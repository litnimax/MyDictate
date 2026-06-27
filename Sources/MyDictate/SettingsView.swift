import SwiftUI

extension Notification.Name {
    static let settingsChanged = Notification.Name("MyDictate.settingsChanged")
}

struct SettingsView: View {
    @AppStorage("language") private var language: String = "auto"
    @AppStorage("whisperKitModel") private var whisperModel: String = Transcriber.defaultModel

    @AppStorage("llmEnabled") private var llmEnabled: Bool = false
    @AppStorage("llmBaseURL") private var llmBaseURL: String = LLMPostProcessor.defaultBaseURL
    @AppStorage("llmModel") private var llmModel: String = LLMPostProcessor.defaultModel
    @AppStorage("llmPrompt") private var llmPrompt: String = LLMPostProcessor.defaultPrompt
    @AppStorage("glossary") private var glossary: String = Glossary.defaultRules
    @AppStorage("vocabulary") private var vocabulary: String = ""

    @State private var llmModels: [String] = []
    @State private var serverStatus: String = ""

    private let languages: [(String, String)] = [
        ("auto", "Авто-определение"),
        ("ru", "Русский"),
        ("en", "English"),
        ("uk", "Українська"),
        ("pl", "Polski"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
    ]

    // Имена моделей WhisperKit (скачиваются автоматически с Hugging Face).
    private let whisperKitModels: [(String, String)] = [
        ("large-v3-v20240930_turbo", "large-v3-turbo (рекомендую)"),
        ("large-v3", "large-v3 (макс. точность)"),
        ("small", "small (быстрее)"),
        ("base", "base (самая лёгкая)"),
    ]

    // Понятные названия для локальных моделей (сконвертированных вручную).
    private let localModelTitles: [String: String] = [
        "whisper-podlodka-turbo": "podlodka-turbo (рус, локальная)",
    ]

    private var whisperOptions: [String] {
        var list = AppPaths.availableLocalModels() // локальные — первыми
        list.append(contentsOf: whisperKitModels.map { $0.0 })
        if !whisperModel.isEmpty && !list.contains(whisperModel) { list.insert(whisperModel, at: 0) }
        return list
    }

    private func whisperTitle(_ id: String) -> String {
        if let t = localModelTitles[id] { return t }
        return whisperKitModels.first { $0.0 == id }?.1 ?? id
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Триггер:") {
                    Text(TriggerMonitor.title).foregroundColor(.secondary)
                }
                Picker("Язык:", selection: $language) {
                    ForEach(languages, id: \.0) { code, title in
                        Text(title).tag(code)
                    }
                }
            }

            Section("Распознавание (WhisperKit · GPU + Neural Engine)") {
                Picker("Модель:", selection: $whisperModel) {
                    ForEach(whisperOptions, id: \.self) { name in
                        Text(whisperTitle(name)).tag(name)
                    }
                }
                .onChange(of: whisperModel) { _ in
                    NotificationCenter.default.post(name: .settingsChanged, object: nil)
                }
                Text("Модель скачивается автоматически при первом выборе (нужен интернет). Считает на GPU и Neural Engine.")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Section("Частые слова и имена (подсказка распознаванию)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Перечислите через запятую (можно и с новой строки). Передаются в AI-чистку (LM Studio) как подсказка — она исправляет похожие ошибки (напр. «Куля» → «Коля»). Требует включённой AI-обработки ниже.")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $vocabulary)
                        .font(.system(size: 11))
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
            }

            Section("Словарь терминов (нормализация написания)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("По строке: что => на_что. Заменяется надёжно, с учётом русских падежей (напр. «Клоду» → «Claude»). Работает и без AI-обработки.")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $glossary)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
            }

            Section("AI-обработка текста (LM Studio)") {
                Toggle("Чистить текст через LM Studio", isOn: $llmEnabled)

                if llmModels.isEmpty {
                    TextField("Модель:", text: $llmModel)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Модель:", selection: $llmModel) {
                        ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Сервер:", text: $llmBaseURL)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Промпт:").font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $llmPrompt)
                        .font(.system(size: 11))
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }

                HStack(spacing: 8) {
                    Button("Запустить сервер") {
                        _ = LMStudio.startServer()
                        serverStatus = "запускаю…"
                        refresh(after: 2)
                    }
                    .disabled(LMStudio.lmsPath == nil)
                    Button("Обновить список") { refresh(after: 0) }
                    Text(serverStatus).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 760)
        .onAppear { refresh(after: 0) }
    }

    private var modelOptions: [String] {
        var list = llmModels
        if !llmModel.isEmpty && !list.contains(llmModel) { list.insert(llmModel, at: 0) }
        return list
    }

    private func refresh(after seconds: Double) {
        Task {
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            let models = await LLMPostProcessor.listModels()
            await MainActor.run {
                llmModels = models
                serverStatus = models.isEmpty ? "⚠️ сервер не отвечает" : "✅ сервер доступен"
            }
        }
    }
}
