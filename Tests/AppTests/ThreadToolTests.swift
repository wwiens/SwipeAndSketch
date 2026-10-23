import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// The Thread tool through the session, canvas, and kernel.
@MainActor final class ThreadToolTests: CanvasTestCase {
    /// Threads start from the Fit preference, which hosted tests share with the app: these tests run
    /// at the default (Standard) fit and put the preference back afterwards.
    private var savedClearance: Any?
    override func setUp() async throws {
        try await super.setUp()
        savedClearance = UserDefaults.standard.object(forKey: "fitClearance")
        Fit.preferredClearance = Fit.defaultClearance
    }
    override func tearDown() async throws {
        UserDefaults.standard.set(savedClearance, forKey: "fitClearance")
        try await super.tearDown()
    }

    /// The 60 × 40 × 20 box with a 6.8 mm through hole (an M8 tap drill) at its center.
    func drilledScene() throws -> (ModelingSession, CanvasController) {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        session.beginFaceSketch()
        session.chooseTool(.hole)
        controller.refresh()
        tap(controller, SIMD3(0.2, 0.1, 20))
        XCTAssertTrue(session.applyDimension(6.8, target: .holeDiameter))
        session.confirmHole()
        session.exitSketch()
        session.select(nil)
        controller.refresh()
        return (session, controller)
    }

