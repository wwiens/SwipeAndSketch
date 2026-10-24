import Foundation

/// Round-off cleanup for computed geometry: kernel and trigonometry noise (a centroid at 1e-16 mm,
/// an axis at 6e-17) becomes exact, so quarter turns land on whole axes and shared points stay shared.
extension SIMD3 where Scalar == Double {
    /// Rounded to steps of 1/`scale`, without negative zeros.
    func roundedOff(_ scale: Double = 1e9) -> SIMD3<Double> {
        let r = (self * scale).rounded(.toNearestOrEven) / scale
        return SIMD3(r.x == 0 ? 0 : r.x, r.y == 0 ? 0 : r.y, r.z == 0 ? 0 : r.z)
    }
}

extension Point2 {
    /// Rounded to steps of 1/`scale`, without negative zeros.
    func roundedOff(_ scale: Double = 1e9) -> Point2 {
        let x = (x * scale).rounded(.toNearestOrEven) / scale, y = (y * scale).rounded(.toNearestOrEven) / scale
        return Point2(x: x == 0 ? 0 : x, y: y == 0 ? 0 : y)
    }
}

struct Point2: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    static let zero = Point2(x: 0, y: 0)
    static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Self, b: Double) -> Self { .init(x: a.x * b, y: a.y * b) }
    var length: Double { hypot(x, y) }
    func distance(to p: Self) -> Double { (self - p).length }
    var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 100_000 && abs(y) <= 100_000 }
}

/// A sketch plane: one of the three world planes, or the plane of a flat solid face.
/// Sketch coordinates (u, v) map to `origin + u * xAxis + v * yAxis`; extrusion follows
/// `normal = xAxis × yAxis`. See SketchPlanes.swift and Docs/ProjectFiles.md.
struct SketchPlane: Hashable, Sendable {
    var origin: SIMD3<Double>
    var xAxis: SIMD3<Double>
    var yAxis: SIMD3<Double>
}

enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case line, circle, rectangle
    /// A circular arc, counterclockwise from `start` to `end` about `arcCenter` (schema 10). Made by
    /// Project, not drawn.
    case arc
    /// A polyline through `points`, open or `closed` (schema 10): projected ellipses, silhouettes,
    /// and other curves that are not lines, circles, or arcs. Made by Project, not drawn.
    case curve
    /// A slot (schema 16): the stadium around the segment from `start` to `end` (the centers of its
    /// round ends), `width` across.
    case slot
    /// An ellipse (October 21, 2026): centered on `start`, its own axis running to `end`, and
    /// `width` across that axis (its other diameter).
    case ellipse
    /// A sketch point (October 21, 2026): `start` (and `end`, the same). A place to snap to,
    /// dimension from, and align to; it bounds no region.
    case point
    /// The kinds the drawing tools make.
    static let drawn: [ShapeKind] = [.line, .circle, .rectangle, .arc, .slot, .ellipse, .point]
    var title: String { rawValue.capitalized }
}

