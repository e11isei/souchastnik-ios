import SwiftUI

enum DownloadState {
    case idle, downloading(received: Int64, total: Int64), verifying, ready, paused, failed(String)
    var isRunning: Bool {
        switch self { case .downloading, .verifying: true; default: false }
    }
    var error: String? { if case .failed(let message) = self { message } else { nil } }
}

@MainActor @Observable
final class AppState {
    var pack: DictionaryPack?
    var message: String?
    var modelInstalled = false
    var importing = false
    var dictionaryDownload = DownloadState.idle
    var modelDownload = DownloadState.idle
    var dictionaryIsManual = false
    var isBusy: Bool { importing || dictionaryDownload.isRunning || modelDownload.isRunning }
    var isDemoDictionary: Bool { pack?.articles.articles.allSatisfy { $0.code.hasPrefix("DEMO-") } == true }
    let judge = LocalJudge()
    private let modelStore = ModelStore()
    private let remote = RemoteAssetService()
    private var didBootstrap = false
    @ObservationIgnored private var dictionaryTask: Task<Void, Never>?
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var dictionaryRequest = UUID()
    @ObservationIgnored private var modelRequest = UUID()
    @ObservationIgnored private var dictionaryUseRepository = false

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        reload()
        dictionaryIsManual = UserDefaults.standard.object(forKey: "dictionaryIsManual") as? Bool
            ?? (pack != nil && !isDemoDictionary)
        if dictionaryIsManual { dictionaryDownload = .ready }
        // The bundled fallback permits offline use; it does not skip GitHub.
        if pack == nil {
            do {
                let starter = try DictionaryPack(bundle: .main)
                try SharedStore.save(starter)
                pack = starter
            } catch { dictionaryDownload = .failed(error.localizedDescription) }
        }
        if !dictionaryIsManual { downloadDictionary() }
        if modelInstalled { modelDownload = .ready }
        else if !UserDefaults.standard.bool(forKey: "modelAutoDownloadDisabled") { downloadModel() }
    }

    func reload() {
        do { pack = try SharedStore.loadPack() }
        catch { dictionaryDownload = .failed(error.localizedDescription) }
        modelInstalled = ModelStore.installed
    }

    func resumeDownloads() {
        if !didBootstrap { bootstrap(); return }
        if case .paused = dictionaryDownload { downloadDictionary(useRepository: dictionaryUseRepository) }
        if case .paused = modelDownload { downloadModel() }
    }

    func pauseDownloads() {
        if dictionaryTask != nil {
            dictionaryRequest = UUID()
            dictionaryTask?.cancel(); dictionaryTask = nil
            dictionaryDownload = .paused
        }
        if modelTask != nil {
            modelRequest = UUID()
            modelTask?.cancel(); modelTask = nil
            modelDownload = .paused
        }
    }

    func downloadDictionary(useRepository: Bool = false) {
        guard dictionaryTask == nil, !importing else { return }
        if dictionaryIsManual && !useRepository { return }
        dictionaryUseRepository = useRepository
        dictionaryDownload = .downloading(received: 0, total: 0)
        let id = UUID()
        dictionaryRequest = id
        let previous = useRepository || pack == nil ? nil : UserDefaults.standard.string(forKey: "dictionaryRevision")
        dictionaryTask = Task {
            defer { if dictionaryRequest == id { dictionaryTask = nil } }
            do {
                if let downloaded = try await remote.dictionary(previousRevision: previous) {
                    try Task.checkCancellation()
                    guard dictionaryRequest == id else { return }
                    try SharedStore.save(downloaded.pack)
                    pack = downloaded.pack
                    UserDefaults.standard.set(downloaded.revision, forKey: "dictionaryRevision")
                }
                guard dictionaryRequest == id else { return }
                dictionaryIsManual = false
                UserDefaults.standard.set(false, forKey: "dictionaryIsManual")
                dictionaryDownload = .ready
            } catch {
                guard dictionaryRequest == id else { return }
                dictionaryDownload = Task.isCancelled ? .paused : .failed(error.localizedDescription)
            }
        }
    }

    func downloadModel() {
        guard modelTask == nil, !importing else { return }
        if ModelStore.installed { modelInstalled = true; modelDownload = .ready; return }
        UserDefaults.standard.set(false, forKey: "modelAutoDownloadDisabled")
        modelDownload = .downloading(received: 0, total: AssetSources.model.byteCount)
        let id = UUID()
        modelRequest = id
        modelTask = Task {
            defer { if modelRequest == id { modelTask = nil } }
            do {
                if try await modelStore.installBundledIfNeeded() {
                    guard modelRequest == id else { return }
                    modelInstalled = true; modelDownload = .ready
                    return
                }
                let file = try await remote.model { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.modelRequest == id, self.modelTask != nil else { return }
                        switch update {
                        case .downloading(let received, let total): self.modelDownload = .downloading(received: received, total: total)
                        case .verifying: self.modelDownload = .verifying
                        }
                    }
                }
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard modelRequest == id else { return }
                try await modelStore.installDownloadedModel(from: file)
                guard modelRequest == id else { return }
                modelInstalled = true
                modelDownload = .ready
            } catch {
                guard modelRequest == id else { return }
                modelDownload = Task.isCancelled ? .paused : .failed(error.localizedDescription)
            }
        }
    }

    func cancelModelDownload() {
        modelRequest = UUID()
        modelTask?.cancel(); modelTask = nil
        modelDownload = .idle
        UserDefaults.standard.set(true, forKey: "modelAutoDownloadDisabled")
    }

    func importDictionary(_ url: URL) async {
        guard !isBusy else { return }
        importing = true
        defer { importing = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try DictionaryPack(directory: url)
            }.value
            try SharedStore.save(imported)
            pack = imported
            dictionaryIsManual = true
            UserDefaults.standard.set(true, forKey: "dictionaryIsManual")
            UserDefaults.standard.removeObject(forKey: "dictionaryRevision")
            dictionaryDownload = .ready
            message = "Словари импортированы. Переоткройте клавиатуру, чтобы применить изменения."
        } catch { message = error.localizedDescription }
    }

    func importModel(_ url: URL) async {
        guard !isBusy else { return }
        importing = true
        defer { importing = false }
        await judge.unload()
        do {
            try await modelStore.importModel(from: url)
            modelInstalled = true
            modelDownload = .ready
            message = "GGUF импортирован. Совместимость модели будет проверена при первом ИИ-разборе."
        } catch { message = error.localizedDescription }
    }

    func removeModel() async {
        guard !isBusy else { return }
        cancelModelDownload()
        importing = true
        defer { importing = false }
        await judge.unload()
        do { try await modelStore.remove(); modelInstalled = false }
        catch { message = error.localizedDescription }
    }
}
