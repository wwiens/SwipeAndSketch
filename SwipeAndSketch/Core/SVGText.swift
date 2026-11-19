import Foundation
import CoreGraphics
import CoreText

// SVG import, part 4: text turned into the outlines of its letters, in the fonts this device
// has. A font the file names but the device lacks is replaced by the closest one (by family, then
// weight and slant) and the warning says which.

enum SVGText {
    struct Run {
        /// The letters' outlines in the text element's coordinates (SVG's, Y down).
        var path: CGPath
        var style: SVGStyle
    }

    /// The outlines of a `<text>` element and its `<tspan>`s, each run with the style it paints with.
    static func runs(of text: SVGNode, style: SVGStyle, sheet: SVGStyleSheet, viewport: CGSize, warnings: inout SVGWarnings) -> [Run] {
        var layout = Layout(sheet: sheet, viewport: viewport)
        layout.walk(text, style: style, root: true)
        layout.finishChunk()
        warnings.add(layout.warnings)
        return layout.runs
    }

    private struct Glyphs {
        var path: CGMutablePath
        var style: SVGStyle
    }

    private struct Layout {
        let sheet: SVGStyleSheet
        let viewport: CGSize
        var x = 0.0, y = 0.0
        var runs: [Run] = []
        var warnings = SVGWarnings()
        /// The runs of the current chunk (text set from one absolute position), which `text-anchor`
        /// moves together, and where the chunk began.
        var chunk: [Glyphs] = []
        var chunkStart = 0.0
        var anchor = "start"
        var lastWasSpace = true

        init(sheet: SVGStyleSheet, viewport: CGSize) { self.sheet = sheet; self.viewport = viewport }

        mutating func finishChunk() {
            let width = x - chunkStart
            let shift: Double = switch anchor { case "middle": -width / 2; case "end": -width; default: 0 }
            for glyphs in chunk {
                let moved = glyphs.path.copy(using: [CGAffineTransform(translationX: shift, y: 0)]) ?? glyphs.path
                if moved.hasSegments { runs.append(Run(path: moved, style: glyphs.style)) }
            }
            chunk = []
        }

        private func lengths(_ node: SVGNode, _ name: String, reference: Double, fontSize: Double) -> [Double] {
            guard let text = node[name] else { return [] }
            return text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { SVGValues.userLength(String($0), reference: reference, fontSize: fontSize) }
        }

        mutating func walk(_ node: SVGNode, style: SVGStyle, root: Bool) {
            let fontSize = style.fontSize
            var xs = lengths(node, "x", reference: viewport.width, fontSize: fontSize)
            var ys = lengths(node, "y", reference: viewport.height, fontSize: fontSize)
            var dxs = lengths(node, "dx", reference: viewport.width, fontSize: fontSize)
            var dys = lengths(node, "dy", reference: viewport.height, fontSize: fontSize)
            if root { anchor = style["text-anchor"]?.lowercased() ?? "start" }
            for child in node.children {
                if child.name == "#text" {
                    var characters = collapse(child.text)
                    guard !characters.isEmpty else { continue }
                    if lastWasSpace, characters.first == " " { characters.removeFirst() }
                    guard !characters.isEmpty else { continue }
                    lastWasSpace = characters.last == " "
                    // Characters given positions of their own are set one at a time.
                    let positioned = max(xs.count, ys.count, dxs.count, dys.count)
                    var rest = Substring(characters)
                    while !rest.isEmpty {
                        let piece = positioned > 0 ? String(rest.prefix(1)) : String(rest)
                        rest = rest.dropFirst(piece.count)
                        if !xs.isEmpty || !ys.isEmpty {
                            let newX = xs.isEmpty ? nil : xs.removeFirst(), newY = ys.isEmpty ? nil : ys.removeFirst()
                            if newX != nil { finishChunk(); if root || chunk.isEmpty { anchor = style["text-anchor"]?.lowercased() ?? anchor } }
                            if let newX { x = newX; chunkStart = newX }
                            if let newY { y = newY }
                        }
                        if !dxs.isEmpty { x += dxs.removeFirst() }
                        if !dys.isEmpty { y += dys.removeFirst() }
                        set(piece, style: style)
                    }
                } else if child.name == "tspan" || child.name == "a" {
                    let childStyle = SVGStyle(node: child, parent: style, sheet: sheet)
                    guard childStyle.isDisplayed else { continue }
                    walk(child, style: childStyle, root: false)
                } else if child.name == "textPath" {
                    warnings.add("Text along a path was left out")
                } else if child.name == "tref" {
                    warnings.add("Referenced text (tref) was left out")
                }
            }
        }

