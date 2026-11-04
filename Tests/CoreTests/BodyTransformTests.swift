import XCTest
import simd
@testable import SwipeAndSketchCore

final class BodyTransformTests: XCTestCase {
    /// A 60 × 40 × 20 box on Top with a fillet, a through hole, a joined boss, a hole preset, a face
    /// extrusion, and a merged solid. (Shells are checked on their own box below.)
    func featuredBox() throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        var body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
        body.finishes = [EdgeFinish(kind: .fillet, edges: [ExtrusionEdge(position: .side, index: 0)], size: 3)]
        let lid = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        let hole = SketchShape(kind: .circle, plane: .top, start: .init(x: 15, y: 0), end: .init(x: 18, y: 0))
        body.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true))
        let boss = SketchShape(kind: .rectangle, plane: lid, start: .init(x: -20, y: -5), end: .init(x: -10, y: 5))
        body.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [boss], on: lid).first), depth: 6, operation: .join))
        body.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.counterbore, size: "M3"), at: .init(x: 0, y: 10), on: lid, depth: nil)))
        let solid = try SolidKernel.solid(for: body)
        let bottom = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { $0.normal.z < -0.9999 } ?? false })
        body.cuts.append(try XCTUnwrap(FaceExtrusionSource(body: body, face: bottom)).operation(depth: 2))
        let side = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 30, y: -10), end: .init(x: 40, y: 10))
        body.cuts.append(.merge(SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [side], on: .top).first), depth: 10)))
        return body
    }

    func testShellOpenFaceFollowsATurn() throws {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        var body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
        body.cuts = [.shell(of: body, openFaces: [ExtrusionFace(position: .cap, index: 0)], thickness: 2)]
        let volume = try SolidKernel.solid(for: body).volume
        let turned = try XCTUnwrap(body.transformed(by: .rotate(degrees: 37, about: .init(1, 2, 3), through: .init(5, 5, 5))))
        XCTAssertEqual(try SolidKernel.solid(for: turned).volume, volume, accuracy: volume * 1e-6, "The open top is still the open top")
    }

    func testMovingAndTurningASolidKeepsEveryStep() throws {
        let body = try featuredBox()
        let original = try SolidKernel.solid(for: body)
        let volume = original.volume
        let moved = try XCTUnwrap(body.transformed(by: .move(.init(10, -5, 30))))
        let movedSolid = try SolidKernel.solid(for: moved)
        XCTAssertEqual(movedSolid.volume, volume, accuracy: volume * 1e-6)
        XCTAssertEqual(movedSolid.bounds.min.z, original.bounds.min.z + 30, accuracy: 1e-6)
        XCTAssertEqual(movedSolid.faceCount, original.faceCount)
        // A turn that is not a quarter turn exercises every named face and edge off the world axes.
        let turned = try XCTUnwrap(body.transformed(by: .rotate(degrees: 37, about: .init(1, 2, 3), through: .init(5, 5, 5))))
        let turnedSolid = try SolidKernel.solid(for: turned)
        XCTAssertEqual(turnedSolid.volume, volume, accuracy: volume * 1e-6)
        XCTAssertTrue(turnedSolid.isValidSolid)
        // Known cosmetic limit: at an arbitrary angle, OCCT may leave a seam where a face
        // extrusion meets a fillet (one extra face); the shape itself is identical.
        XCTAssertEqual(Double(turnedSolid.faceCount), Double(original.faceCount), accuracy: 1)
        var plain = body
        plain.finishes = []
        XCTAssertEqual(try SolidKernel.solid(for: try XCTUnwrap(plain.transformed(by: .rotate(degrees: 37, about: .init(1, 2, 3), through: .init(5, 5, 5))))).faceCount,
                       try SolidKernel.solid(for: plain).faceCount, "Without that combination the topology is unchanged")
    }

    func testWorkspaceMoveAndCopy() throws {
        let body = try featuredBox()
        let workspace = Workspace(bodies: [body])
        let center = try XCTUnwrap(workspace.center(of: body))
        let (moved, movedID) = try XCTUnwrap(workspace.transformingBody(body.id, by: .move(.init(0, 0, 50)), copy: false))
        XCTAssertEqual(movedID, body.id)
        XCTAssertEqual(moved.bodies.count, 1)
        XCTAssertEqual(try XCTUnwrap(moved.center(of: moved.bodies[0])).z, center.z + 50, accuracy: 1e-6)
        let (copied, copyID) = try XCTUnwrap(workspace.transformingBody(body.id, by: .rotate(degrees: 90, about: .init(0, 0, 1), through: center), copy: true))
        XCTAssertNotEqual(copyID, body.id)
        XCTAssertEqual(copied.bodies.count, 2)
        XCTAssertEqual(copied.bodies[0], body, "The original stays")
        XCTAssertEqual(copied.bodies[1].id, copyID)
        XCTAssertEqual(try SolidKernel.solid(for: copied.bodies[1]).volume, try SolidKernel.solid(for: body).volume, accuracy: 1e-3)
        let project = Project(workspace: copied)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(project)).workspace, copied)
        XCTAssertEqual(workspace.transforming(.body(body.id), by: .move(.init(1, 0, 0)), copy: false)?.target, .body(body.id))
    }

    func testWidgetCenterSnapsToCornersEdgesAndCenters() throws {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        let body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
        let solid = try SolidKernel.solid(for: body)
        let mesh = try solid.tessellate()
        let snaps = TransformPivot.snaps(of: solid, edges: mesh.edges.indices.filter { mesh.edges[$0].isBoundary })
        func count(_ kind: TransformPivot.Kind) -> Int { snaps.points.filter { $0.kind == kind }.count }
        XCTAssertEqual(count(.center), 1)
        XCTAssertEqual(count(.corner), 8)
        XCTAssertEqual(count(.midpoint), 12)
        XCTAssertEqual(count(.faceCenter), 6)
        XCTAssertEqual(snaps.edges.count, 12, "Every edge can take the center anywhere along it")
        let center = try XCTUnwrap(snaps.points.first { $0.kind == .center })
        XCTAssertLessThan(simd_distance(center.point, SIMD3(0, 0, 10)), 1e-9)
        XCTAssertTrue(snaps.points.contains { $0.kind == .corner && simd_distance($0.point, SIMD3(30, 20, 20)) < 1e-9 })

        let round = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: .circle, plane: .top, start: .init(x: 5, y: 5),
                                                                                          end: .init(x: 15, y: 5))], on: .top).first), depth: 8)
        let cylinder = try SolidKernel.solid(for: round)
        let cylinderMesh = try cylinder.tessellate()
        let rims = TransformPivot.snaps(of: cylinder, edges: cylinderMesh.edges.indices.filter { cylinderMesh.edges[$0].isBoundary })
        let rimCenters = rims.points.filter { $0.kind == .circleCenter }
        XCTAssertEqual(rimCenters.count, 2, "Both rims' centers")
        XCTAssertTrue(rimCenters.contains { simd_distance($0.point, SIMD3(5, 5, 8)) < 1e-6 })
        XCTAssertEqual(abs(try XCTUnwrap(rimCenters.first?.direction).z), 1, accuracy: 1e-9, "A rim center turns the widget about the cylinder's axis")
    }

    func testWidgetAxesTurnToFollowTheEdge() {
        let axes: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        XCTAssertEqual(TransformPivot(kind: .corner, point: .zero).axes(from: axes), axes, "Points keep the solid's own axes")
        XCTAssertEqual(TransformPivot(kind: .edge, point: .zero, direction: SIMD3(0, 0, -5)).axes(from: axes), axes,
                       "An edge along an axis keeps that axis, and its sense")
        let slanted = TransformPivot(kind: .edge, point: .zero, direction: SIMD3(2, 1, 0)).axes(from: axes)
        XCTAssertLessThan(simd_distance(slanted[0], simd_normalize(SIMD3(2, 1, 0))), 1e-12, "The closest axis turns onto the edge")
        XCTAssertLessThan(simd_distance(slanted[1], simd_normalize(SIMD3(-1, 2, 0))), 1e-12)
        XCTAssertLessThan(simd_distance(slanted[2], SIMD3(0, 0, 1)), 1e-12)
        let tilted = TransformPivot(kind: .edge, point: .zero, direction: SIMD3(0, 1, 3)).axes(from: axes)
        XCTAssertLessThan(simd_distance(tilted[2], simd_normalize(SIMD3(0, 1, 3))), 1e-12)
        for i in 0..<3 { XCTAssertEqual(simd_dot(tilted[i], tilted[(i + 1) % 3]), 0, accuracy: 1e-12) }
        XCTAssertLessThan(simd_distance(simd_cross(tilted[0], tilted[1]), tilted[2]), 1e-12, "Still right-handed")
    }
}
