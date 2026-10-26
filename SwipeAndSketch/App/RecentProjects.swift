import SwiftUI

/// A project shown on Home: one the app opened before, or one in On My iPad › Swipe & Sketch.
struct RecentProject: Identifiable, Equatable, Sendable {
    enum Place: Sendable {
        case iPad, iCloud, elsewhere
        var title: String {
            switch self { case .iPad: "On My iPad"; case .iCloud: "iCloud Drive"; case .elsewhere: "Files" }
        }
    }
    /// The file's standardized path.
    var id: String
    var url: URL
    var name: String
    /// When it was last opened here or changed, whichever is later.
    var date: Date
    var place: Place
    /// Counts from when it was last open here; nil for a file not opened yet.
    var sketches: Int?
    var solids: Int?
}

/// The projects Home lists (October 22, 2026): those opened here, kept as bookmarks so files in
/// iCloud Drive and other places reopen, plus every project in the app's own Documents folder.
/// Each opened project's picture is kept in Caches when it closes, so the list shows pictures
/// without reading (or downloading) the files. Moved or renamed files are followed to their new
/// place; deleted ones (gone, or in Recently Deleted) drop out quietly, while iCloud files not yet
/// downloaded or briefly out of reach stay (October 25, 2026).
@MainActor final class RecentProjects: ObservableObject {
    static let shared = RecentProjects()
    @Published private(set) var projects: [RecentProject] = []
    @Published private(set) var pictures: [String: UIImage] = [:]

    private struct Stored: Codable, Sendable {
        var picture: UUID
        var path: String
        var bookmark: Data
        var opened: Date
        var sketches: Int
        var solids: Int
    }
    private static let limit = 40
    private let defaults: UserDefaults
    private let documents: URL
    private let cache: URL
    private var stored: [Stored]
    /// Projects in Documents removed from Home; they come back when opened again.
    private var dismissed: Set<String>
    private var refreshing: Task<Void, Never>?
    private var watcher: FolderWatcher?

    init(defaults: UserDefaults = .standard, documents: URL = .documentsDirectory,
         cache: URL = .cachesDirectory.appendingPathComponent("RecentPictures", isDirectory: true)) {
        self.defaults = defaults
        self.documents = documents
        self.cache = cache
        stored = (defaults.data(forKey: "recentProjects")).flatMap { try? JSONDecoder().decode([Stored].self, from: $0) } ?? []
        dismissed = Set(defaults.stringArray(forKey: "recentProjects.dismissed") ?? [])
    }

    deinit { if let watcher { NSFileCoordinator.removeFilePresenter(watcher) } }

    nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// Notes an open project (call it while the file's security scope is open, so the bookmark
    /// carries it): its counts, and its saved picture when it has one.
    func record(_ url: URL, project: Project) {
        let path = Self.key(url)
        guard let bookmark = try? url.bookmarkData() else { return }
        var entry = stored.first { $0.path == path } ?? Stored(picture: UUID(), path: path, bookmark: bookmark, opened: .now, sketches: 0, solids: 0)
        entry.bookmark = bookmark
        entry.opened = .now
        entry.sketches = project.workspace.sketches.count
        entry.solids = project.workspace.bodies.count
        stored.removeAll { $0.path == path }
        stored.insert(entry, at: 0)
        for old in stored.dropFirst(Self.limit) { try? FileManager.default.removeItem(at: pictureURL(old.picture)) }
        stored = Array(stored.prefix(Self.limit))
        dismissed.remove(path)
        if let png = project.preview, let image = UIImage(data: png) {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? png.write(to: pictureURL(entry.picture), options: .atomic)
            pictures[path] = image
        }
        save()
        refresh()
    }

