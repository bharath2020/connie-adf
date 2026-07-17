import Foundation
import Testing
@testable import ADFYouTube

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
