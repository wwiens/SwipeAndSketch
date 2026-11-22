import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import UIKit

// Shortcuts and Siri (Phase 1, November 15, 2026): open a project, export it (3MF, STL, or its
// parts list as CSV), save it to the folder picked in Export, and read its parts list and print
// estimate. These only read projects; nothing here ever changes one, so they stay available after
// the trial like the rest of export. Projects are Home's projects, or any project file a shortcut
// hands over. The project open in the editor is read from the editor, unsaved changes included.

// MARK: The app's side

/// What the intents need from the running app: the project open in the editor, and opening one.
@MainActor enum ShortcutsBridge {
    static weak var home: HomeController?
    /// Tests stand in for the editor here.
    static var openSession: ((URL) -> ModelingSession?)?
    static func session(showing url: URL) -> ModelingSession? { openSession?(url) ?? home?.session(showing: url) }
    static func open(_ url: URL) { home?.openExternal(url) }
}

/// A project as the intents read it: its name, its model, and a picture for a 3MF.
private struct ReadProject: Sendable {
    var name: String
    var workspace: Workspace
    var picture: Data?
    var layout: PrintLayout

    func parts(_ choice: PartsOption) -> [ModelExport.PrintPart] {
        workspace.printParts(includingHidden: choice == .all)
    }
}

private enum ShortcutsError: LocalizedError {
    case noProject, noSolids(String), noPrintFolder
    var errorDescription: String? {
        switch self {
        case .noProject: "Choose a project or a Swipe & Sketch project file."
        case .noSolids(let name): "“\(name)” has no solids to use. Hidden solids count only with Parts set to All."
        case .noPrintFolder: "There is no folder to save to yet. In Swipe & Sketch, open Export and tap Save to Folder once."
        }
    }
}

/// The project a shortcut means: the editor's open one (as on screen), else its file read afresh.
@MainActor private func readProject(_ project: ProjectEntity?, file: IntentFile?) async throws -> ReadProject {
    let layout = PrintLayout.stored
    if let project {
        if let session = ShortcutsBridge.session(showing: project.url) {
            return ReadProject(name: session.projectName, workspace: session.workspace, picture: session.thumbnailProvider?(), layout: layout)
        }
        let url = project.url
        let read = try await Task.detached(priority: .userInitiated) { try ProjectReader.read(url) }.value
        return ReadProject(name: ProjectReader.name(of: url), workspace: read.workspace, picture: read.preview, layout: layout)
    }
    guard let file else { throw ShortcutsError.noProject }
    let name = (file.filename as NSString).deletingPathExtension
    if let url = file.fileURL {
        if let session = ShortcutsBridge.session(showing: url) {
            return ReadProject(name: session.projectName, workspace: session.workspace, picture: session.thumbnailProvider?(), layout: layout)
        }
        let read = try await Task.detached(priority: .userInitiated) { try ProjectReader.read(url) }.value
        return ReadProject(name: name.isEmpty ? ProjectReader.name(of: url) : name, workspace: read.workspace, picture: read.preview, layout: layout)
    }
    let data = file.data
    let read = try await Task.detached(priority: .userInitiated) { try ProjectCodec.decode(data) }.value
    return ReadProject(name: name.isEmpty ? "Untitled Project" : name, workspace: read.workspace, picture: read.preview, layout: layout)
}

/// The parts list off the main thread (building solids can take a while).
private func partsList(_ project: ReadProject, _ choice: PartsOption) async throws -> [PartsList.Entry] {
    let parts = project.parts(choice)
    guard !parts.isEmpty else { throw ShortcutsError.noSolids(project.name) }
    let settings = FilamentSettings.stored
    return await Task.detached(priority: .userInitiated) {
        PartsList.entries(parts.map { ($0.body, $0.name) }, settings: settings)
    }.value
}

/// An export's bytes and file name, built off the main thread.
private func exportData(_ project: ReadProject, _ format: ExportFormatOption, _ choice: PartsOption) async throws -> (data: Data, name: String) {
    let parts = project.parts(choice)
    guard !parts.isEmpty else { throw ShortcutsError.noSolids(project.name) }
    switch format {
    case .partsList:
        let entries = try await partsList(project, choice)
        return (Data(PartsList.csv(entries, currency: estimateCurrency).utf8), (project.name.isEmpty ? "Untitled Project" : project.name) + " Parts List.csv")
    case .threeMF, .stl:
        let kind: ModelExport.Format = format == .threeMF ? .threeMF : .stl
        let data = try await Task.detached(priority: .userInitiated) {
            try ModelExport.file(parts, format: kind, title: project.name, layout: project.layout, thumbnail: project.picture)
        }.value
        return (data, ModelExport.fileName(project.name, format: kind))
    }
}

