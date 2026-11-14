import XCTest
import simd
@testable import SwipeAndSketchCore

final class AssistantTemplateTests: XCTestCase {
    func spec(_ reference: AssistantSlipLidBox.Reference = .inside, _ size: SIMD3<Double> = [80, 60, 40]) -> AssistantSlipLidBox {
        .init(reference: reference, width: size.x, depth: size.y, height: size.z, wall: 2, radius: 6, clearance: 0.2, vents: false)
    }
    func area(_ w: Double, _ d: Double, _ r: Double) -> Double { w * d - (4 - .pi) * r * r }

    func testInsideOutsideAndClosedReferencesMakeTheSameGeometry() throws {
        let specs = [spec(), spec(.outside, [84, 64, 42]), spec(.closed, [84, 64, 44])]
        let reference = try XCTUnwrap(specs.first).make().workspace
        for input in specs {
            let made = try input.make()
            XCTAssertEqual(made.resolved.inside, SIMD3(80, 60, 40))
            XCTAssertEqual(made.resolved.outside, SIMD3(84, 64, 42))
            XCTAssertEqual(made.resolved.closed, SIMD3(84, 64, 44))
            XCTAssertTrue(made.resolved.defaults.isEmpty)
            for index in 0..<2 {
                let actual = try SolidKernel.solid(for: made.workspace.bodies[index])
                let expected = try SolidKernel.solid(for: reference.bodies[index])
                let common = try SolidKernel.boolean(actual, expected, .intersect)
                XCTAssertEqual(actual.volume + expected.volume - 2 * common.volume, 0, accuracy: 0.001)
                XCTAssertTrue(actual.isValidSolid)
            }
        }
        let box = try SolidKernel.solid(for: reference.bodies[0]), lid = try SolidKernel.solid(for: reference.bodies[1])
        XCTAssertEqual(box.volume, area(84, 64, 6) * 42 - area(80, 60, 4) * 40, accuracy: 0.001)
        XCTAssertEqual(lid.volume, area(84, 64, 6) * 2 + (area(79.6, 59.6, 3.8) - area(76.4, 56.4, 2.2)) * 4, accuracy: 0.001)
        XCTAssertEqual(lid.bounds.min.x - box.bounds.max.x, 10, accuracy: 0.001)
        XCTAssertEqual(box.bounds.max.z, 42, accuracy: 0.001)
        XCTAssertEqual(lid.bounds.max.z, 6, accuracy: 0.001)
    }

    func testLidAssemblesWithoutInterferenceAndGapIsPerSide() throws {
        let made = try spec().make()
        let box = try SolidKernel.solid(for: made.workspace.bodies[0])
        let lid = made.workspace.bodies[1]
        let closed = try XCTUnwrap(lid.transformed(by: .init(rotation: simd_quatd(angle: .pi, axis: [1, 0, 0]),
                                                          translation: [-94, 0, 44])))
        let assembled = try SolidKernel.solid(for: closed)
        XCTAssertEqual(assembled.bounds.max.z, 44, accuracy: 0.001)
        XCTAssertEqual(try SolidKernel.boolean(box, assembled, .intersect).volume, 0, accuracy: 0.001)
        let rim = try XCTUnwrap(lid.cuts.first)
        let width = (rim.profile.outline.map(\.x).max() ?? 0) - (rim.profile.outline.map(\.x).min() ?? 0)
        XCTAssertEqual((80 - width) / 2, 0.2, accuracy: 0.001)
        let biggerGap = try AssistantSlipLidBox(reference: .inside, width: 80, depth: 60, height: 40, wall: 2, radius: 6, clearance: 0.4).make()
        let biggerRim = biggerGap.workspace.bodies[1].cuts[0].profile.outline
        XCTAssertEqual((80 - ((biggerRim.map(\.x).max() ?? 0) - (biggerRim.map(\.x).min() ?? 0))) / 2, 0.4, accuracy: 0.001)
    }

