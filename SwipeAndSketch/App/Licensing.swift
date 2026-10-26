import SwiftUI
import StoreKit

/// What the user may do. Every tool, the assistant included, is
/// free for seven days from the free "7-Day Trial" item (App Review Guideline 3.1.1 asks for a free
/// non-consumable to start a time-based trial). Afterwards models still open for viewing, measuring,
/// section views, and export; changing them needs Unlock, and the assistant needs Unlock plus AI
/// Assistant (sold only once the app is unlocked). All three are one-time purchases; nothing renews.
struct LicenseAccess: Equatable, Sendable {
    static let trialLength: TimeInterval = 7 * 24 * 60 * 60

    /// When the free trial was started (its first transaction), if it was.
    var trialStart: Date?
    var ownsUnlock = false
    var ownsAssistant = false
    var now = Date()

    enum Phase: Equatable { case notStarted, trial, ended, unlocked }

    var trialEnd: Date? { trialStart.map { $0.addingTimeInterval(Self.trialLength) } }
    var isInTrial: Bool { trialEnd.map { now < $0 } ?? false }
    var canEdit: Bool { ownsUnlock || isInTrial }
    var canUseAssistant: Bool { isInTrial || ownsUnlock && ownsAssistant }
    /// The trial can be started once; after Unlock it still brings a week of the assistant.
    var canStartTrial: Bool { trialStart == nil && !(ownsUnlock && ownsAssistant) }
    /// The assistant is offered once the app is unlocked.
    var canBuyAssistant: Bool { ownsUnlock && !ownsAssistant }

    var phase: Phase {
        if ownsUnlock { return .unlocked }
        if isInTrial { return .trial }
        return trialStart == nil ? .notStarted : .ended
    }

    /// Whole days left in the trial, counting a part day as one ("1 day left" on the last day).
    var trialDaysLeft: Int? {
        guard isInTrial, let end = trialEnd else { return nil }
        return max(1, Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// One line for the project tab and the purchases screen.
    var status: String {
        switch phase {
        case .notStarted: return "View only · start the free trial to edit"
        case .trial:
            let days = trialDaysLeft ?? 1
            return "Free trial · \(days) \(days == 1 ? "day" : "days") left"
        case .ended: return "Trial ended · view only"
        case .unlocked:
            if ownsAssistant { return "Unlocked · AI Assistant" }
            if let days = trialDaysLeft { return "Unlocked · assistant trial \(days) \(days == 1 ? "day" : "days") left" }
            return "Unlocked"
        }
    }
}

/// The App Store side of `LicenseAccess`: loads the three products, buys, restores, and redeems
/// offer codes (free licenses), and follows the transactions StoreKit reports, here or on the user's
/// other devices. The last known access is kept so the app opens unlocked offline and without a
/// flash of the trial screen; StoreKit corrects it moments later.
@MainActor final class LicenseStore: ObservableObject {
    enum ProductID: String, CaseIterable {
        case trial = "noventix.SwipeAndSketch.trial"
        case unlock = "noventix.SwipeAndSketch.unlock"
        case assistant = "noventix.SwipeAndSketch.assistant"
    }

    static let shared = LicenseStore()

    /// The products are not set up in App Store Connect yet (October 21, 2026), so every build runs
    /// fully unlocked and never asks StoreKit. Turn this on before the 1.0 submission.
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
    /// Opens the purchases screen from anywhere (a locked tool, the assistant, the project menu).
    @Published var isShowingStore = false

    private var entitlements: (trialStart: Date?, unlock: Bool, assistant: Bool)
    private var updates: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    /// Fixed access for tests: StoreKit is not consulted.
    private let fixed: LicenseAccess?

    private init() {
        fixed = Self.testAccess
        let cachedStart = defaults.object(forKey: Keys.trialStart) as? Date
        entitlements = (cachedStart, defaults.bool(forKey: Keys.unlock), defaults.bool(forKey: Keys.assistant))
        access = fixed ?? LicenseAccess(trialStart: entitlements.trialStart, ownsUnlock: entitlements.unlock, ownsAssistant: entitlements.assistant)
        guard fixed == nil else { hasLoadedEntitlements = true; return }
        recompute()
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
        // The trial ends while the app is open: check the clock each minute.
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.recompute()
            }
        }
        Task { await refreshEntitlements(); await loadProducts() }
    }

    func product(_ id: ProductID) -> Product? { products[id] }

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
        var trialStart: Date?, unlock = false, assistant = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch ProductID(rawValue: transaction.productID) {
            case .trial: trialStart = min(trialStart ?? transaction.originalPurchaseDate, transaction.originalPurchaseDate)
            case .unlock: unlock = true
            case .assistant: assistant = true
            case nil: break
            }
        }
        entitlements = (trialStart, unlock, assistant)
        defaults.set(trialStart, forKey: Keys.trialStart)
        defaults.set(unlock, forKey: Keys.unlock)
        defaults.set(assistant, forKey: Keys.assistant)
        hasLoadedEntitlements = true
        recompute()
    }

    /// Buys `id` (the free trial too) with SwiftUI's purchase action, which shows the App Store sheet
    /// over the right window.
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
                message = "The purchase is waiting for approval. It unlocks as soon as it is approved."
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
            if !access.ownsUnlock && !access.ownsAssistant && access.trialStart == nil { message = "No purchases were found for this Apple ID." }
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

    private func recompute() {
        guard fixed == nil else { return }
        // Setting the clock back does not bring the trial back: time never runs backwards here.
        let seen = defaults.object(forKey: Keys.latestSeen) as? Date ?? .distantPast
        let now = max(Date(), seen)
        defaults.set(now, forKey: Keys.latestSeen)
        let next = LicenseAccess(trialStart: entitlements.trialStart, ownsUnlock: entitlements.unlock, ownsAssistant: entitlements.assistant, now: now)
        // Only the phase, days, and ownership matter to views; a new `now` alone redraws nothing.
        if next.phase != access.phase || next.trialDaysLeft != access.trialDaysLeft || next.canUseAssistant != access.canUseAssistant ||
            next.trialStart != access.trialStart || next.ownsAssistant != access.ownsAssistant {
            access = next
        }
    }

    private enum Keys {
        static let trialStart = "license.trialStart"
        static let unlock = "license.unlock"
        static let assistant = "license.assistant"
        static let latestSeen = "license.latestSeen"
    }

    /// Tests run unlocked unless a launch argument picks a state; otherwise StoreKit decides, once
    /// purchases are enforced.
    private static var testAccess: LicenseAccess? {
        let everything = LicenseAccess(ownsUnlock: true, ownsAssistant: true)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--license-store") { return nil }
        if arguments.contains("--license-not-started") { return LicenseAccess() }
        if arguments.contains("--license-trial") { return LicenseAccess(trialStart: Date()) }
        if arguments.contains("--license-ended") { return LicenseAccess(trialStart: Date(timeIntervalSinceNow: -30 * 86_400)) }
        if arguments.contains("--license-unlocked") { return LicenseAccess(trialStart: Date(timeIntervalSinceNow: -30 * 86_400), ownsUnlock: true) }
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || arguments.contains("--ui-testing")
        if underTest { return everything }
        #endif
        return enforcesPurchases ? nil : everything
    }
}
