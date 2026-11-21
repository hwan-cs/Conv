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

    @Test(arguments: ["heic", "avif", "bmp", "jpg"])
    func grayWithAlphaKeepsItsPixels(output: String) throws {
        try #require(Self.canWrite(output))
        let input = try write(Self.grayImage(width: 16, height: 16, bits: 8, alpha: true), as: .png, named: "gray.png")
        let converted = directory.appending(path: "gray.\(output)")
        try ImageConverter().convert(input, to: converted)
        // The left half is opaque black.
        let pixel = try Self.pixel(of: converted, x: 2, y: 8)
        #expect(pixel.prefix(3).allSatisfy { $0 < 40 }, "expected black, got \(pixel)")
    }

    @Test(arguments: ["heic", "avif"])
    func sixteenBitGrayIsWritten(output: String) throws {
        try #require(Self.canWrite(output))
        let input = try write(Self.grayImage(width: 16, height: 16, bits: 16, alpha: false), as: .png, named: "gray16.png")
        let converted = directory.appending(path: "gray16.\(output)")
        try ImageConverter().convert(input, to: converted)
        #expect(try Self.pixel(of: converted, x: 2, y: 8).prefix(3).allSatisfy { $0 < 40 })
    }

    @Test func palettePNGBecomesReadableBMP() throws {
        let input = try write(Self.paletteImage(width: 12, height: 12), as: .png, named: "palette.png")
        let output = directory.appending(path: "palette.bmp")
        try ImageConverter().convert(input, to: output)
        let pixel = try Self.pixel(of: output, x: 1, y: 1)
        #expect(pixel[0] > 200 && pixel[1] < 40 && pixel[2] < 40, "expected red, got \(pixel)")
    }

    @Test func avifTurnsPixelsUpright() throws {
        try #require(Self.canWrite("avif"))
        let input = try write(Self.image(width: 40, height: 20, alpha: false), as: .jpeg, named: "turned.jpg", orientation: 6)
        let output = directory.appending(path: "turned.avif")
        try ImageConverter().convert(input, to: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 40)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func animationKeepsItsTiming() throws {
        let input = try writeAnimatedPNG(frames: 3, delay: 0.25)
        let output = directory.appending(path: "animated.gif")
        try ImageConverter().convert(input, to: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let frame = CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any]
        let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(abs((gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0) - 0.25) < 0.01)
    }

    @Test func tiffPagesDoNotBecomeAnAnimation() throws {
        let url = directory.appending(path: "pages.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, Self.image(width: 8, height: 8, alpha: false), nil)
        CGImageDestinationAddImage(destination, Self.image(width: 8, height: 8, alpha: false), nil)
        #expect(CGImageDestinationFinalize(destination))
        let output = directory.appending(path: "pages.gif")
        try ImageConverter().convert(url, to: output)
        #expect(CGImageSourceGetCount(try #require(CGImageSourceCreateWithURL(output as CFURL, nil))) == 1)
    }

    @Test func pdfOfTransparentHEICIsNotBlack() throws {
        let input = try write(Self.halfRed(width: 32, height: 32), as: .heic, named: "clear.heic")
        let output = directory.appending(path: "clear.pdf")
        try ImageConverter().convert(input, to: output)
        let page = try #require(CGPDFDocument(output as CFURL)?.page(at: 1))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.translateBy(x: -8, y: -16)
        context.drawPDFPage(page)
        #expect(pixel[0] > 200 && pixel[1] < 60, "expected red, got \(pixel)")
    }

    @Test func pageSizeStaysWithinPDFLimits() {
        #expect(ImageConverter.pageSize(CGSize(width: 300, height: 150), dpi: 300) == CGSize(width: 72, height: 36))
        #expect(ImageConverter.pageSize(CGSize(width: 4000, height: 2000), dpi: 1).width <= 14_400)
        #expect(ImageConverter.pageSize(CGSize(width: 40, height: 20), dpi: 10_000).height >= 1)
    }

    // MARK: Helpers

    static func canWrite(_ ext: String) -> Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ImageConverter.outputs[ext].map { identifiers.contains($0.identifier) } ?? false
    }

    /// Black on the left half, then white, opaque or fading out on the right when `alpha`.
    static func grayImage(width: Int, height: Int, bits: Int, alpha: Bool) -> CGImage {
        // Bitmap contexts can't hold gray with alpha, so the pixels are laid out by hand.
        let components = alpha ? 2 : 1
        let bytes = bits / 8
        var pixels = Data(count: width * height * components * bytes)
        for y in 0..<height {
            for x in 0..<width {
                let gray: UInt8 = x < width / 2 ? 0 : 255
                let opacity: UInt8 = x < width / 2 ? 255 : 80
                let offset = ((y * width + x) * components) * bytes
                for byte in 0..<bytes {
                    pixels[offset + byte] = gray
                    if alpha {
                        pixels[offset + bytes + byte] = opacity
                    }
                }
            }
        }
        let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.none).rawValue)
            .union(bits == 16 ? .byteOrder16Big : [])
        return CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components,
            bytesPerRow: width * components * bytes, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
            bitmapInfo: info, provider: CGDataProvider(data: pixels as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Red in a two-color palette.
    static func paletteImage(width: Int, height: Int) -> CGImage {
        let table: [UInt8] = [255, 0, 0, 0, 0, 255]
        let space = CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!, last: 1, colorTable: table)!
        let pixels = Data(repeating: 0, count: width * height)
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: pixels as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Red on the left half, clear on the right.
    static func halfRed(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    func writeAnimatedPNG(frames: Int, delay: Double) throws -> URL {
        let url = directory.appending(path: "animated.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        for _ in 0..<frames {
            let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(destination, Self.image(width: 8, height: 8, alpha: false), properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The pixel at (`x`, `y`) from the top-left, drawn on white.
    static func pixel(of url: URL, x: Int, y: Int) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Array(pixel.prefix(3))
    }

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
