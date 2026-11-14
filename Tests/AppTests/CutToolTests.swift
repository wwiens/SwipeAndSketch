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
        XCTAssertEqual(session.extrusionDepth, 0)
        XCTAssertTrue(session.canConfirmExtrusion, "Through All needs no depth: Done is available")
        attach(controller, "Through-all hole preview")

        session.confirmExtrusion()
        controller.refresh()
        XCTAssertFalse(session.isExtruding)
        XCTAssertEqual(session.workspace.bodies.count, 1, "A cut makes no new solid")
        XCTAssertEqual(session.workspace.bodies[0].cuts.count, 1)
        XCTAssertEqual(try volume(session), 48_000 - .pi * 25 * 20, accuracy: 1e-3)
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id))
        let node = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).faceCount, 7, "Six box faces plus the hole's wall")
        XCTAssertEqual(node.geometry?.elements.count, 1, "The canvas draws a solid in one draw call")
        attach(controller, "Box with through hole")

        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].cuts, [])
        session.redo()
        XCTAssertEqual(session.workspace.bodies[0].cuts.count, 1)
    }

    /// On screen the Extrude preview builds off the main thread (November 9, 2026): a depth shows its
    /// cut once built, the newest depth wins, and Done keeps what the final depth makes even when the
    /// background has not caught up. Cancelling drops a result still on its way.
    func testTheExtrudePreviewBuildsInTheBackgroundAndDoneKeepsTheLatestDepth() async throws {
        let (session, controller) = boxScene()
        session.buildsPreviewsInBackground = true
        // A pocket up from the bottom face.
        addCircle(session)
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        await session.cutPreviewSettled()
        session.extrusionDepth = 5
        XCTAssertTrue(session.cutTargets.isEmpty, "Not built yet: the depth does not wait for the kernel")
        await session.cutPreviewSettled()
        XCTAssertEqual(session.cutTargets, [session.workspace.bodies[0].id], "Built in the background")
        let five = try XCTUnwrap(session.operationPreview?.bodies.first)
        XCTAssertEqual(try SolidKernel.solid(for: five).volume, 48_000 - .pi * 25 * 5, accuracy: 1e-3)

        // Quick changes: only the newest waits, and the last one shown is the last depth.
        for depth in stride(from: 6.0, through: 12, by: 1) { session.extrusionDepth = depth }
        await session.cutPreviewSettled()
        let twelve = try XCTUnwrap(session.operationPreview?.bodies.first)
        XCTAssertEqual(try SolidKernel.solid(for: twelve).volume, 48_000 - .pi * 25 * 12, accuracy: 1e-3)

        // Done straight after a change keeps the depth just set, not the preview still building.
        session.extrusionDepth = 8
        session.confirmExtrusion()
        XCTAssertFalse(session.isExtruding)
        XCTAssertEqual(try volume(session), 48_000 - .pi * 25 * 8, accuracy: 1e-3)
        await session.cutPreviewSettled()
        XCTAssertEqual(try volume(session), 48_000 - .pi * 25 * 8, accuracy: 1e-3, "A late result changes nothing")

        // Cancelling drops a preview on its way.
        addCircle(session, at: Point2(x: 20, y: 0))
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        session.extrusionDepth = 3
        session.cancelExtrusion()
        await session.cutPreviewSettled()
        XCTAssertNil(session.operationPreview)
        XCTAssertTrue(session.cutTargets.isEmpty)
        withExtendedLifetime(controller) {}
    }

    /// Fillet and Shell previews build off the main thread on screen too; a typed value is checked
    /// at once, and Done keeps the value just set (November 9, 2026).
    func testFilletAndShellPreviewsBuildInTheBackground() async throws {
        let (session, controller) = boxScene()
        session.buildsPreviewsInBackground = true
        let bodyID = session.workspace.bodies[0].id
        session.chooseTool(.fillet)
        for edge in session.workspace.bodies[0].extrusionEdges where edge.position == .side {
            session.toggleFinishEdge(bodyID: bodyID, edge: try XCTUnwrap(PickedEdge.named(edge, on: session.workspace.bodies[0])))
        }
        session.setFinishSize(3)
        await session.finishPreviewSettled()
        func rounded(_ r: Double) -> Double { 48_000 - 4 * (r * r - .pi * r * r / 4) * 20 }
        let three = try XCTUnwrap(session.finishPreview?.bodies.first)
        XCTAssertEqual(try SolidKernel.solid(for: three).volume, rounded(3), accuracy: 1e-3)
        XCTAssertFalse(session.applyDimension(50, target: .finishSize(.fillet)), "A typed size that cannot fit is refused at once")
        XCTAssertEqual(session.finishDraft?.size, 3)
        XCTAssertNil(session.finishError)
        session.setFinishSize(4)
        session.confirmFinish()
        XCTAssertEqual(try volume(session), rounded(4), accuracy: 1e-3, "Done keeps the size just set")

        // Shell: leave the top open.
        session.chooseTool(.shell)
        let solid = try SolidKernel.solid(for: session.workspace.bodies[0])
        let top = try XCTUnwrap(solid.face(containing: SIMD3(0, 0, 20), normal: SIMD3(0, 0, 1)))
        session.toggleShellFace(bodyID: bodyID, face: top, at: SIMD3(0, 0, 20))
        session.setShellThickness(2)
        await session.shellPreviewSettled()
        XCTAssertNotNil(session.shellPreview, "Built in the background")
        XCTAssertNil(session.draftError)
        XCTAssertFalse(session.applyDimension(30, target: .shellThickness), "A typed wall that cannot fit is refused at once")
        XCTAssertEqual(session.shellDraft?.thickness, 2)
        session.setShellThickness(3)
        let before = try volume(session)
        session.confirmShell()
        XCTAssertLessThan(try volume(session), before, "Kept with the wall just set")
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.shell?.thickness, 3)
        await session.shellPreviewSettled()
        withExtendedLifetime(controller) {}
    }

    func testACutAcrossTheBoxLeavesTwoSolidsInOneUndoStep() throws {
        let (session, _) = boxScene()
        let box = session.workspace.bodies[0].id
        session.choosePlane(.top)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 8, y: -25), end: .init(x: 12, y: 25)))
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        session.cutThroughAll = true
        XCTAssertTrue(session.canConfirmExtrusion)
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
        let image = renderer.image { context in
            controller.sceneView.snapshot().draw(in: controller.view.bounds)
            // Render the overlay in place: drawHierarchy would move it into a window and back,
            // and leaving a window cancels the stroke in progress.
            controller.input.redrawOverlayNow()
            controller.input.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
