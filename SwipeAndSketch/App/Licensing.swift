import SwiftUI
import StoreKit

/// What the user may do (October 28, 2026). The app is free for good: every file opens,
/// edits with the free tools, and exports. Swipe & Sketch Pro, one non-consumable purchase, adds the
/// Pro tools, the templates other than the plain Gridfinity pair, Import STEP, and the assistant's
/// changes. Pro tools preview for everyone; only keeping what they make needs Pro.
struct LicenseAccess: Equatable, Sendable {
    var ownsPro = false

    /// One line for the project menu, Home, and the purchases screen.
    var status: String { ownsPro ? "Swipe & Sketch Pro" : "Free" }
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

    /// The product is not set up in App Store Connect yet (October 28, 2026), so every build runs
    /// with Pro and never asks StoreKit. Turn this on before the 1.0 submission.
    /// In Debug builds `--license-store` asks StoreKit anyway (with
    /// Products.storekit selected in the scheme, purchases and offer codes are simulated).
    static let enforcesPurchases = false

    @Published private(set) var access: LicenseAccess
    @Published private(set) var products: [ProductID: Product] = [:]
    /// StoreKit has reported the entitlements at least once since launch.
    @Published private(set) var hasLoadedEntitlements = false
    @Published private(set) var isLoadingProducts = false
    /// The purchase being made, or restore.
    @Published private(set) var busy: String?
    /// The last problem or note to show on the purchases screen.
    @Published var message: String?
    /// Opens the purchases screen from anywhere (a Pro tool's Keep, the assistant, the project menu).
    @Published var isShowingStore = false

    private var updates: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    /// Fixed access for tests: StoreKit is not consulted.
    private let fixed: LicenseAccess?

    private init() {
        fixed = Self.testAccess
        access = fixed ?? LicenseAccess(ownsPro: defaults.bool(forKey: Keys.pro))
        guard fixed == nil else { hasLoadedEntitlements = true; return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
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

    func loadProducts() async {
        guard fixed == nil, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: ProductID.allCases.map(\.rawValue))
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in ProductID(rawValue: product.id).map { ($0, product) } })
            if products.isEmpty { message = Self.notAnswering + " Check your connection and try again." }
            // An earlier failure to reach the App Store is over.
            else if message?.hasPrefix(Self.notAnswering) == true { message = nil }
        } catch {
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
        defaults.set(pro, forKey: Keys.pro)
        hasLoadedEntitlements = true
        if access.ownsPro != pro { access = LicenseAccess(ownsPro: pro) }
    }

    /// Buys `id` with SwiftUI's purchase action, which shows the App Store sheet over the right window.
    func purchase(_ id: ProductID, with purchase: PurchaseAction) async {
        guard busy == nil, let product = products[id] else { return }
        busy = id.rawValue
        message = nil
        defer { busy = nil }
        do {
            switch try await purchase(product) {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refreshEntitlements()
            case .success(.unverified):
                message = "The App Store could not confirm that purchase. Try Restore Purchases."
            case .pending:
                message = "The purchase is waiting for approval. Pro turns on as soon as it is approved."
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
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
            case .success(.verified(let transaction)): await transaction.finish()
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
