import Foundation

// Closed regions of a sketch: shapes that cross or touch divide each other into
// separate regions, and an outline inside a region (a circle in a rectangle) is a hole in it
// (schema 16). A closed shape that nothing divides is still its own region with its own id, and a
// loop of whole lines joined end to end is named by its lines, exactly as before.

extension Geometry {
    /// Regions of `shapes` on `plane`, smallest first. Results are cached by the shapes, since the
    /// canvas asks for them many times a frame.
    static func profiles(in shapes: [SketchShape], on plane: SketchPlane) -> [SketchProfile] {
        // Construction lines and points are references: they bound no region.
        let shapes = shapes.filter { $0.plane == plane && $0.isValid && !$0.isConstruction && $0.kind != .point }
        guard !shapes.isEmpty else { return [] }
        return RegionCache.shared.profiles(shapes, plane: plane) { SketchRegions(shapes: shapes, plane: plane).profiles() }
    }
}

/// Recently found regions, keyed by the shapes they came from.
final class RegionCache: @unchecked Sendable {
    static let shared = RegionCache()
    private let lock = NSLock()
    private var entries: [(shapes: [SketchShape], plane: SketchPlane, profiles: [SketchProfile])] = []

    func profiles(_ shapes: [SketchShape], plane: SketchPlane, compute: () -> [SketchProfile]) -> [SketchProfile] {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.plane == plane && $0.shapes == shapes }) {
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            lock.unlock()
            return entry.profiles
        }
        lock.unlock()
        let profiles = compute()
        lock.lock()
        entries.insert((shapes, plane, profiles), at: 0)
        if entries.count > 64 { entries.removeLast() }
        lock.unlock()
        return profiles
    }
}

/// One stretch of sketch geometry: a polyline (a line is two points) or a counterclockwise arc.
/// Its parameter runs from 0 to `span`: the point index along a polyline, the angle along an arc.
struct SketchCurve: Sendable {
    enum Kind: Sendable {
        case polyline([Point2])
        case arc(center: Point2, radius: Double, from: Double, sweep: Double)
    }
    var kind: Kind

    var span: Double {
        switch kind {
        case .polyline(let points): Double(points.count - 1)
        case .arc(_, _, _, let sweep): sweep
        }
    }

    func point(_ t: Double) -> Point2 {
        switch kind {
        case .polyline(let points):
            let i = max(0, min(points.count - 2, Int(t.rounded(.down)))), f = t - Double(i)
            return points[i] + (points[i + 1] - points[i]) * f
        case .arc(let center, let radius, let from, _):
            return center + Point2(x: cos(from + t), y: sin(from + t)) * radius
        }
    }

    /// The direction of travel at `t` (toward increasing t).
    func tangent(_ t: Double, leaving: Bool = true) -> Point2 {
        switch kind {
        case .polyline(let points):
            var i = max(0, min(points.count - 2, Int(t.rounded(.down))))
            // At a corner, leaving takes the next segment and arriving the previous one.
            if !leaving, Double(i) == t, i > 0 { i -= 1 }
            let d = points[i + 1] - points[i]
            return d * (1 / max(1e-300, d.length))
        case .arc(_, _, let from, _):
            return Point2(x: -sin(from + t), y: cos(from + t))
        }
    }

    /// Points from `t0` to `t1` (t0 < t1), both ends included: polyline corners between them, or
    /// an arc every 3° at most (at least two segments).
    func points(_ t0: Double, _ t1: Double) -> [Point2] {
        switch kind {
        case .polyline(let points):
            var result = [point(t0)]
            var i = Int(t0.rounded(.down)) + 1
            while Double(i) < t1 - 1e-12, i < points.count { result.append(points[i]); i += 1 }
            result.append(point(t1))
            return result
        case .arc:
            let count = max(2, Int(((t1 - t0) / (.pi / 60)).rounded(.up)))
            return (0...count).map { point(t0 + (t1 - t0) * Double($0) / Double(count)) }
        }
    }

