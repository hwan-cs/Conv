import CommonCrypto
import Foundation

/// 배포용 문서 (distribution documents) keep each section AES-128-ECB encrypted behind a
/// DISTRIBUTE_DOC_DATA record whose 256 bytes are scrambled with MSVC's `rand()`.
enum HwpDistribution {
    static func decrypt(_ stream: Data) throws -> Data {
        guard let record = try? HwpRecord.parse(stream.prefix(260)).first,
              record.tag == HwpTag.distributeDocData, record.payload.count == 256
        else { throw HwpFile.HwpError.corrupt }

        var data = [UInt8](record.payload)
        var random = MSVCRandom(seed: record.payload.uint32(at: 0))
        var key: UInt8 = 0
        var remaining = 0
        for i in 0..<256 {
            if remaining == 0 {
                key = UInt8(random.next() & 0xFF)
                remaining = Int(random.next() & 0xF) + 1
            }
            if i >= 4 { data[i] ^= key }
            remaining -= 1
        }
        let offset = 4 + Int(data[0] & 0xF)
        let aesKey = Array(data[offset..<offset + 16])

        let body = [UInt8](stream.dropFirst(260))
        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            aesKey, kCCKeySizeAES128, nil,
            body, body.count - body.count % kCCBlockSizeAES128,
            &output, output.count, &written
        )
        guard status == kCCSuccess else { throw HwpFile.HwpError.corrupt }
        return Data(output.prefix(written))
    }
}

private struct MSVCRandom {
    var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func next() -> UInt32 {
        state = state &* 214_013 &+ 2_531_011
        return state >> 16 & 0x7FFF
    }
}
