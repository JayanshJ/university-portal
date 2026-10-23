import SwiftUI
import UniversityKit

/// Where the main window is: one of the sections, or a course's page.
enum Route: Hashable {
    case today, ask, deadlines, announcements, materials, schedule
    case course(Int64)

    static let sections: [Route] = [.today, .ask, .deadlines, .announcements, .materials, .schedule]

    var title: String {
        switch self {
        case .today: "Today"
        case .ask: "Ask"
        case .deadlines: "Deadlines"
        case .announcements: "Announcements"
        case .materials: "Materials"
        case .schedule: "Schedule"
        case .course: "Course"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .ask: "sparkles"
        case .deadlines: "checklist"
        case .announcements: "megaphone"
        case .materials: "folder"
        case .schedule: "calendar"
        case .course: "book.closed"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let route = model.selection
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 244)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                if let error = model.startupError {
                    EmptyState(title: "Database unavailable", systemImage: "exclamationmark.triangle", message: error)
                } else {
                    switch route {
                    case .today: TodayView()
                    case .ask: AskView()
                    case .deadlines: DeadlinesView()
                    case .announcements: AnnouncementsView()
                    case .materials: MaterialsView()
                    case .schedule: ScheduleView()
                    case .course(let id): CourseView(courseId: id)
                    }
                }
            }
            .pageBackground()
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .frame(minWidth: 960, minHeight: 600)
        .onChange(of: route) { old, _ in
            // Leaving Today: what it showed as new has now been seen.
            if old == .today { model.markTodayVisited() }
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private var courses: [PortalOverview.CourseRow] {
        model.overview.courses.filter(\.active)
            .sorted { ($0.source == .moodle ? 0 : 1, $0.id) < ($1.source == .moodle ? 0 : 1, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Color.clear.frame(height: 44)  // room for the window buttons
                    ForEach(Route.sections, id: \.self) { route in
                        SidebarRow(route: route, title: route.title, count: count(route)) {
                            Image(systemName: route.systemImage)
                                .font(.system(size: 13))
                                .frame(width: 18)
                                .foregroundStyle(model.selection == route ? Theme.text : Theme.secondary)
                        }
                    }

                    if !courses.isEmpty {
                        SectionLabel("Courses").padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 6)
                        ForEach(courses) { course in
                            let style = model.overview.style(for: course.id)
                            SidebarRow(route: .course(course.id), title: style.name,
                                       count: model.overview.openDeadlines.filter { $0.courseId == course.id }.count) {
                                Circle().fill(style.color).frame(width: 8, height: 8).frame(width: 18)
                            }
                            .help(course.fullName)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            SyncFooter()
        }
        .background(Theme.panel)
    }

    private func count(_ route: Route) -> Int {
        let overview = model.overview
        return switch route {
        case .deadlines:
            overview.openDeadlines.filter { ($0.date ?? .distantFuture) < Date.now.addingTimeInterval(7 * 86_400) }.count
        case .announcements: overview.announcements.filter(\.isNew).count
        case .materials: overview.materials.filter(\.isNew).count
        default: 0
        }
    }
}

private struct SidebarRow<Icon: View>: View {
    @Environment(AppModel.self) private var model
    let route: Route
    let title: String
    let count: Int
    @ViewBuilder let icon: Icon

    var body: some View {
        let selected = model.selection == route
        Button { model.selection = route } label: {
            HStack(spacing: 8) {
                icon
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .rowBackground(selected: selected)
        }
        .buttonStyle(.plain)
    }
}

/// Last sync, a sync button and settings, always visible.
private struct SyncFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let overview = model.overview
        let synced = [overview.moodle?.lastSyncAt, overview.cms?.lastSyncAt].compactMap { $0 }.max()
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, -12)
            if overview.needsReconnect {
                Button { model.selection = .today } label: {
                    Label(overview.moodle?.status == .needsReconnect ? "Moodle needs reconnecting" : "CMS sign-in failed",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.overdue)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isSyncing ? "Syncing…" : "Synced")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    if let synced, !model.isSyncing {
                        Text(synced, format: .relative(presentation: .named))
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
                Spacer()
                Button { Task { await model.syncNow() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .disabled(model.isSyncing)
                .help("Sync now")
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Settings")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
