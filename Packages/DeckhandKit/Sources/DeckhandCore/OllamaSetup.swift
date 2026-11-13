import Foundation

/// A model of your own on your own server: checks the hardware, installs Ollama (listening on the server's
/// localhost only), pulls a model that fits, measures its speed and memory, and hands the app an address for it
/// that goes through the SSH connection (`ServerModelURL`).
public enum OllamaSetup {
    public static let port = 11434

    // MARK: - Hardware and status

    /// Not root. `@@arch`, `@@cpus`, `@@mem`/`@@memfree` (MB), `@@disk` (MB free), `@@gpu name, MiB`, `@@systemd`,
    /// `@@installed <version>`, `@@running`, `@@tags <json>`, `@@ps <json>`.
    public static let statusCommand = """
    echo "@@arch $(uname -m)"
    echo "@@cpus $(nproc 2>/dev/null || echo 1)"
    awk '/^MemTotal:/{print "@@mem " int($2/1024)} /^MemAvailable:/{print "@@memfree " int($2/1024)}' /proc/meminfo 2>/dev/null
    df -Pm / 2>/dev/null | awk 'NR==2{print "@@disk " $4}'
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | sed 's/^/@@gpu /'
    [ -d /run/systemd/system ] && systemctl list-units --no-pager >/dev/null 2>&1 && echo '@@systemd'
    command -v ollama >/dev/null 2>&1 && echo "@@installed $(ollama --version 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1)"
    if command -v curl >/dev/null 2>&1 && curl -fsS -m 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
      echo '@@running'
      printf '@@tags '; curl -fsS -m 5 http://127.0.0.1:11434/api/tags | tr -d '\\n'; echo
      printf '@@ps '; curl -fsS -m 5 http://127.0.0.1:11434/api/ps | tr -d '\\n'; echo
    fi
    true
    """

    public struct Status: Sendable, Hashable {
        public var arch = ""
        public var cpus = 1
        public var memoryMB = 0
        public var availableMB = 0
        public var diskFreeMB = 0
        public var gpu: String?
        public var gpuMemoryMB = 0
        public var systemd = false
        public var version: String?
        public var running = false
        public var models: [Model] = []
        public var loaded: [Loaded] = []
        public var installed: Bool { version != nil }
    }

    public struct Model: Sendable, Hashable, Identifiable {
        public var name: String
        public var sizeBytes: Int64
        public var parameters: String
        public var id: String { name }
    }

    /// A model in memory: how much of it sits on the GPU.
    public struct Loaded: Sendable, Hashable {
        public var name: String
        public var sizeBytes: Int64
        public var vramBytes: Int64
        public var onGPU: Bool { vramBytes > 0 }
    }

