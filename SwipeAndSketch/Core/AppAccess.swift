import Foundation

/// Commercial access belongs to the installation/account, never to a project file.
enum AppAccessState: Equatable, Sendable {
    case checking, notStarted, trialActive(ends: Date), trialEnded, purchased

    var canEdit: Bool {
        switch self { case .trialActive, .purchased: true; default: false }
    }
}

enum AppProduct: String, CaseIterable, Codable, Sendable {
    case trial = "noventix.SwipeAndSketch.trial14days"
    case full = "noventix.SwipeAndSketch.unlock"
    static let trialDuration: TimeInterval = 14 * 24 * 60 * 60
}

/// Constructed only after the storefront has verified a transaction. Latest signed updates win,
/// including revocation. Retaining the original trial start prevents restoring a new 14 days.
struct AccessTransaction: Codable, Equatable, Sendable {
    var product: AppProduct
    var originalID: String
    var accountID: String
    var originalPurchaseDate: Date
    var signedDate: Date
    var revoked: Bool
}

struct AppAccessLedger: Codable, Equatable, Sendable {
    var accountID: String?
    private(set) var transactions: [AccessTransaction] = []
    private(set) var latestDate: Date?

    /// Only a verified account identity may replace the cached account's evidence.
    mutating func useAccount(_ id: String) {
        guard accountID != id else { return }
        accountID = id
        transactions = []
    }

    mutating func record(_ transaction: AccessTransaction) {
        guard transaction.originalPurchaseDate.timeIntervalSince1970.isFinite,
              transaction.signedDate.timeIntervalSince1970.isFinite else { return }
        useAccount(transaction.accountID)
        if let index = transactions.firstIndex(where: { $0.product == transaction.product && $0.originalID == transaction.originalID }) {
            guard transaction.signedDate >= transactions[index].signedDate else { return }
            guard transaction.signedDate != transactions[index].signedDate || !transactions[index].revoked || transaction.revoked else { return }
            transactions[index] = transaction
        } else { transactions.append(transaction) }
    }

    /// Ordinary offline refreshes don't erase verified evidence. A successful explicit restore
    /// may authoritatively reconcile purchases missing from the current entitlement sequence.
    mutating func reconcileFullPurchase(originalIDs: Set<String>, at date: Date) {
        for index in transactions.indices where transactions[index].product == .full && !originalIDs.contains(transactions[index].originalID) {
            transactions[index].revoked = true
            transactions[index].signedDate = max(transactions[index].signedDate, date)
        }
    }

    mutating func observe(_ date: Date) {
        guard date.timeIntervalSince1970.isFinite else { return }
        latestDate = max(latestDate ?? date, date)
    }

    func state(at date: Date, checked: Bool = true) -> AppAccessState {
        if transactions.contains(where: { $0.product == .full && !$0.revoked }) { return .purchased }
        // A revoked trial remains used. Revocation does not buy another trial.
        guard let start = transactions.filter({ $0.product == .trial }).map(\.originalPurchaseDate).min() else {
            return checked ? .notStarted : .checking
        }
        let end = start.addingTimeInterval(AppProduct.trialDuration)
        let now = max(latestDate ?? date, date)
        guard now < end, transactions.contains(where: { $0.product == .trial && !$0.revoked }) else { return .trialEnded }
        return .trialActive(ends: end)
    }
}
