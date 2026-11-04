import Foundation
import SSKernel
import simd

/// Split Body (schema 11): which piece of a split solid this is. A split solid becomes several
/// solids, each the original definition plus one `split` entry in its ordered `cuts` list that
/// keeps only its piece: the side of `profile.plane` its normal points to (`front`), the other
/// side (`back`), or the inside of `profile`'s through-all prism (`inside`; the outside piece is
/// an ordinary through-all cut). Nothing is removed: the pieces add up to the original.
///
/// `piece` (October 24, 2026): a cut, subtract, intersect, hole, or split that leaves a solid in
/// separate pieces makes each piece its own solid, keeping the piece `point` is inside (a point in
/// the solid's own frame, like a finish's edge points). See `Workspace.separatingPieces(since:)`.
struct SplitSpec: Codable, Equatable, Sendable {
    enum Keep: String, Codable, Sendable { case front, back, inside, piece }
    var keep: Keep
    var point: SIMD3<Double>?

    var isValid: Bool {
        guard keep == .piece else { return point == nil }
        guard let point else { return false }
        return [point.x, point.y, point.z].allSatisfy(\.isFinite) && simd_length(point) <= 200_000
    }
}

/// Something a solid is split with (Split Body's Splitting Tools): an infinite plane (a construction
/// plane, a world plane, a flat face of any solid including the one being split, or the plane a
/// sketch line sweeps along its sketch's normal), or a sketch region swept straight through.
struct SplitTool: Equatable, Sendable {
    enum Source: Hashable, Sendable { case face(UUID, Int), plane(UUID), world(SketchPlane), profile(String), line(UUID) }
    var source: Source
    /// The cutting plane (normal `plane.normalAxis`), or the region's own plane for a region.
    var plane: SketchPlane
    /// A region splits along its outline instead of a plane.
    var profile: SketchProfile?

    /// A flat face, construction plane, or world plane splits along its whole plane; a sketch
    /// region splits along its outline, through everything.
    static func reference(_ reference: PlaneReference, in workspace: Workspace) -> SplitTool? {
        switch reference.source {
        case .face(let body, let face):
            return SketchPlane.through(reference.origin, normal: reference.normal).map { SplitTool(source: .face(body, face), plane: $0) }
        case .plane(let id):
            return workspace.constructionPlanes.first { $0.id == id }.map { SplitTool(source: .plane(id), plane: $0.plane) }
        case .world(let plane):
            return SplitTool(source: .world(plane), plane: plane)
        case .profile(let id):
            guard let profile = workspace.sketches.lazy.flatMap({ workspace.profiles(in: $0) }).first(where: { $0.id == id }) else { return nil }
            return SplitTool(source: .profile(id), plane: profile.plane, profile: profile)
        }
    }

    /// A sketch line: the plane through it, square to its sketch.
    static func line(_ shape: SketchShape) -> SplitTool? {
        guard shape.kind == .line, shape.isValid else { return nil }
        let a = shape.plane.point(shape.start), b = shape.plane.point(shape.end)
        let normal = simd_cross(b - a, shape.plane.normalAxis)
        return SketchPlane.through(a, normal: normal).map { SplitTool(source: .line(shape.id), plane: $0) }
    }

    /// One operation per piece this tool cuts a solid into.
    var operations: [ExtrusionCut] {
        if let profile {
            var inside = ExtrusionCut(profile: profile, depth: 1, throughAll: true)
            inside.split = SplitSpec(keep: .inside)
            return [inside, ExtrusionCut(profile: profile, depth: 1, throughAll: true)]
        }
        // The profile only carries the plane; the kernel tool covers the whole solid when built.
        let square = [Point2(x: -5, y: -5), Point2(x: 5, y: -5), Point2(x: 5, y: 5), Point2(x: -5, y: 5)]
        let placeholder = SketchProfile(id: "split", plane: plane, sourceIDs: [], outline: square)
        return [SplitSpec.Keep.front, .back].map { keep in
            var operation = ExtrusionCut(profile: placeholder, depth: 1)
            operation.split = SplitSpec(keep: keep)
            return operation
        }
    }
}

enum Splitting {
    /// The pieces `body` splits into with every tool in turn; a tool that does not cross a piece
    /// leaves it whole. Nil when no tool divides the solid. Pieces get new ids.
    static func pieces(of body: SolidBody, with tools: [SplitTool]) -> [SolidBody]? {
        var pieces = [body]
        var divided = false
        for tool in tools {
            var next: [SolidBody] = []
            for piece in pieces {
                let parts = tool.operations.compactMap { operation -> SolidBody? in
                    var part = piece
                    part.cuts.append(operation)
                    guard part.isValid, let solid = try? SolidKernel.solid(for: part), solid.volume > 1e-6 else { return nil }
                    return part
                }
                if parts.count >= 2 { next += parts; divided = true } else { next.append(piece) }
            }
            pieces = next
        }
        guard divided else { return nil }
        return pieces.map { var piece = $0; piece.id = UUID(); piece.hidden = nil; return piece }
    }
}

