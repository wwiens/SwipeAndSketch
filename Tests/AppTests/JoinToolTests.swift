import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Join: bosses extruded from a face merge into the solid they touch.
@MainActor final class JoinToolTests: CanvasTestCase {

    /// Sketch a 10 × 10 square centered on the box's top face, ready to extrude.
    func squareOnTopFace(_ session: ModelingSession, _ controller: CanvasController) throws {
        let point = controller.project(SIMD3(5, 3, 20))
        controller.pencilBegan(at: point); controller.pencilEnded(at: point, cancelled: false); controller.refresh()
        XCTAssertNotNil(session.selectedFace)
        session.beginFaceSketch()
        session.chooseTool(.rectangle)
        session.rectangleFromCenter = true
        controller.refresh()
        controller.pencilBegan(at: controller.project(SIMD3(0.2, 0.1, 20)))
        controller.pencilMoved(to: controller.project(SIMD3(5.1, 4.9, 20)))
        controller.pencilEnded(at: controller.project(SIMD3(5.1, 4.9, 20)), cancelled: false)
        controller.refresh()
        let square = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(ShapeDimension.width.value(of: square), 10, accuracy: 1e-9)
    }

    func testBossDraggedOutOfAFaceJoinsTheSolid() throws {
        let (session, controller) = boxScene()
        try squareOnTopFace(session, controller)
        session.beginExtrusion()
        XCTAssertTrue(session.applyDimension(6, target: .extrusion))
        XCTAssertEqual(session.extrusionMode, .join, "Out of a face, touching the solid: Join")
        XCTAssertEqual(session.joinTarget, session.workspace.bodies[0].id)
        XCTAssertTrue(session.canConfirmExtrusion)
        XCTAssertEqual(session.displayWorkspace.bodies[0].cuts.last?.operation, .join, "The merged solid previews live")
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 1, "The boss is part of the box, not a second solid")
        let solid = try SolidKernel.solid(for: session.workspace.bodies[0])
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 48_000 + 10 * 10 * 6, accuracy: 1e-3)
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id))
        session.requestCamera(.reset)
        controller.refresh()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.sceneView.snapshot().draw(in: controller.view.bounds)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Boss joined to the box"
        attachment.lifetime = .keepAlways
        add(attachment)
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].cuts, [])
    }

    func testGridReturnsToTheFloorWhenTheFaceSketchEnds() throws {
        let (session, controller) = boxScene()
        try squareOnTopFace(session, controller)
        // While sketching on the top face, the grid is drawn on that face.
        XCTAssertEqual(controller.gridNode.childNodes.first?.simdWorldPosition.z ?? 0, 20, accuracy: 0.5)
        session.beginExtrusion()
        XCTAssertTrue(session.applyDimension(6, target: .extrusion))
        session.confirmExtrusion()
        controller.refresh()
        XCTAssertEqual(session.plane, .top, "Leaving the face sketch returns to the world plane in use before")
        XCTAssertEqual(controller.gridNode.childNodes.first?.simdWorldPosition.z ?? -1, 0, accuracy: 1e-4, "The grid is back on the floor, under the box")
        let bounds = try SolidKernel.solid(for: session.workspace.bodies[0]).bounds
        XCTAssertEqual(bounds.min.z, 0, accuracy: 1e-9, "The box itself never moved")
        XCTAssertEqual(bounds.max.z, 26, accuracy: 1e-9)

        // Exit Sketching does the same; a world plane chosen with the cube is remembered.
        session.chooseCubeFace(.front)
        controller.refresh()
        // In Front view the top face is edge-on (a tap there picks its border); use the front face.
        let point = controller.project(SIMD3(0, -20, 10))
        session.chooseTool(.select)
        controller.pencilBegan(at: point); controller.pencilEnded(at: point, cancelled: false)
        session.beginFaceSketch()
        XCTAssertFalse(session.plane.isWorldPlane)
        session.exitSketch()
        XCTAssertEqual(session.plane, .front)
    }

    func testDraggingTheSameSketchIntoTheSolidCutsAndAwayJoins() throws {
        let (session, controller) = boxScene()
        try squareOnTopFace(session, controller)
        session.beginExtrusion()
        XCTAssertTrue(session.applyDimension(-5, target: .extrusion))
        XCTAssertEqual(session.extrusionMode, .cut)
        XCTAssertTrue(session.applyDimension(5, target: .extrusion))
        XCTAssertEqual(session.extrusionMode, .join)
    }

    func testNewBodyStaysSeparateWhenChosenAndJoinNeedsContact() throws {
        let (session, controller) = boxScene()
        try squareOnTopFace(session, controller)
        session.beginExtrusion()
        session.chooseExtrusionMode(.newBody)
        XCTAssertTrue(session.applyDimension(6, target: .extrusion))
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 2, "New Body keeps a separate solid even when touching")

        // A sketch in free space cannot join anything.
        session.choosePlane(.top)
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 80, y: 0), end: .init(x: 85, y: 0)))
        session.beginExtrusion()
        XCTAssertEqual(session.extrusionMode, .newBody)
        session.chooseExtrusionMode(.join)
        XCTAssertNil(session.joinTarget)
        XCTAssertFalse(session.canConfirmExtrusion)
        session.confirmExtrusion()
        XCTAssertTrue(session.isExtruding, "Done does nothing while the boss touches no solid")
        XCTAssertEqual(session.workspace.bodies.count, 2)
    }
}
