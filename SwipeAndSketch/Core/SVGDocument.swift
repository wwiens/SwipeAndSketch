import Foundation
import CoreGraphics

// SVG import, part 1: the file read into a tree of elements, its style sheet, and the values
// SVG writes (colors, lengths, number lists, transforms). Nothing here is fetched from the
// network: external entities are never resolved, and only `#id` references and `data:` images
// are followed. See SVGImport.swift for the whole pipeline.

/// One element of an SVG file, or a run of text inside one (`name == "#text"`).
final class SVGNode: @unchecked Sendable {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [SVGNode] = []
    fileprivate(set) weak var parent: SVGNode?
    /// A text run's characters (only for `#text` nodes).
    fileprivate(set) var text = ""
    /// The class names in its `class` attribute.
    let classes: [String]

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
        classes = (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    subscript(_ attribute: String) -> String? { attributes[attribute] }
    var id: String? { attributes["id"] }
    /// The `#id` an `href` (or the older `xlink:href`) names.
    var reference: String? {
        guard let href = attributes["href"] ?? attributes["xlink:href"] else { return nil }
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : nil
    }
    var elementChildren: [SVGNode] { children.filter { $0.name != "#text" } }
    /// All the text inside it, in order (a `<style>` element's sheet).
    var allText: String { name == "#text" ? text : children.map(\.allText).joined() }
}

/// A parsed SVG file: its root `<svg>` element, its elements by id, and its style sheet.
final class SVGTree: @unchecked Sendable {
    let root: SVGNode
    let byID: [String: SVGNode]
    let sheet: SVGStyleSheet
    let elementCount: Int

    static let maximumElements = 400_000
    static let maximumDepth = 512
    static let maximumTextBytes = 32 * 1024 * 1024

    init(root: SVGNode, byID: [String: SVGNode], sheet: SVGStyleSheet, elementCount: Int) {
        self.root = root; self.byID = byID; self.sheet = sheet; self.elementCount = elementCount
    }

