import Foundation
import simd

/// A sketch profile extruded and either subtracted from a solid (a hole, pocket, or slot) or
/// joined to it (a boss). Each affected solid keeps its own copy, so solids stay independent of
/// sketches and of each other. A solid's `cuts` list holds both kinds, in the order they were made.
struct ExtrusionCut: Codable, Equatable, Identifiable, Sendable {
    /// cut and join extrude `profile`; merge, shell, and hole carry their own payload (schema 6).
    enum Operation: String, Codable, Sendable { case cut, join, merge, shell, hole, split, subtract, finish, thread, text, intersect, scale, deleteFace, offsetFace }

    var id = UUID()
    var profile: SketchProfile
    /// Signed millimeters along the profile plane's normal. Ignored when `throughAll` is set.
    var depth: Double
    /// Cut through the whole solid in both directions from the sketch plane (cuts only).
    var throughAll = false
    /// Omitted for cuts, so files without joins encode exactly as schema 3/4 did.
    var join: Bool?
    /// Merge: another solid's whole definition, unioned into this one (see MoreOperations.swift).
    var merged: SolidBody?
    /// Shell: hollow the solid, leaving the named faces open.
    var shell: ShellSpec?
    /// Hole: a drilled hole (simple, counterbore, countersink, or insert) at the profile's circle.
    var hole: HoleSpec?
    /// Split (schema 11): keep only one piece of the solid (see Split.swift).
    var split: SplitSpec?
    /// Subtract (schema 12): another solid's whole definition, removed from this one.
    var subtracted: SolidBody?
    /// Intersect: another solid's whole definition; only where the two overlap is kept.
    var intersected: SolidBody?
    /// Scale: everything built so far, scaled about a point (Scale.swift).
    var scale: ScaleSpec?
    /// Delete Face: faces taken off and the gap closed (FaceEdits.swift).
    var removedFaces: FaceRemovalSpec?
    /// Offset Face: faces moved along their normals (FaceEdits.swift).
    var movedFaces: FaceOffsetSpec?
    /// Subtract only: the tool is grown by this many millimeters first, so the part it leaves room
    /// for fits once printed (see Fit.swift). Omitted for an exact subtract.
    var clearance: Double?
    /// Finish (schema 16): a fillet or chamfer on edges the solid has at this point (EdgeFinishes.swift).
    var finish: FinishSpec?
    /// Thread: a modeled screw thread on a hole or round boss (Threads.swift).
    var thread: ThreadSpec?
    /// Text: letters raised from (positive `depth`) or sunk into (negative) the face on `profile.plane` (Text.swift).
    var text: TextSpec?
    /// The solid a merge or subtract carries.
    var nestedSolid: SolidBody? { merged ?? subtracted ?? intersected }
    /// Face extrusion (schema 7): extrude the solid's own flat face on `profile.plane` that
    /// contains this point, instead of `profile` (see FaceExtrusion.swift).
    var facePoint: Point2?
    /// Extrude options (October 21, 2026): a cut or join extruded both ways from its sketch plane
    /// (`depth` in all), and its sides leaning in by `taper` degrees. Omitted otherwise.
    var symmetric: Bool?
    var taper: Double?
    static let taperRange = -89.0...89.0
    /// Revolve (schema 14): a join or cut whose tool is `profile` (or the face at `facePoint`)
    /// revolved about this axis instead of extruded. `depth` is then unused (see Revolve.swift).
    var revolve: RevolveSpec?
    static let maximumPerBody = 256

    init(id: UUID = UUID(), profile: SketchProfile, depth: Double, throughAll: Bool = false, operation: Operation = .cut) {
        self.id = id; self.profile = profile; self.depth = depth; self.throughAll = throughAll
        self.join = operation == .join ? true : nil
    }

