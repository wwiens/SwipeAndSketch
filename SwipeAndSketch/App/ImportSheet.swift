import SwiftUI
import UniformTypeIdentifiers

/// Import: what each kind of file brings in, then Files showing only that kind. Each import is one
/// undo step, placed where the file had it, in a Model Tree group named after the file.
struct ImportSheet: View {
    @Bindable var session: ModelingSession
    var onDone: () -> Void
    @State private var choosing: Kind?

    enum Kind: String, CaseIterable, Identifiable {
        case step, mesh, project
        var id: String { rawValue }
        var title: String {
            switch self {
            case .step: "STEP"
            case .mesh: "Mesh (STL, 3MF)"
            case .project: "Swipe & Sketch Project"
            }
        }
        var icon: SSIcon {
            switch self {
            case .step: .open
            case .mesh: .mesh
            case .project: .project
            }
        }
        var detail: String {
            switch self {
            case .step: "Solids from a .step or .stp file, such as a part from another CAD app or a supplier, converted to millimeters. They are ordinary solids: fillet any edge, cut, shell, combine, and sketch on their faces."
            case .mesh: "Closed meshes from an .stl or .3mf file, such as a downloaded model to remix. Each becomes a solid whose flat areas are single faces. A mesh with holes in it is left out; repair it in a mesh tool first."
            case .project: "Everything from another .swipesketch project, its groups too. The copies are this project's own, so changing them leaves the other file alone."
            }
        }
        var types: [UTType] {
            switch self {
            case .step: WorkspaceView.importTypes(mesh: false)
            case .mesh: WorkspaceView.importTypes(mesh: true)
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
                    Text("Imported items keep their places from the file and arrive together in a Model Tree group named after it, as one step you can undo.")
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
                    switch url.pathExtension.lowercased() {
                    case "swipesketch": session.importProject(from: url)
                    case "stl", "3mf": session.importMesh(from: url)
                    default: session.importSTEP(from: url)
                    }
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
