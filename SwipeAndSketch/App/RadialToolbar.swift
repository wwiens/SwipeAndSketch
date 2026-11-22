import SwiftUI

/// An interface preference only: both workspaces use the same document, commands, and input.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case essentials, allTools
    static let defaultsKey = "workspace.mode"
    static let tipsDefaultsKey = "workspace.showTips"
    var id: String { rawValue }
    var title: String { self == .essentials ? "Essentials" : "All Tools" }

    func tools(in group: ToolGroup) -> [ModelingTool] {
        guard self == .essentials else { return group.tools }
        switch group {
        case .create: return [.box, .cylinder, .sphere, .torus, .extrude]
        case .edges: return [.fillet, .chamfer, .shell]
        case .combine: return [.union, .subtract]
        case .transform: return [.align, .scale]
        case .curves: return [.circle, .arc, .slot]
        case .modify: return [.trim, .cornerFillet, .offset]
        case .faceFeatures: return [.hole, .text]
        case .planes, .fit: return []
        }
    }
}

/// The dock and wheel share their roots, names, identifiers, and commands. A selection never
/// rearranges the wheel. Sketching and the chosen workspace mode determine the first ring.
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
    /// Opens more tools rather than doing something.
    var opensTools: Bool {
        switch self {
        case .group, .primitives: true
        default: false
        }
    }
    static func roots(sketching: Bool, mode: WorkspaceMode = .allTools) -> [Self] {
        if sketching {
            // Features is there off a face too (dimmed, its tools explain they need a face), so
            // holes, pegs, and text can be found from any sketch (November 21, 2026).
            return [.finishSketch, .tool(.line), .tool(.rectangle), .group(.curves), .group(.faceFeatures),
                    .group(.modify), .tool(.dimension)] + (mode == .allTools ? [.tool(.project)] : [])
        }
        if mode == .essentials {
            return [.sketch, .group(.create), .group(.edges), .group(.combine), .group(.transform)]
        }
        return [.sketch, .tool(.project), .group(.planes), .group(.create), .group(.edges),
                .group(.combine), .group(.transform), .group(.fit)]
    }
    static func children(of group: ToolGroup, mode: WorkspaceMode = .allTools) -> [Self] {
        let tools = mode.tools(in: group)
        return group == .create && mode == .allTools ? tools.filter { !primitiveTools.contains($0) }.map(Self.tool) + [.primitives]
            : tools.map(Self.tool)
    }
}

/// One ring's sectors. The first ring goes all the way around; a group's tools open as an arc
/// beside the group instead (November 22, 2026), each tool the same width whatever the group's
/// size, so a tool is always found in the same direction from its group.
struct RadialArc: Equatable {
    let level: Int
    /// The leading edge of the first sector, clockwise on screen.
    let start: Double
    /// Each sector's sweep.
    let step: Double
    let count: Int
    var sweep: Double { step * Double(count) }
    var isFullRing: Bool { sweep >= 2 * .pi - 1e-6 }
    func angle(_ index: Int) -> Double { start + (Double(index) + 0.5) * step }
    func contains(angle: Double) -> Bool {
        if isFullRing { return true }
        let turn = 2 * Double.pi
        var offset = (angle - start).truncatingRemainder(dividingBy: turn)
        if offset < 0 { offset += turn }
        return offset <= sweep
    }
    /// A whole ring with its first sector at 12 o'clock.
    static func ring(count: Int, level: Int) -> Self {
        let step = 2 * Double.pi / Double(max(1, count))
        return Self(level: level, start: -.pi / 2 - step / 2, step: step, count: max(1, count))
    }
}

