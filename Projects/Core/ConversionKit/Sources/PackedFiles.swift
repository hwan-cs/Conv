import Foundation

/// Several files in one stream, for a conversion whose result is more than one file: a PDF's
/// pages as images.
public enum PackedFiles {
    static let magic = Data("CONVPACK1".utf8)

    public enum PackError: Error, Equatable {
        case malformed
        case countMismatch
    }

    /// Writes the files one after another as they are made.
    public final class Writer {
        private let output: FileHandle
        private let count: Int
        private var written = 0

        public init(url: URL, count: Int) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            output = try FileHandle(forWritingTo: url)
            self.count = count
            try output.write(contentsOf: PackedFiles.magic + PackedFiles.bytes(UInt32(count)))
        }

        deinit {
            try? output.close()
        }

        public func append(_ data: Data) throws {
            guard written < count else {
                throw PackError.countMismatch
            }
            try output.write(contentsOf: PackedFiles.bytes(UInt64(data.count)) + data)
            written += 1
        }

        public func finish() throws {
            guard written == count else {
                throw PackError.countMismatch
            }
            try output.close()
        }
    }

    /// Reads the files back one at a time, as often as needed.
    public struct Reader {
        public let count: Int
        private let handle: FileHandle
        private let start: UInt64

        public init(_ handle: FileHandle) throws {
            self.handle = handle
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: PackedFiles.magic.count + 4) ?? Data()
            guard header.count == PackedFiles.magic.count + 4, header.prefix(PackedFiles.magic.count) == PackedFiles.magic else {
                throw PackError.malformed
            }
            count = Int(PackedFiles.integer(header.suffix(4)))
            start = UInt64(header.count)
        }

        /// Each file in order, with its index from 0.
        public func forEach(_ body: (Int, Data) throws -> Void) throws {
            try handle.seek(toOffset: start)
            for index in 0..<count {
                let length = try handle.read(upToCount: 8) ?? Data()
                guard length.count == 8 else {
                    throw PackError.malformed
                }
                let size = Int(PackedFiles.integer(length))
                let data = size == 0 ? Data() : try handle.read(upToCount: size) ?? Data()
                guard data.count == size else {
                    throw PackError.malformed
                }
                try body(index, data)
            }
        }
    }

    static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func integer(_ data: Data) -> UInt64 {
        data.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
