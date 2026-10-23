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
    nonisolated override func contents(forType typeName: String) throws -> Any {
        try ProjectCodec.encode(snapshot.withLock { $0.project })
    }

    @MainActor func updateWorkspace(_ workspace: Workspace) throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let changed = try snapshot.withLock { state in
            guard workspace != state.project.workspace else { return false }
            var updated = state.project
            updated.update(workspace)
            try ProjectCodec.validate(updated)
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

    init() {
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
        let hosting = UIHostingController(rootView: HomeView(model: home, browser: browser))
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
        document.open { [weak self] success in
          Task { @MainActor in
            guard let self else { if scoped { url.stopAccessingSecurityScopedResource() }; return }
            guard success else {
                self.activeDocument = nil
                if scoped { url.stopAccessingSecurityScopedResource() }
                RecentProjects.shared.refresh()
                self.showError("Could not open project", "The file could not be read or uses an unsupported format. The original file has been preserved.")
                return
            }
            self.scopedURL = scoped ? url : nil
            guard let document = self.activeDocument else { return }
            let session = ModelingSession(document: document)
            if self.fileTests, ProcessInfo.processInfo.arguments.contains("--select-document-sketch"), let shape = session.workspace.shapes.first {
                session.selection = .shape(shape.id)
            }
            session.onOpenProjects = { [weak self] in self?.closeCurrent { _ in } }
            session.onNewProject = { [weak self] in self?.chooseNewProject() }
            session.onSaveAs = { [weak self] in self?.saveAs() }
            self.activeSession = session
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
        }
    }

    private func closeCurrent(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let document = activeDocument, let session = activeSession else { completion(true); return }
        guard !session.viewCube.pencilActive, !session.isProjectBusy else { completion(false); return }
        guard !session.isAssistantBusy else { session.saveError = Self.assistantBusyMessage; completion(false); return }
        session.isProjectBusy = true
        session.save(withThumbnail: true) { [weak self] saved in
            guard let self else { completion(false); return }
            guard saved else { session.isProjectBusy = false; completion(false); return }
            // Home's card takes the picture just saved.
            RecentProjects.shared.record(document.fileURL, project: document.project)
            document.close { success in
              Task { @MainActor in
                guard success else { session.isProjectBusy = false; session.saveError = "The project could not be closed safely. Your work is still open."; completion(false); return }
                session.cancelTransient()
                self.activeEditor?.dismiss(animated: true) {
                    self.activeEditor = nil; self.activeSession = nil; self.activeDocument = nil
                    self.scopedURL?.stopAccessingSecurityScopedResource(); self.scopedURL = nil
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
        do {
            var copy = Project(workspace: session.workspace)
            copy.preview = session.projectThumbnailProvider?()?.pngData()
            try presentFilePicker(project: copy, name: session.projectName + " Copy", title: "Save Project As")
        } catch { showError("Could not save a copy", error.localizedDescription) }
    }

    private func presentFilePicker(project: Project, name: String, title: String) throws {
        let url = try stage(project, name: validName(name))
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

    private func stage(_ project: Project, name: String) throws -> URL {
        clearStaging()
        let directory = URL.temporaryDirectory.appendingPathComponent("SwipeAndSketch-Staging/\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("swipesketch")
        try ProjectCodec.create(project, at: url)
        stagingDirectory = directory
        return url
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
    func autosaveActiveProject() { activeSession?.save(withThumbnail: true) }
}
