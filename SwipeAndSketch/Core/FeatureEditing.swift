import Foundation
import simd

// Edit after Done (October 24, 2026): a hole, thread, text, or peg reopens in its own tool with the
// values it was made with, and Done puts the changed one where the old one was in the solid's
// `cuts` list, so the steps after it still apply after it. A peg is a join (or a pin solid of its
// own) plus sockets in the solids it pushes into, so the steps and pin it makes carry its tag.

/// A finished feature that can be reopened in its tool.
enum EditableFeature: Equatable, Sendable {
    /// `cuts[cut]` of a solid: a Hole-tool hole, a thread, or text.
    case hole(body: UUID, cut: Int), thread(body: UUID, cut: Int), text(body: UUID, cut: Int)
    /// A peg and its sockets, by their tag; `body` is the solid it was found from.
    case peg(UUID, body: UUID)

    var title: String {
        switch self { case .hole: "Hole"; case .thread: "Thread"; case .text: "Text"; case .peg: "Peg" }
    }
}

/// A separate peg (a pin solid of its own): what it stands on and how it was made.
struct PegPin: Codable, Equatable, Sendable {
    /// The tag its sockets carry.
    var id: UUID
    /// The solid it stands on.
    var body: UUID
    var clearance: Double
    /// Its length into the face it stands on.
    var embed: Double
}

extension SolidBody {
    /// This solid with `operation` in place of `cuts[index]` (keeping that step's id, so an edit that
    /// changes nothing leaves the solid as it was), or added after the rest when `index` is nil.
    func placing(_ operation: ExtrusionCut, replacing index: Int?) -> SolidBody {
        var result = self, operation = operation
        if let index, cuts.indices.contains(index) {
            operation.id = cuts[index].id
            result.cuts[index] = operation
        } else {
            result.cuts.append(operation)
        }
        return result
    }

    /// The newest Hole-tool hole around `probe`, a world point in a hole's empty middle (on its axis).
    func holeCut(around probe: SIMD3<Double>) -> Int? {
        cuts.indices.reversed().first { index in
            let cut = cuts[index]
            guard let spec = cut.hole, let circle = cut.profile.circle else { return false }
            let plane = cut.profile.plane, center = plane.point(circle.center), into = -plane.normalAxis
            let along = simd_dot(probe - center, into), radial = simd_length(probe - center - into * along)
            let radius = max(spec.diameter, spec.counterboreDiameter, spec.countersinkDiameter) / 2
            return radial <= radius + 0.05 && (cut.throughAll || along >= -0.05 && along <= cut.depth + 0.05)
        }
    }

    /// The newest text whose letters `point` (a world point on a face) lies on: above the face up to
    /// the letters' tops, or below it down to their floors, inside the text's bounds. The face itself,
    /// between the letters, is not the text's.
    func textCut(at point: SIMD3<Double>) -> Int? {
        cuts.indices.reversed().first { index in
            let cut = cuts[index]
            guard let spec = cut.text else { return false }
            let plane = cut.profile.plane, height = plane.height(of: point)
            let range = cut.depth > 0 ? 0.02...(cut.depth + 0.05) : (cut.depth - 0.05)...(-0.02)
            guard range.contains(height) else { return false }
            let points = spec.loops.flatMap { [$0.start] + $0.segments.flatMap(\.points) }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return false }
            let p = plane.coordinates(of: point)
            return p.x >= minX - 0.05 && p.x <= maxX + 0.05 && p.y >= minY - 0.05 && p.y <= maxY + 0.05
        }
    }

    /// The tag of the peg `point` (a world point on a face of this solid) is on: this solid's own when
    /// it is a separate peg, else a joined peg's or a socket's, newest first.
    func pegTag(at point: SIMD3<Double>) -> UUID? {
        if let peg { return peg.id }
        return cuts.reversed().first { cut in
            guard cut.peg != nil, [.join, .cut].contains(cut.operation), let circle = cut.profile.circle else { return false }
            let plane = cut.profile.plane, center = plane.point(circle.center), normal = plane.normalAxis
            let along = simd_dot(point - center, normal), radial = simd_length(point - center - normal * along)
            return radial <= circle.radius + 0.05 && along >= min(0, cut.depth) - 0.05 && along <= max(0, cut.depth) + 0.05
        }?.peg
    }
}

