import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Revolve: a region or flat face turned about a sketch line, solid edge, or world axis.
@MainActor final class RevolveToolTests: XCTestCase {
    func canvas(_ session: ModelingSession) -> CanvasController {
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.layoutIfNeeded()
        controller.refresh()
        return controller
    }

    func tap(_ controller: CanvasController, at screen: CGPoint) {
        controller.pencilBegan(at: screen); controller.pencilEnded(at: screen, cancelled: false); controller.refresh()
    }

    /// A 10 × 10 rectangle 5 mm beside a line (u = 0) on `plane`, with the rectangle selected.
    func ringScene(_ plane: SketchPlane) throws -> (ModelingSession, CanvasController, line: SketchShape) {
        let session = ModelingSession(inMemory: true)
        session.choosePlane(plane)
        session.snapEnabled = false
        let rectangle = SketchShape(kind: .rectangle, plane: plane, start: .init(x: 5, y: 0), end: .init(x: 15, y: 10))
        let line = SketchShape(kind: .line, plane: plane, start: .init(x: 0, y: -5), end: .init(x: 0, y: 20))
        session.addShape(rectangle)
        session.addShape(line)
        session.select(.shape(rectangle.id))
        XCTAssertTrue(session.canExtrude)
        return (session, canvas(session), line)
    }

    func testRegionRevolvesAboutATappedLineIntoASolidAsOneUndoStep() throws {
        for plane in SketchPlane.allCases {
            let (session, controller, line) = try ringScene(plane)
            session.beginRevolve()
            controller.refresh()
            XCTAssertTrue(session.isRevolving)
            XCTAssertEqual(session.tool, .revolve)
            XCTAssertNil(controller.revolveHandle(), "No arrow until the axis is picked")
            XCTAssertTrue(session.hint.contains("axis"), session.hint)

            tap(controller, at: controller.project(plane.world(Point2(x: 0, y: 7.5))))
            let axis = try XCTUnwrap(session.revolveDraft?.axis, "\(plane)")
            XCTAssertEqual(axis.from.x, 0, accuracy: 1e-9); XCTAssertEqual(axis.to.x, 0, accuracy: 1e-9)
            XCTAssertEqual(simd_distance(axis.start, plane.point(line.start)), 0, accuracy: 1e-9)
            XCTAssertNotNil(controller.previewNode.childNode(withName: "revolve.axis", recursively: true), "The axis shows dashed")
            XCTAssertEqual(session.revolveDraft?.angle, 0)
            XCTAssertFalse(session.canConfirmRevolve, "Nothing to make at 0°")

            // Drag the curved arrow forward: the angle grows from 0.
            let handle = try XCTUnwrap(controller.revolveHandle())
            XCTAssertGreaterThanOrEqual(handle.arc.count, 2)
            let ahead = CGPoint(x: handle.center.x + handle.axis.dx * 80, y: handle.center.y + handle.axis.dy * 80)
            controller.pencilBegan(at: handle.center)
            controller.pencilMoved(to: ahead)
            controller.pencilEnded(at: ahead, cancelled: false)
            controller.refresh()
            let dragged = try XCTUnwrap(session.revolveDraft?.angle)
            XCTAssertGreaterThan(dragged, 5, "\(plane)")
            XCTAssertEqual(dragged * 10, (dragged * 10).rounded(), accuracy: 1e-9, "Without snapping, tenths of a degree")
            XCTAssertNotNil(controller.previewNode.childNode(withName: "revolve.preview", recursively: true))
            let label = try XCTUnwrap(controller.dimensionAnnotations().first)
            XCTAssertEqual(label.target, .revolveAngle)
            XCTAssertEqual(label.value, dragged)
            XCTAssertEqual(label.text, "\(formatted(dragged))°")

            // The keypad sets an exact full turn.
            XCTAssertFalse(session.applyDimension(400, target: .revolveAngle))
            XCTAssertTrue(session.applyDimension(360, target: .revolveAngle))
            XCTAssertEqual(session.revolveDraft?.mode, .newBody)
            XCTAssertTrue(session.canConfirmRevolve)
            session.confirmRevolve()
            XCTAssertFalse(session.isRevolving)
            XCTAssertEqual(session.tool, .select)
            let body = try XCTUnwrap(session.workspace.bodies.first)
            XCTAssertEqual(body.revolve?.angle, 360)
            XCTAssertEqual(session.selection, .body(body.id))
            XCTAssertEqual(try SolidKernel.solid(for: body).volume, .pi * (225 - 25) * 10, accuracy: 1e-6)
            session.undo()
            XCTAssertTrue(session.workspace.bodies.isEmpty, "One undo step")
            XCTAssertEqual(session.workspace.shapes.count, 2)
        }
    }

