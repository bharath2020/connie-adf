import Foundation

/// Loads a fixture from the repo-root `Fixtures/` directory.
///
/// Resolves relative to this source file (`#filePath`), so fixtures are read
/// straight from the repository without SPM resource bundling.
func fixtureData(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent() // …/Tests/ADFPreparationTests
    url.deleteLastPathComponent() // …/Tests
    url.deleteLastPathComponent() // repo root
    url.appendPathComponent("Fixtures")
    url.appendPathComponent(name)
    return try Data(contentsOf: url)
}
