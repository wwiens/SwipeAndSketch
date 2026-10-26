import Foundation

/// Help for what the user is doing right now: a short plain-language overview. The hint's help
/// button opens the topic for the current tool, operation, or selection.
enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted, sketchPlane, sketching, line, rectangle, circle, arc, slot, trim, sketchFillet, dimension, hole
    case ellipse, point, polygon, construction, extend, offset, sketchMirror, moveShape
    case editShape, keypad, sketchObject, pickedSketches, pickedSolids, pickedEdges, solid, face, edge, constructionPlane
    case extrude, extrudeFace, cut, join, revolve, fillet, chamfer, shell
    case union, subtract, intersect, split, align, mirror, pattern, scale, deleteFace, section, offsetPlane, midplane, project, measure, assistant
    case peg, fitTest, thread, matingPart, text
    case screwLid
    case sweep
    case loft
    case rib
    case draft
    case spline
    case axis
    case planeTangent
    case plane3Point
    case planeAngle
    case modelGroup
    case primitives
    case xray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: "Getting Started"
        case .sketchPlane: "Choosing a Sketch Plane"
        case .sketching: "Sketching"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .arc: "Arc"
        case .slot: "Slot"
        case .ellipse: "Ellipse"
        case .point: "Point"
        case .polygon: "Polygon"
        case .construction: "Construction Geometry"
        case .extend: "Extend"
        case .offset: "Offset"
        case .sketchMirror: "Mirror in a Sketch"
        case .moveShape: "Moving a Shape"
        case .trim: "Trim"
        case .sketchFillet: "Sketch Fillet"
        case .dimension: "Dimension"
        case .hole: "Hole"
        case .editShape: "Editing a Shape"
        case .keypad: "Typing a Value"
        case .sketchObject: "Moving a Sketch"
        case .pickedSketches: "Picking Several Sketches"
        case .pickedSolids: "Picking Several Solids"
        case .pickedEdges: "Picking Several Edges"
        case .solid: "Moving a Solid"
        case .face: "Working with a Face"
        case .edge: "Working with an Edge"
        case .constructionPlane: "Construction Planes"
        case .extrude: "Extrude"
        case .extrudeFace: "Extrude a Face"
        case .cut: "Cutting Holes and Pockets"
        case .join: "Joining to a Solid"
        case .revolve: "Revolve"
        case .fillet: "Fillet"
        case .chamfer: "Chamfer"
        case .shell: "Shell"
        case .union: "Union"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        case .peg: "Peg & Socket"
        case .fitTest: "Fit Test"
        case .thread: "Thread"
        case .screwLid: "Screw Lid"
        case .matingPart: "Matching Part"
        case .text: "Text"
        case .split: "Split Body"
        case .align: "Align"
        case .mirror: "Mirror"
        case .pattern: "Pattern"
        case .scale: "Scale"
        case .deleteFace: "Delete Face"
        case .section: "Section View"
        case .sweep: "Sweep"
        case .loft: "Loft"
        case .rib: "Rib"
        case .draft: "Draft"
        case .spline: "Spline"
        case .axis: "Axis"
        case .planeTangent: "Tangent Plane"
        case .plane3Point: "3-Point Plane"
        case .planeAngle: "Plane at Angle"
        case .modelGroup: "Groups"
        case .primitives: "Primitives"
        case .xray: "X-ray"
        case .offsetPlane: "Offset Plane"
        case .midplane: "Midplane"
        case .project: "Project"
        case .measure: "Measure"
        case .assistant: "Assistant"
        }
    }

    var icon: SSIcon {
        switch self {
        case .gettingStarted: .help
        case .sketchPlane, .sketching, .sketchObject, .pickedSketches: .sketch
        case .line: .line
        case .rectangle: .rectangle
        case .circle: .circle
        case .arc: .arc
        case .slot: .slot
        case .ellipse: .ellipse
        case .point: .point
        case .polygon: .polygon
        case .construction: .construction
        case .extend: .extend
        case .offset: .offset
        case .sketchMirror: .mirror
        case .moveShape: .select
        case .trim: .trim
        case .sketchFillet: .sketchFillet
        case .dimension, .editShape, .keypad: .dimension
        case .hole: .hole
        case .solid, .pickedSolids: .solid
        case .face, .extrude, .extrudeFace: .extrude
        case .edge, .fillet, .pickedEdges: .fillet
        case .constructionPlane: .plane
        case .cut: .cut
        case .join: .merge
        case .revolve: .revolve
        case .chamfer: .chamfer
        case .shell: .shell
        case .union: .merge
        case .subtract: .subtract
        case .intersect: .intersect
        case .peg: .peg
        case .fitTest: .fitTest
        case .thread, .matingPart, .screwLid: .thread
        case .text: .text
        case .split: .split
        case .align: .align
        case .mirror: .mirror
        case .pattern: .pattern
        case .scale: .scale
        case .deleteFace: .deleteFace
        case .section: .section
        case .sweep: .sweep
        case .loft: .loft
        case .rib: .rib
        case .draft: .draft
        case .spline: .spline
        case .axis: .axis
        case .planeTangent: .planeTangent
        case .plane3Point: .plane3Point
        case .planeAngle: .planeAngle
        case .modelGroup: .group
        case .primitives: .primitives
        case .xray: .xray
        case .offsetPlane: .offsetPlane
        case .midplane: .midplane
        case .project: .project
        case .measure: .measure
        case .assistant: .assistant
        }
    }

    /// What it is, how to do it, and what is worth knowing, in plain words.
    var overview: HelpOverview {
        switch self {
        case .gettingStarted:
            HelpOverview(
                summary: "Swipe & Sketch needs Apple Pencil: it draws, selects, and edits. Your fingers move around the model. Start with a sketch, then turn it into a solid.",
                steps: ["Tap Sketch in the dock at the bottom.", "Draw a shape with Pencil on the grid.", "Tap Finish Sketch, tap inside the shape, then tap Extrude to make it solid."],
                tips: ["One finger orbits, two fingers pan, and a pinch zooms.", "Tap a face of the view cube to look straight at it; double-tap the cube to go back to 3D.",
                       "With no tool chosen, a Pencil tap selects. Undo and Redo are at the bottom left."])
        case .sketchPlane:
            HelpOverview(
                summary: "A sketch lies flat on a plane. Pick where to draw before you start.",
                steps: ["Tap one of the three see-through planes at the origin, or a flat face of a solid.", "The view turns to face it, and your sketch begins there.",
                        "Or just draw on the grid to sketch on the floor without turning the view."],
                tips: ["The view cube also picks the plane: Top, Front, or Right."])
        case .sketching:
            HelpOverview(
                summary: "You are in a sketch. Everything you draw now belongs to it and stays on its plane.",
                steps: ["Pick a drawing tool in the dock: Line, Rectangle, or one under Shapes (Circle, Arc, Slot, and more).", "Draw with Pencil.", "Tap Finish Sketch when you are finished."],
                tips: ["Purple dots are snap points. Line up with one and a dashed guide appears.",
                       "Everything on this plane, from any sketch, turns violet with its ends and middles marked: draw from or onto any of it.",
                       "Strokes catch the ends, middles, and crossings of your lines, and anywhere along a line or circle; a purple ring shows the catch. Snap Off turns off only the grid and the guides.",
                       "Tap a shape with no tool chosen to see and change its sizes.",
                       "Tap the active tool again to put it down."])
        case .line:
            HelpOverview(
                summary: "Draw straight lines. Lines joined end to end can close an outline you can extrude.",
                steps: ["Touch Pencil where the line starts.", "Drag to where it ends and lift.", "Start the next line on the last end to keep the outline connected, and finish on the first point to close it."],
                tips: ["Start or end on another line (its end, middle, or anywhere along it) and the line joins it there.", "Tap a line afterwards to type its exact length."])
        case .rectangle:
            HelpOverview(
                summary: "Draw a rectangle from one corner to the other, or outward from its center.",
                steps: ["Drag Pencil from one corner to the opposite corner.", "Tap the width or height to type an exact size."],
                tips: ["Tap Rectangle again to switch between Corners and Center.", "A rectangle drawn from its center stays centered when you resize it."])
        case .circle:
            HelpOverview(
                summary: "Draw a circle from its center. Arc, Slot, and the other shapes are in the same Shapes group.",
                steps: ["Touch Pencil where the center goes.", "Drag out to the size you want and lift.", "Tap the diameter to type an exact size."],
                tips: ["A circle inside another shape makes a hole in it when you extrude.", "Drag the center to move the circle, or its edge to resize it."])
        case .arc:
            HelpOverview(
                summary: "Draw a curved segment through three points: two ends and a middle.",
                steps: ["Drag Pencil from one end of the arc to the other, bending the stroke through the middle.", "Drag the ends or the middle dot to reshape it."],
                tips: ["Tap the radius to type an exact size."])
        case .ellipse:
            HelpOverview(
                summary: "Draw an ellipse: an oval with two diameters.",
                steps: ["Touch Pencil at the center.", "Drag to a corner of the box around it, and lift."],
                tips: ["Drag the handle at the end of its axis to turn or lengthen it, and the side handle to change its width.",
                       "Tap a diameter to type it. Extruded, it has one smooth side."])
        case .point:
            HelpOverview(
                summary: "Place a point: a spot to snap to, dimension from, and align to. It makes no region.",
                steps: ["Tap where the point goes."],
                tips: ["Use points to mark hole centers, then snap holes or circles to them."])
        case .polygon:
            HelpOverview(
                summary: "Draw a regular polygon, such as a hexagon for a nut trap.",
                steps: ["Touch Pencil at the center.", "Drag to where one corner goes, and lift.", "Tap the number of sides beside it to change it."],
                tips: ["It is made of joined lines, so each side can be dimensioned or trimmed.", "The next polygon has the same number of sides."])
        case .construction:
            HelpOverview(
                summary: "Construction geometry is for reference: drawn dashed, it bounds no region but can be snapped to, mirrored across, or revolved about.",
                steps: ["Select a shape in a sketch.", "Tap Construction above the dock. Tap it again to make it ordinary."],
                tips: ["A construction line through the middle makes a good mirror line or revolve axis."])
        case .extend:
            HelpOverview(
                summary: "Extend carries a straight line on until it meets another shape on this plane, or the edge of the face you are sketching on.",
                steps: ["Open Modify in the dock and choose Extend.", "Tap a line near the end you want to lengthen."],
                tips: ["Lines from any sketch on this plane stop it, not just this sketch's.", "If nothing lies ahead, the line stays as it is."])
        case .offset:
            HelpOverview(
                summary: "Offset draws a copy of an outline a set distance away: a lip for a lid, a wall around a shape, a gasket.",
                steps: ["Choose Modify, then Offset.", "Tap a shape, or one line of an outline (the lines joined to it come too).", "Tap the distance to type it, then Done."],
                tips: ["Flip offsets the other way; Both Sides makes a wall around the outline.", "Rounded rounds the outside corners."])
        case .sketchMirror:
            HelpOverview(
                summary: "Mirror copies shapes across a line in the same sketch, for symmetric parts.",
                steps: ["Choose Modify, then Mirror (or select a shape first).", "Tap the shapes to copy, then Mirror Line and the line to copy across.", "Tap Done."],
                tips: ["Draw a construction line down the middle to mirror across."])
        case .moveShape:
            HelpOverview(
                summary: "Move or turn the selected shape within its sketch.",
                steps: ["Drag an arrow to move it along the sketch, or the arc to turn it."],
                tips: ["Turn on Create Copy to keep the original.", "A rectangle turned to an angle becomes its four lines."])
        case .slot:
            HelpOverview(
                summary: "Draw a rounded slot, like a stretched circle, for screws or adjustable mounts.",
                steps: ["Drag Pencil from the center of one round end to the center of the other.", "Tap the length or width to type exact sizes."],
                tips: ["A new slot uses the last width you set."])
        case .trim:
            HelpOverview(
                summary: "Remove part of a shape, back to where other shapes cross it.",
                steps: ["Tap the part to remove, or scribble across several parts.", "Tap empty space when you are done."],
                tips: ["A shape nothing crosses is removed whole.", "Each stroke is one step you can undo."])
        case .sketchFillet:
            HelpOverview(
                summary: "Round off a corner where two lines meet.",
                steps: ["Tap the corner.", "Tap the radius that appears to type the size you want."],
                tips: ["Rectangle corners work too."])
        case .dimension:
            HelpOverview(
                summary: "Set an exact distance or angle between parts of your sketch.",
                steps: ["Tap a point, line, or circle to measure from.", "Tap a second item. The distance across, up, or the angle appears.", "Tap a value and type the new one. The second item moves to match."],
                tips: ["Purple dots and edges of solids can be the first item.", "Tap empty space to start over. Dimensions are not kept afterwards."])
        case .hole:
            HelpOverview(
                summary: "Put a ready-made screw hole in a face: simple, counterbore, countersink, or heat-set insert.",
                steps: ["Tap the face where the hole goes. It snaps to the purple dots.", "Choose the type and size (M2 to M5) below.", "Tap Done to drill it. The tool stays ready for the next hole."],
                tips: ["Tap the diameter or depth to type your own. A counterbore or countersink widens with the hole.", "Turn off Through for a hole that stops partway.",
                       "To change a hole later, tap its wall and choose Edit Hole: change it, or tap elsewhere on the face to move it, and tap Done."])
        case .editShape:
            HelpOverview(
                summary: "This shape is selected. Its sizes show beside it.",
                steps: ["Tap a size to type an exact value.", "Or drag a corner, end, or edge with Pencil to resize it by hand."],
                tips: ["Connected lines stay joined while you drag.", "Tap inside a closed shape and choose Extrude to make it solid.",
                       "Inside a sketch, drag an arrow of the widget to move the shape, or its arc to turn it; Create Copy keeps the original.",
                       "Construction (above the dock) turns it into a dashed reference that makes no region."])
        case .keypad:
            HelpOverview(
                summary: "Type the exact value you want. The keypad also does simple math and unit changes.",
                steps: ["Type a number, such as 25.", "Tap the check mark to apply it, or × to leave things as they were."],
                tips: ["Math works: 40/2 or 12+3.5.", "Add a unit to convert: 1 in, 2.5 cm, or 0.1 m.", "A value that does not fit is not applied."])
        case .sketchObject:
            HelpOverview(
                summary: "The whole sketch is selected. Move it, turn it, or copy it.",
                steps: ["Drag an arrow to move the sketch along it.", "Drag an arc to turn it.", "Tap a value to type an exact distance or angle."],
                tips: ["Turn on Create Copy to leave the original where it was.", "Tap one of its lines to go back to drawing in it.",
                       "Extrude above the dock extrudes every region of the sketch. Tap another sketch or region on its plane to pick it too."])
        case .pickedSketches:
            HelpOverview(
                summary: "Several sketch regions or whole sketches are picked, ready to extrude or revolve together, such as holes cut into a face all at once.",
                steps: ["With a region or sketch selected, tap more regions, or the lines of more sketches, on the same plane.",
                        "Tap a picked one to take it out again.", "Tap Extrude (or Revolve) above the dock, drag the double-arrow into the solid, and tap Done."],
                tips: ["The strip above the dock says how many are picked.", "Everything picked is cut, joined, or made in one step you can undo.",
                       "Tap empty space to start over. Something on another plane, or a solid or face, starts a new selection."])
        case .pickedSolids:
            HelpOverview(
                summary: "Several whole solids are picked, to move, combine, color, or export them together.",
                steps: ["With a solid selected, double-tap another solid to add it.", "Double-tap a picked one to take it out again.",
                        "Drag an arrow or an arc to move or turn them all, or use the actions above the dock."],
                tips: ["Combine joins, cuts, or intersects them: with Subtract, the first picked is cut by the rest.",
                       "Transform, Color, Export, and Delete take them all, as one step you can undo.",
                       "Tap empty space to start over."])
        case .pickedEdges:
            HelpOverview(
                summary: "Several edges of one solid are picked, to round or bevel them all at once.",
                steps: ["With an edge selected, tap more edges of the same solid to add them.", "Tap a picked edge to take it out again.",
                        "Tap Fillet or Chamfer above the dock, set the size, and tap Done."],
                tips: ["Every picked edge gets the same size, in one step you can undo.",
                       "An edge of another solid, a face, or empty space starts over."])
        case .solid:
            HelpOverview(
                summary: "The whole solid is selected. Move it, turn it, or copy it.",
                steps: ["Drag an arrow to move it, or an arc to turn it.", "Tap a value to type an exact distance or angle."],
                tips: ["Drag the center dot onto a corner or edge to turn about that spot. It can also go to another solid, a sketch point, or the origin.", "Turn on Create Copy to keep the original.", "The actions above the dock work on this solid."])
        case .face:
            HelpOverview(
                summary: "A face is selected. You can change its size, push or pull it, sketch on it, or take it off.",
                steps: ["Tap the size beside it (a round face's diameter, a flat face's distance to the face behind it) and type a new one.",
                        "Or tap Extrude to pull the face out or push it in, or Sketch to draw on it.", "Double-tap the face to select the whole solid."],
                tips: ["Delete Face takes it off and closes the gap: a hole or a boss disappears. For a fillet or chamfer, tap its face and choose Delete Fillet or Delete Chamfer.",
                       "Curved faces can be used for Shell and Delete Face, but not for sketching or Extrude."])
        case .edge:
            HelpOverview(
                summary: "An edge is selected. Round or bevel it.",
                steps: ["Drag the double-arrow to round the edge.", "Or choose Fillet or Chamfer for more edges at once."],
                tips: ["The size shows in the strip above the dock."])
        case .constructionPlane:
            HelpOverview(
                summary: "A construction plane is a flat surface you place in space to sketch on or measure from.",
                steps: ["Tap Sketch to draw on it.", "Or tap Offset Plane for another plane parallel to it."],
                tips: ["Hide or delete planes from the Model Tree."])
        case .extrude:
            HelpOverview(
                summary: "Extrude turns a flat sketch into a solid by giving it depth.",
                steps: ["Tap inside a closed sketch shape.", "Drag the blue double-arrow to set the depth, or tap the value to type it.", "Tap Done to make the solid, or Cancel to discard it."],
                tips: ["Drag back past zero to extrude the other way.", "Dragging into a solid cuts it; touching one joins it. A cut that leaves pieces apart makes each its own solid.",
                       "Symmetric extrudes half each way; Taper leans the sides in by an angle; Up To sets the depth to reach a face you tap.",
                       "Tap other regions of the sketch to extrude them at the same time, or pick several regions and sketches before choosing Extrude."])
        case .extrudeFace:
            HelpOverview(
                summary: "Push or pull a flat face to change the solid it belongs to.",
                steps: ["Drag the double-arrow out to add material, or in to cut.", "Or tap the value to type the size you want.", "Tap Done to apply it."],
                tips: ["The value is the size the solid ends up across the face: pull the top of a 20 mm box 5 mm and it reads 25 mm.",
                       "On a face with no parallel face behind it, the value is how far the face moves (negative goes in).",
                       "Holes and rounded edges in the face carry through."])
        case .cut:
            HelpOverview(
                summary: "The sketch removes material wherever it passes through a solid.",
                steps: ["Drag the double-arrow for a pocket of a set depth.", "Or turn on Through All to cut all the way through.", "Tap Done to cut."],
                tips: ["The red shape shows what will be removed.", "Choose New Body to make a separate solid instead."])
        case .join:
            HelpOverview(
                summary: "The new shape touches a solid, so it will become part of it.",
                steps: ["Drag the double-arrow or tap the depth.", "Tap Done to merge it into the solid."],
                tips: ["Choose New Body to keep it as a separate solid."])
        case .revolve:
            HelpOverview(
                summary: "Revolve spins a flat shape around a line to make round parts, like knobs, rings, or vases.",
                steps: ["Tap the line to spin around: a sketch line, a solid's straight edge, or an axis.", "Drag the curved arrow or tap the angle. 360° goes all the way around.", "Tap Done."],
                tips: ["The line must lie beside the shape, not through it.", "Like Extrude, it can make a new solid, join one, or cut one."])
        case .fillet:
            HelpOverview(
                summary: "Fillet rounds sharp edges of a solid.",
                steps: ["Tap the edges to round. Tap again to unpick one.", "Drag the double-arrow or tap the radius.", "Tap Done."],
                tips: ["A red value is too large for those edges.", "Shell before rounding every edge: a fully rounded box cannot be hollowed.",
                       "To change a fillet later, tap its rounded face and tap the radius. Delete Fillet makes its edges sharp again."])
        case .chamfer:
            HelpOverview(
                summary: "Chamfer cuts a flat bevel along sharp edges of a solid.",
                steps: ["Tap the edges to bevel. Tap again to unpick one.", "Drag the double-arrow or tap the distance.", "Tap Done."],
                tips: ["A red value is too large for those edges.",
                       "To change a chamfer later, tap its beveled face and tap the distance. Delete Chamfer makes its edges sharp again."])
        case .shell:
            HelpOverview(
                summary: "Shell hollows out a solid, leaving walls of the thickness you choose.",
                steps: ["Tap the faces to leave open, such as the top of a box.", "Drag the double-arrow or tap the thickness.", "Tap Done."],
                tips: ["The outside size stays the same; the walls grow inward."])
        case .union:
            HelpOverview(
                summary: "Union combines solids that touch or overlap into one.",
                steps: ["Tap the solids to combine. The last one you tap is the target.", "Tap Done."],
                tips: ["Turn on Keep Input to keep the separate solids too."])
        case .subtract:
            HelpOverview(
                summary: "Subtract takes one solid away from another, like using one as a cutter.",
                steps: ["Tap the solids to cut from (purple).", "Tap Tools, then the solids to take away (blue).", "Tap Done."],
                tips: ["Keep chooses whether the targets, the tools, or both stay afterwards.",
                       "Clearance leaves a gap around the tools, so a printed part shaped like them fits into the space. Keep: Tools keeps that part."])
        case .xray:
            HelpOverview(
                summary: "X-ray shows solids see-through, so you can look inside an enclosure or at parts hidden behind others. It changes nothing in the model.",
                steps: ["Tap X-ray in the rail at the top left to see every solid through.", "Or long-press a solid (or a group) in the Model Tree and choose X-ray to see only that one through.", "Tap X-ray again, or choose Turn Off X-ray, to see them solid again."],
                tips: ["With one solid X-rayed, a tap goes through it to a part inside, so you can select what it hides.", "X-ray is not saved with the project."])
        case .primitives:
            HelpOverview(
                summary: "Make a ready-made box, cylinder, sphere, or torus (a ring) in one step, without sketching.",
                steps: ["Choose Create, then Box, Cylinder, Sphere, or Torus.", "Tap the grid, or a flat face of a solid, where it goes. It stands on what you tapped.", "Tap a size beside it to type a new one. Tap elsewhere to move it.", "Tap Done. It is a solid of its own, ready to move, combine, fillet, or shell."],
                tips: ["A torus's diameter runs through the middle of its tube.", "A box or cylinder is an ordinary extrusion and a sphere or torus a revolve, so their faces can be resized and pushed like any other.", "The next one starts from the sizes you used last."])
        case .modelGroup:
            HelpOverview(
                summary: "A group in the Model Tree holds solids, sketches, planes, and other groups. Select its row to work on everything in it at once.",
                steps: ["Tap a group's name in the Model Tree (its arrow folds it). Everything in it is outlined in blue.", "Drag an arrow of the widget to move it all, or an arc to turn it. Turn on Create Copy to copy the whole group.", "Or choose Transform to scale, mirror, or pattern it all, or Export for a 3MF of just its solids. Long-press the row for Duplicate."],
                tips: ["The group's eye hides everything inside without changing each item's own eye.", "Long-press the row to rename the group, X-ray it, ungroup it, or delete it with its contents."])
        case .planeAngle:
            HelpOverview(
                summary: "A construction plane through a straight edge or sketch line, turned about it by an angle: for sketching on a slant, such as a bevel or a ramp.",
                steps: ["Choose Planes, then Plane at Angle.", "Tap a straight edge of a solid, or a sketch line.", "Tap the angle and type it. 0° lies on the face beside the edge (or the line's sketch); 90° stands straight up from it.", "Tap Done, then Sketch on the plane."],
                tips: ["Like every construction plane, it is a fixed frame: it does not follow the edge if the solid changes."])
        case .plane3Point:
            HelpOverview(
                summary: "A construction plane through three points: corners of solids, points of sketches, or the origin.",
                steps: ["Choose Planes, then 3-Point Plane.", "Tap three points. A picked point taps off again.", "Tap Done."],
                tips: ["Three points in a line make no plane: take one out and pick another."])
        case .planeTangent:
            HelpOverview(
                summary: "A construction plane touching a round face, such as a cylinder's side, along a line: for text or a flat on a round part.",
                steps: ["Choose Planes, then Tangent Plane.", "Tap the round face where the plane should touch it.", "Tap Done, then Sketch on the plane."],
                tips: ["Tap elsewhere on the face to move the plane round it."])
        case .axis:
            HelpOverview(
                summary: "A construction axis: a straight reference line in space, to revolve about, mirror across, or align to.",
                steps: ["Choose Planes, then Axis.", "Tap a round face or circular edge for its center line, a straight edge or sketch line to run along it, or two points.", "Tap Done. The axis is a sketch named Axis 01 holding one construction line."],
                tips: ["Revolve, Mirror, and Align pick it like any sketch line.", "Hide, rename, group, or delete it in the Model Tree like a sketch."])
        case .spline:
            HelpOverview(
                summary: "A smooth curve: draw it freehand with Pencil, and it becomes a spline through a few points that you can drag to reshape it.",
                steps: ["Choose Shapes, then Spline.", "Draw the curve with Pencil. End where you began to close it into a region.", "Tap the spline and drag any of its points: the curve still passes through every point."],
                tips: ["A closed spline bounds a region that extrudes, revolves, and cuts like any other.", "Its sides are made of many short flat pieces, fine enough for printing."])
        case .draft:
            HelpOverview(
                summary: "Draft leans faces a few degrees, so a printed mold releases its casting (or a part slides out of a mold).",
                steps: ["Choose Modify, then Draft.", "Tap the flat face the draft leans from, such as the base: it stays put.", "Tap the faces to lean, such as the sides.", "Tap the angle to change it (3° is common; negative leans outward), then Done."],
                tips: ["A face square to the pull direction (like the top) cannot be drafted.", "Draft is saved with the solid and follows it when it moves or is mirrored."])
        case .rib:
            HelpOverview(
                summary: "A rib is a thin stiffening web that grows from a sketch line until it meets the solid, such as a gusset in the corner of a bracket.",
                steps: ["Sketch a line across the corner, on a plane through the solid (such as Front through the middle of a bracket).", "Choose Create, then Rib, and tap the line.", "Tap the thickness to change it, or Flip for the other side of the line. Tap Done."],
                tips: ["The rib is part of the solid and is saved with it."])
        case .loft:
            HelpOverview(
                summary: "Loft blends between two or more sketch regions on different planes, such as a square base into a round top.",
                steps: ["Sketch the regions on planes one above another (an offset construction plane helps).", "Choose Create, then Loft, and tap the regions in order.", "Turn on Ruled for flat sides between them. Tap Done."],
                tips: ["The loft is a new solid of its own, saved with its exact shape; its regions can be changed afterwards without changing it."])
        case .sweep:
            HelpOverview(
                summary: "Sweep carries a sketch region along a path: a line, an arc, a spline, or joined lines, such as a tube or a handle.",
                steps: ["Sketch the region (such as a circle), and the path starting at it, across it, on another plane.", "Choose Create, then Sweep. Tap the region, then the path.", "Tap Done."],
                tips: ["Keep bends wider than the region, or it folds into itself.", "The sweep is a new solid of its own, saved with its exact shape."])
        case .section:
            HelpOverview(
                summary: "The section view cuts your solids open along a plane, so you can check walls, holes, threads, and sockets inside. It changes nothing.",
                steps: ["Tap Section in the rail at the top left.", "Choose Top, Front, or Right, and drag the double-arrow (or tap the offset) to move the cut.", "Tap Done to see the whole model again."],
                tips: ["The cut faces are filled in coral.", "Flip shows the other half."])
        case .deleteFace:
            HelpOverview(
                summary: "Delete Face takes faces off a solid and closes the gap, so a fillet, chamfer, hole, or boss disappears.",
                steps: ["Select a face and tap Delete Face, or choose Modify, then Delete Face.", "Tap more faces of the same feature, such as a hole's floor.", "Tap Done, or tap empty space."],
                tips: ["For a round hole, tap its wall and choose Delete Hole instead: the whole hole goes in one tap, as if it had never been made, with a thread in it and any fillet or chamfer on its rim.",
                       "The faces around the gap grow to close it. If they cannot meet, pick the rest of the feature too.",
                       "To remove a whole solid, double-tap it and use the trash can."])
        case .scale:
            HelpOverview(
                summary: "Scale makes solids and sketches larger or smaller, by a percentage.",
                steps: ["Tap the solids and sketches to scale.", "Drag an arrow of the gizmo, or tap the percentage and type it.", "Tap Done."],
                tips: ["About sets the point that stays put: the middle, the middle of the bottom (so a part stays on the plate), or the origin.",
                       "Turn off Uniform to stretch solids by a different percentage along each arrow.",
                       "Holes, threads, and pegs scale too: a scaled M3 hole is no longer M3.",
                       "Create Copy keeps the original."])
        case .intersect:
            HelpOverview(
                summary: "Intersect keeps only the part where solids overlap, and removes the rest.",
                steps: ["Tap the solids that overlap. The last one you tap is the target.", "Tap Done."],
                tips: ["Turn on Keep Input to keep the original solids too.",
                       "Good for trimming a part to a shape: overlap it with a box or cylinder of the size you want, then intersect."])
        case .peg:
            HelpOverview(
                summary: "Add a round peg to a face, with a matching socket in the part it pushes into, so printed parts line up and press together.",
                steps: ["Select the flat face the peg stands on, such as a box's rim, and choose Joints, then Peg & Socket. Hide a lid in the Model Tree to reach the face under it.",
                        "Tap where the peg goes. It snaps to the purple dots.",
                        "Any solid the peg pushes into, even a hidden one, gets a socket, wider and deeper by the clearance. Tap Done; the tool stays ready for the next peg."],
                tips: ["Joined makes the peg part of the face's solid. Separate makes it its own solid, a dowel pin to print on its own (lying down, for strength); it reaches into the face by Into Face, which gets a socket too (0 just stands it on the face).",
                       "Tap the diameter or height to change them.", "The clearance starts from your Fit Clearance (project menu). Tight suits press fits; Loose slides apart easily.",
                       "The peg's tip is beveled so it starts into its socket easily.",
                       "To change a peg later, tap it (or its socket, or select a separate peg) and choose Edit Peg. Its sockets follow its new size and place."])
        case .text:
            HelpOverview(
                summary: "Add raised or sunk lettering to a flat face: labels, names, version numbers.",
                steps: ["Select a flat face and tap Text above the dock, or choose Features ▸ Text while sketching on a face.",
                        "Tap where the text goes; it snaps to the purple dots. Type it in the field below and pick a font.",
                        "Choose Raised or Sunk, tap the height or depth to change them, and tap Done."],
                tips: ["Letters 5 mm tall and 0.6 to 1 mm deep print cleanly on most printers.",
                       "Sunk text on a face that prints facing up comes out crisper than raised text on a side.",
                       "The letters are saved with the project, so they rebuild the same on any iPad.",
                       "To change text later, tap a letter and choose Edit Text."])
        case .screwLid:
            HelpOverview(
                summary: "Make a container and its lid screw together in one step: the neck gets a raised thread, and a lid comes with it, already screwed on.",
                steps: ["Make the container first, such as a shelled cylinder with an open top.",
                        "Choose Joints, then Screw Lid, and tap the outside of the neck. Or select that face and tap Screw Lid above the dock.",
                        "Pitch, Starts, and Turns set the thread: two starts close the lid in about a turn. Top, Height, and Grip set the lid.",
                        "Tap Done. The container and the lid are separate solids; move the lid aside to print them both."],
                tips: ["Check the fit with Section before printing: the lid's ridges sit between the neck's with the clearance all round.",
                       "The thread uses the printable 45° profile, so the container prints upright and the lid upside down without supports.",
                       "Print a short ring and collar first if you are unsure of your printer's clearance."])
        case .thread:
            HelpOverview(
                summary: "Make a real screw thread in a hole (like a nut) or on a round boss (like a bolt), ready to print: cut into the face, or raised onto it.",
                steps: ["Choose Joints, then Thread, and tap the inside of a hole or the side of a round boss. Or select that face and tap Thread above the dock.",
                        "The bar shows the face's diameter, and the size that best fits it is picked for you. The message above the bar says how the thread fits.",
                        "Cut cuts grooves into the face. Raised adds ridges onto it instead, so a thin wall stays whole: use it for a jar's neck or a thin-walled tube.",
                        "The same menu sets the profile: ISO 60° for screws and nuts, or Printable 45°, shallower, with flanks that print without supports either way up (the default for raised threads and custom ones of 20 mm and more). Raised ridges fade out over a quarter turn at their ends (Tapered Ends).",
                        "Size lists the sizes that fit the face as it is first, each with a note: Best fit, Full thread, or how much of a full thread's depth it gets. Other sizes cut the hole out or turn the boss down first; sizes that would miss the face are greyed out with the reason. Inch sizes (UNC/UNF) are in their own submenu, and Custom Diameter takes any size, such as a jar lid's.",
                        "Pitch is the distance between crests: each size's standard (coarse) pitch and its fine ones, or any pitch you type.",
                        "Length threads the whole face, or only part of it from the open end, like a bolt with a plain shank.",
                        "Options sets the hand (left-hand tightens counterclockwise), the 45° lead-in at open ends, and the number of starts.",
                        "Tap Done when the preview shows."],
                tips: ["Which sizes fit: in a hole, the thread must be bigger than the hole, and is full when the hole is no wider than the thread's root (about the tap-drill size: M8 needs 6.8 mm or less). On a boss, the thread's root must be inside the boss, and it is full when the boss is at least the thread's size.",
                       "A thread with less than about 60% of its depth may strip. Choose a size the note calls a full thread, or change the hole or boss.",
                       "A cut thread on a hollow part eats into its wall: the message warns when less than 1 mm of wall would stay behind it. Choose Raised to keep the wall whole.",
                       "A raised thread on a boss stands on it, so the boss is the thread's minor diameter: a 60 mm neck with a 3 mm pitch takes a 63.25 mm thread. In a hole the wall is its major diameter. Its matching part fits it like any other.",
                       "Holes open up and bosses slim down by the clearance, so printed threads turn freely. Clearance stands in for a tolerance class: try the Fit Test to find yours. A metal screw in a printed hole needs only the hole's clearance.",
                       "More starts wind 2 to 4 ridges side by side, so a lid closes in fewer turns (each turn advances the pitch times the starts). Its matching part gets the same starts.",
                       "Threads finer than about 0.8 mm pitch are hard to print on most FDM printers; M5 and larger work best. Fine pitches under 0.5 mm suit resin printers.",
                       "To make the part that screws on, tap the finished thread and choose Matching Part.",
                       "To change a thread later, tap it and choose Edit Thread. A matching part already made keeps its own thread: edit it too, or make it again.",
                       "Mirroring a threaded part makes its threads left-hand."])
        case .matingPart:
            HelpOverview(
                summary: "Make the part that screws onto a thread: a nut or cap for a bolt's thread, a bolt or plug for a hole's.",
                steps: ["Tap the thread (or select a solid with one thread).", "Choose Matching Part above the dock, then the kind of part.",
                        "It appears already screwed on, so you can see it fits. Move it aside, or export with Arrange on Plate, to print the parts separately."],
                tips: ["It gets the same size, clearance, and hand as the thread, so the two turn together once printed.",
                       "A cap's ceiling rests on the end of the thread; a bolt's or plug's head sits on the face the hole opens onto.",
                       "Print a cap or plug with its flat top on the plate.",
                       "Edit Thread changes the thread's size, pitch, or length after it is made."])
        case .fitTest:
            HelpOverview(
                summary: "A small print that finds the right clearance for your printer.",
                steps: ["Choose Joints, then Fit Test (or Add a Fit Test Print under Fit Clearance in the project menu). A plate with seven holes and a loose peg appear beside your model.",
                        "Export and print both.",
                        "Try the peg in each hole, starting at the beveled corner. The holes leave 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, and 0.40 mm around the peg.",
                        "Set Fit Clearance in the project menu to the first hole the peg slides into (snug), or one looser for parts that should move freely."],
                tips: ["Print it with the same printer, material, and settings as your parts.", "Delete the coupon from the Model Tree when you are done."])
        case .split:
            HelpOverview(
                summary: "Split Body cuts a solid into separate pieces without removing anything.",
                steps: ["Tap the solids to split.", "Tap Splitting Tools, then a plane, flat face, sketch shape, or sketch line.", "Tap Done."],
                tips: ["Several cutters can split it more than once.", "Parts that end up apart, even on the same side, become separate solids."])
        case .align:
            HelpOverview(
                summary: "Align moves a solid so one of its faces, edges, or corners meets another.",
                steps: ["Tap the solids to move.", "Tap From, then a face, edge, or corner on them.", "Tap To, then where it should go.", "Tap Done."],
                tips: ["Flip turns it over. Drag the arrow to leave a gap.", "To line up round parts, tap a cylinder's side: it picks the rim nearer your tap."])
        case .mirror:
            HelpOverview(
                summary: "Mirror makes a reflected copy across a plane.",
                steps: ["Tap the solids and sketches to mirror.", "Tap Mirror Plane, then a plane, flat face, or sketch line.", "Tap Done."],
                tips: ["Turn off Keep Input to replace them instead of copying."])
        case .pattern:
            HelpOverview(
                summary: "Pattern makes evenly spaced copies, in a row, a grid, or around a circle.",
                steps: ["Tap the solids and sketches to copy.", "Linear: drag an arrow. Circular: drag a ring.", "Set the count with − and +, then tap Done."],
                tips: ["The count includes the original.", "Up to 100 copies."])
        case .offsetPlane:
            HelpOverview(
                summary: "Make a new flat plane parallel to a face or another plane, at a set distance.",
                steps: ["Tap a flat face, sketch shape, or plane.", "Drag the double-arrow or tap the distance.", "Tap Done."],
                tips: ["Sketch on the new plane to build parts at different heights."])
        case .midplane:
            HelpOverview(
                summary: "Make a plane exactly halfway between two parallel faces or planes.",
                steps: ["Tap the first face or plane.", "Tap the second one, parallel to the first.", "Tap Done."],
                tips: ["Useful for mirroring a part across its middle."])
        case .project:
            HelpOverview(
                summary: "Project copies the outline of existing geometry flat onto a plane, as a new sketch.",
                steps: ["Tap the sketches, edges, faces, or solids to copy.", "Tap Target Plane, then the face, plane, or sketch to draw onto.", "Tap Done."],
                tips: ["The copy does not update if the original changes later."])
        case .measure:
            HelpOverview(
                summary: "Check sizes, distances, and angles without changing anything.",
                steps: ["Tap a corner, edge, face, or sketch item to see its size.", "Tap a second item for the distance and angle between them.", "Tap Done."],
                tips: ["Double-tap a solid for its volume and overall size."])
        case .assistant:
            HelpOverview(
                summary: "The assistant is changing the model for you. Look over the result before keeping it.",
                steps: ["Check the preview on the canvas.", "Tap Keep to add the change, or Discard to leave the model as it was."],
                tips: ["A kept change is one step you can undo."])
        }
    }

}

