import XCTest
@testable import SwipeAndSketch

/// Fit Test parts commit at once, undo as one step, and stay ordinary editable solids.
@MainActor final class GeneratedPartTests: XCTestCase {
    func testFitTestCommitsImmediatelyAndUndoesAsOneStep() {
        let session = ModelingSession(inMemory: true)
        let before = session.workspace
        session.addFitTest()
        let result = session.workspace
        XCTAssertFalse(result.bodies.isEmpty)
        XCTAssertNotEqual(result, before)
        session.undo()
        XCTAssertEqual(session.workspace, before)
        session.redo()
        XCTAssertEqual(session.workspace, result)
    }

    func testGeneratedSolidsRemainEditable() throws {
        let session = ModelingSession(inMemory: true)
        session.addFitTest()
        let before = session.workspace
        let body = try XCTUnwrap(before.bodies.first)
        session.selection = .body(body.id)
        session.deleteSelection()
        XCTAssertEqual(session.workspace.bodies.count, before.bodies.count - 1)
        session.undo()
        XCTAssertEqual(session.workspace, before)
    }
}
