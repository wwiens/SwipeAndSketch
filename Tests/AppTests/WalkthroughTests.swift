import XCTest
@testable import SwipeAndSketch

/// The website walkthrough catalog the help card plays from (Walkthroughs.swift): what it trusts,
/// how topics pick their lessons, and which player messages count.
@MainActor final class WalkthroughTests: XCTestCase {
    private func lesson(_ id: String, release: String = "canvas-2026-10-23-v2", embed: String? = nil) -> [String: Any] {
        ["id": id, "title": "Title \(id)", "shortTitle": "Short \(id)", "summary": "Summary \(id)",
         "page": "/walkthroughs/releases/\(release)/player/?lesson=\(id)",
         "embed": embed ?? "/walkthroughs/releases/\(release)/player/?lesson=\(id)&embed=1"]
    }

    private func catalog(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var json: [String: Any] = [
            "schemaVersion": 1, "available": true, "release": "canvas-2026-10-23-v2",
            "uiRevision": "canvas-menus-v3", "protocol": "swipesketch.walkthrough.v1",
            "lessons": [lesson("batch-r063"), lesson("batch-r060"), lesson("SS-T026"), lesson("unmapped-r001")],
            "topics": [
                "extrude": ["default": "batch-r063", "lessons": ["batch-r060", "batch-r063"]],
                "measure": ["default": "SS-T026", "lessons": ["SS-T026"]],
            ],
        ]
        change(&json)
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func problem(_ data: Data) -> WalkthroughCatalog.Problem? {
        do { _ = try WalkthroughCatalog.validated(data); return nil } catch { return error }
    }

    func testTopicsStartWithTheirDefaultAndKeepTheServersOrder() throws {
        let checked = try WalkthroughCatalog.validated(catalog())
        XCTAssertEqual(checked.release, "canvas-2026-10-23-v2")
        let extrude = checked.lessons(for: .extrude)
        XCTAssertEqual(extrude.map(\.id), ["batch-r063", "batch-r060"])
        XCTAssertEqual(extrude[0].shortTitle, "Short batch-r063")
        XCTAssertEqual(extrude[0].embed.absoluteString,
                       "https://swipesketch.com/walkthroughs/releases/canvas-2026-10-23-v2/player/?lesson=batch-r063&embed=1")
        // IDs keep their case.
        XCTAssertEqual(checked.lessons(for: .measure).map(\.id), ["SS-T026"])
        // A topic the website doesn't map keeps only its text.
        XCTAssertTrue(checked.lessons(for: .assistant).isEmpty)
    }

    func testIncompatibleOrUnavailableCatalogsAreRefused() {
        XCTAssertEqual(problem(Data("not json".utf8)), .unreadable)
        XCTAssertEqual(problem(catalog { $0["available"] = false }), .unavailable)
        XCTAssertEqual(problem(catalog { $0["schemaVersion"] = 2 }), .incompatible)
        XCTAssertEqual(problem(catalog { $0["uiRevision"] = "canvas-menus-v4" }), .incompatible)
        XCTAssertEqual(problem(catalog { $0["protocol"] = "swipesketch.walkthrough.v2" }), .incompatible)
        XCTAssertEqual(problem(catalog { $0["release"] = "" }), .badRelease)
        XCTAssertEqual(problem(catalog { $0["release"] = "../other" }), .badRelease)
    }

    func testLessonsMustBeUniqueAndEveryMappedOneMustExist() {
        XCTAssertEqual(problem(catalog { $0["lessons"] = [self.lesson("batch-r063"), self.lesson("batch-r063")] }),
                       .duplicateLesson("batch-r063"))
        XCTAssertEqual(problem(catalog { $0["topics"] = ["extrude": ["default": "batch-r999", "lessons": [] as [String]]] }),
                       .missingLesson("batch-r999"))
    }

    func testOnlyTheReleasesOwnPlayerOnTheWebsiteIsTrusted() {
        let release = "canvas-2026-10-23-v2"
        let good = "/walkthroughs/releases/\(release)/player/?lesson=batch-r063&embed=1"
        XCTAssertNotNil(Walkthroughs.embedURL(good, lesson: "batch-r063", release: release))
        XCTAssertNotNil(Walkthroughs.embedURL("https://swipesketch.com" + good, lesson: "batch-r063", release: release))
        for bad in [
            "http://swipesketch.com" + good,
            "https://evil.example" + good,
            "https://swipesketch.com.evil.example" + good,
            "https://swipesketch.com:8443" + good,
            "https://user:pass@swipesketch.com" + good,
            "//evil.example" + good,
            "/walkthroughs/releases/canvas-2026-01-01-v1/player/?lesson=batch-r063&embed=1",
            "/walkthroughs/releases/\(release)/player/index.html?lesson=batch-r063&embed=1",
            "/walkthroughs/?topic=extrude",
            "/walkthroughs/releases/\(release)/player/?lesson=batch-r064&embed=1",
            "/walkthroughs/releases/\(release)/player/?lesson=batch-r063",
            "/walkthroughs/releases/\(release)/player/?lesson=batch-r063&embed=1&next=https://evil.example",
            "/walkthroughs/releases/\(release)/player/?lesson=batch-r063&lesson=batch-r064&embed=1",
            "/walkthroughs/releases/\(release)/player/?lesson=batch-r063&embed=1#x",
        ] {
            XCTAssertNil(Walkthroughs.embedURL(bad, lesson: "batch-r063", release: release), bad)
        }
        XCTAssertEqual(problem(catalog { $0["lessons"] = [self.lesson("batch-r063", embed: "https://evil.example/x"),
                                                           self.lesson("batch-r060"), self.lesson("SS-T026")] }),
                       .badAddress("batch-r063"))
        // The player may move to another lesson of the same release, in either layout.
        let player = "https://swipesketch.com/walkthroughs/releases/\(release)/player/"
        XCTAssertTrue(Walkthroughs.isPlayerURL(URL(string: player + "?lesson=batch-r064")!, release: release))
        XCTAssertTrue(Walkthroughs.isPlayerURL(URL(string: player + "?lesson=SS-T026&embed=1")!, release: release))
        XCTAssertFalse(Walkthroughs.isPlayerURL(URL(string: player)!, release: release))
        XCTAssertFalse(Walkthroughs.isPlayerURL(URL(string: "https://swipesketch.com/help/extrude/")!, release: release))
    }

    func testPlayerMessagesMustMatchTheProtocol() {
        let state: [String: Any] = ["protocol": "swipesketch.walkthrough.v1", "type": "state", "lesson": "batch-r063",
                                    "step": 2, "totalSteps": 9, "status": "playing", "speed": 1, "title": "Type the depth"]
        XCTAssertEqual(WalkthroughEvent(body: state),
                       .state(lesson: "batch-r063", step: 2, totalSteps: 9, status: .playing, title: "Type the depth"))
        var ready = state
        ready["type"] = "ready"; ready["step"] = 9; ready["status"] = "complete"
        XCTAssertEqual(WalkthroughEvent(body: ready),
                       .state(lesson: "batch-r063", step: 9, totalSteps: 9, status: .complete, title: "Type the depth"))
        XCTAssertEqual(WalkthroughEvent(body: ["protocol": "swipesketch.walkthrough.v1", "type": "error", "code": "load_failed"]),
                       .loadFailed)

        func broken(_ change: (inout [String: Any]) -> Void) -> WalkthroughEvent? {
            var message = state
            change(&message)
            return WalkthroughEvent(body: message)
        }
        XCTAssertNil(broken { $0["protocol"] = "other" })
        XCTAssertNil(broken { $0["type"] = "command" })
        XCTAssertNil(broken { $0["status"] = "rewinding" })
        XCTAssertNil(broken { $0["step"] = 10 })
        XCTAssertNil(broken { $0["step"] = "2" })
        XCTAssertNil(broken { $0["lesson"] = nil })
        XCTAssertNil(WalkthroughEvent(body: "pause"))
        XCTAssertNil(WalkthroughEvent(body: ["protocol": "swipesketch.walkthrough.v1", "type": "error", "code": "other"]))
    }

    func testTheLibraryReadsItsCacheAndDropsOneItCannotTrust() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "catalog.json")

        try catalog().write(to: file)
        XCTAssertEqual(WalkthroughLibrary(cacheFile: file).lessons(for: .extrude).first?.id, "batch-r063")

        try catalog { $0["uiRevision"] = "canvas-menus-v2" }.write(to: file)
        XCTAssertNil(WalkthroughLibrary(cacheFile: file).catalog)
        XCTAssertNil(WalkthroughLibrary(cacheFile: folder.appending(path: "missing.json")).catalog)
    }
}
