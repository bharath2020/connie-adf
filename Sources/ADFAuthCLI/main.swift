// adf-auth: create, check, store and hand off ADFReader's Atlassian
// credentials. macOS only; on other platforms this target is empty.
#if os(macOS)
import Foundation

let status = await CLI.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
#endif
