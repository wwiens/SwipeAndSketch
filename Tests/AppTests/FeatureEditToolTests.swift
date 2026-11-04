import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Edit after Done: a finished hole, thread, text, or peg reopens in its tool from its face, and
/// Done puts the changed one in its place as one undo step (October 24, 2026).
@MainActor final class FeatureEditToolTests: CanvasTestCase {
    /// Features start from the Fit preference, which hosted tests share with the app.
    private var savedClearance: Any?
    override func setUp() async throws {
        try await super.setUp()
        savedClearance = UserDefaults.standard.object(forKey: "fitClearance")
        Fit.preferredClearance = Fit.defaultClearance
    }
    override func tearDown() async throws {
        UserDefaults.standard.set(savedClearance, forKey: "fitClearance")
        try await super.tearDown()
    }

    /// Sketch mode on the box's top face with `tool` ready.
    func onTopFace(_ session: ModelingSession, _ controller: CanvasController, _ tool: ModelingTool) throws -> SketchPlane {
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: session.workspace.bodies[0].id, near: [5, 3, 20]))))
        session.chooseTool(tool)
        controller.refresh()
        return try XCTUnwrap(session.sketchMode?.plane)
    }

    /// Selects the face of the first solid through `point`.
    func selectFace(_ session: ModelingSession, _ controller: CanvasController, near point: SIMD3<Double>, body: Int = 0) throws {
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: session.workspace.bodies[body].id, near: point))))
        controller.refresh()
    }

    func testEditHoleChangesItInPlaceAndCancelLeavesIt() throws {
        let (session, controller) = boxScene()
        let top = try onTopFace(session, controller, .hole)
        session.placeHole(at: top.coordinates(of: [0, 0, 20]))
        session.confirmHole()
        // A second hole, made after it, stays after it.
        session.placeHole(at: top.coordinates(of: [18, 10, 20]))
        session.confirmHole()
        session.exitSketch()
        session.select(nil)
        let body = session.workspace.bodies[0]
        XCTAssertEqual(body.cuts.map(\.operation), [.hole, .hole])
        let holeID = body.cuts[0].id

        try selectFace(session, controller, near: [1.7, 0, 10])
        XCTAssertEqual(session.selectedFeature, .hole(body: body.id, cut: 0))
        XCTAssertEqual(session.helpTopic, .hole)
        XCTAssertTrue(session.hint.contains("Edit Hole"), session.hint)

        session.editSelectedFeature()
        XCTAssertEqual(session.tool, .hole)
        XCTAssertNotNil(session.sketchMode?.face, "Back in the face sketch it was made in")
        let draft = try XCTUnwrap(session.holeDraft)
        XCTAssertEqual(draft.replacing, 0)
        XCTAssertEqual(draft.spec.kind, .simple)
        XCTAssertNil(draft.depth)
        session.chooseHole(kind: .counterbore, size: "M4")
        XCTAssertNotNil(session.holePreview)
        // A tap elsewhere on the face moves it.
        tap(controller, SIMD3(-12, -8, 20))
        let moved = try XCTUnwrap(session.holeDraft?.center)
        XCTAssertGreaterThan(simd_length(top.point(moved) - SIMD3(0, 0, 20)), 5)
        XCTAssertEqual(session.workspace.bodies[0], body, "Nothing changes before Done")
        attach(controller, "Editing a hole: counterbore, moved")
        session.confirmHole()

        let changed = session.workspace.bodies[0]
        XCTAssertEqual(changed.cuts.map(\.operation), [.hole, .hole], "In its place, before the second hole")
        XCTAssertEqual(changed.cuts[0].hole?.kind, .counterbore)
        XCTAssertEqual(changed.cuts[0].id, holeID)
        XCTAssertEqual(changed.cuts[1], body.cuts[1])
        XCTAssertEqual(session.tool, .select)
        XCTAssertNil(session.sketchMode)
        XCTAssertEqual(session.selection, .body(body.id))
        XCTAssertEqual(session.status, "Hole changed")
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0], body, "One undo step")

        try selectFace(session, controller, near: [1.7, 0, 10])
        session.editSelectedFeature()
        session.chooseHole(kind: .countersink)
        session.cancelHole()
        XCTAssertEqual(session.workspace.bodies[0], body)
        XCTAssertEqual(session.tool, .select)
        XCTAssertNil(session.sketchMode)
    }

    func testEditTextChangesTheWords() async throws {
        let (session, controller) = boxScene()
        let top = try onTopFace(session, controller, .text)
        session.placeText(at: top.coordinates(of: [0, 0, 20]))
        session.setText("H")
        XCTAssertTrue(session.applyDimension(8, target: .textHeight))
        XCTAssertTrue(session.applyDimension(1, target: .textDepth))
        await session.textPreviewSettled()
        session.confirmText()
        session.exitSketch()
        let body = session.workspace.bodies[0]

        // The top of the H's crossbar.
        try selectFace(session, controller, near: [0, 0, 21])
        XCTAssertEqual(session.selectedFeature, .text(body: body.id, cut: 0))
        XCTAssertEqual(session.helpTopic, .text)
        session.editSelectedFeature()
        let draft = try XCTUnwrap(session.textDraft)
        XCTAssertEqual(draft.replacing, 0)
        XCTAssertEqual(draft.text, "H")
        XCTAssertEqual(draft.height, 8)
        XCTAssertEqual(draft.depth, 1)
        session.setText("HI")
        session.setTextRaised(false)
        await session.textPreviewSettled()
        XCTAssertNotNil(session.textPreview)
        session.confirmText()
        let changed = session.workspace.bodies[0]
        XCTAssertEqual(changed.cuts.count, 1)
        XCTAssertEqual(changed.cuts[0].text?.text, "HI")
        XCTAssertEqual(changed.cuts[0].depth, -1)
        XCTAssertEqual(session.status, "Text changed")
        XCTAssertEqual(session.selection, .body(body.id))
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0], body)
    }

    func testEditThreadChangesItsPitchInItsPlace() async throws {
        let (session, controller) = boxScene()
        let top = try onTopFace(session, controller, .hole)
        session.placeHole(at: top.coordinates(of: [0, 0, 20]))
        XCTAssertTrue(session.applyDimension(6.8, target: .holeDiameter))
        session.confirmHole()
        session.exitSketch()
        let solid = try SolidKernel.solid(for: session.workspace.bodies[0])
        let wall = try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil })
        session.beginThread(bodyID: session.workspace.bodies[0].id, face: wall)
        await session.threadPreviewSettled()
        XCTAssertEqual(session.threadDraft?.spec.title, "M8 × 1.25")
        session.confirmThread()
        let body = session.workspace.bodies[0]
        XCTAssertEqual(body.cuts.map(\.operation), [.hole, .thread])

        let threaded = try SolidKernel.solid(for: body)
        let face = try XCTUnwrap((0..<threaded.faceCount).first { body.thread(atFace: $0, of: threaded) != nil })
        session.select(.face(FaceSelection(bodyID: body.id, face: face, plane: nil, center: try XCTUnwrap(threaded.faceCenter(face)))))
        XCTAssertEqual(session.selectedFeature, .thread(body: body.id, cut: 1))
        XCTAssertTrue(session.hint.contains("Edit Thread"), session.hint)

        session.editSelectedFeature()
        XCTAssertEqual(session.tool, .thread)
        let draft = try XCTUnwrap(session.threadDraft)
        XCTAssertEqual(draft.replacing, 1)
        XCTAssertEqual(draft.spec, body.cuts[1].thread, "Set up as it was made")
        session.chooseThreadPitch(1)
        await session.threadPreviewSettled()
        XCTAssertNotNil(session.threadPreview)
        XCTAssertEqual(session.threadPreview?.bodies[0].cuts.count, 2, "The old thread is replaced, not cut again")
        session.confirmThread()
        let changed = session.workspace.bodies[0]
        XCTAssertEqual(changed.cuts.map(\.operation), [.hole, .thread])
        XCTAssertEqual(changed.cuts[1].thread?.pitch, 1)
        XCTAssertEqual(changed.cuts[1].id, body.cuts[1].id)
        XCTAssertEqual(session.status, "Thread changed to M8 × 1")
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].cuts[1].thread?.pitch, 1.25)
    }

    func testEditPegResizesItAndItsSocket() throws {
        let (session, controller) = boxScene()
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        session.choosePlane(top)
        session.addShape(.init(kind: .rectangle, plane: top, start: top.coordinates(of: .init(-30, -20, 20)), end: top.coordinates(of: .init(30, 20, 20))))
        session.beginExtrusion()
        session.chooseExtrusionMode(.newBody)
        session.extrusionDepth = 5
        session.confirmExtrusion()
        session.chooseTool(.select)
        session.toggleHidden(.body(session.workspace.bodies[1].id))
        _ = try onTopFace(session, controller, .peg)
        session.placePeg(at: top.coordinates(of: [0, 0, 20]))
        XCTAssertTrue(session.applyDimension(4, target: .pegDiameter))
        XCTAssertTrue(session.applyDimension(3, target: .pegHeight))
        session.confirmPeg()
        session.exitSketch()
        let before = session.workspace

        try selectFace(session, controller, near: [2, 0, 21.5])
        guard case .peg(_, let from)? = session.selectedFeature else { return XCTFail("The peg's side is its peg") }
        XCTAssertEqual(from, before.bodies[0].id)
        XCTAssertEqual(session.helpTopic, .peg)
        session.editSelectedFeature()
        XCTAssertEqual(session.tool, .peg)
        let draft = try XCTUnwrap(session.pegDraft)
        XCTAssertNotNil(draft.editing)
        XCTAssertEqual(draft.spec.diameter, 4, accuracy: 1e-9)
        XCTAssertEqual(draft.spec.height, 3, accuracy: 1e-9)
        XCTAssertEqual(session.pegSockets, [before.bodies[1].id])
        XCTAssertTrue(session.applyDimension(6, target: .pegDiameter))
        session.confirmPeg()

        XCTAssertEqual(session.workspace.bodies[0].cuts.map(\.operation), [.join, .finish])
        XCTAssertEqual(session.workspace.bodies[0].cuts[0].profile.circle?.radius ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(session.workspace.bodies[1].cuts.count, 1, "One socket, resized")
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[1]).volume, 60 * 40 * 5 - .pi * 3.2 * 3.2 * 3.2, accuracy: 1e-3)
        XCTAssertEqual(session.status, "Peg changed · 1 socket")
        XCTAssertEqual(session.tool, .select)
        session.undo()
        XCTAssertEqual(session.workspace, before, "One undo step")

        // A socket's wall leads to its peg too.
        try selectFace(session, controller, near: [2.2, 0, 21.5], body: 1)
        XCTAssertNotNil(session.selectedFeature)
    }
}
