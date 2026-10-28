import SwiftUI
import UniversityKit

/// A deadline, Reminders-style: a completion circle in the course colour, title and course, and
/// when it's due on the right.
struct DeadlineLine: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    var showsCourse = true

    private var isDone: Bool { item.doneAt != nil }
    private var dueChanged: Bool {
        !isDone && (item.dueChangedAt.map { Date.now.timeIntervalSince($0) < 7 * 86_400 } ?? false)
    }

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        let due = item.date ?? .distantFuture
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { model.setDone(item, done: !isDone) } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(style.color)
            }
            .buttonStyle(.plain)
            .help(isDone ? "Mark as not done" : "Mark as done")
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .foregroundStyle(isDone ? .secondary : .primary)
                        .strikethrough(isDone)
                        .lineLimit(1)
                    if dueChanged { Tag("Due date changed") }
                    if item.doneSource == .moodle { Tag("Submitted", color: Theme.done) }
                }
                if showsCourse {
                    Text(style.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let target = model.submitTarget(item) {
                Button(isDone ? "View" : "Submit…") { model.submitting = target }
                    .controlSize(.small)
                    .help(isDone ? "See your submission" : "Hand in on Moodle")
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(DueText.relative(due))
                    .foregroundStyle(isDone ? .secondary : DueText.color(due))
                Text(DueText.date(due))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            if let target = model.submitTarget(item) {
                Button(isDone ? "View Submission…" : "Submit…") { model.submitting = target }
                Divider()
            }
            Button(isDone ? "Mark as Not Done" : "Mark as Done") { model.setDone(item, done: !isDone) }
            Button("Open in \(item.source == .moodle ? "Moodle" : "CMS")") { model.openLink(item) }
            Divider()
            Button("Go to \(style.name)") { model.selection = .course(item.courseId) }
        }
        .onTapGesture(count: 2) {
            if let target = model.submitTarget(item) { model.submitting = target } else { model.openLink(item) }
        }
    }
}

/// A calendar event (or a deadline on the schedule): time, a dot in the course colour, title, place.
struct EventLine: View {
    @Environment(AppModel.self) private var model
    let event: PortalOverview.ItemRow
    var showsDay = false
    var showsCourse = true

    var body: some View {
        let style = model.overview.style(for: event.courseId)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(style.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).lineLimit(1)
                    if event.isExam { Tag("Exam", color: Theme.overdue) }
                    if event.details["mandatory"] == "1" { Tag("Mandatory", color: Theme.overdue) }
                    if event.kind == .deadline { Tag("Deadline") }
                }
                let detail = [showsCourse ? style.name : nil, event.location, category].compactMap { $0 }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let from = event.details["from"] {
                    Label("From \(from)", systemImage: "text.quote")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(event.details["quote"].map { "“\($0)”" } ?? from)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if showsDay, let start = event.date { Text(dayText(start)) }
                Text(timeText).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            if event.kind == .event, let category = event.section {
                Button("Hide “\(category)” for \(style.name)") {
                    model.setCategory(category, hidden: true, courseId: event.courseId)
                }
            }
            Button(event.details["from"] != nil ? "Show Where It's Mentioned" : "Open in \(event.source == .moodle ? "Moodle" : "CMS")") { model.openLink(event) }
            Divider()
            Button("Go to \(style.name)") { model.selection = .course(event.courseId) }
        }
    }

    private var category: String? {
        guard event.kind == .event, event.details["from"] == nil, let section = event.section, section != "Other" else { return nil }
        return section
    }

    /// "Today", "Tomorrow", a weekday within the week, otherwise "Tue 3 Nov".
    private func dayText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if date < Date.now.addingTimeInterval(6 * 86_400) { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var timeText: String {
        guard let start = event.date else { return "" }
        if event.kind == .deadline { return "due " + start.formatted(date: .omitted, time: .shortened) }
        if event.allDay { return "All day" }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end = event.endDate, end > start else { return from }
        return "\(from)–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// An announcement or material in a summary list: unread dot, title, and a detail line.
struct CompactLine: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    var showsCourse = true
    var detail: String?
    var icon: Bool = false
    let action: () -> Void

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UnreadDot(visible: item.isNew)
                if icon {
                    FileIcon(filename: item.hasFile ? (item.filename ?? item.title) : nil, size: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    let meta = [showsCourse ? style.name : nil, detail].compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown at the top of Today when a source needs the user.
struct ReconnectBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.overview.needsReconnect {
            let moodle = model.overview.moodle?.status == .needsReconnect
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(moodle ? "Moodle needs reconnecting" : "CMS sign-in failed").fontWeight(.semibold)
                    Text(moodle ? "The Moodle token stopped working. Reconnecting takes about 20 seconds."
                                : "CMS didn't accept the saved password. Materials stop syncing until you sign in again.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                SettingsLink { Text("Reconnect…") }
            }
            .padding(.vertical, 4)
        }
    }
}

/// "All Courses" and one entry per course, for a toolbar.
struct CoursePicker: View {
    @Environment(AppModel.self) private var model
    let courseIds: [Int64]
    @Binding var selection: Int64?

    var body: some View {
        // A menu, not a menu-style picker: the toolbar stretches pickers over the neighbouring column,
        // while a menu is as wide as its label.
        Menu {
            Picker("Course", selection: $selection) {
                Text("All Courses").tag(Int64?.none)
                Divider()
                ForEach(courseIds, id: \.self) { id in
                    Text(model.overview.style(for: id).name).tag(Int64?.some(id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selection.map { model.overview.style(for: $0).name } ?? "All Courses")
        }
        .fixedSize()
        .help("Show one course")
    }
}
