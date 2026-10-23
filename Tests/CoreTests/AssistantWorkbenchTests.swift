import XCTest
import simd
@testable import SwipeAndSketchCore

/// The assistant's model layer: what it reports, how it resolves names, and that each change is
/// validated (or refused with a reason) without touching the rest of the document.
final class AssistantWorkbenchTests: XCTestCase {
    typealias Input = AssistantWorkbench.ShapeInput

    /// A 60 × 40 × 20 box on Top, centered on the origin, made by the workbench itself.
    func boxBench() throws -> AssistantWorkbench {
        var bench = AssistantWorkbench(workspace: Workspace())
        try bench.addShapes([Input(kind: .rectangle, point: .zero, width: 60, height: 40)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 01", regions: [], distance: 20, mode: .auto, throughAll: false)
        return bench
    }

    func volume(_ bench: AssistantWorkbench, _ index: Int = 0) throws -> Double {
        try SolidKernel.solid(for: bench.workspace.bodies[index]).volume
    }

    func testDrawingAndExtrudingMakesANamedBoxAndRecordsEachChange() throws {
        let bench = try boxBench()
        XCTAssertEqual(bench.workspace.sketches.count, 1)
        XCTAssertEqual(bench.workspace.bodies.count, 1)
        XCTAssertEqual(try volume(bench), 48_000, accuracy: 1e-6)
        XCTAssertEqual(bench.changes.count, 2)
        XCTAssertEqual(bench.changes[1], "New Body 01: 60 × 40 rectangle, 20 mm tall")
        XCTAssertEqual(bench.focus, .body(bench.workspace.bodies[0].id))
        let summary = bench.summary()
        XCTAssertTrue(summary.contains("Body 01: extruded 20 mm along +Z from Sketch 01"), summary)
        XCTAssertTrue(summary.contains("60 wide (x) × 40 deep (y) × 20 tall (z)"), summary)
        XCTAssertTrue(summary.contains("Rectangle 01 60 × 40 centered at (0, 0, 0)"), summary)
        XCTAssertTrue(summary.contains("Selected: nothing."), summary)
    }

    func testNamesResolveLooselyAndUnknownNamesExplainThemselves() throws {
        var bench = try boxBench()
        let id = bench.workspace.bodies[0].id
        for name in ["Body 01", "body 1", "BODY01", "solid 1"] { XCTAssertEqual(try bench.item(named: name), .body(id), name) }
        XCTAssertEqual(try bench.item(named: "rectangle 1"), .shape(bench.workspace.shapes[0].id))
        XCTAssertThrowsError(try bench.item(named: "Body 02")) { XCTAssertTrue(($0 as! AssistantWorkbench.Failure).message.contains("has 1")) }
        XCTAssertThrowsError(try bench.item(named: "selected"))
        bench.selection = .face(bodyID: id, face: 0)
        XCTAssertEqual(try bench.item(named: "selected"), .body(id))
    }

    func testFacesResolveBySideAndEdgesByRule() throws {
        let bench = try boxBench()
        let body = bench.workspace.bodies[0], solid = try SolidKernel.solid(for: body)
        let top = try bench.face("top", of: body)
        XCTAssertEqual(solid.facePlane(top)?.normal.z ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(solid.faceCenter(top)?.z ?? 0, 20, accuracy: 1e-9)
        let front = try bench.face("front face", of: body)
        XCTAssertEqual(solid.facePlane(front)?.normal.y ?? 0, -1, accuracy: 1e-9)
        XCTAssertEqual(try bench.edges("vertical", of: body).count, 4)
        XCTAssertEqual(try bench.edges("top", of: body).count, 4)
        XCTAssertEqual(try bench.edges("all", of: body).count, 12)
        XCTAssertEqual(Set(try bench.edges("top, vertical", of: body)).count, 8)
        XCTAssertThrowsError(try bench.face("sideways", of: body))
        let report = try bench.inspect(body)
        XCTAssertTrue(report.contains("Faces (6):") && report.contains("Edges (12):"), report)
        XCTAssertTrue(report.contains("faces +Z (top), center (0, 0, 20), 60 × 40"), report)
    }

    func testFilletChamferShellAndHoleChangeTheSolid() throws {
        var bench = try boxBench()
        try bench.finish(.fillet, body: "Body 01", edges: "vertical", size: 3)
        XCTAssertEqual(bench.workspace.bodies[0].finishes.first?.edges.count, 4)
        XCTAssertLessThan(try volume(bench), 48_000)
        // Every edge, including the ones the rounds made, as a step after them.
        let message = try bench.finish(.chamfer, body: "Body 01", edges: "all", size: 1)
        XCTAssertTrue(message.hasPrefix("Chamfer 1 mm on"), message)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.last?.operation, .finish)
        XCTAssertTrue(bench.workspace.bodies[0].finishesAreValid)

        let beforeHole = try volume(bench)
        try bench.hole(body: "Body 01", face: "top", kind: .counterbore, size: "m3", depth: nil)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.last?.operation, .hole)
        XCTAssertLessThan(try volume(bench), beforeHole)
        XCTAssertEqual(bench.changes.count, 5)

        // Mounting holes 6 mm in from each corner of the top face.
        var plate = try boxBench()
        try plate.hole(body: "Body 01", face: "top", cornerInset: 6, kind: .simple, size: "M3", depth: nil)
        let holes = plate.workspace.bodies[0].cuts.filter { $0.operation == .hole }
        XCTAssertEqual(holes.count, 4)
        XCTAssertEqual(Set(holes.map { "\($0.profile.circle!.center.x.rounded()),\($0.profile.circle!.center.y.rounded())" }), ["-24.0,-14.0", "24.0,-14.0", "24.0,14.0", "-24.0,14.0"])
        XCTAssertEqual(try volume(plate), 48_000 - 4 * .pi * 1.7 * 1.7 * 20, accuracy: 1)
        // Any diameter, as a plain hole straight through.
        var drilled = try boxBench()
        try drilled.hole(body: "Body 01", face: "top", kind: .simple, size: "", diameter: 10, depth: nil)
        XCTAssertEqual(try volume(drilled), 48_000 - .pi * 25 * 20, accuracy: 1)

        var shelled = try boxBench()
        try shelled.shell(body: "Body 01", openFaces: ["top"], thickness: 2)
        XCTAssertEqual(try volume(shelled), 48_000 - 56 * 36 * 18, accuracy: 1e-3)
    }

    func testCutsAndJoinsFindTheSolidTheyTouch() throws {
        var bench = try boxBench()
        // A slot through the box from a Top sketch: a cut, not a new body.
        try bench.addShapes([Input(kind: .rectangle, point: .zero, width: 10, height: 30)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 02", regions: [], distance: 20, mode: .auto, throughAll: false)
        XCTAssertEqual(bench.workspace.bodies.count, 1)
        XCTAssertEqual(try volume(bench), 48_000 - 10 * 30 * 20, accuracy: 1e-6)
        // A boss on the top face joins.
        try bench.addShapes([Input(kind: .circle, point: [20, 0, 20], diameter: 8)], on: .face(body: bench.workspace.bodies[0].id, face: "top"))
        try bench.extrude(sketch: "Sketch 03", regions: [], distance: 5, mode: .auto, throughAll: false)
        XCTAssertEqual(bench.workspace.bodies.count, 1)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.last?.operation, .join)
        // A cut that misses is refused, and the draft is untouched.
        let before = bench.workspace
        try bench.addShapes([Input(kind: .circle, point: [200, 0, 0], diameter: 5)], on: .world(.top))
        let afterSketch = bench.workspace
        XCTAssertThrowsError(try bench.extrude(sketch: "Sketch 04", regions: [], distance: 5, mode: .cut, throughAll: false))
        XCTAssertEqual(bench.workspace, afterSketch)
        XCTAssertNotEqual(before, afterSketch)
    }

    func testABossSketchedOnAFaceJoinsThatFacesBody() throws {
        // Two overlapping boxes: a wall sketched on the second one's top joins the second, not the first.
        var bench = try boxBench()
        try bench.addShapes([Input(kind: .rectangle, point: [10, 0, 0], width: 60, height: 40)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 02", regions: [], distance: 5, mode: .newBody, throughAll: false)
        let plate = bench.workspace.bodies[1].id
        try bench.addShapes([Input(kind: .rectangle, point: [10, 17.5, 5], width: 40, height: 5)], on: .face(body: plate, face: "top"))
        try bench.extrude(sketch: "Sketch 03", regions: [], distance: 30, mode: .join, throughAll: false)
        XCTAssertEqual(bench.workspace.bodies[1].cuts.last?.operation, .join, "joined the plate")
        XCTAssertTrue(bench.workspace.bodies[0].cuts.isEmpty, "the box is untouched")
    }

    func testAmbiguousRegionsAskWhichOne() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        try bench.addShapes([Input(kind: .rectangle, point: .zero, width: 60, height: 40), Input(kind: .circle, point: [50, 0, 0], diameter: 10)], on: .world(.top))
        XCTAssertThrowsError(try bench.extrude(sketch: "Sketch 01", regions: [], distance: 5, mode: .auto, throughAll: false)) {
            XCTAssertTrue(($0 as! AssistantWorkbench.Failure).message.contains("2 regions"))
        }
        try bench.extrude(sketch: "Sketch 01", regions: [1, 2], distance: 5, mode: .newBody, throughAll: false)
        XCTAssertEqual(bench.workspace.bodies.count, 2)
    }

    func testDimensionsTransformsDeleteAndVisibility() throws {
        var bench = try boxBench()
        try bench.setDimension(item: "Body 01", dimension: "height", value: 35)
        XCTAssertEqual(bench.workspace.bodies[0].depth, 35)
        try bench.setDimension(item: "Rectangle 01", dimension: "width", value: 80)
        XCTAssertEqual(abs(bench.workspace.shapes[0].end.x - bench.workspace.shapes[0].start.x), 80, accuracy: 1e-9)
        XCTAssertEqual(bench.workspace.shapes[0].center.x, 0, accuracy: 1e-9, "centered rectangles stay centered")

        try bench.transform(items: ["Body 01"], move: [0, 0, 10], rotate: 0, axis: "z", pivot: nil, copy: true)
        XCTAssertEqual(bench.workspace.bodies.count, 2)
        let copy = try SolidKernel.solid(for: bench.workspace.bodies[1]).bounds
        XCTAssertEqual(copy.min.z, 10, accuracy: 1e-9)
        try bench.transform(items: ["Body 02"], move: .zero, rotate: 90, axis: "z", pivot: nil, copy: false)
        let turned = try SolidKernel.solid(for: bench.workspace.bodies[1]).bounds
        XCTAssertEqual(turned.max.x - turned.min.x, 40, accuracy: 1e-6)

        try bench.setHidden(items: ["Body 01"], hidden: true)
        XCTAssertTrue(bench.workspace.bodies[0].isHidden)
        try bench.delete(items: ["Body 02", "Sketch 01"])
        XCTAssertEqual(bench.workspace.bodies.count, 1)
        XCTAssertTrue(bench.workspace.sketches.isEmpty)
    }

    func testUnionSubtractMirrorPlanesAndRevolve() throws {
        var bench = try boxBench()
        try bench.addShapes([Input(kind: .rectangle, point: [40, 0, 0], width: 20, height: 20)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 02", regions: [], distance: 10, mode: .newBody, throughAll: false)
        XCTAssertEqual(bench.workspace.bodies.count, 2)
        try bench.combine(union: true, target: "Body 01", tools: ["Body 02"], keepTools: false)
        XCTAssertEqual(bench.workspace.bodies.count, 1)
        XCTAssertEqual(try volume(bench), 48_000 + 20 * 20 * 10, accuracy: 1e-3)

        try bench.mirror(items: ["Body 01"], across: "right", face: nil, keepOriginals: true)
        XCTAssertEqual(bench.workspace.bodies.count, 2)

        try bench.addPlane(from: "Body 01", face: "top", offset: 5)
        XCTAssertEqual(bench.workspace.constructionPlanes.first?.plane.origin.z ?? 0, 25, accuracy: 1e-9)
        try bench.addShapes([Input(kind: .circle, point: [0, 0, 25], diameter: 6)], on: .construction(bench.workspace.constructionPlanes[0].id))
        XCTAssertEqual(bench.workspace.sketches.last?.plane.origin.z ?? 0, 25, accuracy: 1e-9)

        var turned = AssistantWorkbench(workspace: Workspace())
        try turned.addShapes([Input(kind: .rectangle, point: [15, 0, 10], width: 10, height: 20)], on: .world(.front))
        try turned.revolve(sketch: "Sketch 01", region: nil, axis: "z", angle: 360, mode: .newBody)
        XCTAssertEqual(try volume(turned), .pi * (20 * 20 - 10 * 10) * 20, accuracy: 1)
        XCTAssertThrowsError(try turned.revolve(sketch: "Sketch 01", region: nil, axis: "y", angle: 90, mode: .newBody))
    }

    func testIntersectKeepsTheOverlap() throws {
        var bench = try boxBench()
        try bench.addShapes([Input(kind: .rectangle, point: [30, 0, 0], width: 20, height: 20)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 02", regions: [], distance: 10, mode: .newBody, throughAll: false)
        XCTAssertEqual(try bench.intersect(target: "Body 01", tools: ["Body 02"], keepTools: false),
                       "Intersected Body 01 with Body 02. Names of later items may shift.")
        XCTAssertEqual(bench.workspace.bodies.count, 1)
        XCTAssertEqual(try volume(bench), 10 * 20 * 10, accuracy: 1e-3)
        XCTAssertTrue(bench.summary().contains("intersected with a solid"))
        var apart = try boxBench()
        try apart.addShapes([Input(kind: .rectangle, point: [80, 0, 0], width: 20, height: 20)], on: .world(.top))
        try apart.extrude(sketch: "Sketch 02", regions: [], distance: 10, mode: .newBody, throughAll: false)
        XCTAssertThrowsError(try apart.intersect(target: "Body 01", tools: ["Body 02"], keepTools: false))
        XCTAssertEqual(apart.workspace.bodies.count, 2, "A refused change leaves the draft alone")
    }

    func testMissingBasicsOperations() throws {
        var bench = try boxBench()
        // Scale about the base: twice as big, still on the plate.
        try bench.scale(items: ["Body 01"], percent: 200, percents: nil, about: "base", copy: false)
        XCTAssertEqual(try volume(bench), 48_000 * 8, accuracy: 1)
        XCTAssertEqual(try SolidKernel.solid(for: bench.workspace.bodies[0]).bounds.min.z, 0, accuracy: 1e-6)
        XCTAssertTrue(bench.summary().contains("scaled 200%"))
        // A flat face's distance: the top 50 mm from the bottom.
        try bench.resizeFace(body: "Body 01", face: "top", value: 50)
        XCTAssertEqual(try SolidKernel.solid(for: bench.workspace.bodies[0]).bounds.max.z, 50, accuracy: 1e-6)
        // Names and colors.
        try bench.rename(item: "Body 01", to: "Base")
        try bench.setColor(body: "Base", color: "Red")
        XCTAssertEqual(bench.workspace.bodies[0].color, .red)
        XCTAssertTrue(bench.summary().contains("Base: "))
        XCTAssertThrowsError(try bench.setColor(body: "Base", color: "plaid"))
        // A hole, then its wall deleted again.
        var plate = try boxBench()
        try plate.hole(body: "Body 01", face: "top", kind: .simple, size: "", diameter: 6, depth: nil)
        let drilled = try volume(plate)
        XCTAssertLessThan(drilled, 48_000)
        let solid = try SolidKernel.solid(for: plate.workspace.bodies[0])
        let wall = try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil })
        try plate.resizeFace(body: "Body 01", face: String(wall), value: 10)
        XCTAssertEqual(try volume(plate), 48_000 - .pi * 25 * 20, accuracy: 1e-3)
        let resized = try SolidKernel.solid(for: plate.workspace.bodies[0])
        let newWall = try XCTUnwrap((0..<resized.faceCount).first { resized.faceCylinder($0) != nil })
        try plate.deleteFaces(body: "Body 01", faces: [String(newWall)])
        XCTAssertEqual(try volume(plate), 48_000, accuracy: 1e-3)
        // Sketch shapes: an ellipse, a hexagon, a point, a construction line; then an offset and a tapered, symmetric extrusion.
        var sketch = AssistantWorkbench(workspace: Workspace())
        try sketch.addShapes([Input(kind: .ellipse, point: .zero, width: 20, height: 10),
                              Input(kind: .polygon, point: [40, 0, 0], diameter: 20, sides: 6),
                              Input(kind: .point, point: [0, 30, 0]),
                              Input(kind: .line, point: [-30, -30, 0], end: [-30, 30, 0], construction: true)], on: .world(.top))
        XCTAssertEqual(sketch.workspace.shapes.count, 1 + 6 + 1 + 1)
        XCTAssertTrue(sketch.summary().contains("(construction)"))
        try sketch.offsetShape("Ellipse 01", distance: 2, bothSides: false)
        try sketch.extrude(sketch: "Sketch 01", regions: [2], distance: 10, mode: .newBody, throughAll: false, symmetric: true, taper: 5)
        let body = try XCTUnwrap(sketch.workspace.bodies.first)
        XCTAssertEqual(body.symmetric, true)
        XCTAssertEqual(body.taper, 5)
        XCTAssertThrowsError(try sketch.extrude(sketch: "Sketch 01", regions: [1], distance: 10, mode: .cut, throughAll: true, symmetric: true))
    }

    func testLinearAndCircularPatterns() throws {
        var bench = try boxBench()
        let volume = try volume(bench)
        let text = try bench.linearPattern(items: ["Body 01"], rows: [("x", 3, 70), ("-y", 2, 50)])
        XCTAssertTrue(text.contains("5 copies"), text)
        XCTAssertEqual(bench.workspace.bodies.count, 6)
        XCTAssertEqual(try SolidKernel.solid(for: bench.workspace.bodies[5]).volume, volume, accuracy: 1e-3, "Each copy is the whole solid")
        XCTAssertThrowsError(try bench.linearPattern(items: ["Body 01"], rows: [("x", 11, 70), ("y", 10, 70)]), "Over 100 instances")
        XCTAssertThrowsError(try bench.linearPattern(items: ["Body 01"], rows: [("sideways", 3, 70)]))

        var ring = AssistantWorkbench(workspace: Workspace())
        try ring.addShapes([Input(kind: .circle, point: [30, 0, 0], diameter: 6)], on: .world(.top))
        try ring.circularPattern(items: ["Sketch 01"], axis: "z", center: .zero, count: 6, angle: 360, rotateCopies: true)
        XCTAssertEqual(ring.workspace.sketches.count, 6)
        let centers = ring.workspace.shapes.map { $0.plane.point($0.start) }
        XCTAssertTrue(centers.contains { simd_distance($0, SIMD3(-30, 0, 0)) < 1e-6 }, "Half way round")
        XCTAssertThrowsError(try ring.circularPattern(items: ["Sketch 01"], axis: "z", center: .zero, count: 1, angle: 360, rotateCopies: true))
    }

    func testRefusedChangesExplainAndKeepTheDraft() throws {
        var bench = try boxBench()
        let before = bench.workspace
        XCTAssertThrowsError(try bench.finish(.fillet, body: "Body 01", edges: "top", size: 50)) {
            XCTAssertTrue(($0 as! AssistantWorkbench.Failure).message.contains("smaller"))
        }
        XCTAssertThrowsError(try bench.shell(body: "Body 01", openFaces: ["top"], thickness: 0.05))
        XCTAssertThrowsError(try bench.hole(body: "Body 01", face: "top", kind: .simple, size: "M8", depth: nil))
        XCTAssertThrowsError(try bench.addShapes([Input(kind: .rectangle, point: .zero, width: 0, height: 5)], on: .world(.top)))
        XCTAssertThrowsError(try bench.addShapes([Input(kind: .circle, point: .zero)], on: .world(.top)))
        XCTAssertThrowsError(try bench.setDimension(item: "Body 01", dimension: "width", value: 10))
        XCTAssertEqual(bench.workspace, before)
        XCTAssertEqual(bench.changes.count, 2)
    }

    func testSlotsArcsRoundedCornersMeasureAndFilletsOnCutEdges() throws {
        var bench = try boxBench()
        // A 20 × 6 slot cut 3 deep into the top, and a ⌀8 hole through it.
        try bench.addShapes([Input(kind: .slot, point: SIMD3(0, 0, 20), width: 20, height: 6)], on: .world(.top))
        let slot = try XCTUnwrap(bench.workspace.shapes.last)
        XCTAssertEqual(slot.kind, .slot)
        XCTAssertEqual(slot.width, 6)
        XCTAssertEqual(slot.start.distance(to: slot.end), 14, accuracy: 1e-9)
        try bench.hole(body: "Body 01", face: "top", at: [SIMD3(20, 10, 20)], kind: .simple, size: "", diameter: 8, depth: nil)
        // The hole's rim is made by a cut; it still takes a fillet.
        let solid = try SolidKernel.solid(for: bench.workspace.bodies[0])
        let rim = try XCTUnwrap((0..<solid.edgeCount).first { edge in
            guard let circle = solid.edgeCircle(edge) else { return false }
            return abs(circle.radius - 4) < 1e-6 && abs(circle.center.z - 20) < 1e-6
        })
        let reply = try bench.finish(.fillet, body: "Body 01", edges: "edge \(rim)", size: 1)
        XCTAssertTrue(reply.hasPrefix("Fillet 1 mm on 1 edge of Body 01"), reply)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.last?.operation, .finish)
        // Arcs need three points.
        try bench.addShapes([Input(kind: .arc, point: SIMD3(-10, 0, 0), end: SIMD3(10, 0, 0), through: SIMD3(0, 0, 10))], on: .world(.front))
        XCTAssertEqual(bench.workspace.shapes.last?.kind, .arc)
        XCTAssertThrowsError(try bench.addShapes([Input(kind: .arc, point: .zero, end: SIMD3(10, 0, 0))], on: .world(.top)))
        // Rounded corners before extruding.
        try bench.addShapes([Input(kind: .rectangle, point: SIMD3(100, 0, 0), width: 30, height: 20)], on: .world(.top))
        let rounded = try bench.roundCorners(sketch: bench.name(of: .sketch(bench.workspace.sketches.last!.id)), radius: 4)
        XCTAssertTrue(rounded.hasPrefix("Rounded 4 corners"), rounded)
        // Measuring.
        XCTAssertTrue(try bench.measure("Body 01", nil).contains("Volume"))
        let gap = try bench.measure("Body 01 face top", "origin")
        XCTAssertTrue(gap.contains("Distance 20 mm"), gap)
    }
}
