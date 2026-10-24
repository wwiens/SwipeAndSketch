import SwiftUI
import UniformTypeIdentifiers

// Print-ready 3MF: parts named as in the Model Tree,
// placed on the printer's plate, with a preview picture. Export 3MF shares the file; Send to Slicer
// also saves it straight into a chosen folder, such as one in iCloud Drive that a slicer on a Mac
// opens, replacing the last version, so each change is one tap away from the printer.

enum PrintSheetMode: String, Identifiable {
    case export, send
    var id: String { rawValue }
}

/// Which solids go to the printer.
enum PrintParts: String, CaseIterable {
    case visible, selected
}

extension PrintLayout {
    static var stored: PrintLayout {
        var layout = PrintLayout()
        let defaults = UserDefaults.standard
        if let placement = defaults.string(forKey: "print.placement").flatMap(Placement.init) { layout.placement = placement }
        let width = defaults.double(forKey: "print.bedWidth"), depth = defaults.double(forKey: "print.bedDepth")
        if width >= 50, width <= 2000, depth >= 50, depth <= 2000 { layout.bed = [width, depth] }
        return layout
    }
    func store() {
        let defaults = UserDefaults.standard
        defaults.set(placement.rawValue, forKey: "print.placement")
        defaults.set(bed.x, forKey: "print.bedWidth")
        defaults.set(bed.y, forKey: "print.bedDepth")
    }
    var bedTitle: String {
        PrintLayout.beds.first { $0.size == bed }?.title ?? "\(formatted(bed.x)) × \(formatted(bed.y)) mm"
    }
}

/// The remembered print folder (a security-scoped bookmark).
enum PrintFolder {
    private static let key = "print.folderBookmark"
    static var url: URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: key) }
        return url
    }
    static var name: String? { url?.lastPathComponent }
    static func remember(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        UserDefaults.standard.set(try url.bookmarkData(), forKey: key)
    }
}

extension ModelingSession {
    /// The solids a print would include, with their Model Tree names.
    func printParts(_ choice: PrintParts) -> [ModelExport.PrintPart] {
        let names = workspace.bodyNames
        let bodies: [SolidBody]
        switch choice {
        case .visible: bodies = workspace.bodies.filter { !workspace.isHidden($0) }
        case .selected: bodies = workspace.bodies.filter { selectedMembers.bodies.contains($0.id) }
        }
        return bodies.map { ModelExport.PrintPart(body: $0, name: names[$0.id] ?? "Solid") }
    }

    /// Whether the parts fit the plate as laid out (from the solids' boxes).
    func printFits(_ choice: PrintParts) -> Bool {
        let boxes = printParts(choice).compactMap { try? SolidKernel.solid(for: $0.body).bounds }
        return PrintLayout.Placement.offsets(for: boxes, layout: printLayout).fits
    }

    func rememberPrintFolder(_ url: URL) {
        do {
            try PrintFolder.remember(url)
            printFolderName = PrintFolder.name
        } catch {
            saveError = "That folder cannot be used. \(error.localizedDescription)"
        }
    }

    /// Writes the print-ready 3MF off the main thread, then shares it or saves it into the print folder.
    func sendToPrinter(_ choice: PrintParts, toFolder: Bool) {
        let parts = printParts(choice)
        guard !parts.isEmpty, !isProjectBusy else { return }
        let folder = toFolder ? PrintFolder.url : nil
        if toFolder && folder == nil { return }
        cancelTransient()
        printSheet = nil
        isProjectBusy = true
        status = toFolder ? "Sending to the print folder…" : "Exporting 3MF…"
        let layout = printLayout, name = projectName, thumbnail = thumbnailProvider?()
        if let previous = exportItem?.url.deletingLastPathComponent() { try? FileManager.default.removeItem(at: previous) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { () throws -> URL in
                let data = try ModelExport.threeMF(parts, title: name, layout: layout, thumbnail: thumbnail)
                let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                if let folder {
                    // Replaces the last version, so the slicer's recent file is always the newest.
                    let access = folder.startAccessingSecurityScopedResource()
                    defer { if access { folder.stopAccessingSecurityScopedResource() } }
                    let target = folder.appendingPathComponent(safeName).appendingPathExtension("3mf")
                    var coordinationError: NSError?, writeError: Error?
                    NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
                        do { try data.write(to: url, options: .atomic) } catch { writeError = error }
                    }
                    if let error = coordinationError ?? writeError { throw error }
                    return target
                }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                let url = temporary.appendingPathComponent(safeName).appendingPathExtension("3mf")
                try data.write(to: url, options: .atomic)
                return url
            }
            await self?.finishPrintExport(result, toFolder: folder != nil)
        }
    }

    private func finishPrintExport(_ result: Result<URL, any Error>, toFolder: Bool) {
        isProjectBusy = false
        switch result {
        case .success(let url):
            if toFolder {
                status = "Sent \(url.lastPathComponent) to \(url.deletingLastPathComponent().lastPathComponent)"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                exportItem = ExportItem(url: url)
                status = "Exported 3MF"
            }
        case .failure(let error):
            status = "Not exported"
            saveError = (toFolder ? "Could not save to the print folder. " : "Export failed. ") + error.localizedDescription
        }
    }
}

