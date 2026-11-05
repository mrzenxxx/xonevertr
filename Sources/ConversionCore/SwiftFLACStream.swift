import Foundation

/// A streaming integer FLAC decoder without external codec services or dependencies.
/// Implements RFC 9639 frame/subframe coding and checks both frame checksums.
final class SwiftFLACStream {
    private let bits: FLACBits
    private let info: ConversionInfo
    private var frameIndex: UInt64 = 0
    private var sampleIndex: UInt64 = 0
    private let isCancelled: @Sendable () -> Bool

    init(source: URL, metadata: FLACMetadata, isCancelled: @escaping @Sendable () -> Bool) throws {
        let file = try FileHandle(forReadingFrom: source)
        try file.seek(toOffset: metadata.audioOffset)
        self.bits = FLACBits(file: file, isCancelled: isCancelled)
        self.info = metadata.info
        self.isCancelled = isCancelled
    }

    func read() throws -> Data? {
        if isCancelled() { throw ConversionError.cancelled }
        guard try bits.beginFrame() else { return nil }
        guard try bits.unsigned(14) == 0x3ffe, try bits.unsigned(1) == 0 else { throw ConversionError.corruptedAudio }
        let variable = try bits.unsigned(1) == 1
        let blockCode = try bits.unsigned(4)
        let rateCode = try bits.unsigned(4)
        let assignment = try bits.unsigned(4)
        let depthCode = try bits.unsigned(3)
        guard try bits.unsigned(1) == 0 else { throw ConversionError.corruptedAudio }
        let number = try frameNumber()
        guard number == (variable ? sampleIndex : frameIndex) else { throw ConversionError.corruptedAudio }
        let blockSize: Int
        switch blockCode {
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << Int(blockCode - 2)
        case 6: blockSize = Int(try bits.unsigned(8)) + 1
        case 7: blockSize = Int(try bits.unsigned(16)) + 1
        case 8...15: blockSize = 256 << Int(blockCode - 8)
        default: throw ConversionError.corruptedAudio
        }
        guard blockSize <= 65535, info.frames == 0 || sampleIndex + UInt64(blockSize) <= UInt64(info.frames) else {
            throw ConversionError.corruptedAudio
        }
        let rate: Double
        switch rateCode {
        case 0: rate = info.sampleRate
        case 1: rate = 88200
        case 2: rate = 176400
        case 3: rate = 192000
        case 4: rate = 8000
        case 5: rate = 16000
        case 6: rate = 22050
        case 7: rate = 24000
        case 8: rate = 32000
        case 9: rate = 44100
        case 10: rate = 48000
        case 11: rate = 96000
        case 12: rate = Double(try bits.unsigned(8)) * 1000
        case 13: rate = Double(try bits.unsigned(16))
        case 14: rate = Double(try bits.unsigned(16)) * 10
        default: throw ConversionError.corruptedAudio
        }
        let depths = [info.bitDepth, 8, 12, 0, 16, 20, 24, 32]
        let channels = assignment <= 7 ? Int(assignment + 1) : 2
        guard rate == info.sampleRate, depths[Int(depthCode)] == info.bitDepth,
              assignment <= 10, channels == info.channels else { throw ConversionError.corruptedAudio }
        try bits.checkHeaderCRC()
        var samples: [[Int64]] = []
        for channel in 0..<channels {
            if isCancelled() { throw ConversionError.cancelled }
            let extraBit = (assignment == 8 && channel == 1) || (assignment == 9 && channel == 0) || (assignment == 10 && channel == 1)
            samples.append(try subframe(count: blockSize, depth: info.bitDepth + (extraBit ? 1 : 0)))
        }
        try bits.checkFrameCRC()
        if assignment >= 8 {
            for index in 0..<blockSize {
                let first = samples[0][index]
                let second = samples[1][index]
                switch assignment {
                case 8: samples[1][index] = first - second
                case 9: samples[0][index] = first + second
                default:
                    let mid = (first << 1) | (second & 1)
                    samples[0][index] = (mid + second) >> 1
                    samples[1][index] = (mid - second) >> 1
                }
            }
        }
        let minimum = -(Int64(1) << (info.bitDepth - 1))
        let maximum = (Int64(1) << (info.bitDepth - 1)) - 1
        var packed = Data()
        packed.reserveCapacity(blockSize * channels * info.bitDepth / 8)
        for index in 0..<blockSize {
            for channel in 0..<channels {
                let value = samples[channel][index]
                guard (minimum...maximum).contains(value) else { throw ConversionError.corruptedAudio }
                for byte in 0..<(info.bitDepth / 8) { packed.append(UInt8(truncatingIfNeeded: value >> (8 * byte))) }
            }
        }
        sampleIndex += UInt64(blockSize)
        frameIndex += 1
        return packed
    }

