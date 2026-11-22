import Foundation
import SSKernel
import simd

// Merge, shell, and hole presets: operations stored in a solid's ordered `cuts` list (schema 6).

/// A flat face of the original extrusion, named by its role so it survives edits that renumber
/// kernel faces: the base on the sketch plane, the cap at the far end, or the side along
/// profile segment `index` (polygon profiles only). Matched by plane when the solid is rebuilt.
struct ExtrusionFace: Codable, Hashable, Sendable {
    enum Position: String, Codable, Sendable { case base, cap, side }
    var position: Position
    var index: Int
}

/// Hollow a solid inward to `thickness`, leaving `openFaces` open. At least one face must be
/// open: a fully enclosed hollow would trap material inside a print (and OCCT's thick-solid
/// algorithm does not build one reliably).
struct ShellSpec: Codable, Equatable, Sendable {
    /// Original extrusion faces left open, by name (schema 6).
    var openFaces: [ExtrusionFace]
    var thickness: Double
    /// Any other faces left open (schema 13): a point on each, in the solid's own frame (along its
    /// profile plane's x and y axes and normal), so it moves with the solid. Omitted when empty.
    var openPoints: [SIMD3<Double>]?

    var isValid: Bool {
        let points = openPoints ?? []
        return thickness.isFinite && thickness >= 0.2 && thickness <= 100 && !(openFaces.isEmpty && points.isEmpty) &&
            openFaces.count + points.count <= 64 && Set(openFaces).count == openFaces.count &&
            points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_length($0) <= 100_000 }
    }
}

/// A drilled hole. The owning operation's profile is the hole's circle on the face it enters,
/// and its depth (or through-all) how far it goes, measured into the solid along −normal.
struct HoleSpec: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case simple, counterbore, countersink, insert, nutTrap, magnet
        var title: String {
            switch self {
            case .simple: "Simple"; case .counterbore: "Counterbore"; case .countersink: "Countersink"; case .insert: "Insert"
            case .nutTrap: "Nut Trap"; case .magnet: "Magnet"
            }
        }
        /// Sized by a screw (metric or inch); a magnet pocket is sized by its magnet.
        var isScrew: Bool { self != .magnet }
        /// Starts as a blind hole (an insert or a magnet), not through.
        var startsBlind: Bool { self == .insert || self == .magnet }

        /// A kind named loosely, as the assistant or a person might: any case, with or without
        /// spaces, dashes, or underscores ("nut trap", "NUT_TRAP", "heat-set insert", "nut").
        init?(loose text: String) {
            let key = text.lowercased().filter { $0.isLetter }
            let aliases: [String: Kind] = ["nut": .nutTrap, "hexnut": .nutTrap, "heatsetinsert": .insert, "heatset": .insert,
                                           "magnetpocket": .magnet, "cbore": .counterbore, "csink": .countersink]
            guard let kind = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) ?? aliases[key] else { return nil }
            self = kind
        }
    }
    var kind: Kind
    /// Preset label such as "M3", "1/4", or "6×2" (a magnet); the dimensions below are what is
    /// built and may be edited.
    var size: String
    var diameter: Double
    var counterboreDiameter: Double = 0
    var counterboreDepth: Double = 0
    var countersinkDiameter: Double = 0
    var countersinkAngle: Double = 90
    /// Nut traps (November 21, 2026): the hex pocket at the face, across its flats (the nut's width
    /// plus the fit clearance on each side), how deep it goes, and its turn in degrees (0 puts two
    /// flats along the face's x axis). Omitted from files for other kinds.
    var nutAcrossFlats: Double?
    var nutDepth: Double?
    var nutAngle: Double?

    var isValid: Bool {
        let values = [diameter, counterboreDiameter, counterboreDepth, countersinkDiameter, countersinkAngle]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), diameter >= 0.1, diameter <= 200 else { return false }
        switch kind {
        case .simple, .insert, .magnet: return true
        case .counterbore: return counterboreDiameter > diameter && counterboreDepth > 0
        case .countersink: return countersinkDiameter > diameter && countersinkAngle > 1 && countersinkAngle < 179
        case .nutTrap:
            guard let flats = nutAcrossFlats, let depth = nutDepth, flats.isFinite, depth.isFinite, (nutAngle ?? 0).isFinite else { return false }
            return flats > diameter && flats <= 200 && depth > 0 && depth <= 200
        }
    }

    /// A nut trap's hex pocket corners around `center` on the face, counter-clockwise.
    func nutCorners(around center: Point2) -> [Point2] {
        guard kind == .nutTrap, let flats = nutAcrossFlats else { return [] }
        let radius = flats / 3.0.squareRoot(), start = (nutAngle ?? 0) * .pi / 180
        return (0..<6).map { k in
            let angle = start + Double(k) * .pi / 3
            return center + Point2(x: radius * cos(angle), y: radius * sin(angle))
        }
    }

    /// Widest across the face: what the hole takes up where it starts.
    var outerDiameter: Double {
        switch kind {
        case .counterbore: counterboreDiameter
        case .countersink: countersinkDiameter
        case .nutTrap: (nutAcrossFlats ?? 0) * 2 / 3.0.squareRoot()
        default: diameter
        }
    }
}

