import Foundation

public enum AssetSources {
    public static let dictionaryCommit = URL(string: "https://api.github.com/repos/e11isei/souchastnik-ios/commits/main")!
    public static let repository = URL(string: "https://github.com/e11isei/souchastnik-ios/tree/main/Data/StarterPack")!
    public static let modelPage = URL(string: "https://huggingface.co/ggml-org/Qwen3.5-0.8B-GGUF")!
    public static let model = RemoteModel(
        url: URL(string: "https://huggingface.co/ggml-org/Qwen3.5-0.8B-GGUF/resolve/8fea620810c4afa23dd6443f999a48574c1611a3/Qwen3.5-0.8B-Q4_0.gguf")!,
        byteCount: 563_036_064,
        sha256: "57d1997790d1744fba5b40a7317df71ea5e2acee28c47e78f0cce39c0703f8cf"
    )

    public static func dictionaryFile(_ name: String, revision: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/e11isei/souchastnik-ios/\(revision)/Data/StarterPack/\(name)")!
    }
}

public struct RemoteModel: Sendable {
    public let url: URL
    public let byteCount: Int64
    public let sha256: String

    public init(url: URL, byteCount: Int64, sha256: String) {
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum AssetProgress: Sendable {
    case downloading(received: Int64, total: Int64)
    case verifying
}

public enum AssetError: LocalizedError {
    case http(Int)
    case invalidResponse
    case tooLarge
    case invalidRevision
    case wrongSize
    case checksum
    case invalidGGUF

    public var errorDescription: String? {
        switch self {
        case .http(let code): "Сервер вернул HTTP \(code). Повторите загрузку позже."
        case .invalidResponse: "Не удалось получить файл по HTTPS."
        case .tooLarge: "Сервер прислал файл больше допустимого размера."
        case .invalidRevision: "GitHub вернул некорректную версию словаря."
        case .wrongSize: "Модель скачалась не полностью или имеет неверный размер."
        case .checksum: "Контрольная сумма модели не совпадает. Файл не установлен."
        case .invalidGGUF: "Скачанный файл не является GGUF-моделью."
        }
    }
}
