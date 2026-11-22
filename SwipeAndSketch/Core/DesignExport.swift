import Foundation
import simd

// Native solids → the assistant's design document (see DesignDocument.swift). Features the
// document's vocabulary describes exactly (axis-aligned blocks, cylinders, and polygons; holes;
// fillets, chamfers, and shells) are exported editable; anything else is exported `locked`, with a
// note, so the model can see it and keep or remove it but never rewrite it from a guess.

enum DesignExport {
    /// The most features the document carries for the whole workspace; past this the caller
    /// exports only the solids the request is about.
    static let featureLimit = 200

    /// The document for `workspace`. With `detail`, only those solids carry their features; the
    /// others are listed (name and size) so the model knows they are there.
    static func document(of workspace: Workspace, detail: Set<UUID>? = nil) -> (document: DesignDocument, aliases: DesignAliases) {
        var bodies: [DesignDocument.Body] = [], features: [DesignFeature] = [], aliases = DesignAliases()
        let names = workspace.bodyNames
        // Sketch regions, so a solid extruded or revolved from one can say which.
        let regions = workspace.sketches.enumerated().flatMap { index, sketch in
            workspace.profiles(in: sketch).filter(\.isSolidProfile).enumerated().map { (profile: $1, id: "S\(index + 1).R\($0 + 1)") }
        }
        let region: (SketchProfile) -> String? = { profile in regions.first { $0.profile == profile }?.id }
        for (index, body) in workspace.bodies.enumerated() {
            let alias = "B\(index + 1)"
            aliases.bodies[alias] = body.id
            var entry = DesignDocument.Body(id: alias, name: names[body.id] ?? alias, hidden: body.hidden == true ? true : nil)
            if let solid = try? SolidKernel.solid(for: body) {
                let box = solid.bounds
                entry.bounds = [box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z].map(round)
                entry.volume = round(solid.volume)
            }
            bodies.append(entry)
            guard detail?.contains(body.id) ?? true else { continue }
            var count = 0, order: [String] = []
            func add(_ feature: DesignFeature, _ role: DesignAliases.Role) {
                features.append(feature)
                aliases.features[feature.id] = .init(body: body.id, role: role)
                aliases.exported[feature.id] = feature
                order.append(feature.id)
            }
            func nextID() -> String { count += 1; return "\(alias).F\(count)" }
            add(base(of: body, id: nextID(), body: alias, region: region), .base)
            for finish in body.finishes {
                add(DesignFeature(id: nextID(), body: alias, kind: finish.kind == .fillet ? .fillet : .chamfer, size: round(finish.size),
                                  note: "\(finish.edges.count) edge\(finish.edges.count == 1 ? "" : "s") of the original extrusion"),
                    .finish(finish.id))
            }
            for step in body.cuts { add(feature(step, of: body, id: nextID(), body: alias, region: region), .step(step.id)) }
            aliases.order[alias] = order
        }
        // Sketches: their regions listed, their shapes as features.
        var sketches: [DesignDocument.Sketch] = []
        let sketchNames = workspace.sketchNames
        for (index, sketch) in workspace.sketches.enumerated() {
            let alias = "S\(index + 1)"
            aliases.sketches[alias] = sketch.id
            let plane = sketch.plane, facing = worldAxis(plane.normalAxis)
            let where_ = facing.map { "\($0.rawValue.dropFirst()) = \(AssistantWorkbench.mm(round(plane.origin[$0.index]))) (normal \($0.rawValue))" } ?? "a slanted plane"
            let listed = regions.filter { $0.id.hasPrefix(alias + ".R") }.map { entry in
                DesignDocument.Sketch.Region(id: entry.id, shape: outlineWords(entry.profile), center: entry.profile.plane.point(entry.profile.center).map(round).array)
            }
            sketches.append(DesignDocument.Sketch(id: alias, name: sketchNames[sketch.id] ?? alias, hidden: sketch.hidden == true ? true : nil,
                                                  plane: where_, regions: listed))
            var count = 0, order: [String] = []
            for shape in workspace.shapes(in: sketch.id) {
                count += 1
                let feature = shapeFeature(shape, on: plane, id: "\(alias).F\(count)", sketch: alias)
                features.append(feature)
                aliases.features[feature.id] = .init(body: sketch.id, role: .shape(shape.id))
                aliases.exported[feature.id] = feature
                order.append(feature.id)
            }
            aliases.order[alias] = order
        }
        return (DesignDocument(bodies: bodies, features: features, sketches: sketches), aliases)
    }

