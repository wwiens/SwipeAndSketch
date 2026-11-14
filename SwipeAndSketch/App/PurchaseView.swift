import SwiftUI

/// One complete product. The offer never starts a trial or a charge merely by appearing.
struct PurchaseView: View {
    @ObservedObject var access: AppAccessStore
    var close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SSIconTile(icon: .brand, selected: true)
                        .accessibilityHidden(true)
                    Text(access.state == .trialEnded ? "Keep creating with Swipe & Sketch" : access.statusTitle)
                        .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    if let end = access.trialEnd {
                        Text("Your full trial ends \(end.formatted(date: .abbreviated, time: .shortened)).")
                            .accessibilityIdentifier("purchase.trialEnd")
                    }
                    if access.state == .purchased {
                        Text(access.isUnrestricted ? "This build has full development or self-build access." : "The complete app is unlocked. Thank you for supporting Swipe & Sketch.")
                    } else {
                        Text("Design precise parts for 3D printing with every modeling tool, template, import, export, and assistant editing feature.")
                        if access.state == .notStarted || access.state == .checking {
                            Text("Try every feature free for 14 consecutive days, starting when you choose Start 14-Day Trial.")
                        }
                        if let price = access.price {
                            Text("Then unlock Swipe & Sketch for \(price), paid once. No subscription or automatic charge.")
                                .font(.headline).accessibilityIdentifier("purchase.terms")
                        } else {
                            Text("The one-time price is loading from the App Store. You can start a trial once its terms and price are available.")
                        }
                        Text("After the trial, you can still open, view, measure, share, and export projects at full quality. Creating and editing require purchase. Your files stay yours.")
                            .accessibilityIdentifier("purchase.fileAccess")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        if access.state == .notStarted {
                            Button("Start 14-Day Trial") { Task { await access.buy(.trial) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(!access.canStartTrial || access.isBusy)
                                .accessibilityIdentifier("purchase.startTrial")
                        }
                        if access.state != .purchased {
                            Button(access.price.map { "Buy Swipe & Sketch — \($0)" } ?? "Price unavailable") {
                                Task { await access.buy(.full) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(access.price == nil || access.isBusy || access.state == .checking)
                            .accessibilityIdentifier("purchase.buy")
                        }
                        if !access.isUnrestricted {
                            Button("Restore Purchases") { Task { await access.restore() } }
                                .disabled(access.isBusy).accessibilityIdentifier("purchase.restore")
                            if access.price == nil && access.state != .purchased {
                                Button("Retry App Store") { Task { await access.refresh(); await access.loadProducts() } }
                                    .disabled(access.isBusy || access.isLoadingProducts)
                                    .accessibilityIdentifier("purchase.retry")
                            }
                        }
                        #if DEBUG
                        if access.canResetTestAccess {
                            Button("Reset Test Access (Debug)", role: .destructive) { Task { await access.resetTestAccess() } }
                                .disabled(access.isBusy).accessibilityIdentifier("purchase.resetTestAccess")
                        }
                        #endif
                        if access.isBusy || access.isLoadingProducts { ProgressView().accessibilityLabel("Contacting the App Store") }
                        if let message = access.message {
                            Text(message).font(.callout).accessibilityIdentifier("purchase.message")
                        }
                        Button(access.canEdit ? "Continue Modeling" : "Continue Viewing", action: close)
                            .accessibilityIdentifier("purchase.continue")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Text("Requires iPadOS 27 or later and a compatible Apple Pencil. Fingers navigate the canvas; Pencil draws, selects, and edits.")
                    Text("Assistant availability depends on your iPad and model settings. Optional \(AIProvider.offeredNames) requests use your own API key and are billed separately by that company.")
                    Text("Support is provided as time allows, without a guaranteed response or feature schedule. Keep backups of important projects.")
                        .font(.callout).foregroundStyle(Color("ss-muted"))
                }
                .padding(28).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Color("ss-paper")).foregroundStyle(Color("ss-ink"))
            .navigationTitle("Swipe & Sketch").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close).accessibilityIdentifier("purchase.done") } }
        }
        .tint(Color("ss-violet")).preferredColorScheme(.light)
        .task { await access.refresh(); await access.loadProducts() }
        .accessibilityIdentifier("purchase.screen")
    }
}

struct AccessStatusButton: View {
    @ObservedObject var access: AppAccessStore
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(access.statusTitle).font(.headline)
                if let end = access.trialEnd {
                    Text("Ends \(end.formatted(date: .abbreviated, time: .shortened)) · View purchase options")
                } else if access.state == .notStarted {
                    Text("14 days free · One-time purchase afterward")
                } else if access.state == .trialEnded {
                    Text("Unlock to create and edit · Viewing and exports remain available")
                }
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Color("ss-lavender"), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Color("ss-ink")).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("access.status")
    }
}

/// One quiet, dismissible notice near the end; it never covers the modeling canvas.
struct TrialReminder: View {
    @ObservedObject var access: AppAccessStore
    var action: () -> Void
    @AppStorage("purchase.dismissedTrialEnd") private var dismissedEnd = 0.0

    var body: some View {
        if let end = access.trialEnd, end.timeIntervalSinceNow <= 3 * 24 * 60 * 60,
           end.timeIntervalSince1970 != dismissedEnd {
            HStack(alignment: .top, spacing: 12) {
                Button(action: action) {
                    Text("Your trial ends \(end.formatted(date: .abbreviated, time: .shortened)). Make a one-time purchase to continue creating and editing. Your projects remain available to view and export.")
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("trial.reminder")
                Button {
                    dismissedEnd = end.timeIntervalSince1970
                } label: { SSIconGlyph(icon: .exit, size: 22).frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Dismiss trial reminder").accessibilityIdentifier("trial.dismissReminder")
            }
            .buttonStyle(.plain).font(.callout).padding(14)
            .foregroundStyle(Color("ss-ink")).background(Color("ss-paper"), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
