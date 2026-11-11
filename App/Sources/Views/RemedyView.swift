import DeckhandCore
import SwiftUI

/// Which uptime check an incident chat belongs to, so a fix that worked can become automatic.
enum IncidentLinks {
    private static let key = "incident.links"
    static func set(_ checkID: String, for thread: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[thread.uuidString] = checkID
        UserDefaults.standard.set(all, forKey: key)
    }
    static func check(for thread: UUID) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[thread.uuidString]
    }
}

/// The commands that fix an uptime check on their own next time, run by the server when the check fails.
struct RemedySheet: View {
    let server: Server
    let checkID: String
    let checkName: String
    var existing: Uptime.Remedy?
    var initialCommands = ""
    var saved: () -> Void = {}
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var commands = ""
    @State private var maxPerHour = 3
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error { ProblemView(message: error, compact: true) }
                Section {
                    TextEditor(text: $commands)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("remedy.commands")
                    Stepper("At most \(maxPerHour)× an hour", value: $maxPerHour, in: 1...10)
                } header: {
                    Text("When “\(checkName)” fails")
                } footer: {
                    Text(footer)
                }
                if let existing, !existing.runs.isEmpty {
                    Section("Recent runs") {
                        ForEach(Array(existing.runs.suffix(8).reversed().enumerated()), id: \.offset) { _, run in
                            HStack {
                                Image(systemName: run.fixed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(run.fixed ? .green : .red)
                                Text(run.date, format: .dateTime.day().month().hour().minute())
                                Spacer()
                                Text(run.fixed ? String(localized: "Fixed") : String(localized: "Didn't help")).foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                        if !existing.lastOutput.isEmpty {
                            Text(existing.lastOutput).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(12)
                        }
                    }
                }
                if existing != nil {
                    Section {
                        Button("Stop fixing automatically", role: .destructive) { Task { await remove() } }
                    }
                }
            }
            .navigationTitle("Automatic fix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("remedy.save")
                }
            }
            .onAppear {
                commands = existing?.commands ?? initialCommands
                maxPerHour = existing?.maxPerHour ?? 3
            }
        }
    }

    private var footer: String {
        var text = String(localized: "Your server runs these commands as \(server.username) when the check fails, checks again and tells you whether it helped. If it doesn't, you get an urgent push.")
        if commands.contains("sudo") {
            text += " " + String(localized: "sudo only works here if this user may run these commands without a password.")
        }
        return text
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            // The keyboard's smart punctuation would break shell commands.
            let plain = commands.replacingOccurrences(of: "—", with: "--").replacingOccurrences(of: "–", with: "--")
                .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
                .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
            let r = try await conn.run(Uptime.setRemedyCommand(checkID: checkID, remedy: .init(commands: plain, maxPerHour: maxPerHour)), timeout: .seconds(20))
            guard r.stdout.contains("@@ok") else { error = r.stderr.isEmpty ? String(localized: "Couldn't save the fix.") : r.stderr; return }
            saved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(Uptime.removeRemedyCommand(checkID: checkID), timeout: .seconds(20))
            saved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// After an applied fix: offer to make it automatic for the check this incident came from.
struct AutoFixOffer: View {
    let setUp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fix it automatically next time?").font(.subheadline.weight(.semibold))
                Text("The server runs this fix on its own when the check fails again.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Set up", action: setUp).buttonStyle(.borderedProminent).tint(Theme.accent)
                .accessibilityIdentifier("autofix.setup")
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Not now")
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }
}
