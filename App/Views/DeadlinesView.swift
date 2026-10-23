import SwiftUI
import UniversityKit

/// Open deadlines in four groups (Overdue, This week, Next week, Later), a course filter, and Done.
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
        var buckets: [String: [PortalOverview.ItemRow]] = [:]
        for item in filtered(model.overview.openDeadlines) {
            let due = item.date ?? .distantFuture
            let key = due < .now ? "Overdue" : due < thisWeek.end ? "This week" : due < nextWeekEnd ? "Next week" : "Later"
            buckets[key, default: []].append(item)
        }
        return ["Overdue", "This week", "Next week", "Later"].compactMap { key in buckets[key].map { (key, $0) } }
    }

    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return (model.overview.openDeadlines + model.overview.doneDeadlines).compactMap {
            seen.insert($0.courseId).inserted ? $0.courseId : nil
        }
    }

    var body: some View {
        let open = model.overview.openDeadlines
        if open.isEmpty && model.overview.doneDeadlines.isEmpty {
            EmptyState(title: "No deadlines", systemImage: "checklist",
                       message: "Moodle assignments and quizzes appear here once Moodle is connected.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader("Deadlines", subtitle: subtitle(open))
                    FilterBar(courseIds: courseIds, selection: $courseFilter)
                        .padding(.horizontal, Theme.gutter).padding(.bottom, 16)

                    VStack(spacing: 16) {
                        ForEach(groups, id: \.title) { group in
                            Card(group.title, accessory: {
                                Text("\(group.items.count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                        // "Later" spans months: label each month where it starts.
                                        if group.title == "Later", let month = monthLabel(item, previous: index > 0 ? group.items[index - 1] : nil) {
                                            Text(month).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                                                .padding(.horizontal, 12).padding(.top, index == 0 ? 2 : 12).padding(.bottom, 2)
                                        }
                                        DeadlineLine(item: item)
                                    }
                                }
                                .padding(.horizontal, 4).padding(.bottom, 6)
                            }
                        }
                        let done = filtered(model.overview.doneDeadlines)
                        if !done.isEmpty {
                            Card {
                                VStack(alignment: .leading, spacing: 0) {
                                    Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                                        HStack {
                                            Image(systemName: "chevron.right").rotationEffect(.degrees(showDone ? 90 : 0))
                                            SectionLabel("Done in the last 30 days")
                                            Spacer()
                                            Text("\(done.count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                        }
                                        .foregroundStyle(Theme.tertiary)
                                        .padding(14)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if showDone {
                                        VStack(spacing: 0) { ForEach(done) { DeadlineLine(item: $0) } }
                                            .padding(.horizontal, 4).padding(.bottom, 6)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.gutter).padding(.bottom, Theme.gutter)
                }
                .frame(maxWidth: 920, alignment: .leading)
            }
        }
    }

    private func monthLabel(_ item: PortalOverview.ItemRow, previous: PortalOverview.ItemRow?) -> String? {
        guard let date = item.date else { return nil }
        if let previous = previous?.date, Calendar.current.isDate(previous, equalTo: date, toGranularity: .month) { return nil }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private func subtitle(_ open: [PortalOverview.ItemRow]) -> String {
        let overdue = open.filter { ($0.date ?? .distantFuture) < .now }.count
        let week = open.filter { ($0.date ?? .distantFuture) < Date.now.addingTimeInterval(7 * 86_400) }.count - overdue
        var parts = ["\(open.count) open", "\(week) in the next 7 days"]
        if overdue > 0 { parts.insert("\(overdue) overdue", at: 0) }
        return parts.joined(separator: " · ")
    }
}

/// "All" plus one chip per course, in course colours.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    let courseIds: [Int64]
    @Binding var selection: Int64?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil, title: "All courses", color: nil)
                ForEach(courseIds, id: \.self) { id in
                    let style = model.overview.style(for: id)
                    chip(id, title: style.name, color: style.color)
                }
            }
        }
    }

    private func chip(_ id: Int64?, title: String, color: Color?) -> some View {
        let selected = selection == id
        return Button { selection = id } label: {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Theme.raised : .clear))
            .overlay(Capsule().stroke(selected ? Theme.border : Theme.border.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}
