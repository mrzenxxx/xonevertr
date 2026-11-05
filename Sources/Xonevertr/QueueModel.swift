import AppKit
import Observation
import ConversionCore
import QueueCore

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

enum JobState: Equatable {
    case waiting, converting, done, cancelled, failed(String)
    var text: String {
        switch self {
        case .waiting: "В очереди"
        case .converting: "Конвертация"
        case .done: "Готово"
        case .cancelled: "Отменено"
        case .failed(let message): message
        }
    }
    var canRetry: Bool { if case .failed = self { return true }; return self == .cancelled }
}

struct QueueItem: Identifiable {
    let id = UUID()
    let source: URL
    let destination: URL
    var state: JobState = .waiting
    var progress = 0.0
    var detail = ""
}

@MainActor @Observable final class QueueModel {
    var items: [QueueItem] = []
    var outputFolder: URL?
    var isRunning = false
    var isScanning = false
    var error: String?
    private var cancellation = CancellationFlag()
    var completed: Int { items.filter { $0.state == .done }.count }
    var hasPending: Bool { items.contains { $0.state == .waiting } }
    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.state == .done ? 1 : $1.progress) } / Double(items.count)
    }

    func add(_ urls: [URL]) {
        guard !isRunning, !isScanning else { return }
        isScanning = true
        let output = outputFolder
        let knownURLs = items.map(\.source)
        cancellation = CancellationFlag()
        let flag = cancellation
        let reserved = Set(items.map(\.destination))
        Task {
            defer { isScanning = false }
            do {
                let planned = try await Task.detached(priority: .userInitiated) {
                    let knownSources = Set(knownURLs.map { $0.resolvingSymlinksInPath().path })
                    return try QueuePlanner.discover(urls, output: output, reserved: reserved, isCancelled: { flag.isCancelled })
                        .filter { !knownSources.contains($0.source.resolvingSymlinksInPath().path) }
                }.value
                items += planned.map { QueueItem(source: $0.source, destination: $0.destination) }
                if planned.isEmpty { error = "В выбранных файлах и папках нет FLAC." }
            } catch is CancellationError {
                // A cancelled scan leaves the existing queue intact.
            } catch { self.error = error.localizedDescription }
        }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.title = "Добавить FLAC или папки"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "Папка для следующих добавленных файлов"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.outputFolder = panel.url
        }
    }

    func start() {
        guard !isRunning, !isScanning, hasPending else { return }
        isRunning = true
        cancellation = CancellationFlag()
        let flag = cancellation
        Task {
            defer { isRunning = false }
            for index in items.indices {
                if flag.isCancelled { break }
                guard items[index].state == .waiting else { continue }
                let source = items[index].source, destination = items[index].destination
                items[index].state = .converting
                do {
                    let model = self
                    let info = try await Task.detached(priority: .userInitiated) {
                        try FLACConverter.convert(source: source, destination: destination, progress: { value in
                            Task { @MainActor in
                                guard model.items.indices.contains(index), model.items[index].state == .converting else { return }
                                model.items[index].progress = value
                            }
                        }, isCancelled: { flag.isCancelled })
                    }.value
                    items[index].state = .done; items[index].progress = 1
                    items[index].detail = "\(Int(info.sampleRate)) Гц · \(info.bitDepth) бит · \(info.channels) кан."
                } catch {
                    items[index].state = flag.isCancelled ? .cancelled : .failed(error.localizedDescription)
                    items[index].progress = 0
                }
            }
            if flag.isCancelled {
                for index in items.indices where items[index].state == .waiting { items[index].state = .cancelled }
            }
        }
    }

    func cancel() { cancellation.cancel() }
    func retry() {
        guard !isRunning else { return }
        for index in items.indices where items[index].state.canRetry {
            items[index].state = .waiting; items[index].progress = 0
        }
    }
    func clear() { guard !isRunning, !isScanning else { return }; items.removeAll() }
    func reveal(_ item: QueueItem) { NSWorkspace.shared.activateFileViewerSelecting([item.destination]) }
}
