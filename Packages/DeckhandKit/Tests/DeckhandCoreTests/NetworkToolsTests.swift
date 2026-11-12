import Foundation
import Testing
@testable import DeckhandCore

struct NetworkToolsTests {
    @Test func targetsAreHostsOnly() {
        #expect(NetworkTools.isValidTarget("shop.example.com") && NetworkTools.isValidTarget("2001:db8::1"))
        #expect(!NetworkTools.isValidTarget("x; rm -rf /") && !NetworkTools.isValidTarget("-oProxyCommand=x") && !NetworkTools.isValidTarget(""))
        #expect(NetworkTools.host(from: "https://shop.example.com:8443/path") == "shop.example.com")
        #expect(NetworkTools.host(from: "2001:db8::1") == "2001:db8::1")
    }

    @Test func pingSummary() {
        let out = """
        PING example.com (93.184.216.34) 56(84) bytes of data.
        4 packets transmitted, 3 received, 25% packet loss, time 3004ms
        rtt min/avg/max/mdev = 11.2/12.8/15.1/1.4 ms
        """
        let r = NetworkTools.parse(.ping, out)
        #expect(r.ok == true && r.summary == ["3 of 4 replies", "12.8 ms average (11.2–15.1 ms)"])
        #expect(NetworkTools.parse(.ping, "ping: nope.invalid: Name or service not known").ok == false)
    }

    @Test func dnsPortHttpTraceroute() {
        let dns = NetworkTools.parse(.dns, "@@answer 93.184.216.34\n@@server 1.1.1.1#53(1.1.1.1) (UDP)")
        #expect(dns.ok == true && dns.summary == ["93.184.216.34", "Answered by 1.1.1.1#53(1.1.1.1) (UDP)"])
        #expect(NetworkTools.parse(.dns, "@@server x").summary.first == "No records")
        let port = NetworkTools.parse(.port, "@@port open 23")
        #expect(port.ok == true && port.summary == ["Open (23 ms)"])
        #expect(NetworkTools.parse(.port, "@@port closed 5001").ok == false)
        let http = NetworkTools.parse(.http, "@@http 200 0.004 0.020 0.061 0.130 0.140 93.184.216.34 1")
        #expect(http.ok == true && http.summary.first == "Status 200" && http.summary.contains("Total 140 ms") && http.summary.contains("1 redirects"))
        let trace = NetworkTools.parse(.traceroute, " 1?: [LOCALHOST]  pmtu 1500\n 1:  172.17.0.1  0.1ms\n 2:  10.0.0.1  1.0ms\n     Resume: pmtu 1500")
        #expect(trace.summary.first == "2 hops")
        #expect(NetworkTools.parse(.traceroute, "@@missing traceroute").ok == false)
    }

    @Test func dohAnswers() {
        let d = Data(#"{"Status":0,"Answer":[{"name":"example.com","type":1,"TTL":300,"data":"93.184.216.34"}]}"#.utf8)
        #expect(NetworkTools.parseDoH(d) == ["93.184.216.34"])
    }
}