    func testInvalidAndInternallyClampedValuesLeaveTheDraftUntouched() throws {
        var invalid = [spec(.inside, [500, 60, 40]), spec(.closed, [84, 64, 4]), spec(.inside, [.nan, 60, 40])]
        var smallRadius = spec(.inside, [10, 10, 10]); smallRadius.radius = 20; invalid.append(smallRadius)
        var thinWall = spec(); thinWall.wall = 0.5; invalid.append(thinWall)
        var hugeFit = spec(); hugeFit.clearance = 0.8; invalid.append(hugeFit)
        var impossibleVents = spec(.inside, [10, 10, 5]); impossibleVents.radius = 4; impossibleVents.vents = true; invalid.append(impossibleVents)
        for input in invalid {
            var bench = AssistantWorkbench(workspace: Workspace())
            XCTAssertThrowsError(try bench.addSlipLidBox(input))
            XCTAssertEqual(bench.workspace, Workspace())
            XCTAssertTrue(bench.changes.isEmpty)
        }
    }

    func testDefaultsAreRecordedAndExistingBodiesAndNamesArePreserved() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        let input = AssistantSlipLidBox(reference: .inside, width: 80, depth: 60, height: 40)
        let receipt = try bench.addSlipLidBox(input)
        XCTAssertTrue(receipt.contains("Defaults: wall/floor 2 mm"))
        XCTAssertTrue(receipt.contains("Fit clearance"))
        XCTAssertTrue(receipt.contains("vents off"))
        XCTAssertEqual(bench.changes.count, 1)
        let first = bench.workspace
        let right = try SolidKernel.solid(for: first.bodies[1]).bounds.max.x
        try bench.addSlipLidBox(input)
        XCTAssertEqual(Array(bench.workspace.bodies.prefix(2)), first.bodies)
        XCTAssertEqual(bench.workspace.groups.prefix(1), first.groups[...])
        XCTAssertEqual(bench.workspace.bodies.count, 4)
        XCTAssertEqual(Set(bench.workspace.bodyNames.values).count, 4)
        let newLeft = try SolidKernel.solid(for: bench.workspace.bodies[2]).bounds.min.x
        XCTAssertEqual(newLeft - right, 10, accuracy: 0.001)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: bench.workspace))).workspace, bench.workspace)
    }

    func testFollowUpHoleEditsBoxInPlaceAndPreservesLid() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        try bench.addSlipLidBox(spec())
        let box = bench.workspace.bodies[0], lid = bench.workspace.bodies[1]
        // A hole through the 2 mm floor at its middle, on the outside bottom face.
        try bench.hole(body: "Box", face: "bottom", kind: .simple, size: "", diameter: 6, depth: nil)
        XCTAssertEqual(bench.workspace.bodies[0].id, box.id)
        XCTAssertEqual(bench.workspace.bodies[1], lid)
        XCTAssertEqual(try SolidKernel.solid(for: box).volume - SolidKernel.solid(for: bench.workspace.bodies[0]).volume, .pi * 9 * 2, accuracy: 0.001)
    }

    func testReferenceConversionPreservesExactDecimalRangeBoundaries() throws {
        for (reference, size) in [(AssistantSlipLidBox.Reference.inside, SIMD3<Double>(10, 10, 5)),
                                  (.outside, SIMD3<Double>(12.4, 12.4, 6.2)), (.closed, SIMD3<Double>(12.4, 12.4, 8.2))] {
            let made = try AssistantSlipLidBox(reference: reference, width: size.x, depth: size.y, height: size.z,
                                               wall: 1.2, radius: 0, clearance: 0.05, vents: false).make()
            XCTAssertEqual(made.resolved.inside, SIMD3(10, 10, 5))
        }
        XCTAssertThrowsError(try AssistantSlipLidBox(reference: .closed, width: 12.4, depth: 12.4, height: 8.199,
                                                     wall: 1.2, radius: 0, clearance: 0.05, vents: false).make())
    }
}
