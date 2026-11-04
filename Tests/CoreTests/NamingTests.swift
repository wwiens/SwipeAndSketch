import XCTest
import simd
@testable import SwipeAndSketchCore

/// Names, colors, and copy and paste in the Model Tree.
final class NamingTests: XCTestCase {
    func workspace() throws -> Workspace {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 10))
        let profile = try XCTUnwrap(Geometry.profiles(in: [rectangle], on: .top).first)
        var space = Workspace(shapes: [rectangle], bodies: [SolidBody(profile: profile, depth: 10), SolidBody(profile: profile, depth: 5)])
        space.constructionPlanes = [ConstructionPlane(plane: .top, width: 10, height: 10)]
        return space
    }

    func testChosenNamesNumberedNamesAndRepeats() throws {
        var space = try workspace()
        XCTAssertEqual(space.bodies.map { space.bodyNames[$0.id] }, ["Body 01", "Body 02"])
        space = try XCTUnwrap(space.renaming(body: space.bodies[1].id, to: "  Lid\n "))
        XCTAssertEqual(space.bodies[1].name, "Lid")
        space = try XCTUnwrap(space.renaming(body: space.bodies[0].id, to: "lid"))
        XCTAssertEqual(space.bodies.map { space.bodyNames[$0.id] }, ["lid", "Lid (2)"], "A repeated name gets a number")
        space = try XCTUnwrap(space.renaming(body: space.bodies[0].id, to: "   "))
        XCTAssertNil(space.bodies[0].name, "An empty name goes back to its number")
        XCTAssertEqual(space.bodyNames[space.bodies[0].id], "Body 01")
        let sketch = try XCTUnwrap(space.sketches.first)
        space = try XCTUnwrap(space.renaming(sketch: sketch.id, to: "Outline"))
        XCTAssertEqual(space.sketchNames[sketch.id], "Outline")
        space = try XCTUnwrap(space.renaming(plane: space.constructionPlanes[0].id, to: "Lid line"))
        XCTAssertEqual(space.planeNames[space.constructionPlanes[0].id], "Lid line")
        XCTAssertTrue(space.isValid)
        XCTAssertEqual(ItemNames.cleaned(String(repeating: "x", count: 100))?.count, ItemNames.maximumLength)
        // Names and colors save and load.
        space.bodies[1].color = .blue
        let project = Project(workspace: space)
        XCTAssertEqual(try ProjectCodec.decode(try ProjectCodec.encode(project)).workspace, space)
        var gray = space
        gray.bodies[1].color = .gray
        XCTAssertFalse(gray.isValid, "Gray is the default and is not saved")
        // The assistant finds items by their chosen names.
        let bench = AssistantWorkbench(workspace: space)
        XCTAssertEqual(try bench.item(named: "lid"), .body(space.bodies[1].id))
        XCTAssertEqual(try bench.item(named: "outline"), .sketch(sketch.id))
        XCTAssertEqual(bench.name(of: .plane(space.constructionPlanes[0].id)), "Lid line")
    }

    func testCopyAndPasteMakeNewItemsWhereTheOriginalsWere() throws {
        var space = try workspace()
        space.bodies[0].name = "Bracket"
        let clipboard = space.copying(bodies: [space.bodies[0].id], sketches: [space.sketches[0].id])
        XCTAssertEqual(clipboard.title, "2 items")
        XCTAssertEqual(space.copying(bodies: [space.bodies[0].id], sketches: []).title, "Bracket")
        let pasted = try XCTUnwrap(space.pasting(clipboard))
        XCTAssertEqual(pasted.workspace.bodies.count, 3)
        XCTAssertEqual(pasted.workspace.sketches.count, 2)
        let copy = try XCTUnwrap(pasted.workspace.bodies.first { $0.id == pasted.bodies[0] })
        XCTAssertNotEqual(copy.id, space.bodies[0].id)
        XCTAssertEqual(copy.profile, space.bodies[0].profile, "Right where it was")
        XCTAssertEqual(pasted.workspace.bodyNames[copy.id], "Bracket (2)")
        XCTAssertEqual(pasted.workspace.shapes.filter { $0.sketch == pasted.sketches[0] }.count, 1)
        XCTAssertTrue(pasted.workspace.isValid)
        // Into another project: an empty one.
        let other = try XCTUnwrap(Workspace().pasting(clipboard))
        XCTAssertEqual(other.workspace.bodies.count, 1)
        XCTAssertEqual(other.workspace.shapes.count, 1)
    }
}
