import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Split Body through the real Pencil pipeline.
@MainActor final class SplitToolTests: CanvasTestCase {
    /// A 60 × 40 × 20 box on Top (x −30…30, y −20…20, z 0…20) in the default 3D view.
    override func boxScene() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
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


    func volumes(_ session: ModelingSession, _ workspace: Workspace) throws -> [Double] {
        try workspace.bodies.map { try SolidKernel.solid(for: $0).volume.rounded() }
    }


    func testSelectedSolidSplitsWithATappedConstructionPlane() throws {
        let (session, controller) = boxScene()
        // A plane at x = 10, from the Right plane.
        session.chooseTool(.offsetPlane)
        session.pickPlaneReference(.world(.right))
        session.setPlaneOffset(10)
        session.confirmPlane()
        let bodyID = session.workspace.bodies[0].id
        session.select(.body(bodyID))
        session.chooseTool(.split)
        controller.refresh()
        XCTAssertEqual(session.tool, .split)
        XCTAssertEqual(session.splitDraft?.bodies, [bodyID], "The selected solid is the one to split")
        XCTAssertEqual(session.splitDraft?.step, .tools)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "split.bodies", recursively: false))
        tap(controller, SIMD3(10, 0, 30))
        XCTAssertEqual(session.splitDraft?.tools.count, 1)
        XCTAssertEqual(session.splitPieceCount, 2)
        let preview = try XCTUnwrap(session.splitPreview)
        XCTAssertEqual(try volumes(session, preview), [16_000, 32_000])
        XCTAssertNotNil(controller.previewNode.childNode(withName: "split.tool", recursively: false))
        attach(controller, "Split preview")
        XCTAssertEqual(session.workspace.bodies.count, 1, "A preview until Done")
        session.confirmSplit()
        controller.refresh()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        XCTAssertFalse(session.workspace.bodies.contains { $0.id == bodyID }, "The original is replaced")
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id))
        XCTAssertEqual(session.tool, .select)
        session.undo()
        XCTAssertEqual(session.workspace.bodies.map(\.id), [bodyID], "One undo step")
    }

    func testPickedSolidsAndKeepOriginals() throws {
        let (session, controller) = boxScene()
        let bodyID = session.workspace.bodies[0].id
        session.chooseTool(.split)
        XCTAssertEqual(session.splitDraft?.step, .bodies)
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertEqual(session.splitDraft?.bodies, [bodyID])
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertEqual(session.splitDraft?.bodies, [], "A second tap unpicks it")
        tap(controller, SIMD3(5, 3, 20))
        session.chooseSplitStep(.tools)
        session.toggleSplitTool(try XCTUnwrap(SplitTool.reference(.world(.right), in: session.workspace)))
        session.toggleSplitTool(try XCTUnwrap(SplitTool.reference(.world(.front), in: session.workspace)))
        XCTAssertEqual(session.splitPieceCount, 4, "Two planes quarter the box")
        session.setKeepOriginals(true)
        XCTAssertEqual(session.splitPreview?.bodies.count, 5)
        session.confirmSplit()
        XCTAssertEqual(session.workspace.bodies.count, 5)
        XCTAssertEqual(session.workspace.bodies[0].id, bodyID, "The original stays")
        XCTAssertEqual(try volumes(session, session.workspace).dropFirst().reduce(0, +), 48_000, accuracy: 4)
    }

    func testRegionsLinesAndMisses() throws {
        let (session, controller) = boxScene()
        let bodyID = session.workspace.bodies[0].id
        session.select(.body(bodyID))
        session.chooseTool(.split)
        // A plane past the solid does not cut it.
        let away = try XCTUnwrap(SketchPlane.through(.init(100, 0, 0), normal: .init(1, 0, 0)))
        session.toggleSplitTool(SplitTool(source: .world(away), plane: away))
        XCTAssertNil(session.splitPreview)
        XCTAssertTrue(session.hint.hasPrefix("That does not cut through"))
        session.cancelSplit()
        XCTAssertNil(session.splitDraft)
        // A sketch line drawn across the top face, tapped on the canvas, splits along it.
        session.select(nil)
        tap(controller, SIMD3(-5, -3, 20))
        session.beginFaceSketch()
        let facePlane = try XCTUnwrap(session.sketchMode?.plane)
        session.addShape(SketchShape(kind: .line, plane: facePlane, start: facePlane.coordinates(of: .init(-10, -40, 20)),
                                     end: facePlane.coordinates(of: .init(-10, 40, 20))))
        session.exitSketch()
        session.select(.body(bodyID))
        session.chooseTool(.split)
        controller.refresh()
        tap(controller, SIMD3(-10, 30, 20))
        XCTAssertEqual(session.splitDraft?.tools.first.map { if case .line = $0.source { true } else { false } }, true)
        XCTAssertEqual(try volumes(session, try XCTUnwrap(session.splitPreview)).sorted(), [20 * 40 * 20, 40 * 40 * 20])
    }
}
