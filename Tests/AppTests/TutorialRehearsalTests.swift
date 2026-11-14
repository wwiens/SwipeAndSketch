import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Written website projects through the canvas Pencil pipeline, real session previews,
/// native document saving and 3MF export. This does not exercise physical Pencil or a slicer.
@MainActor final class TutorialRehearsalTests: CanvasTestCase {
    private var oldUnit: Any?
    private var oldFit: Any?
    override func setUp() async throws {
        try await super.setUp()
        oldUnit = UserDefaults.standard.object(forKey: "lengthUnit")
        oldFit = UserDefaults.standard.object(forKey: "fitClearance")
    }
    override func tearDown() async throws {
        UserDefaults.standard.set(oldUnit, forKey: "lengthUnit")
        UserDefaults.standard.set(oldFit, forKey: "fitClearance")
        try await super.tearDown()
    }

    func newProject(_ name: String, workspace: Workspace = Workspace()) async throws -> (ModelingSession, CanvasController, ProjectDocument, URL) {
        let directory = URL.temporaryDirectory.appendingPathComponent("written-tutorial-" + UUID().uuidString)
        let url = directory.appendingPathComponent(name + ".swipesketch")
        var project = Project();project.workspace = workspace
        try ProjectCodec.create(project, at: url)
        let document = ProjectDocument(fileURL: url)
        let opened = await withCheckedContinuation { c in document.open { c.resume(returning: $0) } }
        XCTAssertTrue(opened)
        let session = ModelingSession(document: document)
        session.lengthUnit = .millimeters
        session.snapEnabled = true
        let controller = canvas(session)
        session.beginSketch(); session.pickPlane(.top); controller.refresh()
        return (session, controller, document, directory)
    }

