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
/// without reading (or downloading) the files. Moved or deleted files drop out quietly.
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

    init(defaults: UserDefaults = .standard, documents: URL = .documentsDirectory,
         cache: URL = .cachesDirectory.appendingPathComponent("RecentPictures", isDirectory: true)) {
        self.defaults = defaults
        self.documents = documents
        self.cache = cache
        stored = (defaults.data(forKey: "recentProjects")).flatMap { try? JSONDecoder().decode([Stored].self, from: $0) } ?? []
        dismissed = Set(defaults.stringArray(forKey: "recentProjects.dismissed") ?? [])
    }

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
                self.stored.removeAll { found.forgotten.contains($0.path) }
                for index in self.stored.indices { if let path = found.moved[self.stored[index].path] { self.stored[index].path = path } }
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

    private nonisolated static func find(stored: [Stored], dismissed: Set<String>, documents: URL) -> (projects: [RecentProject], forgotten: Set<String>, moved: [String: String]) {
        let fileManager = FileManager.default
        let base = key(documents)
        var byPath: [String: RecentProject] = [:]
        var forgotten = Set<String>()
        // A bookmark follows its file when it moves; the entry then takes the new path.
        var moved: [String: String] = [:]
        func place(_ path: String) -> RecentProject.Place {
            if path.hasPrefix(base + "/") { return .iPad }
            return path.contains("/Mobile Documents/") ? .iCloud : .elsewhere
        }
        for entry in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: entry.bookmark, bookmarkDataIsStale: &stale) else { forgotten.insert(entry.path); continue }
            let path = key(url)
            if path != entry.path { moved[entry.path] = path }
            let where_ = place(path)
            if where_ == .iPad, !fileManager.fileExists(atPath: path) { forgotten.insert(entry.path); continue }
            byPath[path] = RecentProject(id: path, url: url, name: url.deletingPathExtension().lastPathComponent, date: entry.opened,
                                         place: where_, sketches: entry.sketches, solids: entry.solids)
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
