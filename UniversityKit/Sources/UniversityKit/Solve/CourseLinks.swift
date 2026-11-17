import Foundation

/// Which courses belong together: a lecture on Moodle and its CMS page share a distinctive word.
public enum CourseLinks {
    /// The course itself first, then active courses whose name shares a distinctive word with it.
    public static func related(courseId: Int64, courseName: String,
                               courses: [(id: Int64, name: String, active: Bool)]) -> [Int64] {
        let own = words(courseName)
        var ids = [courseId]
        for course in courses where course.active && !ids.contains(course.id) {
            if !own.isDisjoint(with: words(course.name)) { ids.append(course.id) }
        }
        return ids
    }

    private static let filler: Set<String> = ["and", "und", "the", "der", "die", "das", "for", "fur", "für", "in", "of", "von",
                                              "sose", "wise", "winter", "summer", "semester", "course", "kurs", "vorlesung", "lecture"]

    /// Lowercased words of four or more letters, without filler.
    public static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !filler.contains($0) })
    }
}