    func stroke(_ controller: CanvasController, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let first = controller.project(a), last = controller.project(b)
        XCTAssertTrue(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(first))
        XCTAssertTrue(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(last))
        controller.pencilBegan(at: first)
        controller.pencilMoved(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        controller.pencilMoved(to: last)
        controller.pencilEnded(at: last, cancelled: false)
        controller.refresh()
    }

    @discardableResult
    func rectangle(_ session: ModelingSession, _ controller: CanvasController,
                   from a: SIMD3<Float>, to b: SIMD3<Float>, width: Double, height: Double) throws -> SketchShape {
        let count = session.workspace.shapes.count
        session.chooseTool(.rectangle); session.rectangleFromCenter = false; controller.refresh()
        stroke(controller, from: a, to: b)
        XCTAssertEqual(session.workspace.shapes.count, count + 1)
        let shape = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(shape.kind, .rectangle)
        session.chooseTool(.select)
        XCTAssertTrue(session.applyDimension(width, target: .shape(shape.id, .width)))
        XCTAssertTrue(session.applyDimension(height, target: .shape(shape.id, .height)))
        controller.refresh()
        return try XCTUnwrap(session.workspace.shapes.first { $0.id == shape.id })
    }

    func faceSketch(_ session: ModelingSession, _ controller: CanvasController, at p: SIMD3<Float>,
                    camera: ModelingSession.CameraAction = .align(.top)) throws {
        session.chooseTool(.select); session.select(nil); session.requestCamera(camera); controller.refresh()
        tap(controller, p)
        let face = try XCTUnwrap(session.selectedFace)
        XCTAssertEqual(try XCTUnwrap(face.plane).height(of: SIMD3<Double>(p)), 0, accuracy: 1e-5)
        session.beginFaceSketch(); controller.refresh()
        XCTAssertNotNil(session.sketchMode)
    }

    func edgeOffset(_ session: ModelingSession, _ controller: CanvasController,
                    fixed: SIMD3<Float>, moving: SIMD3<Float>, distance: Double) throws {
        session.chooseTool(.dimension); controller.refresh()
        tap(controller, fixed); tap(controller, moving)
        XCTAssertNotNil(session.dimensionDraft?.second)
        let index = try XCTUnwrap(session.sketchDimensions.firstIndex { $0.kind == .distance })
        XCTAssertTrue(session.applyDimension(distance, target: .relation(index, angle: false)))
        controller.refresh()
    }

    func extrude(_ session: ModelingSession, _ controller: CanvasController,
                 shape: SketchShape, depth: Double, mode: ExtrusionMode) throws {
        session.exitSketch(); controller.refresh()
        // Same closed region selected by its source ID; geometry input above used Pencil.
        session.select(.shape(shape.id))
        session.beginExtrusion(); session.chooseExtrusionMode(mode)
        XCTAssertTrue(session.applyDimension(depth, target: .extrusion))
        XCTAssertTrue(session.canConfirmExtrusion, session.status)
        session.confirmExtrusion(); controller.refresh()
        XCTAssertFalse(session.isExtruding)
    }

    func complete(_ session: ModelingSession, _ controller: CanvasController, document: ProjectDocument,
                  size: SIMD3<Double>, expectedVolume: Double, name: String,
                  additional: [(size: SIMD3<Double>, volume: Double)] = []) async throws {
        let expectedParts = [(size: size, volume: expectedVolume)] + additional
        XCTAssertEqual(session.workspace.bodies.count, expectedParts.count)
        for (body, part) in zip(session.workspace.bodies, expectedParts) {
            let solid = try SolidKernel.solid(for: body)
            XCTAssertTrue(solid.isValidSolid)
            XCTAssertEqual(solid.volume, part.volume, accuracy: 0.02)
            for axis in 0..<3 { XCTAssertEqual(solid.bounds.max[axis] - solid.bounds.min[axis], part.size[axis], accuracy: 1e-5) }
            session.select(.body(body.id)); session.beginMeasure(); controller.refresh()
            XCTAssertTrue(session.measurements.values.contains { abs($0.value - part.volume) < 0.02 })
            session.chooseTool(.select)
        }
        session.chooseTool(.select); session.select(nil); session.requestCamera(.reset); controller.refresh()
        attach(controller, name + " - completed native model")
        let saved = await withCheckedContinuation { c in session.save { c.resume(returning: $0) } }
        XCTAssertTrue(saved); XCTAssertNil(session.saveError)
        let expected = session.workspace
        let closed = await withCheckedContinuation { c in document.close { c.resume(returning: $0) } }
        XCTAssertTrue(closed)
        let reopened = ProjectDocument(fileURL: document.fileURL)
        let opened = await withCheckedContinuation { c in reopened.open { c.resume(returning: $0) } }
        XCTAssertTrue(opened)
        XCTAssertEqual(reopened.project.workspace, expected)
        let printSession = ModelingSession(document: reopened)
        XCTAssertEqual(printSession.printParts(.visible).count, expectedParts.count)
        printSession.printLayout = PrintLayout(placement: .arranged, bed: [256, 256])
        XCTAssertTrue(printSession.printFits(.visible))
        printSession.sendToPrinter(.visible, toFolder: false)
        for _ in 0..<500 where printSession.isProjectBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(printSession.isProjectBusy)
        let exported = try XCTUnwrap(printSession.exportItem?.url)
        XCTAssertEqual(exported.pathExtension, "3mf")
        let bytes = try Data(contentsOf: exported)
        XCTAssertEqual(bytes.prefix(2), Data("PK".utf8))
        for (data, type, filename) in [(try Data(contentsOf: document.fileURL), "public.data", name + ".swipesketch"),
                                        (bytes, "public.data", name + ".3mf")] {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
            attachment.name = filename; attachment.lifetime = .keepAlways; add(attachment)
        }
        let meshes = try ModelExport.meshes(reopened.project.workspace.bodies)
        XCTAssertEqual(meshes.count, expectedParts.count)
        for mesh in meshes {
            var edges: [UInt64: Int] = [:]
            for triangle in mesh.triangles {
                for (a, b) in [(triangle.x, triangle.y), (triangle.y, triangle.z), (triangle.z, triangle.x)] {
                    edges[UInt64(a) << 32 | UInt64(b), default: 0] += 1
                }
            }
            XCTAssertTrue(edges.allSatisfy { key, count in count == 1 && edges[(key & 0xFFFF_FFFF) << 32 | (key >> 32)] == 1 }, "Watertight outward-wound export mesh")
        }
        let reclosed = await withCheckedContinuation { c in reopened.close { c.resume(returning: $0) } }
        XCTAssertTrue(reclosed)
    }

    func testWrittenSmallPartsTrayBuildSaveReopenAndExport() async throws {
        let (s, c, document, directory) = try await newProject("Small-parts tray")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try rectangle(s, c, from: [0,0,0], to: [100,70,0], width: 100, height: 70)
        try extrude(s, c, shape: base, depth: 20, mode: .newBody)
        s.select(nil); s.requestCamera(.align(.top)); c.refresh(); tap(c, [20,20,20])
        XCTAssertNotNil(s.selectedFace)
        s.shellSelection()
        XCTAssertTrue(s.applyDimension(2, target: .shellThickness))
        XCTAssertNotNil(s.shellPreview); s.confirmShell(); c.refresh()
        XCTAssertEqual(try SolidKernel.solid(for: s.workspace.bodies[0]).volume, 25_952, accuracy: 0.001)
        attach(c, "Tray - open 2 mm shell")
        for (offset, pick, initial) in [(31.0, SIMD3<Float>(20,20,2), Float(10)), (63.0, SIMD3<Float>(50,20,2), Float(45))] {
            try faceSketch(s, c, at: pick)
            var divider = try rectangle(s, c, from: [initial,2,2], to: [initial+5,68,2], width: 2, height: 66)
            try edgeOffset(s, c, fixed: [2,30,2], moving: [initial,30,2], distance: offset)
            divider = try XCTUnwrap(s.workspace.shapes.first { $0.id == divider.id })
            let lowerX = divider.outline.map { divider.plane.point($0).x }.min()!
            XCTAssertEqual(lowerX, offset + 2, accuracy: 1e-5)
            try extrude(s, c, shape: divider, depth: 18, mode: .join)
            XCTAssertEqual(s.workspace.bodies.count, 1)
            attach(c, "Tray - divider offset \(Int(offset)) mm")
        }
        let solid = try SolidKernel.solid(for: s.workspace.bodies[0])
        for x in [15.0,47,82] { XCTAssertFalse(solid.contains([x,20,3])) }
        for x in [34.0,66] { XCTAssertTrue(solid.contains([x,20,3])) }
        XCTAssertTrue(solid.contains([20,20,1]))
        try await complete(s,c,document:document,size:[100,70,20],expectedVolume:30_704,name:"Small-parts tray")
    }

    func testWrittenCableOrganizerBuildSaveReopenAndExport() async throws {
        let (s, c, document, directory) = try await newProject("Desk cable organizer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try rectangle(s,c,from:[0,0,0],to:[70,25,0],width:70,height:25)
        try extrude(s,c,shape:base,depth:14,mode:.newBody)
        for (x, width, initial) in [(16.0,6.0,Float(10)),(28,8,Float(24)),(42,10,Float(39))] {
            try faceSketch(s,c,at:[5,5,14])
            var channel = try rectangle(s,c,from:[initial,0,14],to:[initial+5,25,14],width:width,height:25)
            // Snapping can move a rough stroke onto a nearby solid edge. Pick its actual
            // left edge, then enter the tutorial's exact offset.
            let left = Float(channel.outline.map { channel.plane.point($0).x }.min()!)
            try edgeOffset(s,c,fixed:[0,5,14],moving:[left,5,14],distance:x)
            channel = try XCTUnwrap(s.workspace.shapes.first { $0.id == channel.id })
            XCTAssertEqual(channel.outline.map { channel.plane.point($0).x }.min()!,x,accuracy:1e-5)
            try extrude(s,c,shape:channel,depth:-8,mode:.cut)
            // Model Tree eye: consumed profiles otherwise remain pickable, including their
            // kept dimension labels, on the next coplanar face sketch.
            s.toggleHidden(.sketch(try XCTUnwrap(channel.sketch))); c.refresh()
        }
        XCTAssertEqual(try SolidKernel.solid(for:s.workspace.bodies[0]).volume,19_700,accuracy:0.001)
        attach(c,"Cable organizer - three 8 mm cuts")
        try faceSketch(s,c,at:[5,5,14])
        var circles: [SketchShape] = []
        for x in [7.0,63] {
            s.chooseTool(.circle);s.select(nil);c.refresh()
            let count = s.workspace.shapes.count
            stroke(c,from:[Float(x),12.5,14],to:[Float(x+7),12.5,14])
            XCTAssertEqual(s.workspace.shapes.count, count + 1)
            let circle=try XCTUnwrap(s.workspace.shapes.last)
            XCTAssertEqual(circle.kind,.circle)
            s.chooseTool(.select)
            XCTAssertTrue(s.applyDimension(3.4,target:.shape(circle.id,.diameter)))
            s.chooseTool(.dimension);s.select(nil);c.refresh()
            tap(c,[0,0,14]);tap(c,SIMD3<Float>(circle.plane.point(circle.start)))
            XCTAssertTrue(s.applyDimension(x,target:.relation(0,angle:false)))
            XCTAssertTrue(s.applyDimension(12.5,target:.relation(1,angle:false)))
            let positioned = try XCTUnwrap(s.workspace.shapes.first { $0.id == circle.id })
            let center = positioned.plane.point(positioned.start)
            XCTAssertEqual(center.x,x,accuracy:1e-5);XCTAssertEqual(center.y,12.5,accuracy:1e-5)
            circles.append(positioned)
        }
        attach(c,"Cable organizer - two positioned reference circles")
        s.chooseTool(.hole);c.refresh()
        for circle in circles {
            tap(c,SIMD3<Float>(circle.plane.point(circle.start)))
            s.chooseHole(kind:.countersink,size:"M3")
            XCTAssertNil(s.holeDraft?.depth)
            XCTAssertEqual(s.holeDraft?.spec.diameter,3.4)
            attach(c,"Cable organizer - M3 countersink preview")
            s.confirmHole();c.refresh();XCTAssertNil(s.holeDraft)
        }
        s.chooseTool(.select);s.exitSketch();s.select(nil);s.requestCamera(.align(.top));c.refresh()
        s.chooseTool(.chamfer);c.refresh()
        for x: Float in [16,22,28,36,42,52] {
            // Tap a clear section of each edge, away from the live size label/handle.
            let p = try XCTUnwrap(stride(from: Float(0.5), through: 24.5, by: 1).map { SIMD3<Float>(x,$0,14) }.first { world in
                let screen = c.project(world)
                return c.finishHandle()?.hitArea.contains(screen) != true &&
                    c.dimensionAnnotations().allSatisfy { annotation in
                        guard let button = c.input.dimensionButton(for: annotation.target) else { return true }
                        return !button.bounds.insetBy(dx: -8, dy: -8).contains(button.convert(screen, from: c.input))
                    }
            })
            let before = s.finishDraft?.edges.count ?? 0
            tap(c,p)
            XCTAssertEqual(s.finishDraft?.edges.count,before+1)
        }
        XCTAssertEqual(s.finishDraft?.edges.count,6)
        XCTAssertTrue(s.applyDimension(0.5,target:.finishSize(.chamfer)))
        XCTAssertNotNil(s.finishPreview)
        attach(c,"Cable organizer - six 0.5 mm chamfer edges")
        s.confirmFinish();c.refresh()
        let solid=try SolidKernel.solid(for:s.workspace.bodies[0])
        for x in [19.0,32,47] { XCTAssertTrue(solid.contains([x,12.5,5]));XCTAssertFalse(solid.contains([x,12.5,7])) }
        for x in [7.0,63] { XCTAssertFalse(solid.contains([x,12.5,1])) }
        let radius=1.7,entry=3.2,depth=entry-radius
        let removed=Double.pi*(radius*radius*(14-depth)+depth*(entry*entry+entry*radius+radius*radius)/3)
        try await complete(s,c,document:document,size:[70,25,14],expectedVolume:19_700-2*removed-6*0.5*0.5/2*25,name:"Desk cable organizer")
    }

    func pointOffset(_ session: ModelingSession, _ controller: CanvasController,
                     fixed: SIMD3<Float>, moving: SIMD3<Float>, horizontal: Double? = nil, vertical: Double? = nil) throws {
        session.select(nil); session.chooseTool(.dimension); controller.refresh()
        tap(controller,fixed); tap(controller,moving)
        let second = try XCTUnwrap(session.dimensionDraft?.second)
        XCTAssertNotNil(second.shapeID, "The sketch point moves, not the fixed solid reference")
        for (kind,value) in [(SketchDimension.Kind.horizontal,horizontal),(.vertical,vertical)] {
            guard let value else { continue }
            let index = try XCTUnwrap(session.sketchDimensions.firstIndex { $0.kind == kind })
            XCTAssertTrue(session.applyDimension(value,target:.relation(index,angle:false)),session.dimensionError ?? session.status)
            controller.refresh()
        }
    }

    func testWrittenProjectBoxBuildSaveReopenAndExport() async throws {
        let (s,c,document,directory) = try await newProject("Screw-lid project box")
        defer { try? FileManager.default.removeItem(at:directory) }
        let base = try rectangle(s,c,from:[0,0,0],to:[80,55,0],width:80,height:55)
        try extrude(s,c,shape:base,depth:25,mode:.newBody)
        s.select(nil);s.requestCamera(.align(.top));c.refresh();tap(c,[40,27.5,25])
        XCTAssertNotNil(s.selectedFace);s.shellSelection()
        XCTAssertTrue(s.applyDimension(2.4,target:.shellThickness))
        XCTAssertNotNil(s.shellPreview);s.confirmShell();c.refresh()
        let shellVolume = 80.0*55*25 - 75.2*50.2*22.6
        XCTAssertEqual(try SolidKernel.solid(for:s.workspace.bodies[0]).volume,shellVolume,accuracy:0.001)
        // Corner indices: lower-left, lower-right, upper-left, upper-right.
        let bosses: [(SIMD3<Float>,SIMD3<Float>,Int,SIMD3<Float>)] = [
            ([7,7,2.4],[2.4,2.4,2.4],0,[8,8,25]),
            ([60,7,2.4],[77.6,2.4,2.4],1,[72,8,25]),
            ([7,35,2.4],[2.4,52.6,2.4],3,[8,47,25]),
            ([60,35,2.4],[77.6,52.6,2.4],2,[72,47,25])]
        for (rough,fixed,corner,center) in bosses {
            try faceSketch(s,c,at:[40,27.5,2.4])
            var boss = try rectangle(s,c,from:rough,to:rough+SIMD3(10,10,0),width:10,height:10)
            try pointOffset(s,c,fixed:fixed,moving:SIMD3<Float>(boss.plane.point(boss.outline[corner])),horizontal:0.6,vertical:0.6)
            boss = try XCTUnwrap(s.workspace.shapes.first { $0.id == boss.id })
            let actual = boss.plane.point(boss.center)
            XCTAssertEqual(actual.x,Double(center.x),accuracy:1e-5);XCTAssertEqual(actual.y,Double(center.y),accuracy:1e-5)
            try extrude(s,c,shape:boss,depth:22.6,mode:.join)
            s.toggleHidden(.sketch(try XCTUnwrap(boss.sketch)));c.refresh()
            XCTAssertEqual(s.workspace.bodies.count,1)
        }
        s.select(nil);s.requestCamera(.reset);c.refresh();attach(c,"Project box - four joined bosses")
        for (_,_,_,center) in bosses {
            try faceSketch(s,c,at:center)
            s.chooseTool(.hole);c.refresh();tap(c,center)
            s.chooseHole(kind:.insert,size:"M3");s.setHoleThrough(false)
            let draft = try XCTUnwrap(s.holeDraft)
            XCTAssertEqual(draft.spec.diameter,4);XCTAssertEqual(draft.depth,6.7)
            let world = draft.plane.point(draft.center)
            XCTAssertEqual(world.x,Double(center.x),accuracy:1e-5);XCTAssertEqual(world.y,Double(center.y),accuracy:1e-5)
            XCTAssertNotNil(s.holePreview)
            if center.x == 8 && center.y == 8 { attach(c,"Project box - M3 blind insert pocket preview") }
            s.confirmHole();c.refresh();XCTAssertNil(s.holeDraft)
            s.chooseTool(.select);s.exitSketch();s.select(nil);c.refresh()
        }
        let box = try SolidKernel.solid(for:s.workspace.bodies[0])
        for (_,_,_,center) in bosses {
            XCTAssertFalse(box.contains([Double(center.x),Double(center.y),24]))
            XCTAssertTrue(box.contains([Double(center.x),Double(center.y),18]))
        }
        s.beginSketch();s.pickPlane(.top);s.requestCamera(.alignAt(.top,[140,27.5,0]));c.refresh()
        let lid = try rectangle(s,c,from:[100,0,0],to:[180,55,0],width:80,height:55)
        try extrude(s,c,shape:lid,depth:3,mode:.newBody)
        XCTAssertEqual(s.workspace.bodies.count,2)
        try faceSketch(s,c,at:[140,27.5,3])
        var circles: [SketchShape] = []
        for local: SIMD2<Double> in [[8,8],[72,8],[8,47],[72,47]] {
            s.chooseTool(.circle);s.select(nil);c.refresh()
            let count = s.workspace.shapes.count
            stroke(c,from:[Float(100+local.x),Float(local.y),3],to:[Float(107+local.x),Float(local.y),3])
            XCTAssertEqual(s.workspace.shapes.count,count+1)
            let circle = try XCTUnwrap(s.workspace.shapes.last)
            XCTAssertEqual(circle.kind,.circle)
            s.chooseTool(.select);XCTAssertTrue(s.applyDimension(3.4,target:.shape(circle.id,.diameter)))
            try pointOffset(s,c,fixed:[100,0,3],moving:SIMD3<Float>(circle.plane.point(circle.start)),horizontal:local.x,vertical:local.y)
            let positioned = try XCTUnwrap(s.workspace.shapes.first { $0.id == circle.id })
            let actual = positioned.plane.point(positioned.start)
            XCTAssertEqual(actual.x,100+local.x,accuracy:1e-5);XCTAssertEqual(actual.y,local.y,accuracy:1e-5)
            circles.append(positioned)
        }
        s.chooseTool(.hole);c.refresh()
        for circle in circles {
            tap(c,SIMD3<Float>(circle.plane.point(circle.start)))
            s.chooseHole(kind:.simple,size:"M3");s.setHoleThrough(true)
            XCTAssertEqual(s.holeDraft?.spec.diameter,3.4);XCTAssertNil(s.holeDraft?.depth)
            XCTAssertNotNil(s.holePreview);s.confirmHole();c.refresh();XCTAssertNil(s.holeDraft)
        }
        s.chooseTool(.select);s.exitSketch();s.select(nil);c.refresh()
        try faceSketch(s,c,at:[40,0,12.5],camera:.alignAt(.front,[40,0,12.5]))
        XCTAssertEqual(s.plane.normalAxis.y,-1,accuracy:1e-5)
        s.chooseTool(.rectangle);s.rectangleFromCenter=true;c.refresh()
        let count = s.workspace.shapes.count
        stroke(c,from:[40,0,12.5],to:[48,0,17.5])
        XCTAssertEqual(s.workspace.shapes.count,count+1)
        let opening = try XCTUnwrap(s.workspace.shapes.last)
        XCTAssertEqual(opening.kind,.rectangle);XCTAssertTrue(opening.isCentered)
        s.chooseTool(.select)
        XCTAssertTrue(s.applyDimension(12,target:.shape(opening.id,.width)))
        XCTAssertTrue(s.applyDimension(6,target:.shape(opening.id,.height)))
        XCTAssertFalse(s.cutThroughAll)
        try extrude(s,c,shape:opening,depth:-3,mode:.cut)
        let result = try SolidKernel.solid(for:s.workspace.bodies[0])
        XCTAssertFalse(result.contains([40,1,12.5]));XCTAssertTrue(result.contains([40,54,12.5]))
        XCTAssertTrue(result.contains([40,1,8]));XCTAssertTrue(result.contains([40,27.5,1]))
        let lidSolid = try SolidKernel.solid(for:s.workspace.bodies[1])
        for local: SIMD2<Double> in [[8,8],[72,8],[8,47],[72,47]] { XCTAssertFalse(lidSolid.contains([100+local.x,local.y,1])) }
        let boxVolume = shellVolume + 4*100*22.6 - 4*Double.pi*4*6.7 - 12*6*2.4
        let lidVolume = 80.0*55*3 - 4*Double.pi*1.7*1.7*3
        try await complete(s,c,document:document,size:[80,55,25],expectedVolume:boxVolume,name:"Screw-lid project box",additional:[(size:[80,55,3],volume:lidVolume)])
    }


    func drawnLines(_ session: ModelingSession, _ controller: CanvasController,
                    points: [SIMD3<Float>]) throws -> [SketchShape] {
        let count = session.workspace.shapes.count
        session.chooseTool(.line);controller.refresh()
        for i in points.indices { stroke(controller,from:points[i],to:points[(i+1)%points.count]) }
        let lines = Array(session.workspace.shapes.dropFirst(count))
        XCTAssertEqual(lines.count,points.count);XCTAssertTrue(lines.allSatisfy { $0.kind == .line })
        return lines
    }

    func buildWrittenToolHolder(_ name: String, full: Bool) async throws -> (ModelingSession,CanvasController,ProjectDocument,URL) {
        let (s,c,document,directory) = try await newProject(name)
        let plateLength = full ? 80.0 : 10, railLength = full ? 60.0 : 10, receiverLength = full ? 40.0 : 10
        let plate = try rectangle(s,c,from:[0,0,0],to:[40,Float(plateLength),0],width:40,height:plateLength)
        try extrude(s,c,shape:plate,depth:4,mode:.newBody)
        try faceSketch(s,c,at:[20,0,2],camera:.alignAt(.front,[20,0,2]))
        var lines = try drawnLines(s,c,points:[[14,0,15],[30,0,15],[36,0,21],[8,0,21]])
        func world(_ index: Int, end: Bool = false) throws -> SIMD3<Float> {
            let line = try XCTUnwrap(s.workspace.shapes.first { $0.id == lines[index].id })
            return SIMD3<Float>(line.plane.point(end ? line.end : line.start))
        }
        try pointOffset(s,c,fixed:world(0),moving:world(0,end:true),horizontal:16)
        try pointOffset(s,c,fixed:world(1),moving:world(1,end:true),horizontal:4,vertical:4)
        try pointOffset(s,c,fixed:world(0),moving:world(3),horizontal:4,vertical:4)
        try pointOffset(s,c,fixed:[0,0,0],moving:world(0),horizontal:12,vertical:4)
        for (i,expected) in [SIMD3<Float>(12,0,4),[28,0,4],[32,0,8],[8,0,8]].enumerated() {
            let actual = try world(i)
            for axis in 0..<3 { XCTAssertEqual(actual[axis],expected[axis],accuracy:1e-5) }
        }
        lines = try lines.map { line in try XCTUnwrap(s.workspace.shapes.first { $0.id == line.id }) }
        try extrude(s,c,shape:lines[0],depth:-railLength,mode:.join)
        s.toggleHidden(.sketch(try XCTUnwrap(lines[0].sketch)));c.refresh()
        XCTAssertEqual(s.workspace.bodies.count,1)
        XCTAssertEqual(try SolidKernel.solid(for:s.workspace.bodies[0]).volume,40*plateLength*4+80*railLength,accuracy:0.001)
        if full {
            try faceSketch(s,c,at:[20,30,8])
            let stop = try rectangle(s,c,from:[8,0,8],to:[32,4,8],width:24,height:4)
            try extrude(s,c,shape:stop,depth:4,mode:.join)
            s.toggleHidden(.sketch(try XCTUnwrap(stop.sketch)));c.refresh()
            try faceSketch(s,c,at:[20,70,4])
            var circles: [SketchShape] = []
            for x in [8.0,32] {
                s.chooseTool(.circle);s.select(nil);c.refresh()
                let count = s.workspace.shapes.count
                stroke(c,from:[Float(x),70,4],to:[Float(x+7),70,4])
                XCTAssertEqual(s.workspace.shapes.count,count+1)
                let circle = try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(circle.kind,.circle)
                s.chooseTool(.select);XCTAssertTrue(s.applyDimension(3.4,target:.shape(circle.id,.diameter)))
                try pointOffset(s,c,fixed:[0,0,4],moving:SIMD3<Float>(circle.plane.point(circle.start)),horizontal:x,vertical:70)
                circles.append(try XCTUnwrap(s.workspace.shapes.first { $0.id == circle.id }))
            }
            s.chooseTool(.hole);c.refresh()
            for circle in circles {
                tap(c,SIMD3<Float>(circle.plane.point(circle.start)));s.chooseHole(kind:.simple,size:"M3");s.setHoleThrough(true)
                XCTAssertNotNil(s.holePreview);s.confirmHole();c.refresh();XCTAssertNil(s.holeDraft)
            }
            s.chooseTool(.select);s.exitSketch();s.select(nil);c.refresh()
        }
        s.beginSketch();s.pickPlane(.top);s.requestCamera(.alignAt(.top,[77,receiverLength/2,0]));c.refresh()
        let receiver = try rectangle(s,c,from:[60,0,0],to:[94,Float(receiverLength),0],width:34,height:receiverLength)
        try extrude(s,c,shape:receiver,depth:10,mode:.newBody)
        XCTAssertEqual(s.workspace.bodies.count,2)
        try faceSketch(s,c,at:[77,0,5],camera:.alignAt(.front,[77,0,5]))
        lines = try drawnLines(s,c,points:[[70,0,0],[88,0,0],[93,0,5],[65,0,5]])
        try pointOffset(s,c,fixed:world(0),moving:world(0,end:true),horizontal:17.2)
        try pointOffset(s,c,fixed:world(1),moving:world(1,end:true),horizontal:4.1,vertical:4.1)
        try pointOffset(s,c,fixed:world(0),moving:world(3),horizontal:4.1,vertical:4.1)
        try pointOffset(s,c,fixed:[60,0,0],moving:world(0),horizontal:8.4)
        for (i,expected) in [SIMD3<Float>(68.4,0,0),[85.6,0,0],[89.7,0,4.1],[64.3,0,4.1]].enumerated() {
            let actual = try world(i)
            for axis in 0..<3 { XCTAssertEqual(actual[axis],expected[axis],accuracy:1e-5) }
        }
        lines = try lines.map { line in try XCTUnwrap(s.workspace.shapes.first { $0.id == line.id }) }
        try extrude(s,c,shape:lines[0],depth:-receiverLength,mode:.cut)
        s.toggleHidden(.sketch(try XCTUnwrap(lines[0].sketch)));c.refresh()
        let grooveVolume = (17.2+25.4)/2*4.1*receiverLength
        XCTAssertEqual(try SolidKernel.solid(for:s.workspace.bodies[1]).volume,34*receiverLength*10-grooveVolume,accuracy:0.001)
        if full {
            try faceSketch(s,c,at:[77,20,10])
            let shelf = try rectangle(s,c,from:[60,0,10],to:[94,6,10],width:34,height:6)
            try extrude(s,c,shape:shelf,depth:18,mode:.join)
            s.toggleHidden(.sketch(try XCTUnwrap(shelf.sketch)));c.refresh()
            try faceSketch(s,c,at:[77,3,28])
            let lip = try rectangle(s,c,from:[60,0,28],to:[94,12,28],width:34,height:12)
            try extrude(s,c,shape:lip,depth:3,mode:.join)
        }
        return (s,c,document,directory)
    }

    func testWrittenToolHolderBuildSaveReopenExportAndAssembly() async throws {
        let (s,c,document,directory) = try await buildWrittenToolHolder("Slide-in tool holder",full:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let mountVolume = 17_984.0 - 2*Double.pi*1.7*1.7*4
        try await complete(s,c,document:document,size:[40,80,12],expectedVolume:mountVolume,name:"Slide-in tool holder",additional:[(size:[34,40,31],volume:15_002.8)])
        // Separate assembly-check document, preserving the saved, separated print project.
        var project = Project();project.workspace=s.workspace
        let url = directory.appendingPathComponent("Tool holder assembly check.swipesketch")
        try ProjectCodec.create(project,at:url)
        let assemblyDocument = ProjectDocument(fileURL:url)
        let opened = await withCheckedContinuation { continuation in assemblyDocument.open { continuation.resume(returning:$0) } }
        XCTAssertTrue(opened)
        let a = ModelingSession(document:assemblyDocument)
        for sketch in a.workspace.sketches where !a.workspace.isHidden(sketch) { a.toggleHidden(.sketch(sketch.id)) }
        let ac = canvas(a,camera:.reset), holderID=a.workspace.bodies[1].id
        a.select(.body(holderID));a.chooseTool(.align);ac.refresh()
        tap(ac,[60,0,0]);XCTAssertEqual(a.alignDraft?.from?.kind,.point)
        tap(ac,[0,0,0]);XCTAssertEqual(a.alignDraft?.to?.kind,.point)
        XCTAssertEqual(a.alignDraft?.bodies,[holderID]);XCTAssertNotNil(a.alignPreview)
        a.confirmAlign();ac.refresh();a.transformCopies=false
        for (axis,amount) in [(0,3.0),(1,4),(2,4.3)] {
            let widget = try XCTUnwrap(ac.transformWidget())
            let arrow = try XCTUnwrap(widget.arrows.first { $0.axis == axis })
            let start = CGPoint(x:(arrow.base.x+arrow.tip.x)/2,y:(arrow.base.y+arrow.tip.y)/2)
            let end = CGPoint(x:start.x+arrow.direction.dx*35,y:start.y+arrow.direction.dy*35)
            ac.pencilBegan(at:start);ac.pencilMoved(to:end);ac.pencilEnded(at:end,cancelled:false);ac.refresh()
            XCTAssertTrue(a.applyDimension(amount,target:.transformDistance));ac.refresh()
        }
        XCTAssertEqual(a.workspace.bodies.count,2)
        let mount = try SolidKernel.solid(for:a.workspace.bodies[0]), holder = try SolidKernel.solid(for:a.workspace.bodies[1])
        for axis in 0..<3 { XCTAssertEqual(holder.bounds.min[axis],SIMD3<Double>(3,4,4.3)[axis],accuracy:1e-5) }
        XCTAssertEqual(try SolidKernel.boolean(mount,holder,.intersect).volume,0,accuracy:1e-6)
        XCTAssertEqual(holder.bounds.min.z-4,0.3,accuracy:1e-5)
        XCTAssertEqual(holder.bounds.min.z+4.1-8,0.4,accuracy:1e-5)
        // Intersect the actual diagonal face planes with Y = 20, Z = 6.
        func flankXs(_ solid: KernelSolid) -> [Double] {
            (0..<solid.faceCount).compactMap { index -> Double? in
                guard let plane = solid.facePlane(index), abs(plane.normal.y)<1e-5,
                      abs(plane.normal.x)>0.6, abs(plane.normal.z)>0.6 else { return nil }
                return (simd_dot(plane.normal,plane.origin)-plane.normal.y*20-plane.normal.z*6)/plane.normal.x
            }.sorted()
        }
        let mountFlanks=flankXs(mount), holderFlanks=flankXs(holder)
        XCTAssertEqual(mountFlanks.count,2);XCTAssertEqual(holderFlanks.count,2)
        XCTAssertEqual(try XCTUnwrap(mountFlanks.first)-XCTUnwrap(holderFlanks.first),0.3,accuracy:1e-5)
        XCTAssertEqual(try XCTUnwrap(holderFlanks.last)-XCTUnwrap(mountFlanks.last),0.3,accuracy:1e-5)
        XCTAssertFalse(mount.contains([9.8,20,6]));XCTAssertFalse(holder.contains([9.8,20,6]))
        XCTAssertTrue(mount.contains([10.1,20,6]));XCTAssertTrue(holder.contains([9.6,20,6]))
        a.select(nil);a.requestCamera(.reset);ac.refresh();attach(ac,"Tool holder - seated assembly check")
        let saved = await withCheckedContinuation { continuation in a.save { continuation.resume(returning:$0) } }
        XCTAssertTrue(saved)
        let attachment = XCTAttachment(data:try Data(contentsOf:url),uniformTypeIdentifier:"public.data")
        attachment.name="Tool holder assembly check.swipesketch";attachment.lifetime = .keepAlways;add(attachment)
        let closed = await withCheckedContinuation { continuation in assemblyDocument.close { continuation.resume(returning:$0) } }
        XCTAssertTrue(closed)
        let check = ProjectDocument(fileURL:url)
        let reopened = await withCheckedContinuation { continuation in check.open { continuation.resume(returning:$0) } }
        XCTAssertTrue(reopened);XCTAssertEqual(check.project.workspace,a.workspace)
        let reclosed = await withCheckedContinuation { continuation in check.close { continuation.resume(returning:$0) } }
        XCTAssertTrue(reclosed)
        let original = ProjectDocument(fileURL:document.fileURL)
        let originalOpened = await withCheckedContinuation { continuation in original.open { continuation.resume(returning:$0) } }
        XCTAssertTrue(originalOpened);XCTAssertEqual(original.project.workspace,s.workspace,"Assembly check preserves the separated main project")
        let originalClosed = await withCheckedContinuation { continuation in original.close { continuation.resume(returning:$0) } }
        XCTAssertTrue(originalClosed)
    }

    func testWrittenToolHolderFitCouponBuildSaveReopenAndExport() async throws {
        let (s,c,document,directory) = try await buildWrittenToolHolder("Dovetail fit test",full:false)
        defer { try? FileManager.default.removeItem(at:directory) }
        try await complete(s,c,document:document,size:[40,10,8],expectedVolume:2400,name:"Dovetail fit test",additional:[(size:[34,10,10],volume:2526.7)])
    }

    func hideSketches(_ s: ModelingSession, _ c: CanvasController) {
        for sketch in s.workspace.sketches where !s.workspace.isHidden(sketch) { s.toggleHidden(.sketch(sketch.id)) }
        s.select(nil);c.refresh()
    }

    func faceCamera(_ point: SIMD3<Double>, normal: SIMD3<Double>) throws -> ModelingSession.CameraAction {
        .alignAt(try XCTUnwrap(SketchPlane.through(point,normal:normal)),point)
    }

    func circle(_ s: ModelingSession, _ c: CanvasController, center: SIMD3<Float>, diameter: Double) throws -> SketchShape {
        s.select(nil);s.chooseTool(.circle);c.refresh()
        let count=s.workspace.shapes.count
        stroke(c,from:center,to:center+SIMD3<Float>(s.plane.xAxis)*7)
        XCTAssertEqual(s.workspace.shapes.count,count+1)
        let shape=try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(shape.kind,.circle)
        s.chooseTool(.select);XCTAssertTrue(s.applyDimension(diameter,target:.shape(shape.id,.diameter)));c.refresh()
        return try XCTUnwrap(s.workspace.shapes.first { $0.id == shape.id })
    }

    func presetHole(_ s: ModelingSession, _ c: CanvasController, center: SIMD3<Float>, kind: HoleSpec.Kind, size: String, through: Bool) throws {
        s.chooseTool(.hole);c.refresh();tap(c,center)
        XCTAssertNotNil(s.holeDraft)
        s.chooseHole(kind:kind,size:size);s.setHoleThrough(through)
        XCTAssertNotNil(s.holePreview,s.status)
        s.confirmHole();c.refresh();XCTAssertNil(s.holeDraft)
        s.chooseTool(.select);s.exitSketch();s.select(nil);c.refresh()
    }

    @discardableResult
    func moveBody(_ s: ModelingSession, _ c: CanvasController, id: UUID, axis: Int, amount: Double, copy: Bool = false) throws -> UUID {
        s.chooseTool(.select);s.select(.body(id));s.transformCopies=copy;s.requestCamera(.home);c.refresh();s.requestCamera(.reset);c.refresh()
        let arrow=try XCTUnwrap(c.transformWidget()?.arrows.first { $0.axis == axis })
        let start=try XCTUnwrap(stride(from:0.0,through:1.0,by:0.1).map { t in
            CGPoint(x:arrow.base.x+(arrow.tip.x-arrow.base.x)*t,y:arrow.base.y+(arrow.tip.y-arrow.base.y)*t)
        }.first { screen in c.dimensionAnnotations().allSatisfy { annotation in
            guard let button=c.input.dimensionButton(for:annotation.target) else { return true }
            return !button.bounds.insetBy(dx:-8,dy:-8).contains(button.convert(screen,from:c.input))
        } })
        let end=CGPoint(x:start.x+arrow.direction.dx*35,y:start.y+arrow.direction.dy*35)
        c.pencilBegan(at:start);c.pencilMoved(to:end)
        XCTAssertNotNil(s.transformDrag,"Move drag axis \(axis), amount \(amount)")
        c.pencilEnded(at:end,cancelled:false);c.refresh()
        XCTAssertTrue(s.applyDimension(amount,target:.transformDistance),"Move axis \(axis), amount \(amount), copy \(copy): \(s.status)");c.refresh();s.transformCopies=false
        guard case .body(let selected) = s.selection else { throw NSError(domain:"TutorialRehearsal",code:1) }
        return selected
    }

    func revolve(_ s: ModelingSession, _ c: CanvasController, shape: SketchShape) throws {
        s.exitSketch();s.select(.shape(shape.id));s.beginRevolve();c.refresh()
        tap(c,[0,0,-10]);XCTAssertNotNil(s.revolveDraft?.axis,s.revolveError ?? s.status)
        XCTAssertTrue(s.applyDimension(360,target:.revolveAngle));s.chooseRevolveMode(.newBody)
        XCTAssertTrue(s.canConfirmRevolve,s.revolveError ?? s.status)
        s.confirmRevolve();c.refresh();XCTAssertNil(s.revolveDraft)
    }

    func testWrittenPhoneStandBuildSaveReopenAndExport() async throws {
        let (s,c,document,directory)=try await newProject("Adjustable phone stand")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.requestCamera(.alignAt(.top,[45,45,0]));c.refresh()
        let base=try rectangle(s,c,from:[0,0,0],to:[90,90,0],width:90,height:90)
        try extrude(s,c,shape:base,depth:6,mode:.newBody);hideSketches(s,c)
        let baseID=s.workspace.bodies[0].id
        try faceSketch(s,c,at:[40,40,6])
        var ear=try rectangle(s,c,from:[8,35,6],to:[18,55,6],width:10,height:20)
        try pointOffset(s,c,fixed:[0,0,6],moving:SIMD3<Float>(ear.plane.point(ear.outline[0])),horizontal:8,vertical:35)
        ear=try XCTUnwrap(s.workspace.shapes.first { $0.id == ear.id })
        try extrude(s,c,shape:ear,depth:50,mode:.newBody);hideSketches(s,c)
        let earID=s.workspace.bodies[1].id
        try faceSketch(s,c,at:[8,45,30],camera:faceCamera([8,45,30],normal:[-1,0,0]))
        let bore=try circle(s,c,center:[8,45,41],diameter:4.5)
        try pointOffset(s,c,fixed:[8,35,6],moving:SIMD3<Float>(bore.plane.point(bore.start)),horizontal:10,vertical:35)
        try presetHole(s,c,center:[8,45,41],kind:.simple,size:"M4",through:true);hideSketches(s,c)
        s.chooseTool(.midplane);s.requestCamera(try faceCamera([0,45,3],normal:[-1,0,0]));c.refresh();tap(c,[0,45,3])
        s.requestCamera(try faceCamera([90,45,3],normal:[1,0,0]));c.refresh();tap(c,[90,45,3])
        XCTAssertEqual(s.planePreview?.plane.origin.x ?? 0,45,accuracy:1e-5)
        s.confirmPlane();c.refresh()
        let midplane=try XCTUnwrap(s.workspace.constructionPlanes.last)
        s.select(.body(earID));s.chooseTool(.mirror);s.selectItem(.plane(midplane.id));s.setMirrorKeepOriginals(true)
        XCTAssertNotNil(s.mirrorPreview);s.confirmMirror();c.refresh();XCTAssertEqual(s.workspace.bodies.count,3)
        let reflected=try XCTUnwrap(s.workspace.bodies.last)
        XCTAssertEqual(try SolidKernel.solid(for:reflected).bounds.min.x,72,accuracy:1e-5)
        s.select(nil);s.chooseTool(.union)
        s.selectItem(.body(earID));s.selectItem(.body(reflected.id));s.selectItem(.body(baseID));s.setUnionKeepOriginals(false)
        XCTAssertEqual(s.unionDraft?.target,baseID);XCTAssertNotNil(s.unionPreview)
        s.confirmUnion();c.refresh();XCTAssertEqual(s.workspace.bodies.count,1)
        s.toggleHidden(.plane(midplane.id));s.select(nil);s.requestCamera(.reset);c.refresh()
        attach(c,"Phone stand - mirrored and united bored ears")
        s.beginSketch();s.pickPlane(.front);s.requestCamera(.alignAt(.front,[165,0,60]));c.refresh()
        let back=try rectangle(s,c,from:[120,0,0],to:[210,0,120],width:90,height:120)
        try extrude(s,c,shape:back,depth:-6,mode:.newBody);hideSketches(s,c)
        try faceSketch(s,c,at:[165,6,60],camera:faceCamera([165,6,60],normal:[0,1,0]))
        // The back face's horizontal axis is -X: start at the high-X corner.
        var boss=try rectangle(s,c,from:[191.6,6,11],to:[138.4,6,35],width:53.2,height:24)
        try pointOffset(s,c,fixed:[210,6,0],moving:SIMD3<Float>(boss.plane.point(boss.outline[0])),horizontal:18.4,vertical:11)
        boss=try XCTUnwrap(s.workspace.shapes.first { $0.id == boss.id })
        try extrude(s,c,shape:boss,depth:38,mode:.join);hideSketches(s,c)
        try faceSketch(s,c,at:[138.4,25,23],camera:faceCamera([138.4,25,23],normal:[-1,0,0]))
        let pivot=try circle(s,c,center:[138.4,25,23],diameter:4.5)
        try pointOffset(s,c,fixed:[138.4,6,11],moving:SIMD3<Float>(pivot.plane.point(pivot.start)),horizontal:19,vertical:12)
        try presetHole(s,c,center:[138.4,25,23],kind:.simple,size:"M4",through:true);hideSketches(s,c)
        try faceSketch(s,c,at:[165,0,50],camera:.alignAt(.front,[165,0,50]))
        let ledge=try rectangle(s,c,from:[120,0,0],to:[210,0,6],width:90,height:6)
        try extrude(s,c,shape:ledge,depth:12,mode:.join);hideSketches(s,c)
        try faceSketch(s,c,at:[165,-12,3],camera:.alignAt(.front,[165,-12,3]))
        let lip=try rectangle(s,c,from:[120,-12,0],to:[210,-12,12],width:90,height:12)
        try extrude(s,c,shape:lip,depth:3,mode:.join);hideSketches(s,c)
        s.select(nil);s.requestCamera(.reset);c.refresh();attach(c,"Phone stand - separate base and pivot cradle")
        for body in s.workspace.bodies { s.toggleHidden(.body(body.id)) }
        s.beginSketch();s.pickPlane(.front);s.requestCamera(.alignAt(.front,[8,0,10]));c.refresh()
        let outline=try drawnLines(s,c,points:[[0,0,0],[16,0,0],[16,0,8],[10,0,8],[10,0,20],[0,0,20]])
        try revolve(s,c,shape:outline[0]);hideSketches(s,c)
        let knobID=try XCTUnwrap(s.workspace.bodies.last).id
        try moveBody(s,c,id:knobID,axis:0,amount:260)
        try faceSketch(s,c,at:[260,0,20],camera:.alignAt(.top,[260,0,20]))
        try presetHole(s,c,center:[260,0,20],kind:.insert,size:"M4",through:false)
        hideSketches(s,c)
        for body in s.workspace.bodies where !s.workspace.isShown(body:body.id) { s.toggleHidden(.body(body.id)) }
        let baseSolid=try SolidKernel.solid(for:s.workspace.bodies[0]),cradle=try SolidKernel.solid(for:s.workspace.bodies[1]),knob=try SolidKernel.solid(for:s.workspace.bodies[2])
        for x in [12.0,77] { XCTAssertFalse(baseSolid.contains([x,45,41]));XCTAssertTrue(baseSolid.contains([x,45,35])) }
        XCTAssertFalse(cradle.contains([165,25,23]));XCTAssertTrue(cradle.contains([165,3,23]))
        XCTAssertFalse(knob.contains([260,0,19]));XCTAssertTrue(knob.contains([260,0,10]))
        let baseVolume=90.0*90*6+2*(10*20*50-Double.pi*2.25*2.25*10)
        let cradleVolume=90.0*6*120+53.2*38*24-Double.pi*2.25*2.25*53.2+90*12*6+90*3*12
        let knobVolume=Double.pi*(16*16*8+10*10*12)-Double.pi*2.8*2.8*9.1
        try await complete(s,c,document:document,size:[90,90,56],expectedVolume:baseVolume,name:"Adjustable phone stand",additional:[(size:[90,59,120],volume:cradleVolume),(size:[32,32,20],volume:knobVolume)])
        try await phoneAssembly(s,document:document,directory:directory)
    }

    func extrudePickedRegion(_ s: ModelingSession, _ c: CanvasController, at point: SIMD3<Float>, depth: Double, mode: ExtrusionMode) throws {
        s.chooseTool(.select);s.select(nil);c.refresh()
        // Same region-selection boundary as the source-ID extrusion helper. Narrow annuli
        // need zooming for reliable Pencil region picks; choose their actual native region ID.
        let profile=try XCTUnwrap(s.profiles.first { $0.holes?.count == 1 && $0.contains($0.plane.coordinates(of:SIMD3<Double>(point))) })
        s.select(.profile(profile.id))
        XCTAssertEqual(s.selectedProfile?.holes?.count,1,"Select the annulus, preserving its center bore")
        s.exitSketch();s.select(.profile(profile.id));s.beginExtrusion();s.chooseExtrusionMode(mode)
        XCTAssertTrue(s.applyDimension(depth,target:.extrusion));XCTAssertTrue(s.canConfirmExtrusion,s.status)
        s.confirmExtrusion();c.refresh();XCTAssertFalse(s.isExtruding)
    }

    func bearingSeat(_ s: ModelingSession, _ c: CanvasController, center: SIMD3<Float>, normal: SIMD3<Double>) throws {
        let outer=center+SIMD3<Float>(11,0,0)
        try faceSketch(s,c,at:outer,camera:faceCamera(SIMD3<Double>(center),normal:normal))
        let profile=try circle(s,c,center:center,diameter:22.2)
        // A face's existing bore is a reference, not a drawn inner loop. Select the
        // whole circle; the bounded Cut preserves the material already missing there.
        XCTAssertNil(s.profile(for:.shape(profile.id))?.holes)
        try extrude(s,c,shape:profile,depth:-7.2,mode:.cut)
        hideSketches(s,c)
    }

    func hollowRoller(_ s: ModelingSession, _ c: CanvasController, height: Double, x: Double, y: Double, bothSeats: Bool) throws -> UUID {
        s.beginSketch();s.pickPlane(.front);s.requestCamera(.alignAt(.front,[7.5,0,height/2]));c.refresh()
        var profile=try rectangle(s,c,from:[7,0,0],to:[15,0,Float(height)],width:8,height:height)
        try pointOffset(s,c,fixed:[0,0,0],moving:SIMD3<Float>(profile.plane.point(profile.outline[0])),horizontal:7)
        profile=try XCTUnwrap(s.workspace.shapes.first { $0.id == profile.id })
        try revolve(s,c,shape:profile);hideSketches(s,c)
        let id=try XCTUnwrap(s.workspace.bodies.last).id
        if x != 0 { try moveBody(s,c,id:id,axis:0,amount:x) }
        if y != 0 { try moveBody(s,c,id:id,axis:2,amount:-y) }
        try bearingSeat(s,c,center:[Float(x),Float(y),Float(height)],normal:[0,0,1])
        if bothSeats { try bearingSeat(s,c,center:[Float(x),Float(y),0],normal:[0,0,-1]) }
        return id
    }

    func annularSpacer(_ s: ModelingSession, _ c: CanvasController, x: Float, y: Float, height: Double) throws -> UUID {
        s.beginSketch();s.pickPlane(.top);s.requestCamera(.alignAt(.top,[Double(x),Double(y),0]));c.refresh()
        _=try circle(s,c,center:[x,y,0],diameter:11.5)
        _=try circle(s,c,center:[x,y,0],diameter:8.6)
        try extrudePickedRegion(s,c,at:[x+5,y,0],depth:height,mode:.newBody);hideSketches(s,c)
        return try XCTUnwrap(s.workspace.bodies.last).id
    }

    func testWrittenSpoolRollerBuildSaveReopenAndExport() async throws {
        let (s,c,document,directory)=try await newProject("Filament spool roller")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.requestCamera(.alignAt(.top,[60,20,0]));c.refresh()
        let rail=try rectangle(s,c,from:[0,0,0],to:[120,40,0],width:120,height:40)
        try extrude(s,c,shape:rail,depth:6,mode:.newBody);hideSketches(s,c)
        for x: Float in [30,90] {
            try faceSketch(s,c,at:[60,20,6])
            let bore=try circle(s,c,center:[x,25,6],diameter:8.6)
            try pointOffset(s,c,fixed:[0,0,6],moving:SIMD3<Float>(bore.plane.point(bore.start)),horizontal:Double(x),vertical:25)
            let positioned=try XCTUnwrap(s.workspace.shapes.first { $0.id == bore.id })
            try extrude(s,c,shape:positioned,depth:-6,mode:.cut);hideSketches(s,c)
        }
        for x: Float in [6,114] {
            try faceSketch(s,c,at:[60,20,6])
            let guide=try circle(s,c,center:[x,4,6],diameter:3.4)
            try pointOffset(s,c,fixed:[0,0,6],moving:SIMD3<Float>(guide.plane.point(guide.start)),horizontal:Double(x),vertical:4)
            try presetHole(s,c,center:[x,4,6],kind:.simple,size:"M3",through:true);hideSketches(s,c)
        }
        let railID=s.workspace.bodies[0].id
        try moveBody(s,c,id:railID,axis:1,amount:55,copy:true)
        s.select(nil);s.requestCamera(.reset);c.refresh();attach(c,"Spool roller - matching drilled rails")
        s.beginSketch();s.pickPlane(.top);s.requestCamera(.alignAt(.top,[54,121,0]));c.refresh()
        let bar=try rectangle(s,c,from:[0,115,0],to:[108,127,0],width:108,height:12)
        try extrude(s,c,shape:bar,depth:8,mode:.newBody);hideSketches(s,c)
        for (x,normal): (Float,SIMD3<Double>) in [(0,[-1,0,0]),(108,[1,0,0])] {
            try faceSketch(s,c,at:[x,121,4],camera:faceCamera([Double(x),121,4],normal:normal))
            try presetHole(s,c,center:[x,121,4],kind:.insert,size:"M3",through:false);hideSketches(s,c)
        }
        let barID=s.workspace.bodies[2].id
        s.requestCamera(.alignAt(.top,[54,121,0]));c.refresh()
        try moveBody(s,c,id:barID,axis:1,amount:25,copy:true)
        for body in s.workspace.bodies { s.toggleHidden(.body(body.id)) }
        let rollerID=try hollowRoller(s,c,height:100,x:160,y:20,bothSeats:true)
        let roller=try SolidKernel.solid(for:s.workspace.bodies[4])
        XCTAssertFalse(roller.contains([160,20,50]));XCTAssertTrue(roller.contains([170,20,50]))
        for z in [1.0,99] { XCTAssertFalse(roller.contains([170,20,z]));XCTAssertTrue(roller.contains([173,20,z])) }
        for z in [7.3,92.7] { XCTAssertTrue(roller.contains([170,20,z])) }
        s.select(nil);s.requestCamera(.reset);c.refresh();attach(c,"Spool roller - opposed bearing seats")
        s.toggleHidden(.body(rollerID))
        let sleeveID=try annularSpacer(s,c,x:220,y:20,height:85.6)
        s.toggleHidden(.body(sleeveID))
        let spacerID=try annularSpacer(s,c,x:245,y:20,height:4.2)
        // Show only the part being copied, keeping source sketches hidden.
        s.toggleHidden(.body(rollerID));s.requestCamera(.home);c.refresh()
        try moveBody(s,c,id:rollerID,axis:2,amount:-45,copy:true)
        s.toggleHidden(.body(sleeveID))
        try moveBody(s,c,id:sleeveID,axis:1,amount:25,copy:true)
        for offset in [20.0,40,60] { try moveBody(s,c,id:spacerID,axis:1,amount:offset,copy:true) }
        for body in s.workspace.bodies where !s.workspace.isShown(body:body.id) { s.toggleHidden(.body(body.id)) }
        XCTAssertEqual(s.workspace.bodies.count,12)
        let boxes=try s.workspace.bodies.map { try SolidKernel.solid(for:$0).bounds }
        for i in boxes.indices {
            for j in boxes.indices where j>i {
                XCTAssertTrue((0..<3).contains { boxes[i].max[$0] <= boxes[j].min[$0] || boxes[j].max[$0] <= boxes[i].min[$0] },"Separated print-layout bounds")
            }
        }
        let railVolume=120.0*40*6-2*Double.pi*(4.3*4.3+1.7*1.7)*6
        let barVolume=108.0*12*8-2*Double.pi*4*6.7
        let rollerVolume=Double.pi*(15*15-7*7)*100-2*Double.pi*(11.1*11.1-7*7)*7.2
        let ringArea=Double.pi*(5.75*5.75-4.3*4.3)
        let railPart=(size:SIMD3<Double>(120,40,6),volume:railVolume)
        let barPart=(size:SIMD3<Double>(108,12,8),volume:barVolume)
        let rollerPart=(size:SIMD3<Double>(30,30,100),volume:rollerVolume)
        let sleevePart=(size:SIMD3<Double>(11.5,11.5,85.6),volume:ringArea*85.6)
        let spacerPart=(size:SIMD3<Double>(11.5,11.5,4.2),volume:ringArea*4.2)
        XCTAssertEqual(4.2+7+85.6+7+4.2,108,accuracy:1e-8)
        try await complete(s,c,document:document,size:railPart.size,expectedVolume:railPart.volume,name:"Filament spool roller",additional:[railPart,barPart,barPart,rollerPart,rollerPart,sleevePart,sleevePart,spacerPart,spacerPart,spacerPart,spacerPart])
    }

    func testWrittenSpoolBearingCouponBuildSaveReopenAndExport() async throws {
        let (s,c,document,directory)=try await newProject("Spool roller fit tests")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.exitSketch()
        _=try hollowRoller(s,c,height:14,x:0,y:0,bothSeats:false)
        let volume=Double.pi*(15*15-7*7)*14-Double.pi*(11.1*11.1-7*7)*7.2
        try await complete(s,c,document:document,size:[30,30,14],expectedVolume:volume,name:"Spool roller bearing coupon")
    }

    func phoneAssembly(_ source: ModelingSession, document: ProjectDocument, directory: URL) async throws {
        var project=Project();project.workspace=source.workspace
        let url=directory.appendingPathComponent("Phone stand assembly check.swipesketch")
        try ProjectCodec.create(project,at:url)
        let d=ProjectDocument(fileURL:url)
        let opened=await withCheckedContinuation { c in d.open { c.resume(returning:$0) } };XCTAssertTrue(opened)
        let a=ModelingSession(document:d)
        let c=canvas(a,camera:.reset),cradleID=a.workspace.bodies[1].id,knobID=a.workspace.bodies[2].id
        a.toggleHidden(.body(knobID));hideSketches(a,c)
        a.requestCamera(try faceCamera([138.4,25,23],normal:[-1,0,0]));a.select(.body(cradleID));a.chooseTool(.align);c.refresh()
        tap(c,[138.4,25,25.25]);XCTAssertEqual(a.alignDraft?.from?.kind,.circle)
        let from=try XCTUnwrap(a.alignDraft?.from)
        XCTAssertLessThan(simd_distance(from.point,[138.4,25,23]),1e-5)
        a.requestCamera(.home);c.refresh();a.requestCamera(.reset);c.refresh()
        tap(c,[18,45,43.25]);XCTAssertEqual(a.alignDraft?.to?.kind,.circle)
        let to=try XCTUnwrap(a.alignDraft?.to)
        XCTAssertLessThan(simd_distance(to.point,[18,45,41]),1e-5)
        a.setAlignOffset(to.direction.x*0.4);XCTAssertNotNil(a.alignPreview)
        a.confirmAlign();c.refresh();a.transformCopies=false
        let base=try SolidKernel.solid(for:a.workspace.bodies[0])
        var cradle=try SolidKernel.solid(for:a.workspace.bodies[1])
        for axis in 0..<3 { XCTAssertEqual(cradle.bounds.min[axis],SIMD3<Double>(0,5,18)[axis],accuracy:1e-5) }
        XCTAssertEqual(try SolidKernel.boolean(base,cradle,.intersect).volume,0,accuracy:1e-6)
        a.select(nil);a.requestCamera(.reset);c.refresh();attach(c,"Phone stand - concentric upright assembly")
        a.select(.body(cradleID));a.requestCamera(.alignAt(.right,[71.6,45,41]));c.refresh()
        let widget=try XCTUnwrap(c.transformWidget()),target=c.project(SIMD3<Float>(71.6,45,41))
        // Looking down the bore exposes its center; the selected cradle's snaps win ties.
        c.pencilBegan(at:widget.center);c.pencilMoved(to:target);c.pencilEnded(at:target,cancelled:false);c.refresh()
        let pivot=try XCTUnwrap(a.transformPivot)
        XCTAssertEqual(pivot.kind,.circleCenter)
        XCTAssertEqual(pivot.center.y,45,accuracy:1e-5);XCTAssertEqual(pivot.center.z,41,accuracy:1e-5)
        XCTAssertTrue([18.4,71.6].contains { abs($0-pivot.center.x)<1e-5 })
        let hingeAxis=try XCTUnwrap(pivot.axes.firstIndex { abs($0.x)>0.99999 })
        for (increment,label) in [(15.0,"15"),(10.0,"25")] {
            let arc=try XCTUnwrap(c.transformWidget()?.arcs.first { $0.axis == hingeAxis })
            c.pencilBegan(at:arc.points[6]);c.pencilMoved(to:arc.points[12]);c.pencilEnded(at:arc.points[12],cancelled:false);c.refresh()
            XCTAssertTrue(a.applyDimension(-increment*pivot.axes[hingeAxis].x,target:.transformAngle));c.refresh()
            cradle=try SolidKernel.solid(for:a.workspace.bodies[1])
            let tilt=Double(try XCTUnwrap(Double(label)))*Double.pi/180
            let tiltedPlatePoint=SIMD3<Double>(45,45-22*cos(tilt)+89*sin(tilt),41+22*sin(tilt)+89*cos(tilt))
            XCTAssertTrue(cradle.contains(tiltedPlatePoint),"Top tilts toward +Y about the fixed bore axis")
            XCTAssertEqual(try SolidKernel.boolean(base,cradle,.intersect).volume,0,accuracy:1e-6,"Static geometry clearance at " + label + " degrees")
            attach(c,"Phone stand - " + label + " degree static tilt check")
        }
        let saved=await withCheckedContinuation { c in a.save { c.resume(returning:$0) } };XCTAssertTrue(saved)
        let attachment=XCTAttachment(data:try Data(contentsOf:url),uniformTypeIdentifier:"public.data")
        attachment.name="Phone stand assembly check.swipesketch";attachment.lifetime = .keepAlways;add(attachment)
        let closed=await withCheckedContinuation { c in d.close { c.resume(returning:$0) } };XCTAssertTrue(closed)
        let check=ProjectDocument(fileURL:url)
        let reopened=await withCheckedContinuation { c in check.open { c.resume(returning:$0) } };XCTAssertTrue(reopened);XCTAssertEqual(check.project.workspace,a.workspace)
        let reclosed=await withCheckedContinuation { c in check.close { c.resume(returning:$0) } };XCTAssertTrue(reclosed)
        let original=ProjectDocument(fileURL:document.fileURL)
        let originalOpened=await withCheckedContinuation { c in original.open { c.resume(returning:$0) } };XCTAssertTrue(originalOpened);XCTAssertEqual(original.project.workspace,source.workspace)
        let originalClosed=await withCheckedContinuation { c in original.close { c.resume(returning:$0) } };XCTAssertTrue(originalClosed)
    }

    func savedSnapshot(_ s: ModelingSession, document: ProjectDocument, name: String) async throws {
        let saved=await withCheckedContinuation { c in s.save { c.resume(returning:$0) } };XCTAssertTrue(saved)
        let a=XCTAttachment(data:try Data(contentsOf:document.fileURL),uniformTypeIdentifier:"public.data")
        a.name=name+".swipesketch";a.lifetime = .keepAlways;add(a)
    }

    func cardSection(_ s: ModelingSession, _ c: CanvasController, offset: Double, name: String) {
        let before=s.workspace
        s.chooseTool(.select);s.select(nil);s.toggleSection();s.setSectionOrientation(.front);s.setSectionOffset(offset)
        s.requestCamera(.home);c.refresh()
        XCTAssertNotNil(s.section)
        XCTAssertNotNil(c.content.childNode(withName:"section.cap",recursively:true))
        attach(c,name);s.endSection();c.refresh();XCTAssertEqual(s.workspace,before)
    }

    func testRecordingCardE01ThreadedPotAndMatchingCap() async throws {
        let (s,c,d,directory)=try await newProject("E01 Storage Pot")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.setFitClearance(0.2)
        let disk=try circle(s,c,center:[0,0,0],diameter:40)
        try extrude(s,c,shape:disk,depth:24,mode:.newBody);hideSketches(s,c)
        s.requestCamera(.align(.top));c.refresh();tap(c,[0,0,24]);XCTAssertNotNil(s.selectedFace)
        s.shellSelection();XCTAssertTrue(s.applyDimension(5,target:.shellThickness));XCTAssertNotNil(s.shellPreview)
        s.confirmShell();c.refresh()
        let unthreaded=try SolidKernel.solid(for:s.workspace.bodies[0])
        XCTAssertEqual(unthreaded.volume,Double.pi*(400*24-225*19),accuracy:0.001)
        XCTAssertTrue(unthreaded.contains([0,0,4]));XCTAssertFalse(unthreaded.contains([0,0,6]))
        try await savedSnapshot(s,document:d,name:"E01 Pot Unthreaded")
        s.select(nil);s.requestCamera(.home);c.refresh();s.chooseTool(.thread);c.refresh();tap(c,[0,-20,18])
        XCTAssertNotNil(s.threadDraft)
        s.chooseThreadSize("");XCTAssertTrue(s.applyDimension(40,target:.threadDiameter));s.chooseThreadPitch(3)
        s.setThreadLength(12);s.setThreadClearance(0.2);s.setThreadLeftHanded(false);s.setThreadStarts(1);s.setThreadLeadIn(true);s.setThreadRaised(false)
        await s.threadPreviewSettled();XCTAssertNotNil(s.threadPreview,s.threadError ?? s.status)
        let spec=try XCTUnwrap(s.threadDraft?.built)
        XCTAssertEqual(spec.majorDiameter,40);XCTAssertEqual(spec.pitch,3);XCTAssertEqual(spec.threadedLength,12)
        XCTAssertFalse(spec.isInternal);XCTAssertEqual(spec.shape,.printable)
        XCTAssertEqual(spec.startCount,1);XCTAssertEqual(spec.clearance,0.2);XCTAssertEqual(spec.leadIn,true)
        XCTAssertNil(s.threadWall,"No warning means at least the native 1 mm reporting threshold")
        XCTAssertGreaterThan(spec.rootRadius-15,3)
        let ends=try XCTUnwrap(spec.ends),draft=try XCTUnwrap(s.threadDraft)
        let entry=draft.atEnd ? ends.end : ends.start
        XCTAssertEqual(s.workspace.bodies[0].worldPoint(spec.origin+spec.axis*entry).z,24,accuracy:1e-5)
        attach(c,"E01 - cut thread preview")
        s.confirmThread();c.refresh();XCTAssertNil(s.threadDraft)
        let potID=s.workspace.bodies[0].id,pot=try SolidKernel.solid(for:s.workspace.bodies[0])
        XCTAssertLessThan(pot.volume,unthreaded.volume-100)
        XCTAssertFalse(pot.contains([0,0,6]));XCTAssertTrue(pot.contains([0,0,4]))
        s.select(.body(potID));XCTAssertTrue(s.matingChoices.contains(.cap));s.makeMatingPart(.cap);await s.matingPartSettled();c.refresh()
        XCTAssertEqual(s.workspace.bodies.count,2)
        let cap=try XCTUnwrap(s.workspace.bodies.last),mate=try XCTUnwrap(cap.cuts.last?.thread)
        XCTAssertTrue(mate.isInternal);XCTAssertEqual(mate.majorDiameter,spec.majorDiameter);XCTAssertEqual(mate.pitch,spec.pitch)
        XCTAssertEqual(mate.startCount,1);XCTAssertEqual(mate.clearance,0.2)
        let capSolid=try SolidKernel.solid(for:cap)
        XCTAssertEqual(try SolidKernel.boolean(pot,capSolid,.intersect).volume,0,accuracy:0.01)
        cardSection(s,c,offset:0,name:"E01 - engaged pot and cap section")
        try moveBody(s,c,id:cap.id,axis:0,amount:65)
        let moved=try SolidKernel.solid(for:s.workspace.bodies[1]);XCTAssertGreaterThan(moved.bounds.min.x,pot.bounds.max.x)
        try await complete(s,c,document:d,size:pot.bounds.max-pot.bounds.min,expectedVolume:pot.volume,name:"E01 Storage Pot",additional:[(size:capSolid.bounds.max-capSolid.bounds.min,volume:capSolid.volume)])
    }

    func measureCylinderDiameter(_ s: ModelingSession, _ c: CanvasController, body: SolidBody, diameter: Double) throws {
        let solid=try SolidKernel.solid(for:body)
        let face=try XCTUnwrap((0..<solid.faceCount).first { index in solid.faceCylinder(index).map { abs($0.radius*2-diameter)<1e-5 } ?? false })
        s.select(.face(FaceSelection(bodyID:body.id,face:face,plane:nil,center:try XCTUnwrap(solid.faceCenter(face)))))
        s.beginMeasure();c.refresh();XCTAssertTrue(s.measurements.values.contains { abs($0.value-diameter)<1e-5 })
        s.chooseTool(.select);s.select(nil);c.refresh()
    }

    func testRecordingCardE02FitCouponAndStartingPreference() async throws {
        let (s,c,d,directory)=try await newProject("E02 Fit Test")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.chooseTool(.fitTest);c.refresh();XCTAssertEqual(s.workspace.bodies.count,2)
        let plate=s.workspace.bodies[0],peg=s.workspace.bodies[1]
        XCTAssertEqual(plate.cuts.count,7)
        for (i,gap) in [0.1,0.15,0.2,0.25,0.3,0.35,0.4].enumerated() {
            XCTAssertEqual(try XCTUnwrap(plate.cuts[i].hole).diameter,6+2*gap,accuracy:1e-9)
            XCTAssertEqual(plate.cuts[i].profile.circle?.radius ?? 0,3+gap,accuracy:1e-9)
        }
        try measureCylinderDiameter(s,c,body:peg,diameter:6)
        try measureCylinderDiameter(s,c,body:plate,diameter:6.4)
        s.requestCamera(.home);c.refresh();s.requestCamera(.reset);c.refresh();attach(c,"E02 - seven-hole coupon and separate peg")
        let unchanged=s.workspace
        s.setFitClearance(0.25);XCTAssertEqual(s.fitClearance,0.25);XCTAssertEqual(s.workspace,unchanged)
        try faceSketch(s,c,at:[10,3,4],camera:.alignAt(.top,[35,8,4]))
        s.chooseTool(.peg);c.refresh();tap(c,[10,3,4]);XCTAssertEqual(s.pegDraft?.spec.clearance,0.25)
        s.cancelPeg();s.exitSketch();hideSketches(s,c)
        XCTAssertEqual(s.workspace.bodies,unchanged.bodies,"Preference/demo does not rebuild the coupon")
        let radii: [Double] = [3.1,3.15,3.2,3.25,3.3,3.35,3.4]
        let holeVolume=radii.reduce(0.0) { $0+Double.pi*$1*$1*4 }
        let plateVolume=70.0*16*4-3.0*3/2*4-holeVolume
        let pegVolume=14.0*14*3+Double.pi*3*3*8-Double.pi*0.5*(9-(9+7.5+6.25)/3)
        try await complete(s,c,document:d,size:[70,16,4],expectedVolume:plateVolume,name:"E02 Fit Test",additional:[(size:[14,14,11],volume:pegVolume)])
        let check=ProjectDocument(fileURL:d.fileURL)
        let opened=await withCheckedContinuation { c in check.open { c.resume(returning:$0) } };XCTAssertTrue(opened)
        XCTAssertEqual(check.project.workspace.bodies,unchanged.bodies)
        let closed=await withCheckedContinuation { c in check.close { c.resume(returning:$0) } };XCTAssertTrue(closed)
    }

    func testRecordingCardE03CoinSlotTemplateLidAndCoupon() async throws {
        let template=try XCTUnwrap(BoxTemplates.templates.first { $0.id == "enclosures.slip-lid-box" })
        var values=template.defaults
        for (id,value) in [("width",60.0),("depth",40),("height",30),("wall",2.4),("radius",5),("fit",0.2),("vents",0)] { values[id]=value }
        let workspace=try template.workspace(values)
        let (s,c,d,directory)=try await newProject("E03 Coin Box",workspace:workspace)
        defer { try? FileManager.default.removeItem(at:directory) }
        s.exitSketch();hideSketches(s,c);XCTAssertEqual(s.workspace.bodies.count,2)
        let box=s.workspace.bodies[0],lid=s.workspace.bodies[1]
        let boxSolid=try SolidKernel.solid(for:box),before=try SolidKernel.solid(for:lid)
        let center=(before.bounds.min+before.bounds.max)/2
        let z=before.bounds.min.z+2
        try faceSketch(s,c,at:[Float(center.x),Float(center.y),Float(z)],camera:.alignAt(.top,[center.x,center.y,z]))
        s.chooseTool(.slot);c.refresh()
        let count=s.workspace.shapes.count
        stroke(c,from:[Float(center.x-14.5),Float(center.y),Float(z)],to:[Float(center.x+14.5),Float(center.y),Float(z)])
        XCTAssertEqual(s.workspace.shapes.count,count+1)
        let slot=try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(slot.kind,.slot)
        s.chooseTool(.select);XCTAssertTrue(s.applyDimension(29,target:.shape(slot.id,.length)));XCTAssertTrue(s.applyDimension(3,target:.shape(slot.id,.width)))
        let rough=try XCTUnwrap(s.workspace.shapes.first { $0.id == slot.id })
        try pointOffset(s,c,fixed:[Float(center.x),Float(center.y),Float(z)],moving:SIMD3<Float>(rough.plane.point(rough.start)),horizontal:14.5)
        let positioned=try XCTUnwrap(s.workspace.shapes.first { $0.id == slot.id })
        XCTAssertLessThan(simd_distance(positioned.plane.point(positioned.center),[center.x,center.y,z]),1e-5)
        s.select(.shape(slot.id));s.beginMeasure();c.refresh()
        XCTAssertTrue(s.measurements.values.contains { abs($0.value-32)<1e-5 });XCTAssertTrue(s.measurements.values.contains { abs($0.value-3)<1e-5 })
        attach(c,"E03 - slot measured 32 by 3 mm")
        s.chooseTool(.select);s.exitSketch();s.select(.shape(slot.id));s.beginExtrusion();s.chooseExtrusionMode(.cut);s.cutThroughAll=true;s.extrusionDepth = -2
        XCTAssertTrue(s.canConfirmExtrusion,s.status);s.confirmExtrusion();hideSketches(s,c)
        XCTAssertEqual(s.workspace.bodies[0],box,"Through All only reaches the separated lid")
        let cut=try SolidKernel.solid(for:s.workspace.bodies[1]),slotArea=29*3+Double.pi*1.5*1.5
        XCTAssertEqual(before.volume-cut.volume,slotArea*2,accuracy:0.001)
        XCTAssertFalse(cut.contains([center.x,center.y,before.bounds.min.z+1]));XCTAssertTrue(cut.contains([center.x,center.y+4,before.bounds.min.z+1]))
        try await complete(s,c,document:d,size:boxSolid.bounds.max-boxSolid.bounds.min,expectedVolume:boxSolid.volume,name:"E03 Coin Box",additional:[(size:before.bounds.max-before.bounds.min,volume:before.volume-slotArea*2)])
        let (coupon,cc,cd,couponDirectory)=try await newProject("E03 Coin Slot Coupon",workspace:s.workspace)
        defer { try? FileManager.default.removeItem(at:couponDirectory) }
        coupon.exitSketch();coupon.select(.body(box.id));coupon.deleteSelection();cc.refresh();XCTAssertEqual(coupon.workspace.bodies.count,1)
        try await complete(coupon,cc,document:cd,size:before.bounds.max-before.bounds.min,expectedVolume:before.volume-slotArea*2,name:"E03 Coin Slot Coupon")
        let check=ProjectDocument(fileURL:d.fileURL)
        let opened=await withCheckedContinuation { c in check.open { c.resume(returning:$0) } };XCTAssertTrue(opened);XCTAssertEqual(check.project.workspace,s.workspace)
        let closed=await withCheckedContinuation { c in check.close { c.resume(returning:$0) } };XCTAssertTrue(closed)
    }

    func testRecordingCardE04FourHardwareHolesAndPresetReset() async throws {
        let (s,c,d,directory)=try await newProject("E04 Hardware Block")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.requestCamera(.alignAt(.top,[40,15,0]));c.refresh()
        let base=try rectangle(s,c,from:[0,0,0],to:[80,30,0],width:80,height:30)
        try extrude(s,c,shape:base,depth:12,mode:.newBody);hideSketches(s,c)
        try faceSketch(s,c,at:[40,15,12])
        for x: Float in [10,30,50,70] {
            s.chooseTool(.point);c.refresh();tap(c,[x,15,12])
            let point=try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(point.kind,.point)
            try pointOffset(s,c,fixed:[0,0,12],moving:SIMD3<Float>(point.plane.point(point.start)),horizontal:Double(x),vertical:15)
        }
        for (x,kind): (Float,HoleSpec.Kind) in [(10,.simple),(30,.counterbore),(50,.countersink),(70,.insert)] {
            s.chooseTool(.hole);c.refresh();tap(c,[x,15,12]);XCTAssertNotNil(s.holeDraft)
            s.chooseHole(kind:kind,size:"M3");s.setHoleThrough(kind != .insert)
            XCTAssertEqual(s.holeDraft?.spec.diameter,kind == .insert ? 4 : 3.4)
            if kind == .insert { XCTAssertEqual(s.holeDraft?.depth,6.7) }
            XCTAssertNotNil(s.holePreview);s.confirmHole();c.refresh();XCTAssertNil(s.holeDraft)
        }
        s.chooseTool(.select);s.exitSketch();hideSketches(s,c)
        let finished=s.workspace
        try faceSketch(s,c,at:[40,5,12]);s.chooseTool(.hole);c.refresh();tap(c,[40,5,12])
        s.chooseHole(kind:.simple,size:"M3");XCTAssertTrue(s.applyDimension(3.8,target:.holeDiameter))
        s.chooseHole(size:"M4");XCTAssertEqual(s.holeDraft?.spec.diameter,4.5)
        s.chooseHole(size:"M3");XCTAssertEqual(s.holeDraft?.spec.diameter,3.4)
        XCTAssertTrue(s.applyDimension(3.8,target:.holeDiameter));attach(c,"S06 - preset first and custom diameter last")
        s.cancelHole();s.exitSketch();hideSketches(s,c);XCTAssertEqual(s.workspace.bodies,finished.bodies)
        cardSection(s,c,offset:-15,name:"E04 - four hardware profiles in Section")
        let solid=try SolidKernel.solid(for:s.workspace.bodies[0])
        for x in [10.0,30,50] { XCTAssertFalse(solid.contains([x,15,1])) }
        XCTAssertFalse(solid.contains([70,15,11]));XCTAssertTrue(solid.contains([70,15,5]))
        let simple=Double.pi*1.7*1.7*12
        let counterbore=Double.pi*(1.7*1.7*(12-3.4)+3.05*3.05*3.4)
        let countersink=Double.pi*(1.7*1.7*(12-1.5)+1.5*(3.2*3.2+3.2*1.7+1.7*1.7)/3)
        let insert=Double.pi*4*6.7
        try await complete(s,c,document:d,size:[80,30,12],expectedVolume:80*30*12-simple-counterbore-countersink-insert,name:"E04 Hardware Block")
    }

    func raisedRecordingProject(_ number: String, bank: Bool) async throws {
        let name=number+(bank ? " Threaded Coin Bank" : " Thin Tube")
        let (s,c,d,directory)=try await newProject(name)
        defer { try? FileManager.default.removeItem(at:directory) }
        let height=bank ? 70.0 : 20.0
        s.setFitClearance(0.2)
        let disk=try circle(s,c,center:[0,0,0],diameter:60)
        try extrude(s,c,shape:disk,depth:height,mode:.newBody);hideSketches(s,c)
        if bank {
            s.requestCamera(.align(.top));c.refresh();tap(c,[0,0,Float(height)]);s.shellSelection()
            XCTAssertTrue(s.applyDimension(3,target:.shellThickness));XCTAssertNotNil(s.shellPreview);s.confirmShell();c.refresh()
            let shell=try SolidKernel.solid(for:s.workspace.bodies[0])
            XCTAssertEqual(shell.volume,Double.pi*(900*70-729*67),accuracy:0.001)
            XCTAssertTrue(shell.contains([0,0,2]));XCTAssertFalse(shell.contains([0,0,4]))
        } else {
            try faceSketch(s,c,at:[0,0,20])
            let bore=try circle(s,c,center:[0,0,20],diameter:56)
            s.exitSketch();s.select(.shape(bore.id));s.beginExtrusion();s.chooseExtrusionMode(.cut);s.cutThroughAll=true;s.extrusionDepth = -20
            XCTAssertTrue(s.canConfirmExtrusion);s.confirmExtrusion();hideSketches(s,c)
            XCTAssertEqual(try SolidKernel.solid(for:s.workspace.bodies[0]).volume,Double.pi*(900-784)*20,accuracy:0.001)
        }
        try await savedSnapshot(s,document:d,name:number+" Before Thread")
        let unthreadedBody=s.workspace.bodies[0]
        let unthreaded=try SolidKernel.solid(for:unthreadedBody),neckID=unthreadedBody.id
        s.select(nil);s.requestCamera(.home);c.refresh();s.requestCamera(.reset);c.refresh();s.chooseTool(.thread);c.refresh();tap(c,[0,-30,Float(height-6)])
        XCTAssertNotNil(s.threadDraft);s.chooseThreadSize("");s.chooseThreadPitch(3);s.setThreadLength(12);s.setThreadClearance(0.2);s.setThreadProfile(.printable)
        s.setThreadLeadIn(true);s.setThreadLeftHanded(false);s.setThreadStarts(2)
        if !bank {
            await s.threadPreviewSettled();XCTAssertNotNil(s.threadPreview)
            XCTAssertEqual(s.threadWall ?? 0,0.9,accuracy:0.11)
            attach(c,"E18 - thin-wall Cut warning before switching to Raised")
        }
        s.setThreadRaised(true);await s.threadPreviewSettled();XCTAssertNotNil(s.threadPreview,s.threadError ?? s.status)
        let spec=try XCTUnwrap(s.threadDraft?.built)
        XCTAssertEqual(spec.majorDiameter,61.8,accuracy:1e-9);XCTAssertEqual(spec.minorDiameter,60,accuracy:1e-9)
        XCTAssertEqual(spec.shape,.printable);XCTAssertEqual(spec.pitch,3);XCTAssertEqual(spec.startCount,2);XCTAssertEqual(spec.lead,6)
        XCTAssertEqual(spec.threadedLength,12);XCTAssertTrue(spec.isRaised)
        attach(c,number+" - Printable 45 degree raised nominal diameter 61.8 mm")
        s.confirmThread();c.refresh()
        let neck=try SolidKernel.solid(for:s.workspace.bodies[0])
        XCTAssertGreaterThan(neck.volume,unthreaded.volume)
        XCTAssertTrue(neck.contains([29.2,0,height-6]));XCTAssertFalse(neck.contains([26,0,height-6]))
        s.select(.body(neckID));s.makeMatingPart(.cap);await s.matingPartSettled();c.refresh();XCTAssertEqual(s.workspace.bodies.count,2)
        let cap=try XCTUnwrap(s.workspace.bodies.last),mate=try XCTUnwrap(cap.cuts.last?.thread)
        XCTAssertEqual(mate.startCount,2);XCTAssertEqual(mate.pitch,3);XCTAssertEqual(mate.shape,.printable);XCTAssertTrue(mate.isInternal)
        let capSolid=try SolidKernel.solid(for:cap)
        XCTAssertEqual(try SolidKernel.boolean(neck,capSolid,.intersect).volume,0,accuracy:0.01)
        cardSection(s,c,offset:0,name:number+" - raised neck and generated cap section")
        let move=bank ? 100.0 : 85
        try moveBody(s,c,id:cap.id,axis:0,amount:move)
        var capVolume=capSolid.volume
        let preservedNeck=s.workspace.bodies[0]
        if bank {
            let z=capSolid.bounds.max.z
            try faceSketch(s,c,at:[Float(move),0,Float(z)],camera:.alignAt(.top,[move,0,z]))
            s.chooseTool(.slot);c.refresh();stroke(c,from:[Float(move-14.4),0,Float(z)],to:[Float(move+14.4),0,Float(z)])
            let slot=try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(slot.kind,.slot)
            s.chooseTool(.select);XCTAssertTrue(s.applyDimension(28.8,target:.shape(slot.id,.length)));XCTAssertTrue(s.applyDimension(3.2,target:.shape(slot.id,.width)))
            let rough=try XCTUnwrap(s.workspace.shapes.first { $0.id == slot.id })
            try pointOffset(s,c,fixed:[Float(move),0,Float(z)],moving:SIMD3<Float>(rough.plane.point(rough.start)),horizontal:14.4)
            let positioned=try XCTUnwrap(s.workspace.shapes.first { $0.id == slot.id })
            XCTAssertLessThan(simd_distance(positioned.plane.point(positioned.center),[move,0,z]),1e-5)
            s.select(.shape(slot.id));s.beginMeasure();c.refresh();XCTAssertTrue(s.measurements.values.contains { abs($0.value-32)<1e-5 })
            attach(c,"E24 - 32 by 3.2 mm coin-admission slot")
            s.chooseTool(.select);s.exitSketch();s.select(.shape(slot.id));s.beginExtrusion();s.chooseExtrusionMode(.cut);s.cutThroughAll=true;s.extrusionDepth = -3
            XCTAssertTrue(s.canConfirmExtrusion);s.confirmExtrusion();hideSketches(s,c)
            XCTAssertEqual(s.workspace.bodies[0],preservedNeck,"Cap slot leaves the separate pot unchanged")
            let actual=try SolidKernel.solid(for:s.workspace.bodies[1])
            let underside=try XCTUnwrap((0..<capSolid.faceCount).compactMap { capSolid.facePlane($0) }.filter { $0.normal.z < -0.99999 }.map { $0.origin.z }.max())
            let ceiling=capSolid.bounds.max.z-underside
            XCTAssertEqual(ceiling,2.98,accuracy:1e-5,"Matching thread's 0.02 mm closed-end extension")
            let removed=(28.8*3.2+Double.pi*1.6*1.6)*ceiling
            XCTAssertEqual(capSolid.volume-actual.volume,removed,accuracy:0.01)
            XCTAssertFalse(actual.contains([move,0,z-1]));XCTAssertTrue(actual.contains([move,5,z-1]))
            capVolume -= removed
        }
        try await complete(s,c,document:d,size:neck.bounds.max-neck.bounds.min,expectedVolume:neck.volume,name:name,additional:[(size:capSolid.bounds.max-capSolid.bounds.min,volume:capVolume)])
    }

    func testRecordingCardE18RaisedThreadNeckAndCap() async throws {
        try await raisedRecordingProject("E18",bank:false)
    }

    func testRecordingCardE24ThreadedCoinBankAndSlottedCap() async throws {
        try await raisedRecordingProject("E24",bank:true)
    }

    func testRecordingCardE05GridfinityBinPlateAndDivider() async throws {
        var plainVolume=0.0
        for (id,name,divider,size) in [("gridfinity.bin","E05 Gridfinity Bin 2x1x6",0,SIMD3<Double>(83.5,41.5,46.2)),("gridfinity.baseplate","E05 Baseplate 2x1",0,SIMD3<Double>(84,42,4.45)),("gridfinity.divided-bin","E05 Divided Variant",1,SIMD3<Double>(83.5,41.5,46.2))] {
            let template=try XCTUnwrap(Gridfinity.templates.first { $0.id == id })
            var values=template.defaults
            for (key,value) in [("columns",2.0),("rows",1),("height",6),("dividersX",Double(divider)),("dividersY",0),("lip",1),("magnets",0)] { values[key]=value }
            if id == "gridfinity.bin" { XCTAssertFalse(template.parameters.contains { ["dividersX","dividersY","magnets"].contains($0.id) }) }
            if id == "gridfinity.baseplate" { XCTAssertFalse(template.parameters.contains { $0.id == "magnets" }) }
            let workspace=try template.workspace(values)
            let (s,c,d,directory)=try await newProject(name,workspace:workspace)
            defer { try? FileManager.default.removeItem(at:directory) }
            s.exitSketch();hideSketches(s,c)
            XCTAssertEqual(workspace.groups.count,1);XCTAssertEqual(workspace.bodies[0].name,id == "gridfinity.baseplate" ? "Baseplate" : "Bin")
            let solid=try SolidKernel.solid(for:s.workspace.bodies[0])
            XCTAssertEqual(solid.bounds.min.z,0,accuracy:1e-5)
            if id == "gridfinity.baseplate" {
                for x in [-21.0,21] { XCTAssertFalse(solid.contains([x,0,1])) }
                XCTAssertTrue(solid.contains([0,0,1]));XCTAssertTrue(solid.contains([41.8,0,4]))
            } else {
                for x in [-21.0,21] { XCTAssertTrue(solid.contains([x,0,1]));XCTAssertTrue(solid.contains([x,0,5.9]));XCTAssertFalse(solid.contains([x,0,7])) }
                XCTAssertFalse(solid.contains([0,0,1]),"Separate stepped feet")
                XCTAssertTrue(solid.contains([41,0,20]));XCTAssertFalse(solid.contains([0,0,47]))
                XCTAssertEqual(solid.contains([0,0,20]),divider == 1)
                if divider == 0 { plainVolume=solid.volume } else {
                    XCTAssertGreaterThan(solid.volume-plainVolume,1500)
                    XCTAssertLessThan(solid.volume-plainVolume,1.2*39.1*36,"Divider ends merge into the rounded inside walls")
                }
                cardSection(s,c,offset:0,name:name+" - foot floor and lip section")
            }
            try await complete(s,c,document:d,size:size,expectedVolume:solid.volume,name:name)
        }
    }

    func testRecordingCardE06BoltAndMatchingHexNut() async throws {
        let (s,c,d,directory)=try await newProject("E06 Bolt and Nut")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.setFitClearance(0.2)
        let head=try circle(s,c,center:[0,0,0],diameter:24)
        try extrude(s,c,shape:head,depth:4,mode:.newBody);hideSketches(s,c)
        try faceSketch(s,c,at:[0,0,4])
        let shank=try circle(s,c,center:[0,0,4],diameter:12)
        try extrude(s,c,shape:shank,depth:18,mode:.join);hideSketches(s,c)
        XCTAssertEqual(try SolidKernel.solid(for:s.workspace.bodies[0]).volume,Double.pi*(144*4+36*18),accuracy:0.001)
        try await savedSnapshot(s,document:d,name:"E06 Unthreaded Bolt")
        s.requestCamera(.home);c.refresh();s.requestCamera(.reset);c.refresh();s.chooseTool(.thread);c.refresh();tap(c,[0,-6,14])
        XCTAssertNotNil(s.threadDraft)
        s.chooseThreadSize("M12");s.chooseThreadPitch(1.75);s.setThreadLength(nil);s.setThreadClearance(0.2);s.setThreadLeftHanded(false);s.setThreadStarts(1);s.setThreadLeadIn(true);s.setThreadRaised(false)
        await s.threadPreviewSettled();XCTAssertNotNil(s.threadPreview,s.threadError ?? s.status)
        let spec=try XCTUnwrap(s.threadDraft?.built)
        XCTAssertEqual(spec.majorDiameter,12);XCTAssertEqual(spec.pitch,1.75);XCTAssertEqual(spec.shape,.iso)
        XCTAssertEqual(spec.threadedLength,18,accuracy:1e-5);XCTAssertEqual(spec.clearance,0.2);XCTAssertEqual(spec.startCount,1);XCTAssertFalse(spec.isInternal)
        XCTAssertNotEqual(spec.leftHanded,true);XCTAssertEqual(spec.leadIn,true)
        attach(c,"E06 - whole shank cut thread preview")
        s.confirmThread();c.refresh()
        let bolt=s.workspace.bodies[0],solid=try SolidKernel.solid(for:bolt)
        XCTAssertTrue(solid.contains([11,0,2]));XCTAssertFalse(solid.contains([11,0,6]));XCTAssertTrue(solid.contains([0,0,21]))
        s.select(.body(bolt.id));XCTAssertTrue(s.matingChoices.contains(.nut));s.makeMatingPart(.nut);await s.matingPartSettled();c.refresh()
        XCTAssertEqual(s.workspace.bodies.count,2)
        let nut=s.workspace.bodies[1],mate=try XCTUnwrap(nut.cuts.last?.thread),nutSolid=try SolidKernel.solid(for:nut)
        XCTAssertTrue(mate.isInternal);XCTAssertEqual(mate.pitch,1.75);XCTAssertEqual(mate.majorDiameter,12);XCTAssertEqual(mate.startCount,1);XCTAssertEqual(mate.clearance,0.2)
        XCTAssertNotEqual(mate.leftHanded,true);XCTAssertEqual(mate.shape,.iso)
        XCTAssertEqual(try SolidKernel.boolean(solid,nutSolid,.intersect).volume,0,accuracy:0.01)
        cardSection(s,c,offset:0,name:"E06 - engaged bolt and hex nut section")
        try moveBody(s,c,id:nut.id,axis:0,amount:40)
        XCTAssertEqual(s.workspace.bodies[0],bolt)
        XCTAssertGreaterThan(try SolidKernel.solid(for:s.workspace.bodies[1]).bounds.min.x,solid.bounds.max.x)
        try await complete(s,c,document:d,size:[24,24,22],expectedVolume:solid.volume,name:"E06 Bolt and Nut",additional:[(size:nutSolid.bounds.max-nutSolid.bounds.min,volume:nutSolid.volume)])
    }

    func testRecordingCardE07CustomBoardCaseAndBlindPortCut() async throws {
        let template=try XCTUnwrap(BoardTemplates.templates.first { $0.id == "electronics.custom-case" })
        var values=template.defaults
        for (key,value) in [("board",4.0),("boardWidth",70),("boardLength",50),("holeInset",3.5),("screw",2),("fixing",1),("wall",2.4),("standoff",5),("headroom",20),("fit",0.2)] { values[key]=value }
        let workspace=try template.workspace(values)
        let (s,c,d,directory)=try await newProject("E07 Custom Board Case",workspace:workspace)
        defer { try? FileManager.default.removeItem(at:directory) }
        s.exitSketch();hideSketches(s,c)
        XCTAssertEqual(workspace.bodies.map(\.name),["Case","Lid"])
        let body=s.workspace.bodies[0],lid=s.workspace.bodies[1],before=try SolidKernel.solid(for:body),lidSolid=try SolidKernel.solid(for:lid)
        let x=(before.bounds.min.x+before.bounds.max.x)/2,y=(before.bounds.min.y+before.bounds.max.y)/2,front=before.bounds.min.y
        let holes=body.cuts.filter { $0.hole != nil }
        XCTAssertEqual(holes.count,4)
        for hole in holes { XCTAssertEqual(hole.hole?.diameter,4);XCTAssertEqual(hole.depth,6.2,accuracy:1e-5) }
        for dx in [-31.5,31.5] { for dy in [-21.5,21.5] {
            XCTAssertFalse(before.contains([x+dx,y+dy,1]));XCTAssertTrue(before.contains([x+dx,y+dy,0.7]))
            XCTAssertTrue(before.contains([x+dx+2.5,y+dy,6.9]));XCTAssertFalse(before.contains([x+dx+2.5,y+dy,7.1]))
        } }
        XCTAssertTrue(before.contains([x,y,1]));XCTAssertFalse(before.contains([x,y,3]))
        try await savedSnapshot(s,document:d,name:"E07 Case Before Port")
        try faceSketch(s,c,at:[Float(x),Float(front),11],camera:faceCamera([x,front,11],normal:[0,-1,0]))
        attach(c,"E07 - front face sketch before opening")
        var opening=try rectangle(s,c,from:[Float(x-12),Float(front),5],to:[Float(x+12),Float(front),18],width:12,height:6)
        try pointOffset(s,c,fixed:[Float(before.bounds.min.x+4.4),Float(front),0],moving:SIMD3<Float>(opening.plane.point(opening.start)),horizontal:29,vertical:8)
        opening=try XCTUnwrap(s.workspace.shapes.first { $0.id == opening.id })
        let points=opening.outline.map { opening.plane.point($0) }
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).min()),x-6,accuracy:1e-5);XCTAssertEqual(try XCTUnwrap(points.map(\.z).min()),8,accuracy:1e-5)
        try extrude(s,c,shape:opening,depth:-3,mode:.cut);hideSketches(s,c)
        let after=try SolidKernel.solid(for:s.workspace.bodies[0])
        XCTAssertEqual(before.volume-after.volume,12*6*2.4,accuracy:0.001)
        XCTAssertEqual(s.workspace.bodies[1],lid)
        XCTAssertFalse(after.contains([x,front+1,11]));XCTAssertTrue(after.contains([x,front+1,7]));XCTAssertTrue(after.contains([x,before.bounds.max.y-1,11]))
        s.requestCamera(.alignAt(.front,[x,front,14]));c.refresh();attach(c,"E07 - bounded front wall opening")
        cardSection(s,c,offset:-y,name:"E07 - floor and enclosure section")
        try measureCylinderDiameter(s,c,body:s.workspace.bodies[0],diameter:4)
        try await complete(s,c,document:d,size:[78.8,58.8,28.6],expectedVolume:before.volume-172.8,name:"E07 Custom Board Case",additional:[(size:[78.8,58.8,6],volume:lidSolid.volume)])
    }

