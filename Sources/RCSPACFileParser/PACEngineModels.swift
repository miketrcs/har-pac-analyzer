import Foundation

public struct PACTestResult: Sendable, Identifiable {
    public let id: UUID
    public let rawInput: String
    public let url: String
    public let host: String
    public let value: String?
    public let matchedLine: Int?
    public let isFallback: Bool
    public let error: String?
    public let suggestedRule: String?

    public init(
        id: UUID = UUID(),
        rawInput: String,
        url: String,
        host: String,
        value: String?,
        matchedLine: Int?,
        isFallback: Bool,
        error: String?,
        suggestedRule: String?
    ) {
        self.id = id
        self.rawInput = rawInput
        self.url = url
        self.host = host
        self.value = value
        self.matchedLine = matchedLine
        self.isFallback = isFallback
        self.error = error
        self.suggestedRule = suggestedRule
    }
}

public enum PACEngineError: Error, Sendable, LocalizedError, Equatable {
    case functionNotFound
    case unbalancedParameterList
    case missingFunctionBody
    case unbalancedBraces
    case javaScriptLoadError(String)
    case notAFunction

    public var errorDescription: String? {
        switch self {
        case .functionNotFound:
            return "Could not find a FindProxyForURL(url, host) function in this file."
        case .unbalancedParameterList:
            return "Unbalanced parentheses in FindProxyForURL parameter list."
        case .missingFunctionBody:
            return "Could not find the body of FindProxyForURL."
        case .unbalancedBraces:
            return "Unbalanced braces in FindProxyForURL body."
        case .javaScriptLoadError(let message):
            return "JavaScript error while loading PAC script: \(message)"
        case .notAFunction:
            return "FindProxyForURL was not a function after loading."
        }
    }
}