    /// The point of the curve nearest `p`.
    func nearestPoint(to p: Point2) -> Point2 {
        switch kind {
        case .polyline(let points):
            return zip(points, points.dropFirst()).map { a, b -> Point2 in
                let d = b - a, length2 = Geometry.dot(d, d)
                return length2 > 1e-18 ? a + d * max(0, min(1, Geometry.dot(p - a, d) / length2)) : a
            }.min { $0.distance(to: p) < $1.distance(to: p) } ?? points[0]
        case .arc(let center, let radius, let from, let sweep):
            var t = atan2(p.y - center.y, p.x - center.x) - from
            t -= 2 * .pi * (t / (2 * .pi)).rounded(.down)
            // Off the arc: whichever end is nearer.
            if t > sweep { return [point(0), point(sweep)].min { $0.distance(to: p) < $1.distance(to: p) }! }
            return point(t)
        }
    }

    var bounds: (low: Point2, high: Point2) {
        switch kind {
        case .polyline(let points):
            return (Point2(x: points.map(\.x).min()!, y: points.map(\.y).min()!), Point2(x: points.map(\.x).max()!, y: points.map(\.y).max()!))
        case .arc(let center, let radius, _, _):
            return (center - Point2(x: radius, y: radius), center + Point2(x: radius, y: radius))
        }
    }

    /// The arc's parameter for an angle, if the angle is on it (within `tolerance` radians of its ends).
    private func arcParameter(_ angle: Double, tolerance: Double) -> Double? {
        guard case .arc(_, _, let from, let sweep) = kind else { return nil }
        var t = angle - from
        while t < -tolerance { t += 2 * .pi }
        while t > 2 * .pi - tolerance { t -= 2 * .pi }
        if t < 0 { t = 0 }
        if t > sweep && t - sweep <= tolerance { t = sweep }
        return t <= sweep ? t : nil
    }

    /// Where this curve meets `other`: each meeting's parameter on this curve and on the other.
    /// Touching counts (an end lying on the other curve), and where straight pieces overlap, each
    /// one's ends inside the other count.
    func meetings(with other: SketchCurve) -> [(Double, Double)] {
        let a = bounds, b = other.bounds, pad = 1e-6
        guard a.low.x <= b.high.x + pad, b.low.x <= a.high.x + pad, a.low.y <= b.high.y + pad, b.low.y <= a.high.y + pad else { return [] }
        switch (kind, other.kind) {
        case (.polyline(let p), .polyline(let q)):
            var result: [(Double, Double)] = []
            for i in 0..<(p.count - 1) {
                let a0 = p[i], a1 = p[i + 1]
                let alo = Point2(x: min(a0.x, a1.x) - pad, y: min(a0.y, a1.y) - pad), ahi = Point2(x: max(a0.x, a1.x) + pad, y: max(a0.y, a1.y) + pad)
                for j in 0..<(q.count - 1) {
                    let b0 = q[j], b1 = q[j + 1]
                    guard max(b0.x, b1.x) >= alo.x, min(b0.x, b1.x) <= ahi.x, max(b0.y, b1.y) >= alo.y, min(b0.y, b1.y) <= ahi.y else { continue }
                    for (s, t) in Self.segmentMeetings(a0, a1, b0, b1) { result.append((Double(i) + s, Double(j) + t)) }
                }
            }
            return result
        case (.polyline(let p), .arc(let center, let radius, _, _)):
            var result: [(Double, Double)] = []
            for i in 0..<(p.count - 1) {
                for (s, angle) in Self.segmentCircle(p[i], p[i + 1], center, radius) {
                    if let t = other.arcParameter(angle, tolerance: 1e-9 / max(radius, 1e-9) * 1e3) { result.append((Double(i) + s, t)) }
                }
            }
            return result
        case (.arc, .polyline):
            return other.meetings(with: self).map { ($0.1, $0.0) }
        case (.arc(let c1, let r1, _, let sweep1), .arc(let c2, let r2, _, let sweep2)):
            let d = c2 - c1, distance = d.length
            if distance <= 1e-9, abs(r1 - r2) <= 1e-7 {
                // The same circle: as with overlapping straight pieces, each one's ends on the other meet.
                let tolerance = 1e-6 / max(min(r1, r2), 1e-9)
                var result: [(Double, Double)] = []
                for s in [0, sweep1] {
                    let p = point(s)
                    if let t = other.arcParameter(atan2(p.y - c2.y, p.x - c2.x), tolerance: tolerance) { result.append((s, t)) }
                }
                for t in [0, sweep2] {
                    let p = other.point(t)
                    if let s = arcParameter(atan2(p.y - c1.y, p.x - c1.x), tolerance: tolerance) { result.append((s, t)) }
                }
                return result
            }
            guard distance > 1e-9, distance <= r1 + r2 + 1e-7, distance >= abs(r1 - r2) - 1e-7 else { return [] }
            let along = (distance * distance + r1 * r1 - r2 * r2) / (2 * distance)
            let height = max(0, r1 * r1 - along * along).squareRoot()
            let base = c1 + d * (along / distance), across = Point2(x: -d.y / distance, y: d.x / distance)
            let points = height < 1e-9 ? [base] : [base + across * height, base - across * height]
            return points.compactMap { point in
                let tolerance = 1e-6 / max(min(r1, r2), 1e-9)
                guard let s = arcParameter(atan2(point.y - c1.y, point.x - c1.x), tolerance: tolerance),
                      let t = other.arcParameter(atan2(point.y - c2.y, point.x - c2.x), tolerance: tolerance) else { return nil }
                return (s, t)
            }
        }
    }

