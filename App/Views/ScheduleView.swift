import SwiftUI
import UniversityKit

/// A week like Calendar's week view: seven columns of CMS events and Moodle deadlines, with
/// "‹ Today ›" in the toolbar.
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start
    @State private var items: [PortalOverview.ItemRow] = []

    private var days: [Date] {
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { index, day in
                    if index > 0 { Divider() }
                    DayHeader(day: day)
                }
            }
            .frame(height: 44)
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            if index > 0 { Divider() }
                            DayColumn(day: day, items: items.filter { Calendar.current.isDate($0.date ?? .distantPast, inSameDayAs: day) })
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
        }
        .background(Theme.paper)
        .navigationTitle(weekStart.formatted(.dateTime.month(.wide).year()))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                ControlGroup {
                    Button { move(-1) } label: { Label("Previous Week", systemImage: "chevron.left") }
                    Button("Today") { weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start }
                    Button { move(1) } label: { Label("Next Week", systemImage: "chevron.right") }
                }
            }
        }
        .task(id: weekStart) { reload() }
        .onChange(of: model.overview) { reload() }
    }

    private var subtitle: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        let range = "\(weekStart.formatted(.dateTime.day().month(.abbreviated)))–\(end.formatted(.dateTime.day().month(.abbreviated)))"
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var parts = [range, count(items.filter { $0.kind == .event }.count, "event"),
                     count(items.filter { $0.kind == .deadline }.count, "deadline")]
        let exams = items.filter(\.isExam).count
        if exams > 0 { parts.append(count(exams, "exam")) }
        return parts.joined(separator: " · ")
    }

    private func move(_ weeks: Int) {
        weekStart = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekStart)!
    }

    private func reload() {
        items = model.schedule(from: weekStart, to: Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!)
    }
}

/// "Mon 19", with today's date in a red circle as in Calendar.
private struct DayHeader: View {
    let day: Date

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        HStack(spacing: 5) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .foregroundStyle(.secondary)
            Text(day.formatted(.dateTime.day()))
                .fontWeight(isToday ? .semibold : .regular)
                .foregroundStyle(isToday ? .white : .primary)
                .frame(minWidth: 24, minHeight: 24)
                .background { if isToday { Circle().fill(.red) } }
        }
        .font(.title3)
        .frame(maxWidth: .infinity)
    }
}

private struct DayColumn: View {
    let day: Date
    let items: [PortalOverview.ItemRow]

    var body: some View {
        let calendar = Calendar.current
        let isPast = day < calendar.startOfDay(for: .now)
        let isWeekend = calendar.isDateInWeekend(day)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.filter { $0.kind == .deadline }) { DeadlineMark(item: $0) }
            ForEach(items.filter { $0.kind == .event }) { EventBlock(event: $0) }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isWeekend ? Color.secondary.opacity(0.06) : .clear)
        .opacity(isPast ? 0.6 : 1)
    }
}

/// Calendar's event style: a tinted fill and a bar in the course colour.
private struct EventBlock: View {
    @Environment(AppModel.self) private var model
    let event: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: event.courseId)
        let color = event.isExam ? Theme.overdue : style.color
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title).font(.caption.weight(.semibold)).lineLimit(2)
            Group {
                Text(timeText).monospacedDigit()
                Text(style.name).lineLimit(1)
                if let location = event.location, !location.hasPrefix("http") {
                    Text(location).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.18))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help([event.title, style.name, event.section, event.location].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu {
            if let category = event.section {
                Button("Hide “\(category)” for \(style.name)") {
                    model.setCategory(category, hidden: true, courseId: event.courseId)
                }
            }
            Button("Open in CMS") { model.openLink(event) }
            Divider()
            Button("Go to \(style.name)") { model.selection = .course(event.courseId) }
        }
    }

    private var timeText: String {
        guard let start = event.date else { return "" }
        if event.allDay { return "All day" }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end = event.endDate, end > start else { return from }
        return "\(from)–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// A deadline at the top of its day, like a reminder in Calendar.
private struct DeadlineMark: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        let done = item.doneAt != nil
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(style.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.caption.weight(.semibold)).strikethrough(done).lineLimit(2)
                Text("due \(item.date?.formatted(date: .omitted, time: .shortened) ?? "")")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 4).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(item.title)\n\(style.name)")
        .onTapGesture(count: 2) { model.openLink(item) }
        .contextMenu {
            Button(done ? "Mark as Not Done" : "Mark as Done") { model.setDone(item, done: !done) }
            Button("Open in Moodle") { model.openLink(item) }
        }
    }
}
