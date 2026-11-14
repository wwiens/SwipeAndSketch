import SwiftUI
import UniformTypeIdentifiers
import os

extension UTType {
    static let swipeAndSketchProject = UTType(exportedAs: Project.formatIdentifier, conformingTo: .json)
}

final class ProjectDocument: UIDocument {
    private struct Snapshot: Sendable {
        var project = Project()
        var hasLoaded = false
        /// The file changed on disk and could not be read (a newer schema, damage): editing and
        /// saving over it stop until it reads again, so it is never silently replaced.
        var reloadFailed = false
        var onReloadFailure: (@MainActor @Sendable () -> Void)?
        var onReload: (@MainActor @Sendable (Project) -> Void)?
        var onError: (@MainActor @Sendable (Error) -> Void)?
    }
    // UIDocument may read/write contents off the main actor. Only immutable
    // value snapshots cross that boundary; session/UI callbacks stay on main.
    nonisolated private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot())
    var project: Project { snapshot.withLock { $0.project } }
    @MainActor var onReload: (@MainActor @Sendable (Project) -> Void)? {
        get { snapshot.withLock { $0.onReload } }
        set { snapshot.withLock { $0.onReload = newValue } }
    }
    @MainActor var onStateChange: (() -> Void)?
    /// The file changed and could not be read; the document is now read-only.
    @MainActor var onReloadFailure: (@MainActor @Sendable () -> Void)? {
        get { snapshot.withLock { $0.onReloadFailure } }
        set { snapshot.withLock { $0.onReloadFailure = newValue } }
    }
    @MainActor var onError: (@MainActor @Sendable (Error) -> Void)? {
        get { snapshot.withLock { $0.onError } }
        set { snapshot.withLock { $0.onError = newValue } }
    }
    var reloadFailed: Bool { snapshot.withLock { $0.reloadFailed } }
    var isReadOnly: Bool { documentState.contains(.inConflict) || documentState.contains(.editingDisabled) || reloadFailed }

    override init(fileURL: URL) {
        super.init(fileURL: fileURL)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: UIDocument.stateChangedNotification, object: self)
    }
    @MainActor @objc private func stateChanged() { onStateChange?() }

    nonisolated override func load(fromContents contents: Any, ofType typeName: String?) throws {
        let loaded: Project
        do {
            guard let data = contents as? Data else { throw ProjectError.invalidModel }
            loaded = try ProjectCodec.decode(data)
        } catch {
            // A failed reload keeps the open model but must not save it over the file it could not read.
            let callback = snapshot.withLock { state in
                guard state.hasLoaded else { return nil as (@MainActor @Sendable () -> Void)? }
                state.reloadFailed = true
                return state.onReloadFailure
            }
            if let callback { Task { @MainActor in callback() } }
            throw error
        }
        let callback = snapshot.withLock { state in
            let wasLoaded = state.hasLoaded
            state.project = loaded
            state.hasLoaded = true
            state.reloadFailed = false
            return wasLoaded ? state.onReload : nil
        }
        if let callback { Task { @MainActor in callback(loaded) } }
    }
    /// UIDocument asks for the contents on the main thread, so this hands over the project value
    /// and `writeContents` encodes it on the save queue: a project with large imported shapes took
    /// a noticeable pause to encode after every change (October 31, 2026).
    nonisolated override func contents(forType typeName: String) throws -> Any {
        snapshot.withLock { $0.project }
    }
    nonisolated override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation, originalContentsURL: URL?) throws {
        // The model was validated when it was read or edited (`updateWorkspace`), so only what the
        // save adds (the version, the size) is checked again here, not every solid.
        let data = try (contents as? Project).map { try ProjectCodec.encode($0, knownValid: $0.workspace) } ?? contents
        try super.writeContents(data, to: url, for: saveOperation, originalContentsURL: originalContentsURL)
    }

    @MainActor func updateWorkspace(_ workspace: Workspace) throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let changed = try snapshot.withLock { state in
            guard workspace != state.project.workspace else { return false }
            var updated = state.project
            updated.update(workspace)
            // The stored model was validated when loaded or last edited. Notes cannot change
            // it; validate only that metadata here. Full encoding validation stays on UIDocument's
            // save queue, rather than blocking the keyboard on the main actor.
            if workspace.hasSameModel(as: state.project.workspace) {
                guard workspace.notesAreValid else { throw ProjectError.invalidModel }
            } else {
                try ProjectCodec.validate(updated, changedFrom: state.project.workspace)
            }
            state.project = updated
            return true
        }
        guard changed else { return }
        updateChangeCount(.done)
    }

    /// The picture the document browser shows for this project (October 21, 2026), saved in the
    /// file for the thumbnail extension. A new picture marks the document changed, so the next save
    /// writes it even when the model has not changed.
    @MainActor func setPreview(_ image: UIImage?) {
        guard !isReadOnly, let png = image?.pngData(), png.count <= ProjectPreview.maximumBytes else { return }
        let changed = snapshot.withLock { state in
            guard state.project.preview != png else { return false }
            state.project.preview = png
            return true
        }
        if changed { updateChangeCount(.done) }
    }

    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        // Never overwrite unresolved cloud versions. Save As can preserve the working copy.
        guard !((documentState.contains(.inConflict) || reloadFailed) && url == fileURL) else { completionHandler?(false); return }
        super.save(to: url, for: saveOperation, completionHandler: completionHandler)
    }

    nonisolated override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        if let callback = snapshot.withLock({ $0.onError }) { Task { @MainActor in callback(error) } }
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
    }
}

