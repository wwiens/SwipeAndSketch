import Foundation
import SSKernel
import simd

// Delete Hole (October 21, 2026): a hole goes away by taking the step that made it out of the
// solid's definition, so the solid is exactly what it was before the hole, not patched over. A hole
// is made by a Hole-tool entry, an extruded cut, or a circle drawn inside the outline the solid (or
// a joined boss) was extruded from. A thread cut into the hole goes with it, and fillets or
// chamfers on its rim are left off. Holes no step made (in imported shapes, or left by unions and
// subtracts) are for Delete Face.

/// What Delete Hole takes out of a solid, and the solid without it.
struct HoleRemoval: Sendable {
    enum Source: Equatable, Sendable {
        /// An entry of `cuts`: a Hole-tool hole or an extruded cut.
        case cut(Int)
        /// A hole in the outline of the solid itself (`entry` nil) or of a joined boss.
        case outlineHole(entry: Int?, hole: Int)
    }
    var source: Source
    var body: SolidBody
    /// Threads cut into the hole, also taken out.
    var threads = 0
    /// Rim fillets and chamfers left off (edges, across all of them).
    var finishedEdges = 0
}

extension SolidBody {
    /// The solid without the hole around `probe`, a world point in the hole's empty space (on its
    /// axis, say), or nil when no step of this solid made a hole there. The newest step that made
    /// one wins: a hole drilled out bigger loses the bigger cut first.
    func removingHole(around probe: SIMD3<Double>) -> HoleRemoval? {
        guard let solid = try? SolidKernel.solid(for: self), !Self.isInside(probe, solid) else { return nil }
        for source in holeSources {
            guard let removed = removing(source) else { continue }
            var result = HoleRemoval(source: source, body: removed)
            // Later threads in this hole would cut it again: they go too. (Taking out a cut entry
            // moves the entries after it down one.)
            let (first, shift): (Int, Int) = switch source {
            case .cut(let index): (index + 1, 1)
            case .outlineHole(let entry, _): ((entry ?? -1) + 1, 0)
            }
            for thread in cuts.indices.reversed() where thread >= first && cuts[thread].thread?.isInternal == true {
                guard let spec = cuts[thread].thread else { continue }
                let middle = worldPoint(spec.origin + spec.axis * (spec.length / 2))
                let without = Self.dropping(thread - shift, from: result.body)
                let check = Self.droppingMissingFinishEdges(without)?.body ?? without
                guard (try? SolidKernel.solid(for: check)).map({ Self.isInside(middle, $0) }) == true else { continue }
                result.body = without
                result.threads += 1
            }
            guard let cleaned = Self.droppingMissingFinishEdges(result.body) else { continue }
            result.finishedEdges = cleaned.dropped
            result.body = cleaned.body
            guard let built = try? SolidKernel.solid(for: result.body), Self.isInside(probe, built) else { continue }
            return result
        }
        return nil
    }

    /// Steps that can have made a hole, newest first.
    private var holeSources: [HoleRemoval.Source] {
        var sources: [HoleRemoval.Source] = []
        for index in cuts.indices.reversed() {
            let cut = cuts[index]
            switch cut.operation {
            case .cut, .hole: sources.append(.cut(index))
            case .join: sources += (cut.profile.holes ?? []).indices.map { .outlineHole(entry: index, hole: $0) }
            default: break
            }
        }
        if revolve == nil, imported == nil { sources += (profile.holes ?? []).indices.map { .outlineHole(entry: nil, hole: $0) } }
        return sources
    }

    private func removing(_ source: HoleRemoval.Source) -> SolidBody? {
        var result = self
        switch source {
        case .cut(let index):
            result = Self.dropping(index, from: self)
        case .outlineHole(let entry, let hole):
            if let entry {
                guard var holes = cuts[entry].profile.holes, holes.indices.contains(hole) else { return nil }
                holes.remove(at: hole)
                result.cuts[entry].profile.holes = holes.isEmpty ? nil : holes
            } else {
                guard var holes = profile.holes, holes.indices.contains(hole) else { return nil }
                holes.remove(at: hole)
                result.profile.holes = holes.isEmpty ? nil : holes
            }
        }
        return result.isValid ? result : nil
    }

