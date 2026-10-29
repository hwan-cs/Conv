import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which formats a file can become, by extension. Grows as engines land.
public enum Formats {
    public struct Output: Sendable, Equatable, Identifiable {
        public let ext: String
        /// One line under the format on its key, e.g. "인쇄·공유용".
        public let caption: String
        /// Shown as a key on the pick screen; the rest wait behind "더 보기".
        public let isPrimary: Bool
        public var id: String { ext }

        public init(ext: String, caption: String, isPrimary: Bool = true) {
            self.ext = ext
            self.caption = caption
            self.isPrimary = isPrimary
        }
    }

    public static let documentInputs: Set<String> = ["docx", "hwp", "hwpx"]
    public static let imageInputs: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "webp", "tiff", "tif", "gif", "bmp", "avif"]

    /// The best choice first: it is the recommended key.
    public static func outputs(for input: URL) -> [Output] {
        let ext = normalized(input.pathExtension)
        if documentInputs.contains(ext) {
            return [Output(ext: "pdf", caption: "인쇄·공유용, 그대로 보여요")]
        }
        guard imageInputs.contains(ext) else { return [] }
        let order: [String] = switch ext {
        case "jpg": ["png", "pdf", "heic", "tiff", "gif", "bmp", "avif"]
        case "png": ["jpg", "pdf", "heic", "tiff", "gif", "bmp", "avif"]
        case "gif": ["png", "jpg", "pdf", "heic", "tiff", "bmp", "avif"]
        default: ["jpg", "png", "pdf", "heic", "tiff", "gif", "bmp", "avif"]
        }
        let available = order.filter { $0 != ext && canWrite($0) }
        return available.enumerated().map { index, output in
            Output(ext: output, caption: caption(output, recommended: index == 0), isPrimary: index < 4)
        }
    }

    private static func caption(_ ext: String, recommended: Bool) -> String {
        let base = switch ext {
        case "jpg": "어디서나 열려요"
        case "png": "화질 그대로, 투명도 유지"
        case "pdf": "한 장씩 문서로"
        case "heic": "화질은 그대로, 용량은 절반"
        case "tiff": "인쇄·편집용"
        case "gif": "움직이는 이미지 유지"
        case "bmp": "오래된 프로그램용"
        case "avif": "가장 작은 용량"
        default: ""
        }
        return recommended ? "추천 · \(base)" : base
    }

    private static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": "jpg"
        case "tif": "tiff"
        case "heif": "heic"
        case let other: other
        }
    }

    /// Writable on this Mac: AVIF needs a newer system than the app's minimum.
    private static func canWrite(_ ext: String) -> Bool {
        guard ext != "pdf" else { return true }
        let type: UTType? = switch ext {
        case "jpg": .jpeg
        case "avif": UTType("public.avif")
        default: UTType(filenameExtension: ext)
        }
        guard let type else { return false }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(type.identifier)
    }
}
