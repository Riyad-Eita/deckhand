import DeckhandCore
import DeckhandSSH
import SwiftData
import SwiftUI
import UIKit
import VisionKit

/// First setup without typing a password or copying a key: one line on the server shows a QR code, the app scans it,
/// checks the server's identity against the code and puts its own key there.
struct PairingGuideView: View {
    /// Called after a server was added (e.g. to close the screen that opened this one).
    var onPaired: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var code: Pairing.Code?
    @State private var copied = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Step(number: 1, text: String(localized: "Open a terminal on the server: over SSH from your computer, or in your provider's web console."))
                    Step(number: 2, text: String(localized: "Run this line as the user Deckhand should sign in as:"))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Pairing.command).font(Theme.monoSmall).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = Pairing.command
                            copied = true
                        } label: { Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .font(.subheadline)
                            .accessibilityIdentifier("pair.copy")
                    }
                    Step(number: 3, text: String(localized: "Scan the QR code it shows."))
                } footer: {
                    Text("The code holds a key that works once, for 15 minutes, and can only hand over this \(Device.name)'s own key. No password or private key ever leaves the server or this \(Device.name).")
                }
                Section {
                    Button { scanning = true } label: { Label("Scan the Code", systemImage: "qrcode.viewfinder") }
                        .accessibilityIdentifier("pair.scan")
                        .disabled(!QRScanner.isAvailable)
                } footer: {
                    if !QRScanner.isAvailable { Text("The camera isn't available here. Scan the code with the Camera app instead — it opens Deckhand.") }
                    else { Text("The Camera app works too: it opens Deckhand with the code.") }
                }
                if let scanError { ProblemView(message: scanError, compact: true) }
            }
            .navigationTitle("Pair with a QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .appSheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    if let url = URL(string: text), let c = Pairing.parse(url) { code = c; scanError = nil }
                    else { scanError = String(localized: "That's not a Deckhand pairing code.") }
                }
                .ignoresSafeArea()
            }
            .navigationDestination(item: $code) { c in PairingConfirmView(code: c, onDone: { onPaired(); dismiss() }) }
        }
    }

    private struct Step: View {
        let number: Int
        let text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.accent)
                Text(text)
            }
        }
    }
}

/// A scanned code: where it connects, then one tap to pair.
struct PairingConfirmView: View {
    let code: Pairing.Code
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var host = ""
    @State private var port = ""
    @State private var editingAddress = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Server", value: code.name)
                LabeledContent("User", value: code.user)
                if editingAddress {
                    TextField("Address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).font(Theme.mono)
                        .accessibilityIdentifier("pair.host")
                    TextField("Port", text: $port).keyboardType(.numberPad).font(Theme.mono)
                } else {
                    LabeledContent("Address", value: "\(host):\(port)")
                    Button("Use Another Address") { editingAddress = true }.font(.subheadline)
                }
            } footer: {
                Text("The server's identity is checked against the code, so nothing is sent to a different machine at this address.")
            }
            if let error { ProblemView(message: error, compact: true) }
            Section {
                Button { Task { await pair() } } label: {
                    HStack { Text("Connect"); Spacer(); if busy { ProgressView() } }
                }
                .disabled(busy || code.isExpired())
                .accessibilityIdentifier("pair.connect")
            } footer: {
                if code.isExpired() {
                    Text("This code has expired. Run the line on the server again.")
                } else {
                    Text("Valid until \(code.expires.formatted(date: .omitted, time: .shortened)). Deckhand makes a key on this \(Device.name), puts the public half on the server and signs in with it from now on.")
                }
            }
        }
        .navigationTitle("Pair with \(code.name)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if host.isEmpty { host = code.host; port = String(code.port) } }
    }

    private func pair() async {
        busy = true
        defer { busy = false }
        error = nil
        let target = host.trimmingCharacters(in: .whitespaces)
        guard let p = Int(port), (1...65535).contains(p), !target.isEmpty else {
            error = String(localized: "Check the address and port.")
            return
        }
        do {
            let result = try await PairingClient.pair(code, host: target, port: p, deviceName: UIDevice.current.name)
            let server = Server(name: code.name, host: target, port: p, username: code.user, authKind: .key)
            server.pinnedHostKey = result.hostKey
            context.insert(server)
            Keychain.set(result.privateKey, for: server.secretAccount)
            try? context.save()
            AppRouter.shared.pendingServer = server.id
            onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A QR code reader (VisionKit). Calls back with the first code's text.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    @MainActor static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let b) = item, let text = b.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}

/// Opens a pairing code from a link (the Camera app, a tapped `deckhand://pair` link).
struct PairingLinkModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        content.appSheet(item: Binding(get: { enabled ? AppRouter.shared.pendingPairing : nil },
                                    set: { AppRouter.shared.pendingPairing = $0 })) { link in
            NavigationStack {
                PairingConfirmView(code: link.code)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { AppRouter.shared.pendingPairing = nil } } }
            }
        }
    }
}

extension Pairing.Code: @retroactive Identifiable {
    public var id: String { host + ":\(port)/" + user + "/" + seed.base64EncodedString() }
}