    func testRecordingCardE08FiveCustomInsertPockets() async throws {
        let (s,c,d,directory)=try await newProject("E08 Insert Coupon")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.requestCamera(.alignAt(.top,[40,12.5,0]));c.refresh()
        let base=try rectangle(s,c,from:[0,0,0],to:[80,25,0],width:80,height:25)
        try extrude(s,c,shape:base,depth:12,mode:.newBody);hideSketches(s,c)
        try faceSketch(s,c,at:[40,12.5,12])
        for x: Float in [8,24,40,56,72] {
            s.chooseTool(.point);c.refresh();tap(c,[x,12.5,12])
            let point=try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(point.kind,.point)
            try pointOffset(s,c,fixed:[0,0,12],moving:SIMD3<Float>(point.plane.point(point.start)),horizontal:Double(x),vertical:12.5)
        }
        for (x,diameter): (Float,Double) in [(8,3.8),(24,4),(40,4.2),(56,4.4),(72,4.6)] {
            s.chooseTool(.hole);c.refresh();tap(c,[x,12.5,12]);XCTAssertNotNil(s.holeDraft)
            s.chooseHole(kind:.insert,size:"M3");s.setHoleThrough(false)
            XCTAssertEqual(s.holeDraft?.spec.diameter,4)
            XCTAssertTrue(s.applyDimension(diameter,target:.holeDiameter));XCTAssertTrue(s.applyDimension(5.5,target:.holeDepth))
            XCTAssertNotNil(s.holePreview);s.confirmHole();c.refresh();XCTAssertNil(s.holeDraft)
        }
        s.exitSketch();hideSketches(s,c)
        let body=s.workspace.bodies[0],solid=try SolidKernel.solid(for:body)
        for (x,diameter) in [(8.0,3.8),(24,4),(40,4.2),(56,4.4),(72,4.6)] {
            XCTAssertTrue(solid.contains([x,12.5,6.4]));XCTAssertFalse(solid.contains([x,12.5,6.6]))
            try measureCylinderDiameter(s,c,body:body,diameter:diameter)
        }
        cardSection(s,c,offset:-12.5,name:"E08 - five blind insert pockets section")
        let removed=[3.8,4,4.2,4.4,4.6].reduce(0.0) { $0+Double.pi*$1*$1/4*5.5 }
        try await complete(s,c,document:d,size:[80,25,12],expectedVolume:24000-removed,name:"E08 Insert Coupon")
    }

