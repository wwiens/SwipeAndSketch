import Foundation
import CoreGraphics
import Vision

// Pictures traced into outlines: the dark (or, inverted, the light) parts of an image become
// closed areas, with holes where the picture has them. Used for pictures embedded in SVG files.
// Transparent pictures are traced by their opaque parts.

enum ImageTracing {
    struct Options: Equatable, Sendable {
        /// 0…1: how dark a pixel must be to count as part of a shape (how opaque, for pictures
        /// with transparency).
        var threshold = 0.5
        /// Trace the light parts instead.
        var invert = false
    }

    /// The traced outlines of `image` in the unit square (Y down, as the image's rows run),
    /// as a filled area. Nil when nothing is traced.
    static func trace(_ image: CGImage, options: Options) -> CGPath? {
        guard let mask = mask(image, options: options) else { return nil }
        let request = VNDetectContoursRequest()
        // The mask is already black on white; no contrast games.
        request.contrastAdjustment = 1
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024
        let handler = VNImageRequestHandler(cgImage: mask, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        let path = CGMutablePath()
        // Vision's points are 0…1 with Y up; a pixel's worth of simplification keeps steps out.
        let epsilon = Float(1.0 / Double(max(mask.width, mask.height)))
        for contour in observation.topLevelContours { add(contour, to: path, epsilon: epsilon, depth: 0) }
        guard path.hasSegments else { return nil }
        return path.normalized(using: .evenOdd)
    }

    private static func add(_ contour: VNContour, to path: CGMutablePath, epsilon: Float, depth: Int) {
        guard depth < 64 else { return }
        if let simple = try? contour.polygonApproximation(epsilon: epsilon), simple.pointCount >= 3 {
            let points = simple.normalizedPoints.map { CGPoint(x: Double($0.x), y: 1 - Double($0.y)) }
            smooth(points, into: path)
        }
        for child in contour.childContours { add(child, to: path, epsilon: epsilon, depth: depth + 1) }
    }

    /// A closed polygon as a smooth curve through its corners (Catmull-Rom as cubic Béziers), so
    /// traced outlines fit to arcs instead of pixel steps. Where the outline turns more than 45°
    /// at a point it keeps a corner there, and a side between two corners stays straight.
    static func smooth(_ points: [CGPoint], into path: CGMutablePath) {
        let n = points.count
        guard n >= 3 else { return }
        let corner: [Bool] = (0..<n).map { i in
            let a = points[(i - 1 + n) % n], b = points[i], c = points[(i + 1) % n]
            let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
            guard lu > 0, lv > 0 else { return true }
            return (u.x * v.x + u.y * v.y) / (lu * lv) < cos(Double.pi / 4)
        }
        // The tangent leaving point i toward i + 1 (or arriving from i - 1): one-sided at a corner.
        func tangent(_ i: Int, toward next: Bool) -> CGPoint {
            let previous = points[(i - 1 + n) % n], point = points[i], following = points[(i + 1) % n]
            if corner[i] {
                return next ? CGPoint(x: following.x - point.x, y: following.y - point.y) : CGPoint(x: point.x - previous.x, y: point.y - previous.y)
            }
            return CGPoint(x: (following.x - previous.x) / 2, y: (following.y - previous.y) / 2)
        }
        path.move(to: points[0])
        for i in 0..<n {
            let j = (i + 1) % n, p1 = points[i], p2 = points[j]
            if corner[i] && corner[j] {
                path.addLine(to: p2)
                continue
            }
            let m1 = tangent(i, toward: true), m2 = tangent(j, toward: false)
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + m1.x / 3, y: p1.y + m1.y / 3),
                          control2: CGPoint(x: p2.x - m2.x / 3, y: p2.y - m2.y / 3))
        }
        path.closeSubpath()
    }

    /// A black-on-white picture of what counts as a shape.
    static func mask(_ image: CGImage, options: Options) -> CGImage? {
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        // Drawn on white, so transparent pixels read as background.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // With transparency, opacity decides; otherwise brightness does.
        var hasTransparency = false
        for index in stride(from: 3, to: width * height * 4, by: 4) where pixels[index] < 250 { hasTransparency = true; break }
        let threshold = min(0.99, max(0.01, options.threshold))
        var shapes = 0
        for index in 0..<(width * height) {
            let r = Double(pixels[index * 4]), g = Double(pixels[index * 4 + 1]), b = Double(pixels[index * 4 + 2]), a = Double(pixels[index * 4 + 3])
            var inside: Bool
            if hasTransparency {
                inside = a / 255 >= threshold
                if options.invert { inside = !inside }
            } else {
                let luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                inside = luminance < threshold
                if options.invert { inside = !inside }
            }
            if inside { shapes += 1 }
            let value: UInt8 = inside ? 0 : 255
            pixels[index * 4] = value; pixels[index * 4 + 1] = value; pixels[index * 4 + 2] = value; pixels[index * 4 + 3] = 255
        }
        guard shapes > 0, shapes < width * height else { return nil }
        return context.makeImage()
    }
}
