import Foundation
import simd

/// An edge of the original extrusion, named by its role rather than by kernel index.
/// Kernel edge numbers change after every operation; these names survive depth edits and
/// earlier finishes, and are matched back to the current solid's edges when it is rebuilt.
struct ExtrusionEdge: Codable, Hashable, Sendable {
    enum Position: String, Codable, Sendable {
        /// On the sketch plane, along profile segment `index` (a circle has one segment, 0).
        case base
        /// On the far end face, along profile segment `index`.
        case cap
        /// Along the extrusion direction, at profile corner `index` (polygons only).
        case side
        /// Edge `index` of an imported shape, in the stored shape's own order (schema 15).
        case imported
    }
    var position: Position
    var index: Int
}

/// A fillet or chamfer of one size on one or more original extrusion edges.
struct EdgeFinish: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case fillet, chamfer
        var title: String { rawValue.capitalized }
        /// The keypad label: a fillet has a radius, a chamfer a setback distance.
        var sizeTitle: String { self == .fillet ? "Radius" : "Distance" }
        var defaultSize: Double { self == .fillet ? 1 : 0.5 }
    }
    var id = UUID()
    var kind: Kind
    var edges: [ExtrusionEdge]
    /// Fillet radius or chamfer distance in millimeters.
    var size: Double
    static let sizeRange = 0.01...1_000.0
}

extension SolidBody {
    /// Profile corners with collinear points removed. Joined straight lines extrude to a single
    /// flat side, so edge indices count real corners, not drawing segments. Points inside an exact
    /// arc are skipped too: the arc extrudes to one curved side.
    var corners: [Point2] { cornerIndices.map { profile.outline[$0] } }

    private var cornerIndices: [Int] {
        let points = profile.outline, n = points.count
        guard profile.circle == nil, n > 3 else { return Array(points.indices) }
        var inside = Set<Int>(), arcEnds = Set<Int>()
        for arc in profile.arcs ?? [] {
            arcEnds.formUnion([arc.start, (arc.start + arc.segments) % n])
            for step in 1..<max(2, arc.segments) { inside.insert((arc.start + step) % n) }
        }
        let kept = points.indices.filter { i in
            guard !inside.contains(i) else { return false }
            if arcEnds.contains(i) { return true }
            let a = points[(i + n - 1) % n], b = points[i], c = points[(i + 1) % n]
            return abs(Geometry.cross(b - a, c - b)) > 1e-9 * max(1, (b - a).length * (c - b).length)
        }
        return kept.count >= 3 || profile.arcs != nil ? kept : Array(points.indices)
    }

    /// The exact arc running from corner `index` to the next corner, if that side is curved.
    func cornerArc(_ index: Int) -> ProfileArc? {
        guard let arcs = profile.arcs else { return nil }
        let indices = cornerIndices
        guard !indices.isEmpty else { return nil }
        let start = indices[((index % indices.count) + indices.count) % indices.count]
        return arcs.first { $0.start == start }
    }

    /// Every edge this body's extrusion has, in a stable order.
    /// A revolve's `base` and `cap` edges lie on its start and end faces (partial revolves only), and
    /// its `side` edges are the rings its corners trace.
    var extrusionEdges: [ExtrusionEdge] {
        if imported != nil { return importedEdges }
        let ends: [ExtrusionEdge.Position] = revolve?.isFull == true ? [] : [.base, .cap]
        if profile.circle != nil { return ends.map { .init(position: $0, index: 0) } }
        let n = corners.count
        return (ends + [.side]).flatMap { position in (0..<n).map { ExtrusionEdge(position: position, index: $0) } }
    }

    /// Structural checks only; whether the kernel can build the finishes is checked separately.
    var finishesAreValid: Bool {
        guard finishes.count <= 64 else { return false }
        let available = Set(extrusionEdges)
        var used = Set<ExtrusionEdge>()
        for finish in finishes {
            guard finish.size.isFinite, EdgeFinish.sizeRange.contains(finish.size), !finish.edges.isEmpty,
                  finish.edges.allSatisfy(available.contains) else { return false }
            // An edge is consumed by its finish, so it cannot be finished twice.
            for edge in finish.edges { guard used.insert(edge).inserted else { return false } }
        }
        return true
    }

