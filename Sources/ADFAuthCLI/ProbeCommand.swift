#if os(macOS)
import ADFAtlassianAuth
import Foundation

/// `adf-auth probe-graphql`: page titles over GraphQL with a saved account.
@MainActor
enum ProbeCommand {
    static let spec = CommandSpec("probe-graphql", options: [
        OptionSpec("--page", value: "id", repeatable: true),
        OptionSpec("--site", value: "site"),
        OptionSpec("--raw"),
        OptionSpec("--gateway", value: "url"),
    ])

    static func run(_ arguments: [String]) async throws -> Int32 {
        let parsed = try ArgumentParser.parse(arguments, for: spec)
        if parsed.helpRequested {
            Terminal.out(Help.probe)
            return ExitCode.success
        }
        var pageIds: [String] = []
        for raw in parsed.values("--page") {
            let id = raw.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, id.utf8.count <= 20, id.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
                throw CLIError.usage("--page needs a numeric page ID, such as 123456.", command: spec.name)
            }
            if !pageIds.contains(id) { pageIds.append(id) }
        }
        guard !pageIds.isEmpty else {
            throw CLIError.usage("give at least one --page <id>.", command: spec.name)
        }
        let explicitSite = try parsed.value("--site").map { site throws(CLIError) in try Context.site(site, command: spec.name) }
        let gateway = try Context.gateway(parsed, command: spec.name)
        let raw = parsed.has("--raw")

        let store = try Context.store()
        let summary = try Context.savedSite(explicit: explicitSite, store: store, command: spec.name)
        let site = summary.site
        guard let credential = try Context.keychain({ try store.load(site: site) }) else {
            throw CLIError.failure("No saved account for \(site.host). Run: adf-auth login --site \(site.host)")
        }
        let client = AtlassianGraphQLClient(credential: credential, endpoint: gateway)

        let result: PageProbeResult
        let cloudId: String
        do {
            if let stored = credential.cloudId {
                cloudId = stored
            } else {
                cloudId = try await client.checkToken().cloudId
            }
            result = try await client.probePages(pageIds: pageIds, cloudId: cloudId)
        } catch {
            if case .scopedTokenRejected = error {
                Terminal.err(error.message)
                return ExitCode.scopedTokenRejected
            }
            throw CLIError.failure(error.message)
        }

        if raw {
            Terminal.out(result.rawJSON)
            return ExitCode.success
        }

        Terminal.out("\(site.host) (cloudId \(cloudId)): \(result.pages.count) of \(pageIds.count) page\(pageIds.count == 1 ? "" : "s") returned")
        for pageId in pageIds {
            Terminal.out()
            Terminal.out("Page \(pageId)")
            guard let page = result.pages.first(where: { $0.pageId == pageId }) else {
                Terminal.out("  not returned (it doesn't exist, or this token can't see it)")
                continue
            }
            let space: String
            switch (page.spaceKey, page.spaceName) {
            case let (key?, name?): space = "\(key) (\(name))"
            case let (key?, nil): space = key
            case let (nil, name?): space = name
            case (nil, nil): space = "(none)"
            }
            let emoji: String
            if let value = page.emoji {
                emoji = value
            } else if result.emojiNeedsMetadataScope {
                emoji = "not available: \(PageProbeResult.metadataScopeNote)"
            } else {
                emoji = "(none)"
            }
            var rows = [
                ["  Title:", page.title.map(Terminal.sanitize) ?? "(none)"],
                ["  Space:", Terminal.sanitize(space)],
                ["  Emoji:", Terminal.sanitize(emoji)],
            ]
            if let url = page.webURL { rows.append(["  Link:", Terminal.sanitize(url.absoluteString)]) }
            Format.table(rows).forEach { Terminal.out($0) }
        }
        if !result.errorMessages.isEmpty {
            Terminal.out()
            Terminal.out("GraphQL errors (verbatim):")
            for message in result.errorMessages {
                Terminal.out("  - \(Terminal.sanitize(message))")
            }
        }
        return ExitCode.success
    }
}
#endif
