import XCTest
@testable import SwipeAndSketchCore

final class AppAccessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func transaction(_ product: AppProduct, revoked: Bool = false, signedOffset: TimeInterval = 0, account: String = "account") -> AccessTransaction {
        AccessTransaction(product: product, originalID: product.rawValue, accountID: account, originalPurchaseDate: start,
                          signedDate: start.addingTimeInterval(signedOffset), revoked: revoked)
    }

    func testExactTrialBoundaryAndRestoringOriginalStart() {
        var ledger = AppAccessLedger()
        ledger.record(transaction(.trial))
        let end = start.addingTimeInterval(14 * 24 * 60 * 60)
        XCTAssertEqual(ledger.state(at: end.addingTimeInterval(-0.001)), .trialActive(ends: end))
        XCTAssertEqual(ledger.state(at: end), .trialEnded)
        ledger.record(transaction(.trial, signedOffset: 30 * 24 * 60 * 60))
        XCTAssertEqual(ledger.state(at: end.addingTimeInterval(1)), .trialEnded)
    }

    func testPurchaseTakesPrecedenceAndDoesNotExpire() {
        var ledger = AppAccessLedger()
        ledger.record(transaction(.trial))
        ledger.record(transaction(.full))
        XCTAssertEqual(ledger.state(at: start.addingTimeInterval(365 * 24 * 60 * 60)), .purchased)
    }

    func testRefundAndOutOfOrderUpdatesCannotRestoreRevokedPurchase() {
        var ledger = AppAccessLedger()
        ledger.record(transaction(.trial))
        ledger.record(transaction(.full))
        ledger.record(transaction(.full, revoked: true, signedOffset: 20 * 24 * 60 * 60))
        ledger.record(transaction(.full, signedOffset: 1))
        XCTAssertEqual(ledger.state(at: start.addingTimeInterval(21 * 24 * 60 * 60)), .trialEnded)
    }

    func testRevokedTrialDoesNotBecomeANewTrial() {
        var ledger = AppAccessLedger()
        ledger.record(transaction(.trial, revoked: true))
        XCTAssertEqual(ledger.state(at: start), .trialEnded)
    }

    func testClockRollbackDoesNotReopenExpiredTrial() {
        var ledger = AppAccessLedger()
        ledger.record(transaction(.trial))
        ledger.observe(start.addingTimeInterval(AppProduct.trialDuration))
        XCTAssertEqual(ledger.state(at: start), .trialEnded)
        XCTAssertEqual(try JSONDecoder().decode(AppAccessLedger.self, from: JSONEncoder().encode(ledger)).state(at: start), .trialEnded)
    }

    func testVerifiedAccountChangeRemovesOtherAccountsPurchase() {
        var ledger = AppAccessLedger()
        ledger.record(transaction(.full))
        ledger.useAccount("different account")
        XCTAssertEqual(ledger.state(at: start), .notStarted)
        ledger.record(transaction(.trial, account: "different account"))
        XCTAssertTrue(ledger.state(at: start).canEdit)
    }

    func testOnlyExplicitReconciliationRemovesMissingPurchase() {
        var ledger = AppAccessLedger()
        ledger.record(transaction(.full))
        XCTAssertEqual(ledger.state(at: start, checked: false), .purchased)
        ledger.reconcileFullPurchase(originalIDs: [], at: start.addingTimeInterval(1))
        XCTAssertEqual(ledger.state(at: start), .notStarted)
        XCTAssertEqual(AppAccessLedger().state(at: start, checked: false), .checking)
    }
}