struct SketchShape: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: ShapeKind
    var plane: SketchPlane
    var start: Point2
    var end: Point2
    /// Rectangles drawn from their center keep that center when resized. Optional and omitted
    /// when unset, so files stay readable by older builds (they see a normal rectangle).
    var centered: Bool?
    /// The sketch this shape belongs to (see Sketches.swift). Assigned when it joins a workspace.
    var sketch: UUID?
    /// Arcs: the center. Omitted for other kinds.
    var arcCenter: Point2?
    /// Curves: every point, `start` first and (open curves) `end` last. Omitted for other kinds.
    var points: [Point2]?
    /// Curves: the last point joins the first. Omitted when open.
    var closed: Bool?
    /// Slots: the full width across; ellipses: the diameter across their axis. Omitted for other kinds.
    var width: Double?
    /// Construction geometry (October 21, 2026): a reference that is drawn dashed, snapped to, and
    /// usable as an axis or mirror line, but bounds no region. Omitted otherwise.
    var construction: Bool?
    var isConstruction: Bool { construction == true }
    var isCentered: Bool { kind == .rectangle && centered == true }
    var center: Point2 { (start + end) * 0.5 }
    /// Whether the outline returns to its start: circles, rectangles, and closed curves.
    var isClosed: Bool {
        switch kind {
        case .line, .arc, .point: false
        case .circle, .rectangle, .slot, .ellipse: true
        case .curve: closed == true
        }
    }

    /// An ellipse's exact curve.
    var ellipseProfile: EllipseProfile? {
        guard kind == .ellipse, let width else { return nil }
        let axis = end - start
        return EllipseProfile(center: start, radiusX: axis.length, radiusY: width / 2, angle: atan2(axis.y, axis.x))
    }

    /// An arc counterclockwise from `start` to `end` about `center`. `end` is placed exactly on the
    /// circle through `start`.
    static func arc(center: Point2, from start: Point2, to end: Point2, plane: SketchPlane) -> SketchShape {
        let radius = start.distance(to: center), offset = end - center
        let onCircle = offset.length > 0 ? center + offset * (radius / offset.length) : end
        return SketchShape(kind: .arc, plane: plane, start: start, end: onCircle, arcCenter: center)
    }

    /// The arc from `start` to `end` through `middle` (a 3-point arc), counterclockwise whichever way
    /// it was drawn. Nil when the three points are (nearly) in a line.
    static func arc(from start: Point2, through middle: Point2, to end: Point2, plane: SketchPlane) -> SketchShape? {
        guard let center = Geometry.circumcenter(start, middle, end) else { return nil }
        // Counterclockwise from start, the arc reaches the middle before the end, or it runs the other way.
        func angle(_ p: Point2) -> Double {
            var a = atan2(p.y - center.y, p.x - center.x) - atan2(start.y - center.y, start.x - center.x)
            while a < 0 { a += 2 * .pi }
            return a
        }
        let shape = angle(middle) < angle(end) ? arc(center: center, from: start, to: end, plane: plane) : arc(center: center, from: end, to: start, plane: plane)
        return shape.isValid ? shape : nil
    }

    /// The arc from `start` to `end`, counterclockwise, turning `sweep` radians (0 < sweep < 2π).
    static func arc(from start: Point2, to end: Point2, sweep: Double, plane: SketchPlane) -> SketchShape? {
        let chord = end - start, length = chord.length
        guard length > 1e-9, sweep > 1e-9, sweep < 2 * .pi - 1e-9 else { return nil }
        // The center sits off the chord's middle, to the left for sweeps under a half turn.
        let left = Point2(x: -chord.y / length, y: chord.x / length)
        let center = (start + end) * 0.5 + left * (length / 2 / tan(sweep / 2))
        let shape = arc(center: center, from: start, to: end, plane: plane)
        return shape.isValid ? shape : nil
    }

    /// A slot between two centers.
    static func slot(from start: Point2, to end: Point2, width: Double, plane: SketchPlane) -> SketchShape {
        SketchShape(kind: .slot, plane: plane, start: start, end: end, width: width)
    }

    /// An arc's point halfway around it.
    var arcMiddle: Point2 {
        guard let c = arcCenter else { return center }
        let radius = start.distance(to: c), angle = atan2(start.y - c.y, start.x - c.x) + arcSweep / 2
        return c + Point2(x: cos(angle), y: sin(angle)) * radius
    }

    static func curve(_ points: [Point2], closed: Bool, plane: SketchPlane) -> SketchShape {
        SketchShape(kind: .curve, plane: plane, start: points.first ?? .zero, end: closed ? points.first ?? .zero : points.last ?? .zero,
                    points: points, closed: closed ? true : nil)
    }

    /// Counterclockwise angle from `start` to `end` about the arc center, in (0, 2π].
    var arcSweep: Double {
        guard let c = arcCenter else { return 0 }
        var sweep = atan2(end.y - c.y, end.x - c.x) - atan2(start.y - c.y, start.x - c.x)
        while sweep <= 0 { sweep += 2 * .pi }
        while sweep > 2 * .pi { sweep -= 2 * .pi }
        return sweep
    }

    var isValid: Bool {
        guard start.isValid, end.isValid, plane.isValid else { return false }
        guard (width != nil) == (kind == .slot || kind == .ellipse), construction != false else { return false }
        switch kind {
        case .point: return start == end && arcCenter == nil && points == nil
        case .ellipse:
            guard let width, arcCenter == nil, points == nil else { return false }
            return start.distance(to: end) >= 0.005 && width.isFinite && width >= 0.01 && width <= 200_000
        case .line, .circle: return start.distance(to: end) >= 0.01
        case .slot:
            guard let width else { return false }
            return start.distance(to: end) >= 0.01 && width.isFinite && width >= 0.02 && width <= 20_000
        case .rectangle: return abs(end.x - start.x) >= 0.01 && abs(end.y - start.y) >= 0.01
        case .arc:
            guard let c = arcCenter, c.isValid, points == nil else { return false }
            let radius = start.distance(to: c)
            return radius >= 0.01 && abs(end.distance(to: c) - radius) <= max(1e-6, radius * 1e-9) && start.distance(to: end) >= 1e-6
        case .curve:
            guard let points, (2...4_096).contains(points.count), points.allSatisfy(\.isValid), arcCenter == nil,
                  start == points[0], end == (isClosed ? points[0] : points[points.count - 1]),
                  zip(points, points.dropFirst()).allSatisfy({ $0.distance(to: $1) >= 1e-9 }) else { return false }
            if isClosed { return points.count >= 3 && abs(Geometry.signedArea(points)) > 1e-8 }
            return zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } >= 0.01
        }
    }

    var outline: [Point2] {
        switch kind {
        case .slot: return slotOutline.points
        case .ellipse: return ellipseProfile?.outline() ?? [start]
        case .point: return [start]
        case .curve: return points ?? [start, end]
        case .arc:
            // Every 3° at most; the ends are exact.
            guard let c = arcCenter else { return [start, end] }
            let sweep = arcSweep, radius = start.distance(to: c), from = atan2(start.y - c.y, start.x - c.x)
            let count = max(2, Int((sweep / (.pi / 60)).rounded(.up)))
            return [start] + (1..<count).map { i in
                let angle = from + sweep * Double(i) / Double(count)
                return c + Point2(x: cos(angle), y: sin(angle)) * radius
            } + [end]
        case .line: return [start, end]
        case .rectangle:
            let lo = Point2(x: min(start.x, end.x), y: min(start.y, end.y))
            let hi = Point2(x: max(start.x, end.x), y: max(start.y, end.y))
            return [lo, .init(x: hi.x, y: lo.y), hi, .init(x: lo.x, y: hi.y)]
        case .circle:
            let r = start.distance(to: end)
            return (0..<128).map {
                let a = Double($0) * 2 * .pi / 128
                return start + Point2(x: cos(a), y: sin(a)) * r
            }
        }
    }

    var snapPoints: [Point2] {
        switch kind {
        case .line: [start, end]
        case .circle: [start]
        case .rectangle: outline
        case .arc: [start, end] + (arcCenter.map { [$0] } ?? [])
        case .curve: isClosed ? [] : [start, end]
        case .slot: [start, end]
        case .point: [start]
        case .ellipse:
            // Its center and the four ends of its axes.
            ellipseProfile.map { e in [start] + [0, .pi / 2, .pi, 3 * .pi / 2].map { e.point($0) } } ?? [start]
        }
    }

    /// A slot's outline, counterclockwise: the round end about `end`, the left side back, the round
    /// end about `start`, and the right side (closing the outline), with the ends as exact arcs.
    var slotOutline: (points: [Point2], arcs: [ProfileArc]) {
        let d = end - start, length = d.length, radius = (width ?? 0) / 2
        guard length > 1e-12 else { return ([start, end], []) }
        let heading = atan2(d.y, d.x), count = 60
        var points: [Point2] = []
        // Each round end, both ends included: the straight sides join them.
        func cap(_ center: Point2, from angle: Double) {
            for i in 0...count {
                let a = angle + .pi * Double(i) / Double(count)
                points.append(center + Point2(x: cos(a), y: sin(a)) * radius)
            }
        }
        cap(end, from: heading - .pi / 2)
        cap(start, from: heading + .pi / 2)
        let arcs = [ProfileArc(start: 0, segments: count, center: end, radius: radius),
                    ProfileArc(start: count + 1, segments: count, center: start, radius: radius)]
        return (points, arcs)
    }
}

