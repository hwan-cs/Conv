import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import DesignSystem

@Suite struct StickerStyleTests {
    @Test(arguments: ["jpg", "JPG", ".jpg", ".JPEG", " jpeg "])
    func aliasesShareTheJPGStyle(ext: String) {
        #expect(StickerStyle.forExtension(ext) == StickerStyle.forExtension("jpg"))
    }

    @Test func relatedFormatsShareAStyle() {
        #expect(StickerStyle.forExtension("hwpx") == StickerStyle.forExtension("hwp"))
        #expect(StickerStyle.forExtension("heif") == StickerStyle.forExtension("heic"))
    }

    @Test func distinctFormatsLookDistinct() {
        #expect(StickerStyle.forExtension("pdf") != StickerStyle.forExtension("png"))
    }

    @Test func unknownFormatFallsBackToPaper() {
        #expect(StickerStyle.forExtension("xyz") == StickerStyle(fill: ConvColor.white, text: ConvColor.ink))
    }

    @Test func labelIsDottedUppercase() {
        #expect(StickerStyle.label(for: "jpeg") == ".JPEG")
        #expect(StickerStyle.label(for: "..hwp") == ".HWP")
    }
}

@Suite struct ConvFontTests {
    @Test func bundledFontsRegister() {
        ConvFont.register()
        for name in ["Pretendard-ExtraBold", "Pretendard-Regular", "JetBrainsMono-Bold"] {
            #expect(NSFont(name: name, size: 12) != nil, "\(name) is not available")
        }
    }
}

@MainActor
@Suite struct GallerySnapshotTests {
    @Test func gallery() {
        ConvFont.register()
        let view = NSHostingView(rootView: DesignSystemGallery())
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        assertSnapshot(of: view, as: .image(precision: 0.98))
    }
}
