import SwiftUI

/// Motion rules from the design's "MOTION" board.
public enum ConvMotion {
    /// The drop zone turning signal orange and the slot opening on drag enter.
    public static let dragEnter = Animation.easeOut(duration: 0.12)
    /// A sticker being sucked into the slot.
    public static let drop = Animation.spring(response: 0.35, dampingFraction: 0.7)
    /// A keycap sinking under a press.
    public static let keyPress = Animation.spring(response: 0.15, dampingFraction: 0.8)
    /// The CONV'D stamp landing.
    public static let stamp = Animation.easeOut(duration: 0.18)
}
