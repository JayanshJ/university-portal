import Foundation

/// A German semester: summer (April–September) or winter (October–March, named after its starting year).
public struct AcademicTerm: Comparable, Hashable, Sendable {
    public enum Season: Int, Sendable { case summer = 0, winter = 1 }

    public var season: Season
    /// The calendar year the term starts in: SoSe26 → 2026, WiSe 26/27 → 2026.
    public var startYear: Int

    public init(_ season: Season, _ startYear: Int) {
        self.season = season
        self.startYear = startYear
    }

    /// "SoSe 26" or "WiSe 26/27".
    public var label: String {
        let short = startYear % 100
        return switch season {
        case .summer: String(format: "SoSe %02d", short)
        case .winter: String(format: "WiSe %02d/%02d", short, (short + 1) % 100)
        }
    }

    public static func < (lhs: AcademicTerm, rhs: AcademicTerm) -> Bool {
        (lhs.startYear, lhs.season.rawValue) < (rhs.startYear, rhs.season.rawValue)
    }

    /// The term `date` falls in, by the German calendar (in Europe/Berlin).
    public static func current(at date: Date = .now) -> AcademicTerm {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year!, month = parts.month!
        switch month {
        case 4...9: return AcademicTerm(.summer, year)
        case 10...12: return AcademicTerm(.winter, year)
        default: return AcademicTerm(.winter, year - 1)
        }
    }

    // "SoSe26", "SoSe 2026", "SS 26", "Sommersemester 2026"
    private static let summerPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:SoSe|SS|Sommersemester|Summer\s+term)\s*(\d{4}|\d{2})(?!\d)"#,
        options: [.caseInsensitive])
    // "WiSe 26/27", "WiSe26/27", "WS 2026/27", "WS26", "Wintersemester 2026/2027"
    private static let winterPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:WiSe|WS|Wintersemester|Winter\s+term)\s*(\d{4}|\d{2})(?:\s*/\s*(?:\d{4}|\d{2}))?(?!\d)"#,
        options: [.caseInsensitive])

    /// The latest term named in `text`, or nil when it names none.
    public static func parse(_ text: String) -> AcademicTerm? {
        let range = NSRange(text.startIndex..., in: text)
        func terms(_ pattern: NSRegularExpression, _ season: Season) -> [AcademicTerm] {
            pattern.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }.map { year in
                    AcademicTerm(season, year < 100 ? 2000 + year : year)
                }
            }
        }
        return (terms(summerPattern, .summer) + terms(winterPattern, .winter)).max()
    }
}