extension SketchProfile {
    /// A closed, simple, non-degenerate outline (with a sane analytic circle) that can be extruded.
    var isSolidProfile: Bool {
        guard plane.isValid, outline.count >= 3, outline.allSatisfy(\.isValid) else { return false }
        if let circle {
            // Circles are checked in linear time (this runs on every drag event of a live preview):
            // points on the circle, strictly in order around it, going around exactly once.
            guard circle.center.isValid, circle.radius.isFinite, circle.radius >= 0.01, circle.radius <= 100_000 else { return false }
            let tolerance = max(1e-6, circle.radius * 1e-9)
            var sweep = 0.0, direction = 0.0
            var previous = atan2(outline[outline.count - 1].y - circle.center.y, outline[outline.count - 1].x - circle.center.x)
            for point in outline {
                guard abs(point.distance(to: circle.center) - circle.radius) <= tolerance else { return false }
                let angle = atan2(point.y - circle.center.y, point.x - circle.center.x)
                var step = angle - previous
                if step <= -.pi { step += 2 * .pi } else if step > .pi { step -= 2 * .pi }
                // Every step turns the same way, so the outline never doubles back on itself.
                guard abs(step) > 1e-12, direction == 0 || (step > 0) == (direction > 0) else { return false }
                direction = step
                sweep += step
                previous = angle
            }
            return abs(abs(sweep) - 2 * .pi) < 1e-6 && area > 0.00001 && holesAreValid
        }
        if let ellipse {
            guard ellipse.isValid, arcs == nil, outline.allSatisfy({ ellipse.residual($0) < 1e-6 }) else { return false }
        }
        return Self.arcsAreValid(arcs, on: outline) && Geometry.isSimplePolygon(outline) && holesAreValid && area > 0.00001
    }

    /// Every hole is a valid loop strictly inside the outline, clear of the outline and the other holes.
    private var holesAreValid: Bool {
        guard let holes else { return true }
        guard !holes.isEmpty, holes.count <= 256 else { return false }
        // Bounded work: the checks below are quadratic in the number of points.
        let loops = [outline] + holes.map(\.outline)
        guard loops.reduce(0, { $0 + $1.count }) <= 20_000 else { return false }
        for hole in holes {
            guard hole.outline.count >= 3, hole.outline.allSatisfy(\.isValid), Geometry.isSimplePolygon(hole.outline),
                  Self.arcsAreValid(hole.arcs, on: hole.outline) else { return false }
            if let circle = hole.circle {
                let tolerance = max(1e-6, circle.radius * 1e-9)
                guard circle.radius >= 0.01, hole.outline.allSatisfy({ abs($0.distance(to: circle.center) - circle.radius) <= tolerance }) else { return false }
            }
            if let ellipse = hole.ellipse {
                guard ellipse.isValid, hole.circle == nil, hole.arcs == nil, hole.outline.allSatisfy({ ellipse.residual($0) < 1e-6 }) else { return false }
            }
        }
        // Loops never cross or touch: check every pair of segments between loops.
        for (i, hole) in loops.enumerated().dropFirst() {
            guard hole.allSatisfy({ Geometry.contains($0, in: outline) && Geometry.distanceToOutline($0, outline) > 1e-6 }) else { return false }
            for other in loops[(i + 1)...] where Geometry.contains(other[0], in: hole) || Geometry.contains(hole[0], in: other) { return false }
        }
        for i in loops.indices { for j in loops.indices where j > i && Geometry.loopsCross(loops[i], loops[j]) { return false } }
        return true
    }

    /// Each arc covers its own run of outline points, every one of them on its circle.
    private static func arcsAreValid(_ arcs: [ProfileArc]?, on outline: [Point2]) -> Bool {
        guard let arcs else { return true }
        let n = outline.count
        guard arcs.count <= n / 2 else { return false }
        var covered = Set<Int>()
        for arc in arcs {
            guard (0..<n).contains(arc.start), arc.segments >= 2, arc.segments < n, arc.center.isValid,
                  arc.radius.isFinite, arc.radius >= 0.01, arc.radius <= 100_000 else { return false }
            let tolerance = max(1e-6, arc.radius * 1e-9)
            for step in 0...arc.segments {
                let index = (arc.start + step) % n
                guard abs(outline[index].distance(to: arc.center) - arc.radius) <= tolerance else { return false }
                // Arcs may share an end point, never a segment.
                if step > 0, !covered.insert(index).inserted { return false }
            }
        }
        return true
    }
}

struct CircleProfile: Codable, Equatable, Sendable {
    var center: Point2
    var radius: Double
}

/// A circular arc along a polygon profile's outline (schema 10): the outline points `start`,
/// `start + 1`, … `start + segments` (wrapping around) lie on it. The kernel builds an exact arc
/// there, so the extruded side is one smooth face instead of facets.
struct ProfileArc: Codable, Equatable, Sendable {
    var start: Int
    var segments: Int
    var center: Point2
    var radius: Double
}

/// An exact ellipse (October 21, 2026): its center, its radius along its own axis (turned `angle`
/// radians from the sketch's x axis), and its radius across.
struct EllipseProfile: Codable, Equatable, Sendable {
    var center: Point2
    var radiusX: Double
    var radiusY: Double
    var angle: Double
    /// The point at parameter `t` (radians) round the ellipse, counterclockwise.
    func point(_ t: Double) -> Point2 {
        let x = radiusX * cos(t), y = radiusY * sin(t), c = cos(angle), s = sin(angle)
        return center + Point2(x: x * c - y * s, y: x * s + y * c)
    }
    /// Points round it, counterclockwise from the end of its own axis.
    func outline(_ count: Int = 128) -> [Point2] { (0..<count).map { point(Double($0) * 2 * .pi / Double(count)) } }
    /// How far `p` is from lying on it, in units of the ellipse (0 on it).
    func residual(_ p: Point2) -> Double {
        let d = p - center, c = cos(angle), s = sin(angle)
        let x = (d.x * c + d.y * s) / radiusX, y = (-d.x * s + d.y * c) / radiusY
        return abs((x * x + y * y).squareRoot() - 1)
    }
    var isValid: Bool {
        center.isValid && angle.isFinite && radiusX.isFinite && radiusY.isFinite && min(radiusX, radiusY) >= 0.005 && max(radiusX, radiusY) <= 100_000
    }
}

/// A hole in a sketch region (schema 16): a closed loop inside its outline, counterclockwise, with
/// its own exact circle, ellipse, or arcs.
struct ProfileHole: Codable, Equatable, Sendable {
    var outline: [Point2]
    var circle: CircleProfile?
    var arcs: [ProfileArc]?
    var ellipse: EllipseProfile?
    var area: Double { abs(Geometry.signedArea(outline)) }
}

