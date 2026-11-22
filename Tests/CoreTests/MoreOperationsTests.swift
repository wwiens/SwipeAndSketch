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
        for kind in HoleSpec.Kind.allCases {
            for size in HolePresets.sizes(for: kind) {
                let spec = HolePresets.spec(kind, size: size)
                XCTAssertTrue(spec.isValid, "\(kind) \(size)")
                XCTAssertEqual(spec.size, size, "\(kind) \(size) is a preset of its own")
            }
        }
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

    func testLargerAndInchSizes() {
        XCTAssertEqual(HolePresets.spec(.simple, size: "M6").diameter, 6.6)
        XCTAssertEqual(HolePresets.spec(.simple, size: "M8").diameter, 9.0)
        XCTAssertEqual(HolePresets.spec(.counterbore, size: "M8").counterboreDiameter, 13.6)
        XCTAssertEqual(HolePresets.spec(.countersink, size: "M6").countersinkAngle, 90)
        XCTAssertEqual(HolePresets.spec(.countersink, size: "1/4").countersinkAngle, 82, "Inch flat heads are 82°")
        XCTAssertEqual(HolePresets.spec(.simple, size: "1/4").diameter, 6.7)
        XCTAssertEqual(HolePresets.defaultDepth(.insert, size: "M6"), 13.7)
        XCTAssertEqual(HolePresets.defaultSize(for: .simple, inch: true), "#6")
        XCTAssertEqual(HolePresets.spec(.magnet, size: "M3").size, "6×2", "A screw size starts a magnet at its default")
    }

    func testLooseKindsAndSizes() {
        XCTAssertEqual(HoleSpec.Kind(loose: "nut trap"), .nutTrap)
        XCTAssertEqual(HoleSpec.Kind(loose: "NUT_TRAP"), .nutTrap)
        XCTAssertEqual(HoleSpec.Kind(loose: "nut"), .nutTrap)
        XCTAssertEqual(HoleSpec.Kind(loose: "Heat-set insert"), .insert)
        XCTAssertEqual(HoleSpec.Kind(loose: "Magnet"), .magnet)
        XCTAssertNil(HoleSpec.Kind(loose: "rivet"))
        XCTAssertEqual(HolePresets.size("m3", for: .simple), "M3")
        XCTAssertEqual(HolePresets.size("M 2.5", for: .counterbore), "M2.5")
        XCTAssertEqual(HolePresets.size("1/4-20", for: .simple), "1/4")
        XCTAssertEqual(HolePresets.size("#10-32", for: .nutTrap), "#10")
        XCTAssertEqual(HolePresets.size("10", for: .simple), "#10")
        XCTAssertEqual(HolePresets.size("6x2", for: .magnet), "6×2")
        XCTAssertEqual(HolePresets.size("10 X 3 mm", for: .magnet), "10×3")
        XCTAssertNil(HolePresets.size("6x2", for: .simple))
        XCTAssertNil(HolePresets.size("M3", for: .magnet))
        XCTAssertNil(HolePresets.size("M12", for: .simple))
    }

    func testNutTrapsAndMagnetPocketsUseTheFitClearance() {
        let nut = HolePresets.spec(.nutTrap, size: "M3", clearance: 0.2)
        XCTAssertEqual(nut.diameter, 3.4)
        XCTAssertEqual(nut.nutAcrossFlats, 5.9, "5.5 mm nut + 0.2 mm each side")
        XCTAssertEqual(nut.nutDepth, 2.8, "2.4 mm nut + 0.4 mm")
        XCTAssertEqual(HolePresets.spec(.nutTrap, size: "M3", clearance: 0.1).nutAcrossFlats, 5.7)
        XCTAssertEqual(HolePresets.spec(.nutTrap, size: "1/4").nutAcrossFlats, 11.51)
        let magnet = HolePresets.spec(.magnet, size: "6×2", clearance: 0.1)
        XCTAssertEqual(magnet.diameter, 6.2)
        XCTAssertEqual(HolePresets.defaultDepth(.magnet, size: "6×2"), 2.2)
        XCTAssertEqual(HolePresets.defaultDepth(.magnet, size: "10×3"), 3.2)
        XCTAssertNil(HolePresets.defaultDepth(.nutTrap, size: "M3"), "Nut traps go through")
        var narrow = nut
        narrow.nutAcrossFlats = 3
        XCTAssertFalse(narrow.isValid, "The hex must be wider than the hole")
        narrow.nutAcrossFlats = nil
        XCTAssertFalse(narrow.isValid)
    }

    func testNutTrapCutsAHexPocketOverTheHole() throws {
        let base = try box()
        let spec = HolePresets.spec(.nutTrap, size: "M3", clearance: 0.2)
        let flats = try XCTUnwrap(spec.nutAcrossFlats), depth = try XCTUnwrap(spec.nutDepth), r = spec.diameter / 2
        let hex = 3.0.squareRoot() / 2 * flats * flats
        for angle in [0.0, 30.0] {
            var turned = spec
            turned.nutAngle = angle
            var body = base
            body.cuts = [try XCTUnwrap(ExtrusionCut.hole(turned, at: .zero, on: lid, depth: nil))]
            XCTAssertTrue(body.isValid)
            let solid = try SolidKernel.solid(for: body)
            XCTAssertTrue(solid.isValidSolid)
            XCTAssertEqual(48_000 - solid.volume, hex * depth + .pi * r * r * (20 - depth), accuracy: 1e-3, "angle \(angle)")
        }
        // Flats along x at 0°, corners along x at 30°.
        let flat = spec.nutCorners(around: .zero)
        XCTAssertEqual(flat.map(\.y).max()!, flats / 2, accuracy: 1e-9)
        var turned = spec
        turned.nutAngle = 30
        XCTAssertEqual(turned.nutCorners(around: .zero).map(\.x).max()!, flats / 2, accuracy: 1e-9)
        // A blind nut trap: the hex and a shorter hole.
        var blind = base
        blind.cuts = [try XCTUnwrap(ExtrusionCut.hole(spec, at: .zero, on: lid, depth: 10))]
        XCTAssertEqual(48_000 - (try SolidKernel.solid(for: blind).volume), hex * depth + .pi * r * r * (10 - depth), accuracy: 1e-3)
    }

    func testMagnetPocketIsBlind() throws {
        var body = try box()
        let spec = HolePresets.spec(.magnet, size: "6×2", clearance: 0.2)
        let depth = try XCTUnwrap(HolePresets.defaultDepth(.magnet, size: "6×2"))
        body.cuts = [try XCTUnwrap(ExtrusionCut.hole(spec, at: .zero, on: lid, depth: depth))]
        XCTAssertTrue(body.isValid)
        XCTAssertEqual(48_000 - (try SolidKernel.solid(for: body).volume), .pi * 3.2 * 3.2 * 2.2, accuracy: 1e-3)
    }

    func testNutTrapRoundTripsAndOtherHolesKeepTheirFiles() throws {
        var body = try box()
        var nut = HolePresets.spec(.nutTrap, size: "M4")
        nut.nutAngle = 30
        body.cuts = [try XCTUnwrap(ExtrusionCut.hole(nut, at: .zero, on: lid, depth: nil)),
                     try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.magnet, size: "8×3"), at: .init(x: 15, y: 0), on: lid, depth: 3.2))]
        let project = Project(workspace: Workspace(bodies: [body]))
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(decoded.workspace, project.workspace)
        let simple = try String(decoding: JSONEncoder().encode(HolePresets.spec(.simple, size: "M3")), as: UTF8.self)
        XCTAssertFalse(simple.contains("nut"), "Other holes are saved exactly as before")
    }

    func testHolesRoundTrip() throws {
        var body = try box()
        body.cuts = [try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.simple, size: "M3"), at: .zero, on: lid, depth: nil))]
        let project = Project(workspace: Workspace(bodies: [body]))
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(decoded.workspace, project.workspace)
    }
}
