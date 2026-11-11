import SwiftUI

/// Color tokens from the pen.dev design (design/conv.pen, "07 Tokens").
public enum ConvColor {
    public static let ink = Color(hex: 0x17150F)
    public static let paper = Color(hex: 0xF4F1EA)
    public static let paper2 = Color(hex: 0xEAE5DA)
    public static let line = Color(hex: 0xD9D2C4)
    public static let muted = Color(hex: 0x8A8376)
    public static let signal = Color(hex: 0xFF5A1F)
    public static let white = Color(hex: 0xFFFDF8)

    public static let success = Color(hex: 0x2BB673)
    public static let errorFill = Color(hex: 0xFFEDE5)
    public static let errorText = Color(hex: 0xB23A10)

    public static let onInkMuted = Color(hex: 0xA39C8E)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
