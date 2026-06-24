import SwiftUI

/// Окно истории: последние транскрипты + результат транскрибации файла.
/// Кнопки «Вставить» (в активное поле) и «Скопировать».
struct HistoryView: View {
    @ObservedObject var store: TranscriptStore
    var onInsert: (String) -> Void
    var onCopy: (String) -> Void
    var onRetranscribe: (Transcript) -> Void

    @State private var copiedID: UUID?

    private func hasAudio(_ item: Transcript) -> Bool {
        guard let p = item.audioFile else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("История транскриптов")
                .font(.headline)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if store.items.isEmpty {
                Spacer()
                Text("Пока пусто. Надиктуйте что-нибудь или транскрибируйте файл.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.items) { item in
                            card(item)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 460, height: 420)
    }

    @ViewBuilder
    private func card(_ item: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.source == .file ? "doc" : "mic")
                    .foregroundColor(.secondary)
                Text(item.fileName ?? item.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundColor(.secondary)
            }

            Text(item.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // Оригинал Whisper (до LLM) — показываем, только если отличается от итога.
            if let raw = item.raw, !raw.isEmpty, raw != item.text {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper (оригинал):")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(raw)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }

            HStack {
                if hasAudio(item) {
                    Button {
                        onRetranscribe(item)
                    } label: {
                        Label("Распознать заново", systemImage: "arrow.clockwise")
                    }
                    .help("Перегнать сохранённую запись через распознавание ещё раз")
                }
                Spacer()
                Button(copiedID == item.id ? "Скопировано ✓" : "Скопировать") {
                    onCopy(item.text)
                    copiedID = item.id
                }
                Button("Вставить") { onInsert(item.text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}