    /// Fractions along segments ab and cd where they meet.
    static func segmentMeetings(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> [(Double, Double)] {
        let r = b - a, s = d - c, denominator = Geometry.cross(r, s)
        let rr = Geometry.dot(r, r), ss = Geometry.dot(s, s)
        guard rr > 1e-18, ss > 1e-18 else { return [] }
        let tolerance = 1e-7
        if abs(denominator) > 1e-12 * (rr * ss).squareRoot() {
            let t = Geometry.cross(c - a, s) / denominator, u = Geometry.cross(c - a, r) / denominator
            let tt = tolerance / rr.squareRoot(), uu = tolerance / ss.squareRoot()
            guard t >= -tt, t <= 1 + tt, u >= -uu, u <= 1 + uu else { return [] }
            return [(min(1, max(0, t)), min(1, max(0, u)))]
        }
        // Parallel: only collinear overlaps meet, at each segment's ends inside the other.
        guard abs(Geometry.cross(c - a, r)) / rr.squareRoot() < tolerance else { return [] }
        var result: [(Double, Double)] = []
        func on(_ p: Point2, _ from: Point2, _ direction: Point2, _ length2: Double) -> Double? {
            let f = Geometry.dot(p - from, direction) / length2
            return f >= -1e-9 && f <= 1 + 1e-9 ? min(1, max(0, f)) : nil
        }
        if let u = on(a, c, s, ss) { result.append((0, u)) }
        if let u = on(b, c, s, ss) { result.append((1, u)) }
        if let t = on(c, a, r, rr) { result.append((t, 0)) }
        if let t = on(d, a, r, rr) { result.append((t, 1)) }
        return result
    }

    /// Where segment ab crosses the circle: the fraction along the segment and the angle on the circle.
    static func segmentCircle(_ a: Point2, _ b: Point2, _ center: Point2, _ radius: Double) -> [(Double, Double)] {
        let d = b - a, f = a - center
        let aa = Geometry.dot(d, d), bb = 2 * Geometry.dot(f, d), cc = Geometry.dot(f, f) - radius * radius
        guard aa > 1e-18 else { return [] }
        let discriminant = bb * bb - 4 * aa * cc
        let slack = 4 * aa * 1e-7 * radius
        guard discriminant >= -slack else { return [] }
        let root = max(0, discriminant).squareRoot()
        let roots = root < 1e-12 ? [-bb / (2 * aa)] : [(-bb - root) / (2 * aa), (-bb + root) / (2 * aa)]
        let tolerance = 1e-7 / aa.squareRoot()
        return roots.compactMap { t in
            guard t >= -tolerance, t <= 1 + tolerance else { return nil }
            let p = a + d * min(1, max(0, t))
            return (min(1, max(0, t)), atan2(p.y - center.y, p.x - center.x))
        }
    }
}

extension SketchShape {
    /// The shape as curves for finding regions. Closed shapes made of one curve (circles, closed
    /// curves) come as two halves, so dividing them never needs a loop from a point to itself.
    var regionCurves: [SketchCurve] {
        switch kind {
        case .line: return [SketchCurve(kind: .polyline([start, end]))]
        case .rectangle:
            let p = outline
            return (0..<4).map { SketchCurve(kind: .polyline([p[$0], p[($0 + 1) % 4]])) }
        case .circle:
            let radius = start.distance(to: end)
            return [SketchCurve(kind: .arc(center: start, radius: radius, from: 0, sweep: .pi)),
                    SketchCurve(kind: .arc(center: start, radius: radius, from: .pi, sweep: .pi))]
        case .arc:
            guard let c = arcCenter else { return [] }
            return [SketchCurve(kind: .arc(center: c, radius: start.distance(to: c), from: atan2(start.y - c.y, start.x - c.x), sweep: arcSweep))]
        case .slot:
            let d = end - start, length = d.length, radius = (width ?? 0) / 2
            guard length > 1e-12 else { return [] }
            let heading = atan2(d.y, d.x), left = Point2(x: -d.y / length, y: d.x / length)
            return [SketchCurve(kind: .arc(center: end, radius: radius, from: heading - .pi / 2, sweep: .pi)),
                    SketchCurve(kind: .polyline([end + left * radius, start + left * radius])),
                    SketchCurve(kind: .arc(center: start, radius: radius, from: heading + .pi / 2, sweep: .pi)),
                    SketchCurve(kind: .polyline([start - left * radius, end - left * radius]))]
        case .point: return []
        case .ellipse:
            // Two halves of its outline (divided, it is followed by these points).
            let loop = outline + [outline[0]], half = loop.count / 2
            return [SketchCurve(kind: .polyline(Array(loop[0...half]))), SketchCurve(kind: .polyline(Array(loop[half...])))]
        case .curve:
            // A spline is followed along its smooth outline, not the points it passes through.
            guard let points = isSpline ? outline : points, points.count >= 2 else { return [] }
            guard isClosed else { return [SketchCurve(kind: .polyline(points))] }
            let loop = points + [points[0]], half = loop.count / 2
            return [SketchCurve(kind: .polyline(Array(loop[0...half]))), SketchCurve(kind: .polyline(Array(loop[half...])))]
        }
    }