extension SolidKernel {
    /// Keeps the piece a split entry names: the solid intersected with a half-space (a box on one
    /// side of the plane that covers the whole solid) or with a through-all prism, or the separate
    /// piece its point is inside.
    static func applySplit(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let split = operation.split else { throw Failure(message: "Missing split") }
        if split.keep == .piece {
            // Whole again (an edit joined the pieces): nothing to choose.
            guard let local = split.point, solid.pieceCount > 1 else { return solid }
            let point = body.worldPoint(local)
            let pieces = try (0..<solid.pieceCount).map(solid.piece)
            if let piece = pieces.first(where: { $0.contains(point) }) { return piece }
            // An edit moved the piece off its point: the piece whose box is nearest.
            return pieces.min { a, b in
                simd_distance((a.bounds.min + a.bounds.max) / 2, point) < simd_distance((b.bounds.min + b.bounds.max) / 2, point)
            }!
        }
        let tool: KernelSolid
        if split.keep == .inside {
            var prism = operation
            prism.split = nil
            tool = try SolidKernel.tool(for: prism, through: solid)
        } else {
            let plane = operation.profile.plane, bounds = solid.bounds
            var corners: [SIMD3<Double>] = []
            for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                corners.append(SIMD3(x, y, z))
            } } }
            let local = corners.map(plane.coordinates(of:))
            let low = local.reduce(Point2(x: .infinity, y: .infinity)) { Point2(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
            let high = local.reduce(Point2(x: -.infinity, y: -.infinity)) { Point2(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
            let reach = corners.map { abs(plane.height(of: $0)) }.max() ?? 0
            guard reach > 1e-9 else { throw Failure(message: "Nothing on that side of the plane") }
            let margin = 1 + 0.1 * max(high.x - low.x, high.y - low.y)
            let square = [Point2(x: low.x - margin, y: low.y - margin), Point2(x: high.x + margin, y: low.y - margin),
                          Point2(x: high.x + margin, y: high.y + margin), Point2(x: low.x - margin, y: high.y + margin)]
            let side = SketchProfile(id: "split", plane: plane, sourceIDs: [], outline: square)
            tool = try extrude(side, depth: (reach + 1) * (split.keep == .front ? 1 : -1))
        }
        let result = try boolean(solid, tool, .intersect)
        guard result.volume > 1e-9 else { throw Failure(message: "Nothing of the solid is on that side") }
        return result
    }
}

extension KernelSolid {
    /// How many separate solids this shape is: a cut can leave several.
    var pieceCount: Int { Int(ssk_solid_count(handle)) }

    func piece(_ index: Int) throws -> KernelSolid {
        guard let pointer = ssk_solid(handle, Int32(index)) else {
            throw SolidKernel.Failure(message: ssk_last_error().map { String(cString: $0) } ?? "A piece could not be read")
        }
        return KernelSolid(adopting: pointer)
    }

    /// Whether `point` is strictly inside.
    func contains(_ point: SIMD3<Double>) -> Bool { ssk_point_inside(handle, SSKVec3(x: point.x, y: point.y, z: point.z)) }

    /// A point strictly inside: the middle of the box when it is inside, else a point just under
    /// the surface at the middle of one of the largest facets.
    func interiorPoint() -> SIMD3<Double>? {
        let box = bounds, middle = (box.min + box.max) / 2
        if contains(middle) { return middle }
        guard let mesh = try? tessellate() else { return nil }
        let size = simd_reduce_max(box.max - box.min)
        var facets: [(center: SIMD3<Double>, normal: SIMD3<Double>, area: Double)] = []
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[t])]), b = SIMD3<Double>(mesh.positions[Int(mesh.indices[t + 1])])
            let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[t + 2])]), cross = simd_cross(b - a, c - a), length = simd_length(cross)
            guard length > 1e-12 else { continue }
            facets.append(((a + b + c) / 3, cross / length, length / 2))
        }
        for facet in facets.sorted(by: { $0.area > $1.area }).prefix(32) {
            for step in [1e-3, 1e-4, 1e-5].map({ $0 * max(size, 1) }) {
                for point in [facet.center - facet.normal * step, facet.center + facet.normal * step] where contains(point) { return point }
            }
        }
        return nil
    }
}

extension Workspace {
    /// Removal steps that can leave a solid in separate pieces.
    private static let separating: Set<ExtrusionCut.Operation> = [.cut, .subtract, .intersect, .hole, .split]

    /// This workspace with every solid that a cut, subtract, intersect, hole, or split since `old`
    /// left in separate pieces divided into one solid per piece (October 24, 2026). Each piece is
    /// the solid's definition plus a `piece` step; the largest keeps the solid's id, name, and
    /// place, and the others follow after the last solid with the same color, group, and name.
    /// Also returns the new solids' ids by the solid they came from.
    func separatingPieces(since old: Workspace) -> (workspace: Workspace, added: [UUID: [UUID]]) {
        let oldSteps = Dictionary(old.bodies.flatMap { body in body.cuts.map { ($0.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let oldBodies = Dictionary(old.bodies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = self, added: [UUID: [UUID]] = [:], appended: [SolidBody] = []
        for (index, body) in bodies.enumerated() {
            // Moving or turning a solid changes its steps' planes but cannot divide it.
            if let before = oldBodies[body.id], before.profile.plane != body.profile.plane { continue }
            let changed = body.cuts.contains { step in Self.separating.contains(step.operation) && oldSteps[step.id] != step }
            guard changed, let solid = try? SolidKernel.solid(for: body), solid.pieceCount > 1,
                  let pieces = try? (0..<solid.pieceCount).map(solid.piece) else { continue }
            var parts: [(body: SolidBody, volume: Double)] = []
            for piece in pieces {
                guard let point = piece.interiorPoint() else { parts = []; break }
                var part = body
                var step = ExtrusionCut(profile: body.profile, depth: 1)
                step.split = SplitSpec(keep: .piece, point: body.localPoint(point))
                part.cuts.append(step)
                guard part.isValid else { parts = []; break }
                parts.append((part, piece.volume))
            }
            guard parts.count > 1 else { continue }
            parts.sort { $0.volume > $1.volume }
            result.bodies[index] = parts[0].body
            for var part in parts.dropFirst().map(\.body) {
                part.id = UUID()
                appended.append(part)
                added[body.id, default: []].append(part.id)
            }
        }
        result.bodies += appended
        return (result, added)
    }
}
