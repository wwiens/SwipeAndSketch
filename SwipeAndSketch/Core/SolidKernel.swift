import Foundation
import SSKernel
import simd

/// Swift face of the Open CASCADE solid-modeling kernel (SwipeAndSketch/Kernel).
///
/// The document keeps editable analytic geometry; kernel solids are derived from it and are
/// never persisted. Every operation returns a new immutable solid and leaves its input intact,
/// which fits the snapshot-based undo history.
enum SolidKernel {
    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    enum BooleanOperation { case union, subtract, intersect }

    static var occtVersion: String { String(cString: ssk_occt_version()) }

    /// Extrudes `depth` along the plane normal, starting `offset` millimeters off the sketch plane,
    /// its sides leaning in by `taper` degrees (positive narrows toward the far end).
    static func extrude(_ profile: SketchProfile, depth: Double, offset: Double = 0, taper: Double = 0) throws -> KernelSolid {
        if taper != 0 || profile.usesEllipses {
            let loops = kernelLoops(of: profile)
            return try make {
                ssk_extrude_region_ex(profile.plane.kernelPlane, loops.xy, loops.mids, loops.ellipses, loops.sizes, Int32(loops.sizes.count),
                                      offset, depth, taper)
            }
        }
        var plane = profile.plane.kernelPlane
        let normal = profile.plane.frame.normal * offset
        plane.origin = SSKVec3(x: plane.origin.x + normal.x, y: plane.origin.y + normal.y, z: plane.origin.z + normal.z)
        if profile.holes != nil {
            let loops = kernelLoops(of: profile)
            return try make { ssk_extrude_region(plane, loops.xy, loops.mids, loops.sizes, Int32(loops.sizes.count), depth) }
        }
        if let circle = profile.circle {
            return try make { ssk_extrude_circle(plane, circle.center.x, circle.center.y, circle.radius, depth) }
        }
        if let arcs = profile.arcs, !arcs.isEmpty {
            let edges = kernelEdges(of: profile)
            return try make { ssk_extrude_profile(plane, edges.xy, edges.mids, edges.count, depth) }
        }
        let coordinates = profile.outline.flatMap { [$0.x, $0.y] }
        return try make { ssk_extrude_polygon(plane, coordinates, Int32(profile.outline.count), depth) }
    }

    /// A polygon profile as kernel edges: one per straight segment and one exact arc (through a
    /// point inside it, in `mids`; NaN for straight edges) per arc.
    private static func kernelEdges(of profile: SketchProfile) -> (xy: [Double], mids: [Double], count: Int32) {
        kernelEdges(outline: profile.outline, arcs: profile.arcs)
    }

    /// A region's outline and holes as kernel loops (see ssk_extrude_region): a circle is one point
    /// on it with its center as the mid-point.
    private static func kernelLoops(of profile: SketchProfile) -> (xy: [Double], mids: [Double], ellipses: [Double], sizes: [Int32]) {
        var xy: [Double] = [], mids: [Double] = [], ellipses: [Double] = [], sizes: [Int32] = []
        let loops = [(profile.outline, profile.circle, profile.arcs, profile.ellipse)] + (profile.holes ?? []).map({ ($0.outline, $0.circle, $0.arcs, $0.ellipse) })
        for loop in loops {
            if let ellipse = loop.3 {
                xy += [ellipse.center.x, ellipse.center.y]
                mids += [.nan, .nan]
                ellipses += [ellipse.radiusX, ellipse.radiusY, ellipse.angle, 1]
                sizes.append(1)
                continue
            }
            ellipses += [0, 0, 0, 0]
            if let circle = loop.1 {
                xy += [circle.center.x + circle.radius, circle.center.y]
                mids += [circle.center.x, circle.center.y]
                sizes.append(1)
            } else {
                let edges = kernelEdges(outline: loop.0, arcs: loop.2)
                xy += edges.xy; mids += edges.mids; sizes.append(edges.count)
            }
        }
        return (xy, mids, ellipses, sizes)
    }

