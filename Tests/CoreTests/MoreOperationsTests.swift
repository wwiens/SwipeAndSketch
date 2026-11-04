import XCTest
import simd
@testable import SwipeAndSketchCore

final class MoreOperationsTests: XCTestCase {
    var lid: SketchPlane { SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1))! }

    // MARK: Merge

    func testMergingTouchingSolidsMakesOneSolidAndKeepsBothHistories() throws {
        var a = try box()
        var b = try box(30, -10, 50, 10, depth: 10)          // touches a's right face
        let hole = SketchShape(kind: .circle, plane: .top, start: .init(x: 40, y: 0), end: .init(x: 42, y: 0))
        b.cuts = [ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true)]
        a.cuts = [.merge(b)]
        XCTAssertEqual(a.cuts[0].operation, .merge)
        XCTAssertTrue(a.isValid)
        let solid = try SolidKernel.solid(for: a)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 48_000 + 20 * 20 * 10 - .pi * 4 * 10, accuracy: 1e-3, "b keeps its own hole")
        XCTAssertEqual(a.nestingDepth, 2)
    }

    func testMergingSeparateSolidsFails() throws {
        var a = try box()
        a.cuts = [.merge(try box(40, -10, 60, 10))]
        XCTAssertThrowsError(try SolidKernel.solid(for: a))
    }

    // MARK: Shell

    func testFaceNamesCoverTheExtrusionAndMatchKernelFaces() throws {
        for depth in [20.0, -20.0] {
            let body = try box(depth: depth)
            let solid = try SolidKernel.solid(for: body)
            let names = (0..<solid.faceCount).compactMap { face in solid.facePlane(face).flatMap { body.extrusionFace(point: $0.origin, normal: $0.normal) } }
            XCTAssertEqual(Set(names), Set(body.extrusionFaces), "depth \(depth)")
            XCTAssertEqual(names.count, 6)
        }
    }

    func testShellOpenTopMakesATray() throws {
        var body = try box()
        body.cuts = [.shell(of: body, openFaces: [.init(position: .cap, index: 0)], thickness: 2)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 48_000 - 56 * 36 * 18, accuracy: 1e-3)
        // Survives a depth edit: the cap is found by role, not by kernel face number.
        body.depth = 30
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 60 * 40 * 30 - 56 * 36 * 28, accuracy: 1e-3)
    }

    func testShellAfterAHoleAndValidation() throws {
        var body = try box()
        let hole = SketchShape(kind: .circle, plane: .top, start: .init(x: 15, y: 0), end: .init(x: 18, y: 0))
        body.cuts = [ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true),
                     .shell(of: body, openFaces: [.init(position: .cap, index: 0)], thickness: 2)]
        XCTAssertTrue(try SolidKernel.solid(for: body).isValidSolid, "The hole becomes a tube through the tray floor")
        body.cuts = [.shell(of: body, openFaces: [.init(position: .cap, index: 0)], thickness: 0.05)]
        XCTAssertFalse(body.isValid, "Walls thinner than 0.2 mm are refused")
        body.cuts = [.shell(of: body, openFaces: [], thickness: 2)]
        XCTAssertFalse(body.isValid, "A shell needs at least one open face")
    }

    // MARK: Holes

    func testPresetsAreStandardAndValid() {
        for size in HolePresets.sizes { for kind in HoleSpec.Kind.allCases { XCTAssertTrue(HolePresets.spec(kind, size: size).isValid, "\(kind) \(size)") } }
        XCTAssertEqual(HolePresets.spec(.simple, size: "M3").diameter, 3.4)
        XCTAssertEqual(HolePresets.spec(.counterbore, size: "M3").counterboreDiameter, 6.1)
        XCTAssertEqual(HolePresets.spec(.insert, size: "M3").diameter, 4.0)
        XCTAssertEqual(HolePresets.defaultDepth(.insert, size: "M3"), 6.7)
        XCTAssertNil(HolePresets.defaultDepth(.simple, size: "M3"))
    }

    func testHoleKindsRemoveTheExpectedMaterial() throws {
        let base = try box()
        func volume(_ spec: HoleSpec, depth: Double?) throws -> Double {
            var body = base
            body.cuts = [try XCTUnwrap(ExtrusionCut.hole(spec, at: .zero, on: lid, depth: depth))]
            XCTAssertTrue(body.isValid)
            let solid = try SolidKernel.solid(for: body)
            XCTAssertTrue(solid.isValidSolid)
            return 48_000 - solid.volume
        }
        let simple = HolePresets.spec(.simple, size: "M3")
        XCTAssertEqual(try volume(simple, depth: nil), .pi * 1.7 * 1.7 * 20, accuracy: 1e-3, "Through the 20 mm box")
        XCTAssertEqual(try volume(simple, depth: 8), .pi * 1.7 * 1.7 * 8, accuracy: 1e-3, "Blind hole from the top face")
        let cb = HolePresets.spec(.counterbore, size: "M3")
        XCTAssertEqual(try volume(cb, depth: nil), .pi * 1.7 * 1.7 * (20 - 3.4) + .pi * 3.05 * 3.05 * 3.4, accuracy: 1e-3)
        let csk = HolePresets.spec(.countersink, size: "M3")
        let height = (3.2 - 1.7) / tan(Double.pi / 4)
        let cone = Double.pi * height / 3 * (3.2 * 3.2 + 3.2 * 1.7 + 1.7 * 1.7)
        XCTAssertEqual(try volume(csk, depth: nil), cone + .pi * 1.7 * 1.7 * (20 - height), accuracy: 1e-3)
        let insert = HolePresets.spec(.insert, size: "M3")
        XCTAssertEqual(try volume(insert, depth: 6.7), .pi * 4 * 6.7, accuracy: 1e-3)
    }

    func testHolesRoundTrip() throws {
        var body = try box()
        body.cuts = [try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.simple, size: "M3"), at: .zero, on: lid, depth: nil))]
        let project = Project(workspace: Workspace(bodies: [body]))
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(decoded.workspace, project.workspace)
    }
}
