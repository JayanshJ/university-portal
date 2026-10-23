import SwiftUI
import UniversityKit

/// A deadline: done circle, date column, title with course, relative due time.
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
        HStack(spacing: 12) {
            Button { model.setDone(item, done: !isDone) } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isDone ? Theme.done : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help(isDone ? "Mark not done" : "Mark done")

            DateBlock(date: due, tint: isDone ? Theme.tertiary : (due < .now ? Theme.overdue : Theme.secondary))

            Rectangle().fill(style.color).frame(width: 3, height: 30).clipShape(Capsule())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isDone ? Theme.tertiary : Theme.text)
                        .strikethrough(isDone, color: Theme.tertiary)
                        .lineLimit(1)
                    if dueChanged { Pill(text: "Due date changed") }
                    if item.doneSource == .moodle { Pill(text: "Submitted", color: Theme.done) }
                }
                if showsCourse {
                    Text(style.name).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(DueText.relative(due))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDone ? Theme.tertiary : DueText.color(due))
                Text(due.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rowBackground()
        .contextMenu {
            Button(isDone ? "Mark Not Done" : "Mark Done") { model.setDone(item, done: !isDone) }
            Button("Open in \(item.source == .moodle ? "Moodle" : "CMS")") { model.openLink(item) }
            Button("Go to \(style.name)") { model.selection = .course(item.courseId) }
        }
        .onTapGesture(count: 2) { model.openLink(item) }
    }
}

/// A calendar event (or a deadline on the schedule): time, course colour bar, title, place.
struct EventLine: View {
    @Environment(AppModel.self) private var model
    let event: PortalOverview.ItemRow
    var showsDay = false
    var showsCourse = true

    var body: some View {
        let style = model.overview.style(for: event.courseId)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if showsDay, let start = event.date {
                    Text(dayText(start)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
                Text(timeText).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            .frame(width: 92, alignment: .leading)

            Rectangle().fill(style.color).frame(width: 3, height: 30).clipShape(Capsule())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if event.isExam { Pill(text: "Exam", color: Theme.overdue) }
                    if event.kind == .deadline { Pill(text: "Deadline") }
                }
                Text([showsCourse ? style.name : nil, event.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if event.kind == .event, let category = event.section, category != "Other" {
                Text(category).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rowBackground()
        .contextMenu {
            if event.kind == .event, let category = event.section {
                Button("Hide “\(category)” for \(style.name)") {
                    model.setCategory(category, hidden: true, courseId: event.courseId)
                }
            }
            Button("Open in \(event.source == .moodle ? "Moodle" : "CMS")") { model.openLink(event) }
            Button("Go to \(style.name)") { model.selection = .course(event.courseId) }
        }
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

/// An announcement or material in a summary: course dot and title.
struct CompactLine: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    var showsCourse = true
    var detail: String?
    let action: () -> Void

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(style.color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    let meta = [showsCourse ? style.name : nil, detail].compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if item.isNew { NewDot() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .rowBackground()
        }
        .buttonStyle(.plain)
    }
}

/// Shown above everything when a source needs the user.
struct ReconnectBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.overview.needsReconnect {
            let moodle = model.overview.moodle?.status == .needsReconnect
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.overdue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(moodle ? "Moodle needs reconnecting" : "CMS sign-in failed")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(moodle ? "The Moodle token stopped working. Reconnecting takes about 20 seconds."
                                : "CMS didn't accept the saved password. Materials stop syncing until you sign in again.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                SettingsLink { Text("Reconnect…") }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.overdue.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.overdue.opacity(0.35)))
        }
    }
}