    private static func kernelEdges(outline points: [Point2], arcs: [ProfileArc]?) -> (xy: [Double], mids: [Double], count: Int32) {
        let n = points.count, arcs = arcs ?? []
        let starts = Dictionary(arcs.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        var inside = Set<Int>()
        for arc in arcs { for step in 1..<max(2, arc.segments) { inside.insert((arc.start + step) % n) } }
        // Start on a point that is not inside an arc, so no arc wraps past the start.
        let first = (0..<n).first { !inside.contains($0) } ?? 0
        var xy: [Double] = [], mids: [Double] = []
        var step = 0
        while step < n {
            let index = (first + step) % n
            xy += [points[index].x, points[index].y]
            if let arc = starts[index] {
                let mid = points[(index + arc.segments / 2) % n]
                mids += [mid.x, mid.y]
                step += arc.segments
            } else {
                mids += [.nan, .nan]
                step += 1
            }
        }
        return (xy, mids, Int32(xy.count / 2))
    }

    /// Revolves a profile about the spec's axis (see Revolve.swift). Arcs stay exact, as in `extrude`.
    static func revolve(_ profile: SketchProfile, _ spec: RevolveSpec) throws -> KernelSolid {
        let plane = profile.plane.kernelPlane, a = spec.from, b = spec.to
        if profile.usesEllipses {
            let loops = kernelLoops(of: profile)
            return try make {
                ssk_revolve_region_ex(plane, loops.xy, loops.mids, loops.ellipses, loops.sizes, Int32(loops.sizes.count), a.x, a.y, b.x, b.y, spec.angle)
            }
        }
        if profile.holes != nil {
            let loops = kernelLoops(of: profile)
            return try make { ssk_revolve_region(plane, loops.xy, loops.mids, loops.sizes, Int32(loops.sizes.count), a.x, a.y, b.x, b.y, spec.angle) }
        }
        if let circle = profile.circle {
            return try make { ssk_revolve_circle(plane, circle.center.x, circle.center.y, circle.radius, a.x, a.y, b.x, b.y, spec.angle) }
        }
        let edges = kernelEdges(of: profile)
        return try make { ssk_revolve_profile(plane, edges.xy, edges.mids, edges.count, a.x, a.y, b.x, b.y, spec.angle) }
    }

    /// The revolve of a solid's own flat face about a world axis. The result is the swept solid alone.
    static func revolve(face: Int, of solid: KernelSolid, about axis: (origin: SIMD3<Double>, direction: SIMD3<Double>), angle: Double) throws -> KernelSolid {
        let a = axis.origin, b = axis.origin + axis.direction
        return try make { ssk_revolve_face(solid.pointer, Int32(face), SSKVec3(x: a.x, y: a.y, z: a.z), SSKVec3(x: b.x, y: b.y, z: b.z), angle) }
    }

    static func extrude(_ body: SolidBody) throws -> KernelSolid {
        try extrude(body.profile, depth: body.depth, symmetric: body.symmetric == true, taper: body.taper ?? 0)
    }

    /// An extrusion with the Extrude options: both ways from the sketch plane, and tapered sides.
    static func extrude(_ profile: SketchProfile, depth: Double, symmetric: Bool, taper: Double) throws -> KernelSolid {
        guard symmetric else { return try extrude(profile, depth: depth, taper: taper) }
        guard taper != 0 else { return try extrude(profile, depth: depth, offset: -depth / 2) }
        // A symmetric taper narrows both ways from the sketch plane: two halves, joined there.
        return try boolean(try extrude(profile, depth: depth / 2, taper: taper), try extrude(profile, depth: -depth / 2, taper: taper), .union)
    }

    /// A body's own feature before finishes and cuts: its imported shape, its revolve, or its extrusion.
    static func base(of body: SolidBody) throws -> KernelSolid {
        if body.imported != nil { return try importedBase(of: body) }
        if let revolve = body.revolve { return try self.revolve(body.profile, revolve) }
        return try extrude(body)
    }

    /// The prism of a solid's own flat face along its outward normal (negative depth goes inward).
    static func extrude(face: Int, of solid: KernelSolid, depth: Double) throws -> KernelSolid {
        try make { ssk_extrude_face(solid.pointer, Int32(face), depth) }
    }

    static func boolean(_ a: KernelSolid, _ b: KernelSolid, _ operation: BooleanOperation) throws -> KernelSolid {
        let op: SSKBooleanOp = switch operation {
        case .union: SSKBooleanUnion
        case .subtract: SSKBooleanSubtract
        case .intersect: SSKBooleanIntersect
        }
        return try make { ssk_boolean(a.pointer, b.pointer, op) }
    }

    static func fillet(_ solid: KernelSolid, edges: [Int], radius: Double) throws -> KernelSolid {
        let indices = edges.map(Int32.init)
        return try make { ssk_fillet(solid.pointer, indices, Int32(indices.count), radius) }
    }

    static func chamfer(_ solid: KernelSolid, edges: [Int], distance: Double) throws -> KernelSolid {
        let indices = edges.map(Int32.init)
        return try make { ssk_chamfer(solid.pointer, indices, Int32(indices.count), distance) }
    }

    /// Hollows inward so the outer dimensions stay as drawn. `openFaces` are removed.
    static func shell(_ solid: KernelSolid, openFaces: [Int], thickness: Double) throws -> KernelSolid {
        let indices = openFaces.map(Int32.init)
        return try make { ssk_shell(solid.pointer, indices, Int32(indices.count), thickness) }
    }

    /// The solid placed by a rigid motion, sharing its geometry (and meshes) with the original.
    static func moved(_ solid: KernelSolid, by transform: RigidTransform) throws -> KernelSolid {
        let r = simd_double3x3(transform.rotation)
        let t = transform.pivot + transform.translation - r * transform.pivot
        // Row-major [R | t]; simd matrices are column-major.
        let m = [r[0][0], r[1][0], r[2][0], t.x, r[0][1], r[1][1], r[2][1], t.y, r[0][2], r[1][2], r[2][2], t.z]
        return try make { ssk_moved(solid.pointer, m) }
    }

    /// Grows the solid outward by `distance` on every side (printing clearance).
    static func offset(_ solid: KernelSolid, by distance: Double) throws -> KernelSolid {
        try make { ssk_offset_solid(solid.pointer, distance) }
    }

    /// The solid scaled about `center` by `factors` along `axes` (x, y; the third is their cross product).
    static func scaled(_ solid: KernelSolid, about center: SIMD3<Double>, axes: [SIMD3<Double>], factors: SIMD3<Double>) throws -> KernelSolid {
        func vec(_ v: SIMD3<Double>) -> SSKVec3 { SSKVec3(x: v.x, y: v.y, z: v.z) }
        return try make { ssk_scale(solid.pointer, vec(center), vec(axes[0]), vec(axes[1]), factors.x, factors.y, factors.z) }
    }

    /// The solid with `faces` taken away and the gap closed by the faces around them.
    static func removingFaces(_ faces: [Int], from solid: KernelSolid) throws -> KernelSolid {
        let indices = faces.map(Int32.init)
        return try make { ssk_remove_faces(solid.pointer, indices, Int32(indices.count)) }
    }

    /// The solid with `faces` moved `distance` along their outward normals (a round face grows or shrinks).
    static func offsettingFaces(_ faces: [Int], of solid: KernelSolid, by distance: Double) throws -> KernelSolid {
        let indices = faces.map(Int32.init)
        return try make { ssk_offset_faces(solid.pointer, indices, Int32(indices.count), distance) }
    }

    /// A loop or chain of sketch edges: edge i runs from `points[i]` to the next point (back to the
    /// first, when closed), as an arc through `mids[i]` when it has one. A closed loop of one point
    /// is a full circle about its mid.
    struct OutlineLoop: Equatable, Sendable {
        var points: [Point2]
        var mids: [Point2?]
        var closed: Bool
    }

    /// Outlines `distance` from a loop or chain on `plane` (outward or to the left for positive
    /// distances), with sharp or rounded corners.
    static func offset(_ outline: OutlineLoop, on plane: SketchPlane, by distance: Double, rounded: Bool) throws -> [OutlineLoop] {
        let xy = outline.points.flatMap { [$0.x, $0.y] }
        let mids = outline.mids.flatMap { $0.map { [$0.x, $0.y] } ?? [.nan, .nan] }
        let kernelPlane = plane.kernelPlane
        var loopCount: Int32 = 0
        let total = ssk_offset_outline(kernelPlane, xy, mids, Int32(outline.points.count), outline.closed, distance, rounded,
                                       nil, nil, nil, nil, 0, 0, &loopCount)
        guard total > 0, loopCount > 0 else { throw lastFailure("The outline cannot be offset that far") }
        var outXY = [Double](repeating: 0, count: 2 * Int(total)), outMids = [Double](repeating: 0, count: 2 * Int(total))
        var sizes = [Int32](repeating: 0, count: Int(loopCount)), closed = [Bool](repeating: false, count: Int(loopCount))
        guard ssk_offset_outline(kernelPlane, xy, mids, Int32(outline.points.count), outline.closed, distance, rounded,
                                 &outXY, &outMids, &sizes, &closed, total, loopCount, &loopCount) == total else {
            throw lastFailure("The outline cannot be offset that far")
        }
        var loops: [OutlineLoop] = [], index = 0
        for (size, isClosed) in zip(sizes, closed) {
            var loop = OutlineLoop(points: [], mids: [], closed: isClosed)
            for i in index..<(index + Int(size)) {
                loop.points.append(Point2(x: outXY[2 * i], y: outXY[2 * i + 1]))
                let mid = Point2(x: outMids[2 * i], y: outMids[2 * i + 1])
                loop.mids.append(mid.x.isFinite && mid.y.isFinite ? mid : nil)
            }
            index += Int(size)
            loops.append(loop)
        }
        return loops
    }

    private static func make(_ body: () -> OpaquePointer?) throws -> KernelSolid {
        guard let pointer = body() else { throw lastFailure("Kernel operation failed") }
        return KernelSolid(pointer)
    }

    fileprivate static func lastFailure(_ fallback: String) -> Failure {
        Failure(message: ssk_last_error().map { String(cString: $0) } ?? fallback)
    }
}

/// An immutable B-rep solid owned by the kernel.
final class KernelSolid: @unchecked Sendable {
    fileprivate let pointer: OpaquePointer
    // OCCT caches triangulations on the shape's faces, which moved copies share (SolidKernel.moved),
    // so tessellation is serialized across all solids.
    private static let meshLock = NSLock()
    private var meshLock: NSLock { Self.meshLock }