/// All dimensions are screen points. Do not scale targets down to fit a third ring: in a small
/// window Primitives replaces ring two, with a Back sector to return to Create.
struct RadialToolbarLayout {
    static let hubRadius: CGFloat = 48
    /// Outer rings are deep enough for a two-line caption at any angle, since an arc can open
    /// in any direction.
    static let ringDepth: CGFloat = 72
    static func innerRadius(_ level: Int) -> CGFloat { level == 0 ? 54 : 142 + CGFloat(level - 1) * (ringDepth + 6) }
    static func outerRadius(_ level: Int) -> CGFloat { innerRadius(level) + (level == 0 ? 82 : ringDepth) }
    static func middleRadius(_ level: Int) -> CGFloat { (innerRadius(level) + outerRadius(level)) / 2 }
    /// How wide each tool in an arc is, along the middle of its ring; it narrows to the minimum
    /// before the arc turns away from its group or the wheel moves.
    static let toolWidth: CGFloat = 120
    static let minimumToolWidth: CGFloat = 100
    /// The rounded white edge drawn around the wheel and its arcs.
    static let rim: CGFloat = 4
    static func angle(index: Int, count: Int) -> Double { -.pi / 2 + Double(index) * 2 * .pi / Double(max(1, count)) }
    static func point(index: Int, count: Int, level: Int) -> CGPoint { point(angle: angle(index: index, count: count), level: level) }
    static func point(angle: Double, level: Int) -> CGPoint {
        CGPoint(x: cos(angle) * middleRadius(level), y: sin(angle) * middleRadius(level))
    }
    static func fits(levels: Int, in bounds: CGRect) -> Bool {
        min(bounds.width, bounds.height) >= 2 * outerRadius(levels - 1)
    }
    static func clamp(_ point: CGPoint, radius: CGFloat, in bounds: CGRect) -> CGPoint {
        let x = bounds.width < radius * 2 ? bounds.midX : min(max(point.x, bounds.minX + radius), bounds.maxX - radius)
        let y = bounds.height < radius * 2 ? bounds.midY : min(max(point.y, bounds.minY + radius), bounds.maxY - radius)
        return CGPoint(x: x, y: y)
    }

