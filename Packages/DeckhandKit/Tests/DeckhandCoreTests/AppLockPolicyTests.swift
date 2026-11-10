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
