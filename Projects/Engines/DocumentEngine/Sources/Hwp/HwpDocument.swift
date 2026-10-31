import Foundation

/// The document model shared by the .hwp (binary) and .hwpx (XML) readers.
///
/// Lengths are HWPUNIT, 1/7200 inch (1/100 pt), as both formats store them.
struct HwpDocument {
    /// Faces per script: 한글, 영어, 한자, 일어, 기타, 기호, 사용자.
    var fonts: [[Font]] = Array(repeating: [], count: 7)
    var charShapes: [CharShape] = []
    var paraShapes: [ParaShape] = []
    /// Referenced 1-based: `borderFills[id - 1]`.
    var borderFills: [BorderFill] = []
    var tabDefs: [TabDef] = []
    var numberings: [Numbering] = []
    var bullets: [Bullet] = []
    /// Embedded files by BinData id.
    var binData: [Int: BinItem] = [:]
    var sections: [Section] = []

    struct Font {
        var name: String
        /// The face Hangul names as its stand-in, e.g. "Malgun Gothic" for "맑은 고딕".
        var fallback: String?
    }

    struct CharShape {
        /// Index into `fonts[script]`, per script.
        var faces: [Int]
        /// 장평 (horizontal scale), percent per script.
        var ratios: [Int]
        /// 자간 (letter spacing), percent of the font size per script.
        var spacings: [Int]
        /// 상대 크기, percent per script.
        var relativeSizes: [Int]
        /// 글자 위치 (baseline shift), percent per script.
        var offsets: [Int]
        var height: Int
        var italic = false
        var bold = false
        var underline: Underline?
        var strikeout = false
        var isSuperscript = false
        var isSubscript = false
        var color: Color
        var shadeColor: Color?
        var borderFillID: Int?

        enum Underline { case below, above }
    }

    struct ParaShape {
        enum Alignment { case justify, left, right, center, distribute, divide }
        enum LineSpacing {
            case percent(Int)
            case fixed(Int)
            /// 여백만 지정: the gap between lines, added to the text height.
            case betweenLines(Int)
            case atLeast(Int)
        }

        var alignment: Alignment = .justify
        var left = 0
        var right = 0
        /// Positive indents the first line; negative is a hanging indent (내어쓰기).
        var indent = 0
        var spaceBefore = 0
        var spaceAfter = 0
        var lineSpacing: LineSpacing = .percent(160)
        var tabDefID = 0
        var heading: Heading?
        var borderFillID: Int?
        var borderOffsets: (left: Int, right: Int, top: Int, bottom: Int) = (0, 0, 0, 0)
        var pageBreakBefore = false

        struct Heading {
            enum Kind { case outline, numbering, bullet }
            var kind: Kind
            /// 1-based numbering or bullet id; 0 means the section's outline numbering.
            var id: Int
            var level: Int
        }
    }

    struct Border {
        /// Line style; nil when there is no line.
        var style: Style?
        /// Millimeters.
        var width: Double
        var color: Color

        enum Style { case solid, dash, dot, dashDot, dashDotDot, longDash, circle, double, thinThick, thickThin, triple, wave }

        static let none = Border(style: nil, width: 0, color: .black)
    }

    struct BorderFill {
        var left: Border = .none
        var right: Border = .none
        var top: Border = .none
        var bottom: Border = .none
        var fill: Color?
        var image: ImageFill?
    }

    /// A picture filling a box (채우기 › 그림).
    struct ImageFill {
        enum Mode { case tile, stretch, center }
        var binID: Int
        var mode: Mode
        var effect: Picture.Effect = .none

        /// HWP's 그림 채우기 유형: 0 바둑판식 전체 … 5 크기에 맞추어, 6 가운데 ….
        init(binID: Int, code: Int, effect: Picture.Effect = .none) {
            self.binID = binID
            self.effect = effect
            mode = switch code {
            case 0...4: .tile
            case 5: .stretch
            default: .center
            }
        }

        init(binID: Int, mode: Mode, effect: Picture.Effect = .none) {
            self.binID = binID
            self.mode = mode
            self.effect = effect
        }
    }

    struct TabDef {
        var stops: [TabStop] = []
        /// 내어쓰기용 자동 탭: a tab on a hanging paragraph's first line stops where the rest begin.
        var hangingStop = false
        /// 오른쪽 끝 자동 탭: a tab past the last stop right-aligns what follows at the margin.
        var rightEndStop = false
    }

    struct TabStop {
        enum Kind { case left, right, center, decimal }
        var position: Int
        var kind: Kind
        var leader: Bool
    }