// MARK: Choices

enum PartsOption: String, AppEnum {
    case visible, all
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Parts"
    static let caseDisplayRepresentations: [PartsOption: DisplayRepresentation] = [
        .visible: "Visible Solids",
        .all: "All Solids"
    ]
}

enum ExportFormatOption: String, AppEnum {
    case threeMF, stl, partsList
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [ExportFormatOption: DisplayRepresentation] = [
        .threeMF: DisplayRepresentation(title: "3MF", subtitle: "Print-ready: named parts on your plate"),
        .stl: DisplayRepresentation(title: "STL", subtitle: "One mesh, as modeled"),
        .partsList: DisplayRepresentation(title: "Parts List (CSV)", subtitle: "Sizes, filament, and cost for a spreadsheet")
    ]
}

enum PrintFormatOption: String, AppEnum {
    case threeMF, stl
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [PrintFormatOption: DisplayRepresentation] = [
        .threeMF: "3MF",
        .stl: "STL"
    ]
}

// MARK: Projects

/// One of Home's projects: those opened here before and those in On My iPad › Swipe & Sketch.
struct ProjectEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Swipe & Sketch Project", numericFormat: "\(placeholder: .int) projects")
    static let defaultQuery = ProjectQuery()

    /// The file's standardized path, as Home keys it.
    var id: String
    var url: URL
    @Property(title: "Name") var name: String
    @Property(title: "Location") var location: String
    @Property(title: "Modified") var modified: Date
    @Property(title: "Solids") var solids: Int?
    var picture: Data?

    init(_ project: RecentProject, picture: Data?) {
        id = project.id
        url = project.url
        self.picture = picture
        name = project.name
        location = project.place.title
        modified = project.date
        solids = project.solids
    }

    var displayRepresentation: DisplayRepresentation {
        let detail = solids.map { "\($0) \($0 == 1 ? "solid" : "solids") · \(location)" } ?? location
        return DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: picture.map { .init(data: $0) })
    }

    /// Tells Spotlight about Home's projects (and forgets the rest), so searching a name finds them.
    @MainActor static func index(_ projects: [RecentProject]) {
        guard !ModelingSession.isRunningUITests else { return }
        let entities = projects.map { ProjectEntity($0, picture: nil) }
        Task.detached(priority: .utility) {
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: ProjectEntity.self)
            try? await index.indexAppEntities(entities)
        }
        // Siri's phrases that name a project ("Save Bracket to my folder…") learn the new names.
        SwipeAndSketchShortcuts.updateAppShortcutParameters()
    }
}

struct ProjectQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor private func projects() async -> [ProjectEntity] {
        let recents = RecentProjects.shared
        return await recents.current().map { ProjectEntity($0, picture: recents.picturePNG(for: $0.id)) }
    }
    func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        let all = await projects()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }
    func entities(matching string: String) async throws -> [ProjectEntity] {
        await projects().filter { $0.name.localizedStandardContains(string) }
    }
    /// The three most recent: Siri's phrases that name a project are offered for these, so Shortcuts
    /// shows a few ready-made tiles rather than one per project. Every project stays pickable.
    func suggestedEntities() async throws -> [ProjectEntity] { Array(await projects().prefix(3)) }
    func allEntities() async throws -> [ProjectEntity] { await projects() }
}

// MARK: Results

