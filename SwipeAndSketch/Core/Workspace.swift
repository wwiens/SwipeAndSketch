import Foundation

/// A notebook linked to a whole sketch or body. Missing targets are intentional: deleting
/// geometry must never delete its design rationale. Names are snapshots for that case.
struct ObjectNote: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case sketch, body }
    var id = UUID()
    var kind: Kind
    var objectID: UUID
    var objectName: String
    var text = ""
}

struct Workspace: Equatable, Sendable {
    var version = 1
    /// Project notebook (version 2) and linked notebooks (version 3) protect older readers from data loss.
    static let maximumNotesBytes = 256 * 1024
    var notes = ""
    var objectNotes: [ObjectNote] = []
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
         constructionPlanes: [ConstructionPlane] = [], notes: String = "", objectNotes: [ObjectNote] = []) {
        self.notes = notes
        self.objectNotes = objectNotes
        self.version = max(version, !objectNotes.isEmpty ? 3 : notes.isEmpty ? 1 : 2); self.shapes = shapes; self.bodies = bodies; self.sketches = sketches
        self.constructionPlanes = constructionPlanes
        normalizeSketches()
    }

    var notesAreValid: Bool {
        (1...3).contains(version) && (notes.isEmpty || version >= 2) &&
        (objectNotes.isEmpty || version == 3) && objectNotes.count <= 1_000 &&
        Set(objectNotes.map(\.id)).count == objectNotes.count &&
        Set(objectNotes.map { "\($0.kind.rawValue):\($0.objectID)" }).count == objectNotes.count &&
        objectNotes.allSatisfy { !$0.objectName.isEmpty && $0.objectName.count <= 256 && $0.text.utf8.count <= Self.maximumNotesBytes } &&
        notes.utf8.count + objectNotes.reduce(0) { $0 + $1.text.utf8.count } <= Self.maximumNotesBytes
    }

    /// Changes only notebook metadata on an already validated workspace. Model validation can
    /// be quadratic in profile size and must not run just because the user entered text.
    func replacingNotes(_ text: String, objectNote: ObjectNote? = nil) -> Workspace? {
        guard (1...3).contains(version), text.utf8.count <= Self.maximumNotesBytes else { return nil }
        var result = self
        if var note = objectNote {
            note.text = text
            if let index = result.objectNotes.firstIndex(where: { $0.id == note.id }) { result.objectNotes[index] = note }
            else { result.objectNotes.append(note) }
        } else {
            result.notes = text
        }
        result.fitNotesVersion()
        return result.notesAreValid ? result : nil
    }

    /// The lowest file version that holds these notes, so an app that predates notes still opens a
    /// file whose notes were all cleared: 1 without notes, 2 with project notes, 3 with linked ones.
    mutating func fitNotesVersion() {
        version = !objectNotes.isEmpty ? 3 : notes.isEmpty ? 1 : 2
    }

    func objectNote(kind: ObjectNote.Kind, id: UUID) -> ObjectNote? {
        objectNotes.first { $0.kind == kind && $0.objectID == id }
    }

    func name(for note: ObjectNote) -> String? {
        switch note.kind {
        case .body: bodyNames[note.objectID]
        case .sketch: sketchNames[note.objectID]
        }
    }

    /// Each linked note keeps its object's name: the name it has here, or, for an object gone
    /// since `previous`, the last name it had there.
    mutating func captureObjectNoteNames(since previous: Workspace? = nil) {
        guard !objectNotes.isEmpty else { return }
        let bodies = bodyNames, sketches = sketchNames
        let oldBodies = previous?.bodyNames ?? [:], oldSketches = previous?.sketchNames ?? [:]
        for index in objectNotes.indices {
            let note = objectNotes[index]
            let name = note.kind == .body ? bodies[note.objectID] ?? oldBodies[note.objectID] : sketches[note.objectID] ?? oldSketches[note.objectID]
            if let name { objectNotes[index].objectName = String(name.prefix(256)) }
        }
    }

    /// Includes every model field, including visibility, names, and kept dimensions. Only the
    /// notebook and its file-version upgrade are ignored; future model fields compare by default.
    func hasSameModel(as other: Workspace) -> Bool {
        var model = other
        model.notes = notes
        model.objectNotes = objectNotes
        model.version = version
        return self == model
    }

    var isValid: Bool {
        notesAreValid && shapes.allSatisfy(\.isValid) && bodies.allSatisfy(\.isValid) &&
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
    /// False, changing nothing, when there is no step to replace or the result is not a valid model.
    @discardableResult mutating func amend(_ updated: Workspace) -> Bool {
        guard canUndo, updated.isValid else { return false }
        workspace = updated
        future.removeAll()
        return true
    }
    /// The existing model is unchanged, so validate only the replacement notebook. The first
    /// save records the base; subsequent autosaves amend that same undo step.
    @discardableResult mutating func updateNotes(_ text: String, objectNote: ObjectNote? = nil, amending: Bool) -> Bool {
        guard let updated = workspace.replacingNotes(text, objectNote: objectNote), updated != workspace else { return false }
        if amending {
            guard canUndo else { return false }
        } else {
            past.append(workspace)
            if past.count > 100 { past.removeFirst() }
        }
        workspace = updated
        future.removeAll()
        return true
    }

    @discardableResult mutating func deleteObjectNote(_ id: UUID) -> Bool {
        guard workspace.objectNotes.contains(where: { $0.id == id }) else { return false }
        past.append(workspace)
        if past.count > 100 { past.removeFirst() }
        workspace.objectNotes.removeAll { $0.id == id }
        workspace.fitNotesVersion()
        future.removeAll()
        return true
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
