import Foundation
import SSKernel
import simd

/// Exact geometry brought in from a STEP file (schema 15): one solid in OCCT's binary B-rep format,
/// in its own coordinates. Stored once per project in `Workspace.importedShapes` and shared by
/// every solid made from it (copies and mirror images). A given id always has the same bytes, so
/// equality compares ids, never megabytes of data.
struct ImportedShape: Codable, Sendable {
    var id: UUID
    /// The file it came from, for Items.
    var name: String
    var data: Data
}

extension ImportedShape: Equatable {
    static func == (a: ImportedShape, b: ImportedShape) -> Bool { a.id == b.id && a.name == b.name }
}

extension ImportedShape {
    /// The name as Items and the assistant show it: one line, at most 60 characters (a file can
    /// carry any text here, and the assistant's prompt includes it).
    var displayName: String {
        let words = name.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)).filter { !$0.isEmpty }
        let line = String(words.joined(separator: " ").prefix(60))
        return line.isEmpty ? "Imported solid" : line
    }
}

extension Workspace {
    /// Each solid's name: "Body 01" (by position), or an imported solid's file name, numbered
    /// "bracket (2)" when several solids share it. Names are unique, ignoring case.
}

/// A solid whose base is an imported shape instead of an extrusion. The shape sits in the solid's
/// frame (its `profile.plane`: shape x, y, z along the plane's x axis, y axis, and normal), so
/// moving the solid moves the frame; `mirrored` flips the shape's y first (a mirror image, see
/// Mirror.swift). The profile is a placeholder covering the shape and is never built.
struct ImportedBase: Codable, Equatable, Sendable {
    var shape: UUID
    /// Omitted when false.
    var mirrored: Bool?
}

/// The imported shapes of the open projects, decoded once, for the kernel. Shapes are registered
/// when a workspace is decoded or a file is imported, and kept for the session, so undo and redo
/// always find them.
final class ImportedShapes: @unchecked Sendable {
    static let shared = ImportedShapes()
    private let lock = NSRecursiveLock()
    private var data: [UUID: Data] = [:]
    private var solids: [UUID: KernelSolid] = [:]
    private var edges: [UUID: [EdgeSamples]] = [:]
    private var grids: [UUID: EdgeGrid] = [:]

    /// Edges by the grid cells their (padded) boxes cover, so a point finds the few edges near it
    /// instead of testing thousands.
    struct EdgeGrid {
        var origin: SIMD3<Double>
        var cell: Double
        var cells: [SIMD3<Int32>: [Int]]
        /// Edges too long to list cell by cell; always candidates.
        var large: [Int]
        func key(_ p: SIMD3<Double>) -> SIMD3<Int32> {
            // The shape covers about 64 cells; far-off or invalid points land in empty cells instead of trapping.
            let index = ((p - origin) / cell).rounded(.down)
            let finite = index.replacing(with: 0, where: .!(index .== index))
            return SIMD3<Int32>(finite.clamped(lowerBound: SIMD3(repeating: -100_000), upperBound: SIMD3(repeating: 100_000)))
        }
        func candidates(near p: SIMD3<Double>) -> [Int] { (cells[key(p)] ?? []) + large }
    }

    func edgeGrid(_ id: UUID) -> EdgeGrid? {
        lock.lock(); defer { lock.unlock() }
        if let cached = grids[id] { return cached }
        let edges = edgeSamples(id)
        guard let first = edges.first else { return nil }
        var low = first.low, high = first.high
        for edge in edges { low = simd_min(low, edge.low); high = simd_max(high, edge.high) }
        let pad = 0.01, cell = max(0.5, simd_reduce_max(high - low) / 64)
        var grid = EdgeGrid(origin: low - SIMD3(repeating: pad), cell: cell, cells: [:], large: [])
        for (index, edge) in edges.enumerated() {
            let a = grid.key(edge.low - SIMD3(repeating: pad)), b = grid.key(edge.high + SIMD3(repeating: pad))
            let span = b &- a &+ 1
            guard Int(span.x) * Int(span.y) * Int(span.z) <= 512 else { grid.large.append(index); continue }
            for x in a.x...b.x { for y in a.y...b.y { for z in a.z...b.z { grid.cells[SIMD3(x, y, z), default: []].append(index) } } }
        }
        grids[id] = grid
        return grid
    }

    /// Points along an edge of a stored shape, with a box sure to contain the whole edge, for quick matching.
    struct EdgeSamples {
        var points: [SIMD3<Double>]
        var low: SIMD3<Double>
        var high: SIMD3<Double>
    }

    func register(_ shapes: [ImportedShape]) {
        lock.lock(); defer { lock.unlock() }
        // An id keeps its bytes; only a damaged or crafted file reuses one with others. The file
        // being read must then be checked and shown with its own bytes, not the cached shape.
        for shape in shapes where data[shape.id] != shape.data {
            data[shape.id] = shape.data
            solids[shape.id] = nil; edges[shape.id] = nil; grids[shape.id] = nil
        }
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return data[id] != nil
    }

