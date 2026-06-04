import Foundation

public struct RequestDiagnostic: Sendable {
    public let url: String
    public let host: String?
    public let method: String
    public let status: Int
    public let mimeType: String?
    public let suspectedIssues: [String]
    public let pacMatch: PACRule?
    public let classification: HostClassification?
}

public struct AnalyzedRequest: Sendable {
    public let url: String
    public let host: String?
    public let registrableDomain: String?
    public let method: String
    public let status: Int
    public let mimeType: String?
    public let elapsedMS: Double?
    public let port: Int?
    public let isNonStandardPort: Bool
    public let timings: RequestTimingBreakdown
    public let requestHeaders: [HeaderField]
    public let responseHeaders: [HeaderField]
    public let headerSignals: [String]
    public let pacMatch: PACRule?
    public let classification: HostClassification?
    public let issues: [String]
}

public struct PortSummary: Sendable {
    public let port: Int
    public let scheme: String
    public let isStandard: Bool
    public let requestCount: Int
    public let hosts: [String]
}

public struct HeaderField: Sendable {
    public let name: String
    public let value: String?
}

public struct RequestTimingBreakdown: Sendable {
    public let blocked: Double?
    public let dns: Double?
    public let connect: Double?
    public let ssl: Double?
    public let send: Double?
    public let wait: Double?
    public let receive: Double?
}

public struct CategorySummary: Sendable {
    public let category: ServiceCategory
    public let criticality: AccessCriticality
    public let hosts: [String]
}

private struct CategorySummaryKey: Hashable {
    let category: ServiceCategory
    let criticality: AccessCriticality
}

public struct AnalysisReport: Sendable {
    public let harVersion: String?
    public let browserName: String?
    public let totalRequests: Int
    public let uniqueHosts: [String]
    public let registrableDomains: [String]
    public let pacReadyDomains: [String]
    public let matchedHosts: [String]
    public let unmatchedHosts: [String]
    public let matchedDomains: [String]
    public let unmatchedDomains: [String]
    public let requiredBypassDomains: [String]
    public let optionalDomains: [String]
    public let hostClassifications: [HostClassification]
    public let categorySummaries: [CategorySummary]
    public let requests: [AnalyzedRequest]
    public let javaScriptURLs: [String]
    public let stylesheetURLs: [String]
    public let zscalerSignals: [String]
    public let blockedCandidates: [RequestDiagnostic]
    public let slowRequests: [RequestDiagnostic]
    public let portSummaries: [PortSummary]
}

