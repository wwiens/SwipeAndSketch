import XCTest
import simd
@testable import SwipeAndSketchCore

/// Fit and clearance: Subtract with clearance, Peg & Socket, and the Fit Test coupon.
final class FitTests: XCTestCase {
    /// A cylinder of `radius` standing on the top plane at `center`, from z = `bottom` up `height`.
    func cylinder(radius: Double, at center: Point2, bottom: Double = 0, height: Double) throws -> SolidBody {
        let plane = bottom == 0 ? SketchPlane.top : try XCTUnwrap(SketchPlane.through(.init(0, 0, bottom), normal: .init(0, 0, 1)))
        let shape = SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: radius, y: 0))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: plane).first), depth: height)
    }

    func testClearanceGrowsTheToolOnEverySide() throws {
        let target = try box(0, -10, 40, 10, depth: 10)
        let pin = try cylinder(radius: 3, at: Point2(x: 20, y: 0), bottom: -5, height: 20)
        let exact = Subtracting.subtract([pin], from: target)
        let loose = Subtracting.subtract([pin], from: target, clearance: 0.2)
        XCTAssertEqual(loose.used, [pin.id])
        XCTAssertNil(exact.result.cuts[0].clearance, "An exact subtract saves no clearance")
        XCTAssertEqual(loose.result.cuts[0].clearance, 0.2)
        let full = 40.0 * 20 * 10
        XCTAssertEqual(try SolidKernel.solid(for: exact.result).volume, full - .pi * 9 * 10, accuracy: 1e-3)
        XCTAssertEqual(try SolidKernel.solid(for: loose.result).volume, full - .pi * 3.2 * 3.2 * 10, accuracy: 1e-2)
    }

    func testClearanceAroundABoxKeepsItsShape() throws {
        // A boxy tool grows by the clearance on each side (its corners rounded by it).
        let target = try box(0, -10, 40, 10, depth: 10)
        let key = try box(10, -3, 30, 3, depth: 30, at: -10)
        let (result, used) = Subtracting.subtract([key], from: target, clearance: 0.3)
        XCTAssertEqual(used, [key.id])
        let solid = try SolidKernel.solid(for: result)
        let hole = 20.6 * 6.6 - 4 * 0.09 * (1 - .pi / 4)
        XCTAssertEqual(solid.volume, 40 * 20 * 10 - hole * 10, accuracy: 1e-2)
        XCTAssertTrue(solid.isValidSolid)
    }

    func testClearanceIsSavedAndChecked() throws {
        let target = try box(0, -10, 40, 10, depth: 10)
        let pin = try cylinder(radius: 3, at: Point2(x: 20, y: 0), bottom: -5, height: 20)
        let (result, _) = Subtracting.subtract([pin], from: target, clearance: 0.15)
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [result])))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [result])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"clearance\" : 0.15"))

        var tooLoose = result
        tooLoose.cuts[0].clearance = 3
        XCTAssertFalse(tooLoose.isValid)
        var notASubtract = try box(depth: 10)
        var cut = ExtrusionCut(profile: pin.profile, depth: 5)
        cut.clearance = 0.2
        notASubtract.cuts = [cut]
        XCTAssertFalse(notASubtract.isValid, "Only subtracts carry a clearance")
    }

    func testPresetsAndNames() {
        XCTAssertEqual(Fit.Preset.allCases.map(\.clearance), [0.1, 0.2, 0.3])
        XCTAssertEqual(Fit.name(for: 0.2), "Standard")
        XCTAssertEqual(Fit.name(for: 0.15), "Custom")
        XCTAssertEqual(Fit.defaultClearance, 0.2)
    }

    func testPegJoinsItsSolidAndSocketsThePartItPushesInto() throws {
        let base = try box(0, -10, 40, 10, depth: 10)
        let lid = try box(0, -10, 40, 10, depth: 5, at: 10)
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 10), normal: .init(0, 0, 1)))
        let center = face.coordinates(of: SIMD3(20, 0, 10))
        let spec = PegSpec(diameter: 5, height: 4, clearance: 0.2)
        let result = try XCTUnwrap(PegJoint.add(spec, at: center, on: face, to: base.id, in: Workspace(bodies: [base, lid])))
        XCTAssertEqual(result.sockets, [lid.id])

        let pegged = result.workspace.bodies[0], socketed = result.workspace.bodies[1]
        XCTAssertEqual(pegged.cuts.map(\.operation), [.join, .finish], "The peg and its lead-in bevel")
        let pegVolume = try SolidKernel.solid(for: pegged).volume - 40 * 20 * 10
        let cylinder = Double.pi * 2.5 * 2.5 * 4
        XCTAssertLessThan(pegVolume, cylinder)
        XCTAssertGreaterThan(pegVolume, cylinder * 0.95)
        XCTAssertEqual(try SolidKernel.solid(for: pegged).bounds.max.z, 14, accuracy: 1e-6)

        XCTAssertEqual(socketed.cuts.map(\.operation), [.cut])
        XCTAssertEqual(try SolidKernel.solid(for: socketed).volume, 40 * 20 * 5 - .pi * 2.7 * 2.7 * 4.2, accuracy: 1e-3)
    }

    func testSeparatePegIsADowelWithSocketsInBothParts() throws {
        let base = try box(0, -10, 40, 10, depth: 10)
        let lid = try box(0, -10, 40, 10, depth: 5, at: 10)
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 10), normal: .init(0, 0, 1)))
        let spec = PegSpec(diameter: 4, height: 3, clearance: 0.2, separate: true, embed: 4)
        let result = try XCTUnwrap(PegJoint.add(spec, at: face.coordinates(of: SIMD3(20, 0, 10)), on: face, to: base.id, in: Workspace(bodies: [base, lid])))
        XCTAssertEqual(result.workspace.bodies.count, 3)
        let pin = result.workspace.bodies[1]
        XCTAssertEqual(result.peg, pin.id, "The pin follows the solid it stands on")
        XCTAssertEqual(result.sockets, [base.id, lid.id])
        XCTAssertEqual(pin.finishes.first?.edges.count, 2, "Both ends beveled")
        let pinSolid = try SolidKernel.solid(for: pin)
        XCTAssertEqual(pinSolid.bounds.min.z, 6, accuracy: 1e-6)
        XCTAssertEqual(pinSolid.bounds.max.z, 13, accuracy: 1e-6)
        XCTAssertLessThan(pinSolid.volume, .pi * 4 * 7)
        XCTAssertGreaterThan(pinSolid.volume, .pi * 4 * 7 * 0.95)
        // The base: a socket 4.4 wide, 4.2 deep; the lid: 4.4 wide, 3.2 deep.
        XCTAssertEqual(try SolidKernel.solid(for: result.workspace.bodies[0]).volume, 40 * 20 * 10 - .pi * 2.2 * 2.2 * 4.2, accuracy: 1e-3)
        XCTAssertEqual(try SolidKernel.solid(for: result.workspace.bodies[2]).volume, 40 * 20 * 5 - .pi * 2.2 * 2.2 * 3.2, accuracy: 1e-3)
        XCTAssertTrue(result.workspace.bodies[0].finishes.isEmpty && result.workspace.bodies[0].cuts.map(\.operation) == [.cut], "Nothing joined to the base")
    }

    func testSeparatePegThatOnlyStandsOnTheFace() throws {
        let base = try box(0, -10, 40, 10, depth: 10)
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 10), normal: .init(0, 0, 1)))
        let standing = PegSpec(diameter: 5, height: 6, separate: true, embed: 0)
        let result = try XCTUnwrap(PegJoint.add(standing, at: face.coordinates(of: SIMD3(20, 0, 10)), on: face, to: base.id, in: Workspace(bodies: [base])))
        XCTAssertEqual(result.sockets, [])
        XCTAssertEqual(result.workspace.bodies[0], base, "The base is untouched")
        XCTAssertEqual(result.workspace.bodies[1].finishes.first?.edges.count, 1, "Only the tip is beveled")
        XCTAssertNil(PegJoint.add(standing, at: face.coordinates(of: SIMD3(80, 0, 10)), on: face, to: base.id, in: Workspace(bodies: [base])), "Off the face")
        var sunk = standing
        sunk.embed = 3
        XCTAssertNil(PegJoint.add(sunk, at: face.coordinates(of: SIMD3(80, 0, 10)), on: face, to: base.id, in: Workspace(bodies: [base])), "Off the face")
        sunk.embed = 120
        XCTAssertFalse(sunk.isValid)
    }

    func testPegInOpenSpaceHasNoSocketAndAPegOffTheSolidIsRefused() throws {
        let base = try box(0, -10, 40, 10, depth: 10)
        let elsewhere = try box(100, -10, 140, 10, depth: 10)
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 10), normal: .init(0, 0, 1)))
        let alone = try XCTUnwrap(PegJoint.add(PegSpec(), at: face.coordinates(of: SIMD3(20, 0, 10)), on: face, to: base.id,
                                              in: Workspace(bodies: [base, elsewhere])))
        XCTAssertEqual(alone.sockets, [])
        XCTAssertEqual(alone.workspace.bodies[1], elsewhere)
        XCTAssertNil(PegJoint.add(PegSpec(), at: face.coordinates(of: SIMD3(70, 0, 10)), on: face, to: base.id, in: Workspace(bodies: [base])))
        XCTAssertNil(PegJoint.add(PegSpec(diameter: 0.2), at: face.coordinates(of: SIMD3(20, 0, 10)), on: face, to: base.id,
                                  in: Workspace(bodies: [base])))
    }

    func testPegOnASideFaceSocketsHiddenSolidsToo() throws {
        // A peg on the +X side pushes into a block beside it, and into a hidden one (hidden to reach the face).
        let base = try box(0, -10, 40, 10, depth: 10)
        let beside = try box(40, -10, 60, 10, depth: 10)
        var hidden = try box(40, -10, 60, 10, depth: 10)
        hidden.hidden = true
        let face = try XCTUnwrap(SketchPlane.through(.init(40, 0, 0), normal: .init(1, 0, 0)))
        let center = face.coordinates(of: SIMD3(40, 0, 5))
        let result = try XCTUnwrap(PegJoint.add(PegSpec(diameter: 4, height: 6, clearance: 0.1), at: center, on: face, to: base.id,
                                                in: Workspace(bodies: [base, beside, hidden])))
        XCTAssertEqual(result.sockets, [beside.id, hidden.id])
        XCTAssertEqual(result.workspace.bodies[2].hidden, true, "It stays hidden")
        XCTAssertEqual(try SolidKernel.solid(for: result.workspace.bodies[0]).bounds.max.x, 46, accuracy: 1e-6)
        XCTAssertEqual(try SolidKernel.solid(for: result.workspace.bodies[1]).volume, 20 * 20 * 10 - .pi * 2.1 * 2.1 * 6.1, accuracy: 1e-3)
    }

    func testFitTestCoupon() throws {
        let coupon = FitTest.coupon()
        XCTAssertEqual(coupon.count, 2)
        let plate = coupon[0], peg = coupon[1]
        XCTAssertTrue(plate.isValid && peg.isValid)
        XCTAssertEqual(plate.cuts.compactMap(\.hole?.diameter), FitTest.clearances.map { 6 + 2 * $0 })
        let holes = FitTest.clearances.reduce(0) { $0 + .pi * pow(3 + $1, 2) * 4 }
        let plateSolid = try SolidKernel.solid(for: plate)
        XCTAssertEqual(plateSolid.volume, 70 * 16 * 4 - 4.5 * 4 - holes, accuracy: 1e-3)
        XCTAssertTrue(plateSolid.isValidSolid)
        let pegSolid = try SolidKernel.solid(for: peg)
        XCTAssertEqual(pegSolid.bounds.max.z, 11, accuracy: 1e-6)
        XCTAssertLessThan(pegSolid.bounds.max.y, 0, "The peg piece lies clear of the plate")
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: coupon)))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, coupon)
    }

    func testFitTestGoesBesideTheModel() throws {
        XCTAssertEqual(FitTest.origin(beside: Workspace()), .zero)
        let model = Workspace(bodies: [try box(0, -10, 40.5, 10, depth: 10)])
        XCTAssertEqual(FitTest.origin(beside: model), Point2(x: 61, y: 0))
    }

    func testAssistantAddsPegsSubtractsWithClearanceAndAddsTheFitTest() throws {
        let base = try box(0, -10, 40, 10, depth: 10), lid = try box(0, -10, 40, 10, depth: 5, at: 10)
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [base, lid]))
        let message = try bench.peg(body: "Body 01", face: "top", at: [SIMD3(8, 0, 10), SIMD3(32, 0, 10)], diameter: 4, height: 3, clearance: 0.15)
        XCTAssertTrue(message.contains("2 Ø4 × 3 mm pegs") && message.contains("sockets in Body 02 with 0.15 mm clearance"), message)
        XCTAssertEqual(bench.workspace.bodies[1].cuts.count, 2)
        XCTAssertEqual(try SolidKernel.solid(for: bench.workspace.bodies[1]).volume, 40 * 20 * 5 - 2 * .pi * 2.15 * 2.15 * 3.15, accuracy: 1e-3)
        XCTAssertThrowsError(try bench.peg(body: "Body 01", face: "top", at: [SIMD3(80, 0, 10)], diameter: 4, height: 3, clearance: 0.2))
        XCTAssertThrowsError(try bench.peg(body: "Body 01", face: "top", diameter: 4, height: 3, clearance: 5))
        var dowels = AssistantWorkbench(workspace: Workspace(bodies: [base, lid]))
        let dowel = try dowels.peg(body: "Body 01", face: "top", diameter: 4, height: 3, clearance: 0.2, separate: true)
        XCTAssertTrue(dowel.contains("separate peg") && dowel.contains("Body 01, Body 03"), dowel)
        XCTAssertEqual(dowels.workspace.bodies.count, 3)

        var cutter = AssistantWorkbench(workspace: Workspace(bodies: [base, try cylinder(radius: 3, at: Point2(x: 20, y: 0), bottom: -5, height: 20)]))
        XCTAssertThrowsError(try cutter.combine(union: true, target: "Body 01", tools: ["Body 02"], keepTools: true, clearance: 0.2))
        let text = try cutter.combine(union: false, target: "Body 01", tools: ["Body 02"], keepTools: true, clearance: 0.2)
        XCTAssertTrue(text.contains("with 0.2 mm clearance"), text)
        XCTAssertEqual(cutter.workspace.bodies.count, 2)
        XCTAssertTrue(cutter.summary(maximumLines: 40).contains("subtracted solid with 0.2 mm clearance"))

        var coupon = AssistantWorkbench(workspace: Workspace(bodies: [base]))
        XCTAssertTrue(try coupon.fitTest().contains("0.10, 0.15, 0.20"))
        XCTAssertEqual(coupon.workspace.bodies.count, 3)
    }
}
