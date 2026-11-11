import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image → image (or PDF) through ImageIO, which decodes everything macOS can show and encodes all but WebP.
public struct ImageConverter: Sendable {
    public enum ConversionError: Error, Equatable {
        case unreadable
        case unsupportedOutput(String)
        case encodingFailed
    }

    public static let inputs: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "webp", "tiff", "tif", "gif", "bmp", "avif"]

    public static let outputs: [String: UTType] = [
        "jpg": .jpeg, "png": .png, "heic": .heic, "tiff": .tiff, "gif": .gif, "bmp": .bmp,
        "avif": UTType("public.avif") ?? .image, "pdf": .pdf,
    ]

    public var quality = 0.9

    public init() {}

    public func convert(_ input: URL, to output: URL) throws {
        let ext = output.pathExtension.lowercased()
        guard let type = Self.outputs[ext] else {
            throw ConversionError.unsupportedOutput(ext)
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw ConversionError.unreadable
        }

        if type == .pdf {
            try writePDF(source, to: output)
            return
        }
        // Animation survives only into GIF; every other format takes the first frame.
        let frames = type == .gif ? CGImageSourceGetCount(source) : 1
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, frames, nil) else {
            throw ConversionError.unsupportedOutput(ext)
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        let dropsAlpha = type == .jpeg || type == .bmp
        for index in 0..<frames {
            if dropsAlpha, Self.hasAlpha(source, at: index), let image = CGImageSourceCreateImageAtIndex(source, index, nil) {
                guard let flattened = Self.flattened(image) else {
                    throw ConversionError.encodingFailed
                }
                let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
                CGImageDestinationAddImage(destination, flattened, properties.merging(options) { $1 } as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, index, options as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.encodingFailed
        }
    }

    /// One page per frame, each the image's size at its own resolution, upright.
    private func writePDF(_ source: CGImageSource, to output: URL) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw ConversionError.encodingFailed }
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = Self.upright(source, at: index) else {
                continue
            }
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    private static func hasAlpha(_ source: CGImageSource, at index: Int) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// The frame with its EXIF orientation applied, since a PDF page has no orientation tag.
    private static func upright(_ source: CGImageSource, at index: Int) -> CGImage? {
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // A "thumbnail" at full size is ImageIO's way to get the frame with its orientation applied.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, index, nil)
    }
}