extension PegJoint {
    /// A peg as made: its settings, where it stands, and the workspace without it (its join and tip
    /// bevel, its pin, and its sockets), with where each solid had its steps.
    struct Existing: Equatable {
        var id: UUID
        var spec: PegSpec
        var center: Point2
        var plane: SketchPlane
        /// The solid it stands on.
        var bodyID: UUID
        var base: Workspace
        /// For each solid that had steps of the peg, where the first of them was in its `cuts`.
        var slots: [UUID: Int]
        /// Where a separate peg's pin was among the solids.
        var pinIndex: Int?
    }

    /// The peg tagged `id`: the joined one in `preferring` when that solid has one, or any solid's,
    /// or the separate pin. A joined peg with no socket takes `clearance`. Nil when it is gone.
    static func existing(_ id: UUID, in workspace: Workspace, preferring: UUID? = nil, clearance: Double) -> Existing? {
        var spec = PegSpec(), plane: SketchPlane, center: Point2, bodyID: UUID, pinIndex: Int?
        var storedClearance: Double?
        func joinIndex(_ body: SolidBody) -> Int? {
            body.cuts.indices.first { body.cuts[$0].peg == id && body.cuts[$0].operation == .join && body.cuts[$0].profile.circle != nil }
        }
        if let index = workspace.bodies.firstIndex(where: { $0.peg?.id == id }) {
            let pin = workspace.bodies[index]
            guard let tag = pin.peg, let circle = pin.profile.circle, workspace.bodies.contains(where: { $0.id == tag.body }) else { return nil }
            let normal = pin.profile.plane.normalAxis
            let top = pin.profile.plane.point(circle.center, height: tag.embed)
            guard let through = SketchPlane.through(top, normal: normal) else { return nil }
            plane = through
            center = plane.coordinates(of: top)
            bodyID = tag.body
            pinIndex = index
            spec.separate = true
            spec.embed = tag.embed
            spec.diameter = 2 * circle.radius
            spec.height = pin.depth - tag.embed
            storedClearance = tag.clearance
        } else {
            let owner = workspace.bodies.first { $0.id == preferring && joinIndex($0) != nil } ?? workspace.bodies.first { joinIndex($0) != nil }
            guard let owner, let join = joinIndex(owner).map({ owner.cuts[$0] }), let circle = join.profile.circle else { return nil }
            plane = join.profile.plane
            center = circle.center
            bodyID = owner.id
            spec.diameter = 2 * circle.radius
            spec.height = join.depth
        }

        // Its sockets lie on its axis; copies of the solids moved elsewhere keep their own.
        let origin = plane.point(center), normal = plane.normalAxis
        func isSocket(_ cut: ExtrusionCut) -> Bool {
            guard cut.peg == id, cut.operation == .cut, let circle = cut.profile.circle,
                  abs(simd_dot(cut.profile.plane.normalAxis, normal)) > 1 - 1e-6 else { return false }
            let offset = cut.profile.plane.point(circle.center) - origin
            return simd_length(offset - normal * simd_dot(offset, normal)) < 1e-4
        }
        var base = workspace, slots: [UUID: Int] = [:]
        for index in base.bodies.indices {
            let body = base.bodies[index]
            let own = body.id == bodyID && !spec.separate
            let steps = body.cuts.indices.filter { step in
                let cut = body.cuts[step]
                return isSocket(cut) || own && cut.peg == id && [.join, .finish].contains(cut.operation)
            }
            guard let first = steps.first else { continue }
            if storedClearance == nil, let socket = steps.lazy.map({ body.cuts[$0] }).first(where: isSocket), socket.depth > 0,
               let radius = socket.profile.circle?.radius {
                storedClearance = radius - spec.diameter / 2
            }
            for step in steps.reversed() { base.bodies[index].cuts.remove(at: step) }
            slots[body.id] = first
        }
        if let pinIndex { base.bodies.remove(at: pinIndex) }
        spec.clearance = storedClearance.map { min(max($0, Fit.clearanceRange.lowerBound), Fit.clearanceRange.upperBound) } ?? clearance
        return Existing(id: id, spec: spec, center: center, plane: plane, bodyID: bodyID, base: base, slots: slots, pinIndex: pinIndex)
    }

