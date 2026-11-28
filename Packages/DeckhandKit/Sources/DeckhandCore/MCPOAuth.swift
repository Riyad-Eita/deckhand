import CryptoKit
import Foundation

/// Sign-in for remote MCP servers that use OAuth (MCP authorization spec: OAuth 2.1 with PKCE, protected resource
/// metadata, authorization server metadata, dynamic client registration). The app opens the authorize URL in
/// ASWebAuthenticationSession; this is the protocol side: discovery, requests and token handling.
public enum MCPOAuth {
    public static let redirectURI = "deckhand://oauth/callback"
    public static let callbackScheme = "deckhand"

    public struct Tokens: Codable, Sendable, Hashable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public var tokenEndpoint: String
        public var clientID: String
        public var resource: String
        /// Refresh a minute early.
        public func needsRefresh(now: Date = Date()) -> Bool { expiresAt.map { $0.addingTimeInterval(-60) <= now } ?? false }
    }

    public struct ServerMetadata: Sendable, Hashable {
        public var issuer: String
        public var authorizationEndpoint: String
        public var tokenEndpoint: String
        public var registrationEndpoint: String?
        public var scopes: [String]
    }

    // MARK: - Discovery

    /// `resource_metadata="…"` from a 401's WWW-Authenticate header.
    public static func resourceMetadataURL(fromWWWAuthenticate header: String?) -> URL? {
        guard let header, let r = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else { return nil }
        let value = header[r].dropFirst("resource_metadata=\"".count).dropLast()
        return URL(string: String(value))
    }

    /// Where protected resource metadata lives when the server didn't say (RFC 9728: well-known + the path).
    public static func defaultResourceMetadataURL(for server: URL) -> URL? {
        guard var c = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        let path = c.path == "/" ? "" : c.path
        c.path = "/.well-known/oauth-protected-resource" + path
        c.query = nil
        return c.url
    }

    /// The authorization server named by the resource metadata.
    public static func authorizationServer(fromResourceMetadata data: Data) -> URL? {
        guard let json = try? JSONValue.parse(data), let first = json["authorization_servers"]?.arrayValue?.first?.stringValue else { return nil }
        return URL(string: first)
    }

    /// Candidate metadata URLs for an issuer (RFC 8414 with path insertion, then OpenID Connect discovery).
    public static func metadataURLs(issuer: URL) -> [URL] {
        guard var c = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
        let path = c.path == "/" ? "" : c.path
        var out: [URL] = []
        for wk in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
            c.path = wk + path
            if let u = c.url { out.append(u) }
        }
        if !path.isEmpty, let u = URL(string: issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.well-known/openid-configuration") {
            out.append(u)
        }
        return out
    }

    public static func parseServerMetadata(_ data: Data) -> ServerMetadata? {
        guard let j = try? JSONValue.parse(data), let auth = j["authorization_endpoint"]?.stringValue, let token = j["token_endpoint"]?.stringValue else { return nil }
        if let methods = j["code_challenge_methods_supported"]?.arrayValue, !methods.contains(.string("S256")) { return nil }
        return ServerMetadata(issuer: j["issuer"]?.stringValue ?? "", authorizationEndpoint: auth, tokenEndpoint: token,
                              registrationEndpoint: j["registration_endpoint"]?.stringValue,
                              scopes: (j["scopes_supported"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    // MARK: - Client registration (RFC 7591)

    public static func registrationBody() -> Data {
        let body: JSONValue = [
            "client_name": "Deckhand",
            "redirect_uris": [.string(redirectURI)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        return Data(body.jsonString().utf8)
    }

    public static func clientID(fromRegistration data: Data) -> String? {
        (try? JSONValue.parse(data))?["client_id"]?.stringValue
    }

    // MARK: - PKCE and the authorize URL

    public struct PKCE: Sendable, Hashable {
        public var verifier: String
        public var challenge: String
        public var state: String

        public init(verifier: String? = nil, state: String? = nil) {
            self.verifier = verifier ?? Self.random(48)
            self.challenge = Self.base64url(Data(SHA256.hash(data: Data(self.verifier.utf8))))
            self.state = state ?? Self.random(24)
        }

        static func random(_ bytes: Int) -> String {
            var data = Data(count: bytes)
            _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
            return base64url(data)
        }

        static func base64url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }

    public static func authorizeURL(_ meta: ServerMetadata, clientID: String, pkce: PKCE, resource: String) -> URL? {
        guard var c = URLComponents(string: meta.authorizationEndpoint) else { return nil }
        var items = c.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "resource", value: resource),
        ]
        if !meta.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: meta.scopes.joined(separator: " "))) }
        c.queryItems = items
        return c.url
    }

    public enum CallbackError: LocalizedError, Equatable {
        case denied(String)
        case stateMismatch
        case noCode
        public var errorDescription: String? {
            switch self {
            case .denied(let why): String(localized: "The sign-in was refused: \(why)")
            case .stateMismatch: String(localized: "The sign-in answer didn't match this request. Try again.")
            case .noCode: String(localized: "The sign-in ended without a code. Try again.")
            }
        }
    }

    /// The code from the redirect, after checking it belongs to this sign-in.
    public static func code(fromCallback url: URL, pkce: PKCE) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let e = v("error") { throw CallbackError.denied(v("error_description") ?? e) }
        guard v("state") == pkce.state else { throw CallbackError.stateMismatch }
        guard let code = v("code"), !code.isEmpty else { throw CallbackError.noCode }
        return code
    }

    // MARK: - Tokens

    static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    public static func tokenRequest(endpoint: String, code: String, pkce: PKCE, clientID: String, resource: String) -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var r = URLRequest(url: url); r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = form([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                           ("client_id", clientID), ("code_verifier", pkce.verifier), ("resource", resource)])
        return r
    }

    public static func refreshRequest(_ t: Tokens) -> URLRequest? {
        guard let refresh = t.refreshToken, let url = URL(string: t.tokenEndpoint) else { return nil }
        var r = URLRequest(url: url); r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = form([("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", t.clientID), ("resource", t.resource)])
        return r
    }

    /// Tokens from a token response; a refresh that sends no new refresh token keeps the old one.
    public static func parseTokens(_ data: Data, endpoint: String, clientID: String, resource: String, previous: Tokens? = nil, now: Date = Date()) -> Tokens? {
        guard let j = try? JSONValue.parse(data), let access = j["access_token"]?.stringValue else { return nil }
        return Tokens(accessToken: access, refreshToken: j["refresh_token"]?.stringValue ?? previous?.refreshToken,
                      expiresAt: j["expires_in"]?.doubleValue.map { now.addingTimeInterval($0) },
                      tokenEndpoint: endpoint, clientID: clientID, resource: resource)
    }
}
