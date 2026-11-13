import Foundation
import Testing
@testable import DeckhandCore

@Suite struct CrashReportsTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "metrickit-diagnostic", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesEveryDiagnostic() throws {
        let reports = CrashReports.parse(try fixture(), fileID: "f1")
        #expect(reports.map(\.kind) == [.crash, .hang, .cpu])
        let crash = reports[0]
        #expect(crash.id == "f1-crashDiagnostics-0")
        #expect(crash.headline == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(crash.explanation.contains("check in the app's code failed"))
        #expect(crash.appVersion == "1.2 (4)")
        #expect(crash.device == "iPhone17,1" && crash.osVersion.hasPrefix("iPhone OS 26.1"))
        #expect(crash.frames == ["Deckhand + 123456", "Deckhand + 120000", "SwiftUI + 99"])
        #expect(crash.date != nil)
        #expect(reports[1].headline == "Hang of 3.4 sec")
        #expect(reports[1].frames == ["Deckhand + 5"])
        #expect(reports[2].headline == "90 sec of CPU in 180 sec")
        #expect(reports[2].frames.isEmpty)
    }

    @Test func explanations() {
        func crash(_ meta: String) -> CrashReports.Report? {
            CrashReports.parse(Data(#"{"crashDiagnostics":[{"diagnosticMetaData":\#(meta)}]}"#.utf8)).first
        }
        #expect(crash(#"{"exceptionType":1,"signal":11}"#)?.explanation.contains("memory") == true)
        #expect(crash(#"{"exceptionType":10,"signal":6}"#)?.headline == "EXC_CRASH (SIGABRT)")
        #expect(crash(#"{"terminationReason":"Namespace FRONTBOARD, Code 0x8badf00d"}"#)?.explanation.contains("didn't respond") == true)
        #expect(CrashReports.parse(Data("not json".utf8)).isEmpty)
    }

    @Test func issueBodyHasNoIdentifiers() throws {
        let r = try #require(CrashReports.parse(try fixture()).first)
        let body = CrashReports.issueBody(r)
        #expect(body.contains("EXC_BREAKPOINT") && body.contains("Deckhand + 123456"))
        #expect(!body.contains("B2") && !body.contains("regionFormat"))
    }
}
