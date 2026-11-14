import Foundation
import simd
import CryptoKit

/// A sketch profile extruded and either subtracted from a solid (a hole, pocket, or slot) or
/// joined to it (a boss). Each affected solid keeps its own copy, so solids stay independent of
/// sketches and of each other. A solid's `cuts` list holds both kinds, in the order they were made.
struct ExtrusionCut: Codable, Equatable, Identifiable, Sendable {
    /// cut and join extrude `profile`; merge, shell, and hole carry their own payload (schema 6).
    enum Operation: String, Codable, Sendable { case cut, join, merge, shell, hole, split, subtract, finish, thread, text, intersect, scale, deleteFace, offsetFace, draft, rib }

    var id = UUID()
    /// Left out of the file when it is the solid's own profile (`StepProfile`).
    @StepProfile var profile: SketchProfile
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

    var isValid: Bool { isValid(profileIsSolid: nil) }

    /// `isValid`, given whether its profile `isSolidProfile` when that is already known (a step
    /// on the solid's own profile, checked once for all of them).
    func isValid(profileIsSolid known: Bool?) -> Bool {
        let depthIsValid = depth.isFinite && abs(depth) >= 0.01 && abs(depth) <= 10_000
        if let clearance, subtracted == nil || !Fit.clearanceRange.contains(clearance) { return false }
        guard known ?? profile.isSolidProfile, [merged != nil, subtracted != nil, intersected != nil, scale != nil, removedFaces != nil, movedFaces != nil, shell != nil, hole != nil, join == true, split != nil, finish != nil, thread != nil, text != nil, draft != nil, rib != nil].filter({ $0 }).count <= 1 else { return false }
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
    /// Steps on the solid's own profile (most of a lean file's) check that profile once, not once
    /// each: its holes check runs about quadratically, once per step on long histories.
    var cutsAreValid: Bool {
        guard cuts.count <= ExtrusionCut.maximumPerBody else { return false }
        var own: Bool?
        return cuts.allSatisfy { cut in
            guard cut.profile == profile else { return cut.isValid }
            if own == nil { own = profile.isSolidProfile }
            return cut.isValid(profileIsSolid: own)
        }
    }

    /// `isValid` for this solid, already found valid, with `steps` added after its cuts: only the
    /// new steps and the step count can make it invalid. A live preview checks this on every Pencil
    /// move instead of the whole definition, which took most of a frame on solids with long
    /// histories (November 8, 2026). Done still checks the kept model in full.
    /// The solid one step earlier (its last cut, else its last finish taken off); nil for a base.
    var withoutLastStep: SolidBody? {
        var earlier = self
        if earlier.cuts.popLast() != nil || earlier.finishes.popLast() != nil { return earlier }
        return nil
    }

    func isValid(appending steps: [ExtrusionCut]) -> Bool {
        cuts.count + steps.count <= ExtrusionCut.maximumPerBody && steps.allSatisfy(\.isValid)
    }
}

extension ExtrusionCut {
    /// False only when this extruded cut or join cannot touch a solid within `bounds`, so a live
    /// preview can skip that solid without building it. Conservative: the region's box (with its
    /// arcs and circles whole, and widened by any taper) swept over the depth, against the solid's
    /// box seen in the sketch plane's own axes. Revolves and face extrusions always may reach.
    func mayReach(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>), margin: Double = 0.01) -> Bool {
        guard revolve == nil, facePoint == nil, [.cut, .join].contains(operation), depth.isFinite else { return true }
        let plane = profile.plane
        var low = SIMD2(repeating: Double.infinity), high = SIMD2(repeating: -Double.infinity)
        func include(_ point: Point2, _ radius: Double = 0) {
            low = simd_min(low, SIMD2(point.x - radius, point.y - radius))
            high = simd_max(high, SIMD2(point.x + radius, point.y + radius))
        }
        for point in profile.outline { include(point) }
        if let circle = profile.circle { include(circle.center, circle.radius) }
        if let ellipse = profile.ellipse { include(ellipse.center, max(ellipse.radiusX, ellipse.radiusY)) }
        for arc in profile.arcs ?? [] { include(arc.center, arc.radius) }
        guard low.x <= high.x, low.y <= high.y else { return true }
        var grow = margin
        if let taper, taper != 0 { grow += abs(depth) * tan(min(abs(taper), 89.9) * .pi / 180) }
        let near: Double, far: Double
        if throughAll { (near, far) = (-.infinity, .infinity) }
        else if symmetric == true { (near, far) = (-abs(depth) / 2, abs(depth) / 2) }
        else { (near, far) = (min(0, depth), max(0, depth)) }
        var boxLow = SIMD3(repeating: Double.infinity), boxHigh = SIMD3(repeating: -Double.infinity)
        let normal = plane.normalAxis
        for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
            let offset = SIMD3(x, y, z) - plane.origin
            let local = SIMD3(simd_dot(offset, plane.xAxis), simd_dot(offset, plane.yAxis), simd_dot(offset, normal))
            boxLow = simd_min(boxLow, local)
            boxHigh = simd_max(boxHigh, local)
        } } }
        return boxLow.x <= high.x + grow && boxHigh.x >= low.x - grow && boxLow.y <= high.y + grow && boxHigh.y >= low.y - grow &&
            boxLow.z <= far + margin && boxHigh.z >= near - margin
    }
}