    /// The stored shape, in its own coordinates.
    func solid(_ id: UUID) throws -> KernelSolid {
        lock.lock(); defer { lock.unlock() }
        if let solid = solids[id] { return solid }
        guard let bytes = data[id] else { throw SolidKernel.Failure(message: "The imported shape is missing from this project") }
        let solid = try SolidKernel.shape(from: bytes)
        solids[id] = solid
        return solid
    }

    /// Every edge of the stored shape, in its stable order, as sample points.
    func edgeSamples(_ id: UUID) -> [EdgeSamples] {
        lock.lock(); defer { lock.unlock() }
        if let cached = edges[id] { return cached }
        guard let solid = try? solid(id) else { return [] }
        let result = (0..<solid.edgeCount).map { edge -> EdgeSamples in
            let points = solid.edgeSamples(edge, count: 9)
            let first = points.first ?? .zero
            let low = points.reduce(first) { simd_min($0, $1) }, high = points.reduce(first) { simd_max($0, $1) }
            // A curved edge bulges between its samples (by up to 8% of a circle's radius), so the
            // box is padded well past that.
            let pad = SIMD3<Double>(repeating: 0.15 * simd_reduce_max(high - low) + 1e-3)
            return EdgeSamples(points: points, low: low - pad, high: high + pad)
        }
        edges[id] = result
        return result
    }
}

extension SolidBody {
    /// A solid from an imported shape, placed where the file put it.
    static func fromImport(_ shape: ImportedShape, solid: KernelSolid) -> SolidBody {
        let bounds = solid.bounds
        // Any valid region will do: the placeholder is never built.
        let low = Point2(x: bounds.min.x, y: bounds.min.y)
        let high = Point2(x: max(bounds.max.x, bounds.min.x + 1), y: max(bounds.max.y, bounds.min.y + 1))
        let outline = [low, Point2(x: high.x, y: low.y), high, Point2(x: low.x, y: high.y)]
        var body = SolidBody(profile: SketchProfile(id: "imported." + shape.id.uuidString, plane: .top, sourceIDs: [], outline: outline), depth: 1)
        body.imported = ImportedBase(shape: shape.id)
        return body
    }

    var isImported: Bool { imported != nil }

    func worldToImported(_ world: SIMD3<Double>) -> SIMD3<Double> {
        let local = localPoint(world)
        return SIMD3(local.x, imported?.mirrored == true ? -local.y : local.y, local.z)
    }

    /// The edges of an imported shape, by their index in the stored shape (which never changes).
    var importedEdges: [ExtrusionEdge] {
        guard let imported else { return [] }
        return ImportedShapes.shared.edgeSamples(imported.shape).indices.map { ExtrusionEdge(position: .imported, index: $0) }
    }

    /// Which stored edge a curve on the current solid lies along: bounding boxes first, then the
    /// kernel's exact distance from each sample to the candidate edge.
    func importedEdge(along samples: [SIMD3<Double>], tolerance: Double) -> ExtrusionEdge? {
        guard let imported, samples.count >= 2, let base = try? ImportedShapes.shared.solid(imported.shape) else { return nil }
        let local = samples.map(worldToImported)
        let pad = SIMD3<Double>(repeating: tolerance)
        let edges = ImportedShapes.shared.edgeSamples(imported.shape)
        let candidates = ImportedShapes.shared.edgeGrid(imported.shape)?.candidates(near: local[0]) ?? Array(edges.indices)
        for index in candidates.sorted() {
            let edge = edges[index]
            guard local.allSatisfy({ all($0 .>= edge.low - pad) && all($0 .<= edge.high + pad) }) else { continue }
            if local.allSatisfy({ point in
                let d = base.edgeDistance(index, to: point)
                return d >= 0 && d <= tolerance
            }) { return ExtrusionEdge(position: .imported, index: index) }
        }
        return nil
    }

    /// Imported shapes this solid uses, nested solids included.
    var importedShapeIDs: Set<UUID> {
        var ids = Set(imported.map { [$0.shape] } ?? [])
        for cut in cuts { if let nested = cut.nestedSolid { ids.formUnion(nested.importedShapeIDs) } }
        return ids
    }

}

extension SolidKernel {
    /// The solids of a STEP file, in millimeters, and how many open surface pieces were left out.
    static func importSTEP(at url: URL) throws -> (solids: [KernelSolid], skipped: Int) {
        var skipped: Int32 = 0
        let all = try url.withUnsafeFileSystemRepresentation { path -> KernelSolid in
            guard let path else { throw Failure(message: "The file cannot be opened") }
            guard let pointer = ssk_read_step(path, &skipped) else { throw kernelFailure("The STEP file could not be read") }
            return KernelSolid(adopting: pointer)
        }
        let solids = try (0..<Int(ssk_solid_count(all.handle))).map { index -> KernelSolid in
            guard let pointer = ssk_solid(all.handle, Int32(index)) else { throw kernelFailure("A solid could not be read") }
            return KernelSolid(adopting: pointer)
        }
        return (solids, Int(skipped))
    }