struct SketchProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var plane: SketchPlane
    var sourceIDs: [UUID]
    var outline: [Point2]
    var circle: CircleProfile?
    /// Exact arcs along the outline, from projected arcs. Omitted when there are none.
    var arcs: [ProfileArc]?
    /// Closed loops inside the outline that are not part of the region (schema 16). Omitted when none.
    var holes: [ProfileHole]?
    /// The outline is this exact ellipse (its points lie on it). Omitted otherwise.
    var ellipse: EllipseProfile?
    /// The outline or a hole is an exact ellipse.
    var usesEllipses: Bool { ellipse != nil || (holes ?? []).contains { $0.ellipse != nil } }
    /// The region's own area: the outline less its holes.
    var area: Double { abs(Geometry.signedArea(outline)) - (holes ?? []).reduce(0) { $0 + $1.area } }
    var center: Point2 {
        if let circle, holes == nil { return circle.center }
        func centroid(_ points: [Point2]) -> (area: Double, center: Point2) {
            let a = Geometry.signedArea(points)
            guard abs(a) > 1e-8 else { return (0, points.first ?? .zero) }
            var c = Point2.zero
            for i in points.indices {
                let p = points[i], q = points[(i + 1) % points.count]
                c = c + (p + q) * Geometry.cross(p, q)
            }
            return (abs(a), c * (1 / (6 * a)))
        }
        let outer = centroid(outline)
        guard let holes, !holes.isEmpty else { return outer.area > 0 ? outer.center : outline.first ?? .zero }
        var weighted = outer.center * outer.area, total = outer.area
        for hole in holes {
            let h = centroid(hole.outline)
            weighted = weighted - h.center * h.area
            total -= h.area
        }
        return total > 1e-8 ? weighted * (1 / total) : outer.center
    }

    /// A point on the region itself, for its extrude arrow: the center, unless that falls in a hole
    /// (a ring's center is its hole), then the middle of the widest span across the region there.
    var anchor: Point2 {
        let middle = center
        guard let holes, !holes.isEmpty, !contains(middle) else { return middle }
        var crossings: [Double] = []
        for loop in [outline] + holes.map(\.outline) {
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                if (a.y > middle.y) != (b.y > middle.y) { crossings.append(a.x + (middle.y - a.y) * (b.x - a.x) / (b.y - a.y)) }
            }
        }
        crossings.sort()
        // Inside and outside alternate along the line: spans run from each even crossing to the next.
        let spans = stride(from: 0, to: crossings.count - 1, by: 2).map { (crossings[$0], crossings[$0 + 1]) }
        guard let widest = spans.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) else { return middle }
        return Point2(x: (widest.0 + widest.1) / 2, y: middle.y)
    }

    /// Whether a point is in the region: inside the outline (or on it) and not inside a hole.
    func contains(_ point: Point2) -> Bool {
        guard Geometry.contains(point, in: outline) else { return false }
        return !(holes ?? []).contains { Geometry.contains(point, in: $0.outline) && Geometry.distanceToOutline(point, $0.outline) > 1e-6 }
    }
}

extension SolidBody {
}

struct SolidBody: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var profile: SketchProfile
    var depth: Double
    /// Fillets and chamfers, replayed in order on the extruded solid. See EdgeFinishes.swift.
    var finishes: [EdgeFinish] = []
    /// Extruded profiles subtracted after the finishes. See Cuts.swift.
    var cuts: [ExtrusionCut] = []
    /// Hidden from the canvas (schema 8). Omitted when visible.
    var hidden: Bool?
    /// Revolved about an axis instead of extruded (schema 14; see Revolve.swift). `depth` is then
    /// unused. Omitted for extrusions.
    var revolve: RevolveSpec?
    /// Built from an imported shape instead (schema 15; see Import.swift). `profile` and `depth`
    /// are then placeholders, and the profile's plane is where the shape sits. Omitted otherwise.
    var imported: ImportedBase?
    /// Extruded the same distance both ways from the sketch plane, `depth` in all (October 21,
    /// 2026). Omitted otherwise.
    var symmetric: Bool?
    /// The sides lean in by this many degrees toward the far end (negative: out). Omitted when 0.
    var taper: Double?
    /// The name chosen in the Model Tree, and the color given (Naming.swift). Omitted when unset.
    var name: String?
    var color: BodyColor?
    /// The Model Tree group it sits in (Groups.swift). Omitted at the top of the tree.
    var group: UUID?
    /// A separate peg's pin: what it stands on, for editing it with its sockets (FeatureEditing.swift).
    /// Omitted otherwise.
    var peg: PegPin?
    /// Where the extrusion starts along the normal: the sketch plane, or half the depth back.
    var baseOffset: Double { symmetric == true ? -depth / 2 : 0 }
    /// Straight sides, starting on the sketch plane: the extrusion whose faces and edges have names.
    var hasPlainSides: Bool { (taper ?? 0) == 0 }
    var isValid: Bool {
        guard ItemNames.isValid(name), color != .gray,
              peg.map({ Fit.clearanceRange.contains($0.clearance) && PegSpec.embedRange.contains($0.embed) }) ?? true else { return false }
        if symmetric != nil || taper != nil {
            guard imported == nil, revolve == nil, symmetric != false, ExtrusionCut.taperRange.contains(taper ?? 0) else { return false }
        }
        if let imported {
            return revolve == nil && profile.plane.isValid && ImportedShapes.shared.contains(imported.shape) && finishesAreValid && cutsAreValid
        }
        let baseIsValid = revolve.map { $0.allows(profile) && depth.isFinite } ?? (depth.isFinite && abs(depth) >= 0.01 && abs(depth) <= 10_000)
        return baseIsValid && profile.isSolidProfile && finishesAreValid && cutsAreValid
    }

    init(id: UUID = UUID(), profile: SketchProfile, depth: Double, finishes: [EdgeFinish] = [], cuts: [ExtrusionCut] = []) {
        self.id = id; self.profile = profile; self.depth = depth; self.finishes = finishes; self.cuts = cuts
    }

    private enum CodingKeys: String, CodingKey { case id, profile, depth, finishes, cuts, hidden, revolve, imported, symmetric, taper, name, color, group, peg }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profile = try container.decode(SketchProfile.self, forKey: .profile)
        depth = try container.decode(Double.self, forKey: .depth)
        finishes = try container.decodeIfPresent([EdgeFinish].self, forKey: .finishes) ?? []
        cuts = try container.decodeIfPresent([ExtrusionCut].self, forKey: .cuts) ?? []
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        revolve = try container.decodeIfPresent(RevolveSpec.self, forKey: .revolve)
        imported = try container.decodeIfPresent(ImportedBase.self, forKey: .imported)
        symmetric = try container.decodeIfPresent(Bool.self, forKey: .symmetric)
        taper = try container.decodeIfPresent(Double.self, forKey: .taper)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        color = try container.decodeIfPresent(BodyColor.self, forKey: .color)
        group = try container.decodeIfPresent(UUID.self, forKey: .group)
        peg = try container.decodeIfPresent(PegPin.self, forKey: .peg)
    }
    /// Bodies without finishes or cuts encode exactly as schema version 1 did.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profile, forKey: .profile)
        try container.encode(depth, forKey: .depth)
        if !finishes.isEmpty { try container.encode(finishes, forKey: .finishes) }
        if !cuts.isEmpty { try container.encode(cuts, forKey: .cuts) }
        if hidden == true { try container.encode(true, forKey: .hidden) }
        if let revolve { try container.encode(revolve, forKey: .revolve) }
        if let imported { try container.encode(imported, forKey: .imported) }
        if symmetric == true { try container.encode(true, forKey: .symmetric) }
        if let taper, taper != 0 { try container.encode(taper, forKey: .taper) }
        if let name { try container.encode(name, forKey: .name) }
        if let color { try container.encode(color, forKey: .color) }
        if let group { try container.encode(group, forKey: .group) }
        if let peg { try container.encode(peg, forKey: .peg) }
    }
}

