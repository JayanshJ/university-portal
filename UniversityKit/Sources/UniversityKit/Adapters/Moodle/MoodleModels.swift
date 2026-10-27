import Foundation

// Only the fields the adapter reads. Moodle sends more; unknown keys are ignored.

public struct MoodleSiteInfo: Decodable, Sendable, Equatable {
    public struct Function: Decodable, Sendable, Equatable { public var name: String }

    public var userid: Int
    public var release: String?
    public var sitename: String?
    /// 1 when the token may upload files (`webservice/upload.php`).
    public var uploadfiles: Int?
    /// The web service functions the token may call.
    public var functions: [Function]?

    /// Whether assignments can be submitted from the app with this token.
    public var canSubmitAssignments: Bool {
        let names = Set((functions ?? []).map(\.name))
        return uploadfiles == 1 && MoodleSubmissions.requiredFunctions.isSubset(of: names)
    }
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
        var numreplies: Int?
        var pinned: Bool?
        /// The first post's files.
        var attachments: [MoodleAttachment]?
    }

    var discussions: [Discussion]
}

struct MoodleSection: Decodable {
    struct Module: Decodable {
        var id: Int
        var name: String
        var modname: String
        var url: String?
        var description: String?
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
    var summary: String?
    var section: Int?
    var modules: [Module]
}

/// A file attached to a forum post or an assignment. Moodle calls the link `fileurl` or `url`.
struct MoodleAttachment: Decodable {
    var filename: String
    var fileurl: String?
    var url: String?
    var filesize: Int?
    var mimetype: String?
    var timemodified: Int?

    var link: String? { fileurl ?? url }
}

struct MoodleCalendarEvents: Decodable {
    struct Event: Decodable {
        var id: Int
        var name: String
        var modulename: String?
        var courseid: Int?
        var timestart: Int
        var eventtype: String
    }

    var events: [Event]
}

struct MoodlePosts: Decodable {
    struct Post: Decodable {
        struct Author: Decodable { var fullname: String? }
        var id: Int
        var message: String
        var timecreated: Int
        var author: Author?
        var attachments: [MoodleAttachment]?
    }

    var posts: [Post]
}

struct MoodleGradeItems: Decodable {
    struct User: Decodable { var gradeitems: [Item] }
    struct Item: Decodable {
        var id: Int
        var itemname: String?
        var itemtype: String
        var itemmodule: String?
        var cmid: Int?
        var graderaw: Double?
        var gradeformatted: String?
        var rangeformatted: String?
        var percentageformatted: String?
        var weightformatted: String?
        var feedback: String?
        var gradedategraded: Int?
    }

    var usergrades: [User]
}

struct MoodlePages: Decodable {
    struct Page: Decodable {
        var coursemodule: Int
        var course: Int
        var name: String
        var content: String?
    }

    var pages: [Page]
}

struct MoodleCourseSummaries: Decodable {
    struct Course: Decodable {
        var id: Int
        var summary: String?
    }

    var courses: [Course]
}

struct MoodleAssignmentIntros: Decodable {
    struct Course: Decodable {
        var id: Int
        var assignments: [Assignment]
    }

    struct Assignment: Decodable {
        var cmid: Int
        var name: String
        var intro: String?
        var introattachments: [MoodleAttachment]?
    }

    var courses: [Course]
}

struct MoodleConversations: Decodable {
    struct Member: Decodable {
        var id: Int
        var fullname: String
    }

    struct Message: Decodable {
        var id: Int
        var useridfrom: Int
        var text: String
        var timecreated: Int
    }

    struct Conversation: Decodable {
        var id: Int
        var name: String?
        var type: Int?
        var unreadcount: Int?
        var members: [Member]?
        var messages: [Message]?
    }

    var conversations: [Conversation]
}

struct MoodleConversationMessages: Decodable {
    var members: [MoodleConversations.Member]?
    var messages: [MoodleConversations.Message]
}
