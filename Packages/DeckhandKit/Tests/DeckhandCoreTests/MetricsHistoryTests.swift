import Foundation
import Testing
@testable import DeckhandCore

struct MetricsHistoryTests {
    func samples(_ cpu: [Double]) -> [MetricsHistory.Sample] {
        cpu.enumerated().map { i, c in
            MetricsHistory.Sample(date: Date(timeIntervalSince1970: Double(i) * 300), cpu: c, memory: 40, disk: 60,
                                  rxBytes: Double(i) * 300 * 1024 * 10, txBytes: 0, load: 0.5)
        }
    }

    @Test func parsesSamples() {
        let p = MetricsHistory.parse("@@installed\n@@s 1700000000 12.5 41.0 63 1000 2000 0.42\n@@s broken\n")
        #expect(p.installed && p.samples.count == 1 && p.samples[0].cpu == 12.5 && p.samples[0].load == 0.42)
    }

    @Test func spikesStandOut() {
        let s = samples(Array(repeating: 10, count: 30) + [95] + Array(repeating: 11, count: 10))
        let points = MetricsHistory.series(s, metric: .cpu)
        #expect(points.filter(\.spike).map(\.value) == [95])
        // A calm but high series has no spikes; a short one doesn't judge at all.
        #expect(MetricsHistory.series(samples(Array(repeating: 80, count: 30)), metric: .cpu).allSatisfy { !$0.spike })
        #expect(MetricsHistory.series(samples([5, 90]), metric: .cpu).allSatisfy { !$0.spike })
        let sum = MetricsHistory.summary(points)!
        #expect(sum.peak == 95 && sum.peakAt == Date(timeIntervalSince1970: 30 * 300))
    }

    @Test func networkIsARate() {
        let points = MetricsHistory.series(samples(Array(repeating: 1, count: 5)), metric: .network)
        #expect(points.count == 4 && points.allSatisfy { abs($0.value - 10) < 0.001 })   // 10 KB/s
        var reset = samples(Array(repeating: 1, count: 3))
        reset[2].rxBytes = 0                                                             // counter reset (reboot)
        #expect(MetricsHistory.series(reset, metric: .network).count == 1)
    }
}
