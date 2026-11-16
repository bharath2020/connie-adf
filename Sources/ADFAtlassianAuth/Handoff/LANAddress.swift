#if os(macOS)
import Darwin
import Foundation

/// The Mac's local-network IPv4 address, for the pairing link.
public enum LANAddress {
    public struct Interface: Sendable, Equatable {
        public let name: String
        public let address: String
    }

    /// `en0` if it has an address, else the first other `en*` interface that
    /// is up and running with a non-loopback, non-link-local IPv4 address.
    public static func primaryIPv4() -> String? {
        let candidates = ipv4Interfaces().filter { $0.name.hasPrefix("en") }
        return (candidates.first { $0.name == "en0" } ?? candidates.first)?.address
    }

    /// Every up-and-running, non-loopback, non-link-local IPv4 interface.
    public static func ipv4Interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var inAddr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let text: String? = buffer.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress, inet_ntop(AF_INET, &inAddr, base, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: base)
            }
            guard let text, !text.hasPrefix("169.254.") else { continue }
            result.append(Interface(name: String(cString: entry.pointee.ifa_name), address: text))
        }
        return result
    }
}
#endif
