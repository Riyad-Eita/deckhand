import Foundation

/// A2UI (agent-to-user interface, v1.0): the agent describes native UI as data — surfaces made of components from
/// a catalog, a data model, and events — and the app draws it with its own components. Nothing the agent sends is
/// code. This is the protocol side (checks, the agent's tool, what a tap sends back); the app renders.
public enum A2UI {
    public static let toolName = "show_ui"
    public static let version = "1.0"
    public static let basicCatalogID = "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
    /// Fenced block that carries a tap back to the agent; the chat shows only the readable part.
    public static let actionFence = "a2ui-action"

    static let messageKinds = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]
    static let components: Set<String> = [
        "Text", "Image", "Icon", "Row", "Column", "List", "Card", "Tabs", "Modal", "Divider",
        "Button", "TextField", "CheckBox", "ChoicePicker", "Slider", "DateTimeInput",
    ]
    static let maxMessages = 20
    static let maxComponents = 300
    static let maxBytes = 96_000

    /// The A2UI messages of one `show_ui` call.
    public static func messages(_ input: JSONValue) -> [JSONValue] {
        if let list = input["messages"]?.arrayValue { return list }
        if let list = input.arrayValue { return list }
        return input["version"] != nil ? [input] : []
    }

    /// Fills in what the agent may leave out (the version, the basic catalog).
    public static func normalize(_ messages: [JSONValue]) -> [JSONValue] {
        messages.map { m in
            guard case .object(var o) = m else { return m }
            if o["version"] == nil { o["version"] = .string(version) }
            if case .object(var create)? = o["createSurface"], create["catalogId"] == nil {
                create["catalogId"] = .string(basicCatalogID)
                o["createSurface"] = .object(create)
            }
            return .object(o)
        }
    }

    /// A quick structural check before the renderer sees it: nil when fine, otherwise what to fix (for the agent).
    public static func check(_ raw: [JSONValue]) -> String? {
        let messages = normalize(raw)
        if messages.isEmpty { return "No A2UI messages. Pass {\"messages\": [ … ]}." }
        if messages.count > maxMessages { return "Too many messages (\(messages.count)); send at most \(maxMessages) per call." }
        if JSONValue.array(messages).jsonString().utf8.count > maxBytes { return "The view is too large; keep it under \(maxBytes / 1000) kB." }
        var created = Set<String>()
        var componentCount = 0
        for (i, m) in messages.enumerated() {
            let at = "messages[\(i)]"
            guard case .object(let o) = m else { return "\(at) must be an object." }
            guard o["version"]?.stringValue == version else { return "\(at): \"version\" must be \"\(version)\"." }
            let kinds = o.keys.filter { $0 != "version" }
            guard kinds.count == 1, let kind = kinds.first, messageKinds.contains(kind) else {
                return "\(at) needs exactly one of \(messageKinds.joined(separator: ", ")) next to \"version\"."
            }
            guard let body = o[kind], case .object = body else { return "\(at).\(kind) must be an object." }
            guard let surface = body["surfaceId"]?.stringValue, isIdentifier(surface) else {
                return "\(at).\(kind).surfaceId must be letters, digits, '-', '_' or '.' (up to 64)."
            }
            if kind == "createSurface" {
                guard body["catalogId"]?.stringValue == basicCatalogID else { return "\(at): only the basic catalog \(basicCatalogID) is available." }
                created.insert(surface)
            }
            if let list = body["components"] {
                guard let components = list.arrayValue else { return "\(at).\(kind).components must be a list." }
                componentCount += components.count
                for (j, c) in components.enumerated() {
                    guard let id = c["id"]?.stringValue, !id.isEmpty else { return "\(at).\(kind).components[\(j)] needs an \"id\"." }
                    guard isComponentID(id) else { return "Component id \"\(id)\" must be letters, digits and _ only (no '-'), e.g. \"\(id.replacingOccurrences(of: "-", with: "_"))\"." }
                    guard let type = c["component"]?.stringValue else { return "Component \"\(id)\" needs a \"component\" type." }
                    guard Self.components.contains(type) else {
                        return "Component \"\(id)\": \"\(type)\" isn't available. Use one of: \(Self.components.sorted().joined(separator: ", "))."
                    }
                }
                if kind == "createSurface", !components.isEmpty, !components.contains(where: { $0["id"]?.stringValue == "root" }) {
                    return "\(at): one component must have the id \"root\"."
                }
            }
        }
        if componentCount > maxComponents { return "Too many components (\(componentCount)); keep a view under \(maxComponents)." }
        return nil
    }

    /// Component ids are identifiers (UAX #31): a letter or _ first, then letters, digits or _.
    static func isComponentID(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.count <= 64 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func isIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The surfaces a call creates, in order (the chat draws each where it was created).
    public static func createdSurfaces(_ input: JSONValue) -> [String] {
        messages(input).compactMap { $0["createSurface"]?["surfaceId"]?.stringValue }
    }

    // MARK: - Taps back to the agent

    public struct Action: Sendable, Hashable, Codable {
        public var name: String
        public var surfaceId: String
        public var sourceComponentId: String?
        public var userMessage: String?
        public var context: JSONValue?
        public init(name: String, surfaceId: String, sourceComponentId: String? = nil, userMessage: String? = nil, context: JSONValue? = nil) {
            self.name = name; self.surfaceId = surfaceId; self.sourceComponentId = sourceComponentId
            self.userMessage = userMessage; self.context = context
        }

        /// What the chat shows for the tap.
        public var display: String { userMessage?.isEmpty == false ? userMessage! : String(localized: "Tapped “\(name)”") }
    }

    /// The user message a tap becomes: readable text plus the A2UI `action` message the agent can act on.
    public static func message(for action: Action) -> String {
        var event: [String: JSONValue] = ["name": .string(action.name), "surfaceId": .string(action.surfaceId)]
        if let s = action.sourceComponentId { event["sourceComponentId"] = .string(s) }
        if let u = action.userMessage { event["userMessage"] = .string(u) }
        if let c = action.context { event["context"] = c }
        let json = JSONValue.object(["version": .string(version), "action": .object(event)]).jsonString()
        return "\(action.display)\n\n```\(actionFence)\n\(json)\n```"
    }

    /// The readable part of a user message (the action block hidden), and whether it was a tap.
    public static func displayText(_ text: String) -> (text: String, isAction: Bool) {
        guard let r = text.range(of: "\n\n```\(actionFence)\n") else { return (text, false) }
        return (String(text[..<r.lowerBound]), true)
    }

    // MARK: - What the agent is told

    static let guide = """
    Show the user a native, interactive view in the chat (A2UI v1.0, basic catalog). Use it when a view is clearer \
    than text: a status overview, a table of items, a choice between options, a form to fill in, a confirmation. \
    Don't use it for a plain answer. Don't repeat the view's content in text afterwards.

    Input: {"messages": [ … ]}. Each message is {"version": "1.0", <one of createSurface | updateComponents | \
    updateDataModel | deleteSurface>}.
    - createSurface: {"surfaceId", "components": [...], "dataModel": {...}} (catalogId defaults to the basic catalog). \
    Use a new, unique surfaceId for each new view (e.g. "services-1").
    - updateComponents: {"surfaceId", "components": [...]} replaces components by id (to change a view you showed).
    - updateDataModel: {"surfaceId", "path": "/a/b", "value": …} (value null deletes).
    - deleteSurface: {"surfaceId"}.

    Components are a FLAT list; each has "id" and "component", one must be "root"; children are referenced by id. \
    Component ids are identifiers: letters, digits and _ only, no '-' (e.g. "main_col").
    - Text {text (simple Markdown, e.g. **bold**), variant: body|caption}   - Image {url (https), description, \
    variant: icon|avatar|smallFeature|mediumFeature|largeFeature|header}
    - Icon {name: check|close|warning|error|info|help|refresh|delete|edit|settings|lock|lockOpen|search|download|\
    upload|folder|home|notifications|star|play|pause|stop|send|share|add|moreHoriz}
    - Row / Column {children: [ids], justify, align}   - List {children: [ids], direction}
    - Card {child: id}   - Divider {}   - Tabs {tabs: [{title, child}]}   - Modal {trigger: id, content: id}
    - Button {child: id (usually a Text), variant: default|primary|borderless, action}
    - TextField {label, value, placeholder, variant: shortText|longText|number|obscured}
    - CheckBox {label, value}   - ChoicePicker {label, options: [{label, value}], value: [..], \
    variant: mutuallyExclusive|multipleSelection}   - Slider {label, min, max, value}   - DateTimeInput {label, value, \
    enableDate, enableTime}
    Any component inside a Row or Column may set "weight" (a number, like flex-grow). There is no font weight; \
    use Markdown in Text. Values can be literals or bound to the data model: {"@path": "/form/name"}. Inputs write \
    to their bound path. \
    Join text with {"@call": "formatString", "args": {"value": "CPU ${/cpu}%"}}.

    Buttons send events: "action": {"event": {"name": "restart", "userMessage": "Restart nginx", "context": \
    {"unit": "nginx", "note": {"@path": "/form/note"}}}}. A tap arrives as the user's next message with a \
    ```\(actionFence) block holding {"version":"1.0","action":{name, surfaceId, sourceComponentId, context}}. \
    Then act on it with your other tools as usual — a tap is a request, not an approval; risky commands still ask.

    Example: {"messages":[{"version":"1.0","createSurface":{"surfaceId":"svc-1","components":[\
    {"id":"root","component":"Card","child":"col"},{"id":"col","component":"Column","children":["t","row"]},\
    {"id":"t","component":"Text","text":"**nginx** has failed"},\
    {"id":"row","component":"Row","children":["b1"]},\
    {"id":"b1","component":"Button","child":"b1t","variant":"primary","action":{"event":{"name":"restart","context":{"unit":"nginx"}}}},\
    {"id":"b1t","component":"Text","text":"Restart"}]}}]}
    """
}

