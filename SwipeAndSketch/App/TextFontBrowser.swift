import SwiftUI

/// All Fonts, from the Text tool's font menu: every font this iPad has, by family, each face
/// showing the text being placed in it. Tapping a face uses it and closes the sheet. The menu keeps
/// the suggested fonts and the ones used lately; the outlines are saved with the text, so a font
/// only needs to be on the iPad that edits the text.
struct TextFontBrowser: View {
    var current: String
    var sample: String
    var onChoose: (String) -> Void
    var onCancel: () -> Void
    @State private var families: [(family: String, faces: [TextFonts.Face])] = []
    @State private var search = ""
    @State private var expanded: Set<String> = []

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    /// The families matching the search: a family by its name keeps all its faces, otherwise only
    /// the faces whose names match.
    private var shown: [(family: String, faces: [TextFonts.Face])] {
        guard !query.isEmpty else { return families }
        return families.compactMap { entry in
            if entry.family.localizedCaseInsensitiveContains(query) { return entry }
            let faces = entry.faces.filter { $0.fullName.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
            return faces.isEmpty ? nil : (entry.family, faces)
        }
    }

    private var preview: String {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Swipe & Sketch 123" : String(text.prefix(40))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        ForEach(shown, id: \.family) { entry in
                            if entry.faces.count == 1 {
                                faceRow(entry.faces[0], title: entry.family).id(entry.family)
                            } else {
                                DisclosureGroup(isExpanded: isExpanded(entry.family)) {
                                    ForEach(entry.faces) { faceRow($0, title: $0.style) }
                                } label: {
                                    familyLabel(entry.family, faces: entry.faces)
                                        .accessibilityIdentifier("textFonts.family.\(entry.family)")
                                }
                                .id(entry.family)
                            }
                        }
                    } footer: {
                        Text(families.isEmpty ? "" : "Bold, plain letters print most cleanly. Thin, script, and decorative faces can be too fine for small text.")
                    }
                }
                .overlay {
                    if !families.isEmpty, shown.isEmpty {
                        Text("No fonts match “\(query)”.").font(.body).foregroundStyle(Color("ss-muted"))
                    }
                }
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search fonts")
                .autocorrectionDisabled()
                .task {
                    families = TextFonts.installedFamilies()
                    guard let family = families.first(where: { $0.faces.contains { $0.name == current } })?.family else { return }
                    expanded.insert(family)
                    await Task.yield()
                    proxy.scrollTo(family, anchor: .center)
                }
            }
            .navigationTitle("All Fonts").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).accessibilityIdentifier("textFonts.cancel")
                }
            }
        }
        .preferredColorScheme(.light)  // light like the app's other sheets, even in Dark Mode
    }

    /// Searching opens every family it finds.
    private func isExpanded(_ family: String) -> Binding<Bool> {
        Binding(get: { !query.isEmpty || expanded.contains(family) },
                set: { open in if open { expanded.insert(family) } else { expanded.remove(family) } })
    }

    private func familyLabel(_ family: String, faces: [TextFonts.Face]) -> some View {
        // The family's name in its plainest face: upright, nearest regular weight.
        let plain = faces.min { (abs($0.weight) + ($0.italic ? 2 : 0)) < (abs($1.weight) + ($1.italic ? 2 : 0)) }
        return HStack(alignment: .firstTextBaseline) {
            Text(family).font(.custom(plain?.name ?? family, size: 18)).foregroundStyle(Color("ss-ink")).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(faces.count) styles").font(.footnote).foregroundStyle(Color("ss-muted"))
        }
        .accessibilityElement(children: .combine)
    }

    private func faceRow(_ face: TextFonts.Face, title: String) -> some View {
        Button { onChoose(face.name) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.footnote).foregroundStyle(Color("ss-muted"))
                    Text(preview).font(.custom(face.name, size: 22)).foregroundStyle(Color("ss-ink")).lineLimit(1)
                }
                Spacer(minLength: 0)
                if face.name == current {
                    SSIconGlyph(icon: .done, size: 18, color: Color("ss-violet"))
                }
            }
            .padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.name == current ? "\(face.fullName), in use" : face.fullName)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("textFonts.face.\(face.name)")
    }
}
