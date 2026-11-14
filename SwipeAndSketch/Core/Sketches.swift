import Foundation
import simd

/// A sketch: a named group of shapes on one plane (schema 8).
/// Names are derived from document order ("Sketch 01"). A plane may hold several sketches; each
/// sketch finds its own closed regions. Moving or rotating a sketch changes only its plane.
struct Sketch: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var plane: SketchPlane
    /// Hidden from the canvas (not drawn, picked, or snapped to). Omitted when visible.
    var hidden: Bool?
    /// The name chosen in the Model Tree (Naming.swift). Omitted when unset.
    var name: String?
    /// The Model Tree group it sits in (Groups.swift). Omitted at the top of the tree.
    var group: UUID?
    /// Dimensions kept in it (SketchDimensions.swift). Omitted when there are none.
    var dimensions: [KeptDimension]?
    /// The edges of the solid face it was drawn on (October 30, 2026; see `FaceEdge`), so the face
    /// less what is drawn on it is a region too. Omitted for sketches not drawn on a face.
    var faceEdges: [FaceEdge]?
    var isHidden: Bool { hidden == true }
    var faceEdgesAreValid: Bool { faceEdges.map { (1...4_096).contains($0.count) && $0.allSatisfy(\.isValid) } ?? true }

    init(id: UUID, plane: SketchPlane, hidden: Bool? = nil, name: String? = nil, group: UUID? = nil, dimensions: [KeptDimension]? = nil) {
        self.id = id; self.plane = plane; self.hidden = hidden; self.name = name; self.group = group; self.dimensions = dimensions
    }
}

extension Workspace {
    /// Gives every shape a sketch and drops sketches without shapes. A shape without a sketch
    /// (older files, or one just added) joins the last sketch on its plane, or starts one whose
    /// id is the shape's own, so older files always get the same sketches.
    mutating func normalizeSketches() {
        for index in shapes.indices {
            let shape = shapes[index]
            if let id = shape.sketch, sketches.contains(where: { $0.id == id && $0.plane == shape.plane }) { continue }
            if let existing = sketches.last(where: { $0.plane == shape.plane }) {
                shapes[index].sketch = existing.id
            } else {
                sketches.append(Sketch(id: shape.id, plane: shape.plane))
                shapes[index].sketch = shape.id
            }
        }
        let used = Set(shapes.compactMap(\.sketch))
        sketches.removeAll { !used.contains($0.id) }
        pruneKeptDimensions()
    }

    var sketchesAreValid: Bool {
        Set(sketches.map(\.id)).count == sketches.count && sketches.allSatisfy { $0.plane.isValid && ItemNames.isValid($0.name) && $0.dimensionsAreValid && $0.faceEdgesAreValid } &&
            shapes.allSatisfy { shape in sketches.contains { $0.id == shape.sketch && $0.plane == shape.plane } }
    }

    /// True when the sketches are exactly what an older file implies: one visible sketch per
    /// plane, named by its first shape. Such workspaces save without sketch data (schema ≤ 7).
    var sketchesAreImplicit: Bool {
        let implicit = Workspace(shapes: shapes.map { var shape = $0; shape.sketch = nil; return shape })
        return implicit.sketches == sketches && implicit.shapes == shapes
    }

    func sketch(_ id: UUID?) -> Sketch? { sketches.first { $0.id == id } }
    func shapes(in sketch: UUID) -> [SketchShape] { shapes.filter { $0.sketch == sketch } }
    func profiles(in sketch: Sketch) -> [SketchProfile] {
        // Several sketches drawn on one face: the first shown offers the face less what all of them draw.
        guard sketch.faceEdges != nil else { return Geometry.profiles(in: shapes(in: sketch.id), on: sketch.plane) }
        let others = sketches.filter { $0.id != sketch.id && $0.plane == sketch.plane && !isHidden($0) }
        guard sketches.first(where: { $0.plane == sketch.plane && $0.faceEdges != nil && ($0.id == sketch.id || !isHidden($0)) })?.id == sketch.id else {
            return Geometry.profiles(in: shapes(in: sketch.id), on: sketch.plane)
        }
        return Geometry.profiles(in: shapes(in: sketch.id), on: sketch.plane, face: sketch.faceEdges, besides: others.map { shapes(in: $0.id) })
    }
    /// Closed regions of every visible sketch, smallest first within each sketch.
    var profiles: [SketchProfile] { sketches.filter { !isHidden($0) }.flatMap(profiles(in:)) }

    /// What the canvas shows: hidden sketches' shapes, hidden solids, and hidden planes removed,
    /// whether hidden themselves or by a hidden group.
    var visible: Workspace {
        guard sketches.contains(where: \.isHidden) || bodies.contains(where: \.isHidden) ||
                constructionPlanes.contains(where: \.isHidden) || groups.contains(where: \.isHidden) else { return self }
        var result = self
        let hidden = Set(sketches.filter(isHidden).map(\.id))
        result.shapes.removeAll { $0.sketch.map(hidden.contains) ?? false }
        result.sketches.removeAll(where: isHidden)
        result.bodies.removeAll(where: isHidden)
        result.constructionPlanes.removeAll(where: isHidden)
        return result
    }
}

/// Files without sketches (schema ≤ 7) get one sketch per plane; files whose sketches are implicit
/// are written without them, exactly as before.
extension Workspace: Codable {
    private enum CodingKeys: String, CodingKey { case version, shapes, bodies, sketches, constructionPlanes, importedShapes, groups, notes, objectNotes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard (1...3).contains(version) else { throw ProjectError.unsupportedVersion }
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        objectNotes = try container.decodeIfPresent([ObjectNote].self, forKey: .objectNotes) ?? []
        // Imported shapes first: solids built from them look them up while they decode and validate.
        importedShapes = try container.decodeIfPresent([ImportedShape].self, forKey: .importedShapes) ?? []
        ImportedShapes.shared.register(importedShapes)
        shapes = try container.decodeIfPresent([SketchShape].self, forKey: .shapes) ?? []
        bodies = try container.decodeIfPresent([SolidBody].self, forKey: .bodies) ?? []
        sketches = try container.decodeIfPresent([Sketch].self, forKey: .sketches) ?? []
        constructionPlanes = try container.decodeIfPresent([ConstructionPlane].self, forKey: .constructionPlanes) ?? []
        groups = try container.decodeIfPresent([ItemGroup].self, forKey: .groups) ?? []
        if container.contains(.sketches) {
            // Explicit sketches must already account for every shape.
            guard sketchesAreValid else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Shapes and sketches do not match"))
            }
        } else {
            guard shapes.allSatisfy({ $0.sketch == nil }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Shapes name sketches that are missing"))
            }
            normalizeSketches()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if !notes.isEmpty { try container.encode(notes, forKey: .notes) }
        if !objectNotes.isEmpty { try container.encode(objectNotes, forKey: .objectNotes) }
        if sketchesAreImplicit {
            try container.encode(shapes.map { var shape = $0; shape.sketch = nil; return shape }, forKey: .shapes)
        } else {
            try container.encode(shapes, forKey: .shapes)
            try container.encode(sketches, forKey: .sketches)
        }
        try container.encode(bodies, forKey: .bodies)
        // Omitted when there are none, so files without planes are unchanged.
        if !constructionPlanes.isEmpty { try container.encode(constructionPlanes, forKey: .constructionPlanes) }
        if !importedShapes.isEmpty { try container.encode(importedShapes, forKey: .importedShapes) }
        if !groups.isEmpty { try container.encode(groups, forKey: .groups) }
    }
}

extension SolidBody {
    var isHidden: Bool { hidden == true }
}
