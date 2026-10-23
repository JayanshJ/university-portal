import Foundation
import GRDB

public enum SyncJob: String, CaseIterable, Sendable {
    case moodleFast = "moodle.fast"
    case moodleMaterials = "moodle.materials"

    var source: SourceKind {
        switch self {
        case .moodleFast, .moodleMaterials: .moodle
        }
    }

    var interval: TimeInterval {
        switch self {
        case .moodleFast: 30 * 60
        case .moodleMaterials: 3 * 3600
        }
    }
}

/// Runs the sync jobs on in-app timers. Jobs of one source never overlap.
public actor SyncScheduler {
    static let maxJitter: TimeInterval = 5 * 60
    static let firstBackoff: TimeInterval = 5 * 60
    static let maxBackoff: TimeInterval = 6 * 3600

    let database: UniDatabase
    let secrets: any SecretStore
    let transport: any HTTPTransport

    private var loops: [SyncJob: Task<Void, Never>] = [:]
    private var running: [SourceKind: Task<Void, Never>] = [:]
    private var failures: [SyncJob: Int] = [:]
    private var lastAttempt: [SyncJob: Date] = [:]

    private static let log = Log(category: "sync")

    public init(database: UniDatabase, secrets: any SecretStore, transport: any HTTPTransport) {
        self.database = database
        self.secrets = secrets
        self.transport = transport
    }

    /// Starts one loop per job. Each loop first catches up if its last good run is older than its interval.
    public func start() {
        for job in SyncJob.allCases where loops[job] == nil {
            loops[job] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let delay = await self.delayUntilDue(job)
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    if Task.isCancelled { return }
                    await self.run(job)
                }
            }
        }
    }

    public func stop() {
        loops.values.forEach { $0.cancel() }
        loops = [:]
    }

    /// After launch or wake: restart the loops so overdue jobs run now and the rest wait as usual.
    public func catchUp() {
        stop()
        start()
    }

    /// "Sync now", and catch-up after wake: runs every job of `source` (or all) right away.
    public func runNow(_ source: SourceKind? = nil) async {
        for job in SyncJob.allCases where source == nil || job.source == source {
            await run(job)
        }
    }

    /// Runs one job, waiting for any other job of the same source to finish first.
    public func run(_ job: SyncJob) async {
        let previous = running[job.source]
        let task = Task { [weak self] in
            await previous?.value
            await self?.perform(job)
        }
        running[job.source] = task
        await task.value
    }

    private func perform(_ job: SyncJob) async {
        lastAttempt[job] = .now
        guard let token = try? secrets.readString(.moodleToken), !token.isEmpty else {
            return  // not connected yet; nothing to do
        }
        if (try? database.source(job.source).status) == .needsReconnect {
            return  // no retries until the user reconnects
        }

        let started = Date.now
        let pending = UniSyncRun(sourceId: (try? database.source(job.source).id) ?? 0, job: job.rawValue, startedAt: started)
        var run = (try? await database.writer.write { db in try pending.inserted(db) }) ?? pending

        do {
            let sync = MoodleSync(database: database, client: MoodleClient(token: token, transport: transport))
            let outcome = switch job {
            case .moodleFast: try await sync.runFast()
            case .moodleMaterials: try await sync.runMaterials()
            }
            failures[job] = 0
            let degraded = !outcome.suspectCourseIds.isEmpty
            try database.setStatus(job.source, degraded ? .degraded : .ok,
                                   error: degraded ? "No items returned for a course that had items; kept the old ones." : nil,
                                   syncedAt: .now)
            finish(&run, ok: true, counts: outcome.counts.dictionary, error: nil)
            Self.log.info("\(job.rawValue): \(outcome.counts.dictionary)")
        } catch MoodleError.invalidToken {
            try? database.setStatus(job.source, .needsReconnect, error: "Moodle token is no longer valid")
            try? recordTokenAge()
            finish(&run, ok: false, counts: nil, error: "invalidtoken")
            Self.log.warning("\(job.rawValue): token rejected, needs reconnect")
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            // Offline is not a failure: retry at the normal backoff start without changing status.
            finish(&run, ok: false, counts: nil, error: "offline")
        } catch let error as URLError {
            failures[job, default: 0] += 1
            try? database.setStatus(job.source, .degraded, error: error.localizedDescription)
            finish(&run, ok: false, counts: nil, error: "\(error.code.rawValue): \(error.localizedDescription)")
        } catch MoodleError.http(let status) where status >= 500 {
            failures[job, default: 0] += 1
            try? database.setStatus(job.source, .degraded, error: "Moodle returned HTTP \(status)")
            finish(&run, ok: false, counts: nil, error: "http \(status)")
        } catch {
            failures[job, default: 0] += 1
            try? database.setStatus(job.source, .error, error: String(describing: error))
            finish(&run, ok: false, counts: nil, error: String(describing: error))
            Self.log.error("\(job.rawValue): \(error)")
        }
    }

    private func finish(_ run: inout UniSyncRun, ok: Bool, counts: [String: Int]?, error: String?) {
        run.finishedAt = .now
        run.ok = ok
        run.counts = counts
        run.error = error.map(Redactor.redact)
        let finished = run
        try? database.writer.write { db in try finished.update(db) }
    }

    private func recordTokenAge() throws {
        try database.updateState(.moodleDiagnostics, default: MoodleDiagnostics()) {
            if let connectedAt = $0.connectedAt {
                $0.tokenAgeAtFailureHours = Date.now.timeIntervalSince(connectedAt) / 3600
            }
        }
    }

    /// Seconds until `job` should run: its interval after the last good run, plus jitter, or the backoff after failures.
    private func delayUntilDue(_ job: SyncJob) -> TimeInterval {
        let failureCount = failures[job, default: 0]
        if failureCount > 0, let attempt = lastAttempt[job] {
            let backoff = min(Self.firstBackoff * pow(2, Double(failureCount - 1)), Self.maxBackoff)
            return max(0, attempt.addingTimeInterval(backoff).timeIntervalSinceNow)
        }
        let lastGood = try? database.writer.read { db in
            try Date.fetchOne(db, sql: """
                SELECT max(started_at) FROM uni_sync_run WHERE job = ? AND ok = 1
                """, arguments: [job.rawValue])
        }
        let jitter = Double.random(in: 0...Self.maxJitter)
        guard let lastGood = lastGood ?? nil else {
            // Never synced: run soon, unless we just tried (e.g. not connected yet).
            guard let attempt = lastAttempt[job] else { return 0 }
            return max(0, attempt.addingTimeInterval(Self.firstBackoff).timeIntervalSinceNow)
        }
        return max(0, lastGood.addingTimeInterval(job.interval + jitter).timeIntervalSinceNow)
    }
}
