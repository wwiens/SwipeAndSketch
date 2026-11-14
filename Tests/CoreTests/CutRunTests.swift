import XCTest
import simd
@testable import SwipeAndSketchCore

/// A run of plain cuts is subtracted in one boolean when a solid is built from its history
/// (November 11, 2026). The result must be the solid that applying each cut in turn makes.
final class CutRunTests: XCTestCase {
    /// A 6-sided pocket (or through hole) of `radius` centered at (`x`, `y`) on the plate's top.
    private func hexagon(_ x: Double, _ y: Double, radius: Double = 3, depth: Double = -4, throughAll: Bool = false,
                         on plane: SketchPlane) throws -> ExtrusionCut {
        let center = Point2(x: x, y: y)
        let lines = SketchTools.polygon(center: center, vertex: Point2(x: x + radius, y: y), sides: 6, plane: plane)
        let profile = try XCTUnwrap(Geometry.profiles(in: lines, on: plane).first)
        return ExtrusionCut(profile: profile, depth: depth, throughAll: throughAll)
    }

    /// A 100 × 80 × 8 mm plate and its top plane.
    private func plate() throws -> (body: SolidBody, top: SketchPlane) {
        (try box(-50, -40, 50, 40, depth: 8), try XCTUnwrap(SketchPlane.through(.init(0, 0, 8), normal: .init(0, 0, 1))))
    }

    /// Hexagons over the plate, every fifth through all.
    private func honeycomb(on top: SketchPlane, rows: Int = 6, columns: Int = 8) throws -> [ExtrusionCut] {
        var cuts: [ExtrusionCut] = []
        for row in 0..<rows { for column in 0..<columns {
            let x = -42 + Double(column) * 12 + (row % 2 == 0 ? 0 : 6), y = -32 + Double(row) * 12
            cuts.append(try hexagon(x, y, throughAll: cuts.count % 5 == 4, on: top))
        } }
        return cuts
    }

    /// `body` built in a cache of its own: one step at a time (every earlier step first, oldest
    /// first, so each builds on the one before), or straight away, with its runs of cuts together.
    private func built(_ body: SolidBody, stepByStep: Bool) throws -> KernelSolid {
        let cache = SolidCache()
        if stepByStep {
            var prefix = body
            prefix.cuts = []
            for count in 0..<body.cuts.count {
                prefix.cuts = Array(body.cuts[..<count])
                _ = try cache.solid(for: prefix)
            }
        }
        return try cache.solid(for: body)
    }

