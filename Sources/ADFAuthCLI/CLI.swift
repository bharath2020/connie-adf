#if os(macOS)
import Foundation

/// Command dispatch and error reporting for `adf-auth`.
@MainActor
enum CLI {
    static let commands = ["login", "list", "push", "rotate", "remove", "probe-graphql", "help"]

    /// Runs one command line and returns the exit status.
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            return try await dispatch(arguments)
        } catch let error as CLIError {
            return report(error)
        } catch {
            // Every command maps its errors to CLIError; this is a backstop.
            return report(.failure(String(describing: type(of: error))))
        }
    }

    /// Prints `error` to stderr and returns its exit status.
    @discardableResult
    static func report(_ error: CLIError) -> Int32 {
        switch error {
        case .usage(let message, let command):
            Terminal.err("adf-auth: \(message)")
            Terminal.err("Run 'adf-auth help\(command.map { " \($0)" } ?? "")' for usage.")
            return ExitCode.usage
        case .failure(let message, let code):
            Terminal.err("error: \(message)")
            return code
        }
    }

    static func dispatch(_ arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first else {
            Terminal.err(Help.main)
            return ExitCode.usage
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "-h", "--help":
            return try help(rest)
        case "--version":
            guard rest.isEmpty else { throw CLIError.usage("--version takes no arguments.", command: nil) }
            Terminal.out(Help.version)
            return ExitCode.success
        case "help":
            return try help(rest)
        case "login":
            return try await LoginCommand.run(rest)
        case "list":
            return try ListCommand.run(rest)
        case "push":
            return try await PushCommand.run(rest)
        case "rotate":
            return try await RotateCommand.run(rest)
        case "remove":
            return try RemoveCommand.run(rest)
        case "probe-graphql":
            return try await ProbeCommand.run(rest)
        default:
            if command.hasPrefix("-") {
                throw CLIError.usage("unknown option '\(command)'.", command: nil)
            }
            throw CLIError.usage("unknown command '\(Terminal.sanitize(String(command.prefix(40))))'. Commands: \(commands.joined(separator: ", ")).", command: nil)
        }
    }

    /// `adf-auth help [command]`.
    static func help(_ arguments: [String]) throws(CLIError) -> Int32 {
        guard let topic = arguments.first else {
            Terminal.out(Help.main)
            return ExitCode.success
        }
        guard arguments.count == 1 else { throw .usage("help takes at most one command name.", command: nil) }
        guard let text = Help.text(for: topic) else {
            throw .usage("no help for '\(Terminal.sanitize(String(topic.prefix(40))))'. Commands: \(commands.joined(separator: ", ")).", command: nil)
        }
        Terminal.out(text)
        return ExitCode.success
    }
}
#endif
