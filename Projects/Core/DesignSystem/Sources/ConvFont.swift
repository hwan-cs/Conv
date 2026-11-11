import CoreText
import SwiftUI

/// Pretendard for UI text, JetBrains Mono for extensions, file names and shortcuts.
public enum ConvFont {
    public enum Weight: Sendable {
        case regular, semibold, bold, heavy
    }

    /// Registers the bundled fonts for this process.
    public static func register() {
        _ = registration
    }

    public static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        register()
        let name = switch weight {
        case .regular: "Pretendard-Regular"
        case .semibold: "Pretendard-SemiBold"
        case .bold: "Pretendard-Bold"
        case .heavy: "Pretendard-ExtraBold"
        }
        return .custom(name, size: size)
    }

    public static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        register()
        let name = switch weight {
        case .regular: "JetBrainsMono-Regular"
        case .semibold, .bold: "JetBrainsMono-Bold"
        case .heavy: "JetBrainsMono-ExtraBold"
        }
        return .custom(name, size: size)
    }

    private static let registration: Void = {
        let fontExtensions: Set<String> = ["otf", "ttf"]
        let urls = FileManager.default
            .enumerator(at: Bundle.module.bundleURL, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { fontExtensions.contains($0.pathExtension) } ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }()
}
