import Foundation
import Testing
@testable import ConversionCore

@Suite(.serialized)
struct ConversionTests {
    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func chunks(_ url: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(Int(le32(data, 4)) == data.count - 8)
        var result: [String: Data] = [:]
        var offset = 12
        while offset + 8 <= data.count {
            let name = String(data: data[offset..<offset + 4], encoding: .ascii)!
            let length = Int(le32(data, offset + 4))
            guard length <= data.count - offset - 8 else { throw TestError.invalidChunk }
            result[name] = data.subdata(in: offset + 8..<offset + 8 + length)
            offset += 8 + length + length % 2
        }
        return result
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }

    @Test func testPreservesEvery16BitMonoSampleAndPlainPCMHeader() throws {
        try assertAudio(bits: 16, channels: 1, rate: 22050)
    }

    @Test func testPreservesEvery24BitStereoSampleAndPlainPCMHeader() throws {
        try assertAudio(bits: 24, channels: 2, rate: 48000)
    }

    private func assertAudio(bits: Int, channels: Int, rate: Double) throws {
        try withDirectory { directory throws in
            let output = directory.appendingPathComponent("result.wav")
            let info = try FLACConverter.convert(source: fixture("pcm\(bits).flac"), destination: output)
            #expect(info.bitDepth == bits)
            #expect(info.channels == channels)
            #expect(info.sampleRate == rate)
            #expect(info.frames == 32768)
            let wav = try chunks(output)
            let format = try #require(wav["fmt "])
            #expect(format.count == 16)
            #expect(Array(format.prefix(2)) == [1, 0], "WAV must use PCM tag 1, never extensible")
            #expect(Array(format.suffix(2)) == [UInt8(bits), 0])
            #expect(wav["data"] == (try Data(contentsOf: fixture("pcm\(bits).raw"))))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["result.wav"])
        }
    }

    @Test func testPreservesUnicodeTagsLabelBPMKeyAndCoverInID3() throws {
        try withDirectory { directory throws in
            let output = directory.appendingPathComponent("tagged.wav")
            _ = try FLACConverter.convert(source: fixture("pcm24.flac"), destination: output)
            let id3 = try #require(try chunks(output)["id3 "])
            #expect(String(data: id3.prefix(3), encoding: .ascii) == "ID3")
            let frames = try id3Frames(id3)
            let expected = ["TIT2": "Тестовый трек", "TPE1": "Archi Gene", "TALB": "Fixture Album", "TPE2": "Various Artists", "TDRC": "2026-11-03", "TCON": "Techno", "TRCK": "7/12", "TPUB": "Fixture Label", "TBPM": "138", "TKEY": "8A"]
            for (frame, value) in expected {
                let bytes = try #require(frames[frame])
                #expect(bytes.first == 3)
                #expect(String(data: bytes.dropFirst(), encoding: .utf8) == value, "\(frame)")
            }
            let custom = try #require(frames["TXXX"])
            #expect(String(data: custom.dropFirst(), encoding: .utf8) == "CUSTOM_FIELD\0Exact value")
            let picture = try #require(frames["APIC"])
            #expect(picture.suffix(try Data(contentsOf: fixture("cover.png")).count).elementsEqual(try Data(contentsOf: fixture("cover.png"))))
            #expect(picture.contains(3))
        }
    }

