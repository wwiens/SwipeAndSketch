import Foundation
import CoreGraphics
import Compression

// SVG import: a vector drawing (a logo, icon, sign, or cut file) brought in as editable sketches,
// and optionally as solids, one per color, ready for a multicolor print.
//
// 1. `read` parses the file (SVGDocument.swift) and paints it into areas in millimeters
//    (SVGRender.swift): fills with their fill rules, strokes as outlines and center lines, clip
//    paths, text as letter outlines in the fonts this device has (SVGText.swift), and pictures,
//    which are traced later (ImageTracing.swift). Hidden things are left out.
// 2. `layout` sizes and places that drawing for the chosen options, groups it into sketches (one,
//    one per layer, or one per color, colors covering what they are painted over), and fits its
//    curves to lines, arcs, and circles (CurveFitting.swift).
// 3. `adding` puts the sketches (and solids) into a new Model Tree group, in one change.
//
// Nothing changes in the project file: the sketches hold only lines, arcs, and circles.

enum SVGImport {
    static let maximumFileBytes = 50 * 1024 * 1024
    /// Shapes one import may add (a project holds 10,000).
    static let maximumShapes = 5_000

    /// A read drawing, before it is sized and placed.
    struct Drawing: @unchecked Sendable {
        var name: String
        var painting: SVGPainting
        /// What is drawn, in millimeters as the file sizes it (96 pixels to the inch when it gives
        /// no real units).
        var bounds: CGRect
        var colors: [SVGColor]
        var hasPhysicalSize: Bool { painting.hasPhysicalSize }
        var hasImages: Bool { painting.paints.contains { $0.kind == .image } }
        var hasStrokes: Bool { painting.paints.contains { $0.kind == .stroke } }
        var hasText: Bool { painting.paints.contains { $0.source == .text } }
        var layerCount: Int { painting.layers.count }
        var warnings: SVGWarnings { painting.warnings }
    }

    enum Grouping: String, CaseIterable, Sendable {
        /// One sketch.
        case single
        /// One sketch per layer (top-level group).
        case layers
        /// One sketch per color, each color less what is painted over it.
        case colors
        var title: String {
            switch self { case .single: "One Sketch"; case .layers: "By Layer"; case .colors: "By Color" }
        }
    }

    enum Strokes: String, CaseIterable, Sendable {
        /// Thin strokes (cut lines, hairlines) as their center lines; wider ones as outlines.
        case auto
        /// Every stroke as the outline of its width.
        case outline
        /// Every stroke as the line it runs along.
        case centerline
        var title: String {
            switch self { case .auto: "Auto"; case .outline: "Outline"; case .centerline: "Center Line" }
        }
    }

    enum Detail: String, CaseIterable, Sendable {
        case fine, standard, coarse
        /// How far fitted curves may stray from the drawing's, in millimeters.
        var tolerance: Double {
            switch self { case .fine: 0.005; case .standard: 0.02; case .coarse: 0.1 }
        }
        var title: String { rawValue.capitalized }
        var coarser: Detail? {
            switch self { case .fine: .standard; case .standard: .coarse; case .coarse: nil }
        }
    }

    /// Strokes thinner than this (millimeters, as imported) are center lines in `Strokes.auto`.
    static let hairline = 0.2

    struct Options: Equatable, Sendable {
        /// The width of what is drawn, in millimeters; its height follows.
        var width: Double
        var grouping: Grouping = .single
        var strokes: Strokes = .auto
        var detail: Detail = .standard
        var traceImages = true
        var tracing = ImageTracing.Options()
        /// The drawing's middle on the placement's center, or the file's own origin there.
        var keepFilePosition = false
        /// Solids this tall (millimeters) are made too, one per region of each color.
        var solidHeight: Double?
        /// White parts make no solids (they are the background of a sign or a logo).
        var leaveOutWhite = true
        /// A white rectangle behind everything is the page, not part of the design.
        var leaveOutBackground = true
    }

    /// Where the drawing goes: a plane, and the point on it the drawing is centered on.
    struct Placement: Equatable, Sendable {
        var plane: SketchPlane
        var center: Point2 = .zero
    }

