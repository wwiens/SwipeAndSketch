import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// X-ray (October 24, 2026): solids drawn see-through, and taps passing through an X-rayed solid.
@MainActor final class XrayToolTests: CanvasTestCase {
    /// The 60 × 40 × 20 box with a small block standing inside it (a part in an enclosure).
    func enclosure() throws -> (ModelingSession, CanvasController, outer: UUID, inner: UUID) {
        let (session, controller) = boxScene()
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        session.choosePlane(top)
        session.addShape(.init(kind: .rectangle, plane: top, start: top.coordinates(of: [-5, -5, 20]), end: top.coordinates(of: [5, 5, 20])))
        session.beginExtrusion()
        session.chooseExtrusionMode(.newBody)
        session.extrusionDepth = 10
        session.confirmExtrusion()
        session.chooseTool(.select)
        session.select(nil)
        controller.refresh()
        return (session, controller, session.workspace.bodies[0].id, session.workspace.bodies[1].id)
    }

    func bodyNode(_ controller: CanvasController, _ id: UUID) throws -> SCNNode {
        try XCTUnwrap(controller.content.childNode(withName: "body|" + id.uuidString, recursively: false))
    }

    func testXrayAllDrawsEverySolidSeeThroughAndChangesNothing() throws {
        let (session, controller, outer, inner) = try enclosure()
        let before = session.workspace
        XCTAssertEqual(try bodyNode(controller, outer).geometry?.materials.first?.transparency, 1)
        session.xrayAll = true
        controller.refresh()
        for id in [outer, inner] {
            let material = try XCTUnwrap(try bodyNode(controller, id).geometry?.materials.first)
            XCTAssertLessThan(material.transparency, 0.5)
            XCTAssertFalse(material.writesToDepthBuffer)
        }
        XCTAssertEqual(session.helpTopic, .xray)
        attach(controller, "X-ray on every solid")
        XCTAssertEqual(session.workspace, before, "A view only")
        XCTAssertFalse(session.history.canRedo)
        session.xrayAll = false
        controller.refresh()
        XCTAssertEqual(try bodyNode(controller, outer).geometry?.materials.first?.transparency, 1)
    }

    func testATapGoesThroughAnXrayedSolidToThePartBehindIt() throws {
        let (session, controller, outer, inner) = try enclosure()
        // The small block stands on the box's top: a tap on the block's top reaches the box under it
        // while the block is X-rayed.
        session.toggleXray(.body(inner))
        XCTAssertTrue(session.isXrayed(.body(inner)))
        XCTAssertFalse(session.isXrayed(.body(outer)))
        controller.refresh()
        tap(controller, SIMD3(0, 0, 30))
        XCTAssertEqual(session.selectedFace?.bodyID, outer, "Through the X-rayed block to the box under it")
        session.toggleXray(.body(inner))
        session.select(nil)
        controller.refresh()
        tap(controller, SIMD3(0, 0, 30))
        XCTAssertEqual(session.selectedFace?.bodyID, inner)
    }
}
