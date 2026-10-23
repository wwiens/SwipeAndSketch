import Foundation

// Dimensions between sketch items: pick a point, line, or circle, then another,
// and the distances or the angle between them appear; typing a value moves the second pick to
// match. Nothing is remembered afterwards (there are no constraints): it is an exact way to place.
//
// What moves: when the two picks are joined (directly or through other shapes), the second one is
// reshaped in place (an end moves, or a line moves and the lines joined to it stretch), so a
// dimension inside an outline changes the outline. Otherwise the second pick's whole connected
// outline moves rigidly, so a dimension between outlines positions one from the other. A pick
// from a solid (a corner, center, or straight edge on the sketch plane) never moves.

/// Something a sketch dimension measures from or to.
struct SketchReference: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case point(Point2)
        case line(Point2, Point2)
        case circle(center: Point2, radius: Double)
    }
    /// Which part of the shape: an end or corner, its center, one side, or all of it.
    enum Part: Equatable, Sendable { case start, end, center, corner(Int), side(Int), whole }
    var kind: Kind
    /// The sketch shape it belongs to; nil for fixed references from solids or the origin.
    var shapeID: UUID?
    var part: Part = .whole

    static func fixed(_ kind: Kind) -> SketchReference { SketchReference(kind: kind, shapeID: nil) }

    /// A reference to part of a shape, as the shape is now.
    static func part(_ part: Part, of shape: SketchShape) -> SketchReference? {
        let kind: Kind
        switch (shape.kind, part) {
        case (.line, .whole): kind = .line(shape.start, shape.end)
        case (.line, .start), (.arc, .start), (.slot, .start): kind = .point(shape.start)
        case (.line, .end), (.arc, .end), (.slot, .end): kind = .point(shape.end)
        case (.circle, .center), (.ellipse, .center), (.point, .center): kind = .point(shape.start)
        case (.circle, .whole): kind = .circle(center: shape.start, radius: shape.start.distance(to: shape.end))
        case (.arc, .center): kind = .point(shape.arcCenter ?? shape.start)
        case (.arc, .whole): kind = .circle(center: shape.arcCenter ?? shape.start, radius: shape.arcCenter.map { shape.start.distance(to: $0) } ?? 0)
        case (.rectangle, .center): kind = .point(shape.center)
        case (.rectangle, .corner(let i)): kind = .point(shape.outline[((i % 4) + 4) % 4])
        case (.rectangle, .side(let i)):
            let p = shape.outline
            kind = .line(p[((i % 4) + 4) % 4], p[(((i + 1) % 4) + 4) % 4])
        case (.slot, .side(let i)):
            let d = shape.end - shape.start, length = d.length
            guard length > 1e-12 else { return nil }
            let left = Point2(x: -d.y / length, y: d.x / length) * ((shape.width ?? 0) / 2) * (i == 0 ? 1 : -1)
            kind = .line(shape.start + left, shape.end + left)
        default: return nil
        }
        return SketchReference(kind: kind, shapeID: shape.id, part: part)
    }

    /// The same reference on the shapes as they are in `workspace` (after an edit moved them).
    func resolved(in workspace: Workspace) -> SketchReference? {
        guard let shapeID else { return self }
        guard let shape = workspace.shapes.first(where: { $0.id == shapeID }) else { return nil }
        return Self.part(part, of: shape)
    }

    /// A representative point: the point, a line's middle, or a circle's center.
    var point: Point2 {
        switch kind {
        case .point(let p): p
        case .line(let a, let b): (a + b) * 0.5
        case .circle(let c, _): c
        }
    }
}

/// One measured value between (or of) picks, with what the canvas needs to draw it.
struct SketchDimension: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case horizontal, vertical, distance, angle, length, diameter, radius
        var isAngle: Bool { self == .angle }
    }
    var kind: Kind
    /// Millimeters, or degrees for an angle.
    var value: Double
    /// Linear: the two measured points. Angle: the two ray ends.
    var from: Point2
    var to: Point2
    /// Angle: where the rays meet.
    var pivot: Point2?
    /// Whether typing a value can move something.
    var editable: Bool
}

enum SketchDimensions {
    /// The dimensions of one pick (a line's length and its angle from the sketch's x axis), or between two.
    static func dimensions(_ a: SketchReference, _ b: SketchReference?, in workspace: Workspace) -> [SketchDimension] {
        guard let b else { return single(a) }
        var result = measured(a, b, in: workspace)
        // Two parts of one shape: only values a move of the second part can actually reach are editable.
        if let id = a.shapeID, id == b.shapeID {
            for index in result.indices where result[index].editable {
                let trial = result[index].kind.isAngle ? max(0, result[index].value - 1) : result[index].value + 1
                result[index].editable = applying(result[index].kind, value: trial, a, b, in: workspace) != nil
            }
        }
        return result
    }

