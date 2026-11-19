import SwiftUI
import UniformTypeIdentifiers

/// Import: what each kind of file brings in, then Files showing only that kind. Each import is one
/// undo step in a Model Tree group named after the file. Solids and projects stay where the file
/// had them; a drawing (SVG) is sized and placed in the SVG Import sheet first.
struct ImportSheet: View {
    @Bindable var session: ModelingSession
    var onDone: () -> Void
    @State private var choosing: Kind?

    enum Kind: String, CaseIterable, Identifiable {
        case step, mesh, svg, project
        var id: String { rawValue }
        var title: String {
            switch self {
            case .step: "STEP"
            case .mesh: "Mesh (STL, 3MF)"
            case .svg: "Vector Drawing (SVG)"
            case .project: "Swipe & Sketch Project"
            }
        }
        var icon: SSIcon {
            switch self {
            case .step: .open
            case .mesh: .mesh
            case .svg: .spline
            case .project: .project
            }
        }
        var detail: String {
            switch self {
            case .step: "Solids from a .step or .stp file, such as a part from another CAD app or a supplier, converted to millimeters. They are ordinary solids: fillet any edge, cut, shell, combine, and sketch on their faces."
            case .mesh: "Closed meshes from an .stl or .3mf file, such as a downloaded model to remix. Each becomes a solid whose flat areas are single faces. A mesh with holes in it is left out; repair it in a mesh tool first."
            case .svg: "A logo, icon, sign, or cut file from an .svg file, as editable sketches of lines, arcs, and circles, sized in millimeters. Text, strokes, colors, and pictures in it come in too, and each color can become a solid of its own for a multicolor print."
            case .project: "Everything from another .swipesketch project, its groups too. The copies are this project's own, so changing them leaves the other file alone."
            }
        }
        var types: [UTType] {
            switch self {
            case .step: WorkspaceView.importTypes(mesh: false)
            case .mesh: WorkspaceView.importTypes(mesh: true)
            case .svg: WorkspaceView.svgTypes
            case .project: WorkspaceView.projectTypes
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Kind.allCases) { kind in
                        Button { choosing = kind } label: {
                            HStack(alignment: .top, spacing: 14) {
                                SSIconGlyph(icon: kind.icon, size: 26, color: Color("ss-violet")).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(kind.title).font(.body.weight(.semibold)).foregroundStyle(Color("ss-ink"))
                                    Text(kind.detail).font(.footnote).foregroundStyle(Color("ss-muted"))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(kind.title).accessibilityHint(kind.detail)
                        .accessibilityIdentifier("import.\(kind.rawValue)")
                    }
                } footer: {
                    Text("Solids and projects keep their places from the file; a drawing is sized and placed before it comes in. Everything arrives together in a Model Tree group named after the file, as one step you can undo. Files can also be dropped onto the canvas.")
                }
                Section {
                    PasteButton(supportedContentTypes: [.svg, .utf8PlainText, .plainText]) { providers in
                        ImportDrop.pasteSVG(providers, into: session) { onDone() }
                    }
                    .labelStyle(.titleAndIcon).buttonBorderShape(.capsule)
                    .accessibilityIdentifier("import.pasteSVG")
                } footer: {
                    Text("Paste an SVG drawing copied from a design app (Copy as SVG).")
                }
            }
            .scrollContentBackground(.hidden).background(Color("ss-canvas"))
            .navigationTitle("Import").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone).accessibilityIdentifier("import.cancel") } }
            .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                          allowedContentTypes: choosing?.types ?? []) { result in
                switch result {
                case .success(let url):
                    onDone()
                    // Files showed only the chosen kind; the file's own extension decides.
                    ImportDrop.open(url, in: session)
                case .failure(let error):
                    onDone()
                    session.saveError = "Import failed. \(error.localizedDescription)"
                }
            }
        }
        .tint(Color("ss-violet"))
        .preferredColorScheme(.light)
    }
}

/// Files dropped on the canvas, and SVG pasted: each kind goes to its own import.
enum ImportDrop {
    /// The extensions the canvas takes.
    static let extensions: Set<String> = ["step", "stp", "stl", "3mf", "svg", "svgz", "swipesketch"]

    /// Opens a picked or dropped file with the import its extension calls for.
    @MainActor static func open(_ url: URL, in session: ModelingSession) {
        switch url.pathExtension.lowercased() {
        case "swipesketch": session.importProject(from: url)
        case "stl", "3mf": session.importMesh(from: url)
        case "svg", "svgz": session.importSVG(from: url)
        default: session.importSTEP(from: url)
        }
    }

    /// Takes the first dropped file the app can import (copied out of the drop first, since a
    /// dropped file lasts only as long as the drop), or dropped SVG markup. False when there is none.
    @MainActor static func drop(_ providers: [NSItemProvider], into session: ModelingSession) -> Bool {
        guard !session.isEditingBlocked else { return false }
        for provider in providers {
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            if let type = types.first(where: { $0.preferredFilenameExtension.map { extensions.contains($0.lowercased()) } ?? false }) {
                let name = provider.suggestedName
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url, let copy = copied(url, name: name, type: type) else { return }
                    Task { @MainActor in open(copy, in: session) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.svg.identifier) {
                let name = provider.suggestedName ?? "Drawing"
                provider.loadDataRepresentation(forTypeIdentifier: UTType.svg.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in session.importSVG(data: data, name: name) }
                }
                return true
            }
        }
        return false
    }

    /// Pasted SVG: an SVG item, or text that is SVG markup.
    @MainActor static func pasteSVG(_ providers: [NSItemProvider], into session: ModelingSession, then done: @escaping @MainActor () -> Void) {
        guard let provider = providers.first else { return }
        let svg = provider.hasItemConformingToTypeIdentifier(UTType.svg.identifier)
        let type = svg ? UTType.svg.identifier : provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) ? UTType.utf8PlainText.identifier : UTType.plainText.identifier
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            Task { @MainActor in
                guard let data, svg || isMarkup(data) else {
                    done()
                    session.saveError = "Import failed. What was copied is not an SVG drawing."
                    return
                }
                done()
                session.importSVG(data: data, name: "Pasted Drawing")
            }
        }
    }

    /// Whether text looks like SVG markup (it has an <svg element near its start).
    static func isMarkup(_ data: Data) -> Bool {
        let start = String(decoding: data.prefix(4_096), as: UTF8.self).lowercased()
        return start.contains("<svg")
    }

    nonisolated private static func copied(_ url: URL, name: String?, type: UTType) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileName = name.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
        let destination = folder.appendingPathComponent(fileName).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch { return nil }
    }
}
