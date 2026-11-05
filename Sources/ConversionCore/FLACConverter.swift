import CryptoKit
import Darwin
import Foundation

public struct ConversionInfo: Sendable {
    public let sampleRate: Double
    public let bitDepth: Int
    public let channels: Int
    public let frames: Int64
}

public enum ConversionError: Error, LocalizedError, Sendable {
    case invalidFLAC
    case invalidMetadata
    case unsupportedFormat(bitDepth: Int, channels: Int)
    case tooLargeForWAV
    case destinationExists
    case cancelled
    case corruptedAudio
    case cannotPublish(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidFLAC: "Файл повреждён или не является FLAC."
        case .invalidMetadata: "Метаданные FLAC повреждены или превышают допустимый размер."
        case let .unsupportedFormat(bits, channels): "Не поддерживается: \(bits) бит, каналов: \(channels). Нужен FLAC 16/24 бит, моно или стерео."
        case .tooLargeForWAV: "Размер превышает ограничение обычного WAV (4 ГБ)."
        case .destinationExists: "WAV с таким именем уже существует."
        case .cancelled: "Конвертация отменена."
        case .corruptedAudio: "Аудиоданные FLAC повреждены или обрезаны."
        case let .cannotPublish(code): "Не удалось сохранить WAV: \(String(cString: strerror(code)))."
        }
    }
}

public enum FLACConverter {
    /// Streams integer FLAC samples into packed PCM rather than WAVE_FORMAT_EXTENSIBLE.
    /// The destination becomes visible only after a successful, exclusive atomic rename.
    public static func convert(source: URL, destination: URL,
                               progress: @Sendable (Double) -> Void = { _ in },
                               isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> ConversionInfo {
        func checkCancellation() throws {
            if isCancelled() { throw ConversionError.cancelled }
        }
        try checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ConversionError.destinationExists
        }
        let metadata = try FLACMetadata.read(source, isCancelled: isCancelled)
        let info = metadata.info
        guard [16, 24].contains(info.bitDepth), (1...2).contains(info.channels) else {
            throw ConversionError.unsupportedFormat(bitDepth: info.bitDepth, channels: info.channels)
        }
        let bytesPerFrame = info.channels * info.bitDepth / 8
        let tag = try metadata.id3Tag()
        let tagBytes = tag.isEmpty ? 0 : 8 + tag.count + tag.count % 2
        let expectedDataBytes = UInt64(info.frames) * UInt64(bytesPerFrame)
        guard expectedDataBytes + UInt64(expectedDataBytes % 2) + 36 + UInt64(tagBytes) <= UInt64(UInt32.max) else {
            throw ConversionError.tooLargeForWAV
        }
        try checkCancellation()
        let reader = try SwiftFLACStream(source: source, metadata: metadata, isCancelled: isCancelled)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".xonevertr-\(UUID().uuidString).partial")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try output.write(contentsOf: waveHeader(info: info, dataBytes: 0, riffBytes: 36))
        progress(0)
        var frameCount: Int64 = 0
        var hash = Insecure.MD5()
        while true {
            try checkCancellation()
            guard let packed = try reader.read() else { break }
            let count = packed.count / bytesPerFrame
            let bytesWritten = UInt64(frameCount + Int64(count)) * UInt64(bytesPerFrame)
            guard bytesWritten + bytesWritten % 2 + 36 + UInt64(tagBytes) <= UInt64(UInt32.max) else {
                throw ConversionError.tooLargeForWAV
            }
            hash.update(data: packed)
            try output.write(contentsOf: packed)
            frameCount += Int64(count)
            if info.frames > 0 { progress(min(0.999, Double(frameCount) / Double(info.frames))) }
        }
        try checkCancellation()
        guard info.frames == 0 || frameCount == info.frames else { throw ConversionError.corruptedAudio }
        let digest = Data(hash.finalize())
        guard metadata.md5.allSatisfy({ $0 == 0 }) || digest == metadata.md5 else {
            throw ConversionError.corruptedAudio
        }
        let dataBytes = UInt32(UInt64(frameCount) * UInt64(bytesPerFrame))
        if dataBytes % 2 != 0 { try output.write(contentsOf: Data([0])) }
        if !tag.isEmpty {
            var chunk = Data("id3 ".utf8)
            chunk.appendLE(UInt32(tag.count))
            try output.write(contentsOf: chunk)
            try output.write(contentsOf: tag)
            if tag.count % 2 != 0 { try output.write(contentsOf: Data([0])) }
        }
        let riffBytes = UInt32(36 + UInt64(dataBytes) + UInt64(dataBytes % 2) + UInt64(tagBytes))
        try output.seek(toOffset: 0)
        try output.write(contentsOf: waveHeader(info: info, dataBytes: dataBytes, riffBytes: riffBytes))
        try output.synchronize()
        try output.close()
        try checkCancellation()
        // RENAME_EXCL is the no-overwrite guarantee, including a destination created during decoding.
        let result = temporary.path.withCString { from in
            destination.path.withCString { to in Darwin.renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        if result != 0 {
            let code = errno
            if code == EEXIST { throw ConversionError.destinationExists }
            throw ConversionError.cannotPublish(code)
        }
        progress(1)
        return ConversionInfo(sampleRate: info.sampleRate, bitDepth: info.bitDepth, channels: info.channels, frames: frameCount)
    }

    private static func waveHeader(info: ConversionInfo, dataBytes: UInt32, riffBytes: UInt32) -> Data {
        var header = Data("RIFF".utf8)
        header.appendLE(riffBytes)
        header.append(contentsOf: "WAVEfmt ".utf8)
        header.appendLE(UInt32(16))
        header.appendLE(UInt16(1))
        header.appendLE(UInt16(info.channels))
        header.appendLE(UInt32(info.sampleRate))
        header.appendLE(UInt32(info.sampleRate) * UInt32(info.channels * info.bitDepth / 8))
        header.appendLE(UInt16(info.channels * info.bitDepth / 8))
        header.appendLE(UInt16(info.bitDepth))
        header.append(contentsOf: "data".utf8)
        header.appendLE(dataBytes)
        return header
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
