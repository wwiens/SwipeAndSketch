import Foundation
import simd

// Fit and clearance for printed parts that go together.
// A printed peg comes out a little fat and its hole a little small, so mating parts need a gap.
// The clearance is the gap on each side, in millimeters. The app's Fit preference only seeds new
// operations: every operation saves the millimeters it was built with, so changing the preference
// never changes existing parts.

enum Fit {
    /// Clearances an operation may save.
    static let clearanceRange = 0.01...2.0

    /// Starting points that suit most FDM printers; calibrate with the Fit Test.
    enum Preset: String, CaseIterable, Sendable {
        case tight, standard, loose
        var title: String { rawValue.capitalized }
        var clearance: Double {
            switch self { case .tight: 0.1; case .standard: 0.2; case .loose: 0.3 }
        }
    }

    static let defaultClearance = Preset.standard.clearance

    /// The user's Fit (the app preference new fits start from, since it depends on the printer).
    static var preferredClearance: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "fitClearance")
            return clearanceRange.contains(stored) ? stored : defaultClearance
        }
        set { UserDefaults.standard.set(newValue, forKey: "fitClearance") }
    }

    /// The preset a clearance matches, if any.
    static func preset(for clearance: Double) -> Preset? {
        Preset.allCases.first { abs($0.clearance - clearance) < 1e-9 }
    }

    /// "Standard" or "Custom": the name of a clearance, without its value.
    static func name(for clearance: Double) -> String { preset(for: clearance)?.title ?? "Custom" }
}

// MARK: Peg & Socket

/// A round press-fit or alignment peg standing on a flat face, and the socket it needs in the part
/// it pushes into: the socket is wider by the clearance on each side and deeper by the clearance.
struct PegSpec: Equatable, Sendable {
    var diameter = 5.0
    var height = 5.0
    var clearance = Fit.defaultClearance
    /// A separate solid (a dowel pin printed on its own) instead of part of the solid it stands on.
    var separate = false
    /// A separate peg's length into the face it stands on, which then gets a socket too (0: it only
    /// stands on the face).
    var embed = 0.0

    static let diameterRange = 1.0...50.0
    static let heightRange = 0.5...100.0
    static let embedRange = 0.0...100.0

    var isValid: Bool {
        Self.diameterRange.contains(diameter) && Self.heightRange.contains(height) && Fit.clearanceRange.contains(clearance) &&
            (!separate || Self.embedRange.contains(embed))
    }
    var socketDiameter: Double { diameter + 2 * clearance }
    var socketDepth: Double { height + clearance }
    /// How far into its own face the peg reaches (only separate pegs do).
    var depthIntoFace: Double { separate ? embed : 0 }
    /// A small bevel on the peg's ends so they start into their sockets easily (0 when the peg is too small).
    var leadIn: Double {
        let shortest = depthIntoFace > 0 ? min(height, depthIntoFace) : height
        let size = min(0.5, diameter / 8, shortest / 4)
        return size >= 0.1 ? size : 0
    }
}

enum PegJoint {
    struct Result: Equatable {
        var workspace: Workspace
        /// Solids that got a socket, in document order.
        var sockets: [UUID]
        /// A separate peg's own solid.
        var peg: UUID?
    }

    /// `workspace` with a peg on solid `bodyID`'s face on `plane`, standing out along the plane's
    /// normal, and a matching socket in every other solid it reaches. Hidden solids count: a lid sitting
    /// on a box is hidden to reach the rim under it. A joined peg becomes part of the solid; a separate
    /// one is its own solid after it, reaching `embed` into the face, which then gets a socket too.
    /// Nil when the peg does not sit on the solid.
    /// Its join, tip bevel, pin, and sockets carry the tag `id`, so it can be edited later.
    static func add(_ spec: PegSpec, at center: Point2, on plane: SketchPlane, to bodyID: UUID, in workspace: Workspace, id: UUID = UUID()) -> Result? {
        guard spec.isValid, let index = workspace.bodies.firstIndex(where: { $0.id == bodyID }),
              let peg = circle(spec.diameter, at: center, on: plane),
              let socket = circle(spec.socketDiameter, at: center, on: plane) else { return nil }
        var next = workspace
        var pegID: UUID?
        var sockets: [UUID] = []
        if spec.separate {
            // The pin from `embed` inside the face to `height` outside it, beveled at both ends that go into a socket.
            let bottom = plane.point(center, height: -spec.embed)
            guard let base = SketchPlane.through(bottom, normal: plane.normalAxis),
                  let profile = circle(spec.diameter, at: base.coordinates(of: bottom), on: base) else { return nil }
            var pin = SolidBody(profile: profile, depth: spec.embed + spec.height)
            pin.peg = PegPin(id: id, body: bodyID, clearance: spec.clearance, embed: spec.embed)
            if spec.leadIn > 0 {
                var ends = [ExtrusionEdge(position: .cap, index: 0)]
                if spec.embed > 0 { ends.append(ExtrusionEdge(position: .base, index: 0)) }
                pin.finishes = [EdgeFinish(kind: .chamfer, edges: ends, size: spec.leadIn)]
            }
            guard pin.isValid, (try? SolidKernel.solid(for: pin)) != nil else { return nil }
            var own = next.bodies[index]
            if spec.embed > 0 {
                // Its socket in the face it stands on proves it sits on the solid.
                guard let before = try? SolidKernel.solid(for: own).volume else { return nil }
                own.cuts.append(tagged(ExtrusionCut(profile: socket, depth: -(spec.embed + spec.clearance), operation: .cut), id))
                guard own.isValid, let after = try? SolidKernel.solid(for: own).volume, after < before - 1e-6 else { return nil }
                next.bodies[index] = own
                sockets.append(own.id)
            } else {
                // Standing on the face: it must touch the solid.
                guard let united = try? SolidKernel.boolean(SolidKernel.solid(for: own), SolidKernel.solid(for: pin), .union), united.isValidSolid else { return nil }
            }
            next.bodies.insert(pin, at: index + 1)
            pegID = pin.id
        } else {
            var body = next.bodies[index]
            body.cuts.append(tagged(ExtrusionCut(profile: peg, depth: spec.height, operation: .join), id))
            guard body.isValid, let solid = try? SolidKernel.solid(for: body) else { return nil }
            // The bevel is a finish on the tip's edge; a peg that cannot take one keeps a square tip.
            if spec.leadIn > 0, let tip = solid.edge(near: plane.point(center + Point2(x: spec.diameter / 2, y: 0), height: spec.height)),
               var beveled = body.finishing(.chamfer, edges: [tip], size: spec.leadIn) {
                if beveled.cuts.count > body.cuts.count { beveled.cuts[beveled.cuts.count - 1].peg = id }
                body = beveled
            }
            next.bodies[index] = body
        }

        for other in next.bodies.indices where next.bodies[other].id != bodyID && next.bodies[other].id != pegID {
            var target = next.bodies[other]
            guard let before = try? SolidKernel.solid(for: target).volume else { continue }
            target.cuts.append(tagged(ExtrusionCut(profile: socket, depth: spec.socketDepth, operation: .cut), id))
            guard target.isValid, let after = try? SolidKernel.solid(for: target).volume, after < before - 1e-6 else { continue }
            next.bodies[other] = target
            sockets.append(target.id)
        }
        let order = next.bodies.map(\.id)
        sockets.sort { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
        return Result(workspace: next, sockets: sockets, peg: pegID)
    }

    private static func tagged(_ cut: ExtrusionCut, _ id: UUID) -> ExtrusionCut {
        var cut = cut
        cut.peg = id
        return cut
    }

    static func circle(_ diameter: Double, at center: Point2, on plane: SketchPlane) -> SketchProfile? {
        let shape = SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: diameter / 2, y: 0))
        return Geometry.profiles(in: [shape], on: plane).first
    }
}

