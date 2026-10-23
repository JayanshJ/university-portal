import SwiftUI
import UniversityKit

/// A week of CMS calendar events and Moodle deadlines, one day after another.
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start
    @State private var items: [PortalOverview.ItemRow] = []

    private var days: [Date] {
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    var body: some View {
        List {
            ForEach(days, id: \.self) { day in
                let dayItems = items.filter { Calendar.current.isDate($0.date ?? .distantPast, inSameDayAs: day) }
                Section {
                    if dayItems.isEmpty {
                        Text("Nothing").foregroundStyle(.tertiary)
                    } else {
                        ForEach(dayItems) { EventRow(event: $0) }
                    }
                } header: {
                    Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .foregroundStyle(Calendar.current.isDateInToday(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
        }
        .frame(maxWidth: Layout.readingWidth + 160)
        .frame(maxWidth: .infinity)
        .toolbar {
            ControlGroup {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("Previous week")
                Button("This Week") {
                    weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start
                }
                Button { move(1) } label: { Image(systemName: "chevron.right") }.help("Next week")
            }
            Text(weekTitle).font(.headline)
        }
        .task(id: weekStart) { reload() }
        .onChange(of: model.overview) { reload() }
    }

    private var weekTitle: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        return "\(weekStart.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private func move(_ weeks: Int) {
        weekStart = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekStart)!
    }

    private func reload() {
        items = model.schedule(from: weekStart, to: Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!)
    }
}