    /// `old` made again with `spec` at `center`: each solid's steps of it go back where its old ones
    /// were, and a separate pin where the old pin was. Nil when it does not fit or a solid no longer builds.
    static func replace(_ old: Existing, with spec: PegSpec, at center: Point2) -> Result? {
        guard var result = add(spec, at: center, on: old.plane, to: old.bodyID, in: old.base, id: old.id) else { return nil }
        for (id, slot) in old.slots {
            guard let index = result.workspace.bodies.firstIndex(where: { $0.id == id }),
                  let before = old.base.bodies.first(where: { $0.id == id })?.cuts.count else { continue }
            var body = result.workspace.bodies[index]
            let added = body.cuts.count - before
            guard added > 0, slot < before else { continue }
            let moved = Array(body.cuts.suffix(added))
            body.cuts.removeLast(added)
            body.cuts.insert(contentsOf: moved, at: slot)
            guard body.isValid, (try? SolidKernel.solid(for: body)) != nil else { return nil }
            result.workspace.bodies[index] = body
        }
        if let pin = result.peg, let oldIndex = old.pinIndex, let index = result.workspace.bodies.firstIndex(where: { $0.id == pin }) {
            let body = result.workspace.bodies.remove(at: index)
            result.workspace.bodies.insert(body, at: min(oldIndex, result.workspace.bodies.count))
        }
        return result
    }
}

/// A finished thread as the Thread tool sets it up again: the solid without it, the face it is on
/// there, the thread along that whole face with the saved size and options, and how much of the face
/// is threaded from which end.
struct ThreadSetup: Equatable {
    var base: SolidBody
    var face: Int
    var spec: ThreadSpec
    /// Nil for the whole face.
    var length: Double?
    var atEnd: Bool
}

extension SolidBody {
    /// The thread at `cuts[index]` set up again for editing (see ThreadSetup); nil when its face is gone.
    func threadSetup(at index: Int) -> ThreadSetup? {
        guard cuts.indices.contains(index), let stored = cuts[index].thread else { return nil }
        var base = self
        base.cuts.remove(at: index)
        guard let solid = try? SolidKernel.solid(for: base) else { return nil }
        // A point on the threaded face, halfway along it.
        let origin = worldPoint(stored.origin), axis = simd_normalize(worldPoint(stored.origin + stored.axis) - origin)
        let reference = worldPoint(stored.origin + stored.reference) - origin
        let across = simd_normalize(reference - axis * simd_dot(reference, axis))
        let (low, high) = stored.ends.map { ($0.start, $0.end) } ?? (0, stored.length)
        let probe = origin + axis * ((low + high) / 2) + across * (stored.surfaceDiameter / 2)
        guard let face = solid.face(near: probe, tolerance: 0.01), solid.faceCylinder(face) != nil,
              let whole = base.threadSpec(onFace: face, of: solid, clearance: Fit.clearanceRange.contains(stored.clearance) ? stored.clearance : Fit.defaultClearance)
        else { return nil }
        guard stored.ends != nil, whole.ends != nil, stored.threadedLength < whole.threadedLength - 1e-6 else {
            return ThreadSetup(base: base, face: face, spec: stored, length: nil, atEnd: base.threadEntryIsAtEnd(stored))
        }
        // Cut short: the whole face's thread with the saved settings, shortened from the end it was.
        var spec = whole
        spec.size = stored.size
        spec.majorDiameter = stored.majorDiameter
        spec.pitch = stored.pitch
        spec.clearance = stored.clearance
        spec.leftHanded = stored.leftHanded
        spec.starts = stored.starts
        spec.raised = stored.raised
        // Where the helix starts, so it lines up with a part already made to screw onto it.
        spec.reference = stored.reference
        if stored.hasOpenEnd { spec.leadIn = stored.leadIn }
        let length = stored.threadedLength
        let fromEnd = spec.shortened(to: length, atEnd: true), fromStart = spec.shortened(to: length, atEnd: false)
        let atEnd = (fromEnd.map { simd_distance($0.origin, stored.origin) } ?? .infinity) <=
            (fromStart.map { simd_distance($0.origin, stored.origin) } ?? .infinity)
        return ThreadSetup(base: base, face: face, spec: spec, length: length, atEnd: atEnd)
    }
}