// MARK: Fit Test

/// A printable coupon for finding a printer's clearance: a plate with a row of holes, each wider
/// than the peg by a larger clearance, and a loose peg on a tab. Print both, try the peg in each
/// hole, and use the clearance of the first hole it slides into.
enum FitTest {
    static let clearances = [0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4]
    static let pegDiameter = 6.0
    static let spacing = 10.0
    static let plateThickness = 4.0

    /// The plate and the peg piece, with the plate's left end at `origin` on the Top plane. The
    /// tightest hole is at the plate's beveled corner.
    static func coupon(at origin: Point2 = .zero) -> [SolidBody] {
        let width = spacing * Double(clearances.count), length = 16.0
        let plateShape = SketchShape(kind: .rectangle, plane: .top, start: origin, end: origin + Point2(x: width, y: length))
        guard let plateProfile = Geometry.profiles(in: [plateShape], on: .top).first else { return [] }
        var plate = SolidBody(profile: plateProfile, depth: plateThickness)
        // Bevel the corner by the tightest hole so the order can be read off the print.
        let corners = plate.corners
        if let marked = corners.indices.min(by: { (corners[$0].x + corners[$0].y) < (corners[$1].x + corners[$1].y) }) {
            plate.finishes = [EdgeFinish(kind: .chamfer, edges: [ExtrusionEdge(position: .side, index: marked)], size: 3)]
        }
        let face = SketchPlane.through(SIMD3(0, 0, plateThickness), normal: SIMD3(0, 0, 1)) ?? .top
        for (index, clearance) in clearances.enumerated() {
            let center = face.coordinates(of: SketchPlane.top.point(origin + Point2(x: spacing * (Double(index) + 0.5), y: length / 2)))
            let spec = HoleSpec(kind: .simple, size: "Fit Test", diameter: pegDiameter + 2 * clearance)
            if let hole = ExtrusionCut.hole(spec, at: center, on: face, depth: nil) { plate.cuts.append(hole) }
        }

        let tabCorner = origin + Point2(x: 0, y: -24)
        let tabShape = SketchShape(kind: .rectangle, plane: .top, start: tabCorner, end: tabCorner + Point2(x: 14, y: 14))
        guard let tabProfile = Geometry.profiles(in: [tabShape], on: .top).first else { return [plate] }
        var peg = SolidBody(profile: tabProfile, depth: 3)
        let tabTop = SketchPlane.through(SIMD3(0, 0, 3), normal: SIMD3(0, 0, 1)) ?? .top
        let pegCenter = tabTop.coordinates(of: SketchPlane.top.point(tabCorner + Point2(x: 7, y: 7)))
        if let result = PegJoint.add(PegSpec(diameter: pegDiameter, height: 8, clearance: 0.2), at: pegCenter, on: tabTop,
                                     to: peg.id, in: Workspace(bodies: [peg])) {
            peg = result.workspace.bodies[0]
        }
        return [plate, peg]
    }

    /// Where a coupon goes in `workspace`: beside the visible solids, or at the origin.
    static func origin(beside workspace: Workspace) -> Point2 {
        var high: Double?
        for body in workspace.bodies where !workspace.isHidden(body) {
            guard let solid = try? SolidKernel.solid(for: body) else { continue }
            high = max(high ?? -.infinity, solid.bounds.max.x)
        }
        return high.map { Point2(x: ($0 + 20).rounded(.up), y: 0) } ?? .zero
    }
}
