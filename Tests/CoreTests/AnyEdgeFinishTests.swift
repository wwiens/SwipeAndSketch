import XCTest
import simd
@testable import SwipeAndSketchCore

/// Fillets and chamfers on any edge, and Measure.
final class AnyEdgeFinishTests: XCTestCase {
    func profile(_ kind: ShapeKind, _ a: Point2, _ b: Point2, plane: SketchPlane = .top) throws -> SketchProfile {
        try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: kind, plane: plane, start: a, end: b)], on: plane).first)
    }

    /// 60 × 40 × 20 box with a ⌀10 through hole.
    func drilledBox() throws -> SolidBody {
        var body = SolidBody(profile: try profile(.rectangle, .init(x: -30, y: -20), .init(x: 30, y: 20)), depth: 20)
        body.cuts = [ExtrusionCut(profile: try profile(.circle, .zero, .init(x: 5, y: 0)), depth: 1, throughAll: true)]
        return body
    }

    /// Kernel edges whose middle lies at height `z` on a circle of radius `r` about the z axis.
    func rim(of solid: KernelSolid, z: Double, radius r: Double) -> [Int] {
        (0..<solid.edgeCount).filter { edge in
            let s = solid.edgeSamples(edge, count: 3)
            return s.count == 3 && abs(s[1].z - z) < 1e-6 && abs(hypot(s[1].x, s[1].y) - r) < 1e-6
        }
    }

    func testAHoleMadeByACutCanBeRoundedAndBeveled() throws {
        let body = try drilledBox()
        let solid = try SolidKernel.solid(for: body)
        let top = rim(of: solid, z: 20, radius: 5)
        XCTAssertFalse(top.isEmpty)
        XCTAssertTrue(body.edgeNames(top, of: solid).allSatisfy { $0 == nil }, "The hole's rim is not an original edge")
        let rounded = try XCTUnwrap(body.finishing(.fillet, edges: top, size: 1))
        XCTAssertEqual(rounded.cuts.last?.operation, .finish, "Saved as a step after the cut")
        XCTAssertTrue(rounded.finishes.isEmpty)
        let result = try SolidKernel.solid(for: rounded)
        XCTAssertTrue(result.isValidSolid)
        XCTAssertLessThan(result.volume, solid.volume)
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: Workspace(bodies: [rounded]))))
        XCTAssertEqual(decoded.workspace.bodies, [rounded])
        // The bottom rim takes a chamfer after the fillet, as a second step.
        let bottom = rim(of: result, z: 0, radius: 5)
        let both = try XCTUnwrap(rounded.finishing(.chamfer, edges: bottom, size: 0.5))
        XCTAssertEqual(both.cuts.filter { $0.operation == .finish }.count, 2)
        XCTAssertTrue(try SolidKernel.solid(for: both).isValidSolid)
        XCTAssertNil(body.finishing(.fillet, edges: top, size: 50), "Too large to build")
    }

    func testOriginalEdgesOfAPlainSolidKeepTheirNames() throws {
        let box = SolidBody(profile: try profile(.rectangle, .init(x: -30, y: -20), .init(x: 30, y: 20)), depth: 20)
        let solid = try SolidKernel.solid(for: box)
        let rounded = try XCTUnwrap(box.finishing(.fillet, edges: [0, 1], size: 2))
        XCTAssertEqual(rounded.finishes.count, 1, "Named as before")
        XCTAssertTrue(rounded.cuts.isEmpty)
        // A fillet-made edge of that solid is saved by a point.
        let filleted = try SolidKernel.solid(for: rounded)
        let new = (0..<filleted.edgeCount).filter { (rounded.edgeNames([$0], of: filleted).first ?? nil) == nil }
        XCTAssertFalse(new.isEmpty)
        // The round's end, where it meets the top face, is a sharp edge to bevel.
        let end = try XCTUnwrap(new.first { filleted.edgeCircle($0) != nil && (filleted.edgeSamples($0, count: 3).first?.z ?? 0) > 19 })
        XCTAssertNotNil(rounded.finishing(.chamfer, edges: [end], size: 0.3)?.cuts.last?.finish)
        _ = solid
    }

    func testNamedEdgesFollowADepthEditAndMirror() throws {
        let body = try drilledBox()
        let solid = try SolidKernel.solid(for: body)
        // The box's top edges are original edges, but the solid has a cut: saved by point and name.
        let caps = (0..<solid.edgeCount).filter { body.edgeNames([$0], of: solid).first??.position == .cap }
        let sides = (0..<solid.edgeCount).filter { body.edgeNames([$0], of: solid).first??.position == .side }
        var rounded = try XCTUnwrap(body.finishing(.fillet, edges: caps + sides, size: 2))
        XCTAssertEqual(rounded.cuts.last?.finish?.edges.compactMap(\.name).count, 8)
        rounded.depth = 35
        let deeper = try SolidKernel.solid(for: rounded)
        XCTAssertTrue(deeper.isValidSolid, "The rounded top edges moved up with the cap")
        XCTAssertEqual(deeper.bounds.max.z, 35, accuracy: 1e-6)
        let image = try XCTUnwrap(rounded.mirrored(by: XCTUnwrap(Reflection(across: .right))))
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, deeper.volume, accuracy: 1e-3)
    }

    func testMeasuringSizesDistancesAndAngles() throws {
        let a = SolidBody(profile: try profile(.rectangle, .zero, .init(x: 10, y: 10)), depth: 10)
        var b = SolidBody(profile: try profile(.rectangle, .init(x: 30, y: 0), .init(x: 40, y: 10)), depth: 10)
        b.id = UUID()
        let workspace = Workspace(bodies: [a, b])
        let properties = Measuring.properties(of: .body(a.id), in: workspace)
        XCTAssertEqual(properties.first { $0.kind == .volume }?.value ?? 0, 1000, accuracy: 1e-6)
        XCTAssertEqual(properties.first { $0.kind == .surfaceArea }?.value ?? 0, 600, accuracy: 1e-6)
        let between = try XCTUnwrap(Measuring.between(.body(a.id), .body(b.id), in: workspace))
        XCTAssertEqual(between.values.first { $0.kind == .distance }?.value ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(between.values.first { $0.kind == .dx }?.value ?? 0, 20, accuracy: 1e-6)
        // Two faces: the right face of one and the top face of the other are square to each other.
        let solidA = try SolidKernel.solid(for: a), solidB = try SolidKernel.solid(for: b)
        let right = try XCTUnwrap((0..<solidA.faceCount).first { solidA.facePlane($0).map { $0.normal.x > 0.99 } ?? false })
        let top = try XCTUnwrap((0..<solidB.faceCount).first { solidB.facePlane($0).map { $0.normal.z > 0.99 } ?? false })
        let faces = try XCTUnwrap(Measuring.between(.face(bodyID: a.id, face: right), .face(bodyID: b.id, face: top), in: workspace))
        XCTAssertEqual(faces.values.first { $0.kind == .angle }?.value ?? 0, 90, accuracy: 1e-6)
        XCTAssertEqual(Measuring.properties(of: .face(bodyID: a.id, face: right), in: workspace).first?.value ?? 0, 100, accuracy: 1e-6)
        // A sketch circle to a corner.
        let ring = SketchShape(kind: .circle, plane: .top, start: .init(x: 0, y: 30), end: .init(x: 5, y: 30))
        let sketch = Workspace(shapes: [ring], bodies: [a, b])
        let gap = try XCTUnwrap(Measuring.between(.shape(ring.id), .point(SIMD3(0, 10, 0)), in: sketch))
        XCTAssertEqual(gap.values.first?.value ?? 0, 15, accuracy: 1e-6)
        XCTAssertEqual(Measuring.properties(of: .shape(ring.id), in: sketch).first?.value, 10)
    }
}
