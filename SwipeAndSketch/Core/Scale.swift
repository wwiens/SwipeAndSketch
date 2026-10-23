import Foundation
import simd

/// Scale (Transform ▸ Scale, October 21, 2026): solids and sketches made larger or smaller about a
/// point, by one factor or (solids only) by a factor along each of three axes. A solid keeps a
/// scale step in its `cuts` list: everything built before it is scaled, steps added later are not.
/// Its center and axes are in the solid's own frame (see `SolidBody.localPoint`), so they follow
/// the solid when it moves.
struct ScaleSpec: Codable, Equatable, Sendable {
    var center: SIMD3<Double>
    var xAxis: SIMD3<Double>
    var yAxis: SIMD3<Double>
    /// Along the x axis, the y axis, and their cross product; 1 leaves that direction alone.
    var factors: SIMD3<Double>
    static let factorRange = 0.001...1000.0

    var isUniform: Bool { factors.x == factors.y && factors.y == factors.z }
    var isValid: Bool {
        [factors.x, factors.y, factors.z].allSatisfy(Self.factorRange.contains) && center.x.isFinite && center.y.isFinite && center.z.isFinite &&
            abs(simd_length(xAxis) - 1) < 1e-6 && abs(simd_length(yAxis) - 1) < 1e-6 && abs(simd_dot(xAxis, yAxis)) < 1e-6
    }
    /// The same scale seen in a frame whose y axis is flipped (a mirror image of the solid).
    var mirrored: ScaleSpec {
        ScaleSpec(center: SIMD3(center.x, -center.y, center.z), xAxis: SIMD3(xAxis.x, -xAxis.y, xAxis.z),
                  yAxis: SIMD3(yAxis.x, -yAxis.y, yAxis.z), factors: factors)
    }
}

extension ExtrusionCut {
    /// Scale everything `body` has so far (the placeholder profile is the body's own).
    static func scale(_ spec: ScaleSpec, of body: SolidBody) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.scale = spec
        return operation
    }
}

extension SolidBody {
    /// A direction in this solid's own frame, and back.
    func localVector(_ world: SIMD3<Double>) -> SIMD3<Double> {
        let plane = profile.plane
        return SIMD3(simd_dot(world, plane.xAxis), simd_dot(world, plane.yAxis), simd_dot(world, plane.normalAxis))
    }
    func worldVector(_ local: SIMD3<Double>) -> SIMD3<Double> {
        let plane = profile.plane
        return plane.xAxis * local.x + plane.yAxis * local.y + plane.normalAxis * local.z
    }

    /// How much the solid's own extrusion or revolve has been scaled since (the product of every
    /// uniform scale step), or nil when a step stretched it unevenly: its depth and profile sizes
    /// then no longer read as one number.
    var baseScale: Double? { scaleFactor(after: -1) }

    /// The uniform factor of the scale steps after step `index` of `cuts` (−1: all of them), or nil
    /// when one of them is not uniform.
    func scaleFactor(after index: Int) -> Double? {
        var factor = 1.0
        for cut in cuts.dropFirst(index + 1) {
            guard let spec = cut.scale else { continue }
            guard spec.isUniform else { return nil }
            factor *= spec.factors.x
        }
        return factor
    }
}

extension SolidKernel {
    static func applyScale(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let spec = operation.scale else { throw Failure(message: "Missing scale") }
        return try scaled(solid, about: body.worldPoint(spec.center), axes: [body.worldVector(spec.xAxis), body.worldVector(spec.yAxis)],
                          factors: spec.factors)
    }
}

extension SketchShape {
    /// The shape with its sketch coordinates multiplied by `factor` (about the sketch's own origin).
    func scaled(by factor: Double) -> SketchShape {
        var result = self
        result.start = start * factor
        result.end = end * factor
        result.arcCenter = arcCenter.map { $0 * factor }
        result.points = points?.map { $0 * factor }
        result.width = width.map { $0 * factor }
        return result
    }
}

/// Scale: solids and sketches about one center.
enum Scaling {
    /// Scales the solids and sketches about `center` by `factors` along `axes` (x and y, in world
    /// millimeters; the third is their cross product). Sketches scale only by one factor. With
    /// `copy`, the originals stay and scaled copies follow them. Nil when anything cannot be scaled.
    static func scale(_ workspace: Workspace, bodies: [UUID], sketches: [UUID], about center: SIMD3<Double>, axes: [SIMD3<Double>],
                      factors: SIMD3<Double>, copy: Bool) -> (workspace: Workspace, bodies: [UUID], sketches: [UUID])? {
        guard !(bodies.isEmpty && sketches.isEmpty), axes.count >= 2,
              [factors.x, factors.y, factors.z].allSatisfy(ScaleSpec.factorRange.contains) else { return nil }
        let uniform = factors.x == factors.y && factors.y == factors.z
        guard sketches.isEmpty || uniform else { return nil }
        var result = workspace
        var madeBodies: [UUID] = [], madeSketches: [UUID] = []
        for id in bodies {
            guard let index = result.bodies.firstIndex(where: { $0.id == id }) else { return nil }
            var body = result.bodies[index]
            let spec = ScaleSpec(center: body.localPoint(center), xAxis: simd_normalize(body.localVector(axes[0])),
                                 yAxis: simd_normalize(body.localVector(axes[1])), factors: factors)
            guard spec.isValid, body.cuts.count < ExtrusionCut.maximumPerBody else { return nil }
            body.cuts.append(.scale(spec, of: body))
            guard body.isValid, (try? SolidKernel.solid(for: body)) != nil else { return nil }
            if copy {
                body.id = UUID()
                body.hidden = nil
                result.bodies.insert(body, at: index + 1)
            } else {
                result.bodies[index] = body
            }
            madeBodies.append(body.id)
        }
        for id in sketches {
            guard let index = result.sketches.firstIndex(where: { $0.id == id }) else { return nil }
            let factor = factors.x, old = result.sketches[index].plane
            var plane = old
            plane.origin = (center + (old.origin - center) * factor).roundedOff()
            let shapes = result.shapes.filter { $0.sketch == id }.map { shape -> SketchShape in
                var scaled = shape.scaled(by: factor)
                scaled.plane = plane
                return scaled
            }
            guard shapes.allSatisfy(\.isValid) else { return nil }
            if copy {
                let sketchID = UUID()
                result.sketches.insert(Sketch(id: sketchID, plane: plane), at: index + 1)
                result.shapes += shapes.map { var shape = $0; shape.id = UUID(); shape.sketch = sketchID; return shape }
                madeSketches.append(sketchID)
            } else {
                result.sketches[index].plane = plane
                for shape in shapes { if let i = result.shapes.firstIndex(where: { $0.id == shape.id }) { result.shapes[i] = shape } }
                madeSketches.append(id)
            }
        }
        return result.isValid ? (result, madeBodies, madeSketches) : nil
    }

    /// The box around the solids and sketches, in world millimeters.
    static func bounds(of workspace: Workspace, bodies: [UUID], sketches: [UUID]) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var points: [SIMD3<Double>] = []
        for id in bodies {
            guard let body = workspace.bodies.first(where: { $0.id == id }), let solid = try? SolidKernel.solid(for: body) else { continue }
            points += [solid.bounds.min, solid.bounds.max]
        }
        for id in sketches {
            guard let sketch = workspace.sketch(id) else { continue }
            points += workspace.shapes(in: id).flatMap(\.outline).map { sketch.plane.point($0) }
        }
        guard let first = points.first else { return nil }
        return (points.reduce(first) { simd_min($0, $1) }, points.reduce(first) { simd_max($0, $1) })
    }
}
