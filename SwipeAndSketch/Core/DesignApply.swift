import Foundation
import simd

// A design proposal → native solids. Removals come first, then each changed feature replaces its
// original in place and each new one is appended to its solid. A solid nothing touches is left
// exactly as it was, and in a touched solid every feature the proposal did not change keeps its
// native step as it was (its UUID, and outlines the document cannot express); only changed and new
// features are built from the document's numbers. Fillet, chamfer, and shell features name edges
// and faces by rule, resolved on the solid as it stands at that point of its history.

enum DesignApply {
    typealias Failure = AssistantWorkbench.Failure

    struct Result {
        var workspace: Workspace
        /// One line per change, for the review card; written by the app, not the model.
        var changes: [String]
        /// Solids that were rebuilt or added.
        var touched: [UUID]
        /// New solids by the name the proposal gave them.
        var newBodies: [String: UUID]
    }

    private struct Entry {
        var id: String
        var feature: DesignFeature
        /// Built from the document: a new feature, or a changed one.
        var rebuilt: Bool
        var role: DesignAliases.Role?
    }

    static func apply(_ proposal: DesignProposal, aliases: DesignAliases, bench: AssistantWorkbench) throws -> Result {
        let start = bench.workspace
        let upserts = proposal.features.map(\.id)
        guard Set(upserts).count == upserts.count else {
            throw Failure("Each feature ID may appear only once in features: \(duplicates(upserts).joined(separator: ", ")).")
        }
        let removals = proposal.removeIDs
        guard Set(removals).count == removals.count else { throw Failure("A removeID is listed twice: \(duplicates(removals).joined(separator: ", ")).") }
        for id in removals {
            if aliases.bodies[id] != nil { continue }
            guard let reference = aliases.features[id] else { throw Failure("removeIDs names \(id), which is not in the document.") }
            if reference.role == .base {
                throw Failure("\(id) is the first feature of its solid; remove the whole solid (\(aliases.alias(of: reference.body) ?? "its ID")) instead.")
            }
        }
        if let both = upserts.first(where: removals.contains) { throw Failure("\(both) is both removed and changed.") }
        let removedBodies = Set(removals.filter { aliases.bodies[$0] != nil })

        // Each solid's feature list, as exported, then edited.
        var lists: [String: [Entry]] = [:]
        for (alias, order) in aliases.order {
            lists[alias] = order.compactMap { id in aliases.exported[id].map { Entry(id: id, feature: $0, rebuilt: false, role: aliases.features[id]?.role) } }
        }
        var removedLines: [String: [String]] = [:]
        for id in removals where aliases.bodies[id] == nil {
            guard let feature = aliases.exported[id] else { continue }
            lists[feature.body]?.removeAll { $0.id == id }
            removedLines[feature.body, default: []].append(describe(feature))
        }
        var newOrder: [String] = [], changedLines: [String: [String]] = [:], addedLines: [String: [String]] = [:]
        for raw in proposal.features {
            var feature = raw.normalized()
            if let original = aliases.exported[feature.id] {
                guard feature.body == original.body else { throw Failure("\(feature.id) belongs to \(original.body); a feature cannot move to another solid.") }
                guard !removedBodies.contains(feature.body) else { throw Failure("\(feature.id) is in \(feature.body), which is removed.") }
                var copy = feature
                copy.note = original.note
                guard !copy.matches(original) else { continue }
                if original.kind == .locked {
                    throw Failure("\(feature.id) is locked (\(original.note ?? "a feature the document cannot describe")): keep it unchanged or remove it.")
                }
                guard let index = lists[feature.body]?.firstIndex(where: { $0.id == feature.id }) else { continue }
                lists[feature.body]![index].feature = feature
                lists[feature.body]![index].rebuilt = true
                changedLines[feature.body, default: []].append("\(describe(original)) → \(describe(feature))")
            } else {
                guard aliases.features[feature.id] == nil, aliases.bodies[feature.id] == nil, !feature.id.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw Failure("Feature ID \"\(feature.id)\" is already used; give new features new IDs.")
                }
                guard !removedBodies.contains(feature.body) else { throw Failure("\(feature.id) is added to \(feature.body), which is removed.") }
                guard feature.kind != .locked else { throw Failure("\(feature.id): locked features cannot be added; use block, cylinder, polygon, hole, fillet, chamfer, or shell.") }
                if aliases.bodies[feature.body] == nil, lists[feature.body] == nil { newOrder.append(feature.body) }
                lists[feature.body, default: []].append(Entry(id: feature.id, feature: feature, rebuilt: true, role: nil))
                if aliases.bodies[feature.body] != nil { addedLines[feature.body, default: []].append(describe(feature)) }
            }
        }

