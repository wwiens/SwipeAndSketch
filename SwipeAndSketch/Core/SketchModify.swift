import Foundation

// Sketch modifications: Trim removes the stretch of a shape between the places
// other shapes meet it, and Fillet rounds the corner where two lines meet. Rectangles and slots
// become their lines and arcs when one of their sides is trimmed or a corner rounded.

extension SketchShape {
    /// A rectangle as four lines and a slot as two lines and two arcs (the first keeps this shape's
    /// id); other shapes as they are.
    var exploded: [SketchShape] {
        func piece(_ index: Int, _ shape: SketchShape) -> SketchShape {
            var shape = shape
            shape.id = index == 0 ? id : UUID()
            shape.sketch = sketch
            return shape
        }
        switch kind {
        case .rectangle:
            let p = outline
            return (0..<4).map { piece($0, SketchShape(kind: .line, plane: plane, start: p[$0], end: p[($0 + 1) % 4])) }
        case .slot:
            let d = end - start, length = d.length, radius = (width ?? 0) / 2
            guard length > 1e-12 else { return [self] }
            let left = Point2(x: -d.y / length, y: d.x / length)
            return [
                piece(0, SketchShape.arc(center: end, from: end - left * radius, to: end + left * radius, plane: plane)),
                piece(1, SketchShape(kind: .line, plane: plane, start: end + left * radius, end: start + left * radius)),
                piece(2, SketchShape.arc(center: start, from: start + left * radius, to: start - left * radius, plane: plane)),
                piece(3, SketchShape(kind: .line, plane: plane, start: start - left * radius, end: end - left * radius)),
            ]
        default: return [self]
        }
    }

    /// The shape as one curve for trimming: a circle or closed curve runs once around from its start.
    fileprivate var trimCurve: (curve: SketchCurve, periodic: Bool)? {
        switch kind {
        case .line: return (SketchCurve(kind: .polyline([start, end])), false)
        case .arc:
            guard let c = arcCenter else { return nil }
            return (SketchCurve(kind: .arc(center: c, radius: start.distance(to: c), from: atan2(start.y - c.y, start.x - c.x), sweep: arcSweep)), false)
        case .circle:
            return (SketchCurve(kind: .arc(center: start, radius: start.distance(to: end), from: atan2(end.y - start.y, end.x - start.x), sweep: 2 * .pi)), true)
        case .curve:
            guard let points = isSpline ? outline : points, points.count >= 2 else { return nil }
            return (SketchCurve(kind: .polyline(isClosed ? points + [points[0]] : points)), isClosed)
        case .ellipse:
            // Trimmed, an ellipse becomes stretches of its outline.
            let points = outline
            return (SketchCurve(kind: .polyline(points + [points[0]])), true)
        case .rectangle, .slot, .point: return nil
        }
    }
}

extension SketchCurve {
    /// The parameter of the point on the curve nearest `p`.
    func parameter(nearest p: Point2) -> Double {
        switch kind {
        case .polyline(let points):
            var best = (t: 0.0, distance: Double.infinity)
            for i in 0..<(points.count - 1) {
                let a = points[i], d = points[i + 1] - a, l2 = Geometry.dot(d, d)
                let f = l2 > 0 ? max(0, min(1, Geometry.dot(p - a, d) / l2)) : 0
                let distance = p.distance(to: a + d * f)
                if distance < best.distance { best = (Double(i) + f, distance) }
            }
            return best.t
        case .arc(let center, _, let from, let sweep):
            var t = atan2(p.y - center.y, p.x - center.x) - from
            while t < 0 { t += 2 * .pi }
            while t >= 2 * .pi { t -= 2 * .pi }
            // Past the end: whichever end is nearer.
            if t > sweep { t = (t - sweep) < (2 * .pi - t) ? sweep : 0 }
            return t
        }
    }

    /// A shape tracing the curve from `t0` to `t1` (t0 < t1), on `plane`.
    func shape(_ t0: Double, _ t1: Double, plane: SketchPlane) -> SketchShape? {
        let shape: SketchShape
        switch kind {
        case .polyline(let points):
            let stretch = self.points(t0, t1)
            if points.count == 2 || stretch.count == 2 {
                shape = SketchShape(kind: .line, plane: plane, start: stretch[0], end: stretch[stretch.count - 1])
            } else {
                shape = SketchShape.curve(stretch, closed: false, plane: plane)
            }
        case .arc(let center, _, _, _):
            shape = SketchShape.arc(center: center, from: point(t0), to: point(t1), plane: plane)
        }
        return shape.isValid ? shape : nil
    }
}

