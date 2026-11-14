import XCTest
import SceneKit
import UniformTypeIdentifiers
import simd
@testable import SwipeAndSketch

/// Import STEP through the session and the real Pencil pipeline.
@MainActor final class ImportToolTests: CanvasTestCase {
    /// A 40 × 30 × 20 mm block at x 10…50, y 0…30, with a ⌀10 hole (written by OCCT).
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/STEP/\(name).step")
    }

    func scene() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.layoutIfNeeded()
        controller.refresh()
        return (session, controller)
    }

    func importFile(_ session: ModelingSession, _ url: URL) {
        session.importSTEP(from: url)
        XCTAssertTrue(session.isProjectBusy, "Read off the main thread")
        let deadline = Date().addingTimeInterval(20)
        while session.isProjectBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(session.isProjectBusy)
    }


    func testImportedBlockIsASolidThatCanBeFilletedAndUndone() throws {
        let (session, controller) = scene()
        importFile(session, fixture("block"))
        controller.refresh()
        XCTAssertNil(session.saveError)
        XCTAssertEqual(session.workspace.bodies.count, 1)
        let body = session.workspace.bodies[0]
        XCTAssertTrue(body.isImported)
        XCTAssertEqual(session.selection, .body(body.id), "A single imported solid is selected")
        // In a group named after its file, as the solid is.
        XCTAssertEqual(session.itemGroups.first?.title, "Groups")
        XCTAssertEqual(session.itemGroups.first?.items.map(\.name), ["block", "block"], "Named after its file")
        XCTAssertEqual(session.itemGroups.first?.items.map(\.indent), [0, 1])
        XCTAssertEqual(body.group, session.workspace.groups.first?.id)
        XCTAssertTrue(session.status.hasPrefix("Imported 1 solid into the group block"), session.status)
        let widget = try XCTUnwrap(controller.transformWidget(), "Imported solids move and turn like any other")
        XCTAssertTrue(widget.canPivot)
        XCTAssertTrue(controller.dimensionAnnotations().isEmpty, "No extrusion depth to edit")
        attach(controller, "Imported STEP block")

        // Tap the top front edge (y 0, z 20) and round it.
        session.select(nil)
        controller.refresh()
        let point = controller.project(SIMD3(30, 0, 20))
        controller.pencilBegan(at: point)
        controller.pencilEnded(at: point, cancelled: false)
        controller.refresh()
        guard case .edge(let id, let edge) = session.selection else { return XCTFail("The tap picks the edge, got \(String(describing: session.selection))") }
        XCTAssertEqual(id, body.id)
        XCTAssertEqual(edge.name?.position, .imported)
        let before = try SolidKernel.solid(for: body).volume
        session.finishSelectedEdge(.fillet)
        session.setFinishSize(3)
        session.confirmFinish()
        XCTAssertEqual(session.workspace.bodies[0].finishes.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, before - (9 - .pi * 9 / 4) * 40, accuracy: 0.01)
        attach(controller, "Filleted imported edge")

        session.undo()
        session.undo()
        XCTAssertTrue(session.workspace.bodies.isEmpty)
        XCTAssertTrue(session.workspace.importedShapes.isEmpty, "Undo removes the import and its stored shape")
    }

    func testAFileThatIsNotSTEPReportsWhy() throws {
        let (session, _) = scene()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).step")
        try Data("not a step file".utf8).write(to: url)
        importFile(session, url)
        XCTAssertTrue(session.workspace.bodies.isEmpty)
        XCTAssertTrue(session.saveError?.hasPrefix("Import failed.") ?? false)
    }

    /// The picker offers declared (not made-up) types for every extension, so the files can be chosen.
    func testImportOffersADeclaredTypeForEveryExtension() {
        for (mesh, extensions) in [(false, ["step", "stp"]), (true, ["stl", "3mf"])] {
            let types = WorkspaceView.importTypes(mesh: mesh)
            for ext in extensions {
                XCTAssertTrue(types.contains { !$0.isDynamic && ($0.tags[.filenameExtension] ?? []).contains(ext) }, ext)
            }
        }
    }
}