enum Geometry {
    static func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
    static func dot(_ a: Point2, _ b: Point2) -> Double { a.x * b.x + a.y * b.y }

    /// The center of the circle through three points, or nil when they are (nearly) in a line.
    static func circumcenter(_ a: Point2, _ b: Point2, _ c: Point2) -> Point2? {
        let d = 2 * cross(b - a, c - a)
        let scale = max(1, (b - a).length * (c - a).length)
        guard abs(d) > 1e-9 * scale else { return nil }
        let ab = b - a, ac = c - a
        let ab2 = dot(ab, ab), ac2 = dot(ac, ac)
        return a + Point2(x: (ac.y * ab2 - ab.y * ac2) / d, y: (ab.x * ac2 - ac.x * ab2) / d)
    }

    /// Distance from a point to a closed outline.
    static func distanceToOutline(_ p: Point2, _ outline: [Point2]) -> Double {
        outline.indices.reduce(.infinity) { min($0, distance(p, toSegment: outline[$1], outline[($1 + 1) % outline.count])) }
    }

    /// Whether two closed outlines cross or touch.
    static func loopsCross(_ a: [Point2], _ b: [Point2]) -> Bool {
        func bounds(_ points: [Point2]) -> (Point2, Point2) {
            (Point2(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0), Point2(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0))
        }
        let (alo, ahi) = bounds(a), (blo, bhi) = bounds(b)
        guard alo.x <= bhi.x + 1e-7, blo.x <= ahi.x + 1e-7, alo.y <= bhi.y + 1e-7, blo.y <= ahi.y + 1e-7 else { return false }
        for i in a.indices {
            let p = a[i], q = a[(i + 1) % a.count]
            for j in b.indices {
                let r = b[j], t = b[(j + 1) % b.count]
                if segmentsTouch(p, q, r, t) { return true }
            }
        }
        return false
    }

    /// Whether segments ab and cd cross or touch.
    static func segmentsTouch(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> Bool {
        let abC = cross(b - a, c - a), abD = cross(b - a, d - a), cdA = cross(d - c, a - c), cdB = cross(d - c, b - c)
        if abC * abD < -1e-12 && cdA * cdB < -1e-12 { return true }
        return distance(c, toSegment: a, b) < 1e-7 || distance(d, toSegment: a, b) < 1e-7 ||
            distance(a, toSegment: c, d) < 1e-7 || distance(b, toSegment: c, d) < 1e-7
    }

    static func signedArea(_ points: [Point2]) -> Double {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(0) { $0 + cross(points[$1], points[($1 + 1) % points.count]) } / 2
    }

    static func distance(_ p: Point2, toSegment a: Point2, _ b: Point2) -> Double {
        let d = b - a
        let l2 = d.x * d.x + d.y * d.y
        guard l2 > 1e-12 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2))
        return p.distance(to: a + d * t)
    }

    static func contains(_ point: Point2, in polygon: [Point2]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if distance(point, toSegment: a, b) < 1e-6 { return true }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }

    static func isSimplePolygon(_ points: [Point2]) -> Bool {
        let n = points.count
        guard n >= 3, abs(signedArea(points)) > 1e-8 else { return false }
        for i in points.indices where points[i].distance(to: points[(i + 1) % n]) < 1e-7 { return false }
        /// Whether segments i and j (i < j, not neighbors) cross or touch.
        func meet(_ i: Int, _ j: Int) -> Bool {
            let a = points[i], b = points[(i + 1) % n], c = points[j], d = points[(j + 1) % n]
            let abC = cross(b - a, c - a), abD = cross(b - a, d - a)
            let cdA = cross(d - c, a - c), cdB = cross(d - c, b - c)
            if abC * abD < -1e-12 && cdA * cdB < -1e-12 { return true }
            return distance(c, toSegment: a, b) < 1e-7 || distance(d, toSegment: a, b) < 1e-7 ||
                distance(a, toSegment: c, d) < 1e-7 || distance(b, toSegment: c, d) < 1e-7
        }
        func neighbors(_ i: Int, _ j: Int) -> Bool { j == i + 1 || (i == 0 && j == n - 1) }
        guard n > 64 else {
            for i in 0..<n { for j in (i + 1)..<n where !neighbors(i, j) && meet(i, j) { return false } }
            return true
        }
        // Long outlines (projected curves, up to thousands of points): only segments whose boxes
        // share a cell of a grid of about n cells can meet, so test just those pairs.
        let xs = points.map(\.x), ys = points.map(\.y)
        let low = Point2(x: xs.min() ?? 0, y: ys.min() ?? 0)
        let side = Int(Double(n).squareRoot())
        let cell = max(xs.max()! - low.x, ys.max()! - low.y, 1e-9) / Double(side)
        func index(_ value: Double) -> Int { Int(max(0, min(Double(side), (value / cell).rounded(.down)))) }
        var cells: [Int: [Int]] = [:]
        for i in 0..<n {
            let a = points[i], b = points[(i + 1) % n], pad = 1e-6
            for x in index(min(a.x, b.x) - pad - low.x)...index(max(a.x, b.x) + pad - low.x) {
                for y in index(min(a.y, b.y) - pad - low.y)...index(max(a.y, b.y) + pad - low.y) { cells[x * (side + 1) + y, default: []].append(i) }
            }
        }
        var tested = Set<Int>()
        for members in cells.values where members.count > 1 {
            for p in members.indices { for q in members.indices where q > p {
                let i = min(members[p], members[q]), j = max(members[p], members[q])
                guard !neighbors(i, j), tested.insert(i * n + j).inserted else { continue }
                if meet(i, j) { return false }
            } }
        }
        return true
    }

}