    /// The region a closed shape bounds on its own: its outline, exact circle, and exact arcs.
    var ownRegion: (outline: [Point2], circle: CircleProfile?, arcs: [ProfileArc]?, ellipse: EllipseProfile?) {
        switch kind {
        case .circle: return (outline, CircleProfile(center: start, radius: start.distance(to: end)), nil, nil)
        case .slot: let slot = slotOutline; return (slot.points, nil, slot.arcs, nil)
        case .ellipse: return (outline, nil, nil, ellipseProfile)
        default: return (outline, nil, nil, nil)
        }
    }
}

/// Finds a sketch's regions: the faces of the arrangement its shapes make.
struct SketchRegions {
    var shapes: [SketchShape]
    var plane: SketchPlane

    private struct HalfEdge {
        var from: Int, to: Int
        var points: [Point2]
        var source: UUID
        var arc: CircleProfile?
        /// Direction leaving `from`, for ordering edges around a vertex.
        var heading: Double
        /// How the edge bends leaving `from` (1/radius, positive turning left), to order edges that
        /// leave in the same direction: a circle tangent to a line or to another circle.
        var curvature: Double
        /// A point halfway along, to tell apart edges with the same ends.
        var middle: Point2
        /// Part of a shape cut short by another (or of a divided closed shape).
        var partial: Bool
    }

