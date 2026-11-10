import Testing
@testable import DeckhandCore

@Suite struct ServerStatsTests {
    static let sample = """
    @@cpu1
    cpu  1378306329 1074307123 828838867 8067724822 0 0 0 0
    @@cpu2
    cpu  1378306333 1074307123 828838869 8067725017 0 0 0 0
    @@mem
    MemTotal:        8388608 kB
    MemAvailable:    4306196 kB
    SwapTotal:             0 kB
    SwapFree:              0 kB
    @@load
    0.29 0.41 0.54 2/4 284694
    @@uptime
    28371739.41
    @@cores
    4
    @@df
    Filesystem        1024-blocks      Used Available Capacity Mounted on
    /dev/ploop11118p1   123721280 102420108  16147064      87% /
    /dev/sda1              523248      6220    517028       2% /boot/efi
    /dev/ploop11118p1   123721280 102420108  16147064      87% /etc/hosts
    """

    @Test func parsesRealOutput() throws {
        let s = try #require(ServerStats.parse(Self.sample))
        #expect(abs(s.cpu - 6.0 / 201.0) < 0.0001)
        #expect(s.cores == 4)
        #expect(s.load.0 == 0.29)
        #expect(s.memTotalKB == 8_388_608)
        #expect(abs(s.memUsedFraction - 0.4867) < 0.001)
        #expect(s.disks.map(\.mount) == ["/"])
        #expect(s.warnings == ["/ is 87 % full"])
        #expect(ByteFormat.duration(s.uptime) == "328d 9h")
    }

    @Test func rejectsGarbage() {
        #expect(ServerStats.parse("not linux") == nil)
    }
}
