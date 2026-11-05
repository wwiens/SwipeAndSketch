import XCTest
import UIKit
import simd
@testable import SwipeAndSketch

@MainActor final class TrialEditingTests: CanvasTestCase {
    private func scene() -> (ModelingSession, AppAccessStore) {
        let access = AppAccessStore(testState: .trialActive(ends: Date().addingTimeInterval(60)))
        let session = ModelingSession(inMemory: true, access: access)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion(); session.extrusionDepth = 20; session.confirmExtrusion()
        return (session, access)
    }

    func testExpiredTrialBlocksNewMutationsAndKeepsViewingAndExport() throws {
        let (session, access) = scene()
        let original = session.workspace
        access.setTestState(.trialEnded)
        session.addShape(.init(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0)))
        session.addFitTest(); session.undo(); session.redo(); session.paste(); session.duplicate()
        session.deleteSelection(); session.chooseTool(.box)
        session.beginExtrusion(); session.beginPattern(); session.beginMirror(); session.beginScale()
        session.beginSketch(); session.beginEditingNotes(); session.updateNotes("not allowed")
        XCTAssertNil(session.newGroup())
        XCTAssertEqual(session.workspace, original)
        XCTAssertFalse(session.canEditNotes)
        XCTAssertTrue(session.canExport)
        XCTAssertNotNil(try ModelExport.data(.stl, bodies: original.bodies, title: "Trial project"))
        XCTAssertNotNil(try ModelExport.data(.threeMF, bodies: original.bodies, title: "Trial project"))
        session.selectItem(.body(original.bodies[0].id))
        XCTAssertEqual(session.selectedBody?.id, original.bodies[0].id)
        session.beginMeasure()
        XCTAssertTrue(session.acceptsPencil)
        XCTAssertTrue(session.isMeasuring)
    }

    func testStartedExtrusionCanCommitOneStepAfterExpiration() {
        let (session, access) = scene()
        session.selection = .shape(session.workspace.shapes[0].id)
        session.beginExtrusion(); session.extrusionDepth = 10
        session.chooseExtrusionMode(.newBody)
        XCTAssertTrue(session.isExtruding)
        let before = session.workspace
        access.setTestState(.trialEnded)
        // An unrelated new operation cannot use the pending extrusion's permission.
        session.addFitTest()
        XCTAssertEqual(session.workspace, before)
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, before.bodies.count + 1)
        let committed = session.workspace
        session.confirmExtrusion(); session.beginExtrusion(); session.confirmExtrusion()
        XCTAssertEqual(session.workspace, committed)
        access.setTestState(.purchased)
        session.undo()
        XCTAssertEqual(session.workspace, before)
    }

    func testCancelledDragRollsBackAtExpirationAndNextStrokeCannotEdit() {
        let (session, access) = scene()
        let shape = session.workspace.shapes[0], before = session.workspace
        session.isPencilDown = true
        session.beginSketchDrag(shapeID: shape.id, handle: .end)
        _ = session.updateSketchDrag(to: .init(x: 35, y: 25))
        access.setTestState(.trialEnded)
        session.finishSketchDrag(cancelled: true)
        session.isPencilDown = false
        session.beginSketchDrag(shapeID: shape.id, handle: .end)
        _ = session.updateSketchDrag(to: .init(x: 50, y: 50))
        session.finishSketchDrag(cancelled: false)
        XCTAssertEqual(session.workspace, before)
    }

    func testPencilStrokeThatStartedBeforeExpirationCommitsOnce() {
        let access = AppAccessStore(testState: .trialActive(ends: Date().addingTimeInterval(60)))
        let session = ModelingSession(inMemory: true, access: access)
        let controller = canvas(session, camera: .align(.top))
        session.chooseTool(.rectangle)
        let start = controller.project(SIMD3<Float>(-20, -10, 0)), end = controller.project(SIMD3<Float>(20, 10, 0))
        controller.pencilBegan(at: start)
        controller.pencilMoved(to: end)
        access.setTestState(.trialEnded)
        controller.pencilEnded(at: end, cancelled: false)
        XCTAssertEqual(session.workspace.shapes.count, 1)
        let saved = session.workspace
        controller.pencilBegan(at: start); controller.pencilEnded(at: end, cancelled: false)
        XCTAssertEqual(session.workspace, saved)
        access.setTestState(.purchased)
        session.undo()
        XCTAssertTrue(session.workspace.shapes.isEmpty)
    }

    func testAcceptedNotesFlushAtExpirationButFurtherTypingIsBlocked() {
        let (session, access) = scene()
        session.beginEditingNotes(); session.updateNotes("Keep this requirement")
        access.setTestState(.trialEnded)
        XCTAssertEqual(session.workspace.notes, "Keep this requirement")
        XCTAssertFalse(session.isEditingNotes)
        session.updateNotes("Do not accept this")
        XCTAssertEqual(session.workspace.notes, "Keep this requirement")
    }

    func testExistingKeypadCanFinishButAnotherDimensionCannotStart() {
        let (session, access) = scene()
        let target = DimensionTarget.bodyDepth(session.workspace.bodies[0].id)
        session.openDimension(target, at: .zero)
        access.setTestState(.trialEnded)
        let unrelated = DimensionTarget.shape(session.workspace.shapes[0].id, .width)
        XCTAssertFalse(session.canEditDimension(unrelated))
        XCTAssertTrue(session.applyDimension(15, target: target))
        XCTAssertEqual(session.workspace.bodies[0].depth, 15)
        XCTAssertFalse(session.applyDimension(16, target: target))
    }

    func testAssistantRequestBegunAfterExpirationCannotCreateDraft() async throws {
        let (session, access) = scene()
        let original = session.workspace
        access.setTestState(.trialEnded)
        let assistant = AssistantController(session: session)
        assistant.responder = { _, workspace, _, _, _, _ in
            var bench = AssistantWorkbench(workspace: workspace)
            try bench.setDimension(item: "Body 01", dimension: "depth", value: 10)
            return AssistantEngine.Turn(reply: "Changed it", bench: bench, backend: .onDevice)
        }
        assistant.send("Make it 10 mm")
        while assistant.isWorking { await Task.yield() }
        assistant.keep()
        XCTAssertFalse(session.isReviewingAssistant)
        XCTAssertEqual(session.workspace, original)
        XCTAssertTrue(assistant.messages.last?.text.contains("active trial or purchase") == true)
    }

    func testAssistantDraftBegunBeforeExpirationCanBeKeptOnce() async throws {
        let (session, access) = scene()
        let assistant = AssistantController(session: session)
        assistant.responder = { _, workspace, _, _, _, _ in
            access.setTestState(.trialEnded)
            var bench = AssistantWorkbench(workspace: workspace)
            try bench.setDimension(item: "Body 01", dimension: "depth", value: 10)
            return AssistantEngine.Turn(reply: "Ready", bench: bench, backend: .onDevice)
        }
        assistant.send("Make it 10 mm")
        while assistant.isWorking { await Task.yield() }
        XCTAssertTrue(session.isReviewingAssistant)
        assistant.keep()
        XCTAssertEqual(session.workspace.bodies[0].depth, 10)
        XCTAssertFalse(session.isReviewingAssistant)
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].depth, 10)
    }

    func testExpiredProjectSavesAcceptedNotesAndViewingDoesNotRewritePreview() async throws {
        let (source, access) = scene()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Trial.swipesketch")
        try ProjectCodec.create(Project(workspace: source.workspace), at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await withCheckedContinuation { continuation in document.open { continuation.resume(returning: $0) } }
        XCTAssertTrue(opened)
        let session = ModelingSession(document: document, access: access)
        session.beginEditingNotes(); session.updateNotes("Accepted before expiration")
        access.setTestState(.trialEnded)
        let saved = await withCheckedContinuation { continuation in session.save { continuation.resume(returning: $0) } }
        XCTAssertTrue(saved)
        let closed = await withCheckedContinuation { continuation in document.close { continuation.resume(returning: $0) } }
        XCTAssertTrue(closed)
        let bytes = try Data(contentsOf: url)
        let loaded = try ProjectCodec.decode(bytes)
        XCTAssertEqual(loaded.workspace.notes, "Accepted before expiration")
        XCTAssertEqual(loaded.workspace.bodies, source.workspace.bodies)
        let viewingDocument = ProjectDocument(fileURL: url)
        let reopened = await withCheckedContinuation { continuation in viewingDocument.open { continuation.resume(returning: $0) } }
        XCTAssertTrue(reopened)
        let viewer = ModelingSession(document: viewingDocument, access: access)
        viewer.projectThumbnailProvider = { UIImage(named: SSIcon.brand.assetName) }
        viewer.selectItem(.body(loaded.workspace.bodies[0].id))
        let viewSaved = await withCheckedContinuation { continuation in viewer.save(withThumbnail: true) { continuation.resume(returning: $0) } }
        XCTAssertTrue(viewSaved)
        let viewClosed = await withCheckedContinuation { continuation in viewingDocument.close { continuation.resume(returning: $0) } }
        XCTAssertTrue(viewClosed)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Viewing must not rewrite geometry or thumbnails")
    }
}
