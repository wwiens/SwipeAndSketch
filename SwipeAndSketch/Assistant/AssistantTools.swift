import Foundation
import FoundationModels
import simd

// The assistant's tools: thin Foundation Models wrappers over AssistantWorkbench (Core). Each
// tool runs on the main actor against the current request's draft. A refused change comes back
// to the model as "Error: …" text rather than a thrown error, so it can correct itself and retry.

/// The draft the tools of one conversation work on. Reset at the start of every request.
@MainActor final class AssistantContext {
    private(set) var bench = AssistantWorkbench(workspace: Workspace())
    /// Called with a short line ("Extruding Sketch 01…") as each tool starts.
    var onActivity: ((String) -> Void)?
    /// Called with each tool's result (for evaluation logs).
    var onResult: ((String) -> Void)?
    /// Tool calls this request, and how often each failure has come back: a model that keeps
    /// repeating a failing call is told to stop instead of filling its context.
    private var calls = 0
    private var failures: [String: Int] = [:]
    static let maximumCalls = 16

    /// Takes over a workbench the planner changed.
    func adopt(_ bench: AssistantWorkbench) { self.bench = bench }

    func reset(workspace: Workspace, selection: AssistantSelection?) {
        bench = AssistantWorkbench(workspace: workspace, selection: selection)
        calls = 0
        failures = [:]
    }

    /// Runs one change or query; failures become text the model can act on.
    func run(_ activity: String, _ body: (inout AssistantWorkbench) throws -> String) -> String {
        calls += 1
        guard calls <= Self.maximumCalls else {
            return "Error: Too many steps for one request. Stop now and tell the user what was done and what is left."
        }
        onActivity?(activity)
        let result: String
        do { result = try body(&bench) } catch let failure as AssistantWorkbench.Failure {
            failures[failure.message, default: 0] += 1
            result = failures[failure.message]! > 2
                ? "Error: \(failure.message) This has failed repeatedly; do not try it again. Explain the problem to the user."
                : "Error: \(failure.message)"
        } catch {
            result = "Error: \(error.localizedDescription)"
        }
        onResult?(result)
        return result
    }
}

private extension AssistantWorkbench.ExtrudeMode {
    init(_ text: String?) {
        switch text?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "new body", "new", "newbody", "body", "new solid": self = .newBody
        case "join", "add", "boss", "union": self = .join
        case "cut", "subtract", "remove", "pocket", "hole": self = .cut
        default: self = .auto
        }
    }
}

private func point(_ x: Double?, _ y: Double?, _ z: Double?) -> SIMD3<Double> { SIMD3(x ?? 0, y ?? 0, z ?? 0) }

struct InspectItemTool: Tool {
    let context: AssistantContext
    let name = "inspect_item"
    let description = "Details of one item: a body's numbered faces and edges with positions, a sketch's shapes and regions, or a plane."
    @Generable struct Arguments {
        @Guide(description: "Item name from the model summary, e.g. Body 01, Sketch 02, Plane 01, or selected")
        var item: String
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Looking at \(arguments.item)") { bench in
            switch try bench.item(named: arguments.item) {
            case .body(let id):
                guard let body = bench.workspace.bodies.first(where: { $0.id == id }) else { throw AssistantWorkbench.Failure("Not found.") }
                return try bench.inspect(body)
            case .sketch(let id):
                guard let sketch = bench.workspace.sketch(id) else { throw AssistantWorkbench.Failure("Not found.") }
                let shapes = bench.workspace.shapes(in: id).map { "\(bench.name(of: .shape($0.id))) \(bench.shapeDescription($0))" }
                let regions = bench.regions(of: sketch).enumerated().map { "region \($0.offset + 1): \(bench.regionDescription($0.element))" }
                let plane = sketch.plane
                return (["\(bench.name(of: .sketch(id))) on \(bench.planeDescription(plane)); u axis \(AssistantWorkbench.direction(plane.xAxis)), v axis \(AssistantWorkbench.direction(plane.yAxis)), normal \(AssistantWorkbench.direction(plane.normalAxis))"]
                        + shapes + (regions.isEmpty ? ["No closed regions."] : regions)).joined(separator: "\n")
            case .shape(let id):
                guard let shape = bench.workspace.shapes.first(where: { $0.id == id }) else { throw AssistantWorkbench.Failure("Not found.") }
                return "\(bench.name(of: .shape(id))) in \(shape.sketch.map { bench.name(of: .sketch($0)) } ?? "no sketch"): \(bench.shapeDescription(shape))"
            case .plane(let id):
                guard let plane = bench.workspace.constructionPlanes.first(where: { $0.id == id }) else { throw AssistantWorkbench.Failure("Not found.") }
                return "\(bench.name(of: .plane(id))): faces \(AssistantWorkbench.direction(plane.plane.normalAxis)) through \(AssistantWorkbench.point(plane.plane.origin)); u axis \(AssistantWorkbench.direction(plane.plane.xAxis)), v axis \(AssistantWorkbench.direction(plane.plane.yAxis))"
            }
        }
    }
}

