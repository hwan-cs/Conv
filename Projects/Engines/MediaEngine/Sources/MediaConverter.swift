@preconcurrency import AVFoundation
import Foundation

/// Video and audio through AVFoundation: rewrapping or re-encoding video, and audio to AAC or PCM.
public struct MediaConverter: Sendable {
    public enum ConversionError: Error, Equatable {
        case unreadable
        case noAudio
        /// The video's codec is one macOS no longer decodes, such as QuickTime's Animation.
        case undecodable
        case unsupportedOutput(String)
        case exportFailed(String)
    }

    public static let videoInputs: Set<String> = ["mov", "mp4", "m4v"]
    public static let audioInputs: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"]

    public init() {}

    /// - Parameter progress: Called with 0…1 as the conversion goes.
    public func convert(_ input: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: input)
        guard (try? await asset.load(.isReadable)) == true else {
            throw ConversionError.unreadable
        }
        try? FileManager.default.removeItem(at: output)
        switch output.pathExtension.lowercased() {
        case "mp4", "m4v":
            try await exportVideo(asset, to: output, as: .mp4, progress: progress)
        case "mov":
            try await exportVideo(asset, to: output, as: .mov, progress: progress)
        case "m4a":
            try await export(asset, preset: AVAssetExportPresetAppleM4A, to: output, as: .m4a, progress: progress)
        case "wav":
            try await writePCM(asset, to: output, bigEndian: false, progress: progress)
        case "aiff", "aif":
            try await writePCM(asset, to: output, bigEndian: true, progress: progress)
        case "mp3":
            try await MP3Encoder().encode(asset, to: output, progress: progress)
        case "gif":
            try await GIFEncoder().encode(asset, to: output, progress: progress)
        case let ext:
            throw ConversionError.unsupportedOutput(ext)
        }
    }

    private func exportVideo(_ asset: AVURLAsset, to output: URL, as type: AVFileType, progress: @escaping @Sendable (Double) -> Void) async throws {
        let playsAnywhere = try await Self.playsAnywhere(asset)
        let rewraps = type == .mov || playsAnywhere
        if rewraps, await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type) {
            do {
                try await export(asset, preset: AVAssetExportPresetPassthrough, to: output, as: type, progress: progress)
                return
            } catch {
                try? FileManager.default.removeItem(at: output)
            }
        }
        try await Self.requireDecodableVideo(asset)
        try await export(asset, preset: AVAssetExportPresetHighestQuality, to: output, as: type, progress: progress)
    }

    /// Codecs an MP4 plays almost anywhere; others, such as Motion JPEG or ProRes, are re-encoded.
    private static func playsAnywhere(_ asset: AVAsset) async throws -> Bool {
        let video: Set<FourCharCode> = [
            kCMVideoCodecType_H264,
            kCMVideoCodecType_HEVC,
            kCMVideoCodecType_MPEG4Video,
            FourCharCode(0x6865_7631), // hev1
        ]
        let audio: Set<FourCharCode> = [
            kAudioFormatMPEG4AAC,
            kAudioFormatMPEG4AAC_HE,
            kAudioFormatMPEG4AAC_HE_V2,
            kAudioFormatMPEGLayer3,
            kAudioFormatAC3,
            kAudioFormatEnhancedAC3,
        ]
        for track in try await asset.load(.tracks) {
            let allowed: Set<FourCharCode>
            switch track.mediaType {
            case .video:
                allowed = video
            case .audio:
                allowed = audio
            default:
                continue
            }
            for description in try await track.load(.formatDescriptions) where !allowed.contains(CMFormatDescriptionGetMediaSubType(description)) {
                return false
            }
        }
        return true
    }

    static func requireDecodableVideo(_ asset: AVAsset) async throws {
        for track in try await asset.loadTracks(withMediaType: .video) where try await !track.load(.isDecodable) {
            throw ConversionError.undecodable
        }
    }

    private func export(
        _ asset: AVAsset,
        preset: String,
        to output: URL,
        as type: AVFileType,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if type == .m4a, try await asset.loadTracks(withMediaType: .audio).isEmpty {
            throw ConversionError.noAudio
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.exportFailed(preset)
        }
        session.shouldOptimizeForNetworkUse = true
        session.outputURL = output
        session.outputFileType = type
        let box = SessionBox(session)
        let polling = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await withCheckedContinuation { continuation in
            box.session.exportAsynchronously { continuation.resume() }
        }
        polling.cancel()
        guard session.status == .completed else {
            throw ConversionError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
        }
    }

    /// Decodes the first audio track to 16-bit PCM in WAV or AIFF, at its own rate and channels.
    private func writePCM(_ asset: AVAsset, to output: URL, bigEndian: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await PCMReader.read(asset, progress: progress) { format in
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: bigEndian,
            ]
            if let layout = format.channelLayout {
                settings[AVChannelLayoutKey] = PCMReader.data(of: layout)
            }
            let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            return { buffer in try file.write(from: buffer) }
        }
    }
}

/// Decodes an asset's first audio track into float PCM buffers.
enum PCMReader {
    /// - Parameters:
    ///   - channels: The most channels to keep; more are mixed down.
    ///   - makeSink: Called once with the decoded format; returns what receives each buffer.
    static func read(
        _ asset: AVAsset,
        channels limit: AVAudioChannelCount = 8,
        progress: @Sendable (Double) -> Void = { _ in },
        makeSink: (AVAudioFormat) throws -> (AVAudioPCMBuffer) throws -> Void
    ) async throws {
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaConverter.ConversionError.noAudio
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let stream = descriptions.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else {
            throw MediaConverter.ConversionError.unreadable
        }
        let channels = AVAudioChannelCount(max(min(stream.mChannelsPerFrame, limit), 1))
        // Past stereo, a format needs a channel layout.
        let layout = channels > 2 ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) : nil
        let made = layout.map { AVAudioFormat(standardFormatWithSampleRate: stream.mSampleRate, channelLayout: $0) }
            ?? AVAudioFormat(standardFormatWithSampleRate: stream.mSampleRate, channels: channels)
        guard let format = made else {
            throw MediaConverter.ConversionError.unreadable
        }

        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        if let layout {
            settings[AVChannelLayoutKey] = data(of: layout)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw MediaConverter.ConversionError.unreadable
        }
        let sink = try makeSink(format)
        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                continue
            }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
            )
            guard status == noErr else {
                throw MediaConverter.ConversionError.unreadable
            }
            try sink(buffer)
            if duration > 0 {
                progress(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
            }
        }
        if reader.status == .failed {
            throw MediaConverter.ConversionError.exportFailed(reader.error?.localizedDescription ?? "")
        }
    }

    static func data(of layout: AVAudioChannelLayout) -> Data {
        let size = MemoryLayout<AudioChannelLayout>.size
            + max(Int(layout.layout.pointee.mNumberChannelDescriptions) - 1, 0) * MemoryLayout<AudioChannelDescription>.size
        return Data(bytes: layout.layout, count: size)
    }
}

/// AVAssetExportSession is safe to finish from its own completion queue.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    
    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
