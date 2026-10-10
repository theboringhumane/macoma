import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Only pinned upstream URLs are accepted. The delegate stops oversized responses
/// while receiving them, rather than checking after an unbounded allocation.
private final class BoundedWallpaperDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var bytes = Data()
    private let limit: Int
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?

    init(limit: Int) { self.limit = limit }

    func run(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.urlCache = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            session.dataTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Pinned raw files require no redirects. Reject rather than change provenance.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel)
            finish(.failure(MacarchyAppearanceError("The wallpaper server rejected the request or the image exceeds the 8 MiB limit.")))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard continuation != nil else { return }
        guard bytes.count <= limit - data.count else {
            dataTask.cancel()
            finish(.failure(MacarchyAppearanceError("The wallpaper download exceeds the 8 MiB limit.")))
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(bytes)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
        session?.invalidateAndCancel()
        session = nil
    }
}

actor MacarchyWallpaperCache {
    static let maximumDownloadBytes = 8 * 1024 * 1024
    static let maximumImportBytes = 32 * 1024 * 1024
    private let directory: URL
    private let preparedDirectory: URL
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(directory: URL = MacarchyAppearancePaths.cache,
         preparedDirectory: URL = MacarchyAppearancePaths.support.appendingPathComponent("Wallpapers", isDirectory: true)) {
        self.directory = directory
        self.preparedDirectory = preparedDirectory
    }

    func image(for wallpaper: MacarchyWallpaper) async throws -> URL {
        guard wallpaper.isValid else { throw MacarchyAppearanceError("The wallpaper catalog entry is invalid.") }
        if let task = inFlight[wallpaper.id] { return try await task.value }
        let task = Task { try await self.fetch(wallpaper) }
        inFlight[wallpaper.id] = task
        defer { inFlight[wallpaper.id] = nil }
        return try await task.value
    }

    private func fetch(_ wallpaper: MacarchyWallpaper) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(wallpaper.gitBlobSHA + ".image")
        if (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) == wallpaper.bytes,
           let data = try? Data(contentsOf: destination), Self.matches(data, wallpaper) {
            try Self.validateImage(data)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }
        let data = try await BoundedWallpaperDownload(limit: Self.maximumDownloadBytes).run(wallpaper.url)
        guard Self.matches(data, wallpaper) else {
            throw MacarchyAppearanceError("The downloaded image does not match its pinned source. Nothing was applied.")
        }
        try Self.validateImage(data)
        try data.write(to: destination, options: .atomic)
        try trimCache(keeping: destination)
        return destination
    }

    static func matches(_ data: Data, _ wallpaper: MacarchyWallpaper) -> Bool {
        guard data.count == wallpaper.bytes else { return false }
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        let hash = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        return hash == wallpaper.gitBlobSHA
    }

    static func validateImage(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= 20_000, height.int64Value <= 20_000,
              width.int64Value * height.int64Value <= 80_000_000 else {
            throw MacarchyAppearanceError("Choose a readable image up to 80 megapixels and 20,000 pixels per side.")
        }
    }

    static func thumbnail(at url: URL, maximumSize: Int = 720) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw MacarchyAppearanceError("This image could not be decoded.") }
        return image
    }

    func preview(at url: URL) throws -> CGImage { try Self.thumbnail(at: url) }

    /// Keep applied files outside the evictable download cache. Convert through
    /// ImageIO so NSWorkspace receives a conventional JPEG, including for WebP.
    func prepareForDesktop(_ url: URL) throws -> URL {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maximumImportBytes else {
            throw MacarchyAppearanceError("Choose an image smaller than 32 MiB.")
        }
        let data = try Data(contentsOf: url)
        try Self.validateImage(data)
        let prepared = preparedDirectory
        if url.deletingLastPathComponent().standardizedFileURL == prepared.standardizedFileURL {
            return url
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        let output = prepared.appendingPathComponent(digest + ".jpg")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let image = try Self.thumbnail(at: url, maximumSize: 8192)
        let encoded = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MacarchyAppearanceError("The desktop image could not be prepared.")
        }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw MacarchyAppearanceError("The desktop image could not be encoded.") }
        guard encoded.length <= Self.maximumImportBytes else { throw MacarchyAppearanceError("The prepared image exceeds 32 MiB. Choose a smaller image.") }
        try (encoded as Data).write(to: output, options: .atomic)
        return output
    }

    private func trimCache(keeping current: URL) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension == "image" }
            .compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where total > 64 * 1024 * 1024 && entry.0 != current {
            try FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}
