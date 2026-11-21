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

    private static let avif = UTType("public.avif")

    public init() {}

    public func convert(_ input: URL, to output: URL) throws {
        let ext = output.pathExtension.lowercased()
        guard let type = Self.outputs[ext] else {
            throw ConversionError.unsupportedOutput(ext)
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              Self.decodes(source, at: CGImageSourceGetPrimaryImageIndex(source))
        else {
            throw ConversionError.unreadable
        }

        if type == .pdf {
            try writePDF(source, to: output)
            return
        }
        // Only GIF keeps animation; others take the primary image, which a HEIC need not store first.
        let frames = type == .gif && Self.isAnimated(source)
            ? Array(0..<CGImageSourceGetCount(source))
            : [CGImageSourceGetPrimaryImageIndex(source)]
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, frames.count, nil) else {
            throw ConversionError.unsupportedOutput(ext)
        }
        if frames.count > 1 {
            let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: Self.loopCount(source)]]
            CGImageDestinationSetProperties(destination, loop as CFDictionary)
        }
        let opaque = type == .jpeg || type == .bmp
        for index in frames {
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            if frames.count > 1, let delay = Self.delay(properties) {
                options[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]
            }
            // AVIF drops the orientation tag, so the pixels are turned instead.
            let upright = type == Self.avif && Self.orientation(properties) != .up
            let redraws = upright || (opaque && Self.hasAlpha(properties)) || Self.needsRedraw(properties, of: source, into: type)
            guard redraws else {
                CGImageDestinationAddImageFromSource(destination, source, index, options as CFDictionary)
                continue
            }
            guard let image = Self.redrawn(source, at: index, opaque: opaque, upright: upright) else {
                throw ConversionError.encodingFailed
            }
            CGImageDestinationAddImage(destination, image, Self.metadata(properties, upright: upright).merging(options) { $1 } as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.encodingFailed
        }
    }

    /// One page per frame, each the image's size at its own resolution, upright. The main image comes first.
    private func writePDF(_ source: CGImageSource, to output: URL) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.encodingFailed
        }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let frames = [primary] + (0..<CGImageSourceGetCount(source)).filter { $0 != primary }
        var pages = 0
        for index in frames {
            guard Self.decodes(source, at: index), let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            let orientation = Self.orientation(properties)
            let pixels = Self.uprightSize(of: image, orientation)
            var box = CGRect(origin: .zero, size: Self.pageSize(pixels, dpi: properties[kCGImagePropertyDPIWidth] as? Double))
            context.beginPage(mediaBox: &box)
            context.scaleBy(x: box.width / pixels.width, y: box.height / pixels.height)
            Self.draw(image, upright: orientation, in: context)
            context.endPage()
            pages += 1
        }
        context.closePDF()
        guard pages > 0 else {
            throw ConversionError.unreadable
        }
    }

    /// Page size in points, at 72 dpi when the resolution is missing or gives a page PDF viewers refuse.
    static func pageSize(_ pixels: CGSize, dpi: Double?) -> CGSize {
        let scale = 72 / (dpi.flatMap { $0 > 0 ? $0 : nil } ?? 72)
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        guard max(size.width, size.height) <= 14_400, min(size.width, size.height) >= 1 else {
            let fit = min(1, 14_400 / max(pixels.width, pixels.height))
            return CGSize(width: max(pixels.width * fit, 1), height: max(pixels.height * fit, 1))
        }
        return size
    }

    /// ImageIO returns an image even for HEIF or TIFF it can't decode (4:2:2 AVIF); only missing pixel data tells.
    private static func decodes(_ source: CGImageSource, at index: Int) -> Bool {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            return false
        }
        guard isHEIF(source) || (CGImageSourceGetType(source) as String?) == UTType.tiff.identifier else {
            return true
        }
        return autoreleasepool {
            image.dataProvider?.data != nil
        }
    }

    /// HEIC, HEIF and AVIF alike: `public.heic` doesn't conform to `.heif`, only to this.
    private static let heifFamily = UTType("public.heif-standard")

    private static func isHEIF(_ source: CGImageSource) -> Bool {
        let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        return type.map { type in heifFamily.map(type.conforms) ?? false || type == avif } ?? false
    }

    private static func hasAlpha(_ properties: [CFString: Any]) -> Bool {
        properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// Pixels the encoder would refuse or garble, which are redrawn as 8-bit RGB first.
    private static func needsRedraw(_ properties: [CFString: Any], of source: CGImageSource, into type: UTType) -> Bool {
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let model = properties[kCGImagePropertyColorModel] as? String
        let fromHEIF = isHEIF(source)
        if ![8, 16].contains(depth), !(fromHEIF && [10, 12].contains(depth)) {
            return true
        }
        // The JPEG encoder garbles some decoded HEIF frames; redrawn ones encode correctly.
        if type == .bmp || (type == .jpeg && fromHEIF) {
            return true
        }
        return (type == .heic || type == avif) && model != kCGImagePropertyColorModelRGB as String
    }

    private static func redrawn(_ source: CGImageSource, at index: Int, opaque: Bool, upright: Bool) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            return nil
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        let orientation = upright ? Self.orientation(properties) : .up
        let size = uprightSize(of: image, orientation)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo = opaque || !hasAlpha(properties) ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: alpha.rawValue
        ) else {
            return nil
        }
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        draw(image, upright: orientation, in: context)
        return context.makeImage()
    }

    private static func metadata(_ properties: [CFString: Any], upright: Bool) -> [CFString: Any] {
        let keys = [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight, kCGImagePropertyOrientation,
        ]
        var metadata = properties.filter { keys.contains($0.key) }
        if upright {
            metadata[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
            var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            tiff?[kCGImagePropertyTIFFOrientation] = CGImagePropertyOrientation.up.rawValue
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        return metadata
    }

    private static func orientation(_ properties: [CFString: Any]) -> CGImagePropertyOrientation {
        (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
    }

    private static func uprightSize(of image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            CGSize(width: image.height, height: image.width)
        default:
            CGSize(width: image.width, height: image.height)
        }
    }

    private static func draw(_ image: CGImage, upright orientation: CGImagePropertyOrientation, in context: CGContext) {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Core Graphics' origin is bottom-left, so each EXIF turn is mirrored vertically from its usual form.
        let transform: CGAffineTransform = switch orientation {
        case .up:
            .identity
        case .upMirrored:
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case .down:
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case .downMirrored:
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case .leftMirrored:
            CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case .right:
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case .rightMirrored:
            CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        }
        context.saveGState()
        context.concatenate(transform)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    private static var animations: [(dictionary: CFString, delay: CFString, unclamped: CFString, loop: CFString)] {
        [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSDelayTime, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSLoopCount),
        ]
    }

    /// Frames with timing, unlike TIFF pages or the separate pictures of a HEIC.
    private static func isAnimated(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1 else {
            return false
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        return delay(properties) != nil
    }

    private static func delay(_ properties: [CFString: Any]) -> Double? {
        for animation in animations {
            guard let frame = properties[animation.dictionary] as? [CFString: Any] else {
                continue
            }
            if let delay = (frame[animation.unclamped] as? Double).flatMap({ $0 > 0 ? $0 : nil }) ?? frame[animation.delay] as? Double {
                return delay
            }
        }
        return nil
    }

    /// 0 is forever.
    private static func loopCount(_ source: CGImageSource) -> Int {
        let properties = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any]) ?? [:]
        for animation in animations {
            if let loop = (properties[animation.dictionary] as? [CFString: Any])?[animation.loop] as? Int {
                return loop
            }
        }
        return 0
    }
}
