import Foundation
import simd

// Face extrusions (schema 7): a solid's own flat face pushed out (joined) or in (cut), stored in
// its ordered `cuts` list like any other join or cut.

/// A flat face of a solid, ready to extrude: its outer boundary as a profile on the face's plane
/// (normal pointing out of the solid) and a point inside it that finds the face again when the
/// solid is rebuilt. `face` indexes the body's current kernel solid, for display only.
struct FaceExtrusionSource: Equatable, Sendable {
    var bodyID: UUID
    var face: Int
    var profile: SketchProfile
    var point: Point2
    /// The solid's size across the face before it moves: the distance to the parallel face behind
    /// it (a box's height for its top), or nil when there is none. The value shown and typed is this
    /// plus the depth, the size the solid ends up.
    var size: Double?

    /// Nil for curved faces and faces whose boundary cannot be traced.
    init?(body: SolidBody, face: Int) {
        guard let solid = try? SolidKernel.solid(for: body), let facePlane = solid.facePlane(face),
              let plane = SketchPlane.through(facePlane.origin, normal: facePlane.normal),
              let inside = solid.interiorPoint(of: face), let outline = solid.faceOutline(face) else { return nil }
        let id = "face:\(body.id.uuidString):\(face)"
        var profile: SketchProfile?
        if let edge = outline.singleEdge, let circle = solid.edgeCircle(edge) {
            let center = plane.coordinates(of: circle.center)
            let shape = SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: circle.radius, y: 0))
            profile = Geometry.profiles(in: [shape], on: plane).first
        } else {
            var points: [Point2] = []
            for point in outline.points.map(plane.coordinates) where points.last.map({ $0.distance(to: point) > 1e-6 }) ?? true {
                points.append(point)
            }
            if let first = points.first, let last = points.last, points.count > 1, first.distance(to: last) <= 1e-6 { points.removeLast() }
            profile = SketchProfile(id: id, plane: plane, sourceIDs: [], outline: points)
        }
        guard var profile, profile.isSolidProfile else { return nil }
        profile.id = id
        profile.sourceIDs = []
        self.bodyID = body.id
        self.face = face
        self.profile = profile
        self.point = plane.coordinates(of: inside)
        if case .distance(let distance, _)? = FaceEditing.size(of: face, on: solid) { size = distance }
    }

    /// The operation extruding this face `depth` millimeters: outward joins, inward cuts.
    func operation(depth: Double) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: profile, depth: depth, operation: depth > 0 ? .join : .cut)
        operation.facePoint = point
        return operation
    }
}

extension KernelSolid {
    /// A point strictly inside a face: the centroid of its largest display triangle.
    func interiorPoint(of face: Int) -> SIMD3<Double>? {
        guard let mesh = try? tessellateForDisplay(), mesh.faces.indices.contains(face) else { return nil }
        var best: (area: Float, point: SIMD3<Float>)?
        for start in stride(from: mesh.faces[face].lowerBound, to: mesh.faces[face].upperBound - 2, by: 3) {
            let a = mesh.positions[Int(mesh.indices[start])], b = mesh.positions[Int(mesh.indices[start + 1])]
            let c = mesh.positions[Int(mesh.indices[start + 2])]
            let area = simd_length(simd_cross(b - a, c - a))
            if area > best?.area ?? 0 { best = (area, (a + b + c) / 3) }
        }
        return best.map { SIMD3<Double>($0.point) }
    }
}

extension SolidKernel {
    /// The prism of the face a face extrusion names, found by its plane and inside point.
    static func faceTool(for cut: ExtrusionCut, on solid: KernelSolid) throws -> KernelSolid {
        guard let point = cut.facePoint else { throw Failure(message: "Missing face") }
        let plane = cut.profile.plane
        guard let face = solid.face(containing: plane.point(point), normal: plane.normalAxis) else {
            throw Failure(message: "The extruded face no longer exists on this solid")
        }
        return try extrude(face: face, of: solid, depth: cut.depth)
    }
}

extension SolidBody {
}