    var operation: Operation {
        if merged != nil { return .merge }
        if subtracted != nil { return .subtract }
        if intersected != nil { return .intersect }
        if scale != nil { return .scale }
        if removedFaces != nil { return .deleteFace }
        if movedFaces != nil { return .offsetFace }
        if shell != nil { return .shell }
        if hole != nil { return .hole }
        if finish != nil { return .finish }
        if thread != nil { return .thread }
        if text != nil { return .text }
        if split != nil { return .split }
        return join == true ? .join : .cut
    }

    var isValid: Bool {
        let depthIsValid = depth.isFinite && abs(depth) >= 0.01 && abs(depth) <= 10_000
        if let clearance, subtracted == nil || !Fit.clearanceRange.contains(clearance) { return false }
        guard profile.isSolidProfile, [merged != nil, subtracted != nil, intersected != nil, scale != nil, removedFaces != nil, movedFaces != nil, shell != nil, hole != nil, join == true, split != nil, finish != nil, thread != nil, text != nil].filter({ $0 }).count <= 1 else { return false }
        if symmetric != nil || taper != nil {
            guard [.cut, .join].contains(operation), symmetric != false, facePoint == nil, revolve == nil, !throughAll,
                  Self.taperRange.contains(taper ?? 0) else { return false }
        }
        if let revolve {
            return [.cut, .join].contains(operation) && !throughAll && depth.isFinite && revolve.allows(profile) && (facePoint?.isValid ?? true)
        }
        if let facePoint {
            // Outward grows the solid; inward cuts it.
            return [.cut, .join].contains(operation) && facePoint.isValid && depthIsValid && !throughAll && (operation == .join) == (depth > 0)
        }
        switch operation {
        case .cut: return throughAll || depthIsValid
        case .join: return depthIsValid && !throughAll
        case .merge: return merged.map { $0.isValid && $0.nestingDepth < 16 } ?? false
        case .subtract: return subtracted.map { $0.isValid && $0.nestingDepth < 16 } ?? false
        case .intersect: return intersected.map { $0.isValid && $0.nestingDepth < 16 } ?? false
        case .scale: return scale?.isValid ?? false
        case .deleteFace: return removedFaces?.isValid ?? false
        case .offsetFace: return movedFaces?.isValid ?? false
        case .shell: return shell?.isValid ?? false
        case .hole: return (hole?.isValid ?? false) && profile.circle != nil && (throughAll || depthIsValid)
        case .split: return split?.keep == .inside ? throughAll : !throughAll && depthIsValid
        case .finish: return finish?.isValid ?? false
        case .thread: return thread?.isValid ?? false
        case .text: return (text?.isValid ?? false) && depthIsValid && !throughAll
        }
    }
}

extension SolidBody {
    var cutsAreValid: Bool { cuts.count <= ExtrusionCut.maximumPerBody && cuts.allSatisfy(\.isValid) }
}

extension SolidKernel {
    /// The solid for a document body: extrude (or revolve), then each finish in order, then each cut in order.
    /// Builds incrementally through `SolidCache`, so adding one cut only runs one boolean.
    static func solid(for body: SolidBody) throws -> KernelSolid { try SolidCache.shared.solid(for: body) }

