import SwiftUI
import UniformTypeIdentifiers

// Export: a print-ready 3MF (parts named as in the Model Tree, placed on the printer's plate, with
// a preview picture) or an STL. The file is shared, or saved straight into a chosen print folder,
// such as one in iCloud Drive that a slicer on a Mac opens, replacing the last version, so each
// change is one tap away from the printer (Send to Slicer).

/// The Export sheet (from the project menu or a selection's Export).
enum PrintSheetMode: String, Identifiable {
    case export
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

    /// Writes the 3MF (print-ready) or STL off the main thread, then shares it or saves it into the print folder.
    func sendToPrinter(_ choice: PrintParts, toFolder: Bool, format: ModelExport.Format = .threeMF) {
        let parts = printParts(choice)
        guard !parts.isEmpty, !isProjectBusy else { return }
        let folder = toFolder ? PrintFolder.url : nil
        if toFolder && folder == nil { return }
        cancelTransient()
        printSheet = nil
        isProjectBusy = true
        status = toFolder ? "Sending to the print folder…" : "Exporting \(format.title)…"
        let layout = printLayout, name = projectName, thumbnail = thumbnailProvider?()
        if let previous = exportItem?.url.deletingLastPathComponent() { try? FileManager.default.removeItem(at: previous) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { () throws -> URL in
                let data = format == .threeMF ? try ModelExport.threeMF(parts, title: name, layout: layout, thumbnail: thumbnail)
                    : try ModelExport.data(format, bodies: parts.map(\.body), title: name)
                let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                if let folder {
                    // Replaces the last version, so the slicer's recent file is always the newest.
                    let access = folder.startAccessingSecurityScopedResource()
                    defer { if access { folder.stopAccessingSecurityScopedResource() } }
                    let target = folder.appendingPathComponent(safeName).appendingPathExtension(format.rawValue)
                    var coordinationError: NSError?, writeError: Error?
                    NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
                        do { try data.write(to: url, options: .atomic) } catch { writeError = error }
                    }
                    if let error = coordinationError ?? writeError { throw error }
                    return target
                }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                let url = temporary.appendingPathComponent(safeName).appendingPathExtension(format.rawValue)
                try data.write(to: url, options: .atomic)
                return url
            }
            await self?.finishPrintExport(result, toFolder: folder != nil, format: format)
        }
    }

    private func finishPrintExport(_ result: Result<URL, any Error>, toFolder: Bool, format: ModelExport.Format) {
        isProjectBusy = false
        switch result {
        case .success(let url):
            if toFolder {
                status = "Sent \(url.lastPathComponent) to \(url.deletingLastPathComponent().lastPathComponent)"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                exportItem = ExportItem(url: url)
                status = "Exported \(format.title)"
            }
        case .failure(let error):
            status = "Not exported"
            saveError = (toFolder ? "Could not save to the print folder. " : "Export failed. ") + error.localizedDescription
        }
    }
}

/// Export: the format (3MF or STL), which parts, how a 3MF sits on the plate, and where the file
/// goes (the print folder a slicer opens, or the share sheet).
struct PrintSheet: View {
    @Bindable var session: ModelingSession
    let mode: PrintSheetMode
    @State private var parts = PrintParts.visible
    @State private var choosingFolder = false
    @AppStorage("export.format") private var formatName = ModelExport.Format.threeMF.rawValue
    private var format: ModelExport.Format { ModelExport.Format(rawValue: formatName) ?? .threeMF }

    var body: some View {
        let count = session.printParts(.visible).count
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $formatName) {
                        ForEach(ModelExport.Format.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("export.format")
                } header: { Text("Format") } footer: {
                    Text(format == .threeMF ? "Print-ready: each part named as in the Model Tree, placed on your plate, with a picture of the view as its preview. Most slicers open it directly." :
                            "One watertight mesh in millimeters, as modeled, for any slicer or mesh tool. Parts are not named or placed on a plate.")
                }
                Section {
                    Picker("Parts", selection: $parts) {
                        Text(count == 1 ? "The visible solid" : "All \(count) visible solids").tag(PrintParts.visible)
                        if session.selectedGroup.map({ !session.workspace.contents(of: $0).bodies.isEmpty }) == true {
                            Text("The selected group").tag(PrintParts.selected)
                        } else if !session.printParts(.selected).isEmpty {
                            Text(session.printParts(.selected).count == 1 ? "The selected solid" : "The selected solids").tag(PrintParts.selected)
                        }
                    }
                    .accessibilityIdentifier("print.parts")
                    // Export from a selected group starts with just its solids.
                    .onAppear { if session.selectedGroup != nil, !session.printParts(.selected).isEmpty { parts = .selected } }
                } header: { Text("Parts") } footer: {
                    if format == .threeMF { Text("Each part is named as in the Model Tree, so the slicer's object list matches.") }
                }
                if format == .threeMF {
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
                }
                Section {
                    Button {
                        session.sendToPrinter(parts, toFolder: true, format: format)
                    } label: {
                        Label { Text(session.printFolderName.map { "Save to “\($0)”" } ?? "Save to a Print Folder") }
                            icon: { Image(SSIcon.send.assetName).renderingMode(.template) }
                    }
                    .disabled(session.printFolderName == nil).accessibilityIdentifier("print.saveToFolder")
                    Button(session.printFolderName == nil ? "Choose Print Folder…" : "Change Print Folder…") { choosingFolder = true }
                        .accessibilityIdentifier("print.chooseFolder")
                } header: { Text("Send to Slicer") } footer: {
                    Text("Pick a folder in iCloud Drive once; each send replaces the file there, so the slicer on your Mac always opens the newest version.")
                }
                Section {
                    Button { session.sendToPrinter(parts, toFolder: false, format: format) } label: {
                        Label { Text("Share or Open in Another App…") }
                            icon: { Image(SSIcon.export.assetName).renderingMode(.template) }
                    }
                    .accessibilityIdentifier("print.share")
                } footer: { Text("AirDrop to a Mac, save to Files, or open in a slicer or printer app on this iPad.") }
            }
            .navigationTitle("Export")
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
