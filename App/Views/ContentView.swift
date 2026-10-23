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
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                if let error = model.startupError {
                    ContentUnavailableView(
                        "Database unavailable", systemImage: "exclamationmark.triangle",
                        description: Text(error))
                } else {
                    detail(selection ?? .today)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((selection ?? .today).title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // Plain lists for now; Phase 5 replaces them with the designed views.
    @ViewBuilder
    private func detail(_ section: SidebarSection) -> some View {
        let overview = model.overview
        switch section {
        case .today:
            TodayView()
        case .deadlines:
            ItemList(section: section, items: overview.openDeadlines, dateStyle: .due)
        case .announcements:
            ItemList(section: section, items: overview.announcements, dateStyle: .posted)
        case .materials:
            ItemList(section: section, items: overview.materials, dateStyle: .none)
        case .schedule:
            ScheduleView()
        }
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let overview = model.overview
        if overview.moodle?.status == .needsReconnect {
            ContentUnavailableView {
                Label("Moodle needs reconnecting", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            } description: {
                Text("The Moodle token stopped working. Reconnecting takes about 20 seconds.")
            } actions: {
                SettingsLink { Text("Open Settings") }
            }
        } else if overview.openDeadlines.isEmpty && overview.materials.isEmpty && overview.upcomingEvents.isEmpty {
            EmptySectionView(section: .today, message: "Connect Moodle in Settings to fill Today.")
        } else {
            List {
                Section("Next deadlines") {
                    ForEach(overview.openDeadlines.filter { ($0.date ?? .distantPast) > .now }.prefix(3)) { item in
                        ItemRowView(item: item, dateStyle: .due)
                    }
                }
                let soon = overview.upcomingEvents.filter { event in
                    guard let date = event.date else { return false }
                    let isLecture = event.section?.localizedCaseInsensitiveContains("lecture") == true
                        || event.section?.localizedCaseInsensitiveContains("vorlesung") == true
                    return (isLecture || event.isExam)
                        && date < Calendar.current.startOfDay(for: .now).addingTimeInterval(2 * 86_400)
                }
                if !soon.isEmpty {
                    Section("Today and tomorrow") {
                        ForEach(soon) { EventRowView(event: $0) }
                    }
                }
                Section("New since last visit") {
                    let newAnnouncements = overview.announcements.filter(\.isNew).count
                    let newMaterials = overview.materials.filter(\.isNew).count
                    Text("\(newAnnouncements) announcements, \(newMaterials) materials")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum DateStyle { case due, posted, none }

struct ItemList: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection
    let items: [PortalOverview.ItemRow]
    let dateStyle: DateStyle

    var body: some View {
        if items.isEmpty {
            EmptySectionView(section: section, message: "Connect Moodle in Settings to fill \(section.title).")
        } else {
            List(items) { item in
                ItemRowView(item: item, dateStyle: dateStyle)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { Task { await model.open(item) } }
                    .contextMenu {
                        if item.hasFile { Button("Open File") { Task { await model.open(item) } } }
                        Button(item.source == .cms ? "Open in CMS" : "Open in Moodle") { model.openLink(item) }
                    }
            }
        }
    }
}

struct ItemRowView: View {
    let item: PortalOverview.ItemRow
    let dateStyle: DateStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.course)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let section = item.section, dateStyle == .none {
                    Text(section).font(.caption).foregroundStyle(.secondary)
                }
            }
            if item.isNew {
                Circle().fill(.tint).frame(width: 6, height: 6)
            }
            Spacer()
            if let date = item.date, dateStyle != .none {
                Text(date, format: .relative(presentation: .named))
                    .font(.callout)
                    .foregroundStyle(dateStyle == .due && date < .now ? .red : .secondary)
            }
            if item.hasFile {
                Image(systemName: item.isCached ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .help(item.isCached ? "Saved on this Mac" : "Downloads on first open")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ScheduleView: View {
    @Environment(AppModel.self) private var model

    private var days: [(day: Date, events: [PortalOverview.ItemRow])] {
        let grouped = Dictionary(grouping: model.overview.upcomingEvents) {
            Calendar.current.startOfDay(for: $0.date ?? .distantPast)
        }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    var body: some View {
        if model.overview.upcomingEvents.isEmpty {
            EmptySectionView(section: .schedule, message: "Choose CMS courses in Settings to see their calendars.")
        } else {
            List {
                ForEach(days, id: \.day) { day in
                    Section(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                        ForEach(day.events) { event in
                            EventRowView(event: event)
                                .contextMenu {
                                    if let category = event.section {
                                        Button("Hide \(category) for \(event.course)") {
                                            model.setCategory(category, hidden: true, courseId: event.courseId)
                                        }
                                    }
                                    Button("Open in CMS") { model.openLink(event) }
                                }
                        }
                    }
                }
            }
        }
    }
}

struct EventRowView: View {
    let event: PortalOverview.ItemRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if event.allDay {
                    Text("All day")
                } else if let start = event.date {
                    Text(start, format: .dateTime.hour().minute())
                        + Text(event.endDate.map { "–" + $0.formatted(.dateTime.hour().minute()) } ?? "")
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                    if event.isExam {
                        Text("Exam").font(.caption.bold()).foregroundStyle(.tint)
                    }
                }
                Text([event.course, event.section, event.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct EmptySectionView: View {
    let section: SidebarSection
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: section.systemImage)
        } description: {
            Text(message)
        } actions: {
            SettingsLink { Text("Open Settings") }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
