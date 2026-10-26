import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Draft (Modify ▴), and Loft, Sweep, and Rib (Create ▴), October 24, 2026.
@MainActor final class ShapeToolTests: CanvasTestCase {
    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    func testDraftLeansTheSidesFromTheBase() throws {
        let (session, controller) = boxScene()
        let body = session.workspace.bodies[0]
        session.chooseTool(.draft)
        XCTAssertEqual(session.helpTopic, .draft)
        XCTAssertTrue(session.hint.contains("flat face"), session.hint)
        session.pickDraftNeutral(bodyID: body.id, point: [0, 0, 0], outward: [0, 0, -1])
        session.toggleDraftFace(bodyID: body.id, point: [30, 0, 10])
        tap(controller, SIMD3(0, -20, 10))
        XCTAssertEqual(session.shapeToolDraft?.faces.count, 2, "A tap on the front face adds it")
        XCTAssertNotNil(session.shapeToolPreview)
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.draftAngle])
        XCTAssertTrue(session.applyDimension(5, target: .draftAngle))
        XCTAssertFalse(session.applyDimension(80, target: .draftAngle))
        attach(controller, "Draft on two sides")
        session.confirmShapeTool()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .draft)
        XCTAssertLessThan(try volume(session.workspace.bodies[0]), 60 * 40 * 20)
        XCTAssertEqual(session.selection, .body(body.id))
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0], body, "One undo step")
    }

    func testARibFillsTheCornerOfABracket() throws {
        let (session, _) = boxScene()
        // A wall standing on the box's left end: an L bracket.
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        session.choosePlane(top)
        session.addShape(.init(kind: .rectangle, plane: top, start: top.coordinates(of: [-30, -20, 20]), end: top.coordinates(of: [-26, 20, 20])))
        session.beginExtrusion()
        session.chooseExtrusionMode(.join)
        session.extrusionDepth = 30
        session.confirmExtrusion()
        session.chooseTool(.select)
        let bracket = session.workspace.bodies[0]
        // A line on Front across the corner, from the wall down to the top.
        session.choosePlane(.front)
        session.addShape(.init(kind: .line, plane: .front, start: SketchPlane.front.coordinates(of: [-26, 0, 44]), end: SketchPlane.front.coordinates(of: [10, 0, 20])))
        let line = try XCTUnwrap(session.workspace.shapes.last)
        session.chooseTool(.rib)
        session.pickRibLine(line)
        let preview = try XCTUnwrap(session.shapeToolPreview)
        XCTAssertEqual(try volume(preview.bodies[0]) - (try volume(bracket)), 0.5 * 36 * 24 * 3, accuracy: 2)
        XCTAssertTrue(session.applyDimension(4, target: .ribThickness))
        session.confirmShapeTool()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .rib)
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.rib?.thickness, 4)
    }

    func testLoftAndSweepMakeSolidsOfTheirOwn() throws {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session, camera: .reset)
        session.choosePlane(.top)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10)))
        let upper = try XCTUnwrap(SketchPlane.through(.init(0, 0, 25), normal: .init(0, 0, 1)))
        session.choosePlane(upper)
        session.addShape(.init(kind: .circle, plane: upper, start: .zero, end: .init(x: 7, y: 0)))
        let regions = session.workspace.profiles
        XCTAssertEqual(regions.count, 2)
        session.select(nil)
        session.chooseTool(.loft)
        XCTAssertEqual(session.helpTopic, .loft)
        session.pickShapeRegion(regions[0])
        session.pickShapeRegion(regions[1])
        XCTAssertNotNil(session.shapeToolPreview)
        // The Model Tree waits while the loft is being made: its eyes and rows would end the tool's picks.
        XCTAssertTrue(session.hasOperationInProgress)
        XCTAssertFalse(session.canToggleVisibility)
        XCTAssertFalse(session.canSelectItems)
        session.toggleHidden(.sketch(try XCTUnwrap(session.workspace.sketches.first).id))
        XCTAssertNotNil(session.shapeToolPreview, "The picks stay")
        // Renaming waits too: Done would bring back the name the preview was built with.
        XCTAssertFalse(session.canChangeRows)
        let before = session.workspace
        session.rename(.sketch(try XCTUnwrap(session.workspace.sketches.first).id), to: "Base")
        XCTAssertEqual(session.workspace, before)
        attach(controller, "Loft from a square to a circle")
        session.confirmShapeTool()
        let loft = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertTrue(loft.isImported)
        XCTAssertEqual(session.workspace.bodyNames[loft.id], "Loft")
        XCTAssertEqual(try SolidKernel.solid(for: loft).bounds.max.z, 25, accuracy: 1e-3)

        // A Ø6 circle on Front swept along a 30 mm line running back from its center.
        session.choosePlane(.front)
        session.addShape(.init(kind: .circle, plane: .front, start: .init(x: 40, y: 5), end: .init(x: 43, y: 5)))
        let section = try XCTUnwrap(session.workspace.profiles.first { $0.plane == .front })
        let level = try XCTUnwrap(SketchPlane.through(.init(0, 0, 5), normal: .init(0, 0, 1)))
        session.choosePlane(level)
        session.addShape(.init(kind: .line, plane: level, start: level.coordinates(of: [40, 0, 5]), end: level.coordinates(of: [40, 30, 5])))
        let path = try XCTUnwrap(session.workspace.shapes.last)
        session.select(nil)
        session.chooseTool(.sweep)
        session.pickShapeRegion(section)
        session.pickSweepPath(path)
        XCTAssertNil(session.shapeToolDraft?.error, session.shapeToolDraft?.error ?? "")
        session.confirmShapeTool()
        let sweep = try XCTUnwrap(session.workspace.bodies.last)
        XCTAssertEqual(session.workspace.bodyNames[sweep.id], "Sweep")
        XCTAssertEqual(try volume(sweep), .pi * 9 * 30, accuracy: 0.5)
    }
}
