import Foundation
import Testing
@testable import QueueCore

@Test func preservesFoldersAndDeduplicatesOverlappingInputs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let album = root.appendingPathComponent("Album")
    let disc = album.appendingPathComponent("Disc 1")
    try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
    let track = disc.appendingPathComponent("track.FLAC")
    try Data().write(to: track)
    try Data().write(to: disc.appendingPathComponent("._hidden.flac"))
    try Data().write(to: disc.appendingPathComponent("notes.txt"))
    let jobs = try QueuePlanner.discover([album, track], output: nil)
    #expect(jobs.count == 1)
    #expect(jobs.first?.destination.path == root.appendingPathComponent("Album WAV/Disc 1/track.wav").path)
}

@Test func flatOutputAvoidsExistingAndQueuedNames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), out = root.appendingPathComponent("Out")
    for dir in [a,b,out] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let first = a.appendingPathComponent("Tune.flac"), second = b.appendingPathComponent("tune.flac")
    try Data().write(to: first); try Data().write(to: second)
    try Data("existing".utf8).write(to: out.appendingPathComponent("Tune.wav"))
    let jobs = try QueuePlanner.discover([first,second], output: out)
    #expect(jobs.map(\.destination.lastPathComponent) == ["Tune (2).wav", "tune (3).wav"])
    #expect(try String(contentsOf: out.appendingPathComponent("Tune.wav"), encoding: .utf8) == "existing")
}

@Test func rejectsMissingInput() throws {
    #expect(throws: (any Error).self) {
        try QueuePlanner.discover([URL(fileURLWithPath: "/nonexistent/track.flac")], output: nil)
    }
}

@Test func ancestorWinsWhenUnrelatedInputSeparatesItFromChild() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let album = root.appendingPathComponent("Album"), other = root.appendingPathComponent("Other")
    let disc = album.appendingPathComponent("Disc")
    for dir in [disc,other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let track = disc.appendingPathComponent("track.flac")
    try Data().write(to: track)
    let jobs = try QueuePlanner.discover([track,other,album], output: nil)
    #expect(jobs.count == 1)
    #expect(jobs.first?.destination.path == root.appendingPathComponent("Album WAV/Disc/track.wav").path)
}

@Test func scanCanBeCancelled() throws {
    #expect(throws: CancellationError.self) {
        try QueuePlanner.discover([FileManager.default.temporaryDirectory], output: nil, isCancelled: { true })
    }
}
