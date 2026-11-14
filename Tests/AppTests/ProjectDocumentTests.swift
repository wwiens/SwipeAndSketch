import XCTest
import SwiftUI
import SceneKit
import Observation
@testable import SwipeAndSketch

@MainActor final class ProjectDocumentTests: XCTestCase {
    func testLinkedNotesHighlightSwitchSaveAndSurviveDeletedObjects() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Linked.swipesketch")
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 30, y: 20))
        let body = SolidBody(profile: Geometry.profiles(in: [shape], on: .top)[0], depth: 10)
        let original = Project(workspace: Workspace(shapes: [shape], bodies: [body]))
        try ProjectCodec.create(original, at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        let sketch = try XCTUnwrap(session.workspace.sketches.first)
        XCTAssertTrue(session.openObjectNote(for: .body(body.id)))
        XCTAssertEqual(session.selection, .body(body.id))
        XCTAssertEqual(session.workspace, original.workspace, "An empty notebook is only a draft")
        session.beginEditingNotes()
        let redrawn = changesWhatTheEditorReads(session) { for i in 1...100 { session.updateNotes("Print flat \(i)") } }
        XCTAssertFalse(redrawn, "Linked text must preserve the fast typing path")
        session.closeNotes()
        let bodyNote = try XCTUnwrap(session.workspace.objectNotes.first)
        session.undo(); XCTAssertEqual(session.workspace, original.workspace, "The link and first text undo together")
        session.redo()
        XCTAssertTrue(session.openObjectNote(for: .sketch(sketch.id)))
        XCTAssertEqual(session.selection, .sketch(sketch.id))
        session.beginEditingNotes(); session.updateNotes("Clearance 0.3 mm")
        XCTAssertTrue(session.selectNote(nil), "Switching notebooks flushes pending linked text")
        XCTAssertEqual(session.workspace.objectNotes.count, 2)
        session.beginEditingNotes(); session.updateNotes("Project requirements")
        XCTAssertTrue(session.selectNote(bodyNote.id))
        XCTAssertEqual(session.workspace.notes, "Project requirements")
        XCTAssertEqual(session.selection, .body(body.id))
        XCTAssertTrue(session.noteMatchesSelection(bodyNote))
        session.rename(.body(body.id), to: "Bracket")
        XCTAssertEqual(session.workspace.name(for: bodyNote), "Bracket")
        session.deleteItem(.body(body.id))
        XCTAssertEqual(session.workspace.objectNotes.count, 2)
        XCTAssertTrue(session.selectNote(bodyNote.id))
        XCTAssertNil(session.selection)
        XCTAssertNil(session.workspace.name(for: try XCTUnwrap(session.activeObjectNote)))
        XCTAssertEqual(session.activeObjectNote?.objectName, "Bracket")
        XCTAssertEqual(session.notesText, "Print flat 100")
        session.undo()
        XCTAssertTrue(session.selectNote(bodyNote.id))
        XCTAssertEqual(session.selection, .body(body.id), "Undo restores the original target ID")
        session.deleteItem(.body(body.id))
        let saved = await save(session); XCTAssertTrue(saved)
        let closed = await close(document); XCTAssertTrue(closed)
        let restored = try ProjectCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(restored.workspace.notes, "Project requirements")
        XCTAssertEqual(restored.workspace.objectNotes.count, 2)
        XCTAssertNil(restored.workspace.name(for: restored.workspace.objectNotes[0]))
        XCTAssertEqual(restored.copyForNewFile().workspace.objectNotes, restored.workspace.objectNotes)
    }

    func testNativeFocusChangesDoNotSplitNotebookUndoGroup() throws {
        let session = ModelingSession(inMemory: true)
        let original = session.workspace
        session.beginEditingNotes(); session.updateNotes("First sentence"); session.save()
        session.endEditingNotes(finalize: false)
        session.beginEditingNotes(); session.updateNotes("First sentence. Second sentence."); session.closeNotes()
        session.undo(); XCTAssertEqual(session.workspace, original)
        session.redo()
        // If geometry changes while text is unfocused, later typing must not amend that geometry step.
        session.beginEditingNotes(); session.updateNotes("More notes"); session.endEditingNotes(finalize: false)
        session.addShape(.init(kind: .line, plane: .top, start: .zero, end: .init(x: 10, y: 0)))
        let afterModeling = session.workspace
        session.beginEditingNotes(); session.updateNotes("Later notes"); session.closeNotes()
        session.undo(); XCTAssertEqual(session.workspace, afterModeling)
    }

    /// Opening a note selects its object as its Model Tree row would: sketch mode ends, and a hidden
    /// object stays unselected.
    func testOpeningANoteEndsSketchModeAndLeavesHiddenObjectsUnselected() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 15)))
        let sketch = try XCTUnwrap(session.workspace.sketches.first), shape = try XCTUnwrap(session.workspace.shapes.first)
        session.enterSketch(of: shape.id)
        XCTAssertNotNil(session.sketchMode)
        XCTAssertTrue(session.openObjectNote(for: .sketch(sketch.id)))
        XCTAssertNil(session.sketchMode)
        XCTAssertEqual(session.selection, .sketch(sketch.id))
        session.beginEditingNotes(); session.updateNotes("Hinge side"); session.closeNotes()
        let note = try XCTUnwrap(session.workspace.objectNotes.first)
        session.toggleHidden(.sketch(sketch.id))
        XCTAssertTrue(session.workspace.isHidden(sketch: sketch.id))
        XCTAssertTrue(session.selectNote(note.id))
        XCTAssertNil(session.selection, "A hidden sketch is not selected")
    }

    /// Typing in a note after undo or redo starts a new step instead of amending another one.
    func testNotesTypedAfterUndoAndRedoKeepTheirOwnStep() throws {
        let session = ModelingSession(inMemory: true)
        session.beginEditingNotes(); session.updateNotes("First"); session.save()
        session.endEditingNotes(finalize: false)
        session.addShape(.init(kind: .line, plane: .top, start: .zero, end: .init(x: 10, y: 0)))
        session.undo(); session.redo()
        let withLine = session.workspace
        session.beginEditingNotes(); session.updateNotes("First, then more"); session.closeNotes()
        XCTAssertEqual(session.workspace.notes, "First, then more")
        session.undo()
        XCTAssertEqual(session.workspace, withLine, "The line stays; only the typing is undone")
    }

    func testEmptyLinkedDraftAndLinkedNoteDeletionDoNotDeleteGeometry() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 15)))
        let original = session.workspace
        let sketch = try XCTUnwrap(original.sketches.first)
        XCTAssertTrue(session.openObjectNote(for: .sketch(sketch.id)))
        session.closeNotes()
        XCTAssertEqual(session.workspace, original)
        XCTAssertNil(session.selectedNoteID)
        XCTAssertTrue(session.openObjectNote(for: .sketch(sketch.id)))
        session.beginEditingNotes(); session.updateNotes("A design decision"); session.closeNotes()
        let note = try XCTUnwrap(session.workspace.objectNotes.first)
        session.deleteObjectNote(note.id)
        XCTAssertTrue(session.workspace.objectNotes.isEmpty)
        XCTAssertEqual(session.workspace.shapes, original.shapes)
        session.undo()
        XCTAssertEqual(session.workspace.objectNotes.first, note)
    }

    func testNotesOnlyUpdatesOnADetailedModelAvoidGeometryValidation() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Detailed.swipesketch")
        let outline = (0..<1_024).map { i -> Point2 in
            let angle = Double(i) * 2 * .pi / 1_024
            return Point2(x: 50 * cos(angle), y: 50 * sin(angle))
        }
        let bodies = (0..<8).map { i in
            SolidBody(profile: SketchProfile(id: "profile-\(i)", plane: .top, sourceIDs: [], outline: outline), depth: Double(i + 1))
        }
        let original = Project(workspace: Workspace(bodies: bodies))
        try ProjectCodec.create(original, at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let clock = ContinuousClock()
        let started = clock.now
        for i in 0..<100 {
            let updated = try XCTUnwrap(document.project.workspace.replacingNotes("Print observation \(i)"))
            try document.updateWorkspace(updated)
        }
        print("100 notes-only updates on eight 1,024-vertex solids: \(started.duration(to: clock.now))")
        XCTAssertEqual(document.project.workspace.bodies, bodies)
        // A geometry change, even alongside a note, must still pass full validation.
        var invalid = document.project.workspace
        invalid.notes = "Changed geometry too"
        invalid.bodies[0].depth = .infinity
        XCTAssertThrowsError(try document.updateWorkspace(invalid))
        XCTAssertEqual(document.project.workspace.notes, "Print observation 99")
        let closed = await close(document); XCTAssertTrue(closed)
        XCTAssertEqual(try ProjectCodec.decode(Data(contentsOf: url)).workspace.notes, "Print observation 99")
    }

    /// Notes offers the selected object's notebook: a solid from any part of it, a sketch from
    /// anything drawn in it, and nothing while nothing is selected.
    func testNotesOfferTheSelectedSolidOrSketch() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 15)))
        session.beginExtrusion(); session.extrusionDepth = 10; session.confirmExtrusion()
        let body = try XCTUnwrap(session.workspace.bodies.first)
        let sketch = try XCTUnwrap(session.workspace.sketches.first)
        let shape = try XCTUnwrap(session.workspace.shapes.first)
        session.select(nil)
        XCTAssertNil(session.selectionNoteTarget)
        let face = try XCTUnwrap(session.faceSelection(bodyID: body.id, near: .init(10, 7, 10)))
        session.select(.face(face))
        XCTAssertEqual(session.selectionNoteTarget?.item, .body(body.id), "A face is part of its solid")
        XCTAssertEqual(session.selectionNoteTarget?.name, session.workspace.bodyNames[body.id])
        session.select(.shape(shape.id))
        XCTAssertEqual(session.selectionNoteTarget?.item, .sketch(sketch.id), "A shape is part of its sketch")
        session.select(.face(face))
        XCTAssertTrue(session.openObjectNote(for: try XCTUnwrap(session.selectionNoteTarget).item))
        XCTAssertEqual(session.activeObjectNote?.objectID, body.id)
        XCTAssertEqual(session.selection, .body(body.id), "Opening it highlights the whole solid")
        session.beginEditingNotes(); session.updateNotes("Print on its side"); session.closeNotes()
        XCTAssertEqual(session.note(for: .body(body.id))?.text, "Print on its side")
        XCTAssertEqual(session.workspace.notes, "", "The project's notes are untouched")
    }

    func testTypingNotesDoesNotPublishWorkspaceChangesPerCharacter() {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 15)))
        session.beginExtrusion(); session.extrusionDepth = 10; session.confirmExtrusion()
        let original = session.workspace
        session.beginEditingNotes()
        let redrawn = changesWhatTheEditorReads(session) { for count in 1...200 { session.updateNotes(String(repeating: "a", count: count)) } }
        XCTAssertFalse(redrawn, "Typing must not trigger canvas refresh, geometry validation, or save-status updates")
        XCTAssertEqual(session.workspace, original)
        XCTAssertEqual(session.notesText, String(repeating: "a", count: 200))
        XCTAssertTrue(changesWhatTheEditorReads(session) { session.endEditingNotes() }, "Ending the edit keeps the text, which the editor sees")
        XCTAssertEqual(session.workspace.notes, String(repeating: "a", count: 200))
        session.undo()
        XCTAssertEqual(session.workspace, original)
    }

    func testNotesAutosaveAfterPauseAndSubsequentTypingStaysOneUndoStep() async throws {
        let session = ModelingSession(inMemory: true)
        let original = session.workspace
        session.beginEditingNotes()
        session.updateNotes("First sentence")
        try await waitUntil { session.workspace.notes == "First sentence" }
        session.updateNotes("First sentence. Second sentence.")
        session.save()
        XCTAssertEqual(session.workspace.notes, "First sentence. Second sentence.")
        session.endEditingNotes()
        session.undo()
        XCTAssertEqual(session.workspace, original)
        // A canceled debounce must never resurrect text after undo.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(session.workspace, original)
    }

    func testNotesSaveWhileEditingAndUseOneUndoStep() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Notebook.swipesketch")
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 30, y: 20))
        let initial = Project(workspace: Workspace(shapes: [rectangle]))
        try ProjectCodec.create(initial, at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        session.beginEditingNotes()
        XCTAssertTrue(session.isEditingNotes)
        XCTAssertFalse(session.acceptsPencil, "Editing text cannot also draw geometry")
        session.updateNotes("Requirements")
        session.updateNotes("Requirements\n• Clearance: 0.3 mm\nhttps://example.com")
        let notes = session.notesText
        let saved = await save(session); XCTAssertTrue(saved)
        XCTAssertEqual(try ProjectCodec.decode(Data(contentsOf: url)).workspace.notes, notes,
                       "Save before Done already includes the current text")
        XCTAssertEqual(session.workspace.shapes, initial.workspace.shapes)
        session.endEditingNotes()
        XCTAssertTrue(session.acceptsPencil)
        session.undo()
        XCTAssertEqual(session.workspace, initial.workspace, "One undo reverses all typing")
        session.redo()
        XCTAssertEqual(session.workspace.notes, notes)
        session.beginEditingNotes(); session.updateNotes(notes + "\nPrint flat"); session.endEditingNotes()
        session.undo(); XCTAssertEqual(session.workspace.notes, notes, "A later edit has its own step")
        let savedAgain = await save(session); XCTAssertTrue(savedAgain)
        let closed = await close(document); XCTAssertTrue(closed)
        let reopened = ProjectDocument(fileURL: url)
        let didReopen = await open(reopened); XCTAssertTrue(didReopen)
        XCTAssertEqual(reopened.project.workspace.notes, notes)
        XCTAssertEqual(reopened.project.copyForNewFile().workspace.notes, notes)
        let closedAgain = await close(reopened); XCTAssertTrue(closedAgain)
    }

    func testNotesPreserveRenderedSolidAndPrintingMesh() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 15)))
        session.beginExtrusion(); session.extrusionDepth = 10; session.confirmExtrusion()
        let stl = try ModelExport.stl(session.workspace.bodies)
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.layoutIfNeeded(); controller.refresh()
        let node = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
        session.beginEditingNotes(); controller.refresh()
        session.updateNotes("Print flat; 0.3 mm clearance"); session.save()
        controller.refresh()
        let afterAutosave = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
        XCTAssertTrue(node === afterAutosave, "Autosaving text must not rebuild the SceneKit content tree")
        session.endEditingNotes(); controller.refresh()
        let afterClosing = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
        XCTAssertTrue(node === afterClosing, "Closing the notebook must not rebuild model content")
        XCTAssertEqual(try ModelExport.stl(session.workspace.bodies), stl)
    }

    func testNotesRespectOperationPreviews() {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 15)))
        session.beginExtrusion()
        XCTAssertTrue(session.isExtruding)
        session.beginEditingNotes(); session.updateNotes("Blocked")
        XCTAssertFalse(session.isEditingNotes); XCTAssertEqual(session.workspace.notes, "")
    }

    /// An edit the project file could not hold is refused, not kept on screen where every later
    /// save fails (November 8, 2026).
    func testAnEditTooLargeToSaveIsRefusedAndTheProjectKeepsSaving() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Large.swipesketch")
        func solid() -> SolidBody {
            let square = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -50, y: -50), end: .init(x: 50, y: 50))
            var profile = Geometry.profiles(in: [square], on: .top)[0]
            profile.holes = [ProfileHole(outline: (0..<2_048).map { i in
                let a = Double(i) / 2_048 * 2 * .pi
                return Point2(x: 10 * cos(a), y: 10 * sin(a))
            })]
            return SolidBody(profile: profile, depth: 5)
        }
        // 23 × 2048² ≈ 96.5 million of the 100 million polygon-check budget.
        let original = Project(workspace: Workspace(bodies: (0..<23).map { _ in solid() }))
        try ProjectCodec.create(original, at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await open(document); XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        let first = try XCTUnwrap(session.workspace.bodies.first?.id)
        session.duplicate(.body(first))
        XCTAssertEqual(session.workspace, original.workspace, "The copy would take the project over the budget")
        XCTAssertEqual(session.saveError, "That change was not made: it would make the project too large to save. Your project is as it was before.")
        XCTAssertFalse(session.history.canUndo)
        session.saveError = nil
        session.toggleHidden(.body(first))
        XCTAssertNil(session.saveError, "Edits that fit still save")
        XCTAssertTrue(session.workspace.isHidden(body: first))
        let closed = await withCheckedContinuation { continuation in document.close { continuation.resume(returning: $0) } }
        XCTAssertTrue(closed)
    }

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
        session.beginEditingNotes(); session.updateNotes("Blocked")
        XCTAssertFalse(session.isEditingNotes); XCTAssertEqual(session.workspace.notes, incoming.workspace.notes)
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
        // The version and build number change with each update; the form stays.
        XCTAssertNotNil(AboutView.version.wholeMatch(of: /Version 1\.\d+(\.\d+)? \(\d+\)/), AboutView.version)
        // App Review asks for the privacy policy inside the app as well as in the store.
        XCTAssertEqual(AboutView.privacy?.absoluteString, "https://swipesketch.com/privacy/")
        XCTAssertEqual(AboutView.support?.absoluteString, "https://swipesketch.com/support/")

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

    /// Whether `changes` changes anything the editor, the notebook, or the canvas reads (they redraw
    /// for exactly what they read, through Observation): the model and its preview, the undo history,
    /// the save status, the hint, the selection, and the notebook's own state.
    private func changesWhatTheEditorReads(_ session: ModelingSession, during changes: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var raised = false }
        let changed = Flag()
        withObservationTracking {
            _ = session.workspace; _ = session.displayWorkspace; _ = session.visibleWorkspace
            _ = session.history.canUndo; _ = session.history.canRedo
            _ = session.status; _ = session.saveError; _ = session.hint; _ = session.projectName
            _ = session.selection; _ = session.selectedItems; _ = session.isEditingBlocked; _ = session.canPaste
            _ = session.itemGroups
            _ = session.notesText; _ = session.isEditingNotes; _ = session.canEditNotes; _ = session.notesTextLimit
            _ = session.selectedNoteID; _ = session.activeObjectNote; _ = session.listedObjectNotes
        } onChange: {
            changed.raised = true
        }
        changes()
        return changed.raised
    }
}
