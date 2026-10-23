import Foundation

// More sketch tools: Polygon, Extend, Mirror inside a
// sketch, Offset, and moving or turning shapes within their sketch. Each works on sketch
// coordinates and returns new shapes or a new workspace; the session commits them as one step.

enum SketchTools {
    static let polygonSides = 3...64

    /// A regular polygon centered on `center` with a corner at `vertex`, as joined lines.
    static func polygon(center: Point2, vertex: Point2, sides: Int, plane: SketchPlane) -> [SketchShape] {
        let radius = center.distance(to: vertex)
        guard polygonSides.contains(sides), radius >= 0.01 else { return [] }
        let start = atan2(vertex.y - center.y, vertex.x - center.x)
        let corners = (0..<sides).map { i -> Point2 in
            let angle = start + 2 * .pi * Double(i) / Double(sides)
            return (center + Point2(x: cos(angle), y: sin(angle)) * radius).roundedOff()
        }
        return corners.indices.map { SketchShape(kind: .line, plane: plane, start: corners[$0], end: corners[($0 + 1) % sides]) }
    }

    // MARK: Extend

    /// The line's end nearer `point` carried on, straight, to the first shape of its sketch it meets.
    static func extend(_ shapeID: UUID, near point: Point2, in workspace: Workspace) -> Workspace? {
        guard let index = workspace.shapes.firstIndex(where: { $0.id == shapeID }), workspace.shapes[index].kind == .line else { return nil }
        let line = workspace.shapes[index]
        let movesEnd = point.distance(to: line.end) <= point.distance(to: line.start)
        let from = movesEnd ? line.end : line.start, other = movesEnd ? line.start : line.end
        let direction = from - other, length = direction.length
        guard length > 1e-9 else { return nil }
        let unit = direction * (1 / length)
        // A long ray ahead of the end (past anything in the sketch), and where it first meets another shape.
        let others = workspace.shapes.filter { $0.sketch == line.sketch && $0.id != line.id && $0.kind != .point }
        let reach = others.flatMap(\.outline).reduce(1_000.0) { max($0, $1.distance(to: from) * 2 + 10) }
        let ray = SketchCurve(kind: .polyline([from, from + unit * reach]))
        var nearest: Double?
        for shape in others {
            for curve in shape.regionCurves {
                for (t, _) in ray.meetings(with: curve) where t * reach > 1e-6 { nearest = min(nearest ?? .infinity, t * reach) }
            }
        }
        guard let distance = nearest else { return nil }
        var result = workspace
        if movesEnd { result.shapes[index].end = from + unit * distance } else { result.shapes[index].start = from + unit * distance }
        return result.shapes[index].isValid && result.isValid ? result : nil
    }

    // MARK: Mirror inside a sketch

    /// A point reflected across the line through `a` and `b`.
    static func reflect(_ p: Point2, across a: Point2, _ b: Point2) -> Point2 {
        let d = b - a, l2 = Geometry.dot(d, d)
        guard l2 > 1e-18 else { return p }
        let foot = a + d * (Geometry.dot(p - a, d) / l2)
        return foot * 2 - p
    }

    /// The shape reflected across the line through `a` and `b` in its own sketch. A rectangle across
    /// a slanted line becomes four lines.
    static func reflected(_ shape: SketchShape, across a: Point2, _ b: Point2) -> [SketchShape] {
        func r(_ p: Point2) -> Point2 { reflect(p, across: a, b).roundedOff() }
        var result = shape
        result.id = UUID()
        switch shape.kind {
        case .rectangle:
            let d = b - a
            guard abs(d.x) < 1e-12 || abs(d.y) < 1e-12 else {
                return shape.exploded.flatMap { reflected($0, across: a, b) }
            }
            result.start = r(shape.start); result.end = r(shape.end)
        case .arc:
            // A reflection reverses the way round, so the ends trade places.
            result.start = r(shape.end); result.end = r(shape.start)
            result.arcCenter = shape.arcCenter.map(r)
        default:
            result.start = r(shape.start); result.end = r(shape.end)
            result.arcCenter = shape.arcCenter.map(r)
            result.points = shape.points.map { $0.map(r) }
        }
        return result.isValid ? [result] : []
    }

