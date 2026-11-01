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
        for ext in ["docx", "hwp", "hwpx"] {
            #expect(Formats.outputs(for: URL(filePath: "/tmp/report.\(ext)")).map(\.ext) == ["pdf"])
        }
    }

    @Test func hwpBecomesPDFOrWord() {
        for ext in ["hwp", "hwpx"] {
            #expect(Formats.outputs(for: URL(filePath: "/tmp/report.\(ext)")).map(\.ext) == ["pdf", "docx"])
        }
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
