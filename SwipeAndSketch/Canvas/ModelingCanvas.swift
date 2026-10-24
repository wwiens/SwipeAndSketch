import SwiftUI
import SceneKit
import simd

struct ModelingCanvas: UIViewControllerRepresentable {
    @ObservedObject var session: ModelingSession
    func makeUIViewController(context: Context) -> CanvasController { CanvasController(session: session) }
    func updateUIViewController(_ controller: CanvasController, context: Context) { controller.refresh() }
}

extension SketchPlane {
    /// Rendering transform: sketch (u, v, height) to world, including the plane's origin.
    var basis: simd_float4x4 {
        let x = SIMD3<Float>(xAxis), y = SIMD3<Float>(yAxis), n = SIMD3<Float>(normalAxis), o = SIMD3<Float>(origin)
        return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(n, 0), SIMD4(o, 1)))
    }
    var normal: SIMD3<Float> { SIMD3<Float>(normalAxis) }
    /// World position of a point `height` above the plane, for placing plane-aligned nodes.
    func position(height: Double) -> SIMD3<Float> { SIMD3<Float>(origin) + normal * Float(height) }
    func world(_ point: Point2, height: Double = 0) -> SIMD3<Float> {
        let v = basis * SIMD4(Float(point.x), Float(point.y), Float(height), 1)
        return .init(v.x, v.y, v.z)
    }
    func local(_ point: SIMD3<Float>) -> Point2 {
        let v = simd_inverse(basis) * SIMD4(point.x, point.y, point.z, 1)
        return .init(x: Double(v.x), y: Double(v.y))
    }
}

/// World axis indicators on the canvas and view cube, in the Swipe & Sketch palette: X Coral,
/// Y Lime, Z Violet. Lime is too light to read as a thin line on the light canvas, so it is
/// drawn over a Graphite casing.
enum WorldAxis: String, CaseIterable {
    case x, y, z
    var direction: SIMD3<Float> {
        switch self { case .x: SIMD3(1, 0, 0); case .y: SIMD3(0, 1, 0); case .z: SIMD3(0, 0, 1) }
    }
    var color: UIColor {
        switch self {
        case .x: UIColor(named: "ss-coral") ?? UIColor(red: 1, green: 0.5, blue: 0.4, alpha: 1)
        case .y: UIColor(named: "ss-lime") ?? UIColor(red: 0.87, green: 1, blue: 0.44, alpha: 1)
        case .z: UIColor(named: "ss-violet") ?? UIColor(red: 0.43, green: 0.24, blue: 0.96, alpha: 1)
        }
    }
    var isCased: Bool { self == .y }
    static let casing = UIColor(named: "ss-ink") ?? UIColor(red: 0.15, green: 0.13, blue: 0.22, alpha: 1)
}

struct CanvasDimension {
    var target: DimensionTarget
    var value: Double
    var center: CGPoint
    var angle: CGFloat = 0
    var baseline: (CGPoint, CGPoint)?
    var extensions: [(CGPoint, CGPoint)] = []
    /// The unit lengths are shown in (angles are always degrees).
    var unit = LengthUnit.millimeters
    var text: String {
        let prefix = target.accessibilityName.hasSuffix("diameter") && target.accessibilityName != "hole.diameter" && target.accessibilityName != "peg.diameter" &&
            target.accessibilityName != "thread.diameter" ? "Ø " : ["radius", "finish.radius"].contains(target.accessibilityName) ? "R " : ""
        if target.unit == "%" { return formatted(value) + " %" }
        if target == .polygonSides { return "\(Int(value.rounded())) sides" }
        if case .primitiveSize = target {
            // Which size it is: W, L, H, Ø, or the torus's Tube Ø.
            let name = target.title
            let mark = name == "Diameter" ? "Ø " : name == "Tube" ? "Tube Ø " : String(name.prefix(1)) + " "
            return mark + formatted(length: value, unit: unit) + " " + unit.symbol
        }
        return target.isLength ? prefix + formatted(length: value, unit: unit) + " " + unit.symbol : prefix + formatted(value) + "°"
    }
    var font: UIFont { target.isOperationValue ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 14) }
    var labelSize: CGSize {
        CGSize(width: max(target.isOperationValue ? 36 : 48, (text as NSString).size(withAttributes: [.font: font]).width + 14),
               height: target.isOperationValue ? 22 : 24)
    }
}

/// The blue double-arrow. `axis` is the on-screen unit direction of increasing value: for an
/// extrusion, the sketch plane's normal as it appears on screen, so dragging toward a solid
/// moves the end face into it. `top` is the arrowhead in that direction.
struct ExtrusionHandle {
    var origin: CGPoint
    var face: CGPoint
    var center: CGPoint
    var axis = CGVector(dx: 0, dy: -1)
    var top: CGPoint { CGPoint(x: center.x + axis.dx * 17, y: center.y + axis.dy * 17) }
    var bottom: CGPoint { CGPoint(x: center.x - axis.dx * 17, y: center.y - axis.dy * 17) }
    var hitArea: CGRect { CGRect(x: center.x - 29, y: center.y - 29, width: 58, height: 58) }
    /// Rotation that turns the upright glyph and label to the axis.
    var angle: CGFloat { atan2(axis.dx, -axis.dy) }
}

/// The blue curved double-arrow of a revolve: it rides on the circle the region's center sweeps,
/// at the end face, pointing the way the angle increases. `arc` is that stretch of the circle on
/// screen (straight when the circle is seen edge-on); `perDegree` is how far the Pencil moves along
/// `axis` per degree there.
struct RevolveHandle {
    var center: CGPoint
    var axis: CGVector
    var arc: [CGPoint]
    var perDegree: Double
    var hitArea: CGRect { CGRect(x: center.x - 29, y: center.y - 29, width: 58, height: 58) }
    /// The straight double-arrow stand-in that places the value label past the outward arrowhead.
    var labelAnchor: ExtrusionHandle {
        let tip = arc.last ?? center
        return ExtrusionHandle(origin: center, face: center, center: CGPoint(x: tip.x - axis.dx * 17, y: tip.y - axis.dy * 17), axis: axis)
    }
}

private struct CameraTransition {
    var from: ViewOrientation
    var to: ViewOrientation
    var fromTarget: SIMD3<Float>
    var toTarget: SIMD3<Float>
    var fromHeight: Double
    var toHeight: Double
    var start = CACurrentMediaTime()
}

/// Geometry made off the main thread and handed to it once, never touched by both.
private struct SharedGeometry: @unchecked Sendable { let geometry: SCNGeometry; init(_ geometry: SCNGeometry) { self.geometry = geometry } }

@MainActor private final class CameraAnimationDriver: NSObject {
    weak var controller: CanvasController?
    init(_ controller: CanvasController) { self.controller = controller }
    @objc func step(_ link: CADisplayLink) {
        if let controller { controller.advanceCameraAnimation() } else { link.invalidate() }
    }
}

@MainActor final class CanvasController: UIViewController, UIGestureRecognizerDelegate {
    let session: ModelingSession
    let sceneView = SCNView()
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let content = SCNNode()
    let gridNode = SCNNode()
    let previewNode = SCNNode()
    var input: PencilInputView!
    private var lastWorkspace: Workspace?
    private var lastSelection: ModelSelection?
    private var lastExtraSelection: [ModelSelection] = []
    /// The last sketch line tap that added a whole sketch to the picked items, so the second tap of
    /// a double-tap (the usual way to pick a whole sketch) does not take it out again.
    private var lastPickTap: (sketchID: UUID, time: CFTimeInterval, point: CGPoint)?
    private var lastPlane: SketchPlane?
    private var lastIsExtruding: Bool?
    private var lastFinishDraft: FinishDraft?
    private var lastLengthUnit = LengthUnit.millimeters
    private var draggingFinish = false
    private var draggingShell = false
    /// An Offset Plane drag: starting offset, on-screen axis, and scale captured at Pencil down.
    private var planeGesture: (start: Double, axis: CGVector, pointsPerMillimeter: Double)?
    /// An Align offset drag: the same, along the target's normal or axis.
    private var alignGesture: (start: Double, axis: CGVector, pointsPerMillimeter: Double)?
    /// A Move/Rotate widget drag: its handle, the screen direction (moves) or center (turns), and
    /// the scale captured at Pencil down so the moving sketch or solid cannot change the drag.
    private var transformGesture: (handle: TransformHandle, direction: CGVector, pointsPerMillimeter: Double,
                                   center: CGPoint, lastAngle: CGFloat, turned: CGFloat, toward: Double)?
    /// The Pencil is dragging a solid's widget center to a new place on the solid.
    private var draggingPivot = false
    /// A Pattern gizmo drag: as a Move/Rotate drag, plus the distance or angle it started from.
    private var patternGesture: (handle: TransformHandle, direction: CGVector, pointsPerMillimeter: Double,
                                 center: CGPoint, lastAngle: CGFloat, turned: CGFloat, toward: Double, start: Double)?
    private var draggingPatternCenter = false
    /// A polygon being drawn: its center, on the sketch plane.
    private var polygonStroke: (center: Point2, plane: SketchPlane)?
    /// A Scale gizmo drag: the arrow, its screen direction and scale, the percentage it started
    /// from, and how far the items reach from the center along it (millimeters).
    private var scaleGesture: (axis: Int, direction: CGVector, pointsPerMillimeter: Double, start: Double, reach: Double)?
    /// Where a solid's widget center can snap, until the solid changes.
    private var pivotSnapCache: [UUID: (body: SolidBody, points: [TransformPivot], edges: [[SIMD3<Double>]])] = [:]
    private var shellStartThickness = 2.0
    private var finishStartSize = 1.0
    private var lastCameraRequest = -1
    private var gestures: [UIGestureRecognizer] = []
    private var target = SIMD3<Float>(repeating: 0)
    private var yaw: Float = -.pi / 3
    private var elevation: Float = .pi / 2
    private var orthographicHeight: Double = 160
    private var alignedFace: ViewCubeFace? = .top
    private var viewDirection = SIMD3<Double>(0, 0, 1)
    private var viewRight = SIMD3<Double>(1, 0, 0)
    private var viewUp = SIMD3<Double>(0, 1, 0)
    private var cameraTransition: CameraTransition?
    /// The camera of the frame SceneKit last drew (see `screenCamera`).
    private var renderedCamera: ScreenCamera?
    /// A curved-face outline update is being computed, and the view has turned since it started.
    private var silhouettesInFlight = false
    private var silhouettesStale = false
    private var cameraDisplayLink: CADisplayLink?
    private var cameraLayoutSize = CGSize.zero
    private var activeShape: SketchShape?
    private var pencilStartScreen = CGPoint.zero
    private var draggingExtrusion = false
    /// An operation the selection's arrow started at Pencil-down; a cancelled touch ends it again.
    private var operationStartedAtDown: ModelingTool?
    /// The zoom the content's edge strokes were last built for.
    private var contentZoom: Double = 1
    /// Counts content rebuilds, so answers about the solids can be kept until they change.
    private var contentVersion = 0
    /// Times the scene's content was built from scratch (tests check a drag does not).
    private(set) var contentRebuilds = 0
    /// The solid drawn as a moved picture of another (itself, or the original it copies) while the
    /// Move/Rotate widget drags it, and that original as its node was built.
    private var draggedGhost: (id: UUID, source: SolidBody)?
    private var visibility: (camera: ScreenCamera, content: Int, answers: [SIMD3<Double>: Bool])?
    private var extrusionStartDepth = 0.0
    private var extrusionPointsPerMillimeter = 1.0
    private var extrusionDragAxis = CGVector(dx: 0, dy: -1)
    /// A revolve angle drag: the starting angle, on-screen direction, and points per degree, captured at Pencil down.
    private var revolveGesture: (start: Double, axis: CGVector, perDegree: Double)?
    /// The last revolve preview tool drawn, so a refresh without a change reuses its geometry.
    private var revolveToolNode: (tool: KernelSolid, cut: Bool, node: SCNNode, borders: [(SIMD3<Float>, SIMD3<Float>)])?
    private var lastRevolveKey: String?
    /// Corners of each solid, for Align's point picking, until the solid changes.
    private var alignCornerCache: [UUID: (body: SolidBody, corners: [SIMD3<Double>])] = [:]
    private var strokePlane: SketchPlane?
    /// The previous face tap, for double-tap-to-select-the-solid.
    /// Two Pencil taps this close in time and place are a double-tap.
    static let doubleTapInterval: CFTimeInterval = 0.45
    static let doubleTapDistance: CGFloat = 24
    /// How far the Pencil must travel before a press on a sketch handle drags it; a tap drifts a few
    /// points (and snapping would then jump the size to the nearest grid value).
    static let sketchDragSlop: CGFloat = 10
    private var lastFaceTap: (bodyID: UUID, time: CFTimeInterval, point: CGPoint)?
    private var lastSketchTap: (sketchID: UUID, time: CFTimeInterval, point: CGPoint)?
    /// A sketch line under the Pencil at touch-down; it becomes `lastSketchTap` only if the Pencil
    /// lifts without moving, so dragging the same line twice is never a double-tap.
    private var pendingSketchTap: (sketchID: UUID, time: CFTimeInterval, point: CGPoint)?
    private var lastSketchMode: SketchMode?
    /// Project's previous item tap (a sketch or a solid), for double-tap-to-pick-all-of-it. Kept
    /// apart from taps made with no tool, so a tap made before Project never pairs with one inside it.
    private var lastProjectionTap: (sketchID: UUID?, bodyID: UUID?, time: CFTimeInterval, point: CGPoint)?
    /// The live snap while a stroke or drag is in progress, for drawing dashed alignment guides.
    private(set) var liveSnap: (result: SnapResult, plane: SketchPlane)?
    /// Center of a rectangle being drawn from its center.
    private var strokeCenter: Point2?
    /// An arc stroke: where it started and the points the Pencil passed (the arc's middle is the one
    /// farthest from the chord).
    private var strokeStart: Point2?
    private var strokePoints: [Point2] = []
    /// A Trim stroke is in progress: where it started and whether it has passed over a shape.
    private var trimming = false
    private var trimStart: CGPoint?
    private var trimTouchedShape = false
    /// The previous Measure tap on a face, for double-tap-to-measure-the-solid.
    private var lastMeasureTap: (bodyID: UUID, face: Int, time: CFTimeInterval, point: CGPoint)?

    /// The next tap starts afresh, never the second half of a double-tap.
    func forgetTaps() {
        lastFaceTap = nil; lastSketchTap = nil; lastProjectionTap = nil; lastMeasureTap = nil
    }
    private var strokeStarted = false
    private var sketchDrag: (shape: SketchShape, handle: SketchHandle, offset: Point2)?
    private var dragMoved = false
    private let blue = UIColor(red: 0.12, green: 0.29, blue: 1, alpha: 1)
    private let edgeGray = UIColor(white: 0.09, alpha: 1)
    private let cutRed = UIColor(red: 0.92, green: 0.26, blue: 0.2, alpha: 0.3)
    /// Kernel solids are derived from document bodies once and reused across zoom, orbit, and selection.
    /// Two entries per body: its committed form and a fillet/chamfer preview of it.
    private var solidCache: [UUID: [(body: SolidBody, render: SolidRender?)]] = [:]
    /// How many solids have been meshed for display (tests check a drag meshes none).
    private(set) var solidRenderBuilds = 0
    /// The section view's cut solids (nil when nothing is left on the kept side) and their cut faces.
    private var sectionCache: [UUID: (body: SolidBody, section: SectionView, render: SolidRender?, caps: [Int])] = [:]
    /// The section plane's offset drag: where it started, the screen direction, scale, and sign.
    private var sectionGesture: (start: Double, axis: CGVector, pointsPerMillimeter: Double, sign: Double)?
    /// Cut faces in the section view: Swipe Coral, so they stand apart from the gray solids.
    private let sectionCap = UIColor(red: 1, green: 0.5, blue: 0.4, alpha: 0.95)

    /// Built on the main thread. Its geometry is immutable; only the outline worker reads it off
    /// the main thread (`silhouettes`), and the edge caches are touched on the main thread only.
    private final class SolidRender: @unchecked Sendable {
        let faces: SCNGeometry
        let borders: [[SIMD3<Float>]]
        /// Original extrusion edge carried by each border, if any (fillet-created edges have none).
        let borderNames: [ExtrusionEdge?]
        /// The kernel edge index of each border.
        let borderEdges: [Int]
        let silhouettes: KernelSilhouettes
        /// Edge tubes as last built, without color: the borders once, and the outline for a view.
        /// Their thickness is set on the GPU (`strokeShader`), so zooming never rebuilds them, and a
        /// selection change only recolors them (rebuilding is slow for imported parts with
        /// thousands of edges).
        var borderGeometry: SCNGeometry?
        var silhouetteGeometry: (view: SIMD3<Float>, geometry: SCNGeometry)?
        /// World-space triangle corners, three per triangle, for occlusion ray casts.
        let triangles: [SIMD3<Float>]
        /// The sketch plane of the flat B-rep face each triangle belongs to (nil on curved faces).
        let trianglePlanes: [SketchPlane?]
        /// The B-rep face index of each triangle.
        let triangleFaces: [Int]
        /// Each face's span of `triangles` and its bounding box, so a ray cast skips faces it misses.
        let faceSpans: [(range: Range<Int>, low: SIMD3<Double>, high: SIMD3<Double>)]
        init(_ solid: KernelSolid, _ mesh: KernelMesh, body: SolidBody, material: SCNMaterial) {
            triangles = mesh.indices.map { mesh.positions[Int($0)] }
            var planes = [SketchPlane?](repeating: nil, count: mesh.triangleCount)
            var owners = [Int](repeating: 0, count: mesh.triangleCount)
            for (face, range) in mesh.faces.enumerated() { for triangle in range.lowerBound / 3..<range.upperBound / 3 { owners[triangle] = face } }
            triangleFaces = owners
            let corners = triangles
            faceSpans = mesh.faces.compactMap { range in
                guard !range.isEmpty, range.upperBound <= corners.count else { return nil }
                var low = SIMD3<Double>(corners[range.lowerBound]), high = low
                for i in range { let p = SIMD3<Double>(corners[i]); low = simd_min(low, p); high = simd_max(high, p) }
                return (range, low, high)
            }
            for range in mesh.faces where !range.isEmpty {
                let corners = mesh.indices[range].map { Int($0) }
                let normal = mesh.normals[corners[0]]
                guard corners.allSatisfy({ simd_dot(mesh.normals[$0], normal) > 0.99999 }) else { continue }
                let plane = SketchPlane.through(SIMD3<Double>(mesh.positions[corners[0]]), normal: SIMD3<Double>(normal))
                for triangle in range.lowerBound / 3..<range.upperBound / 3 { planes[triangle] = plane }
            }
            trianglePlanes = planes
            faces = KernelSceneGeometry(mesh, faceMaterial: material).faces
            let visible = mesh.edges.indices.filter { mesh.edges[$0].isBoundary }
            borders = visible.map { mesh.edges[$0].points }
            borderEdges = visible
            borderNames = body.edgeNames(visible, of: solid)
            silhouettes = KernelSilhouettes(mesh)
        }
    }

