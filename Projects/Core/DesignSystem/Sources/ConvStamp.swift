import SwiftUI

/// The rubber stamp that lands when a batch finishes.
public struct ConvStamp: View {
    let subtitle: String
    let animated: Bool
    @State private var landed = false

    public init(subtitle: String, animated: Bool = true) {
        self.subtitle = subtitle
        self.animated = animated
    }

    public var body: some View {
        VStack(spacing: 2) {
            Text("CONV'D")
                .font(ConvFont.mono(30, .heavy))
                .tracking(1)
            Text(subtitle)
                .font(ConvFont.mono(10, .bold))
                .tracking(1)
        }
        .foregroundStyle(ConvColor.signal)
        .padding(.vertical, 10)
        .padding(.horizontal, 22)
        .inkBorder(cornerRadius: 12, lineWidth: 3.5, color: ConvColor.signal)
        .rotationEffect(.degrees(-9))
        .scaleEffect(isLanded ? 1 : 1.3)
        .opacity(isLanded ? 1 : 0)
        .onAppear {
            guard animated else {
                return
            }
            withAnimation(ConvMotion.stamp) {
                landed = true
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isLanded: Bool { landed || !animated }
}