    func testDraggingBackPassesZeroAndCancelRestores() throws {
        let (session, controller, _) = try ringScene(.front)
        session.snapEnabled = true
        session.beginRevolve()
        controller.refresh()
        tap(controller, at: controller.project(SketchPlane.front.world(Point2(x: 0, y: 7.5))))
        XCTAssertTrue(session.applyDimension(30, target: .revolveAngle))
        controller.refresh()
        let handle = try XCTUnwrap(controller.revolveHandle())
        let back = CGPoint(x: handle.center.x - handle.axis.dx * 400, y: handle.center.y - handle.axis.dy * 400)
        controller.pencilBegan(at: handle.center)
        controller.pencilMoved(to: back)
        XCTAssertLessThan(session.revolveDraft?.angle ?? 0, 0, "Back through 0° turns the other way")
        XCTAssertEqual(session.revolveDraft?.angle, session.revolveDraft?.angle.rounded(), "Snapping keeps whole degrees")
        controller.pencilEnded(at: back, cancelled: true)
        XCTAssertEqual(session.revolveDraft?.angle, 30, "A canceled drag restores the angle")
        session.cancelRevolve()
        controller.refresh()
        XCTAssertNil(controller.revolveHandle())
        XCTAssertTrue(session.workspace.bodies.isEmpty)
        XCTAssertNil(controller.previewNode.childNode(withName: "revolve.preview", recursively: true))
        session.undo()
        XCTAssertEqual(session.workspace.shapes.count, 1, "Cancel adds no history")
    }

    func testAxisMustLieInThePlaneAndBesideTheRegion() throws {
        let (session, _, _) = try ringScene(.top)
        session.beginRevolve()
        session.pickRevolveAxis((SIMD3(10, -5, 0), SIMD3(10, 20, 0)))
        XCTAssertNil(session.revolveDraft?.axis)
        XCTAssertTrue(session.hint.contains("crosses"), session.hint)
        session.pickRevolveAxis((SIMD3(0, 0, 5), SIMD3(0, 1, 5)))
        XCTAssertNil(session.revolveDraft?.axis)
        XCTAssertTrue(session.hint.contains("plane"), session.hint)
        session.pickRevolveAxis(nil)
        XCTAssertTrue(session.hint.contains("not straight"), session.hint)
        // A world axis in the plane is fine.
        session.pickRevolveAxis((.zero, SIMD3(0, 1, 0)))
        XCTAssertNotNil(session.revolveDraft?.axis)
        XCTAssertFalse(session.hint.contains("crosses"))
    }

