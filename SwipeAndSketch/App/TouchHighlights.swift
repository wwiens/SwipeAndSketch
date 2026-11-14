import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Show Touches: a mark at every finger and Apple Pencil contact, drawn inside the app's own windows so that
/// screen recordings show where the screen was touched. Off by default; Settings → Workspace turns it on.

/// Every size, color strength, and duration in one place, so they can be tuned after watching a recording.
enum TouchHighlightStyle {
    static let fingerDiameter: CGFloat = 44
    static let fingerFillAlpha: CGFloat = 0.18
    static let fingerStrokeAlpha: CGFloat = 0.95
    static let fingerStrokeWidth: CGFloat = 2.5
    static let fingerHaloOpacity: Float = 0.35
    static let fingerHaloRadius: CGFloat = 3
    static let fingerTailAlpha: CGFloat = 0.28
    static let fingerTailWidth: CGFloat = 10
    static let fingerTailDuration: TimeInterval = 0.30

    static let pencilDiameter: CGFloat = 24
    static let pencilCasingAlpha: CGFloat = 0.95
    static let pencilCasingWidth: CGFloat = 5.5
    static let pencilRingWidth: CGFloat = 3
    static let pencilTailEnabled = true
    static let pencilTailAlpha: CGFloat = 0.45
    static let pencilTailWidth: CGFloat = 4
    static let pencilTailDuration: TimeInterval = 0.20

    static let rippleScale: CGFloat = 2
    static let rippleOpacity: Float = 0.6
    static let rippleDuration: TimeInterval = 0.45

    static let tailThreshold: CGFloat = 10
    static let maximumTailSamples = 60
    static let minimumVisible: TimeInterval = 0.30
    static let fadeOut: TimeInterval = 0.25
    static let cancelledFade: TimeInterval = 0.10
    static let suppressedFade: TimeInterval = 0.08

    /// Contacts wider than this are palms, the same limit the canvas's tap-away uses.
    static let palmRadius: CGFloat = 45
    /// Fingers that land this soon after the Pencil lifts are the palm shifting between strokes.
    static let palmAfterPencil: TimeInterval = 0.30
}

/// Which contacts are shown, for how long, and their tails. No UIKit views and no clock: every call takes the time.
struct TouchHighlightModel {
    enum Kind: Equatable { case finger, pencil }
    enum Ending: Equatable { case lifted, cancelled, suppressed }
    struct Sample: Equatable { var point: CGPoint; var time: TimeInterval }

    struct Mark: Identifiable, Equatable {
        let id: Int
        let kind: Kind
        var point: CGPoint
        var start: CGPoint
        var began: TimeInterval
        var ended: TimeInterval?
        var ending: Ending?
        var trailing = false
        var samples: [Sample] = []
    }

    private(set) var marks: [Mark] = []
    private var live: [ObjectIdentifier: Int] = [:]
    private var suppressed: Set<ObjectIdentifier> = []
    private var pencils: Set<ObjectIdentifier> = []
    private var lastPencilEnd: TimeInterval?
    private var nextID = 1

    /// A contact came down. Returns the new mark's id, or nil when the contact is suppressed as a palm.
    @discardableResult
    mutating func began(key: ObjectIdentifier, kind: Kind, point: CGPoint, radius: CGFloat, time: TimeInterval) -> Int? {
        if live[key] != nil || suppressed.contains(key) { ended(key: key, cancelled: true, time: time) }
        switch kind {
        case .pencil:
            for (other, id) in live where mark(id)?.kind == .finger { suppress(other, time: time) }
            pencils.insert(key)
        case .finger:
            let afterPencil = lastPencilEnd.map { time - $0 < TouchHighlightStyle.palmAfterPencil } ?? false
            if !pencils.isEmpty || afterPencil || radius > TouchHighlightStyle.palmRadius {
                suppressed.insert(key)
                return nil
            }
        }
        let id = nextID
        nextID += 1
        marks.append(Mark(id: id, kind: kind, point: point, start: point, began: time, samples: [Sample(point: point, time: time)]))
        live[key] = id
        return id
    }

    mutating func moved(key: ObjectIdentifier, point: CGPoint, radius: CGFloat, time: TimeInterval) {
        guard let id = live[key], let index = marks.firstIndex(where: { $0.id == id }) else { return }
        if marks[index].kind == .finger && radius > TouchHighlightStyle.palmRadius { suppress(key, time: time); return }
        marks[index].point = point
        let start = marks[index].start
        if !marks[index].trailing && hypot(point.x - start.x, point.y - start.y) > TouchHighlightStyle.tailThreshold {
            marks[index].trailing = true
        }
        marks[index].samples.append(Sample(point: point, time: time))
        let excess = marks[index].samples.count - TouchHighlightStyle.maximumTailSamples
        if excess > 0 { marks[index].samples.removeFirst(excess) }
    }

