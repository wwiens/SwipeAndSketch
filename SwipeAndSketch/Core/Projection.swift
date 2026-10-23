import Foundation
import simd

/// A curve in world millimeters, captured from a sketch or a solid for Project.
enum SpaceCurve: Equatable, Sendable {
    case segment(SIMD3<Double>, SIMD3<Double>)
    /// A full circle; `axis` is its unit normal.
    case circle(center: SIMD3<Double>, axis: SIMD3<Double>, radius: Double)
    /// A circular arc running right-handed about `axis` from `start` through `mid` to `end`.
    case arc(center: SIMD3<Double>, axis: SIMD3<Double>, start: SIMD3<Double>, mid: SIMD3<Double>, end: SIMD3<Double>)
    /// A sketch rectangle's four corners, in order.
    case rectangle([SIMD3<Double>])
    /// Points along any other curve.
    case polyline([SIMD3<Double>], closed: Bool)
}

/// Something picked to project (Project's Geometry): a sketch shape, a whole sketch, a
/// sketch region, a solid edge, a solid face (its edges), or a whole solid (every edge). Its
/// geometry is captured in world millimeters when it is picked, so it stays valid while the
/// projection is set up; nothing links the projection back to it afterwards.
struct ProjectionItem: Equatable, Sendable {
    enum Source: Hashable, Sendable { case shape(UUID), sketch(UUID), profile(String), edge(UUID, Int), face(UUID, Int), body(UUID) }
    var source: Source
    var curves: [SpaceCurve]
    /// Outlines of curved faces (a cylinder's sides), which depend on the projection direction.
    var silhouettes: KernelSilhouettes?

    /// Sketch shapes, each as drawn on its own plane.
    static func shapes(_ shapes: [SketchShape], source: Source) -> ProjectionItem {
        ProjectionItem(source: source, curves: shapes.filter { $0.isValid && $0.kind != .point }.map(Projection.curve(of:)))
    }

    /// One edge of a solid, by its index in the solid's current kernel shape.
    static func edge(_ edge: Int, of body: SolidBody) -> ProjectionItem? {
        guard let solid = try? SolidKernel.solid(for: body), (0..<solid.edgeCount).contains(edge),
              let curve = Projection.curve(of: solid, edge: edge) else { return nil }
        return ProjectionItem(source: .edge(body.id, edge), curves: [curve])
    }

    /// A face of a solid: every edge around it, and its outline if it is curved.
    static func face(_ face: Int, of body: SolidBody) -> ProjectionItem? {
        guard let solid = try? SolidKernel.solid(for: body), (0..<solid.faceCount).contains(face),
              let mesh = try? solid.tessellate() else { return nil }
        let edges = solid.faceEdges(face).filter { mesh.edges.indices.contains($0) && mesh.edges[$0].isBoundary }
        let silhouettes = KernelSilhouettes(mesh, faces: [face])
        return ProjectionItem(source: .face(body.id, face), curves: edges.compactMap { Projection.curve(of: solid, edge: $0) },
                              silhouettes: silhouettes.isEmpty ? nil : silhouettes)
    }

    /// A whole solid: every edge (seams left out) and the outlines of its curved faces.
    static func body(_ body: SolidBody) -> ProjectionItem? {
        guard let solid = try? SolidKernel.solid(for: body), let mesh = try? solid.tessellate() else { return nil }
        let edges = mesh.edges.indices.filter { mesh.edges[$0].isBoundary }
        let silhouettes = KernelSilhouettes(mesh)
        return ProjectionItem(source: .body(body.id), curves: edges.compactMap { Projection.curve(of: solid, edge: $0) },
                              silhouettes: silhouettes.isEmpty ? nil : silhouettes)
    }
}

