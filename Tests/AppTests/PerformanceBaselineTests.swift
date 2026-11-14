import XCTest
import simd
@testable import SwipeAndSketch

/// Timing baselines (November 10, 2026) for the work the iPad Instruments pass found or fixed, so
/// later changes cannot quietly slow it: an Extrude preview sweep, a sketch point drag, opening
/// and closing templates, a 3MF export, and a Pattern drag. Each runs five times with the solid
/// cache emptied first, so every run does the same work, and each step drains its autorelease
/// pool as a frame does. Baselines are kept per machine and
/// simulator in the project's `xcbaselines`; elsewhere the times are only reported.
@MainActor final class PerformanceBaselineTests: CanvasTestCase {
    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart]
        return options
    }
    private let metrics: [XCTMetric] = [XCTClockMetric(), XCTMemoryMetric()]

    override func tearDown() async throws {
        SolidCache.shared.removeAll()
        try await super.tearDown()
    }

    /// A session on `workspace` as opening a file makes it: decoded from the file's data.
    private func session(opening data: Data) throws -> ModelingSession {
        let document = ProjectDocument(fileURL: URL.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString).swipesketch"))
        try document.load(fromContents: data, ofType: nil)
        let session = ModelingSession(document: document)
        session.lengthUnit = .millimeters
        return session
    }

    private func session(with workspace: Workspace) throws -> ModelingSession {
        var project = Project()
        project.workspace = workspace
        return try session(opening: try ProjectCodec.encode(project))
    }

    private func box(x: Double, y: Double, width: Double, depth: Double, height: Double) throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: x, y: y), end: .init(x: x + width, y: y + depth))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: height)
    }

    /// Empties the memory cache and builds `bodies` again, as a project that is open has them.
    private func rebuild(_ bodies: [SolidBody]) throws {
        SolidCache.shared.removeAll()
        for body in bodies { _ = try SolidKernel.solid(for: body) }
    }

    /// 60 depths of a cut across a row of five of 20 boxes, the canvas drawn after each (scenario 4).
    func testExtrudePreviewSweepAcrossTwentySolids() throws {
        var workspace = Workspace()
        for row in 0..<4 { for column in 0..<5 {
            workspace.bodies.append(try box(x: Double(column) * 30 - 70, y: Double(row) * 30 - 50, width: 20, depth: 20, height: 10))
        } }
        let session = try session(with: workspace)
        let controller = canvas(session)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -80, y: -45), end: .init(x: 80, y: -35)))
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        measure(metrics: metrics, options: options) {
            try? rebuild(workspace.bodies)
            session.extrusionDepth = 0.25
            controller.refresh()
            startMeasuring()
            for step in 1...60 {
                autoreleasepool {
                    session.extrusionDepth = 0.25 + Double(step) * 0.15
                    controller.refresh()
                }
            }
        }
        XCTAssertTrue(session.canConfirmExtrusion)
        XCTAssertEqual(session.operationPreview?.bodies.count, 20, "Five boxes cut, the rest as they were")
        session.cancelExtrusion()
    }

    /// 120 samples dragging a line's end in a Top sketch of 40 rectangles, the canvas and its
    /// overlay (guide and snap dots) drawn after each (scenario 3).
    func testDraggingASketchPointAmongFortyShapes() throws {
        let session = ModelingSession(inMemory: true)
        session.snapEnabled = true
        for row in 0..<5 { for column in 0..<8 {
            let x = Double(column) * 14 - 56, y = Double(row) * 14 - 35
            session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: x, y: y), end: .init(x: x + 10, y: y + 10)))
        } }
        session.addShape(.init(kind: .line, plane: .top, start: .init(x: -60, y: 40), end: .init(x: -20, y: 40)))
        let line = try XCTUnwrap(session.workspace.shapes.last)
        let controller = canvas(session)
        session.beginSketch(); session.pickPlane(.top)
        session.select(.shape(line.id))
        controller.refresh()
        measure(metrics: metrics, options: options) {
            startMeasuring()
            session.beginSketchDrag(shapeID: line.id, handle: .end)
            for sample in 1...120 {
                autoreleasepool {
                    session.updateSketchDrag(to: .init(x: -20 + Double(sample) * 0.6, y: 40 - Double(sample) * 0.3))
                    controller.refresh()
                    controller.input.redrawOverlayNow()
                }
            }
            session.finishSketchDrag(cancelled: true)
        }
        XCTAssertEqual(session.workspace.shapes.last, line, "Each run is rolled back")
    }

    /// The templates' solids built from their definitions, the editor's canvas drawn, then closed (scenario 10, first open).
    func testOpeningAndClosingThePiTemplatesCold() throws {
        try measureOpening(fromDisk: false)
    }

    /// As above, with the built solids already kept on disk (scenario 10, later opens).
    func testOpeningAndClosingThePiTemplatesWarm() throws {
        try measureOpening(fromDisk: true)
    }

    private func measureOpening(fromDisk: Bool) throws {
        let files = try ["electronics.pi-mount", "electronics.pi-case"].map { id in
            let template = try XCTUnwrap(TemplateCatalog.template(id))
            var project = Project()
            project.workspace = try template.workspace(template.defaults)
            return try ProjectCodec.encode(project)
        }
        let disk = BuiltSolidStore.shared.directory
        if fromDisk {
            // Opened once, so the solids are on disk.
            for data in files { for body in try ProjectCodec.decode(data).workspace.visible.bodies { SolidCache.shared.prepare(body) } }
        }
        measure(metrics: metrics, options: options) {
            SolidCache.shared.removeAll()
            if !fromDisk { try? FileManager.default.removeItem(at: disk) }
            startMeasuring()
            for data in files { autoreleasepool {
                guard let session = try? session(opening: data) else { return XCTFail("The file opens") }
                // As the home screen does before the editor shows (`buildSolids`).
                let bodies = session.workspace.visible.bodies
                SolidCache.shared.readFromDisk(bodies)
                for body in bodies { SolidCache.shared.prepare(body) }
                let controller = canvas(session, camera: .reset)
                withExtendedLifetime(controller) {}
                SolidCache.shared.removeAll()
            } }
        }
    }

    /// Export 3MF of the default Gridfinity baseplate, its solids built (scenario 13).
    func testExportingTheGridfinityBaseplateAs3MF() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("gridfinity.baseplate"))
        let bodies = try template.workspace(template.defaults).bodies
        var size = 0
        measure(metrics: metrics, options: options) {
            try? rebuild(bodies)
            startMeasuring()
            size = (try? ModelExport.data(.threeMF, bodies: bodies, title: "Baseplate").count) ?? 0
        }
        XCTAssertGreaterThan(size, 1000)
    }

    /// Delete Fillet on a solid with a long history after the fillet leaves the main thread free:
    /// building the solid again without the round replays every later step, which froze the app
    /// for 0.4–1.3 s on a case's plates (user report, November 11, 2026).
    /// A 60 × 40 × 6 plate, its four top edges rounded by 2 mm, then 40 holes through it.
    private func roundedPlateWithFortyHoles() throws -> SolidBody {
        var plate = try box(x: -30, y: -20, width: 60, depth: 40, height: 6)
        let sharp = try SolidKernel.solid(for: plate)
        let top = (0..<sharp.edgeCount).filter { sharp.edgeSamples($0, count: 5).allSatisfy { abs($0.z - 6) < 1e-6 } }
        XCTAssertEqual(top.count, 4)
        plate = try XCTUnwrap(plate.finishing(.fillet, edges: top, size: 2))
        for row in 0..<5 { for column in 0..<8 {
            let center = Point2(x: Double(column) * 6 - 21, y: Double(row) * 6 - 12)
            let hole = SketchShape(kind: .circle, plane: .top, start: center, end: center + Point2(x: 1.5, y: 0))
            plate.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true))
        } }
        return plate
    }

    /// Halfway around the round along the plate's x = 30 edge.
    private let onPlateRound = SIMD3(28 + 2 * 0.5.squareRoot(), 0, 4 + 2 * 0.5.squareRoot())

    func testDeletingAFilletBeforeFortyHolesLeavesTheMainThreadFree() async throws {
        let plate = try roundedPlateWithFortyHoles()
        var workspace = Workspace()
        workspace.bodies = [plate]
        let session = try session(with: workspace)
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: plate.id, near: onPlateRound))))
        let found = await session.selectedFinishFound()
        XCTAssertEqual(found?.source, .named(0))
        // As an open project has it: the plate built, the plate without its round not.
        SolidCache.shared.removeAll()
        _ = try SolidKernel.solid(for: plate)

        let clock = ContinuousClock(), start = clock.now
        session.deleteSelectedFinish()
        let onMainThread = clock.now - start
        XCTAssertTrue(session.isDeletingFinish, "Worked out in the background")
        await session.finishDeletionSettled()
        let whole = clock.now - start
        print("Delete Fillet: \(onMainThread) on the main thread, \(whole) in all")
        XCTAssertLessThan(onMainThread, .milliseconds(50))
        XCTAssertLessThan(onMainThread * 4, whole, "The rebuild is not on the main thread")
        XCTAssertEqual(session.workspace.bodies[0].finishes, [])
        XCTAssertEqual(session.workspace.bodies[0].cuts.count, 40)
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].finishes.count, 1, "One undo step")
    }

    /// Each face picked for Delete Face closes the gap off the main thread on screen: it rebuilds the
    /// whole solid, up to 3.2 s a tap on a 700-face solid (user report, November 11, 2026).
    func testPickingAFaceToDeleteLeavesTheMainThreadFree() async throws {
        let plate = try roundedPlateWithFortyHoles()
        var workspace = Workspace()
        workspace.bodies = [plate]
        let session = try session(with: workspace)
        session.buildsPreviewsInBackground = true
        let face = try XCTUnwrap(session.faceSelection(bodyID: plate.id, near: onPlateRound))
        session.chooseTool(.deleteFace)
        SolidCache.shared.removeAll()
        _ = try SolidKernel.solid(for: plate)

        let clock = ContinuousClock(), start = clock.now
        session.toggleDeleteFace(bodyID: plate.id, face: face.face, at: onPlateRound)
        let onMainThread = clock.now - start
        XCTAssertNil(session.deleteFacePreview, "Not built yet")
        await session.deleteFacePreviewSettled()
        let whole = clock.now - start
        print("Delete Face preview: \(onMainThread) on the main thread, \(whole) in all")
        XCTAssertLessThan(onMainThread, .milliseconds(50))
        XCTAssertLessThan(onMainThread * 4, whole, "The rebuild is not on the main thread")
        XCTAssertNotNil(session.deleteFacePreview)
        XCTAssertNil(session.deleteFaceError)
        session.confirmDeleteFace()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .deleteFace)
        XCTAssertEqual(session.workspace.bodies[0].cuts.count, 41)
        XCTAssertEqual(session.tool, .select)
    }

    /// Times `action` on the main thread and until `settled` returns, and checks the rebuild was not on the main thread.
    private func assertMainThreadFree(_ name: String, _ action: () -> Void, settled: () async -> Void,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        let clock = ContinuousClock(), start = clock.now
        action()
        let onMainThread = clock.now - start
        await settled()
        let whole = clock.now - start
        print("\(name): \(onMainThread) on the main thread, \(whole) in all")
        XCTAssertLessThan(onMainThread, .milliseconds(50), file: file, line: line)
        XCTAssertLessThan(onMainThread * 4, whole, "The rebuild is not on the main thread", file: file, line: line)
    }

    /// Each pick for Mirror builds the mirrored solid off the main thread on screen: its definition
    /// is new, so it is built from its whole history (November 11, 2026).
    func testMirroringASolidWithFortyHolesLeavesTheMainThreadFree() async throws {
        let plate = try roundedPlateWithFortyHoles()
        var workspace = Workspace()
        workspace.bodies = [plate]
        let session = try session(with: workspace)
        session.buildsPreviewsInBackground = true
        session.select(.body(plate.id))
        session.chooseTool(.mirror)
        await assertMainThreadFree("Mirror preview", {
            session.pickMirrorPlane(MirrorPlane(source: .world(.front), plane: .front))
            XCTAssertNil(session.mirrorPreview, "Not built yet")
            XCTAssertEqual(session.hint, "Mirroring…")
        }, settled: { await session.mirrorPreviewSettled() })
        XCTAssertNotNil(session.mirrorPreview)
        XCTAssertTrue(session.hint.contains("Done"))
        session.confirmMirror()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        XCTAssertEqual(session.workspace.bodies[1].cuts.count, 40)
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[1]).volume, try SolidKernel.solid(for: plate).volume, accuracy: 1e-6)
    }

    /// A fillet's size typed on its face, and a solid's depth, are built off the main thread on
    /// screen: each replays the steps after it, or the whole history (November 11, 2026).
    func testTypingAFilletSizeOrDepthLeavesTheMainThreadFree() async throws {
        let plate = try roundedPlateWithFortyHoles()
        var workspace = Workspace()
        workspace.bodies = [plate]
        let session = try session(with: workspace)
        session.select(.face(try XCTUnwrap(session.faceSelection(bodyID: plate.id, near: onPlateRound))))
        let found = await session.selectedFinishFound()
        XCTAssertEqual(found?.source, .named(0))
        session.buildsPreviewsInBackground = true
        await assertMainThreadFree("Fillet size", {
            XCTAssertTrue(session.applyDimension(1.5, target: .selectedFinish(.fillet)), "Accepted")
            XCTAssertTrue(session.isResizingDimension)
        }, settled: { await session.dimensionResizeSettled() })
        XCTAssertEqual(session.workspace.bodies[0].finishes.first?.size, 1.5)
        XCTAssertEqual(session.selectedFinish?.size, 1.5, "The moved round stays selected")
        XCTAssertNil(session.dimensionError)

        // Too big: refused once built, the keypad left open with the reason.
        XCTAssertTrue(session.applyDimension(30, target: .selectedFinish(.fillet)))
        await session.dimensionResizeSettled()
        XCTAssertEqual(session.workspace.bodies[0].finishes.first?.size, 1.5)
        XCTAssertNotNil(session.dimensionError)

        session.select(.body(plate.id))
        await assertMainThreadFree("Depth", {
            XCTAssertTrue(session.applyDimension(8, target: .bodyDepth(plate.id)))
        }, settled: { await session.dimensionResizeSettled() })
        XCTAssertEqual(session.workspace.bodies[0].depth, 8)
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].depth, 6, "One undo step")
    }

    /// A 60 × 40 × 6 plate with `feature` made first on its top face, then 40 holes through it,
    /// so editing the feature replays them all.
    private func plateWithFortyHoles(after feature: (inout Workspace, SolidBody, SketchPlane) throws -> Void) throws -> Workspace {
        let plate = try box(x: -30, y: -20, width: 60, depth: 40, height: 6)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 6), normal: .init(0, 0, 1)))
        var workspace = Workspace()
        workspace.bodies = [plate]
        try feature(&workspace, plate, top)
        for row in 0..<5 { for column in 0..<8 {
            let center = Point2(x: Double(column) * 6 - 21, y: Double(row) * 6 - 12)
            let hole = SketchShape(kind: .circle, plane: .top, start: center, end: center + Point2(x: 1.5, y: 0))
            workspace.bodies[0].cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true))
        } }
        return workspace
    }

    /// Moving a hole made before 40 others (Edit Hole) builds off the main thread on screen: it
    /// replays every step after it (November 11, 2026).
    func testMovingAnEditedHoleLeavesTheMainThreadFree() async throws {
        let workspace = try plateWithFortyHoles { workspace, plate, top in
            workspace.bodies[0].cuts.append(try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.simple, size: "M3"), at: Point2(x: 25, y: 15), on: top, depth: nil)))
        }
        let plate = workspace.bodies[0]
        let session = try session(with: workspace)
        session.buildsPreviewsInBackground = true
        session.editHole(bodyID: plate.id, cut: 0)
        await session.holePreviewSettled()
        XCTAssertNotNil(session.holePreview)
        await assertMainThreadFree("Edit Hole move", { session.placeHole(at: Point2(x: 25, y: -15)) },
                                   settled: { await session.holePreviewSettled() })
        XCTAssertNil(session.draftError)
        session.confirmHole()
        let edited = session.workspace.bodies[0]
        XCTAssertEqual(edited.cuts.count, 41)
        XCTAssertEqual(edited.cuts[0].profile.circle?.center, Point2(x: 25, y: -15), "Moved in its place")
    }

    /// Moving a peg made before 40 holes (Edit Peg) builds off the main thread on screen: it builds
    /// the solid without the peg and again with it, each replaying the holes (November 11, 2026).
    func testMovingAnEditedPegLeavesTheMainThreadFree() async throws {
        let workspace = try plateWithFortyHoles { workspace, plate, top in
            workspace = try XCTUnwrap(PegJoint.add(PegSpec(), at: Point2(x: 25.5, y: 15), on: top, to: plate.id, in: workspace)).workspace
        }
        let plate = workspace.bodies[0]
        let peg = try XCTUnwrap(plate.cuts.first { $0.peg != nil }?.peg)
        let session = try session(with: workspace)
        session.buildsPreviewsInBackground = true
        session.editPeg(peg, from: plate.id)
        await session.pegPreviewSettled()
        XCTAssertNotNil(session.pegPreview)
        await assertMainThreadFree("Edit Peg move", { session.placePeg(at: Point2(x: 25.5, y: -15)) },
                                   settled: { await session.pegPreviewSettled() })
        XCTAssertNil(session.draftError)
        session.confirmPeg()
        let edited = session.workspace.bodies[0]
        XCTAssertEqual(edited.cuts.count, plate.cuts.count)
        let join = try XCTUnwrap(edited.cuts.first { $0.peg == peg && $0.operation == .join })
        XCTAssertEqual(join.profile.circle?.center, Point2(x: 25.5, y: -15), "Moved")
        XCTAssertEqual(edited.cuts.last?.throughAll, true, "Still before the holes")
    }

    /// A step of a Scale drag builds off the main thread on screen: a scale step on the whole solid,
    /// and a check of its definition (November 11, 2026).
    func testScalingASolidWithFortyHolesLeavesTheMainThreadFree() async throws {
        let plate = try roundedPlateWithFortyHoles()
        var workspace = Workspace()
        workspace.bodies = [plate]
        let session = try session(with: workspace)
        session.buildsPreviewsInBackground = true
        session.select(.body(plate.id))
        session.beginScale()
        await assertMainThreadFree("Scale step", { XCTAssertTrue(session.setScalePercent(150, axis: 3)) },
                                   settled: { await session.scalePreviewSettled() })
        XCTAssertNotNil(session.scalePreview)
        XCTAssertNil(session.scaleError)
        // Dragging the gizmo scales the solid on screen, built only once it is let go.
        session.beginScaleDrag()
        session.setScalePercent(160, axis: 3)
        XCTAssertNil(session.scalePreview)
        XCTAssertEqual(session.scaleGhost?.bodies, [plate.id])
        XCTAssertEqual(session.scaleGhost?.transform.columns.0.x ?? 0, 1.6, accuracy: 1e-9)
        session.setScalePercent(150, axis: 3)
        session.endScaleDrag()
        await session.scalePreviewSettled()
        XCTAssertNotNil(session.scalePreview)
        XCTAssertNil(session.scaleGhost)
        session.confirmScale()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .scale)
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[0]).volume, try SolidKernel.solid(for: plate).volume * 1.5 * 1.5 * 1.5, accuracy: 1e-3)
    }

    /// Each face picked for Draft leans them on the whole solid, off the main thread on screen (November 11, 2026).
    func testPickingAFaceToDraftLeavesTheMainThreadFree() async throws {
        let workspace = try plateWithFortyHoles { _, _, _ in }
        let plate = workspace.bodies[0]
        let session = try session(with: workspace)
        session.buildsPreviewsInBackground = true
        session.chooseTool(.draft)
        session.pickDraftNeutral(bodyID: plate.id, point: [0, 0, 0], outward: [0, 0, -1])
        // As an open project has it.
        _ = try SolidKernel.solid(for: plate)
        await assertMainThreadFree("Draft face", { session.toggleDraftFace(bodyID: plate.id, point: [30, 0, 3]) },
                                   settled: { await session.shapeToolPreviewSettled() })
        XCTAssertNotNil(session.shapeToolPreview)
        XCTAssertNil(session.shapeToolDraft?.error)
        session.confirmShapeTool()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .draft)
    }

    /// Section cuts and meshes every solid shown off the main thread on screen, showing each solid
    /// whole until its section comes (November 11, 2026).
    func testSectionBuildsOffTheMainThread() async throws {
        let plate = try roundedPlateWithFortyHoles()
        var workspace = Workspace()
        workspace.bodies = [plate]
        let session = try session(with: workspace)
        let controller = canvas(session)
        session.buildsPreviewsInBackground = true
        session.toggleSection()
        await assertMainThreadFree("Section", { controller.refresh() }, settled: { await controller.sectionsSettled() })
        XCTAssertNotNil(controller.content.childNode(withName: "section.cap", recursively: true), "Drawn once built")
        // Dragging the plane cuts on the GPU, with nothing built, until it is let go.
        let handle = try XCTUnwrap(controller.sectionHandle())
        controller.pencilBegan(at: handle.center)
        let along = { (step: CGFloat) in CGPoint(x: handle.center.x + handle.axis.dx * step, y: handle.center.y + handle.axis.dy * step) }
        controller.pencilMoved(to: along(10))
        controller.refresh()
        XCTAssertNotNil(controller.content.childNode(withName: "section.inside", recursively: true), "Cut on the GPU")
        await assertMainThreadFree("Section drag step", {
            controller.pencilMoved(to: along(30))
            controller.refresh()
        }, settled: { try? await Task.sleep(for: .milliseconds(100)) })
        controller.pencilEnded(at: along(30), cancelled: false)
        controller.refresh()
        await controller.sectionsSettled()
        XCTAssertNotNil(controller.content.childNode(withName: "section.cap", recursively: true), "Built once let go")
        XCTAssertNil(controller.content.childNode(withName: "section.inside", recursively: true))
        session.toggleSection()
    }

    /// 60 steps of a Pattern distance drag making 20 copies of a solid with 40 holes, each its own
    /// step, the canvas drawn after each (scenario 8).
    func testPatternDragOfALongHistorySolid() throws {
        var plate = try box(x: -30, y: -20, width: 60, depth: 40, height: 6)
        for row in 0..<5 { for column in 0..<8 {
            let center = Point2(x: Double(column) * 6 - 21, y: Double(row) * 6 - 12)
            let hole = SketchShape(kind: .circle, plane: .top, start: center, end: center + Point2(x: 1.5, y: 0))
            plate.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true))
        } }
        XCTAssertEqual(plate.historySteps, 40)
        var workspace = Workspace()
        workspace.bodies = [plate]
        let session = try session(with: workspace)
        let controller = canvas(session)
        session.select(.body(plate.id))
        session.chooseTool(.pattern)
        session.setPatternDistance(1300, axis: 0)
        XCTAssertTrue(session.setPatternCount(20))
        measure(metrics: metrics, options: options) {
            try? rebuild([plate])
            session.setPatternDistance(1300, axis: 0)
            controller.refresh()
            startMeasuring()
            for step in 1...60 {
                autoreleasepool {
                    session.setPatternDistance(1300 + Double(step) * 5, axis: 0)
                    controller.refresh()
                }
            }
        }
        XCTAssertEqual(session.patternPreview?.bodies.count, 20)
        session.cancelPattern()
    }

    /// A plate with 100 small hexagon pockets in a row, each its own step, built from its definition
    /// as on the first open after an update (November 11, 2026). A run of plain cuts is subtracted in
    /// one boolean; the cut-by-cut build (every earlier step first, as the background pass used to)
    /// and the background pass of earlier steps are timed once beside it and reported, and the
    /// first two must make the same solid.
    func testBuildingAHundredConsecutiveCuts() throws {
        var plate = try box(x: -65, y: -55, width: 130, depth: 110, height: 6)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 6), normal: .init(0, 0, 1)))
        for row in 0..<10 { for column in 0..<10 {
            let center = Point2(x: Double(column) * 12 - 54 + Double(row % 2) * 6, y: Double(row) * 11 - 50)
            let lines = SketchTools.polygon(center: center, vertex: center + Point2(x: 4.5, y: 0), sides: 6, plane: top)
            plate.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: lines, on: top).first), depth: -4))
        } }
        XCTAssertEqual(plate.historySteps, 100)
        func timed(_ build: () throws -> KernelSolid) throws -> (solid: KernelSolid, seconds: Double) {
            SolidCache.shared.removeAll()
            let clock = ContinuousClock(), start = clock.now
            let solid = try build()
            let elapsed = clock.now - start
            return (solid, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
        }
        let inTurn = try timed {
            var prefix = plate
            for count in 0..<plate.cuts.count {
                prefix.cuts = Array(plate.cuts[..<count])
                _ = try SolidKernel.solid(for: prefix)
            }
            return try SolidKernel.solid(for: plate)
        }
        let together = try timed { try SolidKernel.solid(for: plate) }
        let background = try timed {
            SolidCache.shared.buildSteps(of: plate) { true }
            return try SolidKernel.solid(for: plate)
        }
        let report = String(format: "100 cuts built one at a time: %.2f s; with the run together: %.2f s; earlier steps in the background: %.2f s",
                            inTurn.seconds, together.seconds, background.seconds)
        print(report)
        XCTContext.runActivity(named: report) { _ in }
        XCTAssertEqual(together.solid.volume, inTurn.solid.volume, accuracy: 1e-6 * inTurn.solid.volume)
        XCTAssertEqual(together.solid.faceCount, inTurn.solid.faceCount)
        XCTAssertEqual(together.solid.faceCount, 6 + 100 * 7, "Each pocket adds its six walls and floor")
        XCTAssertLessThan(together.seconds, inTurn.seconds)
        measure(metrics: metrics, options: options) {
            SolidCache.shared.removeAll()
            startMeasuring()
            _ = try? SolidKernel.solid(for: plate)
        }
    }
}
