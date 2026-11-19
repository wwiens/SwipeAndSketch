import XCTest
import UniformTypeIdentifiers
import SceneKit
import simd
@testable import SwipeAndSketch

/// SVG import through the session: read, the SVG Import sheet's request, then one undo step.
@MainActor final class SVGImportToolTests: CanvasTestCase {
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SVG/\(name).svg")
    }

    /// Reads a drawing and waits for the SVG Import sheet's request.
    func read(_ session: ModelingSession, _ url: URL) throws -> SVGImportRequest {
        session.importSVG(from: url)
        XCTAssertTrue(session.isProjectBusy, "Read off the main thread")
        let deadline = Date().addingTimeInterval(20)
        while session.isProjectBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNil(session.saveError)
        return try XCTUnwrap(session.svgImport)
    }

    func testAColoredSignComesInAsColoredSolidsInOneStep() throws {
        let session = ModelingSession(inMemory: true)
        let request = try read(session, fixture("sign"))
        XCTAssertEqual(request.target.placement.plane, .top, "Nothing selected: the current plane")
        XCTAssertNil(request.target.face)
        var options = SVGImport.defaultOptions(for: request.drawing)
        XCTAssertEqual(options.grouping, .colors, "Several colors: a sketch each")
        options.solidHeight = 2
        let layout = try SVGImport.layout(request.drawing, options: options, placement: request.target.placement)
        session.confirmSVGImport(layout)
        XCTAssertNil(session.svgImport)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(session.workspace.bodies.count, 3)
        XCTAssertEqual(Set(session.workspace.bodies.compactMap(\.color)), [.red, .black])
        XCTAssertTrue(session.workspace.sketches.allSatisfy(\.isHidden))
        guard case .group(let group) = session.selection else { return XCTFail("The import's group is selected") }
        XCTAssertEqual(session.workspace.groupNames[group], "sign")
        XCTAssertTrue(session.status.hasPrefix("Imported sign: 3 solids and 3 sketches"), session.status)
        XCTAssertFalse(session.isEditingBlocked)

        session.undo()
        XCTAssertTrue(session.workspace.bodies.isEmpty, "One undo step")
        XCTAssertTrue(session.workspace.sketches.isEmpty)
    }

    func testOnASelectedFaceTheDrawingIsCenteredOnIt() throws {
        let (session, controller) = boxScene()
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: session.workspace.bodies[0].id, near: [5, 3, 20]))))
        controller.refresh()
        let request = try read(session, fixture("pixels"))
        let face = try XCTUnwrap(request.target.face)
        XCTAssertEqual(face.width, 60, accuracy: 1e-6)
        XCTAssertEqual(face.height, 40, accuracy: 1e-6)
        XCTAssertEqual(request.target.placement.plane.normalAxis.z, 1, accuracy: 1e-9)
        XCTAssertEqual(request.target.placement.plane.point(request.target.placement.center).z, 20, accuracy: 1e-9)
        let middle = request.target.placement.plane.point(request.target.placement.center)
        XCTAssertEqual(middle.x, 0, accuracy: 1e-6)
        XCTAssertEqual(middle.y, 0, accuracy: 1e-6)

        let layout = try SVGImport.layout(request.drawing, options: SVGImport.defaultOptions(for: request.drawing), placement: request.target.placement)
        session.confirmSVGImport(layout)
        let sketch = try XCTUnwrap(session.workspace.sketches.last)
        XCTAssertNotNil(sketch.faceEdges, "The face less the drawing is a region too")
        let circle = try XCTUnwrap(session.workspace.shapes(in: sketch.id).first)
        XCTAssertEqual(circle.kind, .circle)
        XCTAssertEqual(sketch.plane.point(circle.start).z, 20, accuracy: 1e-9)
        attach(controller, "SVG circle on the box's top face")
    }

    /// Dragging an imported drawing moves its sketches' nodes rather than rebuilding them: the
    /// regions and outlines of a thousand shapes were built again on every step (November 19, 2026).
    func testDraggingAnImportedDrawingKeepsItsSketchNodes() throws {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session, camera: .reset)
        // A plate with a line of lettering: several hundred lines and arcs.
        let drawing = try SVGImport.read(data: Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40" width="120mm" height="40mm">
              <rect x="1" y="1" width="118" height="38" rx="5" fill="#111827"/>
              <text x="60" y="26" text-anchor="middle" font-family="Helvetica" font-weight="bold" font-size="14" fill="#f59e0b">WORKSHOP BENCH</text>
            </svg>
            """.utf8), name: "plate")
        session.svgImport = SVGImportRequest(drawing: drawing, target: .init(placement: .init(plane: .top)))
        let layout = try SVGImport.layout(drawing, options: SVGImport.defaultOptions(for: drawing), placement: .init(plane: .top))
        session.confirmSVGImport(layout)
        XCTAssertGreaterThan(session.workspace.shapes.count, 300)
        controller.refresh()
        guard case .group = session.selection else { return XCTFail("The import is selected") }
        let shape = try XCTUnwrap(session.workspace.shapes.first)
        func node() -> SCNNode? { controller.sceneView.scene?.rootNode.childNode(withName: "shape|" + shape.id.uuidString, recursively: true) }
        let before = try XCTUnwrap(node())
        XCTAssertTrue(session.beginTransform(.move(0)))
        let start = Date()
        for step in 1...20 {
            session.updateTransform(Double(step))
            controller.refresh()
        }
        let perStep = Date().timeIntervalSince(start) / 20
        let after = try XCTUnwrap(node())
        XCTAssertTrue(after === before, "The outline's node is kept and moved, not built again")
        let moved = try XCTUnwrap(session.editPreview?.shapes.first { $0.id == shape.id })
        XCTAssertEqual(Double(after.simdWorldPosition.x), moved.plane.origin.x, accuracy: 1e-4, "Placed on the moved plane")
        session.finishTransform(cancelled: false)
        XCTAssertLessThan(perStep, 0.1, "A drag step of a large drawing stays quick")
        print("Drag step with \(session.workspace.shapes.count) shapes: \(String(format: "%.1f", perStep * 1000)) ms")

        // With Create Copy, each step's new copies take over the last step's nodes.
        controller.refresh()
        session.transformCopies = true
        XCTAssertTrue(session.beginTransform(.move(1)))
        session.updateTransform(5)
        controller.refresh()
        let copyStart = Date()
        for step in 2...11 {
            session.updateTransform(Double(step) * 5)
            controller.refresh()
        }
        let copyStep = Date().timeIntervalSince(copyStart) / 10
        session.finishTransform(cancelled: false)
        session.transformCopies = false
        XCTAssertEqual(session.workspace.shapes.count, 2 * layout.shapeCount, "The copy is added")
        XCTAssertLessThan(copyStep, 0.1, "A copying drag step stays quick")
        print("Copying drag step: \(String(format: "%.1f", copyStep * 1000)) ms")
    }

    func testCancellingLeavesTheProjectAsItWas() throws {
        let session = ModelingSession(inMemory: true)
        _ = try read(session, fixture("units"))
        XCTAssertTrue(session.status.hasPrefix("Choose how"))
        session.cancelSVGImport()
        XCTAssertNil(session.svgImport)
        XCTAssertTrue(session.workspace.sketches.isEmpty)
        XCTAssertFalse(session.history.canUndo)
        XCTAssertFalse(session.isEditingBlocked)
    }

    func testAFileThatIsNotSVGReportsWhy() throws {
        let session = ModelingSession(inMemory: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).svg")
        try Data("just some words".utf8).write(to: url)
        session.importSVG(from: url)
        let deadline = Date().addingTimeInterval(20)
        while session.isProjectBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNil(session.svgImport)
        XCTAssertTrue(session.saveError?.hasPrefix("Import failed.") ?? false)
        XCTAssertFalse(session.isEditingBlocked)
    }

    func testPastedMarkupImports() throws {
        let session = ModelingSession(inMemory: true)
        XCTAssertTrue(ImportDrop.isMarkup(Data("<?xml version='1.0'?>\n<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)))
        XCTAssertFalse(ImportDrop.isMarkup(Data("hello".utf8)))
        session.importSVG(data: Data("<svg xmlns='http://www.w3.org/2000/svg' width='10mm' height='10mm'><rect width='100%' height='100%'/></svg>".utf8), name: "Pasted Drawing")
        let deadline = Date().addingTimeInterval(20)
        while session.isProjectBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let request = try XCTUnwrap(session.svgImport)
        XCTAssertEqual(request.drawing.bounds.width, 10, accuracy: 1e-6)
    }

    /// The picker offers SVG, and a declared type for compressed SVG.
    func testImportOffersSVGTypes() {
        let types = WorkspaceView.svgTypes
        XCTAssertTrue(types.contains(.svg))
        XCTAssertTrue(types.contains { !$0.isDynamic && ($0.tags[.filenameExtension] ?? []).contains("svgz") })
        XCTAssertTrue(ImportDrop.extensions.isSuperset(of: ["svg", "svgz", "step", "stl", "3mf", "swipesketch"]))
    }
}
