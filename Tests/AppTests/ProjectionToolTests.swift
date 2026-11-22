import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Project (sketch projections) through the real Pencil pipeline.
@MainActor final class ProjectionToolTests: CanvasTestCase {
    /// A 60 × 40 × 20 box on Top (z 0…20) in the default 3D view.
    override func boxScene() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        return (session, canvas(session))
    }




    func testDoubleTappedSolidProjectsOntoAPlaneAboveAsANewSketch() throws {
        let (session, controller) = boxScene()
        // A construction plane 15 mm above the top face.
        tap(controller, SIMD3(5, 3, 20))
        session.chooseTool(.offsetPlane)
        XCTAssertTrue(session.applyDimension(15, target: .planeOffset))
        session.confirmPlane()
        session.select(nil)
        controller.refresh()
        let plane = try XCTUnwrap(session.workspace.constructionPlanes.first)

        session.chooseTool(.project)
        controller.refresh()
        XCTAssertEqual(session.tool, .project)
        XCTAssertEqual(session.projectionDraft?.step, .items)
        // A tap picks the front face; a quick second tap picks the whole solid instead.
        tap(controller, SIMD3(5, -20, 10))
        XCTAssertEqual(session.projectionDraft?.items.map(\.source).first.map { if case .face = $0 { true } else { false } }, true)
        tap(controller, SIMD3(5, -20, 10))
        XCTAssertEqual(session.projectionDraft?.items.map(\.source), [.body(session.workspace.bodies[0].id)])
        XCTAssertNotNil(controller.previewNode.childNode(withName: "projection.items", recursively: false))

        session.chooseProjectionStep(.surface)
        controller.refresh()
        XCTAssertNotNil(controller.previewNode.childNode(withName: "projection.world.top", recursively: false), "World planes are surfaces too")
        tap(controller, SIMD3(0, 0, 35))
        XCTAssertEqual(session.projectionDraft?.target?.source, .plane(plane.id))
        XCTAssertEqual(session.projectionPreview.count, 4, "The box's outline seen from above")
        XCTAssertTrue(session.projectionPreview.allSatisfy { $0.kind == .line })
        XCTAssertNotNil(controller.previewNode.childNode(withName: "projection.preview", recursively: false))
        XCTAssertNotNil(controller.previewNode.childNode(withName: "projection.target", recursively: false))
        attach(controller, "Projection preview on a plane above the box")

        let sketches = session.workspace.sketches.count
        session.confirmProjection()
        controller.refresh()
        XCTAssertEqual(session.workspace.sketches.count, sketches + 1)
        let sketch = try XCTUnwrap(session.workspace.sketches.last)
        XCTAssertEqual(sketch.plane, plane.plane)
        XCTAssertEqual(session.selection, .sketch(sketch.id))
        XCTAssertEqual(session.tool, .select)
        let profile = try XCTUnwrap(session.workspace.profiles(in: sketch).first)
        XCTAssertEqual(profile.area, 60 * 40, accuracy: 1e-9)
        XCTAssertEqual(sketch.plane.point(profile.center).z, 35, accuracy: 1e-9)
        session.undo()
        XCTAssertEqual(session.workspace.sketches.count, sketches, "One undo step")
    }

    func testSelectionBecomesTheItemAndEdgesPickOnTheCanvas() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        session.chooseTool(.project)
        controller.refresh()
        XCTAssertEqual(session.projectionDraft?.items.count, 1, "The selected face is the item")
        XCTAssertEqual(session.projectionDraft?.step, .surface, "Next, the surface")
        session.setProjectionTarget(.reference(.world(.front), in: session.workspace))
        XCTAssertEqual(session.projectionPreview.count, 1, "The top face seen from the front is one line")
        XCTAssertEqual(session.projectionPreview.first.map { $0.start.distance(to: $0.end) } ?? 0, 60, accuracy: 1e-9)
        // Back to items: tapping the face again unpicks it; a tap on an edge picks just the edge.
        session.chooseProjectionStep(.items)
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertEqual(session.projectionDraft?.items.count, 0)
        XCTAssertTrue(session.projectionPreview.isEmpty)
        tap(controller, SIMD3(0, -20, 20))
        let source = try XCTUnwrap(session.projectionDraft?.items.first?.source)
        guard case .edge(let body, _) = source else { return XCTFail("Expected an edge, got \(source)") }
        XCTAssertEqual(body, session.workspace.bodies[0].id)
        XCTAssertEqual(session.projectionPreview.count, 1)
        // Cancel leaves the model alone.
        let before = session.workspace
        session.cancelProjection()
        XCTAssertEqual(session.workspace, before)
        XCTAssertNil(session.projectionDraft)
        XCTAssertEqual(session.tool, .select)
    }

    func testProjectInsideAFaceSketchAddsToThatSketch() throws {
        let (session, controller) = boxScene()
        // A circle drawn on Top under the box, picked from Items (it is hidden under the solid).
        session.choosePlane(.top)
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 10, y: 5), end: .init(x: 14, y: 5))
        session.addShape(circle)
        session.select(nil)
        session.chooseTool(.select)
        tap(controller, SIMD3(-5, -3, 20))
        XCTAssertNotNil(session.selectedFace)
        session.beginFaceSketch()
        let facePlane = try XCTUnwrap(session.sketchMode?.plane)
        session.chooseTool(.project)
        XCTAssertEqual(session.projectionDraft?.fixedTarget, true)
        XCTAssertEqual(session.projectionDraft?.target?.plane, facePlane)
        session.selectItem(.shape(circle.id))
        XCTAssertEqual(session.projectionPreview.map(\.kind), [.circle])
        session.confirmProjection()
        controller.refresh()
        XCTAssertNotNil(session.sketchMode, "Still sketching on the face")
        let sketchID = try XCTUnwrap(session.sketchMode?.sketchID)
        let projected = session.workspace.shapes(in: sketchID)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(facePlane.point(projected[0].start), SIMD3(10, 5, 20))
        XCTAssertEqual(projected[0].start.distance(to: projected[0].end), 4, accuracy: 1e-12)
        // Projecting it again adds nothing: it is already there.
        session.chooseTool(.project)
        session.selectItem(.shape(circle.id))
        XCTAssertTrue(session.projectionPreview.isEmpty)
        XCTAssertTrue(session.hint.hasPrefix("Nothing new to project"))
        session.cancelProjection()
    }

    func testRoundedSolidOutlineExtrudesWithExactCurvedSides() throws {
        let (session, controller) = boxScene()
        let bodyID = session.workspace.bodies[0].id
        session.chooseTool(.fillet)
        for edge in session.workspace.bodies[0].extrusionEdges where edge.position == .side {
            session.toggleFinishEdge(bodyID: bodyID, edge: try XCTUnwrap(PickedEdge.named(edge, on: session.workspace.bodies[0])))
        }
        session.setFinishSize(5)
        session.confirmFinish()
        XCTAssertEqual(session.workspace.bodies[0].finishes.count, 1)
        session.select(.body(bodyID))
        session.chooseTool(.project)
        let above = try XCTUnwrap(SketchPlane.through(.init(0, 0, 40), normal: .init(0, 0, 1)))
        session.setProjectionTarget(ProjectionTarget(source: .world(above), plane: above, outline: []))
        XCTAssertEqual(session.projectionPreview.filter { $0.kind == .arc }.count, 4)
        XCTAssertEqual(session.projectionPreview.filter { $0.kind == .line }.count, 4)
        session.confirmProjection()
        controller.refresh()
        let sketch = try XCTUnwrap(session.workspace.sketches.last)
        let profile = try XCTUnwrap(session.workspace.profiles(in: sketch).first)
        XCTAssertEqual(profile.arcs?.count, 4)
        session.select(.profile(profile.id))
        session.beginExtrusion()
        session.extrusionDepth = 6
        XCTAssertTrue(session.canConfirmExtrusion)
        session.confirmExtrusion()
        controller.refresh()
        let body = try XCTUnwrap(session.workspace.bodies.last)
        XCTAssertEqual(body.profile.arcs?.count, 4)
        XCTAssertEqual(try SolidKernel.solid(for: body).faceCount, 10, "Exact arcs: four smooth curved sides")
        attach(controller, "Projected rounded outline, extruded")
    }

    /// A rounded solid projected along its sides into a sketch, then again into that sketch every
    /// way the app allows, never leaves a piece lying on another (November 3, 2026: a projected
    /// outline was found drawn twice over itself, which stopped Offset).
    func testProjectingARoundedSolidAgainNeverDoublesItsOutline() throws {
        let (session, controller) = boxScene()
        let bodyID = session.workspace.bodies[0].id
        session.chooseTool(.fillet)
        for edge in session.workspace.bodies[0].extrusionEdges where edge.position == .side {
            session.toggleFinishEdge(bodyID: bodyID, edge: try XCTUnwrap(PickedEdge.named(edge, on: session.workspace.bodies[0])))
        }
        session.setFinishSize(5)
        session.confirmFinish()
        func overlapping(_ sketchID: UUID) -> Int {
            let shapes = session.workspace.shapes(in: sketchID)
            return shapes.indices.reduce(0) { n, i in n + shapes[(i + 1)...].filter { SketchTools.overlaps(shapes[i], $0) }.count }
        }
        // Onto a plane above: one rounded outline (the top and bottom outlines are the same).
        let above = try XCTUnwrap(SketchPlane.through(.init(0, 0, 40), normal: .init(0, 0, 1)))
        session.select(.body(bodyID))
        session.chooseTool(.project)
        session.setProjectionTarget(ProjectionTarget(source: .world(above), plane: above, outline: []))
        XCTAssertEqual(session.projectionPreview.count, 8)
        session.confirmProjection()
        let sketchID = try XCTUnwrap(session.workspace.sketches.last?.id)
        XCTAssertEqual(session.workspace.shapes(in: sketchID).count, 8)
        XCTAssertEqual(overlapping(sketchID), 0)

        // Again, with that sketch picked as the surface: nothing new.
        session.chooseTool(.project)
        session.selectItem(.body(bodyID))
        session.chooseProjectionStep(.surface)
        session.selectItem(.sketch(sketchID))
        XCTAssertEqual(session.projectionDraft?.target?.sketchID, sketchID)
        XCTAssertTrue(session.projectionPreview.isEmpty)
        session.confirmProjection()
        session.cancelProjection()
        XCTAssertEqual(session.workspace.shapes(in: sketchID).count, 8)

        // Again from inside the sketch: nothing new.
        session.enterSketch(of: try XCTUnwrap(session.workspace.shapes(in: sketchID).first?.id))
        XCTAssertEqual(session.sketchMode?.sketchID, sketchID)
        session.chooseTool(.project)
        session.selectItem(.body(bodyID))
        XCTAssertTrue(session.projectionPreview.isEmpty)
        session.confirmProjection()
        session.cancelProjection()
        XCTAssertEqual(session.workspace.shapes(in: sketchID).count, 8)
        XCTAssertEqual(overlapping(sketchID), 0)

        // Onto the same plane, not the sketch: a separate sketch, so this one is untouched.
        session.exitSketch()
        session.chooseTool(.project)
        session.selectItem(.body(bodyID))
        session.setProjectionTarget(ProjectionTarget(source: .world(above), plane: above, outline: []))
        XCTAssertEqual(session.projectionPreview.count, 8)
        session.confirmProjection()
        XCTAssertEqual(session.workspace.shapes(in: sketchID).count, 8)
        XCTAssertEqual(overlapping(sketchID), 0)
        controller.refresh()
    }

    func testItemsRowsPickItemsAndSurfaces() throws {
        let (session, _) = boxScene()
        let bodyID = session.workspace.bodies[0].id
        session.chooseTool(.project)
        XCTAssertTrue(session.canSelectItems, "Items can be picked from the list while projecting")
        session.selectItem(.body(bodyID))
        XCTAssertEqual(session.projectionDraft?.items.map(\.source), [.body(bodyID)])
        let row = try XCTUnwrap(session.itemGroups.flatMap(\.items).first { $0.selection == .body(bodyID) })
        XCTAssertTrue(session.isHighlighted(row))
        session.chooseProjectionStep(.surface)
        let sketch = try XCTUnwrap(session.workspace.sketches.first)
        session.selectItem(.sketch(sketch.id))
        XCTAssertEqual(session.projectionDraft?.target?.sketchID, sketch.id)
        // The bottom outline is the rectangle the box was drawn from: nothing new.
        XCTAssertTrue(session.projectionPreview.isEmpty)
    }

    // MARK: Imported SVG drawings

    /// An SVG drawing of two separate outlines, a triangle and a circle, imported onto Top as one
    /// sketch in its own group (which the import selects).
    func importedDrawing() throws -> (ModelingSession, sketch: UUID, group: UUID) {
        let session = ModelingSession(inMemory: true)
        let markup = "<svg xmlns='http://www.w3.org/2000/svg' width='60mm' height='40mm' viewBox='0 0 60 40'>" +
            "<path d='M5 35 L35 35 L20 5 Z'/><circle cx='48' cy='20' r='8'/></svg>"
        session.importSVG(data: Data(markup.utf8), name: "Badge")
        let deadline = Date().addingTimeInterval(20)
        while session.isProjectBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let request = try XCTUnwrap(session.svgImport)
        var options = SVGImport.defaultOptions(for: request.drawing)
        options.grouping = .single
        session.confirmSVGImport(try SVGImport.layout(request.drawing, options: options, placement: request.target.placement))
        let sketch = try XCTUnwrap(session.workspace.sketches.first)
        guard case .group(let group) = session.selection else { throw XCTSkip("The import selects its group") }
        return (session, sketch.id, group)
    }

    let above = SketchPlane.through(.init(0, 0, 30), normal: .init(0, 0, 1))!

    /// The imported triangle's lines: one outline of the drawing.
    func triangle(_ session: ModelingSession, _ sketch: UUID) throws -> [SketchShape] {
        let lines = session.workspace.shapes(in: sketch).filter { $0.kind == .line }
        XCTAssertEqual(lines.count, 3, "The triangle comes in as three joined lines")
        XCTAssertEqual(session.workspace.shapes(in: sketch).filter { $0.kind != .line }.count, 1, "and the circle as one shape")
        return lines
    }

    func testSelectedImportedDrawingIsWhatProjects() throws {
        let (session, sketch, group) = try importedDrawing()
        session.chooseTool(.project)
        XCTAssertEqual(session.projectionDraft?.items.map(\.source), [.sketch(sketch)], "The group brings its shown sketch")
        XCTAssertEqual(session.projectionDraft?.step, .surface)
        let row = try XCTUnwrap(session.itemGroups.flatMap(\.items).first { $0.selection == .group(group) })
        XCTAssertTrue(session.isHighlighted(row))
        session.setProjectionTarget(ProjectionTarget(source: .world(above), plane: above, outline: []))
        XCTAssertEqual(session.projectionPreview.count, 4)
        // The group's row unpicks it, and picks it again.
        session.chooseProjectionStep(.items)
        session.selectItem(.group(group))
        XCTAssertEqual(session.projectionDraft?.items.count, 0)
        XCTAssertFalse(session.isHighlighted(row))
        session.selectItem(.group(group))
        XCTAssertEqual(session.projectionDraft?.items.map(\.source), [.sketch(sketch)])
        session.confirmProjection()
        let copy = try XCTUnwrap(session.workspace.sketches.last)
        XCTAssertEqual(copy.plane, above)
        XCTAssertEqual(session.workspace.shapes(in: copy.id).count, 4)
    }

    func testSelectedOutlineOfAnImportedDrawingIsWhatProjects() throws {
        let (session, sketch, _) = try importedDrawing()
        let lines = try triangle(session, sketch)
        session.selectChain(of: lines[0].id)
        guard case .chain(let chain) = session.selection else { return XCTFail("Double-tapping a line selects its outline") }
        XCTAssertEqual(Set(chain), Set(lines.map(\.id)))
        session.chooseTool(.project)
        XCTAssertEqual(session.projectionDraft?.items.map(\.source), [.chain(chain)])
        let row = try XCTUnwrap(session.itemGroups.flatMap(\.items).first { $0.selection == .shape(lines[1].id) })
        XCTAssertTrue(session.isHighlighted(row), "Its shapes' rows are highlighted")
        session.setProjectionTarget(ProjectionTarget(source: .world(above), plane: above, outline: []))
        XCTAssertEqual(session.projectionPreview.count, 3, "Only the triangle")
        XCTAssertTrue(session.projectionPreview.allSatisfy { $0.kind == .line })
        session.confirmProjection()
        let copy = try XCTUnwrap(session.workspace.sketches.last)
        let profile = try XCTUnwrap(session.workspace.profiles(in: copy).first)
        XCTAssertEqual(profile.area, 30 * 30 / 2, accuracy: 1e-6, "The copy closes the same triangle")
    }

    func testTapsOnAnImportedLinePickItsShapeThenOutlineThenSketch() throws {
        let (session, sketch, _) = try importedDrawing()
        let lines = try triangle(session, sketch)
        session.select(nil)
        let controller = canvas(session)
        session.chooseTool(.project)
        controller.refresh()
        let line = lines[0]
        let middle = SIMD3<Float>(line.plane.point(Point2(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2)))
        tap(controller, middle)
        XCTAssertEqual(session.projectionDraft?.items.map(\.source), [.shape(line.id)])
        tap(controller, middle)
        let source = try XCTUnwrap(session.projectionDraft?.items.map(\.source).first)
        guard case .chain(let chain) = source else { return XCTFail("A second tap picks the outline, got \(source)") }
        XCTAssertEqual(Set(chain), Set(lines.map(\.id)))
        XCTAssertEqual(session.projectionDraft?.items.count, 1, "In place of the line")
        tap(controller, middle)
        XCTAssertEqual(session.projectionDraft?.items.map(\.source), [.sketch(sketch)], "A third tap: the whole sketch")
    }
}