    private func frameNumber() throws -> UInt64 {
        let first = try bits.unsigned(8)
        if first < 0x80 { return first }
        var length = 0
        for bit in (0..<8).reversed() {
            if first & (1 << bit) == 0 { break }
            length += 1
        }
        guard (2...7).contains(length) else { throw ConversionError.corruptedAudio }
        var value = first & ((UInt64(1) << (7 - length)) - 1)
        for _ in 1..<length {
            let byte = try bits.unsigned(8)
            guard byte & 0xc0 == 0x80 else { throw ConversionError.corruptedAudio }
            value = (value << 6) | (byte & 0x3f)
        }
        let minimumBits = [0, 0, 7, 11, 16, 21, 26, 31]
        guard value >= UInt64(1) << minimumBits[length], value < UInt64(1) << 36 else {
            throw ConversionError.corruptedAudio
        }
        return value
    }

    private func subframe(count: Int, depth: Int) throws -> [Int64] {
        guard try bits.unsigned(1) == 0 else { throw ConversionError.corruptedAudio }
        let type = try bits.unsigned(6)
        let hasWasted = try bits.unsigned(1) == 1
        let wasted = hasWasted ? try bits.unary(limit: UInt64(depth - 1)) + 1 : 0
        guard wasted < depth else { throw ConversionError.corruptedAudio }
        let precision = depth - Int(wasted)
        var values = [Int64](repeating: 0, count: count)
        if type == 0 {
            let value = try bits.signed(precision)
            values = [Int64](repeating: value, count: count)
        } else if type == 1 {
            for index in 0..<count { values[index] = try bits.signed(precision) }
        } else {
            let order: Int
            if (8...12).contains(type) { order = Int(type - 8) }
            else if (32...63).contains(type) { order = Int(type - 31) }
            else { throw ConversionError.corruptedAudio }
            guard order <= count else { throw ConversionError.corruptedAudio }
            for index in 0..<order { values[index] = try bits.signed(precision) }
            var coefficients: [Int64] = []
            var shift = 0
            if type >= 32 {
                let raw = try bits.unsigned(4)
                guard raw != 15 else { throw ConversionError.corruptedAudio }
                shift = Int(try bits.signed(5))
                for _ in 0..<order { coefficients.append(try bits.signed(Int(raw) + 1)) }
            }
            try residuals(into: &values, order: order)
            for index in order..<count {
                let prediction: Int64
                if type >= 32 {
                    var sum: Int64 = 0
                    for coefficient in 0..<order { sum += coefficients[coefficient] * values[index - coefficient - 1] }
                    prediction = shift >= 0 ? sum >> shift : sum << -shift
                } else {
                    switch order {
                    case 0: prediction = 0
                    case 1: prediction = values[index - 1]
                    case 2: prediction = 2 * values[index - 1] - values[index - 2]
                    case 3: prediction = 3 * values[index - 1] - 3 * values[index - 2] + values[index - 3]
                    default: prediction = 4 * values[index - 1] - 6 * values[index - 2] + 4 * values[index - 3] - values[index - 4]
                    }
                }
                values[index] += prediction
                let bound = Int64(1) << (precision - 1)
                guard values[index] >= -bound, values[index] < bound else { throw ConversionError.corruptedAudio }
            }
        }
        if wasted > 0 {
            for index in 0..<count { values[index] <<= wasted }
        }
        return values
    }

