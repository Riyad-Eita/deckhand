import Foundation

/// Seven days of CPU, memory, disk, network and load, sampled every five minutes by a cron job on the server, so
/// trends show even while the phone was off — with unusual spikes marked.
public enum MetricsHistory {
    static let dir = "$HOME/.deckhand/metrics"
    static let cronTag = "# deckhand-metrics"
    /// 7 days at one sample per 5 minutes.
    public static let keep = 2_016

    /// One line per run: `epoch cpu% mem% disk% rxBytes txBytes load1`.
    static let sampler = #"""
    #!/bin/sh
    # Deckhand metrics — every 5 minutes from cron.
    D="$HOME/.deckhand/metrics"; mkdir -p "$D"
    [ -r /proc/stat ] || exit 0
    a=$(head -1 /proc/stat); sleep 1; b=$(head -1 /proc/stat)
    cpu=$(printf '%s\n%s\n' "$a" "$b" | awk '{i=$5+$6; t=0; for (k=2;k<=NF;k++) t+=$k; if (NR==1) {t1=t; i1=i} else {dt=t-t1; di=i-i1; printf "%.1f", (dt>0 ? (dt-di)*100/dt : 0)}}')
    mem=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if (t>0) printf "%.1f", (t-a)*100/t; else print 0}' /proc/meminfo)
    disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}')
    net=$(awk -F'[: ]+' 'NR>2 && $2!="lo" {rx+=$3; tx+=$11} END{printf "%d %d", rx, tx}' /proc/net/dev)
    load=$(cut -d' ' -f1 /proc/loadavg)
    echo "$(date +%s) $cpu $mem ${disk:-0} $net $load" >> "$D/samples"
    tail -n 2016 "$D/samples" > "$D/samples.tmp" && mv "$D/samples.tmp" "$D/samples"
    """#

    public static let installCommand = """
    mkdir -p \(dir) && chmod 700 \(dir)
    printf '%s\\n' \(ShellQuote.quote(sampler)) > \(dir)/run.sh && chmod 700 \(dir)/run.sh
    command -v crontab >/dev/null 2>&1 || { echo '@@nocron'; exit 0; }
    { crontab -l 2>/dev/null | grep -v 'deckhand/metrics/run.sh'; echo "*/5 * * * * $HOME/.deckhand/metrics/run.sh >/dev/null 2>&1 \(cronTag)"; } | crontab -
    \(dir)/run.sh
    echo '@@ok'
    """

    public static let uninstallCommand = """
    crontab -l 2>/dev/null | grep -v 'deckhand/metrics/run.sh' | crontab - 2>/dev/null; rm -rf \(dir); echo '@@ok'
    """

    /// `@@installed` and the samples (`@@s <line>`), at most the last `limit`.
    public static func readCommand(limit: Int = keep) -> String {
        """
        crontab -l 2>/dev/null | grep -q 'deckhand/metrics/run.sh' && echo '@@installed'
        [ -f \(dir)/samples ] && tail -n \(limit) \(dir)/samples | sed 's/^/@@s /'
        true
        """
    }

    public struct Sample: Sendable, Hashable {
        public var date: Date
        public var cpu: Double
        public var memory: Double
        public var disk: Double
        public var rxBytes: Double
        public var txBytes: Double
        public var load: Double
    }

    public enum Metric: String, Sendable, CaseIterable, Identifiable {
        case cpu, memory, disk, network, load
        public var id: String { rawValue }
        public var title: String {
            switch self { case .cpu: "CPU"; case .memory: "Memory"; case .disk: "Disk"; case .network: "Network"; case .load: "Load" }
        }
        public var unit: String {
            switch self { case .cpu, .memory, .disk: "%"; case .network: "KB/s"; case .load: "" }
        }
        /// A spike must also be at least this high to count (no alarms about 2 % CPU).
        var spikeFloor: Double {
            switch self { case .cpu, .memory: 50; case .disk: 85; case .network: 500; case .load: 2 }
        }
    }

    public struct Point: Sendable, Hashable, Identifiable {
        public var date: Date
        public var value: Double
        public var spike: Bool
        public var id: Date { date }
    }

    public static func parse(_ out: String) -> (installed: Bool, samples: [Sample]) {
        var installed = false
        var samples: [Sample] = []
        for line in out.split(separator: "\n") {
            if line == "@@installed" { installed = true; continue }
            guard line.hasPrefix("@@s ") else { continue }
            let f = line.dropFirst(4).split(separator: " ").compactMap { Double($0) }
            guard f.count >= 7 else { continue }
            samples.append(Sample(date: Date(timeIntervalSince1970: f[0]), cpu: f[1], memory: f[2], disk: f[3], rxBytes: f[4], txBytes: f[5], load: f[6]))
        }
        return (installed, samples)
    }

    /// The series for one metric over `since`, with spikes marked (more than 3 standard deviations above the
    /// mean and above the metric's floor). Network is the combined in+out rate between samples (counter resets skipped).
    public static func series(_ samples: [Sample], metric: Metric, since: Date = .distantPast) -> [Point] {
        var values: [(Date, Double)] = []
        switch metric {
        case .network:
            for (a, b) in zip(samples, samples.dropFirst()) {
                let dt = b.date.timeIntervalSince(a.date)
                let bytes = (b.rxBytes - a.rxBytes) + (b.txBytes - a.txBytes)
                guard dt > 0, bytes >= 0 else { continue }
                values.append((b.date, bytes / dt / 1024))
            }
        default:
            values = samples.map { s in
                let v: Double = switch metric { case .cpu: s.cpu; case .memory: s.memory; case .disk: s.disk; case .load: s.load; case .network: 0 }
                return (s.date, v)
            }
        }
        values = values.filter { $0.0 >= since }
        guard !values.isEmpty else { return [] }
        let mean = values.map(\.1).reduce(0, +) / Double(values.count)
        let sd = (values.map { ($0.1 - mean) * ($0.1 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        return values.map { Point(date: $0.0, value: $0.1, spike: values.count >= 12 && $0.1 > mean + 3 * sd && $0.1 >= metric.spikeFloor) }
    }

    /// Average, peak and when the peak was.
    public static func summary(_ points: [Point]) -> (average: Double, peak: Double, peakAt: Date)? {
        guard let top = points.max(by: { $0.value < $1.value }) else { return nil }
        return (points.map(\.value).reduce(0, +) / Double(points.count), top.value, top.date)
    }
}