    init(session: ModelingSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.thumbnailProvider = { [weak self] in self?.thumbnailPNG() }
        session.projectThumbnailProvider = { [weak self] in self?.projectThumbnail() }
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.scene = scene
        // The brand's canvas color (Assets.xcassets); geometry keeps its modeling colors.
        sceneView.backgroundColor = UIColor(named: "ss-canvas") ?? UIColor(white: 0.94, alpha: 1)
        sceneView.accessibilityElementsHidden = true
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = false
        sceneView.isUserInteractionEnabled = false
        sceneView.autoenablesDefaultLighting = false
        view.addSubview(sceneView)
        scene.rootNode.addChildNode(content)
        scene.rootNode.addChildNode(gridNode)
        scene.rootNode.addChildNode(previewNode)
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 200_000
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        sceneView.delegate = self

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 650
        // A fixed studio light separates the top, front, and side faces as the model turns.
        key.position = SCNVector3(4, 2, 8)
        key.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(key)

        input = PencilInputView(controller: self)
        input.frame = view.bounds
        input.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        input.backgroundColor = .clear
        input.isMultipleTouchEnabled = true
        input.accessibilityIdentifier = "modeling.canvas"
        input.isAccessibilityElement = false
        input.accessibilityLabel = "Modeling canvas. Apple Pencil draws and selects. Fingers orbit, pan, and zoom."
        view.addSubview(input)

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:)))
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        gestures = [orbit, pan, pinch]
        for gesture in gestures {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.cancelsTouchesInView = false
            gesture.requiresExclusiveTouchType = false
            gesture.delegate = self
            input.addGestureRecognizer(gesture)
        }
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if cameraLayoutSize != view.bounds.size {
            finishCameraTransition()
            cameraLayoutSize = view.bounds.size
            updateCamera()
            rebuildGrid()
        }
        input.updateDimensions(dimensionAnnotations())
        input.setNeedsDisplay()
    }

    func refresh() {
        guard isViewLoaded else { return }
        if session.cameraRequest != lastCameraRequest {
            lastCameraRequest = session.cameraRequest
            switch session.cameraAction {
            case .align(let plane): align(to: plane)
            case .alignAt(let plane, let point): align(to: plane, target: SIMD3<Float>(point))
            case .face(let face): lookAt(face)
            case .home:
                finishCameraTransition()
                alignedFace = nil
                yaw = -.pi / 3
                elevation = .pi / 5
                // Center the selected profile without discarding the current zoom.
                if let profile = session.revolveDraft?.profile ?? session.extrusionProfile { target = profile.plane.world(profile.center) }
                updateCamera()
            case .reset: reset3DView()
            }
        }
        // The amber source of a revolve depends on what is revolved, not on the angle being dragged.
        let revolveKey = (session.revolveDraft.map { "\($0.profiles.map(\.id).joined())|\($0.face?.face ?? -1)" } ?? "") + session.extraExtrusionProfiles.map(\.id).joined() +
            (session.section.map { "|section \($0.orientation.normalAxis) \($0.flipped) \($0.offset)" } ?? "") +
            (session.xrayAll ? "|xray" : session.xrayBodies.isEmpty ? "" : "|xray " + session.xrayBodies.map(\.uuidString).sorted().joined())
        let othersChanged = lastSelection != session.selection || lastExtraSelection != session.extraSelection || lastPlane != session.plane || lastIsExtruding != session.isExtruding ||
            lastFinishDraft != session.finishDraft || lastSketchMode != session.sketchMode || lastRevolveKey != revolveKey
        if !othersChanged, lastWorkspace != session.visibleWorkspace, moveDraggedGhost() {
            lastWorkspace = session.visibleWorkspace
            lastFaceTap = nil
            lastSketchTap = nil
        } else if lastWorkspace != session.visibleWorkspace || othersChanged {
            // The grid depends only on the sketch plane (and camera, handled elsewhere), so live
            // previews such as an extrusion drag rebuild the solids but not the grid.
            let gridChanged = lastPlane != session.plane || lastSketchMode != session.sketchMode
            if lastWorkspace != session.visibleWorkspace {
                // A double-tap never spans a change to the model.
                lastFaceTap = nil
                lastSketchTap = nil
            }
            lastSketchMode = session.sketchMode
            lastWorkspace = session.visibleWorkspace
            lastSelection = session.selection
            lastExtraSelection = session.extraSelection
            lastPlane = session.plane
            lastIsExtruding = session.isExtruding
            lastRevolveKey = revolveKey
            lastFinishDraft = session.finishDraft
            rebuildContent()
            if gridChanged { rebuildGrid() }
        }
        if lastLengthUnit != session.lengthUnit {
            // Inch and millimeter grids space their lines differently.
            lastLengthUnit = session.lengthUnit
            rebuildGrid()
        }
        rebuildPreview()
        input.updateDimensions(dimensionAnnotations())
        input.setNeedsDisplay()
    }

    private var unitsPerPoint: Double { orthographicHeight / max(1, Double(view.bounds.height)) }

    /// Looks straight at a sketch plane. World planes center on the origin; face planes keep the
    /// current view center (projected onto the face) unless a target on the face is given.
    private func align(to plane: SketchPlane, target newTarget: SIMD3<Float>? = nil) {
        // An animation still running would leave its zoom half way (and the grid and edges sized for it).
        finishCameraTransition()
        alignedFace = .facing(plane)
        if let newTarget { target = newTarget }
        else if plane.isWorldPlane { target = plane.world(.zero) }
        else { target = plane.world(plane.local(target)) }
        let n = plane.normalAxis
        elevation = Float(asin(max(-1, min(1, n.z))))
        yaw = abs(n.z) > 0.9999 ? -.pi / 2 : Float(atan2(n.y, n.x))
        updateCamera()
    }

    private func lookAt(_ face: ViewCubeFace) {
        finishCameraTransition()
        alignedFace = face
        elevation = Float(asin(face.normal.z))
        yaw = abs(face.normal.z) > 0.9 ? -.pi / 2 : Float(atan2(face.normal.y, face.normal.x))
        updateCamera(animated: true)
    }

    private func reset3DView() {
        finishCameraTransition()
        alignedFace = nil
        yaw = -.pi / 3
        elevation = .pi / 5
        var points = session.visibleWorkspace.shapes.flatMap { shape in shape.outline.map { shape.plane.world($0) } }
        func corners(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> [SIMD3<Float>] {
            [bounds.min.x, bounds.max.x].flatMap { x in [bounds.min.y, bounds.max.y].flatMap { y in
                [bounds.min.z, bounds.max.z].map { z in SIMD3<Float>(Float(x), Float(y), Float(z)) } } }
        }
        for body in session.visibleWorkspace.bodies {
            // The built solid, so joined bosses, unions, and revolves count; its sketch extrusion if it cannot build.
            if let solid = try? SolidKernel.solid(for: body) { points += corners(solid.bounds); continue }
            guard !body.isImported, body.revolve == nil else { continue }
            points += body.profile.outline.flatMap { [body.profile.plane.world($0), body.profile.plane.world($0, height: body.depth)] }
        }
        if session.isExtruding, let profile = session.extrusionProfile {
            points += profile.outline.map { profile.plane.world($0, height: session.extrusionDepth) }
        }
        if let tool = session.revolveTool { points += corners(tool.bounds) }
        guard let first = points.first else { updateCamera(animated: true, target: .zero, height: 160); return }
        let minimum = points.reduce(first) { simd_min($0, $1) }, maximum = points.reduce(first) { simd_max($0, $1) }
        let center = (minimum + maximum) / 2
        let orientation = requestedOrientation()
        var halfWidth = 0.0, halfHeight = 0.0
        for point in points {
            let delta = point - center
            let offset = SIMD3(Double(delta.x), Double(delta.y), Double(delta.z))
            halfWidth = max(halfWidth, abs(simd_dot(offset, orientation.right)))
            halfHeight = max(halfHeight, abs(simd_dot(offset, orientation.up)))
        }
        let height = Double(max(1, view.bounds.height))
        let usableWidth = Double(max(200, view.bounds.width - 390)), usableHeight = max(200, height - 250)
        let fit = max(20, min(20_000, max(halfHeight * 2 * height / usableHeight, halfWidth * 2 * height / usableWidth) * 1.15))
        updateCamera(animated: true, target: center, height: fit)
    }

    private func requestedOrientation() -> ViewOrientation {
        if let alignedFace { return ViewOrientation(direction: alignedFace.normal, up: alignedFace.up) }
        return ViewOrientation(direction: SIMD3(Double(cos(elevation) * cos(yaw)), Double(cos(elevation) * sin(yaw)), Double(sin(elevation))), up: .init(0, 0, 1))
    }

    private func updateCamera(animated: Bool = false, target newTarget: SIMD3<Float>? = nil, height newHeight: Double? = nil) {
        let orientation = requestedOrientation()
        let destinationTarget = newTarget ?? target, destinationHeight = newHeight ?? orthographicHeight
        cameraDisplayLink?.invalidate(); cameraDisplayLink = nil; cameraTransition = nil
        if animated && view.window != nil && !UIAccessibility.isReduceMotionEnabled {
            cameraTransition = CameraTransition(from: ViewOrientation(direction: viewDirection, up: viewUp), to: orientation,
                                                fromTarget: target, toTarget: destinationTarget,
                                                fromHeight: orthographicHeight, toHeight: destinationHeight)
            let driver = CameraAnimationDriver(self)
            let link = CADisplayLink(target: driver, selector: #selector(CameraAnimationDriver.step(_:)))
            cameraDisplayLink = link
            link.add(to: .main, forMode: .common)
        } else {
            target = destinationTarget; orthographicHeight = destinationHeight
            applyCamera(orientation)
            if newHeight != nil { rebuildGrid(); rebuildContent() }
        }
    }

    fileprivate func advanceCameraAnimation() {
        guard let transition = cameraTransition else { return }
        let progress = min(1, (CACurrentMediaTime() - transition.start) / 0.28)
        if progress >= 1 { finishCameraTransition(); return }
        let eased = progress * progress * (3 - 2 * progress)
        target = transition.fromTarget + (transition.toTarget - transition.fromTarget) * Float(eased)
        orthographicHeight = transition.fromHeight + (transition.toHeight - transition.fromHeight) * eased
        applyCamera(ViewOrientation(rotation: simd_slerp(transition.from.rotation, transition.to.rotation, Float(eased))))
    }

    private func finishCameraTransition() {
        guard let transition = cameraTransition else { return }
        cameraDisplayLink?.invalidate(); cameraDisplayLink = nil; cameraTransition = nil
        target = transition.toTarget; orthographicHeight = transition.toHeight
        applyCamera(transition.to)
        rebuildGrid(); rebuildContent()
    }

    private func applyCamera(_ orientation: ViewOrientation) {
        let previousDirection = viewDirection
        let distance: Float = 50_000
        viewDirection = orientation.direction; viewRight = orientation.right; viewUp = orientation.up
        let direction = SIMD3(Float(viewDirection.x), Float(viewDirection.y), Float(viewDirection.z))
        cameraNode.simdPosition = target + direction * distance
        cameraNode.simdOrientation = orientation.rotation
        // SceneKit's orthographicScale is half the visible vertical span.
        cameraNode.camera?.orthographicScale = orthographicHeight / 2
        session.viewCube.update(orientation)
        if simd_length(previousDirection - viewDirection) > 1e-6 { scheduleSilhouettes() }
        input?.updateDimensions(dimensionAnnotations())
        input?.setNeedsDisplay()
    }

    /// Curved faces' outlines follow the view. On screen they are computed off the main thread, one
    /// update at a time (the newest view wins), so turning a detailed model never waits for them:
    /// they catch up a moment later. Off screen (tests), at once.
    private func scheduleSilhouettes() {
        guard view.window != nil else { updateSilhouettes(); return }
        if silhouettesInFlight { silhouettesStale = true; return }
        startSilhouettes()
    }

    private func startSilhouettes() {
        silhouettesInFlight = true
        silhouettesStale = false
        let view = SIMD3(Float(viewDirection.x), Float(viewDirection.y), Float(viewDirection.z))
        let ghosts = session.previewGhosts
        let jobs = session.visibleWorkspace.bodies.filter { ghosts[$0.id] == nil }
            .compactMap { body in solidRender(body).flatMap { $0.silhouettes.isEmpty ? nil : (body.id, $0) } }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = jobs.map { id, render in
                (id, render, SharedGeometry(Self.strokeGeometry(render.silhouettes.segments(viewDirection: view))))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applySilhouettes(results, view: view) }
            }
        }
    }

    private func applySilhouettes(_ results: [(UUID, SolidRender, SharedGeometry)], view: SIMD3<Float>) {
        silhouettesInFlight = false
        for (id, render, shared) in results {
            render.silhouetteGeometry = (view, shared.geometry)
            // The solid changed meanwhile (an undo, a kept change): its outline is not this one.
            guard let body = session.visibleWorkspace.bodies.first(where: { $0.id == id }), solidRender(body) === render,
                  let edges = content.childNode(withName: "body|" + id.uuidString, recursively: false)?
                .childNode(withName: "body.edges", recursively: false) else { continue }
            edges.childNode(withName: "body.silhouettes", recursively: false)?.removeFromParentNode()
            let node = coloredNode(shared.geometry, color: session.selectedBody?.id == id ? blue : edgeGray)
            node.name = "body.silhouettes"
            edges.addChildNode(node)
        }
        if silhouettesStale { startSilhouettes() }
    }

    private func updateSilhouettes() {
        let ghosts = session.previewGhosts
        for body in session.visibleWorkspace.bodies where ghosts[body.id] == nil {
            let render = solidRender(body)
            guard render.map({ !$0.silhouettes.isEmpty }) ?? (body.profile.circle != nil && body.revolve == nil),
                  let node = content.childNode(withName: "body|" + body.id.uuidString, recursively: false) else { continue }
            let color = session.selectedBody?.id == body.id ? blue : edgeGray
            if let render, let edges = node.childNode(withName: "body.edges", recursively: false) {
                // Only the outline of curved faces follows the view; the borders stay as built.
                edges.childNode(withName: "body.silhouettes", recursively: false)?.removeFromParentNode()
                edges.addChildNode(silhouetteNode(render, color: color))
                continue
            }
            node.childNode(withName: "body.edges", recursively: false)?.removeFromParentNode()
            node.addChildNode(render.map { kernelEdges($0, color: color) } ?? bodyEdges(body.profile, depth: abs(body.depth), color: color))
        }
    }

    @objc private func orbit(_ gesture: UIPanGestureRecognizer) {
        guard !input.pencilActive else { return }
        finishCameraTransition()
        closeDimensionEdit()
        let d = gesture.translation(in: input)
        gesture.setTranslation(.zero, in: input)
        if alignedFace != nil {
            alignedFace = nil
            elevation = max(-.pi / 2 + 0.02, min(.pi / 2 - 0.02, elevation))
        }
        yaw -= Float(d.x) * 0.008
        elevation = max(-.pi / 2 + 0.02, min(.pi / 2 - 0.02, elevation + Float(d.y) * 0.008))
        updateCamera()
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !input.pencilActive else { return }
        finishCameraTransition()
        closeDimensionEdit()
        let d = gesture.translation(in: input)
        gesture.setTranslation(.zero, in: input)
        let right = cameraNode.simdWorldRight
        let up = cameraNode.simdWorldUp
        target -= right * Float(Double(d.x) * unitsPerPoint)
        target += up * Float(Double(d.y) * unitsPerPoint)
        updateCamera()
        rebuildGrid()
    }

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        guard !input.pencilActive else { return }
        finishCameraTransition()
        closeDimensionEdit()
        orthographicHeight = max(5, min(20_000, orthographicHeight / gesture.scale))
        gesture.scale = 1
        updateCamera()
        rebuildGrid()
        // Solid edges keep their weight on the GPU; sketch lines, dots, and tints are sized for the
        // zoom on the CPU, so restroke those only as it drifts, and once at the end.
        let drift = orthographicHeight / contentZoom
        if gesture.state != .changed || drift > 1.25 || drift < 0.8 { rebuildContent() }
    }

    /// Closes the keypad, without publishing a change (and a SwiftUI update) when it is already closed.
    func closeDimensionEdit() {
        if session.dimensionEdit != nil { session.dimensionEdit = nil }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type == .direct && !input.pencilActive && !(touch.view is DimensionValueButton)
    }
    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        (a is UIPinchGestureRecognizer && (b as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2) ||
        (b is UIPinchGestureRecognizer && (a as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2)
    }

    /// Ignores the depth buffer and renders after solids, so the node stays visible inside them.
    @discardableResult private func drawOnTop(_ node: SCNNode, order: Int) -> SCNNode {
        node.geometry?.materials.forEach { $0.readsFromDepthBuffer = false }
        node.renderingOrder = order
        return node
    }

    private func material(_ color: UIColor, constant: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(1)
        material.transparency = color.cgColor.alpha
        material.blendMode = .alpha
        material.lightingModel = constant ? .constant : .lambert
        material.isDoubleSided = true
        return material
    }

    private func path(for points: [Point2], closed: Bool = true, circle: CircleProfile? = nil) -> UIBezierPath {
        if let circle {
            let path = UIBezierPath(arcCenter: CGPoint(x: circle.center.x, y: circle.center.y), radius: circle.radius,
                                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
            path.close()
            path.flatness = 0.05
            return path
        }
        let path = UIBezierPath()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
        if closed { path.close() }
        return path
    }

    /// A region's outline with its holes left open, so a ring tints and extrudes as a ring.
    private func path(for profile: SketchProfile) -> UIBezierPath {
        let outer = path(for: profile.outline, circle: profile.circle)
        for hole in profile.holes ?? [] { outer.append(path(for: hole.outline, circle: hole.circle)) }
        outer.usesEvenOddFillRule = true
        return outer
    }

    private func planarNode(path: UIBezierPath, plane: SketchPlane, height: Double, color: UIColor, name: String? = nil) -> SCNNode {
        let geometry = SCNShape(path: path, extrusionDepth: 0)
        let mat = material(color, constant: true)
        mat.writesToDepthBuffer = false
        geometry.materials = [mat]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.simdTransform = plane.basis
        node.simdPosition = plane.position(height: height)
        return node
    }

    private func outlineNode(_ points: [Point2], plane: SketchPlane, color: UIColor, closed: Bool,
                             height: Double = 0.035, name: String? = nil, dashed: Bool = false) -> SCNNode {
        // Stroke as explicit triangles: this keeps outlines hollow across SceneKit tessellators.
        let radius = max(0.03, unitsPerPoint * 0.85)
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        func vertex(_ p: Point2) { vertices.append(SCNVector3(Float(p.x), Float(p.y), 0)) }
        let segmentCount = closed ? points.count : max(0, points.count - 1)
        // Construction geometry is dashed: 6 points on, 4 off, measured along the outline.
        let dash = max(1e-6, unitsPerPoint * 6), period = dash + max(1e-6, unitsPerPoint * 4)
        // Where along the current dash-and-gap the outline is (0 ..< period).
        var phase = 0.0
        func strip(_ a: Point2, _ b: Point2) {
            let d = b - a
            guard d.length > 1e-8 else { return }
            let perpendicular = Point2(x: -d.y, y: d.x) * (radius / d.length)
            let index = UInt32(vertices.count)
            [a + perpendicular, a - perpendicular, b + perpendicular, b - perpendicular].forEach(vertex)
            indices += [index, index + 1, index + 2, index + 2, index + 1, index + 3]
        }
        for i in 0..<segmentCount {
            let a = points[i], b = points[(i + 1) % points.count], length = a.distance(to: b)
            guard length > 1e-8 else { continue }
            guard dashed else { strip(a, b); continue }
            var along = 0.0
            while length - along > 1e-9 {
                let drawing = phase < dash
                let step = min(length - along, (drawing ? dash : period) - phase)
                if drawing { strip(a + (b - a) * (along / length), a + (b - a) * ((along + step) / length)) }
                along += step
                phase += step
                // At the end of a dash, the gap starts; at the end of a gap, the next dash.
                if drawing && phase >= dash - 1e-12 { phase = dash }
                if phase >= period - 1e-12 { phase = 0 }
            }
        }
        // A lone point (a sketch point) is a dot large enough to see and tap.
        let dot = points.count == 1 ? radius * 3.5 : radius
        for p in dashed ? [] : points {
            let index = UInt32(vertices.count)
            vertex(p)
            for i in 0...12 {
                let angle = Double(i) * .pi * 2 / 12
                vertex(p + Point2(x: cos(angle), y: sin(angle)) * dot)
                if i > 0 { indices += [index, index + UInt32(i), index + UInt32(i + 1)] }
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material(color, constant: true)]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.simdTransform = plane.basis
        node.simdPosition = plane.position(height: height)
        return node
    }

    /// Sketch planes pass through and under solids. While sketching or extruding, the active
    /// plane's sketches draw over solids so holes and cuts can be drawn and picked inside them.
    private var activeSketchesOnTop: Bool {
        session.sketchMode != nil || session.tool.shapeKind != nil || session.tool == .extrude || session.isExtruding || session.tool == .revolve ||
            session.selectedShape != nil || session.selectedProfile != nil || session.isMultipleSelection
    }

    /// The selected shape whose handles and dimensions show: none while several sketch items are picked.
    private var editableShape: SketchShape? { session.isMultipleSelection ? nil : session.selectedShape }

    /// Regions that are exactly a solid's extruded profile. A coincident source sketch must not tint
    /// the cap of a downward extrusion, so it stays hidden (but in the document) unless it is
    /// selected or its plane is being sketched on, where it can be seen, picked, and edited.
    private func isCovered(_ profile: SketchProfile) -> Bool {
        session.sketchMode?.plane != profile.plane &&
            session.visibleWorkspace.bodies.contains {
                !$0.isImported && $0.profile.plane == profile.plane && $0.profile.outline == profile.outline && $0.profile.circle == profile.circle
            } && !session.selectedProfiles.contains { $0.id == profile.id }
    }

    private func coveredSourceIDs() -> Set<UUID> {
        var covered = Set<UUID>()
        for profile in session.visibleWorkspace.profiles where isCovered(profile) {
            covered.formUnion(profile.sourceIDs)
        }
        return covered
    }

    private func rebuildContent() {
        contentZoom = orthographicHeight
        contentVersion += 1
        contentRebuilds += 1
        draggedGhost = nil
        content.childNodes.forEach { $0.removeFromParentNode() }
        var coveredSourceIDs = Set<UUID>()
        let sketching = activeSketchesOnTop
        // Every picked region, and the shapes of picked regions and whole sketches.
        let pickedProfiles = session.selectedProfiles
        let pickedIDs = Set(pickedProfiles.map(\.id)), pickedShapes = Set(pickedProfiles.flatMap(\.sourceIDs))
        let pickedSketches = Set(session.selectedItems.compactMap { item -> UUID? in if case .sketch(let id) = item { id } else { nil } })
        for profile in session.visibleWorkspace.profiles {
            let plane = profile.plane
            let selected = pickedIDs.contains(profile.id)
            if isCovered(profile) {
                coveredSourceIDs.formUnion(profile.sourceIDs)
                continue
            }
            let source = (session.isExtruding && (selected || session.extraExtrusionProfiles.contains { $0.id == profile.id })) ||
                (session.revolveDraft.map { $0.face == nil && $0.profiles.contains { $0.id == profile.id } } ?? false)
            let fillColor = source ? UIColor(red: 0.74, green: 0.58, blue: 0.31, alpha: 0.52) : blue.withAlphaComponent(selected ? 0.08 : 0.035)
            let fill = planarNode(path: path(for: profile), plane: plane, height: 0.01,
                                  color: fillColor, name: "profile|" + profile.id)
            if sketching && (plane == session.plane || selected) { drawOnTop(fill, order: 9) }
            content.addChildNode(fill)
        }
        for shape in session.visibleWorkspace.shapes where !coveredSourceIDs.contains(shape.id) {
            let selected = session.selectedShape?.id == shape.id || pickedShapes.contains(shape.id) ||
                (shape.sketch.map(pickedSketches.contains) ?? false)
            let active = shape.plane == session.plane
            let picked = session.sketchMirrorDraft.map { $0.shapes.contains(shape.id) || $0.line == shape.id } ?? false ||
                session.offsetDraft?.shapeID == shape.id
            let outline = outlineNode(shape.outline, plane: shape.plane,
                                      color: selected || picked ? blue : active ? UIColor(red: 0.22, green: 0.35, blue: 0.46, alpha: 1) : .systemGray,
                                      closed: shape.isClosed, name: "shape|" + shape.id.uuidString, dashed: shape.isConstruction)
            if sketching && (active || selected) { drawOnTop(outline, order: 10) }
            content.addChildNode(outline)
        }
        for construction in session.visibleWorkspace.constructionPlanes {
            // Translucent, after the solids, so a solid in front hides it (like the grid's role).
            let picked = session.selectedConstructionPlane?.id == construction.id ||
                session.planeDraft?.references.contains { $0.source == .plane(construction.id) } == true
            let fill = planarNode(path: path(for: construction.outline, circle: nil), plane: construction.plane, height: 0,
                                  color: picked ? blue.withAlphaComponent(0.14) : UIColor(white: 0.42, alpha: 0.1),
                                  name: "plane|" + construction.id.uuidString)
            fill.renderingOrder = 6
            content.addChildNode(fill)
            let border = outlineNode(construction.outline, plane: construction.plane,
                                     color: picked ? blue : UIColor(white: 0.36, alpha: 1), closed: true)
            border.renderingOrder = 6
            content.addChildNode(border)
        }
        let bodies = session.visibleWorkspace.bodies
        solidCache = solidCache.filter { entry in bodies.contains { $0.id == entry.key } }
        pivotSnapCache = pivotSnapCache.filter { entry in bodies.contains { $0.id == entry.key } }
        alignCornerCache = alignCornerCache.filter { entry in bodies.contains { $0.id == entry.key } }
        sectionCache = sectionCache.filter { entry in bodies.contains { $0.id == entry.key } }
        let ghosts = session.previewGhosts
        for body in bodies {
            if let section = session.section {
                content.addChildNode(sectionNode(body, section))
                continue
            }
            if let ghost = ghosts[body.id], let source = session.workspace.bodies.first(where: { $0.id == ghost.source }) {
                // A pattern's many copies drop a turned outline; one solid being dragged keeps it.
                let dragged = session.patternGhosts[body.id] == nil
                content.addChildNode(ghostNode(of: source, as: body.id, moved: ghost.transform, selected: dragged && session.selectedBody?.id == body.id,
                                               outline: dragged))
                if dragged { draggedGhost = (body.id, source) }
                continue
            }
            let node = bodyNode(body, selected: session.selectedBody?.id == body.id)
            if session.isXrayed(body.id) {
                // X-ray: faces see-through and left out of the depth buffer, so edges and solids
                // behind them show; drawn after the opaque solids.
                node.geometry = node.geometry?.copy() as? SCNGeometry
                node.geometry?.materials = (node.geometry?.materials ?? []).map(xrayMaterial)
                node.renderingOrder = 3
            }
            if session.finishDraft?.bodyID == body.id {
                // Translucent like the extrusion preview, so the picked edges stay visible.
                node.geometry = node.geometry?.copy() as? SCNGeometry
                node.geometry?.materials = [material(UIColor(white: 0.57, alpha: 0.55))]
            }
            content.addChildNode(node)
        }
        if let draft = session.finishDraft, let body = session.workspace.bodies.first(where: { $0.id == draft.bodyID }),
           let render = solidRender(body) {
            var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
            let picked = Set(draft.edges.map(\.index))
            for (border, edge) in zip(render.borders, render.borderEdges) where picked.contains(edge) {
                segments += zip(border, border.dropFirst()).map { ($0, $1) }
            }
            let highlight = strokeNode(segments, color: blue, weight: 1.8)
            highlight.name = "finish.edges"
            content.addChildNode(highlight)
        }
        if let picked = session.selectedEdge, let body = session.workspace.bodies.first(where: { $0.id == picked.bodyID }),
           let render = solidRender(body) {
            var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
            for (border, edge) in zip(render.borders, render.borderEdges) where edge == picked.edge.index {
                segments += zip(border, border.dropFirst()).map { ($0, $1) }
            }
            let highlight = strokeNode(segments, color: blue, weight: 1.8)
            highlight.name = "edge.selection"
            content.addChildNode(highlight)
        }
        if let source = session.faceExtrusion ?? session.revolveDraft?.face, let body = session.workspace.bodies.first(where: { $0.id == source.bodyID }),
           let render = solidRender(body) {
            // The amber source region, as for sketch extrusions. Material pulled out over it hides it.
            content.addChildNode(faceTint(render, face: source.face, color: UIColor(red: 0.74, green: 0.58, blue: 0.31, alpha: 0.6), name: "face.extrusion"))
        } else if let face = session.selectedFace, let body = session.workspace.bodies.first(where: { $0.id == face.bodyID }),
           let render = solidRender(body) {
            content.addChildNode(faceTint(render, face: face.face, color: blue.withAlphaComponent(0.3), name: "face.selection"))
        }
    }

    /// A solid cut by the section plane: the side the plane's normal points to is taken away, and
    /// the cut faces are filled in coral.
    private func sectionNode(_ body: SolidBody, _ section: SectionView) -> SCNNode {
        let name = "body|" + body.id.uuidString
        let entry: (render: SolidRender?, caps: [Int])
        if let cached = sectionCache[body.id], cached.body == body, cached.section == section {
            entry = (cached.render, cached.caps)
        } else {
            entry = sectioned(body, section)
            sectionCache[body.id] = (body, section, entry.render, entry.caps)
        }
        guard let render = entry.render else { let empty = SCNNode(); empty.name = name; return empty }
        let node = SCNNode(geometry: render.faces)
        node.name = name
        node.addChildNode(kernelEdges(render, color: edgeGray))
        for cap in entry.caps { node.addChildNode(faceTint(render, face: cap, color: sectionCap, name: "section.cap")) }
        return node
    }

    private func sectioned(_ body: SolidBody, _ section: SectionView) -> (render: SolidRender?, caps: [Int]) {
        guard let solid = try? SolidKernel.solid(for: body) else { return (nil, []) }
        let bounds = solid.bounds, plane = section.plane
        let reach = simd_length(bounds.max - bounds.min) + 20, middle = plane.coordinates(of: (bounds.min + bounds.max) / 2)
        // A box past the solid on the side that is cut away.
        let square = SketchShape(kind: .rectangle, plane: plane, start: middle - Point2(x: reach, y: reach), end: middle + Point2(x: reach, y: reach))
        guard let profile = Geometry.profiles(in: [square], on: plane).first,
              let box = try? SolidKernel.extrude(profile, depth: section.flipped ? -2 * reach : 2 * reach) else { return (nil, []) }
        guard let cut = try? SolidKernel.boolean(solid, box, .subtract), cut.volume > 1e-9, let mesh = try? cut.tessellateForDisplay() else { return (nil, []) }
        let render = SolidRender(cut, mesh, body: body, material: bodyMaterial(body))
        let caps = (0..<cut.faceCount).filter { face in
            guard let flat = cut.facePlane(face) else { return false }
            return simd_dot(flat.normal, section.normal) > 0.9999 && abs(simd_dot(flat.origin - plane.origin, section.normal)) < 1e-5
        }
        return (render, caps)
    }

    /// The section plane's double-arrow, at the middle of the solids on the plane, pointing to the
    /// side that is cut away.
    func sectionHandle() -> ExtrusionHandle? {
        guard let section = session.section else { return nil }
        let bounds = session.visibleWorkspace.bodies.compactMap { try? SolidKernel.solid(for: $0).bounds }
        guard let first = bounds.first else { return nil }
        let middle = (bounds.reduce(first.min) { simd_min($0, $1.min) } + bounds.reduce(first.max) { simd_max($0, $1.max) }) / 2
        let center = middle - section.normal * simd_dot(middle - section.origin, section.normal)
        let origin = project(SIMD3<Float>(center)), ahead = project(SIMD3<Float>(center + section.normal * 10))
        let dx = ahead.x - origin.x, dy = ahead.y - origin.y, length = hypot(dx, dy)
        let axis = length > 4 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: -1)
        return ExtrusionHandle(origin: origin, face: origin, center: CGPoint(x: origin.x + axis.dx * 22, y: origin.y + axis.dy * 22), axis: axis)
    }

    /// A translucent overlay on one B-rep face, lifted a hair toward the outside to avoid z-fighting.
    private func faceTint(_ render: SolidRender, face: Int, color: UIColor, name: String) -> SCNNode {
        let lift = Float(unitsPerPoint * 0.6)
        var vertices: [SCNVector3] = []
        for triangle in render.triangleFaces.indices where render.triangleFaces[triangle] == face {
            let a = render.triangles[3 * triangle], b = render.triangles[3 * triangle + 1], c = render.triangles[3 * triangle + 2]
            let n = simd_cross(b - a, c - a)
            let offset = simd_length(n) > 0 ? simd_normalize(n) * lift : .zero
            vertices += [a, b, c].map { SCNVector3($0 + offset) }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                   elements: [SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .triangles)])
        let tint = material(color, constant: true)
        tint.writesToDepthBuffer = false
        geometry.materials = [tint]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.renderingOrder = 5
        return node
    }

    /// A square picture of the solids as they are on screen, for a 3MF's preview (slicers and
    /// printers show it): the middle of the view, 512 points across.
    func thumbnailPNG() -> Data? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let image = sceneView.snapshot()
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).pngData { _ in
            image.draw(in: CGRect(x: -crop.minX * 512 / side, y: -crop.minY * 512 / side, width: image.size.width * 512 / side, height: image.size.height * 512 / side))
        }
    }

    /// The project's picture for the document browser (October 21, 2026): everything visible, from
    /// the standard 3D angle and framed to fit, drawn off screen without the grid, axes, selection,
    /// or widgets. Solids are shaded by the canvas's lights with dark borders; a project with no
    /// solid yet shows its sketches as purple lines. Nil for an empty project.
    func projectThumbnail(side: CGFloat = CGFloat(ProjectPreview.side)) -> UIImage? {
        let visible = session.workspace.visible
        var parts: [ModelPicture.Part] = []
        for body in visible.bodies {
            guard let render = solidRender(body), let solid = try? SolidKernel.solid(for: body) else { continue }
            let b = solid.bounds
            var corners: [SIMD3<Float>] = []
            for x in [b.min.x, b.max.x] { for y in [b.min.y, b.max.y] { for z in [b.min.z, b.max.z] { corners.append(SIMD3(Float(x), Float(y), Float(z))) } } }
            parts.append(ModelPicture.Part(faces: render.faces, borders: render.borders, corners: corners))
        }
        let sketchLines: [[SIMD3<Float>]] = !parts.isEmpty ? [] : visible.shapes.map { shape in
            let outline = shape.outline.map { shape.plane.world($0) }
            return shape.isClosed && outline.count > 2 ? outline + [outline[0]] : outline
        }
        return ModelPicture.image(parts: parts, sketchLines: sketchLines, side: side)
    }

    /// A pattern preview copy, or a solid being dragged: the original's picture (built once) placed
    /// by the motion. A turned one's outline of curved faces fits only the original's view: it is
    /// dropped, or with `outline` worked out again for the view as the turned solid sees it.
    private func ghostNode(of source: SolidBody, as id: UUID, moved transform: RigidTransform, selected: Bool = false, outline: Bool = false) -> SCNNode {
        let node = bodyNode(source, selected: selected)
        node.name = "body|" + id.uuidString
        place(node, of: source, moved: transform, selected: selected, outline: outline)
        return node
    }

    /// Puts a ghost's node where `transform` takes the original, its turned outline redone if asked.
    private func place(_ node: SCNNode, of source: SolidBody, moved transform: RigidTransform, selected: Bool, outline: Bool) {
        let r = simd_float3x3(simd_quatf(ix: Float(transform.rotation.imag.x), iy: Float(transform.rotation.imag.y),
                                         iz: Float(transform.rotation.imag.z), r: Float(transform.rotation.real)))
        let t = SIMD3<Float>(transform.pivot + transform.translation) - r * SIMD3<Float>(transform.pivot)
        node.simdTransform = simd_float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(t, 1))
        guard abs(transform.rotation.angle) > 1e-9, let edges = node.childNode(withName: "body.edges", recursively: false) else { return }
        edges.childNode(withName: "body.silhouettes", recursively: false)?.removeFromParentNode()
        if outline, let render = solidRender(source), !render.silhouettes.isEmpty {
            let view = r.transpose * SIMD3(Float(viewDirection.x), Float(viewDirection.y), Float(viewDirection.z))
            let turned = coloredNode(Self.strokeGeometry(render.silhouettes.segments(viewDirection: view)), color: selected ? blue : edgeGray)
            turned.name = "body.silhouettes"
            edges.addChildNode(turned)
        }
    }

    /// While the Move/Rotate widget drags a solid, only its node moves when nothing else changed:
    /// the rest of the scene stays as built, so SceneKit has nothing new to prepare on each step and
    /// the solid keeps up with the widget (October 22, 2026). False when the scene must be rebuilt.
    private func moveDraggedGhost() -> Bool {
        guard let (id, built) = draggedGhost, let ghost = session.previewGhosts[id], session.patternGhosts[id] == nil,
              let node = content.childNode(withName: "body|" + id.uuidString, recursively: false),
              let source = session.workspace.bodies.first(where: { $0.id == ghost.source }), source == built, var before = lastWorkspace else { return false }
        var after = session.visibleWorkspace
        before.bodies.removeAll { $0.id == id }
        after.bodies.removeAll { $0.id == id }
        guard before == after else { return false }
        place(node, of: source, moved: ghost.transform, selected: session.selectedBody?.id == id, outline: true)
        contentVersion += 1
        return true
    }

    /// Committed solids render from the Open CASCADE B-rep: exact faces, real borders, and
    /// silhouettes of curved faces. The SceneKit extrusion remains as a fallback.
    private func bodyNode(_ body: SolidBody, selected: Bool) -> SCNNode {
        let name = "body|" + body.id.uuidString
        guard let render = solidRender(body) else {
            // A revolve has no SceneKit stand-in; one the kernel cannot build is left out.
            if body.revolve != nil || body.isImported { let empty = SCNNode(); empty.name = name; return empty }
            return bodyNode(body.profile, depth: body.depth, selected: selected, name: name)
        }
        let node = SCNNode(geometry: render.faces)
        node.name = name
        node.addChildNode(kernelEdges(render, color: selected ? blue : edgeGray))
        return node
    }

    private func solidRender(_ body: SolidBody) -> SolidRender? {
        if let cached = solidCache[body.id]?.first(where: { $0.body == body }) { return cached.render }
        solidRenderBuilds += 1
        let render: SolidRender? = (try? SolidKernel.solid(for: body)).flatMap { solid in
            (try? solid.tessellateForDisplay()).map { SolidRender(solid, $0, body: body, material: bodyMaterial(body)) }
        }
        solidCache[body.id] = [(body, render)] + (solidCache[body.id] ?? []).prefix(1)
        return render
    }

    /// A solid's material, see-through for X-ray.
    private func xrayMaterial(_ base: SCNMaterial) -> SCNMaterial {
        let copy = base.copy() as! SCNMaterial
        copy.transparency = 0.22
        copy.writesToDepthBuffer = false
        copy.isDoubleSided = true
        copy.blendMode = .alpha
        return copy
    }

    /// Neutral gray, or the color the solid was given.
    private func bodyMaterial(_ body: SolidBody) -> SCNMaterial {
        let (r, g, b) = (body.color ?? .gray).rgb
        return material(UIColor(red: r, green: g, blue: b, alpha: 1))
    }

    /// A solid's borders, with the outline of its curved faces as a child ("body.silhouettes"). The
    /// borders never change with the view, so turning the camera rebuilds only the outline: on a
    /// detailed solid (an imported phone has hundreds of curved borders) rebuilding everything on
    /// every orbit step made orbiting sluggish.
    private func kernelEdges(_ render: SolidRender, color: UIColor) -> SCNNode {
        if render.borderGeometry == nil {
            var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
            segments.reserveCapacity(render.borders.reduce(0) { $0 + max(0, $1.count - 1) })
            for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
            render.borderGeometry = Self.strokeGeometry(segments)
        }
        let node = coloredNode(render.borderGeometry!, color: color)
        node.name = "body.edges"
        node.addChildNode(silhouetteNode(render, color: color))
        return node
    }

    private func silhouetteNode(_ render: SolidRender, color: UIColor) -> SCNNode {
        let view = SIMD3(Float(viewDirection.x), Float(viewDirection.y), Float(viewDirection.z))
        if render.silhouetteGeometry.map({ $0.view != view }) ?? true {
            render.silhouetteGeometry = (view, Self.strokeGeometry(render.silhouettes.segments(viewDirection: view)))
        }
        let node = coloredNode(render.silhouetteGeometry!.geometry, color: color)
        node.name = "body.silhouettes"
        return node
    }

    /// Shared tube geometry in a color: the copy shares the vertex data and only swaps the material.
    private func coloredNode(_ geometry: SCNGeometry, color: UIColor, pixels: Double? = nil) -> SCNNode {
        let copy = geometry.copy() as! SCNGeometry
        copy.materials = [strokeMaterial(color, pixels: pixels ?? strokePixels())]
        return SCNNode(geometry: copy)
    }

    private func bodyNode(_ profile: SketchProfile, depth: Double, selected: Bool, preview: Bool = false, name: String? = nil,
                          offset: Double = 0, color previewColor: UIColor? = nil) -> SCNNode {
        let shape = SCNShape(path: path(for: profile), extrusionDepth: abs(depth))
        let color = previewColor ?? (preview ? UIColor(white: 0.57, alpha: 0.38) : UIColor(white: 0.62, alpha: 1))
        shape.materials = [material(color)]
        let node = SCNNode(geometry: shape)
        node.name = name
        node.simdTransform = profile.plane.basis
        // SCNShape is centered on local Z. Move half the signed depth so the base stays on the sketch plane.
        node.simdPosition = profile.plane.position(height: offset + depth / 2)
        if !preview {
            node.addChildNode(bodyEdges(profile, depth: abs(depth), color: selected ? blue : edgeGray))
        }
        return node
    }

    private func bodyEdges(_ profile: SketchProfile, depth: Double, color: UIColor) -> SCNNode {
        // Only actual boundaries: two cap rims and polygon corners, never face triangulation
        // or the artificial vertical seams of a tessellated cylinder. Small tubes keep the
        // stroke visible at every camera angle while the depth buffer hides rear edges.
        let points: [Point2]
        if let circle = profile.circle {
            let count = min(720, max(96, Int(ceil(2 * .pi * circle.radius / (unitsPerPoint * 3)))))
            points = (0..<count).map { index in
                let angle = Double(index) * 2 * .pi / Double(count)
                return circle.center + Point2(x: cos(angle), y: sin(angle)) * circle.radius
            }
        } else { points = profile.outline }
        let halfDepth = Float(depth / 2)
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>) { segments.append((a, b)) }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            for z in [-halfDepth, halfDepth] {
                segment(.init(Float(a.x), Float(a.y), z), .init(Float(b.x), Float(b.y), z))
            }
            let previous = points[(i + points.count - 1) % points.count]
            let incoming = a - previous, outgoing = b - a
            if profile.circle == nil && abs(Geometry.cross(incoming, outgoing)) > incoming.length * outgoing.length * 1e-6 {
                segment(.init(Float(a.x), Float(a.y), -halfDepth), .init(Float(a.x), Float(a.y), halfDepth))
            }
        }
        if let circle = profile.circle {
            let localView = simd_inverse(profile.plane.basis) * SIMD4(Float(viewDirection.x), Float(viewDirection.y), Float(viewDirection.z), 0)
            let radialLength = hypot(localView.x, localView.y)
            if radialLength > 1e-5 {
                let tangent = Point2(x: Double(-localView.y / radialLength), y: Double(localView.x / radialLength)) * circle.radius
                for point in [circle.center + tangent, circle.center - tangent] {
                    segment(.init(Float(point.x), Float(point.y), -halfDepth), .init(Float(point.x), Float(point.y), halfDepth))
                }
            }
        }
        return strokeNode(segments, color: color)
    }

    /// Small tubes keep strokes visible at every camera angle while the depth buffer hides rear
    /// edges. Their radius is set on the GPU, so strokes keep a constant on-screen weight at any zoom.
    private func strokeNode(_ segments: [(SIMD3<Float>, SIMD3<Float>)], color: UIColor, weight: Double = 1) -> SCNNode {
        let geometry = Self.strokeGeometry(segments)
        geometry.materials = [strokeMaterial(color, pixels: strokePixels(weight: weight))]
        let node = SCNNode(geometry: geometry)
        node.name = "body.edges"
        return node
    }

    /// A stroke's radius in the scene view's pixels: 0.85 points at weight 1.
    private func strokePixels(weight: Double = 1) -> Double { 0.85 * weight * Double(sceneView.contentScaleFactor) }

    /// Pushes each tube vertex out from its segment (the normal holds the unit offset) by
    /// `strokePixels` worth of world units for the frame's orthographic camera. Zooming then
    /// changes stroke weight without rebuilding any geometry, which on an imported board with
    /// thousands of edges made pinching stutter.
    nonisolated static let strokeShader = """
    #pragma arguments
    float strokePixels;
    #pragma body
    float worldPerPixel = 2.0 * scn_frame.inverseResolution.y / scn_frame.projectionTransform[1][1];
    _geometry.position.xyz += _geometry.normal * (strokePixels * worldPerPixel);
    """

    private func strokeMaterial(_ color: UIColor, pixels: Double) -> SCNMaterial {
        let stroke = material(color, constant: true)
        stroke.shaderModifiers = [.geometry: Self.strokeShader]
        stroke.setValue(NSNumber(value: Float(pixels)), forKey: "strokePixels")
        return stroke
    }

    /// Octagonal tubes along segments, without a material: every vertex sits on its segment, with
    /// its unit offset as the normal, for `strokeShader` to widen. Safe off the main thread.
    nonisolated static func strokeGeometry(_ segments: [(SIMD3<Float>, SIMD3<Float>)]) -> SCNGeometry {
        // An octagonal tube per segment; storage is reserved up front, as solids can have many.
        let ring = (0..<8).map { (cos(Float($0) * .pi / 4), sin(Float($0) * .pi / 4)) }
        var vertices: [SCNVector3] = []
        var offsets: [SCNVector3] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(segments.count * 16)
        offsets.reserveCapacity(segments.count * 16)
        indices.reserveCapacity(segments.count * 48)
        for (a, b) in segments {
            let delta = b - a
            guard simd_length(delta) > 1e-7 else { continue }
            let direction = simd_normalize(delta)
            let reference = abs(direction.z) < 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
            let u = simd_normalize(simd_cross(direction, reference))
            let v = simd_normalize(simd_cross(direction, u))
            let first = UInt32(vertices.count)
            for end in [a, b] {
                for (c, s) in ring { vertices.append(SCNVector3(end)); offsets.append(SCNVector3(u * c + v * s)) }
            }
            for i in UInt32(0)..<8 {
                let next = (i + 1) % 8
                indices.append(first + i); indices.append(first + next); indices.append(first + i + 8)
                indices.append(first + next); indices.append(first + next + 8); indices.append(first + i + 8)
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: offsets)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    private func rebuildPreview() {
        previewNode.childNodes.forEach { $0.removeFromParentNode() }
        if session.isPickingPlane {
            // Three translucent world planes at the origin to pick from after Sketch, borderless and
            // tinted like their view cube faces (Top Violet, Front Lime, Right Coral) so they never
            // read as blue sketch regions.
            let half = planePickerHalfSize
            let square = [Point2(x: -half, y: -half), Point2(x: half, y: -half), Point2(x: half, y: half), Point2(x: -half, y: half)]
            for (plane, axis, alpha) in [(SketchPlane.top, WorldAxis.z, 0.22), (.front, .y, 0.4), (.right, .x, 0.28)] {
                let fill = planarNode(path: path(for: square, circle: nil), plane: plane, height: 0, color: axis.color.withAlphaComponent(alpha),
                                      name: "plane.pick.\(plane.worldName ?? "")")
                previewNode.addChildNode(drawOnTop(fill, order: 8))
            }
        }
        if session.tool.isPlaneTool {
            // The world planes are references too, drawn at the origin.
            let half = PlaneReference.worldHalfSize
            let square = [Point2(x: -half, y: -half), Point2(x: half, y: -half), Point2(x: half, y: half), Point2(x: -half, y: half)]
            for plane in SketchPlane.allCases {
                let fill = planarNode(path: path(for: square, circle: nil), plane: plane, height: 0,
                                      color: blue.withAlphaComponent(0.06), name: "plane.reference.\(plane.worldName ?? "")")
                fill.renderingOrder = 7   // hidden behind solids, so it does not tint them
                previewNode.addChildNode(fill)
                previewNode.addChildNode(drawOnTop(outlineNode(square, plane: plane, color: blue.withAlphaComponent(0.35), closed: true), order: 8))
            }
            for reference in session.planeDraft?.references ?? [] {
                let points = reference.outline.map { SIMD3<Float>($0) }
                let segments = zip(points, points.dropFirst() + points.prefix(1)).map { ($0, $1) }
                let highlight = drawOnTop(strokeNode(segments, color: blue, weight: 1.5), order: 9)
                highlight.name = "plane.reference.picked"
                previewNode.addChildNode(highlight)
            }
            if let preview = session.planePreview {
                // The fill hides behind solids (so it does not tint them); the border always shows.
                let fill = planarNode(path: path(for: preview.outline, circle: nil), plane: preview.plane, height: 0,
                                      color: blue.withAlphaComponent(0.16), name: "plane.preview")
                fill.renderingOrder = 7
                previewNode.addChildNode(fill)
                previewNode.addChildNode(drawOnTop(outlineNode(preview.outline, plane: preview.plane, color: blue, closed: true), order: 9))
            }
        }
        if let draft = session.projectionDraft { rebuildProjectionPreview(draft) }
        if let draft = session.splitDraft { rebuildSplitPreview(draft) }
        if let draft = session.mirrorDraft { rebuildMirrorPreview(draft) }
        if let draft = session.patternDraft { highlightItems(bodies: draft.bodies, sketches: draft.sketches, name: "pattern.items") }
        if let draft = session.scaleDraft { highlightItems(bodies: draft.bodies, sketches: draft.sketches, name: "scale.items") }
        for shape in session.offsetPreview {
            let node = drawOnTop(outlineNode(shape.outline, plane: shape.plane, color: blue, closed: shape.isClosed, name: "offset.preview"), order: 10)
            previewNode.addChildNode(node)
        }
        if let draft = session.deleteFaceDraft, let body = session.workspace.bodies.first(where: { $0.id == draft.bodyID }), let render = solidRender(body) {
            // The faces going away, in coral over the result.
            for opening in draft.faces {
                let tint = faceTint(render, face: opening.face, color: UIColor(red: 1, green: 0.5, blue: 0.4, alpha: 0.55), name: "deleteFace.faces")
                previewNode.addChildNode(drawOnTop(tint, order: 9))
            }
        }
        if let draft = session.alignDraft { rebuildAlignPreview(draft) }
        if let draft = session.revolveDraft { rebuildRevolvePreview(draft) }
        if session.isMeasuring { rebuildMeasurePreview() }
        if let draft = session.subtractDraft {
            // Targets in purple, the solids taken away in blue (drawn over everything, since a
            // removed solid is gone from the preview).
            let purple = UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1)
            for (ids, color, name) in [(draft.targets, purple, "subtract.targets"), (draft.tools, blue, "subtract.tools")] {
                var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
                for id in ids {
                    guard let body = session.workspace.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
                    for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
                }
                guard !segments.isEmpty else { continue }
                let node = strokeNode(segments, color: color, weight: 1.6)
                node.name = name
                previewNode.addChildNode(name == "subtract.tools" ? drawOnTop(node, order: 9) : node)
            }
        }
        if let draft = session.unionDraft {
            // The picked solids in blue, the target (picked last) in purple.
            for id in draft.bodies {
                guard let body = session.workspace.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
                var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
                for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
                let target = id == draft.target && draft.bodies.count > 1
                let node = strokeNode(segments, color: target ? UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1) : blue, weight: 1.6)
                node.name = target ? "union.target" : "union.bodies"
                previewNode.addChildNode(node)
            }
        }
        if session.sketchMode != nil, abs(session.plane.height(of: .zero)) < 1e-9 {
            // The origin, where the sketch plane passes through it.
            let dot = SCNNode(geometry: SCNSphere(radius: CGFloat(unitsPerPoint * 3.5)))
            dot.geometry?.materials = [material(WorldAxis.casing, constant: true)]
            dot.name = "sketch.origin"
            previewNode.addChildNode(drawOnTop(dot, order: 11))
        }
        if let shape = session.preview {
            let circle = shape.kind == .circle ? CircleProfile(center: shape.start, radius: shape.start.distance(to: shape.end)) : nil
            previewNode.addChildNode(drawOnTop(outlineNode(shape.outline, plane: shape.plane, color: blue, closed: shape.isClosed), order: 10))
            if shape.isClosed && shape.isValid {
                previewNode.addChildNode(drawOnTop(planarNode(path: path(for: shape.outline, circle: circle), plane: shape.plane, height: 0.01, color: blue.withAlphaComponent(0.08)), order: 9))
            }
        }
        if session.isCutting, session.cutThroughAll, let profile = session.extrusionProfile {
            // The through-all tool spans every solid on both sides of the sketch plane.
            let reach = session.throughAllReach(from: profile.plane)
            previewNode.addChildNode(bodyNode(profile, depth: 2 * reach, selected: true, preview: true, offset: -reach, color: cutRed))
        } else if session.isJoining && session.joinTarget != nil {
            // The joined solid itself shows the boss (rendered from the merged preview), so no
            // translucent tool is drawn on top of its coincident faces.
        } else if session.isExtruding, let tool = session.extrusionTool {
            // Options or several regions: the kernel's solid, translucent (red for a cut).
            previewNode.addChildNode(kernelToolNode(tool, cut: session.isCutting, name: "extrusion.preview"))
        } else if session.isExtruding, let profile = session.extrusionProfile, abs(session.extrusionDepth) >= 0.01 {
            previewNode.addChildNode(bodyNode(profile, depth: session.extrusionDepth, selected: true, preview: true,
                                              color: session.isCutting ? cutRed : nil))
            // The end rim and the corner edges, a hole's included.
            for loop in [(profile.outline, profile.circle)] + (profile.holes ?? []).map({ ($0.outline, $0.circle) }) {
                previewNode.addChildNode(outlineNode(loop.0, plane: profile.plane, color: UIColor(white: 0.22, alpha: 1), closed: true, height: session.extrusionDepth))
            }
            let cornered = (profile.circle == nil ? [profile.outline] : []) + (profile.holes ?? []).filter { $0.circle == nil }.map(\.outline)
            if !cornered.isEmpty {
                let vertices = cornered.joined().flatMap { point in
                    [SCNVector3(profile.plane.world(point)), SCNVector3(profile.plane.world(point, height: session.extrusionDepth))]
                }
                let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 }, primitiveType: .line)])
                geometry.materials = [material(UIColor(white: 0.22, alpha: 1), constant: true)]
                previewNode.addChildNode(SCNNode(geometry: geometry))
            }
        }
    }

    private func rebuildGrid() {
        gridNode.childNodes.forEach { $0.removeFromParentNode() }
        let step = session.lengthUnit.gridStep(atLeast: unitsPerPoint * 24), major = session.lengthUnit.majorEvery
        if session.gridSpacing != step {
            // Defer published updates until the current UIViewRepresentable update has finished.
            Task { @MainActor [weak self] in self?.session.gridSpacing = step }
        }
        let center = session.plane.local(target)
        let radius = orthographicHeight * max(1, Double(view.bounds.width / max(1, view.bounds.height)))
        let minX = (Int(floor((center.x - radius) / step)))
        let maxX = (Int(ceil((center.x + radius) / step)))
        let minY = (Int(floor((center.y - radius) / step)))
        let maxY = (Int(ceil((center.y + radius) / step)))
        var fine: [SCNVector3] = [], majorLines: [SCNVector3] = []
        // Lines through the plane's origin are ordinary grid lines; the world axes are drawn below.
        for i in minX...maxX {
            let a = SCNVector3(Float(Double(i) * step), Float(Double(minY) * step), -0.02)
            let b = SCNVector3(Float(Double(i) * step), Float(Double(maxY) * step), -0.02)
            if i.isMultiple(of: major) { majorLines += [a, b] } else { fine += [a, b] }
        }
        for i in minY...maxY {
            let a = SCNVector3(Float(Double(minX) * step), Float(Double(i) * step), -0.02)
            let b = SCNVector3(Float(Double(maxX) * step), Float(Double(i) * step), -0.02)
            if i.isMultiple(of: major) { majorLines += [a, b] } else { fine += [a, b] }
        }
        func lines(_ vertices: [SCNVector3], color: UIColor) {
            guard !vertices.isEmpty else { return }
            let source = SCNGeometrySource(vertices: vertices)
            let indices = (0..<Int32(vertices.count)).map { $0 }
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            // The construction grid is a background aid. It must not overlay a solid
            // extruded below this plane. Preblend its color so it renders in the opaque
            // background pass, without writing depth that could cover later geometry.
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let background: CGFloat = 0.94
            let gridMaterial = material(UIColor(red: red * alpha + background * (1 - alpha),
                                                green: green * alpha + background * (1 - alpha),
                                                blue: blue * alpha + background * (1 - alpha), alpha: 1), constant: true)
            gridMaterial.blendMode = .replace
            gridMaterial.writesToDepthBuffer = false
            geometry.materials = [gridMaterial]
            let node = SCNNode(geometry: geometry)
            node.renderingOrder = -100
            node.simdTransform = session.plane.basis
            if session.sketchMode?.face != nil {
                // Sketching on a face: draw the grid on the face itself, after the solids,
                // lifted a hair off the face so it shows on it but stays hidden behind other geometry.
                node.renderingOrder = 4
                node.simdPosition = session.plane.position(height: unitsPerPoint * 0.6)
            }
            gridNode.addChildNode(node)
        }
        lines(fine, color: UIColor(white: 0.78, alpha: 0.55))
        lines(majorLines, color: UIColor(white: 0.7, alpha: 0.6))
        // World axes from the origin along +X, +Y, and +Z, whatever the sketch plane.
        // Like the grid they are background: solids cover them.
        let reach = Float(min(45_000, Double(simd_length(target)) + radius * 2))
        for axis in WorldAxis.allCases {
            let segment = [(SIMD3<Float>.zero, axis.direction * reach)]
            var parts = [(strokeNode(segment, color: axis.color, weight: 0.75), "axis.\(axis.rawValue)")]
            if axis.isCased { parts.insert((strokeNode(segment, color: WorldAxis.casing, weight: 1.35), "axis.\(axis.rawValue).casing"), at: 0) }
            for (index, (node, name)) in parts.enumerated() {
                node.name = name
                node.renderingOrder = -99 + index
                node.geometry?.firstMaterial?.blendMode = .replace
                node.geometry?.firstMaterial?.writesToDepthBuffer = false
                gridNode.addChildNode(node)
            }
        }
    }

    /// An orthographic camera as screen mapping needs it: a point on the view axis, the screen's
    /// right and up, the direction toward the viewer, and the visible height in millimeters.
    struct ScreenCamera: Equatable, Sendable {
        var origin: SIMD3<Double>
        var right: SIMD3<Double>
        var up: SIMD3<Double>
        var direction: SIMD3<Double>
        var height: Double
    }

    /// The camera the overlay and the Pencil map through. On screen it is the camera of the frame
    /// SceneKit last drew: SceneKit draws on its own thread and, on a heavy model, a frame or more
    /// behind the gestures, so the corner dots, widget, handles, and labels stay on the solids as
    /// they appear instead of running ahead of them. Off screen (tests), the camera as set.
    /// A stroke turned the view to face its plane: its points map through the new camera at once,
    /// not through the last frame drawn (which still shows the plane edge-on), until that frame draws.
    private var strokeTurnedView = false

    private var screenCamera: ScreenCamera {
        if view.window != nil, let renderedCamera, !strokeTurnedView { return renderedCamera }
        return ScreenCamera(origin: SIMD3<Double>(target), right: viewRight, up: viewUp, direction: viewDirection, height: orthographicHeight)
    }

    /// A frame was drawn with a new camera: redraw the overlay to match it.
    fileprivate func cameraRendered(_ camera: ScreenCamera) {
        guard camera != renderedCamera else { return }
        renderedCamera = camera
        strokeTurnedView = false
        guard isViewLoaded, view.window != nil else { return }
        input.updateDimensions(dimensionAnnotations())
        input.setNeedsDisplay()
    }

    private func pointOnPlane(_ screen: CGPoint, plane: SketchPlane) -> Point2? {
        // Use the same orthographic camera math for rendering input and the overlay.
        // SCNView's projection APIs can use a stale presentation camera between render frames.
        let normal = SIMD3(Double(plane.normal.x), Double(plane.normal.y), Double(plane.normal.z))
        let direction = screenCamera.direction
        let denominator = simd_dot(direction, normal)
        guard abs(denominator) > 1e-5 else { return nil }
        let origin = viewPlanePoint(screen)
        // Face planes do not pass through the world origin; measure from the plane's own origin.
        let world = origin - direction * (simd_dot(origin - plane.origin, normal) / denominator)
        let point = plane.local(SIMD3(Float(world.x), Float(world.y), Float(world.z)))
        return point.isValid ? point : nil
    }

    private func viewPlanePoint(_ screen: CGPoint) -> SIMD3<Double> {
        let camera = screenCamera, scale = camera.height / max(1, Double(view.bounds.height))
        return camera.origin + camera.right * ((Double(screen.x) - Double(view.bounds.width) / 2) * scale) +
            camera.up * ((Double(view.bounds.height) / 2 - Double(screen.y)) * scale)
    }

    func project(_ point: SIMD3<Float>) -> CGPoint {
        let camera = screenCamera, scale = camera.height / max(1, Double(view.bounds.height))
        let offset = SIMD3<Double>(point) - camera.origin
        return CGPoint(x: Double(view.bounds.width) / 2 + simd_dot(offset, camera.right) / scale,
                       y: Double(view.bounds.height) / 2 - simd_dot(offset, camera.up) / scale)
    }

    func pencilBegan(at point: CGPoint) {
        guard session.acceptsPencil else { return }
        finishCameraTransition()
        // Hit-test labels in their own (possibly rotated) frame; a rotated label's bounding box
        // would otherwise cover the double-arrow beside it.
        if let annotation = dimensionAnnotations().first(where: { annotation in
            guard let button = input.dimensionButton(for: annotation.target) else { return false }
            let local = button.convert(point, from: input)
            return button.bounds.insetBy(dx: -8, dy: -8).contains(local)
        }) {
            session.openDimension(annotation.target, at: annotation.center)
            return
        }
        closeDimensionEdit()
        gestures.forEach { $0.isEnabled = false }
        strokeStarted = true
        session.viewCube.pencilActive = true
        session.isPencilDown = true
        pencilStartScreen = point
        // Picking a plane: a tap on a plane or face starts the sketch there; a stroke in open space
        // starts it on the grid and carries on drawing below.
        if session.isPickingPlane, pickPlane(at: point) { return }
        if let section = session.section {
            // The section view is for looking: only its double-arrow moves the plane.
            if let handle = sectionHandle(), handle.hitArea.contains(point) {
                let origin = project(SIMD3<Float>(section.origin)), ahead = project(SIMD3<Float>(section.origin + section.normal * 10))
                let scale = Double(hypot(ahead.x - origin.x, ahead.y - origin.y)) / 10
                sectionGesture = (section.offset, handle.axis, scale >= 0.5 ? scale : 1 / unitsPerPoint, section.flipped ? -1 : 1)
            }
            return
        }
        if session.isExtruding {
            if let handle = extrusionHandle(), handle.hitArea.contains(point) { startExtrusionDrag(handle); return }
            if session.isPickingExtrusionTarget {
                // Up To: a flat face, or a construction plane, parallel to the sketch.
                if let hit = frontSurface(at: point, committed: true), let plane = hit.plane {
                    session.extrude(upTo: hit.point, normal: plane.normalAxis)
                } else if let hit = constructionPlaneHit(at: point) {
                    session.extrude(upTo: hit.plane.plane.origin, normal: hit.plane.plane.normalAxis)
                }
                return
            }
            // Another region on the same plane is extruded too (or taken out again).
            if session.faceExtrusion == nil, let profile = session.extrusionProfile, let local = pointOnPlane(point, plane: profile.plane),
               let other = session.visibleWorkspace.profiles.first(where: { ModelingSession.isSamePlane($0.plane, profile.plane) && $0.contains(local) }) {
                session.toggleExtrusionProfile(other)
            }
            return
        }
        if let draft = session.revolveDraft {
            if let handle = revolveHandle(), handle.hitArea.contains(point) {
                revolveGesture = (draft.angle, handle.axis, handle.perDegree)
            } else {
                // Any other tap picks (or changes) the axis.
                if let axis = revolveAxis(at: point) { session.pickRevolveAxis(axis) }
            }
            return
        }
        if let widget = transformWidget(), widget.canPivot, distance(point, widget.center) < 16, session.beginPivotDrag() {
            draggingPivot = true
            return
        }
        if let widget = transformWidget(), let handle = widget.handle(at: point), !sketchHandleUnder(point), session.beginTransform(handle) {
            switch handle {
            case .move(let axis):
                let arrow = widget.arrows.first { $0.axis == axis }!
                transformGesture = (handle, arrow.direction, arrow.pointsPerMillimeter, widget.center, 0, 0, 0)
            case .rotate(let axis):
                let angle = atan2(point.y - widget.center.y, point.x - widget.center.x)
                transformGesture = (handle, .zero, 1, widget.center, angle, 0, widget.toward[axis])
            }
            return
        }
        if session.tool.isPlaneTool {
            if let handle = planeHandle(), handle.hitArea.contains(point), let draft = session.planeDraft,
               let reference = draft.references.first, let preview = session.planePreview {
                let origin = project(SIMD3<Float>(preview.plane.origin))
                let ahead = project(SIMD3<Float>(preview.plane.origin + reference.normal * 10))
                let scale = Double(hypot(ahead.x - origin.x, ahead.y - origin.y)) / 10
                planeGesture = (draft.offset, handle.axis, scale >= 0.5 ? scale : 1 / unitsPerPoint)
            } else if let reference = planeReference(at: point) {
                session.pickPlaneReference(reference)
            }
            return
        }
        if session.tool == .project {
            projectionTap(at: point)
            return
        }
        if session.tool == .split {
            splitTap(at: point)
            return
        }
        if session.tool == .mirror {
            mirrorTap(at: point)
            return
        }
        if session.patternDraft != nil {
            patternDown(at: point)
            return
        }
        if session.scaleDraft != nil {
            scaleDown(at: point)
            return
        }
        if session.tool == .deleteFace {
            // Faces are picked as committed; a tap on empty space finishes, as Shell does.
            if let hit = frontSurface(at: point, committed: true) {
                session.toggleDeleteFace(bodyID: hit.bodyID, face: hit.face, at: hit.point)
            } else if session.deleteFacePreview != nil {
                session.confirmDeleteFace()
            }
            return
        }
        if session.tool == .union || session.tool == .intersect {
            // Solids are picked as committed, not as the united preview.
            if let hit = frontSurface(at: point, committed: true) { session.toggleUnionBody(hit.bodyID) }
            return
        }
        if session.tool == .subtract {
            if let hit = frontSurface(at: point, committed: true) { session.toggleSubtractBody(hit.bodyID) }
            return
        }
        if session.tool == .align {
            if let handle = alignHandle(), handle.hitArea.contains(point), let draft = session.alignDraft, let to = draft.to {
                let anchor = project(SIMD3<Float>(to.point)), ahead = project(SIMD3<Float>(to.point + to.direction * 10))
                let scale = Double(hypot(ahead.x - anchor.x, ahead.y - anchor.y)) / 10
                alignGesture = (draft.offset, handle.axis, scale >= 0.5 ? scale : 1 / unitsPerPoint)
            } else {
                alignTap(at: point)
            }
            return
        }
        if session.tool == .shell {
            if let handle = shellHandle(), handle.hitArea.contains(point), let draft = session.shellDraft {
                draggingShell = true
                shellStartThickness = draft.thickness
            } else if let hit = shellFace(at: point) {
                session.toggleShellFace(bodyID: hit.bodyID, face: hit.face, at: hit.point)
            } else if session.shellPreview != nil {
                // A tap on empty space completes the shell.
                session.confirmShell()
            }
            return
        }
        if session.tool.isFaceFeature, session.sketchMode?.face != nil {
            if let local = pointOnPlane(point, plane: session.plane) {
                let result = snapped(local)
                switch session.tool {
                case .hole: session.placeHole(at: result.point)
                case .text: session.placeText(at: result.point)
                default: session.placePeg(at: result.point)
                }
                session.snapLabel = session.snapEnabled ? result.label : ""
            }
            return
        }
        if session.tool.primitiveKind != nil {
            // On a flat face it stands on the face; elsewhere on the grid's plane.
            if let face = solidFace(at: point), let plane = face.plane {
                session.placePrimitive(on: plane, at: plane.coordinates(of: face.point))
            } else if let local = pointOnPlane(point, plane: session.plane) {
                session.placePrimitive(on: session.plane, at: snapped(local).point)
            }
            return
        }
        if session.tool == .thread {
            if session.threadDraft == nil, let hit = solidFace(at: point), hit.plane == nil { session.beginThread(bodyID: hit.bodyID, face: hit.face) }
            return
        }
        if session.tool == .peg {
            // Off a face: a tap on a flat face sketches on it with the Peg tool ready, as Sketch would.
            if let face = solidFace(at: point), face.plane != nil {
                selectFace(face)
                session.beginFaceSketch()
                session.chooseTool(.peg)
            }
            return
        }
        if session.tool == .measure {
            measureTap(at: point)
            return
        }
        if session.tool == .dimension {
            session.pickDimensionReference(dimensionReference(at: point))
            return
        }
        if session.tool == .cornerFillet {
            if let corner = cornerUnder(point) { session.roundCorner(at: corner) }
            return
        }
        if session.tool == .trim {
            session.beginTrim()
            trimming = true
            trimStart = point
            trimTouchedShape = trimUnder(point)
            return
        }
        if session.tool.finishKind != nil {
            if let handle = finishHandle(), handle.hitArea.contains(point), let draft = session.finishDraft {
                draggingFinish = true
                finishStartSize = draft.size
            } else if let (bodyID, edge) = finishEdge(at: point) {
                session.toggleFinishEdge(bodyID: bodyID, edge: edge)
            }
            return
        }
        if session.tool == .select {
            // Double-tapping a sketch line selects the whole sketch (like double-tapping a solid).
            let line = nearestSketch(at: point, over: session.sketchMode == nil ? solidFace(at: point) : nil)
            let now = CACurrentMediaTime()
            if let line, let id = line.sketch, let last = lastSketchTap, last.sketchID == id, now - last.time < Self.doubleTapInterval,
               distance(point, last.point) < Self.doubleTapDistance {
                lastSketchTap = nil
                session.selectSketch(id)
                return
            }
            lastSketchTap = nil
            pendingSketchTap = line?.sketch.map { ($0, now, point) }
            if beginSketchDrag(at: point) { return }
            // The arrow on a selected region or face starts an extrusion right away; the arrow on
            // a selected edge starts a fillet. Sketch handles above win where they overlap, and the
            // region arrow's target is just its glyph.
            if let handle = selectionExtrudeHandle(), distance(point, handle.center) < 20 {
                if session.selectedFace != nil { session.beginFaceExtrusion() } else { session.beginExtrusion() }
                if session.isExtruding, let started = extrusionHandle() { operationStartedAtDown = .extrude; startExtrusionDrag(started) }
                return
            }
            if let handle = edgeSelectionHandle(), handle.hitArea.contains(point) {
                session.finishSelectedEdge(.fillet)
                if let draft = session.finishDraft { operationStartedAtDown = .fillet; draggingFinish = true; finishStartSize = draft.size }
                return
            }
            // While sketching, solids are context only; outside sketch mode a tap picks a face.
            select(at: point, bodies: session.sketchMode == nil)
            _ = beginSketchDrag(at: point)
            return
        }
        if [.circle, .rectangle, .arc, .slot, .ellipse, .point].contains(session.tool), beginSketchDrag(at: point) { return }
        if [.extend, .offset, .sketchMirror].contains(session.tool) {
            // These pick drawn shapes on the sketch plane.
            let shape = nearestSketch(at: point, over: nil)
            switch session.tool {
            case .extend: if let shape, let local = pointOnPlane(point, plane: shape.plane) { session.extend(shape.id, near: local) }
            case .offset: if let shape { session.pickOffsetShape(shape.id) }
            default: if let shape { session.pickSketchMirrorShape(shape.id) }
            }
            return
        }
        if session.tool == .polygon {
            if abs(simd_dot(viewDirection, session.plane.normalAxis)) < 0.26 { align(to: session.plane); strokeTurnedView = true }
            guard let local = pointOnPlane(point, plane: session.plane) else { return }
            let result = snapped(local)
            liveSnap = (result, session.plane)
            polygonStroke = (result.point, session.plane)
            session.snapLabel = session.snapEnabled ? result.label : ""
            return
        }
        guard let kind = session.tool.shapeKind else { select(at: point, bodies: session.tool != .extrude && session.tool != .revolve); return }
        // Strokes always draw on the sketch plane (choose a face with its Sketch button), and may be
        // drawn at an angle in 3D. Only a nearly edge-on plane (under ~15°) turns to face the view,
        // since rays there are too unstable to place points.
        if abs(simd_dot(viewDirection, session.plane.normalAxis)) < 0.26 { align(to: session.plane); strokeTurnedView = true }
        guard let local = pointOnPlane(point, plane: session.plane) else { return }
        let result = snapped(local)
        liveSnap = (result, session.plane)
        let fromCenter = kind == .rectangle && session.rectangleFromCenter
        strokeCenter = fromCenter ? result.point : nil
        strokeStart = result.point
        strokePoints = [local]
        activeShape = kind == .slot ? SketchShape.slot(from: result.point, to: result.point, width: session.slotWidth, plane: session.plane)
            : SketchShape(kind: kind, plane: session.plane, start: result.point, end: result.point, centered: fromCenter ? true : nil,
                          width: kind == .ellipse ? 0 : nil)
        strokePlane = session.plane
        session.preview = activeShape
        session.snapLabel = session.snapEnabled ? result.label : ""
    }

    func pencilMoved(to point: CGPoint) {
        if trimming {
            if trimUnder(point) { trimTouchedShape = true }
            return
        }
        if draggingPatternCenter {
            session.previewPatternCenter(pivotSnap(at: point, in: patternCenterSnaps()))
            return
        }
        if let gesture = scaleGesture, let draft = session.scaleDraft {
            // The arrow's tip moves with the items' far side: dragging it by the items' reach doubles them.
            let along = Double((point.x - pencilStartScreen.x) * gesture.direction.dx + (point.y - pencilStartScreen.y) * gesture.direction.dy)
            var percent = max(0.1, gesture.start * (1 + along / gesture.pointsPerMillimeter / gesture.reach))
            percent = session.snapEnabled ? max(1, percent.rounded()) : (percent * 10).rounded() / 10
            session.setScalePercent(percent, axis: draft.uniform ? 3 : gesture.axis)
            return
        }
        if let gesture = patternGesture {
            switch gesture.handle {
            case .move(let axis):
                let along = Double((point.x - pencilStartScreen.x) * gesture.direction.dx + (point.y - pencilStartScreen.y) * gesture.direction.dy)
                var distance = gesture.start + along / gesture.pointsPerMillimeter
                if session.snapEnabled { distance = session.lengthUnit.rounded(distance) }
                session.setPatternDistance(distance, axis: axis)
            case .rotate(let axis):
                // The angle swept around the gizmo center, counting past half a revolution.
                let current = atan2(point.y - gesture.center.y, point.x - gesture.center.x)
                var step = current - gesture.lastAngle
                if step > .pi { step -= 2 * .pi } else if step < -.pi { step += 2 * .pi }
                let turned = gesture.turned + step
                patternGesture?.lastAngle = current
                patternGesture?.turned = turned
                var angle = gesture.start - Double(turned) * 180 / .pi * (gesture.toward >= 0 ? 1 : -1)
                angle = session.snapEnabled ? (angle / 5).rounded() * 5 : (angle * 10).rounded() / 10
                session.setPatternAngle(angle, axis: axis)
            }
            return
        }
        if draggingPivot {
            session.previewPivot(pivotSnap(at: point))
            return
        }
        if let drag = sketchDrag {
            guard dragMoved || distance(point, pencilStartScreen) > Self.sketchDragSlop,
                  let local = pointOnPlane(point, plane: drag.shape.plane) else { return }
            dragMoved = true
            var endpoint = local + drag.offset
            if session.snapEnabled {
                let fixed = drag.handle == .start ? drag.shape.end : drag.shape.start
                let result = SketchSnap.snap(endpoint, start: fixed,
                                             shapes: session.workspace.visible.shapes.filter { $0.id != drag.shape.id },
                                             plane: drag.shape.plane, grid: session.snapGrid, tolerance: unitsPerPoint * 8,
                                             align: drag.shape.kind == .line,
                                             excluding: [SketchEditing.handlePoint(drag.handle, on: drag.shape)],
                                             guides: session.sketchMode?.plane == drag.shape.plane ? session.sketchGuides : [],
                                             origin: worldOrigin(on: drag.shape.plane))
                endpoint = result.point
                session.snapLabel = result.label
                liveSnap = (result, drag.shape.plane)
            }
            _ = session.updateSketchDrag(to: endpoint)
            return
        }
        if draggingExtrusion && session.isExtruding {
            // Movement along the double-arrow (the on-screen extrusion direction) changes signed depth,
            // so dragging toward a solid moves into it. Axis and sensitivity are captured at Pencil
            // down so the moving preview cannot change the drag.
            let along = Double((point.x - pencilStartScreen.x) * extrusionDragAxis.dx + (point.y - pencilStartScreen.y) * extrusionDragAxis.dy)
            // Both ways, the far end moves half as far as the depth grows.
            var depth = extrusionStartDepth + along / extrusionPointsPerMillimeter * (session.extrusionSymmetric ? 2 : 1)
            if session.snapEnabled { depth = session.lengthUnit.rounded(depth) }
            depth = max(-10_000, min(10_000, depth))
            // Back on the plane is 0 mm, the starting state, where Done stays disabled.
            if abs(depth) < 0.01 { depth = 0 }
            session.extrusionDepth = depth
            return
        }
        if let gesture = revolveGesture {
            // Movement along the curved arrow (where it points as the drag starts) turns the region.
            let along = Double((point.x - pencilStartScreen.x) * gesture.axis.dx + (point.y - pencilStartScreen.y) * gesture.axis.dy)
            var angle = gesture.start + along / gesture.perDegree
            angle = session.snapEnabled ? angle.rounded() : (angle * 10).rounded() / 10
            angle = max(-360, min(360, angle))
            // Back on the sketch plane is 0°, the starting state, where Done stays disabled.
            if abs(angle) < 0.1 { angle = 0 }
            session.setRevolveAngle(angle)
            return
        }
        if let gesture = alignGesture {
            let along = Double((point.x - pencilStartScreen.x) * gesture.axis.dx + (point.y - pencilStartScreen.y) * gesture.axis.dy)
            var offset = gesture.start + along / gesture.pointsPerMillimeter
            if session.snapEnabled { offset = session.lengthUnit.rounded(offset) }
            session.setAlignOffset(offset)
            return
        }
        if let gesture = sectionGesture {
            let along = Double((point.x - pencilStartScreen.x) * gesture.axis.dx + (point.y - pencilStartScreen.y) * gesture.axis.dy)
            var offset = gesture.start + along / gesture.pointsPerMillimeter * gesture.sign
            if session.snapEnabled { offset = session.lengthUnit.rounded(offset) }
            session.setSectionOffset(offset)
            return
        }
        if let gesture = planeGesture {
            let along = Double((point.x - pencilStartScreen.x) * gesture.axis.dx + (point.y - pencilStartScreen.y) * gesture.axis.dy)
            var offset = gesture.start + along / gesture.pointsPerMillimeter
            if session.snapEnabled { offset = session.lengthUnit.rounded(offset) }
            session.setPlaneOffset(offset)
            return
        }
        if let gesture = transformGesture {
            var amount: Double
            switch gesture.handle {
            case .move:
                let along = Double((point.x - pencilStartScreen.x) * gesture.direction.dx + (point.y - pencilStartScreen.y) * gesture.direction.dy)
                amount = along / gesture.pointsPerMillimeter
                if session.snapEnabled { amount = session.lengthUnit.rounded(amount) }
            case .rotate:
                // Accumulate the angle swept around the widget center (screen y points down), so
                // turns past half a revolution keep counting.
                let angle = atan2(point.y - gesture.center.y, point.x - gesture.center.x)
                var step = angle - gesture.lastAngle
                if step > .pi { step -= 2 * .pi } else if step < -.pi { step += 2 * .pi }
                transformGesture?.lastAngle = angle
                transformGesture?.turned += step
                // Facing the viewer, a positive (right-handed) turn looks counter-clockwise.
                amount = -Double(gesture.turned + step) * 180 / .pi * (gesture.toward >= 0 ? 1 : -1)
                amount = session.snapEnabled ? (amount / 5).rounded() * 5 : (amount * 10).rounded() / 10
            }
            session.updateTransform(amount)
            return
        }
        if draggingShell {
            var thickness = shellStartThickness - Double(point.y - pencilStartScreen.y) * unitsPerPoint * 0.25
            if session.snapEnabled { thickness = session.lengthUnit.rounded(thickness) }
            session.setShellThickness(thickness)
            return
        }
        if draggingFinish {
            // Up enlarges, down shrinks: half a millimeter per on-screen millimeter of zoomed model.
            var size = finishStartSize - Double(point.y - pencilStartScreen.y) * unitsPerPoint * 0.5
            if session.snapEnabled { size = session.lengthUnit.rounded(size) }
            session.setFinishSize(size)
            return
        }
        if let stroke = polygonStroke, let local = pointOnPlane(point, plane: stroke.plane) {
            let result = snapped(local, start: stroke.center)
            liveSnap = (result, stroke.plane)
            let lines = SketchTools.polygon(center: stroke.center, vertex: result.point, sides: session.polygonSides, plane: stroke.plane)
            session.preview = lines.isEmpty ? nil : SketchShape.curve(lines.map(\.start), closed: true, plane: stroke.plane)
            session.snapLabel = session.snapEnabled ? result.label : ""
            return
        }
        guard var shape = activeShape, let plane = strokePlane, let local = pointOnPlane(point, plane: plane) else { return }
        if shape.kind == .point {
            let result = snapped(local)
            liveSnap = (result, plane)
            shape.start = result.point; shape.end = result.point
            activeShape = shape
            session.preview = shape
            session.snapLabel = session.snapEnabled ? result.label : ""
            return
        }
        if shape.kind == .ellipse, let start = strokeStart {
            // From the center to a corner of the box around it: its axis along the longer side.
            let result = snapped(local, start: start)
            liveSnap = (result, plane)
            let d = result.point - start
            if abs(d.x) >= abs(d.y) { shape.end = start + Point2(x: d.x, y: 0); shape.width = 2 * abs(d.y) }
            else { shape.end = start + Point2(x: 0, y: d.y); shape.width = 2 * abs(d.x) }
            activeShape = shape
            session.preview = shape
            session.snapLabel = session.snapEnabled ? result.label : ""
            return
        }
        let result = snapped(local, start: strokeStart ?? shape.start, align: shape.kind == .line)
        liveSnap = (result, plane)
        if shape.kind == .arc, let start = strokeStart {
            // Three points: the ends, and the stroke's point farthest from the line between them.
            strokePoints.append(local)
            let chord = result.point - start, length = chord.length
            let middle = strokePoints.max { a, b in
                length > 1e-9 ? abs(Geometry.cross(chord, a - start)) < abs(Geometry.cross(chord, b - start)) : a.distance(to: start) < b.distance(to: start)
            } ?? local
            if let arc = SketchShape.arc(from: start, through: middle, to: result.point, plane: plane) { shape = arc }
            else { shape = SketchShape(kind: .arc, plane: plane, start: start, end: result.point) }
            activeShape = shape
            session.preview = shape
            session.snapLabel = session.snapEnabled ? result.label : ""
            return
        }
        shape.end = result.point
        // From the center: the Pencil is a corner and the opposite corner mirrors it.
        if let center = strokeCenter { shape.start = center * 2 - result.point }
        activeShape = shape
        session.preview = shape
        session.snapLabel = session.snapEnabled ? result.label : ""
    }

    func pencilEnded(at point: CGPoint, cancelled: Bool) {
        guard strokeStarted else { return }
        if let tap = pendingSketchTap, !cancelled, distance(point, tap.point) < 6 { lastSketchTap = tap }
        pendingSketchTap = nil
        if !cancelled { pencilMoved(to: point) }
        if sketchDrag != nil { session.finishSketchDrag(cancelled: cancelled) }
        if cancelled && draggingExtrusion { session.extrusionDepth = extrusionStartDepth }
        if cancelled && draggingFinish { session.setFinishSize(finishStartSize) }
        if cancelled && draggingShell { session.setShellThickness(shellStartThickness) }
        if transformGesture != nil {
            transformGesture = nil
            session.finishTransform(cancelled: cancelled)
        }
        if draggingPivot {
            draggingPivot = false
            session.finishPivotDrag(cancelled: cancelled)
        }
        if draggingPatternCenter {
            draggingPatternCenter = false
            session.finishPatternCenterDrag(cancelled: cancelled)
        }
        if let gesture = scaleGesture {
            scaleGesture = nil
            if cancelled { session.setScalePercent(gesture.start, axis: session.scaleDraft?.uniform == false ? gesture.axis : 3) }
        }
        if let gesture = patternGesture {
            patternGesture = nil
            if cancelled {
                switch gesture.handle {
                case .move(let axis): session.setPatternDistance(gesture.start, axis: axis)
                case .rotate(let axis): session.setPatternAngle(gesture.start, axis: axis)
                }
            }
        }
        if let gesture = planeGesture {
            planeGesture = nil
            if cancelled { session.setPlaneOffset(gesture.start) }
        }
        if let gesture = sectionGesture {
            sectionGesture = nil
            if cancelled { session.setSectionOffset(gesture.start) }
        }
        if let gesture = alignGesture {
            alignGesture = nil
            if cancelled { session.setAlignOffset(gesture.start) }
        }
        if let gesture = revolveGesture {
            revolveGesture = nil
            if cancelled { session.setRevolveAngle(gesture.start) }
        }
        if session.tool.isFaceFeature { session.snapLabel = "" }
        if trimming {
            trimming = false
            session.finishTrim(cancelled: cancelled)
            // A tap on empty space completes Trim.
            if !cancelled, !trimTouchedShape, let start = trimStart, distance(point, start) < 6 { session.chooseTool(.select) }
            trimStart = nil
            trimTouchedShape = false
        }
        if let stroke = polygonStroke {
            polygonStroke = nil
            if !cancelled, let local = pointOnPlane(point, plane: stroke.plane), session.plane == stroke.plane {
                session.addPolygon(center: stroke.center, vertex: snapped(local, start: stroke.center).point)
            } else { session.preview = nil; session.snapLabel = "" }
        } else if !cancelled, let shape = activeShape, session.tool.shapeKind == shape.kind, session.plane == shape.plane { session.addShape(shape) }
        else { session.preview = nil; session.snapLabel = "" }
        activeShape = nil
        sketchDrag = nil
        dragMoved = false
        strokePlane = nil
        if cancelled, let started = operationStartedAtDown {
            // The touch that started it was cancelled (a palm, a system gesture): leave nothing behind.
            if started == .extrude { session.cancelExtrusion() } else { session.cancelFinish() }
        }
        operationStartedAtDown = nil
        draggingExtrusion = false
        draggingFinish = false
        draggingShell = false
        liveSnap = nil
        strokeCenter = nil
        strokeStart = nil
        strokePoints = []
        strokeStarted = false
        session.viewCube.pencilActive = false
        session.isPencilDown = false
        gestures.forEach { $0.isEnabled = true }
    }

    func sketchHandles(for shape: SketchShape) -> [(SketchHandle, Point2)] {
        switch shape.kind {
        case .line: return [(.start, shape.start), (.end, shape.end)]
        case .circle: return [(.center, shape.start), (.radius, shape.end)]
        case .rectangle:
            return (0..<4).map { (.corner($0), shape.outline[$0]) } +
                (0..<4).map { (.side($0), SketchEditing.handlePoint(.side($0), on: shape)) } +
                (shape.isCentered ? [(.center, shape.center)] : [])
        case .arc: return [(.start, shape.start), (.end, shape.end), (.mid, shape.arcMiddle)]
        case .slot: return [(.start, shape.start), (.end, shape.end), (.side(0), SketchEditing.handlePoint(.side(0), on: shape))]
        case .ellipse: return [(.center, shape.start), (.end, shape.end), (.side(0), SketchEditing.handlePoint(.side(0), on: shape))]
        case .point: return [(.center, shape.start)]
        case .curve: return []   // projected geometry: delete or project again rather than drag
        }
    }

    /// Whether a handle of the selected shape is under the Pencil (it wins over the Move/Rotate widget).
    private func sketchHandleUnder(_ screen: CGPoint) -> Bool {
        guard let shape = editableShape, case .shape = session.transformWidgetTarget else { return false }
        return sketchHandles(for: shape).contains { distance(screen, project(shape.plane.world($0.1))) < 17 }
    }

    private func beginSketchDrag(at screen: CGPoint) -> Bool {
        // A sketch on another plane drags on its own plane, unless it is seen almost edge-on,
        // where the Pencil cannot place points on it reliably.
        guard let shape = editableShape,
              shape.plane == session.plane || abs(simd_dot(viewDirection, shape.plane.normalAxis)) > 0.15,
              let local = pointOnPlane(screen, plane: shape.plane) else { return false }
        var picked: (SketchHandle, Point2)?
        let handles = sketchHandles(for: shape).sorted {
            distance(screen, project(shape.plane.world($0.1))) < distance(screen, project(shape.plane.world($1.1)))
        }
        if let nearest = handles.first, distance(screen, project(shape.plane.world(nearest.1))) < 17 { picked = nearest }
        if picked == nil && shape.kind == .circle {
            let radius = shape.start.distance(to: shape.end)
            let direction = local - shape.start
            if direction.length > 1e-5 {
                let edge = shape.start + direction * (radius / direction.length)
                if distance(screen, project(shape.plane.world(edge))) < 12 { picked = (.radius, edge) }
            }
        }
        if picked == nil && shape.kind == .rectangle {
            let points = shape.outline.map { project(shape.plane.world($0)) }
            for i in 0..<4 {
                let d = Geometry.distance(.init(x: screen.x, y: screen.y), toSegment: .init(x: points[i].x, y: points[i].y),
                                          .init(x: points[(i + 1) % 4].x, y: points[(i + 1) % 4].y))
                if d < 10 { picked = (.side(i), SketchEditing.handlePoint(.side(i), on: shape)); break }
            }
        }
        guard let picked else { return false }
        sketchDrag = (shape, picked.0, picked.1 - local)
        dragMoved = false
        session.beginSketchDrag(shapeID: shape.id, handle: picked.0)
        return true
    }

    /// The world origin in a plane's coordinates, when the plane passes through it.
    private func worldOrigin(on plane: SketchPlane) -> Point2? {
        abs(plane.height(of: .zero)) < 1e-9 ? plane.coordinates(of: .zero) : nil
    }

    private func snapped(_ point: Point2, start: Point2? = nil, align: Bool = false) -> SnapResult {
        guard session.snapEnabled else { return SnapResult(point: point, label: "") }
        return SketchSnap.snap(point, start: start, shapes: session.workspace.visible.shapes, plane: session.plane,
                               grid: session.snapGrid, tolerance: unitsPerPoint * 10, align: align,
                               guides: session.sketchMode?.plane == session.plane ? session.sketchGuides : [],
                               origin: worldOrigin(on: session.plane))
    }

    /// `bodies: false` (the Extrude tool) picks sketches and regions even where a solid is in front.
    private func select(at point: CGPoint, bodies: Bool = true) {
        let surface = solidFace(at: point)
        let nearest = nearestSketch(at: point, over: surface)
        // A visible solid face is picked before sketches behind it. A sketch edge in front of it or
        // on it (such as a sketch drawn on that very face) still wins when it is under the Pencil.
        if bodies, session.tool == .select, nearest == nil, let (bodyID, edge) = finishEdge(at: point, tolerance: 8) {
            // A tap on a border picks the edge; a quick second tap picks the whole solid.
            let now = CACurrentMediaTime()
            if let last = lastFaceTap, last.bodyID == bodyID, now - last.time < Self.doubleTapInterval, distance(point, last.point) < Self.doubleTapDistance {
                lastFaceTap = nil
                session.select(.body(bodyID))
            } else {
                lastFaceTap = (bodyID, now, point)
                session.select(.edge(bodyID, edge))
            }
            return
        }
        if bodies, session.tool == .select, nearest == nil, let hit = constructionPlaneHit(at: point),
           hit.border || surface.map({ hit.depth > $0.depth + 1e-6 }) ?? false {
            session.select(.plane(hit.plane.id))
            return
        }
        if bodies, let hit = surface {
            if let nearest { tapSketchLine(nearest); return }
            let now = CACurrentMediaTime()
            if let last = lastFaceTap, last.bodyID == hit.bodyID, now - last.time < Self.doubleTapInterval, distance(point, last.point) < Self.doubleTapDistance {
                // Double-tap: the whole solid.
                lastFaceTap = nil
                session.select(.body(hit.bodyID))
                return
            }
            lastFaceTap = (hit.bodyID, now, point)
            // A sketch region drawn on the face (or in front of it) wins over the face, so the shape
            // the lines enclose can be extruded or cut; a quick second tap still picks the solid.
            if let profile = region(at: point, over: hit) { selectRegion(profile); return }
            selectFace(hit)
            return
        }
        // Give thin solid borders the same forgiving screen-space target as sketch edges.
        // Face hits above take priority, so an occluded body's edge cannot steal selection.
        var nearestBody: (id: UUID, distance: Double)?
        let pencil = Point2(x: point.x, y: point.y)
        for body in bodies ? session.workspace.visible.bodies : [] {
            if body.revolve != nil || body.isImported || !body.hasPlainSides {
                // Revolved, imported, and tapered solids have no straight extrusion outline; use their real borders.
                for border in solidRender(body)?.borders ?? [] {
                    for (a, b) in zip(border.map(project), border.dropFirst().map(project)) {
                        let distance = Geometry.distance(pencil, toSegment: Point2(x: a.x, y: a.y), Point2(x: b.x, y: b.y))
                        if distance < 8 && distance < (nearestBody?.distance ?? .infinity) { nearestBody = (body.id, distance) }
                    }
                }
                continue
            }
            let points = body.profile.outline
            let base = points.map { project(body.profile.plane.world($0, height: body.baseOffset)) }
            let end = points.map { project(body.profile.plane.world($0, height: body.baseOffset + body.depth)) }
            for i in points.indices {
                let next = (i + 1) % points.count
                for (a, b) in [(base[i], base[next]), (end[i], end[next]), (base[i], end[i])] {
                    let distance = Geometry.distance(pencil, toSegment: Point2(x: a.x, y: a.y), Point2(x: b.x, y: b.y))
                    if distance < 8 && distance < (nearestBody?.distance ?? .infinity) {
                        nearestBody = (body.id, distance)
                    }
                }
            }
        }
        if let nearestBody { session.select(.body(nearestBody.id)); return }
        if let nearest { tapSketchLine(nearest); return }
        // The frontmost region under the Pencil on any plane (a face sketch's too), never a solid's
        // hidden source sketch; the Extrude tool reaches it even behind a solid.
        if let profile = region(at: point, over: nil) {
            selectRegion(profile)
            return
        }
        // Extrude and Revolve take a flat face when no sketch is under the Pencil.
        if session.tool == .extrude || session.tool == .revolve, let surface, surface.plane != nil { selectFace(surface); return }
        // Inside a construction plane with nothing else under the Pencil picks the plane.
        if bodies, session.tool == .select, let hit = constructionPlaneHit(at: point) { session.select(.plane(hit.plane.id)); return }
        session.select(nil)
    }

    /// A region made by one closed shape selects that shape; one bounded by several, the region.
    /// With no tool chosen, a region on the plane of the regions or sketches already picked is
    /// added to them (or taken out).
    private func selectRegion(_ profile: SketchProfile) {
        let item: ModelSelection = profile.sourceIDs.count == 1 ? profile.sourceIDs.first.map { .shape($0) } ?? .profile(profile.id) : .profile(profile.id)
        if session.tool == .select { session.pickSketchItem(item) } else { session.select(item) }
    }

    /// The frontmost visible sketch region under the Pencil, on or in front of the solid face hit if any.
    private func region(at point: CGPoint, over surface: SurfaceHit?) -> SketchProfile? {
        var best: (profile: SketchProfile, depth: Double)?
        for profile in session.visibleWorkspace.profiles where abs(simd_dot(viewDirection, profile.plane.normalAxis)) > 0.05 && !isCovered(profile) {
            guard let local = pointOnPlane(point, plane: profile.plane), profile.contains(local) else { continue }
            let depth = simd_dot(profile.plane.point(local), viewDirection)
            if depth > best?.depth ?? -.infinity { best = (profile, depth) }
        }
        guard let best, best.depth >= (surface?.depth ?? -.infinity) - max(0.05, unitsPerPoint * 2) else { return nil }
        return best.profile
    }

    /// Pencil down on an extrusion double-arrow: depth follows movement along it. Axis and scale are
    /// captured now so the moving preview cannot change the drag.
    private func startExtrusionDrag(_ handle: ExtrusionHandle) {
        guard let profile = session.extrusionProfile else { return }
        draggingExtrusion = true
        extrusionStartDepth = session.extrusionDepth
        extrusionDragAxis = handle.axis
        let origin = project(profile.plane.world(profile.anchor))
        let normal = project(profile.plane.world(profile.anchor, height: 10))
        let projectedScale = Double(hypot(normal.x - origin.x, normal.y - origin.y)) / 10
        extrusionPointsPerMillimeter = projectedScale >= 0.5 ? projectedScale : 1 / unitsPerPoint
    }

    /// A sketch line tapped with no tool chosen opens its sketch where it is (the camera stays put);
    /// the Extrude tool just picks it to extrude.
    /// With regions or sketches already picked on its plane, the tap adds the whole sketch instead
    /// (or takes it out).
    private func tapSketchLine(_ shape: SketchShape) {
        if session.tool == .select, let id = shape.sketch, session.addsToSelection(.sketch(id)) {
            // A double-tap picks the whole sketch once: the second tap leaves it picked.
            pendingSketchTap = nil
            let now = CACurrentMediaTime(), point = pencilStartScreen
            if let last = lastPickTap, last.sketchID == id, now - last.time < Self.doubleTapInterval, distance(point, last.point) < Self.doubleTapDistance {
                lastPickTap = nil
                return
            }
            lastPickTap = (id, now, point)
            session.pickSketchItem(.sketch(id))
            return
        }
        if session.tool == .select { session.enterSketch(of: shape.id) } else { session.select(.shape(shape.id)) }
    }

    /// Sketch tile: the nearest of the three world planes (or a flat solid face in front of them)
    /// under the Pencil starts a sketch there. Anywhere else starts it on the grid's plane without
    /// turning the view, and returns false so the stroke draws.
    private func pickPlane(at point: CGPoint) -> Bool {
        let half = planePickerHalfSize
        var best: (plane: SketchPlane, depth: Double)?
        for plane in SketchPlane.allCases where abs(simd_dot(viewDirection, plane.normalAxis)) > 0.05 {
            guard let local = pointOnPlane(point, plane: plane), abs(local.x) <= half, abs(local.y) <= half else { continue }
            let depth = simd_dot(plane.point(local), viewDirection)
            if depth > best?.depth ?? -.infinity { best = (plane, depth) }
        }
        let construction = constructionPlaneHit(at: point)
        let face = solidFace(at: point).flatMap { $0.plane != nil ? $0 : nil }
        if let construction, construction.depth >= max(best?.depth ?? -.infinity, face?.depth ?? -.infinity) - 1e-6 {
            session.pickConstructionPlane(construction.plane.id)
        } else if let face, face.depth > (best?.depth ?? -.infinity) + 1e-6 {
            let pending = session.tool
            session.cancelPlanePick()
            selectFace(face)
            session.beginFaceSketch()
            if pending.shapeKind != nil || pending.isSketchEditTool { session.chooseTool(pending) }
        } else if let best {
            session.pickPlane(best.plane)
        } else {
            session.startSketchOnGrid()
            return false
        }
        return true
    }

    /// The visible construction plane under the Pencil (inside its rectangle or near its border),
    /// nearest the viewer first.
    func constructionPlaneHit(at point: CGPoint) -> (plane: ConstructionPlane, depth: Double, border: Bool)? {
        let pencil = Point2(x: point.x, y: point.y)
        var best: (plane: ConstructionPlane, depth: Double, border: Bool)?
        for construction in session.visibleWorkspace.constructionPlanes {
            let corners = construction.outline.map { project(construction.plane.world($0)) }
            let border = corners.indices.map { i in
                Geometry.distance(pencil, toSegment: Point2(x: corners[i].x, y: corners[i].y),
                                  Point2(x: corners[(i + 1) % 4].x, y: corners[(i + 1) % 4].y))
            }.min() ?? .infinity
            var depth: Double?
            if abs(simd_dot(viewDirection, construction.plane.normalAxis)) > 0.05, let local = pointOnPlane(point, plane: construction.plane),
               construction.contains(local) {
                depth = simd_dot(construction.plane.point(local), viewDirection)
            } else if border < 10 {
                depth = simd_dot(construction.plane.origin, viewDirection)
            }
            guard let depth, depth > best?.depth ?? -.infinity else { continue }
            best = (construction, depth, border < 10)
        }
        return best
    }

    /// What Offset Plane / Midplane picks under the Pencil: the nearest flat face, sketch region, or
    /// construction plane; the world plane squares only where none of those is (they reach past
    /// small solids, and a face is what is usually meant).
    private func planeReference(at point: CGPoint, committed: Bool = false) -> PlaneReference? {
        var best: (reference: PlaneReference, depth: Double)?
        func consider(_ reference: PlaneReference?, _ depth: Double) {
            guard let reference, depth > (best?.depth ?? -.infinity) + 1e-6 else { return }
            best = (reference, depth)
        }
        if let face = frontSurface(at: point, committed: committed), face.plane != nil,
           let body = session.workspace.bodies.first(where: { $0.id == face.bodyID }) {
            consider(.face(face.face, of: body), face.depth)
        }
        if let hit = constructionPlaneHit(at: point) { consider(.construction(hit.plane), hit.depth) }
        for profile in session.visibleWorkspace.profiles where abs(simd_dot(viewDirection, profile.plane.normalAxis)) > 0.05 {
            guard let local = pointOnPlane(point, plane: profile.plane), Geometry.contains(local, in: profile.outline) else { continue }
            consider(.profile(profile), simd_dot(profile.plane.point(local), viewDirection))
        }
        if best != nil { return best?.reference }
        let half = PlaneReference.worldHalfSize
        for plane in SketchPlane.allCases where abs(simd_dot(viewDirection, plane.normalAxis)) > 0.05 {
            guard let local = pointOnPlane(point, plane: plane), abs(local.x) <= half, abs(local.y) <= half else { continue }
            consider(.world(plane), simd_dot(plane.point(local), viewDirection))
        }
        return best?.reference
    }

    /// The double-arrow on an Offset Plane preview, along its reference's normal.
    func planeHandle() -> ExtrusionHandle? {
        guard session.tool == .offsetPlane, let preview = session.planePreview, let reference = session.planeDraft?.references.first else { return nil }
        let origin = project(SIMD3<Float>(preview.plane.origin)), ahead = project(SIMD3<Float>(preview.plane.origin + reference.normal * 10))
        let dx = ahead.x - origin.x, dy = ahead.y - origin.y, length = hypot(dx, dy)
        let axis = length > 4 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: -1)
        return ExtrusionHandle(origin: origin, face: origin, center: CGPoint(x: origin.x + axis.dx * 22, y: origin.y + axis.dy * 22), axis: axis)
    }

    // MARK: Align

    /// Align: a tap picks a solid to move, the face or edge on it to align, or the target,
    /// depending on the step. Everything is picked as committed, not where the preview moved it.
    private func alignTap(at point: CGPoint) {
        guard let draft = session.alignDraft else { return }
        let moving = Set(draft.bodies)
        switch draft.step {
        case .bodies:
            if let hit = frontSurface(at: point, committed: true) { session.toggleAlignBody(hit.bodyID) }
        case .from:
            // Corners first: a tap near one picks the point rather than the edges meeting there.
            if let corner = alignPoint(at: point, moving: moving, from: true) {
                session.setAlignFrom(corner)
            } else if let (bodyID, edge) = solidEdge(at: point, tolerance: 8), moving.contains(bodyID),
               let body = session.workspace.bodies.first(where: { $0.id == bodyID }), let feature = AlignFeature.edge(edge, of: body) {
                session.setAlignFrom(feature)
            } else if let hit = frontSurface(at: point, committed: true), moving.contains(hit.bodyID), hit.plane != nil,
                      let body = session.workspace.bodies.first(where: { $0.id == hit.bodyID }), let reference = PlaneReference.face(hit.face, of: body) {
                session.setAlignFrom(.plane(reference))
            }
        case .to:
            let surface = frontSurface(at: point, committed: true)
            if let target = alignPoint(at: point, moving: moving, from: false) {
                session.setAlignTo(target)
            } else if let line = nearestSketch(at: point, over: surface), let feature = AlignFeature.shape(line) {
                session.setAlignTo(feature)
            } else if let (bodyID, edge) = solidEdge(at: point, tolerance: 8), !moving.contains(bodyID),
                      let body = session.workspace.bodies.first(where: { $0.id == bodyID }), let feature = AlignFeature.edge(edge, of: body) {
                session.setAlignTo(feature)
            } else if let reference = planeReference(at: point, committed: true) {
                if case .face(let bodyID, _) = reference.source, moving.contains(bodyID) { return }
                session.setAlignTo(.plane(reference))
            }
        }
    }

    /// Points Align can pick, with what each is: corners of the moving solids for From; for To,
    /// corners of the other solids, sketch points, and the origin. Only points not hidden behind a
    /// face are offered.
    private func alignPoints(moving: Set<UUID>, from: Bool) -> [AlignFeature] {
        var result: [AlignFeature] = []
        for body in session.workspace.visible.bodies where moving.contains(body.id) == from {
            guard let render = solidRender(body), let solid = try? SolidKernel.solid(for: body) else { continue }
            if alignCornerCache[body.id]?.body != body {
                alignCornerCache[body.id] = (body, AlignFeature.corners(of: solid, edges: render.borderEdges))
            }
            result += (alignCornerCache[body.id]?.corners ?? []).map { AlignFeature.point($0, source: .vertex(body.id, $0)) }
        }
        if !from {
            for shape in session.workspace.visible.shapes {
                result += AlignFeature.points(of: shape).map { AlignFeature.point($0, source: .sketchPoint(shape.id, $0)) }
            }
            result.append(.point(.zero, source: .origin))
        }
        return result.filter { isUnobstructed($0.point) }
    }

    /// The nearest pickable point within 12 pt of the Pencil.
    private func alignPoint(at point: CGPoint, moving: Set<UUID>, from: Bool) -> AlignFeature? {
        alignPoints(moving: moving, from: from)
            .map { ($0, distance(project(SIMD3<Float>($0.point)), point)) }
            .filter { $0.1 < 12 }
            .min { $0.1 < $1.1 }?.0
    }

    /// The moving solids in blue, the feature being aligned in blue, and the target in purple.
    private func rebuildAlignPreview(_ draft: AlignDraft) {
        let purple = UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1)
        if draft.step == .to {
            let half = PlaneReference.worldHalfSize
            let square = [Point2(x: -half, y: -half), Point2(x: half, y: -half), Point2(x: half, y: half), Point2(x: -half, y: half)]
            for plane in SketchPlane.allCases {
                let fill = planarNode(path: path(for: square, circle: nil), plane: plane, height: 0,
                                      color: blue.withAlphaComponent(0.06), name: "align.world.\(plane.worldName ?? "")")
                fill.renderingOrder = 7
                previewNode.addChildNode(fill)
                previewNode.addChildNode(drawOnTop(outlineNode(square, plane: plane, color: blue.withAlphaComponent(0.35), closed: true), order: 8))
            }
        }
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for id in draft.bodies {
            guard let body = session.visibleWorkspace.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
            for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
        }
        if !segments.isEmpty {
            let node = strokeNode(segments, color: blue, weight: 1.6)
            node.name = "align.bodies"
            previewNode.addChildNode(node)
        }
        func outline(_ feature: AlignFeature, _ color: UIColor, _ name: String, moved: RigidTransform?) {
            if feature.kind == .point {
                let dot = SCNNode(geometry: SCNSphere(radius: CGFloat(unitsPerPoint * 5)))
                dot.geometry?.materials = [material(color, constant: true)]
                dot.simdPosition = SIMD3<Float>(moved?.apply(point: feature.point) ?? feature.point)
                dot.name = name
                previewNode.addChildNode(drawOnTop(dot, order: 10))
                return
            }
            var points = feature.outline.map { moved?.apply(point: $0) ?? $0 }
            if feature.kind != .line, let first = points.first { points.append(first) }
            let world = points.map { SIMD3<Float>($0) }
            let node = drawOnTop(strokeNode(zip(world, world.dropFirst()).map { ($0, $1) }, color: color, weight: 2.2), order: 10)
            node.name = name
            previewNode.addChildNode(node)
        }
        if let from = draft.from { outline(from, blue, "align.from", moved: session.alignPreview != nil ? session.alignTransform : nil) }
        if let to = draft.to { outline(to, purple, "align.to", moved: nil) }
    }

    /// The double-arrow on an Align target, along its normal or axis: drag it to offset.
    func alignHandle() -> ExtrusionHandle? {
        // Points only move onto each other: no offset or turn.
        guard session.tool == .align, session.alignPreview != nil, let draft = session.alignDraft, let to = draft.to, to.kind != .point else { return nil }
        let goal = to.point + to.direction * draft.offset
        let origin = project(SIMD3<Float>(goal)), ahead = project(SIMD3<Float>(goal + to.direction * 10))
        let dx = ahead.x - origin.x, dy = ahead.y - origin.y, length = hypot(dx, dy)
        let axis = length > 4 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: -1)
        return ExtrusionHandle(origin: origin, face: origin, center: CGPoint(x: origin.x + axis.dx * 40, y: origin.y + axis.dy * 40), axis: axis)
    }

    // MARK: Split Body

    /// Split Body: a tap picks (or unpicks) a solid to split, or a tool to split with. Solids are
    /// picked as committed, not as the previewed pieces.
    private func splitTap(at point: CGPoint) {
        guard let draft = session.splitDraft else { return }
        if draft.step == .bodies {
            if let hit = frontSurface(at: point, committed: true) { session.toggleSplitBody(hit.bodyID) }
            return
        }
        if let line = nearestSketch(at: point, over: frontSurface(at: point, committed: true)), line.kind == .line,
           let tool = SplitTool.line(line) {
            session.toggleSplitTool(tool)
        } else if let reference = planeReference(at: point, committed: true), let tool = SplitTool.reference(reference, in: session.workspace) {
            session.toggleSplitTool(tool)
        }
    }

    /// The picked solids in blue, and each tool in purple: a plane as a sheet across the solids,
    /// a region as its outline.
    private func rebuildSplitPreview(_ draft: SplitDraft) {
        let purple = UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1)
        if draft.step == .tools {
            let half = PlaneReference.worldHalfSize
            let square = [Point2(x: -half, y: -half), Point2(x: half, y: -half), Point2(x: half, y: half), Point2(x: -half, y: half)]
            for plane in SketchPlane.allCases where !draft.tools.contains(where: { $0.source == .world(plane) }) {
                let fill = planarNode(path: path(for: square, circle: nil), plane: plane, height: 0,
                                      color: blue.withAlphaComponent(0.06), name: "split.world.\(plane.worldName ?? "")")
                fill.renderingOrder = 7
                previewNode.addChildNode(fill)
                previewNode.addChildNode(drawOnTop(outlineNode(square, plane: plane, color: blue.withAlphaComponent(0.35), closed: true), order: 8))
            }
        }
        var corners: [SIMD3<Double>] = []
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for id in draft.bodies {
            guard let body = session.workspace.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
            for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
            if let bounds = try? SolidKernel.solid(for: body).bounds {
                for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                    corners.append(SIMD3(x, y, z))
                } } }
            }
        }
        if !segments.isEmpty {
            let highlight = strokeNode(segments, color: blue, weight: 1.6)
            highlight.name = "split.bodies"
            previewNode.addChildNode(highlight)
        }
        for tool in draft.tools {
            if let profile = tool.profile {
                let node = drawOnTop(outlineNode(profile.outline, plane: profile.plane, color: purple, closed: true), order: 10)
                node.name = "split.tool"
                previewNode.addChildNode(node)
                continue
            }
            // A sheet on the plane, a little larger than the solids it cuts.
            let local = corners.map(tool.plane.coordinates(of:))
            var low = Point2(x: -PlaneReference.worldHalfSize, y: -PlaneReference.worldHalfSize), high = low * -1
            if let first = local.first {
                low = local.reduce(first) { Point2(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
                high = local.reduce(first) { Point2(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
                let margin = max(4, 0.15 * max(high.x - low.x, high.y - low.y))
                low = low - Point2(x: margin, y: margin); high = high + Point2(x: margin, y: margin)
            }
            let sheet = [low, Point2(x: high.x, y: low.y), high, Point2(x: low.x, y: high.y)]
            let fill = planarNode(path: path(for: sheet, circle: nil), plane: tool.plane, height: 0, color: purple.withAlphaComponent(0.16), name: "split.tool")
            fill.renderingOrder = 7
            previewNode.addChildNode(fill)
            previewNode.addChildNode(drawOnTop(outlineNode(sheet, plane: tool.plane, color: purple, closed: true), order: 9))
        }
    }

    // MARK: Mirror

    /// Mirror: a tap picks (or unpicks) a solid, or a sketch by one of its lines, to mirror; or the
    /// mirror plane. Solids and sketches are picked as committed, not as their previewed images.
    private func mirrorTap(at point: CGPoint) {
        guard let draft = session.mirrorDraft else { return }
        let surface = frontSurface(at: point, committed: true)
        let line = nearestSketch(at: point, over: surface)
        if draft.step == .items {
            if let sketch = line?.sketch, session.workspace.sketches.contains(where: { $0.id == sketch }) {
                session.toggleMirrorSketch(sketch)
            } else if let surface {
                session.toggleMirrorBody(surface.bodyID)
            }
            return
        }
        if let line, line.kind == .line, let plane = MirrorPlane.line(line) {
            session.pickMirrorPlane(plane)
        } else if let reference = planeReference(at: point, committed: true), let plane = MirrorPlane.reference(reference, in: session.workspace) {
            session.pickMirrorPlane(plane)
        }
    }

    /// The picked solids and sketches in blue, and the mirror plane in purple: a sheet across the
    /// items and their mirror images.
    private func rebuildMirrorPreview(_ draft: MirrorDraft) {
        let purple = UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1)
        if draft.step == .plane {
            let half = PlaneReference.worldHalfSize
            let square = [Point2(x: -half, y: -half), Point2(x: half, y: -half), Point2(x: half, y: half), Point2(x: -half, y: half)]
            for plane in SketchPlane.allCases where draft.plane?.source != .world(plane) {
                let fill = planarNode(path: path(for: square, circle: nil), plane: plane, height: 0,
                                      color: blue.withAlphaComponent(0.06), name: "mirror.world.\(plane.worldName ?? "")")
                fill.renderingOrder = 7
                previewNode.addChildNode(fill)
                previewNode.addChildNode(drawOnTop(outlineNode(square, plane: plane, color: blue.withAlphaComponent(0.35), closed: true), order: 8))
            }
        }
        var points: [SIMD3<Double>] = []
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for id in draft.bodies {
            guard let body = session.workspace.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
            for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
            if let bounds = try? SolidKernel.solid(for: body).bounds {
                for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                    points.append(SIMD3(x, y, z))
                } } }
            }
        }
        for shape in session.workspace.shapes where shape.sketch.map(draft.sketches.contains) ?? false {
            let outline = shape.outline.map { shape.plane.point($0) }
            points += outline
            let path = shape.isClosed ? outline + outline.prefix(1) : outline
            segments += zip(path, path.dropFirst()).map { (SIMD3<Float>($0), SIMD3<Float>($1)) }
        }
        if !segments.isEmpty {
            let highlight = drawOnTop(strokeNode(segments, color: blue, weight: 1.6), order: 9)
            highlight.name = "mirror.items"
            previewNode.addChildNode(highlight)
        }
        guard let mirror = draft.plane, let reflection = Reflection(across: mirror.plane) else { return }
        // A sheet on the plane covering the items and their images, a little larger.
        let local = (points + points.map(reflection.point)).map(mirror.plane.coordinates(of:))
        var low = Point2(x: -PlaneReference.worldHalfSize, y: -PlaneReference.worldHalfSize), high = low * -1
        if let first = local.first {
            low = local.reduce(first) { Point2(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
            high = local.reduce(first) { Point2(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
            let margin = max(4, 0.15 * max(high.x - low.x, high.y - low.y))
            low = low - Point2(x: margin, y: margin); high = high + Point2(x: margin, y: margin)
        }
        let sheet = [low, Point2(x: high.x, y: low.y), high, Point2(x: low.x, y: high.y)]
        let fill = planarNode(path: path(for: sheet, circle: nil), plane: mirror.plane, height: 0, color: purple.withAlphaComponent(0.16), name: "mirror.plane")
        fill.renderingOrder = 7
        previewNode.addChildNode(fill)
        previewNode.addChildNode(drawOnTop(outlineNode(sheet, plane: mirror.plane, color: purple, closed: true), order: 9))
    }

    // MARK: Pattern

    /// Pattern: Pencil down on the gizmo drags its center (circular) or an arrow or ring; anywhere
    /// else picks (or unpicks) a solid, or a sketch by one of its lines, as committed.
    private func patternDown(at point: CGPoint) {
        guard let draft = session.patternDraft else { return }
        if let widget = patternWidget() {
            if widget.canPivot, distance(point, widget.center) < 16, session.beginPatternCenterDrag() {
                draggingPatternCenter = true
                return
            }
            switch widget.handle(at: point) {
            case .move(let axis):
                if let arrow = widget.arrows.first(where: { $0.axis == axis }) {
                    patternGesture = (.move(axis), arrow.direction, arrow.pointsPerMillimeter, widget.center, 0, 0, widget.toward[axis],
                                      draft.spec.directions[axis].distance)
                    return
                }
            case .rotate(let axis):
                let angle = atan2(point.y - widget.center.y, point.x - widget.center.x)
                // Turning another ring starts that axis afresh.
                patternGesture = (.rotate(axis), .zero, 1, widget.center, angle, 0, widget.toward[axis], axis == draft.circularAxis ? draft.spec.angle : 0)
                return
            case nil: break
            }
        }
        let surface = frontSurface(at: point, committed: true)
        if let sketch = nearestSketch(at: point, over: surface)?.sketch, session.workspace.sketches.contains(where: { $0.id == sketch }) {
            session.togglePatternSketch(sketch)
        } else if let surface {
            session.togglePatternBody(surface.bodyID)
        }
    }

    // MARK: Scale

    /// Scale: Pencil down on an arrow of the gizmo drags it; anywhere else picks (or unpicks) a
    /// solid, or a sketch by one of its lines, as committed.
    private func scaleDown(at point: CGPoint) {
        guard let draft = session.scaleDraft else { return }
        if let widget = scaleWidget(), case .move(let axis) = widget.handle(at: point),
           let arrow = widget.arrows.first(where: { $0.axis == axis }) {
            // How far the items reach from the center along the arrow.
            var reach = 10.0
            if let bounds = Scaling.bounds(of: session.workspace, bodies: draft.bodies, sketches: draft.sketches) {
                let direction = draft.axes[axis]
                var far = 0.0
                for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                    far = max(far, simd_dot(SIMD3(x, y, z) - draft.center, direction))
                } } }
                if far > 0.5 { reach = far }
            }
            let percent = draft.uniform ? draft.percents.x : draft.percents[axis]
            scaleGesture = (axis, arrow.direction, arrow.pointsPerMillimeter, percent, reach)
            return
        }
        let surface = frontSurface(at: point, committed: true)
        if let sketch = nearestSketch(at: point, over: surface)?.sketch, session.workspace.sketches.contains(where: { $0.id == sketch }) {
            session.toggleScaleSketch(sketch)
        } else if let surface {
            session.toggleScaleBody(surface.bodyID)
        }
    }

    /// Scale's gizmo: an arrow along each of the first item's axes, at the point that stays put.
    func scaleWidget() -> TransformWidget? {
        guard let draft = session.scaleDraft, !draft.isEmpty else { return nil }
        return gizmo(center: draft.center, axes: draft.axes, canPivot: false, moves: true, turns: false)
    }

    /// The picked solids' borders and sketches' shapes in blue, drawn over everything.
    private func highlightItems(bodies: [UUID], sketches: [UUID], name: String) {
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for id in bodies {
            guard let body = session.workspace.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
            for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
        }
        for shape in session.workspace.shapes where shape.sketch.map(sketches.contains) ?? false {
            let outline = shape.outline.map { shape.plane.point($0) }
            let path = shape.isClosed ? outline + outline.prefix(1) : outline
            segments += zip(path, path.dropFirst()).map { (SIMD3<Float>($0), SIMD3<Float>($1)) }
        }
        guard !segments.isEmpty else { return }
        let highlight = drawOnTop(strokeNode(segments, color: blue, weight: 1.6), order: 9)
        highlight.name = name
        previewNode.addChildNode(highlight)
    }

    // MARK: Project

    /// Project: a tap picks (or unpicks) an item, or the surface, depending on the step. A quick
    /// second tap on the same sketch or solid picks all of it.
    private func projectionTap(at point: CGPoint) {
        guard let draft = session.projectionDraft else { return }
        if draft.step == .surface && !draft.fixedTarget {
            if let target = projectionTarget(at: point) { session.setProjectionTarget(target) }
            return
        }
        let now = CACurrentMediaTime()
        let last = lastProjectionTap.flatMap { now - $0.time < Self.doubleTapInterval && distance(point, $0.point) < Self.doubleTapDistance ? $0 : nil }
        lastProjectionTap = nil
        let surface = solidFace(at: point)
        if let line = nearestSketch(at: point, over: surface) {
            if let id = line.sketch, last?.sketchID == id {
                session.pickWholeForProjection(.shapes(session.workspace.shapes(in: id), source: .sketch(id)))
            } else {
                lastProjectionTap = (line.sketch, nil, now, point)
                session.toggleProjectionItem(.shapes([line], source: .shape(line.id)))
            }
            return
        }
        let wholeBody: (UUID) -> Bool = { id in
            guard last?.bodyID == id else { return false }
            if let body = self.session.workspace.bodies.first(where: { $0.id == id }), let item = ProjectionItem.body(body) {
                self.session.pickWholeForProjection(item)
            }
            return true
        }
        if let (bodyID, edge) = solidEdge(at: point, tolerance: 8) {
            if wholeBody(bodyID) { return }
            lastProjectionTap = (nil, bodyID, now, point)
            if let body = session.workspace.bodies.first(where: { $0.id == bodyID }), let item = ProjectionItem.edge(edge, of: body) {
                session.toggleProjectionItem(item)
            }
            return
        }
        // A sketch region in front of (or on) the face under the Pencil wins over the face.
        var region: (profile: SketchProfile, depth: Double)?
        for profile in session.visibleWorkspace.profiles where abs(simd_dot(viewDirection, profile.plane.normalAxis)) > 0.05 && !isCovered(profile) {
            guard let local = pointOnPlane(point, plane: profile.plane), Geometry.contains(local, in: profile.outline) else { continue }
            let depth = simd_dot(profile.plane.point(local), viewDirection)
            if depth > region?.depth ?? -.infinity { region = (profile, depth) }
        }
        if let region, region.depth >= (surface?.depth ?? -.infinity) - max(0.05, unitsPerPoint * 2) {
            let shapes = session.workspace.shapes.filter { region.profile.sourceIDs.contains($0.id) }
            session.toggleProjectionItem(.shapes(shapes, source: .profile(region.profile.id)))
            return
        }
        if let surface {
            if wholeBody(surface.bodyID) { return }
            lastProjectionTap = (nil, surface.bodyID, now, point)
            if let body = session.workspace.bodies.first(where: { $0.id == surface.bodyID }), let item = ProjectionItem.face(surface.face, of: body) {
                session.toggleProjectionItem(item)
            }
        }
    }

    /// The surface under the Pencil: a sketch line (its sketch), else the nearest flat face, sketch
    /// region, or construction plane, else a world plane at the origin.
    private func projectionTarget(at point: CGPoint) -> ProjectionTarget? {
        if let line = nearestSketch(at: point, over: solidFace(at: point)), let id = line.sketch,
           let target = ProjectionTarget.sketch(id, in: session.workspace) { return target }
        return planeReference(at: point).flatMap { ProjectionTarget.reference($0, in: session.workspace) }
    }

    /// The nearest solid edge of any kind under the Pencil that is not hidden behind a face, as its
    /// kernel edge index.
    func solidEdge(at point: CGPoint, tolerance: Double = 14) -> (UUID, Int)? {
        let pencil = Point2(x: point.x, y: point.y)
        let view = SIMD3(Float(viewDirection.x), Float(viewDirection.y), Float(viewDirection.z))
        let frontDepth = frontSurface(at: point).map { Float($0.depth) }
        var best: (UUID, Int, Double)?
        for body in session.workspace.visible.bodies {
            guard let render = solidRender(body) else { continue }
            for (border, edge) in zip(render.borders, render.borderEdges) {
                for (a, b) in zip(border, border.dropFirst()) {
                    let pa = project(a), pb = project(b)
                    let d = Geometry.distance(pencil, toSegment: Point2(x: pa.x, y: pa.y), Point2(x: pb.x, y: pb.y))
                    guard d < tolerance, d < (best?.2 ?? .infinity) else { continue }
                    let length = max(1e-6, hypot(pb.x - pa.x, pb.y - pa.y))
                    let t = Float(max(0, min(1, ((point.x - pa.x) * (pb.x - pa.x) + (point.y - pa.y) * (pb.y - pa.y)) / (length * length))))
                    let depth = simd_dot(a + (b - a) * t, view)
                    if let frontDepth, depth < frontDepth - Float(unitsPerPoint * 4) - 0.05 { continue }
                    best = (body.id, edge, d)
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Picked items in blue, the surface in purple, and the projection itself on the surface.
    private func rebuildProjectionPreview(_ draft: ProjectionDraft) {
        let purple = UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1)
        if draft.step == .surface && !draft.fixedTarget {
            // The world planes are surfaces too, drawn at the origin like Offset Plane's.
            let half = PlaneReference.worldHalfSize
            let square = [Point2(x: -half, y: -half), Point2(x: half, y: -half), Point2(x: half, y: half), Point2(x: -half, y: half)]
            for plane in SketchPlane.allCases {
                let fill = planarNode(path: path(for: square, circle: nil), plane: plane, height: 0,
                                      color: blue.withAlphaComponent(0.06), name: "projection.world.\(plane.worldName ?? "")")
                fill.renderingOrder = 7
                previewNode.addChildNode(fill)
                previewNode.addChildNode(drawOnTop(outlineNode(square, plane: plane, color: blue.withAlphaComponent(0.35), closed: true), order: 8))
            }
        }
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for item in draft.items {
            for curve in item.curves {
                let points: [SIMD3<Double>], closed: Bool
                switch curve {
                case .segment(let a, let b): points = [a, b]; closed = false
                case .circle(let center, let axis, let radius):
                    let u = simd_normalize(simd_cross(axis, abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0))), v = simd_cross(axis, u)
                    points = (0..<96).map { center + (u * cos(Double($0) * .pi / 48) + v * sin(Double($0) * .pi / 48)) * radius }
                    closed = true
                case .arc(let center, let axis, let start, let mid, let end):
                    points = Projection.arcPoints(center: center, axis: axis, start: start, end: end, through: mid); closed = false
                case .rectangle(let corners): points = corners; closed = true
                case .polyline(let line, let isClosed): points = line; closed = isClosed
                }
                let world = points.map { SIMD3<Float>($0) }
                segments += zip(world, world.dropFirst()).map { ($0, $1) }
                if closed, let first = world.first, let last = world.last { segments.append((last, first)) }
            }
        }
        if !segments.isEmpty {
            let items = drawOnTop(strokeNode(segments, color: blue, weight: 1.6), order: 9)
            items.name = "projection.items"
            previewNode.addChildNode(items)
        }
        if let target = draft.target {
            if case .face(let bodyID, let face) = target.source, let body = session.workspace.bodies.first(where: { $0.id == bodyID }),
               let render = solidRender(body) {
                previewNode.addChildNode(faceTint(render, face: face, color: purple.withAlphaComponent(0.25), name: "projection.target"))
            } else if !target.outline.isEmpty {
                let outline = target.outline.map { target.plane.coordinates(of: $0) }
                let fill = planarNode(path: path(for: outline, circle: nil), plane: target.plane, height: 0,
                                      color: purple.withAlphaComponent(0.12), name: "projection.target")
                fill.renderingOrder = 7
                previewNode.addChildNode(fill)
                previewNode.addChildNode(drawOnTop(outlineNode(outline, plane: target.plane, color: purple, closed: true), order: 8))
            }
        }
        for shape in session.projectionPreview {
            let node = drawOnTop(outlineNode(shape.outline, plane: shape.plane, color: purple, closed: shape.isClosed), order: 10)
            node.name = "projection.preview"
            previewNode.addChildNode(node)
        }
    }

    /// Half the side of each translucent plane shown by the Sketch tile, about a fifth of the view.
    var planePickerHalfSize: Double { orthographicHeight * 0.2 }

    private func selectFace(_ hit: SurfaceHit) {
        let body = session.workspace.bodies.first { $0.id == hit.bodyID }
        let center = body.flatMap { try? SolidKernel.solid(for: $0).faceCenter(hit.face) } ?? hit.point
        session.select(.face(FaceSelection(bodyID: hit.bodyID, face: hit.face, plane: hit.plane, center: center, point: hit.point)))
    }

    /// The sketch whose edge is under the Pencil, on any plane. Edges get a forgiving screen-space
    /// target, independent of camera orientation. Sketches on the active plane win over others;
    /// sketches hidden from view (under a solid's base, or behind `surface`) cannot be picked.
    private func nearestSketch(at point: CGPoint, over surface: SurfaceHit?) -> SketchShape? {
        let covered = coveredSourceIDs()
        let pencil = Point2(x: point.x, y: point.y)
        var best: (shape: SketchShape, distance: Double, active: Bool)?
        for shape in session.workspace.visible.shapes where !covered.contains(shape.id) {
            let active = shape.plane == session.plane
            let world = shape.outline.map { shape.plane.world($0) }
            let points = world.map(project)
            // A sketch point is one "segment" from itself to itself.
            let count = max(1, shape.isClosed ? points.count : points.count - 1)
            for i in 0..<count {
                let j = (i + 1) % points.count
                let a = Point2(x: points[i].x, y: points[i].y), b = Point2(x: points[j].x, y: points[j].y)
                let d = Geometry.distance(pencil, toSegment: a, b)
                guard d < 12, best.map({ active && !$0.active || active == $0.active && d < $0.distance }) ?? true else { continue }
                // Drawn over solids, or in front of (or on) the solid face under the Pencil.
                if let surface, !(active && activeSketchesOnTop) {
                    let ab = b - a, length = ab.x * ab.x + ab.y * ab.y
                    let t = length > 0 ? max(0, min(1, ((pencil.x - a.x) * ab.x + (pencil.y - a.y) * ab.y) / length)) : 0
                    let onEdge = SIMD3<Double>(world[i] + (world[j] - world[i]) * Float(t))
                    guard simd_dot(onEdge, viewDirection) >= surface.depth - max(0.05, unitsPerPoint * 2) else { continue }
                }
                best = (shape, d, active)
            }
        }
        return best?.shape
    }

    /// The nearest solid edge under the Pencil that is not hidden behind a face: any edge, including
    /// ones made by cuts, joins, holes, and fillets.
    func finishEdge(at point: CGPoint, tolerance: Double = 14) -> (UUID, PickedEdge)? {
        let pencil = Point2(x: point.x, y: point.y)
        let view = SIMD3(Float(viewDirection.x), Float(viewDirection.y), Float(viewDirection.z))
        // Depth toward the camera of the first solid surface under the Pencil; nearer edges are visible.
        let frontDepth = frontSurface(at: point).map { Float($0.depth) }
        var best: (UUID, PickedEdge, Double)?
        for body in session.workspace.visible.bodies {
            guard let render = solidRender(body) else { continue }
            for (offset, border) in render.borders.enumerated() {
                let name = PickedEdge(index: render.borderEdges[offset], name: render.borderNames[offset],
                                      point: SIMD3<Double>(border.isEmpty ? .zero : border[border.count / 2]))
                for (a, b) in zip(border, border.dropFirst()) {
                    let pa = project(a), pb = project(b)
                    let d = Geometry.distance(pencil, toSegment: Point2(x: pa.x, y: pa.y), Point2(x: pb.x, y: pb.y))
                    guard d < tolerance, d < (best?.2 ?? .infinity) else { continue }
                    let length = max(1e-6, hypot(pb.x - pa.x, pb.y - pa.y))
                    let t = Float(max(0, min(1, ((point.x - pa.x) * (pb.x - pa.x) + (point.y - pa.y) * (pb.y - pa.y)) / (length * length))))
                    let depth = simd_dot(a + (b - a) * t, view)
                    if let frontDepth, depth < frontDepth - Float(unitsPerPoint * 4) - 0.05 { continue }
                    best = (body.id, name, d)
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Orthographic ray cast against the kernel triangles of every displayed solid. Uses the
    /// canvas camera math rather than SCNView hit tests, which miss nodes not yet rendered.
    private func frontSurface(at screen: CGPoint, committed: Bool = false) -> SurfaceHit? {
        let origin = viewPlanePoint(screen), direction = screenCamera.direction
        // A tap goes through X-rayed solids to a solid inside them, when there is one.
        var nearest: SurfaceHit?, nearestXrayed: SurfaceHit?
        for body in committed ? session.workspace.visible.bodies : session.visibleWorkspace.bodies {
            guard let render = solidRender(body) else { continue }
            let xrayed = session.isXrayed(body.id) && !session.xrayAll
            let triangles = render.triangles
            for span in render.faceSpans where Self.line(through: origin, along: direction, meets: span.low, span.high) {
            for t in stride(from: span.range.lowerBound, to: span.range.upperBound - 2, by: 3) {
                let a = SIMD3<Double>(triangles[t]), b = SIMD3<Double>(triangles[t + 1]), c = SIMD3<Double>(triangles[t + 2])
                // Möller–Trumbore on the full line through the screen point (both directions).
                let e1 = b - a, e2 = c - a, p = simd_cross(direction, e2), det = simd_dot(e1, p)
                guard abs(det) > 1e-12 else { continue }
                let s = origin - a, u = simd_dot(s, p) / det
                guard u >= 0, u <= 1 else { continue }
                let q = simd_cross(s, e1), v = simd_dot(direction, q) / det
                guard v >= 0, u + v <= 1 else { continue }
                let point = origin + direction * (simd_dot(e2, q) / det)
                let depth = simd_dot(point, viewDirection)
                if depth > (xrayed ? nearestXrayed : nearest)?.depth ?? -.infinity {
                    let hit = SurfaceHit(point: point, depth: depth, plane: render.trianglePlanes[t / 3], bodyID: body.id, face: render.triangleFaces[t / 3])
                    if xrayed { nearestXrayed = hit } else { nearest = hit }
                }
            }
            }
        }
        return nearest ?? nearestXrayed
    }

    /// Whether the infinite line through `origin` along `direction` passes through a box (slightly
    /// enlarged, so faces lying in a box side still count).
    private static func line(through origin: SIMD3<Double>, along direction: SIMD3<Double>, meets low: SIMD3<Double>, _ high: SIMD3<Double>) -> Bool {
        let pad = 1e-6 + 1e-9 * simd_reduce_max(simd_abs(high - low))
        var enter = -Double.infinity, exit = Double.infinity
        for axis in 0..<3 {
            let lo = low[axis] - pad, hi = high[axis] + pad, o = origin[axis], d = direction[axis]
            if abs(d) < 1e-12 {
                guard o >= lo && o <= hi else { return false }
                continue
            }
            let a = (lo - o) / d, b = (hi - o) / d
            enter = max(enter, min(a, b)); exit = min(exit, max(a, b))
            guard enter <= exit else { return false }
        }
        return true
    }

    struct SurfaceHit {
        var point: SIMD3<Double>
        var depth: Double
        /// The face's sketch plane; nil on curved faces.
        var plane: SketchPlane?
        var bodyID: UUID
        var face: Int
    }

    /// The solid face nearest the viewer under a screen point.
    func solidFace(at screen: CGPoint) -> SurfaceHit? { frontSurface(at: screen) }

    /// The face (any face, flat or curved) of a solid under the Pencil, picked on the solid as it
    /// was before the pending shell so opened faces can be tapped again to close them.
    func shellFace(at screen: CGPoint) -> SurfaceHit? { frontSurface(at: screen, committed: true) }

    /// Thickness double-arrow at the first open face (where it was tapped).
    func shellHandle() -> ExtrusionHandle? {
        guard let draft = session.shellDraft, let open = draft.openings.first else { return nil }
        let anchor = project(SIMD3<Float>(open.point))
        return ExtrusionHandle(origin: anchor, face: anchor, center: CGPoint(x: anchor.x + 36, y: anchor.y - 30))
    }

    /// The Move/Rotate widget on screen for the selected sketch or solid: an arrow along each of its
    /// axes and a quarter arc about each, sized in screen points so it reads at any zoom. During
    /// a drag it follows the sketch's preview.
    struct TransformWidget {
        struct Arrow { var axis: Int; var base: CGPoint; var tip: CGPoint; var direction: CGVector; var pointsPerMillimeter: Double }
        var center: CGPoint
        var arrows: [Arrow]
        var arcs: [(axis: Int, points: [CGPoint])]
        /// How much each axis points toward the viewer (−1…1).
        var toward: [Double]
        /// A solid's widget center can be dragged onto its corners and edges; a sketch's cannot.
        var canPivot = false

        func handle(at point: CGPoint) -> TransformHandle? {
            func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
                Geometry.distance(Point2(x: p.x, y: p.y), toSegment: Point2(x: a.x, y: a.y), Point2(x: b.x, y: b.y))
            }
            let arrow = arrows.map { ($0.axis, distance(point, $0.base, $0.tip)) }.min { $0.1 < $1.1 }
            if let arrow, arrow.1 < 14 { return .move(arrow.0) }
            let arc = arcs.map { arc in (arc.axis, zip(arc.points, arc.points.dropFirst()).map { distance(point, $0, $1) }.min() ?? .infinity) }
                .min { $0.1 < $1.1 }
            if let arc, arc.1 < 12 { return .rotate(arc.0) }
            return nil
        }
    }

    func transformWidget() -> TransformWidget? {
        guard let target = session.transformWidgetTarget else { return nil }
        var center: SIMD3<Double>, axes: [SIMD3<Double>]
        if let drag = session.transformDrag {
            let transform = drag.transform
            center = transform.apply(point: drag.center)
            axes = drag.axes.map { transform.apply(vector: $0) }
        } else if let frame = session.transformFrame(of: target) {
            (center, axes) = frame
        } else { return nil }
        var canPivot = false
        if case .body = target { canPivot = true }
        // A shape moves along its sketch and turns about the sketch's normal only.
        if case .shape = target { return gizmo(center: center, axes: axes, canPivot: false, arrowAxes: [0, 1], arcAxes: [2]) }
        return gizmo(center: center, axes: axes, canPivot: canPivot)
    }

    /// A widget at `center` with an arrow along each of `axes` and a quarter arc about each (only
    /// the arrows, or only the arcs, when `moves` or `turns` is false).
    private func gizmo(center: SIMD3<Double>, axes: [SIMD3<Double>], canPivot: Bool, moves: Bool = true, turns: Bool = true,
                       arrowAxes: Set<Int> = [0, 1, 2], arcAxes: Set<Int> = [0, 1, 2]) -> TransformWidget {
        // Arcs on an inner ring, arrows outside it, so each handle has its own place to grab.
        let length = 100 * unitsPerPoint, origin = project(SIMD3<Float>(center))
        var arrows: [TransformWidget.Arrow] = []
        for (index, axis) in axes.enumerated() where moves && arrowAxes.contains(index) {
            let tip = project(SIMD3<Float>(center + axis * length)), base = project(SIMD3<Float>(center + axis * length * 0.5))
            let dx = tip.x - origin.x, dy = tip.y - origin.y, screen = hypot(dx, dy)
            // An axis pointing at the viewer cannot be dragged along.
            guard screen > 20 else { continue }
            arrows.append(.init(axis: index, base: base, tip: tip, direction: CGVector(dx: dx / screen, dy: dy / screen),
                                pointsPerMillimeter: Double(screen) / length))
        }
        var arcs: [(axis: Int, points: [CGPoint])] = []
        for index in axes.indices where turns && arcAxes.contains(index) && abs(simd_dot(axes[index], viewDirection)) > 0.15 {
            let u = axes[(index + 1) % 3], v = axes[(index + 2) % 3]
            arcs.append((index, (0...12).map { step in
                let t = Double(step) / 12 * .pi / 2
                // Without arrows (a circular pattern) the rings have the room to be larger and easier to grab.
                return project(SIMD3<Float>(center + (u * cos(t) + v * sin(t)) * length * (moves ? 0.38 : 0.7)))
            }))
        }
        return TransformWidget(center: origin, arrows: arrows, arcs: arcs, toward: axes.map { simd_dot($0, viewDirection) }, canPivot: canPivot)
    }

    /// Pattern's gizmo: arrows to lay copies out along (linear), or rings to turn them about and a
    /// center to drag (circular).
    func patternWidget() -> TransformWidget? {
        guard let draft = session.patternDraft, !draft.isEmpty else { return nil }
        let circular = draft.spec.kind == .circular
        return gizmo(center: draft.center, axes: draft.axes, canPivot: circular, moves: !circular, turns: circular)
    }

    /// Where a selected solid's widget center can snap to: its
    /// middle, corners, edge midpoints, and circle and face centers, and any point on an edge. Only
    /// places not hidden behind a face are offered.
    func pivotSnaps() -> (points: [TransformPivot], edges: [[SIMD3<Double>]]) {
        guard case .body(let id) = session.transformWidgetTarget,
              let body = session.workspace.bodies.first(where: { $0.id == id }) else { return ([], []) }
        return pivotSnaps(of: body)
    }

    private func pivotSnaps(of body: SolidBody) -> (points: [TransformPivot], edges: [[SIMD3<Double>]]) {
        let id = body.id
        if pivotSnapCache[id]?.body != body {
            guard let render = solidRender(body), let solid = try? SolidKernel.solid(for: body) else { return ([], []) }
            let snaps = TransformPivot.snaps(of: solid, edges: render.borderEdges)
            pivotSnapCache[id] = (body, snaps.points, snaps.edges)
        }
        guard let cached = pivotSnapCache[id] else { return ([], []) }
        // The middle is inside the solid, so it is always offered.
        return (cached.points.filter { $0.kind == .center || isUnobstructed($0.point) }, cached.edges)
    }

    /// Whether a point on a solid is in front of (or on) the nearest face under it on screen.
    /// Overlays ask on every draw, so answers are kept until the view or the solids change.
    private func isUnobstructed(_ point: SIMD3<Double>) -> Bool {
        let camera = screenCamera
        if visibility?.camera != camera || visibility?.content != contentVersion { visibility = (camera, contentVersion, [:]) }
        if let known = visibility?.answers[point] { return known }
        let screen = project(SIMD3<Float>(point))
        let answer: Bool
        if !view.bounds.contains(screen) { answer = false }
        else if let front = frontSurface(at: screen, committed: true) { answer = simd_dot(point, viewDirection) >= front.depth - max(0.05, unitsPerPoint * 3) }
        else { answer = true }
        visibility?.answers[point] = answer
        return answer
    }

    /// The snap under the Pencil: the nearest snap point within 14 pt, else the nearest visible
    /// point on an edge within 10 pt (whole millimeters along a straight edge with snapping on).
    func pivotSnap(at point: CGPoint) -> TransformPivot? { pivotSnap(at: point, in: pivotSnaps()) }

    /// Where Pattern's gizmo center can go: the snaps of every visible solid, sketch line ends and
    /// circle and arc centers (a circle's axis is its plane's normal), and the origin.
    func patternCenterSnaps() -> (points: [TransformPivot], edges: [[SIMD3<Double>]]) {
        var points = [TransformPivot(kind: .origin, point: .zero)], edges: [[SIMD3<Double>]] = []
        for body in session.workspace.visible.bodies {
            let snaps = pivotSnaps(of: body)
            points += snaps.points
            edges += snaps.edges
        }
        for shape in session.workspace.visible.shapes {
            let normal = shape.plane.normalAxis
            switch shape.kind {
            case .line: points += [shape.start, shape.end].map { TransformPivot(kind: .point, point: shape.plane.point($0)) }
            case .circle: points.append(TransformPivot(kind: .circleCenter, point: shape.plane.point(shape.start), direction: normal))
            case .arc:
                if let center = shape.arcCenter { points.append(TransformPivot(kind: .circleCenter, point: shape.plane.point(center), direction: normal)) }
                points += [shape.start, shape.end].map { TransformPivot(kind: .point, point: shape.plane.point($0)) }
            case .rectangle: points += shape.outline.map { TransformPivot(kind: .point, point: shape.plane.point($0)) }
            case .slot: points += [shape.start, shape.end].map { TransformPivot(kind: .circleCenter, point: shape.plane.point($0), direction: normal) }
            case .ellipse: points.append(TransformPivot(kind: .circleCenter, point: shape.plane.point(shape.start), direction: normal))
            case .point: points.append(TransformPivot(kind: .point, point: shape.plane.point(shape.start)))
            case .curve: break
            }
        }
        return (points, edges)
    }

    private func pivotSnap(at point: CGPoint, in snaps: (points: [TransformPivot], edges: [[SIMD3<Double>]])) -> TransformPivot? {
        if let nearest = snaps.points.map({ ($0, distance(project(SIMD3<Float>($0.point)), point)) }).filter({ $0.1 < 14 }).min(by: { $0.1 < $1.1 }) {
            return nearest.0
        }
        var best: (pivot: TransformPivot, distance: CGFloat)?
        for edge in snaps.edges {
            for (a, b) in zip(edge, edge.dropFirst()) {
                let sa = project(SIMD3<Float>(a)), sb = project(SIMD3<Float>(b))
                let dx = sb.x - sa.x, dy = sb.y - sa.y, squared = dx * dx + dy * dy
                guard squared > 1 else { continue }
                // The camera is orthographic, so a fraction along the edge on screen is the same along the edge.
                var t = Double(max(0, min(1, ((point.x - sa.x) * dx + (point.y - sa.y) * dy) / squared)))
                if session.snapEnabled, edge.count == 2 {
                    let length = simd_distance(a, b)
                    t = max(0, min(1, (t * length).rounded() / length))
                }
                let p = a + (b - a) * t
                let gap = distance(project(SIMD3<Float>(p)), point)
                guard gap < 10, gap < (best?.distance ?? .infinity), isUnobstructed(p) else { continue }
                best = (TransformPivot(kind: .edge, point: p, direction: b - a), gap)
            }
        }
        return best?.pivot
    }

    /// The double-arrow on a selected sketch region or flat face (no tool chosen): drag it to extrude
    /// straight from 0 mm, shown as soon as it is selected.
    func selectionExtrudeHandle() -> ExtrusionHandle? {
        // A shape's Move/Rotate widget leaves the middle free, so a region's arrow shows with it.
        var widgetAllowsArrow = session.transformWidgetTarget == nil
        if case .shape = session.transformWidgetTarget { widgetAllowsArrow = true }
        guard !session.isExtruding, session.tool == .select, widgetAllowsArrow, !session.isEditingBlocked else { return nil }
        let origin: SIMD3<Double>, normal: SIMD3<Double>
        if let profile = session.extrusionProfile {
            origin = profile.plane.point(profile.anchor); normal = profile.plane.normalAxis
        } else if let face = session.selectedFace, let plane = face.plane {
            origin = face.center; normal = plane.normalAxis
        } else { return nil }
        let start = project(SIMD3<Float>(origin)), ahead = project(SIMD3<Float>(origin + normal * 10))
        let dx = ahead.x - start.x, dy = ahead.y - start.y, length = hypot(dx, dy)
        let axis = length > 4 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: -1)
        // Set off the center so a circle's center handle stays draggable.
        return ExtrusionHandle(origin: start, face: start, center: CGPoint(x: start.x + axis.dx * 36, y: start.y + axis.dy * 36), axis: axis)
    }

    /// The double-arrow beside a selected edge: drag it to round the edge (a fillet).
    func edgeSelectionHandle() -> ExtrusionHandle? {
        guard let picked = session.selectedEdge, session.tool == .select, !session.isEditingBlocked,
              let body = session.workspace.bodies.first(where: { $0.id == picked.bodyID }), let render = solidRender(body),
              let border = zip(render.borders, render.borderEdges).first(where: { $0.1 == picked.edge.index })?.0, !border.isEmpty else { return nil }
        let anchor = project(border[border.count / 2])
        return ExtrusionHandle(origin: anchor, face: anchor, center: CGPoint(x: anchor.x + 36, y: anchor.y - 30))
    }

    /// Double-arrow beside the first picked edge; drag it to size the fillet or chamfer.
    func finishHandle() -> ExtrusionHandle? {
        guard let draft = session.finishDraft, let first = draft.edges.first,
              let body = session.workspace.bodies.first(where: { $0.id == draft.bodyID }), let render = solidRender(body),
              let border = zip(render.borders, render.borderEdges).first(where: { $0.1 == first.index })?.0, !border.isEmpty else { return nil }
        let anchor = project(border[border.count / 2])
        let center = CGPoint(x: anchor.x + 36, y: anchor.y - 30)
        return ExtrusionHandle(origin: anchor, face: anchor, center: center)
    }

    func extrusionHandle() -> ExtrusionHandle? {
        guard session.isExtruding, !(session.isCutting && session.cutThroughAll), let profile = session.extrusionProfile else { return nil }
        // On the region itself: a ring's center is its hole.
        let anchor = profile.anchor
        let origin = project(profile.plane.world(anchor))
        // Both ways, the arrow rides on the far end, half the depth out.
        let end = session.extrusionSymmetric ? session.extrusionDepth / 2 : session.extrusionDepth
        let face = project(profile.plane.world(anchor, height: end))
        let ahead = project(profile.plane.world(anchor, height: end + 10))
        let dx = ahead.x - face.x, dy = ahead.y - face.y, length = hypot(dx, dy)
        // Looking almost straight along the extrusion, fall back to upright (up = toward the viewer).
        let axis = length > 4 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: -1)
        return ExtrusionHandle(origin: origin, face: face, center: CGPoint(x: face.x + axis.dx * 22, y: face.y + axis.dy * 22), axis: axis)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Sketch Fillet, Trim, Dimension, and Measure

    /// Shapes of the visible sketches on the current plane, as they are now (Trim's working copy included).
    private var planeShapes: [SketchShape] { session.visibleWorkspace.shapes.filter { $0.plane == session.plane } }

    /// The corner (two lines meeting) nearest the Pencil, within 16 points.
    func cornerUnder(_ point: CGPoint) -> Point2? {
        let plane = session.plane
        return SketchModify.corners(in: planeShapes).map { ($0, distance(project(plane.world($0)), point)) }
            .filter { $0.1 < 16 }.min { $0.1 < $1.1 }?.0
    }

    /// Trims the stretch of the sketch shape under the Pencil, if any. False when no shape is there.
    @discardableResult
    private func trimUnder(_ point: CGPoint) -> Bool {
        let plane = session.plane
        guard let local = pointOnPlane(point, plane: plane) else { return false }
        let pencil = Point2(x: point.x, y: point.y)
        var best: (UUID, Double)?
        for shape in planeShapes {
            let points = shape.outline.map { project(plane.world($0)) }
            let count = shape.isClosed ? points.count : points.count - 1
            for i in 0..<max(0, count) {
                let j = (i + 1) % points.count
                let d = Geometry.distance(pencil, toSegment: Point2(x: points[i].x, y: points[i].y), Point2(x: points[j].x, y: points[j].y))
                if d < 10, d < best?.1 ?? .infinity { best = (shape.id, d) }
            }
        }
        guard let best else { return false }
        session.trim(best.0, at: local)
        return true
    }

    /// What the Dimension tool picks under the Pencil: a sketch point (an end, corner, or center), a
    /// purple guide point of a solid, or the origin within 14 points; else a sketch line, a side of
    /// a rectangle or slot, a circle, or a straight solid edge on the plane within 10 points.
    func dimensionReference(at point: CGPoint) -> SketchReference? {
        let plane = session.plane
        func screen(_ p: Point2) -> CGPoint { project(plane.world(p)) }
        var points: [SketchReference] = []
        var curves: [(SketchReference, [Point2], Bool)] = []
        for shape in planeShapes {
            switch shape.kind {
            case .line:
                points += [SketchReference.part(.start, of: shape), SketchReference.part(.end, of: shape)].compactMap { $0 }
                if let whole = SketchReference.part(.whole, of: shape) { curves.append((whole, [shape.start, shape.end], false)) }
            case .circle:
                if let center = SketchReference.part(.center, of: shape) { points.append(center) }
                if let whole = SketchReference.part(.whole, of: shape) { curves.append((whole, shape.outline, true)) }
            case .arc:
                points += [SketchReference.part(.start, of: shape), SketchReference.part(.end, of: shape), SketchReference.part(.center, of: shape)].compactMap { $0 }
                if let whole = SketchReference.part(.whole, of: shape) { curves.append((whole, shape.outline, false)) }
            case .rectangle:
                points += (0..<4).compactMap { SketchReference.part(.corner($0), of: shape) } + [SketchReference.part(.center, of: shape)].compactMap { $0 }
                for i in 0..<4 {
                    if let side = SketchReference.part(.side(i), of: shape), case .line(let a, let b) = side.kind { curves.append((side, [a, b], false)) }
                }
            case .slot:
                points += [SketchReference.part(.start, of: shape), SketchReference.part(.end, of: shape)].compactMap { $0 }
                for i in 0..<2 {
                    if let side = SketchReference.part(.side(i), of: shape), case .line(let a, let b) = side.kind { curves.append((side, [a, b], false)) }
                }
            case .ellipse, .point:
                if let center = SketchReference.part(.center, of: shape) { points.append(center) }
            case .curve: break
            }
        }
        if session.sketchMode?.plane == plane { points += session.sketchGuides.map { .fixed(.point($0.point)) } }
        if abs(plane.height(of: .zero)) < 1e-9 { points.append(.fixed(.point(plane.coordinates(of: .zero)))) }
        for edge in session.sketchGuideLines { curves.append((.fixed(.line(edge.0, edge.1)), [edge.0, edge.1], false)) }
        let pencil = Point2(x: point.x, y: point.y)
        if let nearest = points.map({ ($0, distance(screen($0.point), point)) }).filter({ $0.1 < 14 }).min(by: { $0.1 < $1.1 }) {
            return nearest.0
        }
        var best: (SketchReference, Double)?
        for (reference, outline, closed) in curves {
            let projected = outline.map(screen)
            let count = closed ? projected.count : projected.count - 1
            for i in 0..<max(0, count) {
                let j = (i + 1) % projected.count
                let d = Geometry.distance(pencil, toSegment: Point2(x: projected[i].x, y: projected[i].y), Point2(x: projected[j].x, y: projected[j].y))
                if d < 10, d < best?.1 ?? .infinity { best = (reference, d) }
            }
        }
        return best?.0
    }

    /// Measure: a tap picks the point, sketch shape, solid edge, or face under the Pencil (a
    /// double-tap on a face, the whole solid); a tap on nothing clears the picks.
    private func measureTap(at point: CGPoint) {
        let now = CACurrentMediaTime()
        // Points first: solid corners, sketch points, and the origin.
        if let nearest = alignPoints(moving: [], from: false).map({ ($0, distance(project(SIMD3<Float>($0.point)), point)) })
            .filter({ $0.1 < 12 }).min(by: { $0.1 < $1.1 }) {
            session.pickMeasureItem(.point(nearest.0.point))
            return
        }
        if let shape = nearestSketch(at: point, over: solidFace(at: point)) {
            session.pickMeasureItem(.shape(shape.id))
            return
        }
        if let (bodyID, edge) = finishEdge(at: point, tolerance: 10) {
            session.pickMeasureItem(.edge(bodyID: bodyID, edge: edge.index))
            return
        }
        if let hit = frontSurface(at: point, committed: true) {
            if let last = lastMeasureTap, last.bodyID == hit.bodyID, now - last.time < Self.doubleTapInterval, distance(point, last.point) < Self.doubleTapDistance {
                // The second tap of a double-tap: the face picked by the first becomes the whole solid.
                lastMeasureTap = nil
                let face = MeasureItem.face(bodyID: last.bodyID, face: last.face)
                if session.measureItems.contains(face) { session.pickMeasureItem(face) }
                session.pickMeasureItem(.body(hit.bodyID))
                return
            }
            let face = MeasureItem.face(bodyID: hit.bodyID, face: hit.face)
            session.pickMeasureItem(face)
            // Only a tap that picked the face starts a double-tap (one that unpicked it does not).
            lastMeasureTap = session.measureItems.contains(face) ? (hit.bodyID, hit.face, now, point) : nil
            return
        }
        session.pickMeasureItem(nil)
    }

    /// Highlights of the measured items: edges and solid borders in blue, faces tinted, sketch shapes blue.
    private func rebuildMeasurePreview() {
        let shown = session.workspace.visible
        for item in session.measureItems {
            switch item {
            case .edge(let id, let edge):
                guard let body = shown.bodies.first(where: { $0.id == id }), let render = solidRender(body),
                      let border = zip(render.borders, render.borderEdges).first(where: { $0.1 == edge })?.0 else { continue }
                let node = drawOnTop(strokeNode(zip(border, border.dropFirst()).map { ($0, $1) }, color: blue, weight: 1.8), order: 9)
                node.name = "measure.edge"
                previewNode.addChildNode(node)
            case .face(let id, let face):
                guard let body = shown.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
                previewNode.addChildNode(faceTint(render, face: face, color: blue.withAlphaComponent(0.3), name: "measure.face"))
            case .body(let id):
                guard let body = shown.bodies.first(where: { $0.id == id }), let render = solidRender(body) else { continue }
                var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
                for border in render.borders { segments += zip(border, border.dropFirst()).map { ($0, $1) } }
                let node = strokeNode(segments, color: blue, weight: 1.6)
                node.name = "measure.body"
                previewNode.addChildNode(node)
            case .shape(let id):
                guard let shape = shown.shapes.first(where: { $0.id == id }) else { continue }
                previewNode.addChildNode(drawOnTop(outlineNode(shape.outline, plane: shape.plane, color: blue, closed: shape.isClosed), order: 10))
            case .point: break
            }
        }
    }

    // MARK: Revolve

    /// The curved double-arrow, a little ahead of the end face on the circle a point of the region
    /// sweeps. Seen edge-on, the circle has no direction on screen, so the arrow stands upright.
    func revolveHandle() -> RevolveHandle? {
        guard let draft = session.revolveDraft, let spec = draft.spec else { return nil }
        let plane = draft.profile.plane, start = plane.point(draft.profile.anchor)
        func screen(_ degrees: Double) -> CGPoint { project(SIMD3<Float>(spec.rotation(on: plane, degrees: degrees).apply(point: start))) }
        let face = screen(draft.angle), step = 2.0
        let ahead = screen(draft.angle + step), behind = screen(draft.angle - step)
        let dx = ahead.x - behind.x, dy = ahead.y - behind.y, length = hypot(dx, dy)
        let perDegree = Double(length) / (2 * step)
        guard perDegree >= 0.2 else {
            let center = CGPoint(x: face.x, y: face.y - 22)
            return RevolveHandle(center: center, axis: CGVector(dx: 0, dy: -1),
                                 arc: [CGPoint(x: center.x, y: center.y + 17), CGPoint(x: center.x, y: center.y - 17)], perDegree: 1)
        }
        // Centered 22 pt past the end face and 17 pt long each way, like the straight arrow.
        let middle = draft.angle + 22 / perDegree, half = min(60, 17 / perDegree)
        let arc = stride(from: middle - half, through: middle + half + 1e-9, by: half / 8).map(screen)
        let center = screen(middle)
        let tangent = CGVector(dx: (arc.last?.x ?? 0) - (arc.first?.x ?? 0), dy: (arc.last?.y ?? 0) - (arc.first?.y ?? 0))
        let span = max(1e-6, hypot(tangent.dx, tangent.dy))
        // Dragging stays practical when the region is close to the axis or the view is far out.
        return RevolveHandle(center: center, axis: CGVector(dx: tangent.dx / span, dy: tangent.dy / span), arc: arc, perDegree: max(0.5, perDegree))
    }

    /// The axis under the Pencil: a sketch line (or one side of a rectangle), a straight solid edge,
    /// or a world axis through the origin. `.some(nil)` is something under the Pencil that is not straight.
    private func revolveAxis(at point: CGPoint) -> (SIMD3<Double>, SIMD3<Double>)?? {
        let pencil = Point2(x: point.x, y: point.y)
        if let shape = nearestSketch(at: point, over: solidFace(at: point)) {
            switch shape.kind {
            case .line: return (shape.plane.point(shape.start), shape.plane.point(shape.end))
            case .rectangle:
                let corners = shape.outline
                func gap(_ i: Int) -> Double {
                    let a = project(shape.plane.world(corners[i])), b = project(shape.plane.world(corners[(i + 1) % corners.count]))
                    return Geometry.distance(pencil, toSegment: Point2(x: a.x, y: a.y), Point2(x: b.x, y: b.y))
                }
                guard let side = corners.indices.min(by: { gap($0) < gap($1) }) else { return .some(nil) }
                return (shape.plane.point(corners[side]), shape.plane.point(corners[(side + 1) % corners.count]))
            case .slot:
                // A slot's straight sides are axes too.
                let d = shape.end - shape.start, length = d.length
                guard length > 1e-9 else { return .some(nil) }
                let left = Point2(x: -d.y / length, y: d.x / length) * ((shape.width ?? 0) / 2)
                let sides = [(shape.start + left, shape.end + left), (shape.start - left, shape.end - left)]
                func gap(_ side: (Point2, Point2)) -> Double {
                    let a = project(shape.plane.world(side.0)), b = project(shape.plane.world(side.1))
                    return Geometry.distance(pencil, toSegment: Point2(x: a.x, y: a.y), Point2(x: b.x, y: b.y))
                }
                let side = gap(sides[0]) <= gap(sides[1]) ? sides[0] : sides[1]
                return (shape.plane.point(side.0), shape.plane.point(side.1))
            case .circle, .arc, .curve, .ellipse, .point: return .some(nil)
            }
        }
        if let (bodyID, edge) = solidEdge(at: point, tolerance: 10), let body = session.workspace.bodies.first(where: { $0.id == bodyID }),
           let solid = try? SolidKernel.solid(for: body) {
            let samples = solid.edgeSamples(edge, count: 7)
            guard let a = samples.first, let b = samples.last, simd_distance(a, b) > 1e-6 else { return .some(nil) }
            let d = simd_normalize(b - a)
            let straight = samples.allSatisfy { simd_length(($0 - a) - d * simd_dot($0 - a, d)) < 1e-6 }
            return straight ? (a, b) : .some(nil)
        }
        // The world axes run through the origin both ways.
        let origin = project(.zero)
        var best: (axis: WorldAxis, distance: CGFloat)?
        for axis in WorldAxis.allCases {
            let tip = project(axis.direction * 10)
            let dx = tip.x - origin.x, dy = tip.y - origin.y, length = hypot(dx, dy)
            guard length > 2 else { continue }   // seen end-on
            let distance = abs((point.x - origin.x) * dy - (point.y - origin.y) * dx) / length
            if distance < 10 && distance < best?.distance ?? .infinity { best = (axis, distance) }
        }
        return best.map { (SIMD3<Double>.zero, SIMD3<Double>($0.axis.direction)) }
    }

    /// The picked axis (dashed blue, across the region) and the swept tool: translucent gray, or
    /// red for a cut. A join shows in the joined solid itself, so it has no tool on top.
    private func rebuildRevolvePreview(_ draft: RevolveDraft) {
        if let axis = draft.axis {
            let plane = draft.profile.plane, direction = simd_normalize(axis.end - axis.start)
            var along = [0, simd_dot(axis.end - axis.start, direction)]
            for point in draft.profile.outline { along.append(simd_dot(plane.point(point) - axis.start, direction)) }
            if let circle = draft.profile.circle {
                let center = simd_dot(plane.point(circle.center) - axis.start, direction)
                along += [center - circle.radius, center + circle.radius]
            }
            let low = along.min() ?? 0, high = along.max() ?? 0, pad = max(2, (high - low) * 0.1)
            let dash = unitsPerPoint * 7, gap = unitsPerPoint * 5
            var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
            var t = low - pad
            while t < high + pad && segments.count < 400 {
                let end = min(high + pad, t + dash)
                segments.append((SIMD3<Float>(axis.start + direction * t), SIMD3<Float>(axis.start + direction * end)))
                t = end + gap
            }
            let node = drawOnTop(strokeNode(segments, color: blue, weight: 1.3), order: 9)
            node.name = "revolve.axis"
            previewNode.addChildNode(node)
        }
        guard let tool = session.revolveTool, !(draft.mode == .join && session.revolveJoinTarget != nil) else { return }
        previewNode.addChildNode(kernelToolNode(tool, cut: draft.mode == .cut, name: "revolve.preview"))
    }

    /// A kernel solid an operation would add or cut, translucent gray (or red for a cut) with dark borders.
    private func kernelToolNode(_ tool: KernelSolid, cut: Bool, name: String) -> SCNNode {
        let faces: SCNNode, borders: [(SIMD3<Float>, SIMD3<Float>)]
        if let cached = revolveToolNode, cached.tool === tool, cached.cut == cut, cached.node.name == name {
            faces = cached.node
            borders = cached.borders
        } else {
            guard let mesh = try? tool.tessellateForDisplay() else { return SCNNode() }
            let color = cut ? cutRed : UIColor(white: 0.57, alpha: 0.38)
            faces = SCNNode(geometry: KernelSceneGeometry(mesh, faceMaterial: material(color)).faces)
            faces.name = name
            borders = mesh.edges.filter(\.isBoundary).flatMap { edge in zip(edge.points, edge.points.dropFirst()).map { ($0, $1) } }
            revolveToolNode = (tool, cut, faces, borders)
        }
        // Strokes are rebuilt every time (one preview solid, so it is cheap).
        faces.childNodes.forEach { $0.removeFromParentNode() }
        faces.addChildNode(strokeNode(borders, color: UIColor(white: 0.22, alpha: 1), weight: 0.6))
        return faces
    }

    /// The curved arrow: a thick blue arc with a dark outline and an arrowhead at each end, plus the
    /// dashed path that point of the region has swept so far.
    private func drawRevolveHandle(_ handle: RevolveHandle) {
        if let draft = session.revolveDraft, let spec = draft.spec, abs(draft.angle) >= 0.1 {
            let plane = draft.profile.plane, start = plane.point(draft.profile.anchor)
            let steps = max(2, min(120, Int(abs(draft.angle) / 3)))
            let swept = UIBezierPath()
            for i in 0...steps {
                let p = project(SIMD3<Float>(spec.rotation(on: plane, degrees: draft.angle * Double(i) / Double(steps)).apply(point: start)))
                if i == 0 { swept.move(to: p) } else { swept.addLine(to: p) }
            }
            swept.setLineDash([5, 4], count: 2, phase: 0)
            swept.lineWidth = 1
            UIColor(white: 0.15, alpha: 0.8).setStroke(); swept.stroke()
        }
        guard handle.arc.count >= 2 else { return }
        let body = UIBezierPath()
        handle.arc.enumerated().forEach { $0.offset == 0 ? body.move(to: $0.element) : body.addLine(to: $0.element) }
        body.lineJoinStyle = .round
        UIColor(white: 0.15, alpha: 1).setStroke(); body.lineWidth = 8; body.stroke()
        blue.setStroke(); body.lineWidth = 6; body.stroke()
        let count = handle.arc.count
        for (tip, before) in [(handle.arc[count - 1], handle.arc[count - 2]), (handle.arc[0], handle.arc[1])] {
            let dx = tip.x - before.x, dy = tip.y - before.y, length = max(1e-3, hypot(dx, dy))
            let d = CGVector(dx: dx / length, dy: dy / length), n = CGVector(dx: -d.dy, dy: d.dx)
            let head = UIBezierPath()
            head.move(to: CGPoint(x: tip.x + d.dx * 9, y: tip.y + d.dy * 9))
            head.addLine(to: CGPoint(x: tip.x - d.dx * 2 + n.dx * 9, y: tip.y - d.dy * 2 + n.dy * 9))
            head.addLine(to: CGPoint(x: tip.x - d.dx * 2 - n.dx * 9, y: tip.y - d.dy * 2 - n.dy * 9))
            head.close()
            blue.setFill(); head.fill()
            head.lineWidth = 1; head.lineJoinStyle = .round
            UIColor(white: 0.15, alpha: 1).setStroke(); head.stroke()
        }
    }

    /// Every value label on the canvas, in the chosen length unit.
    func dimensionAnnotations() -> [CanvasDimension] {
        annotations().map { var annotation = $0; annotation.unit = session.lengthUnit; return annotation }
    }

    private func annotations() -> [CanvasDimension] {
        guard isViewLoaded else { return [] }
        if let section = session.section {
            guard let handle = sectionHandle() else { return [] }
            return [operationLabel(.sectionOffset, value: section.offset, beyond: handle)]
        }
        if session.tool.isPlaneTool {
            guard let handle = planeHandle(), let draft = session.planeDraft else { return [] }
            return [operationLabel(.planeOffset, value: draft.offset, beyond: handle)]
        }
        if session.tool == .align {
            guard let handle = alignHandle(), let draft = session.alignDraft else { return [] }
            return [operationLabel(.alignOffset, value: draft.offset, beyond: handle),
                    CanvasDimension(target: .alignAngle, value: draft.angle, center: CGPoint(x: handle.origin.x - 60, y: handle.origin.y + 36))]
        }
        if let draft = session.patternDraft {
            // Each used direction's distance past its arrow; the angle beside the ring it turns about.
            guard let widget = patternWidget() else { return [] }
            if draft.spec.kind == .linear {
                return widget.arrows.filter { draft.spec.directions[$0.axis].isUsed }.map { arrow in
                    CanvasDimension(target: .patternDistance(arrow.axis), value: draft.spec.directions[arrow.axis].distance,
                                    center: CGPoint(x: arrow.tip.x + arrow.direction.dx * 34, y: arrow.tip.y + arrow.direction.dy * 34))
                }
            }
            guard abs(draft.spec.angle) > 1e-9 else { return [] }
            var point = CGPoint(x: widget.center.x + 70, y: widget.center.y - 70)
            if let arc = widget.arcs.first(where: { $0.axis == draft.circularAxis }) {
                let middle = arc.points[arc.points.count / 2]
                let dx = middle.x - widget.center.x, dy = middle.y - widget.center.y, length = max(1, hypot(dx, dy))
                point = CGPoint(x: middle.x + dx / length * 34, y: middle.y + dy / length * 34)
            }
            return [CanvasDimension(target: .patternAngle, value: draft.spec.angle, center: point)]
        }
        if let draft = session.scaleDraft {
            // The percentage past the first arrow (or each arrow's, stretching).
            guard let widget = scaleWidget() else { return [] }
            let arrows = draft.uniform ? Array(widget.arrows.prefix(1)) : widget.arrows
            return arrows.map { arrow in
                CanvasDimension(target: .scalePercent(draft.uniform ? 3 : arrow.axis), value: draft.uniform ? draft.percents.x : draft.percents[arrow.axis],
                                center: CGPoint(x: arrow.tip.x + arrow.direction.dx * 38, y: arrow.tip.y + arrow.direction.dy * 38))
            }
        }
        if let record = session.transformDrag ?? session.editableTransform, let widget = transformWidget() {
            // The amount of the move or turn, past the dragged arrow or beside the arc.
            let target = record.dimensionTarget
            var point = CGPoint(x: widget.center.x + 70, y: widget.center.y - 70)
            if let arrow = widget.arrows.first(where: { .move($0.axis) == record.handle }) {
                point = CGPoint(x: arrow.tip.x + arrow.direction.dx * 34, y: arrow.tip.y + arrow.direction.dy * 34)
            } else if let arc = widget.arcs.first(where: { .rotate($0.axis) == record.handle }) {
                let middle = arc.points[arc.points.count / 2]
                let dx = middle.x - widget.center.x, dy = middle.y - widget.center.y, length = max(1, hypot(dx, dy))
                point = CGPoint(x: middle.x + dx / length * 34, y: middle.y + dy / length * 34)
            }
            return [CanvasDimension(target: target, value: record.amount, center: point)]
        }
        if let draft = session.revolveDraft {
            guard let handle = revolveHandle() else { return [] }
            return [operationLabel(.revolveAngle, value: draft.angle, beyond: handle.labelAnchor)]
        }
        if session.isExtruding {
            // Through All has no depth, so no label; sketch dimensions stay hidden during extrusion.
            guard let handle = extrusionHandle() else { return [] }
            return [operationLabel(.extrusion, value: session.extrusionValue, beyond: handle)]
        }
        if let draft = session.shellDraft {
            guard let handle = shellHandle() else { return [] }
            return [operationLabel(.shellThickness, value: draft.thickness, beyond: handle)]
        }
        if let draft = session.holeDraft {
            // Diameter to the right of the hole, depth below it (through holes have no depth).
            let center = project(draft.plane.world(draft.center))
            let radius = CGFloat(draft.spec.diameter / 2 / unitsPerPoint)
            var labels = [CanvasDimension(target: .holeDiameter, value: draft.spec.diameter,
                                          center: CGPoint(x: center.x + radius + 48, y: center.y))]
            if let depth = draft.depth {
                labels.append(CanvasDimension(target: .holeDepth, value: depth, center: CGPoint(x: center.x, y: center.y + radius + 34)))
            }
            return labels
        }
        if let draft = session.textDraft {
            // Height above the text, depth below it.
            let points = draft.spec?.loops.flatMap { [$0.start] + $0.segments.flatMap(\.points) }.map { project(draft.plane.world($0)) } ?? []
            let center = project(draft.plane.world(draft.center))
            let top = points.map(\.y).min() ?? center.y - 20, bottom = points.map(\.y).max() ?? center.y + 20
            return [CanvasDimension(target: .textHeight, value: draft.height, center: CGPoint(x: center.x, y: top - 26)),
                    CanvasDimension(target: .textDepth, value: abs(draft.depth), center: CGPoint(x: center.x, y: bottom + 26))]
        }
        if let draft = session.threadDraft, let body = session.workspace.bodies.first(where: { $0.id == draft.bodyID }) {
            // Diameter and pitch beside the middle of the thread.
            let spec = draft.spec
            let middle = body.worldPoint(spec.origin + spec.axis * (spec.length / 2))
            let across = body.worldPoint(spec.origin + spec.axis * (spec.length / 2) + spec.reference) - middle
            let side = project(SIMD3<Float>(middle + simd_normalize(across) * (spec.majorDiameter / 2)))
            let center = project(SIMD3<Float>(middle))
            let dx = side.x - center.x, dy = side.y - center.y, reach = max(hypot(dx, dy), 1)
            let out = CGPoint(x: center.x + dx / reach * (reach + 60), y: center.y + dy / reach * (reach + 60))
            return [CanvasDimension(target: .threadDiameter, value: spec.majorDiameter, center: out),
                    CanvasDimension(target: .threadPitch, value: spec.pitch, center: CGPoint(x: out.x, y: out.y + 34))]
        }
        if let draft = session.primitiveDraft {
            // Its sizes in a column to the right of the primitive.
            let corners: [CGPoint]
            if let body = session.primitivePreview?.bodies.last, let bounds = try? SolidKernel.solid(for: body).bounds {
                var points: [CGPoint] = []
                for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                    points.append(project(SIMD3<Float>(Float(x), Float(y), Float(z))))
                } } }
                corners = points
            } else {
                corners = [project(SIMD3<Float>(draft.plane.point(draft.center)))]
            }
            let right = corners.map(\.x).max() ?? 0, middle = (corners.map(\.y).min()! + corners.map(\.y).max()!) / 2
            let count = draft.sizes.count
            return draft.sizes.indices.map { index in
                CanvasDimension(target: .primitiveSize(draft.kind, index), value: draft.sizes[index],
                                center: CGPoint(x: right + 64, y: middle + CGFloat(index) * 36 - CGFloat(count - 1) * 18))
            }
        }
        if let draft = session.pegDraft {
            // Diameter to the right of the peg, height below it.
            let center = project(draft.plane.world(draft.center))
            let radius = CGFloat(draft.spec.socketDiameter / 2 / unitsPerPoint)
            var labels = [CanvasDimension(target: .pegDiameter, value: draft.spec.diameter, center: CGPoint(x: center.x + radius + 48, y: center.y)),
                          CanvasDimension(target: .pegHeight, value: draft.spec.height, center: CGPoint(x: center.x, y: center.y + radius + 34))]
            // A separate peg's length into the face, on the other side.
            if draft.spec.separate {
                labels.append(CanvasDimension(target: .pegEmbed, value: draft.spec.embed, center: CGPoint(x: center.x - radius - 48, y: center.y)))
            }
            return labels
        }
        if let draft = session.finishDraft {
            guard let handle = finishHandle() else { return [] }
            return [operationLabel(.finishSize(draft.kind), value: draft.size, beyond: handle)]
        }
        if let body = session.selectedBody, let spec = body.revolve {
            // A revolved solid's angle, beside the point of its sweep nearest the middle of the view
            // (clear of the hint above and the dock below).
            let plane = body.profile.plane, start = plane.point(body.profile.center)
            let middle = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let anchor = (0...16).map { project(SIMD3<Float>(spec.rotation(on: plane, degrees: spec.angle * Double($0) / 16).apply(point: start))) }
                .min { distance($0, middle) < distance($1, middle) } ?? middle
            return [CanvasDimension(target: .bodyAngle(body.id), value: spec.angle, center: CGPoint(x: anchor.x + 56, y: anchor.y))]
        }
        if let face = session.selectedFace, session.tool == .select, let finish = session.selectedFinish {
            // A fillet's radius or a chamfer's distance, beside where its face was tapped, off the solid.
            let point = face.point ?? face.center
            let a = project(SIMD3<Float>(point))
            let middle = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let dx = a.x - middle.x, dy = a.y - middle.y, length = max(1, hypot(dx, dy))
            let center = CGPoint(x: a.x + dx / length * 60, y: a.y + dy / length * 60)
            return [CanvasDimension(target: .selectedFinish(finish.kind), value: finish.size, center: center, extensions: [(a, center)])]
        }
        if let face = session.selectedFace, session.tool == .select, let size = session.selectedFaceSize,
           let body = session.workspace.bodies.first(where: { $0.id == face.bodyID }), let solid = try? SolidKernel.solid(for: body) {
            // A round face's diameter beside it; a flat face's distance to the face behind it, as a dimension.
            let point = face.point ?? face.center
            switch size {
            case .diameter(let value, _):
                guard let cylinder = solid.faceCylinder(face.face) else { return [] }
                let axis = simd_normalize(cylinder.direction), d = point - cylinder.point
                let middle = cylinder.point + axis * simd_dot(d, axis)
                // Straight across the face as it is seen, at the height it was tapped.
                let sideways = simd_cross(axis, viewDirection)
                let across = simd_length(sideways) > 1e-6 ? simd_normalize(sideways) :
                    (simd_length(d - axis * simd_dot(d, axis)) > 1e-9 ? simd_normalize(d - axis * simd_dot(d, axis)) : SIMD3(1, 0, 0))
                let a = project(SIMD3<Float>(middle - across * cylinder.radius)), b = project(SIMD3<Float>(middle + across * cylinder.radius))
                let dx = b.x - a.x, dy = b.y - a.y, length = max(1, hypot(dx, dy))
                let center = CGPoint(x: b.x + dx / length * 45, y: b.y + dy / length * 45)
                return [CanvasDimension(target: .faceDiameter, value: value, center: center, baseline: (a, b), extensions: [(b, center)])]
            case .distance(let value, _):
                guard let plane = solid.facePlane(face.face) else { return [] }
                let a = project(SIMD3<Float>(point)), b = project(SIMD3<Float>(point - plane.normal * value))
                return [annotationBetween(a, b, outward: CGPoint(x: -(b.y - a.y), y: b.x - a.x), target: .faceDistance, value: value)]
            }
        }
        if let body = session.selectedBody, !body.isImported, !body.cuts.contains(where: { $0.scale != nil }) {
            let point = body.profile.outline.max { project(body.profile.plane.world($0)).x < project(body.profile.plane.world($1)).x } ?? body.profile.center
            return [annotationBetween(project(body.profile.plane.world(point, height: body.baseOffset)),
                                      project(body.profile.plane.world(point, height: body.baseOffset + body.depth)),
                                      outward: CGPoint(x: 1, y: 0), target: .bodyDepth(body.id), value: body.depth)]
        }
        if session.tool == .dimension { return relationAnnotations() }
        if let record = session.editablePolygon {
            // The number of sides, in the middle of the polygon just drawn.
            return [CanvasDimension(target: .polygonSides, value: Double(record.sides), center: project(record.plane.world(record.center)))]
        }
        if let draft = session.offsetDraft {
            // The distance beside the new outline.
            guard let shape = session.offsetPreview.first else { return [] }
            let outline = shape.outline, point = project(shape.plane.world(outline[outline.count / 2]))
            return [CanvasDimension(target: .offsetDistance, value: draft.distance, center: CGPoint(x: point.x + 40, y: point.y - 28))]
        }
        if let corner = session.editableCorner, let arc = session.workspace.shapes.first(where: { $0.id == corner.arc }), let c = arc.arcCenter {
            // The radius just rounded, past the arc's middle; tap it to type another.
            let center = project(arc.plane.world(c)), middle = project(arc.plane.world(arc.arcMiddle))
            let dx = middle.x - center.x, dy = middle.y - center.y, length = max(1, hypot(dx, dy))
            return [CanvasDimension(target: .cornerRadius, value: corner.radius, center: CGPoint(x: middle.x + dx / length * 34, y: middle.y + dy / length * 34))]
        }
        let shapes: [SketchShape]
        if let shape = session.preview ?? editableShape { shapes = [shape] }
        else if !session.isMultipleSelection, let profile = session.selectedProfile { shapes = session.visibleWorkspace.shapes.filter { profile.sourceIDs.contains($0.id) } }
        else { shapes = [] }
        var annotations: [CanvasDimension] = []
        for shape in shapes where shape.isValid {
            switch shape.kind {
            case .line:
                annotations.append(annotationBetween(project(shape.plane.world(shape.start)), project(shape.plane.world(shape.end)),
                                                     outward: CGPoint(x: 0, y: -1), target: .shape(shape.id, .length), value: shape.start.distance(to: shape.end)))
            case .rectangle:
                let points = shape.outline.map { project(shape.plane.world($0)) }
                let center = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
                let top = CGPoint(x: (points[3].x + points[2].x) / 2 - center.x, y: (points[3].y + points[2].y) / 2 - center.y)
                let left = CGPoint(x: (points[0].x + points[3].x) / 2 - center.x, y: (points[0].y + points[3].y) / 2 - center.y)
                annotations.append(annotationBetween(points[3], points[2], outward: top, target: .shape(shape.id, .width), value: abs(shape.end.x - shape.start.x)))
                annotations.append(annotationBetween(points[0], points[3], outward: left, target: .shape(shape.id, .height), value: abs(shape.end.y - shape.start.y)))
            case .circle:
                let radius = shape.start.distance(to: shape.end)
                let radial = Point2(x: cos(.pi / 4), y: sin(.pi / 4)) * radius
                let a = project(shape.plane.world(shape.start - radial)), b = project(shape.plane.world(shape.start + radial))
                let dx = b.x - a.x, dy = b.y - a.y, length = max(1, hypot(dx, dy))
                let center = CGPoint(x: b.x + dx / length * 45, y: b.y + dy / length * 45)
                annotations.append(.init(target: .shape(shape.id, .diameter), value: radius * 2, center: center,
                                         baseline: (a, b), extensions: [(b, center)]))
            case .arc:
                guard let c = shape.arcCenter else { break }
                let center = project(shape.plane.world(c)), middle = project(shape.plane.world(shape.arcMiddle))
                let dx = middle.x - center.x, dy = middle.y - center.y, length = max(1, hypot(dx, dy))
                let label = CGPoint(x: middle.x + dx / length * 40, y: middle.y + dy / length * 40)
                annotations.append(.init(target: .shape(shape.id, .radius), value: shape.start.distance(to: c), center: label,
                                         baseline: (center, middle), extensions: [(middle, label)]))
            case .slot:
                let d = shape.end - shape.start, length = d.length, radius = (shape.width ?? 0) / 2
                guard length > 1e-9 else { break }
                let left = Point2(x: -d.y / length, y: d.x / length)
                let a = project(shape.plane.world(shape.start)), b = project(shape.plane.world(shape.end))
                let side = project(shape.plane.world(shape.start + left)), ahead = project(shape.plane.world(shape.end + d * (1 / length)))
                annotations.append(annotationBetween(a, b, outward: CGPoint(x: side.x - a.x, y: side.y - a.y), target: .shape(shape.id, .length), value: length))
                annotations.append(annotationBetween(project(shape.plane.world(shape.end - left * radius)), project(shape.plane.world(shape.end + left * radius)),
                                                     outward: CGPoint(x: ahead.x - b.x, y: ahead.y - b.y), target: .shape(shape.id, .width), value: shape.width ?? 0))
            case .ellipse:
                // Its two diameters, along its axis and across it.
                guard let ellipse = shape.ellipseProfile else { break }
                let across = Point2(x: -sin(ellipse.angle), y: cos(ellipse.angle)) * ellipse.radiusY
                let along = Point2(x: cos(ellipse.angle), y: sin(ellipse.angle)) * ellipse.radiusX
                let center = project(shape.plane.world(shape.start))
                func screen(_ p: Point2) -> CGPoint { project(shape.plane.world(p)) }
                let farSide = screen(shape.start + across)
                annotations.append(annotationBetween(screen(shape.start - along + across), screen(shape.start + along + across),
                                                     outward: CGPoint(x: farSide.x - center.x, y: farSide.y - center.y),
                                                     target: .shape(shape.id, .width), value: 2 * ellipse.radiusX))
                let farEnd = screen(shape.start + along)
                annotations.append(annotationBetween(screen(shape.start + along - across), screen(shape.start + along + across),
                                                     outward: CGPoint(x: farEnd.x - center.x, y: farEnd.y - center.y),
                                                     target: .shape(shape.id, .height), value: 2 * ellipse.radiusY))
            case .curve, .point: break
            }
        }
        return annotations
    }

    /// The Dimension tool's values: across and up dimensions with extension lines above and beside
    /// the picks, aligned distances, and angles at the lines' meeting.
    private func relationAnnotations() -> [CanvasDimension] {
        let plane = session.plane, gap = 34 * unitsPerPoint
        func screen(_ p: Point2) -> CGPoint { project(plane.world(p)) }
        var result: [CanvasDimension] = []
        for (index, dimension) in session.sketchDimensions.enumerated() {
            let target = DimensionTarget.relation(index, angle: dimension.kind.isAngle)
            let from = dimension.from, to = dimension.to
            switch dimension.kind {
            case .horizontal, .vertical:
                let across = dimension.kind == .horizontal
                let level = across ? max(from.y, to.y) + gap : max(from.x, to.x) + gap
                let a = across ? Point2(x: from.x, y: level) : Point2(x: level, y: from.y)
                let b = across ? Point2(x: to.x, y: level) : Point2(x: level, y: to.y)
                let sa = screen(a), sb = screen(b)
                var angle = atan2(sb.y - sa.y, sb.x - sa.x)
                if angle > .pi / 2 { angle -= .pi }
                if angle < -.pi / 2 { angle += .pi }
                result.append(CanvasDimension(target: target, value: dimension.value, center: CGPoint(x: (sa.x + sb.x) / 2, y: (sa.y + sb.y) / 2),
                                              angle: angle, baseline: (sa, sb), extensions: [(screen(from), sa), (screen(to), sb)]))
            case .distance, .length:
                let sa = screen(from), sb = screen(to)
                result.append(annotationBetween(sa, sb, outward: CGPoint(x: -(sb.y - sa.y), y: sb.x - sa.x), target: target, value: dimension.value))
            case .angle:
                guard let pivot = dimension.pivot else { continue }
                let p = screen(pivot), a = screen(from), b = screen(to)
                let ua = CGVector(dx: a.x - p.x, dy: a.y - p.y), ub = CGVector(dx: b.x - p.x, dy: b.y - p.y)
                let la = max(1, hypot(ua.dx, ua.dy)), lb = max(1, hypot(ub.dx, ub.dy))
                var bisector = CGVector(dx: ua.dx / la + ub.dx / lb, dy: ua.dy / la + ub.dy / lb)
                let length = hypot(bisector.dx, bisector.dy)
                bisector = length > 1e-6 ? CGVector(dx: bisector.dx / length, dy: bisector.dy / length) : CGVector(dx: -ua.dy / la, dy: ua.dx / la)
                result.append(CanvasDimension(target: target, value: dimension.value, center: CGPoint(x: p.x + bisector.dx * 62, y: p.y + bisector.dy * 62)))
            case .diameter, .radius: continue
            }
        }
        return result
    }

    /// The outlined value just past the double-arrow's increasing end, running along the arrow
    /// and turned to stay readable (never upside down).
    private func operationLabel(_ target: DimensionTarget, value: Double, beyond handle: ExtrusionHandle) -> CanvasDimension {
        var angle = atan2(handle.axis.dy, handle.axis.dx)
        if angle > .pi / 2 { angle -= .pi }
        if angle <= -.pi / 2 - 0.001 { angle += .pi }
        var dimension = CanvasDimension(target: target, value: value, center: .zero, angle: angle)
        let distance = 10 + dimension.labelSize.width / 2
        dimension.center = CGPoint(x: handle.top.x + handle.axis.dx * distance, y: handle.top.y + handle.axis.dy * distance)
        return dimension
    }

    private func annotationBetween(_ a: CGPoint, _ b: CGPoint, outward: CGPoint, target: DimensionTarget, value: Double) -> CanvasDimension {
        let dx = b.x - a.x, dy = b.y - a.y, length = max(1, hypot(dx, dy))
        var nx = -dy / length, ny = dx / length
        if nx * outward.x + ny * outward.y < 0 { nx = -nx; ny = -ny }
        let offset: CGFloat = 38
        let da = CGPoint(x: a.x + nx * offset, y: a.y + ny * offset)
        let db = CGPoint(x: b.x + nx * offset, y: b.y + ny * offset)
        var angle = atan2(dy, dx)
        if angle > .pi / 2 { angle -= .pi }
        if angle < -.pi / 2 { angle += .pi }
        return .init(target: target, value: value, center: CGPoint(x: (da.x + db.x) / 2, y: (da.y + db.y) / 2), angle: angle,
                     baseline: (da, db), extensions: [(CGPoint(x: a.x + nx * 6, y: a.y + ny * 6), CGPoint(x: da.x + nx * 8, y: da.y + ny * 8)),
                                                      (CGPoint(x: b.x + nx * 6, y: b.y + ny * 6), CGPoint(x: db.x + nx * 8, y: db.y + ny * 8))])
    }

    func drawOverlay(in rect: CGRect) {
        UIColor(white: 0.12, alpha: 1).setStroke()
        UIColor(white: 0.12, alpha: 1).setFill()
        for annotation in dimensionAnnotations() {
            let guides = UIBezierPath()
            guides.lineWidth = 0.8
            for (a, b) in annotation.extensions { guides.move(to: a); guides.addLine(to: b) }
            if let (a, b) = annotation.baseline {
                guides.move(to: a); guides.addLine(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x)
                for (point, direction) in [(a, angle), (b, angle + .pi)] {
                    let arrow = UIBezierPath()
                    arrow.move(to: point)
                    arrow.addLine(to: CGPoint(x: point.x + cos(direction - 0.23) * 9, y: point.y + sin(direction - 0.23) * 9))
                    arrow.addLine(to: CGPoint(x: point.x + cos(direction + 0.23) * 9, y: point.y + sin(direction + 0.23) * 9))
                    arrow.close(); arrow.fill()
                }
            }
            guides.stroke()
        }
        if let shape = session.preview ?? editableShape, !session.isExtruding {
            for (handle, point) in sketchHandles(for: shape) {
                let p = project(shape.plane.world(point, height: 0.05))
                let side: Bool
                if case .side = handle { side = true } else { side = false }
                let size: CGFloat = side ? 5 : 7
                let dot = UIBezierPath(ovalIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                UIColor.white.setFill(); dot.fill(); blue.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
            if !session.snapLabel.isEmpty {
                let p = project(shape.plane.world(shape.end))
                drawPill(session.snapLabel, at: CGPoint(x: p.x + 14, y: p.y + 12), color: .secondaryLabel)
            }
        }
        if let snap = liveSnap, strokeStarted, !snap.result.alignedTo.isEmpty {
            // Dashed purple alignment guides from each aligned guide point to the Pencil's snap.
            let guide = UIBezierPath()
            let target = project(snap.plane.world(snap.result.point))
            for source in snap.result.alignedTo {
                guide.move(to: project(snap.plane.world(source)))
                guide.addLine(to: target)
            }
            guide.setLineDash([6, 4], count: 2, phase: 0)
            guide.lineWidth = 1.2
            UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 0.9).setStroke()
            guide.stroke()
        }
        if let sketchMode = session.sketchMode {
            // Guide points: purple anchors on solid corners, edge midpoints, and centers.
            let purple = UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1)
            for guide in session.sketchGuides {
                let p = project(sketchMode.plane.world(guide.point))
                let size: CGFloat = guide.kind == .center ? 8 : 7
                let dot = UIBezierPath(ovalIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                purple.withAlphaComponent(0.9).setFill(); dot.fill()
                UIColor.white.setStroke(); dot.lineWidth = 1; dot.stroke()
            }
        }
        if let draft = session.holeDraft {
            // The hole's outline (and counterbore or countersink outline) on the face.
            let center = project(draft.plane.world(draft.center))
            let outer = draft.spec.kind == .counterbore ? draft.spec.counterboreDiameter : draft.spec.kind == .countersink ? draft.spec.countersinkDiameter : 0
            for diameter in [draft.spec.diameter, outer] where diameter > 0 {
                let r = CGFloat(diameter / 2 / unitsPerPoint)
                let ring = UIBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                ring.lineWidth = 1.6
                (session.draftError == nil ? blue : UIColor.systemRed).setStroke(); ring.stroke()
            }
            let cross = UIBezierPath()
            cross.move(to: CGPoint(x: center.x - 5, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 5, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 5)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 5))
            cross.lineWidth = 1; blue.setStroke(); cross.stroke()
        }
        if let draft = session.textDraft, let spec = draft.spec {
            // The letters' outlines at once; the solid preview follows.
            let outline = UIBezierPath()
            for loop in spec.loops {
                outline.move(to: project(draft.plane.world(loop.start)))
                for segment in loop.segments {
                    let p = segment.points.map { project(draft.plane.world($0)) }
                    switch p.count {
                    case 1: outline.addLine(to: p[0])
                    case 2: outline.addQuadCurve(to: p[1], controlPoint: p[0])
                    default: outline.addCurve(to: p[2], controlPoint1: p[0], controlPoint2: p[1])
                    }
                }
                outline.close()
            }
            outline.lineWidth = 1.2
            (session.textError == nil ? blue : UIColor.systemRed).setStroke(); outline.stroke()
        }
        if let draft = session.pegDraft {
            // The peg's outline, and its socket's (wider by the clearance) dashed around it.
            let center = project(draft.plane.world(draft.center))
            let color = session.draftError == nil ? blue : UIColor.systemRed
            for (diameter, dashed) in [(draft.spec.diameter, false), (draft.spec.socketDiameter, true)] {
                let r = CGFloat(diameter / 2 / unitsPerPoint)
                let ring = UIBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                ring.lineWidth = dashed ? 1 : 1.6
                if dashed { ring.setLineDash([4, 3], count: 2, phase: 0) }
                color.setStroke(); ring.stroke()
            }
            let cross = UIBezierPath()
            cross.move(to: CGPoint(x: center.x - 5, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 5, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 5)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 5))
            cross.lineWidth = 1; blue.setStroke(); cross.stroke()
        }
        if let widget = transformWidget() {
            drawGizmo(widget, active: session.transformDrag?.handle, draggingCenter: session.isDraggingPivot,
                      snaps: session.isDraggingPivot ? pivotSnaps().points : [])
        }
        if let widget = scaleWidget() {
            drawGizmo(widget, active: scaleGesture.map { .move($0.axis) }, draggingCenter: false, snaps: [])
        }
        if let widget = patternWidget() {
            drawGizmo(widget, active: patternGesture?.handle, draggingCenter: session.isDraggingPatternCenter,
                      snaps: session.isDraggingPatternCenter ? patternCenterSnaps().points : [])
        }
        if let handle = revolveHandle() { drawRevolveHandle(handle) }
        drawSketchToolOverlay()
        if let draft = session.alignDraft, draft.step != .bodies, !(draft.step == .to && draft.from == nil) {
            // The points Align can pick right now, as small dots (corners, sketch points, the origin).
            for feature in alignPoints(moving: Set(draft.bodies), from: draft.step == .from) {
                let p = project(SIMD3<Float>(feature.point))
                let dot = UIBezierPath(ovalIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                UIColor.white.setFill(); dot.fill()
                (draft.step == .from ? blue : UIColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 1)).setStroke()
                dot.lineWidth = 1.5; dot.stroke()
            }
        }
        for handle in [extrusionHandle(), selectionExtrudeHandle(), edgeSelectionHandle(), finishHandle(), shellHandle(), planeHandle(), alignHandle(), sectionHandle()].compactMap({ $0 }) {
            let guide = UIBezierPath()
            guide.move(to: handle.origin); guide.addLine(to: handle.face); guide.addLine(to: handle.bottom)
            guide.setLineDash([5, 4], count: 2, phase: 0)
            guide.lineWidth = 1
            UIColor(white: 0.15, alpha: 0.8).setStroke(); guide.stroke()
            let arrow = UIBezierPath()
            let points: [CGPoint] = [.init(x: 0, y: -17), .init(x: 10, y: -7), .init(x: 7, y: -4), .init(x: 3, y: -8),
                                     .init(x: 3, y: 8), .init(x: 7, y: 4), .init(x: 10, y: 7), .init(x: 0, y: 17),
                                     .init(x: -10, y: 7), .init(x: -7, y: 4), .init(x: -3, y: 8), .init(x: -3, y: -8),
                                     .init(x: -7, y: -4), .init(x: -10, y: -7)]
            let up = handle.axis, right = CGVector(dx: -handle.axis.dy, dy: handle.axis.dx)
            for (i, point) in points.enumerated() {
                // Glyph coordinates are upright (−y = increasing); turn them onto the handle axis.
                let p = CGPoint(x: handle.center.x + right.dx * point.x - up.dx * point.y,
                                y: handle.center.y + right.dy * point.x - up.dy * point.y)
                if i == 0 { arrow.move(to: p) } else { arrow.addLine(to: p) }
            }
            arrow.close()
            blue.setFill(); arrow.fill()
            arrow.lineWidth = 1; arrow.lineJoinStyle = .round
            UIColor(white: 0.15, alpha: 1).setStroke(); arrow.stroke()
        }
    }

    /// Sketch Fillet's corners, the Dimension tool's picks and angle arcs, and Measure's picks and the
    /// dashed line between the nearest points.
    private func drawSketchToolOverlay() {
        let plane = session.plane
        func screen(_ p: Point2) -> CGPoint { project(plane.world(p)) }
        func ring(_ p: CGPoint, filled: Bool, size: CGFloat = 8) {
            let dot = UIBezierPath(ovalIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
            (filled ? blue : UIColor.white).setFill(); dot.fill()
            blue.setStroke(); dot.lineWidth = 1.5; dot.stroke()
        }
        if session.tool == .cornerFillet {
            for corner in SketchModify.corners(in: planeShapes) { ring(screen(corner), filled: false) }
        }
        if session.tool == .dimension, let picks = session.dimensionPicks {
            for (index, pick) in [picks.first, picks.second].compactMap({ $0 }).enumerated() {
                switch pick.kind {
                case .point(let p): ring(screen(p), filled: index == 1, size: 10)
                case .line(let a, let b):
                    let path = UIBezierPath(); path.move(to: screen(a)); path.addLine(to: screen(b))
                    path.lineWidth = 3; blue.withAlphaComponent(index == 1 ? 1 : 0.6).setStroke(); path.stroke()
                case .circle(let c, let r):
                    let path = UIBezierPath()
                    for i in 0...72 {
                        let p = screen(c + Point2(x: cos(Double(i) * .pi / 36), y: sin(Double(i) * .pi / 36)) * r)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.lineWidth = 3; blue.withAlphaComponent(index == 1 ? 1 : 0.6).setStroke(); path.stroke()
                }
            }
            for dimension in session.sketchDimensions where dimension.kind == .angle {
                guard let pivot = dimension.pivot else { continue }
                // The angle's arc between the two rays.
                let p = screen(pivot), a = screen(dimension.from), b = screen(dimension.to)
                let start = atan2(a.y - p.y, a.x - p.x), end = atan2(b.y - p.y, b.x - p.x)
                var sweep = end - start
                if sweep > .pi { sweep -= 2 * .pi } else if sweep < -.pi { sweep += 2 * .pi }
                let arc = UIBezierPath()
                for i in 0...24 {
                    let t = start + sweep * CGFloat(i) / 24, q = CGPoint(x: p.x + cos(t) * 40, y: p.y + sin(t) * 40)
                    if i == 0 { arc.move(to: q) } else { arc.addLine(to: q) }
                }
                arc.lineWidth = 0.9; UIColor(white: 0.12, alpha: 1).setStroke(); arc.stroke()
                for ray in [a, b] {
                    let line = UIBezierPath(); line.move(to: p); line.addLine(to: ray)
                    line.setLineDash([4, 3], count: 2, phase: 0); line.lineWidth = 0.8; line.stroke()
                }
            }
        }
        if session.isMeasuring {
            for item in session.measureItems { if case .point(let p) = item { ring(project(SIMD3<Float>(p)), filled: true, size: 10) } }
            let result = session.measurements
            if let from = result.from, let to = result.to {
                let a = project(SIMD3<Float>(from)), b = project(SIMD3<Float>(to))
                let line = UIBezierPath(); line.move(to: a); line.addLine(to: b)
                line.setLineDash([6, 4], count: 2, phase: 0); line.lineWidth = 1.6
                blue.setStroke(); line.stroke()
                ring(a, filled: false, size: 7); ring(b, filled: false, size: 7)
                if let distance = result.values.first(where: { $0.kind == .distance }) {
                    drawPill(session.measureText(distance), at: CGPoint(x: (a.x + b.x) / 2 + 10, y: (a.y + b.y) / 2 - 34), color: .label)
                }
            }
        }
    }

    /// A Move/Rotate (or Pattern) widget: arcs and arrows in the axis colors, the dragged one
    /// thicker, and its center dot (with the places it can snap while it is dragged).
    private func drawGizmo(_ widget: TransformWidget, active: TransformHandle?, draggingCenter: Bool, snaps: [TransformPivot]) {
        for arc in widget.arcs {
            let path = UIBezierPath()
            arc.points.enumerated().forEach { $0.offset == 0 ? path.move(to: $0.element) : path.addLine(to: $0.element) }
            strokeAxis(path, axis: arc.axis, width: active == .rotate(arc.axis) ? 4 : 2.5)
        }
        for arrow in widget.arrows {
            let path = UIBezierPath()
            path.move(to: arrow.base); path.addLine(to: arrow.tip)
            let d = arrow.direction, n = CGVector(dx: -d.dy, dy: d.dx)
            let back = CGPoint(x: arrow.tip.x - d.dx * 11, y: arrow.tip.y - d.dy * 11)
            path.move(to: CGPoint(x: back.x + n.dx * 6, y: back.y + n.dy * 6)); path.addLine(to: arrow.tip)
            path.addLine(to: CGPoint(x: back.x - n.dx * 6, y: back.y - n.dy * 6))
            strokeAxis(path, axis: arrow.axis, width: active == .move(arrow.axis) ? 4 : 2.5)
        }
        if draggingCenter {
            // Where the center can snap: small blue-ringed dots, like Align's points.
            for snap in snaps {
                let p = project(SIMD3<Float>(snap.point))
                let mark = UIBezierPath(ovalIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                UIColor.white.setFill(); mark.fill()
                blue.setStroke(); mark.lineWidth = 1.5; mark.stroke()
            }
            if !session.snapLabel.isEmpty {
                drawPill(session.snapLabel, at: CGPoint(x: widget.center.x + 14, y: widget.center.y + 12), color: .secondaryLabel)
            }
        }
        // A solid's center is a larger handle that can be dragged onto the solid.
        let radius: CGFloat = widget.canPivot ? 6 : 4
        let dot = UIBezierPath(ovalIn: CGRect(x: widget.center.x - radius, y: widget.center.y - radius, width: radius * 2, height: radius * 2))
        (draggingCenter ? blue : UIColor.white).setFill(); dot.fill()
        WorldAxis.casing.setStroke(); dot.lineWidth = 1.5; dot.stroke()
    }

    /// Widget strokes in the axis colors (sketch x Coral, y Lime cased in Graphite, normal Violet).
    private func strokeAxis(_ path: UIBezierPath, axis: Int, width: CGFloat) {
        let style = WorldAxis.allCases[axis]
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        if style.isCased { WorldAxis.casing.setStroke(); path.lineWidth = width + 2; path.stroke() }
        style.color.setStroke(); path.lineWidth = width; path.stroke()
    }

    private func drawPill(_ text: String, at point: CGPoint, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: max(110, min(view.bounds.width - size.width - 24, point.x)), y: max(90, min(view.bounds.height - 120, point.y)))
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 16, height: 28)
        UIColor.white.withAlphaComponent(0.94).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: origin.x + 8, y: origin.y + 6), withAttributes: attributes)
    }
}

