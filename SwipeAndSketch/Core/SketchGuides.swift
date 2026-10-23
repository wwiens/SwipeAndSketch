import Foundation
import simd

/// A snap anchor shown as a purple dot while sketching: a solid's corner, edge midpoint, or center,
/// the face's center, or a point where another sketch or a solid edge crosses the sketch plane.
struct SketchGuide: Equatable, Sendable {
    enum Kind: String, Sendable {
        case corner, midpoint, center, faceCenter, intersection
        /// The names shown for these snap points.
        var label: String {
            switch self {
            case .corner: "Endpoint"
            case .midpoint: "Edge midpoint"
            case .center: "Center"
            case .faceCenter: "Face center"
            case .intersection: "Intersection"
            }
        }
    }
    var point: Point2
    var kind: Kind
}

enum SketchGuides {
    /// Guide points on `plane`, in sketch coordinates. Every solid edge lying in the plane
    /// contributes its ends (corners), its midpoint, and, for circles and arcs, its center.
    /// The face being sketched on also contributes its area center. Solid edges and the lines and
    /// circles of `shapes` on other planes contribute the points where they cross the plane.
    /// Nothing here is saved.
    static func guides(on plane: SketchPlane, bodies: [SolidBody], face: (bodyID: UUID, face: Int)? = nil,
                       shapes: [SketchShape] = []) -> [SketchGuide] {
        var result: [SketchGuide] = []
        func add(_ point: SIMD3<Double>, _ kind: SketchGuide.Kind) {
            guard abs(plane.height(of: point)) < 1e-5 else { return }
            // Round off kernel noise (e.g. a centroid at 1e-16 mm) so snapped points are exact.
            let local = plane.coordinates(of: point).roundedOff()
            guard local.isValid, !result.contains(where: { $0.point.distance(to: local) < 1e-6 }) else { return }
            result.append(SketchGuide(point: local, kind: kind))
        }
        // Crossings come last, so a point that is also a corner or center keeps that name.
        var crossings: [SIMD3<Double>] = []
        for body in bodies {
            guard let solid = try? SolidKernel.solid(for: body) else { continue }
            if let face, face.bodyID == body.id, let center = solid.faceCenter(face.face) { add(center, .faceCenter) }
            let lettering = body.textZones
            for edge in 0..<solid.edgeCount {
                let samples = solid.edgeSamples(edge, count: 3)
                guard samples.count == 3 else { continue }
                // Lettering would cover the face in dots.
                if lettering.contains(where: { zone in samples.allSatisfy(zone.contains) }) { continue }
                guard samples.allSatisfy({ abs(plane.height(of: $0)) < 1e-5 }) else {
                    crossings += Self.crossings(of: solid, edge: edge, ends: samples, plane: plane)
                    continue
                }
                let closed = simd_distance(samples[0], samples[2]) < 1e-6
                if let circle = solid.edgeCircle(edge) { add(circle.center, .center) }
                // A closed edge (a full circle) starts at an arbitrary seam point: no corner or midpoint.
                guard !closed else { continue }
                add(samples[0], .corner)
                add(samples[2], .corner)
                add(samples[1], .midpoint)
            }
        }
        for shape in shapes where shape.plane != plane && shape.isValid {
            switch shape.kind {
            case .point:
                // A point of another sketch lying on this plane.
                let p = shape.plane.point(shape.start)
                if abs(plane.height(of: p)) < 1e-6 { crossings.append(p) }
            case .line, .rectangle, .arc, .curve, .slot, .ellipse:
                // Arcs and curves cross along their outline points.
                let points = shape.outline.map { shape.plane.point($0) }
                let count = shape.isClosed ? points.count : points.count - 1
                for i in 0..<count {
                    segmentCrossing(points[i], points[(i + 1) % points.count], plane: plane).map { crossings.append($0) }
                }
            case .circle:
                let center = shape.plane.point(shape.start), radius = shape.start.distance(to: shape.end)
                crossings += circleCrossings(center: center, radius: radius, u: shape.plane.xAxis, v: shape.plane.yAxis, plane: plane)
            }
        }
        crossings.forEach { add($0, .intersection) }
        // Corners first so a shared point reads as a corner rather than a midpoint.
        return result.sorted { order($0.kind) < order($1.kind) }
    }

    /// Straight solid edges lying in `plane`, in sketch coordinates: lines the Dimension tool can
    /// measure from.
    static func lines(on plane: SketchPlane, bodies: [SolidBody]) -> [(Point2, Point2)] {
        var result: [(Point2, Point2)] = []
        for body in bodies {
            guard let solid = try? SolidKernel.solid(for: body) else { continue }
            for edge in 0..<solid.edgeCount {
                let samples = solid.edgeSamples(edge, count: 3)
                guard samples.count == 3, samples.allSatisfy({ abs(plane.height(of: $0)) < 1e-5 }) else { continue }
                let chord = samples[2] - samples[0]
                guard simd_length(chord) > 1e-6, simd_length(simd_cross(samples[1] - samples[0], chord)) / simd_length(chord) < 1e-7 else { continue }
                result.append((plane.coordinates(of: samples[0]), plane.coordinates(of: samples[2])))
            }
        }
        return result
    }