/// Starting dimensions for hobby hardware (all editable).
/// - Metric: clearance follows ISO 273 "normal" fit; counterbores fit ISO 4762 socket heads; countersinks
///   fit ISO 10642 90° flat heads; nut traps fit ISO 4032 hex nuts.
/// - Inch (November 21, 2026): clearance near the ASME B18.2.8 normal fit; counterbores fit ASME B18.3 socket
///   heads; countersinks fit 82° flat heads; nut traps fit finished hex nuts.
/// - Insert holes suit common brass heat-set inserts (check your insert's datasheet).
/// - Magnet pockets (November 21, 2026) fit round disc magnets, diameter × thickness.
/// Nut traps and magnet pockets widen by the fit clearance on each side (the app's Fit preference).
enum HolePresets {
    static let metricSizes = ["M2", "M2.5", "M3", "M4", "M5", "M6", "M8"]
    static let inchSizes = ["#4", "#6", "#8", "#10", "1/4"]
    /// Screw sizes, for every kind but magnets.
    static let sizes = metricSizes + inchSizes
    static let magnetSizes = ["6×2", "6×3", "8×3", "10×2", "10×3", "12×3"]

    private static let clearance: [String: Double] = [
        "M2": 2.4, "M2.5": 2.9, "M3": 3.4, "M4": 4.5, "M5": 5.5, "M6": 6.6, "M8": 9.0,
        "#4": 3.5, "#6": 4.0, "#8": 4.6, "#10": 5.2, "1/4": 6.7]
    private static let counterbore: [String: (Double, Double)] = [
        "M2": (4.4, 2.4), "M2.5": (5.1, 2.9), "M3": (6.1, 3.4), "M4": (7.6, 4.4), "M5": (9.1, 5.4), "M6": (10.6, 6.4), "M8": (13.6, 8.4),
        "#4": (5.3, 3.3), "#6": (6.4, 3.9), "#8": (7.5, 4.6), "#10": (8.5, 5.2), "1/4": (10.1, 6.8)]
    private static let countersink: [String: Double] = [
        "M2": 4.4, "M2.5": 5.4, "M3": 6.4, "M4": 8.4, "M5": 10.4, "M6": 12.4, "M8": 16.4,
        "#4": 6.4, "#6": 7.6, "#8": 8.9, "#10": 10.2, "1/4": 13.2]
    private static let insert: [String: (diameter: Double, depth: Double)] = [
        "M2": (3.2, 5.0), "M2.5": (3.6, 6.7), "M3": (4.0, 6.7), "M4": (5.6, 9.1), "M5": (6.4, 10.5), "M6": (8.0, 13.7), "M8": (9.7, 13.7),
        "#4": (4.0, 6.0), "#6": (4.8, 7.0), "#8": (5.6, 8.0), "#10": (6.4, 9.5), "1/4": (8.0, 13.7)]
    /// Hex nut thickness (ISO 4032 maximum; finished inch nuts).
    private static let nutThickness: [String: Double] = [
        "M2": 1.6, "M2.5": 2.0, "M3": 2.4, "M4": 3.2, "M5": 4.7, "M6": 5.2, "M8": 6.8,
        "#4": 2.38, "#6": 2.78, "#8": 3.18, "#10": 3.18, "1/4": 5.56]
    /// Disc magnets, diameter and thickness.
    private static let magnets: [String: (diameter: Double, thickness: Double)] = [
        "6×2": (6, 2), "6×3": (6, 3), "8×3": (8, 3), "10×2": (10, 2), "10×3": (10, 3), "12×3": (12, 3)]

