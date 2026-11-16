#if os(macOS)
import AppKit
import Darwin
import Foundation

/// Terminal input and output: unbuffered writes, line prompts, the hidden
/// token prompt, the clipboard check and opening URLs.
///
/// Prompts go to stderr so stdout stays clean for piping. Lines are read
/// from stdin byte by byte with `read(2)`, so nothing past the line is
/// buffered (a piped token or answer is never swallowed by an earlier
/// prompt).
enum Terminal {
    // MARK: Output

    static func out(_ text: String = "") { write(text + "\n", to: STDOUT_FILENO) }
    static func err(_ text: String) { write(text + "\n", to: STDERR_FILENO) }

    static func write(_ text: String, to descriptor: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Replaces control characters (ESC, CR, …) in text that came from a
    /// server, so a page title can't drive the terminal.
    static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "\u{FFFD}" : scalar
        }))
    }

    // MARK: Input

    static var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    /// One line from stdin without the line break; nil at end of input.
    /// Blocks the calling thread.
    static func readLine() -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            bytes.append(byte)
            if bytes.count >= 64 * 1024 { break }
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// Writes `text` to stderr and reads one line.
    static func prompt(_ text: String) -> String? {
        write(text, to: STDERR_FILENO)
        let answer = readLine()
        echoIfPiped(answer)
        return answer
    }

    /// When stdin is a pipe the answer isn't echoed by a terminal; echo it so
    /// logs read naturally. Never used for the token.
    static func echoIfPiped(_ answer: String?) {
        guard !stdinIsTerminal else { return }
        write((answer ?? "(end of input)") + "\n", to: STDERR_FILENO)
    }

    /// `[Y/n]`: an empty line or y/yes is yes; end of input or anything else is no.
    static func isYes(_ answer: String?) -> Bool {
        guard let answer else { return false }
        let normalized = answer.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized.isEmpty || normalized == "y" || normalized == "yes"
    }

    static func askYesNo(_ question: String) -> Bool {
        isYes(prompt("\(question) [Y/n] "))
    }

    // MARK: Secrets

    /// Where the token comes from.
    enum SecretSource {
        /// `readpassphrase(3)` on the controlling terminal, echo off, `RPP_REQUIRE_TTY`.
        case terminal
        /// One line of stdin (`--token-stdin`); echo off if stdin is a terminal.
        case standardInput
    }

    static let secretBufferSize = 2048

    /// Reads the token without echoing it. The C buffer that held it is
    /// zeroed with `memset_s` before this returns.
    static func readSecret(prompt: String, from source: SecretSource) throws(CLIError) -> String {
        let size = secretBufferSize
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        defer {
            _ = memset_s(buffer, size, 0, size)
            buffer.deallocate()
        }

        let length: Int
        switch source {
        case .terminal:
            guard readpassphrase(prompt, buffer, size, RPP_REQUIRE_TTY) != nil else {
                throw .usage("there is no terminal to read the token from. Pipe it in with --token-stdin.", command: nil)
            }
            length = strlen(buffer)
        case .standardInput where stdinIsTerminal:
            guard readpassphrase(prompt, buffer, size, RPP_STDIN) != nil else {
                throw .failure("Couldn't read the token from stdin.")
            }
            length = strlen(buffer)
        case .standardInput:
            length = buffer.withMemoryRebound(to: UInt8.self, capacity: size) { readRawLine(into: $0, capacity: size) }
        }
        guard length < size - 1 else {
            throw .failure("That input is longer than any Atlassian API token. Copy the token again.")
        }
        let token = buffer.withMemoryRebound(to: UInt8.self, capacity: size) { bytes in
            String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads stdin up to a line break or end of input into `buffer` (no line
    /// break stored). Returns the byte count; `capacity - 1` means too long.
    private static func readRawLine(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        var length = 0
        while length < capacity - 1 {
            let count = Darwin.read(STDIN_FILENO, buffer + length, 1)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 || buffer[length] == 0x0A {
                buffer[length] = 0
                break
            }
            length += 1
        }
        return length
    }

    // MARK: Clipboard

    /// True when the general pasteboard holds exactly `secret` (ignoring
    /// surrounding whitespace). Reads the pasteboard in-process; the token
    /// never goes through a pipe.
    @MainActor
    static func clipboardHolds(_ secret: String) -> Bool {
        guard let contents = NSPasteboard.general.string(forType: .string) else { return false }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines) == secret
    }

    @MainActor
    static func clearClipboard() {
        NSPasteboard.general.clearContents()
    }

    // MARK: Browser

    /// Opens `url` with `/usr/bin/open`. Returns false if that failed.
    static func open(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
#endif
