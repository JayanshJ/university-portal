import SwiftUI
import UniversityKit

/// One feed across Moodle and CMS, unread first, with the reader on the right.
struct AnnouncementsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int64?
    @State private var courseFilter: Int64?

    private var feed: [PortalOverview.ItemRow] {
        let all = model.overview.announcements.filter { courseFilter == nil || $0.courseId == courseFilter }
        return all.filter(\.isNew) + all.filter { !$0.isNew }
    }

    var body: some View {
        if model.overview.announcements.isEmpty {
            EmptyState(title: "No announcements", systemImage: "megaphone",
                       message: "News from Moodle and CMS courses appears here.")
        } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader("Announcements", subtitle: subtitle) {
                        Button("Mark all read") { model.markAllRead(.announcement) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .disabled(!model.overview.announcements.contains(where: \.isNew))
                    }
                    FilterBar(courseIds: courseIds, selection: $courseFilter)
                        .padding(.horizontal, Theme.gutter).padding(.bottom, 12)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(feed) { item in
                                AnnouncementLine(item: item, selected: item.id == selection)
                                    .onTapGesture { select(item) }
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                }
                .frame(width: 400)
                .background(Theme.canvas)

                Rectangle().fill(Theme.border).frame(width: 1)

                Group {
                    if let item = model.overview.announcements.first(where: { $0.id == selection }) {
                        AnnouncementReader(item: item)
                    } else {
                        EmptyState(title: "Select an announcement", systemImage: "megaphone",
                                   message: "Unread ones are at the top.", showsSettings: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)
            }
            .onAppear { if selection == nil { selection = feed.first?.id } }
        }
    }

    private var subtitle: String {
        let unread = model.overview.announcements.filter(\.isNew).count
        return "\(model.overview.announcements.count) total · \(unread) unread"
    }

    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return model.overview.announcements.compactMap { seen.insert($0.courseId).inserted ? $0.courseId : nil }
    }

    private func select(_ item: PortalOverview.ItemRow) {
        selection = item.id
        if item.isNew { model.setRead(item, read: true) }
    }
}

private struct AnnouncementLine: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    let selected: Bool

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(item.isNew ? Theme.accent : .clear).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CourseChip(style: style, compact: true)
                    Spacer()
                    if let date = item.date {
                        Text(date, format: .relative(presentation: .named))
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
                Text(item.title)
                    .font(.system(size: 13, weight: item.isNew ? .semibold : .medium))
                    .foregroundStyle(Theme.text).lineLimit(2)
                if let body = item.body, !body.isEmpty {
                    Text(body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
            }
        }
        .padding(10)
        .rowBackground(selected: selected)
        .contextMenu {
            Button(item.isNew ? "Mark as Read" : "Mark as Unread") { model.setRead(item, read: item.isNew) }
            Button("Open Original") { model.openLink(item) }
        }
    }
}

private struct AnnouncementReader: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CourseChip(style: style)
                Text(item.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let author = item.section { Text(author) }
                    if let date = item.date {
                        Text("·")
                        Text(date.formatted(date: .long, time: .shortened))
                    }
                    Text("·")
                    Text(item.source == .moodle ? "Moodle" : "CMS")
                }
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Rectangle().fill(Theme.border).frame(height: 1)
                Text(item.body ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text.opacity(0.92))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Button("Open original") { model.openLink(item) }
                    Button("Mark as unread") { model.setRead(item, read: false) }
                }
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}