    mutating func ended(key: ObjectIdentifier, cancelled: Bool, time: TimeInterval) {
        if suppressed.remove(key) != nil { return }
        guard let id = live.removeValue(forKey: key) else { return }
        if pencils.remove(key) != nil { lastPencilEnd = time }
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        marks[index].ended = time
        marks[index].ending = cancelled ? .cancelled : .lifted
    }

    /// Drops aged tail samples and finished marks. Returns false when nothing is left to draw.
    mutating func tick(time: TimeInterval) -> Bool {
        for index in marks.indices {
            let oldest = time - Self.tailDuration(marks[index].kind)
            marks[index].samples.removeAll { $0.time < oldest }
        }
        let model = self
        marks.removeAll { model.opacity(of: $0, at: time) <= 0 && $0.samples.isEmpty }
        return !marks.isEmpty
    }

    /// Ends everything at once (app resigning active, window going away, switch turned off).
    mutating func removeAll() {
        marks.removeAll()
        live.removeAll()
        suppressed.removeAll()
        pencils.removeAll()
        lastPencilEnd = nil
    }

    /// 1 while down and during the minimum visible time, then falling to 0 over the fade.
    func opacity(of mark: Mark, at time: TimeInterval) -> CGFloat {
        guard let ended = mark.ended, let ending = mark.ending else { return 1 }
        let fade: CGFloat
        switch ending {
        case .lifted:
            let hold = max(ended, mark.began + TouchHighlightStyle.minimumVisible)
            fade = CGFloat((time - hold) / TouchHighlightStyle.fadeOut)
        case .cancelled: fade = CGFloat((time - ended) / TouchHighlightStyle.cancelledFade)
        case .suppressed: fade = CGFloat((time - ended) / TouchHighlightStyle.suppressedFade)
        }
        return min(1, max(0, 1 - fade))
    }

    static func tailDuration(_ kind: Kind) -> TimeInterval {
        kind == .pencil ? TouchHighlightStyle.pencilTailDuration : TouchHighlightStyle.fingerTailDuration
    }

    private func mark(_ id: Int) -> Mark? { marks.first { $0.id == id } }

    /// A palm: never shown again, but tracked until it lifts so its later moves and end are ignored.
    private mutating func suppress(_ key: ObjectIdentifier, time: TimeInterval) {
        suppressed.insert(key)
        guard let id = live.removeValue(forKey: key), let index = marks.firstIndex(where: { $0.id == id }) else { return }
        marks[index].ended = time
        marks[index].ending = .suppressed
        marks[index].samples.removeAll()
    }
}

/// Watches every touch in its window and never takes part in recognition: it stays in `.possible`,
/// so it cannot win, block, delay, or cancel anything.
@MainActor final class TouchObserver: UIGestureRecognizer {
    static let identifier = "touchHighlights"
    weak var highlighter: TouchHighlighter?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        name = Self.identifier
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        highlighter?.receive(touches, phase: .began, in: view as? UIWindow)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        highlighter?.receive(touches, phase: .moved, in: view as? UIWindow)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        highlighter?.receive(touches, phase: .ended, in: view as? UIWindow)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        highlighter?.receive(touches, phase: .cancelled, in: view as? UIWindow)
    }
    override func reset() {
        super.reset()
        if let window = view as? UIWindow { highlighter?.endContacts(in: window) }
    }
}

/// Reads the preference, installs and removes the observers, and draws the marks as Core Animation layers
/// in a host layer above each window's content (layers take no part in hit testing).
@MainActor final class TouchHighlighter: NSObject {
    static let shared = TouchHighlighter()
    /// Whether Settings offers the switch and the stored preference is honored. The launch argument works regardless.
    static let isAvailable = true
    static let defaultsKey = "showTouches"
    static let launchArgument = "--show-touches"

    private(set) var isEnabled = false

    private final class Attachment {
        weak var window: UIWindow?
        let observer: TouchObserver
        let host: CALayer
        init(window: UIWindow, observer: TouchObserver, host: CALayer) { self.window = window; self.observer = observer; self.host = host }
    }

    private struct MarkLayers {
        let container: CALayer
        let tail: CAShapeLayer
        let ripple: CAShapeLayer
    }

