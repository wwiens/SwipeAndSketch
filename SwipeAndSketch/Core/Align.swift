import Foundation
import simd

/// Something Align lines up, in world millimeters (the From and To picks): a flat face or
/// plane, a circle (circular edge or sketch circle), a straight line (edge or sketch line), or a
/// point (a solid's corner, a sketch point, or the origin).
struct AlignFeature: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case plane, circle, line, point }
    enum Source: Hashable, Sendable {
        case face(UUID, Int), edge(UUID, Int), plane(UUID), world(SketchPlane), shape(UUID), profile(String)
        /// A corner of a solid, and a point of a sketch shape (both by where they are), and the origin.
        case vertex(UUID, SIMD3<Double>), sketchPoint(UUID, SIMD3<Double>), origin
    }
    var kind: Kind
    var source: Source
    /// A face's center, a circle's center, a line's midpoint, or the point itself.
    var point: SIMD3<Double>
    /// A plane's normal (out of a face), a circle's axis, or a line's direction; unit length. Points
    /// have no direction (+Z is stored).
    var direction: SIMD3<Double>
    /// What to highlight.
    var outline: [SIMD3<Double>]

    /// A flat face, construction plane, world plane, or sketch region.
    static func plane(_ reference: PlaneReference) -> AlignFeature {
        let source: Source = switch reference.source {
        case .face(let body, let face): .face(body, face)
        case .plane(let id): .plane(id)
        case .world(let plane): .world(plane)
        case .profile(let id): .profile(id)
        }
        return AlignFeature(kind: .plane, source: source, point: reference.origin, direction: simd_normalize(reference.normal), outline: reference.outline)
    }

    /// A solid edge that is a full circle (or arc) or a straight line; nil for other curves.
    static func edge(_ edge: Int, of body: SolidBody) -> AlignFeature? {
        guard let solid = try? SolidKernel.solid(for: body), (0..<solid.edgeCount).contains(edge),
              let curve = Projection.curve(of: solid, edge: edge) else { return nil }
        return feature(curve, source: .edge(body.id, edge))
    }

    /// A point: Align moves the From point onto the To point, without turning.
    static func point(_ point: SIMD3<Double>, source: Source) -> AlignFeature {
        AlignFeature(kind: .point, source: source, point: point, direction: SIMD3(0, 0, 1), outline: [point])
    }

    /// The corners of a solid: the ends of its visible edges (not seams, and not closed edges such
    /// as a cylinder's rim, whose single vertex is not a corner), each once.
    static func corners(of body: SolidBody) -> [SIMD3<Double>] {
        guard let solid = try? SolidKernel.solid(for: body), let mesh = try? solid.tessellate() else { return [] }
        return corners(of: solid, edges: mesh.edges.indices.filter { mesh.edges[$0].isBoundary })
    }

    static func corners(of solid: KernelSolid, edges: [Int]) -> [SIMD3<Double>] {
        var result: [SIMD3<Double>] = [], seen = DistinctPoints()
        for edge in edges {
            let ends = solid.edgeSamples(edge, count: 2)
            guard ends.count == 2, simd_distance(ends[0], ends[1]) > 1e-6 else { continue }
            for end in ends where seen.insert(end) { result.append(end) }
        }
        return result
    }

    /// A sketch shape's points: line and arc ends, rectangle corners, and circle and arc centers.
    static func points(of shape: SketchShape) -> [SIMD3<Double>] {
        guard shape.isValid else { return [] }
        let flat: [Point2]
        switch shape.kind {
        case .line: flat = [shape.start, shape.end]
        case .rectangle: flat = Array(shape.outline.prefix(4))
        case .circle: flat = [shape.start]
        case .arc: flat = [shape.start, shape.end] + (shape.arcCenter.map { [$0] } ?? [])
        case .curve: flat = shape.isClosed ? [] : [shape.outline.first, shape.outline.last].compactMap { $0 }
        case .slot: flat = [shape.start, shape.end]
        case .ellipse, .point: flat = [shape.start]
        }
        return flat.map { shape.plane.point($0) }
    }

    /// A sketch line or circle (or arc).
    static func shape(_ shape: SketchShape) -> AlignFeature? {
        guard [.line, .circle, .arc].contains(shape.kind), shape.isValid else { return nil }
        return feature(Projection.curve(of: shape), source: .shape(shape.id))
    }

    private static func feature(_ curve: SpaceCurve, source: Source) -> AlignFeature? {
        switch curve {
        case .segment(let a, let b):
            guard simd_distance(a, b) > 1e-9 else { return nil }
            return AlignFeature(kind: .line, source: source, point: (a + b) / 2, direction: simd_normalize(b - a), outline: [a, b])
        case .circle(let center, let axis, let radius):
            let u = simd_normalize(simd_cross(axis, abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0))), v = simd_cross(axis, u)
            let ring = (0..<72).map { center + (u * cos(Double($0) * .pi / 36) + v * sin(Double($0) * .pi / 36)) * radius }
            return AlignFeature(kind: .circle, source: source, point: center, direction: axis, outline: ring)
        case .arc(let center, let axis, let start, let mid, let end):
            return AlignFeature(kind: .circle, source: source, point: center, direction: axis,
                                outline: Projection.arcPoints(center: center, axis: axis, start: start, end: end, through: mid))
        case .rectangle, .polyline: return nil
        }
    }

    /// Plane targets without a center of their own (world and construction planes, sketch
    /// regions) keep the moving solid where it is in the plane; faces center on each other.
    var centers: Bool {
        switch source { case .world, .plane: false; default: true }
    }
}

