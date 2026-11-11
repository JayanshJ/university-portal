import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Handwriting: whether the student's handwriting is set up, and the ways to set it up.
struct HandwritingSection: View {
    @State private var profile = HandwritingProfile.shared
    @State private var settingUp = false
    @State private var importing = false
    @State private var confirmingRemove = false
    @State private var error: String?

    var body: some View {
        Section("Handwriting (for Solve)") {
            LabeledContent("Status") {
                if let summary = profile.summary {
                    Text("Set up · \(summary.characters) characters")
                } else {
                    Text("Not set up: Solve writes typed PDFs").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(profile.isSetUp ? "Redo From Template…" : "Set Up My Handwriting…") { settingUp = true }
                Button("Import From Math Writer…") { importing = true }
                if profile.isSetUp {
                    Spacer()
                    Button("Remove", role: .destructive) { confirmingRemove = true }
                }
            }
            Text("Fill in a printable template by hand and upload a photo of it; Solve can then hand in solutions in your handwriting. It stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(isPresented: $settingUp) { HandwritingSetupView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try profile.importMathWriter(from: url)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        .confirmationDialog("Remove your handwriting?", isPresented: $confirmingRemove) {
            Button("Remove Handwriting", role: .destructive) { profile.remove() }
        } message: {
            Text("Solve goes back to typed PDFs. You can set it up again from the template.")
        }
    }
}

/// The setup sheet: get the template, fill it in, upload photos or the PDF, check, save.
struct HandwritingSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile = HandwritingProfile.shared
    @State private var pages: [Int: TemplateReader.Page] = [:]
    @State private var problems: [String] = []
    @State private var reading = false
    @State private var picking = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    step(1, "Get the template", "Two pages of boxes, one character each. Print them, or open the PDF on your iPad and write on it.") {
                        HStack {
                            Button("Save Template PDF…") { saveTemplate() }
                            Button("Open to Print") { openTemplate() }
                        }
                    }
                    step(2, "Fill it in", "Use a dark pen. Write each character once per box, sitting on the blue line, with small letters reaching the dashed line. Skip boxes you don't want.") { EmptyView() }
                    step(3, "Upload it", "A photo from straight above with all four black squares in view, a scan, or the PDF exported from your iPad. Both pages, in any order.") {
                        HStack {
                            Button("Add Photos or PDF…") { picking = true }
                            if reading { ProgressView().controlSize(.small) }
                        }
                    }
                }

                if !pages.isEmpty || !problems.isEmpty {
                    Section("Read so far") {
                        ForEach(0..<HandwritingTemplate.pageCount, id: \.self) { number in
                            if let page = pages[number] {
                                Label("Page \(number + 1): \(page.glyphs.count) boxes", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Label("Page \(number + 1): not added yet", systemImage: "circle.dashed").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if !pages.isEmpty { preview }
                }
            }
            .formStyle(.grouped)
            .dropDestination(for: URL.self) { urls, _ in
                read(urls)
                return true
            }

            Divider()
            HStack {
                if let saveError { Text(saveError).foregroundStyle(.red).font(.callout) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Handwriting") {
                    do {
                        try profile.save(pages.keys.sorted().compactMap { pages[$0] })
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pages.isEmpty || reading)
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { read(urls) }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline).frame(width: 24, height: 24).background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(.vertical, 4)
    }

    /// Every character found, with the ones still missing.
    private var preview: some View {
        let found = Dictionary(pages.values.flatMap(\.glyphs).map { ($0.character, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = HandwritingTemplate.characters.map(\.0).filter { found[$0] == nil }
        return Section {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 14), spacing: 6) {
                ForEach(HandwritingTemplate.characters.map(\.0).filter { found[$0] != nil }, id: \.self) { character in
                    if let glyph = found[character], let image = NSImage(data: glyph.png) {
                        Image(nsImage: image)
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                            .padding(2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                            .colorMultiply(Color(red: 0.06, green: 0.27, blue: 0.71))
                            .help(String(character))
                    }
                }
            }
            if !missing.isEmpty {
                Text("Not found yet: \(missing.map(String.init).joined(separator: " "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Your characters")
        }
    }

    private func read(_ urls: [URL]) {
        reading = true
        problems = []
        Task.detached(priority: .userInitiated) {
            var found: [TemplateReader.Page] = []
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    for (index, image) in try TemplateReader.images(from: url).enumerated() {
                        do {
                            found.append(try TemplateReader.read(image))
                        } catch {
                            failures.append("\(url.lastPathComponent)\(index > 0 ? " page \(index + 1)" : ""): \(error.localizedDescription)")
                        }
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                for page in found { pages[page.number] = page }
                problems = failures
                reading = false
            }
        }
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Handwriting Template.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? HandwritingTemplate.pdf().write(to: url)
        }
    }

    private func openTemplate() {
        let url = FileManager.default.temporaryDirectory.appending(path: "Handwriting Template.pdf")
        try? HandwritingTemplate.pdf().write(to: url)
        NSWorkspace.shared.open(url)
    }
}
