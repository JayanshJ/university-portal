import SwiftUI
import UniversityKit

/// A week at a glance: seven columns of CMS events and Moodle deadlines.
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start
    @State private var items: [PortalOverview.ItemRow] = []

    private var days: [Date] {
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(weekTitle, subtitle: subtitle) {
                HStack(spacing: 4) {
                    navButton("chevron.left") { move(-1) }
                    Button("Today") { weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.raised))
                    navButton("chevron.right") { move(1) }
                }
            }

            ScrollView {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        DayColumn(day: day, items: items.filter { Calendar.current.isDate($0.date ?? .distantPast, inSameDayAs: day) })
                    }
                }
                .padding(.horizontal, Theme.gutter).padding(.bottom, Theme.gutter)
            }
        }
        .task(id: weekStart) { reload() }
        .onChange(of: model.overview) { reload() }
    }

    private var weekTitle: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        return "\(weekStart.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private var subtitle: String {
        let events = items.filter { $0.kind == .event }.count
        let deadlines = items.filter { $0.kind == .deadline }.count
        let exams = items.filter(\.isExam).count
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var parts = [count(events, "event"), count(deadlines, "deadline")]
        if exams > 0 { parts.append(count(exams, "exam")) }
        return parts.joined(separator: " · ") + " · right-click an event to hide its category"
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(Capsule().fill(Theme.raised))
        }
        .buttonStyle(.plain).foregroundStyle(Theme.secondary)
    }

    private func move(_ weeks: Int) {
        weekStart = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekStart)!
    }

    private func reload() {
        items = model.schedule(from: weekStart, to: Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!)
    }
}

private struct DayColumn: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let items: [PortalOverview.ItemRow]

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        let isPast = day < Calendar.current.startOfDay(for: .now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isToday ? Theme.accent : Theme.tertiary)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isToday ? Theme.accent : Theme.text)
            }
            .padding(.horizontal, 6).padding(.bottom, 4)

            ForEach(items.filter { $0.kind == .deadline }) { item in
                DeadlineChip(item: item)
            }
            ForEach(items.filter { $0.kind == .event }) { event in
                EventCard(event: event)
            }
            if items.isEmpty {
                Text("Free").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.horizontal, 6)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(isToday ? Theme.panel : Theme.panel.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(isToday ? Theme.accent.opacity(0.4) : Theme.border))
        .opacity(isPast ? 0.65 : 1)
    }
}

private struct EventCard: View {
    @Environment(AppModel.self) private var model
    let event: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: event.courseId)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(timeText).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
                Text(event.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                Text(style.name).font(.system(size: 11)).foregroundStyle(style.color).lineLimit(1)
                if let location = event.location, !location.hasPrefix("http") {
                    Text(location).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                if event.isExam { Pill(text: "Exam", color: Theme.overdue) }
            }
            .padding(.leading, 10).padding(.trailing, 7).padding(.vertical, 6)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .leading) {
            Rectangle().fill(event.isExam ? Theme.overdue : style.color).frame(width: 3)
        }
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help([event.title, style.name, event.section, event.location].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu {
            if let category = event.section {
                Button("Hide “\(category)” for \(style.name)") {
                    model.setCategory(category, hidden: true, courseId: event.courseId)
                }
            }
            Button("Open in CMS") { model.openLink(event) }
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

private struct DeadlineChip: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        HStack(spacing: 6) {
            Image(systemName: item.doneAt == nil ? "flag.fill" : "checkmark")
                .font(.system(size: 9))
                .foregroundStyle(item.doneAt == nil ? Theme.accent : Theme.done)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                Text("\(style.name) · \(item.date?.formatted(date: .omitted, time: .shortened) ?? "")")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.3)))
        .onTapGesture(count: 2) { model.openLink(item) }
    }
}
