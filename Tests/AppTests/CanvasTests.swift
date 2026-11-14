import XCTest
import SwiftUI
import UIKit
import SceneKit
import simd
@testable import SwipeAndSketch

@MainActor final class CanvasTests: XCTestCase {
    /// The overlay is shape layers under the value labels, not a picture the size of the view.
    func testTheOverlayIsDrawnAsLayers() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.select(nil)
        let controller = canvas(session)
        controller.input.redrawOverlayNow()
        let empty = controller.input.overlay.shapeCount
        session.select(.shape(try XCTUnwrap(session.workspace.shapes.first?.id)))
        controller.refresh()
        controller.input.redrawOverlayNow()
        XCTAssertGreaterThan(controller.input.overlay.shapeCount, empty, "The handles and value guides are drawn")
        let shapes = controller.input.overlay.host.sublayers?.compactMap { $0 as? CAShapeLayer }.filter { !$0.isHidden && $0.path != nil } ?? []
        XCTAssertFalse(shapes.isEmpty)
        XCTAssertNil(controller.input.layer.contents, "No backing store")
        XCTAssertEqual(controller.input.layer.sublayers?.first, controller.input.overlay.host, "Under the value labels")
        session.select(nil)
        controller.refresh()
        controller.input.redrawOverlayNow()
        XCTAssertEqual(controller.input.overlay.shapeCount, empty)
        XCTAssertEqual(controller.input.overlay.host.sublayers?.filter { !$0.isHidden }.count, empty, "Unused layers are hidden")
    }

    func testRadialToolbarHasEveryDockToolInBothModes() {
        func tools(_ entries: [ToolbarEntry]) -> Set<ModelingTool> {
            Set(entries.flatMap { entry -> [ModelingTool] in
                switch entry {
                case .tool(let tool): [tool]
                case .group(let group): Array(tools(ToolbarEntry.children(of: group)))
                case .primitives: ToolbarEntry.primitiveTools
                default: []
                }
            })
        }
        let modeling = ToolbarEntry.roots(sketching: false, onFace: false)
        XCTAssertEqual(modeling.map(\.id), ["tool.sketch", "tool.project", "tool.planes", "tool.create", "tool.edges", "tool.combine", "tool.transform", "tool.fit"])
        let modelingGroups: [ToolGroup] = [.planes, .create, .edges, .combine, .transform, .fit]
        XCTAssertEqual(tools(modeling), Set(modelingGroups.flatMap(\.tools) + [.project]))
        let sketch = ToolbarEntry.roots(sketching: true, onFace: false)
        XCTAssertEqual(sketch.map(\.id), ["sketch.exit", "tool.line", "tool.rectangle", "tool.curves", "tool.modify", "tool.dimension", "tool.project"])
        let sketchTools: Set<ModelingTool> = Set(ToolGroup.curves.tools + ToolGroup.modify.tools + [.line, .rectangle, .dimension, .project])
        XCTAssertEqual(tools(sketch), sketchTools)
        let face = ToolbarEntry.roots(sketching: true, onFace: true)
        XCTAssertEqual(tools(face), sketchTools.union(ToolGroup.faceFeatures.tools))
        XCTAssertEqual(face.count, 8)
        for group in ToolGroup.allCases {
            let children = ToolbarEntry.children(of: group)
            XCTAssertEqual(tools(children), Set(group.tools), group.title)
            XCTAssertEqual(Set(children.map(\.id)).count, children.count)
        }
        XCTAssertFalse(ToolbarEntry.children(of: .create).contains(.tool(.box)))
        XCTAssertTrue(ToolbarEntry.children(of: .create).contains(.primitives))
    }

    func testRadialPatternCommandPreviewsWithoutChangingTheDocument() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 15)))
        session.beginExtrusion(); session.extrusionDepth = 10; session.confirmExtrusion()
        let original = session.workspace
        let body = try XCTUnwrap(original.bodies.first)
        session.select(.body(body.id))
        let entry = try XCTUnwrap(ToolbarEntry.children(of: .transform).first { $0 == .tool(.pattern) })
        guard case .tool(let command) = entry else { return XCTFail("Pattern must dispatch the existing tool") }
        session.chooseTool(command)
        session.setPatternDistance(80, axis: 0)
        XCTAssertEqual(session.patternPreview?.bodies.count, 3)
        XCTAssertEqual(session.workspace, original, "A preview never commits to the document")
        session.cancelPattern()
        XCTAssertNil(session.patternPreview)
        XCTAssertEqual(session.workspace, original)
    }

    func testRadialToolbarTargetsAndExpandedBoundsFitWithoutScaling() {
        for count in 3...8 {
            let points = (0..<count).map { RadialToolbarLayout.point(index: $0, count: count, level: 0) }
            for i in points.indices {
                let next = points[(i + 1) % count]
                XCTAssertTrue(abs(points[i].x - next.x) >= 64 || abs(points[i].y - next.y) >= 64,
                              "Accessible targets must not overlap")
            }
        }
        let bounds = CGRect(x: 12, y: 118, width: 1352, height: 826)
        for levels in 1...3 {
            let radius = RadialToolbarLayout.outerRadius(levels - 1)
            XCTAssertTrue(RadialToolbarLayout.fits(levels: levels, in: bounds))
            for requested in [CGPoint(x: -1000, y: -1000), CGPoint(x: 2000, y: 2000), CGPoint(x: 900, y: 650)] {
                let center = RadialToolbarLayout.clamp(requested, radius: radius, in: bounds)
                XCTAssertTrue(bounds.contains(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)))
            }
        }
        XCTAssertFalse(RadialToolbarLayout.fits(levels: 3, in: CGRect(x: 0, y: 0, width: 500, height: 700)))
        XCTAssertFalse(RadialToolbarLayout.fits(levels: 2, in: CGRect(x: 0, y: 0, width: 320, height: 700)))
    }

    func testEveryRadialCaptionStaysInsideItsSector() {
        var configurations: [([ToolbarEntry], Int, Bool)] = [
            (ToolbarEntry.roots(sketching: false, onFace: false), 0, false),
            (ToolbarEntry.roots(sketching: true, onFace: false), 0, false),
            (ToolbarEntry.roots(sketching: true, onFace: true), 0, false),
            (ToolbarEntry.primitiveTools.map(ToolbarEntry.tool), 2, false)
        ]
        for group in ToolGroup.allCases {
            for level in [0, 1] { configurations.append((ToolbarEntry.children(of: group), level, false)) }
        }
        for level in [0, 1] {
            configurations.append(([.primitives] + ToolbarEntry.primitiveTools.map(ToolbarEntry.tool), level, true))
        }
        for (entries, level, compact) in configurations {
            for (index, entry) in entries.enumerated() {
                var subtitles: [String?] = [nil]
                switch entry {
                case .group: subtitles = ["Tools"]
                case .primitives: subtitles = [compact ? "Back to Create" : "Solids"]
                case .tool(.rectangle): subtitles = ["Corners", "Center"]
                case .tool(.slot): subtitles = ["Ends", "Center"]
                default: break
                }
                for subtitle in subtitles {
                    let title = compact && entry == .primitives ? "Back" : entry.title
                    let caption = RadialToolbarCaptionLayout(title: title, subtitle: subtitle,
                                                            index: index, count: entries.count, level: level)
                    let context = "\(entry.id), ring \(level + 1), \(entries.count) sectors"
                    XCTAssertTrue(caption.fits, context)
                    XCTAssertEqual(caption.title.replacingOccurrences(of: "\n", with: " "), title, "No omitted words: " + context)
                    XCTAssertEqual(caption.subtitleFrame != nil, subtitle != nil, context)
                    // Independently sample every component's rectangle, including the inner
                    // edge's midpoint: checking only the caption center misses this regression.
                    let angle = RadialToolbarLayout.angle(index: index, count: entries.count)
                    for frame in caption.visibleFrames {
                        for x in [frame.minX, frame.midX, frame.maxX] {
                            for y in [frame.minY, frame.midY, frame.maxY] {
                                XCTAssertGreaterThanOrEqual(hypot(x, y), RadialToolbarLayout.innerRadius(level) + 2.9, context)
                                XCTAssertLessThanOrEqual(hypot(x, y), RadialToolbarLayout.outerRadius(level) - 2.9, context)
                                let delta = atan2(sin(atan2(y, x) - angle), cos(atan2(y, x) - angle))
                                XCTAssertLessThan(abs(delta), .pi / Double(entries.count) - 0.018, context)
                            }
                        }
                    }
                }
            }
        }
    }

    func testRadialToolbarDragTracksImmediatelySavesOnceAndRollsBackCancellation() {
        let controller = RadialToolbarPlacementController(content: Text("Toolbar"))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let bounds = CGRect(x: 12, y: 118, width: 1352, height: 826)
        let origin = CGPoint(x: 800, y: 500)
        var saves: [CGPoint] = []
        controller.update(content: Text("Toolbar"), center: origin, radius: 136, bounds: bounds, onMove: { saves.append($0) })
        controller.beginMove()
        for offset in 1...200 {
            controller.updateMove(translation: CGPoint(x: -offset, y: -offset / 2))
        }
        XCTAssertEqual(controller.hosting.view.center, CGPoint(x: 600, y: 400), "Each input sample moves the hosted wheel directly")
        XCTAssertTrue(saves.isEmpty, "Live tracking must not trigger preference writes or a workspace redraw")
        controller.endMove(cancelled: false)
        XCTAssertEqual(saves, [CGPoint(x: 600, y: 400)])
        controller.beginMove()
        controller.updateMove(translation: CGPoint(x: 10000, y: 10000))
        XCTAssertEqual(controller.hosting.view.center, CGPoint(x: bounds.maxX - 136, y: bounds.maxY - 136))
        controller.endMove(cancelled: true)
        XCTAssertEqual(controller.hosting.view.center, saves[0], "Cancellation restores the last committed position")
        XCTAssertEqual(saves.count, 1)
        XCTAssertNil(controller.view.hitTest(CGPoint(x: 200, y: 200), with: nil), "The placement container must pass uncovered canvas input through")
        XCTAssertNil(controller.view.hitTest(CGPoint(x: 600 - 135, y: 400 - 135), with: nil), "Even the wheel's rectangular corners pass through")
    }

    func canvas(_ session: ModelingSession) -> CanvasController {
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.refresh()
        return controller
    }

    func cube(_ session: ModelingSession) -> ViewCubeView {
        let view = ViewCubeView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 112, height: 112)
        view.setNeedsLayout(); view.layoutIfNeeded()
        return view
    }

    /// The view cube is Core Animation layers with nothing drawn by the view itself, so turning the
    /// camera rasterizes nothing on the main thread (iPad, November 10, 2026: its Core Graphics
    /// redraw was 0.62 s of a 25 s orbit). It still looks the same: a tile in its axis color.
    func testTheViewCubeIsDrawnAsLayers() throws {
        let session = ModelingSession(inMemory: true)
        let view = cube(session)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func color(at point: CGPoint) -> [Int] {
            let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image.cgImage!, in: CGRect(x: -point.x, y: point.y - view.bounds.height + 1, width: view.bounds.width, height: view.bounds.height))
            return pixel.prefix(3).map(Int.init)
        }
        /// The face's axis color, darkened by the cube's fixed light as the face turns away from it.
        func near(_ a: [Int], _ face: ViewCubeFace) -> Bool {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            face.axis.color.getRed(&r, green: &g, blue: &bl, alpha: &al)
            let light = max(0, simd_dot(face.normal, simd_normalize(SIMD3<Double>(-0.3, -0.4, 1))))
            let shade = 1 - CGFloat(1 - light) * 0.2
            return zip(a, [r, g, bl].map { Int($0 * shade * 255) }).allSatisfy { abs($0 - $1) <= 6 }
        }
        for (face, up) in [(ViewCubeFace.top, SIMD3<Double>(0, 1, 0)), (.front, SIMD3(0, 0, 1)), (.right, SIMD3(0, 0, 1))] {
            view.orientation = ViewOrientation(direction: face.normal, up: up)
            view.layoutIfNeeded(); view.layer.displayIfNeeded()
            XCTAssertNil(view.layer.contents, "\(face): the view draws nothing itself")
            // A point on the tile beside its title: the face's axis color, lightly shaded.
            let tile = view.facePath(face, inset: 0.4).bounds
            let seen = color(at: CGPoint(x: tile.midX, y: tile.minY + 2))
            XCTAssertTrue(near(seen, face), "\(face)'s tile: \(seen)")
        }
        // Turned to a 3D view, the faces seen change with it, and still nothing is drawn by the view.
        view.orientation = ViewOrientation(direction: SIMD3(-0.70, -0.40, 0.59), up: SIMD3(0, 0, 1))
        view.layoutIfNeeded(); view.layer.displayIfNeeded()
        XCTAssertEqual(Set(view.visibleFaces), [.left, .front, .top])
        XCTAssertNil(view.layer.contents)
        XCTAssertNotNil(view.layer.shadowPath, "The body's soft shadow follows it")
        // Each camera frame sets the layers once (moving them made UIKit lay the cube out and set
        // them all again), and keeps the faces' accessibility elements.
        let updates = view.layerUpdates
        let element = try XCTUnwrap(view.accessibilityElements?.first as? NSObject)
        for step in 1...10 {
            let angle = Double(step) * 0.02
            view.orientation = ViewOrientation(direction: SIMD3(-0.70 + angle, -0.40, 0.59), up: SIMD3(0, 0, 1))
            view.layoutIfNeeded(); view.layer.displayIfNeeded()
        }
        XCTAssertEqual(view.layerUpdates, updates + 10)
        XCTAssertTrue(view.accessibilityElements?.first as? NSObject === element)
        XCTAssertEqual((view.accessibilityElements ?? []).compactMap { ($0 as? UIAccessibilityElement)?.accessibilityIdentifier }.sorted(),
                       ["view.cube.front", "view.cube.left", "view.cube.top"])
    }

    func testCubeFacesSelectSketchPlaneAndPencilDrawsFromEitherSide() throws {
        for face in ViewCubeFace.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(.right)
            session.addShape(.init(kind: .rectangle, plane: .right, start: .zero, end: .init(x: 30, y: 20)))
            let controller = canvas(session)
            let cube = cube(session)
            let original = session.workspace
            cube.onFace?(face)
            controller.refresh()
            let direction = -controller.cameraNode.simdWorldFront
            XCTAssertEqual(Double(direction.x), face.normal.x, accuracy: 1e-6)
            XCTAssertEqual(Double(direction.y), face.normal.y, accuracy: 1e-6)
            XCTAssertEqual(Double(direction.z), face.normal.z, accuracy: 1e-6)
            XCTAssertEqual(cube.orientation.face, face)
            XCTAssertEqual(cube.visibleFaces, [face])
            XCTAssertEqual(cube.face(at: CGPoint(x: 56, y: 56)), face)
            XCTAssertEqual(session.plane, face.sketchPlane)
            XCTAssertEqual(session.workspace, original)
            XCTAssertEqual(session.selectedProfile?.plane, .right, "Changing the drawing plane must preserve the selected sketch's extrusion profile")
            XCTAssertTrue(session.canExtrude)
            let up = controller.project(SIMD3(Float(face.up.x), Float(face.up.y), Float(face.up.z)))
            let center = controller.project(.zero)
            XCTAssertLessThan(up.y, center.y, "Camera and cube must agree on up, including the bottom view")
            session.snapEnabled = false
            session.chooseTool(.line); controller.refresh()
            XCTAssertEqual(cube.orientation.face, face, "Choosing a drawing tool must keep the chosen side")
            let a = Point2(x: -15, y: -10), b = Point2(x: 20, y: 15)
            let start = controller.project(face.sketchPlane.world(a)), end = controller.project(face.sketchPlane.world(b))
            controller.pencilBegan(at: start); controller.pencilEnded(at: end, cancelled: false)
            let line = try XCTUnwrap(session.workspace.shapes.last)
            XCTAssertEqual(line.plane, face.sketchPlane)
            XCTAssertEqual(line.start.x, a.x, accuracy: 0.02); XCTAssertEqual(line.start.y, a.y, accuracy: 0.02)
            XCTAssertEqual(line.end.x, b.x, accuracy: 0.02); XCTAssertEqual(line.end.y, b.y, accuracy: 0.02)
        }
    }

    func testCubeTracksFingerOrbitFromTopAndBottomViews() throws {
        let session = ModelingSession(inMemory: true)
        let controller = canvas(session)
        let cube = cube(session)
        let orbit = try XCTUnwrap(controller.input.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first { $0.maximumNumberOfTouches == 1 })
        for face in [ViewCubeFace.top, .bottom] {
            cube.onFace?(face); controller.refresh()
            orbit.setTranslation(CGPoint(x: 45, y: face == .top ? -55 : 55), in: controller.input)
            _ = controller.perform(NSSelectorFromString("orbit:"), with: orbit)
            XCTAssertNil(cube.orientation.face)
            XCTAssertGreaterThan(cube.visibleFaces.count, 1)
            let right = controller.cameraNode.simdWorldRight, up = controller.cameraNode.simdWorldUp, direction = -controller.cameraNode.simdWorldFront
            for (actual, expected) in [(right, cube.orientation.right), (up, cube.orientation.up), (direction, cube.orientation.direction)] {
                XCTAssertEqual(Double(actual.x), expected.x, accuracy: 1e-6)
                XCTAssertEqual(Double(actual.y), expected.y, accuracy: 1e-6)
                XCTAssertEqual(Double(actual.z), expected.z, accuracy: 1e-6)
            }
            for visible in cube.visibleFaces {
                XCTAssertEqual(cube.face(at: cube.project(visible.normal)), visible, "Visible face hit paths must follow the rotating cube")
            }
        }
        XCTAssertTrue(session.workspace.shapes.isEmpty)
    }

    func testCubeResetFramesOffOriginExtrusionAndIgnoresPalmWhilePencilIsActive() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 600, y: -400), end: .init(x: 690, y: -340)))
        session.beginExtrusion(); session.extrusionDepth = -80
        let controller = canvas(session)
        let original = session.workspace
        let cube = cube(session)
        cube.onFace?(.back); controller.refresh()
        XCTAssertEqual(session.plane, .top, "Changing the view during extrusion must keep its source plane")
        XCTAssertNotNil(session.selectedProfile)
        cube.onReset?(); controller.refresh()
        XCTAssertNil(cube.orientation.face)
        XCTAssertEqual(Set(cube.visibleFaces), Set([.top, .front, .right]))
        XCTAssertTrue(session.isExtruding)
        XCTAssertEqual(session.extrusionDepth, -80)
        let profile = try XCTUnwrap(session.selectedProfile)
        for point in profile.outline {
            for depth in [0.0, -80] {
                XCTAssertTrue(controller.view.bounds.insetBy(dx: 100, dy: 90).contains(controller.project(profile.plane.world(point, height: depth))), "Reset should frame the full live extrusion")
            }
        }
        session.cancelExtrusion(); session.chooseTool(.line); controller.refresh()
        controller.pencilBegan(at: CGPoint(x: 450, y: 450))
        let request = session.cameraRequest
        cube.onFace?(.back); cube.onReset?()
        XCTAssertEqual(session.cameraRequest, request, "A resting palm must not activate the cube during a Pencil stroke")
        controller.pencilEnded(at: CGPoint(x: 450, y: 450), cancelled: true)
        cube.onFace?(.back); controller.refresh()
        XCTAssertEqual(session.cameraRequest, request + 1)
        XCTAssertEqual(cube.orientation.face, .back)
        XCTAssertEqual(session.workspace, original)
    }

    func testPencilProjectionRoundTripOnAllPlanes() {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.snapEnabled = false
            session.choosePlane(plane)
            session.chooseTool(.line)
            let controller = canvas(session)
            let a = Point2(x: -20, y: -15), b = Point2(x: 30, y: 25)
            let screenA = controller.project(plane.world(a)), screenB = controller.project(plane.world(b))
            XCTAssertTrue(controller.view.bounds.contains(screenA), "\(plane): \(screenA), bounds \(controller.view.bounds)")
            XCTAssertTrue(controller.view.bounds.contains(screenB), "\(plane): \(screenB)")
            controller.pencilBegan(at: screenA)
            controller.pencilMoved(to: screenB)
            controller.pencilEnded(at: screenB, cancelled: false)
            XCTAssertEqual(session.workspace.shapes.count, 1)
            guard let shape = session.workspace.shapes.first else { continue }
            XCTAssertEqual(shape.start.x, a.x, accuracy: 0.02, "\(plane)")
            XCTAssertEqual(shape.start.y, a.y, accuracy: 0.02, "\(plane)")
            XCTAssertEqual(shape.end.x, b.x, accuracy: 0.02, "\(plane)")
            XCTAssertEqual(shape.end.y, b.y, accuracy: 0.02, "\(plane)")
        }
    }

    func testCancelledPencilStrokeDoesNotCommit() {
        let session = ModelingSession(inMemory: true)
        session.chooseTool(.rectangle)
        let controller = canvas(session)
        let a = controller.project(SketchPlane.top.world(.zero))
        let b = controller.project(SketchPlane.top.world(.init(x: 30, y: 20)))
        controller.pencilBegan(at: a)
        controller.pencilMoved(to: b)
        XCTAssertNotNil(session.preview)
        controller.pencilEnded(at: b, cancelled: true)
        XCTAssertNil(session.preview)
        XCTAssertTrue(session.workspace.shapes.isEmpty)
    }

    func testInterruptedPencilReleasesPalmGuardAndAcceptsNextStroke() {
        let session = ModelingSession(inMemory: true)
        session.chooseTool(.rectangle)
        let controller = canvas(session)
        let original = session.workspace
        let a = controller.project(SketchPlane.top.world(.zero))
        let b = controller.project(SketchPlane.top.world(.init(x: 30, y: 20)))
        controller.pencilBegan(at: a)
        controller.pencilMoved(to: b)
        XCTAssertTrue(session.isPencilDown)
        XCTAssertTrue(session.viewCube.pencilActive)
        XCTAssertNotNil(session.preview)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(session.isPencilDown)
        XCTAssertFalse(session.viewCube.pencilActive)
        XCTAssertFalse(controller.input.pencilActive)
        XCTAssertTrue(controller.input.gestureRecognizers?.allSatisfy(\.isEnabled) == true)
        XCTAssertNil(session.preview)
        XCTAssertEqual(session.workspace, original, "An interruption must roll back rather than commit a partial stroke")
        // Repeated cancellation and a late lift cannot commit the interrupted preview.
        controller.input.cancelActiveStroke()
        controller.pencilEnded(at: b, cancelled: false)
        XCTAssertEqual(session.workspace, original)
        controller.pencilBegan(at: a)
        controller.pencilEnded(at: b, cancelled: false)
        XCTAssertEqual(session.workspace.shapes.count, 1)
        XCTAssertFalse(session.isPencilDown)
    }

    func testRemovingCanvasCancelsPencilAndRestoresControls() throws {
        let session = ModelingSession(inMemory: true)
        session.chooseTool(.rectangle)
        let controller = canvas(session)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = controller.view.bounds
        window.addSubview(controller.view)
        window.isHidden = false
        defer { window.isHidden = true; controller.view.removeFromSuperview() }
        let a = controller.project(SketchPlane.top.world(.zero))
        controller.pencilBegan(at: a)
        controller.pencilMoved(to: CGPoint(x: a.x + 60, y: a.y + 50))
        XCTAssertTrue(session.isPencilDown)
        controller.input.removeFromSuperview()
        XCTAssertFalse(session.isPencilDown)
        XCTAssertFalse(session.viewCube.pencilActive)
        XCTAssertNil(session.preview)
        XCTAssertTrue(session.workspace.shapes.isEmpty)
        // The toolbar/session and view cube can be used again after the interrupted stroke.
        session.chooseTool(.select)
        XCTAssertEqual(session.tool, .select)
        let request = session.cameraRequest
        let viewCube = cube(session)
        viewCube.onFace?(.back)
        XCTAssertEqual(session.cameraRequest, request + 1)
    }

    func testRenderedSketchMatchesInputProjectionOnAllPlanes() throws {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(plane)
            session.addShape(.init(kind: .rectangle, plane: plane, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
            let controller = canvas(session)
            let image = controller.sceneView.snapshot()
            let cgImage = try XCTUnwrap(image.cgImage)
            let width = cgImage.width, height = cgImage.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let edge = controller.project(plane.world(.init(x: -30, y: 0)))
            let x = Int(edge.x * Double(width) / controller.view.bounds.width)
            let y = Int(edge.y * Double(height) / controller.view.bounds.height)
            var blueEdgeFound = false
            for dx in -4...4 {
                for dy in -4...4 {
                    let index = ((max(0, min(height - 1, y + dy)) * width) + max(0, min(width - 1, x + dx))) * 4
                    if Int(pixels[index + 2]) - Int(pixels[index]) > 50 { blueEdgeFound = true }
                }
            }
            XCTAssertTrue(blueEdgeFound, "Rendered edge must match Pencil coordinates on \(plane)")
            let center = controller.project(plane.world(.zero))
            let cx = Int(center.x * Double(width) / controller.view.bounds.width)
            let cy = Int(center.y * Double(height) / controller.view.bounds.height)
            let centerIndex = (cy * width + cx) * 4
            XCTAssertGreaterThan(pixels[centerIndex], 150, "Sketch outlines must stay hollow on \(plane)")
        }
    }

    func testBodyBaseStaysOnEachSketchPlaneForBothDirections() {
        for plane in SketchPlane.allCases {
            for depth in [-20.0, 20.0] {
                let session = ModelingSession(inMemory: true)
                session.choosePlane(plane)
                session.addShape(.init(kind: .rectangle, plane: plane, start: .zero, end: .init(x: 30, y: 20)))
                session.beginExtrusion()
                session.extrusionDepth = depth
                session.confirmExtrusion()
                let controller = canvas(session)
                guard let node = controller.content.childNodes.first(where: { $0.name?.hasPrefix("body|") == true }) else {
                    XCTFail("Missing solid"); continue
                }
                // Rendered face extent along the plane normal (excluding border strokes), whatever the node's local frame.
                guard let (lo, hi) = node.geometry?.boundingBox else { XCTFail("Missing solid faces"); continue }
                let corners = [lo.x, hi.x].flatMap { x in [lo.y, hi.y].flatMap { y in [lo.z, hi.z].map { z in
                    node.simdConvertPosition(SIMD3(Float(x), Float(y), Float(z)), to: nil) } } }
                let distances = corners.map { simd_dot($0, plane.normal) }
                XCTAssertEqual(distances.min() ?? .nan, Float(min(0, depth)), accuracy: 0.001)
                XCTAssertEqual(distances.max() ?? .nan, Float(max(0, depth)), accuracy: 0.001)
            }
        }
    }

    func testRenderedSolidHasDistinctGrayFacesVisibleBordersAndHiddenRearEdges() throws {
        for depth in [-20.0, 20.0] {
            let session = ModelingSession(inMemory: true)
            session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
            session.beginExtrusion()
            session.requestCamera(.home)  // Extruding keeps the view; look from the 3D angle.
            session.extrusionDepth = depth
            session.confirmExtrusion()
            session.select(nil)
            let controller = canvas(session)
            let image = try XCTUnwrap(controller.sceneView.snapshot().cgImage)
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            func sample(_ world: SIMD3<Float>, dx: Int = 0, dy: Int = 0) -> [Int] {
                let point = controller.project(world)
                let x = max(0, min(width - 1, Int(point.x * Double(width) / controller.view.bounds.width) + dx))
                let y = max(0, min(height - 1, Int(point.y * Double(height) / controller.view.bounds.height) + dy))
                let index = (y * width + x) * 4
                return pixels[index..<index + 3].map(Int.init)
            }
            let top = Float(max(0, depth)), middle = Float(depth / 2)
            let faces = [sample(.init(0, 0, top)), sample(.init(30, 0, middle)), sample(.init(0, -20, middle))]
            for color in faces {
                XCTAssertLessThan((color.max() ?? 0) - (color.min() ?? 0), 5, "Faces should be neutral gray: \(faces)")
                XCTAssertGreaterThan(color[0], 50, "Faces should remain readable: \(faces)")
            }
            XCTAssertGreaterThan(faces[0][0] - faces[1][0], 12, "Top and side need distinct shades: \(faces)")
            XCTAssertGreaterThan(faces[1][0] - faces[2][0], 12, "Side and front need distinct shades: \(faces)")
            for edge in [SIMD3<Float>(30, -20, middle), SIMD3<Float>(0, -20, top)] {
                let darkest = (-3...3).flatMap { dx in (-3...3).map { dy in sample(edge, dx: dx, dy: dy)[0] } }.min() ?? 255
                XCTAssertLessThan(darkest, 60, "Visible cap and vertical borders must have dark strokes")
            }
            let hiddenEdge = sample(.init(-30, 20, middle))
            XCTAssertEqual(hiddenEdge[0], faces[0][0], accuracy: 5, "Rear borders must be hidden by the top face")
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Rendered gray solid, depth \(depth)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let border = controller.project(.init(-30.1, -20.05, middle))
            controller.pencilBegan(at: border)
            controller.pencilEnded(at: border, cancelled: false)
            XCTAssertEqual(session.selectedEdge?.bodyID, session.workspace.bodies.first?.id, "A Pencil tap on a border picks that edge, depth \(depth)")
            controller.pencilBegan(at: border)
            controller.pencilEnded(at: border, cancelled: false)
            XCTAssertEqual(session.selection, session.workspace.bodies.first.map { .body($0.id) }, "A quick second tap picks its solid, depth \(depth)")
        }
    }

    func testRenderedCylinderKeepsSmoothSidesAndSilhouetteBordersWhenViewChanges() throws {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(plane)
            session.addShape(.init(kind: .circle, plane: plane, start: .zero, end: .init(x: 20, y: 0)))
            session.beginExtrusion()
            session.requestCamera(.home)  // Extruding keeps the view; look from the 3D angle.
            session.extrusionDepth = -20
            session.confirmExtrusion()
            session.select(nil)
            let controller = canvas(session)
            for alignment in [nil, plane == .front ? SketchPlane.right : .front] {
                if let alignment { session.requestCamera(.align(alignment)); controller.refresh() }
                let image = try XCTUnwrap(controller.sceneView.snapshot().cgImage)
                let width = image.width, height = image.height
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                func sample(_ point: Point2, dx: Int = 0, dy: Int = 0) -> Int {
                    let screen = controller.project(plane.world(point, height: -10))
                    let x = max(0, min(width - 1, Int(screen.x * Double(width) / controller.view.bounds.width) + dx))
                    let y = max(0, min(height - 1, Int(screen.y * Double(height) / controller.view.bounds.height) + dy))
                    return Int(pixels[(y * width + x) * 4])
                }
                let direction = controller.cameraNode.simdWorldFront
                let local = simd_inverse(plane.basis) * SIMD4(direction.x, direction.y, direction.z, 0)
                let angle = atan2(Double(local.y), Double(local.x))
                for side in [-1.0, 1.0] {
                    let a = angle + side * Double.pi / 2
                    let point = Point2(x: cos(a) * 20, y: sin(a) * 20)
                    let darkest = (-3...3).flatMap { dx in (-3...3).map { dy in sample(point, dx: dx, dy: dy) } }.min() ?? 255
                    XCTAssertLessThan(darkest, 60, "Cylinder silhouette must follow camera on \(plane), \(String(describing: alignment))")
                }
                for offset in [-Double.pi / 3, -Double.pi / 6, 0, Double.pi / 6, Double.pi / 3] {
                    let point = Point2(x: cos(angle + offset) * 20, y: sin(angle + offset) * 20)
                    XCTAssertGreaterThan(sample(point), 60, "A smooth cylindrical side must not have segment strokes")
                }
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "Cylinder shaded edges \(plane), \(String(describing: alignment))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testDimensionsAndUndoRetainIndependentBody() {
        let session = ModelingSession(inMemory: true)
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 60, y: 40))
        session.addShape(shape)
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.selection = .shape(shape.id)
        session.updateDimensions(first: 75, second: 50)
        XCTAssertEqual(session.workspace.shapes[0].end, .init(x: 75, y: 50))
        XCTAssertEqual(session.workspace.bodies[0].profile.outline[2], .init(x: 60, y: 40))
        session.undo()
        XCTAssertEqual(session.workspace.shapes[0].end, .init(x: 60, y: 40))
        XCTAssertEqual(session.workspace.bodies.count, 1)
        session.redo()
        XCTAssertEqual(session.workspace.shapes[0].end, .init(x: 75, y: 50))
    }
    func testDimensionButtonsAppearBesideSelectedGeometryAndOpenEditorOnAllPlanes() throws {
        for plane in SketchPlane.allCases {
            for kind in ShapeKind.drawn where kind != .point {   // a point has no size to show
                let session = ModelingSession(inMemory: true)
                session.choosePlane(plane)
                let a = Point2(x: -20, y: -10), b = Point2(x: 20, y: 15)
                let shape = switch kind {
                case .arc: try XCTUnwrap(SketchShape.arc(from: a, through: .init(x: 0, y: 25), to: b, plane: plane))
                case .slot: SketchShape.slot(from: a, to: b, width: 6, plane: plane)
                case .ellipse: SketchShape(kind: .ellipse, plane: plane, start: a, end: b, width: 8)
                default: SketchShape(kind: kind, plane: plane, start: a, end: b)
                }
                session.addShape(shape)
                let controller = canvas(session)
                let dimension: ShapeDimension = kind == .line || kind == .slot ? .length : kind == .circle ? .diameter : kind == .arc ? .radius : .width
                let button = try XCTUnwrap(controller.input.dimensionButton(for: .shape(shape.id, dimension)))
                XCTAssertTrue(controller.view.bounds.intersects(button.frame))
                button.sendActions(for: .touchUpInside)
                XCTAssertEqual(session.dimensionEdit?.target, .shape(shape.id, dimension))
                XCTAssertEqual(session.dimensionEdit?.value, dimension.value(of: shape))
                XCTAssertEqual(session.dimensionEdit?.anchor, button.center)
            }
        }
    }

    func testPencilDragsRectangleCornerAndEdgeWithLiveDimensionsOnAllPlanes() throws {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(plane)
            session.snapEnabled = false
            let shape = SketchShape(kind: .rectangle, plane: plane, start: .zero, end: .init(x: 30, y: 20))
            session.addShape(shape)
            let added = session.workspace.shapes[0]
            let controller = canvas(session)
            let from = controller.project(plane.world(shape.end)), to = controller.project(plane.world(.init(x: 40, y: 25)))
            controller.pencilBegan(at: from)
            controller.pencilMoved(to: to)
            XCTAssertEqual(session.workspace.shapes[0], added, "Dragging is a preview until Pencil lifts")
            XCTAssertEqual(session.dimensionValue(.shape(shape.id, .width)), 40)
            controller.pencilEnded(at: to, cancelled: false)
            XCTAssertEqual(session.workspace.shapes[0].end.x, 40, accuracy: 0.001)
            controller.refresh()
            let side = controller.project(plane.world(.init(x: 40, y: 12.5)))
            let sideTo = controller.project(plane.world(.init(x: 45, y: 12.5)))
            controller.pencilBegan(at: side)
            controller.pencilEnded(at: sideTo, cancelled: false)
            XCTAssertEqual(session.workspace.shapes[0].end.x, 45, accuracy: 0.001)
            XCTAssertEqual(session.workspace.shapes[0].end.y, 25, accuracy: 0.001)
            session.undo()
            XCTAssertEqual(session.workspace.shapes[0].end.x, 40, accuracy: 0.001)
            session.undo()
            XCTAssertEqual(session.workspace.shapes[0], added, "Each drag is exactly one undo step")
        }
    }

    func testPencilCircleCircumferenceAndCenterDragging() throws {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(plane)
            session.snapEnabled = false
            let circle = SketchShape(kind: .circle, plane: plane, start: .zero, end: .init(x: 10, y: 0))
            session.addShape(circle)
            let controller = canvas(session)
            let from = controller.project(plane.world(.init(x: 0, y: 10)))
            let to = controller.project(plane.world(.init(x: 0, y: 15)))
            controller.pencilBegan(at: from)
            controller.pencilEnded(at: to, cancelled: false)
            XCTAssertEqual(session.dimensionValue(.shape(circle.id, .diameter)) ?? 0, 30, accuracy: 0.001)
            controller.refresh()
            let center = controller.project(plane.world(.zero))
            let movedCenter = controller.project(plane.world(.init(x: -5, y: -5)))
            controller.pencilBegan(at: center)
            controller.pencilEnded(at: movedCenter, cancelled: false)
            XCTAssertEqual(session.workspace.shapes[0].start.x, -5, accuracy: 0.001)
            XCTAssertEqual(session.workspace.shapes[0].start.y, -5, accuracy: 0.001)
            XCTAssertEqual(session.dimensionValue(.shape(circle.id, .diameter)) ?? 0, 30, accuracy: 0.001)
        }
    }

    /// A tap on a circle drifts a few points; it selects the circle without resizing it, even with
    /// snapping on (user report, October 23, 2026).
    func testPencilTapOnACircleDoesNotResizeIt() throws {
        for selected in [true, false] {
            let session = ModelingSession(inMemory: true)
            let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 10.3, y: 0))
            session.addShape(circle)
            if !selected { session.selection = nil }
            let controller = canvas(session)
            let edge = controller.project(SketchPlane.top.world(.init(x: 0, y: 10.3)))
            let drift = CGPoint(x: edge.x + 4, y: edge.y + 5)
            controller.pencilBegan(at: edge)
            controller.pencilMoved(to: drift)
            controller.pencilEnded(at: drift, cancelled: false)
            XCTAssertEqual(session.selection, .shape(circle.id))
            XCTAssertEqual(session.dimensionValue(.shape(circle.id, .diameter)) ?? 0, 20.6, accuracy: 0.001)
            XCTAssertEqual(session.workspace.shapes[0].end, circle.end, "Nothing moved")
        }
    }

    func testPencilLineEndpointDragKeepsLoopJoinedAndCanCancel() throws {
        let session = ModelingSession(inMemory: true)
        session.snapEnabled = false
        let a = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 20, y: 0))
        let b = SketchShape(kind: .line, plane: .top, start: a.end, end: .init(x: 10, y: 20))
        let c = SketchShape(kind: .line, plane: .top, start: b.end, end: a.start)
        [a, b, c].forEach { session.addShape($0) }
        let original = session.workspace.shapes
        session.selection = .shape(a.id)
        let controller = canvas(session)
        let from = controller.project(SketchPlane.top.world(a.end)), to = controller.project(SketchPlane.top.world(.init(x: 30, y: 5)))
        controller.pencilBegan(at: from)
        controller.pencilMoved(to: to)
        controller.pencilEnded(at: to, cancelled: true)
        XCTAssertEqual(session.workspace.shapes[0], original[0])
        controller.pencilBegan(at: from)
        controller.pencilEnded(at: to, cancelled: false)
        XCTAssertEqual(session.workspace.shapes[0].end, session.workspace.shapes[1].start)
        XCTAssertEqual(session.profiles.count, 1)
        session.undo()
        XCTAssertEqual(session.workspace.shapes[0], original[0])
        XCTAssertEqual(session.workspace.shapes[1], original[1])
        session.selection = .shape(a.id)
        controller.refresh()
        let startFrom = controller.project(SketchPlane.top.world(a.start))
        let startTo = controller.project(SketchPlane.top.world(.init(x: -5, y: -5)))
        controller.pencilBegan(at: startFrom)
        controller.pencilEnded(at: startTo, cancelled: false)
        XCTAssertEqual(session.workspace.shapes[0].start, session.workspace.shapes[2].end)
        XCTAssertEqual(session.workspace.shapes[0].start.x, -5, accuracy: 0.001)
        XCTAssertEqual(session.profiles.count, 1)
    }

    func testPencilEndpointDragSnapsToOtherGeometry() throws {
        let session = ModelingSession(inMemory: true)
        let a = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 20, y: 0))
        let b = SketchShape(kind: .line, plane: .top, start: .init(x: 40.5, y: 10.25), end: .init(x: 50, y: 20))
        session.addShape(a); session.addShape(b)
        session.selection = .shape(a.id)
        let controller = canvas(session)
        controller.pencilBegan(at: controller.project(SketchPlane.top.world(a.end)))
        controller.pencilEnded(at: controller.project(SketchPlane.top.world(.init(x: 40.4, y: 10.3))), cancelled: false)
        XCTAssertEqual(session.workspace.shapes[0].end, b.start)
    }

    func testIndividualDimensionAndBodyDepthEditsValidateAndUndo() throws {
        let session = ModelingSession(inMemory: true)
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 30, y: 20))
        session.addShape(rectangle)
        XCTAssertTrue(session.applyDimension(45, target: .shape(rectangle.id, .width)))
        XCTAssertEqual(session.workspace.shapes[0].end, .init(x: 45, y: 20))
        XCTAssertFalse(session.applyDimension(0, target: .shape(rectangle.id, .height)))
        session.beginExtrusion()
        XCTAssertTrue(session.applyDimension(-15, target: .extrusion))
        session.confirmExtrusion()
        let body = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertTrue(session.applyDimension(25, target: .bodyDepth(body.id)))
        XCTAssertEqual(session.workspace.bodies[0].depth, 25)
        session.undo()
        XCTAssertEqual(session.workspace.bodies[0].depth, -15)
    }

    func testExtrusionDoubleArrowAndDepthLabelLayoutOnEveryPlane() throws {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(plane)
            session.addShape(.init(kind: .rectangle, plane: plane, start: .init(x: -20, y: -10), end: .init(x: 20, y: 10)))
            session.beginExtrusion()
            session.requestCamera(.home)  // Extruding keeps the view; look from the 3D angle.
            let controller = canvas(session)
            for depth in [3.0, -3.0, 30.0, -30.0] {
                session.extrusionDepth = depth
                controller.refresh()
                let handle = try XCTUnwrap(controller.extrusionHandle())
                // The double-arrow follows the sketch normal as it appears on screen.
                let profile = try XCTUnwrap(session.selectedProfile)
                let face = controller.project(plane.world(profile.center, height: depth))
                let ahead = controller.project(plane.world(profile.center, height: depth + 10))
                let expected = CGVector(dx: ahead.x - face.x, dy: ahead.y - face.y)
                let length = hypot(expected.dx, expected.dy)
                XCTAssertEqual(handle.axis.dx, expected.dx / length, accuracy: 1e-6, "\(plane)")
                XCTAssertEqual(handle.axis.dy, expected.dy / length, accuracy: 1e-6, "\(plane)")
                XCTAssertEqual(hypot(handle.top.x - handle.center.x, handle.top.y - handle.center.y), 17, accuracy: 1e-6)
                XCTAssertEqual(handle.top.x - handle.center.x, handle.center.x - handle.bottom.x, accuracy: 1e-6)
                XCTAssertTrue(handle.hitArea.contains(handle.top))
                XCTAssertTrue(handle.hitArea.contains(handle.bottom))
                let dimension = try XCTUnwrap(controller.dimensionAnnotations().first)
                XCTAssertEqual(dimension.target, .extrusion)
                XCTAssertEqual(dimension.value, depth)
                XCTAssertLessThanOrEqual(abs(dimension.angle), .pi / 2 + 0.001, "Labels never read upside down")
                if plane == .top { XCTAssertEqual(dimension.angle, -.pi / 2, accuracy: 0.001, "Top extrusions keep the upright arrow and label") }
                let button = try XCTUnwrap(controller.input.dimensionButton(for: .extrusion))
                let offset = CGVector(dx: button.center.x - handle.top.x, dy: button.center.y - handle.top.y)
                XCTAssertGreaterThan(offset.dx * handle.axis.dx + offset.dy * handle.axis.dy, 10, "Label sits past the outward arrowhead")
                XCTAssertEqual(offset.dx * handle.axis.dy - offset.dy * handle.axis.dx, 0, accuracy: 0.5)
                XCTAssertEqual(button.layer.borderWidth, 2)
            }
        }
    }

    func testWorldAxesUseBrandColorsOnEveryPlane() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 15
        session.confirmExtrusion()
        session.select(nil)
        let controller = canvas(session)
        for plane in SketchPlane.allCases {
            session.choosePlane(plane)
            controller.refresh()
            for axis in WorldAxis.allCases {
                let node = try XCTUnwrap(controller.gridNode.childNode(withName: "axis.\(axis.rawValue)", recursively: false), "\(axis) on \(plane)")
                let (low, high) = node.boundingBox
                let extent = SIMD3<Float>(high) - SIMD3<Float>(low)
                // Along its own world direction from the origin, whatever the sketch plane.
                XCTAssertGreaterThan(simd_dot(extent, axis.direction), 100)
                XCTAssertLessThan(simd_length(extent - axis.direction * simd_dot(extent, axis.direction)), 5)
                XCTAssertGreaterThan(simd_dot(SIMD3<Float>(high), axis.direction), 100, "Points along +\(axis)")
                XCTAssertLessThan(simd_dot(SIMD3<Float>(low), axis.direction), 1)
                let drawn = try XCTUnwrap(node.geometry?.firstMaterial?.diffuse.contents as? UIColor)
                XCTAssertEqual(rgb(drawn), rgb(axis.color))
                XCTAssertFalse(node.geometry?.firstMaterial?.writesToDepthBuffer ?? true, "Background, behind solids")
            }
            XCTAssertNotNil(controller.gridNode.childNode(withName: "axis.y.casing", recursively: false), "Lime is cased in Graphite")
        }
        XCTAssertEqual(rgb(WorldAxis.x.color), [0xFF, 0x80, 0x66], "Coral")
        XCTAssertEqual(rgb(WorldAxis.y.color), [0xDF, 0xFF, 0x70], "Lime")
        XCTAssertEqual(rgb(WorldAxis.z.color), [0x6D, 0x3D, 0xF5], "Violet")
        session.requestCamera(.reset)
        controller.refresh()
        let cubeView = cube(session)
        let images = [
            ("Axes in 3D", UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in controller.sceneView.snapshot().draw(in: controller.view.bounds) }),
            ("View cube axes", UIGraphicsImageRenderer(bounds: cubeView.bounds).image { cubeView.layer.render(in: $0.cgContext) })
        ]
        for (name, image) in images {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func rgb(_ color: UIColor) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { Int(($0 * 255).rounded()) }
    }

    func testExtrusionPencilUpAndDownCrossesZeroOnEveryPlane() throws {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(plane)
            session.snapEnabled = false
            session.addShape(.init(kind: .rectangle, plane: plane, start: .init(x: -20, y: -10), end: .init(x: 20, y: 10)))
            session.beginExtrusion()
            let controller = canvas(session)
            let first = try XCTUnwrap(controller.extrusionHandle())
            let up = CGPoint(x: first.top.x + first.axis.dx * 60, y: first.top.y + first.axis.dy * 60)
            controller.pencilBegan(at: first.top)
            controller.pencilMoved(to: up)
            XCTAssertGreaterThan(session.extrusionDepth, 5, "Dragging out along the arrow deepens from 0 on \(plane)")
            let liveValue = session.extrusionDepth
            controller.refresh()
            XCTAssertEqual(controller.dimensionAnnotations().first?.value, liveValue)
            controller.pencilEnded(at: up, cancelled: false)
            XCTAssertTrue(session.workspace.bodies.isEmpty)
            XCTAssertTrue(session.applyDimension(3, target: .extrusion))
            controller.refresh()
            let second = try XCTUnwrap(controller.extrusionHandle())
            let down = CGPoint(x: second.bottom.x - second.axis.dx * 120, y: second.bottom.y - second.axis.dy * 120)
            controller.pencilBegan(at: second.bottom)
            controller.pencilEnded(at: down, cancelled: false)
            XCTAssertLessThan(session.extrusionDepth, 0, "Dragging back along the arrow passes through the sketch plane on \(plane)")
            let negative = session.extrusionDepth
            controller.refresh()
            let negativeHandle = try XCTUnwrap(controller.extrusionHandle())
            XCTAssertEqual(negativeHandle.axis.dx, first.axis.dx, accuracy: 1e-6, "The arrow keeps its direction below zero")
            XCTAssertEqual(negativeHandle.axis.dy, first.axis.dy, accuracy: 1e-6)
            session.confirmExtrusion()
            XCTAssertEqual(session.workspace.bodies.first?.depth, negative)
        }
    }

    func testExtrusionSidewaysMotionDoesNotChangeDepth() throws {
        for plane in SketchPlane.allCases {
            let session = ModelingSession(inMemory: true)
            session.choosePlane(plane)
            session.addShape(.init(kind: .circle, plane: plane, start: .zero, end: .init(x: 10, y: 0)))
            session.beginExtrusion()
            let controller = canvas(session)
            let handle = try XCTUnwrap(controller.extrusionHandle())
            controller.pencilBegan(at: handle.center)
            // Across the arrow, not along it.
            controller.pencilEnded(at: CGPoint(x: handle.center.x - handle.axis.dy * 200, y: handle.center.y + handle.axis.dx * 200), cancelled: false)
            XCTAssertEqual(session.extrusionDepth, 0, "Still on the plane, with nothing to make")
            XCTAssertFalse(session.canConfirmExtrusion)
        }
    }

    /// Extruding keeps the view the user was looking from (October 21, 2026).
    func testExtrudingACircleKeepsTheView() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .circle, plane: .top, start: .zero, end: .init(x: 10, y: 0)))
        let controller = canvas(session)
        session.chooseCubeFace(.front)
        controller.refresh()
        let request = session.cameraRequest, before = controller.project(SIMD3(10, 0, 0))
        session.beginExtrusion()
        controller.refresh()
        XCTAssertTrue(session.isExtruding)
        XCTAssertEqual(session.cameraRequest, request, "No camera move")
        let after = controller.project(SIMD3(10, 0, 0))
        XCTAssertEqual(after.x, before.x, accuracy: 0.5)
        XCTAssertEqual(after.y, before.y, accuracy: 0.5)
    }

    func testCanceledExtrusionDragAndDepthKeypadShareLiveState() throws {
        let session = ModelingSession(inMemory: true)
        session.snapEnabled = false
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 30, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 3
        let controller = canvas(session)
        let handle = try XCTUnwrap(controller.extrusionHandle())
        let up = CGPoint(x: handle.center.x, y: handle.center.y - 60)
        controller.pencilBegan(at: handle.center)
        controller.pencilMoved(to: up)
        XCTAssertGreaterThan(session.extrusionDepth, 3)
        controller.pencilEnded(at: up, cancelled: true)
        XCTAssertEqual(session.extrusionDepth, 3)
        controller.refresh()
        let button = try XCTUnwrap(controller.input.dimensionButton(for: .extrusion))
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(session.dimensionEdit?.value, 3)
        XCTAssertTrue(session.applyDimension(-6, target: .extrusion))
        XCTAssertEqual(session.extrusionDepth, -6)
        session.cancelExtrusion()
        controller.refresh()
        XCTAssertNil(controller.extrusionHandle())
        XCTAssertNil(controller.input.dimensionButton(for: .extrusion))
        XCTAssertTrue(session.workspace.bodies.isEmpty)
        session.undo()
        XCTAssertTrue(session.workspace.shapes.isEmpty, "Canceled extrusion must not add history entries")
    }


    /// On screen, the overlay maps through the camera SceneKit last drew, so corner dots and
    /// handles never run ahead of a model that is slow to draw: a camera change moves them only
    /// once a frame with that camera is drawn.
    func testOverlayFollowsTheFrameSceneKitDrew() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        let controller = canvas(session)
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let corner = SIMD3<Float>(30, 20, 0)
        func spin(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        controller.sceneView.setNeedsDisplay()
        var drawn = controller.project(corner)
        spin { controller.project(corner) != drawn }
        drawn = controller.project(corner)
        session.requestCamera(.align(.front))
        controller.refresh()
        XCTAssertEqual(controller.project(corner), drawn, "Until SceneKit draws the new view, the overlay stays with the old frame")
        spin { controller.project(corner) != drawn }
        let followed = controller.project(corner)
        XCTAssertNotEqual(followed, drawn, "Once drawn, the overlay follows")
        controller.view.removeFromSuperview()
        let live = controller.project(corner)
        XCTAssertEqual(followed.x, live.x, accuracy: 0.5, "The drawn camera is the camera as set")
        XCTAssertEqual(followed.y, live.y, accuracy: 0.5)
    }

    /// On screen, a curved solid's outline is redrawn off the main thread after the view turns,
    /// so turning a detailed model never waits for it.
    func testOutlinesFollowTheViewWithoutBlockingIt() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 15, y: 0)))
        session.beginExtrusion()
        session.extrusionDepth = 30
        session.confirmExtrusion()
        let controller = canvas(session)
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.refresh()
        let id = try XCTUnwrap(session.workspace.bodies.first?.id)
        func outline() -> SCNNode? {
            controller.content.childNode(withName: "body|" + id.uuidString, recursively: false)?
                .childNode(withName: "body.edges", recursively: false)?.childNode(withName: "body.silhouettes", recursively: false)
        }
        let before = try XCTUnwrap(outline(), "A cylinder has an outline")
        session.requestCamera(.align(.front))
        controller.refresh()
        XCTAssertTrue(outline() === before, "The turn does not wait for the outline")
        let deadline = Date().addingTimeInterval(3)
        while outline() === before && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(outline() === before, "It catches up")
        XCTAssertNotNil(outline()?.geometry)
    }
}
