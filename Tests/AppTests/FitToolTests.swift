import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// The Fit tools through the session, canvas, and kernel: Peg & Socket, Subtract's clearance, the
/// Fit Test, and the Fit preference.
@MainActor final class FitToolTests: CanvasTestCase {

    /// App preferences these tests change, put back afterwards (hosted tests share the app's settings).
    private static let preferenceKeys = ["fitClearance", "print.folderBookmark", "print.placement", "print.bedWidth", "print.bedDepth"]
    private var savedPreferences: [String: Any] = [:]
    override func setUp() async throws {
        try await super.setUp()
        savedPreferences = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
    }
    override func tearDown() async throws {
        for key in Self.preferenceKeys { UserDefaults.standard.set(savedPreferences[key], forKey: key) }
        try await super.tearDown()
    }
    func volume(_ session: ModelingSession, _ index: Int = 0) throws -> Double {
        try SolidKernel.solid(for: session.workspace.bodies[index]).volume
    }

    /// The 60 × 40 × 20 box with a 5 mm lid of the same size sitting on it (hidden, to reach the rim).
    func lidScene() throws -> (ModelingSession, CanvasController) {
        let (session, controller) = boxScene()
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        session.choosePlane(top)
        session.addShape(.init(kind: .rectangle, plane: top, start: top.coordinates(of: .init(-30, -20, 20)), end: top.coordinates(of: .init(30, 20, 20))))
        session.beginExtrusion()
        session.chooseExtrusionMode(.newBody)
        session.extrusionDepth = 5
        session.confirmExtrusion()
        session.chooseTool(.select)
        XCTAssertEqual(session.workspace.bodies.count, 2)
        session.toggleHidden(.body(session.workspace.bodies[1].id))
        session.select(nil)
        controller.refresh()
        return (session, controller)
    }

    func testPegFromTheFitGroupSocketsTheHiddenLid() throws {
        let (session, controller) = try lidScene()
        session.fitClearance = 0.15
        session.chooseTool(.peg)
        XCTAssertEqual(session.tool, .peg)
        XCTAssertNil(session.sketchMode, "Waits for the face the peg stands on")
        XCTAssertTrue(session.hint.contains("flat face"), session.hint)
        // A tap on the rim's face sketches on it with the Peg tool ready.
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.sketchMode?.face)
        XCTAssertEqual(session.tool, .peg)
        controller.refresh()
        tap(controller, SIMD3(0.3, -0.2, 20))
        let draft = try XCTUnwrap(session.pegDraft)
        XCTAssertEqual(draft.center, .zero, "Snapped to the face's center dot")
        XCTAssertEqual(draft.spec.clearance, 0.15, "Starts from the Fit preference")
        let lid = session.workspace.bodies[1].id
        XCTAssertEqual(session.pegSockets, [lid])
        XCTAssertTrue(session.hint.contains("(hidden)"), session.hint)
        XCTAssertEqual(Set(controller.dimensionAnnotations().map(\.target)), [.pegDiameter, .pegHeight])
        XCTAssertEqual(session.helpTopic, .peg)

