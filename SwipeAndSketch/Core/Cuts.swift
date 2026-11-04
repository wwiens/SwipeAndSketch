import Foundation
import simd

/// A sketch profile extruded and either subtracted from a solid (a hole, pocket, or slot) or
/// joined to it (a boss). Each affected solid keeps its own copy, so solids stay independent of
/// sketches and of each other. A solid's `cuts` list holds both kinds, in the order they were made.
struct ExtrusionCut: Codable, Equatable, Identifiable, Sendable {
    /// cut and join extrude `profile`; merge, shell, and hole carry their own payload (schema 6).
    enum Operation: String, Codable, Sendable { case cut, join, merge, shell, hole, split, subtract, finish, thread, text, intersect, scale, deleteFace, offsetFace, draft, rib }

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
    /// Draft (October 24, 2026): faces leaned for a mold (ShapeOperations.swift).
    var draft: DraftSpec?
    /// Rib (October 24, 2026): a stiffening web from a sketch line to the solid (ShapeOperations.swift).
    var rib: RibSpec?
    /// The peg this join, tip bevel, or socket belongs to (October 24, 2026; FeatureEditing.swift), so the
    /// peg can be edited with its sockets. Omitted otherwise, and on pegs made before then.
    var peg: UUID?
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
        if draft != nil { return .draft }
        if rib != nil { return .rib }
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
        guard profile.isSolidProfile, [merged != nil, subtracted != nil, intersected != nil, scale != nil, removedFaces != nil, movedFaces != nil, shell != nil, hole != nil, join == true, split != nil, finish != nil, thread != nil, text != nil, draft != nil, rib != nil].filter({ $0 }).count <= 1 else { return false }
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
        case .draft: return draft?.isValid ?? false
        case .rib: return rib?.isValid ?? false
        case .shell: return shell?.isValid ?? false
        case .hole: return (hole?.isValid ?? false) && profile.circle != nil && (throughAll || depthIsValid)
        case .split:
            guard split?.isValid == true else { return false }
            return split?.keep == .inside ? throughAll : !throughAll && depthIsValid
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
        case .split: return try applySplit(cut, to: solid, of: body)
        case .subtract: return try applySubtract(cut, to: solid)
        case .intersect: return try applyIntersect(cut, to: solid)
        case .scale: return try applyScale(cut, to: solid, of: body)
        case .deleteFace: return try applyFaceRemoval(cut, to: solid, of: body)
        case .offsetFace: return try applyFaceOffset(cut, to: solid, of: body)
        case .draft: return try applyDraft(cut, to: solid, of: body)
        case .rib: return try applyRib(cut, to: solid, of: body)
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
///
/// Solids asked for keep their own list, apart from the earlier steps built on the way to them,
/// so a long history cannot push out finished solids (October 31, 2026): with a 96-entry list
/// shared by both, a project whose solids had 280 steps rebuilt every solid on each pass over
/// all of them.
final class SolidCache: @unchecked Sendable {
    static let shared = SolidCache()
    private let lock = NSLock()
    private let buildLock = NSRecursiveLock()
    private var entries: [(body: SolidBody, solid: KernelSolid)] = []
    /// Earlier steps of the solids in `entries`, which a change to a late step builds on.
    private var steps: [(body: SolidBody, solid: KernelSolid)] = []
    private let capacity = 256
    private let stepCapacity = 256

    func solid(for body: SolidBody) throws -> KernelSolid { try solid(for: body, step: false) }