        /// XML's default spacing: line breaks and tabs are spaces, and runs of spaces are one.
        private func collapse(_ text: String) -> String {
            var result = ""
            var space = false
            for character in text {
                if character.isWhitespace {
                    if !space { result.append(" ") }
                    space = true
                } else {
                    result.append(character); space = false
                }
            }
            return result
        }

        /// Sets `string` at the pen in `style`'s font, moving the pen past it.
        private mutating func set(_ string: String, style: SVGStyle) {
            let size = style.fontSize
            guard size > 0, size.isFinite else { return }
            let (font, substitute) = SVGFonts.font(family: style["font-family"] ?? "sans-serif", weight: style["font-weight"] ?? "normal",
                                                   italic: ["italic", "oblique"].contains(style["font-style"]?.lowercased() ?? ""), size: size)
            if let substitute { warnings.add(substitute) }
            let spacing = SVGValues.userLength(style["letter-spacing"].flatMap { $0.lowercased() == "normal" ? nil : $0 }, fontSize: size) ?? 0
            let wordSpacing = SVGValues.userLength(style["word-spacing"].flatMap { $0.lowercased() == "normal" ? nil : $0 }, fontSize: size) ?? 0
            let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            let path = CGMutablePath()
            var extra = 0.0
            let characters = Array(string.utf16)
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
                for index in 0..<count {
                    let character = indices[index] < characters.count ? characters[indices[index]] : 0
                    let offset = extra + spacing * Double(indices[index])
                    // Glyph outlines are Y up; SVG's text sits on its baseline with Y down.
                    var placement = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x + positions[index].x + offset, ty: y)
                    if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], &placement) { path.addPath(glyph) }
                    if character == 0x20 { extra += wordSpacing }
                }
            }
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil) + spacing * Double(string.count) + extra
            chunk.append(Glyphs(path: path, style: style))
            x += advance
        }
    }
}

/// Font matching for imported text.
enum SVGFonts {
    /// Families every iPad has that stand in for CSS's generic ones.
    static let generic: [String: String] = ["serif": "Times New Roman", "sans-serif": "Helvetica", "monospace": "Menlo",
                                            "cursive": "Snell Roundhand", "fantasy": "Marker Felt", "system-ui": "Helvetica",
                                            "ui-sans-serif": "Helvetica", "ui-serif": "Times New Roman", "ui-monospace": "Menlo",
                                            "ui-rounded": "Arial Rounded MT Bold"]

    /// The font for a CSS family list, weight, and slant, and a warning when the file's first
    /// choice is not on this device.
    static func font(family list: String, weight: String, italic: Bool, size: Double) -> (CTFont, String?) {
        let families = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }.filter { !$0.isEmpty }
        let wanted = SVGFonts.weight(weight)
        for (index, family) in families.enumerated() {
            let name = generic[family.lowercased()] ?? family
            if let font = match(family: name, weight: wanted, italic: italic, size: size) {
                // A generic family, or a later choice the file allowed for, needs no warning.
                let first = families[0]
                let warning = index == 0 || generic[first.lowercased()] != nil ? nil : "The font \(first) is not on this iPad; its text uses \(name)"
                return (font, warning)
            }
        }
        let fallback = match(family: "Helvetica", weight: wanted, italic: italic, size: size) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let warning = families.first.map { "The font \($0) is not on this iPad; its text uses Helvetica" }
        return (fallback, warning)
    }

    /// CSS weights as Core Text's, −1 (thinnest) to 1 (heaviest).
    static func weight(_ text: String) -> Double {
        let numeric: Double = switch text.lowercased() {
        case "normal": 400
        case "bold": 700
        case "bolder": 800
        case "lighter": 300
        default: Double(text) ?? 400
        }
        let table: [(Double, Double)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let nearest = table.min { abs($0.0 - numeric) < abs($1.0 - numeric) }
        return nearest?.1 ?? 0
    }

    private static func match(family: String, weight: Double, italic: Bool, size: Double) -> CTFont? {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        guard let candidates = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, NSSet(object: kCTFontFamilyNameAttribute) as CFSet) as? [CTFontDescriptor],
              !candidates.isEmpty else { return nil }
        func traits(_ descriptor: CTFontDescriptor) -> (weight: Double, italic: Bool) {
            let values = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let weight = (values[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let symbolic = (values[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            return (weight, symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0)
        }
        let best = candidates.min { a, b in
            let ta = traits(a), tb = traits(b)
            return abs(ta.weight - weight) + (ta.italic == italic ? 0 : 1) < abs(tb.weight - weight) + (tb.italic == italic ? 0 : 1)
        }
        return best.map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }
}