    /// The rectangle an arc covers around the wheel's center, rim included.
    static func extent(of arc: RadialArc) -> CGRect {
        let outer = outerRadius(arc.level) + rim, inner = outerRadius(arc.level - 1)
        if arc.isFullRing { return CGRect(x: -outer, y: -outer, width: outer * 2, height: outer * 2) }
        var points: [CGPoint] = []
        let samples = max(2, Int(arc.sweep / 0.03))
        for sample in 0...samples {
            let angle = arc.start + arc.sweep * Double(sample) / Double(samples)
            points.append(CGPoint(x: cos(angle) * outer, y: sin(angle) * outer))
        }
        for angle in [arc.start, arc.start + arc.sweep] { points.append(CGPoint(x: cos(angle) * inner, y: sin(angle) * inner)) }
        let xs = points.map(\.x), ys = points.map(\.y)
        // The inner corners sit under the ring inside; only the outer edge carries the rim.
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    static func visible(_ arc: RadialArc, center: CGPoint, in bounds: CGRect) -> Bool {
        bounds.contains(extent(of: arc).offsetBy(dx: center.x, dy: center.y))
    }
    /// An arc of `count` tools beside the sector at `anchor`: centered on it if it fits on screen,
    /// otherwise turned toward open space (never so far that it leaves its group), then narrower.
    static func arc(count: Int, level: Int, anchor: Double, center: CGPoint, in bounds: CGRect) -> RadialArc? {
        for width in [toolWidth, minimumToolWidth] {
            let step = min(Double(width / middleRadius(level)), 2 * .pi / Double(max(1, count)))
            let sweep = step * Double(count)
            let centered = RadialArc(level: level, start: anchor - sweep / 2, step: step, count: count)
            if centered.isFullRing { return visible(centered, center: center, in: bounds) ? centered : nil }
            let turn = 0.035
            for k in 0...Int(sweep / 2 / turn) {
                for sign in k == 0 ? [0.0] : [1.0, -1.0] {
                    let arc = RadialArc(level: level, start: centered.start + sign * Double(k) * turn, step: step, count: count)
                    if visible(arc, center: center, in: bounds) { return arc }
                }
            }
        }
        return nil
    }
    static func centeredArc(count: Int, level: Int, anchor: Double) -> RadialArc {
        let step = min(Double(toolWidth / middleRadius(level)), 2 * .pi / Double(max(1, count)))
        return RadialArc(level: level, start: anchor - step * Double(count) / 2, step: step, count: count)
    }

    /// Where the wheel sits and where its open arcs go. The center stays where the wheel rests;
    /// only when an arc cannot fit beside its group anywhere does the wheel move, and then only
    /// as far as that arc needs. `nested` opens from sector `index` of the first arc.
    static func wheel(resting: CGPoint, in bounds: CGRect, group: (count: Int, anchor: Double)?,
                      nested: (count: Int, index: Int)?) -> (center: CGPoint, arcs: [RadialArc]) {
        guard let group else { return (resting, []) }
        let screen = bounds
        func arcs(at center: CGPoint) -> [RadialArc]? {
            guard let first = arc(count: group.count, level: 1, anchor: group.anchor, center: center, in: screen) else { return nil }
            guard let nested else { return [first] }
            guard let second = arc(count: nested.count, level: 2, anchor: first.angle(nested.index), center: center, in: screen) else { return nil }
            return [first, second]
        }
        if let found = arcs(at: resting) { return (resting, found) }
        let first = centeredArc(count: group.count, level: 1, anchor: group.anchor)
        var preferred = [first]
        if let nested { preferred.append(centeredArc(count: nested.count, level: 2, anchor: first.angle(nested.index))) }
        let base = outerRadius(0) + rim
        let box = preferred.map(extent(of:)).reduce(CGRect(x: -base, y: -base, width: base * 2, height: base * 2)) { $0.union($1) }
        func shift(_ value: CGFloat, low: CGFloat, high: CGFloat, min boxMin: CGFloat, max boxMax: CGFloat) -> CGFloat {
            boxMax - boxMin > high - low ? (low + high) / 2 - (boxMin + boxMax) / 2 : min(max(value, low - boxMin), high - boxMax)
        }
        let moved = CGPoint(x: shift(resting.x, low: screen.minX, high: screen.maxX, min: box.minX, max: box.maxX),
                            y: shift(resting.y, low: screen.minY, high: screen.maxY, min: box.minY, max: box.maxY))
        return (moved, arcs(at: moved) ?? preferred)
    }
}

/// Upright captions need to fit the curved sector, not just a rectangular tile. Measure every
/// visible component, then choose wrapping and a nearby position with clearance on all sides.
@MainActor struct RadialToolbarCaptionLayout {
    private struct Key: Hashable {
        let title: String
        let subtitle: String?
        let angle: Int
        let sweep: Int
        let level: Int
        let notch: Bool
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

    static func contains(_ rect: CGRect, angle: Double, sweep: Double, level: Int) -> Bool {
        let inner = RadialToolbarLayout.innerRadius(level) + 3
        let outer = RadialToolbarLayout.outerRadius(level) - 3
        let nearX = min(max(0, rect.minX), rect.maxX), nearY = min(max(0, rect.minY), rect.maxY)
        guard hypot(nearX, nearY) >= inner else { return false }
        let half = sweep / 2 - 0.018
        for x in [rect.minX, rect.maxX] {
            for y in [rect.minY, rect.maxY] {
                guard hypot(x, y) <= outer else { return false }
                let along = x * cos(angle) + y * sin(angle), across = -x * sin(angle) + y * cos(angle)
                guard along * sin(half) - abs(across) * cos(half) >= 3 else { return false }
            }
        }
        return true
    }

