#if os(macOS)
import Darwin
import Foundation
import os

/// Lines of stdin for a prompt that waits while other work goes on (the
/// `push` confirmation).
///
/// One dedicated thread reads one line, and only while someone is waiting,
/// so piped answers are taken in order and never read ahead, and no thread
/// of the cooperative pool ever blocks on stdin. A line goes to whoever is
/// waiting when it arrives. A cancelled wait returns `.cancelled` at once;
/// its read stays in flight and answers the next prompt if one is open by
/// then, otherwise the line is dropped (an answer to a prompt that is gone
/// must never approve a later request). After end of input every wait
/// returns `.endOfInput`.
final class StdinLines: Sendable {
    enum Result: Sendable, Equatable {
        case line(String)
        case endOfInput
        case cancelled
    }

    static let shared = StdinLines()

    private struct Waiter: Sendable {
        let id: UInt64
        let continuation: CheckedContinuation<Result, Never>
    }

    private struct State: Sendable {
        var waiter: Waiter?
        var reading = false
        var endOfInput = false
        var lastID: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private enum Step {
        case resume(Result)
        case wait(displaced: CheckedContinuation<Result, Never>?, startReading: Bool)
    }

    /// The next line. Cancelling the calling task returns `.cancelled`.
    func next() async -> Result {
        let id = state.withLock { state -> UInt64 in
            state.lastID += 1
            return state.lastID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                let step = state.withLock { state -> Step in
                    if state.endOfInput { return .resume(.endOfInput) }
                    let displaced = state.waiter?.continuation
                    state.waiter = Waiter(id: id, continuation: continuation)
                    let startReading = !state.reading
                    state.reading = true
                    return .wait(displaced: displaced, startReading: startReading)
                }
                switch step {
                case .resume(let result):
                    continuation.resume(returning: result)
                case .wait(let displaced, let startReading):
                    displaced?.resume(returning: .cancelled)
                    if startReading { readOneLine() }
                    // Cancelled before the waiter was registered.
                    if Task.isCancelled { cancel(id) }
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UInt64) {
        let continuation = state.withLock { state -> CheckedContinuation<Result, Never>? in
            guard let waiter = state.waiter, waiter.id == id else { return nil }
            state.waiter = nil
            return waiter.continuation
        }
        continuation?.resume(returning: .cancelled)
    }

    private func readOneLine() {
        let thread = Thread { [self] in
            let line = Terminal.readLine()
            let continuation = state.withLock { state -> CheckedContinuation<Result, Never>? in
                state.reading = false
                if line == nil { state.endOfInput = true }
                defer { state.waiter = nil }
                return state.waiter?.continuation
            }
            continuation?.resume(returning: line.map(Result.line) ?? .endOfInput)
        }
        thread.name = "adf-auth stdin"
        thread.start()
    }
}

/// The `[Y/n]` prompt of `push`: keeps warnings and the final message on
/// their own lines, and tells a phone that gave up apart from the timeout.
final class PromptLine: Sendable {
    private struct State: Sendable {
        var open: String?
        var finished = false
        var deadline: Date?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let lines: StdinLines

    init(lines: StdinLines = .shared) {
        self.lines = lines
    }

    /// When the code expires (for telling a departed phone from the timeout).
    func setDeadline(_ deadline: Date) {
        state.withLock { $0.deadline = deadline }
    }

    /// Shows `text` on stderr and waits for one line. `.cancelled` when the
    /// server abandoned the question (the phone left, or time ran out).
    func ask(_ text: String) async -> StdinLines.Result {
        let shown = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.open = text
            return true
        }
        guard shown else { return .cancelled }
        Terminal.write(text, to: STDERR_FILENO)
        let result = await lines.next()
        let lineStillOpen = state.withLock { state -> Bool in
            defer { state.open = nil }
            return state.open != nil && !state.finished
        }
        switch result {
        case .line(let answer):
            Terminal.echoIfPiped(answer)
        case .endOfInput:
            if Terminal.stdinIsTerminal {
                if lineStillOpen { Terminal.write("\n", to: STDERR_FILENO) }
            } else {
                Terminal.echoIfPiped(nil)
            }
        case .cancelled:
            if lineStillOpen { Terminal.write("\n", to: STDERR_FILENO) }
        }
        return result
    }

    /// The phone disconnected while the question was open. Says so, unless
    /// the code is expiring anyway (the final message covers that).
    func phoneLeft(_ peer: String) {
        let mention = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            if let deadline = state.deadline, Date() >= deadline.addingTimeInterval(-1) { return false }
            return true
        }
        if mention {
            Terminal.err("Phone \(peer) went away before you answered; nothing was sent. Still waiting for a scan…")
        }
    }

    /// Prints `message` on its own line; re-shows an open prompt after it.
    func warn(_ message: String) {
        let open = state.withLock { state -> String? in state.finished ? nil : state.open }
        if let open {
            Terminal.write("\n\(message)\n\(open)", to: STDERR_FILENO)
        } else {
            Terminal.err(message)
        }
    }

    /// The handoff is over: end an unanswered prompt's line, stay quiet after.
    func close() {
        let wasOpen = state.withLock { state -> Bool in
            defer {
                state.open = nil
                state.finished = true
            }
            return state.open != nil && !state.finished
        }
        if wasOpen { Terminal.write("\n", to: STDERR_FILENO) }
    }
}
#endif
