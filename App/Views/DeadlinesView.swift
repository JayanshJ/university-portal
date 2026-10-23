import SwiftUI
import UniversityKit

/// Open deadlines grouped by week, a course filter, and a collapsed "Done" group.
struct DeadlinesView: View {
    @Environment(AppModel.self) private var model
    @State private var courseFilter: Int64?
    @State private var showDone = false

    private func filtered(_ items: [PortalOverview.ItemRow]) -> [PortalOverview.ItemRow] {
        courseFilter.map { id in items.filter { $0.courseId == id } } ?? items
    }

    private var groups: [(title: String, items: [PortalOverview.ItemRow])] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)!.start
        var order: [String] = []
        var byTitle: [String: [PortalOverview.ItemRow]] = [:]
        for item in filtered(model.overview.openDeadlines) {
            let due = item.date ?? .distantFuture
            let title: String
            if due < .now {
                title = "Overdue"
            } else {
                let week = calendar.dateInterval(of: .weekOfYear, for: due)!.start
                let offset = calendar.dateComponents([.weekOfYear], from: thisWeek, to: week).weekOfYear ?? 0
                title = switch offset {
                case 0: "This week"
                case 1: "Next week"
                default: "Week of " + week.formatted(.dateTime.day().month(.wide))
                }
            }
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(item)
        }
        return order.map { ($0, byTitle[$0]!) }
    }

    private var courses: [(id: Int64, name: String)] {
        var seen = Set<Int64>()
        return (model.overview.openDeadlines + model.overview.doneDeadlines).compactMap { item in
            seen.insert(item.courseId).inserted ? (item.courseId, item.course) : nil
        }
    }

    var body: some View {
        Group {
            if model.overview.openDeadlines.isEmpty && model.overview.doneDeadlines.isEmpty {
                EmptySectionView(title: "No deadlines", systemImage: "checklist",
                                 message: "Moodle assignments and quizzes appear here once Moodle is connected.")
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { DeadlineRow(item: $0) }
                        }
                    }
                    let done = filtered(model.overview.doneDeadlines)
                    if !done.isEmpty {
                        Section {
                            DisclosureGroup("Done (\(done.count))", isExpanded: $showDone) {
                                ForEach(done) { DeadlineRow(item: $0) }
                            }
                        }
                    }
                }
                .frame(maxWidth: Layout.readingWidth + 160)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            Picker("Course", selection: $courseFilter) {
                Text("All courses").tag(Int64?.none)
                ForEach(courses, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}