struct AddSketchTool: Tool {
    let context: AssistantContext
    let name = "add_sketch"
    let description = "Draws rectangles, circles, slots (rounded-end slots), ellipses, regular polygons, arcs, lines, and points as a new sketch on a plane or flat face (or adds them to an existing sketch). Positions are world x, y, z in mm, projected onto the plane. construction: true makes a dashed reference that bounds no region (a mirror line or revolve axis)."
    @Generable struct Shape {
        @Guide(.anyOf(["rectangle", "circle", "slot", "ellipse", "polygon", "arc", "line", "point"])) var kind: String
        @Guide(description: "Center (rectangle, circle, slot) or start (line, arc), world mm") var x: Double
        var y: Double
        var z: Double
        @Guide(description: "Rectangle or slot overall size along the plane's u axis") var width: Double?
        @Guide(description: "Rectangle or slot overall size along the plane's v axis") var height: Double?
        var diameter: Double?
        @Guide(description: "Line or arc end, world mm") var endX: Double?
        var endY: Double?
        var endZ: Double?
        @Guide(description: "Arc: a point it passes through between its ends, world mm") var throughX: Double?
        var throughY: Double?
        var throughZ: Double?
        @Guide(description: "Polygon: number of sides (diameter is across its corners), e.g. 6 for a hex nut trap") var sides: Int?
        @Guide(description: "A dashed reference that makes no region") var construction: Bool?
    }
    @Generable struct Arguments {
        @Guide(description: "top, front, right, a construction plane (Plane 01), an existing sketch to add to (Sketch 02), or a body name to sketch on its face")
        var on: String
        @Guide(description: "When on is a body: the face, e.g. top, bottom, front, back, left, right, or a face number")
        var face: String?
        var shapes: [Shape]
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Sketching on \(arguments.on)") { bench in
            let target = try planeTarget(arguments.on, face: arguments.face, in: bench)
            let inputs = try arguments.shapes.map { shape -> AssistantWorkbench.ShapeInput in
                guard let kind = AssistantWorkbench.ShapeInput.Kind(rawValue: shape.kind.lowercased()) else {
                    throw AssistantWorkbench.Failure("Shapes are rectangle, circle, slot, ellipse, polygon, arc, line, or point.")
                }
                let end = shape.endX != nil || shape.endY != nil || shape.endZ != nil ? point(shape.endX, shape.endY, shape.endZ) : nil
                let through = shape.throughX != nil || shape.throughY != nil || shape.throughZ != nil ? point(shape.throughX, shape.throughY, shape.throughZ) : nil
                return .init(kind: kind, point: SIMD3(shape.x, shape.y, shape.z), width: shape.width, height: shape.height, diameter: shape.diameter, end: end,
                             through: through, sides: shape.sides, construction: shape.construction)
            }
            return try bench.addShapes(inputs, on: target)
        }
    }
}

