import SwiftUI
import UniversityKit

/// The details the sheet's submission rules ask for and Solve doesn't have yet. The student's own
/// details are saved to Settings, the group, tutorial and partners for this course; then it solves.
struct DetailsForm: View {
    let model: SolveModel
    /// The fields still missing.
    let fields: [SubmissionRules.Field]

    @State private var student: StudentDetails
    @State private var course: CourseDetails
    @State private var sheet: String

    init(model: SolveModel, fields: [SubmissionRules.Field]) {
        self.model = model
        self.fields = fields
        _student = State(initialValue: model.student)
        var course = model.courseDetails
        if (fields.contains(.partnerNames) || fields.contains(.partnerMatrikelnr)) && course.partners.isEmpty {
            course.partners = [Partner()]
        }
        _course = State(initialValue: course)
        _sheet = State(initialValue: model.headerValue(.sheet))
    }

    private var rules: SubmissionRules { model.rules ?? .none }
    private var asksPartners: Bool { fields.contains(.partnerNames) || fields.contains(.partnerMatrikelnr) }
    private var studentFields: [SubmissionRules.Field] { fields.filter { [.name, .matrikelnr, .email].contains($0) } }
    private var courseFields: [SubmissionRules.Field] { fields.filter { [.group, .tutorial].contains($0) } }

    /// The course details as saved: partner rows left completely blank are dropped.
    private var cleanedCourse: CourseDetails {
        var course = course
        course.partners.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.matrikelnr.trimmingCharacters(in: .whitespaces).isEmpty }
        return course
    }

    private var sheetNumber: Int? { Int(sheet.trimmingCharacters(in: .whitespaces)) }

    /// What is still missing with the values typed so far: the model's own rule, so the form and
    /// the model never disagree (values typed in the rules row count too).
    private var stillMissing: [SubmissionRules.Field] {
        model.missingDetails(student: student, course: cleanedCourse, sheet: fields.contains(.sheet) ? sheet : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Details for the Submission").font(.headline)
                        Text("The sheet asks for these on the hand-in. They go into the PDF's header and file name.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let quote = rules.quote, !quote.isEmpty {
                            Text("“\(quote)”").font(.callout).italic().foregroundStyle(.secondary)
                        }
                    }
                }
                if !studentFields.isEmpty {
                    Section {
                        ForEach(studentFields, id: \.self) { field in
                            switch field {
                            case .name:
                                TextField("Name", text: $student.name)
                            case .matrikelnr:
                                TextField(rules.shortLabel(.matrikelnr), text: $student.matrikelnr)
                            default:
                                TextField(rules.shortLabel(.email), text: $student.email)
                            }
                        }
                    } header: {
                        Text("You")
                    } footer: {
                        if needsFirstName {
                            Text("The file name needs your first and last name.").foregroundStyle(Theme.dueSoon)
                        } else {
                            Text("Saved in Settings for every course.").foregroundStyle(.secondary)
                        }
                    }
                }
                if !courseFields.isEmpty {
                    Section {
                        ForEach(courseFields, id: \.self) { field in
                            if field == .group {
                                TextField(rules.shortLabel(.group), text: $course.group)
                            } else {
                                TextField(rules.shortLabel(.tutorial), text: $course.tutorial)
                            }
                        }
                    } header: {
                        Text(model.courseShort.isEmpty ? "This Course" : model.courseShort)
                    } footer: {
                        Text("Saved for this course.").foregroundStyle(.secondary)
                    }
                }
                if asksPartners { partners }
                if fields.contains(.sheet) {
                    Section {
                        TextField("Sheet number", text: $sheet)
                    } footer: {
                        Text(!sheet.isEmpty && sheetNumber == nil ? "Use digits only, e.g. 3." : "Only for this PDF's file name.")
                            .foregroundStyle(!sheet.isEmpty && sheetNumber == nil ? Theme.dueSoon : .secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Spacer()
                Button("Save and Solve", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!stillMissing.isEmpty)
                    .help(stillMissing.isEmpty ? "Save these details and write the solution" : "Fill in every field first")
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var partners: some View {
        Section {
            Toggle("I'm handing in alone", isOn: $course.alone)
        } footer: {
            Text("Saved for this course. The partner rows are left out of the header.").foregroundStyle(.secondary)
        }
        if !course.alone { partnerRows }
    }

    @ViewBuilder
    private var partnerRows: some View {
        ForEach($course.partners) { $partner in
            let number = (course.partners.firstIndex { $0.id == partner.id } ?? 0) + 1
            Section {
                TextField("Name", text: $partner.name)
                TextField(rules.shortLabel(.matrikelnr), text: $partner.matrikelnr)
            } header: {
                HStack {
                    Text("Partner \(number)")
                    Spacer()
                    Button {
                        course.partners.removeAll { $0.id == partner.id }
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remove partner \(number)")
                    .accessibilityLabel("Remove partner \(number)")
                }
            }
        }
        Section {
            Button {
                course.partners.append(Partner())
            } label: {
                Label("Add Partner", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } footer: {
            Text("Partners are saved for this course.").foregroundStyle(.secondary)
        }
    }

    /// The name is there, but a `{firstname}` pattern needs two words.
    private var needsFirstName: Bool {
        stillMissing.contains(.name) && !student.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        if fields.contains(.sheet) { model.overrideHeader(.sheet, value: sheet) }
        model.saveDetails(student: student, course: cleanedCourse)
    }
}