    struct Layout: @unchecked Sendable {
        struct SketchPart {
            var name: String
            var shapes: [SketchShape]
        }
        struct SolidPart {
            var name: String
            var profile: SketchProfile
            var color: BodyColor?
        }
        var sketches: [SketchPart]
        var solids: [SolidPart]
        var placement: Placement
        var warnings: SVGWarnings
        /// The size the drawing comes in at, in millimeters.
        var size: CGSize
        var detail: Detail
        /// How tall the solids are (nil without solids).
        var solidHeight: Double?
        /// Open paths kept as open sketch lines (they bound no region).
        var openPaths: Int
        var shapeCount: Int { sketches.reduce(0) { $0 + $1.shapes.count } }
        /// The drawing's outlines as placed, for a preview: each sketch's shapes.
        var isEmpty: Bool { shapeCount == 0 }
    }

    // MARK: Reading

    static func read(_ url: URL, name: String) throws -> Drawing {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumFileBytes {
            throw SolidKernel.Failure(message: "This SVG file is too large to import (over \(maximumFileBytes / 1_048_576) MB).")
        }
        return try read(data: Data(contentsOf: url), name: name)
    }

    /// Reads SVG markup (or gzip-compressed SVG, `.svgz`).
    static func read(data: Data, name: String) throws -> Drawing {
        guard data.count <= maximumFileBytes else {
            throw SolidKernel.Failure(message: "This SVG file is too large to import (over \(maximumFileBytes / 1_048_576) MB).")
        }
        let markup = data.starts(with: [0x1F, 0x8B]) ? try gunzip(data) : data
        let tree = try SVGTree.parse(markup)
        let painting = try SVGRenderer.paint(tree)
        let bounds = painting.paints.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !bounds.isNull, bounds.width > 0 || bounds.height > 0 else {
            throw SolidKernel.Failure(message: "This SVG drawing has nothing in it that can become a sketch.")
        }
        var colors: [SVGColor] = []
        for paint in painting.paints where !colors.contains(where: { $0.distance(to: paint.color) < colorTolerance }) { colors.append(paint.color) }
        return Drawing(name: name, painting: painting, bounds: bounds, colors: colors)
    }

    /// Colors closer than this count as one (anti-aliasing and rounding in drawing programs).
    static let colorTolerance = 0.03

