import XCTest
@testable import SwipeAndSketchCore

final class AssistantRequirementTests: XCTestCase {
    func block() throws -> Workspace {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        let profile = try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first)
        return Workspace(bodies: [SolidBody(profile: profile, depth: 20)])
    }
    func plan(_ requirements: [AssistantRequirement], request: String, workspace: Workspace) throws -> AssistantRequirementPlan {
        try .init(requirements, request: request, workspace: workspace, selection: nil)
    }

    func testFinalBoundsAreMeasuredAndExplicitSizesCannotBeSubstituted() throws {
        var workspace = try block()
        let request = "Make a block 60 by 40 by 20 mm."
        let check = AssistantRequirement(quote: request, kind: "bodySize", target: "Body 01", expected: [60, 40, 20])
        let p = try plan([check], request: request, workspace: workspace)
        XCTAssertEqual(p.evaluate(in: workspace).results[0].status, .passed)
        workspace.bodies[0].depth = 10
        XCTAssertEqual(p.evaluate(in: workspace).results[0].status, .unmet)
        workspace.bodies[0].depth = 20.004
        let smallMismatch = p.evaluate(in: workspace).results[0]
        XCTAssertEqual(smallMismatch.status, .unmet)
        XCTAssertTrue(smallMismatch.detail.contains("20.004"), "The displayed precision must expose a mismatch larger than the tolerance")
        var substituted = check; substituted.expected = [60, 40, 10]
        XCTAssertEqual(try plan([substituted], request: request, workspace: workspace).evaluate(in: workspace).results[0].status, .notChecked)
    }

    func testHoleLocationAxisDepthAndFinishedVoidAreChecked() throws {
        let workspace = try block()
        let request = "Drill a 10 mm hole through the middle of the top."
        let check = AssistantRequirement(quote: request, kind: "hole", target: "Body 01", expected: [0, 0, 20, 0, 0, 1, 10, -1])
        let p = try plan([check], request: request, workspace: workspace)
        var bench = AssistantWorkbench(workspace: workspace)
        try bench.hole(body: "Body 01", face: "top", kind: .simple, size: "", diameter: 10, depth: nil)
        XCTAssertEqual(p.evaluate(in: bench.workspace).results[0].status, .passed)
        // Wrong position has the same bounds and volume, but must not pass.
        var offset = AssistantWorkbench(workspace: workspace)
        try offset.hole(body: "Body 01", face: "top", at: [SIMD3(10, 0, 20)], kind: .simple, size: "", diameter: 10, depth: nil)
        XCTAssertEqual(try SolidKernel.solid(for: bench.workspace.bodies[0]).volume,
                       try SolidKernel.solid(for: offset.workspace.bodies[0]).volume, accuracy: 0.001)
        XCTAssertEqual(p.evaluate(in: offset.workspace).results[0].status, .unmet)
        var wrongAxis = check; wrongAxis.expected[3] = 1; wrongAxis.expected[5] = 0
        XCTAssertEqual(try plan([wrongAxis], request: request, workspace: workspace).evaluate(in: bench.workspace).results[0].status, .unmet)
        var blind = AssistantWorkbench(workspace: workspace)
        try blind.hole(body: "Body 01", face: "top", kind: .simple, size: "", diameter: 10, depth: 5)
        XCTAssertEqual(p.evaluate(in: blind.workspace).results[0].status, .unmet)
        var blindCheck = check; blindCheck.quote = "10 mm hole, 5 mm deep"; blindCheck.expected[7] = 5
        XCTAssertEqual(try plan([blindCheck], request: blindCheck.quote, workspace: workspace).evaluate(in: blind.workspace).results[0].status, .passed)
        try blind.hole(body: "Body 01", face: "top", kind: .simple, size: "", diameter: 10, depth: 8)
        XCTAssertEqual(try plan([blindCheck], request: blindCheck.quote, workspace: workspace).evaluate(in: blind.workspace).results[0].status, .unmet)
        var widened = bench
        try widened.hole(body: "Body 01", face: "top", kind: .simple, size: "", diameter: 12, depth: nil)
        XCTAssertEqual(p.evaluate(in: widened.workspace).results[0].status, .unmet, "Old feature history cannot certify an enlarged hole")
        // A later union fills the hole, while the original hole entry is still in history.
        let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        let profile = try XCTUnwrap(Geometry.profiles(in: [circle], on: .top).first)
        var filled = bench.workspace
        filled.bodies[0].cuts.append(.merge(SolidBody(profile: profile, depth: 20)))
        XCTAssertEqual(p.evaluate(in: filled).results[0].status, .unmet)
        // An equivalent Boolean-only construction must pass without native hole metadata.
        var booleanHole = workspace
        booleanHole.bodies[0].cuts.append(.subtract(SolidBody(profile: profile, depth: 20), clearance: nil))
        XCTAssertEqual(p.evaluate(in: booleanHole).results[0].status, .passed)
        // A through-hole's physical entry follows the new top, even though its saved cut plane
        // remains at the original height after a depth edit.
        var taller = bench.workspace; taller.bodies[0].depth = 30
        var topEntry = check; topEntry.expected[2] = 30
        XCTAssertEqual(try plan([topEntry], request: request, workspace: workspace).evaluate(in: taller).results[0].status, .passed)
    }

    func testBoundIdentitySurvivesRenameAndDoesNotFollowOrdinalNames() throws {
        var workspace = try block()
        let request = "Keep Body 01 at 60 by 40 by 20 mm."
        let check = AssistantRequirement(quote: request, kind: "bodySize", target: "Body 01", expected: [60, 40, 20])
        let p = try plan([check], request: request, workspace: workspace)
        workspace.bodies[0].name = "Plate"
        XCTAssertEqual(p.evaluate(in: workspace).results[0].status, .passed)
        workspace.bodies[0].id = UUID()
        XCTAssertEqual(p.evaluate(in: workspace).results[0].status, .unmet)
    }

    func testPlannedNewBodyBindsOnlyOnceAndPreservationUsesOriginalDefinition() throws {
        let workspace = try block(), request = "Make one body 60 by 40 by 20 mm."
        let check = AssistantRequirement(quote: request, kind: "bodySize", target: "Body 01", expected: [60, 40, 20])
        var p = try plan([check], request: request, workspace: Workspace())
        XCTAssertEqual(p.evaluate(in: Workspace()).results[0].status, .unmet)
        p.bindTargets(in: workspace, selection: nil)
        XCTAssertEqual(p.evaluate(in: workspace).results[0].status, .passed)
        let replacement = try block()
        p.bindTargets(in: replacement, selection: nil)
        XCTAssertEqual(p.evaluate(in: replacement).results[0].status, .unmet)
        let preserve = AssistantRequirement(quote: "Leave the block unchanged.", kind: "unchangedBody", target: "Body 01", expected: [])
        let unchanged = try plan([preserve], request: preserve.quote, workspace: workspace)
        XCTAssertEqual(unchanged.evaluate(in: workspace).results[0].status, .passed)
        var changed = workspace; changed.bodies[0].depth = 21
        XCTAssertEqual(unchanged.evaluate(in: changed).results[0].status, .unmet)
    }

    func testUnknownMissingAndInvalidChecksNeverBecomePasses() throws {
        let workspace = try block()
        let requirements = [
            AssistantRequirement(quote: "Invented source", kind: "bodyCount", expected: [1]),
            AssistantRequirement(quote: "one body", kind: "futureCheck", expected: []),
            AssistantRequirement(quote: "one body", kind: "bodySize", target: "Body 01", expected: [.nan, 40, 20]),
            AssistantRequirement(quote: "one body", kind: "bodyCount", expected: [1.5]),
            AssistantRequirement(quote: "2 inch walls", kind: "bodySize", target: "Body 01", expected: [2, 2, 2]),
            AssistantRequirement(quote: "2 mm walls", kind: "notChecked", expected: [])
        ]
        let report = try plan(requirements, request: "one body with 2 inch walls, then 2 mm walls", workspace: workspace).evaluate(in: workspace)
        XCTAssertTrue(report.results.allSatisfy { $0.status == .notChecked })
        XCTAssertTrue(report.needsReview)
        XCTAssertThrowsError(try plan([], request: "", workspace: workspace))
        XCTAssertThrowsError(try plan(Array(repeating: requirements[0], count: 25), request: "", workspace: workspace))
        XCTAssertEqual(AssistantRequirementReport().summary, "Requirements not checked")
    }

    func testCountsIncludeHiddenBodiesAndUnsupportedCoverageStaysVisible() throws {
        var workspace = try block(); workspace.bodies[0].hidden = true
        let request = "Keep one body and 2 mm walls."
        let report = try plan([.init(quote: "one body", kind: "bodyCount", expected: [1]),
                               .init(quote: "2 mm walls", kind: "notChecked", expected: [])], request: request, workspace: workspace).evaluate(in: workspace)
        XCTAssertEqual(report.results.map(\.status), [.passed, .notChecked])
        XCTAssertEqual(report.summary, "1 passed · 0 unmet · 1 not checked")
        XCTAssertEqual(try JSONDecoder().decode(AssistantRequirementReport.self, from: JSONEncoder().encode(report)), report)
    }

    func testRoundedSlotEndCannotPassAsASimpleRoundHole() throws {
        let workspace = try block()
        var bench = AssistantWorkbench(workspace: workspace)
        try bench.addShapes([.init(kind: .slot, point: [0, 0, 20], width: 20, height: 10)],
                            on: .face(body: workspace.bodies[0].id, face: "top"))
        try bench.extrude(sketch: "Sketch 01", regions: [], distance: -20, mode: .cut, throughAll: true)
        let request = "Drill a 10 mm through-hole at the top."
        let check = AssistantRequirement(quote: request, kind: "hole", target: "Body 01", expected: [5, 0, 20, 0, 0, 1, 10, -1])
        XCTAssertNotEqual(try plan([check], request: request, workspace: workspace).evaluate(in: bench.workspace).results[0].status, .passed)
    }

    func testOffsetHolesUseEntryCoordinatesOnCanonicalTopFrontAndRightPlanes() throws {
        let workspace = try block()
        for (face, entry, normal) in [("top", SIMD3<Double>(20, 8, 20), SIMD3<Double>(0, 0, 1)),
                                      ("front", SIMD3<Double>(12, -20, 10), SIMD3<Double>(0, -1, 0)),
                                      ("right", SIMD3<Double>(30, -8, 10), SIMD3<Double>(1, 0, 0))] {
            for depth in [nil, 4.0] as [Double?] {
                var bench = AssistantWorkbench(workspace: workspace)
                try bench.hole(body: "Body 01", face: face, at: [entry], kind: .simple, size: "", diameter: 6, depth: depth)
                let request = "Drill a 6 mm hole, 4 mm deep or through all."
                let check = AssistantRequirement(quote: request, kind: "hole", target: "Body 01",
                                                 expected: [entry.x, entry.y, entry.z, normal.x, normal.y, normal.z, 6, depth ?? -1])
                let result = try plan([check], request: request, workspace: workspace).evaluate(in: bench.workspace).results[0]
                XCTAssertEqual(result.status, .passed, "\(face), depth \(String(describing: depth)): \(result.detail)")
            }
        }
    }
}
