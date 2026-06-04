import Foundation

public enum ServiceCategory: String, Sendable, CaseIterable {
    case coreApp = "Core App"
    case cdnStatic = "CDN / Static Assets"
    case fileStorage = "File Storage / Media"
    case identity = "Identity / Auth"
    case api = "API / Data"
    case telemetry = "Telemetry / Monitoring"
    case analytics = "Analytics / Tracking"
    case ads = "Ads / Marketing"
    case thirdPartySupport = "Third-Party Support"
    case unknown = "Unknown"
}

public enum AccessCriticality: String, Sendable {
    case required = "Likely Required"
    case optional = "Likely Optional"
    case unknown = "Needs Review"
}

public struct HostClassification: Sendable {
    public let host: String
    public let category: ServiceCategory
    public let criticality: AccessCriticality
    public let reason: String
}

public enum TrafficClassifier {
    public static func classify(host: String) -> HostClassification {
        let host = host.lowercased()

        // 1. Exact host lookup in the tracker-radar database.
        if let (category, criticality) = TrackerDatabase.lookup(host) {
            return HostClassification(host: host, category: category, criticality: criticality, reason: "Matched in tracker-radar database")
        }

        // 2. Registrable-domain lookup — covers subdomains not listed individually.
        let registrable = NormalizedURL(rawURL: "https://\(host)").registrableCandidate ?? host
        if registrable != host, let (category, criticality) = TrackerDatabase.lookup(registrable) {
            return HostClassification(host: host, category: category, criticality: criticality, reason: "Parent domain matched in tracker-radar database (\(registrable))")
        }

        // 3. Heuristics for domains the database doesn't cover.
        return heuristicClassify(host: host)
    }

    private static func heuristicClassify(host: String) -> HostClassification {
        if containsAny(host, fragments: ["doubleclick", "googlesyndication", "adservice", "ads.", "advertising.", "xlgmedia"]) {
            return HostClassification(host: host, category: .ads, criticality: .optional, reason: "Advertising or ad-delivery hostname")
        }

        if containsAny(host, fragments: ["cloudfront.net", "akamai", "fastly", "cdn.", "cdn-", "walmartimages.com", "gstatic.com", "jsdelivr.net"]) {
            return HostClassification(host: host, category: .cdnStatic, criticality: .required, reason: "Static asset CDN likely required for page rendering")
        }

        if containsAny(host, fragments: ["amazonaws.com", "inscloudgate.net", "uploads", "blob.core.windows.net"]) {
            return HostClassification(host: host, category: .fileStorage, criticality: .required, reason: "File or media storage backing site content")
        }

        if containsAny(host, fragments: ["auth", "login", "oauth", "okta", "microsoftonline", "canvaslms.com"]) {
            if host.contains("canvaslms.com") && !host.contains("sso") {
                return HostClassification(host: host, category: .coreApp, criticality: .required, reason: "Primary application hostname")
            }
            return HostClassification(host: host, category: .identity, criticality: .required, reason: "Authentication or identity hostname")
        }

        if containsAny(host, fragments: ["instructure.com", "walmart.com", "wal.co"]) {
            return HostClassification(host: host, category: .coreApp, criticality: .required, reason: "Primary site application hostname")
        }

        if containsAny(host, fragments: ["sentry", "insops.net", "newrelic", "datadog", "bugsnag"]) {
            return HostClassification(host: host, category: .telemetry, criticality: .optional, reason: "Monitoring or error reporting hostname")
        }

        if containsAny(host, fragments: ["google-analytics", "analytics", "segment", "pendo", "rlcdn", "crcldu", "perimeterx", "px-cloud"]) {
            let category: ServiceCategory = containsAny(host, fragments: ["pendo", "segment", "rlcdn"]) ? .analytics : .telemetry
            return HostClassification(host: host, category: category, criticality: .optional, reason: "Telemetry, bot defense, or analytics hostname")
        }

        if containsAny(host, fragments: ["api.", "graphql", "services", "gateway"]) {
            return HostClassification(host: host, category: .api, criticality: .required, reason: "API or service endpoint")
        }

        return HostClassification(host: host, category: .unknown, criticality: .unknown, reason: "No heuristic classification yet")
    }

    private static func containsAny(_ host: String, fragments: [String]) -> Bool {
        fragments.contains { host.contains($0) }
    }
}