    fileprivate init(_ pointer: OpaquePointer) { self.pointer = pointer }
    /// Takes ownership of a shape returned by a facade call made outside SolidKernel.
    convenience init(adopting pointer: OpaquePointer) { self.init(pointer) }
    deinit { ssk_shape_free(pointer) }
    /// The facade handle, for kernel calls made outside this file. Valid while the solid lives.
    var handle: OpaquePointer { pointer }

    var faceCount: Int { Int(ssk_face_count(pointer)) }
    var edgeCount: Int { Int(ssk_edge_count(pointer)) }
    /// One closed, topologically valid solid: safe to export as a watertight mesh.
    var isValidSolid: Bool { ssk_is_valid_solid(pointer) }
    /// The volume, computed once like the bounds: on a threaded solid it takes tens of
    /// milliseconds, and the selection strip asks on every update, every step of a drag included.
    var volume: Double {
        propertyLock.lock(); defer { propertyLock.unlock() }
        if let cachedVolume { return cachedVolume }
        let value = ssk_volume(pointer)
        cachedVolume = value
        return value
    }
    /// The exact bounding box, computed once: the solid never changes, and on curved shapes it is
    /// slow enough (tens of milliseconds) to matter when the Move/Rotate widget asks every frame.
    var bounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        propertyLock.lock(); defer { propertyLock.unlock() }
        if let cachedBounds { return cachedBounds }
        var lo = SSKVec3(), hi = SSKVec3()
        ssk_bounds(pointer, &lo, &hi)
        let result = (min: SIMD3(lo.x, lo.y, lo.z), max: SIMD3(hi.x, hi.y, hi.z))
        cachedBounds = result
        return result
    }
    private let propertyLock = NSLock()
    private var cachedBounds: (min: SIMD3<Double>, max: SIMD3<Double>)?
    private var cachedVolume: Double?
    private var cachedSurfaceArea: Double?

