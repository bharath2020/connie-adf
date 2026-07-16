import Foundation
import ADFModel

/// What a plugin matcher returns for a node it claims: the plugin's prepared
/// payload plus the declarations the pipeline needs. The library stamps the
/// claiming plugin's `rendererID` onto the resulting block itself, so a claim
/// can never point at the wrong renderer.
public struct ADFCustomBlockClaim: Sendable, Hashable {
    public let value: ADFCustomBlockValue
    public let sizing: ADFCustomBlockSizing
    /// Plain text this block contributes to find-in-page, or `nil` to stay
    /// out of the corpus. WYSIWYG contract: contribute ONLY text the plugin
    /// view actually renders — matching invisible text (a URL behind a
    /// thumbnail) makes "Next" cycle matches with nothing visibly changing.
    /// Matches emphasize the whole block (the atom model); there is no
    /// range-level painting inside plugin views.
    public let searchableText: String?

    public init<V: Hashable & Sendable>(
        _ value: V,
        sizing: ADFCustomBlockSizing,
        searchableText: String? = nil
    ) {
        self.value = ADFCustomBlockValue(value)
        self.sizing = sizing
        self.searchableText = searchableText
    }
}

/// One prepared custom (plugin-claimed) block: everything the pipeline needs,
/// as immutable Sendable + Hashable values — the same contract as every other
/// `RenderBlock.Kind` payload (no closures, no references; rows diff cheaply
/// and preparation runs on a detached task).
///
/// Only the claim loop constructs this (internal init): `rendererID` is the
/// claiming preparer's, by construction.
public struct ADFCustomBlock: Sendable, Hashable {
    /// The renderer that draws this block — stamped by the library from the
    /// preparer whose claim produced it.
    public let rendererID: String
    /// The plugin's own prepared payload (e.g. a parsed video reference).
    public let value: ADFCustomBlockValue
    /// How the block's height answers width and text-size changes; drives the
    /// collapsed-row spacer contracts the scroll machinery relies on.
    public let sizing: ADFCustomBlockSizing
    /// See `ADFCustomBlockClaim.searchableText`.
    public let searchableText: String?

    init(rendererID: String, claim: ADFCustomBlockClaim) {
        self.rendererID = rendererID
        self.value = claim.value
        self.sizing = claim.sizing
        self.searchableText = claim.searchableText
    }
}

/// Type-erased `Hashable & Sendable` box for plugin payloads, so plugin value
/// types ride inside `RenderBlock.Kind` without the enum knowing them.
public struct ADFCustomBlockValue: Sendable, Hashable {
    private let box: any Hashable & Sendable

    public init<V: Hashable & Sendable>(_ value: V) {
        self.box = value
    }

    /// The payload back as its concrete type (`nil` on a type mismatch).
    public func value<V: Hashable & Sendable>(as type: V.Type = V.self) -> V? {
        box as? V
    }

    /// `==` and `hash(into:)` must BOTH go through `AnyHashable`: its
    /// equality is bridging-normalized (`1 as Int == 1.0 as Double`), so
    /// hashing the unwrapped value directly would violate the Hashable law
    /// for values that only compare equal via bridging.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        AnyHashable(lhs.box) == AnyHashable(rhs.box)
    }

    public func hash(into hasher: inout Hasher) {
        AnyHashable(box).hash(into: &hasher)
    }
}

/// How a custom block's height responds to layout changes. The three cases
/// map onto the profiles the built-in kinds already use (media / card /
/// paragraph), and feed the two exhaustive per-kind switches that keep
/// collapsed-row spacer heights truthful across rotation and Dynamic Type
/// changes. Misdeclaring this corrupts scroll geometry — see
/// `CollapsedRowHeight`.
public enum ADFCustomBlockSizing: Sendable, Hashable {
    /// A fixed-aspect box (video player, map embed): height tracks the
    /// column width at `width : height`, stops growing past `maxWidth`
    /// (`nil` = tracks the column at any width), and ignores the text size.
    /// The LIBRARY applies this box around the plugin view, so the declared
    /// profile and the rendered geometry agree by construction.
    case aspectRatio(width: Double, height: Double, maxWidth: Double? = nil)
    /// Fixed layout whose text grows with the type size but whose height
    /// ignores the column width (link cards, horizontally scrolling strips).
    case scaledChrome
    /// Wrapping text: trades width for height, scales quadratically with the
    /// type size (each line gets taller AND fits fewer characters).
    case reflowingText
}

/// Preparation-time facet of a block plugin: claims block-level nodes and
/// prepares them into custom blocks.
///
/// `claim(for:)` runs inside the detached prepare walk, once per block-level
/// node, on documents up to thousands of blocks — it must be cheap (kind
/// checks, string prefix/host checks; no regex, no I/O) and return `nil`
/// fast for nodes it doesn't claim. The first registered plugin to claim a
/// node wins; declined nodes keep their built-in rendering.
///
/// Reach: the matcher sees every node that flows through the block
/// preparation walk — top level, panels, quotes, table cells, layout
/// columns, bodied extensions, list trailing blocks, and expand bodies. It
/// does NOT see inline positions: an atom mid-paragraph, or the LEADING
/// paragraph of a list item (list rows compose that inline) — those keep
/// their inline rendering.
public protocol ADFCustomBlockPreparer: Sendable {
    /// Stable identifier tying prepared blocks to their renderer. Reverse-DNS
    /// style recommended (`"adfkit.youtube"`). Must be unique per document.
    var rendererID: String { get }
    /// The prepared claim, or `nil` to decline this node.
    func claim(for node: ADFNode) -> ADFCustomBlockClaim?
}
