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
    /// Views that couldn't be drawn, by where they came from (a reply's block, a tool call's id): what went wrong.
    @Published private(set) var problems: [String: String] = [:]

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
    /// `reuseSurfaces`: a surface that is already there is kept (an MCP layout filled in again) instead of an error.
    @discardableResult
    func apply(_ messages: [DeckhandCore.JSONValue], reuseSurfaces: Bool = false) -> String? {
        outbox.reset()
        for m in DeckhandCore.A2UI.normalize(messages) {
            if reuseSurfaces, let id = m["createSurface"]?["surfaceId"]?.stringValue, processor.surfaceGroupModel[id] != nil { continue }
            do {
                processor.process(message: try parser.parse(jsonString: m.jsonString()))
            } catch {
                return String(describing: error)
            }
        }
        return outbox.first
    }

    /// A ```a2ui block in a session's reply (Claude Code, Codex). Drawn once; a block seen again is left alone.
    func applyBlock(_ raw: String) {
        guard !seenBlocks.contains(raw) else { return }
        seenBlocks.insert(raw)
        switch DeckhandCore.A2UI.parseBlock(raw) {
        case .failure(let e): problems[raw] = e.message
        case .success(let messages): if let p = apply(messages) { problems[raw] = p }
        }
    }
    private var seenBlocks = Set<String>()

    /// The view an MCP tool returned with its result.
    func applyResult(_ result: ToolResult) {
        guard !result.a2ui.isEmpty, !seenResults.contains(result.toolUseID) else { return }
        seenResults.insert(result.toolUseID)
        let messages = DeckhandCore.A2UI.normalize(result.a2ui)
        if let p = DeckhandCore.A2UI.check(messages) ?? apply(messages, reuseSurfaces: true) { problems[result.toolUseID] = p }
    }
    private var seenResults = Set<String>()

    /// Every view a message brings: blocks in a reply, views in tool results.
    func take(_ message: Message) {
        for block in message.blocks {
            switch block {
            case .text(let t) where message.role == .assistant:
                DeckhandCore.A2UI.viewBlocks(t).forEach(applyBlock)
            case .toolResult(let r):
                applyResult(r)
            default: break
            }
        }
    }

    /// Replays a chat in order — `show_ui` calls that weren't errors, reply blocks, tool results — so its views come back.
    func replay(_ history: [Message]) {
        var failed = Set<String>()
        for message in history {
            for case .toolResult(let r) in message.blocks where r.isError { failed.insert(r.toolUseID) }
        }
        for message in history {
            for case .toolUse(let call) in message.blocks where call.name == DeckhandCore.A2UI.toolName && !failed.contains(call.id) {
                apply(DeckhandCore.A2UI.messages(call.input))
            }
            take(message)
        }
    }

    /// The surfaces a tool result or a reply block creates (where the chat draws them).
    static func surfaces(in messages: [DeckhandCore.JSONValue]) -> [String] {
        var ids: [String] = []
        for m in messages { if let id = m["createSurface"]?["surfaceId"]?.stringValue, !ids.contains(id) { ids.append(id) } }
        return ids
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
