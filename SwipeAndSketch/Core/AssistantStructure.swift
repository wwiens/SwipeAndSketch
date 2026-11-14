import Foundation

// What a change did to the names the assistant uses. Shapes, sketches, solids, and planes are
// numbered by position ("Rectangle 02" is the second rectangle in the model), so rounding a
// rectangle's corners retires it and renumbers the rectangles after it, and deleting Body 01
// makes the old Body 02 the new Body 01. Comparing items by identity before and after a step
// tells the model which names it can no longer use, which now mean something else, what was
// added to sketches it already knew, and which solids kept their identity but not their face and
// edge numbers. Serialized identifiers are untouched; this only describes them.

extension AssistantWorkbench {
    /// A compact note of retired, renumbered, renamed, and new references since `before`, or nil
    /// when the step only made new items its own reply already names.
    func structuralChanges(since before: Workspace) -> String? {
        let old = AssistantWorkbench(workspace: before)
        var lines: [String] = []

        // Retired: items gone by identity, named as they were.
        var retired: [String] = []
        for body in before.bodies where !workspace.bodies.contains(where: { $0.id == body.id }) { retired.append(old.bodyName(body.id)) }
        for sketch in before.sketches where workspace.sketch(sketch.id) == nil { retired.append(old.name(of: .sketch(sketch.id))) }
        for plane in before.constructionPlanes where !workspace.constructionPlanes.contains(where: { $0.id == plane.id }) {
            retired.append(old.name(of: .plane(plane.id)))
        }
        // A shape that became another kind (a rectangle whose corners were rounded is now one of
        // its sides) is retired under its old name and new under its new one.
        let kinds = Dictionary(uniqueKeysWithValues: workspace.shapes.map { ($0.id, $0.kind) })
        let gone = before.shapes.filter { kinds[$0.id] != $0.kind }
        for (sketch, shapes) in Self.bySketch(gone) {
            let scope = sketch.flatMap { id in workspace.sketch(id) == nil ? nil : name(of: .sketch(id)) }
            retired.append(Self.compact(shapes.map { old.name(of: .shape($0.id)) }) + (scope.map { " (in \($0))" } ?? ""))
        }
        if !retired.isEmpty {
            lines.append("Retired, no longer usable: \(Self.limited(retired)).")
        }

        // Names that now mean a different item, or an item that answers to a new name.
        var renamed: [String] = []
        func compare(_ id: UUID, _ was: String, _ now: String) { if was != now { renamed.append("\(was) → \(now)") } }
        for body in workspace.bodies where before.bodies.contains(where: { $0.id == body.id }) { compare(body.id, old.bodyName(body.id), bodyName(body.id)) }
        for sketch in workspace.sketches where before.sketch(sketch.id) != nil {
            compare(sketch.id, old.name(of: .sketch(sketch.id)), name(of: .sketch(sketch.id)))
        }
        for plane in workspace.constructionPlanes where before.constructionPlanes.contains(where: { $0.id == plane.id }) {
            compare(plane.id, old.name(of: .plane(plane.id)), name(of: .plane(plane.id)))
        }
        let previous = Dictionary(uniqueKeysWithValues: before.shapes.map { ($0.id, $0.kind) })
        for shape in workspace.shapes where previous[shape.id] == shape.kind {
            compare(shape.id, old.name(of: .shape(shape.id)), name(of: .shape(shape.id)))
        }
        if !renamed.isEmpty {
            lines.append("Now named (same item, new name; an old name may now mean another item): \(Self.limited(renamed)).")
        }

        // Shapes added to sketches that already existed, with the regions those sketches now have.
        let added = workspace.shapes.filter { previous[$0.id] != $0.kind && before.sketch($0.sketch) != nil }
        for (id, shapes) in Self.bySketch(added) {
            guard let id, let sketch = workspace.sketch(id) else { continue }
            let regions = regions(of: sketch)
            var line = "New in \(name(of: .sketch(id))): \(Self.compact(shapes.map { name(of: .shape($0.id)) }))."
            line += " Its regions now: " + (regions.isEmpty ? "none" : regions.prefix(6).enumerated()
                .map { "\($0.offset + 1) \(regionDescription($0.element))" }.joined(separator: "; ")) + (regions.count > 6 ? "; \(regions.count - 6) more" : "") + "."
            lines.append(line)
        }

        // Solids that kept their identity while their faces or edges changed: earlier numbers are stale.
        var topology: [String] = []
        for body in workspace.bodies {
            guard let was = before.bodies.first(where: { $0.id == body.id }), was != body,
                  let a = try? SolidKernel.solid(for: was), let b = try? SolidKernel.solid(for: body),
                  a.faceCount != b.faceCount || a.edgeCount != b.edgeCount else { continue }
            topology.append("\(bodyName(body.id)) (faces \(a.faceCount) → \(b.faceCount), edges \(a.edgeCount) → \(b.edgeCount))")
        }
        if !topology.isEmpty {
            lines.append("Same solid, new faces and edges: \(Self.limited(topology)). Face and edge numbers from before this step no longer apply; use sides or inspect again.")
        }
        guard !lines.isEmpty else { return nil }
        return "Structure after this step (by identity):\n" + lines.joined(separator: "\n")
    }

