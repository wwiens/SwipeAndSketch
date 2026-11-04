import XCTest
import simd
@testable import SwipeAndSketchCore

/// Structural feedback after topology-changing steps: positional names that a
/// step retires or shifts are reported by identity, so a model need not reuse a stale name.
final class AssistantStructureTests: XCTestCase {
    /// Three rectangles, each in its own sketch, as in the stale-reference reproduction.
    func threeSketches() throws -> AssistantWorkbench {
        var bench = AssistantWorkbench(workspace: Workspace())
        for (x, w) in [(-40.0, 30.0), (0, 20), (40, 16)] {
            try bench.addShapes([.init(kind: .rectangle, point: [x, 0, 0], width: w, height: 20)], on: .world(.top))
        }
        return bench
    }

    func testRoundingRetiresTheRectangleAndRenumbersTheOthers() throws {
        var bench = try threeSketches()
        let before = bench.workspace
        let second = try bench.item(named: "Rectangle 02"), third = try bench.item(named: "Rectangle 03")
        try bench.roundCorners(sketch: "Sketch 01", radius: 4)
        // The hazard itself: the old name now resolves to a different shape, or to none.
        XCTAssertEqual(try bench.item(named: "Rectangle 02"), third)
        XCTAssertEqual(try bench.item(named: "Rectangle 01"), second)
        XCTAssertThrowsError(try bench.item(named: "Rectangle 03"))
        let note = try XCTUnwrap(bench.structuralChanges(since: before))
        XCTAssertTrue(note.contains("Retired, no longer usable: Rectangle 01 (in Sketch 01)."), note)
        XCTAssertTrue(note.contains("Rectangle 02 → Rectangle 01; Rectangle 03 → Rectangle 02"), note)
        XCTAssertTrue(note.contains("New in Sketch 01: Line 01–04, Arc 01–04."), note)
        XCTAssertTrue(note.contains("Its regions now: 1 "), note)
        // Every name the note offers for the new outline resolves into Sketch 01.
        let sketch = try bench.sketch(named: "Sketch 01").id
        for name in ["Line 01", "Line 04", "Arc 01", "Arc 04"] {
            guard case .shape(let id) = try bench.item(named: name) else { return XCTFail(name) }
            XCTAssertEqual(bench.workspace.shapes.first { $0.id == id }?.sketch, sketch)
        }
        // The note describes; it changes nothing it describes.
        XCTAssertEqual(bench.workspace.shapes.filter { $0.kind == .rectangle }.map(\.id), before.shapes.filter { $0.kind == .rectangle }.dropFirst().map(\.id))
    }