    /// Exact points along an edge's curve, ends included. Empty for degenerate edges.
    func edgeSamples(_ edge: Int, count: Int = 5) -> [SIMD3<Double>] {
        var xyz = [Double](repeating: 0, count: 3 * count)
        guard ssk_edge_samples(pointer, Int32(edge), Int32(count), &xyz) else { return [] }
        return (0..<count).map { SIMD3(xyz[3 * $0], xyz[3 * $0 + 1], xyz[3 * $0 + 2]) }
    }

    /// Indices of the edges bounding a face.
    func faceEdges(_ face: Int) -> [Int] {
        let count = Int(ssk_face_edges(pointer, Int32(face), nil, 0))
        guard count > 0 else { return [] }
        var edges = [Int32](repeating: 0, count: count)
        _ = ssk_face_edges(pointer, Int32(face), &edges, Int32(count))
        return edges.map(Int.init)
    }

    /// Area centroid of a face.
    func faceCenter(_ face: Int) -> SIMD3<Double>? {
        var xyz = [Double](repeating: 0, count: 3)
        guard ssk_face_center(pointer, Int32(face), &xyz) else { return nil }
        return SIMD3(xyz[0], xyz[1], xyz[2])
    }

    /// A point on a flat face and its outward unit normal; nil for curved faces.
    func facePlane(_ face: Int) -> (origin: SIMD3<Double>, normal: SIMD3<Double>)? {
        var origin = [Double](repeating: 0, count: 3), normal = [Double](repeating: 0, count: 3)
        guard ssk_face_plane(pointer, Int32(face), &origin, &normal) else { return nil }
        return (SIMD3(origin[0], origin[1], origin[2]), SIMD3(normal[0], normal[1], normal[2]))
    }

