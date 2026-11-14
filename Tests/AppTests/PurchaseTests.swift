import XCTest
import StoreKitTest
@testable import SwipeAndSketch

@MainActor private final class MemoryAccessCache: AccessCache {
    var ledger: AppAccessLedger?
    var writes = 0
    init(_ ledger: AppAccessLedger? = nil) { self.ledger = ledger }
    func read() -> AppAccessLedger? { ledger }
    func write(_ ledger: AppAccessLedger) { self.ledger = ledger; writes += 1 }
}

@MainActor private final class ScriptedPurchaseClient: PurchaseClient {
    var catalog = [PurchaseProduct(id: .trial, price: "$0.00"), PurchaseProduct(id: .full, price: "$19.99")]
    var snapshot = PurchaseSnapshot(accountID: nil, transactions: [], currentFullPurchaseIDs: [])
    var outcome: PurchaseOutcome = .cancelled
    var failure: Error?
    var receive: (@MainActor (AccessTransaction) -> Void)?
    var finished: [AccessTransaction] = []
    var onFinish: (() -> Void)?
    func products() async throws -> [PurchaseProduct] { if let failure { throw failure }; return catalog }
    func history(restoring: Bool) async throws -> PurchaseSnapshot { if let failure { throw failure }; return snapshot }
    func purchase(_ product: AppProduct) async throws -> PurchaseOutcome { if let failure { throw failure }; return outcome }
    func finish(_ transaction: AccessTransaction) async { onFinish?(); finished.append(transaction) }
    func updates(_ receive: @escaping @MainActor (AccessTransaction) -> Void) -> Task<Void, Never> {
        self.receive = receive
        return Task { }
    }
}

