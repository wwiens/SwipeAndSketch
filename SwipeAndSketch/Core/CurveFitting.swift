import Foundation
import CoreGraphics

// Curves made into sketch geometry. Sketches hold lines, arcs, and circles exactly, and regions
// and solids keep arcs exact, so a drawing's curves become lines and tangent-continuous pairs of
// circular arcs (biarcs) that stay within a tolerance of them. Neighbors that turn out to be one
// line or one arc are joined, and a loop of arcs about one center becomes a circle, so circles
// and rounded corners come back as themselves. Used by SVG import (SVGImport.swift).

enum CurveFitting {
    /// A piece of a fitted outline: a line, or an arc about `center` (counterclockwise when `ccw`).
    struct Piece: Equatable {
        var start: Point2
        var end: Point2
        var center: Point2?
        var ccw = true
        /// Points of the original curve this piece stands for, which any joined piece must still pass.
        var samples: [Point2] = []
        var isLine: Bool { center == nil }
        var radius: Double { center.map { start.distance(to: $0) } ?? 0 }

        /// Counterclockwise from start to end when `ccw`, otherwise clockwise; radians in (0, 2π].
        var sweep: Double {
            guard let c = center else { return 0 }
            let a0 = atan2(start.y - c.y, start.x - c.x), a1 = atan2(end.y - c.y, end.x - c.x)
            var sweep = ccw ? a1 - a0 : a0 - a1
            while sweep <= 0 { sweep += 2 * .pi }
            while sweep > 2 * .pi { sweep -= 2 * .pi }
            return sweep
        }

        var length: Double { isLine ? start.distance(to: end) : radius * sweep }

        func distance(to p: Point2) -> Double {
            guard let c = center else { return Geometry.distance(p, toSegment: start, end) }
            let a0 = atan2(start.y - c.y, start.x - c.x), ap = atan2(p.y - c.y, p.x - c.x)
            var along = ccw ? ap - a0 : a0 - ap
            while along < 0 { along += 2 * .pi }
            while along >= 2 * .pi { along -= 2 * .pi }
            if along <= sweep { return abs(p.distance(to: c) - radius) }
            return min(p.distance(to: start), p.distance(to: end))
        }

        /// The point halfway along it.
        var middle: Point2 {
            guard let c = center else { return (start + end) * 0.5 }
            let a0 = atan2(start.y - c.y, start.x - c.x), half = sweep / 2 * (ccw ? 1 : -1)
            return c + Point2(x: cos(a0 + half), y: sin(a0 + half)) * radius
        }

        func reversed() -> Piece {
            Piece(start: end, end: start, center: center, ccw: !ccw, samples: samples.reversed())
        }
    }

    /// A chain of pieces, each starting exactly where the one before ends.
    struct Loop {
        var pieces: [Piece]
        var closed: Bool
        /// A closed loop that is one whole circle.
        var circle: (center: Point2, radius: Double)?
    }

    /// The shortest line and smallest arc radius a sketch keeps (see `SketchShape.isValid`).
    static let shortest = 0.012

    // MARK: Paths into segments

