import Foundation

enum WebMMetadata {
    private enum ID {
        static let ebml: UInt64 = 0x1A45DFA3
        static let docType: UInt64 = 0x4282
        static let segment: UInt64 = 0x18538067
        static let info: UInt64 = 0x1549A966
        static let tracks: UInt64 = 0x1654AE6B
        static let cluster: UInt64 = 0x1F43B675
        static let timestampScale: UInt64 = 0x2AD7B1
        static let duration: UInt64 = 0x4489
        static let trackEntry: UInt64 = 0xAE
        static let trackType: UInt64 = 0x83
        static let enabled: UInt64 = 0xB9
        static let codec: UInt64 = 0x86
        static let video: UInt64 = 0xE0
        static let pixelWidth: UInt64 = 0xB0
        static let pixelHeight: UInt64 = 0xBA
        static let defaultDuration: UInt64 = 0x23E383
    }

    static func inspect(_ url: URL) throws -> VideoMetadata {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let end = try input.seekToEnd()
        let reader = Reader(input: input)
        let header = try reader.element(at: 0, before: end)
        guard header.id == ID.ebml,
              let docType = try reader.children(of: header).first(where: { $0.id == ID.docType }),
              try reader.string(docType) == "webm" else { throw invalid }

        var offset = header.bytes.upperBound
        var segment: Element?
        for _ in 0..<10_000 where offset < end {
            let element = try reader.element(at: offset, before: end)
            if element.id == ID.segment { segment = element; break }
            offset = element.bytes.upperBound
        }
        guard let segment else { throw invalid }

        var info: Element?
        var tracks: Element?
        var hasMedia = false
        offset = segment.bytes.lowerBound
        for _ in 0..<10_000 where offset < segment.bytes.upperBound {
            let element = try reader.element(at: offset, before: segment.bytes.upperBound)
            switch element.id {
            case ID.info: info = element
            case ID.tracks: tracks = element
            case ID.cluster: hasMedia = hasMedia || !element.bytes.isEmpty
            default: break
            }
            if info != nil && tracks != nil && hasMedia { break }
            offset = element.bytes.upperBound
        }
        guard let info, let tracks, hasMedia else { throw invalid }
        let timeFields = try reader.children(of: info)
        let scale = try timeFields.first(where: { $0.id == ID.timestampScale }).map(reader.integer) ?? 1_000_000
        guard let durationField = timeFields.first(where: { $0.id == ID.duration }) else {
            throw WorkspaceError("Choose a WebM export with a known duration.")
        }
        let seconds = try reader.floatingPoint(durationField) * Double(scale) / 1_000_000_000
        guard seconds.isFinite, seconds > 0, seconds <= 600 else {
            throw WorkspaceError("Choose a playable video of up to ten minutes.")
        }

        for entry in try reader.children(of: tracks) where entry.id == ID.trackEntry {
            let fields = try reader.children(of: entry)
            guard let type = fields.first(where: { $0.id == ID.trackType }), try reader.integer(type) == 1,
                  try fields.first(where: { $0.id == ID.enabled }).map(reader.integer) != 0,
                  let codec = fields.first(where: { $0.id == ID.codec }),
                  ["V_VP8", "V_VP9", "V_AV1"].contains(try reader.string(codec)),
                  let video = fields.first(where: { $0.id == ID.video }) else { continue }
            let dimensions = try reader.children(of: video)
            guard let width = try dimensions.first(where: { $0.id == ID.pixelWidth }).map(reader.integer),
                  let height = try dimensions.first(where: { $0.id == ID.pixelHeight }).map(reader.integer),
                  (360...4096).contains(width), (360...4096).contains(height) else {
                throw WorkspaceError("Video width and height must each be between 360 and 4,096 pixels.")
            }
            let nanoseconds = try fields.first(where: { $0.id == ID.defaultDuration }).map(reader.integer) ?? 0
            // Nanosecond precision can encode 60 fps as slightly above 60.
            let rate = nanoseconds > 0 ? Float((1_000_000_000_000 / Double(nanoseconds)).rounded() / 1_000) : 0
            return VideoMetadata(duration: seconds, width: Int(width), height: Int(height), frameRate: rate)
        }
        throw invalid
    }

    private static var invalid: WorkspaceError { WorkspaceError("This file couldn’t be read as a WebM video.") }

    private struct Element {
        let id: UInt64
        let bytes: Range<UInt64>
    }

    private struct Reader {
        let input: FileHandle

        func element(at offset: UInt64, before end: UInt64) throws -> Element {
            try input.seek(toOffset: offset)
            let header = try input.read(upToCount: Int(min(12, end - offset))) ?? Data()
            let (id, idLength, _) = try number(in: header, at: 0, maxLength: 4, stripMarker: false)
            let (size, sizeLength, unknown) = try number(in: header, at: idLength, maxLength: 8, stripMarker: true)
            let start = offset + UInt64(idLength + sizeLength)
            guard start <= end, unknown ? [ID.segment, ID.cluster].contains(id) : size <= end - start else {
                throw invalid
            }
            return Element(id: id, bytes: start..<(unknown ? end : start + size))
        }

        func children(of parent: Element) throws -> [Element] {
            var result: [Element] = []
            var offset = parent.bytes.lowerBound
            while offset < parent.bytes.upperBound {
                guard result.count < 10_000 else { throw invalid }
                let child = try element(at: offset, before: parent.bytes.upperBound)
                result.append(child)
                offset = child.bytes.upperBound
            }
            return result
        }

        func integer(_ element: Element) throws -> UInt64 {
            try bytes(element, maximum: 8).reduce(0) { ($0 << 8) | UInt64($1) }
        }

        func floatingPoint(_ element: Element) throws -> Double {
            let value = try integer(element)
            switch element.bytes.upperBound - element.bytes.lowerBound {
            case 4: return Double(Float(bitPattern: UInt32(value)))
            case 8: return Double(bitPattern: value)
            default: throw invalid
            }
        }

        func string(_ element: Element) throws -> String {
            String(decoding: try bytes(element, maximum: 64), as: UTF8.self)
        }

        private func bytes(_ element: Element, maximum: UInt64) throws -> Data {
            let length = element.bytes.upperBound - element.bytes.lowerBound
            guard length <= maximum else { throw invalid }
            if length == 0 { return Data() }
            try input.seek(toOffset: element.bytes.lowerBound)
            guard let data = try input.read(upToCount: Int(length)), data.count == Int(length) else { throw invalid }
            return data
        }

        private func number(in data: Data, at start: Int, maxLength: Int,
                            stripMarker: Bool) throws -> (UInt64, Int, Bool) {
            guard start < data.count, data[start] != 0 else { throw invalid }
            let first = data[start]
            let length = first.leadingZeroBitCount + 1
            guard length <= maxLength, start + length <= data.count else { throw invalid }
            let mask = UInt8(0x80) >> (length - 1)
            var value = UInt64(stripMarker ? first & (mask - 1) : first)
            for byte in data[(start + 1)..<(start + length)] { value = (value << 8) | UInt64(byte) }
            let unknown = stripMarker && value == (1 << (length * 7)) - 1
            return (value, length, unknown)
        }
    }
}
