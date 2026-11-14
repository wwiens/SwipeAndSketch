import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Face extrusion: a solid's flat face pushed out (join) or in (cut), starting at 0 mm.
@MainActor final class FaceExtrusionToolTests: CanvasTestCase {


    func testTopFaceStartsAtZeroAndDragsOutIntoAJoin() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        XCTAssertTrue(session.canExtrudeSelectedFace)
        session.beginFaceExtrusion()
        controller.refresh()
        XCTAssertTrue(session.isExtruding)
        XCTAssertEqual(session.extrusionDepth, 0, "Face extrusion starts on the face, not 20 mm out")
        XCTAssertFalse(session.canConfirmExtrusion, "Nothing to apply at 0 mm")
        // The value is the size the box ends up (20 mm tall), not the distance moved.
        XCTAssertEqual(session.dimensionValue(.extrusion), 20)
        XCTAssertEqual(session.dimensionTitle(.extrusion), "Size")
        XCTAssertEqual(session.displayWorkspace, session.workspace, "No preview change at 0 mm")
        let handle = try XCTUnwrap(controller.extrusionHandle())
        XCTAssertLessThan(handle.axis.dy, -0.9, "The top face extrudes upward on screen")
        XCTAssertEqual(controller.dimensionAnnotations().count, 1)
        XCTAssertEqual(controller.dimensionAnnotations().first?.value, 20)

        // Drag the double-arrow outward (up on screen).
        controller.pencilBegan(at: handle.center)
        controller.pencilMoved(to: CGPoint(x: handle.center.x, y: handle.center.y - 60))
        controller.pencilEnded(at: CGPoint(x: handle.center.x, y: handle.center.y - 60), cancelled: false)
        controller.refresh()
        XCTAssertGreaterThan(session.extrusionDepth, 1)
        XCTAssertEqual(session.extrusionMode, .join)
        XCTAssertTrue(session.canConfirmExtrusion)
        XCTAssertTrue(session.applyDimension(25, target: .extrusion))
        XCTAssertEqual(session.extrusionDepth, 5, accuracy: 1e-9, "Typing 25 mm pulls the top out 5 mm")
        XCTAssertEqual(controller.dimensionAnnotations().first?.value ?? 0, 25, accuracy: 1e-9)
        XCTAssertFalse(session.applyDimension(-3, target: .extrusion), "A size cannot be negative")
        XCTAssertEqual(try SolidKernel.solid(for: session.displayWorkspace.bodies[0]).volume, 60 * 40 * 25, accuracy: 1e-3, "Live preview")
        controller.refresh()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.sceneView.snapshot().draw(in: controller.view.bounds)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Top face pulled out 5 mm"
        attachment.lifetime = .keepAlways
        add(attachment)

        session.confirmExtrusion()
        XCTAssertFalse(session.isExtruding)
        XCTAssertNil(session.faceExtrusion)
        XCTAssertEqual(session.workspace.bodies.count, 1)
        let solid = try SolidKernel.solid(for: session.workspace.bodies[0])
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 60 * 40 * 25, accuracy: 1e-3)
        XCTAssertEqual(solid.faceCount, 6, "Still a plain box, just taller")
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id))
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].cuts, [], "One undo step")
    }

    func testNegativeDepthCutsIntoTheSolid() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        session.beginFaceExtrusion()
        XCTAssertTrue(session.applyDimension(12, target: .extrusion))
        XCTAssertEqual(session.extrusionDepth, -8, accuracy: 1e-9, "A smaller size pushes the face in")
        XCTAssertEqual(session.extrusionMode, .cut)
        XCTAssertEqual(session.cutTargets, [session.workspace.bodies[0].id])
        XCTAssertTrue(session.canConfirmExtrusion)
        controller.refresh()
        session.confirmExtrusion()
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, 60 * 40 * 12, accuracy: 1e-3)
    }

    func testCancelLeavesTheSolidUntouched() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        let before = session.workspace
        session.beginFaceExtrusion()
        XCTAssertTrue(session.applyDimension(30, target: .extrusion))
        session.cancelExtrusion()
        XCTAssertFalse(session.isExtruding)
        XCTAssertNil(session.faceExtrusion)
        XCTAssertEqual(session.workspace, before)
        XCTAssertEqual(session.displayWorkspace, before)
    }

    func testExtrudeToolTapsAFaceToExtrudeIt() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.extrude)
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertTrue(session.isExtruding, "With no sketch under the Pencil, the Extrude tool extrudes the face")
        XCTAssertNotNil(session.faceExtrusion)
        XCTAssertEqual(session.extrusionDepth, 0)
        // Choosing Extrude with a face already selected does the same.
        session.cancelExtrusion()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        session.chooseTool(.extrude)
        XCTAssertNotNil(session.faceExtrusion)
    }

    func testSketchExtrusionAlsoStartsOnItsPlane() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0)))
        session.beginExtrusion()
        XCTAssertNil(session.faceExtrusion)
        XCTAssertEqual(session.extrusionDepth, 0)
        XCTAssertEqual(session.extrusionMode, .newBody)
        XCTAssertNil(session.extrusionSizeBase, "A sketch extrusion shows its depth")
        XCTAssertEqual(session.dimensionTitle(.extrusion), "Distance")
        XCTAssertFalse(session.canConfirmExtrusion, "Nothing to make at 0 mm")
        XCTAssertTrue(session.applyDimension(12, target: .extrusion))
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.first?.depth, 12)
    }
}