    enum Segment {
        case line(Point2, Point2)
        case cubic(Point2, Point2, Point2, Point2)
        var start: Point2 {
            switch self { case .line(let a, _), .cubic(let a, _, _, _): a }
        }
        var end: Point2 {
            switch self { case .line(_, let b), .cubic(_, _, _, let b): b }
        }
        func reversed() -> Segment {
            switch self {
            case .line(let a, let b): .line(b, a)
            case .cubic(let a, let c1, let c2, let b): .cubic(b, c2, c1, a)
            }
        }
        func withStart(_ p: Point2) -> Segment {
            switch self { case .line(_, let b): .line(p, b); case .cubic(_, let c1, let c2, let b): .cubic(p, c1, c2, b) }
        }
        func withEnd(_ p: Point2) -> Segment {
            switch self { case .line(let a, _): .line(a, p); case .cubic(let a, let c1, let c2, _): .cubic(a, c1, c2, p) }
        }
        /// Its control polygon's length, which is at least the curve's.
        var hull: Double {
            switch self {
            case .line(let a, let b): a.distance(to: b)
            case .cubic(let a, let c1, let c2, let b): a.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: b)
            }
        }
    }

    struct Subpath {
        var segments: [Segment]
        var closed: Bool
        var start: Point2 { segments.first?.start ?? .zero }
        var end: Point2 { segments.last?.end ?? .zero }
        func reversed() -> Subpath { Subpath(segments: segments.reversed().map { $0.reversed() }, closed: closed) }
    }

    /// A path's pieces as subpaths of lines and cubic curves (quadratic curves raised to cubic).
    static func subpaths(of path: CGPath) -> [Subpath] {
        var result: [Subpath] = []
        var current: [Segment] = []
        var start = Point2.zero, last = Point2.zero
        func p(_ point: CGPoint) -> Point2 { Point2(x: Double(point.x), y: Double(point.y)) }
        func finish(closed: Bool) {
            if closed, last.distance(to: start) > 0 { current.append(.line(last, start)) }
            if !current.isEmpty { result.append(Subpath(segments: current, closed: closed)) }
            current = []
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                finish(closed: false)
                start = p(element.points[0]); last = start
            case .addLineToPoint:
                let b = p(element.points[0])
                current.append(.line(last, b)); last = b
            case .addQuadCurveToPoint:
                let c = p(element.points[0]), b = p(element.points[1])
                current.append(.cubic(last, last + (c - last) * (2.0 / 3), b + (c - b) * (2.0 / 3), b)); last = b
            case .addCurveToPoint:
                let b = p(element.points[2])
                current.append(.cubic(last, p(element.points[0]), p(element.points[1]), b)); last = b
            case .closeSubpath:
                finish(closed: true)
                last = start
            @unknown default:
                break
            }
        }
        finish(closed: false)
        return result
    }

    /// Segments shorter than `minimum` are dropped and their neighbors meet in their place; an
    /// open subpath whose ends are within `gap` of each other is closed.
    static func cleaned(_ subpath: Subpath, minimum: Double, gap: Double) -> Subpath? {
        var segments: [Segment] = []
        for segment in subpath.segments {
            if segment.hull < minimum, let last = segments.last {
                // Too short to keep: the one before reaches its end instead.
                segments[segments.count - 1] = last.withEnd(segment.end)
                continue
            }
            if let last = segments.last { segments.append(segment.withStart(last.end)) } else { segments.append(segment) }
        }
        // A first segment too short to keep is merged into the next.
        if segments.count > 1, segments[0].hull < minimum { segments[1] = segments[1].withStart(segments[0].start); segments.removeFirst() }
        guard !segments.isEmpty else { return nil }
        var closed = subpath.closed
        let first = segments[0].start, end = segments[segments.count - 1].end
        if !closed && first.distance(to: end) <= gap && segments.reduce(0, { $0 + $1.hull }) > 4 * gap { closed = true }
        if closed {
            if first.distance(to: end) <= max(gap, minimum) {
                segments[segments.count - 1] = segments[segments.count - 1].withEnd(first)
            } else {
                segments.append(.line(end, first))
            }
            if segments.count == 1, case .line = segments[0] { return nil }
        }
        return Subpath(segments: segments, closed: closed)
    }

    /// Open subpaths whose ends are within `gap` joined into longer ones (closed when they come
    /// back around), the way separately drawn strokes of one outline are meant.
    static func joined(_ subpaths: [Subpath], gap: Double) -> [Subpath] {
        var closed = subpaths.filter(\.closed)
        var open = subpaths.filter { !$0.closed }
        guard gap > 0, open.count > 1, open.count <= 20_000 else { return closed + open }
        var result: [Subpath] = []
        while var chain = open.popLast() {
            var grew = true
            while grew {
                grew = false
                for index in open.indices.reversed() {
                    let other = open[index]
                    var piece: Subpath?, atEnd = true
                    if other.start.distance(to: chain.end) <= gap { piece = other }
                    else if other.end.distance(to: chain.end) <= gap { piece = other.reversed() }
                    else if other.end.distance(to: chain.start) <= gap { piece = other; atEnd = false }
                    else if other.start.distance(to: chain.start) <= gap { piece = other.reversed(); atEnd = false }
                    guard var piece else { continue }
                    open.remove(at: index)
                    if atEnd {
                        piece.segments[0] = piece.segments[0].withStart(chain.end)
                        chain.segments += piece.segments
                    } else {
                        piece.segments[piece.segments.count - 1] = piece.segments[piece.segments.count - 1].withEnd(chain.start)
                        chain.segments = piece.segments + chain.segments
                    }
                    grew = true
                }
            }
            result.append(chain)
        }
        closed += result
        return closed
    }

    // MARK: Fitting

    /// The loops a path's subpaths fit to, each within `tolerance` (millimeters) of the path.
    /// `gap` closes and joins open subpaths whose ends nearly meet; nil leaves them as they are.
    static func loops(of path: CGPath, tolerance: Double, gap: Double?) -> [Loop] {
        var subpaths = subpaths(of: path).compactMap { cleaned($0, minimum: shortest, gap: gap ?? 0) }
        if let gap { subpaths = joined(subpaths, gap: gap) }
        return subpaths.compactMap { fit($0, tolerance: tolerance) }
    }

    static func fit(_ subpath: Subpath, tolerance: Double) -> Loop? {
        var pieces: [Piece] = []
        for segment in subpath.segments {
            var fitted: [Piece]
            switch segment {
            case .line(let a, let b): fitted = [Piece(start: a, end: b, samples: [a, b])]
            case .cubic(let a, let c1, let c2, let b): fitted = fitCubic(a, c1, c2, b, tolerance: tolerance)
            }
            guard !fitted.isEmpty else { continue }
            // Exactly where the piece before ends.
            if let last = pieces.last { fitted[0] = moved(fitted[0], start: last.end) }
            pieces += fitted
        }
        guard !pieces.isEmpty else { return nil }
        if subpath.closed { pieces[pieces.count - 1] = moved(pieces[pieces.count - 1], end: pieces[0].start) }
        pieces = merged(pieces, closed: subpath.closed, tolerance: tolerance)
        pieces = sanitized(pieces, closed: subpath.closed)
        guard !pieces.isEmpty else { return nil }
        var loop = Loop(pieces: pieces, closed: subpath.closed)
        if subpath.closed {
            loop.circle = circle(pieces, tolerance: tolerance)
            if loop.circle == nil {
                // A closed loop must enclose something.
                guard pieces.count >= 2, abs(Geometry.signedArea(pieces.flatMap { piece in [piece.start, piece.middle] })) > 1e-4 else { return nil }
            }
        }
        return loop
    }

    /// A cubic Bézier as lines and biarcs within `tolerance`.
    static func fitCubic(_ p0: Point2, _ p1: Point2, _ p2: Point2, _ p3: Point2, tolerance: Double, depth: Int = 0) -> [Piece] {
        func at(_ t: Double) -> Point2 {
            let u = 1 - t
            return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
        }
        let chord = p3 - p0
        // Nearly straight: a line.
        if Geometry.distance(p1, toSegment: p0, p3) <= tolerance / 4, Geometry.distance(p2, toSegment: p0, p3) <= tolerance / 4 {
            return p0.distance(to: p3) > 1e-9 ? [Piece(start: p0, end: p3, samples: [p0, at(0.5), p3])] : []
        }
        if depth == 0 {
            // Biarcs cannot turn both ways: split where the curve changes its turn.
            let splits = inflections(p0, p1, p2, p3).filter { $0 > 0.02 && $0 < 0.98 }
            if !splits.isEmpty {
                var result: [Piece] = []
                var rest = (p0, p1, p2, p3), done = 0.0
                for t in splits {
                    let local = (t - done) / (1 - done)
                    let (left, right) = split(rest, at: local)
                    result += fitCubic(left.0, left.1, left.2, left.3, tolerance: tolerance, depth: 1)
                    rest = right
                    done = t
                }
                result += fitCubic(rest.0, rest.1, rest.2, rest.3, tolerance: tolerance, depth: 1)
                return chained(result)
            }
        }
        func unit(_ v: Point2) -> Point2? { v.length > 1e-12 ? v * (1 / v.length) : nil }
        let samples = (0...12).map { at(Double($0) / 12) }
        if depth < 18, let t0 = unit(p1 - p0) ?? unit(p2 - p0) ?? unit(chord), let t1 = unit(p3 - p2) ?? unit(p3 - p1) ?? unit(chord),
           let (first, second) = biarc(p0, t0, p3, t1) {
            let error = samples.map { min(first.distance(to: $0), second.distance(to: $0)) }.max() ?? 0
            if error <= tolerance {
                var a = first, b = second
                a.samples = [p0] + samples.filter { first.distance(to: $0) <= second.distance(to: $0) } + [first.end]
                b.samples = [second.start] + samples.filter { first.distance(to: $0) > second.distance(to: $0) } + [p3]
                return [a, b].filter { $0.start.distance(to: $0.end) > 1e-9 }
            }
        }
        guard depth < 18 else {
            return zip(samples, samples.dropFirst()).map { Piece(start: $0, end: $1, samples: [$0, $1]) }
        }
        let (left, right) = split((p0, p1, p2, p3), at: 0.5)
        return chained(fitCubic(left.0, left.1, left.2, left.3, tolerance: tolerance, depth: depth + 1) +
                       fitCubic(right.0, right.1, right.2, right.3, tolerance: tolerance, depth: depth + 1))
    }

    /// Pieces made to meet exactly end to end.
    private static func chained(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces { result.append(result.last.map { moved(piece, start: $0.end) } ?? piece) }
        return result
    }

    /// The parameters where a cubic Bézier stops turning one way and starts turning the other.
    static func inflections(_ p0: Point2, _ p1: Point2, _ p2: Point2, _ p3: Point2) -> [Double] {
        func cross(_ u: Point2, _ v: Point2) -> Double { u.x * v.y - u.y * v.x }
        // B'(t) = a t² + b t + c, B''(t) = 2a t + b; inflections where B' × B'' = 0:
        // −(a×b) t² + 2(c×a) t + c×b = 0.
        let a = (p1 * 3 - p0 - p2 * 3 + p3) * 3, b = (p0 - p1 * 2 + p2) * 6, c = (p1 - p0) * 3
        let qa = -cross(a, b), qb = 2 * cross(c, a), qc = cross(c, b)
        if abs(qa) < 1e-14 {
            guard abs(qb) > 1e-14 else { return [] }
            return [-qc / qb]
        }
        let discriminant = qb * qb - 4 * qa * qc
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        return [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)].sorted()
    }

    static func split(_ c: (Point2, Point2, Point2, Point2), at t: Double) -> ((Point2, Point2, Point2, Point2), (Point2, Point2, Point2, Point2)) {
        func lerp(_ a: Point2, _ b: Point2) -> Point2 { a + (b - a) * t }
        let ab = lerp(c.0, c.1), bc = lerp(c.1, c.2), cd = lerp(c.2, c.3)
        let abc = lerp(ab, bc), bcd = lerp(bc, cd), mid = lerp(abc, bcd)
        return ((c.0, ab, abc, mid), (mid, bcd, cd, c.3))
    }

    /// The two arcs from `p1` leaving along `t1` to `p2` arriving along `t2`, meeting tangent to
    /// each other (equal tangent lengths); nil when the tangents allow none.
    static func biarc(_ p1: Point2, _ t1: Point2, _ p2: Point2, _ t2: Point2) -> (Piece, Piece)? {
        func dot(_ u: Point2, _ v: Point2) -> Double { u.x * v.x + u.y * v.y }
        let v = p2 - p1, t = t1 + t2
        let vDotT = dot(v, t), t1DotT2 = dot(t1, t2)
        let denominator = 2 * (1 - t1DotT2)
        var d: Double
        if abs(denominator) < 1e-12 {
            let vDotT2 = dot(v, t2)
            guard abs(vDotT2) > 1e-12 else { return nil }
            d = dot(v, v) / (4 * vDotT2)
        } else {
            let discriminant = vDotT * vDotT + denominator * dot(v, v)
            guard discriminant >= 0 else { return nil }
            d = (-vDotT + discriminant.squareRoot()) / denominator
        }
        guard d.isFinite, d > 0 else { return nil }
        let joint = (p1 + p2 + (t1 - t2) * d) * 0.5
        guard let first = arc(from: p1, tangent: t1, to: joint),
              let back = arc(from: p2, tangent: t2 * -1, to: joint) else { return nil }
        return (first, back.reversed())
    }

    /// The arc leaving `p` along `tangent` that reaches `q` (a line when they are in line).
    static func arc(from p: Point2, tangent: Point2, to q: Point2) -> Piece? {
        let chord = q - p, length = chord.length
        guard length > 1e-12 else { return nil }
        let normal = Point2(x: -tangent.y, y: tangent.x)
        let along = normal.x * chord.x + normal.y * chord.y
        if abs(along) < 1e-9 * length { return Piece(start: p, end: q) }
        let radius = (chord.x * chord.x + chord.y * chord.y) / (2 * along)
        // Too flat to tell from a line.
        guard abs(radius) < 50_000 else { return Piece(start: p, end: q) }
        let center = p + normal * radius
        return Piece(start: p, end: q, center: center, ccw: radius > 0)
    }

    /// `piece` starting at `point` instead (it already nearly does); an arc keeps its other end
    /// and its middle.
    static func moved(_ piece: Piece, start point: Point2) -> Piece {
        guard piece.start != point else { return piece }
        var result = piece
        result.start = point
        if piece.center != nil { result.center = Geometry.circumcenter(point, piece.middle, piece.end) }
        return result
    }

    static func moved(_ piece: Piece, end point: Point2) -> Piece {
        guard piece.end != point else { return piece }
        var result = piece
        result.end = point
        if piece.center != nil { result.center = Geometry.circumcenter(piece.start, piece.middle, point) }
        return result
    }

    // MARK: Tidying

    /// Neighbors joined where one line or one arc passes every sample of both.
    static func merged(_ pieces: [Piece], closed: Bool, tolerance: Double) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces {
            if let last = result.last, let joined = join(last, piece, tolerance: tolerance) {
                result[result.count - 1] = joined
            } else {
                result.append(piece)
            }
        }
        if closed, result.count > 2, let joined = join(result[result.count - 1], result[0], tolerance: tolerance) {
            result[0] = joined
            result.removeLast()
        }
        return result
    }

    static func join(_ a: Piece, _ b: Piece, tolerance: Double) -> Piece? {
        let samples = a.samples + b.samples
        if a.isLine && b.isLine {
            let candidate = Piece(start: a.start, end: b.end, samples: samples)
            let da = a.end - a.start, db = b.end - b.start
            guard da.x * db.x + da.y * db.y > 0, candidate.length > 1e-9,
                  samples.allSatisfy({ candidate.distance(to: $0) <= tolerance / 2 }) else { return nil }
            return candidate
        }
        // Circles reach drawings as four cubic curves, which stray from the circle by up to 0.027%
        // of its radius: arcs of the same circle may be that far from each other's.
        let tolerance = max(tolerance, circleSlack * max(a.radius, b.radius))
        // Biarcs bend a little more or less than the curve they fit, so their centers can be far
        // apart for a gentle curve; only the samples decide.
        guard !a.isLine, !b.isLine, a.ccw == b.ccw, let ca = a.center, let cb = b.center,
              ca.distance(to: cb) <= 0.1 * max(a.radius, b.radius), abs(a.radius - b.radius) <= 0.1 * max(a.radius, b.radius),
              a.sweep + b.sweep < 2 * .pi - 1e-3,
              let center = fittedCenter(samples + [a.start, a.end, b.end], through: a.start, b.end) else { return nil }
        let candidate = Piece(start: a.start, end: b.end, center: center, ccw: a.ccw, samples: samples)
        guard abs(candidate.sweep - (a.sweep + b.sweep)) < 1e-2, samples.allSatisfy({ candidate.distance(to: $0) <= tolerance }) else { return nil }
        return candidate
    }

    /// Pieces too short or too tight for a sketch removed, their neighbors meeting in their place,
    /// and arcs too flat or too small to keep made lines.
    static func sanitized(_ pieces: [Piece], closed: Bool) -> [Piece] {
        var result: [Piece] = []
        for var piece in pieces {
            if let last = result.last { piece = moved(piece, start: last.end) }
            if let c = piece.center {
                let r = piece.start.distance(to: c)
                if !c.isValid || r < shortest || r > 40_000 || piece.start.distance(to: piece.end) < 1e-5 { piece.center = nil }
            }
            if piece.start.distance(to: piece.end) < shortest && piece.isLine {
                // Dropped: the next piece starts where this one did.
                continue
            }
            result.append(piece)
        }
        if closed, let first = result.first, let last = result.last, last.end != first.start {
            result[result.count - 1] = moved(last, end: first.start)
            if let c = result[result.count - 1].center, result[result.count - 1].start.distance(to: c) < shortest { result[result.count - 1].center = nil }
        }
        return result.filter { $0.isLine ? $0.start.distance(to: $0.end) >= shortest / 2 : true }
    }

    /// The center of the circle that best fits `points` (least squares, Kåsa's method), moved
    /// onto the line of points as far from `start` as from `end`, so both lie exactly on it.
    static func fittedCenter(_ points: [Point2], through start: Point2, _ end: Point2) -> Point2? {
        guard let center = fittedCenter(points) else { return nil }
        let middle = (start + end) * 0.5, chord = end - start
        guard chord.length > 1e-12 else { return nil }
        let across = Point2(x: -chord.y / chord.length, y: chord.x / chord.length)
        let offset = center - middle
        return middle + across * (offset.x * across.x + offset.y * across.y)
    }

    static func fittedCenter(_ points: [Point2]) -> Point2? {
        guard points.count >= 3 else { return nil }
        let mean = points.reduce(Point2.zero, +) * (1 / Double(points.count))
        var suu = 0.0, svv = 0.0, suv = 0.0, suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        for p in points {
            let u = p.x - mean.x, v = p.y - mean.y
            suu += u * u; svv += v * v; suv += u * v
            suuu += u * u * u; svvv += v * v * v; suvv += u * v * v; svuu += v * u * u
        }
        let determinant = suu * svv - suv * suv
        guard abs(determinant) > 1e-18 * max(1, suu * svv) else { return nil }
        let bu = (suuu + suvv) / 2, bv = (svvv + svuu) / 2
        let center = mean + Point2(x: (bu * svv - bv * suv) / determinant, y: (suu * bv - suv * bu) / determinant)
        return center.isValid ? center : nil
    }

    /// How far a circle drawn as four cubic curves strays from the true circle, per radius.
    static let circleSlack = 3e-4

    /// A closed loop's circle, when every piece is an arc about one center.
    static func circle(_ pieces: [Piece], tolerance: Double) -> (center: Point2, radius: Double)? {
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isLine && $0.ccw == pieces[0].ccw }) else { return nil }
        let tolerance = max(tolerance, circleSlack * pieces.map(\.radius).max()!)
        let samples = pieces.flatMap { $0.samples + [$0.start] }
        guard let center = fittedCenter(samples) else { return nil }
        let radius = samples.reduce(0) { $0 + $1.distance(to: center) } / Double(max(1, samples.count))
        let total = pieces.reduce(0) { $0 + $1.sweep }
        guard radius >= shortest, abs(total - 2 * .pi) < 0.05, samples.allSatisfy({ abs($0.distance(to: center) - radius) <= tolerance }) else { return nil }
        return (center, radius)
    }

    // MARK: Sketch shapes

    /// The loops as sketch shapes on `plane`: lines, arcs (counterclockwise, as sketches keep
    /// them), and circles.
    static func shapes(_ loops: [Loop], plane: SketchPlane) -> [SketchShape] {
        var shapes: [SketchShape] = []
        for loop in loops {
            if let circle = loop.circle {
                shapes.append(SketchShape(kind: .circle, plane: plane, start: circle.center, end: circle.center + Point2(x: circle.radius, y: 0)))
                continue
            }
            for piece in loop.pieces {
                if let c = piece.center {
                    let shape = piece.ccw ? SketchShape(kind: .arc, plane: plane, start: piece.start, end: piece.end, arcCenter: c)
                                          : SketchShape(kind: .arc, plane: plane, start: piece.end, end: piece.start, arcCenter: c)
                    if shape.isValid { shapes.append(shape); continue }
                }
                let line = SketchShape(kind: .line, plane: plane, start: piece.start, end: piece.end)
                if line.isValid { shapes.append(line) }
            }
        }
        return shapes
    }
}