enum SketchModify {
    /// The workspace with the stretch of shape `shapeID` nearest `point` removed: the part between
    /// the nearest places where other shapes of its sketch meet it. A shape that
    /// nothing meets is removed whole. Nil when there is no such shape.
    static func trim(_ shapeID: UUID, at point: Point2, in workspace: Workspace) -> Workspace? {
        guard let index = workspace.shapes.firstIndex(where: { $0.id == shapeID }) else { return nil }
        var result = workspace
        var shape = workspace.shapes[index]
        if shape.kind == .rectangle || shape.kind == .slot {
            // Trim one side: the outline becomes its pieces, and the piece under the Pencil is trimmed.
            let pieces = shape.exploded
            result.shapes.replaceSubrange(index...index, with: pieces)
            guard let nearest = pieces.min(by: { distance(point, to: $0) < distance(point, to: $1) }) else { return nil }
            shape = nearest
        }
        guard let shapeIndex = result.shapes.firstIndex(where: { $0.id == shape.id }), let (curve, periodic) = shape.trimCurve else { return nil }
        let others = result.shapes.filter { $0.id != shape.id && $0.sketch == shape.sketch && $0.plane == shape.plane }
        let span = curve.span
        var cuts: [Double] = []
        for other in others { for piece in other.regionCurves { cuts += curve.meetings(with: piece).map(\.0) } }
        // Ends are not places to cut (except where a closed shape's start is met).
        cuts = cuts.filter { periodic || ($0 > 1e-9 && $0 < span - 1e-9) }.map { periodic ? $0.truncatingRemainder(dividingBy: span) : $0 }.sorted()
        var distinct: [Double] = []
        for t in cuts where distinct.last.map({ curve.point(t).distance(to: curve.point($0)) > 1e-6 }) ?? true { distinct.append(t) }
        if periodic, distinct.count > 1, let first = distinct.first, let last = distinct.last,
           curve.point(first).distance(to: curve.point(last)) <= 1e-6 { distinct.removeLast() }
        let tapped = curve.parameter(nearest: point)
        var kept: [SketchShape] = []
        if periodic {
            // A closed shape keeps everything but the stretch between the cuts on either side of the tap.
            if distinct.count >= 2 {
                let after = distinct.first { $0 > tapped } ?? distinct[0] + span
                let before = distinct.last { $0 <= tapped } ?? distinct[distinct.count - 1] - span
                var from = after, to = before + span
                if from >= span { from -= span; to -= span }
                if let piece = curve.periodicShape(from, to, span: span, plane: shape.plane) { kept.append(piece) }
            }
        } else {
            let before = distinct.last { $0 < tapped } ?? 0, after = distinct.first { $0 > tapped } ?? span
            if before > 1e-9, let piece = curve.shape(0, before, plane: shape.plane) { kept.append(piece) }
            if after < span - 1e-9, let piece = curve.shape(after, span, plane: shape.plane) { kept.append(piece) }
        }
        for (i, _) in kept.enumerated() {
            kept[i].id = i == 0 ? shape.id : UUID()
            kept[i].sketch = shape.sketch
        }
        result.shapes.replaceSubrange(shapeIndex...shapeIndex, with: kept)
        return result.isValid ? result : nil
    }

    /// How far a point is from a shape's outline.
    static func distance(_ point: Point2, to shape: SketchShape) -> Double {
        let outline = shape.outline, count = shape.isClosed ? outline.count : outline.count - 1
        guard count > 0 else { return outline.first.map { point.distance(to: $0) } ?? .infinity }
        return (0..<count).reduce(.infinity) { min($0, Geometry.distance(point, toSegment: outline[$1], outline[($1 + 1) % outline.count])) }
    }

