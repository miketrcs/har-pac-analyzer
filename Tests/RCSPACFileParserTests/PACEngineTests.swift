import Foundation
import Testing
@testable import RCSPACFileParser

private func testEngine(
    _ source: String,
    resolver: @escaping @Sendable (String) -> String? = { _ in nil },
    interfaceIP: @escaping @Sendable () -> String? = { "10.1.2.3" },
    now: @escaping @Sendable () -> Date = { Date() }
) throws -> PACEngine {
    try PACEngine(source: source, resolver: resolver, interfaceIPProvider: interfaceIP, clock: now)
}

@Test
func engineExecutesRealFunctionNotACommentedOutOldVersion() async throws {
    // Regression test for the exact bug found and fixed in the sister
    // browser tool: a commented-out OLD version of FindProxyForURL sitting
    // above the real one (a common real-world pattern for ops-maintained
    // PAC files that keep prior versions for rollback/reference) must not
    // be mistaken for the real function.
    let source = """
    // Old version kept for reference — DO NOT USE
    // function FindProxyForURL(url, host) {
    //   return "PROXY proxy.example.com:8080";
    // }

    function FindProxyForURL(url, host) {
      if (dnsDomainIs(host, "realcorp.internal")) {
        return "PROXY realproxy.corp.com:3128";
      }
      return "DIRECT";
    }
    """
    let engine = try testEngine(source)
    let result = await engine.evaluate("realcorp.internal")
    #expect(result.error == nil)
    #expect(result.value == "PROXY realproxy.corp.com:3128")
}

@Test
func engineExecutesRealFunctionNotABlockCommentedOldVersion() async throws {
    let source = """
    /*
     * Old version, keep for rollback:
     * function FindProxyForURL(url, host) {
     *   return "PROXY proxy.example.com:8080";
     * }
     */
    function FindProxyForURL(url, host) {
      if (dnsDomainIs(host, "realcorp.internal")) { return "PROXY realproxy.corp.com:3128"; }
      return "DIRECT";
    }
    """
    let engine = try testEngine(source)
    let result = await engine.evaluate("realcorp.internal")
    #expect(result.error == nil)
    #expect(result.value == "PROXY realproxy.corp.com:3128")
}

private func expectedEngineError(_ source: String) -> PACEngineError? {
    do {
        _ = try testEngine(source)
        return nil
    } catch let error as PACEngineError {
        return error
    } catch {
        return nil
    }
}

@Test
func initThrowsWhenFunctionMissing() {
    #expect(expectedEngineError("function notThePacFunction() { return 1; }") == .functionNotFound)
}

@Test
func initThrowsOnUnbalancedParameterList() {
    #expect(expectedEngineError("function FindProxyForURL(url, host { return \"DIRECT\"; }") == .unbalancedParameterList)
}

@Test
func initThrowsOnUnbalancedBraces() {
    #expect(expectedEngineError("function FindProxyForURL(url, host) { return \"DIRECT\";") == .unbalancedBraces)
}

@Test
func initSurfacesJavaScriptLoadError() {
    guard case .javaScriptLoadError? = expectedEngineError("function FindProxyForURL(url, host) { return (; }") else {
        Issue.record("Expected a .javaScriptLoadError")
        return
    }
}

@Test
func shExpMatchGlobSemantics() async throws {
    let source = """
    function FindProxyForURL(url, host) {
      if (shExpMatch(host, "*.example.com")) return "PROXY a:1";
      if (shExpMatch(host, "sub?.example.org")) return "PROXY b:2";
      return "DIRECT";
    }
    """
    let engine = try testEngine(source)
    #expect((await engine.evaluate("www.example.com")).value == "PROXY a:1")
    #expect((await engine.evaluate("sub1.example.org")).value == "PROXY b:2")
    #expect((await engine.evaluate("other.org")).value == "DIRECT")
}

@Test
func dnsDomainIsPreservesNaiveSuffixMatchQuirk() async throws {
    // Intentionally NOT boundary-aware — matches both the PAC spec's own
    // definition and the (tested) browser tool's behavior. Not a bug.
    let source = """
    function FindProxyForURL(url, host) {
      if (dnsDomainIs(host, "example.com")) return "PROXY matched:1";
      return "DIRECT";
    }
    """
    let engine = try testEngine(source)
    let result = await engine.evaluate("evilnotexample.com")
    #expect(result.value == "PROXY matched:1")
}

@Test
func isInNetWithLiteralIPHostNeedsNoResolver() async throws {
    let source = """
    function FindProxyForURL(url, host) {
      if (isInNet(host, "10.0.0.0", "255.0.0.0")) return "DIRECT";
      return "PROXY out:8080";
    }
    """
    let engine = try testEngine(source, resolver: { _ in
        Issue.record("resolver should not be called for a literal IP host")
        return nil
    })
    #expect((await engine.evaluate("10.5.6.7")).value == "DIRECT")
    #expect((await engine.evaluate("192.168.1.1")).value == "PROXY out:8080")
}

@Test
func defaultFallbackLineHeuristicAndClassification() async throws {
    let source = """
    function FindProxyForURL(url, host) {
      if (dnsDomainIs(host, "special.example.com")) {
        return "PROXY special:8080";
      }
      return "PROXY default:8080";
    }
    """
    let engine = try testEngine(source)
    let explicit = await engine.evaluate("special.example.com")
    #expect(explicit.value == "PROXY special:8080")
    #expect(explicit.isFallback == false)

    let fallback = await engine.evaluate("anything-else.com")
    #expect(fallback.value == "PROXY default:8080")
    #expect(fallback.isFallback == true)
    #expect(fallback.matchedLine == engine.defaultLine)
    #expect(fallback.suggestedRule?.contains("dnsDomainIs(host, \"anything-else.com\")") == true)
}

@Test
func weekdayRangeUsesInjectedNow() async throws {
    let source = """
    function FindProxyForURL(url, host) {
      if (weekdayRange("MON", "FRI")) return "PROXY weekday:8080";
      return "PROXY weekend:8080";
    }
    """
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    // 2026-07-15 is a Wednesday.
    let wednesday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
    let weekdayEngine = try testEngine(source, now: { wednesday })
    #expect((await weekdayEngine.evaluate("example.com")).value == "PROXY weekday:8080")

    // 2026-07-18 is a Saturday.
    let saturday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
    let weekendEngine = try testEngine(source, now: { saturday })
    #expect((await weekendEngine.evaluate("example.com")).value == "PROXY weekend:8080")
}