    /// Where a straight segment meets the plane (an end lying on it counts).
    static func segmentCrossing(_ a: SIMD3<Double>, _ b: SIMD3<Double>, plane: SketchPlane) -> SIMD3<Double>? {
        let ha = plane.height(of: a), hb = plane.height(of: b)
        if abs(ha) < 1e-9 { return a }
        if abs(hb) < 1e-9 { return b }
        guard (ha < 0) != (hb < 0) else { return nil }
        return a + (b - a) * (ha / (ha - hb))
    }

    /// Where a circle (center, radius, in the plane spanned by unit axes u and v) meets the plane.
    static func circleCrossings(center: SIMD3<Double>, radius: Double, u: SIMD3<Double>, v: SIMD3<Double>,
                                plane: SketchPlane) -> [SIMD3<Double>] {
        // height(θ) = h + r (A cos θ + B sin θ) = 0
        let h = plane.height(of: center), a = simd_dot(u, plane.normalAxis), b = simd_dot(v, plane.normalAxis)
        let amplitude = (a * a + b * b).squareRoot()
        guard amplitude > 1e-9, radius > 0 else { return [] }
        let k = -h / (radius * amplitude)
        guard abs(k) <= 1 + 1e-12 else { return [] }
        let phase = atan2(b, a), spread = acos(max(-1, min(1, k)))
        return Set([phase + spread, phase - spread].map { ($0 * 1e9).rounded() / 1e9 }).map { angle in
            center + (u * cos(angle) + v * sin(angle)) * radius
        }
    }

    /// Where a solid edge that does not lie in the plane crosses it: exact for straight edges and
    /// circles or arcs; other curves are skipped rather than approximated.
    private static func crossings(of solid: KernelSolid, edge: Int, ends: [SIMD3<Double>], plane: SketchPlane) -> [SIMD3<Double>] {
        let start = ends[0], middle = ends[1], end = ends[2]
        let chord = end - start
        let straight = simd_length(chord) > 1e-9 &&
            simd_length(simd_cross(middle - start, chord)) / simd_length(chord) < 1e-9
        if straight { return segmentCrossing(start, end, plane: plane).map { [$0] } ?? [] }
        guard let circle = solid.edgeCircle(edge) else { return [] }
        let r1 = start - circle.center, r2 = middle - circle.center
        var normal = simd_cross(r1, r2)
        if simd_length(normal) < 1e-12 { normal = simd_cross(r1, end - circle.center) }
        guard simd_length(normal) > 1e-12, simd_length(r1) > 1e-12 else { return [] }
        let u = simd_normalize(r1), v = simd_normalize(simd_cross(simd_normalize(normal), u))
        let candidates = circleCrossings(center: circle.center, radius: circle.radius, u: u, v: v, plane: plane)
        // Keep points on the arc itself: near the edge's own (dense) samples.
        let samples = solid.edgeSamples(edge, count: 129)
        let tolerance = circle.radius * (1 - cos(.pi / 128)) * 2 + 1e-6 + circle.radius * .pi / 128
        return candidates.filter { point in samples.contains { simd_distance($0, point) <= tolerance } }
    }

    private static func order(_ kind: SketchGuide.Kind) -> Int {
        switch kind { case .corner: 0; case .faceCenter, .center: 1; case .intersection: 2; case .midpoint: 3 }
    }
}

/// The space a text entry's letters take: their outline's bounds on its plane, from the face to
/// the letters' depth (raised or sunk).
struct TextZone {
    var plane: SketchPlane
    var low: Point2, high: Point2
    var bottom: Double, top: Double

    func contains(_ point: SIMD3<Double>) -> Bool {
        let p = plane.coordinates(of: point), h = plane.height(of: point), margin = 0.05
        return p.x >= low.x - margin && p.x <= high.x + margin && p.y >= low.y - margin && p.y <= high.y + margin &&
            h >= bottom - margin && h <= top + margin
    }
}

extension SolidBody {
    var textZones: [TextZone] {
        cuts.compactMap { cut in
            guard let text = cut.text else { return nil }
            let points = text.loops.flatMap { [$0.start] + $0.segments.flatMap(\.points) }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
            return TextZone(plane: cut.profile.plane, low: Point2(x: minX, y: minY), high: Point2(x: maxX, y: maxY),
                            bottom: min(0, cut.depth), top: max(0, cut.depth))
        }
    }
}
