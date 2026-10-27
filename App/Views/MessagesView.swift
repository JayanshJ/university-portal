import SwiftUI
import UniversityKit

/// Moodle direct messages, like Messages: conversations on the left, the chat on the right.
/// Read-only; replies happen in Moodle.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int64?

    private var conversations: [UniConversation] { model.overview.conversations }

    var body: some View {
        Group {
            if conversations.isEmpty {
                EmptyState(title: "No Messages", systemImage: "message",
                           message: "Direct messages from Moodle appear here.", showsSettings: false)
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(conversations) { conversation in
                            ConversationLine(conversation: conversation).tag(conversation.id!)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)

                    Group {
                        if let conversation = conversations.first(where: { $0.id == selection }) {
                            ChatView(conversation: conversation)
                        } else {
                            ContentUnavailableView("No Conversation Selected", systemImage: "message")
                        }
                    }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.paper)
                }
                .onAppear { if selection == nil { selection = conversations.first?.id } }
            }
        }
        .navigationTitle("Messages")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    if let url = conversations.first(where: { $0.id == selection })?.url.flatMap(URL.init(string:)) {
                        NSWorkspace.shared.open(url)
                    }
                } label: { Label("Reply in Moodle", systemImage: "arrowshape.turn.up.left") }
                    .help("Reply in Moodle")
                    .disabled(selection == nil)
            }
        }
    }

    private var subtitle: String {
        let unread = conversations.map(\.unreadCount).reduce(0, +)
        return unread > 0 ? "\(unread) unread" : "\(conversations.count) conversation\(conversations.count == 1 ? "" : "s")"
    }
}

private struct ConversationLine: View {
    let conversation: UniConversation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UnreadDot(visible: conversation.unreadCount > 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    if let date = conversation.lastMessageAt {
                        Text(date.formatted(date: .numeric, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let last = conversation.messages.last {
                    Text((last.mine ? "You: " : "") + last.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Bubbles: yours on the right in the accent colour, theirs on the left; the author above in group chats.
private struct ChatView: View {
    let conversation: UniConversation

    var body: some View {
        let group = Set(conversation.messages.filter { !$0.mine }.map(\.author)).count > 1
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? conversation.messages[index - 1] : nil
                        if previous.map({ message.sentAt.timeIntervalSince($0.sentAt) > 3600 }) ?? true {
                            Text(message.sentAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                        }
                        HStack {
                            if message.mine { Spacer(minLength: 80) }
                            VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
                                if group && !message.mine && previous?.author != message.author {
                                    Text(message.author).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                                }
                                Text(message.text)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .foregroundStyle(message.mine ? Color.white : Color.primary)
                                    .background(RoundedRectangle(cornerRadius: 16)
                                        .fill(message.mine ? Color.accentColor : Color.secondary.opacity(0.15)))
                            }
                            if !message.mine { Spacer(minLength: 80) }
                        }
                        .id(message.id)
                    }
                }
                .padding(20)
            }
            .onAppear { proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom) }
            .onChange(of: conversation.id) { proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom) }
        }
    }
}
