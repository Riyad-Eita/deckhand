import A2UICore
import A2UISwiftUI
import BasicCatalog
import BasicCatalogSwiftUI
import DeckhandCore
import Foundation
import SwiftUI
import UIKit

/// The A2UI renderer for one chat: applies the agent's `show_ui` messages to native surfaces and hands taps back
/// to the chat as the user's next message. Rebuilt from the chat's history when it is opened again.
@MainActor
final class A2UIHost: ObservableObject {
    let processor: MessageProcessor
    let catalog: Catalog<ComponentImplementation>
    private let parser = MessageParser()
    private let outbox = Outbox()
    private let links = LinkOpener()
    /// A tap on a button the agent drew.
    var onAction: ((DeckhandCore.A2UI.Action) -> Void)?

    init() {
        catalog = BasicCatalogImplementation.makeCatalog(version: .v10, openURLHandler: links)
        processor = MessageProcessor(catalogs: [catalog])
        let outbox = self.outbox
        processor.outboundListener = { [weak self] message in
            guard let data = try? JSONEncoder().encode(message),
                  let json = try? JSONDecoder().decode(DeckhandCore.JSONValue.self, from: data) else { return }
            if let error = json["error"] {
                outbox.add(error["message"]?.stringValue ?? error["code"]?.stringValue ?? error.jsonString())
            } else if let a = json["action"], let name = a["name"]?.stringValue, let surface = a["surfaceId"]?.stringValue {
                let action = DeckhandCore.A2UI.Action(
                    name: name, surfaceId: surface, sourceComponentId: a["sourceComponentId"]?.stringValue,
                    userMessage: a["userMessage"]?.stringValue, context: a["context"])
                Task { @MainActor in self?.onAction?(action) }
            }
        }
    }

    /// Applies messages in order. Returns what went wrong (for the agent), or nil when everything drew.
    @discardableResult
    func apply(_ messages: [DeckhandCore.JSONValue]) -> String? {
        outbox.reset()
        for m in DeckhandCore.A2UI.normalize(messages) {
            do {
                processor.process(message: try parser.parse(jsonString: m.jsonString()))
            } catch {
                return String(describing: error)
            }
        }
        return outbox.first
    }

    /// Replays every `show_ui` call of a chat that wasn't an error, so its views come back.
    func replay(_ history: [Message]) {
        var failed = Set<String>()
        for message in history {
            for case .toolResult(let r) in message.blocks where r.isError { failed.insert(r.toolUseID) }
        }
        for message in history {
            for case .toolUse(let call) in message.blocks where call.name == DeckhandCore.A2UI.toolName && !failed.contains(call.id) {
                apply(DeckhandCore.A2UI.messages(call.input))
            }
        }
    }

    func surface(_ id: String) -> SurfaceViewModel? { processor.surfaceGroupModel[id] }

    /// Collects renderer errors while messages are applied (the listener is called synchronously).
    private final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [String] = []
        func reset() { lock.withLock { errors = [] } }
        func add(_ e: String) { lock.withLock { errors.append(e) } }
        var first: String? { lock.withLock { errors.first } }
    }

    /// `openUrl` from a view: only after a tap (the renderer checks that), only http(s), mailto and tel.
    private final class LinkOpener: OpenURLHandler, @unchecked Sendable {
        func open(_ url: URL) {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
    }
}

/// One surface the agent drew, inline in the chat. `pending`: the call is still running (the surface may come).
struct A2UISurfaceView: View {
    let host: A2UIHost
    let surfaceID: String
    var pending = false

    var body: some View {
        SurfaceSlot(group: host.processor.surfaceGroupModel, catalog: host.catalog, surfaceID: surfaceID, pending: pending)
            .accessibilityIdentifier("a2ui.surface.\(surfaceID)")
    }
}

private struct SurfaceSlot: View {
    @ObservedObject var group: SurfaceGroupModel
    let catalog: Catalog<ComponentImplementation>
    let surfaceID: String
    let pending: Bool

    var body: some View {
        if let vm = group[surfaceID] {
            SurfaceBox(viewModel: vm, catalog: catalog)
        } else if pending {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label("This view was closed.", systemImage: "rectangle.dashed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SurfaceBox: View {
    @ObservedObject var viewModel: SurfaceViewModel
    let catalog: Catalog<ComponentImplementation>

    var body: some View {
        // Inline like the agent's text: the agent's own Cards group things, so no box around the whole view.
        Surface(viewModel: viewModel, catalogs: [catalog])
            .a2uiButtonStyle(DeckhandButtonStyle())
            .tint(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Buttons in the app's look: compact, never wrapping their label, a clear primary.
private struct DeckhandButtonStyle: A2UIButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let v = configuration.variant
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, v == .borderless ? 2 : 14)
            .frame(minHeight: v == .borderless ? 30 : 36)
            .foregroundStyle(v == .primary ? Color.white : Theme.accent)
            .background {
                switch v {
                case .primary: RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent)
                case .standard: RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.12))
                case .borderless: Color.clear
                }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isDisabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
    }
}
