import DesignSystem
import SwiftUI

/// Main window: empty → drag over → pick format → converting → done.
public struct DropView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20)
                .fill(ConvColor.ink)
                .overlay {
                    VStack(spacing: 12) {
                        Text("여기로 던지세요")
                            .font(ConvFont.sans(34, .heavy))
                            .tracking(-1)
                            .foregroundStyle(ConvColor.white)
                        HStack(spacing: 6) {
                            KeyHint("⌘O", onInk: true)
                            Text("로 직접 고르기")
                                .font(ConvFont.sans(13))
                                .foregroundStyle(ConvColor.onInkMuted)
                        }
                    }
                }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 456)
        .background(ConvColor.paper)
    }
}
