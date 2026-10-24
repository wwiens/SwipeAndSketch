import XCTest
import simd
@testable import SwipeAndSketchCore

/// Groups moved, turned, and duplicated as a unit (October 24, 2026).
final class GroupUnitTests: XCTestCase {
    /// A group holding a box, a sketch, and a nested group with a second box; a third box outside.
    func grouped() throws -> (Workspace, outer: UUID, inner: UUID) {
        var workspace = Workspace(bodies: [try box(0, 0, 10, 10, depth: 5), try box(20, 0, 30, 10, depth: 5), try box(-40, 0, -30, 10, depth: 5)])
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 50, y: 0), end: .init(x: 55, y: 0))
        workspace.sketches = [Sketch(id: circle.id, plane: .top)]
        var shape = circle
        shape.sketch = circle.id
        workspace.shapes = [shape]
        let outer = try XCTUnwrap(workspace.addingGroup(containing: [.body(workspace.bodies[0].id), .sketch(circle.id)], name: "Lid"))
        let inner = try XCTUnwrap(outer.workspace.addingGroup(in: outer.group, containing: [.body(workspace.bodies[1].id)]))
        return (inner.workspace, outer.group, inner.group)
    }

    func testMovingAGroupMovesItsNestedGroupsAndNothingElse() throws {
        let (workspace, outer, _) = try grouped()
        let moved = try XCTUnwrap(workspace.transformingGroup(outer, by: .move([0, 0, 7]), copy: false))
        XCTAssertEqual(moved.group, outer)
        XCTAssertEqual(try SolidKernel.solid(for: moved.workspace.bodies[0]).bounds.min.z, 7, accuracy: 1e-9)
        XCTAssertEqual(try SolidKernel.solid(for: moved.workspace.bodies[1]).bounds.min.z, 7, accuracy: 1e-9, "Inside the nested group")
        XCTAssertEqual(moved.workspace.bodies[2], workspace.bodies[2], "Outside the group")
        XCTAssertEqual(moved.workspace.shapes[0].plane.origin.z, 7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(workspace.center(ofGroup: outer)).x, 27.5, accuracy: 1e-9)
    }

    func testACopyOfAGroupCopiesItsTree() throws {
        let (workspace, outer, inner) = try grouped()
        let copied = try XCTUnwrap(workspace.transformingGroup(outer, by: .move([100, 0, 0]), copy: true))
        XCTAssertNotEqual(copied.group, outer)
        XCTAssertEqual(copied.workspace.groups.count, 4)
        XCTAssertEqual(copied.workspace.group(copied.group)?.name, "Lid")
        let nested = try XCTUnwrap(copied.workspace.groups.first { $0.parent == copied.group })
        XCTAssertNotEqual(nested.id, inner)
        XCTAssertEqual(copied.workspace.contents(of: copied.group).bodies.count, 2)
        XCTAssertEqual(copied.workspace.contents(of: copied.group).sketches.count, 1)
        XCTAssertEqual(copied.workspace.bodies.count, 5)
        XCTAssertEqual(copied.workspace.bodies[0], workspace.bodies[0], "The original stays")
        XCTAssertEqual(copied.workspace.shapes.count, 2)
        XCTAssertTrue(copied.workspace.isValid)
    }

    func testAssistantMovesAGroupByName() throws {
        let (workspace, _, _) = try grouped()
        var bench = AssistantWorkbench(workspace: workspace)
        let text = try bench.transform(items: ["Lid"], move: [0, 15, 0], rotate: 0, axis: "z", pivot: nil, copy: false)
        XCTAssertTrue(text.contains("Lid"), text)
        XCTAssertEqual(try SolidKernel.solid(for: bench.workspace.bodies[1]).bounds.min.y, 15, accuracy: 1e-9)
        XCTAssertEqual(bench.workspace.bodies[2], workspace.bodies[2])
    }
}