    /// A shape from OCCT binary B-rep bytes.
    static func shape(from data: Data) throws -> KernelSolid {
        let pointer = data.withUnsafeBytes { bytes in
            ssk_read_shape(bytes.bindMemory(to: UInt8.self).baseAddress, Int64(bytes.count))
        }
        guard let pointer else { throw kernelFailure("The imported shape could not be read") }
        return KernelSolid(adopting: pointer)
    }

    /// An imported solid's base: its stored shape placed by the solid's frame (mirrored if flagged).
    static func importedBase(of body: SolidBody) throws -> KernelSolid {
        guard let imported = body.imported else { throw Failure(message: "Not an imported solid") }
        let shape = try ImportedShapes.shared.solid(imported.shape)
        let plane = body.profile.plane, x = plane.xAxis, y = plane.yAxis * (imported.mirrored == true ? -1 : 1), n = plane.normalAxis, o = plane.origin
        let matrix = [x.x, y.x, n.x, o.x, x.y, y.y, n.y, o.y, x.z, y.z, n.z, o.z]
        guard let pointer = ssk_transform(shape.handle, matrix) else { throw kernelFailure("The imported shape could not be placed") }
        return KernelSolid(adopting: pointer)
    }

    fileprivate static func kernelFailure(_ fallback: String) -> Failure {
        Failure(message: ssk_last_error().map { String(cString: $0) } ?? fallback)
    }
}

extension KernelSolid {
    /// The shape in OCCT's binary B-rep format.
    func shapeData() throws -> Data {
        var length: Int64 = 0
        guard let bytes = ssk_write_shape(handle, &length) else {
            throw SolidKernel.Failure(message: ssk_last_error().map { String(cString: $0) } ?? "The shape could not be saved")
        }
        defer { ssk_bytes_free(bytes) }
        return Data(bytes: bytes, count: Int(length))
    }

    /// Distance from a point to an edge, or −1.
    func edgeDistance(_ edge: Int, to point: SIMD3<Double>) -> Double {
        ssk_edge_distance(handle, Int32(edge), SSKVec3(x: point.x, y: point.y, z: point.z))
    }
}

/// STEP import: every closed solid in the file becomes a solid of its own,
/// where the file put it and in millimeters, built from its exact shape stored in the project.
enum STEPImport {
    struct Result: Sendable {
        var shapes: [ImportedShape]
        var bodies: [SolidBody]
        /// Open surface pieces that could not be closed into a solid.
        var skipped: Int
        /// The file's name, which names the group the solids go into.
        var name = ""
    }

    /// Reads a STEP file. `name` (the file's name) names the shapes: "bracket", or "bracket 1",
    /// "bracket 2", … for several solids.
    static func read(_ url: URL, name: String) throws -> Result {
        // The reader holds the whole model in memory several times over; refuse what cannot fit a project anyway.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumFileBytes {
            throw SolidKernel.Failure(message: "This STEP file is too large to import (over \(maximumFileBytes / 1_048_576) MB).")
        }
        let file = try SolidKernel.importSTEP(at: url)
        var result = Result(shapes: [], bodies: [], skipped: file.skipped, name: name)
        for (index, solid) in file.solids.enumerated() {
            let shape = ImportedShape(id: UUID(), name: file.solids.count > 1 ? "\(name) \(index + 1)" : name, data: try solid.shapeData())
            result.shapes.append(shape)
            result.bodies.append(.fromImport(shape, solid: solid))
        }
        // Buildable at once (previews, tests); the bytes for these ids never change.
        ImportedShapes.shared.register(result.shapes)
        return result
    }

    static let maximumFileBytes = 250 * 1024 * 1024

    /// The workspace with the imported solids added after the others, together in a new Model Tree
    /// group named after the file (October 21, 2026); nil if it would be invalid or too large to
    /// save (shape bytes are stored as base64, a third larger).
    static func adding(_ result: Result, to workspace: Workspace) -> Workspace? {
        ImportedShapes.shared.register(result.shapes)
        var next = workspace
        next.importedShapes += result.shapes
        var bodies = result.bodies
        if !bodies.isEmpty && next.groups.count < Workspace.maximumGroups {
            let group = ItemGroup(name: ItemNames.cleaned(result.name) ?? "Import")
            next.groups.append(group)
            for index in bodies.indices { bodies[index].group = group.id }
        }
        next.bodies += bodies
        let stored = next.importedShapes.reduce(0) { $0 + $1.data.count } * 4 / 3
        return next.isValid && next.bodies.count <= 1_000 && stored < ProjectCodec.maximumFileBytes * 9 / 10 ? next : nil
    }
}
