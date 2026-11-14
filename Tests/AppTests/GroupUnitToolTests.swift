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
        // As tapping the group's name in the Model Tree (its arrow folds it).
        session.selectItem(.group(group))
        XCTAssertEqual(session.selection, .group(group))
        let row = try XCTUnwrap(session.itemGroups.flatMap(\.items).first { $0.selection == .group(group) })
        XCTAssertTrue(session.isHighlighted(row))
        controller.refresh()
        return (session, controller, group)
    }

    func testTheWidgetMovesEverythingInTheGroupAsOneStep() throws {
        let (session, controller, group) = try groupedScene()
        // No trash for a group: its menu says whether the contents go too.
        XCTAssertFalse(session.canDeleteSelection)
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

    /// Dragging a group of solids (or a copy of it) moves pictures of them, as for one solid: no
    /// solid is meshed again, and with only solids in the group the scene is not rebuilt on each
    /// step either (November 9, 2026).
    func testDraggingAGroupMovesItsSolidsAsGhosts() throws {
        let (session, controller, group) = try groupedScene()
        session.move(.body(session.workspace.bodies[1].id), toGroup: group)
        for onlySolids in [false, true] {
            if onlySolids, let sketch = session.workspace.sketches.first?.id { session.move(.sketch(sketch), toGroup: nil) }
            session.selectItem(.group(group))
            controller.refresh()
            XCTAssertEqual(session.selectedMembers.bodies.count, 2)
            for (handle, copy) in [(TransformHandle.move(0), false), (.move(1), true), (.rotate(2), false)] {
                session.transformCopies = copy
                let renders = controller.solidRenderBuilds
                XCTAssertTrue(session.beginTransform(handle))
                var rebuilds = 0
                for step in 1...8 {
                    session.updateTransform(Double(step) * 2)
                    controller.refresh()
                    if step == 1 { rebuilds = controller.contentRebuilds }
                }
                XCTAssertEqual(session.previewGhosts.count, 2, "\(handle): both solids are ghosts")
                XCTAssertEqual(controller.solidRenderBuilds, renders, "\(handle): no solid is meshed during the drag")
                // A sketch in the group moves too, so the scene changes beyond the ghosts.
                if onlySolids { XCTAssertEqual(controller.contentRebuilds, rebuilds, "\(handle): after the first step only the solids' nodes move") }
                let preview = try XCTUnwrap(session.editPreview)
                for id in session.previewGhosts.keys {
                    let moved = try XCTUnwrap(preview.bodies.first { $0.id == id })
                    let node = try XCTUnwrap(controller.sceneView.scene?.rootNode.childNode(withName: "body|" + id.uuidString, recursively: true))
                    let expected = try SolidKernel.solid(for: moved).bounds
                    // The faces alone: the edge strokes reach past them.
                    let (low, high) = try XCTUnwrap(node.geometry).boundingBox
                    let a = node.simdConvertPosition(SIMD3<Float>(low), to: nil), b = node.simdConvertPosition(SIMD3<Float>(high), to: nil)
                    XCTAssertEqual(Double((a.x + b.x) / 2), (expected.min.x + expected.max.x) / 2, accuracy: 0.5, "\(handle): drawn where it moves")
                    XCTAssertEqual(Double((a.y + b.y) / 2), (expected.min.y + expected.max.y) / 2, accuracy: 0.5, "\(handle): drawn where it moves")
                }
                if copy { XCTAssertTrue(session.previewGhosts.keys.allSatisfy { id in !session.workspace.bodies.contains { $0.id == id } }, "The copies are the ghosts") }
                session.finishTransform(cancelled: true)
                controller.refresh()
            }
        }
        session.transformCopies = false
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
