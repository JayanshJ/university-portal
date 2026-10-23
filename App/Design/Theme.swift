import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UniversityKit

/// Colours follow the system appearance (light or dark): semantic colours for text and surfaces,
/// the system accent for selection and unread, red for overdue, orange for due soon, and one
/// system colour per course.
enum Theme {
    static let overdue = Color.red
    static let dueSoon = Color.orange
    static let done = Color.green

    static let coursePalette: [Color] = [.blue, .green, .pink, .purple, .teal, .orange, .indigo, .brown]

    /// The reading surface: white in light mode, near-black in dark mode (Mail's message pane).
    static let paper = Color(nsColor: .textBackgroundColor)
}

/// A course's colour and a short name without the term ("Process Mining WS 26/27" → "Process Mining").
struct CourseStyle {
    let color: Color
    let name: String

    private static let termPattern = try! NSRegularExpression(
        pattern: #"\s*[-–(]?\s*(?:WiSe|WS|SoSe|SS|Winter term|Summer term|Wintersemester|Sommersemester)\s*\d{2,4}(?:\s*/\s*\d{2,4})?\)?"#,
        options: .caseInsensitive)

    static func displayName(_ name: String) -> String {
        let range = NSRange(name.startIndex..., in: name)
        let stripped = termPattern.stringByReplacingMatches(in: name, range: range, withTemplate: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
        return stripped.isEmpty ? name : stripped
    }
}

extension PortalOverview {
    /// Colours follow the course list order (Moodle first, then CMS), so they stay put between launches.
    func style(for courseId: Int64) -> CourseStyle {
        let active = courses.filter(\.active).sorted { ($0.source == .moodle ? 0 : 1, $0.id) < ($1.source == .moodle ? 0 : 1, $1.id) }
        let index = active.firstIndex { $0.id == courseId } ?? Int(courseId)
        let course = courses.first { $0.id == courseId }
        let base = course.map { $0.shortName.count <= 28 ? $0.shortName : $0.fullName } ?? ""
        return CourseStyle(color: Theme.coursePalette[index % Theme.coursePalette.count],
                           name: CourseStyle.displayName(base))
    }

    /// Active courses in sidebar order.
    var activeCourses: [CourseRow] {
        courses.filter(\.active).sorted { ($0.source == .moodle ? 0 : 1, $0.id) < ($1.source == .moodle ? 0 : 1, $1.id) }
    }
}

// MARK: - Components

/// A small coloured word after a title: "Exam", "Submitted", "Due date changed".
struct Tag: View {
    let text: String
    var color: Color = Theme.dueSoon

    init(_ text: String, color: Color = Theme.dueSoon) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }
}

/// Mail's unread dot.
struct UnreadDot: View {
    var visible = true

    var body: some View {
        Circle()
            .fill(visible ? Color.accentColor : .clear)
            .frame(width: 8, height: 8)
            .accessibilityHidden(!visible)
            .accessibilityLabel("Unread")
    }
}

/// A section header with a link on the right, e.g. "Due Soon … Show All".
struct SectionHeader: View {
    let title: String
    var action: (title: String, run: () -> Void)?

    init(_ title: String, action: (title: String, run: () -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        }
    }
}

/// A quiet line in an empty section.
struct EmptyRow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(.secondary).padding(.vertical, 2)
    }
}

/// A whole page with nothing to show yet.
struct EmptyState: View {
    let title: String
    let systemImage: String
    let message: String
    var showsSettings = true

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if showsSettings { SettingsLink { Text("Open Settings…") } }
        }
    }
}

/// Finder's icon for a file name, or a link symbol for web links.
struct FileIcon: View {
    let filename: String?
    var size: CGFloat = 20

    var body: some View {
        if let filename {
            let ext = (filename as NSString).pathExtension
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

enum DueText {
    /// "today", "tomorrow", "in 2 days", "in 3 weeks", "overdue · yesterday".
    static func relative(_ due: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        let day = switch days {
        case 0: "today"
        case 1: "tomorrow"
        case -1: "yesterday"
        case 2...59: "in \(days) days"
        case -59 ... -2: "\(-days) days ago"
        default: days > 0 ? "in \(days / 7) weeks" : "\(-days / 7) weeks ago"
        }
        return due < now ? "overdue · \(day)" : day
    }

    static func string(_ due: Date, now: Date = .now) -> String {
        "\(relative(due, now: now)), \(due.formatted(date: .omitted, time: .shortened))"
    }

    /// "Sun 25 Oct, 23:59"
    static func date(_ due: Date) -> String {
        due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func color(_ due: Date, now: Date = .now) -> Color {
        if due < now { return Theme.overdue }
        if due.timeIntervalSince(now) < 48 * 3600 { return Theme.dueSoon }
        return .secondary
    }
}

extension Int64 {
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
