# Confluence Remote Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host the exported `ADFTB` Confluence space as a static Confluence-shaped JSON bundle on Cloudflare Pages, and let ADFReader browse it as a read-only Confluence client (Space → page tree → page).

**Architecture:** A one-time browser-session export writes `cloudflare/public/api/v2/**` static files. A new SPM library `ADFConfluence` holds the models, page-tree builder, and an HTTP client (all `swift test`-covered). The Demo app adds Space/PageTree navigation and refactors `ReaderView` to load from a `DocumentSource` (local fixture or remote page), reusing the existing renderer untouched.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, URLSession, Cloudflare Pages + `wrangler`, Confluence REST v2 (export only).

## Global Constraints

- Swift tools 6.0; targets iOS 17 / macOS 14 (from `Package.swift`).
- Demo app build settings: `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` (`Demo/project.yml`). All new code must be warning-clean and concurrency-correct.
- Hosted content is public/no-auth (fictional test data).
- ADF body is a JSON-encoded **string** in `body.atlas_doc_format.value`, exactly as Confluence returns it.
- Real Confluence ids are used verbatim; the app hardcodes no ids. Space `ADFTB` id is `15171586`.
- The renderer (`ADFDocumentModel`, `ADFDocumentView`, `ADFParser`) is not modified.

---

### Task 1: Export the ADFTB space to a static Confluence-shaped bundle

**Execution note:** This task must run in the session that holds the authenticated Confluence browser session (Playwright). It generates data; there is no TDD cycle, but Step 4 validates every page through `ADFModel`.

**Files:**
- Create: `cloudflare/public/api/v2/spaces.json`
- Create: `cloudflare/public/api/v2/spaces/15171586/pages.json`
- Create: `cloudflare/public/api/v2/pages/<pageId>.json` (one per page, ~51 files)
- Create: `cloudflare/public/_headers`
- Create: `cloudflare/README.md`

**Interfaces:**
- Produces: the static bundle consumed by Task 3's client and Task 6's deploy. File shapes are fixed by the spec's "Cloudflare bundle layout" section.

- [ ] **Step 1: Fetch space + flat page list in the browser session**

In the authenticated tab, run (via `browser_evaluate`):
```js
async () => {
  const SID = '15171586';
  const space = await fetch('/wiki/api/v2/spaces/'+SID, {headers:{Accept:'application/json'}}).then(r=>r.json());
  let pages = [], cur = '/wiki/api/v2/spaces/'+SID+'/pages?limit=100';
  while (cur) {
    const j = await fetch(cur, {headers:{Accept:'application/json'}}).then(r=>r.json());
    pages = pages.concat((j.results||[]).map((p,i)=>({id:p.id,title:p.title,parentId:p.parentId||null,spaceId:SID})));
    cur = (j._links && j._links.next) ? j._links.next : null;
  }
  window.__space = {id:space.id, key:space.key, name:space.name};
  window.__pages = pages.map((p,i)=>({...p, position:i}));
  return {space:window.__space, pageCount:window.__pages.length};
}
```
Expected: `pageCount` = 51.

- [ ] **Step 2: Write `spaces.json` and `spaces/<id>/pages.json`**

Read `window.__space` / `window.__pages` back (small), then write with the file tools:
- `cloudflare/public/api/v2/spaces.json`:
```json
{ "results": [ { "id": "15171586", "key": "ADFTB", "name": "ADFReader Test Bed" } ] }
```
- `cloudflare/public/api/v2/spaces/15171586/pages.json`:
```json
{ "results": [ { "id": "...", "title": "...", "parentId": "..."|null, "spaceId": "15171586", "position": 0 }, ... ] }
```

- [ ] **Step 3: Fetch each page's ADF body and write `pages/<id>.json`**

In batches of ~12 ids, run:
```js
async (ids) => {
  const out = {};
  for (const id of ids) {
    const p = await fetch('/wiki/api/v2/pages/'+id+'?body-format=atlas_doc_format',
      {headers:{Accept:'application/json'}}).then(r=>r.json());
    out[id] = { id:p.id, title:p.title, spaceId:p.spaceId, parentId:p.parentId||null,
      body:{ atlas_doc_format:{ value:p.body.atlas_doc_format.value, representation:'atlas_doc_format' } } };
  }
  return out;
}
```
Write each returned object to `cloudflare/public/api/v2/pages/<id>.json`.

