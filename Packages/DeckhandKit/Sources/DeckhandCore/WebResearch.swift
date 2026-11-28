import Foundation

/// Web research for the own-key agent: Anthropic's server tools (the model searches and reads pages itself, results
/// come back cited), or, for other providers, a fetch through curl on the server. Sources are shown in the chat.
public enum WebResearch {
    /// Models that take the dynamic-filtering tool versions; older ones get the basic web search.
    static func hasDynamicFiltering(_ model: String) -> Bool {
        let id = model.split(separator: "/").last.map(String.init) ?? model
        let newer = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                     "claude-sonnet-5", "claude-sonnet-4-6"]
        return newer.contains { id.hasPrefix($0) }
    }

    /// The server tools for a request (searches are billed by Anthropic; a few per turn are plenty on a phone).
    public static func serverTools(model: String, maxUses: Int = 5) -> [JSONValue] {
        if hasDynamicFiltering(model) {
            return [
                ["type": "web_search_20260209", "name": "web_search", "max_uses": .number(Double(maxUses))],
                ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": .number(Double(maxUses))],
            ]
        }
        return [["type": "web_search_20250305", "name": "web_search", "max_uses": .number(Double(maxUses))]]
    }

    public struct Source: Sendable, Hashable, Identifiable {
        public var title: String
        public var url: String
        public var id: String { url }
        public var host: String { URL(string: url)?.host ?? url }
    }

    public struct Activity: Sendable, Hashable {
        /// What was searched or fetched, in order.
        public var queries: [String] = []
        public var sources: [Source] = []
        public var errors: [String] = []
        public var isEmpty: Bool { queries.isEmpty && sources.isEmpty && errors.isEmpty }
    }

    /// What a reply did on the web: its searches and fetches, the pages it got back (no duplicates), and errors.
    public static func activity(in message: Message) -> Activity {
        var a = Activity()
        for case .opaque("anthropic", let b) in message.blocks {
            switch b["type"]?.stringValue {
            case "server_tool_use":
                if let q = b["input"]?["query"]?.stringValue { a.queries.append(q) }
                if let u = b["input"]?["url"]?.stringValue { a.queries.append(u) }
            case "web_search_tool_result":
                if let list = b["content"]?.arrayValue {
                    for r in list where r["type"]?.stringValue == "web_search_result" {
                        add(&a, title: r["title"]?.stringValue, url: r["url"]?.stringValue)
                    }
                } else if let code = b["content"]?["error_code"]?.stringValue { a.errors.append(code) }
            case "web_fetch_tool_result":
                let c = b["content"]
                if let code = c?["error_code"]?.stringValue { a.errors.append(code) }
                else { add(&a, title: c?["content"]?["title"]?.stringValue, url: c?["url"]?.stringValue) }
            default: break
            }
        }
        return a
    }

    static func add(_ a: inout Activity, title: String?, url: String?) {
        guard let url, url.hasPrefix("http"), !a.sources.contains(where: { $0.url == url }) else { return }
        a.sources.append(Source(title: (title?.isEmpty == false ? title! : URL(string: url)?.host) ?? url, url: url))
    }
}

/// Fallback for providers without server tools: fetches a page through curl on the server, as text.
public struct FetchURLTool: AgentTool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "fetch_url", description: """
        Fetch a web page (http/https) through the server and get its readable text (scripts and styles removed, \
        up to about 60 kB). Use it for documentation, changelogs, release notes or error messages you need to look up. \
        Name the URLs you used when you answer.
        """, inputSchema: [
            "type": "object",
            "properties": ["url": ["type": "string", "description": "The http(s) address to fetch."]],
            "required": ["url"],
        ])
    }

    /// Only reads from the web.
    public var isReadOnly: Bool { true }

    public static func command(url: String) -> String? {
        guard let u = URL(string: url), u.scheme == "http" || u.scheme == "https", u.host != nil, !url.contains("'") else { return nil }
        return """
        curl -sSL --max-time 25 --max-filesize 5000000 -A 'Mozilla/5.0 (Deckhand)' \(ShellQuote.quote(url)) 2>&1 \
        | sed -e 's/<script[^>]*>.*<\\/script>//g' -e 's/<style[^>]*>.*<\\/style>//g' -e 's/<[^>]*>/ /g' \
        | tr -s ' \\t' ' ' | grep -v '^ *$' | head -c 60000
        """
    }

    public func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        guard let url = input["url"]?.stringValue, let cmd = Self.command(url: url) else { throw ToolError.failed("Give an http(s) URL.") }
        let out = try await shell.run(cmd, timeout: .seconds(40)).stdout
        return out.isEmpty ? "The page was empty or couldn't be loaded." : out
    }
}
