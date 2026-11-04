import SwiftUI

/// The dock and wheel share their roots, names, identifiers, and commands. A selection never
/// rearranges the wheel. Only entering or leaving a sketch changes the first ring.
enum ToolbarEntry: Identifiable, Equatable {
    case sketch, finishSketch, tool(ModelingTool), group(ToolGroup), primitives

    var id: String {
        switch self {
        case .sketch: "tool.sketch"
        case .finishSketch: "sketch.exit"
        case .tool(let tool): "tool.\(tool.rawValue)"
        case .group(let group): "tool.\(group.rawValue)"
        case .primitives: "tool.primitives"
        }
    }
    var title: String {
        switch self {
        case .sketch: "Sketch"
        case .finishSketch: "Finish Sketch"
        case .tool(let tool): tool == .split ? "Split Body" : tool == .peg ? "Peg & Socket" : tool.title
        case .group(let group): group.title
        case .primitives: "Primitives"
        }
    }
    var icon: SSIcon {
        switch self {
        case .sketch: .sketch
        case .finishSketch: .done
        case .tool(let tool): tool.icon
        case .group(let group): group.icon
        case .primitives: .primitives
        }
    }
    static let primitiveTools: [ModelingTool] = [.box, .cylinder, .sphere, .torus]
    static func roots(sketching: Bool, onFace: Bool) -> [Self] {
        if sketching {
            return [.finishSketch, .tool(.line), .tool(.rectangle), .group(.curves)]
                + (onFace ? [.group(.faceFeatures)] : [])
                + [.group(.modify), .tool(.dimension), .tool(.project)]
        }
        return [.sketch, .tool(.project), .group(.planes), .group(.create), .group(.edges),
                .group(.combine), .group(.transform), .group(.fit)]
    }
    static func children(of group: ToolGroup) -> [Self] {
        group == .create ? group.tools.filter { !primitiveTools.contains($0) }.map(Self.tool) + [.primitives]
            : group.tools.map(Self.tool)
    }
}

/// All dimensions are screen points. Do not scale targets down to fit a third ring: in a small
/// window Primitives replaces ring two, with a Back sector to return to Create.
struct RadialToolbarLayout {
    static let hubRadius: CGFloat = 48
    static func innerRadius(_ level: Int) -> CGFloat { level == 0 ? 54 : 142 + CGFloat(level - 1) * 70 }
    static func outerRadius(_ level: Int) -> CGFloat { innerRadius(level) + (level == 0 ? 82 : 64) }
    static func angle(index: Int, count: Int) -> Double { -.pi / 2 + Double(index) * 2 * .pi / Double(max(1, count)) }
    static func point(index: Int, count: Int, level: Int) -> CGPoint {
        let angle = angle(index: index, count: count)
        let radius = (innerRadius(level) + outerRadius(level)) / 2
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }
    static func fits(levels: Int, in bounds: CGRect) -> Bool {
        min(bounds.width, bounds.height) >= 2 * outerRadius(levels - 1)
    }
    static func clamp(_ point: CGPoint, radius: CGFloat, in bounds: CGRect) -> CGPoint {
        let x = bounds.width < radius * 2 ? bounds.midX : min(max(point.x, bounds.minX + radius), bounds.maxX - radius)
        let y = bounds.height < radius * 2 ? bounds.midY : min(max(point.y, bounds.minY + radius), bounds.maxY - radius)
        return CGPoint(x: x, y: y)
    }
}

/// Upright captions need to fit the curved sector, not just a rectangular tile. Measure every
/// visible component, then choose wrapping and a nearby position with clearance on all sides.
@MainActor struct RadialToolbarCaptionLayout {
    private struct Key: Hashable {
        let title: String
        let subtitle: String?
        let index: Int
        let count: Int
        let level: Int
    }
    private static var cache: [Key: Self] = [:]
    let title: String
    let fontSize: CGFloat
    let icon: CGRect
    let titleFrame: CGRect
    let subtitleFrame: CGRect?
    let fits: Bool

    var visibleFrames: [CGRect] { [icon, titleFrame] + [subtitleFrame].compactMap { $0 } }
    var bounds: CGRect {
        let box = visibleFrames.dropFirst().reduce(icon) { $0.union($1) }.insetBy(dx: -2, dy: -2)
        return CGRect(x: box.midX - max(44, box.width) / 2, y: box.midY - max(44, box.height) / 2,
                      width: max(44, box.width), height: max(44, box.height))
    }