    /// The tool a cut subtracts from `solid`. Through-all tools span the solid's extent on both sides.
    static func tool(for cut: ExtrusionCut, through solid: KernelSolid) throws -> KernelSolid {
        if let revolve = cut.revolve { return try revolveTool(for: cut, revolve, on: solid) }
        if cut.facePoint != nil { return try faceTool(for: cut, on: solid) }
        guard cut.throughAll else { return try extrude(cut.profile, depth: cut.depth, symmetric: cut.symmetric == true, taper: cut.taper ?? 0) }
        let frame = cut.profile.plane.frame, bounds = solid.bounds
        var reach = 0.0
        for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
            reach = max(reach, abs(simd_dot(SIMD3(x, y, z) - frame.origin, frame.normal)))
        } } }
        reach += 1
        return try extrude(cut.profile, depth: 2 * reach, offset: -reach)
    }

    static func apply(_ cut: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        switch cut.operation {
        case .merge: return try applyMerge(cut, to: solid)
        case .shell: return try applyShell(cut, to: solid, of: body)
        case .hole: return try applyHole(cut, to: solid)
        case .split: return try applySplit(cut, to: solid)
        case .subtract: return try applySubtract(cut, to: solid)
        case .intersect: return try applyIntersect(cut, to: solid)
        case .scale: return try applyScale(cut, to: solid, of: body)
        case .deleteFace: return try applyFaceRemoval(cut, to: solid, of: body)
        case .offsetFace: return try applyFaceOffset(cut, to: solid, of: body)
        case .finish: return try applyFinish(cut, to: solid, of: body)
        case .thread: return try applyThread(cut, to: solid, of: body)
        case .text: return try applyText(cut, to: solid)
        case .cut, .join: break
        }
        if cut.operation == .join {
            // A boss must touch or overlap the solid, leaving one connected solid.
            let result = try boolean(solid, try tool(for: cut, through: solid), .union)
            guard result.isValidSolid else { throw Failure(message: "The boss does not touch this solid") }
            return result
        }
        let result = try boolean(solid, try tool(for: cut, through: solid), .subtract)
        guard result.volume > 1e-9 else { throw Failure(message: "The cut would remove the whole solid") }
        return result
    }
}

/// Recently built kernel solids keyed by document body value. Each body is built from the
/// cached solid of the same body minus its last step, so live previews (one more cut or
/// finish) cost a single kernel operation. Failures are not cached.
///
/// Builds run one at a time (`buildLock`), as the kernel always has, but lookups only take the
/// short `lock`: the canvas and selection strip find an already-built solid at once, even while a
/// thread or text preview builds in the background (October 21, 2026).
final class SolidCache: @unchecked Sendable {
    static let shared = SolidCache()
    private let lock = NSLock()
    private let buildLock = NSRecursiveLock()
    private var entries: [(body: SolidBody, solid: KernelSolid)] = []
    private let capacity = 96

    func solid(for body: SolidBody) throws -> KernelSolid {
        // Visibility does not change geometry.
        var body = body
        body.hidden = nil
        if let solid = cached(body) { return solid }
        buildLock.lock()
        defer { buildLock.unlock() }
        // Another thread may have built it while this one waited.
        if let solid = cached(body) { return solid }
        let solid = try build(body)
        store(body, solid)
        return solid
    }

    /// Records `moved` (`original` carried by `transform`) as the original's built solid moved, when
    /// that is cached, so dragging a solid does not rebuild it every frame.
    func seed(_ moved: SolidBody, from original: SolidBody, by transform: RigidTransform) {
        var key = original, movedKey = moved
        key.hidden = nil
        movedKey.hidden = nil
        lock.lock()
        let source = entries.contains(where: { $0.body == movedKey }) ? nil : entries.first(where: { $0.body == key })?.solid
        lock.unlock()
        guard let source, let solid = try? SolidKernel.moved(source, by: transform) else { return }
        store(movedKey, solid)
    }

    private func cached(_ body: SolidBody) -> KernelSolid? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.body == body }) else { return nil }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
        return entry.solid
    }

    private func store(_ body: SolidBody, _ solid: KernelSolid) {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.contains(where: { $0.body == body }) else { return }
        entries.insert((body, solid), at: 0)
        if entries.count > capacity { entries.removeLast() }
    }

    private func build(_ body: SolidBody) throws -> KernelSolid {
        var previous = body
        if let cut = previous.cuts.popLast() { return try SolidKernel.apply(cut, to: solid(for: previous), of: previous) }
        // Edges are named on the solid as it stood before this finish (an untouched import then needs no matching).
        if let finish = previous.finishes.popLast() { return try SolidKernel.apply(finish, to: solid(for: previous), of: previous) }
        return try SolidKernel.base(of: body)
    }
}
