import SwiftUI
import UniversityKit

/// The summary: reconnect banner, deadlines due soon, today's and tomorrow's lectures and exams,
/// and what is new since the last visit.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    let go: (SidebarSection) -> Void

    private var dueSoon: [PortalOverview.ItemRow] {
        let horizon = Date.now.addingTimeInterval(7 * 86_400)
        let overdue = model.overview.openDeadlines.filter { ($0.date ?? .distantFuture) < .now }
        let upcoming = model.overview.openDeadlines.filter { ($0.date ?? .distantPast) >= .now && $0.date! < horizon }
        return overdue + upcoming.prefix(3)
    }

    private var lecturesAndExams: [PortalOverview.ItemRow] {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(2 * 86_400)
        return model.overview.upcomingEvents.filter { event in
            guard let date = event.date, date < end, (event.endDate ?? date) >= .now || event.allDay else { return false }
            let category = event.section?.lowercased() ?? ""
            return event.isExam || category.contains("lecture") || category.contains("vorlesung")
        }
    }

    var body: some View {
        let overview = model.overview
        let fresh = overview.newSinceVisit
        let isEmpty = overview.openDeadlines.isEmpty && overview.materials.isEmpty && overview.upcomingEvents.isEmpty
        if isEmpty && !overview.needsReconnect {
            EmptySectionView(title: "Nothing here yet", systemImage: "sun.max",
                             message: "Connect Moodle and choose CMS courses in Settings to fill Today.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ReconnectBanner()

                    TodaySection(title: "Due soon", action: ("All deadlines", { go(.deadlines) })) {
                        if dueSoon.isEmpty {
                            Text("Nothing due in the next 7 days.").foregroundStyle(.secondary)
                        } else {
                            ForEach(dueSoon) { DeadlineRow(item: $0) }
                        }
                    }

                    TodaySection(title: "Today and tomorrow", action: ("Schedule", { go(.schedule) })) {
                        if lecturesAndExams.isEmpty {
                            Text("No lectures or exams.").foregroundStyle(.secondary)
                        } else {
                            ForEach(lecturesAndExams) { EventRow(event: $0, showsDay: true) }
                        }
                    }

                    TodaySection(title: "New since last visit", action: nil) {
                        if fresh.announcements.isEmpty && fresh.materials.isEmpty {
                            Text("Nothing new.").foregroundStyle(.secondary)
                        } else {
                            NewSummary(label: "announcements", items: fresh.announcements) { go(.announcements) }
                            NewSummary(label: "materials", items: fresh.materials) { go(.materials) }
                        }
                    }

                    if let synced = [overview.moodle?.lastSyncAt, overview.cms?.lastSyncAt].compactMap({ $0 }).max() {
                        Text("Synced \(synced, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(24)
                .frame(maxWidth: Layout.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct TodaySection<Content: View>: View {
    let title: String
    let action: (String, () -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                if let action {
                    Button(action.0, action: action.1).buttonStyle(.link).font(.callout)
                }
            }
            Divider()
            content
        }
    }
}

private struct NewSummary: View {
    let label: String
    let items: [PortalOverview.ItemRow]
    let open: () -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button { open() } label: {
                    HStack(spacing: 6) {
                        NewDot()
                        Text("\(items.count) new \(label)")
                    }
                }
                .buttonStyle(.plain)
                ForEach(items.prefix(2)) { item in
                    Text("New in \(item.course): \(item.title)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, 12)
                }
            }
        }
    }
}