- [ ] **Step 4: Validate every page parses via ADFModel**

Create `cloudflare/validate.swift` (throwaway, run with `swift`):
```swift
import Foundation
// Minimal check: every pages/*.json decodes, body.value is non-empty valid ADF JSON with type "doc".
let dir = URL(fileURLWithPath: "cloudflare/public/api/v2/pages")
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
var bad = 0
for f in files {
    let j = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String:Any]
    let value = ((j["body"] as! [String:Any])["atlas_doc_format"] as! [String:Any])["value"] as! String
    let adf = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String:Any]
    if adf["type"] as? String != "doc" { bad += 1; print("BAD", f.lastPathComponent) }
}
print("checked \(files.count) pages, \(bad) bad")
```
Run: `swift cloudflare/validate.swift`
Expected: `checked 51 pages, 0 bad`. Then delete `cloudflare/validate.swift`.

- [ ] **Step 5: Write `_headers` and README**

`cloudflare/public/_headers`:
```
/api/*
  Content-Type: application/json
  Access-Control-Allow-Origin: *
  Cache-Control: public, max-age=300
```
`cloudflare/README.md`: document the layout, the export procedure (Steps 1–4), and the deploy command from Task 6.

- [ ] **Step 6: Commit**

```bash
git add cloudflare
git commit -m "feat: static Confluence-shaped bundle for ADFTB space (Cloudflare)"
```

---

### Task 2: Add the `ADFConfluence` package target and models

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ADFConfluence/ConfluenceModels.swift`
- Create: `Tests/ADFConfluenceTests/ConfluenceModelsTests.swift`

**Interfaces:**
- Produces:
  - `struct Space: Decodable, Identifiable, Sendable { let id: String; let key: String; let name: String }`
  - `struct PageSummary: Decodable, Identifiable, Sendable { let id: String; let title: String; let parentId: String?; let position: Int }`
  - `struct PageNode: Identifiable, Sendable { let id: String; let title: String; var children: [PageNode] }`
  - `enum PageTree { static func build(from summaries: [PageSummary]) -> [PageNode] }` — roots are `parentId == nil`, each level sorted by `(position, title)`.

- [ ] **Step 1: Add the target to `Package.swift`**

In `targets:` add:
```swift
.target(name: "ADFConfluence", dependencies: ["ADFModel"]),
.testTarget(name: "ADFConfluenceTests", dependencies: ["ADFConfluence", "ADFModel"]),
```
And add `"ADFConfluence"` to the `ADFKit` product's `targets` array so the Demo app can import it:
```swift
.library(name: "ADFKit", targets: ["ADFModel", "ADFPreparation", "ADFRendering", "ADFConfluence"]),
```

- [ ] **Step 2: Write the failing test**

`Tests/ADFConfluenceTests/ConfluenceModelsTests.swift`:
```swift
import Testing
@testable import ADFConfluence

@Suite("Confluence models")
struct ConfluenceModelsTests {
    @Test("decodes a spaces payload")
    func decodesSpaces() throws {
        let json = #"{ "results": [ { "id": "1", "key": "ADFTB", "name": "Test Bed" } ] }"#
        let wrap = try JSONDecoder().decode(ResultsEnvelope<Space>.self, from: Data(json.utf8))
        #expect(wrap.results.count == 1)
        #expect(wrap.results[0].key == "ADFTB")
    }

    @Test("builds an ordered parent/child tree")
    func buildsTree() {
        let s = [
            PageSummary(id: "a", title: "Root A", parentId: nil, position: 1),
            PageSummary(id: "b", title: "Root B", parentId: nil, position: 0),
            PageSummary(id: "b1", title: "Child B1", parentId: "b", position: 0),
        ]
        let roots = PageTree.build(from: s)
        #expect(roots.map(\.id) == ["b", "a"])            // sorted by position
        #expect(roots[0].children.map(\.id) == ["b1"])    // child nested under b
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ConfluenceModels`
Expected: FAIL — `ADFConfluence`/`ResultsEnvelope`/`PageTree` not found.

- [ ] **Step 4: Write the models**

`Sources/ADFConfluence/ConfluenceModels.swift`:
```swift
import Foundation

public struct ResultsEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let results: [T]
}

public struct Space: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let key: String
    public let name: String
}

