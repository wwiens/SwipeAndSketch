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
        XCTAssertNil(session.transformWidgetTarget, "The widget moves one item")
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

    func testTappingMoreEdgesOfASolidFilletsThemAll() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(30, -20, 10))
        guard case .edge? = session.selection else { return XCTFail("An edge is selected") }
        tap(controller, SIMD3(0, -20, 20))
        XCTAssertEqual(session.pickedEdges.count, 2)
        XCTAssertEqual(session.pickedSummary, "2 edges")
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
}
