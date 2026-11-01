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
        /// All the files become one: images and PDFs into a single PDF.
        public let combines: Bool
        public var id: String { combines ? "\(ext)+" : ext }

        public init(ext: String, caption: String, isPrimary: Bool = true, combines: Bool = false) {
            self.ext = ext
            self.caption = caption
            self.isPrimary = isPrimary
            self.combines = combines
        }
    }

    public static let documentInputs: Set<String> = ["docx", "hwp", "hwpx"]
    public static let markdownInputs: Set<String> = ["md", "markdown"]
    public static let imageInputs: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "webp", "tiff", "tif", "gif", "bmp", "avif"]
    public static let videoInputs: Set<String> = ["mov", "mp4", "m4v"]
    public static let audioInputs: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"]
    public static var mediaInputs: Set<String> { videoInputs.union(audioInputs) }
    public static let pdfInputs: Set<String> = ["pdf"]

    /// Formats every one of the files can become, best first. Several images or PDFs can also
    /// become one PDF together.
    public static func outputs(for files: [URL]) -> [Output] {
        guard let first = files.first else { return [] }
        // By format alone: PNG is recommended for a JPG but not for a HEIC, and both can become it.
        var common = outputs(for: first).filter { output in
            files.allSatisfy { outputs(for: $0).contains { $0.ext == output.ext } }
        }
        let combinable = files.allSatisfy { imageInputs.contains(normalized($0.pathExtension)) || pdfInputs.contains(normalized($0.pathExtension)) }
        guard files.count > 1, combinable else { return common }
        if let index = common.firstIndex(where: { $0.ext == "pdf" }) {
            // Photos each made into a PDF are rarely wanted; one PDF of them all is.
            common[index] = Output(ext: "pdf", caption: "여러 장을 PDF 하나로", isPrimary: common[index].isPrimary, combines: true)
        } else {
            common.insert(Output(ext: "pdf", caption: "추천 · PDF 하나로 합치기", combines: true), at: 0)
        }
        return common
    }

    /// A PDF's pages each become an image, so one file comes out as several.
    public static func splitsPages(_ input: URL) -> Bool {
        pdfInputs.contains(normalized(input.pathExtension))
    }

    /// The best choice first: it is the recommended key.
    public static func outputs(for input: URL) -> [Output] {
        let ext = normalized(input.pathExtension)
        if ext == "hwp" || ext == "hwpx" {
            return [
                Output(ext: "pdf", caption: "추천 · 인쇄·공유용, 그대로 보여요"),
                Output(ext: "docx", caption: "Word에서 고쳐 쓰기"),
            ]
        }
        if documentInputs.contains(ext) {
            return [Output(ext: "pdf", caption: "인쇄·공유용, 그대로 보여요")]
        }
        if pdfInputs.contains(ext) {
            return [
                Output(ext: "jpg", caption: "추천 · 쪽마다 한 장씩"),
                Output(ext: "png", caption: "쪽마다 한 장씩, 글자가 더 또렷하게"),
            ]
        }
        if markdownInputs.contains(ext) {
            return [
                Output(ext: "pdf", caption: "추천 · 인쇄·공유용, 쪽으로 나눠서"),
                Output(ext: "html", caption: "웹 브라우저로 바로 열기"),
            ]
        }
        if videoInputs.contains(ext) {
            let order = ext == "mp4" ? ["mov", "m4a", "mp3", "gif"] : ["mp4", "mov", "m4a", "mp3", "gif"]
            return outputs(order.filter { $0 != ext }).map { output in
                guard output.ext == "gif" else { return output }
                return Output(ext: "gif", caption: "움직이는 이미지로, 소리 없이", isPrimary: output.isPrimary)
            }
        }
        if audioInputs.contains(ext) {
            return outputs(["mp3", "m4a", "wav", "aiff"].filter { $0 != ext })
        }
        guard imageInputs.contains(ext) else { return [] }
        let order: [String] = switch ext {
        case "jpg": ["png", "pdf", "heic", "tiff", "gif", "bmp", "avif"]
        case "png": ["jpg", "pdf", "heic", "tiff", "gif", "bmp", "avif"]
        case "gif": ["png", "jpg", "pdf", "heic", "tiff", "bmp", "avif"]
        default: ["jpg", "png", "pdf", "heic", "tiff", "gif", "bmp", "avif"]
        }
        return outputs(order.filter { $0 != ext && canWrite($0) })
    }

    private static func outputs(_ order: [String]) -> [Output] {
        order.enumerated().map { index, output in
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
        case "mp4": "어디서나 재생돼요"
        case "mov": "Apple 기기·편집용"
        case "m4a": "소리만, 작은 용량 (AAC)"
        case "mp3": "소리만, 어디서나 재생돼요"
        case "wav": "무손실, 편집용"
        case "aiff": "무손실, Mac 편집용"
        default: ""
        }
        return recommended ? "추천 · \(base)" : base
    }

    private static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": "jpg"
        case "tif": "tiff"
        case "heif": "heic"
        case "aif": "aiff"
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