public struct PageSummary: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let parentId: String?
    public let position: Int
    public init(id: String, title: String, parentId: String?, position: Int) {
        self.id = id; self.title = title; self.parentId = parentId; self.position = position
    }
}

public struct PageNode: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public var children: [PageNode]
}

public enum PageTree {
    /// Build root-level nodes from a flat list. Roots have `parentId == nil`;
    /// each sibling level is ordered by `(position, title)`.
    public static func build(from summaries: [PageSummary]) -> [PageNode] {
        var childrenByParent: [String: [PageSummary]] = [:]
        var roots: [PageSummary] = []
        for s in summaries {
            if let p = s.parentId { childrenByParent[p, default: []].append(s) }
            else { roots.append(s) }
        }
        func node(_ s: PageSummary) -> PageNode {
            let kids = (childrenByParent[s.id] ?? []).sorted(by: ordered).map(node)
            return PageNode(id: s.id, title: s.title, children: kids)
        }
        return roots.sorted(by: ordered).map(node)
    }
    private static func ordered(_ a: PageSummary, _ b: PageSummary) -> Bool {
        a.position != b.position ? a.position < b.position : a.title < b.title
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ConfluenceModels`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ADFConfluence Tests/ADFConfluenceTests
git commit -m "feat: ADFConfluence models and page-tree builder"
```

---

### Task 3: Add the `ConfluenceClient` HTTP client

**Files:**
- Create: `Sources/ADFConfluence/ConfluenceClient.swift`
- Create: `Tests/ADFConfluenceTests/ConfluenceClientTests.swift`

**Interfaces:**
- Consumes: `Space`, `PageSummary`, `ResultsEnvelope`, `PageTree` (Task 2).
- Produces:
  - `struct RemotePage: Sendable { let id: String; let title: String; let adf: Data }`
  - `protocol ConfluenceClient: Sendable { func spaces() async throws -> [Space]; func pages(inSpace id: String) async throws -> [PageSummary]; func page(id: String) async throws -> RemotePage }`
  - `struct HTTPConfluenceClient: ConfluenceClient { init(baseURL: URL, session: URLSession = .shared) }`

- [ ] **Step 1: Write the failing test (URLProtocol stub)**

`Tests/ADFConfluenceTests/ConfluenceClientTests.swift`:
```swift
import Foundation
import Testing
@testable import ADFConfluence

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: String] = [:]   // path -> JSON body
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let path = request.url!.path
        let body = Self.routes[path] ?? "{}"
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.routes[path] == nil ? 404 : 200,
                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedClient() -> HTTPConfluenceClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return HTTPConfluenceClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: cfg))
}

@Suite("Confluence client")
struct ConfluenceClientTests {
    @Test("fetches and decodes a page's ADF")
    func fetchesPage() async throws {
        let adf = #"{"version":1,"type":"doc","content":[]}"#
        let page = "{\"id\":\"7\",\"title\":\"Hello\",\"spaceId\":\"1\",\"parentId\":null,\"body\":{\"atlas_doc_format\":{\"value\":\(String(reflecting: adf)),\"representation\":\"atlas_doc_format\"}}}"
        StubProtocol.routes = ["/api/v2/pages/7.json": page]
        let p = try await stubbedClient().page(id: "7")
        #expect(p.title == "Hello")
        let obj = try JSONSerialization.jsonObject(with: p.adf) as! [String: Any]
        #expect(obj["type"] as? String == "doc")
    }

    @Test("lists spaces")
    func listsSpaces() async throws {
        StubProtocol.routes = ["/api/v2/spaces.json": #"{"results":[{"id":"1","key":"ADFTB","name":"Test Bed"}]}"#]
        let spaces = try await stubbedClient().spaces()
        #expect(spaces.map(\.key) == ["ADFTB"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfluenceClient`
Expected: FAIL — `HTTPConfluenceClient` / `RemotePage` not found.

- [ ] **Step 3: Write the client**

`Sources/ADFConfluence/ConfluenceClient.swift`:
```swift
import Foundation

public struct RemotePage: Sendable {
    public let id: String
    public let title: String
    public let adf: Data
}

public protocol ConfluenceClient: Sendable {
    func spaces() async throws -> [Space]
    func pages(inSpace id: String) async throws -> [PageSummary]
    func page(id: String) async throws -> RemotePage
}

public struct HTTPConfluenceClient: ConfluenceClient {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func spaces() async throws -> [Space] {
        try await get("api/v2/spaces.json", as: ResultsEnvelope<Space>.self).results
    }

    public func pages(inSpace id: String) async throws -> [PageSummary] {
        try await get("api/v2/spaces/\(id)/pages.json", as: ResultsEnvelope<PageSummary>.self).results
    }

    public func page(id: String) async throws -> RemotePage {
        let dto = try await get("api/v2/pages/\(id).json", as: PageDTO.self)
        return RemotePage(id: dto.id, title: dto.title,
                          adf: Data(dto.body.atlas_doc_format.value.utf8))
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let url = baseURL.appending(path: path)
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConfluenceError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, url)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct PageDTO: Decodable {
        struct Body: Decodable { let atlas_doc_format: ADFBody }
        struct ADFBody: Decodable { let value: String }
        let id: String; let title: String; let body: Body
    }
}

public enum ConfluenceError: Error, Sendable {
    case http(Int, URL)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConfluenceClient`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all suites pass (existing + new ADFConfluence).

- [ ] **Step 6: Commit**

```bash
git add Sources/ADFConfluence/ConfluenceClient.swift Tests/ADFConfluenceTests/ConfluenceClientTests.swift
git commit -m "feat: HTTP Confluence client over the static bundle"
```

---

### Task 4: App config and the `DocumentSource` reader refactor

**Files:**
- Create: `Demo/ADFReader/AppConfig.swift`
- Create: `Demo/ADFReader/DocumentSource.swift`
- Modify: `Demo/ADFReader/ReaderView.swift`
- Modify: `Demo/project.yml` (no dependency change needed — `ADFKit` product now includes `ADFConfluence`; regenerate project)

**Interfaces:**
- Consumes: `HTTPConfluenceClient`, `RemotePage` (Task 3).
- Produces:
  - `enum AppConfig { static let confluenceBaseURL: URL }`
  - `enum DocumentSource: Hashable { case fixture(Fixture); case remotePage(id: String, title: String) }` with `var title: String` and `func loadData() async throws -> Data`.
  - `ReaderView(source: DocumentSource, options: LaunchOptions)`.

- [ ] **Step 1: Add `AppConfig`**

`Demo/ADFReader/AppConfig.swift`:
```swift
import Foundation

enum AppConfig {
    /// Base URL of the Cloudflare-hosted static Confluence bundle.
    /// Set to the deployed *.pages.dev URL in Task 6.
    static let confluenceBaseURL = URL(string: "https://adfreader-confluence.pages.dev")!
}
```

- [ ] **Step 2: Add `DocumentSource`**

`Demo/ADFReader/DocumentSource.swift`:
```swift
import Foundation
import ADFConfluence

enum DocumentSource: Hashable {
    case fixture(Fixture)
    case remotePage(id: String, title: String)

    var title: String {
        switch self {
        case .fixture(let f): return f.name
        case .remotePage(_, let title): return title
        }
    }

    func loadData() async throws -> Data {
        switch self {
        case .fixture(let f):
            return try Data(contentsOf: f.url)
        case .remotePage(let id, _):
            let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)
            return try await client.page(id: id).adf
        }
    }
}
```

- [ ] **Step 3: Refactor `ReaderView` to take a `DocumentSource`**

In `Demo/ADFReader/ReaderView.swift`:
- Change the stored `let fixture: Fixture` to `let source: DocumentSource` and update `init`.
- Change `.navigationTitle(fixture.name)` → `.navigationTitle(source.title)`.
- Replace the file-load in `load()` with an async load from the source. The current `load()` synchronously reads `Data(contentsOf: fixture.url)` and calls `model.load(data:)`. Change it to load from the source off the main actor, then set `loadStart` and call the (existing, synchronous) `model.load(data:)`:
```swift
private func load() {
    Task {
        do {
            let data = try await source.loadData()
            loadStart = ContinuousClock.now
            model.load(data: data)
        } catch {
            loadFailure = String(describing: error)
        }
    }
}
```
`ADFDocumentModel.load(data:)` already exists (`Sources/ADFRendering/ADFDocumentModel.swift:62`); no model change is needed. Keep the READY-line / `-scrollToFraction` / `-autoscroll` automation intact — it keys off `model.phase`, not the source.

- [ ] **Step 4: Update call sites and app entry**

In `Demo/ADFReader/ADFReaderApp.swift`, the `-fixture` branch becomes:
```swift
ReaderView(source: .fixture(fixture), options: options)
```

- [ ] **Step 5: Build the app**

Run:
```bash
cd Demo && xcodegen generate && \
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Demo/ADFReader/AppConfig.swift Demo/ADFReader/DocumentSource.swift Demo/ADFReader/ReaderView.swift Demo/ADFReader/ADFReaderApp.swift
git commit -m "feat: ReaderView loads from DocumentSource (local or remote)"
```

---

### Task 5: Space list and page-tree navigation

**Files:**
- Create: `Demo/ADFReader/SpaceListView.swift`
- Create: `Demo/ADFReader/PageTreeView.swift`
- Modify: `Demo/ADFReader/ADFReaderApp.swift` (root → `SpaceListView`)
- Modify: `Demo/ADFReader/FixtureListView.swift` (keep `Fixture`; the list UI moves into `SpaceListView`'s Local section)

**Interfaces:**
- Consumes: `Space`, `PageSummary`, `PageNode`, `PageTree`, `HTTPConfluenceClient` (Tasks 2–3); `DocumentSource`, `ReaderView` (Task 4).
- Produces: `SpaceListView` (new root), `PageTreeView(space:)`.

- [ ] **Step 1: `PageTreeView` — load pages, build tree, navigate**

`Demo/ADFReader/PageTreeView.swift`:
```swift
import SwiftUI
import ADFConfluence

struct PageTreeView: View {
    let space: Space
    @State private var roots: [PageNode] = []
    @State private var failure: String?

    private let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)

    var body: some View {
        List {
            if let failure {
                ContentUnavailableView("Couldn't Load Pages", systemImage: "wifi.slash", description: Text(failure))
            } else {
                OutlineGroup(roots, children: \.optionalChildren) { node in
                    NavigationLink(value: DocumentSource.remotePage(id: node.id, title: node.title)) {
                        Label(node.title, systemImage: "doc.text")
                    }
                }
            }
        }
        .navigationTitle(space.name)
        .task { await load() }
    }

    private func load() async {
        do { roots = PageTree.build(from: try await client.pages(inSpace: space.id)) }
        catch { failure = error.localizedDescription }
    }
}

private extension PageNode {
    /// `OutlineGroup` needs `nil` (not `[]`) for leaves to hide the chevron.
    var optionalChildren: [PageNode]? { children.isEmpty ? nil : children }
}
```

- [ ] **Step 2: `SpaceListView` — remote spaces + Local section**

`Demo/ADFReader/SpaceListView.swift`:
```swift
import SwiftUI
import ADFConfluence

struct SpaceListView: View {
    @State private var spaces: [Space] = []
    @State private var failure: String?
    private let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)
    private let fixtures = Fixture.all

    var body: some View {
        List {
            Section("Spaces") {
                if let failure {
                    ContentUnavailableView("Spaces Unavailable", systemImage: "wifi.slash", description: Text(failure))
                } else {
                    ForEach(spaces) { space in
                        NavigationLink(value: space) {
                            Label(space.name, systemImage: "square.grid.2x2")
                        }
                    }
                }
            }
            Section("Local") {
                NavigationLink { ScanView() } label: { Label("Scan", systemImage: "qrcode.viewfinder") }
                ForEach(fixtures) { fixture in
                    NavigationLink(value: DocumentSource.fixture(fixture)) {
                        Text(fixture.name)
                    }
                }
            }
        }
        .navigationTitle("Confluence")
        .task { await loadSpaces() }
        .navigationDestination(for: Space.self) { PageTreeView(space: $0) }
        .navigationDestination(for: DocumentSource.self) { ReaderView(source: $0, options: .none) }
    }

    private func loadSpaces() async {
        do { spaces = try await client.spaces() }
        catch { failure = error.localizedDescription }
    }
}
```

- [ ] **Step 3: Make root `SpaceListView`; trim `FixtureListView`**

In `ADFReaderApp.swift`, replace `FixtureListView()` in the `else` branch with `SpaceListView()`. Remove `FixtureListView`'s now-duplicated list body (keep the `Fixture` struct — `SpaceListView` and `DocumentSource` use it). Delete `FixtureListView` the view if unused, or leave the `Fixture` type in a renamed `Fixture.swift`; simplest: move the `Fixture` struct into `DocumentSource.swift`'s file or a new `Fixture.swift` and delete `FixtureListView.swift`.

- [ ] **Step 4: Build**

Run:
```bash
cd Demo && xcodegen generate && \
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Demo/ADFReader
git commit -m "feat: Space list + page-tree navigation (Confluence-style)"
```

---

### Task 6: Deploy to Cloudflare Pages and wire the URL; verify end-to-end

**Files:**
- Modify: `Demo/ADFReader/AppConfig.swift` (real deployed URL)

**Interfaces:** none produced; this is integration + verification.

- [ ] **Step 1: User deploys the bundle**

Ask the user to run (uses their Cloudflare login):
```
! wrangler pages deploy cloudflare/public --project-name adfreader-confluence
```
Capture the printed `https://<...>.pages.dev` URL.

- [ ] **Step 2: Smoke-test the hosted endpoints**

Run:
```bash
curl -s https://<deployed>.pages.dev/api/v2/spaces.json | head -c 200
curl -s https://<deployed>.pages.dev/api/v2/spaces/15171586/pages.json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["results"]),"pages")'
```
Expected: spaces JSON prints; page count matches the export (~50).

- [ ] **Step 3: Wire the URL into `AppConfig`**

Set `confluenceBaseURL` to the deployed URL. Commit:
```bash
git add Demo/ADFReader/AppConfig.swift
git commit -m "chore: point AppConfig at deployed Cloudflare Pages URL"
```

- [ ] **Step 4: Run the app and verify the flow**

Boot a simulator, install, and launch (per the repo's run patterns). Verify: root shows **Spaces** (ADFReader Test Bed) + **Local**; tapping the space shows the expandable page tree; tapping a page renders its ADF; Local fixtures and Scan still work. Use the `/run` or `/verify` skill to drive and screenshot.

- [ ] **Step 5: Final full test run**

Run: `swift test`
Expected: all suites pass.

---

## Self-Review

- **Spec coverage:** export tool (Task 1), bundle layout + `_headers` (Task 1), models/tree (Task 2), client (Task 3), `DocumentSource` refactor + config (Task 4), Space/PageTree UI + Local section (Task 5), deploy + wire URL + verify (Task 6). Error handling appears in the client (`ConfluenceError`) and every view's failure state. Testing: model/tree/client unit tests + export validation + end-to-end run. All spec sections mapped.
- **Placeholder scan:** none — every code step is complete. The one runtime value filled later (deployed URL) is explicitly Task 6.
- **Type consistency:** `Space`, `PageSummary`, `PageNode`, `PageTree.build`, `ResultsEnvelope`, `RemotePage`, `ConfluenceClient`/`HTTPConfluenceClient`, `DocumentSource`, `ReaderView(source:options:)` are used identically across tasks.
- **Verified against code:** `ADFDocumentModel.load(data:)` already exists (`Sources/ADFRendering/ADFDocumentModel.swift:62`), so Task 4 needs no model change.
