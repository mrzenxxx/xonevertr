import Foundation

/// Metadata is bounded independently of audio length; audio samples are never loaded here.
struct FLACMetadata {
    let info: ConversionInfo
    let md5: Data
    private(set) var audioOffset: UInt64 = 0
    private(set) var comments: [(String, String)] = []
    private(set) var pictures: [Picture] = []

    struct Picture {
        let type: UInt8
        let mime: String
        let description: String
        let bytes: Data
    }

    static func read(_ url: URL, isCancelled: @Sendable () -> Bool) throws -> FLACMetadata {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try readExactly(file, count: 4) == Data("fLaC".utf8) else { throw ConversionError.invalidFLAC }
        var result: FLACMetadata?
        var total = 0
        var sawComments = false
        for index in 0..<4096 {
            if isCancelled() { throw ConversionError.cancelled }
            let header = try readExactly(file, count: 4)
            let type = header[0] & 0x7f
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            total += length + 4
            guard total <= 64 * 1024 * 1024, type != 127 else { throw ConversionError.invalidMetadata }
            let body = try readExactly(file, count: length)
            if index == 0 {
                guard type == 0, length == 34 else { throw ConversionError.invalidFLAC }
                let packed = body[10..<18].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let sampleRate = Double(packed >> 44)
                let channels = Int((packed >> 41) & 7) + 1
                let bits = Int((packed >> 36) & 31) + 1
                let frames = Int64(packed & ((UInt64(1) << 36) - 1))
                guard sampleRate > 0 else { throw ConversionError.invalidFLAC }
                result = FLACMetadata(info: ConversionInfo(sampleRate: sampleRate, bitDepth: bits, channels: channels, frames: frames),
                                      md5: body.subdata(in: 18..<34))
            } else {
                switch type {
                case 0: throw ConversionError.invalidMetadata
                case 4:
                    guard !sawComments else { throw ConversionError.invalidMetadata }
                    sawComments = true
                    result?.comments = try readComments(body)
                case 6:
                    guard (result?.pictures.count ?? 0) < 64 else { throw ConversionError.invalidMetadata }
                    result?.pictures.append(try readPicture(body))
                default: break
                }
            }
            if header[0] & 0x80 != 0 {
                guard var result else { throw ConversionError.invalidFLAC }
                result.audioOffset = UInt64(total + 4)
                return result
            }
        }
        throw ConversionError.invalidMetadata
    }

