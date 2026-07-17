import Foundation
import Testing
@testable import ADFYouTube

/// Lets every pending main-actor task (the coalescer's deferred commit)
/// run before asserting.
@MainActor
private func drainMainQueue() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@Suite("Visibility coalescer")
@MainActor
struct VisibilityCoalescerTests {
    @Test("a burst ending false commits false — the final callback is never lost")
    func trueThenFalseCommitsFalse() async {
        let coalescer = VisibilityCoalescer()
        var committed: [Bool] = []
        // Both callbacks land before the deferred commit runs — the exact
        // interleaving that left the old committed-state guard stale.
        coalescer.set(true) { committed.append($0) }
        coalescer.set(false) { committed.append($0) }
        await drainMainQueue()
        #expect(committed == [false])
    }

    @Test("a burst ending true commits true")
    func falseThenTrueCommitsTrue() async {
        let coalescer = VisibilityCoalescer()
        var committed: [Bool] = []
        coalescer.set(false) { committed.append($0) }
        coalescer.set(true) { committed.append($0) }
        await drainMainQueue()
        #expect(committed == [true])
    }

    @Test("rapid oscillation coalesces into exactly one commit of the last value")
    func oscillationCoalesces() async {
        let coalescer = VisibilityCoalescer()
        var committed: [Bool] = []
        for i in 0..<9 {
            coalescer.set(i.isMultiple(of: 2)) { committed.append($0) }
        }
        await drainMainQueue()
        #expect(committed == [true]) // i == 8, the last set
    }

    @Test("separated callbacks each commit")
    func separatedCallbacksBothCommit() async {
        let coalescer = VisibilityCoalescer()
        var committed: [Bool] = []
        coalescer.set(true) { committed.append($0) }
        await drainMainQueue()
        coalescer.set(false) { committed.append($0) }
        await drainMainQueue()
        #expect(committed == [true, false])
    }
}

@Suite("Playback coordinator")
@MainActor
struct YouTubePlaybackCoordinatorTests {
    @Test("activating a second block takes over from the first — at most one active player")
    func exclusivity() {
        let playback = YouTubePlaybackCoordinator()
        playback.activate("0.1")
        #expect(playback.activeBlockID == "0.1")
        playback.activate("0.5")
        #expect(playback.activeBlockID == "0.5")
    }

    @Test("a stale deactivation from a torn-down row cannot kill a newer player")
    func staleDeactivationIgnored() {
        let playback = YouTubePlaybackCoordinator()
        playback.activate("0.1")
        playback.activate("0.5")
        playback.deactivate("0.1") // the old row's teardown fires late
        #expect(playback.activeBlockID == "0.5")
        playback.deactivate("0.5")
        #expect(playback.activeBlockID == nil)
    }
}
