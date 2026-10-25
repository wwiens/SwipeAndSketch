import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Sketching: sketch objects, hide/show, picking
/// a plane, opening a sketch from 3D, the Move/Rotate widget, and the selection arrows.
@MainActor final class SketchingTests: CanvasTestCase {


    func drag(_ controller: CanvasController, from a: CGPoint, to b: CGPoint) {
        controller.pencilBegan(at: a)
        controller.pencilMoved(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        controller.pencilMoved(to: b)
        controller.pencilEnded(at: b, cancelled: false)
        controller.refresh()
    }


    /// A 20 × 20 square centered on the origin, drawn on Top in its own sketch.
    func squareOnTop(_ session: ModelingSession, half: Double = 10) -> SketchShape {
        session.pickPlaneForTesting(.top)
        session.addShape(SketchShape(kind: .rectangle, plane: .top, start: .init(x: -half, y: -half), end: .init(x: half, y: half), centered: true))
        return session.workspace.shapes.last!
    }

    // MARK: Creating sketches

    func testSketchTileShowsThreePlanesAndATapStartsASketchLookingAtIt() throws {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session)
        session.beginSketch()
        controller.refresh()
        XCTAssertTrue(session.isPickingPlane)
        for name in ["top", "front", "right"] {
            XCTAssertNotNil(controller.previewNode.childNode(withName: "plane.pick.\(name)", recursively: false), name)
        }
        attach(controller, "Sketch: pick a plane")
        // A tap on the Top plane where no other plane is in front of it (toward the viewer at
        // +x, −y) starts a Top sketch and looks straight down.
        tap(controller, SIMD3(18, -18, 0))
        XCTAssertFalse(session.isPickingPlane)
        XCTAssertEqual(session.sketchMode?.plane, .top)
        XCTAssertNil(session.sketchMode?.sketchID, "The sketch starts with its first shape")
        XCTAssertEqual(session.tool, .line)
        XCTAssertEqual(-controller.cameraNode.simdWorldFront.z, 1, accuracy: 1e-3)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "sketch.origin", recursively: false), "The origin is marked")
        // Before a plane is picked the sketch tools are ready, and a stroke in open
        // space draws on the grid (Top) from where the camera is.
        session.exitSketch()
        session.requestCamera(.home)
        controller.refresh()
        let front = controller.cameraNode.simdWorldFront
        session.beginSketch()
        XCTAssertEqual(session.tool, .line, "Line is ready before a plane is picked")
        session.chooseTool(.circle)
        XCTAssertTrue(session.isPickingPlane, "Choosing a drawing tool keeps waiting for the plane")
        XCTAssertEqual(session.tool, .circle)
        controller.refresh()
        let a = controller.project(SIMD3(60, 50, 0)), b = controller.project(SIMD3(70, 50, 0))
        controller.pencilBegan(at: a)
        controller.pencilMoved(to: b)
        controller.pencilEnded(at: b, cancelled: false)
        controller.refresh()
        XCTAssertFalse(session.isPickingPlane)
        XCTAssertEqual(session.sketchMode?.plane, .top)
        let circle = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(circle.kind, .circle)
        XCTAssertEqual(circle.start.x, 60, accuracy: 1)
        XCTAssertEqual(circle.start.distance(to: circle.end), 10, accuracy: 1)
        XCTAssertEqual(controller.cameraNode.simdWorldFront, front, "The view did not turn")
    }

    func testEachSketchSessionIsItsOwnSketchAndCrossingsAreGuides() throws {
        let session = ModelingSession(inMemory: true)
        let square = squareOnTop(session)
        session.exitSketch()
        XCTAssertEqual(session.selection, .sketch(try XCTUnwrap(square.sketch)), "Leaving a sketch selects all of it")
        // A second sketch on Front shows where the Top square crosses it.
        session.pickPlaneForTesting(.front)
        let crossings = session.sketchGuides.filter { $0.kind == .intersection }.map(\.point)
        XCTAssertEqual(Set(crossings.map { "\($0.x),\($0.y)" }), ["-10.0,0.0", "10.0,0.0"])
        session.addShape(SketchShape(kind: .rectangle, plane: .front, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10)))
        XCTAssertEqual(session.workspace.sketches.count, 2)
        XCTAssertEqual(session.itemGroups.last?.items.filter { $0.indent == 0 }.map(\.name), ["Sketch 01", "Sketch 02"])
        // Back on Top, a new sketch session is a third sketch, not part of the first.
        session.exitSketch()
        session.pickPlaneForTesting(.top)
        session.addShape(SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 3, y: 0)))
        XCTAssertEqual(session.workspace.sketches.count, 3)
    }

    func testStrokesSnapOntoSketchLinesTheirMiddlesAndCornersEvenWithSnapOff() throws {
        let session = ModelingSession(inMemory: true)
        _ = squareOnTop(session)
        let controller = canvas(session, camera: .reset)
        session.snapEnabled = false
        session.chooseTool(.line)
        let nudge = CGPoint(x: 4, y: -3)
        func near(_ x: Float, _ y: Float) -> CGPoint {
            let p = controller.project(SIMD3(x, y, 0))
            return CGPoint(x: p.x + nudge.x, y: p.y + nudge.y)
        }
        // From a few points off the square's right side, out into open space.
        drag(controller, from: near(10, 3.7), to: controller.project(SIMD3(31.37, 8.21, 0)))
        var line = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(line.start.x, 10, accuracy: 1e-9, "Starts on the side")
        XCTAssertEqual(line.start.y, 3.7, accuracy: 0.6)
        XCTAssertNotEqual(line.end.x, line.end.x.rounded(), "No grid with Snap off")
        // From near the side's middle to near the top right corner.
        drag(controller, from: near(-10, 0), to: near(10, 10))
        line = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(line.start, Point2(x: -10, y: 0))
        XCTAssertEqual(line.end, Point2(x: 10, y: 10))
    }

    // MARK: Hide and show

    func testHiddenSketchesAndSolidsLeaveTheCanvas() throws {
        let session = ModelingSession(inMemory: true)
        let square = squareOnTop(session)
        session.exitSketch()
        session.select(.shape(square.id))
        session.beginExtrusion()
        session.extrusionDepth = 10
        session.confirmExtrusion()
        session.pickPlaneForTesting(.front)
        session.addShape(SketchShape(kind: .line, plane: .front, start: .init(x: -20, y: 30), end: .init(x: 20, y: 30)))
        session.exitSketch()
        let controller = canvas(session)
        let line = session.workspace.shapes.last!
        XCTAssertNotNil(controller.content.childNode(withName: "shape|" + line.id.uuidString, recursively: false))
        let sketchRow = try XCTUnwrap(session.itemGroups.last?.items.first { $0.name == "Sketch 02" })
        session.toggleHidden(sketchRow.selection)
        controller.refresh()
        XCTAssertNil(controller.content.childNode(withName: "shape|" + line.id.uuidString, recursively: false))
        XCTAssertNil(session.selection, "Hiding the selected sketch clears the selection")
        XCTAssertEqual(session.itemGroups.last?.items.first { $0.name == "Sketch 02" }?.isHidden, true)
        // Solids too: hidden solids are neither drawn nor picked.
        let body = session.workspace.bodies[0]
        session.toggleHidden(.body(body.id))
        controller.refresh()
        XCTAssertNil(controller.content.childNode(withName: "body|" + body.id.uuidString, recursively: false))
        tap(controller, SIMD3(0, 0, 10))
        XCTAssertNil(session.selectedFace)
        session.undo(); session.undo()
        controller.refresh()
        XCTAssertNotNil(controller.content.childNode(withName: "body|" + body.id.uuidString, recursively: false), "Showing again is an undo away")
    }

    // MARK: Editing sketches from 3D

    func testTappingALineOpensItsSketchAndDrawingContinuesAtAnAngle() throws {
        let session = ModelingSession(inMemory: true)
        let square = squareOnTop(session)
        session.exitSketch()
        session.select(nil)
        session.choosePlane(.front)
        session.chooseCubeFace(.front)
        let controller = canvas(session)   // default 3D view
        let view = controller.cameraNode.simdWorldFront
        tap(controller, SketchPlane.top.world(.init(x: 10, y: 0)))
        XCTAssertEqual(session.plane, .top, "The grid moves to the sketch's plane")
        XCTAssertEqual(session.sketchMode?.sketchID, square.sketch)
        XCTAssertEqual(session.selection, .shape(square.id))
        XCTAssertEqual(simd_distance(controller.cameraNode.simdWorldFront, view), 0, accuracy: 1e-5, "The camera does not move")
        // Draw a line into the same sketch from the 3D view.
        session.chooseTool(.line)
        controller.refresh()
        let a = controller.project(SketchPlane.top.world(.init(x: -10, y: 10))), b = controller.project(SketchPlane.top.world(.init(x: 10, y: 25)))
        drag(controller, from: a, to: b)
        XCTAssertEqual(simd_distance(controller.cameraNode.simdWorldFront, view), 0, accuracy: 1e-5, "Pencil draws at an angle")
        let line = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(line.sketch, square.sketch, "It joins the opened sketch")
        XCTAssertEqual(line.start.x, -10, accuracy: 0.05)
        XCTAssertEqual(line.end.y, 25, accuracy: 0.05)
        attach(controller, "Drawing into a sketch in 3D")
    }

    func testTappingALineHighlightsEverythingOnItsPlane() throws {
        let session = ModelingSession(inMemory: true)
        let square = squareOnTop(session)
        session.exitSketch()
        session.pickPlaneForTesting(.top)
        session.addShape(SketchShape(kind: .line, plane: .top, start: .init(x: 20, y: -10), end: .init(x: 40, y: 10)))
        let line = try XCTUnwrap(session.workspace.shapes.last)
        session.exitSketch()
        session.pickPlaneForTesting(.front)
        session.addShape(SketchShape(kind: .circle, plane: .front, start: .init(x: 0, y: 20), end: .init(x: 6, y: 20)))
        let circle = try XCTUnwrap(session.workspace.shapes.last)
        session.exitSketch()
        session.select(nil)
        let controller = canvas(session)
        func color(_ shape: SketchShape) throws -> (red: CGFloat, alpha: CGFloat) {
            let node = try XCTUnwrap(controller.content.childNode(withName: "shape|" + shape.id.uuidString, recursively: false))
            let material = try XCTUnwrap(node.geometry?.firstMaterial)
            let drawn = try XCTUnwrap(material.diffuse.contents as? UIColor)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            drawn.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, material.transparency)
        }
        XCTAssertEqual(try color(line).alpha, 1, "Outside a sketch nothing fades")
        tap(controller, SketchPlane.top.world(.init(x: 10, y: 0)))
        XCTAssertEqual(session.sketchMode?.sketchID, square.sketch)
        XCTAssertEqual(try color(line).red, 0x6D / 255, accuracy: 0.02, "Another sketch on the same plane is highlighted")
        XCTAssertEqual(try color(square).red, 0.12, accuracy: 0.02, "The tapped shape stays selected")
        XCTAssertLessThan(try color(circle).alpha, 0.5, "A sketch on another plane fades")
        attach(controller, "A line tapped: its plane highlighted")
        session.chooseTool(.line)
        controller.refresh()
        attach(controller, "Drawing on the highlighted plane")
        session.exitSketch()
        session.select(nil)
        controller.refresh()
        XCTAssertEqual(try color(circle).alpha, 1, "Leaving the sketch brings everything back")
    }

    func testDoubleTappingALineSelectsTheWholeSketch() throws {
        let session = ModelingSession(inMemory: true)
        let square = squareOnTop(session)
        session.exitSketch()
        session.select(nil)
        let controller = canvas(session)
        tap(controller, SketchPlane.top.world(.init(x: 10, y: 0)))
        tap(controller, SketchPlane.top.world(.init(x: 10, y: 0)))
        XCTAssertEqual(session.selection, .sketch(try XCTUnwrap(square.sketch)))
        XCTAssertNil(session.sketchMode)
        XCTAssertNotNil(controller.transformWidget())
    }

    // MARK: Move and rotate

    func testMoveArrowLiftsTheSketchInOneUndoStepAndTheKeypadSetsItExactly() throws {
        let session = ModelingSession(inMemory: true)
        let square = squareOnTop(session)
        session.exitSketch()
        let controller = canvas(session)
        let widget = try XCTUnwrap(controller.transformWidget())
        XCTAssertEqual(widget.arrows.count, 3, "Arrows along the sketch's x, y, and normal")
        XCTAssertEqual(widget.arcs.count, 3)
        attach(controller, "Move/Rotate widget")
        let up = try XCTUnwrap(widget.arrows.first { $0.axis == 2 })
        XCTAssertLessThan(up.direction.dy, -0.9, "The normal of a Top sketch points up on screen")
        let start = CGPoint(x: (up.base.x + up.tip.x) / 2, y: (up.base.y + up.tip.y) / 2)
        controller.pencilBegan(at: start)
        controller.pencilMoved(to: CGPoint(x: start.x, y: start.y - 40))
        XCTAssertEqual(session.workspace.sketches[0].plane, .top, "A preview until Pencil lifts")
        XCTAssertGreaterThan(session.visibleWorkspace.sketches[0].plane.origin.z, 1)
        controller.pencilEnded(at: CGPoint(x: start.x, y: start.y - 40), cancelled: false)
        controller.refresh()
        let lifted = session.workspace.sketches[0].plane.origin.z
        XCTAssertGreaterThan(lifted, 1)
        XCTAssertEqual(session.selection, .sketch(try XCTUnwrap(square.sketch)))
        XCTAssertEqual(controller.dimensionAnnotations().first?.target, .transformDistance)
        XCTAssertTrue(session.applyDimension(30, target: .transformDistance))
        XCTAssertEqual(session.workspace.sketches[0].plane.origin.z, 30, accuracy: 1e-9)
        session.undo()
        XCTAssertEqual(session.workspace.sketches[0].plane, .top, "The drag and its exact value are one undo step")
        // A cancelled drag changes nothing.
        session.selectSketch(try XCTUnwrap(square.sketch))
        controller.refresh()
        controller.pencilBegan(at: start)
        controller.pencilMoved(to: CGPoint(x: start.x, y: start.y - 40))
        controller.pencilEnded(at: CGPoint(x: start.x, y: start.y - 40), cancelled: true)
        XCTAssertEqual(session.workspace.sketches[0].plane, .top)
        XCTAssertNil(session.editPreview)
    }

    func testCopyKeepsTheOriginalAndRotateTurnsTheCopyUpright() throws {
        let session = ModelingSession(inMemory: true)
        _ = squareOnTop(session)
        session.exitSketch()
        session.transformCopies = true
        let controller = canvas(session)
        var widget = try XCTUnwrap(controller.transformWidget())
        let up = try XCTUnwrap(widget.arrows.first { $0.axis == 2 })
        let start = CGPoint(x: (up.base.x + up.tip.x) / 2, y: (up.base.y + up.tip.y) / 2)
        drag(controller, from: start, to: CGPoint(x: start.x, y: start.y - 60))
        XCTAssertEqual(session.workspace.sketches.count, 2, "Copy makes a new sketch")
        XCTAssertEqual(session.workspace.sketches[0].plane, .top, "The original stays")
        XCTAssertTrue(session.applyDimension(20, target: .transformDistance))
        let copy = session.workspace.sketches[1]
        XCTAssertEqual(copy.plane.origin.z, 20, accuracy: 1e-9)
        XCTAssertEqual(session.selection, .sketch(copy.id), "The copy is selected for the next move")
        // Still copying: turn the copy about its own x axis; the keypad makes it exactly 90°.
        widget = try XCTUnwrap(controller.transformWidget())
        let arc = try XCTUnwrap(widget.arcs.first { $0.axis == 0 })
        let from = arc.points[6], to = arc.points[12]
        drag(controller, from: from, to: to)
        XCTAssertEqual(session.workspace.sketches.count, 3, "Copy is still on")
        XCTAssertEqual(controller.dimensionAnnotations().first?.target, .transformAngle)
        XCTAssertNotEqual(session.dimensionValue(.transformAngle) ?? 0, 0)
        XCTAssertTrue(session.applyDimension(90, target: .transformAngle))
        let turned = session.workspace.sketches[2]
        XCTAssertEqual(abs(turned.plane.normalAxis.y), 1, accuracy: 1e-9, "Standing upright, parallel to Front")
        XCTAssertEqual(try XCTUnwrap(session.workspace.center(of: turned)).z, 20, accuracy: 1e-9, "Turned about its own center")
        XCTAssertEqual(session.workspace.shapes.count, 3)
        attach(controller, "Copied and rotated sketch")
    }

    // MARK: Selection arrows

    func testArrowOnASelectedRegionExtrudesFromZeroWithoutMovingTheCamera() throws {
        let session = ModelingSession(inMemory: true)
        // Large enough that the arrow at the center is clear of the square's sides.
        let square = squareOnTop(session, half: 40)
        session.exitSketch()
        session.select(nil)
        let controller = canvas(session)
        tap(controller, SketchPlane.top.world(.init(x: 40, y: 0)))   // opens the sketch, square selected
        XCTAssertEqual(session.selection, .shape(square.id))
        let view = controller.cameraNode.simdWorldFront
        let handle = try XCTUnwrap(controller.selectionExtrudeHandle())
        drag(controller, from: handle.center, to: CGPoint(x: handle.center.x + handle.axis.dx * 50, y: handle.center.y + handle.axis.dy * 50))
        XCTAssertTrue(session.isExtruding)
        XCTAssertGreaterThan(session.extrusionDepth, 1)
        XCTAssertEqual(simd_distance(controller.cameraNode.simdWorldFront, view), 0, accuracy: 1e-5)
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 1)
    }

    func testTappingAnEdgeOffersFilletAndChamferAndItsArrowRounds() throws {
        let session = ModelingSession(inMemory: true)
        let square = squareOnTop(session)
        session.exitSketch()
        session.select(.shape(square.id))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        let controller = canvas(session)
        // The top edge along +X (y = -10 is toward the viewer in the default view).
        tap(controller, SIMD3(0, -10, 20))
        let picked = try XCTUnwrap(session.selectedEdge)
        XCTAssertEqual(picked.bodyID, session.workspace.bodies[0].id)
        XCTAssertNotNil(controller.content.childNode(withName: "edge.selection", recursively: false))
        let handle = try XCTUnwrap(controller.edgeSelectionHandle())
        drag(controller, from: handle.center, to: CGPoint(x: handle.center.x, y: handle.center.y - 30))
        XCTAssertEqual(session.finishDraft?.kind, .fillet)
        XCTAssertEqual(session.finishDraft?.edges, [picked.edge])
        session.cancelFinish()
        session.select(.edge(picked.bodyID, picked.edge))
        session.finishSelectedEdge(.chamfer)
        XCTAssertEqual(session.finishDraft?.kind, .chamfer)
    }

    // MARK: Sketching on a slanted face

    func testCircleAtTheCenterOfAChamferedFace() throws {
        // A 10 mm cube, an 8 mm chamfer on a top edge, then a 9 mm circle at the slanted face's center.
        let session = ModelingSession(inMemory: true)
        session.pickPlaneForTesting(.top)
        session.addShape(SketchShape(kind: .rectangle, plane: .top, start: .init(x: -5, y: -5), end: .init(x: 5, y: 5), centered: true))
        session.exitSketch()
        session.select(.shape(session.workspace.shapes[0].id))
        session.beginExtrusion()
        XCTAssertTrue(session.applyDimension(10, target: .extrusion))
        session.confirmExtrusion()
        session.select(nil)
        let controller = canvas(session)
        tap(controller, SIMD3(0, -5, 10))
        XCTAssertNotNil(session.selectedEdge)
        session.finishSelectedEdge(.chamfer)
        XCTAssertTrue(session.applyDimension(8, target: .finishSize(.chamfer)))
        session.confirmFinish()
        session.select(nil)
        controller.refresh()
        // The slanted face runs from (y −5, z 2) to (y 3, z 10); tap its middle.
        tap(controller, SIMD3(0, -1, 6))
        let face = try XCTUnwrap(session.selectedFace)
        let plane = try XCTUnwrap(face.plane)
        XCTAssertEqual(plane.normalAxis.y, -plane.normalAxis.z, accuracy: 1e-9, "The chamfer face leans at 45°")
        session.beginFaceSketch()
        controller.refresh()
        let guides = session.sketchGuides
        let center = try XCTUnwrap(guides.first { $0.kind == .faceCenter })
        XCTAssertTrue(guides.contains { $0.kind == .midpoint })
        XCTAssertTrue(guides.contains { $0.kind == .corner })
        session.chooseTool(.circle)
        controller.refresh()
        let c = controller.project(plane.world(center.point)), r = controller.project(plane.world(center.point + Point2(x: 4.5, y: 0)))
        drag(controller, from: CGPoint(x: c.x + 2, y: c.y - 1), to: r)
        let circle = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(circle.kind, .circle)
        XCTAssertEqual(circle.plane, plane)
        XCTAssertEqual(circle.start, center.point, "Snapped to the face center")
        XCTAssertTrue(session.applyDimension(9, target: .shape(circle.id, .diameter)))
        XCTAssertEqual(ShapeDimension.diameter.value(of: session.workspace.shapes.last!), 9, accuracy: 1e-9)
        attach(controller, "Circle on the chamfer face")
    }
}

extension ModelingSession {
    /// Starts a new sketch on a world plane, as tapping it after the Sketch tile does.
    func pickPlaneForTesting(_ plane: SketchPlane) {
        beginSketch()
        pickPlane(plane)
    }
}
