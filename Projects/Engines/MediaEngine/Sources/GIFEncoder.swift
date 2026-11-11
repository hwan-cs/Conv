@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A video's frames as a looping GIF, small enough to send in a chat.
struct GIFEncoder {
    /// 10 frames a second. GIF times frames in hundredths of a second; each frame is stored whole,
    /// at about 60 KB for 480 × 270.
    var frameDelay = 0.1
    var maxSide = 480
    var maxFrames = 300

    func encode(_ asset: AVAsset, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw MediaConverter.ConversionError.unreadable
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw MediaConverter.ConversionError.unreadable
        }
        let delay = max(frameDelay, (duration / Double(maxFrames) * 100).rounded(.up) / 100)
        let count = max(Int(duration / delay), 1)
        let times = (0..<count).map { CMTime(seconds: Double($0) * delay, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance = CMTime(seconds: delay / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw MediaConverter.ConversionError.exportFailed("GIF")
        }
        let loop: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        var added = 0
        for await result in generator.images(for: times) {
            guard let image = try? result.image else {
                continue
            }
            CGImageDestinationAddImage(destination, image, frame as CFDictionary)
            added += 1
            progress(Double(added) / Double(count))
        }
        guard added > 0, CGImageDestinationFinalize(destination) else {
            throw MediaConverter.ConversionError.exportFailed("GIF")
        }
    }
}