extension ExtrusionCut {
    /// A plain extruded cut: its tool is the profile alone (a through-all one only needs to reach
    /// past the solid), so consecutive ones can be subtracted together (`SolidKernel.applyCuts`).
    /// Face cuts and revolves take their tool from the solid as it stands, and other steps aren't cuts.
    var isBatchableCut: Bool { operation == .cut && facePoint == nil && revolve == nil }
}

/// Whether two boxes overlap or touch, within `margin`.
func boxesMeet(_ a: (min: SIMD3<Double>, max: SIMD3<Double>), _ b: (min: SIMD3<Double>, max: SIMD3<Double>), margin: Double = 0.01) -> Bool {
    all(a.min .<= b.max + margin) && all(b.min .<= a.max + margin)
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

    /// Plain extruded cuts subtracted from `solid` in one boolean, as applying each in turn would
    /// (all `isBatchableCut`). Through-all tools reach past `solid`, which no later cut can grow.
    static func applyCuts(_ cuts: [ExtrusionCut], to solid: KernelSolid) throws -> KernelSolid {
        guard cuts.allSatisfy(\.isBatchableCut) else { throw Failure(message: "Only plain cuts can be applied together") }
        let result = try boolean(solid, try cuts.map { try tool(for: $0, through: solid) }, .subtract)
        guard result.volume > 1e-9 else { throw Failure(message: "The cut would remove the whole solid") }
        return result
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
    /// A built solid and what it was built for. Lookups compare a few cheap facts first (step
    /// counts, the last step, the plane's origin) and the whole definition only when those agree:
    /// comparing up to 640 long definitions in full on each lookup added up (November 8, 2026).
    private struct Entry {
        struct Facts: Equatable {
            var cuts: Int, finishes: Int, outline: Int, lastStep: UUID?, depth: Double, origin: SIMD3<Double>
            init(_ body: SolidBody) {
                cuts = body.cuts.count; finishes = body.finishes.count; outline = body.profile.outline.count
                lastStep = body.cuts.last?.id; depth = body.depth; origin = body.profile.plane.origin
            }
        }
        let body: SolidBody
        let facts: Facts
        let solid: KernelSolid
        init(_ body: SolidBody, _ solid: KernelSolid) { self.body = body; facts = Facts(body); self.solid = solid }
        func matches(_ other: SolidBody) -> Bool { facts == Facts(other) && body == other }
    }
    private var entries: [Entry] = []
    /// Earlier steps of the solids in `entries`, which a change to a late step builds on.
    private var steps: [Entry] = []
    /// Moved copies made for live drags and pattern previews (`seed`), apart from the rest: every
    /// drag frame and pattern copy made one, and about four seconds of dragging pushed every real
    /// solid out of `entries` (November 8, 2026). A kept model's moved solids join `entries` (`keep`).
    private var seeds: [Entry] = []
    /// The originals recently seeded from, as their callers hold them. A drag seeds from the same
    /// original on every step, and comparing it with this copy is quick (Swift compares the shared
    /// step arrays by identity), while the copy in `entries` is equal but separate, so finding it
    /// compared every step of a long history each time: 0.4 s in a 20 s drag of several detailed
    /// solids on the iPad (November 9, 2026).
    private var seedSources: [Entry] = []
    private let capacity = 256
    private let stepCapacity = 256
    private let seedCapacity = 128

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
        // A finished solid whose earlier steps are no longer in memory would replay its whole
        // history: the copy kept on disk is quicker, when there is one.
        if !step, body.historySteps > 8, let shorter = body.withoutLastStep, cached(shorter, step: true) == nil,
           let stored = BuiltSolidStore.shared.solid(for: body) {
            store(body, stored, step: false)
            return stored
        }
        let solid = try Performance.measure("Solid build") { try build(body) }
        store(body, solid, step: step)
        return solid
    }

    /// The solid built for `body` when it is in memory; never builds.
    func built(_ body: SolidBody) -> KernelSolid? {
        let key = Self.key(body)
        lock.lock()
        defer { lock.unlock() }
        return (entries.first { $0.matches(key) } ?? steps.first { $0.matches(key) } ?? seeds.first { $0.matches(key) })?.solid
    }

    /// Readies `body`'s solid before the canvas asks for it (opening a project, off the main
    /// thread): from memory, else the copy kept on disk, else built from its definition and then
    /// kept on disk. Its display mesh is made too; Open CASCADE keeps it on the shape's faces, so
    /// the canvas's own tessellation is quick. With `build` false only memory and disk are tried,
    /// which never waits on (or holds up) a build the editor is making.
    func prepare(_ body: SolidBody, build: Bool = true, disk: BuiltSolidStore = .shared) {
        let key = Self.key(body)
        var solid = cached(key, step: false)
        if solid == nil, let stored = disk.solid(for: key) {
            store(key, stored, step: false)
            solid = stored
        }
        if solid == nil, build, let built = try? self.solid(for: body) {
            disk.keep(built, for: key)
            solid = built
        }
        _ = try? solid?.tessellateForDisplay()
    }

    /// Reads the solids of `bodies` kept on disk into memory, several at once (opening a project):
    /// reading and checking the files shares nothing between solids, unlike building or meshing,
    /// which `prepare` then does one at a time.
    func readFromDisk(_ bodies: [SolidBody], disk: BuiltSolidStore = .shared) {
        let keys = bodies.map(Self.key).filter { cached($0, step: false) == nil }
        guard keys.count > 1 else { return }
        DispatchQueue.concurrentPerform(iterations: keys.count) { index in
            guard let stored = disk.solid(for: keys[index]) else { return }
            store(keys[index], stored, step: false)
        }
    }

    /// Builds `body`'s earlier steps, oldest first and each under the build lock on its own, so a
    /// build the editor asks for meanwhile waits for one step (or run of cuts) at most. A solid read
    /// from disk comes without them, and anything that changes an earlier step (which fillet made a
    /// face, a finish's size, a hole removed, editing after Done) then replayed the whole history on
    /// the main thread: 1.65 s on selecting a face of an 88-step solid on an iPad (November 8, 2026).
    /// Stops when `keepGoing` is false.
    ///
    /// The steps inside a run of plain cuts are left out (November 11, 2026): `build` subtracts the
    /// run in one boolean from the solid before it, so one of them is quick to make when asked for,
    /// and building each in turn took this pass about 6 s on a solid with 117 cuts in a row. The
    /// step before the newest is always built, as building the solid itself keeps it.
    func buildSteps(of body: SolidBody, while keepGoing: () -> Bool) {
        guard body.historySteps <= SolidBody.longHistory else { return }
        let key = Self.key(body)
        var prefixes: [SolidBody] = [], previous = key
        // The steps `build` walks back through: cuts newest first, then finishes.
        while !previous.cuts.isEmpty || !previous.finishes.isEmpty {
            if previous.cuts.popLast() == nil { previous.finishes.removeLast() }
            prefixes.append(previous)
        }
        for prefix in prefixes.reversed() {
            let count = prefix.cuts.count
            if count < key.cuts.count - 1, prefix.cuts.last?.isBatchableCut == true, key.cuts[count].isBatchableCut { continue }
            guard keepGoing() else { return }
            _ = try? solid(for: prefix, step: true)
        }
    }

    /// Keeps the solids of `bodies` already built this session on disk (leaving a project), so the
    /// project opens quickly next time. Never builds.
    func keepOnDisk(_ bodies: [SolidBody], disk: BuiltSolidStore = .shared) {
        Self.write(builtForDisk(bodies), to: disk)
    }

    /// The solids of `bodies` built this session, with their keys, taken at once so the memory
    /// can be released while they are written (`write`).
    func builtForDisk(_ bodies: [SolidBody]) -> [(key: SolidBody, solid: KernelSolid)] {
        bodies.compactMap { body in built(body).map { (Self.key(body), $0) } }
    }

    static func write(_ solids: [(key: SolidBody, solid: KernelSolid)], to disk: BuiltSolidStore = .shared) {
        for (key, solid) in solids { disk.keep(solid, for: key) }
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
        let known = entries.contains(where: { $0.matches(movedKey) }) || steps.contains(where: { $0.matches(movedKey) }) ||
            seeds.contains(where: { $0.matches(movedKey) })
        var source: KernelSolid?
        if !known {
            if let recent = seedSources.first(where: { $0.matches(key) }) {
                source = recent.solid
            } else if let found = (entries.first(where: { $0.matches(key) }) ?? steps.first(where: { $0.matches(key) }) ??
                                   seeds.first(where: { $0.matches(key) }))?.solid {
                source = found
                insert(Entry(key, found), into: &seedSources, capacity: 16)
            }
        }
        lock.unlock()
        guard let source, let solid = try? SolidKernel.moved(source, by: transform) else { return }
        lock.lock()
        insert(Entry(movedKey, solid), into: &seeds, capacity: seedCapacity)
        lock.unlock()
    }

    /// Moves the seeded solids of a model just kept (a drag or pattern made final) in with the
    /// others, so later drags and patterns cannot push them out.
    func keep(_ bodies: [SolidBody]) {
        lock.lock()
        defer { lock.unlock() }
        guard !seeds.isEmpty else { return }
        for body in bodies {
            let key = Self.key(body)
            guard let index = seeds.firstIndex(where: { $0.matches(key) }) else { continue }
            let entry = seeds.remove(at: index)
            if !entries.contains(where: { $0.matches(key) }) { insert(entry, into: &entries, capacity: capacity) }
        }
    }

    /// Everything made from the model that can be made again: the solids in memory, imported
    /// shapes' solids (their bytes stay), and sketch regions. Leaving a project, after its solids
    /// went to disk, or when the system is short of memory (`keeping` the most recent solids).
    static func releaseMemory(keepingSolids count: Int = 0) {
        if count == 0 { shared.removeAll() } else { shared.trim(keeping: count) }
        ImportedShapes.shared.releaseBuilt()
        RegionCache.shared.removeAll()
    }

    /// Lets go of every solid held in memory (leaving a project, or when the system is short of
    /// memory). Built solids already kept on disk come back from there.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        steps.removeAll()
        seeds.removeAll()
        seedSources.removeAll()
    }

    /// Under memory pressure: drops the earlier steps and drag copies, and all but the `keeping`
    /// most recently used solids.
    func trim(keeping count: Int) {
        lock.lock()
        defer { lock.unlock() }
        steps.removeAll()
        seeds.removeAll()
        seedSources.removeAll()
        if entries.count > count { entries.removeLast(entries.count - count) }
    }

    /// A step asked for directly (the solid before a preview's extra cut) joins the solids.
    private func cached(_ body: SolidBody, step: Bool) -> KernelSolid? {
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0.matches(body) }) {
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.solid
        }
        if let index = steps.firstIndex(where: { $0.matches(body) }) {
            let entry = steps.remove(at: index)
            if step { steps.insert(entry, at: 0) } else { insert(entry, into: &entries, capacity: capacity) }
            return entry.solid
        }
        guard let index = seeds.firstIndex(where: { $0.matches(body) }) else { return nil }
        let entry = seeds.remove(at: index)
        seeds.insert(entry, at: 0)
        return entry.solid
    }

    private func store(_ body: SolidBody, _ solid: KernelSolid, step: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.contains(where: { $0.matches(body) }), !steps.contains(where: { $0.matches(body) }),
              !seeds.contains(where: { $0.matches(body) }) else { return }
        if step { insert(Entry(body, solid), into: &steps, capacity: stepCapacity) } else { insert(Entry(body, solid), into: &entries, capacity: capacity) }
    }

    private func insert(_ entry: Entry, into list: inout [Entry], capacity: Int) {
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
        var index = pending.count - 1
        while index >= 0 {
            // A run of plain cuts is subtracted at once (November 11, 2026): each cut on its own
            // intersected and simplified the whole solid again, so a honeycomb of 125 hexagon cuts
            // took 6.1 s, each cut slower than the last. The newest step stays on its own, so the
            // solid before it is kept and a live preview of it costs one operation.
            var end = index
            if pending[index].cuts.last?.isBatchableCut == true {
                while end > 1, pending[end - 1].cuts.last?.isBatchableCut == true { end -= 1 }
            }
            if end < index {
                solid = try applyCuts(of: Array(pending[end...index]), to: solid)
                store(pending[end], solid, step: true)
                index = end - 1
                continue
            }
            solid = try applyStep(of: pending[index], to: solid)
            // The caller keeps the solid asked for.
            if index > 0 { store(pending[index], solid, step: true) }
            index -= 1
        }
        return solid
    }

    /// `body`'s last step applied to `solid`, the solid built for `body` without that step.
    private func applyStep(of body: SolidBody, to solid: KernelSolid) throws -> KernelSolid {
        var before = body
        if let cut = before.cuts.popLast() { return try SolidKernel.apply(cut, to: solid, of: before) }
        // Edges are named on the solid as it stood before this finish (an untouched import then needs no matching).
        if let finish = before.finishes.popLast() { return try SolidKernel.apply(finish, to: solid, of: before) }
        return solid
    }

    /// The last cuts of `bodies` (newest first, each one step past the next) subtracted from `solid`
    /// in one boolean. If the kernel cannot do them together, they are applied one at a time, with
    /// each kept as a step as `build` would, so a failure names the same step it always did.
    private func applyCuts(of bodies: [SolidBody], to solid: KernelSolid) throws -> KernelSolid {
        if let result = try? SolidKernel.applyCuts(bodies.reversed().compactMap(\.cuts.last), to: solid) { return result }
        var solid = solid
        for (offset, body) in bodies.enumerated().reversed() {
            solid = try applyStep(of: body, to: solid)
            if offset > 0 { store(body, solid, step: true) }
        }
        return solid
    }
}