    /// The sizes offered for a kind.
    static func sizes(for kind: HoleSpec.Kind) -> [String] { kind.isScrew ? sizes : magnetSizes }

    /// Where a kind starts: M3 (or #6 when the project shows inches), or a 6 × 2 mm magnet.
    static func defaultSize(for kind: HoleSpec.Kind, inch: Bool = false) -> String {
        kind.isScrew ? (inch ? "#6" : "M3") : "6×2"
    }

    static func isInch(_ size: String) -> Bool { inchSizes.contains(size) }

    /// A size as written loosely ("m3", "M 3", "1/4-20", "#10-32", "6x2", "6 × 2 mm") as it is
    /// listed for the kind, or nil when the kind has no such size.
    static func size(_ text: String, for kind: HoleSpec.Kind) -> String? {
        var key = text.uppercased().replacingOccurrences(of: " ", with: "")
        if kind.isScrew {
            // An inch size may carry its threads per inch: "1/4-20", "#10-32".
            if let dash = key.firstIndex(of: "-"), !key.hasPrefix("M") { key = String(key[..<dash]) }
            if key.hasSuffix("\"") { key.removeLast() }
            if ["4", "6", "8", "10"].contains(key) { key = "#" + key }
            return sizes.first { $0.uppercased() == key }
        }
        key = key.replacingOccurrences(of: "MM", with: "").replacingOccurrences(of: "X", with: "×").replacingOccurrences(of: "*", with: "×")
        return magnetSizes.first { $0 == key }
    }

    /// The preset for `kind` and `size` (a size the kind does not offer starts from its default).
    /// `clearance` widens nut traps and magnet pockets on each side.
    static func spec(_ kind: HoleSpec.Kind, size: String, clearance: Double = Fit.defaultClearance) -> HoleSpec {
        let size = sizes(for: kind).contains(size) ? size : defaultSize(for: kind)
        let gap = Fit.clearanceRange.contains(clearance) ? clearance : Fit.defaultClearance
        switch kind {
        case .simple: return HoleSpec(kind: kind, size: size, diameter: Self.clearance[size]!)
        case .counterbore:
            let (d, depth) = counterbore[size]!
            return HoleSpec(kind: kind, size: size, diameter: Self.clearance[size]!, counterboreDiameter: d, counterboreDepth: depth)
        case .countersink:
            return HoleSpec(kind: kind, size: size, diameter: Self.clearance[size]!, countersinkDiameter: countersink[size]!,
                            countersinkAngle: isInch(size) ? 82 : 90)
        case .insert: return HoleSpec(kind: kind, size: size, diameter: insert[size]!.diameter)
        case .nutTrap:
            var spec = HoleSpec(kind: kind, size: size, diameter: Self.clearance[size]!)
            spec.nutAcrossFlats = rounded(ThreadMate.acrossFlats[size]! + 2 * gap)
            spec.nutDepth = rounded(nutThickness[size]! + 0.4)
            spec.nutAngle = 0
            return spec
        case .magnet: return HoleSpec(kind: kind, size: size, diameter: rounded(magnets[size]!.diameter + 2 * gap))
        }
    }

    /// Inserts and magnets are blind holes a little deeper than what goes in; the others default to through.
    static func defaultDepth(_ kind: HoleSpec.Kind, size: String) -> Double? {
        let size = sizes(for: kind).contains(size) ? size : defaultSize(for: kind)
        switch kind {
        case .insert: return insert[size]!.depth
        case .magnet: return rounded(magnets[size]!.thickness + 0.2)
        default: return nil
        }
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

extension ExtrusionCut {
    /// Union another solid (its whole definition) into this one.
    static func merge(_ other: SolidBody) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: other.profile, depth: other.depth)
        operation.merged = other
        return operation
    }