    private static func measured(_ a: SketchReference, _ b: SketchReference, in workspace: Workspace) -> [SketchDimension] {
        let movable = a.shapeID != nil || b.shapeID != nil
        switch (a.kind, b.kind) {
        case (.line(let p0, let p1), .line(let q0, let q1)):
            let u = p1 - p0, v = q1 - q0
            guard u.length > 1e-9, v.length > 1e-9 else { return [] }
            if abs(Geometry.cross(u, v)) / (u.length * v.length) < 1e-6 {
                // Parallel: the distance between them, from b's middle square to a.
                let q = (q0 + q1) * 0.5, p = foot(q, on: p0, p1)
                return [SketchDimension(kind: .distance, value: p.distance(to: q), from: p, to: q, editable: movable && p.distance(to: q) > 1e-9)]
            }
            guard let angle = angle(a, b) else { return [] }
            // Joined, the second line turns alone (so it must be a line, not a rectangle's side).
            let moving = b.shapeID != nil ? b : a
            let turns = moving.shapeID.map { id in
                !joined(a, b, in: workspace) || (moving.part == .whole && workspace.shapes.first { $0.id == id }?.kind == .line)
            } ?? false
            return [SketchDimension(kind: .angle, value: angle.value, from: angle.rayA, to: angle.rayB, pivot: angle.pivot, editable: turns)]
        case (.line(let p0, let p1), _):
            let q = b.point, p = foot(q, on: p0, p1)
            return [SketchDimension(kind: .distance, value: p.distance(to: q), from: p, to: q, editable: movable && p.distance(to: q) > 1e-9)]
        case (_, .line(let q0, let q1)):
            let p = a.point, q = foot(p, on: q0, q1)
            return [SketchDimension(kind: .distance, value: p.distance(to: q), from: p, to: q, editable: movable && p.distance(to: q) > 1e-9)]
        default:
            let p = a.point, q = b.point
            var result: [SketchDimension] = []
            let dx = abs(q.x - p.x), dy = abs(q.y - p.y)
            if dx > 1e-6 { result.append(SketchDimension(kind: .horizontal, value: dx, from: p, to: q, editable: movable)) }
            if dy > 1e-6 { result.append(SketchDimension(kind: .vertical, value: dy, from: p, to: q, editable: movable)) }
            if dx > 1e-6 && dy > 1e-6 || result.isEmpty {
                result.append(SketchDimension(kind: .distance, value: p.distance(to: q), from: p, to: q, editable: movable && p.distance(to: q) > 1e-9))
            }
            return result
        }
    }

    private static func single(_ a: SketchReference) -> [SketchDimension] {
        switch a.kind {
        case .line(let p, let q):
            var angle = atan2(q.y - p.y, q.x - p.x) * 180 / .pi
            if angle < 0 { angle += 180 }
            if angle >= 180 - 1e-9 { angle -= 180 }
            return [SketchDimension(kind: .length, value: p.distance(to: q), from: p, to: q, editable: a.shapeID != nil && a.part == .whole),
                    SketchDimension(kind: .angle, value: angle, from: p + Point2(x: max(5, p.distance(to: q) / 2), y: 0), to: q, pivot: p,
                                    editable: a.shapeID != nil && a.part == .whole)]
        case .circle, .point: return []
        }
    }

    static func foot(_ p: Point2, on a: Point2, _ b: Point2) -> Point2 {
        let d = b - a, l2 = Geometry.dot(d, d)
        guard l2 > 1e-18 else { return a }
        return a + d * (Geometry.dot(p - a, d) / l2)
    }

    /// The angle between two lines where they meet: the rays toward each line's far end.
    static func angle(_ a: SketchReference, _ b: SketchReference) -> (value: Double, signed: Double, pivot: Point2, rayA: Point2, rayB: Point2)? {
        guard case .line(let p0, let p1) = a.kind, case .line(let q0, let q1) = b.kind else { return nil }
        let u = p1 - p0, v = q1 - q0, denominator = Geometry.cross(u, v)
        guard abs(denominator) > 1e-12 else { return nil }
        let t = Geometry.cross(q0 - p0, v) / denominator
        let pivot = p0 + u * t
        let ra = (p0.distance(to: pivot) > p1.distance(to: pivot) ? p0 : p1), rb = (q0.distance(to: pivot) > q1.distance(to: pivot) ? q0 : q1)
        let da = ra - pivot, db = rb - pivot
        guard da.length > 1e-9, db.length > 1e-9 else { return nil }
        let signed = atan2(Geometry.cross(da, db), Geometry.dot(da, db))
        return (abs(signed) * 180 / .pi, signed, pivot, ra, rb)
    }

    // MARK: Setting a value

