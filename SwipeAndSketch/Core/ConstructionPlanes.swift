import Foundation
import simd

/// A construction plane, made with Offset Plane or Midplane (schema 9). The plane is infinite; the
/// `width` × `height` rectangle centered on `plane.origin` (along its axes) is only how it is drawn
/// and picked. It is a fixed frame: it does not follow the face it was made from.
struct ConstructionPlane: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var plane: SketchPlane
    var width: Double
    var height: Double
    /// Hidden from the canvas. Omitted when visible.
    var hidden: Bool?
    /// The name chosen in the Model Tree (Naming.swift). Omitted when unset.
    var name: String?
    /// The Model Tree group it sits in (Groups.swift). Omitted at the top of the tree.
    var group: UUID?
    var isHidden: Bool { hidden == true }

    var isValid: Bool {
        ItemNames.isValid(name) && plane.isValid && [width, height].allSatisfy { $0.isFinite && $0 >= 0.1 && $0 <= 100_000 }
    }

    /// The drawn rectangle's corners, in the plane's coordinates.
    var outline: [Point2] {
        let w = width / 2, h = height / 2
        return [Point2(x: -w, y: -h), Point2(x: w, y: -h), Point2(x: w, y: h), Point2(x: -w, y: h)]
    }

    func contains(_ point: Point2) -> Bool { abs(point.x) <= width / 2 && abs(point.y) <= height / 2 }
}

/// Something flat a construction plane is defined from: a solid face, a sketch region, another
/// construction plane, or a world plane. Captured when picked as a point on it, its normal (out of
/// the solid for a face), and its outline in world millimeters (for sizing and highlighting).
struct PlaneReference: Equatable, Sendable {
    enum Source: Equatable, Sendable { case face(UUID, Int), profile(String), plane(UUID), world(SketchPlane) }
    var source: Source
    var origin: SIMD3<Double>
    var normal: SIMD3<Double>
    var outline: [SIMD3<Double>]

    /// Half the side of the square a world plane is drawn and sized with.
    static let worldHalfSize = 30.0

    static func world(_ plane: SketchPlane) -> PlaneReference {
        let h = worldHalfSize
        return PlaneReference(source: .world(plane), origin: plane.origin, normal: plane.normalAxis,
                              outline: [Point2(x: -h, y: -h), Point2(x: h, y: -h), Point2(x: h, y: h), Point2(x: -h, y: h)].map { plane.point($0) })
    }

    static func construction(_ plane: ConstructionPlane) -> PlaneReference {
        PlaneReference(source: .plane(plane.id), origin: plane.plane.origin, normal: plane.plane.normalAxis,
                       outline: plane.outline.map { plane.plane.point($0) })
    }

    static func profile(_ profile: SketchProfile) -> PlaneReference {
        PlaneReference(source: .profile(profile.id), origin: profile.plane.point(profile.center), normal: profile.plane.normalAxis,
                       outline: profile.outline.map { profile.plane.point($0) })
    }

    /// A flat face of a solid; nil for curved faces.
    static func face(_ face: Int, of body: SolidBody) -> PlaneReference? {
        guard let solid = try? SolidKernel.solid(for: body), let plane = solid.facePlane(face),
              let outline = solid.faceOutline(face), let center = solid.faceCenter(face) else { return nil }
        return PlaneReference(source: .face(body.id, face), origin: center, normal: simd_normalize(plane.normal), outline: outline.points)
    }
}

enum ConstructionPlanes {
    /// `offset` millimeters along the reference's normal (out of a face), the same size as the
    /// reference plus a margin.
    static func offset(from reference: PlaneReference, by offset: Double) -> ConstructionPlane? {
        guard offset.isFinite, abs(offset) <= 10_000 else { return nil }
        let shift = reference.normal * offset
        return plane(normal: reference.normal, through: reference.origin + shift, covering: reference.outline.map { $0 + shift })
    }

    /// Centered between two parallel references, facing like the first; nil when they are not parallel.
    static func midplane(between a: PlaneReference, and b: PlaneReference) -> ConstructionPlane? {
        guard areParallel(a, b) else { return nil }
        let gap = simd_dot(b.origin - a.origin, a.normal)
        return plane(normal: a.normal, through: a.origin + a.normal * (gap / 2), covering: a.outline + b.outline)
    }

    /// Whether two references can have a midplane (they are parallel).
    static func areParallel(_ a: PlaneReference, _ b: PlaneReference) -> Bool {
        simd_length(simd_cross(a.normal, b.normal)) < 1e-9
    }

    // MARK: More construction planes (October 24, 2026)

