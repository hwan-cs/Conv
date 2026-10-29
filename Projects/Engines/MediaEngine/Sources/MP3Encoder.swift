@preconcurrency import AVFoundation
import Foundation
import LAME

/// MP3 through LAME, which ships as a dynamic library (LGPL) since macOS has no MP3 encoder.
struct MP3Encoder {
    enum EncodingError: Error {
        case setupFailed
        case encodingFailed(Int32)
    }

    /// VBR quality 2 (0 best, 9 smallest): transparent for most music, about 190 kbps.
    var quality: Int32 = 2

    func encode(_ asset: AVAsset, to output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { throw EncodingError.setupFailed }
        defer { try? handle.close() }
        var lame: OpaquePointer?
        defer { if let lame { lame_close(lame) } }
        var buffer = [UInt8]()

        try await PCMReader.read(asset, progress: progress) { format in
            guard let encoder = lame_init() else { throw EncodingError.setupFailed }
            lame = encoder
            // MP3 carries one or two channels; more are folded into stereo.
            lame_set_in_samplerate(encoder, Int32(format.sampleRate))
            lame_set_num_channels(encoder, format.channelCount == 1 ? 1 : 2)
            lame_set_VBR(encoder, vbr_default)
            lame_set_VBR_quality(encoder, Float(quality))
            lame_set_write_id3tag_automatic(encoder, 0)
            guard lame_init_params(encoder) >= 0 else { throw EncodingError.setupFailed }
            return { pcm in
                let frames = Int32(pcm.frameLength)
                guard frames > 0, let channels = pcm.floatChannelData else { return }
                let left = channels[0]
                let right = pcm.format.channelCount > 1 ? channels[1] : channels[0]
                // LAME's documented worst case for one call.
                let capacity = Int(frames) * 5 / 4 + 7200
                if buffer.count < capacity { buffer = [UInt8](repeating: 0, count: capacity) }
                let written = buffer.withUnsafeMutableBufferPointer {
                    lame_encode_buffer_ieee_float(encoder, left, right, frames, $0.baseAddress, Int32(capacity))
                }
                guard written >= 0 else { throw EncodingError.encodingFailed(written) }
                try handle.write(contentsOf: buffer.prefix(Int(written)))
            }
        }

        guard let lame else { throw EncodingError.setupFailed }
        var tail = [UInt8](repeating: 0, count: 7200)
        let flushed = tail.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, 7200) }
        guard flushed >= 0 else { throw EncodingError.encodingFailed(flushed) }
        try handle.write(contentsOf: tail.prefix(Int(flushed)))

        // The VBR header at the start lets players show the right duration and seek.
        var tag = [UInt8](repeating: 0, count: 2880)
        let tagSize = tag.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, 2880) }
        if tagSize > 0, tagSize <= 2880 {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tag.prefix(tagSize))
        }
    }
}
