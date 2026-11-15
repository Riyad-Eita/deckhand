import CoreImage
import Foundation
import Testing
@testable import DeckhandCore

struct PairingTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../scripts/pair.sh").standardized

    let fp = "uY8m3vC1fLhQm0rXH2k2s9K5yJ3nYb7wq0PZcV4tA1E"
    var seed: String { Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

    @Test func parsesAPairingLink() throws {
        let url = try #require(URL(string: "deckhand://pair?h=203.0.113.7&p=2222&u=me&n=web-1&k=\(seed)&f=\(fp)%2C\(fp)&e=1794812400"))
        let c = try #require(Pairing.parse(url))
        #expect(c.host == "203.0.113.7" && c.port == 2222 && c.user == "me" && c.name == "web-1")
        #expect(c.seed == Data(repeating: 7, count: 32))
        #expect(c.fingerprints == ["SHA256:\(fp)", "SHA256:\(fp)"])
        #expect(c.isExpired(now: Date(timeIntervalSince1970: 1_794_812_401)))
    }

    @Test func refusesUnsafeOrIncompleteLinks() {
        for bad in [
            "deckhand://pair?h=-oProxyCommand=x&u=me&k=\(seed)&f=\(fp)&e=1",
            "deckhand://pair?h=example.com&u=me%3Bid&k=\(seed)&f=\(fp)&e=1",
            "deckhand://pair?h=example.com&u=me&k=short&f=\(fp)&e=1",
            "deckhand://pair?h=example.com&u=me&k=\(seed)&f=nope&e=1",
            "deckhand://pair?h=example.com&u=me&k=\(seed)&f=\(fp)",
            "deckhand://add?host=example.com",
        ] {
            #expect(Pairing.parse(URL(string: bad)!) == nil, "\(bad)")
        }
    }

    @Test func scriptIsValidShell() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", Self.script.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        #expect(text.contains("restrict,command="))
        #expect(text.contains(Pairing.command.replacingOccurrences(of: " | sh", with: "")))
    }

    /// The script's own QR encoder, checked by decoding its output with Core Image.
    @Test(arguments: [20, 120, 260, 380])
    func qrCodesDecode(length: Int) throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        let start = try #require(text.range(of: "<<'PY'\n"))
        let end = try #require(text.range(of: "\nPY\n", range: start.upperBound..<text.endIndex))
        let py = FileManager.default.temporaryDirectory.appendingPathComponent("dh-qr-\(UUID().uuidString.prefix(6)).py")
        try String(text[start.upperBound..<end.lowerBound]).write(to: py, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: py) }
        let message = String("deckhand://pair?h=example.com&p=22&u=me&k=abcdefghijklmnopqrstuvwxyz0123456789-_ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            .cycled(to: length))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [py.path, "--matrix", message]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let rows = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(Array.init)
        #expect(p.terminationStatus == 0 && !rows.isEmpty)
        #expect(try decode(rows) == message)
    }

    func decode(_ rows: [[Character]]) throws -> String? {
        let scale = 8, quiet = 4, n = rows.count, side = (n + 2 * quiet) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for (y, row) in rows.enumerated() {
            for (x, v) in row.enumerated() where v == "1" {
                for dy in 0..<scale { for dx in 0..<scale { pixels[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0 } }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side, size: CGSize(width: side, height: side), format: .L8,
                            colorSpace: CGColorSpaceCreateDeviceGray())
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
    }

    /// The forced command on its own, in a temporary home: one key once, nothing else.
    @Test func acceptTakesOneKeyOnce() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        let start = try #require(text.range(of: "<<'ACCEPT'\n"))
        let end = try #require(text.range(of: "\nACCEPT\n", range: start.upperBound..<text.endIndex))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dh-pair-\(UUID().uuidString.prefix(6))")
        let dir = home.appendingPathComponent(".deckhand/pair"), ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try String(text[start.upperBound..<end.lowerBound]).write(to: dir.appendingPathComponent("accept.sh"), atomically: true, encoding: .utf8)
        let id = "a1b2c3d4e5f6"
        let pairLine = "restrict,command=\"/bin/sh x\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOnetimeonetimeonetimeonetimeonetimeone deckhand-pair-\(id)"
        try "ssh-ed25519 AAAAexisting me@laptop\n\(pairLine)\n".write(to: ssh.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        func accept(_ key: String, until: Int) throws -> String {
            try "\(until)\n".write(to: dir.appendingPathComponent("\(id).until"), atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [dir.appendingPathComponent("accept.sh").path, id]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SSH_ORIGINAL_COMMAND": key]
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let later = Int(Date().timeIntervalSince1970) + 600
        #expect(try accept("ssh-ed25519 AAAA; rm -rf ~ x", until: later) == "@@badkey")
        #expect(try accept("command=\"sh\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPhonekeyphonekeyphonekeyphonekeyphoneke x", until: later) == "@@badkey")
        let phone = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPhonekeyphonekeyphonekeyphonekeyphoneke deckhand iPhone"
        #expect(try accept(phone, until: Int(Date().timeIntervalSince1970) - 1) == "@@expired")
        // The expired code removed itself; a new one for the real try.
        try (try String(contentsOf: ssh.appendingPathComponent("authorized_keys"), encoding: .utf8) + pairLine + "\n")
            .write(to: ssh.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        #expect(try accept(phone, until: later) == "@@paired")
        let keys = try String(contentsOf: ssh.appendingPathComponent("authorized_keys"), encoding: .utf8)
        #expect(keys == "ssh-ed25519 AAAAexisting me@laptop\n\(phone)\n")
    }
}

private extension String {
    func cycled(to n: Int) -> String {
        var s = ""
        while s.count < n { s += self }
        return String(s.prefix(n))
    }
}
