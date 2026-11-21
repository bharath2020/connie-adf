import Foundation
import ADFAtlassianAuth
import ADFAtlassianMedia
import ADFRendering
import ADFResolvers

/// The reader setting "Load Custom Emoji from Atlassian" (Settings →
/// Reader). Off by default (a missing key): Atlassian has no documented
/// emoji API, so `AtlassianEmojiFetcher` uses the emoji service Atlassian's
/// own editor uses, which may change without notice
/// (`docs/Atlassian-Media-Fetch.md` §6). A change applies to the next
/// Confluence page opened.
enum AtlassianEmojiPreference {
    static let key = "adf.emoji.atlassian.enabled"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Which custom-emoji resolver a reader gets, and the resolvers themselves:
/// each is made once per app session and shared by every reader, so its
/// memory cache serves every document.
///
/// | Launch flag  | Fixtures and beamed documents | Confluence pages |
/// |--------------|-------------------------------|------------------|
/// | `-emoji off` | none                          | none             |
/// | `-emoji mock`| mock                          | mock             |
/// | (no flag)    | mock                          | Atlassian when the setting is on and an account is saved; else none |
///
/// "None" passes no resolver: custom emoji show their `:short-name:` and the
/// library does no lookup work, as before custom emoji had a resolver.
/// "Mock" is `MockEmojiFetch` (`-emojiDelay`), for fixtures, tests and
/// recordings. "Atlassian" is `AtlassianEmojiFetcher.emojiFetch` for the
/// first saved account by site: the demo's Confluence pages come from a
/// static mirror that names no site, and the emoji service needs one (for
/// its cloud ID). A failed Atlassian lookup shows the short name.
@MainActor
enum EmojiResolvers {
    /// A reader's resolver and how About This Build names it.
    struct Choice {
        var resolver: (any ADFEmojiResolver)?
        /// `Off`, `None (short names)`, `Mock · delay 400 ms` or
        /// `Atlassian · <site>`.
        var summary: String
    }

    /// The process's launch flags.
    static let options = MockEmojiOptions()

    /// The shared mock resolver; `nil` under `-emoji off`.
    static let mock: CacheFirstEmojiResolver? = options.mode == .off
        ? nil : CacheFirstEmojiResolver(fetch: MockEmojiFetch.make(options))

    /// The Atlassian resolver of the last site asked for: one fetcher per
    /// account (it caches the cloud ID, emoji by id, the site list and the
    /// read token), one memory cache.
    private static var atlassian: (site: AtlassianSite, choice: Choice)?

    /// The choice a reader starts with, decided without reading the
    /// keychain: final for everything but a Confluence page under no
    /// `-emoji` flag, which starts with none and may upgrade once, before
    /// it loads (`confluenceChoice(accounts:)`).
    static func initialChoice(for source: DocumentSource) -> Choice {
        switch options.mode {
        case .off:
            return Choice(resolver: nil, summary: options.summary)
        case .mock where options.isExplicit:
            return Choice(resolver: mock, summary: options.summary)
        case .mock:
            if case .fixture = source { return Choice(resolver: mock, summary: options.summary) }
            return Choice(resolver: nil, summary: noneSummary)
        }
    }

    /// Whether a reader of `source` asks `confluenceChoice(accounts:)`
    /// before it loads.
    static func usesAtlassianSetting(_ source: DocumentSource) -> Bool {
        guard case .remotePage = source else { return false }
        return options.mode == .mock && !options.isExplicit
    }

    /// The Atlassian resolver for a Confluence page, or `nil` (keep none)
    /// when the setting is off, no account is saved or the keychain read
    /// fails. Reads the account list (non-secret) and, the first time a
    /// site is used, its credential.
    static func confluenceChoice(accounts: AccountStore) -> Choice? {
        guard AtlassianEmojiPreference.isOn() else { return nil }
        if accounts.summaries.isEmpty { accounts.reload() }
        guard let site = accounts.summaries.first?.site else { return nil }
        if let atlassian, atlassian.site == site { return atlassian.choice }
        guard let credential = try? accounts.credential(for: site) else { return nil }
        let fetch = AtlassianEmojiFetcher(credential: credential).emojiFetch
        let resolver = CacheFirstEmojiResolver(fetch: { reference in
            try await fetch(reference.id, reference.shortName)
        })
        let choice = Choice(resolver: resolver, summary: "Atlassian · \(site.host)")
        atlassian = (site, choice)
        return choice
    }

    private static let noneSummary = "None (short names)"
}
