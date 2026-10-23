import Foundation
import simd

/// Split Body (schema 11): which piece of a split solid this is. A split solid becomes several
/// solids, each the original definition plus one `split` entry in its ordered `cuts` list that
/// keeps only its piece: the side of `profile.plane` its normal points to (`front`), the other
/// side (`back`), or the inside of `profile`'s through-all prism (`inside`; the outside piece is
/// an ordinary through-all cut). Nothing is removed: the pieces add up to the original.
struct SplitSpec: Codable, Equatable, Sendable {
    enum Keep: String, Codable, Sendable { case front, back, inside }
    var keep: Keep
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
    /// side of the plane that covers the whole solid) or with a through-all prism.
    static func applySplit(_ operation: ExtrusionCut, to solid: KernelSolid) throws -> KernelSolid {
        guard let split = operation.split else { throw Failure(message: "Missing split") }
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

extension SolidBody {
}