struct HomeScreen: UIViewControllerRepresentable {
    let controller: HomeController
    func makeUIViewController(context: Context) -> HomeController { controller }
    func updateUIViewController(_ controller: HomeController, context: Context) { }
}

/// The system document browser shown in Home's Files (October 22, 2026); HomeController is its delegate.
final class FilesBrowserController: UIDocumentBrowserViewController {
    init() {
        super.init(forOpening: [.swipeAndSketchProject])
        allowsDocumentCreation = true
        allowsPickingMultipleItems = false
        shouldShowFileExtensions = true
        localizedCreateDocumentActionTitle = "New Project"
        browserUserInterfaceStyle = .light
        overrideUserInterfaceStyle = .light
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The app's root (October 22, 2026): Home (HomeView.swift) with the Files browser inside it, and
/// the owner of the open project: it opens, creates, saves as, and closes projects, presenting the
/// editor over Home.
@MainActor final class HomeController: UIViewController, @preconcurrency UIDocumentBrowserViewControllerDelegate, UIDocumentPickerDelegate {
    private let access: AppAccessStore
    private let browser = FilesBrowserController()
    private let home = HomeModel()
    private var activeDocument: ProjectDocument?
    private var activeSession: ModelingSession?
    private var activeEditor: UIViewController?
    private var scopedURL: URL?
    private var initialPresentationDone = false
    private var pendingURL: URL?
    private var stagingDirectory: URL?
    private var pickerCompletion: ((URL) -> Void)?
    private let fileTests: Bool

    /// Short of memory: the solids, imported shapes' solids, and regions that can be made again go,
    /// except the most recently used solids (the canvas keeps what it draws). Nothing listened
    /// before, so a large project could be stopped by the system instead (November 8, 2026).
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        SolidCache.releaseMemory(keepingSolids: 32)
    }

    init(access: AppAccessStore = .shared) {
        self.access = access
        #if DEBUG
        fileTests = ProcessInfo.processInfo.arguments.contains("--ui-testing-documents")
        #else
        fileTests = false
        #endif
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .light
        browser.delegate = self
        home.newBlankProject = { [weak self] in self?.create(Project(), name: "Untitled Project") }
        home.create = { [weak self] in self?.create($0, name: $1) }
        home.open = { [weak self] project in self?.openFile(project.url) }
        home.showInFiles = { [weak self] project in self?.showInFiles(project) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let hosting = UIHostingController(rootView: HomeView(model: home, browser: browser, access: access))
        hosting.overrideUserInterfaceStyle = .light
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !initialPresentationDone else { return }
        initialPresentationDone = true
        do {
            if fileTests {
                let directory = URL.documentsDirectory.appendingPathComponent("SwipeAndSketchFileTests", isDirectory: true)
                // Empty the folder but keep it, so Files keeps the same folder between runs.
                if ProcessInfo.processInfo.arguments.contains("--reset-document-tests"), FileManager.default.fileExists(atPath: directory.path) {
                    for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                        try FileManager.default.removeItem(at: item)
                    }
                }
                let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "swipesketch" }
                let url = existing ?? directory.appendingPathComponent("Document Test \(UUID().uuidString.prefix(8)).swipesketch")
                if !FileManager.default.fileExists(atPath: url.path) {
                    let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
                    let circle = SketchShape(kind: .circle, plane: .front, start: .init(x: 80, y: 0), end: .init(x: 92.5, y: 0))
                    let profile = Geometry.profiles(in: [shape], on: .top)[0]
                    try ProjectCodec.create(Project(workspace: Workspace(shapes: [shape, circle], bodies: [SolidBody(profile: profile, depth: -12.5)])), at: url)
                }
                pendingURL = url
            }
            if let url = pendingURL { pendingURL = nil; openFile(url) }
        } catch { showError("Could not open project", error.localizedDescription) }
    }

