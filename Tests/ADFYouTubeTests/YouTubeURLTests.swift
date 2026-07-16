import Foundation
import Testing
@testable import ADFYouTube

@Suite("YouTubeURL")
struct YouTubeURLTests {
    @Test("recognizes every watchable URL shape", arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "dQw4w9WgXcQ"),
        ("https://music.youtube.com/watch?v=5qap5aO4i9A", "5qap5aO4i9A"),
        ("https://www.youtube.com/watch?list=PL123&v=jNQXAC9IVRw", "jNQXAC9IVRw"),
        ("https://youtu.be/9bZkp7q19f0", "9bZkp7q19f0"),
        ("https://youtu.be/9bZkp7q19f0?t=10", "9bZkp7q19f0"),
        ("http://youtu.be/9bZkp7q19f0", "9bZkp7q19f0"),
        ("https://www.youtube.com/embed/M7lc1UVf-VE", "M7lc1UVf-VE"),
        ("https://www.youtube-nocookie.com/embed/M7lc1UVf-VE", "M7lc1UVf-VE"),
        ("https://www.youtube.com/shorts/aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://www.youtube.com/live/8jLOx1hD3_o", "8jLOx1hD3_o"),
        ("https://www.youtube.com/v/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("HTTPS://WWW.YOUTUBE.COM/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ])
    func matches(url: String, expected: String) {
        #expect(YouTubeURL.videoID(from: url) == expected)
    }

    @Test("declines everything that is not a watchable video", arguments: [
        "https://vimeo.com/76979871",
        "https://www.youtube.com/@aChannelPage",
        "https://www.youtube.com/playlist?list=PLBCF2DAC6FFB574DE",
        "https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw",
        "https://www.youtube.com/user/somebody",
        "https://www.youtube.com/results?search_query=cats",
        "https://www.youtube.com/watch",
        "https://www.youtube.com/watch?v=",
        "https://www.youtube.com/watch?v=tooShort",
        "https://www.youtube.com/watch?v=waaaay-too-long-to-be-an-id",
        "https://www.youtube.com/watch?v=bad~chars!!",
        "https://youtu.be/",
        "https://fakeyoutube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "ftp://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "not a url at all",
        "",
    ])
    func declines(url: String) {
        #expect(YouTubeURL.videoID(from: url) == nil)
    }

    @Test("derived URLs point at the right endpoints")
    func derivedURLs() {
        #expect(
            YouTubeURL.thumbnailURL(videoID: "dQw4w9WgXcQ")?.absoluteString
                == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
        )
        #expect(
            YouTubeURL.embedURL(videoID: "dQw4w9WgXcQ")?.absoluteString
                == "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&playsinline=1"
        )
    }
}
