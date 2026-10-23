import XCTest
import simd
@testable import SwipeAndSketchCore

final class EdgeFinishTests: XCTestCase {
    func body(_ kind: ShapeKind = .rectangle, plane: SketchPlane = .top, depth: Double = 20) throws -> SolidBody {
        let shape = kind == .circle
            ? SketchShape(kind: .circle, plane: plane, start: .zero, end: .init(x: 10, y: 0))
            : SketchShape(kind: .rectangle, plane: plane, start: .init(x: -20, y: -15), end: .init(x: 20, y: 15))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: plane).first), depth: depth)
    }

    func sides(_ body: SolidBody) -> [ExtrusionEdge] { body.extrusionEdges.filter { $0.position == .side } }

    func testEveryKernelEdgeOfAnExtrusionHasAUniqueName() throws {
        for plane in SketchPlane.allCases {
            for depth in [20.0, -20.0] {
                let box = try body(plane: plane, depth: depth)
                let solid = try SolidKernel.solid(for: box)
                let names = (0..<solid.edgeCount).compactMap { box.extrusionEdge(along: solid.edgeSamples($0)) }
                XCTAssertEqual(names.count, 12, "\(plane) \(depth)")
                XCTAssertEqual(Set(names), Set(box.extrusionEdges))
                let cylinder = try body(.circle, plane: plane, depth: depth)
                let rims = try SolidKernel.solid(for: cylinder)
                XCTAssertEqual(Set((0..<rims.edgeCount).compactMap { cylinder.extrusionEdge(along: rims.edgeSamples($0)) }), Set(cylinder.extrusionEdges))
            }
        }
    }

    func testCollinearDrawingPointsDoNotCreateEdgeNames() throws {
        let points = [Point2(x: 0, y: 0), .init(x: 15, y: 0), .init(x: 30, y: 0), .init(x: 30, y: 20), .init(x: 0, y: 20)]
        let lines = points.indices.map { SketchShape(kind: .line, plane: .top, start: points[$0], end: points[($0 + 1) % points.count]) }
        var box = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: lines, on: .top).first), depth: 10)
        XCTAssertEqual(box.corners.count, 4)
        XCTAssertEqual(box.extrusionEdges.count, 12)
        let solid = try SolidKernel.solid(for: box)
        XCTAssertEqual(Set((0..<solid.edgeCount).compactMap { box.extrusionEdge(along: solid.edgeSamples($0)) }).count, 12)
        box.finishes = [EdgeFinish(kind: .fillet, edges: sides(box), size: 2)]
        XCTAssertTrue(try SolidKernel.solid(for: box).isValidSolid)
    }

    func testFilletThenChamferReplaysOnRenamedEdges() throws {
        var box = try body()
        let plain = try SolidKernel.solid(for: box).volume
        box.finishes = [EdgeFinish(kind: .fillet, edges: sides(box), size: 4)]
        let rounded = try SolidKernel.solid(for: box)
        XCTAssertTrue(rounded.isValidSolid)
        XCTAssertEqual(rounded.volume, plain - 4 * (16 - .pi * 4) * 20, accuracy: 1e-3, "Four r4 vertical rounds")
        // The base edges were trimmed by the fillets but keep their names.
        box.finishes.append(EdgeFinish(kind: .chamfer, edges: box.extrusionEdges.filter { $0.position == .base }, size: 1))
        let finished = try SolidKernel.solid(for: box)
        XCTAssertTrue(finished.isValidSolid)
        XCTAssertLessThan(finished.volume, rounded.volume)
    }

    func testFinishesSurviveDepthChanges() throws {
        var box = try body()
        box.finishes = [EdgeFinish(kind: .fillet, edges: box.extrusionEdges.filter { $0.position == .cap }, size: 3)]
        for depth in [20.0, 35.0, -12.0] {
            box.depth = depth
            let solid = try SolidKernel.solid(for: box)
            XCTAssertTrue(solid.isValidSolid, "depth \(depth)")
            XCTAssertEqual(solid.bounds.max.z - solid.bounds.min.z, abs(depth), accuracy: 1e-6)
        }
    }

    func testCylinderRimFilletAndChamfer() throws {
        var cylinder = try body(.circle)
        cylinder.finishes = [EdgeFinish(kind: .fillet, edges: [.init(position: .cap, index: 0)], size: 2),
                             EdgeFinish(kind: .chamfer, edges: [.init(position: .base, index: 0)], size: 1)]
        let solid = try SolidKernel.solid(for: cylinder)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertLessThan(solid.volume, .pi * 100 * 20)
    }

    func testOversizedFinishFailsWithReason() throws {
        var box = try body(depth: 5)
        box.finishes = [EdgeFinish(kind: .fillet, edges: box.extrusionEdges.filter { $0.position == .cap }, size: 20)]
        XCTAssertTrue(box.isValid, "Structurally valid; only the kernel can tell it does not fit")
        XCTAssertThrowsError(try SolidKernel.solid(for: box)) { error in
            XCTAssertFalse((error as? SolidKernel.Failure)?.message.isEmpty ?? true)
        }
    }

    func testStructuralValidation() throws {
        var box = try body()
        let edge = ExtrusionEdge(position: .side, index: 0)
        box.finishes = [EdgeFinish(kind: .fillet, edges: [edge], size: 1)]
        XCTAssertTrue(box.isValid)
        for invalid in [
            [EdgeFinish(kind: .fillet, edges: [], size: 1)],
            [EdgeFinish(kind: .fillet, edges: [.init(position: .side, index: 4)], size: 1)],
            [EdgeFinish(kind: .fillet, edges: [edge], size: 0)],
            [EdgeFinish(kind: .fillet, edges: [edge], size: .nan)],
            [EdgeFinish(kind: .fillet, edges: [edge], size: 1), EdgeFinish(kind: .chamfer, edges: [edge], size: 1)],
        ] {
            box.finishes = invalid
            XCTAssertFalse(box.isValid, "\(invalid)")
        }
        var cylinder = try body(.circle)
        cylinder.finishes = [EdgeFinish(kind: .fillet, edges: [.init(position: .side, index: 0)], size: 1)]
        XCTAssertFalse(cylinder.isValid, "Circles have no side edges")
    }

    func testFinishesRoundTripAndPlainBodiesOmitThem() throws {
        var box = try body()
        let plain = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [box])))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("finishes"), "Bodies without finishes leave the key out")

        box.finishes = [EdgeFinish(kind: .chamfer, edges: [.init(position: .base, index: 2)], size: 0.6)]
        let project = Project(workspace: Workspace(bodies: [box]))
        let data = try ProjectCodec.encode(project)
        let decoded = try ProjectCodec.decode(data)
        XCTAssertEqual(decoded.workspace, project.workspace)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = Project.currentSchemaVersion + 1
        XCTAssertThrowsError(try ProjectCodec.decode(JSONSerialization.data(withJSONObject: json))) { error in
            XCTAssertEqual(error as? ProjectError, .unsupportedVersion)
        }
    }
}
