import CryptoKit
import SwiftUI
import ADFRendering

/// "About This Build": version/build, the SHA-256 of the running executable,
/// and the active text renderer. The checksum lets a screen recording be
/// tied to one exact binary — `Scripts/e2e-video.sh` compares what the test
/// saw on screen against the `.app` it built and the one it installed.
struct BuildInfoView: View {
    let renderer: ADFTextRenderer

    @Environment(\.dismiss) private var dismiss
    @State private var executableSHA256: String?
    @State private var checksumUnavailable = false

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
    /// the file cannot be read.
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
