import Foundation
import simd

// Project templates: New Project opens a gallery of starting
// points for common 3D-printing projects (Gridfinity storage, mounts and cases for electronics
// boards, boxes with lids). Each template is set up with a few sizes and choices before it is
// made, and comes out as ordinary named solids in a Model Tree group, with no link back to the
// template: once made, they are edited like anything drawn by hand. Templates are built here, in
// code, from the same solid definitions the tools make (extrusions, tapered cuts, holes), so they
// need no file format of their own and every one is checked by Tests/CoreTests/TemplateTests.swift.

/// A size or choice a template is set up with.
struct TemplateParameter: Identifiable, Sendable {
    enum Kind: Sendable {
        /// Whole numbers, such as grid units or dividers.
        case count(ClosedRange<Int>)
        /// Millimeters, moved by `step` with the stepper.
        case length(ClosedRange<Double>, step: Double)
        /// One of several options; the value is the option's index.
        case choice([String])
        /// On (1) or off (0).
        case toggle
    }
    var id: String
    var title: String
    var kind: Kind
    var defaultValue: Double
    /// A short explanation shown under the control. Omitted when the title says enough.
    var note: String?
    /// Whether the control applies to the current values (a custom board's sizes only show for the
    /// custom board).
    var isShown: @Sendable (TemplateValues) -> Bool = { _ in true }

    /// The value made valid for this parameter: within range, whole where it counts.
    func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        switch kind {
        case .count(let range): return Double(min(max(Int(value.rounded()), range.lowerBound), range.upperBound))
        case .length(let range, _): return min(max(value, range.lowerBound), range.upperBound)
        case .choice(let options): return Double(min(max(Int(value.rounded()), 0), options.count - 1))
        case .toggle: return value >= 0.5 ? 1 : 0
        }
    }
}

/// The values a template is set up with, by parameter id.
struct TemplateValues: Equatable, Sendable {
    var values: [String: Double] = [:]
    subscript(_ id: String) -> Double {
        get { values[id] ?? 0 }
        set { values[id] = newValue }
    }
    func count(_ id: String) -> Int { Int(self[id].rounded()) }
    func flag(_ id: String) -> Bool { self[id] >= 0.5 }
    func choice(_ id: String) -> Int { Int(self[id].rounded()) }
}

/// One solid a template makes, with its Model Tree name.
struct TemplatePart: Sendable {
    var name: String
    var body: SolidBody
}

/// A starting point in the New Project gallery.
struct ProjectTemplate: Identifiable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case gridfinity, electronics, enclosures
        var title: String {
            switch self { case .gridfinity: "Gridfinity"; case .electronics: "Electronics"; case .enclosures: "Boxes & Enclosures" }
        }
        var summary: String {
            switch self {
            case .gridfinity: "Modular storage on a 42 mm grid: baseplates and the bins that click into them."
            case .electronics: "Mounting plates and cases sized to the holes of common boards."
            case .enclosures: "Boxes sized by their inside, with lids that screw on or slip on."
            }
        }
        /// Credit and trademark notices shown with the category's templates (October 26, 2026).
        var notice: String? {
            switch self {
            case .gridfinity: Self.gridfinityCredit
            case .electronics: Self.boardTrademarks
            case .enclosures: nil
            }
        }
        static let gridfinityCredit = "Gridfinity is the open modular storage system created by Zack Freedman (Voidstar Lab) and released under the MIT License. Swipe & Sketch is not affiliated with or endorsed by Zack Freedman or Voidstar Lab."
        static let boardTrademarks = "Raspberry Pi is a trademark of Raspberry Pi Ltd. Arduino® is a trademark of Arduino S.r.l. Swipe & Sketch is not affiliated with or endorsed by either."
    }
    var id: String
    var category: Category
    var title: String
    var summary: String
    var parameters: [TemplateParameter]
    /// The project's suggested file name for these values.
    var name: @Sendable (TemplateValues) -> String
    var make: @Sendable (TemplateValues) throws -> [TemplatePart]
    /// Making it needs Swipe & Sketch Pro; only the plain Gridfinity Baseplate and Bin are
    /// free. A template is free or Pro as a whole, never one option inside it.
    var needsPro = true

    var defaults: TemplateValues {
        TemplateValues(values: Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) }))
    }

    /// `values` made valid: every parameter present and within its range.
    func clamped(_ values: TemplateValues) -> TemplateValues {
        TemplateValues(values: Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.clamped(values.values[$0.id] ?? $0.defaultValue)) }))
    }

    /// A new project's model: the template's solids, named, in a group named after the project.
    func workspace(_ values: TemplateValues) throws -> Workspace {
        let values = clamped(values)
        let parts = try make(values)
        guard !parts.isEmpty else { throw TemplateError.failed(title) }
        let group = ItemGroup(name: ItemNames.cleaned(name(values)))
        var workspace = Workspace()
        workspace.groups = [group]
        for part in parts {
            var body = part.body
            body.name = ItemNames.cleaned(part.name)
            body.group = group.id
            workspace.bodies.append(body)
        }
        guard workspace.isValid else { throw TemplateError.failed(title) }
        return workspace
    }
}

