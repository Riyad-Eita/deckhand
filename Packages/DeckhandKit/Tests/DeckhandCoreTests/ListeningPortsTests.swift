import Foundation
import Testing
@testable import DeckhandCore

struct ListeningPortsTests {
    @Test func parsesAndSorts() {
        let ports = ListeningPorts.parse("""
        LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*
        LISTEN 0      128          0.0.0.0:22         0.0.0.0:*
        LISTEN 0      511        127.0.0.1:3000       0.0.0.0:*    users:(("node",pid=812,fd=21))
        LISTEN 0      511            [::1]:3000          [::]:*    users:(("node",pid=812,fd=22))
        LISTEN 0      511          0.0.0.0:80         0.0.0.0:*
        LISTEN 0      128             [::]:22            [::]:*
        """, hiding: [22])
        #expect(ports.map(\.port) == [80, 3000, 53])
        #expect(ports[1].localOnly && ports[1].process == "node")
        #expect(!ports[0].localOnly)
    }

    @Test func fallbacksForMinimalSystems() {
        let netstat = ListeningPorts.parse("""
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
        tcp        0      0 127.0.0.1:8765          0.0.0.0:*               LISTEN      812/python3
        tcp        0      0 0.0.0.0:2200            0.0.0.0:*               LISTEN      -
        """)
        #expect(netstat.map(\.port) == [2200, 8765])
        #expect(netstat.first { $0.port == 8765 }?.process == "python3")
        #expect(netstat.first { $0.port == 8765 }?.localOnly == true)
        let proc = ListeningPorts.parse("""
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:223D 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1234 1
           1: 00000000:0898 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1235 1
           2: 0100007F:223D 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  1000        0 1236 1
        """)
        #expect(proc.map(\.port) == [2200, 8765])
        #expect(proc.first { $0.port == 8765 }?.localOnly == true)
    }

    @Test func findsLocalLinks() {
        #expect(ListeningPorts.localPort(in: URL(string: "http://localhost:3000/dashboard")!) == 3000)
        #expect(ListeningPorts.localPort(in: URL(string: "http://127.0.0.1/")!) == 80)
        #expect(ListeningPorts.localPort(in: URL(string: "https://example.com:3000/")!) == nil)
    }
}
