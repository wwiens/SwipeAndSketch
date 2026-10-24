import Foundation

/// The mini walkthroughs on swipesketch.com: scripted canvas lessons the help card can play in a web
/// view beside its text. The app finds them through the website's public catalog, which maps each
/// `HelpTopic` to its lessons; the lessons themselves are never bundled.
enum Walkthroughs {
    static let host = "swipesketch.com"
    static let origin = URL(string: "https://swipesketch.com")!
    /// The website's name for this app's menus and tools; the catalog answers only lessons recorded on it.
    static let uiRevision = "canvas-menus-v3"
    static let protocolName = "swipesketch.walkthrough.v1"
    static let catalogURL = URL(string: "https://swipesketch.com/walkthroughs/catalog.json?ui=canvas-menus-v3")!
    /// The script message handler the player posts its events to.
    static let messageHandler = "swipeSketchWalkthrough"
    /// The catalog is cached for five minutes on the website too.
    static let refreshInterval: TimeInterval = 300

    /// Release names and lesson IDs are plain identifiers (case-sensitive: `SS-T026`).
    static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 80 && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// The player page of `release` on the website, over HTTPS with nothing else in the address.
    static func isPlayerPage(_ url: URL, release: String) -> Bool {
        guard url.scheme == "https", url.host == host, url.port == nil, url.user == nil, url.password == nil,
              url.fragment == nil, url.path(percentEncoded: true) == "/walkthroughs/releases/\(release)/player/" else { return false }
        return true
    }

    /// A player address the help card may show: the release's player with a lesson, and the compact
    /// `embed=1` layout or nothing else.
    static func isPlayerURL(_ url: URL, release: String) -> Bool {
        guard isPlayerPage(url, release: release),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        var lesson: String?
        for item in items {
            switch (item.name, item.value) {
            case ("lesson", let value?) where lesson == nil && isIdentifier(value): lesson = value
            case ("embed", "1"): continue
            default: return false
            }
        }
        return lesson != nil
    }

    /// The lesson a player address shows.
    static func lesson(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "lesson" }?.value
    }

    /// The compact player for `lesson`, resolved against the website and checked.
    static func embedURL(_ path: String, lesson: String, release: String) -> URL? {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, isPlayerURL(url, release: release),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.contains(URLQueryItem(name: "lesson", value: lesson)),
              items.contains(URLQueryItem(name: "embed", value: "1")) else { return nil }
        return url
    }
}

struct WalkthroughLesson: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    /// The name on the picker under the player.
    let shortTitle: String
    let summary: String
    let embed: URL
}

/// A checked copy of the website's catalog: the release and, for each help topic the website maps,
/// its lessons with the intended first one first.
struct WalkthroughCatalog: Codable, Equatable {
    let release: String
    let topics: [String: [WalkthroughLesson]]

    enum Problem: Error, Equatable {
        case unreadable, unavailable, incompatible, badRelease, duplicateLesson(String), missingLesson(String), badAddress(String)
    }

    func lessons(for topic: HelpTopic) -> [WalkthroughLesson] { topics[topic.rawValue] ?? [] }