    func recordingSlot(_ s: ModelingSession, _ c: CanvasController, from a: SIMD3<Float>, to b: SIMD3<Float>, length: Double, width: Double) throws -> SketchShape {
        let count=s.workspace.shapes.count
        s.chooseTool(.slot);c.refresh();stroke(c,from:a,to:b)
        XCTAssertEqual(s.workspace.shapes.count,count+1)
        let slot=try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(slot.kind,.slot)
        s.chooseTool(.select)
        XCTAssertTrue(s.applyDimension(length,target:.shape(slot.id,.length)));XCTAssertTrue(s.applyDimension(width,target:.shape(slot.id,.width)))
        return try XCTUnwrap(s.workspace.shapes.first { $0.id == slot.id })
    }

    func recordingCut(_ s: ModelingSession, _ c: CanvasController, shape: SketchShape, depth: Double, through: Bool) throws {
        s.exitSketch();s.select(.shape(shape.id));s.beginExtrusion();s.chooseExtrusionMode(.cut)
        s.cutThroughAll=through;XCTAssertTrue(s.applyDimension(depth,target:.extrusion));XCTAssertTrue(s.canConfirmExtrusion,s.status)
        s.confirmExtrusion();hideSketches(s,c)
    }

    func recordingFinishEdge(_ s: ModelingSession, _ c: CanvasController, from a: SIMD3<Float>, to b: SIMD3<Float>) throws {
        let p=try XCTUnwrap(stride(from:Float(0.15),through:0.85,by:0.1).map { a+(b-a)*$0 }.first { world in
            let screen=c.project(world)
            return c.finishHandle()?.hitArea.contains(screen) != true && c.dimensionAnnotations().allSatisfy { annotation in
                guard let button=c.input.dimensionButton(for:annotation.target) else { return true }
                return !button.bounds.insetBy(dx:-8,dy:-8).contains(button.convert(screen,from:c.input))
            }
        })
        let count=s.finishDraft?.edges.count ?? 0
        tap(c,p);XCTAssertEqual(s.finishDraft?.edges.count,count+1)
    }

