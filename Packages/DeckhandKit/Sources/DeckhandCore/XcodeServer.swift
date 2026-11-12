import Foundation

/// A Mac with Remote Login as a server: find Xcode projects and schemes, then build, test, archive and upload to
/// App Store Connect with `xcodebuild` — as detached jobs, so they keep running when the phone locks.
public enum XcodeServer {
    // MARK: Detect

    /// `@@os <uname>`, `@@macos <version>`, `@@xcode <version> (<build>)`, `@@nokeychain` when the login keychain is
    /// locked (code signing then fails over SSH).
    public static let detectCommand = """
    echo "@@os $(uname -s)"
    [ "$(uname -s)" = Darwin ] || exit 0
    echo "@@macos $(sw_vers -productVersion 2>/dev/null)"
    v=$(xcodebuild -version 2>/dev/null | tr '\\n' ' '); [ -n "$v" ] && echo "@@xcode $v"
    security show-keychain-info login.keychain-db >/dev/null 2>&1 || echo '@@nokeychain'
    true
    """

    public struct Info: Sendable, Hashable {
        public var isMac = false
        public var macOS: String?
        /// "Xcode 27.2 Build version 27C5040a" → "27.2 (27C5040a)"
        public var xcode: String?
        public var keychainLocked = false
    }

