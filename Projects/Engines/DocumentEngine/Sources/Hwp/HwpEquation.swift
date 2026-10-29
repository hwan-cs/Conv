import Foundation

/// Hangul's equation script (수식 편집기, an EQN descendant) as MathML, which WebKit lays out itself.
///
/// `{ }` group; `^` and `_` attach scripts; `~` and `` ` `` are a space and a quarter space. Other
/// whitespace draws nothing but delimits: `x+y over x-y` divides the whole chunks on either side,
/// and `sqrt x+y` takes the chunk after it.
enum HwpEquation {
    static func mathML(_ script: String) -> String {
        var parser = Parser(tokens: tokenize(script))
        let rows = parser.rows()
        let body: String
        if rows.count > 1 {
            body = "<mtable columnalign=\"left\">" + rows.map { "<mtr><mtd>\(mrow($0))</mtd></mtr>" }.joined() + "</mtable>"
        } else {
            body = mrow(rows.first ?? [])
        }
        return "<math>\(body)</math>"
    }

    // MARK: Tokens

    enum Token: Equatable {
        case open, close, raise, lower, column, row, space, thinSpace
        /// Whitespace: it only separates words, except that it ends an unbraced limit (`lim_h->0 f`).
        case gap
        case word(String)
        case number(String)
        case symbol(String)
        case text(String)
    }