    func testRecordingCardE09SlottedMountingBracket() async throws {
        let (s,c,d,directory)=try await newProject("E09 Slotted Bracket")
        defer { try? FileManager.default.removeItem(at:directory) }
        s.requestCamera(.alignAt(.top,[30,15,0]));c.refresh()
        let base=try rectangle(s,c,from:[0,0,0],to:[60,30,0],width:60,height:30)
        try extrude(s,c,shape:base,depth:4,mode:.newBody);hideSketches(s,c)
        try faceSketch(s,c,at:[30,15,4])
        let wall=try rectangle(s,c,from:[0,26,4],to:[60,30,4],width:60,height:4)
        try extrude(s,c,shape:wall,depth:26,mode:.join);hideSketches(s,c)
        for x: Float in [15,45] {
            try faceSketch(s,c,at:[30,12,4],camera:.alignAt(.top,[30,15,4]))
            let slot=try recordingSlot(s,c,from:[x,8,4],to:[x,18,4],length:10,width:4.5)
            try pointOffset(s,c,fixed:[0,0,4],moving:SIMD3<Float>(slot.plane.point(slot.start)),horizontal:Double(x),vertical:8)
            let positioned=try XCTUnwrap(s.workspace.shapes.first { $0.id == slot.id })
            XCTAssertLessThan(simd_distance(positioned.plane.point(positioned.start),[Double(x),8,4]),1e-5)
            XCTAssertLessThan(simd_distance(positioned.plane.point(positioned.end),[Double(x),18,4]),1e-5)
            s.select(.shape(slot.id));s.beginMeasure();c.refresh()
            XCTAssertTrue(s.measurements.values.contains { abs($0.value-14.5)<1e-5 });XCTAssertTrue(s.measurements.values.contains { abs($0.value-4.5)<1e-5 });s.chooseTool(.select)
            try recordingCut(s,c,shape:positioned,depth:-4,through:true)
        }
        try faceSketch(s,c,at:[30,26,19],camera:faceCamera([30,26,19],normal:[0,-1,0]))
        let hole=try circle(s,c,center:[30,26,19],diameter:4.5)
        try pointOffset(s,c,fixed:[0,26,4],moving:SIMD3<Float>(hole.plane.point(hole.start)),horizontal:30,vertical:15)
        let positioned=try XCTUnwrap(s.workspace.shapes.first { $0.id == hole.id })
        XCTAssertLessThan(simd_distance(positioned.plane.point(positioned.start),[30,26,19]),1e-5)
        try recordingCut(s,c,shape:positioned,depth:-5,through:false)
        let before=try SolidKernel.solid(for:s.workspace.bodies[0])
        let slotArea=10*4.5+Double.pi*2.25*2.25
        let beforeVolume=60*30*4+60*4*26-2*slotArea*4-Double.pi*2.25*2.25*4
        XCTAssertEqual(before.volume,beforeVolume,accuracy:0.001)
        s.requestCamera(.home);c.refresh();s.requestCamera(.reset);c.refresh();s.chooseTool(.fillet);c.refresh()
        try recordingFinishEdge(s,c,from:[0,26,4],to:[60,26,4])
        XCTAssertTrue(s.applyDimension(1.5,target:.finishSize(.fillet)),s.finishError ?? s.status);XCTAssertNotNil(s.finishPreview)
        attach(c,"E09 - inside corner fillet preview R1.5")
        s.confirmFinish();hideSketches(s,c)
        let solid=try SolidKernel.solid(for:s.workspace.bodies[0])
        XCTAssertEqual(solid.volume,beforeVolume+60*1.5*1.5*(1-Double.pi/4),accuracy:0.02)
        for x in [15.0,45] { XCTAssertFalse(solid.contains([x,13,2]));XCTAssertTrue(solid.contains([x,28,20])) }
        XCTAssertFalse(solid.contains([30,28,19]));XCTAssertTrue(solid.contains([30,25.8,4.2]));XCTAssertFalse(solid.contains([30,24,6]))
        cardSection(s,c,offset:-13,name:"E09 - bracket slots and wall section")
        try await complete(s,c,document:d,size:[60,30,30],expectedVolume:solid.volume,name:"E09 Slotted Bracket")
    }

