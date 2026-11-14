import Foundation
import SSKernel
import simd

// Direct edits of a solid's faces: Delete Face takes faces
// off and closes the gap (a fillet, chamfer, hole, or boss removed), and Offset Face moves faces
// along their normals (a round face's diameter changed, a flat face pushed or pulled). Both are
// steps in a solid's `cuts` list that find their faces again by a point on each, in the solid's own
// frame, as shell openings and finishes do.

/// Faces to take off a solid.
struct FaceRemovalSpec: Codable, Equatable, Sendable {
    var points: [SIMD3<Double>]
    var isValid: Bool { (1...64).contains(points.count) && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } }
}

/// Faces moved `distance` millimeters along their outward normals (negative moves them in).
struct FaceOffsetSpec: Codable, Equatable, Sendable {
    var points: [SIMD3<Double>]
    var distance: Double
    /// How the faces around them were made to follow when the edit was made: true intersects every
    /// face, false extends only the neighbours. Rebuilding uses the same way, so a saved solid comes
    /// out the same on any iPad; nil (steps saved before November 2, 2026) tries true, then false.
    var intersection: Bool?
    static let distanceRange = 0.0005...1000.0
    var isValid: Bool {
        (1...64).contains(points.count) && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } &&
            distance.isFinite && Self.distanceRange.contains(abs(distance))
    }
}

extension ExtrusionCut {
    /// Takes off the faces of `body` through these world points.
    static func deleteFaces(at points: [SIMD3<Double>], of body: SolidBody) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.removedFaces = FaceRemovalSpec(points: points.map(body.localPoint))
        return operation
    }

    /// Moves the faces of `body` through these world points by `distance` along their normals.
    static func offsetFaces(at points: [SIMD3<Double>], by distance: Double, of body: SolidBody) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.movedFaces = FaceOffsetSpec(points: points.map(body.localPoint), distance: distance)
        return operation
    }
}

extension SolidKernel {
    /// The faces of `solid` through `points` (in `body`'s own frame).
    fileprivate static func faces(at points: [SIMD3<Double>], on solid: KernelSolid, of body: SolidBody) throws -> [Int] {
        var faces: [Int] = []
        for point in points {
            guard let face = solid.face(near: body.worldPoint(point), tolerance: 1e-3) else {
                throw Failure(message: "A face to change no longer exists on this solid")
            }
            if !faces.contains(face) { faces.append(face) }
        }
        return faces
    }

    static func applyFaceRemoval(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let spec = operation.removedFaces else { throw Failure(message: "Missing faces to delete") }
        return try removingFaces(try faces(at: spec.points, on: solid, of: body), from: solid)
    }

    /// `seconds` > 0 gives up after that long (an edit being made); a saved step runs to the end.
    static func applyFaceOffset(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody, seconds: Double = 0) throws -> KernelSolid {
        guard let spec = operation.movedFaces else { throw Failure(message: "Missing faces to move") }
        return try offsettingFaces(try faces(at: spec.points, on: solid, of: body), of: solid, by: spec.distance,
                                   intersection: spec.intersection, seconds: seconds)
    }
}

enum FaceEditing {
    /// `body` with the faces through `points` (world) taken off, or nil when the gap cannot close.
    static func deleting(faces points: [SIMD3<Double>], of body: SolidBody) -> SolidBody? {
        guard !points.isEmpty, body.cuts.count < ExtrusionCut.maximumPerBody else { return nil }
        var result = body
        result.cuts.append(.deleteFaces(at: points, of: body))
        guard result.isValid, (try? SolidKernel.solid(for: result)) != nil else { return nil }
        return result
    }

    /// How long an edit may spend moving faces before it is refused.
    static let offsetSeconds = 5.0

    /// `body` with the faces through `points` (world) moved `distance` along their normals.
    /// Extending only the neighbouring faces is tried first; intersecting every face is tried on
    /// solids of at most 64 faces, since on pocket arrays OCCT can stall inside one face pair where
    /// it does not check the deadline. The step records which one worked.
    static func offsetting(faces points: [SIMD3<Double>], by distance: Double, of body: SolidBody) -> SolidBody? {
        guard !points.isEmpty, body.cuts.count < ExtrusionCut.maximumPerBody,
              let solid = try? SolidKernel.solid(for: body) else { return nil }
        let started = ContinuousClock.now
        for intersection in [false, true] {
            if intersection && solid.faceCount > 64 { break }
            let elapsed = started.duration(to: .now) / .seconds(1)
            guard elapsed < offsetSeconds else { break }
            var operation = ExtrusionCut.offsetFaces(at: points, by: distance, of: body)
            operation.movedFaces?.intersection = intersection
            var result = body
            result.cuts.append(operation)
            guard result.isValid else { return nil }
            guard let moved = try? SolidKernel.applyFaceOffset(operation, to: solid, of: body, seconds: offsetSeconds - elapsed) else { continue }
            // Built just as the saved step rebuilds (same mode, no deadline), so keep it.
            SolidCache.shared.remember(moved, for: result)
            return result
        }
        return nil
    }
}