    func profiles() -> [SketchProfile] {
        let curves = shapes.map(\.regionCurves)
        // Where shapes meet, as parameters along each curve.
        var splits = curves.map { $0.map { _ in [Double]() } }
        var touched = [Bool](repeating: false, count: shapes.count)
        for i in shapes.indices {
            for j in shapes.indices where j > i {
                for (ci, a) in curves[i].enumerated() {
                    for (cj, b) in curves[j].enumerated() {
                        let meetings = a.meetings(with: b)
                        guard !meetings.isEmpty else { continue }
                        touched[i] = true; touched[j] = true
                        for (s, t) in meetings { splits[i][ci].append(s); splits[j][cj].append(t) }
                    }
                }
            }
        }
        var profiles: [SketchProfile] = []
        // Hole candidates: closed loops (counterclockwise) with a point on them, and what they belong to.
        var loops: [(hole: ProfileHole, point: Point2, owner: Int)] = []
        // Closed shapes that meet nothing are regions of their own, as they always were.
        for (index, shape) in shapes.enumerated() where shape.isClosed && !touched[index] {
            let own = shape.ownRegion
            guard shape.kind != .curve || Geometry.isSimplePolygon(own.outline) else { continue }
            profiles.append(SketchProfile(id: shape.id.uuidString, plane: plane, sourceIDs: [shape.id], outline: own.outline,
                                          circle: own.circle, arcs: own.arcs, ellipse: own.ellipse))
            loops.append((ProfileHole(outline: own.outline, circle: own.circle, arcs: own.arcs, ellipse: own.ellipse), own.outline[0], -1 - (profiles.count - 1)))
        }

        // Everything else is divided at the meetings into edges of a planar graph.
        var vertices: [Point2] = []
        func vertex(_ p: Point2) -> Int {
            if let index = vertices.firstIndex(where: { $0.distance(to: p) < 1e-5 }) { return index }
            vertices.append(p)
            return vertices.count - 1
        }
        var edges: [HalfEdge] = []
        for (index, shape) in shapes.enumerated() where !(shape.isClosed && !touched[index]) {
            for (ci, curve) in curves[index].enumerated() {
                let span = curve.span
                let cuts = ([0, span] + splits[index][ci].filter { $0 > 1e-9 && $0 < span - 1e-9 }).sorted()
                var stops: [Double] = []
                for t in cuts where stops.last.map({ curve.point(t).distance(to: curve.point($0)) > 1e-6 }) ?? true { stops.append(t) }
                if let last = stops.last, last < span { stops[stops.count - 1] = span }
                let partial = shape.isClosed || stops.count > 2
                for (t0, t1) in zip(stops, stops.dropFirst()) {
                    var points = curve.points(t0, t1)
                    let a = vertex(points[0]), b = vertex(points[points.count - 1])
                    guard a != b else { continue }
                    points[0] = vertices[a]; points[points.count - 1] = vertices[b]
                    var arc: CircleProfile?
                    if case .arc(let center, let radius, _, _) = curve.kind { arc = CircleProfile(center: center, radius: radius) }
                    // The same stretch twice (overlapping lines, an arc along a circle) is one edge.
                    let middle = curve.point((t0 + t1) / 2)
                    if edges.contains(where: { ($0.from == a && $0.to == b || $0.from == b && $0.to == a) && $0.middle.distance(to: middle) < 1e-5 }) { continue }
                    let out = curve.tangent(t0), back = curve.tangent(t1, leaving: false)
                    // Arcs run counterclockwise: forward they turn left, backward right.
                    let curvature = arc.map { 1 / $0.radius } ?? 0
                    edges.append(HalfEdge(from: a, to: b, points: points, source: shape.id, arc: arc, heading: atan2(out.y, out.x),
                                          curvature: curvature, middle: middle, partial: partial))
                    edges.append(HalfEdge(from: b, to: a, points: points.reversed(), source: shape.id, arc: arc, heading: atan2(-back.y, -back.x),
                                          curvature: -curvature, middle: middle, partial: partial))
                }
            }
        }
        // Dangling edges bound nothing: drop them until every vertex has two edges or none.
        var alive = [Bool](repeating: true, count: edges.count)
        var changed = true
        while changed {
            changed = false
            var degree = [Int](repeating: 0, count: vertices.count)
            for index in stride(from: 0, to: edges.count, by: 2) where alive[index] { degree[edges[index].from] += 1; degree[edges[index].to] += 1 }
            for index in stride(from: 0, to: edges.count, by: 2) where alive[index] && (degree[edges[index].from] < 2 || degree[edges[index].to] < 2) {
                alive[index] = false; alive[index + 1] = false; changed = true
            }
        }
        // Connected pieces of the graph: a loop of one piece never holds a region of the same piece.
        var parent = Array(vertices.indices)
        func root(_ v: Int) -> Int { var v = v; while parent[v] != v { parent[v] = parent[parent[v]]; v = parent[v] }; return v }
        for index in edges.indices where alive[index] { let a = root(edges[index].from), b = root(edges[index].to); if a != b { parent[a] = b } }

        var outgoing: [Int: [Int]] = [:]
        for index in edges.indices where alive[index] { outgoing[edges[index].from, default: []].append(index) }
        for (key, leaving) in outgoing { outgoing[key] = Self.counterclockwise(leaving, edges) }
        var visited = Set<Int>()
        var faces: [(profile: SketchProfile, component: Int)] = []
        let order = edges.indices.filter { alive[$0] }.sorted { (edges[$0].from, edges[$0].to, $0) < (edges[$1].from, edges[$1].to, $1) }
        for start in order where !visited.contains(start) {
            var current = start, path: [Int] = [], closed = false
            for _ in 0...edges.count {
                if visited.contains(current) { closed = current == start; break }
                visited.insert(current)
                path.append(current)
                guard let leaving = outgoing[edges[current].to], let i = leaving.firstIndex(of: current ^ 1) else { break }
                current = leaving[(i + leaving.count - 1) % leaving.count]
            }
            let indices = path.map { edges[$0].from }
            guard closed, Set(indices).count == indices.count else { continue }
            let loop = Self.loop(path.map { edges[$0] })
            let area = Geometry.signedArea(loop.outline)
            let component = root(edges[start].from)
            if area > 1e-8 {
                guard Geometry.isSimplePolygon(loop.outline) else { continue }
                let sources = Array(Set(path.map { edges[$0].source })).sorted { $0.uuidString < $1.uuidString }
                var profile = SketchProfile(id: sources.map(\.uuidString).joined(separator: ":"), plane: plane, sourceIDs: sources,
                                            outline: loop.outline, arcs: loop.arcs.isEmpty ? nil : loop.arcs)
                if path.contains(where: { edges[$0].partial }) {
                    // A closed shape that only touches others still bounds its own region: name it as before.
                    // (The walk samples arcs every 3°, its own outline more finely: their areas differ slightly.)
                    if sources.count == 1, let shape = shapes.first(where: { $0.id == sources[0] }), shape.isClosed,
                       abs(abs(Geometry.signedArea(shape.ownRegion.outline)) - area) < 1e-2 * max(1, area) {
                        let own = shape.ownRegion
                        profile = SketchProfile(id: shape.id.uuidString, plane: plane, sourceIDs: [shape.id], outline: own.outline,
                                                circle: own.circle, arcs: own.arcs, ellipse: own.ellipse)
                    } else {
                        // Pieces of divided shapes: several regions share their shapes, so the place tells them apart.
                        let c = profile.center
                        profile.id += String(format: "#%.3f,%.3f", c.x, c.y)
                    }
                }
                faces.append((profile, component))
            } else if area < -1e-8, Geometry.isSimplePolygon(loop.outline) {
                // The outside of a connected piece: walked the other way round, it may be a hole in a region around it.
                let reversed = Self.loop(path.reversed().map { edges[$0 ^ 1] })
                loops.append((ProfileHole(outline: reversed.outline, arcs: reversed.arcs.isEmpty ? nil : reversed.arcs),
                              (reversed.outline[0] + reversed.outline[1]) * 0.5, component))
            }
        }
        let graphStart = profiles.count
        profiles += faces.map(\.profile)

        // Each loop is a hole in the smallest region around it that is not its own piece.
        for loop in loops {
            var best: Int?
            for index in profiles.indices {
                if loop.owner < 0 { if index == -1 - loop.owner { continue } }
                else if index >= graphStart, faces[index - graphStart].component == loop.owner { continue }
                let region = profiles[index]
                guard abs(Geometry.signedArea(region.outline)) > loop.hole.area + 1e-9, Geometry.contains(loop.point, in: region.outline),
                      Geometry.distanceToOutline(loop.point, region.outline) > 1e-6 else { continue }
                if best.map({ abs(Geometry.signedArea(region.outline)) < abs(Geometry.signedArea(profiles[$0].outline)) }) ?? true { best = index }
            }
            if let best { profiles[best].holes = (profiles[best].holes ?? []) + [loop.hole] }
        }
        // A hole inside another of the same region's holes belongs to a region inside that hole instead.
        for index in profiles.indices {
            guard let holes = profiles[index].holes, holes.count > 1 else { continue }
            profiles[index].holes = holes.filter { hole in !holes.contains { other in other.area > hole.area && Geometry.contains(hole.outline[0], in: other.outline) } }
        }
        return profiles.sorted { $0.area < $1.area }
    }