@MainActor final class PurchaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func record(_ product: AppProduct, at date: Date? = nil, revoked: Bool = false, signed: Date? = nil) -> AccessTransaction {
        AccessTransaction(product: product, originalID: product.rawValue, accountID: "account", originalPurchaseDate: date ?? now,
                          signedDate: signed ?? now, revoked: revoked)
    }

    func testTrialRequiresExplicitCompletedActivationAndPriceDisclosure() async {
        let client = ScriptedPurchaseClient(), cache = MemoryAccessCache()
        let store = AppAccessStore(client: client, cache: cache, clock: { self.now }, start: false)
        await store.refresh(); await store.loadProducts()
        XCTAssertEqual(store.state, .notStarted)
        XCTAssertTrue(store.canStartTrial)
        client.outcome = .pending
        await store.buy(.trial)
        XCTAssertEqual(store.state, .notStarted)
        client.outcome = .cancelled
        await store.buy(.trial)
        XCTAssertEqual(store.state, .notStarted)
        client.onFinish = { XCTAssertTrue(cache.ledger?.state(at: self.now).canEdit == true, "Persist before finishing the transaction") }
        client.outcome = .completed(record(.trial))
        await store.buy(.trial)
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(store.trialEnd, now.addingTimeInterval(AppProduct.trialDuration))
        XCTAssertFalse(store.canStartTrial)
        XCTAssertEqual(client.finished.count, 1)
    }

    func testResetTestAccessForgetsCachedTrialAndPurchaseRemovedFromStore() async {
        var ledger = AppAccessLedger()
        ledger.record(record(.trial, at: now.addingTimeInterval(-20 * 24 * 60 * 60)))
        ledger.record(record(.full))
        let cache = MemoryAccessCache(ledger), client = ScriptedPurchaseClient()
        let store = AppAccessStore(client: client, cache: cache, clock: { self.now }, start: false)
        await store.refresh(); await store.loadProducts()
        XCTAssertEqual(store.state, .purchased, "Cached evidence survives an ordinary refresh")
        XCTAssertTrue(store.canResetTestAccess)
        await store.resetTestAccess()
        XCTAssertEqual(store.state, .notStarted)
        XCTAssertTrue(store.canStartTrial)
        XCTAssertEqual(cache.ledger?.transactions, [])
        XCTAssertFalse(AppAccessStore(unrestricted: true).canResetTestAccess)
    }

    func testMissingPricePreventsTrialActivation() async {
        let client = ScriptedPurchaseClient()
        client.catalog = [PurchaseProduct(id: .trial, price: "$0.00")]
        client.outcome = .completed(record(.trial))
        let store = AppAccessStore(client: client, cache: MemoryAccessCache(), clock: { self.now }, start: false)
        await store.refresh(); await store.loadProducts(); await store.buy(.trial)
        XCTAssertFalse(store.canStartTrial)
        XCTAssertFalse(store.canEdit)
        XCTAssertTrue(client.finished.isEmpty)
    }

    func testOfflinePurchaseSurvivesRelaunchAndLookupFailure() async {
        var ledger = AppAccessLedger(); ledger.record(record(.full))
        let cache = MemoryAccessCache(ledger), client = ScriptedPurchaseClient()
        client.failure = URLError(.notConnectedToInternet)
        let store = AppAccessStore(client: client, cache: cache, clock: { self.now }, start: false)
        await store.refresh()
        XCTAssertEqual(store.state, .purchased)
        let relaunched = AppAccessStore(client: client, cache: cache, clock: { self.now }, start: false)
        XCTAssertTrue(relaunched.canEdit)
        await relaunched.restore()
        XCTAssertTrue(relaunched.canEdit)
    }

    func testRestoreKeepsOriginalTrialEndAndVerifiedRevocationRemovesPurchase() async {
        let client = ScriptedPurchaseClient()
        client.snapshot = PurchaseSnapshot(accountID: "account", transactions: [record(.trial)], currentFullPurchaseIDs: [])
        let later = now.addingTimeInterval(AppProduct.trialDuration + 1)
        let store = AppAccessStore(client: client, cache: MemoryAccessCache(), clock: { later }, start: false)
        await store.restore()
        XCTAssertEqual(store.state, .trialEnded)
        client.receive?(record(.full))
        XCTAssertEqual(store.state, .purchased)
        client.receive?(record(.full, revoked: true, signed: later))
        XCTAssertEqual(store.state, .trialEnded)
        client.receive?(record(.full))
        XCTAssertEqual(store.state, .trialEnded, "A stale update must not undo a refund")
    }

    func testFailedPurchasePreservesActiveTrial() async {
        var ledger = AppAccessLedger(); ledger.record(record(.trial))
        let client = ScriptedPurchaseClient()
        let store = AppAccessStore(client: client, cache: MemoryAccessCache(ledger), clock: { self.now }, start: false)
        await store.loadProducts()
        client.failure = URLError(.timedOut)
        await store.buy(.full)
        XCTAssertTrue(store.canEdit)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(store.message?.contains("could not be completed") == true)
    }

    func testLocalStoreKitTrialPurchaseRestoreAndRefund() async throws {
        let testing = try SKTestSession(configurationFileNamed: "Purchases")
        testing.disableDialogs = true
        testing.clearTransactions()
        defer { testing.clearTransactions() }
        let store = AppAccessStore(client: StoreKitPurchaseClient(), cache: MemoryAccessCache(), start: false)
        await store.refresh(); await store.loadProducts()
        XCTAssertTrue(store.canStartTrial)
        _ = try await testing.buyProduct(identifier: AppProduct.trial.rawValue)
        await store.refresh()
        XCTAssertTrue(store.canEdit, store.message ?? "No trial access")
        let originalEnd = try XCTUnwrap(store.trialEnd)
        let otherInstallation = AppAccessStore(client: StoreKitPurchaseClient(), cache: MemoryAccessCache(), start: false)
        await otherInstallation.refresh()
        XCTAssertEqual(otherInstallation.trialEnd, originalEnd)
        _ = try await testing.buyProduct(identifier: AppProduct.full.rawValue)
        await store.refresh()
        await settle { store.state == .purchased }
        XCTAssertEqual(store.state, .purchased, store.message ?? "No purchase")
        let purchased = try XCTUnwrap(testing.allTransactions().first { $0.productIdentifier == AppProduct.full.rawValue })
        try testing.refundTransaction(identifier: purchased.identifier)
        await store.refresh()
        await settle { store.state != .purchased }
        XCTAssertNotEqual(store.state, .purchased)
        XCTAssertTrue(store.canEdit, "Refunded purchase falls back to an unexpired trial")
    }

    /// StoreKit delivers external purchases and refunds through an asynchronous update stream.
    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }
}
