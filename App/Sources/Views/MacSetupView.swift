#if targetEnvironment(macCatalyst)
import DeckhandCore
import Network
import SwiftUI

/// "Use this Mac from your iPhone": turn on Remote Login, then scan a QR code with Deckhand on the iPhone. The iPhone
/// talks to the Mac over SSH like to any server — no relay. No password or key is in the code.
struct MacSetupView: View {
    @State private var remoteLogin: Bool?
    @State private var tailscaleName = ""
    private let hostName = ProcessInfo.processInfo.hostName
    private let user = NSUserName()

    private var link: String? { MacSetup.link(hostName: hostName, user: user, override: tailscaleName) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    StepNumber(n: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Turn on Remote Login").font(.headline)
                        Text("System Settings → General → Sharing → Remote Login. Allow access for your user.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Open Sharing Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            status
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                HStack(alignment: .top, spacing: 14) {
                    StepNumber(n: 2)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Scan this code with Deckhand on your iPhone").font(.headline)
                        Text("Your iPhone's camera opens Deckhand with this Mac filled in. The code holds only the address and your user name — no password, no key.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let link, let qr = QRCode.image(link) {
                            Image(uiImage: qr)
                                .interpolation(.none).resizable().scaledToFit()
                                .frame(width: 220, height: 220)
                                .padding(12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .accessibilityLabel("QR code for this Mac")
                                .accessibilityIdentifier("macSetup.qr")
                            Text(verbatim: "\(user)@\(MacSetup.address(hostName: hostName, override: tailscaleName))")
                                .font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        TextField("Away from home? Tailscale name or IP (optional)", text: $tailscaleName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("macSetup.tailscale")
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                HStack(alignment: .top, spacing: 14) {
                    StepNumber(n: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign in once on the iPhone").font(.headline)
                        Text("Use your Mac password the first time. Deckhand then installs its own key on this Mac and forgets the password. Claude Code and Codex run here like on a server — with your house rules and approvals.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text("A sleeping Mac can't answer. To reach it any time, turn on \"Prevent automatic sleeping when the display is off\" in System Settings → Energy, or keep it on power.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Use This Mac From Your iPhone")
        .task {
            while !Task.isCancelled {
                remoteLogin = await RemoteLoginProbe.isOn()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch remoteLogin {
        case .some(true):
            Label("Remote Login is on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityIdentifier("macSetup.on")
        case .some(false):
            Label("Remote Login is off", systemImage: "xmark.circle").foregroundStyle(.secondary)
                .accessibilityIdentifier("macSetup.off")
        case .none:
            ProgressView().controlSize(.small)
        }
    }
}

private struct StepNumber: View {
    let n: Int
    var body: some View {
        Text(verbatim: "\(n)")
            .font(.headline.monospacedDigit()).foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Theme.accent, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Is something answering on this Mac's SSH port? (Remote Login on.)
enum RemoteLoginProbe {
    static func isOn() async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: "127.0.0.1", port: 22, using: .tcp)
            let done = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if done.claim() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .waiting: if done.claim() { conn.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if done.claim() { conn.cancel(); cont.resume(returning: false) } }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var used = false
        func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }
}
#endif