    /// The name of each of `edges` (kernel edge indices of `solid`, this body as built). An
    /// imported solid with nothing added is its stored shape placed, with the same edges in the
    /// same order, so its names need no matching; that matters for imported parts with thousands
    /// of edges.
    func edgeNames(_ edges: [Int], of solid: KernelSolid) -> [ExtrusionEdge?] {
        if imported != nil, finishes.isEmpty, cuts.isEmpty, solid.edgeCount == importedEdges.count {
            return edges.map { ExtrusionEdge(position: .imported, index: $0) }
        }
        return edges.map { extrusionEdge(along: solid.edgeSamples($0)) }
    }

    /// Identifies which original extrusion edge, if any, a curve on the current solid lies along.
    /// Edges created by fillets or chamfers return nil.
    func extrusionEdge(along samples: [SIMD3<Double>], tolerance: Double = 1e-4) -> ExtrusionEdge? {
        guard samples.count >= 2 else { return nil }
        if imported != nil { return importedEdge(along: samples, tolerance: tolerance) }
        return extrusionEdges.first { edge in samples.allSatisfy { distance($0, to: edge) <= tolerance } }
    }

    func distance(_ point: SIMD3<Double>, to edge: ExtrusionEdge) -> Double {
        if let imported {
            guard edge.position == .imported, let base = try? ImportedShapes.shared.solid(imported.shape) else { return .infinity }
            let d = base.edgeDistance(edge.index, to: worldToImported(point))
            return d >= 0 ? d : .infinity
        }
        if let revolve { return revolveDistance(point, to: edge, revolve) }
        let frame = profile.plane.frame
        // Tapered sides are not where the names expect them; their edges are saved by point.
        guard hasPlainSides || edge.position == .base else { return .infinity }
        let height = baseOffset + (edge.position == .cap ? depth : 0)
        let local = point - frame.origin
        let u = simd_dot(local, frame.x), v = simd_dot(local, frame.y), h = simd_dot(local, frame.normal)
        if let circle = profile.circle {
            guard edge.position != .side else { return .infinity }
            return hypot(hypot(u - circle.center.x, v - circle.center.y) - circle.radius, h - height)
        }
        let corners = corners, n = corners.count
        let a = corners[edge.index % n]
        let flat = Point2(x: u, y: v)
        switch edge.position {
        case .base, .cap:
            if let arc = cornerArc(edge.index) { return hypot(flat.distance(to: arc.center) - arc.radius, h - height) }
            let b = corners[(edge.index + 1) % n]
            return hypot(Geometry.distance(flat, toSegment: a, b), h - height)
        case .side:
            let along = max(min(h, baseOffset + max(0, depth)), baseOffset + min(0, depth))
            return hypot(flat.distance(to: a), h - along)
        case .imported:
            return .infinity
        }
    }
}

extension SketchPlane {
    /// Orthonormal world frame in double precision (see Docs/ProjectFiles.md plane mappings).
    var frame: (origin: SIMD3<Double>, x: SIMD3<Double>, y: SIMD3<Double>, normal: SIMD3<Double>) {
        (origin, xAxis, yAxis, normalAxis)
    }
}

extension SolidKernel {
    /// Applies one finish to the edges of `solid` that still carry its names on `body`.
    static func apply(_ finish: EdgeFinish, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        let named = Set(finish.edges)
        let all = Array(0..<solid.edgeCount)
        let indices = zip(all, body.edgeNames(all, of: solid)).filter { $0.1.map(named.contains) ?? false }.map(\.0)
        guard !indices.isEmpty else {
            throw Failure(message: "\(finish.kind.title) edges no longer exist on this solid")
        }
        return switch finish.kind {
        case .fillet: try fillet(solid, edges: indices, radius: finish.size)
        case .chamfer: try chamfer(solid, edges: indices, distance: finish.size)
        }
    }
}

