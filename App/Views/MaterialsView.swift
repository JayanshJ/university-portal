import SwiftUI
import UniversityKit

/// Files and links per course, grouped by section, with the viewer on the right.
struct MaterialsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Int64?
    @State private var search = ""

    private struct CourseGroup: Identifiable {
        var id: Int64
        var name: String
        var sections: [(name: String, items: [PortalOverview.ItemRow])]
    }

    private var groups: [CourseGroup] {
        let query = search.lowercased()
        var order: [Int64] = []
        var byCourse: [Int64: (name: String, sections: [String], items: [String: [PortalOverview.ItemRow]])] = [:]
        for item in model.overview.materials {
            if !query.isEmpty, !"\(item.title) \(item.filename ?? "") \(item.section ?? "")".lowercased().contains(query) { continue }
            let section = item.section ?? "Other"
            if byCourse[item.courseId] == nil {
                order.append(item.courseId)
                byCourse[item.courseId] = (item.courseFullName, [], [:])
            }
            if byCourse[item.courseId]!.items[section] == nil { byCourse[item.courseId]!.sections.append(section) }
            byCourse[item.courseId]!.items[section, default: []].append(item)
        }
        return order.map { id in
            let course = byCourse[id]!
            return CourseGroup(id: id, name: course.name, sections: course.sections.map { ($0, course.items[$0]!) })
        }
    }

    private func item(_ id: Int64?) -> PortalOverview.ItemRow? {
        model.overview.materials.first { $0.id == id }
    }

    var body: some View {
        if model.overview.materials.isEmpty {
            EmptySectionView(title: "No materials", systemImage: "doc.text",
                             message: "Moodle files and CMS materials (after signing in to CMS) appear here.")
        } else {
            HSplitView {
                List(selection: $selection) {
                    ForEach(groups) { course in
                        Section(course.name) {
                            ForEach(course.sections, id: \.name) { section in
                                Text(section.name).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                                ForEach(section.items) { item in
                                    MaterialRow(item: item).tag(item.id)
                                }
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: Int64.self) { ids in
                    if let item = item(ids.first) {
                        if item.hasFile {
                            Button("Open in New Window") { openWindow(id: "viewer", value: item.id) }
                        }
                        Button("Open Original") { model.openLink(item) }
                        Button(item.isNew ? "Mark as Read" : "Mark as Unread") { model.setRead(item, read: item.isNew) }
                    }
                } primaryAction: { ids in
                    // Double-click: a file in its own window, a link in the browser.
                    guard let item = item(ids.first) else { return }
                    if item.hasFile { openWindow(id: "viewer", value: item.id) } else { model.openLink(item) }
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Filter materials")
                .frame(minWidth: 260, idealWidth: 320)

                Group {
                    if let item = model.overview.materials.first(where: { $0.id == selection }) {
                        if item.hasFile {
                            FileViewer(item: item)
                        } else {
                            ContentUnavailableView {
                                Label(item.title, systemImage: "link")
                            } description: {
                                Text(item.url ?? "")
                            } actions: {
                                Button("Open Link") {
                                    model.openLink(item)
                                    model.setRead(item, read: true)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("Select a file", systemImage: "doc.text",
                                               description: Text("PDFs open here. Double-click to open one in its own window."))
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct MaterialRow: View {
    let item: PortalOverview.ItemRow

    private var icon: String {
        guard item.hasFile else { return "link" }
        let name = (item.filename ?? "").lowercased()
        if name.hasSuffix(".pdf") { return "doc.richtext" }
        if name.hasSuffix(".zip") { return "doc.zipper" }
        if name.hasSuffix(".mp4") || name.hasSuffix(".mov") { return "film" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(item.title).lineLimit(1)
            if item.isNew { NewDot() }
            Spacer(minLength: 4)
            if item.isCached {
                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.tertiary)
                    .help("Saved on this Mac")
            }
            SourceTag(source: item.source)
        }
    }
}