    /// Mirror copies of `shapes` across the line `lineID`, added to their sketch.
    static func mirror(_ shapes: [UUID], across lineID: UUID, in workspace: Workspace) -> (workspace: Workspace, added: [UUID])? {
        guard let line = workspace.shapes.first(where: { $0.id == lineID }), line.kind == .line else { return nil }
        let sources = workspace.shapes.filter { shapes.contains($0.id) && $0.id != lineID && $0.plane == line.plane }
        guard !sources.isEmpty else { return nil }
        var result = workspace
        var added: [UUID] = []
        for source in sources {
            for image in reflected(source, across: line.start, line.end) {
                var copy = image
                copy.sketch = source.sketch
                result.shapes.append(copy)
                added.append(copy.id)
            }
        }
        return result.isValid ? (result, added) : nil
    }

    // MARK: Moving and turning shapes

    /// The shape moved by `offset` and turned `degrees` counterclockwise about `pivot`, in its sketch.
    static func transformed(_ shape: SketchShape, by offset: Point2, turning degrees: Double = 0, about pivot: Point2 = .zero) -> SketchShape? {
        let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
        func move(_ p: Point2) -> Point2 {
            let d = p - pivot
            return (pivot + Point2(x: d.x * c - d.y * s, y: d.x * s + d.y * c) + offset).roundedOff()
        }
        var result = shape
        let quarter = abs(sin(2 * angle)) < 1e-9
        if shape.kind == .rectangle && !quarter {
            // A rectangle stays square to its sketch; turned at any other angle it becomes its lines.
            return nil
        }
        result.start = move(shape.start); result.end = move(shape.end)
        result.arcCenter = shape.arcCenter.map(move)
        result.points = shape.points.map { $0.map(move) }
        return result.isValid ? result : nil
    }

    // MARK: Offset

    /// The chain an Offset starts from: a closed shape on its own, or the lines and arcs joined end
    /// to end with `shapeID` (around a loop, or from one free end to the other).
    static func chain(from shapeID: UUID, in workspace: Workspace) -> [SketchShape] {
        guard let shape = workspace.shapes.first(where: { $0.id == shapeID }) else { return [] }
        guard shape.kind == .line || shape.kind == .arc || (shape.kind == .curve && !shape.isClosed) else { return [shape] }
        let candidates = workspace.shapes.filter { $0.sketch == shape.sketch && ($0.kind == .line || $0.kind == .arc) && !$0.isConstruction }
        // Walk on from the tail, then back from the head, while exactly one piece continues there.
        var chain = [shape], head = shape.start, tail = shape.end
        func next(at point: Point2) -> SketchShape? {
            let touching = candidates.filter { c in !chain.contains { $0.id == c.id } && (c.start.distance(to: point) < 1e-5 || c.end.distance(to: point) < 1e-5) }
            return touching.count == 1 ? touching[0] : nil
        }
        func far(_ piece: SketchShape, from point: Point2) -> Point2 { piece.start.distance(to: point) < 1e-5 ? piece.end : piece.start }
        while tail.distance(to: head) >= 1e-5, let piece = next(at: tail) {
            chain.append(piece)
            tail = far(piece, from: tail)
        }
        while tail.distance(to: head) >= 1e-5, let piece = next(at: head) {
            chain.insert(piece, at: 0)
            head = far(piece, from: head)
        }
        return chain
    }

