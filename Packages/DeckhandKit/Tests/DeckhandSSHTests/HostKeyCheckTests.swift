import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import DeckhandSSH

/// A changed host key is never accepted silently; a forgotten key (pinned nil) asks again with the new fingerprint.
@Suite struct HostKeyCheckTests {
    func key() -> NIOSSHPublicKey { NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey }

    func validate(_ check: HostKeyCheck, _ key: NIOSSHPublicKey) async -> Error? {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Void.self)
        check.validateHostKey(hostKey: key, validationCompletePromise: promise)
        for _ in 0..<50 { loop.run(); try? await Task.sleep(for: .milliseconds(10)) }
        do { try await promise.futureResult.get(); return nil } catch { return error }
    }

    @Test func pinnedKeyMatchesOrStopsWithBothFingerprints() async {
        let old = key(), new = key()
        let pinned = String(openSSHPublicKey: old)
        let asked = AskCounter()
        let check = HostKeyCheck(pinned: pinned) { _, _ in await asked.ask(); return true }
        #expect(await validate(check, old) == nil)
        let error = await validate(check, new)
        guard case .hostKeyChanged(let expected, let got)? = error as? SSHError else { Issue.record("not refused: \(String(describing: error))"); return }
        #expect(expected == SSHKeys.fingerprint(openSSHPublicKey: pinned))
        #expect(got == SSHKeys.fingerprint(openSSHPublicKey: String(openSSHPublicKey: new)))
        #expect(expected != got)
        #expect(await asked.count == 0)   // a changed key is never offered for trust, it just stops
    }

    @Test func aForgottenKeyAsksAgain() async {
        let new = key()
        let asked = AskCounter()
        let refuse = HostKeyCheck(pinned: nil) { _, fp in await asked.ask(fp); return false }
        guard case .hostKeyRejected? = await validate(refuse, new) as? SSHError else { Issue.record("trusted without asking"); return }
        #expect(await asked.fingerprints == [SSHKeys.fingerprint(openSSHPublicKey: String(openSSHPublicKey: new))])
        let trust = HostKeyCheck(pinned: nil) { _, _ in true }
        #expect(await validate(trust, new) == nil)
        #expect(trust.seen == String(openSSHPublicKey: new))   // this is what gets pinned
    }
}

actor AskCounter {
    var count = 0
    var fingerprints: [String] = []
    func ask(_ fp: String = "") { count += 1; if !fp.isEmpty { fingerprints.append(fp) } }
}