/// Built solids kept between sessions in the app's caches folder (November 8, 2026), so a project
/// opens without replaying every solid's history: a case of 8 solids with up to 119 steps took
/// about 12 seconds to build. Each file is named for a hash of what shapes the solid (its cache
/// key) and the app's version, so another definition or a new kernel never finds it. A file holds
/// the SHA-256 of its B-rep bytes ahead of them, and one that does not match is ignored. The
/// project file stays the only source: the system may empty this folder at any time, and the
/// oldest files go when it passes `maximumBytes`.
final class BuiltSolidStore: @unchecked Sendable {
    static let shared = BuiltSolidStore(directory: URL.cachesDirectory.appendingPathComponent("Built Solids", isDirectory: true))

    let directory: URL
    let maximumBytes: Int
    private let lock = NSLock()

    init(directory: URL, maximumBytes: Int = 256 * 1024 * 1024) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    /// Changes when the kernel may build a definition differently: with `SolidKernel.buildFormat`
    /// (raise it with any change to the kernel, the facade, or how a step builds), the kernel's
    /// version, and the app's marketing version. It used to change with every build number, so
    /// each TestFlight or App Store update rebuilt every history on first open (November 8, 2026).
    /// Debug builds also take the executable's date, so a development build never reads solids
    /// an older one made.
    static let version: String = {
        let info = Bundle.main.infoDictionary
        var version = "2|\(SolidKernel.buildFormat)|\(SolidKernel.kernelVersion)|\(info?["CFBundleShortVersionString"] as? String ?? "")"
        #if DEBUG
        // The binary holding this code (the app, or the test bundle under `swift test`).
        var image = Dl_info()
        if dladdr(#dsohandle, &image) != 0, let path = image.dli_fname,
           let date = try? URL(fileURLWithPath: String(cString: path)).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            version += "|\(date.timeIntervalSince1970)"
        }
        #endif
        return version
    }()

