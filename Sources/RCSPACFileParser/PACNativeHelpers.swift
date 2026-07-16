import Foundation

/// Pure-Swift implementations of the PAC spec's helper functions (the
/// functions a `FindProxyForURL` body calls: `shExpMatch`, `dnsDomainIs`,
/// `isInNet`, `weekdayRange`, etc). No JavaScriptCore dependency — these are
/// plain value-in/value-out functions, ported 1:1 from the already-tested
/// sister browser tool (pac-analyzer.html) so behavior stays consistent
/// with real-world PAC semantics (including a couple of deliberately
/// preserved quirks — see `dnsDomainIs`).
enum PACNativeHelpers {
    // MARK: - String / host matching

    static func shExpMatch(_ str: String, _ pattern: String) -> Bool {
        var re = "^"
        for ch in pattern {
            if ch == "*" {
                re += ".*"
            } else if ch == "?" {
                re += "."
            } else if ".+^${}()|[]\\".contains(ch) {
                re += "\\\(ch)"
            } else {
                re.append(ch)
            }
        }
        re += "$"
        guard let regex = try? NSRegularExpression(pattern: re) else { return false }
        let range = NSRange(str.startIndex..., in: str)
        return regex.firstMatch(in: str, range: range) != nil
    }

    static func isPlainHostName(_ host: String) -> Bool {
        !host.contains(".")
    }

    /// Naive suffix-substring match, intentionally preserved as-is (matches
    /// both the PAC spec's own definition and the web tool's behavior) —
    /// this is NOT boundary-aware, so e.g. `dnsDomainIs("evilnotexample.com",
    /// "example.com")` returns true. That's spec-accurate, not a bug.
    static func dnsDomainIs(_ host: String, _ domain: String) -> Bool {
        guard host.count >= domain.count else { return false }
        return host.hasSuffix(domain)
    }

    static func localHostOrDomainIs(_ host: String, _ hostdom: String) -> Bool {
        host == hostdom || hostdom.hasPrefix(host + ".")
    }

    static func dnsDomainLevels(_ host: String) -> Int {
        host.filter { $0 == "." }.count
    }

    // MARK: - IPv4 helpers

