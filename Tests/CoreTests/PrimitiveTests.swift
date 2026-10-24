import XCTest
import simd
@testable import SwipeAndSketchCore

/// Box, cylinder, sphere, and torus primitives (October 24, 2026).
final class PrimitiveTests: XCTestCase {
    func solid(_ kind: PrimitiveKind, _ sizes: [Double], on plane: SketchPlane = .top, at center: Point2 = .zero) throws -> KernelSolid {
        let body = try XCTUnwrap(Primitives.body(kind, sizes: sizes, on: plane, at: center))
        XCTAssertTrue(body.isValid)
        return try SolidKernel.solid(for: body)
    }

    func testEachPrimitiveHasItsVolumeAndStandsOnThePlane() throws {
        let box = try solid(.box, [30, 20, 10], at: Point2(x: 5, y: 5))
        XCTAssertEqual(box.volume, 6000, accuracy: 1e-6)
        XCTAssertEqual(box.bounds.min, SIMD3(-10, -5, 0))
        XCTAssertEqual(box.bounds.max, SIMD3(20, 15, 10))

        let cylinder = try solid(.cylinder, [20, 15])
        XCTAssertEqual(cylinder.volume, .pi * 100 * 15, accuracy: 1e-3)

        let sphere = try solid(.sphere, [20])
        XCTAssertEqual(sphere.volume, 4 / 3 * .pi * 1000, accuracy: 1e-2)
        XCTAssertEqual(sphere.bounds.min.z, 0, accuracy: 1e-6, "It rests on the plane")
        XCTAssertEqual(sphere.bounds.max.z, 20, accuracy: 1e-6)
        XCTAssertEqual(sphere.bounds.max.x, 10, accuracy: 1e-6)
        XCTAssertTrue(sphere.isValidSolid)

        let torus = try solid(.torus, [30, 8])
        XCTAssertEqual(torus.volume, 2 * .pi * .pi * 15 * 16, accuracy: 1e-2)
        XCTAssertEqual(torus.bounds.min.z, 0, accuracy: 1e-6, "It lies flat on the plane")
        XCTAssertEqual(torus.bounds.max.z, 8, accuracy: 1e-6)
        XCTAssertEqual(torus.bounds.max.x, 19, accuracy: 1e-6)
        XCTAssertTrue(torus.isValidSolid)
    }

    func testOnAFacePlaneTheyStandOutAlongItsNormal() throws {
        let front = try XCTUnwrap(SketchPlane.through(.init(0, -10, 0), normal: .init(0, -1, 0)))
        let sphere = try solid(.sphere, [10], on: front, at: front.coordinates(of: SIMD3(3, -10, 4)))
        XCTAssertEqual(sphere.bounds.max.y, -10, accuracy: 1e-6)
        XCTAssertEqual(sphere.bounds.min.y, -20, accuracy: 1e-6)
        XCTAssertEqual(sphere.bounds.min.x, -2, accuracy: 1e-6)
    }

    func testBadSizesAreRefused() {
        XCTAssertNil(Primitives.body(.torus, sizes: [10, 12], on: .top, at: .zero), "The tube is wider than the ring")
        XCTAssertNil(Primitives.body(.box, sizes: [10, 0, 5], on: .top, at: .zero))
        XCTAssertNil(Primitives.body(.cylinder, sizes: [10], on: .top, at: .zero), "Missing a size")
    }

    func testAssistantMakesPrimitives() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        let made = try bench.primitive(kind: "sphere", sizes: [25], at: SIMD3(10, 0, 0))
        XCTAssertTrue(made.contains("sphere"), made)
        _ = try bench.primitive(kind: "torus", sizes: [40, 10], at: nil)
        XCTAssertEqual(bench.workspace.bodies.count, 2)
        XCTAssertNotNil(bench.workspace.bodies[0].revolve)
        XCTAssertThrowsError(try bench.primitive(kind: "cone", sizes: [10], at: nil))
        XCTAssertThrowsError(try bench.primitive(kind: "box", sizes: [10, 10], at: nil), "A box takes three sizes")
    }
}