    /// Remove `other` (its whole definition) from the solid, grown by `clearance` millimeters when given.
    static func subtract(_ other: SolidBody, clearance: Double? = nil) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: other.profile, depth: other.depth)
        operation.subtracted = other
        operation.clearance = clearance.flatMap { $0 > 0 ? $0 : nil }
        return operation
    }

    /// Keep only where `other` (its whole definition) overlaps the solid.
    static func intersect(_ other: SolidBody) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: other.profile, depth: other.depth)
        operation.intersected = other
        return operation
    }

    /// Hollow `body` (which supplies the placeholder profile) leaving `openFaces` open.
    static func shell(of body: SolidBody, openFaces: [ExtrusionFace], thickness: Double) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.shell = ShellSpec(openFaces: openFaces, thickness: thickness)
        return operation
    }

    /// Hollow `body`, leaving open the named original faces and the faces through these world
    /// points (any face: curved, or made by a cut, join, union, or fillet).
    static func shell(of body: SolidBody, openFaces: [ExtrusionFace] = [], openingAt points: [SIMD3<Double>], thickness: Double) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.shell = ShellSpec(openFaces: openFaces, thickness: thickness, openPoints: points.isEmpty ? nil : points.map(body.localPoint))
        return operation
    }

    /// A hole centered at `center` on `plane`, drilled into the solid along −normal.
    static func hole(_ spec: HoleSpec, at center: Point2, on plane: SketchPlane, depth: Double?) -> ExtrusionCut? {
        let circle = SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: spec.diameter / 2, y: 0))
        guard let profile = Geometry.profiles(in: [circle], on: plane).first else { return nil }
        var operation = ExtrusionCut(profile: profile, depth: depth ?? 1, throughAll: depth == nil)
        operation.hole = spec
        return operation
    }
}

extension SolidBody {
    /// How deeply merged solids nest inside this one (bounded to keep files and rebuilds sane).
    var nestingDepth: Int { 1 + (cuts.compactMap(\.nestedSolid).map(\.nestingDepth).max() ?? 0) }

    /// Every step a build from nothing replays: this solid's own and those of the solids its merges,
    /// subtracts, and intersects carry, however deep. A plate split into pieces and merged back
    /// carried 24,321 steps in 135 of its own and took 14 s to build from nothing (November 8, 2026).
    var historySteps: Int { cuts.count + finishes.count + cuts.compactMap(\.nestedSolid).reduce(0) { $0 + $1.historySteps } }

    /// Past this, work that rebuilds a solid without one of its steps (earlier steps built ahead of
    /// time, finding which fillet made a face) is not started: each such build can hold the kernel
    /// for seconds, and the editor waits for the kernel.
    static let longHistory = 2_000

    /// The flat faces of the original extrusion that a shell can open.
    var extrusionFaces: [ExtrusionFace] {
        // Imported faces are opened by a point on them.
        if imported != nil { return [] }
        if let revolve { return revolve.isFull ? [] : [ExtrusionFace(position: .base, index: 0), ExtrusionFace(position: .cap, index: 0)] }
        return [ExtrusionFace(position: .base, index: 0), ExtrusionFace(position: .cap, index: 0)] +
            (profile.circle == nil ? corners.indices.map { ExtrusionFace(position: .side, index: $0) } : [])
    }

    /// The plane (a point on it and its outward normal) where a named face lies.
    func expectedPlane(of face: ExtrusionFace) -> (point: SIMD3<Double>, normal: SIMD3<Double>)? {
        if let revolve { return revolvePlane(of: face, revolve) }
        let plane = profile.plane, n = plane.normalAxis, direction: Double = depth >= 0 ? 1 : -1
        switch face.position {
        case .base: return (plane.point(.zero, height: baseOffset), -n * direction)
        case .cap: return (plane.point(.zero, height: baseOffset + depth), n * direction)
        case .side:
            let corners = corners
            guard hasPlainSides, profile.circle == nil, corners.indices.contains(face.index), cornerArc(face.index) == nil else { return nil }
            let a = corners[face.index], b = corners[(face.index + 1) % corners.count]
            // Outward is to the right of a counter-clockwise outline.
            let ccw = Geometry.signedArea(corners) > 0
            let along = simd_normalize(plane.point(b) - plane.point(a))
            let outward = simd_cross(along, n) * (ccw ? 1 : -1)
            return (plane.point(a), simd_normalize(outward))
        }
    }

