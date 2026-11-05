import SwiftUI
import StoreKit
import Security

struct PurchaseProduct: Equatable, Sendable {
    var id: AppProduct
    var price: String
}

struct PurchaseSnapshot: Sendable {
    var accountID: String?
    var transactions: [AccessTransaction]
    var currentFullPurchaseIDs: Set<String>?
}

enum PurchaseOutcome: Sendable {
    case completed(AccessTransaction), cancelled, pending
}

@MainActor protocol PurchaseClient: AnyObject {
    func products() async throws -> [PurchaseProduct]
    func history(restoring: Bool) async throws -> PurchaseSnapshot
    func purchase(_ product: AppProduct) async throws -> PurchaseOutcome
    func finish(_ transaction: AccessTransaction) async
    func updates(_ receive: @escaping @MainActor (AccessTransaction) -> Void) -> Task<Void, Never>
}

@MainActor protocol AccessCache: AnyObject {
    func read() -> AppAccessLedger?
    func write(_ ledger: AppAccessLedger) throws
}

/// StoreKit owns verification and its offline transaction history. The Keychain copy preserves
/// already verified access through transient store failures; it never contains project contents.
@MainActor final class AppAccessStore: ObservableObject {
    static let shared: AppAccessStore = {
        #if SWIPE_SKETCH_SELF_BUILD
        return AppAccessStore(unrestricted: true)
        #else
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-access") {
            let state: AppAccessState = arguments.contains("--access-trial") ? .trialActive(ends: Date().addingTimeInterval(AppProduct.trialDuration)) :
                arguments.contains("--access-purchased") ? .purchased : arguments.contains("--access-not-started") ? .notStarted : .trialEnded
            return AppAccessStore(testState: state)
        }
        if arguments.contains("--ui-testing") || NSClassFromString("XCTestCase") != nil {
            return AppAccessStore(unrestricted: true)
        }
        #endif
        return AppAccessStore(client: StoreKitPurchaseClient(), cache: KeychainAccessCache())
        #endif
    }()

    @Published private(set) var state: AppAccessState = .checking
    @Published private(set) var products: [PurchaseProduct] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var message: String?
    @Published var showOffer = false
    @Published private(set) var isUnrestricted = false
    private var ledger: AppAccessLedger
    private let client: (any PurchaseClient)?
    private let cache: (any AccessCache)?
    private let clock: () -> Date
    private var clockAnchor: Date
    private var uptimeAnchor: TimeInterval
    private var checked = false
    private var listener: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var refreshing = false
    private var pendingUpdateRevision = 0

    init(client: any PurchaseClient, cache: any AccessCache, clock: @escaping () -> Date = Date.init, start: Bool = true) {
        self.client = client; self.cache = cache; self.clock = clock
        ledger = cache.read() ?? AppAccessLedger()
        clockAnchor = clock(); uptimeAnchor = ProcessInfo.processInfo.systemUptime
        state = ledger.state(at: clock(), checked: false)
        listener = client.updates { [weak self] transaction in self?.receive(transaction) }
        if start {
            Task { [weak self] in await self?.refresh(); await self?.loadProducts() }
        }
        scheduleExpiration()
    }

    deinit { listener?.cancel(); expiration?.cancel() }

    /// Explicit dependency for previews, hosted tests, and MIT self-builds. Official Release
    /// builds never read launch arguments or preferences that can grant unrestricted access.
    init(unrestricted: Bool) {
        client = nil; cache = nil; clock = Date.init; ledger = AppAccessLedger()
        clockAnchor = Date(); uptimeAnchor = ProcessInfo.processInfo.systemUptime
        isUnrestricted = unrestricted; checked = true
        state = unrestricted ? .purchased : .notStarted
    }

    #if DEBUG
    init(testState: AppAccessState) {
        client = nil; cache = nil; clock = Date.init; ledger = AppAccessLedger()
        clockAnchor = Date(); uptimeAnchor = ProcessInfo.processInfo.systemUptime
        checked = true; state = testState
        products = [PurchaseProduct(id: .trial, price: "$0.00"), PurchaseProduct(id: .full, price: "$19.99")]
    }
    func setTestState(_ state: AppAccessState) { self.state = state }

    /// Debug-only StoreKit testing aid. Forgets the locally cached ledger (including the used
    /// trial and the clock-rollback guard) and re-reads the store, so transactions deleted in
    /// Xcode's transaction manager stop granting access. The cache is the separate development
    /// Keychain entry; sandbox and production evidence are never touched. Project files are not
    /// affected.
    var canResetTestAccess: Bool { client != nil && cache != nil }

    func resetTestAccess() async {
        guard canResetTestAccess, !isBusy, !refreshing else { return }
        isBusy = true
        defer { isBusy = false }
        ledger = AppAccessLedger()
        clockAnchor = clock(); uptimeAnchor = ProcessInfo.processInfo.systemUptime
        checked = false
        pendingUpdateRevision += 1
        message = nil
        persist()
        publishState()
        await refresh()
        if message == nil {
            message = "Local test access was reset. Access now reflects only the transactions in the StoreKit test store."
        }
    }
    #endif

    var canEdit: Bool {
        guard client != nil else { return state.canEdit }
        return ledger.state(at: effectiveNow, checked: checked).canEdit
    }
    var price: String? { products.first { $0.id == .full }?.price }
    var canStartTrial: Bool { state == .notStarted && products.contains { $0.id == .trial } && price != nil }
    var trialEnd: Date? { if case .trialActive(let end) = state { end } else { nil } }
    var statusTitle: String {
        switch state {
        case .checking: "Checking access…"
        case .notStarted: "Try Swipe & Sketch"
        case .trialActive: "14-day trial"
        case .trialEnded: "Viewing mode"
        case .purchased: isUnrestricted ? "Self-built / development access" : "Swipe & Sketch purchased"
        }
    }
    private var effectiveNow: Date {
        max(clock(), clockAnchor.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime - uptimeAnchor)))
    }

    func requestEditing() -> Bool {
        refreshClock()
        guard !canEdit else { return true }
        showOffer = true
        return false
    }

    func refreshClock() {
        guard client != nil else { return }
        ledger.observe(effectiveNow)
        persist()
        publishState()
    }

    func refresh(restoring: Bool = false) async {
        guard let client, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let revision = pendingUpdateRevision
        do {
            let snapshot = try await client.history(restoring: restoring)
            // A transaction update can arrive while history is being read. Never replace it
            // with a stale snapshot; merge signed records and reconcile only an unchanged read.
            guard revision == pendingUpdateRevision else {
                checked = true
                refreshClock()
                if restoring { message = "Your access changed during restoration. The latest verified transaction has been kept. Choose Restore Purchases again if needed." }
                return
            }
            if let accountID = snapshot.accountID { ledger.useAccount(accountID) }
            for transaction in snapshot.transactions { ledger.record(transaction) }
            if restoring, revision == pendingUpdateRevision, let ids = snapshot.currentFullPurchaseIDs {
                ledger.reconcileFullPurchase(originalIDs: ids, at: effectiveNow)
            }
            checked = true
            refreshClock()
            if restoring {
                message = state == .purchased ? "Purchase restored." :
                    trialEnd != nil ? "Your trial has been restored with its original end date." :
                    "No active purchase was found. Check that the App Store is using the Apple Account that made the purchase."
            }
        } catch {
            checked = true
            refreshClock()
            message = "Could not check the App Store. Your previously verified access is preserved. Connect to the internet and try Restore Purchases. \(error.localizedDescription)"
        }
    }

    func loadProducts() async {
        guard let client, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await client.products()
            if price == nil || state == .notStarted && !products.contains(where: { $0.id == .trial }) {
                message = "Purchases are currently unavailable. You can still view, share, and export projects. Please try again."
            }
        } catch { message = "Could not load App Store prices. Connect to the internet and try again. \(error.localizedDescription)" }
    }

    func buy(_ product: AppProduct) async {
        guard let client, !isBusy, !refreshing else { return }
        refreshClock()
        guard product != .trial || canStartTrial else { return }
        guard products.contains(where: { $0.id == product }), price != nil else { await loadProducts(); return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            switch try await client.purchase(product) {
            case .completed(let transaction):
                guard transaction.product == product else { throw StoreKitPurchaseClient.Failure.unverified }
                receive(transaction)
                await client.finish(transaction)
                message = canEdit ? (product == .trial ? "Your 14-day trial is ready." : "Thank you. Swipe & Sketch is unlocked.") :
                    "This trial has already ended. Your projects remain available to view, share, and export."
            case .cancelled: break
            case .pending: message = "Your purchase is awaiting approval. Access will update when the App Store confirms it."
            }
        } catch { message = "The purchase could not be completed. No access has been removed. \(error.localizedDescription)" }
    }

    func restore() async {
        guard !isBusy, !refreshing else { return }
        isBusy = true; message = nil
        await refresh(restoring: true)
        isBusy = false
    }

    private func receive(_ transaction: AccessTransaction) {
        pendingUpdateRevision += 1
        ledger.record(transaction)
        checked = true
        refreshClock()
    }
    private func persist() {
        do { try cache?.write(ledger) }
        catch { message = "Access was verified, but could not be saved locally. Use Restore Purchases if needed after restarting. Your project files are unaffected." }
    }
    private func publishState() {
        let next = ledger.state(at: effectiveNow, checked: checked)
        if state != next { state = next }
        scheduleExpiration()
    }
    private func scheduleExpiration() {
        expiration?.cancel()
        guard client != nil, let end = trialEnd else { return }
        let delay = max(0.01, end.timeIntervalSince(effectiveNow))
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.refreshClock()
        }
    }
}

