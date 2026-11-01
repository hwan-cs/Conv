import Foundation

/// .hwp and .hwpx → .docx, to keep editing in Word: the document read as for PDF, written as
/// WordprocessingML by `HwpDocxWriter`. Throws `HwpPDFConverter.ConversionError` as that does.
public struct HwpDocxConverter {
    public init() {}

    public func convert(_ input: URL, to output: URL) throws {
        var writer = HwpDocxWriter(document: try HwpPDFConverter.document(at: input))
        try writer.write(to: output)
    }
}
