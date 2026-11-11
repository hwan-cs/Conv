import SwiftUI

/// Motion rules from the design's "MOTION" board.
public enum ConvMotion {
    public static let dragEnter = Animation.easeOut(duration: 0.12)
    public static let drop = Animation.spring(response: 0.35, dampingFraction: 0.7)
    public static let keyPress = Animation.spring(response: 0.15, dampingFraction: 0.8)
    public static let stamp = Animation.easeOut(duration: 0.18)
}