    /// The face (flat or curved) nearest `point`, within `tolerance`.
    func face(near point: SIMD3<Double>, tolerance: Double = 1e-3) -> Int? {
        let index = ssk_face_near(pointer, SSKVec3(x: point.x, y: point.y, z: point.z), tolerance)
        return index >= 0 ? Int(index) : nil
    }

    /// The flat face with outward `normal` that contains `point` strictly inside, if any.
    func face(containing point: SIMD3<Double>, normal: SIMD3<Double>, tolerance: Double = 1e-4) -> Int? {
        let index = ssk_face_at(pointer, SSKVec3(x: point.x, y: point.y, z: point.z), SSKVec3(x: normal.x, y: normal.y, z: normal.z), tolerance)
        return index >= 0 ? Int(index) : nil
    }

    /// A face's outer boundary as an ordered closed polygon (arcs every 5°), plus the boundary's
    /// edge when it is a single edge such as a full circle.
    func faceOutline(_ face: Int) -> (points: [SIMD3<Double>], singleEdge: Int?)? {
        var single: Int32 = -1
        let count = Int(ssk_face_outline(pointer, Int32(face), nil, 0, &single))
        guard count > 0 else { return nil }
        var xyz = [Double](repeating: 0, count: 3 * count)
        guard Int(ssk_face_outline(pointer, Int32(face), &xyz, Int32(count), &single)) == count else { return nil }
        return ((0..<count).map { SIMD3(xyz[3 * $0], xyz[3 * $0 + 1], xyz[3 * $0 + 2]) }, single >= 0 ? Int(single) : nil)
    }