// MARK: Gallery pictures

extension ProjectTemplate {
    /// The gallery card's picture in the asset catalog (Assets.xcassets/Templates), drawn at the
    /// template's defaults by Scripts/render_template_pictures.sh so the gallery opens at once.
    var pictureName: String { "template-" + id.replacingOccurrences(of: ".", with: "-") }

    /// The defaults the pictures are drawn at: the standard Fit, whatever this iPad's preference.
    var pictureValues: TemplateValues {
        var values = defaults
        if values.values["fit"] != nil { values["fit"] = Fit.defaultClearance }
        return values
    }

    /// What the template makes at `pictureValues`, in short: each solid's name, volume, and size.
    /// Tests/Fixtures/TemplatePictures.json records it for each picture, so a test notices when a
    /// template has changed and its picture needs drawing again.
    func pictureFingerprint() throws -> String {
        try workspace(pictureValues).bodies.map { body in
            let solid = try SolidKernel.solid(for: body)
            let size = solid.bounds.max - solid.bounds.min
            return String(format: "%@ %.1f mm³ %.2f×%.2f×%.2f", body.name ?? "", solid.volume, size.x, size.y, size.z)
        }.joined(separator: "; ")
    }
}

enum TemplateError: LocalizedError, Equatable {
    /// The kernel could not make the template's solids.
    case failed(String)
    /// The sizes do not leave room for a feature; the message says which.
    case tooSmall(String)
    var errorDescription: String? {
        switch self {
        case .failed(let title): "The \(title) could not be made with these sizes. Try other values."
        case .tooSmall(let message): message
        }
    }
}

enum TemplateCatalog {
    /// Every template, in gallery order. Computed, so templates that start from an app preference
    /// (the Fit clearance) read its current value.
    static var all: [ProjectTemplate] { Gridfinity.templates + BoardTemplates.templates + BoxTemplates.templates }

    static func template(_ id: String) -> ProjectTemplate? { all.first { $0.id == id } }
}

// MARK: Geometry

/// Profiles and steps the templates are built from, in world millimeters with Z up.
enum TemplateGeometry {
    /// The horizontal plane at height `z`, its normal up (or down, for holes drilled from below).
    static func horizontal(_ z: Double, facingDown: Bool = false) -> SketchPlane {
        SketchPlane.through(SIMD3(0, 0, z), normal: SIMD3(0, 0, facingDown ? -1 : 1)) ?? .top
    }

    /// A rectangle with rounded corners, centered at world (x, y) on a horizontal `plane`, as an
    /// exact profile (each corner a true arc). A radius of 0 gives sharp corners.
    static func roundedRectangle(center: Point2 = .zero, width: Double, depth: Double, radius: Double, on plane: SketchPlane) -> SketchProfile {
        roundedRectangle(center: center, width: width, depth: depth, radii: [radius, radius, radius, radius], on: plane)
    }

    /// The same with a radius for each corner, counterclockwise from the lower right (in world x and y).
    static func roundedRectangle(center: Point2 = .zero, width: Double, depth: Double, radii: [Double], on plane: SketchPlane) -> SketchProfile {
        let loop = roundedLoop(center: center, width: width, depth: depth, radii: radii, on: plane)
        return SketchProfile(id: "template", plane: plane, sourceIDs: [], outline: loop.outline, arcs: loop.arcs)
    }

    /// A circle of `diameter` centered at world (x, y) on a horizontal `plane`.
    /// The kernel builds the exact circle; `points` only draw it (fewer keep big regions quick to check).
    static func circle(_ diameter: Double, at center: Point2, on plane: SketchPlane, points: Int = 128) -> SketchProfile {
        let c = plane.coordinates(of: SIMD3(center.x, center.y, 0))
        let outline = (0..<points).map { i -> Point2 in
            let a = Double(i) * 2 * .pi / Double(points)
            return c + Point2(x: cos(a), y: sin(a)) * (diameter / 2)
        }
        return SketchProfile(id: "template", plane: plane, sourceIDs: [], outline: outline, circle: CircleProfile(center: c, radius: diameter / 2))
    }

