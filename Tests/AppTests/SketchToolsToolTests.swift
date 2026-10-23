import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Arc, Slot, Fillet on any edge, sketch Fillet, Trim, Dimension, Measure, divided regions, and inch
/// units through the session, the Pencil pipeline, and the kernel.
@MainActor final class SketchToolsToolTests: CanvasTestCase {
    override func tearDown() {
        // Units are a device preference; leave them as the other tests expect.
        UserDefaults.standard.removeObject(forKey: "lengthUnit")
        super.tearDown()
    }



    /// A Pencil stroke through world points.
    func stroke(_ controller: CanvasController, _ points: [SIMD3<Float>]) {
        let screen = points.map(controller.project)
        controller.pencilBegan(at: screen[0])
        for point in screen.dropFirst() { controller.pencilMoved(to: point) }
        controller.pencilEnded(at: screen[screen.count - 1], cancelled: false)
        controller.refresh()
    }

    /// Sketching on Top, looking straight down.
    func topSketch() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session)
        session.pickPlaneForTesting(.top)
        controller.refresh()
        return (session, controller)
    }

    /// A 60 × 40 × 20 box on Top with a ⌀10 hole through it, in the default 3D view.
    func drilledBox() throws -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 10, y: 0), end: .init(x: 15, y: 0)))
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        session.cutThroughAll = true
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.first?.cuts.count, 1)
        session.select(nil)
        return (session, canvas(session, camera: .reset))
    }

    // MARK: Arc and Slot

    func testArcAndSlotStrokesDrawEditableShapes() throws {
        let (session, controller) = topSketch()
        session.chooseTool(.arc)
        stroke(controller, [SIMD3(0, 0, 0), SIMD3(4, 7, 0), SIMD3(10, 10, 0), SIMD3(16, 7, 0), SIMD3(20, 0, 0)])
        let arc = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(arc.kind, .arc)
        XCTAssertEqual(Set([arc.start, arc.end]), Set([Point2(x: 0, y: 0), Point2(x: 20, y: 0)]), "The ends snap")
        XCTAssertGreaterThan(arc.arcMiddle.y, 5, "It bulges toward the stroke")
        XCTAssertEqual(session.selection, .shape(arc.id))
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .shape(arc.id, .radius) })
        XCTAssertEqual(controller.sketchHandles(for: arc).map(\.0), [.start, .end, .mid])
        XCTAssertTrue(session.applyDimension(15, target: .shape(arc.id, .radius)))
        XCTAssertEqual(ShapeDimension.radius.value(of: try XCTUnwrap(session.workspace.shapes.last)), 15, accuracy: 1e-9)

        session.chooseTool(.slot)
        stroke(controller, [SIMD3(-10, 30, 0), SIMD3(0, 30, 0), SIMD3(10, 30, 0)])
        let slot = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(slot.kind, .slot)
        XCTAssertEqual(slot.width, 6)
        XCTAssertEqual(ShapeDimension.length.value(of: slot), 20, accuracy: 1e-9)
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.shape(slot.id, .length), .shape(slot.id, .width)])
        XCTAssertTrue(session.applyDimension(8, target: .shape(slot.id, .width)))
        XCTAssertEqual(session.slotWidth, 8, "The next slot is drawn as wide")
        let region = try XCTUnwrap(session.workspace.profiles.first { $0.sourceIDs == [slot.id] })
        XCTAssertEqual(region.area, 20 * 8 + .pi * 16, accuracy: 0.05)
        // A slot extrudes with exact round ends.
        session.select(.shape(slot.id))
        session.beginExtrusion()
        session.extrusionDepth = 5
        session.confirmExtrusion()
        XCTAssertEqual(try SolidKernel.solid(for: try XCTUnwrap(session.workspace.bodies.last)).volume, (20 * 8 + .pi * 16) * 5, accuracy: 1e-3)
        session.undo()
        XCTAssertTrue(session.workspace.bodies.isEmpty)
    }

    // MARK: Fillet and chamfer on any edge

    func testAHoleRimCutIntoASolidCanBeRounded() throws {
        let (session, controller) = try drilledBox()
        let body = try XCTUnwrap(session.workspace.bodies.first)
        let before = try SolidKernel.solid(for: body).volume
        session.chooseTool(.fillet)
        // The front of the hole's top rim: made by the cut, not by the original extrusion.
        tap(controller, SIMD3(10, -5, 20))
        let picked = try XCTUnwrap(session.finishDraft?.edges.first)
        XCTAssertNil(picked.name)
        XCTAssertNotNil(session.finishPreview)
        XCTAssertTrue(session.applyDimension(1.5, target: .finishSize(.fillet)))
        session.confirmFinish()
        let rounded = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(rounded.cuts.last?.operation, .finish)
        XCTAssertLessThan(try SolidKernel.solid(for: rounded).volume, before)
        // The box's own top edge, on a solid that has a cut, is a step after the cut too.
        session.select(nil)
        session.chooseTool(.chamfer)
        tap(controller, SIMD3(0, -20, 20))
        XCTAssertEqual(session.finishDraft?.edges.first?.name?.position, .cap)
        session.confirmFinish()
        XCTAssertEqual(session.workspace.bodies.first?.cuts.filter { $0.operation == .finish }.count, 2)
        session.undo()
        session.undo()
        XCTAssertEqual(session.workspace.bodies.first, body)
        // In Select, a tap on the rim picks it too, and its arrow rounds it.
        session.chooseTool(.select)
        tap(controller, SIMD3(10, -5, 20))
        let selected = try XCTUnwrap(session.selectedEdge)
        XCTAssertNil(selected.edge.name)
        XCTAssertNotNil(controller.edgeSelectionHandle())
        XCTAssertEqual(session.selectionMeasure, "Ø 10 mm", "The strip shows the rim's size")
    }

    // MARK: Sketch Fillet, Trim, and Dimension

    func testSketchFilletRoundsATappedCornerAndTakesARadius() throws {
        let (session, controller) = topSketch()
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 40, y: 20)))
        session.chooseTool(.cornerFillet)
        XCTAssertEqual(session.tool, .cornerFillet)
        XCTAssertNotNil(session.sketchMode, "Sketch tools keep sketching")
        tap(controller, SIMD3(40, 20, 0))
        XCTAssertEqual(session.workspace.shapes.filter { $0.kind == .line }.count, 4)
        XCTAssertEqual(session.workspace.shapes.filter { $0.kind == .arc }.count, 1)
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.cornerRadius])
        XCTAssertTrue(session.applyDimension(6, target: .cornerRadius))
        let arc = try XCTUnwrap(session.workspace.shapes.first { $0.kind == .arc })
        XCTAssertEqual(arc.arcCenter, Point2(x: 34, y: 14))
        XCTAssertEqual(session.workspace.profiles.count, 1)
        XCTAssertFalse(session.applyDimension(30, target: .cornerRadius), "Too large for the sides")
        session.undo()
        XCTAssertEqual(session.workspace.shapes.map(\.kind), [.rectangle], "The corner and its radius were one step")
    }

    func testTrimScribblesAwayTheStretchesItCrosses() throws {
        let (session, controller) = topSketch()
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 40, y: 20)))
        session.addShape(.init(kind: .line, plane: .top, start: .init(x: 20, y: -10), end: .init(x: 20, y: 30)))
        XCTAssertEqual(session.workspace.profiles.count, 2, "The line divides the rectangle")
        session.chooseTool(.trim)
        // One stroke over the line's two ends outside the rectangle.
        stroke(controller, [SIMD3(18, -6, 0), SIMD3(20, -5, 0), SIMD3(22, -6, 0)])
        stroke(controller, [SIMD3(18, 26, 0), SIMD3(20, 25, 0), SIMD3(22, 26, 0)])
        XCTAssertEqual(session.workspace.shapes.filter { $0.kind == .line }.count, 1)
        XCTAssertEqual(session.workspace.profiles.count, 2, "The divider stays")
        session.undo()
        XCTAssertEqual(session.workspace.shapes.count, 2, "Each stroke is one step")
        XCTAssertEqual(session.workspace.shapes.filter { $0.kind == .line }.first.map { abs($0.end.y - $0.start.y) }, 30)
    }

    func testTrimFinishesWithATapOnEmptySpace() throws {
        let (session, controller) = topSketch()
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 40, y: 20)))
        session.addShape(.init(kind: .line, plane: .top, start: .init(x: 20, y: -10), end: .init(x: 20, y: 30)))
        session.chooseTool(.trim)
        tap(controller, SIMD3(20, -5, 0))
        XCTAssertEqual(session.tool, .trim, "A tap on a shape trims and keeps trimming")
        let trimmed = session.workspace
        tap(controller, SIMD3(70, 60, 0))
        XCTAssertEqual(session.tool, .select, "A tap on empty space completes Trim")
        XCTAssertNotNil(session.sketchMode, "Still sketching")
        XCTAssertEqual(session.workspace, trimmed, "The empty tap changed nothing")
    }

    func testDimensionToolPositionsACircleFromACorner() throws {
        let (session, controller) = topSketch()
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 40, y: 20)))
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 12, y: 7), end: .init(x: 15, y: 7)))
        session.chooseTool(.dimension)
        tap(controller, SIMD3(0, 0, 0))
        XCTAssertEqual(session.dimensionDraft?.first?.part, .corner(0))
        tap(controller, SIMD3(12, 7, 0))
        XCTAssertEqual(session.dimensionDraft?.second?.part, .center)
        XCTAssertEqual(session.sketchDimensions.map(\.kind), [.horizontal, .vertical, .distance])
        let labels = controller.dimensionAnnotations()
        XCTAssertEqual(labels.map(\.target), [.relation(0, angle: false), .relation(1, angle: false), .relation(2, angle: false)])
        XCTAssertTrue(session.applyDimension(6, target: .relation(0, angle: false)))
        XCTAssertTrue(session.applyDimension(10, target: .relation(1, angle: false)))
        XCTAssertEqual(session.workspace.shapes[1].start, Point2(x: 6, y: 10))
        XCTAssertEqual(session.workspace.shapes[0].outline[0], .zero, "The rectangle stays")
        // The picks follow the move, so the values read back.
        XCTAssertEqual(session.sketchDimensions.map(\.value).prefix(2), [6, 10])
        // A tap on nothing starts again.
        tap(controller, SIMD3(100, 100, 0))
        XCTAssertNil(session.dimensionDraft?.first)
        session.undo()
        session.undo()
        XCTAssertEqual(session.workspace.shapes[1].start, Point2(x: 12, y: 7))
    }

    func testDimensionAndOtherSketchToolsSurviveThePlanePick() throws {
        // The Sketch tile, then Dimension, then a plane: the tool is ready to pick.
        let session = ModelingSession(inMemory: true)
        session.beginSketch()
        session.chooseTool(.dimension)
        session.pickPlane(.top)
        XCTAssertEqual(session.tool, .dimension)
        XCTAssertNotNil(session.dimensionDraft)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 40, y: 20)))
        session.pickDimensionReference(SketchReference(kind: .point(.zero)))
        XCTAssertNotNil(session.dimensionDraft?.first)

        // A construction plane keeps the chosen tool too.
        session.exitSketch()
        session.chooseTool(.offsetPlane)
        session.pickPlaneReference(.world(.front))
        XCTAssertTrue(session.applyDimension(15, target: .planeOffset))
        session.confirmPlane()
        let plane = try XCTUnwrap(session.workspace.constructionPlanes.first)
        session.selection = nil
        session.beginSketch()
        session.chooseTool(.circle)
        session.pickConstructionPlane(plane.id)
        XCTAssertEqual(session.tool, .circle)
    }

    func testARegionWithAHoleExtrudesAsARing() throws {
        let (session, _) = topSketch()
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -20, y: -20), end: .init(x: 20, y: 20)))
        session.addShape(.init(kind: .circle, plane: .top, start: .zero, end: .init(x: 8, y: 0)))
        let plate = try XCTUnwrap(session.workspace.profiles.first { $0.holes != nil })
        session.select(.profile(plate.id))
        XCTAssertEqual(session.selectedProfile?.holes?.count, 1)
        session.beginExtrusion()
        session.extrusionDepth = 4
        session.confirmExtrusion()
        let body = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, (1600 - .pi * 64) * 4, accuracy: 0.05)
    }

    /// An offset rectangle inside another (October 22, 2026): the outer region looks like the ring it
    /// extrudes. The tint and preview leave the hole open, the arrow sits on the ring, and the strip says so.
    func testARingLooksLikeARingBeforeAndWhileExtruding() throws {
        let (session, _) = topSketch()
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -41, y: -19.5), end: .init(x: 41, y: 19.5)))
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -39, y: -17.5), end: .init(x: 39, y: 17.5)))
        session.exitSketch()
        let ring = try XCTUnwrap(session.workspace.profiles.first { $0.holes != nil })
        session.select(.profile(ring.id))
        let controller = canvas(session, camera: .reset)
        let hole = controller.project(SIMD3(0, 0, 0))
        let handle = try XCTUnwrap(controller.selectionExtrudeHandle())
        XCTAssertGreaterThan(hypot(handle.origin.x - hole.x, handle.origin.y - hole.y), 100, "The arrow is on the ring, not in its hole")
        attach(controller, "Ring selected")
        session.beginExtrusion()
        session.extrusionDepth = 10
        controller.refresh()
        let arrow = try XCTUnwrap(controller.extrusionHandle())
        XCTAssertGreaterThan(hypot(arrow.origin.x - hole.x, arrow.origin.y - hole.y), 100)
        attach(controller, "Ring extruding")
        // The hole's middle shows the canvas through the preview: no gray block over it.
        let image = controller.sceneView.snapshot()
        let scale = image.size.width / controller.view.bounds.width
        func sample(_ world: SIMD3<Float>) throws -> SIMD3<Double> {
            let point = controller.project(world)
            return try color(of: image, at: CGPoint(x: point.x * scale, y: point.y * scale))
        }
        // Beside a grid line in the hole's middle, and on the open canvas off the ring's side; inside the ring's wall for contrast.
        let inside = try sample(SIMD3(1, 1, 0)), open = try sample(SIMD3(1, -40, 0)), wall = try sample(SIMD3(-40, 1, 5))
        XCTAssertLessThan(simd_length(inside - open), 0.08, "The hole stays open in the preview: \(inside) vs \(open)")
        XCTAssertGreaterThan(simd_length(wall - open), 0.08, "The ring's wall is drawn: \(wall) vs \(open)")
    }

    /// Lines crossing on a solid's face (October 22, 2026): after Finish Sketch, the shape they enclose
    /// can be picked and cut into the solid behind it.
    func testLinesSketchedOnAFaceCutTheShapeTheyEnclose() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(0, -20, 10))
        let face = try XCTUnwrap(session.selectedFace?.plane, "The front face")
        session.beginSketch()
        XCTAssertNotNil(session.sketchMode)
        let plane = session.plane
        XCTAssertEqual(plane.height(of: SIMD3(0, -20, 10)), 0, accuracy: 1e-6, "Sketching on the face: \(face)")
        func local(_ x: Double, _ z: Double) -> Point2 { plane.coordinates(of: SIMD3(x, -20, z)) }
        // A rectangle of four lines, each running a little past the others.
        for (a, b) in [(local(-18, 4), local(18, 4)), (local(-18, 16), local(18, 16)), (local(-15, 1), local(-15, 19)), (local(15, 1), local(15, 19))] {
            session.addShape(.init(kind: .line, plane: plane, start: a, end: b))
        }
        let regions = session.workspace.profiles.filter { $0.plane == plane }
        XCTAssertEqual(regions.count, 1, "The lines enclose one region")
        session.exitSketch()
        session.requestCamera(.reset)
        controller.refresh()
        attach(controller, "Face sketch finished")
        session.select(nil)
        tap(controller, SIMD3(0, -20, 10))
        XCTAssertEqual(session.selectedProfile?.plane, plane, "No tool: a tap inside picks the region, not the face")
        session.select(nil)
        session.chooseTool(.extrude)
        tap(controller, SIMD3(0, -20, 10))
        XCTAssertEqual(session.selectedProfile?.plane, plane, "Extrude tool: a tap inside picks the region, not the box's hidden source sketch")
        // Pushed 5 mm into the box, it cuts a 30 × 12 pocket there.
        XCTAssertTrue(session.isExtruding)
        let before = try SolidKernel.solid(for: session.workspace.bodies[0]).volume
        XCTAssertTrue(session.applyDimension(-5, target: .extrusion))
        XCTAssertEqual(session.extrusionMode, .cut, "Into the box cuts it")
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, before - 30 * 12 * 5, accuracy: 1e-3)
    }

    /// The color at a point of an image, as 0…1 RGB.
    private func color(of image: UIImage, at point: CGPoint) throws -> SIMD3<Double> {
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let x = point.x / image.size.width * CGFloat(cg.width), y = point.y / image.size.height * CGFloat(cg.height)
        context.draw(cg, in: CGRect(x: -x, y: y - CGFloat(cg.height) + 1, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
    }

    // MARK: Measure

    func testMeasureReadsASolidAndTheGapBetweenFaces() throws {
        let (session, controller) = try drilledBox()
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 50, y: -20), end: .init(x: 70, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        session.chooseTool(.measure)
        XCTAssertTrue(session.isMeasuring)
        XCTAssertNil(session.sketchMode)
        // Top faces of both solids: 30 mm apart, parallel.
        tap(controller, SIMD3(-15, 5, 20))
        XCTAssertEqual(session.measureItems.count, 1)
        XCTAssertEqual(session.measurements.values.first?.kind, .area)
        XCTAssertEqual(session.measurements.values.first?.value ?? 0, 2400 - .pi * 25, accuracy: 1e-3)
        tap(controller, SIMD3(60, 0, 20))
        let between = session.measurements
        XCTAssertEqual(between.values.first { $0.kind == .distance }?.value ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(between.values.first { $0.kind == .angle }?.value ?? -1, 0, accuracy: 1e-6)
        XCTAssertNotNil(between.from)
        // A double-tap measures the whole solid (the earlier tap must not count as its first half).
        session.pickMeasureItem(nil)
        controller.forgetTaps()
        tap(controller, SIMD3(60, 0, 20))
        tap(controller, SIMD3(60, 0, 20))
        XCTAssertEqual(session.measureItems.count, 1)
        XCTAssertEqual(session.measurements.values.first { $0.kind == .volume }?.value ?? 0, 16_000, accuracy: 1e-6)
        XCTAssertEqual(session.measureItems.last, .body(session.workspace.bodies[1].id))
        session.endMeasure()
        XCTAssertEqual(session.tool, .select)
        XCTAssertTrue(session.measureItems.isEmpty)
    }

    // MARK: Units

    func testInchesShowOnLabelsAndTheKeypadTakesThem() throws {
        let (session, controller) = topSketch()
        session.addShape(.init(kind: .line, plane: .top, start: .zero, end: .init(x: 25.4, y: 0)))
        session.lengthUnit = .inches
        controller.refresh()
        let label = try XCTUnwrap(controller.dimensionAnnotations().first)
        XCTAssertEqual(label.text, "1 in")
        XCTAssertEqual(session.lengthText(12.7), "0.5 in")
        // The keypad's value arrives in millimeters.
        XCTAssertTrue(session.applyDimension(try XCTUnwrap(DimensionExpression.evaluate("2", unit: .inches)) * 25.4, target: label.target))
        XCTAssertEqual(session.workspace.shapes[0].end.x, 50.8, accuracy: 1e-9)
        XCTAssertEqual(session.snapGrid, min(session.gridSpacing, 25.4 / 16))
        session.lengthUnit = .millimeters
        controller.refresh()
        XCTAssertEqual(controller.dimensionAnnotations().first?.text, "50.8 mm")
    }
}
