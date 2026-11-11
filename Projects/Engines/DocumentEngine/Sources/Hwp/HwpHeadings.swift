import Foundation

/// The numbers and bullets before paragraphs (문단 머리), counted as the document goes.
struct HwpHeadings {
    private let document: HwpDocument
    /// Counters by numbering id, one per level.
    private var counters: [Int: [Int]] = [:]
    /// The section's 개요 번호, which outline headings count with.
    var outlineNumberingID = 0

    init(document: HwpDocument) {
        self.document = document
    }

    /// The head's text and spacing, nil when the paragraph has none.
    /// - Parameter advance: Whether to count this paragraph; off for later pieces of a split one.
    mutating func head(_ heading: HwpDocument.ParaShape.Heading?, advance: Bool = true) -> (label: String, spacing: HwpDocument.HeadSpacing)? {
        guard let heading else {
            return nil
        }
        switch heading.kind {
        case .bullet:
            guard let bullet = document.bullets[safe: heading.id - 1] else {
                return nil
            }
            return (HwpHTMLWriter.bulletCharacter(bullet.character), bullet.spacing)
        case .numbering, .outline:
            let id = heading.kind == .outline ? outlineNumberingID : heading.id
            guard let numbering = document.numberings[safe: id - 1], numbering.levels.indices.contains(heading.level) else {
                return nil
            }
            var values = counters[id] ?? numbering.levels.map { $0.start - 1 }
            values[heading.level] += 1
            for deeper in values.indices where deeper > heading.level {
                values[deeper] = numbering.levels[deeper].start - 1
            }
            if advance {
                counters[id] = values
            } else {
                values = counters[id] ?? values
            }
            var text = numbering.levels[heading.level].format.replacingOccurrences(of: "^N", with: "^\(heading.level + 1).")
            for level in (0..<numbering.levels.count).reversed() {
                text = text.replacingOccurrences(of: "^\(level + 1)", with: HwpHTMLWriter.format(max(values[level], numbering.levels[level].start), style: numbering.levels[level].style))
            }
            return (text, numbering.levels[heading.level].spacing)
        }
    }
}