    init(title: String, subtitle: String?, index: Int, count: Int, level: Int, notch: Bool = false) {
        self.init(title: title, subtitle: subtitle, angle: RadialToolbarLayout.angle(index: index, count: count),
                  sweep: 2 * .pi / Double(max(1, count)), level: level, notch: notch)
    }
    /// Where a group's notch sits, at its sector's outer edge; its caption keeps clear of it.
    static func notchCenter(angle: Double, level: Int) -> CGPoint {
        let radius = RadialToolbarLayout.outerRadius(level) - 8
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }
    init(title: String, subtitle: String?, angle: Double, sweep: Double, level: Int, notch: Bool = false) {
        let key = Key(title: title, subtitle: subtitle, angle: Int((angle * 1000).rounded()), sweep: Int((sweep * 1000).rounded()),
                      level: level, notch: notch)
        if let cached = Self.cache[key] { self = cached; return }
        let point = RadialToolbarLayout.point(angle: angle, level: level)
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
        let notchPoint = Self.notchCenter(angle: angle, level: level)
        let keepClear = notch ? CGRect(x: notchPoint.x - 8, y: notchPoint.y - 8, width: 16, height: 16) : .null
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
                        if cost < bestCost && candidate.visibleFrames.allSatisfy({ Self.contains($0, angle: angle, sweep: sweep, level: level) && !$0.intersects(keepClear) }) {
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

/// What a sector's fill says. Each look means one thing (November 22, 2026): Swipe Violet is the
/// tool in use, lavender the group that is open, a violet dot a closed group holding the tool in
/// use, and lime Finish Sketch, which confirms rather than chooses.
enum RadialSectorState: Equatable {
    case plain, active, open, holdsActive, confirm
    var fill: Color {
        switch self {
        case .active: Color("ss-violet")
        case .open: Color("ss-lavender")
        case .confirm: Color("ss-limeSoft")
        case .plain, .holdsActive: Color("ss-white")
        }
    }
    var ink: Color { self == .active ? Color("ss-paper") : Color("ss-ink") }
    var isSelected: Bool { self == .active || self == .open || self == .holdsActive }
}

private struct RadialToolbarCaption: View {
    let layout: RadialToolbarCaptionLayout
    let entry: ToolbarEntry
    let subtitle: String?
    let state: RadialSectorState
    var body: some View {
        let bounds = layout.bounds
        ZStack(alignment: .topLeading) {
            SSIconGlyph(icon: entry.icon, size: 24, color: state.ink)
                .position(x: layout.icon.midX - bounds.minX, y: layout.icon.midY - bounds.minY)
            if state == .holdsActive {
                Circle().fill(Color("ss-violet")).frame(width: 7, height: 7)
                    .position(x: layout.icon.maxX + 2 - bounds.minX, y: layout.icon.minY + 2 - bounds.minY)
            }
            Text(layout.title).font(.system(size: layout.fontSize, weight: .semibold))
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(width: layout.titleFrame.width, height: layout.titleFrame.height)
                .position(x: layout.titleFrame.midX - bounds.minX, y: layout.titleFrame.midY - bounds.minY)
            if let subtitle, let detail = layout.subtitleFrame {
                Text(subtitle).font(.system(size: 8, weight: .medium))
                    .foregroundStyle(state == .active ? Color("ss-paper").opacity(0.85) : Color("ss-muted"))
                    .frame(width: detail.width, height: detail.height)
                    .position(x: detail.midX - bounds.minX, y: detail.midY - bounds.minY)
            }
        }
        .foregroundStyle(state.ink).frame(width: bounds.width, height: bounds.height)
    }
}

/// A small notch at a group's outer edge, pointing to where its tools open.
private struct RadialGroupNotch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
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

/// The wheel's white backing: the first ring and each open arc joined into one shape, which
/// the rim's rounded stroke gives soft corners.
private struct RadialBackdrop: Shape {
    let arcs: [RadialArc]
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func disc(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        var path = disc(RadialToolbarLayout.outerRadius(0))
        for arc in arcs {
            let outer = RadialToolbarLayout.outerRadius(arc.level)
            if arc.isFullRing { path = path.union(disc(outer)); continue }
            // Reach back under the ring inside so the arc reads as growing out of the wheel.
            let inner = RadialToolbarLayout.outerRadius(arc.level - 1) - 2
            var band = Path()
            band.addArc(center: center, radius: outer, startAngle: .radians(arc.start), endAngle: .radians(arc.start + arc.sweep), clockwise: false)
            band.addArc(center: center, radius: inner, startAngle: .radians(arc.start + arc.sweep), endAngle: .radians(arc.start), clockwise: true)
            band.closeSubpath()
            path = path.union(band)
        }
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
    let session: ModelingSession
    let sketching: Bool
    let mode: WorkspaceMode
    let bounds: CGRect
    let requestedCenter: CGPoint?
    let onMove: (CGPoint) -> Void
    let onEntry: (ToolbarEntry) -> Void
    let onClose: () -> Void
    @State private var expanded: ToolGroup?
    @State private var primitives = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var roots: [ToolbarEntry] { ToolbarEntry.roots(sketching: sketching, mode: mode) }
    private var twoRings: Bool { RadialToolbarLayout.fits(levels: 2, in: bounds) }
    private var threeRings: Bool { RadialToolbarLayout.fits(levels: 3, in: bounds) }
    private var levels: Int { expanded == nil || !twoRings ? 1 : primitives && threeRings ? 3 : 2 }
    /// Half the hosted square: everything that can show, rim included. Only the wheel and its open
    /// arcs take touches.
    private var radius: CGFloat { RadialToolbarLayout.outerRadius(levels - 1) + RadialToolbarLayout.rim }
    /// The first ring keeps the wheel on screen; open arcs find room beside their group.
    private var baseRadius: CGFloat { RadialToolbarLayout.outerRadius(0) + RadialToolbarLayout.rim }
    /// The open group's tools (Primitives' with a Back sector, in a window too small for a third ring).
    private var groupEntries: [ToolbarEntry] {
        guard let expanded else { return [] }
        return primitives && !threeRings ? [.primitives] + ToolbarEntry.primitiveTools.map(ToolbarEntry.tool)
            : ToolbarEntry.children(of: expanded, mode: mode)
    }
    private var restingCenter: CGPoint {
        // Unmoved, the wheel rests far enough in from the corner for every group to open beside
        // it without the wheel shifting.
        let inset = twoRings ? RadialToolbarLayout.outerRadius(1) + RadialToolbarLayout.rim : baseRadius
        let preferred = requestedCenter ?? CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset)
        return RadialToolbarLayout.clamp(preferred, radius: baseRadius, in: bounds)
    }
    private var layout: (center: CGPoint, arcs: [RadialArc]) {
        guard twoRings, let expanded, let index = roots.firstIndex(of: .group(expanded)) else { return (restingCenter, []) }
        let entries = groupEntries
        let nested = primitives && threeRings
            ? entries.firstIndex(of: .primitives).map { (count: ToolbarEntry.primitiveTools.count, index: $0) } : nil
        return RadialToolbarLayout.wheel(resting: restingCenter, in: bounds,
                                         group: (entries.count, RadialToolbarLayout.angle(index: index, count: roots.count)), nested: nested)
    }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }

    var body: some View {
        let layout = layout
        RadialToolbarPlacement(center: layout.center, radius: baseRadius, frameRadius: radius, arcs: layout.arcs,
                               bounds: bounds, onMove: onMove) {
            wheel(layout.arcs)
        }
        .allowsHitTesting(!session.isPencilDown)
        .onChange(of: sketching) { expanded = nil; primitives = false }
        .onChange(of: mode) { expanded = nil; primitives = false }
    }

    private func wheel(_ arcs: [RadialArc]) -> some View {
        let backdrop = RadialBackdrop(arcs: arcs)
        let rim = RadialToolbarLayout.rim
        let compact = primitives && !threeRings
        return ZStack {
            // Only the wheel and its open arcs are opaque and interactive. There is no full-screen
            // dismiss layer.
            backdrop.stroke(Color("ss-border"), style: StrokeStyle(lineWidth: rim * 2 + 1, lineJoin: .round))
                .shadow(color: Color("ss-ink").opacity(0.18), radius: 18, y: 6)
            backdrop.stroke(Color("ss-white"), style: StrokeStyle(lineWidth: rim * 2 - 1, lineJoin: .round))
            backdrop.fill(Color("ss-white"))
            if twoRings || expanded == nil { ring(roots, arc: .ring(count: roots.count, level: 0)) }
            if expanded != nil {
                if !twoRings {
                    ring(groupEntries, arc: .ring(count: groupEntries.count, level: 0), compactPrimitives: compact)
                } else if let arc = arcs.first {
                    ring(groupEntries, arc: arc, compactPrimitives: compact)
                }
            }
            if primitives && threeRings, arcs.count > 1 {
                ring(ToolbarEntry.primitiveTools.map(ToolbarEntry.tool), arc: arcs[1])
            }
            hub
        }
        .frame(width: radius * 2, height: radius * 2)
        .accessibilityElement(children: .contain).accessibilityIdentifier("radial.toolbar")
    }

    private func state(_ entry: ToolbarEntry) -> RadialSectorState {
        switch entry {
        case .tool(let tool): session.tool == tool ? .active : .plain
        case .group(let group): expanded == group ? .open : group.tools.contains(session.tool) ? .holdsActive : .plain
        case .primitives: primitives ? .open : ToolbarEntry.primitiveTools.contains(session.tool) ? .holdsActive : .plain
        case .finishSketch: .confirm
        case .sketch: .plain
        }
    }
    /// Holes, pegs, and text go on a solid's face: off one, Features and its tools are dimmed like
    /// the dock's, and still explain themselves when chosen.
    private func needsFace(_ entry: ToolbarEntry) -> Bool {
        guard session.faceFeaturesNeedFace else { return false }
        switch entry {
        case .group(.faceFeatures): return true
        case .tool(let tool): return tool.isFaceFeature
        default: return false
        }
    }
    static let needsFaceSubtitle = "Needs a face"
    /// In a window too small for a third ring, Primitives' tools replace Create's, behind this.
    static let backTitle = "Back to Create"
    private func subtitle(_ entry: ToolbarEntry, compactPrimitives: Bool) -> String? {
        switch entry {
        case .group(.faceFeatures) where needsFace(entry): Self.needsFaceSubtitle
        case .tool(.rectangle): session.rectangleFromCenter ? "Center" : "Corners"
        case .tool(.slot): session.slotFromCenter ? "Center" : "Ends"
        default: nil
        }
    }
    /// Groups open; everything else is a command. After a command the wheel folds back to its first
    /// ring so it covers as little of the canvas as possible.
    private func activate(_ entry: ToolbarEntry) {
        withAnimation(animation) {
            switch entry {
            case .group(let group): expanded = expanded == group ? nil : group; primitives = false
            case .primitives: primitives.toggle()
            default: onEntry(entry); expanded = nil; primitives = false
            }
        }
    }

    private func ring(_ entries: [ToolbarEntry], arc: RadialArc, compactPrimitives: Bool = false) -> some View {
        let level = arc.level
        return ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            let state = state(entry)
            let angle = arc.angle(index)
            let shape = ToolbarSector(inner: RadialToolbarLayout.innerRadius(level), outer: RadialToolbarLayout.outerRadius(level),
                                      angle: angle, sweep: arc.step)
            let detail = subtitle(entry, compactPrimitives: compactPrimitives)
            let opensTools = entry.opensTools && !(compactPrimitives && entry == .primitives)
            let caption = RadialToolbarCaptionLayout(title: compactPrimitives && entry == .primitives ? Self.backTitle : entry.title,
                                                     subtitle: detail, angle: angle, sweep: arc.step, level: level, notch: opensTools)
            let point = CGPoint(x: caption.bounds.midX, y: caption.bounds.midY)
            shape.fill(state.fill)
                .overlay(shape.stroke(Color("ss-border").opacity(0.65), lineWidth: 0.7))
                .contentShape(shape).onTapGesture { activate(entry) }.accessibilityHidden(true)
            if opensTools {
                let notch = RadialToolbarCaptionLayout.notchCenter(angle: angle, level: level)
                RadialGroupNotch().fill(state == .open ? Color("ss-violet") : Color("ss-muted").opacity(0.7))
                    .frame(width: 10, height: 5)
                    .rotationEffect(.radians(angle + .pi / 2))
                    .position(x: radius + notch.x, y: radius + notch.y)
                    .opacity(needsFace(entry) ? 0.45 : 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            // A separate, conventionally sized accessible button keeps VoiceOver's focus and
            // activation point on the caption rather than the wheel's enclosing rectangle.
            Button { activate(entry) } label: {
                RadialToolbarCaption(layout: caption, entry: entry, subtitle: detail, state: state)
                    .opacity(needsFace(entry) ? 0.45 : 1)
                    .contentShape(ToolbarCaptionTarget(sector: shape, offset: point))
            }
            .buttonStyle(.plain).position(x: radius + point.x, y: radius + point.y)
            .accessibilityLabel(compactPrimitives && entry == .primitives ? Self.backTitle : entry.title)
            .accessibilityValue(detail ?? "")
            .accessibilityHint(opensTools ? "Shows this group's tools" : "")
            .accessibilityIdentifier(entry.id).accessibilityAddTraits(state.isSelected ? .isSelected : [])
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
        onMove(RadialToolbarLayout.clamp(CGPoint(x: restingCenter.x + x, y: restingCenter.y + y), radius: baseRadius, in: bounds))
    }
}


/// Gesture tracking lives outside SwiftUI. Moving the menu only changes its hosted view's
/// center; it does not rebuild the rings or refresh the modeling canvas for every input sample.
private struct RadialToolbarPlacement<Content: View>: UIViewControllerRepresentable {
    let center: CGPoint
    let radius: CGFloat
    let frameRadius: CGFloat
    let arcs: [RadialArc]
    let bounds: CGRect
    let onMove: (CGPoint) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> RadialToolbarPlacementController<Content> {
        RadialToolbarPlacementController(content: content())
    }
    func updateUIViewController(_ controller: RadialToolbarPlacementController<Content>, context: Context) {
        controller.update(content: content(), center: center, radius: radius, frameRadius: frameRadius, arcs: arcs, bounds: bounds, onMove: onMove)
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
    /// `radius` keeps the wheel on screen while it is dragged; `frameRadius` is half the hosted
    /// square, which can reach past the screen where an arc is closed; `arcs` take touches too.
    func update(content: Content, center: CGPoint, radius: CGFloat, frameRadius: CGFloat? = nil, arcs: [RadialArc] = [],
                bounds: CGRect, onMove: @escaping (CGPoint) -> Void) {
        loadViewIfNeeded()
        // Rotation or ring expansion can invalidate the current gesture's constraints.
        if radius != self.radius || bounds != allowedBounds { endMove(cancelled: true) }
        hosting.rootView = content
        self.radius = radius
        allowedBounds = bounds
        restingCenter = center
        self.onMove = onMove
        let frame = frameRadius ?? radius
        hosting.view.bounds = CGRect(x: 0, y: 0, width: frame * 2, height: frame * 2)
        if let hit = view as? RadialToolbarHitView { hit.radius = radius; hit.arcs = arcs }
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

/// The placement container fills the workspace, but only the wheel and its open arcs consume
/// input: the rest of the hosted square, beside an arc, reaches the canvas.
@MainActor private final class RadialToolbarHitView: UIView {
    weak var wheel: UIView?
    var radius: CGFloat = 0
    var arcs: [RadialArc] = []
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let wheel else { return false }
        let x = point.x - wheel.center.x, y = point.y - wheel.center.y, distance = hypot(x, y)
        if distance <= radius { return true }
        return arcs.contains { arc in
            distance >= RadialToolbarLayout.outerRadius(arc.level - 1)
                && distance <= RadialToolbarLayout.outerRadius(arc.level) + RadialToolbarLayout.rim
                && arc.contains(angle: atan2(y, x))
        }
    }
}
