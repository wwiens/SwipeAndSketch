import Foundation
import CoreGraphics

// SVG import, part 2: path data and the basic shapes as Core Graphics paths, in the element's
// own coordinates. A path with a mistake in it is read up to the mistake, as SVG renders it.

enum SVGPathData {
    /// The path a `d` attribute describes: M, L, H, V, C, S, Q, T, A, and Z, absolute and relative,
    /// with repeated coordinates continuing the command before (implicit lines after a move).
    static func path(_ data: String) -> CGMutablePath {
        let path = CGMutablePath()
        var scanner = SVGValues.NumberScanner(Substring(data))
        var current = CGPoint.zero, start = CGPoint.zero
        // The last control point, for S and T, and which kind of curve set it.
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var command: UInt8 = 0
        var open = false
        func ensureStarted() {
            if !open { path.move(to: current); open = true }
        }
        func number() -> Double? { scanner.next() }
        func point(_ relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        loop: while true {
            scanner.skipSeparators()
            guard let byte = scanner.peek else { break }
            if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
                command = byte
                scanner.index += 1
            } else if command == 0 {
                break
            } else if command == 0x4D { command = 0x4C } else if command == 0x6D { command = 0x6C }
            let relative = command >= 0x61
            switch command | 0x20 {
            case 0x6D: // m
                guard let p = point(relative) else { break loop }
                path.move(to: p); current = p; start = p; open = true
                lastCubic = nil; lastQuad = nil
                // Coordinates after a move are lines.
                command = relative ? 0x6C : 0x4C
                continue
            case 0x6C: // l
                guard let p = point(relative) else { break loop }
                ensureStarted(); path.addLine(to: p); current = p
                lastCubic = nil; lastQuad = nil
            case 0x68: // h
                guard let x = number() else { break loop }
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                ensureStarted(); path.addLine(to: p); current = p
                lastCubic = nil; lastQuad = nil
            case 0x76: // v
                guard let y = number() else { break loop }
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                ensureStarted(); path.addLine(to: p); current = p
                lastCubic = nil; lastQuad = nil
            case 0x63: // c
                let base = current
                guard let c1 = point(relative) else { break loop }
                current = base
                guard let c2 = point(relative) else { break loop }
                current = base
                guard let p = point(relative) else { break loop }
                ensureStarted(); path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastCubic = c2; lastQuad = nil
            case 0x73: // s
                let base = current
                let c1 = lastCubic.map { CGPoint(x: 2 * base.x - $0.x, y: 2 * base.y - $0.y) } ?? base
                guard let c2 = point(relative) else { break loop }
                current = base
                guard let p = point(relative) else { break loop }
                ensureStarted(); path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastCubic = c2; lastQuad = nil
            case 0x71: // q
                let base = current
                guard let c = point(relative) else { break loop }
                current = base
                guard let p = point(relative) else { break loop }
                ensureStarted(); path.addQuadCurve(to: p, control: c)
                current = p; lastQuad = c; lastCubic = nil
            case 0x74: // t
                let base = current
                let c = lastQuad.map { CGPoint(x: 2 * base.x - $0.x, y: 2 * base.y - $0.y) } ?? base
                guard let p = point(relative) else { break loop }
                ensureStarted(); path.addQuadCurve(to: p, control: c)
                current = p; lastQuad = c; lastCubic = nil
            case 0x61: // a
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point(relative) else { break loop }
                ensureStarted()
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p; lastCubic = nil; lastQuad = nil
            case 0x7A: // z
                if open { path.closeSubpath() }
                current = start; open = false
                lastCubic = nil; lastQuad = nil
                command = 0
                continue
            default:
                break loop
            }
        }
        return path
    }