    private func assertSame(_ a: KernelSolid, _ b: KernelSolid, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.volume, b.volume, accuracy: 1e-6 * max(1, b.volume), "Volume", file: file, line: line)
        XCTAssertEqual(a.faceCount, b.faceCount, "Faces", file: file, line: line)
        XCTAssertEqual(a.edgeCount, b.edgeCount, "Edges", file: file, line: line)
        XCTAssertEqual(a.isValidSolid, b.isValidSolid, "Validity", file: file, line: line)
    }

    func testARunOfCutsBuildsAsEachCutInTurn() throws {
        var (body, top) = try plate()
        body.cuts = try honeycomb(on: top)
        let together = try built(body, stepByStep: false), inTurn = try built(body, stepByStep: true)
        assertSame(together, inTurn)
        XCTAssertTrue(together.isValidSolid)
        XCTAssertLessThan(together.volume, 100 * 80 * 8 - 48 * 4 * 23)
    }

    func testOnlyTheSolidBeforeTheNewestStepIsKept() throws {
        var (body, top) = try plate()
        body.cuts = try honeycomb(on: top, rows: 2, columns: 5)
        let cache = SolidCache()
        _ = try cache.solid(for: body)
        var before = body
        before.cuts.removeLast()
        XCTAssertNotNil(cache.built(before), "A live preview of the newest step builds on this")
        before.cuts.removeLast()
        XCTAssertNil(cache.built(before), "Inside the run: subtracted together, not one at a time")
        // An earlier step is then built from the solid before the run.
        let earlier = try cache.solid(for: before)
        assertSame(earlier, try built(before, stepByStep: true))
    }

    func testTheBackgroundPassLeavesOutTheStepsInsideARun() throws {
        var (body, top) = try plate()
        let cells = try honeycomb(on: top, rows: 2, columns: 8)
        let bossShape = SketchShape(kind: .rectangle, plane: top, start: .init(x: -50, y: 34), end: .init(x: 50, y: 40))
        let boss = ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [bossShape], on: top).first), depth: 4, operation: .join)
        // 10 cuts, a boss, 6 cuts.
        body.cuts = Array(cells[0..<10]) + [boss] + Array(cells[10...])
        func prefix(_ count: Int) -> SolidBody { var prefix = body; prefix.cuts = Array(body.cuts[..<count]); return prefix }
        let cache = SolidCache()
        cache.buildSteps(of: body) { true }
        XCTAssertNotNil(cache.built(prefix(0)), "The base")
        XCTAssertNil(cache.built(prefix(5)), "Inside the first run")
        XCTAssertNotNil(cache.built(prefix(10)), "The end of the first run, which the boss builds on")
        XCTAssertNotNil(cache.built(prefix(11)), "The boss, which the second run builds on")
        XCTAssertNil(cache.built(prefix(14)), "Inside the second run")
        XCTAssertNotNil(cache.built(prefix(16)), "The step before the newest, which a preview of it builds on")
        for count in [5, 14] { assertSame(try cache.solid(for: prefix(count)), try built(prefix(count), stepByStep: true)) }
        // Editing a cut inside a run builds from the step before the run.
        var edited = body
        edited.cuts[4].depth = -2
        assertSame(try cache.solid(for: edited), try built(edited, stepByStep: true))
    }

    func testJoinsFinishesAndFaceCutsSplitTheRuns() throws {
        var (body, top) = try plate()
        let cells = try honeycomb(on: top)
        var cuts = Array(cells[0..<12])
        // A boss, then more cuts, a face cut, more cuts, a fillet by point on an edge a cut made, more cuts.
        let bossShape = SketchShape(kind: .rectangle, plane: top, start: .init(x: -50, y: 34), end: .init(x: 50, y: 40))
        cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [bossShape], on: top).first), depth: 4, operation: .join))
        cuts += cells[12..<24]
        // The plate's left side pushed in by 1 mm.
        let plain = try SolidKernel.solid(for: body)
        let side = try XCTUnwrap((0..<plain.faceCount).first { plain.facePlane($0).map { simd_dot($0.normal, .init(-1, 0, 0)) > 0.9999 } ?? false })
        let faceCut = try XCTUnwrap(FaceExtrusionSource(body: body, face: side)).operation(depth: -1)
        XCTAssertNotNil(faceCut.facePoint)
        cuts.append(faceCut)
        cuts += cells[24..<36]
        body.cuts = cuts
        // A hexagon's top edge: from (x + 3, y) to (x + 1.5, y + 2.6) on the plate's top.
        let cell = cells[30].profile.outline
        let corner = top.origin + top.xAxis * cell[0].x + top.yAxis * cell[0].y
        let next = top.origin + top.xAxis * cell[1].x + top.yAxis * cell[1].y
        let solid = try built(body, stepByStep: true)
        let edge = try XCTUnwrap(solid.edge(near: (corner + next) / 2), "The cut made this edge")
        let reference = try XCTUnwrap(body.edgeReference(edge, of: solid))
        body.cuts.append(.finish(of: body, FinishSpec(kind: .fillet, size: 0.5, edges: [reference])))
        body.cuts += cells[36...]
        XCTAssertTrue(body.isValid)
        let together = try built(body, stepByStep: false), inTurn = try built(body, stepByStep: true)
        assertSame(together, inTurn)
        XCTAssertLessThan(together.volume, solid.volume, "The fillet and later cuts took material away")
    }

    func testCutsThatSeparateThePlateStillMatch() throws {
        var (body, top) = try plate()
        // Two slots across the plate, through all, leave three pieces; then pockets in each.
        let slots = try [-15.0, 15.0].map { x -> ExtrusionCut in
            let shape = SketchShape(kind: .rectangle, plane: top, start: .init(x: x - 1, y: -45), end: .init(x: x + 1, y: 45))
            return ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: top).first), depth: 0, throughAll: true)
        }
        body.cuts = slots + (try [-35.0, 0, 35].map { try hexagon($0, 0, on: top) }) + [try hexagon(0, 20, on: top)]
        assertSame(try built(body, stepByStep: false), try built(body, stepByStep: true))
    }

    func testARunThatRemovesTheWholeSolidFailsAsBefore() throws {
        var (body, top) = try plate()
        let halves = try [(-60.0, 0.0), (0.0, 60.0)].map { range -> ExtrusionCut in
            let shape = SketchShape(kind: .rectangle, plane: top, start: .init(x: range.0, y: -45), end: .init(x: range.1, y: 45))
            return ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: top).first), depth: 0, throughAll: true)
        }
        body.cuts = halves + [try hexagon(0, 0, on: top)]
        XCTAssertThrowsError(try built(body, stepByStep: false)) { error in
            XCTAssertEqual((error as? SolidKernel.Failure)?.message, "The cut would remove the whole solid")
        }
    }
}
