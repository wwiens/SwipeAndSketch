import XCTest
import simd
@testable import SwipeAndSketchCore

final class SketchPlaneTests: XCTestCase {
    func testFacesOnWorldPlanesAreTheWorldPlanes() throws {
        XCTAssertEqual(SketchPlane.through(.init(5, -3, 0), normal: .init(0, 0, 1)), .top)
        XCTAssertEqual(SketchPlane.through(.init(7, 0, 9), normal: .init(0, -1, 0)), .front)
        XCTAssertEqual(SketchPlane.through(.init(0, 4, 2), normal: .init(2, 0, 0)), .right)
        let lid = try XCTUnwrap(SketchPlane.through(.init(12, -8, 20), normal: .init(0, 0, 1)))
        XCTAssertEqual(lid.origin, .init(0, 0, 20))
        XCTAssertEqual(lid.xAxis, SketchPlane.top.xAxis, "A raised top face keeps Top's sketch axes")
        XCTAssertFalse(lid.isWorldPlane)
    }

    func testCoplanarFacesShareOnePlaneAndObliqueFramesAreRightHanded() throws {
        let n = simd_normalize(SIMD3<Double>(1, -1, 1))
        let a = try XCTUnwrap(SketchPlane.through(.init(10, 0, 0), normal: n))
        let b = try XCTUnwrap(SketchPlane.through(.init(0, -10, 0), normal: n * 3))
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.isValid)
        XCTAssertEqual(simd_length(a.normalAxis - n), 0, accuracy: 1e-9)
        let p = Point2(x: 3, y: -4)
        XCTAssertEqual(a.coordinates(of: a.point(p, height: 2)).distance(to: p), 0, accuracy: 1e-9)
        XCTAssertEqual(a.height(of: a.point(p, height: 2)), 2, accuracy: 1e-9)
        XCTAssertEqual(a.height(of: .init(10, 0, 0)), 0, accuracy: 1e-9)
    }

    func testWorldPlanesEncodeAsBeforeAndFacePlanesRoundTrip() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([SketchPlane.top, .front, .right]), as: UTF8.self), #"["top","front","right"]"#)
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        XCTAssertEqual(try JSONDecoder().decode(SketchPlane.self, from: JSONEncoder().encode(face)), face)
        XCTAssertThrowsError(try JSONDecoder().decode(SketchPlane.self, from: Data(#""left""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(SketchPlane.self, from: Data(#"{"origin":[0,0,0],"xAxis":[2,0,0],"yAxis":[0,1,0]}"#.utf8)),
                             "Axes must be unit length")
    }

    func testFaceSketchesSolidsAndCutsRoundTrip() throws {
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        let circle = SketchShape(kind: .circle, plane: face, start: .zero, end: .init(x: 4, y: 0))
        let profile = try XCTUnwrap(Geometry.profiles(in: [circle], on: face).first)
        let boss = SolidBody(profile: profile, depth: 5)
        let solid = try SolidKernel.solid(for: boss)
        XCTAssertEqual(solid.bounds.min.z, 20, accuracy: 1e-9, "Extrusions start on the face")
        XCTAssertEqual(solid.bounds.max.z, 25, accuracy: 1e-9)

        let project = Project(workspace: Workspace(shapes: [circle], bodies: [boss]))
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, project.workspace)
    }

    func testCircleProfilesAreValidatedInLinearTimeWithoutLosingSafety() throws {
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 3, y: -2), end: .init(x: 9, y: -2))
        let profile = try XCTUnwrap(Geometry.profiles(in: [circle], on: .top).first)
        XCTAssertTrue(profile.isSolidProfile)
        var scrambled = profile; scrambled.outline.swapAt(3, 40)
        XCTAssertFalse(scrambled.isSolidProfile, "Out-of-order points are rejected")
        var twice = profile; twice.outline += profile.outline
        XCTAssertFalse(twice.isSolidProfile, "Going around twice is rejected")
        var off = profile; off.outline[5].x += 0.1
        XCTAssertFalse(off.isSolidProfile, "Points off the circle are rejected")
        var reversed = profile; reversed.outline.reverse()
        XCTAssertTrue(reversed.isSolidProfile, "Either winding is fine")
    }

    func testFinishNamesAndCutsWorkOnFacePlaneBodies() throws {
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        let square = SketchShape(kind: .rectangle, plane: face, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10))
        var boss = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [square], on: face).first), depth: 10)
        let solid = try SolidKernel.solid(for: boss)
        XCTAssertEqual(Set((0..<solid.edgeCount).compactMap { boss.extrusionEdge(along: solid.edgeSamples($0)) }).count, 12)
        boss.finishes = [EdgeFinish(kind: .fillet, edges: boss.extrusionEdges.filter { $0.position == .cap }, size: 2)]
        let hole = SketchShape(kind: .circle, plane: face, start: .zero, end: .init(x: 3, y: 0))
        boss.cuts = [ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: face).first), depth: 1, throughAll: true)]
        XCTAssertTrue(try SolidKernel.solid(for: boss).isValidSolid)
    }
}