    /// The workspace with the corner at `vertex` of sketch `sketch` rounded to `radius`: the two lines
    /// meeting there (a rectangle's sides count) stop short and a tangent arc joins them (sketch
    /// Fillet). Returns the new arc's id; nil when two lines do not meet there or the radius
    /// does not fit them.
    static func roundCorner(at vertex: Point2, radius: Double, sketch: UUID, in workspace: Workspace) -> (workspace: Workspace, arc: UUID)? {
        guard radius.isFinite, radius >= 0.01 else { return nil }
        var result = workspace
        // A rectangle with a corner there becomes four lines.
        if let index = result.shapes.firstIndex(where: { $0.sketch == sketch && $0.kind == .rectangle && $0.outline.contains { $0.distance(to: vertex) < 1e-5 } }) {
            result.shapes.replaceSubrange(index...index, with: result.shapes[index].exploded)
        }
        let lines = result.shapes.indices.filter { i in
            let shape = result.shapes[i]
            return shape.sketch == sketch && shape.kind == .line && (shape.start.distance(to: vertex) < 1e-5 || shape.end.distance(to: vertex) < 1e-5)
        }
        guard lines.count == 2 else { return nil }
        func far(_ shape: SketchShape) -> Point2 { shape.start.distance(to: vertex) < 1e-5 ? shape.end : shape.start }
        let first = result.shapes[lines[0]], second = result.shapes[lines[1]]
        let a = far(first) - vertex, b = far(second) - vertex
        let la = a.length, lb = b.length
        guard la > 1e-9, lb > 1e-9 else { return nil }
        let u = a * (1 / la), w = b * (1 / lb)
        let angle = acos(max(-1, min(1, Geometry.dot(u, w))))
        // Straight through (nothing to round) or folded back on itself.
        guard angle > 1e-3, angle < .pi - 1e-3 else { return nil }
        let setback = radius / tan(angle / 2)
        guard setback < la - 0.005, setback < lb - 0.005 else { return nil }
        let ta = vertex + u * setback, tb = vertex + w * setback
        let bisector = (u + w) * (1 / (u + w).length)
        let center = vertex + bisector * (radius / sin(angle / 2))
        // The short way round, counterclockwise.
        let arc = Geometry.cross(ta - center, tb - center) > 0 ? SketchShape.arc(center: center, from: ta, to: tb, plane: first.plane)
                                                             : SketchShape.arc(center: center, from: tb, to: ta, plane: first.plane)
        var rounded = arc
        rounded.sketch = sketch
        for (index, point) in [(lines[0], ta), (lines[1], tb)] {
            if result.shapes[index].start.distance(to: vertex) < 1e-5 { result.shapes[index].start = point } else { result.shapes[index].end = point }
        }
        result.shapes.append(rounded)
        return result.isValid && rounded.isValid ? (result, rounded.id) : nil
    }

    /// Where lines (and rectangle corners) of a sketch meet two at a time: the corners Fillet can round.
    static func corners(in shapes: [SketchShape]) -> [Point2] {
        var ends: [Point2] = []
        for shape in shapes {
            switch shape.kind {
            case .line: ends += [shape.start, shape.end]
            case .rectangle: ends += shape.outline + shape.outline
            default: break
            }
        }
        var result: [Point2] = []
        for point in ends where !result.contains(where: { $0.distance(to: point) < 1e-5 }) {
            if ends.filter({ $0.distance(to: point) < 1e-5 }).count == 2 { result.append(point) }
        }
        return result
    }
}

extension SketchCurve {
    /// A shape along a closed curve from `t0` to `t1` (t0 < t1 < t0 + span), wrapping past its start.
    fileprivate func periodicShape(_ t0: Double, _ t1: Double, span: Double, plane: SketchPlane) -> SketchShape? {
        switch kind {
        case .arc(let center, _, _, _):
            return SketchShape.arc(center: center, from: point(t0.truncatingRemainder(dividingBy: span)),
                                   to: point(t1.truncatingRemainder(dividingBy: span)), plane: plane)
        case .polyline:
            var points: [Point2]
            if t1 <= span { points = self.points(t0, t1) }
            else { points = self.points(t0, span) + self.points(0, t1 - span).dropFirst() }
            let shape = points.count == 2 ? SketchShape(kind: .line, plane: plane, start: points[0], end: points[1])
                                          : SketchShape.curve(points, closed: false, plane: plane)
            return shape.isValid ? shape : nil
        }
    }
}
