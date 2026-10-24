import Foundation
import simd

/// Mirror: sketches and solids reflected across a plane. A mirrored
/// solid is an ordinary solid: its whole definition (profile, revolve, every cut, join, hole,
/// shell, face extrusion, and merged or subtracted solid) is reflected, and its fillets, chamfers,
/// and shell faces are renamed to the matching mirrored edges and faces. No new file data.
///
/// A plane's reflection keeps its x axis and flips its y axis, so its normal is the reflected
/// normal and extrusion depths keep their sign; 2D points (u, v) become (u, −v). Outlines are
/// reversed so they stay counter-clockwise.
struct Reflection: Sendable {
    var origin: SIMD3<Double>
    var normal: SIMD3<Double>

    init?(across plane: SketchPlane) {
        let n = plane.normalAxis
        guard simd_length(n) > 1e-9 else { return nil }
        origin = plane.origin; normal = simd_normalize(n)
    }

    func point(_ p: SIMD3<Double>) -> SIMD3<Double> { p - normal * (2 * simd_dot(p - origin, normal)) }
    func vector(_ v: SIMD3<Double>) -> SIMD3<Double> { v - normal * (2 * simd_dot(v, normal)) }
    func plane(_ plane: SketchPlane) -> SketchPlane? {
        SketchPlane.cleaned(origin: point(plane.origin), xAxis: vector(plane.xAxis), yAxis: -vector(plane.yAxis))
    }
    /// A sketch point on a reflected plane.
    static func flip(_ p: Point2) -> Point2 { Point2(x: p.x, y: -p.y) }
}

/// The plane to mirror across: a construction plane, a plane at the
/// origin, a flat face, a sketch region's plane, or the plane through a sketch line square to its
/// sketch. Picked like Split Body's tools.
struct MirrorPlane: Equatable, Sendable {
    var source: SplitTool.Source
    var plane: SketchPlane

    static func reference(_ reference: PlaneReference, in workspace: Workspace) -> MirrorPlane? {
        SplitTool.reference(reference, in: workspace).map { MirrorPlane(source: $0.source, plane: $0.plane) }
    }

    static func line(_ shape: SketchShape) -> MirrorPlane? {
        SplitTool.line(shape).map { MirrorPlane(source: $0.source, plane: $0.plane) }
    }
}

extension SketchProfile {
    /// The same region reflected: v flipped and the outline reversed (starting at the same point)
    /// so it stays counter-clockwise; exact arcs follow their points.
    func mirrored(by reflection: Reflection) -> SketchProfile? {
        guard let plane = reflection.plane(plane) else { return nil }
        var result = self
        result.plane = plane
        (result.outline, result.circle, result.arcs) = Self.mirrored(outline, circle, arcs)
        result.ellipse = ellipse.map(Self.mirrored)
        result.holes = holes?.map { hole in
            let loop = Self.mirrored(hole.outline, hole.circle, hole.arcs)
            return ProfileHole(outline: loop.0, circle: loop.1, arcs: loop.2, ellipse: hole.ellipse.map(Self.mirrored))
        }
        return result
    }

    /// An ellipse across the sketch's x axis: its axis turns the other way.
    private static func mirrored(_ ellipse: EllipseProfile) -> EllipseProfile {
        EllipseProfile(center: Reflection.flip(ellipse.center), radiusX: ellipse.radiusX, radiusY: ellipse.radiusY, angle: -ellipse.angle)
    }

    private static func mirrored(_ outline: [Point2], _ circle: CircleProfile?, _ arcs: [ProfileArc]?) -> ([Point2], CircleProfile?, [ProfileArc]?) {
        let n = outline.count
        // Point j moves to (n − j) mod n, so an arc over points s…s+g now runs from n − s − g.
        return ((0..<n).map { Reflection.flip(outline[(n - $0) % n]) },
                circle.map { CircleProfile(center: Reflection.flip($0.center), radius: $0.radius) },
                arcs.map { arcs in
                    arcs.map { ProfileArc(start: ((n - $0.start - $0.segments) % n + n) % n, segments: $0.segments,
                                          center: Reflection.flip($0.center), radius: $0.radius) }
                })
    }
}

