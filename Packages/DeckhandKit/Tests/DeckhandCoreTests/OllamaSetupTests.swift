import Foundation
import Testing
@testable import DeckhandCore

@Suite struct OllamaSetupTests {
    @Test func parsesStatus() {
        let out = """
        @@arch x86_64
        @@cpus 4
        @@mem 8192
        @@memfree 4105
        @@disk 21000
        @@gpu NVIDIA GeForce RTX 4090, 24564
        @@installed 0.12.6
        @@running
        @@tags {"models":[{"name":"qwen3:0.6b","model":"qwen3:0.6b","size":522653767,"details":{"parameter_size":"751.63M"}}]}
        @@ps {"models":[{"name":"qwen3:0.6b","size":1203000000,"size_vram":1203000000}]}
        """
        let s = OllamaSetup.parse(out)
        #expect(s.cpus == 4 && s.memoryMB == 8192 && s.availableMB == 4105 && s.diskFreeMB == 21000)
        #expect(s.gpu == "NVIDIA GeForce RTX 4090" && s.gpuMemoryMB == 24564)
        #expect(s.installed && s.version == "0.12.6" && s.running && !s.systemd)
        #expect(s.models == [.init(name: "qwen3:0.6b", sizeBytes: 522_653_767, parameters: "751.63M")])
        #expect(s.loaded.first?.onGPU == true)
        #expect(!OllamaSetup.parse("@@cpus 2").installed)
    }

    @Test func suggestsWhatFits() {
        var cpu = OllamaSetup.Status()
        cpu.cpus = 4; cpu.memoryMB = 8192; cpu.availableMB = 4105; cpu.diskFreeMB = 21000
        let a = OllamaSetup.choices(for: cpu)
        #expect(a.fitting.map(\.name) == ["qwen3:0.6b", "qwen3:1.7b", "qwen3:4b"])
        #expect(a.suggested?.name == "qwen3:4b")

        var big = cpu
        big.gpu = "RTX 4090"; big.gpuMemoryMB = 24564; big.diskFreeMB = 100_000
        #expect(OllamaSetup.choices(for: big).suggested?.name == "qwen3:32b")

        var tiny = cpu
        tiny.memoryMB = 2048; tiny.availableMB = 1500
        #expect(OllamaSetup.choices(for: tiny).suggested?.name == "qwen3:0.6b")

        var noDisk = cpu
        noDisk.diskFreeMB = 1200
        #expect(OllamaSetup.choices(for: noDisk).fitting.isEmpty)

        // Lots of RAM but few cores: stays at a usable size.
        var wide = cpu
        wide.memoryMB = 65536; wide.availableMB = 60000
        #expect(OllamaSetup.choices(for: wide).suggested?.name == "qwen3:4b")
        wide.cpus = 16
        #expect(OllamaSetup.choices(for: wide).suggested?.name == "qwen3:8b")
    }

    @Test func pullProgress() {
        #expect(OllamaSetup.parsePullLine(#"{"status":"pulling 7f4030143c1c","digest":"sha256:x","total":522000000,"completed":261000000}"#)?.fraction == 0.5)
        #expect(OllamaSetup.parsePullLine(#"{"status":"success"}"#)?.fraction == 1)
        #expect(OllamaSetup.parsePullLine(#"{"error":"pull model manifest: file does not exist"}"#)?.error != nil)
        #expect(OllamaSetup.parsePullLine("@@done") == nil)
        #expect(OllamaSetup.pullCommand("qwen3:0.6b").contains(#"'{"model":"qwen3:0.6b","stream":true}'"#))
    }

    @Test func benchmark() throws {
        let out = """
        @@gen {"model":"qwen3:0.6b","response":"A reverse proxy sits in front of servers.","done":true,"load_duration":1500000000,"eval_count":80,"eval_duration":2000000000}
        @@ps {"models":[{"name":"qwen3:0.6b","size":1203000000,"size_vram":0}]}
        """
        let b = try #require(OllamaSetup.parseBenchmark(out, model: "qwen3:0.6b"))
        #expect(b.tokensPerSecond == 40)
        #expect(b.loadSeconds == 1.5)
        #expect(b.memoryBytes == 1_203_000_000 && !b.onGPU)
        #expect(b.sample.hasPrefix("A reverse proxy"))
        #expect(OllamaSetup.benchmarkError(#"@@gen {"error":"model 'x' not found"}"#) == "model 'x' not found")
    }

    @Test func serverModelURLRoundTrip() throws {
        let id = UUID()
        let url = ServerModelURL.make(serverID: id)
        #expect(url.absoluteString == "deckhand-server://\(id.uuidString.lowercased()):11434/v1")
        let p = try #require(ServerModelURL.parse(url))
        #expect(p.serverID == id && p.port == 11434 && p.path == "/v1")
        #expect(ServerModelURL.local(port: 50123, path: p.path).absoluteString == "http://127.0.0.1:50123/v1")
        #expect(ServerModelURL.parse(URL(string: "http://localhost:11434/v1")!) == nil)
    }
}
