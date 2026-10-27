import SwiftUI

/// A small bordered key label such as "⌘O" or "1".
public struct KeyHint: View {
    let keys: String
    let emphasized: Bool
    let onInk: Bool

    public init(_ keys: String, emphasized: Bool = false, onInk: Bool = false) {
        self.keys = keys
        self.emphasized = emphasized
        self.onInk = onInk
    }

    public var body: some View {
        let color = onInk ? ConvColor.onInkMuted : (emphasized ? ConvColor.ink : ConvColor.muted)
        Text(keys)
            .font(ConvFont.mono(12, emphasized ? .bold : .regular))
            .foregroundStyle(color)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .inkBorder(
                cornerRadius: 5,
                lineWidth: 1,
                color: onInk ? Color(hex: 0x4A453A) : (emphasized ? ConvColor.ink : ConvColor.line)
            )
    }
}
