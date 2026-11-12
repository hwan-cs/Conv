import SwiftUI

/// The fixed sticker color for a file format.
public struct StickerStyle: Sendable, Equatable {
    public let fill: Color
    public let text: Color

    public init(fill: Color, text: Color) {
        self.fill = fill
        self.text = text
    }

    /// Style for a file extension such as "jpeg", ".PDF" or "hwpx".
    public static func forExtension(_ ext: String) -> StickerStyle {
        switch normalized(ext) {
        case "pdf": StickerStyle(fill: Color(hex: 0xF2542D), text: ConvColor.white)
        case "jpg", "jpeg": StickerStyle(fill: Color(hex: 0xFFC93C), text: ConvColor.ink)
        case "png": StickerStyle(fill: Color(hex: 0x4F7CFF), text: ConvColor.white)
        case "heic", "heif": StickerStyle(fill: Color(hex: 0x2BB673), text: ConvColor.white)
        case "webp", "avif": StickerStyle(fill: Color(hex: 0xC9B6FF), text: ConvColor.ink)
        case "hwp", "hwpx": StickerStyle(fill: Color(hex: 0x13A8B8), text: ConvColor.white)
        case "docx", "doc", "rtf": StickerStyle(fill: Color(hex: 0x1F3A93), text: ConvColor.white)
        case "xlsx":
            StickerStyle(
                fill: Color(hex: 0x1D6F42),
                text: ConvColor.white
            )
        case "csv":
            StickerStyle(
                fill: Color(hex: 0xB8E2A6),
                text: ConvColor.ink
            )
        case "mp4": StickerStyle(fill: Color(hex: 0xFF8CC2), text: ConvColor.ink)
        case "mov": StickerStyle(fill: Color(hex: 0xFFB27A), text: ConvColor.ink)
        case "mp3", "m4a", "wav", "flac": StickerStyle(fill: Color(hex: 0xE9DFC9), text: ConvColor.ink)
        default: StickerStyle(fill: ConvColor.white, text: ConvColor.ink)
        }
    }

    /// The sticker label, e.g. "jpeg" → ".JPEG".
    public static func label(for ext: String) -> String {
        "." + normalized(ext).uppercased()
    }

    static func normalized(_ ext: String) -> String {
        var trimmed = ext.trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        return trimmed.lowercased()
    }
}
