import Foundation
import simd

/// A rigid motion: rotate by `rotation` about `pivot`, then move by `translation`.
struct RigidTransform: Equatable, Sendable {
    var rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var pivot = SIMD3<Double>.zero
    var translation = SIMD3<Double>.zero

    static func move(_ offset: SIMD3<Double>) -> RigidTransform { RigidTransform(translation: offset) }
    /// Turns `degrees` about `axis` (right-handed) through `pivot`.
    static func rotate(degrees: Double, about axis: SIMD3<Double>, through pivot: SIMD3<Double>) -> RigidTransform {
        RigidTransform(rotation: simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis)), pivot: pivot)
    }

    func apply(point: SIMD3<Double>) -> SIMD3<Double> { rotation.act(point - pivot) + pivot + translation }
    func apply(vector: SIMD3<Double>) -> SIMD3<Double> { rotation.act(vector) }
}

extension SketchPlane {
    /// The plane carried by a rigid motion. Axes are re-orthonormalized and round-off is cleaned,
    /// so turning a sketch by quarter turns lands exactly on Top, Front, or Right.
    func transformed(by transform: RigidTransform) -> SketchPlane? {
        Self.cleaned(origin: transform.apply(point: origin), xAxis: transform.apply(vector: xAxis), yAxis: transform.apply(vector: yAxis))
    }

    /// A plane from computed axes: re-orthonormalized, with round-off cleaned so quarter turns
    /// and mirrors across world planes land exactly on whole axes.
    static func cleaned(origin: SIMD3<Double>, xAxis: SIMD3<Double>, yAxis: SIMD3<Double>) -> SketchPlane? {
        let x = simd_normalize(xAxis)
        let y = simd_normalize(yAxis - x * simd_dot(x, yAxis))
        let plane = SketchPlane(origin: origin.roundedOff(), xAxis: simd_normalize(x.roundedOff(1e12)), yAxis: simd_normalize(y.roundedOff(1e12)))
        return plane.isValid ? plane : nil
    }
}

