import XCTest
import SwiftUI
@testable import SwipeAndSketch

@MainActor final class ProjectDocumentTests: XCTestCase {
    func open(_ document: ProjectDocument) async -> Bool {
        await withCheckedContinuation { continuation in document.open { continuation.resume(returning: $0) } }
    }
    func close(_ document: ProjectDocument) async -> Bool {
        await withCheckedContinuation { continuation in document.close { continuation.resume(returning: $0) } }
    }
    func save(_ session: ModelingSession) async -> Bool {
        await withCheckedContinuation { continuation in session.save { continuation.resume(returning: $0) } }
    }

    func testNativeDocumentSavesEditsAndReopensExactGeometry() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Bracket.swipesketch")
        let circle = SketchShape(kind: .circle, plane: .front, start: .init(x: 3.123456789, y: -8), end: .init(x: 15.987654321, y: -8))
        let profile = Geometry.profiles(in: [circle], on: .front)[0]
        let project = Project(workspace: Workspace(shapes: [circle], bodies: [SolidBody(profile: profile, depth: -12.3456789)]))
        try ProjectCodec.create(project, at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        XCTAssertEqual(session.projectName, "Bracket")
        session.addShape(.init(kind: .line, plane: .right, start: .zero, end: .init(x: 10, y: 20)))
        let edited = session.workspace
        let saved = await save(session); XCTAssertTrue(saved)
        let closed = await close(document); XCTAssertTrue(closed)
        let reopened = ProjectDocument(fileURL: url)
        let reopenedSuccessfully = await open(reopened); XCTAssertTrue(reopenedSuccessfully)
        XCTAssertEqual(reopened.project.id, project.id)
        XCTAssertEqual(reopened.project.workspace, edited)
        let reloadedSession = ModelingSession(document: reopened)
        XCTAssertFalse(reloadedSession.history.canUndo)
        XCTAssertEqual(reloadedSession.workspace.bodies[0].profile.circle, profile.circle)
        let closedAgain = await close(reopened); XCTAssertTrue(closedAgain)
    }