    public static func parseDetect(_ out: String) -> Info {
        var i = Info()
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@os ") { i.isMac = line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "Darwin" }
            else if line.hasPrefix("@@macos ") { i.macOS = String(line.dropFirst(8)).nilIfEmpty }
            else if line.hasPrefix("@@xcode ") {
                let p = line.dropFirst(8).split(separator: " ").map(String.init)
                // ["Xcode", "27.2", "Build", "version", "27C5040a"]
                if p.count >= 2 { i.xcode = p.count >= 5 ? "\(p[1]) (\(p[4]))" : p[1] }
            } else if line == "@@nokeychain" { i.keychainLocked = true }
        }
        return i
    }

    // MARK: Projects

    public struct Project: Sendable, Hashable, Identifiable {
        /// Absolute path of the .xcodeproj or .xcworkspace.
        public var path: String
        public var id: String { path }
        public var isWorkspace: Bool { path.hasSuffix(".xcworkspace") }
        public var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        public var folder: String { (path as NSString).deletingLastPathComponent }
    }

    /// Projects and workspaces up to four levels below `root` (no Pods, DerivedData, build folders or the workspaces
    /// inside a project). A project next to a workspace of the same folder is left out — the workspace is the one to build.
    public static func projectsCommand(root: String = "~") -> String {
        """
        cd \(ServerTools.shellPath(root)) 2>/dev/null || exit 0
        find "$PWD" -maxdepth 4 \\( -name Pods -o -name DerivedData -o -name .build -o -name build -o -name node_modules -o -name '.*' -o -name Library \\) -prune -o \\
          \\( -name '*.xcworkspace' -o -name '*.xcodeproj' \\) -print 2>/dev/null | grep -v '\\.xcodeproj/' | sort | sed 's/^/@@project /' | head -n 200
        true
        """
    }

    public static func parseProjects(_ out: String) -> [Project] {
        let all = out.split(separator: "\n").filter { $0.hasPrefix("@@project ") }.map { Project(path: String($0.dropFirst(10))) }
        let workspaceFolders = Set(all.filter(\.isWorkspace).map(\.folder))
        return all.filter { $0.isWorkspace || !workspaceFolders.contains($0.folder) }
    }

    static func flag(_ p: Project) -> String { "\(p.isWorkspace ? "-workspace" : "-project") \(ShellQuote.quote(p.path))" }

    public static func schemesCommand(_ p: Project) -> String {
        "xcodebuild -list -json \(flag(p)) 2>/dev/null"
    }

    public static func parseSchemes(_ out: String) -> [String] {
        guard let start = out.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else { return [] }
        let body = (json["workspace"] ?? json["project"]) as? [String: Any]
        return (body?["schemes"] as? [String]) ?? []
    }

    // MARK: Jobs

    public enum Job: String, Sendable, CaseIterable, Identifiable {
        case build, test, archive, upload
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .build: "Build"
            case .test: "Test"
            case .archive: "Archive"
            case .upload: "Upload to App Store Connect"
            }
        }
    }

    /// App Store Connect key for signing and uploading without an Xcode account on the Mac. The .p8 must be on the
    /// Mac at `~/.appstoreconnect/private_keys/AuthKey_<keyID>.p8` (where Apple's tools look for it).
    public struct UploadKey: Sendable, Hashable {
        public var keyID: String
        public var issuerID: String
        public init(keyID: String, issuerID: String) { self.keyID = keyID; self.issuerID = issuerID }
    }

    /// The shell command for a job. Prints `@@step <name>` per phase and ends with `@@result ok|failed`; xcodebuild's
    /// own output goes in between (with `-quiet`, so mostly warnings and errors).
    public static func jobCommand(_ job: Job, project p: Project, scheme: String, key: UploadKey? = nil) -> String {
        let s = ShellQuote.quote(scheme)
        let auth = key.map {
            let file = "$HOME/.appstoreconnect/private_keys/AuthKey_\($0.keyID.filter { $0.isLetter || $0.isNumber }).p8"
            return " -allowProvisioningUpdates -authenticationKeyPath \"\(file)\" -authenticationKeyID \(ShellQuote.quote($0.keyID)) -authenticationKeyIssuerID \(ShellQuote.quote($0.issuerID))"
        } ?? " -allowProvisioningUpdates"
        let keyCheck = key.map {
            "[ -f \"$HOME/.appstoreconnect/private_keys/AuthKey_\($0.keyID.filter { $0.isLetter || $0.isNumber }).p8\" ] || { echo '@@nokey'; echo '@@result failed'; exit 0; }\n"
        } ?? ""
        let archive = "\"$HOME/.deckhand/xcode/\(scheme.filter { $0.isLetter || $0.isNumber || $0 == "-" })-$(date +%Y%m%d-%H%M%S).xcarchive\""
        let head = """
        export NSUnbufferedIO=YES
        cd \(ShellQuote.quote(p.folder)) || { echo '@@result failed'; exit 0; }
        mkdir -p "$HOME/.deckhand/xcode"
        """
        switch job {
        case .build:
            return head + """

            echo '@@step build'
            xcodebuild \(flag(p)) -scheme \(s) -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 && echo '@@result ok' || echo '@@result failed'
            """
        case .test:
            return head + """

            echo '@@step simulator'
            id=$(xcrun simctl list devices available -j 2>/dev/null | /usr/bin/python3 -c 'import json,sys
            d=json.load(sys.stdin)["devices"]
            v=lambda r:[int(n) for n in r.rsplit("iOS-",1)[-1].split("-") if n.isdigit()]
            ids=[x["udid"] for r,l in sorted(d.items(),key=lambda i:v(i[0]),reverse=True) if "iOS-" in r for x in l if x["name"].startswith("iPhone")]
            print(ids[0] if ids else "")')
            [ -n "$id" ] || { echo '@@nosimulator'; echo '@@result failed'; exit 0; }
            echo '@@step test'
            L=$(mktemp)
            xcodebuild \(flag(p)) -scheme \(s) -destination "platform=iOS Simulator,id=$id" test > "$L" 2>&1; rc=$?
            grep -E ': error:|^error:|Test Case .* failed|Executed [0-9]+ tests?|Test run with|\\*\\* TEST' "$L" | head -n 400
            rm -f "$L"
            [ $rc = 0 ] && echo '@@result ok' || echo '@@result failed'
            """
        case .archive, .upload:
            var cmd = head + "\n" + keyCheck + """
            security show-keychain-info login.keychain-db >/dev/null 2>&1 || echo '@@nokeychain'
            A=\(archive)
            echo '@@step archive'
            xcodebuild \(flag(p)) -scheme \(s) -destination 'generic/platform=iOS' -archivePath "$A"\(auth) -quiet archive 2>&1 || { echo '@@result failed'; exit 0; }
            echo "@@archive $A"
            """
            if job == .upload {
                cmd += """

                O=$(mktemp -d)
                printf '%s\\n' '<?xml version="1.0" encoding="UTF-8"?>' \\
                  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \\
                  '<plist version="1.0"><dict><key>method</key><string>app-store-connect</string>' \\
                  '<key>destination</key><string>upload</string><key>signingStyle</key><string>automatic</string></dict></plist>' > "$O/options.plist"
                echo '@@step upload'
                xcodebuild -exportArchive -archivePath "$A" -exportOptionsPlist "$O/options.plist" -exportPath "$O/out"\(auth) > "$O/log" 2>&1; rc=$?
                grep -vE '^[[:space:]]*$' "$O/log" | tail -n 40
                rm -rf "$O"
                [ $rc = 0 ] && { echo '@@uploaded'; echo '@@result ok'; } || echo '@@result failed'
                """
            } else {
                cmd += "\necho '@@result ok'"
            }
            return cmd
        }
    }

    // MARK: Results

    public struct Summary: Sendable, Hashable {
        public var ok: Bool?
        public var step: String?
        public var errors: [String] = []
        public var warnings = 0
        public var testsRun: Int?
        public var testsFailed: Int?
        public var failedTests: [String] = []
        public var archive: String?
        public var uploaded = false
        /// Plain explanations for known setup problems.
        public var hints: [String] = []
    }

    public static func summarize(_ out: String) -> Summary {
        var s = Summary()
        for raw in out.split(separator: "\n").map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@step ") { s.step = String(line.dropFirst(7)) }
            else if line == "@@result ok" { s.ok = true }
            else if line == "@@result failed" { s.ok = false }
            else if line.hasPrefix("@@archive ") { s.archive = String(line.dropFirst(10)) }
            else if line == "@@nokeychain" {
                s.hints.append("The Mac's login keychain is locked, so code signing can fail over SSH. Log in on the Mac once (or unlock it in Terminal with `security unlock-keychain`).")
            } else if line == "@@nokey" {
                s.hints.append("Copy your App Store Connect key (AuthKey_<ID>.p8) to ~/.appstoreconnect/private_keys on the Mac.")
            } else if line == "@@nosimulator" {
                s.hints.append("No iPhone simulator is installed on the Mac. Add one in Xcode → Settings → Components.")
            } else if line.contains(": error:") || line.hasPrefix("error:") || line.hasPrefix("xcodebuild: error:") {
                if s.errors.count < 30, !s.errors.contains(line) { s.errors.append(line) }
            } else if line.contains(": warning:") {
                s.warnings += 1
            } else if let m = line.range(of: #"Executed (\d+) tests?, with (\d+) failures?"#, options: .regularExpression) {
                let nums = line[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if nums.count >= 2 { s.testsRun = nums[0]; s.testsFailed = nums[1] }
            } else if let m = line.range(of: #"Test run with (\d+) tests?.* (passed|failed)"#, options: .regularExpression) {
                let nums = line[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if let n = nums.first { s.testsRun = (s.testsRun ?? 0) + n }
                if line.contains("failed"), s.testsFailed == nil { s.testsFailed = nums.dropFirst().last ?? 1 }
            } else if line.hasPrefix("Test Case "), line.hasSuffix("failed") || line.contains("' failed (") {
                if let a = line.firstIndex(of: "["), let b = line.firstIndex(of: "]") { s.failedTests.append(String(line[line.index(after: a)..<b])) }
            } else if line == "@@uploaded" {
                s.uploaded = true
            }
            if line.contains("errSecInternalComponent") {
                s.hints.append("Code signing couldn't use the signing key (errSecInternalComponent): the keychain that holds it is locked. Unlock it on the Mac.")
            }
        }
        return s
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
