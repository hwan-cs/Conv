@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import MediaEngine

@Suite(.timeLimit(.minutes(1))) struct MediaConverterTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "media-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test(arguments: ["mp3", "m4a", "wav", "aiff"])
    func convertsAudio(output: String) async throws {
        let input = try writeTone(seconds: 2, channels: 2, named: "tone.wav")
        let converted = directory.appending(path: "tone.\(output)")
        try await MediaConverter().convert(input, to: converted)
        let duration = try await AVURLAsset(url: converted).load(.duration).seconds
        // Encoders pad a frame or two.
        #expect(abs(duration - 2) < 0.1, "\(output) lasts \(duration)s")
    }

    @Test func mp3IsVariableBitRateWithAHeader() async throws {
        let input = try writeTone(seconds: 3, channels: 1, named: "mono.wav")
        let output = directory.appending(path: "mono.mp3")
        try await MediaConverter().convert(input, to: output)
        let data = try Data(contentsOf: output)
        // The first frame carries LAME's "Xing" (VBR) or "Info" (CBR) tag.
        #expect(data.range(of: Data("Xing".utf8)) != nil || data.range(of: Data("Info".utf8)) != nil)
        #expect(data.count < 200_000)
    }

    @Test func movRewrapsToMP4() async throws {
        let input = try await writeVideo(named: "clip.mov")
        let output = directory.appending(path: "clip.mp4")
        try await MediaConverter().convert(input, to: output)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let size = try await tracks[0].load(.naturalSize)
        #expect(size == CGSize(width: 64, height: 48))
        let original = try await AVURLAsset(url: input).load(.duration).seconds
        let rewrapped = try await asset.load(.duration).seconds
        #expect(abs(rewrapped - original) < 0.05, "\(rewrapped)s from \(original)s")
    }

    @Test func videoBecomesALoopingGIF() async throws {
        let input = try await writeVideo(named: "clip.mov")
        let output = directory.appending(path: "clip.gif")
        try await MediaConverter().convert(input, to: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.compuserve.gif")
        // About a second at 10 frames a second, never made larger than the video.
        #expect((8...12).contains(CGImageSourceGetCount(source)), "\(CGImageSourceGetCount(source)) frames")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CGSize(width: image.width, height: image.height) == CGSize(width: 64, height: 48))
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 0)
    }

    @Test func soundlessVideoHasNoAudioToExtract() async throws {
        let input = try await writeVideo(named: "silent.mov")
        await #expect(throws: MediaConverter.ConversionError.noAudio) {
            try await MediaConverter().convert(input, to: directory.appending(path: "silent.m4a"))
        }
    }

    @Test func unreadableInputIsReported() async throws {
        let input = directory.appending(path: "broken.mov")
        try Data("not a movie".utf8).write(to: input)
        await #expect(throws: MediaConverter.ConversionError.unreadable) {
            try await MediaConverter().convert(input, to: directory.appending(path: "broken.mp4"))
        }
    }

    // MARK: Fixtures

    /// A 440 Hz sine wave as 16-bit WAV.
    func writeTone(seconds: Double, channels: AVAudioChannelCount, named name: String) throws -> URL {
        let url = directory.appending(path: name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * 440 * Double(frame) / 44_100) * 0.5)
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// One second of 64×48 H.264 at 10 frames a second, without sound.
    func writeVideo(named name: String) async throws -> URL {
        let url = directory.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0...10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixels: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixels)
            let buffer = try #require(pixels)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }
}
