import SwiftUI
import simd

enum ViewCubeFace: String, CaseIterable {
    case top, bottom, front, back, right, left
    var title: String { rawValue.capitalized }
    var normal: SIMD3<Double> {
        switch self {
        case .top: .init(0, 0, 1)
        case .bottom: .init(0, 0, -1)
        case .front: .init(0, -1, 0)
        case .back: .init(0, 1, 0)
        case .right: .init(1, 0, 0)
        case .left: .init(-1, 0, 0)
        }
    }
    var up: SIMD3<Double> {
        switch self { case .top: .init(0, 1, 0); case .bottom: .init(0, -1, 0); default: .init(0, 0, 1) }
    }
    var right: SIMD3<Double> { simd_cross(up, normal) }
    /// The world axis this face looks along; the face takes that axis's color.
    var axis: WorldAxis {
        switch self { case .right, .left: .x; case .front, .back: .y; case .top, .bottom: .z }
    }
    var sketchPlane: SketchPlane {
        switch self { case .top, .bottom: .top; case .front, .back: .front; case .right, .left: .right }
    }
    /// The cube face looking straight at `plane`, if its normal is a world axis.
    static func facing(_ plane: SketchPlane) -> Self? {
        allCases.first { simd_dot($0.normal, plane.normalAxis) > 0.9999 }
    }
}

struct ViewOrientation: Equatable {
    var right: SIMD3<Double>
    var up: SIMD3<Double>
    var direction: SIMD3<Double>

    init(direction: SIMD3<Double>, up: SIMD3<Double>) {
        self.direction = simd_normalize(direction)
        right = simd_normalize(simd_cross(up, self.direction))
        self.up = simd_normalize(simd_cross(self.direction, right))
    }
    init(rotation: simd_quatf) {
        let matrix = simd_float3x3(rotation)
        right = SIMD3(Double(matrix.columns.0.x), Double(matrix.columns.0.y), Double(matrix.columns.0.z))
        up = SIMD3(Double(matrix.columns.1.x), Double(matrix.columns.1.y), Double(matrix.columns.1.z))
        direction = SIMD3(Double(matrix.columns.2.x), Double(matrix.columns.2.y), Double(matrix.columns.2.z))
    }
    var rotation: simd_quatf {
        simd_quatf(simd_float3x3(columns: (SIMD3(Float(right.x), Float(right.y), Float(right.z)),
                                             SIMD3(Float(up.x), Float(up.y), Float(up.z)),
                                             SIMD3(Float(direction.x), Float(direction.y), Float(direction.z)))))
    }
    var face: ViewCubeFace? { ViewCubeFace.allCases.first { simd_dot($0.normal, direction) > 0.9999 } }
}

// The cube receives camera frames directly, avoiding a SwiftUI workspace refresh on every orbit frame.
@MainActor final class ViewCubeState {
    private(set) var orientation = ViewOrientation(direction: ViewCubeFace.top.normal, up: ViewCubeFace.top.up)
    weak var view: ViewCubeView?
    var pencilActive = false
    func update(_ orientation: ViewOrientation) {
        self.orientation = orientation
        view?.orientation = orientation
    }
}

struct ViewCube: UIViewRepresentable {
    let session: ModelingSession
    func makeUIView(context: Context) -> ViewCubeView { ViewCubeView(session: session) }
    func updateUIView(_ view: ViewCubeView, context: Context) { view.orientation = session.viewCube.orientation }
}

@MainActor final class ViewCubeView: UIView {
    weak var state: ViewCubeState?
    var onFace: ((ViewCubeFace) -> Void)?
    var onReset: (() -> Void)?
    var orientation = ViewOrientation(direction: ViewCubeFace.top.normal, up: ViewCubeFace.top.up) {
        didSet { if orientation != oldValue { updateLayers(); updateAccessibility() } }
    }
    private(set) var singleTap: UITapGestureRecognizer!
    private(set) var doubleTap: UITapGestureRecognizer!
    private var scale: Double { Double(min(bounds.width, bounds.height)) * 0.22 }
    private var centerPoint: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    var visibleFaces: [ViewCubeFace] { ViewCubeFace.allCases.filter { simd_dot($0.normal, orientation.direction) > 0.001 } }

