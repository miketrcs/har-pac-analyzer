import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Synchronous, native (OS-resolver-backed) DNS and local-interface lookups
/// for `dnsResolve`/`isResolvable`/`isInNet`/`myIpAddress`.
///
/// Deliberately diverges from the sister browser tool (which used a public
/// DNS-over-HTTPS service and an IP-echo service, since browsers have no
/// `getaddrinfo`/local-interface API). Native resolution reflects what the
/// actual machine sees — including VPN-scoped/internal-only DNS zones a
/// school district's IT staff needs to test against, which a public DoH
/// resolver can never see. IPv4-only, matching the PAC spec's own
/// `isInNet` mask arithmetic (which is 32-bit-only).
enum PACNetworking {
    /// Resolves `host` to its first IPv4 address via the OS resolver.
    /// Synchronous (matches the PAC spec's `dnsResolve()` semantics), with
    /// a timeout so one bad hostname can't hang a whole batch.
    static func resolveIPv4(host: String, timeout: TimeInterval = 4) -> String? {
        if PACNativeHelpers.isIPv4Literal(host) { return host }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = blockingResolveIPv4(host: host)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.value
    }

    /// The primary non-loopback IPv4 address of a local interface — the
    /// PAC spec's intent for `myIpAddress()` (the client's own address, used
    /// for local-subnet bypass logic like `isInNet(myIpAddress(), ...)`).
    static func primaryLocalIPv4Address() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ifaddr = pointer {
            defer { pointer = ifaddr.pointee.ifa_next }

            let flags = Int32(ifaddr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ifaddr.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET else { continue }

            var sockAddr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sockAddr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }

            let ipString = string(fromNulTerminated: buffer)
            if ipString != "127.0.0.1" { return ipString }
        }
        return nil
    }

    // MARK: - Internals

    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }

    private static func string(fromNulTerminated buffer: [CChar]) -> String {
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        let nulIndex = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0..<nulIndex], as: UTF8.self)
    }

    private static func blockingResolveIPv4(host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var resultPtr: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &resultPtr)
        guard status == 0, let result = resultPtr else { return nil }
        defer { freeaddrinfo(result) }

        guard let sockAddrPtr = result.pointee.ai_addr else { return nil }
        var sockAddr = sockAddrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sockAddr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return string(fromNulTerminated: buffer)
    }
}
