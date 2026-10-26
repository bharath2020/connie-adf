import CryptoKit
import SwiftUI
import ADFRendering

/// "About This Build": version/build, the SHA-256 of the running executable,
/// the active text renderer and how many TextKit 2 rows are alive (the
/// renderer proof: > 0 while TextKit 2 draws rows on screen, 0 after a
/// switch back to SwiftUI), of which how many are TextKit 1-backed (linked
/// text, laid out and drawn by a TextKit 1 stack inside the row). The checksum lets a screen recording be
/// tied to one exact binary — `Scripts/e2e-video.sh` compares what the test
/// saw on screen against the `.app` it built and the one it installed.
struct BuildInfoView: View {
    let renderer: ADFTextRenderer

    @Environment(\.dismiss) private var dismiss
    @State private var executableSHA256: String?
    @State private var checksumUnavailable = false
    /// Polled from the diagnostics counter while the sheet is open — never
    /// bound to row visibility, so reading it cannot feed back into layout.
    /// `nil` until the first read, shown as "…" so a UI test never mistakes
    /// the placeholder for a count.
    @State private var liveTextKit2Rows: Int?
    @State private var liveTextKit1BackedRows: Int?

    var body: some View {
        NavigationStack {
            List {
                Section("Version") {
                    Text(BuildIdentity.versionString)
                        .accessibilityIdentifier("build-version")
                }
                Section("Text Renderer") {
                    Text(renderer.displayName)
                        .accessibilityIdentifier("build-renderer")
                }
                Section("Live TextKit 2 Rows") {
                    Text(liveTextKit2Rows.map(String.init) ?? "…")
                        .monospacedDigit()
                        .accessibilityIdentifier("tk2-live-rows")
                }
                Section("Of Which TextKit 1-Backed (Links)") {
                    Text(liveTextKit1BackedRows.map(String.init) ?? "…")
                        .monospacedDigit()
                        .accessibilityIdentifier("tk1-backed-rows")
                }
                if let blocks = LoadSwitchProbe.blocksAtSwitch {
                    Section("Switched During Load (Blocks Loaded)") {
                        Text(verbatim: String(blocks))
                            .monospacedDigit()
                            .accessibilityIdentifier("load-switch-blocks")
                    }
                }
                if let blocks = LoadSwitchProbe.blocksAtReady {
                    Section("Ready After the Switch (Blocks Loaded)") {
                        Text(verbatim: String(blocks))
                            .monospacedDigit()
                            .accessibilityIdentifier("load-ready-blocks")
                    }
                }
                Section {
                    checksumRow
                } header: {
                    Text("Executable SHA-256")
                } footer: {
                    Text(BuildIdentity.executableDescription)
                }
            }
            .navigationTitle("About This Build")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("build-info-done")
                }
            }
            .task {
                if let sha = await BuildIdentity.executableSHA256() {
                    executableSHA256 = sha
                } else {
                    checksumUnavailable = true
                }
            }
            .task {
                while !Task.isCancelled {
                    let stats = ADFTextRenderer.textKit2Stats
                    liveTextKit2Rows = stats.liveRowCount
                    liveTextKit1BackedRows = stats.textKit1BackedRowCount
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    @ViewBuilder
    private var checksumRow: some View {
        if let executableSHA256 {
            Text(executableSHA256)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("build-sha256")
        } else if checksumUnavailable {
            Text("Unavailable")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("build-sha256-unavailable")
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Computing…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("build-sha256-pending")
        }
    }
}

/// Identity of the running binary. The checksum is computed once per process,
/// off the main thread, the first time it is requested — the executable is a
/// few megabytes, which is too much to hash during a sheet presentation.
enum BuildIdentity {
    /// `CFBundleShortVersionString (CFBundleVersion)`, e.g. `1.0 (18)`.
    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var executableDescription: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown bundle"
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "unknown executable"
        return "\(bundleID) · \(executable)"
    }

    /// Lowercase hex SHA-256 of `Bundle.main.executableURL`, or `nil` when
    /// the file cannot be read. Matches a simulator or development install
    /// of the built binary; App Store Connect re-signs TestFlight builds, so
    /// there the digest differs from the local archive's.
    static func executableSHA256() async -> String? {
        await checksumTask.value
    }

    private static let checksumTask: Task<String?, Never> = {
        let url = Bundle.main.executableURL
        return Task.detached(priority: .utility) {
            guard let url else { return nil }
            return try? sha256Hex(ofFileAt: url)
        }
    }()

    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
