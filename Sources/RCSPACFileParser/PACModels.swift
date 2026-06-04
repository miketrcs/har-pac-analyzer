import Foundation

public struct PACRule: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case dnsDomainIs
        case shExpMatch
        case raw
    }

    public let kind: Kind
    public let pattern: String
    public let sourceLine: String

    public init(kind: Kind, pattern: String, sourceLine: String) {
        self.kind = kind
        self.pattern = pattern
        self.sourceLine = sourceLine
    }
}

public struct PACAnalysis: Sendable {
    public let rules: [PACRule]
    public let rawText: String
}
