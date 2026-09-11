import Foundation

public protocol AssetDownloading: Sendable {
    /// Caller owns the returned temporary file and must remove it.
    func download(_ url: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
}

/// Only public asset GETs are supported; there is no text or inference request.
public struct HTTPAssetDownloader: AssetDownloading {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }

    public func download(_ url: URL, maximumBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard url.scheme == "https" else { throw AssetError.invalidResponse }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("Souchastnik-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let delegate = TransferDelegate(limit: maximumBytes, progress: progress)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        do {
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url?.scheme == "https" else {
                throw AssetError.invalidResponse
            }
            guard response.statusCode == 200 else { throw AssetError.http(response.statusCode) }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= maximumBytes else { throw AssetError.tooLarge }
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

private final class TransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let progress: @Sendable (Int64, Int64) -> Void

    init(limit: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.limit = limit
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
