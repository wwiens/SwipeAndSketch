import SwiftUI

/// App settings: the workspace, units, the fit clearance, and the assistant's provider and
/// device-local credential (no requests are made by saving a key). Opened from Home, the project
/// menu, and the assistant panel; from a project, units and clearance change it at once.
struct AssistantSettingsView: View {
    var session: ModelingSession? = nil
    var onDone: () -> Void
    @AppStorage("assistant.model") private var model = AssistantModelChoice.automatic.rawValue
    @AppStorage("radialToolbarEnabled") private var radialToolbarEnabled = true
    @AppStorage(TouchHighlighter.defaultsKey) private var showTouches = false
    @State private var unit = LengthUnit.millimeters
    @State private var clearance = Fit.defaultClearance
    /// Custom stays chosen while its value happens to equal a preset's.
    @State private var customFit = false
    @State private var loaded = false
    /// Which providers have a key saved, for their rows' summaries.
    @State private var keys: Set<AIProvider> = []

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
                    if TouchHighlighter.isAvailable {
                        Toggle("Show Touches", isOn: $showTouches)
                            .accessibilityIdentifier("settings.showTouches")
                        Text("Shows a circle where fingers touch and a ring at the Apple Pencil tip, so taps and drags can be seen in screen recordings.")
                            .font(.footnote).foregroundStyle(Color("ss-muted"))
                    }
                }
                Section {
                    Picker("Units", selection: $unit) {
                        ForEach(LengthUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("settings.units")
                } header: { Text("Units") } footer: {
                    Text("Labels, the keypad, the grid, and snapping use these units. Projects always store millimeters.")
                }
                Section {
                    Picker("Fit Clearance", selection: fitChoice) {
                        ForEach(Fit.Preset.allCases, id: \.self) { preset in
                            Text("\(preset.title) · \(lengthText(preset.clearance))").tag(Optional(preset))
                        }
                        Text("Custom").tag(Fit.Preset?.none)
                    }
                    .accessibilityIdentifier("settings.fit")
                    if fitChoice.wrappedValue == nil {
                        // Hundredths of a millimeter, so repeated steps never drift.
                        Stepper(value: Binding(get: { clearance }, set: { clearance = ($0 * 100).rounded() / 100 }),
                                in: Fit.clearanceRange, step: 0.05) {
                            Text("Gap: \(lengthText(clearance))").monospacedDigit()
                        }
                        .accessibilityIdentifier("settings.fit.custom")
                    }
                } header: { Text("Fit Clearance") } footer: {
                    Text("The gap on each side that new pegs, threads, lids, and Subtract clearances start from. It depends on your printer: Joints ▸ Fit Test adds a test print to find yours. Parts already made keep their own gap.")
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
                    Text("Automatic uses Apple's models. Claude, OpenAI, and Gemini use your own API key from that company, with the model and effort you choose for it.")
                        .font(.footnote).foregroundStyle(Color("ss-muted"))
                }
                Section {
                    ForEach(AIProvider.allCases) { provider in
                        NavigationLink {
                            ProviderSettingsView(provider: provider, choice: $model, onDone: onDone)
                        } label: {
                            HStack {
                                Text(provider.title)
                                Spacer()
                                Text(keys.contains(provider) ? ProviderSettings.model(for: provider).name : "No API key")
                                    .foregroundStyle(Color("ss-muted")).lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("settings.provider.\(provider.rawValue)")
                    }
                } header: { Text("AI Providers") } footer: {
                    Text("Each needs an API key from its company. Usage is billed to your account there.")
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
        // The light-only design, as the other sheets: in Dark Mode the rows and title were dark
        // while the page and text stayed light-mode colors, so labels were dark on dark.
        .preferredColorScheme(.light)
        .onAppear {
            if !loaded {
                unit = session?.lengthUnit ?? LengthUnit(rawValue: UserDefaults.standard.string(forKey: "lengthUnit") ?? "") ?? .millimeters
                clearance = session?.fitClearance ?? Fit.preferredClearance
                customFit = Fit.preset(for: clearance) == nil
                loaded = true
            }
            refreshKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: APICredentials.didChange)) { _ in refreshKeys() }
        .onChange(of: unit) { _, unit in
            guard loaded else { return }
            if let session { session.lengthUnit = unit } else { UserDefaults.standard.set(unit.rawValue, forKey: "lengthUnit") }
        }
        .onChange(of: clearance) { _, clearance in
            guard loaded, Fit.clearanceRange.contains(clearance) else { return }
            if let session { session.setFitClearance(clearance) } else { Fit.preferredClearance = clearance }
        }
    }

    private func refreshKeys() {
        keys = Set(AIProvider.allCases.filter { (try? $0.credentials.read()) != nil })
    }

    /// A preset, or nil for Custom.
    private var fitChoice: Binding<Fit.Preset?> {
        Binding(get: { customFit ? nil : Fit.preset(for: clearance) }, set: { preset in
            if let preset { customFit = false; clearance = preset.clearance } else { customFit = true }
        })
    }

    private func lengthText(_ millimeters: Double) -> String { formatted(length: millimeters, unit: unit) + " " + unit.symbol }
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

/// One provider's API key, model, and effort, and whether the assistant uses it. Saving a key reads
/// the models it can use; nothing else is sent until a request is made with the provider chosen.
private struct ProviderSettingsView: View {
    let provider: AIProvider
    @Binding var choice: String
    var onDone: () -> Void
    @State private var key = ""
    @State private var hasKey = false
    @State private var status = ""
    @State private var failed = false
    @State private var models: [ProviderModel] = []
    @State private var model = ProviderModel(id: "", name: "")
    @State private var effort = AssistantEffort.high
    @State private var loading = false
    @State private var listNote = ""
    @State private var loaded = false
    @FocusState private var keyFocused: Bool
    /// Providers whose list was read since the app started, so opening the page again doesn't ask.
    @MainActor private static var listed: Set<AIProvider> = []

    private var id: String { provider.rawValue }

    var body: some View {
        Form {
            Section {
                Text(hasKey ? "An API key is saved on this device." : "No API key is saved.")
                    .accessibilityIdentifier("settings.\(id).status")
                SecureField(hasKey ? "Replacement \(provider.title) API key" : "\(provider.title) API key", text: $key)
                    .focused($keyFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive().accessibilityIdentifier("settings.\(id).key")
                Button(hasKey ? "Replace API Key" : "Save API Key") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.\(id).save")
                if hasKey {
                    Button("Remove API Key") { remove() }
                        .foregroundStyle(Color("ss-coral"))
                        .accessibilityIdentifier("settings.\(id).remove")
                }
                if !status.isEmpty {
                    Text(status).font(.footnote)
                        .foregroundStyle(Color(failed ? "ss-coral" : "ss-muted"))
                        .accessibilityIdentifier("settings.\(id).feedback")
                }
                Link("Get \(provider == .openAI ? "an" : "a") \(provider.company) API key", destination: provider.keyPage)
            } header: { Text("API Key") } footer: { Text(provider.dataNote) }
            Section {
                Picker("Model", selection: $model) {
                    ForEach(models.contains(model) || model.id.isEmpty ? models : [model] + models) { Text($0.name).tag($0) }
                }
                .accessibilityIdentifier("settings.\(id).model")
                Button { Task { await refresh() } } label: {
                    HStack {
                        Text("Refresh Model List")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(!hasKey || loading).accessibilityIdentifier("settings.\(id).refresh")
            } header: { Text("Model") } footer: {
                Text(listNote.isEmpty ? "The models your key can use, as \(provider.company) lists them once the key is saved. Changing the model starts a new conversation." : listNote)
            }
            Section {
                Picker("Effort", selection: $effort) {
                    ForEach(AssistantEffort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("settings.\(id).effort")
            } header: { Text("Effort") } footer: {
                let unsupported = model.efforts.map { !$0.contains(effort.rawValue) } ?? false
                Text("Higher effort thinks longer: better for bigger changes, but slower and more expensive."
                     + (unsupported ? " \(model.name) doesn't take this level, so it uses its own default." : ""))
            }
            Section {
                Button(choice == provider.choice.rawValue ? "The Assistant Uses \(provider.title)" : "Use \(provider.title) for the Assistant") {
                    choice = provider.choice.rawValue
                }
                .disabled(choice == provider.choice.rawValue)
                .accessibilityIdentifier("settings.\(id).use")
            }
        }
        .scrollContentBackground(.hidden).background(Color("ss-canvas"))
        .navigationTitle(provider.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).accessibilityIdentifier("settings.done") }
        }
        .onAppear {
            if !loaded {
                models = ProviderSettings.models(for: provider)
                model = ProviderSettings.model(for: provider)
                effort = ProviderSettings.effort(for: provider)
                loaded = true
            }
            do { hasKey = try provider.credentials.read() != nil } catch { show(error) }
            if hasKey && !Self.listed.contains(provider) { Task { await refresh() } }
        }
        .onChange(of: model) { _, model in if loaded, !model.id.isEmpty { ProviderSettings.setModel(model, for: provider) } }
        .onChange(of: effort) { _, effort in if loaded { ProviderSettings.setEffort(effort, for: provider) } }
        .onDisappear { key = "" }
    }

    /// Reads the models the saved key can use; the last list stays if that fails.
    private func refresh() async {
        guard !loading, let saved = try? provider.credentials.read() else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await ProviderCatalog.fetch(provider, key: saved)
            ProviderSettings.storeModels(list, for: provider)
            Self.listed.insert(provider)
            models = list
            model = ProviderSettings.model(for: provider)
            listNote = "\(list.count) \(list.count == 1 ? "model" : "models") from \(provider.company). Changing the model starts a new conversation."
        } catch {
            listNote = error.localizedDescription
        }
    }

    private func save() {
        do {
            try provider.credentials.save(key)
            keyFocused = false; key = ""; hasKey = true; failed = false
            status = choice == provider.choice.rawValue ? "API key saved." : "API key saved. Choose Use \(provider.title) for the Assistant to use it."
            Self.listed.remove(provider)
            Task { await refresh() }
        } catch { show(error) }
    }

    private func remove() {
        do {
            try provider.credentials.remove()
            keyFocused = false; key = ""; hasKey = false; failed = false; status = "API key removed."
        } catch { show(error) }
    }

    private func show(_ error: Error) { status = error.localizedDescription; failed = true }
}