struct SnapResult: Equatable, Sendable {
    var point: Point2
    var label: String
    /// Points the result is aligned with horizontally or vertically (drawn as dashed guides).
    var alignedTo: [Point2] = []
}

enum SketchSnap {
    static func snap(_ point: Point2, start: Point2? = nil, shapes: [SketchShape],
                     plane: SketchPlane, grid: Double, tolerance: Double, align: Bool = true,
                     excluding: [Point2] = [], guides: [SketchGuide] = [], origin: Point2? = .zero) -> SnapResult {
        // Sketch endpoints and solid guide points (corners, midpoints, centers) compete by distance.
        let endpoints = shapes.filter { $0.plane == plane }.flatMap(\.snapPoints).map { SnapResult(point: $0, label: "Endpoint") } +
            guides.map { SnapResult(point: $0.point, label: $0.kind.label) }
        let candidates = endpoints.filter { candidate in !excluding.contains { $0.distance(to: candidate.point) < 1e-5 } }
        if let nearest = candidates.min(by: { $0.point.distance(to: point) < $1.point.distance(to: point) }),
           nearest.point.distance(to: point) <= tolerance { return nearest }
        // The world origin, where the plane passes through it.
        if let origin, point.distance(to: origin) <= tolerance { return .init(point: origin, label: "Origin") }
        var p = Point2(x: (point.x / grid).rounded() * grid, y: (point.y / grid).rounded() * grid)
        var label = "Grid"
        // Alignment: line up vertically and/or horizontally with a guide point (or the stroke's
        // own start for lines). Two alignments lock to their crossing, e.g. a face's center.
        let sources = guides.map(\.point) + (align ? start.map { [$0] } ?? [] : [])
        // Equally aligned sources (e.g. a center and a midpoint above it) resolve to the nearer one.
        func closer(_ offset: @escaping (Point2) -> Double) -> (Point2, Point2) -> Bool {
            { a, b in abs(offset(a) - offset(b)) > 1e-9 ? offset(a) < offset(b) : a.distance(to: point) < b.distance(to: point) }
        }
        let vertical = sources.filter { abs(point.x - $0.x) <= tolerance }.min(by: closer { abs(point.x - $0.x) })
        let horizontal = sources.filter { abs(point.y - $0.y) <= tolerance && $0 != vertical }.min(by: closer { abs(point.y - $0.y) })
        var aligned: [Point2] = []
        if let vertical { p.x = vertical.x; aligned.append(vertical); label = "Vertical" }
        if let horizontal { p.y = horizontal.y; aligned.append(horizontal); label = vertical == nil ? "Horizontal" : "Aligned" }
        return .init(point: p, label: label, alignedTo: aligned)
    }
}

enum ShapeDimension: String, CaseIterable, Sendable {
    case length, width, height, diameter, radius
    var title: String { rawValue.capitalized }
    func value(of shape: SketchShape) -> Double {
        switch (self, shape.kind) {
        case (.width, .slot): shape.width ?? 0
        case (.width, .ellipse): 2 * shape.start.distance(to: shape.end)
        case (.height, .ellipse): shape.width ?? 0
        case (.length, _): shape.start.distance(to: shape.end)
        case (.width, _): abs(shape.end.x - shape.start.x)
        case (.height, _): abs(shape.end.y - shape.start.y)
        case (.diameter, _): shape.start.distance(to: shape.end) * 2
        case (.radius, _): shape.arcCenter.map { shape.start.distance(to: $0) } ?? 0
        }
    }
    /// The dimensions shown beside a shape, in order.
    static func of(_ kind: ShapeKind) -> [ShapeDimension] {
        switch kind {
        case .line: [.length]
        case .rectangle: [.width, .height]
        case .circle: [.diameter]
        case .arc: [.radius]
        case .slot: [.length, .width]
        case .ellipse: [.width, .height]
        case .point, .curve: []
        }
    }
}

enum SketchHandle: Hashable, Sendable {
    /// `mid` is an arc's middle point; `side` on a slot is its edge (the width).
    case start, end, corner(Int), side(Int), center, radius, mid
}

enum SketchEditing {
    static func dimension(_ dimension: ShapeDimension, value: Double, of shape: SketchShape) -> SketchShape? {
        guard value.isFinite, value >= 0.01, value <= 10_000 else { return nil }
        var result = shape
        switch (shape.kind, dimension) {
        case (.line, .length), (.slot, .length): result.end = shape.start + (shape.end - shape.start) * (value / (shape.end - shape.start).length)
        case (.slot, .width): result.width = value
        case (.ellipse, .width):
            let axis = shape.end - shape.start
            guard axis.length > 1e-12 else { return nil }
            result.end = shape.start + axis * (value / 2 / axis.length)
        case (.ellipse, .height): result.width = value
        case (.circle, .diameter): result.end = shape.start + (shape.end - shape.start) * (value / (2 * (shape.end - shape.start).length))
        case (.arc, .radius):
            // The ends stay; the center moves along the chord's perpendicular, on the same side.
            guard let center = shape.arcCenter else { return nil }
            let chord = shape.end - shape.start, half = chord.length / 2
            // Exactly half the chord is a half circle (its current radius, if it is one).
            guard value >= half - 1e-9 else { return nil }
            let left = Point2(x: -chord.y, y: chord.x) * (1 / chord.length), middle = (shape.start + shape.end) * 0.5
            let side: Double = Geometry.dot(center - middle, left) >= 0 ? 1 : -1
            let offset = max(0, value * value - half * half).squareRoot()
            result = SketchShape.arc(center: middle + left * (offset * side), from: shape.start, to: shape.end, plane: shape.plane)
            result.id = shape.id; result.sketch = shape.sketch
        case (.rectangle, .width) where shape.isCentered:
            let half = (shape.end.x >= shape.start.x ? value : -value) / 2
            result.start.x = shape.center.x - half; result.end.x = shape.center.x + half
        case (.rectangle, .height) where shape.isCentered:
            let half = (shape.end.y >= shape.start.y ? value : -value) / 2
            result.start.y = shape.center.y - half; result.end.y = shape.center.y + half
        case (.rectangle, .width): result.end.x = shape.start.x + (shape.end.x >= shape.start.x ? value : -value)
        case (.rectangle, .height): result.end.y = shape.start.y + (shape.end.y >= shape.start.y ? value : -value)
        default: return nil
        }
        return result.isValid ? result : nil
    }

