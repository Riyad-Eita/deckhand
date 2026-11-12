import Foundation

/// One-tap app installs: a catalog of Docker Compose templates. Each app lives in `~/apps/<slug>` (compose file,
/// `.env` with mode 600, a marker), runs as compose project `dh-<slug>`, and listens on 127.0.0.1 only — reachable
/// through the app's SSH tunnel, or on a domain with HTTPS via Caddy. Passwords and keys are generated on the
/// server, so they never appear in a command line.
public enum AppTemplates {
    public enum Category: String, Sendable, CaseIterable {
        case databases = "Databases", automation = "Automation", monitoring = "Monitoring", productivity = "Files and teams"
        case development = "Development", security = "Security", analytics = "Analytics"
    }

    public struct Secret: Sendable, Hashable {
        /// Variable name in `.env`.
        public var key: String
        /// Shown to the user afterwards (nil = internal only, e.g. an encryption key).
        public var label: String?
        /// `hex` (letters and digits) or `base64` (64 characters, for secret_key_base style values).
        public var style: Style = .hex
        public enum Style: Sendable { case hex, base64 }
    }

    public struct Template: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String
        public var symbol: String
        public var category: Category
        /// Port inside the container that the app serves on (HTTP apps) or listens on (databases).
        public var containerPort: Int
        /// First host port tried on 127.0.0.1 (the next free one is used if taken).
        public var defaultPort: Int
        /// Web app: has a URL to open. Databases show a connection string instead.
        public var isWeb = true
        /// Needs a domain with HTTPS to work properly (e.g. passkeys, secure cookies, webhooks).
        public var needsDomain = false
        public var secrets: [Secret] = []
        /// Fixed credentials shown afterwards (label, value) — values may use `${VAR}` from `.env`.
        public var credentials: [(label: String, value: String)] = []
        /// What to do after opening it the first time.
        public var firstSteps: String = ""
        /// Compose file; `${PORT}`, `${DOMAIN}`, `${URL}` and the secrets come from `.env`.
        public var compose: String