    /// How a paragraph's number or bullet sits before its text (문단 머리 정보).
    struct HeadSpacing {
        /// Gap between the head and the text: a percent of the font size, or HWPUNIT.
        var distance = 50
        var distanceIsPercent = true
        /// 자동 내어쓰기: the paragraph's other lines start where the text after the head does.
        var autoIndent = false
        /// The head's own character shape, when it doesn't take the paragraph's.
        var charShapeID: Int?
    }

    struct Numbering {
        struct Level {
            /// Format with ^1..^7 placeholders, e.g. "^1." or "(^2)".
            var format: String
            /// 번호 모양: 0 1,2,3; 1 ①; 2 I; 3 i; 4 A; 5 a; 8 가; 10 ㄱ; 12 일; 13 一.
            var style: Int
            var start: Int
            var spacing = HeadSpacing()
        }
        var levels: [Level]
    }

    struct Bullet {
        var character: String
        var spacing = HeadSpacing()
    }

    struct BinItem {
        var `extension`: String
        var data: () throws -> Data?
    }

    struct Color: Equatable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8

        static let black = Color(red: 0, green: 0, blue: 0)

        /// COLORREF is 0x00BBGGRR; values with the top byte set mean "none".
        init?(colorRef: UInt32) {
            guard colorRef >> 24 == 0 else { return nil }
            self.init(red: UInt8(colorRef & 0xFF), green: UInt8(colorRef >> 8 & 0xFF), blue: UInt8(colorRef >> 16 & 0xFF))
        }

