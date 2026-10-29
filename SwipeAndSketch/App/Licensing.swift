import SwiftUI
import StoreKit
import os

/// What the user may do (October 28, 2026). The app is free for good: every file opens,
/// edits with the free tools, and exports. Swipe & Sketch Pro, one non-consumable purchase, adds the
/// Pro tools, the templates other than the plain Gridfinity pair, Import STEP, and the assistant's
/// changes. Pro tools preview for everyone; only keeping what they make needs Pro.
struct LicenseAccess: Equatable, Sendable {
    var ownsPro = false

    /// The plan's short name, for the project menu, Home, and Your Plan.
    var planName: String { ownsPro ? "Pro" : "Free" }
}

/// The App Store side of `LicenseAccess`: loads the Pro product, buys, restores, and redeems offer
/// codes (free licenses), and follows the transactions StoreKit reports, here or on the user's other
/// devices. The last known access is kept so the app opens with Pro offline; StoreKit corrects it
/// moments later.
@MainActor final class LicenseStore: ObservableObject {
    enum ProductID: String, CaseIterable {
        /// Named "unlock" for the earlier Unlock purchase; the ID stays, the product is Swipe & Sketch Pro.
        case pro = "noventix.SwipeAndSketch.unlock"
    }

    static let shared = LicenseStore()

    /// Purchases are on (October 29, 2026, build 2, once Pro was set up in App Store Connect):
    /// StoreKit decides who has Pro. Off, every build ran with Pro and never asked StoreKit.
    /// Debug builds still pick a state with `--license-free`, `--license-pro`, or `--license-store`
    /// (with Products.storekit selected in the scheme, purchases and offer codes are simulated).
    static let enforcesPurchases = true

    @Published private(set) var access: LicenseAccess
    @Published private(set) var products: [ProductID: Product] = [:]
    /// StoreKit has reported the entitlements at least once since launch.
    @Published private(set) var hasLoadedEntitlements = false
    @Published private(set) var isLoadingProducts = false
    /// The purchase being made, or restore.
    @Published private(set) var busy: String?
    /// The last problem or note to show on the purchases screen.
    @Published var message: String?
    /// Opens Your Plan from anywhere (a Pro tool's Keep, the assistant, the project menu, the rail's Pro tile).
    @Published var isShowingStore = false

    private var updates: Task<Void, Never>?
    /// Pro as its own verified transactions said this launch (bought, restored, redeemed, or revoked).
    /// `Transaction.currentEntitlements` can lag a moment behind a new purchase, and read alone it
    /// left the app Free until the next launch.
    private var confirmedPro: Bool?
    private let defaults = UserDefaults.standard
    /// Fixed access for tests: StoreKit is not consulted.
    private let fixed: LicenseAccess?