    func testOffsetNamesTheNewOutlineAndItsRegions() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        try bench.addShapes([.init(kind: .rectangle, point: .zero, width: 60, height: 40)], on: .world(.top))
        try bench.roundCorners(sketch: "Sketch 01", radius: 5)
        let before = bench.workspace
        try bench.offsetShape("Line 01", distance: -3, bothSides: false)
        let note = try XCTUnwrap(bench.structuralChanges(since: before))
        XCTAssertFalse(note.contains("Retired"), note)
        XCTAssertFalse(note.contains("Now named"), note)
        XCTAssertTrue(note.contains("New in Sketch 01: Line 05–08, Arc 05–08."), note)
        XCTAssertTrue(note.contains("Its regions now: 1 ") && note.contains("; 2 "), note)
    }

    func testDeletingABodyRenumbersTheBodiesAfterIt() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        for x in [-40.0, 0, 40] {
            try bench.primitive(kind: "box", sizes: [20, 20, 10], at: [x, 0, 0])
        }
        let ids = bench.workspace.bodies.map(\.id)
        let before = bench.workspace
        try bench.delete(items: ["Body 01"])
        let note = try XCTUnwrap(bench.structuralChanges(since: before))
        XCTAssertTrue(note.contains("Retired, no longer usable: Body 01."), note)
        XCTAssertTrue(note.contains("Body 02 → Body 01; Body 03 → Body 02"), note)
        XCTAssertEqual(try bench.body(named: "Body 02").id, ids[2])
        XCTAssertThrowsError(try bench.body(named: "Body 03"))
    }

    func testRenamingIsReportedAndPositionalNamesKeepResolving() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        try bench.primitive(kind: "box", sizes: [20, 20, 10], at: .zero)
        let before = bench.workspace
        try bench.rename(item: "Body 01", to: "Base")
        XCTAssertEqual(bench.structuralChanges(since: before), "Structure after this step (by identity):\nNow named (same item, new name; an old name may now mean another item): Body 01 → Base.")
        XCTAssertEqual(try bench.body(named: "Base").id, before.bodies[0].id)
    }

    func testCuttingKeepsTheSolidButRetiresItsFaceNumbers() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        try bench.primitive(kind: "box", sizes: [60, 40, 20], at: .zero)
        let before = bench.workspace
        try bench.hole(body: "Body 01", face: "top", kind: .simple, size: "", diameter: 10, depth: nil)
        let note = try XCTUnwrap(bench.structuralChanges(since: before))
        XCTAssertTrue(note.contains("Same solid, new faces and edges: Body 01 (faces 6 → 7, edges 12 → 15)."), note)
        XCTAssertFalse(note.contains("Retired"), note)
    }

    func testNewItemsAloneAddNothing() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        var before = bench.workspace
        try bench.addShapes([.init(kind: .rectangle, point: .zero, width: 60, height: 40)], on: .world(.top))
        XCTAssertNil(bench.structuralChanges(since: before))
        before = bench.workspace
        try bench.extrude(sketch: "Sketch 01", regions: [], distance: 10, mode: .newBody, throughAll: false)
        XCTAssertNil(bench.structuralChanges(since: before))
        // A resize keeps the solid's faces and edges, so it adds no note either.
        before = bench.workspace
        try bench.setDimension(item: "Body 01", dimension: "depth", value: 15)
        XCTAssertNil(bench.structuralChanges(since: before))
    }

    func testCompactRunsOfNames() {
        XCTAssertEqual(AssistantWorkbench.compact(["Line 09", "Line 10", "Line 11", "Arc 09", "Arc 11", "Box (2)"]),
                       "Line 09–11, Arc 09, Arc 11, Box (2)")
    }

    // MARK: Names as the model last saw them

    func testASameRoundRenumberedNameIsRefusedInsteadOfEditingAnotherShape() throws {
        var bench = try threeSketches()
        let start = bench.workspace
        bench.namesLastSeen = start
        try bench.roundCorners(sketch: "Sketch 01", radius: 4)
        let rounded = bench.workspace
        XCTAssertThrowsError(try bench.setDimension(item: "Rectangle 02", dimension: "width", value: 30)) { error in
            let message = (error as? AssistantWorkbench.Failure)?.message ?? ""
            XCTAssertTrue(message.hasPrefix("Rectangle 02 meant Rectangle 02 (in Sketch 02) when this call was sent"), message)
            XCTAssertTrue(message.contains("it is now Rectangle 01 (in Sketch 02), and Rectangle 02 now means Rectangle 02 (in Sketch 03)."), message)
            XCTAssertTrue(message.contains("send this call again with Rectangle 01"), message)
        }
        XCTAssertEqual(bench.workspace, rounded, "nothing changed")
        // The name of the rectangle that was rounded away is refused in the same round too.
        XCTAssertThrowsError(try bench.offsetShape("Rectangle 01", distance: -2, bothSides: false)) { error in
            XCTAssertTrue((error as? AssistantWorkbench.Failure)?.message.contains("replaced or deleted it") == true)
        }
        // Once the model has read the results, names mean what they mean now.
        bench.namesLastSeen = bench.workspace
        try bench.setDimension(item: "Rectangle 01", dimension: "width", value: 30)
        XCTAssertEqual(bench.workspace.shapes.first { $0.kind == .rectangle }?.sketch, start.sketches[1].id)
        // Without the guard, the same call widens Sketch 03's rectangle.
        var unguarded = try threeSketches()
        try unguarded.roundCorners(sketch: "Sketch 01", radius: 4)
        try unguarded.setDimension(item: "Rectangle 02", dimension: "width", value: 30)
        XCTAssertEqual(unguarded.workspace.shapes(in: unguarded.workspace.sketches[2].id).first?.end.x, 55, "Sketch 03's rectangle, 16 wide at x 40, became 30 wide")
    }

    func testDeletedBodiesShiftNamesOnlyAfterTheModelHasSeenIt() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        for x in [-40.0, 0, 40] { try bench.primitive(kind: "box", sizes: [20, 20, 10], at: [x, 0, 0]) }
        let ids = bench.workspace.bodies.map(\.id)
        bench.namesLastSeen = bench.workspace
        try bench.delete(items: ["Body 01"])
        XCTAssertThrowsError(try bench.body(named: "Body 03")) { error in
            XCTAssertTrue((error as? AssistantWorkbench.Failure)?.message.contains("it is now Body 02.") == true)
        }
        XCTAssertThrowsError(try bench.body(named: "Body 02"))
        bench.namesLastSeen = bench.workspace
        XCTAssertEqual(try bench.body(named: "Body 02").id, ids[2])
    }

    func testRenamesInTheSameRoundStillResolve() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        for x in [-40.0, 40] { try bench.primitive(kind: "box", sizes: [60, 40, 5], at: [x, 0, 0]) }
        bench.namesLastSeen = bench.workspace
        try bench.rename(item: "Body 02", to: "Lid")
        XCTAssertEqual(try bench.body(named: "Lid").id, bench.workspace.bodies[1].id)
        XCTAssertEqual(try bench.body(named: "Body 02").id, bench.workspace.bodies[1].id)
        try bench.hole(body: "Lid", face: "top", kind: .simple, size: "", diameter: 4, depth: nil)
    }

    func testANameRetiredEarlierInTheRequestSaysSo() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        try bench.addShapes([.init(kind: .rectangle, point: .zero, width: 60, height: 40)], on: .world(.top))
        bench.namesAtRequest = bench.workspace
        try bench.roundCorners(sketch: "Sketch 01", radius: 5)
        bench.namesLastSeen = bench.workspace
        XCTAssertThrowsError(try bench.offsetShape("Rectangle 01", distance: -3, bothSides: false)) { error in
            XCTAssertEqual((error as? AssistantWorkbench.Failure)?.message,
                           "Rectangle 01 (Rectangle 01 (in Sketch 01)) was replaced or deleted earlier in this request. Use the names from the latest results, or inspect the sketch or body to find them.")
        }
        bench.namesAtRequest = nil
        XCTAssertThrowsError(try bench.offsetShape("Rectangle 01", distance: -3, bothSides: false)) { error in
            XCTAssertTrue((error as? AssistantWorkbench.Failure)?.message.hasPrefix("There is no Rectangle 01") == true)
        }
    }
}

