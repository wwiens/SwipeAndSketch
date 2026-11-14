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

    /// `name(for:)` for many notes: the name tables are built once, not for each note.
    func noteNames() -> (ObjectNote) -> String? {
        let bodies = bodyNames, sketches = sketchNames
        return { note in note.kind == .body ? bodies[note.objectID] : sketches[note.objectID] }
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

    var isValid: Bool { bodies.allSatisfy(\.isValid) && isValidApartFromBodies }

    /// `isValid` for a change from `known`, a workspace already found valid: a solid it holds
    /// unchanged is not checked again. Checking every solid in full took about 40 ms on each edit,
    /// twice (history, then the document), on an 8-solid case whose solids carry 100-step histories
    /// (November 8, 2026); an edit to one solid now checks that one.
    func isValid(changedFrom known: Workspace) -> Bool {
        let before = Dictionary(known.bodies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return isValidApartFromBodies && bodies.allSatisfy { before[$0.id] == $0 || $0.isValid }
    }

    /// Everything `isValid` checks except each solid's own definition: for a change that leaves
    /// every solid as it was, or only carries solids by a rigid motion (which moves their planes,
    /// each checked as it moves, and leaves the rest of their definition as it was). Checking each
    /// solid's outlines and cuts again on every step of a live drag took the whole frame on a
    /// project whose solids had about 75 steps each (November 5, 2026). Results are still checked
    /// in full when they are kept (`WorkspaceHistory.commit` and `amend`).
    var isValidApartFromBodies: Bool {
        notesAreValid && shapes.allSatisfy(\.isValid) &&
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

    /// At most 100 undo steps, and fewer (never under 10) when each step holds a very large sketch
    /// or many solids: a step shares what it did not change with the others, but copies the list it
    /// changed, so 100 steps of a 10,000-shape sketch held about 200 MB (November 8, 2026).
    static let maximumSteps = 100, minimumSteps = 10, maximumBytes = 64 << 20
    private mutating func trimPast() {
        if past.count > Self.maximumSteps { past.removeFirst(past.count - Self.maximumSteps) }
        func bytes(_ w: Workspace) -> Int {
            w.shapes.count * MemoryLayout<SketchShape>.stride + w.bodies.count * MemoryLayout<SolidBody>.stride
        }
        var total = past.reduce(0) { $0 + bytes($1) }
        while past.count > Self.minimumSteps, total > Self.maximumBytes {
            total -= bytes(past.removeFirst())
        }
    }
    var canRedo: Bool { !future.isEmpty }
    init(workspace: Workspace = Workspace()) { self.workspace = workspace }

    mutating func commit(_ updated: Workspace) {
        guard updated != workspace, updated.isValid(changedFrom: workspace) else { return }
        SolidCache.shared.keep(updated.bodies)
        past.append(workspace)
        trimPast()
        workspace = updated
        future.removeAll()
    }
    /// Replaces the model with the same model stored differently (carried solids as their exact
    /// shapes), without an undo step: undoing goes back to the step before, as it did.
    @discardableResult mutating func replaceStorage(_ updated: Workspace) -> Bool {
        guard updated != workspace, updated.isValid(changedFrom: workspace) else { return false }
        workspace = updated
        return true
    }
    /// Replaces the latest step in place (e.g. a keypad value for the move just made), so it stays one undo step.
    /// False, changing nothing, when there is no step to replace or the result is not a valid model.
    @discardableResult mutating func amend(_ updated: Workspace) -> Bool {
        guard canUndo, updated.isValid(changedFrom: workspace) else { return false }
        SolidCache.shared.keep(updated.bodies)
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
            trimPast()
        }
        workspace = updated
        future.removeAll()
        return true
    }

    @discardableResult mutating func deleteObjectNote(_ id: UUID) -> Bool {
        guard workspace.objectNotes.contains(where: { $0.id == id }) else { return false }
        past.append(workspace)
        trimPast()
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
