import XCTest
import simd
@testable import SwipeAndSketchCore

/// A sketch drawn on a solid's face (October 30, 2026): the face's edges bound regions with the
/// sketch, so the face less what is drawn on it can be extruded or cut as well as what is drawn.
final class FaceAreaTests: XCTestCase {
    /// The top face of `body` (outward normal +z) and its plane.
    func top(of body: SolidBody) throws -> (solid: KernelSolid, face: Int, plane: SketchPlane) {
        let solid = try SolidKernel.solid(for: body)
        let face = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { simd_dot($0.normal, .init(0, 0, 1)) > 0.9999 } ?? false })
        let plane = try XCTUnwrap(solid.facePlane(face).flatMap { SketchPlane.through($0.origin, normal: $0.normal) })
        return (solid, face, plane)
    }

    /// A workspace holding `body` and one sketch of `shapes` drawn on its top face.
    func faceSketch(on body: SolidBody, _ shapes: (SketchPlane) -> [SketchShape]) throws -> (workspace: Workspace, sketch: Sketch, plane: SketchPlane) {
        let top = try top(of: body)
        var sketch = Sketch(id: UUID(), plane: top.plane)
        sketch.faceEdges = try XCTUnwrap(top.solid.faceEdges(top.face, on: top.plane))
        var workspace = Workspace(shapes: [])
        workspace.bodies = [body]
        workspace.sketches = [sketch]
        workspace.shapes = shapes(top.plane).map { var shape = $0; shape.sketch = sketch.id; return shape }
        XCTAssertTrue(workspace.isValid)
        return (workspace, sketch, top.plane)
    }

    func circle(_ plane: SketchPlane, at center: Point2 = .zero, radius: Double) -> SketchShape {
        SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: radius, y: 0))
    }

    /// The 10 × 10 × 2 block with a ⌀3 circle in the middle of its top.
    func blockWithCircle() throws -> (body: SolidBody, circle: SketchShape, inside: SketchProfile, outside: SketchProfile) {
        let body = try box(-5, -5, 5, 5, depth: 2)
        let (workspace, sketch, _) = try faceSketch(on: body) { [circle(radius: 1.5, $0)] }
        let regions = workspace.profiles(in: sketch)
        XCTAssertEqual(regions.count, 2, "The circle, and the face around it")
        let inside = try XCTUnwrap(regions.first { !$0.isFaceArea }), outside = try XCTUnwrap(regions.first(where: \.isFaceArea))
        return (body, workspace.shapes[0], inside, outside)
    }

    func circle(radius: Double, _ plane: SketchPlane) -> SketchShape { circle(plane, radius: radius) }

    func testTheFaceAroundACircleIsARegionWithTheCircleAsItsHole() throws {
        let (_, circle, inside, outside) = try blockWithCircle()
        XCTAssertEqual(inside.id, circle.id.uuidString, "The circle's own region is unchanged")
        XCTAssertEqual(inside.area, .pi * 2.25, accuracy: 0.01, "(its outline is sampled every 3°)")
        XCTAssertEqual(outside.holes?.count, 1)
        XCTAssertEqual(outside.holes?.first?.circle?.radius ?? 0, 1.5, accuracy: 1e-9, "The hole is the exact circle")
        XCTAssertEqual(outside.area, 100 - .pi * 2.25, accuracy: 0.01)
        XCTAssertEqual(outside.sourceIDs, [circle.id], "It is bounded by the circle")
        XCTAssertTrue(outside.isSolidProfile)
        XCTAssertTrue(outside.contains(.init(x: 4, y: 4)))
        XCTAssertFalse(outside.contains(.zero), "The circle is not part of it")
        XCTAssertFalse(inside.contains(.init(x: 4, y: 4)))
    }

    func testTheFaceAroundCutsInLeavingTheCircleStanding() throws {
        var (body, _, _, outside) = try blockWithCircle()
        body.cuts = [ExtrusionCut(profile: outside, depth: -1, operation: .cut)]
        XCTAssertTrue(body.isValid)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 200 - (100 - .pi * 2.25), accuracy: 1e-3)
        XCTAssertEqual(solid.bounds.max.z, 2, accuracy: 1e-9, "The circle stands at the face's height")
    }

    func testTheFaceAroundCutThroughAllLeavesOnlyThePin() throws {
        var (body, _, _, outside) = try blockWithCircle()
        body.cuts = [ExtrusionCut(profile: outside, depth: -1, throughAll: true, operation: .cut)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertEqual(solid.volume, .pi * 2.25 * 2, accuracy: 1e-3)
        XCTAssertEqual(solid.bounds.max.x, 1.5, accuracy: 1e-6)
    }

    func testTheFaceAroundJoinsOutwardLeavingAPocket() throws {
        var (body, _, _, outside) = try blockWithCircle()
        body.cuts = [ExtrusionCut(profile: outside, depth: 3, operation: .join)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 200 + (100 - .pi * 2.25) * 3, accuracy: 1e-3)
        XCTAssertEqual(solid.bounds.max.z, 5, accuracy: 1e-9)
    }

    func testTheFaceAroundExtrudesAsANewBody() throws {
        let (_, _, _, outside) = try blockWithCircle()
        let ring = SolidBody(profile: outside, depth: 4)
        XCTAssertTrue(ring.isValid)
        XCTAssertEqual(try SolidKernel.solid(for: ring).volume, (100 - .pi * 2.25) * 4, accuracy: 1e-3)
        let revolved = SolidBody(profile: outside, revolve: RevolveSpec(from: .init(x: 6, y: -5), to: .init(x: 6, y: 5), angle: 90))
        XCTAssertTrue(revolved.isValid, "It revolves like any region")
        XCTAssertTrue(try SolidKernel.solid(for: revolved).isValidSolid)
    }

    func testAFaceWithAHoleKeepsItsHoleInTheFaceAround() throws {
        var body = try box(-5, -5, 5, 5, depth: 2)
        let lid = try XCTUnwrap(SketchPlane.through(.init(0, 0, 2), normal: .init(0, 0, 1)))
        body.cuts = [try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.simple, size: "M3"), at: .init(x: -2.5, y: -2.5), on: lid, depth: nil))]
        let (workspace, sketch, plane) = try faceSketch(on: body) { [circle($0, at: .init(x: 2, y: 2), radius: 1)] }
        XCTAssertEqual(sketch.faceEdges?.filter { $0.kind == .circle }.count, 1, "The face's hole is one of its edges")
        let regions = workspace.profiles(in: sketch)
        XCTAssertEqual(regions.count, 2, "The circle and the face around it; the face's hole is no region")
        let outside = try XCTUnwrap(regions.first(where: \.isFaceArea))
        XCTAssertEqual(outside.holes?.count, 2)
        XCTAssertEqual(outside.area, 100 - .pi * 1.7 * 1.7 - .pi, accuracy: 0.02)
        XCTAssertFalse(outside.contains(plane.coordinates(of: .init(-2.5, -2.5, 2))), "The face's hole stays open")
        var cut = body
        cut.cuts.append(ExtrusionCut(profile: outside, depth: -1, operation: .cut))
        XCTAssertEqual(try SolidKernel.solid(for: cut).volume, try SolidKernel.solid(for: body).volume - (100 - .pi * 1.7 * 1.7 - .pi), accuracy: 1e-3)
    }

    func testARoundFaceKeepsItsExactCircle() throws {
        let disc = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 10, y: 0))
        let body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [disc], on: .top).first), depth: 5)
        let (workspace, sketch, _) = try faceSketch(on: body) { [SketchShape(kind: .rectangle, plane: $0, start: .init(x: -2, y: -3), end: .init(x: 2, y: 3))] }
        let outside = try XCTUnwrap(workspace.profiles(in: sketch).first(where: \.isFaceArea))
        XCTAssertEqual(outside.circle?.radius ?? 0, 10, accuracy: 1e-9, "The face's rim stays an exact circle")
        XCTAssertEqual(outside.holes?.count, 1)
        XCTAssertEqual(outside.area, .pi * 100 - 24, accuracy: 0.2)
        XCTAssertEqual(try SolidKernel.solid(for: SolidBody(profile: outside, depth: 1)).volume, .pi * 100 - 24, accuracy: 1e-3)
    }

    func testASlotShapedFaceKeepsItsExactArcs() throws {
        let slot = SketchShape(kind: .slot, plane: .top, start: .init(x: -10, y: 0), end: .init(x: 10, y: 0), width: 8)
        let body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [slot], on: .top).first), depth: 3)
        let (workspace, sketch, _) = try faceSketch(on: body) { [circle($0, at: .init(x: 10, y: 0), radius: 2)] }
        XCTAssertEqual(sketch.faceEdges?.filter { $0.kind == .arc }.count, 2)
        let outside = try XCTUnwrap(workspace.profiles(in: sketch).first(where: \.isFaceArea))
        XCTAssertEqual(outside.arcs?.count, 2, "The round ends stay exact arcs")
        XCTAssertEqual(outside.area, 20 * 8 + .pi * 16 - .pi * 4, accuracy: 0.05)
        XCTAssertEqual(try SolidKernel.solid(for: SolidBody(profile: outside, depth: 1)).volume, 20 * 8 + .pi * 16 - .pi * 4, accuracy: 1e-3)
    }

    func testALineAcrossTheFaceDividesItInTwo() throws {
        let body = try box(-5, -5, 5, 5, depth: 2)
        let (workspace, sketch, _) = try faceSketch(on: body) { [SketchShape(kind: .line, plane: $0, start: .init(x: 0, y: -5), end: .init(x: 0, y: 5))] }
        let regions = workspace.profiles(in: sketch)
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions.allSatisfy(\.isFaceArea))
        for region in regions { XCTAssertEqual(region.area, 50, accuracy: 1e-9) }
        XCTAssertNotEqual(regions[0].id, regions[1].id)
    }

    func testADrawnShapeCrossingTheFaceEdgeStaysWhole() throws {
        let body = try box(-5, -5, 5, 5, depth: 2)
        let (workspace, sketch, _) = try faceSketch(on: body) { [SketchShape(kind: .rectangle, plane: $0, start: .init(x: 3, y: -1), end: .init(x: 8, y: 1))] }
        let regions = workspace.profiles(in: sketch)
        let drawn = try XCTUnwrap(regions.first { !$0.isFaceArea })
        XCTAssertEqual(drawn.area, 10, accuracy: 1e-9, "The rectangle is still all of itself")
        let outside = try XCTUnwrap(regions.first(where: \.isFaceArea))
        XCTAssertEqual(outside.area, 100 - 4, accuracy: 1e-9, "The face less the part of the rectangle on it")
    }

    func testShapesOffTheFaceAddNoRegion() throws {
        let body = try box(-5, -5, 5, 5, depth: 2)
        let (workspace, sketch, _) = try faceSketch(on: body) { [self.circle($0, at: .init(x: 20, y: 0), radius: 2)] }
        XCTAssertEqual(workspace.profiles(in: sketch).count, 1, "The face alone is picked as a face, not a region")
        XCTAssertFalse(workspace.profiles(in: sketch).contains(where: \.isFaceArea))
        // A sketch without face edges is unchanged.
        let plain = Sketch(id: sketch.id, plane: sketch.plane)
        XCTAssertEqual(Geometry.profiles(in: workspace.shapes, on: plain.plane).count, 1)
    }

    func testTwoSketchesOnOneFaceOfferOneFaceAroundBoth() throws {
        let body = try box(-5, -5, 5, 5, depth: 2)
        var (workspace, first, plane) = try faceSketch(on: body) { [circle($0, at: .init(x: -2.5, y: 0), radius: 1)] }
        var second = Sketch(id: UUID(), plane: plane)
        second.faceEdges = first.faceEdges
        workspace.sketches.append(second)
        let other = SketchShape(kind: .circle, plane: plane, start: .init(x: 2.5, y: 0), end: .init(x: 3.5, y: 0), sketch: second.id)
        workspace.shapes.append(other)
        XCTAssertTrue(workspace.isValid)
        let outside = try XCTUnwrap(workspace.profiles(in: first).first(where: \.isFaceArea))
        XCTAssertEqual(outside.holes?.count, 2, "What the other sketch draws on the face is left out too")
        XCTAssertEqual(outside.sourceIDs.first, workspace.shapes[0].id, "It belongs to the first sketch")
        XCTAssertFalse(workspace.profiles(in: second).contains(where: \.isFaceArea), "Only one sketch offers it")
        XCTAssertEqual(workspace.profiles(in: second).count, 1)
        // Hide the first: the second offers it instead, around its own circle only.
        workspace.sketches[0].hidden = true
        let visible = workspace.visible
        let alone = try XCTUnwrap(visible.profiles(in: visible.sketches[0]).first(where: \.isFaceArea))
        XCTAssertEqual(alone.holes?.count, 1)
        XCTAssertEqual(alone.sourceIDs, [other.id])
    }

    func testRegionsStayTheSameEveryTime() throws {
        let body = try box(-5, -5, 5, 5, depth: 2)
        let id = UUID()
        func regions() throws -> [String] {
            let (workspace, sketch, _) = try faceSketch(on: body) { [SketchShape(id: id, kind: .circle, plane: $0, start: .zero, end: .init(x: 1, y: 0))] }
            return workspace.profiles(in: sketch).map(\.id)
        }
        XCTAssertEqual(try regions(), try regions())
        XCTAssertTrue(try regions().contains { $0.hasPrefix(SketchProfile.faceAreaPrefix) && $0.contains(id.uuidString) })
    }

    func testFaceEdgesAreSavedAndReadBack() throws {
        let body = try box(-5, -5, 5, 5, depth: 2)
        let (workspace, sketch, _) = try faceSketch(on: body) { [circle(radius: 1.5, $0)] }
        let data = try JSONEncoder().encode(workspace)
        let read = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(read.sketches.first?.faceEdges, sketch.faceEdges)
        XCTAssertEqual(read.profiles(in: read.sketches[0]).map(\.id), workspace.profiles(in: sketch).map(\.id))
        // Sketches not drawn on a face write no face edges.
        var plain = workspace
        plain.sketches[0].faceEdges = nil
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("faceEdges"))
        // Damaged face edges are refused, not dropped.
        var damaged = workspace
        damaged.sketches[0].faceEdges = [FaceEdge(kind: .rectangle, start: .zero, end: .init(x: 1, y: 1))]
        XCTAssertFalse(damaged.isValid)
    }

    func testScalingOrMirroringASketchInPlaceForgetsTheFace() throws {
        let body = try box(-5, -5, 5, 5, depth: 2)
        let (workspace, sketch, _) = try faceSketch(on: body) { [circle(radius: 1.5, $0)] }
        let moved = try XCTUnwrap(workspace.transformingSketch(sketch.id, by: .move(.init(0, 0, 5)), copy: false))
        XCTAssertNotNil(moved.workspace.sketch(sketch.id)?.faceEdges, "Moving keeps the face with the sketch, in its own coordinates")
        let mirrored = try XCTUnwrap(Mirroring.mirror(workspace, bodies: [], sketches: [sketch.id], across: .right, keepOriginals: false))
        XCTAssertNil(mirrored.workspace.sketch(sketch.id)?.faceEdges)
        XCTAssertFalse(mirrored.workspace.profiles(in: mirrored.workspace.sketches[0]).contains(where: \.isFaceArea))
    }
}
