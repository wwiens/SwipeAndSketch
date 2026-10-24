import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Box, Cylinder, Sphere, and Torus from Create ▴ (October 24, 2026).
@MainActor final class PrimitiveToolTests: CanvasTestCase {
    func testASphereOnTheGridIsSizedAndMade() throws {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session, camera: .reset)
        session.chooseTool(.sphere)
        XCTAssertEqual(session.tool, .sphere)
        XCTAssertEqual(session.helpTopic, .primitives)
        XCTAssertTrue(session.hint.contains("Tap the grid"), session.hint)
        tap(controller, SIMD3(20, 10, 0))
        let draft = try XCTUnwrap(session.primitiveDraft)
        XCTAssertEqual(draft.kind, .sphere)
        XCTAssertEqual(draft.sizes, [20])
        XCTAssertNotNil(session.primitivePreview)
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.primitiveSize(.sphere, 0)])
        XCTAssertEqual(controller.dimensionAnnotations().first?.text, "Ø 20 mm")
        XCTAssertTrue(session.workspace.bodies.isEmpty, "Nothing is made before Done")

        XCTAssertTrue(session.applyDimension(30, target: .primitiveSize(.sphere, 0)))
        XCTAssertFalse(session.applyDimension(0, target: .primitiveSize(.sphere, 0)))
        attach(controller, "Sphere being placed")
        session.confirmPrimitive()
        let body = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertNotNil(body.revolve)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertEqual(solid.volume, 4 / 3 * .pi * 15 * 15 * 15, accuracy: 0.05)
        XCTAssertEqual(solid.bounds.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(session.selection, .body(body.id))
        XCTAssertEqual(session.tool, .select)
        session.undo()
        XCTAssertTrue(session.workspace.bodies.isEmpty, "One undo step")
    }

    func testABoxOnAFaceStandsOnItAndATorusTubeMustFit() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.box)
        tap(controller, SIMD3(10, 5, 20))
        let draft = try XCTUnwrap(session.primitiveDraft)
        XCTAssertEqual(draft.plane.normalAxis, SIMD3(0, 0, 1))
        XCTAssertEqual(Set(controller.dimensionAnnotations().compactMap(\.text.first)), ["W", "L", "H"])
        XCTAssertTrue(session.applyDimension(5, target: .primitiveSize(.box, 2)))
        session.confirmPrimitive()
        let box = try SolidKernel.solid(for: try XCTUnwrap(session.workspace.bodies.last))
        XCTAssertEqual(box.bounds.min.z, 20, accuracy: 1e-6, "On the top face")
        XCTAssertEqual(box.bounds.max.z, 25, accuracy: 1e-6)
        XCTAssertEqual(session.workspace.bodies.count, 2, "A solid of its own")

        session.chooseTool(.torus)
        tap(controller, SIMD3(-60, 0, 0))
        XCTAssertFalse(session.applyDimension(40, target: .primitiveSize(.torus, 1)), "Thicker than the ring")
        XCTAssertNotNil(session.dimensionError)
        session.cancelPrimitive()
        XCTAssertNil(session.primitiveDraft)
        XCTAssertEqual(session.workspace.bodies.count, 2)
    }
}
