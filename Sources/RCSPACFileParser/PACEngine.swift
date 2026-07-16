import Foundation
@preconcurrency import JavaScriptCore

/// Mutable engine state shared between the actor's own methods and the
/// synchronous native callbacks bound into the JSContext. Marked
/// `@unchecked Sendable` because access is only ever synchronous, and only
/// ever happens either (a) from within one of `PACEngine`'s actor-isolated
/// methods, or (b) from a JS-native callback invoked *during* one of those
/// same methods (JavaScriptCore itself is single-threaded per `JSContext`,
/// and the actor's serial executor guarantees only one such method runs at
/// a time) — so this box is never actually touched concurrently, even
/// though the compiler can't prove that statically.
private final class PACEngineState: @unchecked Sendable {
    var dnsCache: [String: String?] = [:]
    var clientIPCache: String?
    var clientIPOverride: String?
    var nowOverride: Date?
    var defaultProxyText = "PROXY proxy.example.com:8080"
    var traceLine: Int?
    var traceValue: JSValue?
    var lastException: String?
    var logLines: [String] = []
}

/// Compiles a PAC file's `FindProxyForURL(url, host)` and actually
/// *executes* it against test hosts/URLs (via JavaScriptCore), rather than
/// statically pattern-matching `dnsDomainIs`/`shExpMatch` literals the way
/// `PACParser` does. Mechanically ported from the sister browser tool
/// (pac-analyzer.html), including its comment/string-safe function
/// location (see `PACSourceInstrumentation.maskCommentsAndStrings`) and
/// per-return line-hit tracing (so callers can show which line matched).
///
/// `actor` (not the `enum`+`static func` style used elsewhere in this
/// package) is required here: `JSContext`/`JSValue` are not `Sendable`, and
/// this type has real session state — a compiled function plus a DNS
/// cache — that must be shared safely between the GUI (`@MainActor`) and
/// the `har-analyzer` CLI target.
public actor PACEngine {
    public nonisolated let defaultLine: Int?
    public nonisolated let lineCount: Int
    public nonisolated let sourceLines: [String]

    private let context: JSContext
    private let findProxyFunction: JSValue
    private let state: PACEngineState

    public init(source: String, clientIPOverride: String? = nil, nowOverride: Date? = nil) throws {
        try self.init(
            source: source,
            clientIPOverride: clientIPOverride,
            nowOverride: nowOverride,
            resolver: { PACNetworking.resolveIPv4(host: $0) },
            interfaceIPProvider: { PACNetworking.primaryLocalIPv4Address() },
            clock: { Date() }
        )
    }

    /// Test seam: injectable DNS resolver / local-IP provider / clock so
    /// tests are deterministic and don't need live network access.
    internal init(
        source: String,
        clientIPOverride: String? = nil,
        nowOverride: Date? = nil,
        resolver: @escaping @Sendable (String) -> String?,
        interfaceIPProvider: @escaping @Sendable () -> String?,
        clock: @escaping @Sendable () -> Date
    ) throws {
        let sourceChars = Array(source)
        let masked = PACSourceInstrumentation.maskCommentsAndStrings(sourceChars)

        guard let paramsStart = PACSourceInstrumentation.locateFindProxyParamsStart(masked) else {
            throw PACEngineError.functionNotFound
        }
        var idx = paramsStart
        var depth = 1
        while depth > 0 {
            guard idx < masked.count else { throw PACEngineError.unbalancedParameterList }
            if masked[idx] == "(" { depth += 1 } else if masked[idx] == ")" { depth -= 1 }
            idx += 1
        }
        while idx < masked.count && masked[idx] != "{" { idx += 1 }
        guard idx < masked.count, masked[idx] == "{" else { throw PACEngineError.missingFunctionBody }
        let bodyOpen = idx
        guard let bodyClose = PACSourceInstrumentation.findMatchingBrace(masked, openIndex: bodyOpen) else {
            throw PACEngineError.unbalancedBraces
        }

        let startLine = sourceChars[0...bodyOpen].filter { $0 == "\n" }.count + 1
        let bodySlice = Array(sourceChars[(bodyOpen + 1)..<bodyClose])
        let instrumented = PACSourceInstrumentation.instrumentReturns(bodySlice, startLine: startLine)

        var newSourceChars = Array(sourceChars[0...bodyOpen])
        newSourceChars.append(contentsOf: instrumented.code)
        newSourceChars.append(contentsOf: sourceChars[bodyClose...])
        let newSource = String(newSourceChars)

        self.lineCount = sourceChars.filter { $0 == "\n" }.count + 1
        self.sourceLines = source.components(separatedBy: "\n")
        self.defaultLine = instrumented.hitLines.max()

        let state = PACEngineState()
        state.clientIPOverride = clientIPOverride
        state.nowOverride = nowOverride
        self.state = state

        guard let ctx = JSContext() else {
            throw PACEngineError.javaScriptLoadError("Could not create a JavaScript context.")
        }
        ctx.exceptionHandler = { [state] _, exception in
            state.lastException = exception?.toString() ?? "Unknown JavaScript error"
        }
        self.context = ctx

        Self.bindHelpers(into: ctx, state: state, resolver: resolver, interfaceIPProvider: interfaceIPProvider, clock: clock)

        state.lastException = nil
        ctx.evaluateScript(newSource)
        if let error = state.lastException {
            throw PACEngineError.javaScriptLoadError(error)
        }

        guard let isFunction = ctx.evaluateScript("typeof FindProxyForURL === 'function'"), isFunction.toBool() else {
            throw PACEngineError.notAFunction
        }
        guard let fn = ctx.objectForKeyedSubscript("FindProxyForURL") else {
            throw PACEngineError.notAFunction
        }
        self.findProxyFunction = fn
    }

    public func evaluate(_ rawInput: String) async -> PACTestResult {
        evaluateOnce(rawInput)
    }

    public func evaluateBatch(_ rawInputs: [String]) async -> [PACTestResult] {
        rawInputs.map { evaluateOnce($0) }
    }

    public func setClientIPOverride(_ ip: String?) async {
        state.clientIPOverride = ip
        state.clientIPCache = nil
    }

    public func setNowOverride(_ date: Date?) async {
        state.nowOverride = date
    }

    public func setDefaultProxyText(_ proxy: String) async {
        state.defaultProxyText = proxy
    }

    public func log() async -> [String] {
        state.logLines
    }

    // MARK: - Internals

    private func evaluateOnce(_ rawInput: String) -> PACTestResult {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let (url, host) = Self.parseTestInput(trimmed)

        state.traceLine = nil
        state.traceValue = nil
        state.lastException = nil

        let result = findProxyFunction.call(withArguments: [url, host])

        if let error = state.lastException {
            return PACTestResult(
                rawInput: rawInput, url: url, host: host, value: nil,
                matchedLine: nil, isFallback: false, error: error, suggestedRule: nil
            )
        }

        let valueString: String?
        if let result, !result.isUndefined {
            valueString = result.isNull ? "null" : result.toString()
        } else {
            valueString = nil
        }

        let matchedLine = state.traceLine
        let isFallback = defaultLine != nil && matchedLine == defaultLine
        let suggestion: String? = isFallback
            ? "if (dnsDomainIs(host, \"\(host)\")) return \"\(state.defaultProxyText)\";"
            : nil

        return PACTestResult(
            rawInput: rawInput, url: url, host: host, value: valueString,
            matchedLine: matchedLine, isFallback: isFallback, error: nil, suggestedRule: suggestion
        )
    }

    /// Mirrors the sister browser tool's `parseInput(raw)`: accepts a bare
    /// host, a `host/path`, or a full URL, and produces the `(url, host)`
    /// pair `FindProxyForURL` expects.
    private static func parseTestInput(_ raw: String) -> (url: String, host: String) {
        let hasScheme = raw.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil
        if hasScheme {
            if let host = URLComponents(string: raw)?.host, !host.isEmpty {
                return (raw, host.lowercased())
            }
            let fallbackHost = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
            return ("http://\(raw)/", fallbackHost.lowercased())
        } else if raw.contains("/") {
            let host = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
            return ("http://\(raw)", host.lowercased())
        } else {
            return ("http://\(raw)/", raw.lowercased())
        }
    }

    private static func bindHelpers(
        into context: JSContext,
        state: PACEngineState,
        resolver: @escaping @Sendable (String) -> String?,
        interfaceIPProvider: @escaping @Sendable () -> String?,
        clock: @escaping @Sendable () -> Date
    ) {
        func resolveCached(_ host: String) -> String? {
            if PACNativeHelpers.isIPv4Literal(host) { return host }
            if let cached = state.dnsCache[host] { return cached }
            let ip = resolver(host)
            state.dnsCache[host] = ip
            return ip
        }

        func effectiveClientIP() -> String {
            if let override = state.clientIPOverride, !override.isEmpty { return override }
            if let cached = state.clientIPCache { return cached }
            let ip = interfaceIPProvider() ?? "127.0.0.1"
            state.clientIPCache = ip
            return ip
        }

        func effectiveNow() -> Date { state.nowOverride ?? clock() }

        func dateComponents(gmt: Bool) -> (year: Int, month: Int, day: Int, weekday: Int, hour: Int, minute: Int, second: Int) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = gmt ? TimeZone(identifier: "UTC")! : TimeZone.current
            let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: effectiveNow())
            return (c.year ?? 1970, (c.month ?? 1) - 1, c.day ?? 1, (c.weekday ?? 1) - 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        }

        let dnsDomainIsBlock: @convention(block) (String, String) -> Bool = { host, domain in
            PACNativeHelpers.dnsDomainIs(host, domain)
        }
        context.setObject(dnsDomainIsBlock, forKeyedSubscript: "dnsDomainIs" as NSString)

        let shExpMatchBlock: @convention(block) (String, String) -> Bool = { str, pattern in
            PACNativeHelpers.shExpMatch(str, pattern)
        }
        context.setObject(shExpMatchBlock, forKeyedSubscript: "shExpMatch" as NSString)

        let isPlainHostNameBlock: @convention(block) (String) -> Bool = { host in
            PACNativeHelpers.isPlainHostName(host)
        }
        context.setObject(isPlainHostNameBlock, forKeyedSubscript: "isPlainHostName" as NSString)

        let localHostOrDomainIsBlock: @convention(block) (String, String) -> Bool = { host, hostdom in
            PACNativeHelpers.localHostOrDomainIs(host, hostdom)
        }
        context.setObject(localHostOrDomainIsBlock, forKeyedSubscript: "localHostOrDomainIs" as NSString)

        let dnsDomainLevelsBlock: @convention(block) (String) -> Int = { host in
            PACNativeHelpers.dnsDomainLevels(host)
        }
        context.setObject(dnsDomainLevelsBlock, forKeyedSubscript: "dnsDomainLevels" as NSString)

        let isResolvableBlock: @convention(block) (String) -> Bool = { host in
            resolveCached(host) != nil
        }
        context.setObject(isResolvableBlock, forKeyedSubscript: "isResolvable" as NSString)

        let isInNetBlock: @convention(block) (String, String, String) -> Bool = { host, pattern, mask in
            let ip = resolveCached(host)
            return PACNativeHelpers.isInNet(host: host, resolvedIP: ip, pattern: pattern, mask: mask)
        }
        context.setObject(isInNetBlock, forKeyedSubscript: "isInNet" as NSString)

        let isInNetExBlock: @convention(block) (String, String) -> Bool = { host, ipPrefix in
            let ip = resolveCached(host)
            return PACNativeHelpers.isInNetEx(resolvedIP: ip, ipPrefix: ipPrefix)
        }
        context.setObject(isInNetExBlock, forKeyedSubscript: "isInNetEx" as NSString)

        let dnsResolveBlock: @convention(block) (String) -> JSValue? = { host in
            guard let ip = resolveCached(host) else { return JSValue(nullIn: context) }
            return JSValue(object: ip, in: context)
        }
        context.setObject(dnsResolveBlock, forKeyedSubscript: "dnsResolve" as NSString)

        let dnsResolveExBlock: @convention(block) (String) -> String = { host in
            resolveCached(host) ?? ""
        }
        context.setObject(dnsResolveExBlock, forKeyedSubscript: "dnsResolveEx" as NSString)

        let myIpAddressBlock: @convention(block) () -> String = {
            effectiveClientIP()
        }
        context.setObject(myIpAddressBlock, forKeyedSubscript: "myIpAddress" as NSString)

        let myIpAddressExBlock: @convention(block) () -> String = {
            effectiveClientIP()
        }
        context.setObject(myIpAddressExBlock, forKeyedSubscript: "myIpAddressEx" as NSString)

        let sortIpAddressListBlock: @convention(block) (String) -> String = { list in
            PACNativeHelpers.sortIPAddressList(list)
        }
        context.setObject(sortIpAddressListBlock, forKeyedSubscript: "sortIpAddressList" as NSString)

        let getClientVersionBlock: @convention(block) () -> String = {
            PACNativeHelpers.getClientVersion()
        }
        context.setObject(getClientVersionBlock, forKeyedSubscript: "getClientVersion" as NSString)

        let alertBlock: @convention(block) (JSValue) -> Void = { message in
            state.logLines.append(message.toString() ?? "")
        }
        context.setObject(alertBlock, forKeyedSubscript: "alert" as NSString)

        let traceBlock: @convention(block) (JSValue, JSValue) -> JSValue = { lineValue, value in
            state.traceLine = Int(lineValue.toInt32())
            state.traceValue = value
            return value
        }
        context.setObject(traceBlock, forKeyedSubscript: "__trace" as NSString)

        let weekdayRangeBlock: @convention(block) () -> Bool = {
            let rawArgs = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            guard !rawArgs.isEmpty else { return false }
            var wd2: String? = rawArgs.count > 1 ? rawArgs[1] : nil
            let gmtArg: String? = rawArgs.count > 2 ? rawArgs[2] : nil
            let useGmt = wd2 == "GMT" || gmtArg == "GMT"
            if wd2 == "GMT" { wd2 = nil }
            let comps = dateComponents(gmt: useGmt)
            return PACNativeHelpers.weekdayRange(day: comps.weekday, wd1: rawArgs[0], wd2: wd2)
        }
        context.setObject(weekdayRangeBlock, forKeyedSubscript: "weekdayRange" as NSString)

        let dateRangeBlock: @convention(block) () -> Bool = {
            var jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            var gmt = false
            if let last = jsArgs.last, last.toString() == "GMT" { gmt = true; jsArgs.removeLast() }
            let comps = dateComponents(gmt: gmt)
            let args: [PACNativeHelpers.DateComponentArg] = jsArgs.map { v in
                v.isNumber ? .number(Int(v.toInt32())) : .text(v.toString() ?? "")
            }
            return PACNativeHelpers.dateRange(args, currentDay: comps.day, currentMonth: comps.month, currentYear: comps.year)
        }
        context.setObject(dateRangeBlock, forKeyedSubscript: "dateRange" as NSString)

        let timeRangeBlock: @convention(block) () -> Bool = {
            var jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            var gmt = false
            if let last = jsArgs.last, last.toString() == "GMT" { gmt = true; jsArgs.removeLast() }
            let comps = dateComponents(gmt: gmt)
            let intArgs = jsArgs.map { Int($0.toInt32()) }
            let secondOfDay = comps.hour * 3600 + comps.minute * 60 + comps.second
            return PACNativeHelpers.timeRange(hour: comps.hour, secondOfDay: secondOfDay, args: intArgs)
        }
        context.setObject(timeRangeBlock, forKeyedSubscript: "timeRange" as NSString)
    }
}