    /// `outer` with `holes` taken out of it: a region the kernel extrudes (and tapers) in one step.
    static func region(_ outer: SketchProfile, holes: [SketchProfile]) -> SketchProfile {
        var region = outer
        region.holes = holes.isEmpty ? nil : holes.map { ProfileHole(outline: $0.outline, circle: $0.circle, arcs: $0.arcs) }
        return region
    }

    /// A counterclockwise rounded-rectangle loop in `plane` coordinates.
    private static func roundedLoop(center: Point2, width: Double, depth: Double, radii: [Double], on plane: SketchPlane) -> (outline: [Point2], arcs: [ProfileArc]?) {
        // World XY to plane coordinates: planes facing down mirror one axis, so build the loop in
        // world terms and keep it counterclockwise about the plane's own normal.
        func local(_ p: Point2) -> Point2 { plane.coordinates(of: SIMD3(p.x, p.y, 0)) }
        let hx = width / 2, hy = depth / 2
        var world: [Point2] = []
        var arcs: [ProfileArc] = []
        let segments = 8
        // Each corner, its direction from the center, and where its arc starts turning.
        let corners: [(Point2, Double)] = [(Point2(x: 1, y: -1), -Double.pi / 2), (Point2(x: 1, y: 1), 0),
                                           (Point2(x: -1, y: 1), Double.pi / 2), (Point2(x: -1, y: -1), Double.pi)]
        for (index, (sign, from)) in corners.enumerated() {
            let r = min(max(0, radii[index % radii.count]), min(width, depth) / 2 - 0.01)
            let corner = Point2(x: sign.x * hx, y: sign.y * hy)
            guard r >= 0.01 else { world.append(center + corner); continue }
            let arcCenter = center + corner - Point2(x: sign.x * r, y: sign.y * r)
            let start = world.count
            for step in 0...segments {
                let a = from + Double.pi / 2 * Double(step) / Double(segments)
                world.append(arcCenter + Point2(x: cos(a), y: sin(a)) * r)
            }
            arcs.append(ProfileArc(start: start, segments: segments, center: arcCenter, radius: r))
        }
        var outline = world.map(local)
        let flipped = Geometry.signedArea(outline) < 0
        if flipped {
            // Reverse the loop and renumber its arcs from the new start.
            let n = outline.count
            outline.reverse()
            arcs = arcs.map { arc in
                let end = (arc.start + arc.segments) % n
                return ProfileArc(start: n - 1 - end, segments: arc.segments, center: local(arc.center), radius: arc.radius)
            }
        } else {
            arcs = arcs.map { ProfileArc(start: $0.start, segments: $0.segments, center: local($0.center), radius: $0.radius) }
        }
        return (outline, arcs.isEmpty ? nil : arcs)
    }

    /// A solid extruded `height` up from `z` (the profile's plane must be the plane at `z`).
    static func block(_ profile: SketchProfile, height: Double, taper: Double = 0) -> SolidBody {
        var body = SolidBody(profile: profile, depth: height)
        if taper != 0 { body.taper = taper }
        return body
    }

    /// A cut (or, with `join`, a boss) of `profile` extruded `depth` along its plane's normal.
    static func step(_ profile: SketchProfile, depth: Double, taper: Double = 0, join: Bool = false) -> ExtrusionCut {
        var cut = ExtrusionCut(profile: profile, depth: depth, operation: join ? .join : .cut)
        if taper != 0 { cut.taper = taper }
        return cut
    }

    /// A cut through the whole solid both ways from its plane.
    static func through(_ profile: SketchProfile) -> ExtrusionCut {
        ExtrusionCut(profile: profile, depth: 1, throughAll: true)
    }

    /// A drilled hole at world (x, y) entering the face on `plane` (its normal pointing out of the
    /// solid), `depth` deep or through when nil.
    static func hole(_ spec: HoleSpec, at point: Point2, on plane: SketchPlane, depth: Double?) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: circle(spec.diameter, at: point, on: plane), depth: depth ?? 1, throughAll: depth == nil)
        operation.hole = spec
        return operation
    }

    /// A plain round hole of `diameter`.
    static func plainHole(_ diameter: Double, label: String) -> HoleSpec {
        HoleSpec(kind: .simple, size: label, diameter: diameter)
    }
}
