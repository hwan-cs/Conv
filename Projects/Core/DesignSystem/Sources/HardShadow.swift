import SwiftUI

extension View {
    /// The blur-free ink shadow that makes stickers and keycaps look stuck on paper.
    func hardShadow(cornerRadius: CGFloat, offset: CGFloat, color: Color = ConvColor.ink) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(color)
                .offset(y: offset)
        )
    }

    /// Ink outline drawn inside the shape's bounds.
    func inkBorder(cornerRadius: CGFloat, lineWidth: CGFloat = 1.5, color: Color = ConvColor.ink) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(color, lineWidth: lineWidth)
        )
    }
}
