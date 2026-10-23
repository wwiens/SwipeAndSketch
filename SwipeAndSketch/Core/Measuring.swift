import Foundation
import simd

// Measure: pick an item to read its size, or two to read the distance
// and angle between them. Nothing is saved or changed.

/// Something Measure can pick.
enum MeasureItem: Equatable, Sendable {
    /// A solid's corner, a sketch point, or the origin.
    case point(SIMD3<Double>)
    case edge(bodyID: UUID, edge: Int)
    case face(bodyID: UUID, face: Int)
    case body(UUID)
    case shape(UUID)
}

/// One measured value. Lengths are millimeters, areas mm², volumes mm³, angles degrees.
struct Measurement: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case distance, dx, dy, dz, angle, length, radius, diameter, width, height, area, volume, surfaceArea, x, y, z
        var title: String {
            switch self {
            case .distance: "Distance"
            case .dx: "ΔX"
            case .dy: "ΔY"
            case .dz: "ΔZ"
            case .angle: "Angle"
            case .length: "Length"
            case .radius: "Radius"
            case .diameter: "Diameter"
            case .width: "Width"
            case .height: "Height"
            case .area: "Area"
            case .volume: "Volume"
            case .surfaceArea: "Surface area"
            case .x: "X"
            case .y: "Y"
            case .z: "Z"
            }
        }
        /// 1 for lengths, 2 for areas, 3 for volumes, 0 for angles.
        var power: Int {
            switch self {
            case .angle: 0
            case .area, .surfaceArea: 2
            case .volume: 3
            default: 1
            }
        }
    }
    var kind: Kind
    var value: Double
}

enum Measuring {
    /// The sizes of one item.
    static func properties(of item: MeasureItem, in workspace: Workspace) -> [Measurement] {
        switch item {
        case .point(let p):
            return [Measurement(kind: .x, value: p.x), Measurement(kind: .y, value: p.y), Measurement(kind: .z, value: p.z)]
        case .edge(let id, let edge):
            guard let solid = solid(id, in: workspace) else { return [] }
            var result: [Measurement] = []
            if let length = solid.edgeLength(edge) { result.append(Measurement(kind: .length, value: length)) }
            if let circle = solid.edgeCircle(edge) {
                result += [Measurement(kind: .radius, value: circle.radius), Measurement(kind: .diameter, value: circle.radius * 2)]
            }
            return result
        case .face(let id, let face):
            guard let solid = solid(id, in: workspace) else { return [] }
            var result: [Measurement] = []
            if let area = solid.faceArea(face) { result.append(Measurement(kind: .area, value: area)) }
            if let cylinder = solid.faceCylinder(face) {
                result += [Measurement(kind: .radius, value: cylinder.radius), Measurement(kind: .diameter, value: cylinder.radius * 2)]
            }
            return result
        case .body(let id):
            guard let solid = solid(id, in: workspace) else { return [] }
            let size = solid.bounds.max - solid.bounds.min
            return [Measurement(kind: .volume, value: solid.volume), Measurement(kind: .surfaceArea, value: solid.surfaceArea),
                    Measurement(kind: .dx, value: size.x), Measurement(kind: .dy, value: size.y), Measurement(kind: .dz, value: size.z)]
        case .shape(let id):
            guard let shape = workspace.shapes.first(where: { $0.id == id }) else { return [] }
            switch shape.kind {
            case .line: return [Measurement(kind: .length, value: shape.start.distance(to: shape.end))]
            case .circle:
                let r = shape.start.distance(to: shape.end)
                return [Measurement(kind: .diameter, value: 2 * r), Measurement(kind: .length, value: 2 * .pi * r), Measurement(kind: .area, value: .pi * r * r)]
            case .arc:
                let r = shape.arcCenter.map { shape.start.distance(to: $0) } ?? 0
                return [Measurement(kind: .radius, value: r), Measurement(kind: .length, value: r * shape.arcSweep),
                        Measurement(kind: .angle, value: shape.arcSweep * 180 / .pi)]
            case .rectangle:
                let w = abs(shape.end.x - shape.start.x), h = abs(shape.end.y - shape.start.y)
                return [Measurement(kind: .width, value: w), Measurement(kind: .height, value: h), Measurement(kind: .area, value: w * h)]
            case .slot:
                let length = shape.start.distance(to: shape.end), width = shape.width ?? 0
                return [Measurement(kind: .length, value: length + width), Measurement(kind: .width, value: width),
                        Measurement(kind: .area, value: length * width + .pi * width * width / 4)]
            case .ellipse:
                let a = shape.start.distance(to: shape.end), b = (shape.width ?? 0) / 2
                // Ramanujan's perimeter, exact to well under a micron at sketch sizes.
                let h = pow(a - b, 2) / max(1e-12, pow(a + b, 2)), perimeter = .pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
                return [Measurement(kind: .width, value: 2 * a), Measurement(kind: .height, value: 2 * b), Measurement(kind: .length, value: perimeter),
                        Measurement(kind: .area, value: .pi * a * b)]
            case .point: return []
            case .curve:
                let outline = shape.outline, count = shape.isClosed ? outline.count : outline.count - 1
                let length = (0..<max(0, count)).reduce(0) { $0 + outline[$1].distance(to: outline[($1 + 1) % outline.count]) }
                return [Measurement(kind: .length, value: length)]
            }
        }
    }