/// One row of the parts list.
struct PartItem: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Part"
    @Property(title: "Name") var name: String
    @Property(title: "X (mm)") var x: Double
    @Property(title: "Y (mm)") var y: Double
    @Property(title: "Z (mm)") var z: Double
    @Property(title: "Volume (mm³)") var volume: Double
    @Property(title: "Filament (g)") var grams: Double
    @Property(title: "Filament (m)") var meters: Double
    @Property(title: "Cost") var cost: Double

    init() {
        name = ""; x = 0; y = 0; z = 0; volume = 0; grams = 0; meters = 0; cost = 0
    }
    init(_ entry: PartsList.Entry) {
        self.init()
        name = entry.name
        x = (entry.size.x * 100).rounded() / 100
        y = (entry.size.y * 100).rounded() / 100
        z = (entry.size.z * 100).rounded() / 100
        volume = (entry.estimate.volume * 10).rounded() / 10
        grams = (entry.estimate.grams * 10).rounded() / 10
        meters = (entry.estimate.meters * 100).rounded() / 100
        cost = (entry.estimate.cost * 100).rounded() / 100
    }
    var displayRepresentation: DisplayRepresentation {
        let size = [x, y, z].map { FilamentSettings.number($0, digits: 2) }.joined(separator: " × ")
        return DisplayRepresentation(title: "\(name)", subtitle: "\(size) mm · \(FilamentSettings.number(grams, digits: 1)) g")
    }
}

/// The print estimate for a project's parts.
struct PrintEstimateItem: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Print Estimate"
    @Property(title: "Filament (g)") var grams: Double
    @Property(title: "Filament (m)") var meters: Double
    @Property(title: "Cost") var cost: Double
    @Property(title: "Parts") var parts: Int
    @Property(title: "Summary") var summary: String

    init() {
        grams = 0; meters = 0; cost = 0; parts = 0; summary = ""
    }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }
}

// MARK: Actions

struct OpenProjectIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Project"
    static let description = IntentDescription("Opens a Swipe & Sketch project in the editor.")
    @Parameter(title: "Project") var target: ProjectEntity

    init() {}
    init(target: ProjectEntity) { self.target = target }

    @MainActor func perform() async throws -> some IntentResult {
        ShortcutsBridge.open(target.url)
        return .result()
    }
}

struct ExportProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Project"
    static let description = IntentDescription("Exports a project as a print-ready 3MF, an STL, or its parts list as CSV. The project itself is not changed.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Project") var project: ProjectEntity?
    @Parameter(title: "Project File", supportedContentTypes: [UTType(exportedAs: "noventix.SwipeAndSketch.project")]) var file: IntentFile?
    @Parameter(title: "Format", default: .threeMF) var format: ExportFormatOption
    @Parameter(title: "Parts", default: .visible) var parts: PartsOption

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$project) as \(\.$format)") {
            \.$parts
            \.$file
        }
    }

    init() {}
    init(project: ProjectEntity, format: ExportFormatOption, parts: PartsOption = .visible) {
        self.project = project
        self.format = format
        self.parts = parts
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        // Neither given (a tile, or Siri without a name): ask which project, from Home's list.
        if project == nil && file == nil { throw $project.needsValueError("Which project?") }
        let read = try await readProject(project, file: file)
        let export = try await exportData(read, format, parts)
        let url = try ExportFiles.temporary(export.data, named: export.name)
        return .result(value: IntentFile(fileURL: url, filename: export.name, type: UTType(filenameExtension: url.pathExtension)))
    }
}

struct SendToSlicerIntent: AppIntent {
    static let title: LocalizedStringResource = "Save to Folder"
    static let description = IntentDescription("Saves a project's 3MF or STL into the folder you picked in Export's Save to Folder, replacing the last copy, so your slicer opens the newest.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Project") var project: ProjectEntity?
    @Parameter(title: "Project File", supportedContentTypes: [UTType(exportedAs: "noventix.SwipeAndSketch.project")]) var file: IntentFile?
    @Parameter(title: "Format", default: .threeMF) var format: PrintFormatOption
    @Parameter(title: "Parts", default: .visible) var parts: PartsOption

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$project) to the folder as \(\.$format)") {
            \.$parts
            \.$file
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        guard let folder = PrintFolder.url else { throw ShortcutsError.noPrintFolder }
        // Neither given (a tile, or Siri without a name): ask which project, from Home's list.
        if project == nil && file == nil { throw $project.needsValueError("Which project?") }
        let read = try await readProject(project, file: file)
        let export = try await exportData(read, format == .threeMF ? .threeMF : .stl, parts)
        let saved = try await Task.detached(priority: .userInitiated) { try PrintFolder.save(export.data, named: export.name, in: folder) }.value
        return .result(value: IntentFile(fileURL: saved, filename: export.name, type: UTType(filenameExtension: saved.pathExtension)),
                       dialog: "Saved \(export.name) to \(folder.lastPathComponent).")
    }
}

