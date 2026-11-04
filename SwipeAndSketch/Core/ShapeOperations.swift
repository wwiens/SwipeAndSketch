import Foundation
import SSKernel
import simd

// Tier 2 basics (October 24, 2026): Draft leans faces for molds, Rib adds a stiffening web from a
// sketch line, Loft blends between sketch regions, and Sweep carries a region along a path. Draft
// and Rib are steps in a solid's `cuts` list, in the solid's own frame like the face edits; a loft
// or sweep is a new solid whose exact shape is stored in the project like an imported one.

/// Faces leaned by `angle` degrees from the pull direction, pivoting on the neutral plane (through
/// `origin`, perpendicular to `pull`): the face itself where it lies on that plane stays put.
struct DraftSpec: Codable, Equatable, Sendable {
    /// A point on each face to lean, in the solid's frame.
    var points: [SIMD3<Double>]
    var pull: SIMD3<Double>
    var origin: SIMD3<Double>
    var angle: Double
    static let angleRange = 0.01...60.0
    var isValid: Bool {
        let vectors = points + [pull, origin]
        return (1...64).contains(points.count) && vectors.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } &&
            abs(simd_length(pull) - 1) < 1e-6 && angle.isFinite && Self.angleRange.contains(abs(angle))
    }
}

/// A rib: the sketch line from `start` to `end` on a plane with normal `normal` (all in the solid's
/// frame), thickened `thickness` across that plane and reaching along it, on `side` of the line
/// (+1 toward normal × direction), until it meets the solid.
struct RibSpec: Codable, Equatable, Sendable {
    var start: SIMD3<Double>
    var end: SIMD3<Double>
    var normal: SIMD3<Double>
    var thickness: Double
    var side: Double
    static let thicknessRange = 0.1...100.0
    var isValid: Bool {
        [start, end, normal].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } && simd_distance(start, end) >= 0.01 &&
            abs(simd_length(normal) - 1) < 1e-6 && abs(simd_dot(normal, end - start)) < 1e-6 * max(1, simd_distance(start, end)) &&
            Self.thicknessRange.contains(thickness) && abs(side) == 1
    }
}

extension ExtrusionCut {
    static func draft(_ spec: DraftSpec, of body: SolidBody) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.draft = spec
        return operation
    }

    static func rib(_ spec: RibSpec, of body: SolidBody) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.rib = spec
        return operation
    }
}

private func adopt(_ pointer: OpaquePointer?, _ fallback: String) throws -> KernelSolid {
    guard let pointer else { throw SolidKernel.Failure(message: ssk_last_error().map { String(cString: $0) } ?? fallback) }
    return KernelSolid(adopting: pointer)
}

private func vec(_ v: SIMD3<Double>) -> SSKVec3 { SSKVec3(x: v.x, y: v.y, z: v.z) }

extension SolidKernel {
    static func applyDraft(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let spec = operation.draft else { throw Failure(message: "Missing draft") }
        var faces: [Int32] = []
        for point in spec.points {
            guard let face = solid.face(near: body.worldPoint(point), tolerance: 1e-3) else { throw Failure(message: "A face to draft no longer exists on this solid") }
            if !faces.contains(Int32(face)) { faces.append(Int32(face)) }
        }
        let origin = body.worldPoint(spec.origin)
        let pull = simd_normalize(body.worldPoint(spec.origin + spec.pull) - origin)
        return try adopt(ssk_draft_faces(solid.handle, faces, Int32(faces.count), vec(pull), vec(origin), vec(pull), spec.angle), "Draft failed")
    }

    static func applyRib(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let spec = operation.rib else { throw Failure(message: "Missing rib") }
        let a = body.worldPoint(spec.start), b = body.worldPoint(spec.end)
        let normal = simd_normalize(body.worldPoint(spec.start + spec.normal) - a)
        guard let web = try Ribs.web(from: a, to: b, normal: normal, thickness: spec.thickness, side: spec.side, against: solid) else {
            throw Failure(message: "The rib does not meet the solid on that side")
        }
        let result = try boolean(solid, web, .union)
        guard result.isValidSolid else { throw Failure(message: "The rib does not join the solid") }
        return result
    }
}

