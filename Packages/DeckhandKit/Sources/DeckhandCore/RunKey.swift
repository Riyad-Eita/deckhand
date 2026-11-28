import Foundation

/// Runs an own-key task on the server, so it keeps going while the phone is locked: Claude Code with an Anthropic key,
/// Codex with an OpenAI key, detached like any server run.
///
/// The key never appears in a command line or the process list: the app sends it over stdin into
/// `~/.deckhand/runs/<id>.key/key` (mode 600 in a 700 folder). The run reads it into its environment and deletes the
/// file before the CLI starts; the folder goes away when the run ends or is stopped.
public enum RunKey {
    /// The CLI that does an own-key task on the server, or nil when this provider can't (OpenRouter, custom).
    public static func cli(for provider: ProviderKind) -> ServerCLI? {
        switch provider {
        case .anthropic: .claudeCode
        case .openAI: .codex
        case .openRouter, .custom: nil
        }
    }

    /// The variable the CLI reads its API key from.
    public static func variable(for cli: ServerCLI) -> String {
        switch cli {
        case .claudeCode: "ANTHROPIC_API_KEY"
        case .codex: "CODEX_API_KEY"
        }
    }

    public static func folder(_ run: DetachedRun) -> String { run.base + ".key" }

    /// Run through a channel; the first stdin line is the key. Prints "@@key ok".
    public static func prepareCommand(_ run: DetachedRun) -> String {
        let d = folder(run)
        return """
        umask 077; mkdir -p ~/.deckhand/runs; chmod 700 ~/.deckhand ~/.deckhand/runs
        D=\(d); rm -rf "$D"; mkdir -p "$D"; chmod 700 "$D"
        IFS= read -r K; printf '%s' "$K" > "$D/key"; K=
        [ -s "$D/key" ] && echo '@@key ok' || { rm -rf "$D"; echo '@@key empty'; }
        """
    }

    /// Wraps the run's command: the key goes into the environment, the file is deleted at once, the folder on exit.
    public static func wrap(_ command: String, run: DetachedRun, cli: ServerCLI) -> String {
        let d = folder(run)
        return """
        trap 'rm -rf \(d)' EXIT; trap 'exit 143' TERM INT
        export \(variable(for: cli))="$(cat \(d)/key 2>/dev/null)"; rm -f \(d)/key
        \(command)
        """
    }

    /// Stores the key for `run`. False when nothing arrived.
    public static func prepare(_ run: DetachedRun, key: String, on shell: any ChannelShell) async throws -> Bool {
        let channel = try await shell.openChannel(prepareCommand(run) + " 2>&1")
        defer { channel.close() }
        try await channel.send(key)
        for try await line in channel.lines where line.hasPrefix("@@key") { return line == "@@key ok" }
        return false
    }
}
