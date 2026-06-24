import AppKit
import Carbon.HIToolbox

/// Глобальный триггер по правой клавише ⌥ (Option).
///
/// Правый Option — это «голый» модификатор, поэтому Carbon RegisterEventHotKey
/// его не ловит. Слушаем события .flagsChanged глобальным монитором и различаем
/// левый/правый Option по keyCode (правый = kVK_RightOption = 61).
///
/// Требует разрешения «Универсальный доступ» (Accessibility) — оно же нужно
/// и для вставки текста.
final class TriggerMonitor {
    static let shared = TriggerMonitor()

    var onTrigger: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    /// Человекочитаемое название триггера (для меню и подсказок).
    static let title = "правый ⌥ (Option)"

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_RightOption) else { return }
        let pressed = event.modifierFlags.contains(.option)
        if pressed && !isDown {
            isDown = true
            onTrigger?()
        } else if !pressed {
            isDown = false
        }
    }
}
