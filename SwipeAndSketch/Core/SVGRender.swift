import Foundation
import CoreGraphics
import ImageIO

// SVG import, part 3: the drawing painted the way an SVG viewer would, but into areas instead
// of pixels. Every visible fill and stroke becomes an area in millimeters (Y up, as sketches are),
// already clipped and with its fill rule applied, in the order the file paints them. Hidden
// things are left out; what cannot be turned into geometry is named in the warnings.

/// One thing the drawing paints.
struct SVGPaint: @unchecked Sendable {
    enum Kind: Sendable { case fill, stroke, image }
    enum Source: Sendable { case shape, text, image }
    var kind: Kind
    var source: Source
    /// Fills and strokes: what is painted (a stroke's outline), with holes where the fill rule
    /// leaves them. Images: empty until traced.
    var area: CGPath
    /// Strokes: the line the stroke runs along.
    var centerline: CGPath?
    /// Strokes: how wide, in millimeters.
    var strokeWidth: Double = 0
    var color: SVGColor
    /// The layer (a top-level group) it is in; nil at the top of the drawing.
    var layer: Int?
    /// Images: the picture and where its unit square lands, with the clips that apply to it.
    var image: CGImage?
    var imageTransform: CGAffineTransform = .identity
    /// The clips that apply to it (images are clipped when traced; fills and strokes already are).
    var clips: [CGPath] = []
    /// Fills and strokes under clips: the area before clipping, so colors under one clip can
    /// cover each other before it cuts them all along one edge.
    var unclipped: CGPath?
    var bounds: CGRect { kind == .image ? CGRect(x: 0, y: 0, width: 1, height: 1).applying(imageTransform) : area.boundingBoxOfPath }
}

/// What could not be brought in, each kind once with how often it happened.
struct SVGWarnings: Sendable, Equatable {
    private(set) var counts: [String: Int] = [:]
    private(set) var order: [String] = []
    mutating func add(_ message: String, count: Int = 1) {
        guard count > 0 else { return }
        if counts[message] == nil { order.append(message) }
        counts[message, default: 0] += count
    }
    mutating func add(_ other: SVGWarnings) { for message in other.order { add(message, count: other.counts[message] ?? 1) } }
    /// A message that says the same however often it happens (which font stood in for which).
    mutating func note(_ message: String) { if counts[message] == nil { add(message) } }
    var isEmpty: Bool { order.isEmpty }
    var messages: [String] { order.map { message in (counts[message] ?? 1) > 1 ? "\(message) (\(counts[message] ?? 1)×)" : message } }
}

/// The painted drawing.
struct SVGPainting: @unchecked Sendable {
    var paints: [SVGPaint]
    var layers: [String]
    var warnings: SVGWarnings
    /// The drawing's size in millimeters, and whether the file says how big it is in real units
    /// (millimeters, inches, …) rather than only in pixels.
    var viewSize: CGSize
    var hasPhysicalSize: Bool
    /// Where the file's own origin (0, 0) lands, in the same millimeters.
    var origin: CGPoint
}

struct SVGRenderer {
    let tree: SVGTree
    private(set) var paints: [SVGPaint] = []
    private(set) var layers: [String] = []
    private(set) var warnings = SVGWarnings()
    private var expansions = 0
    private var useStack: [String] = []

    /// Millimeters per CSS pixel.
    static let millimetersPerPixel = 25.4 / 96
    static let maximumPaints = 50_000
    static let maximumExpansions = 100_000

    init(tree: SVGTree) { self.tree = tree }

