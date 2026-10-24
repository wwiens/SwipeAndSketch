import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Picking several sketch regions and whole sketches with the Pencil, then extruding or revolving
/// them together (user decision, October 23, 2026).
@MainActor final class MultiSelectToolTests: CanvasTestCase {
    /// The 60 × 40 × 20 box with a circle on its top face (z = 20) at each world center, each in
    /// a sketch of its own, in the default 3D view with nothing selected.
    func boxWithFaceSketches(_ centers: [SIMD2<Double>], radius: Double) throws -> (ModelingSession, CanvasController, body: UUID, circles: [UUID], sketches: [UUID]) {
        let (session, controller) = boxScene()
        let body = try XCTUnwrap(session.workspace.bodies.first).id
        var circles: [UUID] = [], sketches: [UUID] = []
        for center in centers {
            session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: body, near: [0, 0, 20]))))
            session.beginFaceSketch()
            let plane = session.plane
            let middle = plane.coordinates(of: SIMD3(center.x, center.y, 20)), edge = plane.coordinates(of: SIMD3(center.x + radius, center.y, 20))
            let circle = SketchShape(kind: .circle, plane: plane, start: middle, end: edge)
            session.addShape(circle)
            session.exitSketch()
            circles.append(circle.id)
            sketches.append(try XCTUnwrap(session.selectedSketch?.id, "Finishing the sketch selects it"))
        }
        XCTAssertEqual(Set(sketches).count, centers.count, "Each circle is its own sketch")
        session.select(nil)
        session.requestCamera(.reset)
        controller.refresh()
        return (session, controller, body, circles, sketches)
    }

    func testTappingRegionsOnAFacePicksThemAllAndOneExtrudeCutsThemAsOneUndoStep() throws {
        // Far enough apart that no two taps in a row count as a double-tap.
        let centers: [SIMD2<Double>] = [[-20, -10], [20, 10], [-20, 10], [20, -10], [0, 0]]
        let (session, controller, body, circles, _) = try boxWithFaceSketches(centers, radius: 3)
        func tapCircle(_ index: Int) { tap(controller, SIMD3<Float>(Float(centers[index].x), Float(centers[index].y), 20)) }

        tapCircle(0)
        XCTAssertEqual(session.selection, .shape(circles[0]), "The first tap selects the region alone")
        XCTAssertFalse(session.isMultipleSelection)
        for index in 1...3 { tapCircle(index) }
        XCTAssertEqual(session.selectedItems, (0...3).map { .shape(circles[$0]) }, "Each tap on the face's plane adds a region")
        XCTAssertEqual(session.pickedSummary, "4 regions")
        XCTAssertTrue(session.hint.hasPrefix("4 regions picked."), session.hint)
        XCTAssertEqual(session.helpTopic, .pickedSketches)
        XCTAssertNil(session.transformWidgetTarget, "No Move/Rotate widget for several items")
        XCTAssertTrue(session.canExtrude)
        XCTAssertNil(session.sketchMode, "Picking never opens a sketch")

        // A tap on a picked region takes it out; removing the first passes the lead on.
        tapCircle(1)
        tapCircle(4)
        tapCircle(0)
        XCTAssertEqual(session.selectedItems, [2, 3, 4].map { .shape(circles[$0]) })
        XCTAssertEqual(session.pickedSummary, "3 regions")
        controller.refresh()
        attach(controller, "Three regions picked on a face")

        // The assistant sees all three and can extrude them as "selected".
        var bench = AssistantWorkbench(workspace: session.workspace, selection: session.assistantSelection)
        XCTAssertTrue(bench.selectionDescription().hasPrefix("3 sketch items"), bench.selectionDescription())
        XCTAssertEqual(bench.selectedRegions().count, 3)
        try bench.extrude(sketch: "selected", regions: [], distance: -5, mode: .cut, throughAll: false)
        XCTAssertEqual(bench.workspace.bodies.first?.cuts.count, 3)

        // Extrude (the strip's button) takes all three; pushing in cuts the box.
        session.beginExtrusion()
        XCTAssertTrue(session.isExtruding)
        XCTAssertEqual(session.extrusionProfiles.count, 3)
        XCTAssertTrue(session.applyDimension(-5, target: .extrusion))
        XCTAssertTrue(session.isCutting, "Into the solid cuts it")
        XCTAssertEqual(session.cutTargets, [body])
        controller.refresh()
        XCTAssertNotNil(controller.extrusionHandle())
        attach(controller, "Three regions cut together")
        session.confirmExtrusion()
        XCTAssertFalse(session.isExtruding)
        let cut = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(cut.cuts.count, 3)
        XCTAssertEqual(try SolidKernel.solid(for: cut).volume, 48_000 - 3 * .pi * 9 * 5, accuracy: 1e-2)
        XCTAssertEqual(session.selection, .body(body))
        XCTAssertFalse(session.isMultipleSelection)

        session.undo()
        XCTAssertEqual(session.workspace.bodies.first?.cuts, [], "One undo takes out every cut")
        session.redo()
        XCTAssertEqual(session.workspace.bodies.first?.cuts.count, 3)
    }

    func testTappingSketchLinesPicksWholeSketchesAndAFaceStartsOver() throws {
        let centers: [SIMD2<Double>] = [[-20, 0], [0, 0], [20, 0]]
        let (session, controller, body, _, sketches) = try boxWithFaceSketches(centers, radius: 5)
        func tapLine(_ index: Int) { tap(controller, SIMD3<Float>(Float(centers[index].x + 5), Float(centers[index].y), 20)) }

        // Double-tapping a line picks its whole sketch, as before; another sketch's line adds that sketch.
        tapLine(0); tapLine(0)
        XCTAssertEqual(session.selection, .sketch(sketches[0]))
        XCTAssertNil(session.sketchMode)
        tapLine(1)
        XCTAssertEqual(session.selectedItems, [.sketch(sketches[0]), .sketch(sketches[1])])
        XCTAssertNil(session.sketchMode, "A line tap adds the sketch instead of opening it")
        // A plain face tap replaces them.
        tap(controller, SIMD3<Float>(0, 15, 20))
        guard case .face(let face) = session.selection else { return XCTFail("The face is selected: \(String(describing: session.selection))") }
        XCTAssertEqual(face.bodyID, body)
        XCTAssertFalse(session.isMultipleSelection)

        tapLine(2); tapLine(2)
        tapLine(0)
        // A double-tap on another sketch adds it once.
        tapLine(1); tapLine(1)
        XCTAssertEqual(session.selectedItems, [2, 0, 1].map { .sketch(sketches[$0]) })
        XCTAssertEqual(session.pickedSummary, "3 sketches")
        XCTAssertEqual(session.selectedProfiles.count, 3)

        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        session.cutThroughAll = true
        XCTAssertEqual(session.cutTargets, [body])
        session.confirmExtrusion()
        let cut = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(cut.cuts.count, 3)
        XCTAssertEqual(try SolidKernel.solid(for: cut).volume, 48_000 - 3 * .pi * 25 * 20, accuracy: 1e-2)
    }

    func testASingleWholeSketchExtrudesEveryRegion() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 10, y: 10)))
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 20, y: 0), end: .init(x: 30, y: 10)))
        let sketch = try XCTUnwrap(session.workspace.sketches.first).id
        session.selectSketch(sketch)
        XCTAssertTrue(session.canExtrude, "A whole sketch with regions can be extruded")
        session.beginExtrusion()
        XCTAssertEqual(session.extrusionProfiles.count, 2)
        session.extrusionDepth = 5
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 2, "Two regions apart make two solids")
    }

    func testPickedRegionsRevolveTogetherAboutOneAxis() throws {
        let session = ModelingSession(inMemory: true)
        session.choosePlane(.front)
        session.snapEnabled = false
        let near = SketchShape(kind: .rectangle, plane: .front, start: .init(x: 5, y: 0), end: .init(x: 15, y: 10))
        let far = SketchShape(kind: .rectangle, plane: .front, start: .init(x: 20, y: 0), end: .init(x: 30, y: 10))
        let line = SketchShape(kind: .line, plane: .front, start: .init(x: 0, y: -5), end: .init(x: 0, y: 20))
        for shape in [near, far, line] { session.addShape(shape) }
        session.select(nil)
        let controller = canvas(session)
        tap(controller, SketchPlane.front.world(Point2(x: 10, y: 5)))
        tap(controller, SketchPlane.front.world(Point2(x: 25, y: 5)))
        XCTAssertEqual(session.selectedItems, [.shape(near.id), .shape(far.id)])

        session.beginRevolve()
        XCTAssertEqual(session.revolveDraft?.profiles.count, 2)
        XCTAssertEqual(session.selectedItems.count, 2, "Both stay picked while revolving")
        tap(controller, SketchPlane.front.world(Point2(x: 0, y: 7.5)))
        XCTAssertNotNil(session.revolveDraft?.axis)
        session.setRevolveAngle(360)
        XCTAssertTrue(session.canConfirmRevolve)
        session.confirmRevolve()
        XCTAssertEqual(session.workspace.bodies.count, 2, "Two rings apart make two solids")
        let volumes = try session.workspace.bodies.map { try SolidKernel.solid(for: $0).volume }.sorted()
        XCTAssertEqual(volumes[0], .pi * (15 * 15 - 5 * 5) * 10, accuracy: 0.5)
        XCTAssertEqual(volumes[1], .pi * (30 * 30 - 20 * 20) * 10, accuracy: 0.5)
        session.undo()
        XCTAssertTrue(session.workspace.bodies.isEmpty, "One undo step")
    }
}
