import Foundation

public struct HARArchive: Decodable, Sendable {
    public let log: HARLog
}

public struct HARLog: Decodable, Sendable {
    public let version: String?
    public let creator: HARCreator?
    public let browser: HARCreator?
    public let pages: [HARPage]?
    public let entries: [HAREntry]
    public let comment: String?
}

public struct HARCreator: Decodable, Sendable {
    public let name: String
    public let version: String
    public let comment: String?
}

public struct HARPage: Decodable, Sendable {
    public let startedDateTime: String?
    public let id: String
    public let title: String?
    public let pageTimings: HARPageTimings?
    public let comment: String?
}

public struct HARPageTimings: Decodable, Sendable {
    public let onContentLoad: Double?
    public let onLoad: Double?
    public let comment: String?
}

public struct HAREntry: Decodable, Sendable {
    public let pageref: String?
    public let startedDateTime: String
    public let time: Double?
    public let request: HARRequest
    public let response: HARResponse
    public let cache: HARCache?
    public let timings: HARTimings?
    public let serverIPAddress: String?
    public let connection: String?
    public let comment: String?
}

public struct HARRequest: Decodable, Sendable {
    public let method: String
    public let url: String
    public let httpVersion: String?
    public let cookies: [HARNamedValue]?
    public let headers: [HARNamedValue]?
    public let queryString: [HARNamedValue]?
    public let postData: HARPostData?
    public let headersSize: Int?
    public let bodySize: Int?
    public let comment: String?
}

public struct HARResponse: Decodable, Sendable {
    public let status: Int
    public let statusText: String?
    public let httpVersion: String?
    public let cookies: [HARNamedValue]?
    public let headers: [HARNamedValue]?
    public let content: HARContent?
    public let redirectURL: String?
    public let headersSize: Int?
    public let bodySize: Int?
    public let comment: String?
}

public struct HARNamedValue: Decodable, Sendable {
    public let name: String
    public let value: String?
    public let comment: String?
}

public struct HARPostData: Decodable, Sendable {
    public let mimeType: String?
    public let params: [HARPostParam]?
    public let text: String?
    public let comment: String?
}

public struct HARPostParam: Decodable, Sendable {
    public let name: String
    public let value: String?
    public let fileName: String?
    public let contentType: String?
    public let comment: String?
}

public struct HARContent: Decodable, Sendable {
    public let size: Int?
    public let compression: Int?
    public let mimeType: String?
    public let text: String?
    public let encoding: String?
    public let comment: String?
}

public struct HARCache: Decodable, Sendable {
    public let beforeRequest: HARCacheState?
    public let afterRequest: HARCacheState?
    public let comment: String?
}

public struct HARCacheState: Decodable, Sendable {
    public let expires: String?
    public let lastAccess: String?
    public let eTag: String?
    public let hitCount: Int?
    public let comment: String?
}

public struct HARTimings: Decodable, Sendable {
    public let blocked: Double?
    public let dns: Double?
    public let connect: Double?
    public let send: Double?
    public let wait: Double?
    public let receive: Double?
    public let ssl: Double?
    public let comment: String?
}
