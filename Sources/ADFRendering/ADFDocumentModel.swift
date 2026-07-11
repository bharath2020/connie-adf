import Foundation
import Observation
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

    /// Set to a block ID (typically a `headings` entry) to ask the visible
    /// `ADFDocumentView` to scroll there; the view consumes and clears it.
    public var scrollTarget: String?

    let theme: ADFTheme

    @ObservationIgnored private let parser = ADFParser()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(theme: ADFTheme = .default) {
        self.theme = theme
    }

    /// Parses `data` and streams prepared blocks in chunks of 50. Safe to
    /// call again: a previous in-flight load is cancelled first.
    public func load(data: Data) {
        loadTask?.cancel()
        blocks = []
        headings = []
        scrollTarget = nil
        phase = .parsing

        let parser = self.parser
        let preparer = DocumentPreparer(theme: theme)
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
            guard let self, !Task.isCancelled else { return }
            self.phase = .preparing
            for await chunk in preparer.prepareStream(document, chunkSize: 50) {
                if Task.isCancelled { return }
                self.append(chunk)
            }
            if !Task.isCancelled {
                self.phase = .ready
            }
        }
    }

    private func append(_ chunk: [RenderBlock]) {
        blocks.append(contentsOf: chunk)
        for block in chunk {
            guard case .richText(let segments, let style) = block.kind, style.isHeading else {
                continue
            }
            headings.append(
                (id: block.id, title: Self.plainTitle(of: segments), level: style.headingLevel ?? 1)
            )
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
