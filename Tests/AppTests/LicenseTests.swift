import XCTest
@testable import SwipeAndSketch

/// The free trial, Unlock, and AI Assistant rules (Licensing.swift), and the session's view-only mode.
@MainActor final class LicenseTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testTrialNotStartedIsViewOnly() {
        let access = LicenseAccess()
        XCTAssertEqual(access.phase, .notStarted)
        XCTAssertFalse(access.canEdit)
        XCTAssertFalse(access.canUseAssistant)
        XCTAssertTrue(access.canStartTrial)
        XCTAssertFalse(access.canBuyAssistant)
    }

    func testTrialGivesEverythingForSevenDays() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let early = LicenseAccess(trialStart: start, now: start.addingTimeInterval(0.5 * day))
        XCTAssertEqual(early.phase, .trial)
        XCTAssertTrue(early.canEdit)
        XCTAssertTrue(early.canUseAssistant)
        XCTAssertFalse(early.canStartTrial)
        XCTAssertEqual(early.trialDaysLeft, 7)
        XCTAssertEqual(early.status, "Free trial · 7 days left")

        let lastDay = LicenseAccess(trialStart: start, now: start.addingTimeInterval(6.9 * day))
        XCTAssertEqual(lastDay.trialDaysLeft, 1)
        XCTAssertEqual(lastDay.status, "Free trial · 1 day left")

        let over = LicenseAccess(trialStart: start, now: start.addingTimeInterval(7 * day))
        XCTAssertEqual(over.phase, .ended)
        XCTAssertFalse(over.canEdit)
        XCTAssertFalse(over.canUseAssistant)
        XCTAssertNil(over.trialDaysLeft)
        // The assistant is sold only once the app is unlocked.
        XCTAssertFalse(over.canBuyAssistant)
    }

    func testUnlockEditsForGoodButTheAssistantNeedsItsOwnPurchase() {
        let start = Date(timeIntervalSince1970: 1_800_000_000), later = start.addingTimeInterval(30 * day)
        let unlocked = LicenseAccess(trialStart: start, ownsUnlock: true, now: later)
        XCTAssertEqual(unlocked.phase, .unlocked)
        XCTAssertTrue(unlocked.canEdit)
        XCTAssertFalse(unlocked.canUseAssistant)
        XCTAssertTrue(unlocked.canBuyAssistant)

        let everything = LicenseAccess(trialStart: start, ownsUnlock: true, ownsAssistant: true, now: later)
        XCTAssertTrue(everything.canUseAssistant)
        XCTAssertFalse(everything.canBuyAssistant)
        XCTAssertFalse(everything.canStartTrial)
        XCTAssertEqual(everything.status, "Unlocked · AI Assistant")
    }

    func testAssistantWithoutUnlockDoesNotEdit() {
        // An offer code for the assistant alone: it waits for Unlock after the trial.
        let access = LicenseAccess(trialStart: Date(timeIntervalSince1970: 0), ownsAssistant: true, now: Date(timeIntervalSince1970: 30 * day))
        XCTAssertFalse(access.canEdit)
        XCTAssertFalse(access.canUseAssistant)
    }

    func testUnlockBeforeTheTrialStillOffersTheAssistantTrial() {
        let access = LicenseAccess(ownsUnlock: true)
        XCTAssertTrue(access.canEdit)
        XCTAssertFalse(access.canUseAssistant)
        XCTAssertTrue(access.canStartTrial)
    }

    func testLockedSessionShowsButDoesNotChangeTheModel() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(SketchShape(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 20, y: 10)))
        let before = session.workspace
        XCTAssertEqual(before.shapes.count, 1)

        session.isLicenseLocked = true
        XCTAssertTrue(session.isEditingBlocked)
        XCTAssertFalse(session.isViewingBlocked)
        XCTAssertTrue(session.hint.contains("view-only") || session.hint.contains("View only"))

        session.addShape(SketchShape(kind: .circle, plane: .top, start: .init(x: 40, y: 0), end: .init(x: 45, y: 0)))
        session.selection = .shape(before.shapes[0].id)
        session.deleteSelection()
        session.undo()
        XCTAssertEqual(session.workspace, before)

        // Measuring and the section view are for looking, so they still work.
        session.chooseTool(.measure)
        XCTAssertTrue(session.isMeasuring)
        XCTAssertTrue(session.acceptsPencil)
        XCTAssertTrue(session.canEditDimension(.sectionOffset))
        XCTAssertFalse(session.canEditDimension(.patternCount))

        session.isLicenseLocked = false
        XCTAssertFalse(session.isEditingBlocked)
    }
}
