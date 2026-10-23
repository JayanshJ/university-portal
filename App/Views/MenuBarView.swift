import SwiftUI
import UniversityKit

/// The menu bar summary: reconnect warning, the next deadlines, what is new, and Sync Now.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let overview = model.overview
        let upcoming = overview.openDeadlines.filter { ($0.date ?? .distantPast) > .now }.prefix(3)
        let fresh = overview.newSinceVisit

        if overview.moodle?.status == .needsReconnect {
            Button("⚠︎ Moodle needs reconnecting…") { openSettingsWindow() }
        }
        if overview.cms?.status == .needsReconnect {
            Button("⚠︎ CMS sign-in failed…") { openSettingsWindow() }
        }

        Section("Next deadlines") {
            if upcoming.isEmpty {
                Text(model.isMoodleConnected ? "Nothing due" : "Moodle not connected")
            }
            ForEach(upcoming) { item in
                Button("\(item.course): \(item.title) — \(DueText.string(item.date!))") { model.openLink(item) }
            }
        }

        if !fresh.announcements.isEmpty || !fresh.materials.isEmpty {
            Section("New since last visit") {
                if !fresh.announcements.isEmpty { Button("\(fresh.announcements.count) announcements") { openMain() } }
                if !fresh.materials.isEmpty { Button("\(fresh.materials.count) materials") { openMain() } }
            }
        }

        Divider()
        if let changes = model.recentChanges, Date.now.timeIntervalSince(changes.at) < 3600 {
            Text("Last sync brought \(changes.new) new, \(changes.changed) changed")
        }
        Button(model.isSyncing ? "Syncing…" : "Sync Now") { Task { await model.syncNow() } }
            .disabled(model.isSyncing)
        Button("Open University Portal") { openMain() }
        Button("Settings…") { openSettingsWindow() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func openSettingsWindow() {
        openSettings()
        NSApp.activate()
    }
}
