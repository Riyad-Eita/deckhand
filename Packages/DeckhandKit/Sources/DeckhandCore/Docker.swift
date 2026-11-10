import Foundation

public struct DockerContainer: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var ports: String
    public var composeProject: String?
    // Live usage from `docker stats` (only for running containers).
    public var cpu: String?
    public var memory: String?

    public var isRunning: Bool { state == "running" }
    public var isUnhealthy: Bool { status.contains("unhealthy") || state == "restarting" || (state == "exited" && !status.contains("(0)")) }

    /// Ports published on all interfaces — reachable from the internet even with ufw active.
    public var publicPorts: [String] {
        ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("0.0.0.0:") || $0.hasPrefix("[::]:") || $0.hasPrefix(":::") }
            .compactMap { $0.split(separator: "->").first.map(String.init) }
            .filter { !$0.hasPrefix("[::]") && !$0.hasPrefix(":::") }
    }
}

public struct ComposeProject: Sendable, Hashable, Identifiable {
    public var name: String
    public var status: String
    public var configFiles: [String]
    public var id: String { name }
    public var isRunning: Bool { status.hasPrefix("running") }
}

public enum ContainerAction: String, Sendable, CaseIterable {
    case start, stop, restart, remove
    public var title: String { self == .remove ? "Remove" : rawValue.capitalized }
    public var isDisruptive: Bool { self != .start }
}

public enum ComposeAction: String, Sendable, CaseIterable {
    case up, down, restart, pull
    public var title: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .restart: "Restart"
        case .pull: "Pull images"
        }
    }
    public var isDisruptive: Bool { self == .down || self == .restart }
}

public enum Docker {
    public static let overviewCommand = """
    if ! command -v docker >/dev/null 2>&1; then echo '@@nodocker'; exit 0; fi
    echo '@@ps'; docker ps -a --no-trunc=false --format '{{json .}}' 2>&1
    echo '@@stats'; docker stats --no-stream --format '{{json .}}' 2>/dev/null
    echo '@@compose'; docker compose ls -a --format json 2>/dev/null
    """

    public struct Overview: Sendable, Hashable {
        public var installed: Bool
        public var permissionDenied: Bool
        public var containers: [DockerContainer]
        public var projects: [ComposeProject]
    }

    public static func parseOverview(_ output: String) -> Overview {
        if output.contains("@@nodocker") { return Overview(installed: false, permissionDenied: false, containers: [], projects: []) }
        var section = ""
        var containers: [DockerContainer] = []
        var stats: [String: (String, String)] = [:]
        var projects: [ComposeProject] = []
        var denied = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@") { section = String(line.dropFirst(2)); continue }
            if line.contains("permission denied") && line.contains("docker") { denied = true; continue }
            switch section {
            case "ps":
                guard let j = try? JSONValue.parse(line), let id = j["ID"]?.stringValue else { continue }
                let labels = j["Labels"]?.stringValue ?? ""
                let project = labels.split(separator: ",").first { $0.hasPrefix("com.docker.compose.project=") }
                    .map { String($0.dropFirst("com.docker.compose.project=".count)) }
                containers.append(DockerContainer(
                    id: id, name: j["Names"]?.stringValue ?? id, image: j["Image"]?.stringValue ?? "",
                    state: j["State"]?.stringValue ?? "", status: j["Status"]?.stringValue ?? "",
                    ports: j["Ports"]?.stringValue ?? "", composeProject: project))
            case "stats":
                guard let j = try? JSONValue.parse(line), let name = j["Name"]?.stringValue else { continue }
                stats[name] = (j["CPUPerc"]?.stringValue ?? "", j["MemUsage"]?.stringValue ?? "")
            case "compose":
                guard let j = try? JSONValue.parse(line), let list = j.arrayValue else { continue }
                for p in list {
                    guard let name = p["Name"]?.stringValue else { continue }
                    let files = (p["ConfigFiles"]?.stringValue ?? "").split(separator: ",").map(String.init)
                    projects.append(ComposeProject(name: name, status: p["Status"]?.stringValue ?? "", configFiles: files))
                }
            default:
                break
            }
        }
        for i in containers.indices {
            if let s = stats[containers[i].name] { containers[i].cpu = s.0; containers[i].memory = s.1 }
        }
        containers.sort { a, b in
            func rank(_ c: DockerContainer) -> Int { c.isUnhealthy ? 0 : c.isRunning ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.name < b.name
        }
        return Overview(installed: true, permissionDenied: denied, containers: containers, projects: projects.sorted { $0.name < $1.name })
    }

    public static func actionCommand(_ action: ContainerAction, container: String) -> String {
        let c = ShellQuote.quote(container)
        switch action {
        case .remove: return "docker rm -f \(c)"
        default: return "docker \(action.rawValue) \(c)"
        }
    }

    public static func logsCommand(container: String, lines: Int = 300) -> String {
        "docker logs --tail \(lines) --timestamps \(ShellQuote.quote(container)) 2>&1"
    }

    public static func followLogsCommand(container: String, seconds: Int = 600) -> String {
        "timeout \(seconds) docker logs -f --tail 0 --timestamps \(ShellQuote.quote(container)) 2>&1 || true"
    }

    public static func composeCommand(_ action: ComposeAction, project: ComposeProject) -> String {
        let files = project.configFiles.map { "-f \(ShellQuote.quote($0))" }.joined(separator: " ")
        let base = "docker compose -p \(ShellQuote.quote(project.name)) \(files)"
        switch action {
        case .up: return "\(base) up -d 2>&1"
        case .down: return "\(base) down 2>&1"
        case .restart: return "\(base) restart 2>&1"
        case .pull: return "\(base) pull 2>&1"
        }
    }
}