    /// Which named face a flat kernel face is, from its plane and a point on it. A half revolve's
    /// start and end faces share a plane, so for revolves the point must be on the profile's side.
    func extrusionFace(point: SIMD3<Double>, normal: SIMD3<Double>) -> ExtrusionFace? {
        extrusionFaces.first { face in
            guard let expected = expectedPlane(of: face) else { return false }
            guard simd_dot(expected.normal, normal) > 0.9999 && abs(simd_dot(point - expected.point, expected.normal)) < 1e-5 else { return false }
            return revolve.map { isOnProfileSide(point, of: face, $0) } ?? true
        }
    }

    /// The named face of a kernel face (flat faces of the original extrusion or revolve only).
    func extrusionFace(_ index: Int, of solid: KernelSolid) -> ExtrusionFace? {
        guard let plane = solid.facePlane(index) else { return nil }
        return extrusionFace(point: solid.faceCenter(index) ?? plane.origin, normal: plane.normal)
    }
}

extension SolidKernel {
    static func applyMerge(_ operation: ExtrusionCut, to solid: KernelSolid) throws -> KernelSolid {
        guard let other = operation.merged else { throw Failure(message: "Missing merged solid") }
        let result = try boolean(solid, try SolidKernel.solid(for: other), .union)
        guard result.isValidSolid else { throw Failure(message: "These solids do not touch, so they cannot merge") }
        return result
    }

    static func applyShell(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let spec = operation.shell else { throw Failure(message: "Missing shell") }
        let named = Set(spec.openFaces)
        let faces = (0..<solid.faceCount).filter { index in
            body.extrusionFace(index, of: solid).map(named.contains) ?? false
        }
        guard faces.count >= named.count else { throw Failure(message: "A face to leave open no longer exists on this solid") }
        var open = Set(faces)
        for point in spec.openPoints ?? [] {
            guard let face = solid.face(near: body.worldPoint(point)) else {
                throw Failure(message: "A face to leave open no longer exists on this solid")
            }
            open.insert(face)
        }
        return try shell(solid, openFaces: open.sorted(), thickness: spec.thickness)
    }

    static func applyHole(_ operation: ExtrusionCut, to solid: KernelSolid) throws -> KernelSolid {
        guard let spec = operation.hole, let circle = operation.profile.circle else { throw Failure(message: "Missing hole") }
        if operation.throughAll && spec.kind == .simple {
            // The saved entry plane can lie inside the body after a depth edit. A through
            // hole must span both sides of it, just like a through-all sketch cut.
            let result = try boolean(solid, try tool(for: operation, through: solid), .subtract)
            guard result.volume < solid.volume - 1e-9 else { throw Failure(message: "The hole does not reach this solid") }
            return result
        }
        var depth = operation.depth
        if operation.throughAll {
            // Through: reach past the solid's far side.
            let frame = operation.profile.plane.frame, bounds = solid.bounds
            depth = 1
            for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                depth = max(depth, -simd_dot(SIMD3(x, y, z) - frame.origin, frame.normal) + 1)
            } } }
        }
        let counterbore = spec.kind == .counterbore, countersink = spec.kind == .countersink
        guard let tool = ssk_hole_tool(operation.profile.plane.kernelPlane, circle.center.x, circle.center.y, spec.diameter, depth,
                                      counterbore ? spec.counterboreDiameter : 0, counterbore ? spec.counterboreDepth : 0,
                                      countersink ? spec.countersinkDiameter : 0, countersink ? spec.countersinkAngle : 0) else {
            throw Failure(message: ssk_last_error().map { String(cString: $0) } ?? "Hole failed")
        }
        var result = try boolean(solid, KernelSolid(adopting: tool), .subtract)
        if spec.kind == .nutTrap, let nutDepth = spec.nutDepth {
            // The hex pocket: a prism from a little above the face down to the nut's depth.
            let lead = 0.5, plane = operation.profile.plane
            var kernelPlane = plane.kernelPlane
            let up = plane.frame.normal * lead
            kernelPlane.origin = SSKVec3(x: kernelPlane.origin.x + up.x, y: kernelPlane.origin.y + up.y, z: kernelPlane.origin.z + up.z)
            let xy = spec.nutCorners(around: circle.center).flatMap { [$0.x, $0.y] }
            guard xy.count == 12, let pocket = ssk_extrude_polygon(kernelPlane, xy, 6, -(nutDepth + lead)) else {
                throw Failure(message: ssk_last_error().map { String(cString: $0) } ?? "Nut trap failed")
            }
            result = try boolean(result, KernelSolid(adopting: pocket), .subtract)
        }
        guard result.volume < solid.volume - 1e-9 else { throw Failure(message: "The hole does not reach this solid") }
        return result
    }
}

