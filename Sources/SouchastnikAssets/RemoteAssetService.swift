import Foundation
import CryptoKit
#if canImport(SouchastnikCore)
import SouchastnikCore
#endif

public struct RemoteDictionary: Sendable {
    public let pack: DictionaryPack
    public let revision: String
}

public struct RemoteAssetService: Sendable {
    private let downloader: any AssetDownloading

    public init(downloader: any AssetDownloading = HTTPAssetDownloader()) {
        self.downloader = downloader
    }

    /// Resolve main once. All five files then come from the same immutable
    /// commit, even if main changes while downloading the package.
    public func dictionary(previousRevision: String?) async throws -> RemoteDictionary? {
        let metadata = try await downloader.download(AssetSources.dictionaryCommit, maximumBytes: 2_000_000) { _, _ in }
        defer { try? FileManager.default.removeItem(at: metadata) }
        struct Commit: Decodable { let sha: String }
        let commit = try JSONDecoder().decode(Commit.self, from: Data(contentsOf: metadata))
        guard commit.sha.count == 40, commit.sha.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw AssetError.invalidRevision
        }
        if commit.sha == previousRevision { return nil }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["articles.json", "triggers.json", "agents.json", "examples.json", "judge.txt"] {
            try Task.checkCancellation()
            let file = try await downloader.download(AssetSources.dictionaryFile(name, revision: commit.sha), maximumBytes: 2_000_000) { _, _ in }
            defer { try? FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(name))
        }
        let pack = try DictionaryPack(directory: folder)
        try Task.checkCancellation()
        // Publication happens in the app only after the entire pack validates.
        return RemoteDictionary(pack: pack, revision: commit.sha)
    }

    /// Returns a verified temporary model, never the installed model path.
    /// The caller owns this URL and must remove it after atomic installation.
    public func model(_ descriptor: RemoteModel = AssetSources.model,
                      progress: @escaping @Sendable (AssetProgress) -> Void) async throws -> URL {
        let file = try await downloader.download(descriptor.url, maximumBytes: descriptor.byteCount) { received, _ in
            progress(.downloading(received: received, total: descriptor.byteCount))
        }
        do {
            progress(.verifying)
            try Self.verifyModel(at: file, descriptor: descriptor)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    public static func verifyModel(at file: URL, descriptor: RemoteModel) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == descriptor.byteCount else { throw AssetError.wrongSize }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else { throw AssetError.invalidGGUF }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == descriptor.sha256 else { throw AssetError.checksum }
        try Task.checkCancellation()
    }
}