/// The agent's `show_ui` tool. `validate` runs the app's renderer over the messages (nil = it draws).
public struct ShowUITool: AgentTool {
    public let validate: @Sendable ([JSONValue]) async -> String?

    public init(validate: @escaping @Sendable ([JSONValue]) async -> String? = { _ in nil }) { self.validate = validate }

    public var spec: ToolSpec {
        ToolSpec(name: A2UI.toolName, description: A2UI.guide, inputSchema: [
            "type": "object",
            "properties": [
                "messages": [
                    "type": "array",
                    "description": "A2UI v1.0 messages, applied in order.",
                    "items": ["type": "object"],
                ],
            ],
            "required": ["messages"],
        ])
    }

    /// Only draws in the chat; changes nothing on a server.
    public var isReadOnly: Bool { true }

    public func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let messages = A2UI.normalize(A2UI.messages(input))
        if let problem = A2UI.check(messages) { throw ToolError.failed(problem) }
        if let problem = await validate(messages) { throw ToolError.failed("The view couldn't be drawn: \(problem)") }
        let surfaces = A2UI.createdSurfaces(input)
        return surfaces.isEmpty
            ? "Updated the view in the chat."
            : "Shown in the chat (\(surfaces.joined(separator: ", "))). The user's taps come back as their next message."
    }
}
