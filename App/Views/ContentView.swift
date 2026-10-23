import SwiftUI
import UniversityKit

enum SidebarSection: String, CaseIterable, Identifiable {
    case today, deadlines, announcements, materials, schedule

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .deadlines: "checklist"
        case .announcements: "megaphone"
        case .materials: "doc.text"
        case .schedule: "calendar"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarSection? = .today

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(badge(for: section))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                if let error = model.startupError {
                    ContentUnavailableView("Database unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    switch selection ?? .today {
                    case .today: TodayView(go: { selection = $0 })
                    case .deadlines: DeadlinesView()
                    case .announcements: AnnouncementsView()
                    case .materials: MaterialsView()
                    case .schedule: ScheduleView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((selection ?? .today).title)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onChange(of: selection) { old, _ in
            // Leaving Today: what it showed as new has now been seen.
            if old == .today { model.markTodayVisited() }
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        let overview = model.overview
        return switch section {
        case .deadlines:
            overview.openDeadlines.filter { ($0.date ?? .distantFuture) < Date.now.addingTimeInterval(7 * 86_400) }.count
        case .announcements: overview.announcements.filter(\.isNew).count
        case .materials: overview.materials.filter(\.isNew).count
        case .today, .schedule: 0
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