    static func handlePoint(_ handle: SketchHandle, on shape: SketchShape) -> Point2 {
        switch handle {
        case .center where shape.kind == .rectangle: return shape.center
        case .mid: return shape.arcMiddle
        case .side where shape.kind == .slot || shape.kind == .ellipse:
            let d = shape.end - shape.start, length = max(1e-12, d.length)
            return shape.center + Point2(x: -d.y, y: d.x) * ((shape.width ?? 0) / 2 / length)
        case .start, .center: return shape.start
        case .end, .radius: return shape.end
        case .corner(let index): return shape.outline[index % 4]
        case .side(let index):
            let points = shape.outline
            return (points[index % 4] + points[(index + 1) % 4]) * 0.5
        }
    }

    static func dragging(_ shape: SketchShape, handle: SketchHandle, to point: Point2) -> SketchShape? {
        guard point.isValid else { return nil }
        var result = shape
        switch (shape.kind, handle) {
        case (.line, .start), (.slot, .start): result.start = point
        case (.line, .end), (.slot, .end): result.end = point
        case (.ellipse, .center), (.point, .center), (.point, .start):
            let delta = point - shape.start
            result.start = point; result.end = shape.end + delta
        case (.ellipse, .end): result.end = point
        case (.slot, .side), (.ellipse, .side):
            // Twice the distance from the center line is the width.
            let d = shape.end - shape.start, length = d.length
            guard length > 1e-12 else { return nil }
            result.width = 2 * abs(Geometry.cross(d, point - shape.start)) / length
        case (.arc, .start), (.arc, .end), (.arc, .mid):
            // The arc keeps passing through its other two handles.
            var start = shape.start, end = shape.end, middle = shape.arcMiddle
            switch handle { case .start: start = point; case .end: end = point; default: middle = point }
            guard var arc = SketchShape.arc(from: start, through: middle, to: end, plane: shape.plane) else { return nil }
            // A 3-point arc runs counterclockwise; keep the dragged end where it was dragged.
            arc.id = shape.id; arc.sketch = shape.sketch
            result = arc
        case (.circle, .center): result.start = point; result.end = shape.end + (point - shape.start)
        case (.circle, .radius): result.end = point
        case (.rectangle, .center):
            let delta = point - shape.center
            result.start = shape.start + delta; result.end = shape.end + delta
        case (.rectangle, .corner) where shape.isCentered, (.rectangle, .side) where shape.isCentered:
            // Centered rectangles resize symmetrically about their center.
            let c = shape.center
            let sx: Double = shape.end.x >= shape.start.x ? 1 : -1, sy: Double = shape.end.y >= shape.start.y ? 1 : -1
            var hx = abs(shape.end.x - c.x), hy = abs(shape.end.y - c.y)
            let movesX: Bool, movesY: Bool
            if case .side(let index) = handle { movesX = !index.isMultiple(of: 2); movesY = index.isMultiple(of: 2) } else { movesX = true; movesY = true }
            if movesX { hx = abs(point.x - c.x) }
            if movesY { hy = abs(point.y - c.y) }
            result.start = Point2(x: c.x - hx * sx, y: c.y - hy * sy)
            result.end = Point2(x: c.x + hx * sx, y: c.y + hy * sy)
        case (.rectangle, .corner(let index)):
            let old = shape.outline[index % 4]
            if old.x == shape.start.x { result.start.x = point.x } else { result.end.x = point.x }
            if old.y == shape.start.y { result.start.y = point.y } else { result.end.y = point.y }
        case (.rectangle, .side(let index)):
            let old = handlePoint(handle, on: shape)
            if index.isMultiple(of: 2) {
                if old.y == shape.start.y { result.start.y = point.y } else { result.end.y = point.y }
            } else {
                if old.x == shape.start.x { result.start.x = point.x } else { result.end.x = point.x }
            }
        default: return nil
        }
        return result.isValid ? result : nil
    }

    /// The points where a shape joins others (line and arc ends, rectangle corners), in order.
    static func joints(of shape: SketchShape) -> [Point2] {
        switch shape.kind {
        case .line, .arc: [shape.start, shape.end]
        case .curve: shape.isClosed ? [] : [shape.start, shape.end]
        case .rectangle: shape.outline
        case .circle, .slot, .ellipse, .point: []
        }
    }

    /// An arc with its ends moved (each by its own move, if it has one), keeping its sweep: it turns
    /// and scales with them, as a joined line stretches.
    static func movingEnds(of arc: SketchShape, _ moves: [(Point2, Point2)]) -> SketchShape? {
        var start = arc.start, end = arc.end
        for (old, new) in moves where old != new {
            if arc.start.distance(to: old) < 1e-5 { start = new }
            if arc.end.distance(to: old) < 1e-5 { end = new }
        }
        guard start != arc.start || end != arc.end else { return arc }
        guard var moved = SketchShape.arc(from: start, to: end, sweep: arc.arcSweep, plane: arc.plane) else { return nil }
        moved.id = arc.id; moved.sketch = arc.sketch
        return moved
    }

    /// Propagate moved vertices to joined line and arc ends, using the pre-edit document for every preview.
    static func replacing(_ shape: SketchShape, in workspace: Workspace) -> Workspace? {
        guard let index = workspace.shapes.firstIndex(where: { $0.id == shape.id }), shape.isValid else { return nil }
        let original = workspace.shapes[index]
        var shape = shape
        shape.sketch = original.sketch
        let before = joints(of: original)
        var after = joints(of: shape)
        if original.kind == .arc, after.count == 2 {
            // A redrawn arc runs counterclockwise, so its ends may have traded places: pair each old end
            // with the nearer new one.
            if before[0].distance(to: after[1]) + before[1].distance(to: after[0]) < before[0].distance(to: after[0]) + before[1].distance(to: after[1]) {
                after.swapAt(0, 1)
            }
        }
        if original.kind == .rectangle, shape.kind == .rectangle {
            // Outlines list corners from the lower left, so a rectangle dragged inside out lists them in
            // another order. Follow each side instead: a side that stayed put keeps its corners, and the
            // other side's corners go where that side went.
            func follow(_ old: [Double], _ new: [Double]) -> (Double) -> Double {
                let old = old.sorted(), new = new.sorted()
                for i in 0..<2 { for j in 0..<2 where abs(old[i] - new[j]) < 1e-9 {
                    return { abs($0 - old[i]) < 1e-9 ? new[j] : new[1 - j] }
                } }
                return { abs($0 - old[0]) < 1e-9 ? new[0] : new[1] }
            }
            let o = original.outline, n = shape.outline
            let x = follow([o[0].x, o[2].x], [n[0].x, n[2].x]), y = follow([o[0].y, o[2].y], [n[0].y, n[2].y])
            after = before.map { Point2(x: x($0.x), y: y($0.y)) }
        }
        let moves = zip(before, after).map { ($0, $1) }
        var result = workspace
        result.shapes[index] = shape
        for i in result.shapes.indices where i != index && workspace.shapes[i].plane == shape.plane && workspace.shapes[i].sketch == shape.sketch {
            switch workspace.shapes[i].kind {
            case .line:
                for (old, new) in moves where old != new {
                    if workspace.shapes[i].start.distance(to: old) < 1e-5 { result.shapes[i].start = new }
                    if workspace.shapes[i].end.distance(to: old) < 1e-5 { result.shapes[i].end = new }
                }
            case .arc:
                guard let moved = movingEnds(of: workspace.shapes[i], moves) else { return nil }
                result.shapes[i] = moved
            default: break
            }
        }
        return result.isValid ? result : nil
    }
}