        public static func == (a: Template, b: Template) -> Bool { a.id == b.id }
        public func hash(into h: inout Hasher) { h.combine(id) }
    }

    // MARK: Catalog

    public static let catalog: [Template] = [
        Template(
            id: "postgres", name: "PostgreSQL", summary: "The database most apps want.", symbol: "cylinder.split.1x2",
            category: .databases, containerPort: 5432, defaultPort: 5432, isWeb: false,
            secrets: [Secret(key: "POSTGRES_PASSWORD", label: "Password")],
            credentials: [("User", "app"), ("Database", "app"), ("Connection", "postgres://app:${POSTGRES_PASSWORD}@127.0.0.1:${PORT}/app")],
            compose: """
            services:
              db:
                image: postgres:17
                restart: unless-stopped
                environment:
                  POSTGRES_USER: app
                  POSTGRES_DB: app
                  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
                ports:
                  - "127.0.0.1:${PORT}:5432"
                volumes:
                  - data:/var/lib/postgresql/data
            volumes:
              data:
            """),
        Template(
            id: "redis", name: "Redis", summary: "Fast key-value store for caches and queues.", symbol: "bolt.horizontal",
            category: .databases, containerPort: 6379, defaultPort: 6379, isWeb: false,
            secrets: [Secret(key: "REDIS_PASSWORD", label: "Password")],
            credentials: [("Connection", "redis://:${REDIS_PASSWORD}@127.0.0.1:${PORT}")],
            compose: """
            services:
              redis:
                image: redis:7
                restart: unless-stopped
                command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}", "--appendonly", "yes"]
                ports:
                  - "127.0.0.1:${PORT}:6379"
                volumes:
                  - data:/data
            volumes:
              data:
            """),
        Template(
            id: "n8n", name: "n8n", summary: "Workflow automation with hundreds of integrations.", symbol: "point.3.connected.trianglepath.dotted",
            category: .automation, containerPort: 5678, defaultPort: 5678,
            secrets: [Secret(key: "N8N_ENCRYPTION_KEY")],
            firstSteps: "Create the owner account on the first visit.",
            compose: """
            services:
              n8n:
                image: docker.n8n.io/n8nio/n8n:latest
                restart: unless-stopped
                environment:
                  N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
                  N8N_HOST: ${DOMAIN}
                  N8N_PROTOCOL: ${SCHEME}
                  WEBHOOK_URL: ${URL}/
                  N8N_SECURE_COOKIE: ${SECURE}
                  N8N_RUNNERS_ENABLED: "true"
                ports:
                  - "127.0.0.1:${PORT}:5678"
                volumes:
                  - data:/home/node/.n8n
            volumes:
              data:
            """),
        Template(
            id: "uptime-kuma", name: "Uptime Kuma", summary: "Status pages and uptime monitoring.", symbol: "waveform.path.ecg",
            category: .monitoring, containerPort: 3001, defaultPort: 3001,
            firstSteps: "Create the admin account on the first visit.",
            compose: """
            services:
              kuma:
                image: louislam/uptime-kuma:1
                restart: unless-stopped
                ports:
                  - "127.0.0.1:${PORT}:3001"
                volumes:
                  - data:/app/data
            volumes:
              data:
            """),
        Template(
            id: "nextcloud", name: "Nextcloud", summary: "Your own cloud for files, calendars and contacts.", symbol: "cloud",
            category: .productivity, containerPort: 80, defaultPort: 8080,
            secrets: [Secret(key: "ADMIN_PASSWORD", label: "Admin password"), Secret(key: "DB_PASSWORD")],
            credentials: [("Admin user", "admin")],
            compose: """
            services:
              db:
                image: postgres:17
                restart: unless-stopped
                environment:
                  POSTGRES_USER: nextcloud
                  POSTGRES_DB: nextcloud
                  POSTGRES_PASSWORD: ${DB_PASSWORD}
                volumes:
                  - db:/var/lib/postgresql/data
              app:
                image: nextcloud:30-apache
                restart: unless-stopped
                depends_on: [db]
                environment:
                  POSTGRES_HOST: db
                  POSTGRES_USER: nextcloud
                  POSTGRES_DB: nextcloud
                  POSTGRES_PASSWORD: ${DB_PASSWORD}
                  NEXTCLOUD_ADMIN_USER: admin
                  NEXTCLOUD_ADMIN_PASSWORD: ${ADMIN_PASSWORD}
                  NEXTCLOUD_TRUSTED_DOMAINS: ${DOMAIN} localhost 127.0.0.1
                  OVERWRITEPROTOCOL: ${SCHEME}
                  TRUSTED_PROXIES: 127.0.0.1 172.16.0.0/12
                ports:
                  - "127.0.0.1:${PORT}:80"
                volumes:
                  - html:/var/www/html
            volumes:
              db:
              html:
            """),
        Template(
            id: "gitea", name: "Gitea", summary: "Lightweight Git hosting with issues and pull requests.", symbol: "arrow.triangle.branch",
            category: .development, containerPort: 3000, defaultPort: 3000,
            firstSteps: "The first visit shows the installer; keep SQLite and create the admin account there.",
            compose: """
            services:
              gitea:
                image: gitea/gitea:1
                restart: unless-stopped
                environment:
                  USER_UID: "1000"
                  USER_GID: "1000"
                  GITEA__server__ROOT_URL: ${URL}/
                  GITEA__server__DOMAIN: ${DOMAIN}
                ports:
                  - "127.0.0.1:${PORT}:3000"
                volumes:
                  - data:/data
            volumes:
              data:
            """),
        Template(
            id: "vaultwarden", name: "Vaultwarden", summary: "Password manager compatible with Bitwarden apps.", symbol: "lock.shield",
            category: .security, containerPort: 80, defaultPort: 8081, needsDomain: true,
            secrets: [Secret(key: "ADMIN_TOKEN", label: "Admin token")],
            credentials: [("Admin page", "${URL}/admin")],
            firstSteps: "Create your account in the web vault, then sign in with the Bitwarden apps using this server's address.",
            compose: """
            services:
              vaultwarden:
                image: vaultwarden/server:latest
                restart: unless-stopped
                environment:
                  DOMAIN: ${URL}
                  ADMIN_TOKEN: ${ADMIN_TOKEN}
                  SIGNUPS_ALLOWED: "true"
                ports:
                  - "127.0.0.1:${PORT}:80"
                volumes:
                  - data:/data
            volumes:
              data:
            """),
        Template(
            id: "plausible", name: "Plausible", summary: "Privacy-friendly web analytics.", symbol: "chart.xyaxis.line",
            category: .analytics, containerPort: 8000, defaultPort: 8000, needsDomain: true,
            secrets: [Secret(key: "SECRET_KEY_BASE", style: .base64), Secret(key: "DB_PASSWORD")],
            firstSteps: "Register the first account on the first visit, then add your site and its snippet.",
            compose: """
            services:
              db:
                image: postgres:16-alpine
                restart: unless-stopped
                environment:
                  POSTGRES_PASSWORD: ${DB_PASSWORD}
                volumes:
                  - db:/var/lib/postgresql/data
              events:
                image: clickhouse/clickhouse-server:24.3.3.102-alpine
                restart: unless-stopped
                environment:
                  CLICKHOUSE_SKIP_USER_SETUP: "1"
                ulimits:
                  nofile:
                    soft: 262144
                    hard: 262144
                volumes:
                  - events:/var/lib/clickhouse
              plausible:
                image: ghcr.io/plausible/community-edition:v2.1.4
                restart: unless-stopped
                command: sh -c "/entrypoint.sh db createdb && /entrypoint.sh db migrate && /entrypoint.sh run"
                depends_on: [db, events]
                environment:
                  BASE_URL: ${URL}
                  SECRET_KEY_BASE: ${SECRET_KEY_BASE}
                  DATABASE_URL: postgres://postgres:${DB_PASSWORD}@db:5432/plausible_db
                  CLICKHOUSE_DATABASE_URL: http://events:8123/plausible_events_db
                ports:
                  - "127.0.0.1:${PORT}:8000"
                volumes:
                  - data:/var/lib/plausible
            volumes:
              db:
              events:
              data:
            """),
    ]

    public static func template(_ id: String) -> Template? { catalog.first { $0.id == id } }

    // MARK: Names

    /// Folder and project name: lower-case letters, digits and dashes.
    public static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber ? String($0) : "-" }.joined()
        return s.split(separator: "-").joined(separator: "-").prefix(40).description
    }

    static let root = "$HOME/apps"

    // MARK: Install

    public struct Plan: Sendable, Hashable {
        public var template: Template
        public var name: String
        /// Empty: only reachable through the app's tunnel.
        public var domain: String
        public init(template: Template, name: String? = nil, domain: String = "") {
            self.template = template
            self.name = slug(name ?? template.id)
            self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        public var project: String { "dh-\(name)" }
    }

    /// Non-root (the user must be able to use Docker). Prints `@@port <n>`, `@@secret <KEY> <value>` for the shown
    /// secrets, `@@ok` once the app answers (or its containers run), or `@@failed <reason>` with reasons
    /// `nodocker`, `nocompose`, `noaccess`, `exists`, or the last lines of Docker's output.
    public static func installCommand(_ p: Plan, waitSeconds: Int = 180) -> String {
        let t = p.template
        let dir = "\(root)/\(p.name)"
        let gen = t.secrets.map { s in
            switch s.style {
            case .hex: "printf '%s=%s\\n' \(s.key) \"$(od -An -N24 -tx1 /dev/urandom | tr -d ' \\n')\""
            case .base64: "printf '%s=%s\\n' \(s.key) \"$(head -c 48 /dev/urandom | base64 | tr -d '\\n/+=' | head -c 64)\""
            }
        }.joined(separator: "\n  ")
        let shown = t.secrets.filter { $0.label != nil }.map(\.key)
        let domain = p.domain.isEmpty ? "localhost" : p.domain
        let check = t.isWeb
            ? "curl -s -o /dev/null -m 5 \"http://127.0.0.1:$port/\""
            : "[ \"$(docker compose -p \(p.project) ps --status running -q | wc -l)\" -ge 1 ]"
        return """
        command -v docker >/dev/null 2>&1 || { echo '@@failed nodocker'; exit 0; }
        docker compose version >/dev/null 2>&1 || { echo '@@failed nocompose'; exit 0; }
        docker info >/dev/null 2>&1 || { echo '@@failed noaccess'; exit 0; }
        D="\(dir)"
        [ -e "$D/.deckhand-app" ] && { echo '@@failed exists'; exit 0; }
        mkdir -p "$D" && cd "$D" || { echo '@@failed could not create the folder'; exit 0; }
        used() { (ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null) | awk '{print $4}' | grep -qE "[:.]$1$"; }
        port=\(t.defaultPort); while used $port; do port=$((port + 1)); done
        umask 077
        # Installed here before and removed with its data kept: reuse the secrets the data was created with.
        kept=""; [ -f .env ] && kept=$(grep -vE '^(PORT|DOMAIN|URL|SCHEME|SECURE)=' .env)
        {
          printf 'PORT=%s\\nDOMAIN=%s\\nURL=%s\\nSCHEME=%s\\nSECURE=%s\\n' "$port" \(ShellQuote.quote(domain)) \
            \(p.domain.isEmpty ? "\"http://localhost:$port\"" : ShellQuote.quote("https://" + p.domain)) \(p.domain.isEmpty ? "http false" : "https true")
          if [ -n "$kept" ]; then printf '%s\\n' "$kept"; else
          \(gen.isEmpty ? ":" : gen)
          fi
        } > .env.new && mv .env.new .env
        printf '%s\\n' \(ShellQuote.quote(t.compose)) > docker-compose.yml
        printf 'template=%s\\nname=%s\\ndomain=%s\\n' \(ShellQuote.quote(t.id)) \(ShellQuote.quote(p.name)) \(ShellQuote.quote(p.domain)) > .deckhand-app
        echo "@@port $port"
        \(shown.map { "echo \"@@secret \($0) $(grep '^\($0)=' .env | cut -d= -f2-)\"" }.joined(separator: "\n"))
        out=$(docker compose -p \(p.project) up -d --quiet-pull 2>&1) || { echo "@@failed $(printf '%s' "$out" | tail -n 3 | tr '\\n' ' ')"; exit 0; }
        i=0; until \(check); do i=$((i + 3)); [ $i -ge \(waitSeconds) ] && { echo '@@slow'; break; }; sleep 3; done
        echo '@@ok'
        """
    }

    public struct InstallResult: Sendable, Hashable {
        public var ok = false
        public var slow = false
        public var port: Int?
        public var secrets: [String: String] = [:]
        public var failure: String?
    }

    public static func parseInstall(_ out: String) -> InstallResult {
        var r = InstallResult()
        for line in out.split(separator: "\n").map(String.init) {
            if line == "@@ok" { r.ok = true }
            else if line == "@@slow" { r.slow = true }
            else if line.hasPrefix("@@port ") { r.port = Int(line.dropFirst(7)) }
            else if line.hasPrefix("@@secret ") {
                let p = line.dropFirst(9).split(separator: " ", maxSplits: 1).map(String.init)
                if p.count == 2 { r.secrets[p[0]] = p[1] }
            } else if line.hasPrefix("@@failed ") {
                let why = String(line.dropFirst(9))
                r.failure = switch why {
                case "nodocker": "Docker isn't installed on this server."
                case "nocompose": "Docker Compose isn't available (the `docker compose` plugin)."
                case "noaccess": "Your user can't use Docker. Add it to the docker group (then log in again)."
                case "exists": "An app with this name is already installed."
                default: why
                }
            }
        }
        return r
    }

    // MARK: Installed apps

    public struct Installed: Sendable, Hashable, Identifiable {
        public var name: String
        public var templateID: String
        public var domain: String
        public var port: Int?
        /// Containers running / total.
        public var running: Int
        public var total: Int
        public var id: String { name }
        public var template: Template? { AppTemplates.template(templateID) }
        public var url: String? {
            guard template?.isWeb != false else { return nil }
            return domain.isEmpty ? port.map { "http://localhost:\($0)" } : "https://\(domain)"
        }
    }

    /// `@@app <name>\t<template>\t<domain>\t<port>\t<running>\t<total>` per installed app.
    public static let listCommand = """
    for f in \(root)/*/.deckhand-app; do [ -f "$f" ] || continue
      d=$(dirname "$f"); n=$(sed -n 's/^name=//p' "$f"); t=$(sed -n 's/^template=//p' "$f"); dom=$(sed -n 's/^domain=//p' "$f")
      port=$(sed -n 's/^PORT=//p' "$d/.env" 2>/dev/null)
      run=$(docker compose -p "dh-$n" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')
      all=$(docker compose -p "dh-$n" ps -a -q 2>/dev/null | wc -l | tr -d ' ')
      printf '@@app %s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$n" "$t" "$dom" "$port" "$run" "$all"
    done
    true
    """

    public static func parseList(_ out: String) -> [Installed] {
        out.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("@@app ") else { return nil }
            let f = line.dropFirst(6).components(separatedBy: "\t")
            guard f.count == 6 else { return nil }
            return Installed(name: f[0], templateID: f[1], domain: f[2], port: Int(f[3]), running: Int(f[4]) ?? 0, total: Int(f[5]) ?? 0)
        }
    }

    /// The shown credentials of an installed app, with `${VAR}` filled from its `.env`. Prints `@@env KEY value`.
    public static func secretsCommand(name: String) -> String {
        "f=\(root)/\(slug(name))/.env; [ -f \"$f\" ] && sed -n 's/^\\([A-Z_]*\\)=\\(.*\\)$/@@env \\1 \\2/p' \"$f\"; true"
    }

    public static func parseEnv(_ out: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in out.split(separator: "\n") where line.hasPrefix("@@env ") {
            let p = line.dropFirst(6).split(separator: " ", maxSplits: 1).map(String.init)
            env[p[0]] = p.count > 1 ? p[1] : ""
        }
        return env
    }

    /// Credentials to show for an app (label, value), with variables filled in.
    public static func credentials(_ t: Template, env: [String: String]) -> [(label: String, value: String)] {
        func fill(_ s: String) -> String {
            env.reduce(s) { $0.replacingOccurrences(of: "${\($1.key)}", with: $1.value) }
        }
        return t.credentials.map { ($0.label, fill($0.value)) }
            + t.secrets.compactMap { s in s.label.flatMap { l in env[s.key].map { (l, $0) } } }
    }

    public enum Action: String, Sendable { case start, stop, restart, update, remove, removeWithData }

    /// Start/stop/restart; update pulls new images; remove keeps the data volumes (and the folder) unless asked.
    public static func actionCommand(_ action: Action, name: String) -> String {
        let n = slug(name)
        guard !n.isEmpty else { return "echo '@@failed missing'" }
        let cd = "cd \(root)/\(n) 2>/dev/null || { echo '@@failed missing'; exit 0; }"
        let dc = "docker compose -p dh-\(n)"
        let body = switch action {
        case .start: "\(dc) up -d"
        case .stop: "\(dc) stop"
        case .restart: "\(dc) restart"
        case .update: "\(dc) pull --quiet && \(dc) up -d"
        case .remove: "\(dc) down && rm -f .deckhand-app"
        case .removeWithData: "\(dc) down -v && cd .. && rm -rf -- \(ShellQuote.quote(n))"
        }
        return "\(cd)\nout=$( { \(body); } 2>&1) && echo '@@ok' || echo \"@@failed $(printf '%s' \"$out\" | tail -n 3 | tr '\\n' ' ')\""
    }
}
