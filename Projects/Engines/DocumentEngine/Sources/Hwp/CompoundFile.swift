import Foundation

/// Read-only Compound File Binary (OLE2) reader: the container of .hwp 5.x, as ZIP is for .docx.
///
/// [MS-CFB]: a FAT of sector chains, a directory of red-black trees, and a mini stream
/// holding streams smaller than the cutoff in 64-byte sectors.
struct CompoundFile {
    enum FileError: Error {
        case notACompoundFile
        case corrupt
    }

    private struct Entry {
        var name: String
        var type: UInt8
        var left: UInt32
        var right: UInt32
        var child: UInt32
        var start: UInt32
        var size: Int
    }

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let noStream: UInt32 = 0xFFFF_FFFF

    private let data: Data
    private let sectorSize: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: Data
    private let miniCutoff: Int
    private let entries: [Entry]

    init(data: Data) throws {
        let data = Data(data)
        guard data.count >= 512, data.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else {
            throw FileError.notACompoundFile
        }
        self.data = data
        let shift = Int(data.uint16(at: 0x1E))
        guard (9...12).contains(shift) else { throw FileError.corrupt }
        sectorSize = 1 << shift
        miniCutoff = Int(data.uint32(at: 0x38))

        // The header lists the first 109 FAT sectors; DIFAT sectors chain the rest.
        var fatSectors = (0..<109).map { data.uint32(at: 0x4C + $0 * 4) }
        var difat = data.uint32(at: 0x44)
        var guardCount = 0
        let perSector = sectorSize / 4
        while difat < Self.endOfChain, guardCount < 1 << 16 {
            let offset = (Int(difat) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw FileError.corrupt }
            fatSectors += (0..<perSector - 1).map { data.uint32(at: offset + $0 * 4) }
            difat = data.uint32(at: offset + (perSector - 1) * 4)
            guardCount += 1
        }
        let fatCount = Int(data.uint32(at: 0x2C))
        var fat: [UInt32] = []
        for sector in fatSectors.prefix(fatCount) where sector < Self.endOfChain {
            let offset = (Int(sector) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw FileError.corrupt }
            fat += (0..<perSector).map { data.uint32(at: offset + $0 * 4) }
        }
        self.fat = fat

        let directory = try Self.chain(from: data.uint32(at: 0x30), fat: fat, sectorSize: sectorSize, in: data)
        entries = stride(from: 0, to: directory.count - 127, by: 128).map { offset in
            let nameLength = max(Int(directory.uint16(at: offset + 0x40)) - 2, 0)
            let nameBytes = directory.subdata(in: offset..<offset + min(nameLength, 62))
            return Entry(
                name: String(data: nameBytes, encoding: .utf16LittleEndian) ?? "",
                type: directory[directory.startIndex + offset + 0x42],
                left: directory.uint32(at: offset + 0x44),
                right: directory.uint32(at: offset + 0x48),
                child: directory.uint32(at: offset + 0x4C),
                start: directory.uint32(at: offset + 0x74),
                size: Int(directory.uint32(at: offset + 0x78))
            )
        }
        guard let root = entries.first, root.type == 5 else { throw FileError.corrupt }

        let miniFATData = try Self.chain(from: data.uint32(at: 0x3C), fat: fat, sectorSize: sectorSize, in: data)
        miniFAT = (0..<miniFATData.count / 4).map { miniFATData.uint32(at: $0 * 4) }
        miniStream = try Self.chain(from: root.start, fat: fat, sectorSize: sectorSize, in: data).prefix(root.size)
    }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// The stream at a slash-separated path such as "BodyText/Section0", or nil.
    func stream(_ path: String) throws -> Data? {
        var entry = entries[0]
        for name in path.split(separator: "/") {
            guard let found = child(named: String(name), of: entry) else { return nil }
            entry = found
        }
        guard entry.type == 2 else { return nil }
        if entry.size < miniCutoff {
            return try Self.chain(from: entry.start, fat: miniFAT, sectorSize: 64, in: miniStream, headerSectors: 0)
                .prefix(entry.size)
        }
        return try Self.chain(from: entry.start, fat: fat, sectorSize: sectorSize, in: data).prefix(entry.size)
    }

    /// Names directly inside a storage, e.g. "BinData".
    func names(in path: String = "") -> [String] {
        var entry = entries[0]
        for name in path.split(separator: "/") {
            guard let found = child(named: String(name), of: entry) else { return [] }
            entry = found
        }
        var result: [String] = []
        var stack = [entry.child]
        var visited = Set<UInt32>()
        while let id = stack.popLast() {
            guard id != Self.noStream, Int(id) < entries.count, visited.insert(id).inserted else { continue }
            result.append(entries[Int(id)].name)
            stack += [entries[Int(id)].left, entries[Int(id)].right]
        }
        return result
    }

    private func child(named name: String, of storage: Entry) -> Entry? {
        // Siblings are a red-black tree ordered by length then uppercase name; a walk is simpler and as fast here.
        var stack = [storage.child]
        var visited = Set<UInt32>()
        while let id = stack.popLast() {
            guard id != Self.noStream, Int(id) < entries.count, visited.insert(id).inserted else { continue }
            let entry = entries[Int(id)]
            if entry.name.caseInsensitiveCompare(name) == .orderedSame { return entry }
            stack += [entry.left, entry.right]
        }
        return nil
    }

    private static func chain(
        from start: UInt32,
        fat: [UInt32],
        sectorSize: Int,
        in data: Data,
        headerSectors: Int = 1
    ) throws -> Data {
        var result = Data()
        var sector = start
        var visited = Set<UInt32>()
        while sector < endOfChain {
            let offset = (Int(sector) + headerSectors) * sectorSize
            guard Int(sector) < fat.count, offset < data.count, visited.insert(sector).inserted else {
                throw FileError.corrupt
            }
            // The last sector of a file may be cut short.
            let end = min(offset + sectorSize, data.count)
            result.append(data[(data.startIndex + offset)..<(data.startIndex + end)])
            sector = fat[Int(sector)]
        }
        return result
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func double(at offset: Int) -> Double {
        Double(bitPattern: UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32)
    }

    func int32(at offset: Int) -> Int32 {
        Int32(bitPattern: uint32(at: offset))
    }
}
