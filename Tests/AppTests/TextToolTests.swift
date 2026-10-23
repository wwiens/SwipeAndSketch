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
}