    func testRectangleSideWorldAxisAndSolidEdgeCanBeTapped() throws {
        // One side of the region's own rectangle: a solid cylinder.
        do {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(.front)
            let square = SketchShape(kind: .rectangle, plane: .front, start: .init(x: 0, y: 0), end: .init(x: 10, y: 10))
            session.addShape(square)
            session.select(.shape(square.id))
            let controller = canvas(session)
            session.beginRevolve()
            controller.refresh()
            tap(controller, at: controller.project(SketchPlane.front.world(Point2(x: 0, y: 4))))
            let axis = try XCTUnwrap(session.revolveDraft?.axis)
            XCTAssertEqual(axis.from.x, 0, accuracy: 1e-9); XCTAssertEqual(axis.to.x, 0, accuracy: 1e-9)
            XCTAssertTrue(session.applyDimension(360, target: .revolveAngle))
            session.confirmRevolve()
            XCTAssertEqual(try SolidKernel.solid(for: XCTUnwrap(session.workspace.bodies.first)).volume, .pi * 100 * 10, accuracy: 1e-6)
        }
        // The world Y axis, tapped well away from the sketch.
        do {
            let session = ModelingSession(inMemory: true)
            let bar = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 5, y: -2), end: .init(x: 10, y: 2))
            session.addShape(bar)
            session.select(.shape(bar.id))
            let controller = canvas(session)
            session.beginRevolve()
            controller.refresh()
            tap(controller, at: controller.project(SIMD3(0, -40, 0)))
            let axis = try XCTUnwrap(session.revolveDraft?.axis)
            XCTAssertEqual(axis.start, .zero)
            XCTAssertEqual(axis.end, SIMD3(0, 1, 0))
        }
        // A solid's straight edge on the region's plane (a box hanging below Top).
        do {
            let session = ModelingSession(inMemory: true)
            session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10)))
            session.beginExtrusion(); session.extrusionDepth = -10; session.confirmExtrusion()
            let tab = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 14, y: -5), end: .init(x: 18, y: 5))
            session.addShape(tab)
            session.select(.shape(tab.id))
            let controller = canvas(session)
            session.beginRevolve()
            controller.refresh()
            tap(controller, at: controller.project(SIMD3(10, 3, 0)))
            let axis = try XCTUnwrap(session.revolveDraft?.axis, session.hint)
            XCTAssertEqual(axis.from.x, 10, accuracy: 1e-6); XCTAssertEqual(axis.to.x, 10, accuracy: 1e-6)
            XCTAssertTrue(session.applyDimension(90, target: .revolveAngle))
            XCTAssertEqual(session.revolveDraft?.mode, .newBody, "Turned up off the box's top edge, it does not touch the box")
            session.confirmRevolve()
            XCTAssertEqual(session.workspace.bodies.count, 2)
        }
    }

    func testRevolvingIntoASolidCutsItAndTouchingOneJoinsIt() throws {
        for (low, high, mode, change) in [(15.0, 25.0, ExtrusionMode.cut, -Double.pi * 25 * 5), (20, 25, .join, Double.pi * 25 * 5)] {
            let session = ModelingSession(inMemory: true)
            session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
            session.beginExtrusion()
            session.extrusionDepth = 20
            session.confirmExtrusion()
            // A Front-plane rectangle against the Z axis, turned all the way around it.
            let pin = SketchShape(kind: .rectangle, plane: .front, start: .init(x: 0, y: low), end: .init(x: 5, y: high))
            session.choosePlane(.front)
            session.addShape(pin)
            session.select(.shape(pin.id))
            session.beginRevolve()
            session.pickRevolveAxis((.zero, SIMD3(0, 0, 1)))
            XCTAssertTrue(session.applyDimension(360, target: .revolveAngle))
            XCTAssertEqual(session.revolveDraft?.mode, mode, "Automatic, like Extrude")
            XCTAssertTrue(session.canConfirmRevolve)
            let box = session.workspace.bodies[0]
            XCTAssertEqual(try SolidKernel.solid(for: session.displayWorkspace.bodies[0]).volume, 48_000 + change, accuracy: 1e-3, "Live preview")
            session.confirmRevolve()
            XCTAssertEqual(session.workspace.bodies.count, 1)
            XCTAssertEqual(session.selection, .body(box.id))
            XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, 48_000 + change, accuracy: 1e-3)
            session.undo()
            XCTAssertEqual(session.workspace.bodies[0], box, "One undo step")
        }
        // Choosing New Body keeps it separate.
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion(); session.extrusionDepth = 20; session.confirmExtrusion()
        let pin = SketchShape(kind: .rectangle, plane: .front, start: .init(x: 0, y: 20), end: .init(x: 5, y: 25))
        session.choosePlane(.front)
        session.addShape(pin)
        session.select(.shape(pin.id))
        session.beginRevolve()
        session.pickRevolveAxis((.zero, SIMD3(0, 0, 1)))
        XCTAssertTrue(session.applyDimension(360, target: .revolveAngle))
        session.chooseRevolveMode(.newBody)
        XCTAssertEqual(session.revolveDraft?.mode, .newBody)
        session.confirmRevolve()
        XCTAssertEqual(session.workspace.bodies.count, 2)
    }

    func testAFlatFaceRevolvesAboutItsEdgeAndJoinsItsSolid() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10)))
        session.beginExtrusion(); session.extrusionDepth = 10; session.confirmExtrusion()
        let controller = canvas(session)
        session.requestCamera(.reset)
        controller.refresh()
        tap(controller, at: controller.project(SIMD3(2, 1, 10)))
        XCTAssertTrue(session.canExtrudeSelectedFace)
        session.beginRevolve()
        controller.refresh()
        XCTAssertNotNil(session.revolveDraft?.face)
        XCTAssertNotNil(controller.content.childNode(withName: "face.extrusion", recursively: false), "The face is amber")
        // About the top face's back edge.
        session.pickRevolveAxis((SIMD3(-10, 10, 10), SIMD3(10, 10, 10)))
        XCTAssertTrue(session.applyDimension(90, target: .revolveAngle))
        XCTAssertEqual(session.revolveDraft?.mode, .join, "Out of the solid joins it")
        session.confirmRevolve()
        XCTAssertEqual(session.workspace.bodies.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, 4_000 + .pi * 400 / 4 * 20, accuracy: 1e-3)
        XCTAssertTrue(session.applyDimension(-90, target: .revolveAngle) == false, "Nothing is being revolved now")
    }

    func testSelectedRevolvedSolidShowsItsAngleForTheKeypad() throws {
        let (session, controller, _) = try ringScene(.top)
        session.beginRevolve()
        session.pickRevolveAxis((.zero, SIMD3(0, 1, 0)))
        XCTAssertTrue(session.applyDimension(270, target: .revolveAngle))
        session.confirmRevolve()
        controller.refresh()
        let body = try XCTUnwrap(session.selectedBody)
        let label = try XCTUnwrap(controller.dimensionAnnotations().first)
        XCTAssertEqual(label.target, .bodyAngle(body.id))
        XCTAssertEqual(label.value, 270)
        XCTAssertTrue(session.applyDimension(-90, target: .bodyAngle(body.id)))
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, .pi * 200 * 10 / 4, accuracy: 1e-6)
        XCTAssertFalse(session.applyDimension(0.05, target: .bodyAngle(body.id)))
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].revolve?.angle, 270)
    }

    func testRevolveToolPicksTheRegionFirst() throws {
        let session = ModelingSession(inMemory: true)
        session.choosePlane(.front)
        let square = SketchShape(kind: .rectangle, plane: .front, start: .init(x: 5, y: 0), end: .init(x: 15, y: 10))
        session.addShape(square)
        session.select(nil)
        let controller = canvas(session)
        session.chooseTool(.revolve)
        XCTAssertFalse(session.isRevolving)
        XCTAssertTrue(session.hint.contains("region"), session.hint)
        tap(controller, at: controller.project(SketchPlane.front.world(Point2(x: 10, y: 5))))
        XCTAssertTrue(session.isRevolving, "Tapping a region with Revolve starts it")
        XCTAssertEqual(session.revolveDraft?.profile.sourceIDs, [square.id])
    }
}
