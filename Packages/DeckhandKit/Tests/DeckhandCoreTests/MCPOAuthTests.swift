import CryptoKit
import Foundation
import Testing
@testable import DeckhandCore

@Suite struct MCPOAuthTests {
    @Test func discovery() throws {
        #expect(MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: #"Bearer realm="mcp", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#)?.absoluteString
                == "https://mcp.example.com/.well-known/oauth-protected-resource")
        #expect(MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: "Bearer") == nil)
        #expect(MCPOAuth.defaultResourceMetadataURL(for: URL(string: "https://mcp.example.com/v1/mcp")!)?.absoluteString
                == "https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp")
        #expect(MCPOAuth.authorizationServer(fromResourceMetadata: Data(#"{"resource":"x","authorization_servers":["https://auth.example.com"]}"#.utf8))?.host == "auth.example.com")
        #expect(MCPOAuth.metadataURLs(issuer: URL(string: "https://auth.example.com")!).map(\.absoluteString)
                == ["https://auth.example.com/.well-known/oauth-authorization-server", "https://auth.example.com/.well-known/openid-configuration"])
        let meta = try #require(MCPOAuth.parseServerMetadata(Data(#"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register","code_challenge_methods_supported":["S256"],"scopes_supported":["mcp"]}"#.utf8)))
        #expect(meta.registrationEndpoint == "https://auth.example.com/register" && meta.scopes == ["mcp"])
        // Without S256 there is no safe sign-in.
        #expect(MCPOAuth.parseServerMetadata(Data(#"{"authorization_endpoint":"a","token_endpoint":"t","code_challenge_methods_supported":["plain"]}"#.utf8)) == nil)
    }

    @Test func pkceAndAuthorizeURL() throws {
        // RFC 7636 appendix B.
        let p = MCPOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s1")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(MCPOAuth.PKCE().verifier.count >= 43)
        let meta = MCPOAuth.ServerMetadata(issuer: "", authorizationEndpoint: "https://auth.example.com/authorize?x=1", tokenEndpoint: "t", registrationEndpoint: nil, scopes: ["mcp"])
        let url = try #require(MCPOAuth.authorizeURL(meta, clientID: "c1", pkce: p, resource: "https://mcp.example.com/mcp"))
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["x"] == "1" && q["code_challenge_method"] == "S256" && q["state"] == "s1" && q["redirect_uri"] == MCPOAuth.redirectURI)
        #expect(q["resource"] == "https://mcp.example.com/mcp" && q["scope"] == "mcp")
        #expect(try MCPOAuth.code(fromCallback: URL(string: "deckhand://oauth/callback?code=abc&state=s1")!, pkce: p) == "abc")
        #expect(throws: MCPOAuth.CallbackError.stateMismatch) { try MCPOAuth.code(fromCallback: URL(string: "deckhand://oauth/callback?code=abc&state=evil")!, pkce: p) }
        #expect(throws: MCPOAuth.CallbackError.self) { try MCPOAuth.code(fromCallback: URL(string: "deckhand://oauth/callback?error=access_denied&state=s1")!, pkce: p) }
    }

    @Test func tokensAndRefresh() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let t = try #require(MCPOAuth.parseTokens(Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#.utf8), endpoint: "https://auth.example.com/token", clientID: "c1", resource: "res", now: now))
        #expect(!t.needsRefresh(now: now) && t.needsRefresh(now: now.addingTimeInterval(3550)))
        let r = try #require(MCPOAuth.refreshRequest(t))
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token") && body.contains("refresh_token=r1") && body.contains("client_id=c1"))
        let t2 = try #require(MCPOAuth.parseTokens(Data(#"{"access_token":"a2","expires_in":60}"#.utf8), endpoint: t.tokenEndpoint, clientID: "c1", resource: "res", previous: t, now: now))
        #expect(t2.refreshToken == "r1" && t2.accessToken == "a2")
        let reg = try JSONValue.parse(MCPOAuth.registrationBody())
        #expect(reg["token_endpoint_auth_method"] == "none" && reg["redirect_uris"] == [.string(MCPOAuth.redirectURI)])
        let ex = try #require(MCPOAuth.tokenRequest(endpoint: "https://auth.example.com/token", code: "c d", pkce: MCPOAuth.PKCE(verifier: "v"), clientID: "c1", resource: "https://mcp.example.com/mcp"))
        #expect(String(data: ex.httpBody!, encoding: .utf8)!.contains("code=c%20d&redirect_uri=deckhand%3A%2F%2Foauth%2Fcallback"))
    }
}

/// Opt-in: DECKHAND_NET_TEST=1. Discovery against a real OAuth MCP server, up to its metadata (nothing is registered).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_NET_TEST"] != nil))
struct MCPOAuthLiveTests {
    @Test func discoversARealServer() async throws {
        let server = URL(string: "https://mcp.linear.app/mcp")!
        var r = URLRequest(url: server)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Deckhand","version":"1.0"}}}"#.utf8)
        let (_, resp) = try await URLSession.shared.data(for: r)
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 401)
        let header = http.value(forHTTPHeaderField: "WWW-Authenticate")
        var issuer: URL?
        if let meta = MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: header) ?? MCPOAuth.defaultResourceMetadataURL(for: server),
           let (data, mr) = try? await URLSession.shared.data(from: meta), (mr as? HTTPURLResponse)?.statusCode == 200 {
            issuer = MCPOAuth.authorizationServer(fromResourceMetadata: data)
        }
        if issuer == nil { issuer = URL(string: "https://mcp.linear.app") }
        var found: MCPOAuth.ServerMetadata?
        for u in MCPOAuth.metadataURLs(issuer: try #require(issuer)) {
            if let (d, mr) = try? await URLSession.shared.data(from: u), (mr as? HTTPURLResponse)?.statusCode == 200, let m = MCPOAuth.parseServerMetadata(d) { found = m; break }
        }
        let meta = try #require(found)
        #expect(meta.registrationEndpoint != nil)
        #expect(MCPOAuth.authorizeURL(meta, clientID: "probe", pkce: MCPOAuth.PKCE(), resource: server.absoluteString) != nil)
    }
}