struct SketchAndExtrudeTool: Tool {
    let context: AssistantContext
    let name = "sketch_and_extrude"
    let description = "One step for a single rectangle or circle: sketches it on a plane or a body's flat face and extrudes it. Makes boxes and cylinders, bosses (positive distance on a face), and pockets or cuts (negative distance on a face)."
    @Generable struct Arguments {
        @Guide(description: "top, front, right, Plane 01, or a body name to work on its face") var on: String
        @Guide(description: "When on is a body: top, bottom, front, back, left, right, or a face number") var face: String?
        @Guide(description: "circle for anything round (cylinders, round bosses, round pockets); rectangle for boxes, plates, and slots", .anyOf(["circle", "rectangle"]))
        var shape: String
        @Guide(description: "Center of the shape, world mm, on the plane or face") var x: Double
        var y: Double
        var z: Double
        @Guide(description: "Rectangle size along the plane's u axis (X on top and front)") var width: Double?
        @Guide(description: "Rectangle size along the plane's v axis (Y on top, Z on front)") var height: Double?
        @Guide(description: "Circle diameter in mm: the size across, as the user said it") var diameter: Double?
        @Guide(description: "Signed extrusion distance in mm (the thickness or height); on a face, positive adds material and negative cuts into it") var distance: Double
        @Guide(description: "On a plane only: join or cut an existing body it overlaps; omit for a new body", .anyOf(["new body", "join", "cut"]))
        var operation: String?
        @Guide(description: "To place a new solid beside an existing body without overlapping: that body's name (then x, y, z are ignored)")
        var nextTo: String?
        @Guide(description: "Which side of nextTo", .anyOf(["right", "left", "back", "front"])) var side: String?
        @Guide(description: "Gap from nextTo in mm (default 10)") var gap: Double?
        @Guide(description: "On a face: put the shape against that edge of the face (a wall along the back edge is on face top, flushWith back)", .anyOf(["back", "front", "left", "right"]))
        var flushWith: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Making a \(arguments.shape) on \(arguments.on)") { bench in
            let target = try planeTarget(arguments.on, face: arguments.face, in: bench)
            guard let kind = AssistantWorkbench.ShapeInput.Kind(rawValue: arguments.shape.lowercased()), kind != .line else {
                throw AssistantWorkbench.Failure("shape must be rectangle or circle.")
            }
            var point = SIMD3(arguments.x, arguments.y, arguments.z)
            if let neighbor = arguments.nextTo, !neighbor.isEmpty {
                // Beside a body on the top plane: its edge, plus half this shape's size, plus the gap.
                let body = try bench.body(named: neighbor), bounds = try SolidKernel.solid(for: body).bounds
                let halfX = (kind == .circle ? (arguments.diameter ?? arguments.width ?? 0) : (arguments.width ?? 0)) / 2
                let halfY = (kind == .circle ? (arguments.diameter ?? arguments.width ?? 0) : (arguments.height ?? arguments.width ?? 0)) / 2
                let gap = max(0, arguments.gap ?? 10), center = (bounds.min + bounds.max) / 2
                switch arguments.side?.lowercased() ?? "right" {
                case "left": point = [bounds.min.x - gap - halfX, center.y, 0]
                case "back": point = [center.x, bounds.max.y + gap + halfY, 0]
                case "front": point = [center.x, bounds.min.y - gap - halfY, 0]
                default: point = [bounds.max.x + gap + halfX, center.y, 0]
                }
            }
            if let side = arguments.flushWith?.lowercased(), case .face(let bodyID, let faceSpec) = target,
               let direction = AssistantWorkbench.sideDirections[side], let body = bench.workspace.bodies.first(where: { $0.id == bodyID }) {
                // Against an edge of the face: the shape's far side on the face's far side that way.
                let index = try bench.face(faceSpec, of: body), solid = try SolidKernel.solid(for: body)
                guard let facePlane = solid.facePlane(index), let plane = SketchPlane.through(facePlane.origin, normal: facePlane.normal),
                      let outline = solid.faceOutline(index), let faceCenter = solid.faceCenter(index) else { throw AssistantWorkbench.Failure("That face is curved.") }
                let a = kind == .circle ? (arguments.diameter ?? arguments.width ?? 0) : (arguments.width ?? 0)
                let b = kind == .circle ? a : (arguments.height ?? arguments.width ?? 0)
                let half = abs(simd_dot(plane.xAxis, direction)) * a / 2 + abs(simd_dot(plane.yAxis, direction)) * b / 2
                let reach = outline.points.map { simd_dot($0, direction) }.max() ?? simd_dot(faceCenter, direction)
                // Keep the given position across the edge; move it along `direction` to sit flush.
                let start = point == .zero ? faceCenter : point
                point = start + direction * (reach - half - simd_dot(start, direction))
            }
            var draft = bench
            let drawn = try draft.addShapes([.init(kind: kind, point: point, width: arguments.width,
                                                  height: arguments.height, diameter: arguments.diameter)], on: target)
            // The shape may join an existing sketch ("on Sketch 01"), which need not be the last one.
            let existing = Set(bench.workspace.shapes.map(\.id))
            guard let shape = draft.workspace.shapes.first(where: { !existing.contains($0.id) }),
                  let sketch = draft.workspace.sketch(shape.sketch) else { throw AssistantWorkbench.Failure("The sketch was not made.") }
            let sketchName = draft.name(of: .sketch(sketch.id))
            let regions = draft.regions(of: sketch)
            // A shape added to a busy sketch extrudes its own region.
            let region = regions.count > 1 ? (regions.firstIndex { $0.sourceIDs.contains(shape.id) || $0.id == shape.id.uuidString }.map { [$0 + 1] } ?? []) : []
            // On a face, out joins and in cuts (like pushing the face); on a plane it is a new body unless
            // asked to join or cut (an overlapping new solid must not silently cut its neighbor).
            let mode: AssistantWorkbench.ExtrudeMode
            if case .face = target { mode = arguments.distance > 0 ? .join : .cut }
            else { mode = ["join", "cut"].contains(arguments.operation?.lowercased() ?? "") ? .init(arguments.operation) : .newBody }
            let extruded = try draft.extrude(sketch: sketchName, regions: region, distance: arguments.distance, mode: mode, throughAll: false)
            bench = draft
            let done = draft.focus.map { " \(draft.name(of: $0)) is complete; do not extrude it again." } ?? ""
            return (drawn.components(separatedBy: " Regions:").first ?? drawn) + " " + extruded + done
        }
    }
}

private func planeTarget(_ on: String, face: String?, in bench: AssistantWorkbench) throws -> AssistantWorkbench.PlaneTarget {
    let text = on.lowercased().trimmingCharacters(in: .whitespaces)
    if let world = SketchPlane.allCases.first(where: { $0.worldName == text || $0.worldName.map { "\($0) plane" } == text }) { return .world(world) }
    if AssistantWorkbench.sideDirections[text.replacingOccurrences(of: " face", with: "")] != nil {
        throw AssistantWorkbench.Failure("\"\(on)\" is a face, not an item: set on to the body's name (such as \(bench.workspace.bodies.last.map { bench.bodyName($0.id) } ?? "Body 01")) and face to \(text).")
    }
    switch try bench.item(named: on) {
    case .plane(let id): return .construction(id)
    case .sketch(let id): return .sketch(id)
    case .body(let id):
        // No face named: the selected face of that body, else its top.
        if let face, !face.isEmpty { return .face(body: id, face: face) }
        if case .face(id, _)? = bench.selection { return .face(body: id, face: "selected") }
        return .face(body: id, face: "top")
    case .shape(let id):
        guard let sketch = bench.workspace.shapes.first(where: { $0.id == id })?.sketch else { throw AssistantWorkbench.Failure("No sketch.") }
        return .sketch(sketch)
    }
}

