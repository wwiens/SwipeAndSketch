import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Construction planes (Offset Plane and Midplane) through the real Pencil pipeline.
@MainActor final class ConstructionPlaneToolTests: CanvasTestCase {
    /// A 60 × 40 × 20 box on Top (z 0…20) in the default 3D view.
    override func boxScene() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        return (session, canvas(session))
    }




    /// Offset Plane from the box's top face, 15 mm up.
    func planeAboveTheBox(_ session: ModelingSession, _ controller: CanvasController) throws -> ConstructionPlane {
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        session.chooseTool(.offsetPlane)
        XCTAssertTrue(session.applyDimension(15, target: .planeOffset))
        session.confirmPlane()
        controller.refresh()
        return try XCTUnwrap(session.workspace.constructionPlanes.last)
    }

    func testOffsetPlaneFromASelectedFaceStartsOnItAndDragsUp() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        session.chooseTool(.offsetPlane)
        controller.refresh()
        XCTAssertEqual(session.planeDraft?.references.count, 1, "The selected face is the reference")
        XCTAssertEqual(session.planeDraft?.offset, 0, "Starts on the face")
        XCTAssertEqual(session.planePreview?.plane.origin.z ?? 0, 20, accuracy: 1e-9)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "plane.preview", recursively: false))
        let handle = try XCTUnwrap(controller.planeHandle())
        XCTAssertLessThan(handle.axis.dy, -0.9, "The arrow points up, out of the top face")
        XCTAssertEqual(controller.dimensionAnnotations().first?.target, .planeOffset)
        controller.pencilBegan(at: handle.center)
        controller.pencilMoved(to: CGPoint(x: handle.center.x, y: handle.center.y - 40))
        controller.pencilEnded(at: CGPoint(x: handle.center.x, y: handle.center.y - 40), cancelled: false)
        XCTAssertGreaterThan(session.planeDraft?.offset ?? 0, 1)
        XCTAssertTrue(session.applyDimension(15, target: .planeOffset))
        XCTAssertEqual(session.planePreview?.plane.origin.z ?? 0, 35, accuracy: 1e-9)
        attach(controller, "Offset plane preview")
        XCTAssertTrue(session.workspace.constructionPlanes.isEmpty, "A preview until Done")
        session.confirmPlane()
        controller.refresh()
        let plane = try XCTUnwrap(session.workspace.constructionPlanes.first)
        XCTAssertEqual(plane.plane.origin.z, 35, accuracy: 1e-9)
        XCTAssertEqual(session.selection, .plane(plane.id))
        XCTAssertEqual(session.tool, .select)
        XCTAssertNotNil(controller.content.childNode(withName: "plane|" + plane.id.uuidString, recursively: false))
        attach(controller, "Construction plane above the box")
        session.undo()
        XCTAssertTrue(session.workspace.constructionPlanes.isEmpty, "One undo step")
    }

    func testOffsetPlaneFromAWorldPlaneAndCancel() throws {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session)
        session.chooseTool(.offsetPlane)
        controller.refresh()
        XCTAssertNotNil(controller.previewNode.childNode(withName: "plane.reference.top", recursively: false), "World planes are offered")
        tap(controller, SIMD3(18, -18, 0))
        XCTAssertEqual(session.planeDraft?.references.first?.source, .world(.top))
        XCTAssertTrue(session.applyDimension(-10, target: .planeOffset), "Below is a negative offset")
        XCTAssertEqual(session.planePreview?.plane.origin.z ?? 0, -10, accuracy: 1e-9)
        session.cancelPlane()
        XCTAssertNil(session.planeDraft)
        XCTAssertTrue(session.workspace.constructionPlanes.isEmpty)
        XCTAssertFalse(session.history.canUndo)
    }

    func testMidplaneBetweenTheTopFaceAndTheGround() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.midplane)
        controller.refresh()
        tap(controller, SIMD3(5, 3, 20))          // the box's top face
        XCTAssertNil(session.planePreview, "Needs two")
        tap(controller, SIMD3(25, -27, 0))        // the Top plane square, clear of the box
        XCTAssertEqual(session.planeDraft?.references.count, 2)
        XCTAssertEqual(session.planePreview?.plane.origin.z ?? 0, 10, accuracy: 1e-9)
        attach(controller, "Midplane preview")
        // A face at an angle cannot pair: it replaces the second pick and there is no plane.
        tap(controller, SIMD3(0, -20, 10))        // the front face
        XCTAssertEqual(session.planeDraft?.references.count, 2)
        XCTAssertNil(session.planePreview)
        XCTAssertTrue(session.hint.contains("not parallel"))
        tap(controller, SIMD3(0, -20, 10))        // tapping it again unpicks it
        XCTAssertEqual(session.planeDraft?.references.count, 1)
        tap(controller, SIMD3(25, -27, 0))
        session.confirmPlane()
        XCTAssertEqual(session.workspace.constructionPlanes.first?.plane.origin.z ?? 0, 10, accuracy: 1e-9)
    }

    func testSketchingOnAConstructionPlane() throws {
        let (session, controller) = boxScene()
        let plane = try planeAboveTheBox(session, controller)
        session.chooseTool(.rectangle)
        XCTAssertEqual(session.sketchMode?.constructionPlane, plane.id)
        XCTAssertEqual(session.sketchMode?.title, "Plane sketch")
        XCTAssertEqual(session.plane, plane.plane)
        controller.refresh()
        XCTAssertEqual(-controller.cameraNode.simdWorldFront.z, 1, accuracy: 1e-3, "Looks straight at the plane")
        session.addShape(SketchShape(kind: .rectangle, plane: session.plane, start: .init(x: -5, y: -5), end: .init(x: 5, y: 5)))
        let profile = try XCTUnwrap(session.workspace.profiles.first { $0.plane == plane.plane })
        let solid = try SolidKernel.solid(for: SolidBody(profile: profile, depth: 5))
        XCTAssertEqual(solid.bounds.min.z, 35, accuracy: 1e-9, "Drawn 35 mm up")
        // The Sketch tile picks construction planes too.
        session.exitSketch()
        session.select(nil)
        session.beginSketch()
        controller.refresh()
        tap(controller, SIMD3(20, -15, 35))
        XCTAssertEqual(session.sketchMode?.constructionPlane, plane.id)
    }

    func testPlanesAreSelectedListedHiddenAndDeleted() throws {
        let (session, controller) = boxScene()
        let plane = try planeAboveTheBox(session, controller)
        session.select(nil)
        controller.refresh()
        // A tap inside the plane, above the box, picks the plane.
        tap(controller, SIMD3(10, -10, 35))
        XCTAssertEqual(session.selection, .plane(plane.id))
        XCTAssertEqual(session.selectedPlaneReference?.source, .plane(plane.id))
        let row = try XCTUnwrap(session.itemGroups.first { $0.title == "Planes" }?.items.first)
        XCTAssertEqual(row.name, "Plane 01")
        XCTAssertEqual(row.isHidden, false)
        XCTAssertTrue(session.isHighlighted(row))
        session.toggleHidden(row.selection)
        controller.refresh()
        XCTAssertNil(controller.content.childNode(withName: "plane|" + plane.id.uuidString, recursively: false))
        XCTAssertNil(session.selection)
        session.toggleHidden(row.selection)
        session.select(.plane(plane.id))
        session.deleteSelection()
        XCTAssertTrue(session.workspace.constructionPlanes.isEmpty)
        XCTAssertEqual(session.workspace.bodies.count, 1, "Deleting a plane leaves the solid")
    }

    /// Delete with a face or edge selected never removes the solid (someone removing a fillet would
    /// lose the part); the trash is offered for whole items only.
    func testDeleteIgnoresAFaceOrEdgeSelection() {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        XCTAssertFalse(session.canDeleteSelection)
        session.deleteSelection()
        XCTAssertEqual(session.workspace.bodies.count, 1)
        let body = session.workspace.bodies[0]
        session.select(.edge(body.id, PickedEdge(index: 0, name: nil, point: .zero)))
        session.deleteSelection()
        XCTAssertEqual(session.workspace.bodies.count, 1)
        session.select(.body(body.id))
        XCTAssertTrue(session.canDeleteSelection)
        session.deleteSelection()
        XCTAssertTrue(session.workspace.bodies.isEmpty)
    }
}
