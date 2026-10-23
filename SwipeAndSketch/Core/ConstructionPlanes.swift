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
