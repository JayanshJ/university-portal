import SwiftUI
import UniversityKit

/// Lists `/system/courses` by term; ticking a course adds it to the sync.
struct CMSCoursePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showOlderTerms = false

    private var selectedSlugs: Set<String> {
        Set(model.overview.courses.filter { $0.source == .cms && $0.active }.map(\.externalId))
    }

    private var groups: [(heading: String, courses: [CMSCourseListing])] {
        let current = AcademicTerm.current()
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var byHeading: [String: [CMSCourseListing]] = [:]
        for course in model.cmsListing {
            if !showOlderTerms, let term = course.term, term < current { continue }
            if !query.isEmpty, !"\(course.name) \(course.slug) \(course.lecturer ?? "")".lowercased().contains(query) { continue }
            if byHeading[course.termHeading] == nil { order.append(course.termHeading) }
            byHeading[course.termHeading, default: []].append(course)
        }
        return order.map { ($0, byHeading[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search courses, lecturers or slugs", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("Older terms", isOn: $showOlderTerms)
            }
            .padding(12)

            Group {
                if model.isLoadingCMSListing && model.cmsListing.isEmpty {
                    ProgressView("Loading the CMS course list…").frame(maxHeight: .infinity)
                } else if let error = model.cmsListingError, model.cmsListing.isEmpty {
                    ContentUnavailableView("Course list unavailable", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else {
                    List {
                        ForEach(groups, id: \.heading) { group in
                            Section(group.heading) {
                                ForEach(group.courses) { course in
                                    Toggle(isOn: Binding(
                                        get: { selectedSlugs.contains(course.slug) },
                                        set: { model.setCMSCourse(course, selected: $0) }
                                    )) {
                                        VStack(alignment: .leading) {
                                            Text(course.name)
                                            Text([course.lecturer, course.slug].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Text("\(selectedSlugs.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    dismiss()
                    Task { await model.syncCMS() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .task { if model.cmsListing.isEmpty { await model.loadCMSCourses() } }
    }
}
