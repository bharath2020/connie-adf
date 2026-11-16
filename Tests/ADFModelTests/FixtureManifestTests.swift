import CryptoKit
import Foundation
import Testing

/// `Fixtures/SHA256SUMS` makes "never modify an earlier fixture's bytes"
/// executable.
///
/// The manifest is in `shasum -a 256` format, one `<64 hex digits>  <file
/// name>` line per `Fixtures/*.json`; lines starting with `#` are comments
/// (`shasum -c` skips them too). The line `# PR 4` splits it: every byte
/// above it is the ancestor block, the fixtures as they were at main
/// `be500c8`, and its sha256 is pinned below, so no inherited line can
/// change. PR 4's own fixtures are listed below that line; a draft
/// fixture's line is rewritten with its new digest (`shasum -a 256
/// <name>.json` in `Fixtures/`) whenever its bytes change, until the
/// fixture freeze. `swift Tools/make-fixtures.swift --check` is the
/// generator-side half: it regenerates every generated fixture in memory
/// and fails on any difference.
@Suite("Fixture manifest")
struct FixtureManifestTests {
    /// sha256 of the manifest's bytes from its start through the newline
    /// that ends the line before `# PR 4`: the header comment and the 16
    /// lines of main `be500c8`'s fixtures. Never change this value to
    /// absorb an edit: restore the ancestor block (and its fixtures)
    /// instead.
    static let pinnedAncestorBlockSHA256 = "8d99667bfb4ca10204c8f883c3fa278c9a61a7b9f04b2824db96cab6b8e1d7a9"

    /// The line that ends the ancestor block.
    static let boundaryLine = "# PR 4"

    /// The repository's `Fixtures/` directory, resolved from this source
    /// file as `fixtureData` does, so the test reads the checkout itself.
    static var fixturesDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // …/Tests/ADFModelTests
        url.deleteLastPathComponent() // …/Tests
        url.deleteLastPathComponent() // repo root
        return url.appendingPathComponent("Fixtures")
    }

    struct Entry: Equatable {
        let digest: String
        let name: String
    }

    static func manifestData() throws -> Data {
        try Data(contentsOf: fixturesDirectory.appendingPathComponent("SHA256SUMS"))
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let digits = String(byte, radix: 16)
            return byte < 16 ? "0" + digits : digits
        }.joined()
    }

    /// The manifest's entries in file order, or a failure message for the
    /// first line that is neither a comment nor a well-formed entry.
    static func entries(of text: String) -> (entries: [Entry], problems: [String]) {
        var entries: [Entry] = []
        var problems: [String] = []
        let hexDigits = Set("0123456789abcdef")
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "  ")
            guard parts.count == 2,
                  parts[0].count == 64, parts[0].allSatisfy({ hexDigits.contains($0) }),
                  parts[1].hasSuffix(".json"), !parts[1].contains("/"),
                  !parts[1].contains(" ") else {
                problems.append("line \(offset + 1) is not '<64 lower-case hex>  <name>.json': \(line)")
                continue
            }
            entries.append(Entry(digest: parts[0], name: parts[1]))
        }
        return (entries, problems)
    }

    @Test("the manifest lists exactly the fixture JSON files, each with its sha256")
    func manifestMatchesDirectory() throws {
        let data = try Self.manifestData()
        let text = try #require(String(data: data, encoding: .utf8), "SHA256SUMS is not UTF-8")
        #expect(text.hasSuffix("\n"), "SHA256SUMS must end with a newline")

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.filter { $0 == Self.boundaryLine }.count == 1,
                "SHA256SUMS must hold the line '\(Self.boundaryLine)' exactly once")

        let parsed = Self.entries(of: text)
        #expect(parsed.problems.isEmpty, "\(parsed.problems)")

        let names = parsed.entries.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(duplicates.isEmpty, "listed more than once: \(duplicates)")

        let onDisk = try FileManager.default.contentsOfDirectory(atPath: Self.fixturesDirectory.path)
            .filter { $0.hasSuffix(".json") }
        let unlisted = Set(onDisk).subtracting(names).sorted()
        let missing = Set(names).subtracting(onDisk).sorted()
        #expect(unlisted.isEmpty, "Fixtures/ holds JSON the manifest does not list: \(unlisted)")
        #expect(missing.isEmpty, "the manifest lists files Fixtures/ does not hold: \(missing)")

        for entry in parsed.entries where !missing.contains(entry.name) {
            let bytes = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent(entry.name))
            #expect(Self.hex(bytes) == entry.digest, "\(entry.name): its bytes no longer match SHA256SUMS")
        }
    }

    @Test("the ancestor block above '# PR 4' is pinned")
    func ancestorBlockIsPinned() throws {
        let data = try Self.manifestData()
        let boundary = Data((Self.boundaryLine + "\n").utf8)
        // The boundary must start a line: at the very start, or after "\n".
        var searchFrom = data.startIndex
        var blockEnd: Int?
        while let range = data.range(of: boundary, in: searchFrom ..< data.endIndex) {
            if range.lowerBound == data.startIndex || data[range.lowerBound - 1] == UInt8(ascii: "\n") {
                blockEnd = range.lowerBound
                break
            }
            searchFrom = range.upperBound
        }
        let end = try #require(blockEnd, "SHA256SUMS has no line '\(Self.boundaryLine)'")
        let block = data[data.startIndex ..< end]
        #expect(Self.hex(Data(block)) == Self.pinnedAncestorBlockSHA256,
                "the manifest above '\(Self.boundaryLine)' changed: an inherited fixture line was edited")

        // The pinned block itself lists the 16 fixtures of be500c8.
        let text = try #require(String(data: Data(block), encoding: .utf8))
        let parsed = Self.entries(of: text)
        #expect(parsed.problems.isEmpty, "\(parsed.problems)")
        #expect(parsed.entries.count == 16)
    }
}
