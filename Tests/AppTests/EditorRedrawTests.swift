import XCTest
import SwiftUI
@testable import SwipeAndSketch

/// How often the editor redraws while the Pencil drags. The session is observed per property, so
/// a value that changes with every Pencil sample redraws only the parts of the editor that show it,
/// not the whole editor ("Workspace body" in Instruments' Points of Interest).
@MainActor final class EditorRedrawTests: XCTestCase {
    private var window: UIWindow?
    private var events: [String: Int] = [:]

    override func tearDown() async throws {
        Performance.eventHook = nil
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    /// The editor on screen, settled.
    private func show(_ session: ModelingSession) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        window.rootViewController = UIHostingController(rootView: WorkspaceView(session: session))
        window.makeKeyAndVisible()
        self.window = window
        settle(0.5)
        Performance.eventHook = { [weak self] name in
            // Solid builds and other intervals may begin off the main thread; only the main thread's count.
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { self?.events["\(name)", default: 0] += 1 }
        }
    }

    private func settle(_ seconds: TimeInterval = 0.02) {
        window?.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Runs `samples` steps, letting SwiftUI update after each, and returns the editor's redraws.
    private func redraws(samples: Int, _ step: (Int) -> Void) -> (editor: Int, parts: Int, canvas: Int) {
        events = [:]
        for sample in 1...samples {
            step(sample)
            settle()
        }
        let counted = (editor: events["Workspace body", default: 0], parts: events["Editor part", default: 0], canvas: events["Canvas refresh", default: 0])
        print("Redraws for \(samples) samples: editor \(counted.editor), parts \(counted.parts), canvas \(counted.canvas)")
        return counted
    }

    func testDraggingASketchPointRedrawsOnlyThePartsThatShowIt() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .line, plane: .top, start: .zero, end: .init(x: 40, y: 0)))
        let line = try XCTUnwrap(session.workspace.shapes.first)
        try show(session)
        session.beginSketchDrag(shapeID: line.id, handle: .end)
        settle(0.2)
        let counted = redraws(samples: 30) { session.updateSketchDrag(to: .init(x: 40 + Double($0), y: Double($0) / 2)) }
        session.finishSketchDrag(cancelled: false)
        XCTAssertEqual(session.workspace.shapes.first?.end, .init(x: 70, y: 15), "The drag still lands")
        XCTAssertLessThanOrEqual(counted.editor, 2, "30 samples redrew the editor \(counted.editor) times (parts: \(counted.parts))")
        XCTAssertGreaterThanOrEqual(counted.canvas, 30, "The canvas shows every sample")
    }

    func testDraggingAnExtrusionRedrawsOnlyThePartsThatShowIt() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 30, y: 20)))
        try show(session)
        session.beginExtrusion()
        settle(0.2)
        let counted = redraws(samples: 30) { session.extrusionDepth = Double($0) }
        XCTAssertTrue(session.canConfirmExtrusion)
        session.confirmExtrusion()
        XCTAssertEqual(session.workspace.bodies.count, 1, "The extrusion still lands")
        XCTAssertLessThanOrEqual(counted.editor, 2, "30 samples redrew the editor \(counted.editor) times (parts: \(counted.parts))")
        XCTAssertGreaterThanOrEqual(counted.canvas, 30, "The canvas shows every sample")
    }
}
