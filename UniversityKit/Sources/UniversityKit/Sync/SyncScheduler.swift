import Foundation
import GRDB

public enum SyncJob: String, CaseIterable, Sendable {
    case moodleFast = "moodle.fast"
    case moodleMaterials = "moodle.materials"
    case cmsPublic = "cms.public"
    case cmsMaterials = "cms.materials"

    var source: SourceKind {
        switch self {
        case .moodleFast, .moodleMaterials: .moodle
        case .cmsPublic, .cmsMaterials: .cms
        }
    }

    var interval: TimeInterval {
        switch self {
        case .moodleFast: 30 * 60
        case .moodleMaterials: 3 * 3600
        case .cmsPublic: 3600
        case .cmsMaterials: 3 * 3600
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
    /// For CMS: must not follow redirects or handle cookies (see `URLSessionTransport.manualRedirectsAndCookies`).
    let cmsTransport: any HTTPTransport
    let events: UniEventHub?

    private var loops: [SyncJob: Task<Void, Never>] = [:]
    private var running: [SourceKind: Task<Void, Never>] = [:]
    private var failures: [SyncJob: Int] = [:]
    private var lastAttempt: [SyncJob: Date] = [:]

    private static let log = Log(category: "sync")

    public init(database: UniDatabase, secrets: any SecretStore, transport: any HTTPTransport,
                cmsTransport: (any HTTPTransport)? = nil, events: UniEventHub? = nil) {
        self.database = database
        self.secrets = secrets
        self.transport = transport
        self.cmsTransport = cmsTransport ?? transport
        self.events = events
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

    /// The work for `job`, or nil when there is nothing to do yet (not connected, no courses chosen).
    private func work(for job: SyncJob) -> (@Sendable () async throws -> SyncOutcome)? {
        let database = database, transport = transport, cmsTransport = cmsTransport, secrets = secrets
        switch job {
        case .moodleFast, .moodleMaterials:
            guard let token = try? secrets.readString(.moodleToken), !token.isEmpty else { return nil }
            if (try? database.source(.moodle).status) == .needsReconnect {
                return nil  // no retries until the user reconnects
            }
            let sync = MoodleSync(database: database, client: MoodleClient(token: token, transport: transport))
            if job == .moodleFast {
                return { @Sendable in try await sync.runFast() }
            }
            return { @Sendable in try await sync.runMaterials() }
        case .cmsPublic, .cmsMaterials:
            let hasCourses = (try? database.writer.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM uni_course c JOIN uni_source s ON s.id = c.source_id
                                   WHERE s.kind = 'cms' AND c.active = 1)
                    """)
            }) ?? nil
            guard hasCourses == true else { return nil }
            let client = CMSClient(transport: cmsTransport)
            let sync = CMSSync(database: database, client: client)
            if job == .cmsPublic {
                return { @Sendable in try await sync.runPublic() }
            }
            guard (try? secrets.readString(.cmsPassword)).flatMap({ $0 }) != nil,
                  (try? database.source(.cms).status) != .needsReconnect else {
                return nil  // not signed in, or waiting for the user to fix the password
            }
            return { @Sendable in
                try await sync.runMaterials(session: await CMSSession(database: database, secrets: secrets, client: client))
            }
        }
    }

    private func perform(_ job: SyncJob) async {
        lastAttempt[job] = .now
        guard let work = work(for: job) else { return }

        let started = Date.now
        let pending = UniSyncRun(sourceId: (try? database.source(job.source).id) ?? 0, job: job.rawValue, startedAt: started)
        var run = (try? await database.writer.write { db in try pending.inserted(db) }) ?? pending

        do {
            let outcome = try await work()
            events?.publish(outcome.events)
            failures[job] = 0
            let degraded = !outcome.suspectCourseIds.isEmpty
            try setStatus(job, degraded ? .degraded : .ok,
                          error: degraded ? "No items returned for a course that had items; kept the old ones." : nil,
                          syncedAt: .now)
            finish(&run, ok: true, counts: outcome.counts.dictionary, error: nil)
            Self.log.info("\(job.rawValue): \(outcome.counts.dictionary)")
        } catch CMSAuthError.loginRejected, CMSAuthError.stillLoggedOut, CMSAuthError.loginFormMissing {
            try? setStatus(job, .needsReconnect, error: "CMS login failed. Check your username and password in Settings.")
            finish(&run, ok: false, counts: nil, error: "cms login failed")
            Self.log.warning("\(job.rawValue): CMS login failed, needs reconnect")
        } catch CMSAuthError.waitBeforeRetry(let until) {
            finish(&run, ok: false, counts: nil, error: "waiting until \(until.formatted(.iso8601)) before the next login attempt")
        } catch MoodleError.invalidToken {
            try? setStatus(job, .needsReconnect, error: "Moodle token is no longer valid")
            try? recordTokenAge()
            finish(&run, ok: false, counts: nil, error: "invalidtoken")
            Self.log.warning("\(job.rawValue): token rejected, needs reconnect")
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            // Offline is not a failure: retry at the normal backoff start without changing status.
            finish(&run, ok: false, counts: nil, error: "offline")
        } catch let error as URLError {
            failures[job, default: 0] += 1
            try? setStatus(job, .degraded, error: error.localizedDescription)
            finish(&run, ok: false, counts: nil, error: "\(error.code.rawValue): \(error.localizedDescription)")
        } catch MoodleError.http(let status) where status >= 500 {
            failures[job, default: 0] += 1
            try? setStatus(job, .degraded, error: "Moodle returned HTTP \(status)")
            finish(&run, ok: false, counts: nil, error: "http \(status)")
        } catch CMSError.http(let status, let path) where status >= 500 {
            failures[job, default: 0] += 1
            try? setStatus(job, .degraded, error: "CMS returned HTTP \(status) for \(path)")
            finish(&run, ok: false, counts: nil, error: "http \(status) \(path)")
        } catch let error as CMSPageError {
            // A page no longer looks as expected: keep the old data, flag the source.
            failures[job, default: 0] += 1
            try? setStatus(job, .degraded, error: "CMS page changed: \(error)")
            finish(&run, ok: false, counts: nil, error: String(describing: error))
        } catch {
            failures[job, default: 0] += 1
            try? setStatus(job, .error, error: String(describing: error))
            finish(&run, ok: false, counts: nil, error: String(describing: error))
            Self.log.error("\(job.rawValue): \(error)")
        }
    }

    /// Every status write of a run. The public CMS job needs no login, so none of its outcomes may
    /// replace `needs_reconnect` left by a failed login: only the user fixing the password clears it.
    private func setStatus(_ job: SyncJob, _ status: SourceStatus, error: String?, syncedAt: Date? = nil) throws {
        if job == .cmsPublic, status != .needsReconnect, let current = try? database.source(.cms),
           current.status == .needsReconnect {
            try database.setStatus(.cms, .needsReconnect, error: current.lastError, syncedAt: syncedAt)
            return
        }
        try database.setStatus(job.source, status, error: error, syncedAt: syncedAt)
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