// MARK: Finishes on any edge (schema 16)

/// An edge of a solid as it stands after the operations before a finish: a point on it, in the
/// solid's own frame (so it moves with the solid), and its original extrusion name when it lies
/// along one. A named edge's point follows depth edits: on the cap it stays on the cap, and along
/// a side it keeps its fraction of the depth (`along`).
struct EdgeReference: Codable, Equatable, Sendable {
    var point: SIMD3<Double>
    var name: ExtrusionEdge?
    /// Side edges: how far along the extrusion the point is (0 on the sketch plane, 1 on the cap).
    var along: Double?

    var isValid: Bool {
        [point.x, point.y, point.z].allSatisfy { $0.isFinite } && simd_length(point) <= 200_000 && (along?.isFinite ?? true)
    }
}

/// A fillet or chamfer in a solid's ordered `cuts` list: it rounds or bevels edges the solid has at
/// that point, including edges made by cuts, joins, holes, unions, shells, and earlier finishes.
struct FinishSpec: Codable, Equatable, Sendable {
    var kind: EdgeFinish.Kind
    var size: Double
    var edges: [EdgeReference]
    var isValid: Bool {
        size.isFinite && EdgeFinish.sizeRange.contains(size) && (1...256).contains(edges.count) && edges.allSatisfy(\.isValid)
    }
}

extension ExtrusionCut {
    /// A fillet or chamfer on edges of `body` (which supplies the placeholder profile).
    static func finish(of body: SolidBody, _ spec: FinishSpec) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.finish = spec
        return operation
    }
}

extension SolidBody {

    /// The world point a reference names on this solid now: a named extrusion edge's point moves
    /// with the depth.
    func worldPoint(of reference: EdgeReference) -> SIMD3<Double> {
        var local = reference.point
        if let name = reference.name, revolve == nil, imported == nil {
            switch name.position {
            case .base: local.z = baseOffset
            case .cap: local.z = baseOffset + depth
            case .side: local.z = baseOffset + (reference.along ?? 0.5) * depth
            case .imported: break
            }
        }
        return worldPoint(local)
    }

    /// A reference to kernel edge `edge` of `solid` (this body as built), by its middle point.
    func edgeReference(_ edge: Int, of solid: KernelSolid) -> EdgeReference? {
        let samples = solid.edgeSamples(edge, count: 3)
        guard samples.count == 3 else { return nil }
        let middle = samples[1], local = localPoint(middle)
        let name = edgeNames([edge], of: solid).first ?? nil
        var reference = EdgeReference(point: local, name: name)
        if name?.position == .side, revolve == nil, imported == nil, abs(depth) > 1e-9 { reference.along = (local.z - baseOffset) / depth }
        return reference
    }

    /// This solid with a fillet or chamfer of `size` on `edges` (kernel edge indices of the solid as
    /// it builds now). Edges of the original extrusion on a solid with no other operations keep
    /// their names in `finishes`, as before; any other edge (one made by a cut, join, hole, union,
    /// shell, or earlier finish, or on a solid that has those) is saved by a point on it, as a step
    /// after the others. Nil when an edge cannot be named or the kernel cannot build it.
    func finishing(_ kind: EdgeFinish.Kind, edges: [Int], size: Double) -> SolidBody? {
        guard !edges.isEmpty, EdgeFinish.sizeRange.contains(size), let solid = try? SolidKernel.solid(for: self) else { return nil }
        var result = self
        let names = edgeNames(edges, of: solid)
        let finished = Set(finishes.flatMap(\.edges))
        let named = names.compactMap { $0 }
        if cuts.isEmpty, named.count == edges.count, Set(named).count == named.count, finished.isDisjoint(with: named) {
            result.finishes.append(EdgeFinish(kind: kind, edges: named, size: size))
        } else {
            let references = edges.compactMap { edgeReference($0, of: solid) }
            guard references.count == edges.count else { return nil }
            result.cuts.append(.finish(of: self, FinishSpec(kind: kind, size: size, edges: references)))
        }
        guard result.isValid, (try? SolidKernel.solid(for: result)) != nil else { return nil }
        return result
    }
}