/// Export 3MF and Send to Slicer: which parts, how they sit on the plate, and where they go.
struct PrintSheet: View {
    @ObservedObject var session: ModelingSession
    let mode: PrintSheetMode
    @State private var parts = PrintParts.visible
    @State private var choosingFolder = false

    var body: some View {
        let count = session.printParts(.visible).count
        NavigationStack {
            Form {
                Section {
                    Picker("Parts", selection: $parts) {
                        Text(count == 1 ? "The visible solid" : "All \(count) visible solids").tag(PrintParts.visible)
                        if session.selectedGroup.map({ !session.workspace.contents(of: $0).bodies.isEmpty }) == true {
                            Text("The selected group").tag(PrintParts.selected)
                        } else if session.selectedBody != nil { Text("The selected solid").tag(PrintParts.selected) }
                    }
                    .accessibilityIdentifier("print.parts")
                    // Export from a selected group starts with just its solids.
                    .onAppear { if session.selectedGroup != nil, !session.printParts(.selected).isEmpty { parts = .selected } }
                } footer: { Text("Each part is named as in the Model Tree, so the slicer's object list matches.") }
                Section {
                    Picker("Placement", selection: $session.printLayout.placement) {
                        ForEach(PrintLayout.Placement.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("print.placement")
                    Picker("Plate", selection: Binding(get: { session.printLayout.bed }, set: { session.printLayout.bed = $0 })) {
                        ForEach(PrintLayout.beds, id: \.title) { Text($0.title).tag($0.size) }
                        if !PrintLayout.beds.contains(where: { $0.size == session.printLayout.bed }) {
                            Text(session.printLayout.bedTitle).tag(session.printLayout.bed)
                        }
                    }
                    .accessibilityIdentifier("print.bed")
                    if !session.printFits(parts) {
                        Text("These parts do not all fit on one plate; the slicer will ask to arrange them.")
                            .font(.footnote).foregroundStyle(Color("ss-coral"))
                    }
                } header: { Text("Plate") } footer: {
                    Text(session.printLayout.placement == .arranged ? "Parts are laid side by side, each resting on the plate, so a lid and its box print together." :
                            "Parts keep their places in the model, lifted onto the middle of the plate.")
                }
                if mode == .send {
                    Section {
                        Button {
                            session.sendToPrinter(parts, toFolder: true)
                        } label: {
                            Label { Text(session.printFolderName.map { "Save to “\($0)”" } ?? "Save to a Print Folder") }
                                icon: { Image(SSIcon.save.assetName).renderingMode(.template) }
                        }
                        .disabled(session.printFolderName == nil).accessibilityIdentifier("print.saveToFolder")
                        Button(session.printFolderName == nil ? "Choose Print Folder…" : "Change Print Folder…") { choosingFolder = true }
                            .accessibilityIdentifier("print.chooseFolder")
                    } header: { Text("Send to") } footer: {
                        Text("Pick a folder in iCloud Drive once; each send replaces the file there, so the slicer on your Mac always opens the newest version.")
                    }
                }
                Section {
                    Button { session.sendToPrinter(parts, toFolder: false) } label: {
                        Label { Text(mode == .send ? "Share or Open in Another App…" : "Export 3MF…") }
                            icon: { Image(SSIcon.export.assetName).renderingMode(.template) }
                    }
                    .accessibilityIdentifier("print.share")
                } footer: {
                    if mode == .send { Text("AirDrop to a Mac, or open in a slicer or printer app on this iPad.") }
                }
            }
            .navigationTitle(mode == .send ? "Send to Slicer" : "Export 3MF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.printSheet = nil } } }
            .sheet(isPresented: $choosingFolder) {
                FolderPicker { url in session.rememberPrintFolder(url) }.ignoresSafeArea()
            }
        }
        .tint(Color("ss-violet"))
    }
}

/// The system folder picker.
private struct FolderPicker: UIViewControllerRepresentable {
    var picked: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: (URL) -> Void
        init(picked: @escaping (URL) -> Void) { self.picked = picked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { urls.first.map(picked) }
    }
}
