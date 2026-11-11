import Foundation

/// Navigation rules for the Moodle sign-in window. SSO may use a different host.
public enum MoodleSignInNavigation {
    public enum Destination: Equatable {
        case callback
        case web
        case unsupported
    }

    public static func destination(for url: URL) -> Destination {
        switch url.scheme?.lowercased() {
        case "moodlemobile": .callback
        case "https", "http": .web
        default: .unsupported
        }
    }
}
