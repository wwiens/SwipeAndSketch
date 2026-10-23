import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// The basic editing tools through the session, canvas, and
/// kernel: Scale, Delete Face, sizes edited from faces, extrude options, the section view, sketch
/// tools, Offset, and the Model Tree.
@MainActor final class BasicsToolTests: CanvasTestCase {
    func bounds(_ body: SolidBody) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try SolidKernel.solid(for: body).bounds }

    /// A Pencil drag through screen points.
    func drag(_ controller: CanvasController, _ points: [CGPoint]) {
        guard let first = points.first else { return }
        controller.pencilBegan(at: first)
        for point in points.dropFirst() { controller.pencilMoved(to: point) }
        controller.pencilEnded(at: points.last!, cancelled: false)
        controller.refresh()
    }

    // MARK: Scale

    func testScaleASolidByDraggingAnArrowAboutItsBase() throws {
        let (session, controller) = boxScene()
        let original = session.workspace.bodies[0]
        session.select(.body(original.id))
        session.chooseTool(.scale)
        controller.refresh()
        XCTAssertEqual(session.tool, .scale)
        XCTAssertEqual(session.scaleDraft?.bodies, [original.id])
        XCTAssertEqual(session.helpTopic, .scale)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "scale.items", recursively: false))
        session.setScalePivot(.base)
        XCTAssertEqual(session.scaleDraft?.center ?? .one, SIMD3(0, 0, 0))
        let widget = try XCTUnwrap(controller.scaleWidget())
        let arrow = try XCTUnwrap(widget.arrows.first { $0.axis == 0 })
        // The box reaches 30 mm along x from the center: dragging the arrow 30 mm doubles it.
        let start = CGPoint(x: (arrow.base.x + arrow.tip.x) / 2, y: (arrow.base.y + arrow.tip.y) / 2)
        let reach = CGFloat(30 * arrow.pointsPerMillimeter)
        drag(controller, (0...6).map { CGPoint(x: start.x + arrow.direction.dx * reach * CGFloat($0) / 6, y: start.y + arrow.direction.dy * reach * CGFloat($0) / 6) })
        XCTAssertEqual(session.scaleDraft?.percents.x ?? 0, 200, accuracy: 2)
        XCTAssertNotNil(session.scalePreview)
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .scalePercent(3) }, "One percentage while uniform")
        attach(controller, "Scale preview")
        XCTAssertTrue(session.applyDimension(150, target: .scalePercent(3)))
        session.confirmScale()
        controller.refresh()
        XCTAssertEqual(session.tool, .select)
        let scaled = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(scaled.id, original.id)
        XCTAssertEqual(try SolidKernel.solid(for: scaled).volume, 48_000 * 3.375, accuracy: 1e-3)
        XCTAssertEqual(try bounds(scaled).min.z, 0, accuracy: 1e-6, "Scaled about its base, it stays on the plate")
        XCTAssertEqual(session.selection, .body(scaled.id))
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0], original)
    }

    func testStretchAlongOneAxisAndRefuseSketchesUnlessUniform() throws {
        let (session, controller) = boxScene()
        let body = session.workspace.bodies[0]
        session.select(.body(body.id))
        session.chooseTool(.scale)
        session.setScaleUniform(false)
        controller.refresh()
        XCTAssertEqual(controller.dimensionAnnotations().filter { if case .scalePercent = $0.target { true } else { false } }.count, 3)
        XCTAssertTrue(session.applyDimension(50, target: .scalePercent(2)))
        session.setScaleCopy(true)
        // The sketch the box came from cannot be stretched.
        let sketch = try XCTUnwrap(session.workspace.sketches.first?.id)
        session.selectItem(.sketch(sketch))
        XCTAssertNil(session.scalePreview)
        XCTAssertTrue(session.hint.hasPrefix("Sketches scale by one percentage"))
        session.selectItem(.sketch(sketch))
        XCTAssertNotNil(session.scalePreview)
        session.confirmScale()
        XCTAssertEqual(session.workspace.bodies.count, 2, "Create Copy keeps the original")
        XCTAssertEqual(try bounds(session.workspace.bodies[1]).max.z - bounds(session.workspace.bodies[1]).min.z, 10, accuracy: 1e-6)
    }

    // MARK: Delete Face

    func testDeleteFaceRemovesAFilletAndHealsTheSolid() throws {
        let (session, controller) = boxScene()
        // Round the top front edge (y = −20, z = 20), then take the fillet off again.
        let body = session.workspace.bodies[0]
        session.chooseTool(.fillet)
        let edge = try XCTUnwrap(controller.finishEdge(at: controller.project(SIMD3(0, -20, 20))))
        session.toggleFinishEdge(bodyID: edge.0, edge: edge.1)
        session.setFinishSize(5)
        session.confirmFinish()
        let rounded = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertLessThan(try SolidKernel.solid(for: rounded).volume, 48_000 - 1)
        controller.refresh()
        // The middle of the fillet's curved face, 45° round from the edge.
        let r = 5.0, on = SIMD3<Float>(0, Float(-20 + r - r * cos(.pi / 4)), Float(20 - r + r * sin(.pi / 4)))
        tap(controller, on)
        let face = try XCTUnwrap(session.selectedFace)
        XCTAssertNil(face.plane, "The fillet is curved")
        XCTAssertFalse(session.canDeleteSelection, "The trash is not offered for a face")
        session.chooseTool(.deleteFace)
        controller.refresh()
        XCTAssertEqual(session.tool, .deleteFace)
        XCTAssertEqual(session.deleteFaceDraft?.faces.count, 1)
        XCTAssertNotNil(session.deleteFacePreview)
        XCTAssertNotNil(controller.previewNode.childNode(withName: "deleteFace.faces", recursively: true))
        XCTAssertEqual(session.helpTopic, .deleteFace)
        attach(controller, "Delete Face preview")
        session.confirmDeleteFace()
        let healed = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(healed.id, body.id)
        XCTAssertEqual(healed.cuts.last?.operation, .deleteFace)
        XCTAssertEqual(try SolidKernel.solid(for: healed).volume, 48_000, accuracy: 1e-3)
        XCTAssertEqual(session.selection, .body(body.id))
        XCTAssertEqual(session.tool, .select)
    }

    // MARK: Sizes from faces

    func testTypingARoundFacesDiameterChangesTheCylinder() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .circle, plane: .top, start: .zero, end: .init(x: 10, y: 0)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        let controller = canvas(session, camera: .reset)
        tap(controller, SIMD3(10 * cos(-.pi / 3), 10 * sin(-.pi / 3), 10))
        let face = try XCTUnwrap(session.selectedFace)
        XCTAssertNil(face.plane)
        XCTAssertEqual(session.selectedFaceSize, .diameter(20, side: 1))
        XCTAssertTrue(session.hint.hasPrefix("Tap its diameter to change it."))
        let label = try XCTUnwrap(controller.dimensionAnnotations().first { $0.target == .faceDiameter })
        XCTAssertEqual(label.text, "Ø 20 mm")
        attach(controller, "Round face diameter")
        session.openDimension(.faceDiameter, at: label.center)
        XCTAssertEqual(session.dimensionEdit?.value, 20)
        XCTAssertTrue(session.applyDimension(30, target: .faceDiameter))
        let body = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertEqual(body.profile.circle?.radius ?? 0, 15, accuracy: 1e-12, "The solid's own circle")
        XCTAssertEqual(session.selectedFaceSize, .diameter(30, side: 1), "The face stays selected")
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].profile.circle?.radius ?? 0, 10, accuracy: 1e-12)
    }

    func testTypingAFlatFacesDistanceWidensTheBox() throws {
        let (session, controller) = boxScene()
        tap(controller, SIMD3(30, 0, 10))
        XCTAssertEqual(session.selectedFace?.plane?.normalAxis ?? .zero, SIMD3(1, 0, 0))
        XCTAssertEqual(session.selectedFaceSize?.value ?? 0, 60, accuracy: 1e-9)
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .faceDistance })
        XCTAssertTrue(session.applyDimension(80, target: .faceDistance))
        let solid = try SolidKernel.solid(for: session.workspace.bodies[0])
        XCTAssertEqual(solid.bounds.max.x, 50, accuracy: 1e-9)
        XCTAssertEqual(solid.bounds.min.x, -30, accuracy: 1e-9)
        XCTAssertTrue(session.workspace.bodies[0].cuts.isEmpty)
        XCTAssertFalse(session.applyDimension(0.001, target: .faceDistance))
    }

    // MARK: Extrude options

    func testSymmetricTaperedExtrusionOfTwoRegions() throws {
        let session = ModelingSession(inMemory: true)
        let left = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -10), end: .init(x: -10, y: 10))
        let right = SketchShape(kind: .circle, plane: .top, start: .init(x: 20, y: 0), end: .init(x: 30, y: 0))
        session.addShape(left)
        session.addShape(right)
        session.select(.shape(left.id))
        let controller = canvas(session)
        session.beginExtrusion()
        controller.refresh()
        // A tap inside the circle extrudes it too.
        tap(controller, SIMD3(20, 0, 0))
        XCTAssertEqual(session.extrusionProfiles.count, 2)
        session.extrusionSymmetric = true
        session.extrusionDepth = 10
        XCTAssertTrue(session.applyDimension(10, target: .extrusionTaper))
        XCTAssertEqual(session.extrusionTaper, 10)
        XCTAssertNotNil(session.extrusionTool, "Options preview the kernel's solid")
        controller.refresh()
        XCTAssertNotNil(controller.previewNode.childNode(withName: "extrusion.preview", recursively: false))
        let handle = try XCTUnwrap(controller.extrusionHandle())
        XCTAssertEqual(handle.face, controller.project(SIMD3(-20, 0, 5)), "The arrow rides on the far end, half the depth up")
        attach(controller, "Symmetric tapered extrusion of two regions")
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 2, "Two regions that do not touch make two solids")
        for body in session.workspace.bodies {
            XCTAssertEqual(body.symmetric, true)
            XCTAssertEqual(body.taper, 10)
            let bounds = try bounds(body)
            XCTAssertEqual(bounds.min.z, -5, accuracy: 1e-6)
            XCTAssertEqual(bounds.max.z, 5, accuracy: 1e-6)
        }
        XCTAssertFalse(session.applyDimension(100, target: .extrusionTaper), "Only while extruding")
    }

    func testUpToAFaceSetsTheDepth() throws {
        let (session, controller) = boxScene()
        // A plane 50 mm up, and a square on the floor beside the box.
        let square = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 40, y: -5), end: .init(x: 50, y: 5))
        session.addShape(square)
        session.select(.shape(square.id))
        session.beginExtrusion()
        controller.refresh()
        session.isPickingExtrusionTarget = true
        tap(controller, SIMD3(0, 0, 20))
        XCTAssertFalse(session.isPickingExtrusionTarget)
        XCTAssertEqual(session.extrusionDepth, 20, accuracy: 1e-9, "Up to the box's top")
        // A side face is not parallel to the sketch.
        session.isPickingExtrusionTarget = true
        XCTAssertFalse(session.extrude(upTo: SIMD3(30, 0, 10), normal: SIMD3(1, 0, 0)))
        session.isPickingExtrusionTarget = false
        session.confirmExtrusion()
        XCTAssertEqual(try bounds(session.workspace.bodies[1]).max.z, 20, accuracy: 1e-9)
    }

    // MARK: Section view

    func testSectionViewCutsTheSolidsOpenAndChangesNothing() throws {
        let (session, controller) = boxScene()
        // A hole through the box, to see inside.
        tap(controller, SIMD3(5, 3, 20))
        session.beginFaceSketch()
        let top = try XCTUnwrap(session.sketchMode?.plane)
        session.addShape(SketchShape(kind: .circle, plane: top, start: top.coordinates(of: .init(0, 0, 20)), end: top.coordinates(of: .init(5, 0, 20))))
        session.exitSketch()
        session.select(.shape(session.workspace.shapes.last!.id))
        session.beginExtrusion()
        session.chooseExtrusionMode(.cut)
        session.cutThroughAll = true
        session.confirmExtrusion()
        let before = session.workspace
        session.toggleSection()
        controller.refresh()
        let section = try XCTUnwrap(session.section)
        XCTAssertEqual(section.orientation, .front)
        XCTAssertEqual(section.offset, 0, accuracy: 1e-9, "Through the middle of the solids")
        XCTAssertEqual(session.helpTopic, .section)
        XCTAssertNotNil(controller.content.childNode(withName: "section.cap", recursively: true), "The cut faces are filled")
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .sectionOffset })
        attach(controller, "Section view")
        XCTAssertTrue(session.applyDimension(-10, target: .sectionOffset))
        session.flipSection()
        session.setSectionOrientation(.right)
        controller.refresh()
        XCTAssertEqual(session.section?.orientation, .right)
        // A tap on the solid picks nothing while looking.
        tap(controller, SIMD3(-10, 0, 20))
        XCTAssertNil(session.selection)
        session.toggleSection()
        XCTAssertNil(session.section)
        XCTAssertEqual(session.workspace, before, "The model is unchanged")
        controller.refresh()
        XCTAssertNil(controller.content.childNode(withName: "section.cap", recursively: true))
    }

    // MARK: Model Tree

    func testRenameColorCopyPasteAndDuplicate() throws {
        let (session, controller) = boxScene()
        let body = session.workspace.bodies[0]
        session.rename(.body(body.id), to: "Base")
        XCTAssertEqual(session.itemGroups.first?.items.first?.name, "Base")
        session.undo()
        XCTAssertEqual(session.itemGroups.first?.items.first?.name, "Body 01", "One undo step")
        session.redo()
        let sketch = try XCTUnwrap(session.workspace.sketches.first)
        session.rename(.sketch(sketch.id), to: "Footprint")
        XCTAssertEqual(session.sketchName(of: sketch.id), "Footprint")
        session.setColor(.orange, of: body.id)
        XCTAssertEqual(session.workspace.bodies[0].color, .orange)
        controller.refresh()
        attach(controller, "Orange body")
        // Duplicate the selected solid: a copy in place, selected, ready to move.
        session.select(.body(body.id))
        XCTAssertTrue(session.canCopy)
        session.duplicate()
        XCTAssertEqual(session.workspace.bodies.count, 2)
        let copy = session.workspace.bodies[1]
        XCTAssertEqual(session.selection, .body(copy.id))
        XCTAssertEqual(copy.color, .orange)
        XCTAssertEqual(session.itemGroups.first?.items.map(\.name), ["Base", "Base (2)"])
        // Copy, then paste into another project.
        session.copy(.body(body.id))
        let other = ModelingSession(inMemory: true)
        XCTAssertTrue(other.canPaste)
        XCTAssertEqual(other.pasteTitle, "Paste Base")
        other.paste()
        XCTAssertEqual(other.workspace.bodies.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: other.workspace.bodies[0]).volume, 48_000, accuracy: 1e-3)
        XCTAssertEqual(other.selection, .body(other.workspace.bodies[0].id))
        ModelClipboard.shared = ModelClipboard()
    }

    func testGroupsOrganizeTheModelTreeAndHideTogether() throws {
        let (session, controller) = boxScene()
        let body = session.workspace.bodies[0].id
        let sketch = try XCTUnwrap(session.workspace.sketches.first).id
        session.select(.body(body))
        let group = try XCTUnwrap(session.newGroup(containing: .body(body)))
        XCTAssertEqual(session.status, "Made Group 01")
        session.rename(.group(group), to: "Lid")
        XCTAssertEqual(session.itemGroups.first?.title, "Groups")
        XCTAssertEqual(session.itemGroups.first?.items.map(\.name), ["Lid", "Body 01"])
        XCTAssertEqual(session.itemGroups.first?.items.map(\.indent), [0, 1])
        XCTAssertEqual(session.itemGroups.first?.items.first?.memberCount, 1)
        XCTAssertFalse(session.itemGroups.contains { $0.title == "Bodies" }, "A grouped solid is listed in its group only")
        // A shape's row moves its whole sketch; dropping a row on a group does the same.
        XCTAssertTrue(session.moveDropped("sketch.\(sketch.uuidString)", toGroup: group))
        XCTAssertEqual(session.workspace.sketches[0].group, group)
        XCTAssertEqual(session.groupChoices(for: .group(group)).count, 0, "A group cannot go into itself")

        // Folding the group away hides its rows, not its items.
        session.toggleGroupCollapsed(group)
        XCTAssertEqual(session.itemGroups.first?.items.map(\.name), ["Lid"])
        XCTAssertEqual(session.visibleWorkspace.bodies.count, 1)
        session.toggleGroupCollapsed(group)

        // The group's eye takes its solid and sketch off the canvas and ends the selection.
        XCTAssertEqual(session.selection, .body(body))
        session.toggleHidden(.group(group))
        XCTAssertNil(session.selection)
        XCTAssertTrue(session.visibleWorkspace.bodies.isEmpty)
        XCTAssertTrue(session.visibleWorkspace.shapes.isEmpty)
        let row = try XCTUnwrap(session.itemGroups.first?.items.first { $0.name == "Body 01" })
        XCTAssertTrue(row.isHiddenByGroup && row.isOffCanvas)
        XCTAssertEqual(row.isHidden, false, "Its own eye is still open")
        controller.refresh()
        attach(controller, "Lid group hidden")
        session.undo()
        XCTAssertEqual(session.visibleWorkspace.bodies.count, 1, "One undo step")
        session.redo()

        // A sketch being edited ends when its group is hidden.
        session.toggleHidden(.group(group))
        session.enterSketch(of: session.workspace.shapes[0].id)
        XCTAssertNotNil(session.sketchMode)
        session.toggleHidden(.group(group))
        XCTAssertNil(session.sketchMode)
        session.toggleHidden(.group(group))

        // Out of its group, back to the Bodies list; then delete the group with what is left in it.
        session.move(.body(body), toGroup: nil)
        XCTAssertEqual(session.itemGroups.first { $0.title == "Bodies" }?.items.map(\.name), ["Body 01"])
        XCTAssertTrue(session.visibleWorkspace.bodies.count == 1)
        session.deleteGroup(group)
        XCTAssertTrue(session.workspace.groups.isEmpty)
        XCTAssertTrue(session.workspace.sketches.isEmpty, "The sketch in it went with it")
        XCTAssertEqual(session.workspace.bodies.count, 1)
        session.undo()
        XCTAssertEqual(session.workspace.groups.count, 1)
        XCTAssertEqual(session.workspace.sketches.count, 1)
        session.ungroup(group)
        XCTAssertTrue(session.workspace.groups.isEmpty)
        XCTAssertEqual(session.workspace.sketches.count, 1, "Ungroup keeps the contents")
    }

    func testPickingSeveralRowsGroupsMovesHidesAndDeletesThem() throws {
        let (session, _) = boxScene()
        let first = session.workspace.bodies[0].id
        session.duplicate(.body(first))
        let second = session.workspace.bodies[1].id
        let sketch = try XCTUnwrap(session.workspace.sketches.first).id
        session.select(.body(first))

        session.beginSelectingRows()
        XCTAssertTrue(session.isSelectingRows)
        XCTAssertEqual(session.pickedTitle, "Select items")
        session.togglePicked(.body(first))
        session.togglePicked(.shape(session.workspace.shapes[0].id))
        XCTAssertTrue(session.isPicked(.sketch(sketch)), "A shape's row picks its sketch")
        XCTAssertEqual(session.pickedTitle, "2 selected")
        XCTAssertEqual(session.selection, .body(first), "The canvas selection is untouched")
        let lid = try XCTUnwrap(session.groupPicked())
        XCTAssertFalse(session.isSelectingRows, "Done once grouped")
        XCTAssertEqual(session.workspace.bodies[0].group, lid)
        XCTAssertEqual(session.workspace.sketches[0].group, lid)
        XCTAssertNil(session.workspace.bodies[1].group)
        XCTAssertEqual(session.status, "Made Group 01 with 2 items")
        session.undo()
        XCTAssertTrue(session.workspace.groups.isEmpty, "One undo step")
        session.redo()

        // Move another solid in; dragging a picked row moves every picked row.
        session.beginSelectingRows()
        session.togglePicked(.body(second))
        XCTAssertEqual(session.pickedGroupChoices.map(\.title), ["Group 01"])
        XCTAssertTrue(session.moveDropped("body.\(second.uuidString)", toGroup: lid))
        XCTAssertEqual(session.workspace.bodies[1].group, lid)
        XCTAssertFalse(session.isSelectingRows)

        // Hide two, then show them; a picked group cannot go into itself.
        session.beginSelectingRows()
        session.togglePicked(.body(first))
        session.togglePicked(.body(second))
        XCTAssertTrue(session.pickedIncludeShown)
        session.setPickedHidden(true)
        XCTAssertTrue(session.visibleWorkspace.bodies.isEmpty)
        XCTAssertNil(session.selection, "The hidden solid's selection ends")
        XCTAssertFalse(session.pickedIncludeShown)
        session.setPickedHidden(false)
        XCTAssertEqual(session.visibleWorkspace.bodies.count, 2)
        session.endSelectingRows()
        session.beginSelectingRows()
        session.togglePicked(.group(lid))
        XCTAssertTrue(session.pickedGroupChoices.isEmpty)
        session.movePicked(toGroup: lid)
        XCTAssertEqual(session.workspace.groups[0].parent, nil)

        // Delete the group with what is in it, then undo.
        session.deletePicked()
        XCTAssertTrue(session.workspace.bodies.isEmpty && session.workspace.groups.isEmpty)
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 2)
    }

    // MARK: Project thumbnails

    /// The color at a point of an image, as 0…1 RGB.
    func color(of image: UIImage, at point: CGPoint) throws -> SIMD3<Double> {
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let x = point.x / image.size.width * CGFloat(cg.width), y = point.y / image.size.height * CGFloat(cg.height)
        context.draw(cg, in: CGRect(x: -x, y: y - CGFloat(cg.height) + 1, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
    }

    /// New Project's templates (October 21, 2026): the gallery's picture of a template is the
    /// thumbnail its new file starts with, and suggested names are made fit for files.
    func testTemplateProjectsStartWithTheirPicture() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("electronics.pi-case"))
        let workspace = try template.workspace(template.defaults)
        let parts = ModelPicture.parts(of: workspace)
        XCTAssertEqual(parts.count, 2, "Case and lid")
        let image = try XCTUnwrap(ModelPicture.image(parts: parts, side: CGFloat(ProjectPreview.side)))
        let shot = XCTAttachment(image: image)
        shot.name = "Template picture"
        shot.lifetime = .keepAlways
        add(shot)
        var project = Project(workspace: workspace)
        project.preview = try XCTUnwrap(image.pngData())
        let data = try ProjectCodec.encode(project)
        XCTAssertNotNil(ProjectPreview.png(in: data), "The thumbnail extension finds it")
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, workspace)
        let middle = try color(of: image, at: CGPoint(x: image.size.width / 2, y: image.size.height / 2))
        let corner = try color(of: image, at: CGPoint(x: 4, y: 4))
        XCTAssertGreaterThan(simd_length(middle - corner), 0.05, "The model is drawn on the canvas color")

        XCTAssertEqual(HomeController.fileName("Raspberry Pi 5 / 4: Case"), "Raspberry Pi 5 - 4- Case")
        XCTAssertEqual(HomeController.fileName("Gridfinity Bin 3×1×6"), "Gridfinity Bin 3×1×6")
        XCTAssertEqual(HomeController.fileName("  "), "Untitled Project")
    }

    func testProjectThumbnailPicturesTheWholeModelForTheBrowser() async throws {
        let (session, controller) = boxScene()
        // Selected and zoomed in on a corner: the picture is still the whole model, from the usual angle.
        session.select(.body(session.workspace.bodies[0].id))
        controller.refresh()
        let image = try XCTUnwrap(session.projectThumbnailProvider?())
        XCTAssertGreaterThanOrEqual(image.size.width * image.scale, 256, "Low resolution is enough")
        let shot = XCTAttachment(image: image)
        shot.name = "Project thumbnail"
        shot.lifetime = .keepAlways
        add(shot)
        let middle = try color(of: image, at: CGPoint(x: image.size.width / 2, y: image.size.height / 2))
        let corner = try color(of: image, at: CGPoint(x: 4, y: 4))
        XCTAssertGreaterThan(simd_length(middle - corner), 0.1, "The solid fills the middle, on the canvas color")
        XCTAssertLessThan(abs(middle.x - middle.z), 0.05, "Gray, not selection blue")

        let empty = ModelingSession(inMemory: true)
        let emptyCanvas = canvas(empty)
        XCTAssertNotNil(empty.projectThumbnailProvider)
        XCTAssertNil(emptyCanvas.projectThumbnail(), "Nothing to picture")

        // The document saves the picture in the file, where the thumbnail extension finds it.
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Box.swipesketch")
        try ProjectCodec.create(Project(workspace: session.workspace), at: url)
        XCTAssertNil(ProjectPreview.png(in: try Data(contentsOf: url)))
        let document = ProjectDocument(fileURL: url)
        let opened = await withCheckedContinuation { continuation in document.open { continuation.resume(returning: $0) } }
        XCTAssertTrue(opened)
        let documentSession = ModelingSession(document: document)
        // The session draws the picture through its canvas (held weakly), so keep the canvas.
        let documentCanvas = canvas(documentSession, camera: .reset)
        let saved = await withCheckedContinuation { continuation in documentSession.save(withThumbnail: true) { continuation.resume(returning: $0) } }
        XCTAssertTrue(saved)
        let closed = await withCheckedContinuation { continuation in document.close { continuation.resume(returning: $0) } }
        XCTAssertTrue(closed)
        let png = try XCTUnwrap(ProjectPreview.png(in: try Data(contentsOf: url)), "Written even though the model did not change")
        let picture = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(picture.size.width * picture.scale, CGFloat(ProjectPreview.side), accuracy: 1)
        XCTAssertLessThan(png.count, 200_000, "Low resolution, small")
        XCTAssertEqual(try ProjectCodec.decode(try Data(contentsOf: url)).workspace, session.workspace, "The model is unchanged")
        withExtendedLifetime(documentCanvas) {}
    }

    // MARK: Sketch tools

    /// A sketch session on Top, looking straight down, with `tool` chosen.
    func topSketch(_ tool: ModelingTool) -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session, camera: .align(.top))
        session.chooseTool(tool)
        controller.refresh()
        return (session, controller)
    }

    func drag(_ controller: CanvasController, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let start = controller.project(a), end = controller.project(b)
        drag(controller, (0...6).map { CGPoint(x: start.x + (end.x - start.x) * CGFloat($0) / 6, y: start.y + (end.y - start.y) * CGFloat($0) / 6) })
    }

    func testPolygonEllipseAndPointToolsDraw() throws {
        let (session, controller) = topSketch(.polygon)
        XCTAssertNotNil(session.sketchMode)
        drag(controller, from: .zero, to: SIMD3(10, 0, 0))
        XCTAssertEqual(session.workspace.shapes.count, 6, "A hexagon of joined lines")
        XCTAssertEqual(Geometry.profiles(in: session.workspace.shapes, on: .top).count, 1)
        let label = try XCTUnwrap(controller.dimensionAnnotations().first { $0.target == .polygonSides })
        XCTAssertEqual(label.text, "6 sides")
        XCTAssertTrue(session.applyDimension(8, target: .polygonSides))
        XCTAssertEqual(session.workspace.shapes.count, 8, "Redrawn with eight sides")
        session.undo()
        XCTAssertTrue(session.workspace.shapes.isEmpty, "Drawing and retyping were one step")
        session.redo()
        session.chooseTool(.ellipse)
        drag(controller, from: SIMD3(40, 0, 0), to: SIMD3(52, 5, 0))
        let ellipse = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(ellipse.kind, .ellipse)
        XCTAssertEqual(ShapeDimension.width.value(of: ellipse), 24, accuracy: 0.5)
        XCTAssertEqual(ShapeDimension.height.value(of: ellipse), 10, accuracy: 0.5)
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .shape(ellipse.id, .height) })
        session.chooseTool(.point)
        tap(controller, SIMD3(-20, 20, 0))
        let point = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(point.kind, .point)
        XCTAssertEqual(point.start, .init(x: -20, y: 20))
        attach(controller, "Polygon, ellipse, and point")
        // The point can be tapped again with no tool.
        session.chooseTool(.select)
        session.select(nil)
        tap(controller, SIMD3(-20, 20, 0))
        XCTAssertEqual(session.selection, .shape(point.id))
    }

    func testConstructionExtendOffsetAndMirrorInASketch() throws {
        let (session, controller) = topSketch(.line)
        drag(controller, from: SIMD3(0, -20, 0), to: SIMD3(0, 20, 0))
        let axis = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(session.selection, .shape(axis.id))
        session.toggleConstruction()
        XCTAssertTrue(session.workspace.shapes[0].isConstruction)
        session.addShape(SketchShape(kind: .rectangle, plane: .top, start: .init(x: 5, y: -5), end: .init(x: 15, y: 5)))
        let rectangle = try XCTUnwrap(session.workspace.shapes.last)
        session.addShape(SketchShape(kind: .line, plane: .top, start: .init(x: 20, y: 0), end: .init(x: 25, y: 0)))
        let stub = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertEqual(session.profiles.count, 1, "The construction line bounds nothing")
        // Mirror the rectangle across the construction line.
        session.select(.shape(rectangle.id))
        session.chooseTool(.sketchMirror)
        controller.refresh()
        XCTAssertEqual(session.sketchMirrorDraft?.shapes, [rectangle.id])
        tap(controller, SIMD3(0, 10, 0))
        XCTAssertEqual(session.sketchMirrorDraft?.line, axis.id)
        session.confirmSketchMirror()
        XCTAssertTrue(session.workspace.shapes.contains { $0.kind == .rectangle && $0.start.x < 0 })
        session.cancelSketchMirror()
        // Extend the stub back to the rectangle (x = 15).
        session.chooseTool(.extend)
        tap(controller, SIMD3(21, 0, 0))
        XCTAssertEqual(session.workspace.shapes.first { $0.id == stub.id }?.start.x ?? 0, 15, accuracy: 1e-6)
        // Offset the rectangle 2 mm out.
        session.chooseTool(.offset)
        controller.refresh()
        tap(controller, SIMD3(15, 2, 0))
        XCTAssertEqual(session.offsetDraft?.shapeID, rectangle.id)
        XCTAssertEqual(session.offsetPreview.count, 4)
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .offsetDistance })
        XCTAssertTrue(session.applyDimension(3, target: .offsetDistance))
        attach(controller, "Offset preview")
        let before = session.workspace.shapes
        session.confirmOffset()
        let added = session.workspace.shapes.filter { shape in !before.contains { $0.id == shape.id } }
        XCTAssertEqual(added.count, 4)
        let xs = added.flatMap { [$0.start.x, $0.end.x] }, ys = added.flatMap { [$0.start.y, $0.end.y] }
        XCTAssertEqual(xs.min() ?? 0, 2, accuracy: 1e-6, "3 mm outside the rectangle")
        XCTAssertEqual(xs.max() ?? 0, 18, accuracy: 1e-6)
        XCTAssertEqual(ys.max() ?? 0, 8, accuracy: 1e-6)
        XCTAssertEqual(Set(added.map(\.sketch)), [rectangle.sketch], "In the rectangle's sketch")
    }

    func testMovingAShapeWithinItsSketch() throws {
        let (session, controller) = topSketch(.circle)
        drag(controller, from: .zero, to: SIMD3(5, 0, 0))
        let circle = try XCTUnwrap(session.workspace.shapes.last)
        session.chooseTool(.select)
        session.select(.shape(circle.id))
        controller.refresh()
        XCTAssertEqual(session.transformWidgetTarget, .shape(circle.id))
        let widget = try XCTUnwrap(controller.transformWidget())
        XCTAssertEqual(Set(widget.arrows.map(\.axis)), [0, 1], "Along the sketch only")
        let arrow = try XCTUnwrap(widget.arrows.first { $0.axis == 0 })
        let start = CGPoint(x: (arrow.base.x + arrow.tip.x) / 2, y: (arrow.base.y + arrow.tip.y) / 2)
        let reach = CGFloat(20 * arrow.pointsPerMillimeter)
        drag(controller, (0...6).map { CGPoint(x: start.x + arrow.direction.dx * reach * CGFloat($0) / 6, y: start.y + arrow.direction.dy * reach * CGFloat($0) / 6) })
        let moved = try XCTUnwrap(session.workspace.shapes.first { $0.id == circle.id })
        XCTAssertEqual(moved.start.x, 20, accuracy: 0.6)
        XCTAssertEqual(ShapeDimension.diameter.value(of: moved), 10, accuracy: 1e-9)
        XCTAssertEqual(session.selection, .shape(circle.id))
    }
}
