import XCTest
import WebKit
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
        for value: Any in [true, 1.5, -1, Double.infinity, Double.nan, NSNumber(value: UInt64.max)] {
            XCTAssertNil(broken { $0["step"] = value }, "Invalid step: \(value)")
            XCTAssertNil(broken { $0["totalSteps"] = value }, "Invalid count: \(value)")
        }
        for value: Any in [true, "1", 0, 1.25, 3, NSNull()] {
            XCTAssertNil(broken { $0["speed"] = value }, "Invalid speed: \(value)")
        }
        XCTAssertNil(broken { $0["speed"] = nil })
        XCTAssertNil(broken { $0["status"] = "complete" })
        XCTAssertNil(broken { $0["step"] = 9 })
        XCTAssertNil(WalkthroughEvent(body: "pause"))
        XCTAssertNil(WalkthroughEvent(body: ["protocol": "swipesketch.walkthrough.v1", "type": "error", "code": "other"]))
    }

    func testEveryCatalogAddressIsValidatedEvenWithoutATopicMapping() {
        for field in ["page", "embed"] {
            for address in ["https://evil.example/player/", "/walkthroughs/?topic=extrude",
                            "/walkthroughs/releases/canvas-2026-10-23-v2/player/?lesson=other&embed=1"] {
                XCTAssertEqual(problem(catalog {
                    var lessons = $0["lessons"] as! [[String: Any]]
                    lessons[3][field] = address
                    $0["lessons"] = lessons
                }), .badAddress("unmapped-r001"))
            }
        }
        for release in [".", ".."] {
            XCTAssertEqual(problem(catalog { $0["release"] = release }), .badRelease)
        }
        let duplicateEmbed = "/walkthroughs/releases/canvas-2026-10-23-v2/player/?lesson=batch-r063&embed=1&embed=1"
        XCTAssertNil(Walkthroughs.embedURL(duplicateEmbed, lesson: "batch-r063", release: "canvas-2026-10-23-v2"))
    }

    /// Real WebKit navigation and script messages, with an in-memory response at the normal
    /// trusted URL. No live network, website assets or document/kernel bridge is involved.
    private func player(html: String = SimulatedPlayerWebView.html, timeout: Duration = .seconds(10)) throws
        -> (WalkthroughPlayer.Coordinator, SimulatedPlayerWebView, WalkthroughPlayback, WalkthroughLesson) {
        let playback = WalkthroughPlayback()
        let catalog = try WalkthroughCatalog.validated(catalog())
        let lesson = try XCTUnwrap(catalog.lessons(for: .extrude).first)
        let coordinator = WalkthroughPlayer.Coordinator(release: catalog.release, playback: playback, readyTimeout: timeout)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(TestPlayerMessageHandler(coordinator), name: Walkthroughs.messageHandler)
        let web = SimulatedPlayerWebView(frame: .init(x: 0, y: 0, width: 560, height: 400), configuration: config)
        web.html = html
        coordinator.web = web
        web.navigationDelegate = coordinator
        coordinator.load(lesson, attempt: 0)
        return (coordinator, web, playback, lesson)
    }

    private func waitForPhase(_ phase: WalkthroughPlayback.Phase, _ playback: WalkthroughPlayback,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if playback.phase == phase { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(playback.phase, phase, file: file, line: line)
    }

    func testTrustedPlayerReadinessPauseBackgroundAndRetryThroughWebKit() async throws {
        let (coordinator, web, playback, lesson) = try player()
        defer { coordinator.stop(); web.stopLoading() }
        try await waitForPhase(.ready, playback)
        // Initial discovery is pinned to the explicit default, with no extra loads on view updates.
        coordinator.load(lesson, attempt: 0)
        XCTAssertEqual(web.requests.count, 1)
        playback.pause()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        // WebKit serializes these commands before the following JavaScript read.
        let commands = try await web.callAsyncJavaScript("return commands;", in: nil, contentWorld: .page) as? [[String: String]]
        XCTAssertGreaterThanOrEqual(commands?.count ?? 0, 2)
        XCTAssertTrue(commands?.allSatisfy { $0 == ["protocol": Walkthroughs.protocolName, "action": "pause"] } == true)
        playback.retry()
        coordinator.load(lesson, attempt: playback.attempt)
        try await waitForPhase(.ready, playback)
        XCTAssertEqual(web.requests.map(\.url), [lesson.embed, lesson.embed])
        let pauses = try await web.callAsyncJavaScript("return commands.length;", in: nil, contentWorld: .page) as? Int
        XCTAssertGreaterThanOrEqual(pauses ?? 0, 1, "Readiness after backgrounding must explicitly pause")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func testPlayerNavigationStartsANewReadyDeadlineAndCanRetryAfterFailure() async throws {
        let (coordinator, web, playback, lesson) = try player(timeout: .seconds(1))
        defer { coordinator.stop(); web.stopLoading() }
        try await waitForPhase(.ready, playback)
        let other = try XCTUnwrap(Walkthroughs.embedURL(
            "/walkthroughs/releases/\(coordinator.release)/player/?lesson=batch-r060&embed=1",
            lesson: "batch-r060", release: coordinator.release))
        // The old page's state must not make the next page ready.
        coordinator.beginNavigation(to: other)
        _ = try await web.callAsyncJavaScript("post(state);", in: nil, contentWorld: .page)
        try await waitForPhase(.failed, playback)
        playback.retry()
        coordinator.load(lesson, attempt: playback.attempt)
        try await waitForPhase(.ready, playback)
    }

    func testGeometryLoadFailureAndHTTP404OfferRetry() async throws {
        let (coordinator, web, playback, lesson) = try player()
        defer { coordinator.stop(); web.stopLoading() }
        try await waitForPhase(.ready, playback)
        _ = try await web.callAsyncJavaScript("post(message);", arguments: ["message": [
            "protocol": Walkthroughs.protocolName, "type": "error", "code": "load_failed"
        ]], in: nil, contentWorld: .page)
        try await waitForPhase(.failed, playback)
        // Queued progress cannot revive a failed page.
        _ = try await web.callAsyncJavaScript("post(state);", in: nil, contentWorld: .page)
        await Task.yield()
        XCTAssertEqual(playback.phase, .failed)
        playback.retry(); coordinator.load(lesson, attempt: playback.attempt)
        try await waitForPhase(.ready, playback)
        // Supply the HTTP error directly to the navigation policy; simulated page loads above
        // exercise the bridge without depending on the simulated loader's HTTP error handling.
        let response = try XCTUnwrap(HTTPURLResponse(url: lesson.embed, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
        let policy = coordinator.responsePolicy(response, isMainFrame: true)
        XCTAssertEqual(policy, .cancel)
        try await waitForPhase(.failed, playback)
        playback.retry(); coordinator.load(lesson, attempt: playback.attempt)
        try await waitForPhase(.ready, playback)
    }

    func testSubframeAndMalformedMessagesCannotMakePlayerReady() async throws {
        let html = """
        <script>
        const post=m=>window.webkit.messageHandlers.swipeSketchWalkthrough.postMessage(m);
        post({protocol:'swipesketch.walkthrough.v1',type:'ready',lesson:'batch-r063',step:true,totalSteps:9,status:'ready',speed:1,title:'Bad'});
        </script>
        <iframe srcdoc="<script>window.webkit.messageHandlers.swipeSketchWalkthrough.postMessage({protocol:'swipesketch.walkthrough.v1',type:'ready',lesson:'batch-r063',step:0,totalSteps:9,status:'ready',speed:1,title:'Child'});</script>"></iframe>
        """
        let (coordinator, web, playback, _) = try player(html: html, timeout: .seconds(1))
        defer { coordinator.stop(); web.stopLoading() }
        // Let the iframe execute to exercise message validation independently of the production
        // navigation delegate, which already blocks child-frame loads.
        web.navigationDelegate = nil
        try await waitForPhase(.failed, playback)
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
    /// This response was exported through the real website route using a disposable content
    /// store and v5 activation. It is a test resource, not a bundled production lesson catalog.
    func reviewedV5() throws -> Data {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"canvas-2026-10-30-v5-catalog",withExtension:"json"))
        return try Data(contentsOf:url)
    }

    /// Help topics added after the reviewed v5 catalog was published.
    static let newerThanV5: Set<HelpTopic> = [.radialToolbar, .notes, .purchases]
    /// Topics the v5 catalog still maps that the app no longer has (its lookups ignore them).
    static let retiredSinceV5: Set<String> = ["moveShape"]

    func testReviewedV5CatalogMapsEveryCurrentHelpTopicAndTrustsEveryLesson() throws {
        let data=try reviewedV5(),checked=try WalkthroughCatalog.validated(data)
        let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let lessons=try XCTUnwrap(raw["lessons"] as? [[String:Any]]),topics=try XCTUnwrap(raw["topics"] as? [String:[String:Any]])
        XCTAssertEqual(checked.release,"canvas-2026-10-30-v5");XCTAssertEqual(lessons.count,217)
        XCTAssertEqual(HelpTopic.allCases.count-Self.newerThanV5.count+Self.retiredSinceV5.count,73)
        XCTAssertEqual(Set(topics.keys),Set(HelpTopic.allCases.filter { !Self.newerThanV5.contains($0) }.map(\.rawValue)).union(Self.retiredSinceV5))
        // Until the website maps them, these keep Text only (the card offers no Walkthrough).
        for topic in Self.newerThanV5 { XCTAssertTrue(checked.lessons(for:topic).isEmpty,topic.rawValue) }
        for topic in HelpTopic.allCases where !Self.newerThanV5.contains(topic) {
            let mapped=checked.lessons(for:topic),spec=try XCTUnwrap(topics[topic.rawValue])
            XCTAssertFalse(mapped.isEmpty,topic.rawValue)
            XCTAssertEqual(mapped.first?.id,spec["default"] as? String)
            let expected=try XCTUnwrap(spec["lessons"] as? [String])
            XCTAssertEqual(Set(mapped.map(\.id)),Set(expected));XCTAssertEqual(Set(mapped.map(\.id)).count,mapped.count)
        }
        // Validate the unassociated introductory/project lessons too, not only mapped ones.
        for lesson in lessons {
            let id=try XCTUnwrap(lesson["id"] as? String),embed=try XCTUnwrap(lesson["embed"] as? String),page=try XCTUnwrap(lesson["page"] as? String)
            let address=try XCTUnwrap(Walkthroughs.embedURL(embed,lesson:id,release:checked.release))
            XCTAssertEqual(Walkthroughs.lesson(in:address),id)
            XCTAssertTrue(Walkthroughs.isPlayerURL(try XCTUnwrap(URL(string:page,relativeTo:Walkthroughs.origin)?.absoluteURL),release:checked.release))
        }
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        attachment.name="Reviewed v5 public catalog.json";attachment.lifetime = .keepAlways;add(attachment)
    }

    func testReviewedV5RefreshCachesAndRestoresAllTopicsWithoutLiveNetwork() async throws {
        let directory=URL.temporaryDirectory.appendingPathComponent("v5-acceptance-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("catalog.json")
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ReviewedV5CatalogProtocol.self]
        let network=URLSession(configuration:config);defer { network.invalidateAndCancel() }
        let library=WalkthroughLibrary(cacheFile:file,session:network)
        XCTAssertNil(library.catalog)
        await library.refresh()?.value
        XCTAssertEqual(library.catalog?.release,"canvas-2026-10-30-v5")
        XCTAssertEqual(try Data(contentsOf:file),try reviewedV5())
        let relaunched=WalkthroughLibrary(cacheFile:file,session:network)
        XCTAssertEqual(relaunched.catalog,library.catalog)
        for topic in HelpTopic.allCases where !Self.newerThanV5.contains(topic) { XCTAssertFalse(relaunched.lessons(for:topic).isEmpty,topic.rawValue) }
    }

    func testDiscoveryFailuresKeepValidatedCacheAndUnavailableClearsIt() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        let original = try reviewedV5()
        for scenario in ["offline", "404", "incompatible", "unexpected-port", "unavailable", "new-release"] {
            try original.write(to: file)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReviewedV5CatalogProtocol.self]
            config.httpAdditionalHeaders = ["X-Walkthrough-Test-Response": scenario]
            let network = URLSession(configuration: config)
            defer { network.invalidateAndCancel() }
            let library = WalkthroughLibrary(cacheFile: file, session: network)
            let pinned = try XCTUnwrap(library.lessons(for: .extrude).first?.embed)
            await library.refresh()?.value
            if scenario == "unavailable" {
                XCTAssertNil(library.catalog)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            } else if scenario == "new-release" {
                XCTAssertEqual(library.catalog?.release, "canvas-2026-11-03-v1")
                XCTAssertTrue(pinned.path.contains("canvas-2026-10-30-v5"), "Previously selected URLs stay pinned")
                XCTAssertNotEqual(library.lessons(for: .extrude).first?.embed, pinned)
            } else {
                XCTAssertEqual(library.catalog?.release, "canvas-2026-10-30-v5", scenario)
                XCTAssertEqual(try Data(contentsOf: file), original, scenario)
            }
        }
    }

}


