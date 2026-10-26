import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Moving, turning, and copying solids with the Move/Rotate widget, through the Pencil pipeline.
@MainActor final class BodyTransformToolTests: CanvasTestCase {
    /// A 60 × 40 × 20 box on Top (z 0…20) with a fillet, selected, in the default 3D view.
    override func boxScene() -> (ModelingSession, CanvasController) {
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

    func drag(_ controller: CanvasController, from a: CGPoint, to b: CGPoint) {
        controller.pencilBegan(at: a)
        controller.pencilMoved(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        controller.pencilMoved(to: b)
        controller.pencilEnded(at: b, cancelled: false)
        controller.refresh()
    }

    func bounds(_ body: SolidBody) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try SolidKernel.solid(for: body).bounds }


    func testUpArrowLiftsTheSolidInOneUndoStepAndTheKeypadSetsItExactly() throws {
        let (session, controller) = boxScene()
        let id = session.workspace.bodies[0].id
        XCTAssertEqual(session.selection, .body(id), "Done leaves the new solid selected")
        let widget = try XCTUnwrap(controller.transformWidget())
        XCTAssertEqual(widget.arrows.count, 3)
        XCTAssertEqual(widget.arcs.count, 3)
        attach(controller, "Move/Rotate widget on a solid")
        let up = try XCTUnwrap(widget.arrows.first { $0.axis == 2 })
        XCTAssertLessThan(up.direction.dy, -0.9, "Up is the extrusion direction")
        let start = CGPoint(x: (up.base.x + up.tip.x) / 2, y: (up.base.y + up.tip.y) / 2)
        controller.pencilBegan(at: start)
        controller.pencilMoved(to: CGPoint(x: start.x, y: start.y - 40))
        XCTAssertEqual(try bounds(session.workspace.bodies[0]).min.z, 0, accuracy: 1e-9, "A preview until Pencil lifts")
        XCTAssertGreaterThan(try bounds(session.visibleWorkspace.bodies[0]).min.z, 1)
        controller.pencilEnded(at: CGPoint(x: start.x, y: start.y - 40), cancelled: false)
        controller.refresh()
        XCTAssertGreaterThan(try bounds(session.workspace.bodies[0]).min.z, 1)
        XCTAssertEqual(session.selection, .body(id))
        XCTAssertEqual(controller.dimensionAnnotations().first?.target, .transformDistance)
        let moved = session.workspace
        XCTAssertNil(session.dimensionValue(.transformAngle), "A move has no angle")
        XCTAssertFalse(session.applyDimension(90, target: .transformAngle), "An angle cannot change a move")
        XCTAssertEqual(session.workspace, moved)
        XCTAssertTrue(session.applyDimension(30, target: .transformDistance))
        XCTAssertEqual(try bounds(session.workspace.bodies[0]).min.z, 30, accuracy: 1e-6)
        XCTAssertEqual(try bounds(session.workspace.bodies[0]).max.z, 50, accuracy: 1e-6)
        session.undo()
        XCTAssertEqual(try bounds(session.workspace.bodies[0]).min.z, 0, accuracy: 1e-9, "The drag and its exact value are one undo step")
    }

    func testCopyKeepsTheOriginalAndTurningTheCopyStandsItSideways() throws {
        let (session, controller) = boxScene()
        let original = session.workspace.bodies[0]
        session.transformCopies = true
        var widget = try XCTUnwrap(controller.transformWidget())
        let x = try XCTUnwrap(widget.arrows.first { $0.axis == 0 })
        let start = CGPoint(x: (x.base.x + x.tip.x) / 2, y: (x.base.y + x.tip.y) / 2)
        drag(controller, from: start, to: CGPoint(x: start.x + x.direction.dx * 60, y: start.y + x.direction.dy * 60))
        XCTAssertEqual(session.workspace.bodies.count, 2, "Copy makes a second solid")
        XCTAssertEqual(session.workspace.bodies[0], original, "The original stays")
        XCTAssertTrue(session.applyDimension(80, target: .transformDistance))
        let copy = session.workspace.bodies[1]
        XCTAssertEqual(try bounds(copy).min.x, 50, accuracy: 1e-6)
        XCTAssertEqual(session.selection, .body(copy.id), "The copy is selected for the next move")
        XCTAssertEqual(session.itemGroups.first?.items.map(\.name), ["Body 01", "Body 02"])
        // Still copying: turn the copy about its own vertical axis, exactly a quarter turn.
        widget = try XCTUnwrap(controller.transformWidget())
        let arc = try XCTUnwrap(widget.arcs.first { $0.axis == 2 })
        drag(controller, from: arc.points[6], to: arc.points[12])
        XCTAssertEqual(session.workspace.bodies.count, 3)
        XCTAssertTrue(session.applyDimension(90, target: .transformAngle))
        let turned = try bounds(session.workspace.bodies[2])
        XCTAssertEqual(turned.max.x - turned.min.x, 40, accuracy: 1e-6, "60 × 40 turned to 40 × 60")
        XCTAssertEqual(turned.max.y - turned.min.y, 60, accuracy: 1e-6)
        XCTAssertEqual((turned.min.x + turned.max.x) / 2, 80, accuracy: 1e-6, "Turned about its own center")
        attach(controller, "Copied and turned solid")
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2, "Each drag is one undo step")
    }

