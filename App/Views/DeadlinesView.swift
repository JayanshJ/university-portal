import SwiftUI
import UniversityKit

/// Open deadlines by when they're due (Overdue, This Week, Next Week, then by month), a course
/// filter in the toolbar, and the last 30 days' done ones.
struct DeadlinesView: View {
    @Environment(AppModel.self) private var model
    @State private var courseFilter: Int64?
    @State private var showDone = false

    private func filtered(_ items: [PortalOverview.ItemRow]) -> [PortalOverview.ItemRow] {
        courseFilter.map { id in items.filter { $0.courseId == id } } ?? items
    }

    private var groups: [(title: String, items: [PortalOverview.ItemRow])] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)!
        let nextWeekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeek.end)!
        var order: [String] = []
        var buckets: [String: [PortalOverview.ItemRow]] = [:]
        for item in filtered(model.overview.openDeadlines) {
            let due = item.date ?? .distantFuture
            let key = due < .now ? "Overdue"
                : due < thisWeek.end ? "This Week"
                : due < nextWeekEnd ? "Next Week"
                : due.formatted(.dateTime.month(.wide).year())
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { ($0, buckets[$0]!) }
    }

    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return (model.overview.openDeadlines + model.overview.doneDeadlines).compactMap {
            seen.insert($0.courseId).inserted ? $0.courseId : nil
        }
    }

    var body: some View {
        let open = model.overview.openDeadlines
        Group {
            if open.isEmpty && model.overview.doneDeadlines.isEmpty {
                EmptyState(title: "No Deadlines", systemImage: "checklist",
                           message: "Moodle assignments and quizzes appear here once Moodle is connected.")
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.items) { DeadlineLine(item: $0, showsCourse: courseFilter == nil) }
                        } header: {
                            Text(group.title).foregroundStyle(group.title == "Overdue" ? Theme.overdue : .secondary)
                        }
                    }
                    let done = filtered(model.overview.doneDeadlines)
                    if !done.isEmpty {
                        Section("Done in the Last 30 Days", isExpanded: $showDone) {
                            ForEach(done) { DeadlineLine(item: $0, showsCourse: courseFilter == nil) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Deadlines")
        .navigationSubtitle(subtitle(open))
        .toolbar {
            ToolbarItem { CoursePicker(courseIds: courseIds, selection: $courseFilter) }
        }
    }

    private func subtitle(_ open: [PortalOverview.ItemRow]) -> String {
        let overdue = open.filter { ($0.date ?? .distantFuture) < .now }.count
        let week = open.filter { ($0.date ?? .distantFuture) < Date.now.addingTimeInterval(7 * 86_400) }.count - overdue
        var parts = ["\(open.count) open", "\(week) in the next 7 days"]
        if overdue > 0 { parts.insert("\(overdue) overdue", at: 0) }
        return parts.joined(separator: " · ")
    }
}
