import Foundation
import Testing
@testable import DeckhandCore

struct ServerXrayTests {
    static let sample = """
    @@os Ubuntu 24.04.1 LTS
    @@kernel Linux 6.8.0-45-generic
    @@cpus 2
    @@mem 3916
    @@up 864000
    @@disk 41152736 37000000
    @@svc nginx.service
    @@svc docker.service
    @@port 0.0.0.0:80 nginx
    @@port 0.0.0.0:443 nginx
    @@port 127.0.0.1:3000 docker-proxy
    @@port 0.0.0.0:5432 postgres
    @@port [::]:22 sshd
    @@ng /etc/nginx/sites-enabled/shop:1:server {
    @@ng /etc/nginx/sites-enabled/shop:2:    listen 80;
    @@ng /etc/nginx/sites-enabled/shop:3:    server_name shop.example.com;
    @@ng /etc/nginx/sites-enabled/shop:4:    return 301 https://$host$request_uri;
    @@ng /etc/nginx/sites-enabled/shop:6:server {
    @@ng /etc/nginx/sites-enabled/shop:7:    listen 443 ssl;
    @@ng /etc/nginx/sites-enabled/shop:8:    server_name shop.example.com www.shop.example.com;
    @@ng /etc/nginx/sites-enabled/shop:9:    proxy_pass http://127.0.0.1:3000;
    @@ng /etc/nginx/sites-enabled/blog:1:server {
    @@ng /etc/nginx/sites-enabled/blog:2:    listen 80;
    @@ng /etc/nginx/sites-enabled/blog:3:    server_name blog.example.com;
    @@ng /etc/nginx/sites-enabled/blog:4:    location / { proxy_pass http://127.0.0.1:4000; }
    @@ct shop|ghcr.io/me/shop:latest|127.0.0.1:3000->3000/tcp|Up 3 days
    @@ct old-worker|me/worker:1|  |Exited (1) 2 weeks ago
    @@cron 0 3 * * * /usr/local/bin/cleanup.sh
    @@cron * * * * * /home/me/.deckhand/uptime/run.sh >/dev/null 2>&1 # deckhand-uptime
    @@cron 17 *	* * *	root	cd / && run-parts --report /etc/cron.hourly
    @@upd 12 4
    @@user root
    @@user deploy
    @@keys 3
    """

    @Test func parsesTheMap() {
        let r = ServerXray.parse(Self.sample, certificates: "@@cert shop.example.com \(Int(Date().timeIntervalSince1970) + 9 * 86_400)")
        #expect(r.os == "Ubuntu 24.04.1 LTS" && r.cpus == 2 && r.memoryMB == 3916)
        #expect(r.sites.count == 2) // the redirect-only block folds into the HTTPS one
        let shop = r.sites[0]
        #expect(shop.names == ["shop.example.com", "www.shop.example.com"] && shop.tls && shop.upstreamPort == 3000)
        #expect(r.app(for: shop) == "shop (container, port 3000)")
        #expect(r.app(for: r.sites[1]) == "port 4000 (nothing listening!)")
        #expect(r.databases.map(\.kind) == ["PostgreSQL"])
        #expect(r.cron == ["0 3 * * * /usr/local/bin/cleanup.sh"])
        #expect(r.domains == ["blog.example.com", "shop.example.com", "www.shop.example.com"])
        #expect(!r.hasBackups)
        let titles = r.risks.map(\.title)
        #expect(r.risks.first?.level == .high)
        #expect(titles.contains("No backups found"))
        #expect(titles.contains("PostgreSQL is reachable from outside"))
        #expect(titles.contains { $0.hasPrefix("Certificate for shop.example.com expires in") })
        #expect(titles.contains("blog.example.com has no HTTPS"))
        #expect(titles.contains("blog.example.com points to nothing"))
        #expect(titles.contains("12 updates waiting, 4 for security"))
        #expect(titles.contains("Disk is 89 % full"))
        #expect(titles.contains("1 stopped containers"))
    }

    @Test func backupsAndHandover() {
        var r = ServerXray.parse(Self.sample + "\n@@cron 30 2 * * * restic backup /srv")
        #expect(r.hasBackups)
        r.date = Date(timeIntervalSince1970: 1_794_400_000)
        let md = ServerXray.markdown(r, serverName: "my-server")
        #expect(md.contains("- shop.example.com, www.shop.example.com → nginx (HTTPS) → shop (container, port 3000)"))
        #expect(md.contains("- PostgreSQL on 0.0.0.0:5432 (public!)"))
        #expect(md.contains("## Risks"))
    }

    @Test func changesBetweenScans() {
        let a = ServerXray.parse(Self.sample)
        let b = ServerXray.parse(Self.sample.replacingOccurrences(of: "@@svc docker.service", with: "@@svc redis.service"))
        #expect(ServerXray.changes(from: a, to: b) == ["+ service: redis.service", "− service: docker.service"])
    }

    @Test func probeRunsLocally() async throws {
        let r = try await LocalShell().run(ServerXray.probeCommand, timeout: .seconds(60))
        let rep = ServerXray.parse(r.stdout)
        #expect(!rep.kernel.isEmpty)
    }

    @Test func notesBlockReplacesTheOldOne() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "xr-\(UUID().uuidString.prefix(6))").path
        let shell = LocalShell()
        _ = try await shell.run("mkdir -p '\(home)/.deckhand' && printf '# Server notes\\n- keep me\\n' > '\(home)/.deckhand/memory.md'", timeout: .seconds(5))
        for text in ["first map", "second map"] {
            _ = try await shell.run("HOME='\(home)' sh -c \(ShellQuote.quote(ServerXray.saveToNotesCommand("# x\n\(text)")))", timeout: .seconds(5))
        }
        let notes = try String(contentsOfFile: home + "/.deckhand/memory.md", encoding: .utf8)
        #expect(notes.contains("- keep me") && notes.contains("second map") && !notes.contains("first map"))
        _ = try await shell.run("rm -rf '\(home)'", timeout: .seconds(5))
    }
}