/// Align: the rigid motion that brings a feature of the moving
/// solids onto a target. Flat to flat meets face to face (normals opposite), centered on a face
/// target; circle to circle is concentric; line to line is collinear, midpoint to midpoint; point to
/// point moves without turning.
/// `flip` turns the result over (flat faces flush the same way, circles and lines reversed),
/// `offset` moves along the target's normal or axis, and `angle` turns about it.
enum Aligning {
    static func transform(from source: AlignFeature, to target: AlignFeature, flip: Bool = false,
                          offset: Double = 0, angle: Double = 0) -> RigidTransform? {
        guard source.kind == target.kind, offset.isFinite, angle.isFinite else { return nil }
        // Point to point only moves: the From point lands on the To point.
        if target.kind == .point { return .move(target.point - source.point) }
        let t = simd_normalize(target.direction), s = simd_normalize(source.direction)
        var wanted: SIMD3<Double>
        switch target.kind {
        case .plane: wanted = -t
        case .circle, .line, .point: wanted = simd_dot(s, t) >= 0 ? t : -t   // the shorter turn
        }
        if flip { wanted = -wanted }
        let turn = rotation(from: s, to: wanted)
        let spin = simd_quatd(angle: angle * .pi / 180, axis: t)
        var anchor = target.point
        if target.kind == .plane && !target.centers {
            // Onto the plane, staying where it is along it.
            anchor = source.point - t * simd_dot(source.point - target.point, t)
        }
        let goal = anchor + t * offset
        return RigidTransform(rotation: spin * turn, pivot: source.point, translation: goal - source.point)
    }

    /// The shortest rotation taking unit vector `a` to unit vector `b`.
    static func rotation(from a: SIMD3<Double>, to b: SIMD3<Double>) -> simd_quatd {
        let d = simd_dot(a, b)
        if d > 1 - 1e-12 { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        if d < -1 + 1e-12 {
            // Half a turn about any axis square to `a`.
            let other: SIMD3<Double> = abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            return simd_quatd(angle: .pi, axis: simd_normalize(simd_cross(a, other)))
        }
        return simd_quatd(from: a, to: b)
    }

    /// The workspace with `bodies` moved by `transform`; nil if any no longer builds.
    static func moving(_ bodies: [UUID], in workspace: Workspace, by transform: RigidTransform) -> Workspace? {
        var result = workspace
        for id in bodies {
            guard let index = result.bodies.firstIndex(where: { $0.id == id }),
                  let moved = result.bodies[index].transformed(by: transform) else { return nil }
            result.bodies[index] = moved
        }
        guard result.isValid, result.bodies.allSatisfy({ !bodies.contains($0.id) || (try? SolidKernel.solid(for: $0)) != nil }) else { return nil }
        return result
    }
}

/// Points kept once each: one within `tolerance` of a point already added is a repeat. Lookups go
/// through a grid, so an imported part's tens of thousands of corners don't each search them all.
struct DistinctPoints {
    let tolerance: Double
    private var cells: [SIMD3<Int>: [SIMD3<Double>]] = [:]

    init(tolerance: Double = 1e-6) { self.tolerance = tolerance }

    /// Adds `point` unless it repeats one already added, and says whether it was added.
    mutating func insert(_ point: SIMD3<Double>) -> Bool {
        let scaled = point / tolerance
        // Too far out for the grid (or not a number): compared with nothing, like a new point.
        guard all(simd_abs(scaled) .< 1e15) else { return true }
        let cell = SIMD3<Int>(scaled.rounded(.down))
        for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
            if cells[cell &+ SIMD3(dx, dy, dz)]?.contains(where: { simd_distance($0, point) < tolerance }) == true { return false }
        } } }
        cells[cell, default: []].append(point)
        return true
    }
}