    /// A sketch shape as a feature of its sketch, or locked when the vocabulary cannot say it.
    private static func shapeFeature(_ shape: SketchShape, on plane: SketchPlane, id: String, sketch alias: String) -> DesignFeature {
        guard let facing = worldAxis(plane.normalAxis), !shape.isConstruction else {
            return locked(id, alias, "\(shape.isConstruction ? "construction " : "")\(shape.kind.rawValue)" + (worldAxis(plane.normalAxis) == nil ? " on a slanted plane" : ""))
        }
        let (ia, ib) = facing.across, along = plane.origin[facing.index]
        func flat(_ p: Point2) -> DesignFeature.Point { let w = plane.point(p); return .init(u: round(w[ia]), v: round(w[ib])) }
        func at(_ p: Point2?) -> SIMD3<Double> {
            var w = SIMD3<Double>(repeating: 0)
            if let p { w = plane.point(p) }
            w[facing.index] = along
            return w.map(round)
        }
        var feature = DesignFeature(id: id, body: alias, kind: .locked, axis: facing)
        func place(_ p: Point2?) { let w = at(p); feature.x = w.x; feature.y = w.y; feature.z = w.z }
        switch shape.kind {
        case .rectangle:
            let a = plane.point(shape.start), b = plane.point(shape.end)
            feature.kind = .rectangle
            feature.width = round(abs(b[ia] - a[ia])); feature.depth = round(abs(b[ib] - a[ib]))
            place(shape.center)
        case .circle:
            feature.kind = .circle
            feature.radius = round(shape.start.distance(to: shape.end))
            place(shape.start)
        case .line:
            feature.kind = .line
            feature.points = [flat(shape.start), flat(shape.end)]
            place(nil)
        case .arc:
            guard let c = shape.arcCenter else { return locked(id, alias, "arc") }
            let r = c.distance(to: shape.start)
            let a0 = atan2(shape.start.y - c.y, shape.start.x - c.x), a1 = atan2(shape.end.y - c.y, shape.end.x - c.x)
            var sweep = a1 - a0
            while sweep <= 0 { sweep += 2 * .pi }
            let middle = c + Point2(x: cos(a0 + sweep / 2), y: sin(a0 + sweep / 2)) * r
            feature.kind = .arc
            feature.points = [flat(shape.start), flat(middle), flat(shape.end)]
            place(nil)
        case .slot:
            guard let width = shape.width else { return locked(id, alias, "slot") }
            feature.kind = .slot
            feature.points = [flat(shape.start), flat(shape.end)]
            feature.size = round(width)
            place(nil)
        case .ellipse, .curve, .point:
            return locked(id, alias, shape.kind == .curve ? (shape.isSpline ? "spline" : "curve") : shape.kind.rawValue)
        }
        return feature
    }

    /// A revolved profile as a revolve feature: points about a world axis when the profile is a
    /// plain polygon in the plane holding the axis and its first cross axis, else the sketch region
    /// it was made from; nil when neither says it.
    private static func revolved(_ profile: SketchProfile, _ spec: RevolveSpec, id: String, body alias: String, region: (SketchProfile) -> String?) -> DesignFeature? {
        let axisLine = spec.axis(on: profile.plane)
        guard let axis = worldAxis(axisLine.direction) else { return nil }
        let (ia, ib) = axis.across, origin = axisLine.origin.map(round)
        var feature = DesignFeature(id: id, body: alias, kind: .revolve, axis: axis, x: origin.x, y: origin.y, z: origin.z,
                                    size: spec.isFull ? nil : round(spec.angle))
        if profile.circle == nil, profile.arcs == nil, (profile.holes ?? []).isEmpty, profile.ellipse == nil,
           (3...64).contains(profile.outline.count), abs(abs(profile.plane.normalAxis[ib]) - 1) < 1e-9 {
            feature.points = profile.outline.map { p in
                let w = profile.plane.point(p) - axisLine.origin
                return DesignFeature.Point(u: round(w[ia]), v: round(simd_dot(w, axis.vector)))
            }
            return feature
        }
        guard let named = region(profile) else { return nil }
        feature.region = named
        return feature
    }

    /// A profile extruded `depth` (signed along its plane's normal) as the sketch region it came from.
    private static func extruded(_ profile: SketchProfile, depth: Double, throughAll: Bool, id: String, body alias: String, region: (SketchProfile) -> String?) -> DesignFeature? {
        guard let named = region(profile), let facing = worldAxis(profile.plane.normalAxis),
              let axis = DesignFeature.Axis(index: facing.index, sign: throughAll ? facing.sign : facing.sign * (depth < 0 ? -1 : 1)) else { return nil }
        return DesignFeature(id: id, body: alias, kind: .extrude, axis: axis, height: throughAll ? nil : round(abs(depth)),
                             throughAll: throughAll ? true : nil, region: named)
    }

