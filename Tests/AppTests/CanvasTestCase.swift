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
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.sceneView.snapshot().draw(in: controller.view.bounds)
            controller.input.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
