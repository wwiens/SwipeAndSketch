# Editable project files

Projects are native `.swipesketch` documents (type `noventix.SwipeAndSketch.project`), opened from the app's Home screen or from Files. A project contains its sketches, solids (extruded, revolved, imported, or made by templates and primitives) with the ordered steps that change them, construction planes, Model Tree groups, imported shapes, notes, and a picture for thumbnails. Users choose On My iPad, iCloud Drive, or another writable Files provider.

## User workflow

- The app opens on Home: recent projects with their pictures, Start Something (Blank Project and the template categories), Templates, and Files (the system document browser, for everything else). **New Project** opens the template gallery: Blank Project, or a template set up with a few sizes; then the file is named and placed.
- In the modeling header, the house returns to Home. The menu provides **Save**, **Save As…**, **New Project…**, and **Open Project…**.
- Committed geometry changes autosave. Save requests an immediate flush. An unconfirmed extrusion preview or unfinished keypad entry is not a committed model change; press Done or the keypad check first.
- New Project first saves the current project, then shows the template gallery and asks where to create the new project. Cancel keeps the existing project open. Each project starts with fresh selection and undo history.
- Save As writes an independent project with a new project ID, then opens that copy. Renaming and moving files are available in the native browser or Files app.
- A project inside the app's own folder (On My iPad › Swipe & Sketch, except the system Inbox) always opens in place; the browser is only moved to its folder. A file the app has just written may not be known to the Files provider yet, and revealing it with import would copy it into a same-named duplicate or report a failed import. Projects elsewhere are revealed through the browser, which imports them when needed.

## Why a native project format

The editable source is a small, documented JSON document, rather than a saved SceneKit scene or a printing mesh. This is an application format, not a claim of CAD interchange conformance. A flat file is sufficient for the current geometry; packaging or compression would add complexity without assets to bundle.

| Field | Meaning |
| --- | --- |
| `format` | `noventix.SwipeAndSketch.project` |
| `schemaVersion` | Format version: `2` (lean files, November 8, 2026); `1` still reads and is saved as `2`. A file with another version or `format` is refused, never partly read |
| `id` | Stable UUID for this project; Save As creates a new one |
| `createdAtMilliseconds`, `modifiedAtMilliseconds` | UTC Unix timestamps in milliseconds |
| `units` | Explicitly `millimeter` |
| `coordinateSystem` | Explicitly `right-handed-z-up` |
| `workspace` | Versioned sketches and solid definitions with stable object IDs |

Coordinates and dimensions remain full-precision Swift `Double` values through JSON encoding/decoding. No display rounding is applied to saved geometry. Sketch primitives retain their kind, plane, endpoints or center/radius definition. Each solid retains its own plane, profile outline, analytic circle where applicable, and signed extrusion distance. Deleting or editing a source sketch does not invalidate an independent existing solid. A polygon outline goes with a circle's analytic definition for previews; the kernel builds exact geometry from the analytic definition.

Centered rectangles: a rectangle drawn from its center carries `"centered": true`, an editing hint meaning width/height edits and corner drags keep its center. Its geometry is still the two stored corners, and the key is omitted when false.

Sketch planes: besides the three world planes below, a sketch, solid, or cut may lie on the plane of a flat solid face. Such a plane is stored as `{"origin": [x, y, z], "xAxis": [...], "yAxis": [...]}` with unit, orthogonal axes; the normal is `xAxis × yAxis` and positive extrusion follows it (outward from the face it was taken from). Face planes are canonical: the origin is the plane point nearest the world origin, and `yAxis` is world +Z projected onto the plane (world +Y for horizontal planes), so coplanar faces share one plane and a face lying on a world plane is that world plane. World planes keep their names (`"top"`, `"front"`, `"right"`).

The world plane mappings are fixed. For local sketch coordinates `(u, v)` and signed extrusion height `h`:

| Plane | World `(x, y, z)` | Positive extrusion normal |
| --- | --- | --- |
| `top` | `(u, v, h)` | +Z |
| `front` | `(u, -h, v)` | −Y |
| `right` | `(h, u, v)` | +X |

All three planes pass through the world origin. The kernel applies these mappings in double precision directly from saved geometry, and exports are built from the kernel's solids. The current SceneKit projection uses floats for display; those display conversions must not become the persisted or exported source.

Camera, selection, undo stack, lighting, edge strokes, and preview meshes are session or presentation state. They are regenerated when opening a file. They are not the authoritative model and must not be used as the export source.

SceneKit renders the scene. Committed solids are rebuilt from the saved definitions by the Open CASCADE kernel ([Kernel.md](Kernel.md)); the kernel's B-rep is derived state and is never saved, except for the exact shapes of imported solids, which have no other definition (*Imported solids*).

## Edge finishes

Added October 18, 2026. A solid may carry `finishes`, an ordered list replayed on its extrusion:

| Field | Meaning |
| --- | --- |
| `kind` | `fillet` (rounded, `size` is the radius) or `chamfer` (bevel, `size` is the setback distance) |
| `edges` | Original extrusion edges, each `{position, index}`: `base` / `cap` along profile segment `index` on the sketch plane or far end; `side` along the extrusion at profile corner `index` (polygons only). Circles have `base` 0 and `cap` 0 |
| `size` | Millimeters, 0.01 to 1,000 |
| `id` | Stable UUID |

Edges are named by their role, never by kernel edge number, because kernel numbering changes after every operation. Indices count real corners: collinear outline points (lines joined end to end) are skipped, since they extrude to one flat side. When the solid is rebuilt, each named edge is matched to the current kernel edge whose exact curve lies along it, so names survive depth edits and earlier finishes. An edge may appear in only one finish. Edges created by a fillet or chamfer, cut, or other operation have no name; they are finished by a finish entry in the `cuts` list, named by a point on them.