@MainActor final class StoreKitPurchaseClient: PurchaseClient {
    private var loaded: [String: Product] = [:]
    private var unfinished: [String: StoreKit.Transaction] = [:]
    private var accountID: String?
    enum Failure: LocalizedError {
        case unverified, unavailable
        var errorDescription: String? {
            switch self { case .unverified: "The App Store transaction could not be verified."; case .unavailable: "This product is not available from the App Store right now." }
        }
    }

    func products() async throws -> [PurchaseProduct] {
        let values = try await Product.products(for: AppProduct.allCases.map(\.rawValue))
        loaded = Dictionary(uniqueKeysWithValues: values.filter { $0.type == .nonConsumable }.map { ($0.id, $0) })
        return values.compactMap { value in
            guard value.type == .nonConsumable, let id = AppProduct(rawValue: value.id), id != .trial || value.price == 0 else { return nil }
            return PurchaseProduct(id: id, price: value.displayPrice)
        }
    }

    func history(restoring: Bool) async throws -> PurchaseSnapshot {
        if restoring { try await AppStore.sync() }
        // This is verified on device and identifies the purchasing account without an app login.
        if case .verified(let app) = try await AppTransaction.shared { accountID = app.appTransactionID }
        var records: [AccessTransaction] = []
        for await result in StoreKit.Transaction.all {
            guard case .verified(let transaction) = result else { throw Failure.unverified }
            guard let record = record(transaction) else { continue }
            records.append(record)
        }
        var current = Set<String>()
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { throw Failure.unverified }
            if let record = record(transaction), record.product == .full, !record.revoked {
                current.insert(record.originalID)
                records.append(record)
            }
        }
        return PurchaseSnapshot(accountID: accountID, transactions: records, currentFullPurchaseIDs: restoring ? current : nil)
    }

    func purchase(_ product: AppProduct) async throws -> PurchaseOutcome {
        guard let value = loaded[product.rawValue], product != .trial || value.price == 0 else { throw Failure.unavailable }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { throw Failure.unavailable }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        switch try await value.purchase(confirmIn: presenter) {
        case .success(let result):
            guard case .verified(let transaction) = result, let record = record(transaction) else { throw Failure.unverified }
            unfinished[record.originalID] = transaction
            return .completed(record)
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: throw Failure.unavailable
        }
    }

    func finish(_ transaction: AccessTransaction) async {
        if let pending = unfinished.removeValue(forKey: transaction.originalID) { await pending.finish() }
    }

    func updates(_ receive: @escaping @MainActor (AccessTransaction) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = result, let record = self?.record(transaction) else { continue }
                receive(record)
                await transaction.finish()
            }
        }
    }

    private func record(_ transaction: StoreKit.Transaction) -> AccessTransaction? {
        guard let product = AppProduct(rawValue: transaction.productID), transaction.productType == .nonConsumable else { return nil }
        #if !DEBUG
        let sandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        guard transaction.environment == (sandbox ? .sandbox : .production) else { return nil }
        #endif
        return AccessTransaction(product: product, originalID: String(transaction.originalID), accountID: accountID ?? transaction.appTransactionID,
                                 originalPurchaseDate: transaction.originalPurchaseDate, signedDate: transaction.signedDate,
                                 revoked: transaction.revocationDate != nil)
    }
}

@MainActor final class KeychainAccessCache: AccessCache {
    private var query: [String: Any] {
        #if DEBUG
        let environment = "development"
        #else
        let environment = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "sandbox" : "production"
        #endif
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "noventix.SwipeAndSketch") + ".access." + environment,
                kSecAttrAccount as String: "verified-ledger-v1"]
    }
    func read() -> AppAccessLedger? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AppAccessLedger.self, from: data)
    }
    func write(_ ledger: AppAccessLedger) throws {
        let data = try JSONEncoder().encode(ledger)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
