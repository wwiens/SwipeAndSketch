import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Export, Union, Shell, and Hole through the session, canvas, and kernel.
@MainActor final class OperationToolTests: CanvasTestCase {



    func volume(_ session: ModelingSession, _ index: Int = 0) throws -> Double {
        try SolidKernel.solid(for: session.workspace.bodies[index]).volume
    }

    // MARK: Export

    /// Exports run off the main thread; waits for the shared file.
    func exported(_ session: ModelingSession, _ format: ModelExport.Format) async throws -> URL {
        let previous = session.exportItem?.url
        session.export(format)
        XCTAssertTrue(session.isProjectBusy, "the project waits while the file is written")
        for _ in 0..<500 where session.isProjectBusy { try await Task.sleep(for: .milliseconds(10)) }
        let url = try XCTUnwrap(session.exportItem?.url)
        XCTAssertNotEqual(url, previous)
        if let previous { XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path), "the last export's copy is removed") }
        return url
    }

    func testExportWritesShareableThreeMFAndSTL() async throws {
        let (session, _) = boxScene()
        XCTAssertTrue(session.canExport)
        let threeMF = try await exported(session, .threeMF)
        XCTAssertEqual(threeMF.pathExtension, "3mf")
        XCTAssertEqual(try Data(contentsOf: threeMF).prefix(2), Data("PK".utf8), "A zip package")
        let stl = try Data(contentsOf: try await exported(session, .stl))
        let count = stl.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(stl.count, 84 + Int(count) * 50)
        XCTAssertEqual(count, 12, "A box is twelve triangles")
        XCTAssertNil(session.saveError)
        XCTAssertFalse(ModelingSession(inMemory: true).canExport, "Nothing to export without solids")
    }

    // MARK: Union

    /// A second box, x 30…50, touching the first (x −30…30) and 10 mm tall.
    func addTouchingBox(_ session: ModelingSession, from x0: Double = 30, to x1: Double = 50) {
        session.choosePlane(.top)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: x0, y: -10), end: .init(x: x1, y: 10)))
        session.beginExtrusion()
        session.chooseExtrusionMode(.newBody)
        session.extrusionDepth = 10
        session.confirmExtrusion()
        session.chooseTool(.select)
        // Choosing Top looks straight down, and extruding keeps the view: back to the 3D angle.
        session.requestCamera(.home)
    }

    func testUnionTouchingSolidsIntoTheLastPicked() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session)
        XCTAssertEqual(session.workspace.bodies.count, 2)
        let first = session.workspace.bodies[0].id, second = session.workspace.bodies[1].id
        session.select(.body(first))
        session.chooseTool(.union)
        XCTAssertEqual(session.unionDraft?.bodies, [first], "The selected solid is picked")
        controller.refresh()
        tap(controller, SIMD3(40, 0, 10))
        XCTAssertEqual(session.unionDraft?.target, second, "The last picked is the target")
        XCTAssertNotNil(controller.previewNode.childNode(withName: "union.target", recursively: false))
        XCTAssertEqual(session.unionPreview?.bodies.count, 1)
        XCTAssertEqual(session.workspace.bodies.count, 2, "A preview until Done")
        session.confirmUnion()
        XCTAssertNil(session.unionDraft)
        XCTAssertEqual(session.workspace.bodies.count, 1)
        XCTAssertEqual(session.workspace.bodies[0].id, second)
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .merge)
        XCTAssertEqual(session.selection, .body(second))
        XCTAssertEqual(try volume(session), 48_000 + 4_000, accuracy: 1e-3)
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2, "Undo brings the other solid back")
    }

    func testUnionOfAChainWithKeepOriginals() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session)
        addTouchingBox(session, from: 50, to: 70)
        let ids = session.workspace.bodies.map(\.id)
        session.select(nil)
        session.chooseTool(.union)
        XCTAssertEqual(session.unionDraft?.bodies, [])
        controller.refresh()
        // The far box touches only the middle one; picked first, it still joins.
        session.selectItem(.body(ids[2]))
        session.selectItem(.body(ids[0]))
        session.selectItem(.body(ids[1]))
        XCTAssertEqual(session.unionPreview?.bodies.count, 1)
        session.setUnionKeepOriginals(true)
        XCTAssertEqual(session.unionPreview?.bodies.count, 4)
        session.confirmUnion()
        XCTAssertEqual(session.workspace.bodies.count, 4)
        XCTAssertEqual(Array(session.workspace.bodies.prefix(2).map(\.id)), Array(ids.prefix(2)), "The originals stay")
        let united = try XCTUnwrap(session.workspace.bodies.first { !ids.contains($0.id) })
        XCTAssertEqual(session.selection, .body(united.id))
        XCTAssertEqual(try SolidKernel.solid(for: united).volume, 48_000 + 2 * 4_000, accuracy: 1e-3)
    }

    func testUnionRefusesSolidsThatDoNotTouch() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 40, to: 60)
        session.select(.body(session.workspace.bodies[0].id))
        session.chooseTool(.union)
        controller.refresh()
        tap(controller, SIMD3(50, 0, 10))
        XCTAssertNil(session.unionPreview)
        XCTAssertEqual(session.hint, "Body 01 does not touch the others. Tap it to leave it out.")
        session.cancelUnion()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        XCTAssertEqual(session.tool, .select)
    }

    // MARK: Intersect

    func testIntersectKeepsOnlyTheOverlap() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 20, to: 50)
        let first = session.workspace.bodies[0].id, second = session.workspace.bodies[1].id
        session.select(.body(first))
        session.chooseTool(.intersect)
        XCTAssertEqual(session.tool, .intersect)
        XCTAssertEqual(session.unionDraft?.intersect, true)
        XCTAssertEqual(session.helpTopic, .intersect)
        controller.refresh()
        tap(controller, SIMD3(40, 0, 10))
        XCTAssertEqual(session.unionDraft?.target, second)
        XCTAssertEqual(session.unionPreview?.bodies.count, 1)
        session.confirmUnion()
        XCTAssertEqual(session.workspace.bodies.map(\.id), [second])
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .intersect)
        XCTAssertEqual(try volume(session), 10 * 20 * 10, accuracy: 1e-3)
        XCTAssertEqual(session.status, "Intersected 2 solids")
        XCTAssertEqual(session.tool, .select)
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2)
    }

    func testIntersectRefusesSolidsThatDoNotOverlap() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 40, to: 60)
        session.select(.body(session.workspace.bodies[0].id))
        session.chooseTool(.intersect)
        controller.refresh()
        tap(controller, SIMD3(50, 0, 10))
        XCTAssertNil(session.unionPreview)
        XCTAssertEqual(session.hint, "These solids do not all overlap, so nothing would be left. Tap one to leave it out.")
        session.cancelUnion()
        XCTAssertEqual(session.tool, .select)
    }

    func testShellOpensAFaceMadeByAJoinAndATapOnEmptySpaceFinishes() throws {
        let (session, controller) = boxScene()
        // A round boss joined on top: its top face is not an original extrusion face.
        tap(controller, SIMD3(5, 3, 20))
        session.beginFaceSketch()
        let top = try XCTUnwrap(session.sketchMode?.plane)
        let circle = SketchShape(kind: .circle, plane: top, start: top.coordinates(of: .init(0, 0, 20)),
                                 end: top.coordinates(of: .init(8, 0, 20)))
        session.addShape(circle)
        session.exitSketch()
        session.select(.shape(circle.id))
        session.beginExtrusion()
        session.extrusionDepth = 10
        XCTAssertTrue(session.isJoining)
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 1)
        session.select(nil)
        session.chooseTool(.shell)
        controller.refresh()
        tap(controller, SIMD3(2, 1, 30))
        let opening = try XCTUnwrap(session.shellDraft?.openings.first)
        XCTAssertNil(opening.name, "Saved by a point on it")
        XCTAssertNotNil(session.shellPreview, "\(session.hint)")
        XCTAssertNotNil(controller.shellHandle())
        // Empty canvas, away from the solid and the handle.
        controller.pencilBegan(at: CGPoint(x: 120, y: 760))
        controller.pencilEnded(at: CGPoint(x: 120, y: 760), cancelled: false)
        XCTAssertNil(session.shellDraft, "Done")
        let shell = try XCTUnwrap(session.workspace.bodies[0].cuts.last?.shell)
        XCTAssertEqual(shell.openPoints?.count, 1)
        XCTAssertLessThan(try volume(session), 48_000 + .pi * 64 * 10 - 20_000)
    }

    func testShellFromASelectedFaceOrSolid() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertNotNil(session.selectedFace)
        session.shellSelection()
        XCTAssertEqual(session.tool, .shell)
        XCTAssertEqual(session.shellDraft?.openFaces, [ExtrusionFace(position: .cap, index: 0)], "The face opens straight away, by name")
        XCTAssertNotNil(session.shellPreview)
        session.cancelShell()
        session.select(.body(session.workspace.bodies[0].id))
        session.shellSelection()
        XCTAssertEqual(session.shellDraft?.openings, [], "A solid waits for its faces")
        XCTAssertEqual(session.hint, "Tap at least one face to leave open, such as the top.")
    }

    // MARK: Align

    func testAlignASelectedFaceOntoAnotherSolidFlipAndOffset() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 60, to: 80)
        let small = session.workspace.bodies[1].id
        session.select(nil)
        controller.refresh()
        tap(controller, SIMD3(70, 0, 10))
        XCTAssertEqual(session.selectedFace?.bodyID, small)
        session.chooseTool(.align)
        XCTAssertEqual(session.alignDraft?.bodies, [small])
        XCTAssertEqual(session.alignDraft?.from?.kind, .plane, "The selected face is what gets aligned")
        XCTAssertEqual(session.alignDraft?.step, .to)
        controller.refresh()
        tap(controller, SIMD3(-10, 0, 20))
        XCTAssertEqual(session.alignDraft?.to?.kind, .plane)
        func smallBounds(_ workspace: Workspace?) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
            try SolidKernel.solid(for: try XCTUnwrap(workspace?.bodies.first { $0.id == small })).bounds
        }
        // Face to face: turned over onto the big box's top, centered on it.
        var b = try smallBounds(session.alignPreview)
        XCTAssertEqual(b.min.z, 20, accuracy: 1e-6)
        XCTAssertEqual(b.max.z, 30, accuracy: 1e-6)
        XCTAssertEqual((b.min.x + b.max.x) / 2, 0, accuracy: 1e-6)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "align.to", recursively: false))
        XCTAssertNotNil(controller.alignHandle())
        XCTAssertEqual(Set(controller.dimensionAnnotations().map(\.target)), [.alignOffset, .alignAngle])
        session.setAlignFlip(true)
        b = try smallBounds(session.alignPreview)
        XCTAssertEqual(b.max.z, 20, accuracy: 1e-6, "Flush the same way instead")
        session.setAlignFlip(false)
        XCTAssertTrue(session.applyDimension(5, target: .alignOffset))
        XCTAssertTrue(session.applyDimension(90, target: .alignAngle))
        b = try smallBounds(session.alignPreview)
        XCTAssertEqual(b.min.z, 25, accuracy: 1e-6, "5 mm off the face")
        XCTAssertEqual(b.max.x - b.min.x, 20, accuracy: 1e-6, "A quarter turn swaps its 20 × 20 footprint onto itself")
        XCTAssertEqual(session.workspace.bodies[1].profile.plane, .top, "A preview until Done")
        attach(controller, "Align preview")
        session.confirmAlign()
        XCTAssertNil(session.alignDraft)
        XCTAssertEqual(session.selection, .body(small))
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[1]).bounds.min.z, 25, accuracy: 1e-6)
        session.undo()
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[1]).bounds.min.z, 0, accuracy: 1e-6, "One undo step")
    }

    /// A tap on a cylinder's side picks its nearer rim, for From and To (user report, October 25,
    /// 2026: no part of a cylinder could be picked; only its thin rims could).
    func testAlignACylinderBySideTapsOntoAnotherCylinder() throws {
        let (session, controller) = boxScene()
        func addCylinder(at center: Point2, radius: Double, height: Double) throws -> UUID {
            session.choosePlane(.top)
            session.addShape(.init(kind: .circle, plane: .top, start: center, end: center + Point2(x: radius, y: 0)))
            session.beginExtrusion()
            session.chooseExtrusionMode(.newBody)
            session.extrusionDepth = height
            session.confirmExtrusion()
            session.chooseTool(.select)
            session.requestCamera(.home)
            return try XCTUnwrap(session.workspace.bodies.last).id
        }
        let peg = try addCylinder(at: .init(x: 70, y: 0), radius: 5, height: 10)
        let post = try addCylinder(at: .init(x: 0, y: -45), radius: 8, height: 20)
        session.select(.body(peg))
        session.chooseTool(.align)
        controller.refresh()
        // High on the peg's front side: its top rim.
        tap(controller, SIMD3(70, -5, 8))
        let from = try XCTUnwrap(session.alignDraft?.from)
        XCTAssertEqual(from.kind, .circle)
        XCTAssertEqual(from.point.z, 10, accuracy: 1e-6)
        XCTAssertEqual(session.alignDraft?.step, .to)
        // The peg's own side is not a target, and nothing behind it is picked instead.
        tap(controller, SIMD3(70 + 5 * 0.7071, -5 * 0.7071, 5))
        XCTAssertNil(session.alignDraft?.to)
        // High on the post's front side: its top rim.
        tap(controller, SIMD3(0, -53, 17))
        let to = try XCTUnwrap(session.alignDraft?.to)
        XCTAssertEqual(to.kind, .circle)
        XCTAssertEqual(to.point.x, 0, accuracy: 1e-6)
        XCTAssertEqual(to.point.y, -45, accuracy: 1e-6)
        XCTAssertEqual(to.point.z, 20, accuracy: 1e-6)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "align.to", recursively: true))
        let preview = try XCTUnwrap(session.alignPreview?.bodies.first { $0.id == peg })
        let b = try SolidKernel.solid(for: preview).bounds
        XCTAssertEqual((b.min.x + b.max.x) / 2, 0, accuracy: 1e-6, "Concentric with the post")
        XCTAssertEqual((b.min.y + b.max.y) / 2, -45, accuracy: 1e-6)
        XCTAssertEqual(min(abs(b.min.z - 20), abs(b.max.z - 20)), 0, accuracy: 1e-6, "Its rim on the post's rim")
        session.confirmAlign()
        XCTAssertEqual(session.selection, .body(peg))
        XCTAssertEqual(session.workspace.bodies.first { $0.id == post }.map { try? SolidKernel.solid(for: $0).bounds.max.z } ?? nil, 20, "The post stays put")
    }

    func testAlignCornerToCornerOfAnotherBox() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 60, to: 80)
        let small = session.workspace.bodies[1].id
        session.select(.body(small))
        session.chooseTool(.align)
        controller.refresh()
        XCTAssertEqual(session.alignDraft?.step, .from)
        // A tap on the small box's corner picks the point, not the edges meeting there.
        tap(controller, SIMD3(60, -10, 10))
        let from = try XCTUnwrap(session.alignDraft?.from)
        XCTAssertEqual(from.kind, .point)
        XCTAssertEqual(from.point, SIMD3(60, -10, 10))
        XCTAssertEqual(session.alignDraft?.step, .to)
        XCTAssertTrue(session.hint.contains("point"), session.hint)
        // Onto the big box's top front right corner.
        tap(controller, SIMD3(30, -20, 20))
        XCTAssertEqual(session.alignDraft?.to?.kind, .point)
        XCTAssertEqual(session.alignDraft?.to?.point, SIMD3(30, -20, 20))
        let preview = try XCTUnwrap(session.alignPreview?.bodies.first { $0.id == small })
        let b = try SolidKernel.solid(for: preview).bounds
        XCTAssertEqual(b.min, SIMD3(30, -20, 10), "Moved so the corners meet, without turning")
        XCTAssertEqual(b.max, SIMD3(50, 0, 20))
        XCTAssertNil(controller.alignHandle(), "No offset or turn for points")
        XCTAssertTrue(controller.dimensionAnnotations().isEmpty)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "align.from", recursively: true))
        XCTAssertNotNil(controller.previewNode.childNode(withName: "align.to", recursively: true))
        attach(controller, "Align corner to corner")
        session.confirmAlign()
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[1]).bounds.min, SIMD3(30, -20, 10))
        session.undo()
        XCTAssertEqual(try SolidKernel.solid(for: session.workspace.bodies[1]).bounds.min, SIMD3(60, -10, 0), "One undo step")
    }

    func testAlignPointsToSketchPointsButNotToFaces() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 60, to: 80)
        let small = session.workspace.bodies[1].id
        let line = SketchShape(kind: .line, plane: .top, start: .init(x: 0, y: -50), end: .init(x: 20, y: -50))
        session.addShape(line)
        session.select(.body(small))
        session.chooseTool(.align)
        controller.refresh()
        tap(controller, SIMD3(80, -10, 10))
        XCTAssertEqual(session.alignDraft?.from?.kind, .point)
        // The end of a sketch line (the origin is offered too, but here it is hidden under the big box).
        tap(controller, SIMD3(20, -50, 0))
        XCTAssertEqual(session.alignDraft?.to?.source, .sketchPoint(line.id, SIMD3(20, -50, 0)))
        let moved = try SolidKernel.solid(for: XCTUnwrap(session.alignPreview?.bodies.first { $0.id == small })).bounds
        XCTAssertEqual(moved.max.x, 20, accuracy: 1e-9); XCTAssertEqual(moved.min.y, -50, accuracy: 1e-9); XCTAssertEqual(moved.max.z, 0, accuracy: 1e-9)
        session.setAlignTo(.plane(.world(.top)))
        XCTAssertNil(session.alignPreview)
        XCTAssertTrue(session.hint.contains("corner with a point"), session.hint)
    }

    func testAlignNeedsMatchingKindsAndStartsFromAnEdge() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 60, to: 80)
        let small = session.workspace.bodies[1].id
        session.select(.body(small))
        session.chooseTool(.align)
        XCTAssertEqual(session.alignDraft?.step, .from)
        controller.refresh()
        tap(controller, SIMD3(70, 0, 10))
        XCTAssertEqual(session.alignDraft?.from?.kind, .plane)
        session.setAlignTo(try XCTUnwrap(AlignFeature.shape(SketchShape(kind: .line, plane: .top, start: .init(x: 0, y: 40), end: .init(x: 10, y: 40)))))
        XCTAssertNil(session.alignPreview)
        XCTAssertTrue(session.hint.hasPrefix("Those do not go together"), session.hint)
        session.cancelAlign()
        XCTAssertNil(session.alignDraft)
        XCTAssertEqual(session.tool, .select)
        // A selected straight edge is what gets aligned.
        let body = session.workspace.bodies[1]
        let edge = try XCTUnwrap(body.extrusionEdges.first { $0.position == .cap })
        session.select(.edge(small, try XCTUnwrap(PickedEdge.named(edge, on: XCTUnwrap(session.workspace.bodies.first { $0.id == small })))))
        session.chooseTool(.align)
        XCTAssertEqual(session.alignDraft?.from?.kind, .line)
        XCTAssertEqual(session.alignDraft?.step, .to)
    }

    // MARK: Subtract

    func testSubtractRemovesTheToolFromTheTarget() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 20, to: 40)
        let target = session.workspace.bodies[0].id, tool = session.workspace.bodies[1].id
        session.select(.body(target))
        session.chooseTool(.subtract)
        XCTAssertEqual(session.subtractDraft?.targets, [target], "The selected solid is the target")
        XCTAssertEqual(session.subtractDraft?.step, .tools)
        controller.refresh()
        tap(controller, SIMD3(35, 0, 10))
        XCTAssertEqual(session.subtractDraft?.tools, [tool])
        XCTAssertNotNil(controller.previewNode.childNode(withName: "subtract.targets", recursively: false))
        XCTAssertNotNil(controller.previewNode.childNode(withName: "subtract.tools", recursively: false))
        let preview = try XCTUnwrap(session.subtractPreview)
        XCTAssertEqual(preview.bodies.map(\.id), [target], "The tool is used up")
        session.confirmSubtract()
        XCTAssertNil(session.subtractDraft)
        XCTAssertEqual(session.workspace.bodies.map(\.id), [target])
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .subtract)
        XCTAssertEqual(try volume(session), 48_000 - 10 * 20 * 10, accuracy: 1e-3)
        XCTAssertEqual(session.selection, .body(target))
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2, "One undo step")
    }

    func testSubtractKeepOriginalsChoices() throws {
        let (session, _) = boxScene()
        addTouchingBox(session, from: 20, to: 40)
        let target = session.workspace.bodies[0].id, tool = session.workspace.bodies[1].id
        session.select(nil)
        session.chooseTool(.subtract)
        session.selectItem(.body(target))
        session.chooseSubtractStep(.tools)
        session.selectItem(.body(tool))
        XCTAssertEqual(session.subtractPreview?.bodies.count, 1, "None")
        session.setSubtractKeep(.removed)
        XCTAssertEqual(session.subtractPreview?.bodies.map(\.id), [target, tool], "The tool stays")
        session.setSubtractKeep(.all)
        XCTAssertEqual(session.subtractPreview?.bodies.count, 3)
        session.setSubtractKeep(.modified)
        XCTAssertEqual(session.subtractPreview?.bodies.count, 2)
        session.confirmSubtract()
        XCTAssertEqual(session.workspace.bodies[0].id, target, "The target stays as it was")
        XCTAssertTrue(session.workspace.bodies[0].cuts.isEmpty)
        let result = session.workspace.bodies[1]
        XCTAssertEqual(session.selection, .body(result.id))
        XCTAssertEqual(try SolidKernel.solid(for: result).volume, 46_000, accuracy: 1e-3)
    }

    func testSubtractNamesAToolThatMisses() throws {
        let (session, controller) = boxScene()
        addTouchingBox(session, from: 40, to: 60)
        session.select(.body(session.workspace.bodies[0].id))
        session.chooseTool(.subtract)
        controller.refresh()
        tap(controller, SIMD3(50, 0, 10))
        XCTAssertNil(session.subtractPreview)
        XCTAssertTrue(session.hint.hasPrefix("Body 01 is not overlapped"), session.hint)
        session.cancelSubtract()
        XCTAssertEqual(session.workspace.bodies.count, 2)
    }

    // MARK: Shell

    func testShellOpenTopWithThicknessFromTheKeypad() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.shell)
        controller.refresh()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertEqual(session.shellDraft?.openFaces, [ExtrusionFace(position: .cap, index: 0)])
        XCTAssertNotNil(session.shellPreview)
        XCTAssertNotNil(controller.shellHandle())
        XCTAssertTrue(session.applyDimension(3, target: .shellThickness))
        // The opened top is gone from the preview, but tapping where it was closes it again.
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertEqual(session.shellDraft?.openFaces, [])
        XCTAssertNil(session.shellPreview, "At least one face must be open")
        XCTAssertNil(controller.shellHandle())
        session.confirmShell()
        XCTAssertTrue(session.workspace.bodies[0].cuts.isEmpty, "Done does nothing without an open face")
        tap(controller, SIMD3(5, 3, 20))
        session.confirmShell()
        XCTAssertEqual(session.workspace.bodies[0].cuts.last?.operation, .shell)
        XCTAssertEqual(try volume(session), 48_000 - 54 * 34 * 17, accuracy: 1e-3)
        XCTAssertEqual(session.tool, .select)
        session.select(nil)
        session.requestCamera(.reset)
        attach(controller, "Shelled tray")
    }

    func testShellThatDoesNotFitIsRefused() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.shell)
        controller.refresh()
        tap(controller, SIMD3(5, 3, 20))
        XCTAssertFalse(session.applyDimension(25, target: .shellThickness), "25 mm walls cannot fit a 40 mm wide box")
        XCTAssertNotNil(session.dimensionError)
        XCTAssertEqual(session.shellDraft?.thickness, 2)
    }

    // MARK: Holes

    func holeScene() throws -> (ModelingSession, CanvasController) {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(5, 3, 20))
        session.beginFaceSketch()
        session.chooseTool(.hole)
        controller.refresh()
        return (session, controller)
    }

    func testHolePresetsPlacedOnTheFaceCenter() throws {
        let (session, controller) = try holeScene()
        XCTAssertNotNil(session.sketchMode)
        tap(controller, SIMD3(0.3, -0.2, 20))
        let draft = try XCTUnwrap(session.holeDraft)
        XCTAssertEqual(draft.center, .zero, "Snapped to the face's center dot")
        XCTAssertEqual(draft.spec, HolePresets.spec(.simple, size: "M3"))
        XCTAssertNil(draft.depth, "Through by default")
        XCTAssertEqual(controller.dimensionAnnotations().map(\.target), [.holeDiameter])
        session.chooseHole(kind: .counterbore)
        session.chooseHole(size: "M4")
        XCTAssertEqual(session.holeDraft?.spec, HolePresets.spec(.counterbore, size: "M4"))
        attach(controller, "Counterbored M4 hole placed on the face center")
        session.confirmHole()
        XCTAssertNil(session.holeDraft)
        XCTAssertEqual(session.tool, .hole, "Ready for the next hole")
        let spec = HolePresets.spec(.counterbore, size: "M4")
        let removed = Double.pi * pow(spec.diameter / 2, 2) * (20 - spec.counterboreDepth) + .pi * pow(spec.counterboreDiameter / 2, 2) * spec.counterboreDepth
        XCTAssertEqual(try volume(session), 48_000 - removed, accuracy: 1e-3)
    }

    func testInsertHoleIsBlindAndEditable() throws {
        let (session, controller) = try holeScene()
        tap(controller, SIMD3(15.2, 9.8, 20))
        session.chooseHole(kind: .insert)
        XCTAssertEqual(session.holeDraft?.depth, 6.7)
        XCTAssertEqual(Set(controller.dimensionAnnotations().map(\.target)), [.holeDiameter, .holeDepth])
        XCTAssertTrue(session.applyDimension(4.2, target: .holeDiameter))
        XCTAssertTrue(session.applyDimension(8, target: .holeDepth))
        session.confirmHole()
        XCTAssertEqual(try volume(session), 48_000 - .pi * 2.1 * 2.1 * 8, accuracy: 1e-3)
    }

    func testHoleOffTheSolidCannotBeConfirmed() throws {
        let (session, controller) = try holeScene()
        tap(controller, SIMD3(45, 30, 20))
        XCTAssertNotNil(session.draftError)
        session.confirmHole()
        XCTAssertEqual(session.workspace.bodies[0].cuts, [])
    }

    // MARK: Dock groups

    /// Each group is named for what its tools do, every tool sits in a group whose name fits it, and
    /// nothing is in two groups of one dock except Peg & Socket, which is both a joint and a face feature.
    func testDockGroupsAreNamedForWhatTheirToolsDo() {
        let modeling: [ToolGroup] = [.planes, .create, .edges, .combine, .transform, .fit]
        let sketching: [ToolGroup] = [.curves, .faceFeatures, .modify]
        XCTAssertEqual(modeling.map(\.title), ["Planes", "Create", "Modify", "Combine", "Transform", "Joints"])
        XCTAssertEqual(sketching.map(\.title), ["Shapes", "Features", "Modify"])
        XCTAssertEqual(ToolGroup.combine.tools, [.union, .subtract, .intersect], "Combine is only the ways of putting solids together")
        XCTAssertEqual(ToolGroup.edges.tools, [.fillet, .chamfer, .shell, .draft, .deleteFace, .split], "Modify changes one solid")
        XCTAssertEqual(ToolGroup.fit.tools, [.peg, .thread, .fitTest])
        XCTAssertEqual(ToolGroup.curves.tools.first, .circle)
        for group in ToolGroup.allCases {
            XCTAssertFalse(group.tools.map(group.title(for:)).contains(group.title), "\(group.title) names its category, not one of its tools")
        }
        let modelingTools = modeling.flatMap(\.tools)
        XCTAssertEqual(Set(modelingTools).count, modelingTools.count, "no tool twice in the modeling dock")
        XCTAssertEqual(ToolGroup.edges.title(for: .split), "Split Body")
        XCTAssertEqual(ToolGroup.fit.title(for: .peg), "Peg & Socket")
    }
}
