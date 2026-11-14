import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Plane at Angle, 3-Point Plane, Tangent Plane, and Axis from Planes ▴ (October 24, 2026).
@MainActor final class ConstructionToolTests: CanvasTestCase {
    func testAPlaneAtAnAngleAboutAnEdge() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.planeAngle)
        XCTAssertEqual(session.helpTopic, .planeAngle)
        XCTAssertTrue(session.hint.contains("straight edge"), session.hint)
        // The box's top front edge, y = −20, z = 20.
        tap(controller, SIMD3(0, -20, 20))
        let preview = try XCTUnwrap(session.constructionPreview)
        XCTAssertEqual(preview.plane.height(of: [10, -20, 20]), 0, accuracy: 1e-6, "Through the edge")
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.constructionAngle])
        XCTAssertTrue(session.applyDimension(45, target: .constructionAngle))
        let tilted = try XCTUnwrap(session.constructionPreview)
        XCTAssertEqual(abs(tilted.plane.normalAxis.z), cos(.pi / 4), accuracy: 1e-6)
        attach(controller, "Plane at 45° about the top front edge")
        session.confirmConstruction()
        XCTAssertEqual(session.workspace.constructionPlanes.count, 1)
        XCTAssertEqual(session.selection, .plane(session.workspace.constructionPlanes[0].id))
        XCTAssertEqual(session.tool, .select)
        session.undo()
        XCTAssertTrue(session.workspace.constructionPlanes.isEmpty, "One undo step")
    }

    func testAPlaneThroughThreeCornersAndATangentPlane() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.plane3Point)
        for corner: SIMD3<Float> in [[30, -20, 20], [-30, -20, 20], [30, 20, 0]] { tap(controller, corner) }
        XCTAssertEqual(session.constructionDraft?.points.count, 3)
        let plane = try XCTUnwrap(session.constructionPreview)
        XCTAssertEqual(plane.plane.height(of: [30, 20, 0]), 0, accuracy: 1e-6)
        session.confirmConstruction()
        XCTAssertEqual(session.workspace.constructionPlanes.count, 1)

        session.chooseTool(.cylinder)
        tap(controller, SIMD3(-70, 0, 0))
        session.confirmPrimitive()
        session.chooseTool(.planeTangent)
        tap(controller, SIMD3(-70, -10, 10))
        let tangent = try XCTUnwrap(session.constructionPreview)
        XCTAssertEqual(abs(tangent.plane.normalAxis.z), 0, accuracy: 1e-6, "Upright, against the cylinder's side")
        XCTAssertEqual(abs(tangent.plane.height(of: [-70, 0, 10])), 10, accuracy: 1e-6, "A radius from its axis")
        session.cancelConstruction()
        XCTAssertEqual(session.workspace.constructionPlanes.count, 1)
    }

    func testAnAxisAlongACylinderIsANamedConstructionLine() throws {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session, camera: .reset)
        session.chooseTool(.cylinder)
        tap(controller, SIMD3(0, 0, 0))
        session.confirmPrimitive()
        session.chooseTool(.axis)
        XCTAssertEqual(session.helpTopic, .axis)
        tap(controller, SIMD3(0, -10, 10))
        let axis = try XCTUnwrap(session.axisPreview)
        XCTAssertEqual(simd_length(simd_cross(axis.to - axis.from, [0, 0, 1])), 0, accuracy: 1e-6, "Along the cylinder")
        XCTAssertEqual(simd_length(SIMD2(axis.from.x, axis.from.y)), 0, accuracy: 1e-6, "On its center line")
        XCTAssertNotNil(controller.previewNode.childNode(withName: "axis.preview", recursively: true))
        session.confirmConstruction()
        let sketch = try XCTUnwrap(session.selectedSketch)
        XCTAssertEqual(session.sketchName(of: sketch.id), "Axis 01")
        XCTAssertEqual(session.workspace.shapes.last?.isConstruction, true)
    }
}