    /// Edges leaving one vertex, counterclockwise. Edges leaving in the same direction (tangent
    /// curves) are ordered by how they bend: one turning further left lies further counterclockwise.
    private static func counterclockwise(_ leaving: [Int], _ edges: [HalfEdge]) -> [Int] {
        let tolerance = 1e-6
        var sorted = leaving.sorted { edges[$0].heading < edges[$1].heading }
        func turn(_ i: Int, _ j: Int) -> Double {
            let d = edges[j].heading - edges[i].heading
            return d < 0 ? d + 2 * .pi : d
        }
        // Start after a real gap, so a run of equal directions never wraps around the start.
        guard sorted.count > 1, let gap = sorted.indices.first(where: { turn(sorted[$0], sorted[($0 + 1) % sorted.count]) > tolerance }) else {
            return sorted.sorted { edges[$0].curvature < edges[$1].curvature }
        }
        sorted = Array(sorted[(gap + 1)...] + sorted[...gap])
        var result: [Int] = [], run: [Int] = []
        for (i, index) in sorted.enumerated() {
            run.append(index)
            if i + 1 == sorted.count || turn(index, sorted[i + 1]) > tolerance {
                result += run.sorted { edges[$0].curvature < edges[$1].curvature }
                run = []
            }
        }
        return result
    }

