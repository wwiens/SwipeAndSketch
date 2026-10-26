import SwiftUI
import Combine

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let hairline = Color("ss-border")
private let white = Color("ss-white")
private let lavender = Color("ss-lavender")

/// The AI assistant: a conversation panel at the right edge (the Items list's counterpart on the
/// left), like the assistant panels of desktop CAD tools, so the canvas stays in view. Requests
/// can be typed, dictated, or written with Apple Pencil (Scribble). Changes preview on the canvas
/// and are kept or discarded from the bar that replaces the dock.
struct AssistantPanel: View {
    @ObservedObject var assistant: AssistantController
    /// Not observed: the panel follows the controller, so it does not redraw with every change to
    /// the model (each frame of a drag).
    let session: ModelingSession
    /// Bumped to put the cursor in the field (the Assistant tile with something selected).
    var focusRequest: Int
    var close: () -> Void
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var license = LicenseStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(hairline.opacity(0.6))
            conversation
            if license.access.canUseAssistant { composer } else { locked }
        }
        .background(white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(hairline.opacity(0.6)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        .onChange(of: focusRequest) { fieldFocused = true }
        // Once a request is sent, the keyboard goes away so the canvas (and Keep / Discard) show.
        .onChange(of: assistant.isWorking) { if assistant.isWorking { fieldFocused = false } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.panel")
        .onAppear { assistant.refreshModelStatus() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SSIconGlyph(icon: .assistant, size: 24, color: violet)
            Text("Assistant").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 2)
            Menu {
                Picker("Model", selection: $assistant.choice) {
                    ForEach(AssistantModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Section {
                    Text(modelNote)
                }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(assistant.modelStatus.available ? Color("ss-lime") : Color("ss-coral"))
                        .overlay(Circle().stroke(ink.opacity(0.35), lineWidth: 0.5)).frame(width: 8, height: 8)
                    Text(assistant.modelStatus.available ? assistant.modelStatus.title : "Unavailable")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(ink).lineLimit(1)
                }
                .padding(.horizontal, 9).frame(height: 30)
                .background(Color("ss-neutral"), in: Capsule())
                .fixedSize()
            }
            .accessibilityLabel("Model")
            .accessibilityValue(assistant.modelStatus.title)
            .accessibilityIdentifier("assistant.model")
            Button { assistant.newConversation() } label: {
                SSIconGlyph(icon: .newProject, size: 22, color: ink).frame(width: 34, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(assistant.isWorking || assistant.messages.isEmpty)
            .opacity(assistant.isWorking || assistant.messages.isEmpty ? 0.35 : 1)
            .accessibilityLabel("New conversation").accessibilityIdentifier("assistant.new")
            Button(action: close) {
                SSIconGlyph(icon: .exit, size: 20, color: ink).frame(width: 34, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Close assistant").accessibilityIdentifier("assistant.close")
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 52)
    }

    private var modelNote: String {
        switch assistant.choice {
        case .automatic: "Uses Private Cloud Compute when it can, and the on-device model otherwise."
        case .cloud: "Apple's larger model on Private Cloud Compute. Your model data is not stored."
        case .onDevice: "Runs on this iPad, offline. Best for one or two changes at a time."
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if assistant.messages.isEmpty { emptyState }
                    ForEach(assistant.messages) { message in
                        MessageView(message: message, canReview: !assistant.isWorking, retry: { assistant.retry(message) },
                                    keep: { assistant.keep() }, discard: { assistant.discard() }).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: assistant.messages) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe a part or a change, or ask about your model. Changes appear on the canvas for you to keep or discard.")
                .font(.system(size: 14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            ForEach(assistant.suggestions, id: \.self) { suggestion in
                Button { assistant.send(suggestion) } label: {
                    Text(suggestion).font(.system(size: 14)).foregroundStyle(ink).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color("ss-neutral"), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!assistant.modelStatus.available)
                .accessibilityIdentifier("assistant.suggestion")
            }
        }
    }

    /// After the free trial: what the assistant needs, and the way to it.
    private var locked: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(license.access.ownsUnlock
                 ? license.access.trialStart == nil
                    ? "Start the free 7-day trial of the AI Assistant, or buy it to ask about and change your models."
                    : "The free trial of the AI Assistant has ended. Buy AI Assistant to keep asking about and changing your models."
                 : license.access.trialStart == nil
                    ? "Start the free 7-day trial to use the AI Assistant."
                    : "The free trial has ended. The AI Assistant comes back with Unlock and the AI Assistant purchase.")
                .font(.system(size: 13)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.locked")
            Button { license.isShowingStore = true } label: {
                Text(license.access.canStartTrial ? "Start Free Trial…" : "See Purchases…").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(paper).frame(maxWidth: .infinity).frame(height: 36)
                    .background(violet, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).accessibilityIdentifier("assistant.purchases")
        }
        .padding(12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = assistant.selectionLabel {
                // What "this" and "it" refer to: the selection when the request was typed.
                HStack(spacing: 5) {
                    SSIconGlyph(icon: .select, size: 16, color: violet)
                    Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(ink).lineLimit(1)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(lavender, in: Capsule())
                .accessibilityIdentifier("assistant.selection")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(assistant.isReviewing ? "Refine the changes, or ask…" : "Describe a change or ask…", text: $assistant.draft, axis: .vertical)
                    .font(.system(size: 15)).foregroundStyle(ink)
                    .lineLimit(1...5)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit { assistant.send() }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color("ss-neutral"), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(!assistant.modelStatus.available)
                    .accessibilityIdentifier("assistant.input")
                if assistant.isWorking {
                    Button { assistant.stop() } label: { SSIconTile(icon: .stop) }
                        .buttonStyle(.plain).accessibilityLabel("Stop").accessibilityIdentifier("assistant.stop")
                } else {
                    let empty = assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { assistant.send() } label: { SSIconTile(icon: .send, selected: !empty, enabled: !empty) }
                        .buttonStyle(.plain).disabled(empty || !assistant.modelStatus.available)
                        .accessibilityLabel("Send").accessibilityIdentifier("assistant.send")
                }
            }
            if !assistant.modelStatus.available {
                Text(assistant.modelStatus.title).font(.system(size: 12)).foregroundStyle(Color("ss-coral"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }
}

/// One request or reply. A reply lists the changes the tools actually made, and their review state.
private struct MessageView: View {
    let message: AssistantController.Message
    var canReview: Bool
    var retry: () -> Void
    var keep: () -> Void
    var discard: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 36)
                Text(message.text).font(.system(size: 15)).foregroundStyle(ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(lavender, in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("assistant.request")
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message.activity ?? "Thinking").font(.system(size: 13)).foregroundStyle(muted).lineLimit(2)
                    }
                    .accessibilityIdentifier("assistant.working")
                }
                if !message.text.isEmpty {
                    Text(message.text).font(.system(size: 15)).foregroundStyle(message.failed ? Color("ss-coral") : ink)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("assistant.reply")
                }
                if !message.changes.isEmpty { changeCard }
                HStack(spacing: 10) {
                    if let backend = message.backend {
                        Text(backend.shortTitle).font(.system(size: 11)).foregroundStyle(muted)
                    }
                    if message.failed {
                        Button("Try again", action: retry).font(.system(size: 13, weight: .medium)).disabled(!canReview).accessibilityIdentifier("assistant.retry")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var changeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(status.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(status.color)
                Spacer()
            }
            ForEach(Array(message.changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(muted).frame(width: 4, height: 4).offset(y: -3)
                    Text(change).font(.system(size: 13)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            if message.review == .pending {
                // The same choice as the bar in place of the dock, within reach of the conversation.
                HStack(spacing: 8) {
                    Button(action: discard) {
                        Text("Discard").font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
                            .padding(.horizontal, 14).frame(height: 34).background(white, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("assistant.card.discard")
                    Button(action: keep) {
                        Text("Keep").font(.system(size: 14, weight: .semibold)).foregroundStyle(paper)
                            .padding(.horizontal, 16).frame(height: 34).background(violet, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("assistant.card.keep")
                }
                .disabled(!canReview).opacity(canReview ? 1 : 0.4)
                .padding(.top, 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.review == .pending ? Color("ss-limeSoft") : Color("ss-neutral"), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hairline.opacity(0.6)))
        .opacity(message.review == .discarded ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.changes")
    }

    private var status: (title: String, color: Color) {
        switch message.review {
        case .pending: ("PREVIEW ON THE CANVAS", ink)
        case .kept: ("KEPT", muted)
        case .discarded: ("DISCARDED", muted)
        case .none: ("CHANGES", muted)
        }
    }
}

/// How far the software keyboard covers the bottom of the screen, so the panel's field stays above it.
@MainActor final class KeyboardInset: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    private var subscription: AnyCancellable?

    init() {
        let center = NotificationCenter.default
        subscription = center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .merge(with: center.publisher(for: UIResponder.keyboardWillHideNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let frame = note.name == UIResponder.keyboardWillHideNotification ? .zero
                    : (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                // Keyboard notifications carry the screen the keyboard is on.
                let screen = (note.object as? UIScreen)?.bounds ?? frame
                MainActor.assumeIsolated {
                    self?.height = frame == .zero || frame.minY >= screen.maxY ? 0 : max(0, screen.maxY - frame.minY)
                }
            }
    }
}
