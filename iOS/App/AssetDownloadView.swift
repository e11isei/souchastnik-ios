import SwiftUI

struct AssetDownloadView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section("Автоматическая установка") {
            downloadRow(state.dictionaryIsManual ? "Ваш импортированный словарь" : "Словари из GitHub", state: state.dictionaryDownload)
            if let error = state.dictionaryDownload.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Повторить загрузку словаря") { state.downloadDictionary(useRepository: true) }
            }
            if state.isDemoDictionary {
                Text("В репозитории пока демонстрационный словарь. Его записи не являются реальными статьями закона.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            downloadRow("Модель Qwen3.5 · 563 МБ", state: state.modelDownload)
            if let error = state.modelDownload.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if state.modelDownload.isRunning {
                Button("Отменить загрузку модели", role: .cancel) { state.cancelModelDownload() }
            } else if !state.modelInstalled {
                Button("Скачать модель") { state.downloadModel() }
            }
            Text("Интернет нужен для скачивания файлов. После установки разбор работает на устройстве. При уходе в фон незавершённая загрузка приостанавливается, при возвращении начинается заново.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func downloadRow(_ title: String, state: DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if case .ready = state { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            switch state {
            case .downloading(let received, let total):
                if total > 0 {
                    ProgressView(value: min(Double(received) / Double(total), 1))
                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .decimal)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else { ProgressView("Проверка и загрузка словарей…") }
            case .verifying: ProgressView("Проверка файла и установка…")
            case .paused: Text("Загрузка продолжится при возвращении в приложение").font(.caption)
            case .failed: Text("Не удалось скачать").font(.caption).foregroundStyle(.secondary)
            case .idle: Text("Ещё не скачано").font(.caption).foregroundStyle(.secondary)
            case .ready: EmptyView()
            }
        }.accessibilityElement(children: .combine)
    }
}
