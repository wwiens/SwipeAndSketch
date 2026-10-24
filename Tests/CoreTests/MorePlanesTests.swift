import XCTest
import simd
@testable import SwipeAndSketchCore

/// Planes at an angle about a line, through three points, and tangent to a round face, and
/// construction axes (October 24, 2026).
final class MorePlanesTests: XCTestCase {
    func testAPlaneAtAnAngleTurnsAboutItsLine() throws {
        // The top front edge of a box, from (0, 0, 10) along +X; the top face's normal is +Z.
        let flat = try XCTUnwrap(ConstructionPlanes.atAngle(through: [5, 0, 10], along: [1, 0, 0], length: 10, reference: [0, 0, 1], degrees: 0))
        XCTAssertEqual(flat.plane.normalAxis.z, 1, accuracy: 1e-9)
        let upright = try XCTUnwrap(ConstructionPlanes.atAngle(through: [5, 0, 10], along: [1, 0, 0], length: 10, reference: [0, 0, 1], degrees: 90))
        XCTAssertEqual(abs(upright.plane.normalAxis.y), 1, accuracy: 1e-9)
        XCTAssertEqual(upright.plane.height(of: [0, 0, 10]), 0, accuracy: 1e-9, "Through the line")
        let tilted = try XCTUnwrap(ConstructionPlanes.atAngle(through: [5, 0, 10], along: [1, 0, 0], length: 10, reference: [0, 0, 1], degrees: 30))
        XCTAssertEqual(acos(abs(tilted.plane.normalAxis.z)) * 180 / .pi, 30, accuracy: 1e-6)
        XCTAssertNil(ConstructionPlanes.atAngle(through: .zero, along: [0, 0, 1], length: 10, reference: [0, 0, 1], degrees: 10), "A reference along the line")
    }

    func testAPlaneThroughThreePoints() throws {
        let plane = try XCTUnwrap(ConstructionPlanes.through([0, 0, 0], [10, 0, 10], [0, 10, 0]))
        for p: SIMD3<Double> in [[0, 0, 0], [10, 0, 10], [0, 10, 0]] { XCTAssertEqual(plane.plane.height(of: p), 0, accuracy: 1e-9) }
        XCTAssertGreaterThan(plane.plane.normalAxis.z, 0, "Facing up")
        XCTAssertNil(ConstructionPlanes.through([0, 0, 0], [1, 1, 1], [2, 2, 2]), "In a line")
    }

    func testATangentPlaneTouchesTheRoundFace() throws {
        // A Ø20 cylinder standing on Top; tapped on its +Y side.
        let plane = try XCTUnwrap(ConstructionPlanes.tangent(toCylinderAt: .zero, axisDirection: [0, 0, 1], radius: 10, through: [0, 10.2, 5], height: 30))
        XCTAssertEqual(plane.plane.normalAxis.y, 1, accuracy: 1e-9)
        XCTAssertEqual(plane.plane.height(of: [0, 10, 0]), 0, accuracy: 1e-9, "Touching at the radius")
    }

    func testAnAxisIsANamedSketchWithAConstructionLine() throws {
        let first = try XCTUnwrap(ConstructionAxes.adding(from: [0, 0, 0], to: [0, 0, 40], in: Workspace()))
        let second = try XCTUnwrap(ConstructionAxes.adding(from: [5, 5, 0], to: [25, 5, 0], in: first.workspace))
        let workspace = second.workspace
        XCTAssertEqual(workspace.sketches.map(\.name), ["Axis 01", "Axis 02"])
        XCTAssertEqual(workspace.shapes.map(\.isConstruction), [true, true])
        let line = workspace.shapes[0]
        XCTAssertEqual(simd_distance(line.plane.point(line.start), [0, 0, 0]), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(line.plane.point(line.end), [0, 0, 40]), 0, accuracy: 1e-9)
        XCTAssertTrue(workspace.profiles.isEmpty, "An axis bounds no region")
        XCTAssertNil(ConstructionAxes.adding(from: .zero, to: .zero, in: Workspace()))
    }
}
