import XCTest
@testable import SwipeAndSketchCore

final class SketchObjectTests: XCTestCase {
    func rectangle(_ plane: SketchPlane, sketch: UUID? = nil) -> SketchShape {
        SketchShape(kind: .rectangle, plane: plane, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10), sketch: sketch)
    }

    func testOlderFilesGetOneSketchPerPlaneAndSaveUnchanged() throws {
        let top = rectangle(.top), front = rectangle(.front), second = rectangle(.top)
        let workspace = Workspace(shapes: [top, front, second])
        XCTAssertEqual(workspace.sketches.map(\.id), [top.id, front.id], "Named by each plane's first shape")
        XCTAssertEqual(workspace.shapes.map(\.sketch), [top.id, front.id, top.id])
        XCTAssertTrue(workspace.isValid)
        XCTAssertTrue(workspace.sketchesAreImplicit)
        let project = Project(workspace: workspace)
        let data = try ProjectCodec.encode(project)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("sketches"))
        XCTAssertFalse(text.contains("\"sketch\""))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, workspace)
    }

    func testSeveralSketchesOnOnePlaneRoundTripAndKeepTheirRegions() throws {
        var workspace = Workspace(shapes: [rectangle(.top)])
        let second = Sketch(id: UUID(), plane: .top)
        workspace.sketches.append(second)
        // An overlapping square in its own sketch: each sketch finds its own regions.
        workspace.shapes.append(SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 20), sketch: second.id))
        XCTAssertTrue(workspace.isValid)
        XCTAssertFalse(workspace.sketchesAreImplicit)
        XCTAssertEqual(workspace.profiles.count, 2)
        XCTAssertEqual(workspace.profiles(in: second).count, 1)
        let project = Project(workspace: workspace)
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, workspace)
    }

    func testHiddenSketchesAndSolidsAreSavedAndLeaveTheCanvas() throws {
        var workspace = Workspace(shapes: [rectangle(.top), rectangle(.front)])
        let profile = try XCTUnwrap(workspace.profiles.first)
        workspace.bodies = [SolidBody(profile: profile, depth: 5)]
        workspace.sketches[1].hidden = true
        workspace.bodies[0].hidden = true
        let visible = workspace.visible
        XCTAssertEqual(visible.shapes.count, 1)
        XCTAssertEqual(visible.sketches.count, 1)
        XCTAssertTrue(visible.bodies.isEmpty)
        XCTAssertEqual(workspace.profiles.count, 1, "Hidden sketches have no regions to pick")
        XCTAssertEqual(try SolidKernel.solid(for: workspace.bodies[0]).volume, 2_000, accuracy: 1e-6, "Hiding changes nothing about the solid")
        let project = Project(workspace: workspace)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(project)).workspace, workspace)
    }

    func testShapesMustMatchTheirSketch() throws {
        var workspace = Workspace(shapes: [rectangle(.top)])
        workspace.shapes[0].plane = .front
        XCTAssertFalse(workspace.isValid, "A shape lies on its sketch's plane")
        let json = #"{"version":1,"shapes":[{"id":"\#(UUID().uuidString)","kind":"line","plane":"top","start":{"x":0,"y":0},"end":{"x":5,"y":0},"sketch":"\#(UUID().uuidString)"}],"bodies":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Workspace.self, from: Data(json.utf8)), "A shape cannot name a sketch the file does not have")
    }

    func testJoinedEndpointsOnlyFollowWithinOneSketch() throws {
        let a = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 20, y: 0))
        var workspace = Workspace(shapes: [a])
        let other = Sketch(id: UUID(), plane: .top)
        workspace.sketches.append(other)
        workspace.shapes.append(SketchShape(kind: .line, plane: .top, start: a.end, end: .init(x: 20, y: 20), sketch: other.id))
        let moved = try XCTUnwrap(SketchEditing.dragging(workspace.shapes[0], handle: .end, to: .init(x: 30, y: 0)))
        let result = try XCTUnwrap(SketchEditing.replacing(moved, in: workspace))
        XCTAssertEqual(result.shapes[1].start, a.end, "A line in another sketch stays put")
    }
}
