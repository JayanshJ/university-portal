import Foundation

/// Who the student is, for submission headers. Filled by the user (name defaults to Moodle's).
public struct StudentDetails: Codable, Sendable, Equatable {
    public var name: String
    public var matrikelnr: String
    public var email: String

    public init(name: String = "", matrikelnr: String = "", email: String = "") {
        self.name = name
        self.matrikelnr = matrikelnr
        self.email = email
    }

    public static func load(_ db: UniDatabase) -> StudentDetails {
        var details = (try? db.state(.studentDetails, as: StudentDetails.self)) ?? StudentDetails()
        if details.name.isEmpty, let full = try? db.state(.moodleFullName, as: String.self) {
            details.name = full
        }
        return details
    }

    public func save(_ db: UniDatabase) throws {
        try db.setState(.studentDetails, to: self)
    }
}

public struct Partner: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var matrikelnr: String
    public var email: String

    public init(id: UUID = UUID(), name: String = "", matrikelnr: String = "", email: String = "") {
        self.id = id
        self.name = name
        self.matrikelnr = matrikelnr
        self.email = email
    }
}

/// Per-course submission details: exercise group, tutorial and team partners.
public struct CourseDetails: Codable, Sendable, Equatable {
    public var group: String
    public var tutorial: String
    public var partners: [Partner]
    /// The student hands in alone: the sheet's partner fields don't apply.
    public var alone: Bool

    public init(group: String = "", tutorial: String = "", partners: [Partner] = [], alone: Bool = false) {
        self.group = group
        self.tutorial = tutorial
        self.partners = partners
        self.alone = alone
    }

    private enum CodingKeys: String, CodingKey { case group, tutorial, partners, alone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        tutorial = try c.decodeIfPresent(String.self, forKey: .tutorial) ?? ""
        partners = try c.decodeIfPresent([Partner].self, forKey: .partners) ?? []
        alone = try c.decodeIfPresent(Bool.self, forKey: .alone) ?? false  // saved before `alone` existed
    }

    public static func load(_ db: UniDatabase, courseId: Int64) -> CourseDetails {
        let all = (try? db.state(.courseDetails, as: [String: CourseDetails].self)) ?? [:]
        return all[String(courseId)] ?? CourseDetails()
    }

    /// The details saved for the first of `courseIds` that has any: the course's own first, then
    /// its related courses (a twin page may have been where they were typed).
    public static func load(_ db: UniDatabase, courseIds: [Int64]) -> CourseDetails {
        let all = (try? db.state(.courseDetails, as: [String: CourseDetails].self)) ?? [:]
        return courseIds.lazy.compactMap { all[String($0)] }.first ?? CourseDetails()
    }

    public func save(_ db: UniDatabase, courseId: Int64) throws {
        try db.updateState(.courseDetails, default: [String: CourseDetails]()) {
            $0[String(courseId)] = self
        }
    }
}