    static func paint(_ tree: SVGTree) throws -> SVGPainting {
        var renderer = SVGRenderer(tree: tree)
        let root = tree.root
        // The root's size: real units when given, otherwise its view box in pixels.
        let box = SVGValues.numbers(root["viewBox"] ?? "")
        let viewBox = box.count == 4 && box[2] > 0 && box[3] > 0 ? CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) : nil
        let width = SVGValues.length(root["width"]), height = SVGValues.length(root["height"])
        let physical: Set<SVGValues.Unit> = [.mm, .cm, .inch, .pt, .pc]
        let hasPhysicalSize = [width, height].contains { $0.map { physical.contains($0.unit) } ?? false }
        func pixels(_ length: (value: Double, unit: SVGValues.Unit)?, _ fallback: Double?) -> Double? {
            guard let length, length.unit != .percent, let per = SVGValues.userUnits(per: length.unit) else { return fallback }
            return length.value * per
        }
        var viewportWidth = pixels(width, viewBox.map { Double($0.width) }), viewportHeight = pixels(height, viewBox.map { Double($0.height) })
        // One side given with a view box: the other keeps the box's proportions.
        if let box = viewBox {
            if viewportWidth == nil, let h = viewportHeight { viewportWidth = h * box.width / box.height }
            if viewportHeight == nil, let w = viewportWidth { viewportHeight = w * box.height / box.width }
        }
        var toPixels = CGAffineTransform.identity
        var viewport = CGSize(width: viewportWidth ?? 0, height: viewportHeight ?? 0)
        if let box = viewBox, let w = viewportWidth, let h = viewportHeight {
            toPixels = SVGValues.viewBoxTransform(box, into: CGRect(x: 0, y: 0, width: w, height: h), preserve: root["preserveAspectRatio"])
            viewport = box.size
        }
        // Pixels to millimeters, Y turned up.
        let toMillimeters = toPixels.concatenating(CGAffineTransform(scaleX: millimetersPerPixel, y: -millimetersPerPixel))
        let style = SVGStyle(node: root, parent: .initial, sheet: tree.sheet)
        let context = Context(transform: toMillimeters, clips: [], layer: nil, opacity: 1, viewport: viewport)
        try renderer.children(of: root, style: style, context: context, topLevel: true)
        let drawn = renderer.paints.reduce(CGRect.null) { $0.union($1.bounds) }
        var size = CGSize(width: (viewportWidth ?? 0) * millimetersPerPixel, height: (viewportHeight ?? 0) * millimetersPerPixel)
        if size.width <= 0 || size.height <= 0 { size = drawn.isNull ? .zero : drawn.size }
        return SVGPainting(paints: renderer.paints, layers: renderer.layers, warnings: renderer.warnings, viewSize: size,
                           hasPhysicalSize: hasPhysicalSize, origin: CGPoint.zero.applying(toMillimeters))
    }

    struct Context {
        var transform: CGAffineTransform
        var clips: [CGPath]
        var layer: Int?
        var opacity: Double
        /// The nearest viewport's size in its user units, for percentages.
        var viewport: CGSize
    }

    private static let skipped: Set<String> = ["defs", "clipPath", "mask", "marker", "pattern", "symbol", "linearGradient", "radialGradient",
                                               "style", "title", "desc", "metadata", "script", "filter", "font", "font-face", "cursor",
                                               "animate", "animateTransform", "animateMotion", "set", "view", "namedview", "#text"]

    private mutating func children(of node: SVGNode, style: SVGStyle, context: Context, topLevel: Bool = false) throws {
        if node.name == "switch" {
            // The first child a viewer can show; every child here is one.
            if let first = node.elementChildren.first(where: { !Self.skipped.contains($0.name) }) {
                try render(first, parent: style, context: context, topLevel: topLevel)
            }
            return
        }
        for child in node.children { try render(child, parent: style, context: context, topLevel: topLevel) }
    }

    private mutating func render(_ node: SVGNode, parent: SVGStyle, context: Context, topLevel: Bool = false) throws {
        guard !Self.skipped.contains(node.name) else { return }
        expansions += 1
        guard expansions <= Self.maximumExpansions, paints.count <= Self.maximumPaints else {
            throw SolidKernel.Failure(message: "This SVG drawing has more in it than an import can take.")
        }
        let style = SVGStyle(node: node, parent: parent, sheet: tree.sheet)
        guard style.isDisplayed, style.opacity > 0.004 else { return }
        guard let own = SVGValues.transform(node["transform"] ?? style["transform"]) else {
            warnings.add("An element with a transform that could not be read was left out")
            return
        }
        var context = context
        context.transform = own.concatenating(context.transform)
        context.opacity *= style.opacity
        if style["mask"].map({ $0 != "none" }) ?? false { warnings.add("Masks were ignored: the shapes they hide or fade are brought in whole") }
        if style["filter"].map({ $0 != "none" }) ?? false { warnings.add("Filters (blurs, shadows) were ignored") }
        if let clipID = style.reference("clip-path") {
            if let clip = clipPath(clipID, for: node, style: style, context: context) { context.clips.append(clip) }
        }
        if topLevel, ["g", "svg", "a", "switch"].contains(node.name) {
            context.layer = layer(for: node)
        } else if node.name == "g", node["inkscape:groupmode"] == "layer" {
            context.layer = layer(for: node)
        }
        switch node.name {
        case "g", "a":
            try children(of: node, style: style, context: context)
        case "switch":
            try children(of: node, style: style, context: context)
        case "svg":
            // A nested viewport: its own view box fitted into its x, y, width, and height.
            var inner = context
            let x = SVGValues.userLength(node["x"], reference: context.viewport.width) ?? 0
            let y = SVGValues.userLength(node["y"], reference: context.viewport.height) ?? 0
            let width = SVGValues.userLength(node["width"], reference: context.viewport.width) ?? context.viewport.width
            let height = SVGValues.userLength(node["height"], reference: context.viewport.height) ?? context.viewport.height
            let box = SVGValues.numbers(node["viewBox"] ?? "")
            if box.count == 4, box[2] > 0, box[3] > 0 {
                let viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                inner.transform = SVGValues.viewBoxTransform(viewBox, into: CGRect(x: x, y: y, width: width, height: height),
                                                              preserve: node["preserveAspectRatio"]).concatenating(context.transform)
                inner.viewport = viewBox.size
            } else {
                inner.transform = CGAffineTransform(translationX: x, y: y).concatenating(context.transform)
                inner.viewport = CGSize(width: width, height: height)
            }
            try children(of: node, style: style, context: inner)
        case "use":
            try use(node, style: style, context: context)
        case "text":
            for run in SVGText.runs(of: node, style: style, sheet: tree.sheet, viewport: context.viewport, warnings: &warnings) {
                paint(run.path, style: run.style, context: context, source: .text)
            }
        case "image":
            image(node, style: style, context: context)
        case "foreignObject":
            warnings.add("Embedded web content (foreignObject) was left out")
        case "textPath":
            warnings.add("Text along a path was left out")
        default:
            if SVGShapes.names.contains(node.name) {
                if ["marker-start", "marker-mid", "marker-end"].contains(where: { style.reference($0) != nil }) {
                    warnings.add("Markers (arrowheads and dots on lines) were left out")
                }
                if let path = SVGShapes.path(for: node, viewport: context.viewport, fontSize: style.fontSize) {
                    paint(path, style: style, context: context, source: .shape)
                }
            }
        }
    }

    /// A top-level group or an Inkscape layer: its label, its title, or its id.
    private mutating func layer(for node: SVGNode) -> Int {
        let title = node.elementChildren.first { $0.name == "title" }?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = [node["inkscape:label"], title, node["data-name"], node.id].compactMap { $0 }.first { !$0.isEmpty }
        layers.append(name.flatMap(ItemNames.cleaned) ?? "Layer \(layers.count + 1)")
        return layers.count - 1
    }

    private mutating func use(_ node: SVGNode, style: SVGStyle, context: Context) throws {
        guard let id = node.reference, let target = tree.byID[id] else { return }
        guard !useStack.contains(id), useStack.count < 32 else {
            warnings.add("A reference that leads back to itself was left out")
            return
        }
        useStack.append(id)
        defer { useStack.removeLast() }
        var context = context
        let x = SVGValues.userLength(node["x"], reference: context.viewport.width) ?? 0
        let y = SVGValues.userLength(node["y"], reference: context.viewport.height) ?? 0
        context.transform = CGAffineTransform(translationX: x, y: y).concatenating(context.transform)
        if target.name == "symbol" {
            let symbolStyle = SVGStyle(node: target, parent: style, sheet: tree.sheet)
            let box = SVGValues.numbers(target["viewBox"] ?? "")
            if box.count == 4, box[2] > 0, box[3] > 0 {
                let viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                let width = SVGValues.userLength(node["width"] ?? target["width"], reference: context.viewport.width) ?? viewBox.width
                let height = SVGValues.userLength(node["height"] ?? target["height"], reference: context.viewport.height) ?? viewBox.height
                context.transform = SVGValues.viewBoxTransform(viewBox, into: CGRect(x: 0, y: 0, width: width, height: height),
                                                                preserve: target["preserveAspectRatio"]).concatenating(context.transform)
                context.viewport = viewBox.size
            }
            try children(of: target, style: symbolStyle, context: context)
        } else {
            try render(target, parent: style, context: context)
        }
    }

    // MARK: Painting

    private mutating func paint(_ path: CGPath, style: SVGStyle, context: Context, source: SVGPaint.Source) {
        guard style.isVisible else { return }
        let strokeFirst = (style["paint-order"] ?? "").lowercased().split(separator: " ").first == "stroke"
        let fill = { (renderer: inout SVGRenderer) in renderer.fill(path, style: style, context: context, source: source) }
        let stroke = { (renderer: inout SVGRenderer) in renderer.stroke(path, style: style, context: context, source: source) }
        if strokeFirst { stroke(&self); fill(&self) } else { fill(&self); stroke(&self) }
    }

    private mutating func fill(_ path: CGPath, style: SVGStyle, context: Context, source: SVGPaint.Source) {
        guard let paint = color(style["fill"] ?? "black", style: style), paint.alpha * style.fillOpacity * context.opacity > 0.01 else { return }
        var area = path.copy(using: [context.transform]) ?? path
        area = area.normalized(using: style.fillRule)
        let unclipped = context.clips.isEmpty ? nil : area
        for clip in context.clips { area = area.intersection(clip) }
        guard area.hasSegments else { return }
        paints.append(SVGPaint(kind: .fill, source: source, area: area, color: paint.color, layer: context.layer, clips: context.clips, unclipped: unclipped))
    }

    private mutating func stroke(_ path: CGPath, style: SVGStyle, context: Context, source: SVGPaint.Source) {
        guard let paint = color(style["stroke"] ?? "none", style: style), paint.alpha * style.strokeOpacity * context.opacity > 0.01 else { return }
        let viewport = context.viewport
        let diagonal = (viewport.width * viewport.width + viewport.height * viewport.height).squareRoot() / 2.0.squareRoot()
        guard let width = SVGValues.userLength(style["stroke-width"] ?? "1", reference: diagonal, fontSize: style.fontSize), width > 0 else { return }
        let cap: CGLineCap = switch style["stroke-linecap"]?.lowercased() { case "round": .round; case "square": .square; default: .butt }
        let join: CGLineJoin = switch style["stroke-linejoin"]?.lowercased() { case "round": .round; case "bevel": .bevel; default: .miter }
        let miter = max(1, SVGValues.number(style["stroke-miterlimit"] ?? "4") ?? 4)
        var line: CGPath = path
        if let dashes = style["stroke-dasharray"], dashes.lowercased() != "none" {
            var lengths = SVGValues.numbers(dashes).map { max(0, $0) }
            if lengths.count % 2 == 1 { lengths += lengths }
            if !lengths.isEmpty, lengths.reduce(0, +) > 0 {
                let phase = SVGValues.number(style["stroke-dashoffset"] ?? "0") ?? 0
                line = path.copy(dashingWithPhase: phase, lengths: lengths.map { CGFloat($0) })
            }
        }
        let scale = abs(context.transform.a * context.transform.d - context.transform.b * context.transform.c).squareRoot()
        var outline: CGPath
        var naturalWidth = width * scale
        if style["vector-effect"]?.lowercased() == "non-scaling-stroke" {
            naturalWidth = width * Self.millimetersPerPixel
            let placed = line.copy(using: [context.transform]) ?? line
            outline = placed.copy(strokingWithWidth: naturalWidth, lineCap: cap, lineJoin: join, miterLimit: miter)
        } else {
            outline = line.copy(strokingWithWidth: width, lineCap: cap, lineJoin: join, miterLimit: miter)
            outline = outline.copy(using: [context.transform]) ?? outline
        }
        outline = outline.normalized(using: .winding)
        var centerline = line.copy(using: [context.transform]) ?? line
        let unclipped = context.clips.isEmpty ? nil : outline
        for clip in context.clips {
            outline = outline.intersection(clip)
            centerline = centerline.lineIntersection(clip)
        }
        guard outline.hasSegments || centerline.hasSegments else { return }
        paints.append(SVGPaint(kind: .stroke, source: source, area: outline, centerline: centerline, strokeWidth: naturalWidth,
                               color: paint.color, layer: context.layer, clips: context.clips, unclipped: unclipped))
    }

    /// A paint's color: a color, `currentColor`, a gradient's first stop, or for anything else
    /// (a pattern) its fallback or a gray; nil for none.
    private mutating func color(_ text: String, style: SVGStyle) -> (color: SVGColor, alpha: Double)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower == "none" { return nil }
        if lower == "currentcolor" { return SVGValues.color(style["color"] ?? "black") }
        if let id = SVGValues.urlReference(text) {
            if let server = tree.byID[id] {
                if server.name.hasSuffix("Gradient"), let stop = firstStop(server) {
                    warnings.add("Gradients were brought in as one color each")
                    return stop
                }
                if server.name == "pattern" { warnings.add("Pattern fills were brought in as plain fills") }
            }
            if let fallback = SVGValues.urlFallback(text), let color = SVGValues.color(fallback) { return color }
            return tree.byID[id] == nil ? nil : (.gray, 1)
        }
        return SVGValues.color(text) ?? (lower == "black" ? (.black, 1) : nil)
    }

    private func firstStop(_ gradient: SVGNode, depth: Int = 0) -> (color: SVGColor, alpha: Double)? {
        let stops = gradient.elementChildren.filter { $0.name == "stop" }
        if let stop = stops.first {
            let style = SVGStyle(node: stop, parent: .initial, sheet: tree.sheet)
            let color = SVGValues.color(style["stop-color"] ?? "black") ?? (.black, 1)
            return (color.color, color.alpha * SVGValues.opacity(style["stop-opacity"]))
        }
        guard depth < 8, let id = gradient.reference, let next = tree.byID[id] else { return nil }
        return firstStop(next, depth: depth + 1)
    }

    // MARK: Clip paths

    /// A clip path's area, in millimeters, for an element painted with `context`.
    private mutating func clipPath(_ id: String, for node: SVGNode, style: SVGStyle, context: Context) -> CGPath? {
        guard let clip = tree.byID[id], clip.name == "clipPath" else { return nil }
        let clipStyle = SVGStyle(node: clip, parent: style, sheet: tree.sheet)
        var transform = (SVGValues.transform(clip["transform"]) ?? .identity).concatenating(context.transform)
        if clip["clipPathUnits"] == "objectBoundingBox" {
            guard SVGShapes.names.contains(node.name), let own = SVGShapes.path(for: node, viewport: context.viewport, fontSize: style.fontSize) else {
                warnings.add("A clip path sized to its group was ignored")
                return nil
            }
            let box = own.boundingBoxOfPath
            transform = CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY).concatenating(transform)
        }
        var result: CGPath?
        func add(_ element: SVGNode, parent: SVGStyle, transform: CGAffineTransform, depth: Int) {
            guard depth < 8 else { return }
            let elementStyle = SVGStyle(node: element, parent: parent, sheet: tree.sheet)
            guard elementStyle.isDisplayed, let own = SVGValues.transform(element["transform"]) else { return }
            let placed = own.concatenating(transform)
            if element.name == "use", let id = element.reference, let target = tree.byID[id] {
                let x = SVGValues.userLength(element["x"]) ?? 0, y = SVGValues.userLength(element["y"]) ?? 0
                add(target, parent: elementStyle, transform: CGAffineTransform(translationX: x, y: y).concatenating(placed), depth: depth + 1)
                return
            }
            if element.name == "text" {
                var ignored = SVGWarnings()
                for run in SVGText.runs(of: element, style: elementStyle, sheet: tree.sheet, viewport: context.viewport, warnings: &ignored) {
                    let area = (run.path.copy(using: [placed]) ?? run.path).normalized(using: .winding)
                    result = result.map { $0.union(area) } ?? area
                }
                return
            }
            guard SVGShapes.names.contains(element.name),
                  let path = SVGShapes.path(for: element, viewport: context.viewport, fontSize: elementStyle.fontSize) else { return }
            let area = (path.copy(using: [placed]) ?? path).normalized(using: elementStyle.clipRule)
            result = result.map { $0.union(area) } ?? area
        }
        for child in clip.elementChildren { add(child, parent: clipStyle, transform: transform, depth: 0) }
        // A clip path with nothing in it hides everything.
        return result ?? CGMutablePath()
    }

    // MARK: Images

    private mutating func image(_ node: SVGNode, style: SVGStyle, context: Context) {
        guard style.isVisible else { return }
        guard let href = node["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), href.lowercased().hasPrefix("data:") else {
            warnings.add("Pictures linked from other files were left out (only pictures inside the SVG can be traced)")
            return
        }
        guard let picture = Self.decodeImage(href) else {
            warnings.add("A picture inside the SVG could not be read")
            return
        }
        let natural = CGSize(width: picture.width, height: picture.height)
        let x = SVGValues.userLength(node["x"], reference: context.viewport.width) ?? 0
        let y = SVGValues.userLength(node["y"], reference: context.viewport.height) ?? 0
        let width = SVGValues.userLength(node["width"], reference: context.viewport.width) ?? natural.width
        let height = SVGValues.userLength(node["height"], reference: context.viewport.height) ?? natural.height
        guard width > 0, height > 0 else { return }
        // The picture's own box fitted into the image's, as its preserveAspectRatio says.
        let fit = SVGValues.viewBoxTransform(CGRect(origin: .zero, size: natural), into: CGRect(x: x, y: y, width: width, height: height),
                                             preserve: node["preserveAspectRatio"])
        let unit = CGAffineTransform(scaleX: natural.width, y: natural.height).concatenating(fit).concatenating(context.transform)
        paints.append(SVGPaint(kind: .image, source: .image, area: CGMutablePath(), color: .black, layer: context.layer,
                               image: picture, imageTransform: unit, clips: context.clips))
    }

    /// A `data:` URL's picture (PNG, JPEG, and the other kinds Image I/O reads).
    static func decodeImage(_ href: String) -> CGImage? {
        guard let comma = href.firstIndex(of: ",") else { return nil }
        let header = href[..<comma].lowercased()
        let payload = String(href[href.index(after: comma)...])
        let data: Data?
        if header.contains(";base64") {
            data = Data(base64Encoded: payload.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, data.count <= 64 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0,
              image.width * image.height <= 50_000_000 else { return nil }
        return image
    }
}