    func testRecordingCardE10JoinedPegsSocketHiddenUpper() async throws {
        let (s,c,d,directory)=try await newProject("E10 Peg Blocks")
        defer { try? FileManager.default.removeItem(at:directory) }
        let base=try rectangle(s,c,from:[0,0,0],to:[40,30,0],width:40,height:30)
        try extrude(s,c,shape:base,depth:10,mode:.newBody);hideSketches(s,c)
        try faceSketch(s,c,at:[20,15,10])
        let upper=try rectangle(s,c,from:[0,0,10],to:[40,30,10],width:40,height:30)
        try extrude(s,c,shape:upper,depth:8,mode:.newBody);hideSketches(s,c)
        XCTAssertEqual(s.workspace.bodies.count,2)
        let lowerID=s.workspace.bodies[0].id,upperID=s.workspace.bodies[1].id
        s.rename(.body(lowerID),to:"Lower");s.rename(.body(upperID),to:"Upper")
        try await savedSnapshot(s,document:d,name:"E10 Blocks Before Pegs")
        s.toggleHidden(.body(upperID));c.refresh()
        try faceSketch(s,c,at:[20,15,10])
        for x: Float in [10,30] {
            s.chooseTool(.point);c.refresh();tap(c,[x,15,10])
            let point=try XCTUnwrap(s.workspace.shapes.last);XCTAssertEqual(point.kind,.point)
            try pointOffset(s,c,fixed:[0,0,10],moving:SIMD3<Float>(point.plane.point(point.start)),horizontal:Double(x),vertical:15)
        }
        for x: Float in [10,30] {
            s.chooseTool(.peg);c.refresh();tap(c,[x,15,10]);XCTAssertNotNil(s.pegDraft)
            s.setPegSeparate(false);XCTAssertTrue(s.applyDimension(5,target:.pegDiameter));XCTAssertTrue(s.applyDimension(4,target:.pegHeight));s.setPegClearance(0.2)
            XCTAssertEqual(s.pegDraft?.spec.socketDiameter,5.4);XCTAssertEqual(s.pegDraft?.spec.socketDepth,4.2);XCTAssertEqual(s.pegSockets,[upperID]);XCTAssertEqual(s.workspace.bodies[1].hidden,true)
            XCTAssertNotNil(s.pegPreview,s.draftError ?? s.status);attach(c,"E10 - joined peg at X\(Int(x)) sockets hidden Upper")
            s.confirmPeg();c.refresh();XCTAssertNil(s.pegDraft)
        }
        s.exitSketch();hideSketches(s,c)
        let finished=s.workspace.bodies
        s.setFitClearance(0.35);XCTAssertEqual(s.workspace.bodies,finished,"Preference does not resize completed sockets")
        let lower=try SolidKernel.solid(for:s.workspace.bodies[0]),upperSolid=try SolidKernel.solid(for:s.workspace.bodies[1])
        for x in [10.0,30] {
            XCTAssertTrue(lower.contains([x,15,13.5]));XCTAssertFalse(upperSolid.contains([x,15,14.1]));XCTAssertTrue(upperSolid.contains([x,15,14.3]))
        }
        XCTAssertEqual(try SolidKernel.boolean(lower,upperSolid,.intersect).volume,0,accuracy:1e-6)
        s.toggleHidden(.body(upperID));hideSketches(s,c)
        try measureCylinderDiameter(s,c,body:s.workspace.bodies[0],diameter:5);try measureCylinderDiameter(s,c,body:s.workspace.bodies[1],diameter:5.4)
        cardSection(s,c,offset:-15,name:"E10 - assembled peg and socket depth section")
        try moveBody(s,c,id:upperID,axis:0,amount:60)
        let pegVolume=Double.pi*2.5*2.5*4-Double.pi*0.5*(6.25-(6.25+5+4)/3)
        try await complete(s,c,document:d,size:[40,30,14],expectedVolume:12000+2*pegVolume,name:"E10 Peg Blocks",additional:[(size:[40,30,8],volume:9600-2*Double.pi*2.7*2.7*4.2)])
    }

