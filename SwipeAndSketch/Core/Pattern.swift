import Foundation
import simd

// Pattern: copies of solids and whole sketches spaced along up
// to three straight directions (linear) or about an axis (circular). Each copy is an ordinary,
// independent solid or sketch with no link back.

struct PatternSpec: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case linear, circular
        var title: String { rawValue.capitalized }
    }
    /// Whether a distance or angle covers the whole pattern (copies spread evenly across it) or the
    /// gap between neighbors.
    enum Definition: String, CaseIterable, Sendable {
        case total, spacing
        /// Extent: the whole distance or angle; Spacing: the gap between neighbors.
        var title: String { self == .total ? "Extent" : "Spacing" }
    }
    /// Circular copies keep the original's orientation, or turn with the pattern.
    enum Orientation: String, CaseIterable, Sendable {
        case uniform, rotated
        /// Fixed copies keep the original's orientation; Rotated ones turn with the pattern.
        var title: String { self == .uniform ? "Fixed" : "Rotated" }
    }
    /// One straight direction of a linear pattern.
    struct Direction: Equatable, Sendable {
        /// Unit vector, in world millimeters.
        var axis: SIMD3<Double>
        /// Instances along it, the original included.
        var count = 3
        /// Total or spacing, in millimeters along `axis` (negative runs the other way); 0 leaves the
        /// direction unused.
        var distance = 0.0
        var isUsed: Bool { count > 1 && abs(distance) > 1e-9 }
    }

    /// Each copy is a full solid of its own, so a pattern stays at most this many.
    static let maximumInstances = 100
    static let countRange = 2...maximumInstances

    var kind = Kind.linear
    var definition = Definition.total
    /// Linear: three directions (the items' own x, y, and normal to start).
    var directions: [Direction]
    /// Circular: the axis the copies turn about, through `center`.
    var center: SIMD3<Double>
    var axis: SIMD3<Double>
    var count = 6
    /// Degrees, total or spacing; 0 until the gizmo is turned.
    var angle = 0.0
    var orientation = Orientation.rotated

    init(center: SIMD3<Double>, axes: [SIMD3<Double>]) {
        directions = axes.map { Direction(axis: $0) }
        self.center = center
        axis = axes.last ?? SIMD3(0, 0, 1)
    }

    /// How far apart neighbors are along a direction.
    func step(_ direction: Direction) -> Double {
        definition == .spacing ? direction.distance : direction.distance / Double(direction.count - 1)
    }

    /// The turn between neighbors. A total of a whole turn spreads the copies all the way round
    /// without the last landing on the original.
    var angleStep: Double {
        if definition == .spacing { return angle }
        return abs(angle) >= 360 - 1e-9 ? angle / Double(count) : angle / Double(count - 1)
    }

    /// Instances, the originals included (1 when nothing is set yet).
    var instanceCount: Int {
        switch kind {
        case .linear: directions.filter(\.isUsed).reduce(1) { $0 * $1.count }
        case .circular: count > 1 && abs(angle) > 1e-9 ? count : 1
        }
    }

    /// The motions that place each copy (not the originals), in order. `itemsCenter` is where the
    /// items sit together, which uniform circular copies carry round without turning.
    func placements(itemsCenter: SIMD3<Double>) -> [RigidTransform] {
        switch kind {
        case .linear:
            let used = directions.filter(\.isUsed)
            var offsets = [SIMD3<Double>.zero]
            for direction in used {
                let step = direction.axis * self.step(direction)
                offsets = offsets.flatMap { offset in (0..<direction.count).map { offset + step * Double($0) } }
            }
            return offsets.dropFirst().map { .move($0) }
        case .circular:
            guard instanceCount > 1, simd_length(axis) > 1e-9 else { return [] }
            return (1..<count).map { index in
                let turn = RigidTransform.rotate(degrees: angleStep * Double(index), about: axis, through: center)
                return orientation == .rotated ? turn : .move(turn.apply(point: itemsCenter) - itemsCenter)
            }
        }
    }
}

enum Patterning {
    /// The middle of the items together: the average of each solid's bounding box center and
    /// each sketch's extent center.
    static func center(of workspace: Workspace, bodies: [UUID], sketches: [UUID]) -> SIMD3<Double>? {
        let centers = bodies.compactMap { id in workspace.bodies.first { $0.id == id }.flatMap(workspace.center(of:)) }
            + sketches.compactMap { id in workspace.sketch(id).flatMap(workspace.center(of:)) }
        guard !centers.isEmpty else { return nil }
        return centers.reduce(.zero, +) / Double(centers.count)
    }

    /// The solids and sketches with their pattern copies. Each original's copies follow it in
    /// Items. With `checked`, every copied solid must build (a commit); a preview skips that, since
    /// a rigid copy of a solid that builds builds too. Returns the copies made; nil when the pattern
    /// makes no copies, too many, or an item cannot be copied.
    /// `placements` are the motions of each original's copies, in order (each solid's copies follow
    /// it in `bodies`).
    static func pattern(_ workspace: Workspace, bodies: [UUID], sketches: [UUID], spec: PatternSpec,
                        checked: Bool = true) -> (workspace: Workspace, bodies: [UUID], sketches: [UUID], placements: [RigidTransform])? {
        guard !(bodies.isEmpty && sketches.isEmpty), spec.instanceCount > 1, spec.instanceCount <= PatternSpec.maximumInstances,
              let itemsCenter = center(of: workspace, bodies: bodies, sketches: sketches) else { return nil }
        let placements = spec.placements(itemsCenter: itemsCenter)
        guard !placements.isEmpty else { return nil }
        var result = workspace
        var madeBodies: [UUID] = [], madeSketches: [UUID] = []
        for id in bodies {
            guard let index = result.bodies.firstIndex(where: { $0.id == id }) else { return nil }
            let original = result.bodies[index]
            var copies: [SolidBody] = []
            for placement in placements {
                guard var copy = original.transformed(by: placement) else { return nil }
                copy.id = UUID()
                copy.hidden = nil
                // The copy's solid is the original's, placed: nothing is rebuilt.
                SolidCache.shared.seed(copy, from: original, by: placement)
                if checked { guard (try? SolidKernel.solid(for: copy)) != nil else { return nil } }
                copies.append(copy)
            }
            result.bodies.insert(contentsOf: copies, at: index + 1)
            madeBodies += copies.map(\.id)
        }
        for id in sketches {
            guard let index = result.sketches.firstIndex(where: { $0.id == id }) else { return nil }
            let shapes = result.shapes.filter { $0.sketch == id }
            guard !shapes.isEmpty else { return nil }
            var copies: [Sketch] = []
            for placement in placements {
                guard let plane = result.sketches[index].plane.transformed(by: placement) else { return nil }
                let sketchID = UUID()
                copies.append(Sketch(id: sketchID, plane: plane))
                result.shapes += shapes.map { shape in
                    var copy = shape
                    copy.id = UUID()
                    copy.sketch = sketchID
                    copy.plane = plane
                    return copy
                }
            }
            result.sketches.insert(contentsOf: copies, at: index + 1)
            madeSketches += copies.map(\.id)
        }
        return result.isValid ? (result, madeBodies, madeSketches, placements) : nil
    }
}
