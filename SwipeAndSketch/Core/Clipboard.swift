import Foundation

/// Copy and paste of whole solids and sketches. A copy
/// keeps everything needed to recreate them, imported shapes included, so it pastes into the same
/// project or another one opened later in the same session. Paste puts the copies exactly where
/// the originals were, as new items; the Move/Rotate widget then takes them where they go.
struct ModelClipboard: Equatable, Sendable {
    struct SketchCopy: Equatable, Sendable {
        var sketch: Sketch
        var shapes: [SketchShape]
    }
    var bodies: [SolidBody] = []
    var sketches: [SketchCopy] = []
    var importedShapes: [ImportedShape] = []
    var isEmpty: Bool { bodies.isEmpty && sketches.isEmpty }
    /// "Body 01", or "3 items", for the Paste command.
    var title: String = ""

    /// Shared by every project open in this session (never saved).
    @MainActor static var shared = ModelClipboard()
}

extension Workspace {
    /// A copy of the solids and sketches, in document order.
    func copying(bodies bodyIDs: [UUID], sketches sketchIDs: [UUID]) -> ModelClipboard {
        var clipboard = ModelClipboard()
        clipboard.bodies = bodies.filter { bodyIDs.contains($0.id) }
        clipboard.sketches = sketches.filter { sketchIDs.contains($0.id) }.map { .init(sketch: $0, shapes: shapes(in: $0.id)) }
        let used = Set(clipboard.bodies.flatMap(\.importedShapeIDs))
        clipboard.importedShapes = importedShapes.filter { used.contains($0.id) }
        let count = clipboard.bodies.count + clipboard.sketches.count
        clipboard.title = count == 1 ? (clipboard.bodies.first.flatMap { bodyNames[$0.id] } ?? clipboard.sketches.first.flatMap { sketchNames[$0.sketch.id] } ?? "1 item") : "\(count) items"
        return clipboard
    }

    /// The clipboard's solids and sketches added as new items (after everything else), where they
    /// were copied from. Returns the new solids' and sketches' ids.
    func pasting(_ clipboard: ModelClipboard) -> (workspace: Workspace, bodies: [UUID], sketches: [UUID])? {
        guard !clipboard.isEmpty else { return nil }
        var result = self
        for shape in clipboard.importedShapes where !result.importedShapes.contains(where: { $0.id == shape.id }) {
            result.importedShapes.append(shape)
        }
        var bodies: [UUID] = [], sketches: [UUID] = []
        for body in clipboard.bodies {
            var copy = body
            copy.id = UUID()
            copy.hidden = nil
            result.bodies.append(copy)
            bodies.append(copy.id)
        }
        for item in clipboard.sketches {
            let id = UUID()
            result.sketches.append(Sketch(id: id, plane: item.sketch.plane, name: item.sketch.name, group: item.sketch.group))
            result.shapes += item.shapes.map { var shape = $0; shape.id = UUID(); shape.sketch = id; return shape }
            sketches.append(id)
        }
        // Pasted into the group it was copied from, when that group is here.
        result.dropMissingGroups()
        return result.isValid ? (result, bodies, sketches) : nil
    }
}