extension Workspace {
    /// The middle of a sketch's extent, in world millimeters (where the Move/Rotate widget sits).
    func center(of sketch: Sketch) -> SIMD3<Double>? {
        let points = shapes(in: sketch.id).flatMap(\.outline)
        guard let first = points.first else { return nil }
        let low = points.reduce(first) { Point2(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
        let high = points.reduce(first) { Point2(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
        return sketch.plane.point((low + high) * 0.5)
    }

    /// Moves or turns a sketch, or (with `copy`) a copy of it, leaving the original in place. Only
    /// the sketch's plane changes; its shapes keep their exact 2D geometry. Returns the result and
    /// the id of the sketch that moved.
    func transformingSketch(_ id: UUID, by transform: RigidTransform, copy: Bool) -> (workspace: Workspace, sketchID: UUID)? {
        guard let index = sketches.firstIndex(where: { $0.id == id }),
              let plane = sketches[index].plane.transformed(by: transform) else { return nil }
        var result = self
        var movedID = id
        if copy {
            movedID = UUID()
            result.sketches.insert(Sketch(id: movedID, plane: plane), at: index + 1)
            result.shapes += shapes(in: id).map { shape in
                var duplicate = shape
                duplicate.id = UUID()
                duplicate.sketch = movedID
                duplicate.plane = plane
                return duplicate
            }
        } else {
            result.sketches[index].plane = plane
            for i in result.shapes.indices where result.shapes[i].sketch == id { result.shapes[i].plane = plane }
        }
        return result.isValid ? (result, movedID) : nil
    }
}

/// What the Move/Rotate widget moves: a whole sketch, a whole solid, or one shape within its
/// sketch (October 21, 2026).
enum TransformTarget: Hashable, Sendable {
    case sketch(UUID), body(UUID), shape(UUID)
}

extension SolidBody {
    /// The same solid carried by a rigid motion. Every plane in its definition moves (its profile,
    /// each cut, join, hole, face extrusion, and merged or subtracted solid); fillets, chamfers, shell faces, and
    /// face extrusions are named relative to those planes, so they follow without change.
    func transformed(by transform: RigidTransform) -> SolidBody? {
        guard let plane = profile.plane.transformed(by: transform) else { return nil }
        var result = self
        result.profile.plane = plane
        for index in cuts.indices {
            guard let cutPlane = cuts[index].profile.plane.transformed(by: transform) else { return nil }
            result.cuts[index].profile.plane = cutPlane
            if let merged = cuts[index].merged {
                guard let moved = merged.transformed(by: transform) else { return nil }
                result.cuts[index].merged = moved
            }
            if let subtracted = cuts[index].subtracted {
                guard let moved = subtracted.transformed(by: transform) else { return nil }
                result.cuts[index].subtracted = moved
            }
            if let intersected = cuts[index].intersected {
                guard let moved = intersected.transformed(by: transform) else { return nil }
                result.cuts[index].intersected = moved
            }
        }
        return result
    }
}

extension Workspace {
    /// The middle of a solid's bounding box, in world millimeters (where the widget sits).
    func center(of body: SolidBody) -> SIMD3<Double>? {
        guard let bounds = try? SolidKernel.solid(for: body).bounds else { return nil }
        return (bounds.min + bounds.max) / 2
    }

    /// Moves or turns a solid, or (with `copy`) a copy of it, leaving the original in place.
    /// Returns the result and the id of the solid that moved; nil if it no longer builds.
    func transformingBody(_ id: UUID, by transform: RigidTransform, copy: Bool) -> (workspace: Workspace, bodyID: UUID)? {
        guard let index = bodies.firstIndex(where: { $0.id == id }), var moved = bodies[index].transformed(by: transform) else { return nil }
        var result = self
        if copy {
            moved.id = UUID()
            result.bodies.insert(moved, at: index + 1)
        } else {
            result.bodies[index] = moved
        }
        SolidCache.shared.seed(moved, from: bodies[index], by: transform)
        guard result.isValid, (try? SolidKernel.solid(for: moved)) != nil else { return nil }
        return (result, moved.id)
    }

    /// Moves or turns a sketch or a solid (or a copy), returning what moved.
    func transforming(_ target: TransformTarget, by transform: RigidTransform, copy: Bool) -> (workspace: Workspace, target: TransformTarget)? {
        switch target {
        case .sketch(let id): transformingSketch(id, by: transform, copy: copy).map { ($0.workspace, .sketch($0.sketchID)) }
        case .body(let id): transformingBody(id, by: transform, copy: copy).map { ($0.workspace, .body($0.bodyID)) }
        case .shape(let id): transformingShape(id, by: transform, copy: copy).map { ($0.workspace, .shape($0.shapeID)) }
        }
    }

    /// The middle of a shape's extent, in world millimeters.
    func center(of shape: SketchShape) -> SIMD3<Double>? {
        let points = shape.outline
        guard let first = points.first else { return nil }
        let low = points.reduce(first) { Point2(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
        let high = points.reduce(first) { Point2(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
        return shape.plane.point((low + high) * 0.5)
    }

    /// Moves or turns one shape within its sketch (only along the sketch and about its normal), or
    /// a copy of it. A rectangle turned off square becomes its four lines (the first moves on).
    func transformingShape(_ id: UUID, by transform: RigidTransform, copy: Bool) -> (workspace: Workspace, shapeID: UUID)? {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else { return nil }
        let shape = shapes[index], plane = shape.plane, normal = plane.normalAxis
        // The motion as seen in the sketch: a turn about its normal and a move along it.
        let angle = transform.rotation.angle, axis = transform.rotation.axis
        guard abs(angle) < 1e-12 || abs(abs(simd_dot(axis, normal)) - 1) < 1e-9 else { return nil }
        let degrees = abs(angle) < 1e-12 ? 0 : angle * 180 / .pi * (simd_dot(axis, normal) > 0 ? 1 : -1)
        // p ↦ pivot + R(p − pivot) + translation: in the sketch, a turn about the pivot and a move.
        guard abs(simd_dot(transform.translation, normal)) < 1e-6 else { return nil }
        let pivot = plane.coordinates(of: transform.pivot), offset = plane.coordinates(of: plane.origin + transform.translation)
        var pieces: [SketchShape]
        if let single = SketchTools.transformed(shape, by: offset, turning: degrees, about: pivot) { pieces = [single] }
        else { pieces = shape.exploded.compactMap { SketchTools.transformed($0, by: offset, turning: degrees, about: pivot) } }
        guard !pieces.isEmpty else { return nil }
        var result = self
        if copy {
            pieces = pieces.map { var piece = $0; piece.id = UUID(); return piece }
            result.shapes.insert(contentsOf: pieces, at: index + 1)
        } else {
            result.shapes.replaceSubrange(index...index, with: pieces)
        }
        return result.isValid ? (result, pieces[0].id) : nil
    }
}

/// Where a solid's Move/Rotate widget sits and turns about once its center is dragged onto the
/// solid: a corner, any point on an edge, an edge's midpoint, a circle's
/// center, a face's center, or back to the middle of the solid.
struct TransformPivot: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Pattern's gizmo center can also go to the origin or a sketch point (an end or center).
        case center, corner, midpoint, edge, circleCenter, faceCenter, origin, point
        var title: String {
            switch self {
            case .center: "Center"
            case .origin: "Origin"
            case .point: "Point"
            case .corner: "Corner"
            case .midpoint: "Midpoint"
            case .edge: "On edge"
            case .circleCenter: "Circle center"
            case .faceCenter: "Face center"
            }
        }
    }
    var kind: Kind
    var point: SIMD3<Double>
    /// The edge's direction, a circle's axis, or a face's normal, which one widget axis turns to
    /// follow; nil keeps the solid's own axes.
    var direction: SIMD3<Double>?

    /// The widget axes for this pivot: the solid's own `axes` (x, y, normal; right-handed), with the
    /// one closest to `direction` turned onto it and the others squared up around it, so turning
    /// about that axis hinges the solid on the edge or spins it about the circle.
    func axes(from axes: [SIMD3<Double>]) -> [SIMD3<Double>] {
        guard let direction, axes.count == 3, simd_length(direction) > 1e-9 else { return axes }
        let d = simd_normalize(direction)
        let i = (0..<3).max { abs(simd_dot(axes[$0], d)) < abs(simd_dot(axes[$1], d)) }!
        var result = axes
        result[i] = simd_dot(axes[i], d) < 0 ? -d : d
        let j = (i + 1) % 3, k = (i + 2) % 3
        result[j] = simd_normalize(axes[j] - result[i] * simd_dot(axes[j], result[i]))
        result[k] = simd_cross(result[i], result[j])
        return result
    }

    /// The places a solid's widget center snaps to: the middle of its bounding box, the corners
    /// and midpoints of its `edges` (visible borders), the centers of its circular edges and flat
    /// faces, and each edge as points along it (exact ends for straight edges) for any-point snapping.
    static func snaps(of solid: KernelSolid, edges: [Int]) -> (points: [TransformPivot], edges: [[SIMD3<Double>]]) {
        let bounds = solid.bounds
        var points = [TransformPivot(kind: .center, point: (bounds.min + bounds.max) / 2)]
        points += AlignFeature.corners(of: solid, edges: edges).map { TransformPivot(kind: .corner, point: $0) }
        var lines: [[SIMD3<Double>]] = []
        func add(_ pivot: TransformPivot) {
            if !points.contains(where: { simd_distance($0.point, pivot.point) < 1e-6 }) { points.append(pivot) }
        }
        for edge in edges {
            switch Projection.curve(of: solid, edge: edge) {
            case .segment(let a, let b):
                add(TransformPivot(kind: .midpoint, point: (a + b) / 2, direction: b - a))
                lines.append([a, b])
            case .circle(let center, let axis, _):
                add(TransformPivot(kind: .circleCenter, point: center, direction: axis))
                lines.append(solid.edgeSamples(edge, count: 65))
            case .arc(let center, let axis, _, let mid, _):
                add(TransformPivot(kind: .circleCenter, point: center, direction: axis))
                add(TransformPivot(kind: .midpoint, point: mid, direction: simd_cross(axis, mid - center)))
                lines.append(solid.edgeSamples(edge, count: 65))
            case .polyline(let samples, let closed):
                lines.append(closed ? samples + samples.prefix(1) : samples)
            case .rectangle, nil:
                break
            }
        }
        for face in 0..<solid.faceCount {
            guard let plane = solid.facePlane(face), let center = solid.faceCenter(face) else { continue }
            add(TransformPivot(kind: .faceCenter, point: center, direction: plane.normal))
        }
        return (points, lines)
    }
}
