import SwiftUI
import UniversityKit

/// Every course's gradebook: each graded item with its grade, range and feedback, and the course total.
struct GradesView: View {
    @Environment(AppModel.self) private var model
    @State private var courseFilter: Int64?

    private var grades: [PortalOverview.ItemRow] {
        model.overview.grades.filter { courseFilter == nil || $0.courseId == courseFilter }
    }

    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return model.overview.grades.compactMap { seen.insert($0.courseId).inserted ? $0.courseId : nil }
    }

    var body: some View {
        Group {
            if model.overview.grades.isEmpty {
                EmptyState(title: "No Grades", systemImage: "rosette",
                           message: "Grades from your Moodle gradebooks appear here once they're given.", showsSettings: false)
            } else {
                List {
                    ForEach(courseIds.filter { courseFilter == nil || $0 == courseFilter }, id: \.self) { courseId in
                        let items = grades.filter { $0.courseId == courseId }
                        Section {
                            ForEach(items) { GradeLine(item: $0) }
                        } header: {
                            HStack(spacing: 6) {
                                Circle().fill(model.overview.style(for: courseId).color).frame(width: 8, height: 8)
                                Text(model.overview.style(for: courseId).name)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Grades")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem { CoursePicker(courseIds: courseIds, selection: $courseFilter) }
            ToolbarItem {
                Button { model.markAllRead(.grade) } label: { Label("Mark All as Seen", systemImage: "checkmark.circle") }
                    .help("Mark All as Seen")
                    .disabled(!model.overview.grades.contains(where: \.isNew))
            }
        }
    }

    private var subtitle: String {
        let graded = model.overview.grades.filter { $0.section != nil && $0.details["total"] == nil }.count
        let fresh = model.overview.grades.filter(\.isNew).count
        return ([graded == 1 ? "1 grade" : "\(graded) grades"] + (fresh > 0 ? ["\(fresh) new"] : [])).joined(separator: " · ")
    }
}

/// One gradebook row: name, then the grade over its range, with percentage and feedback.
struct GradeLine: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        let isTotal = item.details["total"] == "1"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UnreadDot(visible: item.isNew)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(isTotal ? .semibold : .regular)
                let meta = [item.details["weight"].map { "Weight \($0)" }, item.date.map { "Graded \($0.formatted(date: .abbreviated, time: .omitted))" }]
                    .compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if let feedback = item.body, !feedback.isEmpty {
                    Text(feedback).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if let grade = item.section {
                    Text(grade + (item.details["range"].map { " / \($0.components(separatedBy: "–").last ?? $0)" } ?? ""))
                        .font(.body.monospacedDigit().weight(.semibold))
                    if let percentage = item.details["percentage"] {
                        Text(percentage).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not graded").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if item.isNew { model.setRead(item, read: true) } }
        .contextMenu {
            Button("Open in Moodle") { model.openLink(item) }
            if item.isNew { Button("Mark as Seen") { model.setRead(item, read: true) } }
        }
    }
}
