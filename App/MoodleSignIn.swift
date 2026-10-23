import AuthenticationServices
import AppKit

/// Opens `launch.php` in a system sign-in sheet and returns the `moodlemobile://token=…` callback.
@MainActor
final class MoodleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SignInError: LocalizedError {
        case couldNotStart

        var errorDescription: String? { "The sign-in sheet could not be opened." }
    }

    private var session: ASWebAuthenticationSession?

    func callbackURL(for url: URL) async throws -> URL {
        defer { session = nil }
        // The sheet only takes clicks when the app is active and anchored to a real window.
        NSApp.activate()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("moodlemobile")) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? URLError(.unknown))
                }
            }
            session.presentationContextProvider = self
            // Reuse an existing Safari login to Moodle if there is one.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: SignInError.couldNotStart)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.windows.map(Optional.some)
            return candidates.compactMap { $0 }.first { $0.isVisible && $0.canBecomeKey } ?? ASPresentationAnchor()
        }
    }
}