    private init() {
        fixed = Self.testAccess
        access = fixed ?? LicenseAccess(ownsPro: defaults.bool(forKey: Keys.pro))
        guard fixed == nil else { hasLoadedEntitlements = true; return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    self?.apply(transaction)
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
        Task { await refreshEntitlements(); await loadProducts() }
    }

    func product(_ id: ProductID) -> Product? { products[id] }

    /// The Pro price as the App Store gives it for this storefront (never a typed one: it changes
    /// after the launch price), or nil until the product loads.
    var proPrice: String? { products[.pro]?.displayPrice }

    private static let notAnswering = "The App Store is not answering right now."
    /// Each load, purchase, and restore, for Xcode's console and Console.app (category "purchases").
    private let log = Logger(subsystem: "noventix.SwipeAndSketch", category: "purchases")

    /// The App Store is consulted; false in builds that fix the plan (tests and Debug launch
    /// arguments, or every build until purchases are switched on).
    var purchasesAreOn: Bool { fixed == nil }

    func loadProducts() async {
        guard fixed == nil, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: ProductID.allCases.map(\.rawValue))
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in ProductID(rawValue: product.id).map { ($0, product) } })
            log.info("Loaded \(loaded.count) products: \(loaded.map(\.id).joined(separator: ", "), privacy: .public)")
            if products.isEmpty { message = Self.notAnswering + " Check your connection and try again." }
            // An earlier failure to reach the App Store is over.
            else if message?.hasPrefix(Self.notAnswering) == true { message = nil }
        } catch {
            log.error("Loading products failed: \(error.localizedDescription, privacy: .public)")
            message = Self.notAnswering + " \(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        guard fixed == nil else { return }
        var pro = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if ProductID(rawValue: transaction.productID) == .pro { pro = true }
        }
        hasLoadedEntitlements = true
        // A purchase or refund seen this launch wins over an entitlement list that has not caught up.
        setPro(confirmedPro ?? pro)
    }

    /// Takes Pro from one verified transaction at once: owned unless it was refunded or revoked.
    private func apply(_ transaction: StoreKit.Transaction) {
        guard ProductID(rawValue: transaction.productID) == .pro else { return }
        confirmedPro = transaction.revocationDate == nil
        setPro(transaction.revocationDate == nil)
    }

    private func setPro(_ pro: Bool) {
        defaults.set(pro, forKey: Keys.pro)
        if access.ownsPro != pro { access = LicenseAccess(ownsPro: pro) }
    }

    /// Buys `id` with SwiftUI's purchase action, which shows the App Store sheet over the right window.
    /// When the product has not loaded yet, it is loaded first, and a product that cannot be loaded
    /// says so rather than leaving the button doing nothing.
    func purchase(_ id: ProductID, with purchase: PurchaseAction) async {
        guard busy == nil, fixed == nil else { return }
        if products[id] == nil { await loadProducts() }
        guard let product = products[id] else {
            log.error("No product \(id.rawValue, privacy: .public) to buy")
            message = "Swipe & Sketch Pro could not be loaded from the App Store. Check your connection and try again."
            return
        }
        busy = id.rawValue
        message = nil
        defer { busy = nil }
        do {
            switch try await purchase(product) {
            case .success(.verified(let transaction)):
                log.info("Bought \(transaction.productID, privacy: .public)")
                apply(transaction)
                await transaction.finish()
                await refreshEntitlements()
            case .success(.unverified(_, let error)):
                log.error("Unverified purchase: \(error.localizedDescription, privacy: .public)")
                message = "The App Store could not confirm that purchase. Try Restore Purchases."
            case .pending:
                log.info("Purchase pending approval")
                message = "The purchase is waiting for approval. Pro turns on as soon as it is approved."
            case .userCancelled:
                log.info("Purchase cancelled")
            @unknown default: break
            }
        } catch {
            log.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    /// Restore Purchases: asks the App Store for this Apple ID's purchases (it may ask to sign in).
    func restore() async {
        guard busy == nil, fixed == nil else { return }
        busy = "restore"
        message = nil
        defer { busy = nil }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !access.ownsPro { message = "No purchases were found for this Apple ID." }
        } catch StoreKitError.userCancelled {
        } catch {
            message = error.localizedDescription
        }
    }

    /// After the offer code sheet closes: a redeemed code arrives as a transaction, finished like a purchase.
    func codeRedemptionFinished(_ result: Result<VerificationResult<StoreKit.Transaction>, Error>) {
        Task {
            switch result {
            case .success(.verified(let transaction)):
                apply(transaction)
                await transaction.finish()
            case .success(.unverified): message = "The App Store could not confirm that code. Try Restore Purchases."
            case .failure(StoreKitError.userCancelled): break
            case .failure(let error): message = error.localizedDescription
            }
            await refreshEntitlements()
        }
    }

    private enum Keys {
        /// Kept from the earlier Unlock purchase, which used the same product.
        static let pro = "license.unlock"
    }

    /// Tests run with Pro unless a launch argument picks a state; otherwise StoreKit decides, once
    /// purchases are enforced.
    private static var testAccess: LicenseAccess? {
        let pro = LicenseAccess(ownsPro: true)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--license-store") { return nil }
        if arguments.contains("--license-free") { return LicenseAccess() }
        if arguments.contains("--license-pro") { return pro }
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || arguments.contains("--ui-testing")
        if underTest { return pro }
        #endif
        return enforcesPurchases ? nil : pro
    }
}
