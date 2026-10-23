import XCTest
import simd
@testable import SwipeAndSketchCore

/// Shell opening any face, by a point on it.
final class ShellOpeningTests: XCTestCase {
    /// A 40 × 40 × 10 plate on Top with a 10 mm-radius, 15 mm-tall boss joined on top.
    func plateWithBoss() throws -> SolidBody {
        let plate = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -20, y: -20), end: .init(x: 20, y: 20))
        var body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [plate], on: .top).first), depth: 10)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 10), normal: .init(0, 0, 1)))
        let circle = SketchShape(kind: .circle, plane: top, start: .zero, end: .init(x: 10, y: 0))
        body.cuts = [ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [circle], on: top).first), depth: 15, operation: .join)]
        return body
    }

    func testAFaceMadeByAJoinCanBeLeftOpen() throws {
        var body = try plateWithBoss()
        let solid = try SolidKernel.solid(for: body)
        let bossTop = SIMD3<Double>(3, 2, 25)
        XCTAssertNotNil(solid.face(near: bossTop), "The boss's top is found by a point on it")
        XCTAssertNil(solid.face(near: .init(100, 0, 0)))
        body.cuts.append(.shell(of: body, openingAt: [bossTop], thickness: 1))
        XCTAssertTrue(body.isValid)
        let shelled = try SolidKernel.solid(for: body)
        XCTAssertTrue(shelled.isValidSolid)
        XCTAssertLessThan(shelled.volume, solid.volume * 0.5, "Hollowed through the boss")
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [body])))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [body])
    }

    func testCurvedFacesAreFoundAndOpeningsMoveWithTheSolid() throws {
        var body = try plateWithBoss()
        let solid = try SolidKernel.solid(for: body)
        let side = try XCTUnwrap(solid.face(near: .init(10, 0, 18)), "The boss's curved side")
        XCTAssertNil(solid.facePlane(side), "It is curved")
        XCTAssertNotEqual(side, solid.face(near: .init(3, 2, 25)))
        body.cuts.append(.shell(of: body, openingAt: [.init(3, 2, 25)], thickness: 1))
        let shelled = try SolidKernel.solid(for: body).volume
        let moved = try XCTUnwrap(body.transformed(by: .rotate(degrees: 90, about: .init(1, 0, 0), through: .zero)))
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, shelled, accuracy: 1e-6, "The opening turned with the solid")
    }

    func testAnOpeningThatNoLongerTouchesTheSolidFails() throws {
        var body = try plateWithBoss()
        body.cuts.append(.shell(of: body, openingAt: [.init(3, 2, 25)], thickness: 1))
        body.cuts[0].depth = 5   // The boss top moves to z = 15.
        XCTAssertThrowsError(try SolidKernel.solid(for: body))
    }
}