public enum HARAnalyzer {
    public static func analyze(archive: HARArchive, pac: PACAnalysis? = nil) -> AnalysisReport {
        let normalizedEntries = archive.log.entries.map { entry in
            (entry: entry, normalized: NormalizedURL(rawURL: entry.request.url))
        }

        let uniqueHosts = Array(Set(normalizedEntries.compactMap(\.normalized.lowercasedHost))).sorted()
        let registrableDomains = Array(Set(normalizedEntries.compactMap(\.normalized.registrableCandidate))).sorted()
        let pacReadyDomains = registrableDomains.map { #"dnsDomainIs(host, ".\#($0)") ||"# }
        let hostClassifications = uniqueHosts.map(TrafficClassifier.classify(host:))
        let hostClassificationMap = Dictionary(uniqueKeysWithValues: hostClassifications.map { ($0.host, $0) })

        let pacMatches: [String: PACRule] = Dictionary(uniqueKeysWithValues: uniqueHosts.compactMap { host in
            guard let match = pac.flatMap({ bestPACMatch(for: host, in: $0.rules) }) else { return nil }
            return (host, match)
        })

        // Group observed hosts by their registrable domain so we can check coverage at the domain level.
        // A domain needs a bypass only if at least one of its observed hosts lacks a PAC rule — not
        // because the bare domain string itself is absent from the PAC file.
        let hostsByDomain = Dictionary(grouping: uniqueHosts) { host in
            NormalizedURL(rawURL: "https://\(host)").registrableCandidate ?? host
        }

        let javaScriptURLs = extractURLs(from: normalizedEntries, mimeTypeFragment: "javascript", extension: ".js")
        let stylesheetURLs = extractURLs(from: normalizedEntries, mimeTypeFragment: "css", extension: ".css")

        let zscalerSignals = buildZscalerSignals(from: archive.log.entries)
        let requests = normalizedEntries.map { pair -> AnalyzedRequest in
            let entry = pair.entry
            let normalized = pair.normalized
            return AnalyzedRequest(
                url: entry.request.url,
                host: normalized.lowercasedHost,
                registrableDomain: normalized.registrableCandidate,
                method: entry.request.method,
                status: entry.response.status,
                mimeType: entry.response.content?.mimeType,
                elapsedMS: entry.time,
                port: normalized.port,
                isNonStandardPort: normalized.isNonStandardPort,
                timings: RequestTimingBreakdown(
                    blocked: entry.timings?.blocked,
                    dns: entry.timings?.dns,
                    connect: entry.timings?.connect,
                    ssl: entry.timings?.ssl,
                    send: entry.timings?.send,
                    wait: entry.timings?.wait,
                    receive: entry.timings?.receive
                ),
                requestHeaders: (entry.request.headers ?? []).map { HeaderField(name: $0.name, value: $0.value) },
                responseHeaders: (entry.response.headers ?? []).map { HeaderField(name: $0.name, value: $0.value) },
                headerSignals: headerSignals(for: entry),
                pacMatch: normalized.lowercasedHost.flatMap { pacMatches[$0] },
                classification: normalized.lowercasedHost.flatMap { hostClassificationMap[$0] },
                issues: suspectedIssues(for: entry, normalized: normalized)
            )
        }

        let blockedCandidates = normalizedEntries.compactMap { pair -> RequestDiagnostic? in
            let entry = pair.entry
            let normalized = pair.normalized
            let issues = suspectedIssues(for: entry, normalized: normalized)
            guard !issues.isEmpty else { return nil }
            return RequestDiagnostic(
                url: entry.request.url,
                host: normalized.lowercasedHost,
                method: entry.request.method,
                status: entry.response.status,
                mimeType: entry.response.content?.mimeType,
                suspectedIssues: issues,
                pacMatch: normalized.lowercasedHost.flatMap { pacMatches[$0] },
                classification: normalized.lowercasedHost.flatMap { hostClassificationMap[$0] }
            )
        }

        let slowRequests = normalizedEntries
            .filter { $0.entry.time.map { $0 >= 2_000 } ?? false }
            .sorted { ($0.entry.time ?? 0) > ($1.entry.time ?? 0) }
            .prefix(15)
            .map { entry, normalized in
                RequestDiagnostic(
                    url: entry.request.url,
                    host: normalized.lowercasedHost,
                    method: entry.request.method,
                    status: entry.response.status,
                    mimeType: entry.response.content?.mimeType,
                    suspectedIssues: ["Slow request: \((entry.time ?? 0).formattedMilliseconds)"],
                    pacMatch: normalized.lowercasedHost.flatMap { pacMatches[$0] },
                    classification: normalized.lowercasedHost.flatMap { hostClassificationMap[$0] }
                )
            }

        let matchedHosts = uniqueHosts.filter { pacMatches[$0] != nil }
        let unmatchedHosts = uniqueHosts.filter { pacMatches[$0] == nil }
        let matchedDomains = registrableDomains.filter { domain in
            let hosts = hostsByDomain[domain] ?? []
            return !hosts.isEmpty && hosts.allSatisfy { pacMatches[$0] != nil }
        }
        let unmatchedDomains = registrableDomains.filter { domain in
            let hosts = hostsByDomain[domain] ?? []
            return hosts.contains { pacMatches[$0] == nil }
        }
        let requiredBypassDomains = Array(Set(hostClassifications
            .filter { $0.criticality == .required }
            .compactMap { NormalizedURL(rawURL: "https://\($0.host)").registrableCandidate }
            .filter { unmatchedDomains.contains($0) }
        )).sorted()
        let optionalDomains = Array(Set(hostClassifications
            .filter { $0.criticality == .optional }
            .compactMap { NormalizedURL(rawURL: "https://\($0.host)").registrableCandidate }
            .filter { unmatchedDomains.contains($0) }
        )).sorted()
        let categorySummaries = buildCategorySummaries(from: hostClassifications)
        let portSummaries = buildPortSummaries(from: normalizedEntries)

        return AnalysisReport(
            harVersion: archive.log.version,
            browserName: archive.log.browser?.name,
            totalRequests: archive.log.entries.count,
            uniqueHosts: uniqueHosts,
            registrableDomains: registrableDomains,
            pacReadyDomains: pacReadyDomains,
            matchedHosts: matchedHosts,
            unmatchedHosts: unmatchedHosts,
            matchedDomains: matchedDomains,
            unmatchedDomains: unmatchedDomains,
            requiredBypassDomains: requiredBypassDomains,
            optionalDomains: optionalDomains,
            hostClassifications: hostClassifications,
            categorySummaries: categorySummaries,
            requests: requests,
            javaScriptURLs: javaScriptURLs,
            stylesheetURLs: stylesheetURLs,
            zscalerSignals: zscalerSignals,
            blockedCandidates: blockedCandidates,
            slowRequests: Array(slowRequests),
            portSummaries: portSummaries
        )
    }

    private static func extractURLs(
        from entries: [(entry: HAREntry, normalized: NormalizedURL)],
        mimeTypeFragment: String,
        extension ext: String
    ) -> [String] {
        Array(Set(entries.compactMap { entry, _ -> String? in
            let mimeType = entry.response.content?.mimeType?.lowercased() ?? ""
            let url = entry.request.url.lowercased()
            guard mimeType.contains(mimeTypeFragment) || url.hasSuffix(ext) || url.contains("\(ext)?") else {
                return nil
            }
            return entry.request.url
        })).sorted()
    }

    private static func suspectedIssues(for entry: HAREntry, normalized: NormalizedURL) -> [String] {
        var issues: [String] = []
        let status = entry.response.status
        let mimeType = entry.response.content?.mimeType?.lowercased() ?? ""
        let url = entry.request.url.lowercased()

        if [0, 403, 407, 412, 451, 502, 503, 504].contains(status) {
            issues.append("HTTP status \(status) may indicate blocking, proxy auth, or upstream failure")
        }

        if mimeType.contains("html"), url.hasSuffix(".js") || url.contains(".js?") {
            issues.append("JavaScript URL returned HTML instead of JavaScript")
        }

        if mimeType.contains("html"), url.hasSuffix(".css") || url.contains(".css?") {
            issues.append("Stylesheet URL returned HTML instead of CSS")
        }

        if let redirect = entry.response.redirectURL, !redirect.isEmpty {
            issues.append("Redirected to \(redirect)")
        }

        if let wait = entry.timings?.wait, wait >= 3_000 {
            issues.append("Server wait time is elevated: \(wait.formattedMilliseconds)")
        }

        if let dns = entry.timings?.dns, dns >= 1_000 {
            issues.append("DNS resolution is slow: \(dns.formattedMilliseconds)")
        }

        return issues
    }

    private static func bestPACMatch(for host: String, in rules: [PACRule]) -> PACRule? {
        rules
            .filter { rule in
                switch rule.kind {
                case .dnsDomainIs:
                    let normalizedPattern = rule.pattern.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return host == normalizedPattern || host.hasSuffix(".\(normalizedPattern)")
                case .shExpMatch:
                    let pattern = rule.pattern.lowercased()
                    if host == pattern { return true }
                    let escaped = NSRegularExpression.escapedPattern(for: pattern)
                        .replacingOccurrences(of: "\\*", with: ".*")
                        .replacingOccurrences(of: "\\?", with: ".")
                    guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$") else { return false }
                    return regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
                case .raw:
                    return false
                }
            }
            .max { $0.pattern.count < $1.pattern.count }
    }

    private static func buildZscalerSignals(from entries: [HAREntry]) -> [String] {
        var signals: [String] = []
        let statusCounts = Dictionary(grouping: entries, by: { $0.response.status }).mapValues(\.count)

        if let proxyAuth = statusCounts[407], proxyAuth > 0 {
            signals.append("Detected \(proxyAuth) response(s) with HTTP 407, which often points to proxy authentication or policy interception.")
        }

        if let forbidden = statusCounts[403], forbidden > 0 {
            signals.append("Detected \(forbidden) response(s) with HTTP 403. Review PAC allow rules and any Zscaler category/policy decisions.")
        }

        if let legal = statusCounts[451], legal > 0 {
            signals.append("Detected \(legal) response(s) with HTTP 451, which can indicate policy-based blocking or content restriction.")
        }

        if let precondition = statusCounts[412], precondition > 0 {
            signals.append("Detected \(precondition) response(s) with HTTP 412. This can be application logic, but it is still worth reviewing when a page partially breaks.")
        }

        let htmlForJS = entries.filter {
            let mimeType = $0.response.content?.mimeType?.lowercased() ?? ""
            let url = $0.request.url.lowercased()
            return mimeType.contains("html") && (url.hasSuffix(".js") || url.contains(".js?"))
        }
        if !htmlForJS.isEmpty {
            signals.append("Detected \(htmlForJS.count) JavaScript request(s) returning HTML, which can happen when a proxy block page is served instead of the script.")
        }

        let zeroStatus = statusCounts[0] ?? 0
        if zeroStatus > 0 {
            signals.append("Detected \(zeroStatus) request(s) with status 0, which can reflect browser-side failures, cancelled requests, or blocked network flows.")
        }

        return signals
    }

    private static func headerSignals(for entry: HAREntry) -> [String] {
        var signals: [String] = []
        let responseHeaders = groupedHeaderValues(from: entry.response.headers ?? [])

        let requestURL = entry.request.url.lowercased()
        let contentType = responseHeaders["content-type"]?.first?.lowercased() ?? entry.response.content?.mimeType?.lowercased() ?? ""

        if let location = responseHeaders["location"]?.first, !location.isEmpty {
            signals.append("Redirect response header points to \(location)")
        }

        if let via = responseHeaders["via"]?.first, !via.isEmpty {
            signals.append("`Via` header present: \(via)")
        }

        if let server = responseHeaders["server"]?.first, !server.isEmpty {
            signals.append("Server header: \(server)")
        }

        if let proxyAuthenticate = responseHeaders["proxy-authenticate"]?.first, !proxyAuthenticate.isEmpty {
            signals.append("Proxy authentication requested: \(proxyAuthenticate)")
        }

        if let xCache = responseHeaders["x-cache"]?.first, !xCache.isEmpty {
            signals.append("Cache indicator: \(xCache)")
        }

        if let cfCacheStatus = responseHeaders["cf-cache-status"]?.first, !cfCacheStatus.isEmpty {
            signals.append("Cloudflare cache status: \(cfCacheStatus)")
        }

        if requestURL.hasSuffix(".js") || requestURL.contains(".js?") {
            if !contentType.isEmpty, !contentType.contains("javascript"), !contentType.contains("ecmascript") {
                signals.append("JavaScript request returned unexpected content type: \(contentType)")
            }
        }

        if requestURL.hasSuffix(".css") || requestURL.contains(".css?") {
            if !contentType.isEmpty, !contentType.contains("css") {
                signals.append("Stylesheet request returned unexpected content type: \(contentType)")
            }
        }

        if entry.response.status == 429 {
            signals.append("Rate limiting detected (HTTP 429)")
        }

        return signals
    }

    private static func groupedHeaderValues(from headers: [HARNamedValue]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for header in headers {
            result[header.name.lowercased(), default: []].append(header.value ?? "")
        }
        return result
    }

    private static func buildPortSummaries(
        from entries: [(entry: HAREntry, normalized: NormalizedURL)]
    ) -> [PortSummary] {
        var portCounts: [Int: Int] = [:]
        var portHosts: [Int: Set<String>] = [:]
        var portSchemes: [Int: String] = [:]

        for (_, normalized) in entries {
            let scheme = normalized.scheme?.lowercased() ?? "https"
            let effectivePort = normalized.port ?? (scheme == "http" ? 80 : 443)
            portCounts[effectivePort, default: 0] += 1
            portHosts[effectivePort, default: []].insert(normalized.lowercasedHost ?? "")
            if portSchemes[effectivePort] == nil { portSchemes[effectivePort] = scheme }
        }

        return portCounts
            .map { port, count -> PortSummary in
                let scheme = portSchemes[port] ?? "https"
                let isStandard = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
                return PortSummary(
                    port: port,
                    scheme: scheme,
                    isStandard: isStandard,
                    requestCount: count,
                    hosts: (portHosts[port] ?? []).sorted()
                )
            }
            .sorted { a, b in
                if a.isStandard != b.isStandard { return !a.isStandard }
                return a.requestCount > b.requestCount
            }
    }

    private static func buildCategorySummaries(from classifications: [HostClassification]) -> [CategorySummary] {
        let grouped = Dictionary(grouping: classifications) {
            CategorySummaryKey(category: $0.category, criticality: $0.criticality)
        }
        return grouped
            .map { key, value in
                CategorySummary(
                    category: key.category,
                    criticality: key.criticality,
                    hosts: value.map { $0.host }.sorted()
                )
            }
            .sorted {
                func rank(_ c: AccessCriticality) -> Int {
                    switch c { case .required: return 0; case .optional: return 1; case .unknown: return 2 }
                }
                if $0.criticality == $1.criticality {
                    return $0.category.rawValue < $1.category.rawValue
                }
                return rank($0.criticality) < rank($1.criticality)
            }
    }
}

private extension Double {
    var formattedMilliseconds: String {
        String(format: "%.0f ms", self)
    }
}