    /// The edge (not degenerate) nearest `point`, within `tolerance`.
    func edge(near point: SIMD3<Double>, tolerance: Double = 1e-3) -> Int? {
        let index = ssk_edge_near(pointer, SSKVec3(x: point.x, y: point.y, z: point.z), tolerance)
        return index >= 0 ? Int(index) : nil
    }

    /// Length of an edge in millimeters.
    func edgeLength(_ edge: Int) -> Double? {
        let length = ssk_edge_length(pointer, Int32(edge))
        return length >= 0 ? length : nil
    }

    /// Area of a face in square millimeters.
    func faceArea(_ face: Int) -> Double? {
        let area = ssk_face_area(pointer, Int32(face))
        return area >= 0 ? area : nil
    }

    /// Total area of the solid's faces, computed once (see `volume`).
    var surfaceArea: Double {
        propertyLock.lock(); defer { propertyLock.unlock() }
        if let cachedSurfaceArea { return cachedSurfaceArea }
        let value = ssk_surface_area(pointer)
        cachedSurfaceArea = value
        return value
    }

    /// A cylindrical face's axis (a point on it and its direction) and radius.
    func faceCylinder(_ face: Int) -> (point: SIMD3<Double>, direction: SIMD3<Double>, radius: Double)? {
        var point = [Double](repeating: 0, count: 3), direction = [Double](repeating: 0, count: 3), radius = 0.0
        guard ssk_face_cylinder(pointer, Int32(face), &point, &direction, &radius) else { return nil }
        return (SIMD3(point[0], point[1], point[2]), SIMD3(direction[0], direction[1], direction[2]), radius)
    }

    /// Which part of a solid a distance is measured from.
    enum Part: Equatable, Sendable {
        case whole, face(Int), edge(Int)
        fileprivate var kernel: (SSKPart, Int32) {
            switch self {
            case .whole: (SSKPartWhole, 0)
            case .face(let index): (SSKPartFace, Int32(index))
            case .edge(let index): (SSKPartEdge, Int32(index))
            }
        }
    }

