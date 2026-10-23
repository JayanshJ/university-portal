import SwiftUI
import UniversityKit

/// A course's files by section, Finder-style, with the selected file previewed on the right.
/// The toolbar picks the course and searches all files.
struct MaterialsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Int64?
    @State private var search = ""
    @State private var collapsed: Set<String> = []

    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return model.overview.materials.compactMap { seen.insert($0.courseId).inserted ? $0.courseId : nil }
    }

    private var courseId: Int64? { model.materialsCourse ?? courseIds.first }

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private var visible: [PortalOverview.ItemRow] {
        model.overview.materials.filter { item in
            if !query.isEmpty {
                return "\(item.title) \(item.filename ?? "") \(item.section ?? "")".lowercased().contains(query)
            }
            return item.courseId == courseId
        }
    }

    /// Sections of the course, or courses when searching.
    private var sections: [(name: String, items: [PortalOverview.ItemRow])] {
        var order: [String] = []
        var byName: [String: [PortalOverview.ItemRow]] = [:]
        for item in visible {
            let name = query.isEmpty ? (item.section ?? "Other") : model.overview.style(for: item.courseId).name
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(item)
        }
        return order.map { ($0, byName[$0]!) }
    }

    var body: some View {
        Group {
            if model.overview.materials.isEmpty {
                EmptyState(title: "No Materials", systemImage: "folder",
                           message: "Moodle files and CMS materials (after signing in to CMS) appear here.")
            } else {
                HSplitView {
                    fileList.frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
                    viewer.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Materials")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search All Files")
        .toolbar {
            ToolbarItem {
                Picker("Course", selection: Binding(get: { courseId }, set: { model.materialsCourse = $0; search = "" })) {
                    ForEach(courseIds, id: \.self) { id in
                        let fresh = model.overview.materials.filter { $0.courseId == id && $0.isNew }.count
                        Text(model.overview.style(for: id).name + (fresh > 0 ? " (\(fresh) new)" : "")).tag(Int64?.some(id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .disabled(!query.isEmpty)
                .help("Choose a course")
            }
        }
    }

    private var subtitle: String {
        let files = visible.filter(\.hasFile).count
        let links = visible.count - files
        let counts = [files == 1 ? "1 file" : "\(files) files", links == 0 ? nil : links == 1 ? "1 link" : "\(links) links"]
            .compactMap { $0 }.joined(separator: ", ")
        return query.isEmpty ? counts : "\(visible.count) results"
    }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(sections, id: \.name) { section in
                Section(isExpanded: Binding(
                    get: { !collapsed.contains(section.name) },
                    set: { if $0 { collapsed.remove(section.name) } else { collapsed.insert(section.name) } }
                )) {
                    ForEach(section.items) { MaterialLine(item: $0).tag($0.id) }
                } header: {
                    Text(section.name).lineLimit(1)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let item = material(ids.first) {
                if item.hasFile { Button("Open in New Window") { open(item) } }
                Button("Open Original") { model.openLink(item) }
                Button(item.isNew ? "Mark as Read" : "Mark as Unread") { model.setRead(item, read: item.isNew) }
            }
        } primaryAction: { ids in
            if let item = material(ids.first) { open(item) }
        }
        .overlay {
            if visible.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: search) }
        }
    }

    private func material(_ id: Int64?) -> PortalOverview.ItemRow? {
        id.flatMap { id in model.overview.materials.first { $0.id == id } }
    }

    private func open(_ item: PortalOverview.ItemRow) {
        if item.hasFile { openWindow(id: "viewer", value: ViewerTarget(itemId: item.id)) } else { model.openLink(item) }
    }

    @ViewBuilder
    private var viewer: some View {
        if let item = material(selection) {
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
            ContentUnavailableView("No File Selected", systemImage: "doc",
                                   description: Text("PDFs open here. Double-click a file to open it in its own window."))
        }
    }
}

private struct MaterialLine: View {
    let item: PortalOverview.ItemRow

    private var kind: String {
        guard item.hasFile else { return "Link" }
        let ext = ((item.filename ?? item.title) as NSString).pathExtension.lowercased()
        return switch ext {
        case "pdf": "PDF"
        case "mp4", "mov", "m4v": "Video"
        case "pptx", "ppt", "key": "Slides"
        case "docx", "doc": "Word"
        default: ext.isEmpty ? "File" : ext.uppercased()
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(filename: item.hasFile ? (item.filename ?? item.title) : nil, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text([kind, item.fileSize.map(\.fileSizeText)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.hasFile && !item.isCached {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).help("Downloads when opened")
            }
            UnreadDot(visible: item.isNew)
        }
        .padding(.vertical, 1)
    }
}
