import SwiftUI
import AppKit

enum IndicatorPhase {
    case recording
    case transcribing
}

final class IndicatorModel: ObservableObject {
    @Published var phase: IndicatorPhase = .recording
    @Published var level: Float = 0
    @Published var paused: Bool = false
    /// Опциональная строка прогресса для фазы распознавания (напр. «Папка: 2 из 7»).
    @Published var progressText: String? = nil
    /// Язык вывода на эту диктовку: "auto" (как услышано) или код языка (перевод).
    @Published var outputLang: String = "auto"

    /// Цикл переключения языка в окошке: авто → английский → русский → …
    static let langCycle = ["auto", "en", "ru"]

    func cycleLang() {
        let i = IndicatorModel.langCycle.firstIndex(of: outputLang) ?? 0
        outputLang = IndicatorModel.langCycle[(i + 1) % IndicatorModel.langCycle.count]
    }

    /// Колбэки управления (выставляет AppDelegate).
    var onTogglePause: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// Плавающее окно-индикатор (HUD) внизу экрана с кнопками управления.
final class IndicatorController {
    private var panel: NSPanel?
    let model = IndicatorModel()

    func show(phase: IndicatorPhase) {
        model.phase = phase
        model.paused = false
        model.progressText = nil
        model.outputLang = "auto" // на каждую новую диктовку — авто
        if panel == nil { makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    func update(level: Float) { model.level = level }
    func setPhase(_ phase: IndicatorPhase) { model.phase = phase }
    func setProgress(_ text: String?) { model.progressText = text }
    func setPaused(_ paused: Bool) { model.paused = paused }
    func hide() { panel?.orderOut(nil) }

    private func makePanel() {
        let hosting = NSHostingView(rootView: IndicatorView(model: model))
        let size = NSSize(width: 340, height: 64)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        // Кликабельно, но не забирает фокус у активного поля (куда вставляем текст).
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hosting.frame = NSRect(origin: .zero, size: size)
        p.contentView = hosting
        panel = p
    }

    private func position() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + 90))
    }
}

private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .recording:
                recordingContent
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                Text(model.progressText ?? "Распознаю…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 340, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
    }

    @ViewBuilder
    private var recordingContent: some View {
        Circle()
            .fill(model.paused ? Color.orange : Color.red)
            .frame(width: 12, height: 12)
            .scaleEffect(pulse && !model.paused ? 1.35 : 0.85)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }

        if model.paused {
            Text("Пауза")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            WaveformView(level: model.level)
            Text("Запись…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Переключатель языка вывода: 🌐 auto / EN / RU
        LangButton(lang: model.outputLang) { model.cycleLang() }

        // Кнопка паузы/продолжения
        ControlButton(symbol: model.paused ? "play.fill" : "pause.fill",
                      tint: .white) {
            model.onTogglePause?()
        }
        // Кнопка отмены
        ControlButton(symbol: "xmark", tint: Color.red.opacity(0.9)) {
            model.onCancel?()
        }
    }
}

private struct LangButton: View {
    let lang: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if lang == "auto" {
                    Image(systemName: "globe").font(.system(size: 12, weight: .bold))
                } else {
                    Text(lang.uppercased()).font(.system(size: 11, weight: .heavy))
                }
            }
            .foregroundColor(lang == "auto" ? .white : .yellow)
            .frame(width: 30, height: 26)
            .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("Язык вывода: глобус — авто, EN/RU — перевести в этот язык")
    }
}

private struct ControlButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// Простой эквалайзер из 5 полосок, реагирующий на уровень звука.
private struct WaveformView: View {
    let level: Float
    private let bars = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let phase = Float(i) / Float(bars)
                let h = max(0.15, min(1.0, level * (0.6 + phase)))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: CGFloat(6 + h * 22))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: 28)
    }
}
