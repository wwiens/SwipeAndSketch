import SwiftUI
import StoreKit

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let coral = Color("ss-coral")

/// Purchases (October 28, 2026): what stays free, Swipe & Sketch Pro, Restore Purchases,
/// and Redeem Code (offer codes are how free licenses are given). It opens from the project menu,
/// Home, a Pro tool's Keep with Pro, and the assistant's Keep, never by itself.
struct PurchasesView: View {
    var onDone: () -> Void
    @ObservedObject private var license = LicenseStore.shared
    @Environment(\.purchase) private var purchase
    @State private var redeeming = false
    private let assistantRuns = AssistantEngine.deviceCanRunAssistant

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(license.access.status).font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
                            .accessibilityIdentifier("purchases.status")
                        Text("Swipe & Sketch is free for good: no trial, no limit on projects or exports. Pro is a one-time payment; nothing renews.")
                            .font(.system(size: 14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                Section("Included free") {
                    Text("Every tool you need to make a part by hand: sketching and dimensions, Extrude, Revolve, primitives, Fillet, Chamfer, Hole, Union, Subtract, Intersect, Align, Scale, Mirror, planes, Measure, Section, the Gridfinity Baseplate and Bin, Import Mesh, and full-quality STL and 3MF export. The AI Assistant answers questions.")
                        .font(.system(size: 14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
                Section("One-time purchase") {
                    item(.pro, title: "Swipe & Sketch Pro",
                         detail: "Adds every template; Thread, Matching Part, Screw Lid, Peg & Socket, and Fit Test; Text; Shell, Draft, Split Body, Pattern, Project, Loft, Sweep, and Rib; Import STEP; the AI Assistant's changes"
                            + (assistantRuns ? "" : " (on an iPad with Apple Intelligence; this one cannot run the assistant)")
                            + "; and every Pro tool that comes later. Pro tools preview for free: only keeping what they make needs Pro, and your files always open, edit, and export without it.",
                         owned: license.access.ownsPro)
                }
                Section {
                    Button("Restore Purchases") { Task { await license.restore() } }
                        .disabled(license.busy != nil).accessibilityIdentifier("purchases.restore")
                    Button("Redeem Code") { redeeming = true }
                        .disabled(license.busy != nil).accessibilityIdentifier("purchases.redeem")
                } footer: {
                    Text("Purchases belong to your Apple ID and work on each iPad you sign in to, and with Family Sharing.")
                }
                if let message = license.message {
                    Section { Text(message).foregroundStyle(coral).accessibilityIdentifier("purchases.message") }
                }
            }
            .tint(violet)
            .navigationTitle("Purchases").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).accessibilityIdentifier("purchases.done") } }
            .offerCodeRedemption(options: [], isPresented: $redeeming) { license.codeRedemptionFinished($0) }
            .task { if license.products.isEmpty { await license.loadProducts() } }
        }
        // The light-only design: in Dark Mode a sheet from the editor would otherwise turn dark under the brand ink.
        .preferredColorScheme(.light)
    }

    private func item(_ id: LicenseStore.ProductID, title: String, detail: String, owned: Bool = false) -> some View {
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
                    Text(product?.displayPrice ?? "…").font(.system(size: 15, weight: .semibold)).foregroundStyle(paper)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(violet, in: Capsule())
                }
                .buttonStyle(.plain)
                .opacity(product == nil ? 0.4 : 1)
                .disabled(product == nil || license.busy != nil)
                .accessibilityIdentifier("purchases.\(id.shortName).buy")
            }
        }
        .padding(.vertical, 4)
    }
}

private extension LicenseStore.ProductID {
    var shortName: String { rawValue.components(separatedBy: ".").last ?? rawValue }
}
