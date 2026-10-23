import Foundation
import simd

extension SketchPlane {
    /// World XY through the origin, normal +Z.
    static let top = SketchPlane(origin: .zero, xAxis: .init(1, 0, 0), yAxis: .init(0, 1, 0))
    /// World XZ through the origin, normal −Y.
    static let front = SketchPlane(origin: .zero, xAxis: .init(1, 0, 0), yAxis: .init(0, 0, 1))
    /// World YZ through the origin, normal +X.
    static let right = SketchPlane(origin: .zero, xAxis: .init(0, 1, 0), yAxis: .init(0, 0, 1))
    /// The three world planes chosen with the view cube.
    static let allCases: [SketchPlane] = [.top, .front, .right]

    /// Double-precision normal (the canvas has a Float `normal` for rendering).
    var normalAxis: SIMD3<Double> { simd_cross(xAxis, yAxis) }
    var isWorldPlane: Bool { Self.allCases.contains(self) }
    var worldName: String? {
        switch self { case .top: "top"; case .front: "front"; case .right: "right"; default: nil }
    }
    var title: String { worldName?.capitalized ?? "Face" }

    /// Double-precision placement (the canvas's Float `world` / `local` are for rendering only).
    func point(_ point: Point2, height: Double = 0) -> SIMD3<Double> {
        origin + xAxis * point.x + yAxis * point.y + normalAxis * height
    }
    func coordinates(of point: SIMD3<Double>) -> Point2 {
        let d = point - origin
        return Point2(x: simd_dot(d, xAxis), y: simd_dot(d, yAxis))
    }
    func height(of point: SIMD3<Double>) -> Double { simd_dot(point - origin, normalAxis) }

    /// The canonical sketch plane through `point` with outward `normal`. Coplanar faces share one
    /// plane: the origin is the plane point nearest the world origin, and the axes follow world up
    /// (or world Y for horizontal planes), so a face lying on a world plane *is* that world plane.
    static func through(_ point: SIMD3<Double>, normal: SIMD3<Double>) -> SketchPlane? {
        guard simd_length(normal) > 1e-9, point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        let n = simd_normalize(normal)
        let reference: SIMD3<Double> = abs(n.z) < 0.9 ? .init(0, 0, 1) : .init(0, 1, 0)
        let y = simd_normalize(reference - n * simd_dot(reference, n))
        let x = simd_cross(y, n)
        return SketchPlane(origin: (n * simd_dot(point, n)).roundedOff(), xAxis: x.roundedOff(1e12), yAxis: y.roundedOff(1e12))
    }

    /// Orthonormal, finite, and within the document's coordinate limits.
    var isValid: Bool {
        [origin, xAxis, yAxis].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } &&
        simd_length(origin) <= 100_000 && abs(simd_length(xAxis) - 1) < 1e-9 && abs(simd_length(yAxis) - 1) < 1e-9 &&
        abs(simd_dot(xAxis, yAxis)) < 1e-9
    }
}

/// World planes encode as their names ("top", "front", "right"), exactly as in schema 1–3.
/// Face planes encode as `{"origin": [x, y, z], "xAxis": [...], "yAxis": [...]}` (schema 4).
extension SketchPlane: Codable {
    private enum CodingKeys: String, CodingKey { case origin, xAxis, yAxis }

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard let plane = Self.allCases.first(where: { $0.worldName == name }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown sketch plane \(name)"))
            }
            self = plane
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(origin: try container.decode(SIMD3<Double>.self, forKey: .origin),
                  xAxis: try container.decode(SIMD3<Double>.self, forKey: .xAxis),
                  yAxis: try container.decode(SIMD3<Double>.self, forKey: .yAxis))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid sketch plane frame"))
        }
    }

    func encode(to encoder: Encoder) throws {
        if let worldName {
            var container = encoder.singleValueContainer()
            try container.encode(worldName)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(origin, forKey: .origin)
            try container.encode(xAxis, forKey: .xAxis)
            try container.encode(yAxis, forKey: .yAxis)
        }
    }
}

extension Workspace {
    /// Every plane that sketches, solids, or cuts use, world planes first.
    var planes: [SketchPlane] {
        var result = SketchPlane.allCases
        for plane in shapes.map(\.plane) + bodies.flatMap({ [$0.profile.plane] + $0.cuts.map(\.profile.plane) }) where !result.contains(plane) {
            result.append(plane)
        }
        return result
    }
}
