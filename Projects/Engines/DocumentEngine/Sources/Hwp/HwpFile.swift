import Compression
import Foundation

/// A .hwp 5.x document: the compound file, its header flags, and its record streams.
///
/// Follows the published "한글 문서 파일 형식 5.0" specification (revision 1.3).
struct HwpFile {
    enum HwpError: Error {
        case notAnHwp
        case unsupportedVersion(String)
        case passwordProtected
        case corrupt
    }

    struct Version: Comparable, CustomStringConvertible {
        var raw: UInt32

        var description: String {
            "\(raw >> 24).\(raw >> 16 & 0xFF).\(raw >> 8 & 0xFF).\(raw & 0xFF)"
        }

        static func < (lhs: Version, rhs: Version) -> Bool { lhs.raw < rhs.raw }
    }

    let container: CompoundFile
    let version: Version
    let isCompressed: Bool
    let isDistribution: Bool

    init(url: URL) throws {
        do {
            container = try CompoundFile(url: url)
        } catch {
            let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 23)) ?? nil
            if let head, String(decoding: head, as: UTF8.self).hasPrefix("HWP Document File V") {
                throw HwpError.unsupportedVersion(String(decoding: head.suffix(4), as: UTF8.self))
            }
            throw HwpError.notAnHwp
        }
        guard let header = try container.stream("FileHeader"), header.count >= 40,
              String(data: header.prefix(17), encoding: .ascii) == "HWP Document File"
        else {
            throw HwpError.notAnHwp
        }
        version = Version(raw: header.uint32(at: 32))
        guard version.raw >> 24 == 5 else {
            throw HwpError.unsupportedVersion(version.description)
        }
        let flags = header.uint32(at: 36)
        isCompressed = flags & 1 != 0
        if flags & 2 != 0 {
            throw HwpError.passwordProtected
        }
        isDistribution = flags & 4 != 0
    }

    var sectionCount: Int {
        container.names(in: isDistribution ? "ViewText" : "BodyText").count
    }

    func docInfo() throws -> [HwpRecord] {
        guard let stream = try container.stream("DocInfo") else {
            throw HwpError.corrupt
        }
        return try HwpRecord.parse(decompressed(stream))
    }

    func section(_ index: Int) throws -> [HwpRecord] {
        if isDistribution {
            guard let stream = try container.stream("ViewText/Section\(index)") else {
                throw HwpError.corrupt
            }
            return try HwpRecord.parse(decompressed(HwpDistribution.decrypt(stream)))
        }
        guard let stream = try container.stream("BodyText/Section\(index)") else {
            throw HwpError.corrupt
        }
        return try HwpRecord.parse(decompressed(stream))
    }

    /// An embedded file such as "BIN0001.png", decompressed when the document is.
    func binData(named name: String) throws -> Data? {
        guard let stream = try container.stream("BinData/\(name)") else {
            return nil
        }
        return (try? decompressed(stream)) ?? stream
    }

    private func decompressed(_ data: Data) throws -> Data {
        guard isCompressed else {
            return data
        }
        return try Self.inflate(data)
    }

    /// Raw DEFLATE, which Compression calls zlib.
    static func inflate(_ data: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.decompress, using: .zlib) { output.append($0 ?? Data()) }
        try filter.write(data)
        try filter.finalize()
        guard !output.isEmpty || data.isEmpty else {
            throw HwpError.corrupt
        }
        return output
    }
}

/// One tag/level/size record; DocInfo and each section are flat sequences of them. Nnesting given by `level`.
struct HwpRecord {
    let tag: Int
    let level: Int
    let payload: Data

    static func parse(_ data: Data) throws -> [HwpRecord] {
        var records: [HwpRecord] = []
        var offset = 0
        while offset + 4 <= data.count {
            let header = data.uint32(at: offset)
            var size = Int(header >> 20)
            offset += 4
            if size == 0xFFF {
                size = Int(data.uint32(at: offset))
                offset += 4
            }
            guard offset + size <= data.count else {
                throw HwpFile.HwpError.corrupt
            }
            let start = data.startIndex + offset
            records.append(HwpRecord(
                tag: Int(header & 0x3FF),
                level: Int(header >> 10 & 0x3FF),
                payload: data.subdata(in: start..<start + size)
            ))
            offset += size
        }
        return records
    }
}

enum HwpTag {
    static let begin = 0x10
    static let documentProperties = begin
    static let idMappings = begin + 1
    static let binData = begin + 2
    static let faceName = begin + 3
    static let borderFill = begin + 4
    static let charShape = begin + 5
    static let tabDef = begin + 6
    static let numbering = begin + 7
    static let bullet = begin + 8
    static let paraShape = begin + 9
    static let style = begin + 10
    static let distributeDocData = begin + 12
    // BodyText
    static let paraHeader = begin + 50
    static let paraText = begin + 51
    static let paraCharShape = begin + 52
    static let paraLineSeg = begin + 53
    static let paraRangeTag = begin + 54
    static let ctrlHeader = begin + 55
    static let listHeader = begin + 56
    static let pageDef = begin + 57
    static let footnoteShape = begin + 58
    static let pageBorderFill = begin + 59
    static let shapeComponent = begin + 60
    static let table = begin + 61
    static let shapeComponentLine = begin + 62
    static let shapeComponentRectangle = begin + 63
    static let shapeComponentEllipse = begin + 64
    static let shapeComponentArc = begin + 65
    static let shapeComponentPolygon = begin + 66
    static let shapeComponentCurve = begin + 67
    static let shapeComponentOLE = begin + 68
    static let shapeComponentPicture = begin + 69
    static let shapeComponentContainer = begin + 70
    static let ctrlData = begin + 71
    static let eqEdit = begin + 72
    static let shapeComponentTextArt = begin + 74
    static let formObject = begin + 75
    static let memoShape = begin + 76
    static let memoList = begin + 77
    static let chartData = begin + 79
}