## Cuts

Added October 18, 2026. A solid may carry `cuts`, an ordered list of extruded profiles subtracted from it (holes, pockets, slots):

| Field | Meaning |
| --- | --- |
| `profile` | A full copy of the cut's sketch profile (plane, outline, analytic circle), independent of the source sketch |
| `depth` | Signed millimeters along the profile plane's normal from the sketch plane (ignored for through-all) |
| `throughAll` | When true, the cut spans the solid's full extent on both sides of the sketch plane |
| `id` | Stable UUID |

One Cut operation records a copy on every solid it removes material from, so solids stay independent. A solid is rebuilt as: extrude, then finishes in order, then cuts in order. Finish edge names refer to the uncut extrusion; edges created by cuts have no names. A cut that would remove the whole solid is rejected; one that leaves it in separate pieces makes each piece its own solid (see *Splits*).

## More operations

Added October 18, 2026. Three more kinds of entry can appear in a solid's ordered `cuts` list. Each carries a payload key; its `profile` and `depth` are placeholders for merge and shell (copies of the solid's own) and the hole's circle and depth for holes:

| Key | Meaning |
| --- | --- |
| `merged` | Another solid's complete definition (profile, depth, finishes, and its own `cuts`), unioned into this one; nesting is limited to 16 levels. It must touch or overlap. |
| `shell` | `{"openFaces": [{"position": "base" \| "cap" \| "side", "index": n}], "thickness": mm}`: hollow inward, keeping the outside, leaving the named faces open. Faces are named by role (side *n* lies along profile corner *n* to *n + 1*), matched by plane when rebuilt, so shells survive depth edits. Thickness 0.2 to 100 mm; at least one face must be open (a fully enclosed hollow would trap material in a print and is not built reliably by the kernel). |
| `hole` | `{"kind": "simple" \| "counterbore" \| "countersink" \| "insert", "size": "M3", "diameter", "counterboreDiameter", "counterboreDepth", "countersinkDiameter", "countersinkAngle"}`. The profile is the hole's circle on the face it enters, drilled along −normal; `depth` or `throughAll` sets how far. Preset values are starting points and are stored as built. |

Shell openings beyond the original faces (October 19, 2026): `shell` may also carry `"openPoints": [[x, y, z], …]`, a point on each further face to leave open (any face: made by a cut, join, union, subtract, or fillet, or curved), in the solid's own frame (along its profile plane's x and y axes and normal) so it moves with the solid. On rebuild each point selects the face nearest it (within 0.001 mm); if none is there, the solid fails to rebuild and the edit is refused. Original extrusion faces are still saved by name in `openFaces`, which may then be empty.

## Construction planes

Added October 19, 2026. A workspace may carry `"constructionPlanes": [{"id": UUID, "plane": plane frame, "width": mm, "height": mm, "hidden": true?}]`, made with Offset Plane (a distance from a flat face, sketch region, construction plane, or world plane) or Midplane (centered between two parallel ones). Only the result is stored: a plane is a fixed frame and does not follow the face or plane it was made from. Its frame uses the same axes as sketch planes (world up, or world Y for horizontal planes), with the origin at the center of the drawn rectangle; `width` and `height` only size that rectangle (the plane itself is unbounded). Sketches drawn on a plane keep their own copy of its frame, so deleting the plane leaves them in place. The key is omitted when there are no planes.

## Finishes on any edge, regions with holes, and slots

Added October 20, 2026. Three kinds of data:

