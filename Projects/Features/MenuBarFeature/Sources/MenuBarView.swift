import DesignSystem
import SwiftUI

/// Popover shown from the menu bar icon.
public struct MenuBarView: View {
    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(ConvColor.ink)
            .frame(height: 120)
            .overlay {
                Text("여기로 던지기")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(ConvColor.white)
            }
            .padding(14)
            .frame(width: 320)
            .background(ConvColor.paper)
    }
}
