import AuthenticationServices
import DeckhandCore
import Foundation
import UIKit

/// OAuth sign-in for remote MCP servers: discovery, client registration, Apple's sign-in sheet with PKCE, and tokens
/// kept in the Keychain and refreshed before they run out.
@MainActor
enum MCPAuth {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func account(_ record: ConnectionRecord) -> String { record.secretAccount + ".oauth" }

    static func tokens(_ record: ConnectionRecord) -> MCPOAuth.Tokens? {
        Keychain.get(account(record)).flatMap { try? JSONDecoder().decode(MCPOAuth.Tokens.self, from: Data($0.utf8)) }
    }

    static func save(_ tokens: MCPOAuth.Tokens?, for record: ConnectionRecord) {
        let json = tokens.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        Keychain.set(json, for: account(record))
    }

    /// What a connection sends as its bearer token: the OAuth access token (refreshed first when due) or the token
    /// typed in by hand.
    static func bearer(for record: ConnectionRecord) async -> String? {
        guard var t = tokens(record) else { return record.token }
        if t.needsRefresh(), let request = MCPOAuth.refreshRequest(t),
           let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode ?? 500 < 400,
           let fresh = MCPOAuth.parseTokens(data, endpoint: t.tokenEndpoint, clientID: t.clientID, resource: t.resource, previous: t) {
            t = fresh
            save(t, for: record)
        }
        return t.accessToken
    }

    /// Every enabled connection with what it authenticates with.
    static func resolved(_ records: [ConnectionRecord]) async -> [(MCPConnection, String?)] {
        var out: [(MCPConnection, String?)] = []
        for r in records { out.append((r.spec, await bearer(for: r))) }
        return out
    }

    /// Does this server want an OAuth sign-in? Returns the WWW-Authenticate header of its 401, or nil.
    static func challenge(_ url: URL) async -> String? {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Deckhand","version":"1.0"}}}"#.utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: r), let http = response as? HTTPURLResponse, http.statusCode == 401 else { return nil }
        return http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
    }

    /// The whole sign-in for an MCP server URL.
    static func signIn(url: URL) async throws -> MCPOAuth.Tokens {
        guard let header = await challenge(url) else { throw Failure(message: String(localized: "This server doesn't ask for a sign-in.")) }
        // Where the server's authorization lives (protected resource metadata, else its own origin, as older servers do).
        var issuer: URL?
        if let metaURL = MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: header) ?? MCPOAuth.defaultResourceMetadataURL(for: url),
           let (data, resp) = try? await URLSession.shared.data(from: metaURL), (resp as? HTTPURLResponse)?.statusCode == 200 {
            issuer = MCPOAuth.authorizationServer(fromResourceMetadata: data)
        }
        if issuer == nil, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) { c.path = ""; c.query = nil; issuer = c.url }
        guard let issuer else { throw Failure(message: String(localized: "The server didn't say where to sign in.")) }
        var meta: MCPOAuth.ServerMetadata?
        for candidate in MCPOAuth.metadataURLs(issuer: issuer) {
            if let (data, resp) = try? await URLSession.shared.data(from: candidate), (resp as? HTTPURLResponse)?.statusCode == 200,
               let m = MCPOAuth.parseServerMetadata(data) { meta = m; break }
        }
        guard let meta else { throw Failure(message: String(localized: "The sign-in server doesn't describe itself (or doesn't support PKCE).")) }
        guard let reg = meta.registrationEndpoint.flatMap(URL.init(string:)) else {
            throw Failure(message: String(localized: "This server needs an app registered by hand; use a token from its settings instead."))
        }
        var r = URLRequest(url: reg); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = MCPOAuth.registrationBody()
        let (regData, regResp) = try await URLSession.shared.data(for: r)
        guard (regResp as? HTTPURLResponse)?.statusCode ?? 500 < 400, let clientID = MCPOAuth.clientID(fromRegistration: regData) else {
            throw Failure(message: String(localized: "The server didn't register Deckhand as a client."))
        }
        let pkce = MCPOAuth.PKCE()
        guard let authorize = MCPOAuth.authorizeURL(meta, clientID: clientID, pkce: pkce, resource: url.absoluteString) else {
            throw Failure(message: String(localized: "The sign-in address is invalid."))
        }
        let callback = try await AuthSheet().run(authorize)
        let code = try MCPOAuth.code(fromCallback: callback, pkce: pkce)
        guard let exchange = MCPOAuth.tokenRequest(endpoint: meta.tokenEndpoint, code: code, pkce: pkce, clientID: clientID, resource: url.absoluteString) else {
            throw Failure(message: String(localized: "The token address is invalid."))
        }
        let (tokData, tokResp) = try await URLSession.shared.data(for: exchange)
        guard (tokResp as? HTTPURLResponse)?.statusCode ?? 500 < 400,
              let tokens = MCPOAuth.parseTokens(tokData, endpoint: meta.tokenEndpoint, clientID: clientID, resource: url.absoluteString) else {
            throw Failure(message: String(localized: "The server didn't hand out a token."))
        }
        return tokens
    }
}

/// Apple's sign-in sheet, waiting for the deckhand://oauth/callback redirect.
@MainActor
private final class AuthSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            let s = ASWebAuthenticationSession(url: url, callback: .customScheme(MCPOAuth.callbackScheme)) { callback, error in
                if let callback { c.resume(returning: callback) } else { c.resume(throwing: error ?? MCPAuth.Failure(message: String(localized: "The sign-in was cancelled."))) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
