import SwiftUI
import StoreKit

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let coral = Color("ss-coral")

/// Purchases (October 21, 2026): the free 7-day trial, Unlock, and AI Assistant, with Restore
/// Purchases and Redeem Code (offer codes are how free licenses are given). App Review asks the
/// trial offer to say how long it lasts, what stops working afterwards, and what it costs to keep it.
struct PurchasesView: View {
    var onDone: () -> Void
    @ObservedObject private var license = LicenseStore.shared
    @Environment(\.purchase) private var purchase
    @State private var redeeming = false

    /// The trial offer opens by itself only once per launch.
    static var offeredThisLaunch = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(license.access.status).font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
                            .accessibilityIdentifier("purchases.status")
                        Text("Every purchase is a one-time payment. Nothing renews.").font(.system(size: 14)).foregroundStyle(muted)
                    }
                    .padding(.vertical, 4)
                }
                if license.access.canStartTrial {
                    Section("Free trial") {
                        item(.trial, title: "7-Day Free Trial",
                             detail: "Every tool, including the AI Assistant, free for 7 days. No payment and no subscription. "
                                + "When the 7 days are over, your models stay yours: you can still open, view, measure, section, and export them, "
                                + "but changing them needs Unlock (\(price(.unlock))), and the AI Assistant needs its own purchase (\(price(.assistant))).",
                             action: "Start Free Trial")
                    }
                }
                Section("Swipe & Sketch") {
                    item(.unlock, title: "Unlock",
                         detail: "Edit your models and use every modeling tool, for good. The AI Assistant is a separate purchase.",
                         owned: license.access.ownsUnlock)
                    item(.assistant, title: "AI Assistant",
                         detail: license.access.ownsUnlock || license.access.ownsAssistant
                            ? "Ask about your model and have the assistant change it, for good."
                            : "Ask about your model and have the assistant change it. Available once Swipe & Sketch is unlocked.",
                         owned: license.access.ownsAssistant, enabled: license.access.canBuyAssistant)
                }
                Section {
                    Button("Restore Purchases") { Task { await license.restore() } }
                        .disabled(license.busy != nil).accessibilityIdentifier("purchases.restore")
                    Button("Redeem Code") { redeeming = true }
                        .disabled(license.busy != nil).accessibilityIdentifier("purchases.redeem")
                } footer: {
                    Text("Purchases belong to your Apple ID and work on each iPad you sign in to.")
                }
                if let message = license.message {
                    Section { Text(message).foregroundStyle(coral).accessibilityIdentifier("purchases.message") }
                }
            }
            .tint(violet)
            .navigationTitle("Purchases").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).accessibilityIdentifier("purchases.done") } }
            .offerCodeRedemption(isPresented: $redeeming) { license.codeRedemptionFinished($0) }
            .task { if license.products.isEmpty { await license.loadProducts() } }
        }
    }

    private func price(_ id: LicenseStore.ProductID) -> String { license.product(id)?.displayPrice ?? "one-time purchase" }

    private func item(_ id: LicenseStore.ProductID, title: String, detail: String, action: String? = nil, owned: Bool = false, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                Text(detail).font(.system(size: 14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if owned {
                Text("Owned").font(.system(size: 15, weight: .semibold)).foregroundStyle(violet)
                    .accessibilityIdentifier("purchases.\(id.shortName).owned")
            } else if license.busy == id.rawValue {
                ProgressView()
            } else {
                let product = license.product(id)
                Button {
                    Task { await license.purchase(id, with: purchase) }
                } label: {
                    Text(action ?? product?.displayPrice ?? "…").font(.system(size: 15, weight: .semibold)).foregroundStyle(paper)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(violet, in: Capsule())
                }
                .buttonStyle(.plain)
                .opacity(product == nil || !enabled ? 0.4 : 1)
                .disabled(product == nil || !enabled || license.busy != nil)
                .accessibilityIdentifier("purchases.\(id.shortName).buy")
            }
        }
        .padding(.vertical, 4)
    }
}

private extension LicenseStore.ProductID {
    var shortName: String { rawValue.components(separatedBy: ".").last ?? rawValue }
}
