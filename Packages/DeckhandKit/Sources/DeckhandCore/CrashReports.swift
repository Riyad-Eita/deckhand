import Foundation

/// Crash, hang and resource reports from MetricKit, read from their JSON form. They stay on the device; the user
/// decides whether to share one. No third-party SDK, no automatic upload.
public enum CrashReports {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case crash, hang, cpu, diskWrites, launch

        public var title: String {
            switch self {
            case .crash: String(localized: "Crash")
            case .hang: String(localized: "Hang")
            case .cpu: String(localized: "Heavy CPU use")
            case .diskWrites: String(localized: "Heavy disk writes")
            case .launch: String(localized: "Slow launch")
            }
        }
    }

    public struct Report: Sendable, Hashable, Identifiable {
        public var id: String
        public var kind: Kind
        public var date: Date?
        public var appVersion: String
        public var osVersion: String
        public var device: String
        /// One line, e.g. "EXC_BREAKPOINT (SIGTRAP)" or "Hang of 3.4 sec".
        public var headline: String
        /// What it means, in plain words.
        public var explanation: String
        /// The crashed (or main) thread's frames, innermost first: "Deckhand + 123456".
        public var frames: [String]
    }

    /// Every diagnostic in one MetricKit payload (`MXDiagnosticPayload.jsonRepresentation()`).
    public static func parse(_ data: Data, fileID: String = UUID().uuidString) -> [Report] {
        guard let json = try? JSONValue.parse(data) else { return [] }
        let date = (json["timeStampEnd"]?.stringValue ?? json["timeStampBegin"]?.stringValue).flatMap(parseDate)
        var out: [Report] = []
        let groups: [(String, Kind)] = [
            ("crashDiagnostics", .crash), ("hangDiagnostics", .hang), ("cpuExceptionDiagnostics", .cpu),
            ("diskWriteExceptionDiagnostics", .diskWrites), ("appLaunchDiagnostics", .launch),
        ]
        for (key, kind) in groups {
            for (i, d) in (json[key]?.arrayValue ?? []).enumerated() {
                let meta = d["diagnosticMetaData"] ?? .null
                out.append(Report(
                    id: "\(fileID)-\(key)-\(i)", kind: kind, date: date,
                    appVersion: [meta["appVersion"]?.stringValue, meta["appBuildVersion"]?.stringValue.map { "(\($0))" }]
                        .compactMap { $0 }.joined(separator: " "),
                    osVersion: meta["osVersion"]?.stringValue ?? "",
                    device: meta["deviceType"]?.stringValue ?? "",
                    headline: headline(kind, meta),
                    explanation: explanation(kind, meta),
                    frames: frames(d["callStackTree"])))
            }
        }
        return out
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static let exceptionNames: [Int: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION", 5: "EXC_SOFTWARE",
        6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD",
    ]
    static let signalNames: [Int: String] = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV"]

    static func headline(_ kind: Kind, _ meta: JSONValue) -> String {
        switch kind {
        case .crash:
            let ex = meta["exceptionType"]?.intValue.map { exceptionNames[$0] ?? "Exception \($0)" }
            let sig = meta["signal"]?.intValue.map { signalNames[$0] ?? "signal \($0)" }
            let parts = [ex, sig.map { "(\($0))" }].compactMap { $0 }
            return parts.isEmpty ? (meta["terminationReason"]?.stringValue ?? "Crash") : parts.joined(separator: " ")
        case .hang: return String(localized: "Hang of \(meta["hangDuration"]?.stringValue ?? "?")")
        case .cpu: return String(localized: "\(meta["totalCPUTime"]?.stringValue ?? "?") of CPU in \(meta["totalSampledTime"]?.stringValue ?? "?")")
        case .diskWrites: return String(localized: "\(meta["writesCaused"]?.stringValue ?? "?") written")
        case .launch: return String(localized: "Launch took \(meta["launchDuration"]?.stringValue ?? "?")")
        }
    }

    static func explanation(_ kind: Kind, _ meta: JSONValue) -> String {
        switch kind {
        case .crash:
            let reason = (meta["terminationReason"]?.stringValue ?? "").lowercased()
            if reason.contains("8badf00d") { return String(localized: "iOS ended the app because it didn't respond in time.") }
            switch (meta["exceptionType"]?.intValue, meta["signal"]?.intValue) {
            case (6?, _), (_, 5?): return String(localized: "A check in the app's code failed — for example an empty value that was expected to be there.")
            case (_, 6?): return String(localized: "The app stopped itself after an error it couldn't recover from.")
            case (1?, _), (_, 11?), (_, 10?): return String(localized: "The app read memory it wasn't allowed to.")
            case (11?, _): return String(localized: "iOS ended the app for using too much of a resource (memory, CPU or wakeups).")
            default: return String(localized: "The app quit unexpectedly.")
            }
        case .hang: return String(localized: "The app didn't react to touches for a while.")
        case .cpu: return String(localized: "The app kept the processor busy for a long time, which drains the battery.")
        case .diskWrites: return String(localized: "The app wrote a lot of data to storage in a short time.")
        case .launch: return String(localized: "The app took long to open.")
        }
    }

    /// The attributed thread's frames (or the first thread's), following the first sub-frame at each level.
    static func frames(_ tree: JSONValue?) -> [String] {
        guard let stacks = tree?["callStacks"]?.arrayValue, !stacks.isEmpty else { return [] }
        let stack = stacks.first { $0["threadAttributed"] == .bool(true) } ?? stacks[0]
        var out: [String] = []
        var level = stack["callStackRootFrames"]?.arrayValue ?? []
        while let f = level.first, out.count < 40 {
            let name = f["binaryName"]?.stringValue ?? "?"
            let offset = f["offsetIntoBinaryTextSegment"]?.intValue.map(String.init) ?? "?"
            out.append("\(name) + \(offset)")
            level = f["subFrames"]?.arrayValue ?? []
        }
        return out
    }

    /// Text for a GitHub issue: what happened and the frames — no device identifiers beyond model and OS.
    public static func issueBody(_ r: Report) -> String {
        """
        **\(r.kind.title):** \(r.headline)
        \(r.explanation)

        - App: \(r.appVersion)
        - iOS: \(r.osVersion)
        - Device: \(r.device)

        ```
        \(r.frames.prefix(20).joined(separator: "\n"))
        ```
        """
    }
}
