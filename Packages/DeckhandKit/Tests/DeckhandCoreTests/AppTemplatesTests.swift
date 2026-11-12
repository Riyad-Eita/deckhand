import Foundation
import Testing
@testable import DeckhandCore

struct AppTemplatesTests {
    /// A fake HOME with a `docker` that records its calls and reports one running container.
    func fakeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appending(path: "tpl-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        let docker = """
        #!/bin/sh
        echo "$*" >> "$HOME/docker.log"
        case "$*" in
          "compose version"|info) exit 0 ;;
          *"ps --status running -q"*|*"ps -a -q"*) echo abc123 ;;
        esac
        exit 0
        """
        try docker.write(toFile: home + "/bin/docker", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/bin/docker")
        return home
    }

    func sh(_ home: String, _ c: String) async throws -> String {
        try await LocalShell().run("HOME='\(home)' PATH='\(home)/bin':$PATH /bin/sh -c \(ShellQuote.quote(c))", timeout: .seconds(30)).stdout
    }

    @Test func installWritesComposeAndPrivateEnv() async throws {
        let home = try fakeHome()
        let plan = AppTemplates.Plan(template: AppTemplates.template("postgres")!, name: "Shop DB")
        #expect(plan.name == "shop-db" && plan.project == "dh-shop-db")
        let cmd = AppTemplates.installCommand(plan, waitSeconds: 3)
        let r = AppTemplates.parseInstall(try await sh(home, cmd))
        #expect(r.ok && r.failure == nil && r.port != nil)
        let pw = try #require(r.secrets["POSTGRES_PASSWORD"])
        #expect(pw.count == 48 && !cmd.contains(pw))                   // made on the server, never in the command
        let dir = home + "/apps/shop-db"
        let env = try String(contentsOfFile: dir + "/.env", encoding: .utf8)
        #expect(env.contains("POSTGRES_PASSWORD=\(pw)") && env.contains("PORT=\(r.port!)") && env.contains("URL=http://localhost:"))
        let mode = try FileManager.default.attributesOfItem(atPath: dir + "/.env")[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOfFile: dir + "/docker-compose.yml", encoding: .utf8).contains("127.0.0.1:${PORT}:5432"))
        #expect(try String(contentsOfFile: home + "/docker.log", encoding: .utf8).contains("compose -p dh-shop-db up -d"))

        // Listed, with credentials filled from .env.
        let list = AppTemplates.parseList(try await sh(home, AppTemplates.listCommand))
        #expect(list.map(\.name) == ["shop-db"] && list.first?.running == 1 && list.first?.url == nil)
        let creds = AppTemplates.credentials(plan.template, env: AppTemplates.parseEnv(try await sh(home, AppTemplates.secretsCommand(name: "shop-db"))))
        #expect(creds.contains { $0.label == "Connection" && $0.value == "postgres://app:\(pw)@127.0.0.1:\(r.port!)/app" })
        #expect(creds.contains { $0.label == "Password" && $0.value == pw })

        // Same name again: refused. Removed (data kept) and installed again: the old secrets are reused.
        #expect(AppTemplates.parseInstall(try await sh(home, cmd)).failure == "An app with this name is already installed.")
        #expect(try await sh(home, AppTemplates.actionCommand(.remove, name: "shop-db")).contains("@@ok"))
        #expect(AppTemplates.parseList(try await sh(home, AppTemplates.listCommand)).isEmpty)
        #expect(AppTemplates.parseInstall(try await sh(home, cmd)).secrets["POSTGRES_PASSWORD"] == pw)

        // Removed with its data: folder gone.
        #expect(try await sh(home, AppTemplates.actionCommand(.removeWithData, name: "shop-db")).contains("@@ok"))
        #expect(!FileManager.default.fileExists(atPath: dir))
        _ = try await LocalShell().run("rm -rf '\(home)'", timeout: .seconds(10))
    }

    @Test func domainsGoIntoTheEnvironment() async throws {
        let home = try fakeHome()
        let plan = AppTemplates.Plan(template: AppTemplates.template("vaultwarden")!, domain: " Vault.Example.com ")
        _ = try await sh(home, AppTemplates.installCommand(plan, waitSeconds: 0))
        let env = try String(contentsOfFile: home + "/apps/vaultwarden/.env", encoding: .utf8)
        #expect(env.contains("DOMAIN=vault.example.com\nURL=https://vault.example.com\nSCHEME=https\nSECURE=true"))
        #expect(env.contains("ADMIN_TOKEN="))
        let list = AppTemplates.parseList(try await sh(home, AppTemplates.listCommand))
        #expect(list.first?.url == "https://vault.example.com")
        _ = try await LocalShell().run("rm -rf '\(home)'", timeout: .seconds(10))
    }

    @Test func dockerProblemsAreExplained() async throws {
        let home = try fakeHome()
        try "#!/bin/sh\n[ \"$1\" = info ] && exit 1\nexit 0\n".write(toFile: home + "/bin/docker", atomically: true, encoding: .utf8)
        let r = AppTemplates.parseInstall(try await sh(home, AppTemplates.installCommand(.init(template: AppTemplates.catalog[0]))))
        #expect(r.failure?.contains("docker group") == true)
        _ = try await LocalShell().run("rm -rf '\(home)'", timeout: .seconds(10))
    }

    @Test func catalogIsConsistent() {
        #expect(Set(AppTemplates.catalog.map(\.id)).count == AppTemplates.catalog.count)
        for t in AppTemplates.catalog {
            // Every published port is bound to localhost and uses ${PORT}; every secret is used by the compose file.
            #expect(t.compose.contains("\"127.0.0.1:${PORT}:\(t.containerPort)\""), "\(t.id)")
            #expect(!t.compose.contains("- \"\(t.containerPort):"), "\(t.id)")
            for s in t.secrets { #expect(t.compose.contains("${\(s.key)}"), "\(t.id) \(s.key)") }
        }
        #expect(AppTemplates.slug("My Cloud!") == "my-cloud")
        #expect(AppTemplates.actionCommand(.removeWithData, name: "!!!") == "echo '@@failed missing'")
    }
}