    /// An elliptical arc in SVG's endpoint form, added as cubic curves of at most a quarter turn
    /// (SVG 1.1 appendix F.6.5 and F.6.6: out-of-range radii are scaled up to reach).
    static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator > 0 ? max(0, numerator / denominator).squareRoot() : 0
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let pieces = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(pieces)
        let k = 4.0 / 3 * tan(step / 4)
        func onEllipse(_ t: Double) -> (point: CGPoint, derivative: CGPoint) {
            let ct = cos(t), st = sin(t)
            let point = CGPoint(x: cx + rx * ct * cosPhi - ry * st * sinPhi, y: cy + rx * ct * sinPhi + ry * st * cosPhi)
            let derivative = CGPoint(x: -rx * st * cosPhi - ry * ct * sinPhi, y: -rx * st * sinPhi + ry * ct * cosPhi)
            return (point, derivative)
        }
        var t = theta1
        for index in 0..<pieces {
            let a = onEllipse(t), b = onEllipse(t + step)
            let c1 = CGPoint(x: a.point.x + k * a.derivative.x, y: a.point.y + k * a.derivative.y)
            let c2 = CGPoint(x: b.point.x - k * b.derivative.x, y: b.point.y - k * b.derivative.y)
            path.addCurve(to: index == pieces - 1 ? p1 : b.point, control1: c1, control2: c2)
            t += step
        }
    }
}

/// The basic shapes, in their own coordinates; nil when one draws nothing (a zero radius or size).
enum SVGShapes {
    /// `viewport` sizes percentages: widths against its width, heights against its height, and
    /// radii against its normalized diagonal.
    static func path(for node: SVGNode, viewport: CGSize, fontSize: Double) -> CGPath? {
        let diagonal = (viewport.width * viewport.width + viewport.height * viewport.height).squareRoot() / 2.0.squareRoot()
        func x(_ name: String) -> Double { SVGValues.userLength(node[name], reference: viewport.width, fontSize: fontSize) ?? 0 }
        func y(_ name: String) -> Double { SVGValues.userLength(node[name], reference: viewport.height, fontSize: fontSize) ?? 0 }
        func r(_ name: String) -> Double? { SVGValues.userLength(node[name], reference: diagonal, fontSize: fontSize) }
        switch node.name {
        case "path":
            guard let d = node["d"] else { return nil }
            let path = SVGPathData.path(d)
            return path.isEmpty ? nil : path
        case "rect":
            let width = x("width"), height = y("height")
            guard width > 0, height > 0 else { return nil }
            var rx = SVGValues.userLength(node["rx"], reference: viewport.width, fontSize: fontSize)
            var ry = SVGValues.userLength(node["ry"], reference: viewport.height, fontSize: fontSize)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cornerX = min(max(0, rx ?? 0), width / 2), cornerY = min(max(0, ry ?? 0), height / 2)
            let rect = CGRect(x: x("x"), y: y("y"), width: width, height: height)
            guard cornerX > 0, cornerY > 0 else { return CGPath(rect: rect, transform: nil) }
            // Core Graphics wants each corner strictly under half a side.
            return CGPath(roundedRect: rect, cornerWidth: min(cornerX, width / 2 - 1e-9), cornerHeight: min(cornerY, height / 2 - 1e-9), transform: nil)
        case "circle":
            guard let radius = r("r"), radius > 0 else { return nil }
            let cx = x("cx"), cy = y("cy")
            return CGPath(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: 2 * radius, height: 2 * radius), transform: nil)
        case "ellipse":
            var rx = SVGValues.userLength(node["rx"], reference: viewport.width, fontSize: fontSize)
            var ry = SVGValues.userLength(node["ry"], reference: viewport.height, fontSize: fontSize)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            guard let rx, let ry, rx > 0, ry > 0 else { return nil }
            let cx = x("cx"), cy = y("cy")
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x("x1"), y: y("y1")))
            path.addLine(to: CGPoint(x: x("x2"), y: y("y2")))
            return path
        case "polyline", "polygon":
            let values = SVGValues.numbers(node["points"] ?? "")
            guard values.count >= 4 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: values[0], y: values[1]))
            for index in stride(from: 2, to: values.count - 1, by: 2) { path.addLine(to: CGPoint(x: values[index], y: values[index + 1])) }
            if node.name == "polygon" { path.closeSubpath() }
            return path
        default:
            return nil
        }
    }

    static let names: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]
}

extension CGPath {
    /// Whether it has any segments at all.
    var hasSegments: Bool {
        var any = false
        applyWithBlock { element in if element.pointee.type != .moveToPoint { any = true } }
        return any
    }
}