    private static func dropping(_ index: Int, from body: SolidBody) -> SolidBody {
        var result = body
        result.cuts.remove(at: index)
        return result
    }

    /// The solid with fillet and chamfer steps kept to the edges it still has where they come (a
    /// step left with none is dropped), and how many edges were left off; nil when it still fails.
    private static func droppingMissingFinishEdges(_ body: SolidBody) -> (body: SolidBody, dropped: Int)? {
        if (try? SolidKernel.solid(for: body)) != nil { return (body, 0) }
        var result = body, dropped = 0, index = 0
        while index < result.cuts.count {
            guard var spec = result.cuts[index].finish else { index += 1; continue }
            var before = result
            before.cuts = Array(result.cuts[..<index])
            guard let solid = try? SolidKernel.solid(for: before) else { return nil }
            let kept = spec.edges.filter { solid.edge(near: result.worldPoint(of: $0)) != nil }
            dropped += spec.edges.count - kept.count
            if kept.isEmpty {
                result.cuts.remove(at: index)
                continue
            }
            spec.edges = kept
            result.cuts[index].finish = spec
            index += 1
        }
        return (try? SolidKernel.solid(for: result)) != nil ? (result, dropped) : nil
    }

    private static func isInside(_ point: SIMD3<Double>, _ solid: KernelSolid) -> Bool {
        ssk_point_inside(solid.handle, SSKVec3(x: point.x, y: point.y, z: point.z))
    }
}

extension KernelSolid {
    /// A point in the empty space a hole's wall surrounds, level with `point` on the wall: on the
    /// wall's axis. Nil unless `face` is a hole's round wall.
    func holeProbe(face: Int, near point: SIMD3<Double>) -> SIMD3<Double>? {
        guard cylinderSide(face) == -1, let cylinder = faceCylinder(face) else { return nil }
        let axis = simd_normalize(cylinder.direction)
        return cylinder.point + axis * simd_dot(point - cylinder.point, axis)
    }

    /// Points on the faces of the hole whose wall is `face`, for Delete Face: its round walls on
    /// the same axis (a solid from a STEP file may split one in halves) and floors across it.
    func holeFacePoints(wall face: Int) -> [SIMD3<Double>] {
        guard cylinderSide(face) == -1, let wall = faceCylinder(face) else { return [] }
        let axis = simd_normalize(wall.direction)
        func offAxis(_ p: SIMD3<Double>) -> SIMD3<Double> { let d = p - wall.point; return d - axis * simd_dot(d, axis) }
        var points: [SIMD3<Double>] = []
        var widest = wall.radius
        for candidate in 0..<faceCount where cylinderSide(candidate) == -1 {
            guard let cylinder = faceCylinder(candidate), abs(abs(simd_dot(simd_normalize(cylinder.direction), axis)) - 1) < 1e-6,
                  simd_length(offAxis(cylinder.point)) < 1e-4 else { continue }
            // Midway up the wall, beside the middle of one of its edges.
            let samples = faceEdges(candidate).flatMap { edgeSamples($0, count: 9) }
            guard let low = samples.map({ simd_dot($0 - wall.point, axis) }).min(), let high = samples.map({ simd_dot($0 - wall.point, axis) }).max(),
                  let side = samples.map(offAxis).first(where: { simd_length($0) > 1e-6 }) else { continue }
            points.append(wall.point + axis * ((low + high) / 2) + simd_normalize(side) * cylinder.radius)
            widest = max(widest, cylinder.radius)
        }
        // A blind hole's floor: a flat face across the axis, inside the hole.
        for candidate in 0..<faceCount {
            guard let plane = facePlane(candidate), abs(abs(simd_dot(plane.normal, axis)) - 1) < 1e-6,
                  let outline = faceOutline(candidate)?.points, !outline.isEmpty,
                  outline.allSatisfy({ simd_length(offAxis($0)) <= widest + 1e-4 }), let center = faceCenter(candidate) else { continue }
            points.append(center)
        }
        return points
    }
}
