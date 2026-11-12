import Foundation

/// RGB ↔ HSL, for the lighter and darker variants Office derives from a theme color.
enum ColorMath {
    static func hsl(_ rgb: Int) -> (hue: Double, saturation: Double, lightness: Double) {
        let red = Double(rgb >> 16 & 0xFF) / 255
        let green = Double(rgb >> 8 & 0xFF) / 255
        let blue = Double(rgb & 0xFF) / 255
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else {
            return (0, 0, lightness)
        }
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        switch high {
        case red:
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        case green:
            hue = (blue - red) / delta + 2
        default:
            hue = (red - green) / delta + 4
        }
        hue /= 6
        return (hue, saturation, lightness)
    }

    static func rgb(
        hue: Double,
        saturation: Double,
        lightness: Double
    ) -> Int {
        let lightness = min(max(lightness, 0), 1)
        let saturation = min(max(saturation, 0), 1)

        func channel(_ offset: Double) -> Int {
            guard saturation > 0 else {
                return Int((lightness * 255).rounded())
            }
            let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
            let p = 2 * lightness - q
            var t = hue + offset
            if t < 0 {
                t += 1
            }
            if t > 1 {
                t -= 1
            }
            let value: Double
            if t < 1 / 6 {
                value = p + (q - p) * 6 * t
            } else if t < 1 / 2 {
                value = q
            } else if t < 2 / 3 {
                value = p + (q - p) * (2 / 3 - t) * 6
            } else {
                value = p
            }
            return Int((value * 255).rounded())
        }

        return channel(1 / 3) << 16 | channel(0) << 8 | channel(-1 / 3)
    }

    /// How light a color looks, from 0 for black to 1 for white.
    static func luminance(_ rgb: Int) -> Double {
        let red = Double(rgb >> 16 & 0xFF)
        let green = Double(rgb >> 8 & 0xFF)
        let blue = Double(rgb & 0xFF)
        return (0.299 * red + 0.587 * green + 0.114 * blue) / 255
    }
}

/// DrawingML colors as CSS: `a:srgbClr`, `a:schemeClr`, `a:sysClr` or `a:prstClr`, with the
/// `lumMod`, `lumOff`, `tint`, `shade`, `satMod` and `alpha` changes charts and shapes put on them.
struct DrawingColors {
    struct Color: Equatable {
        var rgb: Int
        var alpha = 1.0

        var css: String {
            guard alpha < 1 else {
                return String(format: "#%06X", rgb)
            }
            return String(
                format: "rgba(%d,%d,%d,%.2f)",
                rgb >> 16 & 0xFF,
                rgb >> 8 & 0xFF,
                rgb & 0xFF,
                alpha
            )
        }
    }

    let theme: DocxTheme

    private static let presets = [
        "black": 0x000000,
        "white": 0xFFFFFF,
        "red": 0xFF0000,
        "green": 0x008000,
        "blue": 0x0000FF,
        "yellow": 0xFFFF00,
        "gray": 0x808080,
        "orange": 0xFFA500,
    ]

    /// The color held by `element`: a `solidFill`, a style reference, or any element with one
    /// color child. Nil for `noFill` or a placeholder color.
    func color(in element: XMLElement?) -> Color? {
        guard let element else {
            return nil
        }
        let names = ["srgbClr", "schemeClr", "sysClr", "prstClr", "scrgbClr", "hslClr"]
        guard let child = element.elements.first(where: { names.contains($0.localName ?? "") && $0.uri == OOXMLNamespace.a }) else {
            return nil
        }
        return color(child)
    }

    func css(in element: XMLElement?) -> String? {
        color(in: element)?.css
    }

    /// Office's default color for the series or slice at `index`: the six accents, then darker
    /// and lighter rounds of them.
    func accent(_ index: Int) -> Color {
        let name = "accent\(index % 6 + 1)"
        var color = Color(rgb: base(scheme: name) ?? 0x4472C4)
        let rounds: [(modulation: Double, offset: Double)] = [
            (1, 0),
            (0.6, 0),
            (0.8, 0.2),
            (0.8, 0),
            (0.6, 0.4),
            (0.5, 0),
        ]
        let round = rounds[(index / 6) % rounds.count]
        if round != (1, 0) {
            var hsl = ColorMath.hsl(color.rgb)
            hsl.lightness = hsl.lightness * round.modulation + round.offset
            color.rgb = ColorMath.rgb(
                hue: hsl.hue,
                saturation: hsl.saturation,
                lightness: hsl.lightness
            )
        }
        return color
    }

    private func color(_ element: XMLElement) -> Color? {
        var rgb: Int?
        switch element.localName {
        case "srgbClr":
            rgb = element.attributeValue("val").flatMap { Int($0, radix: 16) }
        case "schemeClr":
            rgb = element.attributeValue("val").flatMap(base(scheme:))
        case "sysClr":
            rgb = (element.attributeValue("lastClr") ?? (element.attributeValue("val") == "window" ? "FFFFFF" : "000000"))
                .flatMap { Int($0, radix: 16) }
        case "prstClr":
            rgb = element.attributeValue("val").flatMap { Self.presets[$0] }
        case "scrgbClr":
            func channel(_ name: String) -> Int {
                let value = element.attributeValue(name).flatMap(Double.init) ?? 0
                return Int((min(max(value / 100_000, 0), 1) * 255).rounded())
            }
            rgb = channel("r") << 16 | channel("g") << 8 | channel("b")
        default:
            rgb = nil
        }
        guard let rgb else {
            return nil
        }
        var color = Color(rgb: rgb)
        for change in element.elements {
            let value = (change.attributeValue("val").flatMap(Double.init) ?? 100_000) / 100_000
            switch change.localName {
            case "lumMod", "lumOff", "satMod":
                var hsl = ColorMath.hsl(color.rgb)
                switch change.localName {
                case "lumMod":
                    hsl.lightness *= value
                case "lumOff":
                    hsl.lightness += value
                default:
                    hsl.saturation *= value
                }
                color.rgb = ColorMath.rgb(
                    hue: hsl.hue,
                    saturation: hsl.saturation,
                    lightness: hsl.lightness
                )
            case "tint":
                color.rgb = Self.mapChannels(color.rgb) { 255 - (255 - $0) * value }
            case "shade":
                color.rgb = Self.mapChannels(color.rgb) { $0 * value }
            case "alpha":
                color.alpha = value
            default:
                break
            }
        }
        return color
    }

    private func base(scheme name: String) -> Int? {
        let aliases = [
            "tx1": "dk1",
            "bg1": "lt1",
            "tx2": "dk2",
            "bg2": "lt2",
        ]
        let resolved = aliases[name] ?? name
        let hex = theme.color(resolved).map { String($0.dropFirst()) } ?? SpreadsheetColors.officeTheme[resolved]
        return hex.flatMap { Int($0, radix: 16) }
    }

    private static func mapChannels(_ rgb: Int, _ transform: (Double) -> Double) -> Int {
        let channels = [rgb >> 16 & 0xFF, rgb >> 8 & 0xFF, rgb & 0xFF].map { channel in
            Int(min(max(transform(Double(channel)), 0), 255).rounded())
        }
        return channels[0] << 16 | channels[1] << 8 | channels[2]
    }
}
