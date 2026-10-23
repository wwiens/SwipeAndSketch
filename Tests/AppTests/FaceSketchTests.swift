import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Face selection, sketch mode on a face, guide points, and extruding from face sketches,
/// through the real Pencil pipeline.
@MainActor final class FaceSketchTests: CanvasTestCase {


    func stroke(_ controller: CanvasController, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        controller.pencilBegan(at: controller.project(a))
        controller.pencilMoved(to: controller.project(b))
        controller.pencilEnded(at: controller.project(b), cancelled: false)
        controller.refresh()
    }

    /// Select the face under a point and enter sketch mode on it.
    func sketchOnFace(_ session: ModelingSession, _ controller: CanvasController, at world: SIMD3<Float>) throws -> FaceSelection {
        tap(controller, world)
        let face = try XCTUnwrap(session.selectedFace)
        session.beginFaceSketch()
        controller.refresh()
        return face
    }

    func testTapSelectsAFaceAndDoubleTapSelectsTheSolid() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        let face = try XCTUnwrap(session.selectedFace)
        XCTAssertEqual(face.bodyID, session.workspace.bodies[0].id)
        XCTAssertEqual(face.plane?.origin.z ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(face.plane?.normalAxis.z ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(face.center.x, 0, accuracy: 1e-6, "The view centers on the face's center")
        XCTAssertTrue(session.canSketchOnSelectedFace)
        XCTAssertNotNil(controller.content.childNode(withName: "face.selection", recursively: false), "The picked face is tinted")
        attach(controller, "Face selected")
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id), "A quick second tap picks the whole solid")
    }

    func testFaceSketchLocksThePlaneLooksAtTheFaceAndSnapsToGuides() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(5, 3, 20))
        let mode = try XCTUnwrap(session.sketchMode)
        XCTAssertEqual(mode.title, "Face sketch")
        XCTAssertEqual(session.plane, mode.plane)
        XCTAssertEqual(session.tool, .line)
        XCTAssertEqual(-controller.cameraNode.simdWorldFront.z, 1, accuracy: 1e-4, "The camera looks straight down at the face")
        let guides = session.sketchGuides
        XCTAssertEqual(guides.filter { $0.kind == .corner }.count, 4)
        XCTAssertEqual(guides.filter { $0.kind == .midpoint }.count, 4)
        XCTAssertEqual(guides.filter { $0.kind == .faceCenter }.count, 1)

        // A circle started just off the face center snaps to it; the radius reaches an edge midpoint.
        session.chooseTool(.circle)
        controller.refresh()
        stroke(controller, from: SIMD3(0.4, -0.3, 20), to: SIMD3(0.3, 19.7, 20))
        let circle = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(circle.plane, mode.plane, "Strokes stay on the face")
        XCTAssertEqual(circle.start.x, 0, accuracy: 1e-9); XCTAssertEqual(circle.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(circle.end.x, 0, accuracy: 1e-9); XCTAssertEqual(circle.end.y, 20, accuracy: 1e-9)
        XCTAssertNotNil(session.sketchMode, "Drawing keeps sketch mode")
        attach(controller, "Face sketch with guide points and a centered circle")

        // Strokes that start outside the face still land on the locked plane.
        session.chooseTool(.line)
        controller.refresh()
        stroke(controller, from: SIMD3(-50, -35, 20), to: SIMD3(-40, -35, 20))
        XCTAssertEqual(session.workspace.shapes.last?.plane, mode.plane)

        session.exitSketch()
        XCTAssertNil(session.sketchMode)
        XCTAssertEqual(session.tool, .select)
    }


    func testChoosingADrawingToolWithAFaceSelectedSketchesOnThatFace() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        session.chooseTool(.circle)          // no Sketch tap in between
        controller.refresh()
        XCTAssertEqual(session.sketchMode?.title, "Face sketch")
        XCTAssertEqual(session.plane.origin.z, 20, accuracy: 1e-9)
        XCTAssertEqual(-controller.cameraNode.simdWorldFront.z, 1, accuracy: 1e-4, "The camera looks straight down at the face")
        session.snapEnabled = false
        stroke(controller, from: SIMD3(5, 2, 20), to: SIMD3(9, 2, 20))
        let circle = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(circle.plane.point(circle.start).z, 20, accuracy: 1e-9, "The circle is on the top face, not on Top at the bottom")
        session.beginExtrusion()
        XCTAssertTrue(session.applyDimension(-6, target: .extrusion))
        XCTAssertEqual(session.extrusionMode, .cut, "Extruding down from the top face cuts a pocket")
        session.confirmExtrusion()
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).bounds.max.z, 20, accuracy: 1e-9)
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, 48_000 - .pi * 16 * 6, accuracy: 0.5)

        // The Hole tool works the same way from a selected face.
        session.chooseTool(.select)
        controller.refresh()
        tap(controller, SIMD3(-20, -10, 20))
        session.chooseTool(.hole)
        XCTAssertEqual(session.sketchMode?.face?.bodyID, session.workspace.bodies[0].id)
    }

    func testSolidsAreNotPickableWhileSketching() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(5, 3, 20))
        session.chooseTool(.select)
        tap(controller, SIMD3(-20, 10, 20))
        XCTAssertNil(session.selectedFace)
        XCTAssertNil(session.selectedBody)
    }

    func testPocketFromAFaceSketchCutsAutomatically() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(5, 3, 20))
        session.snapEnabled = false
        session.chooseTool(.circle)
        controller.refresh()
        stroke(controller, from: SIMD3(5, 2, 20), to: SIMD3(11, 2, 20))
        session.beginExtrusion()
        XCTAssertNil(session.sketchMode, "Extruding leaves sketch mode")
        XCTAssertEqual(session.extrusionMode, .newBody, "Outward from the face is a new body")
        XCTAssertTrue(session.applyDimension(-8, target: .extrusion))
        XCTAssertEqual(session.extrusionMode, .cut, "Into the solid switches to Cut")
        session.confirmExtrusion()
        let volume = try SolidKernel.solid(for: session.workspace.bodies[0]).volume
        XCTAssertEqual(volume, 48_000 - .pi * 36 * 8, accuracy: 0.5)
    }

    func testSideFaceSketchCutsThroughAndDragTowardTheSolidGoesIn() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(0, -20, 10))
        XCTAssertEqual(session.plane.normalAxis.y, -1, accuracy: 1e-9)
        XCTAssertEqual(session.plane.origin.y, -20, accuracy: 1e-9)
        XCTAssertEqual(-controller.cameraNode.simdWorldFront.y, -1, accuracy: 1e-4, "The camera looks straight at the front face")
        session.snapEnabled = false
        session.chooseTool(.circle)
        controller.refresh()
        stroke(controller, from: SIMD3(-5, -20, 12), to: SIMD3(-1, -20, 12))
        let hole = try XCTUnwrap(session.workspace.shapes.last)
        let center = hole.plane.point(hole.start)
        XCTAssertEqual(center.x, -5, accuracy: 0.05); XCTAssertEqual(center.z, 12, accuracy: 0.05)

        session.beginExtrusion()
        // Extruding keeps the straight-on view; turn to the 3D angle to drag along the arrow.
        session.requestCamera(.home)
        controller.refresh()
        // Dragging toward the solid (the box interior is +Y) moves into it and cuts.
        let handle = try XCTUnwrap(controller.extrusionHandle())
        let face = controller.project(SIMD3(-5, -20, 12)), inside = controller.project(SIMD3(-5, 0, 12))
        let length = hypot(inside.x - face.x, inside.y - face.y)
        let toward = CGVector(dx: (inside.x - face.x) / length, dy: (inside.y - face.y) / length)
        controller.pencilBegan(at: handle.center)
        controller.pencilEnded(at: CGPoint(x: handle.center.x + toward.dx * 150, y: handle.center.y + toward.dy * 150), cancelled: false)
        XCTAssertLessThan(session.extrusionDepth, 0)
        XCTAssertEqual(session.extrusionMode, .cut)
        session.cutThroughAll = true
        XCTAssertEqual(session.cutTargets.count, 1)
        session.confirmExtrusion()
        let volume = try SolidKernel.solid(for: session.workspace.bodies[0]).volume
        XCTAssertEqual(volume, 48_000 - .pi * 16 * 40, accuracy: 1)
    }

    func testDrawingToolsSketchOnTheCurrentPlaneNotTheFaceUnderThePencil() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.rectangle)
        XCTAssertEqual(session.sketchMode?.plane, .top, "A drawing tool starts a sketch on the current plane")
        controller.refresh()
        stroke(controller, from: SIMD3(-10, -10, 0), to: SIMD3(10, 10, 0))
        XCTAssertEqual(session.workspace.shapes.last?.plane, .top, "No jumping to the box's top face")
        XCTAssertEqual(session.sketchGuides.filter { $0.kind == .corner }.count, 4, "The box's bottom edges lie on Top")
    }

    func testRectangleFromTheFaceCenterStaysCenteredWhenResized() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(5, 3, 20))
        session.chooseTool(.rectangle)
        session.rectangleFromCenter = true
        controller.refresh()
        stroke(controller, from: SIMD3(0.3, 0.4, 20), to: SIMD3(10.2, 6.1, 20))
        let rectangle = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertTrue(rectangle.isCentered)
        XCTAssertEqual(rectangle.center.x, 0, accuracy: 1e-9, "The center snapped to the face's center dot")
        XCTAssertEqual(rectangle.center.y, 0, accuracy: 1e-9)
        XCTAssertEqual(ShapeDimension.width.value(of: rectangle), 20, accuracy: 1e-9)
        XCTAssertEqual(ShapeDimension.height.value(of: rectangle), 12, accuracy: 1e-9)
        XCTAssertTrue(session.applyDimension(36, target: .shape(rectangle.id, .width)))
        let resized = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(resized.center.x, 0, accuracy: 1e-9, "Keypad edits keep it centered on the face")
        XCTAssertEqual(ShapeDimension.width.value(of: resized), 36, accuracy: 1e-9)
        XCTAssertTrue(controller.sketchHandles(for: resized).contains { $0.0 == .center })
    }

    func testAlignmentWithAGuidePointSnapsAndShowsADashedGuide() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(5, 3, 20))
        session.chooseTool(.line)
        controller.refresh()
        controller.pencilBegan(at: controller.project(SIMD3(-25, -15, 20)))
        controller.pencilMoved(to: controller.project(SIMD3(0.4, 8.3, 20)))
        controller.refresh()
        let live = try XCTUnwrap(controller.liveSnap)
        XCTAssertEqual(live.result.label, "Vertical")
        XCTAssertEqual(live.result.alignedTo, [.init(x: 0, y: 0)], "Lined up under the face center (nearer than the top midpoint)")
        attach(controller, "Dashed alignment guide while drawing")
        controller.pencilEnded(at: controller.project(SIMD3(0.4, 8.3, 20)), cancelled: false)
        let line = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(line.end.x, 0, accuracy: 1e-9)
        XCTAssertEqual(line.end.y, 8, accuracy: 1e-9)
        XCTAssertNil(controller.liveSnap, "Guides disappear when the stroke ends")
    }

    func testViewCubeMovesTheSketchToAWorldPlane() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(5, 3, 20))
        session.chooseCubeFace(.front)
        XCTAssertEqual(session.plane, .front)
        XCTAssertEqual(session.sketchMode?.plane, .front)
        XCTAssertNil(session.sketchMode?.face)
    }

    // MARK: Items list

    func testItemsListNamesSolidsAndListsEachSketchWithItsShapes() throws {
        let (session, _) = boxScene()
        session.addShape(.init(kind: .line, plane: .front, start: .init(x: 0, y: 30), end: .init(x: 20, y: 30)))
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 50, y: 0), end: .init(x: 55, y: 0)))
        let groups = session.itemGroups
        XCTAssertEqual(groups.map(\.title), ["Bodies", "Sketches"])
        XCTAssertEqual(groups.map { $0.items.map(\.name) }, [["Body 01"], ["Sketch 01", "Rectangle 01", "Circle 01", "Sketch 02", "Line 01"]])
        XCTAssertEqual(groups[0].items[0].selection, .body(session.workspace.bodies[0].id))
        XCTAssertEqual(groups[0].items[0].isHidden, false, "Solids can be hidden")
        let sketches = groups[1].items
        XCTAssertEqual(sketches[0].selection, .sketch(session.workspace.sketches[0].id))
        XCTAssertEqual(sketches[0].isHidden, false)
        XCTAssertEqual(sketches[1].indent, 1, "Shapes sit under their sketch")
        XCTAssertNil(sketches[1].isHidden, "Shapes follow their sketch's visibility")
        XCTAssertEqual(sketches[4].selection, .shape(session.workspace.shapes[1].id))
    }

    func testItemsListSelectsASketchHiddenUnderItsSolid() throws {
        let (session, controller) = boxScene()
        let rectangle = session.workspace.shapes[0]
        XCTAssertNil(controller.content.childNode(withName: "shape|" + rectangle.id.uuidString, recursively: false),
                     "The source sketch is covered by the solid's base")
        let item = try XCTUnwrap(session.itemGroups.flatMap(\.items).first { $0.name == "Rectangle 01" })
        session.selectItem(item.selection)
        controller.refresh()
        XCTAssertEqual(session.selection, .shape(rectangle.id))
        XCTAssertTrue(session.isHighlighted(item))
        XCTAssertNotNil(controller.content.childNode(withName: "shape|" + rectangle.id.uuidString, recursively: false))
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .shape(rectangle.id, .width) })
        XCTAssertEqual(session.sketchMode?.sketchID, rectangle.sketch, "Picking a shape opens its sketch")
    }

    func testItemsListOpensASketchOnAnotherPlaneWithoutMovingTheCamera() {
        let (session, controller) = boxScene()
        session.addShape(.init(kind: .line, plane: .front, start: .init(x: 0, y: 30), end: .init(x: 20, y: 30)))
        session.select(nil)
        controller.refresh()
        let view = controller.cameraNode.simdWorldFront
        session.selectItem(.shape(session.workspace.shapes[1].id))
        controller.refresh()
        XCTAssertEqual(session.selection, .shape(session.workspace.shapes[1].id))
        XCTAssertEqual(session.plane, .front, "The grid moves to the sketch's plane")
        XCTAssertEqual(session.sketchMode?.sketchID, session.workspace.shapes[1].sketch)
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(simd_distance(controller.cameraNode.simdWorldFront, view), 0, accuracy: 1e-6, "The camera stays where it is")
    }

    // MARK: Picking sketches on the canvas

    func testPencilPicksAndDragsASketchOnAnotherPlane() throws {
        let (session, controller) = boxScene()
        session.addShape(.init(kind: .line, plane: .front, start: .init(x: 0, y: 30), end: .init(x: 20, y: 30)))
        session.select(nil)
        controller.refresh()
        let line = session.workspace.shapes[1]
        tap(controller, SketchPlane.front.world(.init(x: 10, y: 30)))
        XCTAssertEqual(session.selection, .shape(line.id), "A Front sketch is picked while Top is the sketch plane")
        XCTAssertEqual(session.plane, .front, "Tapping a line opens its sketch")
        XCTAssertEqual(session.sketchMode?.sketchID, line.sketch)
        // Its endpoint drags on its own plane, in one undo step.
        stroke(controller, from: SketchPlane.front.world(line.end), to: SketchPlane.front.world(.init(x: 25, y: 35)))
        let moved = try XCTUnwrap(session.workspace.shapes.first { $0.id == line.id })
        XCTAssertEqual(moved.end, .init(x: 25, y: 35))
        XCTAssertEqual(moved.start, line.start)
        session.undo()
        XCTAssertEqual(session.workspace.shapes.first { $0.id == line.id }?.end, line.end)
    }

    func testASketchHiddenInsideASolidCannotBePicked() {
        let (session, controller) = boxScene()
        // On Front (y = 0), inside the 60 × 40 × 20 box.
        session.addShape(.init(kind: .line, plane: .front, start: .init(x: -10, y: 10), end: .init(x: 10, y: 10)))
        session.select(nil)
        controller.refresh()
        tap(controller, SketchPlane.front.world(.init(x: 0, y: 10)))
        XCTAssertNotNil(session.selectedFace, "The solid face in front of the sketch is picked instead")
    }

    func testAnExtrudedSketchIsPickableWhileSketchingOnItsPlane() {
        let (session, controller) = boxScene()
        let rectangle = session.workspace.shapes[0]
        let edge = SketchPlane.top.world(.init(x: 30, y: 0))
        tap(controller, edge)
        XCTAssertNotEqual(session.selection, .shape(rectangle.id), "Outside sketch mode the solid's base hides its sketch")
        session.select(nil)
        session.chooseTool(.line)
        session.chooseTool(.select)
        controller.refresh()
        XCTAssertEqual(session.sketchMode?.plane, .top)
        XCTAssertNotNil(controller.content.childNode(withName: "shape|" + rectangle.id.uuidString, recursively: false),
                        "Sketching on its plane shows the source sketch")
        tap(controller, edge)
        XCTAssertEqual(session.selection, .shape(rectangle.id))
        attach(controller, "Extruded sketch picked in Top sketch mode")
    }

    func testItemsListSelectsASolidAndLeavesSketchMode() throws {
        let (session, controller) = boxScene()
        _ = try sketchOnFace(session, controller, at: SIMD3(5, 3, 20))
        let body = session.workspace.bodies[0]
        session.selectItem(.body(body.id))
        XCTAssertNil(session.sketchMode)
        XCTAssertEqual(session.plane, .top)
        XCTAssertEqual(session.selection, .body(body.id))
        // A picked face highlights its solid's row.
        session.select(.face(FaceSelection(bodyID: body.id, face: 0, plane: nil, center: .zero)))
        XCTAssertTrue(session.isHighlighted(ModelItem(selection: .body(body.id), name: "Body 01", icon: .solid)))
    }

    func testItemsListIsInactiveDuringAnExtrusion() {
        let (session, _) = boxScene()
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 60, y: 0), end: .init(x: 65, y: 0)))
        session.beginExtrusion()
        XCTAssertFalse(session.canSelectItems)
        session.selectItem(.body(session.workspace.bodies[0].id))
        XCTAssertTrue(session.isExtruding)
        XCTAssertEqual(session.selection, .shape(session.workspace.shapes[1].id))
    }
}
