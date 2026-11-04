import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Mirror through the real Pencil pipeline.
@MainActor final class MirrorToolTests: CanvasTestCase {
    /// A 40 × 40 × 20 box on Top (x 10…50, y −20…20, z 0…20), off the origin so mirrors move it,
    /// in the default 3D view.
    override func boxScene() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 10, y: -20), end: .init(x: 50, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.layoutIfNeeded()
        session.requestCamera(.home)
        controller.refresh()
        return (session, controller)
    }


    func bounds(_ body: SolidBody) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try SolidKernel.solid(for: body).bounds }


    func testSelectedSolidMirrorsAcrossItsOwnFaceAsANewSolid() throws {
        let (session, controller) = boxScene()
        let original = session.workspace.bodies[0]
        session.select(.body(original.id))
        session.chooseTool(.mirror)
        controller.refresh()
        XCTAssertEqual(session.tool, .mirror)
        XCTAssertEqual(session.mirrorDraft?.bodies, [original.id], "The selected solid is the one to mirror")
        XCTAssertEqual(session.mirrorDraft?.step, .plane)
        XCTAssertEqual(session.mirrorDraft?.keepOriginals, true, "Keep Input starts on")
        XCTAssertNotNil(controller.previewNode.childNode(withName: "mirror.items", recursively: false))
        // The end face at x = 50 is the mirror plane.
        tap(controller, SIMD3(50, 0, 10))
        XCTAssertEqual(session.mirrorDraft?.plane?.plane.normalAxis.x ?? 0, 1, accuracy: 1e-9)
        let preview = try XCTUnwrap(session.mirrorPreview)
        XCTAssertEqual(preview.bodies.count, 2)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "mirror.plane", recursively: false))
        attach(controller, "Mirror preview")
        XCTAssertEqual(session.workspace.bodies.count, 1, "A preview until Done")
        session.confirmMirror()
        controller.refresh()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        XCTAssertEqual(session.workspace.bodies[0], original, "The original stays")
        let image = session.workspace.bodies[1]
        XCTAssertEqual(try bounds(image).min.x, 50, accuracy: 1e-6)
        XCTAssertEqual(try bounds(image).max.x, 90, accuracy: 1e-6)
        XCTAssertEqual(session.selection, .body(image.id), "The mirror image is selected")
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(session.itemGroups.first?.items.map(\.name), ["Body 01", "Body 02"])
        attach(controller, "Mirrored solid")
        // The mirror image is an ordinary solid: its edges can be rounded.
        let edge = try XCTUnwrap(image.extrusionEdges.first { $0.position == .side })
        session.select(.edge(image.id, try XCTUnwrap(PickedEdge.named(edge, on: image))))
        session.finishSelectedEdge(.fillet)
        session.setFinishSize(3)
        session.confirmFinish()
        XCTAssertEqual(session.workspace.bodies[1].finishes.count, 1)
        session.undo()
        session.undo()
        XCTAssertEqual(session.workspace.bodies.map(\.id), [original.id], "Mirror is one undo step")
    }

    func testTappedSolidAndSketchReplacedAcrossAWorldPlane() throws {
        let (session, controller) = boxScene()
        session.addShape(.init(kind: .line, plane: .top, start: .init(x: 10, y: -28), end: .init(x: 25, y: -28)))
        let bodyID = session.workspace.bodies[0].id
        let line = try XCTUnwrap(session.workspace.shapes.first { $0.kind == .line })
        let sketchID = try XCTUnwrap(line.sketch)
        session.select(nil)
        session.chooseTool(.mirror)
        controller.refresh()
        XCTAssertEqual(session.mirrorDraft?.step, .items)
        tap(controller, SIMD3(30, 3, 20))
        XCTAssertEqual(session.mirrorDraft?.bodies, [bodyID], "A tap on a face picks its solid")
        tap(controller, SIMD3(17.5, -28, 0))
        XCTAssertEqual(session.mirrorDraft?.sketches, [sketchID], "A tap on a line picks its sketch")
        tap(controller, SIMD3(30, 3, 20))
        XCTAssertEqual(session.mirrorDraft?.bodies, [], "A second tap unpicks")
        tap(controller, SIMD3(30, 3, 20))
        XCTAssertNil(session.mirrorPreview, "No plane yet")
        session.chooseMirrorStep(.plane)
        session.setMirrorKeepOriginals(false)
        controller.refresh()
        // The Right plane at the origin, beside the box.
        tap(controller, SIMD3(0, -10, 28))
        XCTAssertEqual(session.mirrorDraft?.plane?.source, .world(.right))
        attach(controller, "Mirror across the Right plane")
        session.confirmMirror()
        controller.refresh()
        XCTAssertEqual(session.workspace.bodies.map(\.id), [bodyID], "Replaced in place")
        XCTAssertEqual(try bounds(session.workspace.bodies[0]).min.x, -50, accuracy: 1e-6)
        XCTAssertEqual(try bounds(session.workspace.bodies[0]).max.x, -10, accuracy: 1e-6)
        let moved = try XCTUnwrap(session.workspace.shapes.first { $0.id == line.id })
        XCTAssertLessThan(simd_distance(moved.plane.point(moved.start), SIMD3(-10, -28, 0)), 1e-9)
        XCTAssertLessThan(simd_distance(moved.plane.point(moved.end), SIMD3(-25, -28, 0)), 1e-9)
        XCTAssertEqual(session.workspace.sketches.map(\.id), [sketchID])
    }

    func testCancelAndTheTransformGroup() throws {
        let (session, controller) = boxScene()
        session.select(.body(session.workspace.bodies[0].id))
        session.chooseTool(.mirror)
        session.pickMirrorPlane(MirrorPlane(source: .world(.front), plane: .front))
        XCTAssertNotNil(session.mirrorPreview)
        XCTAssertTrue(session.hint.contains("Done"))
        session.cancelMirror()
        controller.refresh()
        XCTAssertNil(session.mirrorDraft)
        XCTAssertEqual(session.workspace.bodies.count, 1)
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(ToolGroup.transform.tools, [.align, .scale, .mirror, .pattern])
    }
}
