import Foundation

public enum HARLoaderError: LocalizedError {
    case unreadableFile(String)
    case invalidHAR(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "Unable to read HAR file at \(path)"
        case .invalidHAR(let reason):
            return "Unable to decode HAR content: \(reason)"
        }
    }
}

public enum HARLoader {
    public static func load(from fileURL: URL) throws -> HARArchive {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw HARLoaderError.unreadableFile(fileURL.path)
        }

        let decoder = JSONDecoder()

        do {
            return try decoder.decode(HARArchive.self, from: data)
        } catch {
            throw HARLoaderError.invalidHAR(error.localizedDescription)
        }
    }
}