    /// The file for a cache key, or nil when it cannot be encoded.
    func url(for key: SolidBody) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let definition = try? encoder.encode(key) else { return nil }
        var hash = SHA256()
        hash.update(data: Data(Self.version.utf8))
        hash.update(data: definition)
        let name = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("brep")
    }

    func solid(for key: SolidBody) -> KernelSolid? {
        guard let url = url(for: key), let file = try? Data(contentsOf: url, options: .mappedIfSafe), file.count > 32 else { return nil }
        let bytes = file.dropFirst(32)
        guard Data(SHA256.hash(data: bytes)) == file.prefix(32), let solid = try? SolidKernel.shape(from: Data(bytes)) else { return nil }
        // Recently used files are the last to go.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return solid
    }

    /// Writes `solid` for `key` unless a file has it already.
    func keep(_ solid: KernelSolid, for key: SolidBody) {
        guard let url = url(for: key) else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path), let bytes = try? solid.shapeData() else { return }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try (Data(SHA256.hash(data: bytes)) + bytes).write(to: url, options: .atomic)
        } catch { return }
        // The folder is listed once, then its size kept up to date, instead of listing every file
        // on each write (closing a project writes many).
        let total = (knownBytes ?? folderBytes()) + bytes.count + 32
        if total > maximumBytes { trim(); knownBytes = nil } else { knownBytes = total }
    }
    private var knownBytes: Int?

    private func folderBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Removes the least recently used files once the folder passes `maximumBytes`, down to three quarters of it.
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maximumBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > maximumBytes * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// Lean files (November 8, 2026): steps that work on the solid itself (Offset Face, Delete Face,
/// fillets, splits, merges) carry the solid's own profile, which filled 2.4 MB of a 11.6 MB case.
/// Inside a solid, a step's profile equal to the solid's is left out of the file and taken from
/// the solid on reading, so the model reads back exactly. A step coded on its own keeps it.
@propertyWrapper struct StepProfile: Codable, Equatable, Sendable {
    var wrappedValue: SketchProfile
    init(wrappedValue: SketchProfile) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try SketchProfile(from: decoder) }
    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }

    /// The profile of the solid whose steps are being coded.
    @TaskLocal static var solidProfile: SketchProfile?
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: StepProfile, forKey key: Key) throws {
        if let solid = StepProfile.solidProfile, solid == value.wrappedValue { return }
        try encode(value.wrappedValue, forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: StepProfile.Type, forKey key: Key) throws -> StepProfile {
        if let profile = try decodeIfPresent(SketchProfile.self, forKey: key) { return StepProfile(wrappedValue: profile) }
        guard let solid = StepProfile.solidProfile else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "A step's profile, outside a solid"))
        }
        return StepProfile(wrappedValue: solid)
    }
}