    static func contains(_ rect: CGRect, index: Int, count: Int, level: Int) -> Bool {
        let inner = RadialToolbarLayout.innerRadius(level) + 3
        let outer = RadialToolbarLayout.outerRadius(level) - 3
        let nearX = min(max(0, rect.minX), rect.maxX), nearY = min(max(0, rect.minY), rect.maxY)
        guard hypot(nearX, nearY) >= inner else { return false }
        let angle = RadialToolbarLayout.angle(index: index, count: count)
        let half = Double.pi / Double(count) - 0.018
        for x in [rect.minX, rect.maxX] {
            for y in [rect.minY, rect.maxY] {
                guard hypot(x, y) <= outer else { return false }
                let along = x * cos(angle) + y * sin(angle), across = -x * sin(angle) + y * cos(angle)
                guard along * sin(half) - abs(across) * cos(half) >= 3 else { return false }
            }
        }
        return true
    }

    init(title: String, subtitle: String?, index: Int, count: Int, level: Int) {
        let key = Key(title: title, subtitle: subtitle, index: index, count: count, level: level)
        if let cached = Self.cache[key] { self = cached; return }
        let point = RadialToolbarLayout.point(index: index, count: count, level: level)
        let words = title.split(separator: " ").map(String.init)
        var variants = [title]
        if words.count > 1 {
            for split in 1..<words.count {
                variants.append(words[..<split].joined(separator: " ") + "\n" + words[split...].joined(separator: " "))
            }
        }
        func measured(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGSize {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            let lines = text.components(separatedBy: "\n")
            return CGSize(width: ceil(lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 2,
                          height: ceil(font.lineHeight * CGFloat(lines.count)))
        }
        let subtitleSize = subtitle.map { measured($0, size: 8, weight: .medium) }
        var best: RadialToolbarCaptionLayout?
        var bestCost = CGFloat.infinity
        // Preserve the normal type size whenever possible. A 10-point fallback is only used
        // if no two-line arrangement at 11 points can fit, including compact first-ring groups.
        for size: CGFloat in [11, 10] {
            for variant in variants {
                let titleSize = measured(variant, size: size, weight: .semibold)
                let height = 24 + 3 + titleSize.height + (subtitleSize.map { 3 + $0.height } ?? 0)
                for dx in stride(from: -24, through: 24, by: 2) {
                    for dy in stride(from: -24, through: 24, by: 2) {
                        let center = CGPoint(x: point.x + CGFloat(dx), y: point.y + CGFloat(dy))
                        let top = center.y - height / 2
                        let icon = CGRect(x: center.x - 12, y: top, width: 24, height: 24)
                        let text = CGRect(x: center.x - titleSize.width / 2, y: top + 27, width: titleSize.width, height: titleSize.height)
                        let detail = subtitleSize.map { CGRect(x: center.x - $0.width / 2, y: text.maxY + 3, width: $0.width, height: $0.height) }
                        let candidate = Self(title: variant, fontSize: size, icon: icon, titleFrame: text, subtitleFrame: detail, fits: true)
                        let cost = (11 - size) * 10000 + CGFloat(variant.filter { $0 == "\n" }.count) * 100 + CGFloat(dx * dx + dy * dy)
                        if cost < bestCost && candidate.visibleFrames.allSatisfy({ Self.contains($0, index: index, count: count, level: level) }) {
                            best = candidate; bestCost = cost
                        }
                    }
                }
            }
            if best != nil { break }
        }
        // Retain a visible caption for future commands; exhaustive catalog tests flag a title
        // that needs a new layout rather than silently clipping or omitting its text.
        self = best ?? Self(title: title, fontSize: 11,
                            icon: CGRect(x: point.x - 12, y: point.y - 24, width: 24, height: 24),
                            titleFrame: CGRect(x: point.x - 38, y: point.y + 3, width: 76, height: 28), subtitleFrame: nil, fits: false)
        Self.cache[key] = self
    }
    private init(title: String, fontSize: CGFloat, icon: CGRect, titleFrame: CGRect, subtitleFrame: CGRect?, fits: Bool) {
        self.title = title; self.fontSize = fontSize; self.icon = icon
        self.titleFrame = titleFrame; self.subtitleFrame = subtitleFrame; self.fits = fits
    }
}

private struct RadialToolbarCaption: View {
    let layout: RadialToolbarCaptionLayout
    let entry: ToolbarEntry
    let subtitle: String?
    let active: Bool
    var body: some View {
        let bounds = layout.bounds
        ZStack(alignment: .topLeading) {
            SSIconGlyph(icon: entry.icon, size: 24, color: active ? Color("ss-violet") : Color("ss-ink"))
                .position(x: layout.icon.midX - bounds.minX, y: layout.icon.midY - bounds.minY)
            Text(layout.title).font(.system(size: layout.fontSize, weight: .semibold))
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(width: layout.titleFrame.width, height: layout.titleFrame.height)
                .position(x: layout.titleFrame.midX - bounds.minX, y: layout.titleFrame.midY - bounds.minY)
            if let subtitle, let detail = layout.subtitleFrame {
                Text(subtitle).font(.system(size: 8, weight: .medium)).foregroundStyle(Color("ss-muted"))
                    .frame(width: detail.width, height: detail.height)
                    .position(x: detail.midX - bounds.minX, y: detail.midY - bounds.minY)
            }
        }
        .foregroundStyle(Color("ss-ink")).frame(width: bounds.width, height: bounds.height)
    }
}

private struct ToolbarSector: Shape {
    let inner: CGFloat
    let outer: CGFloat
    let angle: Double
    let sweep: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // A small seam separates sectors without reducing their usable target to the icon alone.
        let gap = 0.018
        let start = angle - sweep / 2 + gap, end = angle + sweep / 2 - gap
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct ToolbarCaptionTarget: Shape {
    let sector: ToolbarSector
    let offset: CGPoint
    func path(in rect: CGRect) -> Path {
        sector.path(in: rect).offsetBy(dx: -offset.x, dy: -offset.y).intersection(Path(rect))
    }
}

struct RadialToolbar: View {
    @ObservedObject var session: ModelingSession
    let sketching: Bool
    let bounds: CGRect
    let requestedCenter: CGPoint?
    let onMove: (CGPoint) -> Void
    let onEntry: (ToolbarEntry) -> Void
    let onClose: () -> Void
    @State private var expanded: ToolGroup?
    @State private var primitives = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var roots: [ToolbarEntry] { ToolbarEntry.roots(sketching: sketching, onFace: session.sketchMode?.face != nil) }
    private var twoRings: Bool { RadialToolbarLayout.fits(levels: 2, in: bounds) }
    private var threeRings: Bool { RadialToolbarLayout.fits(levels: 3, in: bounds) }
    private var levels: Int { expanded == nil || !twoRings ? 1 : primitives && threeRings ? 3 : 2 }
    private var radius: CGFloat { RadialToolbarLayout.outerRadius(levels - 1) }
    private var restingCenter: CGPoint {
        let preferred = requestedCenter ?? CGPoint(x: bounds.maxX - RadialToolbarLayout.outerRadius(0), y: bounds.maxY - RadialToolbarLayout.outerRadius(0))
        return RadialToolbarLayout.clamp(preferred, radius: radius, in: bounds)
    }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }

    var body: some View {
        RadialToolbarPlacement(center: restingCenter, radius: radius, bounds: bounds, onMove: onMove) {
            wheel
        }
        .allowsHitTesting(!session.isPencilDown)
        .onChange(of: sketching) { expanded = nil; primitives = false }
        .onChange(of: session.sketchMode?.face != nil) { _, onFace in
            if !onFace && expanded == .faceFeatures { expanded = nil; primitives = false }
        }
    }

    private var wheel: some View {
        ZStack {
            // Only the wheel is opaque and interactive. There is no full-screen dismiss layer.
            Circle().fill(Color("ss-white"))
                .overlay(Circle().stroke(Color("ss-border"), lineWidth: 1))
                .shadow(color: Color("ss-ink").opacity(0.18), radius: 18, y: 6)
            if twoRings || expanded == nil { ring(roots, level: 0) }
            if let expanded {
                if primitives && !threeRings {
                    ring([.primitives] + ToolbarEntry.primitiveTools.map(ToolbarEntry.tool), level: twoRings ? 1 : 0, compactPrimitives: true)
                } else {
                    ring(ToolbarEntry.children(of: expanded), level: twoRings ? 1 : 0)
                }
            }
            if primitives && threeRings {
                ring(ToolbarEntry.primitiveTools.map(ToolbarEntry.tool), level: 2)
            }
            hub
        }
        .frame(width: radius * 2, height: radius * 2)
        .accessibilityElement(children: .contain).accessibilityIdentifier("radial.toolbar")
    }

    private func selected(_ entry: ToolbarEntry) -> Bool {
        switch entry {
        case .tool(let tool): session.tool == tool
        case .group(let group): expanded == group || group.tools.contains(session.tool)
        case .primitives: primitives || ToolbarEntry.primitiveTools.contains(session.tool)
        case .finishSketch: true
        default: false
        }
    }
    private func subtitle(_ entry: ToolbarEntry, compactPrimitives: Bool) -> String? {
        switch entry {
        case .group: "Tools"
        case .primitives: compactPrimitives ? "Back to Create" : "Solids"
        case .tool(.rectangle): session.rectangleFromCenter ? "Center" : "Corners"
        default: nil
        }
    }
    private func activate(_ entry: ToolbarEntry) {
        withAnimation(animation) {
            switch entry {
            case .group(let group): expanded = expanded == group ? nil : group; primitives = false
            case .primitives: primitives.toggle()
            default: onEntry(entry)
            }
        }
    }

    private func ring(_ entries: [ToolbarEntry], level: Int, compactPrimitives: Bool = false) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            let active = selected(entry)
            let shape = ToolbarSector(inner: RadialToolbarLayout.innerRadius(level), outer: RadialToolbarLayout.outerRadius(level),
                                      angle: RadialToolbarLayout.angle(index: index, count: entries.count), sweep: 2 * .pi / Double(entries.count))
            let detail = subtitle(entry, compactPrimitives: compactPrimitives)
            let caption = RadialToolbarCaptionLayout(title: compactPrimitives && entry == .primitives ? "Back" : entry.title,
                                                     subtitle: detail, index: index, count: entries.count, level: level)
            let point = CGPoint(x: caption.bounds.midX, y: caption.bounds.midY)
            shape.fill(active ? Color("ss-lavender") : Color("ss-white"))
                .overlay(shape.stroke(Color("ss-border").opacity(0.65), lineWidth: 0.7))
                .contentShape(shape).onTapGesture { activate(entry) }.accessibilityHidden(true)
            // A separate, conventionally sized accessible button keeps VoiceOver's focus and
            // activation point on the caption rather than the wheel's enclosing rectangle.
            Button { activate(entry) } label: {
                RadialToolbarCaption(layout: caption, entry: entry, subtitle: detail, active: active)
                    .contentShape(ToolbarCaptionTarget(sector: shape, offset: point))
            }
            .buttonStyle(.plain).position(x: radius + point.x, y: radius + point.y)
            .accessibilityLabel(entry.title)
            .accessibilityValue(subtitle(entry, compactPrimitives: compactPrimitives) ?? "")
            .accessibilityIdentifier(entry.id).accessibilityAddTraits(active ? .isSelected : [])
        }
    }