    func testNewAndSaveAsFilesKeepOriginalIndependentAndNewHistoryEmpty() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("Original.swipesketch")
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 30, y: 20))
        let original = Project(workspace: Workspace(shapes: [rectangle]))
        try ProjectCodec.create(original, at: originalURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let newURL = directory.appendingPathComponent("New.swipesketch")
        try ProjectCodec.create(Project(), at: newURL)
        let newDocument = ProjectDocument(fileURL: newURL)
        let opened = await open(newDocument); XCTAssertTrue(opened)
        let newSession = ModelingSession(document: newDocument)
        XCTAssertTrue(newSession.workspace.shapes.isEmpty); XCTAssertTrue(newSession.workspace.bodies.isEmpty)
        XCTAssertFalse(newSession.history.canUndo); XCTAssertNil(newSession.selection)
        let closed = await close(newDocument); XCTAssertTrue(closed)
        let copyURL = directory.appendingPathComponent("Copy.swipesketch")
        try ProjectCodec.create(original.copyForNewFile(), at: copyURL)
        let copy = ProjectDocument(fileURL: copyURL)
        let copyOpened = await open(copy); XCTAssertTrue(copyOpened)
        let copySession = ModelingSession(document: copy)
        copySession.selection = .shape(rectangle.id)
        XCTAssertTrue(copySession.applyDimension(75, target: .shape(rectangle.id, .width)))
        let saved = await save(copySession); XCTAssertTrue(saved)
        let copyClosed = await close(copy); XCTAssertTrue(copyClosed)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertNotEqual(try ProjectCodec.decode(Data(contentsOf: copyURL)).id, original.id)
        XCTAssertEqual(try ProjectCodec.decode(Data(contentsOf: copyURL)).workspace.shapes[0].end.x, 75)
    }

    /// The document UI test's fixture: a 60 × 40 rectangle with its solid, plus a circle.
    func createFixture(in directory: URL) throws -> (URL, SketchShape) {
        let url = directory.appendingPathComponent("Fixture.swipesketch")
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        let circle = SketchShape(kind: .circle, plane: .front, start: .init(x: 80, y: 0), end: .init(x: 92.5, y: 0))
        let profile = Geometry.profiles(in: [rectangle], on: .top)[0]
        try ProjectCodec.create(Project(workspace: Workspace(shapes: [rectangle, circle], bodies: [SolidBody(profile: profile, depth: -12.5)])), at: url)
        return (url, rectangle)
    }
    func widthOnDisk(_ url: URL) throws -> Double {
        let shape = try ProjectCodec.decode(Data(contentsOf: url)).workspace.shapes[0]
        return abs(shape.end.x - shape.start.x)
    }

    func testKeypadEditThenSaveAndNewProjectWritesEditBeforeClosing() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, rectangle) = try createFixture(in: directory)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        session.selection = .shape(rectangle.id)
        // The same calls, in the same order, as keypad 75 ✓, Save, then New Project → Create.
        XCTAssertTrue(session.applyDimension(75, target: .shape(rectangle.id, .width)))
        XCTAssertEqual(session.status, "Saving…", "The keypad's autosave is still in flight")
        session.save()
        let savedBeforePicker = await save(session); XCTAssertTrue(savedBeforePicker)
        let savedBeforeClose = await save(session); XCTAssertTrue(savedBeforeClose)
        let closed = await close(document); XCTAssertTrue(closed)
        XCTAssertEqual(try widthOnDisk(url), 75)
    }

    func testClosingWhileTheEditsAutosaveIsInFlightStillWritesTheEdit() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, rectangle) = try createFixture(in: directory)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        session.selection = .shape(rectangle.id)
        XCTAssertTrue(session.applyDimension(75, target: .shape(rectangle.id, .width)))
        // No suspension point since the edit: its autosave cannot have completed before close is queued.
        XCTAssertEqual(session.status, "Saving…")
        let closed = await close(document); XCTAssertTrue(closed)
        XCTAssertEqual(try widthOnDisk(url), 75)
        let reopened = ProjectDocument(fileURL: url)
        let reopenedSuccessfully = await open(reopened); XCTAssertTrue(reopenedSuccessfully)
        XCTAssertEqual(ModelingSession(document: reopened).workspace.shapes[0].end.x, 45)
        let closedAgain = await close(reopened); XCTAssertTrue(closedAgain)
    }

    func testInboxFilesMoveIntoDocumentsUnderAnUnusedName() throws {
        let documents = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents.deletingLastPathComponent()) }
        XCTAssertTrue(HomeController.isInInbox(documents.appendingPathComponent("Inbox/Shared.swipesketch"), documents: documents))
        XCTAssertFalse(HomeController.isInInbox(documents.appendingPathComponent("Bracket.swipesketch"), documents: documents))
        XCTAssertFalse(HomeController.isInInbox(documents.appendingPathComponent("Inbox"), documents: documents))
        XCTAssertFalse(HomeController.isInInbox(documents.appendingPathComponent("Parts/Inbox/Bracket.swipesketch"), documents: documents))
        XCTAssertFalse(HomeController.isInInbox(URL(fileURLWithPath: documents.path + "Copy/Inbox/Bracket.swipesketch"), documents: documents))
        XCTAssertEqual(HomeController.unusedURL(for: "Bracket.swipesketch", in: documents).lastPathComponent, "Bracket.swipesketch")
        try Data().write(to: documents.appendingPathComponent("Bracket.swipesketch"))
        try Data().write(to: documents.appendingPathComponent("Bracket 2.swipesketch"))
        XCTAssertEqual(HomeController.unusedURL(for: "Bracket.swipesketch", in: documents).lastPathComponent, "Bracket 3.swipesketch")
    }

    func testRecentProjectsListOpenedAndLocalProjectsNewestFirst() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let documents = root.appendingPathComponent("Documents"), elsewhere = root.appendingPathComponent("Elsewhere")
        for folder in [documents.appendingPathComponent("Inbox"), documents.appendingPathComponent("Parts"), elsewhere] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentProjectsTests-\(UUID().uuidString)"))
        let local = documents.appendingPathComponent("Parts/Bracket.swipesketch")
        try ProjectCodec.create(Project(), at: local)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: local.path)
        try ProjectCodec.create(Project(), at: documents.appendingPathComponent("Inbox/Shared.swipesketch"))
        let opened = elsewhere.appendingPathComponent("Lid.swipesketch")
        var project = Project(workspace: Workspace(bodies: [SolidBody(profile: Geometry.profiles(in: [SketchShape(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 10, y: 10))], on: .top)[0], depth: 5)]))
        project.preview = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        try ProjectCodec.create(project, at: opened)

        let recents = RecentProjects(defaults: defaults, documents: documents, cache: root.appendingPathComponent("Pictures"))
        recents.record(opened, project: project)
        try await waitUntil { recents.projects.count == 2 }
        XCTAssertEqual(recents.projects.map(\.name), ["Lid", "Bracket"], "Newest first; the Inbox is left out")
        XCTAssertEqual(recents.projects[0].solids, 1)
        XCTAssertEqual(recents.projects[0].place, .elsewhere)
        XCTAssertEqual(recents.projects[1].place, .iPad)
        XCTAssertNil(recents.projects[1].solids, "Not opened here yet")
        XCTAssertNotNil(recents.pictures[recents.projects[0].id])

        // The list survives a relaunch; a removed local project stays off until it is opened again.
        let again = RecentProjects(defaults: defaults, documents: documents, cache: root.appendingPathComponent("Pictures"))
        again.refresh()
        try await waitUntil { again.projects.count == 2 && again.pictures[again.projects[0].id] != nil }
        again.remove(again.projects[1])
        again.refresh()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(again.projects.map(\.name), ["Lid"])
        again.record(local, project: Project())
        try await waitUntil { again.projects.count == 2 }
        XCTAssertEqual(again.projects.map(\.name), ["Bracket", "Lid"])

        // A deleted file drops out.
        try FileManager.default.removeItem(at: local)
        again.refresh()
        try await waitUntil { again.projects.map(\.name) == ["Lid"] }
    }

    func testRecentProjectsFollowMovedFilesAndDropDeletedOnes() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let documents = root.appendingPathComponent("Documents"), elsewhere = root.appendingPathComponent("Elsewhere")
        let cloud = root.appendingPathComponent("Mobile Documents/com~apple~CloudDocs")
        for folder in [documents, elsewhere.appendingPathComponent("Archive"), cloud] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentProjectsTests-\(UUID().uuidString)"))
        let local = documents.appendingPathComponent("Bracket.swipesketch")
        let lid = elsewhere.appendingPathComponent("Lid.swipesketch")
        let hinge = cloud.appendingPathComponent("Hinge.swipesketch")
        let clip = cloud.appendingPathComponent("Clip.swipesketch")
        var project = Project()
        project.preview = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        for url in [local, lid, hinge, clip] { try ProjectCodec.create(project, at: url) }
        let recents = RecentProjects(defaults: defaults, documents: documents, cache: root.appendingPathComponent("Pictures"))
        for url in [local, lid, hinge, clip] { recents.record(url, project: project) }
        try await waitUntil { recents.projects.count == 4 }

        // Files moves a deleted project into Recently Deleted (a .Trash folder), where the bookmark still finds it.
        let trash = documents.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: local, to: trash.appendingPathComponent(local.lastPathComponent))
        XCTAssertTrue(RecentProjects.isTrashed(trash.appendingPathComponent(local.lastPathComponent)))
        // A moved and renamed project stays, at its new place and name, with its picture.
        let renamed = elsewhere.appendingPathComponent("Archive/Lid v2.swipesketch")
        try FileManager.default.moveItem(at: lid, to: renamed)
        // An iCloud file evicted to a placeholder stays; one deleted outright drops out.
        try FileManager.default.removeItem(at: hinge)
        try Data().write(to: cloud.appendingPathComponent(".Hinge.swipesketch.icloud"))
        try FileManager.default.removeItem(at: clip)
        recents.refresh()
        try await waitUntil { recents.projects.count == 2 }
        XCTAssertEqual(Set(recents.projects.map(\.name)), ["Lid v2", "Hinge"])
        let moved = try XCTUnwrap(recents.projects.first { $0.name == "Lid v2" })
        XCTAssertEqual(moved.id, RecentProjects.key(renamed))
        XCTAssertEqual(moved.place, .elsewhere)
        let placeholder = try XCTUnwrap(recents.projects.first { $0.name == "Hinge" })
        XCTAssertEqual(placeholder.place, .iCloud)
        XCTAssertEqual(placeholder.id, RecentProjects.key(hinge))
        try await waitUntil { recents.pictures[moved.id] != nil }

        // The stored entries changed too: a relaunch finds the same list without the deleted ones.
        let again = RecentProjects(defaults: defaults, documents: documents, cache: root.appendingPathComponent("Pictures"))
        again.refresh()
        try await waitUntil { Set(again.projects.map(\.name)) == ["Lid v2", "Hinge"] && again.pictures[moved.id] != nil }
        // Once the placeholder is gone too, the iCloud project was deleted.
        try FileManager.default.removeItem(at: cloud.appendingPathComponent(".Hinge.swipesketch.icloud"))
        again.refresh()
        try await waitUntil { again.projects.map(\.name) == ["Lid v2"] }
    }

    func testRecentProjectsRefreshWhenDocumentsChange() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentProjectsTests-\(UUID().uuidString)"))
        let local = documents.appendingPathComponent("Bracket.swipesketch")
        try ProjectCodec.create(Project(), at: local)
        let recents = RecentProjects(defaults: defaults, documents: documents, cache: root.appendingPathComponent("Pictures"))
        recents.record(local, project: Project())
        try await waitUntil { recents.projects.count == 1 }
        recents.watchDocuments()
        // A coordinated delete, as Files makes, refreshes Home without being asked.
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: local, options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertNil(coordinationError)
        try await waitUntil { recents.projects.isEmpty }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition())
    }

    func testUnsupportedDocumentOpenFailsWithoutChangingBytes() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Future.swipesketch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectCodec.encode(Project())) as? [String: Any])
        json["schemaVersion"] = 999
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document)
        XCTAssertFalse(opened)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReloadUpdatesSessionAndRejectsInvalidReplacementWithoutLosingModel() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Reload.swipesketch")
        let original = Project()
        try ProjectCodec.create(original, at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        var incoming = original
        incoming.update(Workspace(shapes: [.init(kind: .circle, plane: .right, start: .zero, end: .init(x: 20, y: 0))]))
        let reloaded = expectation(description: "Document reload applied on main actor")
        reloaded.assertForOverFulfill = false
        let apply = document.onReload
        document.onReload = { project in apply?(project); reloaded.fulfill() }
        // UIDocument calls this override for contents supplied by a coordinated read.
        try document.load(fromContents: ProjectCodec.encode(incoming), ofType: Project.formatIdentifier)
        await fulfillment(of: [reloaded], timeout: 2)
        XCTAssertEqual(session.workspace, incoming.workspace)
        XCTAssertFalse(session.history.canUndo)
        let failed = expectation(description: "Failed reload reported on main actor")
        let report = document.onReloadFailure
        document.onReloadFailure = { report?(); failed.fulfill() }
        do {
            try document.load(fromContents: Data("broken".utf8), ofType: Project.formatIdentifier)
            XCTFail("Invalid contents must be rejected")
        } catch { }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(document.project, incoming)
        XCTAssertEqual(session.workspace, incoming.workspace)
        // The file on disk is not what the app has open: editing stops so it is never saved over.
        XCTAssertTrue(document.isReadOnly)
        XCTAssertTrue(session.isReadOnly)
        XCTAssertTrue(session.isEditingBlocked)
        try document.load(fromContents: ProjectCodec.encode(incoming), ofType: Project.formatIdentifier)
        XCTAssertFalse(document.isReadOnly, "a readable file lifts the block")
        let closed = await close(document); XCTAssertTrue(closed)
    }

    /// About carries the version and the Open CASCADE notice and licenses.
    func testAboutShowsTheVersionAndOpenCascadeLicenses() throws {
        XCTAssertTrue(Licenses.lgpl21.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(Licenses.lgpl21.contains("Version 2.1, February 1999"))
        XCTAssertTrue(Licenses.lgpl21.contains("END OF TERMS AND CONDITIONS"), "The whole license")
        XCTAssertTrue(Licenses.openCascadeException.hasPrefix("Open CASCADE exception (version 1.0)"))
        XCTAssertEqual(AboutView.repository?.absoluteString, "https://github.com/wwiens/SwipeAndSketch")
        XCTAssertEqual(AboutView.version, "Version 1.0 (1)")

        let host = UIHostingController(rootView: AboutView {})
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "About Swipe & Sketch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
