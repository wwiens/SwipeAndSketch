import XCTest
@testable import SwipeAndSketchCore

/// The hole checks compare only nearby segments (November 11, 2026); they must answer exactly as
/// comparing every point and segment did, including loops a hair apart.
final class ProfileHoleCheckTests: XCTestCase {
    /// Every segment pair, as `Geometry.loopsCross` did before.
    private func crossEveryPair(_ a: [Point2], _ b: [Point2]) -> Bool {
        for i in a.indices { for j in b.indices where Geometry.segmentsTouch(a[i], a[(i + 1) % a.count], b[j], b[(j + 1) % b.count]) { return true } }
        return false
    }

    /// Every point against the whole outline, as the hole check did before.
    private func insideEveryPoint(_ hole: [Point2], _ outline: [Point2]) -> Bool {
        hole.allSatisfy { Geometry.contains($0, in: outline) && Geometry.distanceToOutline($0, outline) > 1e-6 }
    }

    /// A rounded-looking loop of `count` points about `center`, wobbling by `wobble`.
    private func loop(_ center: Point2, radius: Double, count: Int, wobble: Double, using random: inout SystemRandomNumberGenerator) -> [Point2] {
        (0..<count).map { i in
            let angle = Double(i) / Double(count) * 2 * .pi
            let r = radius * (1 + Double.random(in: -wobble...wobble, using: &random))
            return Point2(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
    }

    func testNearbyChecksAnswerAsCheckingEverything() {
        var random = SystemRandomNumberGenerator()
        var crossings = 0, insides = 0, cases = 0
        for _ in 0..<400 {
            let outline = loop(.init(x: 0, y: 0), radius: 20, count: Int.random(in: 4...130, using: &random), wobble: 0.2, using: &random)
            let radius = Double.random(in: 0.5...8, using: &random)
            // Holes anywhere from well inside to across and outside the outline.
            let center = Point2(x: Double.random(in: -28...28, using: &random), y: Double.random(in: -28...28, using: &random))
            let hole = loop(center, radius: radius, count: Int.random(in: 3...130, using: &random), wobble: 0.1, using: &random)
            XCTAssertEqual(Geometry.loopsCross(outline, hole), crossEveryPair(outline, hole))
            XCTAssertEqual(SketchProfile.isStrictlyInside(hole, outline), insideEveryPoint(hole, outline))
            if crossEveryPair(outline, hole) { crossings += 1 }
            if insideEveryPoint(hole, outline) { insides += 1 }
            cases += 1
        }
        XCTAssertGreaterThan(crossings, 20, "Some holes cross the outline")
        XCTAssertGreaterThan(insides, 20, "Some holes are inside")
        XCTAssertGreaterThan(cases - crossings - insides, 0)
    }

    func testLoopsAHairApart() {
        let square = [Point2(x: 0, y: 0), Point2(x: 10, y: 0), Point2(x: 10, y: 10), Point2(x: 0, y: 10)]
        for gap in [0, 5e-8, 1e-7, 2e-7, 5e-7, 1e-6, 2e-6, 1e-3] {
            // A small square inside, its right side `gap` from the outline's.
            let hole = [Point2(x: 8, y: 4), Point2(x: 10 - gap, y: 4), Point2(x: 10 - gap, y: 6), Point2(x: 8, y: 6)]
            XCTAssertEqual(Geometry.loopsCross(square, hole), crossEveryPair(square, hole), "gap \(gap)")
            XCTAssertEqual(SketchProfile.isStrictlyInside(hole, square), insideEveryPoint(hole, square), "gap \(gap)")
            // And a corner touching from outside.
            let outside = [Point2(x: 10 + gap, y: 4), Point2(x: 12, y: 4), Point2(x: 12, y: 6), Point2(x: 10 + gap, y: 6)]
            XCTAssertEqual(Geometry.loopsCross(square, outside), crossEveryPair(square, outside), "outside gap \(gap)")
            XCTAssertEqual(SketchProfile.isStrictlyInside(outside, square), insideEveryPoint(outside, square), "outside gap \(gap)")
        }
    }
}