    func testDoubleTapSelectsTheSolidWithItsWidgetAndUnionHidesIt() throws {
        let (session, controller) = boxScene()
        session.select(nil)
        controller.refresh()
        XCTAssertNil(controller.transformWidget())
        for _ in 0..<2 {
            let point = controller.project(SIMD3(5, 3, 20))
            controller.pencilBegan(at: point); controller.pencilEnded(at: point, cancelled: false); controller.refresh()
        }
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id))
        XCTAssertNotNil(controller.transformWidget())
        XCTAssertTrue(session.hint.contains("Drag an arrow"))
        // While uniting, taps pick solids, so the widget steps aside.
        session.transformCopies = true
        let widget = try XCTUnwrap(controller.transformWidget())
        let x = try XCTUnwrap(widget.arrows.first { $0.axis == 0 })
        drag(controller, from: CGPoint(x: (x.base.x + x.tip.x) / 2, y: (x.base.y + x.tip.y) / 2),
             to: CGPoint(x: (x.base.x + x.tip.x) / 2 + x.direction.dx * 40, y: (x.base.y + x.tip.y) / 2 + x.direction.dy * 40))
        XCTAssertEqual(session.workspace.bodies.count, 2)
        session.chooseTool(.union)
        controller.refresh()
        XCTAssertTrue(session.isUniting)
        XCTAssertNil(controller.transformWidget())
    }

    /// Drags the widget center (Pencil) to a point on the box and lifts.
    func movePivot(_ controller: CanvasController, to world: SIMD3<Float>) throws {
        let widget = try XCTUnwrap(controller.transformWidget())
        let target = controller.project(world)
        controller.pencilBegan(at: widget.center)
        controller.pencilMoved(to: CGPoint(x: (widget.center.x + target.x) / 2, y: (widget.center.y + target.y) / 2))
        controller.pencilMoved(to: target)
        controller.refresh()
        attach(controller, "Dragging the widget center")
        controller.pencilEnded(at: target, cancelled: false)
        controller.refresh()
    }

    func testDraggingTheCenterOntoACornerTurnsTheSolidAboutThatCorner() throws {
        let (session, controller) = boxScene()
        let id = session.workspace.bodies[0].id, before = session.workspace
        var widget = try XCTUnwrap(controller.transformWidget())
        XCTAssertTrue(widget.canPivot)
        let corner = controller.project(SIMD3(30, 20, 20))
        controller.pencilBegan(at: widget.center)
        XCTAssertTrue(session.isDraggingPivot)
        controller.pencilMoved(to: corner)
        XCTAssertEqual(session.snapLabel, "Corner")
        controller.pencilEnded(at: corner, cancelled: false)
        controller.refresh()
        XCTAssertEqual(session.transformPivot?.kind, .corner)
        XCTAssertEqual(session.workspace, before, "Placing the center changes nothing in the model")
        XCTAssertEqual(session.selection, .body(id))
        widget = try XCTUnwrap(controller.transformWidget())
        XCTAssertEqual(widget.center.x, corner.x, accuracy: 0.5)
        XCTAssertEqual(widget.center.y, corner.y, accuracy: 0.5)

        let arc = try XCTUnwrap(widget.arcs.first { $0.axis == 2 })
        drag(controller, from: arc.points[6], to: arc.points[12])
        XCTAssertFalse(session.applyDimension(25, target: .transformDistance), "A distance cannot change a turn")
        XCTAssertTrue(session.applyDimension(90, target: .transformAngle))
        let turned = try bounds(session.workspace.bodies[0])
        XCTAssertEqual(turned.min.x, 30, accuracy: 1e-6, "A quarter turn about the corner at (30, 20)")
        XCTAssertEqual(turned.max.x, 70, accuracy: 1e-6)
        XCTAssertEqual(turned.min.y, -40, accuracy: 1e-6)
        XCTAssertEqual(turned.max.y, 20, accuracy: 1e-6)
        attach(controller, "Turned about a corner")
        let pivot = try XCTUnwrap(session.transformPivot, "The center stays on the same corner")
        XCTAssertLessThan(simd_distance(pivot.center, SIMD3(30, 20, 20)), 1e-6)
        session.undo()
        XCTAssertNil(session.transformPivot)
        XCTAssertEqual(session.workspace, before)
    }

    func testBigModelsFindTheCenterSnapsInSightOffTheMainThread() async throws {
        let inline = CanvasController.inlineOcclusionTriangles
        CanvasController.inlineOcclusionTriangles = 0
        defer { CanvasController.inlineOcclusionTriangles = inline }
        let (_, controller) = boxScene()
        func corners() -> [TransformPivot] { controller.pivotSnaps().points.filter { $0.kind == .corner } }
        XCTAssertTrue(corners().isEmpty, "Snaps wait for the check")
        XCTAssertEqual(controller.pivotSnaps().points.first?.kind, .center, "The middle is always offered")
        for _ in 0..<500 where corners().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(corners().count, 7, "Seven corners of a box are in sight in the 3D view")
        XCTAssertTrue(corners().contains { simd_distance($0.point, SIMD3(30, 20, 20)) < 1e-6 })
    }

    func testCenterOnAnEdgeHingesTheSolidAboutIt() throws {
        let (session, controller) = boxScene()
        try movePivot(controller, to: SIMD3(10.2, -20, 20))
        let pivot = try XCTUnwrap(session.transformPivot)
        XCTAssertEqual(pivot.kind, .edge)
        XCTAssertLessThan(simd_distance(pivot.center, SIMD3(10, -20, 20)), 1e-6, "Whole millimeters along the edge with snapping on")
        XCTAssertEqual(abs(pivot.axes[0].x), 1, accuracy: 1e-9, "The x axis lies along the edge")
        let widget = try XCTUnwrap(controller.transformWidget())
        let arc = try XCTUnwrap(widget.arcs.first { $0.axis == 0 })
        drag(controller, from: arc.points[6], to: arc.points[12])
        XCTAssertTrue(session.applyDimension(90, target: .transformAngle))
        let hinged = try bounds(session.workspace.bodies[0])
        XCTAssertEqual(hinged.min.x, -30, accuracy: 1e-6)
        XCTAssertEqual(hinged.max.x, 30, accuracy: 1e-6)
        XCTAssertEqual(hinged.min.y, -20, accuracy: 1e-6, "Swung up about the top front edge")
        XCTAssertEqual(hinged.max.y, 0, accuracy: 1e-6)
        XCTAssertEqual(hinged.min.z, 20, accuracy: 1e-6)
        XCTAssertEqual(hinged.max.z, 60, accuracy: 1e-6)
        attach(controller, "Hinged about an edge")
        // Back to the middle: the center snaps to the solid's middle and the pivot clears.
        let center = try XCTUnwrap(session.workspace.center(of: session.workspace.bodies[0]))
        try movePivot(controller, to: SIMD3<Float>(center))
        XCTAssertNil(session.transformPivot)
    }

    /// The box, selected, beside a second 40 × 40 × 20 box at x 60…100, with a line on Top from
    /// under the second box out to (80, 60) and a circle centered at (0, 70).
    func outsideScene() throws -> (ModelingSession, CanvasController, UUID) {
        let (session, controller) = boxScene()
        let id = session.workspace.bodies[0].id
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 60, y: -20), end: .init(x: 100, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 2, "The second box is a solid of its own")
        session.addShape(.init(kind: .line, plane: .top, start: .init(x: 80, y: 0), end: .init(x: 80, y: 60)))
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 0, y: 70), end: .init(x: 5, y: 70)))
        session.select(.body(id))
        session.requestCamera(.reset)
        controller.refresh()
        XCTAssertNotNil(controller.transformWidget())
        return (session, controller, id)
    }

    func testCenterGoesOntoAnotherSolidAndTurnsTheSelectedSolidAboutIt() throws {
        let (session, controller, id) = try outsideScene()
        let other = try XCTUnwrap(session.workspace.bodies.first { $0.id != id })
        let points = controller.pivotSnaps().points
        func offered(_ p: SIMD3<Double>) -> Bool { points.contains { simd_distance($0.point, p) < 1e-6 } }
        XCTAssertTrue(offered(SIMD3(100, 20, 20)), "The other solid's corners")
        XCTAssertTrue(offered(SIMD3(80, 0, 20)), "Its face centers")
        XCTAssertTrue(offered(SIMD3(80, 60, 0)), "Sketch line ends")
        XCTAssertTrue(offered(SIMD3(0, 70, 0)), "Circle centers")
        XCTAssertFalse(offered(SIMD3(80, 0, 0)), "A line end under the other solid is hidden")
        XCTAssertFalse(points.contains { $0.kind == .origin }, "The origin is hidden under the selected box")
        XCTAssertEqual(points.filter { $0.kind == .center }.count, 1, "Only the selected solid's middle")

        // Onto the other box's top front edge: the widget's x axis lies along it.
        try movePivot(controller, to: SIMD3(70.2, -20, 20))
        var pivot = try XCTUnwrap(session.transformPivot)
        XCTAssertEqual(pivot.kind, .edge)
        XCTAssertLessThan(simd_distance(pivot.center, SIMD3(70, -20, 20)), 1e-6)
        XCTAssertEqual(abs(pivot.axes[0].x), 1, accuracy: 1e-9, "The x axis follows the other solid's edge")

        // Onto its far corner, with the live label, then a quarter turn about it.
        let before = session.workspace
        var widget = try XCTUnwrap(controller.transformWidget())
        let corner = controller.project(SIMD3(100, 20, 20))
        controller.pencilBegan(at: widget.center)
        XCTAssertTrue(session.isDraggingPivot)
        controller.pencilMoved(to: CGPoint(x: (widget.center.x + corner.x) / 2, y: (widget.center.y + corner.y) / 2))
        controller.pencilMoved(to: corner)
        XCTAssertEqual(session.snapLabel, "Corner")
        XCTAssertEqual(try XCTUnwrap(controller.transformWidget()).center.x, corner.x, accuracy: 0.5, "The widget follows the Pencil")
        controller.refresh()
        attach(controller, "Dragging the center onto another solid")
        controller.pencilEnded(at: corner, cancelled: false)
        controller.refresh()
        pivot = try XCTUnwrap(session.transformPivot)
        XCTAssertEqual(pivot.kind, .corner)
        XCTAssertLessThan(simd_distance(pivot.center, SIMD3(100, 20, 20)), 1e-6)
        XCTAssertEqual(session.workspace, before, "Placing the center changes nothing in the model")
        XCTAssertEqual(session.selection, .body(id))

        widget = try XCTUnwrap(controller.transformWidget())
        let arc = try XCTUnwrap(widget.arcs.first { $0.axis == 2 })
        drag(controller, from: arc.points[6], to: arc.points[12])
        XCTAssertTrue(session.applyDimension(90, target: .transformAngle))
        let turned = try bounds(try XCTUnwrap(session.workspace.bodies.first { $0.id == id }))
        XCTAssertEqual(turned.min.x, 100, accuracy: 1e-6, "A quarter turn about the other box's corner at (100, 20)")
        XCTAssertEqual(turned.max.x, 140, accuracy: 1e-6)
        XCTAssertEqual(turned.min.y, -110, accuracy: 1e-6)
        XCTAssertEqual(turned.max.y, -50, accuracy: 1e-6)
        XCTAssertEqual(session.workspace.bodies.first { $0.id == other.id }, other, "The other solid stays put")
        XCTAssertLessThan(simd_distance(try XCTUnwrap(session.transformPivot).center, SIMD3(100, 20, 20)), 1e-6, "The center stays on the corner")
        attach(controller, "Turned about another solid's corner")
        session.undo()
        XCTAssertEqual(session.workspace, before, "The turn is one undo step")
    }

    func testCenterGoesOntoASketchCircleCenterAndTheOrigin() throws {
        let (session, controller, id) = try outsideScene()
        func box() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
            try bounds(try XCTUnwrap(session.workspace.bodies.first { $0.id == id }))
        }
        try movePivot(controller, to: SIMD3(0, 70, 0))
        var pivot = try XCTUnwrap(session.transformPivot)
        XCTAssertEqual(pivot.kind, .circleCenter)
        XCTAssertLessThan(simd_distance(pivot.center, SIMD3(0, 70, 0)), 1e-6)
        XCTAssertEqual(abs(pivot.axes[2].z), 1, accuracy: 1e-9, "The widget turns about the circle's axis")
        var widget = try XCTUnwrap(controller.transformWidget())
        let arc = try XCTUnwrap(widget.arcs.first { $0.axis == 2 })
        drag(controller, from: arc.points[6], to: arc.points[12])
        XCTAssertTrue(session.applyDimension(90, target: .transformAngle))
        let turned = try box()
        XCTAssertEqual(turned.min.x, 50, accuracy: 1e-6, "A quarter turn about the circle's center at (0, 70)")
        XCTAssertEqual(turned.max.x, 90, accuracy: 1e-6)
        XCTAssertEqual(turned.min.y, 40, accuracy: 1e-6)
        XCTAssertEqual(turned.max.y, 100, accuracy: 1e-6)

        // The box is out of the way, so the origin is in sight.
        controller.refresh()
        XCTAssertTrue(controller.pivotSnaps().points.contains { $0.kind == .origin })
        try movePivot(controller, to: SIMD3(0, 0, 0))
        pivot = try XCTUnwrap(session.transformPivot)
        XCTAssertEqual(pivot.kind, .origin)
        XCTAssertLessThan(simd_length(pivot.center), 1e-6)
        let moved = session.workspace
        widget = try XCTUnwrap(controller.transformWidget())
        let up = try XCTUnwrap(widget.arrows.first { $0.axis == 2 })
        let start = CGPoint(x: (up.base.x + up.tip.x) / 2, y: (up.base.y + up.tip.y) / 2)
        drag(controller, from: start, to: CGPoint(x: start.x + up.direction.dx * 40, y: start.y + up.direction.dy * 40))
        XCTAssertTrue(session.applyDimension(15, target: .transformDistance))
        XCTAssertEqual(try box().min.z, 15, accuracy: 1e-6)
        XCTAssertLessThan(simd_distance(try XCTUnwrap(session.transformPivot).center, SIMD3(0, 0, 15)), 1e-6, "The center moves with the solid")
        session.undo()
        XCTAssertEqual(session.workspace, moved, "The move is one undo step")
    }

    func testSketchWidgetCenterDoesNotMove() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.select(.sketch(try XCTUnwrap(session.workspace.sketches.first?.id)))
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.layoutIfNeeded()
        controller.refresh()
        let widget = try XCTUnwrap(controller.transformWidget())
        XCTAssertFalse(widget.canPivot, "Only solids get a movable center")
        controller.pencilBegan(at: widget.center)
        XCTAssertFalse(session.isDraggingPivot)
        controller.pencilEnded(at: widget.center, cancelled: true)
    }
}