struct ExtrudeTool: Tool {
    let context: AssistantContext
    let name = "extrude"
    let description = "Extrudes sketch regions along the sketch normal. auto cuts solids it overlaps, joins solids it touches, else makes a new body. Negative distance goes the other way."
    @Generable struct Arguments {
        @Guide(description: "Sketch name, e.g. Sketch 01") var sketch: String
        @Guide(description: "Region numbers from the summary; omit when the sketch has one region") var regions: [Int]?
        @Guide(description: "Signed distance in mm") var distance: Double
        @Guide(.anyOf(["auto", "new body", "join", "cut"])) var operation: String?
        @Guide(description: "Cut through every solid in both directions") var throughAll: Bool?
        @Guide(description: "Extrude half the distance each way from the sketch plane") var symmetric: Bool?
        @Guide(description: "Draft angle of the sides in degrees, positive narrowing toward the far end (molds, easier printing); omit for straight sides")
        var taper: Double?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Extruding \(arguments.sketch)") { bench in
            try bench.extrude(sketch: arguments.sketch, regions: arguments.regions ?? [], distance: arguments.distance,
                              mode: .init(arguments.operation), throughAll: arguments.throughAll ?? false,
                              symmetric: arguments.symmetric ?? false, taper: arguments.taper ?? 0)
        }
    }
}

struct ScaleItemsTool: Tool {
    let context: AssistantContext
    let name = "scale_items"
    let description = "Scales bodies and sketches by a percentage (e.g. 150 makes them half again as big; 100.5 compensates shrinkage). Holes, threads, and pegs scale too. Bodies can be stretched with a percentage per world axis."
    @Generable struct Arguments {
        var items: [String]
        @Guide(description: "Uniform percentage") var percent: Double?
        @Guide(description: "Bodies only: percentage along world x, y, z instead") var percentX: Double?
        var percentY: Double?
        var percentZ: Double?
        @Guide(.anyOf(["center", "base", "origin"])) var about: String?
        @Guide(description: "Keep the originals and add scaled copies") var copy: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Scaling \(arguments.items.joined(separator: ", "))") { bench in
            let stretch = arguments.percentX != nil || arguments.percentY != nil || arguments.percentZ != nil
            let percents = stretch ? SIMD3(arguments.percentX ?? 100, arguments.percentY ?? 100, arguments.percentZ ?? 100) : nil
            return try bench.scale(items: arguments.items, percent: arguments.percent, percents: percents, about: arguments.about, copy: arguments.copy ?? false)
        }
    }
}

struct DeleteFacesTool: Tool {
    let context: AssistantContext
    let name = "delete_faces"
    let description = "Takes faces off a body and closes the gap: removes a fillet, chamfer, hole (its wall and floor), or boss."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "Faces: top, bottom, front, back, left, right, face numbers, or selected") var faces: [String]
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Deleting faces of \(arguments.body)") { bench in
            try bench.deleteFaces(body: arguments.body, faces: arguments.faces)
        }
    }
}

struct DeleteHoleTool: Tool {
    let context: AssistantContext
    let name = "delete_hole"
    let description = "Deletes a round hole from a body, as if it had never been made (a thread in it and fillets on its rim go too)."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "hole (the body's first), a hole wall's face number, or selected") var face: String
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Deleting a hole in \(arguments.body)") { bench in
            try bench.deleteHole(body: arguments.body, face: arguments.face)
        }
    }
}

struct EditFinishTool: Tool {
    let context: AssistantContext
    let name = "edit_fillet"
    let description = "Changes the size of a body's fillet or chamfer, or deletes it so its edges are sharp again."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "Which one: 1 for the first fillet or chamfer made, 2 for the next, or last") var which: String
        @Guide(description: "New radius (fillet) or distance (chamfer) in mm, or 0 to delete it") var size: Double
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run(arguments.size == 0 ? "Deleting a fillet of \(arguments.body)" : "Changing a fillet of \(arguments.body)") { bench in
            try bench.editFinish(body: arguments.body, which: arguments.which, size: arguments.size == 0 ? nil : arguments.size)
        }
    }
}

struct ResizeFaceTool: Tool {
    let context: AssistantContext
    let name = "resize_face"
    let description = "Changes a body's size from one face: a round face (a cylinder or hole wall) to a new diameter, or a flat face to a new distance from the parallel face behind it (width, depth, or height)."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "The face: top, bottom, front, back, left, right, a face number, or selected") var face: String
        @Guide(description: "New diameter (round face) or distance (flat face) in mm") var value: Double
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Resizing \(arguments.body)") { bench in
            try bench.resizeFace(body: arguments.body, face: arguments.face, value: arguments.value)
        }
    }
}

struct OffsetSketchTool: Tool {
    let context: AssistantContext
    let name = "offset_sketch"
    let description = "Adds an outline a distance from a sketch shape (and lines joined to it) in the same sketch: outward for positive, inward for negative; bothSides makes a wall around it."
    @Generable struct Arguments {
        @Guide(description: "A shape name such as Rectangle 01, Circle 02, or Line 03") var shape: String
        var distance: Double
        var bothSides: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Offsetting \(arguments.shape)") { bench in
            try bench.offsetShape(arguments.shape, distance: arguments.distance, bothSides: arguments.bothSides ?? false)
        }
    }
}

struct RenameItemTool: Tool {
    let context: AssistantContext
    let name = "rename_item"
    let description = "Names a body, sketch, construction plane, or group (an empty name goes back to its number)."
    @Generable struct Arguments {
        var item: String
        var name: String
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Renaming \(arguments.item)") { bench in try bench.rename(item: arguments.item, to: arguments.name) }
    }
}

struct GroupItemsTool: Tool {
    let context: AssistantContext
    let name = "group_items"
    let description = "Organizes the Model Tree: puts bodies, sketches, planes, or groups into a group (an existing one, or a new one), or takes them out of their groups. Groups can then be hidden or shown together."
    @Generable struct Arguments {
        var items: [String]
        @Guide(description: "An existing group's name; omit to make a new group; \"none\" to take the items out of their groups") var group: String?
        @Guide(description: "Name for a new group, such as Lid or Hardware") var name: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Grouping \(arguments.items.joined(separator: ", "))") { bench in
            try bench.group(items: arguments.items, into: arguments.group, newName: arguments.name)
        }
    }
}