extension RevolveSpec {
    /// The axis reflected and its ends swapped: a reflection reverses the sense of a turn, and
    /// reversing the axis restores it, so the angle and the profile's side of the axis are unchanged.
    var mirrored: RevolveSpec { RevolveSpec(from: Reflection.flip(to), to: Reflection.flip(from), angle: angle) }
}

extension SketchShape {
    /// The same shape on the reflected plane. Arcs swap their ends to stay counter-clockwise.
    func mirrored(by reflection: Reflection) -> SketchShape? {
        guard let plane = reflection.plane(plane) else { return nil }
        var result = self
        result.plane = plane
        if kind == .arc {
            result.start = Reflection.flip(end); result.end = Reflection.flip(start)
        } else {
            result.start = Reflection.flip(start); result.end = Reflection.flip(end)
        }
        result.arcCenter = arcCenter.map(Reflection.flip)
        result.points = points.map { $0.map(Reflection.flip) }
        return result
    }
}

extension SolidBody {
    /// This solid reflected, as a definition that builds the mirror image. Nil when a finish or
    /// shell face cannot be matched on the mirror image, or the result does not build.
    func mirrored(by reflection: Reflection) -> SolidBody? {
        guard let profile = profile.mirrored(by: reflection) else { return nil }
        var result = self
        result.profile = profile
        result.revolve = revolve?.mirrored
        if let imported {
            // The same stored shape, flipped in its new frame: its edges keep their numbers, so
            // finishes carry over unchanged.
            result.imported = ImportedBase(shape: imported.shape, mirrored: imported.mirrored == true ? nil : true)
        }
        result.finishes = []
        result.cuts = []
        guard let base = try? SolidKernel.base(of: self) else { return nil }
        // Rename finishes and shell faces by matching the original edges and faces to their reflections.
        var edges: [ExtrusionEdge: ExtrusionEdge] = [:]
        if imported != nil {
            for finish in finishes { for edge in finish.edges { edges[edge] = edge } }
        } else if !finishes.isEmpty || cuts.contains(where: { $0.finish?.edges.contains { $0.name != nil } ?? false }) {
            for edge in 0..<base.edgeCount {
                let samples = base.edgeSamples(edge)
                if let name = extrusionEdge(along: samples), let image = result.extrusionEdge(along: samples.map(reflection.point)) {
                    edges[name] = image
                }
            }
        }
        var faces: [ExtrusionFace: ExtrusionFace] = [:]
        if cuts.contains(where: { !($0.shell?.openFaces ?? []).isEmpty }) {
            for face in 0..<base.faceCount {
                guard let name = extrusionFace(face, of: base), let plane = base.facePlane(face) else { continue }
                let center = base.faceCenter(face) ?? plane.origin
                if let image = result.extrusionFace(point: reflection.point(center), normal: reflection.vector(plane.normal)) { faces[name] = image }
            }
        }
        for finish in finishes {
            var copy = finish
            copy.id = UUID()
            copy.edges = finish.edges.compactMap { edges[$0] }
            guard copy.edges.count == finish.edges.count else { return nil }
            result.finishes.append(copy)
        }
        for cut in cuts {
            var copy = cut
            copy.id = UUID()
            guard let cutProfile = cut.profile.mirrored(by: reflection) else { return nil }
            copy.profile = cutProfile
            copy.facePoint = cut.facePoint.map(Reflection.flip)
            copy.revolve = cut.revolve?.mirrored
            if let merged = cut.merged {
                guard let image = merged.mirrored(by: reflection) else { return nil }
                copy.merged = image
            }
            if let subtracted = cut.subtracted {
                guard let image = subtracted.mirrored(by: reflection) else { return nil }
                copy.subtracted = image
            }
            if let intersected = cut.intersected {
                guard let image = intersected.mirrored(by: reflection) else { return nil }
                copy.intersected = image
            }
            if var finish = cut.finish {
                // Points are in the solid's own frame, whose y axis the reflection flips; names follow
                // their mirrored edges (a name with no image is dropped, leaving the point).
                finish.edges = finish.edges.map { reference in
                    var image = reference
                    image.point = SIMD3(reference.point.x, -reference.point.y, reference.point.z)
                    image.name = reference.name.flatMap { edges[$0] }
                    return image
                }
                copy.finish = finish
            }
            copy.scale = cut.scale?.mirrored
            // Points are in the solid's own frame, whose y axis the reflection flips.
            if var removed = cut.removedFaces { removed.points = removed.points.map { SIMD3($0.x, -$0.y, $0.z) }; copy.removedFaces = removed }
            if var draft = cut.draft {
                draft.points = draft.points.map { SIMD3($0.x, -$0.y, $0.z) }
                draft.origin = SIMD3(draft.origin.x, -draft.origin.y, draft.origin.z); draft.pull = SIMD3(draft.pull.x, -draft.pull.y, draft.pull.z)
                copy.draft = draft
            }
            if var rib = cut.rib {
                rib.start = SIMD3(rib.start.x, -rib.start.y, rib.start.z); rib.end = SIMD3(rib.end.x, -rib.end.y, rib.end.z)
                rib.normal = SIMD3(rib.normal.x, -rib.normal.y, rib.normal.z)
                // Reflected, the side of the line the web runs to turns over.
                rib.side = -rib.side
                copy.rib = rib
            }
            if var moved = cut.movedFaces { moved.points = moved.points.map { SIMD3($0.x, -$0.y, $0.z) }; copy.movedFaces = moved }
            copy.thread = cut.thread?.mirrored
            copy.text = cut.text?.mirrored
            if var shell = cut.shell {
                let open = shell.openFaces.compactMap { faces[$0] }
                guard open.count == shell.openFaces.count else { return nil }
                shell.openFaces = open
                // Points are in the solid's own frame, whose y axis the reflection flips.
                shell.openPoints = shell.openPoints?.map { SIMD3($0.x, -$0.y, $0.z) }
                copy.shell = shell
            }
            result.cuts.append(copy)
        }
        return result
    }
}

