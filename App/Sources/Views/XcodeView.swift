import DeckhandCore
import SwiftUI

/// A Mac as a server: Xcode version, projects and schemes; build, test, archive and upload as background jobs
/// (they keep running when the phone locks, and a push says when they're done).
struct XcodeView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var info: XcodeServer.Info?
    @State private var projects: [XcodeServer.Project]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let info {
                if !info.isMac {
                    Section {
                        Text("This server isn't a Mac. To build iOS apps from your iPhone, turn on Remote Login on your Mac (System Settings → General → Sharing) and add the Mac as a server.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        LabeledContent("macOS", value: info.macOS ?? "?")
                        LabeledContent("Xcode", value: info.xcode ?? String(localized: "Not installed"))
                        if info.keychainLocked {
                            Label("The login keychain is locked. Building and testing work; archiving and uploading need code signing, so log in on the Mac once.",
                                  systemImage: "lock").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    Section {
                        if let projects {
                            if projects.isEmpty { Text("No Xcode projects in your home folder (four levels deep).").foregroundStyle(.secondary) }
                            ForEach(projects) { p in
                                NavigationLink { XcodeProjectView(server: server, project: p) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label(p.name, systemImage: p.isWorkspace ? "square.stack.3d.up" : "hammer").font(.body.weight(.medium))
                                        Text(p.folder.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression))
                                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                }
                                .accessibilityIdentifier("xcode.project.\(p.name)")
                            }
                        } else {
                            HStack { ProgressView(); Text("Looking for projects…").foregroundStyle(.secondary) }
                        }
                    } header: {
                        Text("Projects")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Xcode")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            let i = XcodeServer.parseDetect(try await conn.run(XcodeServer.detectCommand, timeout: .seconds(30)).stdout)
            info = i
            error = nil
            if i.isMac {
                projects = XcodeServer.parseProjects(try await conn.run(XcodeServer.projectsCommand(), timeout: .seconds(60)).stdout)
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// One project: pick a scheme, start a job, follow its log, see the summary.
private struct XcodeProjectView: View {
    let server: Server
    let project: XcodeServer.Project
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var schemes: [String]?
    @State private var scheme = ""
    @State private var run: DetachedRun?
    @State private var job: XcodeServer.Job?
    @State private var log = ""
    @State private var exitCode: Int?
    @State private var error: String?
    @State private var confirmUpload = false

    private var summary: XcodeServer.Summary { XcodeServer.summarize(log) }
    private var running: Bool { run != nil && exitCode == nil }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            Section {
                if let schemes {
                    if schemes.isEmpty { Text("No shared schemes found.").foregroundStyle(.secondary) }
                    else {
                        Picker("Scheme", selection: $scheme) { ForEach(schemes, id: \.self) { Text($0).tag($0) } }
                            .accessibilityIdentifier("xcode.scheme")
                    }
                } else {
                    HStack { ProgressView(); Text("Reading schemes…").foregroundStyle(.secondary) }
                }
            }
            Section {
                ForEach(XcodeServer.Job.allCases) { j in
                    Button {
                        if j == .upload { confirmUpload = true } else { Task { await start(j) } }
                    } label: {
                        HStack {
                            Label(LocalizedStringKey(j.title), systemImage: symbol(j))
                            Spacer()
                            if running && job == j { ProgressView() }
                        }
                    }
                    .disabled(scheme.isEmpty || running)
                    .accessibilityIdentifier("xcode.job.\(j.rawValue)")
                }
            } footer: {
                Text("Jobs run on the Mac in the background — you can lock the phone; a notification says when they're done. Upload uses your App Store Connect key: its .p8 has to be in ~/.appstoreconnect/private_keys on the Mac.")
            }
            if run != nil {
                resultSection
                Section("Log") {
                    ScrollView(.horizontal) {
                        Text(verbatim: log.split(separator: "\n").suffix(80).filter { !$0.hasPrefix("@@") }.joined(separator: "\n"))
                            .font(.caption2.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSchemes() }
        .task(id: run?.id) { await follow() }
        .confirmationDialog("Archive \(scheme) and upload it to App Store Connect?", isPresented: $confirmUpload, titleVisibility: .visible) {
            Button("Archive and upload") { Task { await start(.upload) } }
        } message: {
            Text("The build lands in TestFlight. Nothing is submitted for review.")
        }
    }

    @ViewBuilder private var resultSection: some View {
        let s = summary
        Section {
            HStack {
                if let ok = s.ok {
                    Label(ok ? String(localized: "\(String(localized: String.LocalizationValue(job?.title ?? ""))) succeeded") : String(localized: "Failed"),
                          systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ok ? .green : .red)
                        .accessibilityIdentifier("xcode.result")
                } else {
                    ProgressView()
                    Text(stepName(s.step)).foregroundStyle(.secondary)
                }
            }
            if let n = s.testsRun {
                Text(s.testsFailed ?? 0 == 0 ? String(localized: "\(n) tests passed") : String(localized: "\(s.testsFailed ?? 0) of \(n) tests failed"))
                    .font(.subheadline)
            }
            ForEach(s.failedTests, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.red) }
            ForEach(s.errors, id: \.self) { e in
                Text(e.replacingOccurrences(of: project.folder + "/", with: "")).font(.caption.monospaced()).foregroundStyle(.red).lineLimit(4)
            }
            if s.warnings > 0 { Text("\(s.warnings) warnings").font(.caption).foregroundStyle(.secondary) }
            if s.uploaded { Label("Uploaded — it shows up in TestFlight after processing.", systemImage: "icloud.and.arrow.up").font(.subheadline) }
            ForEach(s.hints, id: \.self) { Label(LocalizedStringKey($0), systemImage: "lightbulb").font(.footnote).foregroundStyle(.orange) }
        }
    }

    private func symbol(_ j: XcodeServer.Job) -> String {
        switch j { case .build: "hammer"; case .test: "checkmark.diamond"; case .archive: "archivebox"; case .upload: "icloud.and.arrow.up" }
    }

    private func stepName(_ step: String?) -> String {
        switch step {
        case "simulator": String(localized: "Picking a simulator…")
        case "test": String(localized: "Testing…")
        case "archive": String(localized: "Archiving…")
        case "upload": String(localized: "Uploading…")
        default: String(localized: "Building…")
        }
    }

    private func loadSchemes() async {
        do {
            let conn = try await connections.connection(for: server)
            let list = XcodeServer.parseSchemes(try await conn.run(XcodeServer.schemesCommand(project), timeout: .seconds(120)).stdout)
            schemes = list
            if scheme.isEmpty { scheme = list.first { $0 == project.name } ?? list.first ?? "" }
        } catch { self.error = error.localizedDescription }
    }

    private func start(_ j: XcodeServer.Job) async {
        let key = AppStoreAccount.shared.credentials.map { XcodeServer.UploadKey(keyID: $0.keyID, issuerID: $0.issuerID) }
        if (j == .upload) && key == nil {
            error = String(localized: "Connect App Store Connect first (Apps on the home screen); the upload uses that key.")
            return
        }
        do {
            let conn = try await connections.connection(for: server)
            let r = DetachedRun()
            if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
            let title = "\(String(localized: String.LocalizationValue(j.title))): \(scheme)"
            let notify = DetachedRun.Notify(topicURL: settings.ntfyTopicURL,
                                            doneMessage: String(localized: "\(title) — done"), failedMessage: String(localized: "\(title) — failed"))
            let command = XcodeServer.jobCommand(j, project: project, scheme: scheme, key: j == .upload || j == .archive ? key : nil)
            _ = try await conn.run(r.startCommand(command, meta: .init(title: title, engine: "Xcode", directory: project.folder), notify: notify),
                                   timeout: .seconds(30))
            log = ""; exitCode = nil; job = j; run = r; error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Reads the job's output every two seconds until it has ended.
    private func follow() async {
        guard let run else { return }
        while !Task.isCancelled {
            guard let conn = try? await connections.connection(for: server),
                  let r = try? await conn.run("cat \(run.base).out 2>/dev/null; echo; echo \"@@exit $(cat \(run.base).exit 2>/dev/null)\"", timeout: .seconds(30))
            else { try? await Task.sleep(for: .seconds(3)); continue }
            var lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let exit = lines.last(where: { $0.hasPrefix("@@exit") })
            lines.removeAll { $0.hasPrefix("@@exit") }
            log = lines.joined(separator: "\n")
            if let e = exit, let code = Int(e.dropFirst(7).trimmingCharacters(in: .whitespaces)) { exitCode = code; return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
