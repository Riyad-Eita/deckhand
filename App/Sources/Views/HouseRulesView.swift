import DeckhandCore
import SwiftUI

/// The last house rules seen per server (the server's file is the truth; this saves a round trip).
enum HouseRulesStore {
    private static func key(_ server: Server) -> String { "rules.\(server.id.uuidString)" }
    static func rules(for server: Server) -> HouseRules? {
        UserDefaults.standard.data(forKey: key(server)).flatMap { try? JSONDecoder().decode(HouseRules.self, from: $0) }
    }
    static func set(_ rules: HouseRules?, for server: Server) {
        if let rules, let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: key(server)) }
        else { UserDefaults.standard.removeObject(forKey: key(server)) }
    }
}

/// Rules every agent on this server must follow: Claude Code and Codex (also when started from a laptop) and the
/// own-key agent. Enforced on the server, not just written into a prompt.
struct HouseRulesView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var rules = HouseRules()
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: HouseRules.InstallResult?
    @State private var newPath = ""
    @State private var newCommand = ""
    @State private var quiet = false
    @State private var quietStart = Self.time("09:00")
    @State private var quietEnd = Self.time("18:00")
    @State private var weekdaysOnly = true
    @State private var spendCap = false
    @State private var spend = 2.0
    @State private var askOn = false
    @State private var askMinutes = 10

    var body: some View {
        Form {
            if let error { ProblemView(message: error, compact: true) }
            if let result {
                Section {
                    if result.noPython {
                        Label("This server has no python3, which the rules need. Install it from Updates or the terminal.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if result.ok {
                        Label(appliedText(result), systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    }
                    ForEach(result.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
            }
            Section {
                Toggle("Read-only mode", isOn: $rules.readOnly).accessibilityIdentifier("rules.readOnly")
            } footer: {
                Text("Agents may look around but can't change files or run commands that change things.")
            }
            Section {
                ForEach(rules.protectedPaths, id: \.self) { p in
                    Label(p, systemImage: "lock.fill").font(.callout.monospaced())
                }
                .onDelete { rules.protectedPaths.remove(atOffsets: $0) }
                HStack {
                    TextField("/srv/data", text: $newPath).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("rules.newPath")
                    Button("Add") { add(&rules.protectedPaths, &newPath) }.disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("rules.addPath")
                }
                if !HouseRules.databaseFolders.allSatisfy(rules.protectedPaths.contains) {
                    Button { for f in HouseRules.databaseFolders where !rules.protectedPaths.contains(f) { rules.protectedPaths.append(f) } } label: {
                        Label("Protect the database folders", systemImage: "cylinder.split.1x2")
                    }
                }
            } header: {
                Text("Hands off")
            } footer: {
                Text("No edits, and no commands that touch these folders or files.")
            }
            Section {
                ForEach(rules.forbiddenCommands, id: \.self) { c in Label(c, systemImage: "nosign").font(.callout.monospaced()) }
                    .onDelete { rules.forbiddenCommands.remove(atOffsets: $0) }
                HStack {
                    TextField("docker system prune", text: $newCommand).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") { add(&rules.forbiddenCommands, &newCommand) }.disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Toggle("Never open ports", isOn: $rules.noOpenPorts)
            } header: {
                Text("Never run")
            } footer: {
                Text("“Never open ports” stops firewall openings and published Docker ports.")
            }
            Section {
                Toggle("Quiet hours", isOn: $quiet)
                if quiet {
                    DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: $quietEnd, displayedComponents: .hourAndMinute)
                    Toggle("Weekdays only", isOn: $weekdaysOnly)
                }
            } footer: {
                Text("No restarts, stops or reboots in this window (\(TimeZone.current.localizedName(for: .shortGeneric, locale: .current) ?? TimeZone.current.identifier)).")
            }
            Section {
                Toggle("Spending cap per task", isOn: $spendCap)
                if spendCap {
                    Stepper(value: $spend, in: 0.5...50, step: 0.5) { Text(spend, format: .currency(code: "USD")) }
                }
            } footer: {
                Text("Claude Code stops a task that would cost more. Plans like Claude Max or ChatGPT have no per-task cost.")
            }
            Section {
                Toggle("Ask on my lock screen", isOn: $askOn).accessibilityIdentifier("rules.ask")
                if askOn {
                    Stepper("Wait \(askMinutes) min for an answer", value: $askMinutes, in: 2...60, step: 2)
                }
            } footer: {
                Text("Instead of just stopping Claude Code or Codex, the server sends a push with Allow and Deny — also while the app is closed. Commands that can't be undone open Deckhand for Face ID. No answer means no.")
            }
            Section {
                Button { Task { await save() } } label: {
                    HStack { Text("Save rules"); Spacer(); if busy { ProgressView() } }
                }
                .disabled(busy || !loaded)
                .accessibilityIdentifier("rules.save")
                if HouseRulesStore.rules(for: server) != nil {
                    Button("Remove all rules", role: .destructive) { Task { await removeAll() } }
                }
            } footer: {
                Text("Stored on the server in ~/.deckhand/rules and checked there before every agent action — also for tasks you start from a laptop. A blocked action can be allowed once.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("House rules")
        .task { await load() }
    }

    private func appliedText(_ r: HouseRules.InstallResult) -> String {
        var engines = [String(localized: "your own-key agent")]
        if r.claudeCode { engines.insert("Claude Code", at: 0) }
        if r.codex { engines.insert("Codex", at: r.claudeCode ? 1 : 0) }
        return String(localized: "Active for \(engines.formatted(.list(type: .and))).")
    }

    private func add(_ list: inout [String], _ field: inout String) {
        let v = field.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty, !list.contains(v) { list.append(v) }
        field = ""
    }

    private static func time(_ hhmm: String) -> Date {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    private static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            let current = HouseRules.decode(try await conn.run(HouseRules.readCommand, timeout: .seconds(15)).stdout)
            HouseRulesStore.set(current, for: server)
            rules = current ?? HouseRules()
            if let q = rules.quietHours {
                quiet = true; quietStart = Self.time(q.start); quietEnd = Self.time(q.end); weekdaysOnly = q.days.count == 5
            }
            if let s = rules.maxSpendUSD { spendCap = true; spend = s }
            if let a = rules.ask { askOn = true; askMinutes = a.minutes }
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var r = rules
        r.quietHours = quiet ? .init(start: Self.hhmm(quietStart), end: Self.hhmm(quietEnd), days: weekdaysOnly ? [1, 2, 3, 4, 5] : Array(1...7)) : nil
        r.maxSpendUSD = spendCap ? spend : nil
        if askOn {
            let settings = AppSettings.shared
            if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
            r.ask = .init(topic: settings.ntfyTopicURL, server: server.id.uuidString, minutes: askMinutes)
        } else {
            r.ask = nil
        }
        do {
            let conn = try await connections.connection(for: server)
            if r.isEmpty {
                _ = try await conn.run(HouseRules.uninstallCommand, timeout: .seconds(30))
                HouseRulesStore.set(nil, for: server)
                result = nil
            } else {
                result = HouseRules.InstallResult(output: try await conn.run(r.installCommand(), timeout: .seconds(60)).stdout)
                if result?.ok == true { HouseRulesStore.set(r, for: server) }
            }
            rules = r
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeAll() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(HouseRules.uninstallCommand, timeout: .seconds(30))
            HouseRulesStore.set(nil, for: server)
            rules = HouseRules(); quiet = false; spendCap = false; askOn = false; result = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A server CLI's action was stopped by a house rule: say which, and offer to allow exactly that action once.
struct RuleBlockedBar: View {
    let title: String
    let allowOnce: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stopped by a house rule").font(.subheadline.weight(.semibold))
                    Text(title).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Not now")
            }
            Button(action: allowOnce) { Text("Allow once and continue").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).accessibilityIdentifier("rules.allowOnce")
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }
}
