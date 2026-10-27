import SwiftUI
import UniversityKit

/// Where the main window is: one of the sections, or a course's page.
enum Route: Hashable {
    case today, ask, deadlines, announcements, forums, messages, grades, materials, schedule
    case course(Int64)

    static let sections: [Route] = [.today, .ask, .deadlines, .announcements, .forums, .messages, .grades, .materials, .schedule]

    var title: String {
        switch self {
        case .today: "Today"
        case .ask: "Ask"
        case .deadlines: "Deadlines"
        case .announcements: "Announcements"
        case .forums: "Forums"
        case .messages: "Messages"
        case .grades: "Grades"
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
        case .forums: "bubble.left.and.bubble.right"
        case .messages: "message"
        case .grades: "rosette"
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
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            Group {
                if let error = model.startupError {
                    EmptyState(title: "Database Unavailable", systemImage: "exclamationmark.triangle", message: error)
                } else {
                    switch route {
                    case .today: TodayView()
                    case .ask: AskView()
                    case .deadlines: DeadlinesView()
                    case .announcements: AnnouncementsView(kind: .announcement)
                    case .forums: AnnouncementsView(kind: .discussion)
                    case .messages: MessagesView()
                    case .grades: GradesView()
                    case .materials: MaterialsView()
                    case .schedule: ScheduleView()
                    case .course(let id): CourseView(courseId: id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: Binding(get: { model.submitting }, set: { model.submitting = $0 })) { target in
            if let service = model.submissions() {
                SubmissionView(model: SubmissionModel(cmid: target.cmid, service: service),
                               item: model.overview.openDeadlines.first { $0.id == target.itemId }
                                   ?? model.overview.doneDeadlines.first { $0.id == target.itemId })
            } else {
                ContentUnavailableView {
                    Label("Moodle Isn't Connected", systemImage: "link")
                } description: {
                    Text("Connect Moodle in Settings to hand in assignments from here.")
                } actions: {
                    Button("Close") { model.submitting = nil }
                }
                .frame(width: 420, height: 260)
            }
        }
        .onChange(of: route) { old, _ in
            // Leaving Today: what it showed as new has now been seen.
            if old == .today { model.markTodayVisited() }
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<Route?>(get: { model.selection }, set: { if let route = $0 { model.selection = route } })
        List(selection: selection) {
            Section {
                ForEach(Route.sections, id: \.self) { route in
                    Label(route.title, systemImage: route.systemImage)
                        .badge(count(route))
                        .tag(route)
                }
            }
            let courses = model.overview.activeCourses
            if !courses.isEmpty {
                Section("Courses") {
                    ForEach(courses) { course in
                        let style = model.overview.style(for: course.id)
                        Label(style.name, systemImage: "book.closed.fill")
                            .badge(model.overview.openDeadlines.filter { $0.courseId == course.id }.count)
                            .listItemTint(style.color)
                            .tag(Route.course(course.id))
                            .help(course.fullName)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatus() }
    }

    private func count(_ route: Route) -> Int {
        let overview = model.overview
        return switch route {
        case .deadlines:
            overview.openDeadlines.filter { ($0.date ?? .distantFuture) < Date.now.addingTimeInterval(7 * 86_400) }.count
        case .announcements: overview.announcements.filter(\.isNew).count
        case .forums: overview.discussions.filter(\.isNew).count
        case .messages: overview.conversations.map(\.unreadCount).reduce(0, +)
        case .grades: overview.grades.filter(\.isNew).count
        case .materials: overview.materials.filter(\.isNew).count
        default: 0
        }
    }
}

/// Mail's "Updated Just Now" line at the bottom of the sidebar, with Sync Now.
private struct SyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let overview = model.overview
        let synced = [overview.moodle?.lastSyncAt, overview.cms?.lastSyncAt].compactMap { $0 }.max()
        HStack(spacing: 6) {
            if overview.needsReconnect {
                SettingsLink {
                    Label(overview.moodle?.status == .needsReconnect ? "Reconnect Moodle…" : "Sign in to CMS…",
                          systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
            } else if model.isSyncing {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            } else if let synced {
                Text("Updated \(synced.formatted(.relative(presentation: .named)))")
            }
            Spacer(minLength: 0)
            Button { Task { await model.syncNow() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isSyncing)
            .help("Sync Now")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
