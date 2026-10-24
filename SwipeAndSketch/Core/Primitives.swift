import Foundation
import simd

// Primitives (October 24, 2026): a box, cylinder, sphere, or torus made in one step, for people who
// start from shapes rather than sketches. Each is an ordinary solid with nothing new in the file: a
// box and a cylinder are extrusions, a sphere and a torus revolves, standing on the plane they are
// placed on and centered on the point picked there.

enum PrimitiveKind: String, CaseIterable, Sendable {
    case box, cylinder, sphere, torus

    var title: String { rawValue.capitalized }

    /// The sizes it takes, in order: their names and starting values (mm).
    var sizes: [(name: String, value: Double)] {
        switch self {
        case .box: [("Width", 20), ("Length", 20), ("Height", 20)]
        case .cylinder: [("Diameter", 20), ("Height", 20)]
        case .sphere: [("Diameter", 20)]
        case .torus: [("Diameter", 30), ("Tube", 8)]
        }
    }
}

enum Primitives {
    static let sizeRange = 0.1...10_000.0

    /// The `kind` solid with `sizes` (see `PrimitiveKind.sizes`), standing on `plane` and centered
    /// on `center`. A torus's diameter runs through the middle of its tube, which must be thinner
    /// than the diameter. Nil for sizes out of range.
    static func body(_ kind: PrimitiveKind, sizes: [Double], on plane: SketchPlane, at center: Point2) -> SolidBody? {
        guard sizes.count == kind.sizes.count, sizes.allSatisfy(sizeRange.contains) else { return nil }
        switch kind {
        case .box:
            let half = Point2(x: sizes[0] / 2, y: sizes[1] / 2)
            let shape = SketchShape(kind: .rectangle, plane: plane, start: center - half, end: center + half)
            return Geometry.profiles(in: [shape], on: plane).first.map { SolidBody(profile: $0, depth: sizes[2]) }
        case .cylinder:
            let shape = SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: sizes[0] / 2, y: 0))
            return Geometry.profiles(in: [shape], on: plane).first.map { SolidBody(profile: $0, depth: sizes[1]) }
        case .sphere, .torus:
            // Revolved about the plane's normal through the center, from a plane standing up across it.
            let side = SketchPlane(origin: plane.point(center), xAxis: plane.yAxis, yAxis: plane.normalAxis)
            let shapes: [SketchShape]
            if kind == .sphere {
                let r = sizes[0] / 2
                shapes = [SketchShape(kind: .arc, plane: side, start: .zero, end: Point2(x: 0, y: 2 * r), arcCenter: Point2(x: 0, y: r)),
                          SketchShape(kind: .line, plane: side, start: Point2(x: 0, y: 2 * r), end: .zero)]
            } else {
                let ring = sizes[0] / 2, tube = sizes[1] / 2
                guard tube < ring - 1e-6 else { return nil }
                shapes = [SketchShape(kind: .circle, plane: side, start: Point2(x: ring, y: tube), end: Point2(x: ring + tube, y: tube))]
            }
            guard let profile = Geometry.profiles(in: shapes, on: side).first else { return nil }
            let body = SolidBody(profile: profile, revolve: .oriented(from: .zero, to: Point2(x: 0, y: 1), angle: 360, for: profile))
            return body.isValid ? body : nil
        }
    }
}
