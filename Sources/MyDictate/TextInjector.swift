import AppKit
import Carbon.HIToolbox

/// Вставляет текст в активное поле ввода через буфер обмена + эмуляцию Cmd+V.
/// Требует разрешения «Универсальный доступ» (Accessibility).
enum TextInjector {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        // Добавляем пробел в конце, чтобы следующая вставка/слово не слипались.
        let toInsert = text.hasSuffix(" ") ? text : text + " "

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(toInsert, forType: .string)

        sendPaste()

        // Восстанавливаем прежнее содержимое буфера чуть позже,
        // чтобы целевое приложение успело прочитать вставку.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let savedItems = savedItems {
                pasteboard.setString(savedItems, forType: .string)
            }
        }
    }

    private static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
