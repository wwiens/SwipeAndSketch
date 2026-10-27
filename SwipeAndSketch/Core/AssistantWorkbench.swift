import Foundation
import SSKernel
import simd

// The AI assistant's model layer: describes the document in words a language model can work
// with, resolves the names it uses ("Body 01", "top face", "vertical edges"), and makes changes
// on a draft copy of the workspace. Every change is validated (the document stays valid and every
// solid still builds) before it is kept; a failed change leaves the draft as it was and explains
// why, so the model can correct itself. Nothing here talks to a model; see App/Assistant*.swift.

/// What the user had selected when the request started, so "the selected face" can be resolved.
enum AssistantSelection: Equatable, Sendable {
    /// An edge is its index on the solid as it is now.
    case body(UUID), face(bodyID: UUID, face: Int), edge(bodyID: UUID, edge: Int), sketch(UUID), shape(UUID), plane(UUID), profile(String)
    /// Several items picked together on the canvas: sketch regions and whole sketches on one plane,
    /// whole solids, or edges of one solid.
    case several([AssistantSelection])
}

/// A document item the assistant can name.
enum AssistantItem: Equatable, Sendable {
    case body(UUID), sketch(UUID), shape(UUID), plane(UUID)
}

struct AssistantWorkbench {
    struct Failure: LocalizedError, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// One input shape, in world millimeters: a point is projected onto the sketch plane.
    struct ShapeInput: Equatable, Sendable {
        enum Kind: String, Sendable { case rectangle, circle, line, slot, arc, ellipse, point, polygon, spline }
        var kind: Kind
        /// Rectangle, circle, and slot center, or line and arc start.
        var point: SIMD3<Double>
        /// Rectangle size along the plane's u and v axes; a slot fits the same box, its round ends
        /// on the shorter sides.
        var width: Double?
        var height: Double?
        var diameter: Double?
        /// Line and arc end.
        var end: SIMD3<Double>?
        /// A point the arc passes through between its ends.
        var through: SIMD3<Double>? = nil
        /// Polygon: how many sides (its diameter is across its corners).
        var sides: Int? = nil
        /// Construction geometry: a reference that bounds no region.
        var construction: Bool? = nil
        /// Spline: the points it passes through after `point` (the last is its end, unless closed).
        var points: [SIMD3<Double>]? = nil
        var closed: Bool? = nil
    }

    /// Where new sketch shapes go.
    enum PlaneTarget: Equatable, Sendable {
        case world(SketchPlane), construction(UUID), face(body: UUID, face: String), sketch(UUID)
    }

    enum ExtrudeMode: String, Sendable { case auto, newBody = "new body", join, cut }

    private(set) var workspace: Workspace
    var selection: AssistantSelection?
    /// One line per change, in order, for the review card.
    private(set) var changes: [String] = []
    /// The solid or sketch most recently made or changed, to select after the changes are kept.
    private(set) var focus: AssistantItem?

    init(workspace: Workspace, selection: AssistantSelection? = nil) {
        self.workspace = workspace
        self.selection = selection
    }

    var hasChanges: Bool { !changes.isEmpty }

    // MARK: Names

    private static func number(_ index: Int) -> String { String(format: "%02d", index + 1) }

    func name(of item: AssistantItem) -> String {
        switch item {
        case .body(let id): return bodyName(id)
        case .sketch(let id): return workspace.sketchNames[id] ?? "a deleted sketch"
        case .plane(let id): return workspace.planeNames[id] ?? "a deleted plane"
        case .shape(let id):
            guard let shape = workspace.shapes.first(where: { $0.id == id }) else { return "a deleted shape" }
            let index = workspace.shapes.filter { $0.kind == shape.kind }.firstIndex { $0.id == id } ?? 0
            return "\(shape.kind.title) \(Self.number(index))"
        }
    }

    /// "Body 01", or the file name an imported solid came from (as the Items list shows it).
    func bodyName(_ id: UUID) -> String { workspace.bodyNames[id] ?? "a deleted body" }

