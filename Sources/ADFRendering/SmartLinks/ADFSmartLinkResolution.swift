import Foundation

/// When a document looks up its smart links
/// (`ADFDocumentView(smartLinkResolution:)`). Every mode asks the host's
/// `ADFSmartLinkResolver` at most once per URL, at most four calls at once,
/// and shows the same stages (plain, loading, icon and title).
///
/// The scroll phase that `.afterScrolling` and `.afterScrollingWithNearby`
/// wait on is reported from iOS 18 / macOS 15. Before that both behave as
/// `.whileScrolling`.
///
/// In every mode:
/// - a link shows its loading look only once its lookup has run for
///   300 ms: a link scrolled past sooner, or a lookup that answers sooner,
///   never shows it;
/// - from iOS 18 / macOS 15, a title that arrives while the reader scrolls
///   is shown once the paragraph showing the link is fully on screen, or
///   when scrolling stops, so text never jumps across the screen's edge (a
///   paragraph usually gets shorter under its title).
public enum ADFSmartLinkResolution: String, CaseIterable, Sendable, Identifiable {
    /// Links are looked up as they come on screen, also while the reader
    /// scrolls (after a short dwell, so a fling past a link asks nothing).
    /// The default.
    case whileScrolling
    /// Links are looked up only once scrolling has stopped, including a
    /// fling's deceleration and an animated jump: then every link on
    /// screen. Lookups already running when scrolling resumes keep running
    /// while their links stay on screen.
    case afterScrolling
    /// As `.afterScrolling`, plus, while the reader is not scrolling, small
    /// batches of the off-screen links nearest the screen, so they show
    /// their titles as soon as they scroll in. Scrolling stops the batches.
    case afterScrollingWithNearby

    public var id: String { rawValue }

    /// Human-readable name for a host's settings picker.
    public var displayName: String {
        switch self {
        case .whileScrolling: return "While Scrolling"
        case .afterScrolling: return "After Scrolling"
        case .afterScrollingWithNearby: return "After Scrolling + Nearby"
        }
    }
}
