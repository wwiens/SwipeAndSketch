import XCTest
@testable import SwipeAndSketch

/// Free and Pro (Licensing.swift): the free app edits every file with the free tools, Pro
/// tools wait at Keep for Swipe & Sketch Pro, and buying it does what was waiting.
@MainActor final class LicenseTests: XCTestCase {
    override func tearDown() {
        LicenseStore.shared.isShowingStore = false
        super.tearDown()
    }

    func testStatusNamesTheTier() {
        XCTAssertEqual(LicenseAccess().status, "Free")
        XCTAssertEqual(LicenseAccess(ownsPro: true).status, "Swipe & Sketch Pro")
    }

    func testProToolsAreTheListedOnes() {
        let pro: Set<ModelingTool> = [.shell, .draft, .split, .pattern, .project, .loft, .sweep, .rib, .peg, .fitTest, .thread, .screwLid, .text]
        XCTAssertEqual(Set(ModelingTool.allCases.filter(\.isPro)), pro)
        // Every tool needed to make a part by hand stays free.
        for tool in [ModelingTool.line, .rectangle, .circle, .extrude, .revolve, .fillet, .chamfer, .hole, .union, .subtract, .intersect, .align, .scale, .mirror, .deleteFace, .box] {
            XCTAssertFalse(tool.isPro, "\(tool) is free")
        }
    }

    /// Without Pro nothing is view-only: drawing, deleting, and undoing work as always.
    func testFreeSessionEditsWithTheFreeTools() throws {
        let session = ModelingSession(inMemory: true)
        session.ownsPro = false
        XCTAssertFalse(session.isEditingBlocked)
        session.addShape(SketchShape(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 20, y: 10)))
        XCTAssertEqual(session.workspace.shapes.count, 1)
        session.selection = .shape(session.workspace.shapes[0].id)
        session.deleteSelection()
        XCTAssertTrue(session.workspace.shapes.isEmpty)
        session.undo()
        XCTAssertEqual(session.workspace.shapes.count, 1)
        XCTAssertFalse(session.hint.localizedCaseInsensitiveContains("view only"))
    }

    /// A Pro tool's Keep opens Purchases and changes nothing; buying Pro does what was waiting.
    func testProToolWaitsForProAndBuyingFinishesIt() {
        let session = ModelingSession(inMemory: true)
        session.ownsPro = false
        session.addFitTest()
        XCTAssertTrue(session.workspace.bodies.isEmpty, "Nothing is added without Pro")
        XCTAssertTrue(LicenseStore.shared.isShowingStore, "Purchases opens")
        XCTAssertNotNil(session.pendingPro)

        session.ownsPro = true
        XCTAssertNil(session.pendingPro)
        XCTAssertFalse(session.workspace.bodies.isEmpty, "The Fit Test is added once Pro is bought")
    }

    /// Closing Purchases without buying forgets the waiting Keep, so a later purchase does nothing by surprise.
    func testClosingPurchasesDropsTheWaitingKeep() {
        let session = ModelingSession(inMemory: true)
        session.ownsPro = false
        session.addFitTest()
        session.dropPendingPro()
        session.ownsPro = true
        XCTAssertTrue(session.workspace.bodies.isEmpty)
    }

    /// A file made with Pro tools still changes with the free tools after Pro is gone (a refund, or
    /// another person's iPad).
    func testProMadeSolidsEditWithoutPro() {
        let session = ModelingSession(inMemory: true)
        session.addFitTest()
        let coupon = session.workspace.bodies
        XCTAssertFalse(coupon.isEmpty)
        session.ownsPro = false
        session.selection = .body(coupon[0].id)
        session.deleteSelection()
        XCTAssertEqual(session.workspace.bodies.count, coupon.count - 1, "A free user deletes a Pro-made solid")
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, coupon.count)
    }

    /// The assistant's changes keep without Pro at the session level; the assistant's own Keep
    /// asks for Pro (AssistantTests).
    func testAssistantChangesKeepWhenAllowed() throws {
        let session = ModelingSession(inMemory: true)
        let before = session.workspace
        var changed = before
        changed.shapes.append(SketchShape(kind: .circle, plane: .top, start: .init(x: 40, y: 0), end: .init(x: 45, y: 0)))
        session.showAssistantPreview(changed, focus: nil)
        XCTAssertTrue(session.keepAssistantChanges())
        XCTAssertEqual(session.workspace.shapes.count, before.shapes.count + 1)
    }
}