    /// Resolves "Body 01", "body 1", "Sketch 2", "Rectangle 03", "Plane 1", an imported solid's
    /// file name, or "selected"/"selection" for the user's selection.
    func item(named raw: String) throws -> AssistantItem {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["selected", "selection", "the selection", "selected item", "it", "this"].contains(text) {
            switch selection {
            case .body(let id), .face(let id, _), .edge(let id, _): return .body(id)
            case .sketch(let id): return .sketch(id)
            case .shape(let id): return .shape(id)
            case .plane(let id): return .plane(id)
            case .profile(let id):
                if let source = workspace.profiles.first(where: { $0.id == id })?.sourceIDs.first,
                   let sketch = workspace.shapes.first(where: { $0.id == source })?.sketch { return .sketch(sketch) }
                throw Failure("Nothing usable is selected.")
            case .several(let items):
                if !pickedBodies.isEmpty {
                    throw Failure("\(pickedBodies.count) solids are selected. Name one, or use \"selected\" in a list of items (move, delete, hide, scale, mirror, pattern, group, combine, color) to take them all.")
                }
                if !pickedEdges.isEmpty { return .body(pickedEdges[0].body) }
                // Items of one sketch stand for it; otherwise only extrude and revolve take them all.
                let sketches = Set(items.compactMap { sketchID(of: $0) })
                if sketches.count == 1, let id = sketches.first { return .sketch(id) }
                throw Failure("\(items.count) sketch items are selected. Name one, or use sketch \"selected\" with extrude or revolve to take them all.")
            case nil: throw Failure("Nothing is selected.")
            }
        }
        for (id, name) in workspace.bodyNames where workspace.bodies.contains(where: { $0.id == id && ($0.isImported || $0.name != nil) }) {
            if name.lowercased() == text || (name as NSString).deletingPathExtension.lowercased() == text { return .body(id) }
        }
        // Chosen names of sketches and planes.
        for (id, name) in workspace.sketchNames where workspace.sketch(id)?.name != nil && name.lowercased() == text { return .sketch(id) }
        for (id, name) in workspace.planeNames where workspace.constructionPlanes.contains(where: { $0.id == id && $0.name != nil }) && name.lowercased() == text {
            return .plane(id)
        }
        let compact = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "#", with: "")
        let letters = compact.prefix { $0.isLetter }
        let digits = compact.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits), number >= 1 else {
            throw Failure("Unknown item \"\(raw)\". Use names from the model summary, such as Body 01, Sketch 02, Rectangle 01, or Plane 01.")
        }
        let index = number - 1
        func pick<T>(_ list: [T], _ make: (T) -> AssistantItem) throws -> AssistantItem {
            guard list.indices.contains(index) else {
                throw Failure(list.isEmpty ? "There is no \(raw): the model has none yet. To start a new solid, sketch on top, front, or right."
                                           : "There is no \(raw); the model has \(list.count).")
            }
            return make(list[index])
        }
        switch String(letters) {
        case "body", "solid", "b": return try pick(workspace.bodies) { .body($0.id) }
        case "sketch", "s": return try pick(workspace.sketches) { .sketch($0.id) }
        case "plane", "constructionplane", "p": return try pick(workspace.constructionPlanes) { .plane($0.id) }
        default:
            guard let kind = ShapeKind.allCases.first(where: { $0.rawValue == letters || $0.rawValue + "s" == letters }) else {
                throw Failure("Unknown item \"\(raw)\". Use names from the model summary.")
            }
            return try pick(workspace.shapes.filter { $0.kind == kind }) { .shape($0.id) }
        }
    }

    func body(named name: String) throws -> SolidBody {
        guard case .body(let id) = try item(named: name), let body = workspace.bodies.first(where: { $0.id == id }) else {
            throw Failure("\(name) is not a solid body.")
        }
        return body
    }

    func sketch(named name: String) throws -> Sketch {
        switch try item(named: name) {
        case .sketch(let id): if let sketch = workspace.sketch(id) { return sketch }
        case .shape(let id): if let sketch = workspace.sketch(workspace.shapes.first { $0.id == id }?.sketch) { return sketch }
        default: break
        }
        throw Failure("\(name) is not a sketch.")
    }

    // MARK: Describing

    static func mm(_ value: Double) -> String {
        var rounded = (value * 100).rounded() / 100
        if rounded == 0 { rounded = 0 }   // no "-0"
        return rounded.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
    static func point(_ p: SIMD3<Double>) -> String { "(\(mm(p.x)), \(mm(p.y)), \(mm(p.z)))" }

    /// "+Z (up)" for a direction near a world axis, else its components.
    static func direction(_ v: SIMD3<Double>) -> String {
        guard simd_length(v) > 1e-12 else { return "none" }
        let n = simd_normalize(v)
        let axes: [(String, SIMD3<Double>)] = [("+X", [1, 0, 0]), ("-X", [-1, 0, 0]), ("+Y", [0, 1, 0]), ("-Y", [0, -1, 0]), ("+Z", [0, 0, 1]), ("-Z", [0, 0, -1])]
        if let best = axes.max(by: { simd_dot($0.1, n) < simd_dot($1.1, n) }), simd_dot(best.1, n) > 0.9995 { return best.0 }
        return "(\(String(format: "%.2f", n.x)), \(String(format: "%.2f", n.y)), \(String(format: "%.2f", n.z)))"
    }

    /// The side of the model an outward face normal points to.
    static func side(_ normal: SIMD3<Double>) -> String? {
        switch direction(normal) {
        case "+Z": "top"; case "-Z": "bottom"; case "-Y": "front"; case "+Y": "back"; case "+X": "right"; case "-X": "left"
        default: nil
        }
    }

    static let sideDirections: [String: SIMD3<Double>] = [
        "top": [0, 0, 1], "bottom": [0, 0, -1], "front": [0, -1, 0], "back": [0, 1, 0], "right": [1, 0, 0], "left": [-1, 0, 0],
        "+z": [0, 0, 1], "-z": [0, 0, -1], "-y": [0, -1, 0], "+y": [0, 1, 0], "+x": [1, 0, 0], "-x": [-1, 0, 0],
    ]

    func planeDescription(_ plane: SketchPlane) -> String {
        if let name = plane.worldName { return name.capitalized }
        if let construction = workspace.constructionPlanes.first(where: { $0.plane == plane }) { return name(of: .plane(construction.id)) }
        let n = plane.normalAxis
        return "a plane facing \(Self.direction(n)) through \(Self.point(n * simd_dot(plane.origin, n)))"
    }

    func shapeDescription(_ shape: SketchShape) -> String {
        let plane = shape.plane
        switch shape.kind {
        case .rectangle:
            return "\(Self.mm(abs(shape.end.x - shape.start.x))) × \(Self.mm(abs(shape.end.y - shape.start.y))) centered at \(Self.point(plane.point(shape.center)))"
        case .circle:
            return "Ø\(Self.mm(shape.start.distance(to: shape.end) * 2)) centered at \(Self.point(plane.point(shape.start)))"
        case .line:
            return "from \(Self.point(plane.point(shape.start))) to \(Self.point(plane.point(shape.end))), \(Self.mm(shape.start.distance(to: shape.end))) long"
        case .arc:
            let radius = shape.arcCenter.map { shape.start.distance(to: $0) } ?? 0
            return "radius \(Self.mm(radius)), \(Self.mm(shape.arcSweep * 180 / .pi))°"
        case .curve:
            return "\(shape.isSpline ? "spline through " : "")\(shape.points?.count ?? 0) points\(shape.isClosed ? ", closed" : "")"
        case .slot:
            return "slot \(Self.mm(shape.start.distance(to: shape.end))) between centers × \(Self.mm(shape.width ?? 0)) wide, from \(Self.point(plane.point(shape.start))) to \(Self.point(plane.point(shape.end)))"
        case .ellipse:
            return "ellipse \(Self.mm(2 * shape.start.distance(to: shape.end))) × \(Self.mm(shape.width ?? 0)) centered at \(Self.point(plane.point(shape.start)))"
        case .point:
            return "point at \(Self.point(plane.point(shape.start)))"
        }
    }

    func regionDescription(_ profile: SketchProfile) -> String {
        let plane = profile.plane
        if let circle = profile.circle {
            return "circle Ø\(Self.mm(circle.radius * 2)) at \(Self.point(plane.point(circle.center)))"
        }
        let xs = profile.outline.map(\.x), ys = profile.outline.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
        let isBox = profile.outline.count == 4 && abs(profile.area - w * h) < 1e-6 * max(1, w * h)
        return "\(isBox ? "rectangle" : "\(profile.outline.count)-sided area") \(Self.mm(w)) × \(Self.mm(h)) at \(Self.point(plane.point(profile.center))), \(Self.mm(profile.area)) mm²"
    }

    /// "rectangle 60 × 40" or "circle Ø12", for change lines.
    func shortRegion(_ profile: SketchProfile) -> String {
        if let circle = profile.circle { return "Ø\(Self.mm(circle.radius * 2)) circle" }
        let xs = profile.outline.map(\.x), ys = profile.outline.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
        let isBox = profile.outline.count == 4 && abs(profile.area - w * h) < 1e-6 * max(1, w * h)
        return "\(Self.mm(w)) × \(Self.mm(h)) \(isBox ? "rectangle" : "shape")"
    }

    /// The closed regions of a sketch, in the order the tools number them (1 = first).
    func regions(of sketch: Sketch) -> [SketchProfile] { workspace.profiles(in: sketch).filter(\.isSolidProfile) }

    func bodyDescription(_ body: SolidBody) -> String {
        var parts: [String] = []
        if let imported = body.imported, let shape = workspace.importedShapes.first(where: { $0.id == imported.shape }) {
            parts.append("imported from \(shape.displayName)")
        } else {
            let source = workspace.shapes.first { body.profile.sourceIDs.contains($0.id) }?.sketch.flatMap { id in
                workspace.sketchNames[id]
            }
            let from = source.map { "\($0) (\(regionDescription(body.profile)))" } ?? regionDescription(body.profile)
            if let revolve = body.revolve {
                parts.append("revolved \(Self.mm(revolve.angle))° from \(from)")
            } else {
                parts.append("extruded \(Self.mm(body.depth)) mm along \(Self.direction(body.profile.plane.normalAxis)) from \(from)")
            }
        }
        if let solid = try? SolidKernel.solid(for: body) {
            let b = solid.bounds, size = b.max - b.min
            parts.append("\(Self.mm(size.x)) wide (x) × \(Self.mm(size.y)) deep (y) × \(Self.mm(size.z)) tall (z)")
            parts.append("spans x \(Self.mm(b.min.x))…\(Self.mm(b.max.x)), y \(Self.mm(b.min.y))…\(Self.mm(b.max.y)), z \(Self.mm(b.min.z))…\(Self.mm(b.max.z))")
            parts.append("volume \(Self.mm(solid.volume)) mm³")
        } else {
            parts.append("does not build")
        }
        for finish in body.finishes {
            parts.append("\(finish.kind.rawValue) \(Self.mm(finish.size)) mm on \(finish.edges.count) edge\(finish.edges.count == 1 ? "" : "s")")
        }
        var counts: [String: Int] = [:]
        for cut in body.cuts {
            let label: String
            switch cut.operation {
            case .cut: label = cut.facePoint != nil ? "face push-in" : cut.throughAll ? "through-all cut" : "cut"
            case .join: label = cut.facePoint != nil ? "face extrusion" : "joined boss"
            case .merge: label = "united solid"
            case .shell: label = "shell \(Self.mm(cut.shell?.thickness ?? 0)) mm"
            case .hole: label = "\(cut.hole?.kind.title.lowercased() ?? "") \(cut.hole?.size ?? "") hole"
            case .split: label = cut.split?.keep == .piece ? "one piece of a solid a cut divided" : "split"
            case .subtract: label = cut.clearance.map { "subtracted solid with \(Self.mm($0)) mm clearance" } ?? "subtracted solid"
            case .intersect: label = "intersected with a solid (only the overlap kept)"
            case .deleteFace: label = "\(cut.removedFaces?.points.count ?? 1) face(s) deleted"
            case .offsetFace: label = "\(cut.movedFaces?.points.count ?? 1) face(s) moved \(Self.mm(cut.movedFaces?.distance ?? 0)) mm"
            case .draft: label = "\(cut.draft?.points.count ?? 1) face(s) drafted \(Self.mm(cut.draft?.angle ?? 0))°"
            case .rib: label = "rib \(Self.mm(cut.rib?.thickness ?? 0)) mm thick"
            case .scale:
                let f = cut.scale?.factors ?? .one
                label = cut.scale?.isUniform == true ? "scaled \(Self.mm(f.x * 100))%" : "stretched \(Self.mm(f.x * 100)) × \(Self.mm(f.y * 100)) × \(Self.mm(f.z * 100))%"
            case .finish: label = "\(cut.finish?.kind.rawValue ?? "fillet") \(Self.mm(cut.finish?.size ?? 0)) mm on \(cut.finish?.edges.count ?? 0) edges"
            case .text: label = "\(cut.depth > 0 ? "embossed" : "debossed") text \"\(cut.text?.text ?? "")\""
            case .thread: label = "\(cut.thread?.isInternal == true ? "internal" : "external")\(cut.thread?.isRaised == true ? " raised" : "") thread \(cut.thread?.title ?? "")"
            }
            counts[label, default: 0] += 1
        }
        for (label, count) in counts.sorted(by: { $0.key < $1.key }) { parts.append(count == 1 ? label : "\(count) × \(label)") }
        if body.symmetric == true { parts.append("extruded both ways from its sketch") }
        if let taper = body.taper { parts.append("sides tapered \(Self.mm(taper))°") }
        if let color = body.color { parts.append("color \(color.rawValue)") }
        if body.isHidden { parts.append("hidden") } else if workspace.isGroupHidden(body.group) { parts.append("hidden by its group") }
        return parts.joined(separator: "; ")
    }

    func selectionDescription() -> String {
        switch selection {
        case nil: return "nothing"
        case .body(let id): return bodyName(id)
        case .face(let id, let face):
            guard let body = workspace.bodies.first(where: { $0.id == id }), let solid = try? SolidKernel.solid(for: body) else { return bodyName(id) }
            return "\(bodyName(id)) face \(face) (\(faceDescription(face, of: solid)))"
        case .edge(let id, let index):
            guard let body = workspace.bodies.first(where: { $0.id == id }), let solid = try? SolidKernel.solid(for: body),
                  index < solid.edgeCount else { return "an edge of \(bodyName(id))" }
            return "\(bodyName(id)) edge \(index) (\(edgeDescription(index, of: solid)))"
        case .sketch(let id): return name(of: .sketch(id))
        case .shape(let id): return name(of: .shape(id))
        case .plane(let id): return name(of: .plane(id))
        case .profile(let id):
            guard let profile = workspace.profiles.first(where: { $0.id == id }) else { return "a sketch region" }
            return "a sketch region (\(regionDescription(profile)))"
        case .several(let items):
            let names = items.map { item -> String in
                var single = self
                single.selection = item
                return single.selectionDescription()
            }
            let kind = !pickedBodies.isEmpty ? "solids" : !pickedEdges.isEmpty ? "edges of one solid" : "sketch items on one plane"
            return "\(items.count) \(kind): \(names.joined(separator: "; "))"
        }
    }

    /// The sketch a selected sketch item belongs to.
    private func sketchID(of item: AssistantSelection) -> UUID? {
        switch item {
        case .sketch(let id): return id
        case .shape(let id): return workspace.shapes.first { $0.id == id }?.sketch
        case .profile(let id):
            return workspace.profiles.first { $0.id == id }?.sourceIDs.first.flatMap { source in workspace.shapes.first { $0.id == source }?.sketch }
        default: return nil
        }
    }

    /// The regions the selection stands for when it is sketch items: a region, a closed shape's
    /// region, every region of a whole sketch, or all of them for several. Empty for anything else.
    func selectedRegions() -> [SketchProfile] {
        func itemRegions(_ item: AssistantSelection?) -> [SketchProfile] {
            switch item {
            case .sketch(let id): return workspace.sketch(id).map(regions(of:)) ?? []
            case .profile(let id): return workspace.profiles.first { $0.id == id }.map { [$0] } ?? []
            case .shape(let id):
                guard let shape = workspace.shapes.first(where: { $0.id == id }), let sketch = workspace.sketch(shape.sketch) else { return [] }
                let all = regions(of: sketch)
                return all.first { $0.id == id.uuidString }.map { [$0] } ?? Array(all.filter { $0.sourceIDs.contains(id) }.prefix(1))
            case .several(let items): return items.flatMap(itemRegions)
            default: return []
            }
        }
        var seen = Set<String>()
        return itemRegions(selection).filter { seen.insert($0.id).inserted }
    }

    private static func isSelectionWord(_ text: String) -> Bool {
        ["selected", "selection", "the selection", "selected item", "selected items", "it", "this", "these", "them"]
            .contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The solids picked together on the canvas, in the order picked (empty unless several solids are).
    var pickedBodies: [UUID] {
        guard case .several(let items) = selection else { return [] }
        let bodies = items.compactMap { item -> UUID? in if case .body(let id) = item { id } else { nil } }
        return bodies.count == items.count ? bodies : []
    }

    /// The edges picked together on one solid (empty unless several edges are).
    var pickedEdges: [(body: UUID, edge: Int)] {
        guard case .several(let items) = selection else { return [] }
        let edges = items.compactMap { item -> (body: UUID, edge: Int)? in if case .edge(let body, let edge) = item { (body, edge) } else { nil } }
        return edges.count == items.count && Set(edges.map(\.body)).count == 1 ? edges : []
    }

    /// A list of names with "selected" standing for every solid picked together, when several are.
    private func expandingSelection(_ names: [String]) -> [String] {
        let picked = pickedBodies.map(bodyName)
        guard !picked.isEmpty else { return names }
        var result: [String] = []
        for name in names {
            for item in Self.isSelectionWord(name) ? picked : [name] where !result.contains(item) { result.append(item) }
        }
        return result
    }

    /// A compact description of the whole document, sent with each request.
    func summary(maximumLines: Int = 120) -> String {
        var lines = ["Units mm; Z is up. Top plane = XY (normal +Z), Front = XZ (normal -Y), Right = YZ (normal +X)."]
        if workspace.bodies.isEmpty && workspace.sketches.isEmpty && workspace.constructionPlanes.isEmpty {
            lines.append("The model is empty: no bodies, sketches, or planes yet. New solids start on the top, front, or right plane.")
        }
        for body in workspace.bodies { lines.append("\(bodyName(body.id)): \(bodyDescription(body))") }
        for plane in workspace.constructionPlanes {
            let n = plane.plane.normalAxis
            lines.append("\(name(of: .plane(plane.id))): construction plane facing \(Self.direction(n)) through \(Self.point(plane.plane.origin))\(workspace.isHidden(plane) ? "; hidden" : "")")
        }
        for sketch in workspace.sketches {
            let name = name(of: .sketch(sketch.id))
            var line = "\(name) on \(planeDescription(sketch.plane))\(workspace.isHidden(sketch) ? " (hidden)" : ""):"
            line += workspace.shapes(in: sketch.id).map { " \(self.name(of: .shape($0.id))) \(shapeDescription($0))\($0.isConstruction ? " (construction)" : "")" }.joined(separator: ";")
            let regions = regions(of: sketch)
            if !regions.isEmpty {
                line += ". Regions: " + regions.enumerated().map { "\($0.offset + 1) \(regionDescription($0.element))" }.joined(separator: "; ")
            }
            lines.append(line)
        }
        for group in workspace.groups { lines.append(groupDescription(group)) }
        lines.append("Selected: \(selectionDescription()).")
        if lines.count > maximumLines {
            let kept = Array(lines.prefix(maximumLines - 2)) + ["… \(lines.count - maximumLines + 1) more items; ask for one by name.", lines.last!]
            return kept.joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Faces and edges

    func faceDescription(_ face: Int, of solid: KernelSolid) -> String {
        guard let plane = solid.facePlane(face) else {
            return "curved" + (solid.faceCenter(face).map { ", center \(Self.point($0))" } ?? "")
        }
        var text = "flat, faces \(Self.direction(plane.normal))"
        if let side = Self.side(plane.normal) { text += " (\(side))" }
        if let center = solid.faceCenter(face) { text += ", center \(Self.point(center))" }
        if let frame = SketchPlane.through(plane.origin, normal: plane.normal), let outline = solid.faceOutline(face) {
            let points = outline.points.map(frame.coordinates)
            let w = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0), h = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
            text += ", \(Self.mm(w)) × \(Self.mm(h)) along u \(Self.direction(frame.xAxis)) × v \(Self.direction(frame.yAxis))"
        }
        return text
    }

    func edgeDescription(_ edge: Int, of solid: KernelSolid) -> String {
        if let circle = solid.edgeCircle(edge) {
            let samples = solid.edgeSamples(edge, count: 9)
            let closed = samples.count > 1 && simd_distance(samples.first!, samples.last!) < 1e-6
            return "\(closed ? "circle" : "arc") radius \(Self.mm(circle.radius)) around \(Self.point(circle.center))"
        }
        let samples = solid.edgeSamples(edge, count: 9)
        guard let a = samples.first, let b = samples.last else { return "edge" }
        let length = zip(samples, samples.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        let straight = abs(length - simd_distance(a, b)) < 1e-6 * max(1, length)
        if straight { return "straight \(Self.mm(length)) along \(Self.direction(b - a)) from \(Self.point(a)) to \(Self.point(b))" }
        return "curve \(Self.mm(length)) long from \(Self.point(a)) to \(Self.point(b))"
    }

    /// Faces and edges of a solid, numbered as the face and edge arguments take them.
    func inspect(_ body: SolidBody, maximumFaces: Int = 60, maximumEdges: Int = 120) throws -> String {
        let solid = try buildable(body)
        var lines = ["\(bodyName(body.id)): \(bodyDescription(body))", "Faces (\(solid.faceCount)):"]
        for face in 0..<min(solid.faceCount, maximumFaces) { lines.append("face \(face): \(faceDescription(face, of: solid))") }
        if solid.faceCount > maximumFaces { lines.append("… \(solid.faceCount - maximumFaces) more faces; name faces by side (top, bottom, front, back, left, right).") }
        lines.append("Edges (\(solid.edgeCount)):")
        for edge in 0..<min(solid.edgeCount, maximumEdges) { lines.append("edge \(edge): \(edgeDescription(edge, of: solid))") }
        if solid.edgeCount > maximumEdges { lines.append("… \(solid.edgeCount - maximumEdges) more edges; use edge rules such as top, vertical, or circular.") }
        return lines.joined(separator: "\n")
    }

    private func buildable(_ body: SolidBody) throws -> KernelSolid {
        do { return try SolidKernel.solid(for: body) } catch { throw Failure("\(bodyName(body.id)) does not build.") }
    }

    /// A face by side ("top", "-x"), by number ("face 7", "7"), or "selected".
    func face(_ spec: String, of body: SolidBody) throws -> Int {
        let solid = try buildable(body)
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " face", with: "").replacingOccurrences(of: "face ", with: "").replacingOccurrences(of: "the ", with: "")
        if ["selected", "selection", "it", "this"].contains(text) {
            guard case .face(let id, let face) = selection, id == body.id else { throw Failure("No face of \(bodyName(body.id)) is selected.") }
            return face
        }
        if let index = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "f#"))) {
            guard (0..<solid.faceCount).contains(index) else { throw Failure("\(bodyName(body.id)) has faces 0…\(solid.faceCount - 1).") }
            return index
        }
        guard let direction = Self.sideDirections[text] else {
            throw Failure("Unknown face \"\(spec)\". Use top, bottom, front, back, left, right, a face number from inspect_item, or selected.")
        }
        // The flat face pointing that way that lies farthest out; the largest wins a tie.
        var best: (face: Int, reach: Double, area: Double)?
        for face in 0..<solid.faceCount {
            guard let plane = solid.facePlane(face), simd_dot(simd_normalize(plane.normal), direction) > 0.999,
                  let center = solid.faceCenter(face) else { continue }
            let reach = simd_dot(center, direction)
            let area = faceArea(face, of: solid)
            if best == nil || reach > best!.reach + 1e-6 || (abs(reach - best!.reach) <= 1e-6 && area > best!.area) { best = (face, reach, area) }
        }
        guard let best else { throw Failure("\(bodyName(body.id)) has no flat face facing \(text).") }
        return best.face
    }

    private func faceArea(_ face: Int, of solid: KernelSolid) -> Double {
        guard let plane = solid.facePlane(face), let frame = SketchPlane.through(plane.origin, normal: plane.normal),
              let outline = solid.faceOutline(face) else { return 0 }
        return abs(Geometry.signedArea(outline.points.map(frame.coordinates)))
    }

    /// Edges by rule: all, top, bottom, front, back, left, right (the edges around that side's
    /// face), vertical, horizontal, circular, straight, "face 3" (around a face), "edge 5" or "5",
    /// selected. Several rules may be combined with commas.
    func edges(_ spec: String, of body: SolidBody) throws -> [Int] {
        let solid = try buildable(body)
        var result: [Int] = []
        func add(_ edges: [Int]) { for edge in edges where !result.contains(edge) { result.append(edge) } }
        let all = Array(0..<solid.edgeCount)
        func direction(_ edge: Int) -> SIMD3<Double>? {
            let samples = solid.edgeSamples(edge, count: 5)
            guard solid.edgeCircle(edge) == nil, let a = samples.first, let b = samples.last, simd_distance(a, b) > 1e-9 else { return nil }
            let length = zip(samples, samples.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
            return abs(length - simd_distance(a, b)) < 1e-6 * max(1, length) ? simd_normalize(b - a) : nil
        }
        for raw in spec.lowercased().split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let rule = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " edges", with: "").replacingOccurrences(of: "the ", with: "")
            switch rule {
            case "all", "every", "everything": add(all)
            case "vertical": add(all.filter { direction($0).map { abs($0.z) > 0.999 } ?? false })
            case "horizontal": add(all.filter { direction($0).map { abs($0.z) < 0.001 } ?? false })
            case "circular", "round", "circles", "arcs": add(all.filter { solid.edgeCircle($0) != nil })
            case "straight": add(all.filter { direction($0) != nil })
            case "selected", "selection", "it", "this":
                // One selected edge, or several picked on this solid.
                let picked = pickedEdges.filter { $0.body == body.id }.map(\.edge)
                if !picked.isEmpty, picked.allSatisfy(all.contains) { add(picked); break }
                guard case .edge(let id, let index) = selection, id == body.id, all.contains(index) else {
                    throw Failure("No edge of \(bodyName(body.id)) is selected.")
                }
                add([index])
            default:
                if let index = Int(rule.replacingOccurrences(of: "edge", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " e#"))) {
                    guard all.contains(index) else { throw Failure("\(bodyName(body.id)) has edges 0…\(solid.edgeCount - 1).") }
                    add([index])
                } else {
                    let faceSpec = rule.hasPrefix("face") ? String(rule.dropFirst(4)) : rule
                    do { add(solid.faceEdges(try face(faceSpec, of: body))) } catch {
                        throw Failure("Unknown edge rule \"\(rule)\". Use all, top, bottom, front, back, left, right, vertical, horizontal, circular, straight, face N, edge N, or selected.")
                    }
                }
            }
        }
        guard !result.isEmpty else { throw Failure("No edges of \(bodyName(body.id)) match \"\(spec)\".") }
        return result
    }

    // MARK: Changing the model

    /// Keeps `next` if it is valid and every solid in `bodies` builds; records `change`.
    private mutating func keep(_ next: Workspace, change: String, checking bodies: [UUID] = [], focus: AssistantItem? = nil) throws {
        var next = next
        next.normalizeSketches()
        next.pruneImportedShapes()
        // A solid a removal left in separate pieces becomes one solid per piece.
        let separated = next.separatingPieces(since: workspace)
        next = separated.workspace
        // A change that changes nothing (a height it already has) is not listed.
        guard next != workspace else { return }
        guard next.isValid else { throw Failure("That change would make the model invalid (sizes must be 0.01–10000 mm and coordinates within ±100000 mm).") }
        for id in bodies {
            guard let body = next.bodies.first(where: { $0.id == id }) else { continue }
            guard (try? SolidKernel.solid(for: body)) != nil else {
                throw Failure("The kernel could not build that result for \(bodyName(id)); try other values.")
            }
        }
        workspace = next
        changes.append(change)
        for (id, pieces) in separated.added.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            changes.append("\(bodyName(id)) came apart into \(pieces.count + 1) separate solids: " +
                           ([id] + pieces).map(bodyName).joined(separator: ", "))
        }
        if let focus { self.focus = focus }
    }

    private func sketchPlane(for target: PlaneTarget) throws -> (plane: SketchPlane, sketch: UUID?, label: String) {
        switch target {
        case .world(let plane): return (plane, nil, plane.title)
        case .construction(let id):
            guard let plane = workspace.constructionPlanes.first(where: { $0.id == id }) else { throw Failure("That plane no longer exists.") }
            return (plane.plane, nil, name(of: .plane(id)))
        case .sketch(let id):
            guard let sketch = workspace.sketch(id) else { throw Failure("That sketch no longer exists.") }
            return (sketch.plane, id, name(of: .sketch(id)))
        case .face(let bodyID, let spec):
            guard let body = workspace.bodies.first(where: { $0.id == bodyID }) else { throw Failure("That body no longer exists.") }
            let index = try face(spec, of: body), solid = try buildable(body)
            guard let facePlane = solid.facePlane(index), let plane = SketchPlane.through(facePlane.origin, normal: facePlane.normal) else {
                throw Failure("Face \(index) of \(bodyName(bodyID)) is curved; sketches need a flat face.")
            }
            return (plane, nil, "\(bodyName(bodyID)) face \(index)")
        }
    }

    /// Adds rectangles, circles, and lines to a new sketch on `target` (or to an existing sketch).
    @discardableResult mutating func addShapes(_ inputs: [ShapeInput], on target: PlaneTarget) throws -> String {
        guard !inputs.isEmpty else { throw Failure("Give at least one shape.") }
        guard inputs.count <= 50 else { throw Failure("Add at most 50 shapes at a time.") }
        let (plane, existing, label) = try sketchPlane(for: target)
        var next = workspace
        let sketchID = existing ?? UUID()
        if existing == nil { next.sketches.append(Sketch(id: sketchID, plane: plane)) }
        var added: [UUID] = []
        for input in inputs {
            let p = plane.coordinates(of: input.point)
            var shape: SketchShape
            switch input.kind {
            case .rectangle:
                // One size given makes a square.
                guard let w = input.width ?? input.height ?? input.diameter, let h = input.height ?? input.width ?? input.diameter,
                      w >= 0.01, h >= 0.01 else { throw Failure("A rectangle needs width and height of at least 0.01 mm.") }
                shape = SketchShape(kind: .rectangle, plane: plane, start: p - Point2(x: w / 2, y: h / 2), end: p + Point2(x: w / 2, y: h / 2))
                shape.centered = true
            case .circle:
                // Models often give a circle's size as its width.
                guard let d = input.diameter ?? input.width ?? input.height, d >= 0.02 else { throw Failure("A circle needs a diameter of at least 0.02 mm; pass diameter.") }
                shape = SketchShape(kind: .circle, plane: plane, start: p, end: p + Point2(x: d / 2, y: 0))
            case .line:
                guard let end = input.end else { throw Failure("A line needs an end point.") }
                shape = SketchShape(kind: .line, plane: plane, start: p, end: plane.coordinates(of: end))
            case .slot:
                // The stadium inside a width × height box: its centers along the longer side.
                guard let w = input.width, let h = input.height ?? input.diameter, w >= 0.02, h >= 0.02, w != h else {
                    throw Failure("A slot needs a width and a height (its overall size), and they must differ.")
                }
                let along = w > h ? Point2(x: (w - h) / 2, y: 0) : Point2(x: 0, y: (h - w) / 2)
                shape = SketchShape.slot(from: p - along, to: p + along, width: min(w, h), plane: plane)
            case .arc:
                guard let end = input.end, let through = input.through,
                      let arc = SketchShape.arc(from: p, through: plane.coordinates(of: through), to: plane.coordinates(of: end), plane: plane) else {
                    throw Failure("An arc needs a start, an end, and a point it passes through, not all in a line.")
                }
                shape = arc
            case .ellipse:
                // Width along the plane's u axis, height along v.
                guard let w = input.width ?? input.diameter, let h = input.height ?? input.diameter, w >= 0.02, h >= 0.02 else {
                    throw Failure("An ellipse needs a width and a height of at least 0.02 mm.")
                }
                shape = SketchShape(kind: .ellipse, plane: plane, start: p, end: p + Point2(x: w / 2, y: 0), width: h)
            case .point:
                shape = SketchShape(kind: .point, plane: plane, start: p, end: p)
            case .spline:
                let through = [p] + (input.points ?? []).map(plane.coordinates(of:))
                guard let spline = SketchShape.spline(through: through, closed: input.closed == true, plane: plane) else {
                    throw Failure("A spline needs at least two points (three when closed), not all the same.")
                }
                shape = spline
            case .polygon:
                guard let d = input.diameter ?? input.width, d >= 0.02 else { throw Failure("A polygon needs a diameter (across its corners).") }
                let sides = input.sides ?? 6
                let lines = SketchTools.polygon(center: p, vertex: p + Point2(x: d / 2, y: 0), sides: sides, plane: plane)
                guard !lines.isEmpty else { throw Failure("A polygon has 3 to 64 sides.") }
                for var line in lines {
                    line.sketch = sketchID
                    line.construction = input.construction == true ? true : nil
                    next.shapes.append(line)
                    added.append(line.id)
                }
                continue
            }
            if input.construction == true { shape.construction = true }
            guard shape.isValid else { throw Failure("A \(input.kind.rawValue) is too small or too far from the origin.") }
            shape.sketch = sketchID
            next.shapes.append(shape)
            added.append(shape.id)
        }
        var result = self
        result.workspace = next
        let names = added.map { result.name(of: .shape($0)) }
        let sketchName = result.name(of: .sketch(sketchID))
        let description = added.compactMap { id in next.shapes.first { $0.id == id } }.map { "\(result.name(of: .shape($0.id))) \(result.shapeDescription($0))" }
        try keep(next, change: "Sketched \(names.joined(separator: ", ")) in \(sketchName) on \(label)", focus: .sketch(sketchID))
        let regions = self.workspace.sketch(sketchID).map(regions(of:)) ?? []
        var reply = "\(existing == nil ? "Created" : "Added to") \(sketchName) on \(label): \(description.joined(separator: "; "))."
        reply += regions.isEmpty ? " It has no closed regions yet." :
            " Regions: " + regions.enumerated().map { "\($0.offset + 1) \(regionDescription($0.element))" }.joined(separator: "; ") + "."
        return reply
    }

    /// Extrudes sketch regions (1-based; nil means the only one) by a signed distance along the
    /// sketch normal, as new solids, joined bosses, or cuts.
    @discardableResult mutating func extrude(sketch sketchName: String, regions numbers: [Int], distance: Double, mode: ExtrudeMode, throughAll: Bool,
                                             joining preferred: UUID? = nil, symmetric: Bool = false, taper: Double = 0) throws -> String {
        guard taper.isFinite, abs(taper) < 89 else { throw Failure("A taper must be under 89°.") }
        guard !(throughAll && (symmetric || taper != 0)) else { throw Failure("Through all has no symmetric or tapered option.") }
        let picked = Self.isSelectionWord(sketchName) && numbers.isEmpty ? selectedRegions() : []
        let sketch = picked.isEmpty ? try sketch(named: sketchName) : nil
        let regions = sketch.map(regions(of:)) ?? picked
        let name = sketch.map { name(of: .sketch($0.id)) } ?? "the \(picked.count) selected region\(picked.count == 1 ? "" : "s")"
        guard !regions.isEmpty else { throw Failure("\(name) has no closed regions to extrude.") }
        let chosen: [SketchProfile]
        if sketch == nil {
            // The selected regions and sketches, all together.
            chosen = picked
        } else if numbers.isEmpty {
            guard regions.count == 1 else {
                throw Failure("\(name) has \(regions.count) regions; say which: " + regions.enumerated().map { "\($0.offset + 1) \(regionDescription($0.element))" }.joined(separator: "; "))
            }
            chosen = regions
        } else {
            chosen = try numbers.map { n in
                guard regions.indices.contains(n - 1) else { throw Failure("\(name) has regions 1…\(regions.count).") }
                return regions[n - 1]
            }
        }
        guard distance.isFinite, abs(distance) >= 0.01, abs(distance) <= 10_000 || throughAll else { throw Failure("Distance must be 0.01–10000 mm.") }
        var next = workspace
        var made: [String] = [], said: [String] = [], checked: [UUID] = [], focus: AssistantItem?
        let amount = throughAll ? "through all" : "\(Self.mm(abs(distance))) mm"
        for profile in chosen {
            let shape = shortRegion(profile)
            var cut = ExtrusionCut(profile: profile, depth: throughAll ? (distance < 0 ? -1 : 1) : distance, throughAll: throughAll)
            var join = ExtrusionCut(profile: profile, depth: distance, operation: .join)
            if symmetric { cut.symmetric = cut.throughAll ? nil : true; join.symmetric = true }
            if taper != 0, !throughAll { cut.taper = taper; join.taper = taper }
            let placed = place(cut: cut, join: join, mode: throughAll ? .cut : mode, in: next, joining: preferred ?? faceBody(of: profile.plane))
            switch placed {
            case .cut(let ws, let targets):
                next = ws; checked += targets
                made.append("cut \(targets.map(bodyName).joined(separator: ", "))")
                said.append("Cut a \(shape) \(amount) into \(targets.map(bodyName).joined(separator: " and "))")
                focus = targets.first.map { .body($0) }
            case .join(let ws, let target):
                next = ws; checked.append(target)
                made.append("joined to \(bodyName(target))")
                said.append("Added a \(shape) \(amount) tall to \(bodyName(target))")
                focus = .body(target)
            case .newBody:
                var body = SolidBody(profile: profile, depth: distance)
                if symmetric { body.symmetric = true }
                if taper != 0 { body.taper = taper }
                guard body.isValid else { throw Failure("That region cannot be extruded.") }
                next.bodies.append(body); checked.append(body.id)
                var preview = self; preview.workspace = next
                made.append("new solid \(preview.bodyName(body.id))")
                said.append("New \(preview.bodyName(body.id)): \(shape), \(amount) \(abs(body.profile.plane.normalAxis.z) > 0.99 ? "tall" : "deep")")
                focus = .body(body.id)
            case .failed(let reason): throw Failure(reason)
            }
        }
        let regionText = numbers.isEmpty ? "\(name)" : "\(name) region\(numbers.count == 1 ? "" : "s") \(numbers.map(String.init).joined(separator: ", "))"
        try keep(next, change: said.joined(separator: "; "), checking: checked, focus: focus)
        return "Extruded \(regionText) \(throughAll ? "through all" : "\(Self.mm(distance)) mm"): \(made.joined(separator: "; "))." + checked.compactMap { id in
            workspace.bodies.first { $0.id == id }.map { " \(bodyName($0.id)) is now \(bodyDescription($0))." }
        }.joined()
    }

    private enum Placement { case cut(Workspace, [UUID]), join(Workspace, UUID), newBody, failed(String) }

    /// Where an extrusion goes, as the Extrude tool decides: `auto` cuts the visible solids it
    /// removes material from, else joins the first solid it touches, else makes a new solid.
    /// The body with a flat face on `plane`, the newest first: a sketch made on a face joins its own body.
    private func faceBody(of plane: SketchPlane) -> UUID? {
        guard !plane.isWorldPlane else { return nil }
        for body in workspace.bodies.reversed() where !workspace.isHidden(body) {
            guard let solid = try? SolidKernel.solid(for: body) else { continue }
            for face in 0..<solid.faceCount {
                guard let facePlane = solid.facePlane(face), let through = SketchPlane.through(facePlane.origin, normal: facePlane.normal) else { continue }
                if through.origin == plane.origin && simd_dot(through.normalAxis, plane.normalAxis) > 0.9999 { return body.id }
            }
        }
        return nil
    }

    private func place(cut: ExtrusionCut, join: ExtrusionCut, mode: ExtrudeMode, in workspace: Workspace, joining preferred: UUID? = nil) -> Placement {
        if mode == .cut || mode == .auto, cut.isValid {
            var result = workspace, targets: [UUID] = []
            for index in result.bodies.indices where !result.isHidden(result.bodies[index]) {
                var body = result.bodies[index]
                body.cuts.append(cut)
                guard body.isValid, let before = try? SolidKernel.solid(for: result.bodies[index]),
                      let after = try? SolidKernel.solid(for: body), after.volume < before.volume - 1e-6 else { continue }
                result.bodies[index] = body
                targets.append(body.id)
            }
            if !targets.isEmpty { return .cut(result, targets) }
            if mode == .cut { return .failed("That cut does not remove material from any visible solid. Check its position and direction (negative distances go the other way).") }
        }
        if mode == .join || mode == .auto, join.isValid {
            var result = workspace
            // The preferred body (the one sketched on) first, then the rest in order.
            let order = result.bodies.indices.sorted { a, b in (result.bodies[a].id == preferred ? 0 : 1, a) < (result.bodies[b].id == preferred ? 0 : 1, b) }
            for index in order where !result.isHidden(result.bodies[index]) {
                var body = result.bodies[index]
                body.cuts.append(join)
                guard body.isValid, (try? SolidKernel.solid(for: body)) != nil else { continue }
                result.bodies[index] = body
                return .join(result, body.id)
            }
            if mode == .join { return .failed("That extrusion does not touch a visible solid, so it cannot join one.") }
        }
        return .newBody
    }

    /// Pushes a flat face out (positive, joins) or in (negative, cuts).
    @discardableResult mutating func extrudeFace(body bodyName: String, face spec: String, distance: Double) throws -> String {
        let body = try body(named: bodyName), index = try face(spec, of: body)
        guard let source = FaceExtrusionSource(body: body, face: index) else { throw Failure("Face \(index) of \(self.bodyName(body.id)) is curved or cannot be extruded.") }
        guard distance.isFinite, abs(distance) >= 0.01, abs(distance) <= 10_000 else { throw Failure("Distance must be 0.01–10000 mm.") }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        next.bodies[bodyIndex].cuts.append(source.operation(depth: distance))
        let name = self.bodyName(body.id)
        try keep(next, change: "\(distance > 0 ? "Pulled" : "Pushed") \(name) face \(index) \(Self.mm(abs(distance))) mm \(distance > 0 ? "out" : "in")", checking: [body.id], focus: .body(body.id))
        return "Done. \(name) is now \(bodyDescription(workspace.bodies[bodyIndex]))."
    }

    /// Rounds (fillet) or bevels (chamfer) any edges of a solid, including edges made by cuts, holes,
    /// joins, unions, shells, and earlier finishes.
    @discardableResult mutating func finish(_ kind: EdgeFinish.Kind, body bodyName: String, edges spec: String, size: Double) throws -> String {
        let body = try body(named: bodyName)
        _ = try buildable(body)
        guard EdgeFinish.sizeRange.contains(size) else { throw Failure("Size must be 0.01–1000 mm.") }
        let indices = try edges(spec, of: body)
        let name = self.bodyName(body.id)
        guard let finished = body.finishing(kind, edges: indices, size: size) else {
            throw Failure("A \(Self.mm(size)) mm \(kind.rawValue) does not fit those edges of \(name); try a smaller size or fewer edges.")
        }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        next.bodies[bodyIndex] = finished
        let change = "\(kind.title) \(Self.mm(size)) mm on \(indices.count) edge\(indices.count == 1 ? "" : "s") of \(name)"
        do { try keep(next, change: change, checking: [body.id], focus: .body(body.id)) } catch {
            throw Failure("A \(Self.mm(size)) mm \(kind.rawValue) does not fit those edges of \(name); try a smaller size.")
        }
        return change + "."
    }

    /// Rounds every corner of a sketch where two lines meet (rectangle corners included) to `radius`;
    /// corners too tight for it are left sharp.
    @discardableResult mutating func roundCorners(sketch sketchName: String, radius: Double) throws -> String {
        let sketch = try self.sketch(named: sketchName)
        guard radius.isFinite, radius >= 0.01, radius <= 10_000 else { throw Failure("The radius must be 0.01–10000 mm.") }
        var next = workspace, rounded = 0, skipped = 0
        for corner in SketchModify.corners(in: next.shapes(in: sketch.id)) {
            if let result = SketchModify.roundCorner(at: corner, radius: radius, sketch: sketch.id, in: next) { next = result.workspace; rounded += 1 }
            else { skipped += 1 }
        }
        let name = self.name(of: .sketch(sketch.id))
        guard rounded > 0 else { throw Failure("No corner of \(name) has room for a \(Self.mm(radius)) mm round.") }
        try keep(next, change: "Rounded \(rounded) corner\(rounded == 1 ? "" : "s") of \(name) to \(Self.mm(radius)) mm", focus: .sketch(sketch.id))
        return "Rounded \(rounded) corner\(rounded == 1 ? "" : "s") of \(name) to \(Self.mm(radius)) mm" + (skipped > 0 ? "; \(skipped) had no room." : ".")
    }

    /// What Measure picks, by name: a body ("Body 01"), one of its faces or edges ("Body 01 face top",
    /// "Body 01 edge 4"), a sketch shape ("Line 02"), the origin, a point "x, y, z", or the selection.
    func measureItem(_ raw: String) throws -> MeasureItem {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.lowercased() == "origin" { return .point(.zero) }
        let numbers = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if numbers.count == 3, let x = numbers[0], let y = numbers[1], let z = numbers[2] { return .point(SIMD3(x, y, z)) }
        for part in ["face", "edge"] {
            if let range = text.range(of: " \(part) ", options: .caseInsensitive) {
                let body = try self.body(named: String(text[..<range.lowerBound])), spec = String(text[range.upperBound...])
                if part == "face" { return .face(bodyID: body.id, face: try face(spec, of: body)) }
                guard let index = try edges(spec, of: body).first else { throw Failure("No such edge.") }
                return .edge(bodyID: body.id, edge: index)
            }
        }
        if text.lowercased() == "selected", case .edge(let id, let index)? = selection { return .edge(bodyID: id, edge: index) }
        if text.lowercased() == "selected", case .face(let id, let face)? = selection { return .face(bodyID: id, face: face) }
        switch try item(named: text) {
        case .body(let id): return .body(id)
        case .shape(let id): return .shape(id)
        default: throw Failure("Measure bodies, their faces and edges, sketch shapes, the origin, or points.")
        }
    }

    /// Sizes of one item, or the distance (and its x, y, and z parts) and angle between two.
    func measure(_ first: String, _ second: String?) throws -> String {
        let a = try measureItem(first)
        func text(_ m: Measurement) -> String {
            "\(m.kind.title) \(Self.mm(m.value))" + (m.kind.power == 0 ? "°" : m.kind.power == 1 ? " mm" : m.kind.power == 2 ? " mm²" : " mm³")
        }
        guard let second else { return "\(first): " + Measuring.properties(of: a, in: workspace).map(text).joined(separator: ", ") }
        let b = try measureItem(second)
        guard let result = Measuring.between(a, b, in: workspace) else { throw Failure("Those cannot be measured against each other.") }
        return "\(first) to \(second): " + result.values.map(text).joined(separator: ", ") + " (nearest points \(Self.point(result.from)) and \(Self.point(result.to)))."
    }

    /// Hollows a solid to `thickness`, leaving the given faces open.
    @discardableResult mutating func shell(body bodyName: String, openFaces specs: [String], thickness: Double) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body)
        guard (0.2...100).contains(thickness) else { throw Failure("Shell thickness must be 0.2–100 mm.") }
        guard !specs.isEmpty else { throw Failure("Name at least one face to leave open, such as top.") }
        var named: [ExtrusionFace] = [], points: [SIMD3<Double>] = []
        for spec in specs {
            let index = try face(spec, of: body)
            if let face = body.extrusionFace(index, of: solid), !named.contains(face) { named.append(face) }
            else if let point = solid.interiorPoint(of: index) { points.append(point) }
            else { throw Failure("Face \(index) cannot be opened.") }
        }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        next.bodies[bodyIndex].cuts.append(.shell(of: body, openFaces: named, openingAt: points, thickness: thickness))
        let name = self.bodyName(body.id)
        do {
            try keep(next, change: "Hollowed \(name) to \(Self.mm(thickness)) mm walls, open at \(specs.joined(separator: ", "))", checking: [body.id], focus: .body(body.id))
        } catch {
            throw Failure("\(name) cannot be shelled to \(Self.mm(thickness)) mm with those faces open; try a thinner wall.")
        }
        return "Shelled \(name): walls \(Self.mm(thickness)) mm, open at \(specs.joined(separator: ", "))."
    }

    /// Drills preset holes into a flat face: at world points (default: the face center), or with
    /// `cornerInset`, one near each corner of the face's bounding rectangle, that far in from both sides.
    @discardableResult mutating func hole(body bodyName: String, face spec: String, at points: [SIMD3<Double>] = [], cornerInset: Double? = nil,
                                          kind: HoleSpec.Kind, size: String, diameter: Double? = nil, depth: Double?) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body), index = try face(spec, of: body)
        guard let facePlane = solid.facePlane(index), let plane = SketchPlane.through(facePlane.origin, normal: facePlane.normal),
              let faceCenter = solid.faceCenter(index), let outline = solid.faceOutline(index) else { throw Failure("Holes need a flat face.") }
        var label = size.uppercased().replacingOccurrences(of: " ", with: "")
        if let diameter {
            guard (0.1...200).contains(diameter) else { throw Failure("Hole diameters must be 0.1–200 mm.") }
            label = "Ø\(Self.mm(diameter))"
        } else {
            guard HolePresets.sizes.contains(label) else { throw Failure("Hole sizes are \(HolePresets.sizes.joined(separator: ", ")), or give a diameter.") }
        }
        let depth = depth ?? (diameter == nil ? HolePresets.defaultDepth(kind, size: label) : nil)
        if let depth, !(0.01...10_000).contains(depth) { throw Failure("Hole depth must be 0.01–10000 mm.") }
        var centers = points.map(plane.coordinates)
        if let inset = cornerInset {
            let local = outline.points.map(plane.coordinates)
            guard let minX = local.map(\.x).min(), let maxX = local.map(\.x).max(), let minY = local.map(\.y).min(), let maxY = local.map(\.y).max(),
                  inset > 0, maxX - minX > 2 * inset, maxY - minY > 2 * inset else { throw Failure("The face is too small for holes \(Self.mm(inset)) mm in from the corners.") }
            centers += [Point2(x: minX + inset, y: minY + inset), Point2(x: maxX - inset, y: minY + inset),
                        Point2(x: maxX - inset, y: maxY - inset), Point2(x: minX + inset, y: maxY - inset)]
        }
        if centers.isEmpty { centers = [plane.coordinates(of: faceCenter)] }
        guard centers.count <= 64 else { throw Failure("Drill at most 64 holes at a time.") }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        // A plain round hole of any diameter, or a preset for metric hardware.
        let spec = diameter.map { HoleSpec(kind: .simple, size: label, diameter: $0) } ?? HolePresets.spec(kind, size: label)
        for center in centers {
            guard let operation = ExtrusionCut.hole(spec, at: center, on: plane, depth: depth) else { throw Failure("That hole cannot be placed there.") }
            next.bodies[bodyIndex].cuts.append(operation)
        }
        let name = self.bodyName(body.id)
        let places = centers.map { Self.point(plane.point($0)) }.joined(separator: ", ")
        let title = diameter == nil ? (kind == .simple ? label : "\(kind.title.lowercased()) \(label)") : label
        let count = centers.count == 1 ? "\(title) hole" : "\(centers.count) \(title) holes"
        do {
            try keep(next, change: "Drilled \(count)\(depth.map { " \(Self.mm($0)) mm deep" } ?? " through") in \(name) at \(places)", checking: [body.id], focus: .body(body.id))
        } catch {
            throw Failure("A hole at \(places) does not reach \(name); place holes on the face.")
        }
        return "Drilled \(count) (Ø\(Self.mm(spec.diameter))) \(depth.map { "\(Self.mm($0)) mm deep" } ?? "through") into \(name) face \(index) at \(places)."
    }

    /// Press-fit pegs on a flat face (at world points, default the face center), each with a socket
    /// in every other solid it pushes into (hidden ones too), wider and deeper by `clearance`.
    @discardableResult mutating func peg(body bodyName: String, face spec: String, at points: [SIMD3<Double>] = [],
                                         diameter: Double, height: Double, clearance: Double, separate: Bool = false, into embed: Double? = nil) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body), index = try face(spec, of: body)
        guard let facePlane = solid.facePlane(index), let plane = SketchPlane.through(facePlane.origin, normal: facePlane.normal),
              let faceCenter = solid.faceCenter(index) else { throw Failure("Pegs need a flat face.") }
        let peg = PegSpec(diameter: diameter, height: height, clearance: clearance, separate: separate, embed: separate ? (embed ?? height) : 0)
        guard PegSpec.embedRange.contains(peg.embed) else { throw Failure("A separate peg reaches 0–100 mm into the face.") }
        guard PegSpec.diameterRange.contains(diameter) else { throw Failure("Peg diameters must be 1–50 mm.") }
        guard PegSpec.heightRange.contains(height) else { throw Failure("Peg heights must be 0.5–100 mm.") }
        guard Fit.clearanceRange.contains(clearance) else { throw Failure("Clearance must be 0.01–2 mm.") }
        let centers = (points.isEmpty ? [faceCenter] : points).map(plane.coordinates)
        guard centers.count <= 32 else { throw Failure("Add at most 32 pegs at a time.") }
        var next = workspace, socketed: [UUID] = []
        let name = self.bodyName(body.id)
        for center in centers {
            guard let result = PegJoint.add(peg, at: center, on: plane, to: body.id, in: next) else {
                throw Failure("A peg at \(Self.point(plane.point(center))) does not sit on \(name) face \(index); place pegs on the face.")
            }
            next = result.workspace
            socketed += result.sockets.filter { !socketed.contains($0) }
        }
        let places = centers.map { Self.point(plane.point($0)) }.joined(separator: ", ")
        let kind = separate ? "separate peg" : "peg"
        let count = centers.count == 1 ? "a Ø\(Self.mm(diameter)) × \(Self.mm(height)) mm \(kind)" : "\(centers.count) Ø\(Self.mm(diameter)) × \(Self.mm(height)) mm \(kind)s"
        // Named as they are after the change (a separate peg goes in after its solid).
        let names = next.bodyNames
        let sockets = socketed.isEmpty ? "no socket (nothing sits over the face)" :
            "sockets in \(socketed.map { names[$0] ?? "a solid" }.joined(separator: ", ")) with \(Self.mm(clearance)) mm clearance"
        try keep(next, change: "Added \(count) to \(name) at \(places), \(sockets)", checking: [body.id] + socketed, focus: .body(body.id))
        return "Added \(count) to \(name) face \(index) at \(places); \(sockets)."
    }

    /// Raised (positive `depth`) or sunk (negative) text on a flat face, centered at `at` (default the
    /// face center), capitals `height` tall, turned `angle` degrees.
    @discardableResult mutating func text(body bodyName: String, face spec: String, text: String, height: Double, depth: Double,
                                          at point: SIMD3<Double>? = nil, angle: Double = 0, font: String? = nil) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body), index = try face(spec, of: body)
        guard let facePlane = solid.facePlane(index), let plane = SketchPlane.through(facePlane.origin, normal: facePlane.normal),
              let faceCenter = solid.faceCenter(index) else { throw Failure("Text goes on a flat face.") }
        guard TextSpec.heightRange.contains(height) else { throw Failure("Text height must be 0.5–500 mm.") }
        guard depth.isFinite, abs(depth) >= 0.05, abs(depth) <= 100 else { throw Failure("Text depth must be 0.05–100 mm (negative to sink it).") }
        let fontName = font.flatMap { name in TextFonts.available.first { $0.name.lowercased() == name.lowercased() || $0.title.lowercased() == name.lowercased() }?.name } ?? TextFonts.defaultFont
        guard let textSpec = TextSpec.make(text, font: fontName, height: height, center: plane.coordinates(of: point ?? faceCenter), angle: angle),
              let operation = ExtrusionCut.text(textSpec, on: plane, depth: depth) else { throw Failure("That text cannot be drawn; use letters, digits, or symbols.") }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        next.bodies[bodyIndex].cuts.append(operation)
        let name = self.bodyName(body.id)
        let change = "\(depth > 0 ? "Raised" : "Sank") \"\(text)\" \(Self.mm(abs(depth))) mm on \(name) face \(index), \(Self.mm(height)) mm tall"
        do {
            try keep(next, change: change, checking: [body.id], focus: .body(body.id))
        } catch {
            throw Failure("\"\(text)\" at \(Self.mm(height)) mm does not fit on \(name) face \(index); make it smaller or shorter.")
        }
        return change + "."
    }

    /// A modeled thread on a hole's wall or a round boss's side: `face` is a face number, "selected",
    /// or "hole" / "boss" for the solid's first one. The size is a standard name (M2–M36, or inch
    /// sizes such as 1/4 or #10) or, with `diameter` and `pitch`, custom; otherwise it is picked from
    /// the face. `pitch` alone picks a fine pitch of the size; `length` threads only that much of the
    /// face from its open end; `starts` winds 1–4 ridges. `raised` adds the ridges onto the face
    /// instead of cutting grooves into it, keeping a thin wall whole.
    @discardableResult mutating func thread(body bodyName: String, face spec: String, size: String?, diameter: Double?, pitch: Double?,
                                            clearance: Double, leftHanded: Bool, starts: Int? = nil, length: Double? = nil,
                                            raised: Bool = false, profile: String? = nil) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body)
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        let index: Int
        if ["hole", "boss"].contains(text) {
            let wanted: Int32 = text == "hole" ? -1 : 1
            guard let found = (0..<solid.faceCount).first(where: { ssk_face_cylinder_side(solid.handle, Int32($0)) == wanted }) else {
                throw Failure("\(self.bodyName(body.id)) has no round \(text) to thread.")
            }
            index = found
        } else {
            index = try face(spec, of: body)
        }
        guard clearance == 0 || Fit.clearanceRange.contains(clearance) else { throw Failure("Clearance must be 0–2 mm.") }
        guard var thread = body.threadSpec(onFace: index, of: solid, clearance: clearance) else {
            throw Failure("Face \(index) of \(self.bodyName(body.id)) is not a hole's wall or a round boss's side.")
        }
        if raised { thread = thread.made(raised: true) }
        if let size, !size.isEmpty {
            // "M8x1.25" names a size and a pitch.
            let parts = size.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x", maxSplits: 1).map(String.init)
            guard let standard = ThreadPresets.size(named: parts[0]) else {
                throw Failure("Thread sizes are \(ThreadPresets.names.joined(separator: ", ")), or give a diameter and pitch.")
            }
            thread = thread.with(size: standard, diameter: standard.diameter, pitch: parts.count > 1 ? Double(parts[1]) ?? standard.coarse : standard.coarse)
        }
        if let diameter { thread = thread.with(size: nil, diameter: diameter, pitch: thread.pitch) }
        if let pitch { thread = diameter == nil ? thread.with(pitch: pitch) : thread.with(size: thread.standardSize, diameter: thread.majorDiameter, pitch: pitch) }
        if let profile, !profile.isEmpty {
            switch profile.lowercased() {
            case "iso", "iso 60", "60", "standard": thread = thread.with(profile: .iso)
            case "printable", "printable 45", "45", "lid": thread = thread.with(profile: .printable)
            default: throw Failure("Profile is iso (screws and nuts) or printable (45°, for lids and jars).")
            }
        }
        if leftHanded { thread.leftHanded = true }
        if let starts {
            guard ThreadSpec.startsRange.contains(starts) else { throw Failure("A thread has 1 to 4 starts.") }
            thread.starts = starts > 1 ? starts : nil
        }
        guard thread.isValid else {
            throw Failure("That thread cannot be cut: the pitch must be 0.2–20 mm, and at most \(Self.mm(max(0, thread.largestPitch))) mm for a \(Self.mm(thread.majorDiameter)) mm thread.")
        }
        guard thread.fit.isUsable else { throw Failure(thread.fitSummary { "\(Self.mm($0)) mm" }) }
        if let length {
            guard let shorter = thread.shortened(to: length, atEnd: body.threadEntryIsAtEnd(thread)) else {
                throw Failure("A thread is at least one turn (\(Self.mm(thread.shortestLength)) mm) long.")
            }
            thread = shorter
        }
        guard let threaded = body.threading(thread) else {
            throw Failure("\(thread.title) could not be built on that \(thread.isInternal ? "hole" : "boss") (\(Self.mm(thread.surfaceDiameter)) mm); try a nearby pitch or size.")
        }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        next.bodies[bodyIndex] = threaded
        let kind = thread.isInternal ? "nut thread in the hole" : "bolt thread on the boss"
        var text2 = "\(thread.isRaised ? "Raised" : "Cut") a \(thread.title) \(kind) of \(self.bodyName(body.id)) (face \(index))\(thread.clearance > 0 ? " with \(Self.mm(thread.clearance)) mm clearance" : "")"
        if thread.fit.kind != .full { text2 += ". " + thread.fitSummary { "\(Self.mm($0)) mm" }.dropLast() }
        if let wall = body.wallBehindThread(thread, in: solid) {
            text2 += ". " + thread.wallWarning(wall) { "\(Self.mm($0)) mm" } + " Threading it raised instead would keep the wall whole"
        }
        try keep(next, change: text2, checking: [body.id], focus: .body(body.id))
        return text2 + "."
    }

    /// The part that screws onto a body's thread (its last one), already screwed on: a nut or cap for
    /// a bolt's thread, a bolt or plug for a nut's. `kind` names one; nil or empty picks the likelier.
    @discardableResult mutating func matingPart(body bodyName: String, kind: String?) throws -> String {
        let body = try body(named: bodyName)
        guard let index = body.matableThreads.last, let spec = body.cuts[index].thread else {
            throw Failure("\(self.bodyName(body.id)) has no thread with an open end to screw a part onto; add one with add_thread first.")
        }
        let choices = ThreadMate.choices(for: spec)
        let wanted = (kind ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let mate: ThreadMate
        if wanted.isEmpty {
            mate = choices[0]
        } else {
            guard let found = choices.first(where: { $0.rawValue == wanted || $0.title.lowercased() == wanted }) else {
                throw Failure("A \(spec.isInternal ? "hole's" : "boss's") thread takes a \(choices.map(\.noun).joined(separator: " or ")).")
            }
            mate = found
        }
        guard let part = body.matingPart(mate, forThreadAt: index) else { throw Failure("A \(mate.noun) could not be made for that thread.") }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        next.bodies.insert(part, at: bodyIndex + 1)
        let host = self.bodyName(body.id)
        try keep(next, change: "Made a \(spec.title) \(mate.noun) screwed onto \(host)", checking: [part.id], focus: .body(part.id))
        return "Made a \(spec.title) \(mate.noun) screwed onto \(host), as \(self.bodyName(part.id))."
    }

    /// A primitive standing on the Top plane at `point` (its x and y; default the origin): box
    /// (width, length, height), cylinder (diameter, height), sphere (diameter), or torus (diameter
    /// through the tube's middle, tube diameter).
    @discardableResult mutating func primitive(kind name: String, sizes: [Double], at point: SIMD3<Double>?) throws -> String {
        guard let kind = PrimitiveKind(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw Failure("Primitives are box, cylinder, sphere, and torus.")
        }
        let names = kind.sizes.map { $0.name.lowercased() }
        guard sizes.count == names.count else { throw Failure("A \(kind.rawValue) takes \(names.joined(separator: ", ")) in mm.") }
        let center = Point2(x: point?.x ?? 0, y: point?.y ?? 0)
        guard let body = Primitives.body(kind, sizes: sizes, on: .top, at: center) else {
            throw Failure(kind == .torus ? "A torus's tube must be thinner than its diameter, and sizes 0.1–10000 mm." : "Sizes must be 0.1–10000 mm.")
        }
        var next = workspace
        next.bodies.append(body)
        let change = "Made a \(kind.rawValue) (\(zip(names, sizes).map { "\($0) \(Self.mm($1)) mm" }.joined(separator: ", "))) at \(Self.point(SketchPlane.top.point(center)))"
        try keep(next, change: change, checking: [body.id], focus: .body(body.id))
        return change + "."
    }

    /// The Fit Test coupon beside the model: a plate with holes at 0.10–0.40 mm clearance and a peg.
    @discardableResult mutating func fitTest() throws -> String {
        let coupon = FitTest.coupon(at: FitTest.origin(beside: workspace))
        guard coupon.count == 2 else { throw Failure("The Fit Test could not be built.") }
        var next = workspace
        next.bodies += coupon
        try keep(next, change: "Added the Fit Test: a plate with holes at 0.10–0.40 mm clearance and a loose peg", checking: coupon.map(\.id),
                 focus: .body(coupon[0].id))
        return "Added the Fit Test coupon (a plate whose holes, from the beveled corner, leave 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, and 0.40 mm around the peg, and a loose 6 mm peg). Print both; the first hole the peg slides into is the printer's clearance, to set as Fit in the project menu."
    }

    /// Moves and/or turns solids and sketches (or copies of them).
    @discardableResult mutating func transform(items names: [String], move offset: SIMD3<Double>, rotate degrees: Double, axis: String, pivot: SIMD3<Double>?, copy: Bool) throws -> String {
        let names = expandingSelection(names)
        guard !names.isEmpty else { throw Failure("Name the items to move.") }
        let axes: [String: SIMD3<Double>] = ["x": [1, 0, 0], "y": [0, 1, 0], "z": [0, 0, 1]]
        guard let axisVector = axes[axis.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " +"))] else { throw Failure("Rotation axis must be x, y, or z.") }
        guard degrees.isFinite, offset.x.isFinite, offset.y.isFinite, offset.z.isFinite, simd_length(offset) <= 100_000 else { throw Failure("Invalid amount.") }
        guard simd_length(offset) >= 1e-6 || abs(degrees) >= 1e-6 else { throw Failure("Give a distance to move or an angle to turn.") }
        var next = workspace, moved: [String] = [], checked: [UUID] = [], focus: AssistantItem?
        for name in names {
            let target: TransformTarget
            // A Model Tree group moves with everything in it.
            if let group = workspace.groupNames.first(where: { $0.value.lowercased() == name.trimmingCharacters(in: .whitespaces).lowercased() })?.key {
                target = .group(group)
            } else {
            switch try item(named: name) {
            case .body(let id): target = .body(id)
            case .sketch(let id): target = .sketch(id)
            case .shape(let id):
                guard let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch else { throw Failure("\(name) has no sketch.") }
                target = .sketch(sketch)
            case .plane: throw Failure("Construction planes cannot be moved; make a new one.")
            }
            }
            var current = target, didCopy = false
            if abs(degrees) >= 1e-6 {
                let center: SIMD3<Double>?
                switch current {
                case .body(let id): center = next.bodies.first { $0.id == id }.flatMap(next.center(of:))
                case .sketch(let id): center = next.sketch(id).flatMap(next.center(of:))
                case .shape(let id): center = next.shapes.first { $0.id == id }.flatMap(next.center(of:))
                case .group(let id): center = next.center(ofGroup: id)
                case .items(let bodies, let sketches): center = next.center(ofBodies: bodies, sketches: sketches)
                }
                guard let result = next.transforming(current, by: .rotate(degrees: degrees, about: axisVector, through: pivot ?? center ?? .zero), copy: copy) else {
                    throw Failure("\(name) cannot be turned that way.")
                }
                next = result.workspace; current = result.target; didCopy = copy
            }
            if simd_length(offset) >= 1e-6 {
                guard let result = next.transforming(current, by: .move(offset), copy: copy && !didCopy) else { throw Failure("\(name) cannot be moved there.") }
                next = result.workspace; current = result.target
            }
            if case .body(let id) = current { checked.append(id); focus = .body(id) } else if case .sketch(let id) = current { focus = .sketch(id) }
            else if case .group(let id) = current { checked += next.contents(of: id).bodies }
            moved.append(name)
        }
        var parts: [String] = []
        if simd_length(offset) >= 1e-6 { parts.append("moved by \(Self.point(offset))") }
        if abs(degrees) >= 1e-6 { parts.append("turned \(Self.mm(degrees))° about \(axis.uppercased())") }
        let text = "\(copy ? "Copied and " : "")\(parts.joined(separator: " and ")): \(moved.joined(separator: ", "))"
        try keep(next, change: text.prefix(1).uppercased() + text.dropFirst(), checking: checked, focus: focus)
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    /// Changes a shape's width, height, diameter, radius, or length, or a solid's extrusion depth
    /// or revolve angle.
    @discardableResult mutating func setDimension(item name: String, dimension raw: String, value: Double) throws -> String {
        let dimension = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard value.isFinite, abs(value) >= 0.01, abs(value) <= 10_000 else { throw Failure("Values must be 0.01–10000.") }
        switch try item(named: name) {
        case .shape(let id):
            guard let shape = workspace.shapes.first(where: { $0.id == id }) else { throw Failure("That shape no longer exists.") }
            var target: ShapeDimension, amount = value
            switch (shape.kind, dimension) {
            case (.rectangle, "width"): target = .width
            case (.rectangle, "height"), (.rectangle, "depth"): target = .height
            case (.circle, "diameter"): target = .diameter
            case (.circle, "radius"): target = .diameter; amount = value * 2
            case (.line, "length"): target = .length
            case (.slot, "length"): target = .length
            case (.slot, "width"): target = .width
            case (.arc, "radius"): target = .radius
            case (.arc, "diameter"): target = .radius; amount = value / 2
            default:
                let has = switch shape.kind {
                case .rectangle: "width and height"
                case .circle: "diameter and radius"
                case .slot: "length (between its round ends' centers) and width"
                case .arc: "radius"
                default: "length"
                }
                throw Failure("\(name) is a \(shape.kind.rawValue); it has \(has).")
            }
            guard amount > 0, let updated = SketchEditing.dimension(target, value: amount, of: shape),
                  let next = SketchEditing.replacing(updated, in: workspace) else { throw Failure("\(name) cannot be \(Self.mm(value)) mm.") }
            let checked = next.bodies.map(\.id)
            try keep(next, change: "Set \(self.name(of: .shape(id))) \(dimension) to \(Self.mm(value)) mm", checking: checked, focus: shape.sketch.map { .sketch($0) })
            return "Set \(self.name(of: .shape(id))) \(dimension) to \(Self.mm(value)) mm. Solids already made from it keep their own copy of the shape; change their depth or rebuild them to follow."
        case .body(let id):
            guard let index = workspace.bodies.firstIndex(where: { $0.id == id }) else { throw Failure("That body no longer exists.") }
            var next = workspace
            let body = next.bodies[index]
            if ["angle", "revolve angle"].contains(dimension) {
                guard var revolve = body.revolve else { throw Failure("\(name) is not revolved.") }
                revolve.angle = value
                next.bodies[index].revolve = revolve
                try keep(next, change: "Set \(bodyName(id)) revolve angle to \(Self.mm(value))°", checking: [id], focus: .body(id))
                return "Set \(bodyName(id)) to \(Self.mm(value))°."
            }
            guard ["depth", "height", "thickness", "distance", "length", "extrusion"].contains(dimension) else {
                throw Failure("Solids have depth (extrusion distance) or angle (revolves). Change width or height on the sketch shape instead.")
            }
            guard body.imported == nil, body.revolve == nil else { throw Failure("\(name) is not an extrusion.") }
            next.bodies[index].depth = body.depth < 0 ? -abs(value) : abs(value)
            do {
                try keep(next, change: "Set \(bodyName(id)) depth to \(Self.mm(abs(value))) mm", checking: [id], focus: .body(id))
            } catch { throw Failure("Its fillets, chamfers, or cuts do not fit at \(Self.mm(value)) mm.") }
            return "Set \(bodyName(id)) depth to \(Self.mm(abs(value))) mm; it is now \(bodyDescription(workspace.bodies[index]))."
        default:
            throw Failure("\(name) has no dimension to set.")
        }
    }

    /// Deletes solids, sketches, shapes, and construction planes.
    @discardableResult mutating func delete(items names: [String]) throws -> String {
        let names = expandingSelection(names)
        guard !names.isEmpty else { throw Failure("Name the items to delete.") }
        let items = try names.map { try item(named: $0) }
        let labels = items.map(name(of:))
        var next = workspace
        for item in items {
            switch item {
            case .body(let id): next.bodies.removeAll { $0.id == id }
            case .sketch(let id): next.shapes.removeAll { $0.sketch == id }
            case .shape(let id): next.shapes.removeAll { $0.id == id }
            case .plane(let id): next.constructionPlanes.removeAll { $0.id == id }
            }
        }
        if case .body(let id) = selection, items.contains(.body(id)) { selection = nil }
        try keep(next, change: "Deleted \(labels.joined(separator: ", "))")
        return "Deleted \(labels.joined(separator: ", ")). Names of later items shift down."
    }

    /// Hides or shows solids, sketches, construction planes, and groups (a group's contents with it).
    @discardableResult mutating func setHidden(items names: [String], hidden: Bool) throws -> String {
        let names = expandingSelection(names)
        var next = workspace, labels: [String] = []
        var items: [AssistantItem] = []
        for name in names {
            if let group = group(named: name) {
                next = next.settingGroup(group, hidden: hidden) ?? next
                labels.append(workspace.groupNames[group] ?? name)
            } else {
                let item = try item(named: name)
                items.append(item)
                labels.append(self.name(of: item))
            }
        }
        for item in items {
            switch item {
            case .body(let id): if let i = next.bodies.firstIndex(where: { $0.id == id }) { next.bodies[i].hidden = hidden ? true : nil }
            case .sketch(let id): if let i = next.sketches.firstIndex(where: { $0.id == id }) { next.sketches[i].hidden = hidden ? true : nil }
            case .plane(let id): if let i = next.constructionPlanes.firstIndex(where: { $0.id == id }) { next.constructionPlanes[i].hidden = hidden ? true : nil }
            case .shape(let id):
                if let sketch = next.shapes.first(where: { $0.id == id })?.sketch, let i = next.sketches.firstIndex(where: { $0.id == sketch }) {
                    next.sketches[i].hidden = hidden ? true : nil
                }
            }
        }
        let list = labels.joined(separator: ", ")
        try keep(next, change: "\(hidden ? "Hid" : "Showed") \(list)")
        return "\(hidden ? "Hid" : "Showed") \(list)."
    }

    /// Unites tool solids into a target, or subtracts them from it.
    /// Unites or subtracts solids. A subtract's `clearance` grows the tools first, so a printed part
    /// shaped like them fits into the space left.
    @discardableResult mutating func combine(union: Bool, target targetName: String, tools toolNames: [String], keepTools: Bool,
                                             clearance: Double? = nil) throws -> String {
        if let clearance {
            guard !union else { throw Failure("Clearance only applies to subtract.") }
            guard Fit.clearanceRange.contains(clearance) else { throw Failure("Clearance must be 0.01–2 mm.") }
        }
        let (target, tools) = try targetAndTools(targetName, toolNames)
        var next = workspace
        guard let index = next.bodies.firstIndex(where: { $0.id == target.id }) else { throw Failure("That body no longer exists.") }
        let used: [UUID]
        if union {
            let result = Unioning.union(target, with: tools)
            next.bodies[index] = result.result
            used = tools.map(\.id).filter { !result.untouched.contains($0) }
        } else {
            let result = Subtracting.subtract(tools, from: target, clearance: clearance)
            next.bodies[index] = result.result
            used = result.used
        }
        guard !used.isEmpty else { throw Failure(union ? "Those solids do not touch \(bodyName(target.id)), so they cannot be united." : "Those solids do not overlap \(bodyName(target.id)).") }
        let toolLabels = used.map(bodyName).joined(separator: ", "), targetLabel = bodyName(target.id)
        if !keepTools { next.bodies.removeAll { used.contains($0.id) } }
        let text = union ? "United \(toolLabels) into \(targetLabel)" :
            "Subtracted \(toolLabels) from \(targetLabel)" + (clearance.map { " with \(Self.mm($0)) mm clearance" } ?? "")
        try keep(next, change: text, checking: [target.id], focus: .body(target.id))
        return text + (keepTools ? "; the tool solids were kept." : ".") + " Names of later items may shift."
    }

    // MARK: Missing basics (October 21, 2026)

    /// Scales bodies and sketches by a percentage (sketches only uniformly), about their middle, the
    /// middle of their bottom ("base", so a part stays on the plate), or the origin.
    @discardableResult mutating func scale(items names: [String], percent: Double?, percents: SIMD3<Double>?, about pivot: String?, copy: Bool) throws -> String {
        let names = expandingSelection(names)
        guard !names.isEmpty else { throw Failure("Name the items to scale.") }
        let factors: SIMD3<Double>
        if let percents { factors = percents / 100 } else if let percent { factors = SIMD3(repeating: percent / 100) } else {
            throw Failure("Give a percentage (100 keeps the size).")
        }
        guard [factors.x, factors.y, factors.z].allSatisfy({ (0.001...100).contains($0) }) else { throw Failure("Percentages must be 0.1–10000.") }
        var bodies: [UUID] = [], sketches: [UUID] = []
        for name in names {
            switch try item(named: name) {
            case .body(let id): bodies.append(id)
            case .sketch(let id): sketches.append(id)
            case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { sketches.append(sketch) }
            case .plane: throw Failure("Construction planes cannot be scaled.")
            }
        }
        guard let bounds = Scaling.bounds(of: workspace, bodies: bodies, sketches: sketches) else { throw Failure("Nothing to scale.") }
        let middle = (bounds.min + bounds.max) / 2
        let center: SIMD3<Double>
        switch pivot?.lowercased() ?? "center" {
        case "base", "bottom", "plate": center = SIMD3(middle.x, middle.y, bounds.min.z)
        case "origin": center = .zero
        default: center = middle
        }
        // Stretches go along world x, y, z.
        guard let result = Scaling.scale(workspace, bodies: bodies, sketches: sketches, about: center, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                         factors: factors, copy: copy) else {
            throw Failure(sketches.isEmpty ? "That scale does not build; try another percentage." : "Sketches scale only by one percentage for all directions.")
        }
        let amount = factors.x == factors.y && factors.y == factors.z ? "\(Self.mm(factors.x * 100))%" : "\(Self.mm(factors.x * 100)) × \(Self.mm(factors.y * 100)) × \(Self.mm(factors.z * 100))% (x × y × z)"
        let text = "Scaled \(names.joined(separator: ", ")) to \(amount)" + (copy ? " as copies" : "")
        try keep(result.workspace, change: text, checking: result.bodies, focus: result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) })
        return text + "."
    }

    /// Takes faces off a body and closes the gap (a fillet, chamfer, hole, or boss removed).
    @discardableResult mutating func deleteFaces(body bodyName: String, faces specs: [String]) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body)
        guard !specs.isEmpty else { throw Failure("Name the faces to delete.") }
        let points = try specs.map { spec -> SIMD3<Double> in
            let index = try face(spec, of: body)
            guard let center = solid.faceCenter(index), let face = solid.face(near: center, tolerance: 1e-3), face == index else {
                // A ring's center lies off it: use a point on its outline instead.
                guard let point = solid.faceOutline(index)?.points.first else { throw Failure("Face \(index) cannot be found again.") }
                return point
            }
            return center
        }
        guard let result = FaceEditing.deleting(faces: points, of: body), let index = workspace.bodies.firstIndex(where: { $0.id == body.id }) else {
            throw Failure("The faces around those cannot close the gap; include the rest of the feature (such as a hole's floor).")
        }
        var next = workspace
        next.bodies[index] = result
        let text = "Deleted \(specs.count == 1 ? "a face" : "\(specs.count) faces") of \(self.bodyName(body.id))"
        try keep(next, change: text, checking: [body.id], focus: .body(body.id))
        return "\(text). \(self.bodyName(body.id)) is now \(bodyDescription(workspace.bodies[index]))."
    }

    /// Deletes a hole: the step that made it (with a thread in it and fillets on its rim), or for a
    /// hole no step made, its faces with the gap closed. `face` is a hole wall's face number,
    /// "selected", or "hole" for the body's first hole.
    @discardableResult mutating func deleteHole(body bodyName: String, face spec: String) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body)
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        let index: Int
        if text == "hole" {
            guard let found = (0..<solid.faceCount).first(where: { solid.cylinderSide($0) == -1 }) else {
                throw Failure("\(self.bodyName(body.id)) has no round hole.")
            }
            index = found
        } else {
            index = try face(spec, of: body)
        }
        // Any point does: it is carried to the wall's axis.
        guard let probe = solid.holeProbe(face: index, near: solid.faceCenter(index) ?? .zero) else {
            throw Failure("Face \(index) of \(self.bodyName(body.id)) is not the wall of a round hole.")
        }
        let next: SolidBody, change: String
        if let removal = body.removingHole(around: probe) {
            next = removal.body
            change = "Deleted a hole in \(self.bodyName(body.id))" + (removal.threads > 0 ? " and its thread" : "")
        } else if let closed = FaceEditing.deleting(faces: solid.holeFacePoints(wall: index), of: body) {
            next = closed
            change = "Deleted a hole in \(self.bodyName(body.id)) and closed the gap"
        } else {
            throw Failure("That hole could not be deleted; try delete_faces with all of its faces.")
        }
        guard let bodyIndex = workspace.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        var updated = workspace
        updated.bodies[bodyIndex] = next
        try keep(updated, change: change, checking: [body.id], focus: .body(body.id))
        return change + "."
    }

    /// Changes the size of one of a body's fillets or chamfers, or with `size` nil takes it out so
    /// its edges are sharp again. `which` is its number in the order they were made (1 for the
    /// first) or "last".
    @discardableResult mutating func editFinish(body bodyName: String, which: String, size: Double?) throws -> String {
        let body = try body(named: bodyName)
        _ = try buildable(body)
        let name = self.bodyName(body.id)
        let sources = body.finishes.indices.map(FinishSource.named) + body.cuts.indices.filter { body.cuts[$0].finish != nil }.map(FinishSource.step)
        guard !sources.isEmpty else { throw Failure("\(name) has no fillets or chamfers.") }
        let text = which.trimmingCharacters(in: .whitespaces).lowercased()
        let number = text == "last" ? sources.count : Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
        guard sources.indices.contains(number - 1), let finish = body.finishKind(sources[number - 1]) else {
            throw Failure("\(name) has \(sources.count) fillet\(sources.count == 1 ? "" : "s") or chamfer\(sources.count == 1 ? "" : "s"); give 1…\(sources.count) or last.")
        }
        let source = sources[number - 1]
        let next: SolidBody, change: String
        if let size {
            guard EdgeFinish.sizeRange.contains(size) else { throw Failure("Size must be 0.01–1000 mm.") }
            guard let resized = body.resizingFinish(source, to: size) else {
                throw Failure("A \(Self.mm(size)) mm \(finish.kind.rawValue) does not fit those edges of \(name); try a smaller size.")
            }
            next = resized
            change = "Changed a \(finish.kind.rawValue) of \(name) from \(Self.mm(finish.size)) to \(Self.mm(size)) mm"
        } else {
            guard let removed = body.removingFinish(source) else { throw Failure("That \(finish.kind.rawValue) of \(name) could not be taken out.") }
            next = removed
            change = "Deleted a \(Self.mm(finish.size)) mm \(finish.kind.rawValue) from \(name)"
        }
        guard let bodyIndex = workspace.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        var updated = workspace
        updated.bodies[bodyIndex] = next
        try keep(updated, change: change, checking: [body.id], focus: .body(body.id))
        return change + "."
    }

    /// The entry `which` names among `count` (1 for the first made, or "last"), counting from 0.
    private func numbered(_ which: String, of count: Int, _ noun: String, in name: String) throws -> Int {
        guard count > 0 else { throw Failure("\(name) has no \(noun)s.") }
        let text = which.trimmingCharacters(in: .whitespaces).lowercased()
        let number = text == "last" || text.isEmpty ? count : Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
        guard (1...count).contains(number) else { throw Failure("\(name) has \(count) \(noun)\(count == 1 ? "" : "s"); give 1…\(count) or last.") }
        return number - 1
    }

    /// Changes one of a body's holes, threads, text, or pegs after it was made (`which`: 1 for the
    /// first made, or "last"); values left nil stay as they are. Hole: `kind` and `size` pick a
    /// preset, `diameter` a plain round hole, `depth` a blind depth or `through`. Thread: `size`
    /// ("M8", "M8x1"), or `diameter` and `pitch`, `length` from its open end, `clearance`, `starts`.
    /// Text: `text`, `height`, `depth` (negative sinks it). Peg: `diameter`, `height`, `clearance`.
    @discardableResult mutating func editFeature(body bodyName: String, feature: String, which: String, kind: String? = nil, size: String? = nil,
                                                 diameter: Double? = nil, depth: Double? = nil, through: Bool? = nil, height: Double? = nil,
                                                 pitch: Double? = nil, length: Double? = nil, clearance: Double? = nil, starts: Int? = nil,
                                                 text newText: String? = nil) throws -> String {
        let body = try body(named: bodyName)
        _ = try buildable(body)
        let name = self.bodyName(body.id)
        guard let bodyIndex = workspace.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        var next = workspace, checking = [body.id]
        let change: String
        switch feature.trimmingCharacters(in: .whitespaces).lowercased() {
        case "hole":
            let holes = body.cuts.indices.filter { body.cuts[$0].hole != nil }
            let index = holes[try numbered(which, of: holes.count, "hole", in: name)]
            let cut = body.cuts[index]
            guard var spec = cut.hole, let circle = cut.profile.circle else { throw Failure("That hole cannot be changed.") }
            if let diameter {
                guard (0.1...200).contains(diameter) else { throw Failure("Hole diameters must be 0.1–200 mm.") }
                spec = HoleSpec(kind: .simple, size: "Ø\(Self.mm(diameter))", diameter: diameter)
            } else if kind != nil || size != nil {
                let label = size?.uppercased().replacingOccurrences(of: " ", with: "") ?? (HolePresets.sizes.contains(spec.size) ? spec.size : "M3")
                guard HolePresets.sizes.contains(label) else { throw Failure("Hole sizes are \(HolePresets.sizes.joined(separator: ", ")), or give a diameter.") }
                spec = HolePresets.spec(kind.flatMap { HoleSpec.Kind(rawValue: $0.lowercased()) } ?? spec.kind, size: label)
            }
            let newDepth: Double? = through == true ? nil : depth ?? (cut.throughAll ? nil : cut.depth)
            if let newDepth, !(0.01...10_000).contains(newDepth) { throw Failure("Hole depth must be 0.01–10000 mm.") }
            guard let operation = ExtrusionCut.hole(spec, at: circle.center, on: cut.profile.plane, depth: newDepth) else { throw Failure("That hole cannot be made.") }
            next.bodies[bodyIndex] = body.placing(operation, replacing: index)
            change = "Changed a hole of \(name) to Ø\(Self.mm(spec.diameter))\(spec.kind == .simple ? "" : " " + spec.kind.title.lowercased()) \(newDepth.map { "\(Self.mm($0)) mm deep" } ?? "through")"
        case "text":
            let texts = body.cuts.indices.filter { body.cuts[$0].text != nil }
            let index = texts[try numbered(which, of: texts.count, "text", in: name)]
            let cut = body.cuts[index]
            guard let old = cut.text else { throw Failure("That text cannot be changed.") }
            let words = newText ?? old.text, size = height ?? old.height, newDepth = depth ?? cut.depth
            guard TextSpec.heightRange.contains(size) else { throw Failure("Text height must be 0.5–500 mm.") }
            guard newDepth.isFinite, abs(newDepth) >= 0.05, abs(newDepth) <= 100 else { throw Failure("Text depth must be 0.05–100 mm (negative to sink it).") }
            guard let spec = TextSpec.make(words, font: old.font, height: size, center: old.center, angle: old.angle),
                  let operation = ExtrusionCut.text(spec, on: cut.profile.plane, depth: newDepth) else { throw Failure("That text cannot be drawn; use letters, digits, or symbols.") }
            next.bodies[bodyIndex] = body.placing(operation, replacing: index)
            change = "Changed text on \(name) to \"\(words)\", \(Self.mm(size)) mm tall, \(newDepth > 0 ? "raised" : "sunk") \(Self.mm(abs(newDepth))) mm"
        case "thread":
            let threads = body.cuts.indices.filter { body.cuts[$0].thread != nil }
            let index = threads[try numbered(which, of: threads.count, "thread", in: name)]
            guard let setup = body.threadSetup(at: index) else { throw Failure("The face of that thread is gone, so it cannot be changed.") }
            var thread = setup.spec
            if let size, !size.isEmpty {
                let parts = size.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x", maxSplits: 1).map(String.init)
                guard let standard = ThreadPresets.size(named: parts[0]) else {
                    throw Failure("Thread sizes are \(ThreadPresets.names.joined(separator: ", ")), or give a diameter and pitch.")
                }
                thread = thread.with(size: standard, diameter: standard.diameter, pitch: parts.count > 1 ? Double(parts[1]) ?? standard.coarse : standard.coarse)
            }
            if let diameter { thread = thread.with(size: nil, diameter: diameter, pitch: thread.pitch) }
            if let pitch { thread = diameter == nil ? thread.with(pitch: pitch) : thread.with(size: thread.standardSize, diameter: thread.majorDiameter, pitch: pitch) }
            if let clearance {
                guard clearance == 0 || Fit.clearanceRange.contains(clearance) else { throw Failure("Clearance must be 0–2 mm.") }
                thread.clearance = clearance
            }
            if let starts {
                guard ThreadSpec.startsRange.contains(starts) else { throw Failure("A thread has 1 to 4 starts.") }
                thread.starts = starts > 1 ? starts : nil
            }
            guard thread.isValid else {
                throw Failure("That thread cannot be cut: the pitch must be 0.2–20 mm, and at most \(Self.mm(max(0, thread.largestPitch))) mm for a \(Self.mm(thread.majorDiameter)) mm thread.")
            }
            guard thread.fit.isUsable else { throw Failure(thread.fitSummary { "\(Self.mm($0)) mm" }) }
            var built = thread
            if let threaded = length ?? setup.length, threaded < thread.threadedLength - 1e-6 {
                guard let shorter = thread.shortened(to: threaded, atEnd: setup.atEnd) else {
                    throw Failure("A thread is at least one turn (\(Self.mm(thread.shortestLength)) mm) long.")
                }
                built = shorter
            }
            guard var rebuilt = setup.base.threading(built, at: index) else {
                throw Failure("\(built.title) could not be built on that \(built.isInternal ? "hole" : "boss"); try a nearby pitch or size.")
            }
            rebuilt.cuts[index].id = body.cuts[index].id
            next.bodies[bodyIndex] = rebuilt
            change = "Changed a thread of \(name) to \(built.title), \(Self.mm(built.threadedLength)) mm long"
        case "peg":
            var tags: [UUID] = []
            if let pin = body.peg { tags = [pin.id] }
            for cut in body.cuts where cut.operation == .join { if let tag = cut.peg, !tags.contains(tag) { tags.append(tag) } }
            if tags.isEmpty { for cut in body.cuts { if let tag = cut.peg, !tags.contains(tag) { tags.append(tag) } } }
            let id = tags[try numbered(which, of: tags.count, "peg", in: name)]
            guard let old = PegJoint.existing(id, in: workspace, preferring: body.id, clearance: Fit.preferredClearance) else {
                throw Failure("That peg cannot be changed (pegs made before October 24, 2026 can be resized from their faces).")
            }
            var spec = old.spec
            if let diameter { spec.diameter = diameter }
            if let height { spec.height = height }
            if let clearance { spec.clearance = clearance }
            guard spec.isValid else { throw Failure("A peg is 1–50 mm across and 0.5–100 mm tall, with 0.01–2 mm clearance.") }
            guard let result = PegJoint.replace(old, with: spec, at: old.center) else { throw Failure("A peg that size does not fit there.") }
            next = result.workspace
            checking = next.bodies.map(\.id)
            change = "Changed a peg of \(name) to Ø\(Self.mm(spec.diameter)) × \(Self.mm(spec.height)) mm, \(result.sockets.count == 1 ? "1 socket" : "\(result.sockets.count) sockets")"
        default:
            throw Failure("Choose a hole, thread, text, or peg to change.")
        }
        do {
            try keep(next, change: change, checking: checking, focus: .body(body.id))
        } catch {
            throw Failure("\(name) does not build with that change (a fillet or chamfer on it may not follow); try other values.")
        }
        return change + "."
    }

    /// Sets a round face's diameter, or a flat face's distance to the parallel face behind it.
    @discardableResult mutating func resizeFace(body bodyName: String, face spec: String, value: Double) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body), index = try face(spec, of: body)
        guard let size = FaceEditing.size(of: index, on: solid) else {
            throw Failure("Face \(index) is neither round nor has a parallel face behind it.")
        }
        guard value.isFinite, value >= 0.01, value <= 10_000 else { throw Failure("Sizes are 0.01–10000 mm.") }
        let point = solid.faceOutline(index)?.points.first ?? solid.faceCenter(index) ?? .zero
        guard let resized = FaceEditing.resizing(body, face: index, at: point, to: value), let bodyIndex = workspace.bodies.firstIndex(where: { $0.id == body.id }) else {
            throw Failure("That size does not fit: the faces around it cannot follow.")
        }
        var next = workspace
        next.bodies[bodyIndex] = resized
        let what: String
        switch size { case .diameter: what = "diameter"; case .distance: what = "distance to the face behind it" }
        let text = "Set \(self.bodyName(body.id)) face \(index)'s \(what) to \(Self.mm(value)) mm"
        try keep(next, change: text, checking: [body.id], focus: .body(body.id))
        return "\(text). \(self.bodyName(body.id)) is now \(bodyDescription(workspace.bodies[bodyIndex]))."
    }

    /// Adds an outline `distance` from a sketch shape (and the lines joined to it), to its sketch.
    @discardableResult mutating func offsetShape(_ shapeName: String, distance: Double, bothSides: Bool) throws -> String {
        guard case .shape(let id) = try item(named: shapeName), let shape = workspace.shapes.first(where: { $0.id == id }) else {
            throw Failure("Name a sketch shape, such as Rectangle 01 or Line 02.")
        }
        guard distance.isFinite, abs(distance) >= 0.001, abs(distance) <= 10_000 else { throw Failure("Distance must be 0.001–10000 mm.") }
        guard let shapes = SketchTools.offset(id, by: distance, bothSides: bothSides, rounded: false, in: workspace) else {
            throw Failure("That outline cannot be offset that far.")
        }
        var next = workspace
        next.shapes += shapes.map { var copy = $0; copy.sketch = shape.sketch; return copy }
        let text = "Offset \(shapeName) by \(Self.mm(distance)) mm\(bothSides ? " both ways" : "")"
        try keep(next, change: text, focus: shape.sketch.map { .sketch($0) })
        return text + "; regions now: " + (workspace.sketch(shape.sketch).map(regions(of:)) ?? []).enumerated()
            .map { "\($0.offset + 1) \(regionDescription($0.element))" }.joined(separator: "; ") + "."
    }

    /// Names a body, sketch, or construction plane (an empty name goes back to its number).
    @discardableResult mutating func rename(item name: String, to newName: String) throws -> String {
        let next: Workspace?
        if let group = group(named: name) {
            next = workspace.renaming(group: group, to: newName)
        } else {
            switch try item(named: name) {
            case .body(let id): next = workspace.renaming(body: id, to: newName)
            case .sketch(let id): next = workspace.renaming(sketch: id, to: newName)
            case .plane(let id): next = workspace.renaming(plane: id, to: newName)
            case .shape: throw Failure("Shapes keep their numbered names; rename their sketch instead.")
            }
        }
        guard let next else { throw Failure("That item no longer exists.") }
        let text = "Renamed \(name) to \(ItemNames.cleaned(newName) ?? "its number")"
        try keep(next, change: text)
        return text + ". Use the new name from now on."
    }

    // MARK: Groups

    /// A group by its name: "Group 01", "group 1", or the name it was given.
    func group(named raw: String) -> UUID? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = workspace.groupNames
        if let found = names.first(where: { $0.value.lowercased() == text }) { return found.key }
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard compact.hasPrefix("group"), let number = Int(compact.dropFirst(5)), workspace.groups.indices.contains(number - 1) else { return nil }
        // "Group 3" is the third group only while it has no name of its own.
        let group = workspace.groups[number - 1]
        return group.name == nil ? group.id : nil
    }

    /// "Group 01 (hidden, inside Group 02): Body 01, Sketch 03".
    func groupDescription(_ group: ItemGroup) -> String {
        let names = workspace.groupNames
        var notes: [String] = []
        if group.isHidden { notes.append("hidden, with everything in it") }
        if let parent = group.parent { notes.append("inside \(names[parent] ?? "a group")") }
        let members = workspace.members(of: group.id).map { member -> String in
            switch member {
            case .body(let id): bodyName(id)
            case .sketch(let id): name(of: .sketch(id))
            case .plane(let id): name(of: .plane(id))
            case .group(let id): names[id] ?? "a group"
            }
        }
        return "\(names[group.id] ?? "Group")\(notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"): " +
            (members.isEmpty ? "empty" : members.joined(separator: ", "))
    }

    private func member(named name: String) throws -> GroupMember {
        if let group = group(named: name) { return .group(group) }
        switch try item(named: name) {
        case .body(let id): return .body(id)
        case .sketch(let id): return .sketch(id)
        case .plane(let id): return .plane(id)
        case .shape(let id):
            guard let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch else { throw Failure("That shape no longer exists.") }
            return .sketch(sketch)
        }
    }

    /// Puts solids, sketches, planes, or groups into a group: `group` names an existing one, or
    /// else a new group is made (named `newName` when given). An empty `group` of "none" or "top"
    /// takes them out of their groups.
    @discardableResult mutating func group(items names: [String], into target: String?, newName: String?) throws -> String {
        let members = try expandingSelection(names).map(member(named:))
        guard !members.isEmpty else { throw Failure("Name the items to group.") }
        let labels = names.joined(separator: ", ")
        let text = target?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let next: Workspace?, destination: String
        if ["none", "top", "root", "no group", "ungrouped"].contains(text) {
            next = workspace.moving(members, into: nil)
            destination = "out of their groups"
        } else if !text.isEmpty {
            guard let group = group(named: text) else {
                throw Failure("There is no group called \(target ?? ""). Groups: \(workspace.groupNames.values.sorted().joined(separator: ", ")).")
            }
            next = workspace.moving(members, into: group)
            destination = "into \(workspace.groupNames[group] ?? "the group")"
        } else {
            guard let made = workspace.addingGroup(containing: members, name: newName) else { throw Failure("Those items cannot be grouped.") }
            next = made.workspace
            destination = "into a new group, \(made.workspace.groupNames[made.group] ?? "Group")"
        }
        guard let next else { throw Failure("A group cannot go inside itself.") }
        let change = "Moved \(labels) \(destination)"
        try keep(next, change: change)
        return change + "."
    }

    /// Removes a group, keeping its contents (they move up to where the group was).
    @discardableResult mutating func ungroup(_ name: String) throws -> String {
        guard let group = group(named: name), let next = workspace.ungrouping(group) else { throw Failure("There is no group called \(name).") }
        let change = "Ungrouped \(workspace.groupNames[group] ?? name)"
        try keep(next, change: change)
        return change + "; its contents stay."
    }

    /// Gives a body a color (for multicolor prints); gray is the default.
    @discardableResult mutating func setColor(body bodyName: String, color raw: String) throws -> String {
        guard let color = BodyColor(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces)) else {
            throw Failure("Colors are " + BodyColor.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        // "selected" with several solids picked colors them all.
        let ids = try expandingSelection([bodyName]).map { try body(named: $0).id }
        var next = workspace
        for id in ids {
            guard let index = next.bodies.firstIndex(where: { $0.id == id }) else { throw Failure("That body no longer exists.") }
            next.bodies[index].color = color == .gray ? nil : color
        }
        let text = "Colored \(ids.map(self.bodyName).joined(separator: ", ")) \(color.rawValue)"
        try keep(next, change: text, focus: ids.first.map { .body($0) })
        return text + "."
    }

    /// A target and the tools to combine with it. With several solids picked, "selected" as the
    /// target is the first picked, and "selected" among the tools is the rest.
    private func targetAndTools(_ targetName: String, _ toolNames: [String]) throws -> (target: SolidBody, tools: [SolidBody]) {
        let target = try Self.isSelectionWord(targetName) && !pickedBodies.isEmpty ? body(named: bodyName(pickedBodies[0])) : body(named: targetName)
        let tools = try expandingSelection(toolNames).map { try body(named: $0) }.filter { $0.id != target.id }
        guard !tools.isEmpty else { throw Failure("Name at least one other solid.") }
        return (target, tools)
    }

    /// Keeps only the volume a target shares with every tool solid (Intersect).
    @discardableResult mutating func intersect(target targetName: String, tools toolNames: [String], keepTools: Bool) throws -> String {
        let (target, tools) = try targetAndTools(targetName, toolNames)
        var next = workspace
        guard let index = next.bodies.firstIndex(where: { $0.id == target.id }) else { throw Failure("That body no longer exists.") }
        guard let result = Intersecting.intersect(target, with: tools) else {
            throw Failure("Those solids do not all overlap \(bodyName(target.id)), so nothing would be left.")
        }
        next.bodies[index] = result
        let ids = tools.map(\.id)
        let text = "Intersected \(bodyName(target.id)) with \(ids.map(bodyName).joined(separator: ", "))"
        if !keepTools { next.bodies.removeAll { ids.contains($0.id) } }
        try keep(next, change: text, checking: [target.id], focus: .body(target.id))
        return text + (keepTools ? "; the other solids were kept." : ".") + " Names of later items may shift."
    }

    /// A world plane, construction plane, or solid face as a plane.
    func plane(_ spec: String, face faceSpec: String?) throws -> (plane: SketchPlane, reference: PlaneReference, label: String) {
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        if let world = SketchPlane.allCases.first(where: { $0.worldName == text }) { return (world, .world(world), world.title) }
        switch try item(named: spec) {
        case .plane(let id):
            guard let plane = workspace.constructionPlanes.first(where: { $0.id == id }) else { throw Failure("That plane no longer exists.") }
            return (plane.plane, .construction(plane), name(of: .plane(id)))
        case .body(let id):
            guard let body = workspace.bodies.first(where: { $0.id == id }) else { throw Failure("That body no longer exists.") }
            let index = try face(faceSpec ?? "selected", of: body)
            guard let reference = PlaneReference.face(index, of: body), let plane = SketchPlane.through(reference.origin, normal: reference.normal) else {
                throw Failure("Face \(index) of \(bodyName(id)) is curved.")
            }
            return (plane, reference, "\(bodyName(id)) face \(index)")
        case .sketch(let id):
            guard let sketch = workspace.sketch(id) else { throw Failure("That sketch no longer exists.") }
            return (sketch.plane, PlaneReference(source: .world(sketch.plane), origin: sketch.plane.origin, normal: sketch.plane.normalAxis, outline: []), name(of: .sketch(id)))
        case .shape: throw Failure("Use a plane name (top, front, right, Plane 01) or a solid with a face.")
        }
    }

    /// Reflects solids and sketches across a plane.
    @discardableResult mutating func mirror(items names: [String], across planeName: String, face: String?, keepOriginals: Bool) throws -> String {
        let names = expandingSelection(names)
        let (plane, _, label) = try plane(planeName, face: face)
        var bodies: [UUID] = [], sketches: [UUID] = []
        for name in names {
            switch try item(named: name) {
            case .body(let id): bodies.append(id)
            case .sketch(let id): sketches.append(id)
            case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { sketches.append(sketch) }
            case .plane: throw Failure("Construction planes cannot be mirrored.")
            }
        }
        guard let result = Mirroring.mirror(workspace, bodies: bodies, sketches: sketches, across: plane, keepOriginals: keepOriginals) else {
            throw Failure("Those items cannot be mirrored across \(label).")
        }
        let text = "Mirrored \(names.joined(separator: ", ")) across \(label)\(keepOriginals ? ", keeping the originals" : "")"
        try keep(result.workspace, change: text, checking: result.bodies, focus: result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) })
        return text + "."
    }

    /// The solids and sketches a list of names stands for (a shape stands for its sketch).
    private func patternItems(_ names: [String]) throws -> (bodies: [UUID], sketches: [UUID]) {
        guard !names.isEmpty else { throw Failure("Name the items to pattern.") }
        var bodies: [UUID] = [], sketches: [UUID] = []
        for name in expandingSelection(names) {
            switch try item(named: name) {
            case .body(let id): bodies.append(id)
            case .sketch(let id): sketches.append(id)
            case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch, !sketches.contains(sketch) { sketches.append(sketch) }
            case .plane: throw Failure("Construction planes cannot be patterned.")
            }
        }
        return (bodies, sketches)
    }

    private mutating func keepPattern(_ names: [String], items: (bodies: [UUID], sketches: [UUID]), spec: PatternSpec, describing layout: String) throws -> String {
        guard spec.instanceCount <= PatternSpec.maximumInstances else { throw Failure("A pattern makes at most \(PatternSpec.maximumInstances) instances.") }
        guard let result = Patterning.pattern(workspace, bodies: items.bodies, sketches: items.sketches, spec: spec) else {
            throw Failure("Those items cannot be patterned that way.")
        }
        let copies = result.bodies.count + result.sketches.count
        let text = "Patterned \(names.joined(separator: ", ")) \(layout): \(copies) \(copies == 1 ? "copy" : "copies")"
        try keep(result.workspace, change: text, checking: result.bodies, focus: result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) })
        return text + "."
    }

    /// Copies solids and sketches in rows along world directions (a grid with two or three):
    /// each row's instances count the original, `spacing` mm apart.
    @discardableResult mutating func linearPattern(items names: [String], rows: [(direction: String, count: Int, spacing: Double)]) throws -> String {
        let items = try patternItems(names)
        guard (1...3).contains(rows.count) else { throw Failure("Give one to three directions.") }
        var spec = PatternSpec(center: .zero, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
        spec.definition = .spacing
        var layout: [String] = []
        spec.directions = try rows.map { row in
            let key = row.direction.lowercased().trimmingCharacters(in: .whitespaces)
            guard let axis = Self.sideDirections[key] ?? Self.sideDirections["+" + key] else { throw Failure("Directions are x, y, z, -x, -y, or -z.") }
            guard PatternSpec.countRange.contains(row.count) else { throw Failure("Each count is 2–\(PatternSpec.maximumInstances), the original included.") }
            guard row.spacing.isFinite, abs(row.spacing) >= 0.01, abs(row.spacing) <= 10_000 else { throw Failure("Spacing must be 0.01–10000 mm.") }
            layout.append("\(row.count) along \(Self.direction(axis)), \(Self.mm(row.spacing)) mm apart")
            return PatternSpec.Direction(axis: axis, count: row.count, distance: row.spacing)
        }
        return try keepPattern(names, items: items, spec: spec, describing: layout.joined(separator: " by "))
    }

    /// Copies solids and sketches round a world axis through `center`: `count` instances (the
    /// original included) across `angle` degrees (a whole turn spaces them evenly round it).
    @discardableResult mutating func circularPattern(items names: [String], axis axisName: String, center: SIMD3<Double>, count: Int, angle: Double,
                                                     rotateCopies: Bool) throws -> String {
        let items = try patternItems(names)
        let axes: [String: SIMD3<Double>] = ["x": [1, 0, 0], "y": [0, 1, 0], "z": [0, 0, 1]]
        guard let axis = axes[axisName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " +"))] else { throw Failure("The axis must be x, y, or z.") }
        guard PatternSpec.countRange.contains(count) else { throw Failure("Count is 2–\(PatternSpec.maximumInstances), the original included.") }
        guard angle.isFinite, abs(angle) >= 0.1, abs(angle) <= 360 else { throw Failure("The angle must be 0.1–360 degrees.") }
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { throw Failure("Invalid center.") }
        var spec = PatternSpec(center: center, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), axis])
        spec.kind = .circular
        spec.count = count
        spec.angle = angle
        spec.orientation = rotateCopies ? .rotated : .uniform
        return try keepPattern(names, items: items, spec: spec,
                               describing: "\(count) round \(axisName.uppercased()) through \(Self.point(center)) across \(Self.mm(angle))°\(rotateCopies ? "" : ", keeping their orientation")")
    }

    /// Adds a construction plane parallel to a world plane, construction plane, or flat face.
    /// Leans faces of a body (`faces`: names or numbers) by `angle` degrees from its flat face
    /// `from`, which stays put (the pull runs into the body from it); negative leans outward.
    @discardableResult mutating func draft(body bodyName: String, faces specs: [String], from neutralSpec: String, angle: Double) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body), name = self.bodyName(body.id)
        let neutral = try face(neutralSpec, of: body)
        guard let plane = solid.facePlane(neutral), let center = solid.faceCenter(neutral) else { throw Failure("Draft leans faces from a flat face.") }
        guard DraftSpec.angleRange.contains(abs(angle)) else { throw Failure("The draft angle is 0.01–60° (negative leans outward).") }
        let points = try specs.map { spec -> SIMD3<Double> in
            let index = try face(spec, of: body)
            guard let point = solid.faceCenter(index) else { throw Failure("Face \(spec) of \(name) cannot be found.") }
            return point
        }
        guard !points.isEmpty, let drafted = Drafting.drafting(body, faces: points, pull: -plane.normal, origin: center, angle: angle),
              let index = workspace.bodies.firstIndex(where: { $0.id == body.id }) else {
            throw Failure("Those faces of \(name) cannot lean \(Self.mm(angle))° from that face; a face square to it cannot be drafted.")
        }
        var next = workspace
        next.bodies[index] = drafted
        let change = "Drafted \(specs.count) face\(specs.count == 1 ? "" : "s") of \(name) \(Self.mm(angle))° from its \(neutralSpec) face"
        try keep(next, change: change, checking: [body.id], focus: .body(body.id))
        return change + "."
    }

    /// A rib from a sketch line (by name, such as Line 03) to whichever solid it meets, `thickness` thick.
    @discardableResult mutating func rib(line lineName: String, thickness: Double) throws -> String {
        guard case .shape(let id) = try item(named: lineName), let line = workspace.shapes.first(where: { $0.id == id }), line.kind == .line else {
            throw Failure("A rib grows from a sketch line; name one such as Line 01.")
        }
        guard RibSpec.thicknessRange.contains(thickness) else { throw Failure("A rib is 0.1–100 mm thick.") }
        let a = line.plane.point(line.start), b = line.plane.point(line.end)
        // Hidden solids are left alone, as by the Rib tool on the canvas.
        for index in workspace.bodies.indices where !workspace.isHidden(workspace.bodies[index]) {
            guard let ribbed = Ribs.ribbing(workspace.bodies[index], from: a, to: b, normal: line.plane.normalAxis, thickness: thickness) else { continue }
            var next = workspace
            next.bodies[index] = ribbed
            let change = "Added a \(Self.mm(thickness)) mm rib from \(lineName) to \(bodyName(ribbed.id))"
            try keep(next, change: change, checking: [ribbed.id], focus: .body(ribbed.id))
            return change + "."
        }
        throw Failure("\(lineName) meets no solid on either side; draw it across a corner, on a plane through the solid.")
    }

    /// A loft through the first region of each sketch, in order (`ruled`: flat sides).
    @discardableResult mutating func loft(sketches names: [String], ruled: Bool) throws -> String {
        let regions = try names.map { name -> SketchProfile in
            guard case .sketch(let id) = try item(named: name), let sketch = workspace.sketch(id),
                  let region = workspace.profiles(in: sketch).first(where: \.isSolidProfile) else { throw Failure("\(name) has no closed region.") }
            return region
        }
        let solid: KernelSolid
        do { solid = try ShapedSolids.loft(regions, ruled: ruled) } catch { throw Failure("Those regions cannot be lofted; use regions one above another, facing the same way.") }
        guard let added = ShapedSolids.adding(solid, named: "Loft", to: workspace) else { throw Failure("The loft could not be saved.") }
        let change = "Lofted \(names.joined(separator: " → ")) into \(added.workspace.bodyNames[added.body] ?? "a loft")"
        try keep(added.workspace, change: change, checking: [added.body], focus: .body(added.body))
        return change + "."
    }

    /// Sweeps the first region of `sketch` along the sketch line, arc, or spline `path` (by name).
    @discardableResult mutating func sweep(sketch sketchName: String, path pathName: String) throws -> String {
        guard case .sketch(let id) = try item(named: sketchName), let sketch = workspace.sketch(id),
              let region = workspace.profiles(in: sketch).first(where: \.isSolidProfile) else { throw Failure("\(sketchName) has no closed region.") }
        guard case .shape(let pathID) = try item(named: pathName), let shape = workspace.shapes.first(where: { $0.id == pathID }),
              let path = ShapedSolids.chain(from: shape, in: workspace.shapes) else { throw Failure("The path is a sketch line, arc, or spline, such as Line 02.") }
        let solid: KernelSolid
        do { solid = try ShapedSolids.sweep(region, along: path.points, smooth: path.smooth) } catch {
            throw Failure("\(sketchName) cannot follow \(pathName); start the path at the region, across it, with bends wider than it.")
        }
        guard let added = ShapedSolids.adding(solid, named: "Sweep", to: workspace) else { throw Failure("The sweep could not be saved.") }
        let change = "Swept \(sketchName) along \(pathName) into \(added.workspace.bodyNames[added.body] ?? "a sweep")"
        try keep(added.workspace, change: change, checking: [added.body], focus: .body(added.body))
        return change + "."
    }

    /// A construction plane through three world points, or a construction axis from one point to
    /// another (a sketch named Axis 01 … holding one construction line).
    @discardableResult mutating func addConstruction(kind: String, points: [SIMD3<Double>]) throws -> String {
        switch kind.trimmingCharacters(in: .whitespaces).lowercased() {
        case "plane", "three points", "3 points":
            guard points.count == 3 else { throw Failure("A plane through points takes three points.") }
            guard let plane = ConstructionPlanes.through(points[0], points[1], points[2]) else { throw Failure("Those points are in a line.") }
            var next = workspace
            next.constructionPlanes.append(plane)
            let name = next.planeNames[plane.id] ?? "a plane"
            let change = "Added \(name) through \(points.map(Self.point).joined(separator: ", "))"
            try keep(next, change: change, focus: .plane(plane.id))
            return change + "."
        case "axis":
            guard points.count == 2 else { throw Failure("An axis takes two points.") }
            guard let result = ConstructionAxes.adding(from: points[0], to: points[1], in: workspace) else { throw Failure("The two points are the same.") }
            let name = result.workspace.sketchNames[result.sketch] ?? "an axis"
            let change = "Added \(name), a construction axis from \(Self.point(points[0])) to \(Self.point(points[1]))"
            try keep(result.workspace, change: change, focus: .sketch(result.sketch))
            return change + "."
        default:
            throw Failure("Choose plane (three points) or axis (two points).")
        }
    }

    /// A construction plane through a sketch line, turned `degrees` about it: 0° lies on the line's
    /// sketch plane, 90° stands straight up from it (Plane at Angle).
    @discardableResult mutating func addPlaneAtAngle(line lineName: String, degrees: Double) throws -> String {
        guard case .shape(let id) = try item(named: lineName), let line = workspace.shapes.first(where: { $0.id == id }), line.kind == .line else {
            throw Failure("A plane at an angle turns about a sketch line; name one such as Line 01.")
        }
        guard degrees.isFinite, abs(degrees) <= 360 else { throw Failure("The angle must be within ±360°.") }
        let a = line.plane.point(line.start), b = line.plane.point(line.end)
        guard let plane = ConstructionPlanes.atAngle(through: (a + b) / 2, along: b - a, length: simd_distance(a, b),
                                                     reference: line.plane.normalAxis, degrees: degrees) else {
            throw Failure("A plane cannot be made about \(lineName).")
        }
        var next = workspace
        next.constructionPlanes.append(plane)
        let name = next.planeNames[plane.id] ?? "a plane"
        let change = "Added \(name), turned \(Self.mm(degrees))° about \(lineName)"
        try keep(next, change: change, focus: .plane(plane.id))
        return change + ". Sketch on it with on: \"\(name)\"."
    }

    /// A construction plane touching a solid's round face along a line, on the `side` it faces
    /// (top, bottom, front, back, left, right, or ±x/±y/±z): Tangent Plane.
    @discardableResult mutating func addTangentPlane(body bodyName: String, face spec: String, side: String) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body)
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        let face = ["round", "side", "curved", "cylinder", "round face", "curved face"].contains(text)
            ? (0..<solid.faceCount).first { solid.faceCylinder($0) != nil }
            : try self.face(spec, of: body)
        guard let face, let cylinder = solid.faceCylinder(face) else { throw Failure("\(self.bodyName(body.id)) has no round face there; name a cylinder's side or a hole's wall.") }
        guard let direction = Self.sideDirections[side.trimmingCharacters(in: .whitespaces).lowercased()] else {
            throw Failure("Side must be top, bottom, front, back, left, right, or ±x, ±y, ±z.")
        }
        let axis = simd_normalize(cylinder.direction)
        let radial = direction - axis * simd_dot(direction, axis)
        guard simd_length(radial) > 1e-6 else { throw Failure("The \(side) side runs along the face's axis; choose a side across it.") }
        // Halfway along the face, on the chosen side.
        let heights = solid.faceEdges(face).flatMap { solid.edgeSamples($0, count: 9) }.map { simd_dot($0 - cylinder.point, axis) }
        let low = heights.min() ?? -10, high = heights.max() ?? 10
        let point = cylinder.point + axis * ((low + high) / 2) + simd_normalize(radial) * cylinder.radius
        guard let plane = ConstructionPlanes.tangent(toCylinderAt: cylinder.point, axisDirection: axis, radius: cylinder.radius,
                                                     through: point, height: high - low) else { throw Failure("A plane cannot touch that face.") }
        var next = workspace
        next.constructionPlanes.append(plane)
        let name = next.planeNames[plane.id] ?? "a plane"
        let change = "Added \(name), touching the \(side) of \(self.bodyName(body.id))'s round face (Ø\(Self.mm(2 * cylinder.radius)) mm)"
        try keep(next, change: change, focus: .plane(plane.id))
        return change + ". Sketch on it with on: \"\(name)\"."
    }

    /// Carries a sketch line's end (`start`, `end`, or both when nil) on, straight, to the next shape
    /// on its plane (Extend).
    @discardableResult mutating func extendLine(_ lineName: String, end: String?) throws -> String {
        guard case .shape(let id) = try item(named: lineName), let line = workspace.shapes.first(where: { $0.id == id }), line.kind == .line else {
            throw Failure("Extend carries a sketch line on; name one such as Line 01.")
        }
        let ends: [(label: String, point: Point2)]
        switch end?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "start", "first": ends = [("start", line.start)]
        case "end", "last": ends = [("end", line.end)]
        case nil, "", "both": ends = [("end", line.end), ("start", line.start)]
        default: throw Failure("End must be start, end, or both.")
        }
        var next = workspace, moved: [String] = []
        for (label, point) in ends {
            if let extended = SketchTools.extend(id, near: point, in: next) { next = extended; moved.append(label) }
        }
        guard !moved.isEmpty else { throw Failure("Nothing on \(lineName)'s plane lies ahead of it to extend to.") }
        let change = "Extended \(lineName) at its \(moved.joined(separator: " and "))"
        try keep(next, change: change, focus: line.sketch.map { .sketch($0) })
        return change + "."
    }

    /// Screw Lid: a container's round neck gets a raised printable thread, and a lid is added
    /// already screwed on. `face` is "boss" (the first round boss), a face number, or selected.
    @discardableResult mutating func screwLid(body bodyName: String, face spec: String, pitch: Double?, starts: Int?, turns: Double?,
                                              top: Double?, height: Double?, ribbed: Bool?, clearance: Double, testPrint: Bool = false) throws -> String {
        let body = try body(named: bodyName), solid = try buildable(body)
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        let index: Int
        if ["boss", "neck", "round", "outside"].contains(text) {
            guard let found = (0..<solid.faceCount).first(where: { ssk_face_cylinder_side(solid.handle, Int32($0)) == 1 }) else {
                throw Failure("\(self.bodyName(body.id)) has no round neck for a lid.")
            }
            index = found
        } else {
            index = try face(spec, of: body)
        }
        var lidSpec = ScrewLidSpec(clearance: clearance)
        if let pitch { lidSpec.pitch = pitch }
        if let starts { lidSpec.starts = starts }
        if let turns { lidSpec.turns = turns }
        if let top { lidSpec.top = top }
        lidSpec.height = height
        if let ribbed { lidSpec.ribbed = ribbed }
        if testPrint { return try screwLidFitTest(body, face: index, lidSpec) }
        let made: ScrewLid.Result
        do { made = try ScrewLid.make(on: body, face: index, lidSpec) } catch let error as ScrewLid.Failure { throw Failure(error.message) }
        var next = workspace
        guard let bodyIndex = next.bodies.firstIndex(where: { $0.id == body.id }) else { throw Failure("That body no longer exists.") }
        next.bodies[bodyIndex] = made.jar
        var lid = made.lid
        lid.name = "Lid"
        next.bodies.append(lid)
        let change = "Threaded the neck of \(self.bodyName(body.id)) (\(made.thread.title), closing in \(Self.mm(lidSpec.turns)) turns) and added a \(lidSpec.ribbed ? "ribbed" : "smooth") lid screwed onto it"
        try keep(next, change: change, checking: [made.jar.id, lid.id], focus: .body(lid.id))
        return change + "."
    }

    /// The thread fit test for a neck: a ring with its thread and three collars, beside the model.
    private mutating func screwLidFitTest(_ body: SolidBody, face: Int, _ spec: ScrewLidSpec) throws -> String {
        let test: ScrewLid.TestPrint
        do { test = try ScrewLid.fitTest(on: body, face: face, spec, at: FitTest.origin(beside: workspace)) } catch let error as ScrewLid.Failure { throw Failure(error.message) }
        let (group, bodies) = test.parts
        var next = workspace
        next.groups.append(group)
        next.bodies += bodies
        let clearances = test.collars.map { Self.mm($0.clearance) }.joined(separator: ", ")
        let change = "Added a thread fit test for \(bodyName(body.id))'s neck: a ring with its thread and collars at \(clearances) mm clearance (one, two, and three notches)"
        try keep(next, change: change, checking: bodies.map(\.id), focus: .body(bodies[0].id))
        return change + ". Print them; the collar that turns on smoothly without wobbling gives the clearance to set as Fit Clearance in the project menu."
    }

    @discardableResult mutating func addPlane(from planeName: String, face: String?, offset: Double) throws -> String {
        let (_, reference, label) = try plane(planeName, face: face)
        guard offset.isFinite, abs(offset) <= 10_000 else { throw Failure("Offset must be within ±10000 mm.") }
        guard let plane = ConstructionPlanes.offset(from: reference, by: offset) else { throw Failure("A plane cannot be made there.") }
        var next = workspace
        next.constructionPlanes.append(plane)
        var preview = self; preview.workspace = next
        let name = preview.name(of: .plane(plane.id))
        try keep(next, change: "Added \(name), \(Self.mm(offset)) mm from \(label)")
        return "Added \(name), \(Self.mm(offset)) mm from \(label), facing \(Self.direction(plane.plane.normalAxis)) through \(Self.point(plane.plane.origin)). Sketch on it with on: \"\(name)\"."
    }

    /// Revolves a sketch region about a world axis or one of the sketch's lines. Sketch "selected"
    /// with no region revolves every selected region and sketch together.
    @discardableResult mutating func revolve(sketch sketchName: String, region number: Int?, axis axisName: String, angle: Double, mode: ExtrudeMode) throws -> String {
        let picked = Self.isSelectionWord(sketchName) && number == nil ? selectedRegions() : []
        let profiles: [SketchProfile], name: String, plane: SketchPlane
        if let first = picked.first {
            profiles = picked; plane = first.plane
            name = "the \(picked.count) selected region\(picked.count == 1 ? "" : "s")"
        } else {
            let sketch = try sketch(named: sketchName)
            let regions = regions(of: sketch)
            name = self.name(of: .sketch(sketch.id)); plane = sketch.plane
            guard !regions.isEmpty else { throw Failure("\(name) has no closed regions.") }
            if let number {
                guard regions.indices.contains(number - 1) else { throw Failure("\(name) has regions 1…\(regions.count).") }
                profiles = [regions[number - 1]]
            } else {
                guard regions.count == 1 else { throw Failure("\(name) has \(regions.count) regions; say which.") }
                profiles = regions
            }
        }
        let profile = profiles[0]
        guard RevolveSpec.angleRange.contains(abs(angle)) else { throw Failure("Angle must be 0.1–360°.") }
        let from: Point2, to: Point2
        let worldAxes: [String: SIMD3<Double>] = ["x": [1, 0, 0], "y": [0, 1, 0], "z": [0, 0, 1]]
        if let direction = worldAxes[axisName.lowercased().replacingOccurrences(of: " axis", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " +"))] {
            from = plane.coordinates(of: .zero)
            to = plane.coordinates(of: direction * 10)
            guard from.distance(to: to) > 1 else { throw Failure("The \(axisName.uppercased()) axis is not in \(name)'s plane.") }
            guard abs(plane.height(of: .zero)) < 1e-6, abs(simd_dot(direction, plane.normalAxis)) < 1e-6 else {
                throw Failure("The \(axisName.uppercased()) axis does not lie in \(name)'s plane; use a line of the sketch as the axis.")
            }
        } else if case .shape(let id) = try item(named: axisName), let line = workspace.shapes.first(where: { $0.id == id }), line.kind == .line {
            guard line.plane == plane else { throw Failure("That line is on another plane.") }
            from = line.start; to = line.end
        } else {
            throw Failure("The axis must be x, y, z, or a line of the sketch.")
        }
        let spec = RevolveSpec.oriented(from: from, to: to, angle: angle, for: profile)
        guard profiles.allSatisfy(spec.allows) else {
            throw Failure(profiles.count == 1 ? "The axis crosses that region; it must lie to one side." : "The axis crosses one of the regions; it must lie beside all of them.")
        }
        var next = workspace, made: [String] = [], checked: [UUID] = [], focus: AssistantItem?
        for profile in profiles {
            var cut = ExtrusionCut(profile: profile, depth: 1), join = ExtrusionCut(profile: profile, depth: 1, operation: .join)
            cut.revolve = spec; join.revolve = spec
            switch place(cut: cut, join: join, mode: mode, in: next) {
            case .cut(let ws, let targets): next = ws; checked += targets; made.append("cut \(targets.map(bodyName).joined(separator: ", "))"); focus = .body(targets[0])
            case .join(let ws, let target): next = ws; checked.append(target); made.append("joined to \(bodyName(target))"); focus = .body(target)
            case .newBody:
                let body = SolidBody(profile: profile, revolve: spec)
                guard body.isValid else { throw Failure("That region cannot be revolved about that axis.") }
                next.bodies.append(body); checked.append(body.id); focus = .body(body.id)
                var preview = self; preview.workspace = next
                made.append("new solid \(preview.bodyName(body.id))")
            case .failed(let reason): throw Failure(reason)
            }
        }
        try keep(next, change: "Revolved \(name) \(Self.mm(angle))° about \(axisName): \(made.joined(separator: "; "))", checking: checked, focus: focus)
        return "Revolved \(name) \(Self.mm(angle))°: \(made.joined(separator: "; "))."
    }
}
