import Foundation

// Only the fields the adapter reads. Moodle sends more; unknown keys are ignored.

public struct MoodleSiteInfo: Decodable, Sendable, Equatable {
    public var userid: Int
    public var release: String?
    public var sitename: String?
}

struct MoodleCourse: Decodable {
    var id: Int
    var shortname: String
    var fullname: String
    var startdate: Int?
    var enddate: Int?
}

struct MoodleActionEvents: Decodable {
    struct Event: Decodable {
        struct Course: Decodable { var id: Int }
        var id: Int
        var name: String
        var modulename: String?
        var course: Course?
        var timesort: Int
        var url: String?
    }

    var events: [Event]
}

struct MoodleAssignments: Decodable {
    struct Course: Decodable {
        var id: Int
        var assignments: [Assignment]
    }

    struct Assignment: Decodable {
        var id: Int
        var cmid: Int
        var name: String
        var duedate: Int
    }

    var courses: [Course]
}

struct MoodleForum: Decodable {
    var id: Int
    var course: Int
    var type: String
    var name: String
}

struct MoodleDiscussions: Decodable {
    struct Discussion: Decodable {
        var discussion: Int
        var subject: String
        var message: String
        var created: Int
        var timemodified: Int?
        var userfullname: String?
    }

    var discussions: [Discussion]
}

struct MoodleSection: Decodable {
    struct Module: Decodable {
        var id: Int
        var name: String
        var modname: String
        var url: String?
        var contents: [Content]?
    }

    struct Content: Decodable {
        var type: String
        var filename: String?
        var filepath: String?
        var filesize: Int?
        var fileurl: String?
        var timemodified: Int?
        var mimetype: String?
    }

    var id: Int
    var name: String
    var modules: [Module]
}