    /// The workspace with `dimension` (one of `dimensions(a, b)`) set to `value`: the second pick
    /// (or the first, when the second cannot move) moves to match. Nil when nothing can move or the
    /// result is invalid.
    static func applying(_ kind: SketchDimension.Kind, value: Double, _ a: SketchReference, _ b: SketchReference?, in workspace: Workspace) -> Workspace? {
        guard value.isFinite, kind.isAngle ? (value >= 0 && value <= 180) : (value >= 0 && value <= 10_000) else { return nil }
        guard let b else { return applyingSingle(kind, value: value, a, in: workspace) }
        // The second pick moves, unless it is fixed (from a solid).
        let (fixed, moving, flipped) = b.shapeID != nil ? (a, b, false) : (b, a, true)
        guard moving.shapeID != nil else { return nil }
        if kind == .angle {
            guard let measured = angle(fixed, moving) else { return nil }
            let target = (measured.signed >= 0 ? 1.0 : -1.0) * value * .pi / 180
            let pivot = joint(fixed, moving, in: workspace) ?? measured.pivot
            return turn(moving, about: pivot, by: target - measured.signed, relativeTo: fixed, in: workspace)
        }
        let current = measured(a, b, in: workspace).first { $0.kind == kind }
        guard let current else { return nil }
        // The measured direction from the fixed side toward the moving side.
        var from = current.from, to = current.to
        if flipped { swap(&from, &to) }
        var delta: Point2
        switch kind {
        case .horizontal:
            let sign: Double = to.x >= from.x ? 1 : -1
            delta = Point2(x: from.x + sign * value - to.x, y: 0)
        case .vertical:
            let sign: Double = to.y >= from.y ? 1 : -1
            delta = Point2(x: 0, y: from.y + sign * value - to.y)
        case .distance:
            let d = to - from
            guard d.length > 1e-9 else { return nil }
            delta = d * (value / d.length - 1)
        default: return nil
        }
        // Moving part of a shape can carry the fixed pick along (both on one shape): then nothing reaches the value.
        guard let result = move(moving, by: delta, relativeTo: fixed, in: workspace),
              let a2 = a.resolved(in: result), let b2 = b.resolved(in: result),
              let reached = measured(a2, b2, in: result).first(where: { $0.kind == kind }),
              abs(reached.value - value) <= 1e-6 * max(1, value) else { return nil }
        return result
    }

    private static func applyingSingle(_ kind: SketchDimension.Kind, value: Double, _ a: SketchReference, in workspace: Workspace) -> Workspace? {
        guard let id = a.shapeID, let shape = workspace.shapes.first(where: { $0.id == id }), shape.kind == .line, a.part == .whole else { return nil }
        switch kind {
        case .length:
            guard let updated = SketchEditing.dimension(.length, value: value, of: shape) else { return nil }
            return SketchEditing.replacing(updated, in: workspace)
        case .angle:
            // Turn about the end joined to something (else the start), staying near the drawn direction.
            let joined = { (p: Point2) in workspace.shapes.contains { $0.id != id && $0.sketch == shape.sketch && SketchEditing.joints(of: $0).contains { $0.distance(to: p) < 1e-5 } } }
            let pivot = joined(shape.end) && !joined(shape.start) ? shape.end : shape.start
            let current = atan2(shape.end.y - shape.start.y, shape.end.x - shape.start.x)
            let options = [value, value - 180, value + 180, value - 360].map { $0 * .pi / 180 }
            let target = options.min { abs(remainder($0 - current, 2 * .pi)) < abs(remainder($1 - current, 2 * .pi)) }!
            var turned = shape
            turned.start = rotate(shape.start, about: pivot, by: target - current)
            turned.end = rotate(shape.end, about: pivot, by: target - current)
            return SketchEditing.replacing(turned, in: workspace)
        default: return nil
        }
    }

    static func rotate(_ p: Point2, about c: Point2, by angle: Double) -> Point2 {
        let d = p - c
        return c + Point2(x: d.x * cos(angle) - d.y * sin(angle), y: d.x * sin(angle) + d.y * cos(angle))
    }

    /// The shapes joined to `shapeID` (itself included) through shared ends and corners, in its sketch.
    static func component(of shapeID: UUID, in workspace: Workspace) -> Set<UUID> {
        guard let shape = workspace.shapes.first(where: { $0.id == shapeID }) else { return [] }
        let shapes = workspace.shapes.filter { $0.sketch == shape.sketch && $0.plane == shape.plane }
        var result: Set<UUID> = [shapeID], frontier = [shape]
        while let current = frontier.popLast() {
            let joints = SketchEditing.joints(of: current)
            for other in shapes where !result.contains(other.id) {
                if SketchEditing.joints(of: other).contains(where: { p in joints.contains { $0.distance(to: p) < 1e-5 } }) {
                    result.insert(other.id); frontier.append(other)
                }
            }
        }
        return result
    }

