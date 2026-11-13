import DeckhandCore
import DeckhandSSH
import SwiftUI

/// Moves SSH to another port in guarded steps, proving a login on the new port before the old one closes.
struct SSHPortView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var root = RootRunner()
    @State private var inspection: SSHPort.Inspection?
    @State private var portText = ""
    @State private var steps: [Step] = []
    @State private var running = false
    @State private var outcome: Outcome?
    @State private var confirmStart = false

    struct Step: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, done, failed }
        let id: Int
        let title: String
        var state: State = .waiting
    }

    enum Outcome: Equatable {
        case moved(Int)
        /// Nothing changed in the end.
        case undone(String)
        /// Partly done; the text says what's left.
        case warning(String)
    }

    private var newPort: Int? { Int(portText.trimmingCharacters(in: .whitespaces)) }
    private var portProblem: String? {
        guard let inspection else { return nil }
        guard let p = newPort else { return portText.isEmpty ? nil : String(localized: "Enter a number.") }
        return SSHPort.problem(with: p, on: inspection).map { String(localized: String.LocalizationValue($0)) }
    }

    var body: some View {
        List {
            if let inspection {
                Section("Now") {
                    LabeledContent("SSH port", value: inspection.ports.map(String.init).joined(separator: ", "))
                    LabeledContent("Firewall", value: firewallText(inspection.firewall))
                    if inspection.socketActivated { LabeledContent("Started by", value: "ssh.socket") }
                }
                if outcome == nil && steps.isEmpty {
                    Section {
                        HStack {
                            TextField("New port", text: $portText).keyboardType(.numberPad).font(.body.monospacedDigit())
                                .accessibilityIdentifier("sshPort.field")
                            Button("Suggest") { portText = String(SSHPort.suggestion(avoiding: inspection)) }
                        }
                        if let portProblem { Text(portProblem).font(.footnote).foregroundStyle(.orange) }
                    } header: {
                        Text("New port")
                    } footer: {
                        Text("A port other than 22 keeps most automated login attempts away. If your hosting provider has its own firewall (security groups, cloud firewall), allow the new port there first.")
                    }
                    Section {
                        Button {
                            confirmStart = true
                        } label: {
                            Text(newPort.map { "Move SSH to port \(String($0))" } ?? "Move SSH").frame(maxWidth: .infinity)
                        }
                        .disabled(newPort == nil || portProblem != nil || running)
                        .accessibilityIdentifier("sshPort.start")
                    } footer: {
                        Text("Deckhand opens the new port next to the old one, logs in on it, and only then closes the old one. If anything goes wrong, the server switches back by itself after 5 minutes.")
                    }
                }
            } else if case .failed(let m) = root.phase {
                ProblemView(message: m, compact: true)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
            if !steps.isEmpty {
                Section("Progress") {
                    ForEach(steps) { step in
                        HStack(spacing: 10) {
                            icon(step.state).frame(width: 20)
                            Text(step.title)
                        }
                    }
                }
            }
            if let outcome {
                Section {
                    switch outcome {
                    case .moved(let p):
                        Label("SSH now runs on port \(String(p)). Deckhand saved the new port for this server.", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    case .undone(let why):
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(why)
                                Text("Nothing changed: SSH still runs on the old port.").foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange) }
                    case .warning(let text):
                        Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)
            }
        }
        .navigationTitle("SSH port")
        .task { await inspect() }
        .sudoPassword(root, server: server)
        .confirmationDialog("Move SSH to port \(newPort.map(String.init) ?? "")?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Move SSH") { Task { await move() } }
        } message: {
            Text("Your current session stays open. Other SSH clients and scripts need the new port afterwards.")
        }
        .interactiveDismissDisabled(running)
    }

    private func firewallText(_ f: SSHPort.Firewall) -> String {
        switch f {
        case .ufw: "ufw"
        case .firewalld(let zone): "firewalld (\(zone))"
        case .none: String(localized: "none found")
        }
    }

    @ViewBuilder private func icon(_ s: Step.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func inspect(using conn: SSHConnection? = nil) async -> SSHPort.Inspection? {
        guard await root.run(SSHPort.inspectScript, on: server, connection: conn) else { return nil }
        let i = SSHPort.parse(root.lines.joined(separator: "\n"))
        inspection = i
        return i
    }

    private func set(_ id: Int, _ state: Step.State) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = state }
    }

    private func move() async {
        guard let port = newPort, let before = inspection else { return }
        let old = before.ports.map(String.init).joined(separator: ", ")
        running = true
        defer { running = false }
        steps = [
            Step(id: 1, title: String(localized: "Open port \(String(port)) next to \(old)")),
            Step(id: 2, title: String(localized: "Log in on port \(String(port))")),
            Step(id: 3, title: String(localized: "Close port \(old)")),
            Step(id: 4, title: String(localized: "Log in on port \(String(port)) again")),
        ]

        // 1. Open the new port next to the old one.
        set(1, .running)
        let add = SSHPort.addPort(port, inspection: before)
        let addID = ConfigChange.makeID(title: add.title)
        guard await root.run(add.script(id: addID), on: server) else {
            set(1, .failed)
            outcome = .undone(String(localized: "The server couldn't open port \(String(port)) (\(root.failedStep ?? "error")). Its previous configuration was put back."))
            return
        }
        set(1, .done)

        // 2. Prove a login on the new port.
        set(2, .running)
        let onNew: SSHConnection
        do {
            onNew = try await connections.testLogin(server, port: port)
        } catch {
            set(2, .failed)
            await root.run(ConfigChange.rollbackScript(id: addID), on: server)
            outcome = .undone(String(localized: "Deckhand couldn't log in on port \(String(port)): \(error.localizedDescription) Most often a firewall at your hosting provider blocks the port."))
            return
        }
        guard await root.run(ConfigChange.confirmScript(id: addID), on: server, connection: onNew) else {
            set(2, .failed); outcome = .warning(String(localized: "Couldn't confirm the change; the server switches back by itself within 5 minutes.")); return
        }
        await connections.adopt(onNew, for: server, port: port)
        set(2, .done)

        // 3. Close the old port, over the new connection.
        set(3, .running)
        guard let mid = await inspect(using: onNew) else {
            set(3, .failed); outcome = .warning(String(localized: "Port \(String(port)) works, but the old port is still open. You can close it later.")); return
        }
        let close = SSHPort.closeOldPorts(keep: port, inspection: mid)
        let closeID = ConfigChange.makeID(title: close.title, date: Date().addingTimeInterval(1))
        guard await root.run(close.script(id: closeID), on: server, connection: onNew) else {
            set(3, .failed)
            outcome = .warning(String(localized: "The old port couldn't be closed (\(root.failedStep ?? "error")). Both ports stay open; you can try again later."))
            return
        }
        set(3, .done)

        // 4. Log in again on the new port only, then keep it.
        set(4, .running)
        do {
            let again = try await connections.testLogin(server, port: port)
            guard await root.run(ConfigChange.confirmScript(id: closeID), on: server, connection: again) else { throw CLIError("confirm") }
            await connections.adopt(again, for: server, port: port)
        } catch {
            set(4, .failed)
            outcome = .warning(String(localized: "The login check after closing the old port failed, so the server opens it again by itself within 5 minutes."))
            return
        }
        set(4, .done)
        outcome = .moved(port)
        _ = await inspect()
    }
}