        XCTAssertTrue(session.applyDimension(4, target: .pegDiameter))
        XCTAssertTrue(session.applyDimension(3, target: .pegHeight))
        XCTAssertFalse(session.applyDimension(0.5, target: .pegDiameter), "Too thin")
        XCTAssertNotNil(session.dimensionError)
        session.setPegClearance(0.2)
        attach(controller, "Peg placed on the rim, socketing the hidden lid")
        session.confirmPeg()
        XCTAssertNil(session.pegDraft)
        XCTAssertEqual(session.tool, .peg, "Ready for the next peg")
        XCTAssertEqual(session.status, "Peg added · 1 socket")
        XCTAssertEqual(session.workspace.bodies[0].cuts.map(\.operation), [.join, .finish])
        XCTAssertEqual(try volume(session, 1), 60 * 40 * 5 - .pi * 2.2 * 2.2 * 3.2, accuracy: 1e-3)
        XCTAssertEqual(session.workspace.bodies[1].hidden, true)
        session.undo()
        XCTAssertTrue(session.workspace.bodies[0].cuts.isEmpty && session.workspace.bodies[1].cuts.isEmpty, "One undo step")
    }

    func testPegOffTheFaceCannotBeConfirmed() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        session.chooseTool(.peg)
        XCTAssertNotNil(session.sketchMode?.face, "A selected face starts the peg's face sketch")
        controller.refresh()
        tap(controller, SIMD3(45, 30, 20))
        XCTAssertNotNil(session.draftError)
        session.confirmPeg()
        XCTAssertEqual(session.workspace.bodies[0].cuts, [])
        session.cancelPeg()
        XCTAssertNil(session.pegDraft)
    }

    func testSubtractWithClearanceLeavesRoomForTheTool() throws {
        let (session, _) = boxScene()
        // A 10 mm pin standing through the box.
        let bottom = try XCTUnwrap(SketchPlane.through(.init(0, 0, -5), normal: .init(0, 0, 1)))
        session.choosePlane(bottom)
        session.addShape(.init(kind: .circle, plane: bottom, start: .zero, end: Point2(x: 5, y: 0)))
        session.beginExtrusion()
        session.chooseExtrusionMode(.newBody)
        session.extrusionDepth = 30
        session.confirmExtrusion()
        session.chooseTool(.select)
        let box = session.workspace.bodies[0].id, pin = session.workspace.bodies[1].id
        session.select(.body(box))
        session.chooseTool(.subtract)
        session.selectItem(.body(pin))
        session.setSubtractKeep(.removed)
        XCTAssertNil(session.subtractDraft?.clearance, "Exact unless asked")
        session.setSubtractClearance(0.3)
        XCTAssertTrue(session.hint.contains("grown by the clearance"), session.hint)
        // The keypad edits the operation's clearance, not the app's Fit.
        let fit = session.fitClearance
        XCTAssertEqual(session.dimensionValue(.clearance), 0.3)
        XCTAssertTrue(session.applyDimension(0.25, target: .clearance))
        XCTAssertEqual(session.subtractDraft?.clearance, 0.25)
        XCTAssertEqual(session.fitClearance, fit)
        XCTAssertFalse(session.applyDimension(3, target: .clearance))
        session.confirmSubtract()
        XCTAssertEqual(session.workspace.bodies.map(\.id), [box, pin], "The pin stays, to print")
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.clearance, 0.25)
        XCTAssertEqual(try volume(session), 48_000 - .pi * 5.25 * 5.25 * 20, accuracy: 1e-2)
    }

    func testFitTestAddsTheCouponBesideTheModel() throws {
        let (session, _) = boxScene()
        session.chooseTool(.fitTest)
        XCTAssertEqual(session.workspace.bodies.count, 3)
        XCTAssertEqual(session.status, "Fit Test added")
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[1].id))
        XCTAssertGreaterThan(try SolidKernel.solid(for: session.workspace.bodies[1]).bounds.min.x, 30, "Clear of the box")
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 1, "One undo step")
    }

    func testFitPreferenceIsKeptAndChecked() throws {
        let session = ModelingSession(inMemory: true)
        let original = session.fitClearance
        defer { session.fitClearance = original }
        session.setFitClearance(Fit.Preset.loose.clearance)
        XCTAssertEqual(Fit.preferredClearance, 0.3, "Saved as the app preference")
        XCTAssertEqual(session.fitText(0.3), "Loose · 0.3 mm")
        XCTAssertTrue(session.applyDimension(0.18, target: .fitClearance))
        XCTAssertEqual(session.fitClearance, 0.18)
        XCTAssertEqual(session.fitText(0.18), "Custom · 0.18 mm")
        XCTAssertFalse(session.applyDimension(0.18, target: .clearance), "No fit is being set up")
        session.setFitClearance(5)
        XCTAssertEqual(session.fitClearance, 0.18, "Out of range is ignored")
    }

    func testSeparatePegIsItsOwnSolidWithASocketInItsFace() throws {
        let (session, controller) = try lidScene()
        session.chooseTool(.peg)
        tap(controller, SIMD3(5, 3, 20))
        controller.refresh()
        tap(controller, SIMD3(0.3, -0.2, 20))
        XCTAssertEqual(session.pegDraft?.spec.separate, false, "Joined by default, as before")
        session.setPegSeparate(true)
        XCTAssertEqual(session.pegDraft?.spec.embed, session.pegDraft?.spec.height, "Into the face as far as it stands out")
        XCTAssertEqual(Set(controller.dimensionAnnotations().map(\.target)), [.pegDiameter, .pegHeight, .pegEmbed])
        XCTAssertTrue(session.applyDimension(3, target: .pegEmbed))
        XCTAssertTrue(session.applyDimension(0, target: .pegEmbed), "0 stands it on the face")
        XCTAssertEqual(session.pegSockets.count, 1, "Only the lid")
        XCTAssertTrue(session.applyDimension(3, target: .pegEmbed))
        XCTAssertEqual(session.pegSockets.count, 2, "The lid and the face it stands on")
        session.confirmPeg()
        XCTAssertEqual(session.workspace.bodies.count, 3)
        XCTAssertEqual(session.status, "Separate peg added · 2 sockets")
        let pin = session.workspace.bodies[1]
        XCTAssertEqual(try SolidKernel.solid(for: pin).bounds.min.z, 17, accuracy: 1e-6)
        XCTAssertEqual(session.workspace.bodies[0].cuts.map(\.operation), [.cut], "A socket, nothing joined")
        // The next peg starts separate too.
        tap(controller, SIMD3(15, 10, 20))
        XCTAssertEqual(session.pegDraft?.spec.separate, true)
        session.cancelPeg()
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2, "One undo step")
    }
}