struct UngroupTool: Tool {
    let context: AssistantContext
    let name = "ungroup"
    let description = "Removes a group from the Model Tree, keeping everything that was in it."
    @Generable struct Arguments {
        var group: String
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Ungrouping \(arguments.group)") { bench in try bench.ungroup(arguments.group) }
    }
}

struct SetColorTool: Tool {
    let context: AssistantContext
    let name = "set_color"
    let description = "Colors a body (shown on the canvas and saved in 3MF files for multicolor prints)."
    @Generable struct Arguments {
        var body: String
        @Guide(.anyOf(["gray", "white", "black", "red", "orange", "yellow", "green", "blue", "purple", "pink"])) var color: String
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Coloring \(arguments.body)") { bench in try bench.setColor(body: arguments.body, color: arguments.color) }
    }
}

struct ExtrudeFaceTool: Tool {
    let context: AssistantContext
    let name = "extrude_face"
    let description = "Pushes a body's flat face out (positive mm, adds material) or in (negative, removes material)."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "top, bottom, front, back, left, right, a face number, or selected") var face: String
        var distance: Double
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Extruding a face of \(arguments.body)") { bench in
            try bench.extrudeFace(body: arguments.body, face: arguments.face, distance: arguments.distance)
        }
    }
}

/// Edge arguments shared by fillet_edges and chamfer_edges.
@Generable struct EdgeArguments {
    var body: String
    @Guide(description: "Comma-separated: all, top, bottom, front, back, left, right, vertical, horizontal, circular, face <side>, edge numbers, or selected")
    var edges: String
    @Guide(description: "Fillet radius or chamfer distance in mm") var size: Double
}

struct FilletEdgesTool: Tool {
    let context: AssistantContext
    let name = "fillet_edges"
    let description = "Rounds edges of a body with a fillet radius."
    func call(arguments: EdgeArguments) async throws -> String {
        await context.run("Filleting \(arguments.body)") { bench in
            try bench.finish(.fillet, body: arguments.body, edges: arguments.edges, size: arguments.size)
        }
    }
}

struct ChamferEdgesTool: Tool {
    let context: AssistantContext
    let name = "chamfer_edges"
    let description = "Bevels edges of a body with a chamfer distance."
    func call(arguments: EdgeArguments) async throws -> String {
        await context.run("Chamfering \(arguments.body)") { bench in
            try bench.finish(.chamfer, body: arguments.body, edges: arguments.edges, size: arguments.size)
        }
    }
}

struct ShellTool: Tool {
    let context: AssistantContext
    // Named for the result: the cloud model's output guardrails stop calls to tools named
    // "shell" or "hollow_body".
    let name = "make_container"
    let description = "Turns a solid into a container with walls of a given thickness (a CAD shell), leaving one or more faces open."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "Faces to leave open, e.g. [\"top\"]") var openFaces: [String]
        @Guide(description: "Wall thickness in mm, 0.2–100") var thickness: Double
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Shelling \(arguments.body)") { bench in
            try bench.shell(body: arguments.body, openFaces: arguments.openFaces, thickness: arguments.thickness)
        }
    }
}

struct AddHoleTool: Tool {
    let context: AssistantContext
    let name = "add_hole"
    let description = "Drills holes into a body's flat face, no sketch needed: a round hole of any diameter, or a metric screw hole (M2–M5: simple clearance, counterbore, countersink, or heat-set insert). Goes through unless a depth is given."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "top, bottom, front, back, left, right, a face number, or selected") var face: String
        @Guide(description: "Hole center, world mm; omit all three for the face center") var x: Double?
        var y: Double?
        var z: Double?
        @Guide(description: "Instead of a position: one hole near each of the face's four corners, this many mm in from both edges")
        var cornerInset: Double?
        @Guide(description: "For a plain round hole of a given size, its diameter in mm (then size and type are ignored)") var diameter: Double?
        @Guide(.anyOf(["simple", "counterbore", "countersink", "insert"])) var type: String?
        @Guide(.anyOf(["M2", "M2.5", "M3", "M4", "M5"])) var size: String?
        @Guide(description: "Only for blind holes: depth in mm. Omit for holes that go through (the usual).") var depth: Double?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Drilling \(arguments.body)") { bench in
            let center = arguments.x == nil && arguments.y == nil && arguments.z == nil || arguments.cornerInset != nil ? [] : [point(arguments.x, arguments.y, arguments.z)]
            return try bench.hole(body: arguments.body, face: arguments.face, at: center, cornerInset: arguments.cornerInset,
                                  kind: HoleSpec.Kind(rawValue: arguments.type?.lowercased() ?? "") ?? .simple, size: arguments.size ?? "M3",
                                  diameter: arguments.diameter, depth: arguments.depth)
        }
    }
}

