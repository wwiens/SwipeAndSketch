import Foundation
import XCTest
@testable import SwipeAndSketchCore

extension XCTestCase {
    /// A rectangle extruded from the top plane (or a plane `height` above it): 60 × 40 × 20 mm by default.
    func box(_ x0: Double = -30, _ y0: Double = -20, _ x1: Double = 30, _ y1: Double = 20, depth: Double = 20, at height: Double = 0) throws -> SolidBody {
        let plane = height == 0 ? SketchPlane.top : try XCTUnwrap(SketchPlane.through(.init(0, 0, height), normal: .init(0, 0, 1)))
        let shape = SketchShape(kind: .rectangle, plane: plane, start: .init(x: x0, y: y0), end: .init(x: x1, y: y1))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: plane).first), depth: depth)
    }
}
