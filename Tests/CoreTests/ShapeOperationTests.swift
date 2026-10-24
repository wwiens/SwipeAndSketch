import XCTest
import simd
@testable import SwipeAndSketchCore

/// Draft, Rib, Loft, and Sweep (October 24, 2026).
final class ShapeOperationTests: XCTestCase {
    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    func testDraftLeansSideFacesFromTheBase() throws {
        let block = try box(-10, -10, 10, 10, depth: 20)
        // Lean the four sides 5° in toward the top, pivoting on the base.
        let sides: [SIMD3<Double>] = [[10, 0, 10], [-10, 0, 10], [0, 10, 10], [0, -10, 10]]
        let drafted = try XCTUnwrap(Drafting.drafting(block, faces: sides, pull: [0, 0, 1], origin: .zero, angle: 5))
        XCTAssertEqual(drafted.cuts.map(\.operation), [.draft])
        let solid = try SolidKernel.solid(for: drafted)
        XCTAssertEqual(solid.bounds.min.x, -10, accuracy: 1e-4, "The base stays put")
        XCTAssertLessThan(try volume(drafted), 20 * 20 * 20, "Narrower toward the top")
        XCTAssertGreaterThan(try volume(drafted), 20 * 20 * 20 * 0.7)
        XCTAssertNil(Drafting.drafting(block, faces: [[0, 0, 20]], pull: [0, 0, 1], origin: .zero, angle: 5), "The top is square to the pull")

        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [drafted])))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [drafted])
        let mirrored = try XCTUnwrap(drafted.mirrored(by: try XCTUnwrap(Reflection(across: try XCTUnwrap(SketchPlane.through([0, 30, 0], normal: [0, 1, 0]))))))
        XCTAssertEqual(try volume(mirrored), try volume(drafted), accuracy: 1e-3)
    }

    func testARibFillsTheCornerOfAnLBracket() throws {
        // An L bracket: a 40 × 20 × 4 base with a 4 × 20 × 30 wall at x = 0…4.
        var bracket = try box(0, -10, 40, 10, depth: 4)
        let wall = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 0, y: -10), end: .init(x: 4, y: 10))
        bracket.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [wall], on: .top).first), depth: 30, operation: .join))
        let before = try volume(bracket)
        // A diagonal sketch line on Front (y = 0) from the wall high up to the base far out.
        let ribbed = try XCTUnwrap(Ribs.ribbing(bracket, from: [4, 0, 24], to: [34, 0, 4], normal: [0, -1, 0], thickness: 3))
        XCTAssertEqual(ribbed.cuts.last?.operation, .rib)
        // The triangle between the line, the wall, and the base: ½ × 30 × 20, 3 mm thick.
        XCTAssertEqual(try volume(ribbed) - before, 0.5 * 30 * 20 * 3, accuracy: 1)
        XCTAssertNil(Ribs.ribbing(bracket, from: [60, 0, 24], to: [80, 0, 30], normal: [0, -1, 0], thickness: 3), "Out in the open")
    }

    func testLoftAndSweep() throws {
        let square = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10))
        let upper = try XCTUnwrap(SketchPlane.through([0, 0, 20], normal: [0, 0, 1]))
        let circle = SketchShape(kind: .circle, plane: upper, start: .zero, end: .init(x: 6, y: 0))
        let bottom = try XCTUnwrap(Geometry.profiles(in: [square], on: .top).first), top = try XCTUnwrap(Geometry.profiles(in: [circle], on: upper).first)
        let loft = try ShapedSolids.loft([bottom, top], ruled: false)
        XCTAssertTrue(loft.isValidSolid)
        XCTAssertEqual(loft.bounds.max.z, 20, accuracy: 1e-4)
        XCTAssertLessThan(loft.volume, 400 * 20)
        XCTAssertGreaterThan(loft.volume, .pi * 36 * 20)

        let added = try XCTUnwrap(ShapedSolids.adding(loft, named: "Loft", to: Workspace()))
        XCTAssertEqual(added.workspace.bodies.first?.isImported, true)
        XCTAssertEqual(added.workspace.bodyNames[added.body], "Loft")

        // A Ø6 circle on Front (across the path where it starts) swept along a quarter arc in the Top plane.
        let section = try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: .circle, plane: .front, start: .init(x: 0, y: 0), end: .init(x: 3, y: 0))], on: .front).first)
        let arc = try XCTUnwrap(SketchShape.arc(from: .zero, through: Point2(x: 20 * (1 - cos(.pi / 4)), y: 20 * sin(.pi / 4)), to: Point2(x: 20, y: 20), plane: .top))
        let path = try XCTUnwrap(ShapedSolids.path(of: arc))
        XCTAssertTrue(path.smooth)
        let swept = try ShapedSolids.sweep(section, along: path.points, smooth: path.smooth)
        XCTAssertTrue(swept.isValidSolid)
        // A tube Ø6 along a quarter circle of radius 20: π × 9 × (π × 20 / 2).
        XCTAssertEqual(swept.volume, .pi * 9 * .pi * 10, accuracy: 3)
    }
}

extension ShapeOperationTests {
    func testAssistantDraftsAndLofts() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try box(-10, -10, 10, 10, depth: 20)]))
        let draft = try bench.draft(body: "Body 01", faces: ["front", "back"], from: "bottom", angle: 4)
        XCTAssertTrue(draft.contains("Drafted 2 faces"), draft)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.last?.operation, .draft)
        _ = try bench.addShapes([.init(kind: .rectangle, point: [40, 0, 0], width: 20, height: 20)], on: .world(.top))
        let upper = try XCTUnwrap(SketchPlane.through([0, 0, 15], normal: [0, 0, 1]))
        var next = bench.workspace
        next.constructionPlanes.append(ConstructionPlane(plane: upper, width: 50, height: 50))
        bench = AssistantWorkbench(workspace: next)
        _ = try bench.addShapes([.init(kind: .circle, point: [40, 0, 15], diameter: 12)], on: .construction(next.constructionPlanes[0].id))
        let loft = try bench.loft(sketches: ["Sketch 01", "Sketch 02"], ruled: false)
        XCTAssertTrue(loft.contains("Lofted"), loft)
        XCTAssertEqual(bench.workspace.bodies.last?.isImported, true)
    }
}