    private func residuals(into values: inout [Int64], order: Int) throws {
        let method = try bits.unsigned(2)
        guard method <= 1 else { throw ConversionError.corruptedAudio }
        let parameterBits = method == 0 ? 4 : 5
        let partitionOrder = Int(try bits.unsigned(4))
        let partitions = 1 << partitionOrder
        guard values.count % partitions == 0 else { throw ConversionError.corruptedAudio }
        let partitionSize = values.count / partitions
        guard partitionSize >= order else { throw ConversionError.corruptedAudio }
        var index = order
        for partition in 0..<partitions {
            if isCancelled() { throw ConversionError.cancelled }
            let parameter = Int(try bits.unsigned(parameterBits))
            let count = partitionSize - (partition == 0 ? order : 0)
            if parameter == (1 << parameterBits) - 1 {
                let rawBits = Int(try bits.unsigned(5))
                for _ in 0..<count { values[index] = try bits.signed(rawBits); index += 1 }
            } else {
                for _ in 0..<count {
                    let quotient = try bits.unary(limit: UInt64(UInt32.max) >> parameter)
                    let value = (quotient << parameter) | (try bits.unsigned(parameter))
                    guard value < UInt64(UInt32.max) else { throw ConversionError.corruptedAudio }
                    values[index] = Int64(value >> 1) ^ -Int64(value & 1)
                    index += 1
                }
            }
        }
    }
}

private final class FLACBits {
    let file: FileHandle
    let isCancelled: @Sendable () -> Bool
    var buffer = Data()
    var offset = 0
    var current: UInt8 = 0
    var remaining = 0
    var crc8: UInt8 = 0
    var crc16: UInt16 = 0

    init(file: FileHandle, isCancelled: @escaping @Sendable () -> Bool) {
        self.file = file
        self.isCancelled = isCancelled
    }
    deinit { try? file.close() }

    func beginFrame() throws -> Bool {
        guard remaining == 0 else { throw ConversionError.corruptedAudio }
        crc8 = 0; crc16 = 0
        guard let byte = try nextByte() else { return false }
        current = byte; remaining = 8
        checksum(byte)
        return true
    }

    func unsigned(_ count: Int) throws -> UInt64 {
        guard (0...32).contains(count) else { throw ConversionError.corruptedAudio }
        var value: UInt64 = 0
        var needed = count
        while needed > 0 {
            if remaining == 0 {
                guard let byte = try nextByte() else { throw ConversionError.corruptedAudio }
                current = byte; remaining = 8
                checksum(byte)
            }
            let take = min(needed, remaining)
            value = (value << take) | UInt64((current >> (remaining - take)) & UInt8((1 << take) - 1))
            remaining -= take; needed -= take
        }
        return value
    }

    func signed(_ count: Int) throws -> Int64 {
        guard count > 0 else { return 0 }
        let value = try unsigned(count)
        let sign = UInt64(1) << (count - 1)
        return Int64(value ^ sign) - Int64(sign)
    }

    func unary(limit: UInt64) throws -> UInt64 {
        var count: UInt64 = 0
        while try unsigned(1) == 0 {
            count += 1
            guard count <= limit else { throw ConversionError.corruptedAudio }
        }
        return count
    }

    func checkHeaderCRC() throws {
        guard remaining == 0 else { throw ConversionError.corruptedAudio }
        let expected = crc8
        guard try unsigned(8) == expected else { throw ConversionError.corruptedAudio }
    }

    func checkFrameCRC() throws {
        if remaining > 0 {
            guard try unsigned(remaining) == 0 else { throw ConversionError.corruptedAudio }
        }
        let expected = crc16
        guard try unsigned(16) == expected else { throw ConversionError.corruptedAudio }
    }

    private func nextByte() throws -> UInt8? {
        if offset == buffer.count {
            if isCancelled() { throw ConversionError.cancelled }
            buffer = try file.read(upToCount: 64 * 1024) ?? Data()
            offset = 0
            if buffer.isEmpty { return nil }
        }
        defer { offset += 1 }
        return buffer[offset]
    }

    private func checksum(_ byte: UInt8) {
        crc8 ^= byte
        crc16 ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc8 = crc8 & 0x80 == 0 ? crc8 << 1 : (crc8 << 1) ^ 0x07
            crc16 = crc16 & 0x8000 == 0 ? crc16 << 1 : (crc16 << 1) ^ 0x8005
        }
    }
}
