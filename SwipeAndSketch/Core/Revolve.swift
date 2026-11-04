import Foundation
import simd

// Revolves (schema 14): a profile turned about an axis in its own plane. A
// revolved solid stores the spec in `SolidBody.revolve`; a revolve that joins or cuts another
// solid is an ordinary join or cut entry whose tool is revolved instead of extruded.

/// The axis and angle of a revolve. The axis runs through two points in the profile plane's own
/// coordinates, so moving or turning the solid carries it along. Positive angles turn right-handed
/// about `from` → `to`.
struct RevolveSpec: Codable, Equatable, Sendable {
    var from: Point2
    var to: Point2
    /// Signed degrees; ±360 is a full revolution with no end faces.
    var angle: Double
    static let angleRange = 0.1...360.0

    var isValid: Bool {
        from.isValid && to.isValid && from.distance(to: to) >= 0.01 && angle.isFinite && Self.angleRange.contains(abs(angle))
    }
    var isFull: Bool { abs(angle) >= 360 - 1e-9 }

    /// An axis through `from` and `to`, ordered so a positive angle first lifts `profile` toward
    /// its plane's normal, as a positive extrusion depth does.
    static func oriented(from: Point2, to: Point2, angle: Double, for profile: SketchProfile) -> RevolveSpec {
        let side = Geometry.cross(to - from, profile.center - from)
        return side < 0 ? RevolveSpec(from: to, to: from, angle: angle) : RevolveSpec(from: from, to: to, angle: angle)
    }

    /// Signed distance of a point from the axis line: positive on the left of `from` → `to`.
    func side(of point: Point2) -> Double {
        let d = to - from
        return Geometry.cross(d, point - from) / max(d.length, 1e-12)
    }

    /// The profile stays on one side of the axis (touching it is fine). Arcs are checked through
    /// the outline points along them; the kernel checks the exact arcs again.
    func allows(_ profile: SketchProfile) -> Bool {
        guard isValid else { return false }
        let sides = profile.circle.map { [side(of: $0.center) - $0.radius, side(of: $0.center) + $0.radius] } ?? profile.outline.map(side(of:))
        let low = min(0, sides.min() ?? 0), high = max(0, sides.max() ?? 0), tolerance = 1e-6
        return !(low < -tolerance && high > tolerance) && high - low > tolerance
    }

    /// +1 when the sweep first moves the profile toward its plane's normal, −1 when away.
    func sweepSign(for profile: SketchProfile) -> Double {
        (Geometry.cross(to - from, profile.center - from) >= 0 ? 1 : -1) * (angle >= 0 ? 1 : -1)
    }

    /// The axis in world space: a point on it and its unit direction.
    func axis(on plane: SketchPlane) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let a = plane.point(from)
        return (a, simd_normalize(plane.point(to) - a))
    }

    /// The turn this revolve makes about its axis (by `degrees`, the full angle by default).
    func rotation(on plane: SketchPlane, degrees: Double? = nil) -> RigidTransform {
        let axis = axis(on: plane)
        return .rotate(degrees: degrees ?? angle, about: axis.direction, through: axis.origin)
    }
}

extension SolidKernel {
    /// The tool a revolved join or cut adds or removes.
    static func revolveTool(for cut: ExtrusionCut, _ spec: RevolveSpec, on solid: KernelSolid) throws -> KernelSolid {
        guard let point = cut.facePoint else { return try revolve(cut.profile, spec) }
        let plane = cut.profile.plane
        guard let face = solid.face(containing: plane.point(point), normal: plane.normalAxis) else {
            throw Failure(message: "The revolved face no longer exists on this solid")
        }
        return try revolve(face: face, of: solid, about: spec.axis(on: plane), angle: spec.angle)
    }
}

extension SolidBody {
    /// A solid revolved from `profile`. Its `depth` is unused and stored as 0.
    init(id: UUID = UUID(), profile: SketchProfile, revolve: RevolveSpec) {
        self.init(id: id, profile: profile, depth: 0)
        self.revolve = revolve
    }

    /// Distance from a point to a named edge of the original revolve: `base` lies on the sketch
    /// plane (the start face) and `cap` on the end face, along profile segment `index`; `side` is
    /// the ring corner `index` traces about the axis.
    func revolveDistance(_ point: SIMD3<Double>, to edge: ExtrusionEdge, _ spec: RevolveSpec) -> Double {
        let plane = profile.plane
        switch edge.position {
        case .base, .cap:
            guard !spec.isFull else { return .infinity }
            // The end face is the start face turned by the angle; turn the point back onto it.
            let p = edge.position == .cap ? spec.rotation(on: plane, degrees: -spec.angle).apply(point: point) : point
            var flat = self
            flat.revolve = nil
            flat.depth = 1
            return flat.distance(p, to: ExtrusionEdge(position: .base, index: edge.index))
        case .imported:
            return .infinity
        case .side:
            guard profile.circle == nil else { return .infinity }
            let corners = corners
            guard corners.indices.contains(edge.index) else { return .infinity }
            let axis = spec.axis(on: plane)
            func polar(_ p: SIMD3<Double>) -> (along: Double, radial: SIMD3<Double>) {
                let along = simd_dot(p - axis.origin, axis.direction)
                return (along, p - axis.origin - axis.direction * along)
            }
            let corner = polar(plane.point(corners[edge.index])), here = polar(point)
            let r0 = simd_length(corner.radial), r = simd_length(here.radial)
            guard r0 > 1e-6 else { return .infinity }
            let distance = hypot(here.along - corner.along, r - r0)
            guard !spec.isFull, r > 1e-9 else { return distance }
            // Only the part of the ring the sweep covers.
            let start = corner.radial / r0, normal = simd_cross(axis.direction, start)
            var turned = atan2(simd_dot(here.radial, normal), simd_dot(here.radial, start)) * 180 / .pi
            if spec.angle >= 0 { if turned < -1e-6 { turned += 360 } } else if turned > 1e-6 { turned -= 360 }
            let slack = 1e-3 + 1e-4 / r * 180 / .pi
            let inside = spec.angle >= 0 ? turned <= spec.angle + slack : turned >= spec.angle - slack
            return inside ? distance : .infinity
        }
    }

    /// Whether a point on a start or end face lies on the profile's side of the axis (turned back
    /// onto the sketch plane for the end face).
    func isOnProfileSide(_ point: SIMD3<Double>, of face: ExtrusionFace, _ spec: RevolveSpec) -> Bool {
        let plane = profile.plane
        let p = face.position == .cap ? spec.rotation(on: plane, degrees: -spec.angle).apply(point: point) : point
        return spec.side(of: plane.coordinates(of: p)) * spec.side(of: profile.center) > 0
    }

    /// The flat end faces of a partial revolve: the start face on the sketch plane, and the end face.
    func revolvePlane(of face: ExtrusionFace, _ spec: RevolveSpec) -> (point: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard !spec.isFull else { return nil }
        let plane = profile.plane, n = plane.normalAxis, sweep = spec.sweepSign(for: profile)
        switch face.position {
        case .base: return (plane.point(profile.center), -n * sweep)
        case .cap:
            let turn = spec.rotation(on: plane)
            return (turn.apply(point: plane.point(profile.center)), turn.apply(vector: n) * sweep)
        case .side: return nil
        }
    }
}
