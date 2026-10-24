import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Fillet and chamfer through the real Pencil pipeline, keypad path, and kernel rendering.
@MainActor final class FinishToolTests: CanvasTestCase {
    /// A 60 × 40 × 20 box on Top, viewed from the default 3D angle (camera at +X, −Y, +Z).
    func boxScene() throws -> (ModelingSession, CanvasController, SolidBody) {
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
        return (session, controller, try XCTUnwrap(session.workspace.bodies.first))
    }


    func testFilletPicksVisibleEdgesPreviewsAndCommitsOneUndoStep() throws {
        let (session, controller, body) = try boxScene()
        session.chooseTool(.fillet)
        // Front-right vertical edge at corner (30, −20): outline corner 1.
        tap(controller, SIMD3(30, -20, 10))
        XCTAssertEqual(session.finishDraft?.edges.map(\.name), [ExtrusionEdge(position: .side, index: 1)])
        XCTAssertNotNil(controller.content.childNode(withName: "finish.edges", recursively: false), "Picked edges are highlighted")
        // The back-left vertical edge is hidden behind the box and must not be picked.
        tap(controller, SIMD3(-30, 20, 10))
        XCTAssertEqual(session.finishDraft?.edges.count, 1)
        // Top front edge (y = −20, z = 20): outline segment 0 on the cap.
        tap(controller, SIMD3(0, -20, 20))
        XCTAssertEqual(session.finishDraft?.edges.map(\.name), [ExtrusionEdge(position: .side, index: 1), ExtrusionEdge(position: .cap, index: 0)])
        XCTAssertNotNil(session.finishPreview)
        XCTAssertEqual(session.workspace.bodies.first, body, "Drafts never change the document")

        XCTAssertTrue(session.applyDimension(3, target: .finishSize(.fillet)))
        XCTAssertEqual(session.finishDraft?.size, 3)
        XCTAssertNotNil(controller.finishHandle())
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.finishSize(.fillet)])
        controller.refresh()
        attach(controller, "Fillet preview with picked edges")
        session.confirmFinish()
        controller.refresh()
        attach(controller, "Filleted solid")
        let finished = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(finished.finishes.count, 1)
        XCTAssertEqual(finished.finishes.first?.size, 3)
        XCTAssertEqual(session.selection, .body(body.id))
        XCTAssertNil(session.finishDraft)
        let node = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
        XCTAssertGreaterThan(node.geometry?.elements.count ?? 0, 6, "The rendered solid has the new rounded faces")

        session.undo()
        XCTAssertEqual(session.workspace.bodies.first?.finishes, [])
        session.redo()
        XCTAssertEqual(session.workspace.bodies.first?.finishes.count, 1)
    }


    func testTappingAnEdgeAgainDeselectsAndSwitchingToolsDiscardsTheDraft() throws {
        let (session, controller, _) = try boxScene()
        session.chooseTool(.chamfer)
        tap(controller, SIMD3(30, -20, 10))
        XCTAssertEqual(session.finishDraft?.kind, .chamfer)
        tap(controller, SIMD3(30, -20, 10))
        XCTAssertNil(session.finishDraft, "Removing the only edge ends the draft")
        tap(controller, SIMD3(30, -20, 10))
        session.chooseTool(.select)
        XCTAssertNil(session.finishDraft)
        XCTAssertEqual(session.workspace.bodies.first?.finishes, [])
    }

    func testOversizedValueIsRejectedAndKeepsLastFittingSize() throws {
        let (session, controller, _) = try boxScene()
        session.chooseTool(.chamfer)
        tap(controller, SIMD3(0, -20, 20))
        let original = try XCTUnwrap(session.finishDraft?.size)
        XCTAssertFalse(session.applyDimension(45, target: .finishSize(.chamfer)))
        XCTAssertNotNil(session.dimensionError)
        XCTAssertEqual(session.finishDraft?.size, original)
        XCTAssertNil(session.finishError)
        XCTAssertFalse(session.applyDimension(-2, target: .finishSize(.chamfer)), "Sizes are positive")
    }

    func testDragHandleResizesLiveAndCancelRestores() throws {
        let (session, controller, _) = try boxScene()
        session.chooseTool(.fillet)
        tap(controller, SIMD3(30, -20, 10))
        session.snapEnabled = false
        let start = try XCTUnwrap(session.finishDraft?.size)
        let handle = try XCTUnwrap(controller.finishHandle())
        controller.pencilBegan(at: handle.center)
        controller.pencilMoved(to: CGPoint(x: handle.center.x, y: handle.center.y - 40))
        let enlarged = try XCTUnwrap(session.finishDraft?.size)
        XCTAssertGreaterThan(enlarged, start, "Dragging up enlarges the fillet")
        XCTAssertNotNil(session.finishPreview)
        controller.pencilEnded(at: CGPoint(x: handle.center.x, y: handle.center.y - 40), cancelled: true)
        XCTAssertEqual(session.finishDraft?.size, start, "A cancelled drag restores the size")
        // An oversized drag shows an error and disables Done instead of committing.
        controller.pencilBegan(at: handle.center)
        controller.pencilEnded(at: CGPoint(x: handle.center.x, y: handle.center.y - 4_000), cancelled: false)
        XCTAssertNotNil(session.finishError)
        session.confirmFinish()
        XCTAssertEqual(session.workspace.bodies.first?.finishes, [], "Done is refused while the size does not fit")
    }

    func testDepthEditsMustKeepFinishesBuildable() throws {
        let (session, controller, body) = try boxScene()
        session.chooseTool(.fillet)
        tap(controller, SIMD3(0, -20, 20))
        XCTAssertTrue(session.applyDimension(3, target: .finishSize(.fillet)))
        session.confirmFinish()
        XCTAssertTrue(session.applyDimension(30, target: .bodyDepth(body.id)))
        XCTAssertFalse(session.applyDimension(2, target: .bodyDepth(body.id)))
        XCTAssertNotNil(session.dimensionError)
        XCTAssertEqual(session.workspace.bodies.first?.depth, 30)
    }

    /// A committed fillet is changed and taken out from its own face (user report, October 23, 2026:
    /// its face offered a diameter no value could change).
    func testTappingAFilletFaceEditsItsRadiusAndDeletesIt() throws {
        let (session, controller, body) = try boxScene()
        session.chooseTool(.fillet)
        tap(controller, SIMD3(30, -20, 10))
        XCTAssertTrue(session.applyDimension(3, target: .finishSize(.fillet)))
        session.confirmFinish()
        session.chooseTool(.select)
        session.select(nil)
        controller.refresh()

        // Halfway around the round on the front-right corner.
        let h = Float(3 * 0.5.squareRoot())
        tap(controller, SIMD3(27 + h, -17 - h, 10))
        XCTAssertEqual(session.selectedFace?.bodyID, body.id)
        let finish = try XCTUnwrap(session.selectedFinish)
        XCTAssertEqual(finish.kind, .fillet)
        XCTAssertEqual(finish.size, 3)
        XCTAssertNil(session.selectedFaceSize, "No diameter for a fillet's face")
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.selectedFinish(.fillet)])
        XCTAssertEqual(controller.dimensionAnnotations().first?.text, "R 3 mm")
        XCTAssertEqual(session.helpTopic, .fillet)

        XCTAssertFalse(session.applyDimension(45, target: .selectedFinish(.fillet)), "Wider than the faces beside it")
        XCTAssertNotNil(session.dimensionError)
        XCTAssertEqual(session.workspace.bodies[0].finishes.first?.size, 3)
        XCTAssertTrue(session.applyDimension(5, target: .selectedFinish(.fillet)))
        XCTAssertEqual(session.workspace.bodies[0].finishes.first?.size, 5)
        XCTAssertEqual(session.selectedFinish?.size, 5, "The moved round stays selected")
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].finishes.first?.size, 3, "One undo step")
        session.redo()

        session.select(nil)
        controller.refresh()
        let r = Float(5 * 0.5.squareRoot())
        tap(controller, SIMD3(25 + r, -15 - r, 10))
        XCTAssertTrue(session.canDeleteSelectedFinish)
        session.deleteSelectedFinish()
        XCTAssertEqual(session.workspace.bodies[0].finishes, [])
        XCTAssertEqual(session.selection, .body(body.id))
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].finishes.first?.size, 5)
    }
}