    /// The minimum distance from a part of this solid to a part of `other`, and the nearest points.
    func distance(_ part: Part, to other: KernelSolid, _ otherPart: Part) -> (distance: Double, from: SIMD3<Double>, to: SIMD3<Double>)? {
        var a = SSKVec3(), b = SSKVec3()
        let (kindA, indexA) = part.kernel, (kindB, indexB) = otherPart.kernel
        let value = ssk_distance(pointer, kindA, indexA, other.pointer, kindB, indexB, &a, &b)
        return value >= 0 ? (value, SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)) : nil
    }

    /// Reference geometry to measure against (never part of a model): a point, a segment, or an
    /// arc about `center` from `start`, turning right-handed about `normal` (360°: a circle).
    static func point(_ p: SIMD3<Double>) -> KernelSolid? { ssk_make_point(SSKVec3(x: p.x, y: p.y, z: p.z)).map(KernelSolid.init) }
    static func segment(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> KernelSolid? {
        ssk_make_segment(SSKVec3(x: a.x, y: a.y, z: a.z), SSKVec3(x: b.x, y: b.y, z: b.z)).map(KernelSolid.init)
    }
    static func arc(center: SIMD3<Double>, normal: SIMD3<Double>, start: SIMD3<Double>, degrees: Double) -> KernelSolid? {
        ssk_make_arc(SSKVec3(x: center.x, y: center.y, z: center.z), SSKVec3(x: normal.x, y: normal.y, z: normal.z),
                    SSKVec3(x: start.x, y: start.y, z: start.z), degrees).map(KernelSolid.init)
    }

    /// Center and radius when an edge is a circle or circular arc.
    func edgeCircle(_ edge: Int) -> (center: SIMD3<Double>, radius: Double)? {
        var xyz = [Double](repeating: 0, count: 3), radius = 0.0
        guard ssk_edge_circle(pointer, Int32(edge), &xyz, &radius) else { return nil }
        return (SIMD3(xyz[0], xyz[1], xyz[2]), radius)
    }

    /// Display triangulation. Defaults follow the research brief: 0.02 mm chordal, 5° angular.
    /// Triangles for drawing: 0.05 mm and 10°, smooth on screen (a ⌀10 hole gets 36 sides, within
    /// 0.02 mm) at a fraction of the triangles of the default. Imported hardware with modeled
    /// threads otherwise runs to hundreds of thousands of triangles per screw. Exports and anything
    /// measured from the mesh keep the finer default. The kernel never coarsens a shape's mesh, so
    /// a finer one made first is kept.
    func tessellateForDisplay() throws -> KernelMesh { try tessellate(linearDeflection: 0.05, angularDeflection: 10 * .pi / 180) }

    func tessellate(linearDeflection: Double = 0.02, angularDeflection: Double = 5 * .pi / 180) throws -> KernelMesh {
        meshLock.lock()
        defer { meshLock.unlock() }
        guard let mesh = ssk_tessellate(pointer, linearDeflection, angularDeflection) else {
            throw SolidKernel.lastFailure("Tessellation failed")
        }
        defer { ssk_mesh_free(mesh) }
        return KernelMesh(mesh)
    }
}

/// Triangles grouped by B-rep face, plus each B-rep edge as a polyline, in world millimeters.
struct KernelMesh: Sendable {
    struct Edge: Sendable {
        var points: [SIMD3<Float>]
        /// Seams (the closing line of a cylinder) and degenerate edges are not visible borders.
        var isBoundary: Bool
    }

    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    /// `faces[i]` is the range of `indices` belonging to B-rep face `i`.
    var faces: [Range<Int>]
    var edges: [Edge]

    var triangleCount: Int { indices.count / 3 }

    fileprivate init(_ mesh: OpaquePointer) {
        func vectors(_ data: UnsafePointer<Float>?, _ count: Int) -> [SIMD3<Float>] {
            guard let data, count > 0 else { return [] }
            return (0..<count).map { SIMD3(data[3 * $0], data[3 * $0 + 1], data[3 * $0 + 2]) }
        }
        let vertexCount = Int(ssk_mesh_vertex_count(mesh))
        positions = vectors(ssk_mesh_positions(mesh), vertexCount)
        normals = vectors(ssk_mesh_normals(mesh), vertexCount)
        let indexCount = Int(ssk_mesh_index_count(mesh))
        indices = indexCount > 0 ? Array(UnsafeBufferPointer(start: ssk_mesh_indices(mesh), count: indexCount)) : []
        let faceCount = Int(ssk_mesh_face_count(mesh))
        let faceStarts = Array(UnsafeBufferPointer(start: ssk_mesh_face_starts(mesh), count: faceCount + 1)).map(Int.init)
        faces = (0..<faceCount).map { faceStarts[$0]..<faceStarts[$0 + 1] }
        let edgeCount = Int(ssk_mesh_edge_count(mesh))
        let edgeStarts = Array(UnsafeBufferPointer(start: ssk_mesh_edge_starts(mesh), count: edgeCount + 1)).map(Int.init)
        let points = vectors(ssk_mesh_edge_points(mesh), edgeStarts.last ?? 0)
        let flags = UnsafeBufferPointer(start: ssk_mesh_edge_flags(mesh), count: edgeCount)
        edges = (0..<edgeCount).map { i in
            Edge(points: Array(points[edgeStarts[i]..<edgeStarts[i + 1]]),
                 isBoundary: flags[i] & UInt8(SSKEdgeSeam | SSKEdgeDegenerate) == 0)
        }
    }
}

