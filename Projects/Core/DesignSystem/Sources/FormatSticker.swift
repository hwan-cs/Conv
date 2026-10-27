import SwiftUI

/// A file format as a sticker: ".HEIC" on its fixed color, ink outline, hard shadow.
public struct FormatSticker: View {
    public enum Size: Sendable {
        /// List rows and menus.
        case mini
        /// Default.
        case regular
        /// Hero moments: drag over, done.
        case large

        var fontSize: CGFloat {
            switch self {
            case .mini: 11
            case .regular: 16
            case .large: 24
            }
        }

        var padding: EdgeInsets {
            switch self {
            case .mini: EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
            case .regular: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            case .large: EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            }
        }

        var cornerRadius: CGFloat { self == .mini ? 6 : 8 }

        var shadow: CGFloat {
            switch self {
            case .mini: 2
            case .regular: 3
            case .large: 5
            }
        }
    }

    let ext: String
    let size: Size

    public init(_ ext: String, size: Size = .regular) {
        self.ext = ext
        self.size = size
    }

    public var body: some View {
        let style = StickerStyle.forExtension(ext)
        Text(StickerStyle.label(for: ext))
            .font(ConvFont.mono(size.fontSize, .bold))
            .foregroundStyle(style.text)
            .padding(size.padding)
            .background(RoundedRectangle(cornerRadius: size.cornerRadius).fill(style.fill))
            .inkBorder(cornerRadius: size.cornerRadius)
            .hardShadow(cornerRadius: size.cornerRadius, offset: size.shadow)
            .accessibilityLabel(Text("\(StickerStyle.normalized(ext).uppercased()) 파일"))
    }
}
