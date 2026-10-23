import SwiftUI
import UniversityKit

/// Three columns: courses, the chosen course's sections and files, and the viewer.
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

    private var visible: [PortalOverview.ItemRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.overview.materials.filter { item in
            if !query.isEmpty {
                return "\(item.title) \(item.filename ?? "") \(item.section ?? "")".lowercased().contains(query)
            }
            return item.courseId == courseId
        }
    }

    private var sections: [(name: String, items: [PortalOverview.ItemRow])] {
        var order: [String] = []
        var byName: [String: [PortalOverview.ItemRow]] = [:]
        for item in visible {
            let name = search.isEmpty ? (item.section ?? "Other") : model.overview.style(for: item.courseId).name
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(item)
        }
        return order.map { ($0, byName[$0]!) }
    }

    var body: some View {
        if model.overview.materials.isEmpty {
            EmptyState(title: "No materials", systemImage: "folder",
                       message: "Moodle files and CMS materials (after signing in to CMS) appear here.")
        } else {
            HStack(spacing: 0) {
                courseColumn.frame(width: 230)
                Rectangle().fill(Theme.border).frame(width: 1)
                fileColumn.frame(width: 360)
                Rectangle().fill(Theme.border).frame(width: 1)
                viewer.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panel)
            }
        }
    }

    private var courseColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Materials")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField("Search all files", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .padding(.horizontal, 14).padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(courseIds, id: \.self) { id in
                        let style = model.overview.style(for: id)
                        let items = model.overview.materials.filter { $0.courseId == id }
                        let fresh = items.filter(\.isNew).count
                        Button {
                            search = ""
                            model.materialsCourse = id
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(style.color).frame(width: 8, height: 8)
                                Text(style.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer(minLength: 4)
                                if fresh > 0 { Pill(text: "\(fresh) new") }
                                Text("\(items.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .rowBackground(selected: search.isEmpty && id == courseId)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .background(Theme.canvas)
    }

    private var fileColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            let title = search.isEmpty ? (courseId.map { model.overview.style(for: $0).name } ?? "") : "Results"
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(visible.filter(\.hasFile).count) files · \(visible.filter { !$0.hasFile }.count) links")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.name) { section in
                        Button {
                            if collapsed.contains(section.name) { collapsed.remove(section.name) } else { collapsed.insert(section.name) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(collapsed.contains(section.name) ? 0 : 90))
                                Text(section.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text("\(section.items.count)").font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !collapsed.contains(section.name) {
                            ForEach(section.items) { item in
                                MaterialLine(item: item, selected: item.id == selection)
                                    .onTapGesture(count: 2) {
                                        if item.hasFile { openWindow(id: "viewer", value: ViewerTarget(itemId: item.id)) } else { model.openLink(item) }
                                    }
                                    .onTapGesture { selection = item.id }
                                    .contextMenu {
                                        if item.hasFile { Button("Open in New Window") { openWindow(id: "viewer", value: ViewerTarget(itemId: item.id)) } }
                                        Button("Open Original") { model.openLink(item) }
                                        Button(item.isNew ? "Mark as Read" : "Mark as Unread") { model.setRead(item, read: item.isNew) }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 14)
            }
        }
        .background(Theme.canvas)
    }

    @ViewBuilder
    private var viewer: some View {
        if let item = model.overview.materials.first(where: { $0.id == selection }) {
            if item.hasFile {
                FileViewer(item: item)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "link").font(.system(size: 28)).foregroundStyle(Theme.tertiary)
                    Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    Text(item.url ?? "").font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(2)
                    Button("Open link") {
                        model.openLink(item)
                        model.setRead(item, read: true)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            EmptyState(title: "Select a file", systemImage: "doc.text",
                       message: "PDFs open here. Double-click to open one in its own window.", showsSettings: false)
        }
    }
}

private struct MaterialLine: View {
    let item: PortalOverview.ItemRow
    let selected: Bool

    private var kind: (icon: String, label: String) {
        guard item.hasFile else { return ("link", "Link") }
        let ext = ((item.filename ?? item.title) as NSString).pathExtension.lowercased()
        return switch ext {
        case "pdf": ("doc.richtext", "PDF")
        case "zip": ("doc.zipper", "ZIP")
        case "mp4", "mov", "m4v": ("film", "Video")
        case "pptx", "ppt", "key": ("rectangle.on.rectangle", "Slides")
        case "docx", "doc": ("doc.text", "Word")
        case "ipynb", "py", "java", "c", "sml": ("chevron.left.forwardslash.chevron.right", ext.uppercased())
        default: ("doc", ext.isEmpty ? "File" : ext.uppercased())
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                Text([kind.label, item.fileSize.map(\.fileSizeText), item.isCached ? "on this Mac" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
            if item.isNew { NewDot() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .rowBackground(selected: selected)
    }
}