/// Union: solids united into one target solid. Each other solid's whole
/// definition becomes a merge entry on the target, as Merge always stored it (schema 6).
enum Unioning {
    /// `target` with `tools` merged in. Tools join in the order picked where they can; one that
    /// touches only a later tool waits until that tool is in. `untouched` lists the tools that never
    /// touch the growing solid (they are left out of `result`).
    static func union(_ target: SolidBody, with tools: [SolidBody]) -> (result: SolidBody, untouched: [UUID]) {
        var result = target, remaining = tools
        while let index = remaining.firstIndex(where: { tool in
            var next = result
            next.cuts.append(.merge(tool))
            return next.isValid && (try? SolidKernel.solid(for: next)) != nil
        }) {
            result.cuts.append(.merge(remaining.remove(at: index)))
        }
        return (result, remaining.map(\.id))
    }
}

/// Subtract: tool solids removed from target solids. Each target keeps
/// a copy of every tool that cuts it as a subtract entry (schema 12), so it rebuilds without them.
enum Subtracting {
    /// `target` with each tool that overlaps it removed (grown by `clearance` when given); `used`
    /// lists the tools that cut it.
    static func subtract(_ tools: [SolidBody], from target: SolidBody, clearance: Double? = nil) -> (result: SolidBody, used: [UUID]) {
        var result = target, used: [UUID] = []
        for tool in tools {
            var next = result
            next.cuts.append(.subtract(tool, clearance: clearance))
            guard next.isValid, (try? SolidKernel.solid(for: next)) != nil else { continue }
            result = next
            used.append(tool.id)
        }
        return (result, used)
    }
}

/// Intersect: only the volume every picked solid shares is kept.
/// The target (picked last) stores each other solid's whole definition as an intersect entry.
enum Intersecting {
    /// `target` cut down to where every tool overlaps it, or nil when they share no volume.
    static func intersect(_ target: SolidBody, with tools: [SolidBody]) -> SolidBody? {
        var result = target
        for tool in tools { result.cuts.append(.intersect(tool)) }
        guard result.isValid, (try? SolidKernel.solid(for: result)) != nil else { return nil }
        return result
    }
}

extension SolidKernel {
    static func applyIntersect(_ operation: ExtrusionCut, to solid: KernelSolid) throws -> KernelSolid {
        guard let other = operation.intersected else { throw Failure(message: "Missing intersected solid") }
        let result = try boolean(solid, try SolidKernel.solid(for: other), .intersect)
        guard result.volume > 1e-9 else { throw Failure(message: "Those solids do not overlap") }
        return result
    }

    static func applySubtract(_ operation: ExtrusionCut, to solid: KernelSolid) throws -> KernelSolid {
        guard let other = operation.subtracted else { throw Failure(message: "Missing subtracted solid") }
        var tool = try SolidKernel.solid(for: other)
        if let clearance = operation.clearance { tool = try offset(tool, by: clearance) }
        let result = try boolean(solid, tool, .subtract)
        guard result.volume < solid.volume - 1e-6 else { throw Failure(message: "Those solids do not overlap") }
        guard result.volume > 1e-9 else { throw Failure(message: "That would remove the whole solid") }
        return result
    }
}

extension SolidBody {
}

extension SolidBody {
    /// A world point in this solid's own frame (its profile plane's axes and normal), and back.
    func localPoint(_ world: SIMD3<Double>) -> SIMD3<Double> {
        let plane = profile.plane, d = world - plane.origin
        return SIMD3(simd_dot(d, plane.xAxis), simd_dot(d, plane.yAxis), simd_dot(d, plane.normalAxis))
    }
    func worldPoint(_ local: SIMD3<Double>) -> SIMD3<Double> { profile.plane.point(Point2(x: local.x, y: local.y), height: local.z) }

}