    /// Reads and checks the catalog response. Anything the app can't trust fails the whole catalog,
    /// so the help card keeps its text rather than playing an unexpected lesson.
    static func validated(_ data: Data) throws(Problem) -> WalkthroughCatalog {
        struct Lesson: Decodable { let id: String; let title: String; let shortTitle: String?; let summary: String?; let embed: String }
        struct Topic: Decodable { let `default`: String; let lessons: [String] }
        struct Response: Decodable {
            let schemaVersion: Int; let available: Bool; let release: String
            let uiRevision: String; let `protocol`: String
            let lessons: [Lesson]; let topics: [String: Topic]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw .unreadable }
        guard response.available else { throw .unavailable }
        guard response.schemaVersion == 1, response.protocol == Walkthroughs.protocolName,
              response.uiRevision == Walkthroughs.uiRevision else { throw .incompatible }
        let release = response.release
        guard Walkthroughs.isIdentifier(release) else { throw .badRelease }
        var byID: [String: Lesson] = [:]
        for lesson in response.lessons {
            guard Walkthroughs.isIdentifier(lesson.id) else { throw .badAddress(lesson.id) }
            guard byID.updateValue(lesson, forKey: lesson.id) == nil else { throw .duplicateLesson(lesson.id) }
        }
        var topics: [String: [WalkthroughLesson]] = [:]
        for (name, topic) in response.topics {
            var ids = [topic.default]
            for id in topic.lessons where !ids.contains(id) { ids.append(id) }
            topics[name] = try ids.map { id throws(Problem) in
                guard let lesson = byID[id] else { throw .missingLesson(id) }
                guard let embed = Walkthroughs.embedURL(lesson.embed, lesson: id, release: release) else { throw .badAddress(id) }
                return WalkthroughLesson(id: id, title: lesson.title, shortTitle: lesson.shortTitle ?? lesson.title,
                                         summary: lesson.summary ?? "", embed: embed)
            }
        }
        return WalkthroughCatalog(release: release, topics: topics)
    }
}

/// What the player reports through its script message handler.
enum WalkthroughEvent: Equatable {
    /// `step` counts from zero; `step == totalSteps` is the completion screen.
    case state(lesson: String, step: Int, totalSteps: Int, status: Status, title: String)
    case loadFailed

    enum Status: String { case ready, playing, paused, complete }

    /// Reads a message body, ignoring anything that isn't exactly this protocol's.
    init?(body: Any) {
        guard let message = body as? [String: Any], message["protocol"] as? String == Walkthroughs.protocolName else { return nil }
        switch message["type"] as? String {
        case "error":
            guard message["code"] as? String == "load_failed" else { return nil }
            self = .loadFailed
        case "ready", "state":
            guard let lesson = message["lesson"] as? String, Walkthroughs.isIdentifier(lesson),
                  let step = (message["step"] as? NSNumber)?.intValue, let total = (message["totalSteps"] as? NSNumber)?.intValue,
                  step >= 0, total >= 0, step <= total,
                  let status = (message["status"] as? String).flatMap(Status.init), let title = message["title"] as? String
            else { return nil }
            self = .state(lesson: lesson, step: step, totalSteps: total, status: status, title: title)
        default:
            return nil
        }
    }
}

/// The catalog the help card plays from: the last one checked, kept on disk so the pinned lesson
/// addresses survive a relaunch, and refreshed from the website at most every five minutes.
@MainActor final class WalkthroughLibrary: ObservableObject {
    static let shared = WalkthroughLibrary()

    @Published private(set) var catalog: WalkthroughCatalog?
    private var lastRefresh: Date?
    private var refreshing = false
    private let cacheFile: URL?
    private let session: URLSession

    init(cacheFile: URL? = WalkthroughLibrary.defaultCacheFile, session: URLSession = .init(configuration: .ephemeral)) {
        self.cacheFile = cacheFile
        self.session = session
        if let cacheFile, let data = try? Data(contentsOf: cacheFile) { catalog = try? WalkthroughCatalog.validated(data) }
    }

    nonisolated static var defaultCacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "walkthroughs-catalog.json")
    }

    func lessons(for topic: HelpTopic) -> [WalkthroughLesson] { catalog?.lessons(for: topic) ?? [] }

    /// Looks for a newer compatible release. A failure keeps what is cached; only the website turning
    /// walkthroughs off clears it.
    func refresh() {
        guard !refreshing, lastRefresh.map({ Date.now.timeIntervalSince($0) > Walkthroughs.refreshInterval }) ?? true else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            var request = URLRequest(url: Walkthroughs.catalogURL, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https", http.url?.host == Walkthroughs.host else { return }
            lastRefresh = .now
            do {
                let fresh = try WalkthroughCatalog.validated(data)
                if fresh != catalog { catalog = fresh }
                if let cacheFile { try? data.write(to: cacheFile, options: .atomic) }
            } catch WalkthroughCatalog.Problem.unavailable {
                catalog = nil
                if let cacheFile { try? FileManager.default.removeItem(at: cacheFile) }
            } catch {}
        }
    }
}
