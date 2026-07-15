import Foundation
import Observation
import SwiftUI
import ADFModel
import ADFPreparation

/// Loads one ADF document for rendering: parses off-main via `ADFParser`,
/// then streams `DocumentPreparer.prepareStream` chunks into `blocks` on the
/// main actor, so the first screenful appears while the tail prepares.
@Observable @MainActor
public final class ADFDocumentModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case parsing
        case preparing
        case ready
        case failed(String)
    }

    public private(set) var blocks: [RenderBlock] = []
    public private(set) var phase: Phase = .idle
    /// Top-level headings (block ID, plain-text title, level 1–6) in document
    /// order — the data source for table-of-contents menus.
    public private(set) var headings: [(id: String, title: String, level: Int)] = []
    /// Lazy-stack sections over `blocks`, maintained incrementally in
    /// `append` so `ADFDocumentView.body` never rebuilds the section
    /// structure during scroll (§8: no O(document) work in `body`). A table's
    /// header slice starts a section (as its pinned header) containing the
    /// row slices of the same table; every other run of blocks is a
    /// headerless section. Section IDs are stable as chunks stream in,
    /// because blocks only ever append at the end.
    private(set) var sections: [BlockSection] = []

    /// Find-in-page controller for this document (`run`/`next`/`previous`/
    /// `clear`, streamed `matchCount`, highlight payload). One per model.
    public let search: ADFDocumentSearch

    /// Expand blocks currently open, keyed by block ID. Owned here (not view
    /// `@State`) so expansion survives rows collapsing to spacers, and so
    /// search navigation can open expands programmatically.
    public var expandedBlocks: Set<String> = []

    /// Set to a block ID (typically a `headings` entry) to ask the visible
    /// `ADFDocumentView` to scroll there; the view consumes and clears it.
    public var scrollTarget: String?

    /// Animation the reader applies when honoring `scrollTarget`. Defaults
    /// to `.snappy` (a TOC jump); hosts driving scripted scrolls can
    /// substitute e.g. a long `.linear` for constant-velocity movement.
    /// Configuration, not UI state — hence not observed.
    @ObservationIgnored public var scrollTargetAnimation: Animation = .snappy

    /// Placement for the next `scrollTarget` consume. Set BEFORE
    /// `scrollTarget` (the consumer observes only `scrollTarget`); the view
    /// resets it to `.top` together with clearing the target.
    /// Configuration, not UI state — hence not observed.
    @ObservationIgnored public var scrollTargetPlacement: ADFScrollTargetPlacement = .top

    /// Scroll-anchoring registry the document view binds `scrollPosition(id:)`
    /// through. Owned here (not view `@State`) so search can read the
    /// top-visible row without any geometry. See `ScrollAnchorRegistry`.
    @ObservationIgnored let anchors = ScrollAnchorRegistry()

    let theme: ADFTheme

    @ObservationIgnored private let parser = ADFParser()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(theme: ADFTheme = .default) {
        self.theme = theme
        self.search = ADFDocumentSearch()
        self.search.model = self
    }

    deinit {
        // The load task captures `self` weakly, so releasing the model can
        // reach deinit mid-stream; cancelling here stops the detached
        // preparer promptly instead of at the next chunk boundary.
        loadTask?.cancel()
    }

    /// Parses `data` and streams prepared blocks in chunks of 50. Safe to
    /// call again: a previous in-flight load is cancelled first.
    public func load(data: Data) {
        loadTask?.cancel()
        blocks = []
        sections = []
        headings = []
        scrollTarget = nil
        scrollTargetPlacement = .top
        expandedBlocks = []
        search.reset()
        phase = .parsing

        let parser = self.parser
        let preparer = DocumentPreparer(theme: theme)
        // `self` stays weak for the whole stream: holding it strongly across
        // the loop would keep the model (and the detached preparer feeding
        // it) alive after the owner releases it. Each iteration re-checks;
        // when the model is gone the loop exits, ending the stream and
        // cancelling its producer.
        loadTask = Task { [weak self] in
            let document: ADFDocument
            do {
                document = try await parser.parse(data)
            } catch {
                if !Task.isCancelled {
                    self?.phase = .failed(String(describing: error))
                }
                return
            }
            guard self != nil, !Task.isCancelled else { return }
            self?.phase = .preparing
            for await chunk in preparer.prepareStream(document, chunkSize: 50) {
                guard let self, !Task.isCancelled else { return }
                self.append(chunk)
            }
            if !Task.isCancelled {
                self?.phase = .ready
            }
        }
    }

    private func append(_ chunk: [RenderBlock]) {
        search.indexAppended(chunk, theme: theme)
        blocks.append(contentsOf: chunk)
        for block in chunk {
            appendToSections(block)
            guard case .richText(let segments, let style) = block.kind, style.isHeading else {
                continue
            }
            headings.append(
                (id: block.id, title: Self.plainTitle(of: segments), level: style.headingLevel ?? 1)
            )
        }
    }

    /// Extends `sections` with one appended block in O(1): a table header
    /// slice opens a new section, row slices join the table section they
    /// follow contiguously (header slice IDs are `"<tableID>#header"`, row
    /// slices `"<tableID>#rows<n>"`), and everything else joins the trailing
    /// headerless section.
    private func appendToSections(_ block: RenderBlock) {
        if case .tableSlice(_, _, isHeaderSlice: true) = block.kind {
            sections.append(BlockSection(id: block.id, header: block, blocks: []))
            return
        }
        if case .tableSlice(_, _, isHeaderSlice: false) = block.kind,
           let last = sections.last, let header = last.header,
           block.id.hasPrefix(String(header.id.prefix(while: { $0 != "#" })) + "#") {
            sections[sections.count - 1].blocks.append(block)
            return
        }
        if let last = sections.last, last.header == nil {
            sections[sections.count - 1].blocks.append(block)
        } else {
            sections.append(BlockSection(id: "plain-\(block.id)", header: nil, blocks: [block]))
        }
    }

    private static func plainTitle(of segments: [InlineSegment]) -> String {
        var title = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                title += String(text.characters)
            case .atom(let atom, _):
                title += atom.fallbackText
            }
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled heading" : trimmed
    }
}

/// One lazy-stack section: an optional pinned header (a table's header
/// slice) plus its content blocks.
struct BlockSection: Identifiable, Sendable {
    let id: String
    let header: RenderBlock?
    var blocks: [RenderBlock]
}
