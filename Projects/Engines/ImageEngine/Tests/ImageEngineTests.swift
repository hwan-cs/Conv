import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import ImageEngine

@Suite struct ImageConverterTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "image-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test(arguments: ["jpg", "png", "heic", "tiff", "gif", "bmp"])
    func convertsBetweenFormats(output: String) throws {
        let input = try write(Self.image(width: 40, height: 30, alpha: false), as: .png, named: "in.png")
        let converted = directory.appending(path: "out.\(output)")
        try ImageConverter().convert(input, to: converted)
        let source = try #require(CGImageSourceCreateWithURL(converted as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((image.width, image.height) == (40, 30))
        #expect(CGImageSourceGetType(source) as String? == ImageConverter.outputs[output]?.identifier)
    }

    @Test func transparencyBecomesWhiteInJPEG() throws {
        let input = try write(Self.image(width: 8, height: 8, alpha: true), as: .png, named: "clear.png")
        let output = directory.appending(path: "clear.jpg")
        try ImageConverter().convert(input, to: output)
        let pixel = try Self.firstPixel(of: output)
        #expect(pixel.allSatisfy { $0 > 240 }, "expected white, got \(pixel)")
    }

    @Test func orientationIsKept() throws {
        let input = try write(Self.image(width: 40, height: 20, alpha: false), as: .jpeg, named: "rotated.jpg", orientation: 6)
        let output = directory.appending(path: "rotated.heic")
        try ImageConverter().convert(input, to: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test func pdfPagesAreUpright() throws {
        let input = try write(Self.image(width: 40, height: 20, alpha: false), as: .jpeg, named: "page.jpg", orientation: 6)
        let output = directory.appending(path: "page.pdf")
        try ImageConverter().convert(input, to: output)
        let page = try #require(PDFDocument(url: output)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        // Orientation 6 turns the 40×20 pixels a quarter turn: the page is taller than wide.
        #expect((box.width, box.height) == (20, 40))
    }

    @Test func webPCannotBeWritten() throws {
        let input = try write(Self.image(width: 4, height: 4, alpha: false), as: .png, named: "small.png")
        #expect(throws: ImageConverter.ConversionError.unsupportedOutput("webp")) {
            try ImageConverter().convert(input, to: directory.appending(path: "small.webp"))
        }
    }

    @Test func unreadableInputIsReported() throws {
        let input = directory.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: input)
        #expect(throws: ImageConverter.ConversionError.unreadable) {
            try ImageConverter().convert(input, to: directory.appending(path: "broken.jpg"))
        }
    }

    // MARK: Helpers

    /// Red with a transparent top-left pixel when `alpha`.
    static func image(width: Int, height: Int, alpha: Bool) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        if alpha {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    func write(_ image: CGImage, as type: UTType, named name: String, orientation: Int? = nil) throws -> URL {
        let url = directory.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func firstPixel(of url: URL) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(pixel.prefix(3))
    }
}