/// Where Project casts items (Project's Target Plane): a flat face, a construction plane,
/// a world plane, or an existing sketch, whose shapes the projection then joins.
struct ProjectionTarget: Equatable, Sendable {
    enum Source: Hashable, Sendable { case face(UUID, Int), plane(UUID), world(SketchPlane), sketch(UUID) }
    var source: Source
    var plane: SketchPlane
    /// The sketch the projected shapes join; nil starts a new sketch on `plane`.
    var sketchID: UUID?
    /// Where to highlight the surface, in world millimeters.
    var outline: [SIMD3<Double>]

    /// An existing sketch: the projection joins it, on its plane.
    static func sketch(_ id: UUID, in workspace: Workspace) -> ProjectionTarget? {
        guard let sketch = workspace.sketch(id) else { return nil }
        let points = workspace.shapes(in: id).flatMap(\.outline)
        guard let first = points.first else { return nil }
        let low = points.reduce(first) { Point2(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
        let high = points.reduce(first) { Point2(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
        let margin = max(3, 0.1 * max(high.x - low.x, high.y - low.y))
        let corners = [Point2(x: low.x - margin, y: low.y - margin), Point2(x: high.x + margin, y: low.y - margin),
                       Point2(x: high.x + margin, y: high.y + margin), Point2(x: low.x - margin, y: high.y + margin)]
        return ProjectionTarget(source: .sketch(id), plane: sketch.plane, sketchID: id, outline: corners.map { sketch.plane.point($0) })
    }

    /// A flat face, construction plane, or world plane (a new sketch there), or a sketch region
    /// (its sketch).
    static func reference(_ reference: PlaneReference, in workspace: Workspace) -> ProjectionTarget? {
        switch reference.source {
        case .face(let body, let face):
            guard let plane = SketchPlane.through(reference.origin, normal: reference.normal) else { return nil }
            return ProjectionTarget(source: .face(body, face), plane: plane, outline: reference.outline)
        case .plane(let id):
            guard let construction = workspace.constructionPlanes.first(where: { $0.id == id }) else { return nil }
            return ProjectionTarget(source: .plane(id), plane: construction.plane, outline: reference.outline)
        case .world(let plane):
            return ProjectionTarget(source: .world(plane), plane: plane, outline: reference.outline)
        case .profile(let id):
            guard let sketch = workspace.sketches.first(where: { sketch in workspace.profiles(in: sketch).contains { $0.id == id } }) else { return nil }
            return .sketch(sketch.id, in: workspace)
        }
    }
}

/// Project (sketch projections): items are cast straight onto a plane along its normal and become
/// ordinary sketch shapes there. Lines stay lines, and circles and arcs facing the plane stay exact
/// circles and arcs; anything seen edge-on flattens to a line, and other curves (circles seen at an
/// angle, outlines of curved faces) become polylines. The result is a copy: it does not follow
/// later changes to what was projected.
enum Projection {
    /// More shapes than this from one projection is refused rather than flooding a sketch.
    static let maximumShapes = 2_000

    /// The shapes `items` cast onto `plane`. Duplicates (such as a solid's top and bottom outlines
    /// seen from above) are kept once, and so is anything that matches a shape in `existing`.
    /// Nil when there would be too many shapes.
    static func shapes(projecting items: [ProjectionItem], onto plane: SketchPlane, existing: [SketchShape] = []) -> [SketchShape]? {
        var result: [SketchShape] = []
        let existing = existing.filter { $0.plane == plane && $0.isValid }
        func add(_ shape: SketchShape) {
            guard shape.isValid, !result.contains(where: { isDuplicate($0, shape) }),
                  !existing.contains(where: { isDuplicate($0, shape) }) else { return }
            result.append(shape)
        }
        for item in items {
            for curve in item.curves {
                project(curve, onto: plane).forEach(add)
                if result.count > maximumShapes { return nil }
            }
            if let silhouettes = item.silhouettes {
                // Mesh points are single precision, so their outlines are straightened more loosely.
                let segments = silhouettes.segments(viewDirection: SIMD3<Float>(plane.normalAxis), tolerance: 1e-4).map {
                    (flat(SIMD3<Double>($0.0), on: plane), flat(SIMD3<Double>($0.1), on: plane))
                }
                for chain in chained(segments) {
                    polyline(chain, closed: false, plane: plane, tolerance: 1e-4).forEach(add)
                    if result.count > maximumShapes { return nil }
                }
            }
        }
        return result
    }

    /// One curve cast onto `plane`: none if it shrinks to a point, else one shape (four lines for a
    /// rectangle that is no longer square to the plane's axes).
    static func project(_ curve: SpaceCurve, onto plane: SketchPlane) -> [SketchShape] {
        let n = plane.normalAxis
        switch curve {
        case .segment(let a, let b):
            let p = flat(a, on: plane), q = flat(b, on: plane)
            return p.distance(to: q) >= 0.01 ? [SketchShape(kind: .line, plane: plane, start: p, end: q)] : []
        case .circle(let center, let axis, let radius):
            let c = flat(center, on: plane)
            if simd_length(simd_cross(axis, n)) < 1e-9 {
                return [SketchShape(kind: .circle, plane: plane, start: c, end: (c + Point2(x: radius, y: 0)).roundedOff())]
            }
            if abs(simd_dot(axis, n)) < 1e-9 {
                // Seen edge-on: a line across its diameter.
                let along = simd_normalize(simd_cross(axis, n)) * radius
                return project(.segment(center - along, center + along), onto: plane)
            }
            let u = simd_normalize(simd_cross(axis, n)), v = simd_cross(axis, u)
            let points = (0..<96).map { i -> SIMD3<Double> in
                let angle = Double(i) * 2 * .pi / 96
                return center + (u * cos(angle) + v * sin(angle)) * radius
            }
            return polyline(points.map { flat($0, on: plane) }, closed: true, plane: plane)
        case .arc(let center, let axis, let start, let mid, let end):
            if simd_length(simd_cross(axis, n)) < 1e-9 {
                // Facing the plane: an exact arc, counterclockwise in the plane's own coordinates.
                let c = flat(center, on: plane), s = flat(start, on: plane), e = flat(end, on: plane)
                let shape = simd_dot(axis, n) > 0 ? SketchShape.arc(center: c, from: s, to: e, plane: plane) :
                    SketchShape.arc(center: c, from: e, to: s, plane: plane)
                return [shape]
            }
            let points = arcPoints(center: center, axis: axis, start: start, end: end, through: mid)
            return polyline(points.map { flat($0, on: plane) }, closed: false, plane: plane)
        case .rectangle(let corners):
            let points = corners.map { flat($0, on: plane) }
            let xs = points.map(\.x), ys = points.map(\.y)
            // Still square to the plane's axes (two x and two y values, all four corners): still a rectangle.
            if points.count == 4, Set(xs).count == 2, Set(ys).count == 2, Set(points).count == 4 {
                let shape = SketchShape(kind: .rectangle, plane: plane, start: Point2(x: xs.min() ?? 0, y: ys.min() ?? 0),
                                        end: Point2(x: xs.max() ?? 0, y: ys.max() ?? 0))
                if shape.isValid { return [shape] }
            }
            return corners.indices.flatMap { project(.segment(corners[$0], corners[($0 + 1) % corners.count]), onto: plane) }
        case .polyline(let points, let closed):
            return polyline(points.map { flat($0, on: plane) }, closed: closed, plane: plane)
        }
    }

    /// A projected polyline: nothing if it shrinks to a point, a line if it lies along one (a curve
    /// seen edge-on), else a curve.
    static func polyline(_ points: [Point2], closed: Bool, plane: SketchPlane, tolerance: Double = 1e-6) -> [SketchShape] {
        var kept: [Point2] = []
        for point in points where kept.last.map({ $0.distance(to: point) >= 1e-7 }) ?? true { kept.append(point) }
        if closed, kept.count > 1, kept[0].distance(to: kept[kept.count - 1]) < 1e-7 { kept.removeLast() }
        guard let first = kept.first, let far = kept.max(by: { $0.distance(to: first) < $1.distance(to: first) }),
              let other = kept.max(by: { $0.distance(to: far) < $1.distance(to: far) }), far.distance(to: other) >= 0.01 else { return [] }
        if kept.allSatisfy({ Geometry.distance($0, toSegment: far, other) <= tolerance }) {
            return [SketchShape(kind: .line, plane: plane, start: far, end: other)]
        }
        if closed && kept.count < 3 { return [] }
        return [SketchShape.curve(kept, closed: closed, plane: plane)]
    }

    /// Where a world point lands on the plane, with kernel round-off (1e-16 mm) cleaned so
    /// endpoints shared by neighboring edges stay exactly shared.
    static func flat(_ point: SIMD3<Double>, on plane: SketchPlane) -> Point2 { plane.coordinates(of: point).roundedOff() }

    /// Points along an arc, every 3° at most, ends exact.
    static func arcPoints(center: SIMD3<Double>, axis: SIMD3<Double>, start: SIMD3<Double>, end: SIMD3<Double>,
                          through mid: SIMD3<Double>) -> [SIMD3<Double>] {
        let a = start - center, b = end - center
        var sweep = atan2(simd_dot(simd_cross(a, b), axis), simd_dot(a, b))
        if sweep <= 1e-12 { sweep += 2 * .pi }
        let count = max(2, Int((sweep / (.pi / 60)).rounded(.up)))
        return [start] + (1..<count).map { i in
            center + simd_quatd(angle: sweep * Double(i) / Double(count), axis: axis).act(a)
        } + [end]
    }

    /// The world curve a sketch shape traces.
    static func curve(of shape: SketchShape) -> SpaceCurve {
        let plane = shape.plane
        switch shape.kind {
        case .line: return .segment(plane.point(shape.start), plane.point(shape.end))
        case .circle: return .circle(center: plane.point(shape.start), axis: plane.normalAxis, radius: shape.start.distance(to: shape.end))
        case .rectangle: return .rectangle(shape.outline.map { plane.point($0) })
        case .arc:
            let outline = shape.outline
            return .arc(center: plane.point(shape.arcCenter ?? shape.start), axis: plane.normalAxis, start: plane.point(shape.start),
                        mid: plane.point(outline[outline.count / 2]), end: plane.point(shape.end))
        case .curve: return .polyline(shape.outline.map { plane.point($0) }, closed: shape.isClosed)
        // A slot projects through its outline (round ends every 3°).
        case .slot, .ellipse: return .polyline(shape.outline.map { plane.point($0) }, closed: true)
        case .point: return .polyline([plane.point(shape.start)], closed: false)
        }
    }

    /// A solid edge as an exact segment, circle, or arc where it is one, else points along it.
    static func curve(of solid: KernelSolid, edge: Int) -> SpaceCurve? {
        let samples = solid.edgeSamples(edge, count: 5)
        guard samples.count == 5 else { return nil }
        let start = samples[0], end = samples[4]
        let closed = simd_distance(start, end) < 1e-7
        let chord = end - start
        if !closed, simd_length(chord) > 1e-9,
           samples.allSatisfy({ simd_length(simd_cross($0 - start, chord)) / simd_length(chord) < 1e-9 }) {
            return .segment(start, end)
        }
        if let circle = solid.edgeCircle(edge) {
            let normal = simd_cross(samples[1] - circle.center, samples[2] - circle.center)
            guard simd_length(normal) > 1e-12 else { return nil }
            let axis = simd_normalize(normal)
            if closed { return .circle(center: circle.center, axis: axis, radius: circle.radius) }
            return .arc(center: circle.center, axis: axis, start: start, mid: samples[2], end: end)
        }
        let dense = solid.edgeSamples(edge, count: 65)
        guard dense.count == 65 else { return nil }
        return .polyline(closed ? Array(dense.dropLast()) : dense, closed: closed)
    }

    /// Whether two shapes on the same plane trace the same geometry.
    static func isDuplicate(_ a: SketchShape, _ b: SketchShape) -> Bool {
        guard a.plane == b.plane else { return false }
        let tolerance = 1e-6
        func same(_ p: Point2, _ q: Point2) -> Bool { p.distance(to: q) <= tolerance }
        switch (a.kind, b.kind) {
        case (.line, .line):
            return (same(a.start, b.start) && same(a.end, b.end)) || (same(a.start, b.end) && same(a.end, b.start))
        case (.circle, .circle):
            return same(a.start, b.start) && abs(a.start.distance(to: a.end) - b.start.distance(to: b.end)) <= tolerance
        case (.rectangle, .rectangle):
            let p = a.outline, q = b.outline
            return same(p[0], q[0]) && same(p[2], q[2])
        case (.line, .rectangle), (.rectangle, .line):
            // A line along a whole side of a rectangle adds nothing.
            let (line, rectangle) = a.kind == .line ? (a, b) : (b, a)
            let corners = rectangle.outline
            return corners.indices.contains { i in
                let side = SketchShape(kind: .line, plane: rectangle.plane, start: corners[i], end: corners[(i + 1) % 4])
                return isDuplicate(line, side)
            }
        case (.arc, .arc):
            guard let c = a.arcCenter, let d = b.arcCenter else { return false }
            return same(c, d) && same(a.start, b.start) && same(a.end, b.end)
        case (.curve, .curve):
            let p = a.outline, q = b.outline
            guard a.isClosed == b.isClosed, p.count == q.count else { return false }
            if a.isClosed { return p.allSatisfy { point in q.contains { same($0, point) } } }
            return zip(p, q).allSatisfy(same) || zip(p, q.reversed()).allSatisfy(same)
        default: return false
        }
    }

    /// Joins segments that share ends into polylines (open chains first, then loops).
    static func chained(_ segments: [(Point2, Point2)]) -> [[Point2]] {
        struct Key: Hashable { var x, y: Int64 }
        func key(_ p: Point2) -> Key { Key(x: Int64((p.x * 1e4).rounded()), y: Int64((p.y * 1e4).rounded())) }
        let segments = segments.filter { $0.0.distance(to: $0.1) > 1e-7 }
        var ends: [Key: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            ends[key(segment.0), default: []].append(index)
            ends[key(segment.1), default: []].append(index)
        }
        var used = Set<Int>()
        var chains: [[Point2]] = []
        func walk(from index: Int, reversed: Bool) -> [Point2] {
            var points = reversed ? [segments[index].1, segments[index].0] : [segments[index].0, segments[index].1]
            used.insert(index)
            while let next = ends[key(points[points.count - 1])]?.first(where: { !used.contains($0) }) {
                used.insert(next)
                let segment = segments[next]
                points.append(key(segment.0) == key(points[points.count - 1]) ? segment.1 : segment.0)
            }
            return points
        }
        // Start at loose ends, so each open chain is walked from one end to the other.
        for index in segments.indices where !used.contains(index) {
            if ends[key(segments[index].0)]?.count == 1 { chains.append(walk(from: index, reversed: false)) }
            else if ends[key(segments[index].1)]?.count == 1 { chains.append(walk(from: index, reversed: true)) }
        }
        for index in segments.indices where !used.contains(index) { chains.append(walk(from: index, reversed: false)) }
        return chains
    }
}

extension Workspace {
}

extension SolidBody {
    var usesProfileArcs: Bool {
        profile.arcs != nil || cuts.contains { $0.profile.arcs != nil || ($0.nestedSolid?.usesProfileArcs ?? false) }
    }
}
