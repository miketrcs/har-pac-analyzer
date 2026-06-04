import Foundation

public enum PACParser {
    public static func parse(fileURL: URL) throws -> PACAnalysis {
        let rawText = try String(contentsOf: fileURL, encoding: .utf8)
        return PACAnalysis(rules: parseRules(from: rawText), rawText: rawText)
    }

    public static func parse(text: String) -> PACAnalysis {
        PACAnalysis(rules: parseRules(from: text), rawText: text)
    }

    public static func parseRules(from text: String) -> [PACRule] {
        let dnsMatches = text.matches(for: #"dnsDomainIs\s*\(\s*host\s*,\s*"([^"]+)"\s*\)"#)
            .map { PACRule(kind: .dnsDomainIs, pattern: $0.captures[0], sourceLine: $0.match) }

        let shellMatches = text.matches(for: #"shExpMatch\s*\(\s*(?:host|url)\s*,\s*"([^"]+)"\s*\)"#)
            .map { PACRule(kind: .shExpMatch, pattern: $0.captures[0], sourceLine: $0.match) }

        return dnsMatches + shellMatches
    }
}

private extension String {
    struct RegexMatch {
        let match: String
        let captures: [String]
    }

    func matches(for pattern: String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let fullRange = NSRange(startIndex..., in: self)
        return regex.matches(in: self, options: [], range: fullRange).compactMap { result in
            guard let matchRange = Range(result.range, in: self) else { return nil }
            let matchText = String(self[matchRange])
            let captures = (1..<result.numberOfRanges).compactMap { index -> String? in
                guard let captureRange = Range(result.range(at: index), in: self) else { return nil }
                return String(self[captureRange])
            }
            return RegexMatch(match: matchText, captures: captures)
        }
    }
}