    private var hub: some View {
        Button {
            withAnimation(animation) {
                if primitives { primitives = false }
                else if expanded != nil { expanded = nil }
                else { onClose() }
            }
        } label: {
            VStack(spacing: 4) {
                SSIconGlyph(icon: expanded == nil ? .brand : .exit, size: 23, color: Color("ss-paper"))
                Text(expanded?.title ?? (sketching ? "Sketch" : "Tools")).font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Color("ss-paper")).frame(width: 96, height: 96)
            .background(Color("ss-violet"), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("radial.move")
        .accessibilityLabel("\(expanded?.title ?? "Tools"). Drag to move toolbar")
        .accessibilityHint(expanded == nil ? "Tap to hide. Drag to reposition." : "Tap to go back. Drag to reposition.")
        .accessibilityAction(named: "Move left") { moveBy(x: -60, y: 0) }
        .accessibilityAction(named: "Move right") { moveBy(x: 60, y: 0) }
        .accessibilityAction(named: "Move up") { moveBy(x: 0, y: -60) }
        .accessibilityAction(named: "Move down") { moveBy(x: 0, y: 60) }
    }
    private func moveBy(x: CGFloat, y: CGFloat) {
        onMove(RadialToolbarLayout.clamp(CGPoint(x: restingCenter.x + x, y: restingCenter.y + y), radius: radius, in: bounds))
    }
}


/// Gesture tracking lives outside SwiftUI. Moving the menu only changes its hosted view's
/// center; it does not rebuild the rings or refresh the modeling canvas for every input sample.
private struct RadialToolbarPlacement<Content: View>: UIViewControllerRepresentable {
    let center: CGPoint
    let radius: CGFloat
    let bounds: CGRect
    let onMove: (CGPoint) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> RadialToolbarPlacementController<Content> {
        RadialToolbarPlacementController(content: content())
    }
    func updateUIViewController(_ controller: RadialToolbarPlacementController<Content>, context: Context) {
        controller.update(content: content(), center: center, radius: radius, bounds: bounds, onMove: onMove)
    }
}

@MainActor final class RadialToolbarPlacementController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    let hosting: UIHostingController<Content>
    private var radius: CGFloat = 0
    private var allowedBounds = CGRect.zero
    private var restingCenter = CGPoint.zero
    private var moveOrigin: CGPoint?
    private var touchOrigin: CGPoint?
    private var onMove: ((CGPoint) -> Void)?

    init(content: Content) {
        hosting = UIHostingController(rootView: content)
        hosting.safeAreaRegions = []
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view = RadialToolbarHitView()
        view.backgroundColor = .clear
        view.isOpaque = false
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        (view as? RadialToolbarHitView)?.wheel = hosting.view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHubPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pan.delaysTouchesBegan = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }
    func update(content: Content, center: CGPoint, radius: CGFloat, bounds: CGRect, onMove: @escaping (CGPoint) -> Void) {
        loadViewIfNeeded()
        // Rotation or ring expansion can invalidate the current gesture's constraints.
        if radius != self.radius || bounds != allowedBounds { endMove(cancelled: true) }
        hosting.rootView = content
        self.radius = radius
        allowedBounds = bounds
        restingCenter = center
        self.onMove = onMove
        hosting.view.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        if moveOrigin == nil { hosting.view.center = center }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: view)
        guard hypot(point.x - hosting.view.center.x, point.y - hosting.view.center.y) <= RadialToolbarLayout.hubRadius else { return false }
        touchOrigin = point
        return true
    }
    @objc private func handleHubPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: view)
        // Include the distance travelled before UIKit recognizes the pan, so the wheel stays
        // anchored to the original touch rather than trailing by the recognition threshold.
        let translation = touchOrigin.map { CGPoint(x: location.x - $0.x, y: location.y - $0.y) } ?? gesture.translation(in: view)
        switch gesture.state {
        case .began: beginMove(); updateMove(translation: translation)
        case .changed: updateMove(translation: translation)
        case .ended: updateMove(translation: translation); endMove(cancelled: false)
        case .cancelled, .failed: endMove(cancelled: true)
        default: break
        }
    }
    func beginMove() { moveOrigin = hosting.view.center }
    func updateMove(translation: CGPoint) {
        guard let moveOrigin else { return }
        // No animations, SwiftUI state changes, document edits, or preference writes while moving.
        hosting.view.center = RadialToolbarLayout.clamp(CGPoint(x: moveOrigin.x + translation.x, y: moveOrigin.y + translation.y), radius: radius, in: allowedBounds)
    }
    func endMove(cancelled: Bool) {
        touchOrigin = nil
        guard let moveOrigin else { return }
        self.moveOrigin = nil
        if cancelled { hosting.view.center = moveOrigin }
        else {
            restingCenter = hosting.view.center
            onMove?(restingCenter)
        }
    }
}

/// The placement container fills the workspace, but only the visible circle consumes input.
@MainActor private final class RadialToolbarHitView: UIView {
    weak var wheel: UIView?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let wheel else { return false }
        return hypot(point.x - wheel.center.x, point.y - wheel.center.y) <= wheel.bounds.width / 2
    }
}
