import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @Environment(AppState.self) private var state
    @State private var importFolder = false
    @State private var importModel = false
    @State private var confirmRemoval = false
    @State private var query = ""

    private var articles: [Article] {
        let all = state.pack?.articles.articles ?? []
        guard !query.isEmpty else { return all }
        return all.filter { "\($0.code) \($0.act) \($0.title)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            AssetDownloadView()
            Section("Пакет словарей") {
                if let pack = state.pack {
                    LabeledContent("Статей", value: "\(pack.articles.articles.count)")
                    LabeledContent("Групп триггеров", value: "\(pack.triggers.groups.count)")
                    LabeledContent("Записей маркировки", value: "\(pack.markers?.entries.count ?? 0)")
                } else {
                    ContentUnavailableView("Словари не установлены", systemImage: "books.vertical", description: Text("Оригинальные данные отсутствуют в публичном репозитории. Приложение не подставляет выдуманный справочник."))
                }
                Button("Обновить словари из репозитория", systemImage: "arrow.clockwise") {
                    state.downloadDictionary(useRepository: true)
                }.disabled(state.isBusy)
                Link("Источник словарей", destination: AssetSources.repository)
                Button("Импортировать папку словарей", systemImage: "folder.badge.plus") { importFolder = true }
                    .disabled(state.isBusy)
                Text("Обязательно: articles.json, triggers.json, judge.txt. Необязательно: agents.json и examples.json. Форматы совместимы с исходным проектом.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Локальная модель") {
                Label(state.modelInstalled ? "GGUF-файл установлен" : "Модель не установлена", systemImage: "cpu")
                Button("Импортировать GGUF-файл", systemImage: "square.and.arrow.down") { importModel = true }
                    .disabled(state.isBusy)
                if state.modelInstalled {
                    Button("Удалить модель", role: .destructive) { confirmRemoval = true }.disabled(state.isBusy)
                }
                Text("Qwen3.5-0.8B Q4_0 скачивается автоматически с Hugging Face, около 563 МБ. Перед установкой проверяются размер файла и SHA-256. Готовая модель используется повторно без скачивания.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Источник модели · Apache 2.0", destination: AssetSources.modelPage)
            }
            if state.importing {
                Section { ProgressView("Импорт данных…") }
            }
            if state.pack != nil {
                Section("Статьи из загруженного справочника") {
                    ForEach(articles) { article in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ст. \(article.code) \(article.act)").font(.headline)
                            Text(article.title)
                            Text(article.penalty).font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Словари и ИИ")
        .searchable(text: $query, prompt: "Код или название статьи")
        .fileImporter(isPresented: $importFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await state.importDictionary(url) }
            case .failure(let error): state.message = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importModel, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case .success(let url): Task { await state.importModel(url) }
            case .failure(let error): state.message = error.localizedDescription
            }
        }
        .confirmationDialog("Удалить локальную модель? Автозагрузка отключится до нажатия «Скачать модель».", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Удалить модель", role: .destructive) { Task { await state.removeModel() } }
        }
    }
}