    @Test func testCancelledConversionNeverPublishesOrLeavesTemporaryFiles() throws {
        try withDirectory { directory throws in
            let output = directory.appendingPathComponent("cancelled.wav")
            let state = LockedState()
            #expect(throws: (any Error).self) { try FLACConverter.convert(source: fixture("pcm24.flac"), destination: output,
                progress: { value in if value > 0 { state.set(true) } }, isCancelled: { state.value }) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(throws: (any Error).self) { try FLACConverter.convert(source: fixture("pcm16.flac"), destination: output, isCancelled: { true }) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test(arguments: ["constant16", "ramp16", "verbatim24", "left24", "right24", "mid24", "mono24", "stereo16"])
    func testStreamingDecoderPreservesSamplesAcrossPredictionAndStereoModes(_ name: String) throws {
        let source = fixture("\(name).flac")
        let metadata = try FLACMetadata.read(source, isCancelled: { false })
        let stream = try SwiftFLACStream(source: source, metadata: metadata, isCancelled: { false })
        var pcm = Data()
        while let block = try stream.read() { pcm.append(block) }
        #expect(pcm == (try Data(contentsOf: fixture("\(name).raw"))))
        try withDirectory { directory throws in
            let output = directory.appendingPathComponent("result.wav")
            let info = try FLACConverter.convert(source: source, destination: output)
            #expect(info.frames == 8195)
            #expect(try chunks(output)["data"] == pcm)
        }
    }

    @Test func testStreamMD5MismatchRejectsOtherwiseValidAudio() throws {
        var bytes = try Data(contentsOf: fixture("pcm24.flac"))
        bytes[26] ^= 1
        try assertRejected(bytes)
    }

    @Test func testInvalidPictureLengthIsRejectedBeforeDecoding() throws {
        var bytes = try Data(contentsOf: fixture("pcm24.flac"))
        var offset = 4
        while offset + 4 < bytes.count {
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if bytes[offset] & 127 == 6 {
                bytes.replaceSubrange(offset + 4 + length - 71..<offset + 4 + length - 67, with: [255, 255, 255, 255])
                break
            }
            offset += length + 4
        }
        try assertRejected(bytes)
    }

    @Test func testFrameChecksumDetectsCorruptionWhenStreamMD5IsAbsent() throws {
        var corrupt = try Data(contentsOf: fixture("pcm24.flac"))
        corrupt.replaceSubrange(26..<42, with: repeatElement(UInt8(0), count: 16))
        corrupt[corrupt.count - 1] ^= 1
        try assertRejected(corrupt)
    }

    @Test func testUnknownTotalFrameCountIsDecodedUntilEOF() throws {
        var bytes = try Data(contentsOf: fixture("pcm24.flac"))
        bytes[21] &= 0xf0
        for index in 22..<26 { bytes[index] = 0 }
        try withDirectory { directory throws in
            let source = directory.appendingPathComponent("unknown.flac")
            let output = directory.appendingPathComponent("result.wav")
            try bytes.write(to: source)
            let info = try FLACConverter.convert(source: source, destination: output)
            #expect(info.frames == 32768)
            #expect(try chunks(output)["data"] == (try Data(contentsOf: fixture("pcm24.raw"))))
        }
    }

    @Test func testCreatesMissingDestinationDirectory() throws {
        try withDirectory { directory throws in
            let output = directory.appendingPathComponent("new/subfolder/result.wav")
            _ = try FLACConverter.convert(source: fixture("pcm16.flac"), destination: output)
            #expect(try chunks(output)["data"] == (try Data(contentsOf: fixture("pcm16.raw"))))
        }
    }

    @Test func testExistingDestinationIsNeverOverwritten() throws {
        try withDirectory { directory throws in
            let output = directory.appendingPathComponent("existing.wav")
            let sentinel = Data("existing music".utf8)
            try sentinel.write(to: output)
            #expect(throws: (any Error).self) { try FLACConverter.convert(source: fixture("pcm16.flac"), destination: output) }
            #expect(try Data(contentsOf: output) == sentinel)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.wav"])
        }
    }

    @Test func testDestinationCreatedDuringConversionWinsPublishRace() throws {
        try withDirectory { directory throws in
            let output = directory.appendingPathComponent("raced.wav")
            let sentinel = Data("another conversion".utf8)
            let state = LockedState()
            #expect(throws: (any Error).self) { try FLACConverter.convert(source: fixture("pcm24.flac"), destination: output,
                progress: { value in
                    if value > 0 && !state.value {
                        state.set(true)
                        try? sentinel.write(to: output)
                    }
                }) }
            #expect(state.value)
            #expect(try Data(contentsOf: output) == sentinel)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["raced.wav"])
        }
    }

    @Test func testTruncatedAndCorruptInputsLeaveSourceUntouchedAndNoOutput() throws {
        let original = try Data(contentsOf: fixture("pcm24.flac"))
        for count in [0, 3, 6, 20, 100, original.count - 20] {
            try assertRejected(Data(original.prefix(count)))
        }
        var corrupt = original
        corrupt[corrupt.count - 5] ^= 0x7f
        try assertRejected(corrupt)
    }

    @Test func testMalformedMetadataLengthsAreRejected() throws {
        var malformed = try Data(contentsOf: fixture("pcm24.flac"))
        var offset = 4
        while offset + 4 < malformed.count {
            let length = Int(malformed[offset + 1]) << 16 | Int(malformed[offset + 2]) << 8 | Int(malformed[offset + 3])
            if malformed[offset] & 127 == 4 {
                malformed.replaceSubrange(offset + 4..<offset + 8, with: [255, 255, 255, 255])
                break
            }
            offset += length + 4
        }
        try assertRejected(malformed)
    }

    @Test func testUnsupportedBitDepthChannelsAndOversizedRIFFAreRejected() throws {
        let original = try Data(contentsOf: fixture("pcm24.flac"))
        for (bits, channels, frames) in [(32, 2, UInt64(32768)), (24, 6, UInt64(32768)), (24, 2, UInt64(1) << 34)] {
            var altered = original
            var packed = (18..<26).reduce(UInt64(0)) { ($0 << 8) | UInt64(altered[$1]) }
            packed = (packed & ~((UInt64(7) << 41) | (UInt64(31) << 36) | ((UInt64(1) << 36) - 1)))
                | UInt64(channels - 1) << 41 | UInt64(bits - 1) << 36 | frames
            for index in 0..<8 { altered[18 + index] = UInt8(truncatingIfNeeded: packed >> (56 - index * 8)) }
            try assertRejected(altered)
        }
    }

    private func assertRejected(_ bytes: Data) throws {
        try withDirectory { directory throws in
            let source = directory.appendingPathComponent("broken.flac")
            let output = directory.appendingPathComponent("broken.wav")
            try bytes.write(to: source)
            #expect(throws: (any Error).self) { try FLACConverter.convert(source: source, destination: output) }
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["broken.flac"])
        }
    }

    private func id3Frames(_ data: Data) throws -> [String: Data] {
        #expect(data[3] == 4)
        var result: [String: Data] = [:]
        var offset = 10
        while offset + 10 <= data.count {
            let name = String(data: data[offset..<offset + 4], encoding: .ascii)!
            let count = (0..<4).reduce(0) { ($0 << 7) | Int(data[offset + 4 + $1]) }
            guard count <= data.count - offset - 10 else { throw TestError.invalidChunk }
            result[name] = data.subdata(in: offset + 10..<offset + 10 + count)
            offset += 10 + count
        }
        return result
    }

    enum TestError: Error { case invalidChunk }
}

private final class LockedState: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