    /// Reads an SVG file's XML. Throws when it is not XML, not SVG, or larger than an import takes.
    static func parse(_ data: Data) throws -> SVGTree {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = builder
        let parsed = parser.parse()
        if builder.tooLarge { throw SolidKernel.Failure(message: "This SVG file has more in it than an import can take.") }
        guard parsed || builder.root != nil && parser.parserError == nil else {
            throw SolidKernel.Failure(message: "This SVG file could not be read: it is not well-formed XML.")
        }
        guard let root = builder.root, root.name == "svg" else {
            throw SolidKernel.Failure(message: "This file is not an SVG drawing.")
        }
        var byID: [String: SVGNode] = [:]
        var styles: [String] = []
        func index(_ node: SVGNode) {
            if let id = node.id, byID[id] == nil { byID[id] = node }
            if node.name == "style" { styles.append(node.allText) }
            node.children.forEach(index)
        }
        index(root)
        return SVGTree(root: root, byID: byID, sheet: SVGStyleSheet(styles.joined(separator: "\n")), elementCount: builder.count)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: SVGNode?
        var stack: [SVGNode] = []
        var count = 0
        var textBytes = 0
        var tooLarge = false

        /// "svg:path" and "path" are the same element; attributes keep their prefixes
        /// ("inkscape:label"), and `xlink:href` is read as `href` too.
        private func local(_ name: String) -> String {
            guard let colon = name.lastIndex(of: ":") else { return name }
            return String(name[name.index(after: colon)...])
        }

        private func stop(_ parser: XMLParser) { tooLarge = true; parser.abortParsing() }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            count += 1
            guard count <= SVGTree.maximumElements, stack.count < SVGTree.maximumDepth else { return stop(parser) }
            var attributes = attributes
            if attributes["href"] == nil, let href = attributes["xlink:href"] { attributes["href"] = href }
            let node = SVGNode(name: local(elementName), attributes: attributes)
            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
            } else if root == nil {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        private func add(_ string: String, _ parser: XMLParser) {
            textBytes += string.utf8.count
            guard textBytes <= SVGTree.maximumTextBytes else { return stop(parser) }
            guard let parent = stack.last else { return }
            if let last = parent.children.last, last.name == "#text" {
                last.text += string
            } else {
                let node = SVGNode(name: "#text", attributes: [:])
                node.text = string
                node.parent = parent
                parent.children.append(node)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { add(string, parser) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { add(String(decoding: CDATABlock, as: UTF8.self), parser) }
    }
}

// MARK: Style sheet

/// The rules of the file's `<style>` elements: type, `.class`, and `#id` selectors, compounds of
/// them (`path.cls-1`), descendant combinations (`g .cls-1`), and comma lists, with specificity
/// and `!important`. Rules using anything else (child or sibling combinators, attribute selectors,
/// pseudo-classes, at-rules) are left out.
struct SVGStyleSheet: Sendable {
    struct Compound: Sendable {
        var type: String?
        var id: String?
        var classes: [String] = []
        func matches(_ node: SVGNode) -> Bool {
            if let type, type != "*", type != node.name { return false }
            if let id, node.id != id { return false }
            return classes.allSatisfy(node.classes.contains)
        }
    }
    struct Rule: Sendable {
        /// Compounds from the outermost ancestor to the element itself.
        var selector: [Compound]
        var specificity: Int
        var order: Int
        var declarations: [(name: String, value: String, important: Bool)]
    }
    let rules: [Rule]

    init(_ text: String) {
        var rules: [Rule] = []
        var text = text
        // Comments out first.
        while let open = text.range(of: "/*") {
            let close = text.range(of: "*/", range: open.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            text.removeSubrange(open.lowerBound..<close)
        }
        var rest = Substring(text)
        var order = 0
        while let brace = rest.firstIndex(of: "{") {
            let prelude = rest[..<brace].trimmingCharacters(in: .whitespacesAndNewlines)
            // The block, nesting included (an at-rule's block holds whole rules).
            var depth = 0, end = brace
            for index in rest[brace...].indices {
                if rest[index] == "{" { depth += 1 } else if rest[index] == "}" { depth -= 1; if depth == 0 { end = index; break } }
            }
            guard depth == 0, end > brace else { break }
            let body = rest[rest.index(after: brace)..<end]
            rest = rest[rest.index(after: end)...]
            guard !prelude.hasPrefix("@") else { continue }
            let declarations = Self.declarations(String(body))
            guard !declarations.isEmpty else { continue }
            for selectorText in prelude.split(separator: ",") {
                guard let selector = Self.selector(selectorText.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                let specificity = selector.reduce(0) { $0 + ($1.id != nil ? 100 : 0) + $1.classes.count * 10 + ($1.type.map { $0 == "*" ? 0 : 1 } ?? 0) }
                rules.append(Rule(selector: selector, specificity: specificity, order: order, declarations: declarations))
                order += 1
            }
        }
        self.rules = rules.sorted { ($0.specificity, $0.order) < ($1.specificity, $1.order) }
    }

    /// "fill: red; stroke-width: 2 !important" as declarations, names lowercased.
    static func declarations(_ text: String) -> [(name: String, value: String, important: Bool)] {
        text.split(separator: ";").compactMap { item in
            guard let colon = item.firstIndex(of: ":") else { return nil }
            let name = item[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = item[item.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let bang = value.range(of: "!important", options: [.caseInsensitive, .backwards]) {
                important = true
                value = value[..<bang.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return (name, value, important)
        }
    }

    private static func selector(_ text: String) -> [Compound]? {
        guard !text.isEmpty, text.rangeOfCharacter(from: CharacterSet(charactersIn: ">+~[]:()")) == nil else { return nil }
        var compounds: [Compound] = []
        for part in text.split(whereSeparator: \.isWhitespace) {
            var compound = Compound()
            var current = "", kind: Character = " "
            func flush() {
                guard !current.isEmpty else { return }
                switch kind {
                case ".": compound.classes.append(current)
                case "#": compound.id = current
                default: compound.type = current
                }
                current = ""
            }
            for character in part {
                if character == "." || character == "#" { flush(); kind = character } else { current.append(character) }
            }
            flush()
            compounds.append(compound)
        }
        return compounds.isEmpty ? nil : compounds
    }

    /// The declarations that apply to `node`, weakest first.
    func declarations(for node: SVGNode) -> [(name: String, value: String, important: Bool)] {
        var result: [(name: String, value: String, important: Bool)] = []
        for rule in rules where Self.matches(rule.selector, node) { result += rule.declarations }
        return result
    }

    private static func matches(_ selector: [Compound], _ node: SVGNode) -> Bool {
        guard let last = selector.last, last.matches(node) else { return false }
        var remaining = selector.dropLast()
        var ancestor = node.parent
        while let compound = remaining.last {
            guard let current = ancestor else { return false }
            if compound.matches(current) { remaining = remaining.dropLast() }
            ancestor = current.parent
        }
        return true
    }
}

// MARK: Computed style

/// The style properties an element ends up with: presentation attributes, then the style sheet,
/// then its `style` attribute, with `!important` declarations last; inherited properties come
/// from the parent unless set.
struct SVGStyle: Sendable {
    private(set) var values: [String: String]

    static let properties: Set<String> = [
        "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin",
        "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "display", "visibility", "clip-path", "clip-rule",
        "mask", "filter", "color", "font-family", "font-size", "font-weight", "font-style", "text-anchor", "letter-spacing",
        "word-spacing", "stop-color", "stop-opacity", "paint-order", "vector-effect", "marker-start", "marker-mid", "marker-end",
        "marker", "font", "dominant-baseline", "text-decoration", "transform"]
    /// Properties an element does not take from its parent.
    static let notInherited: Set<String> = ["opacity", "display", "clip-path", "mask", "filter", "stop-color", "stop-opacity", "transform"]

    static let initial = SVGStyle(values: ["fill": "black", "fill-rule": "nonzero", "stroke": "none", "stroke-width": "1",
                                           "stroke-linecap": "butt", "stroke-linejoin": "miter", "stroke-miterlimit": "4",
                                           "font-size": "16", "font-family": "sans-serif", "font-weight": "normal",
                                           "font-style": "normal", "text-anchor": "start", "visibility": "visible",
                                           "color": "black", "clip-rule": "nonzero"])

    init(values: [String: String]) { self.values = values }

    subscript(_ name: String) -> String? { values[name] }

    /// `node`'s style, given its parent's.
    init(node: SVGNode, parent: SVGStyle, sheet: SVGStyleSheet) {
        var specified: [String: String] = [:]
        for (name, value) in node.attributes where Self.properties.contains(name) && name != "transform" { specified[name] = value }
        var important: [String: String] = [:]
        for declaration in sheet.declarations(for: node) {
            if declaration.important { important[declaration.name] = declaration.value } else { specified[declaration.name] = declaration.value }
        }
        if let inline = node["style"] {
            for declaration in SVGStyleSheet.declarations(inline) {
                if declaration.important { important[declaration.name] = declaration.value } else { specified[declaration.name] = declaration.value }
            }
        }
        for (name, value) in important { specified[name] = value }
        if let font = specified.removeValue(forKey: "font") { Self.expandFont(font, into: &specified) }
        if let marker = specified.removeValue(forKey: "marker") {
            for name in ["marker-start", "marker-mid", "marker-end"] where specified[name] == nil { specified[name] = marker }
        }
        var values = parent.values.filter { !Self.notInherited.contains($0.key) }
        for (name, value) in specified {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "inherit" { values[name] = parent.values[name] } else { values[name] = trimmed }
        }
        // `font-size` in em or % is relative to the parent's.
        if let size = specified["font-size"] {
            let parentSize = SVGValues.number(parent.values["font-size"] ?? "16") ?? 16
            if let resolved = SVGValues.fontSize(size, parent: parentSize) { values["font-size"] = String(resolved) }
        }
        self.values = values
    }

    /// The `font` shorthand: "italic bold 12px Helvetica, sans-serif".
    private static func expandFont(_ font: String, into values: inout [String: String]) {
        var words = font.split(separator: " ").map(String.init)
        while let word = words.first {
            let lower = word.lowercased()
            if ["italic", "oblique"].contains(lower) { values["font-style"] = lower }
            else if ["bold", "bolder", "lighter"].contains(lower) || Int(lower) != nil { values["font-weight"] = lower }
            else if ["normal", "small-caps"].contains(lower) {}
            else { break }
            words.removeFirst()
        }
        guard let size = words.first else { return }
        values["font-size"] = String(size.split(separator: "/").first ?? Substring(size))
        let family = words.dropFirst().joined(separator: " ")
        if !family.isEmpty { values["font-family"] = family }
    }

    var opacity: Double { SVGValues.opacity(values["opacity"]) }
    var fillOpacity: Double { SVGValues.opacity(values["fill-opacity"]) }
    var strokeOpacity: Double { SVGValues.opacity(values["stroke-opacity"]) }
    var isDisplayed: Bool { values["display"]?.lowercased() != "none" }
    var isVisible: Bool { !["hidden", "collapse"].contains(values["visibility"]?.lowercased() ?? "visible") }
    var fillRule: CGPathFillRule { values["fill-rule"]?.lowercased() == "evenodd" ? .evenOdd : .winding }
    var clipRule: CGPathFillRule { values["clip-rule"]?.lowercased() == "evenodd" ? .evenOdd : .winding }
    var fontSize: Double { SVGValues.number(values["font-size"] ?? "16") ?? 16 }
    /// The `url(#id)` a property names.
    func reference(_ name: String) -> String? { SVGValues.urlReference(values[name]) }
}

// MARK: Values

/// An sRGB color, 0…1.
struct SVGColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    static let black = SVGColor(red: 0, green: 0, blue: 0)
    static let gray = SVGColor(red: 0.5, green: 0.5, blue: 0.5)
    var hex: String { String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())) }
    func distance(to other: SVGColor) -> Double {
        let r = red - other.red, g = green - other.green, b = blue - other.blue
        return (r * r * 2 + g * g * 4 + b * b * 3).squareRoot() / 3
    }
    /// White or nearly white: light and without much color.
    var isWhite: Bool { min(red, green, blue) >= 0.9 && max(red, green, blue) - min(red, green, blue) < 0.06 }
}

enum SVGValues {
    /// Numbers in an SVG list: separated by spaces or commas, or by nothing where a sign or a
    /// second decimal point starts the next ("10-5", "1.5.5"). Stops at anything else.
    static func numbers(_ text: Substring) -> [Double] {
        var scanner = NumberScanner(text)
        var result: [Double] = []
        while let value = scanner.next() { result.append(value) }
        return result
    }
    static func numbers(_ text: String) -> [Double] { numbers(Substring(text)) }

    struct NumberScanner {
        let bytes: [UInt8]
        var index = 0
        init(_ text: Substring) { bytes = Array(text.utf8) }

        mutating func skipSeparators() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x2C].contains(bytes[index]) { index += 1 }
        }
        var atEnd: Bool { index >= bytes.count }
        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        /// The next number, or nil (and no progress) when none starts here.
        mutating func next() -> Double? {
            skipSeparators()
            let start = index
            var i = index
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            var digits = 0, dot = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 0x30 && b <= 0x39 { digits += 1; i += 1 } else if b == 0x2E && !dot { dot = true; i += 1 } else { break }
            }
            guard digits > 0 else { index = start; return nil }
            if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
                var j = i + 1
                if j < bytes.count, bytes[j] == 0x2B || bytes[j] == 0x2D { j += 1 }
                var expDigits = 0
                while j < bytes.count, bytes[j] >= 0x30 && bytes[j] <= 0x39 { j += 1; expDigits += 1 }
                if expDigits > 0 { i = j }
            }
            guard let value = Double(String(decoding: bytes[start..<i], as: UTF8.self)), value.isFinite else { index = start; return nil }
            index = i
            return value
        }

        /// An arc flag: a single 0 or 1, which may run straight into the next number ("a1 1 0 0110 10").
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else { return nil }
            defer { index += 1 }
            return bytes[index] == 0x31
        }
    }

    /// A leading number, ignoring any unit after it ("12px" is 12).
    static func number(_ text: String) -> Double? {
        var scanner = NumberScanner(Substring(text))
        return scanner.next()
    }

    enum Unit { case user, mm, cm, inch, pt, pc, em, ex, percent }

    /// A length and its unit; nil when it is not a length.
    static func length(_ text: String?) -> (value: Double, unit: Unit)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var scanner = NumberScanner(Substring(text))
        guard let value = scanner.next() else { return nil }
        let suffix = String(decoding: scanner.bytes[scanner.index...], as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
        switch suffix {
        case "", "px": return (value, .user)
        case "mm": return (value, .mm)
        case "cm": return (value, .cm)
        case "in": return (value, .inch)
        case "pt": return (value, .pt)
        case "pc": return (value, .pc)
        case "em": return (value, .em)
        case "ex": return (value, .ex)
        case "%": return (value, .percent)
        default: return nil
        }
    }

    /// User units (CSS pixels, 96 to the inch) per unit.
    static func userUnits(per unit: Unit, fontSize: Double = 16) -> Double? {
        switch unit {
        case .user: 1
        case .mm: 96 / 25.4
        case .cm: 96 / 2.54
        case .inch: 96
        case .pt: 96.0 / 72
        case .pc: 16
        case .em: fontSize
        case .ex: fontSize / 2
        case .percent: nil
        }
    }

    /// A length in user units; percentages are of `reference`.
    static func userLength(_ text: String?, reference: Double = 0, fontSize: Double = 16) -> Double? {
        guard let (value, unit) = length(text) else { return nil }
        if unit == .percent { return value / 100 * reference }
        return userUnits(per: unit, fontSize: fontSize).map { value * $0 }
    }

    static func fontSize(_ text: String, parent: Double) -> Double? {
        let named: [String: Double] = ["xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32]
        if let size = named[text.lowercased()] { return size }
        guard let (value, unit) = length(text) else { return nil }
        switch unit {
        case .percent: return value / 100 * parent
        case .em: return value * parent
        case .ex: return value * parent / 2
        default: return userUnits(per: unit).map { value * $0 }
        }
    }

    static func opacity(_ text: String?) -> Double {
        guard let text = text?.trimmingCharacters(in: .whitespaces), let (value, unit) = length(text) else { return 1 }
        return min(1, max(0, unit == .percent ? value / 100 : value))
    }

    /// The id in "url(#id)" (or "url('#id') fallback").
    static func urlReference(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.lowercased().hasPrefix("url("),
              let close = text.firstIndex(of: ")") else { return nil }
        var inner = text[text.index(text.startIndex, offsetBy: 4)..<close].trimmingCharacters(in: .whitespaces)
        inner = inner.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return inner.hasPrefix("#") ? String(inner.dropFirst()) : nil
    }

    /// What follows "url(#id)" in a paint: its fallback color.
    static func urlFallback(_ text: String) -> String? {
        guard let close = text.firstIndex(of: ")") else { return nil }
        let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    // MARK: Colors

    /// A CSS color: "#rgb", "#rrggbb" (with alpha too), "rgb()", "rgba()", "hsl()", "hsla()", or a
    /// name. The alpha is returned separately.
    static func color(_ text: String) -> (color: SVGColor, alpha: Double)? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            let digits = Array(text.dropFirst())
            guard digits.allSatisfy(\.isHexDigit) else { return nil }
            func value(_ s: [Character]) -> Double { Double(Int(String(s), radix: 16) ?? 0) / Double((1 << (4 * s.count)) - 1) }
            switch digits.count {
            case 3, 4:
                let c = digits.map { [$0] }
                return (SVGColor(red: value(c[0]), green: value(c[1]), blue: value(c[2])), digits.count == 4 ? value(c[3]) : 1)
            case 6, 8:
                return (SVGColor(red: value(Array(digits[0..<2])), green: value(Array(digits[2..<4])), blue: value(Array(digits[4..<6]))),
                        digits.count == 8 ? value(Array(digits[6..<8])) : 1)
            default: return nil
            }
        }
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") {
            let function = text[..<open].trimmingCharacters(in: .whitespaces)
            let parts = text[text.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count >= 3 else { return nil }
            func channel(_ s: String) -> Double? {
                guard let (v, unit) = length(s) else { return nil }
                return min(1, max(0, unit == .percent ? v / 100 : v / 255))
            }
            let alpha = parts.count > 3 ? opacity(parts[3]) : 1
            if function == "rgb" || function == "rgba" {
                guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
                return (SVGColor(red: r, green: g, blue: b), alpha)
            }
            if function == "hsl" || function == "hsla" {
                guard let h = number(parts[0]), let s = length(parts[1])?.value, let l = length(parts[2])?.value else { return nil }
                return (hsl(h, s / 100, l / 100), alpha)
            }
            return nil
        }
        if text == "transparent" { return (.black, 0) }
        return namedColors[text].map { ($0, 1) }
    }

    private static func hsl(_ hue: Double, _ s: Double, _ l: Double) -> SVGColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func f(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return SVGColor(red: f(h + 1.0 / 3), green: f(h), blue: f(h - 1.0 / 3))
    }

    static let namedColors: [String: SVGColor] = {
        let table = """
        aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 black 000000 \
        blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 \
        chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff darkblue 00008b \
        darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b \
        darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f \
        darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 \
        deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 forestgreen 228b22 \
        fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 grey 808080 green 008000 \
        greenyellow adff2f honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa \
        lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff \
        lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a \
        lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0 \
        lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd \
        mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a \
        mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 \
        navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 \
        palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 \
        peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f \
        royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d \
        silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f \
        steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 \
        white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32
        """
        let words = table.split(whereSeparator: \.isWhitespace)
        var colors: [String: SVGColor] = [:]
        for index in stride(from: 0, to: words.count - 1, by: 2) {
            let hex = Int(words[index + 1], radix: 16) ?? 0
            colors[String(words[index])] = SVGColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
        }
        return colors
    }()

    // MARK: Transforms

    /// A `transform` attribute: matrix, translate, scale, rotate (about a point too), skewX, and
    /// skewY, applied left to right as SVG does. Nil when it cannot be read.
    static func transform(_ text: String?) -> CGAffineTransform? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .identity }
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "(") {
            guard let close = rest[open...].firstIndex(of: ")") else { return nil }
            let name = rest[..<open].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))).lowercased()
            let values = numbers(rest[rest.index(after: open)..<close])
            rest = rest[rest.index(after: close)...]
            let step: CGAffineTransform
            switch (name, values.count) {
            case ("matrix", 6): step = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case ("translate", 1): step = CGAffineTransform(translationX: values[0], y: 0)
            case ("translate", 2): step = CGAffineTransform(translationX: values[0], y: values[1])
            case ("scale", 1): step = CGAffineTransform(scaleX: values[0], y: values[0])
            case ("scale", 2): step = CGAffineTransform(scaleX: values[0], y: values[1])
            case ("rotate", 1): step = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
            case ("rotate", 3):
                step = CGAffineTransform(translationX: values[1], y: values[2]).rotated(by: values[0] * .pi / 180).translatedBy(x: -values[1], y: -values[2])
            case ("skewx", 1): step = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewy", 1): step = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return nil
            }
            // Each function applies inside the ones before it.
            result = step.concatenating(result)
        }
        return result
    }

    /// How a viewport shows a view box (`preserveAspectRatio`), as a transform from view-box
    /// coordinates to the viewport's.
    static func viewBoxTransform(_ box: CGRect, into viewport: CGRect, preserve: String?) -> CGAffineTransform {
        guard box.width > 0, box.height > 0, viewport.width > 0, viewport.height > 0 else { return .identity }
        let words = (preserve ?? "xMidYMid meet").split(separator: " ").map { $0.lowercased() }
        var sx = viewport.width / box.width, sy = viewport.height / box.height
        let align = words.first { $0 != "defer" } ?? "xmidymid"
        if align != "none" {
            let scale = words.contains("slice") ? max(sx, sy) : min(sx, sy)
            sx = scale; sy = scale
        }
        var tx = viewport.minX - box.minX * sx, ty = viewport.minY - box.minY * sy
        if align != "none" {
            let extraX = viewport.width - box.width * sx, extraY = viewport.height - box.height * sy
            if align.contains("xmid") { tx += extraX / 2 } else if align.contains("xmax") { tx += extraX }
            if align.contains("ymid") { ty += extraY / 2 } else if align.contains("ymax") { ty += extraY }
        }
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
    }
}