    /// The distance (with its x, y, and z parts) and, where both have a direction, the angle between
    /// two items, with the nearest points on each.
    static func between(_ a: MeasureItem, _ b: MeasureItem, in workspace: Workspace) -> (values: [Measurement], from: SIMD3<Double>, to: SIMD3<Double>)? {
        guard let nearest = nearestPoints(a, b, in: workspace) else { return nil }
        let d = nearest.to - nearest.from
        var values = [Measurement(kind: .distance, value: simd_length(d))]
        if simd_length(d) > 1e-9 {
            values += [Measurement(kind: .dx, value: abs(d.x)), Measurement(kind: .dy, value: abs(d.y)), Measurement(kind: .dz, value: abs(d.z))]
        }
        if let first = direction(of: a, in: workspace), let second = direction(of: b, in: workspace) {
            let cosine = min(1, abs(simd_dot(first.vector, second.vector)))
            var angle = acos(cosine) * 180 / .pi
            // A line against a plane: the angle to the plane, not to its normal.
            if first.isNormal != second.isNormal { angle = 90 - angle }
            values.append(Measurement(kind: .angle, value: max(0, angle)))
        }
        return (values, nearest.from, nearest.to)
    }

    private static func solid(_ id: UUID, in workspace: Workspace) -> KernelSolid? {
        workspace.bodies.first { $0.id == id }.flatMap { try? SolidKernel.solid(for: $0) }
    }

    /// An item as kernel geometry to measure between: parts of a solid, or reference curves.
    private static func pieces(of item: MeasureItem, in workspace: Workspace) -> [(KernelSolid, KernelSolid.Part)] {
        switch item {
        case .point(let p): return KernelSolid.point(p).map { [($0, .whole)] } ?? []
        case .edge(let id, let edge): return solid(id, in: workspace).map { [($0, .edge(edge))] } ?? []
        case .face(let id, let face): return solid(id, in: workspace).map { [($0, .face(face))] } ?? []
        case .body(let id): return solid(id, in: workspace).map { [($0, .whole)] } ?? []
        case .shape(let id):
            guard let shape = workspace.shapes.first(where: { $0.id == id }) else { return [] }
            let plane = shape.plane, n = plane.normalAxis
            func world(_ p: Point2) -> SIMD3<Double> { plane.point(p) }
            var result: [KernelSolid?] = []
            for curve in shape.regionCurves {
                switch curve.kind {
                case .polyline(let points):
                    // Long projected curves are measured along every few points.
                    let step = max(1, points.count / 256)
                    var index = 0
                    while index < points.count - 1 {
                        let next = min(points.count - 1, index + step)
                        result.append(KernelSolid.segment(world(points[index]), world(points[next])))
                        index = next
                    }
                case .arc(let center, let radius, let from, let sweep):
                    let start = center + Point2(x: cos(from), y: sin(from)) * radius
                    result.append(KernelSolid.arc(center: world(center), normal: n, start: world(start), degrees: sweep * 180 / .pi))
                }
            }
            return result.compactMap { $0 }.map { ($0, .whole) }
        }
    }

    private static func nearestPoints(_ a: MeasureItem, _ b: MeasureItem, in workspace: Workspace) -> (from: SIMD3<Double>, to: SIMD3<Double>)? {
        var best: (distance: Double, from: SIMD3<Double>, to: SIMD3<Double>)?
        for (first, firstPart) in pieces(of: a, in: workspace) {
            for (second, secondPart) in pieces(of: b, in: workspace) {
                guard let result = first.distance(firstPart, to: second, secondPart) else { continue }
                if result.distance < best?.distance ?? .infinity { best = result }
            }
        }
        return best.map { ($0.from, $0.to) }
    }

    /// A straight item's direction, or a flat or round item's normal or axis.
    private static func direction(of item: MeasureItem, in workspace: Workspace) -> (vector: SIMD3<Double>, isNormal: Bool)? {
        switch item {
        case .point, .body: return nil
        case .edge(let id, let edge):
            guard let solid = solid(id, in: workspace) else { return nil }
            let samples = solid.edgeSamples(edge, count: 5)
            guard samples.count == 5 else { return nil }
            if solid.edgeCircle(edge) != nil {
                let c = simd_cross(samples[1] - samples[0], samples[3] - samples[0])
                return simd_length(c) > 1e-12 ? (simd_normalize(c), true) : nil
            }
            let chord = samples[4] - samples[0]
            guard simd_length(chord) > 1e-9, samples.allSatisfy({ simd_length(simd_cross($0 - samples[0], chord)) / simd_length(chord) < 1e-6 }) else { return nil }
            return (simd_normalize(chord), false)
        case .face(let id, let face):
            guard let solid = solid(id, in: workspace) else { return nil }
            if let plane = solid.facePlane(face) { return (plane.normal, true) }
            if let cylinder = solid.faceCylinder(face) { return (simd_normalize(cylinder.direction), false) }
            return nil
        case .shape(let id):
            guard let shape = workspace.shapes.first(where: { $0.id == id }) else { return nil }
            switch shape.kind {
            case .line:
                let d = shape.plane.point(shape.end) - shape.plane.point(shape.start)
                return simd_length(d) > 1e-9 ? (simd_normalize(d), false) : nil
            default:
                // A closed or round shape lies in its plane.
                return (shape.plane.normalAxis, true)
            }
        }
    }
}
