import XCTest
import simd
@testable import SwipeAndSketchCore

/// Holes, threads, text, and pegs found from their faces and made again with new values, in their
/// place among the solid's steps (October 24, 2026).
final class FeatureEditingTests: XCTestCase {
    let top = SketchPlane.through(.init(0, 0, 12), normal: .init(0, 0, 1))!

    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    /// A 30 × 30 × 12 block with a through hole of `diameter` at its center, then a pocket after it.
    func drilledBlock(_ diameter: Double = 6.8) throws -> SolidBody {
        var block = try box(-15, -15, 15, 15, depth: 12)
        block.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HoleSpec(kind: .simple, size: "", diameter: diameter), at: .zero, on: top, depth: nil)))
        let pocket = SketchShape(kind: .rectangle, plane: top, start: Point2(x: 8, y: 8), end: Point2(x: 12, y: 12))
        block.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [pocket], on: top).first), depth: -3))
        return block
    }

    // MARK: Holes

    func testAHoleIsFoundAroundItsAxisAndChangedInPlace() throws {
        let block = try drilledBlock()
        XCTAssertEqual(block.holeCut(around: SIMD3(0, 0, 6)), 0)
        XCTAssertEqual(block.holeCut(around: SIMD3(3.3, 0, 2)), 0, "Anywhere inside it")
        XCTAssertNil(block.holeCut(around: SIMD3(10, 10, 11)), "The pocket is not a Hole-tool hole")
        XCTAssertNil(block.holeCut(around: SIMD3(6, 0, 6)), "Beside it")

        let counterbore = try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.counterbore, size: "M4"), at: .zero, on: top, depth: 8))
        let changed = block.placing(counterbore, replacing: 0)
        XCTAssertEqual(changed.cuts.map(\.operation), [.hole, .cut], "The pocket still comes after it")
        XCTAssertEqual(changed.cuts[0].hole?.kind, .counterbore)
        XCTAssertEqual(changed.cuts[1], block.cuts[1])
        XCTAssertEqual(changed.cuts[0].id, block.cuts[0].id, "The step keeps its id")
        XCTAssertGreaterThan(try volume(changed), try volume(block), "Blind, and narrower below the counterbore")
        XCTAssertEqual(block.placing(counterbore, replacing: nil).cuts.count, 3, "Without an index it is added")
    }

    // MARK: Text

    func testTextIsFoundFromItsLettersAndChanged() throws {
        var block = try box(-30, -15, 30, 15, depth: 12)
        let spec = try XCTUnwrap(TextSpec.make("AB", font: TextFonts.defaultFont, height: 8, center: top.coordinates(of: SIMD3(0, 0, 12)), angle: 0))
        block.cuts.append(try XCTUnwrap(ExtrusionCut.text(spec, on: top, depth: 1)))
        XCTAssertEqual(block.textCut(at: SIMD3(0, 0, 13)), 0, "On top of the letters")
        XCTAssertEqual(block.textCut(at: SIMD3(0, 0, 12.5)), 0, "On their sides")
        XCTAssertNil(block.textCut(at: SIMD3(20, 0, 13)), "Beyond them")
        XCTAssertNil(block.textCut(at: SIMD3(0, 0, 6)), "Inside the block")
        XCTAssertNil(block.textCut(at: SIMD3(0, 0, 12)), "The face between the letters is the block's")

        let longer = try XCTUnwrap(TextSpec.make("ABCD", font: TextFonts.defaultFont, height: 8, center: spec.center, angle: 0))
        let changed = block.placing(try XCTUnwrap(ExtrusionCut.text(longer, on: top, depth: -0.8)), replacing: 0)
        XCTAssertEqual(changed.cuts.count, 1)
        XCTAssertEqual(changed.cuts[0].text?.text, "ABCD")
        XCTAssertLessThan(try volume(changed), 60 * 30 * 12, "Now sunk")
        XCTAssertEqual(changed.textCut(at: SIMD3(0, 0, 11.5)), 0, "Found from its floor")
    }

    // MARK: Threads

    func testAThreadAlongItsWholeFaceIsSetUpAsItWas() throws {
        let block = try drilledBlock()
        let solid = try SolidKernel.solid(for: block)
        let face = try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil })
        let spec = try XCTUnwrap(block.threadSpec(onFace: face, of: solid, clearance: 0.2))
        let threaded = try XCTUnwrap(block.threading(spec, at: 1))
        XCTAssertEqual(threaded.cuts.map(\.operation), [.hole, .thread, .cut], "Threaded before the pocket")

        let setup = try XCTUnwrap(threaded.threadSetup(at: 1))
        XCTAssertEqual(setup.base, block)
        XCTAssertEqual(setup.spec, spec)
        XCTAssertNil(setup.length)
        var again = try XCTUnwrap(setup.base.threading(setup.spec, at: 1))
        again.cuts[1].id = threaded.cuts[1].id
        XCTAssertEqual(again, threaded, "Done with nothing changed changes nothing")
    }

    func testAShortenedThreadKeepsItsLengthEndAndHelix() throws {
        let block = try drilledBlock()
        let solid = try SolidKernel.solid(for: block)
        let face = try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil })
        var whole = try XCTUnwrap(block.threadSpec(onFace: face, of: solid, clearance: 0.2))
        whole = whole.with(size: ThreadPresets.size(named: "M8"), diameter: 8, pitch: 1)
        whole.starts = 2
        for atEnd in [true, false] {
            let short = try XCTUnwrap(whole.shortened(to: 5, atEnd: atEnd))
            let threaded = try XCTUnwrap(block.threading(short))
            let setup = try XCTUnwrap(threaded.threadSetup(at: 2))
            XCTAssertEqual(try XCTUnwrap(setup.length), 5, accuracy: 1e-9)
            XCTAssertEqual(setup.atEnd, atEnd)
            XCTAssertEqual(setup.spec.pitch, 1)
            XCTAssertEqual(setup.spec.starts, 2)
            XCTAssertEqual(setup.spec.threadedLength, whole.threadedLength, accuracy: 1e-9, "Set up along the whole face")
            let again = try XCTUnwrap(setup.spec.shortened(to: 5, atEnd: setup.atEnd))
            XCTAssertEqual(simd_distance(again.origin, short.origin), 0, accuracy: 1e-9, "The same helix")
            XCTAssertEqual(again.reference, short.reference)
        }
    }

    // MARK: Pegs

    func lidAndBase() throws -> (base: SolidBody, lid: SolidBody, face: SketchPlane, center: Point2) {
        let base = try box(0, -10, 40, 10, depth: 10)
        let lid = try box(0, -10, 40, 10, depth: 5, at: 10)
        let face = try XCTUnwrap(SketchPlane.through(.init(0, 0, 10), normal: .init(0, 0, 1)))
        return (base, lid, face, face.coordinates(of: SIMD3(20, 0, 10)))
    }

    func testAJoinedPegIsFoundWithItsSocketAndMadeAgain() throws {
        var (base, lid, face, center) = try lidAndBase()
        // Something made after the peg in each solid stays after it.
        let notch = SketchShape(kind: .rectangle, plane: face, start: face.coordinates(of: SIMD3(2, -2, 10)), end: face.coordinates(of: SIMD3(6, 2, 10)))
        let added = try XCTUnwrap(PegJoint.add(PegSpec(diameter: 5, height: 4, clearance: 0.15), at: center, on: face, to: base.id, in: Workspace(bodies: [base, lid])))
        base = added.workspace.bodies[0]
        lid = added.workspace.bodies[1]
        base.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [notch], on: face).first), depth: -2))
        let workspace = Workspace(bodies: [base, lid])
        let tag = try XCTUnwrap(base.cuts[0].peg)
        XCTAssertEqual(base.cuts.map(\.peg), [tag, tag, nil], "The peg and its bevel are tagged")
        XCTAssertEqual(lid.cuts.map(\.peg), [tag], "So is its socket")

        XCTAssertEqual(base.pegTag(at: SIMD3(22.5, 0, 12)), tag, "On the peg's side")
        XCTAssertEqual(lid.pegTag(at: SIMD3(22.65, 0, 12)), tag, "On the socket's wall")
        XCTAssertNil(base.pegTag(at: SIMD3(35, 0, 10)))

        let old = try XCTUnwrap(PegJoint.existing(tag, in: workspace, preferring: lid.id, clearance: 0.3))
        XCTAssertEqual(old.bodyID, base.id)
        XCTAssertEqual(old.spec.diameter, 5, accuracy: 1e-9)
        XCTAssertEqual(old.spec.height, 4, accuracy: 1e-9)
        XCTAssertEqual(old.spec.clearance, 0.15, accuracy: 1e-9, "From its socket")
        XCTAssertFalse(old.spec.separate)
        XCTAssertEqual(simd_distance(old.plane.point(old.center), SIMD3(20, 0, 10)), 0, accuracy: 1e-9)
        XCTAssertEqual(old.base.bodies[0].cuts.map(\.operation), [.cut], "Only the notch is left")
        XCTAssertTrue(old.base.bodies[1].cuts.isEmpty)
        XCTAssertEqual(old.slots, [base.id: 0, lid.id: 0])

        var bigger = old.spec
        bigger.diameter = 8
        bigger.height = 3
        let result = try XCTUnwrap(PegJoint.replace(old, with: bigger, at: old.center))
        XCTAssertEqual(result.sockets, [lid.id])
        let pegged = result.workspace.bodies[0], socketed = result.workspace.bodies[1]
        XCTAssertEqual(pegged.cuts.map(\.operation), [.join, .finish, .cut], "Back before the notch")
        XCTAssertEqual(pegged.cuts.map(\.peg), [tag, tag, nil], "Same tag")
        XCTAssertEqual(pegged.cuts[0].profile.circle?.radius ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(try volume(socketed), 40 * 20 * 5 - .pi * 4.15 * 4.15 * 3.15, accuracy: 1e-3)

        let none = PegJoint.existing(UUID(), in: workspace, clearance: 0.2)
        XCTAssertNil(none)
    }

    func testASeparatePegKeepsItsPlaceAndItsSockets() throws {
        let (base, lid, face, center) = try lidAndBase()
        let spec = PegSpec(diameter: 4, height: 3, clearance: 0.2, separate: true, embed: 4)
        let added = try XCTUnwrap(PegJoint.add(spec, at: center, on: face, to: base.id, in: Workspace(bodies: [base, lid])))
        let pin = added.workspace.bodies[1]
        let tag = try XCTUnwrap(pin.peg?.id)
        XCTAssertEqual(pin.peg, PegPin(id: tag, body: base.id, clearance: 0.2, embed: 4))
        XCTAssertEqual(pin.pegTag(at: SIMD3(0, 0, 0)), tag, "Anywhere on the pin")

        let old = try XCTUnwrap(PegJoint.existing(tag, in: added.workspace, clearance: 0.3))
        XCTAssertTrue(old.spec.separate)
        XCTAssertEqual(old.spec.embed, 4, accuracy: 1e-9)
        XCTAssertEqual(old.spec.height, 3, accuracy: 1e-9)
        XCTAssertEqual(old.spec.diameter, 4, accuracy: 1e-9)
        XCTAssertEqual(old.spec.clearance, 0.2, accuracy: 1e-9)
        XCTAssertEqual(old.pinIndex, 1)
        XCTAssertEqual(old.base.bodies.map(\.id), [base.id, lid.id])
        XCTAssertTrue(old.base.bodies.allSatisfy(\.cuts.isEmpty), "Both sockets come out")
        XCTAssertEqual(simd_distance(old.plane.point(old.center), SIMD3(20, 0, 10)), 0, accuracy: 1e-9)

        var taller = old.spec
        taller.height = 4
        let result = try XCTUnwrap(PegJoint.replace(old, with: taller, at: old.center))
        XCTAssertEqual(result.workspace.bodies.map(\.peg?.id), [nil, tag, nil], "The pin stays second")
        XCTAssertEqual(result.workspace.bodies[1].depth, 8, accuracy: 1e-9)
        XCTAssertEqual(try volume(result.workspace.bodies[2]), 40 * 20 * 5 - .pi * 2.2 * 2.2 * 4.2, accuracy: 1e-3)
    }

    func testPegTagsAreSaved() throws {
        let (base, lid, face, center) = try lidAndBase()
        let joined = try XCTUnwrap(PegJoint.add(PegSpec(), at: center, on: face, to: base.id, in: Workspace(bodies: [base, lid])))
        let separate = try XCTUnwrap(PegJoint.add(PegSpec(separate: true, embed: 3), at: face.coordinates(of: SIMD3(8, 0, 10)), on: face,
                                                  to: base.id, in: joined.workspace))
        let data = try ProjectCodec.encode(Project(workspace: separate.workspace))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, separate.workspace.bodies)
        var badPin = separate.workspace.bodies[1]
        badPin.peg?.clearance = 5
        XCTAssertFalse(badPin.isValid)
    }

    // MARK: Assistant

    func testAssistantEditsHolesTextThreadsAndPegs() throws {
        var (base, lid, face, center) = try lidAndBase()
        base = try XCTUnwrap(PegJoint.add(PegSpec(diameter: 5, height: 4), at: center, on: face, to: base.id, in: Workspace(bodies: [base, lid]))).workspace.bodies[0]
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try drilledBlock(), base]))
        _ = try bench.text(body: "Body 01", face: "top", text: "V1", height: 5, depth: 0.6, at: SIMD3(0, -9, 12))

        let hole = try bench.editFeature(body: "Body 01", feature: "hole", which: "1", kind: "countersink", size: "M3")
        XCTAssertTrue(hole.contains("Ø3.4 countersink through"), hole)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.map(\.operation), [.hole, .cut, .text])
        let text = try bench.editFeature(body: "Body 01", feature: "text", which: "last", depth: -0.4, text: "V2")
        XCTAssertTrue(text.contains("\"V2\""), text)
        XCTAssertEqual(bench.workspace.bodies[0].cuts[2].depth, -0.4)

        _ = try bench.thread(body: "Body 01", face: "hole", size: "M4", diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false)
        let thread = try bench.editFeature(body: "Body 01", feature: "thread", which: "1", pitch: 0.5)
        XCTAssertTrue(thread.contains("M4 × 0.5"), thread)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.last?.thread?.pitch, 0.5)

        let peg = try bench.editFeature(body: "Body 02", feature: "peg", which: "1", diameter: 6)
        XCTAssertTrue(peg.contains("Ø6 × 4 mm"), peg)
        XCTAssertThrowsError(try bench.editFeature(body: "Body 01", feature: "peg", which: "1"))
        XCTAssertThrowsError(try bench.editFeature(body: "Body 01", feature: "hole", which: "3"))
        XCTAssertThrowsError(try bench.editFeature(body: "Body 01", feature: "fillet", which: "1"))
    }
}
