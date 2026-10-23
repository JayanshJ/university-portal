import Foundation

/// Reconnect flow from the plan: create a passport, open `launch.php`, take the token from the
/// `moodlemobile://` callback (or a pasted `location:` value), validate it, store it.
public struct MoodleConnector: Sendable {
    public static let passportLifetime: TimeInterval = 15 * 60

    let database: UniDatabase
    let secrets: any SecretStore
    let transport: any HTTPTransport
    let siteURL: URL

    private static let log = Log(category: "moodle.connect")

    public enum ConnectError: Error, Equatable {
        case unreadable(MoodleLaunchToken.ParseError)
        case tokenRejected
    }

    public init(database: UniDatabase, secrets: any SecretStore, transport: any HTTPTransport,
                siteURL: URL = MoodleClient.siteURL) {
        self.database = database
        self.secrets = secrets
        self.transport = transport
        self.siteURL = siteURL
    }

    /// Starts a reconnect and returns the `launch.php` URL to open.
    public func beginReconnect(now: Date = .now) throws -> URL {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        let passport = String((0..<24).map { _ in alphabet.randomElement(using: &generator)! })
        try database.setState(.moodlePassport, to: MoodlePassport(
            value: passport, expiresAt: now.addingTimeInterval(Self.passportLifetime)))
        return Self.launchURL(siteURL: siteURL, passport: passport)
    }

    public static func launchURL(siteURL: URL = MoodleClient.siteURL, passport: String) -> URL {
        siteURL.appending(path: "admin/tool/mobile/launch.php").appending(queryItems: [
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
            URLQueryItem(name: "passport", value: passport),
        ])
    }

    /// Finishes a reconnect from the callback URL or pasted text.
    @discardableResult
    public func complete(with input: String, via method: MoodleDiagnostics.ConnectMethod, now: Date = .now) async throws -> MoodleSiteInfo {
        let launch: MoodleLaunchToken
        do {
            launch = try MoodleLaunchToken.parse(input)
        } catch let error as MoodleLaunchToken.ParseError {
            throw ConnectError.unreadable(error)
        }

        // The site hash proves the token answers our passport. Its formula is unconfirmed, so a
        // mismatch is recorded rather than fatal; site info below is the real validation.
        let passport = try database.state(.moodlePassport, as: MoodlePassport.self)
        let hashMatched: Bool? = passport.flatMap { passport in
            guard passport.expiresAt > now else { return nil }
            return MoodleLaunchToken.expectedSiteHash(siteURL: siteURL, passport: passport.value) == launch.siteHash.lowercased()
        }
        if hashMatched == false {
            Self.log.warning("Site hash does not match md5(wwwroot + passport); validating with site info only.")
        }

        let client = MoodleClient(token: launch.token, transport: transport, siteURL: siteURL)
        let info: MoodleSiteInfo
        do {
            info = try await MoodleSync(database: database, client: client).siteInfo()
        } catch MoodleError.invalidToken {
            throw ConnectError.tokenRejected
        }

        try secrets.writeString(launch.token, for: .moodleToken)
        if let privateToken = launch.privateToken {
            try secrets.writeString(privateToken, for: .moodlePrivateToken)
        } else {
            try secrets.delete(.moodlePrivateToken)
        }
        try database.removeState(.moodlePassport)
        try database.setStatus(.moodle, .ok)
        try database.updateState(.moodleDiagnostics, default: MoodleDiagnostics()) {
            $0.connectedAt = now
            $0.connectedVia = method
            if method == .sheet { $0.sheetFailure = nil }
            $0.siteHashMatched = hashMatched
            $0.release = info.release
        }
        Self.log.info("Moodle connected via \(method.rawValue); site hash matched: \(hashMatched.map(String.init) ?? "n/a")")
        return info
    }

    public func disconnect() throws {
        try secrets.delete(.moodleToken)
        try secrets.delete(.moodlePrivateToken)
        try database.setStatus(.moodle, .needsReconnect, error: "Disconnected")
    }
}
