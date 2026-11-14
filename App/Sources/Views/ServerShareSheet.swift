import CoreImage.CIFilterBuiltins
import DeckhandCore
import SwiftData
import SwiftUI

/// Share where a server is: a `deckhand://add` link and its QR code. Another iPhone opens it with the camera and
/// sees the server on its import screen. Only the address and user name travel — no password, no key.
struct ServerShareSheet: View {
    let server: Server
    @Environment(\.dismiss) private var dismiss
    @Query private var servers: [Server]
    @State private var copied = false

    private var link: String {
        let jump = server.jumpHostID.flatMap { id in servers.first { $0.id == id } }
            .map { "\($0.username)@\($0.host)" + ($0.port == 22 ? "" : ":\($0.port)") }
        return HostLink.link(for: HostImport.Candidate(name: server.displayName, host: server.host, port: server.port,
                                                       user: server.username, proxyJump: jump))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let qr = QRCode.image(link) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260)
                            .padding(16)
                            // Always dark on white: scanners need the contrast, in dark mode too.
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("QR code for \(server.displayName)")
                            .accessibilityIdentifier("share.qr")
                    }
                    Text(link)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("share.link")
                    HStack {
                        Button {
                            UIPasteboard.general.string = link
                            copied = true
                        } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("share.copy")
                        ShareLink(item: link) { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Scan it with the Camera on another iPhone that has Deckhand. Only the address and the user name are in it — no password, no key. The other side signs in with their own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(server.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A crisp QR code for a short text (a link).
enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