    /// Feature count of a full export, to decide whether it fits.
    static func featureCount(of workspace: Workspace) -> Int {
        workspace.bodies.reduce(0) { $0 + 1 + $1.finishes.count + $1.cuts.count } + workspace.shapes.filter { $0.sketch != nil }.count
    }

    // MARK: Features

    private static func base(of body: SolidBody, id: String, body alias: String, region: (SketchProfile) -> String?) -> DesignFeature {
        if body.imported != nil { return locked(id, alias, "imported shape") }
        if body.peg != nil { return locked(id, alias, "separate peg Ø\(AssistantWorkbench.mm((body.profile.circle?.radius ?? 0) * 2)) mm") }
        if let revolve = body.revolve {
            guard var feature = revolved(body.profile, revolve, id: id, body: alias, region: region) else {
                return locked(id, alias, "profile revolved \(AssistantWorkbench.mm(revolve.angle))°")
            }
            feature.operation = .add
            return feature
        }
        if body.symmetric == true || (body.taper ?? 0) != 0 {
            return locked(id, alias, "profile extruded \(AssistantWorkbench.mm(abs(body.depth))) mm" + (body.symmetric == true ? " both ways" : "") +
                          ((body.taper ?? 0) != 0 ? " with \(AssistantWorkbench.mm(body.taper ?? 0))° taper" : ""))
        }
        guard var feature = shape(body.profile, depth: body.depth, throughAll: false, id: id, body: alias)
                ?? extruded(body.profile, depth: body.depth, throughAll: false, id: id, body: alias, region: region) else {
            return locked(id, alias, "\(outlineWords(body.profile)) extruded \(AssistantWorkbench.mm(abs(body.depth))) mm")
        }
        feature.operation = .add
        return feature
    }

    private static func feature(_ step: ExtrusionCut, of body: SolidBody, id: String, body alias: String, region: (SketchProfile) -> String?) -> DesignFeature {
        if step.peg != nil {
            // A peg, its tip's bevel, and its sockets stay linked by the peg's id; rebuilding one
            // as a plain cylinder or chamfer would break that.
            let diameter = step.profile.circle.map { " Ø\(AssistantWorkbench.mm($0.radius * 2))" } ?? ""
            switch step.operation {
            case .join: return locked(id, alias, "peg\(diameter) × \(AssistantWorkbench.mm(abs(step.depth))) mm")
            case .cut: return locked(id, alias, "socket\(diameter) for a peg")
            default: return locked(id, alias, "bevel on a peg's tip")
            }
        }
        switch step.operation {
        case .cut, .join:
            let words = "\(step.operation == .cut ? "cut" : "boss"): \(outlineWords(step.profile))" +
                (step.throughAll ? " through all" : " \(AssistantWorkbench.mm(abs(step.depth))) mm")
            if let revolve = step.revolve, step.facePoint == nil, var feature = revolved(step.profile, revolve, id: id, body: alias, region: region) {
                feature.operation = step.operation == .cut ? .cut : .add
                return feature
            }
            guard step.facePoint == nil, step.revolve == nil, step.symmetric != true, (step.taper ?? 0) == 0,
                  !(step.throughAll && step.operation == .join),
                  var feature = shape(step.profile, depth: step.depth, throughAll: step.throughAll, id: id, body: alias)
                    ?? extruded(step.profile, depth: step.depth, throughAll: step.throughAll, id: id, body: alias, region: region) else {
                return locked(id, alias, words + (step.facePoint != nil ? " from a face" : step.revolve != nil ? " (revolved)" : ""))
            }
            feature.operation = step.operation == .cut ? .cut : .add
            return feature
        case .hole:
            guard let spec = step.hole, let circle = step.profile.circle, let axis = worldAxis(step.profile.plane.normalAxis) else {
                return locked(id, alias, "hole")
            }
            let center = step.profile.plane.point(circle.center).map(round)
            var hole = DesignFeature.Hole(type: spec.kind, size: HolePresets.size(spec.size, for: spec.kind), diameter: round(spec.diameter))
            if spec.kind == .counterbore { hole.counterboreDiameter = round(spec.counterboreDiameter); hole.counterboreDepth = round(spec.counterboreDepth) }
            if spec.kind == .countersink { hole.countersinkDiameter = round(spec.countersinkDiameter); hole.countersinkAngle = round(spec.countersinkAngle) }
            return DesignFeature(id: id, body: alias, kind: .hole, axis: axis, x: center.x, y: center.y, z: center.z,
                                 height: step.throughAll ? nil : round(step.depth), throughAll: step.throughAll ? true : nil, hole: hole)
        case .finish:
            guard let finish = step.finish else { return locked(id, alias, "finish") }
            return DesignFeature(id: id, body: alias, kind: finish.kind == .fillet ? .fillet : .chamfer, size: round(finish.size),
                                 note: "\(finish.edges.count) edge\(finish.edges.count == 1 ? "" : "s")")
        case .shell:
            guard let shell = step.shell else { return locked(id, alias, "shell") }
            let open = shell.openFaces.count + (shell.openPoints?.count ?? 0)
            return DesignFeature(id: id, body: alias, kind: .shell, size: round(shell.thickness),
                                 note: "open at \(open) face\(open == 1 ? "" : "s")")
        case .merge: return locked(id, alias, "union with another solid")
        case .subtract: return locked(id, alias, "another solid subtracted")
        case .intersect: return locked(id, alias, "intersected with another solid")
        case .split: return locked(id, alias, "split")
        case .scale: return locked(id, alias, "scaled")
        case .deleteFace: return locked(id, alias, "faces deleted")
        case .offsetFace: return locked(id, alias, "faces moved")
        case .draft: return locked(id, alias, "draft angle on faces")
        case .rib: return locked(id, alias, "rib")
        case .thread:
            guard let thread = step.thread else { return locked(id, alias, "thread") }
            return locked(id, alias, "\(thread.isInternal ? "internal" : "external") thread \(thread.size) × \(AssistantWorkbench.mm(thread.length)) mm")
        case .text:
            return locked(id, alias, "text \"\(step.text?.text ?? "")\" \(step.depth < 0 ? "debossed" : "embossed")")
        }
    }

