import SwiftUI
import UniversityKit

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let upcoming = model.overview.openDeadlines.filter { ($0.date ?? .distantPast) > .now }.prefix(3)
        if model.overview.moodle?.status == .needsReconnect {
            Text("⚠︎ Moodle needs reconnecting")
        }
        if upcoming.isEmpty {
            Text(model.isMoodleConnected ? "No open deadlines" : "Nothing synced yet")
        } else {
            ForEach(upcoming) { item in
                Button("\(item.course): \(item.title) · \(item.date!.formatted(.relative(presentation: .named)))") {
                    model.openLink(item)
                }
            }
        }
        Divider()
        Button("Sync Now") { Task { await model.syncNow() } }
            .disabled(!model.isMoodleConnected || model.isSyncing)
        Button("Open University Portal") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