enum Mirroring {
    /// Mirrors the solids and sketches across `plane`. With `keepOriginals`, each mirror image is
    /// a new solid or sketch right after its original; otherwise it replaces the original (same
    /// id, same place in Items). Returns what was made; nil if anything cannot be mirrored.
    static func mirror(_ workspace: Workspace, bodies: [UUID], sketches: [UUID], across plane: SketchPlane,
                       keepOriginals: Bool) -> (workspace: Workspace, bodies: [UUID], sketches: [UUID])? {
        guard let reflection = Reflection(across: plane), !(bodies.isEmpty && sketches.isEmpty) else { return nil }
        var result = workspace
        var madeBodies: [UUID] = [], madeSketches: [UUID] = []
        for id in bodies {
            guard let index = result.bodies.firstIndex(where: { $0.id == id }), var image = result.bodies[index].mirrored(by: reflection),
                  (try? SolidKernel.solid(for: image)) != nil else { return nil }
            if keepOriginals {
                image.id = UUID()
                image.hidden = nil
                result.bodies.insert(image, at: index + 1)
            } else {
                result.bodies[index] = image
            }
            madeBodies.append(image.id)
        }
        for id in sketches {
            guard let index = result.sketches.firstIndex(where: { $0.id == id }),
                  let mirroredPlane = reflection.plane(result.sketches[index].plane) else { return nil }
            let shapes = result.shapes.filter { $0.sketch == id }
            let images = shapes.compactMap { $0.mirrored(by: reflection) }
            guard images.count == shapes.count, !images.isEmpty else { return nil }
            if keepOriginals {
                let sketchID = UUID()
                result.sketches.insert(Sketch(id: sketchID, plane: mirroredPlane), at: index + 1)
                result.shapes += images.map { var shape = $0; shape.id = UUID(); shape.sketch = sketchID; return shape }
                madeSketches.append(sketchID)
            } else {
                result.sketches[index].plane = mirroredPlane
                for image in images { if let i = result.shapes.firstIndex(where: { $0.id == image.id }) { result.shapes[i] = image } }
                madeSketches.append(id)
            }
        }
        return result.isValid ? (result, madeBodies, madeSketches) : nil
    }
}
