import SwiftUI
import UniversityKit

/// Everything for one course: deadlines, the next events, news and recent materials.
struct CourseView: View {
    @Environment(AppModel.self) private var model
    let courseId: Int64

    var body: some View {
        let overview = model.overview
        let style = overview.style(for: courseId)
        let course = overview.courses.first { $0.id == courseId }
        let deadlines = overview.openDeadlines.filter { $0.courseId == courseId }
        let events = overview.upcomingEvents.filter { $0.courseId == courseId }.prefix(6)
        let news = overview.announcements.filter { $0.courseId == courseId }.prefix(5)
        let materials = overview.materials.filter { $0.courseId == courseId }
        let recent = materials.sorted { $0.firstSeenAt > $1.firstSeenAt }.prefix(6)

        List {
            Section("Open Deadlines") {
                if deadlines.isEmpty {
                    EmptyRow("Nothing open.")
                } else {
                    ForEach(deadlines) { DeadlineLine(item: $0, showsCourse: false) }
                }
            }
            if course?.source == .cms {
                Section("Coming Up") {
                    if events.isEmpty {
                        EmptyRow("No events in the next three weeks.")
                    } else {
                        ForEach(Array(events)) { EventLine(event: $0, showsDay: true, showsCourse: false) }
                    }
                }
            }
            Section {
                if news.isEmpty {
                    EmptyRow("No news.")
                } else {
                    ForEach(Array(news)) { item in
                        CompactLine(item: item, showsCourse: false,
                                    detail: item.date?.formatted(.relative(presentation: .named))) {
                            model.selection = .announcements
                        }
                    }
                }
            } header: {
                SectionHeader("Announcements", action: ("Show All", { model.selection = .announcements }))
            }
            Section {
                if recent.isEmpty {
                    EmptyRow("No materials.")
                } else {
                    ForEach(Array(recent)) { item in
                        CompactLine(item: item, showsCourse: false,
                                    detail: [item.section, item.fileSize.map(\.fileSizeText)].compactMap { $0 }.joined(separator: " · "),
                                    icon: true) {
                            model.materialsCourse = courseId
                            model.selection = .materials
                        }
                    }
                }
            } header: {
                SectionHeader("Recent Materials", action: ("Show All \(materials.count)", {
                    model.materialsCourse = courseId
                    model.selection = .materials
                }))
            }
        }
        .listStyle(.inset)
        .navigationTitle(style.name)
        .navigationSubtitle([course?.fullName == style.name ? nil : course?.fullName,
                             course?.source == .cms ? "CMS" : "Moodle",
                             course?.term.flatMap { term in course?.fullName.contains(term) == true ? nil : term }]
            .compactMap { $0 }.joined(separator: " · "))
    }
}