    private var started = false
    private var model = TouchHighlightModel()
    private var attachments: [Attachment] = []
    private var hosts: [Int: CALayer] = [:]
    private var layers: [Int: MarkLayers] = [:]
    private var contactWindows: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var displayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []

    private lazy var ink = UIColor(named: "ss-ink") ?? UIColor(red: 0x25 / 255, green: 0x21 / 255, blue: 0x37 / 255, alpha: 1)
    private lazy var paper = UIColor(named: "ss-paper") ?? UIColor(red: 0xFF / 255, green: 0xF9 / 255, blue: 0xF0 / 255, alpha: 1)
    private lazy var violet = UIColor(named: "ss-violet") ?? UIColor(red: 0x6D / 255, green: 0x3D / 255, blue: 0xF5 / 255, alpha: 1)

    /// Called once from the app's `init()`, before any window exists; windows arrive as they become visible.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.preferenceChanged() }
            },
            center.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? UIWindow
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled, let window, Self.eligible(window) else { return }
                    self.attach(to: window)
                }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearMarks() }
            },
        ]
        setEnabled(Self.wanted)
    }

    static var wanted: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
            || (isAvailable && UserDefaults.standard.bool(forKey: defaultsKey))
    }

    private func preferenceChanged() {
        let wanted = Self.wanted
        if wanted != isEnabled { setEnabled(wanted) }
    }

    /// Installs on every app window, or removes everything so nothing of the feature remains.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            for window in windows where Self.eligible(window) { attach(to: window) }
        } else {
            clearMarks()
            for attachment in attachments {
                attachment.window?.removeGestureRecognizer(attachment.observer)
                attachment.host.removeFromSuperlayer()
            }
            attachments.removeAll()
        }
    }

    /// Only the app's own windows; UIKit's text-effects and keyboard windows sit at higher levels.
    private static func eligible(_ window: UIWindow) -> Bool { window.windowLevel == .normal }

    func attach(to window: UIWindow) {
        attachments.removeAll { $0.window == nil }
        if window.gestureRecognizers?.contains(where: { $0.name == TouchObserver.identifier }) == true { return }
        let observer = TouchObserver()
        observer.highlighter = self
        let host = CALayer()
        host.name = TouchObserver.identifier
        host.zPosition = 100_000
        host.frame = window.bounds
        host.actions = Self.noActions
        window.layer.addSublayer(host)
        window.addGestureRecognizer(observer)
        attachments.append(Attachment(window: window, observer: observer, host: host))
    }

    // MARK: Touches

    func receive(_ touches: Set<UITouch>, phase: UITouch.Phase, in window: UIWindow?) {
        guard isEnabled, let window, let attachment = attachments.first(where: { $0.window === window }) else { return }
        let windowID = ObjectIdentifier(window)
        if phase == .began {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            attachment.host.frame = window.bounds
            if attachment.host.superlayer !== window.layer { window.layer.addSublayer(attachment.host) }
            CATransaction.commit()
        }
        var latest = CACurrentMediaTime()
        for touch in touches {
            let kind: TouchHighlightModel.Kind
            switch touch.type {
            case .direct: kind = .finger
            case .pencil: kind = .pencil
            default: continue
            }
            let key = ObjectIdentifier(touch), point = touch.preciseLocation(in: window), time = touch.timestamp
            latest = time
            switch phase {
            case .began:
                contactWindows[key] = windowID
                if let id = model.began(key: key, kind: kind, point: point, radius: touch.majorRadius, time: time) {
                    hosts[id] = attachment.host
                }
            case .moved:
                model.moved(key: key, point: point, radius: touch.majorRadius, time: time)
            case .ended, .cancelled:
                contactWindows[key] = nil
                model.ended(key: key, cancelled: phase == .cancelled, time: time)
            default: break
            }
        }
        redraw(at: latest)
        if !model.marks.isEmpty { startDisplayLink() }
    }

    /// Ends contacts the window's observer no longer tracks (it reset without delivering their end).
    func endContacts(in window: UIWindow) {
        let windowID = ObjectIdentifier(window)
        let stale = contactWindows.filter { $0.value == windowID }.map(\.key)
        guard !stale.isEmpty else { return }
        let now = CACurrentMediaTime()
        for key in stale {
            contactWindows[key] = nil
            model.ended(key: key, cancelled: true, time: now)
        }
        redraw(at: now)
    }

    private func clearMarks() {
        model.removeAll()
        contactWindows.removeAll()
        hosts.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.values { layer.container.removeFromSuperlayer() }
        CATransaction.commit()
        layers.removeAll()
        stopDisplayLink()
    }

    // MARK: Drawing

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    var isAnimating: Bool { displayLink != nil }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let remaining = model.tick(time: now)
        redraw(at: now)
        if !remaining { stopDisplayLink() }
    }

    private func redraw(at time: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let current = Set(model.marks.map(\.id))
        for (id, layer) in layers where !current.contains(id) {
            layer.container.removeFromSuperlayer()
            layers[id] = nil
            hosts[id] = nil
        }
        for mark in model.marks {
            guard let layer = layers[mark.id] ?? makeLayers(for: mark) else { continue }
            layer.container.position = mark.point
            layer.container.opacity = Float(model.opacity(of: mark, at: time))
            if mark.ending == .suppressed { layer.ripple.removeAllAnimations(); layer.ripple.removeFromSuperlayer() }
            layer.tail.path = tailPath(for: mark)
        }
        CATransaction.commit()
    }

    private func tailPath(for mark: TouchHighlightModel.Mark) -> CGPath? {
        guard mark.trailing, mark.kind == .finger || TouchHighlightStyle.pencilTailEnabled, mark.samples.count > 1 else { return nil }
        let path = CGMutablePath()
        let offset = CGPoint(x: -mark.point.x, y: -mark.point.y)
        path.addLines(between: mark.samples.map { CGPoint(x: $0.point.x + offset.x, y: $0.point.y + offset.y) })
        return path
    }

    private func makeLayers(for mark: TouchHighlightModel.Mark) -> MarkLayers? {
        guard let host = hosts[mark.id] else { return nil }
        let style = TouchHighlightStyle.self
        let container = CALayer()
        container.actions = Self.noActions
        container.bounds = .zero

        let tail = CAShapeLayer()
        tail.actions = Self.noActions
        tail.fillColor = nil
        tail.lineCap = .round
        tail.lineJoin = .round
        container.addSublayer(tail)

        let ripple = CAShapeLayer()
        ripple.fillColor = nil
        container.addSublayer(ripple)

        switch mark.kind {
        case .finger:
            tail.strokeColor = ink.withAlphaComponent(style.fingerTailAlpha).cgColor
            tail.lineWidth = style.fingerTailWidth
            let circle = Self.circle(diameter: style.fingerDiameter)
            let dot = CAShapeLayer()
            dot.actions = Self.noActions
            dot.path = circle
            dot.fillColor = ink.withAlphaComponent(style.fingerFillAlpha).cgColor
            dot.strokeColor = paper.withAlphaComponent(style.fingerStrokeAlpha).cgColor
            dot.lineWidth = style.fingerStrokeWidth
            dot.shadowColor = ink.cgColor
            dot.shadowOpacity = style.fingerHaloOpacity
            dot.shadowRadius = style.fingerHaloRadius
            dot.shadowOffset = .zero
            dot.shadowPath = circle
            container.addSublayer(dot)
            ripple.path = circle
            ripple.strokeColor = paper.cgColor
            ripple.lineWidth = style.fingerStrokeWidth
        case .pencil:
            tail.strokeColor = violet.withAlphaComponent(style.pencilTailAlpha).cgColor
            tail.lineWidth = style.pencilTailWidth
            // The ring's outer edge is the diameter, so each stroke is inset by half its width.
            let casing = CAShapeLayer(), ring = CAShapeLayer()
            casing.path = Self.circle(diameter: style.pencilDiameter - style.pencilCasingWidth)
            casing.strokeColor = paper.withAlphaComponent(style.pencilCasingAlpha).cgColor
            casing.lineWidth = style.pencilCasingWidth
            ring.path = Self.circle(diameter: style.pencilDiameter - style.pencilCasingWidth)
            ring.strokeColor = violet.cgColor
            ring.lineWidth = style.pencilRingWidth
            for layer in [casing, ring] {
                layer.actions = Self.noActions
                layer.fillColor = nil
                container.addSublayer(layer)
            }
            ripple.path = ring.path
            ripple.strokeColor = violet.cgColor
            ripple.lineWidth = style.pencilRingWidth
        }

        // The ripple runs once from the touch-down; its final values are invisible, so it needs no cleanup.
        ripple.opacity = 0
        ripple.transform = CATransform3DMakeScale(style.rippleScale, style.rippleScale, 1)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = style.rippleScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = style.rippleOpacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = style.rippleDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(group, forKey: "ripple")

        host.addSublayer(container)
        let made = MarkLayers(container: container, tail: tail, ripple: ripple)
        layers[mark.id] = made
        return made
    }

    private static func circle(diameter: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter), transform: nil)
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "path": NSNull(),
        "contents": NSNull(), "transform": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]
}