    /// Takes a project off Home (the file stays where it is).
    func remove(_ project: RecentProject) {
        if let entry = stored.first(where: { $0.path == project.id }) { try? FileManager.default.removeItem(at: pictureURL(entry.picture)) }
        stored.removeAll { $0.path == project.id }
        if project.place == .iPad { dismissed.insert(project.id) }
        projects.removeAll { $0.id == project.id }
        save()
    }

    /// Refreshes when something in Documents is deleted, moved, or added, even by Files beside the app.
    func watchDocuments() {
        guard watcher == nil else { return }
        let watcher = FolderWatcher(documents) { [weak self] in self?.refresh() }
        NSFileCoordinator.addFilePresenter(watcher)
        self.watcher = watcher
    }

    /// Finds the projects again: resolves the bookmarks and looks through Documents, off the main thread.
    func refresh() {
        refreshing?.cancel()
        let stored = stored, dismissed = dismissed, documents = documents, cache = cache
        refreshing = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.find(stored: stored, dismissed: dismissed, documents: documents)
            }.value
            guard !Task.isCancelled else { return }
            projects = found.projects
            if !found.forgotten.isEmpty || !found.moved.isEmpty {
                for entry in self.stored where found.forgotten.contains(entry.path) {
                    try? FileManager.default.removeItem(at: pictureURL(entry.picture))
                    pictures[entry.path] = nil
                }
                self.stored.removeAll { found.forgotten.contains($0.path) }
                for index in self.stored.indices {
                    guard let move = found.moved[self.stored[index].path] else { continue }
                    if let picture = pictures.removeValue(forKey: self.stored[index].path) { pictures[move.path] = picture }
                    self.stored[index].path = move.path
                    if let bookmark = move.bookmark { self.stored[index].bookmark = bookmark }
                }
                save()
            }
            let wanted = found.projects.filter { pictures[$0.id] == nil }
            guard !wanted.isEmpty else { return }
            let pictureIDs = Dictionary(self.stored.map { ($0.path, $0.picture) }, uniquingKeysWith: { first, _ in first })
            let loaded = await Task.detached(priority: .utility) { () -> [String: Data] in
                var loaded: [String: Data] = [:]
                for project in wanted {
                    if let id = pictureIDs[project.id], let png = try? Data(contentsOf: cache.appendingPathComponent(id.uuidString + ".png")) {
                        loaded[project.id] = png
                    } else if project.place == .iPad, let data = try? Data(contentsOf: project.url, options: .alwaysMapped),
                              let png = ProjectPreview.png(in: data) {
                        // Only files already on this iPad are read; others would be downloaded.
                        loaded[project.id] = png
                    }
                }
                return loaded
            }.value
            guard !Task.isCancelled else { return }
            for (path, png) in loaded { if let image = UIImage(data: png) { pictures[path] = image } }
        }
    }

    /// Where a stored project's file is now. `gone` only when it was really deleted: the bookmark
    /// cannot find it and nothing stands in its place, or it is in a Recently Deleted (`.Trash`) folder.
    enum Whereabouts: Equatable, Sendable {
        /// Found, possibly moved or renamed; `bookmark` is set when the old one should be replaced.
        case at(URL, bookmark: Data?)
        /// Not reachable just now (an iCloud file not downloaded yet, a provider that is away): kept, at
        /// what its bookmark found or else its last place.
        case unreachable(URL?)
        case gone
    }

    nonisolated static func whereabouts(path: String, bookmark: Data, documents: URL) -> Whereabouts {
        let fileManager = FileManager.default
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // An iCloud file evicted to a placeholder no longer resolves, but is still there to download.
            return hasCloudPlaceholder(URL(fileURLWithPath: path)) ? .unreachable(nil) : .gone
        } catch {
            return .unreachable(nil)
        }
        if isTrashed(url) { return .gone }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if fileManager.fileExists(atPath: url.path) || hasCloudPlaceholder(url) {
            let renewed = stale || key(url) != path ? try? url.bookmarkData() : nil
            return .at(url, bookmark: renewed)
        }
        // Outside the app's own folders, a file whose security scope did not open may only look missing.
        let own = key(url).hasPrefix(key(documents.deletingLastPathComponent()) + "/")
        return scoped || own ? .gone : .unreachable(url)
    }

    /// In a Recently Deleted folder: Files moves a deleted project into the `.Trash` folder of its
    /// app's Documents or of iCloud Drive, where its bookmark still finds it.
    nonisolated static func isTrashed(_ url: URL) -> Bool {
        if url.standardizedFileURL.pathComponents.contains(".Trash") { return true }
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false) {
            return key(url).hasPrefix(key(trash) + "/")
        }
        return false
    }

    /// An iCloud file not downloaded yet may be stood in for by a hidden `.Name.ext.icloud` file.
    nonisolated static func hasCloudPlaceholder(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    private nonisolated static func find(stored: [Stored], dismissed: Set<String>, documents: URL) -> (projects: [RecentProject], forgotten: Set<String>, moved: [String: (path: String, bookmark: Data?)]) {
        let fileManager = FileManager.default
        let base = key(documents)
        var byPath: [String: RecentProject] = [:]
        var forgotten = Set<String>()
        // A bookmark follows its file when it moves; the entry then takes the new path.
        var moved: [String: (path: String, bookmark: Data?)] = [:]
        func place(_ path: String) -> RecentProject.Place {
            if path.hasPrefix(base + "/") { return .iPad }
            return path.contains("/Mobile Documents/") ? .iCloud : .elsewhere
        }
        for entry in stored {
            let url: URL
            switch whereabouts(path: entry.path, bookmark: entry.bookmark, documents: documents) {
            case .gone: forgotten.insert(entry.path); continue
            case let .unreachable(found): url = found ?? URL(fileURLWithPath: entry.path)
            case let .at(found, bookmark):
                url = found
                let path = key(found)
                if path != entry.path || bookmark != nil { moved[entry.path] = (path, bookmark) }
            }
            let path = key(url)
            byPath[path] = RecentProject(id: path, url: url, name: url.deletingPathExtension().lastPathComponent, date: entry.opened,
                                         place: place(path), sketches: entry.sketches, solids: entry.solids)
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        if let files = fileManager.enumerator(at: documents, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in files {
                if url.lastPathComponent == "Inbox", key(url.deletingLastPathComponent()) == base { files.skipDescendants(); continue }
                guard url.pathExtension == "swipesketch" else { continue }
                let path = key(url)
                guard !dismissed.contains(path) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if var known = byPath[path] {
                    known.date = max(known.date, modified)
                    byPath[path] = known
                } else {
                    byPath[path] = RecentProject(id: path, url: url, name: url.deletingPathExtension().lastPathComponent, date: modified, place: .iPad)
                }
            }
        }
        return (byPath.values.sorted { $0.date > $1.date }, forgotten, moved)
    }

    private func pictureURL(_ id: UUID) -> URL { cache.appendingPathComponent(id.uuidString + ".png") }

    private func save() {
        defaults.set(try? JSONEncoder().encode(stored), forKey: "recentProjects")
        defaults.set(Array(dismissed), forKey: "recentProjects.dismissed")
    }
}

/// Tells Home when Files (here or beside the app) deletes, moves, or adds something in Documents.
/// Several changes in a row make one refresh.
private final class FolderWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let changed: @MainActor () -> Void
    private var pending: DispatchWorkItem?

    init(_ folder: URL, changed: @escaping @MainActor () -> Void) {
        presentedItemURL = folder
        self.changed = changed
    }

    private func changeSoon() {
        pending?.cancel()
        let changed = changed
        let work = DispatchWorkItem { MainActor.assumeIsolated { changed() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func presentedSubitemDidAppear(at url: URL) { changeSoon() }
    func presentedSubitemDidChange(at url: URL) { changeSoon() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changeSoon() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        completionHandler(nil)
        changeSoon()
    }
}