enum Ribs {
    /// The web between the line and the solid: a slab `thickness` thick across the line's plane,
    /// running from the line on `side` until it meets `solid`, or nil when it never does.
    static func web(from a: SIMD3<Double>, to b: SIMD3<Double>, normal: SIMD3<Double>, thickness: Double, side: Double,
                    against solid: KernelSolid) throws -> KernelSolid? {
        let along = simd_normalize(b - a), out = simd_normalize(simd_cross(normal, along)) * side
        let bounds = solid.bounds
        let reach = simd_length(bounds.max - bounds.min) + simd_distance(a, (bounds.min + bounds.max) / 2) + 10
        guard let plane = SketchPlane.through(a, normal: normal) else { return nil }
        let corners = [a, b, b + out * reach, a + out * reach].map(plane.coordinates(of:))
        let lines = (0..<4).map { SketchShape(kind: .line, plane: plane, start: corners[$0], end: corners[($0 + 1) % 4]) }
        guard let profile = Geometry.profiles(in: lines, on: plane).first else { return nil }
        let slab = try SolidKernel.extrude(profile, depth: thickness, symmetric: true, taper: 0)
        let gap = try SolidKernel.boolean(slab, solid, .subtract)
        // The piece of the slab left beside the line, which must stop at the solid before the far end.
        let probe = (a + b) / 2 + out * min(0.05, thickness / 4)
        let pieces = try (0..<Int(ssk_solid_count(gap.handle))).map { try adopt(ssk_solid(gap.handle, Int32($0)), "A rib piece could not be read") }
        guard let piece = pieces.first(where: { ssk_point_inside($0.handle, vec(probe)) }) else { return nil }
        let far = simd_dot(a + out * reach - a, out)
        let box = piece.bounds
        var corners3: [SIMD3<Double>] = []
        for x in [box.min.x, box.max.x] { for y in [box.min.y, box.max.y] { for z in [box.min.z, box.max.z] { corners3.append(SIMD3(x, y, z)) } } }
        let pieceReach = corners3.map { simd_dot($0 - a, out) }.max() ?? far
        // Running out to the slab's far end means it never met the solid.
        guard pieceReach < far - 1 else { return nil }
        return piece
    }

    /// `body` with a rib from the line `a`–`b` on the plane with `normal` (world), on whichever side
    /// meets the solid (`side` first when given). Nil when neither does.
    static func ribbing(_ body: SolidBody, from a: SIMD3<Double>, to b: SIMD3<Double>, normal: SIMD3<Double>, thickness: Double,
                        side preferred: Double? = nil) -> SolidBody? {
        guard RibSpec.thicknessRange.contains(thickness), simd_distance(a, b) >= 0.01, let solid = try? SolidKernel.solid(for: body) else { return nil }
        let n = simd_normalize(normal - simd_normalize(b - a) * simd_dot(normal, simd_normalize(b - a)))
        for side in preferred.map({ [$0, -$0] }) ?? [1.0, -1.0] {
            guard (try? web(from: a, to: b, normal: n, thickness: thickness, side: side, against: solid)) ?? nil != nil else { continue }
            let origin = body.localPoint(a)
            let spec = RibSpec(start: origin, end: body.localPoint(b), normal: simd_normalize(body.localPoint(a + n) - origin),
                               thickness: thickness, side: side)
            var result = body
            result.cuts.append(.rib(spec, of: body))
            if result.isValid, (try? SolidKernel.solid(for: result)) != nil { return result }
        }
        return nil
    }
}

enum Drafting {
    /// `body` with the faces through `points` (world) leaned `angle` degrees from `pull` (world),
    /// pivoting on the plane through `origin` perpendicular to it; nil when it cannot be built.
    static func drafting(_ body: SolidBody, faces points: [SIMD3<Double>], pull: SIMD3<Double>, origin: SIMD3<Double>, angle: Double) -> SolidBody? {
        guard !points.isEmpty, simd_length(pull) > 1e-9, body.cuts.count < ExtrusionCut.maximumPerBody else { return nil }
        let local = body.localPoint(origin)
        let spec = DraftSpec(points: points.map(body.localPoint), pull: simd_normalize(body.localPoint(origin + simd_normalize(pull)) - local),
                             origin: local, angle: angle)
        var result = body
        result.cuts.append(.draft(spec, of: body))
        guard result.isValid, (try? SolidKernel.solid(for: result)) != nil else { return nil }
        return result
    }
}

// MARK: Loft and Sweep