struct HelpOverview {
    var summary: String
    var steps: [String]
    var tips: [String]
}

extension ModelingSession {
    /// The help topic for the current tool, operation, or selection (in the same order as `hint`).
    var helpTopic: HelpTopic {
        if isAssistantWorking || isReviewingAssistant { return .assistant }
        if dimensionEdit != nil { return .keypad }
        if section != nil { return .section }
        if tool == .measure { return .measure }
        if tool == .dimension { return .dimension }
        if isExtruding {
            if faceExtrusion != nil { return .extrudeFace }
            return isCutting ? .cut : isJoining ? .join : .extrude
        }
        if revolveDraft != nil { return .revolve }
        if alignDraft != nil { return .align }
        if subtractDraft != nil { return .subtract }
        if let unionDraft { return unionDraft.intersect ? .intersect : .union }
        if shellDraft != nil { return .shell }
        if holeDraft != nil { return .hole }
        if pegDraft != nil { return .peg }
        if threadDraft != nil { return .thread }
        if screwLidDraft != nil { return .screwLid }
        if textDraft != nil { return .text }
        if let finishDraft { return finishDraft.kind == .chamfer ? .chamfer : .fillet }
        if tool == .offsetPlane { return .offsetPlane }
        if tool == .midplane { return .midplane }
        if projectionDraft != nil { return .project }
        if mirrorDraft != nil { return .mirror }
        if patternDraft != nil { return .pattern }
        if scaleDraft != nil { return .scale }
        if deleteFaceDraft != nil { return .deleteFace }
        if splitDraft != nil { return .split }
        if isPickingPlane { return .sketchPlane }
        if selectedConstructionPlane != nil { return .constructionPlane }
        if isMultipleSelection { return pickedBodies.count > 1 ? .pickedSolids : pickedEdges.count > 1 ? .pickedEdges : .pickedSketches }
        if selectedSketch != nil { return .sketchObject }
        if selectedBody != nil, tool == .select { return .solid }
        if selectedGroup != nil, tool == .select { return .modelGroup }
        if selectedEdge != nil { return .edge }
        if selectedShape != nil { return .editShape }
        if selectedFace != nil {
            if let finish = selectedFinish { return finish.kind == .fillet ? .fillet : .chamfer }
            if selectedThread != nil { return .matingPart }
            switch selectedFeature {
            case .hole: return .hole
            case .text: return .text
            case .peg: return .peg
            case .thread, nil: return .face
            }
        }
        switch tool {
        case .select: return sketchMode != nil ? .sketching : xrayAll || !xrayBodies.isEmpty ? .xray : .gettingStarted
        case .line: return .line
        case .rectangle: return .rectangle
        case .circle: return .circle
        case .arc: return .arc
        case .slot: return .slot
        case .ellipse: return .ellipse
        case .point: return .point
        case .polygon: return .polygon
        case .extend: return .extend
        case .offset: return .offset
        case .sketchMirror: return .sketchMirror
        case .cornerFillet: return .sketchFillet
        case .trim: return .trim
        case .dimension: return .dimension
        case .measure: return .measure
        case .extrude: return .extrude
        case .revolve: return .revolve
        case .fillet: return .fillet
        case .chamfer: return .chamfer
        case .shell: return .shell
        case .hole: return .hole
        case .offsetPlane: return .offsetPlane
        case .midplane: return .midplane
        case .project: return .project
        case .split: return .split
        case .union: return .union
        case .subtract: return .subtract
        case .intersect: return .intersect
        case .align: return .align
        case .mirror: return .mirror
        case .pattern: return .pattern
        case .scale: return .scale
        case .deleteFace: return .deleteFace
        case .peg: return .peg
        case .fitTest: return .fitTest
        case .thread: return .thread
        case .text: return .text
        case .box, .cylinder, .sphere, .torus: return .primitives
        case .planeAngle: return .planeAngle
        case .plane3Point: return .plane3Point
        case .planeTangent: return .planeTangent
        case .axis: return .axis
        case .spline: return .spline
        case .draft: return .draft
        case .rib: return .rib
        case .loft: return .loft
        case .sweep: return .sweep
        case .screwLid: return .screwLid
        }
    }
}