    /// A closed loop's points (each edge's start and interior points) and its exact arcs.
    /// Consecutive pieces of one circle join into one exact arc (the meeting between them only
    /// divided the circle), as long as the arc stays short of a full turn.
    private static func loop(_ path: [HalfEdge]) -> (outline: [Point2], arcs: [ProfileArc]) {
        func same(_ a: CircleProfile?, _ b: CircleProfile?) -> Bool {
            guard let a, let b else { return false }
            return a.center.distance(to: b.center) < 1e-7 && abs(a.radius - b.radius) < 1e-7
        }
        // Start where an arc run begins, so no run wraps past the start.
        var edges = path
        if edges.count > 1, let first = edges.indices.first(where: { !same(edges[$0].arc, edges[($0 + edges.count - 1) % edges.count].arc) }) {
            edges = Array(edges[first...] + edges[..<first])
        }
        var points: [Point2] = [], arcs: [ProfileArc] = []
        let total = edges.reduce(0) { $0 + $1.points.count - 1 }
        for (index, edge) in edges.enumerated() {
            if let arc = edge.arc {
                if index > 0, same(edges[index - 1].arc, arc), let last = arcs.last, last.start + last.segments == points.count,
                   last.segments + edge.points.count - 1 < total {
                    arcs[arcs.count - 1].segments += edge.points.count - 1
                } else {
                    arcs.append(ProfileArc(start: points.count, segments: edge.points.count - 1, center: arc.center, radius: arc.radius))
                }
            }
            points += edge.points.dropLast()
        }
        return (points, arcs)
    }
}
