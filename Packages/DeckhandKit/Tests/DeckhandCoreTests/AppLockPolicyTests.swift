import Foundation
import Testing
@testable import DeckhandCore

@Suite struct AppLockPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func offNeverLocks() {
        #expect(!AppLockPolicy.shouldLock(enabled: false, backgroundedAt: nil, now: t0, delay: 0))
        #expect(!AppLockPolicy.shouldLock(enabled: false, backgroundedAt: t0, now: t0.addingTimeInterval(9999), delay: 0))
    }

    @Test func locksOnLaunch() {
        #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: nil, now: t0, delay: 3600))
    }

    @Test func respectsTheDelay() {
        #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: t0, now: t0, delay: 0))
        #expect(!AppLockPolicy.shouldLock(enabled: true, backgroundedAt: t0, now: t0.addingTimeInterval(299), delay: 300))
        #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: t0, now: t0.addingTimeInterval(300), delay: 300))
    }

    @Test func clockGoingBackwardsLocks() {
        #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: t0, now: t0.addingTimeInterval(-60), delay: 900))
    }

    @Test func delaysAreSorted() {
        #expect(AppLockPolicy.delays == AppLockPolicy.delays.sorted() && AppLockPolicy.delays.first == 0)
    }
}

@Suite struct KeyUnlockPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func lockedUntilUnlocked() {
        #expect(!KeyUnlockPolicy.isUnlocked(unlockedAt: nil, backgroundedAt: nil, now: t0))
        #expect(KeyUnlockPolicy.isUnlocked(unlockedAt: t0, backgroundedAt: nil, now: t0.addingTimeInterval(7200)))
    }

    @Test func staysOpenForAWhileInTheBackground() {
        let bg = t0.addingTimeInterval(60)
        #expect(KeyUnlockPolicy.isUnlocked(unlockedAt: t0, backgroundedAt: bg, now: bg.addingTimeInterval(599)))
        #expect(!KeyUnlockPolicy.isUnlocked(unlockedAt: t0, backgroundedAt: bg, now: bg.addingTimeInterval(600)))
        #expect(!KeyUnlockPolicy.isUnlocked(unlockedAt: t0, backgroundedAt: bg, now: bg.addingTimeInterval(-5)))
        #expect(!KeyUnlockPolicy.isUnlocked(unlockedAt: t0, backgroundedAt: nil, now: t0.addingTimeInterval(-1)))
    }

    @Test func protectsServerSecretsOnly() {
        #expect(KeyUnlockPolicy.protects(account: "server.1234"))
        #expect(KeyUnlockPolicy.protects(account: "server.1234.passphrase"))
        #expect(!KeyUnlockPolicy.protects(account: "apikey.anthropic"))
        #expect(!KeyUnlockPolicy.protects(account: "connection.1234"))
    }
}
