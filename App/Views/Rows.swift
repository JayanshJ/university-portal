import SwiftUI
import UniversityKit

/// Shared pieces of every list: course tag, title, date, source tag. One accent for "new" and
/// "due soon", red only for overdue.
enum Layout {
    static let readingWidth: CGFloat = 720
    static let courseColumn: CGFloat = 120
}

struct CourseTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: Layout.courseColumn, alignment: .leading)
    }
}

struct SourceTag: View {
    let source: SourceKind

    var body: some View {
        Text(source == .moodle ? "Moodle" : "CMS")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
    }
}

struct NewDot: View {
    var body: some View {
        Circle().fill(.tint).frame(width: 6, height: 6).accessibilityLabel("New")
    }
}

enum DueText {
    /// "today, 23:59", "tomorrow, 23:59", "in 2 days, 23:59", "Mon 9 Nov, 23:59", "overdue · yesterday, 23:59".
    static func string(_ due: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = due.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        let day = switch days {
        case 0: "today"
        case 1: "tomorrow"
        case -1: "yesterday"
        case 2...6: "in \(days) days"
        default: due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return due < now ? "overdue · \(day), \(time)" : "\(day), \(time)"
    }

    static func style(_ due: Date, now: Date = .now) -> AnyShapeStyle {
        if due < now { return AnyShapeStyle(.red) }
        if due.timeIntervalSince(now) < 48 * 3600 { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(.secondary)
    }
}

struct DeadlineRow: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    var showsCourse = true

    private var dueRecentlyChanged: Bool {
        (item.dueChangedAt.map { Date.now.timeIntervalSince($0) < 7 * 86_400 } ?? false) && item.doneAt == nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                model.setDone(item, done: item.doneAt == nil)
            } label: {
                Image(systemName: item.doneAt == nil ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(item.doneAt == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .help(item.doneAt == nil ? "Mark done" : "Mark not done")

            if showsCourse { CourseTag(text: item.course) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .strikethrough(item.doneAt != nil)
                    .foregroundStyle(item.doneAt == nil ? .primary : .secondary)
                    .lineLimit(1)
                if dueRecentlyChanged {
                    Text("Due date changed").font(.caption).foregroundStyle(.tint)
                } else if item.doneSource == .moodle {
                    Text("Submitted on Moodle").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let due = item.date {
                Text(DueText.string(due))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(item.doneAt == nil ? DueText.style(due) : AnyShapeStyle(.tertiary))
            }
            SourceTag(source: item.source)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(item.doneAt == nil ? "Mark Done" : "Mark Not Done") { model.setDone(item, done: item.doneAt == nil) }
            Button("Open in \(item.source == .moodle ? "Moodle" : "CMS")") { model.openLink(item) }
        }
    }
}

struct EventRow: View {
    @Environment(AppModel.self) private var model
    let event: PortalOverview.ItemRow
    var showsDay = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if event.kind == .deadline, let due = event.date {
                    Text("due " + due.formatted(date: .omitted, time: .shortened))
                } else if event.allDay {
                    Text("All day")
                } else if let start = event.date {
                    Text((showsDay ? start.formatted(.dateTime.weekday(.abbreviated)) + " " : "")
                         + start.formatted(date: .omitted, time: .shortened)
                         + (event.endDate.map { "–" + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: Layout.courseColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).lineLimit(1)
                    if event.isExam { Text("Exam").font(.caption.bold()).foregroundStyle(.tint) }
                    if event.kind == .deadline { Text("Deadline").font(.caption.bold()).foregroundStyle(.tint) }
                }
                Text([event.course, event.kind == .event ? event.section : nil, event.location]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            SourceTag(source: event.source)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if event.kind == .event, let category = event.section {
                Button("Hide \(category) for \(event.course)") {
                    model.setCategory(category, hidden: true, courseId: event.courseId)
                }
            }
            Button("Open in \(event.source == .moodle ? "Moodle" : "CMS")") { model.openLink(event) }
        }
    }
}

struct EmptySectionView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            SettingsLink { Text("Open Settings") }
        }
    }
}

struct ReconnectBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.overview.needsReconnect {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.overview.moodle?.status == .needsReconnect ? "Moodle needs reconnecting" : "CMS sign-in failed")
                        .font(.headline)
                    Text(model.overview.moodle?.status == .needsReconnect
                         ? "The Moodle token stopped working. Reconnecting takes about 20 seconds."
                         : "CMS didn't accept the saved password. Materials stop syncing until you sign in again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                SettingsLink { Text("Reconnect…") }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.3)))
        }
    }
}