struct GetPartsListIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Parts List"
    static let description = IntentDescription("Lists a project's parts with their size along X, Y, and Z, volume, filament, and cost, using the filament settings in Swipe & Sketch.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Project") var project: ProjectEntity?
    @Parameter(title: "Project File", supportedContentTypes: [UTType(exportedAs: "noventix.SwipeAndSketch.project")]) var file: IntentFile?
    @Parameter(title: "Parts", default: .visible) var parts: PartsOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get the parts list of \(\.$project)") {
            \.$parts
            \.$file
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PartItem]> {
        // Neither given (a tile, or Siri without a name): ask which project, from Home's list.
        if project == nil && file == nil { throw $project.needsValueError("Which project?") }
        let read = try await readProject(project, file: file)
        return .result(value: try await partsList(read, parts).map(PartItem.init))
    }
}

struct GetPrintEstimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Print Estimate"
    static let description = IntentDescription("About how much filament a project's parts take and what it costs, using the filament settings in Swipe & Sketch. Your slicer's figure is exact.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Project") var project: ProjectEntity?
    @Parameter(title: "Project File", supportedContentTypes: [UTType(exportedAs: "noventix.SwipeAndSketch.project")]) var file: IntentFile?
    @Parameter(title: "Parts", default: .visible) var parts: PartsOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get the print estimate for \(\.$project)") {
            \.$parts
            \.$file
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<PrintEstimateItem> & ProvidesDialog {
        // Neither given (a tile, or Siri without a name): ask which project, from Home's list.
        if project == nil && file == nil { throw $project.needsValueError("Which project?") }
        let read = try await readProject(project, file: file)
        let entries = try await partsList(read, parts)
        let total = PartsList.total(entries), settings = FilamentSettings.stored
        let material = settings.material == .custom ? "filament" : settings.material.title
        let summary = "About \(total.weightText) of \(material) (\(total.lengthText)), \(total.costText(currency: estimateCurrency))"
        let item = PrintEstimateItem()
        item.grams = (total.grams * 10).rounded() / 10
        item.meters = (total.meters * 100).rounded() / 100
        item.cost = (total.cost * 100).rounded() / 100
        item.parts = entries.count
        item.summary = summary
        return .result(value: item, dialog: "\(summary) for \(entries.count == 1 ? "1 part" : "\(entries.count) parts") of \(read.name).")
    }
}

// MARK: Siri and Spotlight

struct SwipeAndSketchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExportProjectIntent(), phrases: [
            "Export a project with \(.applicationName)",
            "Export with \(.applicationName)"
        ], shortTitle: "Export Project", systemImageName: "square.and.arrow.up")
        AppShortcut(intent: SendToSlicerIntent(), phrases: [
            "Save \(\.$project) to my folder with \(.applicationName)",
            "Save a project to my folder with \(.applicationName)"
        ], shortTitle: "Save to Folder", systemImageName: "printer")
        AppShortcut(intent: GetPartsListIntent(), phrases: [
            "Get a parts list in \(.applicationName)",
            "Show the parts list in \(.applicationName)"
        ], shortTitle: "Parts List", systemImageName: "list.bullet.rectangle")
        AppShortcut(intent: GetPrintEstimateIntent(), phrases: [
            "How much filament does it take in \(.applicationName)",
            "Get a print estimate in \(.applicationName)"
        ], shortTitle: "Print Estimate", systemImageName: "scalemass")
        AppShortcut(intent: OpenProjectIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Open a project in \(.applicationName)"
        ], shortTitle: "Open Project", systemImageName: "cube")
    }
    static let shortcutTileColor: ShortcutTileColor = .purple
}

extension ModelingSession {
    /// Tells the system the user exported this project, so Siri can suggest the shortcut.
    func donateExport(_ format: ModelExport.Format, toFolder: Bool) {
        guard !ModelingSession.isRunningUITests, let url = projectFileURL else { return }
        Task { @MainActor in
            guard let project = await RecentProjects.shared.current().first(where: { $0.id == RecentProjects.key(url) }) else { return }
            let entity = ProjectEntity(project, picture: nil)
            if toFolder {
                let intent = SendToSlicerIntent()
                intent.project = entity
                intent.format = format == .threeMF ? .threeMF : .stl
                _ = try? await intent.donate()
            } else {
                _ = try? await ExportProjectIntent(project: entity, format: format == .threeMF ? .threeMF : .stl).donate()
            }
        }
    }
}