/// Serve the exact reviewed route response at the native client's normal HTTPS address, inside
/// this test URLSession only. This does not change host trust, production routing or activation.
private final class ReviewedV5CatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request:URLRequest) -> Bool { request.url == Walkthroughs.catalogURL }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let scenario = request.value(forHTTPHeaderField: "X-Walkthrough-Test-Response")
            if scenario == "offline" { throw URLError(.notConnectedToInternet) }
            let url=try XCTUnwrap(Bundle(for:WalkthroughTests.self).url(forResource:"canvas-2026-10-30-v5-catalog",withExtension:"json"))
            var data=try Data(contentsOf:url)
            if scenario == "incompatible" || scenario == "unavailable" {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                if scenario == "incompatible" { json["uiRevision"] = "canvas-menus-v99" }
                else { json["available"] = false }
                data = try JSONSerialization.data(withJSONObject: json)
            }
            if scenario == "new-release" {
                data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "canvas-2026-10-30-v5", with: "canvas-2026-11-03-v1").utf8)
            }
            let responseURL = scenario == "unexpected-port"
                ? URL(string: "https://swipesketch.com:8443/walkthroughs/catalog.json?ui=canvas-menus-v3")! : try XCTUnwrap(request.url)
            let response=try XCTUnwrap(HTTPURLResponse(url:responseURL,statusCode:scenario == "404" ? 404 : 200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"]))
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

@MainActor private final class TestPlayerMessageHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: WalkthroughPlayer.Coordinator?
    init(_ coordinator: WalkthroughPlayer.Coordinator) { self.coordinator = coordinator }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.received(message)
    }
}

@MainActor private final class SimulatedPlayerWebView: WKWebView {
    static let html = """
    <script>
    const commands=[];
    const post=m=>window.webkit.messageHandlers.swipeSketchWalkthrough.postMessage(m);
    const state={protocol:'swipesketch.walkthrough.v1',type:'ready',lesson:new URL(location.href).searchParams.get('lesson'),step:0,totalSteps:9,status:'ready',speed:1,title:'Start'};
    window.SwipeSketchWalkthrough={command:message=>{commands.push(message);return true;}};
    post(state);
    </script>
    """
    var html = SimulatedPlayerWebView.html
    var requests: [URLRequest] = []
    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html"])!
        return loadSimulatedRequest(request, response: response, responseData: Data(html.utf8))
    }
}
