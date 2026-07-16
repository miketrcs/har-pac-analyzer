import Foundation

/// Mechanical port of the source-scanning helpers proven out in the sister
/// browser tool (pac-analyzer.html). Operates over `[Character]` so index
/// math stays O(1), matching the original's raw-index string scanning.
///
/// No JavaScriptCore dependency here — this is pure text surgery, done
/// before anything is handed to a JS engine.
enum PACSourceInstrumentation {
    /// Replaces string/comment *contents* with spaces (preserving length and
    /// newlines) so that occurrences of "FindProxyForURL" or stray brackets
    /// inside comments/strings — e.g. a commented-out older version of the
    /// function, common in real-world ops-maintained PAC files — can't be
    /// mistaken for real code while locating/parsing the function.
    static func maskCommentsAndStrings(_ source: [Character]) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(source.count)
        var i = 0
        let n = source.count
        while i < n {
            let c = source[i]
            if c == "\"" || c == "'" || c == "`" {
                let q = c
                out.append(" ")
                i += 1
                while i < n {
                    if source[i] == "\\" {
                        out.append(" ")
                        out.append(" ")
                        i += 2
                        continue
                    }
                    if source[i] == "\n" {
                        out.append("\n")
                        i += 1
                        continue
                    }
                    if source[i] == q {
                        out.append(" ")
                        i += 1
                        break
                    }
                    out.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/" && i + 1 < n && source[i + 1] == "/" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i < n && source[i] != "\n" {
                    out.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/" && i + 1 < n && source[i + 1] == "*" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i < n && !(source[i] == "*" && i + 1 < n && source[i + 1] == "/") {
                    out.append(source[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Finds the index just past `FindProxyForURL(`'s opening paren, on a
    /// masked (comment/string-blind) source. Returns nil if not found.
    static func locateFindProxyParamsStart(_ masked: [Character]) -> Int? {
        let text = String(masked)
        if let range = text.range(of: #"function\s+FindProxyForURL\s*\("#, options: .regularExpression) {
            return text.distance(from: text.startIndex, to: range.upperBound)
        }
        if let range = text.range(of: #"FindProxyForURL\s*=\s*function\s*\("#, options: .regularExpression) {
            return text.distance(from: text.startIndex, to: range.upperBound)
        }
        return nil
    }

    /// Given the index of an opening `{`, finds the index of its matching
    /// closing `}` (skipping strings/comments). Returns nil if unbalanced.
    static func findMatchingBrace(_ source: [Character], openIndex: Int) -> Int? {
        var depth = 0
        var i = openIndex
        let n = source.count
        while i < n {
            let c = source[i]
            if c == "\"" || c == "'" || c == "`" {
                let q = c
                i += 1
                while i < n {
                    if source[i] == "\\" { i += 2; continue }
                    if source[i] == q { i += 1; break }
                    i += 1
                }
                continue
            }
            if c == "/" && i + 1 < n && source[i + 1] == "/" {
                while i < n && source[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < n && source[i + 1] == "*" {
                i += 2
                while i < n && !(source[i] == "*" && i + 1 < n && source[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "{" { depth += 1; i += 1; continue }
            if c == "}" {
                depth -= 1
                i += 1
                if depth == 0 { return i - 1 }
                continue
            }
            i += 1
        }
        return nil
    }

    struct InstrumentedBody {
        let code: [Character]
        let hitLines: [Int]
    }

    /// Rewrites every `return <expr>;` (or bare `return;`) in `source` to
    /// `return __trace(<line>, (<expr>));`, correctly skipping over strings,
    /// comments, and nested parens/brackets/braces to find each return's own
    /// expression boundary. `startLine` is the 1-based line number of the
    /// first character of `source`.
    static func instrumentReturns(_ source: [Character], startLine: Int) -> InstrumentedBody {
        var i = 0
        let n = source.count
        var out: [Character] = []
        out.reserveCapacity(source.count + 64)
        var line = startLine
        var hitLines: [Int] = []

        func isIdentStart(_ c: Character) -> Bool {
            c.isLetter || c == "_" || c == "$"
        }
        func isIdentPart(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "$"
        }
        func isSpace(_ c: Character) -> Bool {
            c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{0C}"
        }

        while i < n {
            let c = source[i]
            if c == "\n" { line += 1; out.append(c); i += 1; continue }

            if c == "\"" || c == "'" || c == "`" {
                let q = c
                var j = i + 1
                out.append(c)
                while j < n {
                    if source[j] == "\\" {
                        out.append(source[j])
                        if j + 1 < n { out.append(source[j + 1]); if source[j + 1] == "\n" { line += 1 } }
                        j += 2
                        continue
                    }
                    if source[j] == "\n" { line += 1 }
                    out.append(source[j])
                    if source[j] == q { j += 1; break }
                    j += 1
                }
                i = j
                continue
            }

            if c == "/" && i + 1 < n && source[i + 1] == "/" {
                var j = i
                while j < n && source[j] != "\n" { out.append(source[j]); j += 1 }
                i = j
                continue
            }
            if c == "/" && i + 1 < n && source[i + 1] == "*" {
                var j = i + 2
                out.append("/"); out.append("*")
                while j < n && !(source[j] == "*" && j + 1 < n && source[j + 1] == "/") {
                    if source[j] == "\n" { line += 1 }
                    out.append(source[j])
                    j += 1
                }
                out.append("*"); out.append("/")
                j += 2
                i = j
                continue
            }

            if isIdentStart(c) {
                var j = i
                while j < n && isIdentPart(source[j]) { j += 1 }
                let word = String(source[i..<j])
                if word == "return" {
                    let returnLine = line
                    out.append(contentsOf: word)
                    i = j
                    var ws: [Character] = []
                    var k = i
                    while k < n && isSpace(source[k]) {
                        if source[k] == "\n" { line += 1 }
                        ws.append(source[k])
                        k += 1
                    }
                    if k < n && (source[k] == ";" || source[k] == "}") {
                        out.append(contentsOf: ws)
                        out.append(contentsOf: Array("__trace(\(returnLine), undefined)"))
                        i = k
                        hitLines.append(returnLine)
                        continue
                    }
                    var depth = 0
                    var m = k
                    var exprEnd = -1
                    while m < n {
                        let ch = source[m]
                        if ch == "\"" || ch == "'" || ch == "`" {
                            let q = ch
                            m += 1
                            while m < n {
                                if source[m] == "\\" { m += 2; continue }
                                if source[m] == q { m += 1; break }
                                if source[m] == "\n" { line += 1 }
                                m += 1
                            }
                            continue
                        }
                        if ch == "(" || ch == "[" || ch == "{" { depth += 1; m += 1; continue }
                        if ch == ")" || ch == "]" || ch == "}" { depth = max(0, depth - 1); m += 1; continue }
                        if ch == ";" && depth == 0 { exprEnd = m; break }
                        if ch == "\n" { line += 1 }
                        m += 1
                    }
                    if exprEnd == -1 { exprEnd = m }
                    let expr = source[k..<exprEnd]
                    out.append(contentsOf: ws)
                    out.append(contentsOf: Array("__trace(\(returnLine), ("))
                    out.append(contentsOf: expr)
                    out.append(contentsOf: Array("))"))
                    i = exprEnd
                    hitLines.append(returnLine)
                    continue
                } else {
                    out.append(contentsOf: word)
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return InstrumentedBody(code: out, hitLines: hitLines)
    }
}
