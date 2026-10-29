import SwiftUI

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let card = Color("ss-white")
private let canvas = Color("ss-canvas")
private let hairline = Color("ss-border")

/// One topic of the Controls guide: what a tool or part of the app does, in plain words.
struct GuideTopic: Identifiable {
    let title: String
    let icon: SSIcon
    let paragraphs: [String]
    /// A Pro tool's topic, marked PRO while Pro is not owned.
    var isPro = false
    var id: String { title }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || paragraphs.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// A chapter of the guide, in the order a part is made.
struct GuideChapter: Identifiable {
    let id: String
    let title: String
    let summary: String
    let icon: SSIcon
    let topics: [GuideTopic]
}

/// The Controls guide (October 28, 2026; was a plain list): the whole manual in chapters, opened by
/// Controls at the bottom right, the project menu, and the help card's All Controls. A violet card
/// sums up how the app is used, chips jump to a chapter, a search finds any topic, and each topic is a
/// card with its tool's brand icon. Light only, like the editor.
struct ControlsGuide: View {
    var onDone: () -> Void
    @ObservedObject private var license = LicenseStore.shared
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        let search = query.trimmingCharacters(in: .whitespaces)
                        if search.isEmpty {
                            hero
                            chapterChips(scroller)
                            ForEach(Self.chapters) { chapter in
                                chapterHeader(chapter).id(chapter.id)
                                ForEach(chapter.topics) { topicCard($0) }
                            }
                        } else {
                            let found = Self.chapters.flatMap(\.topics).filter { $0.matches(search) }
                            if found.isEmpty {
                                Text("Nothing in the guide mentions \u{201C}\(search)\u{201D}.")
                                    .font(.system(size: 16)).foregroundStyle(muted).padding(.top, 24)
                                    .frame(maxWidth: .infinity)
                            }
                            ForEach(found) { topicCard($0) }
                        }
                    }
                    .padding(20)
                }
            }
            .background(canvas)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the guide")
            .navigationTitle("Controls").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).accessibilityIdentifier("guide.done") } }
        }
        .tint(violet)
        // The light-only design: in Dark Mode a sheet from the editor would otherwise turn dark under the brand ink.
        .preferredColorScheme(.light)
    }

    /// How the app is used, in three tiles: what the Pencil does, what fingers do, and where help is.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How Swipe & Sketch works").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(paper)
                .accessibilityAddTraits(.isHeader)
            Text("Sketch an outline, make it solid, then shape it for your printer. Here is everything, chapter by chapter.")
                .font(.system(size: 16)).foregroundStyle(paper.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                heroTile(.line, "Apple Pencil", "Draws, picks, and drags geometry.")
                heroTile(.resetView, "Fingers", "Orbit, pan, and zoom the view.")
                heroTile(.help, "Help button", "Beside the hint, for what you are doing now.")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(violet, in: RoundedRectangle(cornerRadius: 20))
    }

    private func heroTile(_ icon: SSIcon, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SSIconTile(icon: icon)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(paper)
            Text(detail).font(.system(size: 13)).foregroundStyle(paper.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(paper.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// One chip per chapter; a tap scrolls to it.
    private func chapterChips(_ scroller: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.chapters) { chapter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { scroller.scrollTo(chapter.id, anchor: .top) }
                    } label: {
                        HStack(spacing: 6) {
                            SSIconGlyph(icon: chapter.icon, size: 18, color: ink)
                            Text(chapter.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(card, in: Capsule())
                        .overlay(Capsule().stroke(hairline.opacity(0.7)))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("guide.chapter.\(chapter.id)")
                }
            }
        }
    }

    private func chapterHeader(_ chapter: GuideChapter) -> some View {
        HStack(spacing: 12) {
            SSIconGlyph(icon: chapter.icon, size: 26, color: paper)
                .frame(width: 40, height: 40).background(violet, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title).font(.system(size: 22, weight: .bold)).foregroundStyle(ink)
                Text(chapter.summary).font(.system(size: 14)).foregroundStyle(muted)
            }
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    private func topicCard(_ topic: GuideTopic) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SSIconTile(icon: topic.icon)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(topic.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                    if topic.isPro && !license.access.ownsPro {
                        Text("PRO").font(.system(size: 9, weight: .heavy)).foregroundStyle(paper)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(violet, in: Capsule())
                            .accessibilityLabel("Pro")
                    }
                }
                ForEach(topic.paragraphs, id: \.self) { paragraph in
                    Text(paragraph).font(.system(size: 15)).foregroundStyle(ink.opacity(0.85))
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.6)))
        .accessibilityElement(children: .contain)
    }

    static let chapters: [GuideChapter] = [
        GuideChapter(id: "basics", title: "Getting Around", summary: "How Pencil, fingers, and the toolbars work.", icon: .help, topics: [
            GuideTopic(title: "Pencil", icon: .line, paragraphs: [
                "Tap Sketch, then draw with Apple Pencil: on the grid, or on one of the planes at the origin or a flat face (tap it first to look straight at it). Line is ready; Rectangle and Shapes (Circle and more) are beside it.",
                "Sketch on a solid: with no tool chosen, tap a flat face with Pencil, then tap Sketch (in the selection strip or the dock). The view turns to face it, strokes stay on that face, and purple dots on its corners, edge midpoints, and center are snap points. Finish Sketch ends the sketch. Tapping a view cube face while sketching moves the sketch to Top, Front, or Right.",
                "With no tool chosen, a tap picks a face and a quick double-tap picks the whole solid. A tap near a solid's edge picks the edge: drag its arrow to round it, or choose Fillet or Chamfer. A tap on a sketch line opens that sketch where you are looking, so you can keep drawing into it at an angle; a quick double-tap selects the whole sketch.",
                "A sketch you extruded is hidden under its solid. Choose a drawing tool on its plane (then tap the tool again to put it down) and it shows again so you can tap it, or pick it from the Model Tree.",
                "While sketching, lining the Pencil up horizontally or vertically with a purple dot snaps to that line and shows a dashed purple guide; lining up with two dots locks to where the guides cross, such as a face's center. Tap Rectangle again to switch between drawing from corners and drawing from the center. A rectangle drawn from its center stays centered when you change its width or height or drag a corner, and has a center handle to move it.",
                "Select a sketch. Its dimensions appear beside it. Tap a value with Pencil or a finger to open the numeric keypad.",
                "With no tool chosen, drag endpoints to change lines, rectangle corners or edges to resize, or a circle's circumference to change its diameter. Drag the circle center to reposition it.",
            ]),
            GuideTopic(title: "Touch", icon: .resetView, paragraphs: ["One finger orbits. Two fingers pan. Pinch to zoom. Fingers never draw or drag sketch geometry. The view cube rotates with the camera: tap any face to look straight at it and choose the plane for new sketches. Opposite faces share the same sketch plane. Double-tap the cube to reset and frame the model in 3D. During extrusion, the cube changes the view while keeping the extrusion's sketch plane."]),
            GuideTopic(title: "Toolbar", icon: .more, paragraphs: ["Tools live in the dock at the bottom, in the order a part is made. While modeling: Sketch, Project, and Planes (Offset Plane, Midplane, Plane at Angle, 3-Point Plane, Tangent Plane, Axis) to build on; Create (Extrude, Revolve, Loft, Sweep, Rib, Box, Cylinder, Sphere, Torus) to make solids; Modify (Fillet, Chamfer, Shell, Draft, Delete Face, Split Body) to change one; Combine (Union, Subtract, Intersect) to join or cut solids with each other; Transform (Align, Scale, Mirror, Pattern) to move, resize, and copy; and Joints (Peg & Socket, Thread, Screw Lid, Fit Test) for parts that fit together. A tile with ▴ pops up its tools above it and shows the one in use. Tap Sketch and the dock switches to sketch tools until you tap Finish Sketch: Line, Rectangle, Shapes (Circle, Arc, Slot, Ellipse, Polygon, Spline, Point), Features on a face (Hole, Peg & Socket, Text), Modify (Trim, Extend, Fillet, Offset, Mirror), Dimension, and Project. The rail at the top left opens the Model Tree and the Assistant, then Measure, Section, X-ray, and Snap; the view cube is at the top right. There is no Select tool: with no tool chosen, a tap selects; tap the active tool again to put it down. What you can do with the selection appears in the strip just above the dock, grouped the same way: for a solid, its volume, Shell, Split Body, Combine (Union, Subtract, Intersect) when there are other solids, Transform (Align, Scale, Mirror, Pattern), Matching Part for a thread, Color, and the trash can for Delete, which removes whole items only (Duplicate is in the Model Tree and on ⌘D); a face, edge, region, sketch, or plane offers what suits it, and a face of a finished hole, thread, text, or peg offers Edit. While an operation is being set up, its own controls and Done replace the dock. A hand resting on the dock while the Pencil draws presses nothing."]),
        ]),
        GuideChapter(id: "sketching", title: "Sketching", summary: "Drawing outlines on a plane or a face.", icon: .sketch, topics: [
            GuideTopic(title: "Sketches", icon: .sketch, paragraphs: ["Tap Sketch, then one of the three planes at the origin (or a flat face) to start a new sketch; the view turns to face it and the origin is marked. Everything you draw until you leave belongs to that sketch, and the Model Tree lists each sketch with its shapes. Purple dots also mark where other sketches and solid edges cross the plane. Leaving a sketch selects all of it: drag an arrow to move it or an arc to turn it, tap the value to type an exact distance or angle, and turn on Create Copy to make copies instead. A selected solid (double-tap one of its faces) moves, turns, and copies the same way, with everything done to it. Hide or Show any sketch or solid from the Model Tree."]),
            GuideTopic(title: "Regions", icon: .rectangle, paragraphs: ["Shapes in a sketch divide each other where they cross: two overlapping rectangles make three regions, and a line across a rectangle makes two. Tap inside a region to select it. An outline inside a region, such as a circle in a rectangle, is a hole in it, and the circle is a region of its own. A selected shape (just drawn, or picked from the Model Tree) extrudes all of itself."]),
            GuideTopic(title: "Picking Several", icon: .select, paragraphs: ["With a region or a whole sketch selected, tap more regions, or the lines of more sketches, on the same plane to pick them too; tap a picked one to take it out. Extrude or Revolve then takes them all in one step. With a solid selected, double-tap another solid to add it: the widget moves them all, and Combine, Transform, Color, Export, and Delete take them all. With an edge selected, tap more edges of the same solid, then Fillet or Chamfer rounds or bevels them all. Inside an open sketch, tap more regions the same way. Tap empty space to start over."]),
            GuideTopic(title: "Arc and Slot", icon: .arc, paragraphs: ["In a sketch, tap Shapes to find Arc and Slot with Circle. Arc: drag from one end to the other, curving the stroke through the middle; the arc passes through the point farthest from its ends. Drag its ends or middle dot to reshape it, or tap its radius. Slot: drag from the center of one round end to the other's; it is drawn at the last width used. Drag its ends or its edge, or tap its length or width."]),
            GuideTopic(title: "More Sketch Tools", icon: .spline, paragraphs: ["Shapes ▸ Ellipse, Polygon (tap the number of sides afterward to change it), Point, and Spline: draw a curve freehand and it becomes a smooth spline through a few points you can drag; end where you began to close it into a region. Modify ▸ Extend carries a line on to the next shape; Offset draws an outline a set distance away (Both Sides for a wall); Mirror copies shapes across a line. Select a shape and tap Construction to make it a dashed reference, and drag its arrows to move it within the sketch."]),
            GuideTopic(title: "Trim and Sketch Fillet", icon: .trim, paragraphs: ["Tap Modify in the sketch dock, then Trim, then tap or scribble over part of a shape: the part goes, back to where other shapes cross it. A shape nothing crosses goes whole. Each stroke is one undo step; tap empty space to finish. Fillet in the same group rounds a corner where two lines meet (a rectangle's too): tap the corner. Tap the radius that appears to type another; it stays one undo step."]),
            GuideTopic(title: "Dimension", icon: .dimension, paragraphs: ["While sketching, tap Dimension, then a point (a line end, a corner, a circle's center, a purple dot of a solid, or the origin), a line, or a circle. One line shows its length and its angle. Tap a second item for the distance across and up between them, or the angle between two lines. Tap a value to type a new one: the second item moves to match. Joined to the first, it changes the outline in place; otherwise its whole outline moves. Tap empty space to start again. Dimensions are not kept afterwards."]),
            GuideTopic(title: "Project", icon: .project, paragraphs: ["Tap Project in the dock to cast existing geometry onto a plane as a sketch. Tap the sketches, edges, faces, or solids to project (tap again to unpick; double-tap a solid or sketch for all of it), or select one first. Then tap Target Plane and the flat face, construction plane, world plane at the origin, or sketch to project onto. The surface turns purple and the projection previews on it; Done adds it as a new sketch, or into the sketch you tapped. Inside a sketch, Project goes into that sketch. Lines stay lines, and circles and arcs facing the surface stay exact, so projected outlines extrude with smooth curved sides; circles seen at an angle and the outlines of curved faces become curves. The projection is a copy: it does not follow later changes."], isPro: true),
        ]),
        GuideChapter(id: "solids", title: "Making Solids", summary: "Turning sketches into solids, and solids from scratch.", icon: .extrude, topics: [
            GuideTopic(title: "Construction Planes", icon: .offsetPlane, paragraphs: ["Tap Planes in the dock, then the kind of plane. Offset Plane: tap a flat face, sketch region, plane, or one of the planes at the origin (or select it first); the new plane starts on it, so drag the double-arrow or tap the value for an exact distance (negative goes the other way). Midplane: tap two parallel faces, regions, or planes and the plane lands halfway between them. Plane at Angle: tap a straight edge or sketch line, then type the angle it turns about it (0° lies on the face beside the edge, 90° stands straight up). 3-Point Plane: tap three corners, sketch points, or the origin. Tangent Plane: tap a round face where the plane should touch it. Done adds the plane. Axis makes a construction line instead: tap a round face or circular edge for its center line, a straight edge or sketch line, or two points; Revolve, Mirror, and Align pick it like a sketch line. Select a plane to sketch on it or offset from it; hide or delete it from the Model Tree."]),
            GuideTopic(title: "Extrude", icon: .extrude, paragraphs: ["Select a closed region, then Extrude. It starts at 0 mm on the sketch plane. Drag the double-arrow outward along its direction to increase depth or back to decrease it, including through the sketch plane; dragging toward a solid moves into it. Tap the outlined value above the arrow for the same keypad used by sketch dimensions. Done creates a separate solid; Cancel discards the preview."]),
            GuideTopic(title: "Extrude Options", icon: .taper, paragraphs: ["While extruding a sketch: Symmetric goes half each way, Taper leans the sides in by an angle, Up To sets the depth to reach a face you tap, and tapping more regions extrudes them too."]),
            GuideTopic(title: "Extrude a Face", icon: .extrudeTo, paragraphs: ["Tap a flat face of a solid, then Extrude (or tap the face with the Extrude tool). It starts at 0 mm on the face: drag the double-arrow out to add material to the solid or in to cut into it, or tap the value to type the size the solid ends up across the face (pull the top of a 20 mm box 5 mm and it reads 25 mm; on a face with nothing parallel behind it, the value is how far the face moves, negative going in). Holes and rounded edges in the face carry through. Done applies it as one undo step."]),
            GuideTopic(title: "Join", icon: .solid, paragraphs: ["Extrude a sketch out of a solid's face (or anywhere it touches a solid) and it joins that solid: Extrude switches to Join automatically and the merged solid previews live. Done makes the boss part of the solid, so later holes can go through both. Choose New Body to keep it separate."]),
            GuideTopic(title: "Holes and Cuts", icon: .cut, paragraphs: ["Draw a circle (for a hole) or any closed outline on a plane that crosses or touches a solid, then Extrude and choose Cut. Drag the depth for a pocket, or turn on Through All to cut straight through every solid on both sides of the sketch plane. The red tool shows what is removed and the solids preview with the cut. Dragging into a solid switches to Cut automatically, and back out returns to New Body, until you choose one yourself. Done cuts every solid the tool touches as one undo step. While sketching or extruding, sketches on the active plane show through solids, and the Extrude tool picks regions even inside a solid."]),
            GuideTopic(title: "Revolve", icon: .revolve, paragraphs: ["Select a closed region (or a flat face of a solid), then Revolve, from the selection strip or Create in the dock. Tap the axis to turn it around: a sketch line or one side of a rectangle, a straight edge of a solid, or the X, Y, or Z axis, lying in the region's plane along its edge or beside it (never through it). Drag the curved arrow around the axis, or tap the angle for the keypad; 360° goes all the way around, and a negative angle turns the other way. Tap another line to change the axis. Like Extrude, sweeping into a solid cuts it and touching one joins it, until you choose New Body, Join, or Cut. A face revolve joins or cuts its own solid. Done is one undo step; select the solid later to change its angle."]),
            GuideTopic(title: "Box, Cylinder, Sphere, Torus", icon: .primitives, paragraphs: ["Create ▸ Box, Cylinder, Sphere, or Torus makes a ready-made solid without sketching: tap the grid, or a flat face it should stand on, tap a size to type it, tap elsewhere to move it, then Done. The next one starts from the sizes used last. They are ordinary solids whose faces resize and push like any other."]),
            GuideTopic(title: "Loft and Sweep", icon: .loft, paragraphs: ["Create ▸ Loft blends between sketch regions on different planes, such as a square base into a round top: tap the regions in order, turn on Ruled for flat sides, and tap Done. Create ▸ Sweep carries a region along a path (a line, an arc, a spline, or joined lines): tap the region, then the path, which starts at the region on another plane; keep bends wider than the region. Each makes a new solid with its exact shape saved; changing the sketches afterwards does not change it."], isPro: true),
            GuideTopic(title: "Rib", icon: .rib, paragraphs: ["Sketch a line across a corner, on a plane through the solid (such as Front through the middle of a bracket), then choose Create ▸ Rib and tap the line. The rib grows from the line until it meets the solid. Tap the thickness to change it, or Flip for the other side of the line, then Done."], isPro: true),
        ]),
        GuideChapter(id: "changing", title: "Changing Solids", summary: "Holes, rounded edges, walls, and sizes.", icon: .fillet, topics: [
            GuideTopic(title: "Holes", icon: .hole, paragraphs: ["While sketching on a face, choose Features ▸ Hole and tap where it goes; it snaps to the purple dots. Pick Simple, Counterbore, Countersink, or Insert (heat-set) and a size from M2 to M5: dimensions start from standard metric hardware (ISO 273 clearance, socket-head counterbores, 90° countersinks, common brass inserts). Tap the diameter or depth to type your own; a counterbore or countersink widens with the hole. Through goes all the way; turn it off for a blind hole. Done adds the hole and keeps the Hole tool ready for the next one. To change it later, tap the hole's wall and choose Edit Hole above the dock."]),
            GuideTopic(title: "Text", icon: .text, paragraphs: ["Select a flat face and tap Text above the dock (or choose Features ▸ Text while sketching on a face), then tap where the text goes. Type it in the field, pick a font, and choose Raised (embossed) or Sunk (debossed). Tap the height (capital letters) or depth to type a value, and Rotate 90° to turn it. Tap elsewhere on the face to move it. The outline shows at once; the solid preview follows, and Done adds it as one step. The letters are saved in the project, so they rebuild the same on any iPad. To change them later, tap a letter and choose Edit Text."], isPro: true),
            GuideTopic(title: "Fillet and Chamfer", icon: .fillet, paragraphs: ["Choose Modify ▸ Fillet to round edges or Modify ▸ Chamfer to bevel them (or select an edge and tap Fillet or Chamfer above it), then tap the edges of a solid with Apple Pencil; tap again to deselect. Any edge works: the solid's own, and the edges of holes, cuts, joined bosses, united solids, shells, and earlier fillets. Drag the double-arrow up or down, or tap its value for the keypad. The preview shows the result; a red value does not fit the edges. Done applies it as one step, and Undo removes it."]),
            GuideTopic(title: "Shell", icon: .shell, paragraphs: ["Choose Modify ▸ Shell and tap the faces to leave open, such as a box's top (at least one): any face, including faces made by cuts, joins, Union, or Subtract, and curved faces where the wall can be built. Or select a face (or a solid) and tap Shell beside it. Drag the double-arrow or tap the thickness for the wall. Done, or a tap on empty space, hollows the solid inward, keeping its outside size. Shell before rounding every edge: a fully rounded box cannot be hollowed."], isPro: true),
            GuideTopic(title: "Draft", icon: .draft, paragraphs: ["Modify ▸ Draft leans faces a few degrees, so a printed mold releases its casting: tap the flat face the draft leans from (it stays put), then the faces to lean, and tap the angle to change it (negative leans outward). A face square to the pull, like a box's top, cannot be drafted. Done adds it to the solid."], isPro: true),
            GuideTopic(title: "Sizes From Faces", icon: .dimension, paragraphs: ["Tap a face of a solid. A round face shows its diameter and a flat face its distance to the face behind it; tap the value to type a new one. The solid's own circle, depth, hole, or outline changes when it can; otherwise the face moves and the faces around it follow. Delete Face (beside it, or under Modify) takes faces off and closes the gap, removing a fillet, hole, or boss. For a round hole, tap its wall and choose Delete Hole: the whole hole goes in one tap, with any thread in it and fillets on its rim, as if it had never been made."]),
            GuideTopic(title: "Split Body", icon: .split, paragraphs: ["Tap Modify in the dock, then Split Body (or select a solid and tap Split Body above the dock). Tap the solids to split, then Splitting Tools and what to cut them with: a construction plane, one of the planes at the origin, a flat face of any solid (even the one being split, such as the inside face of an L), a sketch region (cut along its outline, straight through), or a sketch line (cut along the plane through it, square to its sketch). Tools reach through the whole solid, and several cut again. Nothing is removed: the pieces become separate solids that add up to the original. Turn on Keep Input to keep the solid too. Done is one undo step. Pieces that do not touch each other become separate solids, as they do after any cut."], isPro: true),
        ]),
        GuideChapter(id: "combining", title: "Combining and Moving", summary: "Putting solids together, moving, resizing, and copying them.", icon: .merge, topics: [
            GuideTopic(title: "Union", icon: .merge, paragraphs: ["Tap Combine in the dock, then Union (or, with two or more solids, select one and choose Combine ▾ → Union above the dock), then tap the solids to unite; tap one again to leave it out. The last one you tap is the target, outlined in purple, and the others join it. They must touch or overlap, in a chain if you like. The preview shows the united solid; Done makes it one solid that keeps everything done to each. Turn on Keep Input to add the united solid as a new one and keep the input solids too."]),
            GuideTopic(title: "Subtract", icon: .subtract, paragraphs: ["Tap Combine in the dock, then Subtract (or select a solid and choose Combine ▾ → Subtract above the dock). Tap the solids to subtract from (the targets, outlined in purple; a selected solid starts as one), then Tools and the solids to take away (blue). Each target loses whatever the tools overlap; a tool that overlaps no target, or a target no tool reaches, is named in the hint. Keep: None keeps only the results; Targets adds the results as new solids and keeps the targets; Tools keeps the tools; Targets & Tools keeps both. Done is one undo step."]),
            GuideTopic(title: "Intersect", icon: .intersect, paragraphs: ["Combine ▸ Intersect (or Combine ▾ → Intersect above a selected solid) keeps only where the picked solids overlap."]),
            GuideTopic(title: "Align", icon: .align, paragraphs: ["Tap Transform in the dock, then Align (or select a face or edge and tap Align above it, or a solid and choose Transform ▾ → Align). Tap the solids to move, then From and the flat face, round edge, or straight edge on them to align, then To and where it goes: a face, construction plane, plane at the origin, or sketch region for a face (they meet face to face, centered on a face); a round edge or sketch circle for a round edge (concentric); a straight edge or sketch line for a straight edge (end to end, centered); a corner of another solid, a sketch point, or the origin for a corner (point to point: it just moves there). Pickable points show as small dots, and a tap near a corner picks the point rather than its edges. Flip turns it over; drag the double-arrow or tap the values to offset it or turn it about the target. Done moves the solids as one undo step."]),
            GuideTopic(title: "Scale", icon: .scale, paragraphs: ["Transform ▸ Scale (or Transform ▾ → Scale above a selected solid or sketch) makes solids and sketches larger or smaller: drag an arrow or type the percentage, about their center, their base, or the origin; turn off Uniform to stretch a solid along one arrow."]),
            GuideTopic(title: "Mirror", icon: .mirror, paragraphs: ["Tap Transform in the dock, then Mirror (or select a solid or sketch and choose Transform ▾ → Mirror above it). Tap the solids and sketches to mirror, then Mirror Plane and the plane to mirror across: one of the planes at the origin, a construction plane, a flat face, a sketch region's plane, or a sketch line (the plane through it, square to its sketch). Keep Input is on: the mirror images are new solids and sketches beside the originals; turn it off to replace them. A mirrored solid is an ordinary solid: its fillets, holes, cuts, and shells come along, and it can be edited, moved, or filleted like any other. Done is one undo step."]),
            GuideTopic(title: "Pattern", icon: .pattern, paragraphs: ["Tap Transform in the dock, then Pattern (or select a solid or sketch and choose Transform ▾ → Pattern above it). Tap the solids and sketches to copy. Linear: drag one of the gizmo arrows to lay copies out along it, and others for a grid; Extent spreads the copies across the distance, Spacing is the gap between neighbors. The quantity (− and +, or tap it to type it) counts the original and applies to the last arrow dragged. Circular: drag the gizmo center onto a corner, edge, circle center, or face center of any solid, a sketch point, or the origin (on a circle or edge the gizmo turns to follow it), then turn a ring; Rotated copies turn with the pattern, Fixed ones keep their orientation. Tap a value to type it. Done adds the copies as ordinary, independent solids and sketches in one undo step; a pattern makes at most 100."], isPro: true),
        ]),
        GuideChapter(id: "fit", title: "Parts That Fit", summary: "Clearances, threads, and lids for printed parts that go together.", icon: .fit, topics: [
            GuideTopic(title: "Joints and Fit Clearance", icon: .fit, paragraphs: ["Printed parts that go together need a small gap. Set Fit Clearance in the project menu once for your printer: Tight (0.1 mm), Standard (0.2 mm), Loose (0.3 mm), or Custom. To find yours, choose Add a Fit Test Print in the same menu (or Joints ▸ Fit Test). Joints ▸ Peg & Socket (or Features ▸ Peg & Socket while sketching on a face) puts a round peg on a flat face, and every solid it pushes into gets a matching socket, even a hidden one, so hide a lid to reach the rim under it. Tap a peg later and choose Edit Peg to change it; its sockets follow. Subtract's Clearance leaves that gap around the tools, so a part shaped like them fits; choose Keep: Tools to keep the part."], isPro: true),
            GuideTopic(title: "Threads", icon: .thread, paragraphs: ["Choose Joints ▸ Thread and tap the inside of a hole (a nut's thread) or the side of a round boss (a bolt's thread), or select that face and tap Thread above the dock. A size is picked from the face: a hole near an M-size's tap-drill diameter, a boss near its diameter, or a custom thread fitted to the face. The Size menu lists metric M2 to M36 and inch #4 to 3/4 (UNC and UNF) and says how each fits the face; Pitch offers the fine pitches, or tap the diameter or pitch to type your own, such as a 3 mm pitch for a jar lid. Cut grooves the thread into the face; Raised adds its ridges onto it, so a thin wall keeps its thickness, and fades them out at their ends. The same menu picks the profile: ISO 60° for hardware, or Printable 45° (shallower, printing without supports either way up), the default for raised threads and custom threads of 20 mm and more. Length threads part of the face, and more starts close a lid in fewer turns. Holes open up and bosses slim down by the clearance. Left-hand turns the thread the other way. Lead-in (on unless you turn it off) bevels the open ends so the thread starts straight. The preview takes a moment to build; Done adds the thread as one step, and Edit Thread (tap the thread) changes it later. A matching part made before keeps its own thread, so make it again after an edit. Then tap the thread and choose Matching Part above the dock for the nut or cap (on a bolt's thread) or bolt or plug (in a hole's) that screws onto it: it appears already screwed on, with the same size, hand, and clearance. Move it aside, or export with Arrange on Plate, to print the parts separately."], isPro: true),
            GuideTopic(title: "Screw Lid", icon: .screwLid, paragraphs: ["Joints ▸ Screw Lid (or Screw Lid above a selected round boss) makes a container and its lid screw together: tap the outside of the neck, such as a shelled cylinder's. The neck gets a raised thread in the printable 45° profile and a lid comes with it, already screwed on, as a solid of its own. Pitch, Starts (two close it in about a turn), and Turns set the thread; Top, Height, and Grip (Ribbed or Smooth) set the lid; Clearance starts from Fit Clearance. Test Print first adds a short ring with the thread and three collars to try it on (one, two, and three notches: 0.1 mm tighter, the clearance chosen, and 0.1 mm looser), in a Thread Fit Test group; the one that turns on smoothly is your clearance. Check the fit with Section, then Done adds both in one step. Move the lid aside to print the parts separately, the lid upside down."], isPro: true),
        ]),
        GuideChapter(id: "looking", title: "Looking and Asking", summary: "Measuring, looking inside, the Model Tree, and the assistant.", icon: .measure, topics: [
            GuideTopic(title: "Measure", icon: .measure, paragraphs: ["Tap Measure in the rail at the top left; a selected item becomes the first one measured. Tap a corner, edge, face, or sketch item to read its size: length, radius, area, or for a solid (double-tap a face) its volume and size. Tap a second item for the distance between them, its parts across, back, and up, and the angle between them. The results replace the dock; Done ends Measure. A selected edge, face, or solid also shows its size in the strip above the dock."]),
            GuideTopic(title: "Section View", icon: .section, paragraphs: ["Tap Section at the top left to cut the solids open along a plane and look inside; the cut faces are coral. Choose Top, Front, or Right, drag the arrow to move the cut, Flip for the other half, Done to finish. Nothing changes."]),
            GuideTopic(title: "X-ray", icon: .xray, paragraphs: ["Tap X-ray in the rail at the top left to see every solid through, or long-press a solid or group in the Model Tree and choose X-ray to see only it through. With one solid X-rayed, a tap goes through it to a part inside. X-ray changes nothing and is not saved."]),
            GuideTopic(title: "Model Tree", icon: .items, paragraphs: ["Tap Model Tree at the top left to list everything in the project under Bodies, Planes, and Sketches. Tap a row to select it, just like tapping it on the canvas, even a sketch hidden under the solid it made. Long-press a row to rename it, color a solid, copy, duplicate, paste, move it to a group, or delete; Paste also sits at the top of the list while something is copied (⌘C, ⌘V, and ⌘D work with a keyboard). Groups organize the tree: tap New Group at the top to make one (or choose Move to Group ▸ New Group on a row), then drag rows onto it or use Move to Group. A group can hold solids, sketches, planes, and other groups; tap its arrow to fold it away, and tap its eye to hide or show everything in it at once (each item keeps its own eye for when the group is shown again). Tap a group's name to select everything in it: drag the widget to move or turn it all (Create Copy copies the group), or use Transform or Export above the dock. Long-press a group to rename it, X-ray or duplicate it, make a group inside it, ungroup it (keeping its contents), or delete it with its contents. To act on several rows at once, tap Select at the top of the list, tap the rows to check them (hidden ones too; a shape's row follows its sketch), then use the bar at the bottom: Group puts them in a new group, Move puts them in a group or takes them out, Hide or Show, and Delete. Dragging a checked row onto a group moves them all. Tap Done to stop. Tap Model Tree again to close the list."]),
            GuideTopic(title: "Assistant", icon: .assistant, paragraphs: ["Tap Assistant in the rail at the top left to ask about the model or describe a change (with something selected, the request is about it), by typing, dictating, or writing with Apple Pencil. Changes preview on the canvas: Keep adds them as one step you can undo, and Discard leaves the model as it was; editing waits until you choose. Each reply lists the changes the app actually made. Automatic uses Private Cloud Compute when it is available and the on-device model otherwise; choose a model from the badge at the top of the panel."]),
        ]),
        GuideChapter(id: "files", title: "Projects and Printing", summary: "Saving, importing, exporting, units, and your plan.", icon: .send, topics: [
            GuideTopic(title: "Projects", icon: .open, paragraphs: [
                "Create and open .swipesketch projects in Files, on your iPad or in iCloud Drive. Completed changes save automatically. Use the project menu for New Project, Open Project, Save, or Save As; the home button returns to the Home screen.",
                "Save As creates and opens a separate editable copy. New Project opens the template gallery: Blank Project, or a template set up with a few sizes; the current project stays saved. Canceled file pickers leave your current project open. Finish an extrusion with Done before saving it.",
            ]),
            GuideTopic(title: "Import", icon: .mesh, paragraphs: ["Import STEP in the project menu brings in the solids of a .step or .stp file from Files, each as a solid of its own, where the file put them, converted to millimeters, together in a Model Tree group named after the file (hide or show them all with its eye). Open surfaces are joined into solids where they close. Imported solids are ordinary solids: move, rotate, mirror, align, cut, drill, shell, fillet any edge, combine, split, sketch on their faces, and export them. Their exact shapes are saved in the project, so it does not need the STEP file again. Import Mesh brings in STL and 3MF files the same way, such as downloaded models to remix: each closed mesh becomes a solid whose flat areas are single faces (a mesh with holes in it is left out; repair it in a mesh tool first)."]),
            GuideTopic(title: "Export", icon: .export, paragraphs: ["Export 3MF in the project menu makes a print-ready file: choose all visible solids or the selection (a solid, several picked solids, or a group), Arrange on Plate (side by side, each resting on the plate) or As Modeled, and your printer's plate. Each part is named as in the Model Tree, and a picture of the view is the file's preview. Export STL saves every visible solid in one watertight millimeter file. Both open the share sheet for AirDrop, Files, or a slicer app."]),
            GuideTopic(title: "Send to Slicer", icon: .send, paragraphs: ["Send to Slicer in the project menu makes the same print-ready 3MF and saves it into a print folder you choose once, such as a folder in iCloud Drive that the slicer on your Mac opens. Each send replaces the file there, so the newest version is always the one you open. Or share it with AirDrop or another app."]),
            GuideTopic(title: "Units", icon: .measure, paragraphs: ["Choose Millimeters or Inches under Units in the project menu. Values, the keypad, the grid, and snapping follow the choice; type in, mm, cm, or m after a number to give another unit. Projects always store millimeters."]),
            GuideTopic(title: "Free and Pro", icon: .brand, paragraphs: ["Swipe & Sketch is free for good, with no limit on projects or exports. Swipe & Sketch Pro, a one-time purchase in Your Plan (the project menu, or the Pro tile under Snap), adds the tools marked PRO: Shell, Draft, Split Body, Pattern, Project, Loft, Sweep, Rib, Thread, Matching Part, Screw Lid, Peg & Socket, Fit Test, and Text, every template but the Gridfinity Baseplate, Bin, and Bin with Label Shelf, the openGrid Board, Connector Pegs, Mounting Snaps, Metric Screw Snaps, and Interface Fit Test, the Spacer Set, Stylus Rest, Key Tag, and the Fit & Print Tests, Import STEP, and keeping the assistant's changes. A Pro tool works and previews as usual; its Done says Keep with Pro. Files that use Pro features open, change with the free tools, and export for everyone."]),
        ]),
    ]
}