extension KernelSolid {
    /// For a cylindrical face: 1 when it faces away from its axis (a round boss), −1 when it faces
    /// the axis (a hole), 0 for any other face.
    func cylinderSide(_ face: Int) -> Int { Int(ssk_face_cylinder_side(handle, Int32(face))) }
}

/// Sizes read and changed from a selected face (October 21, 2026): a round face's diameter, or a
/// flat face's distance to the parallel face behind it (a box's width or height). A size stored in
/// the solid's definition (its own circle or depth, a cut's circle, a hole's diameter, a side of its
/// profile) is changed there, so the solid stays as simple as it was; anything else moves the face
/// with an Offset Face step.
extension FaceEditing {
    enum Size: Equatable {
        /// A round face: its diameter, and 1 for a boss or −1 for a hole.
        case diameter(Double, side: Int)
        /// A flat face: how far the nearest parallel face facing the other way lies behind it.
        case distance(Double, opposite: Int)
        var value: Double { switch self { case .diameter(let d, _): d; case .distance(let d, _): d } }
    }

    /// With `point` (where the face was tapped), a flat face measures to the nearest parallel face
    /// straight behind that point, so a face beside a window measures to the window where it was
    /// tapped beside it and to the far side elsewhere; when no parallel face lies straight behind it,
    /// or without a point, to the nearest parallel plane anywhere.
    static func size(of face: Int, on solid: KernelSolid, at point: SIMD3<Double>? = nil) -> Size? {
        if let cylinder = solid.faceCylinder(face) {
            let side = solid.cylinderSide(face)
            return side == 0 ? nil : .diameter(2 * cylinder.radius, side: side)
        }
        guard let plane = solid.facePlane(face) else { return nil }
        var candidates: [(distance: Double, face: Int)] = []
        for other in 0..<solid.faceCount where other != face {
            guard let candidate = solid.facePlane(other), simd_dot(candidate.normal, plane.normal) < -0.9999 else { continue }
            let distance = simd_dot(plane.origin - candidate.origin, plane.normal)
            if distance > 1e-6 { candidates.append((distance, other)) }
        }
        candidates.sort { $0.distance < $1.distance }
        if let point {
            // The tapped point carried onto the face's own plane, then straight back to each candidate.
            let onFace = point - plane.normal * simd_dot(point - plane.origin, plane.normal)
            for candidate in candidates {
                let behind = onFace - plane.normal * candidate.distance
                if let nearest = solid.point(onFace: candidate.face, near: behind), simd_distance(nearest, behind) < 1e-4 {
                    return .distance(candidate.distance, opposite: candidate.face)
                }
            }
        }
        return candidates.first.map { .distance($0.distance, opposite: $0.face) }
    }

    /// `body` with the face `face` (of its solid as built, through `point`) resized: a round face to
    /// `value` across, a flat face to `value` from the face behind `point`. Nil when it does not fit.
    static func resizing(_ body: SolidBody, face: Int, at point: SIMD3<Double>, to value: Double) -> SolidBody? {
        guard value.isFinite, value >= 0.01, let solid = try? SolidKernel.solid(for: body), let size = size(of: face, on: solid, at: point) else { return nil }
        if abs(size.value - value) < 1e-9 { return body }
        let candidates: [SolidBody]
        let offset: Double
        switch size {
        case .diameter(let diameter, let side):
            candidates = definitionResizes(body, solid: solid, face: face, to: value / 2)
            // Grown outward a boss gets wider; a hole's wall faces its axis, so it moves back to widen.
            offset = (value - diameter) / 2 * Double(side)
        case .distance(let distance, let opposite):
            candidates = trimmedOutlineMoves(body, solid: solid, face: face, by: value - distance) +
                definitionMoves(body, solid: solid, face: face, opposite: opposite, by: value - distance)
            offset = value - distance
        }
        for candidate in candidates where candidate.isValid && (try? SolidKernel.solid(for: candidate)) != nil { return candidate }
        return offsetting(faces: [point], by: offset, of: body)
    }

