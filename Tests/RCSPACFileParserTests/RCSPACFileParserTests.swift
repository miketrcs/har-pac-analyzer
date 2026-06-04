import Testing
@testable import RCSPACFileParser

@Test
func pacParserFindsDNSDomainRules() {
    let text = #"""
    function FindProxyForURL(url, host) {
      if (
        dnsDomainIs(host, ".vertexsmb.com") ||
        dnsDomainIs(host, ".apple-mapkit.com")
      ) {
        return "DIRECT";
      }
      return "PROXY proxy.example.com:8080";
    }
    """#

    let rules = PACParser.parseRules(from: text)
    #expect(rules.count == 2)
    #expect(rules.map(\.pattern).contains(".vertexsmb.com"))
    #expect(rules.map(\.pattern).contains(".apple-mapkit.com"))
}

@Test
func analyzerMarksMissingPACHosts() throws {
    let har = HARArchive(
        log: HARLog(
            version: "1.2",
            creator: HARCreator(name: "Test", version: "1.0", comment: nil),
            browser: HARCreator(name: "Chrome", version: "1.0", comment: nil),
            pages: nil,
            entries: [
                HAREntry(
                    pageref: nil,
                    startedDateTime: "2026-04-01T10:00:00Z",
                    time: 4000,
                    request: HARRequest(
                        method: "GET",
                        url: "https://cdn.vertexsmb.com/app.js",
                        httpVersion: "HTTP/2",
                        cookies: nil,
                        headers: nil,
                        queryString: nil,
                        postData: nil,
                        headersSize: 120,
                        bodySize: 0,
                        comment: nil
                    ),
                    response: HARResponse(
                        status: 403,
                        statusText: "Forbidden",
                        httpVersion: "HTTP/2",
                        cookies: nil,
                        headers: nil,
                        content: HARContent(size: 100, compression: nil, mimeType: "text/html", text: nil, encoding: nil, comment: nil),
                        redirectURL: nil,
                        headersSize: 120,
                        bodySize: 100,
                        comment: nil
                    ),
                    cache: nil,
                    timings: HARTimings(blocked: 0, dns: 1200, connect: 100, send: 20, wait: 3200, receive: 40, ssl: 60, comment: nil),
                    serverIPAddress: nil,
                    connection: nil,
                    comment: nil
                )
            ],
            comment: nil
        )
    )

    let pac = PACAnalysis(
        rules: [PACRule(kind: .dnsDomainIs, pattern: ".allowed.example.com", sourceLine: "")],
        rawText: ""
    )

    let report = HARAnalyzer.analyze(archive: har, pac: pac)
    #expect(report.unmatchedHosts == ["cdn.vertexsmb.com"])
    #expect(report.blockedCandidates.count == 1)
}

@Test
func nonStandardPortsAreDetected() {
    let makeEntry: (String) -> HAREntry = { url in
        HAREntry(
            pageref: nil, startedDateTime: "2026-06-01T10:00:00Z", time: 50,
            request: HARRequest(method: "GET", url: url, httpVersion: "HTTP/2",
                cookies: nil, headers: nil, queryString: nil, postData: nil,
                headersSize: 100, bodySize: 0, comment: nil),
            response: HARResponse(status: 200, statusText: "OK", httpVersion: "HTTP/2",
                cookies: nil, headers: nil,
                content: HARContent(size: 100, compression: nil, mimeType: "application/json",
                    text: nil, encoding: nil, comment: nil),
                redirectURL: nil, headersSize: 100, bodySize: 100, comment: nil),
            cache: nil, timings: nil, serverIPAddress: nil, connection: nil, comment: nil
        )
    }
    let har = HARArchive(log: HARLog(
        version: "1.2",
        creator: HARCreator(name: "Test", version: "1.0", comment: nil),
        browser: nil, pages: nil,
        entries: [
            makeEntry("https://api.example.com/data"),        // standard 443
            makeEntry("https://api.example.com:8443/secure"), // non-standard
            makeEntry("http://legacy.example.com:8080/old"),  // non-standard
        ],
        comment: nil
    ))

    let report = HARAnalyzer.analyze(archive: har)

    // NormalizedURL port extraction
    #expect(NormalizedURL(rawURL: "https://api.example.com:8443/x").port == 8443)
    #expect(NormalizedURL(rawURL: "https://api.example.com:8443/x").isNonStandardPort == true)
    #expect(NormalizedURL(rawURL: "https://api.example.com/x").isNonStandardPort == false)
    #expect(NormalizedURL(rawURL: "http://h.com:80/x").isNonStandardPort == false)

    // portSummaries built correctly
    let nonStandard = report.portSummaries.filter { !$0.isStandard }
    #expect(nonStandard.count == 2)
    #expect(nonStandard.map(\.port).contains(8443))
    #expect(nonStandard.map(\.port).contains(8080))

    // port is correctly populated on AnalyzedRequest
    let req8443 = report.requests.first(where: { $0.url.contains("8443") })
    #expect(req8443 != nil)
    #expect(req8443?.port == 8443)
    #expect(req8443?.isNonStandardPort == true)

    let req8080 = report.requests.first(where: { $0.url.contains("8080") })
    #expect(req8080?.port == 8080)
    #expect(req8080?.isNonStandardPort == true)

    // standard port request has no port set
    let reqStd = report.requests.first(where: { $0.url == "https://api.example.com/data" })
    #expect(reqStd?.port == nil)
    #expect(reqStd?.isNonStandardPort == false)

    // non-standard port requests can be filtered directly from AnalyzedRequest
    let nonStandardRequests = report.requests.filter { $0.isNonStandardPort }
    #expect(nonStandardRequests.count == 2)
}

@Test
func trackerDatabaseClassifiesKnownDomains() {
    // Exact host lookup
    let ga = TrafficClassifier.classify(host: "google-analytics.com")
    #expect(ga.category == .analytics)
    #expect(ga.criticality == .optional)

    let dc = TrafficClassifier.classify(host: "doubleclick.net")
    #expect(dc.category == .ads)
    #expect(dc.criticality == .optional)

    // Subdomain lookup falls through to parent domain in database
    let sub = TrafficClassifier.classify(host: "stats.g.doubleclick.net")
    #expect(sub.criticality == .optional)

    // CDN domain is required
    let cf = TrafficClassifier.classify(host: "cloudflare.com")
    #expect(cf.category == .cdnStatic)
    #expect(cf.criticality == .required)
}

@Test
func domainNotFlaggedWhenAllSubdomainsArePACCovered() {
    // cdn.example.com and cdn2.example.com are both in the PAC file.
    // example.com should NOT appear in unmatchedDomains — the bare root is
    // never actually requested, and every observed host is already covered.
    let makeEntry: (String) -> HAREntry = { url in
        HAREntry(
            pageref: nil,
            startedDateTime: "2026-04-01T10:00:00Z",
            time: 50,
            request: HARRequest(method: "GET", url: url, httpVersion: "HTTP/2",
                cookies: nil, headers: nil, queryString: nil, postData: nil,
                headersSize: 100, bodySize: 0, comment: nil),
            response: HARResponse(status: 200, statusText: "OK", httpVersion: "HTTP/2",
                cookies: nil, headers: nil,
                content: HARContent(size: 200, compression: nil, mimeType: "application/javascript", text: nil, encoding: nil, comment: nil),
                redirectURL: nil, headersSize: 100, bodySize: 200, comment: nil),
            cache: nil, timings: nil, serverIPAddress: nil, connection: nil, comment: nil
        )
    }

    let har = HARArchive(log: HARLog(
        version: "1.2",
        creator: HARCreator(name: "Test", version: "1.0", comment: nil),
        browser: nil,
        pages: nil,
        entries: [
            makeEntry("https://cdn.example.com/app.js"),
            makeEntry("https://cdn2.example.com/bundle.js")
        ],
        comment: nil
    ))

    let pac = PACAnalysis(rules: [
        PACRule(kind: .dnsDomainIs, pattern: ".cdn.example.com", sourceLine: ""),
        PACRule(kind: .dnsDomainIs, pattern: ".cdn2.example.com", sourceLine: "")
    ], rawText: "")

    let report = HARAnalyzer.analyze(archive: har, pac: pac)
    #expect(!report.unmatchedDomains.contains("example.com"),
            "example.com should not be flagged — all its observed hosts are already PAC-covered")
    #expect(report.matchedDomains.contains("example.com"),
            "example.com should be considered matched since all its hosts have PAC rules")
}

@Test
func classifierSeparatesRequiredAndOptionalTraffic() {
    let cdn = TrafficClassifier.classify(host: "du11hjcvx0uqb.cloudfront.net")
    let telemetry = TrafficClassifier.classify(host: "relay-iad.sentry.insops.net")
    let ads = TrafficClassifier.classify(host: "tpc.googlesyndication.com")

    #expect(cdn.category == .cdnStatic)
    #expect(cdn.criticality == .required)
    #expect(telemetry.category == .telemetry)
    #expect(telemetry.criticality == .optional)
    #expect(ads.category == .ads)
    #expect(ads.criticality == .optional)
}