struct AddPegTool: Tool {
    let context: AssistantContext
    let name = "add_peg"
    let description = "Adds round press-fit or alignment pegs standing on a body's flat face, joined to it or as separate dowel pins; every solid a peg pushes into (such as a lid sitting on that face) gets a matching socket with printing clearance."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "top, bottom, front, back, left, right, a face number, or selected") var face: String
        @Guide(description: "Peg center, world mm; omit all three for the face center") var x: Double?
        var y: Double?
        var z: Double?
        @Guide(description: "Peg diameter in mm (default 5)") var diameter: Double?
        @Guide(description: "How far the peg stands out, mm (default 5)") var height: Double?
        @Guide(description: "Gap around the peg in its socket, mm; omit for the user's Fit Clearance preference") var clearance: Double?
        @Guide(description: "True for a separate peg (a dowel pin printed on its own) instead of one joined to the body") var separate: Bool?
        @Guide(description: "Separate pegs: mm into the face it stands on, which gets a socket too (default its height; 0 to just stand on it)") var into: Double?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Adding a peg to \(arguments.body)") { bench in
            let center = arguments.x == nil && arguments.y == nil && arguments.z == nil ? [] : [point(arguments.x, arguments.y, arguments.z)]
            return try bench.peg(body: arguments.body, face: arguments.face, at: center, diameter: arguments.diameter ?? 5, height: arguments.height ?? 5,
                                 clearance: arguments.clearance ?? Fit.preferredClearance, separate: arguments.separate ?? false, into: arguments.into)
        }
    }
}

struct AddThreadTool: Tool {
    let context: AssistantContext
    let name = "add_thread"
    let description = "Cuts a real printable screw thread into a hole (nut) or onto a round boss (bolt), or with raised adds its ridges onto the face so a thin wall stays whole (a jar's neck). The size is picked from the face unless given; a size must reach the face (bigger than a hole, its root inside a boss; raised: a hole at its major diameter, a boss at its minor)."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "hole or boss (the body's first), a face number, or selected") var face: String
        @Guide(description: "Size: metric M2–M36 (M8x1 for a fine pitch) or inch #4–3/4 such as 1/4; omit to fit the face, or give diameter and pitch") var size: String?
        @Guide(description: "Custom major diameter in mm, e.g. for a jar lid") var diameter: Double?
        @Guide(description: "Pitch in mm: a fine pitch of the size, or a custom one") var pitch: Double?
        @Guide(description: "Gap in mm; omit for the user's Fit Clearance preference") var clearance: Double?
        var leftHanded: Bool?
        @Guide(description: "1–4 ridges side by side (2–4 for quick jar lids); omit for 1") var starts: Int?
        @Guide(description: "Threaded length in mm from the open end; omit for the whole face") var length: Double?
        @Guide(description: "True to add the ridges onto the face instead of cutting grooves into it, for thin walls such as a jar's neck") var raised: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Threading \(arguments.body)") { bench in
            try bench.thread(body: arguments.body, face: arguments.face, size: arguments.size, diameter: arguments.diameter, pitch: arguments.pitch,
                             clearance: arguments.clearance ?? Fit.preferredClearance, leftHanded: arguments.leftHanded ?? false,
                             starts: arguments.starts, length: arguments.length, raised: arguments.raised ?? false)
        }
    }
}

struct AddMatingPartTool: Tool {
    let context: AssistantContext
    let name = "add_matching_part"
    let description = "Makes the part that screws onto a body's thread, already screwed on: a nut or cap for a bolt's thread, a bolt or plug for a hole's."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "nut, cap, bolt, or plug; omit for the likelier one") var kind: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Making a matching part for \(arguments.body)") { bench in
            try bench.matingPart(body: arguments.body, kind: arguments.kind)
        }
    }
}

struct AddTextTool: Tool {
    let context: AssistantContext
    let name = "add_text"
    let description = "Adds raised (embossed) or sunk (debossed) lettering to a body's flat face, centered on the face unless placed."
    @Generable struct Arguments {
        var body: String
        @Guide(description: "top, bottom, front, back, left, right, a face number, or selected") var face: String
        var text: String
        @Guide(description: "Capital letter height in mm (5 is typical)") var height: Double
        @Guide(description: "mm the letters stand out; negative to sink them (about 0.6–1)") var depth: Double
        @Guide(description: "Center, world mm; omit for the face center") var x: Double?
        var y: Double?
        var z: Double?
        @Guide(description: "Degrees to turn the text, usually 0") var angle: Double?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Lettering \(arguments.body)") { bench in
            let center = arguments.x == nil && arguments.y == nil && arguments.z == nil ? nil : point(arguments.x, arguments.y, arguments.z)
            return try bench.text(body: arguments.body, face: arguments.face, text: arguments.text, height: arguments.height, depth: arguments.depth,
                                  at: center, angle: arguments.angle ?? 0)
        }
    }
}

struct FitTestTool: Tool {
    let context: AssistantContext
    let name = "add_fit_test"
    let description = "Adds the Fit Test print beside the model: a plate with holes at 0.10–0.40 mm clearance and a loose peg, for finding the printer's clearance."
    @Generable struct Arguments {
        @Guide(description: "Always true") var confirm: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Adding the Fit Test") { bench in try bench.fitTest() }
    }
}

struct MoveItemsTool: Tool {
    let context: AssistantContext
    let name = "move_items"
    let description = "Moves and/or rotates bodies and sketches, optionally as copies. Rotation turns about a world axis through each item's center."
    @Generable struct Arguments {
        var items: [String]
        @Guide(description: "Move in mm along world X") var dx: Double?
        var dy: Double?
        var dz: Double?
        @Guide(description: "Degrees, counterclockwise looking down the axis") var rotateDegrees: Double?
        @Guide(.anyOf(["x", "y", "z"])) var axis: String?
        @Guide(description: "Leave the originals in place and move copies") var copy: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Moving \(arguments.items.joined(separator: ", "))") { bench in
            try bench.transform(items: arguments.items, move: point(arguments.dx, arguments.dy, arguments.dz), rotate: arguments.rotateDegrees ?? 0,
                                axis: arguments.axis ?? "z", pivot: nil, copy: arguments.copy ?? false)
        }
    }
}