    private static func locked(_ id: String, _ body: String, _ note: String) -> DesignFeature {
        DesignFeature(id: id, body: body, kind: .locked, note: note)
    }

    /// A profile on a plane facing along a world axis as a block, cylinder, or polygon, extruded
    /// `depth` (signed along the plane's normal), or nil when the vocabulary cannot say it exactly.
    static func shape(_ profile: SketchProfile, depth: Double, throughAll: Bool, id: String, body: String) -> DesignFeature? {
        guard (profile.holes ?? []).isEmpty, profile.ellipse == nil,
              let facing = worldAxis(profile.plane.normalAxis),
              let axis = DesignFeature.Axis(index: facing.index, sign: throughAll ? facing.sign : facing.sign * (depth < 0 ? -1 : 1)) else { return nil }
        let plane = profile.plane, along = plane.origin[axis.index], (ia, ib) = axis.across
        let height: Double? = throughAll ? nil : round(abs(depth))
        var feature = DesignFeature(id: id, body: body, kind: .locked, axis: axis, height: height, throughAll: throughAll ? true : nil)
        func place(_ a: Double, _ b: Double) {
            var p = SIMD3<Double>(repeating: 0)
            p[ia] = a; p[ib] = b; p[axis.index] = along
            p = p.map(round)
            feature.x = p.x; feature.y = p.y; feature.z = p.z
        }
        if let circle = profile.circle {
            let center = plane.point(circle.center)
            feature.kind = .cylinder
            feature.radius = round(circle.radius)
            place(center[ia], center[ib])
            return feature
        }
        let world = profile.outline.map { plane.point($0) }
        let a = world.map { $0[ia] }, b = world.map { $0[ib] }
        guard let minA = a.min(), let maxA = a.max(), let minB = b.min(), let maxB = b.max() else { return nil }
        if let radius = roundedRectangleRadius(profile, across: (ia, ib), box: (minA, maxA, minB, maxB)) {
            feature.kind = .block
            feature.width = round(maxA - minA)
            feature.depth = round(maxB - minB)
            feature.radius = radius > 0 ? round(radius) : nil
            place((minA + maxA) / 2, (minB + maxB) / 2)
            return feature
        }
        guard profile.arcs == nil, (3...64).contains(profile.outline.count) else { return nil }
        feature.kind = .polygon
        feature.points = zip(a, b).map { DesignFeature.Point(u: round($0), v: round($1)) }
        place(0, 0)
        return feature
    }

