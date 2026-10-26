import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Several solids, several edges of a solid, and several regions inside an open sketch picked on
/// the canvas (October 24, 2026).
@MainActor final class PickSeveralToolTests: CanvasTestCase {
    /// The 60 × 40 × 20 box and a 20 mm box beside it.
    func twoBoxes() throws -> (ModelingSession, CanvasController, UUID, UUID) {
        let (session, controller) = boxScene()
        session.chooseTool(.box)
        tap(controller, SIMD3(-70, 0, 0))
        session.confirmPrimitive()
        session.select(nil)
        controller.refresh()
        return (session, controller, session.workspace.bodies[0].id, session.workspace.bodies[1].id)
    }

    func testADoubleTapAddsASolidAndTheToolsTakeThemAll() throws {
        let (session, controller, big, small) = try twoBoxes()
        session.select(.body(big))
        controller.refresh()
        // A quick double-tap on the small box's top.
        tap(controller, SIMD3(-70, 0, 20))
        tap(controller, SIMD3(-70, 0, 20))
        XCTAssertEqual(session.selectedItems, [.body(big), .body(small)])
        XCTAssertEqual(session.pickedBodies, [big, small])
        XCTAssertEqual(session.pickedSummary, "2 solids")
        XCTAssertEqual(session.selectedMembers.bodies, [big, small])
        XCTAssertTrue(session.hint.contains("2 solids picked"), session.hint)
        XCTAssertEqual(session.helpTopic, .pickedSolids)
        XCTAssertEqual(session.transformWidgetTarget, .items(bodies: [big, small], sketches: []), "The widget moves them all")
        attach(controller, "Two solids picked")

        session.setColor(.orange, of: session.pickedBodies)
        XCTAssertEqual(session.workspace.bodies.map(\.color), [.orange, .orange])
        session.undo()

        session.pickBody(big, after: [.body(big), .body(small)])
        XCTAssertEqual(session.selectedItems, [.body(small)], "A double-tap on a picked one takes it out")
        session.pickBody(big, after: session.selectedItems)
        session.chooseTool(.union)
        XCTAssertEqual(session.unionDraft?.bodies, [small, big])
        session.cancelUnion()

        session.pickBody(small, after: [.body(big)])
        session.deleteSelection()
        XCTAssertTrue(session.workspace.bodies.isEmpty, "Delete takes them all")
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2, "As one undo step")
    }

    /// Hiding or showing something else keeps the solids picked; hiding one of them takes only it out.
    func testPickedSolidsStayPickedWhenOtherItemsAreHidden() throws {
        let (session, _, big, small) = try twoBoxes()
        let other = try XCTUnwrap(session.newGroup())
        let holder = try XCTUnwrap(session.newGroup(containing: .body(small)))
        session.pickBody(small, after: [.body(big)])
        XCTAssertEqual(session.selectedItems, [.body(big), .body(small)])
        session.toggleHidden(.group(other))
        XCTAssertEqual(session.selectedItems, [.body(big), .body(small)], "An unrelated group's eye leaves the picks")
        session.toggleHidden(.group(holder))
        XCTAssertEqual(session.selectedItems, [.body(big)], "The hidden solid leaves the picks")
    }

    func testTappingMoreEdgesOfASolidFilletsThemAll() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(30, -20, 10))
        guard case .edge? = session.selection else { return XCTFail("An edge is selected") }
        tap(controller, SIMD3(0, -20, 20))
        XCTAssertEqual(session.pickedEdges.count, 2)
        XCTAssertEqual(session.pickedSummary, "2 edges")
        XCTAssertEqual(session.helpTopic, .pickedEdges)
        session.finishSelectedEdge(.fillet)
        XCTAssertEqual(session.finishDraft?.edges.count, 2)
        session.cancelFinish()
    }

    func testRegionsInsideAnOpenSketchArePickedTogether() throws {
        let (session, controller) = boxScene()
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: session.workspace.bodies[0].id, near: [0, 0, 20]))))
        session.beginFaceSketch()
        let plane = session.plane
        for x in [-15.0, 15] {
            session.addShape(SketchShape(kind: .circle, plane: plane, start: plane.coordinates(of: [x, 0, 20]), end: plane.coordinates(of: [x + 4, 0, 20])))
        }
        session.chooseTool(.select)
        session.select(nil)
        controller.refresh()
        tap(controller, SIMD3(-15, 0, 20))
        tap(controller, SIMD3(15, 0, 20))
        XCTAssertNotNil(session.sketchMode, "Still in the sketch")
        XCTAssertEqual(session.selectedProfiles.count, 2)
        XCTAssertTrue(session.isMultipleSelection)
        XCTAssertTrue(session.canExtrude)
    }

    func testSeveralPickedSolidsMoveTogether() throws {
        let (session, controller, big, small) = try twoBoxes()
        let before = session.workspace
        session.select(.body(big))
        session.pickBody(small, after: [.body(big)])
        XCTAssertEqual(session.transformWidgetTarget, .items(bodies: [big, small], sketches: []))
        XCTAssertNotNil(controller.transformWidget())
        XCTAssertTrue(session.beginTransform(.move(2)))
        session.updateTransform(12)
        session.finishTransform(cancelled: false)
        for (index, original) in before.bodies.enumerated() {
            let moved = try SolidKernel.solid(for: session.workspace.bodies[index]).bounds.min.z
            XCTAssertEqual(moved, try SolidKernel.solid(for: original).bounds.min.z + 12, accuracy: 1e-6, "Both moved up")
        }
        XCTAssertEqual(session.pickedBodies, [big, small], "Still picked, for the next drag")
        XCTAssertTrue(session.applyDimension(20, target: .transformDistance), "The keypad changes the move")
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).bounds.min.z, 20, accuracy: 1e-6)
        session.undo()
        XCTAssertEqual(session.workspace, before, "One undo step")
    }

    func testModelTreeRowsPickedInSelectModeMoveAndCopyTogether() throws {
        let (session, controller, big, small) = try twoBoxes()
        session.beginSelectingRows()
        session.togglePicked(.body(big))
        session.togglePicked(.body(small))
        XCTAssertEqual(session.transformWidgetTarget, .items(bodies: [big, small], sketches: []))
        XCTAssertNotNil(controller.transformWidget())
        session.transformCopies = true
        XCTAssertTrue(session.beginTransform(.move(0)))
        session.updateTransform(100)
        session.finishTransform(cancelled: false)
        XCTAssertEqual(session.workspace.bodies.count, 4, "Each copied")
        XCTAssertEqual(session.pickedRows.count, 2)
        XCTAssertFalse(session.pickedRows.contains(.body(big)), "The copies are picked now")
        session.transformCopies = false
    }
}