/// Moves only: the on-device model, given rotation fields too, tends to fill them in.
struct MoveOnlyTool: Tool {
    let context: AssistantContext
    let name = "move_items"
    let description = "Moves bodies and sketches by a distance in mm along world X, Y, Z, optionally as copies."
    @Generable struct Arguments {
        var items: [String]
        @Guide(description: "mm along X (right is positive)") var dx: Double?
        @Guide(description: "mm along Y (back is positive)") var dy: Double?
        @Guide(description: "mm along Z (up is positive)") var dz: Double?
        @Guide(description: "Leave the originals in place and move copies") var copy: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Moving \(arguments.items.joined(separator: ", "))") { bench in
            try bench.transform(items: arguments.items, move: point(arguments.dx, arguments.dy, arguments.dz), rotate: 0, axis: "z", pivot: nil, copy: arguments.copy ?? false)
        }
    }
}

struct SetDimensionTool: Tool {
    let context: AssistantContext
    let name = "set_dimension"
    let description = "Changes a sketch shape's width, height, diameter, radius, or length, or a body's extrusion depth or revolve angle."
    @Generable struct Arguments {
        @Guide(description: "Shape (Rectangle 01) or body (Body 01)") var item: String
        @Guide(.anyOf(["width", "height", "diameter", "radius", "length", "depth", "angle"])) var dimension: String
        @Guide(description: "New value in mm (degrees for angle)") var value: Double
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Changing \(arguments.item)") { bench in
            try bench.setDimension(item: arguments.item, dimension: arguments.dimension, value: arguments.value)
        }
    }
}

struct DeleteItemsTool: Tool {
    let context: AssistantContext
    let name = "delete_items"
    let description = "Deletes bodies, sketches, shapes, or construction planes."
    @Generable struct Arguments { var items: [String] }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Deleting \(arguments.items.joined(separator: ", "))") { bench in try bench.delete(items: arguments.items) }
    }
}

struct SetVisibilityTool: Tool {
    let context: AssistantContext
    let name = "set_visibility"
    let description = "Hides or shows bodies, sketches, construction planes, or groups (a group hides everything in it)."
    @Generable struct Arguments {
        var items: [String]
        var visible: Bool
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("\(arguments.visible ? "Showing" : "Hiding") \(arguments.items.joined(separator: ", "))") { bench in
            try bench.setHidden(items: arguments.items, hidden: !arguments.visible)
        }
    }
}

struct CombineTool: Tool {
    let context: AssistantContext
    let name = "combine"
    let description = "Unites touching bodies into a target body, subtracts tool bodies from it, or intersects them (keeps only the volume they all share)."
    @Generable struct Arguments {
        @Guide(.anyOf(["union", "subtract", "intersect"])) var operation: String
        var target: String
        var tools: [String]
        @Guide(description: "Keep the tool bodies afterwards") var keepTools: Bool?
        @Guide(description: "Subtract only: mm of gap left around the tools so a printed part shaped like them fits (the user's Fit Clearance is usually 0.1–0.3); omit for an exact cut")
        var clearance: Double?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Combining into \(arguments.target)") { bench in
            if arguments.operation.lowercased() == "intersect" {
                return try bench.intersect(target: arguments.target, tools: arguments.tools, keepTools: arguments.keepTools ?? false)
            }
            return try bench.combine(union: arguments.operation.lowercased() != "subtract", target: arguments.target, tools: arguments.tools, keepTools: arguments.keepTools ?? false,
                              clearance: arguments.clearance)
        }
    }
}

struct MirrorTool: Tool {
    let context: AssistantContext
    let name = "mirror"
    let description = "Mirrors bodies and sketches across top, front, right, a construction plane, or a body's flat face."
    @Generable struct Arguments {
        var items: [String]
        @Guide(description: "top, front, right, Plane 01, or a body name") var plane: String
        @Guide(description: "When plane is a body: its face") var face: String?
        @Guide(description: "Keep the originals (default true)") var keepOriginals: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Mirroring \(arguments.items.joined(separator: ", "))") { bench in
            try bench.mirror(items: arguments.items, across: arguments.plane, face: arguments.face, keepOriginals: arguments.keepOriginals ?? true)
        }
    }
}