    /// A `.svgz` file's SVG: gzip's header and trailer around raw DEFLATE data.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let failure = SolidKernel.Failure(message: "This compressed SVG file could not be read.")
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw failure }
        let flags = bytes[3]
        var index = 10
        if flags & 4 != 0 {
            guard index + 2 <= bytes.count else { throw failure }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for flag in [UInt8(8), 16] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 2 != 0 { index += 2 }
        guard index < bytes.count - 8 else { throw failure }
        let capacity = maximumFileBytes * 2
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            bytes[index..<(bytes.count - 8)].withUnsafeBufferPointer { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw failure }
        guard written < capacity else { throw SolidKernel.Failure(message: "This SVG file is too large to import.") }
        return output.prefix(written)
    }

    /// The options a drawing starts with: its own size, one sketch per color when it has several
    /// (one sketch otherwise), and solids off.
    static func defaultOptions(for drawing: Drawing) -> Options {
        Options(width: max(0.1, Double(drawing.bounds.width)), grouping: drawing.colors.count > 1 ? .colors : .single)
    }

    // MARK: Layout

    private struct Item {
        enum Geometry {
            case area(CGPath), line(CGPath)
            var areaPath: CGPath? { if case .area(let path) = self { path } else { nil } }
            var linePath: CGPath? { if case .line(let path) = self { path } else { nil } }
        }
        var geometry: Geometry
        var color: Int
        var layer: Int?
        var bounds: CGRect
    }

    /// The drawing sized, placed, grouped into sketches, and fitted, for `options`. When it would
    /// make more shapes than an import takes, coarser detail is tried before giving up.
    static func layout(_ drawing: Drawing, options: Options, placement: Placement) throws -> Layout {
        var detail = options.detail
        while true {
            var attempt = options
            attempt.detail = detail
            var layout = try layoutOnce(drawing, options: attempt, placement: placement)
            if layout.shapeCount <= maximumShapes {
                if detail != options.detail { layout.warnings.add("The drawing was too detailed for \(options.detail.title) detail; it uses \(detail.title)") }
                return layout
            }
            guard let next = detail.coarser else {
                throw SolidKernel.Failure(message: "This drawing has more shapes than an import can take (\(layout.shapeCount); at most \(maximumShapes)). Simplify it, or import part of it.")
            }
            detail = next
        }
    }

    private static func layoutOnce(_ drawing: Drawing, options: Options, placement: Placement) throws -> Layout {
        let bounds = drawing.bounds
        guard options.width.isFinite, options.width > 0, bounds.width > 0 || bounds.height > 0 else {
            throw SolidKernel.Failure(message: "Give the drawing a size first.")
        }
        let scale = bounds.width > 0 ? options.width / Double(bounds.width) : options.width / Double(bounds.height)
        let origin = options.keepFilePosition ? drawing.painting.origin : CGPoint(x: bounds.midX, y: bounds.midY)
        let place = CGAffineTransform(translationX: -origin.x, y: -origin.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: placement.center.x, y: placement.center.y))
        let size = CGSize(width: Double(bounds.width) * scale, height: Double(bounds.height) * scale)
        let farthest = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY)].map { $0.applying(place) }
        guard farthest.allSatisfy({ abs($0.x) <= 50_000 && abs($0.y) <= 50_000 }) else {
            throw SolidKernel.Failure(message: "At that size the drawing is too large for a sketch.")
        }
        let tolerance = options.detail.tolerance
        let gap = max(0.05, 0.001 * max(size.width, size.height))
        var warnings = drawing.warnings

        // What each paint leaves, placed in sketch millimeters.
        let colors = drawing.colors
        func colorIndex(_ color: SVGColor) -> Int { colors.firstIndex { $0.distance(to: color) < colorTolerance } ?? 0 }
        var items: [Item] = []
        var traced = 0
        for paint in drawing.painting.paints {
            switch paint.kind {
            case .fill:
                let area = paint.area.copy(using: [place]) ?? paint.area
                items.append(Item(geometry: .area(area), color: colorIndex(paint.color), layer: paint.layer, bounds: area.boundingBoxOfPath))
            case .stroke:
                let asLine = options.strokes == .centerline || options.strokes == .auto && paint.strokeWidth * scale < hairline
                if asLine, let line = paint.centerline {
                    let placed = line.copy(using: [place]) ?? line
                    items.append(Item(geometry: .line(placed), color: colorIndex(paint.color), layer: paint.layer, bounds: placed.boundingBoxOfPath))
                } else {
                    let area = paint.area.copy(using: [place]) ?? paint.area
                    items.append(Item(geometry: .area(area), color: colorIndex(paint.color), layer: paint.layer, bounds: area.boundingBoxOfPath))
                }
            case .image:
                guard options.traceImages, let image = paint.image else { continue }
                guard let unit = ImageTracing.trace(image, options: options.tracing) else {
                    warnings.add("A picture had nothing to trace at this threshold")
                    continue
                }
                var area = unit.copy(using: [paint.imageTransform]) ?? unit
                for clip in paint.clips { area = area.intersection(clip) }
                area = area.copy(using: [place]) ?? area
                guard area.hasSegments else { continue }
                traced += 1
                items.append(Item(geometry: .area(area), color: colorIndex(paint.color), layer: paint.layer, bounds: area.boundingBoxOfPath))
            }
        }
        if drawing.hasImages && !options.traceImages { warnings.add("Pictures were left out (tracing is off)") }

        // A white rectangle under everything else is the page.
        if options.leaveOutBackground, items.count > 1, case .area = items[0].geometry, colors[items[0].color].isWhite {
            let others = items.dropFirst().reduce(CGRect.null) { $0.union($1.bounds) }
            if items[0].bounds.insetBy(dx: -0.01, dy: -0.01).contains(others) {
                items.removeFirst()
                warnings.add("The white background was left out")
            }
        }

        // Colors in the order the drawing first paints them (the page left out).
        var order: [Int] = []
        for item in items where !order.contains(item.color) { order.append(item.color) }

        func colorName(_ index: Int) -> String {
            let color = colors[index]
            let name = nearestBodyColor(color).title
            let shared = colors.indices.filter { nearestBodyColor(colors[$0]) == nearestBodyColor(color) }
            return shared.count > 1 ? "\(name) \(color.hex)" : name
        }

        // Each color's visible area: what it paints less what other colors paint over it. For
        // solids, closed center lines (cut outlines) enclose what they outline too.
        func flatten(closedLines: Bool) -> [[CGPath]] {
            var visible: [[CGPath]] = Array(repeating: [], count: colors.count)
            var above: [(area: CGPath, bounds: CGRect, color: Int)] = []
            for item in items.reversed() {
                var area: CGPath
                switch item.geometry {
                case .area(let path): area = path
                case .line(let path):
                    guard closedLines, let closed = closedArea(path, gap: gap) else { continue }
                    area = closed
                }
                let own = area
                let covering = above.filter { $0.color != item.color && $0.bounds.intersects(item.bounds) }
                if !covering.isEmpty { area = area.subtracting(combined(covering.map(\.area))) }
                if area.hasSegments { visible[item.color].append(area) }
                above.append((own, item.bounds, item.color))
            }
            return visible
        }

        var parts: [Layout.SketchPart] = []
        var openPaths = 0
        func fitted(_ areas: [CGPath], lines: [CGPath]) -> [SketchShape] {
            var loops: [CurveFitting.Loop] = []
            if !areas.isEmpty { loops += CurveFitting.loops(of: combined(areas), tolerance: tolerance, gap: nil) }
            for line in lines {
                let fitted = CurveFitting.loops(of: line, tolerance: tolerance, gap: gap)
                openPaths += fitted.filter { !$0.closed }.count
                loops += fitted
            }
            return deduplicated(CurveFitting.shapes(loops, plane: placement.plane))
        }
        func part(_ name: String, _ selected: [Item]) {
            // Each color's areas joined, so overlapping pieces of one color make no slivers.
            var shapes: [SketchShape] = []
            for color in order {
                let ofColor = selected.filter { $0.color == color }
                guard !ofColor.isEmpty else { continue }
                shapes += fitted(ofColor.compactMap(\.geometry.areaPath), lines: ofColor.compactMap(\.geometry.linePath))
            }
            if !shapes.isEmpty { parts.append(Layout.SketchPart(name: name, shapes: deduplicated(shapes))) }
        }

        switch options.grouping {
        case .single:
            part(drawing.name, items)
        case .layers:
            let layers = drawing.painting.layers
            part(drawing.name, items.filter { $0.layer == nil })
            for (index, name) in layers.enumerated() { part(name, items.filter { $0.layer == index }) }
        case .colors:
            let visible = flatten(closedLines: false)
            for color in order {
                let lines = items.filter { $0.color == color }.compactMap(\.geometry.linePath)
                let shapes = fitted(visible[color], lines: lines)
                if !shapes.isEmpty { parts.append(Layout.SketchPart(name: colorName(color), shapes: shapes)) }
            }
        }

        // Solids: each color's visible regions.
        var solids: [Layout.SolidPart] = []
        if let height = options.solidHeight {
            guard height.isFinite, abs(height) >= 0.01, abs(height) <= 10_000 else { throw SolidKernel.Failure(message: "Give the solids a height.") }
            let visible = flatten(closedLines: true)
            let keep = order.filter { !visible[$0].isEmpty }
            let leaveOut = options.leaveOutWhite && keep.contains { !colors[$0].isWhite }
            var skipped = 0
            for color in keep where !(leaveOut && colors[color].isWhite) {
                let area = combined(visible[color])
                let loops = CurveFitting.loops(of: area, tolerance: tolerance, gap: nil)
                let shapes = CurveFitting.shapes(loops, plane: placement.plane)
                for profile in Geometry.profiles(in: shapes, on: placement.plane) {
                    let anchor = profile.anchor
                    guard area.contains(CGPoint(x: anchor.x, y: anchor.y), using: .winding) else { continue }
                    guard profile.isSolidProfile, ProjectCodec.polygonWork(of: profile) != nil else { skipped += 1; continue }
                    solids.append(Layout.SolidPart(name: colorName(color), profile: profile, color: bodyColor(colors[color])))
                }
            }
            if skipped > 0 { warnings.add("Regions too detailed or too thin for a solid were left as sketches", count: skipped) }
            if options.leaveOutWhite && leaveOut && keep.contains(where: { colors[$0].isWhite }) { warnings.add("White areas made no solids") }
        }

        if openPaths > 0 { warnings.add("Open paths were kept as lines; they bound no region (use Strokes: Outline to make them solid)", count: openPaths) }
        if traced > 0 { warnings.add("Pictures were traced into outlines; check their shapes", count: traced) }
        return Layout(sketches: parts, solids: solids, placement: placement, warnings: warnings, size: size, detail: options.detail,
                      solidHeight: options.solidHeight, openPaths: openPaths)
    }

    /// Paths filled together as one (each already has its holes where its own fill rule put them).
    static func combined(_ paths: [CGPath]) -> CGPath {
        guard paths.count > 1 else { return paths.first ?? CGMutablePath() }
        let all = CGMutablePath()
        for path in paths { all.addPath(path) }
        return all.normalized(using: .winding)
    }

    /// What a line's closed loops enclose (the inside of a cut outline); nil when none close.
    private static func closedArea(_ line: CGPath, gap: Double) -> CGPath? {
        let path = CGMutablePath()
        let subpaths = CurveFitting.joined(CurveFitting.subpaths(of: line).compactMap { CurveFitting.cleaned($0, minimum: CurveFitting.shortest, gap: gap) }, gap: gap)
        for subpath in subpaths where subpath.closed {
            func p(_ point: Point2) -> CGPoint { CGPoint(x: point.x, y: point.y) }
            path.move(to: p(subpath.start))
            for segment in subpath.segments {
                switch segment {
                case .line(_, let b): path.addLine(to: p(b))
                case .cubic(_, let c1, let c2, let b): path.addCurve(to: p(b), control1: p(c1), control2: p(c2))
                }
            }
            path.closeSubpath()
        }
        return path.hasSegments ? path.normalized(using: .evenOdd) : nil
    }

    /// Shapes drawn twice (the same outline painted by two elements) kept once.
    static func deduplicated(_ shapes: [SketchShape]) -> [SketchShape] {
        var seen = Set<String>()
        func key(_ shape: SketchShape) -> String {
            func r(_ p: Point2) -> String { String(format: "%.5f,%.5f", p.x, p.y) }
            let ends = [r(shape.start), r(shape.end)]
            let center = shape.arcCenter.map(r) ?? ""
            return "\(shape.kind.rawValue)|\(shape.kind == .arc ? ends.joined(separator: ";") : ends.sorted().joined(separator: ";"))|\(center)"
        }
        return shapes.filter { seen.insert(key($0)).inserted }
    }

    static func nearestBodyColor(_ color: SVGColor) -> BodyColor {
        BodyColor.allCases.min { a, b in
            SVGColor(red: a.rgb.red, green: a.rgb.green, blue: a.rgb.blue).distance(to: color) <
                SVGColor(red: b.rgb.red, green: b.rgb.green, blue: b.rgb.blue).distance(to: color)
        } ?? .gray
    }

    /// A solid's color for a drawing's color: the nearest the app has (gray, the default, is left unset).
    static func bodyColor(_ color: SVGColor) -> BodyColor? {
        let nearest = nearestBodyColor(color)
        return nearest == .gray ? nil : nearest
    }

    // MARK: Into the workspace

    /// The workspace with the drawing's sketches (and solids) added in a new Model Tree group
    /// named after the file, and that group's id; nil when it would be invalid or too large.
    /// Solids of one color share a group of their own when there are several. With solids, the
    /// sketches they came from are hidden.
    static func adding(_ layout: Layout, name: String, to workspace: Workspace) -> (workspace: Workspace, group: UUID)? {
        guard !layout.isEmpty || !layout.solids.isEmpty else { return nil }
        let byColor = Dictionary(grouping: layout.solids.indices, by: { layout.solids[$0].name })
        let subgroups = byColor.values.filter { $0.count > 1 }.count
        guard workspace.groups.count + 1 + subgroups <= Workspace.maximumGroups else { return nil }
        var next = workspace
        let group = ItemGroup(name: ItemNames.cleaned(name) ?? "Drawing")
        next.groups.append(group)
        for part in layout.sketches {
            let id = UUID()
            next.sketches.append(Sketch(id: id, plane: layout.placement.plane, hidden: layout.solids.isEmpty ? nil : true,
                                        name: ItemNames.cleaned(part.name), group: group.id))
            next.shapes += part.shapes.map { var shape = $0; shape.sketch = id; return shape }
        }
        var colorGroups: [String: UUID] = [:]
        for solid in layout.solids {
            var body = SolidBody(profile: solid.profile, depth: 0)
            body.depth = layout.solidHeight ?? 1
            body.name = ItemNames.cleaned(solid.name)
            body.color = solid.color
            if (byColor[solid.name]?.count ?? 0) > 1 {
                if colorGroups[solid.name] == nil {
                    let sub = ItemGroup(name: ItemNames.cleaned(solid.name), parent: group.id)
                    next.groups.append(sub)
                    colorGroups[solid.name] = sub.id
                }
                body.group = colorGroups[solid.name]
            } else {
                body.group = group.id
            }
            next.bodies.append(body)
        }
        guard next.isValid, (try? ProjectCodec.checkSize(next)) != nil else { return nil }
        return (next, group.id)
    }
}
