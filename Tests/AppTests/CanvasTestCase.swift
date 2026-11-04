import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Shared setup for tests that drive the canvas through the Pencil pipeline. A test class can
/// override a helper when it needs a different scene.
@MainActor class CanvasTestCase: XCTestCase {
    /// A canvas on an iPad-sized view, after `camera` is applied.
    func canvas(_ session: ModelingSession, camera: ModelingSession.CameraAction = .home) -> CanvasController {
        let controller = CanvasController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        controller.view.layoutIfNeeded()
        session.requestCamera(camera)
        controller.refresh()
        return controller
    }

    /// A 60 × 40 × 20 box on Top (z 0…20) in the default 3D view.
    func boxScene() -> (ModelingSession, CanvasController) {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion()
        session.extrusionDepth = 20
        session.confirmExtrusion()
        session.select(nil)
        return (session, canvas(session, camera: .reset))
    }

    /// A Pencil tap at a world point.
    func tap(_ controller: CanvasController, _ world: SIMD3<Float>) {
        let point = controller.project(world)
        controller.pencilBegan(at: point)
        controller.pencilEnded(at: point, cancelled: false)
        controller.refresh()
    }

    /// The canvas and its overlay as a screenshot attached to the test result.
    func attach(_ controller: CanvasController, _ name: String) {
        controller.refresh()
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { context in
            controller.sceneView.snapshot().draw(in: controller.view.bounds)
            // Render the overlay in place: drawHierarchy would move it into a window and back,
            // and leaving a window cancels the stroke in progress.
            controller.input.layer.setNeedsDisplay()
            controller.input.layer.displayIfNeeded()
            controller.input.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension CanvasController {
    /// A screen point near the canvas's edge, well away from the world axes (which pick as revolve
    /// axes) and from geometry in the middle of the view: a tap there lands on empty canvas.
    func emptyPoint() -> CGPoint {
        let origin = project(.zero)
        let candidates = stride(from: 80.0, through: 1100, by: 40).flatMap { x in [CGPoint(x: x, y: 230), CGPoint(x: x, y: 740)] } +
            stride(from: 260.0, through: 720, by: 40).flatMap { y in [CGPoint(x: 70, y: y), CGPoint(x: 1110, y: y)] }
        func clearance(_ p: CGPoint) -> CGFloat {
            [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)].map { axis -> CGFloat in
                let tip = project(axis * 10), dx = tip.x - origin.x, dy = tip.y - origin.y, length = hypot(dx, dy)
                return length > 2 ? abs((p.x - origin.x) * dy - (p.y - origin.y) * dx) / length : .infinity
            }.min() ?? .infinity
        }
        return candidates.max { clearance($0) < clearance($1) }!
    }
}
