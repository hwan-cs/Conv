import Foundation

/// Which formats a file can become, by extension. Grows as engines land.
public enum Formats {
    public struct Output: Sendable, Equatable, Identifiable {
        public let ext: String
        /// One line under the format on its key, e.g. "인쇄·공유용".
        public let caption: String
        public var id: String { ext }

        public init(ext: String, caption: String) {
            self.ext = ext
            self.caption = caption
        }
    }

    public static func outputs(for input: URL) -> [Output] {
        switch input.pathExtension.lowercased() {
        case "docx", "hwp", "hwpx":
            [Output(ext: "pdf", caption: "인쇄·공유용, 그대로 보여요")]
        default:
            []
        }
    }
}