    func holeWall(_ session: ModelingSession) throws -> Int {
        let solid = try SolidKernel.solid(for: session.workspace.bodies[0])
        return try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil })
    }

    func testThreadToolCutsAnM8NutThreadInTheHole() async throws {
        let (session, controller) = try drilledScene()
        session.chooseTool(.thread)
        XCTAssertEqual(session.tool, .thread)
        XCTAssertTrue(session.hint.contains("hole"), session.hint)
        session.beginThread(bodyID: session.workspace.bodies[0].id, face: try holeWall(session))
        let draft = try XCTUnwrap(session.threadDraft)
        XCTAssertTrue(draft.spec.isInternal)
        XCTAssertEqual(draft.spec.size, "M8")
        XCTAssertEqual(session.helpTopic, .thread)
        XCTAssertTrue(session.isBuildingThread, "Built in the background")
        await session.threadPreviewSettled()
        XCTAssertNotNil(session.threadPreview)
        XCTAssertEqual(Set(controller.dimensionAnnotations().map(\.target)), [.threadDiameter, .threadPitch])
        session.chooseThreadSize("M10")
        await session.threadPreviewSettled()
        XCTAssertEqual(session.threadDraft?.spec.pitch, 1.5)
        XCTAssertNotNil(session.threadPreview, "An undersized hole is opened up to the thread")
        XCTAssertTrue(session.applyDimension(1.25, target: .threadPitch))
        XCTAssertEqual(session.threadDraft?.spec.title, "M10 × 1.25", "A standard fine pitch keeps the size")
        XCTAssertTrue(session.applyDimension(1.3, target: .threadPitch))
        XCTAssertEqual(session.threadDraft?.spec.size, "", "Any other typed pitch makes it custom")
        XCTAssertFalse(session.applyDimension(25, target: .threadPitch))
        session.chooseThreadSize("M8")
        session.setThreadLeftHanded(true)
        await session.threadPreviewSettled()
        controller.refresh()
        attach(controller, "M8 left-hand nut thread in the hole")
        let before = try SolidKernel.solid(for: session.workspace.bodies[0]).volume
        session.confirmThread()
        XCTAssertNil(session.threadDraft)
        XCTAssertEqual(session.status, "Threaded M8 × 1.25 LH")
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .thread)
        XCTAssertLessThan(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, before)
        session.undo()
        XCTAssertNotEqual(session.workspace.bodies[0].cuts.last?.operation, .thread, "One undo step")
    }

    func testSelectedHoleWallOffersThreadAndAFlatFaceDoesNot() throws {
        let (session, controller) = try drilledScene()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        XCTAssertFalse(session.canThreadSelectedFace, "A flat face")
        let body = session.workspace.bodies[0]
        let solid = try SolidKernel.solid(for: body)
        let wall = try holeWall(session)
        session.select(.face(FaceSelection(bodyID: body.id, face: wall, plane: nil, center: try XCTUnwrap(solid.faceCenter(wall)))))
        XCTAssertTrue(session.canThreadSelectedFace)
        session.chooseTool(.thread)
        XCTAssertNotNil(session.threadDraft, "The selected wall is threaded at once")
        session.cancelThread()
        XCTAssertNil(session.threadDraft)
        XCTAssertEqual(session.tool, .select)
    }

    func testLeadInIsOnByDefaultAndAThreadOffersItsMatchingBolt() async throws {
        let (session, controller) = try drilledScene()
        session.beginThread(bodyID: session.workspace.bodies[0].id, face: try holeWall(session))
        XCTAssertEqual(session.threadDraft?.spec.leadIn, true)
        await session.threadPreviewSettled()
        let beveled = try SolidKernel.solid(for: XCTUnwrap(session.threadPreview).bodies[0]).volume
        session.setThreadLeadIn(false)
        XCTAssertNil(session.threadDraft?.spec.leadIn)
        await session.threadPreviewSettled()
        XCTAssertGreaterThan(try SolidKernel.solid(for: XCTUnwrap(session.threadPreview).bodies[0]).volume, beveled, "No countersinks")
        session.setThreadLeadIn(true)
        await session.threadPreviewSettled()
        session.confirmThread()

        // A tap on the thread offers the parts that screw into it, not another thread.
        let body = session.workspace.bodies[0]
        let solid = try SolidKernel.solid(for: body)
        let flank = try XCTUnwrap((0..<solid.faceCount).first { body.thread(atFace: $0, of: solid) != nil })
        session.select(.face(FaceSelection(bodyID: body.id, face: flank, plane: nil, center: try XCTUnwrap(solid.faceCenter(flank)))))
        XCTAssertNotNil(session.selectedThread)
        XCTAssertEqual(session.matingChoices, [.bolt, .plug])
        XCTAssertEqual(session.helpTopic, .matingPart)
        XCTAssertTrue(session.hint.contains("Matching Part"), session.hint)
        session.select(.body(body.id))
        XCTAssertEqual(session.matingChoices, [.bolt, .plug], "A solid with one thread offers it too")

        session.makeMatingPart(.bolt)
        XCTAssertTrue(session.isMakingMatingPart, "Built in the background")
        await session.matingPartSettled()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        let bolt = session.workspace.bodies[1]
        XCTAssertEqual(session.selection, .body(bolt.id))
        XCTAssertTrue(session.status.contains("bolt"), session.status)
        XCTAssertEqual(bolt.cuts.last?.thread?.title, "M8 × 1.25")
        let boltSolid = try SolidKernel.solid(for: bolt)
        XCTAssertEqual(boltSolid.bounds.min.z, 0, accuracy: 1e-6, "Through the box")
        XCTAssertEqual(boltSolid.bounds.max.z, 20 + 5.6, accuracy: 1e-6, "Its head on the top")
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 1, "One undo step")
        session.redo()
        session.requestCamera(.reset)
        controller.refresh()
        attach(controller, "Matching M8 bolt screwed into the threaded hole")
        session.toggleHidden(.body(body.id))
        session.select(nil)
        attach(controller, "The matching bolt's thread and lead-in, the box hidden")
    }

    func testSizeMenuExplainsWhichSizesFitAndWhy() async throws {
        let (session, _) = try drilledScene()
        session.beginThread(bodyID: session.workspace.bodies[0].id, face: try holeWall(session))
        await session.threadPreviewSettled()
        XCTAssertTrue(session.hint.hasPrefix("M8 × 1.25 fits this 6.8 mm hole"), session.hint)

        let metric = session.threadSizeChoices(.metric)
        let m8 = try XCTUnwrap(metric.first { $0.size.name == "M8" })
        XCTAssertEqual(m8.note, "Best fit")
        XCTAssertTrue(m8.inUse && m8.fitsAsIs)
        let m5 = try XCTUnwrap(metric.first { $0.size.name == "M5" })
        XCTAssertEqual(m5.fit, .misses, "Greyed out, with the reason")
        XCTAssertEqual(m5.note, "Smaller than the hole")
        XCTAssertTrue(try XCTUnwrap(metric.first { $0.size.name == "M12" }).note.hasPrefix("Cuts the hole out to"))
        XCTAssertFalse(session.threadSizeChoices(.inch).isEmpty)
        XCTAssertEqual(session.threadPitchChoices.map(\.pitch), [1.25, 1, 0.75])
        XCTAssertEqual(session.threadPitchChoices.first?.note, "Coarse (standard)")

        // A size that misses says why and what to choose, and builds nothing.
        session.chooseThreadSize("M5")
        await session.threadPreviewSettled()
        XCTAssertNil(session.threadPreview)
        XCTAssertTrue(session.hint.contains("smaller than this 6.8 mm hole") && session.hint.contains("Try M8"), session.hint)
        // A typed diameter that misses is refused at the keypad with the range.
        XCTAssertFalse(session.applyDimension(6, target: .threadDiameter))
        // (Over the hole less the clearance on each side, plus a tenth of the pitch.)
        let least = 6.8 - 2 * (session.threadDraft?.spec.clearance ?? 0) + 0.08
        XCTAssertEqual(session.dimensionError, "Too small to reach this 6.8 mm hole. Enter more than \(session.lengthText(least)).")

        // Length, starts, and fine pitch.
        session.chooseThreadSize("M8")
        session.chooseThreadPitch(1)
        session.setThreadStarts(2)
        XCTAssertFalse(session.applyDimension(0.5, target: .threadLength), "Under a turn")
        XCTAssertTrue(session.applyDimension(10, target: .threadLength))
        await session.threadPreviewSettled()
        XCTAssertNotNil(session.threadPreview)
        XCTAssertEqual(session.threadDraft?.threadedLength ?? 0, 10, accuracy: 1e-9)
        session.confirmThread()
        XCTAssertEqual(session.status, "Threaded M8 × 1, 2-start")
        let thread = try XCTUnwrap(session.workspace.bodies[0].cuts.last?.thread)
        XCTAssertEqual(thread.threadedLength, 10, accuracy: 1e-9)
        XCTAssertEqual(thread.starts, 2)
    }

    func testDeleteHoleTakesOutTheHoleAndItsThread() async throws {
        let (session, controller) = try drilledScene()
        let before = try SolidKernel.solid(for: session.workspace.bodies[0]).volume
        let body = session.workspace.bodies[0]
        let solid = try SolidKernel.solid(for: body)
        let wall = try holeWall(session)
        session.beginThread(bodyID: body.id, face: wall)
        await session.threadPreviewSettled()
        session.confirmThread()
        // Tap the threaded hole (one of its thread faces): its wall's strip offers Delete Hole.
        let threaded = try SolidKernel.solid(for: session.workspace.bodies[0])
        let threadWall = try XCTUnwrap((0..<threaded.faceCount).first { threaded.cylinderSide($0) == -1 })
        session.select(.face(FaceSelection(bodyID: body.id, face: threadWall, plane: nil,
                                           center: try XCTUnwrap(threaded.faceCenter(threadWall)), point: threaded.faceOutline(threadWall)?.points.first)))
        XCTAssertTrue(session.canDeleteSelectedHole)
        // A thread flank (not a round wall) offers it too.
        let threadedBody = session.workspace.bodies[0]
        let flank = try XCTUnwrap((0..<threaded.faceCount).first { threaded.cylinderSide($0) == 0 && threadedBody.thread(atFace: $0, of: threaded) != nil })
        session.select(.face(FaceSelection(bodyID: body.id, face: flank, plane: nil, center: try XCTUnwrap(threaded.faceCenter(flank)))))
        XCTAssertTrue(session.canDeleteSelectedHole)
        session.deleteSelectedHole()
        XCTAssertTrue(session.isDeletingHole, "Worked out in the background")
        await session.holeDeletionSettled()
        XCTAssertEqual(session.status, "Deleted the hole and its thread")
        XCTAssertTrue(session.workspace.bodies[0].cuts.allSatisfy { $0.operation != .hole && $0.operation != .thread })
        XCTAssertGreaterThan(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, before)
        XCTAssertEqual(session.selection, .body(body.id))
        controller.refresh()
        attach(controller, "Hole deleted")
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .thread, "One undo step")
        // A flat face is no hole.
        let top = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0)?.normal.z ?? 0 > 0.9 })
        session.select(.face(FaceSelection(bodyID: body.id, face: top, plane: .top, center: try XCTUnwrap(solid.faceCenter(top)))))
        XCTAssertFalse(session.canDeleteSelectedHole)
    }
    // MARK: Raised threads (October 22, 2026)

    /// A Ø60 tube with 2 mm walls, 20 tall, open at both ends: a jar's neck.
    func tubeScene() throws -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .circle, plane: .top, start: .zero, end: .init(x: 30, y: 0)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        let controller = canvas(session, camera: .reset)
        tap(controller, SIMD3(15, 10, 20))
        session.beginFaceSketch()
        session.chooseTool(.hole)
        controller.refresh()
        tap(controller, SIMD3(0.2, 0.1, 20))
        XCTAssertTrue(session.applyDimension(56, target: .holeDiameter))
        session.confirmHole()
        session.exitSketch()
        session.select(nil)
        controller.refresh()
        return (session, controller)
    }

    func testRaisedThreadKeepsAThinNeckWholeAndTakesACap() async throws {
        let (session, controller) = try tubeScene()
        let body = session.workspace.bodies[0]
        let solid = try SolidKernel.solid(for: body)
        let outside = try XCTUnwrap((0..<solid.faceCount).first { solid.cylinderSide($0) == 1 })
        session.beginThread(bodyID: body.id, face: outside)
        await session.threadPreviewSettled()
        XCTAssertEqual(session.threadDraft?.spec.title, "Ø60 × 3")
        XCTAssertFalse(session.threadDraft?.spec.isRaised ?? true, "Cut by default")
        // The cut grooves leave about 0.2 mm of the 2 mm wall: the hint says so and points to Raised.
        XCTAssertEqual(session.threadWall ?? -1, 0.2, accuracy: 0.11)
        XCTAssertTrue(session.hint.hasPrefix("Only about 0.2 mm of wall stays behind this thread. Choose Raised"), session.hint)

        session.setThreadRaised(true)
        XCTAssertEqual(session.threadDraft?.spec.title, "Ø63.25 × 3", "The neck is the thread's minor diameter")
        await session.threadPreviewSettled()
        XCTAssertNil(session.threadWall)
        XCTAssertTrue(session.hint.hasPrefix("Ø63.25 × 3 is raised on this 60 mm boss"), session.hint)
        XCTAssertTrue(session.hint.hasSuffix("Done adds it."), session.hint)
        // A custom raised thread keeps the neck as its minor when the pitch changes.
        session.chooseThreadPitch(2.5)
        XCTAssertEqual(session.threadDraft?.spec.majorDiameter ?? 0, 60 + 1.082532 * 2.5, accuracy: 1e-9)
        XCTAssertTrue(session.threadPitchChoices.contains { $0.pitch == 3 && $0.usable })
        // A typed diameter the neck would fill is refused.
        XCTAssertFalse(session.applyDimension(61, target: .threadDiameter))
        XCTAssertTrue(session.dimensionError?.hasPrefix("Too small to raise on this 60 mm boss. Enter") == true, session.dimensionError ?? "")
        session.chooseThreadPitch(3)
        session.setThreadStarts(2)
        XCTAssertTrue(session.applyDimension(12, target: .threadLength))
        await session.threadPreviewSettled()
        let preview = try XCTUnwrap(session.threadPreview)
        let built = try SolidKernel.solid(for: preview.bodies[0])
        XCTAssertTrue(built.isValidSolid)
        XCTAssertGreaterThan(built.volume, solid.volume, "Ridges added, nothing cut")
        session.requestCamera(.home)
        controller.refresh()
        attach(controller, "Raised 2-start thread on a jar's neck")
        session.confirmThread()
        XCTAssertEqual(session.status, "Threaded Ø63.25 × 3, 2-start")
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.thread?.isRaised, true)

        // Its cap screws on in step, with its own (cut) thread.
        session.select(.body(body.id))
        XCTAssertEqual(session.matingChoices, [.cap, .nut])
        session.makeMatingPart(.cap)
        await session.matingPartSettled()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        let cap = session.workspace.bodies[1]
        XCTAssertEqual(cap.cuts.last?.thread?.isRaised, false)
        XCTAssertEqual(cap.cuts.last?.thread?.starts, 2)
        let shared = try? SolidKernel.boolean(SolidKernel.solid(for: session.workspace.bodies[0]), SolidKernel.solid(for: cap), .intersect)
        XCTAssertLessThan(shared?.volume ?? 0, 1e-2, "Screwed on without clashing")
        session.select(nil)
        session.requestCamera(.home)
        controller.refresh()
        attach(controller, "The cap screwed onto the raised neck")
        session.toggleHidden(.body(cap.id))
        controller.refresh()
        attach(controller, "The raised neck, its cap hidden")
    }
    /// A threaded solid moves and turns smoothly: a drag draws the picture it already has, moved,
    /// instead of meshing the moved solid again on every step (October 22, 2026).
    func testDraggingAThreadedSolidReusesItsPicture() async throws {
        let (session, controller) = try tubeScene()
        let body = session.workspace.bodies[0]
        let solid = try SolidKernel.solid(for: body)
        let outside = try XCTUnwrap((0..<solid.faceCount).first { solid.cylinderSide($0) == 1 })
        session.beginThread(bodyID: body.id, face: outside)
        session.setThreadRaised(true)
        session.setThreadStarts(2)
        XCTAssertTrue(session.applyDimension(12, target: .threadLength))
        await session.threadPreviewSettled()
        session.confirmThread()
        session.select(.body(body.id))
        session.makeMatingPart(.cap)
        await session.matingPartSettled()
        let cap = session.workspace.bodies[1]
        session.select(.body(cap.id))
        session.requestCamera(.home)
        controller.refresh()

        // The selection strip's size (volume) is worked out once, not on every update of a drag.
        _ = session.selectionMeasure
        let measured = Date()
        for _ in 0..<10 { _ = session.selectionMeasure }
        print("[drag timing] selection size: \(Int(Date().timeIntervalSince(measured) / 10 * 1000)) ms")
        XCTAssertLessThan(Date().timeIntervalSince(measured) / 10, 0.005)

        for handle in [TransformHandle.move(2), .rotate(0)] {
            let builds = controller.solidRenderBuilds
            XCTAssertTrue(session.beginTransform(handle))
            var update = 0.0, draw = 0.0, rebuilds = 0
            for step in 1...30 {
                var start = Date()
                session.updateTransform(Double(step) * (handle.isRotation ? 3 : 1))
                update += Date().timeIntervalSince(start)
                start = Date()
                controller.refresh()
                draw += Date().timeIntervalSince(start)
                if step == 1 { rebuilds = controller.contentRebuilds }
            }
            print("[drag timing] \(handle): update \(Int(update / 30 * 1000)) ms, canvas \(Int(draw / 30 * 1000)) ms per step")
            XCTAssertEqual(controller.solidRenderBuilds, builds, "\(handle): no solid is meshed again during the drag")
            XCTAssertEqual(controller.contentRebuilds, rebuilds, "\(handle): after its first step, only the dragged solid's node moves")
            attach(controller, "Cap dragged: \(handle)")
            session.finishTransform(cancelled: false)
            controller.refresh()
            // The dropped solid is meshed once where it landed, at the next change (here a reselect).
            session.select(nil)
            controller.refresh()
            session.select(.body(cap.id))
            controller.refresh()
        }
        XCTAssertEqual(session.status, "Rotated")

        // A second drag straight after a drop starts from where the first one left the solid.
        XCTAssertTrue(session.beginTransform(.move(0)))
        session.updateTransform(5)
        controller.refresh()
        session.finishTransform(cancelled: false)
        controller.refresh()
        XCTAssertTrue(session.beginTransform(.move(0)))
        for step in 1...3 { session.updateTransform(Double(step)); controller.refresh() }
        let moved = try XCTUnwrap(session.editPreview?.bodies.first { $0.id == cap.id })
        let node = try XCTUnwrap(controller.sceneView.scene?.rootNode.childNode(withName: "body|" + cap.id.uuidString, recursively: true))
        let expected = try SolidKernel.solid(for: moved).bounds
        let (low, high) = node.boundingBox
        let lowWorld = node.simdConvertPosition(SIMD3<Float>(low), to: nil), highWorld = node.simdConvertPosition(SIMD3<Float>(high), to: nil)
        XCTAssertEqual(Double(min(lowWorld.x, highWorld.x)), expected.min.x, accuracy: 0.5, "Drawn where the second drag has it")
        XCTAssertEqual(Double(max(lowWorld.x, highWorld.x)), expected.max.x, accuracy: 0.5)
        session.finishTransform(cancelled: true)
    }
}
