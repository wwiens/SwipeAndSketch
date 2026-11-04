import XCTest
import simd
@testable import SwipeAndSketchCore

/// Shapes joined end to end (a double-tapped sketch line, October 30, 2026).
final class SketchChainTests: XCTestCase {
    func line(_ a: Point2, _ b: Point2) -> SketchShape { SketchShape(kind: .line, plane: .top, start: a, end: b) }

    /// An L of two lines closed by an arc, a rectangle with a line from one corner, a line that
    /// crosses the L without meeting its ends, and a circle on its own, all in one Top sketch.
    func sketch() throws -> (workspace: Workspace, l: [UUID], rectangle: [UUID], crossing: UUID, circle: UUID) {
        let a = line(.init(x: 0, y: 0), .init(x: 20, y: 0)), b = line(.init(x: 20, y: 0), .init(x: 20, y: 20))
        let arc = try XCTUnwrap(SketchShape.arc(from: .init(x: 20, y: 20), to: .init(x: 0, y: 0), sweep: .pi / 2, plane: .top))
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 40, y: 0), end: .init(x: 50, y: 10))
        let tail = line(.init(x: 50, y: 10), .init(x: 60, y: 20))
        let crossing = line(.init(x: 10, y: -5), .init(x: 10, y: 5))
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: -20, y: 0), end: .init(x: -15, y: 0))
        let workspace = Workspace(shapes: [a, b, arc, rectangle, tail, crossing, circle])
        XCTAssertEqual(workspace.sketches.count, 1, "One sketch holds them all")
        return (workspace, [a.id, b.id, arc.id], [rectangle.id, tail.id], crossing.id, circle.id)
    }

    func testTheChainFollowsSharedEndsAndCornersOnly() throws {
        let (workspace, l, rectangle, crossing, circle) = try sketch()
        XCTAssertEqual(SketchEditing.chain(from: l[1], in: workspace), l, "Lines and the arc meeting end to end, in document order")
        XCTAssertEqual(SketchEditing.chain(from: rectangle[1], in: workspace), rectangle, "A line from a rectangle's corner joins it")
        XCTAssertEqual(SketchEditing.chain(from: crossing, in: workspace), [crossing], "Crossing a line partway is not joining it")
        XCTAssertEqual(SketchEditing.chain(from: circle, in: workspace), [circle], "A circle has no ends to join")
        XCTAssertEqual(SketchEditing.chain(from: UUID(), in: workspace), [])
    }

    func testAChainInAnotherSketchOnTheSamePlaneStaysApart() throws {
        var workspace = Workspace(shapes: [line(.init(x: 0, y: 0), .init(x: 10, y: 0))])
        let other = Sketch(id: UUID(), plane: .top)
        workspace.sketches.append(other)
        var touching = line(.init(x: 10, y: 0), .init(x: 10, y: 10))
        touching.sketch = other.id
        workspace.shapes.append(touching)
        XCTAssertEqual(SketchEditing.chain(from: workspace.shapes[0].id, in: workspace), [workspace.shapes[0].id])
    }

    func testAChainMovesAndCopiesWithinItsSketchAndStaysJoined() throws {
        let (workspace, l, _, crossing, _) = try sketch()
        let moved = try XCTUnwrap(workspace.transforming(.shapes(l), by: .move([5, 0, 0]), copy: false))
        guard case .shapes(let ids) = moved.target else { return XCTFail("The chain moved") }
        XCTAssertEqual(ids, l)
        let shapes = l.compactMap { id in moved.workspace.shapes.first { $0.id == id } }
        XCTAssertEqual(shapes[0].start, .init(x: 5, y: 0))
        XCTAssertEqual(shapes[1].end, .init(x: 25, y: 20))
        XCTAssertEqual(shapes[2].start.distance(to: shapes[1].end), 0, accuracy: 1e-9, "The arc still meets the line")
        XCTAssertEqual(moved.workspace.shapes.first { $0.id == crossing }?.start, .init(x: 10, y: -5), "The rest of the sketch stays")
        XCTAssertNil(workspace.transforming(.shapes(l), by: .move([0, 0, 5]), copy: false), "A chain never leaves its plane")

        let turned = try XCTUnwrap(workspace.transforming(.shapes(l), by: .rotate(degrees: 90, about: [0, 0, 1], through: [100, 0, 0]), copy: true))
        guard case .shapes(let copies) = turned.target else { return XCTFail("The chain was copied") }
        XCTAssertEqual(copies.count, 3)
        XCTAssertTrue(Set(copies).isDisjoint(with: l), "Copies are new shapes")
        XCTAssertEqual(turned.workspace.shapes.count, workspace.shapes.count + 3)
        XCTAssertEqual(Set(turned.workspace.shapes.filter { copies.contains($0.id) }.map(\.sketch)), [workspace.sketches[0].id], "Copies go in the same sketch")
        let copied = try XCTUnwrap(turned.workspace.shapes.first { $0.id == copies[0] })
        XCTAssertEqual(copied.end.x, 100, accuracy: 1e-9, "Turned a quarter about x = 100")
        XCTAssertEqual(copied.end.y, -80, accuracy: 1e-9)
        XCTAssertEqual(SketchEditing.chain(from: copies[0], in: turned.workspace), copies, "The copies are joined to each other only")
        XCTAssertNotNil(workspace.center(ofShapes: l))
    }
}
