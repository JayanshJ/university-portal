import SwiftUI
import UniversityKit

/// The app's dark theme: near-black canvas, slightly raised panels, hairline borders, one warm
/// accent for "new" and "due soon", red only for overdue, and one colour per course.
enum Theme {
    static let canvas = Color(hex: 0x0B0B0D)
    static let panel = Color(hex: 0x131316)
    static let raised = Color(hex: 0x1A1A1E)
    static let hover = Color(hex: 0x202025)
    static let border = Color(hex: 0x26262B)
    static let text = Color(hex: 0xEDEDEF)
    static let secondary = Color(hex: 0xA1A1AA)
    static let tertiary = Color(hex: 0x6B6B74)
    static let accent = Color(hex: 0xF5C451)
    static let overdue = Color(hex: 0xF87171)
    static let done = Color(hex: 0x4ADE80)

    static let coursePalette: [Color] = [
        Color(hex: 0x6E9BFF), Color(hex: 0x3DD68C), Color(hex: 0xF472B6), Color(hex: 0xA78BFA),
        Color(hex: 0x22D3EE), Color(hex: 0xFB8F5A), Color(hex: 0x94A3B8), Color(hex: 0xE879F9),
    ]

    static let corner: CGFloat = 10
    static let gutter: CGFloat = 24
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
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
}

// MARK: - Components

/// A raised panel with a title row.
struct Card<Content: View, Accessory: View>: View {
    let title: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    SectionLabel(title)
                    Spacer()
                    accessory
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.border, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
    }
}

/// Page title, a one-line summary, and actions on the right.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            actions
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

/// A coloured dot and the course's short name.
struct CourseChip: View {
    let style: CourseStyle
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(style.color).frame(width: 7, height: 7)
            Text(style.name)
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }
}

/// "TUE / 3 / NOV" for a list's date column.
struct DateBlock: View {
    let date: Date
    var tint: Color = Theme.secondary

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint.opacity(0.8))
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint == Theme.secondary ? Theme.text : tint)
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(width: 40)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct NewDot: View {
    var body: some View {
        Circle().fill(Theme.accent).frame(width: 6, height: 6).accessibilityLabel("New")
    }
}

/// A row that highlights on hover and when selected.
struct RowBackground: ViewModifier {
    var selected = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.raised : (hovering ? Theme.hover.opacity(0.6) : .clear)))
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowBackground(selected: Bool = false) -> some View { modifier(RowBackground(selected: selected)) }

    /// The canvas behind every page.
    func pageBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Theme.canvas)
    }
}

struct EmptyState: View {
    let title: String
    let systemImage: String
    let message: String
    var showsSettings = true

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            if showsSettings {
                SettingsLink { Text("Open Settings") }.padding(.top, 4)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum DueText {
    /// "today, 23:59", "tomorrow, 23:59", "in 2 days", "Mon 9 Nov", "overdue · yesterday".
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

    static func color(_ due: Date, now: Date = .now) -> Color {
        if due < now { return Theme.overdue }
        if due.timeIntervalSince(now) < 48 * 3600 { return Theme.accent }
        return Theme.secondary
    }
}

extension Int64 {
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
