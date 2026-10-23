import SwiftUI
import UniversityKit

/// One screen for the day: what is due, where to be, what is new, and the week ahead.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    private var overview: PortalOverview { model.overview }

    private var dueSoon: [PortalOverview.ItemRow] {
        let horizon = Date.now.addingTimeInterval(7 * 86_400)
        let overdue = overview.openDeadlines.filter { ($0.date ?? .distantFuture) < .now }
        let upcoming = overview.openDeadlines.filter { ($0.date ?? .distantPast) >= .now && $0.date! < horizon }
        return overdue + upcoming.prefix(4)
    }

    private var todayAndTomorrow: [PortalOverview.ItemRow] {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(2 * 86_400)
        return overview.upcomingEvents.filter { event in
            guard let start = event.date, start < end else { return false }
            return (event.endDate ?? start) >= .now || event.allDay
        }
    }

    private var summary: String {
        let dueThisWeek = overview.openDeadlines.filter { ($0.date ?? .distantFuture) < Date.now.addingTimeInterval(7 * 86_400) }.count
        let today = todayAndTomorrow.filter { Calendar.current.isDateInToday($0.date ?? .distantPast) }.count
        let fresh = overview.newSinceVisit
        return [
            dueThisWeek == 1 ? "1 deadline this week" : "\(dueThisWeek) deadlines this week",
            today == 1 ? "1 event today" : "\(today) events today",
            "\(fresh.announcements.count + fresh.materials.count) new",
        ].joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)), subtitle: summary)

                VStack(alignment: .leading, spacing: 16) {
                    ReconnectBanner()

                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            Card("Due soon", accessory: { link("All deadlines", .deadlines) }) {
                                if dueSoon.isEmpty {
                                    quiet("Nothing due in the next 7 days.")
                                } else {
                                    VStack(spacing: 0) { ForEach(dueSoon) { DeadlineLine(item: $0) } }
                                        .padding(.horizontal, 4).padding(.bottom, 6)
                                }
                            }
                            Card("Today and tomorrow", accessory: { link("Week", .schedule) }) {
                                if todayAndTomorrow.isEmpty {
                                    quiet("No lectures, tutorials or exams.")
                                } else {
                                    VStack(spacing: 0) { ForEach(todayAndTomorrow) { EventLine(event: $0, showsDay: true) } }
                                        .padding(.horizontal, 4).padding(.bottom, 6)
                                }
                            }
                            Card("Latest announcements", accessory: { link("All", .announcements) }) {
                                let latest = overview.announcements.prefix(4)
                                if latest.isEmpty {
                                    quiet("No announcements yet.")
                                } else {
                                    VStack(spacing: 0) {
                                        ForEach(Array(latest)) { item in
                                            CompactLine(item: item, detail: item.date?.formatted(.relative(presentation: .named))) {
                                                model.selection = .announcements
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 4).padding(.bottom, 6)
                                }
                            }
                        }
                        .frame(minWidth: 420, maxWidth: .infinity)

                        VStack(spacing: 16) {
                            NewCard()
                            WeekStripCard()
                            ExamsCard()
                        }
                        .frame(width: 320)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.gutter)
            }
            .frame(maxWidth: 1180, alignment: .leading)
        }
    }

    private func link(_ title: String, _ route: Route) -> some View {
        Button(title) { model.selection = route }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 2)
    }
}

/// Unread announcements and materials since the last visit.
private struct NewCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let fresh = model.overview.newSinceVisit
        Card("New since last visit") {
            if fresh.announcements.isEmpty && fresh.materials.isEmpty {
                Text("You're up to date.").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fresh.announcements.prefix(4)) { item in
                        CompactLine(item: item) { model.selection = .announcements }
                    }
                    ForEach(fresh.materials.prefix(4)) { item in
                        CompactLine(item: item) { model.selection = .materials }
                    }
                    let more = fresh.announcements.count + fresh.materials.count
                        - min(4, fresh.announcements.count) - min(4, fresh.materials.count)
                    if more > 0 {
                        Text("and \(more) more").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
    }
}

/// The next exams across all courses, with a countdown.
private struct ExamsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let exams = model.schedule(from: .now, to: Date.now.addingTimeInterval(200 * 86_400)).filter(\.isExam).prefix(5)
        if !exams.isEmpty {
            Card("Upcoming exams") {
                VStack(spacing: 0) {
                    ForEach(Array(exams)) { exam in
                        let style = model.overview.style(for: exam.courseId)
                        HStack(spacing: 10) {
                            DateBlock(date: exam.date ?? .now)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exam.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                CourseChip(style: style, compact: true)
                            }
                            Spacer(minLength: 4)
                            Text(DueText.relative(exam.date ?? .now))
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .rowBackground()
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
    }
}

/// Seven days with their events and deadlines as coloured dots.
private struct WeekStripCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        let items = model.schedule(from: start, to: calendar.date(byAdding: .day, value: 7, to: start)!)
        Card("Next 7 days", accessory: {
            Button("Week") { model.selection = .schedule }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }) {
            VStack(spacing: 2) {
                ForEach(days, id: \.self) { day in
                    let dayItems = items.filter { calendar.isDate($0.date ?? .distantPast, inSameDayAs: day) }
                    HStack(spacing: 10) {
                        Text(calendar.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 12, weight: calendar.isDateInToday(day) ? .semibold : .regular))
                            .foregroundStyle(calendar.isDateInToday(day) ? Theme.text : Theme.secondary)
                            .frame(width: 44, alignment: .leading)
                        HStack(spacing: 3) {
                            ForEach(dayItems.prefix(12)) { item in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(item.kind == .deadline || item.isExam ? Theme.accent : model.overview.style(for: item.courseId).color)
                                    .frame(width: 8, height: 8)
                            }
                            if dayItems.isEmpty { Text("—").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                        }
                        Spacer()
                        if dayItems.contains(where: { $0.kind == .deadline }) {
                            Pill(text: "due")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 5)
                }
            }
            .padding(.bottom, 8)
        }
    }
}
