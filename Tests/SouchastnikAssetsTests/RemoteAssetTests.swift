import XCTest
import CryptoKit
@testable import SouchastnikAssets

private actor StubDownloader: AssetDownloading {
    let payloads: [String: Data]
    var paths: [String] = []
    var temporaryFiles: [URL] = []
    init(_ payloads: [String: Data]) { self.payloads = payloads }

    func download(_ url: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try Task.checkCancellation()
        paths.append(url.path)
        guard let data = payloads[url.lastPathComponent] else { throw AssetError.http(404) }
        if data.count > maximumBytes { throw AssetError.tooLarge }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        temporaryFiles.append(file)
        progress(Int64(data.count), Int64(data.count))
        return file
    }
}

final class RemoteAssetTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)
    private var fixture: [String: Data] {
        [
            "main": "{\"sha\":\"\(revision)\"}",
            "articles.json": #"{"articles":[{"code":"DEMO-1","act":"demo","title":"demo","penalty":"demo","severity":1}]}"#,
            "triggers.json": #"{"groups":[{"words":["demo"],"codes":["DEMO-1"]}]}"#,
            "agents.json": #"{"agents":[],"services":[]}"#,
            "examples.json": #"{"shots":{}}"#,
            "judge.txt": "Choose a code or none.\n@@TABLE@@"
        ].mapValues { Data($0.utf8) }
    }

    func testDictionaryUsesSingleCommitAndCleansTemporaryFiles() async throws {
        let stub = StubDownloader(fixture)
        let result = try await RemoteAssetService(downloader: stub).dictionary(previousRevision: nil)
        XCTAssertEqual(result?.revision, revision)
        XCTAssertEqual(result?.pack.match("demo").codes, ["DEMO-1"])
        let paths = await stub.paths
        XCTAssertEqual(paths.count, 6)
        XCTAssertTrue(paths.dropFirst().allSatisfy { $0.contains("/\(revision)/Data/StarterPack/") })
        for url in await stub.temporaryFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testUnchangedRevisionDoesNotDownloadAgain() async throws {
        let stub = StubDownloader(fixture)
        let result = try await RemoteAssetService(downloader: stub).dictionary(previousRevision: revision)
        XCTAssertNil(result)
        let paths = await stub.paths
        XCTAssertEqual(paths.count, 1)
    }

    func testPartialDictionaryNeverProducesInstallablePackage() async throws {
        var files = fixture
        files.removeValue(forKey: "examples.json")
        let stub = StubDownloader(files)
        do {
            _ = try await RemoteAssetService(downloader: stub).dictionary(previousRevision: nil)
            XCTFail("Incomplete dictionary must not be returned")
        } catch {}
        for url in await stub.temporaryFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testInvalidDictionaryDoesNotPassValidation() async throws {
        var files = fixture
        files["triggers.json"] = Data(#"{"groups":[{"words":["demo"],"codes":["UNKNOWN"]}]}"#.utf8)
        do {
            _ = try await RemoteAssetService(downloader: StubDownloader(files)).dictionary(previousRevision: nil)
            XCTFail("Unknown article must be rejected")
        } catch {}
    }

    func testInvalidCommitRejectedBeforeFileRequests() async throws {
        let stub = StubDownloader(["main": Data(#"{"sha":"../../main"}"#.utf8)])
        do {
            _ = try await RemoteAssetService(downloader: stub).dictionary(previousRevision: nil)
            XCTFail("Invalid revision accepted")
        } catch {}
        let paths = await stub.paths
        XCTAssertEqual(paths.count, 1)
    }

    func testModelSizeMagicAndHash() async throws {
        let data = Data("GGUFsynthetic model verification fixture".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let model = RemoteModel(url: URL(string: "https://example.com/model.gguf")!, byteCount: Int64(data.count), sha256: hash)
        let stub = StubDownloader(["model.gguf": data])
        let file = try await RemoteAssetService(downloader: stub).model(model) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertThrowsError(try RemoteAssetService.verifyModel(at: file, descriptor: RemoteModel(url: model.url, byteCount: 1, sha256: hash)))
        XCTAssertThrowsError(try RemoteAssetService.verifyModel(at: file, descriptor: RemoteModel(url: model.url, byteCount: model.byteCount, sha256: String(repeating: "0", count: 64))))
    }

    func testBadHashRemovesFailedDownload() async throws {
        let data = Data("GGUFwrong content".utf8)
        let stub = StubDownloader(["model.gguf": data])
        let descriptor = RemoteModel(url: URL(string: "https://example.com/model.gguf")!, byteCount: Int64(data.count), sha256: "wrong")
        do {
            _ = try await RemoteAssetService(downloader: stub).model(descriptor) { _ in }
            XCTFail("Bad checksum accepted")
        } catch {}
        for url in await stub.temporaryFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testHTMLCannotBeInstalledAsModel() async throws {
        let data = Data("<html>Not a GGUF</html>".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let stub = StubDownloader(["model.gguf": data])
        do {
            _ = try await RemoteAssetService(downloader: stub).model(RemoteModel(url: URL(string: "https://example.com/model.gguf")!, byteCount: Int64(data.count), sha256: hash)) { _ in }
            XCTFail("HTML accepted as a model")
        } catch {}
    }

    func testHTTPURLRejected() async throws {
        do {
            _ = try await HTTPAssetDownloader().download(URL(string: "http://example.com/model")!, maximumBytes: 100) { _, _ in }
            XCTFail("Cleartext HTTP accepted")
        } catch {}
    }

    func testCancelledTransferDoesNotReturnAModel() async throws {
        struct DelayedDownloader: AssetDownloading {
            func download(_ url: URL, maximumBytes: Int64,
                          progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
                try await Task.sleep(for: .seconds(30))
                throw AssetError.invalidResponse
            }
        }
        let task = Task {
            try await RemoteAssetService(downloader: DelayedDownloader()).model { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled download returned a file")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRealDownloadsWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SOUCHASTNIK_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Opt-in network check downloads 563 MB")
        }
        let service = RemoteAssetService()
        let dictionary = try await service.dictionary(previousRevision: nil)
        XCTAssertNotNil(dictionary)
        let file = try await service.model { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(AssetSources.model.byteCount))
    }
}
