import XCTest
import simd
@testable import SwipeAndSketchCore

final class ConstructionPlaneTests: XCTestCase {
    /// A 60 × 40 × 20 box on Top (z 0…20).
    func face(of body: SolidBody, normal: SIMD3<Double>) throws -> PlaneReference {
        let solid = try SolidKernel.solid(for: body)
        let index = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { simd_dot($0.normal, normal) > 0.9999 } ?? false })
        return try XCTUnwrap(PlaneReference.face(index, of: body))
    }

    func testOffsetFromATopFaceSitsAboveItAndCoversIt() throws {
        let top = try face(of: try box(), normal: .init(0, 0, 1))
        XCTAssertEqual(simd_distance(top.origin, .init(0, 0, 20)), 0, accuracy: 1e-9)
        let plane = try XCTUnwrap(ConstructionPlanes.offset(from: top, by: 15))
        XCTAssertEqual(plane.plane.origin, .init(0, 0, 35))
        XCTAssertEqual(plane.plane.normalAxis, .init(0, 0, 1), "Out of the face")
        XCTAssertGreaterThan(plane.width, 60, "Covers the face with a margin")
        XCTAssertGreaterThan(plane.height, 40)
        // A sketch on it is 35 mm up.
        XCTAssertEqual(plane.plane.point(.init(x: 3, y: 4)).z, 35, accuracy: 1e-12)
        // Inward is a negative offset; zero lies on the face.
        XCTAssertEqual(try XCTUnwrap(ConstructionPlanes.offset(from: top, by: -5)).plane.origin.z, 15, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ConstructionPlanes.offset(from: top, by: 0)).plane.origin.z, 20, accuracy: 1e-12)
    }

    func testOffsetFromASideFaceAndAWorldPlane() throws {
        let side = try face(of: try box(), normal: .init(1, 0, 0))
        let plane = try XCTUnwrap(ConstructionPlanes.offset(from: side, by: 10))
        XCTAssertEqual(plane.plane.origin, .init(40, 0, 10))
        XCTAssertEqual(plane.plane.yAxis, .init(0, 0, 1), "Upright planes keep world up")
        let front = try XCTUnwrap(ConstructionPlanes.offset(from: .world(.front), by: 25))
        XCTAssertEqual(front.plane.normalAxis, .init(0, -1, 0))
        XCTAssertEqual(front.plane.origin, .init(0, -25, 0))
    }

    func testMidplaneBetweenOppositeFacesAndRejectsAngledOnes() throws {
        let body = try box()
        let left = try face(of: body, normal: .init(-1, 0, 0)), right = try face(of: body, normal: .init(1, 0, 0))
        let middle = try XCTUnwrap(ConstructionPlanes.midplane(between: left, and: right))
        XCTAssertEqual(middle.plane.origin.x, 0, accuracy: 1e-12)
        XCTAssertEqual(abs(middle.plane.normalAxis.x), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(middle.width, 40, "Covers both faces")
        // Between a face and a parallel plane above it.
        let top = try face(of: body, normal: .init(0, 0, 1))
        let above = try XCTUnwrap(ConstructionPlanes.offset(from: top, by: 30))
        XCTAssertEqual(try XCTUnwrap(ConstructionPlanes.midplane(between: top, and: .construction(above))).plane.origin.z, 35, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ConstructionPlanes.midplane(between: .world(.top), and: top)).plane.origin.z, 10, accuracy: 1e-12)
        XCTAssertNil(ConstructionPlanes.midplane(between: top, and: right), "Only parallel references")
        XCTAssertFalse(ConstructionPlanes.areParallel(top, right))
    }

    func testPlanesRoundTripAndCanBeHidden() throws {
        let plane = try XCTUnwrap(ConstructionPlanes.offset(from: .world(.top), by: 12))
        var workspace = Workspace(constructionPlanes: [plane])
        XCTAssertTrue(workspace.isValid)
        let project = Project(workspace: workspace)
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, workspace)
        workspace.constructionPlanes[0].hidden = true
        XCTAssertTrue(workspace.visible.constructionPlanes.isEmpty)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: workspace))).workspace, workspace)
        // Files without planes are unchanged.
        XCTAssertFalse(String(decoding: try ProjectCodec.encode(Project(workspace: Workspace())), as: UTF8.self).contains("constructionPlanes"))
        workspace.constructionPlanes[0].width = 0
        XCTAssertFalse(workspace.isValid)
    }
}
