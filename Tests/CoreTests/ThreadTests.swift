import XCTest
import simd
import SSKernel
@testable import SwipeAndSketchCore

/// Modeled threads on holes and round bosses.
final class ThreadTests: XCTestCase {
    /// A 30 × 30 × 12 block with a through hole of `diameter` at its center.
    func drilledBlock(_ diameter: Double) throws -> SolidBody {
        var block = try box(-15, -15, 15, 15, depth: 12)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 12), normal: .init(0, 0, 1)))
        block.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HoleSpec(kind: .simple, size: "", diameter: diameter), at: .zero, on: top, depth: nil)))
        return block
    }

    /// A round boss of `diameter`, `height` tall, standing on a 30 × 30 × 4 plate.
    func bossOnPlate(_ diameter: Double, height: Double = 16) throws -> SolidBody {
        var plate = try box(-15, -15, 15, 15, depth: 4)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 4), normal: .init(0, 0, 1)))
        let circle = SketchShape(kind: .circle, plane: top, start: .zero, end: Point2(x: diameter / 2, y: 0))
        plate.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [circle], on: top).first), depth: height, operation: .join))
        return plate
    }

    func cylindricalFace(of body: SolidBody) throws -> (KernelSolid, Int) {
        let solid = try SolidKernel.solid(for: body)
        let face = try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil })
        return (solid, face)
    }

    func testTapDrilledHoleTakesAnM8NutThread() throws {
        let block = try drilledBlock(6.8)
        let (solid, face) = try cylindricalFace(of: block)
        let spec = try XCTUnwrap(block.threadSpec(onFace: face, of: solid, clearance: 0.2))
        XCTAssertTrue(spec.isInternal)
        XCTAssertEqual(spec.size, "M8")
        XCTAssertEqual(spec.pitch, 1.25)
        XCTAssertEqual(spec.length, 12 + 2 * 1.25, accuracy: 1e-6, "A pitch past both open ends")
        XCTAssertEqual(spec.title, "M8 × 1.25")

        let start = Date()
        let threaded = try XCTUnwrap(block.threading(spec))
        let result = try SolidKernel.solid(for: threaded)
        print("[thread timing] M8 × 12 mm nut thread: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        XCTAssertTrue(result.isValidSolid)
        // Between a plain bore at the minor and one at the major diameter (each opened up by the clearance).
        let block3D = 30.0 * 30 * 12
        XCTAssertLessThan(result.volume, block3D - .pi * pow(spec.rootRadius, 2) * 12)
        XCTAssertGreaterThan(result.volume, block3D - .pi * pow(spec.crestRadius, 2) * 12)
        XCTAssertEqual(threaded.cuts.last?.operation, .thread)
    }

    func testRoundBossTakesABoltThread() throws {
        let boss = try bossOnPlate(8)
        let (solid, face) = try cylindricalFace(of: boss)
        let spec = try XCTUnwrap(boss.threadSpec(onFace: face, of: solid, clearance: 0.1))
        XCTAssertFalse(spec.isInternal)
        XCTAssertEqual(spec.size, "M8")
        XCTAssertEqual(spec.length, 16 + 1.25 + 0.02, accuracy: 1e-6, "A pitch past the open top, a hair into the plate")
        let threaded = try XCTUnwrap(boss.threading(spec))
        let result = try SolidKernel.solid(for: threaded)
        XCTAssertTrue(result.isValidSolid)
        let plate = 30.0 * 30 * 4
        // (Less the hair-thin ring the grooves leave in the plate around the boss.)
        XCTAssertGreaterThan(result.volume, plate + .pi * pow(spec.rootRadius, 2) * 16 - .pi * (pow(4.05, 2) - pow(spec.rootRadius, 2)) * 0.02)
        XCTAssertLessThan(result.volume, plate + .pi * pow(spec.crestRadius, 2) * 16)
        // The plate under the boss is untouched.
        XCTAssertEqual(result.bounds.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(result.bounds.max.x, 15, accuracy: 1e-6)
    }

    func testLargeBossTakesACustomJarThread() throws {
        let boss = try bossOnPlate(24.5, height: 8)
        let (solid, face) = try cylindricalFace(of: boss)
        var spec = try XCTUnwrap(boss.threadSpec(onFace: face, of: solid, clearance: 0.2))
        XCTAssertEqual(spec.size, "", "Not near an ISO size")
        XCTAssertEqual(spec.majorDiameter, 24.5)
        XCTAssertEqual(spec.pitch, 3)
        spec.pitch = 2.5
        XCTAssertTrue(try SolidKernel.solid(for: XCTUnwrap(boss.threading(spec))).isValidSolid)
        spec.pitch = 25
        XCTAssertFalse(spec.isValid, "Out of range")
    }

    func testMirrorTurnsTheHandAndMovingCarriesTheThread() throws {
        let block = try drilledBlock(6.8)
        let (solid, face) = try cylindricalFace(of: block)
        let threaded = try XCTUnwrap(block.threading(try XCTUnwrap(block.threadSpec(onFace: face, of: solid, clearance: 0.2))))
        let volume = try SolidKernel.solid(for: threaded).volume

        let reflection = try XCTUnwrap(Reflection(across: .right))
        let image = try XCTUnwrap(threaded.mirrored(by: reflection))
        XCTAssertEqual(image.cuts.last?.thread?.leftHanded, true)
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, volume, accuracy: volume * 1e-4)
        XCTAssertNil(try XCTUnwrap(image.mirrored(by: reflection)).cuts.last?.thread?.leftHanded, "Mirrored twice is right-handed again")

        let moved = try XCTUnwrap(threaded.transformed(by: .rotate(degrees: 90, about: .init(1, 0, 0), through: .zero)))
        let movedSolid = try SolidKernel.solid(for: moved)
        XCTAssertEqual(movedSolid.volume, volume, accuracy: volume * 1e-4)
        XCTAssertEqual(movedSolid.bounds.max.y, 0, accuracy: 1e-4, "Turned with the block")
    }

    func testThreadIsSavedAndChecked() throws {
        let boss = try bossOnPlate(6)
        let (solid, face) = try cylindricalFace(of: boss)
        let threaded = try XCTUnwrap(boss.threading(try XCTUnwrap(boss.threadSpec(onFace: face, of: solid, clearance: 0.2))))
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [threaded])))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"internal\" : false"))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [threaded])

        var tooDeep = try XCTUnwrap(threaded.cuts.last?.thread)
        tooDeep.majorDiameter = 12
        tooDeep.pitch = 0.5
        XCTAssertTrue(tooDeep.isValid, "The ISO profile always fits its pitch")
        tooDeep.clearance = 5
        XCTAssertFalse(tooDeep.isValid)
        // A flat face takes no thread.
        let flat = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0) != nil })
        XCTAssertNil(boss.threadSpec(onFace: flat, of: solid, clearance: 0.2))
    }

    func testSuggestions() {
        XCTAssertEqual(ThreadPresets.suggestion(internal: true, surfaceDiameter: 4.2, clearance: 0.2).size, "M5")
        XCTAssertEqual(ThreadPresets.suggestion(internal: true, surfaceDiameter: 10.2, clearance: 0.2).size, "M12")
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 5.9, clearance: 0.2).size, "M6")
        let jar = ThreadPresets.suggestion(internal: true, surfaceDiameter: 60, clearance: 0.2)
        XCTAssertEqual(jar.size, "")
        XCTAssertEqual(jar.pitch, 3)
        XCTAssertEqual(jar.major, 60 + 1.082532 * 3, accuracy: 1e-9)
    }

    func testDraggingAThreadedSolidMovesItsBuiltShapeInsteadOfRebuilding() throws {
        let block = try drilledBlock(6.8)
        let (solid, face) = try cylindricalFace(of: block)
        let threaded = try XCTUnwrap(block.threading(try XCTUnwrap(block.threadSpec(onFace: face, of: solid, clearance: 0.2))))
        let built = try SolidKernel.solid(for: threaded)
        let workspace = Workspace(bodies: [threaded])
        let turn = RigidTransform.rotate(degrees: 30, about: .init(0, 0, 1), through: .init(5, 0, 0))
        let start = Date()
        for step in 1...20 {
            let move = RigidTransform(rotation: turn.rotation, pivot: turn.pivot, translation: .init(Double(step), 0, 0))
            XCTAssertNotNil(workspace.transformingBody(threaded.id, by: move, copy: false))
        }
        let perFrame = Date().timeIntervalSince(start) / 20
        print("[thread timing] drag frame: \(Int(perFrame * 1000)) ms")
        XCTAssertLessThan(perFrame, 0.1, "A drag frame must not rebuild the thread")

        // The moved shape matches a rebuild of the moved definition.
        let move = RigidTransform(rotation: turn.rotation, pivot: turn.pivot, translation: .init(4, 0, 0))
        let moved = try XCTUnwrap(workspace.transformingBody(threaded.id, by: move, copy: false)).workspace.bodies[0]
        let fast = try SolidKernel.solid(for: moved)
        var fresh = moved
        fresh.id = UUID()
        let rebuilt = try SolidKernel.solid(for: fresh)
        XCTAssertEqual(fast.volume, rebuilt.volume, accuracy: built.volume * 1e-5)
        XCTAssertEqual(simd_distance(fast.bounds.min, rebuilt.bounds.min), 0, accuracy: 1e-3)
        XCTAssertEqual(simd_distance(fast.bounds.max, rebuilt.bounds.max), 0, accuracy: 1e-3)
        XCTAssertEqual(fast.faceCount, rebuilt.faceCount)
        XCTAssertTrue(fast.isValidSolid)
    }

    func testAssistantThreadsAHoleAndABoss() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try drilledBlock(6.8), try bossOnPlate(10)]))
        let nut = try bench.thread(body: "Body 01", face: "hole", size: nil, diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false)
        XCTAssertTrue(nut.contains("M8 × 1.25 nut thread"), nut)
        let bolt = try bench.thread(body: "Body 02", face: "boss", size: "m10", diameter: nil, pitch: nil, clearance: 0, leftHanded: true)
        XCTAssertTrue(bolt.contains("M10 × 1.5 LH bolt thread"), bolt)
        XCTAssertEqual(bench.workspace.bodies.map { $0.cuts.last?.operation }, [.thread, .thread])
        XCTAssertThrowsError(try bench.thread(body: "Body 01", face: "boss", size: nil, diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false))
        XCTAssertThrowsError(try bench.thread(body: "Body 02", face: "top", size: nil, diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false))
        XCTAssertTrue(bench.summary().contains("external thread M10 × 1.5 LH"), bench.summary())
    }

    // MARK: Lead-ins and matching parts

    func threaded(_ body: SolidBody, clearance: Double = 0.2, edit: (inout ThreadSpec) -> Void = { _ in }) throws -> SolidBody {
        let (solid, face) = try cylindricalFace(of: body)
        var spec = try XCTUnwrap(body.threadSpec(onFace: face, of: solid, clearance: clearance))
        edit(&spec)
        return try XCTUnwrap(body.threading(spec))
    }

    /// Volume both solids share (0 when they only touch).
    func overlap(_ a: SolidBody, _ b: SolidBody) throws -> Double {
        let shared = try? SolidKernel.boolean(SolidKernel.solid(for: a), SolidKernel.solid(for: b), .intersect)
        return shared?.volume ?? 0
    }

    func testThreadsRecordTheirOpenEndsAndTakeALeadInThere() throws {
        let block = try drilledBlock(6.8)
        let (solid, face) = try cylindricalFace(of: block)
        let spec = try XCTUnwrap(block.threadSpec(onFace: face, of: solid, clearance: 0.2))
        let ends = try XCTUnwrap(spec.ends)
        XCTAssertEqual(ends.start, 1.25, accuracy: 1e-6)
        XCTAssertEqual(ends.end, 13.25, accuracy: 1e-6)
        XCTAssertTrue(ends.startOpen && ends.endOpen, "A through hole opens at both ends")
        XCTAssertEqual(spec.leadIn, true, "On by default")

        var square = spec
        square.leadIn = nil
        let beveled = try SolidKernel.solid(for: XCTUnwrap(block.threading(spec)))
        let plain = try SolidKernel.solid(for: XCTUnwrap(block.threading(square)))
        XCTAssertTrue(beveled.isValidSolid)
        XCTAssertLessThan(beveled.volume, plain.volume - 1, "Two countersinks")
        // Just past the thread's crest, just inside each face: wall without a lead-in, air with one.
        for z in [0.02, 11.98] {
            let point = SSKVec3(x: spec.crestRadius + 0.05, y: 0, z: z)
            XCTAssertTrue(ssk_point_inside(plain.handle, point))
            XCTAssertFalse(ssk_point_inside(beveled.handle, point))
        }
    }

    func testABossIsBeveledAtItsTipOnly() throws {
        let boss = try bossOnPlate(8)
        let (solid, face) = try cylindricalFace(of: boss)
        let spec = try XCTUnwrap(boss.threadSpec(onFace: face, of: solid, clearance: 0.2))
        let ends = try XCTUnwrap(spec.ends)
        XCTAssertNotEqual(ends.startOpen, ends.endOpen, "Open at its tip, closed where it stands on the plate")
        XCTAssertEqual(ends.end - ends.start, 16, accuracy: 1e-6)
        var square = spec
        square.leadIn = nil
        let beveled = try SolidKernel.solid(for: XCTUnwrap(boss.threading(spec)))
        let plain = try SolidKernel.solid(for: XCTUnwrap(boss.threading(square)))
        XCTAssertTrue(beveled.isValidSolid)
        XCTAssertLessThan(beveled.volume, plain.volume - 0.1)
        XCTAssertEqual(beveled.volume, plain.volume, accuracy: 10, "Only the tip's first turn")
        // The tip's face shrinks to the root.
        XCTAssertFalse(ssk_point_inside(beveled.handle, SSKVec3(x: spec.rootRadius + 0.2, y: 0, z: 19.95)))
        XCTAssertTrue(ssk_point_inside(beveled.handle, SSKVec3(x: spec.rootRadius - 0.2, y: 0, z: 19.95)))
    }

    func testOlderThreadsWithoutEndsStillBuild() throws {
        let boss = try bossOnPlate(8)
        let (solid, face) = try cylindricalFace(of: boss)
        var spec = try XCTUnwrap(boss.threadSpec(onFace: face, of: solid, clearance: 0.2))
        spec.ends = nil
        spec.leadIn = nil
        let threaded = try XCTUnwrap(boss.threading(spec))
        XCTAssertTrue(try SolidKernel.solid(for: threaded).isValidSolid)
        XCTAssertEqual(threaded.matableThreads, [], "Nowhere known to screw a part on")
        XCTAssertNil(threaded.matingPart(.nut, forThreadAt: threaded.cuts.count - 1))
    }

    func testAMatchingNutScrewsOntoABoltInStep() throws {
        let bolt = try threaded(try bossOnPlate(8))
        let index = bolt.cuts.count - 1
        let spec = try XCTUnwrap(bolt.cuts[index].thread)
        XCTAssertEqual(ThreadMate.choices(for: spec), [.nut, .cap])
        XCTAssertNil(bolt.matingPart(.bolt, forThreadAt: index), "A bolt's thread takes a nut or cap")

        let nut = try XCTUnwrap(bolt.matingPart(.nut, forThreadAt: index))
        let built = try SolidKernel.solid(for: nut)
        XCTAssertTrue(built.isValidSolid)
        let thread = try XCTUnwrap(nut.cuts.last?.thread)
        XCTAssertTrue(thread.isInternal)
        XCTAssertEqual(thread.title, "M8 × 1.25")
        XCTAssertEqual(thread.clearance, 0.2)
        XCTAssertEqual(thread.ends.map { $0.startOpen && $0.endOpen }, true)
        // Flush with the tip, 0.8 × 8 mm tall, 13 mm across flats.
        XCTAssertEqual(built.bounds.max.z, 20, accuracy: 1e-6)
        XCTAssertEqual(built.bounds.min.z, 20 - 6.4, accuracy: 1e-6)
        XCTAssertEqual(built.bounds.max.x - built.bounds.min.x, 13 / sqrt(3) * 2, accuracy: 1e-3)
        // The helices are in step: the threads mesh without touching, and half a pitch off they would collide.
        XCTAssertLessThan(try overlap(bolt, nut), 1e-3)
        let offStep = try XCTUnwrap(nut.transformed(by: RigidTransform(translation: .init(0, 0, -0.625))))
        XCTAssertGreaterThan(try overlap(bolt, offStep), 1)
    }

    func testAJarNeckGetsACapThatRestsOnItsRim() throws {
        let jar = try threaded(try bossOnPlate(24.5, height: 8))
        let index = jar.cuts.count - 1
        let spec = try XCTUnwrap(jar.cuts[index].thread)
        XCTAssertEqual(ThreadMate.choices(for: spec), [.cap, .nut], "Jar-sized: a cap first")
        let cap = try XCTUnwrap(jar.matingPart(.cap, forThreadAt: index))
        let built = try SolidKernel.solid(for: cap)
        XCTAssertTrue(built.isValidSolid)
        let wall = 0.08 * 24.5
        XCTAssertEqual(built.bounds.max.z, 12 + wall, accuracy: 1e-6, "Its ceiling on the rim")
        XCTAssertEqual(built.bounds.min.z, 4.5, accuracy: 1e-6, "Half a millimeter above the shoulder")
        XCTAssertEqual(cap.cuts.last?.thread?.ends.map { $0.startOpen != $0.endOpen }, true, "Open only at its mouth")
        XCTAssertLessThan(try overlap(jar, cap), 1e-3)
        // Its top is whole: the thread stops at the top's underside, not a pitch into it.
        for (x, y) in [(0.0, 0.0), (8, 0), (0, -10), (-11, 3)] {
            XCTAssertTrue(ssk_point_inside(built.handle, SSKVec3(x: x, y: y, z: 12 + wall / 2)), "Top at (\(x), \(y))")
        }
        let offStep = try XCTUnwrap(cap.transformed(by: RigidTransform(translation: .init(0, 0, -1.5))))
        XCTAssertGreaterThan(try overlap(jar, offStep), 1, "In step: half a pitch off, the ridges collide")
    }

    func testANutsThreadTakesABoltOrAPlug() throws {
        let nut = try threaded(try drilledBlock(6.8))
        let index = nut.cuts.count - 1
        let bolt = try XCTUnwrap(nut.matingPart(.bolt, forThreadAt: index))
        let built = try SolidKernel.solid(for: bolt)
        XCTAssertTrue(built.isValidSolid)
        XCTAssertFalse(try XCTUnwrap(bolt.cuts.last?.thread).isInternal)
        // Through the whole block, its head on the top face.
        XCTAssertEqual(built.bounds.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(built.bounds.max.z, 12 + 0.7 * 8, accuracy: 1e-6)
        XCTAssertLessThan(try overlap(nut, bolt), 1e-3)
        // No groove runs on into its head.
        let crest = try XCTUnwrap(bolt.cuts.last?.thread).crestRadius
        for step in 0..<12 {
            let angle = Double(step) * .pi / 6
            XCTAssertTrue(ssk_point_inside(built.handle, SSKVec3(x: (crest - 0.1) * cos(angle), y: (crest - 0.1) * sin(angle), z: 12.3)), "Head at \(step)")
        }

        let plug = try XCTUnwrap(nut.matingPart(.plug, forThreadAt: index))
        let plugSolid = try SolidKernel.solid(for: plug)
        XCTAssertTrue(plugSolid.isValidSolid)
        XCTAssertEqual(plugSolid.bounds.max.x, 4 + 2, accuracy: 1e-3, "A round head 2 mm past the thread")
        XCTAssertLessThan(try overlap(nut, plug), 1e-3)
    }

    func testABlindHolesBoltStopsShortOfTheFloorAndLeftHandCarriesOver() throws {
        var block = try box(-15, -15, 15, 15, depth: 12)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 12), normal: .init(0, 0, 1)))
        block.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HoleSpec(kind: .simple, size: "", diameter: 8.5), at: .zero, on: top, depth: 8)))
        let nut = try threaded(block) { $0.leftHanded = true }
        let index = nut.cuts.count - 1
        let bolt = try XCTUnwrap(nut.matingPart(.bolt, forThreadAt: index))
        XCTAssertEqual(bolt.cuts.last?.thread?.leftHanded, true)
        XCTAssertEqual(try SolidKernel.solid(for: bolt).bounds.min.z, 4.5, accuracy: 1e-6)
        XCTAssertLessThan(try overlap(nut, bolt), 1e-3)
    }

    func testAThreadedFaceIsFoundFromAnyOfItsFaces() throws {
        let bolt = try threaded(try bossOnPlate(8))
        let solid = try SolidKernel.solid(for: bolt)
        let threadFaces = (0..<solid.faceCount).filter { bolt.thread(atFace: $0, of: solid) != nil }
        XCTAssertFalse(threadFaces.isEmpty)
        XCTAssertTrue(threadFaces.allSatisfy { bolt.thread(atFace: $0, of: solid) == bolt.cuts.count - 1 })
        let plateTop = try XCTUnwrap(solid.face(near: .init(10, 10, 4)))
        XCTAssertNil(bolt.thread(atFace: plateTop, of: solid))
    }

    func testEndsAndLeadInAreSaved() throws {
        let bolt = try threaded(try bossOnPlate(6))
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [bolt])))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"leadIn\" : true"), text)
        XCTAssertTrue(text.contains("\"startOpen\" : false") || text.contains("\"endOpen\" : false"), "The end on the plate is closed")
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [bolt])
        var bad = try XCTUnwrap(bolt.cuts.last?.thread)
        bad.ends?.end = bad.length + 1
        XCTAssertFalse(bad.isValid)
    }

    func testAssistantMakesMatchingParts() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try bossOnPlate(24.5, height: 8)]))
        XCTAssertThrowsError(try bench.matingPart(body: "Body 01", kind: nil), "No thread yet")
        try bench.thread(body: "Body 01", face: "boss", size: nil, diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false)
        XCTAssertThrowsError(try bench.matingPart(body: "Body 01", kind: "bolt"), "A boss's thread takes a cap or nut")
        let cap = try bench.matingPart(body: "Body 01", kind: nil)
        XCTAssertTrue(cap.contains("cap screwed onto Body 01, as Body 02"), cap)
        XCTAssertEqual(bench.workspace.bodies.count, 2)
        XCTAssertTrue(try bench.matingPart(body: "Body 01", kind: "Hex Nut").contains("nut"))
        XCTAssertEqual(bench.workspace.bodies.count, 3)
    }

    /// A slow build (a thread) on another thread must not hold up finding solids already built.
    func testCachedSolidsAreFoundWhileAThreadBuilds() throws {
        let plate = try bossOnPlate(8)
        let (solid, face) = try cylindricalFace(of: plate)
        var slow = plate
        slow.cuts.append(.thread(of: plate, try XCTUnwrap(plate.threadSpec(onFace: face, of: solid, clearance: 0.2))))
        let built = expectation(description: "thread built")
        let finished = NSLock()
        var isFinished = false
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? SolidKernel.solid(for: slow)
            finished.lock(); isFinished = true; finished.unlock()
            built.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        let start = Date()
        XCTAssertNoThrow(try SolidKernel.solid(for: plate))
        let delay = Date().timeIntervalSince(start)
        finished.lock(); let stillBuilding = !isFinished; finished.unlock()
        XCTAssertTrue(stillBuilding, "The thread should still be building (it takes about half a second)")
        XCTAssertLessThan(delay, 0.05, "A cached solid is found without waiting for the build")
        wait(for: [built], timeout: 30)
    }

    // MARK: Fit, standards, pitch, starts, and length (October 21, 2026)

    func faceSpec(_ body: SolidBody, clearance: Double = 0.2) throws -> ThreadSpec {
        let (solid, face) = try cylindricalFace(of: body)
        return try XCTUnwrap(body.threadSpec(onFace: face, of: solid, clearance: clearance))
    }

    func spec(_ base: ThreadSpec, _ name: String, pitch: Double? = nil) throws -> ThreadSpec {
        let size = try XCTUnwrap(ThreadPresets.size(named: name))
        return base.with(size: size, diameter: size.diameter, pitch: pitch ?? size.coarse)
    }

    func testFitSaysHowEachSizeSitsOnAHole() throws {
        let hole = try faceSpec(try drilledBlock(6.8))
        XCTAssertEqual(try spec(hole, "M5").fit.kind, .misses)
        XCTAssertEqual(try spec(hole, "M6").fit.kind, .misses, "Its crest (3.2 mm) is inside the 3.4 mm wall")
        XCTAssertEqual(try spec(hole, "M8").fit.kind, .full)
        XCTAssertEqual(try spec(hole, "M10").fit.kind, .resizes)
        XCTAssertEqual(try spec(hole, "M10").fit.resultDiameter, 10 - 1.082532 * 1.5 + 0.4, accuracy: 1e-9)
        let wide = try faceSpec(try drilledBlock(7.6))
        let partial = try spec(wide, "M8").fit
        XCTAssertEqual(partial.kind, .partial)
        XCTAssertEqual(partial.depth, (4.2 - 3.8) / (0.541266 * 1.25), accuracy: 1e-3)
        XCTAssertLessThan(partial.depth, ThreadFit.shallow)

        let mm = { (v: Double) in "\(ThreadSpec.mm(v)) mm" }
        let miss = try spec(hole, "M5").fitSummary(mm)
        XCTAssertTrue(miss.contains("smaller than this 6.8 mm hole"), miss)
        XCTAssertTrue(miss.contains("Try M8"), miss)
        XCTAssertTrue(miss.contains("over 6.4 mm"), miss)
        XCTAssertTrue(try spec(wide, "M8").fitSummary(mm).contains("may strip"))
        XCTAssertEqual(try spec(hole, "M5").fitNote(mm), "Smaller than the hole")
        XCTAssertEqual(try spec(hole, "M10").fitNote(mm), "Cuts the hole out to \(ThreadSpec.mm(10 - 1.082532 * 1.5 + 0.4)) mm")
    }

    func testFitSaysHowEachSizeSitsOnABoss() throws {
        let boss = try faceSpec(try bossOnPlate(8))
        XCTAssertEqual(try spec(boss, "M8").fit.kind, .full)
        XCTAssertEqual(try spec(boss, "M10").fit.kind, .misses, "Its root (3.99 mm) barely touches the 4 mm boss")
        let thin = try faceSpec(try bossOnPlate(7.4))
        XCTAssertEqual(try spec(thin, "M8").fit.kind, .partial)
        XCTAssertEqual(try spec(thin, "M8").fit.depth, (3.7 - (4 - 0.541266 * 1.25 - 0.2)) / (0.541266 * 1.25), accuracy: 1e-3)
        XCTAssertEqual(try spec(boss, "M12").fit.kind, .misses)
        XCTAssertEqual(try spec(boss, "M5").fit.kind, .resizes)
        let mm = { (v: Double) in "\(ThreadSpec.mm(v)) mm" }
        let miss = try spec(boss, "M12").fitSummary(mm)
        XCTAssertTrue(miss.contains("bigger than this 8 mm boss") && miss.contains("Try M8"), miss)
        XCTAssertEqual(try spec(boss, "M12").reachableDiameters?.upperBound ?? 0, 8 + 0.4 + 1.082532 * 1.75 - 0.175, accuracy: 1e-9)
    }

    func testEverySizeThatReachesTheFaceBuilds() throws {
        // Sizes that once failed with "could not be built": large turn-downs, and sizes just reaching.
        let boss = try bossOnPlate(8), hole = try drilledBlock(5)
        for (body, names) in [(boss, ["M3", "M5", "#10", "5/16"]), (hole, ["M5", "M6", "M10", "1/4"])] {
            let base = try faceSpec(body)
            for name in names {
                let thread = try spec(base, name)
                XCTAssertTrue(thread.fit.isUsable, name)
                let built = try XCTUnwrap(body.threading(thread), name)
                XCTAssertTrue(try SolidKernel.solid(for: built).isValidSolid, name)
            }
        }
    }

    func testStandardsAndFinePitches() throws {
        XCTAssertEqual(ThreadPresets.size(named: "m8")?.pitches, [1.25, 1, 0.75])
        XCTAssertEqual(ThreadPresets.size(named: "1/4\"")?.title(pitch: 25.4 / 20), "1/4-20 UNC")
        XCTAssertEqual(ThreadPresets.size(named: "1/4")?.title(pitch: 25.4 / 28), "1/4-28 UNF")
        XCTAssertEqual(ThreadPresets.size(named: "#10")?.diameter ?? 0, 4.826, accuracy: 1e-9)
        XCTAssertNil(ThreadPresets.size(named: ""))

        let boss = try faceSpec(try bossOnPlate(8))
        let fine = try spec(boss, "M8", pitch: 1)
        XCTAssertEqual(fine.title, "M8 × 1")
        XCTAssertEqual(fine.standardSize?.name, "M8")
        XCTAssertEqual(fine.with(size: nil, diameter: 8, pitch: 1.1).title, "Ø8 × 1.1", "Not a standard pitch: custom")
        XCTAssertEqual(fine.with(size: nil, diameter: 8, pitch: 1.25).size, "M8", "Typing a standard pair names it")
        XCTAssertEqual(fine.with(size: fine.standardSize, diameter: 8, pitch: 1.3).size, "", "A size only with one of its pitches")

        // An inch project prefers inch sizes; a 1/4-20 tripod boss.
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 6.2, clearance: 0.2).size, "M6", "Metric first")
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 6.2, clearance: 0.2, preferInch: true).size, "1/4")
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 6.35, clearance: 0.2).size, "1/4", "No metric size near: inch")
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 5.9, clearance: 0.2, preferInch: true).size, "M6",
                       "No inch size near: metric")
    }

    func testMultiStartThreadsBuildAndSave() throws {
        let boss = try bossOnPlate(24.5, height: 8)
        let single = try threaded(boss) { $0.pitch = 3 }
        let triple = try threaded(boss) { $0.pitch = 3; $0.starts = 3 }
        let tripleSpec = try XCTUnwrap(triple.cuts.last?.thread)
        XCTAssertEqual(tripleSpec.lead, 9)
        XCTAssertTrue(tripleSpec.title.hasSuffix(", 3-start"), tripleSpec.title)
        let a = try SolidKernel.solid(for: single), b = try SolidKernel.solid(for: triple)
        XCTAssertTrue(b.isValidSolid)
        // The same profile every pitch, only wound differently: the same material is left.
        XCTAssertEqual(b.volume, a.volume, accuracy: a.volume * 0.01)
        XCTAssertGreaterThan(try overlap(single, triple), 0)
        XCTAssertLessThan(try overlap(single, triple), a.volume * 0.995, "The ridges run at another angle")
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [triple])))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [triple])
        var tooMany = tripleSpec
        tooMany.starts = 5
        XCTAssertFalse(tooMany.isValid)
        // A cap made for it carries the starts.
        let index = try XCTUnwrap(triple.matableThreads.last)
        let cap = try XCTUnwrap(triple.matingPart(.cap, forThreadAt: index))
        XCTAssertEqual(cap.cuts.last?.thread?.starts, 3)
        XCTAssertLessThan(try overlap(triple, cap), 1, "Screwed on without clashing")
    }

    func testAThreadCanCoverPartOfTheFaceFromItsOpenEnd() throws {
        let boss = try bossOnPlate(8)
        let full = try faceSpec(boss)
        // This boss's axis runs down from its tip, so it is screwed onto at the thread's start.
        let ends = try XCTUnwrap(full.ends)
        XCTAssertTrue(ends.startOpen && !ends.endOpen)
        XCTAssertFalse(boss.threadEntryIsAtEnd(full), "A boss is screwed onto at its tip")
        let short = try XCTUnwrap(full.shortened(to: 6, atEnd: false))
        XCTAssertEqual(short.threadedLength, 6, accuracy: 1e-9)
        XCTAssertEqual(short.ends, ThreadEnds(start: ends.start, end: ends.start + 6, startOpen: true, endOpen: false))
        XCTAssertEqual(short.length, 6 + full.pitch, accuracy: 1e-9, "Still a pitch past the tip")
        // From the other end, the thread starts partway along the face.
        let low = try XCTUnwrap(full.shortened(to: 6, atEnd: true))
        XCTAssertEqual(low.ends, ThreadEnds(start: 0, end: 6, startOpen: false, endOpen: false))
        XCTAssertNil(full.shortened(to: 0.5, atEnd: false), "Under a turn")
        XCTAssertEqual(full.shortened(to: 40, atEnd: false), full, "Longer than the face: the whole face")

        let plain = try SolidKernel.solid(for: boss).volume
        let whole = try SolidKernel.solid(for: try XCTUnwrap(boss.threading(full))).volume
        let part = try SolidKernel.solid(for: try XCTUnwrap(boss.threading(short)))
        XCTAssertTrue(part.isValidSolid)
        // About 6/16 of the grooves are cut.
        XCTAssertEqual((plain - part.volume) / (plain - whole), 6.0 / 16, accuracy: 0.05)
        // The plain shank keeps its full diameter below the thread.
        XCTAssertTrue(ssk_point_inside(part.handle, SSKVec3(x: 3.9, y: 0, z: 6)))
        XCTAssertTrue(ssk_point_inside(part.handle, SSKVec3(x: 0, y: 3.9, z: 6)))
    }

    func testAssistantTakesFinePitchesStartsAndLength() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try bossOnPlate(10), try drilledBlock(6.8), try bossOnPlate(8)]))
        let fine = try bench.thread(body: "Body 01", face: "boss", size: "M10x1.25", diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false,
                                    starts: 2, length: 8)
        XCTAssertTrue(fine.contains("M10 × 1.25, 2-start bolt thread"), fine)
        let spec = try XCTUnwrap(bench.workspace.bodies[0].cuts.last?.thread)
        XCTAssertEqual(spec.threadedLength, 8, accuracy: 1e-9)
        XCTAssertThrowsError(try bench.thread(body: "Body 02", face: "hole", size: "M5", diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false)) { error in
            XCTAssertTrue("\(error)".contains("smaller than this 6.8 mm hole"), "\(error)")
        }
        XCTAssertThrowsError(try bench.thread(body: "Body 03", face: "boss", size: nil, diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false, starts: 6))
        let inch = try bench.thread(body: "Body 03", face: "boss", size: "5/16", diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false)
        XCTAssertTrue(inch.contains("5/16-18 UNC"), inch)
    }

    // MARK: Raised threads (October 22, 2026)

    /// A jar's neck: a Ø60 tube with 2 mm walls, 20 tall, on an 80 × 80 × 4 plate.
    /// A jar's neck: a boss of `diameter` with 2 mm walls, 20 mm tall on a 4 mm plate.
    func jarNeck(diameter: Double = 60) throws -> SolidBody {
        let half = diameter / 2 + 10
        var neck = try box(-half, -half, half, half, depth: 4)
        let plate = try XCTUnwrap(SketchPlane.through(.init(0, 0, 4), normal: .init(0, 0, 1)))
        let circle = SketchShape(kind: .circle, plane: plate, start: .zero, end: Point2(x: diameter / 2, y: 0))
        neck.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [circle], on: plate).first), depth: 20, operation: .join))
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 24), normal: .init(0, 0, 1)))
        neck.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HoleSpec(kind: .simple, size: "", diameter: diameter - 4), at: .zero, on: top, depth: 20)))
        return neck
    }

    /// The thread a body's round boss (side 1) or hole (side -1) suggests, and the body's solid.
    func roundFace(_ body: SolidBody, side: Int32, clearance: Double = 0.2) throws -> (ThreadSpec, KernelSolid) {
        let solid = try SolidKernel.solid(for: body)
        let face = try XCTUnwrap((0..<solid.faceCount).first { ssk_face_cylinder_side(solid.handle, Int32($0)) == side })
        return (try XCTUnwrap(body.threadSpec(onFace: face, of: solid, clearance: clearance)), solid)
    }

    func isInside(_ solid: KernelSolid, radius: Double, z: Double, angle: Double) -> Bool {
        ssk_point_inside(solid.handle, SSKVec3(x: radius * cos(angle), y: radius * sin(angle), z: z))
    }

    func testACutThreadWarnsOfAThinWallAndARaisedOneKeepsIt() throws {
        let neck = try jarNeck()
        let (cut, solid) = try roundFace(neck, side: 1)
        XCTAssertEqual(cut.title, "Ø60 × 3")
        // The grooves reach in to 28.18 mm of the 28 mm inside: about 0.2 mm of wall stays.
        XCTAssertEqual(try XCTUnwrap(neck.wallBehindThread(cut, in: solid)), 0.2, accuracy: 0.11)
        XCTAssertEqual(cut.wallWarning(0.2) { "\(ThreadSpec.mm($0)) mm" }, "Only about 0.2 mm of wall stays behind this thread.")
        XCTAssertNil(try bossOnPlate(8).wallBehindThread(try faceSpec(try bossOnPlate(8)), in: SolidKernel.solid(for: bossOnPlate(8))),
                     "A solid boss has its core behind the thread")

        let raised = cut.made(raised: true)
        XCTAssertTrue(raised.isRaised)
        XCTAssertEqual(raised.majorDiameter, 60 + 1.082532 * 3, accuracy: 1e-9, "The boss is the thread's minor diameter")
        XCTAssertEqual(raised.title, "Ø63.25 × 3")
        XCTAssertEqual(raised.fit.kind, .full)
        XCTAssertNil(neck.wallBehindThread(raised, in: solid))
        let mm = { (v: Double) in "\(ThreadSpec.mm(v)) mm" }
        XCTAssertTrue(raised.fitSummary(mm).contains("raised on this 60 mm boss"), raised.fitSummary(mm))

        let threaded = try XCTUnwrap(neck.threading(raised))
        let built = try SolidKernel.solid(for: threaded)
        XCTAssertTrue(built.isValidSolid)
        let added = built.volume - solid.volume
        let annulus = Double.pi * (pow(raised.crestRadius, 2) - 900) * 20
        XCTAssertGreaterThan(added, 0.25 * annulus, "Ridges stand out of the neck")
        XCTAssertLessThan(added, 0.6 * annulus)
        // Only along the neck: not past its rim, though the thread runs a pitch beyond it.
        XCTAssertEqual(built.bounds.max.z, 24, accuracy: 1e-6)
        var crest = false
        for step in 0..<24 {
            let angle = Double(step) * .pi / 12
            XCTAssertTrue(isInside(built, radius: 28.2, z: 14, angle: angle), "The wall is whole")
            XCTAssertFalse(isInside(built, radius: 27.9, z: 14, angle: angle), "The inside is untouched")
            XCTAssertFalse(isInside(built, radius: raised.crestRadius + 0.05, z: 14, angle: angle), "Nothing past the crest")
            crest = crest || isInside(built, radius: raised.crestRadius - 0.05, z: 14, angle: angle)
        }
        XCTAssertTrue(crest, "Ridges reach the crest")
        XCTAssertNil(threaded.wallBehindThread(raised, in: built))
    }

    func testARaisedNeckTakesACapThatScrewsOnInStep() throws {
        let neck = try jarNeck()
        let (cut, _) = try roundFace(neck, side: 1)
        let full = cut.made(raised: true)
        let spec = try XCTUnwrap(full.shortened(to: 12, atEnd: neck.threadEntryIsAtEnd(full)))
        let jar = try XCTUnwrap(neck.threading(spec))
        let index = jar.cuts.count - 1
        XCTAssertEqual(jar.matableThreads, [index])
        XCTAssertEqual(ThreadMate.choices(for: spec), [.cap, .nut])
        let cap = try XCTUnwrap(jar.matingPart(.cap, forThreadAt: index))
        let built = try SolidKernel.solid(for: cap)
        XCTAssertTrue(built.isValidSolid)
        let thread = try XCTUnwrap(cap.cuts.last?.thread)
        XCTAssertTrue(thread.isInternal)
        XCTAssertFalse(thread.isRaised, "Cut into the cap's own bore")
        XCTAssertEqual(thread.title, spec.title)
        XCTAssertEqual(built.bounds.max.z, 24 + 3, accuracy: 1e-6, "Its ceiling on the rim")
        for (x, y) in [(0.0, 0.0), (20, 0), (0, -29), (-25, 10)] {
            XCTAssertTrue(ssk_point_inside(built.handle, SSKVec3(x: x, y: y, z: 25.5)), "Top at (\(x), \(y))")
        }
        XCTAssertLessThan(try overlap(jar, cap), 1e-3)
        let offStep = try XCTUnwrap(cap.transformed(by: RigidTransform(translation: .init(0, 0, -1.5))))
        XCTAssertGreaterThan(try overlap(jar, offStep), 1, "Half a pitch off, the ridges collide")
    }

    func testARaisedThreadInAHoleKeepsTheWallAroundIt() throws {
        let block = try drilledBlock(20)
        let (cut, solid) = try roundFace(block, side: -1)
        let raised = cut.made(raised: true)
        XCTAssertEqual(raised.title, "M20 × 2.5", "A Ø20 hole is M20's major diameter")
        XCTAssertEqual(raised.fit.kind, .full)
        let nut = try XCTUnwrap(block.threading(raised))
        let built = try SolidKernel.solid(for: nut)
        XCTAssertTrue(built.isValidSolid)
        XCTAssertGreaterThan(built.volume, solid.volume + 10)
        XCTAssertEqual(built.bounds.max.x, 15, accuracy: 1e-6, "The block's outside is untouched")
        var ridge = false
        for step in 0..<12 {
            let angle = Double(step) * .pi / 6
            XCTAssertFalse(isInside(built, radius: raised.rootRadius - 0.1, z: 6, angle: angle), "Inside the ridges' tips")
            XCTAssertTrue(isInside(built, radius: 10.1, z: 6, angle: angle), "The wall")
            ridge = ridge || isInside(built, radius: 9.5, z: 6, angle: angle)
        }
        XCTAssertTrue(ridge, "Ridges stand in from the wall")
        let bolt = try XCTUnwrap(nut.matingPart(.bolt, forThreadAt: nut.cuts.count - 1))
        XCTAssertTrue(try SolidKernel.solid(for: bolt).isValidSolid)
        XCTAssertLessThan(try overlap(nut, bolt), 1e-3)

        // Near the block's sides, a cut thread leaves 15 mm less its crest of wall, or cuts through.
        let near = cut.with(size: nil, diameter: 28, pitch: 2)
        XCTAssertEqual(try XCTUnwrap(block.wallBehindThread(near, in: solid)), 15 - near.crestRadius, accuracy: 0.11)
        let wide = try drilledBlock(26)
        let (through, wideSolid) = try roundFace(wide, side: -1)
        XCTAssertGreaterThan(through.crestRadius, 15)
        XCTAssertEqual(wide.wallBehindThread(through, in: wideSolid), 0)
        XCTAssertEqual(through.wallWarning(0) { "\($0)" }, "This thread cuts through the wall into the inside.")
    }

    func testRaisedFitsAndSuggestions() throws {
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 60, clearance: 0.2, raised: true).major, 60 + 1.082532 * 3, accuracy: 1e-9)
        XCTAssertEqual(ThreadPresets.suggestion(internal: true, surfaceDiameter: 20, clearance: 0.2, raised: true).size, "M20")
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 8.3, clearance: 0.2, raised: true).size, "M10",
                       "M10's minor (8.38 mm) is just outside the boss")
        XCTAssertEqual(ThreadPresets.suggestion(internal: false, surfaceDiameter: 8.5, clearance: 0.2, raised: true).size, "",
                       "Inside M10's minor: its grooves would be filled")

        let boss = try faceSpec(try bossOnPlate(8)).made(raised: true)
        XCTAssertEqual(boss.size, "", "No size's minor is near 8 mm")
        XCTAssertEqual(boss.majorDiameter, 8 + 1.082532 * 1.25, accuracy: 1e-9)
        XCTAssertEqual(try spec(boss, "M8").fit.kind, .misses, "Raised M8 would be buried in an 8 mm boss")
        XCTAssertEqual(try spec(boss, "M10").fit.kind, .full)
        let m12 = try spec(boss, "M12")
        XCTAssertEqual(m12.fit.kind, .resizes)
        XCTAssertEqual(m12.fit.resultDiameter, 2 * m12.rootRadius, accuracy: 1e-9)
        let mm = { (v: Double) in "\(ThreadSpec.mm(v)) mm" }
        XCTAssertTrue(m12.fitSummary(mm).contains("built up to"), m12.fitSummary(mm))
        XCTAssertEqual(m12.fitNote(mm), "Builds the boss up to \(ThreadSpec.mm(2 * m12.rootRadius)) mm")
        let miss = try spec(boss, "M8").fitSummary(mm)
        XCTAssertTrue(miss.contains("too small to raise") && miss.contains("Try M10"), miss)
        XCTAssertEqual(try spec(boss, "M8").reachableDiameters?.lowerBound ?? 0, 8 + 1.082532 * 1.25 - 0.06 * 0.541266 * 1.25, accuracy: 1e-3)
        // A built-up boss builds.
        let plate = try bossOnPlate(8)
        let built = try SolidKernel.solid(for: try XCTUnwrap(plate.threading(m12)))
        XCTAssertTrue(built.isValidSolid)
        XCTAssertTrue(isInside(built, radius: 4.5, z: 12, angle: 0.3), "The sleeve under the ridges")

        // Custom raised threads keep the boss as their minor when the pitch changes; Cut puts it back.
        XCTAssertEqual(boss.with(pitch: 2).majorDiameter, 8 + 1.082532 * 2, accuracy: 1e-9)
        XCTAssertEqual(boss.made(raised: false).majorDiameter, 8, accuracy: 1e-9)
        let hole = try faceSpec(try drilledBlock(6.8))
        XCTAssertEqual(hole.made(raised: true).fit.kind, .full)
        XCTAssertEqual(hole.made(raised: true).made(raised: false).size, "M8")
    }

    func testRaisedThreadsSaveMirrorAndTakeStarts() throws {
        let neck = try jarNeck()
        let (cut, _) = try roundFace(neck, side: 1)
        var spec = cut.made(raised: true)
        spec.starts = 2
        let jar = try XCTUnwrap(neck.threading(spec))
        let built = try SolidKernel.solid(for: jar)
        XCTAssertTrue(built.isValidSolid)
        let text = String(decoding: try ProjectCodec.encode(Project(workspace: Workspace(bodies: [jar]))), as: UTF8.self)
        XCTAssertTrue(text.contains("\"raised\" : true"), text)
        XCTAssertEqual(try ProjectCodec.decode(try ProjectCodec.encode(Project(workspace: Workspace(bodies: [jar])))).workspace.bodies, [jar])
        let cutText = String(decoding: try ProjectCodec.encode(Project(workspace: Workspace(bodies: [try XCTUnwrap(neck.threading(cut))]))), as: UTF8.self)
        XCTAssertFalse(cutText.contains("raised"), "Cut threads write nothing new")

        let image = try XCTUnwrap(jar.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        XCTAssertEqual(image.cuts.last?.thread?.isRaised, true)
        XCTAssertEqual(image.cuts.last?.thread?.leftHanded, true)
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, built.volume, accuracy: built.volume * 1e-4)
    }

    func testAssistantRaisesThreadsAndWarnsOfThinWalls() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try jarNeck()]))
        let cut = try bench.thread(body: "Body 01", face: "boss", size: nil, diameter: nil, pitch: nil, clearance: 0.2, leftHanded: false)
        XCTAssertTrue(cut.contains("Cut a Ø60 × 3 bolt thread"), cut)
        XCTAssertTrue(cut.contains("Only about 0.2 mm of wall") && cut.contains("raised"), cut)

        bench = AssistantWorkbench(workspace: Workspace(bodies: [try jarNeck()]))
        let raised = try bench.thread(body: "Body 01", face: "boss", size: nil, diameter: nil, pitch: 2.5, clearance: 0.2, leftHanded: false,
                                      starts: 2, length: 10, raised: true)
        XCTAssertTrue(raised.contains("Raised a Ø62.71 × 2.5, 2-start bolt thread"), raised)
        XCTAssertFalse(raised.contains("wall"), raised)
        let spec = try XCTUnwrap(bench.workspace.bodies[0].cuts.last?.thread)
        XCTAssertTrue(spec.isRaised)
        XCTAssertEqual(spec.threadedLength, 10, accuracy: 1e-9)
        XCTAssertTrue(bench.summary().contains("external raised thread"), bench.summary())
    }

    // MARK: Jar sizes (October 23, 2026)

    /// The tool the kernel makes for `body`'s thread `spec` from fallback `attempt` alone, placed as
    /// SolidKernel.applyThread places it.
    func threadTool(_ spec: ThreadSpec, of body: SolidBody, attempt: Int32) -> KernelSolid? {
        ssk_set_thread_attempt(attempt)
        defer { ssk_set_thread_attempt(-1) }
        func vec(_ v: SIMD3<Double>) -> SSKVec3 { SSKVec3(x: v.x, y: v.y, z: v.z) }
        let origin = body.worldPoint(spec.origin)
        let axis = simd_normalize(body.worldPoint(spec.origin + spec.axis) - origin)
        let reference = body.worldPoint(spec.origin + spec.reference) - origin
        let clip = spec.ends.map { ($0.startOpen ? $0.start : 0, $0.endOpen ? $0.end : spec.length) } ?? (0, spec.length)
        return ssk_thread_tool(vec(origin), vec(axis), vec(reference), 0, spec.length, spec.pitch, spec.crestRadius,
                               spec.rootRadius, spec.surfaceDiameter / 2, spec.isInternal, spec.leftHanded == true, Int32(spec.startCount),
                               spec.isRaised, clip.0, clip.1).map { KernelSolid(adopting: $0) }
    }

    /// Probes halfway between `spec`'s root and crest, staggered around the axis along `tool`'s length
    /// (a pitch in from either end), raised by `lift`: whether each lies inside `tool`.
    func probes(_ tool: KernelSolid, _ spec: ThreadSpec, of span: KernelSolid? = nil, lift: Double = 0) -> [Bool] {
        let bounds = (span ?? tool).bounds
        let radius = (spec.rootRadius + spec.crestRadius) / 2, bottom = bounds.min.z + spec.pitch, top = bounds.max.z - spec.pitch
        return (0..<144).map { i in
            let z = bottom + (top - bottom) * Double(i / 6) / 23 + lift
            let angle = 2 * Double.pi * (Double(i % 6) / 6 + 0.137 * Double(i / 6))
            return ssk_point_inside(tool.handle, SSKVec3(x: radius * cos(angle), y: radius * sin(angle), z: z))
        }
    }

    /// The share of two probe lists that disagree.
    func disagreement(_ a: [Bool], _ b: [Bool]) -> Double {
        Double(zip(a, b).filter { $0 != $1 }.count) / Double(a.count)
    }

    func testEveryFallbackKeepsTheHelixInStep() throws {
        let neck = try jarNeck()
        let (cut, _) = try roundFace(neck, side: 1)
        var raised = cut.made(raised: true)
        raised.starts = 2
        var leftHanded = raised
        leftHanded.leftHanded = true
        let jar = try XCTUnwrap(neck.threading(raised))
        let cap = try XCTUnwrap(jar.matingPart(.cap, forThreadAt: jar.cuts.count - 1))
        let capThread = try XCTUnwrap(cap.cuts.last?.thread)
        let attempts = ssk_set_thread_attempt(-1)
        XCTAssertGreaterThan(attempts, 1)
        for (name, spec, body) in [("raised", raised, neck), ("left-handed", leftHanded, neck), ("cap", capThread, cap)] {
            let first = try XCTUnwrap(threadTool(spec, of: body, attempt: 0), name)
            let expected = probes(first, spec)
            // An eighth of a pitch along the axis, as the fallbacks once slid the helix, shows plainly.
            XCTAssertGreaterThan(disagreement(expected, probes(first, spec, lift: 0.13 * spec.pitch)), 0.15, name)
            for attempt in 1..<attempts {
                let tool = try XCTUnwrap(threadTool(spec, of: body, attempt: attempt), "\(name): attempt \(attempt) builds")
                XCTAssertEqual(tool.volume, first.volume, accuracy: 0.03 * first.volume, "\(name): attempt \(attempt)")
                XCTAssertLessThan(disagreement(expected, probes(tool, spec, of: first)), 0.03, "\(name): attempt \(attempt) keeps the helix where it is")
            }
        }
    }

    func testJarSizedTwoStartThreadsTakeCapsInStep() throws {
        for diameter in [40.0, 60, 80, 100] {
            let neck = try jarNeck(diameter: diameter)
            let (cut, _) = try roundFace(neck, side: 1)
            var full = cut.made(raised: true)
            full.starts = 2
            let spec = try XCTUnwrap(full.shortened(to: 12, atEnd: neck.threadEntryIsAtEnd(full)), "Ø\(diameter)")
            let jar = try XCTUnwrap(neck.threading(spec), "Ø\(diameter)")
            let built = try SolidKernel.solid(for: jar)
            XCTAssertTrue(built.isValidSolid, "Ø\(diameter)")
            XCTAssertGreaterThan(built.bounds.max.x, diameter / 2 + 0.5, "Ø\(diameter): the ridges stand out of the neck")
            let cap = try XCTUnwrap(jar.matingPart(.cap, forThreadAt: jar.cuts.count - 1), "Ø\(diameter)")
            XCTAssertEqual(cap.cuts.last?.thread?.startCount, 2, "Ø\(diameter)")
            XCTAssertTrue(try SolidKernel.solid(for: cap).isValidSolid, "Ø\(diameter)")
            XCTAssertLessThan(try overlap(jar, cap), 1e-3, "Ø\(diameter): screwed on without touching")
            let offStep = try XCTUnwrap(cap.transformed(by: RigidTransform(translation: .init(0, 0, -spec.pitch / 2))))
            XCTAssertGreaterThan(try overlap(jar, offStep), 1, "Ø\(diameter): half a pitch off, the ridges collide")
        }
    }
}