struct PatternTool: Tool {
    let context: AssistantContext
    let name = "pattern"
    let description = "Copies bodies and sketches in a row or grid along world directions (linear), or around a world axis (circular, e.g. bolt holes or spokes). Counts include the original; copies are independent."
    @Generable struct Arguments {
        var items: [String]
        @Guide(.anyOf(["linear", "circular"])) var type: String
        @Guide(description: "Instances including the original: along direction, or around the circle") var count: Int
        @Guide(description: "Linear: x, y, z, -x, -y, or -z") var direction: String?
        @Guide(description: "Linear: mm between neighbors") var spacing: Double?
        @Guide(description: "Linear grid: a second direction") var direction2: String?
        var count2: Int?
        var spacing2: Double?
        @Guide(.anyOf(["x", "y", "z"])) var axis: String?
        @Guide(description: "Circular: center of the circle, mm (default the origin)") var centerX: Double?
        var centerY: Double?
        var centerZ: Double?
        @Guide(description: "Circular: total degrees (default 360, evenly around)") var angle: Double?
        @Guide(description: "Circular: turn each copy with the pattern (default true)") var rotateCopies: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Patterning \(arguments.items.joined(separator: ", "))") { bench in
            if arguments.type.lowercased() == "circular" {
                return try bench.circularPattern(items: arguments.items, axis: arguments.axis ?? "z", center: point(arguments.centerX, arguments.centerY, arguments.centerZ),
                                                 count: arguments.count, angle: arguments.angle ?? 360, rotateCopies: arguments.rotateCopies ?? true)
            }
            guard let spacing = arguments.spacing else { throw AssistantWorkbench.Failure("A linear pattern needs a spacing.") }
            var rows = [(direction: arguments.direction ?? "x", count: arguments.count, spacing: spacing)]
            if let direction = arguments.direction2 {
                guard let count = arguments.count2, let spacing = arguments.spacing2 else { throw AssistantWorkbench.Failure("The second direction needs count2 and spacing2.") }
                rows.append((direction, count, spacing))
            }
            return try bench.linearPattern(items: arguments.items, rows: rows)
        }
    }
}

struct AddPlaneTool: Tool {
    let context: AssistantContext
    let name = "add_plane"
    let description = "Adds a construction plane parallel to top, front, right, another plane, or a body's flat face, offset along its normal. Sketch on it afterwards."
    @Generable struct Arguments {
        @Guide(description: "top, front, right, Plane 01, or a body name") var from: String
        @Guide(description: "When from is a body: its face") var face: String?
        @Guide(description: "Offset in mm along the normal") var offset: Double
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Adding a plane") { bench in try bench.addPlane(from: arguments.from, face: arguments.face, offset: arguments.offset) }
    }
}

struct RevolveTool: Tool {
    let context: AssistantContext
    let name = "revolve"
    let description = "Revolves a sketch region about a world axis (x, y, z) lying in the sketch plane, or about a line of the sketch."
    @Generable struct Arguments {
        var sketch: String
        var region: Int?
        @Guide(description: "x, y, z, or a line name such as Line 01") var axis: String
        @Guide(description: "Degrees, up to 360") var angle: Double
        @Guide(.anyOf(["auto", "new body", "join", "cut"])) var operation: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Revolving \(arguments.sketch)") { bench in
            try bench.revolve(sketch: arguments.sketch, region: arguments.region, axis: arguments.axis, angle: arguments.angle, mode: .init(arguments.operation))
        }
    }
}

struct RoundSketchCornersTool: Tool {
    let context: AssistantContext
    let name = "round_sketch_corners"
    let description = "Rounds the corners of a sketch where two lines meet (rectangle corners too) with tangent arcs of a radius, before extruding."
    @Generable struct Arguments {
        @Guide(description: "The sketch's name, e.g. Sketch 01") var sketch: String
        @Guide(description: "Corner radius in mm") var radius: Double
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Rounding \(arguments.sketch)") { bench in try bench.roundCorners(sketch: arguments.sketch, radius: arguments.radius) }
    }
}

struct MeasureTool: Tool {
    let context: AssistantContext
    let name = "measure"
    let description = "Measures one item (length, radius, area, volume, size) or the distance and angle between two. Changes nothing."
    @Generable struct Arguments {
        @Guide(description: "A body (Body 01), a face or edge of one (Body 01 face top, Body 01 edge 4), a sketch shape (Line 02), origin, a point x, y, z, or selected")
        var item: String
        @Guide(description: "A second item to measure the distance and angle to, if any") var to: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await context.run("Measuring \(arguments.item)") { bench in try bench.measure(arguments.item, arguments.to) }
    }
}

extension AssistantContext {
    /// Every tool, for the cloud model.
    var allTools: [any Tool] {
        [InspectItemTool(context: self), SketchAndExtrudeTool(context: self), AddSketchTool(context: self), ExtrudeTool(context: self), ExtrudeFaceTool(context: self),
         FilletEdgesTool(context: self), ChamferEdgesTool(context: self), ShellTool(context: self), AddHoleTool(context: self), AddPegTool(context: self), AddThreadTool(context: self), AddMatingPartTool(context: self), AddTextTool(context: self), FitTestTool(context: self),
         MoveItemsTool(context: self), SetDimensionTool(context: self), DeleteItemsTool(context: self), SetVisibilityTool(context: self), CombineTool(context: self),
         MirrorTool(context: self), PatternTool(context: self), AddPlaneTool(context: self), RevolveTool(context: self), RoundSketchCornersTool(context: self), MeasureTool(context: self),
         ScaleItemsTool(context: self), DeleteFacesTool(context: self), DeleteHoleTool(context: self), EditFinishTool(context: self), ResizeFaceTool(context: self), OffsetSketchTool(context: self), RenameItemTool(context: self), GroupItemsTool(context: self), UngroupTool(context: self),
         SetColorTool(context: self)]
    }
    /// The everyday tools, which fit the on-device model's smaller context.
    var compactTools: [any Tool] {
        [InspectItemTool(context: self), SketchAndExtrudeTool(context: self), FilletEdgesTool(context: self), ChamferEdgesTool(context: self), ShellTool(context: self),
         AddHoleTool(context: self), MoveOnlyTool(context: self), SetDimensionTool(context: self), DeleteItemsTool(context: self)]
    }
}
