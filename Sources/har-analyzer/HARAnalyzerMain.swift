import Foundation
import RCSPACFileParser

struct CommandLineTool {
    let harPath: String
    let pacPath: String?

    static func parse() -> CommandLineTool? {
        let args = CommandLine.arguments.dropFirst()
        guard !args.isEmpty else { return nil }

        var harPath: String?
        var pacPath: String?

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--har":
                harPath = iterator.next()
            case "--pac":
                pacPath = iterator.next()
            default:
                if harPath == nil {
                    harPath = arg
                }
            }
        }

        guard let harPath else { return nil }
        return CommandLineTool(harPath: harPath, pacPath: pacPath)
    }
}

@main
enum Main {
    static func main() {
        guard let command = CommandLineTool.parse() else {
            print("""
            Usage:
              har-analyzer --har /path/to/file.har [--pac /path/to/file.pac]

            Notes:
              - Targets HAR 1.2 style files while tolerating browser custom fields.
              - PAC parsing currently recognizes dnsDomainIs(host, "...") and shExpMatch(...).
            """)
            Foundation.exit(1)
        }

        do {
            let harURL = URL(fileURLWithPath: command.harPath)
            let archive = try HARLoader.load(from: harURL)
            let pac = try command.pacPath.map { try PACParser.parse(fileURL: URL(fileURLWithPath: $0)) }
            let report = HARAnalyzer.analyze(archive: archive, pac: pac)
            print(report.renderedText)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private extension AnalysisReport {
    var renderedText: String {
        var lines: [String] = []
        lines.append("HAR version: \(harVersion ?? "unknown")")
        lines.append("Browser: \(browserName ?? "unknown")")
        lines.append("Requests: \(totalRequests)")
        lines.append("Unique hosts: \(uniqueHosts.count)")
        lines.append("Suggested PAC domains: \(registrableDomains.count)")
        lines.append("")
        lines.append(ANSI.cyan("PAC-ready domains:"))
        lines.append(contentsOf: pacReadyDomains.map { "  \(ANSI.blue($0))" })
        lines.append("")

        if !matchedHosts.isEmpty || !unmatchedHosts.isEmpty {
            lines.append(ANSI.cyan("PAC comparison:"))
            lines.append("  matched hosts: \(ANSI.green(String(matchedHosts.count)))")
            lines.append("  unmatched hosts: \(ANSI.yellow(String(unmatchedHosts.count)))")
            lines.append("  matched domains: \(ANSI.green(String(matchedDomains.count)))")
            lines.append("  unmatched domains: \(ANSI.yellow(String(unmatchedDomains.count)))")
            lines.append(contentsOf: unmatchedDomains.map { "  suggested domain: \(ANSI.yellow($0))" })
            lines.append(contentsOf: unmatchedHosts.prefix(25).map { "  missing: \(ANSI.yellow($0))" })
            lines.append("")
        }

        if !requiredBypassDomains.isEmpty {
            lines.append(ANSI.green("Likely required bypass domains:"))
            lines.append(contentsOf: requiredBypassDomains.map { "  \(ANSI.green($0))" })
            lines.append("")
        }

        if !optionalDomains.isEmpty {
            lines.append(ANSI.dim("Likely optional domains:"))
            lines.append(contentsOf: optionalDomains.map { "  \(ANSI.dim($0))" })
            lines.append("")
        }

        if !categorySummaries.isEmpty {
            lines.append(ANSI.cyan("Traffic categories:"))
            for summary in categorySummaries {
                let label = "\(summary.category.rawValue) [\(summary.criticality.rawValue)]"
                let styledLabel = styledCategoryLabel(label, criticality: summary.criticality)
                let styledHosts = summary.hosts.map { styledHost($0, criticality: summary.criticality) }.joined(separator: ", ")
                lines.append("  \(styledLabel): \(styledHosts)")
            }
            lines.append("")
        }

        if !zscalerSignals.isEmpty {
            lines.append(ANSI.magenta("Zscaler / proxy signals:"))
            lines.append(contentsOf: zscalerSignals.map { "  - \(ANSI.yellow($0))" })
            lines.append("")
        }

        if !javaScriptURLs.isEmpty {
            lines.append(ANSI.cyan("JavaScript URLs:"))
            lines.append(contentsOf: javaScriptURLs.prefix(30).map { "  \(ANSI.blue($0))" })
            lines.append("")
        }

        if !stylesheetURLs.isEmpty {
            lines.append(ANSI.cyan("Stylesheet URLs:"))
            lines.append(contentsOf: stylesheetURLs.prefix(30).map { "  \(ANSI.blue($0))" })
            lines.append("")
        }

        if !blockedCandidates.isEmpty {
            lines.append(ANSI.red("Possible blocking or breakage:"))
            for item in blockedCandidates.prefix(25) {
                let pacText = item.pacMatch.map { " | PAC: \($0.pattern)" } ?? " | PAC: no match"
                let categoryText = item.classification.map { " | \($0.category.rawValue)" } ?? ""
                lines.append("  \(styledStatus(item.status)) \(ANSI.red(item.url))\(ANSI.dim(pacText))\(ANSI.dim(categoryText))")
                item.suspectedIssues.forEach { lines.append("    - \(ANSI.yellow($0))") }
            }
            lines.append("")
        }

        if !slowRequests.isEmpty {
            lines.append(ANSI.yellow("Slow requests:"))
            for item in slowRequests.prefix(10) {
                let categoryText = item.classification.map { " | \($0.category.rawValue)" } ?? ""
                lines.append("  \(styledStatus(item.status)) \(ANSI.yellow(item.url))\(ANSI.dim(categoryText))")
                item.suspectedIssues.forEach { lines.append("    - \(ANSI.yellow($0))") }
            }
        }

        return lines.joined(separator: "\n")
    }

    func styledCategoryLabel(_ text: String, criticality: AccessCriticality) -> String {
        switch criticality {
        case .required:
            return ANSI.green(text)
        case .optional:
            return ANSI.dim(text)
        case .unknown:
            return ANSI.yellow(text)
        }
    }

    func styledHost(_ host: String, criticality: AccessCriticality) -> String {
        switch criticality {
        case .required:
            return ANSI.green(host)
        case .optional:
            return ANSI.dim(host)
        case .unknown:
            return ANSI.yellow(host)
        }
    }

    func styledStatus(_ status: Int) -> String {
        let text = "[\(status)]"
        switch status {
        case 200..<300:
            return ANSI.green(text)
        case 300..<400:
            return ANSI.yellow(text)
        default:
            return ANSI.red(text)
        }
    }
}

private enum ANSI {
    static func red(_ text: String) -> String { wrap(text, code: "31") }
    static func green(_ text: String) -> String { wrap(text, code: "32") }
    static func yellow(_ text: String) -> String { wrap(text, code: "33") }
    static func blue(_ text: String) -> String { wrap(text, code: "34") }
    static func magenta(_ text: String) -> String { wrap(text, code: "35") }
    static func cyan(_ text: String) -> String { wrap(text, code: "36") }
    static func dim(_ text: String) -> String { wrap(text, code: "2") }

    private static func wrap(_ text: String, code: String) -> String {
        "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }
}