    /// The chain as kernel edges: points in order with an arc's middle where the edge is an arc,
    /// whether it closes, and whether it is one smooth sampled curve (an ellipse or projected curve).
    private static func outlineLoop(_ chain: [SketchShape]) -> (loop: SolidKernel.OutlineLoop, sampled: Bool)? {
        if chain.count == 1 {
            let shape = chain[0]
            switch shape.kind {
            case .circle:
                return (.init(points: [shape.end], mids: [shape.start], closed: true), false)
            case .rectangle:
                return (.init(points: shape.outline, mids: [nil, nil, nil, nil], closed: true), false)
            case .slot:
                let slot = shape.slotOutline, n = slot.points.count
                var points: [Point2] = [], mids: [Point2?] = []
                var index = 0
                while index < n {
                    points.append(slot.points[index])
                    if let arc = slot.arcs.first(where: { $0.start == index }) {
                        mids.append(slot.points[(index + arc.segments / 2) % n])
                        index += arc.segments
                    } else {
                        mids.append(nil)
                        index += 1
                    }
                }
                return (.init(points: points, mids: mids, closed: true), false)
            case .ellipse:
                let outline = shape.outline
                return (.init(points: outline, mids: outline.map { _ in nil }, closed: true), true)
            case .curve:
                let outline = shape.outline
                return (.init(points: outline, mids: outline.map { _ in nil }, closed: shape.isClosed), true)
            case .line, .arc: break
            case .point: return nil
            }
        }
        // Lines and arcs in order, each oriented to follow on from the last.
        var points: [Point2] = [], mids: [Point2?] = []
        var cursor: Point2?
        for (index, shape) in chain.enumerated() {
            var a = shape.start, b = shape.end
            if let cursor { if b.distance(to: cursor) < 1e-5 { swap(&a, &b) } }
            else if chain.count > 1 {
                let next = chain[index + 1]
                if [next.start, next.end].contains(where: { $0.distance(to: a) < 1e-5 }) { swap(&a, &b) }
            }
            points.append(a)
            mids.append(shape.kind == .arc ? shape.arcMiddle : nil)
            cursor = b
        }
        guard let last = cursor else { return nil }
        let closed = chain.count > 2 && last.distance(to: points[0]) < 1e-5
        if !closed { points.append(last); mids.append(nil) }
        return (.init(points: points, mids: mids, closed: closed), false)
    }

    /// Shapes `distance` from the chain through `shapeID` (outward or to the left for positive
    /// distances; both ways with `bothSides`), on its plane, not yet in any sketch.
    static func offset(_ shapeID: UUID, by distance: Double, bothSides: Bool, rounded: Bool, in workspace: Workspace) -> [SketchShape]? {
        let chain = chain(from: shapeID, in: workspace)
        guard let plane = chain.first?.plane, let (loop, sampled) = outlineLoop(chain), distance.isFinite, abs(distance) >= 0.001 else { return nil }
        var shapes: [SketchShape] = []
        for amount in bothSides ? [abs(distance), -abs(distance)] : [distance] {
            guard let loops = try? SolidKernel.offset(loop, on: plane, by: amount, rounded: rounded) else { return nil }
            for result in loops { shapes += self.shapes(result, plane: plane, sampled: sampled) }
        }
        return shapes.isEmpty || !shapes.allSatisfy(\.isValid) ? nil : shapes
    }

    /// A kernel loop as sketch shapes: a circle, one smooth curve, or lines and arcs.
    private static func shapes(_ loop: SolidKernel.OutlineLoop, plane: SketchPlane, sampled: Bool) -> [SketchShape] {
        let points = loop.points.map { $0.roundedOff() }
        if loop.closed, points.count == 1, let center = loop.mids[0] {
            return [SketchShape(kind: .circle, plane: plane, start: center.roundedOff(), end: points[0])]
        }
        if sampled, loop.mids.allSatisfy({ $0 == nil }) {
            return [SketchShape.curve(points, closed: loop.closed, plane: plane)]
        }
        let count = loop.closed ? points.count : points.count - 1
        return (0..<count).compactMap { i -> SketchShape? in
            let a = points[i], b = points[(i + 1) % points.count]
            guard a.distance(to: b) >= 1e-6 else { return nil }
            if let mid = loop.mids[i] { return SketchShape.arc(from: a, through: mid, to: b, plane: plane) }
            return SketchShape(kind: .line, plane: plane, start: a, end: b)
        }
    }
}
