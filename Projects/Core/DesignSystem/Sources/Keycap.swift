import SwiftUI

/// An output format choice drawn as a keyboard key. 
public struct Keycap: View {
    let ext: String
    let caption: String
    let key: Character
    let isSelected: Bool
    let action: () -> Void

    public init(
        ext: String,
        caption: String,
        key: Character,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.ext = ext
        self.caption = caption
        self.key = key
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(StickerStyle.label(for: ext))
                        .font(ConvFont.mono(26, .heavy))
                        .tracking(-1)
                    Spacer()
                    KeyHint(String(key), emphasized: true)
                }
                Text(caption)
                    .font(ConvFont.sans(12, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color(hex: 0x5A4300) : ConvColor.muted)
            }
            .foregroundStyle(ConvColor.ink)
        }
        .buttonStyle(KeycapButtonStyle(isSelected: isSelected))
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
    }
}

public struct KeycapButtonStyle: ButtonStyle {
    let isSelected: Bool

    public init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        let depth: CGFloat = isSelected ? 6 : 4
        let shape = RoundedRectangle(cornerRadius: 12)
        configuration.label
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(isSelected ? StickerStyle.forExtension("jpg").fill : ConvColor.white))
            .inkBorder(cornerRadius: 12)
            .contentShape(shape)
            .offset(y: configuration.isPressed ? depth : 0)
            .background(shape.fill(ConvColor.ink).offset(y: depth))
            .animation(ConvMotion.keyPress, value: configuration.isPressed)
    }
}