        var next = start, touched: [UUID] = [], changes: [String] = [], newBodies: [String: UUID] = [:]
        // Existing solids, in document order.
        for (index, body) in start.bodies.enumerated() {
            guard let alias = aliases.alias(of: body.id) else { continue }
            let name = bench.bodyName(body.id)
            if removedBodies.contains(alias) {
                next.bodies.removeAll { $0.id == body.id }
                changes.append("Deleted \(name)")
                continue
            }
            var parts: [String] = []
            if let changed = changedLines[alias] { parts.append(grouped(changed)) }
            if let added = addedLines[alias] { parts.append("added " + grouped(added)) }
            if let removed = removedLines[alias] { parts.append("removed " + grouped(removed)) }
            guard !parts.isEmpty, let list = lists[alias] else { continue }
            let rebuilt = try build(list, from: body, alias: alias, bench: bench)
            if let position = next.bodies.firstIndex(where: { $0.id == body.id }) { next.bodies[position] = rebuilt } else { next.bodies.insert(rebuilt, at: min(index, next.bodies.count)) }
            touched.append(body.id)
            changes.append("\(name): " + parts.joined(separator: "; "))
        }
        // New solids, in the order the proposal first named them.
        for key in newOrder {
            guard let list = lists[key], let first = list.first else { continue }
            guard [.block, .cylinder, .polygon].contains(first.feature.kind), (first.feature.operation ?? .add) == .add else {
                throw Failure("The first feature of new solid \"\(key)\" (\(first.id)) must add a block, cylinder, or polygon.")
            }
            var seed = SolidBody(profile: SketchProfile(id: "template", plane: .top, sourceIDs: [], outline: []), depth: 1)
            seed.name = ItemNames.cleaned(key)
            let body = try build(list, from: seed, alias: key, bench: bench)
            next.bodies.append(body)
            touched.append(body.id)
            newBodies[key] = body.id
            let rest = list.dropFirst().map { describe($0.feature) }
            changes.append("New \(body.name ?? key): \(describe(first.feature))" + (rest.isEmpty ? "" : "; then " + grouped(rest)))
        }
        return Result(workspace: next, changes: changes, touched: touched, newBodies: newBodies)
    }

    // MARK: Building a solid

    /// `list` built onto `original`: its base, finishes, and steps, in order.
    private static func build(_ list: [Entry], from original: SolidBody, alias: String, bench: AssistantWorkbench) throws -> SolidBody {
        guard let first = list.first else { throw Failure("\(alias) has no features left; remove the solid instead.") }
        var body = original
        body.finishes = []
        body.cuts = []
        if first.rebuilt {
            guard [.block, .cylinder, .polygon].contains(first.feature.kind), (first.feature.operation ?? .add) == .add else {
                throw Failure("\(first.id) is the first feature of \(alias): it must add a block, cylinder, or polygon.")
            }
            let made = try extrusion(first.feature)
            body.profile = made.profile
            body.depth = made.height
            body.symmetric = nil
            body.taper = nil
            body.revolve = nil
            body.imported = nil
        } else if first.role != .base {
            throw Failure("\(first.id) cannot come first in \(alias).")
        }
        for entry in list.dropFirst() {
            do { try add(entry, to: &body, original: original, bench: bench) }
            catch let failure as Failure { throw Failure("\(entry.id): \(failure.message)") }
        }
        return body
    }

    private static func add(_ entry: Entry, to body: inout SolidBody, original: SolidBody, bench: AssistantWorkbench) throws {
        let feature = entry.feature
        // Unchanged: the native finish or step exactly as it was.
        if !entry.rebuilt {
            switch entry.role {
            case .finish(let id)?:
                guard let finish = original.finishes.first(where: { $0.id == id }) else { throw Failure("Its original edges are gone.") }
                guard body.cuts.isEmpty else { throw Failure("A fillet on the original extrusion must come before the other steps.") }
                body.finishes.append(finish)
            case .step(let id)?:
                guard let step = original.cuts.first(where: { $0.id == id }) else { throw Failure("Its original step is gone.") }
                body.cuts.append(step)
            default: throw Failure("Only the first feature can be the solid's base.")
            }
            return
        }
        let existingStep: ExtrusionCut? = {
            if case .step(let id)? = entry.role { return original.cuts.first { $0.id == id } }
            return nil
        }()
        var step: ExtrusionCut
        switch feature.kind {
        case .block, .cylinder, .polygon:
            let operation = feature.operation ?? .add
            let through = operation == .cut && feature.throughAll == true
            if operation == .add && feature.throughAll == true { throw Failure("Through all is for cuts only.") }
            let made = try extrusion(feature, throughAll: through)
            step = ExtrusionCut(profile: made.profile, depth: made.height, throughAll: through, operation: operation == .add ? .join : .cut)
        case .hole:
            step = try hole(feature)
        case .fillet, .chamfer:
            let kind: EdgeFinish.Kind = feature.kind == .fillet ? .fillet : .chamfer
            guard let size = feature.size, size.isFinite, EdgeFinish.sizeRange.contains(size) else {
                throw Failure("Give the \(kind.rawValue) a size of \(AssistantWorkbench.mm(EdgeFinish.sizeRange.lowerBound))–\(AssistantWorkbench.mm(EdgeFinish.sizeRange.upperBound)) mm.")
            }
            let rule = feature.edges?.trimmingCharacters(in: .whitespaces) ?? ""
            if case .finish(let id)? = entry.role {
                // A fillet on the original extrusion: its size may change; new edges need a new fillet.
                guard rule.isEmpty, var finish = original.finishes.first(where: { $0.id == id }) else {
                    throw Failure("To round other edges, remove this \(kind.rawValue) and add a new one.")
                }
                guard body.cuts.isEmpty else { throw Failure("A fillet on the original extrusion must come before the other steps.") }
                finish.kind = kind
                finish.size = size
                body.finishes.append(finish)
                return
            }
            if rule.isEmpty {
                guard var spec = existingStep?.finish else { throw Failure("Say which edges to \(kind == .fillet ? "round" : "bevel"), such as \"top\" or \"outside vertical\".") }
                spec.kind = kind
                spec.size = size
                step = .finish(of: body, spec)
            } else {
                let solid = try built(body)
                let edges = try bench.edges(rule, of: body)
                let references = edges.compactMap { body.edgeReference($0, of: solid) }
                guard references.count == edges.count, !references.isEmpty else { throw Failure("Those edges cannot be named on the solid.") }
                step = .finish(of: body, FinishSpec(kind: kind, size: size, edges: references))
            }
        case .shell:
            guard let thickness = feature.size, thickness.isFinite, (0.2...100).contains(thickness) else { throw Failure("Shell walls must be 0.2–100 mm thick.") }
            let faces = (feature.faces ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if faces.isEmpty {
                guard var spec = existingStep?.shell else { throw Failure("Name at least one face to leave open, such as \"top\".") }
                spec.thickness = thickness
                step = ExtrusionCut(profile: body.profile, depth: body.depth)
                step.shell = spec
            } else {
                let solid = try built(body)
                var named: [ExtrusionFace] = [], points: [SIMD3<Double>] = []
                for spec in faces {
                    let index = try bench.face(spec, of: body)
                    if let face = body.extrusionFace(index, of: solid), !named.contains(face) { named.append(face) }
                    else if let point = solid.interiorPoint(of: index) { points.append(point) }
                    else { throw Failure("Face \"\(spec)\" cannot be opened.") }
                }
                step = .shell(of: body, openFaces: named, openingAt: points, thickness: thickness)
            }
        case .locked:
            throw Failure("Locked features cannot be changed.")
        }
        step.id = existingStep?.id ?? UUID()
        body.cuts.append(step)
        guard body.cuts.count <= ExtrusionCut.maximumPerBody else { throw Failure("A solid holds at most \(ExtrusionCut.maximumPerBody) steps.") }
    }

    private static func built(_ body: SolidBody) throws -> KernelSolid {
        do { return try SolidKernel.solid(for: body) }
        catch { throw Failure("The solid does not build before this feature.") }
    }

    // MARK: Profiles

    /// A block, cylinder, or polygon feature as a profile on the plane through its start, facing
    /// along its axis, and the distance to extrude it.
    static func extrusion(_ f: DesignFeature, throughAll: Bool = false) throws -> (profile: SketchProfile, height: Double) {
        let axis = f.axis ?? .pz
        let start = SIMD3(f.x ?? 0, f.y ?? 0, f.z ?? 0)
        guard [start.x, start.y, start.z].allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else { throw Failure("Positions must be within ±10000 mm.") }
        let height: Double
        if throughAll { height = 1 } else {
            guard let h = f.height, h.isFinite, (0.01...10_000).contains(h) else { throw Failure("Give a height of 0.01–10000 mm along the axis.") }
            height = h
        }
        guard let plane = SketchPlane.through(start, normal: axis.vector) else { throw Failure("Invalid start point.") }
        let profile: SketchProfile
        switch f.kind {
        case .block:
            guard let w = f.width, let d = f.depth, w.isFinite, d.isFinite, (0.01...10_000).contains(w), (0.01...10_000).contains(d) else {
                throw Failure("A block needs a width and depth of 0.01–10000 mm.")
            }
            let r = f.radius ?? 0
            guard r.isFinite, r >= 0 else { throw Failure("Corner radius must be 0 or more.") }
            if r > 0 && (r < 0.01 || r > min(w, d) / 2 - 0.01) {
                throw Failure("Corner radius must be 0, or 0.01 mm up to just under half the shorter side (\(AssistantWorkbench.mm(min(w, d) / 2 - 0.01)) mm).")
            }
            profile = roundedRectangle(center: start, axis: axis, width: w, depth: d, radius: r, on: plane)
        case .cylinder:
            guard let r = f.radius, r.isFinite, (0.01...5_000).contains(r) else { throw Failure("A cylinder needs a radius of 0.01–5000 mm (half its diameter).") }
            profile = TemplateGeometry.circle(r * 2, around: start, facing: axis.vector, points: 128)
        case .polygon:
            guard let points = f.points, (3...64).contains(points.count),
                  points.allSatisfy({ $0.u.isFinite && $0.v.isFinite && max(abs($0.u), abs($0.v)) <= 10_000 }) else {
                throw Failure("A polygon needs 3–64 points (u, v) within ±10000 mm.")
            }
            guard points.indices.allSatisfy({ i in
                let a = points[i], b = points[(i + 1) % points.count]
                return hypot(b.u - a.u, b.v - a.v) >= 0.001
            }) else { throw Failure("Polygon points must be at least 0.001 mm apart, without repeating the first point.") }
            let (ia, ib) = axis.across
            let world = points.map { p -> SIMD3<Double> in
                var w = start
                w[ia] += p.u
                w[ib] += p.v
                return w
            }
            profile = TemplateGeometry.polygon(world, on: plane)
        default:
            throw Failure("\(f.kind.rawValue) is not an extrusion.")
        }
        guard profile.isSolidProfile else { throw Failure("The outline crosses itself or has no area.") }
        return (profile, height)
    }

    /// A rectangle `width` along the axis's first cross axis and `depth` along its second (Z: X
    /// and Y; Y: X and Z; X: Y and Z), centered on `center`, its corners true arcs of `radius`.
    private static func roundedRectangle(center: SIMD3<Double>, axis: DesignFeature.Axis, width: Double, depth: Double, radius: Double,
                                         on plane: SketchPlane) -> SketchProfile {
        let (ia, ib) = axis.across
        func local(_ a: Double, _ b: Double) -> Point2 {
            var w = center
            w[ia] += a
            w[ib] += b
            return plane.coordinates(of: w)
        }
        let hx = width / 2, hy = depth / 2, segments = 8
        var outline: [Point2] = [], arcs: [ProfileArc] = []
        let corners: [(Double, Double, Double)] = [(1, -1, -Double.pi / 2), (1, 1, 0), (-1, 1, Double.pi / 2), (-1, -1, Double.pi)]
        for (sx, sy, from) in corners {
            guard radius >= 0.01 else { outline.append(local(sx * hx, sy * hy)); continue }
            let ca = sx * (hx - radius), cb = sy * (hy - radius)
            let begin = outline.count
            for step in 0...segments {
                let a = from + Double.pi / 2 * Double(step) / Double(segments)
                outline.append(local(ca + cos(a) * radius, cb + sin(a) * radius))
            }
            arcs.append(ProfileArc(start: begin, segments: segments, center: local(ca, cb), radius: radius))
        }
        if Geometry.signedArea(outline) < 0 {
            // Counterclockwise about the plane's normal, the arcs renumbered from the new start.
            let n = outline.count
            outline.reverse()
            arcs = arcs.map { arc in
                let end = (arc.start + arc.segments) % n
                return ProfileArc(start: n - 1 - end, segments: arc.segments, center: arc.center, radius: arc.radius)
            }
        }
        return SketchProfile(id: "template", plane: plane, sourceIDs: [], outline: outline, arcs: arcs.isEmpty ? nil : arcs)
    }

    private static func hole(_ f: DesignFeature) throws -> ExtrusionCut {
        guard let wanted = f.hole else { throw Failure("A hole needs its hole settings (type and diameter or size).") }
        guard let axis = f.axis else { throw Failure("A hole needs an axis: the outward normal of the face it enters.") }
        let entry = SIMD3(f.x ?? 0, f.y ?? 0, f.z ?? 0)
        guard [entry.x, entry.y, entry.z].allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else { throw Failure("Positions must be within ±10000 mm.") }
        var spec: HoleSpec
        if let size = wanted.size?.uppercased().replacingOccurrences(of: " ", with: ""), HolePresets.sizes.contains(size) {
            spec = HolePresets.spec(wanted.type, size: size)
        } else {
            guard let diameter = wanted.diameter else { throw Failure("Give a hole diameter, or a size from \(HolePresets.sizes.joined(separator: ", ")).") }
            spec = HoleSpec(kind: wanted.type, size: "Ø\(AssistantWorkbench.mm(diameter))", diameter: diameter)
        }
        if let diameter = wanted.diameter { spec.diameter = diameter }
        if let value = wanted.counterboreDiameter { spec.counterboreDiameter = value }
        if let value = wanted.counterboreDepth { spec.counterboreDepth = value }
        if let value = wanted.countersinkDiameter { spec.countersinkDiameter = value }
        if let value = wanted.countersinkAngle { spec.countersinkAngle = value }
        guard spec.isValid else { throw Failure("Invalid hole: diameter 0.1–200 mm; a counterbore wider than the hole with a depth; a countersink wider than the hole.") }
        var depth: Double?
        if f.throughAll != true {
            depth = f.height ?? HolePresets.defaultDepth(spec.kind, size: spec.size)
            guard let d = depth, d.isFinite, (0.01...10_000).contains(d) else { throw Failure("Give the hole a depth (height) of 0.01–10000 mm, or make it through all.") }
        }
        guard let plane = SketchPlane.through(entry, normal: axis.vector),
              let step = ExtrusionCut.hole(spec, at: plane.coordinates(of: entry), on: plane, depth: depth) else { throw Failure("That hole cannot be placed there.") }
        return step
    }

    // MARK: Words

    /// A feature in a few words, for the review card ("60 × 40 × 20 mm block", "Ø6 mm cut
    /// through", "M3 countersink hole 6 mm deep", "3 mm fillet on vertical edges"). The direction is
    /// given only when it is not the usual one (up for material, down for a cut).
    static func describe(_ f: DesignFeature) -> String {
        let mm = AssistantWorkbench.mm
        let cut = f.operation == .cut, through = f.throughAll == true
        let usual: DesignFeature.Axis = cut ? .nz : .pz
        let along = f.axis.map { through || $0 == usual ? "" : " along \($0.rawValue.uppercased())" } ?? ""
        let deep = through ? "through" : "\(mm(f.height ?? 0)) mm deep"
        switch f.kind {
        case .block:
            let corners = (f.radius ?? 0) > 0 ? ", R\(mm(f.radius ?? 0)) corners" : ""
            let size = "\(mm(f.width ?? 0)) × \(mm(f.depth ?? 0))"
            return (cut ? "\(size) mm pocket \(deep)" : "\(size) × \(mm(f.height ?? 0)) mm block") + along + corners
        case .cylinder:
            let diameter = "Ø\(mm((f.radius ?? 0) * 2))"
            return (cut ? "\(diameter) mm cut \(deep)" : "\(diameter) × \(mm(f.height ?? 0)) mm cylinder") + along
        case .polygon:
            let sides = "\(f.points?.count ?? 0)-sided"
            return (cut ? "\(sides) cut \(deep)" : "\(sides) outline \(mm(f.height ?? 0)) mm thick") + along
        case .hole:
            let hole = f.hole
            let label = hole?.size ?? hole?.diameter.map { "Ø\(mm($0)) mm" } ?? "Hole"
            let type = hole.map { $0.type == .simple ? "" : " \($0.type.rawValue)" } ?? ""
            return "\(label)\(type) hole \(deep)"
        case .fillet: return "\(mm(f.size ?? 0)) mm fillet" + (f.edges.map { " on \($0) edges" } ?? "")
        case .chamfer: return "\(mm(f.size ?? 0)) mm chamfer" + (f.edges.map { " on \($0) edges" } ?? "")
        case .shell: return "\(mm(f.size ?? 0)) mm shell" + ((f.faces ?? []).isEmpty ? "" : ", open at \((f.faces ?? []).joined(separator: ", "))")
        case .locked: return f.note ?? "locked feature"
        }
    }

    /// Phrases in order, a repeated one once with its count ("M3 hole through ×4").
    static func grouped(_ phrases: [String]) -> String {
        var order: [String] = [], counts: [String: Int] = [:]
        for phrase in phrases {
            if counts[phrase] == nil { order.append(phrase) }
            counts[phrase, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: "; ")
    }

    private static func duplicates(_ ids: [String]) -> [String] {
        var seen = Set<String>(), repeated: [String] = []
        for id in ids where !seen.insert(id).inserted && !repeated.contains(id) { repeated.append(id) }
        return repeated
    }
}