    public static func parse(_ out: String) -> Status {
        var s = Status()
        for line in out.split(separator: "\n").map(String.init) {
            func value(_ p: String) -> String? { line.hasPrefix(p) ? String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) : nil }
            if let v = value("@@arch ") { s.arch = v }
            else if let v = value("@@cpus ") { s.cpus = Int(v) ?? 1 }
            else if let v = value("@@memfree ") { s.availableMB = Int(v) ?? 0 }
            else if let v = value("@@mem ") { s.memoryMB = Int(v) ?? 0 }
            else if let v = value("@@disk ") { s.diskFreeMB = Int(v) ?? 0 }
            else if let v = value("@@gpu ") {
                let p = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                s.gpu = p.first; s.gpuMemoryMB = p.count > 1 ? Int(p[1]) ?? 0 : 0
            }
            else if line == "@@systemd" { s.systemd = true }
            else if let v = value("@@installed") { s.version = v.isEmpty ? "?" : v }
            else if line == "@@running" { s.running = true }
            else if let v = value("@@tags "), let json = try? JSONValue.parse(v) {
                s.models = (json["models"]?.arrayValue ?? []).compactMap { m in
                    guard let name = m["name"]?.stringValue ?? m["model"]?.stringValue else { return nil }
                    return Model(name: name, sizeBytes: Int64(m["size"]?.doubleValue ?? 0),
                                 parameters: m["details"]?["parameter_size"]?.stringValue ?? "")
                }
            }
            else if let v = value("@@ps "), let json = try? JSONValue.parse(v) {
                s.loaded = (json["models"]?.arrayValue ?? []).compactMap { m in
                    guard let name = m["name"]?.stringValue ?? m["model"]?.stringValue else { return nil }
                    return Loaded(name: name, sizeBytes: Int64(m["size"]?.doubleValue ?? 0), vramBytes: Int64(m["size_vram"]?.doubleValue ?? 0))
                }
            }
        }
        return s
    }

    // MARK: - Which model

    public struct Choice: Sendable, Hashable, Identifiable {
        public var name: String
        public var title: String
        /// Download size.
        public var sizeGB: Double
        public var note: String
        public var id: String { name }
        /// Memory it needs to run: the weights plus room for the context.
        public var neededMB: Int { Int(sizeGB * 1024 * 1.1) + 512 }
    }

    /// Qwen3 models: tool calling (so they can drive the agent), thinking, and a size for every machine.
    public static let catalog: [Choice] = [
        Choice(name: "qwen3:0.6b", title: "Qwen3 0.6B", sizeGB: 0.5, note: "Tiny and fast; fine for short answers and commit messages."),
        Choice(name: "qwen3:1.7b", title: "Qwen3 1.7B", sizeGB: 1.4, note: "Small; good for summaries and simple questions."),
        Choice(name: "qwen3:4b", title: "Qwen3 4B", sizeGB: 2.5, note: "A good balance on a server without a graphics card."),
        Choice(name: "qwen3:8b", title: "Qwen3 8B", sizeGB: 5.2, note: "Solid all-rounder; can use tools for simple agent tasks."),
        Choice(name: "qwen3:14b", title: "Qwen3 14B", sizeGB: 9.3, note: "Better reasoning; wants a graphics card or lots of memory."),
        Choice(name: "qwen3:32b", title: "Qwen3 32B", sizeGB: 20, note: "Close to hosted models for many tasks; needs a big GPU."),
    ]

    /// The memory a model may use: most of the GPU's, or a share of the RAM that's free (other services keep running).
    public static func budgetMB(_ s: Status) -> Int {
        if s.gpu != nil, s.gpuMemoryMB > 0 { return Int(Double(s.gpuMemoryMB) * 0.95) }
        let free = s.availableMB > 0 ? s.availableMB : s.memoryMB / 2
        return min(Int(Double(free) * 0.85), Int(Double(s.memoryMB) * 0.6))
    }

    /// Models that fit, with the suggested one: the largest that fits — on CPU only also one that stays usable
    /// (≤ 4B with fewer than 8 cores, ≤ 8B otherwise).
    public static func choices(for s: Status) -> (fitting: [Choice], suggested: Choice?) {
        let budget = budgetMB(s)
        let fitting = catalog.filter { $0.neededMB <= budget && Int($0.sizeGB * 1024) + 1024 <= s.diskFreeMB }
        let cpuCap: Double = s.gpu != nil ? .infinity : (s.cpus < 8 ? 2.5 : 5.2)
        return (fitting, fitting.last { $0.sizeGB <= cpuCap } ?? fitting.first)
    }

    // MARK: - Install, pull, measure

    /// Root: installs Ollama with its official script when missing and makes sure it runs, bound to localhost.
    /// Without systemd (containers) it starts `ollama serve` itself.
    public static let installScript = """
    set -e
    need=""
    command -v curl >/dev/null 2>&1 || need="$need curl"
    command -v zstd >/dev/null 2>&1 || need="$need zstd"
    if [ -n "$need" ]; then
      echo '@@step packages'
      if command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need >/dev/null 2>&1
      elif command -v dnf >/dev/null 2>&1; then dnf install -y -q $need >/dev/null
      fi
    fi
    if ! command -v ollama >/dev/null 2>&1; then
      echo '@@step install'
      curl -fsSL https://ollama.com/install.sh -o /tmp/deckhand-ollama-install.sh
      if ! sh /tmp/deckhand-ollama-install.sh > /tmp/deckhand-ollama-install.log 2>&1; then
        grep -vE '^#|^\\s*$' /tmp/deckhand-ollama-install.log | tail -n 4
        echo 'The Ollama installer failed.'; exit 1
      fi
      rm -f /tmp/deckhand-ollama-install.sh
    fi
    echo '@@step start'
    up() { curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; }
    if ! up; then
      # systemd only when it really runs (containers often have the folder but no systemd).
      if [ -d /run/systemd/system ] && systemctl list-units --no-pager >/dev/null 2>&1 && systemctl cat ollama >/dev/null 2>&1; then
        systemctl enable --now ollama >/dev/null 2>&1 || true
        for i in $(seq 1 15); do up && break; sleep 1; done
      fi
    fi
    if ! up; then
      U=root; id ollama >/dev/null 2>&1 && U=ollama
      S=; command -v setsid >/dev/null 2>&1 && S=setsid
      $S su -s /bin/sh "$U" -c 'OLLAMA_HOST=127.0.0.1:11434 nohup ollama serve >> /tmp/ollama-serve.log 2>&1 &'
      for i in $(seq 1 40); do up && break; sleep 1; done
    fi
    up || { tail -n 3 /tmp/ollama-serve.log 2>/dev/null; echo 'Ollama was installed but does not answer on port 11434.'; exit 1; }
    echo 'Ollama is running (localhost only).'
    """

    /// Not root: pulls a model through the API; one JSON line per progress step.
    public static func pullCommand(_ model: String) -> String {
        "curl -sN --max-time 7200 http://127.0.0.1:11434/api/pull -d \(ShellQuote.quote(#"{"model":"\#(jsonEscaped(model))","stream":true}"#)); echo; echo '@@done'"
    }

    public struct PullProgress: Sendable, Hashable {
        public var status: String
        public var fraction: Double?
        public var error: String?
    }

    public static func parsePullLine(_ line: String) -> PullProgress? {
        guard let json = try? JSONValue.parse(line) else { return nil }
        if let e = json["error"]?.stringValue { return PullProgress(status: e, fraction: nil, error: e) }
        let status = json["status"]?.stringValue ?? ""
        if let total = json["total"]?.doubleValue, total > 0, let done = json["completed"]?.doubleValue {
            return PullProgress(status: status, fraction: min(1, done / total), error: nil)
        }
        return PullProgress(status: status, fraction: status == "success" ? 1 : nil, error: nil)
    }

    /// Not root: one short generation; prints the API's answer (eval_count, eval_duration…) and then `/api/ps`.
    public static func benchmarkCommand(_ model: String) -> String {
        let body = #"{"model":"\#(jsonEscaped(model))","prompt":"Explain in two sentences what a reverse proxy does.","stream":false,"think":false,"options":{"num_predict":96}}"#
        return """
        printf '@@gen '; curl -sS --max-time 600 http://127.0.0.1:11434/api/generate -d \(ShellQuote.quote(body)) | tr -d '\\n'; echo
        printf '@@ps '; curl -fsS -m 5 http://127.0.0.1:11434/api/ps | tr -d '\\n'; echo
        """
    }

    public struct Benchmark: Sendable, Hashable {
        public var tokensPerSecond: Double
        /// Seconds until the model was loaded and the answer started (cold start included).
        public var loadSeconds: Double
        public var memoryBytes: Int64
        public var onGPU: Bool
        public var sample: String
    }

    public static func parseBenchmark(_ out: String, model: String) -> Benchmark? {
        var gen: JSONValue?, ps: [Loaded] = []
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@gen ") { gen = try? JSONValue.parse(String(line.dropFirst(6))) }
            if line.hasPrefix("@@ps ") { ps = parse("@@running\n" + line).loaded }
        }
        guard let g = gen, let count = g["eval_count"]?.doubleValue, let ns = g["eval_duration"]?.doubleValue, ns > 0 else { return nil }
        let loaded = ps.first { $0.name == model || $0.name.hasPrefix(model + ":") || model.hasPrefix($0.name) }
        return Benchmark(tokensPerSecond: count / (ns / 1e9),
                         loadSeconds: (g["load_duration"]?.doubleValue ?? 0) / 1e9,
                         memoryBytes: loaded?.sizeBytes ?? 0, onGPU: loaded?.onGPU ?? false,
                         sample: (g["response"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Error text in a generate answer (model missing, out of memory…).
    public static func benchmarkError(_ out: String) -> String? {
        for line in out.split(separator: "\n") where line.hasPrefix("@@gen ") {
            if let e = (try? JSONValue.parse(String(line.dropFirst(6))))?["error"]?.stringValue { return e }
        }
        return nil
    }

    /// Not root: removes a model.
    public static func deleteCommand(_ model: String) -> String {
        "curl -fsS -X DELETE http://127.0.0.1:11434/api/delete -d \(ShellQuote.quote(#"{"model":"\#(jsonEscaped(model))"}"#)) && echo deleted"
    }

    static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// An address for a model on one of the user's servers: `deckhand-server://<server id>:<port>/v1`. The app swaps it
/// for an SSH tunnel to that port when a request goes out, so the model never has to listen on the internet.
public enum ServerModelURL {
    public static let scheme = "deckhand-server"

    public static func make(serverID: UUID, port: Int = OllamaSetup.port, path: String = "/v1") -> URL {
        URL(string: "\(scheme)://\(serverID.uuidString.lowercased()):\(port)\(path)")!
    }

    public static func parse(_ url: URL) -> (serverID: UUID, port: Int, path: String)? {
        guard url.scheme == scheme, let host = url.host(), let id = UUID(uuidString: host) else { return nil }
        return (id, url.port ?? OllamaSetup.port, url.path())
    }

    /// The same request path through a local tunnel port.
    public static func local(port: Int, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }
}
