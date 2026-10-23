import AppKit
import SwiftUI
import UniversityKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPaste = false
    @State private var pasted = ""
    @State private var launchLink: URL?
    @State private var showPicker = false
    @State private var cmsUser = ""
    @State private var cmsPassword = ""

    var body: some View {
        Form {
            moodleSection
            if model.isMoodleConnected || model.overview.diagnostics != nil {
                checksSection
            }
            if model.overview.courses.contains(where: { $0.source == .moodle }) {
                coursesSection
            }
            cmsSection
            if !model.overview.recentRuns.isEmpty {
                runsSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 680)
        .sheet(isPresented: $showPicker) { CMSCoursePicker().environment(model) }
    }

    // MARK: - CMS

    private var cmsCourses: [PortalOverview.CourseRow] {
        model.overview.courses.filter { $0.source == .cms }
    }

    private var cmsSection: some View {
        Section("CMS") {
            LabeledContent("Status") {
                if !cmsCourses.contains(where: \.active) {
                    Text("No courses chosen").foregroundStyle(.secondary)
                } else {
                    StatusText(source: model.overview.cms, connected: true)
                }
            }
            HStack {
                Button("Choose Courses…") { showPicker = true }
                if model.isSyncing { ProgressView().controlSize(.small) }
            }
            let categories = model.eventCategories()
            ForEach(cmsCourses) { course in
                HStack {
                    Toggle(isOn: Binding(
                        get: { course.active },
                        set: { model.setCMSCourse(id: course.id, selected: $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(course.fullName)
                            Text(course.externalId).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let names = categories[course.id], !names.isEmpty {
                        let hidden = model.hiddenCategories(courseId: course.id)
                        Menu("Schedule") {
                            ForEach(names, id: \.self) { name in
                                Toggle(name, isOn: Binding(
                                    get: { !hidden.contains(name) },
                                    set: { model.setCategory(name, hidden: !$0, courseId: course.id) }
                                ))
                            }
                        }
                        .fixedSize()
                        .help("Choose which calendar categories appear in Schedule")
                    }
                }
            }
            if model.isCMSSignedIn {
                LabeledContent("Signed in as") {
                    HStack {
                        Text(model.cmsUsername ?? "")
                        Button("Sign Out") { model.signOutCMS() }
                    }
                }
                if model.overview.cms?.status == .needsReconnect {
                    Text("CMS rejected the saved password. Sign out and sign in again with the right one.")
                        .font(.caption).foregroundStyle(.red)
                }
            } else {
                TextField("CMS username", text: $cmsUser)
                    .textContentType(.username)
                SecureField("CMS password", text: $cmsPassword)
                    .textContentType(.password)
                HStack {
                    Button("Sign In to CMS") {
                        let (user, password) = (cmsUser, cmsPassword)
                        cmsPassword = ""
                        Task { await model.signInCMS(username: user, password: password) }
                    }
                    .disabled(cmsUser.isEmpty || cmsPassword.isEmpty || model.isConnecting)
                    if model.isConnecting { ProgressView().controlSize(.small) }
                }
                Text("Needed for materials. Stored in your Keychain; the app tries it at most once per 15 minutes if it stops working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Moodle

    private var moodleSection: some View {
        Section("Moodle") {
            LabeledContent("Status") { StatusText(source: model.overview.moodle, connected: model.isMoodleConnected) }

            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button(model.isMoodleConnected ? "Reconnect in Browser…" : "Connect in Browser…") {
                    model.connectMoodleInBrowser()
                }
                .disabled(model.isConnecting)
                .help("Opens Moodle in your default browser; allow it to open University Portal at the end.")
                Button("Sync now") { Task { await model.syncNow() } }
                    .disabled(!model.isMoodleConnected || model.isSyncing)
                if model.isConnecting || model.isSyncing { ProgressView().controlSize(.small) }
                Spacer()
                if model.isMoodleConnected {
                    Button("Disconnect", role: .destructive) { model.disconnectMoodle() }
                }
            }

            LabeledContent("Other ways") {
                Button("Sign in inside the app…") { Task { await model.connectMoodleWithSheet() } }
                    .disabled(model.isConnecting)
            }

            DisclosureGroup("Paste the redirect instead", isExpanded: $showPaste) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("""
                        1. Copy the launch link and open it in a browser where you're logged in to Moodle.
                        2. DevTools → Network (Preserve log) → the launch.php row (302) → Response Headers.
                        3. Copy the location value (moodlemobile://token=…) and paste it below.
                        """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button("Copy launch link") {
                        launchLink = model.makeLaunchLink()
                        if let launchLink {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(launchLink.absoluteString, forType: .string)
                        }
                    }
                    if launchLink != nil {
                        Text("Copied. The link works for 15 minutes.").font(.caption).foregroundStyle(.secondary)
                    }

                    TextField("moodlemobile://token=…", text: $pasted, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Connect") {
                        let text = pasted
                        pasted = ""
                        Task { await model.connectMoodle(pasted: text) }
                    }
                    .disabled(pasted.isEmpty || model.isConnecting)
                }
                .padding(.top, 4)
            }
        }
    }

    private var checksSection: some View {
        let diagnostics = model.overview.diagnostics
        return Section("Checks") {
            LabeledContent("Connected via") {
                switch diagnostics?.connectedVia {
                case .browser?: Text("Browser → moodlemobile:// link").foregroundStyle(.green)
                case .sheet?: Text("In-app sheet").foregroundStyle(.green)
                case .paste?: Text("Pasted redirect")
                case nil: Text("Not connected yet").foregroundStyle(.secondary)
                }
            }
            LabeledContent("In-app sheet") {
                if diagnostics?.connectedVia == .sheet, diagnostics?.sheetFailure == nil {
                    Text("Returned the token").foregroundStyle(.green)
                } else if let failure = diagnostics?.sheetFailure {
                    Text(failure).foregroundStyle(.orange)
                } else {
                    Text("Not tried").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Deadlines call") {
                switch diagnostics?.deadlinesMode {
                case .actionEvents: Text("Works with the token").foregroundStyle(.green)
                case .assignFallback: Text("Refused, using assignments: \(diagnostics?.deadlinesFallbackReason ?? "")")
                    .foregroundStyle(.orange)
                case nil: Text("Not checked yet").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Site hash") {
                switch diagnostics?.siteHashMatched {
                case true?: Text("Matches md5(wwwroot + passport)").foregroundStyle(.green)
                case false?: Text("Does not match (validated by site info)").foregroundStyle(.orange)
                case nil: Text("Not checked").foregroundStyle(.secondary)
                }
            }
            if let release = diagnostics?.release {
                LabeledContent("Moodle", value: release)
            }
        }
    }

    private var coursesSection: some View {
        Section("Moodle courses") {
            ForEach(model.overview.courses.filter { $0.source == .moodle }) { course in
                Toggle(isOn: Binding(
                    get: { course.active },
                    set: { model.setCourse(course.id, active: $0) }
                )) {
                    VStack(alignment: .leading) {
                        Text(course.fullName)
                        Text(courseCaption(course))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Use Automatic Setting") { model.resetCourse(course.id) }
                        .disabled(!course.isOverridden)
                }
            }
            if model.overview.courses.contains(where: \.isOverridden) {
                Text("Right-click a course set by you to go back to the automatic setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var runsSection: some View {
        Section("Recent syncs") {
            ForEach(model.overview.recentRuns) { run in
                LabeledContent {
                    Text(run.ok == true ? summary(run.counts) : (run.error ?? "running…"))
                        .foregroundStyle(run.ok == false ? .orange : .secondary)
                } label: {
                    Text(run.job)
                    Text(run.startedAt, format: .relative(presentation: .named)).font(.caption)
                }
            }
        }
    }

    private func courseCaption(_ course: PortalOverview.CourseRow) -> String {
        var parts = [course.shortName]
        if course.isOverridden {
            parts.append("set by you")
        } else if let term = course.term {
            parts.append(course.termIsPast ? "\(term) · past term" : term)
        }
        return parts.joined(separator: " · ")
    }

    private func summary(_ counts: [String: Int]?) -> String {
        guard let counts else { return "ok" }
        let parts = ["new", "updated", "unchanged", "missing", "deleted", "done_by_moodle"]
            .compactMap { key in counts[key].flatMap { $0 > 0 ? "\($0) \(key.replacingOccurrences(of: "_", with: " "))" : nil } }
        return parts.isEmpty ? "nothing changed" : parts.joined(separator: ", ")
    }
}

struct StatusText: View {
    let source: PortalOverview.SourceRow?
    let connected: Bool

    var body: some View {
        if !connected {
            Text("Not connected").foregroundStyle(.secondary)
        } else if let source {
            switch source.status {
            case .ok:
                if let synced = source.lastSyncAt {
                    Text("Synced \(synced, format: .relative(presentation: .named))")
                } else {
                    Text("Connected")
                }
            case .degraded: Text(source.lastError ?? "Degraded").foregroundStyle(.secondary)
            case .needsReconnect: Text("Needs reconnect").foregroundStyle(.red)
            case .error: Text(source.lastError ?? "Error").foregroundStyle(.orange)
            }
        } else {
            Text("Connected")
        }
    }
}