    func testRecordingCardE11ThreadedPlugAndBlindCoinRecess() async throws {
        let (s,c,d,directory)=try await newProject("E11 Coin Drive Plug")
        defer { try? FileManager.default.removeItem(at:directory) }
        let base=try rectangle(s,c,from:[0,0,0],to:[50,35,0],width:50,height:35)
        try extrude(s,c,shape:base,depth:10,mode:.newBody);hideSketches(s,c)
        try faceSketch(s,c,at:[25,17.5,10])
        let bore=try circle(s,c,center:[25,17.5,10],diameter:10)
        try pointOffset(s,c,fixed:[0,0,10],moving:SIMD3<Float>(bore.plane.point(bore.start)),horizontal:25,vertical:17.5)
        try recordingCut(s,c,shape:try XCTUnwrap(s.workspace.shapes.first { $0.id == bore.id }),depth:-10,through:true)
        XCTAssertEqual(try SolidKernel.solid(for:s.workspace.bodies[0]).volume,17500-Double.pi*25*10,accuracy:0.001)
        try await savedSnapshot(s,document:d,name:"E11 Before Thread")
        s.requestCamera(try faceCamera([25,17.5,10],normal:[0,-1,2]));c.refresh();s.chooseTool(.thread);c.refresh();tap(c,[25,22.5,8])
        XCTAssertNotNil(s.threadDraft)
        s.chooseThreadSize("M12");s.chooseThreadPitch(1.75);s.setThreadLength(nil);s.setThreadClearance(0.2);s.setThreadLeftHanded(false);s.setThreadStarts(1);s.setThreadLeadIn(true);s.setThreadRaised(false)
        await s.threadPreviewSettled();XCTAssertNotNil(s.threadPreview,s.threadError ?? s.status)
        let spec=try XCTUnwrap(s.threadDraft?.built)
        XCTAssertTrue(spec.isInternal);XCTAssertEqual(spec.majorDiameter,12);XCTAssertEqual(spec.pitch,1.75);XCTAssertEqual(spec.threadedLength,10,accuracy:1e-5);XCTAssertEqual(spec.shape,.iso);XCTAssertEqual(spec.clearance,0.2);XCTAssertEqual(spec.startCount,1);XCTAssertNotEqual(spec.leftHanded,true);XCTAssertEqual(spec.leadIn,true)
        s.confirmThread();c.refresh()
        let block=s.workspace.bodies[0],blockSolid=try SolidKernel.solid(for:block)
        s.select(.body(block.id));XCTAssertTrue(s.matingChoices.contains(.plug));s.makeMatingPart(.plug);await s.matingPartSettled();c.refresh()
        XCTAssertEqual(s.workspace.bodies.count,2)
        let plug=s.workspace.bodies[1],mate=try XCTUnwrap(plug.cuts.last?.thread),plugSolid=try SolidKernel.solid(for:plug)
        XCTAssertFalse(mate.isInternal);XCTAssertEqual(mate.majorDiameter,12);XCTAssertEqual(mate.pitch,1.75);XCTAssertEqual(mate.clearance,0.2);XCTAssertEqual(mate.shape,.iso)
        XCTAssertEqual(try SolidKernel.boolean(blockSolid,plugSolid,.intersect).volume,0,accuracy:0.01)
        cardSection(s,c,offset:-17.5,name:"E11 - engaged internal thread and generated plug")
        try moveBody(s,c,id:plug.id,axis:0,amount:55)
        let moved=try SolidKernel.solid(for:s.workspace.bodies[1]),center=(moved.bounds.min+moved.bounds.max)/2,z=moved.bounds.max.z
        XCTAssertEqual(center.x,80,accuracy:1e-5);XCTAssertEqual(z,11.6,accuracy:1e-5)
        try faceSketch(s,c,at:[Float(center.x),Float(center.y),Float(z)],camera:.alignAt(.top,[center.x,center.y,z]))
        let slot=try recordingSlot(s,c,from:[Float(center.x-4),Float(center.y),Float(z)],to:[Float(center.x+4),Float(center.y),Float(z)],length:8,width:2.5)
        try pointOffset(s,c,fixed:[Float(center.x),Float(center.y),Float(z)],moving:SIMD3<Float>(slot.plane.point(slot.start)),horizontal:4)
        let positioned=try XCTUnwrap(s.workspace.shapes.first { $0.id == slot.id })
        XCTAssertLessThan(simd_distance(positioned.plane.point(positioned.center),[center.x,center.y,z]),1e-5)
        try recordingCut(s,c,shape:positioned,depth:-0.8,through:false)
        let after=try SolidKernel.solid(for:s.workspace.bodies[1]),area=8*2.5+Double.pi*1.25*1.25
        XCTAssertEqual(moved.volume-after.volume,area*0.8,accuracy:0.001);XCTAssertEqual(s.workspace.bodies[0],block)
        XCTAssertTrue(after.contains([center.x,center.y,10.7]));XCTAssertFalse(after.contains([center.x,center.y,10.9]));XCTAssertEqual(z-0.8-10,0.8,accuracy:1e-5)
        cardSection(s,c,offset:-17.5,name:"E11 - blind coin recess and remaining head material")
        try await complete(s,c,document:d,size:[50,35,10],expectedVolume:blockSolid.volume,name:"E11 Coin Drive Plug",additional:[(size:moved.bounds.max-moved.bounds.min,volume:moved.volume-area*0.8)])
    }

