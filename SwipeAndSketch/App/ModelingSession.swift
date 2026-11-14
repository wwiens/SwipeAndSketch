import SwiftUI
import os
import Combine
import simd

enum ModelingTool: String, CaseIterable, Sendable {
    case select, line, circle, rectangle, arc, slot, extrude, revolve, fillet, chamfer, shell, hole, offsetPlane, midplane, project, split, union, subtract, align, mirror, pattern
    /// Sketch tools: round a corner where two lines meet, trim a shape back to where others cross it,
    /// and dimension between sketch items.
    case cornerFillet, trim, dimension
    /// Read sizes, distances, and angles (sketching or modeling).
    case measure
    /// Fit tools: a press-fit peg with its socket, placed on a face like a
    /// hole, and the Fit Test coupon for finding a printer's clearance.
    case peg, fitTest
    /// A modeled screw thread on a hole or round boss.
    case thread
    /// A container's neck threaded, with a lid already screwed on (Joints ▸ Screw Lid).
    case screwLid
    /// Letters embossed onto or debossed into a face, placed like a hole.
    case text
    /// Keep only where solids overlap (Combine ▸ Intersect).
    case intersect
    /// Make solids and sketches larger or smaller (Transform ▸ Scale).
    case scale
    /// Take faces off a solid and close the gap (a fillet, hole, or boss removed).
    case deleteFace
    /// Sketch tools (October 21, 2026): an ellipse, a point, and a regular polygon to draw; and
    /// Extend, Offset, and Mirror, which work on drawn shapes.
    case ellipse, point, polygon, extend, offset, sketchMirror
    /// Primitives (October 24, 2026): a ready-made solid placed with a tap (Create ▸ Box …).
    case box, cylinder, sphere, torus
    var primitiveKind: PrimitiveKind? { PrimitiveKind(rawValue: rawValue) }
    /// More construction (October 24, 2026): planes at an angle about a line, through three points,
    /// and tangent to a round face, and axes (Planes ▸ …).
    case planeAngle, plane3Point, planeTangent, axis
    /// A smooth curve drawn freehand and fitted through a few points (Shapes ▸ Spline).
    case spline
    /// Draft (Modify ▸), and Loft, Sweep, and Rib (Create ▸), October 24, 2026.
    case draft, loft, sweep, rib
    var isShapeTool: Bool { [.draft, .loft, .sweep, .rib].contains(self) }
    var isConstructionTool: Bool { [.planeAngle, .plane3Point, .planeTangent, .axis].contains(self) }
    var title: String {
        switch self {
        case .offsetPlane: "Offset Plane"
        case .split: "Split"
        case .midplane: "Midplane"
        case .cornerFillet: "Fillet"
        case .fitTest: "Fit Test"
        case .screwLid: "Screw Lid"
        case .deleteFace: "Delete Face"
        case .sketchMirror: "Mirror"
        case .planeAngle: "Plane at Angle"
        case .plane3Point: "3-Point Plane"
        case .planeTangent: "Tangent Plane"
        default: rawValue.capitalized
        }
    }
    var isPlaneTool: Bool { self == .offsetPlane || self == .midplane }
    /// Tools that work on sketch shapes rather than draw them.
    var isSketchEditTool: Bool { [.cornerFillet, .trim, .dimension, .extend, .offset, .sketchMirror, .polygon].contains(self) }
    /// Features placed with a tap on the face being sketched on.
    var isFaceFeature: Bool { self == .hole || self == .peg || self == .text }
    var icon: SSIcon {
        switch self {
        case .arc: .arc
        case .slot: .slot
        case .cornerFillet: .sketchFillet
        case .trim: .trim
        case .dimension: .dimension
        case .measure: .measure
        case .offsetPlane: .offsetPlane
        case .midplane: .midplane
        case .select: .select
        case .line: .line
        case .circle: .circle
        case .rectangle: .rectangle
        case .extrude: .extrude
        case .revolve: .revolve
        case .fillet: .fillet
        case .chamfer: .chamfer
        case .shell: .shell
        case .hole: .hole
        case .project: .project
        case .split: .split
        case .union: .merge
        case .subtract: .subtract
        case .intersect: .intersect
        case .scale: .scale
        case .deleteFace: .deleteFace
        case .ellipse: .ellipse
        case .point: .point
        case .polygon: .polygon
        case .extend: .extend
        case .offset: .offset
        case .sketchMirror: .mirror
        case .align: .align
        case .mirror: .mirror
        case .pattern: .pattern
        case .peg: .peg
        case .fitTest: .fitTest
        case .thread: .thread
        case .screwLid: .screwLid
        case .text: .text
        case .box: .box
        case .cylinder: .cylinder
        case .sphere: .sphere
        case .torus: .torus
        case .planeAngle: .planeAngle
        case .plane3Point: .plane3Point
        case .planeTangent: .planeTangent
        case .axis: .axis
        case .spline: .spline
        case .draft: .draft
        case .loft: .loft
        case .sweep: .sweep
        case .rib: .rib
        }
    }
    var shapeKind: ShapeKind? { self == .spline ? .curve : ShapeKind(rawValue: rawValue) }
    var finishKind: EdgeFinish.Kind? { EdgeFinish.Kind(rawValue: rawValue) }
}

enum ModelSelection: Equatable {
    case shape(UUID), profile(String), body(UUID), face(FaceSelection), sketch(UUID)
    /// Shapes of one sketch joined end to end, picked by double-tapping one of its lines outside
    /// the sketch (October 30, 2026); `SketchEditing.chain` finds them.
    case chain([UUID])
    /// A solid edge picked with no tool chosen, ready to round or bevel.
    case edge(UUID, PickedEdge)
    case plane(UUID)
    /// A Model Tree group (Groups.swift): only its row, never the canvas, picks it.
    case group(UUID)
}

/// An edge picked on a solid as it is now: its kernel index (meaningful until the solid changes),
/// its original extrusion name when it has one, and its middle point in world millimeters.
struct PickedEdge: Hashable {
    var index: Int
    var name: ExtrusionEdge?
    var point: SIMD3<Double>

    /// The edge of `body` (as it builds now) that carries an original extrusion name.
    static func named(_ name: ExtrusionEdge, on body: SolidBody) -> PickedEdge? {
        guard let solid = try? SolidKernel.solid(for: body) else { return nil }
        for index in 0..<solid.edgeCount where body.edgeNames([index], of: solid).first == name {
            let samples = solid.edgeSamples(index, count: 3)
            return PickedEdge(index: index, name: name, point: samples.count == 3 ? samples[1] : .zero)
        }
        return nil
    }
}

/// A face picked on a solid. `face` indexes the body's current kernel solid and is only
/// meaningful until the body changes: selections are cleared on undo and redo, and a sketch mode
/// on the face follows it to its new index.
struct FaceSelection: Equatable {
    var bodyID: UUID
    var face: Int
    /// The face's sketch plane, or nil for a curved face (which cannot be sketched on).
    var plane: SketchPlane?
    /// Where to center the view when sketching on the face.
    var center: SIMD3<Double>
    /// Where the face was tapped (always on the face, unlike the center of a ring).
    var point: SIMD3<Double>?
}

/// Sketching locked to one plane, entered from a face's Sketch button or a drawing tool.
struct SketchMode: Equatable {
    var plane: SketchPlane
    /// The face being sketched on, whose area center becomes a guide point.
    var face: FaceSelection?
    /// The sketch new shapes join; nil until the first shape starts a new sketch.
    var sketchID: UUID?
    /// The construction plane being sketched on.
    var constructionPlane: UUID?
    var title: String { face != nil ? "Face sketch" : constructionPlane != nil ? "Plane sketch" : "\(plane.title) sketch" }
}

enum DimensionTarget: Hashable {
    case shape(UUID, ShapeDimension), bodyDepth(UUID), extrusion, finishSize(EdgeFinish.Kind), shellThickness, holeDiameter, holeDepth
    /// The last move or turn of a sketch or solid with the Move/Rotate widget.
    case transformDistance, transformAngle
    /// How far a new construction plane sits from its reference.
    case planeOffset
    /// Align: the distance off the target, and the turn about it.
    case alignOffset, alignAngle
    /// Revolve: the angle of the revolve being set up, and of a selected revolved solid.
    case revolveAngle, bodyAngle(UUID)
    /// The radius of the sketch corner just rounded.
    case cornerRadius
    /// Pattern: the total or spacing along a direction (0 x, 1 y, 2 normal), the angle of a
    /// circular pattern, and the quantity.
    case patternDistance(Int), patternAngle, patternCount
    /// A dimension between picks of the Dimension tool: its place in the list, and whether it is an angle.
    case relation(Int, angle: Bool)
    /// A dimension kept in a sketch (SketchDimensions.swift), by id, and whether it is an angle.
    case kept(UUID, angle: Bool)
    /// Peg & Socket: the peg's size; the clearance of the fit being set up (a peg's or Subtract's);
    /// and the app's Fit preference.
    case pegDiameter, pegHeight, clearance, fitClearance
    /// How far a separate peg reaches into the face it stands on.
    case pegEmbed
    /// Thread: its nominal diameter and pitch, and how much of the face it runs along.
    case threadDiameter, threadPitch, threadLength
    /// Text: its capitals' height, and how far it is raised or sunk.
    case textHeight, textDepth
    /// Scale: the percentage along one gizmo axis (0 x, 1 y, 2 normal), or of the whole (3).
    case scalePercent(Int)
    /// A selected round face's diameter, or a flat face's distance to the parallel face behind it.
    case faceDiameter, faceDistance
    /// Extrude's taper, in degrees.
    case extrusionTaper
    /// Where the section plane lies along its normal.
    case sectionOffset
    /// The polygon just drawn: how many sides it has, and its radius (center to a corner).
    case polygonSides, polygonRadius
    /// Offset: how far the new outline lies from the picked one.
    case offsetDistance
    /// The radius or distance of the fillet or chamfer whose face is selected.
    case selectedFinish(EdgeFinish.Kind)
    /// A size of the primitive being placed, by its index in `PrimitiveKind.sizes`.
    case primitiveSize(PrimitiveKind, Int)
    /// Plane at Angle: degrees turned about its line.
    case constructionAngle
    /// Draft's angle and Rib's thickness.
    case draftAngle, ribThickness
    var unit: String {
        switch self {
        case .scalePercent: "%"
        case .extrusionTaper: "°"
        case .polygonSides: ""
        case .transformAngle, .alignAngle, .revolveAngle, .bodyAngle, .patternAngle, .constructionAngle, .draftAngle: "°"
        case .patternCount: ""
        case .relation(_, let angle), .kept(_, let angle): angle ? "°" : "mm"
        default: "mm"
        }
    }
    /// A length, shown and typed in the chosen length unit (angles are always degrees).
    var isLength: Bool { unit == "mm" }
    var title: String {
        switch self {
        case .transformDistance: "Distance"
        case .transformAngle: "Angle"
        case .planeOffset, .alignOffset: "Offset"
        case .alignAngle, .revolveAngle, .bodyAngle: "Angle"
        case .shape(_, let dimension): dimension.title
        case .bodyDepth, .extrusion: "Distance"
        case .finishSize(let kind): kind.sizeTitle
        case .shellThickness: "Thickness"
        case .holeDiameter: "Diameter"
        case .holeDepth: "Depth"
        case .pegDiameter: "Diameter"
        case .pegHeight: "Height"
        case .pegEmbed: "Into Face"
        case .clearance: "Clearance"
        case .fitClearance: "Fit Clearance"
        case .threadDiameter: "Diameter"
        case .threadPitch: "Pitch"
        case .threadLength: "Length"
        case .textHeight: "Height"
        case .textDepth: "Depth"
        case .scalePercent(let axis): axis == 3 ? "Scale" : "Scale " + ["X", "Y", "Z"][axis]
        case .faceDiameter: "Diameter"
        case .faceDistance: "Distance"
        case .selectedFinish(let kind): kind.sizeTitle
        case .primitiveSize(let kind, let index): kind.sizes[index].name
        case .extrusionTaper: "Taper"
        case .sectionOffset: "Offset"
        case .polygonSides: "Sides"
        case .polygonRadius: "Radius"
        case .offsetDistance: "Distance"
        case .cornerRadius: "Radius"
        case .relation(_, let angle), .kept(_, let angle): angle ? "Angle" : "Distance"
        case .patternDistance: "Distance"
        case .patternAngle: "Angle"
        case .patternCount: "Quantity"
        case .constructionAngle: "Angle"
        case .draftAngle: "Draft"
        case .ribThickness: "Thickness"
        }
    }
    var accessibilityName: String {
        switch self {
        case .shape(_, let dimension): dimension.rawValue
        case .bodyDepth, .extrusion: "depth"
        case .finishSize: "finish"
        case .shellThickness: "shell"
        case .holeDiameter: "hole.diameter"
        case .holeDepth: "hole.depth"
        case .pegDiameter: "peg.diameter"
        case .pegHeight: "peg.height"
        case .pegEmbed: "peg.embed"
        case .clearance: "clearance"
        case .fitClearance: "fit"
        case .threadDiameter: "thread.diameter"
        case .threadPitch: "thread.pitch"
        case .threadLength: "thread.length"
        case .textHeight: "text.height"
        case .textDepth: "text.depth"
        case .scalePercent(let axis): "scale.\(axis)"
        case .faceDiameter: "face.diameter"
        case .faceDistance: "face.distance"
        case .selectedFinish(let kind): kind == .fillet ? "finish.radius" : "finish.distance"
        case .primitiveSize(let kind, let index): "\(kind.rawValue).\(kind.sizes[index].name.lowercased())"
        case .extrusionTaper: "extrusion.taper"
        case .sectionOffset: "section.offset"
        case .polygonSides: "polygon.sides"
        case .polygonRadius: "polygon.radius"
        case .offsetDistance: "offset.distance"
        case .transformDistance: "transform.distance"
        case .transformAngle: "transform.angle"
        case .planeOffset: "plane.offset"
        case .alignOffset: "align.offset"
        case .alignAngle: "align.angle"
        case .revolveAngle: "revolve.angle"
        case .bodyAngle: "angle"
        case .cornerRadius: "corner.radius"
        case .relation(let index, _): "relation.\(index)"
        case .kept(let id, _): "kept.\(id.uuidString)"
        case .patternDistance(let axis): "pattern.distance.\(axis)"
        case .patternAngle: "pattern.angle"
        case .patternCount: "pattern.count"
        case .constructionAngle: "plane.angle"
        case .draftAngle: "draft.angle"
        case .ribThickness: "rib.thickness"
        }
    }
    /// Values that may be exactly 0: offsets, turns, and dimensions between sketch items (0 lines them up).
    var allowsZero: Bool {
        switch self {
        case .planeOffset, .alignOffset, .alignAngle, .relation, .kept, .pegEmbed, .extrusionTaper, .sectionOffset, .constructionAngle: true
        default: false
        }
    }
    var allowsNegative: Bool {
        switch self {
        case .bodyDepth, .extrusion, .transformDistance, .transformAngle, .planeOffset, .alignOffset, .alignAngle, .revolveAngle, .bodyAngle,
             .patternDistance, .patternAngle, .extrusionTaper, .sectionOffset, .offsetDistance, .constructionAngle, .draftAngle: true
        default: false
        }
    }
    /// Values that drive a live operation preview (outlined label beside a drag handle).
    var isOperationValue: Bool {
        switch self {
        case .extrusion, .finishSize, .shellThickness, .holeDiameter, .holeDepth, .pegDiameter, .pegHeight, .pegEmbed, .transformDistance, .transformAngle,
             .planeOffset, .alignOffset, .alignAngle, .revolveAngle, .cornerRadius, .patternDistance, .patternAngle, .threadDiameter, .threadPitch, .threadLength, .textHeight, .textDepth,
             .scalePercent, .sectionOffset, .polygonSides, .polygonRadius, .offsetDistance, .primitiveSize, .constructionAngle, .draftAngle, .ribThickness: true
        case .shape, .bodyDepth, .bodyAngle, .relation, .kept, .patternCount, .clearance, .fitClearance, .faceDiameter, .faceDistance, .selectedFinish, .extrusionTaper: false
        }
    }
}

/// A handle of the Move/Rotate widget: slide along, or turn about, one of the sketch's own axes
/// (0 = its x axis, 1 = its y axis, 2 = its normal).
enum TransformHandle: Equatable {
    case move(Int), rotate(Int)
    var isRotation: Bool { if case .rotate = self { true } else { false } }
    var axis: Int { switch self { case .move(let i), .rotate(let i): i } }
}

/// A move or turn of a sketch or solid: what it started from, so a drag previews from the same
/// place and the keypad can change the amount afterwards.
struct TransformRecord: Equatable {
    var base: Workspace
    var target: TransformTarget
    var handle: TransformHandle
    /// Millimeters, or degrees for a turn.
    var amount: Double
    var copy: Bool
    var center: SIMD3<Double>
    var axes: [SIMD3<Double>]
    var result: Workspace?
    /// What moved: the original, or its copy.
    var resultTarget: TransformTarget?
    /// The widget center the solid was dragged or turned about, when it had been moved onto the solid.
    var pivot: TransformPivot.Kind?

    /// The keypad value for this move or turn: a distance, or an angle.
    var dimensionTarget: DimensionTarget { handle.isRotation ? .transformAngle : .transformDistance }

    var transform: RigidTransform {
        handle.isRotation ? .rotate(degrees: amount, about: axes[handle.axis], through: center) : .move(axes[handle.axis] * amount)
    }
}

/// A solid's widget center placed on the solid (or on another solid, a sketch point, or the
/// origin), and the widget's axes there. It moves with the solid.
struct PlacedPivot: Equatable {
    var bodyID: UUID
    /// The solid as it was when the center was placed; any other change to it lapses the pivot.
    var body: SolidBody
    var kind: TransformPivot.Kind
    var center: SIMD3<Double>
    var axes: [SIMD3<Double>]
}

/// A construction plane being placed with Offset Plane or Midplane: the references picked so far
/// and, for Offset Plane, the distance from the reference.
struct PlaneDraft: Equatable {
    var references: [PlaneReference] = []
    var offset = 0.0
}

/// Draft, Loft, Sweep, or Rib being set up: what has been picked and the values typed.
struct ShapeToolDraft: Equatable, Sendable {
    /// Draft: the solid, its neutral face (a point on it and the pull, into the solid), the faces to
    /// lean (a point on each), and the angle.
    var bodyID: UUID?
    var neutral: SIMD3<Double>?
    var pull: SIMD3<Double>?
    var faces: [SIMD3<Double>] = []
    var angle = 3.0
    /// Rib: the sketch line, the web's thickness, and its side (nil: whichever meets a solid).
    var line: UUID?
    var thickness = 3.0
    var side: Double?
    /// Loft: the regions in order (Sweep: its section first); Sweep: the path's shape.
    var regions: [SketchProfile] = []
    var path: UUID?
    var ruled = false
    var error: String?
}

/// Plane at Angle, 3-Point Plane, Tangent Plane, or Axis being set up: what has been picked.
struct ConstructionDraft: Equatable {
    /// A straight line: Plane at Angle turns about it; Axis runs along it.
    var line: AlignFeature?
    /// Plane at Angle's 0°: the face beside the edge, or the line's sketch plane (its normal).
    var reference: SIMD3<Double>?
    /// Points picked: three for a plane, two for an axis.
    var points: [AlignFeature] = []
    var angle = 90.0
    /// A round face: Tangent Plane touches it at `point`; Axis runs along its axis over `extent`.
    struct Round: Equatable {
        var axisPoint: SIMD3<Double>, axisDirection: SIMD3<Double>, radius: Double, point: SIMD3<Double>
        var extent: ClosedRange<Double>
    }
    var round: Round?
}

/// Project in progress (sketch projections): the items picked so
/// far and the surface they are cast onto.
struct ProjectionDraft: Equatable {
    /// Which of the two picks the Pencil is making (Geometry / Target Plane).
    enum Step: Equatable { case items, surface }
    var items: [ProjectionItem] = []
    var target: ProjectionTarget?
    var step = Step.items
    /// Projecting inside a sketch: the surface is that sketch, so only items are picked.
    var fixedTarget = false
}

/// Split Body in progress: the solids to split and what to split
/// them with.
struct SplitDraft: Equatable {
    /// Which of the two picks the Pencil is making (Bodies to Split / Splitting Tools).
    enum Step: Equatable { case bodies, tools }
    var bodies: [UUID] = []
    var tools: [SplitTool] = []
    var step = Step.bodies
    /// Keep the original solids alongside the pieces.
    var keepOriginals = false
}

/// Mirror in progress: the solids and sketches to mirror, and
/// the plane to mirror them across.
struct MirrorDraft: Equatable, Sendable {
    /// Which of the two picks the Pencil is making (what to mirror / the mirror plane).
    enum Step: Equatable { case items, plane }
    var bodies: [UUID] = []
    var sketches: [UUID] = []
    var plane: MirrorPlane?
    var step = Step.items
    /// Keep the originals beside their mirror images (Keep Input, on by default).
    var keepOriginals = true
    var isEmpty: Bool { bodies.isEmpty && sketches.isEmpty }
}

/// Pattern in progress: the solids and sketches to copy and how
/// the copies are laid out. The gizmo starts at the items' middle with the first item's own axes,
/// as the Move/Rotate widget does.
struct PatternDraft: Equatable {
    var bodies: [UUID] = []
    var sketches: [UUID] = []
    var spec = PatternSpec(center: .zero, axes: PatternDraft.worldAxes)
    /// The first item's own axes (x, y, normal), and the gizmo's: those, or turned onto the edge or
    /// circle its center was dragged to.
    var ownAxes = PatternDraft.worldAxes
    var axes = PatternDraft.worldAxes
    var center = SIMD3<Double>.zero
    /// Where the gizmo center was dragged; it then stays put when items are picked.
    var placedCenter: TransformPivot.Kind?
    /// The linear direction the quantity applies to (the last one dragged), and the axis circular
    /// copies turn about (0 x, 1 y, 2 normal).
    var linearAxis = 0
    var circularAxis = 2
    var isEmpty: Bool { bodies.isEmpty && sketches.isEmpty }
    /// The quantity shown in the bar: along the last dragged direction, or round the circle.
    var count: Int { spec.kind == .linear ? spec.directions[linearAxis].count : spec.count }

    static let worldAxes: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]

    /// Carries the gizmo's place and axes into the spec.
    mutating func syncSpec() {
        for index in spec.directions.indices { spec.directions[index].axis = axes[index] }
        spec.center = center
        spec.axis = axes[circularAxis]
    }
}

/// Scale in progress: the solids and sketches to scale, the point that stays put, and the
/// percentages. The gizmo takes the first item's own axes, as the Move/Rotate widget does.
struct ScaleDraft: Equatable, Sendable {
    /// Where the scale is centered: the items' middle, the middle of their bottom (so printed parts
    /// stay on the plate), or the origin.
    enum Pivot: String, CaseIterable, Equatable, Sendable {
        case center, base, origin
        var title: String { switch self { case .center: "Center"; case .base: "Base"; case .origin: "Origin" } }
    }
    var bodies: [UUID] = []
    var sketches: [UUID] = []
    /// One percentage for every direction, or one along each gizmo axis (solids only).
    var uniform = true
    /// Percent along x, y, and the normal of the gizmo's axes; a uniform scale uses the first.
    var percents = SIMD3<Double>(repeating: 100)
    var pivot = Pivot.center
    /// Keep the originals and add scaled copies.
    var copy = false
    var axes = PatternDraft.worldAxes
    var center = SIMD3<Double>.zero
    var isEmpty: Bool { bodies.isEmpty && sketches.isEmpty }
    /// The factors the kernel applies.
    var factors: SIMD3<Double> { uniform ? SIMD3(repeating: percents.x / 100) : percents / 100 }
}

/// A solid copy in the pattern preview: the original it copies, and the motion that places it.
struct PatternGhost: Equatable {
    var source: UUID
    var transform: RigidTransform
}

/// Union or Intersect in progress: the solids picked,
/// in order. The last one is the target the others unite into (or that is cut down to their overlap).
struct UnionDraft: Equatable {
    var bodies: [UUID] = []
    /// Intersect: keep only the volume every picked solid shares.
    var intersect = false
    /// Keep the original solids and add the united one as a new solid.
    var keepOriginals = false
    var target: UUID? { bodies.last }
}

/// Subtract in progress: target solids (purple) and the tool solids
/// (blue) taken out of them.
struct SubtractDraft: Equatable {
    enum Step: Equatable { case targets, tools }
    /// Which input bodies stay afterwards besides the results: the targets, the tools, both, or neither.
    enum Keep: String, CaseIterable, Equatable {
        case none, modified, removed, all
        var title: String {
            switch self { case .none: "None"; case .all: "Targets & Tools"; case .modified: "Targets"; case .removed: "Tools" }
        }
        var keepsTargets: Bool { self == .all || self == .modified }
        var keepsTools: Bool { self == .all || self == .removed }
    }
    var targets: [UUID] = []
    var tools: [UUID] = []
    var step = Step.targets
    var keep = Keep.none
    /// The gap left around the tools, in millimeters, so a part shaped like them fits (nil: exact).
    var clearance: Double?
}

/// Align in progress: the solids that move, the feature on them
/// that is aligned (From), the target (To), and the adjustments.
struct AlignDraft: Equatable {
    enum Step: Equatable { case bodies, from, to }
    var bodies: [UUID] = []
    var from: AlignFeature?
    var to: AlignFeature?
    var step = Step.bodies
    var flip = false
    var offset = 0.0
    var angle = 0.0
}

/// Revolve in progress: the sketch region (or a solid's flat face) being
/// turned, the axis it turns about, and how far. New Body, Join, and Cut work as for Extrude.
struct RevolveDraft: Equatable {
    var profile: SketchProfile
    /// More picked regions on the same plane, revolved with `profile` about the same axis.
    var more: [SketchProfile] = []
    var profiles: [SketchProfile] { [profile] + more }
    /// Revolving a solid's own flat face, which joins or cuts that solid.
    var face: FaceExtrusionSource?
    var axis: RevolveAxis?
    /// Signed degrees; 0 until dragged or typed.
    var angle = 0.0
    var mode = ExtrusionMode.newBody
    /// Until New Body, Join, or Cut is picked, the result decides: into a solid cuts it.
    var modeIsAutomatic = true
    /// The revolve, its axis ordered so a positive angle first lifts the region toward its plane's
    /// normal, as a positive extrusion does.
    var spec: RevolveSpec? { axis.map { RevolveSpec.oriented(from: $0.from, to: $0.to, angle: angle, for: profile) } }
}

/// The axis picked for a revolve: two points on it in the region's plane, and the stretch of the
/// sketch line, solid edge, or world axis that was tapped, in world millimeters.
struct RevolveAxis: Equatable {
    var from: Point2
    var to: Point2
    var start: SIMD3<Double>
    var end: SIMD3<Double>
}

/// What Done does with an extrusion: make a separate solid, or subtract from the solids it touches.
enum ExtrusionMode: String, CaseIterable {
    case newBody, join, cut
    var title: String {
        switch self { case .newBody: "New Body"; case .join: "Join"; case .cut: "Cut" }
    }
}

/// Faces picked to leave open on a shell that has not been committed yet.
struct ShellDraft: Equatable {
    var bodyID: UUID
    var openings: [ShellOpening]
    var thickness: Double
    /// The openings that are original extrusion faces, saved by name.
    var openFaces: [ExtrusionFace] { openings.compactMap(\.name) }
}

/// A face to leave open: its index on the solid as committed, its name when it is an original
/// extrusion face (names survive depth edits), and a point on it for any other face.
struct ShellOpening: Equatable {
    var face: Int
    var name: ExtrusionFace?
    var point: SIMD3<Double>
}

/// A primitive being placed: where it stands and its sizes (see `PrimitiveKind.sizes`).
struct PrimitiveDraft: Equatable {
    var kind: PrimitiveKind
    var plane: SketchPlane
    var center: Point2
    var sizes: [Double]
}

/// A hole being placed on a face in sketch mode.
struct HoleDraft: Equatable, Sendable {
    var bodyID: UUID
    var plane: SketchPlane
    var center: Point2
    var spec: HoleSpec
    /// nil = through the solid.
    var depth: Double?
    /// Editing the hole at this step of the solid's `cuts` (Edit Hole) instead of adding one.
    var replacing: Int?
}

/// A peg being placed on a face in sketch mode; Done also cuts its socket in whatever it pushes into.
struct PegDraft: Equatable, Sendable {
    var bodyID: UUID
    var plane: SketchPlane
    var center: Point2
    var spec: PegSpec
    /// Editing this peg and its sockets (Edit Peg) instead of adding one.
    var editing: PegJoint.Existing?
}

/// A thread being set up on a hole or round boss. Its preview is built in the background (a long
/// thread takes about a second), and Done waits for it.
/// Screw Lid in progress: the neck's face and the lid's settings.
struct ScrewLidDraft: Equatable {
    var bodyID: UUID
    var face: Int
    var spec: ScrewLidSpec
}

struct ThreadDraft: Equatable {
    var bodyID: UUID
    var face: Int
    /// The thread along the whole face, with the chosen size, pitch, and options.
    var spec: ThreadSpec
    /// How much of the face is threaded, from the end it is screwed in at; nil for all of it.
    var length: Double?
    /// The thread is screwed in at the `ends.end` side of the face.
    var atEnd: Bool = true
    /// Editing the thread at this step of the solid's `cuts` (Edit Thread): `face` is then a face of
    /// the solid without it.
    var replacing: Int?

    /// What is cut: the spec cut short to `length`.
    var built: ThreadSpec? { length.map { spec.shortened(to: $0, atEnd: atEnd) } ?? spec }
    /// The length of face threaded.
    var threadedLength: Double { built?.threadedLength ?? spec.threadedLength }
}

/// A standard size in the Thread tool's Size menu: how it fits the face (a note such as "Best fit"
/// or "72% depth"), and whether it is the one in use.
struct ThreadSizeChoice: Equatable {
    var size: ThreadSize
    var title: String
    var note: String
    var fit: ThreadFit.Kind
    var inUse: Bool
    /// Fits the face as it is: a full or partial thread, not a resize or a miss.
    var fitsAsIs: Bool { fit == .full || fit == .partial }
}

/// Text being placed on a face in sketch mode. The outlines come from the font at once; the solid
/// preview is built in the background.
struct TextDraft: Equatable {
    var bodyID: UUID
    var plane: SketchPlane
    var center: Point2
    var text: String
    var font: String
    var height: Double
    /// How far the letters stand out (positive) or sink in (negative), in millimeters.
    var depth: Double
    var angle: Double
    var spec: TextSpec?
    /// Editing the text at this step of the solid's `cuts` (Edit Text) instead of adding it.
    var replacing: Int?
}

/// The section view (October 21, 2026): solids drawn cut away on one side of a plane parallel to
/// Top, Front, or Right, with their cut faces filled, to see inside a part. A view only: nothing in
/// the model changes, and it is not saved.
struct SectionView: Equatable, Sendable {
    /// The world plane the section plane is parallel to.
    var orientation: SketchPlane
    /// The side cut away: the one the orientation's normal points to, or (flipped) the other.
    var flipped = false
    /// How far from the origin, along the orientation's normal, the plane lies.
    var offset: Double
    /// Points toward the side that is cut away.
    var normal: SIMD3<Double> { orientation.normalAxis * (flipped ? -1 : 1) }
    var origin: SIMD3<Double> { orientation.origin + orientation.normalAxis * offset }
    var plane: SketchPlane { var plane = orientation; plane.origin = origin; return plane }
}

/// A live preview built off the main thread, one build at a time (November 9, 2026). The newest
/// waiting request replaces older ones, and each result is applied as it lands (it is newer than
/// what is shown) unless `drop()` was called after its request was taken: the operation ended,
/// was kept, or a value was built at once. With `inBackground` false (off screen, as in the app
/// tests, or a typed value that must be checked now) `submit` builds and applies at once.
@MainActor final class BackgroundPreview<Request: Sendable, Output: Sendable> {
    private let build: @Sendable (Request) -> Output
    private let apply: @MainActor (Output) -> Void
    private var pending: Request?
    private var task: Task<Void, Never>?
    private var epoch = 0

    init(build: @escaping @Sendable (Request) -> Output, apply: @escaping @MainActor (Output) -> Void) {
        self.build = build
        self.apply = apply
    }

    /// A build is waiting or running.
    var isBusy: Bool { task != nil || pending != nil }

    func submit(_ request: Request, inBackground: Bool) {
        guard inBackground else {
            drop()
            apply(build(request))
            return
        }
        pending = request
        if task == nil { start() }
    }

    /// Builds `request` now when the background has not caught up (Done keeps the final value).
    func settle(_ request: () -> Request?) {
        guard isBusy else { return }
        drop()
        if let request = request() { apply(build(request)) }
    }

    /// A result on its way no longer fits: it is not applied.
    func drop() {
        epoch += 1
        pending = nil
    }

    /// Waits for the builds to finish (tests).
    func settled() async {
        while isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func start() {
        guard let request = pending else { task = nil; return }
        pending = nil
        let epoch = epoch, build = build
        task = Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) { build(request) }.value
            guard let self else { return }
            if epoch == self.epoch { self.apply(output) }
            self.task = nil
            self.start()
        }
    }
}

/// What a Fillet or Chamfer preview is built from.
struct FinishPreviewRequest: Sendable {
    var base: Workspace
    var draft: FinishDraft
}

/// What a Revolve preview is built from.
struct RevolvePreviewRequest: Sendable {
    var base: Workspace
    var draft: RevolveDraft
}

/// A Revolve preview as built: the draft it was built for (with the mode the result decided), the
/// solids changed, and the swept tool. `error` is nil when it leaves the message as it was (no axis
/// or angle yet), and `.some(nil)` when it clears it.
struct RevolvePreviewOutput: @unchecked Sendable {
    var draft: RevolveDraft
    var preview: Workspace?
    var cutTargets: [UUID] = []
    var joinTarget: UUID?
    var tool: KernelSolid?
    var error: String??
    /// The swept tool was built, so `draft.mode` is the mode the result decided.
    var decidedMode = false
}

/// What a Shell preview is built from.
struct ShellPreviewRequest: Sendable {
    var base: Workspace
    var draft: ShellDraft
}

/// What a Delete Face preview is built from.
struct DeleteFacePreviewRequest: Sendable {
    var base: Workspace
    var draft: DeleteFaceDraft
}

/// What a Scale preview is built from.
struct ScalePreviewRequest: Sendable {
    var base: Workspace
    var draft: ScaleDraft
}

/// What a Draft, Rib, Loft, or Sweep preview is built from: the tool in use and its picks.
struct ShapeToolRequest: Sendable {
    var base: Workspace
    var tool: ModelingTool
    var draft: ShapeToolDraft
}

/// A Draft, Rib, Loft, or Sweep preview as built: the picks it was built for, why it could not be
/// made (if so), and the model with it.
struct ShapeToolOutput: Sendable {
    var draft: ShapeToolDraft
    var error: String?
    var preview: Workspace?
}

/// What a Hole preview is built from.
struct HolePreviewRequest: Sendable {
    var base: Workspace
    var draft: HoleDraft
}

/// What a Peg preview is built from.
struct PegPreviewRequest: Sendable {
    var base: Workspace
    var draft: PegDraft
}

/// What a Mirror preview is built from.
struct MirrorPreviewRequest: Sendable {
    var base: Workspace
    var draft: MirrorDraft
}

/// Why a typed value was not applied: the message shown under the keypad, or nil when the value
/// is simply refused.
struct DimensionRefusal: Error {
    var message: String?
}

/// What a Subtract, Union or Intersect, or Split Body preview is built from (November 10, 2026:
/// a pick on a detailed solid rebuilds it, so they are built off the main thread like the drags).
struct SubtractPreviewRequest: Sendable {
    var base: Workspace
    var draft: SubtractDraft
}

struct UnionPreviewRequest: Sendable {
    var base: Workspace
    var draft: UnionDraft
}

struct SplitPreviewRequest: Sendable {
    var base: Workspace
    var draft: SplitDraft
}

/// A Subtract, Union, or Split preview as built: the workspace with the result (nil when it
/// cannot be built), why not, and for Split the number of pieces.
struct CombinePreviewOutput: Sendable {
    var preview: Workspace?
    var error: String?
    var count = 0
}

/// What an Extrude preview is built from: a snapshot taken on the main thread, so it can be built on another.
struct CutPreviewRequest: Sendable {
    var base: Workspace
    var face: FaceExtrusionSource?
    var cuts: [ExtrusionCut] = []
    var joins: [ExtrusionCut] = []
    var automatic = true
    var mode = ExtrusionMode.newBody
    var cutThroughAll = false
    /// The new solids a New Body extrusion with options or several regions makes, for its preview.
    var toolBodies: [SolidBody]?
    var depth: Double
}

/// An Extrude preview as built, or nil when the extrusion cannot be made.
struct CutPreviewResult: @unchecked Sendable {
    var built: (mode: ExtrusionMode, preview: Workspace?, cutTargets: [UUID], joinTarget: UUID?, tool: KernelSolid?)?
}

/// The polygon just drawn, while its number of sides and radius can still be typed (as the same undo step).
struct PolygonRecord: Equatable {
    var base: Workspace
    var center: Point2
    var vertex: Point2
    var plane: SketchPlane
    var sides: Int
    var result: Workspace
    /// From the center to a corner.
    var radius: Double { center.distance(to: vertex) }
}

/// Offset in progress: the shape (and the chain joined to it) and how far the new outline lies.
struct OffsetDraft: Equatable {
    var shapeID: UUID
    /// Outward (or to the right of an open chain) when positive.
    var distance: Double
    /// Both ways at once, a wall around the outline.
    var bothSides = false
    /// Rounded outside corners instead of sharp ones.
    var rounded = false
}

/// Mirror inside a sketch: the shapes to copy and the line to copy them across.
struct SketchMirrorDraft: Equatable {
    enum Step: Equatable { case shapes, line }
    var shapes: [UUID] = []
    var line: UUID?
    var step = Step.shapes
}

/// Faces picked to take off one solid with Delete Face.
struct DeleteFaceDraft: Equatable {
    var bodyID: UUID
    /// Each face's index on the committed solid and a point on it.
    var faces: [ShellOpening]
}

/// Edges picked for a fillet or chamfer that has not been committed yet.
struct FinishDraft: Equatable {
    var bodyID: UUID
    var kind: EdgeFinish.Kind
    var edges: [PickedEdge]
    var size: Double
}

/// The sketch corner just rounded with Fillet: what it was before, so the keypad can change the
/// radius as the same undo step.
struct CornerRecord: Equatable {
    var base: Workspace
    var vertex: Point2
    var sketch: UUID
    var radius: Double
    var arc: UUID
    var result: Workspace
}

/// The Dimension tool's picks: the first stays, the second moves to a typed value.
struct DimensionDraft: Equatable {
    var first: SketchReference?
    var second: SketchReference?
}

/// A row in the Items list: a solid, a sketch, or one sketch shape (indented under its sketch).
/// Names number each kind in document order ("Body 01", "Sketch 01", "Rectangle 02"); they are
/// derived, not saved. Solids and sketches can be hidden.
struct ModelItem: Identifiable, Equatable {
    var selection: ModelSelection
    var name: String
    var icon: SSIcon
    var indent = 0
    /// Nil for rows that cannot be hidden (shapes follow their sketch).
    var isHidden: Bool?
    /// Inside a hidden group: off the canvas whatever its own eye says.
    var isHiddenByGroup = false
    /// A group row: how many items sit directly in it (a sketch row: how many shapes), and whether
    /// its contents are folded away.
    var memberCount: Int?
    var isCollapsed = false
    /// Off the canvas, by its own eye or a group's.
    var isOffCanvas: Bool { isHidden == true || isHiddenByGroup }
    /// Unique across rows (an implicit sketch can share its first shape's UUID), unlike names.
    var id: String {
        switch selection {
        case .body(let id): "body." + id.uuidString
        case .sketch(let id): "sketch." + id.uuidString
        case .shape(let id): "shape." + id.uuidString
        case .plane(let id): "plane." + id.uuidString
        case .group(let id): "group." + id.uuidString
        default: name
        }
    }
}

/// Items under one heading: the solids, or the sketches on one plane.
struct ModelItemGroup: Identifiable, Equatable {
    var title: String
    var items: [ModelItem]
    var id: String { title }
}

/// A finished export file waiting to be shared.
struct ExportItem: Identifiable {
    let id = UUID()
    var url: URL
}

struct DimensionEdit: Identifiable {
    let id = UUID()
    var target: DimensionTarget
    var value: Double
    var anchor: CGPoint
}

@MainActor @Observable final class ModelingSession {
    let access: AppAccessStore
    var showPurchaseOffer = false
    /// One operation already underway may finish after expiration. New operations always consult
    /// `requireNewEditingAccess`, even while this continuation can commit its single undo step.
    private var canFinishAuthorizedEdit = false
    @ObservationIgnored private var hadEditingAccess = false
    @ObservationIgnored private var accessObservation: AnyCancellable?
    /// Counts changes to the access state. The store is not observed through the session, so
    /// everything here that asks whether editing is allowed reads this too, and views that ask
    /// redraw when the trial ends or a purchase goes through.
    private var accessRevision = 0
    var hasEditingAccess: Bool { _ = accessRevision; return access.canEdit }
    @discardableResult func requireNewEditingAccess() -> Bool {
        access.refreshClock()
        guard hasEditingAccess else { showPurchaseOffer = true; return false }
        return true
    }
    private var purchaseBlocksEditing: Bool { !hasEditingAccess && !canFinishAuthorizedEdit }

    private var editingOperationPending: Bool {
        isPencilDown || dragContext != nil || transformDrag != nil || trimBase != nil ||
            dimensionEdit != nil && dimensionEdit?.target != .sectionOffset || isResizingDimension ||
            isAssistantBusy || isImportingGeometry || isDeletingHole || isDeletingFinish || isMakingMatingPart || isBuildingScrewLidTest ||
            hasOperationInProgress && section == nil && tool != .measure
    }
    private func accessChanged(_ state: AppAccessState) {
        if hadEditingAccess && !state.canEdit {
            canFinishAuthorizedEdit = editingOperationPending
            // Flush already accepted typing, then close the notebook to further keystrokes.
            endEditingNotes()
            save()
            if !canFinishAuthorizedEdit {
                cancelTransient()
                endSketchMode()
                tool = .select
            }
        }
        if state.canEdit { canFinishAuthorizedEdit = false }
        hadEditingAccess = state.canEdit
        accessRevision += 1
    }
    private var isImportingGeometry = false
    private func finishExpiredPencilOperation() {
        guard !hasEditingAccess, !editingOperationPending else { return }
        canFinishAuthorizedEdit = false
        cancelTransient()
        endSketchMode()
        tool = .select
    }
    let viewCube = ViewCubeState()
    private(set) var history: WorkspaceHistory
    private(set) var isResizingDimension = false
    /// What the keypad says while `isResizingDimension`.
    private(set) var resizingProgress = "Resizing face…"
    var tool: ModelingTool = .select
    var plane: SketchPlane = .top { didSet { if plane.isWorldPlane { lastWorldPlane = plane } } }
    /// The world plane to return to when sketching on a face ends, so the grid goes back to the floor.
    @ObservationIgnored private var lastWorldPlane = SketchPlane.top
    var selection: ModelSelection? {
        didSet {
            // The assistant hears of the new selection before the extra picks it ends.
            if selection != oldValue { notifySelectionObservers(.selection) }
            if let pivot = transformPivot, selection != .body(pivot.bodyID) { transformPivot = nil }
            if selection != oldValue, !extraSelection.isEmpty { extraSelection = [] }
        }
    }
    /// More items picked along with `selection`: sketch regions and whole sketches on the same plane
    /// (a tap adds one, a tap on a picked one takes it out; Extrude and Revolve take them all),
    /// regions inside an open sketch, whole solids (a double-tap adds one), or edges of one solid
    /// (Fillet and Chamfer take them all). Any other change of selection ends it.
    private(set) var extraSelection: [ModelSelection] = [] {
        didSet { if extraSelection != oldValue { notifySelectionObservers(.extraSelection) } }
    }
    /// What changed, for those following the selection (the assistant's label of it).
    enum SelectionChange { case selection, extraSelection, assistantPreview }
    @ObservationIgnored private var selectionObservers: [(SelectionChange) -> Void] = []
    /// Calls `observer` after each change of `selection` or `extraSelection` (when the value is new)
    /// and after every assignment of `assistantPreview`, the new values already in place.
    func observeSelection(_ observer: @escaping (SelectionChange) -> Void) { selectionObservers.append(observer) }
    private func notifySelectionObservers(_ change: SelectionChange) {
        for observer in selectionObservers { observer(change) }
    }
    /// The shape being drawn, and the snap label beside the Pencil: only the canvas shows them, and
    /// they change on every Pencil sample, so they are not observed (each publication redrew the
    /// whole editor, November 8, 2026). The canvas redraws when they change (`onLiveCanvasChange`).
    @ObservationIgnored var preview: SketchShape? { didSet { if preview != oldValue { onLiveCanvasChange?() } } }
    @ObservationIgnored var onLiveCanvasChange: (() -> Void)?
    var extrusionDepth = 0.0 { didSet { updateCutPreview() } }
    var isExtruding = false {
        didSet {
            guard !isExtruding else { return }
            cutPreviews.drop()
            if faceExtrusion != nil { faceExtrusion = nil }
            if isPickingExtrusionTarget { isPickingExtrusionTarget = false }
            if !extraExtrusionProfiles.isEmpty { extraExtrusionProfiles = [] }
            if extrusionTool != nil { extrusionTool = nil }
        }
    }
    /// The solid face being pushed out or pulled in, when extruding a face instead of a sketch.
    private(set) var faceExtrusion: FaceExtrusionSource?
    var extrusionMode = ExtrusionMode.newBody { didSet { updateCutPreview() } }
    /// Until the user picks New Body, Join, or Cut, the mode follows the drag: into a solid cuts it.
    private(set) var extrusionModeIsAutomatic = true
    @ObservationIgnored private var updatingCutPreview = false
    /// Set by the canvas while it is on screen: previews that cut or join solids build off the main
    /// thread then. Off screen (tests), they are built at once.
    @ObservationIgnored var buildsPreviewsInBackground = false
    /// Previews built off the main thread on screen (`buildsPreviewsInBackground`).
    @ObservationIgnored private lazy var cutPreviews = BackgroundPreview<CutPreviewRequest, CutPreviewResult>(
        build: { Self.buildCutPreview($0) }, apply: { [weak self] in self?.applyCutPreview($0) })
    @ObservationIgnored private lazy var finishPreviews = BackgroundPreview<FinishPreviewRequest, (FinishDraft, SolidBody?)>(
        build: { Self.buildFinishPreview($0) }, apply: { [weak self] in self?.applyFinishPreview($0) })
    @ObservationIgnored private lazy var revolvePreviews = BackgroundPreview<RevolvePreviewRequest, RevolvePreviewOutput>(
        build: { Self.buildRevolvePreview($0) }, apply: { [weak self] in self?.applyRevolvePreview($0) })
    @ObservationIgnored private lazy var shellPreviews = BackgroundPreview<ShellPreviewRequest, (ShellDraft, Workspace?)>(
        build: { Self.buildShellPreview($0) }, apply: { [weak self] in self?.applyShellPreview($0) })
    @ObservationIgnored private lazy var deleteFacePreviews = BackgroundPreview<DeleteFacePreviewRequest, (DeleteFaceDraft, Workspace?)>(
        build: { Self.buildDeleteFacePreview($0) }, apply: { [weak self] in self?.applyDeleteFacePreview($0) })
    @ObservationIgnored private lazy var scalePreviews = BackgroundPreview<ScalePreviewRequest, (ScaleDraft, Workspace?)>(
        build: { Self.buildScalePreview($0) }, apply: { [weak self] in self?.applyScalePreview($0) })
    @ObservationIgnored private lazy var shapeToolPreviews = BackgroundPreview<ShapeToolRequest, ShapeToolOutput>(
        build: { Self.buildShapeToolPreview($0) }, apply: { [weak self] in self?.applyShapeToolPreview($0) })
    @ObservationIgnored private lazy var holePreviews = BackgroundPreview<HolePreviewRequest, (HoleDraft, Workspace?)>(
        build: { Self.buildHolePreview($0) }, apply: { [weak self] in self?.applyHolePreview($0) })
    @ObservationIgnored private lazy var pegPreviews = BackgroundPreview<PegPreviewRequest, (PegDraft, PegJoint.Result?)>(
        build: { Self.buildPegPreview($0) }, apply: { [weak self] in self?.applyPegPreview($0) })
    @ObservationIgnored private lazy var mirrorPreviews = BackgroundPreview<MirrorPreviewRequest, (MirrorDraft, Workspace?)>(
        build: { Self.buildMirrorPreview($0) }, apply: { [weak self] in self?.applyMirrorPreview($0) })
    @ObservationIgnored private lazy var subtractPreviews = BackgroundPreview<SubtractPreviewRequest, CombinePreviewOutput>(
        build: { Self.buildSubtractPreview($0) }, apply: { [weak self] in self?.applySubtractPreview($0) })
    @ObservationIgnored private lazy var unionPreviews = BackgroundPreview<UnionPreviewRequest, CombinePreviewOutput>(
        build: { Self.buildUnionPreview($0) }, apply: { [weak self] in self?.applyUnionPreview($0) })
    @ObservationIgnored private lazy var splitPreviews = BackgroundPreview<SplitPreviewRequest, CombinePreviewOutput>(
        build: { Self.buildSplitPreview($0) }, apply: { [weak self] in self?.applySplitPreview($0) })
    var cutThroughAll = false { didSet { updateCutPreview() } }
    /// Extrude options (October 21, 2026): both ways from the sketch plane, and the sides' taper in
    /// degrees (positive narrows toward the far end).
    var extrusionSymmetric = false { didSet { if oldValue != extrusionSymmetric { updateCutPreview() } } }
    private(set) var extrusionTaper = 0.0
    /// Up To: the next tap on a flat face or plane parallel to the sketch sets the depth to reach it.
    var isPickingExtrusionTarget = false
    /// More regions extruded together with the selected one.
    private(set) var extraExtrusionProfiles: [SketchProfile] = []
    /// What a new-body extrusion with options or several regions adds, for its preview.
    private(set) var extrusionTool: KernelSolid?
    /// The workspace with the pending cut (every solid it removes material from) or join applied.
    private(set) var operationPreview: Workspace?
    /// Solids the pending cut touches, in document order.
    private(set) var cutTargets: [UUID] = []
    /// The solid a pending join (boss) merges into.
    private(set) var joinTarget: UUID?
    var snapEnabled = true
    /// The gap new fits start with, in millimeters on each side (an app preference, since it depends
    /// on the printer; operations save the value they were built with).
    var fitClearance = Fit.preferredClearance {
        didSet { Fit.preferredClearance = fitClearance }
    }
    /// "Standard · 0.2 mm": a clearance as the user reads it.
    func fitText(_ clearance: Double) -> String { "\(Fit.name(for: clearance)) · \(lengthText(clearance))" }
    /// Millimeters or inches for labels and the keypad (an app preference; files stay in millimeters).
    var lengthUnit = LengthUnit(rawValue: UserDefaults.standard.string(forKey: "lengthUnit") ?? "") ?? .millimeters {
        didSet { UserDefaults.standard.set(lengthUnit.rawValue, forKey: "lengthUnit") }
    }
    /// A length in millimeters as the user reads it: "12.5 mm" or "0.492 in".
    func lengthText(_ millimeters: Double) -> String { formatted(length: millimeters, unit: lengthUnit) + " " + lengthUnit.symbol }
    /// The sketch snapping grid: at most 1 mm (or 1/16 in), finer when zoomed in.
    var snapGrid: Double { lengthUnit.snapGrid(for: gridSpacing) }
    /// Rectangle tool option: drag from the center (kept centered when resized) instead of corner to corner.
    var rectangleFromCenter = false
    /// Slot tool option: drag from the slot's center to one round end's center (kept centered when
    /// resized) instead of from one end's center to the other's.
    var slotFromCenter = false
    /// The width new slots are drawn with (the last width typed).
    var slotWidth = 6.0
    /// The radius Fillet rounds sketch corners to (the last radius typed).
    var cornerRadius = 2.0
    /// The sketch corner just rounded, while its radius can still be typed.
    private(set) var lastCorner: CornerRecord?
    /// Dimension tool picks.
    private(set) var dimensionDraft: DimensionDraft?
    /// Measure picks: one item for its sizes, two for the distance and angle between them.
    private(set) var measureItems: [MeasureItem] = []
    /// The document before a Trim stroke started, while the Pencil is down.
    private var trimBase: Workspace?
    @ObservationIgnored var snapLabel = "" { didSet { if snapLabel != oldValue { onLiveCanvasChange?() } } }
    var gridSpacing = 5.0
    var status = "Ready"
    var saveError: String?
    var cameraRequest = 0
    var cameraAction: CameraAction = .align(.top)
    var showHelp = false
    var exportItem: ExportItem?
    /// The Export sheet (3MF or STL, shared or sent to the slicer), and how a 3MF's parts sit on the plate.
    var printSheet: PrintSheetMode?
    var printLayout = PrintLayout.stored { didSet { printLayout.store() } }
    /// The folder Export's Send to Slicer saves into (a slicer on a Mac can open it from iCloud Drive).
    var printFolderName = PrintFolder.name
    /// A picture of the canvas for the 3MF's preview (set by the canvas).
    @ObservationIgnored var thumbnailProvider: (() -> Data?)?
    /// The project's picture for the document browser: the whole model from the standard angle.
    @ObservationIgnored var projectThumbnailProvider: (() -> UIImage?)?
    var canExport: Bool { workspace.bodies.contains { !workspace.isHidden($0) } && !isProjectBusy && !isResizingDimension }
    var dimensionEdit: DimensionEdit?
    var isProjectBusy = false
    /// The AI assistant's proposed changes, shown on the canvas until kept (one undo step) or discarded.
    private(set) var assistantPreview: Workspace? { didSet { notifySelectionObservers(.assistantPreview) } }
    /// What to select once the assistant's changes are kept.
    @ObservationIgnored private var assistantFocus: AssistantItem?
    /// The assistant is working on a request; the document must not change under it.
    var isAssistantWorking = false
    /// Counts assistant resets: a request started before one must not show its changes.
    @ObservationIgnored private(set) var assistantEpoch = 0
    /// Called when the assistant's request and review end without keeping anything.
    @ObservationIgnored var onAssistantReset: (() -> Void)?
    private(set) var isReadOnly = false
    private(set) var editPreview: Workspace?
    private(set) var finishDraft: FinishDraft?
    private(set) var sketchMode: SketchMode?
    /// After Sketch is tapped with nothing selected: three translucent world planes wait for a tap.
    private(set) var isPickingPlane = false
    /// The Pencil is down on the canvas (a stroke or drag in progress); the dock ignores touches then.
    var isPencilDown = false {
        didSet { if oldValue && !isPencilDown { finishExpiredPencilOperation() } }
    }
    /// A finger tapped the canvas; menus floating over it put themselves away.
    let canvasTapped = PassthroughSubject<Void, Never>()
    /// Move/Rotate widget: each drag makes a copy (the original stays) while this is on.
    var transformCopies = false
    /// The sketch move or turn in progress (Pencil down on a widget handle).
    private(set) var transformDrag: TransformRecord?
    /// The last committed move or turn, whose amount the keypad can still change.
    private(set) var lastTransform: TransformRecord?
    /// A selected solid's widget center after it was dragged onto a corner, edge, or center of the
    /// solid: where it sits and its axes, for the solid as it was then. It lapses when the
    /// selection moves on or the solid changes any other way (Undo, an operation).
    private(set) var transformPivot: PlacedPivot?
    /// The widget center being dragged (Pencil down on it), and where it would land.
    private(set) var pivotDrag: PlacedPivot?
    private(set) var isDraggingPivot = false
    /// Offset Plane / Midplane in progress, and the plane it would make.
    private(set) var planeDraft: PlaneDraft?
    private(set) var constructionDraft: ConstructionDraft?
    private(set) var shapeToolDraft: ShapeToolDraft?
    private(set) var shapeToolPreview: Workspace?
    /// What Done makes: a construction plane, or an axis from one point to another.
    private(set) var constructionPreview: ConstructionPlane?
    private(set) var axisPreview: (from: SIMD3<Double>, to: SIMD3<Double>)?
    private(set) var planePreview: ConstructionPlane?
    /// Project in progress, the shapes it would add, and why it cannot (too many shapes).
    private(set) var projectionDraft: ProjectionDraft?
    private(set) var projectionPreview: [SketchShape] = []
    private(set) var projectionError: String?
    /// Split Body in progress, the workspace with the pieces, and how many pieces there are.
    private(set) var splitDraft: SplitDraft?
    private(set) var splitPreview: Workspace?
    private(set) var splitPieceCount = 0
    /// Why the picked tools do not split the solids.
    private(set) var splitError: String?
    /// Mirror in progress, and the workspace with the mirror images.
    private(set) var mirrorDraft: MirrorDraft?
    private(set) var mirrorPreview: Workspace?
    /// Edit Thread is setting the thread up again in the background.
    @ObservationIgnored private var isOpeningThread = false
    /// The Mirror preview for the current picks is being built.
    private(set) var isBuildingMirror = false
    /// Pattern in progress, the workspace with the copies, and whether its gizmo center is being dragged.
    private(set) var patternDraft: PatternDraft?
    private(set) var patternPreview: Workspace?
    private(set) var isDraggingPatternCenter = false
    /// Scale in progress, the workspace with the scaled items, and why it cannot be done.
    private(set) var scaleDraft: ScaleDraft?
    private(set) var scalePreview: Workspace?
    /// The Scale gizmo is being dragged: the solids follow on screen (`scaleGhost`) and are built when it is let go.
    private(set) var isDraggingScale = false
    private(set) var scaleError: String?
    /// The section view, while it is on.
    private(set) var section: SectionView?
    /// X-ray (October 24, 2026): every solid drawn see-through, or only these, so the inside of an
    /// enclosure shows. A view only, like Section: not saved and not an undo step.
    var xrayAll = false
    private(set) var xrayBodies: Set<UUID> = []
    func isXrayed(_ id: UUID) -> Bool { xrayAll || xrayBodies.contains(id) }
    /// Turns X-ray on or off for one solid, or every solid in a group.
    func toggleXray(_ item: ModelSelection) {
        let ids: [UUID]
        switch item {
        case .body(let id): ids = [id]
        case .group(let group): ids = workspace.contents(of: group).bodies
        default: return
        }
        guard !ids.isEmpty else { return }
        if ids.allSatisfy(xrayBodies.contains) { xrayBodies.subtract(ids) } else { xrayBodies.formUnion(ids) }
    }
    func isXrayed(_ item: ModelSelection) -> Bool {
        switch item {
        case .body(let id): return xrayBodies.contains(id)
        case .group(let group):
            let ids = workspace.contents(of: group).bodies
            return !ids.isEmpty && ids.allSatisfy(xrayBodies.contains)
        default: return false
        }
    }
    /// How many sides Polygon draws (the last number typed), and the polygon just drawn.
    var polygonSides = 6
    private(set) var lastPolygon: PolygonRecord?
    /// Offset in progress and the shapes it would add.
    private(set) var offsetDraft: OffsetDraft?
    private(set) var offsetPreview: [SketchShape] = []
    /// The distance Offset starts at (the last one typed).
    @ObservationIgnored private var lastOffsetDistance = 2.0
    /// Mirror inside a sketch in progress, and the shapes it would add.
    private(set) var sketchMirrorDraft: SketchMirrorDraft?
    private(set) var sketchMirrorPreview: Workspace?
    /// Delete Face in progress, the workspace without the faces, and why it cannot be done.
    private(set) var deleteFaceDraft: DeleteFaceDraft?
    private(set) var deleteFacePreview: Workspace?
    private(set) var deleteFaceError: String?
    /// The pattern preview's solid copies: the original each is a copy of, and its motion.
    private(set) var patternGhosts: [UUID: PatternGhost] = [:]
    /// Solids the canvas draws as another solid's picture, moved, instead of meshing them: pattern
    /// copies, and a solid (or its copy) being dragged with the Move/Rotate widget, so dragging a
    /// detailed solid such as a threaded one stays smooth (October 22, 2026); and the solids Align
    /// would move, while its offset arrow is dragged too (November 9, 2026).
    var previewGhosts: [UUID: PatternGhost] {
        if let draft = alignDraft, alignPreview != nil, let transform = alignTransform {
            var ghosts = patternGhosts
            for id in draft.bodies { ghosts[id] = PatternGhost(source: id, transform: transform) }
            return ghosts
        }
        guard let drag = transformDrag, let result = drag.result, abs(drag.amount) > 1e-9, let moved = drag.resultTarget else { return patternGhosts }
        var ghosts = patternGhosts
        for (source, id) in Self.movedBodies(from: drag.target, to: moved, base: drag.base, result: result) {
            ghosts[id] = PatternGhost(source: source, transform: drag.transform)
        }
        return ghosts
    }

    /// Each solid a move or turn carries, as (original, the solid that moved: itself or its copy).
    /// A group or several picked solids are ghosted too, not only one solid: rebuilding them on
    /// every step of a drag rendered each from scratch (10.6 s in 20 on the iPad, November 9, 2026).
    static func movedBodies(from target: TransformTarget, to moved: TransformTarget, base: Workspace, result: Workspace) -> [(UUID, UUID)] {
        switch (target, moved) {
        case (.body(let source), .body(let id)): return [(source, id)]
        case (.items(let sources, _), .items(let ids, _)) where sources.count == ids.count: return Array(zip(sources, ids))
        case (.group(let source), .group(let id)):
            // A copied group's solids are appended in the original's order (`appendCopies`).
            let sources = base.contents(of: source).bodies, ids = result.contents(of: id).bodies
            return sources.count == ids.count ? Array(zip(sources, ids)) : []
        default: return []
        }
    }
    /// The gizmo before its center drag, to go back to on cancel.
    @ObservationIgnored private var patternCenterStart: PatternDraft?
    private(set) var shellDraft: ShellDraft?
    private(set) var shellPreview: Workspace?
    private(set) var holeDraft: HoleDraft?
    private(set) var holePreview: Workspace?
    private(set) var primitiveDraft: PrimitiveDraft?
    private(set) var primitivePreview: Workspace?
    /// The sizes each primitive was last made with, for the next one.
    @ObservationIgnored private var lastPrimitiveSizes: [PrimitiveKind: [Double]] = [:]
    private(set) var textDraft: TextDraft?
    private(set) var textPreview: Workspace?
    private(set) var isBuildingText = false
    private(set) var textError: String?
    @ObservationIgnored private var textGeneration = 0
    /// The text build running, which the next waits for: Open CASCADE builds on one solid must not overlap.
    @ObservationIgnored private var textBuild: Task<Void, Never>?
    /// The last text's settings, for the next.
    @ObservationIgnored private var lastText = (text: "Text", font: TextFonts.defaultFont, height: 6.0, depth: 0.8)
    private(set) var threadDraft: ThreadDraft?
    private(set) var threadPreview: Workspace?
    private(set) var screwLidDraft: ScrewLidDraft?
    /// The model with the neck threaded and the lid added, and the lid's id there.
    private(set) var screwLidPreview: Workspace?
    private(set) var screwLidLid: UUID?
    private(set) var screwLidError: String?
    private(set) var isBuildingScrewLid = false
    private(set) var isBuildingScrewLidTest = false
    @ObservationIgnored private var screwLidGeneration = 0
    @ObservationIgnored private var screwLidBuild: Task<Void, Never>?
    private(set) var isBuildingThread = false
    private(set) var threadError: String?
    /// The thinnest wall a cut thread leaves behind it, when under a millimeter (0 when it cuts through).
    private(set) var threadWall: Double?
    /// A matching nut, cap, bolt, or plug is being built in the background.
    private(set) var isMakingMatingPart = false
    /// Bumped with each change, so a preview that finishes late for an older draft is dropped.
    @ObservationIgnored private var threadGeneration = 0
    /// The thread build running, which the next waits for: overlapping Open CASCADE booleans on one
    /// solid crashed in the simulator (REC-005), and quick menu changes would start many at once.
    @ObservationIgnored private var threadBuild: Task<Void, Never>?
    private(set) var pegDraft: PegDraft?
    private(set) var pegPreview: Workspace?
    /// Solids the pending peg sockets, in document order.
    private(set) var pegSockets: [UUID] = []
    /// The size of the last peg placed, for the next.
    @ObservationIgnored private var lastPeg = PegSpec()
    /// Why the current shell, hole, or peg cannot be built.
    private(set) var draftError: String?
    /// Union in progress, the workspace with the united solid, and why it cannot be built.
    private(set) var unionDraft: UnionDraft?
    private(set) var unionPreview: Workspace?
    private(set) var unionError: String?
    /// Align in progress, the workspace with the solids moved, and why it cannot be done.
    private(set) var alignDraft: AlignDraft?
    private(set) var alignPreview: Workspace?
    private(set) var alignError: String?
    /// Subtract in progress, the workspace with the result, and why it cannot be built.
    private(set) var subtractDraft: SubtractDraft?
    private(set) var subtractPreview: Workspace?
    private(set) var subtractError: String?
    /// Revolve in progress, the workspace with its join or cut, the swept tool, and why it cannot be built.
    private(set) var revolveDraft: RevolveDraft?
    private(set) var revolvePreview: Workspace?
    private(set) var revolveTool: KernelSolid?
    private(set) var revolveCutTargets: [UUID] = []
    private(set) var revolveJoinTarget: UUID?
    private(set) var revolveError: String?
    @ObservationIgnored private var lastShellThickness = 2.0
    @ObservationIgnored private var lastHole: (kind: HoleSpec.Kind, size: String) = (.simple, "M3")
    @ObservationIgnored private var guideCache: (plane: SketchPlane, face: FaceSelection?, bodies: [SolidBody], shapes: [SketchShape], guides: [SketchGuide])?
    /// The workspace with the draft finish applied, when the kernel can build it.
    private(set) var finishPreview: Workspace?
    /// Why the draft size does not fit, shown on the value label and keypad.
    private(set) var finishError: String?
    /// Reason the last keypad value was rejected, if more specific than the default.
    var dimensionError: String?
    @ObservationIgnored private var lastFinishSize: [EdgeFinish.Kind: Double] = [:]
    /// The edges of the last finish preview that built.
    @ObservationIgnored private var lastFinishPreviewEdges: [PickedEdge] = []
    private var dragContext: (original: Workspace, shape: SketchShape, handle: SketchHandle)?

    enum CameraAction { case align(SketchPlane), alignAt(SketchPlane, SIMD3<Double>), face(ViewCubeFace), home, reset }
    private let document: ProjectDocument?
    @ObservationIgnored var onOpenProjects: (() -> Void)?
    @ObservationIgnored var onNewProject: (() -> Void)?
    @ObservationIgnored var onSaveAs: (() -> Void)?
    var hasProjectFile: Bool { document != nil }
    /// Editing waits while the assistant works on a request or its changes are under review.
    var isEditingBlocked: Bool { isReadOnly || purchaseBlocksEditing || isViewingBlocked }
    /// Looking at the model (Measure, the section view) waits only for the project and the assistant;
    /// a read-only file still shows it.
    var isViewingBlocked: Bool { isProjectBusy || isResizingDimension || isAssistantWorking || assistantPreview != nil || isEditingNotes }
    /// The Pencil may still pick while measuring or moving the section's cut when editing is blocked.
    var acceptsPencil: Bool { !isEditingBlocked || !isViewingBlocked && (tool == .select || tool == .measure || section != nil) }
    /// Whether a dimension value can be typed: the section's offset changes only the view.
    func canEditDimension(_ target: DimensionTarget) -> Bool {
        if target == .sectionOffset { return !isViewingBlocked }
        guard !isEditingBlocked else { return false }
        return hasEditingAccess || dimensionEdit?.target == target || target.isOperationValue && hasOperationInProgress
    }

    var projectName: String { _ = documentRevision; return document?.fileURL.deletingPathExtension().lastPathComponent ?? "Untitled Project" }
    /// Counts changes the document reports (its state, a reload, a move), which the views of its
    /// name and state read through `projectName`.
    private var documentRevision = 0
    var workspace: Workspace { history.workspace }
    var displayWorkspace: Workspace { assistantPreview ?? editPreview ?? finishPreview ?? shellPreview ?? shapeToolPreview ?? primitivePreview ?? holePreview ?? pegPreview ?? threadPreview ?? screwLidPreview ?? textPreview ?? splitPreview ?? mirrorPreview ?? patternPreview ?? scalePreview ?? deleteFacePreview ?? sketchMirrorPreview ?? unionPreview ?? subtractPreview ?? alignPreview ?? revolvePreview ?? operationPreview ?? workspace }
    var isShelling: Bool { shellDraft != nil }
    var isPlacingHole: Bool { holeDraft != nil }
    var isPlacingPeg: Bool { pegDraft != nil }
    var isThreading: Bool { threadDraft != nil }
    var isPlacingText: Bool { textDraft != nil }
    /// The selected face is a hole's wall or a round boss's side, which can take a thread.
    /// A selected round boss (not a hole) can take a screw lid.
    var canScrewLidSelectedFace: Bool {
        guard canThreadSelectedFace else { return false }
        return selectionFact("screwLid") {
            guard let face = selectedFace, let body = workspace.bodies.first(where: { $0.id == face.bodyID }),
                  let solid = try? SolidKernel.solid(for: body) else { return false }
            return solid.cylinderSide(face.face) == 1
        }
    }

    var canThreadSelectedFace: Bool {
        guard !isEditingBlocked else { return false }
        return selectionFact("threadFace") {
            guard let face = selectedFace, face.plane == nil,
                  let body = workspace.bodies.first(where: { $0.id == face.bodyID }), let solid = try? SolidKernel.solid(for: body) else { return false }
            return solid.faceCylinder(face.face) != nil
        }
    }

    /// What the selection strip asks about the selection (a hole to delete, a thread to mate, its
    /// size), kept until the selection or the model changes: each answer asks the kernel, and the
    /// strip asked on every redraw of the editor, each Pencil sample of a drag included
    /// (November 8, 2026). Comparing an unchanged model is quick, as its arrays are the same storage.
    @ObservationIgnored private var selectionFacts: (selection: ModelSelection?, workspace: Workspace, values: [String: Any]) = (nil, Workspace(), [:])

    private func selectionFact<T>(_ key: String, _ compute: () -> T) -> T {
        if selectionFacts.selection != selection || selectionFacts.workspace != workspace {
            selectionFacts = (selection, workspace, [:])
        }
        if let known = selectionFacts.values[key], let value = known as? T { return value }
        let value = compute()
        selectionFacts.values[key] = value
        return value
    }
    /// The thread the selection points at, ready for a matching part: the selected face's (a thread's
    /// flank, crest, root, or lead-in), or a selected solid's only one.
    var selectedThread: (bodyID: UUID, cut: Int)? {
        guard !isEditingBlocked else { return nil }
        return selectionFact("thread") { () -> (bodyID: UUID, cut: Int)? in selectedThreadNow }
    }
    private var selectedThreadNow: (bodyID: UUID, cut: Int)? {
        if let face = selectedFace {
            guard face.plane == nil, let body = workspace.bodies.first(where: { $0.id == face.bodyID }), !body.matableThreads.isEmpty,
                  let solid = try? SolidKernel.solid(for: body), let cut = body.thread(atFace: face.face, of: solid) else { return nil }
            return (body.id, cut)
        }
        if let body = selectedBody, body.matableThreads.count == 1 { return (body.id, body.matableThreads[0]) }
        return nil
    }
    /// The parts that screw onto the selected thread, the likelier first.
    var matingChoices: [ThreadMate] {
        guard let target = selectedThread, let spec = workspace.bodies.first(where: { $0.id == target.bodyID })?.cuts[target.cut].thread else { return [] }
        return ThreadMate.choices(for: spec)
    }
    var isUniting: Bool { unionDraft != nil }
    var isCutting: Bool { isExtruding && extrusionMode == .cut }
    var isJoining: Bool { isExtruding && extrusionMode == .join }
    /// Done is available: a new body always, a cut or join only when it reaches a solid.
    var canConfirmExtrusion: Bool {
        // Through All needs no depth (it is 0 until dragged).
        let throughAll = extrusionMode == .cut && cutThroughAll
        guard isExtruding, throughAll || (extrusionDepth.isFinite && abs(extrusionDepth) >= 0.01 && abs(extrusionDepth) <= 10_000) else { return false }
        switch extrusionMode {
        case .newBody: return true
        case .cut: return !cutTargets.isEmpty
        case .join: return joinTarget != nil
        }
    }
    var isRevolving: Bool { revolveDraft != nil }
    /// Done is available: a new body once it builds, a cut or join only when it reaches a solid.
    var canConfirmRevolve: Bool {
        guard let draft = revolveDraft, draft.spec?.isValid == true, revolveTool != nil else { return false }
        switch draft.mode {
        case .newBody: return draft.face == nil
        case .cut: return !revolveCutTargets.isEmpty
        case .join: return revolveJoinTarget != nil
        }
    }
    var isFinishing: Bool { finishDraft != nil }
    var selectedFace: FaceSelection? {
        if case .face(let face) = selection { return face } else { return nil }
    }
    var canSketchOnSelectedFace: Bool { selectedFace?.plane != nil && !isEditingBlocked }
    /// The selected face's size: a round face's diameter, or a flat face's distance to the face
    /// behind where it was tapped, as built now. Typing a new one changes the solid (see FaceEditing).
    var selectedFaceSize: FaceEditing.Size? {
        // A fillet's or chamfer's face shows the finish's own size instead (selectedFinish).
        guard let face = selectedFace, let body = workspace.bodies.first(where: { $0.id == face.bodyID }), selectedFinish == nil, !isFindingFinish else { return nil }
        let point = face.point ?? face.center
        // Kept by shape only, so hiding, renaming, or recoloring the solid doesn't measure again.
        let shape = SolidCache.key(body)
        if let cache = faceSizeCache, cache.body == shape, cache.face == face.face, cache.point == point { return cache.size }
        let size = (try? SolidKernel.solid(for: body)).flatMap { FaceEditing.size(of: face.face, on: $0, at: point) }
        faceSizeCache = (shape, face.face, point, size)
        return size
    }
    @ObservationIgnored private var faceSizeCache: (body: SolidBody, face: Int, point: SIMD3<Double>, size: FaceEditing.Size?)?

    /// The fillet or chamfer that made the selected face, with its kind and size.
    var selectedFinish: (bodyID: UUID, source: FinishSource, kind: EdgeFinish.Kind, size: Double)? {
        // Read first: a search started below ends in the background, and the answer is seen through it.
        _ = finishRevision
        guard let face = selectedFace, let body = workspace.bodies.first(where: { $0.id == face.bodyID }),
              !body.finishes.isEmpty || body.cuts.contains(where: { $0.finish != nil }) else { return nil }
        let point = face.point ?? face.center
        // Kept by shape only: the search rebuilds the solid once per finish, and hiding it ran that again.
        let shape = SolidCache.key(body)
        guard let cache = finishCache, cache.body == shape, cache.point == point else {
            findFinish(of: body, shape: shape, at: point)
            return nil
        }
        guard let source = cache.source, let finish = body.finishKind(source) else { return nil }
        return (body.id, source, finish.kind, finish.size)
    }
    @ObservationIgnored private var finishCache: (body: SolidBody, point: SIMD3<Double>, source: FinishSource?)?

    /// Whether the selected face's fillet or chamfer is still being looked for; meanwhile
    /// `selectedFinish` is nil, and so are the face's own size and Edit (which a finish's face has not).
    var isFindingFinish: Bool {
        _ = finishRevision
        guard let search = finishSearch, let face = selectedFace, let body = workspace.bodies.first(where: { $0.id == face.bodyID }) else { return false }
        return search.point == (face.point ?? face.center) && search.body == SolidCache.key(body)
    }
    @ObservationIgnored private var finishSearch: (body: SolidBody, point: SIMD3<Double>)?
    /// Counts finished background searches, which `selectedFinish` and `isFindingFinish` read, so
    /// views asking about the selected face redraw when its finish is found.
    private var finishRevision = 0

    /// Looks for the finish that made the face at `point`. Faces no finish could have made (a flat
    /// face of a solid without chamfers, a hole's wall) are answered at once; otherwise the search,
    /// which builds the solid without each finish tried, runs in the background: on the main thread
    /// it stopped the app for 1.65 s on tapping a face of an 88-step solid (November 8, 2026).
    private func findFinish(of body: SolidBody, shape: SolidBody, at point: SIMD3<Double>) {
        if let search = finishSearch, search.body == shape, search.point == point { return }
        // Each try rebuilds the solid without one finish, holding the kernel meanwhile.
        let candidates = body.historySteps > SolidBody.longHistory ? [] : body.finishCandidates(atFace: point)
        guard !candidates.isEmpty else {
            finishCache = (shape, point, nil)
            return
        }
        finishSearch = (shape, point)
        Task.detached(priority: .userInitiated) { [weak self] in
            let source = body.finishSource(atFace: point, among: candidates)
            await self?.foundFinish(source, shape: shape, point: point)
        }
    }

    private func foundFinish(_ source: FinishSource?, shape: SolidBody, point: SIMD3<Double>) {
        guard let search = finishSearch, search.body == shape, search.point == point else { return }
        finishSearch = nil
        finishCache = (shape, point, source)
        finishRevision += 1
    }

    /// The face of a solid through `point`, as a selection.
    func faceSelection(bodyID: UUID, near point: SIMD3<Double>) -> FaceSelection? {
        guard let body = workspace.bodies.first(where: { $0.id == bodyID }), let solid = try? SolidKernel.solid(for: body),
              let face = solid.face(near: point, tolerance: 1e-3) else { return nil }
        let plane = solid.facePlane(face).flatMap { SketchPlane.through($0.origin, normal: $0.normal) }
        return FaceSelection(bodyID: bodyID, face: face, plane: plane, center: solid.faceCenter(face) ?? point, point: point)
    }
    var selectedConstructionPlane: ConstructionPlane? {
        guard case .plane(let id) = selection else { return nil }
        return displayWorkspace.constructionPlanes.first { $0.id == id }
    }
    /// What Offset Plane would start from: the selected flat face, sketch region, or plane.
    var selectedPlaneReference: PlaneReference? {
        if let plane = selectedConstructionPlane { return .construction(plane) }
        if let face = selectedFace, face.plane != nil, let body = workspace.bodies.first(where: { $0.id == face.bodyID }) {
            return .face(face.face, of: body)
        }
        if let profile = selectedProfile { return .profile(profile) }
        return nil
    }
    var selectedEdge: (bodyID: UUID, edge: PickedEdge)? {
        if case .edge(let body, let edge) = selection { return (body, edge) } else { return nil }
    }

    /// Rounds or bevels the selected edge: opens the Fillet or Chamfer draft with it picked.
    func finishSelectedEdge(_ kind: EdgeFinish.Kind) {
        guard let picked = selectedEdge, !isEditingBlocked else { return }
        let others = pickedEdges.dropFirst()
        chooseTool(kind == .fillet ? .fillet : .chamfer)
        toggleFinishEdge(bodyID: picked.bodyID, edge: picked.edge)
        for other in others { toggleFinishEdge(bodyID: other.bodyID, edge: other.edge) }
    }

    /// Purple snap anchors for the locked sketch plane: solid corners, edge midpoints, centers, and
    /// where other sketches and solid edges cross it.
    var sketchGuides: [SketchGuide] {
        guard let sketchMode, !isExtruding else { return [] }
        let visible = visibleWorkspace
        let bodies = visible.bodies, shapes = visible.shapes.filter { $0.plane != sketchMode.plane }
        if let cache = guideCache, cache.plane == sketchMode.plane, cache.face == sketchMode.face, cache.bodies == bodies,
           cache.shapes == shapes { return cache.guides }
        let guides = SketchGuides.guides(on: sketchMode.plane, bodies: bodies,
                                         face: sketchMode.face.map { ($0.bodyID, $0.face) }, shapes: shapes)
        guideCache = (sketchMode.plane, sketchMode.face, bodies, shapes, guides)
        return guides
    }
    /// Straight solid edges on the locked sketch plane, for the Dimension tool.
    var sketchGuideLines: [(Point2, Point2)] {
        guard let sketchMode, !isExtruding else { return [] }
        let bodies = visibleWorkspace.bodies
        if let cache = guideLineCache, cache.plane == sketchMode.plane, cache.bodies == bodies { return cache.lines }
        let lines = SketchGuides.lines(on: sketchMode.plane, bodies: bodies)
        guideLineCache = (sketchMode.plane, bodies, lines)
        return lines
    }
    @ObservationIgnored private var guideLineCache: (plane: SketchPlane, bodies: [SolidBody], lines: [(Point2, Point2)])?

    /// Whether the canvas offers a face sketch's area around its shapes (October 30, 2026): only while
    /// the face it was drawn on is still there as it was. Once the face changes (a pocket cut in it, the
    /// area itself pushed out or in), the face is picked there again. Judged on the model as kept, so a
    /// preview of the area's own extrusion never takes it away.
    func offersFaceArea(_ profile: SketchProfile) -> Bool {
        guard profile.isFaceArea else { return true }
        let visible = workspace.visible
        if faceAreaCache?.bodies != visible.bodies || faceAreaCache?.sketches != visible.sketches {
            faceAreaCache = (visible.bodies, visible.sketches, [:])
        }
        if let known = faceAreaCache?.live[profile.id] { return known }
        let live = Self.faceIsUnchanged(under: profile, in: visible)
        faceAreaCache?.live[profile.id] = live
        return live
    }
    @ObservationIgnored private var faceAreaCache: (bodies: [SolidBody], sketches: [Sketch], live: [String: Bool])?

    /// A solid face lies under the area with exactly the edges its sketch kept.
    private static func faceIsUnchanged(under profile: SketchProfile, in workspace: Workspace) -> Bool {
        let plane = profile.plane
        guard let kept = workspace.sketches.first(where: { $0.plane == plane && $0.faceEdges != nil })?.faceEdges else { return false }
        let point = plane.point(profile.insidePoint)
        for body in workspace.bodies {
            guard let solid = try? SolidKernel.solid(for: body), let face = solid.face(containing: point, normal: plane.normalAxis),
                  let edges = solid.faceEdges(face, on: plane) else { continue }
            // Lines and curves may run either way when the solid is rebuilt; arcs always run counterclockwise.
            func same(_ a: FaceEdge, _ b: FaceEdge) -> Bool {
                let ends = a.start.distance(to: b.start) < 1e-5 && a.end.distance(to: b.end) < 1e-5 ||
                    a.kind != .arc && a.start.distance(to: b.end) < 1e-5 && a.end.distance(to: b.start) < 1e-5
                return a.kind == b.kind && ends && a.points?.count == b.points?.count &&
                    (a.arcCenter == nil) == (b.arcCenter == nil) && (a.arcCenter.map { $0.distance(to: b.arcCenter!) < 1e-5 } ?? true)
            }
            return edges.count == kept.count && kept.allSatisfy { edge in edges.contains { same($0, edge) } }
        }
        return false
    }

    /// The document as the canvas shows it: the live preview with hidden sketches and solids left out.
    /// The canvas asks for this many times on each refresh, and with anything hidden it made new
    /// arrays each time, which also defeated the quick equality checks of the caches comparing it
    /// (November 8, 2026). Kept until the shown model changes; comparing an unchanged model is quick,
    /// as its arrays are the same storage.
    var visibleWorkspace: Workspace {
        let source = displayWorkspace
        if let visibleMemo, visibleMemo.source == source { return visibleMemo.visible }
        let visible = source.visible
        visibleMemo = (source, visible)
        return visible
    }
    @ObservationIgnored private var visibleMemo: (source: Workspace, visible: Workspace)?
    /// Closed regions of the visible sketches on the current plane.
    var profiles: [SketchProfile] { visibleWorkspace.profiles.filter { $0.plane == plane } }
    var selectedShape: SketchShape? {
        guard case .shape(let id) = selection else { return nil }
        return displayWorkspace.shapes.first { $0.id == id }
    }
    var selectedBody: SolidBody? {
        guard case .body(let id) = selection else { return nil }
        return displayWorkspace.bodies.first { $0.id == id }
    }
    var selectedProfile: SketchProfile? { profile(for: selection) }
    /// The region a selected region or shape stands for.
    func profile(for item: ModelSelection?) -> SketchProfile? {
        if case .profile(let id) = item {
            return displayWorkspace.sketches.lazy.flatMap { self.displayWorkspace.profiles(in: $0) }.first { $0.id == id }
        }
        if case .shape(let id) = item, let shape = displayWorkspace.shapes.first(where: { $0.id == id }), let sketch = displayWorkspace.sketch(shape.sketch) {
            let regions = displayWorkspace.profiles(in: sketch)
            // A selected closed shape is all of it, as drawn, even where other shapes divide it (a tap
            // inside picks one of the pieces); an open one is the smallest region it bounds.
            if let own = regions.first(where: { $0.id == shape.id.uuidString }) { return own }
            if shape.isClosed {
                let own = shape.ownRegion
                let whole = SketchProfile(id: shape.id.uuidString, plane: shape.plane, sourceIDs: [shape.id], outline: own.outline,
                                          circle: own.circle, arcs: own.arcs, ellipse: own.ellipse)
                return whole.isSolidProfile ? whole : nil
            }
            return regions.first { $0.sourceIDs.contains(shape.id) }
        }
        return nil
    }
    /// A whole sketch, selected from the Model Tree, by leaving it, by Whole Sketch, or by
    /// double-tapping a line whose chain is all of it.
    var selectedSketch: Sketch? {
        guard case .sketch(let id) = selection else { return nil }
        return displayWorkspace.sketch(id)
    }
    /// The shapes of a selected chain, in document order.
    var selectedChain: [SketchShape]? {
        guard case .chain(let ids) = selection else { return nil }
        let shapes = displayWorkspace.shapes.filter { ids.contains($0.id) }
        return shapes.isEmpty ? nil : shapes
    }

    /// Everything picked: the selection, then the sketch items picked with it.
    var selectedItems: [ModelSelection] { (selection.map { [$0] } ?? []) + extraSelection }
    var isMultipleSelection: Bool { !extraSelection.isEmpty }

    /// The regions a picked sketch item stands for: a region or closed shape, or every region of a whole sketch.
    func profiles(for item: ModelSelection) -> [SketchProfile] {
        switch item {
        // A whole sketch is what is drawn in it, not the face around it.
        case .sketch(let id): displayWorkspace.sketch(id).map { displayWorkspace.profiles(in: $0).filter { $0.isSolidProfile && !$0.isFaceArea } } ?? []
        case .shape, .profile: profile(for: item).map { [$0] } ?? []
        // A chain is the regions it closes on its own: those whose outline runs only along it.
        case .chain(let ids):
            displayWorkspace.sketch(sketchID(of: item)).map { sketch in
                displayWorkspace.profiles(in: sketch).filter { $0.isSolidProfile && !$0.isFaceArea && Set($0.sourceIDs).isSubset(of: ids) }
            } ?? []
        default: []
        }
    }

    /// Every region picked, each once, in the order picked.
    var selectedProfiles: [SketchProfile] {
        var seen = Set<String>()
        return selectedItems.flatMap(profiles(for:)).filter { seen.insert($0.id).inserted }
    }

    /// The sketch a picked region, shape, or whole sketch belongs to.
    func sketchID(of item: ModelSelection) -> UUID? {
        switch item {
        case .sketch(let id): return id
        case .shape(let id): return displayWorkspace.shapes.first { $0.id == id }?.sketch
        case .chain(let ids): return ids.first.flatMap { id in displayWorkspace.shapes.first { $0.id == id }?.sketch }
        case .profile: return profile(for: item)?.sourceIDs.first.flatMap { id in displayWorkspace.shapes.first { $0.id == id }?.sketch }
        default: return nil
        }
    }

    /// The plane of a sketch region or whole sketch; nil for anything else.
    private func sketchPickPlane(_ item: ModelSelection) -> SketchPlane? {
        switch item {
        case .sketch(let id): displayWorkspace.sketch(id)?.plane
        case .shape, .profile: profile(for: item)?.plane
        default: nil
        }
    }

    /// The same plane, facing the same way, however it was made (two sketches on one face).
    static func isSamePlane(_ a: SketchPlane, _ b: SketchPlane) -> Bool {
        a == b || simd_dot(a.normalAxis, b.normalAxis) > 1 - 1e-9 && abs(a.height(of: b.origin)) < 1e-6
    }

    /// Whether a tap on `item` adds it to the picked sketch items (or takes it out) instead of
    /// selecting it alone: no tool or sketch is open, a region or whole sketch is selected, and
    /// `item` is one on the same plane.
    func addsToSelection(_ item: ModelSelection) -> Bool {
        // Inside an open sketch, regions add too (October 24, 2026); a whole sketch is picked outside one.
        if sketchMode != nil, case .sketch = item { return false }
        guard tool == .select, !hasOperationInProgress, let first = selection,
              let plane = sketchPickPlane(first), let other = sketchPickPlane(item) else { return false }
        if !isMultipleSelection {
            // Alone, the selected item stays picked, and its own sketch's line still opens the sketch.
            if item == first { return false }
            if case .sketch(let id) = item, sketchID(of: first) == id { return false }
        }
        return Self.isSamePlane(plane, other)
    }

    /// A Pencil tap on a sketch region, or outside a sketch on a sketch's line (`.sketch`): adds it
    /// to the picked items or takes it out again when `addsToSelection`, else selects it alone. A
    /// whole sketch takes the place of its regions already picked.
    func pickSketchItem(_ item: ModelSelection) {
        guard addsToSelection(item) else { select(item); return }
        dimensionEdit = nil
        var items = selectedItems
        // The face around a face sketch is not part of the whole sketch: it is picked beside it.
        func isFaceArea(_ item: ModelSelection) -> Bool { if case .profile = item { profile(for: item)?.isFaceArea == true } else { false } }
        if let index = items.firstIndex(of: item) {
            items.remove(at: index)
        } else if case .sketch(let id) = item {
            items.removeAll { sketchID(of: $0) == id && !isFaceArea($0) }
            items.append(item)
        } else if !isFaceArea(item), let sketch = sketchID(of: item), items.contains(.sketch(sketch)) {
            status = "\(sketchName(of: sketch) ?? "That sketch") is already picked whole"
            return
        } else {
            items.append(item)
        }
        selection = items.first
        extraSelection = Array(items.dropFirst())
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Several solids or edges (October 24, 2026)

    /// The solids picked together: with a whole solid selected, a double-tap on another adds it (a
    /// double-tap on a picked one takes it out). Faces stay single, so a tap still moves to a face.
    var pickedBodies: [UUID] {
        let items = selectedItems
        let ids = items.compactMap { item -> UUID? in if case .body(let id) = item { id } else { nil } }
        return ids.count == items.count ? ids : []
    }
    /// Edges of one solid picked together: with an edge selected, a tap on another edge of the same
    /// solid adds it (a tap on a picked one takes it out), for Fillet and Chamfer.
    var pickedEdges: [(bodyID: UUID, edge: PickedEdge)] {
        let items = selectedItems
        let edges = items.compactMap { item -> (UUID, PickedEdge)? in if case .edge(let body, let edge) = item { (body, edge) } else { nil } }
        return edges.count == items.count ? edges.map { (bodyID: $0.0, edge: $0.1) } : []
    }

    /// A double-tap on solid `id`: added to the solids picked before the tap (`before`, the
    /// selection before the double-tap's first tap) or taken out of them, else selected alone.
    func pickBody(_ id: UUID, after before: [ModelSelection]) {
        let picked = before.compactMap { item -> UUID? in if case .body(let id) = item { id } else { nil } }
        guard tool == .select, sketchMode == nil, !hasOperationInProgress, !picked.isEmpty, picked.count == before.count,
              picked != [id] else { select(.body(id)); return }
        var items = picked
        if let index = items.firstIndex(of: id) { items.remove(at: index) } else { items.append(id) }
        dimensionEdit = nil
        selection = items.first.map { .body($0) }
        extraSelection = items.dropFirst().map { .body($0) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A tap on an edge: added to (or taken out of) the edges picked on the same solid, else selected alone.
    func pickEdge(_ bodyID: UUID, _ edge: PickedEdge) {
        let picked = pickedEdges
        guard tool == .select, sketchMode == nil, !hasOperationInProgress, !picked.isEmpty, picked.allSatisfy({ $0.bodyID == bodyID }),
              !(picked.count == 1 && picked[0].edge.index == edge.index) else { select(.edge(bodyID, edge)); return }
        var items = picked.map(\.edge)
        if let index = items.firstIndex(where: { $0.index == edge.index }) { items.remove(at: index) } else { items.append(edge) }
        dimensionEdit = nil
        selection = items.first.map { .edge(bodyID, $0) }
        extraSelection = items.dropFirst().map { .edge(bodyID, $0) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// "3 regions", "2 sketches", "2 sketches · 1 region": what is picked, for the strip and hint.
    var pickedSummary: String {
        if pickedBodies.count > 1 { return "\(pickedBodies.count) solids" }
        if pickedEdges.count > 1 { return "\(pickedEdges.count) edges" }
        let sketches = selectedItems.filter { if case .sketch = $0 { true } else { false } }.count
        let regions = selectedItems.count - sketches
        let sketchText = "\(sketches) \(sketches == 1 ? "sketch" : "sketches")", regionText = "\(regions) \(regions == 1 ? "region" : "regions")"
        if sketches == 0 { return regionText }
        return regions == 0 ? sketchText : sketchText + " · " + regionText
    }

    /// Keeps the picked items the canvas still shows (none hidden or deleted); the first left leads.
    private func keepShownPicks() {
        let kept = selectedItems.filter { item in
            switch item {
            case .body(let id), .edge(let id, _):
                return workspace.bodies.contains { $0.id == id } && !workspace.isHidden(body: id)
            default:
                if let sketch = sketchID(of: item), workspace.sketch(sketch) == nil || workspace.isHidden(sketch: sketch) { return false }
                return !profiles(for: item).isEmpty
            }
        }
        guard kept != selectedItems else { return }
        selection = kept.first
        extraSelection = Array(kept.dropFirst())
    }

    var canExtrude: Bool { !selectedProfiles.isEmpty }
    var canExtrudeSelectedFace: Bool { selectedFace?.plane != nil && !isEditingBlocked }
    /// What the extrusion handle and preview follow: the face being extruded, or the selected sketch region.
    /// A face being pushed or pulled shows and takes the size the solid ends up across it, not the
    /// distance moved: a 20 mm box pulled 5 mm reads 25 mm.
    var extrusionSizeBase: Double? { isExtruding ? faceExtrusion?.size : nil }
    /// The value beside the extrusion's double-arrow and in its keypad.
    var extrusionValue: Double { extrusionDepth + (extrusionSizeBase ?? 0) }
    /// The keypad's caption for `target`.
    func dimensionTitle(_ target: DimensionTarget) -> String { target == .extrusion && extrusionSizeBase != nil ? "Size" : target.title }
    var extrusionProfile: SketchProfile? { isExtruding ? faceExtrusion?.profile ?? selectedProfiles.first : selectedProfiles.first }

    /// The Model Tree: groups first, each with what is in it (folded away when collapsed), then
    /// the solids, planes, and sketches in no group. A sketch is followed by its shapes.
    var itemGroups: [ModelItemGroup] {
        // Built once for the model and what is folded, not on every redraw of the editor.
        if let memo = itemGroupsMemo, memo.workspace == workspace, memo.sketches == collapsedSketches, memo.groups == collapsedGroups { return memo.groups_ }
        let built = buildItemGroups()
        itemGroupsMemo = (workspace, collapsedSketches, collapsedGroups, built)
        return built
    }
    @ObservationIgnored private var itemGroupsMemo: (workspace: Workspace, sketches: Set<UUID>, groups: Set<UUID>, groups_: [ModelItemGroup])?

    private func buildItemGroups() -> [ModelItemGroup] {
        func number(_ index: Int) -> String { String(format: "%02d", index + 1) }
        let workspace = workspace
        var counts: [ShapeKind: Int] = [:]
        var shapeNames: [UUID: String] = [:]
        for shape in workspace.shapes {
            shapeNames[shape.id] = "\(shape.kind.title) \(number(counts[shape.kind, default: 0]))"
            counts[shape.kind, default: 0] += 1
        }
        // Imported solids keep the name of the file they came from.
        let bodyNames = workspace.bodyNames, planeNames = workspace.planeNames, sketchNames = workspace.sketchNames
        let groupNames = workspace.groupNames
        func body(_ body: SolidBody, _ indent: Int) -> ModelItem {
            ModelItem(selection: .body(body.id), name: bodyNames[body.id] ?? "Body", icon: .solid, indent: indent, isHidden: body.isHidden,
                      isHiddenByGroup: workspace.isGroupHidden(body.group))
        }
        func plane(_ plane: ConstructionPlane, _ indent: Int) -> ModelItem {
            ModelItem(selection: .plane(plane.id), name: planeNames[plane.id] ?? "Plane", icon: .plane, indent: indent, isHidden: plane.isHidden,
                      isHiddenByGroup: workspace.isGroupHidden(plane.group))
        }
        let foldedSketches = collapsedSketches
        // A sketch's row, then (unless folded away) its shapes.
        func sketch(_ sketch: Sketch, _ indent: Int) -> [ModelItem] {
            let byGroup = workspace.isGroupHidden(sketch.group)
            let shapes = workspace.shapes(in: sketch.id), folded = foldedSketches.contains(sketch.id) && !shapes.isEmpty
            let row = ModelItem(selection: .sketch(sketch.id), name: sketchNames[sketch.id] ?? "Sketch", icon: .sketch, indent: indent,
                                isHidden: sketch.isHidden, isHiddenByGroup: byGroup, memberCount: shapes.count, isCollapsed: folded)
            guard !folded else { return [row] }
            return [row] +
                shapes.map {
                    ModelItem(selection: .shape($0.id), name: shapeNames[$0.id] ?? $0.kind.title, icon: $0.isSpline ? .spline : Self.icon(for: $0.kind), indent: indent + 1,
                              isHiddenByGroup: byGroup || sketch.isHidden)
                }
        }
        let collapsed = collapsedGroups
        // A group's row, then (unless folded away) its groups, solids, planes, and sketches.
        func rows(in id: UUID, _ indent: Int) -> [ModelItem] {
            guard let group = workspace.group(id) else { return [] }
            var result = [ModelItem(selection: .group(id), name: groupNames[id] ?? "Group", icon: .group, indent: indent, isHidden: group.isHidden,
                                    isHiddenByGroup: workspace.isGroupHidden(group.parent), memberCount: workspace.members(of: id).count,
                                    isCollapsed: collapsed.contains(id))]
            guard !collapsed.contains(id) else { return result }
            for child in workspace.groups where child.parent == id { result += rows(in: child.id, indent + 1) }
            result += workspace.bodies.filter { $0.group == id }.map { body($0, indent + 1) }
            result += workspace.constructionPlanes.filter { $0.group == id }.map { plane($0, indent + 1) }
            result += workspace.sketches.filter { $0.group == id }.flatMap { sketch($0, indent + 1) }
            return result
        }
        var sections: [ModelItemGroup] = []
        if !workspace.groups.isEmpty {
            sections.append(ModelItemGroup(title: "Groups", items: workspace.groups.filter { $0.parent == nil }.flatMap { rows(in: $0.id, 0) }))
        }
        let looseBodies = workspace.bodies.filter { $0.group == nil }
        if !looseBodies.isEmpty { sections.append(ModelItemGroup(title: "Bodies", items: looseBodies.map { body($0, 0) })) }
        let loosePlanes = workspace.constructionPlanes.filter { $0.group == nil }
        if !loosePlanes.isEmpty { sections.append(ModelItemGroup(title: "Planes", items: loosePlanes.map { plane($0, 0) })) }
        let looseSketches = workspace.sketches.filter { $0.group == nil }
        if !looseSketches.isEmpty { sections.append(ModelItemGroup(title: "Sketches", items: looseSketches.flatMap { sketch($0, 0) })) }
        return sections
    }

    // MARK: Groups

    /// Groups folded away in the Model Tree (this session only; not saved, not undone).
    var collapsedGroups: Set<UUID> = []

    func toggleGroupCollapsed(_ id: UUID) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }

    /// Sketches whose shapes are folded away in the Model Tree (this session only, like groups).
    var collapsedSketches: Set<UUID> = []

    func toggleSketchCollapsed(_ id: UUID) {
        if collapsedSketches.contains(id) { collapsedSketches.remove(id) } else { collapsedSketches.insert(id) }
    }

    /// A folded sketch's row stands in for its hidden shape rows: whether one of them is highlighted
    /// (a region or shape of it picked on the canvas).
    func holdsHighlight(_ item: ModelItem) -> Bool {
        guard item.isCollapsed, case .sketch(let id) = item.selection else { return false }
        return workspace.shapes(in: id).contains { isHighlighted(ModelItem(selection: .shape($0.id), name: "", icon: .sketch)) }
    }

    /// What a Model Tree row puts in a group: a shape's row moves its sketch.
    func groupMember(_ item: ModelSelection) -> GroupMember? {
        switch item {
        case .body(let id): .body(id)
        case .sketch(let id): .sketch(id)
        case .plane(let id): .plane(id)
        case .group(let id): .group(id)
        case .shape(let id): workspace.shapes.first { $0.id == id }?.sketch.map { .sketch($0) }
        default: nil
        }
    }

    /// The group a row's item sits in.
    func group(of item: ModelSelection) -> UUID? { groupMember(item).flatMap(workspace.group(of:)) }

    /// Every group, as "Group 01 › Group 02", for Move to Group (leaving out `item` itself and the
    /// groups inside it, which it cannot go into).
    func groupChoices(for item: ModelSelection) -> [(id: UUID, title: String)] {
        let excluded: Set<UUID> = if case .group(let id) = item { workspace.groupAndDescendants(id) } else { [] }
        return workspace.groups.filter { !excluded.contains($0.id) }.map { ($0.id, workspace.groupPath($0.id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Row edits wait while the Pencil is down too: a drag commits the model it started from at lift.
    var canEditGroups: Bool { hasEditingAccess && !isEditingBlocked && !hasOperationInProgress && !isPencilDown }

    /// A new group (in `parent`), holding `item` when given (one undo step). Returns its id so the
    /// Model Tree can offer to name it.
    @discardableResult func newGroup(containing item: ModelSelection? = nil, in parent: UUID? = nil) -> UUID? {
        guard canEditGroups else { return nil }
        let members = item.flatMap(groupMember).map { [$0] } ?? []
        guard let made = workspace.addingGroup(in: parent ?? item.flatMap(group(of:)), containing: members) else { return nil }
        commit(made.workspace)
        collapsedGroups.remove(made.group)
        if let parent { collapsedGroups.remove(parent) }
        status = "Made \(workspace.groupNames[made.group] ?? "a group")"
        return made.group
    }

    /// Moves a row's item into a group, or out to the top of the tree (nil); one undo step. An item
    /// moved into a hidden group leaves the canvas.
    func move(_ item: ModelSelection, toGroup target: UUID?) {
        guard canEditGroups, let member = groupMember(item), workspace.group(of: member) != target,
              let next = workspace.moving([member], into: target) else { return }
        cancelTransient()
        commit(next)
        endHiddenSelection()
        status = target.map { "Moved into \(workspace.groupNames[$0] ?? "the group")" } ?? "Moved out of its group"
    }

    // MARK: Selecting several rows

    /// The Model Tree is picking rows to act on together (its Select button); the canvas
    /// selection is untouched.
    private(set) var isSelectingRows = false
    /// The rows picked, as what they stand for (a shape's row picks its sketch).
    private(set) var pickedRows: Set<GroupMember> = []

    func beginSelectingRows() {
        guard canEditGroups else { return }
        pickedRows = []
        isSelectingRows = true
    }

    func endSelectingRows() {
        isSelectingRows = false
        pickedRows = []
    }

    /// Drops picked rows whose items no longer exist (after an undo).
    private func prunePicked() {
        guard !pickedRows.isEmpty else { return }
        let alive = pickedRows.filter { member in
            switch member {
            case .body(let id): workspace.bodies.contains { $0.id == id }
            case .sketch(let id): workspace.sketch(id) != nil
            case .plane(let id): workspace.constructionPlanes.contains { $0.id == id }
            case .group(let id): workspace.group(id) != nil
            }
        }
        if alive != pickedRows { pickedRows = alive }
    }

    func isPicked(_ item: ModelSelection) -> Bool { groupMember(item).map(pickedRows.contains) ?? false }

    func togglePicked(_ item: ModelSelection) {
        guard isSelectingRows, let member = groupMember(item) else { return }
        if pickedRows.contains(member) { pickedRows.remove(member) } else { pickedRows.insert(member) }
    }

    /// What the picked rows act on: those not already inside a picked group.
    private var pickedMembers: [GroupMember] { workspace.outermost(pickedRows) }

    /// "3 selected", or "Select items" with none.
    var pickedTitle: String { pickedRows.isEmpty ? "Select items" : "\(pickedRows.count) selected" }

    /// Hide rather than Show: something picked is still on the canvas.
    var pickedIncludeShown: Bool {
        pickedRows.contains { member in
            switch member {
            case .body(let id): workspace.bodies.first { $0.id == id }?.isHidden == false
            case .sketch(let id): workspace.sketch(id)?.isHidden == false
            case .plane(let id): workspace.constructionPlanes.first { $0.id == id }?.isHidden == false
            case .group(let id): workspace.group(id)?.isHidden == false
            }
        }
    }

    /// Groups the picked rows can move into (not a picked group, or one inside it).
    var pickedGroupChoices: [(id: UUID, title: String)] {
        let excluded = pickedRows.reduce(into: Set<UUID>()) { set, member in
            if case .group(let id) = member { set.formUnion(workspace.groupAndDescendants(id)) }
        }
        return workspace.groups.filter { !excluded.contains($0.id) }.map { ($0.id, workspace.groupPath($0.id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// A new group holding the picked rows (where they all were, or at the top), one undo step.
    /// Returns it so the Model Tree can offer to name it.
    @discardableResult func groupPicked() -> UUID? {
        let members = pickedMembers
        guard canEditGroups, !members.isEmpty,
              let made = workspace.addingGroup(in: workspace.commonGroup(of: members), containing: members) else { return nil }
        commit(made.workspace)
        endSelectingRows()
        status = "Made \(workspace.groupNames[made.group] ?? "a group") with \(members.count) \(members.count == 1 ? "item" : "items")"
        return made.group
    }

    /// Moves the picked rows into a group, or out to the top of the tree (nil); one undo step.
    func movePicked(toGroup target: UUID?) {
        let members = pickedMembers
        guard canEditGroups, !members.isEmpty else { return }
        guard let next = workspace.moving(members, into: target) else {
            status = "A group cannot go inside itself"
            return
        }
        cancelTransient()
        commit(next)
        endHiddenSelection()
        endSelectingRows()
        status = target.map { "Moved \(members.count) into \(workspace.groupNames[$0] ?? "the group")" } ?? "Moved \(members.count) out of their groups"
    }

    /// Hides the picked rows (or shows them, when all are hidden); one undo step.
    func setPickedHidden(_ hidden: Bool) {
        let members = Array(pickedRows)
        guard canToggleVisibility, !members.isEmpty else { return }
        cancelTransient()
        commit(workspace.setting(members, hidden: hidden))
        endHiddenSelection()
    }

    /// Deletes the picked rows (a group with everything in it); one undo step.
    func deletePicked() {
        let members = pickedMembers
        guard canEditGroups, !members.isEmpty, let next = workspace.deleting(members) else { return }
        cancelTransient()
        if let sketch = sketchMode?.sketchID, next.sketch(sketch) == nil { endSketchMode(); tool = .select }
        commit(next)
        dropMissingSelection()
        endSelectingRows()
        status = "Deleted \(members.count) \(members.count == 1 ? "item" : "items")"
    }

    /// A row dragged onto a group row (or a section title, `nil`). While rows are picked, dragging
    /// one of them moves them all.
    @discardableResult func moveDropped(_ rowID: String, toGroup target: UUID?) -> Bool {
        let parts = rowID.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return false }
        let item: ModelSelection
        switch parts[0] {
        case "body": item = .body(id)
        case "sketch": item = .sketch(id)
        case "plane": item = .plane(id)
        case "group": item = .group(id)
        case "shape": item = .shape(id)
        default: return false
        }
        let before = workspace
        if isSelectingRows, let member = groupMember(item), pickedRows.contains(member) {
            movePicked(toGroup: target)
        } else {
            move(item, toGroup: target)
        }
        return workspace != before
    }

    /// Removes a group, keeping what was in it (one undo step).
    func ungroup(_ id: UUID) {
        guard canEditGroups, let next = workspace.ungrouping(id) else { return }
        let name = workspace.groupNames[id] ?? "the group"
        commit(next)
        collapsedGroups.remove(id)
        status = "Ungrouped \(name)"
    }

    /// Deletes a group and everything in it (one undo step).
    func deleteGroup(_ id: UUID) {
        guard canEditGroups, let next = workspace.deletingGroup(id) else { return }
        let contents = workspace.contents(of: id)
        cancelTransient()
        if let sketch = sketchMode?.sketchID, contents.sketches.contains(sketch) { endSketchMode(); tool = .select }
        let name = workspace.groupNames[id] ?? "the group"
        commit(next)
        dropMissingSelection()
        status = "Deleted \(name) and everything in it"
    }

    /// Ends a selection or sketch the canvas no longer shows (hidden, or in a hidden group).
    private func endHiddenSelection() {
        if let sketch = sketchMode?.sketchID, workspace.isHidden(sketch: sketch) { endSketchMode(); tool = .select }
        if let plane = sketchMode?.constructionPlane, workspace.isHidden(plane: plane) { endSketchMode(); tool = .select }
        if isMultipleSelection { keepShownPicks(); return }
        switch selection {
        case .body(let id), .edge(let id, _): if workspace.isHidden(body: id) { selection = nil }
        case .face(let face): if workspace.isHidden(body: face.bodyID) { selection = nil }
        case .sketch(let id): if workspace.isHidden(sketch: id) { selection = nil }
        case .plane(let id): if workspace.isHidden(plane: id) { selection = nil }
        case .shape(let id):
            if workspace.shapes.first(where: { $0.id == id })?.sketch.map(workspace.isHidden(sketch:)) != false { selection = nil }
        case .chain(let ids):
            if workspace.shapes.first(where: { ids.contains($0.id) })?.sketch.map(workspace.isHidden(sketch:)) != false { selection = nil }
        case .profile: if selectedProfile == nil { selection = nil }
        case .group, nil: break
        }
    }

    /// Ends a selection whose item was deleted.
    private func dropMissingSelection() {
        if isMultipleSelection { keepShownPicks(); return }
        switch selection {
        case .body(let id), .edge(let id, _): if !workspace.bodies.contains(where: { $0.id == id }) { selection = nil }
        case .face(let face): if !workspace.bodies.contains(where: { $0.id == face.bodyID }) { selection = nil }
        case .sketch(let id): if workspace.sketch(id) == nil { selection = nil }
        case .plane(let id): if !workspace.constructionPlanes.contains(where: { $0.id == id }) { selection = nil }
        case .shape(let id): if !workspace.shapes.contains(where: { $0.id == id }) { selection = nil }
        // What is left of a chain stays picked.
        case .chain(let ids):
            let left = ids.filter { id in workspace.shapes.contains { $0.id == id } }
            if left.count < ids.count { selection = left.isEmpty ? nil : .chain(left) }
        case .profile: if selectedProfile == nil { selection = nil }
        case .group, nil: break
        }
    }

    /// Projected arcs read as circles, projected curves as projections.
    static func icon(for kind: ShapeKind) -> SSIcon {
        switch kind {
        case .line: .line
        case .circle: .circle
        case .arc: .arc
        case .slot: .slot
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .point: .point
        case .curve: .project
        }
    }
    /// "Sketch 02" for a sketch in the document.
    func sketchName(of id: UUID) -> String? { workspace.sketchNames[id] }

    // MARK: Names, colors, copy and paste

    /// The name a Model Tree row shows (for the rename field).
    func name(of item: ModelSelection) -> String? {
        switch item {
        case .body(let id): workspace.bodyNames[id]
        case .sketch(let id): workspace.sketchNames[id]
        case .plane(let id): workspace.planeNames[id]
        case .group(let id): workspace.groupNames[id]
        default: nil
        }
    }

    /// Keystrokes stay outside the published workspace: publishing it validates geometry and
    /// refreshes the canvas. Flush after a pause, or synchronously before saving/leaving.
    private(set) var isEditingNotes = false
    @ObservationIgnored private var notesEditHasCommitted = false
    @ObservationIgnored private var notesGroupingWorkspace: Workspace?
    @ObservationIgnored private var pendingNotes: String?
    @ObservationIgnored private var notesAutosave: Task<Void, Never>?
    private var notesEditingByteLimit = Workspace.maximumNotesBytes
    private(set) var selectedNoteID: UUID?
    private(set) var draftObjectNote: ObjectNote?
    var activeObjectNote: ObjectNote? {
        guard let id = selectedNoteID else { return nil }
        return workspace.objectNotes.first { $0.id == id } ?? (draftObjectNote?.id == id ? draftObjectNote : nil)
    }
    var notesText: String { pendingNotes ?? (selectedNoteID == nil ? workspace.notes : activeObjectNote?.text ?? "") }
    var notesTextLimit: Int {
        let otherBytes = workspace.notes.utf8.count + workspace.objectNotes.reduce(0) { $0 + ($1.id == selectedNoteID ? 0 : $1.text.utf8.count) }
        return Workspace.maximumNotesBytes - otherBytes + (selectedNoteID == nil ? workspace.notes.utf8.count : 0)
    }
    var listedObjectNotes: [ObjectNote] {
        guard let draft = draftObjectNote, !workspace.objectNotes.contains(where: { $0.id == draft.id }) else { return workspace.objectNotes }
        return workspace.objectNotes + [draft]
    }

    func note(for item: ModelSelection) -> ObjectNote? {
        switch item {
        case .body(let id): workspace.objectNote(kind: .body, id: id)
        case .sketch(let id): workspace.objectNote(kind: .sketch, id: id)
        default: nil
        }
    }

    func noteMatchesSelection(_ note: ObjectNote) -> Bool {
        guard let target = selectionNoteTarget else { return false }
        return note.kind == .body ? target.item == .body(note.objectID) : target.item == .sketch(note.objectID)
    }

    /// The solid or sketch the selection is on, which Notes offers a notebook for (November 9,
    /// 2026: it was hard to tell whether a note went with the selected object): a solid or one of
    /// its faces or edges, or a sketch or anything drawn in it. Hidden objects have no row to note.
    var selectionNoteTarget: (item: ModelSelection, name: String)? {
        guard let selection else { return nil }
        let bodyID: UUID? = switch selection {
        case .body(let id): id
        case .face(let face): face.bodyID
        case .edge(let id, _): id
        default: nil
        }
        if let bodyID {
            guard let name = workspace.bodyNames[bodyID] else { return nil }
            return (.body(bodyID), name)
        }
        guard let sketchID = sketchID(of: selection), let name = workspace.sketchNames[sketchID] else { return nil }
        return (.sketch(sketchID), name)
    }

    /// A draft notebook acquires storage only when text is entered. Its first text and its link
    /// therefore become one undo step, and simply opening an empty notebook changes no file.
    @discardableResult func openObjectNote(for item: ModelSelection) -> Bool {
        endEditingNotes()
        if let existing = note(for: item) { return selectNote(existing.id) }
        guard canChangeRows else { return false }
        let kind: ObjectNote.Kind
        let id: UUID
        let name: String?
        switch item {
        case .body(let value): kind = .body; id = value; name = workspace.bodyNames[value]
        case .sketch(let value): kind = .sketch; id = value; name = workspace.sketchNames[value]
        default: return false
        }
        guard let name else { return false }
        guard workspace.objectNotes.count < 1_000 else { return false }
        let draft = ObjectNote(kind: kind, objectID: id, objectName: String(name.prefix(256)))
        draftObjectNote = draft
        selectedNoteID = draft.id
        highlightNoteTarget(draft)
        return true
    }

    @discardableResult func selectNote(_ id: UUID?) -> Bool {
        endEditingNotes()
        guard !isViewingBlocked, !hasOperationInProgress else { return false }
        let note = id.flatMap { id in listedObjectNotes.first { $0.id == id } }
        guard id == nil || note != nil else { return false }
        draftObjectNote = note.flatMap { note in workspace.objectNotes.contains(where: { $0.id == note.id }) ? nil : note }
        selectedNoteID = id
        if let note { highlightNoteTarget(note) }
        return true
    }

    /// Selects a note's object as its Model Tree row would: sketch mode and the plane picker end,
    /// and a hidden or missing object is left unselected.
    private func highlightNoteTarget(_ note: ObjectNote) {
        dimensionEdit = nil
        cancelTransient()
        endSketchMode()
        tool = .select
        selection = nil
        extraSelection = []
        switch note.kind {
        case .body:
            guard let body = workspace.bodies.first(where: { $0.id == note.objectID }), !workspace.isHidden(body) else { return }
            select(.body(body.id))
        case .sketch:
            guard let sketch = workspace.sketch(note.objectID), !workspace.isHidden(sketch) else { return }
            select(.sketch(sketch.id))
        }
    }

    func deleteObjectNote(_ id: UUID) {
        endEditingNotes()
        guard canChangeRows else { return }
        if history.deleteObjectNote(id) { save() }
        if draftObjectNote?.id == id { draftObjectNote = nil }
        if selectedNoteID == id { selectedNoteID = nil }
    }
    var canEditNotes: Bool { canChangeRows && !isPencilDown && dimensionEdit == nil }

    func beginEditingNotes() {
        guard canEditNotes else { return }
        // UIKit may temporarily relinquish text focus (selection, keyboard, or view updates).
        // Keep one undo group until the notebook closes/switches, unless modeling changed in between.
        if notesGroupingWorkspace != workspace { notesEditHasCommitted = false }
        notesEditingByteLimit = notesTextLimit
        isEditingNotes = true
    }

    func updateNotes(_ text: String) {
        guard isEditingNotes, !isReadOnly, !isProjectBusy, !isAssistantBusy,
              text.utf8.count <= notesEditingByteLimit, text != notesText else { return }
        pendingNotes = text
        notesAutosave?.cancel()
        notesAutosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            self?.save()
        }
    }

    /// Save also calls this for Home/backgrounding, including while a file operation is busy.
    @discardableResult private func flushNotes() -> Bool {
        notesAutosave?.cancel()
        notesAutosave = nil
        guard let text = pendingNotes else { return false }
        pendingNotes = nil
        guard text != (selectedNoteID == nil ? workspace.notes : activeObjectNote?.text ?? "") else { return false }
        guard selectedNoteID == nil || activeObjectNote != nil else {
            status = "Your last note edit could not be saved: its note was removed"
            return false
        }
        // Amend only the step this editing made: a model change, undo, or redo since starts a new one.
        let amending = notesEditHasCommitted && notesGroupingWorkspace == workspace && history.canUndo
        guard history.updateNotes(text, objectNote: activeObjectNote, amending: amending) else {
            status = "Your last note edit could not be saved"
            return false
        }
        notesEditHasCommitted = true
        notesGroupingWorkspace = workspace
        if draftObjectNote != nil { draftObjectNote = nil }
        return true
    }

    func endEditingNotes(finalize: Bool = true) {
        if flushNotes() { save() }
        if isEditingNotes { isEditingNotes = false }
        if finalize { notesEditHasCommitted = false; notesGroupingWorkspace = nil }
    }

    func closeNotes() {
        endEditingNotes()
        if draftObjectNote != nil { draftObjectNote = nil; selectedNoteID = nil }
    }

    private func revalidateSelectedNote() {
        if let id = selectedNoteID, !workspace.objectNotes.contains(where: { $0.id == id }), draftObjectNote?.id != id { selectedNoteID = nil }
    }

    /// Renames a solid, sketch, or construction plane (one undo step). An empty name goes back to
    /// its number.
    /// Renaming, recoloring, or deleting a row waits for the operation in progress: its preview
    /// was built from the model as it was, so Done would put the old names and colors back.
    var canChangeRows: Bool { hasEditingAccess && !isEditingBlocked && !hasOperationInProgress && !isPencilDown }

    func rename(_ item: ModelSelection, to name: String) {
        guard canChangeRows else { return }
        let next: Workspace?
        switch item {
        case .body(let id): next = workspace.renaming(body: id, to: name)
        case .sketch(let id): next = workspace.renaming(sketch: id, to: name)
        case .plane(let id): next = workspace.renaming(plane: id, to: name)
        case .group(let id): next = workspace.renaming(group: id, to: name)
        default: next = nil
        }
        if let next { commit(next) }
    }

    /// A solid's color (one undo step); gray is the default.
    /// Several solids colored at once (picked together), as one undo step.
    func setColor(_ color: BodyColor, of ids: [UUID]) {
        guard canChangeRows else { return }
        var next = workspace
        for index in next.bodies.indices where ids.contains(next.bodies[index].id) { next.bodies[index].color = color == .gray ? nil : color }
        commit(next)
    }

    func setColor(_ color: BodyColor, of id: UUID) {
        guard canChangeRows, let index = workspace.bodies.firstIndex(where: { $0.id == id }) else { return }
        var next = workspace
        next.bodies[index].color = color == .gray ? nil : color
        commit(next)
    }

    /// The solids and sketches Copy and Duplicate take: the selected solid (or its face or edge's),
    /// or the selected sketch (or a shape's sketch), or an item row.
    private func copyTargets(_ item: ModelSelection?) -> (bodies: [UUID], sketches: [UUID]) {
        // Several solids picked together go together.
        if item == selection, pickedBodies.count > 1 { return (pickedBodies, []) }
        switch item {
        case .body(let id), .edge(let id, _): return ([id], [])
        case .face(let face): return ([face.bodyID], [])
        case .sketch(let id): return ([], [id])
        case .shape(let id): return ([], workspace.shapes.first { $0.id == id }?.sketch.map { [$0] } ?? [])
        case .group(let id): return (workspace.contents(of: id).bodies, workspace.contents(of: id).sketches)
        default: return ([], [])
        }
    }

    var canCopy: Bool { let targets = copyTargets(selection); return !(targets.bodies.isEmpty && targets.sketches.isEmpty) }
    var canPaste: Bool { _ = clipboardRevision; return !ModelClipboard.shared.isEmpty && !isEditingBlocked }
    /// "Paste Body 01".
    var pasteTitle: String { _ = clipboardRevision; return "Paste " + ModelClipboard.shared.title }
    /// Counts copies made here: the clipboard is shared by every project, outside the session, so
    /// Paste reads this to redraw when something new is copied.
    private var clipboardRevision = 0

    /// Copies the selected solid or sketch (or an item row's) for Paste, in this project or another.
    func copy(_ item: ModelSelection? = nil) {
        let targets = copyTargets(item ?? selection)
        guard !(targets.bodies.isEmpty && targets.sketches.isEmpty) else { return }
        ModelClipboard.shared = workspace.copying(bodies: targets.bodies, sketches: targets.sketches)
        clipboardRevision += 1
        status = "Copied " + ModelClipboard.shared.title
    }

    /// Adds the copied solids and sketches where they were copied from (one undo step) and selects
    /// the first, ready to move.
    func paste() {
        guard requireNewEditingAccess() else { return }
        guard canPaste, let result = workspace.pasting(ModelClipboard.shared) else { return }
        cancelTransient()
        endSketchMode()
        tool = .select
        commit(result.workspace)
        selection = result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) }
        status = "Pasted " + ModelClipboard.shared.title
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A copy of the selected solid or sketch (or an item row's) right where it is, selected.
    func duplicate(_ item: ModelSelection? = nil) {
        guard requireNewEditingAccess() else { return }
        if case .group(let id)? = item ?? selection {
            // The whole group, nested groups included, as a new group beside it.
            guard !isEditingBlocked, let result = workspace.duplicatingGroup(id) else { return }
            cancelTransient()
            endSketchMode()
            tool = .select
            commit(result.workspace)
            selection = .group(result.group)
            status = "Duplicated the group"
            return
        }
        let targets = copyTargets(item ?? selection)
        guard !isEditingBlocked, !(targets.bodies.isEmpty && targets.sketches.isEmpty),
              let result = workspace.pasting(workspace.copying(bodies: targets.bodies, sketches: targets.sketches)) else { return }
        cancelTransient()
        endSketchMode()
        tool = .select
        commit(result.workspace)
        selection = result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) }
        status = "Duplicated"
    }

    /// Shows or hides a solid or sketch (one undo step). Hidden items leave the canvas, and a
    /// selection or sketch inside them ends.
    func toggleHidden(_ item: ModelSelection) {
        guard requireNewEditingAccess() else { return }
        guard canToggleVisibility else { return }
        var next = workspace
        var sketchID: UUID?, bodyID: UUID?
        switch item {
        case .sketch(let id):
            guard let index = next.sketches.firstIndex(where: { $0.id == id }) else { return }
            next.sketches[index].hidden = next.sketches[index].isHidden ? nil : true
            if next.sketches[index].isHidden { sketchID = id }
        case .body(let id):
            guard let index = next.bodies.firstIndex(where: { $0.id == id }) else { return }
            next.bodies[index].hidden = next.bodies[index].isHidden ? nil : true
            if next.bodies[index].isHidden { bodyID = id }
        case .plane(let id):
            guard let index = next.constructionPlanes.firstIndex(where: { $0.id == id }) else { return }
            next.constructionPlanes[index].hidden = next.constructionPlanes[index].isHidden ? nil : true
            if next.constructionPlanes[index].isHidden {
                if selection == .plane(id) { selection = nil }
                if sketchMode?.constructionPlane == id { endSketchMode(); tool = .select }
            }
        case .group(let id):
            // Everything inside goes with it; each item's own eye is kept for when it comes back.
            guard let group = workspace.group(id), let shown = workspace.settingGroup(id, hidden: !group.isHidden) else { return }
            cancelTransient()
            commit(shown)
            endHiddenSelection()
            return
        default: return
        }
        cancelTransient()
        if let sketchID {
            if sketchMode?.sketchID == sketchID { endSketchMode(); tool = .select }
            let inSketch: (UUID) -> Bool = { id in self.workspace.shapes.first { $0.id == id }?.sketch == sketchID }
            switch selection {
            case .sketch(sketchID): selection = nil
            case .shape(let id) where inSketch(id): selection = nil
            case .profile where selectedProfile?.sourceIDs.contains(where: inSketch) == true: selection = nil
            default: break
            }
        }
        if let bodyID {
            if selectedBody?.id == bodyID || selectedFace?.bodyID == bodyID { selection = nil }
        }
        commit(next)
    }

    /// Whether an Items row shows as selected: its shape or solid, a region it bounds, or one of the solid's faces.
    func isHighlighted(_ item: ModelItem) -> Bool {
        if let draft = unionDraft {
            if case .body(let id) = item.selection { return draft.bodies.contains(id) }
            return false
        }
        if let draft = subtractDraft {
            if case .body(let id) = item.selection { return draft.targets.contains(id) || draft.tools.contains(id) }
            return false
        }
        if let draft = alignDraft {
            switch item.selection {
            case .body(let id): return draft.bodies.contains(id)
            case .plane(let id): return draft.to?.source == .plane(id)
            case .shape(let id): return draft.to?.source == .shape(id)
            default: return false
            }
        }
        if let draft = patternDraft {
            switch item.selection {
            case .body(let id): return draft.bodies.contains(id)
            case .sketch(let id): return draft.sketches.contains(id)
            default: return false
            }
        }
        if let draft = scaleDraft {
            switch item.selection {
            case .body(let id): return draft.bodies.contains(id)
            case .sketch(let id): return draft.sketches.contains(id)
            default: return false
            }
        }
        if let draft = mirrorDraft {
            switch item.selection {
            case .body(let id): return draft.bodies.contains(id)
            case .sketch(let id): return draft.sketches.contains(id)
            case .plane(let id): return draft.plane?.source == .plane(id)
            case .shape(let id): return draft.plane?.source == .line(id)
            default: return false
            }
        }
        if let draft = splitDraft {
            switch item.selection {
            case .body(let id): return draft.bodies.contains(id)
            case .plane(let id): return draft.tools.contains { $0.source == .plane(id) }
            case .shape(let id): return draft.tools.contains { $0.source == .line(id) }
            default: return false
            }
        }
        if let draft = projectionDraft {
            // While projecting, the rows picked as items or as the surface.
            let sources = Set(draft.items.map(\.source))
            switch item.selection {
            case .sketch(let id): return sources.contains(.sketch(id)) || draft.target?.sketchID == id
            case .shape(let id): return sources.contains(.shape(id))
            case .body(let id): return sources.contains(.body(id))
            case .plane(let id): return draft.target?.source == .plane(id)
            default: return false
            }
        }
        if isMultipleSelection {
            // Each picked sketch, each shape of a picked region, and each picked solid (or the solid
            // of picked edges).
            switch item.selection {
            case .sketch(let id): return selectedItems.contains(.sketch(id))
            case .shape(let id): return selectedItems.contains { profile(for: $0)?.sourceIDs.contains(id) == true }
            case .body(let id): return pickedBodies.contains(id) || pickedEdges.contains { $0.bodyID == id }
            default: return false
            }
        }
        switch (item.selection, selection) {
        case (.sketch(let id), .sketch(let selected)): return id == selected
        case (.plane(let id), .plane(let selected)): return id == selected
        case (.shape(let id), .shape(let selected)): return id == selected
        case (.shape(let id), .profile): return selectedProfile?.sourceIDs.contains(id) ?? false
        case (.shape(let id), .chain(let ids)): return ids.contains(id)
        case (.body(let id), .body(let selected)): return id == selected
        case (.body(let id), .face(let face)): return id == face.bodyID
        case (.body(let id), .edge(let bodyID, _)): return id == bodyID
        case (.group(let id), .group(let selected)): return id == selected
        default: return false
        }
    }

    /// Items can be picked whenever the canvas could pick them: not during an operation preview.
    /// An operation is picking or previewing; its picks and preview are built on the model as it is.
    var hasOperationInProgress: Bool {
        projectionDraft != nil || splitDraft != nil || mirrorDraft != nil || patternDraft != nil || scaleDraft != nil || deleteFaceDraft != nil || unionDraft != nil ||
            subtractDraft != nil || alignDraft != nil || revolveDraft != nil || offsetDraft != nil || sketchMirrorDraft != nil || section != nil || planeDraft != nil || isExtruding || isRevolving || isFinishing || isShelling || isPlacingHole || isPlacingPeg || isThreading || isPlacingText || !measureItems.isEmpty ||
            primitiveDraft != nil || constructionDraft != nil || shapeToolDraft != nil || screwLidDraft != nil
    }

    /// Hiding or showing waits for the operation in progress (it would end it).
    var canToggleVisibility: Bool { hasEditingAccess && !isEditingBlocked && !hasOperationInProgress && !isPencilDown }

    var canSelectItems: Bool {
        (tool == .measure || tool == .select ? !isViewingBlocked : !isEditingBlocked) && (tool == .measure || projectionDraft != nil || splitDraft != nil || mirrorDraft != nil || patternDraft != nil || scaleDraft != nil || unionDraft != nil || subtractDraft != nil || alignDraft != nil || revolveDraft != nil || !isExtruding && !isRevolving && !isFinishing && !isShelling && !isPlacingHole && !isPlacingPeg && !isThreading && !isPlacingText && planeDraft == nil && tool != .deleteFace &&
            primitiveDraft == nil && constructionDraft == nil && shapeToolDraft == nil && screwLidDraft == nil)
    }

    /// Selects a row of the Items list, exactly like tapping it on the canvas, including sketches
    /// hidden under a solid. A sketch keeps its plane (it drags on its own plane); a solid ends sketch mode.
    func selectItem(_ item: ModelSelection) {
        guard canSelectItems else { return }
        // An operation or Measure picks only what the canvas shows: a hidden row is passed over.
        let picksForOperation = tool == .measure || projectionDraft != nil || splitDraft != nil || mirrorDraft != nil || patternDraft != nil ||
            scaleDraft != nil || unionDraft != nil || subtractDraft != nil || alignDraft != nil || revolveDraft != nil
        if picksForOperation, !rowIsShown(item) { return }
        if tool == .measure {
            // A solid or sketch shape row is measured, as tapping it would be.
            switch item {
            case .body(let id): pickMeasureItem(.body(id))
            case .shape(let id): pickMeasureItem(.shape(id))
            default: break
            }
            return
        }
        if projectionDraft != nil { pickProjectionRow(item); return }
        if splitDraft != nil { pickSplitRow(item); return }
        if mirrorDraft != nil { pickMirrorRow(item); return }
        if patternDraft != nil { pickPatternRow(item); return }
        if scaleDraft != nil { pickScaleRow(item); return }
        if unionDraft != nil {
            if case .body(let id) = item { toggleUnionBody(id) }
            return
        }
        if subtractDraft != nil {
            if case .body(let id) = item { toggleSubtractBody(id) }
            return
        }
        if alignDraft != nil { pickAlignRow(item); return }
        if revolveDraft != nil {
            // A Line row is an axis, like tapping the line.
            guard case .shape(let id) = item, let shape = workspace.shapes.first(where: { $0.id == id }) else { return }
            pickRevolveAxis(shape.kind == .line ? (shape.plane.point(shape.start), shape.plane.point(shape.end)) : nil)
            return
        }
        cancelTransient()
        switch item {
        case .shape(let id):
            // Shapes of a hidden sketch are not on the canvas, so they cannot be picked either.
            guard let shape = workspace.shapes.first(where: { $0.id == id }), workspace.sketch(shape.sketch).map(workspace.isHidden) != true else { return }
            // In Extrude, picking a sketch starts its extrusion, as a canvas tap does. Otherwise
            // the row opens its sketch, like tapping the line on the canvas.
            if tool != .extrude && tool != .revolve {
                enterSketch(of: id)
                return
            }
        case .sketch(let id):
            selectSketch(id)
            return
        case .plane(let id):
            guard workspace.isShown(plane: id) else { return }
            tool = .select
            if sketchMode != nil { endSketchMode() }
        case .body(let id):
            guard workspace.bodies.contains(where: { $0.id == id }) else { return }
            tool = .select
            if sketchMode != nil { endSketchMode() }
        case .profile, .face, .edge, .chain: break
        // A group's name selects everything in it, to move, transform, or export it as a unit
        // (its arrow folds it away).
        case .group(let id):
            guard workspace.group(id) != nil else { return }
            tool = .select
            if sketchMode != nil { endSketchMode() }
        }
        select(item)
    }
    /// Whether a Model Tree row's item is on the canvas (not hidden, nor in a hidden group or sketch).
    private func rowIsShown(_ item: ModelSelection) -> Bool {
        switch item {
        case .body(let id): workspace.isShown(body: id)
        case .sketch(let id): workspace.isShown(sketch: id)
        case .plane(let id): workspace.isShown(plane: id)
        case .shape(let id): workspace.shapes.first { $0.id == id }.flatMap { workspace.sketch($0.sketch) }.map { !workspace.isHidden($0) } ?? false
        case .group(let id): workspace.group(id) != nil && !workspace.isGroupHidden(id)
        case .profile, .face, .edge, .chain: true
        }
    }
    var hint: String {
        if isAssistantWorking { return "The assistant is working on your request." }
        if isReviewingAssistant { return "Review the assistant's changes. Keep adds them as one step you can undo; Discard leaves the model as it was." }
        if section != nil {
            return "Section view: drag the double-arrow or tap the offset to move the cut. Flip shows the other side; Done goes back to the whole model."
        }
        if tool == .measure {
            switch measureItems.count {
            case 0: return "Tap a corner, edge, face, or sketch item to measure it; double-tap a solid for all of it."
            case 1: return "Tap a second item for the distance and angle between them."
            default: return "Tap another item to measure from it, or Done."
            }
        }
        if tool == .dimension {
            guard let draft = dimensionDraft, draft.first != nil else {
                return "Tap a point, line, or circle to dimension from: a sketch's, or a purple dot or edge of a solid."
            }
            if draft.second == nil { return "Tap a second item for the distance or angle between them, or tap a value to change it." }
            return "Tap a value to change it: the second item moves, and the dimension stays in the sketch. Tap empty space to start again."
        }
        if isExtruding && faceExtrusion != nil {
            if abs(extrusionDepth) < 0.01 {
                return extrusionSizeBase == nil ? "Drag the double-arrow out to add material or in to cut, or tap the depth value."
                    : "Drag the double-arrow out to add material or in to cut, or tap the size to type the size you want."
            }
            return isCutting ? "Pushes the face into the solid. Done cuts it." : "Pulls the face out of the solid. Done adds the material."
        }
        if isCutting {
            if cutTargets.isEmpty { return cutThroughAll ? "The cut does not cross a solid. Choose a sketch that overlaps one." : "The cut does not reach a solid yet. Drag the double-arrow or choose Through All." }
            return cutThroughAll ? "Cuts straight through every solid it crosses. Done applies the cut." : "Drag the double-arrow or tap the depth. The red tool cuts every solid it touches."
        }
        if isJoining {
            return joinTarget == nil ? "The boss does not touch a solid. Drag it onto one, or choose New Body." :
                "Joins the solid it touches. Drag the double-arrow or tap the depth; Done merges it."
        }
        if isExtruding { return "Drag the double-arrow along its direction, or tap the depth value." }
        if let draft = revolveDraft { return revolveHint(draft) }
        if let draft = alignDraft {
            if let alignError { return alignError }
            switch draft.step {
            case .bodies: return draft.bodies.isEmpty ? "Tap the solids to move." : "Tap more solids, or From and then a face, edge, or corner on them."
            case .from: return "Tap what to align on the moving solids: a flat face, a round edge (or a cylinder's side for its nearer rim), a straight edge, or a corner (the dots)."
            case .to:
                if draft.from == nil { return "Tap From, then a face, edge, or corner of the moving solids." }
                if draft.to == nil {
                    if draft.from?.kind == .point { return "Tap the point it goes to: a corner of another solid, a sketch point, or the origin." }
                    return "Tap where it goes: a face, plane, or sketch region for a face; a round edge, cylinder side, or circle for a round edge; a straight edge or line for a straight edge."
                }
                if draft.to?.kind == .point { return "The corner moves onto the point. Done moves the solids." }
                return "Flip turns it over. Drag the double-arrow or tap the values to offset or turn it. Done moves the solids."
            }
        }
        if let draft = subtractDraft {
            if let subtractError { return subtractError }
            if draft.step == .targets {
                return draft.targets.isEmpty ? "Tap the solids to subtract from." : "Tap more targets, or Tools and then the solids to take away."
            }
            if draft.tools.isEmpty { return "Tap the solids to take away from the purple targets." }
            if draft.targets.isEmpty { return "Tap Targets, then the solids to subtract from." }
            return draft.clearance == nil ? "Done removes the blue solids from the purple ones. Add a clearance to leave room for a part shaped like them." :
                "Done removes the blue solids, grown by the clearance, so a part shaped like them fits."
        }
        if let draft = unionDraft {
            if let unionError { return unionError }
            if draft.intersect {
                if draft.bodies.count < 2 { return draft.bodies.isEmpty ? "Tap the solids to intersect. Only where they all overlap is kept." : "Tap another solid that overlaps it." }
                return "Keeps only where the \(draft.bodies.count) solids overlap. Tap more to add them, or Done."
            }
            if draft.bodies.count < 2 { return draft.bodies.isEmpty ? "Tap the solids to unite. The last one you tap is the target." : "Tap another solid that touches or overlaps it." }
            return "Unites \(draft.bodies.count) solids into one. Tap more to add them, or Done."
        }
        if let draft = shellDraft {
            if let draftError { return draftError }
            return draft.openings.isEmpty ? "Tap at least one face to leave open, such as the top." :
                "Tap more faces to open or close them. Drag the double-arrow or tap the thickness. Done hollows the solid."
        }
        if let draft = holeDraft {
            if let draftError { return draftError }
            return "Choose the hole type and size below. Tap elsewhere on the face to move it, or tap a value to edit it." +
                (draft.replacing != nil ? " Done keeps the change; Cancel leaves the hole as it was." : "")
        }
        if let draft = textDraft {
            if let textError { return textError }
            if isBuildingText { return "Building the letters…" }
            return (draft.depth > 0 ? "Raised" : "Sunk") + " text. Type it below, pick a font, or tap the height or depth. Tap elsewhere on the face to move it, or Done." +
                (draft.replacing != nil ? " Cancel leaves the text as it was." : "")
        }
        if let draft = screwLidDraft {
            if let screwLidError { return screwLidError }
            if isBuildingScrewLidTest { return "Building the thread fit test…" }
            if isBuildingScrewLid { return "Building the thread and the lid…" }
            let s = draft.spec
            return "A \(s.starts)-start, \(lengthText(s.pitch)) thread that closes in \(ThreadSpec.mm(s.turns)) \(s.turns == 1 ? "turn" : "turns"), and a \(s.ribbed ? "ribbed" : "smooth") lid screwed on (check it with Section). Test Print adds a ring and three collars to try first; Done adds both."
        }
        if let draft = threadDraft {
            if let threadError { return threadError }
            if isBuildingThread { return "Building the thread…" }
            if let threadWall, let spec = draft.built {
                return spec.wallWarning(threadWall, lengthText) + " Choose Raised to add the ridges onto the face instead, or change the size or pitch."
            }
            return draft.spec.fitSummary(lengthText) + " Change the size, pitch, or length below, or tap a value to type your own. " +
                (draft.replacing != nil ? "Done keeps the change; Cancel leaves the thread as it was." : "Done \(draft.spec.isRaised ? "adds" : "cuts") it.")
        }
        if pegDraft != nil {
            if let draftError { return draftError }
            guard !pegSockets.isEmpty else {
                return "No part sits over the peg, so there is no socket yet (hide a lid to reach the face under it). Tap elsewhere to move it, or tap a value to edit it."
            }
            let names = workspace.bodyNames
            let sockets = pegSockets.map { id in
                (names[id] ?? "A solid") + (workspace.isHidden(body: id) ? " (hidden)" : "")
            }
            return "Sockets go into \(sockets.joined(separator: ", ")) with the clearance below. Tap elsewhere to move the peg, or Done." +
                (pegDraft?.spec.separate == true ? " The peg is its own solid, to print separately." : "") +
                (pegDraft?.editing != nil ? " Cancel leaves the peg as it was." : "")
        }
        if let draft = finishDraft {
            if let finishError { return finishError }
            return "Tap more edges, drag the double-arrow, or tap the \(draft.kind.sizeTitle.lowercased()). Done applies the \(draft.kind.rawValue)."
        }
        if tool == .offsetPlane {
            guard planeDraft?.references.isEmpty == false else { return "Tap a flat face, sketch region, or plane to offset from." }
            return "Drag the double-arrow or tap the offset. Tap another face or plane to start from it. Done adds the plane."
        }
        if tool == .midplane {
            let count = planeDraft?.references.count ?? 0
            if count < 2 { return count == 0 ? "Tap the first of two parallel faces, sketch regions, or planes." : "Tap the second, parallel to the first." }
            return planePreview == nil ? "Those two are not parallel. Tap one of them to unpick it." : "Done adds the plane centered between them."
        }
        if let draft = projectionDraft { return projectionHint(draft) }
        if let draft = mirrorDraft {
            if draft.step == .items {
                return draft.isEmpty ? "Tap the solids and sketches to mirror." : "Tap more, or Mirror Plane and then the plane to mirror across."
            }
            if draft.plane == nil { return "Tap a plane, a flat face, a sketch region, or a sketch line to mirror across." }
            if draft.isEmpty { return "Tap Objects, then the solids and sketches to mirror." }
            if isBuildingMirror { return "Mirroring…" }
            return mirrorPreview == nil ? "That cannot be mirrored. Pick another plane." : "Tap another plane to change it, or Done."
        }
        if let draft = patternDraft { return patternHint(draft) }
        if let draft = deleteFaceDraft {
            if let deleteFaceError { return deleteFaceError }
            return draft.faces.isEmpty ? "Tap the faces to take off, such as a fillet or the wall of a hole." :
                "Tap more faces, such as the rest of a hole, or Done. The faces around them grow to close the gap."
        }
        if let draft = scaleDraft {
            if let scaleError { return scaleError }
            if draft.isEmpty { return "Tap the solids and sketches to scale." }
            return draft.uniform ? "Drag an arrow or tap the percentage. Tap more items to scale them too, or Done." :
                "Drag an arrow, or tap a percentage, to stretch along it. Done scales the solids."
        }
        if let draft = splitDraft {
            if draft.step == .bodies {
                return draft.bodies.isEmpty ? "Tap the solids to split." : "Tap more solids, or Splitting Tools and then a plane, flat face, sketch region, or sketch line."
            }
            if draft.tools.isEmpty { return "Tap a plane, a flat face (of any solid, even its own), a sketch region, or a sketch line to split with." }
            if draft.bodies.isEmpty { return "Tap Bodies to Split, then the solids to split." }
            if let splitError { return splitError }
            return splitPreview == nil ? "Finding the pieces…" : "Splits into \(splitPieceCount) solids. Tap more to cut again, or Done."
        }
        if isPickingPlane { return "Draw on the grid, or tap one of the planes at the origin or a flat face to sketch on it." }
        if selectedConstructionPlane != nil { return "Construction plane selected. Tap Sketch to draw on it, or Offset Plane for a parallel plane." }
        if transformDrag?.copy == true { return "Copying. Lift Pencil to place the copy." }
        if isDraggingPivot { return "Drag the center onto a corner, an edge, or a circle or face center, of this solid or another, a sketch point, or the origin. Lift Pencil to turn about it there." }
        if isMultipleSelection {
            if pickedBodies.count > 1 {
                return "\(pickedSummary) picked. Drag an arrow to move them all or an arc to turn them. Double-tap another solid to add it, or a picked one to take it out. Combine, Transform, Color, Export, and Delete take them all."
            }
            if pickedEdges.count > 1 {
                return "\(pickedSummary) picked. Tap more edges of this solid to add them, or a picked one to take it out. Fillet or Chamfer takes them all."
            }
            return "\(pickedSummary) picked. Tap more regions or sketches on this plane to add them, or a picked one to take it out. Extrude or Revolve takes them all; tap empty space to start over."
        }
        if selectedSketch != nil {
            return "Drag an arrow to move the sketch or an arc to turn it. Turn on Create Copy to keep the original. Tap a line to keep drawing in it, or another sketch or region on its plane to pick it too."
        }
        if let chain = selectedChain {
            return "\(Self.chainSummary(chain.count)) selected. Drag an arrow to slide them along the sketch or the arc to turn them. Turn on Create Copy to keep the originals. Whole Sketch picks all of it."
        }
        if selectedBody != nil, tool == .select {
            return "Solid selected. Drag an arrow to move it or an arc to turn it, or drag the center dot onto a corner or edge to turn about it. Turn on Create Copy to keep the original. Double-tap another solid to pick it too."
        }
        if selectedEdge != nil { return "Edge selected. Drag the double-arrow to round it, or choose Fillet or Chamfer. Tap another edge of this solid to pick it too." }
        if selectedShape != nil {
            return "Tap a dimension to edit it. Drag a point or edge with Pencil to resize." + (sketchMode == nil ? " Tap more regions or sketches on its plane to pick them too." : "")
        }
        if let face = selectedFace {
            if face.plane == nil, selectedThread != nil {
                return "Thread selected. Edit Thread changes its size, pitch, or length; Matching Part makes the nut, cap, bolt, or plug that screws onto it."
            }
            switch selectedFeature {
            case .hole: return "Hole selected. Edit Hole changes its type, size, or depth, or moves it; Delete Hole takes it out. Double-tap for the whole solid."
            case .text: return "Text selected. Edit Text changes the words, font, size, or depth, or moves it. Double-tap for the whole solid."
            case .peg: return "Peg selected. Edit Peg changes its size, clearance, or place, and its sockets follow. Double-tap for the whole solid."
            case .thread, nil: break
            }
            if let finish = selectedFinish {
                return "\(finish.kind.title) selected. Tap its \(finish.kind.sizeTitle.lowercased()) to change it, or choose Delete \(finish.kind.title) to make its edges sharp again; double-tap for the whole solid."
            }
            let size = selectedFaceSize.map { if case .diameter = $0 { "Tap its diameter to change it. " } else { "Tap its distance to change it. " } } ?? ""
            return face.plane != nil ? size + "Extrude pushes or pulls it, Sketch draws on it, Delete Face takes it off; double-tap for the whole solid." :
                size + "Delete Face takes it off; double-tap to select the whole solid."
        }
        switch tool {
        case .select: return sketchMode != nil ? "Tap a sketch to edit it, or choose a drawing tool." : "Tap a face or sketch region with your Apple Pencil. Double-tap a solid to select all of it."
        case .line: return guidePrefix + "Drag Pencil from start to endpoint. Join endpoints to close a shape."
        case .circle: return guidePrefix + "Place Pencil at the center, then drag to set the radius."
        case .rectangle: return guidePrefix + (rectangleFromCenter ? "Place Pencil at the center, then drag to a corner." : "Drag Pencil between two opposite corners.") + " Tap Rectangle again to switch."
        case .arc: return guidePrefix + "Drag Pencil from one end of the arc to the other, curving through its middle."
        case .slot: return guidePrefix + (slotFromCenter ? "Place Pencil at the slot's center, then drag to the center of a round end." :
                                          "Drag Pencil from the center of one round end to the other's.") + " Tap Slot again to switch."
        case .cornerFillet: return editableCorner != nil ? "Tap the radius to change it, or tap another corner to round it." :
            "Tap a corner where two lines meet to round it."
        case .trim: return "Tap or scribble over the part of a shape to remove: it goes back to where other shapes cross it. Tap empty space when done."
        case .ellipse: return guidePrefix + "Place Pencil at the center, then drag to a corner of the box around it. Drag its handles to turn or resize it."
        case .point: return guidePrefix + "Tap to place a point: something to snap, dimension, and align to."
        case .draft:
            guard let draft = shapeToolDraft else { return "" }
            if let error = draft.error { return error }
            if draft.neutral == nil { return "Tap the flat face the draft leans from, such as a mold's parting face: it stays put." }
            return draft.faces.isEmpty ? "Tap the faces to lean, such as the sides." :
                "Tap more faces, or a picked one to take it out. Tap the angle to change it (negative leans outward). Done applies the draft."
        case .rib:
            guard let draft = shapeToolDraft else { return "" }
            if let error = draft.error { return error }
            return draft.line == nil ? "Tap a sketch line drawn across a corner, on a plane through the solid." :
                "The rib grows from the line until it meets the solid. Tap the thickness to change it, Flip for the other side, or Done."
        case .loft:
            guard let draft = shapeToolDraft else { return "" }
            if let error = draft.error { return error }
            return draft.regions.count < 2 ? "Tap the sketch regions to blend between, in order (\(draft.regions.count) picked)." :
                "Tap more regions to pass through, or a picked one to take it out. Done makes the loft a solid of its own."
        case .sweep:
            guard let draft = shapeToolDraft else { return "" }
            if let error = draft.error { return error }
            if draft.regions.isEmpty { return "Tap the sketch region to sweep." }
            return draft.path == nil ? "Tap the path: a sketch line, arc, or spline (joined lines follow too), starting at the region." :
                "Done makes the sweep a solid of its own. Tap another path or region to change it."
        case .spline: return guidePrefix + "Draw the curve with Pencil; it becomes a smooth spline through a few points. End where you began to close it. Drag its points to reshape it."
        case .polygon: return editablePolygon != nil ? "Tap the number of sides or the radius to change it, or draw another polygon." :
            guidePrefix + "Place Pencil at the center, then drag to a corner. It has \(polygonSides) sides; tap the number or the radius afterward to change it."
        case .extend: return "Tap a line near the end to extend: it reaches on to the next shape it meets."
        case .offset:
            guard offsetDraft != nil else { return "Tap a shape, or a line of an outline, to offset it." }
            return offsetPreview.isEmpty ? "That cannot be offset this far. Tap the distance to change it." :
                "Drag nothing: tap the distance to type it. Flip goes the other way; Both Sides makes a wall. Done adds it."
        case .sketchMirror:
            guard let draft = sketchMirrorDraft else { return "" }
            if draft.step == .shapes { return draft.shapes.isEmpty ? "Tap the shapes to mirror." : "Tap more shapes, or Mirror Line and then the line to mirror across." }
            if draft.line == nil { return "Tap the line to mirror across (a construction line works well)." }
            return draft.shapes.isEmpty ? "Tap Shapes, then the shapes to mirror." : "Done adds the mirror copies."
        case .dimension, .measure: return ""
        case .extrude: return "Tap a closed sketch region or a flat face of a solid with your Apple Pencil."
        case .revolve: return "Tap the closed sketch region or flat face to revolve with your Apple Pencil."
        case .fillet: return "Tap the solid edges to round with your Apple Pencil."
        case .chamfer: return "Tap the solid edges to bevel with your Apple Pencil."
        case .shell: return "Tap the faces of a solid to leave open, such as the top of a box."
        case .hole: return guidePrefix + "Tap the face where the hole goes."
        case .box, .cylinder, .sphere, .torus:
            let name = tool.rawValue
            guard primitiveDraft != nil else { return "Tap the grid, or a flat face of a solid, where the \(name) goes." }
            return primitivePreview == nil ? "The tube must be thinner than the torus's diameter. Tap a size to change it." :
                "Tap a size to change it, or tap elsewhere to move the \(name). Done makes it a solid of its own."
        case .peg: return sketchMode?.face != nil ? guidePrefix + "Tap where the peg stands. Any solid it pushes into gets a socket, even a hidden one." :
            "Tap the flat face the peg stands on, such as a box's rim (hide the lid first to reach it)."
        case .fitTest: return ""
        case .thread: return "Tap the inside of a hole, or the side of a round boss, to thread it."
        case .screwLid: return "Tap the outside of a container's round neck. It gets a thread and a lid screwed onto it."
        case .text: return sketchMode?.face != nil ? guidePrefix + "Tap where the text goes on the face." : "Select a flat face first, then choose Text."
        case .offsetPlane: return "Tap a flat face, sketch region, or plane to offset from."
        case .planeAngle:
            guard constructionDraft?.line != nil else { return "Tap a straight edge of a solid, or a sketch line, for the plane to turn about." }
            return constructionPreview == nil ? "That line cannot take a plane. Tap another." :
                "Tap the angle to change it (0° lies on the face beside the edge, or the line's sketch). Tap another line to start again, or Done."
        case .plane3Point:
            let count = constructionDraft?.points.count ?? 0
            if count == 3 && constructionPreview == nil { return "Those points are in a line. Tap one to take it out, then another." }
            return count == 3 ? "Done adds the plane through the three points. Tap a point to take it out." :
                "Tap three points: solid corners, sketch points, or the origin (\(count) of 3)."
        case .planeTangent:
            return constructionPreview == nil ? "Tap a round face, such as a cylinder's side, where the plane touches it." :
                "Done adds the plane. Tap elsewhere on a round face to move it."
        case .axis:
            if axisPreview != nil { return "Done adds the axis. Tap something else to start again." }
            return (constructionDraft?.points.count ?? 0) == 1 ? "Tap a second point for the axis to run to." :
                "Tap a round face, a circular edge, a straight edge or sketch line, or two points."
        case .midplane: return "Tap two parallel faces, sketch regions, or planes."
        case .project: return "Tap the sketches, edges, faces, or solids to project."
        case .split: return "Tap the solids to split."
        case .union: return "Tap the solids to unite."
        case .intersect: return "Tap the solids to intersect."
        case .subtract: return "Tap the solids to subtract from."
        case .align: return "Tap the solids to move."
        case .mirror: return "Tap the solids and sketches to mirror."
        case .pattern: return "Tap the solids and sketches to pattern."
        case .scale: return "Tap the solids and sketches to scale."
        case .deleteFace: return "Tap the faces to take off, such as a fillet or the wall of a hole."
        }
    }

    private func revolveHint(_ draft: RevolveDraft) -> String {
        if let revolveError { return revolveError }
        guard draft.axis != nil else {
            return "Tap the axis to revolve around: a sketch line, a straight edge of a solid, or the X, Y, or Z axis, in the region's plane."
        }
        if abs(draft.angle) < 0.1 { return "Drag the curved arrow or tap the angle. Tap another line to change the axis." }
        switch draft.mode {
        case .cut:
            return revolveCutTargets.isEmpty ? "The cut does not reach a solid yet. Drag the arrow further, or choose New Body." :
                "The red tool cuts every solid it touches. Done applies the cut."
        case .join:
            return revolveJoinTarget == nil ? "It does not touch a solid. Drag it onto one, or choose New Body." :
                "Joins the solid it touches. Done merges it."
        case .newBody:
            return "Drag the curved arrow or tap the angle; 360° goes all the way around. Done makes a solid."
        }
    }

    private func projectionHint(_ draft: ProjectionDraft) -> String {
        if let projectionError { return projectionError }
        if draft.step == .items || draft.fixedTarget {
            if draft.items.isEmpty {
                return draft.fixedTarget ? "Tap the edges, faces, solids, or other sketches to project into this sketch. Double-tap a solid for all of it." :
                    "Tap the sketches, edges, faces, or solids to project. Double-tap a solid for all of it."
            }
            if draft.fixedTarget || draft.target != nil {
                return projectionPreview.isEmpty ? "Nothing new to project: seen from the surface, these lie edge-on or are already there." :
                    "Tap more items, or Done to add the projection."
            }
            return "Tap more geometry, or Target Plane and then the face, plane, or sketch to project onto."
        }
        guard draft.target != nil else { return "Tap the flat face, plane, or sketch to project onto." }
        if projectionPreview.isEmpty { return "Nothing new to project: seen from this surface, the items lie edge-on or are already there." }
        return draft.target?.sketchID != nil ? "Done adds the projection to that sketch." : "Done adds the projection as a new sketch."
    }

    private var guidePrefix: String { sketchGuides.isEmpty ? "" : "Purple dots are snap points. " }

    /// A session on `document`, or on an unsaved workspace when there is none. `inMemory` only labels
    /// test sessions (a session without a document never saves); it changes nothing.
    init(inMemory: Bool = false, document: ProjectDocument? = nil, access: AppAccessStore = .shared) {
        self.access = access
        hadEditingAccess = access.canEdit
        self.document = document
        history = WorkspaceHistory(workspace: document?.project.workspace ?? Workspace())
        // The file's picture shows the model as it was saved.
        if document?.project.preview != nil { pictureWorkspace = document?.project.workspace }
        if document?.project.workspace.bodies.isEmpty == false { cameraAction = .reset }
        document?.onReload = { [weak self] project in
            guard let self else { return }
            // The assistant's changes were built on the old contents; keeping them would undo the file's.
            let hadAssistantChanges = self.isAssistantWorking || self.isReviewingAssistant
            self.resetAssistant()
            self.cancelTransient(); self.selection = nil; self.tool = .select; self.endSketchMode()
            self.notesAutosave?.cancel()
            self.notesAutosave = nil
            self.pendingNotes = nil
            self.draftObjectNote = nil
            self.selectedNoteID = nil
            self.endEditingNotes()
            self.history = WorkspaceHistory(workspace: project.workspace)
            self.pictureWorkspace = project.preview != nil ? project.workspace : nil
            // Model Tree picks of rows the new contents no longer have go too.
            self.prunePicked()
            self.status = hadAssistantChanges ? "Updated from file · the assistant's changes were discarded" : "Updated from file"
            self.requestCamera(.reset)
            self.documentStateChanged()
        }
        document?.onStateChange = { [weak self] in self?.documentStateChanged() }
        document?.onReloadFailure = { [weak self] in self?.documentStateChanged() }
        document?.onError = { [weak self] error in self?.status = "Not saved"; self?.saveError = error.localizedDescription }
        isReadOnly = document?.isReadOnly ?? false
        accessObservation = access.$state.dropFirst().sink { [weak self] state in self?.accessChanged(state) }
        #if DEBUG
        if Self.isRunningUITests && document == nil { loadUITestFixture() }
        #endif
    }

    #if DEBUG
    /// The model a UI test starts with, picked by its launch arguments (Debug builds only).
    private func loadUITestFixture() {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        history = WorkspaceHistory(workspace: Workspace(shapes: [rectangle]))
        selection = .shape(rectangle.id)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-axis") {
            // A line beside the rectangle, to revolve it around.
            let axis = SketchShape(kind: .line, plane: .top, start: .init(x: -40, y: -30), end: .init(x: -40, y: 30))
            history = WorkspaceHistory(workspace: Workspace(shapes: [rectangle, axis]))
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-chain") {
            // A line from the rectangle's corner and one apart, with the rectangle's chain picked as
            // a Pencil double-tap would (UI tests' touches are fingers, which never pick).
            let tail = SketchShape(kind: .line, plane: .top, start: .init(x: 30, y: 20), end: .init(x: 45, y: 35))
            let apart = SketchShape(kind: .line, plane: .top, start: .init(x: -45, y: -20), end: .init(x: -45, y: 20))
            history = WorkspaceHistory(workspace: Workspace(shapes: [rectangle, tail, apart]))
            selection = .chain([rectangle.id, tail.id])
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-solid"),
           let profile = Geometry.profiles(in: [rectangle], on: .top).first {
            history = WorkspaceHistory(workspace: Workspace(shapes: [rectangle], bodies: [SolidBody(profile: profile, depth: 12)]))
            selection = nil
            cameraAction = .home
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-gridfinity-resize"),
           let plate = try? Gridfinity.plate(columns: 6, rows: 6, magnets: false),
           let solid = try? SolidKernel.solid(for: plate) {
            let point = SIMD3<Double>(0, 126, 1.5)
            if let face = solid.face(containing: point, normal: SIMD3(0, 1, 0)),
               let size = FaceEditing.size(of: face, on: solid, at: point) {
                history = WorkspaceHistory(workspace: Workspace(bodies: [plate]))
                selection = .face(FaceSelection(bodyID: plate.id, face: face, plane: SketchPlane.through(point, normal: SIMD3(0, 1, 0)), center: point, point: point))
                dimensionEdit = DimensionEdit(target: .faceDistance, value: size.value, anchor: CGPoint(x: 500, y: 350))
                cameraAction = .reset
            }
        }
    }
    #endif

    static var isRunningUITests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }

    func chooseTool(_ value: ModelingTool) {
        guard value == .select || value == .measure || requireNewEditingAccess() else { return }
        // Before a plane is picked, a drawing tool waits for the first stroke; putting the tool down leaves.
        if isPickingPlane, value.shapeKind != nil || value.isSketchEditTool { tool = value; return }
        if value == .measure { beginMeasure(); return }
        if value.isPlaneTool { beginPlaneTool(value); return }
        if value.isConstructionTool { beginConstruction(value); return }
        if value.isShapeTool { beginShapeTool(value); return }
        if value == .project { beginProjection(); return }
        if value == .split { beginSplit(); return }
        if value == .mirror { beginMirror(); return }
        if value == .pattern { beginPattern(); return }
        if value == .scale { beginScale(); return }
        if value == .deleteFace { beginDeleteFace(); return }
        if value == .union { beginUnion(); return }
        if value == .intersect { beginUnion(intersect: true); return }
        if value == .subtract { beginSubtract(); return }
        if value == .align { beginAlign(); return }
        if value == .fitTest { addFitTest(); return }
        if value.primitiveKind != nil {
            // Placed with a tap on the grid or a flat face.
            cancelTransient()
            endSketchMode()
            selection = nil
            tool = value
            return
        }
        if value == .screwLid {
            // A selected round boss (a container's neck) gets its lid at once.
            if let face = selectedFace, canScrewLidSelectedFace { beginScrewLid(bodyID: face.bodyID, face: face.face); return }
            cancelTransient()
            endSketchMode()
            selection = nil
            tool = .screwLid
            return
        }
        if value == .thread {
            // A selected hole wall or boss side is threaded at once.
            if let face = selectedFace, canThreadSelectedFace { beginThread(bodyID: face.bodyID, face: face.face); return }
            cancelTransient()
            endSketchMode()
            selection = nil
            tool = .thread
            return
        }
        let mirrorStart = (selectedShape, selectedProfile)
        let offsetStart = value == .offset ? offsetStartShape() : nil
        cancelTransient()
        tool = value
        if value == .dimension { dimensionDraft = DimensionDraft() }
        if value == .sketchMirror {
            // The selected shape or region is what gets copied.
            if let shape = mirrorStart.0 { sketchMirrorDraft = SketchMirrorDraft(shapes: [shape.id], step: .line) }
            else if let profile = mirrorStart.1 { sketchMirrorDraft = SketchMirrorDraft(shapes: profile.sourceIDs, step: .line) }
            else { sketchMirrorDraft = SketchMirrorDraft() }
        }
        if value == .offset, let shapeID = offsetStart { offsetDraft = OffsetDraft(shapeID: shapeID, distance: lastOffsetDistance); updateOffsetPreview() }
        let sketchTool = value.shapeKind != nil || value.isFaceFeature || value.isSketchEditTool
        if sketchTool, sketchMode == nil, let plane = selectedConstructionPlane {
            // A selected construction plane becomes the sketch plane, as a selected face does.
            startPlaneSketch(plane, tool: value)
            return
        }
        if sketchTool, sketchMode == nil, let face = selectedFace, let facePlane = face.plane {
            // A selected flat face becomes the sketch plane, exactly as if Sketch had been tapped,
            // so a circle drawn right after picking a face lands on that face.
            plane = facePlane
            sketchMode = SketchMode(plane: facePlane, face: face)
            selection = nil
            requestCamera(.alignAt(facePlane, face.center))
            return
        }
        if value.shapeKind != nil || value.isSketchEditTool {
            // A drawing tool keeps drawing in the open sketch, from the current view (Pencil may
            // draw at an angle), or starts a new sketch on the current plane, looking straight at it.
            selection = nil
            if sketchMode == nil {
                sketchMode = SketchMode(plane: plane)
                if viewCube.orientation.face?.sketchPlane != plane { requestCamera(.align(plane)) }
            }
        } else if value.finishKind != nil || value == .shell {
            // Edges and faces are picked on the solid as currently viewed; keep the camera where it is.
            endSketchMode()
            selection = nil
        } else if value.isFaceFeature {
            // On a face: tap to place. Elsewhere a peg waits for the face it stands on (a hole only
            // appears in a face sketch's dock).
            if value == .peg && sketchMode?.face == nil { endSketchMode() }
            selection = nil
        } else if value == .extrude {
            endSketchMode()
            if canExtrude { beginExtrusion() } else if canExtrudeSelectedFace { beginFaceExtrusion() }
        } else if value == .revolve {
            endSketchMode()
            if canExtrude || canExtrudeSelectedFace { beginRevolve() }
        }
    }

    /// The Sketch tile: on a selected flat face or construction plane, sketch on it; otherwise show
    /// the three world planes (and any construction planes) to pick from.
    func beginSketch() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        if selectedFace?.plane != nil { beginFaceSketch(); return }
        if let plane = selectedConstructionPlane { startPlaneSketch(plane, tool: .line); return }
        cancelTransient()
        endSketchMode()
        selection = nil
        // The sketch tools are ready at once ("No active plane"); the first stroke
        // picks the plane, or a tap on one of the planes at the origin or a flat face does.
        tool = .line
        isPickingPlane = true
    }

    /// Starts a new sketch on a world plane picked from the three at the origin, looking straight at it.
    func pickPlane(_ value: SketchPlane) {
        guard isPickingPlane else { return }
        isPickingPlane = false
        plane = value
        sketchMode = SketchMode(plane: value)
        if tool.shapeKind == nil && !tool.isSketchEditTool { tool = .line }
        if tool == .dimension { dimensionDraft = DimensionDraft() }
        requestCamera(.align(value))
    }

    /// A stroke started in open space before any plane was picked: it draws on the grid's plane,
    /// from where the camera is (no turn), and that plane becomes the sketch's.
    func startSketchOnGrid() {
        guard isPickingPlane else { return }
        isPickingPlane = false
        sketchMode = SketchMode(plane: plane)
        if tool.shapeKind == nil && !tool.isSketchEditTool { tool = .line }
        if tool == .dimension { dimensionDraft = DimensionDraft() }
    }

    func cancelPlanePick() { isPickingPlane = false }

    /// Sketches on a construction plane, looking straight at it.
    func startPlaneSketch(_ construction: ConstructionPlane, tool value: ModelingTool = .line) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        cancelTransient()
        plane = construction.plane
        sketchMode = SketchMode(plane: construction.plane, constructionPlane: construction.id)
        selection = nil
        tool = value.shapeKind != nil || value.isSketchEditTool ? value : .line
        if tool == .dimension { dimensionDraft = DimensionDraft() }
        requestCamera(.alignAt(construction.plane, construction.plane.origin))
    }

    /// A construction plane picked after the Sketch tile.
    func pickConstructionPlane(_ id: UUID) {
        guard isPickingPlane, let plane = workspace.constructionPlanes.first(where: { $0.id == id && !workspace.isHidden($0) }) else { return }
        isPickingPlane = false
        startPlaneSketch(plane, tool: tool)
    }

    // MARK: Construction planes

    /// Offset Plane or Midplane. A selected flat face, sketch region, or plane becomes the first
    /// reference.
    func beginPlaneTool(_ value: ModelingTool) {
        guard requireNewEditingAccess() else { return }
        guard value.isPlaneTool, !isEditingBlocked else { return }
        let reference = selectedPlaneReference
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = value
        planeDraft = PlaneDraft()
        if let reference { pickPlaneReference(reference) }
    }

    /// Offset Plane starts again from the tapped reference (at 0 mm); Midplane adds it, or unpicks
    /// it when tapped again, keeping at most two.
    func pickPlaneReference(_ reference: PlaneReference) {
        guard tool.isPlaneTool, var draft = planeDraft else { return }
        dimensionEdit = nil
        if tool == .offsetPlane {
            draft = PlaneDraft(references: [reference], offset: 0)
        } else if let index = draft.references.firstIndex(where: { $0.source == reference.source }) {
            draft.references.remove(at: index)
        } else {
            if draft.references.count == 2 { draft.references.removeLast() }
            draft.references.append(reference)
        }
        planeDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updatePlanePreview()
    }

    func setPlaneOffset(_ offset: Double) {
        guard var draft = planeDraft, tool == .offsetPlane, offset.isFinite else { return }
        draft.offset = max(-10_000, min(10_000, offset))
        planeDraft = draft
        updatePlanePreview()
    }

    private func updatePlanePreview() {
        guard let draft = planeDraft else { planePreview = nil; return }
        if tool == .offsetPlane, let reference = draft.references.first {
            planePreview = ConstructionPlanes.offset(from: reference, by: draft.offset)
        } else if tool == .midplane, draft.references.count == 2 {
            planePreview = ConstructionPlanes.midplane(between: draft.references[0], and: draft.references[1])
        } else {
            planePreview = nil
        }
    }

    func confirmPlane() {
        guard let plane = planePreview, !isEditingBlocked else { return }
        var next = workspace
        next.constructionPlanes.append(plane)
        planeDraft = nil
        planePreview = nil
        dimensionEdit = nil
        commit(next)
        selection = .plane(plane.id)
        tool = .select
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelPlane() { planeDraft = nil; planePreview = nil; dimensionEdit = nil; tool = .select }

    // MARK: Plane at Angle, 3-Point Plane, Tangent Plane, and Axis (October 24, 2026)

    func beginConstruction(_ value: ModelingTool) {
        guard requireNewEditingAccess() else { return }
        guard value.isConstructionTool, !isEditingBlocked else { return }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = value
        constructionDraft = ConstructionDraft()
    }

    /// A straight line: Plane at Angle turns about it (from `reference`), and Axis runs along it. A
    /// circle (an edge or sketch circle) gives Axis its center line.
    func pickConstructionLine(_ line: AlignFeature, reference: SIMD3<Double>?) {
        guard var draft = constructionDraft, tool == .planeAngle || tool == .axis else { return }
        dimensionEdit = nil
        draft.line = line
        draft.reference = reference
        draft.points = []
        draft.round = nil
        UISelectionFeedbackGenerator().selectionChanged()
        updateConstruction(draft)
    }

    /// A point for 3-Point Plane (three) or Axis (two); a picked one is taken out again.
    func pickConstructionPoint(_ point: AlignFeature) {
        guard var draft = constructionDraft, tool == .plane3Point || tool == .axis else { return }
        dimensionEdit = nil
        if let index = draft.points.firstIndex(where: { simd_distance($0.point, point.point) < 1e-6 }) {
            draft.points.remove(at: index)
        } else {
            if draft.points.count == (tool == .axis ? 2 : 3) { draft.points.removeLast() }
            draft.points.append(point)
        }
        draft.line = nil
        draft.round = nil
        UISelectionFeedbackGenerator().selectionChanged()
        updateConstruction(draft)
    }

    /// A round face of a solid tapped at `point`: Tangent Plane touches it there; Axis runs along it.
    func pickConstructionRound(bodyID: UUID, face: Int, at point: SIMD3<Double>) {
        guard var draft = constructionDraft, tool == .planeTangent || tool == .axis,
              let body = workspace.bodies.first(where: { $0.id == bodyID }), let solid = try? SolidKernel.solid(for: body),
              let cylinder = solid.faceCylinder(face) else {
            status = "Tap a round face, such as a cylinder's side or a hole's wall"
            return
        }
        dimensionEdit = nil
        let axis = simd_normalize(cylinder.direction)
        let heights = solid.faceEdges(face).flatMap { solid.edgeSamples($0, count: 9) }.map { simd_dot($0 - cylinder.point, axis) }
        draft.round = ConstructionDraft.Round(axisPoint: cylinder.point, axisDirection: axis, radius: cylinder.radius, point: point,
                                              extent: (heights.min() ?? -10)...(heights.max() ?? 10))
        draft.line = nil
        draft.points = []
        UISelectionFeedbackGenerator().selectionChanged()
        updateConstruction(draft)
    }

    private func updateConstruction(_ draft: ConstructionDraft) {
        constructionDraft = draft
        constructionPreview = nil
        axisPreview = nil
        switch tool {
        case .planeAngle:
            guard let line = draft.line, line.kind == .line, let reference = draft.reference, let a = line.outline.first, let b = line.outline.last else { return }
            constructionPreview = ConstructionPlanes.atAngle(through: line.point, along: line.direction, length: simd_distance(a, b),
                                                             reference: reference, degrees: draft.angle)
        case .plane3Point:
            guard draft.points.count == 3 else { return }
            constructionPreview = ConstructionPlanes.through(draft.points[0].point, draft.points[1].point, draft.points[2].point)
        case .planeTangent:
            guard let round = draft.round else { return }
            constructionPreview = ConstructionPlanes.tangent(toCylinderAt: round.axisPoint, axisDirection: round.axisDirection, radius: round.radius,
                                                             through: round.point, height: round.extent.upperBound - round.extent.lowerBound)
        case .axis:
            if let round = draft.round {
                // Along the round face, a little past its ends.
                let margin = max(2, 0.1 * (round.extent.upperBound - round.extent.lowerBound))
                axisPreview = (round.axisPoint + round.axisDirection * (round.extent.lowerBound - margin),
                               round.axisPoint + round.axisDirection * (round.extent.upperBound + margin))
            } else if let line = draft.line {
                if line.kind == .line, let a = line.outline.first, let b = line.outline.last {
                    axisPreview = (a, b)
                } else {
                    // A circle's center line, as long as the circle is across.
                    let reach = line.outline.first.map { simd_distance($0, line.point) } ?? 10
                    axisPreview = (line.point - line.direction * reach, line.point + line.direction * reach)
                }
            } else if draft.points.count == 2, simd_distance(draft.points[0].point, draft.points[1].point) > 0.01 {
                axisPreview = (draft.points[0].point, draft.points[1].point)
            }
        default: break
        }
    }

    var canConfirmConstruction: Bool { constructionPreview != nil || axisPreview != nil }

    /// One undo step; the new plane, or the new axis's sketch, is selected.
    func confirmConstruction() {
        guard !isEditingBlocked else { return }
        if let plane = constructionPreview {
            var next = workspace
            next.constructionPlanes.append(plane)
            clearConstruction()
            commit(next)
            selection = .plane(plane.id)
            status = "Added a construction plane"
        } else if let axis = axisPreview, let result = ConstructionAxes.adding(from: axis.from, to: axis.to, in: workspace) {
            clearConstruction()
            commit(result.workspace)
            selection = .sketch(result.sketch)
            status = "Added \(sketchName(of: result.sketch) ?? "an axis")"
        } else { return }
        tool = .select
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelConstruction() { clearConstruction(); dimensionEdit = nil; tool = .select }

    private func clearConstruction() {
        if constructionDraft != nil { constructionDraft = nil }
        if constructionPreview != nil { constructionPreview = nil }
        if axisPreview != nil { axisPreview = nil }
    }

    /// The normal of a flat face of `bodyID` along edge `edge`, for Plane at Angle's 0°.
    func flatFaceNormal(bodyID: UUID, beside edge: Int) -> SIMD3<Double>? {
        guard let body = workspace.bodies.first(where: { $0.id == bodyID }), let solid = try? SolidKernel.solid(for: body) else { return nil }
        return (0..<solid.faceCount).lazy.compactMap { face in solid.faceEdges(face).contains(edge) ? solid.facePlane(face)?.normal : nil }.first
    }

    // MARK: Draft, Loft, Sweep, and Rib (October 24, 2026)

    func beginShapeTool(_ value: ModelingTool) {
        guard requireNewEditingAccess() else { return }
        guard value.isShapeTool, !isEditingBlocked else { return }
        // A selected region starts a loft or sweep; a selected line, a rib.
        let region = selectedProfiles.first, line = selectedShape.flatMap { $0.kind == .line ? $0.id : nil }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = value
        var draft = ShapeToolDraft()
        if (value == .loft || value == .sweep), let region { draft.regions = [region] }
        if value == .rib, let line { draft.line = line }
        updateShapeTool(draft)
    }

    /// Draft: the flat face the others lean from (it stays put); the pull runs into the solid.
    func pickDraftNeutral(bodyID: UUID, point: SIMD3<Double>, outward: SIMD3<Double>) {
        guard tool == .draft, var draft = shapeToolDraft else { return }
        draft.bodyID = bodyID
        draft.neutral = point
        draft.pull = -simd_normalize(outward)
        draft.faces = []
        UISelectionFeedbackGenerator().selectionChanged()
        updateShapeTool(draft)
    }

    /// Draft: a face of the solid to lean, or taken out again.
    func toggleDraftFace(bodyID: UUID, point: SIMD3<Double>) {
        guard tool == .draft, var draft = shapeToolDraft, draft.bodyID == bodyID,
              let body = workspace.bodies.first(where: { $0.id == bodyID }), let solid = try? SolidKernel.solid(for: body),
              let face = solid.face(near: point, tolerance: 1e-3) else { return }
        if let index = draft.faces.firstIndex(where: { solid.face(near: $0, tolerance: 1e-3) == face }) { draft.faces.remove(at: index) }
        else { draft.faces.append(point) }
        UISelectionFeedbackGenerator().selectionChanged()
        updateShapeTool(draft)
    }

    /// Rib: the sketch line it grows from.
    func pickRibLine(_ shape: SketchShape) {
        guard tool == .rib, var draft = shapeToolDraft else { return }
        guard shape.kind == .line else {
            // A result on its way would clear this.
            shapeToolPreviews.drop()
            draft.error = "A rib grows from a straight sketch line."
            shapeToolDraft = draft
            return
        }
        draft.line = shape.id
        draft.side = nil
        updateShapeTool(draft)
    }

    /// Rib: the web on the other side of its line.
    func flipRib() {
        guard tool == .rib, var draft = shapeToolDraft, let side = currentRibSide else { return }
        draft.side = -side
        updateShapeTool(draft)
    }
    private var currentRibSide: Double? {
        guard let body = shapeToolPreview?.bodies.first(where: { $0.cuts.last?.rib != nil && !workspace.bodies.contains($0) }) else { return nil }
        return body.cuts.last?.rib?.side
    }

    /// Loft: a region added in order, or taken out again. Sweep: the region to carry along the path.
    func pickShapeRegion(_ profile: SketchProfile) {
        guard tool == .loft || tool == .sweep, var draft = shapeToolDraft else { return }
        if tool == .sweep {
            draft.regions = [profile]
        } else if let index = draft.regions.firstIndex(where: { $0.id == profile.id }) {
            draft.regions.remove(at: index)
        } else {
            draft.regions.append(profile)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        updateShapeTool(draft)
    }

    /// Sweep: the sketch line, arc, or spline (with lines joined to a line) the region follows.
    func pickSweepPath(_ shape: SketchShape) {
        guard tool == .sweep, var draft = shapeToolDraft else { return }
        draft.path = shape.id
        updateShapeTool(draft)
    }

    func setLoftRuled(_ ruled: Bool) {
        guard tool == .loft, var draft = shapeToolDraft else { return }
        draft.ruled = ruled
        updateShapeTool(draft)
    }

    /// Builds the Draft, Rib, Loft, or Sweep preview off the main thread on screen: each pick leans
    /// faces of, or adds a web to, a whole solid, which stopped the app on detailed solids (November
    /// 11, 2026). Done waits for the latest.
    private func updateShapeTool(_ draft: ShapeToolDraft) {
        var draft = draft
        draft.error = nil
        shapeToolDraft = draft
        shapeToolPreviews.submit(ShapeToolRequest(base: workspace, tool: tool, draft: draft), inBackground: buildsPreviewsInBackground)
    }

    /// The preview for `request`'s picks, or why there is none; on any thread.
    nonisolated private static func buildShapeToolPreview(_ request: ShapeToolRequest) -> ShapeToolOutput {
        let performance = Performance.begin("Shape tool preview")
        defer { Performance.end(performance) }
        let workspace = request.base, draft = request.draft
        var output = ShapeToolOutput(draft: draft)
        switch request.tool {
        case .draft:
            guard let id = draft.bodyID, let neutral = draft.neutral, let pull = draft.pull, !draft.faces.isEmpty,
                  let index = workspace.bodies.firstIndex(where: { $0.id == id }) else { break }
            guard let drafted = Drafting.drafting(workspace.bodies[index], faces: draft.faces, pull: pull, origin: neutral, angle: draft.angle) else {
                output.error = "Those faces cannot lean that way: a face square to the pull, or neighbors that cannot follow. Try a smaller angle."
                break
            }
            var next = workspace
            next.bodies[index] = drafted
            output.preview = next
            meshForDisplay([drafted])
        case .rib:
            guard let id = draft.line, let line = workspace.shapes.first(where: { $0.id == id }) else { break }
            let a = line.plane.point(line.start), b = line.plane.point(line.end), n = line.plane.normalAxis
            for index in workspace.bodies.indices where !workspace.isHidden(workspace.bodies[index]) {
                if let ribbed = Ribs.ribbing(workspace.bodies[index], from: a, to: b, normal: n, thickness: draft.thickness, side: draft.side) {
                    var next = workspace
                    next.bodies[index] = ribbed
                    output.preview = next
                    meshForDisplay([ribbed])
                    return output
                }
            }
            output.error = "A rib grows from the line until it meets a solid, and this one meets none. Draw the line across a corner, on a plane through the solid."
        case .loft:
            guard draft.regions.count >= 2 else { break }
            do {
                let solid = try ShapedSolids.loft(draft.regions, ruled: draft.ruled)
                output.preview = ShapedSolids.adding(solid, named: "Loft", to: workspace)?.workspace
            } catch { output.error = "Those regions cannot be lofted. Try regions that face the same way, one above another." }
        case .sweep:
            guard let section = draft.regions.first, let id = draft.path, let shape = workspace.shapes.first(where: { $0.id == id }),
                  let path = ShapedSolids.chain(from: shape, in: workspace.shapes) else { break }
            do {
                let solid = try ShapedSolids.sweep(section, along: path.points, smooth: path.smooth)
                output.preview = ShapedSolids.adding(solid, named: "Sweep", to: workspace)?.workspace
            } catch { output.error = "The region cannot follow that path. Start the path at the region, across it, and keep bends wider than the region." }
        default: break
        }
        return output
    }

    /// A result for picks since changed is left for the newer one.
    private func applyShapeToolPreview(_ output: ShapeToolOutput) {
        guard var current = shapeToolDraft else { return }
        var picks = current
        picks.error = nil
        guard picks == output.draft else { return }
        current.error = output.error
        shapeToolDraft = current
        shapeToolPreview = output.preview
    }

    /// Waits for the background Draft, Rib, Loft, or Sweep preview (tests).
    func shapeToolPreviewSettled() async { await shapeToolPreviews.settled() }

    /// One undo step; the changed or new solid is selected.
    func confirmShapeTool() {
        shapeToolPreviews.settle { shapeToolDraft.map { ShapeToolRequest(base: workspace, tool: tool, draft: $0) } }
        guard let preview = shapeToolPreview, !isEditingBlocked else { return }
        let before = workspace
        let kind = tool
        clearShapeTool()
        commit(preview)
        let changed = preview.bodies.first { body in !before.bodies.contains(body) }
        selection = changed.map { .body($0.id) }
        tool = .select
        status = ["draft": "Drafted", "rib": "Added a rib", "loft": "Lofted", "sweep": "Swept"][kind.rawValue] ?? "Done"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelShapeTool() { clearShapeTool(); dimensionEdit = nil; tool = .select }

    private func clearShapeTool() {
        shapeToolPreviews.drop()
        if shapeToolDraft != nil { shapeToolDraft = nil }
        if shapeToolPreview != nil { shapeToolPreview = nil }
    }

    // MARK: Split Body

    /// Split Body. A selected solid (or its face or edge) is the first solid to split, and a
    /// selected construction plane the first tool.
    func beginSplit() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        let bodyID: UUID?
        switch selection {
        case .body(let id), .edge(let id, _): bodyID = id
        case .face(let face): bodyID = face.bodyID
        default: bodyID = nil
        }
        let plane = selectedConstructionPlane
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .split
        var draft = SplitDraft()
        if let bodyID { draft.bodies = [bodyID]; draft.step = .tools }
        if let plane { draft.tools = [SplitTool(source: .plane(plane.id), plane: plane.plane)] }
        splitDraft = draft
        updateSplitPreview()
    }

    func chooseSplitStep(_ step: SplitDraft.Step) {
        guard var draft = splitDraft else { return }
        draft.step = step
        splitDraft = draft
    }

    func toggleSplitBody(_ id: UUID) {
        guard var draft = splitDraft, workspace.isShown(body: id) else { return }
        if let index = draft.bodies.firstIndex(of: id) { draft.bodies.remove(at: index) } else { draft.bodies.append(id) }
        splitDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateSplitPreview()
    }

    /// Adds a tool, or removes it when it is already picked.
    func toggleSplitTool(_ tool: SplitTool) {
        guard var draft = splitDraft else { return }
        if let index = draft.tools.firstIndex(where: { $0.source == tool.source }) { draft.tools.remove(at: index) } else { draft.tools.append(tool) }
        splitDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateSplitPreview()
    }

    func setKeepOriginals(_ keep: Bool) {
        guard var draft = splitDraft else { return }
        draft.keepOriginals = keep
        splitDraft = draft
        updateSplitPreview()
    }

    private func pickSplitRow(_ row: ModelSelection) {
        guard let draft = splitDraft else { return }
        switch (draft.step, row) {
        case (.bodies, .body(let id)): toggleSplitBody(id)
        case (.tools, .plane(let id)):
            if let plane = workspace.constructionPlanes.first(where: { $0.id == id }) { toggleSplitTool(SplitTool(source: .plane(id), plane: plane.plane)) }
        case (.tools, .shape(let id)):
            if let tool = workspace.shapes.first(where: { $0.id == id }).flatMap(SplitTool.line) { toggleSplitTool(tool) }
        default: break
        }
    }

    /// Each picked solid replaced by its pieces (after the original, when it is kept).
    /// Built off the main thread on screen.
    private func updateSplitPreview() {
        guard let request = splitPreviewRequest() else {
            splitPreviews.drop(); splitPreview = nil; splitPieceCount = 0; splitError = nil; return
        }
        splitPreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    private func splitPreviewRequest() -> SplitPreviewRequest? {
        guard let draft = splitDraft, !draft.tools.isEmpty, !draft.bodies.isEmpty else { return nil }
        return SplitPreviewRequest(base: workspace, draft: draft)
    }

    /// On any thread.
    nonisolated private static func buildSplitPreview(_ request: SplitPreviewRequest) -> CombinePreviewOutput {
        let performance = Performance.begin("Split preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        var next = request.base, count = 0, made: [SolidBody] = []
        for id in draft.bodies {
            guard let index = next.bodies.firstIndex(where: { $0.id == id }),
                  let pieces = Splitting.pieces(of: next.bodies[index], with: draft.tools) else { continue }
            if draft.keepOriginals { next.bodies.insert(contentsOf: pieces, at: index + 1) }
            else { next.bodies.replaceSubrange(index...index, with: pieces) }
            count += pieces.count
            made += pieces
        }
        guard count > 0 else { return CombinePreviewOutput(error: "That does not cut through the solid. Pick another plane, face, or sketch.") }
        meshForDisplay(made)
        return CombinePreviewOutput(preview: next, count: count)
    }

    private func applySplitPreview(_ output: CombinePreviewOutput) {
        guard splitDraft != nil else { return }
        splitPreview = output.preview
        splitPieceCount = output.count
        splitError = output.error
    }

    /// Waits for the background Split preview (tests).
    func splitPreviewSettled() async { await splitPreviews.settled() }

    /// One undo step; the first piece is selected.
    func confirmSplit() {
        splitPreviews.settle { splitPreviewRequest() }
        guard let preview = splitPreview, splitDraft != nil, !isEditingBlocked else { return }
        let original = Set(workspace.bodies.map(\.id))
        let first = preview.bodies.first { !original.contains($0.id) }?.id
        let count = splitPieceCount
        clearSplit()
        commit(preview)
        status = "Split into \(count) solids"
        selection = first.map { .body($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelSplit() { clearSplit(); dimensionEdit = nil }

    private func clearSplit() {
        if tool == .split { tool = .select }
        if splitDraft != nil { splitDraft = nil }
        splitPreviews.drop()
        if splitPreview != nil { splitPreview = nil }
        splitPieceCount = 0
        if splitError != nil { splitError = nil }
    }

    // MARK: Mirror

    /// Mirror. A selected solid (or its face or edge) or sketch is the first item, and a selected
    /// construction plane the mirror plane.
    func beginMirror() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        var draft = MirrorDraft()
        switch selection {
        case .body(let id), .edge(let id, _): draft.bodies = [id]
        case .face(let face): draft.bodies = [face.bodyID]
        case .sketch(let id): draft.sketches = [id]
        case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { draft.sketches = [sketch] }
        case .group(let id): (draft.bodies, draft.sketches) = (workspace.contents(of: id).bodies, workspace.contents(of: id).sketches)
        default: break
        }
        if pickedBodies.count > 1 { draft.bodies = pickedBodies }
        if let plane = selectedConstructionPlane { draft.plane = MirrorPlane(source: .plane(plane.id), plane: plane.plane) }
        if !draft.isEmpty { draft.step = .plane }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .mirror
        mirrorDraft = draft
        updateMirrorPreview()
    }

    func chooseMirrorStep(_ step: MirrorDraft.Step) {
        guard var draft = mirrorDraft else { return }
        draft.step = step
        mirrorDraft = draft
    }

    func toggleMirrorBody(_ id: UUID) {
        guard var draft = mirrorDraft, workspace.isShown(body: id) else { return }
        if let index = draft.bodies.firstIndex(of: id) { draft.bodies.remove(at: index) } else { draft.bodies.append(id) }
        mirrorDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateMirrorPreview()
    }

    func toggleMirrorSketch(_ id: UUID) {
        guard var draft = mirrorDraft, workspace.isShown(sketch: id) else { return }
        if let index = draft.sketches.firstIndex(of: id) { draft.sketches.remove(at: index) } else { draft.sketches.append(id) }
        mirrorDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateMirrorPreview()
    }

    /// Picks the mirror plane; picking it again clears it. There is one mirror plane.
    func pickMirrorPlane(_ plane: MirrorPlane) {
        guard var draft = mirrorDraft else { return }
        draft.plane = draft.plane?.source == plane.source ? nil : plane
        mirrorDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateMirrorPreview()
    }

    func setMirrorKeepOriginals(_ keep: Bool) {
        guard var draft = mirrorDraft else { return }
        draft.keepOriginals = keep
        mirrorDraft = draft
        updateMirrorPreview()
    }

    private func pickMirrorRow(_ row: ModelSelection) {
        guard let draft = mirrorDraft else { return }
        switch (draft.step, row) {
        case (.items, .body(let id)): toggleMirrorBody(id)
        case (.items, .sketch(let id)): toggleMirrorSketch(id)
        case (.items, .shape(let id)): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { toggleMirrorSketch(sketch) }
        case (.plane, .plane(let id)):
            if let plane = workspace.constructionPlanes.first(where: { $0.id == id }) { pickMirrorPlane(MirrorPlane(source: .plane(id), plane: plane.plane)) }
        case (.plane, .shape(let id)):
            if let plane = workspace.shapes.first(where: { $0.id == id }).flatMap(MirrorPlane.line) { pickMirrorPlane(plane) }
        default: break
        }
    }

    /// Mirrors off the main thread on screen: a mirrored solid's definition is new, so it is built
    /// from its whole history, which stopped the app for seconds on each pick of a detailed solid
    /// (November 11, 2026).
    private func updateMirrorPreview() {
        guard let request = mirrorPreviewRequest() else {
            mirrorPreviews.drop()
            isBuildingMirror = false
            mirrorPreview = nil
            return
        }
        isBuildingMirror = true
        mirrorPreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    private func mirrorPreviewRequest() -> MirrorPreviewRequest? {
        guard let draft = mirrorDraft, draft.plane != nil, !draft.isEmpty else { return nil }
        return MirrorPreviewRequest(base: workspace, draft: draft)
    }

    /// The draft it was built for, and the mirrored workspace (nil when it cannot be mirrored); on any thread.
    nonisolated private static func buildMirrorPreview(_ request: MirrorPreviewRequest) -> (MirrorDraft, Workspace?) {
        let performance = Performance.begin("Mirror preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        guard let plane = draft.plane,
              let result = Mirroring.mirror(request.base, bodies: draft.bodies, sketches: draft.sketches, across: plane.plane,
                                            keepOriginals: draft.keepOriginals) else { return (draft, nil) }
        meshForDisplay(result.workspace.bodies.filter { result.bodies.contains($0.id) })
        return (draft, result.workspace)
    }

    /// A result for picks since changed is left for the newer one.
    private func applyMirrorPreview(_ output: (MirrorDraft, Workspace?)) {
        guard mirrorDraft == output.0 else { return }
        isBuildingMirror = false
        mirrorPreview = output.1
    }

    /// Waits for the background Mirror preview (tests).
    func mirrorPreviewSettled() async { await mirrorPreviews.settled() }

    /// One undo step; the first mirrored solid (or sketch) is selected.
    func confirmMirror() {
        mirrorPreviews.settle { mirrorPreviewRequest() }
        guard let draft = mirrorDraft, let plane = draft.plane, mirrorPreview != nil, !isEditingBlocked,
              let result = Mirroring.mirror(workspace, bodies: draft.bodies, sketches: draft.sketches, across: plane.plane,
                                            keepOriginals: draft.keepOriginals) else { return }
        clearMirror()
        commit(result.workspace)
        let count = result.bodies.count + result.sketches.count
        status = count == 1 ? "Mirrored" : "Mirrored \(count) items"
        selection = result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelMirror() { clearMirror(); dimensionEdit = nil }

    private func clearMirror() {
        mirrorPreviews.drop()
        isBuildingMirror = false
        if tool == .mirror { tool = .select }
        if mirrorDraft != nil { mirrorDraft = nil }
        if mirrorPreview != nil { mirrorPreview = nil }
    }

    // MARK: Pattern

    /// Pattern. A selected solid (or its face or edge) or sketch is the first item.
    func beginPattern() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        var draft = PatternDraft()
        switch selection {
        case .body(let id), .edge(let id, _): draft.bodies = [id]
        case .face(let face): draft.bodies = [face.bodyID]
        case .sketch(let id): draft.sketches = [id]
        case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { draft.sketches = [sketch] }
        case .group(let id): (draft.bodies, draft.sketches) = (workspace.contents(of: id).bodies, workspace.contents(of: id).sketches)
        default: break
        }
        if pickedBodies.count > 1 { draft.bodies = pickedBodies }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .pattern
        placePatternGizmo(&draft)
        patternDraft = draft
        updatePatternPreview()
    }

    /// The gizmo at the items' middle with the first item's own axes, unless its center was placed.
    private func placePatternGizmo(_ draft: inout PatternDraft) {
        if draft.placedCenter == nil {
            let plane = draft.bodies.first.flatMap { id in workspace.bodies.first { $0.id == id }?.profile.plane }
                ?? draft.sketches.first.flatMap { workspace.sketch($0)?.plane }
            if let plane { draft.ownAxes = [plane.xAxis, plane.yAxis, plane.normalAxis] }
            draft.axes = draft.ownAxes
            if let center = Patterning.center(of: workspace, bodies: draft.bodies, sketches: draft.sketches) { draft.center = center }
        }
        draft.syncSpec()
    }

    func togglePatternBody(_ id: UUID) {
        guard var draft = patternDraft, workspace.isShown(body: id) else { return }
        if let index = draft.bodies.firstIndex(of: id) { draft.bodies.remove(at: index) } else { draft.bodies.append(id) }
        placePatternGizmo(&draft)
        patternDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updatePatternPreview()
    }

    func togglePatternSketch(_ id: UUID) {
        guard var draft = patternDraft, workspace.isShown(sketch: id) else { return }
        if let index = draft.sketches.firstIndex(of: id) { draft.sketches.remove(at: index) } else { draft.sketches.append(id) }
        placePatternGizmo(&draft)
        patternDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updatePatternPreview()
    }

    private func pickPatternRow(_ row: ModelSelection) {
        switch row {
        case .body(let id): togglePatternBody(id)
        case .sketch(let id): togglePatternSketch(id)
        case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { togglePatternSketch(sketch) }
        default: break
        }
    }

    private func updatePattern(_ change: (inout PatternDraft) -> Void) {
        guard var draft = patternDraft else { return }
        change(&draft)
        draft.syncSpec()
        if draft != patternDraft { patternDraft = draft }
        updatePatternPreview()
    }

    func setPatternKind(_ kind: PatternSpec.Kind) { updatePattern { $0.spec.kind = kind } }
    func setPatternDefinition(_ definition: PatternSpec.Definition) { updatePattern { $0.spec.definition = definition } }
    func setPatternOrientation(_ orientation: PatternSpec.Orientation) { updatePattern { $0.spec.orientation = orientation } }

    /// Instances along the last dragged direction, or round the circle, the original included.
    /// False (and nothing changes) outside 2–100 or when the whole pattern would pass 100.
    @discardableResult func setPatternCount(_ count: Int) -> Bool {
        guard var draft = patternDraft, PatternSpec.countRange.contains(count) else { return false }
        if draft.spec.kind == .linear { draft.spec.directions[draft.linearAxis].count = count } else { draft.spec.count = count }
        guard draft.spec.instanceCount <= PatternSpec.maximumInstances else { return false }
        updatePattern { $0 = draft }
        return true
    }

    /// The total or spacing along a direction (millimeters; 0 leaves it unused). It becomes the
    /// direction the quantity applies to.
    func setPatternDistance(_ distance: Double, axis: Int) {
        guard distance.isFinite, (0..<3).contains(axis) else { return }
        updatePattern { draft in
            draft.linearAxis = axis
            draft.spec.directions[axis].distance = max(-10_000, min(10_000, distance))
            // Too many copies: this direction drops back to one row until the quantity comes down.
            if draft.spec.instanceCount > PatternSpec.maximumInstances { draft.spec.directions[axis].distance = 0 }
        }
    }

    /// The total or spacing angle of a circular pattern, about one of the gizmo's axes.
    func setPatternAngle(_ angle: Double, axis: Int) {
        guard angle.isFinite, (0..<3).contains(axis) else { return }
        updatePattern { draft in
            draft.circularAxis = axis
            draft.spec.angle = max(-3600, min(3600, angle))
        }
    }

    /// Pencil down on the gizmo center of a circular pattern: drag it to where the copies turn about.
    @discardableResult func beginPatternCenterDrag() -> Bool {
        guard let draft = patternDraft, draft.spec.kind == .circular, !isEditingBlocked else { return false }
        dimensionEdit = nil
        patternCenterStart = draft
        isDraggingPatternCenter = true
        return true
    }

    /// The gizmo center over a snap (a corner, edge, or center of any visible solid, a sketch point,
    /// or the origin). Over a circle or edge one axis turns to follow it, so the copies turn about it.
    func previewPatternCenter(_ snap: TransformPivot?) {
        guard isDraggingPatternCenter else { return }
        if snapLabel != (snap?.kind.title ?? "") { snapLabel = snap?.kind.title ?? "" }
        guard let snap else { return }
        updatePattern { draft in
            draft.center = snap.point
            draft.axes = snap.axes(from: draft.ownAxes)
            draft.placedCenter = snap.kind
            if let direction = snap.direction, simd_length(direction) > 1e-9 {
                // Turn about the axis that followed the edge or circle.
                let d = simd_normalize(direction), axes = draft.axes
                draft.circularAxis = (0..<3).max { abs(simd_dot(axes[$0], d)) < abs(simd_dot(axes[$1], d)) } ?? 2
            }
        }
    }

    func finishPatternCenterDrag(cancelled: Bool) {
        guard isDraggingPatternCenter else { return }
        isDraggingPatternCenter = false
        snapLabel = ""
        if cancelled, let start = patternCenterStart { updatePattern { $0 = start } }
        patternCenterStart = nil
    }

    private func updatePatternPreview() {
        guard let draft = patternDraft else {
            patternGhosts = [:]
            if patternPreview != nil { patternPreview = nil }
            return
        }
        let result = Patterning.pattern(workspace, bodies: draft.bodies, sketches: draft.sketches, spec: draft.spec, checked: false)
        // Which original each preview copy is, and where it goes: the canvas draws copies as the
        // original's picture moved, instead of building and meshing every copy on every drag step.
        var ghosts: [UUID: PatternGhost] = [:]
        if let result, !result.placements.isEmpty {
            for (index, id) in result.bodies.enumerated() {
                let source = draft.bodies[index / result.placements.count]
                ghosts[id] = PatternGhost(source: source, transform: result.placements[index % result.placements.count])
            }
        }
        patternGhosts = ghosts
        if result?.workspace != patternPreview { patternPreview = result?.workspace }
    }

    private func patternHint(_ draft: PatternDraft) -> String {
        if draft.isEmpty { return "Tap the solids and sketches to pattern." }
        if patternPreview != nil {
            return draft.spec.kind == .linear ? "Drag another arrow for more directions, or tap a value to type it. Done adds the copies."
                : "Turn the ring further or tap the angle to type it. Done adds the copies."
        }
        if draft.spec.instanceCount > 1 { return "That cannot be patterned. Try a smaller quantity." }
        return draft.spec.kind == .linear ? "Drag an arrow to lay out copies along it, or tap more items."
            : "Drag the center to where the copies turn about, then turn a ring."
    }

    /// One undo step; the copies are independent solids and sketches, and the first is selected.
    func confirmPattern() {
        guard let draft = patternDraft, patternPreview != nil, !isEditingBlocked else { return }
        guard let result = Patterning.pattern(workspace, bodies: draft.bodies, sketches: draft.sketches, spec: draft.spec) else {
            status = "A copy cannot be built"
            return
        }
        clearPattern()
        commit(result.workspace)
        let count = result.bodies.count + result.sketches.count
        status = count == 1 ? "Patterned 1 copy" : "Patterned \(count) copies"
        selection = result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelPattern() { clearPattern(); dimensionEdit = nil }

    private func clearPattern() {
        if tool == .pattern { tool = .select }
        if patternDraft != nil { patternDraft = nil }
        if patternPreview != nil { patternPreview = nil }
        patternGhosts = [:]
        if isDraggingPatternCenter { isDraggingPatternCenter = false; snapLabel = "" }
        patternCenterStart = nil
    }

    // MARK: Scale

    /// Scale. A selected solid (or its face or edge) or sketch is the first item.
    func beginScale() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        var draft = ScaleDraft()
        switch selection {
        case .body(let id), .edge(let id, _): draft.bodies = [id]
        case .face(let face): draft.bodies = [face.bodyID]
        case .sketch(let id): draft.sketches = [id]
        case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { draft.sketches = [sketch] }
        case .group(let id): (draft.bodies, draft.sketches) = (workspace.contents(of: id).bodies, workspace.contents(of: id).sketches)
        default: break
        }
        if pickedBodies.count > 1 { draft.bodies = pickedBodies }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .scale
        placeScaleGizmo(&draft)
        scaleDraft = draft
        updateScalePreview()
    }

    /// The gizmo's axes (the first item's own) and center (by the pivot choice).
    private func placeScaleGizmo(_ draft: inout ScaleDraft) {
        let plane = draft.bodies.first.flatMap { id in workspace.bodies.first { $0.id == id }?.profile.plane }
            ?? draft.sketches.first.flatMap { workspace.sketch($0)?.plane }
        draft.axes = plane.map { [$0.xAxis, $0.yAxis, $0.normalAxis] } ?? PatternDraft.worldAxes
        guard let bounds = Scaling.bounds(of: workspace, bodies: draft.bodies, sketches: draft.sketches) else { draft.center = .zero; return }
        let middle = (bounds.min + bounds.max) / 2
        switch draft.pivot {
        case .center: draft.center = middle
        case .base: draft.center = SIMD3(middle.x, middle.y, bounds.min.z)
        case .origin: draft.center = .zero
        }
    }

    func toggleScaleBody(_ id: UUID) {
        guard var draft = scaleDraft, workspace.isShown(body: id) else { return }
        if let index = draft.bodies.firstIndex(of: id) { draft.bodies.remove(at: index) } else { draft.bodies.append(id) }
        placeScaleGizmo(&draft)
        scaleDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateScalePreview()
    }

    func toggleScaleSketch(_ id: UUID) {
        guard var draft = scaleDraft, workspace.isShown(sketch: id) else { return }
        if let index = draft.sketches.firstIndex(of: id) { draft.sketches.remove(at: index) } else { draft.sketches.append(id) }
        placeScaleGizmo(&draft)
        scaleDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateScalePreview()
    }

    private func pickScaleRow(_ row: ModelSelection) {
        switch row {
        case .body(let id): toggleScaleBody(id)
        case .sketch(let id): toggleScaleSketch(id)
        case .shape(let id): if let sketch = workspace.shapes.first(where: { $0.id == id })?.sketch { toggleScaleSketch(sketch) }
        default: break
        }
    }

    /// One percentage for everything, or one along each axis. Going back to one keeps the first.
    func setScaleUniform(_ uniform: Bool) {
        guard var draft = scaleDraft else { return }
        draft.uniform = uniform
        if uniform { draft.percents = SIMD3(repeating: draft.percents.x) }
        scaleDraft = draft
        updateScalePreview()
    }

    func setScalePivot(_ pivot: ScaleDraft.Pivot) {
        guard var draft = scaleDraft else { return }
        draft.pivot = pivot
        placeScaleGizmo(&draft)
        scaleDraft = draft
        updateScalePreview()
    }

    func setScaleCopy(_ copy: Bool) {
        guard var draft = scaleDraft else { return }
        draft.copy = copy
        scaleDraft = draft
        updateScalePreview()
    }

    /// The percentage along one axis (0–2) or of everything (3, or any axis while uniform). False
    /// (and nothing changes) when the items cannot be scaled that much.
    @discardableResult func setScalePercent(_ percent: Double, axis: Int) -> Bool {
        guard var draft = scaleDraft, percent.isFinite, (0.1...10_000).contains(percent) else { return false }
        let previous = draft
        if draft.uniform || axis == 3 { draft.percents = SIMD3(repeating: percent) } else { draft.percents[axis] = percent }
        scaleDraft = draft
        updateScalePreview()
        // On screen the scale builds in the background, and one that does not fit says so once built.
        if !buildsPreviewsInBackground, scalePreview == nil, !draft.isEmpty, draft.percents != SIMD3(repeating: 100) {
            scaleDraft = previous
            let error = scaleError
            updateScalePreview()
            scaleError = error
            return false
        }
        return true
    }

    /// Scales off the main thread on screen: each solid scaled builds a scale step and checks its
    /// whole definition, on every sample of a drag of the gizmo (November 11, 2026). Done waits for the latest.
    private func updateScalePreview() {
        guard let draft = scaleDraft, !draft.isEmpty else { scalePreviews.drop(); scaleError = nil; scalePreview = nil; return }
        if !draft.uniform && !draft.sketches.isEmpty {
            scalePreviews.drop()
            scalePreview = nil
            scaleError = "Sketches scale by one percentage. Turn on Uniform, or tap the sketch to leave it out."
            return
        }
        guard draft.percents != SIMD3(repeating: 100) || draft.copy else { scalePreviews.drop(); scaleError = nil; scalePreview = nil; return }
        // Until it is built (or, while the gizmo is dragged, until it is let go), the canvas shows the
        // solids scaled on screen (`scaleGhost`): each built step drew a whole new solid on the main
        // thread, so a drag on a detailed solid stuttered behind the Pencil (November 11, 2026).
        scalePreview = nil
        scaleError = nil
        guard !isDraggingScale || !buildsPreviewsInBackground else { scalePreviews.drop(); return }
        scalePreviews.submit(ScalePreviewRequest(base: workspace, draft: draft), inBackground: buildsPreviewsInBackground)
    }

    func beginScaleDrag() { if scaleDraft != nil { isDraggingScale = true } }

    /// The gizmo let go: the solids are built at their last size.
    func endScaleDrag() {
        guard isDraggingScale else { return }
        isDraggingScale = false
        updateScalePreview()
    }

    /// While the solids being scaled are not built yet: which ones, whether they are copies (the
    /// originals stay), and the world transform that takes each original where its scaled solid goes.
    var scaleGhost: (bodies: [UUID], copy: Bool, transform: simd_double4x4)? {
        guard let draft = scaleDraft, !draft.bodies.isEmpty, scalePreview == nil, scaleError == nil,
              draft.percents != SIMD3(repeating: 100) || draft.copy, draft.axes.count >= 2 else { return nil }
        let x = simd_normalize(draft.axes[0]), y = simd_normalize(draft.axes[1]), z = simd_normalize(simd_cross(x, y))
        let frame = simd_double3x3(x, y, z)
        let linear = frame * simd_double3x3(diagonal: draft.factors) * frame.transpose
        let shift = draft.center - linear * draft.center
        return (draft.bodies, draft.copy, simd_double4x4(SIMD4(linear.columns.0, 0), SIMD4(linear.columns.1, 0), SIMD4(linear.columns.2, 0), SIMD4(shift, 1)))
    }

    /// The draft it was built for, and the scaled workspace (nil when it does not build); on any thread.
    nonisolated private static func buildScalePreview(_ request: ScalePreviewRequest) -> (ScaleDraft, Workspace?) {
        let performance = Performance.begin("Scale preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        guard let result = Scaling.scale(request.base, bodies: draft.bodies, sketches: draft.sketches, about: draft.center, axes: draft.axes,
                                         factors: draft.factors, copy: draft.copy) else { return (draft, nil) }
        meshForDisplay(result.workspace.bodies.filter { result.bodies.contains($0.id) })
        return (draft, result.workspace)
    }

    /// A result for a draft since changed is left for the newer one.
    private func applyScalePreview(_ output: (ScaleDraft, Workspace?)) {
        guard scaleDraft == output.0 else { return }
        scalePreview = output.1
        scaleError = output.1 != nil ? nil : "That scale does not build: a cut, hole, or finish no longer fits. Try another percentage."
    }

    /// Waits for the background Scale preview (tests).
    func scalePreviewSettled() async { await scalePreviews.settled() }

    /// One undo step; the first scaled solid (or sketch) is selected.
    func confirmScale() {
        scalePreviews.settle { scaleDraft.map { ScalePreviewRequest(base: workspace, draft: $0) } }
        guard let draft = scaleDraft, scalePreview != nil, !isEditingBlocked,
              let result = Scaling.scale(workspace, bodies: draft.bodies, sketches: draft.sketches, about: draft.center, axes: draft.axes,
                                         factors: draft.factors, copy: draft.copy) else { return }
        clearScale()
        commit(result.workspace)
        let count = result.bodies.count + result.sketches.count
        status = count == 1 ? "Scaled" : "Scaled \(count) items"
        selection = result.bodies.first.map { .body($0) } ?? result.sketches.first.map { .sketch($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelScale() { clearScale(); dimensionEdit = nil }

    private func clearScale() {
        scalePreviews.drop()
        isDraggingScale = false
        if tool == .scale { tool = .select }
        if scaleDraft != nil { scaleDraft = nil }
        if scalePreview != nil { scalePreview = nil }
        scaleError = nil
    }

    // MARK: Project

    /// Project (sketch projections). Whatever is selected becomes the first item, and the surface is
    /// picked next. Inside a sketch, the projection goes into that sketch.
    func beginProjection() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        let picked = selection.flatMap(projectionItem(for:))
        let plane = selectedConstructionPlane
        cancelTransient()
        selection = nil
        tool = .project
        var draft = ProjectionDraft()
        if let sketchMode {
            draft.fixedTarget = true
            if let id = sketchMode.sketchID, let target = ProjectionTarget.sketch(id, in: workspace) {
                draft.target = target
            } else {
                draft.target = ProjectionTarget(source: .world(sketchMode.plane), plane: sketchMode.plane, outline: [])
            }
        } else if let plane {
            // A selected construction plane is the surface.
            draft.target = ProjectionTarget(source: .plane(plane.id), plane: plane.plane,
                                            outline: plane.outline.map { plane.plane.point($0) })
        }
        if let picked {
            draft.items = [picked]
            if !draft.fixedTarget && draft.target == nil { draft.step = .surface }
        }
        projectionDraft = draft
        updateProjectionPreview()
    }

    /// The item a selection stands for: a shape, region, sketch, edge, face, or solid.
    private func projectionItem(for selection: ModelSelection) -> ProjectionItem? {
        switch selection {
        case .shape(let id): return workspace.shapes.first { $0.id == id }.map { .shapes([$0], source: .shape(id)) }
        case .profile(let id):
            guard let profile = workspace.sketches.lazy.flatMap({ self.workspace.profiles(in: $0) }).first(where: { $0.id == id }) else { return nil }
            return .shapes(workspace.shapes.filter { profile.sourceIDs.contains($0.id) }, source: .profile(id))
        case .sketch(let id): return .shapes(workspace.shapes(in: id), source: .sketch(id))
        case .body(let id): return workspace.bodies.first { $0.id == id }.flatMap(ProjectionItem.body)
        case .face(let face): return workspace.bodies.first { $0.id == face.bodyID }.flatMap { .face(face.face, of: $0) }
        case .edge(let bodyID, let edge):
            guard let body = workspace.bodies.first(where: { $0.id == bodyID }) else { return nil }
            return .edge(edge.index, of: body)
        case .plane, .group, .chain: return nil
        }
    }

    /// Switches between picking items and picking the surface.
    func chooseProjectionStep(_ step: ProjectionDraft.Step) {
        guard var draft = projectionDraft, !draft.fixedTarget else { return }
        draft.step = step
        projectionDraft = draft
    }

    /// Adds an item, or removes it when it is already picked.
    func toggleProjectionItem(_ item: ProjectionItem) {
        guard var draft = projectionDraft, !isEditingBlocked else { return }
        if let index = draft.items.firstIndex(where: { $0.source == item.source }) { draft.items.remove(at: index) }
        else { draft.items.append(item) }
        projectionDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateProjectionPreview()
    }

    /// A double-tap: the whole sketch or solid instead of the shape, face, or edge just tapped.
    func pickWholeForProjection(_ item: ProjectionItem) {
        guard var draft = projectionDraft else { return }
        switch item.source {
        case .sketch(let id):
            let shapes = Set(workspace.shapes(in: id).map(\.id))
            draft.items.removeAll { if case .shape(let shape) = $0.source { shapes.contains(shape) } else { false } }
        case .body(let id):
            draft.items.removeAll {
                switch $0.source { case .face(let body, _), .edge(let body, _): body == id; default: false }
            }
        default: break
        }
        draft.items.removeAll { $0.source == item.source }
        draft.items.append(item)
        projectionDraft = draft
        updateProjectionPreview()
    }

    /// The surface; tapping the picked one again unpicks it.
    func setProjectionTarget(_ target: ProjectionTarget?) {
        guard var draft = projectionDraft, !draft.fixedTarget else { return }
        draft.target = target?.source == draft.target?.source ? nil : target
        projectionDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateProjectionPreview()
    }

    /// An Items row picked while projecting: an item, or (choosing the surface) a sketch or plane.
    private func pickProjectionRow(_ row: ModelSelection) {
        guard let draft = projectionDraft else { return }
        if draft.step == .surface && !draft.fixedTarget {
            switch row {
            case .sketch(let id): setProjectionTarget(.sketch(id, in: workspace))
            case .shape(let id): setProjectionTarget(workspace.shapes.first { $0.id == id }?.sketch.flatMap { .sketch($0, in: workspace) })
            case .plane(let id):
                guard let plane = workspace.constructionPlanes.first(where: { $0.id == id }) else { return }
                setProjectionTarget(ProjectionTarget(source: .plane(id), plane: plane.plane, outline: plane.outline.map { plane.plane.point($0) }))
            default: break
            }
            return
        }
        if let item = projectionItem(for: row) { toggleProjectionItem(item) }
    }

    private func updateProjectionPreview() {
        projectionError = nil
        guard let draft = projectionDraft, let target = draft.target, !draft.items.isEmpty else { projectionPreview = []; return }
        let existing = target.sketchID.map { workspace.shapes(in: $0) } ?? []
        if let shapes = Projection.shapes(projecting: draft.items, onto: target.plane, existing: existing) {
            projectionPreview = shapes
        } else {
            projectionPreview = []
            projectionError = "That would add more than \(Projection.maximumShapes) shapes. Pick fewer items."
        }
    }

    /// Adds the projected shapes as one undo step: to the target sketch, or as a new sketch.
    func confirmProjection() {
        guard let draft = projectionDraft, let target = draft.target, let first = projectionPreview.first, !isEditingBlocked else { return }
        var next = workspace
        let sketchID: UUID
        if let id = target.sketchID, next.sketch(id)?.plane == target.plane {
            sketchID = id
        } else {
            // Named by its first shape, like a sketch started by drawing.
            sketchID = first.id
            next.sketches.append(Sketch(id: sketchID, plane: target.plane))
        }
        next.shapes += projectionPreview.map { var shape = $0; shape.sketch = sketchID; return shape }
        let count = projectionPreview.count
        clearProjection()
        commit(next)
        status = "Projected \(count) \(count == 1 ? "shape" : "shapes")"
        if var mode = sketchMode, mode.plane == target.plane {
            // Inside a sketch: stay there, with the projection part of it.
            mode.sketchID = sketchID
            sketchMode = mode
            tool = .select
        } else {
            tool = .select
            selection = .sketch(sketchID)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelProjection() { clearProjection(); dimensionEdit = nil; tool = .select }

    private func clearProjection() {
        if tool == .project { tool = .select }
        if projectionDraft != nil { projectionDraft = nil }
        if !projectionPreview.isEmpty { projectionPreview = [] }
        projectionError = nil
    }

    /// Opens the sketch a shape belongs to, as tapping one of its lines does: the plane and grid move
    /// to the sketch, the camera stays where it is, and the shape is selected for editing.
    func enterSketch(of shapeID: UUID) {
        guard let shape = workspace.shapes.first(where: { $0.id == shapeID }), let sketch = workspace.sketch(shape.sketch),
              !workspace.isHidden(sketch) else { return }
        cancelTransient()
        if sketchMode?.sketchID != sketch.id {
            plane = sketch.plane
            sketchMode = SketchMode(plane: sketch.plane, face: sketchMode?.plane == sketch.plane ? sketchMode?.face : nil, sketchID: sketch.id)
        }
        if tool.shapeKind == nil && !tool.isFaceFeature { tool = .select }
        select(.shape(shapeID))
    }

    /// Selects a whole sketch, ending sketch mode (its Model Tree row, or Whole Sketch).
    func selectSketch(_ id: UUID) {
        guard let sketch = workspace.sketch(id), !workspace.isHidden(sketch) else { return }
        cancelTransient()
        endSketchMode()
        tool = .select
        select(.sketch(id))
    }

    /// Selects the shapes joined to `shapeID` end to end, ending sketch mode (double-tapping a
    /// sketch line, October 30, 2026). Shapes that only cross it, and the rest of
    /// the sketch, stay out; a chain that is all of its sketch selects the whole sketch.
    func selectChain(of shapeID: UUID) {
        guard let shape = workspace.shapes.first(where: { $0.id == shapeID }), let sketch = workspace.sketch(shape.sketch),
              !workspace.isHidden(sketch) else { return }
        let chain = SketchEditing.chain(from: shapeID, in: workspace)
        guard chain.count < workspace.shapes(in: sketch.id).count else { selectSketch(sketch.id); return }
        cancelTransient()
        endSketchMode()
        tool = .select
        select(.chain(chain))
    }

    /// "1 shape", "3 joined shapes": a chain, for the strip and hint.
    static func chainSummary(_ count: Int) -> String { count == 1 ? "1 shape" : "\(count) joined shapes" }

    /// From a chain to all of its sketch (the strip's Whole Sketch).
    func selectWholeSketch() {
        guard let chain = selection, let id = sketchID(of: chain) else { return }
        selectSketch(id)
    }

    /// Enters sketch mode on the selected flat face: the plane locks to the face, the camera
    /// looks straight at it, and its corners, edge midpoints, and center become guide points.
    func beginFaceSketch() {
        guard let face = selectedFace, let facePlane = face.plane, !isEditingBlocked else { return }
        cancelTransient()
        plane = facePlane
        sketchMode = SketchMode(plane: facePlane, face: face)
        selection = nil
        tool = .line
        requestCamera(.alignAt(facePlane, face.center))
    }

    /// Leaves sketch mode. A face plane only lasts while sketching on that face; afterwards the
    /// sketch plane (and with it the grid) returns to the world plane in use before.
    private func endSketchMode() {
        sketchMode = nil
        if !plane.isWorldPlane { plane = lastWorldPlane }
    }

    /// Leaves the sketch with the whole sketch selected, ready to move or rotate.
    func exitSketch() {
        let finished = sketchMode?.sketchID.flatMap { id in workspace.sketch(id) }
        cancelTransient()
        endSketchMode()
        selection = finished.map { .sketch($0.id) }
        tool = .select
    }

    func choosePlane(_ value: SketchPlane) {
        cancelTransient()
        plane = value
        if sketchMode != nil { sketchMode = SketchMode(plane: value) }
        selection = nil
        requestCamera(.align(value))
    }

    func chooseCubeFace(_ face: ViewCubeFace) {
        guard !viewCube.pencilActive else { return }
        dimensionEdit = nil
        if !isExtruding {
            plane = face.sketchPlane
            // While sketching, the cube moves the locked plane to Top, Front, or Right.
            if sketchMode != nil && sketchMode?.plane != face.sketchPlane { sketchMode = SketchMode(plane: face.sketchPlane) }
        }
        requestCamera(.face(face))
    }

    func requestCamera(_ action: CameraAction) {
        cameraAction = action
        cameraRequest += 1
    }

    func cancelTransient() {
        canFinishAuthorizedEdit = false
        isPickingPlane = false
        planeDraft = nil
        planePreview = nil
        clearProjection()
        clearSplit()
        clearMirror()
        clearPattern()
        clearScale()
        clearDeleteFace()
        clearOffset()
        clearSketchMirror()
        if lastPolygon != nil { lastPolygon = nil }
        finishTransform(cancelled: true)
        finishPivotDrag(cancelled: true)
        finishSketchDrag(cancelled: true)
        dimensionEdit = nil
        preview = nil
        isExtruding = false
        snapLabel = ""
        clearFinishDraft()
        clearCutPreview()
        clearShellDraft()
        clearHoleDraft()
        clearPrimitive()
        clearConstruction()
        clearShapeTool()
        clearPegDraft()
        clearThread()
        clearScrewLid()
        clearTextDraft()
        clearUnion()
        clearSubtract()
        clearAlign()
        clearRevolve()
        finishTrim(cancelled: true)
        if dimensionDraft != nil { dimensionDraft = nil }
        if !measureItems.isEmpty { measureItems = [] }
        if lastCorner != nil { lastCorner = nil }
    }

    /// Adds a drawn shape to the open sketch, starting a new sketch with the first shape. (Outside
    /// sketch mode, as in tests, it joins the last sketch on its plane.)
    func addShape(_ shape: SketchShape) {
        guard hasEditingAccess || canFinishAuthorizedEdit && isPencilDown else { showPurchaseOffer = true; return }
        preview = nil
        snapLabel = ""
        guard shape.isValid, let next = adding([shape]) else { return }
        commit(next)
        selection = .shape(next.shapes.last?.id ?? shape.id)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The workspace with drawn shapes added to the open sketch (starting it with the first).
    private func adding(_ shapes: [SketchShape]) -> Workspace? {
        guard !shapes.isEmpty, shapes.allSatisfy(\.isValid) else { return nil }
        var next = workspace
        for var shape in shapes {
            if var mode = sketchMode, mode.plane == shape.plane {
                if let id = mode.sketchID, let index = next.sketches.firstIndex(where: { $0.id == id && $0.plane == shape.plane }) {
                    shape.sketch = id
                    if next.sketches[index].faceEdges == nil { next.sketches[index].faceEdges = faceEdges(of: mode, in: next) }
                } else {
                    // Named by its first shape, so a lone sketch on a plane saves exactly as older files did.
                    var sketch = Sketch(id: shape.id, plane: shape.plane)
                    sketch.faceEdges = faceEdges(of: mode, in: next)
                    next.sketches.append(sketch)
                    shape.sketch = shape.id
                    mode.sketchID = shape.id
                    sketchMode = mode
                }
            }
            next.shapes.append(shape)
        }
        return next
    }

    /// The edges of the face being sketched on, in its plane's coordinates, so the face less what
    /// is drawn on it is a region of the sketch too. Found again by where it was tapped, since
    /// holes made while sketching renumber the solid's faces.
    private func faceEdges(of mode: SketchMode, in workspace: Workspace) -> [FaceEdge]? {
        guard let face = mode.face, let body = workspace.bodies.first(where: { $0.id == face.bodyID }),
              let solid = try? SolidKernel.solid(for: body) else { return nil }
        if let point = face.point, let index = solid.face(containing: point, normal: mode.plane.normalAxis),
           let edges = solid.faceEdges(index, on: mode.plane) { return edges }
        return solid.faceEdges(face.face, on: mode.plane)
    }

    // MARK: Polygon, Construction, Extend, Offset, and Mirror in a sketch

    /// Draws a regular polygon of `polygonSides` sides, centered on `center` with a corner at `vertex`,
    /// as joined lines (one undo step); its number of sides and radius can then be typed.
    func addPolygon(center: Point2, vertex: Point2) {
        guard hasEditingAccess || canFinishAuthorizedEdit && isPencilDown else { return }
        preview = nil
        snapLabel = ""
        let lines = SketchTools.polygon(center: center, vertex: vertex, sides: polygonSides, plane: plane)
        let base = workspace
        guard let next = adding(lines) else { return }
        commit(next)
        lastPolygon = PolygonRecord(base: base, center: center, vertex: vertex, plane: plane, sides: polygonSides, result: workspace)
        selection = nil
        status = "\(polygonSides)-sided polygon"
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The polygon just drawn, while its sides and radius can still be changed (nothing else happened since).
    var editablePolygon: PolygonRecord? {
        guard let record = lastPolygon, record.result == workspace, tool == .polygon else { return nil }
        return record
    }

    /// Redraws the last polygon with another number of sides or radius (center to a corner, its
    /// first corner staying in the same direction), as the same undo step.
    private func amendPolygon(sides: Int? = nil, radius: Double? = nil) -> Bool {
        guard var record = editablePolygon else { return false }
        let sides = sides ?? record.sides
        var vertex = record.vertex
        if let radius {
            let d = record.vertex - record.center, length = d.length
            guard length > 1e-9 else { return false }
            vertex = (record.center + d * (radius / length)).roundedOff()
        }
        let lines = SketchTools.polygon(center: record.center, vertex: vertex, sides: sides, plane: record.plane)
        // The new lines join the sketch the old ones were in.
        let sketch = record.result.shapes.first { !record.base.shapes.map(\.id).contains($0.id) }?.sketch
        guard let sketch, !lines.isEmpty else { return false }
        var updated = record.base
        if updated.sketch(sketch) == nil { updated.sketches.append(Sketch(id: sketch, plane: record.plane)) }
        updated.shapes += lines.map { var line = $0; line.sketch = sketch; return line }
        updated.normalizeSketches()
        guard updated.isValid else { return false }
        history.amend(updated)
        save()
        record.sides = sides
        record.vertex = vertex
        record.result = workspace
        lastPolygon = record
        polygonSides = sides
        return true
    }

    /// Makes the selected shape construction geometry (a dashed reference that bounds no region),
    /// or ordinary again. One undo step.
    func toggleConstruction() {
        guard requireNewEditingAccess() else { return }
        guard let shape = selectedShape, shape.kind != .point, !isEditingBlocked,
              let index = workspace.shapes.firstIndex(where: { $0.id == shape.id }) else { return }
        var next = workspace
        next.shapes[index].construction = shape.isConstruction ? nil : true
        commit(next)
        status = next.shapes[index].isConstruction ? "Construction" : "Not construction"
    }

    /// Extend: carries the line's nearer end on to the next shape it meets.
    func extend(_ shapeID: UUID, near point: Point2) {
        guard requireNewEditingAccess() else { return }
        guard tool == .extend, !isEditingBlocked else { return }
        // A face's edges count while sketching on its plane.
        let edges = workspace.shapes.first { $0.id == shapeID }?.plane == sketchMode?.plane ? sketchGuideLines : []
        guard let next = SketchTools.extend(shapeID, near: point, in: workspace, edges: edges) else {
            status = "Nothing ahead to extend to"
            return
        }
        commit(next)
        status = "Extended"
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// What Offset starts from when it is chosen: a selected shape, a selected chain, or a selected
    /// region whose whole outline is one chain (a region cut out by crossing shapes is not).
    private func offsetStartShape() -> UUID? {
        if let shape = selectedShape { return shape.kind == .point ? nil : shape.id }
        if let chain = selectedChain { return chain.first { $0.kind != .point }?.id }
        guard let profile = selectedProfile else { return nil }
        let sources = Set(profile.sourceIDs)
        return profile.sourceIDs.first {
            Set(SketchTools.chain(from: $0, in: workspace).map(\.id)).isSubset(of: sources) &&
                SketchTools.chainWithCopies(from: $0, in: workspace).isSuperset(of: sources)
        }
    }

    /// Every shape the picked Offset follows (the tapped one and those joined to it), drawn picked.
    var offsetChainIDs: Set<UUID> {
        guard let draft = offsetDraft else { return [] }
        return SketchTools.chainWithCopies(from: draft.shapeID, in: workspace)
    }

    /// Offset: picks the shape (and the chain joined to it) to offset, at the last distance used.
    func pickOffsetShape(_ shapeID: UUID) {
        guard tool == .offset, !isEditingBlocked, workspace.shapes.contains(where: { $0.id == shapeID && $0.kind != .point }) else { return }
        dimensionEdit = nil
        var draft = offsetDraft ?? OffsetDraft(shapeID: shapeID, distance: lastOffsetDistance)
        draft.shapeID = shapeID
        offsetDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateOffsetPreview()
    }

    /// False (and nothing changes) when the outline cannot be offset that far.
    @discardableResult func setOffsetDistance(_ distance: Double) -> Bool {
        guard var draft = offsetDraft, distance.isFinite, abs(distance) >= 0.001 else { return false }
        let previous = draft
        draft.distance = distance
        offsetDraft = draft
        updateOffsetPreview()
        if offsetPreview.isEmpty { offsetDraft = previous; updateOffsetPreview(); return false }
        return true
    }

    func flipOffset() { if let draft = offsetDraft { setOffsetDistance(-draft.distance) } }
    func setOffsetBothSides(_ both: Bool) { offsetDraft?.bothSides = both; updateOffsetPreview() }
    func setOffsetRounded(_ rounded: Bool) { offsetDraft?.rounded = rounded; updateOffsetPreview() }

    private func updateOffsetPreview() {
        guard let draft = offsetDraft else { offsetPreview = []; return }
        offsetPreview = SketchTools.offset(draft.shapeID, by: draft.distance, bothSides: draft.bothSides, rounded: draft.rounded, in: workspace) ?? []
    }

    /// Adds the offset outline to the picked shape's sketch (one undo step); the tool stays ready.
    func confirmOffset() {
        guard let draft = offsetDraft, !offsetPreview.isEmpty, !isEditingBlocked,
              let sketch = workspace.shapes.first(where: { $0.id == draft.shapeID })?.sketch else { return }
        var next = workspace
        next.shapes += offsetPreview.map { var shape = $0; shape.sketch = sketch; return shape }
        guard next.isValid else { return }
        lastOffsetDistance = abs(draft.distance)
        commit(next)
        offsetDraft = nil
        offsetPreview = []
        dimensionEdit = nil
        status = "Offset"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelOffset() { clearOffset(); dimensionEdit = nil }

    private func clearOffset() {
        if offsetDraft != nil { offsetDraft = nil }
        if !offsetPreview.isEmpty { offsetPreview = [] }
    }

    func chooseSketchMirrorStep(_ step: SketchMirrorDraft.Step) { sketchMirrorDraft?.step = step }

    /// A tapped shape: one to copy (tap again to leave it out), or the line to copy across.
    func pickSketchMirrorShape(_ shapeID: UUID) {
        guard var draft = sketchMirrorDraft, let shape = workspace.shapes.first(where: { $0.id == shapeID }) else { return }
        if draft.step == .line {
            guard shape.kind == .line else { status = "Tap a straight line to mirror across"; return }
            draft.line = draft.line == shapeID ? nil : shapeID
            draft.shapes.removeAll { $0 == shapeID }
        } else if let index = draft.shapes.firstIndex(of: shapeID) {
            draft.shapes.remove(at: index)
        } else {
            draft.shapes.append(shapeID)
            if draft.line == shapeID { draft.line = nil }
        }
        sketchMirrorDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateSketchMirrorPreview()
    }

    private func updateSketchMirrorPreview() {
        guard let draft = sketchMirrorDraft, let line = draft.line, !draft.shapes.isEmpty else { sketchMirrorPreview = nil; return }
        sketchMirrorPreview = SketchTools.mirror(draft.shapes, across: line, in: workspace)?.workspace
    }

    /// One undo step; the tool stays ready for more.
    func confirmSketchMirror() {
        guard let preview = sketchMirrorPreview, !isEditingBlocked else { return }
        commit(preview)
        sketchMirrorDraft = SketchMirrorDraft()
        sketchMirrorPreview = nil
        status = "Mirrored"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelSketchMirror() { clearSketchMirror(); tool = .select }

    private func clearSketchMirror() {
        if sketchMirrorDraft != nil { sketchMirrorDraft = nil }
        if sketchMirrorPreview != nil { sketchMirrorPreview = nil }
    }

    func select(_ value: ModelSelection?) {
        dimensionEdit = nil
        if isExtruding { isExtruding = false }
        selection = value
        if !extraSelection.isEmpty { extraSelection = [] }
        if tool == .extrude {
            if canExtrude { beginExtrusion() } else if canExtrudeSelectedFace { beginFaceExtrusion() }
        }
        if tool == .revolve, revolveDraft == nil, canExtrude || canExtrudeSelectedFace { beginRevolve() }
    }

    /// Starts extruding the selected region. The camera stays put; the arrow
    /// turns upright when the view looks straight along the extrusion.
    func beginExtrusion() {
        guard requireNewEditingAccess() else { return }
        guard canExtrude else { return }
        faceExtrusion = nil
        endSketchMode()
        preview = nil
        dimensionEdit = nil
        tool = .extrude
        extrusionModeIsAutomatic = true
        extrusionMode = .newBody
        cutThroughAll = false
        extrusionSymmetric = false
        extrusionTaper = 0
        isPickingExtrusionTarget = false
        extraExtrusionProfiles = []
        extrusionTool = nil
        // Start on the sketch plane, like a face extrusion; the drag or keypad sets the depth.
        extrusionDepth = 0
        isExtruding = true
    }

    /// Extrudes the selected flat face from where it is: starting at 0 mm, pulling out joins the
    /// solid and pushing in cuts it. The camera stays put, since the face was just tapped in view.
    func beginFaceExtrusion() {
        guard requireNewEditingAccess() else { return }
        guard canExtrudeSelectedFace, let face = selectedFace,
              let body = workspace.bodies.first(where: { $0.id == face.bodyID }) else { return }
        guard let source = FaceExtrusionSource(body: body, face: face.face, tapped: face.point ?? face.center) else {
            status = "This face cannot be extruded"
            return
        }
        cancelTransient()
        endSketchMode()
        tool = .extrude
        extrusionModeIsAutomatic = true
        cutThroughAll = false
        faceExtrusion = source
        extrusionDepth = 0
        isExtruding = true
        updateCutPreview()
    }

    func confirmExtrusion() {
        // Done waits while the file is busy or locked; the preview stays for later.
        guard !isEditingBlocked else { return }
        settleCutPreview()
        if isCutting || isJoining { confirmOperation(); return }
        guard isExtruding, !extrusionProfiles.isEmpty else { return }
        let bodies = newExtrusionBodies()
        guard let body = bodies.first, bodies.allSatisfy(\.isValid) else { return }
        var next = workspace
        next.bodies += bodies
        commit(next)
        isExtruding = false
        dimensionEdit = nil
        selection = .body(body.id)
        tool = .select
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Writes every visible solid to a print-ready file in a temporary folder and offers it for
    /// sharing (AirDrop, Files, slicer apps). Export files are copies; the project stays the original.
    /// Meshing runs off the main thread, since detailed solids take a while.
    func export(_ format: ModelExport.Format) {
        guard canExport else { return }
        cancelTransient()
        isProjectBusy = true
        status = "Exporting \(format.title)…"
        let bodies = workspace.bodies.filter { !workspace.isHidden($0) }, name = projectName
        // The last export's file has been shared (or dismissed) by now.
        if let previous = exportItem?.url.deletingLastPathComponent() { try? FileManager.default.removeItem(at: previous) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { () throws -> URL in
                let data = try ModelExport.data(format, bodies: bodies, title: name)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let url = folder.appendingPathComponent(safeName).appendingPathExtension(format.rawValue)
                try data.write(to: url, options: .atomic)
                return url
            }
            await self?.finishExport(result, format: format)
        }
    }

    private func finishExport(_ result: Result<URL, any Error>, format: ModelExport.Format) {
        isProjectBusy = false
        switch result {
        case .success(let url):
            exportItem = ExportItem(url: url)
            status = "Exported \(format.title)"
        case .failure(let error):
            status = "Not exported"
            saveError = "Export failed. \(error.localizedDescription)"
        }
    }

    func cancelExtrusion() { isExtruding = false; clearCutPreview(); dimensionEdit = nil; tool = .select }

    // MARK: Import

    /// Imports a STEP file (read off the main thread): each closed solid in it becomes a solid,
    /// where the file put it, in millimeters, as one undo step. A single solid is selected.
    func importSTEP(from url: URL) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        cancelTransient()
        endSketchMode()
        selection = nil
        isProjectBusy = true
        isImportingGeometry = true
        status = "Importing \(url.lastPathComponent)…"
        let name = url.deletingPathExtension().lastPathComponent
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try STEPImport.read(url, name: name) }
            await self?.finishImport(result)
        }
    }

    /// Imports an STL or 3MF file (read off the main thread): each closed mesh becomes a solid of
    /// its own, its flat areas single faces, as one undo step, like a STEP import.
    func importMesh(from url: URL) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        cancelTransient()
        endSketchMode()
        selection = nil
        isProjectBusy = true
        isImportingGeometry = true
        status = "Importing \(url.lastPathComponent)…"
        let name = url.deletingPathExtension().lastPathComponent
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try MeshImport.read(url, name: name) }
            await self?.finishImport(result, meshes: true)
        }
    }

    /// Imports another project (read off the main thread): everything in it, in a new group named
    /// after the file, where the file had it, as one undo step, with the group selected.
    func importProject(from url: URL) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        cancelTransient()
        endSketchMode()
        selection = nil
        isProjectBusy = true
        isImportingGeometry = true
        status = "Importing \(url.lastPathComponent)…"
        let name = url.deletingPathExtension().lastPathComponent
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try ProjectImport.read(url, name: name) }
            await self?.finishProjectImport(result)
        }
    }

    private func finishProjectImport(_ result: Result<ProjectImport.Result, any Error>) {
        defer { isImportingGeometry = false }
        isProjectBusy = false
        switch result {
        case .failure(let error):
            status = "Not imported"
            saveError = "Import failed. \(error.localizedDescription)"
        case .success(let imported):
            guard !imported.isEmpty else {
                status = "Not imported"
                saveError = "Import failed. That project has nothing in it."
                return
            }
            guard let next = ProjectImport.adding(imported, to: workspace) else {
                status = "Not imported"
                saveError = "Import failed. The project cannot hold everything in that one: there is too much, or it is too large for a project file."
                return
            }
            tool = .select
            commit(next.workspace)
            selection = .group(next.group)
            status = "Imported \(imported.name)" + (workspace.groupNames[next.group].map { " into the group \($0)" } ?? "")
            requestCamera(.reset)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func finishImport(_ result: Result<STEPImport.Result, any Error>, meshes: Bool = false) {
        defer { isImportingGeometry = false }
        isProjectBusy = false
        switch result {
        case .failure(let error):
            status = "Not imported"
            saveError = "Import failed. \(error.localizedDescription)"
        case .success(let imported):
            guard let next = STEPImport.adding(imported, to: workspace) else {
                status = "Not imported"
                saveError = "Import failed. The project cannot hold these solids: there are too many, or they are too large for a project file."
                return
            }
            commit(next)
            let count = imported.bodies.count
            selection = count == 1 ? .body(imported.bodies[0].id) : nil
            // The solids sit together in a group named after the file.
            let group = workspace.bodies.first { $0.id == imported.bodies.first?.id }?.group
            status = (count == 1 ? "Imported 1 solid" : "Imported \(count) solids") +
                (group.flatMap { workspace.groupNames[$0] }.map { " into the group \($0)" } ?? "") +
                (imported.skipped > 0 ? "; \(imported.skipped) \(meshes ? "open mesh" : "open surface")\(imported.skipped == 1 ? "" : "s") left out" : "")
            requestCamera(.reset)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: Cuts

    private func confirmOperation() {
        guard let preview = operationPreview, let first = isJoining ? joinTarget : cutTargets.first else { return }
        commit(preview)
        clearCutPreview()
        isExtruding = false
        dimensionEdit = nil
        selection = .body(first)
        tool = .select
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Revolve

    /// Starts revolving the selected sketch region or flat face. The axis is
    /// picked next, then the angle is dragged or typed.
    func beginRevolve() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        var face: FaceExtrusionSource?
        let profile: SketchProfile
        let picked = selectedProfiles
        if let selected = picked.first {
            profile = selected
        } else if canExtrudeSelectedFace, let picked = selectedFace, let body = workspace.bodies.first(where: { $0.id == picked.bodyID }) {
            guard let source = FaceExtrusionSource(body: body, face: picked.face) else { status = "This face cannot be revolved"; return }
            face = source
            profile = source.profile
        } else { return }
        let keep = selectedItems
        cancelTransient()
        endSketchMode()
        preview = nil
        tool = .revolve
        // The regions stay selected (amber while revolving), as for an extrusion.
        selection = keep.first
        extraSelection = Array(keep.dropFirst())
        revolveDraft = RevolveDraft(profile: profile, more: face == nil ? Array(picked.dropFirst()) : [], face: face)
    }

    /// Picks the axis: two world points on a sketch line, straight solid edge, or world axis. It must
    /// lie in the region's plane and not cross the region. Nil reports a tap on something that is
    /// not straight.
    func pickRevolveAxis(_ points: (SIMD3<Double>, SIMD3<Double>)?) {
        guard var draft = revolveDraft, !isEditingBlocked else { return }
        dimensionEdit = nil
        guard let (a, b) = points else {
            revolveError = "That is not straight. Tap a sketch line, a straight edge of a solid, or the X, Y, or Z axis."
            return
        }
        let plane = draft.profile.plane
        guard abs(plane.height(of: a)) < 1e-4, abs(plane.height(of: b)) < 1e-4 else {
            revolveError = "The axis must lie in the region's plane. Tap a line, edge, or axis on it."
            return
        }
        let from = plane.coordinates(of: a), to = plane.coordinates(of: b)
        guard from.distance(to: to) >= 0.01, draft.profiles.allSatisfy(RevolveSpec(from: from, to: to, angle: 360).allows) else {
            revolveError = draft.more.isEmpty ? "That axis crosses the region. Pick one along its edge or beside it." :
                "That axis crosses one of the regions. Pick one beside all of them."
            return
        }
        let first = draft.axis == nil
        draft.axis = RevolveAxis(from: from, to: to, start: a, end: b)
        revolveError = nil
        revolveDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        // Looking straight at the region, the sweep would come straight at the viewer.
        if first && viewCube.orientation.face != nil { requestCamera(.home) }
        updateRevolvePreview()
    }

    /// Signed degrees, up to a full turn either way.
    func setRevolveAngle(_ value: Double) {
        guard var draft = revolveDraft, draft.axis != nil, value.isFinite else { return }
        let angle = max(-360, min(360, value))
        // A snapped drag repeats the same angle on many moves; the preview already shows it.
        guard angle != draft.angle else { return }
        draft.angle = angle
        revolveDraft = draft
        updateRevolvePreview()
    }

    /// The user's explicit New Body / Join / Cut choice, which stops automatic switching.
    func chooseRevolveMode(_ mode: ExtrusionMode) {
        guard var draft = revolveDraft, draft.face == nil else { return }
        draft.modeIsAutomatic = false
        draft.mode = mode
        revolveDraft = draft
        updateRevolvePreview()
    }

    func confirmRevolve() {
        revolvePreviews.settle { revolveDraft.map { RevolvePreviewRequest(base: workspace, draft: $0) } }
        guard canConfirmRevolve, let draft = revolveDraft, let spec = draft.spec, !isEditingBlocked else { return }
        let picked: UUID
        switch draft.mode {
        case .newBody:
            let bodies = Self.unitedTouching(draft.profiles.map { SolidBody(profile: $0, revolve: spec) })
            guard let body = bodies.first, bodies.allSatisfy(\.isValid) else { return }
            var next = workspace
            next.bodies += bodies
            commit(next)
            picked = body.id
        case .cut, .join:
            guard let preview = revolvePreview, let first = draft.mode == .join ? revolveJoinTarget : revolveCutTargets.first else { return }
            commit(preview)
            picked = first
        }
        clearRevolve()
        dimensionEdit = nil
        selection = .body(picked)
        tool = .select
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelRevolve() { clearRevolve(); dimensionEdit = nil; tool = .select }

    private func clearRevolve() {
        revolvePreviews.drop()
        if revolveDraft != nil { revolveDraft = nil }
        if revolvePreview != nil { revolvePreview = nil }
        if revolveTool != nil { revolveTool = nil }
        if !revolveCutTargets.isEmpty { revolveCutTargets = [] }
        if revolveJoinTarget != nil { revolveJoinTarget = nil }
        if revolveError != nil { revolveError = nil }
    }

    /// Builds the swept tool, then previews where it goes. A sketch revolve cuts, joins, or makes a
    /// new solid like an extrusion; a face revolve cuts its own solid where it sweeps into it and
    /// joins it otherwise.
    private func updateRevolvePreview() {
        guard let draft = revolveDraft else { revolvePreviews.drop(); return }
        revolvePreviews.submit(RevolvePreviewRequest(base: workspace, draft: draft), inBackground: buildsPreviewsInBackground)
    }

    /// The swept tool and where it goes, on any thread (see `updateRevolvePreview`).
    nonisolated private static func buildRevolvePreview(_ request: RevolvePreviewRequest) -> RevolvePreviewOutput {
        let performance = Performance.begin("Revolve preview")
        defer { Performance.end(performance) }
        var draft = request.draft
        let workspace = request.base
        var output = RevolvePreviewOutput(draft: draft)
        guard let spec = draft.spec, spec.isValid else { return output }
        var cut = ExtrusionCut(profile: draft.profile, depth: 0, operation: .cut)
        cut.revolve = spec
        if let source = draft.face {
            cut.facePoint = source.point
            guard let index = workspace.bodies.firstIndex(where: { $0.id == source.bodyID }),
                  let solid = try? SolidKernel.solid(for: workspace.bodies[index]) else { return output }
            do { output.tool = try SolidKernel.revolveTool(for: cut, spec, on: solid) } catch {
                output.error = .some((error as? SolidKernel.Failure)?.message.capitalizedFirst ?? "This face cannot be revolved that way.")
                return output
            }
            output.error = .some(nil)
            var next = workspace
            next.bodies[index].cuts.append(cut)
            if workspace.bodies[index].isValid(appending: [cut]), let after = try? SolidKernel.solid(for: next.bodies[index]),
               after.volume < solid.volume - 1e-6 {
                draft.mode = .cut
                output.preview = next; output.cutTargets = [source.bodyID]
            } else {
                cut.join = true
                next = workspace
                next.bodies[index].cuts.append(cut)
                draft.mode = .join
                if workspace.bodies[index].isValid(appending: [cut]), (try? SolidKernel.solid(for: next.bodies[index])) != nil {
                    output.preview = next; output.joinTarget = source.bodyID
                }
            }
        } else {
            do {
                let tools = try draft.profiles.map { try SolidKernel.revolve($0, spec) }
                output.tool = try tools.dropFirst().reduce(tools[0]) { try SolidKernel.boolean($0, $1, .union) }
            } catch {
                output.error = .some((error as? SolidKernel.Failure)?.message.capitalizedFirst ?? "This region cannot be revolved that way.")
                return output
            }
            output.error = .some(nil)
            let cuts = draft.profiles.map { profile -> ExtrusionCut in
                var cut = ExtrusionCut(profile: profile, depth: 0, operation: .cut)
                cut.revolve = spec
                return cut
            }
            let joins = cuts.map { cut -> ExtrusionCut in var join = cut; join.join = true; return join }
            let result = cutOrJoin(in: workspace, cuts: cuts, joins: joins, automatic: draft.modeIsAutomatic, mode: draft.mode,
                                   toolBounds: output.tool?.bounds)
            draft.mode = result.mode
            output.preview = result.preview
            output.cutTargets = result.cutTargets
            output.joinTarget = result.joinTarget
        }
        output.draft = draft
        output.decidedMode = true
        let changed = Set(output.cutTargets + [output.joinTarget].compactMap { $0 })
        meshForDisplay(output.preview?.bodies.filter { changed.contains($0.id) } ?? [])
        _ = try? output.tool?.tessellateForDisplay()
        return output
    }

    /// Shows a revolve preview. It may be for an earlier angle than the draft now has: only the mode
    /// it decided is taken back, and only while the mode is still automatic (a face revolve's always is).
    private func applyRevolvePreview(_ output: RevolvePreviewOutput) {
        guard var draft = revolveDraft else { return }
        if revolvePreview != output.preview { revolvePreview = output.preview }
        if revolveCutTargets != output.cutTargets { revolveCutTargets = output.cutTargets }
        if revolveJoinTarget != output.joinTarget { revolveJoinTarget = output.joinTarget }
        if revolveTool !== output.tool { revolveTool = output.tool }
        if let error = output.error, revolveError != error { revolveError = error }
        if (draft.modeIsAutomatic || draft.face != nil) && output.decidedMode && draft.mode != output.draft.mode {
            draft.mode = output.draft.mode
            revolveDraft = draft
        }
    }

    /// Waits for the background Revolve preview (tests).
    func revolvePreviewSettled() async { await revolvePreviews.settled() }

    // MARK: Move and rotate sketches and solids

    /// Where the Move/Rotate widget sits (a sketch's extent or a solid's bounding box center) and
    /// the axes it uses: the sketch's own, or those of the plane the solid was extruded from.
    func transformFrame(of target: TransformTarget) -> (center: SIMD3<Double>, axes: [SIMD3<Double>])? {
        let plane: SketchPlane, center: SIMD3<Double>?
        switch target {
        case .sketch(let id):
            guard let sketch = workspace.sketch(id) else { return nil }
            plane = sketch.plane; center = workspace.center(of: sketch)
        case .body(let id):
            guard let body = workspace.bodies.first(where: { $0.id == id }) else { return nil }
            if let pivot = pivot(for: body) { return (pivot.center, pivot.axes) }
            plane = body.profile.plane; center = workspace.center(of: body)
        case .shape(let id):
            guard let shape = workspace.shapes.first(where: { $0.id == id }) else { return nil }
            plane = shape.plane; center = workspace.center(of: shape)
        case .shapes(let ids):
            guard let shape = workspace.shapes.first(where: { ids.contains($0.id) }) else { return nil }
            plane = shape.plane; center = workspace.center(ofShapes: ids)
        case .group(let id):
            // Everything in it, about its middle, along the world axes.
            plane = .top; center = workspace.center(ofGroup: id)
        case .items(let bodies, let sketches):
            plane = .top; center = workspace.center(ofBodies: bodies, sketches: sketches)
        }
        return center.map { ($0, [plane.xAxis, plane.yAxis, plane.normalAxis]) }
    }

    /// The placed (or, mid-drag, previewed) widget center of a solid, while the solid is unchanged.
    private func pivot(for body: SolidBody) -> PlacedPivot? {
        if isDraggingPivot, let pivotDrag, pivotDrag.bodyID == body.id { return pivotDrag }
        guard let pivot = transformPivot, pivot.bodyID == body.id, pivot.body == body else { return nil }
        return pivot
    }

    /// Pencil down on a solid's widget center: drag it to a corner, an edge, or a center (of this
    /// solid or another), a sketch point, or the origin to move or turn about there. Sketches keep
    /// their widget at their middle.
    @discardableResult func beginPivotDrag() -> Bool {
        guard case .body(let id) = transformWidgetTarget, transformDrag == nil, !isEditingBlocked,
              let body = workspace.bodies.first(where: { $0.id == id }) else { return false }
        dimensionEdit = nil
        lastTransform = nil
        pivotDrag = pivot(for: body)
        isDraggingPivot = true
        return true
    }

    /// Where the dragged center would land (nil while it is over nothing it can snap to).
    func previewPivot(_ snap: TransformPivot?) {
        guard isDraggingPivot, case .body(let id) = transformWidgetTarget,
              let body = workspace.bodies.first(where: { $0.id == id }) else { return }
        let plane = body.profile.plane
        let placed = snap.map { snap in
            PlacedPivot(bodyID: id, body: body, kind: snap.kind, center: snap.point,
                        axes: snap.axes(from: [plane.xAxis, plane.yAxis, plane.normalAxis]))
        }
        if let placed { pivotDrag = placed }
        if snapLabel != (snap?.kind.title ?? "") { snapLabel = snap?.kind.title ?? "" }
    }

    /// Pencil lift: the widget stays where the center was last snapped. Nothing in the document
    /// changes, so this is not an undo step.
    func finishPivotDrag(cancelled: Bool) {
        guard isDraggingPivot else { return }
        isDraggingPivot = false
        snapLabel = ""
        defer { pivotDrag = nil }
        guard !cancelled, let pivotDrag else { return }
        transformPivot = pivotDrag.kind == .center ? nil : pivotDrag
        status = "Widget at \(pivotDrag.kind.title.lowercased())"
    }

    /// After a move or turn, a placed widget center stays on the same spot of the solid (or its copy).
    private func carryPivot(of record: TransformRecord, to target: TransformTarget) {
        guard let kind = record.pivot, case .body(let id) = target,
              let body = workspace.bodies.first(where: { $0.id == id }) else { return }
        let transform = record.transform
        transformPivot = PlacedPivot(bodyID: id, body: body, kind: kind, center: transform.apply(point: record.center),
                                     axes: record.axes.map { transform.apply(vector: $0) })
    }

    /// The widget shows on a selected sketch (outside sketch mode) or solid (no tool chosen), or follows
    /// a drag in progress.
    var transformWidgetTarget: TransformTarget? {
        if let transformDrag { return transformDrag.target }
        // Several solids picked on the canvas, or rows picked in the Model Tree's Select mode, move together.
        if !isExtruding, !isEditingBlocked, tool == .select, sketchMode == nil, let items = movableItems {
            return .items(bodies: items.bodies, sketches: items.sketches)
        }
        // Several picked sketch regions are for Extrude and Revolve.
        guard !isExtruding, !isEditingBlocked, extraSelection.isEmpty else { return nil }
        // Inside a sketch, a selected shape moves and turns within it.
        if sketchMode != nil {
            if tool == .select, let shape = selectedShape { return .shape(shape.id) }
            return nil
        }
        if let sketch = selectedSketch { return .sketch(sketch.id) }
        // A chain moves and turns within its sketch, like one shape.
        if let chain = selectedChain, tool == .select { return .shapes(chain.map(\.id)) }
        if let body = selectedBody, tool == .select { return .body(body.id) }
        if let group = selectedGroup, tool == .select, workspace.center(ofGroup: group) != nil { return .group(group) }
        return nil
    }

    /// What the widget moves when several things are picked (October 24, 2026): the solids picked
    /// together on the canvas, or the Model Tree rows picked in Select mode (with everything in a
    /// picked group). Nil otherwise.
    var movableItems: (bodies: [UUID], sketches: [UUID])? {
        if isSelectingRows {
            var bodies: [UUID] = [], sketches: [UUID] = []
            for member in workspace.outermost(pickedRows) {
                switch member {
                case .body(let id): bodies.append(id)
                case .sketch(let id): sketches.append(id)
                case .group(let id): bodies += workspace.contents(of: id).bodies; sketches += workspace.contents(of: id).sketches
                case .plane: break
                }
            }
            // In document order, so copies land where Duplicate would put them.
            bodies = workspace.bodies.map(\.id).filter(bodies.contains)
            sketches = workspace.sketches.map(\.id).filter(sketches.contains)
            return bodies.isEmpty && sketches.isEmpty ? nil : (bodies, sketches)
        }
        return pickedBodies.count > 1 ? (pickedBodies, []) : nil
    }

    /// After a move of several items: the same items (or their copies) picked again.
    private func pickAgain(_ target: TransformTarget) {
        guard case .items(let bodies, let sketches) = target else { selection = selection(for: target); return }
        if isSelectingRows {
            pickedRows = Set(bodies.map { GroupMember.body($0) } + sketches.map { GroupMember.sketch($0) })
        } else {
            selection = bodies.first.map { .body($0) }
            extraSelection = bodies.dropFirst().map { .body($0) }
        }
    }

    /// The Model Tree group selected (its row), which moves and transforms as a unit.
    var selectedGroup: UUID? {
        guard case .group(let id) = selection, workspace.group(id) != nil else { return nil }
        return id
    }
    /// The solids and sketches selected: one, or everything in a selected group (drawn as selected).
    var selectedMembers: (bodies: Set<UUID>, sketches: Set<UUID>) {
        if let group = selectedGroup {
            let contents = workspace.contents(of: group)
            return (Set(contents.bodies), Set(contents.sketches))
        }
        if let items = movableItems { return (Set(items.bodies), Set(items.sketches)) }
        return (Set(selectedBody.map { [$0.id] } ?? []), Set(selectedSketch.map { [$0.id] } ?? []))
    }

    private func selection(for target: TransformTarget) -> ModelSelection {
        switch target {
        case .sketch(let id): .sketch(id); case .body(let id): .body(id); case .shape(let id): .shape(id); case .group(let id): .group(id)
        case .shapes(let ids): .chain(ids)
        case .items(let bodies, let sketches): bodies.first.map { .body($0) } ?? sketches.first.map { .sketch($0) } ?? .body(UUID())
        }
    }

    @discardableResult func beginTransform(_ handle: TransformHandle) -> Bool {
        guard requireNewEditingAccess() else { return false }
        guard let target = transformWidgetTarget, transformDrag == nil, !isEditingBlocked,
              let frame = transformFrame(of: target) else { return false }
        dimensionEdit = nil
        lastTransform = nil
        var pivot: TransformPivot.Kind?
        if case .body(let id) = target, let body = workspace.bodies.first(where: { $0.id == id }) { pivot = self.pivot(for: body)?.kind }
        transformDrag = TransformRecord(base: workspace, target: target, handle: handle, amount: 0, copy: transformCopies,
                                        center: frame.center, axes: frame.axes, pivot: pivot)
        return true
    }

    /// Live preview of the drag: millimeters along, or degrees about, the handle's axis.
    func updateTransform(_ amount: Double) {
        guard var drag = transformDrag, amount.isFinite else { return }
        drag.amount = max(-10_000, min(10_000, amount))
        // An amount that cannot be reached keeps the last one that could, so the amount and result agree.
        guard let moved = drag.base.transforming(drag.target, by: drag.transform, copy: drag.copy) else { return }
        drag.result = moved.workspace
        drag.resultTarget = moved.target
        editPreview = abs(drag.amount) > 1e-9 ? moved.workspace : nil
        transformDrag = drag
    }

    /// One undo step at Pencil lift; a cancelled or zero drag changes nothing. With Copy on, the
    /// copy is selected so the next drag moves it, and the original stays where it was.
    func finishTransform(cancelled: Bool) {
        guard let drag = transformDrag else { return }
        transformDrag = nil
        editPreview = nil
        guard !cancelled, abs(drag.amount) > 1e-9, let result = drag.result, let moved = drag.resultTarget else { return }
        commit(result)
        pickAgain(moved)
        carryPivot(of: drag, to: moved)
        lastTransform = drag
        status = drag.copy ? "Copied" : drag.handle.isRotation ? "Rotated" : "Moved"
    }

    /// The keypad changes the last move or turn to an exact amount, still as one undo step.
    private func amendLastTransform(_ amount: Double) -> Bool {
        guard var record = lastTransform, record.result == workspace,
              let moved = record.base.transforming(record.target, by: {
                  var updated = record; updated.amount = amount; return updated.transform }(), copy: record.copy) else { return false }
        var updated = moved.workspace
        updated.normalizeSketches()
        guard history.amend(updated) else { return false }
        record.amount = amount
        record.result = workspace
        record.resultTarget = moved.target
        save()
        pickAgain(moved.target)
        carryPivot(of: record, to: moved.target)
        lastTransform = record
        return true
    }

    /// The last transform's amount while it can still be changed (nothing else has happened since).
    var editableTransform: TransformRecord? {
        guard let record = lastTransform, record.result == workspace, let moved = record.resultTarget else { return nil }
        if case .items = moved { return transformWidgetTarget == moved ? record : nil }
        guard selection == selection(for: moved) else { return nil }
        return record
    }

    /// The picked regions (and every region of a picked sketch), then any others tapped while extruding.
    var extrusionProfiles: [SketchProfile] {
        let picked = selectedProfiles
        return picked + extraExtrusionProfiles.filter { extra in !picked.contains { $0.id == extra.id } }
    }

    /// A region's cut or join with the current Extrude options.
    private func extrusionOperation(_ profile: SketchProfile, join: Bool) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: profile, depth: extrusionDepth, throughAll: !join && cutThroughAll, operation: join ? .join : .cut)
        if !operation.throughAll {
            if extrusionSymmetric { operation.symmetric = true }
            if extrusionTaper != 0 { operation.taper = extrusionTaper }
        }
        return operation
    }

    /// The new solids Done makes: one per region, with those that touch united into the first.
    private func newExtrusionBodies() -> [SolidBody] {
        Self.unitedTouching(extrusionProfiles.map { profile -> SolidBody in
            var body = SolidBody(profile: profile, depth: extrusionDepth)
            if extrusionSymmetric { body.symmetric = true }
            if extrusionTaper != 0 { body.taper = extrusionTaper }
            return body
        })
    }

    /// New solids from several regions: those that touch the first are united into it.
    private static func unitedTouching(_ bodies: [SolidBody]) -> [SolidBody] {
        guard bodies.count > 1 else { return bodies }
        let (united, untouched) = Unioning.union(bodies[0], with: Array(bodies.dropFirst()))
        return [united] + bodies.dropFirst().filter { untouched.contains($0.id) }
    }

    /// Adds a region to extrude with the picked ones, or takes it out again (not one picked beforehand).
    func toggleExtrusionProfile(_ profile: SketchProfile) {
        guard isExtruding, faceExtrusion == nil, !selectedProfiles.contains(where: { $0.id == profile.id }) else { return }
        if let index = extraExtrusionProfiles.firstIndex(where: { $0.id == profile.id }) { extraExtrusionProfiles.remove(at: index) }
        else { extraExtrusionProfiles.append(profile) }
        UISelectionFeedbackGenerator().selectionChanged()
        updateCutPreview()
    }

    /// The sides' taper in degrees (−89 to 89; positive narrows toward the far end). False when out of range.
    @discardableResult func setExtrusionTaper(_ degrees: Double) -> Bool {
        guard isExtruding, faceExtrusion == nil, degrees.isFinite, ExtrusionCut.taperRange.contains(degrees), abs(degrees) < 89 else { return false }
        extrusionTaper = degrees
        updateCutPreview()
        return true
    }

    /// Up To: the depth that reaches a plane (a flat face's or a construction plane's) parallel to
    /// the sketch. False when it is not parallel or lies on the sketch plane.
    @discardableResult func extrude(upTo point: SIMD3<Double>, normal: SIMD3<Double>) -> Bool {
        guard isExtruding, let profile = extrusionProfile, abs(abs(simd_dot(simd_normalize(normal), profile.plane.normalAxis)) - 1) < 1e-6 else {
            status = "Tap a face or plane parallel to the sketch"
            return false
        }
        let depth = simd_dot(point - profile.plane.origin, profile.plane.normalAxis)
        guard abs(depth) >= 0.01, abs(depth) <= 10_000 else { status = "That face is on the sketch plane"; return false }
        isPickingExtrusionTarget = false
        extrusionSymmetric = false
        extrusionDepth = depth
        return true
    }

    private func clearCutPreview() {
        if extrusionTool != nil { extrusionTool = nil }
        if operationPreview != nil { operationPreview = nil }
        if !cutTargets.isEmpty { cutTargets = [] }
        if joinTarget != nil { joinTarget = nil }
    }

    /// The user's explicit New Body / Cut choice, which stops automatic switching.
    func chooseExtrusionMode(_ mode: ExtrusionMode) {
        extrusionModeIsAutomatic = false
        extrusionMode = mode
    }

    /// Previews the pending cut (applied to every solid it removes material from) or join (merged
    /// into the first solid it touches) through the kernel. While the mode is automatic, the drag
    /// decides: into a solid cuts it, touching a solid from outside joins it, free space is a new body.
    /// On screen the kernel work runs off the main thread (`buildsPreviewsInBackground`): cutting a
    /// detailed solid on every Pencil sample hung an Extrude drag 18 times in 20 s on the iPad
    /// (November 9, 2026). Off screen (tests) it is built at once.
    private func updateCutPreview() {
        guard !updatingCutPreview else { return }
        guard let request = cutPreviewRequest() else {
            cutPreviews.drop()
            clearCutPreview()
            return
        }
        cutPreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    /// What the Extrude preview is built from, taken on the main thread; nil when nothing is extruded.
    private func cutPreviewRequest() -> CutPreviewRequest? {
        if isExtruding, let source = faceExtrusion {
            return CutPreviewRequest(base: workspace, face: source, depth: extrusionDepth)
        }
        let profiles = extrusionProfiles
        guard isExtruding, !profiles.isEmpty else { return nil }
        // A plain single region previews as before; options and several regions show the kernel's solid.
        let plain = profiles.count == 1 && !extrusionSymmetric && extrusionTaper == 0
        return CutPreviewRequest(base: workspace, cuts: profiles.map { extrusionOperation($0, join: false) },
                                 joins: profiles.map { extrusionOperation($0, join: true) }, automatic: extrusionModeIsAutomatic,
                                 mode: extrusionMode, cutThroughAll: cutThroughAll,
                                 toolBodies: !plain && abs(extrusionDepth) >= 0.01 ? newExtrusionBodies() : nil, depth: extrusionDepth)
    }

    /// Done keeps what the final depth makes: the preview for the current settings, built now when the
    /// background has not caught up (its builds are cached by then, so this is usually quick).
    private func settleCutPreview() { cutPreviews.settle { cutPreviewRequest() } }

    /// Waits for the background Extrude preview (tests).
    func cutPreviewSettled() async { await cutPreviews.settled() }

    private func applyCutPreview(_ result: CutPreviewResult) {
        // The extrusion ended while this was building.
        guard isExtruding else { return }
        updatingCutPreview = true
        defer { updatingCutPreview = false }
        guard let result = result.built else { clearCutPreview(); return }
        if extrusionModeIsAutomatic || faceExtrusion != nil {
            if extrusionMode != result.mode { extrusionMode = result.mode }
            if faceExtrusion == nil, result.mode != .cut && cutThroughAll { cutThroughAll = false }
        }
        operationPreview = result.preview
        cutTargets = result.cutTargets
        joinTarget = result.joinTarget
        if extrusionTool != nil || result.tool != nil { extrusionTool = result.tool }
    }

    /// The Extrude preview from a request, on any thread.
    nonisolated private static func buildCutPreview(_ request: CutPreviewRequest) -> CutPreviewResult {
        let performance = Performance.begin("Extrude preview")
        defer { Performance.end(performance) }
        if let source = request.face {
            // A face extrusion only ever changes its own solid: outward joins it, inward cuts it.
            let mode: ExtrusionMode = request.depth < 0 ? .cut : .join
            let operation = source.operation(depth: request.depth)
            var next = request.base
            guard operation.isValid, let index = next.bodies.firstIndex(where: { $0.id == source.bodyID }) else { return CutPreviewResult(built: nil) }
            next.bodies[index].cuts.append(operation)
            // The solid was valid and the step is checked above: checking the whole definition again on
            // every Pencil move took 0.9 s over one drag on an 88-step solid (November 8, 2026). Done
            // checks it in full when the step is kept (WorkspaceHistory.commit).
            guard next.bodies[index].cuts.count <= ExtrusionCut.maximumPerBody,
                  (try? SolidKernel.solid(for: next.bodies[index])) != nil else { return CutPreviewResult(built: nil) }
            meshForDisplay([next.bodies[index]])
            return CutPreviewResult(built: (mode, next, mode == .cut ? [source.bodyID] : [], mode == .join ? source.bodyID : nil, nil))
        }
        let result = cutOrJoin(in: request.base, cuts: request.cuts, joins: request.joins, automatic: request.automatic, mode: request.mode)
        let throughAll = request.cutThroughAll && (!request.automatic || result.mode == .cut)
        var tool: KernelSolid?
        if result.mode != .join && !(result.mode == .cut && throughAll), let bodies = request.toolBodies {
            let solids = bodies.compactMap { try? SolidKernel.solid(for: $0) }
            tool = solids.count == bodies.count ? solids.dropFirst().reduce(solids.first) { tool, next in tool.flatMap { try? SolidKernel.boolean($0, next, .union) } } : nil
        }
        let changed = Set(result.cutTargets + [result.joinTarget].compactMap { $0 })
        meshForDisplay(result.preview?.bodies.filter { changed.contains($0.id) } ?? [])
        _ = try? tool?.tessellateForDisplay()
        return CutPreviewResult(built: (result.mode, result.preview, result.cutTargets, result.joinTarget, tool))
    }

    /// Makes the display mesh of the solids a preview changed where the preview is built, so the
    /// canvas finds it ready: meshing each new preview on the main thread took about 12 ms on a
    /// detailed solid (November 9, 2026). The mesh is kept on the solid (`tessellateForDisplay`).
    nonisolated private static func meshForDisplay(_ bodies: [SolidBody]) {
        for body in bodies { _ = try? SolidKernel.solid(for: body).tessellateForDisplay() }
    }

    /// Where a pending extrusion or revolve goes. `cut` applies to every visible solid it removes
    /// material from; `join` merges into the first solid it makes one piece with. While `automatic`,
    /// a cut wins, then a join, else it is a new body; otherwise `mode` is kept as chosen.
    private func cutOrJoin(cut: ExtrusionCut, join: ExtrusionCut, automatic: Bool, mode: ExtrusionMode)
        -> (mode: ExtrusionMode, preview: Workspace?, cutTargets: [UUID], joinTarget: UUID?) {
        cutOrJoin(cuts: [cut], joins: [join], automatic: automatic, mode: mode)
    }

    /// As above for several regions: each body takes the cuts that reach it; the joins all go into
    /// the first solid they make one piece with.
    /// Solids the tool's box (`toolBounds`, else each cut's own reach) cannot touch are skipped
    /// without building, and each candidate checks only its new steps: the model was valid, and
    /// Done checks the kept model in full. Building and checking every shown solid in full on each
    /// Pencil move was most of the per-move cost on larger projects (November 8, 2026).
    private func cutOrJoin(cuts: [ExtrusionCut], joins: [ExtrusionCut], automatic: Bool, mode: ExtrusionMode,
                           toolBounds: (min: SIMD3<Double>, max: SIMD3<Double>)? = nil)
        -> (mode: ExtrusionMode, preview: Workspace?, cutTargets: [UUID], joinTarget: UUID?) {
        Self.cutOrJoin(in: workspace, cuts: cuts, joins: joins, automatic: automatic, mode: mode, toolBounds: toolBounds)
    }

    /// The same on any workspace, off the main thread too (the Extrude preview builds there).
    nonisolated private static func cutOrJoin(in workspace: Workspace, cuts: [ExtrusionCut], joins: [ExtrusionCut], automatic: Bool, mode: ExtrusionMode,
                                              toolBounds: (min: SIMD3<Double>, max: SIMD3<Double>)? = nil)
        -> (mode: ExtrusionMode, preview: Workspace?, cutTargets: [UUID], joinTarget: UUID?) {
        func reaches(_ cut: ExtrusionCut, _ solid: KernelSolid) -> Bool {
            if let toolBounds { return boxesMeet(toolBounds, solid.bounds) }
            return cut.mayReach(solid.bounds)
        }
        var cutWorkspace = workspace, targets: [UUID] = []
        if (automatic || mode == .cut) && !cuts.isEmpty && cuts.allSatisfy(\.isValid) {
            for index in cutWorkspace.bodies.indices where !cutWorkspace.isHidden(cutWorkspace.bodies[index]) {
                var body = cutWorkspace.bodies[index]
                guard var before = try? SolidKernel.solid(for: body) else { continue }
                var reached = false
                for cut in cuts where reaches(cut, before) {
                    guard body.isValid(appending: [cut]) else { continue }
                    var next = body
                    next.cuts.append(cut)
                    guard let after = try? SolidKernel.solid(for: next), after.volume < before.volume - 1e-6 else { continue }
                    body = next
                    before = after
                    reached = true
                }
                guard reached else { continue }
                cutWorkspace.bodies[index] = body
                targets.append(body.id)
            }
        }
        var joinWorkspace = workspace, joined: UUID?
        if ((automatic && targets.isEmpty) || mode == .join) && !joins.isEmpty && joins.allSatisfy(\.isValid) {
            for index in joinWorkspace.bodies.indices where !joinWorkspace.isHidden(joinWorkspace.bodies[index]) {
                var body = joinWorkspace.bodies[index]
                guard body.isValid(appending: joins), let solid = try? SolidKernel.solid(for: body),
                      joins.contains(where: { reaches($0, solid) }) else { continue }
                body.cuts += joins
                // Kernel apply only succeeds when the result is one connected solid.
                guard (try? SolidKernel.solid(for: body)) != nil else { continue }
                joinWorkspace.bodies[index] = body
                joined = body.id
                break
            }
        }
        let result = automatic ? (!targets.isEmpty ? .cut : joined != nil ? .join : .newBody) : mode
        switch result {
        case .cut: return (.cut, targets.isEmpty ? nil : cutWorkspace, targets, nil)
        case .join: return (.join, joined == nil ? nil : joinWorkspace, [], joined)
        case .newBody: return (.newBody, nil, [], nil)
        }
    }

    /// How far a through-all cut tool reaches on each side of `plane`, covering every shown solid
    /// (hidden ones are never cut, and building them all on each preview step was slow).
    func throughAllReach(from plane: SketchPlane) -> Double {
        let frame = plane.frame
        var reach = 20.0
        for body in workspace.bodies where !workspace.isHidden(body) {
            guard let bounds = try? SolidKernel.solid(for: body).bounds else { continue }
            for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                reach = max(reach, abs(simd_dot(SIMD3(x, y, z) - frame.origin, frame.normal)) + 1)
            } } }
        }
        return reach
    }

    // MARK: Align

    /// Align. A selected solid is the one to move; a selected flat face or straight or round edge
    /// is also what gets aligned, so the target comes next.
    func beginAlign() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        var draft = AlignDraft()
        switch selection {
        case .body(let id): draft.bodies = [id]; draft.step = .from
        case .face(let face):
            draft.bodies = [face.bodyID]; draft.step = .from
            if face.plane != nil, let body = workspace.bodies.first(where: { $0.id == face.bodyID }),
               let reference = PlaneReference.face(face.face, of: body) {
                draft.from = .plane(reference); draft.step = .to
            }
        case .edge(let bodyID, let edge):
            draft.bodies = [bodyID]; draft.step = .from
            if let body = workspace.bodies.first(where: { $0.id == bodyID }), let feature = AlignFeature.edge(edge.index, of: body) {
                draft.from = feature; draft.step = .to
            }
        default: break
        }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .align
        alignDraft = draft
        updateAlignPreview()
    }

    func chooseAlignStep(_ step: AlignDraft.Step) {
        guard var draft = alignDraft else { return }
        draft.step = step
        alignDraft = draft
    }

    func toggleAlignBody(_ id: UUID) {
        guard var draft = alignDraft, workspace.isShown(body: id) else { return }
        if let index = draft.bodies.firstIndex(of: id) {
            draft.bodies.remove(at: index)
            if case .face(id, _) = draft.from?.source { draft.from = nil }
            if case .edge(id, _) = draft.from?.source { draft.from = nil }
            if case .vertex(id, _) = draft.from?.source { draft.from = nil }
        } else { draft.bodies.append(id) }
        alignDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateAlignPreview()
    }

    /// What gets aligned: a face or edge of a moving solid. The target comes next.
    func setAlignFrom(_ feature: AlignFeature) {
        guard var draft = alignDraft else { return }
        draft.from = feature
        draft.step = .to
        alignDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateAlignPreview()
    }

    func setAlignTo(_ feature: AlignFeature) {
        guard var draft = alignDraft else { return }
        draft.to = feature
        alignDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateAlignPreview()
    }

    func setAlignFlip(_ flip: Bool) { adjustAlign { $0.flip = flip } }
    func setAlignOffset(_ offset: Double) { adjustAlign { $0.offset = max(-10_000, min(10_000, offset)) } }
    func setAlignAngle(_ angle: Double) { adjustAlign { $0.angle = max(-360, min(360, angle)) } }

    private func adjustAlign(_ change: (inout AlignDraft) -> Void) {
        guard var draft = alignDraft else { return }
        change(&draft)
        alignDraft = draft
        updateAlignPreview()
    }

    private func pickAlignRow(_ row: ModelSelection) {
        guard let draft = alignDraft else { return }
        switch (draft.step, row) {
        case (.bodies, .body(let id)): toggleAlignBody(id)
        case (.to, .plane(let id)):
            if let plane = workspace.constructionPlanes.first(where: { $0.id == id }) { setAlignTo(.plane(.construction(plane))) }
        case (.to, .shape(let id)):
            if let feature = workspace.shapes.first(where: { $0.id == id }).flatMap(AlignFeature.shape) { setAlignTo(feature) }
        default: break
        }
    }

    /// The motion Align would make now, if it can.
    var alignTransform: RigidTransform? {
        guard let draft = alignDraft, let from = draft.from, let to = draft.to else { return nil }
        return Aligning.transform(from: from, to: to, flip: draft.flip, offset: draft.offset, angle: draft.angle)
    }

    private func updateAlignPreview() {
        alignError = nil
        guard let draft = alignDraft, !draft.bodies.isEmpty, let from = draft.from, let to = draft.to else { alignPreview = nil; return }
        guard from.kind == to.kind, let transform = alignTransform else {
            alignPreview = nil
            alignError = "Those do not go together: align a flat face with a face or plane, a round edge with a circle, a straight edge with a line, or a corner with a point."
            return
        }
        alignPreview = Aligning.moving(draft.bodies, in: workspace, by: transform)
        if alignPreview == nil { alignError = "The solids cannot be moved there." }
    }

    /// One undo step; the first moved solid is selected.
    func confirmAlign() {
        guard let preview = alignPreview, let draft = alignDraft, !isEditingBlocked else { return }
        clearAlign()
        commit(preview)
        status = "Aligned"
        selection = draft.bodies.first.map { .body($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelAlign() { clearAlign(); dimensionEdit = nil }

    private func clearAlign() {
        if tool == .align { tool = .select }
        if alignDraft != nil { alignDraft = nil }
        if alignPreview != nil { alignPreview = nil }
        alignError = nil
    }

    // MARK: Subtract

    /// Subtract. A selected solid (or its face or edge) is the first target; the tools come next.
    func beginSubtract() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        let picked = pickedBodies
        let bodyID: UUID?
        switch selection {
        case .body(let id), .edge(let id, _): bodyID = id
        case .face(let face): bodyID = face.bodyID
        default: bodyID = nil
        }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .subtract
        var draft = SubtractDraft()
        if let bodyID { draft.targets = [bodyID]; draft.step = .tools }
        // Several solids picked: the first is cut by the rest.
        if picked.count > 1 { draft.tools = Array(picked.dropFirst()) }
        subtractDraft = draft
        updateSubtractPreview()
    }

    func chooseSubtractStep(_ step: SubtractDraft.Step) {
        guard var draft = subtractDraft else { return }
        draft.step = step
        subtractDraft = draft
    }

    /// Picks a solid as a target or a tool (by step), or unpicks it. A solid is one or the other.
    func toggleSubtractBody(_ id: UUID) {
        guard var draft = subtractDraft, workspace.isShown(body: id) else { return }
        if draft.step == .targets {
            if let index = draft.targets.firstIndex(of: id) { draft.targets.remove(at: index) } else { draft.targets.append(id); draft.tools.removeAll { $0 == id } }
        } else {
            if let index = draft.tools.firstIndex(of: id) { draft.tools.remove(at: index) } else { draft.tools.append(id); draft.targets.removeAll { $0 == id } }
        }
        subtractDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateSubtractPreview()
    }

    /// The gap left around the tools (nil for an exact subtract).
    func setSubtractClearance(_ clearance: Double?) {
        guard var draft = subtractDraft, clearance.map(Fit.clearanceRange.contains) ?? true else { return }
        draft.clearance = clearance
        subtractDraft = draft
        updateSubtractPreview()
    }

    func setSubtractKeep(_ keep: SubtractDraft.Keep) {
        guard var draft = subtractDraft else { return }
        draft.keep = keep
        subtractDraft = draft
        updateSubtractPreview()
    }

    /// Each target with the tools that overlap it removed: in its place, or (keeping targets) as a
    /// new solid after it. Tools go away unless kept.
    /// Built off the main thread on screen.
    private func updateSubtractPreview() {
        guard let request = subtractPreviewRequest() else {
            subtractPreviews.drop(); subtractPreview = nil; subtractError = nil; return
        }
        subtractPreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    private func subtractPreviewRequest() -> SubtractPreviewRequest? {
        guard let draft = subtractDraft, !draft.targets.isEmpty, !draft.tools.isEmpty else { return nil }
        return SubtractPreviewRequest(base: workspace, draft: draft)
    }

    /// On any thread.
    nonisolated private static func buildSubtractPreview(_ request: SubtractPreviewRequest) -> CombinePreviewOutput {
        let performance = Performance.begin("Subtract preview")
        defer { Performance.end(performance) }
        let draft = request.draft, base = request.base
        let names = base.bodyNames
        func name(_ id: UUID) -> String { names[id] ?? "A solid" }
        let tools = draft.tools.compactMap { id in base.bodies.first { $0.id == id } }
        var next = base, used = Set<UUID>(), made: [SolidBody] = []
        for id in draft.targets {
            guard let index = next.bodies.firstIndex(where: { $0.id == id }) else { continue }
            var (result, cutters) = Subtracting.subtract(tools, from: next.bodies[index], clearance: draft.clearance)
            guard !cutters.isEmpty else {
                return CombinePreviewOutput(error: draft.clearance == nil ?
                    "\(name(id)) is not overlapped by any tool, or would be removed entirely. Tap it to leave it out." :
                    "\(name(id)) is not overlapped by any tool, would be removed entirely, or a tool cannot be grown by that clearance.")
            }
            used.formUnion(cutters)
            if draft.keep.keepsTargets {
                result.id = UUID()
                result.hidden = nil
                next.bodies.insert(result, at: index + 1)
            } else {
                next.bodies[index] = result
            }
            made.append(result)
        }
        if let unused = draft.tools.first(where: { !used.contains($0) }) {
            return CombinePreviewOutput(error: "\(name(unused)) does not overlap a target. Tap it to leave it out.")
        }
        if !draft.keep.keepsTools { next.bodies.removeAll { draft.tools.contains($0.id) } }
        meshForDisplay(made)
        return CombinePreviewOutput(preview: next)
    }

    private func applySubtractPreview(_ output: CombinePreviewOutput) {
        guard subtractDraft != nil else { return }
        subtractPreview = output.preview
        subtractError = output.error
    }

    /// Waits for the background Subtract preview (tests).
    func subtractPreviewSettled() async { await subtractPreviews.settled() }

    /// One undo step; the first result is selected.
    func confirmSubtract() {
        subtractPreviews.settle { subtractPreviewRequest() }
        guard let preview = subtractPreview, let draft = subtractDraft, !isEditingBlocked else { return }
        let original = Set(workspace.bodies.map(\.id))
        let first = draft.keep.keepsTargets ? preview.bodies.first { !original.contains($0.id) }?.id : draft.targets.first
        clearSubtract()
        commit(preview)
        status = "Subtracted"
        selection = first.map { .body($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelSubtract() { clearSubtract(); dimensionEdit = nil }

    private func clearSubtract() {
        if tool == .subtract { tool = .select }
        if subtractDraft != nil { subtractDraft = nil }
        subtractPreviews.drop()
        if subtractPreview != nil { subtractPreview = nil }
        subtractError = nil
    }

    // MARK: Union

    /// Union (or Intersect). A selected solid (or its face or edge) is the first one picked.
    func beginUnion(intersect: Bool = false) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        let bodyID: UUID?
        switch selection {
        case .body(let id), .edge(let id, _): bodyID = id
        case .face(let face): bodyID = face.bodyID
        default: bodyID = nil
        }
        let picked = pickedBodies
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = intersect ? .intersect : .union
        unionDraft = UnionDraft(bodies: picked.count > 1 ? picked : bodyID.map { [$0] } ?? [], intersect: intersect)
        updateUnionPreview()
    }

    /// Adds a solid (it becomes the target), or removes it when it is already picked.
    func toggleUnionBody(_ id: UUID) {
        guard var draft = unionDraft, workspace.isShown(body: id) else { return }
        if let index = draft.bodies.firstIndex(of: id) { draft.bodies.remove(at: index) } else { draft.bodies.append(id) }
        unionDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateUnionPreview()
    }

    func setUnionKeepOriginals(_ keep: Bool) {
        guard var draft = unionDraft else { return }
        draft.keepOriginals = keep
        unionDraft = draft
        updateUnionPreview()
    }

    /// The target with every other picked solid merged in: in its place, or (keeping the
    /// originals) as a new solid after it.
    /// Built off the main thread on screen.
    private func updateUnionPreview() {
        guard let request = unionPreviewRequest() else {
            unionPreviews.drop(); unionPreview = nil; unionError = nil; return
        }
        unionPreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    private func unionPreviewRequest() -> UnionPreviewRequest? {
        guard let draft = unionDraft, draft.bodies.count >= 2, let targetID = draft.target,
              workspace.bodies.contains(where: { $0.id == targetID }) else { return nil }
        return UnionPreviewRequest(base: workspace, draft: draft)
    }

    /// On any thread.
    nonisolated private static func buildUnionPreview(_ request: UnionPreviewRequest) -> CombinePreviewOutput {
        let performance = Performance.begin(request.draft.intersect ? "Intersect preview" : "Union preview")
        defer { Performance.end(performance) }
        let draft = request.draft, base = request.base
        guard let targetID = draft.target, let index = base.bodies.firstIndex(where: { $0.id == targetID }) else { return CombinePreviewOutput() }
        let tools = draft.bodies.dropLast().compactMap { id in base.bodies.first { $0.id == id } }
        var result: SolidBody
        if draft.intersect {
            guard let shared = Intersecting.intersect(base.bodies[index], with: tools) else {
                return CombinePreviewOutput(error: "These solids do not all overlap, so nothing would be left. Tap one to leave it out.")
            }
            result = shared
        } else {
            let (united, untouched) = Unioning.union(base.bodies[index], with: tools)
            guard untouched.isEmpty else {
                let names = untouched.compactMap { base.bodyNames[$0] }
                return CombinePreviewOutput(error: "\(names.joined(separator: " and ")) \(names.count == 1 ? "does" : "do") not touch the others. Tap it to leave it out.")
            }
            result = united
        }
        var next = base
        if draft.keepOriginals {
            result.id = UUID()
            result.hidden = nil
            next.bodies.insert(result, at: index + 1)
        } else {
            next.bodies[index] = result
            let absorbed = Set(tools.map(\.id))
            next.bodies.removeAll { absorbed.contains($0.id) }
        }
        meshForDisplay([result])
        return CombinePreviewOutput(preview: next)
    }

    private func applyUnionPreview(_ output: CombinePreviewOutput) {
        guard unionDraft != nil else { return }
        unionPreview = output.preview
        unionError = output.error
    }

    /// Waits for the background Union or Intersect preview (tests).
    func unionPreviewSettled() async { await unionPreviews.settled() }

    /// One undo step; the united solid is selected.
    func confirmUnion() {
        unionPreviews.settle { unionPreviewRequest() }
        guard let preview = unionPreview, let draft = unionDraft, !isEditingBlocked else { return }
        let original = Set(workspace.bodies.map(\.id))
        let united = draft.keepOriginals ? preview.bodies.first { !original.contains($0.id) }?.id : draft.target
        clearUnion()
        commit(preview)
        status = draft.intersect ? "Intersected \(draft.bodies.count) solids" : "United \(draft.bodies.count) solids"
        selection = united.map { .body($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelUnion() { clearUnion(); dimensionEdit = nil }

    private func clearUnion() {
        if tool == .union || tool == .intersect { tool = .select }
        if unionDraft != nil { unionDraft = nil }
        unionPreviews.drop()
        if unionPreview != nil { unionPreview = nil }
        unionError = nil
    }

    // MARK: Shell

    /// Adds or removes a face (any face, by its index on the committed solid and a point on it) to
    /// leave open. Picking a face of another solid starts over there.
    func toggleShellFace(bodyID: UUID, face: Int, at point: SIMD3<Double>) {
        guard shellDraft != nil || requireNewEditingAccess() else { return }
        guard tool == .shell, !isEditingBlocked, let body = workspace.bodies.first(where: { $0.id == bodyID }) else { return }
        dimensionEdit = nil
        var draft = shellDraft?.bodyID == bodyID ? shellDraft! : ShellDraft(bodyID: bodyID, openings: [], thickness: lastShellThickness)
        if let index = draft.openings.firstIndex(where: { $0.face == face }) {
            draft.openings.remove(at: index)
        } else {
            let name = (try? SolidKernel.solid(for: body)).flatMap { body.extrusionFace(face, of: $0) }
            draft.openings.append(ShellOpening(face: face, name: name, point: point))
        }
        shellDraft = draft
        selection = nil
        UISelectionFeedbackGenerator().selectionChanged()
        updateShellPreview()
    }

    /// Shell from the adaptive menu: a selected face opens straight away; a selected solid waits for faces.
    func shellSelection() {
        guard requireNewEditingAccess() else { return }
        let face = selectedFace, body = selectedBody?.id ?? face?.bodyID
        chooseTool(.shell)
        guard let body else { return }
        if let face { toggleShellFace(bodyID: body, face: face.face, at: face.point ?? face.center) }
        else { shellDraft = ShellDraft(bodyID: body, openings: [], thickness: lastShellThickness) }
    }

    /// `now`: built at once, so whether it fits is known (a typed value).
    func setShellThickness(_ thickness: Double, now: Bool = false) {
        guard var draft = shellDraft, thickness.isFinite else { return }
        let thickness = min(100, max(0.2, thickness))
        guard thickness != draft.thickness else { if now { shellPreviews.settle { shellPreviewRequest() } }; return }
        draft.thickness = thickness
        shellDraft = draft
        updateShellPreview(now: now)
    }

    func confirmShell() {
        shellPreviews.settle { shellPreviewRequest() }
        guard let draft = shellDraft, draftError == nil, let preview = shellPreview, !isEditingBlocked else { return }
        lastShellThickness = draft.thickness
        commit(preview)
        clearShellDraft()
        selection = .body(draft.bodyID)
        tool = .select
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelShell() { clearShellDraft(); dimensionEdit = nil; tool = .select }

    private func clearShellDraft() { shellPreviews.drop(); shellDraft = nil; shellPreview = nil; if holeDraft == nil { draftError = nil } }

    /// Builds the shelled solid, off the main thread on screen unless `now`.
    private func updateShellPreview(now: Bool = false) {
        guard let draft = shellDraft, workspace.bodies.contains(where: { $0.id == draft.bodyID }) else { return }
        guard !draft.openings.isEmpty else { shellPreviews.drop(); shellPreview = nil; draftError = nil; return }
        guard let request = shellPreviewRequest() else { return }
        shellPreviews.submit(request, inBackground: buildsPreviewsInBackground && !now)
    }

    private func shellPreviewRequest() -> ShellPreviewRequest? {
        guard let draft = shellDraft, !draft.openings.isEmpty, workspace.bodies.contains(where: { $0.id == draft.bodyID }) else { return nil }
        return ShellPreviewRequest(base: workspace, draft: draft)
    }

    /// The draft it was built for, and the workspace with the shell (nil when the wall does not fit); on any thread.
    nonisolated private static func buildShellPreview(_ request: ShellPreviewRequest) -> (ShellDraft, Workspace?) {
        let performance = Performance.begin("Shell preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        guard let index = request.base.bodies.firstIndex(where: { $0.id == draft.bodyID }) else { return (draft, nil) }
        var next = request.base
        let shell = ExtrusionCut.shell(of: next.bodies[index], openFaces: draft.openFaces,
                                       openingAt: draft.openings.filter { $0.name == nil }.map(\.point), thickness: draft.thickness)
        next.bodies[index].cuts.append(shell)
        guard request.base.bodies[index].isValid(appending: [shell]), (try? SolidKernel.solid(for: next.bodies[index])) != nil else { return (draft, nil) }
        meshForDisplay([next.bodies[index]])
        return (draft, next)
    }

    /// A result describes the draft it was built for, which may be older than the current one.
    private func applyShellPreview(_ output: (ShellDraft, Workspace?)) {
        let (draft, next) = output
        guard shellDraft?.bodyID == draft.bodyID else { return }
        if let next {
            shellPreview = next
            draftError = nil
        } else {
            shellPreview = nil
            draftError = "A \(lengthText(draft.thickness)) wall does not fit this solid. Try a thinner wall, or shell before rounding edges."
        }
    }

    /// Waits for the background Shell preview (tests).
    func shellPreviewSettled() async { await shellPreviews.settled() }

    // MARK: Section view

    /// Turns the section view on, cutting the solids in half from the front, or off.
    func toggleSection() {
        if section != nil { endSection(); return }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .select
        section = SectionView(orientation: .front, offset: sectionMiddle(along: SketchPlane.front.normalAxis))
    }

    func endSection() { section = nil; dimensionEdit = nil }

    /// Where the visible solids' middle lies along `normal`, so a new section cuts through them.
    private func sectionMiddle(along normal: SIMD3<Double>) -> Double {
        let bounds = visibleWorkspace.bodies.compactMap { try? SolidKernel.solid(for: $0).bounds }
        guard let first = bounds.first else { return 0 }
        let low = bounds.reduce(first.min) { simd_min($0, $1.min) }, high = bounds.reduce(first.max) { simd_max($0, $1.max) }
        return lengthUnit.rounded(simd_dot((low + high) / 2, normal))
    }

    /// Parallel to another world plane, through the solids' middle again.
    func setSectionOrientation(_ plane: SketchPlane) {
        guard var view = section, plane.isWorldPlane else { return }
        view.orientation = plane
        view.offset = sectionMiddle(along: plane.normalAxis)
        section = view
    }

    func flipSection() { section?.flipped.toggle() }

    func setSectionOffset(_ offset: Double) {
        guard offset.isFinite else { return }
        section?.offset = max(-10_000, min(10_000, offset))
    }

    // MARK: Delete Face

    /// Delete Face. A selected face is the first one picked.
    func beginDeleteFace() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        let face = selectedFace
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .deleteFace
        if let face {
            deleteFaceDraft = DeleteFaceDraft(bodyID: face.bodyID, faces: [])
            toggleDeleteFace(bodyID: face.bodyID, face: face.face, at: face.point ?? face.center)
        }
    }

    /// Picks a face to take off, or unpicks it. A face of another solid starts over there.
    func toggleDeleteFace(bodyID: UUID, face: Int, at point: SIMD3<Double>) {
        guard tool == .deleteFace, !isEditingBlocked, workspace.bodies.contains(where: { $0.id == bodyID }) else { return }
        var draft = deleteFaceDraft?.bodyID == bodyID ? deleteFaceDraft! : DeleteFaceDraft(bodyID: bodyID, faces: [])
        if let index = draft.faces.firstIndex(where: { $0.face == face }) { draft.faces.remove(at: index) }
        else { draft.faces.append(ShellOpening(face: face, name: nil, point: point)) }
        deleteFaceDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
        updateDeleteFacePreview()
    }

    /// Builds the solid without the picked faces, off the main thread on screen: closing the gap
    /// rebuilds the whole solid, which stopped the app for up to 3.2 s a tap on a 700-face solid
    /// (user report, November 11, 2026).
    private func updateDeleteFacePreview() {
        guard let request = deleteFacePreviewRequest() else {
            deleteFacePreviews.drop()
            deleteFacePreview = nil
            deleteFaceError = nil
            return
        }
        deleteFacePreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    private func deleteFacePreviewRequest() -> DeleteFacePreviewRequest? {
        guard let draft = deleteFaceDraft, !draft.faces.isEmpty, workspace.bodies.contains(where: { $0.id == draft.bodyID }) else { return nil }
        return DeleteFacePreviewRequest(base: workspace, draft: draft)
    }

    /// The draft it was built for, and the workspace without its faces (nil when the gap cannot close); on any thread.
    nonisolated private static func buildDeleteFacePreview(_ request: DeleteFacePreviewRequest) -> (DeleteFaceDraft, Workspace?) {
        let performance = Performance.begin("Delete Face preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        guard let index = request.base.bodies.firstIndex(where: { $0.id == draft.bodyID }),
              let result = FaceEditing.deleting(faces: draft.faces.map(\.point), of: request.base.bodies[index]) else { return (draft, nil) }
        var next = request.base
        next.bodies[index] = result
        meshForDisplay([result])
        return (draft, next)
    }

    /// A result describes the draft it was built for, which may be older than the current one.
    private func applyDeleteFacePreview(_ output: (DeleteFaceDraft, Workspace?)) {
        let (draft, next) = output
        guard deleteFaceDraft?.bodyID == draft.bodyID else { return }
        deleteFacePreview = next
        if next != nil {
            deleteFaceError = nil
        } else {
            deleteFaceError = draft.faces.count == 1 ? "The faces around it cannot close the gap. Tap the rest of the feature too, such as a hole's floor." :
                "The faces around them cannot close the gap. Tap the rest of the feature, or unpick a face."
        }
    }

    /// Waits for the background Delete Face preview (tests).
    func deleteFacePreviewSettled() async { await deleteFacePreviews.settled() }

    /// One undo step; the solid is selected.
    func confirmDeleteFace() {
        deleteFacePreviews.settle { deleteFacePreviewRequest() }
        guard let draft = deleteFaceDraft, let preview = deleteFacePreview, !isEditingBlocked else { return }
        clearDeleteFace()
        commit(preview)
        status = draft.faces.count == 1 ? "Deleted a face" : "Deleted \(draft.faces.count) faces"
        selection = .body(draft.bodyID)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelDeleteFace() { clearDeleteFace() }

    private func clearDeleteFace() {
        deleteFacePreviews.drop()
        if tool == .deleteFace { tool = .select }
        if deleteFaceDraft != nil { deleteFaceDraft = nil }
        if deleteFacePreview != nil { deleteFacePreview = nil }
        deleteFaceError = nil
    }

    // MARK: Holes

    /// Places (or moves) a hole at `center` on the face being sketched.
    func placeHole(at center: Point2) {
        guard holeDraft != nil || requireNewEditingAccess() else { return }
        guard tool == .hole, let face = sketchMode?.face, let plane = face.plane, !isEditingBlocked else { return }
        dimensionEdit = nil
        var draft = holeDraft ?? HoleDraft(bodyID: face.bodyID, plane: plane, center: center,
                                           spec: HolePresets.spec(lastHole.kind, size: lastHole.size),
                                           depth: HolePresets.defaultDepth(lastHole.kind, size: lastHole.size))
        draft.center = center
        updateHole(draft)
    }

    /// Switches hole type or size, resetting the dimensions to that preset.
    func chooseHole(kind: HoleSpec.Kind? = nil, size: String? = nil) {
        guard var draft = holeDraft else { return }
        let kind = kind ?? draft.spec.kind, size = size ?? draft.spec.size
        let wasInsert = draft.spec.kind == .insert
        draft.spec = HolePresets.spec(kind, size: size)
        if kind == .insert { draft.depth = HolePresets.defaultDepth(kind, size: size) }
        else if wasInsert { draft.depth = nil }
        lastHole = (kind, size)
        updateHole(draft)
    }

    func setHoleThrough(_ through: Bool) {
        guard var draft = holeDraft else { return }
        draft.depth = through ? nil : (draft.depth ?? HolePresets.defaultDepth(.insert, size: draft.spec.size) ?? 10)
        updateHole(draft)
    }

    func confirmHole() {
        holePreviews.settle { holePreviewRequest() }
        guard let draft = holeDraft, draftError == nil, let preview = holePreview, !isEditingBlocked else { return }
        commit(preview)
        clearHoleDraft()
        if draft.replacing != nil {
            finishFeatureEdit(draft.bodyID, status: "Hole changed")
        } else {
            revalidateSketchMode()
            // Stay in the Hole tool on this face for the next hole.
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelHole() {
        let editing = holeDraft?.replacing != nil ? holeDraft?.bodyID : nil
        clearHoleDraft()
        dimensionEdit = nil
        if let editing { finishFeatureEdit(editing, status: nil) }
    }

    private func clearHoleDraft() { holePreviews.drop(); holeDraft = nil; holePreview = nil; if shellDraft == nil { draftError = nil } }

    /// Builds the solid with the hole off the main thread on screen: editing a hole replays every
    /// step after it, which stopped the app for seconds on each move of a detailed solid's hole
    /// (November 11, 2026). Done waits for the latest.
    private func updateHole(_ draft: HoleDraft) {
        holeDraft = draft
        guard let request = holePreviewRequest() else {
            // No stale preview: Done would otherwise make the previous hole.
            holePreviews.drop()
            holePreview = nil
            draftError = "This hole does not fit here. Move it onto the solid or change its size."
            return
        }
        holePreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    private func holePreviewRequest() -> HolePreviewRequest? {
        guard let draft = holeDraft, workspace.bodies.contains(where: { $0.id == draft.bodyID }),
              ExtrusionCut.hole(draft.spec, at: draft.center, on: draft.plane, depth: draft.depth) != nil else { return nil }
        return HolePreviewRequest(base: workspace, draft: draft)
    }

    /// The draft it was built for, and the workspace with its hole (nil when it does not fit); on any thread.
    nonisolated private static func buildHolePreview(_ request: HolePreviewRequest) -> (HoleDraft, Workspace?) {
        let performance = Performance.begin("Hole preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        guard let index = request.base.bodies.firstIndex(where: { $0.id == draft.bodyID }),
              let operation = ExtrusionCut.hole(draft.spec, at: draft.center, on: draft.plane, depth: draft.depth) else { return (draft, nil) }
        var next = request.base
        next.bodies[index] = next.bodies[index].placing(operation, replacing: draft.replacing)
        guard next.bodies[index].isValid, (try? SolidKernel.solid(for: next.bodies[index])) != nil else { return (draft, nil) }
        meshForDisplay([next.bodies[index]])
        return (draft, next)
    }

    /// A result for a draft since changed is left for the newer one.
    private func applyHolePreview(_ output: (HoleDraft, Workspace?)) {
        let (draft, next) = output
        guard holeDraft == draft else { return }
        holePreview = next
        draftError = next != nil ? nil : draft.replacing != nil ?
            "This hole does not fit here, or a thread or fillet made after it cannot follow. Try another size or place." :
            "This hole does not fit here. Move it onto the solid or change its size."
    }

    /// Waits for the background Hole preview (tests).
    func holePreviewSettled() async { await holePreviews.settled() }

    // MARK: Primitives

    /// Places (or moves) the chosen primitive standing on `plane` at `center`.
    func placePrimitive(on plane: SketchPlane, at center: Point2) {
        guard primitiveDraft != nil || requireNewEditingAccess() else { return }
        guard let kind = tool.primitiveKind, !isEditingBlocked else { return }
        dimensionEdit = nil
        let sizes = primitiveDraft.flatMap { $0.kind == kind ? $0.sizes : nil } ?? lastPrimitiveSizes[kind] ?? kind.sizes.map(\.value)
        updatePrimitive(PrimitiveDraft(kind: kind, plane: plane, center: center, sizes: sizes))
    }

    private func updatePrimitive(_ draft: PrimitiveDraft) {
        primitiveDraft = draft
        guard let body = Primitives.body(draft.kind, sizes: draft.sizes, on: draft.plane, at: draft.center),
              (try? SolidKernel.solid(for: body)) != nil else {
            primitivePreview = nil
            return
        }
        var next = workspace
        next.bodies.append(body)
        primitivePreview = next
    }

    /// One undo step; the new solid is selected.
    func confirmPrimitive() {
        guard let draft = primitiveDraft, let preview = primitivePreview, let body = preview.bodies.last, !isEditingBlocked else { return }
        commit(preview)
        lastPrimitiveSizes[draft.kind] = draft.sizes
        clearPrimitive()
        tool = .select
        selection = .body(body.id)
        status = "Made a \(draft.kind.rawValue)"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelPrimitive() { clearPrimitive(); dimensionEdit = nil; tool = .select }

    private func clearPrimitive() {
        if primitiveDraft != nil { primitiveDraft = nil }
        if primitivePreview != nil { primitivePreview = nil }
    }

    // MARK: Peg & Socket

    /// Places (or moves) a peg at `center` on the face being sketched.
    func placePeg(at center: Point2) {
        guard pegDraft != nil || requireNewEditingAccess() else { return }
        guard tool == .peg, let face = sketchMode?.face, let plane = face.plane, !isEditingBlocked else { return }
        dimensionEdit = nil
        var draft = pegDraft ?? PegDraft(bodyID: face.bodyID, plane: plane, center: center, spec: lastPeg)
        if pegDraft == nil { draft.spec.clearance = fitClearance }
        draft.center = center
        updatePeg(draft)
    }

    /// Joined to the solid it stands on, or a separate solid (a dowel pin); a separate peg starts out
    /// reaching as far into the face as it stands out of it.
    func setPegSeparate(_ separate: Bool) {
        guard var draft = pegDraft, draft.spec.separate != separate else { return }
        draft.spec.separate = separate
        if separate && draft.spec.embed == 0 { draft.spec.embed = draft.spec.height }
        updatePeg(draft)
    }

    func setPegClearance(_ clearance: Double) {
        guard var draft = pegDraft, Fit.clearanceRange.contains(clearance) else { return }
        draft.spec.clearance = clearance
        updatePeg(draft)
    }

    /// One undo step for the peg and its sockets; the Peg tool stays ready on this face.
    func confirmPeg() {
        pegPreviews.settle { pegPreviewRequest() }
        guard let draft = pegDraft, draftError == nil, let preview = pegPreview, !isEditingBlocked else { return }
        let sockets = pegSockets.count
        commit(preview)
        clearPegDraft()
        let kind = draft.editing != nil ? "Peg changed" : draft.spec.separate ? "Separate peg added" : "Peg added"
        let text = sockets == 0 ? kind : "\(kind) · \(sockets == 1 ? "1 socket" : "\(sockets) sockets")"
        if draft.editing != nil {
            finishFeatureEdit(draft.bodyID, status: text)
        } else {
            lastPeg = draft.spec
            revalidateSketchMode()
            status = text
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelPeg() {
        let editing = pegDraft?.editing != nil ? pegDraft?.bodyID : nil
        clearPegDraft()
        dimensionEdit = nil
        if let editing { finishFeatureEdit(editing, status: nil) }
    }

    private func clearPegDraft() {
        pegPreviews.drop()
        if pegDraft != nil { pegDraft = nil }
        if pegPreview != nil { pegPreview = nil }
        if !pegSockets.isEmpty { pegSockets = [] }
        if shellDraft == nil && holeDraft == nil { draftError = nil }
    }

    /// Builds the peg and its sockets off the main thread on screen: a peg sockets every solid it
    /// pushes into, and editing one replays the steps after it in each, twice; on detailed solids
    /// that stopped the app for seconds on each move (November 11, 2026). Done waits for the latest.
    private func updatePeg(_ draft: PegDraft) {
        pegDraft = draft
        guard let request = pegPreviewRequest() else { return }
        pegPreviews.submit(request, inBackground: buildsPreviewsInBackground)
    }

    private func pegPreviewRequest() -> PegPreviewRequest? {
        pegDraft.map { PegPreviewRequest(base: workspace, draft: $0) }
    }

    /// The draft it was built for, and the peg made (nil when it does not fit); on any thread.
    nonisolated private static func buildPegPreview(_ request: PegPreviewRequest) -> (PegDraft, PegJoint.Result?) {
        let performance = Performance.begin("Peg preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        let made = draft.editing.map { PegJoint.replace($0, with: draft.spec, at: draft.center) } ??
            PegJoint.add(draft.spec, at: draft.center, on: draft.plane, to: draft.bodyID, in: request.base)
        if let made {
            let before = Dictionary(request.base.bodies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            meshForDisplay(made.workspace.bodies.filter { before[$0.id] != $0 })
        }
        return (draft, made)
    }

    /// A result for a draft since changed is left for the newer one.
    private func applyPegPreview(_ output: (PegDraft, PegJoint.Result?)) {
        let (draft, made) = output
        guard pegDraft == draft else { return }
        // No stale preview when it does not fit: Done would otherwise make the previous peg.
        pegPreview = made?.workspace
        pegSockets = made?.sockets ?? []
        draftError = made == nil ? "This peg does not fit here. Move it onto the face or change its size." : nil
    }

    /// Waits for the background Peg preview (tests).
    func pegPreviewSettled() async { await pegPreviews.settled() }

    // MARK: Text

    /// Places (or moves) text centered at `center` on the face being sketched.
    func placeText(at center: Point2) {
        guard textDraft != nil || requireNewEditingAccess() else { return }
        guard tool == .text, let face = sketchMode?.face, let plane = face.plane, !isEditingBlocked else { return }
        dimensionEdit = nil
        var draft = textDraft ?? TextDraft(bodyID: face.bodyID, plane: plane, center: center, text: lastText.text, font: lastText.font,
                                           height: lastText.height, depth: lastText.depth, angle: 0)
        draft.center = center
        updateText(draft)
    }

    func setText(_ text: String) {
        guard var draft = textDraft, text != draft.text else { return }
        draft.text = String(text.prefix(TextSpec.maximumLength))
        updateText(draft)
    }

    func setTextFont(_ font: String) {
        guard var draft = textDraft else { return }
        draft.font = font
        updateText(draft)
    }

    /// Raised from the face (emboss), or sunk into it (deboss), keeping the depth.
    func setTextRaised(_ raised: Bool) {
        guard var draft = textDraft, (draft.depth > 0) != raised else { return }
        draft.depth = -draft.depth
        updateText(draft)
    }

    /// Turns the text a quarter turn.
    func rotateText() {
        guard var draft = textDraft else { return }
        draft.angle = (draft.angle + 90).truncatingRemainder(dividingBy: 360)
        updateText(draft)
    }

    /// One undo step, once the preview is built; the Text tool stays ready on this face.
    func confirmText() {
        guard let draft = textDraft, let preview = textPreview, !isBuildingText, !isEditingBlocked else { return }
        commit(preview)
        lastText = (draft.text, draft.font, draft.height, draft.depth)
        clearTextDraft()
        if draft.replacing != nil {
            finishFeatureEdit(draft.bodyID, status: "Text changed")
        } else {
            revalidateSketchMode()
            status = draft.depth > 0 ? "Text raised" : "Text sunk"
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelText() {
        let editing = textDraft?.replacing != nil ? textDraft?.bodyID : nil
        clearTextDraft()
        dimensionEdit = nil
        if let editing { finishFeatureEdit(editing, status: nil) }
    }

    private func clearTextDraft() {
        textGeneration += 1
        if textDraft != nil { textDraft = nil }
        if textPreview != nil { textPreview = nil }
        if isBuildingText { isBuildingText = false }
        textError = nil
    }

    /// Lays out the letters now (fast) and builds the solid preview in the background.
    private func updateText(_ draft: TextDraft) {
        var draft = draft
        draft.spec = TextSpec.make(draft.text, font: draft.font, height: draft.height, center: draft.center, angle: draft.angle)
        textDraft = draft
        textPreview = nil
        textError = nil
        textGeneration += 1
        let generation = textGeneration
        guard let spec = draft.spec, spec.isValid, let operation = ExtrusionCut.text(spec, on: draft.plane, depth: draft.depth),
              let index = workspace.bodies.firstIndex(where: { $0.id == draft.bodyID }) else {
            isBuildingText = false
            textError = draft.text.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the text to add." : "This font cannot draw that text."
            return
        }
        var next = workspace
        next.bodies[index] = next.bodies[index].placing(operation, replacing: draft.replacing)
        let body = next.bodies[index]
        isBuildingText = true
        let previous = textBuild
        textBuild = Task { [weak self] in
            // One build at a time, and only the latest text: a newer one makes this one moot.
            await previous?.value
            guard generation == self?.textGeneration else { return }
            let builds = await Task.detached(priority: .userInitiated) { body.isValid && (try? SolidKernel.solid(for: body)) != nil }.value
            guard let self, generation == self.textGeneration else { return }
            self.isBuildingText = false
            guard builds else {
                self.textError = draft.depth > 0 ? "Some letters are off the face. Move the text onto it, or make it smaller." :
                    "The text is not on the face, or cuts the part apart. Move it, or make it shallower."
                return
            }
            self.textPreview = next
        }
    }

    /// Waits for the text preview being built (tests).
    func textPreviewSettled() async {
        while isBuildingText { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Threads

    /// Sets up a thread on a solid's cylindrical face (a hole or round boss), sized from the face.
    func beginThread(bodyID: UUID, face: Int) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked, let body = workspace.bodies.first(where: { $0.id == bodyID }),
              let solid = try? SolidKernel.solid(for: body) else { return }
        guard let spec = body.threadSpec(onFace: face, of: solid, clearance: fitClearance, preferInch: lengthUnit == .inches) else {
            status = "Only a hole's wall or a round boss's side can be threaded"
            return
        }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .thread
        updateThread(ThreadDraft(bodyID: bodyID, face: face, spec: spec, atEnd: body.threadEntryIsAtEnd(spec)))
    }

    /// A standard size at its usual (coarse) pitch, or "" to keep the current diameter and pitch as a
    /// custom thread. A size that misses the face is refused with the reason.
    func chooseThreadSize(_ name: String) {
        guard var draft = threadDraft else { return }
        if let size = ThreadPresets.size(named: name) {
            draft.spec = draft.spec.with(size: size, diameter: size.diameter, pitch: size.coarse)
        } else {
            draft.spec.size = ""
        }
        updateThread(draft)
    }

    /// Another pitch for the thread: a fine one of its size, or any for a custom thread.
    func chooseThreadPitch(_ pitch: Double) {
        guard var draft = threadDraft else { return }
        draft.spec = draft.spec.with(pitch: pitch)
        updateThread(draft)
    }

    /// Raises the thread onto the face (ridges added, the wall kept whole) or cuts it into the face,
    /// with the size that then suits the face.
    func setThreadRaised(_ raised: Bool) {
        guard var draft = threadDraft, draft.spec.isRaised != raised else { return }
        draft.spec = draft.spec.made(raised: raised, preferInch: lengthUnit == .inches)
        updateThread(draft)
    }

    /// ISO 60° (screws and nuts) or the printable 45° profile (lids and jars).
    func setThreadProfile(_ profile: ThreadProfile) {
        guard var draft = threadDraft, draft.spec.shape != profile else { return }
        draft.spec = draft.spec.with(profile: profile)
        updateThread(draft)
    }

    /// Whether a raised thread's ridges fade out at their ends instead of stopping square.
    func setThreadTaperedEnds(_ on: Bool) {
        guard var draft = threadDraft, draft.spec.isRaised else { return }
        draft.spec.taperedEnds = on ? true : nil
        updateThread(draft)
    }

    /// How many ridges wind side by side (1–4).
    func setThreadStarts(_ starts: Int) {
        guard var draft = threadDraft, ThreadSpec.startsRange.contains(starts) else { return }
        draft.spec.starts = starts > 1 ? starts : nil
        updateThread(draft)
    }

    /// Threads the whole face (nil), or that much of it from the end it is screwed in at.
    func setThreadLength(_ length: Double?) {
        guard var draft = threadDraft else { return }
        draft.length = length.flatMap { $0 < draft.spec.threadedLength - 1e-6 ? $0 : nil }
        updateThread(draft)
    }

    /// The standard sizes offered for the thread being placed, with how each fits its face.
    func threadSizeChoices(_ standard: ThreadSize.Standard) -> [ThreadSizeChoice] {
        guard let draft = threadDraft else { return [] }
        let suggested = ThreadPresets.suggestion(internal: draft.spec.isInternal, surfaceDiameter: draft.spec.surfaceDiameter,
                                                 clearance: draft.spec.clearance, preferInch: lengthUnit == .inches, raised: draft.spec.isRaised).size
        return (standard == .metric ? ThreadPresets.metric : ThreadPresets.inch).map { size in
            let spec = draft.spec.with(size: size, diameter: size.diameter, pitch: size.coarse)
            let note = size.name == suggested ? "Best fit" : spec.fitNote(lengthText)
            return ThreadSizeChoice(size: size, title: size.title(pitch: size.coarse), note: note, fit: spec.fit.kind,
                                    inUse: draft.spec.standardSize?.name == size.name)
        }
    }

    /// The pitches offered for the thread being placed: its size's coarse and fine ones, or the
    /// usual series for a custom diameter, each with a note.
    var threadPitchChoices: [(pitch: Double, title: String, note: String, usable: Bool)] {
        guard let draft = threadDraft else { return [] }
        let size = draft.spec.standardSize ?? ThreadPresets.size(named: draft.spec.size).flatMap { abs($0.diameter - draft.spec.majorDiameter) < 1e-6 ? $0 : nil }
        let pitches = size?.pitches ?? ThreadPresets.customPitches(for: draft.spec.majorDiameter)
        return pitches.map { pitch in
            let spec = draft.spec.with(pitch: pitch)
            let title = size?.standard == .inch ? "\(ThreadSize.tpi(pitch)) threads per inch" : lengthText(pitch)
            var notes: [String] = []
            if let size { notes.append(size.pitchKind(pitch) + (abs(pitch - size.coarse) < 1e-6 ? " (standard)" : "")) }
            if pitch < 0.5 { notes.append("too fine for most FDM printers") }
            if spec.isValid, spec.fit.kind == .partial { notes.append(spec.fitNote(lengthText)) }
            return (pitch, title, notes.joined(separator: ", "), spec.isValid && spec.fit.isUsable)
        }
    }

    func setThreadClearance(_ clearance: Double) {
        guard var draft = threadDraft, clearance == 0 || Fit.clearanceRange.contains(clearance) else { return }
        draft.spec.clearance = clearance
        updateThread(draft)
    }

    func setThreadLeftHanded(_ left: Bool) {
        guard var draft = threadDraft else { return }
        draft.spec.leftHanded = left ? true : nil
        updateThread(draft)
    }

    /// The 45° chamfer at the thread's open ends (on by default).
    func setThreadLeadIn(_ on: Bool) {
        guard var draft = threadDraft, draft.spec.hasOpenEnd else { return }
        draft.spec.leadIn = on ? true : nil
        updateThread(draft)
    }

    /// One undo step, once the preview is built.
    func confirmThread() {
        guard let draft = threadDraft, let preview = threadPreview, !isBuildingThread, !isEditingBlocked else { return }
        commit(preview)
        clearThread()
        selection = .body(draft.bodyID)
        status = (draft.replacing != nil ? "Thread changed to " : "Threaded ") + (draft.built?.title ?? draft.spec.title)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelThread() {
        let editing = threadDraft?.replacing != nil ? threadDraft?.bodyID : nil
        clearThread()
        dimensionEdit = nil
        if let editing { selection = .body(editing) }
    }

    private func clearThread() {
        if tool == .thread { tool = .select }
        threadGeneration += 1
        if threadDraft != nil { threadDraft = nil }
        if threadPreview != nil { threadPreview = nil }
        if isBuildingThread { isBuildingThread = false }
        threadError = nil
        threadWall = nil
    }

    /// Builds the preview off the main thread; the newest draft wins.
    private func updateThread(_ draft: ThreadDraft) {
        threadDraft = draft
        threadPreview = nil
        threadError = nil
        threadWall = nil
        threadGeneration += 1
        let generation = threadGeneration
        guard draft.spec.isValid, let spec = draft.built else {
            isBuildingThread = false
            if !ThreadSpec.pitchRange.contains(draft.spec.pitch) || draft.spec.pitch > draft.spec.largestPitch {
                threadError = "A \(lengthText(draft.spec.majorDiameter)) thread takes a pitch up to \(lengthText(max(0.2, draft.spec.largestPitch))). Choose a smaller pitch."
            } else {
                threadError = "That thread cannot be cut. Choose a size from the Size menu."
            }
            return
        }
        // A size that misses the face is explained, not built.
        guard spec.fit.isUsable else {
            isBuildingThread = false
            threadError = spec.fitSummary(lengthText)
            return
        }
        guard let index = workspace.bodies.firstIndex(where: { $0.id == draft.bodyID }) else { return }
        // Editing: the solid without the old thread, the new one going in at its step.
        var body = workspace.bodies[index]
        let replaced = draft.replacing.flatMap { body.cuts.indices.contains($0) ? body.cuts.remove(at: $0) : nil }
        let base = workspace, step = draft.replacing
        isBuildingThread = true
        let previous = threadBuild
        threadBuild = Task { [weak self, body] in
            // One build at a time, and only the latest settings: a newer change makes this one moot.
            await previous?.value
            guard generation == self?.threadGeneration else { return }
            let (threaded, wall) = await Task.detached(priority: .userInitiated) {
                Self.threadBuilds.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
                defer { Self.threadBuilds.withLock { $0.now -= 1 } }
                var threaded = body.threading(spec, at: step)
                if let step, let replaced { threaded?.cuts[step].id = replaced.id }
                return (threaded, (try? SolidKernel.solid(for: body)).flatMap { body.wallBehindThread(spec, in: $0) })
            }.value
            guard let self, generation == self.threadGeneration else { return }
            self.isBuildingThread = false
            guard let threaded else {
                self.threadError = "\(spec.title) could not be built on this \(spec.isInternal ? "hole" : "boss"). Try a nearby pitch or size, or a shorter length."
                return
            }
            var next = base
            next.bodies[index] = threaded
            self.threadWall = wall
            self.threadPreview = next
        }
    }

    /// Thread builds running now, and the most at once (tests).
    nonisolated private static let threadBuilds = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
    static var mostThreadBuildsAtOnce: Int { threadBuilds.withLock { $0.most } }

    // MARK: Screw Lid (October 26, 2026)

    /// Starts Screw Lid on a round boss: the neck's thread and its lid, at the usual settings.
    func beginScrewLid(bodyID: UUID, face: Int) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked, workspace.bodies.contains(where: { $0.id == bodyID }) else { return }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .screwLid
        updateScrewLid(ScrewLidDraft(bodyID: bodyID, face: face, spec: ScrewLidSpec(clearance: fitClearance)))
    }

    func setScrewLidPitch(_ pitch: Double) { changeScrewLid { $0.pitch = pitch } }
    func setScrewLidStarts(_ starts: Int) { changeScrewLid { $0.starts = starts } }
    func setScrewLidTurns(_ turns: Double) { changeScrewLid { $0.turns = turns } }
    func setScrewLidTop(_ top: Double) { changeScrewLid { $0.top = top } }
    /// The lid's whole height, or nil for the thread plus the top plus a millimeter.
    func setScrewLidHeight(_ height: Double?) { changeScrewLid { $0.height = height } }
    func setScrewLidRibbed(_ ribbed: Bool) { changeScrewLid { $0.ribbed = ribbed } }
    func setScrewLidClearance(_ clearance: Double) { changeScrewLid { $0.clearance = clearance } }

    private func changeScrewLid(_ change: (inout ScrewLidSpec) -> Void) {
        guard var draft = screwLidDraft else { return }
        change(&draft.spec)
        guard draft.spec != screwLidDraft?.spec else { return }
        updateScrewLid(draft)
    }

    /// The thread the neck takes now, without building it (for the bar's height choices).
    var screwLidThread: ThreadSpec? {
        guard let draft = screwLidDraft, let body = workspace.bodies.first(where: { $0.id == draft.bodyID }) else { return nil }
        return try? ScrewLid.thread(on: body, face: draft.face, draft.spec).thread
    }

    /// Builds the threaded neck and its lid off the main thread, one build at a time, newest wins.
    private func updateScrewLid(_ draft: ScrewLidDraft) {
        screwLidDraft = draft
        screwLidPreview = nil
        screwLidLid = nil
        screwLidError = nil
        screwLidGeneration += 1
        let generation = screwLidGeneration
        guard let index = workspace.bodies.firstIndex(where: { $0.id == draft.bodyID }) else { return }
        let body = workspace.bodies[index], base = workspace
        isBuildingScrewLid = true
        let previous = screwLidBuild
        screwLidBuild = Task { [weak self] in
            await previous?.value
            guard generation == self?.screwLidGeneration else { return }
            let result = await Task.detached(priority: .userInitiated) { Result { try ScrewLid.make(on: body, face: draft.face, draft.spec) } }.value
            guard let self, generation == self.screwLidGeneration else { return }
            self.isBuildingScrewLid = false
            switch result {
            case .success(let made):
                var next = base
                next.bodies[index] = made.jar
                var lid = made.lid
                lid.name = "Lid"
                next.bodies.append(lid)
                self.screwLidLid = lid.id
                self.screwLidPreview = next
            case .failure(let error):
                self.screwLidError = (error as? ScrewLid.Failure)?.message ?? error.localizedDescription
            }
        }
    }

    func confirmScrewLid() {
        guard screwLidDraft != nil, let preview = screwLidPreview, let lid = screwLidLid, !isBuildingScrewLid, !isBuildingScrewLidTest, !isEditingBlocked else { return }
        commit(preview)
        clearScrewLid()
        selection = .body(lid)
        status = "Added a screw lid"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Adds the thread fit test for the neck at the current settings beside the model, as its own
    /// undo step, and keeps Screw Lid open (its preview rebuilt on the new model) to finish after.
    func addScrewLidFitTest() {
        guard requireNewEditingAccess() else { return }
        guard let draft = screwLidDraft, !isBuildingScrewLidTest, !isEditingBlocked,
              let body = workspace.bodies.first(where: { $0.id == draft.bodyID }) else { return }
        let base = workspace, origin = FitTest.origin(beside: workspace)
        isBuildingScrewLidTest = true
        // After any lid build, so only one thread is built at a time.
        let previous = screwLidBuild
        screwLidBuild = Task { [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) { Result { try ScrewLid.fitTest(on: body, face: draft.face, draft.spec, at: origin) } }.value
            guard let self else { return }
            self.isBuildingScrewLidTest = false
            // Dropped if the model or the operation changed meanwhile.
            guard self.screwLidDraft?.bodyID == draft.bodyID, self.canFinishBuild(from: base) else { return }
            switch result {
            case .success(let test):
                let (group, bodies) = test.parts
                var next = self.workspace
                next.groups.append(group)
                next.bodies += bodies
                guard next.isValid else { return }
                self.commit(next)
                self.status = "Thread Fit Test added"
                self.requestCamera(.reset)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if let current = self.screwLidDraft { self.updateScrewLid(current) }
            case .failure(let error):
                self.screwLidError = (error as? ScrewLid.Failure)?.message ?? error.localizedDescription
            }
        }
    }

    func cancelScrewLid() {
        clearScrewLid()
        dimensionEdit = nil
    }

    private func clearScrewLid() {
        if tool == .screwLid { tool = .select }
        screwLidGeneration += 1
        if screwLidDraft != nil { screwLidDraft = nil }
        if screwLidPreview != nil { screwLidPreview = nil }
        screwLidLid = nil
        if isBuildingScrewLid { isBuildingScrewLid = false }
        if isBuildingScrewLidTest { isBuildingScrewLidTest = false }
        screwLidError = nil
    }

    /// Waits for the screw lid being built (tests).
    func screwLidSettled() async {
        while isBuildingScrewLid || isBuildingScrewLidTest { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Waits for the thread preview being built (tests).
    func threadPreviewSettled() async {
        while isBuildingThread { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Adds a `kind` part that screws onto the selected thread, already screwed on so the fit shows,
    /// as one undo step, and selects it. Built in the background; a change meanwhile drops it.
    func makeMatingPart(_ kind: ThreadMate) {
        guard requireNewEditingAccess() else { return }
        guard !isMakingMatingPart, let target = selectedThread, let body = workspace.bodies.first(where: { $0.id == target.bodyID }) else { return }
        cancelTransient()
        endSketchMode()
        let base = workspace
        isMakingMatingPart = true
        status = "Making the \(kind.noun)…"
        Task { [weak self] in
            let part = await Task.detached(priority: .userInitiated) { body.matingPart(kind, forThreadAt: target.cut) }.value
            guard let self else { return }
            self.isMakingMatingPart = false
            guard self.canFinishBuild(from: base) else {
                self.status = "The model changed while the \(kind.noun) was being made. Choose Matching Part again."
                return
            }
            guard let part, let index = base.bodies.firstIndex(where: { $0.id == body.id }) else {
                self.status = "A \(kind.noun) could not be made for this thread"
                return
            }
            self.commitBuilt { $0.bodies.insert(part, at: index + 1) }
            self.selection = .body(part.id)
            self.status = "Made a matching \(kind.noun), screwed on. Move it aside to print it, or export with Arrange on Plate."
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: Delete Hole

    private(set) var isDeletingHole = false

    /// The selected face is a hole's round wall, or a face of the thread in a hole: where the hole's
    /// empty middle is (level with the tap, or halfway along the thread).
    private var selectedHoleProbe: (body: SolidBody, probe: SIMD3<Double>, solid: KernelSolid, face: Int)? {
        selectionFact("holeProbe") { () -> (body: SolidBody, probe: SIMD3<Double>, solid: KernelSolid, face: Int)? in selectedHoleProbeNow }
    }
    private var selectedHoleProbeNow: (body: SolidBody, probe: SIMD3<Double>, solid: KernelSolid, face: Int)? {
        guard let face = selectedFace, face.plane == nil, let body = workspace.bodies.first(where: { $0.id == face.bodyID }),
              let solid = try? SolidKernel.solid(for: body) else { return nil }
        if let probe = solid.holeProbe(face: face.face, near: face.point ?? face.center) { return (body, probe, solid, face.face) }
        if let thread = body.thread(atFace: face.face, of: solid), let spec = body.cuts[thread].thread, spec.isInternal {
            return (body, body.worldPoint(spec.origin + spec.axis * (spec.length / 2)), solid, face.face)
        }
        return nil
    }
    var canDeleteSelectedHole: Bool { !isEditingBlocked && !isDeletingHole && selectedHoleProbe != nil }

    /// Takes the selected hole out of its solid (one undo step): the step that made it comes out of
    /// the solid's definition, with a thread cut into it and fillets on its rim; a hole no step
    /// made (an imported solid's) is closed with Delete Face. Worked out in the background.
    func deleteSelectedHole() {
        guard requireNewEditingAccess() else { return }
        guard canDeleteSelectedHole, let target = selectedHoleProbe else { return }
        cancelTransient()
        let base = workspace, body = target.body, probe = target.probe
        let facePoints = target.solid.holeFacePoints(wall: target.face)
        isDeletingHole = true
        status = "Deleting the hole…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (SolidBody, String)? in
                if let removal = body.removingHole(around: probe) {
                    var notes: [String] = []
                    if removal.threads > 0 { notes.append(removal.threads == 1 ? "its thread" : "its threads") }
                    if removal.finishedEdges > 0 { notes.append("the fillet or chamfer on its rim") }
                    return (removal.body, "Deleted the hole" + (notes.isEmpty ? "" : " and " + notes.joined(separator: " and ")))
                }
                return FaceEditing.deleting(faces: facePoints, of: body).map { ($0, "Deleted the hole and closed the gap") }
            }.value
            guard let self else { return }
            self.isDeletingHole = false
            guard self.canFinishBuild(from: base) else {
                self.status = "The model changed while the hole was being deleted. Choose Delete Hole again."
                return
            }
            guard let (deleted, message) = result, let index = base.bodies.firstIndex(where: { $0.id == body.id }) else {
                self.status = "This hole could not be deleted. Try Delete Face and tap each of its faces."
                return
            }
            self.commitBuilt { $0.bodies[index] = deleted }
            self.selection = .body(body.id)
            self.status = message
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// A part built in the background can still be kept: the model it was built from is unchanged
    /// (notes typed meanwhile don't count) and nothing but Notes typing holds editing.
    private func canFinishBuild(from base: Workspace) -> Bool {
        workspace.hasSameModel(as: base) && !isBlockedApartFromNotes
    }
    private var isBlockedApartFromNotes: Bool { isReadOnly || purchaseBlocksEditing || isProjectBusy || isResizingDimension || isAssistantWorking || assistantPreview != nil }

    /// Keeps a part built in the background, even while Notes has the keyboard: the typing so far
    /// is saved first as its own step, so the part is one undo step of its own.
    private func commitBuilt(_ change: (inout Workspace) -> Void) {
        flushNotes()
        var next = workspace
        change(&next)
        commit(next, besideNotes: true)
    }

    /// Waits for Delete Hole (tests).
    func holeDeletionSettled() async {
        while isDeletingHole { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Fillets and chamfers from their faces

    private(set) var isDeletingFinish = false

    var canDeleteSelectedFinish: Bool { !isEditingBlocked && !isDeletingFinish && selectedFinish != nil }

    /// Takes the selected face's fillet or chamfer out of its solid (one undo step): its edges are
    /// sharp again, every edge it rounded or beveled included. Worked out in the background, as it
    /// builds the solid again without the finish, replaying every later step: on the main thread
    /// that stopped the app for 0.4–1.3 s on a 99- to 145-step plate (user report, November 11, 2026).
    func deleteSelectedFinish() {
        guard requireNewEditingAccess() else { return }
        guard canDeleteSelectedFinish, let finish = selectedFinish, let body = workspace.bodies.first(where: { $0.id == finish.bodyID }) else { return }
        cancelTransient()
        let base = workspace, source = finish.source, kind = finish.kind
        isDeletingFinish = true
        status = "Deleting the \(kind.rawValue)…"
        Task { [weak self] in
            let removed = await Task.detached(priority: .userInitiated) { body.removingFinish(source) }.value
            guard let self else { return }
            self.isDeletingFinish = false
            guard self.canFinishBuild(from: base) else {
                self.status = "The model changed while the \(kind.rawValue) was being deleted. Choose Delete \(kind.title) again."
                return
            }
            guard let removed, let index = base.bodies.firstIndex(where: { $0.id == body.id }) else {
                self.status = "This \(kind.rawValue) could not be deleted. Try Delete Face on it."
                return
            }
            self.commitBuilt { $0.bodies[index] = removed }
            self.selection = .body(body.id)
            self.status = "Deleted the \(kind.rawValue)"
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Waits for Delete Fillet or Delete Chamfer (tests).
    func finishDeletionSettled() async {
        while isDeletingFinish { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A point on a face of `body` (as built) that the finish at `source` makes, nearest `point`: the
    /// tapped point carried onto the resized round or bevel. Nil for faces other than cylinders and
    /// planes. Builds the solid without the finish; on any thread.
    nonisolated private static func finishFacePoint(of body: SolidBody, source: FinishSource, near point: SIMD3<Double>) -> SIMD3<Double>? {
        guard let solid = try? SolidKernel.solid(for: body), let without = body.removingFinish(source),
              let plain = try? SolidKernel.solid(for: without) else { return nil }
        var best: (distance: Double, point: SIMD3<Double>)?
        for face in 0..<solid.faceCount {
            let moved: SIMD3<Double>
            if let cylinder = solid.faceCylinder(face) {
                let axis = simd_normalize(cylinder.direction), d = point - cylinder.point
                let radial = d - axis * simd_dot(d, axis)
                guard simd_length(radial) > 1e-9 else { continue }
                moved = cylinder.point + axis * simd_dot(d, axis) + simd_normalize(radial) * cylinder.radius
            } else if let plane = solid.facePlane(face) {
                moved = point - plane.normal * simd_dot(point - plane.origin, plane.normal)
            } else { continue }
            guard solid.face(near: moved, tolerance: 1e-4) == face, plain.face(near: moved, tolerance: 1e-3) == nil else { continue }
            let distance = simd_distance(moved, point)
            if distance < (best?.distance ?? .infinity) { best = (distance, moved) }
        }
        return best?.point
    }

    // MARK: Edit after Done (October 24, 2026)

    /// The hole, thread, text, or peg the selection is on, which Edit reopens in its tool: a face
    /// of one (a socket's wall counts as its peg's), or a separate peg's pin.
    var selectedFeature: EditableFeature? {
        guard !isEditingBlocked else { return nil }
        if let body = selectedBody, let pin = body.peg { return .peg(pin.id, body: body.id) }
        guard let face = selectedFace, selectedFinish == nil, !isFindingFinish, let body = workspace.bodies.first(where: { $0.id == face.bodyID }) else { return nil }
        let point = face.point ?? face.center
        if let cache = featureCache, cache.body == body, cache.face == face.face, cache.point == point { return cache.feature }
        var feature: EditableFeature?
        if let thread = selectedThread, thread.bodyID == body.id {
            feature = .thread(body: body.id, cut: thread.cut)
        } else if let tag = body.pegTag(at: point), PegJoint.existing(tag, in: workspace, preferring: body.id, clearance: fitClearance) != nil {
            feature = .peg(tag, body: body.id)
        } else if let cut = body.textCut(at: point) {
            feature = .text(body: body.id, cut: cut)
        } else if face.plane == nil, let probe = selectedHoleProbe?.probe, let cut = body.holeCut(around: probe) {
            feature = .hole(body: body.id, cut: cut)
        }
        featureCache = (body, face.face, point, feature)
        return feature
    }
    @ObservationIgnored private var featureCache: (body: SolidBody, face: Int, point: SIMD3<Double>, feature: EditableFeature?)?

    /// Reopens the selected feature in its tool with the values it was made with; Done puts the
    /// changed one in its place (one undo step), and Cancel leaves it as it was.
    func editSelectedFeature() {
        guard requireNewEditingAccess() else { return }
        guard let feature = selectedFeature else { return }
        switch feature {
        case .hole(let body, let cut): editHole(bodyID: body, cut: cut)
        case .thread(let body, let cut): editThread(bodyID: body, cut: cut)
        case .text(let body, let cut): editText(bodyID: body, cut: cut)
        case .peg(let id, let body): editPeg(id, from: body)
        }
    }

    func editHole(bodyID: UUID, cut: Int) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked, let body = workspace.bodies.first(where: { $0.id == bodyID }), body.cuts.indices.contains(cut),
              let spec = body.cuts[cut].hole, let circle = body.cuts[cut].profile.circle else { return }
        let operation = body.cuts[cut]
        guard enterFeatureSketch(bodyID: bodyID, plane: operation.profile.plane, at: circle.center, tool: .hole) else { return }
        updateHole(HoleDraft(bodyID: bodyID, plane: operation.profile.plane, center: circle.center, spec: spec,
                             depth: operation.throughAll ? nil : operation.depth, replacing: cut))
    }

    func editText(bodyID: UUID, cut: Int) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked, let body = workspace.bodies.first(where: { $0.id == bodyID }), body.cuts.indices.contains(cut),
              let spec = body.cuts[cut].text else { return }
        let operation = body.cuts[cut]
        guard enterFeatureSketch(bodyID: bodyID, plane: operation.profile.plane, at: spec.center, tool: .text) else { return }
        updateText(TextDraft(bodyID: bodyID, plane: operation.profile.plane, center: spec.center, text: spec.text, font: spec.font,
                             height: spec.height, depth: operation.depth, angle: spec.angle, replacing: cut))
    }

    func editThread(bodyID: UUID, cut: Int) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked, !isOpeningThread, let body = workspace.bodies.first(where: { $0.id == bodyID }) else { return }
        guard buildsPreviewsInBackground else { return openThread(body.threadSetup(at: cut), bodyID: bodyID, cut: cut) }
        // Setting it up builds the solid without the thread, replaying every step after it: off the
        // main thread on screen, as that stopped the app on a detailed solid (November 11, 2026).
        let base = workspace, selected = selection
        isOpeningThread = true
        status = "Opening the thread…"
        Task { [weak self] in
            let setup = await Task.detached(priority: .userInitiated) { body.threadSetup(at: cut) }.value
            guard let self else { return }
            self.isOpeningThread = false
            guard self.workspace == base, self.selection == selected, !self.isEditingBlocked else { return }
            self.openThread(setup, bodyID: bodyID, cut: cut)
        }
    }

    /// Waits for Edit Thread to open the tool (tests).
    func threadOpeningSettled() async {
        while isOpeningThread { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func openThread(_ setup: ThreadSetup?, bodyID: UUID, cut: Int) {
        guard let setup else {
            status = "The face this thread is on is gone, so it cannot be edited. Delete it with Undo or Delete Hole."
            return
        }
        cancelTransient()
        endSketchMode()
        selection = nil
        tool = .thread
        updateThread(ThreadDraft(bodyID: bodyID, face: setup.face, spec: setup.spec, length: setup.length, atEnd: setup.atEnd, replacing: cut))
    }

    func editPeg(_ id: UUID, from bodyID: UUID?) {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked, let old = PegJoint.existing(id, in: workspace, preferring: bodyID, clearance: fitClearance) else { return }
        guard enterFeatureSketch(bodyID: old.bodyID, plane: old.plane, at: old.center, tool: .peg) else { return }
        updatePeg(PegDraft(bodyID: old.bodyID, plane: old.plane, center: old.center, spec: old.spec, editing: old))
    }

    /// Sketch mode on the face `plane` lies on, looking at `center`, with `tool` ready, as when the
    /// tool was first used there. False (with a status) when no face of the solid lies on the plane.
    private func enterFeatureSketch(bodyID: UUID, plane featurePlane: SketchPlane, at center: Point2, tool value: ModelingTool) -> Bool {
        guard let body = workspace.bodies.first(where: { $0.id == bodyID }), let solid = try? SolidKernel.solid(for: body) else { return false }
        let normal = featurePlane.normalAxis
        guard let index = (0..<solid.faceCount).first(where: { index in
            solid.facePlane(index).map { simd_dot($0.normal, normal) > 1 - 1e-9 && abs(simd_dot($0.origin - featurePlane.origin, normal)) < 1e-6 } ?? false
        }) else {
            status = "The face this was made on is gone, so it cannot be edited here."
            return false
        }
        cancelTransient()
        let middle = featurePlane.point(center)
        plane = featurePlane
        sketchMode = SketchMode(plane: featurePlane, face: FaceSelection(bodyID: bodyID, face: index, plane: featurePlane, center: middle))
        selection = nil
        tool = value
        requestCamera(.alignAt(featurePlane, middle))
        return true
    }

    /// After Done or Cancel on an edit: out of the tool and the face sketch, with the solid selected.
    private func finishFeatureEdit(_ bodyID: UUID, status text: String?) {
        endSketchMode()
        tool = .select
        selection = workspace.bodies.contains(where: { $0.id == bodyID }) ? .body(bodyID) : nil
        if let text { status = text }
    }

    /// Waits for a matching part being built (tests).
    func matingPartSettled() async {
        while isMakingMatingPart { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Fit Test

    /// Adds the Fit Test coupon beside the model as one undo step, selected and in view.
    func addFitTest() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        cancelTransient()
        endSketchMode()
        tool = .select
        let coupon = FitTest.coupon(at: FitTest.origin(beside: workspace))
        guard !coupon.isEmpty else { return }
        var next = workspace
        next.bodies.append(contentsOf: coupon)
        guard next.isValid else { return }
        commit(next)
        selection = .body(coupon[0].id)
        status = "Fit Test added"
        requestCamera(.reset)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The app's Fit preference: new pegs and Subtract clearances start from it.
    func setFitClearance(_ clearance: Double) {
        guard Fit.clearanceRange.contains(clearance) else { return }
        fitClearance = clearance
    }

    // MARK: Sketch Fillet, Trim, and Dimension

    /// Rounds the corner at `vertex` (where two lines of a sketch on the current plane meet) to the
    /// current corner radius, as one undo step; the radius can then be typed.
    func roundCorner(at vertex: Point2) {
        guard requireNewEditingAccess() else { return }
        guard tool == .cornerFillet, !isEditingBlocked else { return }
        let owners = visibleWorkspace.shapes.filter { shape in
            shape.plane == plane && (shape.kind == .line || shape.kind == .rectangle) &&
                SketchEditing.joints(of: shape).contains { $0.distance(to: vertex) < 1e-5 }
        }
        guard let sketch = owners.first?.sketch else { return }
        guard let result = SketchModify.roundCorner(at: vertex, radius: cornerRadius, sketch: sketch, in: workspace) else {
            status = "That corner cannot take a \(lengthText(cornerRadius)) round"
            return
        }
        let base = workspace
        dimensionEdit = nil
        commit(result.workspace)
        lastCorner = CornerRecord(base: base, vertex: vertex, sketch: sketch, radius: cornerRadius, arc: result.arc, result: workspace)
        status = "Rounded corner"
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The corner just rounded, while its radius can still be changed (nothing else happened since).
    var editableCorner: CornerRecord? {
        guard let record = lastCorner, record.result == workspace, tool == .cornerFillet else { return nil }
        return record
    }

    /// Changes the last rounded corner's radius, still as one undo step.
    private func amendCorner(_ radius: Double) -> Bool {
        guard var record = editableCorner,
              let result = SketchModify.roundCorner(at: record.vertex, radius: radius, sketch: record.sketch, in: record.base) else {
            dimensionError = "That radius does not fit the lines at this corner."
            return false
        }
        var updated = result.workspace
        updated.normalizeSketches()
        guard history.amend(updated) else {
            dimensionError = "That radius does not fit the lines at this corner."
            return false
        }
        save()
        record.radius = radius
        record.arc = result.arc
        record.result = workspace
        lastCorner = record
        cornerRadius = radius
        return true
    }

    /// Trim: the Pencil touched down. Every shape stretch it passes over is trimmed, as one undo step at lift.
    func beginTrim() {
        guard tool == .trim, !isEditingBlocked else { return }
        trimBase = workspace
        editPreview = workspace
    }

    /// Removes the stretch of a shape under the Pencil (between the shapes that cross it).
    func trim(_ shapeID: UUID, at point: Point2) {
        guard trimBase != nil, let current = editPreview, let next = SketchModify.trim(shapeID, at: point, in: current) else { return }
        editPreview = next
    }

    func finishTrim(cancelled: Bool) {
        guard let base = trimBase else { return }
        trimBase = nil
        let next = editPreview
        editPreview = nil
        guard !cancelled, let next, next != base else { return }
        commit(next)
        status = "Trimmed"
    }

    /// The Dimension tool: the first tap picks what to measure from, the second what moves; a tap
    /// after both starts again; a tap on nothing (nil) clears them.
    func pickDimensionReference(_ reference: SketchReference?) {
        guard tool == .dimension, var draft = dimensionDraft else { return }
        dimensionEdit = nil
        guard let reference else { dimensionDraft = DimensionDraft(); return }
        func same(_ a: SketchReference?, _ b: SketchReference) -> Bool {
            guard let a else { return false }
            return a.shapeID != nil ? a.shapeID == b.shapeID && a.part == b.part : a.kind == b.kind
        }
        if draft.first == nil { draft.first = reference }
        else if draft.second == nil { if same(draft.first, reference) { draft.first = nil } else { draft.second = reference } }
        else if same(draft.second, reference) { draft.second = nil }
        else { draft = DimensionDraft(first: reference) }
        dimensionDraft = draft
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The Dimension tool's picks as the shapes are now.
    var dimensionPicks: (first: SketchReference, second: SketchReference?)? {
        guard let draft = dimensionDraft, let first = draft.first?.resolved(in: displayWorkspace) else { return nil }
        return (first, draft.second?.resolved(in: displayWorkspace))
    }

    /// What the Dimension tool shows: one pick's own length and angle, or the distances or angle between two.
    var sketchDimensions: [SketchDimension] {
        guard let picks = dimensionPicks else { return [] }
        return SketchDimensions.dimensions(picks.first, picks.second, in: displayWorkspace)
    }

    /// The dimensions kept in the visible sketches on the plane being sketched on, as the shapes are
    /// now. With the Dimension tool, those it is showing for its picks are left out (it shows them).
    var keptDimensions: [(kept: KeptDimension, plane: SketchPlane, dimension: SketchDimension)] {
        guard let mode = sketchMode, !isExtruding else { return [] }
        let shown = visibleWorkspace
        let picked = dimensionDraft?.first.map { first in
            sketchDimensions.map { KeptDimension(kind: $0.kind, first: first, second: dimensionDraft?.second) }
        } ?? []
        var result: [(kept: KeptDimension, plane: SketchPlane, dimension: SketchDimension)] = []
        for sketch in shown.sketches where sketch.plane == mode.plane {
            for kept in sketch.dimensions ?? [] where !picked.contains(where: kept.isSame) {
                if let dimension = shown.measure(kept, in: sketch) { result.append((kept, sketch.plane, dimension)) }
            }
        }
        return result
    }

    /// Removes a kept dimension from its sketch; the shapes stay as they are.
    func removeKeptDimension(_ id: UUID) {
        guard requireNewEditingAccess() else { return }
        dimensionEdit = nil
        guard !isEditingBlocked, let next = workspace.removingKeptDimension(id) else { return }
        commit(next)
        status = "Dimension removed"
    }

    // MARK: Measure

    var isMeasuring: Bool { tool == .measure }

    /// Measure: pick one item for its sizes, two for the distance and angle
    /// between them. A selected solid, face, edge, or sketch shape is the first item.
    func beginMeasure() {
        guard !isViewingBlocked else { return }
        var first: MeasureItem?
        switch selection {
        case .body(let id): first = .body(id)
        case .face(let face): first = .face(bodyID: face.bodyID, face: face.face)
        case .edge(let id, let edge): first = .edge(bodyID: id, edge: edge.index)
        case .shape(let id): first = .shape(id)
        default: break
        }
        cancelTransient()
        selection = nil
        tool = .measure
        measureItems = first.map { [$0] } ?? []
    }

    /// Adds an item (or removes it when picked again); a third item starts over. Nil clears.
    func pickMeasureItem(_ item: MeasureItem?) {
        guard tool == .measure else { return }
        guard let item else { measureItems = []; return }
        if let index = measureItems.firstIndex(of: item) { measureItems.remove(at: index) }
        else if measureItems.count >= 2 { measureItems = [item] }
        else { measureItems.append(item) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func endMeasure() {
        measureItems = []
        if tool == .measure { tool = .select }
    }

    /// One item's sizes, or the distance and angle between two, and the nearest points between them.
    /// Kept until the picks or the model change: the canvas and the results bar ask every frame,
    /// and a distance between detailed solids takes the kernel a while.
    var measurements: (values: [Measurement], from: SIMD3<Double>?, to: SIMD3<Double>?) {
        if let cache = measurementCache, cache.items == measureItems, cache.workspace == workspace { return cache.result }
        let shown = workspace.visible
        var result: (values: [Measurement], from: SIMD3<Double>?, to: SIMD3<Double>?) = ([], nil, nil)
        switch measureItems.count {
        case 1: result = (Measuring.properties(of: measureItems[0], in: shown), nil, nil)
        case 2:
            if let between = Measuring.between(measureItems[0], measureItems[1], in: shown) { result = (between.values, between.from, between.to) }
        default: break
        }
        measurementCache = (measureItems, workspace, result)
        return result
    }
    @ObservationIgnored private var measurementCache: (items: [MeasureItem], workspace: Workspace, result: (values: [Measurement], from: SIMD3<Double>?, to: SIMD3<Double>?))?

    /// A measured value as the user reads it, in the chosen unit.
    func measureText(_ measurement: Measurement) -> String {
        let unit = lengthUnit, power = measurement.kind.power
        guard power > 0 else { return formatted(measurement.value) + "°" }
        let scale = pow(unit.millimeters, Double(power))
        let digits = unit.fractionDigits + (power > 1 && unit == .inches ? 1 : 0)
        let number = (measurement.value / scale).formatted(.number.grouping(.never).precision(.fractionLength(0...digits)))
        return number + " " + unit.symbol + (power == 2 ? "²" : power == 3 ? "³" : "")
    }

    /// The size the selection strip shows beside a selected edge, face, or solid.
    var selectionMeasure: String? {
        selectionFact("measure \(lengthUnit)") { () -> String? in selectionMeasureNow }
    }
    private var selectionMeasureNow: String? {
        let item: MeasureItem
        switch selection {
        case .edge(let id, let edge): item = .edge(bodyID: id, edge: edge.index)
        case .face(let face): item = .face(bodyID: face.bodyID, face: face.face)
        case .body(let id): item = .body(id)
        default: return nil
        }
        let wanted: [Measurement.Kind] = [.diameter, .length, .area, .volume]
        let values = Measuring.properties(of: item, in: workspace)
        return wanted.lazy.compactMap { kind in values.first { $0.kind == kind } }.first.map {
            ($0.kind == .diameter ? "Ø " : "") + measureText($0)
        }
    }

    // MARK: Fillet and chamfer

    /// Adds or removes an edge from the draft: any edge of the solid, including ones made by cuts,
    /// joins, holes, unions, shells, and earlier fillets. Picking an edge of another solid starts over there.
    func toggleFinishEdge(bodyID: UUID, edge: PickedEdge) {
        guard let kind = tool.finishKind, !isEditingBlocked, workspace.bodies.contains(where: { $0.id == bodyID }) else { return }
        dimensionEdit = nil
        var draft = finishDraft?.bodyID == bodyID ? finishDraft! : FinishDraft(bodyID: bodyID, kind: kind, edges: [], size: lastFinishSize[kind] ?? kind.defaultSize)
        if let index = draft.edges.firstIndex(where: { $0.index == edge.index }) { draft.edges.remove(at: index) } else { draft.edges.append(edge) }
        if draft.edges.isEmpty { clearFinishDraft(); return }
        finishDraft = draft
        selection = nil
        UISelectionFeedbackGenerator().selectionChanged()
        updateFinishPreview()
    }

    /// Live size change (drag). The preview keeps the last size that fits; Done needs a fitting size.
    /// `now`: built at once, so whether it fits is known (a typed value).
    func setFinishSize(_ size: Double, now: Bool = false) {
        guard var draft = finishDraft, size.isFinite else { return }
        let size = min(EdgeFinish.sizeRange.upperBound, max(EdgeFinish.sizeRange.lowerBound, size))
        guard size != draft.size else { if now { finishPreviews.settle { finishPreviewRequest() } }; return }
        draft.size = size
        finishDraft = draft
        updateFinishPreview(now: now)
    }

    func confirmFinish() {
        finishPreviews.settle { finishPreviewRequest() }
        guard let draft = finishDraft, finishError == nil, let preview = finishPreview, !isEditingBlocked else { return }
        lastFinishSize[draft.kind] = draft.size
        commit(preview)
        clearFinishDraft()
        selection = .body(draft.bodyID)
        tool = .select
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancelFinish() { clearFinishDraft(); dimensionEdit = nil; tool = .select }

    private func clearFinishDraft() { finishPreviews.drop(); finishDraft = nil; finishPreview = nil; finishError = nil }

    /// Rebuilds the draft body through the kernel, off the main thread on screen unless `now`. On
    /// failure the last fitting preview stays visible.
    private func updateFinishPreview(now: Bool = false) {
        guard let request = finishPreviewRequest() else { return }
        finishPreviews.submit(request, inBackground: buildsPreviewsInBackground && !now)
    }

    private func finishPreviewRequest() -> FinishPreviewRequest? {
        guard let draft = finishDraft, workspace.bodies.contains(where: { $0.id == draft.bodyID }) else { return nil }
        return FinishPreviewRequest(base: workspace, draft: draft)
    }

    /// The draft it was built for, and the finished solid (nil when the size does not fit); on any thread.
    nonisolated private static func buildFinishPreview(_ request: FinishPreviewRequest) -> (FinishDraft, SolidBody?) {
        let performance = Performance.begin("Finish preview")
        defer { Performance.end(performance) }
        let draft = request.draft
        guard let body = request.base.bodies.first(where: { $0.id == draft.bodyID }),
              let finished = body.finishing(draft.kind, edges: draft.edges.map(\.index), size: draft.size, knownValid: true) else { return (draft, nil) }
        meshForDisplay([finished])
        return (draft, finished)
    }

    /// A result describes the draft it was built for, which may be older than the current one.
    private func applyFinishPreview(_ output: (FinishDraft, SolidBody?)) {
        let (draft, finished) = output
        guard finishDraft?.bodyID == draft.bodyID, let index = workspace.bodies.firstIndex(where: { $0.id == draft.bodyID }) else { return }
        if let finished {
            var next = workspace
            next.bodies[index] = finished
            finishPreview = next
            finishError = nil
            lastFinishPreviewEdges = draft.edges
            return
        }
        finishError = "\(lengthText(draft.size)) is too large for the selected edges."
        // Keep the last preview that fit, unless it was for other edges.
        if lastFinishPreviewEdges != draft.edges { finishPreview = nil }
    }

    /// Waits for the background Fillet or Chamfer preview (tests).
    func finishPreviewSettled() async { await finishPreviews.settled() }

    func updateDimensions(first: Double, second: Double?) {
        guard requireNewEditingAccess() else { return }
        guard var shape = selectedShape else { return }
        switch shape.kind {
        case .line: guard let updated = SketchEditing.dimension(.length, value: first, of: shape) else { return }; shape = updated
        case .circle: guard let updated = SketchEditing.dimension(.diameter, value: first, of: shape) else { return }; shape = updated
        case .rectangle:
            guard let second, let wide = SketchEditing.dimension(.width, value: first, of: shape),
                  let tall = SketchEditing.dimension(.height, value: second, of: wide) else { return }
            shape = tall
        case .slot:
            guard let second, let long = SketchEditing.dimension(.length, value: first, of: shape),
                  let wide = SketchEditing.dimension(.width, value: second, of: long) else { return }
            shape = wide
        case .arc: guard let updated = SketchEditing.dimension(.radius, value: first, of: shape) else { return }; shape = updated
        case .ellipse:
            guard let second, let wide = SketchEditing.dimension(.width, value: first, of: shape),
                  let tall = SketchEditing.dimension(.height, value: second, of: wide) else { return }
            shape = tall
        case .curve, .point: return
        }
        if let next = SketchEditing.replacing(shape, in: workspace) { commit(next) }
    }

    func dimensionValue(_ target: DimensionTarget) -> Double? {
        switch target {
        case .shape(let id, let dimension): return displayWorkspace.shapes.first { $0.id == id }.map { dimension.value(of: $0) }
        case .bodyDepth(let id): return displayWorkspace.bodies.first { $0.id == id }?.depth
        case .extrusion: return isExtruding ? extrusionValue : nil
        case .finishSize: return finishDraft?.size
        case .shellThickness: return shellDraft?.thickness
        case .holeDiameter: return holeDraft?.spec.diameter
        case .holeDepth: return holeDraft.map { $0.depth ?? 0 }
        case .textHeight: return textDraft?.height
        case .textDepth: return textDraft.map { abs($0.depth) }
        case .threadDiameter: return threadDraft?.spec.majorDiameter
        case .threadPitch: return threadDraft?.spec.pitch
        case .threadLength: return threadDraft?.threadedLength
        case .pegDiameter: return pegDraft?.spec.diameter
        case .pegHeight: return pegDraft?.spec.height
        case .pegEmbed: return pegDraft?.spec.separate == true ? pegDraft?.spec.embed : nil
        case .clearance: return pegDraft?.spec.clearance ?? subtractDraft?.clearance
        case .fitClearance: return fitClearance
        case .transformDistance, .transformAngle:
            guard let record = transformDrag ?? editableTransform, record.dimensionTarget == target else { return nil }
            return record.amount
        case .planeOffset: return tool == .offsetPlane && planePreview != nil ? planeDraft?.offset : nil
        case .constructionAngle: return tool == .planeAngle && constructionDraft?.line != nil ? constructionDraft?.angle : nil
        case .draftAngle: return tool == .draft && shapeToolDraft?.faces.isEmpty == false ? shapeToolDraft?.angle : nil
        case .ribThickness: return tool == .rib && shapeToolDraft?.line != nil ? shapeToolDraft?.thickness : nil
        case .alignOffset: return alignPreview != nil ? alignDraft?.offset : nil
        case .alignAngle: return alignPreview != nil ? alignDraft?.angle : nil
        case .revolveAngle: return revolveDraft?.axis != nil ? revolveDraft?.angle : nil
        case .bodyAngle(let id): return displayWorkspace.bodies.first { $0.id == id }?.revolve?.angle
        case .cornerRadius: return editableCorner?.radius
        case .patternDistance(let axis): return patternDraft?.spec.directions[axis].distance
        case .patternAngle: return patternDraft.map { $0.spec.angle }
        case .patternCount: return patternDraft.map { Double($0.count) }
        case .scalePercent(let axis): return scaleDraft.map { axis == 3 || $0.uniform ? $0.percents.x : $0.percents[axis] }
        case .extrusionTaper: return isExtruding && faceExtrusion == nil ? extrusionTaper : nil
        case .sectionOffset: return section?.offset
        case .polygonSides: return editablePolygon.map { Double($0.sides) }
        case .polygonRadius: return editablePolygon?.radius
        case .offsetDistance: return offsetDraft?.distance
        case .faceDiameter: if case .diameter(let value, _) = selectedFaceSize { return value } else { return nil }
        case .faceDistance: if case .distance(let value, _) = selectedFaceSize { return value } else { return nil }
        case .selectedFinish(let kind): return selectedFinish.flatMap { $0.kind == kind ? $0.size : nil }
        case .primitiveSize(let kind, let index): return primitiveDraft.flatMap { $0.kind == kind && $0.sizes.indices.contains(index) ? $0.sizes[index] : nil }
        case .relation(let index, _):
            let dimensions = sketchDimensions
            return dimensions.indices.contains(index) ? dimensions[index].value : nil
        case .kept(let id, _):
            return displayWorkspace.keptDimension(id).flatMap { displayWorkspace.measure($0.kept, in: $0.sketch) }?.value
        }
    }

    func openDimension(_ target: DimensionTarget, at anchor: CGPoint) {
        guard canEditDimension(target) else {
            if !hasEditingAccess { showPurchaseOffer = true }
            return
        }
        guard let value = dimensionValue(target), dragContext == nil else { return }
        dimensionError = nil
        preview = nil
        dimensionEdit = DimensionEdit(target: target, value: value, anchor: anchor)
    }

    @discardableResult func applyDimension(_ value: Double, target: DimensionTarget) -> Bool {
        dimensionError = nil
        guard canEditDimension(target) else { return false }
        // Offsets and angles may be exactly 0; other values are lengths.
        guard value.isFinite, abs(value) >= 0.01 || target.allowsZero, abs(value) <= 10_000,
              target.allowsNegative || value > 0 || target.allowsZero && value == 0 else { return false }
        switch target {
        case .shape(let id, let dimension):
            guard let shape = workspace.shapes.first(where: { $0.id == id }),
                  let updated = SketchEditing.dimension(dimension, value: value, of: shape),
                  let next = SketchEditing.replacing(updated, in: workspace) else { return false }
            commit(next)
            // The next slot is drawn this wide too.
            if shape.kind == .slot && dimension == .width { slotWidth = value }
        case .cornerRadius:
            guard amendCorner(value) else { return false }
        case .relation(let index, let angle):
            let dimensions = sketchDimensions
            guard let picks = dimensionPicks, dimensions.indices.contains(index), dimensions[index].editable else { return false }
            guard !angle || value <= 180 else { dimensionError = "Enter an angle from 0° to 180°."; return false }
            guard let next = SketchDimensions.applying(dimensions[index].kind, value: value, picks.first, picks.second, in: workspace) else {
                dimensionError = "That value would collapse or break the sketch."
                return false
            }
            // Kept in the sketch, to show and type again later; in the same undo step.
            let kept = KeptDimension(kind: dimensions[index].kind, first: picks.first, second: picks.second)
            commit(next.keeping(kept)?.workspace ?? next)
        case .kept(let id, let angle):
            guard let found = workspace.keptDimension(id), let picks = workspace.picks(of: found.kept, in: found.sketch) else { return false }
            guard !angle || value <= 180 else { dimensionError = "Enter an angle from 0° to 180°."; return false }
            guard let next = SketchDimensions.applying(found.kept.kind, value: value, picks.first, picks.second, in: workspace) else {
                dimensionError = "That value would collapse or break the sketch."
                return false
            }
            commit(next)
        case .bodyDepth(let id):
            guard let index = workspace.bodies.firstIndex(where: { $0.id == id && !$0.isImported }) else { return false }
            return applyBuilt("Changing the depth…", build: { base in
                var next = base
                next.bodies[index].depth = value
                guard next.isValid(changedFrom: base) else { return .failure(DimensionRefusal()) }
                // A new depth replays the whole history.
                if !next.bodies[index].finishes.isEmpty || !next.bodies[index].cuts.isEmpty,
                   (try? SolidKernel.solid(for: next.bodies[index])) == nil {
                    return .failure(DimensionRefusal(message: "Its fillets, chamfers, or cuts do not fit at this depth."))
                }
                return .success((next, ()))
            }, then: { (_: ModelingSession, _: Void) in })
        case .extrusion:
            guard isExtruding else { return false }
            if let base = extrusionSizeBase {
                guard value > 0 else { dimensionError = "Enter the size the solid should be."; return false }
                extrusionDepth = value - base
            } else {
                extrusionDepth = value
            }
        case .finishSize:
            guard let previous = finishDraft?.size else { return false }
            setFinishSize(value, now: true)
            guard finishError == nil else {
                dimensionError = finishError
                setFinishSize(previous, now: true)
                return false
            }
        case .shellThickness:
            guard let previous = shellDraft?.thickness else { return false }
            setShellThickness(value, now: true)
            guard draftError == nil else { dimensionError = draftError; setShellThickness(previous, now: true); return false }
        case .holeDiameter, .holeDepth:
            guard let previous = holeDraft else { return false }
            var draft = previous
            if target == .holeDiameter {
                draft.spec.diameter = value
                // Keep counterbore and countersink at least as wide as the hole.
                draft.spec.counterboreDiameter = max(draft.spec.counterboreDiameter, value + 0.2)
                draft.spec.countersinkDiameter = max(draft.spec.countersinkDiameter, value + 0.2)
            } else { draft.depth = value }
            updateHole(draft)
            guard draftError == nil else { dimensionError = draftError; updateHole(previous); return false }
        case .textHeight, .textDepth:
            guard var draft = textDraft else { return false }
            if target == .textHeight {
                guard TextSpec.heightRange.contains(value) else { dimensionError = "Enter a height from 0.5 to 500 mm."; return false }
                draft.height = value
            } else {
                guard value <= 100 else { dimensionError = "Enter a depth up to 100 mm."; return false }
                draft.depth = draft.depth > 0 ? value : -value
            }
            updateText(draft)
        case .threadDiameter, .threadPitch:
            guard var draft = threadDraft else { return false }
            let previous = draft.spec
            // A typed value makes it a custom thread, unless it lands on a standard size.
            if target == .threadDiameter {
                draft.spec = previous.with(size: nil, diameter: value, pitch: previous.pitch)
            } else {
                draft.spec = previous.with(pitch: value)
            }
            guard draft.spec.isValid else {
                if target == .threadPitch {
                    dimensionError = "Enter a pitch from \(lengthText(0.2)) to \(lengthText(max(0.2, previous.largestPitch))) for this diameter."
                } else {
                    dimensionError = "Enter a diameter from \(lengthText(1)) to \(lengthText(500)) that this pitch can cut."
                }
                return false
            }
            guard draft.spec.fit.isUsable else {
                if target == .threadDiameter, let range = draft.spec.reachableDiameters {
                    let face = lengthText(draft.spec.surfaceDiameter)
                    if draft.spec.isRaised {
                        dimensionError = draft.spec.isInternal ? "Too big to raise inside this \(face) hole. Enter \(lengthText(range.upperBound)) or less."
                            : "Too small to raise on this \(face) boss. Enter \(lengthText(range.lowerBound)) or more."
                    } else {
                        dimensionError = draft.spec.isInternal ? "Too small to reach this \(face) hole. Enter more than \(lengthText(range.lowerBound))."
                            : "Too big to reach this \(face) boss. Enter less than \(lengthText(range.upperBound))."
                    }
                } else {
                    dimensionError = draft.spec.fitSummary(lengthText)
                }
                return false
            }
            updateThread(draft)
        case .threadLength:
            guard var draft = threadDraft else { return false }
            let full = draft.spec.threadedLength
            guard value >= draft.spec.shortestLength - 1e-9, value <= full + 1e-6 else {
                dimensionError = "Enter a length from \(lengthText(draft.spec.shortestLength)) (one turn) to \(lengthText(full)) (the whole face)."
                return false
            }
            draft.length = value < full - 1e-6 ? value : nil
            updateThread(draft)
        case .pegDiameter, .pegHeight, .pegEmbed:
            guard let previous = pegDraft else { return false }
            var draft = previous
            switch target {
            case .pegDiameter: draft.spec.diameter = value
            case .pegHeight: draft.spec.height = value
            default: draft.spec.embed = value
            }
            guard draft.spec.isValid else {
                dimensionError = target == .pegDiameter ? "Enter a diameter from 1 to 50 mm." :
                    target == .pegHeight ? "Enter a height from 0.5 to 100 mm." : "Enter a depth from 0 to 100 mm."
                return false
            }
            updatePeg(draft)
            guard draftError == nil else { dimensionError = draftError; updatePeg(previous); return false }
        case .clearance, .fitClearance:
            guard Fit.clearanceRange.contains(value) else { dimensionError = "Enter a clearance from 0.01 to 2 mm."; return false }
            if target == .fitClearance { setFitClearance(value) }
            else if pegDraft != nil { setPegClearance(value) }
            else if subtractDraft != nil { setSubtractClearance(value) }
            else { return false }
        case .transformDistance, .transformAngle:
            // A distance cannot change a turn, nor an angle a move.
            guard lastTransform?.dimensionTarget == target, amendLastTransform(value) else { return false }
        case .planeOffset:
            guard tool == .offsetPlane, planeDraft?.references.isEmpty == false else { return false }
            setPlaneOffset(value)
        case .draftAngle:
            guard tool == .draft, let previous = shapeToolDraft else { return false }
            guard DraftSpec.angleRange.contains(abs(value)) else { dimensionError = "Enter an angle from 0.01° to 60° (negative leans outward)."; return false }
            var draft = previous
            draft.angle = value
            updateShapeTool(draft)
            guard shapeToolPreview != nil else {
                // The angle is refused; the last one that built stays, with its preview.
                dimensionError = shapeToolDraft?.error ?? "Those faces cannot lean that far."
                updateShapeTool(previous)
                return false
            }
        case .ribThickness:
            guard tool == .rib, var draft = shapeToolDraft else { return false }
            guard RibSpec.thicknessRange.contains(value) else { dimensionError = "Enter a thickness from \(lengthText(0.1)) to \(lengthText(100))."; return false }
            draft.thickness = value
            updateShapeTool(draft)
        case .constructionAngle:
            guard tool == .planeAngle, let previous = constructionDraft, previous.line != nil else { return false }
            guard abs(value) <= 360 else { dimensionError = "Enter an angle from −360° to 360°."; return false }
            var draft = previous
            draft.angle = value
            updateConstruction(draft)
            guard constructionPreview != nil else { dimensionError = "That plane cannot be made."; updateConstruction(previous); return false }
        case .alignOffset, .alignAngle:
            guard alignPreview != nil, let previous = alignDraft else { return false }
            if target == .alignOffset { setAlignOffset(value) } else { setAlignAngle(value) }
            guard alignPreview != nil else {
                // Keep the last value that fit, as the other operations do.
                dimensionError = alignError
                alignDraft = previous; updateAlignPreview()
                return false
            }
        case .revolveAngle:
            guard revolveDraft?.axis != nil else { return false }
            guard RevolveSpec.angleRange.contains(abs(value)) else { dimensionError = "Enter an angle from 0.1° to 360°."; return false }
            setRevolveAngle(value)
        case .patternDistance(let axis):
            guard let draft = patternDraft else { return false }
            setPatternDistance(value, axis: axis)
            guard patternDraft?.spec.directions[axis].distance == value else {
                dimensionError = "That makes more than \(PatternSpec.maximumInstances) copies."
                patternDraft = draft; updatePatternPreview()
                return false
            }
        case .patternAngle:
            guard let draft = patternDraft else { return false }
            guard draft.spec.definition == .spacing || abs(value) <= 360 else { dimensionError = "Enter a total angle up to 360°."; return false }
            setPatternAngle(value, axis: draft.circularAxis)
        case .patternCount:
            guard patternDraft != nil else { return false }
            guard value == value.rounded(), PatternSpec.countRange.contains(Int(value)) else {
                dimensionError = "Enter a whole number from 2 to \(PatternSpec.maximumInstances)."
                return false
            }
            guard setPatternCount(Int(value)) else { dimensionError = "That makes more than \(PatternSpec.maximumInstances) copies."; return false }
        case .sectionOffset:
            guard section != nil else { return false }
            setSectionOffset(value)
        case .polygonSides:
            guard value == value.rounded(), SketchTools.polygonSides.contains(Int(value)) else {
                dimensionError = "Enter a whole number of sides from 3 to 64."
                return false
            }
            guard amendPolygon(sides: Int(value)) else { return false }
        case .polygonRadius:
            guard editablePolygon != nil else { return false }
            guard amendPolygon(radius: value) else { dimensionError = "The polygon cannot be that size."; return false }
        case .offsetDistance:
            guard offsetDraft != nil, setOffsetDistance(value) else { dimensionError = "The outline cannot be offset that far."; return false }
        case .extrusionTaper:
            guard setExtrusionTaper(value) else { dimensionError = "Enter a taper from −88° to 88°."; return false }
        case .faceDiameter, .faceDistance:
            // Accepted here; the validated result commits later, without blocking input.
            return beginFaceDimension(value)
        case .selectedFinish(let kind):
            guard let finish = selectedFinish, let face = selectedFace, let index = workspace.bodies.firstIndex(where: { $0.id == finish.bodyID }) else { return false }
            guard EdgeFinish.sizeRange.contains(value) else { dimensionError = "Enter a size from 0.01 to 1000 mm."; return false }
            let body = workspace.bodies[index], source = finish.source, point = face.point ?? face.center, size = lengthText(value)
            return applyBuilt("Resizing the \(kind.rawValue)…", build: { base in
                // Replays every step from the finish on.
                guard let resized = body.resizingFinish(source, to: value) else {
                    return .failure(DimensionRefusal(message: "A \(size) \(kind.rawValue) does not fit these edges. Try a smaller size."))
                }
                var next = base
                next.bodies[index] = resized
                return .success((next, Self.finishFacePoint(of: resized, source: source, near: point)))
            }, then: { (session: ModelingSession, moved: SIMD3<Double>?) in
                // The rounded face moves with its size: keep it selected where it went, still known as
                // this finish's (looking again would rebuild the solid without it).
                let resized = session.workspace.bodies[index]
                let selection = moved.flatMap { session.faceSelection(bodyID: body.id, near: $0) }
                if let selection { session.finishCache = (SolidCache.key(resized), selection.point ?? selection.center, source) }
                session.selection = selection.map { .face($0) } ?? .body(body.id)
                session.status = "\(kind.title) changed to \(size)"
            })
        case .primitiveSize(let kind, let index):
            guard var draft = primitiveDraft, draft.kind == kind, draft.sizes.indices.contains(index) else { return false }
            guard Primitives.sizeRange.contains(value) else { dimensionError = "Enter a size from \(lengthText(0.1)) to \(lengthText(10_000))."; return false }
            draft.sizes[index] = value
            guard Primitives.body(kind, sizes: draft.sizes, on: draft.plane, at: draft.center) != nil else {
                dimensionError = "The tube must be thinner than the torus's diameter."
                return false
            }
            updatePrimitive(draft)
        case .scalePercent(let axis):
            guard scaleDraft != nil else { return false }
            guard (0.1...10_000).contains(value) else { dimensionError = "Enter a percentage from 0.1 to 10000."; return false }
            guard setScalePercent(value, axis: axis) else { dimensionError = scaleError ?? "That cannot be scaled."; return false }
        case .bodyAngle(let id):
            guard let index = workspace.bodies.firstIndex(where: { $0.id == id }), workspace.bodies[index].revolve != nil else { return false }
            guard RevolveSpec.angleRange.contains(abs(value)) else { dimensionError = "Enter an angle from 0.1° to 360°."; return false }
            return applyBuilt("Changing the angle…", build: { base in
                var next = base
                next.bodies[index].revolve?.angle = value
                // A new angle replays the whole history.
                guard next.isValid(changedFrom: base), (try? SolidKernel.solid(for: next.bodies[index])) != nil else {
                    return .failure(DimensionRefusal(message: "Its fillets, chamfers, or cuts do not fit at this angle."))
                }
                return .success((next, ()))
            }, then: { (_: ModelingSession, _: Void) in })
        }
        dimensionEdit = nil
        if !editingOperationPending { canFinishAuthorizedEdit = false }
        return true
    }

    /// Face offsets may intersect hundreds of faces. Keep the unchanged model visible while
    /// the kernel works, and discard results if the keypad, selection, or document changed.
    private func beginFaceDimension(_ value: Double) -> Bool {
        guard let face = selectedFace, let index = workspace.bodies.firstIndex(where: { $0.id == face.bodyID }) else { return false }
        let base = workspace, body = base.bodies[index], editID = dimensionEdit?.id
        isResizingDimension = true
        resizingProgress = "Resizing face…"
        status = "Resizing face…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (SolidBody, SIMD3<Double>)? in
                let point = face.point ?? face.center
                guard let solid = try? SolidKernel.solid(for: body),
                      let size = FaceEditing.size(of: face.face, on: solid, at: point),
                      let resized = FaceEditing.resizing(body, face: face.face, at: point, to: value) else { return nil }
                var moved = point
                switch size {
                case .diameter(let old, _):
                    if let cylinder = solid.faceCylinder(face.face) {
                        let axis = simd_normalize(cylinder.direction), d = point - cylinder.point
                        let radial = d - axis * simd_dot(d, axis)
                        if simd_length(radial) > 1e-9 { moved += simd_normalize(radial) * (value - old) / 2 }
                    }
                case .distance(let old, _):
                    if let plane = solid.facePlane(face.face) { moved += plane.normal * (value - old) }
                }
                return (resized, moved)
            }.value
            guard let self else { return }
            self.isResizingDimension = false
            guard self.workspace == base, self.selectedFace == face,
                  self.dimensionEdit?.id == editID, !self.isEditingBlocked else {
                self.status = "Resize cancelled"
                return
            }
            guard let (resized, moved) = result else {
                self.dimensionError = "That size could not be built. Try a smaller change or edit the sketch."
                self.status = "Face not resized"
                return
            }
            var next = base
            next.bodies[index] = resized
            self.commit(next)
            self.selection = self.faceSelection(bodyID: face.bodyID, near: moved).map { .face($0) } ?? .body(face.bodyID)
            self.dimensionEdit = nil
            self.status = "Resized"
        }
        return true
    }

    /// Waits for a face dimension to finish (tests).
    func dimensionResizeSettled() async {
        while isResizingDimension { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Applies a typed value whose result needs a solid built again from its steps (a fillet's
    /// size, a solid's depth or angle): `build` makes the next model from this one, or refuses the
    /// value, and `then` runs once it is committed. On screen it builds off the main thread, the
    /// keypad showing `progress` and editing waiting, and the result is kept only if nothing changed
    /// meanwhile: building a detailed solid again stopped the app for seconds (November 11, 2026).
    /// Returns whether the value was applied, or, off the main thread, accepted.
    private func applyBuilt<Extra: Sendable>(_ progress: String,
                                             build: @escaping @Sendable (Workspace) -> Result<(Workspace, Extra), DimensionRefusal>,
                                             then: @escaping @MainActor (ModelingSession, Extra) -> Void) -> Bool {
        let base = workspace
        let finish: @MainActor (ModelingSession, Result<(Workspace, Extra), DimensionRefusal>) -> Bool = { session, result in
            switch result {
            case .failure(let refusal):
                session.dimensionError = refusal.message
                return false
            case .success(let (next, extra)):
                session.commit(next)
                then(session, extra)
                session.dimensionEdit = nil
                if !session.editingOperationPending { session.canFinishAuthorizedEdit = false }
                return true
            }
        }
        guard buildsPreviewsInBackground else { return finish(self, build(base)) }
        let editID = dimensionEdit?.id, selected = selection
        isResizingDimension = true
        resizingProgress = progress
        status = progress
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { build(base) }.value
            guard let self else { return }
            self.isResizingDimension = false
            guard self.workspace == base, self.selection == selected, self.dimensionEdit?.id == editID, !self.isEditingBlocked else {
                self.status = "Change cancelled"
                return
            }
            if case .failure(let refusal) = result, refusal.message == nil {
                self.dimensionError = "That value does not fit this solid."
            } else if !finish(self, result) {
                self.status = "Not changed"
            }
        }
        return true
    }

    func beginSketchDrag(shapeID: UUID, handle: SketchHandle) {
        guard requireNewEditingAccess() && !isEditingBlocked else { return }
        guard !isExtruding, let shape = workspace.shapes.first(where: { $0.id == shapeID }) else { return }
        dimensionEdit = nil
        preview = nil
        selection = .shape(shapeID)
        dragContext = (workspace, shape, handle)
    }

    @discardableResult func updateSketchDrag(to point: Point2) -> Bool {
        guard let context = dragContext,
              let updated = SketchEditing.dragging(context.shape, handle: context.handle, to: point),
              let next = SketchEditing.replacing(updated, in: context.original) else { return false }
        editPreview = next
        return true
    }

    func finishSketchDrag(cancelled: Bool) {
        let next = editPreview
        editPreview = nil
        dragContext = nil
        snapLabel = ""
        if !cancelled, let next { commit(next) }
    }

    /// Whether the selection is a whole item Delete can remove (not a face or edge of a solid, nor a
    /// group, whose menu says whether its contents go too).
    var canDeleteSelection: Bool {
        switch selection {
        case .face, .edge, .group, nil: false
        default: true
        }
    }

    /// A row's Delete: that item alone, whatever else is selected.
    func deleteItem(_ item: ModelSelection) {
        guard canChangeRows else { return }
        cancelTransient()
        selection = item
        extraSelection = []
        deleteSelection()
    }

    func deleteSelection() {
        guard requireNewEditingAccess() else { return }
        guard !isEditingBlocked else { return }
        var next = workspace
        // Several picked sketch items go together, as one step.
        for item in extraSelection {
            switch item {
            case .sketch(let id): next.shapes.removeAll { $0.sketch == id }
            case .shape, .profile:
                let ids = Set(profile(for: item)?.sourceIDs ?? [])
                next.shapes.removeAll { ids.contains($0.id) }
            case .body(let id): next.bodies.removeAll { $0.id == id }
            default: break
            }
        }
        switch selection {
        case .shape(let id): next.shapes.removeAll { $0.id == id }
        case .profile(let id):
            // The region may be in any sketch, not only one on the current plane.
            let region = workspace.sketches.lazy.flatMap { self.workspace.profiles(in: $0) }.first { $0.id == id }
            let ids = Set(region?.sourceIDs ?? [])
            next.shapes.removeAll { ids.contains($0.id) }
        case .body(let id): next.bodies.removeAll { $0.id == id }
        case .sketch(let id): next.shapes.removeAll { $0.sketch == id }
        case .chain(let ids): next.shapes.removeAll { ids.contains($0.id) }
        case .plane(let id): next.constructionPlanes.removeAll { $0.id == id }
        // A face or edge is part of a solid, not an item of its own: Delete never takes the whole
        // solid with it (someone removing a fillet would lose the part). Double-tap selects the solid.
        case .face, .edge, .group, nil: return
        }
        cancelTransient()
        // Deleting the sketch being drawn in ends sketch mode; deleting its last shape keeps its plane.
        if let sketch = sketchMode?.sketchID, ([selection].compactMap { $0 } + extraSelection).contains(.sketch(sketch)) { endSketchMode(); tool = .select }
        selection = nil
        commit(next)
        revalidateSketchMode()
    }

    // MARK: Assistant

    var isReviewingAssistant: Bool { assistantPreview != nil }
    /// The assistant has a request running or changes under review; the project must not close under it.
    var isAssistantBusy: Bool { isAssistantWorking || isReviewingAssistant }

    /// Ends the assistant's request and review without keeping anything (the file was reloaded).
    func resetAssistant() {
        assistantPreview = nil
        assistantFocus = nil
        assistantEpoch += 1
        onAssistantReset?()
    }
    /// What the assistant builds on: its own pending changes, or the document.
    var assistantBase: Workspace { assistantPreview ?? workspace }
    /// The selection, in the assistant's terms ("the selected face").
    var assistantSelection: AssistantSelection? { Self.assistantSelection(for: selectedItems) }
    /// Several picked sketch items are `.several`.
    static func assistantSelection(for items: [ModelSelection]) -> AssistantSelection? {
        items.count > 1 ? .several(items.compactMap { assistantSelection(for: $0) }) : assistantSelection(for: items.first)
    }
    static func assistantSelection(for selection: ModelSelection?) -> AssistantSelection? {
        switch selection {
        case .body(let id): .body(id)
        case .face(let face): .face(bodyID: face.bodyID, face: face.face)
        case .edge(let body, let edge): .edge(bodyID: body, edge: edge.index)
        case .sketch(let id): .sketch(id)
        case .shape(let id): .shape(id)
        case .chain(let ids): .several(ids.map { .shape($0) })
        case .plane(let id): .plane(id)
        case .profile(let id): .profile(id)
        case .group, nil: nil
        }
    }

    /// Shows the assistant's changes on the canvas for review. Tools and drafts end first. A draft
    /// that is not a valid model is not shown, and what was under review stays (returns false).
    @discardableResult func showAssistantPreview(_ preview: Workspace, focus: AssistantItem?, authorizedBeforeExpiration: Bool = false) -> Bool {
        guard hasEditingAccess || authorizedBeforeExpiration else { return false }
        var preview = preview
        preview.normalizeSketches()
        preview.pruneImportedShapes()
        // The model is valid, so only the solids the assistant changed are checked again.
        guard preview.isValid(changedFrom: workspace) else { return false }
        cancelTransient()
        if authorizedBeforeExpiration && !hasEditingAccess { canFinishAuthorizedEdit = true }
        dimensionEdit = nil
        if sketchMode != nil { endSketchMode() }
        tool = .select
        selection = nil
        assistantPreview = preview == workspace ? nil : preview
        assistantFocus = focus
        return true
    }

    /// Keeps the assistant's changes as one undo step and selects what it made or changed last.
    /// Returns false (the changes stay under review) when the document cannot change.
    @discardableResult func keepAssistantChanges() -> Bool {
        guard let preview = assistantPreview, !isAssistantWorking, !isProjectBusy else { return false }
        guard !isReadOnly, !purchaseBlocksEditing else {
            saveError = "This file cannot be changed right now, so the assistant's changes are still under review. Resolve the file first, or Discard them."
            return false
        }
        assistantPreview = nil
        commit(preview)
        switch assistantFocus {
        case .body(let id)? where workspace.isShown(body: id): selection = .body(id)
        case .sketch(let id)? where workspace.isShown(sketch: id): selection = .sketch(id)
        default: break
        }
        assistantFocus = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    func discardAssistantChanges() {
        guard !isAssistantWorking else { return }
        assistantPreview = nil
        assistantFocus = nil
        canFinishAuthorizedEdit = false
    }

    func undo() { guard requireNewEditingAccess(), !isEditingBlocked else { return }; cancelTransient(); selection = nil; history.undo(); revalidateSelectedNote(); revalidateSketchMode(); prunePicked(); save() }
    func redo() { guard requireNewEditingAccess(), !isEditingBlocked else { return }; cancelTransient(); selection = nil; history.redo(); revalidateSelectedNote(); revalidateSketchMode(); prunePicked(); save() }

    /// Undo, redo, and holes can remove or renumber what a sketch mode is on: follow its face to the
    /// face's new number (by the point it was picked at), or leave sketch mode when it is gone.
    private func revalidateSketchMode() {
        guard let mode = sketchMode else { return }
        func leave() { endSketchMode(); tool = .select }
        if let id = mode.sketchID, !workspace.sketches.contains(where: { $0.id == id }) { sketchMode?.sketchID = nil }
        if let id = mode.constructionPlane, !workspace.isShown(plane: id) { leave(); return }
        guard let face = mode.face, let plane = face.plane else { return }
        guard let body = workspace.bodies.first(where: { $0.id == face.bodyID && !workspace.isHidden($0) }),
              let solid = try? SolidKernel.solid(for: body) else { leave(); return }
        let normal = plane.normalAxis
        // The picked point can now be inside a hole; any face still on the plane will do then.
        let onPlane = (0..<solid.faceCount).first { index in
            solid.facePlane(index).map { simd_dot($0.normal, normal) > 1 - 1e-9 && abs(simd_dot($0.origin - plane.origin, normal)) < 1e-6 } ?? false
        }
        guard let index = solid.face(containing: face.point ?? face.center, normal: normal) ?? onPlane else { leave(); return }
        if index != face.face { sketchMode?.face?.face = index }
    }
    private func commit(_ updated: Workspace, besideNotes: Bool = false) {
        guard besideNotes ? !isBlockedApartFromNotes : !isEditingBlocked else { return }
        var updated = updated
        updated.normalizeSketches()
        updated.pruneImportedShapes()
        // Linked notes keep the names of objects deleted or renumbered by this step.
        updated.captureObjectNoteNames(since: workspace)
        // A solid a removal left in separate pieces becomes one solid per piece, in the same step.
        let separated = updated.separatingPieces(since: workspace)
        updated = separated.workspace
        // A merge, subtract, or intersect just made stores a solid with a long history as its exact
        // shape, built already for its preview (November 8, 2026).
        let oldSteps = Set(workspace.bodies.flatMap { $0.cuts.map(\.id) })
        let newSteps = Set(updated.bodies.flatMap { $0.cuts.filter { $0.nestedSolid != nil }.map(\.id) }).subtracting(oldSteps)
        if !newSteps.isEmpty { updated = updated.storingCarriedSolidsAsShapes(build: false, steps: newSteps) }
        let count = separated.added.values.reduce(0) { $0 + $1.count + 1 }
        // An edit the project file cannot hold is refused here, rather than kept on screen where
        // every later save would fail until it is undone (November 8, 2026).
        guard (try? ProjectCodec.checkSize(updated)) != nil else {
            status = "Not changed"
            saveError = "That change was not made: it would make the project too large to save. Your project is as it was before."
            return
        }
        if count > 0 { status = "Separated into \(count) solids" }
        history.commit(updated)
        canFinishAuthorizedEdit = false
        save()
    }
    /// Stores the carried solids of a model made before November 8, 2026 (merged, subtracted, and
    /// intersected solids with their whole histories) as their exact shapes, once, in the background
    /// after opening: the same model, smaller and quicker to build, saved without an undo step. An
    /// edit made meanwhile starts it again; a file that cannot be edited is left as it is.
    func storeCarriedSolidsAsShapes() {
        guard !isEditingBlocked, hasEditingAccess, workspace.hasCarriedHistories, !isStoringCarriedSolids else { return }
        isStoringCarriedSolids = true
        let snapshot = workspace
        Task.detached(priority: .utility) { [weak self] in
            let stored = snapshot.storingCarriedSolidsAsShapes(build: true)
            await self?.carriedSolidsStored(stored, from: snapshot)
        }
    }
    @ObservationIgnored private var isStoringCarriedSolids = false

    private func carriedSolidsStored(_ stored: Workspace, from snapshot: Workspace) {
        isStoringCarriedSolids = false
        guard stored != snapshot, !isEditingBlocked else { return }
        guard workspace == snapshot else { storeCarriedSolidsAsShapes(); return }
        guard history.replaceStorage(stored) else { return }
        save()
    }

    private func documentStateChanged() {
        guard let document else { return }
        isReadOnly = document.isReadOnly
        if isReadOnly { endEditingNotes() }
        documentRevision += 1
        if document.documentState.contains(.inConflict) { status = "File conflict · Save As to keep a copy" }
        else if document.reloadFailed { status = "The file changed and cannot be read · Save As to keep a copy" }
    }

    /// Saves the project. `withThumbnail` also draws the model's picture for the document browser
    /// (on leaving the project or the app, not after every change).
    func save(withThumbnail: Bool = false, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        // Edits in quick succession (keypad entries, the assistant's steps, undo held down) save
        // once at the end of the burst rather than writing the whole file for each (November 8,
        // 2026); an isolated edit still saves at once, and leaving the project or the app saves
        // anything pending first.
        // Notes being typed join the model at once; only writing the file waits.
        flushNotes()
        pendingSave?.cancel()
        pendingSave = nil
        if !withThumbnail, completion == nil, Date().timeIntervalSince(lastSaveStarted) < Self.saveBurstInterval {
            pendingSave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.saveBurstInterval))
                guard !Task.isCancelled, let self else { return }
                self.pendingSave = nil
                self.saveNow(withThumbnail: false, completion: nil)
            }
            return
        }
        saveNow(withThumbnail: withThumbnail, completion: completion)
    }

    private static let saveBurstInterval = 1.0
    @ObservationIgnored private var lastSaveStarted = Date.distantPast
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// The model the file's picture shows, so leaving a project (or the app) unchanged does not
    /// render the picture again: it was drawn on every trip to the background (November 8, 2026).
    @ObservationIgnored private var pictureWorkspace: Workspace?

    private func saveNow(withThumbnail: Bool, completion: (@MainActor @Sendable (Bool) -> Void)?) {
        lastSaveStarted = Date()
        flushNotes()
        guard let document else { completion?(true); return }
        if document.isReadOnly {
            if !document.hasUnsavedChanges && document.project.workspace == workspace { completion?(true); return }
            saveError = "This file cannot be overwritten right now. Use Save As to keep your work in a separate file."
            completion?(false); return
        }
        if withThumbnail, hasEditingAccess || document.hasUnsavedChanges || document.project.workspace != workspace,
           !(pictureWorkspace?.hasSameModel(as: workspace) ?? false) {
            document.setPreview(projectThumbnailProvider?())
            pictureWorkspace = workspace
        }
        do {
            try document.updateWorkspace(workspace)
            // Each published change redraws the editor: set only what changed.
            if status != "Saving…" { status = "Saving…" }
            document.autosave { [weak self] success in
              Task { @MainActor in
                guard let self else { completion?(success); return }
                if success {
                    let saved = self.document?.hasUnsavedChanges == true ? "Changes pending" : "Saved"
                    if self.status != saved { self.status = saved }
                    if self.saveError != nil { self.saveError = nil }
                } else {
                    self.status = "Not saved"
                    self.saveError = "Your changes are still open. Check the file's location and available storage, then try Save again or use Save As."
                }
                completion?(success)
              }
            }
        } catch { status = "Not saved"; saveError = error.localizedDescription; completion?(false) }
    }
}

private extension String {
    /// A kernel message ("Revolve failed: the axis crosses the profile") as a hint sentence.
    var capitalizedFirst: String {
        let reason = components(separatedBy: ": ").last ?? self
        return reason.prefix(1).uppercased() + reason.dropFirst() + (reason.hasSuffix(".") ? "" : ".")
    }
}
