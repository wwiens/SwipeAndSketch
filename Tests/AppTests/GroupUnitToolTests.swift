import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// A Model Tree group moved, duplicated, transformed, and exported as a unit (October 24, 2026).
@MainActor final class GroupUnitToolTests: CanvasTestCase {
    /// The box and a sketch beside it, grouped, plus a loose solid outside the group.
    func groupedScene() throws -> (ModelingSession, CanvasController, group: UUID) {
        let (session, controller) = boxScene()
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 60, y: 0), end: .init(x: 65, y: 0)))
        let box = session.workspace.bodies[0].id, sketch = try XCTUnwrap(session.workspace.sketches.first?.id)
        session.select(nil)
        session.chooseTool(.box)
        tap(controller, SIMD3(-80, 0, 0))
        session.confirmPrimitive()
        let group = try XCTUnwrap(session.newGroup(containing: .body(box)))
        session.move(.sketch(sketch), toGroup: group)
        session.select(.group(group))
        controller.refresh()
        return (session, controller, group)
    }

    func testTheWidgetMovesEverythingInTheGroupAsOneStep() throws {
        let (session, controller, group) = try groupedScene()
        let before = session.workspace
        XCTAssertEqual(session.transformWidgetTarget, .group(group))
        XCTAssertNotNil(controller.transformWidget())
        XCTAssertEqual(session.selectedMembers.bodies.count, 1)
        attach(controller, "A selected group with the Move/Rotate widget")
        XCTAssertTrue(session.beginTransform(.move(0)))
        session.updateTransform(15)
        session.finishTransform(cancelled: false)
        let boxBounds = try SolidKernel.solid(for: session.workspace.bodies[0]).bounds
        XCTAssertEqual(boxBounds.min.x, -15, accuracy: 1e-6, "The box moved")
        XCTAssertEqual(session.workspace.shapes[0].plane.origin.x, 15, accuracy: 1e-9, "The sketch moved with it")
        XCTAssertEqual(session.workspace.bodies[1], before.bodies[1], "The solid outside the group stayed")
        XCTAssertEqual(session.selection, .group(group))
        session.undo()
        XCTAssertEqual(session.workspace, before, "One undo step")
    }

    func testDuplicateScaleAndExportTakeTheWholeGroup() throws {
        let (session, _, group) = try groupedScene()
        session.duplicate()
        XCTAssertEqual(session.workspace.groups.count, 2)
        guard case .group(let copy) = session.selection else { return XCTFail("The copy is selected") }
        XCTAssertNotEqual(copy, group)
        XCTAssertEqual(session.workspace.contents(of: copy).bodies.count, 1)
        XCTAssertEqual(session.workspace.contents(of: copy).sketches.count, 1)
        XCTAssertEqual(session.workspace.bodies.count, 3)

        session.select(.group(group))
        XCTAssertEqual(session.printParts(.selected).count, 1, "Export takes the group's solids")
        session.chooseTool(.scale)
        let draft = try XCTUnwrap(session.scaleDraft)
        XCTAssertEqual(draft.bodies, session.workspace.contents(of: group).bodies)
        XCTAssertEqual(draft.sketches, session.workspace.contents(of: group).sketches)
    }
}