extension CanvasController: SCNSceneRendererDelegate {
    /// Records the camera of each frame as SceneKit draws it (on its render thread), for `screenCamera`.
    nonisolated func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let node = renderer.pointOfView?.presentation, let scale = node.camera?.orthographicScale else { return }
        let m = node.simdWorldTransform
        func axis(_ c: SIMD4<Float>) -> SIMD3<Double> { simd_normalize(SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))) }
        // The camera looks along −z; +z points back toward the viewer.
        let camera = ScreenCamera(origin: SIMD3<Double>(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z)),
                                  right: axis(m.columns.0), up: axis(m.columns.1), direction: axis(m.columns.2), height: scale * 2)
        Task { @MainActor [weak self] in self?.cameraRendered(camera) }
    }
}

@MainActor final class PencilInputView: UIView {
    weak var controller: CanvasController?
    private var activeTouch: UITouch?
    private var dimensionButtons: [DimensionTarget: DimensionValueButton] = [:]
    var pencilActive: Bool { activeTouch != nil }
    init(controller: CanvasController) { self.controller = controller; super.init(frame: .zero); isOpaque = false; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func dimensionButton(for target: DimensionTarget) -> DimensionValueButton? { dimensionButtons[target] }

    func updateDimensions(_ annotations: [CanvasDimension]) {
        let targets = Set(annotations.map(\.target))
        for target in Array(dimensionButtons.keys) where !targets.contains(target) {
            dimensionButtons.removeValue(forKey: target)?.removeFromSuperview()
        }
        for annotation in annotations {
            let button: DimensionValueButton
            if let existing = dimensionButtons[annotation.target] { button = existing }
            else {
                button = DimensionValueButton(type: .custom)
                dimensionButtons[annotation.target] = button
                button.addAction(UIAction { [weak self] _ in
                    // Palm guard: a touch on a label while the Pencil drags (the value sits past the arrow) is a palm.
                    guard let self, !self.pencilActive else { return }
                    self.controller?.session.openDimension(annotation.target, at: self.dimensionButtons[annotation.target]?.center ?? annotation.center)
                }, for: .touchUpInside)
                addSubview(button)
            }
            button.setTitle(annotation.text, for: .normal)
            button.isEnabled = controller?.session.canEditDimension(annotation.target) == true
            button.titleLabel?.font = annotation.font
            let active = controller?.session.dimensionEdit?.target == annotation.target
            let misfit = annotation.target.isOperationValue && (controller?.session.finishError != nil || controller?.session.draftError != nil)
            button.setTitleColor(misfit ? .systemRed : active ? .systemBlue : .black, for: .normal)
            button.backgroundColor = annotation.target.isOperationValue ? .white : UIColor(white: 0.94, alpha: 1)
            button.layer.cornerRadius = annotation.target.isOperationValue ? 7 : 5
            button.layer.borderWidth = annotation.target.isOperationValue ? 2 : active ? 1 : 0
            button.layer.borderColor = (misfit ? UIColor.systemRed : UIColor(red: 0.12, green: 0.29, blue: 1, alpha: 1)).cgColor
            button.accessibilityIdentifier = "dimension.\(annotation.target.accessibilityName)"
            button.accessibilityLabel = "\(annotation.target.title), \(annotation.text)"
            button.accessibilityValue = formatted(annotation.value)
            button.bounds = CGRect(origin: .zero, size: annotation.labelSize)
            button.transform = CGAffineTransform(rotationAngle: annotation.angle)
            button.center = CGPoint(x: max(28, min(bounds.width - 32, annotation.center.x)), y: max(142, min(bounds.height - 62, annotation.center.y)))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .direct }) { controller?.closeDimensionEdit() }
        guard activeTouch == nil, let touch = touches.first(where: { $0.type == .pencil }) else { return }
        activeTouch = touch
        controller?.pencilBegan(at: touch.preciseLocation(in: self))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        controller?.pencilMoved(to: touch.preciseLocation(in: self))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        controller?.pencilEnded(at: touch.preciseLocation(in: self), cancelled: cancelled)
        activeTouch = nil
    }
    override func draw(_ rect: CGRect) { controller?.drawOverlay(in: rect) }
}

@MainActor final class DimensionValueButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -6, dy: -10).contains(point)
    }
}
