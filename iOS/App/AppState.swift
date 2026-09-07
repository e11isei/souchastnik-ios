import SwiftUI

@MainActor @Observable
final class AppState {
    var pack: DictionaryPack?
    var message: String?
    var modelInstalled = ModelStore.installed
    var importing = false
    let judge = LocalJudge()
    private let modelStore = ModelStore()
    private var didBootstrap = false

    init() {}

    /// Runs after the first SwiftUI frame. File and App Group work must not
    /// happen in App.init: a failed entitlement or a slow container lookup
    /// should never leave the launch screen looking like a frozen black view.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        reload()
        if pack == nil {
            // Install the bundled starter pack only on a clean install. A
            // user's imported package in the App Group always wins.
            do {
                let starter = try DictionaryPack(bundle: .main)
                try SharedStore.save(starter)
                pack = starter
                message = "Демонстрационные словари установлены автоматически. Замените их своими данными во вкладке «Словари»."
            } catch {
                message = "Стартовый пакет не установлен: \(error.localizedDescription)"
            }
        }
        do {
            if try await modelStore.installBundledIfNeeded() {
                modelInstalled = true
                message = "Локальная GGUF-модель установлена автоматически."
            }
        } catch {
            // A malformed optional bundled model must not hide the UI or
            // replace an already imported model.
            if !modelInstalled { message = "Модель не установлена: \(error.localizedDescription)" }
        }
    }
    func reload() {
        do { pack = try SharedStore.loadPack() }
        catch { message = error.localizedDescription }
        modelInstalled = ModelStore.installed
    }

    func importDictionary(_ url: URL) async {
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
            message = "Словари импортированы. Переоткройте клавиатуру, чтобы применить изменения."
        } catch { message = error.localizedDescription }
    }

    func importModel(_ url: URL) async {
        importing = true
        defer { importing = false }
        await judge.unload()
        do {
            try await modelStore.importModel(from: url)
            modelInstalled = true
            message = "GGUF импортирован. Совместимость модели будет проверена при первом ИИ-разборе."
        } catch { message = error.localizedDescription }
    }

    func removeModel() async {
        importing = true
        defer { importing = false }
        await judge.unload()
        do { try await modelStore.remove(); modelInstalled = false }
        catch { message = error.localizedDescription }
    }
}
