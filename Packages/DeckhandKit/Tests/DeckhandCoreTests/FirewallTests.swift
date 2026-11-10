import Foundation
import Network
import Testing
@testable import DeckhandCore

struct FirewallTests {
    let ufw = Firewall.parse("""
    @@ufw active
    Status: active

         To                         Action      From
         --                         ------      ----
    [ 1] 22/tcp                     ALLOW IN    Anywhere
    [ 2] 443                        ALLOW IN    Anywhere                   # Web
    [ 3] 5432/tcp                   ALLOW IN    203.0.113.4
    [ 4] 22/tcp (v6)                ALLOW IN    Anywhere (v6)
    [ 5] Nginx Full                 ALLOW IN    Anywhere
    """)

    @Test func parsesUfw() {
        #expect(ufw.kind == .ufw && ufw.active)
        #expect(ufw.rules.count == 5)
        #expect(ufw.rules[1].comment == "Web" && ufw.rules[1].ports == [443])
        #expect(ufw.rules[2].from == "203.0.113.4")
        #expect(ufw.rules[3].ipv6)
        #expect(ufw.rules[4].ports == [80, 443])
    }

    @Test func neverRemovesTheOnlySSHRule() {
        // sshd's own port counts, not the port the app dials (it may be forwarded).
        #expect(ufw.sshPorts == [22])
        #expect(Firewall.protects(ufw.rules[0], in: ufw) != nil)
        #expect(Firewall.protects(ufw.rules[3], in: ufw) != nil)
        #expect(Firewall.protects(ufw.rules[1], in: ufw) == nil)
        var two = ufw
        two.rules.append(Firewall.Rule(id: "6", target: "OpenSSH", action: "ALLOW", from: "Anywhere", ipv6: false))
        #expect(Firewall.protects(two.rules[0], in: two) == nil)
        #expect(Firewall.parse("@@sshports 2222 \n@@ufw active\n").sshPorts == [2222])
    }

    @Test func buildsGuardedChanges() {
        let web = Firewall.add(.init(port: "8080", comment: "App"), to: ufw)
        #expect(web.apply == "ufw allow 8080/tcp comment 'App'")
        #expect(web.guardSeconds != nil)
        let db = Firewall.add(.init(port: "5432", from: "10.0.0.0/8", comment: ""), to: ufw)
        #expect(db.apply == "ufw allow from '10.0.0.0/8' to any port 5432 proto tcp")
        #expect(Firewall.remove(ufw.rules[2], from: ufw).apply == "ufw --force delete 3")
        // IPv4 and IPv6 twins go together, higher number first.
        #expect(Firewall.remove(ufw.rules[0], from: ufw).apply == "ufw --force delete 4\nufw --force delete 1")
        #expect(!Firewall.NewRule(port: "70000", comment: "").isValid)
        #expect(Firewall.NewRule(port: "80,443", comment: "").isValid && Firewall.NewRule(port: "6000:6007", comment: "").isValid)
        #expect(!Firewall.NewRule(port: "80,,443", comment: "").isValid)
        #expect(!Firewall.NewRule(port: "80", from: "evil; rm", comment: "").isValid)
        let fwd = Firewall.parse("@@firewalld active public\nservices=ssh http\nports=8080/tcp\n")
        #expect(fwd.rules.map(\.id) == ["service:ssh", "service:http", "port:8080/tcp"])
        #expect(Firewall.remove(fwd.rules[2], from: fwd).apply.contains("--remove-port='8080/tcp'"))
    }

    @Test func probesPorts() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.start(queue: .global()); $0.cancel() }
        listener.start(queue: .global())
        var port = 0
        for _ in 0..<100 {
            if listener.state == .ready, let p = listener.port { port = Int(p.rawValue); break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(port > 0)
        let open = await PortProbe.openPorts(host: "127.0.0.1", ports: [port, 1], timeout: .seconds(2))
        #expect(open == [port])
        listener.cancel()
    }
}