- **Finish entries.** A solid's ordered `cuts` list may carry `"finish": {"kind": "fillet" | "chamfer", "size": mm, "edges": [{"point": [x, y, z], "name": {"position", "index"}?, "along": t?}]}`: a fillet or chamfer on edges the solid has at that point in its history, including edges made by cuts, holes, joins, unions, shells, and earlier finishes. Each edge is named by its middle point in the solid's own frame (along its profile plane's x and y axes and normal, as shell `openPoints` are), so moving, turning, aligning, or mirroring the solid carries it along; when rebuilt, the edge nearest that point (within 0.001 mm) is rounded or beveled. When the edge lies along an original extrusion edge, its `name` is kept too, and the point follows depth edits: a `cap` edge's point stays on the cap, and a `side` edge's keeps its fraction `along` the depth. The entry's `profile` and `depth` are placeholders (the solid's own). The app still saves a finish on original edges of a solid with no other operations in `finishes`, by name; anything else becomes a finish entry. An edit that moves an unnamed edge away from its point makes the solid fail to rebuild, and the edit is refused, as for shell points.
- **Holes in regions.** A profile (a solid's, or a cut's or join's) may carry `"holes": [{"outline": [...], "circle": {...}?, "arcs": [...]?}]`: closed counterclockwise loops strictly inside its outline, clear of it and of each other, that are not part of the region (a circle drawn inside a rectangle). Each has its own exact circle or arcs, like the outline. Extrusions and revolves build the region with its holes.
- **Slots.** A sketch shape may be `"kind": "slot"` with `"width": mm`: the stadium around the segment from `start` to `end` (its round ends' centers), `width` across.

Regions themselves are derived, never saved: shapes in a sketch divide each other where they cross or touch (the faces of the arrangement they make), and an outline inside a region becomes a hole in it. A closed shape that nothing divides keeps its own id as its region's id, and a loop of whole lines keeps the joined ids of its lines, so regions keep their ids as their shapes change; regions made of pieces of divided shapes add their center to the id (`…#x,y`). Arcs (`kind: "arc"`) can also be drawn, and Trim and sketch Fillet make ordinary lines and arcs.

## Imported solids

Added October 19, 2026. Import STEP brings in the closed solids of a `.step`/`.stp` file (open surfaces are sewn and kept where they close), converted to millimeters. Their exact shapes have no sketch definition, so they are stored in the file: the workspace carries `"importedShapes": [{"id": UUID, "name": "bracket", "data": base64}]`, where `data` is one solid in Open CASCADE's binary B-rep format (`BinTools`, current format version, without triangulations), in its own coordinates. Each shape is stored once; every solid made from it (copies, mirror images) refers to it by id, and a shape no solid uses is dropped when the model changes. A given id always has the same bytes. Because a project can come from anyone, the bytes are checked before Open CASCADE reads them (November 3, 2026): they must be format version 4 as `BinTools::Write` makes it, every table header exact, every count within the bytes left, every index within its table, and every curve and surface well formed by Open CASCADE's own rules (degrees, knots, poles, weights, radii, directions). After reading, the shape must hold a solid whose points are finite and within ten million millimeters. A shape that fails either is refused, so the project does not open. Since November 8, 2026 a merged, subtracted, or intersected solid with a long history (10 steps or more, its carried solids included, or merges of its own) is carried as an imported solid made from its exact shape, rather than as its whole definition: a plate split into pieces and merged back had carried 24,321 steps (16 MB, 14 s to build from nothing) and carries 144 (its file went from 18.3 to 2.1 MB). New merges are stored so when kept, using the solid already built for the preview; a model saved before is converted once in the background after it opens, without an undo step, each shape read back and its volume checked first. The target keeps every one of its own steps; only the carried solid's own history (never editable) is no longer kept. Files stay format version 2.

A solid built from one carries `"imported": {"shape": UUID, "mirrored": true?}` instead of being extruded or revolved. The shape sits in the solid's frame, its `profile.plane`: shape x, y, and z run along the plane's x axis, y axis, and normal (`mirrored` flips shape y first). Moving, turning, aligning, or mirroring the solid changes only that frame (and the flag), exactly as for drawn solids. The solid's `profile` (a rectangle around the shape) and `depth` are placeholders and are never built. Finishes name an imported solid's edges `{"position": "imported", "index": n}`, edge *n* of the stored shape in its own fixed order, matched to the current solid's edges by their exact curves like other names. Its faces have no names; a shell opens them by point (`openPoints`). Cuts, joins, holes, shells, face extrusions, unions, subtracts, and splits are stored in its `cuts` list as for any solid. A solid naming a shape the file does not store is invalid model data. Files may be up to 120 MB.

Import Project (October 29, 2026) brings another project into the open one. The file is read and validated exactly as when it is opened (a later version or damaged model is refused, never read in part). Everything in it is copied with new ids: its groups keep their nesting and its items their hidden state and place, all inside one new top-level group named after the file. Imported shapes the copies use are added unless this project already stores the same id; a file storing other bytes under an id this project uses is refused. A separate peg stands on the copy of its solid. Nothing links back to the other file, and the result must still fit the limits below, or nothing is imported. Duplicating a group copies the same way.

## Revolves

Added October 19, 2026. A solid can be revolved instead of extruded: it carries `"revolve": {"from": {"x": u, "y": v}, "to": {...}, "angle": degrees}`. The axis runs through `from` and `to`, two points in the profile plane's own coordinates (so moving or turning the solid carries the axis with it), and positive angles turn right-handed about `from` → `to`. The angle is 0.1° to 360° either way; ±360 is a full revolution with no end faces. The app orders the axis so a positive angle first lifts the region toward its plane's normal, like a positive extrusion, but readers must follow the stored direction. The profile must stay on one side of the axis (touching it is fine); a revolve whose axis crosses its profile is invalid model data. A revolved solid's `depth` is unused and saved as 0. Finishes name a revolve's edges by the same roles as an extrusion's: `base` and `cap` are profile segments on the start and end faces of a partial revolve, and `side` is the ring a profile corner traces; a shell can open the start (`base`) and end (`cap`) faces by name. A join or cut entry in a solid's `cuts` list may carry the same `revolve` object, and then its tool is its `profile` (or, with `facePoint`, that solid's own flat face) revolved instead of extruded; its `depth` is unused and `throughAll` is not allowed.

## Subtracts

Added October 19, 2026. Subtract removes tool solids from target solids. Each target keeps, at the end of its ordered `cuts` list, one entry per tool that overlaps it, carrying the tool's complete definition under `subtracted` (like `merged` for unions; its `profile` and `depth` are placeholders copied from the tool, and nesting counts toward the same 16-level limit). Rebuilding subtracts that solid as built; an entry that no longer removes anything, or would remove the whole target, fails the rebuild. When the targets are kept (Keep: Targets, or Targets & Tools) the results are new solids with new ids, and kept tools (Keep: Tools, or Targets & Tools) stay as solids of their own.

Clearance (October 20, 2026): a subtract entry may carry `"clearance": mm` (0.01 to 2), the printing gap on each side. The tool is grown outward by that distance (every point of its surface moves that far, with rounded convex edges) before it is subtracted, so a printed part shaped like the tool fits the space left. Omitted for an exact subtract; only subtract entries may carry it.

Threads (October 20, 2026): a solid's ordered `cuts` list may carry `"thread": {"internal": bool, "size": "M8" | "", "majorDiameter", "pitch", "clearance", "leftHanded": true?, "origin": [x, y, z], "axis": [...], "reference": [...], "length", "surfaceDiameter"}`, a modeled ISO 60° screw thread on a hole's wall (internal, a nut) or a round boss's side (external, a bolt). The axis runs from `origin` along the unit `axis` for `length` millimeters, all in the solid's own frame (as shell `openPoints` are) so it moves with the solid; `reference` (across the axis) fixes where the helix starts. The length runs a pitch past each open end of the face and 0.02 mm past a closed one (a blind hole's floor, a boss's base), so the cut never shares a face with the solid. Internal threads open the hole up to the root (the minor diameter) and make the groove; both kinds offset their profile by `clearance` (internal outward, external inward). Mirroring a solid flips its threads' hand. The entry's `profile` and `depth` are placeholders.

Thread ends and lead-ins (October 21, 2026): a thread may also carry `"ends": {"start", "end", "startOpen", "endOpen"}`, the threaded face's own extent along the axis measured from `origin` (inside `0…length`) and whether air lies beyond each end, and `"leadIn": true` for a 45° chamfer at each open end (a countersink in a nut from just past the crest to the root, a bevel on a bolt from just inside the root past the crest; a lead-in that will not build is left out rather than failing the thread). Threads saved without `ends` build as before and take no lead-in or matching part. A matching part (nut, cap, bolt, or plug) is an ordinary solid whose own `thread` entry copies the size, pitch, hand, clearance, and axis direction of the original and starts where its own face does (a pitch past an open end, 0.02 mm into a closed one), its `reference` turned about the axis by the distance from the original's `origin` over the lead (the other way for left-hand), so the two helices mesh where it was made. (Until October 22, 2026 the start was rounded down to a whole number of pitches instead, which could run a part's thread up to a pitch into a closed end: a cap lost its top. Parts made then keep their saved threads; make the part again to fix one.)

Thread sizes, starts, and lengths (October 21, 2026): `size` may also name an inch size (`"#4"`–`"#10"`, `"1/4"`–`"3/4"`; Unified threads share the 60° profile) or a metric size from `"M2"` to `"M36"`; a size with a fine `pitch` keeps its name ("M8" with pitch 1 is M8 × 1). An optional `"starts"` (2–4) winds that many ridges side by side a pitch apart, so a turn advances `starts × pitch`; omitted for one. A thread cut short by the Thread tool's Length is stored as an ordinary thread whose `origin`, `length`, and `ends` cover only the threaded part, its cut-off end recorded as closed (`startOpen` or `endOpen` false).

Raised threads (October 22, 2026): `"raised": true` adds the thread onto its face instead of cutting it in, so a thin wall keeps its thickness: the ridges (and, on a boss narrower than the thread's root, a sleeve building it up to the root) are united with the solid, and inside a hole the nut's ridges (and, in a hole wider than the crest, a sleeve filling it in to the crest). Only the face's own extent along the axis gets material: the thread's `length` still runs a pitch past an open end, but nothing is added beyond `ends.start` or `ends.end` where that end is open. The profile and clearance are as for a cut thread; a raised boss's face is normally the thread's nominal minor diameter and a raised hole's its major. Omitted for a cut thread. A matching part's own thread is always cut.

Text (October 20, 2026): a solid's ordered `cuts` list may carry `"text": {"text", "font": PostScript name, "height": capital height mm, "center": [u, v], "angle": degrees, "loops": [{"glyph": n, "filled": bool, "start": [u, v], "segments": [{"points": [[u, v], …]}]}]}`, lettering on the entry's `profile.plane` (its profile is a placeholder circle that carries the plane, so moving the solid carries the text). `depth` is how far the letters stand out (positive, embossed and joined) or sink in (negative, debossed and cut). The glyph outlines are saved: each segment is a line (one point), a quadratic curve (control point, end), or a cubic curve (two control points, end) after the point before it. A glyph's `filled` loops are united and its other loops (the inside of an "o") are holes. The string, font, and height are kept for editing; rebuilding uses only the outlines, so the text is the same on any device whatever fonts it has.

Peg & Socket (October 20, 2026) adds no new data: the peg is an ordinary `join` of a circle on the face plane (with a `finish` entry chamfering its tip when it is large enough), or, for a separate peg (October 21, 2026), an ordinary solid of its own (a circle extruded from its depth into the face to its height, with chamfer `finishes` on its socketed ends) plus an ordinary `cut` socket in the face's solid, and each socket an ordinary `cut` of a circle wider by twice the clearance and deeper by the clearance, on the same plane. Pegs made from October 24, 2026 carry a tag so they can be edited with their sockets (Edit Peg): the peg's `join`, its tip's `finish`, and every socket `cut` have `"peg": "<UUID>"`, and a separate peg's solid has `"peg": {"id": "<UUID>", "body": "<UUID of the solid it stands on>", "clearance", "embed"}` (`embed` its length into that face). Sockets are found by the tag and by lying on the peg's axis, so copies of the solids moved elsewhere keep theirs. Pegs without the tag build exactly as before; they just cannot be edited as a peg. The Fit Test coupon is two ordinary solids. The Fit preference (Tight 0.1, Standard 0.2, Loose 0.3 mm, or a custom value) is an app setting, not project data: operations save the millimeters they were built with.

## Splits

Added October 19, 2026. Split Body divides a solid into pieces without removing material. Each piece is saved as its own solid: the original definition (profile, depth, finishes, and ordered `cuts`) with one more entry at the end of `cuts` that keeps only that piece. For a plane, the entry carries `"split": {"keep": "front"}` or `{"keep": "back"}` and keeps the side of `profile.plane` its normal points to, or the other side; its `profile` (a small square on the plane) and `depth` are placeholders, because the kernel builds a half-space box covering the whole solid when it rebuilds. For a sketch region, the inside piece carries `{"keep": "inside"}` with `throughAll` and the region's `profile`, and the outside piece is an ordinary through-all cut. Several tools apply one after another, so a piece may carry several entries. Pieces have new ids; with Keep Input the original solid is kept too. Moving a piece moves its split planes with it.

Added October 24, 2026. A cut, subtract, intersect, hole, or split that leaves a solid in separate pieces (parts that do not touch) makes each piece its own solid, in the same undo step. Each is the solid's definition with one more entry at the end of `cuts`: `"split": {"keep": "piece", "point": [x, y, z]}`, which keeps the piece that point is strictly inside. The point is in the solid's own frame (`profile.plane`'s axes and normal, like a finish's edge points), so moving or mirroring the solid carries it; `profile` and `depth` are placeholders. When the solid is in one piece again (an earlier step was edited), the entry keeps it whole; when no piece contains the point, it keeps the piece whose bounding box center is nearest. The largest piece keeps the solid's id; the others have new ids and follow after the last solid, with the same name, color, and group.

## Projections

Added October 19, 2026. Project (sketch projection) casts sketches, solid edges, faces, or whole solids straight onto a plane and saves the result as ordinary sketch shapes; nothing records what was projected, so the shapes do not follow later changes. Lines, circles, and rectangles use the existing kinds. Two shape kinds are added:

| Kind | Fields |
| --- | --- |
| `arc` | `start` and `end` on the circle, `arcCenter`; the arc runs counterclockwise (in the plane's own axes) from `start` to `end`, less than a full turn |
| `curve` | `points` (2 to 4,096, `start` first), and `"closed": true` when the last point joins the first (omitted when open); for circles seen at an angle and outlines of curved faces. With `"spline": true` (October 24, 2026; at most 256 points) the points are the ones a spline passes through, and the curve is the uniform Catmull-Rom spline through them, 16 straight pieces between each two |

Lines, arcs, and open curves join end to end into closed regions as lines always have. A solid or cut profile built from such a region may carry `arcs`: `[{"start": i, "segments": n, "center": [u, v], "radius": r}]`, meaning outline points `i … i + n` (wrapping) lie on that circle. The outline is still saved in full (arcs every 3° at most); the kernel builds each run as one exact arc, so the extruded side is a single smooth face whose edges can be named and finished like straight ones.

## Sketches

Added October 19, 2026. Shapes belong to named sketches ("Sketch 01", "Sketch 02": names are derived from document order, not saved). A workspace may carry `"sketches": [{"id": UUID, "plane": plane, "hidden": true?}]`, and each shape then names its sketch with `"sketch": UUID`. A shape lies on its sketch's plane; a plane may hold several sketches, and each sketch finds its own closed regions. Moving or rotating a sketch changes only its plane frame (any orthonormal frame, stored as for face planes), never its shapes' 2D coordinates. A solid may carry `"hidden": true`. Hidden sketches and solids are not drawn, picked, or snapped to; the key is omitted when visible.

Shapes without sketch data form one sketch per plane, whose id is the plane's first shape's id; a workspace whose sketches are exactly that (one visible sketch per plane, named by its first shape) is written without `sketches` or shape `sketch` keys. A file that has `sketches` must account for every shape; shapes that name a missing sketch are rejected.

## Face extrusions

Added October 19, 2026. A flat face of a solid can be extruded from where it is (push/pull): outward joins the solid, inward cuts it. It is stored in the solid's ordered `cuts` list as an ordinary join (`"join": true`, positive `depth`) or cut (negative `depth`, never `throughAll`) with one more key, `facePoint`: a point strictly inside the face, in the coordinates of `profile.plane`. That plane is the face's canonical plane with its normal pointing out of the solid, and `profile` is the face's outer boundary (an exact circle for a round face; arcs otherwise saved as points every 5°), used for previews. Rebuilding does not extrude `profile`: it finds the flat face of the solid built so far that lies on that plane, faces the same way, and contains `facePoint`, and extrudes that face exactly, so holes and rounded edges in the face carry through. If an earlier edit (such as changing the solid's depth) moves the face away, the solid fails to rebuild and the edit is refused, as for finishes and cuts that no longer fit.

## Joins

Added October 18, 2026. A boss extruded onto a solid can be merged into it. A join is stored in the same ordered `cuts` list as cuts, with `"join": true` (the key is omitted for cuts), and the same `profile` and `depth` fields; `throughAll` is never set on a join. Rebuilding replays the list in order, unioning joins and subtracting cuts, so a hole, then a boss over it, then a hole through the boss reproduces exactly. A join must leave one connected solid; it merges into a single solid (the first one it touches). Existing solids are merged with Union (October 19, 2026), stored as `merged` entries (*More operations*).

## File safety and evolution

`UIDocument` owns open documents, coordinated reads/writes, change tracking, and safe replacement. This follows [Apple's document architecture](https://developer.apple.com/documentation/uikit/uidocument), rather than directly rewriting URLs supplied by cloud providers. Security-scoped access is retained for the open document's lifetime. Native Files controls choose the destination for new files and Save As copies. No custom cloud service or iCloud-container entitlement is needed to use user-selected iCloud Drive locations.

The document maintains a locked value snapshot for content serialization and loading; UI updates remain on the main actor. Every committed edit updates that snapshot and requests autosave. Leaving the editor flushes and closes the document before replacing the session. A failed save keeps the current model open and reports the error. Files with unresolved version conflicts are protected against overwriting, and Save As can preserve the working copy separately. There is no custom version-merging interface yet.

The codec validates format, version, units, coordinate system, identities, finite geometry, profile validity, and resource limits before accepting a file. Unknown versions fail explicitly; they never silently load as empty projects. Existing files are preserved on decoding failure. New-file creation refuses to replace an existing path. The current defensive limits are 120 MB per project (imported shapes are the large part), 10,000 sketch shapes, 1,000 solids, and bounded polygon validation work (the sum of every outline's squared point count, a circle's outline counting its points as it is checked point by point, including the solids that merges and subtracts carry, at most 100 million). An edit that would pass these limits is refused rather than kept unsaveable. Files are written as compact JSON with sorted keys (since November 8, 2026; earlier files are indented, and both read the same).

Version 2 (November 8, 2026) writes lean files and changes nothing else. A profile's (or hole's) `outline` is left out when it is exactly its `circle`'s or `ellipse`'s 128 points, counterclockwise from +x, and a reader makes it again bit for bit; any other outline (one that was mirrored or reordered, for example) is written out. A step in a solid's `cuts` leaves out its `profile` when it equals the solid's own `profile`, which Offset Face, Delete Face, fillets, splits, and merges carry, and a reader takes the solid's; a step coded on its own keeps it. A case of 9 solids went from 11.6 MB to 3.2 MB and reads back identical. Readers of version 1 refuse version 2 files instead of misreading them.

The format started over at version 1 on October 20, 2026, with the rename to Swipe & Sketch; earlier `.pencilform` files are not read. The outer project version and nested workspace version are separate. A future incompatible change needs a new version with an explicit decoder or migration and regression fixtures; never reinterpret a version 1 field or discard unknown future geometry. Keep migrations copy-preserving until their output has been verified. The Open CASCADE kernel rebuilds solids from the native analytic source, which stays authoritative; only imported solids store exact bodies (`importedShapes`). Any further exact-body representation needs a new version, added deliberately. Built solids are also kept outside the file, in the app's caches folder (`BuiltSolidStore`, November 8, 2026), so a project opens without replaying every solid's history; that cache is named by a hash of each solid's definition and the app's version, is never needed to open a file, and may be emptied by the system at any time.

## Export

A native `.swipesketch` project remains the editable original; exports are derived delivery files written to a temporary folder and handed to the share sheet. **3MF and STL are implemented** (`Export.swift`): every solid is rebuilt by the kernel, tessellated at 0.01 mm chordal / 5° angular tolerance (finer than display), and welded so shared edges share vertices; tests verify closed, consistently oriented, manifold meshes with the solid's volume. 3MF is a core-spec OPC package (unit millimeter, one object and build item per solid, deflate-compressed with Apple's Compression framework); STL is binary, the visible solids (or the selection) in one file, in millimeters. STP remains future work:

- **3MF:** The [3MF Core specification](https://github.com/3MFConsortium/spec_core/blob/master/3MF%20Core%20Specification.md) defines mesh objects and explicit units, including millimeters. The exporter generates tessellated, consistently oriented, closed manifold meshes from the kernel's solids, never from the display, and excludes grid lines, selection strokes, and preview objects. Rendering tessellation is not an export quality guarantee. See the [Consortium's specification catalog](https://3mf.io/spec/).
- **STP / STEP:** STEP is an ISO 10303 CAD exchange family; `.stp` and `.step` are common Part 21 file extensions. [NIST's overview](https://www.nist.gov/services-resources/software/step-file-analyzer-and-viewer) describes supported application protocols and validation. A future exporter would write the exact solids the Open CASCADE kernel already rebuilds from the analytic definitions (the app uses OCCT's STEP reader for import; no writer is wired up). Protocol choice, tolerances, topology validation, and independent-reader tests belong to the export feature.

Print-ready 3MF (October 20, 2026): Export 3MF and Send to Slicer name each object as the Model Tree does ("Body 01", or an imported file's name), so slicers' object lists match; add `CreationDate`, `ModificationDate`, and `Description` metadata; mark build items printable; and place parts on the plate with each build item's `transform` (translation only, plate coordinates with the plate's center at half its size): **Arrange on Plate** lays parts side by side in shelves, each resting on the plate, the group centered; **As Modeled** moves the whole group as one onto the plate's middle. The plate size is an app setting (common plates, 256 × 256 mm by default). A square 512-pixel picture of the canvas goes in as the package thumbnail (`/Metadata/thumbnail.png`, linked from `_rels/.rels`), which Files, slicers, and printers show. Vertex coordinates stay as modeled. Send to Slicer can also save the file into a remembered folder (a security-scoped bookmark), replacing the last version, so a slicer on a Mac can open it from iCloud Drive.

These requirements support the present choice: preserve analytic model definitions, signed distances, units, and identity now, so exports are derived (and a future STEP export can be) without turning circles into saved polygon approximations.

## Verification scope

Core tests cover exact geometry round trips, independent copies, invalid and future formats, and exclusive creation. Hosted iPad tests open, edit, autosave, close, and reopen real UIDocuments. Simulator UI tests exercise native Files dialogs and the modeling menu. Simulator local storage checks do not establish real-account iCloud synchronization, provider conflict handling, or physical Pencil behavior; those remain device checks.

## Missing basics (October 21, 2026)

Still format version 1; every new key is optional and omitted when unset, so files without these features are unchanged.

- **Solids:** `symmetric: true` (extruded half the depth each way from the sketch plane; base and cap names lie at −depth/2 and +depth/2), `taper` (degrees, the sides leaning in toward the far end; edges and faces of tapered sides are found by point, not by name), `name` (chosen in the Model Tree, 1–60 characters on one line), and `color` (`white`, `black`, `red`, `orange`, `yellow`, `green`, `blue`, `purple`, or `pink`; gray is the default and is never written).
- **Cut and join entries:** `symmetric` and `taper` as for solids (never with `throughAll`, `facePoint`, or `revolve`).
- **New entries in a solid's `cuts` list** (each with the solid's own profile and depth as placeholders): `"intersected": {solid}` keeps only where that solid's whole definition overlaps; `"scale": {"center": [x, y, z], "xAxis": [..], "yAxis": [..], "factors": [fx, fy, fz]}` scales everything before it about the center, along the axes (all in the solid's own frame, so it moves and mirrors with the solid; factors 0.001–1000); `"removedFaces": {"points": [[x, y, z], …]}` takes off the faces through those points (Delete Face); `"movedFaces": {"points": [...], "distance": mm, "intersection": true|false}` moves those faces along their outward normals (Offset Face); `intersection` records how the faces around them followed when the edit was made (true: every face intersected; false: only the neighbours extended) and rebuilding uses the same, with no time limit, so the solid comes out the same on any device. Without it (steps saved before November 2, 2026) rebuilding tries true, then false. Points are in the solid's own frame, as finish and shell points are; an edit that moves such a face away makes the solid fail to rebuild, and the edit is refused.
- **Sketch shapes:** `kind` may be `ellipse` (`start` its center, `end` the end of its own axis, `width` its diameter across) or `point` (`start` and `end` equal); `construction: true` marks reference geometry that bounds no region. **Regions** (profiles and holes) may carry `ellipse: {"center", "radiusX", "radiusY", "angle"}` when the loop is an exact ellipse.
- **Sketches and construction planes:** an optional `name`.
- **Preview picture:** the project may carry a top-level `"preview"`: a base64 PNG (320 × 320 points at the screen's scale, at most 1 MB; readers decode it only when its header says at most 2048 pixels a side) of the visible solids from the standard 3D angle, or of the sketches when there is no solid. The app draws it when a project is left (closed, another project started, the app sent to the background) and for Save As copies; it is never needed to open the file. The `SwipeAndSketchThumbnails` Quick Look thumbnail extension finds it with a byte search of the memory-mapped file (keys are written sorted, so `preview` comes before `workspace`), so the document browser, Files, and AirDrop show the model; a file without one shows a plain cube instead of its JSON text. UIDocument's thumbnail attributes are not used: iOS ignores them for files on the device (verified October 21, 2026).
- **Groups (Model Tree):** the workspace may carry `"groups": [{"id": UUID, "name"?, "hidden": true?, "parent": UUID?}]`, and solids, sketches, and construction planes an optional `"group": UUID` naming the group they sit in (omitted at the top of the tree). A group's `parent` is the group it sits in. Every referenced group must exist and parents must not loop (at most 32 deep, 1,000 groups); a file that breaks this is refused, not repaired. A hidden group hides everything in it, at any depth, without changing the items' own `hidden`. Selecting a group selects everything in it, so it moves, transforms, and exports as a unit (October 24, 2026); that adds no data. Whether a group is folded away in the Model Tree is not saved.

Kept dimensions (October 30, 2026): a sketch may carry `"dimensions": [{"id": UUID, "kind": "horizontal" | "vertical" | "distance" | "angle" | "length", "first": reference, "second": reference?}]`, the dimensions given a value with the Dimension tool. A reference to a sketch shape is `{"shape": UUID, "part": "start" | "end" | "center" | "corner" | "side", "index": n?}` (`part` omitted for the whole shape; `index` 0–3 for a rectangle's corner or side, 0–1 for a slot's side), and is found on the shape as it is now; the item as it was when picked (`point`, `line`, or `center` and `radius`) is written too, but only read back for fixed references (no `shape`: a solid's corner or edge on the sketch plane, a guide point, or the origin), in the sketch plane's own coordinates. Without `second`, `kind` is a whole line's `length` or `angle`; otherwise it is the value between the two. At least one reference names a shape. Values are never saved: a kept dimension is not a constraint, and it shows the value as the shapes are now. It is kept in the sketch of the shape that moves when the value is typed (the second pick's, or the first's when the second is fixed); a shape it names may be in another sketch on the same plane. A dimension whose shape is gone, has left the plane, or no longer has that part (a rectangle turned into lines) is dropped with the next change. Copies of a sketch keep the dimensions between their own shapes (Duplicate Group and Import Project, between any of the sketches copied), and copies left in place (Paste, Duplicate, Import Project) keep those to fixed references too; a sketch that moves, turns, scales, or mirrors drops those to fixed references. The key is omitted when a sketch has none, and files without them are unchanged.

Face edges (October 30, 2026): a sketch drawn on a flat face of a solid may carry `"faceEdges": [{"kind": "line" | "arc" | "circle" | "curve", "start": point, "end": point, "arcCenter": point?, "points": [point]?, "closed": true?}]`, the face's edges (outer boundary and any holes) when its first shape was drawn, in the sketch plane's own coordinates and with the same meaning as a shape of that kind (an arc runs counterclockwise from `start` to `end` about `arcCenter`; a circle is centered on `start` through `end`; edges that are not lines or circles are `curve` points along them). They are not shapes: they are never drawn, picked, or snapped to, and they do not follow later changes to the solid. They only bound regions with the sketch's shapes, so the face less what is drawn on it is a region of the sketch too, as is each part of the face a line divides off; the drawn regions are unchanged, and a region of the face no shape touches is not offered. When several sketches on the same plane carry face edges, the first one shown offers that region, less what every visible sketch on the plane draws there. A whole sketch selected extrudes only what is drawn. The app offers that region on the canvas only while a face with exactly those edges still lies under it (once the face changes, a tap there picks the face again); this is not saved. A sketch moved or turned keeps its face edges (they are in its own coordinates), as do copies left in place (Paste, Duplicate, Import Project); a sketch scaled or mirrored in place drops them, and copies made by moving, mirroring, scaling, or patterning do not carry them. Each edge must be a valid shape of its kind, and there are at most 4,096; a file that breaks this is refused. The key is omitted for sketches not drawn on a face, and files without it are unchanged.

Thread profiles (October 26, 2026): a thread entry may carry `"profile": "printable"`, a 90° profile (flanks leaning 45°, 0.3 pitch deep: the minor diameter is the major less 0.6 pitch) instead of ISO 60°, which is the default and is never written; and a raised thread `"taperedEnds": true`, its ridges fading out over a quarter of the lead where they meet the solid (and at an open end without a lead-in). Threads without them build as before.

Screw Lid (October 26, 2026) adds no data of its own either: the neck's thread is an ordinary raised thread entry, and the lid an ordinary solid with its own cut thread. Its Test Print (the thread fit test) adds ordinary solids too: a ring with a raised thread and three collars with cut threads, in an ordinary group named "Thread Fit Test".

Editing after Done (October 24, 2026) adds no data of its own: Edit Hole, Edit Thread, and Edit Text replace their entry in the solid's `cuts` list in place, keeping its `id`, so the entries after it still apply after it. Edit Peg does the same for each solid's peg entries (a separate peg's solid stays where it was in the list).

Tier 2 basics (October 24, 2026):

- Draft: a solid's `cuts` list may carry `"draft": {"points": [[x, y, z], …], "pull": [x, y, z], "origin": [x, y, z], "angle": degrees}`, all in the solid's own frame: the faces through `points` lean `angle` degrees (0.01–60, negative outward) from the unit `pull` direction, pivoting on the plane through `origin` perpendicular to it.
- Rib: `"rib": {"start", "end", "normal", "thickness", "side"}` in the solid's own frame: a web from the line `start`–`end` on a plane with unit `normal`, `thickness` mm across that plane (0.1–100), reaching on `side` (+1 toward `normal` × the line's direction, or −1) until it meets the solid, which is rebuilt each time.
- Loft, Sweep, and Import Mesh (STL, 3MF) make solids whose exact shape is stored in `importedShapes`, exactly as STEP import does (named "Loft", "Sweep", or after the file); their sections, paths, or meshes are not kept.
- Primitives are ordinary extrusions and revolves; construction axes are sketches named "Axis 01", … holding one construction line; Plane at Angle, 3-Point Plane, and Tangent Plane make ordinary construction planes. None adds data.

## Project notes

Notes below Assistant in the left toolbar (or Project Menu > Notes) opens a notebook panel beside
the canvas. Tap the text directly to type; there are no Edit or Done buttons. The × button closes
the panel and saves pending text. The native editor accepts plain text, line-based lists, and URLs;
touch and hold a link for its actions. Opening the panel does not summon the keyboard. Notes are
free, saved through UIDocument after a short pause in typing, and copied by Save As.
Closing Notes, Save, Home, and backgrounding flush pending text immediately. Keystrokes stay outside
the published modeling workspace to avoid validating geometry or refreshing the canvas per character.
Notes-only autosaves validate notebook metadata without revalidating unchanged geometry on the main
actor. Canvas change detection ignores notes, so autosaving them does not rebuild SceneKit content.
Full file validation still runs on UIDocument’s save queue. Each text-editing
session is one project undo step; the editor also provides native text undo. Notes do not enter
geometry, STL, or 3MF exports. Pencil Scribble and dictation use the native text editor; fingers
continue to navigate the modeling canvas.

The project envelope remains format version 1. A workspace with project notes alone initially uses workspace `version: 2`
and a UTF-8 `notes` string (maximum 256 KiB). Readers without note support require workspace
version 1 and refuse these files, preventing silent loss on save. New builds read workspace versions 1–3; an absent `notes` key means an empty notebook. A workspace always carries the
lowest version its notes need (November 3, 2026): clearing every note brings it back to version 1, so
older readers open it again. Projects without notes use version 1 and omit the notes key. Unsupported future workspace versions are refused before decoding geometry.

### Linked notes

A sketch or body can have one notebook, opened with **Add Note…** (then **Open Note**) in its
Model Tree context menu. A note indicator beside the row opens the same notebook. The Notes
panel lists Project Notes alongside these notebooks; **All** shows all linked notebooks and
**Selected Object** filters them to the selected body or sketch. Selecting a linked notebook
selects its target as its Model Tree row would: sketch mode ends, and a hidden target stays
unselected (its visibility does not change). The empty
notebook is a session draft until text is entered, so its first text and link are one undo step.
Switching notebooks flushes pending text. Opening and closing an empty draft changes no file.

Linked notebooks store `objectNotes: [{id, kind, objectID, objectName, text}]` with stable UUIDs
and `kind: "body" | "sketch"`. The name is a fallback snapshot, kept current by every change (a deleted object's note keeps the
last name it had); live names follow renames.
Deleting geometry preserves its notes and marks the target missing; undoing deletion reconnects
it automatically. Duplicating geometry does not duplicate its notebook. A linked notebook's
context menu can delete the note independently of geometry, with Undo support.

Files containing linked notebooks use workspace **version 3**. The project envelope stays at
version 1; readers supporting only workspace versions 1 or 2 refuse these files safely.
New builds accept versions 1–3. Deleting the last linked note lowers the version to what the
project notes need (2, or 1 without them); updating project notes never lowers it below 3 while
linked notes remain. Notebook text shares a 256 KiB UTF-8 budget, with at most 1,000 linked
notebooks and unique note IDs and object targets. Missing object IDs are allowed deliberately.
Notes-only validation and canvas change detection treat linked text as metadata too.
