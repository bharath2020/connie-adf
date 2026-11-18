#if os(macOS)
import Foundation

/// Process exit codes.
enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    /// `probe-graphql`: the gateway refused the scoped API token.
    static let scopedTokenRejected: Int32 = 3
}

/// An error that ends the command with a message on stderr.
enum CLIError: Error {
    /// Bad arguments or missing input: exit 2, with a pointer to the help.
    case usage(String, command: String?)
    /// A runtime failure: exit `code`.
    case failure(String, code: Int32 = ExitCode.failure)
}

/// One `--option` a command accepts.
struct OptionSpec: Sendable {
    let name: String
    /// The placeholder for the value (`--site <site>`), or nil for a flag.
    let valueName: String?
    let repeatable: Bool

    init(_ name: String, value: String? = nil, repeatable: Bool = false) {
        self.name = name
        self.valueName = value
        self.repeatable = repeatable
    }
}

/// What a command accepts: options and required positional arguments.
struct CommandSpec: Sendable {
    let name: String
    let options: [OptionSpec]
    /// Required positional arguments, in order (`["site"]` for `remove`).
    let positionals: [String]

    init(_ name: String, options: [OptionSpec] = [], positionals: [String] = []) {
        self.name = name
        self.options = options
        self.positionals = positionals
    }
}

/// The parsed command line of one command.
struct ParsedArguments {
    fileprivate(set) var flags: Set<String> = []
    fileprivate(set) var optionValues: [String: [String]] = [:]
    fileprivate(set) var positionals: [String] = []
    /// `-h` / `--help` appeared anywhere; nothing else was validated.
    fileprivate(set) var helpRequested = false

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ option: String) -> String? { optionValues[option]?.last }
    func values(_ option: String) -> [String] { optionValues[option] ?? [] }
}

/// Hand-rolled `--name value` / `--name=value` parsing.
enum ArgumentParser {
    static func parse(_ arguments: [String], for spec: CommandSpec) throws(CLIError) -> ParsedArguments {
        var result = ParsedArguments()
        var index = 0
        var onlyPositionals = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if onlyPositionals || !argument.hasPrefix("-") || argument == "-" {
                result.positionals.append(argument)
                continue
            }
            if argument == "--" {
                onlyPositionals = true
                continue
            }
            if argument == "-h" || argument == "--help" {
                result.helpRequested = true
                continue
            }
            var name = argument
            var inlineValue: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            if name == "--token" {
                // Never echo the value: it is probably a token.
                throw .usage("the token is never accepted as an argument (it would show up in `ps` and your shell history). Paste it at the hidden prompt, or pipe it in with --token-stdin.", command: spec.name)
            }
            guard let option = spec.options.first(where: { $0.name == name }) else {
                throw .usage("unknown option '\(name)' for '\(spec.name)'.", command: spec.name)
            }
            guard let valueName = option.valueName else {
                guard inlineValue == nil else { throw .usage("'\(name)' doesn't take a value.", command: spec.name) }
                result.flags.insert(name)
                continue
            }
            let value: String
            if let inlineValue {
                value = inlineValue
            } else {
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw .usage("'\(name)' needs a value: \(name) <\(valueName)>.", command: spec.name)
                }
                value = arguments[index]
                index += 1
            }
            if !option.repeatable, result.optionValues[name] != nil {
                throw .usage("'\(name)' was given more than once.", command: spec.name)
            }
            result.optionValues[name, default: []].append(value)
        }
        if result.helpRequested { return result }
        if result.positionals.count > spec.positionals.count {
            // Don't echo the extra argument: it could be a pasted token.
            let takes = spec.positionals.isEmpty ? "no arguments" : spec.positionals.map { "<\($0)>" }.joined(separator: " ")
            throw .usage("too many arguments; '\(spec.name)' takes \(takes).", command: spec.name)
        }
        if result.positionals.count < spec.positionals.count {
            throw .usage("missing <\(spec.positionals[result.positionals.count])>.", command: spec.name)
        }
        return result
    }

    /// An integer option within `range`, or `defaultValue` when absent.
    static func integer(_ parsed: ParsedArguments, _ option: String, in range: ClosedRange<Int>, default defaultValue: Int, command: String) throws(CLIError) -> Int {
        guard let raw = parsed.value(option) else { return defaultValue }
        guard let value = Int(raw), range.contains(value) else {
            throw .usage("\(option) must be a whole number from \(range.lowerBound) to \(range.upperBound).", command: command)
        }
        return value
    }
}
#endif
