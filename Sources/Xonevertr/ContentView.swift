import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: QueueModel
    @State private var isDropTarget = false
    private var busy: Bool { model.isRunning || model.isScanning }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "waveform.path").font(.system(size: 35, weight: .medium)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("FLAC → WAV").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Ваш звук. Без потерь.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("PCM\n16 / 24 бит").font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }.padding(24)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 44, weight: .light)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Перетащите FLAC или папку").font(.title3.bold())
                    Text("Частота, разрядность, теги и обложка сохранятся.\nИсходники останутся на месте.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Выбрать файлы…", systemImage: "plus") { model.importFiles() }
                        .controlSize(.large).disabled(busy).padding(.top, 6)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: symbol(item.state)).foregroundStyle(color(item.state))
                                .font(.title3).frame(width: 26).accessibilityLabel(item.state.text)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.source.lastPathComponent).fontWeight(.medium).lineLimit(1)
                                Text(item.state == .done ? item.detail : item.state.text)
                                    .font(.caption).foregroundStyle(item.state.canRetry ? .primary : .secondary)
                                    .lineLimit(2).textSelection(.enabled)
                                Text(item.destination.path).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                if item.state == .converting {
                                    ProgressView(value: item.progress).accessibilityLabel("Прогресс файла")
                                }
                            }
                            Spacer(minLength: 12)
                            if item.state == .done {
                                Button { model.reveal(item) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless).help("Показать WAV в Finder")
                                    .accessibilityLabel("Показать \(item.destination.lastPathComponent) в Finder")
                            } else if item.state == .converting {
                                Text(item.progress, format: .percent.precision(.fractionLength(0)))
                                    .font(.system(.caption, design: .monospaced)).monospacedDigit()
                            }
                        }.padding(.vertical, 7)
                        .help(item.destination.path)
                        .contextMenu {
                            Button("Показать исходник") { NSWorkspace.shared.activateFileViewerSelecting([item.source]) }
                            if item.state == .done { Button("Показать WAV") { model.reveal(item) } }
                        }
                    }
                }.listStyle(.inset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.outputFolder?.path ?? "Рядом с исходниками, в папках «… WAV»")
                            .lineLimit(1).truncationMode(.middle).font(.callout)
                        Text("Место вывода применяется к следующим добавленным файлам")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Сохранение") {
                        Button("Выбрать папку…") { model.chooseOutput() }
                        Button("Рядом с исходниками") { model.outputFolder = nil }
                    }.fixedSize().disabled(busy)
                }
                if model.isRunning { ProgressView(value: model.overallProgress).accessibilityLabel("Прогресс очереди") }
                HStack {
                    if model.isScanning { ProgressView().controlSize(.small); Text("Поиск FLAC…").foregroundStyle(.secondary) }
                    else { Text("Готово \(model.completed) из \(model.items.count)").foregroundStyle(.secondary).font(.callout) }
                    Spacer()
                    if model.isRunning || model.isScanning {
                        Button("Остановить", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                    } else {
                        if model.items.contains(where: { $0.state.canRetry }) { Button("Повторить") { model.retry() }.disabled(busy) }
                        Button("Конвертировать", systemImage: "arrow.right") { model.start() }
                            .buttonStyle(.borderedProminent).disabled(!model.hasPending || busy)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(20).background(.bar)
        }
        .frame(minWidth: 650, minHeight: 480)
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 3).padding(5).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy else { return false }; model.add(urls); return true
        } isTargeted: { isDropTarget = $0 }
        .toolbar {
            ToolbarItemGroup {
                Button("Добавить", systemImage: "plus") { model.importFiles() }.disabled(busy)
                Button("Очистить", systemImage: "trash") { model.clear() }.disabled(busy || model.items.isEmpty)
            }
        }
        .alert("Не удалось добавить файлы", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func symbol(_ state: JobState) -> String {
        switch state {
        case .waiting: "waveform"
        case .converting: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .cancelled: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    private func color(_ state: JobState) -> Color {
        switch state {
        case .done: .green
        case .failed: .orange
        case .converting: .accentColor
        default: .secondary
        }
    }
}
