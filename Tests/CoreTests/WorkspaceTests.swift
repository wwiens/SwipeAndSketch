import XCTest
@testable import SwipeAndSketchCore

final class WorkspaceTests: XCTestCase {
    let shape = SketchShape(kind: .rectangle, plane: .front, start: .zero, end: .init(x: 40, y: 25))

    func testUndoRedoAndNewEditClearsRedo() {
        var history = WorkspaceHistory()
        var workspace = Workspace(shapes: [shape])
        history.commit(workspace)
        XCTAssertTrue(history.canUndo)
        history.undo()
        XCTAssertTrue(history.workspace.shapes.isEmpty)
        history.redo()
        XCTAssertEqual(history.workspace, workspace)
        history.undo()
        workspace.shapes[0].end.x = 50
        history.commit(workspace)
        XCTAssertFalse(history.canRedo)
    }
    func testExtrusionsAreIndependentOfSourceSketch() {
        let profile = Geometry.profiles(in: [shape], on: .front)[0]
        var workspace = Workspace(shapes: [shape], bodies: [SolidBody(profile: profile, depth: 30)])
        workspace.shapes.removeAll()
        XCTAssertTrue(workspace.isValid)
        XCTAssertEqual(workspace.bodies[0].profile.outline[1].x, 40)
    }
}
