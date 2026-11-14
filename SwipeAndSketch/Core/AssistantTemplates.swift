import Foundation
import simd

/// A deliberately small native recipe catalog. Values are checked before calling the gallery's
/// generator, whose general-purpose entry point otherwise clamps out-of-range parameters.
struct AssistantSlipLidBox: Equatable, Sendable {
    enum Reference: String, Sendable { case inside, outside, closed }
    var reference: Reference
    var width: Double
    var depth: Double
    var height: Double
    var wall: Double? = nil
    var radius: Double? = nil
    var clearance: Double? = nil
    var vents: Bool? = nil

    struct Resolved: Sendable {
        var inside: SIMD3<Double>
        var wall: Double
        var radius: Double
        var clearance: Double
        var vents: Bool
        var defaults: [String]
        var outside: SIMD3<Double> { inside + SIMD3(2 * wall, 2 * wall, wall) }
        var closed: SIMD3<Double> { outside + SIMD3(0, 0, 2) }
        var rimHeight: Double { min(4, inside.z / 2) }
        var parameters: TemplateValues {
            TemplateValues(values: ["width": inside.x, "depth": inside.y, "height": inside.z,
                                    "wall": wall, "radius": radius, "fit": clearance, "vents": vents ? 1 : 0])
        }
        var summary: String {
            "inside \(AssistantSlipLidBox.size(inside)) mm; outside box \(AssistantSlipLidBox.size(outside)) mm; closed enclosure \(AssistantSlipLidBox.size(closed)) mm; wall/floor \(AssistantSlipLidBox.number(wall)) mm; outside corners R\(AssistantSlipLidBox.number(radius)); lid clearance \(AssistantSlipLidBox.number(clearance)) mm per side; vents \(vents ? "on" : "off")"
        }
        var defaultSummary: String { defaults.isEmpty ? "No optional values defaulted." : "Defaults: " + defaults.joined(separator: "; ") + "." }
    }

    static let id = "enclosures.slip-lid-box"
    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never)) }
    private static func size(_ value: SIMD3<Double>) -> String { [value.x, value.y, value.z].map(number).joined(separator: " × ") }
    static let catalog = """
    Native recipe: enclosures.slip-lid-box — Box with Slip-On Lid.
    Makes separate, editable Box and Lid solids in a group, side by side, flat on Z=0. An existing model is preserved and the pair is placed 10 mm to its right.
    reference inside: nominal cavity width/depth/height. outside: outside box body, excluding lid. closed: outside assembled enclosure including a 2 mm lid plate. X=width, Y=depth, Z=height, all mm.
    Native inside ranges: width/depth 10–400, height 5–300 mm. Wall and floor are the same thickness, 1.2–6 mm (default 2). Outside corner radius 0–20 mm (default 4), limited further by the box width/depth; inside corners are rounded by the recipe. Lid clearance is a gap on EACH SIDE, 0.05–0.6 mm (default from project Fit). Vents default off; small lids may not support them.
    Fixed recipe: lid plate 2 mm; rim wall 1.6 mm; rim height min(4, inside height/2) mm. Different floor/lid/rim dimensions, explicit vent counts, and other lid types are unsupported by this recipe. Never silently substitute values. Nominal cavity bounds do not prove a rectangular object clears its rounded corners. The output has ordinary editable geometry, without a live link to template settings.
    """

    /// The cavity a size measured against `reference` leaves with walls (and floor) `wall` thick.
    static func inside(_ size: SIMD3<Double>, _ reference: Reference, wall: Double) -> SIMD3<Double> {
        reference == .inside ? size : size - SIMD3(2 * wall, 2 * wall, wall + (reference == .closed ? 2 : 0))
    }
    static var defaultWall: Double { BoxTemplates.templates.first { $0.id == id }?.defaults["wall"] ?? 2 }

    func resolved() throws -> Resolved {
        guard let template = BoxTemplates.templates.first(where: { $0.id == Self.id }) else {
            throw AssistantWorkbench.Failure("The slip-on lid template is unavailable.")
        }
        guard [width, depth, height].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw AssistantWorkbench.Failure("Width, depth, and height must be positive finite millimeters.")
        }
        let defaults = template.defaults
        let w = wall ?? defaults["wall"], r = radius ?? defaults["radius"], fit = clearance ?? defaults["fit"]
        var inside = Self.inside(SIMD3(width, depth, height), reference, wall: w)
        if reference != .inside {
            // Decimal subtraction can put a mathematically exact boundary a few ULPs outside
            // its range (closed 8.2 minus wall 1.2 minus lid 2). Only normalize arithmetic noise
            // in derived dimensions; explicit unsupported values are still rejected.
            for axis in 0..<3 { for boundary in axis == 2 ? [5.0, 300] : [10.0, 400] {
                if abs(inside[axis] - boundary) <= 8 * max(1, abs(boundary)) * Double.ulpOfOne { inside[axis] = boundary }
            } }
        }
        var chosen: [String] = []
        if wall == nil { chosen.append("wall/floor \(AssistantWorkbench.mm(w)) mm") }
        if radius == nil { chosen.append("outside corners R\(AssistantWorkbench.mm(r))") }
        if clearance == nil { chosen.append("Fit clearance \(AssistantWorkbench.mm(fit)) mm per side") }
        if vents == nil { chosen.append("vents off") }
        let result = Resolved(inside: inside, wall: w, radius: r, clearance: fit, vents: vents ?? false, defaults: chosen)
        for parameter in template.parameters {
            let value = result.parameters[parameter.id]
            guard value.isFinite, parameter.clamped(value) == value else {
                throw AssistantWorkbench.Failure("Unsupported \(parameter.title) (\(AssistantWorkbench.mm(value)) mm) for the slip-on lid template. Inside width/depth must be 10–400 mm, inside height 5–300 mm, wall/floor 1.2–6 mm, radius 0–20 mm, and per-side clearance 0.05–0.6 mm. No values were changed.")
            }
        }
        let limit = min(result.outside.x, result.outside.y) / 2 - 1
        guard r <= limit || r - limit <= 8 * max(1, abs(limit)) * Double.ulpOfOne else {
            throw AssistantWorkbench.Failure("Outside corner radius \(AssistantWorkbench.mm(r)) mm exceeds the \(AssistantWorkbench.mm(limit)) mm limit at this size. No values were changed.")
        }
        guard !result.vents || inside.y - 2 * fit - 3.2 - 8 >= 6 else {
            throw AssistantWorkbench.Failure("This lid is too small for the recipe's vent slots. No values were changed; omit vents or increase inside depth.")
        }
        return result
    }

    func make() throws -> (workspace: Workspace, resolved: Resolved) {
        let resolved = try resolved()
        guard let template = BoxTemplates.templates.first(where: { $0.id == Self.id }),
              template.clamped(resolved.parameters) == resolved.parameters else {
            throw AssistantWorkbench.Failure("The template would change a requested value. No parts were made.")
        }
        let workspace = try template.workspace(resolved.parameters)
        guard workspace.bodies.count == 2 else { throw AssistantWorkbench.Failure("The template did not make both parts.") }
        for body in workspace.bodies {
            guard try SolidKernel.solid(for: body).isValidSolid else { throw AssistantWorkbench.Failure("The template did not make valid closed solids.") }
        }
        return (workspace, resolved)
    }
}