    func testRecordingCardE12BottomFilletChamferAndSizeEdit() async throws {
        let (s,c,d,directory)=try await newProject("E12 Bottom Edge Comparison")
        defer { try? FileManager.default.removeItem(at:directory) }
        let base=try rectangle(s,c,from:[0,0,0],to:[24,24,0],width:24,height:24)
        try extrude(s,c,shape:base,depth:12,mode:.newBody);hideSketches(s,c)
        let filletID=s.workspace.bodies[0].id,chamferID=try moveBody(s,c,id:s.workspace.bodies[0].id,axis:0,amount:36,copy:true)
        s.rename(.body(filletID),to:"Bottom Fillet");s.rename(.body(chamferID),to:"Bottom Chamfer")
        for (offset,kind): (Float,EdgeFinish.Kind) in [(0,.fillet),(36,.chamfer)] {
            s.select(nil);s.requestCamera(try faceCamera([30,12,0],normal:[0,0,-1]));c.refresh();s.chooseTool(kind == .fillet ? .fillet : .chamfer);c.refresh()
            for (a,b): (SIMD3<Float>,SIMD3<Float>) in [([offset,0,0],[offset+24,0,0]),([offset+24,0,0],[offset+24,24,0]),([offset+24,24,0],[offset,24,0]),([offset,24,0],[offset,0,0])] {
                try recordingFinishEdge(s,c,from:a,to:b)
            }
            XCTAssertEqual(s.finishDraft?.edges.count,4);XCTAssertTrue(s.applyDimension(3,target:.finishSize(kind)),s.finishError ?? s.status)
            attach(c,"E12 - four bottom edges \(kind.title) 3 preview");s.confirmFinish();hideSketches(s,c)
        }
        let fillet=try SolidKernel.solid(for:s.workspace.bodies[0]),chamfer=try SolidKernel.solid(for:s.workspace.bodies[1])
        XCTAssertTrue(fillet.contains([12,1,1]));XCTAssertFalse(chamfer.contains([48,1,1]));XCTAssertFalse(fillet.contains([12,0.5,0.5]));XCTAssertTrue(chamfer.contains([48,2,2]))
        XCTAssertEqual(chamfer.volume,6912-(48*9-4*27/3),accuracy:0.001);XCTAssertGreaterThan(fillet.volume,chamfer.volume);XCTAssertLessThan(fillet.volume,6912)
        cardSection(s,c,offset:-12,name:"E12 - bottom fillet and chamfer cross sections")
        try await complete(s,c,document:d,size:[24,24,12],expectedVolume:fillet.volume,name:"E12 Bottom Edge Comparison",additional:[(size:[24,24,12],volume:chamfer.volume)])
        let (variant,vc,vd,variantDirectory)=try await newProject("E12 Smaller Chamfer",workspace:s.workspace)
        defer { try? FileManager.default.removeItem(at:variantDirectory) }
        variant.exitSketch();variant.select(.body(filletID));variant.deleteSelection();hideSketches(variant,vc)
        variant.requestCamera(try faceCamera([48,1.5,1.5],normal:[0,-1,-1]));vc.refresh();tap(vc,[48,1.5,1.5])
        let found=await variant.selectedFinishFound();XCTAssertEqual(found?.kind,.chamfer);XCTAssertEqual(found?.size,3)
        XCTAssertTrue(variant.applyDimension(1.5,target:.selectedFinish(.chamfer)));XCTAssertEqual(variant.selectedFinish?.size,1.5)
        attach(vc,"E12 - existing bottom chamfer edited to 1.5")
        let smaller=try SolidKernel.solid(for:variant.workspace.bodies[0])
        XCTAssertTrue(smaller.contains([48,1,1]));XCTAssertFalse(smaller.contains([48,0.5,0.5]))
        variant.requestCamera(.home);vc.refresh()
        try await complete(variant,vc,document:vd,size:[24,24,12],expectedVolume:6912-(48*2.25-4*3.375/3),name:"E12 Smaller Chamfer")
    }

}