    func openExternal(_ url: URL) {
        guard initialPresentationDone else { pendingURL = url; return }
        closeCurrent { [weak self] success in if success { self?.openFile(url) } }
    }

    /// Opens a project file. One the system left in Documents/Inbox (another app's "Copy to") moves
    /// into Documents first, under a name of its own, so it is not edited where the system clears it.
    private func openFile(_ url: URL) {
        guard Self.isInInbox(url) else { openProject(url); return }
        do {
            let destination = Self.unusedURL(for: url.lastPathComponent, in: .documentsDirectory)
            try FileManager.default.moveItem(at: url, to: destination)
            openProject(destination)
        } catch { showError("Could not open project", error.localizedDescription) }
    }

    nonisolated static func isInInbox(_ url: URL, documents: URL = .documentsDirectory) -> Bool {
        let base = documents.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return path.count > base.count + 1 && Array(path.prefix(base.count)) == base && path[base.count] == "Inbox"
    }

    /// `name` in `folder`, numbered ("Bracket 2") when that name is taken.
    nonisolated static func unusedURL(for name: String, in folder: URL) -> URL {
        let file = name as NSString
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(file.deletingPathExtension) \(number)").appendingPathExtension(file.pathExtension)
            number += 1
        }
        return url
    }

    private func showInFiles(_ project: RecentProject) {
        home.section = .files
        let scoped = project.url.startAccessingSecurityScopedResource()
        // The browser loads when Files first shows; reveal once it is on screen.
        DispatchQueue.main.async { [weak self] in
            self?.browser.revealDocument(at: project.url, importIfNeeded: false) { _, _ in
                if scoped { project.url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let url = documentURLs.first { openFile(url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        // The browser's + and the project menu show the template gallery, then the native name/location sheet.
        // Complete the browser's own creation request before presenting them.
        importHandler(nil, .none)
        DispatchQueue.main.async { [weak self] in self?.presentTemplateGallery() }
    }

    private func openProject(_ url: URL) {
        guard activeDocument == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ProjectCodec.maximumFileBytes {
            if scoped { url.stopAccessingSecurityScopedResource() }
            showError("Could not open project", ProjectError.tooLarge.localizedDescription)
            return
        }
        let document = ProjectDocument(fileURL: url)
        activeDocument = document
        readCancelled = false
        // A large file takes a moment to read before its solids build: the Opening card shows from
        // half a second into the read, not only once building starts (November 8, 2026).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.activeDocument === document, self.activeSession == nil, self.solidsTask == nil,
                  self.openingCard == nil, self.presentedViewController == nil, !self.readCancelled else { return }
            self.presentOpeningCard(name: document.localizedName, message: "Reading the file")
        }
        document.open { [weak self] success in
          Task { @MainActor in
            guard let self else { if scoped { url.stopAccessingSecurityScopedResource() }; return }
            if self.readCancelled {
                // Cancel while reading: the project closes unread.
                self.readCancelled = false
                let reading = self.activeDocument
                self.activeDocument = nil
                if scoped { url.stopAccessingSecurityScopedResource() }
                if success { reading?.close { _ in } }
                return
            }
            guard success else {
                self.openingCard?.dismiss(animated: false)
                self.openingCard = nil
                self.activeDocument = nil
                if scoped { url.stopAccessingSecurityScopedResource() }
                RecentProjects.shared.refresh()
                self.showError("Could not open project", "The file could not be read or uses an unsupported format. The original file has been preserved.")
                return
            }
            self.scopedURL = scoped ? url : nil
            guard let document = self.activeDocument else { return }
            self.buildSolids(of: document) { [weak self] in self?.presentEditor(for: document, url: url) }
          }
        }
    }

    /// Builds the solids the canvas draws first, off the main thread, before the editor opens:
    /// the canvas builds them as it draws, and a project whose solids carry long histories froze
    /// the app for about 12 seconds on opening (an 8-solid case, November 8, 2026). Past half a
    /// second a card shows the progress, with Cancel.
    private func buildSolids(of document: ProjectDocument, then present: @escaping @MainActor () -> Void) {
        let workspace = document.project.workspace
        let bodies = workspace.visible.bodies
        let hidden = workspace.bodies.filter { body in !bodies.contains { $0.id == body.id } }
        let name = document.localizedName
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // Solids kept on disk come back several at once; the rest build one at a time below.
            if !Task.isCancelled { SolidCache.shared.readFromDisk(bodies) }
            for (index, body) in bodies.enumerated() {
                guard !Task.isCancelled else { return }
                await self?.showOpeningProgress(name, built: index, of: bodies.count)
                SolidCache.shared.prepare(body)
            }
            // A cancelled opening must not present its project, even if another one is opening now.
            guard !Task.isCancelled else { return }
            await self?.finishBuildingSolids(then: present)
            // Hidden solids kept on disk are read too, so showing one later does not rebuild it.
            for body in hidden where !Task.isCancelled { SolidCache.shared.prepare(body, build: false) }
            // Then the visible solids' earlier steps, which editing a finish, a hole, or an earlier
            // step builds on; until the project closes.
            for body in bodies where !Task.isCancelled {
                SolidCache.shared.buildSteps(of: body) { !Task.isCancelled }
            }
        }
        solidsTask = task
        openingCard?.message = Self.openingMessage(built: 0, of: bodies.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.solidsTask == task, self.openingCard == nil, self.presentedViewController == nil else { return }
            self.presentOpeningCard(name: name, message: Self.openingMessage(built: self.solidsBuilt, of: bodies.count))
        }
    }

    /// Cancel reads the file no further, or stops building its solids.
    private func presentOpeningCard(name: String, message: String) {
        let card = UIAlertController(title: "Opening \(name)", message: message, preferredStyle: .alert)
        card.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            guard let self else { return }
            if self.solidsTask != nil { self.cancelOpening() } else { self.readCancelled = true; self.openingCard = nil }
        })
        openingCard = card
        present(card, animated: true)
    }
    private var readCancelled = false
    private var solidsTask: Task<Void, Never>?
    /// The same task once the editor is open, still building earlier steps; cancelled on closing.
    private var stepsTask: Task<Void, Never>?
    private var openingCard: UIAlertController?
    private var solidsBuilt = 0

    private static func openingMessage(built: Int, of count: Int) -> String { "Building solids: \(built) of \(count)" }

    private func showOpeningProgress(_ name: String, built: Int, of count: Int) {
        solidsBuilt = built
        openingCard?.message = Self.openingMessage(built: built, of: count)
    }

    private func finishBuildingSolids(then present: @MainActor () -> Void) {
        guard let task = solidsTask, !task.isCancelled else { return }
        solidsTask = nil
        stepsTask = task
        solidsBuilt = 0
        openingCard = nil
        present()
    }

    /// Cancel on the opening card (or another file opened meanwhile): the solid being built
    /// finishes in the background, and the project closes unchanged.
    private func cancelOpening(then completion: (@MainActor @Sendable () -> Void)? = nil) {
        solidsTask?.cancel()
        solidsTask = nil
        solidsBuilt = 0
        openingCard = nil
        let document = activeDocument
        activeDocument = nil
        let scoped = scopedURL
        scopedURL = nil
        document?.close { _ in
            Task { @MainActor in
                scoped?.stopAccessingSecurityScopedResource()
                RecentProjects.shared.refresh()
                completion?()
            }
        }
        if document == nil { scoped?.stopAccessingSecurityScopedResource(); completion?() }
    }

    private func presentEditor(for document: ProjectDocument, url: URL) {
        guard activeDocument === document else { return }
        RecentProjects.shared.isEditing = true
        let session = ModelingSession(document: document, access: self.access)
        if self.fileTests, ProcessInfo.processInfo.arguments.contains("--select-document-sketch"), let shape = session.workspace.shapes.first {
            session.selection = .shape(shape.id)
        }
        session.onOpenProjects = { [weak self] in self?.closeCurrent { _ in } }
        session.onNewProject = { [weak self] in self?.chooseNewProject() }
        session.onSaveAs = { [weak self] in self?.saveAs() }
        self.activeSession = session
        session.storeCarriedSolidsAsShapes()
        RecentProjects.shared.record(url, project: document.project)
        let editor = UIHostingController(rootView: WorkspaceView(session: session).preferredColorScheme(.light))
        editor.modalPresentationStyle = .fullScreen
        editor.isModalInPresentation = true
        // The light-only editor design; preferredColorScheme alone does not reach a presented controller in Dark Mode.
        editor.overrideUserInterfaceStyle = .light
        self.activeEditor = editor
        // A stale alert would make this presentation fail silently, leaving the project open but unseen.
        if let alert = self.presentedViewController as? UIAlertController {
            alert.dismiss(animated: false) { self.present(editor, animated: true) }
        } else {
            self.present(editor, animated: true)
        }
    }

    private func closeCurrent(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if solidsTask != nil {
            openingCard?.dismiss(animated: false)
            cancelOpening { completion(true) }
            return
        }
        guard let document = activeDocument, let session = activeSession else { completion(true); return }
        guard !session.viewCube.pencilActive, !session.isProjectBusy else { completion(false); return }
        guard !session.isAssistantBusy else { session.saveError = Self.assistantBusyMessage; completion(false); return }
        session.isProjectBusy = true
        session.save(withThumbnail: true) { [weak self] saved in
            guard let self else { completion(false); return }
            guard saved else { session.isProjectBusy = false; completion(false); return }
            self.stepsTask?.cancel()
            self.stepsTask = nil
            // Home's card takes the picture just saved.
            RecentProjects.shared.record(document.fileURL, project: document.project)
            Self.keepSolidsOnDisk(session)
            document.close { success in
              Task { @MainActor in
                guard success else { session.isProjectBusy = false; session.saveError = "The project could not be closed safely. Your work is still open."; completion(false); return }
                session.cancelTransient()
                self.activeEditor?.dismiss(animated: true) {
                    self.activeEditor = nil; self.activeSession = nil; self.activeDocument = nil
                    self.scopedURL?.stopAccessingSecurityScopedResource(); self.scopedURL = nil
                    // Its solids went to disk above; the next project starts with memory to spare.
                    SolidCache.releaseMemory()
                    RecentProjects.shared.isEditing = false
                    RecentProjects.shared.refresh()
                    completion(true)
                }
              }
            }
        }
    }

    /// Closing would drop the assistant's request or the changes under review without asking.
    private static let assistantBusyMessage = "Keep or discard the assistant's changes (or stop its request) before leaving this project."

    private func chooseNewProject() {
        guard let session = activeSession, !session.isProjectBusy, !session.viewCube.pencilActive else { return }
        guard !session.isAssistantBusy else { session.saveError = Self.assistantBusyMessage; return }
        session.save(withThumbnail: true) { [weak self] success in
            guard let self, success else { return }
            self.presentTemplateGallery()
        }
    }

    /// New Project's gallery (TemplateGallery.swift): a blank project or a template, then the save sheet.
    private func presentTemplateGallery() {
        let gallery = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
        gallery.rootView = AnyView(TemplateGallery(
            onCreate: { [weak self, weak gallery] project, name in
                gallery?.dismiss(animated: true) { self?.create(project, name: name) }
            },
            onCancel: { [weak gallery] in gallery?.dismiss(animated: true) }
        ).preferredColorScheme(.light))
        gallery.modalPresentationStyle = .fullScreen
        gallery.isModalInPresentation = true
        // The light-only design; preferredColorScheme alone does not reach a presented controller in Dark Mode.
        gallery.overrideUserInterfaceStyle = .light
        (activeEditor ?? self).present(gallery, animated: true)
    }

    /// Asks where to save a new project (named `name`), then opens it. Home goes back to its start.
    private func create(_ project: Project, name: String) {
        access.refreshClock()
        guard access.canEdit else {
            if let session = activeSession { session.showPurchaseOffer = true }
            else { home.showPurchaseOffer = true }
            return
        }
        do {
            try presentFilePicker(project: project, name: Self.fileName(name), title: "New Project")
        } catch { showError("Could not create project", error.localizedDescription) }
    }

    /// A suggested name made fit for a file: characters files cannot hold become dashes.
    nonisolated static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled Project" : String(cleaned.prefix(120))
    }

    private func saveAs() {
        guard let session = activeSession, !session.isProjectBusy, !session.viewCube.pencilActive else { return }
        guard !session.isAssistantBusy else { session.saveError = Self.assistantBusyMessage; return }
        session.endEditingNotes()
        do {
            var copy = Project(workspace: session.workspace)
            copy.preview = session.projectThumbnailProvider?()?.pngData()
            try presentFilePicker(project: copy, name: session.projectName + " Copy", title: "Save Project As")
        } catch { showError("Could not save a copy", error.localizedDescription) }
    }

    /// The copy is written (encoded and checked) off the main thread, which paused the app on a
    /// large project (November 8, 2026); the picker follows once it is ready.
    private func presentFilePicker(project: Project, name: String, title: String) throws {
        let name = try validName(name)
        clearStaging()
        activeSession?.isProjectBusy = true
        let failure = title == "New Project" ? "Could not create project" : "Could not save a copy"
        Task { [weak self] in
            let staged = await Task.detached(priority: .userInitiated) { () -> Result<(directory: URL, file: URL), Error> in
                Result { try Self.stage(project, name: name) }
            }.value
            guard let self else { return }
            switch staged {
            case .failure(let error):
                self.activeSession?.isProjectBusy = false
                self.showError(failure, error.localizedDescription)
            case .success(let staged):
                self.stagingDirectory = staged.directory
                self.showFilePicker(for: staged.file, title: title)
            }
        }
    }

    private func showFilePicker(for url: URL, title: String) {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self
        picker.overrideUserInterfaceStyle = .light
        picker.shouldShowFileExtensions = true
        picker.title = title
        picker.directoryURL = activeDocument?.fileURL.deletingLastPathComponent() ?? .documentsDirectory
        activeSession?.isProjectBusy = true
        pickerCompletion = { [weak self] destination in
            guard let self else { return }
            self.activeSession?.isProjectBusy = false
            // Home's Templates starts from its gallery again next time.
            self.home.galleryID = UUID()
            // A successfully written Save As copy safely preserves any conflicted edits.
            if self.activeDocument?.documentState.contains(.inConflict) == true || self.activeDocument?.reloadFailed == true {
                self.activeDocument?.updateChangeCount(.cleared)
            }
            self.closeCurrent { success in if success { self.openFile(destination) } }
        }
        (activeEditor ?? self).present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let completion = pickerCompletion; pickerCompletion = nil
        controller.dismiss(animated: true) { [weak self] in
            self?.clearStaging()
            if let url = urls.first { completion?(url) } else { self?.activeSession?.isProjectBusy = false }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCompletion = nil; clearStaging(); activeSession?.isProjectBusy = false
    }

    nonisolated private static func stage(_ project: Project, name: String) throws -> (directory: URL, file: URL) {
        let directory = URL.temporaryDirectory.appendingPathComponent("SwipeAndSketch-Staging/\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("swipesketch")
        try ProjectCodec.create(project, at: url)
        return (directory, url)
    }
    private func clearStaging() {
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
    }
    private func validName(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 180,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)) == nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return name
    }
    private func showError(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (activeEditor ?? self).present(alert, animated: true)
    }
    /// `withThumbnail` false (the app only inactive: Control Center, the app switcher, a system
    /// sheet) saves any change at once but draws no picture and writes no solids, which waits for
    /// the background; both ran on every one of those moments before (November 8, 2026).
    func autosaveActiveProject(withThumbnail: Bool = true) {
        guard let session = activeSession else { return }
        session.save(withThumbnail: withThumbnail, completion: { _ in })
        if withThumbnail { Self.keepSolidsOnDisk(session) }
    }

    /// The solids built this session go to the caches folder, so the project opens quickly next time.
    private static func keepSolidsOnDisk(_ session: ModelingSession) {
        // Hidden solids too, when they were built (shown, or used by an operation).
        // Taken now, so leaving the project can release the memory while they are written.
        let solids = SolidCache.shared.builtForDisk(session.workspace.bodies)
        Task.detached(priority: .utility) { SolidCache.write(solids) }
    }
}