    /// What a solid is cached under: only what shapes it. Visibility, name, color, group, and a pin's
    /// tag do not, so renaming or recoloring a solid with a long history doesn't rebuild it, and a
    /// copy finds the original's solid.
    static func key(_ body: SolidBody) -> SolidBody {
        var key = body
        key.id = anyID
        key.hidden = nil
        key.name = nil
        key.color = nil
        key.group = nil
        key.peg = nil
        return key
    }
    private static let anyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private func solid(for body: SolidBody, step: Bool) throws -> KernelSolid {
        let body = Self.key(body)
        if let solid = cached(body, step: step) { return solid }
        buildLock.lock()
        defer { buildLock.unlock() }
        // Another thread may have built it while this one waited.
        if let solid = cached(body, step: step) { return solid }
        let solid = try build(body)
        store(body, solid, step: step)
        return solid
    }

    /// Records `solid` as `body`'s, when the caller built it exactly as `build` would.
    func remember(_ solid: KernelSolid, for body: SolidBody) {
        store(Self.key(body), solid, step: false)
    }

    /// Records `moved` (`original` carried by `transform`) as the original's built solid moved, when
    /// that is cached, so dragging a solid does not rebuild it every frame.
    func seed(_ moved: SolidBody, from original: SolidBody, by transform: RigidTransform) {
        let key = Self.key(original), movedKey = Self.key(moved)
        lock.lock()
        let known = entries.contains(where: { $0.body == movedKey }) || steps.contains(where: { $0.body == movedKey })
        let source = known ? nil : (entries.first(where: { $0.body == key }) ?? steps.first(where: { $0.body == key }))?.solid
        lock.unlock()
        guard let source, let solid = try? SolidKernel.moved(source, by: transform) else { return }
        store(movedKey, solid, step: false)
    }

    /// A step asked for directly (the solid before a preview's extra cut) joins the solids.
    private func cached(_ body: SolidBody, step: Bool) -> KernelSolid? {
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0.body == body }) {
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.solid
        }
        guard let index = steps.firstIndex(where: { $0.body == body }) else { return nil }
        let entry = steps.remove(at: index)
        if step { steps.insert(entry, at: 0) } else { insert(entry, into: &entries, capacity: capacity) }
        return entry.solid
    }

    private func store(_ body: SolidBody, _ solid: KernelSolid, step: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.contains(where: { $0.body == body }), !steps.contains(where: { $0.body == body }) else { return }
        if step { insert((body, solid), into: &steps, capacity: stepCapacity) } else { insert((body, solid), into: &entries, capacity: capacity) }
    }

    private func insert(_ entry: (body: SolidBody, solid: KernelSolid), into list: inout [(body: SolidBody, solid: KernelSolid)], capacity: Int) {
        list.insert(entry, at: 0)
        if list.count > capacity { list.removeLast() }
    }

    /// Walks back to the newest earlier step already built (or the base), then applies the rest in
    /// order, keeping each as a step. It used to call itself once per step, and an uncached rebuild of
    /// a solid with about 100 steps overflowed the main thread's 1 MB stack (November 4, 2026); now
    /// only a merge, which builds the solid it took in, nests.
    private func build(_ body: SolidBody) throws -> KernelSolid {
        // Steps are cuts, newest last, on top of finishes, newest last, on top of the base.
        var pending: [SolidBody] = [], previous = body, solid: KernelSolid
        while true {
            guard !previous.cuts.isEmpty || !previous.finishes.isEmpty else {
                solid = try SolidKernel.base(of: previous)
                if !pending.isEmpty { store(previous, solid, step: true) }
                break
            }
            pending.append(previous)
            if previous.cuts.popLast() == nil { previous.finishes.removeLast() }
            if let built = cached(previous, step: true) { solid = built; break }
        }
        for index in pending.indices.reversed() {
            var before = pending[index]
            if let cut = before.cuts.popLast() {
                solid = try SolidKernel.apply(cut, to: solid, of: before)
            } else if let finish = before.finishes.popLast() {
                // Edges are named on the solid as it stood before this finish (an untouched import then needs no matching).
                solid = try SolidKernel.apply(finish, to: solid, of: before)
            }
            // The caller keeps the solid asked for.
            if index > 0 { store(pending[index], solid, step: true) }
        }
        return solid
    }
}
