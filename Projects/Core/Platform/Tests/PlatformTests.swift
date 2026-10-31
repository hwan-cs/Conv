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
