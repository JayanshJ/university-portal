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

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(style.color).frame(width: 6, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course?.fullName ?? style.name)
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                        Text([course?.source == .cms ? "CMS" : "Moodle", course?.term, course.map { $0.externalId }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.gutter).padding(.top, 24).padding(.bottom, 18)

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        Card("Open deadlines") {
                            if deadlines.isEmpty {
                                quiet("Nothing open.")
                            } else {
                                VStack(spacing: 0) { ForEach(deadlines) { DeadlineLine(item: $0, showsCourse: false) } }
                                    .padding(.horizontal, 4).padding(.bottom, 6)
                            }
                        }
                        if course?.source == .cms {
                            Card("Coming up") {
                                if events.isEmpty {
                                    quiet("No events in the next three weeks.")
                                } else {
                                    VStack(spacing: 0) { ForEach(Array(events)) { EventLine(event: $0, showsDay: true, showsCourse: false) } }
                                        .padding(.horizontal, 4).padding(.bottom, 6)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)

                    VStack(spacing: 16) {
                        Card("Announcements", accessory: { link("All", .announcements) }) {
                            if news.isEmpty {
                                quiet("No news.")
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(news)) { item in
                                        CompactLine(item: item, showsCourse: false,
                                                    detail: item.date?.formatted(.relative(presentation: .named))) {
                                            model.selection = .announcements
                                        }
                                    }
                                }
                                .padding(.horizontal, 4).padding(.bottom, 6)
                            }
                        }
                        Card("Recent materials", accessory: {
                            Button("All \(materials.count)") {
                                model.materialsCourse = courseId
                                model.selection = .materials
                            }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }) {
                            if recent.isEmpty {
                                quiet("No materials.")
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(recent)) { item in
                                        CompactLine(item: item, showsCourse: false,
                                                    detail: [item.section, item.fileSize.map(\.fileSizeText)].compactMap { $0 }.joined(separator: " · ")) {
                                            model.materialsCourse = courseId
                                            model.selection = .materials
                                        }
                                    }
                                }
                                .padding(.horizontal, 4).padding(.bottom, 6)
                            }
                        }
                    }
                    .frame(width: 340)
                }
                .padding(.horizontal, Theme.gutter).padding(.bottom, Theme.gutter)
            }
            .frame(maxWidth: 1180, alignment: .leading)
        }
    }

    private func link(_ title: String, _ route: Route) -> some View {
        Button(title) { model.selection = route }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 2)
    }
}