    static func tokenize(_ script: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(script)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "{": tokens.append(.open)
            case "}": tokens.append(.close)
            case "^": tokens.append(.raise)
            case "_": tokens.append(.lower)
            case "&": tokens.append(.column)
            case "#": tokens.append(.row)
            case "~": tokens.append(.space)
            case "`": tokens.append(.thinSpace)
            case "\"":
                var end = index + 1
                while end < characters.count, characters[end] != "\"" { end += 1 }
                tokens.append(.text(String(characters[(index + 1)..<min(end, characters.count)])))
                index = end
            case _ where character.isWhitespace:
                if tokens.last != .gap { tokens.append(.gap) }
            case _ where character.isASCII && character.isLetter:
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isLetter { end += 1 }
                tokens.append(.word(String(characters[index..<end])))
                index = end - 1
            case _ where character.isNumber && character.isASCII:
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isNumber || characters[end] == "." { end += 1 }
                tokens.append(.number(String(characters[index..<end])))
                index = end - 1
            case "-" where index + 1 < characters.count && characters[index + 1] == ">":
                tokens.append(.symbol("→"))
                index += 1
            case "<" where index + 1 < characters.count && characters[index + 1] == "=":
                tokens.append(.symbol("≤"))
                index += 1
            case ">" where index + 1 < characters.count && characters[index + 1] == "=":
                tokens.append(.symbol("≥"))
                index += 1
            case "!" where index + 1 < characters.count && characters[index + 1] == "=":
                tokens.append(.symbol("≠"))
                index += 1
            case _ where character.isLetter:
                tokens.append(.text(String(character)))
            default:
                tokens.append(.symbol(String(character)))
            }
            index += 1
        }
        return tokens
    }

    // MARK: Tree

    indirect enum Node {
        case identifier(String, upright: Bool)
        case number(String)
        case operation(String)
        case text(String)
        case space(Double)
        case row([Node])
        case fraction(Node, Node, line: Bool)
        case root(Node, index: Node?)
        case scripts(Node, sub: Node?, sup: Node?, limits: Bool)
        case accent(Node, String, over: Bool)
        case fenced(String, [Node], String)
        case matrix([[Node]], open: String, close: String)
        case boxed(Node)
        case styled(Node, upright: Bool, bold: Bool)
    }

    struct Parser {
        var tokens: [Token]
        var index = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func next() -> Token? {
            defer { index += 1 }
            return peek
        }

        mutating func skipGaps() {
            while peek == .gap { index += 1 }
        }

        /// Top-level lines, split at `#`.
        mutating func rows() -> [[Node]] {
            var rows: [[Node]] = []
            while index < tokens.count {
                rows.append(sequence(until: [.row]))
                if peek == .row { index += 1 }
                if peek == .close { index += 1 }
            }
            return rows.filter { !$0.isEmpty }
        }

        /// Items up to a closing brace or one of `stops`, with `over` and `atop` binding their neighbours.
        mutating func sequence(until stops: Set<StopToken> = [], words: Set<String> = []) -> [Node] {
            var nodes: [Node] = []
            // Where the chunk since the last whitespace starts.
            var chunkStart = 0
            var afterGap = false
            while true {
                if peek == .gap { afterGap = true }
                skipGaps()
                guard let token = peek else { break }
                if token == .close { break }
                if let stop = StopToken(token), stops.contains(stop) { break }
                if case .word(let word) = token, words.contains(word.lowercased()) { break }
                if case .word(let word) = token, ["over", "atop"].contains(word.lowercased()) {
                    index += 1
                    let start = min(chunkStart, nodes.count)
                    let taken = Array(nodes[start...])
                    nodes.removeSubrange(start...)
                    let numerator: Node = taken.count == 1 ? taken[0] : .row(taken)
                    nodes.append(.fraction(numerator, chunk(), line: word.lowercased() == "over"))
                    chunkStart = nodes.count - 1
                    afterGap = false
                    continue
                }
                if afterGap { chunkStart = nodes.count }
                afterGap = false
                // A token that is no item (a stray `#` or `^`) is dropped.
                guard let node = atom() else { continue }
                nodes.append(scripts(on: node))
            }
            return nodes
        }

        /// A braced group, or the items up to the next whitespace.
        mutating func chunk() -> Node {
            skipGaps()
            if peek == .open, let group = atom() { return scripts(on: group) }
            var nodes: [Node] = []
            while let token = peek, ![.gap, .close, .column, .row].contains(token) {
                if case .word(let word) = token, ["over", "atop", "of", "right"].contains(word.lowercased()) { break }
                guard let node = atom() else { break }
                nodes.append(scripts(on: node))
            }
            return nodes.count == 1 ? nodes[0] : .row(nodes)
        }

        /// `^` and `_` after an item; `from`/`to` set limits under and over operators.
        mutating func scripts(on base: Node) -> Node {
            var sub: Node?
            var sup: Node?
            var limits = false
            if case .operation(let op) = base, ["∑", "∏", "∐", "⋂", "⋃"].contains(op) { limits = true }
            if case .identifier(let name, true) = base, ["lim", "max", "min", "sup", "inf"].contains(name) { limits = true }
            loop: while true {
                let mark = index
                skipGaps()
                guard let token = peek else { index = mark; break }
                switch token {
                case .lower:
                    index += 1
                    sub = scriptArgument()
                case .raise:
                    index += 1
                    sup = scriptArgument()
                case .word(let word) where word.lowercased() == "from":
                    index += 1
                    sub = atom()
                    limits = true
                case .word(let word) where word.lowercased() == "to":
                    index += 1
                    sup = atom()
                    limits = true
                case .word(let word) where word == "SUB" || word == "sub":
                    index += 1
                    sub = scriptArgument()
                case .word(let word) where word == "SUP" || word == "sup":
                    index += 1
                    sup = scriptArgument()
                default:
                    index = mark
                    break loop
                }
            }
            guard sub != nil || sup != nil else { return base }
            return .scripts(base, sub: sub, sup: sup, limits: limits)
        }

        /// A braced group, or like `over`'s operands everything up to the next space: `f_n+1`, `lim_h->0`.
        mutating func scriptArgument() -> Node? {
            skipGaps()
            if peek == .open { return atom() }
            var nodes: [Node] = []
            while let token = peek, ![.open, .close, .raise, .lower, .gap].contains(token) {
                guard let node = atom() else { break }
                nodes.append(node)
            }
            return .row(nodes)
        }

        mutating func atom() -> Node? {
            skipGaps()
            guard let token = next() else { return nil }
            switch token {
            case .open:
                let inner = sequence()
                if peek == .close { index += 1 }
                return .row(inner)
            case .close, .row, .column, .raise, .lower, .gap:
                return nil
            case .space: return .space(0.3)
            case .thinSpace: return .space(0.1)
            case .number(let value): return .number(value)
            case .text(let value): return .text(value)
            case .symbol(let value): return Self.operators.contains(value) ? .operation(value) : .identifier(value, upright: true)
            case .word(let word): return keyword(word)
            }
        }

        mutating func keyword(_ word: String) -> Node? {
            let lower = word.lowercased()
            switch lower {
            case "sqrt":
                return .root(chunk(), index: nil)
            case "root":
                // `root 3 of x` has a degree; a plain `root x` is a square root.
                let first = chunk()
                let mark = index
                skipGaps()
                if case .word(let of) = peek, of.lowercased() == "of" {
                    index += 1
                    return .root(chunk(), index: first)
                }
                index = mark
                return .root(first, index: nil)
            case "left":
                let open = delimiter()
                let inner = sequence(words: ["right"])
                var close = ""
                skipGaps()
                if case .word(let right) = peek, right.lowercased() == "right" {
                    index += 1
                    close = delimiter()
                }
                return .fenced(open, inner, close)
            case "right":
                _ = delimiter()
                return nil
            case "matrix", "pmatrix", "bmatrix", "dmatrix", "cases", "eqalign":
                let (open, close) = switch lower {
                case "pmatrix": ("(", ")")
                case "bmatrix": ("[", "]")
                case "dmatrix": ("|", "|")
                case "cases": ("{", "")
                default: ("", "")
                }
                skipGaps()
                guard peek == .open else { return nil }
                index += 1
                var rows: [[Node]] = [[]]
                var cell: [Node] = []
                while let token = peek, token != .close {
                    switch token {
                    case .gap:
                        index += 1
                    case .column:
                        index += 1
                        // `&&` is one column break.
                        if peek == .column { index += 1 }
                        rows[rows.count - 1].append(.row(cell))
                        cell = []
                    case .row:
                        index += 1
                        rows[rows.count - 1].append(.row(cell))
                        cell = []
                        rows.append([])
                    default:
                        cell += sequence(until: [.column, .row])
                    }
                }
                if peek == .close { index += 1 }
                rows[rows.count - 1].append(.row(cell))
                return .matrix(rows, open: open, close: close)
            case "rm", "it", "bold":
                // A font change lasts to the end of its group.
                let rest = sequence(until: [.column, .row])
                return .styled(.row(rest), upright: lower != "it", bold: lower == "bold")
            case "box":
                // BOX{…} frames its argument; BOX alone is the □ symbol.
                skipGaps()
                if peek == .open { return .boxed(atom() ?? .row([])) }
                return .operation("□")
            default:
                break
            }
            if let accent = Self.accents[lower] {
                return .accent(atom() ?? .row([]), accent.0, over: accent.1)
            }
            if let symbol = Self.symbols[word] ?? Self.symbols[lower] {
                return Self.operators.contains(symbol) || symbol.count == 1 && !symbol.first!.isLetter
                    ? .operation(symbol)
                    : .identifier(symbol, upright: false)
            }
            if Self.functions.contains(lower) { return .identifier(lower, upright: true) }
            // Words run together: "rmP", "cosA", "barPH". Split off the longest known word in front.
            if let prefix = Self.prefixes.first(where: { word.hasPrefix($0) && word.count > $0.count }) {
                tokens.insert(.word(String(word.dropFirst(prefix.count))), at: index)
                return keyword(prefix)
            }
            // Hangul also finds capitalized keywords and `circ` inside words: "ACUPB" is A ∪ B.
            let characters = Array(word)
            for start in 1..<max(characters.count, 1) {
                let rest = String(characters[start...])
                if let embedded = Self.embedded.first(where: { rest.hasPrefix($0) }) {
                    let after = String(characters[(start + embedded.count)...])
                    if !after.isEmpty { tokens.insert(.word(after), at: index) }
                    tokens.insert(.word(embedded), at: index)
                    return keyword(String(characters[..<start]))
                }
            }
            // Plain letters are separate variables.
            if word.count == 1 { return .identifier(word, upright: false) }
            return .row(word.map { .identifier(String($0), upright: false) })
        }

        mutating func delimiter() -> String {
            skipGaps()
            guard let token = next() else { return "" }
            switch token {
            case .symbol(let value): return value == "." ? "" : value
            case .open: return "{"
            case .close: return "}"
            case .word(let word):
                let named = ["lbrace": "{", "rbrace": "}", "langle": "⟨", "rangle": "⟩",
                             "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋"]
                if let delimiter = named[word.lowercased()] { return delimiter }
                index -= 1
                return ""
            default:
                index -= 1
                return ""
            }
        }

        static let functions: Set<String> = [
            "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
            "log", "ln", "lg", "exp", "lim", "max", "min", "det", "gcd", "mod", "deg", "dim", "arg", "ker", "hom",
        ]

        static let accents: [String: (String, Bool)] = [
            "bar": ("‾", true), "overline": ("‾", true), "vec": ("→", true), "dyad": ("↔", true),
            "hat": ("^", true), "tilde": ("~", true), "dot": ("˙", true), "ddot": ("¨", true),
            "acute": ("´", true), "grave": ("`", true), "check": ("ˇ", true), "arch": ("⏜", true),
            "under": ("_", false), "underline": ("_", false),
        ]

        static let symbols: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η",
            "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
            "omicron": "ο", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
            "chi": "χ", "psi": "ψ", "omega": "ω",
            "ALPHA": "Α", "BETA": "Β", "GAMMA": "Γ", "DELTA": "Δ", "THETA": "Θ", "LAMBDA": "Λ", "XI": "Ξ",
            "PI": "Π", "SIGMA": "Σ", "PHI": "Φ", "PSI": "Ψ", "OMEGA": "Ω",
            "CDOTS": "⋯", "LDOTS": "…", "VDOTS": "⋮", "DDOTS": "⋱", "CDOT": "·",
            "THEREFORE": "∴", "BECAUSE": "∵",
            "RARROW": "→", "LARROW": "←", "LRARROW": "↔", "UPARROW": "↑", "DOWNARROW": "↓",
            "Rarrow": "⇒", "Larrow": "⇐", "LRarrow": "⇔", "rarrow": "→", "larrow": "←",
            "TIMES": "×", "DIV": "÷", "PM": "±", "MP": "∓", "CIRC": "∘", "BULLET": "•", "STAR": "⋆",
            "LEQ": "≤", "GEQ": "≥", "NEQ": "≠", "APPROX": "≈", "SIM": "∼", "SIMEQ": "≃",
            "EQUIV": "≡", "CONG": "≅", "PROPTO": "∝",
            "INF": "∞", "inf": "∞", "in": "∈", "INFINITY": "∞", "IN": "∈", "NOTIN": "∉", "OWNS": "∋", "SUBSET": "⊂", "SUPSET": "⊃",
            "SUBSETEQ": "⊆", "SUPSETEQ": "⊇", "SMALLINTER": "∩", "SMALLUNION": "∪", "INTER": "⋂", "UNION": "⋃",
            "CUP": "∪", "CAP": "∩", "SUPERSET": "⊃", "circ": "∘", "cdot": "·", "times": "×",
            "EMPTYSET": "∅", "FORALL": "∀", "EXIST": "∃", "PARTIAL": "∂", "NABLA": "∇", "PRIME": "′",
            "TRIANGLE": "△", "ANGLE": "∠", "BOX": "□", "DIAMOND": "◇", "PERP": "⊥", "PARALLEL": "∥",
            "DEG": "°", "OPLUS": "⊕", "OTIMES": "⊗",
            "int": "∫", "dint": "∬", "tint": "∭", "oint": "∮", "sum": "∑", "prod": "∏", "coprod": "∐",
            "INT": "∫", "SUM": "∑", "PROD": "∏",
            "hbar": "ℏ", "aleph": "ℵ",
        ]

        /// Shown as operators, spaced by MathML's operator dictionary.
        static let operators: Set<String> = [
            "+", "-", "−", "=", "<", ">", "≤", "≥", "≠", "×", "÷", "±", "∓", "·", "∘", "→", "←", "↔", "⇒", "⇐", "⇔",
            "∈", "∉", "⊂", "⊃", "⊆", "⊇", "∩", "∪", "⋂", "⋃", "∫", "∬", "∭", "∮", "∑", "∏", "∐", "≈", "≡", "∼",
            "(", ")", "[", "]", "|", ",", ";", ":", "!", "∴", "∵", "⋯", "…", "/", "∧", "∨",
        ]

        /// Keywords found inside longer words, longest first.
        static let embedded: [String] = (symbols.keys.filter { $0.count > 2 && $0 == $0.uppercased() } + ["circ"])
            .sorted { $0.count > $1.count }

        /// Words that may run straight into the next, longest first.
        static let prefixes: [String] = (["rm", "it", "bold", "bar", "vec", "hat", "dot", "overline", "under", "sqrt", "root", "left", "right", "box"]
            + Array(functions) + Array(symbols.keys).filter { $0.count > 1 })
            .sorted { $0.count > $1.count }
    }

    enum StopToken: Hashable {
        case column, row

        init?(_ token: Token) {
            switch token {
            case .column: self = .column
            case .row: self = .row
            default: return nil
            }
        }
    }

    // MARK: MathML

    static func mrow(_ nodes: [Node]) -> String {
        nodes.count == 1 ? render(nodes[0]) : "<mrow>" + nodes.map(render).joined() + "</mrow>"
    }

    static func render(_ node: Node) -> String {
        switch node {
        case .identifier(let name, let upright):
            let variant = upright || name.count > 1 || !(name.first?.isLetter ?? false) ? " mathvariant=\"normal\"" : ""
            return "<mi\(variant)>\(escape(name))</mi>"
        case .number(let value):
            return "<mn>\(escape(value))</mn>"
        case .operation(let value):
            let large = ["∫", "∬", "∭", "∮", "∑", "∏", "∐", "⋂", "⋃"].contains(value) ? " largeop=\"true\"" : ""
            // Brackets typed as plain characters keep their size; only left/right fences stretch.
            let fixed = ["(", ")", "[", "]", "|"].contains(value) ? " stretchy=\"false\"" : ""
            return "<mo\(large)\(fixed)>\(escape(value == "-" ? "−" : value))</mo>"
        case .text(let value):
            return "<mtext>\(escape(value))</mtext>"
        case .space(let width):
            return "<mspace width=\"\(width)em\"/>"
        case .row(let nodes):
            return "<mrow>" + nodes.map(render).joined() + "</mrow>"
        case .fraction(let numerator, let denominator, let line):
            return "<mfrac\(line ? "" : " linethickness=\"0\"")>\(render(numerator))\(render(denominator))</mfrac>"
        case .root(let radicand, let index):
            if let index { return "<mroot>\(render(radicand))\(render(index))</mroot>" }
            return "<msqrt>\(render(radicand))</msqrt>"
        case .scripts(let base, let sub, let sup, let limits):
            let (both, under, over) = limits ? ("munderover", "munder", "mover") : ("msubsup", "msub", "msup")
            switch (sub, sup) {
            case let (sub?, sup?): return "<\(both)>\(render(base))\(render(sub))\(render(sup))</\(both)>"
            case let (sub?, nil): return "<\(under)>\(render(base))\(render(sub))</\(under)>"
            case let (nil, sup?): return "<\(over)>\(render(base))\(render(sup))</\(over)>"
            default: return render(base)
            }
        case .accent(let base, let mark, let over):
            let tag = over ? "mover" : "munder"
            return "<\(tag) accent\(over ? "" : "under")=\"true\">\(render(base))<mo stretchy=\"true\">\(escape(mark))</mo></\(tag)>"
        case .fenced(let open, let nodes, let close):
            let left = open.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(escape(open))</mo>"
            let right = close.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(escape(close))</mo>"
            return "<mrow>\(left)\(nodes.map(render).joined())\(right)</mrow>"
        case .matrix(let rows, let open, let close):
            let table = "<mtable>" + rows.map { "<mtr>" + $0.map { "<mtd>\(render($0))</mtd>" }.joined() + "</mtr>" }.joined() + "</mtable>"
            let left = open.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(escape(open))</mo>"
            let right = close.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(escape(close))</mo>"
            return "<mrow>\(left)\(table)\(right)</mrow>"
        case .boxed(let inner):
            return "<menclose notation=\"box\">\(render(inner))</menclose>"
        case .styled(let inner, let upright, let bold):
            // MathML Core only honours mathvariant="normal" on <mi>, so the style goes to the letters.
            let html = render(restyled(inner, upright: upright))
            return bold ? "<mrow style=\"font-weight:bold\">\(html)</mrow>" : html
        }
    }

    private static func restyled(_ node: Node, upright: Bool) -> Node {
        switch node {
        case .identifier(let name, _): .identifier(name, upright: upright)
        case .row(let nodes): .row(nodes.map { restyled($0, upright: upright) })
        case .accent(let base, let mark, let over): .accent(restyled(base, upright: upright), mark, over: over)
        case .fraction(let top, let bottom, let line): .fraction(restyled(top, upright: upright), restyled(bottom, upright: upright), line: line)
        case .scripts(let base, let sub, let sup, let limits): .scripts(restyled(base, upright: upright), sub: sub, sup: sup, limits: limits)
        default: node
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
