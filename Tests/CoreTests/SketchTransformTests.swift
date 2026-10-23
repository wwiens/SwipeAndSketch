import XCTest
import simd
@testable import SwipeAndSketchCore

final class SketchTransformTests: XCTestCase {
    /// A 20 × 20 square centered on the origin, on Top.
    func square() -> Workspace {
        Workspace(shapes: [SketchShape(kind: .rectangle, plane: .top, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10))])
    }

    func testMovingASketchOnlyMovesItsPlane() throws {
        let workspace = square()
        let id = workspace.sketches[0].id
        let (moved, movedID) = try XCTUnwrap(workspace.transformingSketch(id, by: .move(.init(0, 0, 30)), copy: false))
        XCTAssertEqual(movedID, id)
        XCTAssertEqual(moved.shapes.count, 1)
        XCTAssertEqual(moved.shapes[0].start, workspace.shapes[0].start, "2D geometry is unchanged")
        XCTAssertEqual(moved.sketches[0].plane.origin, .init(0, 0, 30))
        XCTAssertEqual(moved.shapes[0].plane, moved.sketches[0].plane)
        XCTAssertFalse(moved.sketches[0].plane.isWorldPlane)
        XCTAssertEqual(try XCTUnwrap(moved.center(of: moved.sketches[0])), .init(0, 0, 30))
        // Extruding the moved sketch builds a solid 30 mm up.
        let profile = try XCTUnwrap(moved.profiles.first)
        let solid = try SolidKernel.solid(for: SolidBody(profile: profile, depth: 5))
        XCTAssertEqual(solid.bounds.min.z, 30, accuracy: 1e-9)
    }

    func testCopyKeepsTheOriginalAndRotationTurnsUprightExactly() throws {
        let workspace = square()
        let id = workspace.sketches[0].id
        let (copied, copyID) = try XCTUnwrap(workspace.transformingSketch(id, by: .move(.init(0, 0, 20)), copy: true))
        XCTAssertNotEqual(copyID, id)
        XCTAssertEqual(copied.sketches.count, 2)
        XCTAssertEqual(copied.shapes.count, 2)
        XCTAssertEqual(copied.sketches[0].plane, .top, "The original stays put")
        XCTAssertNotEqual(copied.shapes[1].id, copied.shapes[0].id)
        XCTAssertEqual(copied.shapes[1].sketch, copyID)
        // Turn the copy a quarter turn about world X through its center: it stands upright,
        // parallel to Front, with no round-off left in its axes.
        let center = try XCTUnwrap(copied.center(of: try XCTUnwrap(copied.sketch(copyID))))
        let (turned, _) = try XCTUnwrap(copied.transformingSketch(copyID, by: .rotate(degrees: 90, about: .init(1, 0, 0), through: center), copy: false))
        let plane = try XCTUnwrap(turned.sketch(copyID)).plane
        XCTAssertEqual(plane.xAxis, .init(1, 0, 0))
        XCTAssertEqual(plane.yAxis, .init(0, 0, 1))
        XCTAssertEqual(plane.normalAxis, .init(0, -1, 0))
        XCTAssertEqual(plane.origin, .init(0, 0, 20))
        XCTAssertTrue(turned.isValid)
        XCTAssertEqual(try XCTUnwrap(turned.center(of: try XCTUnwrap(turned.sketch(copyID)))), center, "Turns about its own center")
        // Turning a sketch through the origin back onto Top is exactly Top again.
        let (onFront, _) = try XCTUnwrap(workspace.transformingSketch(id, by: .rotate(degrees: 90, about: .init(1, 0, 0), through: .zero), copy: false))
        XCTAssertEqual(onFront.sketches[0].plane, .front)
        let project = Project(workspace: turned)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(project)).workspace, turned)
    }
}
