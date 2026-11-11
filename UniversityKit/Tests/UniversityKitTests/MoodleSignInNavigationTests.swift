import Foundation
import Testing
@testable import UniversityKit

@Suite struct MoodleSignInNavigationTests {
    @Test func recognizesMoodleCallbackAndAllowsCrossHostSSO() throws {
        let encoded = Data("site-hash:::token:::private".utf8).base64EncodedString()
        let callback = try #require(URL(string: "moodlemobile://token=\(encoded)"))
        #expect(MoodleSignInNavigation.destination(for: callback) == .callback)
        #expect(try MoodleLaunchToken.parse(callback.absoluteString).token == "token")
        #expect(MoodleSignInNavigation.destination(for: URL(string: "https://login.microsoftonline.com/signin")!) == .web)
        #expect(MoodleSignInNavigation.destination(for: URL(string: "https://idp0.uni-saarland.de/login")!) == .web)
    }

    @Test func rejectsOtherCustomSchemes() {
        #expect(MoodleSignInNavigation.destination(for: URL(string: "file:///tmp/example")!) == .unsupported)
        #expect(MoodleSignInNavigation.destination(for: URL(string: "otherapp://login")!) == .unsupported)
    }
}
