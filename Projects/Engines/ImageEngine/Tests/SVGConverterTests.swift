import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import ImageEngine

@Suite struct SVGConverterTests {
    let directory: URL
    let svg: URL

    /// A 100×50 badge: a red square on the left, the rest transparent.
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "svg-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        svg = directory.appending(path: "badge.svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50">
            <rect x="10" y="10" width="30" height="30" fill="#FF0000"/>
            <text x="50" y="30" font-size="12">한글</text>
            </svg>
            """.utf8
        ).write(to: svg)
    }

    @Test func pngIsSharpAndKeepsTransparency() async throws {
        let output = directory.appending(path: "badge.png")
        try await SVGConverter().convert(
            svg,
            to: output
        )
        let image = try Self.image(at: output)
        // 100 points grows to the 1024-pixel minimum.
        #expect((image.width, image.height) == (1024, 512))
        #expect(try Self.pixel(of: output, x: 0, y: 0)[3] == 0)
        #expect(try Self.pixel(of: output, x: 250, y: 250).prefix(3) == [255, 0, 0])
    }

    @Test func jpegFillsTransparencyWithWhite() async throws {
        let output = directory.appending(path: "badge.jpg")
        try await SVGConverter().convert(
            svg,
            to: output
        )
        let corner = try Self.pixel(of: output, x: 0, y: 0)
        #expect(corner.prefix(3).allSatisfy { $0 > 240 }, "expected white, got \(corner)")
    }

    @Test func pdfIsOnePageTheSVGsSize() async throws {
        let output = directory.appending(path: "badge.pdf")
        try await SVGConverter().convert(
            svg,
            to: output
        )
        let document = try #require(PDFDocument(url: output))
        let page = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(document.pageCount == 1)
        #expect((page.width, page.height) == (100, 50))
    }

    /// AppKit's PDFs wash out fills drawn under a gradient that fades to transparent, nearly to
    /// white. WebKit's keep the fill, though the fade prints as a flat tint.
    @Test func pdfKeepsFillsUnderFadingGradient() async throws {
        let faded = directory.appending(path: "faded.svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">
            <rect width="100" height="50" fill="#6F2CFF"/>
            <rect width="100" height="50" fill="url(#fade)" fill-opacity="0.16"/>
            <defs>
            <linearGradient id="fade" x1="0" y1="0" x2="0" y2="50" gradientUnits="userSpaceOnUse">
            <stop stop-color="white"/>
            <stop offset="1" stop-color="white" stop-opacity="0"/>
            </linearGradient>
            </defs>
            </svg>
            """.utf8
        ).write(to: faded)
        let output = directory.appending(path: "faded.pdf")
        try await SVGConverter().convert(
            faded,
            to: output
        )
        let page = try #require(PDFDocument(url: output)?.page(at: 0))
        let thumbnail = page.thumbnail(
            of: CGSize(width: 100, height: 50),
            for: .mediaBox
        )
        let bitmap = try #require(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try #require(bitmap.colorAt(x: 50, y: 40)?.usingColorSpace(.sRGB))
        #expect(
            color.blueComponent > 0.9 && color.greenComponent < 0.6,
            "expected purple, got \(color)"
        )
    }

    @Test func pdfKeepsAFadeToTransparent() async throws {
        let faded = directory.appending(path: "fade.svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">
            <defs><linearGradient id="g"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="red" stop-opacity="0"/></linearGradient></defs>
            <rect width="200" height="100" fill="url(#g)"/>
            </svg>
            """.utf8
        ).write(to: faded)
        let output = directory.appending(path: "fade.pdf")
        try await SVGConverter().convert(
            faded,
            to: output
        )
        let page = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 200, height: 100))
        let thumbnail = page.thumbnail(
            of: CGSize(width: 200, height: 100),
            for: .mediaBox
        )
        let bitmap = try #require(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let left = try #require(bitmap.colorAt(x: 5, y: 50)?.usingColorSpace(.sRGB))
        let right = try #require(bitmap.colorAt(x: 195, y: 50)?.usingColorSpace(.sRGB))
        #expect(left.redComponent > 0.9 && left.greenComponent < 0.3, "expected red, got \(left)")
        #expect(right.greenComponent > 0.8, "expected the fade, got \(right)")
    }

    @Test func fadeIsToldFromSolidStops() {
        #expect(SVGConverter.fadesToTransparent(Data("<stop stop-opacity=\"0\"/>".utf8)))
        #expect(SVGConverter.fadesToTransparent(Data("<stop style=\"stop-opacity:.4\"/>".utf8)))
        #expect(SVGConverter.fadesToTransparent(Data("<stop stop-color=\"rgba(0,0,0,0)\"/>".utf8)))
        #expect(!SVGConverter.fadesToTransparent(Data("<stop stop-opacity=\"1\"/><stop stop-opacity=\"1.0\"/>".utf8)))
        #expect(!SVGConverter.fadesToTransparent(Data("<stop stop-color=\"#ff0000\"/>".utf8)))
    }

    @Test func hugePDFPageIsShrunkToTheLimit() async throws {
        let huge = directory.appending(path: "huge.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50000\" height=\"25000\" viewBox=\"0 0 2 1\"><rect width=\"2\" height=\"1\" fill=\"navy\"/></svg>".utf8)
            .write(to: huge)
        let output = directory.appending(path: "huge.pdf")
        try await SVGConverter().convert(
            huge,
            to: output
        )
        let page = try #require(PDFDocument(url: output)?.page(at: 0)).bounds(for: .mediaBox)
        #expect((page.width, page.height) == (14_400, 7_200))
    }

    @Test func largeSVGIsCappedInPixels() async throws {
        let large = directory.appending(path: "large.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6000\" height=\"3000\"><rect width=\"6000\" height=\"3000\"/></svg>".utf8)
            .write(to: large)
        let output = directory.appending(path: "large.png")
        try await SVGConverter().convert(
            large,
            to: output
        )
        let image = try Self.image(at: output)
        #expect((image.width, image.height) == (8192, 4096))
    }

    @Test func brokenSVGIsReported() async throws {
        let broken = directory.appending(path: "broken.svg")
        try Data("not svg".utf8).write(to: broken)
        await #expect(throws: SVGConverter.ConversionError.unreadable) {
            try await SVGConverter().convert(
                broken,
                to: directory.appending(path: "broken.png")
            )
        }
    }

    // MARK: Helpers

    static func image(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// RGBA at a pixel counted from the top left.
    static func pixel(of url: URL, x: Int, y: Int) throws -> [UInt8] {
        let image = try image(at: url)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(
            image,
            in: CGRect(
                x: -x,
                y: y - image.height + 1,
                width: image.width,
                height: image.height
            )
        )
        return pixel
    }
}
