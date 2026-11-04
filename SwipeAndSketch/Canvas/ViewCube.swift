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
        didSet { if orientation != oldValue { setNeedsDisplay(); updateAccessibility() } }
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
        contentMode = .redraw
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
    override func layoutSubviews() { super.layoutSubviews(); updateAccessibility(); setNeedsDisplay() }

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

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let faces = visibleFaces
        drawAxes()
        // A Graphite body with rounded corners and a soft shadow, like the brand's outlined shapes.
        let body = UIBezierPath()
        for face in faces { body.append(facePath(face)) }
        body.lineJoinStyle = .round; body.lineWidth = 4
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.2).cgColor)
        WorldAxis.casing.setFill(); WorldAxis.casing.setStroke(); body.fill(); body.stroke()
        context.restoreGState()
        // Each face is a rounded tile in the color of its axis (X Coral, Y Lime, Z Violet), shaded by a
        // fixed light so the cube still reads as a solid while it turns.
        for face in faces {
            let light = max(0, simd_dot(face.normal, simd_normalize(SIMD3<Double>(-0.3, -0.4, 1))))
            let tile = UIBezierPath(roundedRect: CGRect(x: -0.87, y: -0.87, width: 1.74, height: 1.74), cornerRadius: 0.32)
            tile.apply(faceTransform(face))
            face.axis.color.shaded(by: CGFloat(1 - light) * 0.2).setFill()
            tile.fill()
            // A highlight along the tile's top edge gives it a little bevel.
            let gloss = UIBezierPath(roundedRect: CGRect(x: -0.55, y: 0.62, width: 1.1, height: 0.1), cornerRadius: 0.05)
            gloss.apply(faceTransform(face))
            UIColor.white.withAlphaComponent(face.axis == .z ? 0.3 : 0.5).setFill()
            gloss.fill()
            let origin = project(face.normal)
            let u = face.right, v = -face.up
            context.saveGState()
            context.concatenate(CGAffineTransform(a: simd_dot(u, orientation.right), b: -simd_dot(u, orientation.up),
                                                 c: simd_dot(v, orientation.right), d: -simd_dot(v, orientation.up),
                                                 tx: origin.x, ty: origin.y))
            // Paper on Violet, Graphite on Coral and Lime (the brand's checked text pairs).
            let text = face.axis == .z ? (UIColor(named: "ss-paper") ?? .white) : WorldAxis.casing
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: text]
            let size = (face.title as NSString).size(withAttributes: attributes)
            (face.title as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
            context.restoreGState()
        }
        // Axes pointing toward the viewer label in front of the cube.
        for axis in WorldAxis.allCases where simd_dot(SIMD3<Double>(axis.direction), orientation.direction) >= 0 { drawAxisLabel(axis) }
    }

    /// The world axes run through the cube from its center, drawn behind it so only their tips show,
    /// in the canvas axes' colors.
    private func drawAxes() {
        for axis in WorldAxis.allCases {
            let direction = SIMD3<Double>(axis.direction)
            let end = project(direction * 1.9)
            if hypot(end.x - centerPoint.x, end.y - centerPoint.y) < 8 { continue }
            let path = UIBezierPath(); path.move(to: centerPoint); path.addLine(to: end)
            path.lineCapStyle = .round
            if axis.isCased { WorldAxis.casing.setStroke(); path.lineWidth = 3.5; path.stroke() }
            axis.color.setStroke(); path.lineWidth = 2.2; path.stroke()
            // Axes pointing away label behind the cube, where it can cover them.
            if simd_dot(direction, orientation.direction) < 0 { drawAxisLabel(axis) }
        }
    }

    /// Letters stay Graphite (small Coral or Lime text is not legible).
    private func drawAxisLabel(_ axis: WorldAxis) {
        let direction = SIMD3<Double>(axis.direction)
        if hypot(project(direction * 1.9).x - centerPoint.x, project(direction * 1.9).y - centerPoint.y) < 8 { return }
        let title = axis.rawValue.uppercased()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.axisFont, .foregroundColor: WorldAxis.casing]
        let size = (title as NSString).size(withAttributes: attributes)
        let point = project(direction * 2.15)
        (title as NSString).draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attributes)
    }

    private static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? font
    }
    private static let labelFont = rounded(11, .bold)
    private static let axisFont = rounded(10, .bold)

    private func updateAccessibility() {
        accessibilityValue = orientation.face?.title ?? "3D"
        accessibilityElements = visibleFaces.map { face in
            let element = CubeFaceAccessibilityElement(accessibilityContainer: self)
            element.accessibilityIdentifier = "view.cube.\(face.rawValue)"
            element.accessibilityLabel = "\(face.title) view"
            element.accessibilityHint = "Tap to face \(face.title.lowercased()). Double tap the cube to reset the 3D view."
            element.accessibilityTraits = .button
            element.accessibilityValue = orientation.face?.title ?? "3D"
            element.accessibilityFrameInContainerSpace = facePath(face).bounds
            element.accessibilityPath = nil
            element.onActivate = { [weak self] in
                guard let self, self.state?.pencilActive != true else { return false }
                self.onFace?(face); return true
            }
            return element
        }
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
