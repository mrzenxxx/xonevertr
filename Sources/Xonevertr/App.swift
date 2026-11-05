import SwiftUI

@main struct XonevertrApp: App {
    @State private var model = QueueModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("xonevertr", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 820, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить FLAC…") { model.importFiles() }
                    .keyboardShortcut("o")
                    .disabled(model.isRunning || model.isScanning)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Завершить xonevertr") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: QueueModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, (model.isRunning || model.isScanning) else { return .terminateNow }
        model.cancel()
        Task { @MainActor in
            while model.isRunning || model.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.add(urls) }
        else { Task { @MainActor in
            for _ in 0..<50 {
                if let model { model.add(urls); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } }
    }
}
