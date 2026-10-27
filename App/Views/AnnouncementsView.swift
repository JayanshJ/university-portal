import SwiftUI
import UniversityKit

/// Announcements (each course's news forum) or Forums (every other forum), unread first, with the
/// whole thread on the right (like Mail).
struct AnnouncementsView: View {
    @Environment(AppModel.self) private var model
    /// `.announcement` or `.discussion`.
    let kind: ItemKind
    @State private var selection: Int64?
    @State private var courseFilter: Int64?

    private var all: [PortalOverview.ItemRow] {
        kind == .announcement ? model.overview.announcements : model.overview.discussions
    }

    private var feed: [PortalOverview.ItemRow] {
        let shown = all.filter { courseFilter == nil || $0.courseId == courseFilter }
        let pinned = shown.filter { $0.details["pinned"] == "1" }
        let rest = shown.filter { $0.details["pinned"] != "1" }
        return pinned + rest.filter(\.isNew) + rest.filter { !$0.isNew }
    }

    private var selected: PortalOverview.ItemRow? {
        all.first { $0.id == selection }
    }

    private var title: String { kind == .announcement ? "Announcements" : "Forums" }

    var body: some View {
        Group {
            if all.isEmpty {
                EmptyState(title: kind == .announcement ? "No Announcements" : "No Forum Posts",
                           systemImage: kind == .announcement ? "megaphone" : "bubble.left.and.bubble.right",
                           message: kind == .announcement
                               ? "News from Moodle and CMS courses appears here."
                               : "Questions and discussions from your courses' Moodle forums appear here, with every reply.",
                           showsSettings: false)
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(feed) { item in
                            ThreadLine(item: item, showsForum: kind == .discussion).tag(item.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)

                    Group {
                        if let selected {
                            ThreadReader(item: selected)
                        } else {
                            ContentUnavailableView("Nothing Selected", systemImage: kind == .announcement ? "megaphone" : "bubble.left.and.bubble.right")
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
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem { CoursePicker(courseIds: courseIds, selection: $courseFilter) }
            ToolbarItemGroup {
                Button { model.markAllRead(kind) } label: {
                    Label("Mark All as Read", systemImage: "envelope.open")
                }
                .help("Mark All as Read")
                .disabled(!all.contains(where: \.isNew))
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
        let unread = all.filter(\.isNew).count
        let noun = kind == .announcement ? "announcement" : "thread"
        return unread == 0 ? "\(all.count) \(noun)\(all.count == 1 ? "" : "s")" : "\(unread) unread"
    }

    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return all.compactMap { seen.insert($0.courseId).inserted ? $0.courseId : nil }
    }
}

/// Mail's message row: unread dot, course (and forum) and date, title, two lines of preview, replies.
private struct ThreadLine: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    let showsForum: Bool

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        let replies = Int(item.details["replies"] ?? "") ?? 0
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UnreadDot(visible: item.isNew)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(style.name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    if let date = item.posts.last?.date ?? item.date {
                        Text(shortDate(date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    if item.details["pinned"] == "1" { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                    Text(item.title).lineLimit(1)
                }
                if let preview = item.posts.first?.text, !preview.isEmpty {
                    Text(preview.replacingOccurrences(of: "\n", with: " "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                let meta = [showsForum ? item.details["forum"] : nil,
                            replies > 0 ? (replies == 1 ? "1 reply" : "\(replies) replies") : nil].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
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

/// The thread: title, then each post with its author and date, replies set off below the first.
private struct ThreadReader: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow

    var body: some View {
        let style = model.overview.style(for: item.courseId)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(style.color).frame(width: 8, height: 8)
                    Text([style.name, item.details["forum"]].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ForEach(Array(item.posts.enumerated()), id: \.offset) { index, post in
                    if index == 1 {
                        Text(item.posts.count == 2 ? "1 Reply" : "\(item.posts.count - 1) Replies")
                            .font(.headline).padding(.top, 14)
                    }
                    PostView(post: post, isReply: index > 0)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PostView: View {
    let post: PortalOverview.ItemRow.Post
    let isReply: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(post.author ?? "Unknown").fontWeight(.semibold)
                Spacer()
                if let date = post.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Text(post.text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(isReply ? 14 : 0)
        .padding(.top, isReply ? 0 : 6)
        .background {
            if isReply { RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)) }
        }
        .overlay(alignment: .top) { if !isReply { Divider().offset(y: -4) } }
    }
}