extension SolidKernel {
    /// Rounds or bevels the edges a finish step names, found by their points.
    static func applyFinish(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let spec = operation.finish else { throw Failure(message: "Missing finish") }
        var indices: [Int] = []
        for reference in spec.edges {
            guard let edge = solid.edge(near: body.worldPoint(of: reference)) else {
                throw Failure(message: "\(spec.kind.title) edges no longer exist on this solid")
            }
            if !indices.contains(edge) { indices.append(edge) }
        }
        return switch spec.kind {
        case .fillet: try fillet(solid, edges: indices, radius: spec.size)
        case .chamfer: try chamfer(solid, edges: indices, distance: spec.size)
        }
    }
}

// MARK: Editing a finish from its face (October 23, 2026)

/// A fillet or chamfer of a solid, found from a face it made: an entry of `finishes` (original
/// edges by name) or a finish step in `cuts`. Its size changes, or it comes out, as one step, so
/// the edges are as sharp as before it.
enum FinishSource: Hashable, Sendable {
    case named(Int), step(Int)
}

extension SolidBody {
    func finishKind(_ source: FinishSource) -> (kind: EdgeFinish.Kind, size: Double)? {
        switch source {
        case .named(let index): finishes.indices.contains(index) ? (finishes[index].kind, finishes[index].size) : nil
        case .step(let index): cuts.indices.contains(index) ? cuts[index].finish.map { ($0.kind, $0.size) } : nil
        }
    }

    /// The fillet or chamfer whose rounded or beveled face passes through `point` (a world point on
    /// this solid as built), newest first: without it, no face of the solid lies there any more.
    func finishSource(atFace point: SIMD3<Double>) -> FinishSource? {
        guard let solid = try? SolidKernel.solid(for: self), solid.face(near: point, tolerance: 1e-3) != nil else { return nil }
        let sources = cuts.indices.reversed().filter { cuts[$0].finish != nil }.map(FinishSource.step) +
            finishes.indices.reversed().map(FinishSource.named)
        for source in sources {
            guard let without = removingFinish(source), let built = try? SolidKernel.solid(for: without) else { continue }
            if built.face(near: point, tolerance: 1e-3) == nil { return source }
        }
        return nil
    }

    /// This solid with the finish at `source` taken out; a later finish on an edge only it made
    /// keeps the edges that are left (or goes, with none). Nil when it cannot be built.
    func removingFinish(_ source: FinishSource) -> SolidBody? {
        var result = self
        switch source {
        case .named(let index):
            guard finishes.indices.contains(index) else { return nil }
            result.finishes.remove(at: index)
        case .step(let index):
            guard cuts.indices.contains(index), cuts[index].finish != nil else { return nil }
            result.cuts.remove(at: index)
        }
        guard result.isValid, let cleaned = Self.droppingMissingFinishEdges(result) else { return nil }
        return cleaned.body
    }

    /// This solid with the finish at `source` set to `size`; nil when it does not fit.
    func resizingFinish(_ source: FinishSource, to size: Double) -> SolidBody? {
        guard size.isFinite, EdgeFinish.sizeRange.contains(size) else { return nil }
        var result = self
        switch source {
        case .named(let index):
            guard finishes.indices.contains(index) else { return nil }
            result.finishes[index].size = size
        case .step(let index):
            guard cuts.indices.contains(index), cuts[index].finish != nil else { return nil }
            result.cuts[index].finish?.size = size
        }
        guard result.isValid, (try? SolidKernel.solid(for: result)) != nil else { return nil }
        return result
    }
}
