import SwiftUI
import UniversityKit

/// One list for the day: what is due, where to be, exams ahead, and what is new.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    private var overview: PortalOverview { model.overview }

    private var dueSoon: [PortalOverview.ItemRow] {
        let horizon = Date.now.addingTimeInterval(7 * 86_400)
        let overdue = overview.openDeadlines.filter { ($0.date ?? .distantFuture) < .now }
        let upcoming = overview.openDeadlines.filter { ($0.date ?? .distantPast) >= .now && $0.date! < horizon }
        return overdue + upcoming.prefix(5)
    }

    private var todayAndTomorrow: [PortalOverview.ItemRow] {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(2 * 86_400)
        return overview.upcomingEvents.filter { event in
            guard let start = event.date, start < end else { return false }
            return (event.endDate ?? start) >= .now || event.allDay
        }
    }

    private var exams: [PortalOverview.ItemRow] {
        Array(model.schedule(from: .now, to: Date.now.addingTimeInterval(200 * 86_400)).filter(\.isExam).prefix(4))
    }

    private var summary: String {
        let dueThisWeek = overview.openDeadlines.filter { ($0.date ?? .distantFuture) < Date.now.addingTimeInterval(7 * 86_400) }.count
        let today = todayAndTomorrow.filter { Calendar.current.isDateInToday($0.date ?? .distantPast) }.count
        return [
            Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)),
            dueThisWeek == 1 ? "1 deadline this week" : "\(dueThisWeek) deadlines this week",
            today == 0 ? "nothing scheduled today" : today == 1 ? "1 event today" : "\(today) events today",
        ].joined(separator: " · ")
    }

    var body: some View {
        List {
            if overview.needsReconnect {
                Section { ReconnectBanner() }
            }

            Section {
                if dueSoon.isEmpty {
                    EmptyRow("Nothing due in the next 7 days.")
                } else {
                    ForEach(dueSoon) { DeadlineLine(item: $0) }
                }
            } header: {
                SectionHeader("Due Soon", action: ("Show All", { model.selection = .deadlines }))
            }

            Section {
                if todayAndTomorrow.isEmpty {
                    EmptyRow("No lectures, tutorials or exams.")
                } else {
                    ForEach(todayAndTomorrow) { EventLine(event: $0, showsDay: true) }
                }
            } header: {
                SectionHeader("Today and Tomorrow", action: ("Show Week", { model.selection = .schedule }))
            }

            let latest = overview.announcements.prefix(4)
            Section {
                if latest.isEmpty {
                    EmptyRow("No announcements yet.")
                } else {
                    ForEach(Array(latest)) { item in
                        CompactLine(item: item, detail: item.date?.formatted(.relative(presentation: .named))) {
                            model.selection = .announcements
                        }
                    }
                }
            } header: {
                SectionHeader("Announcements", action: ("Show All", { model.selection = .announcements }))
            }

            let freshMaterials = overview.newSinceVisit.materials
            if !freshMaterials.isEmpty {
                Section {
                    ForEach(freshMaterials.prefix(5)) { item in
                        CompactLine(item: item, detail: item.section, icon: true) {
                            model.materialsCourse = item.courseId
                            model.selection = .materials
                        }
                    }
                } header: {
                    SectionHeader(freshMaterials.count > 5 ? "New Materials (\(freshMaterials.count))" : "New Materials",
                                  action: ("Show All", { model.selection = .materials }))
                }
            }

            let newGrades = overview.grades.filter { $0.isNew && $0.section != nil }
            if !newGrades.isEmpty {
                Section {
                    ForEach(newGrades) { GradeLine(item: $0) }
                } header: {
                    SectionHeader("New Grades", action: ("Show All", { model.selection = .grades }))
                }
            }

            if !exams.isEmpty {
                Section("Upcoming Exams") {
                    ForEach(exams) { exam in
                        let style = overview.style(for: exam.courseId)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(style.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exam.title)
                                Text(style.name).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(DueText.relative(exam.date ?? .now))
                                Text((exam.date ?? .now).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Today")
        .navigationSubtitle(summary)
    }
}
