import SwiftUI
import UniversityKit

/// One feed across Moodle and CMS, unread first, with the message on the right (like Mail).
struct AnnouncementsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int64?
    @State private var courseFilter: Int64?

    private var feed: [PortalOverview.ItemRow] {
        let all = model.overview.announcements.filter { courseFilter == nil || $0.courseId == courseFilter }
        return all.filter(\.isNew) + all.filter { !$0.isNew }
    }

    private var selected: PortalOverview.ItemRow? {
        model.overview.announcements.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if model.overview.announcements.isEmpty {
                EmptyState(title: "No Announcements", systemImage: "megaphone",
                           message: "News from Moodle and CMS courses appears here.")
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(feed) { item in
                            AnnouncementLine(item: item).tag(item.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)

                    Group {
                        if let selected {
                            AnnouncementReader(item: selected)
                        } else {
                            ContentUnavailableView("No Announcement Selected", systemImage: "megaphone")
                        }
                    }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.paper)
                }
                .onAppear { if selection == nil { selection = feed.first?.id } }
                .onChange(of: selection) {
                    if let selected, selected.isNew { model.setRead(selected, read: true) }
                }
            }
        }
        .navigationTitle("Announcements")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem { CoursePicker(courseIds: courseIds, selection: $courseFilter) }
            ToolbarItemGroup {
                Button { model.markAllRead(.announcement) } label: {
                    Label("Mark All as Read", systemImage: "envelope.open")
                }
                .help("Mark All as Read")
                .disabled(!model.overview.announcements.contains(where: \.isNew))
                Button { if let selected { model.setRead(selected, read: false) } } label: {
                    Label("Mark as Unread", systemImage: "envelope.badge")
                }
                .help("Mark as Unread")
                .disabled(selected == nil || selected?.isNew == true)
                Button { if let selected { model.openLink(selected) } } label: {
                    Label("Open Original", systemImage: "safari")
                }
                .help("Open in Moodle or CMS")
                .disabled(selected == nil)
            }
        }
    }

    private var subtitle: String {
        let unread = model.overview.announcements.filter(\.isNew).count
        return unread == 0 ? "\(model.overview.announcements.count) announcements" : "\(unread) unread"
    }

    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return model.overview.announcements.compactMap { seen.insert($0.courseId).inserted ? $0.courseId : nil }
    }
}

/// Mail's message row: unread dot, course and date, title, two lines of preview.
private struct AnnouncementLine: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UnreadDot(visible: item.isNew)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(style.name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    if let date = item.date {
                        Text(shortDate(date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(item.title).lineLimit(1)
                if let body = item.body, !body.isEmpty {
                    Text(body.replacingOccurrences(of: "\n", with: " "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(item.isNew ? "Mark as Read" : "Mark as Unread") { model.setRead(item, read: item.isNew) }
            Button("Open Original") { model.openLink(item) }
            Divider()
            Button("Go to \(style.name)") { model.selection = .course(item.courseId) }
        }
    }

    /// Mail's dates: time today, "Yesterday", the weekday this week, otherwise the date.
    private func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if date > Date.now.addingTimeInterval(-6 * 86_400) { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

private struct AnnouncementReader: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(style.color).frame(width: 8, height: 8)
                    Text([style.name, item.section].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                    Spacer(minLength: 12)
                    if let date = item.date { Text(date.formatted(date: .abbreviated, time: .shortened)).fixedSize() }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Divider().padding(.vertical, 6)
                Text(item.body ?? "")
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
