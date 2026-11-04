import SwiftUI

/// Explicit provider choice and a device-local credential; no requests are made by saving a key.
struct AssistantSettingsView: View {
    var onDone: () -> Void
    @AppStorage("assistant.model") private var model = AssistantModelChoice.automatic.rawValue
    @AppStorage("radialToolbarEnabled") private var radialToolbarEnabled = true
    @State private var key = ""
    @State private var hasKey = false
    @State private var status = ""
    @State private var failed = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    Picker("Tool Layout", selection: $radialToolbarEnabled) {
                        Text("Radial Toolbar").tag(true)
                        Text("Dock").tag(false)
                    }
                    .accessibilityIdentifier("settings.toolLayout")
                    Text("Drag the radial toolbar by its center. Use the bottom-right Tools button or squeeze Apple Pencil Pro to show or hide it. Set Pencil squeeze to Show Contextual Palette in iPad Settings.")
                        .font(.footnote).foregroundStyle(Color("ss-muted"))
                }
                Section("Assistant") {
                    NavigationLink {
                        AssistantModelSettings(selection: $model)
                    } label: {
                        HStack {
                            Text("Model")
                            Spacer()
                            Text(AssistantModelChoice(rawValue: model)?.title ?? "Automatic (Apple)")
                                .foregroundStyle(Color("ss-muted"))
                        }
                    }
                    .accessibilityValue(AssistantModelChoice(rawValue: model)?.title ?? "Automatic (Apple)")
                    .accessibilityIdentifier("settings.assistant.model")
                    Text("Automatic uses Apple's models. Select Claude Opus 5.5 · High to use your Anthropic API account.")
                        .font(.footnote).foregroundStyle(Color("ss-muted"))
                }
                Section {
                    Text(hasKey ? "An API key is saved on this device." : "No API key is saved.")
                        .accessibilityIdentifier("settings.claude.status")
                    SecureField(hasKey ? "Replacement Claude API key" : "Claude API key", text: $key)
                        .focused($keyFocused)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().accessibilityIdentifier("settings.claude.key")
                    Button(hasKey ? "Replace API Key" : "Save API Key") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("settings.claude.save")
                    if hasKey {
                        Button("Remove API Key") { remove() }
                            .foregroundStyle(Color("ss-coral"))
                            .accessibilityIdentifier("settings.claude.remove")
                    }
                    if !status.isEmpty {
                        Text(status).font(.footnote)
                            .foregroundStyle(Color(failed ? "ss-coral" : "ss-muted"))
                            .accessibilityIdentifier("settings.claude.feedback")
                    }
                    Link("Get an Anthropic API key", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                } header: {
                    Text("Claude API Key")
                } footer: {
                    Text("Your key is stored in this device's Keychain. When you select Claude and send a request, your request, conversation, model summary, and CAD tool results are sent directly to Anthropic. Anthropic bills API usage to your account; a Claude subscription does not cover API usage.")
                }
            }
            .scrollContentBackground(.hidden).background(Color("ss-canvas"))
            .foregroundStyle(Color("ss-ink"))
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).accessibilityIdentifier("settings.done")
                }
            }
            .tint(Color("ss-violet"))
        }
        .onAppear {
            do { hasKey = try ClaudeCredentials.shared.read() != nil }
            catch { show(error) }
        }
        .onDisappear { key = "" }
    }

    private func save() {
        do {
            try ClaudeCredentials.shared.save(key)
            keyFocused = false; key = ""; hasKey = true; failed = false
            status = "API key saved. Select Claude Opus 5.5 · High to use it."
        } catch { show(error) }
    }

    private func remove() {
        do {
            try ClaudeCredentials.shared.remove()
            keyFocused = false; key = ""; hasKey = false; failed = false; status = "API key removed."
        } catch { show(error) }
    }

    private func show(_ error: Error) { status = error.localizedDescription; failed = true }
}

private struct AssistantModelSettings: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(AssistantModelChoice.allCases) { choice in
            Button {
                selection = choice.rawValue
                dismiss()
            } label: {
                HStack {
                    Text(choice.title)
                    Spacer()
                    if selection == choice.rawValue {
                        SSIconGlyph(icon: .done, size: 20, color: Color("ss-violet")).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color("ss-ink"))
            .accessibilityLabel(choice.title)
        }
        .scrollContentBackground(.hidden).background(Color("ss-canvas"))
        .navigationTitle("Assistant Model").navigationBarTitleDisplayMode(.inline)
    }
}
