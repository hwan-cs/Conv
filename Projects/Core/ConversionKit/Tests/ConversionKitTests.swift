import Foundation
import Testing
@testable import ConversionKit

@Suite struct FormatsTests {
    @Test func photosRecommendJPEG() {
        let outputs = Formats.outputs(for: URL(filePath: "/tmp/IMG_2041.HEIC"))
        #expect(outputs.first?.ext == "jpg")
        #expect(outputs.first?.caption.hasPrefix("추천") == true)
        #expect(!outputs.contains { $0.ext == "heic" })
        #expect(outputs.filter(\.isPrimary).count == 4)
    }

    @Test func aFormatIsNeverOfferedToItself() {
        for ext in ["jpg", "jpeg", "png", "gif", "tiff", "tif"] {
            let outputs = Formats.outputs(for: URL(filePath: "/tmp/image.\(ext)"))
            let same = ext == "jpeg" ? "jpg" : ext == "tif" ? "tiff" : ext
            #expect(!outputs.contains { $0.ext == same }, "\(ext) offered \(same)")
        }
    }

    @Test func webPIsReadButNotWritten() {
        let outputs = Formats.outputs(for: URL(filePath: "/tmp/sticker.webp"))
        #expect(outputs.first?.ext == "jpg")
        #expect(!outputs.contains { $0.ext == "webp" })
    }

    @Test func documentsBecomePDF() {
        #expect(Formats.outputs(for: URL(filePath: "/tmp/report.docx")).map(\.ext) == ["pdf"])
    }

    @Test func hwpBecomesPDFOrWord() {
        for ext in ["hwp", "hwpx"] {
            #expect(Formats.outputs(for: URL(filePath: "/tmp/report.\(ext)")).map(\.ext) == ["pdf", "docx"])
        }
    }

    @Test func videosBecomeMP4TheirSoundOrGIF() {
        #expect(Formats.outputs(for: URL(filePath: "/tmp/clip.MOV")).map(\.ext) == ["mp4", "m4a", "mp3", "gif"])
        #expect(Formats.outputs(for: URL(filePath: "/tmp/clip.mp4")).map(\.ext) == ["mov", "m4a", "mp3", "gif"])
    }

    @Test func pdfPagesBecomeImages() {
        let pdf = URL(filePath: "/tmp/slides.PDF")
        #expect(Formats.outputs(for: pdf).map(\.ext) == ["jpg", "png"])
        #expect(Formats.splitsPages(pdf))
        #expect(!Formats.splitsPages(URL(filePath: "/tmp/photo.jpg")))
    }

    @Test func severalImagesBecomeOnePDF() {
        let photos = ["a.heic", "b.jpg"].map { URL(filePath: "/tmp/\($0)") }
        let outputs = Formats.outputs(for: photos)
        #expect(Array(outputs.map(\.ext).prefix(2)) == ["png", "pdf"])
        #expect(outputs.filter { $0.ext == "pdf" }.map(\.combines) == [true])
        // One image still becomes a PDF of its own.
        #expect(Formats.outputs(for: [photos[0]]).first { $0.ext == "pdf" }?.combines == false)
    }

    @Test func severalPDFsCombineFirst() {
        let files = ["a.pdf", "b.pdf", "c.png"].map { URL(filePath: "/tmp/\($0)") }
        let outputs = Formats.outputs(for: files)
        #expect(outputs.first?.combines == true)
        #expect(outputs.first?.caption.hasPrefix("추천") == true)
        #expect(Formats.outputs(for: [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/clip.mov")]).isEmpty)
    }

    @Test func soundsRecommendMP3UnlessAlreadyMP3() {
        #expect(Formats.outputs(for: URL(filePath: "/tmp/memo.m4a")).first?.ext == "mp3")
        #expect(Formats.outputs(for: URL(filePath: "/tmp/song.mp3")).map(\.ext) == ["m4a", "wav", "aiff"])
        #expect(Formats.outputs(for: URL(filePath: "/tmp/take.aif")).map(\.ext) == ["mp3", "m4a", "wav"])
    }

    @Test func markdownBecomesPDFOrHTML() {
        #expect(Formats.outputs(for: URL(filePath: "/tmp/README.md")).map(\.ext) == ["pdf", "html"])
        #expect(Formats.outputs(for: URL(filePath: "/tmp/notes.markdown")).first?.caption.hasPrefix("추천") == true)
    }

    @Test func unknownFilesHaveNoOutputs() {
        #expect(Formats.outputs(for: URL(filePath: "/tmp/archive.zip")).isEmpty)
    }
}

@Suite struct PackedFilesTests {
    @Test func filesComeBackInOrderAsOftenAsAsked() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "packed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let files = [Data("first".utf8), Data(), Data(repeating: 7, count: 100_000)]
        let writer = try PackedFiles.Writer(url: url, count: files.count)
        for file in files { try writer.append(file) }
        try writer.finish()

        let reader = try PackedFiles.Reader(FileHandle(forReadingFrom: url))
        #expect(reader.count == 3)
        for _ in 0..<2 {
            var read: [Data] = []
            try reader.forEach { index, data in
                #expect(index == read.count)
                read.append(data)
            }
            #expect(read == files)
        }
    }

    @Test func anythingElseIsMalformed() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "packed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("PK\u{3}\u{4} a zip".utf8).write(to: url)
        #expect(throws: PackedFiles.PackError.malformed) { try PackedFiles.Reader(FileHandle(forReadingFrom: url)) }
    }
}