    /// A final through cut can trim a patterned plate to a rounded rectangular boundary.
    /// Move that boundary in its definition, preserving the corner radii and all pockets,
    /// rather than asking Offset Face to re-intersect every pocket in the plate.
    private static func trimmedOutlineMoves(_ body: SolidBody, solid: KernelSolid, face: Int, by delta: Double) -> [SolidBody] {
        guard let cut = body.cuts.last, cut.operation == .cut, cut.throughAll,
              cut.profile.holes?.count == 1, var hole = cut.profile.holes?.first,
              hole.circle == nil, hole.ellipse == nil, let arcs = hole.arcs, arcs.count == 4,
              let radius = arcs.first?.radius, arcs.allSatisfy({ abs($0.radius - radius) < 1e-6 }),
              let plane = solid.facePlane(face), let center = solid.faceCenter(face) else { return [] }
        let frame = cut.profile.plane
        let normal = Point2(x: simd_dot(plane.normal, frame.xAxis), y: simd_dot(plane.normal, frame.yAxis))
        let alongX = abs(normal.x) > 1 - 1e-6
        guard alongX || abs(normal.y) > 1 - 1e-6 else { return [] }
        let xs = hole.outline.map(\.x), ys = hole.outline.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let middle = Point2(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let reference = TemplateGeometry.roundedRectangle(center: middle, width: maxX - minX, depth: maxY - minY, radius: radius, on: .top)
        guard reference.outline.count == hole.outline.count,
              hole.outline.allSatisfy({ p in reference.outline.contains { $0.distance(to: p) < 1e-6 } }),
              arcs.allSatisfy({ arc in reference.arcs?.contains { $0.center.distance(to: arc.center) < 1e-6 && $0.start == arc.start && $0.segments == arc.segments } == true }) else { return [] }
        let positive = (alongX ? normal.x : normal.y) > 0
        let boundary = alongX ? (positive ? maxX : minX) : (positive ? maxY : minY)
        let local = frame.coordinates(of: center)
        guard abs((alongX ? local.x : local.y) - boundary) < 1e-5,
              (alongX ? maxX - minX : maxY - minY) + delta > 2 * radius + 0.01 else { return [] }
        let shift = normal * delta
        // The two corners on the moved side translate rigidly; the straight sides extend.
        func onMovedSide(_ point: Point2) -> Bool {
            let coordinate = alongX ? point.x : point.y, mid = alongX ? middle.x : middle.y
            return positive ? coordinate > mid : coordinate < mid
        }
        hole.outline = hole.outline.map { onMovedSide($0) ? $0 + shift : $0 }
        hole.arcs = arcs.map { arc in
            var arc = arc
            if onMovedSide(arc.center) { arc.center = arc.center + shift }
            return arc
        }
        var result = body
        result.cuts[result.cuts.count - 1].profile.holes = [hole]
        // The retained boundary must still lie in the material before the trim; otherwise
        // a larger requested size would silently stop at that material's old edge.
        guard result.isValid, let built = try? SolidKernel.solid(for: result),
              built.face(containing: center + plane.normal * delta, normal: plane.normal) != nil else { return [] }
        return [result]
    }

    /// The solid with whatever its definition holds for this round face (its own circle, a cut's or
    /// join's circle, a hole) set to `radius`, for each place that matches.
    private static func definitionResizes(_ body: SolidBody, solid: KernelSolid, face: Int, to radius: Double) -> [SolidBody] {
        guard let cylinder = solid.faceCylinder(face) else { return [] }
        let axis = simd_normalize(cylinder.direction), r = cylinder.radius
        func onAxis(_ p: SIMD3<Double>) -> Bool {
            let d = p - cylinder.point
            return simd_length(d - axis * simd_dot(d, axis)) < 1e-5
        }
        func matches(_ circle: CircleProfile, on plane: SketchPlane) -> Bool {
            abs(abs(simd_dot(plane.normalAxis, axis)) - 1) < 1e-6 && onAxis(plane.point(circle.center)) && abs(circle.radius - r) < 1e-6
        }
        func resized(_ outline: [Point2], _ circle: CircleProfile) -> [Point2] {
            outline.map { circle.center + ($0 - circle.center) * (radius / circle.radius) }
        }
        /// The profile with its outline circle, or a hole's circle, set to the new radius.
        func resizedProfile(_ profile: SketchProfile) -> SketchProfile? {
            var result = profile
            if let circle = profile.circle, matches(circle, on: profile.plane) {
                result.outline = resized(profile.outline, circle)
                result.circle = CircleProfile(center: circle.center, radius: radius)
                return result
            }
            for (index, hole) in (profile.holes ?? []).enumerated() {
                guard let circle = hole.circle, matches(circle, on: profile.plane) else { continue }
                result.holes?[index].outline = resized(hole.outline, circle)
                result.holes?[index].circle = CircleProfile(center: circle.center, radius: radius)
                return result
            }
            return nil
        }
        /// A scale after a step changes its sizes and places; those are left to Offset Face.
        func unscaled(after index: Int) -> Bool { !body.cuts.dropFirst(index + 1).contains { $0.scale != nil } }
        var results: [SolidBody] = []
        if body.imported == nil, unscaled(after: -1), let profile = resizedProfile(body.profile) {
            var result = body
            result.profile = profile
            results.append(result)
        }
        for (index, cut) in body.cuts.enumerated() where unscaled(after: index) {
            var result = body
            switch cut.operation {
            case .cut, .join:
                guard cut.facePoint == nil, let profile = resizedProfile(cut.profile) else { continue }
                result.cuts[index].profile = profile
            case .hole:
                guard var spec = cut.hole, let circle = cut.profile.circle, matches(circle, on: cut.profile.plane) || {
                    // A counterbore's wider wall.
                    spec.kind == .counterbore && abs(spec.counterboreDiameter / 2 - r) < 1e-6 && onAxis(cut.profile.plane.point(circle.center))
                }() else { continue }
                if abs(spec.diameter / 2 - r) < 1e-6 {
                    spec.diameter = 2 * radius
                    spec.counterboreDiameter = max(spec.counterboreDiameter, spec.diameter + 0.2)
                    spec.countersinkDiameter = max(spec.countersinkDiameter, spec.diameter + 0.2)
                    result.cuts[index].profile.outline = resized(cut.profile.outline, circle)
                    result.cuts[index].profile.circle = CircleProfile(center: circle.center, radius: radius)
                } else {
                    guard 2 * radius > spec.diameter else { continue }
                    spec.counterboreDiameter = 2 * radius
                }
                spec.size = ""
                result.cuts[index].hole = spec
            default: continue
            }
            results.append(result)
        }
        return results
    }

    /// The solid with its definition changed so this flat face moves `delta` outward: its depth for
    /// the far end of an extrusion, or a side of a straight-sided profile.
    private static func definitionMoves(_ body: SolidBody, solid: KernelSolid, face: Int, opposite: Int, by delta: Double) -> [SolidBody] {
        guard body.imported == nil, body.revolve == nil, !body.cuts.contains(where: { $0.scale != nil }),
              let plane = solid.facePlane(face), let center = solid.faceCenter(face),
              let name = body.extrusionFace(point: center, normal: plane.normal) else { return [] }
        switch name.position {
        case .cap:
            guard let back = solid.faceCenter(opposite).flatMap({ point in solid.facePlane(opposite).flatMap { body.extrusionFace(point: point, normal: $0.normal) } }),
                  back.position == .base else { return [] }
            var result = body
            result.depth = body.depth >= 0 ? body.depth + delta : body.depth - delta
            return [result]
        case .side:
            let profile = body.profile
            guard profile.circle == nil, profile.arcs == nil, profile.holes == nil, profile.ellipse == nil, body.corners.count == profile.outline.count else { return [] }
            let points = profile.outline, n = points.count, i = name.index
            guard n >= 3, points.indices.contains(i) else { return [] }
            let a = points[i], b = points[(i + 1) % n], previous = points[(i + n - 1) % n], next = points[(i + 2) % n]
            // Outward is to the right of a counterclockwise outline.
            let along = b - a, length = along.length
            guard length > 1e-9 else { return [] }
            let outward = Point2(x: along.y, y: -along.x) * ((Geometry.signedArea(points) > 0 ? 1 : -1) / length)
            let shift = outward * delta
            // Each moved end slides along its neighbor side, so the neighbors keep their direction.
            func meet(_ p: Point2, _ q: Point2, _ from: Point2, _ direction: Point2) -> Point2? {
                let d = q - p, denominator = Geometry.cross(direction, d)
                guard abs(denominator) > 1e-9 * max(1, d.length * direction.length) else { return nil }
                let t = Geometry.cross(p - from, d) / denominator
                return from + direction * t
            }
            guard let newA = meet(previous, a, a + shift, along), let newB = meet(b, next, a + shift, along) else { return [] }
            var result = body
            result.profile.outline[i] = newA
            result.profile.outline[(i + 1) % n] = newB
            return result.profile.isSolidProfile ? [result] : []
        case .base:
            return []
        }
    }
}
