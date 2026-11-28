import Foundation

/// Agent skills (a folder with a SKILL.md: YAML front matter with `name` and `description`, then instructions) on a
/// server: made or imported once, used by Claude Code (~/.claude/skills), Codex (~/.codex/skills) and the own-key
/// agent (which sees the list and reads a skill when it needs it).
public enum Skills {
    public enum Target: String, Sendable, Hashable, CaseIterable, Codable {
        case claude, codex
        public var dir: String { self == .claude ? "$HOME/.claude/skills" : "$HOME/.codex/skills" }
        public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    }

    public struct Skill: Sendable, Hashable, Identifiable {
        public var name: String
        public var description: String
        /// Where it is installed.
        public var targets: Set<Target>
        /// Folder of the copy the agent reads (Claude's if there, else Codex's).
        public var path: String
        public var id: String { name }
    }

    /// Folder names Deckhand writes: lowercase letters, digits and '-', like the skill names the CLIs accept.
    public static func isValidName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
            && !s.hasPrefix("-") && !s.hasSuffix("-")
    }

    /// "My Deploy Helper!" → "my-deploy-helper".
    public static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
    }

    /// `name` and `description` from a SKILL.md's front matter (nil without front matter).
    public static func frontMatter(_ text: String) -> (name: String?, description: String?)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var name: String?, description: String?
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" { value = String(value.dropFirst().dropLast()) }
            if key == "name" { name = value }
            if key == "description" { description = value }
        }
        return (name, description)
    }

    /// A new SKILL.md.
    public static func template(name: String, description: String, body: String) -> String {
        let d = description.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return "---\nname: \(name)\ndescription: \"\(d)\"\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    // MARK: - On the server

    /// Lines "<target>\t<name>\t<description>" for every skill folder with a SKILL.md.
    public static let listCommand = #"""
    for t in claude codex; do
      d="$HOME/.$t/skills"; [ -d "$d" ] || continue
      for f in "$d"/*/SKILL.md; do
        [ -f "$f" ] || continue
        n="$(basename "$(dirname "$f")")"
        desc="$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} /^description:/ {sub(/^description:[ ]*/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' "$f" | tr '\t' ' ')"
        printf '%s\t%s\t%s\n' "$t" "$n" "$desc"
      done
    done
    """#

    public static func parseList(_ output: String) -> [Skill] {
        var byName: [String: Skill] = [:]
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let target = Target(rawValue: f[0]) else { continue }
            let name = f[1], desc = f.count > 2 ? f[2] : ""
            var s = byName[name] ?? Skill(name: name, description: desc, targets: [], path: "~/.\(target.rawValue)/skills/\(name)")
            s.targets.insert(target)
            if s.description.isEmpty { s.description = desc }
            if target == .claude { s.path = "~/.claude/skills/\(name)" }
            byName[name] = s
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Writes a SKILL.md (made in the app, from a file or a URL) as skill `name` for each target.
    public static func writeCommand(name: String, skillMD: String, targets: Set<Target>) -> String? {
        guard isValidName(name), !targets.isEmpty else { return nil }
        let b64 = Data(skillMD.utf8).base64EncodedString()
        return targets.sorted { $0.rawValue < $1.rawValue }.map { t in
            "mkdir -p \"\(t.dir)/\(name)\" && printf '%s' '\(b64)' | base64 -d > \"\(t.dir)/\(name)/SKILL.md\""
        }.joined(separator: " && ") + " && echo @@ok"
    }

    /// Copies an installed skill folder to another target (or more), so both CLIs have it.
    public static func copyCommand(name: String, from: Target, to: Target) -> String? {
        guard isValidName(name), from != to else { return nil }
        return "mkdir -p \"\(to.dir)\" && rm -rf \"\(to.dir)/\(name)\" && cp -R \"\(from.dir)/\(name)\" \"\(to.dir)/\(name)\" && echo @@ok"
    }

    public static func removeCommand(name: String, from target: Target) -> String? {
        guard isValidName(name) else { return nil }
        return "rm -rf \"\(target.dir)/\(name)\" && echo @@ok"
    }

    /// Imports every skill in a git repository (a SKILL.md at the top, or one per folder, e.g. skills/*/SKILL.md).
    /// Nothing from the repository runs: it is cloned shallow and only skill folders are copied. Prints the names.
    public static func importGitCommand(url: String, targets: Set<Target>) -> String? {
        guard url.hasPrefix("https://"), !url.contains(" "), !targets.isEmpty else { return nil }
        let copies = targets.sorted { $0.rawValue < $1.rawValue }.map { t in
            "mkdir -p \"\(t.dir)\" && rm -rf \"\(t.dir)/$n\" && cp -R \"$d\" \"\(t.dir)/$n\""
        }.joined(separator: " && ")
        return """
        set -e; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
        R="$(basename \(ShellQuote.quote(url)) .git)"
        GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 \(ShellQuote.quote(url)) "$W/repo" 2>&1 | tail -3
        rm -rf "$W/repo/.git"
        (cd "$W/repo" && find . -maxdepth 4 -name SKILL.md | sort) > "$W/list"
        found=0
        while IFS= read -r f; do
          rel="$(dirname "$f")"; d="$W/repo/$rel"
          if [ "$rel" = "." ]; then base="$R"; else base="$(basename "$rel")"; fi
          n="$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} /^name:/ {sub(/^name:[ ]*/, ""); print; exit}' "$W/repo/$f")"
          [ -n "$n" ] || n="$base"
          n="$(printf '%s' "$n" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-64)"
          [ -n "$n" ] || continue
          \(copies)
          echo "@@skill $n"; found=$((found+1))
        done < "$W/list"
        [ "$found" -gt 0 ] || { echo "@@none"; exit 3; }
        echo "@@ok"
        """
    }

    /// The own-key agent's view: what skills exist and where, read on demand (only names and descriptions here).
    public static func promptSection(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        let list = skills.prefix(40).map { "- \($0.name): \($0.description.isEmpty ? "(no description)" : String($0.description.prefix(200))) — \($0.path)/SKILL.md" }
        return """
        Skills on this server (instructions written for tasks like these). When a task matches one, read its SKILL.md \
        with read_file first and follow it; it may point to more files in its folder.
        \(list.joined(separator: "\n"))
        """
    }
}
