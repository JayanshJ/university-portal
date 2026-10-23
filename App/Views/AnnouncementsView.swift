import SwiftUI
import UniversityKit

/// One feed across Moodle and CMS, unread first; selecting an announcement reads it.
struct AnnouncementsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int64?

    private var feed: [PortalOverview.ItemRow] {
        let all = model.overview.announcements
        return all.filter(\.isNew) + all.filter { !$0.isNew }
    }

    var body: some View {
        if model.overview.announcements.isEmpty {
            EmptySectionView(title: "No announcements", systemImage: "megaphone",
                             message: "News from Moodle and CMS courses appears here.")
        } else {
            HSplitView {
                List(feed, selection: $selection) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if item.isNew { NewDot() } else { Color.clear.frame(width: 6, height: 6) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).fontWeight(item.isNew ? .semibold : .regular).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(item.course)
                                if let date = item.date { Text(date, format: .relative(presentation: .named)) }
                            }
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        SourceTag(source: item.source)
                    }
                    .padding(.vertical, 2)
                    .tag(item.id)
                    .contextMenu {
                        Button(item.isNew ? "Mark as Read" : "Mark as Unread") { model.setRead(item, read: item.isNew) }
                        Button("Open Original") { model.openLink(item) }
                    }
                }
                .frame(minWidth: 280, idealWidth: 340)

                Group {
                    if let item = model.overview.announcements.first(where: { $0.id == selection }) {
                        AnnouncementDetail(item: item)
                    } else {
                        ContentUnavailableView("No announcement selected", systemImage: "megaphone")
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                Button("Mark All as Read") { model.markAllRead(.announcement) }
                    .disabled(!model.overview.announcements.contains(where: \.isNew))
            }
            .onChange(of: selection) { _, id in
                if let item = model.overview.announcements.first(where: { $0.id == id }), item.isNew {
                    model.setRead(item, read: true)
                }
            }
        }
    }
}

private struct AnnouncementDetail: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(item.courseFullName)
                    if let author = item.section { Text("·"); Text(author) }
                    if let date = item.date { Text("·"); Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
                .font(.callout).foregroundStyle(.secondary)
                Divider()
                Text(item.body ?? "")
                    .textSelection(.enabled)
                    .lineSpacing(3)
                HStack {
                    Button("Open Original") { model.openLink(item) }
                    Button("Mark as Unread") { model.setRead(item, read: false) }
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: Layout.readingWidth, alignment: .leading)
        }
    }
}
