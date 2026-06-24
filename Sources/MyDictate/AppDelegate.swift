import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let indicator = IndicatorController()
    private let store = TranscriptStore.shared
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    private enum State { case idle, recording, transcribing }
    private var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        TriggerMonitor.shared.onTrigger = { [weak self] in
            self?.toggle()
        }
        TriggerMonitor.shared.start()

        recorder.onLevel = { [weak self] level in
            self?.indicator.update(level: level)
        }

        indicator.model.onTogglePause = { [weak self] in self?.togglePause() }
        indicator.model.onCancel = { [weak self] in self?.cancelRecording() }

        transcriber.preload()

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }

        // Триггер (правый ⌥) работает только с «Универсальным доступом».
        promptAccessibilityIfNeeded()
    }

    // MARK: - Меню-бар

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "mic", accessibilityDescription: "MyDictate") {
                img.isTemplate = true
                button.image = img
            } else {
                // Фолбэк, если SF Symbol недоступен — чтобы иконка точно была видна.
                button.title = "🎙"
            }
        }
        rebuildMenu()
        showWelcomeIfNeeded()
    }

    private func showWelcomeIfNeeded() {
        let key = "didShowWelcome"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "MyDictate запущен"
        a.informativeText = "Иконка микрофона 🎙 теперь в строке меню (вверху справа).\n\nКак пользоваться:\n1. Поставьте курсор в любое текстовое поле.\n2. Нажмите \(TriggerMonitor.title) — начнётся запись.\n3. Говорите, затем нажмите \(TriggerMonitor.title) ещё раз — текст распознается и вставится.\n\nВо время записи в индикаторе есть кнопки паузы и отмены.\nНастройки и выход — в меню иконки 🎙."
        a.addButton(withTitle: "Понятно")
        a.runModal()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let toggleTitle = state == .recording ? "Остановить запись" : "Начать запись"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(menuToggle), keyEquivalent: "")
        toggleItem.target = self
        if state == .transcribing { toggleItem.isEnabled = false; toggleItem.title = "Распознаю…" }
        menu.addItem(toggleItem)

        let hint = NSMenuItem(title: "Триггер: \(TriggerMonitor.title)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let history = NSMenuItem(title: "История…", action: #selector(openHistory), keyEquivalent: "h")
        history.target = self
        menu.addItem(history)

        let file = NSMenuItem(title: "Транскрибировать файл…", action: #selector(pickAndTranscribeFile), keyEquivalent: "o")
        file.target = self
        if state == .transcribing { file.isEnabled = false }
        menu.addItem(file)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func menuToggle() { toggle() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Основной цикл

    private func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break // занят
        }
    }

    private func startRecording() {
        recorder.requestPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.alert(title: "Нет доступа к микрофону",
                           message: "Разрешите доступ в Системных настройках → Конфиденциальность → Микрофон.")
                return
            }
            do {
                try self.recorder.start()
                self.state = .recording
                self.setStatusActive(true)
                self.indicator.show(phase: .recording)
                self.rebuildMenu()
            } catch {
                self.alert(title: "Не удалось начать запись", message: error.localizedDescription)
            }
        }
    }

    private func stopAndTranscribe() {
        let frames = recorder.stop()
        let outputLang = indicator.model.outputLang // выбранный в окошке язык вывода
        state = .transcribing
        setStatusActive(false)
        indicator.setPhase(.transcribing)
        rebuildMenu()

        guard frames.count > 1600 else { // меньше ~0.1с — игнорируем
            indicator.hide()
            state = .idle
            rebuildMenu()
            return
        }

        let llmEnabled = UserDefaults.standard.bool(forKey: "llmEnabled")
        // Если просят английский, но LLM выключен — переводим встроенным переводом Whisper.
        let whisperTranslate = (outputLang == "en" && !llmEnabled)
        let translateTo: String? = (outputLang != "auto") ? outputLang : nil

        // Сохраняем запись в WAV для возможного повторного распознавания из истории.
        let audioURL = AppPaths.recordingsDir.appendingPathComponent(UUID().uuidString + ".wav")

        Task { [weak self] in
            guard let self = self else { return }
            var savedAudio: String? = nil
            do { try AudioFile.writeWAV(frames, to: audioURL); savedAudio = audioURL.path } catch {}
            do {
                let raw = try await self.transcriber.transcribe(frames, translateToEnglish: whisperTranslate)
                // Чистка/перевод через LM Studio (тихий откат на сырой текст), затем
                // гарантированная морфологическая нормализация терминов по словарю.
                let cleaned = await LLMPostProcessor.process(raw, translateTo: whisperTranslate ? nil : translateTo)
                let text = Glossary.apply(cleaned)
                await MainActor.run {
                    self.indicator.hide()
                    self.state = .idle
                    self.rebuildMenu()
                    if text.isEmpty {
                        NSSound.beep()
                    } else {
                        self.store.add(text, raw: raw, source: .dictation, audioFile: savedAudio) // итог + оригинал + аудио
                        if self.ensureAccessibility() {
                            TextInjector.insert(text)
                        } else {
                            self.openHistory() // не можем вставить — показываем историю
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.indicator.hide()
                    self.state = .idle
                    self.rebuildMenu()
                    self.alert(title: "Ошибка распознавания", message: error.localizedDescription)
                }
            }
        }
    }

    /// Пауза/продолжение записи (кнопка в индикаторе).
    private func togglePause() {
        guard state == .recording else { return }
        let nowPaused = !recorder.isPaused
        recorder.setPaused(nowPaused)
        indicator.setPaused(nowPaused)
        statusItem.button?.contentTintColor = nowPaused ? .systemOrange : .systemRed
    }

    /// Отмена записи без распознавания (кнопка ✕ в индикаторе).
    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        state = .idle
        setStatusActive(false)
        indicator.hide()
        rebuildMenu()
    }

    private func setStatusActive(_ active: Bool) {
        let name = active ? "mic.fill" : "mic"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "MyDictate")
        statusItem.button?.contentTintColor = active ? .systemRed : nil
    }

    // MARK: - Разрешения / диалоги

    /// При старте просим «Универсальный доступ»: без него не работает ни триггер
    /// (правый ⌥), ни вставка текста.
    private func promptAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        let a = NSAlert()
        a.messageText = "Нужен «Универсальный доступ»"
        a.informativeText = "Чтобы ловить нажатие правого ⌥ и вставлять текст, включите MyDictate в:\nСистемные настройки → Конфиденциальность и безопасность → Универсальный доступ.\n\nПосле включения перезапустите MyDictate."
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @discardableResult
    private func ensureAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            alert(title: "Нужен «Универсальный доступ»",
                  message: "Чтобы вставлять текст в активное поле, включите MyDictate в Системных настройках → Конфиденциальность → Универсальный доступ, затем повторите.")
        }
        return trusted
    }

    private func alert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .informational
        a.runModal()
    }

    // MARK: - Настройки

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Настройки MyDictate"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 430, height: 760))
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - История

    @objc private func openHistory() {
        if historyWindow == nil {
            let view = HistoryView(
                store: store,
                onInsert: { [weak self] text in self?.insertFromHistory(text) },
                onCopy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                onRetranscribe: { [weak self] item in self?.retranscribe(item) }
            )
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "MyDictate — История"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 460, height: 420))
            win.isReleasedWhenClosed = false
            win.center()
            historyWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    /// Повторное распознавание сохранённой записи из истории.
    private func retranscribe(_ item: Transcript) {
        guard state == .idle else { return }
        guard let path = item.audioFile, FileManager.default.fileExists(atPath: path) else {
            alert(title: "Аудио недоступно",
                  message: "Запись для этого транскрипта не найдена (могла быть вытеснена из истории).")
            return
        }
        state = .transcribing
        indicator.show(phase: .transcribing)
        rebuildMenu()
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let raw = try await self.transcriber.transcribeFile(URL(fileURLWithPath: path))
                let text = Glossary.apply(await LLMPostProcessor.process(raw))
                await MainActor.run {
                    self.indicator.hide()
                    self.state = .idle
                    self.rebuildMenu()
                    if text.isEmpty { NSSound.beep() }
                    else { self.store.update(id: item.id, text: text, raw: raw) }
                }
            } catch {
                await MainActor.run {
                    self.indicator.hide()
                    self.state = .idle
                    self.rebuildMenu()
                    self.alert(title: "Ошибка повторного распознавания", message: error.localizedDescription)
                }
            }
        }
    }

    /// Вставка из истории: убираем окно, возвращаем фокус прежнему приложению, затем вставляем.
    private func insertFromHistory(_ text: String) {
        guard ensureAccessibility() else { return }
        historyWindow?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            TextInjector.insert(text)
        }
    }

    // MARK: - Транскрибация файла

    @objc private func pickAndTranscribeFile() {
        guard state != .transcribing else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите аудиофайл"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        state = .transcribing
        indicator.show(phase: .transcribing)
        rebuildMenu()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let raw = try await self.transcriber.transcribeFile(url)
                let text = Glossary.apply(await LLMPostProcessor.process(raw))
                await MainActor.run {
                    self.indicator.hide()
                    self.state = .idle
                    self.rebuildMenu()
                    if text.isEmpty {
                        self.alert(title: "Пусто", message: "В файле не распознано речи.")
                    } else {
                        self.store.add(text, raw: raw, source: .file, fileName: url.lastPathComponent, audioFile: url.path)
                        self.openHistory() // показываем результат
                    }
                }
            } catch {
                await MainActor.run {
                    self.indicator.hide()
                    self.state = .idle
                    self.rebuildMenu()
                    self.alert(title: "Ошибка распознавания файла", message: error.localizedDescription)
                }
            }
        }
    }
}
