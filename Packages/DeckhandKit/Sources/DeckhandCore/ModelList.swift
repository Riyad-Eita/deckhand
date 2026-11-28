import Foundation

/// The models a provider offers right now (`GET …/models`), so the picker never goes stale. Free text stays possible.
public enum ModelList {
    public struct Model: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String?
        /// Known from the provider's list (OpenRouter sends prices).
        public var price: ModelPriceCodable?
        public init(id: String, name: String? = nil, price: ModelPriceCodable? = nil) { self.id = id; self.name = name; self.price = price }
    }

    /// `ModelPrice` as stored data.
    public struct ModelPriceCodable: Sendable, Hashable, Codable {
        public var input: Double
        public var output: Double
        public var price: ModelPrice { ModelPrice(input: input, output: output) }
    }

    /// The request for a provider's model list.
    public static func request(_ config: ProviderConfig) -> URLRequest {
        let url: URL = switch config.kind {
        case .anthropic: config.baseURL.appending(path: "v1/models").appending(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        case .openAI, .openRouter, .custom: config.baseURL.appending(path: "models")
        }
        var r = URLRequest(url: url, timeoutInterval: 20)
        switch config.kind {
        case .anthropic:
            r.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            if !config.apiKey.isEmpty { r.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        }
        return r
    }

    /// Model ids that can't chat (embeddings, speech, images, moderation): left out of OpenAI's list.
    static let notChat = ["embedding", "tts", "whisper", "dall-e", "transcribe", "moderation", "image", "audio", "realtime", "search", "davinci", "babbage", "computer-use"]

    /// Parses a `/models` reply. Newest first where the provider says when a model came out.
    public static func parse(_ data: Data, kind: ProviderKind) throws -> [Model] {
        let json = try JSONValue.parse(data)
        if let message = json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue {
            throw LLMError.badStream(message)
        }
        var out: [(Model, Double)] = []
        for m in json["data"]?.arrayValue ?? json["models"]?.arrayValue ?? [] {
            guard let id = m["id"]?.stringValue ?? m["name"]?.stringValue, !id.isEmpty else { continue }
            if kind == .openAI, notChat.contains(where: { id.contains($0) }) { continue }
            var price: ModelPriceCodable?
            if let p = m["pricing"], let i = Double(p["prompt"]?.stringValue ?? ""), let o = Double(p["completion"]?.stringValue ?? "") {
                price = ModelPriceCodable(input: i * 1_000_000, output: o * 1_000_000)
            }
            let created = m["created"]?.doubleValue
                ?? m["created_at"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 } ?? 0
            out.append((Model(id: id, name: m["display_name"]?.stringValue ?? m["name"]?.stringValue, price: price), created))
        }
        return out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }.map(\.0)
    }

    /// The models to offer: the recommended ones that exist first (marked), then the rest of the live list.
    /// Without a live list: the built-in suggestions.
    public static func choices(live: [Model]?, kind: ProviderKind) -> [(id: String, recommended: Bool)] {
        guard let live, !live.isEmpty else { return kind.suggestedModels.map { ($0, true) } }
        let ids = live.map(\.id)
        let recommended = kind.suggestedModels.filter(ids.contains)
        return recommended.map { ($0, true) } + ids.filter { !recommended.contains($0) }.map { ($0, false) }
    }
}