    convenience init(session: ModelingSession) {
        self.init(frame: .zero)
        state = session.viewCube
        session.viewCube.view = self
        orientation = session.viewCube.orientation
        onFace = { [weak session] face in
            session?.chooseCubeFace(face)
        }
        onReset = { [weak session] in
            guard let session, !session.viewCube.pencilActive else { return }
            session.dimensionEdit = nil
            session.requestCamera(.reset)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        makeLayers()
        // The body's soft shadow is the layer's, drawn by Core Animation from `shadowPath`: blurring it
        // in `draw` on every camera change took about 0.1 s of each 20 s orbit on the iPad (November 9, 2026).
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityIdentifier = "view.cube"
        accessibilityLabel = "View cube"
        shouldGroupAccessibilityChildren = true
        singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetView))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        for gesture in [singleTap!, doubleTap!] {
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue, UITouch.TouchType.pencil.rawValue].map(NSNumber.init(value:))
            addGestureRecognizer(gesture)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    /// Laid out again only for a new size (or screen scale): moving the cube's layers asks UIKit for
    /// a layout pass, which redid every layer a second time on each camera frame.
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale
        guard bounds.size != laidOut.size || scale != laidOut.scale else { return }
        laidOut = (bounds.size, scale)
        updateAccessibility(); updateLayers()
    }
    private var laidOut: (size: CGSize, scale: CGFloat) = (.zero, 0)

    /// The visible faces together, the cube's body outline.
    private var bodyPath: UIBezierPath {
        let body = UIBezierPath()
        for face in visibleFaces { body.append(facePath(face)) }
        body.lineJoinStyle = .round; body.lineWidth = 4
        return body
    }

    func project(_ point: SIMD3<Double>) -> CGPoint {
        CGPoint(x: centerPoint.x + simd_dot(point, orientation.right) * scale,
                y: centerPoint.y - simd_dot(point, orientation.up) * scale)
    }
    func facePath(_ face: ViewCubeFace, inset: Double = 0) -> UIBezierPath {
        let path = UIBezierPath()
        let extent = 1 - inset
        let points = [(-extent, -extent), (extent, -extent), (extent, extent), (-extent, extent)]
        for (index, point) in points.enumerated() {
            let screen = project(face.normal + face.right * point.0 + face.up * point.1)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        path.close()
        return path
    }
    func face(at point: CGPoint) -> ViewCubeFace? { visibleFaces.first { facePath($0).contains(point) } }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard state?.pencilActive != true, let face = face(at: gesture.location(in: self)) else { return }
        onFace?(face)
    }
    @objc private func resetView() { guard state?.pencilActive != true else { return }; onReset?() }

    /// Maps a face's own square, -1...1 along its right and up, onto the screen.
    private func faceTransform(_ face: ViewCubeFace) -> CGAffineTransform {
        let origin = project(face.normal)
        let u = face.right, v = face.up
        return CGAffineTransform(a: simd_dot(u, orientation.right) * scale, b: -simd_dot(u, orientation.up) * scale,
                                 c: simd_dot(v, orientation.right) * scale, d: -simd_dot(v, orientation.up) * scale,
                                 tx: origin.x, ty: origin.y)
    }

    // MARK: Layers

    /// The cube is drawn as Core Animation layers rather than in `draw(_:)`: redrawing it with Core
    /// Graphics on every camera change was the largest main-thread cost of an orbit on the iPad
    /// (0.62 s in 25, November 10, 2026). A turn now only sets paths and transforms; the shapes are
    /// rendered by Core Animation and the labels are images made once.
    private struct AxisLayers { var casing: CAShapeLayer?; var line: CAShapeLayer; var label: CALayer }
    private struct FaceLayers { var tile: CAShapeLayer; var gloss: CAShapeLayer; var label: CALayer }
    private var axisLayers: [WorldAxis: AxisLayers] = [:]
    private var faceLayers: [ViewCubeFace: FaceLayers] = [:]
    private let bodyLayer = CAShapeLayer()
    /// The screen scale the label images were made for.
    private var labelScale: CGFloat = 0

    /// Back to front: the axes and the labels of those pointing away, the Graphite body, the tiles
    /// with their highlights and titles, then the labels of the axes pointing toward the viewer.
    private enum Depth {
        static let axis: CGFloat = 0, backLabel: CGFloat = 1, body: CGFloat = 2, tile: CGFloat = 3
        static let gloss: CGFloat = 4, title: CGFloat = 5, frontLabel: CGFloat = 6
    }

    private func makeLayers() {
        func stroke(_ color: UIColor, width: CGFloat) -> CAShapeLayer {
            let line = CAShapeLayer()
            line.fillColor = nil; line.strokeColor = color.cgColor; line.lineWidth = width; line.lineCap = .round
            line.zPosition = Depth.axis
            return line
        }
        for axis in WorldAxis.allCases {
            // The world axes run through the cube from its center, behind it so only their tips
            // show, in the canvas axes' colors (Lime over a Graphite casing).
            let casing = axis.isCased ? stroke(WorldAxis.casing, width: 3.5) : nil
            let parts = AxisLayers(casing: casing, line: stroke(axis.color, width: 2.2), label: CALayer())
            [parts.casing, parts.line, parts.label].compactMap { $0 }.forEach(layer.addSublayer)
            axisLayers[axis] = parts
        }
        // A Graphite body with rounded corners and a soft shadow (the view layer's), like the brand's outlined shapes.
        bodyLayer.fillColor = WorldAxis.casing.cgColor; bodyLayer.strokeColor = WorldAxis.casing.cgColor
        bodyLayer.lineWidth = 4; bodyLayer.lineJoin = .round
        bodyLayer.zPosition = Depth.body
        layer.addSublayer(bodyLayer)
        for face in ViewCubeFace.allCases {
            // Each face is a rounded tile in the color of its axis (X Coral, Y Lime, Z Violet), shaded
            // by a fixed light so the cube still reads as a solid while it turns.
            let light = max(0, simd_dot(face.normal, simd_normalize(SIMD3<Double>(-0.3, -0.4, 1))))
            let tile = CAShapeLayer()
            tile.fillColor = face.axis.color.shaded(by: CGFloat(1 - light) * 0.2).cgColor
            tile.zPosition = Depth.tile
            // A highlight along the tile's top edge gives it a little bevel.
            let gloss = CAShapeLayer()
            gloss.fillColor = UIColor.white.withAlphaComponent(face.axis == .z ? 0.3 : 0.5).cgColor
            gloss.zPosition = Depth.gloss
            let label = CALayer()
            label.zPosition = Depth.title
            [tile, gloss, label].forEach(layer.addSublayer)
            faceLayers[face] = FaceLayers(tile: tile, gloss: gloss, label: label)
        }
    }

    /// The labels as images, made again only when the screen scale changes.
    private func updateLabelImages() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        guard scale != labelScale else { return }
        labelScale = scale
        func show(_ title: (NSAttributedString, CGSize), in label: CALayer) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            // Whole pixels, with the text centered in them, so the image is shown unstretched.
            let size = CGSize(width: ceil(title.1.width * scale) / scale, height: ceil(title.1.height * scale) / scale)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                title.0.draw(at: CGPoint(x: (size.width - title.1.width) / 2, y: (size.height - title.1.height) / 2))
            }
            label.contents = image.cgImage
            label.contentsScale = scale
            label.bounds = CGRect(origin: .zero, size: size)
        }
        for (axis, parts) in axisLayers { show(Self.axisTitle(axis), in: parts.label) }
        for (face, parts) in faceLayers { show(Self.faceTitle(face), in: parts.label) }
    }

    /// Times the layers were set for the view (tests check a turn sets them once).
    private(set) var layerUpdates = 0

    private func updateLayers() {
        layerUpdates += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updateLabelImages()
        let body = bodyPath
        bodyLayer.path = body.cgPath
        // The body is stroked 4 points wide, so its shadow follows the stroke's outline.
        layer.shadowPath = body.cgPath.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10)
        for axis in WorldAxis.allCases {
            guard let parts = axisLayers[axis] else { continue }
            let direction = SIMD3<Double>(axis.direction)
            let end = project(direction * 1.9)
            // Seen end on, an axis is only a dot under the cube: left out, with its label.
            let shown = hypot(end.x - centerPoint.x, end.y - centerPoint.y) >= 8
            let path = CGMutablePath(); path.move(to: centerPoint); path.addLine(to: end)
            for line in [parts.casing, parts.line].compactMap({ $0 }) { line.path = path; line.isHidden = !shown }
            // Letters stay Graphite (small Coral or Lime text is not legible); an axis pointing away
            // is labeled behind the cube, where it can cover the label.
            parts.label.isHidden = !shown
            parts.label.position = project(direction * 2.15)
            parts.label.zPosition = simd_dot(direction, orientation.direction) < 0 ? Depth.backLabel : Depth.frontLabel
        }
        let visible = Set(visibleFaces)
        for (face, parts) in faceLayers {
            let shown = visible.contains(face)
            [parts.tile, parts.gloss, parts.label].forEach { $0.isHidden = !shown }
            guard shown else { continue }
            let transform = faceTransform(face)
            for (shape, rect, radius) in [(parts.tile, CGRect(x: -0.87, y: -0.87, width: 1.74, height: 1.74), 0.32),
                                          (parts.gloss, CGRect(x: -0.55, y: 0.62, width: 1.1, height: 0.1), 0.05)] {
                let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
                path.apply(transform)
                shape.path = path.cgPath
            }
            // The title lies on the face, turned and foreshortened with it. Paper on Violet,
            // Graphite on Coral and Lime (the brand's checked text pairs).
            let u = face.right, v = -face.up
            parts.label.position = project(face.normal)
            parts.label.setAffineTransform(CGAffineTransform(a: simd_dot(u, orientation.right), b: -simd_dot(u, orientation.up),
                                                             c: simd_dot(v, orientation.right), d: -simd_dot(v, orientation.up), tx: 0, ty: 0))
        }
    }

    /// The labels, set once with their sizes (they never change) instead of on every redraw.
    private static var faceTitles: [ViewCubeFace: (NSAttributedString, CGSize)] = [:]
    private static var axisTitles: [WorldAxis: (NSAttributedString, CGSize)] = [:]
    private static func faceTitle(_ face: ViewCubeFace) -> (NSAttributedString, CGSize) {
        if let title = faceTitles[face] { return title }
        let text = face.axis == .z ? (UIColor(named: "ss-paper") ?? .white) : WorldAxis.casing
        let title = NSAttributedString(string: face.title, attributes: [.font: labelFont, .foregroundColor: text])
        faceTitles[face] = (title, title.size())
        return (title, title.size())
    }
    private static func axisTitle(_ axis: WorldAxis) -> (NSAttributedString, CGSize) {
        if let title = axisTitles[axis] { return title }
        let title = NSAttributedString(string: axis.rawValue.uppercased(), attributes: [.font: axisFont, .foregroundColor: WorldAxis.casing])
        axisTitles[axis] = (title, title.size())
        return (title, title.size())
    }

    private static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? font
    }
    private static let labelFont = rounded(11, .bold)
    private static let axisFont = rounded(10, .bold)

    /// One element per face, made once; a turn only moves them, and the list changes only when
    /// other faces come into view (they were all made again on every camera frame).
    private var faceElements: [ViewCubeFace: CubeFaceAccessibilityElement] = [:]
    private var listedFaces: [ViewCubeFace] = []

    private func updateAccessibility() {
        let value = orientation.face?.title ?? "3D"
        accessibilityValue = value
        let faces = visibleFaces
        for face in faces {
            let element = faceElements[face] ?? makeElement(face)
            element.accessibilityValue = value
            element.accessibilityFrameInContainerSpace = facePath(face).bounds
        }
        if faces != listedFaces {
            listedFaces = faces
            accessibilityElements = faces.compactMap { faceElements[$0] }
        }
    }

    private func makeElement(_ face: ViewCubeFace) -> CubeFaceAccessibilityElement {
        let element = CubeFaceAccessibilityElement(accessibilityContainer: self)
        element.accessibilityIdentifier = "view.cube.\(face.rawValue)"
        element.accessibilityLabel = "\(face.title) view"
        element.accessibilityHint = "Tap to face \(face.title.lowercased()). Double tap the cube to reset the 3D view."
        element.accessibilityTraits = .button
        element.accessibilityPath = nil
        element.onActivate = { [weak self] in
            guard let self, self.state?.pencilActive != true else { return false }
            self.onFace?(face); return true
        }
        faceElements[face] = element
        return element
    }
}

private extension UIColor {
    /// This color darkened toward black by `amount` (0...1).
    func shaded(by amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * (1 - amount), green: g * (1 - amount), blue: b * (1 - amount), alpha: a)
    }
}

@MainActor private final class CubeFaceAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { onActivate?() ?? false }
}