    private static func joined(_ a: SketchReference, _ b: SketchReference, in workspace: Workspace) -> Bool {
        guard let first = a.shapeID, let second = b.shapeID else { return false }
        return component(of: second, in: workspace).contains(first)
    }

    /// A point both lines pass through (a shared end), if they are joined there.
    private static func joint(_ a: SketchReference, _ b: SketchReference, in workspace: Workspace) -> Point2? {
        guard joined(a, b, in: workspace), case .line(let p0, let p1) = a.kind, case .line(let q0, let q1) = b.kind else { return nil }
        for p in [p0, p1] { for q in [q0, q1] where p.distance(to: q) < 1e-5 { return p } }
        return nil
    }

    /// Moves the second pick by `delta`: in place when it is joined to the first, else with its whole outline.
    private static func move(_ moving: SketchReference, by delta: Point2, relativeTo fixed: SketchReference, in workspace: Workspace) -> Workspace? {
        guard let id = moving.shapeID, let shape = workspace.shapes.first(where: { $0.id == id }) else { return nil }
        if joined(fixed, moving, in: workspace) {
            let edited: SketchShape?
            switch (shape.kind, moving.part) {
            case (_, .whole), (.circle, .center), (.arc, .center), (.slot, .side):
                edited = translated(shape, by: delta)
            case (.rectangle, .center):
                if fixed.shapeID == id, case .corner(let i) = fixed.part {
                    // From one of its own corners: the opposite corner moves twice as far, so the corner stays.
                    let opposite = ((i + 2) % 4 + 4) % 4
                    edited = SketchEditing.dragging(shape, handle: .corner(opposite), to: shape.outline[opposite] + delta * 2)
                } else {
                    edited = SketchEditing.dragging(shape, handle: .center, to: shape.center + delta)
                }
            case (.rectangle, .corner(let i)):
                edited = SketchEditing.dragging(shape, handle: .corner(i), to: shape.outline[((i % 4) + 4) % 4] + delta)
            case (.rectangle, .side(let i)):
                edited = SketchEditing.dragging(shape, handle: .side(i), to: SketchEditing.handlePoint(.side(i), on: shape) + delta)
            case (_, .start): edited = SketchEditing.dragging(shape, handle: .start, to: shape.start + delta)
            case (_, .end): edited = SketchEditing.dragging(shape, handle: .end, to: shape.end + delta)
            default: edited = nil
            }
            guard let edited else { return nil }
            return SketchEditing.replacing(edited, in: workspace)
        }
        var result = workspace
        let moved = component(of: id, in: workspace)
        for index in result.shapes.indices where moved.contains(result.shapes[index].id) {
            result.shapes[index] = translated(result.shapes[index], by: delta)
        }
        return result.isValid ? result : nil
    }

    /// Turns the second pick (a line) about `pivot`: alone when joined to the first (joined lines
    /// follow), else with its whole outline (rectangles in it become lines, since they cannot turn).
    private static func turn(_ moving: SketchReference, about pivot: Point2, by angle: Double, relativeTo fixed: SketchReference,
                             in workspace: Workspace) -> Workspace? {
        guard let id = moving.shapeID, let shape = workspace.shapes.first(where: { $0.id == id }) else { return nil }
        if joined(fixed, moving, in: workspace) {
            guard shape.kind == .line, moving.part == .whole else { return nil }
            var turned = shape
            turned.start = rotate(shape.start, about: pivot, by: angle)
            turned.end = rotate(shape.end, about: pivot, by: angle)
            return SketchEditing.replacing(turned, in: workspace)
        }
        var result = workspace
        let moved = component(of: id, in: workspace)
        var shapes: [SketchShape] = []
        for shape in result.shapes {
            guard moved.contains(shape.id) else { shapes.append(shape); continue }
            shapes += (shape.kind == .rectangle ? shape.exploded : [shape]).map { turned($0, about: pivot, by: angle) }
        }
        result.shapes = shapes
        return result.isValid ? result : nil
    }

    static func translated(_ shape: SketchShape, by delta: Point2) -> SketchShape {
        var result = shape
        result.start = shape.start + delta
        result.end = shape.end + delta
        result.arcCenter = shape.arcCenter.map { $0 + delta }
        result.points = shape.points?.map { $0 + delta }
        return result
    }

    static func turned(_ shape: SketchShape, about pivot: Point2, by angle: Double) -> SketchShape {
        var result = shape
        result.start = rotate(shape.start, about: pivot, by: angle)
        result.end = rotate(shape.end, about: pivot, by: angle)
        result.arcCenter = shape.arcCenter.map { rotate($0, about: pivot, by: angle) }
        result.points = shape.points?.map { rotate($0, about: pivot, by: angle) }
        return result
    }
}