        init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var css: String { String(format: "#%02x%02x%02x", red, green, blue) }
    }

    struct PageDef {
        var width = 59528
        var height = 84188
        var left = 8504
        var right = 8504
        var top = 5668
        var bottom = 4252
        var header = 4252
        var footer = 4252
        var gutter = 0
        var landscape = false
    }

    struct Section {
        var page = PageDef()
        var pageNumberStart = 0
        /// 1-based numbering id of the section's 개요 번호 (outline numbering).
        var outlineNumberingID = 0
        var endnoteShape = NoteShape()
        var columns = 1
        var columnGap = 0
        /// Spacing of the stops after the defined ones.
        var defaultTab = 4000
        var paragraphs: [Paragraph] = []
    }

    /// 미주 모양: how endnotes are numbered and spaced.
    struct NoteShape {
        var prefix = ""
        var suffix = ")"
        var start = 1
        /// Above and below the separator line, and between notes.
        var spaceAbove = 850
        var spaceBelow = 567
        var spaceBetween = 0
    }

    struct Paragraph {
        var paraShapeID = 0
        var styleID = 0
        var pageBreak = false
        var columnBreak = false
        /// The shape at the paragraph's start, which sizes an empty paragraph.
        var charShapeID = 0
        var content: [Inline] = []
        /// Hangul's own layout when the writer saved it (desktop Hangul does; web and server exports don't).
        var lineSegments: [LineSegment] = []
    }

    struct LineSegment {
        var textStart: Int
        var verticalPosition: Int
        var lineHeight: Int
        var textHeight: Int
        var baseline: Int
        var spacing: Int
        var columnStart: Int
        var width: Int
        var flags: UInt32
    }

    enum Inline {
        case text(String, charShapeID: Int)
        case tab(charShapeID: Int)
        case lineBreak
        /// Where Hangul's saved layout starts a new line.
        case lineStart
        case control(Control)
    }

    enum Control {
        case table(Table)
        case picture(Picture)
        case shape(Shape)
        case equation(Equation)
        case header(HeaderFooter)
        case footer(HeaderFooter)
        case footnote([Paragraph])
        case endnote([Paragraph])
        case autoNumber(AutoNumber)
        case pageNumberPosition(PageNumberPosition)
        /// 감추기: hides these on the page holding the control.
        case pageHide(header: Bool, footer: Bool, pageNumber: Bool)
        case hyperlink(String)
        case fieldEnd
    }

    /// Placement shared by tables, pictures, shapes and equations (개체 공통 속성).
    struct ObjectLayout {
        enum Relative { case paper, page, column, paragraph }
        enum Wrap { case square, tight, through, topAndBottom, behindText, inFrontOfText }

        var inline = true
        var vertical: Relative = .paragraph
        var horizontal: Relative = .column
        /// 0 top/left, 1 center, 2 bottom/right, plus inside/outside variants.
        var verticalAlign = 0
        var horizontalAlign = 0
        var x = 0
        var y = 0
        var width = 0
        var height = 0
        var wrap: Wrap = .topAndBottom
        var zOrder = 0
        var margins: (left: Int, right: Int, top: Int, bottom: Int) = (0, 0, 0, 0)
    }

    struct Table {
        var layout = ObjectLayout()
        var rows = 0
        var columns = 0
        var cellSpacing = 0
        var padding: (left: Int, right: Int, top: Int, bottom: Int) = (0, 0, 0, 0)
        var borderFillID = 0
        var cells: [Cell] = []
        var repeatHeader = false

        struct Cell {
            var column = 0
            var row = 0
            var columnSpan = 1
            var rowSpan = 1
            var width = 0
            var height = 0
            var padding: (left: Int, right: Int, top: Int, bottom: Int) = (0, 0, 0, 0)
            var borderFillID = 0
            /// 0 top, 1 center, 2 bottom.
            var verticalAlign = 0
            var paragraphs: [Paragraph] = []
        }
    }

    struct Picture {
        var layout = ObjectLayout()
        var binID = 0
        /// The part of the image shown, in the image's own units: 75 per pixel (96 dpi in HWPUNIT).
        var crop: (left: Int, top: Int, right: Int, bottom: Int) = (0, 0, 0, 0)
        /// The image rectangle's far corner. In those same units when the picture was cropped in
        /// Hangul; otherwise the size it is drawn at.
        var extent: (width: Int, height: Int) = (0, 0)
        var effect: Effect = .none
        var border: Border = .none

        /// 그림 효과.
        enum Effect {
            case none, grayscale, blackAndWhite

            init(code: Int) {
                self = switch code {
                case 1: .grayscale
                case 2: .blackAndWhite
                default: .none
                }
            }

            init(hwpx: String?) {
                self = switch hwpx {
                case "GRAY_SCALE": .grayscale
                case "BLACK_WHITE": .blackAndWhite
                default: .none
                }
            }
        }
    }

    struct Shape {
        enum Kind { case line, rectangle, ellipse, other }
        var layout = ObjectLayout()
        var kind: Kind = .other
        var line: Border = .none
        var fill: Color?
        var image: ImageFill?
        /// Radius as a percent of the shorter side, for rounded rectangles.
        var cornerRatio = 0
        /// Line endpoints in the shape's own box, for `.line`.
        var start = (x: 0, y: 0)
        var end = (x: 0, y: 0)
        var text: [Paragraph] = []
        var textPadding: (left: Int, right: Int, top: Int, bottom: Int) = (0, 0, 0, 0)
        var textVerticalAlign = 0
        var children: [Control] = []
    }

    struct Equation {
        var layout = ObjectLayout()
        var script: String
        var fontSize: Int
        var color: Color
    }

    struct HeaderFooter {
        enum Pages { case both, even, odd }
        var pages: Pages
        var paragraphs: [Paragraph]
    }

    struct AutoNumber {
        enum Kind { case page, footnote, endnote, picture, table, equation, totalPages }
        var kind: Kind
        var style: Int
        var number: Int
        var charShapeID: Int
    }

    struct PageNumberPosition {
        /// 0 none, 1-3 top left/center/right, 4-6 bottom left/center/right,
        /// 7/8 outside top/bottom, 9/10 inside top/bottom.
        var position: Int
        var style: Int
        var prefix: String
        var suffix: String
        var dash: String
    }
}

extension HwpDocument.ParaShape.Alignment {
    init(code: Int) {
        self = switch code {
        case 1: .left
        case 2: .right
        case 3: .center
        case 4: .distribute
        case 5: .divide
        default: .justify
        }
    }
}

extension HwpDocument.Border.Style {
    /// HWP 5 line type codes (테두리선 종류); 0 is no line.
    init?(code: Int) {
        switch code {
        case 1: self = .solid
        case 2: self = .dash
        case 3: self = .dot
        case 4: self = .dashDot
        case 5: self = .dashDotDot
        case 6: self = .longDash
        case 7: self = .circle
        case 8: self = .double
        case 9: self = .thinThick
        case 10: self = .thickThin
        case 11: self = .triple
        case 12, 13: self = .wave
        case 14...17: self = .solid
        default: return nil
        }
    }

    var css: String {
        switch self {
        case .solid, .wave: "solid"
        case .dash, .longDash, .dashDot, .dashDotDot: "dashed"
        case .dot, .circle: "dotted"
        case .double, .thinThick, .thickThin, .triple: "double"
        }
    }
}

extension HwpDocument.Border {
    /// 테두리선 굵기 codes, in millimeters.
    static let widths: [Double] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]
}
