import XCTest
import simd
@testable import SwipeAndSketchCore

/// The assistant reaches the newer tools (October 26, 2026): several picked solids and edges, Plane
/// at Angle, Tangent Plane, Extend, and the construction and sweep operations.
final class AssistantReachTests: XCTestCase {
    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    func testSeveralPickedSolidsStandForSelectedInLists() throws {
        let a = try box(-10, -10, 10, 10, depth: 10), b = try box(5, -10, 25, 10, depth: 10)
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [a, b]), selection: .several([.body(a.id), .body(b.id)]))
        XCTAssertTrue(bench.selectionDescription().hasPrefix("2 solids"), bench.selectionDescription())
        // A single-item operation says which to name.
        XCTAssertThrowsError(try bench.item(named: "selected")) { error in
            XCTAssertTrue((error as? AssistantWorkbench.Failure)?.message.contains("2 solids") == true)
        }
        _ = try bench.setColor(body: "selected", color: "red")
        XCTAssertEqual(bench.workspace.bodies.map(\.color), [.red, .red])
        _ = try bench.transform(items: ["selected"], move: [0, 0, 5], rotate: 0, axis: "z", pivot: nil, copy: false)
        for body in bench.workspace.bodies {
            XCTAssertEqual(try SolidKernel.solid(for: body).bounds.min.z, 5, accuracy: 1e-6)
        }
        // Combine: the first picked is the target, the rest the tools.
        let change = try bench.combine(union: true, target: "selected", tools: ["selected"], keepTools: false)
        XCTAssertTrue(change.contains("Body 01"), change)
        XCTAssertEqual(bench.workspace.bodies.count, 1)
    }

    func testSeveralPickedEdgesAreFilletedTogether() throws {
        let block = try box(-10, -10, 10, 10, depth: 20)
        let vertical = try AssistantWorkbench(workspace: Workspace(bodies: [block])).edges("vertical", of: block)
        XCTAssertEqual(vertical.count, 4)
        let picked = Array(vertical.prefix(2))
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [block]), selection: .several(picked.map { .edge(bodyID: block.id, edge: $0) }))
        XCTAssertEqual(try bench.edges("selected", of: block), picked)
        XCTAssertEqual(try bench.item(named: "selected"), .body(block.id), "Edges stand for their solid")
        _ = try bench.finish(.fillet, body: "selected", edges: "selected", size: 2)
        // Two vertical edges rounded: each loses (4 − π) × 20 mm³.
        XCTAssertEqual(try volume(bench.workspace.bodies[0]), 8000 - 2 * (4 - .pi) * 20, accuracy: 0.5)
    }

    func testPlaneAtAngleAboutASketchLine() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        _ = try bench.addShapes([.init(kind: .line, point: [0, 0, 0], end: [20, 0, 0])], on: .world(.top))
        _ = try bench.addPlaneAtAngle(line: "Line 01", degrees: 90)
        let upright = try XCTUnwrap(bench.workspace.constructionPlanes.last?.plane)
        XCTAssertEqual(upright.normalAxis.z, 0, accuracy: 1e-9, "90° stands straight up from Top")
        XCTAssertEqual(abs(upright.normalAxis.y), 1, accuracy: 1e-9)
        _ = try bench.addPlaneAtAngle(line: "Line 01", degrees: 30)
        let slanted = try XCTUnwrap(bench.workspace.constructionPlanes.last?.plane)
        XCTAssertEqual(abs(slanted.normalAxis.z), cos(.pi / 6), accuracy: 1e-9)
        XCTAssertThrowsError(try bench.addPlaneAtAngle(line: "Sketch 01", degrees: 30))
    }

    func testTangentPlaneTouchesARoundFaceOnTheSideAsked() throws {
        let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        let cylinder = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [circle], on: .top).first), depth: 20)
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [cylinder]))
        let change = try bench.addTangentPlane(body: "Body 01", face: "round", side: "front")
        XCTAssertTrue(change.contains("Ø10"), change)
        let plane = try XCTUnwrap(bench.workspace.constructionPlanes.last?.plane)
        XCTAssertEqual(plane.normalAxis.y, -1, accuracy: 1e-9)
        XCTAssertEqual(plane.origin.y, -5, accuracy: 1e-6)
        XCTAssertThrowsError(try bench.addTangentPlane(body: "Body 01", face: "round", side: "top"), "Top runs along the axis")
    }

    func testExtendCarriesALineToTheNextShape() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        _ = try bench.addShapes([.init(kind: .line, point: [0, 0, 0], end: [10, 0, 0]),
                                 .init(kind: .line, point: [30, -10, 0], end: [30, 10, 0])], on: .world(.top))
        let change = try bench.extendLine("Line 01", end: nil)
        XCTAssertEqual(change, "Extended Line 01 at its end.", "Nothing lies behind its start")
        XCTAssertEqual(bench.workspace.shapes[0].end.x, 30, accuracy: 1e-9)
        XCTAssertThrowsError(try bench.extendLine("Line 01", end: "end"), "It already meets the other line")
    }

    func testConstructionPlaneAndAxisThroughPoints() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        _ = try bench.addConstruction(kind: "plane", points: [[0, 0, 5], [10, 0, 5], [0, 10, 5]])
        let plane = try XCTUnwrap(bench.workspace.constructionPlanes.first?.plane)
        XCTAssertEqual(plane.normalAxis.z, 1, accuracy: 1e-9)
        XCTAssertEqual(plane.origin.z, 5, accuracy: 1e-9)
        XCTAssertThrowsError(try bench.addConstruction(kind: "plane", points: [[0, 0, 0], [1, 0, 0], [2, 0, 0]]), "Points in a line")
        let axis = try bench.addConstruction(kind: "axis", points: [[0, 0, 0], [0, 0, 30]])
        XCTAssertTrue(axis.contains("Axis 01"), axis)
        XCTAssertEqual(bench.workspace.shapes.last?.isConstruction, true)
    }

    func testSweepCarriesARegionAlongALine() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        // A Ø6 circle on Front, and a 30 mm path along +Y from its center on Top.
        _ = try bench.addShapes([.init(kind: .circle, point: [0, 0, 0], diameter: 6)], on: .world(.front))
        _ = try bench.addShapes([.init(kind: .line, point: [0, 0, 0], end: [0, 30, 0])], on: .world(.top))
        let change = try bench.sweep(sketch: "Sketch 01", path: "Line 01")
        XCTAssertTrue(change.lowercased().contains("swept"), change)
        let tube = try XCTUnwrap(bench.workspace.bodies.last)
        XCTAssertEqual(try volume(tube), .pi * 9 * 30, accuracy: 1)
    }
}
