import SwiftUI
import StoreKit

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let card = Color("ss-white")
private let canvas = Color("ss-canvas")
private let hairline = Color("ss-border")

/// Your Plan (October 28, 2026): which plan this iPad is on, what Swipe & Sketch Pro adds and what
/// stays free, the one-time purchase, Restore Purchases, and Redeem Code (offer codes are how free
/// licenses are given). It opens from the project menu, Home, the rail's Pro tile, a Pro tool's Keep
/// with Pro, and the assistant's Keep, never by itself.
struct PurchasesView: View {
    var onDone: () -> Void
    @ObservedObject private var license = LicenseStore.shared
    @Environment(\.purchase) private var purchase
    @State private var redeeming = false
    private let assistantRuns = AssistantEngine.deviceCanRunAssistant

    /// What Pro adds, each with the brand icon of its tool.
    private var proFeatures: [(icon: SSIcon, title: String, detail: String)] {
        [(.newProject, "Every template", "Gridfinity with magnets and dividers, cases and mounts for boards, and boxes with screw or slip-on lids."),
         (.thread, "Threads and screw lids", "Real threads with a matching nut, bolt, or cap, and jars with lids that screw on."),
         (.peg, "Parts that fit", "Peg & Socket joins parts, and Fit Test prints find your printer's clearance."),
         (.text, "Text", "Raised or sunk lettering on any flat face."),
         (.pattern, "Power tools", "Shell, Pattern, Split Body, Draft, Loft, Sweep, Rib, and Project."),
         (.open, "Import STEP", "Bring in parts from other CAD apps as editable solids."),
         (.assistant, "AI Assistant changes", assistantRuns
            ? "Describe a change and keep what it builds."
            : "Describe a change and keep what it builds, on an iPad with Apple Intelligence.")]
    }

    /// What every plan has.
    private let freeFeatures = [
        "Every sketch and dimension tool",
        "Extrude, Revolve, Fillet, Chamfer, and Holes",
        "Union, Subtract, Intersect, Align, Mirror, and Scale",
        "Measure, Section, and Import Mesh",
        "Gridfinity Baseplate, Bin, Spacer Set, and Fit & Print Test templates",
        "Unlimited projects, full-quality STL and 3MF export",
        "Ask the AI Assistant about your model",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    if !license.access.ownsPro { howItWorks }
                    sectionTitle(license.access.ownsPro ? "Included in your plan" : "What Pro adds")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(proFeatures, id: \.title) { feature in featureCard(feature) }
                    }
                    sectionTitle("Free for everyone, for good")
                    freeCard
                    footer
                }
                .padding(20)
            }
            .background(canvas)
            .navigationTitle("Your Plan").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).accessibilityIdentifier("purchases.done") } }
            .offerCodeRedemption(options: [], isPresented: $redeeming) { license.codeRedemptionFinished($0) }
            .task { if license.products.isEmpty { await license.loadProducts() } }
        }
        .tint(violet)
        // The light-only design: in Dark Mode a sheet from the editor would otherwise turn dark under the brand ink.
        .preferredColorScheme(.light)
    }

    /// The plan, the offer, and the button that buys it: Swipe Violet with Paper type.
    private var hero: some View {
        let owned = license.access.ownsPro
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Your plan:").font(.system(size: 13, weight: .semibold)).foregroundStyle(paper.opacity(0.85))
                Text(license.access.planName).font(.system(size: 13, weight: .heavy)).foregroundStyle(paper)
                    .accessibilityIdentifier("purchases.status")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(paper.opacity(0.18), in: Capsule())
            Text(owned ? "You have Swipe & Sketch Pro" : "Get Swipe & Sketch Pro")
                .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(paper)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(owned
                 ? "Every Pro tool and template is yours, and so is every Pro tool still to come. Thank you for supporting Swipe & Sketch."
                 : "Every template, threads and screw lids, parts that fit, text, the power tools, and the AI Assistant's changes. Pay once and keep it for good.")
                .font(.system(size: 16)).foregroundStyle(paper.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
            if owned {
                HStack(spacing: 8) {
                    SSIconGlyph(icon: .done, size: 22, color: violet)
                    Text("Pro is on").font(.system(size: 16, weight: .semibold)).foregroundStyle(violet)
                }
                .padding(.horizontal, 16).frame(height: 44)
                .background(paper, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("purchases.unlock.owned")
            } else {
                buyButton
                Text("One-time purchase · No subscription · Family Sharing")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(paper.opacity(0.85))
            }
            if let message = license.message {
                // Problems and notes from the App Store, at the top where they are seen.
                Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(paper, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("purchases.message")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(violet, in: RoundedRectangle(cornerRadius: 20))
    }

    /// Get Pro with the store's price. Before the price loads it still works: it loads the product
    /// first, and says so when the App Store cannot be reached.
    @ViewBuilder private var buyButton: some View {
        let product = license.product(.pro)
        if license.busy == LicenseStore.ProductID.pro.rawValue || license.isLoadingProducts && product == nil {
            ProgressView().tint(paper).frame(height: 50)
        } else {
            Button {
                Task { await license.purchase(.pro, with: purchase) }
            } label: {
                Text(product.map { "Get Pro · \($0.displayPrice)" } ?? "Get Pro")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(violet)
                    .padding(.horizontal, 28).frame(height: 50)
                    .background(paper, in: Capsule())
            }
            .buttonStyle(.plain)
            .opacity(license.purchasesAreOn ? 1 : 0.6)
            .disabled(!license.purchasesAreOn || license.busy != nil)
            .accessibilityIdentifier("purchases.unlock.buy")
        }
        if !license.purchasesAreOn {
            Text("Purchases are switched off in this build.")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(paper)
        }
    }

    /// Why nothing is locked away: Pro tools preview, and files never lock.
    private var howItWorks: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("PRO").font(.system(size: 10, weight: .heavy)).foregroundStyle(paper)
                .padding(.horizontal, 6).padding(.vertical, 3).background(violet, in: Capsule())
                .padding(.top, 2).accessibilityHidden(true)
            Text("Tools marked PRO still open and show you the result for free. When you like it, tap Keep with Pro. Your projects always open, edit, and export, with or without Pro.")
                .font(.system(size: 15)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("ss-lavender"), in: RoundedRectangle(cornerRadius: 16))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .bold)).foregroundStyle(ink).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func featureCard(_ feature: (icon: SSIcon, title: String, detail: String)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SSIconTile(icon: feature.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                Text(feature.detail).font(.system(size: 14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private var freeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(freeFeatures, id: \.self) { feature in
                HStack(alignment: .top, spacing: 10) {
                    SSIconGlyph(icon: .done, size: 18, color: ink)
                        .frame(width: 26, height: 26).background(Color("ss-limeSoft"), in: Circle())
                    Text(feature).font(.system(size: 15)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.6)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                Button("Restore Purchases") { Task { await license.restore() } }
                    .disabled(license.busy != nil).accessibilityIdentifier("purchases.restore")
                Button("Redeem Code") { redeeming = true }
                    .disabled(license.busy != nil).accessibilityIdentifier("purchases.redeem")
            }
            .font(.system(size: 15, weight: .semibold))
            Text("Purchases belong to your Apple Account and work on each iPad you sign in to, and with Family Sharing.")
                .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