    /// The plane through a line (`point`, `direction`) turned `degrees` about it from the plane
    /// through it with `reference` as its normal (a face beside an edge, a line's sketch plane).
    /// Nil when the reference runs along the line.
    static func atAngle(through point: SIMD3<Double>, along direction: SIMD3<Double>, length: Double,
                        reference: SIMD3<Double>, degrees: Double) -> ConstructionPlane? {
        guard simd_length(direction) > 1e-9, degrees.isFinite, length.isFinite else { return nil }
        let axis = simd_normalize(direction)
        let flat = reference - axis * simd_dot(reference, axis)
        guard simd_length(flat) > 1e-9 else { return nil }
        let normal = RigidTransform.rotate(degrees: degrees, about: axis, through: .zero).apply(vector: simd_normalize(flat))
        // As long as the line, and as wide as it is long (at least 20 mm), away from the line on its far side.
        let half = max(length, 20) / 2, across = simd_cross(normal, axis)
        let corners = [point - axis * half, point + axis * half, point - axis * half + across * 2 * half, point + axis * half + across * 2 * half]
        return plane(normal: normal, through: point, covering: corners)
    }

    /// The plane through three points; nil when they are (nearly) in a line.
    static func through(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> ConstructionPlane? {
        let normal = simd_cross(b - a, c - a)
        let scale = max(simd_length(b - a) * simd_length(c - a), 1e-12)
        guard simd_length(normal) > 1e-9 * scale else { return nil }
        // Facing up (or toward +Y, +X) when it can, as the world planes do.
        var n = simd_normalize(normal)
        if n.z < -1e-9 || abs(n.z) <= 1e-9 && (n.y < -1e-9 || abs(n.y) <= 1e-9 && n.x < 0) { n = -n }
        return plane(normal: n, through: (a + b + c) / 3, covering: [a, b, c])
    }

    /// The plane touching a round face (a cylinder about `axisPoint`, `axisDirection`, of `radius`)
    /// along the line through `point` (on or near the face), facing out of it, as tall as `height`.
    static func tangent(toCylinderAt axisPoint: SIMD3<Double>, axisDirection: SIMD3<Double>, radius: Double,
                        through point: SIMD3<Double>, height: Double) -> ConstructionPlane? {
        guard simd_length(axisDirection) > 1e-9, radius > 0 else { return nil }
        let axis = simd_normalize(axisDirection), d = point - axisPoint, along = simd_dot(d, axis)
        let radial = d - axis * along
        guard simd_length(radial) > 1e-9 else { return nil }
        let normal = simd_normalize(radial), touch = axisPoint + axis * along + normal * radius
        let across = simd_cross(normal, axis), half = max(height, 2 * radius, 20) / 2
        return plane(normal: normal, through: touch, covering: [touch - axis * half - across * half, touch + axis * half + across * half])
    }

    /// The plane through `point` with `normal`, axes as for sketch planes (following world up), drawn
    /// as a rectangle covering `points` (projected onto it) with a margin.
    private static func plane(normal: SIMD3<Double>, through point: SIMD3<Double>, covering points: [SIMD3<Double>]) -> ConstructionPlane? {
        guard let canonical = SketchPlane.through(point, normal: normal) else { return nil }
        let local = points.map(canonical.coordinates(of:))
        var low = canonical.coordinates(of: point), high = low
        if let first = local.first {
            low = local.reduce(first) { Point2(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
            high = local.reduce(first) { Point2(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
        }
        let margin = max(5, 0.1 * max(high.x - low.x, high.y - low.y))
        let center = (low + high) * 0.5
        let frame = SketchPlane(origin: canonical.point(center).roundedOff(), xAxis: canonical.xAxis, yAxis: canonical.yAxis)
        let result = ConstructionPlane(plane: frame, width: max(10, high.x - low.x + 2 * margin), height: max(10, high.y - low.y + 2 * margin))
        return result.isValid ? result : nil
    }
}

/// Construction axes (October 24, 2026): a straight reference line in space, kept as a sketch of its
/// own named "Axis 01", "Axis 02", … holding one construction line, on a plane through the line.
/// Like any construction line, it is a revolve axis, a mirror line, and an Align target, and it
/// shows, hides, groups, and deletes in the Model Tree like a sketch.
enum ConstructionAxes {
    /// A new axis from `a` to `b` in `workspace`, named after the axes already there. Nil when the
    /// points are (nearly) the same.
    static func adding(from a: SIMD3<Double>, to b: SIMD3<Double>, in workspace: Workspace) -> (workspace: Workspace, sketch: UUID)? {
        guard simd_distance(a, b) > 0.01 else { return nil }
        let direction = simd_normalize(b - a)
        // A plane containing the line: its normal across the line, toward world up when it can be.
        let up: SIMD3<Double> = abs(direction.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        let normal = simd_normalize(simd_cross(direction, simd_cross(up, direction)))
        guard let plane = SketchPlane.through(a, normal: normal) else { return nil }
        var line = SketchShape(kind: .line, plane: plane, start: plane.coordinates(of: a), end: plane.coordinates(of: b))
        line.construction = true
        let existing = Set(workspace.sketches.compactMap(\.name))
        let number = (1...999).first { !existing.contains(String(format: "Axis %02d", $0)) } ?? 1
        var result = workspace
        let sketch = Sketch(id: line.id, plane: plane, name: String(format: "Axis %02d", number))
        line.sketch = sketch.id
        result.sketches.append(sketch)
        result.shapes.append(line)
        return result.isValid ? (result, sketch.id) : nil
    }
}
