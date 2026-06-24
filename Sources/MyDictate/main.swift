import AppKit

// MyDictate — нативное macOS-приложение для голосового ввода.
// Запускается как accessory (без иконки в Dock), живёт в меню-баре.

// Скрытый режим самодиагностики: ./MyDictate --selftest <audiofile>
if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let t = Transcriber()
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let text = try await t.transcribeFile(URL(fileURLWithPath: path))
            print("RESULT: \(text)")
        } catch {
            print("ERROR: \(error)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
