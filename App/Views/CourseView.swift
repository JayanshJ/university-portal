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
        let notes = overview.notes.filter { $0.courseId == courseId }
        let grades = overview.grades.filter { $0.courseId == courseId && ($0.section != nil || $0.details["total"] == "1") }
        let threads = overview.discussions.filter { $0.courseId == courseId }.prefix(5)

        List {
            if !notes.isEmpty {
                Section("Course Page") {
                    ForEach(notes) { CourseNote(item: $0) }
                }
            }
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
            if !threads.isEmpty {
                Section {
                    ForEach(Array(threads)) { item in
                        CompactLine(item: item, showsCourse: false,
                                    detail: [item.details["forum"], (Int(item.details["replies"] ?? "") ?? 0) > 0 ? "\(item.details["replies"]!) replies" : nil]
                                        .compactMap { $0 }.joined(separator: " · ")) {
                            model.selection = .forums
                        }
                    }
                } header: {
                    SectionHeader("Forums", action: ("Show All", { model.selection = .forums }))
                }
            }
            if !grades.isEmpty {
                Section {
                    ForEach(grades) { GradeLine(item: $0) }
                } header: {
                    SectionHeader("Grades", action: ("Show All", { model.selection = .grades }))
                }
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

/// A piece of course page text: its heading (none for a text block), the section it's in, and the
/// text, folded after a few lines.
private struct CourseNote: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    @State private var expanded = false

    var body: some View {
        let text = item.body ?? ""
        let long = text.count > 320 || text.filter { $0 == "\n" }.count > 4
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if !item.title.isEmpty { Text(item.title).fontWeight(.semibold) }
                if let section = item.section, section != item.title {
                    Text(section).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                UnreadDot(visible: item.isNew)
            }
            Text(text)
                .lineLimit(expanded || !long ? nil : 4)
                .textSelection(.enabled)
                .foregroundStyle(item.title.isEmpty ? .primary : .secondary)
            if long {
                Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
        .onAppear { if item.isNew { model.setRead(item, read: true) } }
        .contextMenu { Button("Open in Moodle") { model.openLink(item) } }
    }
}
