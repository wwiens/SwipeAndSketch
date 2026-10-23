import Foundation

struct Workspace: Equatable, Sendable {
    var version = 1
    var shapes: [SketchShape] = []
    var bodies: [SolidBody] = []
    /// Every shape belongs to exactly one sketch here, on the sketch's plane. See Sketches.swift.
    var sketches: [Sketch] = []
    /// Reference planes for sketching (ConstructionPlanes.swift). They are not part of any solid.
    var constructionPlanes: [ConstructionPlane] = []
    /// Shapes imported from STEP files (Import.swift), each stored once and shared by the solids
    /// made from it. Kept in step with the solids by `pruneImportedShapes`.
    var importedShapes: [ImportedShape] = []
    /// Model Tree groups (Groups.swift), in the order they were made.
    var groups: [ItemGroup] = []

    init(version: Int = 1, shapes: [SketchShape] = [], bodies: [SolidBody] = [], sketches: [Sketch] = [],
         constructionPlanes: [ConstructionPlane] = []) {
        self.version = version; self.shapes = shapes; self.bodies = bodies; self.sketches = sketches
        self.constructionPlanes = constructionPlanes
        normalizeSketches()
    }

    var isValid: Bool {
        version == 1 && shapes.allSatisfy(\.isValid) && bodies.allSatisfy(\.isValid) &&
        Set(shapes.map(\.id)).count == shapes.count && Set(bodies.map(\.id)).count == bodies.count && sketchesAreValid &&
        constructionPlanes.count <= 1_000 && constructionPlanes.allSatisfy(\.isValid) &&
        Set(constructionPlanes.map(\.id)).count == constructionPlanes.count &&
        Set(importedShapes.map(\.id)).count == importedShapes.count && importedShapesAreComplete && groupsAreValid
    }

    /// Every imported shape a solid uses is stored here.
    var importedShapesAreComplete: Bool {
        let stored = Set(importedShapes.map(\.id))
        return bodies.allSatisfy { $0.importedShapeIDs.isSubset(of: stored) }
    }

    /// Drops imported shapes no solid uses any more (after a delete), so files do not keep them.
    mutating func pruneImportedShapes() {
        guard !importedShapes.isEmpty else { return }
        let used = bodies.reduce(into: Set<UUID>()) { $0.formUnion($1.importedShapeIDs) }
        if importedShapes.contains(where: { !used.contains($0.id) }) { importedShapes.removeAll { !used.contains($0.id) } }
    }
}

struct WorkspaceHistory {
    private(set) var workspace: Workspace
    private var past: [Workspace] = []
    private var future: [Workspace] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    init(workspace: Workspace = Workspace()) { self.workspace = workspace }

    mutating func commit(_ updated: Workspace) {
        guard updated != workspace, updated.isValid else { return }
        past.append(workspace)
        if past.count > 100 { past.removeFirst() }
        workspace = updated
        future.removeAll()
    }
    /// Replaces the latest step in place (e.g. a keypad value for the move just made), so it stays one undo step.
    mutating func amend(_ updated: Workspace) {
        guard canUndo, updated.isValid else { return }
        workspace = updated
        future.removeAll()
    }
    mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(workspace)
        workspace = previous
    }
    mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(workspace)
        workspace = next
    }
}