    static func isIPv4Literal(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber) else { return false }
            guard let v = Int(part) else { return false }
            return v >= 0 && v <= 255
        }
    }

    static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt32(part), byte <= 255 else { return nil }
            value = (value << 8) | byte
        }
        return value
    }

    static func isInNet(host: String, resolvedIP: String?, pattern: String, mask: String) -> Bool {
        guard let ip = resolvedIP else { return false }
        guard let ipI = ipv4ToUInt32(ip), let patI = ipv4ToUInt32(pattern), let maskI = ipv4ToUInt32(mask) else {
            return false
        }
        return (ipI & maskI) == (patI & maskI)
    }

    static func isInNetEx(resolvedIP: String?, ipPrefix: String) -> Bool {
        let parts = ipPrefix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), bits >= 0, bits <= 32 else { return false }
        let maskI: UInt32 = bits == 0 ? 0 : (0xFFFF_FFFF << (32 - bits))
        guard let patI = ipv4ToUInt32(String(parts[0])), let ip = resolvedIP, let ipI = ipv4ToUInt32(ip) else {
            return false
        }
        return (ipI & maskI) == (patI & maskI)
    }

    static func sortIPAddressList(_ ipList: String) -> String {
        ipList.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { (ipv4ToUInt32($0) ?? 0) < (ipv4ToUInt32($1) ?? 0) }
            .joined(separator: ";")
    }

    static func getClientVersion() -> String { "1.0" }

    // MARK: - Date/time helpers

    static let weekdayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    static func weekdayIndex(_ s: String) -> Int? {
        weekdayNames.firstIndex(of: s.uppercased())
    }

    static func monthIndex(_ s: String) -> Int? {
        monthNames.firstIndex(of: s.uppercased())
    }

    /// `day` is the already-computed current weekday (0=Sun...6=Sat, in
    /// whichever timezone — GMT or local — the caller selected).
    static func weekdayRange(day: Int, wd1: String, wd2: String?) -> Bool {
        guard let d1 = weekdayIndex(wd1) else { return false }
        guard let wd2 else { return day == d1 }
        guard let d2 = weekdayIndex(wd2) else { return false }
        return d1 <= d2 ? (day >= d1 && day <= d2) : (day >= d1 || day <= d2)
    }

    enum DateComponentArg {
        case number(Int)
        case text(String)
    }

    /// `currentDay`/`currentMonth` (0-indexed, matching JS `getMonth()`)/
    /// `currentYear` are pre-resolved by the caller for the selected
    /// timezone (GMT or local).
    static func dateRange(_ args: [DateComponentArg], currentDay: Int, currentMonth: Int, currentYear: Int) -> Bool {
        func parseSingle(_ a: DateComponentArg) -> (day: Int?, month: Int?, year: Int?) {
            switch a {
            case .number(let n):
                return (n, nil, nil)
            case .text(let s):
                let upper = s.uppercased()
                if let mi = monthIndex(upper) { return (nil, mi, nil) }
                if let y = Int(upper) { return (nil, nil, y) }
                return (nil, nil, nil)
            }
        }
        func toNum(_ a: DateComponentArg) -> Int? {
            switch a {
            case .number(let n):
                return n
            case .text(let s):
                let upper = s.uppercased()
                if let mi = monthIndex(upper) { return mi }
                return Int(upper)
            }
        }

        if args.count == 1 {
            let p = parseSingle(args[0])
            if let d = p.day { return currentDay == d }
            if let m = p.month { return currentMonth == m }
            if let y = p.year { return currentYear == y }
            return false
        }

        let nums = args.map(toNum)
        guard nums.allSatisfy({ $0 != nil }) else { return false }
        let n = nums.map { $0! }

        if args.count >= 6 {
            let (d1, m1, y1, d2, m2, y2) = (n[0], n[1], n[2], n[3], n[4], n[5])
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            func makeDate(year: Int, month: Int, day: Int) -> Date? {
                calendar.date(from: DateComponents(year: year, month: month + 1, day: day))
            }
            guard let cur = makeDate(year: currentYear, month: currentMonth, day: currentDay),
                  let start = makeDate(year: y1, month: m1, day: d1),
                  let end = makeDate(year: y2, month: m2, day: d2) else { return false }
            return cur >= start && cur <= end
        }
        if args.count == 3 {
            let (d1, m1, y1) = (n[0], n[1], n[2])
            return currentDay == d1 && currentMonth == m1 && currentYear == y1
        }
        if args.count == 2 {
            return currentMonth == n[0] || currentYear == n[1]
        }
        return false
    }

    /// `secondOfDay`/hour are pre-resolved by the caller for the selected
    /// timezone. `args` are the raw numeric timeRange arguments (1, 2, or 6
    /// of them, per the PAC spec).
    static func timeRange(hour: Int, secondOfDay: Int, args: [Int]) -> Bool {
        func toSeconds(_ parts: ArraySlice<Int>) -> Int {
            let hh = parts.count > 0 ? parts[parts.startIndex] : 0
            let mm = parts.count > 1 ? parts[parts.startIndex + 1] : 0
            let ss = parts.count > 2 ? parts[parts.startIndex + 2] : 0
            return hh * 3600 + mm * 60 + ss
        }
        if args.count == 1 { return hour == args[0] }
        if args.count == 2 { return hour >= args[0] && hour < args[1] }
        if args.count == 6 {
            let start = toSeconds(args[0..<3])
            let end = toSeconds(args[3..<6])
            return start <= end ? (secondOfDay >= start && secondOfDay <= end) : (secondOfDay >= start || secondOfDay <= end)
        }
        return false
    }
}