/// How lengths are shown and typed. A preference of the app, not of a project: files always store
/// millimeters.
enum LengthUnit: String, CaseIterable, Sendable {
    case millimeters, inches
    /// Millimeters in one unit.
    var millimeters: Double { self == .inches ? 25.4 : 1 }
    var symbol: String { self == .inches ? "in" : "mm" }
    var title: String { self == .inches ? "Inches" : "Millimeters" }
    /// Decimal places shown on dimension labels.
    var fractionDigits: Int { self == .inches ? 3 : 2 }
    /// The finest step a drag snaps lengths to: 0.1 mm, or 0.01 in.
    var dragStep: Double { self == .inches ? 0.254 : 0.1 }
    /// A drag value rounded to whole `dragStep`s, in millimeters.
    func rounded(_ millimeters: Double) -> Double { (millimeters / dragStep).rounded() * dragStep }
    /// The sketch snapping grid for a canvas grid of `gridSpacing` mm: at most 1 mm, or 1/16 in.
    func snapGrid(for gridSpacing: Double) -> Double { min(gridSpacing, self == .inches ? 25.4 / 16 : 1) }
    /// Grid line spacings in millimeters, finest first: 1-2-5 decades of millimeters, or binary
    /// fractions and whole inches.
    func gridStep(atLeast ideal: Double) -> Double {
        if self == .millimeters {
            let power = pow(10, floor(log10(max(0.01, ideal))))
            return [1.0, 2, 5, 10].map { $0 * power }.first { $0 >= ideal } ?? power * 10
        }
        var step = 25.4 / 64
        while step < ideal { step *= 2 }
        return step
    }
    /// How many grid steps apart the darker lines are: every 5 mm-steps, every 4 inch-steps.
    var majorEvery: Int { self == .inches ? 4 : 5 }
}

/// Small, deterministic calculator for dimension entry. No eval, locale dependency, or arbitrary execution.
/// A number may carry a unit (mm, cm, m, in, or "); bare numbers are in `unit`, and the result is in `unit` too.
enum DimensionExpression {
    /// A comma is a decimal point ("2,5"), except where it would look like thousands ("1,000"):
    /// that is rejected rather than misread as 1.
    static func evaluate(_ text: String, unit: LengthUnit = .millimeters) -> Double? {
        guard text.count <= 128 else { return nil }
        let normalized = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").filter { !$0.isWhitespace }
        var parser = Parser(characters: Array(normalized), unit: unit.millimeters)
        guard let result = parser.expression(), parser.position == parser.characters.count, result.value.isFinite else { return nil }
        return result.value
    }

    private struct Parser {
        /// A value, and whether a unit was written for it (a length times a length is an area, not a length).
        typealias Value = (value: Double, length: Bool)
        var characters: [Character]
        /// Millimeters per bare number.
        var unit: Double
        var position = 0
        var depth = 0
        var next: Character? { position < characters.count ? characters[position] : nil }
        mutating func consume(_ c: Character) -> Bool {
            guard next == c else { return false }; position += 1; return true
        }
        mutating func expression() -> Value? {
            guard var value = term() else { return nil }
            while let op = next, op == "+" || op == "-" {
                position += 1
                guard let rhs = term() else { return nil }
                value = (op == "+" ? value.value + rhs.value : value.value - rhs.value, value.length || rhs.length)
            }
            return value
        }
        mutating func term() -> Value? {
            guard var value = factor() else { return nil }
            while let op = next, op == "*" || op == "/" {
                position += 1
                guard let rhs = factor(), op != "/" || rhs.value != 0 else { return nil }
                if op == "*" {
                    guard !(value.length && rhs.length) else { return nil }
                    value = (value.value * rhs.value, value.length || rhs.length)
                } else {
                    // A length over a length is a plain ratio; a number over a length means nothing here.
                    guard value.length || !rhs.length else { return nil }
                    value = (value.value / rhs.value, value.length && !rhs.length)
                }
            }
            return value
        }
        mutating func factor() -> Value? {
            guard depth < 32 else { return nil }
            depth += 1
            defer { depth -= 1 }
            if consume("+") { return factor() }
            if consume("-") { return factor().map { (-$0.value, $0.length) } }
            var value: Value
            if consume("(") {
                guard let nested = expression(), consume(")") else { return nil }
                value = nested
            } else {
                let start = position
                while let c = next, c.isNumber || c == "." || c == "," { position += 1 }
                guard start != position, let number = Double(Self.plainNumber(String(characters[start..<position])) ?? "") else { return nil }
                value = (number, false)
            }
            // A unit converts the number to millimeters, then to the bare-number unit.
            var millimeters: Double?
            if consume("c") { guard consume("m") else { return nil }; millimeters = 10 }
            else if consume("m") { millimeters = consume("m") ? 1 : 1000 }
            else if consume("i") { guard consume("n") else { return nil }; millimeters = 25.4 }
            else if consume("\"") || consume("″") { millimeters = 25.4 }
            if let millimeters { value = (value.value * millimeters / unit, true) }
            return value.value.isFinite ? value : nil
        }

        /// The number with its decimal comma as a point; nil for "1,000", which could mean a thousand.
        static func plainNumber(_ text: String) -> String? {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return parts.count == 1 ? text : nil }
            guard !(parts[1].count == 3 && parts[1].allSatisfy(\.isNumber)) else { return nil }
            return parts.joined(separator: ".")
        }
    }
}