extension SketchPlane {
    /// Same frame as the canvas basis: normal = x × y (Top +Z, Front −Y, Right +X).
    var kernelPlane: SSKPlane {
        func vec(_ v: SIMD3<Double>) -> SSKVec3 { SSKVec3(x: v.x, y: v.y, z: v.z) }
        return SSKPlane(origin: vec(origin), xAxis: vec(xAxis), yAxis: vec(yAxis))
    }
}

/// Direction-dependent outlines of curved B-rep faces (cylinder sides, fillets): where the surface
/// turns from facing a direction to facing away. The canvas draws them for the view direction;
/// Project uses them for its projection direction. Planar faces never produce silhouettes; their
/// borders are real B-rep edges.
struct KernelSilhouettes: Equatable, Sendable {
    private struct Crease: Equatable, Sendable { var a, b: SIMD3<Float>; var n1, n2: SIMD3<Float> }
    private var creases: [Crease] = []
    var isEmpty: Bool { creases.isEmpty }

    /// `faces` limits the outline to those B-rep faces (all faces when nil).
    init(_ mesh: KernelMesh, faces: Set<Int>? = nil) {
        // Rounded floats rather than integers: any coordinate (however far out) is a valid key.
        func key(_ p: SIMD3<Float>) -> SIMD3<Float> { (p * 1e4).rounded(.toNearestOrAwayFromZero) }
        for (face, range) in mesh.faces.enumerated() where !range.isEmpty && faces.map({ $0.contains(face) }) ?? true {
            let vertices = Set(mesh.indices[range])
            guard let first = vertices.first.map({ mesh.normals[Int($0)] }),
                  vertices.contains(where: { simd_dot(mesh.normals[Int($0)], first) < 0.9999 }) else { continue }
            // Weld by position so periodic seams (duplicated nodes) still join their neighbours.
            var welded: [SIMD3<Float>: Int] = [:]
            var edges: [[Int]: (a: SIMD3<Float>, b: SIMD3<Float>, normals: [SIMD3<Float>])] = [:]
            for t in stride(from: range.lowerBound, to: range.upperBound, by: 3) {
                let p = (0..<3).map { mesh.positions[Int(mesh.indices[t + $0])] }
                let n = simd_cross(p[1] - p[0], p[2] - p[0])
                guard simd_length(n) > 1e-12 else { continue }
                let ids = p.map { point in welded[key(point)] ?? { welded[key(point)] = welded.count; return welded.count - 1 }() }
                for i in 0..<3 {
                    let j = (i + 1) % 3
                    let edge = [min(ids[i], ids[j]), max(ids[i], ids[j])]
                    edges[edge, default: (p[i], p[j], [])].normals.append(simd_normalize(n))
                }
            }
            for edge in edges.values where edge.normals.count == 2 {
                creases.append(Crease(a: edge.a, b: edge.b, n1: edge.normals[0], n2: edge.normals[1]))
            }
        }
    }

    /// Segments where the surface turns from facing `viewDirection` to facing away. Facets within
    /// `tolerance` of edge-on count as facing, so a surface seen straight along its rulings (a
    /// cylinder from the end) has no outline from round-off.
    func segments(viewDirection: SIMD3<Float>, tolerance: Float = 0) -> [(SIMD3<Float>, SIMD3<Float>)] {
        creases.compactMap { crease in
            (simd_dot(crease.n1, viewDirection) > -tolerance) != (simd_dot(crease.n2, viewDirection) > -tolerance) ? (crease.a, crease.b) : nil
        }
    }
}
