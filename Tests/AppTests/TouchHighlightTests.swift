import XCTest
@testable import SwipeAndSketch

/// Show Touches: which contacts are drawn, for how long, and their tails. Touch delivery itself needs real touches.
@MainActor final class TouchHighlightTests: XCTestCase {
    private final class Contact {}
    private var contacts: [Contact] = []
    private func key() -> ObjectIdentifier { let contact = Contact(); contacts.append(contact); return ObjectIdentifier(contact) }
    private let origin = CGPoint(x: 100, y: 100)

    func testFingerTapStaysReadableThenFades() {
        var model = TouchHighlightModel()
        let finger = key()
        XCTAssertNotNil(model.began(key: finger, kind: .finger, point: origin, radius: 10, time: 0))
        model.ended(key: finger, cancelled: false, time: 0.1)
        XCTAssertEqual(model.marks.count, 1)
        let mark = model.marks[0]
        XCTAssertEqual(mark.ending, .lifted)
        XCTAssertEqual(model.opacity(of: mark, at: 0.29), 1)
        let fading = model.opacity(of: mark, at: 0.40)
        XCTAssertGreaterThan(fading, 0)
        XCTAssertLessThan(fading, 1)
        XCTAssertFalse(model.tick(time: 0.60))
        XCTAssertTrue(model.marks.isEmpty)
    }

    func testLongPressFadesFromLiftNotMinimum() {
        var model = TouchHighlightModel()
        let finger = key()
        model.began(key: finger, kind: .finger, point: origin, radius: 10, time: 0)
        XCTAssertTrue(model.tick(time: 1.0))
        model.ended(key: finger, cancelled: false, time: 2.0)
        let mark = model.marks[0]
        XCTAssertEqual(model.opacity(of: mark, at: 2.0), 1)
        XCTAssertLessThan(model.opacity(of: mark, at: 2.1), 1)
        XCTAssertTrue(model.tick(time: 2.1))
        XCTAssertFalse(model.tick(time: 2.3))
    }

    func testPencilIsAlwaysShown() {
        var model = TouchHighlightModel()
        XCTAssertNotNil(model.began(key: key(), kind: .pencil, point: origin, radius: 80, time: 0))
        XCTAssertEqual(model.marks.map(\.kind), [.pencil])
    }

    func testFingerBeganWhilePencilDownNeverAppears() {
        var model = TouchHighlightModel()
        let pencil = key(), palm = key()
        model.began(key: pencil, kind: .pencil, point: origin, radius: 1, time: 0)
        XCTAssertNil(model.began(key: palm, kind: .finger, point: CGPoint(x: 300, y: 300), radius: 20, time: 0.1))
        model.ended(key: pencil, cancelled: false, time: 0.5)
        model.moved(key: palm, point: CGPoint(x: 320, y: 300), radius: 20, time: 1.0)
        XCTAssertEqual(model.marks.map(\.kind), [.pencil])
        model.ended(key: palm, cancelled: false, time: 1.1)
        XCTAssertEqual(model.marks.map(\.kind), [.pencil])
    }

    func testFingerDownWhenPencilBeginsIsRemoved() {
        var model = TouchHighlightModel()
        let palm = key(), pencil = key()
        model.began(key: palm, kind: .finger, point: CGPoint(x: 300, y: 300), radius: 20, time: 0)
        model.began(key: pencil, kind: .pencil, point: origin, radius: 1, time: 0.05)
        let finger = model.marks.first { $0.kind == .finger }
        XCTAssertEqual(finger?.ending, .suppressed)
        XCTAssertEqual(model.opacity(of: finger!, at: 0.14), 0)
        model.moved(key: palm, point: CGPoint(x: 340, y: 300), radius: 20, time: 0.1)
        XCTAssertEqual(model.marks.first { $0.kind == .finger }?.point, CGPoint(x: 300, y: 300))
        model.ended(key: pencil, cancelled: false, time: 0.2)
        model.ended(key: palm, cancelled: false, time: 0.3)
        _ = model.tick(time: 0.3)
        XCTAssertFalse(model.marks.contains { $0.kind == .finger })
    }

    func testFingerSoonAfterPencilLiftIsPalm() {
        var model = TouchHighlightModel()
        let pencil = key()
        model.began(key: pencil, kind: .pencil, point: origin, radius: 1, time: 0)
        model.ended(key: pencil, cancelled: false, time: 1.0)
        XCTAssertNil(model.began(key: key(), kind: .finger, point: origin, radius: 20, time: 1.2))
        XCTAssertNotNil(model.began(key: key(), kind: .finger, point: origin, radius: 20, time: 1.4))
    }

    func testWideContactIsPalm() {
        var model = TouchHighlightModel()
        XCTAssertNil(model.began(key: key(), kind: .finger, point: origin, radius: 60, time: 0))
        let growing = key()
        XCTAssertNotNil(model.began(key: growing, kind: .finger, point: origin, radius: 20, time: 0))
        model.moved(key: growing, point: origin, radius: 50, time: 0.05)
        XCTAssertEqual(model.marks.last?.ending, .suppressed)
        XCTAssertFalse(model.tick(time: 0.2))
    }