    /// Shapes grouped by sketch, in the order their sketches first appear.
    private static func bySketch(_ shapes: [SketchShape]) -> [(UUID?, [SketchShape])] {
        var order: [UUID?] = [], groups: [UUID?: [SketchShape]] = [:]
        for shape in shapes {
            if groups[shape.sketch] == nil { order.append(shape.sketch) }
            groups[shape.sketch, default: []].append(shape)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// "Line 09–12, Arc 09–12": consecutive numbered names of one kind run together.
    static func compact(_ names: [String]) -> String {
        var numbered: [(prefix: String, number: Int, width: Int)] = [], others: [String] = []
        for name in names {
            guard let space = name.lastIndex(of: " "), let number = Int(name[name.index(after: space)...]) else { others.append(name); continue }
            numbered.append((String(name[..<space]), number, name.distance(from: name.index(after: space), to: name.endIndex)))
        }
        // Kinds in the order they first appear, numbers ascending within each kind.
        let kinds = numbered.map(\.prefix).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        numbered.sort { (kinds.firstIndex(of: $0.prefix)!, $0.number) < (kinds.firstIndex(of: $1.prefix)!, $1.number) }
        var runs: [(prefix: String, first: Int, last: Int, width: Int)] = []
        for name in numbered {
            if let last = runs.last, last.prefix == name.prefix, last.last + 1 == name.number {
                runs[runs.count - 1].last = name.number
            } else {
                runs.append((name.prefix, name.number, name.number, name.width))
            }
        }
        func digits(_ n: Int, _ width: Int) -> String { String(format: "%0\(width)d", n) }
        return (runs.map { $0.first == $0.last ? "\($0.prefix) \(digits($0.first, $0.width))"
                                                : "\($0.prefix) \(digits($0.first, $0.width))–\(digits($0.last, $0.width))" } + others)
            .joined(separator: ", ")
    }

    private static func limited(_ items: [String], maximum: Int = 12) -> String {
        items.prefix(maximum).joined(separator: "; ") + (items.count > maximum ? "; and \(items.count - maximum) more" : "")
    }

    // MARK: Names as the model last saw them

    /// A name the model sends means what it meant in the last results it read. When an earlier call
    /// in the same round retired or renumbered it, the call is refused rather than sent to another
    /// item; a name retired earlier in the request says so instead of "the model has none".
    func checkedItem(named raw: String) throws -> AssistantItem {
        let now = Result { try resolvedItem(named: raw) }
        if let seen = namesLastSeen, seen != workspace,
           let meant = try? AssistantWorkbench(workspace: seen, selection: selection).resolvedItem(named: raw),
           (try? now.get()) != meant {
            let old = AssistantWorkbench(workspace: seen)
            let was = "\(raw) meant \(old.scopedName(of: meant)) when this call was sent"
            if survives(meant, from: seen) {
                let shifted = (try? now.get()).map { ", and \(raw) now means \(scopedName(of: $0))" } ?? ""
                throw Failure("\(was), but an earlier call in the same step renamed or renumbered it: it is now \(scopedName(of: meant))\(shifted). Nothing was changed; send this call again with \(name(of: meant)) if that is the item you meant.")
            }
            throw Failure("\(was), but an earlier call in the same step replaced or deleted it. Nothing was changed; use the names in that call's result.")
        }
        if case .failure = now, let start = namesAtRequest,
           let meant = try? AssistantWorkbench(workspace: start, selection: selection).resolvedItem(named: raw) {
            let was = AssistantWorkbench(workspace: start).scopedName(of: meant)
            guard survives(meant, from: start) else {
                throw Failure("\(raw) (\(was)) was replaced or deleted earlier in this request. Use the names from the latest results, or inspect the sketch or body to find them.")
            }
            throw Failure("\(raw) (\(was)) was renamed or renumbered earlier in this request: it is now \(scopedName(of: meant)).")
        }
        return try now.get()
    }

    /// Whether an item from `earlier` is still here as the same kind of thing (a rounded
    /// rectangle that is now one of its own sides has been replaced).
    private func survives(_ item: AssistantItem, from earlier: Workspace) -> Bool {
        switch item {
        case .body(let id): workspace.bodies.contains { $0.id == id }
        case .sketch(let id): workspace.sketch(id) != nil
        case .plane(let id): workspace.constructionPlanes.contains { $0.id == id }
        case .shape(let id):
            workspace.shapes.first { $0.id == id }?.kind == earlier.shapes.first { $0.id == id }?.kind
        }
    }

    /// "Rectangle 02 (in Sketch 02)" for a shape; other items by name.
    func scopedName(of item: AssistantItem) -> String {
        guard case .shape(let id) = item, let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch,
              workspace.sketch(sketch) != nil else { return name(of: item) }
        return "\(name(of: item)) (in \(name(of: .sketch(sketch))))"
    }
}
