import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// The Spline tool: a freehand Pencil stroke fitted with a smooth spline (October 24, 2026).
@MainActor final class SplineToolTests: CanvasTestCase {
    /// A Pencil stroke through world points on Top.
    func stroke(_ controller: CanvasController, _ points: [SIMD3<Float>]) {
        let screen = points.map(controller.project)
        controller.pencilBegan(at: screen[0])
        for point in screen.dropFirst() { controller.pencilMoved(to: point) }
        controller.pencilEnded(at: screen[screen.count - 1], cancelled: false)
        controller.refresh()
    }

    func testAWavyStrokeBecomesASplineWhosePointsDrag() throws {
        let session = ModelingSession(inMemory: true)
        session.pickPlaneForTesting(.top)
        let controller = canvas(session, camera: .align(.top))
        session.chooseTool(.spline)
        XCTAssertEqual(session.helpTopic, .spline)
        let wave = (0...60).map { i -> SIMD3<Float> in let x = Float(i) - 30; return SIMD3(x, 8 * sin(x / 6), 0) }
        stroke(controller, wave)
        let spline = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertTrue(spline.isSpline)
        XCTAssertFalse(spline.isClosed)
        XCTAssertGreaterThan(spline.points?.count ?? 0, 3)
        XCTAssertLessThan(spline.points?.count ?? 99, 20)
        XCTAssertEqual(spline.plane.point(spline.start).x, -30, accuracy: 1.5)
        attach(controller, "A spline drawn freehand")
        // Its Model Tree row shows the Spline icon, not Project's.
        let row = session.itemGroups.flatMap(\.items).first { $0.selection == .shape(spline.id) }
        XCTAssertEqual(row?.icon, .spline)

        session.chooseTool(.select)
        session.select(.shape(spline.id))
        controller.refresh()
        XCTAssertEqual(controller.sketchHandles(for: spline).count, spline.points?.count, "A handle on every point")
    }

    func testAStrokeEndingWhereItBeganClosesIntoARegion() throws {
        let session = ModelingSession(inMemory: true)
        session.pickPlaneForTesting(.top)
        let controller = canvas(session, camera: .align(.top))
        session.chooseTool(.spline)
        let loop = (0...72).map { i -> SIMD3<Float> in let a = Float(i) * .pi / 36; return SIMD3(15 * cos(a), 10 * sin(a), 0) }
        stroke(controller, loop)
        let spline = try XCTUnwrap(session.workspace.shapes.last)
        XCTAssertTrue(spline.isSpline)
        XCTAssertTrue(spline.isClosed)
        let region = try XCTUnwrap(session.workspace.profiles.first)
        XCTAssertEqual(region.area, .pi * 15 * 10, accuracy: 0.08 * .pi * 150, "About the ellipse drawn")
    }
}