    /// The corner radius when the profile is an axis-aligned rectangle (0) or one with four equal
    /// round corners, else nil.
    private static func roundedRectangleRadius(_ profile: SketchProfile, across: (Int, Int), box: (Double, Double, Double, Double)) -> Double? {
        let (ia, ib) = across, (minA, maxA, minB, maxB) = box
        let tolerance = 1e-6 * max(1, maxA - minA, maxB - minB)
        let plane = profile.plane
        func flat(_ p: Point2) -> (Double, Double) { let w = plane.point(p); return (w[ia], w[ib]) }
        func onBox(_ p: (Double, Double)) -> Bool {
            (abs(p.0 - minA) <= tolerance || abs(p.0 - maxA) <= tolerance) && (minB - tolerance...maxB + tolerance).contains(p.1) ||
            (abs(p.1 - minB) <= tolerance || abs(p.1 - maxB) <= tolerance) && (minA - tolerance...maxA + tolerance).contains(p.0)
        }
        let points = profile.outline.map(flat)
        guard let arcs = profile.arcs, !arcs.isEmpty else {
            // Corners only (collinear points dropped): exactly the four corners of the box.
            let corners = points.indices.filter { i in
                let p = points[(i + points.count - 1) % points.count], q = points[i], r = points[(i + 1) % points.count]
                return abs((q.0 - p.0) * (r.1 - q.1) - (q.1 - p.1) * (r.0 - q.0)) > tolerance * max(1, maxA - minA, maxB - minB)
            }
            guard corners.count == 4, points.allSatisfy(onBox),
                  corners.allSatisfy({ i in
                      let q = points[i]
                      return (abs(q.0 - minA) <= tolerance || abs(q.0 - maxA) <= tolerance) && (abs(q.1 - minB) <= tolerance || abs(q.1 - maxB) <= tolerance)
                  }) else { return nil }
            return 0
        }
        guard arcs.count == 4, let radius = arcs.first?.radius, arcs.allSatisfy({ abs($0.radius - radius) <= tolerance }),
              radius * 2 < min(maxA - minA, maxB - minB) else { return nil }
        // Each arc's center sits a radius in from a different corner of the box.
        var corners = Set<Int>()
        for arc in arcs {
            let c = flat(arc.center)
            guard let corner = [(minA + radius, minB + radius), (maxA - radius, minB + radius), (maxA - radius, maxB - radius), (minA + radius, maxB - radius)]
                .firstIndex(where: { abs($0.0 - c.0) <= tolerance && abs($0.1 - c.1) <= tolerance }) else { return nil }
            corners.insert(corner)
        }
        guard corners.count == 4 else { return nil }
        // Every other point lies on the box's sides.
        var onArc = Set<Int>()
        for arc in arcs { for k in 0...arc.segments { onArc.insert((arc.start + k) % points.count) } }
        guard points.indices.allSatisfy({ onArc.contains($0) || onBox(points[$0]) }) else { return nil }
        return radius
    }

    /// The world axis a direction lies along, with its sign, or nil.
    static func worldAxis(_ direction: SIMD3<Double>) -> DesignFeature.Axis? {
        guard simd_length(direction) > 1e-12 else { return nil }
        let n = simd_normalize(direction)
        guard let index = (0..<3).first(where: { abs(n[$0]) > 1 - 1e-9 }) else { return nil }
        return DesignFeature.Axis(index: index, sign: n[index])
    }

    static func outlineWords(_ profile: SketchProfile) -> String {
        if let circle = profile.circle { return "Ø\(AssistantWorkbench.mm(circle.radius * 2)) circle" }
        let xs = profile.outline.map(\.x), ys = profile.outline.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
        var words = "\(AssistantWorkbench.mm(w)) × \(AssistantWorkbench.mm(h)) \(profile.arcs == nil ? "outline" : "rounded outline")"
        if let holes = profile.holes, !holes.isEmpty { words += " with \(holes.count) opening\(holes.count == 1 ? "" : "s")" }
        if profile.ellipse != nil { words = "ellipse" }
        if !(worldAxis(profile.plane.normalAxis) != nil) { words += " on a slanted plane" }
        return words
    }

    /// Millimeters to 0.0001, enough for print work and short in the model's input.
    static func round(_ value: Double) -> Double {
        let rounded = (value * 10_000).rounded() / 10_000
        return rounded == 0 ? 0 : rounded
    }
}

private extension SIMD3 where Scalar == Double {
    func map(_ transform: (Double) -> Double) -> SIMD3<Double> { SIMD3(transform(x), transform(y), transform(z)) }
    var array: [Double] { [x, y, z] }
}
