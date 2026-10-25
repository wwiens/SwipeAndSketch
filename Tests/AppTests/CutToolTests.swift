import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Holes and cuts: Extrude in Cut mode through the session, canvas, and kernel.
@MainActor final class CutToolTests: XCTestCase {
    /// A 60 × 40 × 20 box on Top (z 0…20) in the default 3D view.
    func boxScene() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.layoutIfNeeded()
        session.requestCamera(.reset)
        controller.refresh()
        return (session, controller)
    }

    func addCircle(_ session: ModelingSession, at center: Point2 = .zero, radius: Double = 5, plane: SketchPlane = .top) {
        session.choosePlane(plane)
        session.addShape(.init(kind: .circle, plane: plane, start: center, end: center + Point2(x: radius, y: 0)))
    }

    func volume(_ session: ModelingSession, _ index: Int = 0) throws -> Double {
        try SolidKernel.solid(for: session.workspace.bodies[index]).volume
    }

    func testThroughAllHolePreviewsAndCommitsOneUndoStep() throws {
        let (session, controller) = boxScene()
        addCircle(session)
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        XCTAssertEqual(session.extrusionDepth, 0)
        XCTAssertTrue(session.cutTargets.isEmpty, "Starting on the sketch plane, the cut reaches nothing yet")
        session.cutThroughAll = true
        controller.refresh()
        XCTAssertEqual(session.cutTargets, [session.workspace.bodies[0].id])
        XCTAssertNil(controller.extrusionHandle(), "Through All has no depth handle")
        XCTAssertTrue(controller.dimensionAnnotations().isEmpty)
        XCTAssertFalse(controller.previewNode.childNodes.isEmpty, "The red cut tool is shown")
        XCTAssertEqual(session.workspace.bodies[0].cuts, [], "Previews never change the document")
        attach(controller, "Through-all hole preview")

        session.confirmExtrusion()
        controller.refresh()
        XCTAssertFalse(session.isExtruding)
        XCTAssertEqual(session.workspace.bodies.count, 1, "A cut makes no new solid")
        XCTAssertEqual(session.workspace.bodies[0].cuts.count, 1)
        XCTAssertEqual(try volume(session), 48_000 - .pi * 25 * 20, accuracy: 1e-3)
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id))
        let node = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
        XCTAssertEqual(node.geometry?.elements.count, 7, "Six box faces plus the hole's wall")
        attach(controller, "Box with through hole")

        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].cuts, [])
        session.redo()
        XCTAssertEqual(session.workspace.bodies[0].cuts.count, 1)
    }

    func testACutAcrossTheBoxLeavesTwoSolidsInOneUndoStep() throws {
        let (session, _) = boxScene()
        let box = session.workspace.bodies[0].id
        session.choosePlane(.top)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 8, y: -25), end: .init(x: 12, y: 25)))
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        session.cutThroughAll = true
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 2, "Each piece is its own solid")
        XCTAssertEqual(session.workspace.bodies[0].id, box, "The larger piece keeps the solid")
        XCTAssertEqual(try volume(session, 0), 38 * 40 * 20, accuracy: 1e-6)
        XCTAssertEqual(try volume(session, 1), 18 * 40 * 20, accuracy: 1e-6)
        XCTAssertEqual(session.status, "Separated into 2 solids")
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 1)
        XCTAssertEqual(session.workspace.bodies[0].cuts, [])
        session.redo()
        XCTAssertEqual(session.workspace.bodies.count, 2)
    }

    func testPocketDepthFollowsDragAndMissingCutsCannotBeConfirmed() throws {
        let (session, controller) = boxScene()
        addCircle(session)
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        XCTAssertTrue(session.applyDimension(-6, target: .extrusion))
        XCTAssertTrue(session.cutTargets.isEmpty, "Downward from the bottom face misses the box")
        session.confirmExtrusion()
        XCTAssertTrue(session.isExtruding, "Done does nothing while the cut reaches no solid")
        XCTAssertEqual(session.workspace.bodies[0].cuts, [])

        // Drag the double-arrow up: the pocket deepens live.
        session.extrusionDepth = 4
        controller.refresh()
        let handle = try XCTUnwrap(controller.extrusionHandle())
        session.snapEnabled = false
        controller.pencilBegan(at: handle.center)
        controller.pencilMoved(to: CGPoint(x: handle.center.x, y: handle.center.y - 30))
        let depth = session.extrusionDepth
        XCTAssertGreaterThan(depth, 4)
        XCTAssertEqual(session.cutTargets.count, 1)
        controller.pencilEnded(at: CGPoint(x: handle.center.x, y: handle.center.y - 30), cancelled: false)
        session.confirmExtrusion()
        XCTAssertEqual(try volume(session), 48_000 - .pi * 25 * min(20, depth), accuracy: 1e-2)
    }

    func testOneCutReachesEverySolidItCrosses() throws {
        let (session, _) = boxScene()
        session.choosePlane(.top)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 40, y: -20), end: .init(x: 70, y: 20)))
        session.beginExtrusion(); session.extrusionDepth = 20; session.confirmExtrusion()
        // A slot on the Front plane (y = 0) crossing both boxes.
        session.choosePlane(.front)
        session.addShape(.init(kind: .rectangle, plane: .front, start: .init(x: -10, y: 8), end: .init(x: 60, y: 12)))
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        session.cutThroughAll = true
        XCTAssertEqual(session.cutTargets.count, 2)
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.map(\.cuts.count), [1, 1])
        XCTAssertEqual(try volume(session, 0), 48_000 - 40 * 4 * 40, accuracy: 1e-3)
        XCTAssertEqual(try volume(session, 1), 24_000 - 20 * 4 * 40, accuracy: 1e-3)
    }

    func testSketchesShowThroughSolidsAndExtrudePicksRegionsInsideThem() throws {
        let (session, controller) = boxScene()
        addCircle(session)
        session.chooseTool(.circle)
        controller.refresh()
        let outline = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("shape|") == true && $0.renderingOrder == 10 })
        XCTAssertEqual(outline.geometry?.firstMaterial?.readsFromDepthBuffer, false, "Active-plane sketches draw over solids while sketching")

        session.chooseTool(.select)
        session.select(nil)
        controller.refresh()
        session.chooseTool(.extrude)
        session.requestCamera(.reset)
        controller.refresh()
        // The circle sits on the box's bottom face, behind the top face in this view.
        let inside = controller.project(SketchPlane.top.world(Point2(x: 1, y: 1)))
        controller.pencilBegan(at: inside)
        controller.pencilEnded(at: inside, cancelled: false)
        XCTAssertNotNil(session.selectedShape, "Extrude picks the hidden circle, not the solid in front")
        XCTAssertTrue(session.isExtruding)
    }

    func attach(_ controller: CanvasController, _ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let image = renderer.image { _ in
            controller.sceneView.snapshot().draw(in: controller.view.bounds)
            controller.input.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
