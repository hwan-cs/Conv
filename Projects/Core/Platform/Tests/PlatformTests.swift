import ConversionKit
import Foundation
import Testing
@testable import Platform

@MainActor
@Suite struct ConversionHistoryTests {
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "ConversionHistoryTests-\(UUID().uuidString)"))
    }

    @Test func newestComesFirstAndSurvivesRelaunch() {
        let history = ConversionHistory(defaults: defaults)
        history.record(input: URL(filePath: "/tmp/IMG_2041.HEIC"), output: URL(filePath: "/tmp/IMG_2041.jpg"))
        history.record(input: URL(filePath: "/tmp/README.md"), output: URL(filePath: "/tmp/README.pdf"))
        let relaunched = ConversionHistory(defaults: defaults)
        #expect(relaunched.entries.map(\.inputName) == ["README.md", "IMG_2041.HEIC"])
        #expect(relaunched.entries.first?.outputExtension == "pdf")
        #expect(relaunched.entries.last?.inputExtension == "heic")
    }

    @Test func keepsTheLastTwenty() {
        let history = ConversionHistory(defaults: defaults)
        for index in 0..<25 {
            history.record(input: URL(filePath: "/tmp/\(index).png"), output: URL(filePath: "/tmp/\(index).jpg"))
        }
        #expect(history.entries.count == 20)
        #expect(history.entries.first?.inputName == "24.png")
    }
}

@MainActor
@Suite struct ConversionInboxTests {
    @Test func aDeliveryIsTakenOnce() {
        let inbox = ConversionInbox()
        inbox.send([URL(filePath: "/tmp/a.png")], isPasted: true)
        let delivery = inbox.take()
        #expect(delivery?.urls.count == 1 && delivery?.isPasted == true)
        #expect(inbox.take() == nil)
    }

    @Test func finderSendsTheFormatPickedAndWhetherAFolderIsMissing() {
        let inbox = ConversionInbox()
        inbox.send([URL(filePath: "/tmp/IMG_2041.heic")], format: "jpg", needsFolderAccess: true)
        let delivery = inbox.take()
        #expect(delivery?.format == "jpg" && delivery?.needsFolderAccess == true)
    }

    @Test func nothingIsSentForNoFiles() {
        let inbox = ConversionInbox()
        inbox.send([])
        #expect(inbox.delivery == nil)
    }
}

@MainActor
@Suite struct FolderAccessTests {
    @Test func filesInsideAnAllowedFolderAreCovered() throws {
        let defaults = try #require(UserDefaults(suiteName: "FolderAccessTests-\(UUID())"))
        let access = FolderAccess(defaults: defaults)
        #expect(!access.covers([URL(filePath: "/Users/me/Desktop/a.heic")]))
        access.add(URL(filePath: "/Users/me/Desktop", directoryHint: .isDirectory))
        #expect(access.covers([URL(filePath: "/Users/me/Desktop/a.heic"), URL(filePath: "/Users/me/Desktop/sub/b.png")]))
        // A sibling whose name only starts the same isn't inside.
        #expect(!access.covers([URL(filePath: "/Users/me/Desktop2/a.heic")]))
        access.remove(URL(filePath: "/Users/me/Desktop", directoryHint: .isDirectory))
        #expect(!access.covers([URL(filePath: "/Users/me/Desktop/a.heic")]))
    }
}

@Suite struct SiblingNumberingTests {
    @Test func copiesAreNumberedAsFinderDoes() {
        let pdf = URL(filePath: "/Users/me/보고서.pdf")
        #expect(SiblingWriter.numbered(pdf, 1) == pdf)
        #expect(SiblingWriter.numbered(pdf, 2).path == "/Users/me/보고서 2.pdf")
    }
}

@Suite struct SiblingWriterManyTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sibling-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func pages(_ count: Int) throws -> PackedFiles.Reader {
        let url = directory.appending(path: "packed-\(UUID().uuidString)")
        let writer = try PackedFiles.Writer(url: url, count: count)
        for index in 0..<count { try writer.append(Data("page \(index)".utf8)) }
        try writer.finish()
        return try PackedFiles.Reader(FileHandle(forReadingFrom: url))
    }

    @Test func pagesGoInAFolderNamedAfterThePDF() throws {
        let pdf = directory.appending(path: "v1.2 보고서.pdf")
        let folder = try SiblingWriter.writePages(pages(12), nextTo: pdf, extension: "jpg", keepingBoth: true)
        #expect(folder.lastPathComponent == "v1.2 보고서")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.first == "v1.2 보고서-01.jpg" && names.last == "v1.2 보고서-12.jpg" && names.count == 12)
        // Again: a second folder rather than mixing pages.
        let again = try SiblingWriter.writePages(pages(2), nextTo: pdf, extension: "jpg", keepingBoth: true)
        #expect(again.lastPathComponent == "v1.2 보고서 2")
        #expect(throws: SiblingWriter.WriteError.self) {
            try SiblingWriter.writePages(pages(2), nextTo: pdf, extension: "jpg", keepingBoth: false)
        }
    }

    @Test func aSinglePageSitsBesideThePDF() throws {
        let pdf = directory.appending(path: "poster.pdf")
        try Data().write(to: pdf)
        let image = try SiblingWriter.writePages(pages(1), nextTo: pdf, extension: "png", keepingBoth: true)
        #expect(image.lastPathComponent == "poster.png")
        #expect(try Data(contentsOf: image) == Data("page 0".utf8))
    }

    @Test func combinedFilesAreNamedAfterTheFirst() throws {
        let files = ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"].map { directory.appending(path: $0) }
        #expect(SiblingWriter.combinedName(of: files, extension: "pdf").lastPathComponent == "IMG_1 외 2개.pdf")
        let source = directory.appending(path: "source.pdf")
        try Data("pdf".utf8).write(to: source)
        let handle = try FileHandle(forReadingFrom: source)
        let first = try SiblingWriter.copyCombined(handle, of: files, extension: "pdf", keepingBoth: true)
        let second = try SiblingWriter.copyCombined(handle, of: files, extension: "pdf", keepingBoth: true)
        #expect(first.lastPathComponent == "IMG_1 외 2개.pdf")
        #expect(second.lastPathComponent == "IMG_1 외 2개 2.pdf")
        #expect(try Data(contentsOf: second) == Data("pdf".utf8))
    }
}
