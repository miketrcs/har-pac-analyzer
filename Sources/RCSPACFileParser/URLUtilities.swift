import Foundation

private let knownTwoPartTLDs: Set<String> = [
    "co.uk", "co.nz", "co.za", "co.jp", "co.in", "co.id", "co.kr", "co.th",
    "co.il", "co.ve", "co.tz", "co.ug", "co.ke", "co.zw", "co.bw",
    "com.au", "com.br", "com.mx", "com.ar", "com.co", "com.pe", "com.sg",
    "com.hk", "com.tw", "com.tr", "com.my", "com.ph", "com.ng", "com.eg",
    "com.sa", "com.pk", "com.ua", "com.vn", "com.gr", "com.pl", "com.ro",
    "net.au", "net.nz", "net.uk", "net.br", "net.pl",
    "org.uk", "org.au", "org.nz", "org.za",
    "edu.au", "edu.sg", "edu.hk", "edu.tw", "edu.pl",
    "gov.uk", "gov.au", "gov.nz", "gov.sg", "gov.in", "gov.za",
    "ac.uk", "ac.nz", "ac.jp", "ac.za", "ac.kr",
]

public struct NormalizedURL: Hashable, Sendable {
    public let original: String
    public let scheme: String?
    public let host: String?
    public let port: Int?
    public let isNonStandardPort: Bool
    public let path: String
    public let query: String?

    public var lowercasedHost: String? {
        host?.lowercased()
    }

    public var registrableCandidate: String? {
        guard let host = lowercasedHost else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        if parts.count >= 3 {
            let twoLabelSuffix = parts.suffix(2).joined(separator: ".")
            if knownTwoPartTLDs.contains(twoLabelSuffix) {
                return parts.suffix(3).joined(separator: ".")
            }
        }
        return parts.suffix(2).joined(separator: ".")
    }

    public init(rawURL: String) {
        original = rawURL

        if let components = URLComponents(string: rawURL) {
            scheme = components.scheme
            host = components.host
            let p = components.port
            port = p
            let s = components.scheme?.lowercased()
            if let p {
                isNonStandardPort = (s == "http") ? p != 80 : (s == "https") ? p != 443 : true
            } else {
                isNonStandardPort = false
            }
            path = components.path.isEmpty ? "/" : components.path
            query = components.query
        } else {
            scheme = nil
            host = nil
            port = nil
            isNonStandardPort = false
            path = "/"
            query = nil
        }
    }
}
