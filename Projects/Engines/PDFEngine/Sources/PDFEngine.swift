import CoreGraphics
import ConversionKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Entry point the conversion service uses to register this engine's converters.
public enum PDFEngine {
    public static let converters: [any Converter.Type] = []

    public enum ConversionError: Error, Equatable {
        case unreadable
        case passwordProtected
        case unsupportedOutput(String)
        case encodingFailed
    }

    /// Opens a PDF, unlocking one that has only an owner password (no password to open).
    static func document(at url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw ConversionError.unreadable
        }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw ConversionError.passwordProtected
        }
        guard document.numberOfPages > 0 else {
            throw ConversionError.unreadable
        }
        return document
    }
}

/// A PDF's pages as images, each drawn on white the way a viewer shows it.
public struct PDFPageRenderer: Sendable {
    public var dpi: Double = 150
    public var maxPixels = 10_000
    public var quality = 0.9

    public init() {}

    /// Writes the pages of `input` into `output` as `PackedFiles`, in order.
    /// - Parameter format: "jpg" or "png".
    public func render(_ input: URL, as format: String, to output: URL, progress: (Double) -> Void = { _ in }) throws {
        let type: UTType = switch format {
        case "jpg", "jpeg": .jpeg
        case "png": .png
        default:
            throw PDFEngine.ConversionError.unsupportedOutput(format)
        }
        let document = try PDFEngine.document(at: input)
        let writer = try PackedFiles.Writer(url: output, count: document.numberOfPages)
        for number in 1...document.numberOfPages {
            try autoreleasepool {
                guard let page = document.page(at: number), let image = image(of: page) else {
                    throw PDFEngine.ConversionError.unreadable
                }
                try writer.append(encode(image, as: type))
            }
            progress(Double(number) / Double(document.numberOfPages))
        }
        try writer.finish()
    }

    func image(of page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let scale = min(dpi / 72, Double(maxPixels) / max(size.width, size.height))
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw PDFEngine.ConversionError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PDFEngine.ConversionError.encodingFailed
        }
        return data as Data
    }
}

/// PDFs one after another in a single PDF, with their links and annotations.
public struct PDFCombiner: Sendable {
    public enum InputError: Error {
        case failed(index: Int, PDFEngine.ConversionError)
    }

    public init() {}

    public func combine(_ inputs: [URL], to output: URL, progress: (Double) -> Void = { _ in }) throws {
        let combined = PDFDocument()
        var sources: [PDFDocument] = []
        for (index, input) in inputs.enumerated() {
            guard let document = PDFDocument(url: input) else {
                throw InputError.failed(index: index, .unreadable)
            }
            if document.isLocked, !document.unlock(withPassword: "") {
                throw InputError.failed(index: index, .passwordProtected)
            }
            sources.append(document)
            for number in 0..<document.pageCount {
                guard let page = document.page(at: number) else {
                    continue
                }
                combined.insert(page, at: combined.pageCount)
            }
            progress(Double(index + 1) / Double(inputs.count) * 0.8)
        }
        guard combined.pageCount > 0 else {
            throw PDFEngine.ConversionError.unreadable
        }
        guard combined.write(to: output) else {
            throw PDFEngine.ConversionError.encodingFailed
        }
        progress(1)
    }
}