    private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else {
                throw ConversionError.invalidFLAC
            }
            data.append(part)
        }
        return data
    }

    private static func readComments(_ data: Data) throws -> [(String, String)] {
        var cursor = Cursor(data)
        _ = try cursor.take(Int(cursor.u32(little: true))) // Vendor string is not a music tag.
        let count = try cursor.u32(little: true)
        guard count <= 100_000, UInt64(count) * 4 <= UInt64(cursor.remaining) else { throw ConversionError.invalidMetadata }
        var comments: [(String, String)] = []
        for _ in 0..<count {
            let bytes = try cursor.take(Int(cursor.u32(little: true)))
            guard let value = String(data: bytes, encoding: .utf8), let separator = value.firstIndex(of: "=") else {
                throw ConversionError.invalidMetadata
            }
            let name = String(value[..<separator])
            guard !name.isEmpty, name.utf8.allSatisfy({ (0x20...0x7d).contains($0) && $0 != 0x3d }) else {
                throw ConversionError.invalidMetadata
            }
            comments.append((name.uppercased(), String(value[value.index(after: separator)...])))
        }
        guard cursor.remaining == 0 else { throw ConversionError.invalidMetadata }
        return comments
    }

    private static func readPicture(_ data: Data) throws -> Picture {
        var cursor = Cursor(data)
        let type = try cursor.u32()
        let mimeBytes = try cursor.take(Int(cursor.u32()))
        let descriptionBytes = try cursor.take(Int(cursor.u32()))
        guard type <= 20, let mime = String(data: mimeBytes, encoding: .ascii),
              !mime.isEmpty, !mime.contains("\0"), let description = String(data: descriptionBytes, encoding: .utf8),
              !description.contains("\0") else { throw ConversionError.invalidMetadata }
        _ = try cursor.take(16) // Width, height, colour depth, palette size.
        let bytes = try cursor.take(Int(cursor.u32()))
        guard cursor.remaining == 0 else { throw ConversionError.invalidMetadata }
        return Picture(type: UInt8(type), mime: mime, description: description, bytes: bytes)
    }

    func id3Tag() throws -> Data {
        let standard = ["TITLE": "TIT2", "ARTIST": "TPE1", "ALBUM": "TALB", "ALBUMARTIST": "TPE2",
                        "ALBUM ARTIST": "TPE2", "DATE": "TDRC", "YEAR": "TDRC", "GENRE": "TCON",
                        "ORGANIZATION": "TPUB", "LABEL": "TPUB", "BPM": "TBPM", "INITIALKEY": "TKEY",
                        "COMMENT": "COMM", "DISCNUMBER": "TPOS"]
        let totals = ["TRACKTOTAL", "TOTALTRACKS"]
        let total = comments.first { totals.contains($0.0) }?.1
        var frames = Data()
        var mapped: [(String, [String])] = []
        for (name, value) in comments {
            var frame: String
            var text = value
            if name == "TRACKNUMBER" || name == "TRACK" {
                frame = "TRCK"
                if let total, !value.contains("/") { text += "/" + total }
            } else if totals.contains(name), comments.contains(where: { $0.0 == "TRACKNUMBER" || $0.0 == "TRACK" }) {
                continue
            } else if let known = standard[name] { frame = known }
            else {
                var payload = Data([3]) // ID3v2.4 UTF-8.
                payload.append(contentsOf: name.utf8)
                payload.append(0)
                payload.append(contentsOf: value.utf8)
                frames.append(try id3Frame("TXXX", payload))
                continue
            }
            if let index = mapped.firstIndex(where: { $0.0 == frame }) {
                mapped[index].1.append(text)
            } else { mapped.append((frame, [text])) }
        }
        for (frame, values) in mapped {
            var payload = Data([3])
            if frame == "COMM" { payload.append(contentsOf: [0x65, 0x6e, 0x67, 0]) }
            payload.append(contentsOf: values.joined(separator: "\0").utf8)
            frames.append(try id3Frame(frame, payload))
        }
        for picture in pictures {
            var payload = Data([3])
            payload.append(contentsOf: picture.mime.utf8)
            payload.append(0)
            payload.append(picture.type)
            payload.append(contentsOf: picture.description.utf8)
            payload.append(0)
            payload.append(picture.bytes)
            frames.append(try id3Frame("APIC", payload))
        }
        guard !frames.isEmpty else { return Data() }
        var tag = Data([0x49, 0x44, 0x33, 4, 0, 0])
        tag.append(try synchsafe(frames.count))
        tag.append(frames)
        return tag
    }

    private func id3Frame(_ name: String, _ payload: Data) throws -> Data {
        var frame = Data(name.utf8)
        frame.append(try synchsafe(payload.count))
        frame.append(contentsOf: [0, 0])
        frame.append(payload)
        return frame
    }

    private func synchsafe(_ count: Int) throws -> Data {
        guard count < (1 << 28) else { throw ConversionError.invalidMetadata }
        return Data([UInt8((count >> 21) & 127), UInt8((count >> 14) & 127), UInt8((count >> 7) & 127), UInt8(count & 127)])
    }
}

private struct Cursor {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    init(_ data: Data) { self.data = data }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ConversionError.invalidMetadata }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func u32(little: Bool = false) throws -> UInt32 {
        let bytes = try take(4)
        if little { return bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) } }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