enum ShapedSolids {
    /// A closed section for the kernel: a circle's seven numbers (count 0), or its outline's points.
    static func section(_ profile: SketchProfile) -> (data: [Double], count: Int32) {
        if let circle = profile.circle {
            let c = profile.plane.point(circle.center), n = profile.plane.normalAxis
            return ([c.x, c.y, c.z, n.x, n.y, n.z, circle.radius], 0)
        }
        let points = profile.outline.map { profile.plane.point($0) }
        return (points.flatMap { [$0.x, $0.y, $0.z] }, Int32(points.count))
    }

    /// A solid through the regions in order (`ruled`: flat pieces between them).
    static func loft(_ sections: [SketchProfile], ruled: Bool) throws -> KernelSolid {
        guard sections.count >= 2 else { throw SolidKernel.Failure(message: "Pick at least two regions to loft between.") }
        guard sections.allSatisfy({ ($0.holes ?? []).isEmpty }) else { throw SolidKernel.Failure(message: "Regions with holes in them cannot be lofted.") }
        let parts = sections.map(section)
        let data = parts.flatMap(\.data), counts = parts.map(\.count)
        return try adopt(ssk_loft(data, counts, Int32(counts.count), ruled), "Loft failed")
    }

    /// The region carried along the path through `path` (world points): smooth through them, or
    /// straight pieces meeting at corners.
    static func sweep(_ section: SketchProfile, along path: [SIMD3<Double>], smooth: Bool) throws -> KernelSolid {
        guard path.count >= 2 else { throw SolidKernel.Failure(message: "Pick a path: a sketch line, arc, spline, or joined lines.") }
        guard (section.holes ?? []).isEmpty else { throw SolidKernel.Failure(message: "A region with holes in it cannot be swept.") }
        let part = self.section(section), points = path.flatMap { [$0.x, $0.y, $0.z] }
        return try adopt(ssk_sweep(part.data, part.count, points, Int32(path.count), smooth), "Sweep failed")
    }

    /// The path a sketch shape traces, as points, and whether it is smooth (an arc or spline).
    static func path(of shape: SketchShape) -> (points: [SIMD3<Double>], smooth: Bool)? {
        switch shape.kind {
        case .line: return ([shape.plane.point(shape.start), shape.plane.point(shape.end)], false)
        case .arc, .curve:
            let outline = shape.outline + (shape.isClosed ? [shape.outline[0]] : [])
            return (outline.map { shape.plane.point($0) }, shape.kind == .arc || shape.isSpline)
        default: return nil
        }
    }

    /// Lines and arcs joined end to end with `first`, in order along the chain, as one path (sharp at
    /// corners); a single arc or spline stays smooth.
    static func chain(from first: SketchShape, in shapes: [SketchShape]) -> (points: [SIMD3<Double>], smooth: Bool)? {
        guard let single = path(of: first) else { return nil }
        guard first.kind == .line else { return single }
        var points = single.points
        var used: Set<UUID> = [first.id]
        // Extend from either end through joined lines.
        for _ in 0..<2 {
            var extended = true
            while extended {
                extended = false
                for shape in shapes where shape.kind == .line && shape.sketch == first.sketch && !used.contains(shape.id) {
                    let a = shape.plane.point(shape.start), b = shape.plane.point(shape.end)
                    guard let last = points.last else { break }
                    if simd_distance(a, last) < 1e-6 { points.append(b) } else if simd_distance(b, last) < 1e-6 { points.append(a) } else { continue }
                    used.insert(shape.id)
                    extended = true
                }
            }
            points.reverse()
        }
        return (points, false)
    }

    /// `workspace` with a new solid of exactly `solid`'s shape, stored in the project like an
    /// imported one and named `name` in the Model Tree; nil when it would not save.
    static func adding(_ solid: KernelSolid, named name: String, to workspace: Workspace) -> (workspace: Workspace, body: UUID)? {
        guard let data = try? solid.shapeData() else { return nil }
        let shape = ImportedShape(id: UUID(), name: name, data: data)
        ImportedShapes.shared.register([shape])
        var next = workspace
        next.importedShapes.append(shape)
        let body = SolidBody.fromImport(shape, solid: solid)
        next.bodies.append(body)
        let stored = next.importedShapes.reduce(0) { $0 + $1.data.count } * 4 / 3
        guard next.isValid, stored < ProjectCodec.maximumFileBytes * 9 / 10, (try? SolidKernel.solid(for: body)) != nil else { return nil }
        return (next, body.id)
    }
}