    func testTailStartsPastThresholdAndAgesOut() {
        var model = TouchHighlightModel()
        let finger = key()
        model.began(key: finger, kind: .finger, point: origin, radius: 10, time: 0)
        model.moved(key: finger, point: CGPoint(x: 109, y: 100), radius: 10, time: 0.02)
        XCTAssertFalse(model.marks[0].trailing)
        model.moved(key: finger, point: CGPoint(x: 111, y: 100), radius: 10, time: 0.04)
        XCTAssertTrue(model.marks[0].trailing)
        XCTAssertEqual(model.marks[0].samples.count, 3)
        _ = model.tick(time: 0.33)
        XCTAssertEqual(model.marks[0].samples.map(\.time), [0.04])
        _ = model.tick(time: 0.5)
        XCTAssertTrue(model.marks[0].samples.isEmpty, "Held still, the tail empties")
        XCTAssertEqual(model.marks.count, 1, "The mark stays while the finger is down")
    }

    func testTailKeepsAtMostSixtySamples() {
        var model = TouchHighlightModel()
        let pencil = key()
        model.began(key: pencil, kind: .pencil, point: origin, radius: 1, time: 0)
        for step in 1...100 { model.moved(key: pencil, point: CGPoint(x: 100 + CGFloat(step), y: 100), radius: 1, time: Double(step) * 0.001) }
        XCTAssertEqual(model.marks[0].samples.count, 60)
        XCTAssertEqual(model.marks[0].point, CGPoint(x: 200, y: 100))
    }

    func testCancelledContactGoesQuickly() {
        var model = TouchHighlightModel()
        let finger = key()
        model.began(key: finger, kind: .finger, point: origin, radius: 10, time: 0)
        model.ended(key: finger, cancelled: true, time: 0.02)
        XCTAssertEqual(model.marks[0].ending, .cancelled)
        XCTAssertFalse(model.tick(time: 0.35))
    }

    func testTwoFingersMoveIndependently() {
        var model = TouchHighlightModel()
        let a = key(), b = key()
        model.began(key: a, kind: .finger, point: CGPoint(x: 100, y: 100), radius: 10, time: 0)
        model.began(key: b, kind: .finger, point: CGPoint(x: 300, y: 100), radius: 10, time: 0)
        model.moved(key: a, point: CGPoint(x: 80, y: 100), radius: 10, time: 0.05)
        model.moved(key: b, point: CGPoint(x: 330, y: 100), radius: 10, time: 0.05)
        XCTAssertEqual(model.marks.map(\.point), [CGPoint(x: 80, y: 100), CGPoint(x: 330, y: 100)])
        XCTAssertEqual(Set(model.marks.map(\.id)).count, 2)
    }

    func testRemoveAllLeavesNothing() {
        var model = TouchHighlightModel()
        let finger = key()
        model.began(key: finger, kind: .finger, point: origin, radius: 10, time: 0)
        model.began(key: key(), kind: .pencil, point: origin, radius: 1, time: 0)
        model.removeAll()
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertFalse(model.tick(time: 0))
        model.ended(key: finger, cancelled: false, time: 0.1)
        XCTAssertTrue(model.marks.isEmpty)
    }

    func testUnknownEndAndRepeatedBeginAreHarmless() {
        var model = TouchHighlightModel()
        model.ended(key: key(), cancelled: false, time: 0)
        XCTAssertTrue(model.marks.isEmpty)
        let finger = key()
        model.began(key: finger, kind: .finger, point: origin, radius: 10, time: 0)
        model.began(key: finger, kind: .finger, point: origin, radius: 10, time: 0.01)
        XCTAssertEqual(model.marks.map(\.ending), [.cancelled, nil])
        model.ended(key: finger, cancelled: false, time: 0.05)
        XCTAssertFalse(model.tick(time: 1))
    }

    func testInstallsOnceAndRemovesCompletely() throws {
        let highlighter = TouchHighlighter()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        func observers() -> Int { window.gestureRecognizers?.filter { $0.name == TouchObserver.identifier }.count ?? 0 }
        func hosts() -> Int { window.layer.sublayers?.filter { $0.name == TouchObserver.identifier }.count ?? 0 }
        XCTAssertEqual(observers(), 0)
        highlighter.setEnabled(true)
        highlighter.attach(to: window)
        highlighter.attach(to: window)
        XCTAssertEqual(observers(), 1)
        XCTAssertEqual(hosts(), 1)
        XCTAssertEqual(window.layer.sublayers?.first { $0.name == TouchObserver.identifier }?.zPosition, 100_000)
        highlighter.setEnabled(false)
        XCTAssertEqual(observers(), 0)
        XCTAssertEqual(hosts(), 0)
        XCTAssertFalse(highlighter.isAnimating)
    }

    func testObserverNeverInterferes() {
        let observer = TouchObserver()
        let other = UIPanGestureRecognizer()
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertFalse(observer.requiresExclusiveTouchType)
        XCTAssertFalse(observer.canPrevent(other))
        XCTAssertFalse(observer.canBePrevented(by: other))
        XCTAssertFalse(observer.shouldRequireFailure(of: other))
        XCTAssertFalse(observer.shouldBeRequiredToFail(by: other))
        XCTAssertEqual(Set(observer.allowedTouchTypes.map(\.intValue)), [UITouch.TouchType.direct.rawValue, UITouch.TouchType.pencil.rawValue])
    }

    func testFollowsTheSwitchAndLaunchArgument() {
        XCTAssertEqual(TouchHighlighter.shared.isEnabled, TouchHighlighter.wanted)
    }
}
