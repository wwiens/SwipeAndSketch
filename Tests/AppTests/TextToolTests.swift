import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// The Text tool through the session, canvas, and kernel.
@MainActor final class TextToolTests: CanvasTestCase {
    func testTextFromASelectedFaceIsRaisedEditedAndSunk() async throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        session.chooseTool(.text)
        XCTAssertNotNil(session.sketchMode?.face, "Text sketches on the selected face")
        XCTAssertEqual(session.tool, .text)
        controller.refresh()
        tap(controller, SIMD3(0.3, -0.2, 20))
        let draft = try XCTUnwrap(session.textDraft)
        XCTAssertEqual(draft.center, .zero, "Snapped to the face's center dot")
        XCTAssertNotNil(draft.spec, "The outline is ready at once")
        XCTAssertEqual(session.helpTopic, .text)
        await session.textPreviewSettled()
        XCTAssertNotNil(session.textPreview)
        XCTAssertEqual(Set(controller.dimensionAnnotations().map(\.target)), [.textHeight, .textDepth])

        session.setText("PLA 0.2")
        XCTAssertTrue(session.applyDimension(5, target: .textHeight))
        XCTAssertTrue(session.applyDimension(1.2, target: .textDepth))
        XCTAssertFalse(session.applyDimension(0.1, target: .textHeight))
        session.setTextFont("Courier-Bold")
        await session.textPreviewSettled()
        attach(controller, "Raised PLA 0.2 text on the top face")
        session.confirmText()
        XCTAssertNil(session.textDraft)
        XCTAssertEqual(session.tool, .text, "Ready for more text")
        XCTAssertEqual(session.status, "Text raised")
        let raised = try XCTUnwrap(session.workspace.bodies[0].cuts.last)
        XCTAssertEqual(raised.text?.text, "PLA 0.2")
        XCTAssertEqual(raised.depth, 1.2)
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).bounds.max.z, 21.2, accuracy: 1e-6)

        // The next text starts from the last one's settings; this one is sunk and turned.
        controller.refresh()
        tap(controller, SIMD3(-15, 10, 20))
        session.setTextRaised(false)
        session.rotateText()
        XCTAssertEqual(session.textDraft?.angle, 90)
        XCTAssertEqual(session.textDraft?.depth, -1.2)
        await session.textPreviewSettled()
        session.confirmText()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.depth, -1.2)
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].cuts.count, 1, "One undo step each")
    }

    func testTextOffTheFaceAndEmptyTextCannotBeConfirmed() async throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        session.chooseTool(.text)
        controller.refresh()
        tap(controller, SIMD3(0, 0, 20))
        session.setText("   ")
        XCTAssertNotNil(session.textError)
        XCTAssertNil(session.textPreview)
        session.setText("WAY TOO LONG FOR THIS BOX")
        XCTAssertTrue(session.applyDimension(40, target: .textHeight))
        await session.textPreviewSettled()
        XCTAssertNotNil(session.textError, "Letters off the face")
        session.confirmText()
        XCTAssertTrue(session.workspace.bodies[0].cuts.isEmpty)
        session.cancelText()
        XCTAssertNil(session.textDraft)
    }

    /// Embedded text (November 22, 2026): sunk, and filled flush by an inlay that is a solid of its
    /// own in another color; Edit Text from the inlay changes both, and Sunk takes the inlay away.
    func testEmbeddedTextFillsItsLettersWithAnInlayOfItsOwn() async throws {
        let (session, controller) = boxScene()
        let box = session.workspace.bodies[0], boxVolume = try SolidKernel.solid(for: box).volume
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: box.id, near: [5, 3, 20]))))
        session.chooseTool(.text)
        controller.refresh()
        let top = try XCTUnwrap(session.sketchMode?.plane)
        session.placeText(at: top.coordinates(of: [0, 0, 20]))
        session.setText("HI")
        XCTAssertTrue(session.applyDimension(10, target: .textHeight))
        XCTAssertTrue(session.applyDimension(1, target: .textDepth))
        session.setTextStyle(.embedded)
        XCTAssertEqual(session.textDraft?.depth, -1, "Embedded text is sunk")
        XCTAssertEqual(session.textDraft?.inlayColor, .black, "Black stands out on the gray box")
        session.setTextInlayColor(.red)
        await session.textPreviewSettled()
        XCTAssertEqual(session.textPreview?.bodies.count, 2, "The preview shows the inlay")
        attach(controller, "Embedded HI with a red inlay")
        session.confirmText()
        XCTAssertEqual(session.status, "Text embedded, with its inlay as a solid of its own")

        XCTAssertEqual(session.workspace.bodies.count, 2)
        let host = session.workspace.bodies[0], inlay = session.workspace.bodies[1]
        XCTAssertEqual(host.cuts.last?.depth, -1)
        XCTAssertNil(host.cuts.last?.inlay)
        XCTAssertEqual(inlay.color, .red)
        XCTAssertEqual(session.workspace.bodyNames[inlay.id], "Body 01 Inlay")
        XCTAssertEqual(session.workspace.inlays(of: try XCTUnwrap(host.cuts.last)), [inlay.id])
        // The inlay fills the letters exactly, flush with the face: together they are the box.
        let hostSolid = try SolidKernel.solid(for: host), inlaySolid = try SolidKernel.solid(for: inlay)
        XCTAssertEqual(inlaySolid.bounds.max.z, 20, accuracy: 1e-6)
        XCTAssertEqual(inlaySolid.bounds.min.z, 19, accuracy: 1e-6)
        XCTAssertGreaterThan(inlaySolid.volume, 10)
        XCTAssertEqual(hostSolid.volume + inlaySolid.volume, boxVolume, accuracy: 1e-3)

        // Files with an inlay are version 3, which earlier versions refuse rather than misread.
        let data = try ProjectCodec.encode(Project(workspace: session.workspace))
        let read = try ProjectCodec.decode(data)
        XCTAssertEqual(read.schemaVersion, Project.inlaySchemaVersion)
        XCTAssertEqual(read.workspace.bodies, session.workspace.bodies)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: Workspace(bodies: [box])))).schemaVersion, Project.currentSchemaVersion)

        // The inlay's top is the text's: Edit Text opens the sunk text, embedded, in its color.
        session.exitSketch()
        let inside = try XCTUnwrap(inlaySolid.interiorPoint())
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: inlay.id, near: [inside.x, inside.y, 20]))))
        controller.refresh()
        XCTAssertEqual(session.selectedFeature, .text(body: host.id, cut: host.cuts.count - 1))
        session.editSelectedFeature()
        let draft = try XCTUnwrap(session.textDraft)
        XCTAssertEqual(draft.bodyID, host.id)
        XCTAssertEqual(draft.style, .embedded)
        XCTAssertEqual(draft.inlayColor, .red)
        XCTAssertEqual(draft.inlay, inlay.id)
        session.setText("HIT")
        await session.textPreviewSettled()
        session.confirmText()
        XCTAssertEqual(session.workspace.bodies.map(\.id), [host.id, inlay.id], "The inlay is changed in place")
        XCTAssertEqual(session.workspace.bodies[1].inlayStep?.text?.text, "HIT")
        XCTAssertEqual(session.workspace.bodies[1].color, .red)

        // Sunk again: the inlay goes, in the same step.
        session.editText(bodyID: host.id, cut: host.cuts.count - 1)
        session.setTextStyle(.sunk)
        await session.textPreviewSettled()
        session.confirmText()
        XCTAssertEqual(session.workspace.bodies.map(\.id), [host.id])
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        session.undo()
        session.undo()
        XCTAssertEqual(session.workspace.bodies, [box], "One undo step each")
    }
}
