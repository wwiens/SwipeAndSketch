# Editable project files

Decision recorded October 18, 2026; renamed October 20, 2026. Projects are native `.swipesketch` documents (type `noventix.SwipeAndSketch.project`) managed through Apple's Files browser. A project contains its sketches and independent extruded solids. Users choose On My iPad, iCloud Drive, or another writable Files provider.

## User workflow

- Open the app to browse projects. **New Project** creates an empty named file in the chosen location.
- In the modeling header, the house returns to the project browser. The menu provides **Save**, **Save As…**, **New Project…**, and **Open Project…**.
- Committed geometry changes autosave. Save requests an immediate flush. An unconfirmed extrusion preview or unfinished keypad entry is not a committed model change; press Done or the keypad check first.
- New Project first saves the current project, then asks where to create the empty project. Cancel keeps the existing project open. Each project starts with fresh selection and undo history.
- Save As writes an independent project with a new project ID, then opens that copy. Renaming and moving files are available in the native browser or Files app.
- A project inside the app's own folder (On My iPad › Swipe & Sketch, except the system Inbox) always opens in place; the browser is only moved to its folder. A file the app has just written may not be known to the Files provider yet, and revealing it with import would copy it into a same-named duplicate or report a failed import. Projects elsewhere are revealed through the browser, which imports them when needed.

## Why a native project format

The editable source is a small, documented JSON document, rather than a saved SceneKit scene or a printing mesh. This is an application format, not a claim of CAD interchange conformance. A flat file is sufficient for the current geometry; packaging or compression would add complexity without assets to bundle.

| Field | Meaning |
| --- | --- |
| `format` | `noventix.SwipeAndSketch.project` |
| `schemaVersion` | Format version: `1`. A file with another version or `format` is refused, never partly read |
| `id` | Stable UUID for this project; Save As creates a new one |
| `createdAtMilliseconds`, `modifiedAtMilliseconds` | UTC Unix timestamps in milliseconds |
| `units` | Explicitly `millimeter` |
| `coordinateSystem` | Explicitly `right-handed-z-up` |
| `workspace` | Versioned sketches and solid definitions with stable object IDs |

Coordinates and dimensions remain full-precision Swift `Double` values through JSON encoding/decoding. No display rounding is applied to saved geometry. Sketch primitives retain their kind, plane, endpoints or center/radius definition. Each solid retains its own plane, profile outline, analytic circle where applicable, and signed extrusion distance. Deleting or editing a source sketch does not invalidate an independent existing solid. A polygon outline is saved alongside a circle's analytic definition for previews; the kernel builds exact geometry from the analytic definition.

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

Decision recorded October 18, 2026. A solid may carry `finishes`, an ordered list replayed on its extrusion:

| Field | Meaning |
| --- | --- |
| `kind` | `fillet` (rounded, `size` is the radius) or `chamfer` (bevel, `size` is the setback distance) |
| `edges` | Original extrusion edges, each `{position, index}`: `base` / `cap` along profile segment `index` on the sketch plane or far end; `side` along the extrusion at profile corner `index` (polygons only). Circles have `base` 0 and `cap` 0 |
| `size` | Millimeters, 0.01 to 1,000 |
| `id` | Stable UUID |

Edges are named by their role, never by kernel edge number, because kernel numbering changes after every operation. Indices count real corners: collinear outline points (lines joined end to end) are skipped, since they extrude to one flat side. When the solid is rebuilt, each named edge is matched to the current kernel edge whose exact curve lies along it, so names survive depth edits and earlier finishes. An edge may appear in only one finish. Edges created by a fillet or chamfer, cut, or other operation have no name; they are finished by a finish entry in the `cuts` list, named by a point on them.

## Cuts

Decision recorded October 18, 2026. A solid may carry `cuts`, an ordered list of extruded profiles subtracted from it (holes, pockets, slots):

| Field | Meaning |
| --- | --- |
| `profile` | A full copy of the cut's sketch profile (plane, outline, analytic circle), independent of the source sketch |
| `depth` | Signed millimeters along the profile plane's normal from the sketch plane (ignored for through-all) |
| `throughAll` | When true, the cut spans the solid's full extent on both sides of the sketch plane |
| `id` | Stable UUID |

One Cut operation records a copy on every solid it removes material from, so solids stay independent. A solid is rebuilt as: extrude, then finishes in order, then cuts in order. Finish edge names refer to the uncut extrusion; edges created by cuts have no names. A cut may split a solid into separate pieces; a cut that would remove the whole solid is rejected.

## More operations

Decision recorded October 18, 2026. Three more kinds of entry can appear in a solid's ordered `cuts` list. Each carries a payload key; its `profile` and `depth` are placeholders for merge and shell (copies of the solid's own) and the hole's circle and depth for holes:

| Key | Meaning |
| --- | --- |
| `merged` | Another solid's complete definition (profile, depth, finishes, and its own `cuts`), unioned into this one; nesting is limited to 16 levels. It must touch or overlap. |
| `shell` | `{"openFaces": [{"position": "base" \| "cap" \| "side", "index": n}], "thickness": mm}`: hollow inward, keeping the outside, leaving the named faces open. Faces are named by role (side *n* lies along profile corner *n* to *n + 1*), matched by plane when rebuilt, so shells survive depth edits. Thickness 0.2 to 100 mm; at least one face must be open (a fully enclosed hollow would trap material in a print and is not built reliably by the kernel). |
| `hole` | `{"kind": "simple" \| "counterbore" \| "countersink" \| "insert", "size": "M3", "diameter", "counterboreDiameter", "counterboreDepth", "countersinkDiameter", "countersinkAngle"}`. The profile is the hole's circle on the face it enters, drilled along −normal; `depth` or `throughAll` sets how far. Preset values are starting points and are stored as built. |

Shell openings beyond the original faces (October 19, 2026): `shell` may also carry `"openPoints": [[x, y, z], …]`, a point on each further face to leave open (any face: made by a cut, join, union, subtract, or fillet, or curved), in the solid's own frame (along its profile plane's x and y axes and normal) so it moves with the solid. On rebuild each point selects the face nearest it (within 0.001 mm); if none is there, the solid fails to rebuild and the edit is refused. Original extrusion faces are still saved by name in `openFaces`, which may then be empty.

## Construction planes

Decision recorded October 19, 2026. A workspace may carry `"constructionPlanes": [{"id": UUID, "plane": plane frame, "width": mm, "height": mm, "hidden": true?}]`, made with Offset Plane (a distance from a flat face, sketch region, construction plane, or world plane) or Midplane (centered between two parallel ones). Only the result is stored: a plane is a fixed frame and does not follow the face or plane it was made from. Its frame uses the same axes as sketch planes (world up, or world Y for horizontal planes), with the origin at the center of the drawn rectangle; `width` and `height` only size that rectangle (the plane itself is unbounded). Sketches drawn on a plane keep their own copy of its frame, so deleting the plane leaves them in place. The key is omitted when there are no planes.

## Finishes on any edge, regions with holes, and slots

Decision recorded October 20, 2026. Three kinds of data:

- **Finish entries.** A solid's ordered `cuts` list may carry `"finish": {"kind": "fillet" | "chamfer", "size": mm, "edges": [{"point": [x, y, z], "name": {"position", "index"}?, "along": t?}]}`: a fillet or chamfer on edges the solid has at that point in its history, including edges made by cuts, holes, joins, unions, shells, and earlier finishes. Each edge is named by its middle point in the solid's own frame (along its profile plane's x and y axes and normal, as shell `openPoints` are), so moving, turning, aligning, or mirroring the solid carries it along; when rebuilt, the edge nearest that point (within 0.001 mm) is rounded or beveled. When the edge lies along an original extrusion edge, its `name` is kept too, and the point follows depth edits: a `cap` edge's point stays on the cap, and a `side` edge's keeps its fraction `along` the depth. The entry's `profile` and `depth` are placeholders (the solid's own). The app still saves a finish on original edges of a solid with no other operations in `finishes`, by name; anything else becomes a finish entry. An edit that moves an unnamed edge away from its point makes the solid fail to rebuild, and the edit is refused, as for shell points.
- **Holes in regions.** A profile (a solid's, or a cut's or join's) may carry `"holes": [{"outline": [...], "circle": {...}?, "arcs": [...]?}]`: closed counterclockwise loops strictly inside its outline, clear of it and of each other, that are not part of the region (a circle drawn inside a rectangle). Each has its own exact circle or arcs, like the outline. Extrusions and revolves build the region with its holes.
- **Slots.** A sketch shape may be `"kind": "slot"` with `"width": mm`: the stadium around the segment from `start` to `end` (its round ends' centers), `width` across.

Regions themselves are derived, never saved: shapes in a sketch divide each other where they cross or touch (the faces of the arrangement they make), and an outline inside a region becomes a hole in it. A closed shape that nothing divides keeps its own id as its region's id, and a loop of whole lines keeps the joined ids of its lines, so regions keep their ids as their shapes change; regions made of pieces of divided shapes add their center to the id (`…#x,y`). Arcs (`kind: "arc"`) can also be drawn, and Trim and sketch Fillet make ordinary lines and arcs.

## Imported solids

Decision recorded October 19, 2026. Import STEP brings in the closed solids of a `.step`/`.stp` file (open surfaces are sewn and kept where they close), converted to millimeters. Their exact shapes have no sketch definition, so they are stored in the file: the workspace carries `"importedShapes": [{"id": UUID, "name": "bracket", "data": base64}]`, where `data` is one solid in Open CASCADE's binary B-rep format (`BinTools`, current format version, without triangulations), in its own coordinates. Each shape is stored once; every solid made from it (copies, mirror images) refers to it by id, and a shape no solid uses is dropped when the model changes. A given id always has the same bytes.

A solid built from one carries `"imported": {"shape": UUID, "mirrored": true?}` instead of being extruded or revolved. The shape sits in the solid's frame, its `profile.plane`: shape x, y, and z run along the plane's x axis, y axis, and normal (`mirrored` flips shape y first). Moving, turning, aligning, or mirroring the solid changes only that frame (and the flag), exactly as for drawn solids. The solid's `profile` (a rectangle around the shape) and `depth` are placeholders and are never built. Finishes name an imported solid's edges `{"position": "imported", "index": n}`, edge *n* of the stored shape in its own fixed order, matched to the current solid's edges by their exact curves like other names. Its faces have no names; a shell opens them by point (`openPoints`). Cuts, joins, holes, shells, face extrusions, unions, subtracts, and splits are stored in its `cuts` list as for any solid. A solid naming a shape the file does not store is invalid model data. Files may be up to 120 MB.

## Revolves

Decision recorded October 19, 2026. A solid can be revolved instead of extruded: it carries `"revolve": {"from": {"x": u, "y": v}, "to": {...}, "angle": degrees}`. The axis runs through `from` and `to`, two points in the profile plane's own coordinates (so moving or turning the solid carries the axis with it), and positive angles turn right-handed about `from` → `to`. The angle is 0.1° to 360° either way; ±360 is a full revolution with no end faces. The app orders the axis so a positive angle first lifts the region toward its plane's normal, like a positive extrusion, but readers must follow the stored direction. The profile must stay on one side of the axis (touching it is fine); a revolve whose axis crosses its profile is invalid model data. A revolved solid's `depth` is unused and saved as 0. Finishes name a revolve's edges by the same roles as an extrusion's: `base` and `cap` are profile segments on the start and end faces of a partial revolve, and `side` is the ring a profile corner traces; a shell can open the start (`base`) and end (`cap`) faces by name. A join or cut entry in a solid's `cuts` list may carry the same `revolve` object, and then its tool is its `profile` (or, with `facePoint`, that solid's own flat face) revolved instead of extruded; its `depth` is unused and `throughAll` is not allowed.

## Subtracts

Decision recorded October 19, 2026. Subtract removes tool solids from target solids. Each target keeps, at the end of its ordered `cuts` list, one entry per tool that overlaps it, carrying the tool's complete definition under `subtracted` (like `merged` for unions; its `profile` and `depth` are placeholders copied from the tool, and nesting counts toward the same 16-level limit). Rebuilding subtracts that solid as built; an entry that no longer removes anything, or would remove the whole target, fails the rebuild. When the targets are kept (Keep: Targets, or Targets & Tools) the results are new solids with new ids, and kept tools (Keep: Tools, or Targets & Tools) stay as solids of their own.

Clearance (October 20, 2026): a subtract entry may carry `"clearance": mm` (0.01 to 2), the printing gap on each side. The tool is grown outward by that distance (every point of its surface moves that far, with rounded convex edges) before it is subtracted, so a printed part shaped like the tool fits the space left. Omitted for an exact subtract; only subtract entries may carry it.

Threads (October 20, 2026): a solid's ordered `cuts` list may carry `"thread": {"internal": bool, "size": "M8" | "", "majorDiameter", "pitch", "clearance", "leftHanded": true?, "origin": [x, y, z], "axis": [...], "reference": [...], "length", "surfaceDiameter"}`, a modeled ISO 60° screw thread on a hole's wall (internal, a nut) or a round boss's side (external, a bolt). The axis runs from `origin` along the unit `axis` for `length` millimeters, all in the solid's own frame (as shell `openPoints` are) so it moves with the solid; `reference` (across the axis) fixes where the helix starts. The length runs a pitch past each open end of the face and 0.02 mm past a closed one (a blind hole's floor, a boss's base), so the cut never shares a face with the solid. Internal threads open the hole up to the root (the minor diameter) and make the groove; both kinds offset their profile by `clearance` (internal outward, external inward). Mirroring a solid flips its threads' hand. The entry's `profile` and `depth` are placeholders.

Thread ends and lead-ins (October 21, 2026): a thread may also carry `"ends": {"start", "end", "startOpen", "endOpen"}`, the threaded face's own extent along the axis measured from `origin` (inside `0…length`) and whether air lies beyond each end, and `"leadIn": true` for a 45° chamfer at each open end (a countersink in a nut from just past the crest to the root, a bevel on a bolt from just inside the root past the crest; a lead-in that will not build is left out rather than failing the thread). Threads saved without `ends` build as before and take no lead-in or matching part. A matching part (nut, cap, bolt, or plug) is an ordinary solid whose own `thread` entry copies the size, pitch, hand, clearance, and axis direction of the original and starts where its own face does (a pitch past an open end, 0.02 mm into a closed one), its `reference` turned about the axis by the distance from the original's `origin` over the lead (the other way for left-hand), so the two helices mesh where it was made. (Until October 22, 2026 the start was rounded down to a whole number of pitches instead, which could run a part's thread up to a pitch into a closed end: a cap lost its top. Parts made then keep their saved threads; make the part again to fix one.)

Thread sizes, starts, and lengths (October 21, 2026): `size` may also name an inch size (`"#4"`–`"#10"`, `"1/4"`–`"3/4"`; Unified threads share the 60° profile) or a metric size from `"M2"` to `"M36"`; a size with a fine `pitch` keeps its name ("M8" with pitch 1 is M8 × 1). An optional `"starts"` (2–4) winds that many ridges side by side a pitch apart, so a turn advances `starts × pitch`; omitted for one. A thread cut short by the Thread tool's Length is stored as an ordinary thread whose `origin`, `length`, and `ends` cover only the threaded part, its cut-off end recorded as closed (`startOpen` or `endOpen` false).

Raised threads (October 22, 2026): `"raised": true` adds the thread onto its face instead of cutting it in, so a thin wall keeps its thickness: the ridges (and, on a boss narrower than the thread's root, a sleeve building it up to the root) are united with the solid, and inside a hole the nut's ridges (and, in a hole wider than the crest, a sleeve filling it in to the crest). Only the face's own extent along the axis gets material: the thread's `length` still runs a pitch past an open end, but nothing is added beyond `ends.start` or `ends.end` where that end is open. The profile and clearance are as for a cut thread; a raised boss's face is normally the thread's nominal minor diameter and a raised hole's its major. Omitted for a cut thread. A matching part's own thread is always cut.

Text (October 20, 2026): a solid's ordered `cuts` list may carry `"text": {"text", "font": PostScript name, "height": capital height mm, "center": [u, v], "angle": degrees, "loops": [{"glyph": n, "filled": bool, "start": [u, v], "segments": [{"points": [[u, v], …]}]}]}`, lettering on the entry's `profile.plane` (its profile is a placeholder circle that carries the plane, so moving the solid carries the text). `depth` is how far the letters stand out (positive, embossed and joined) or sink in (negative, debossed and cut). The glyph outlines are saved: each segment is a line (one point), a quadratic curve (control point, end), or a cubic curve (two control points, end) after the point before it. A glyph's `filled` loops are united and its other loops (the inside of an "o") are holes. The string, font, and height are kept for editing; rebuilding uses only the outlines, so the text is the same on any device whatever fonts it has.

Peg & Socket (October 20, 2026) adds no new data: the peg is an ordinary `join` of a circle on the face plane (with a `finish` entry chamfering its tip when it is large enough), or, for a separate peg (October 21, 2026), an ordinary solid of its own (a circle extruded from its depth into the face to its height, with chamfer `finishes` on its socketed ends) plus an ordinary `cut` socket in the face's solid, and each socket an ordinary `cut` of a circle wider by twice the clearance and deeper by the clearance, on the same plane. Pegs made from October 24, 2026 carry a tag so they can be edited with their sockets (Edit Peg): the peg's `join`, its tip's `finish`, and every socket `cut` have `"peg": "<UUID>"`, and a separate peg's solid has `"peg": {"id": "<UUID>", "body": "<UUID of the solid it stands on>", "clearance", "embed"}` (`embed` its length into that face). Sockets are found by the tag and by lying on the peg's axis, so copies of the solids moved elsewhere keep theirs. Pegs without the tag build exactly as before; they just cannot be edited as a peg. The Fit Test coupon is two ordinary solids. The Fit preference (Tight 0.1, Standard 0.2, Loose 0.3 mm, or a custom value) is an app setting, not project data: operations save the millimeters they were built with.

## Splits

Decision recorded October 19, 2026. Split Body divides a solid into pieces without removing material. Each piece is saved as its own solid: the original definition (profile, depth, finishes, and ordered `cuts`) with one more entry at the end of `cuts` that keeps only that piece. For a plane, the entry carries `"split": {"keep": "front"}` or `{"keep": "back"}` and keeps the side of `profile.plane` its normal points to, or the other side; its `profile` (a small square on the plane) and `depth` are placeholders, because the kernel builds a half-space box covering the whole solid when it rebuilds. For a sketch region, the inside piece carries `{"keep": "inside"}` with `throughAll` and the region's `profile`, and the outside piece is an ordinary through-all cut. Several tools apply one after another, so a piece may carry several entries. Pieces have new ids; with Keep Input the original solid is kept too. Moving a piece moves its split planes with it.

## Projections

Decision recorded October 19, 2026. Project (sketch projection) casts sketches, solid edges, faces, or whole solids straight onto a plane and saves the result as ordinary sketch shapes; nothing records what was projected, so the shapes do not follow later changes. Lines, circles, and rectangles use the existing kinds. Two shape kinds are added:

| Kind | Fields |
| --- | --- |
| `arc` | `start` and `end` on the circle, `arcCenter`; the arc runs counterclockwise (in the plane's own axes) from `start` to `end`, less than a full turn |
| `curve` | `points` (2 to 4,096, `start` first), and `"closed": true` when the last point joins the first (omitted when open); for circles seen at an angle and outlines of curved faces |

Lines, arcs, and open curves join end to end into closed regions as lines always have. A solid or cut profile built from such a region may carry `arcs`: `[{"start": i, "segments": n, "center": [u, v], "radius": r}]`, meaning outline points `i … i + n` (wrapping) lie on that circle. The outline is still saved in full (arcs every 3° at most); the kernel builds each run as one exact arc, so the extruded side is a single smooth face whose edges can be named and finished like straight ones.

## Sketches

Decision recorded October 19, 2026. Shapes belong to named sketches ("Sketch 01", "Sketch 02": names are derived from document order, not saved). A workspace may carry `"sketches": [{"id": UUID, "plane": plane, "hidden": true?}]`, and each shape then names its sketch with `"sketch": UUID`. A shape lies on its sketch's plane; a plane may hold several sketches, and each sketch finds its own closed regions. Moving or rotating a sketch changes only its plane frame (any orthonormal frame, stored as for face planes), never its shapes' 2D coordinates. A solid may carry `"hidden": true`. Hidden sketches and solids are not drawn, picked, or snapped to; the key is omitted when visible.

Shapes without sketch data form one sketch per plane, whose id is the plane's first shape's id; a workspace whose sketches are exactly that (one visible sketch per plane, named by its first shape) is written without `sketches` or shape `sketch` keys. A file that has `sketches` must account for every shape; shapes that name a missing sketch are rejected.

## Face extrusions

Decision recorded October 19, 2026. A flat face of a solid can be extruded from where it is (push/pull): outward joins the solid, inward cuts it. It is stored in the solid's ordered `cuts` list as an ordinary join (`"join": true`, positive `depth`) or cut (negative `depth`, never `throughAll`) with one more key, `facePoint`: a point strictly inside the face, in the coordinates of `profile.plane`. That plane is the face's canonical plane with its normal pointing out of the solid, and `profile` is the face's outer boundary (an exact circle for a round face; arcs otherwise saved as points every 5°), used for previews. Rebuilding does not extrude `profile`: it finds the flat face of the solid built so far that lies on that plane, faces the same way, and contains `facePoint`, and extrudes that face exactly, so holes and rounded edges in the face carry through. If an earlier edit (such as changing the solid's depth) moves the face away, the solid fails to rebuild and the edit is refused, as for finishes and cuts that no longer fit.

## Joins

Decision recorded October 18, 2026. A boss extruded onto a solid can be merged into it. A join is stored in the same ordered `cuts` list as cuts, with `"join": true` (the key is omitted for cuts), and the same `profile` and `depth` fields; `throughAll` is never set on a join. Rebuilding replays the list in order, unioning joins and subtracting cuts, so a hole, then a boss over it, then a hole through the boss reproduces exactly. A join must leave one connected solid; it merges into a single solid (the first one it touches). Existing solids are merged with Union (October 19, 2026), stored as `merged` entries (*More operations*).

## File safety and evolution

`UIDocument` owns open documents, coordinated reads/writes, change tracking, and safe replacement. This follows [Apple's document architecture](https://developer.apple.com/documentation/uikit/uidocument), rather than directly rewriting URLs supplied by cloud providers. Security-scoped access is retained for the open document's lifetime. Native Files controls choose the destination for new files and Save As copies. No custom cloud service or iCloud-container entitlement is needed to use user-selected iCloud Drive locations.

The document maintains a locked value snapshot for content serialization and loading; UI updates remain on the main actor. Every committed edit updates that snapshot and requests autosave. Leaving the editor flushes and closes the document before replacing the session. A failed save keeps the current model open and reports the error. Files with unresolved version conflicts are protected against overwriting, and Save As can preserve the working copy separately. There is no custom version-merging interface yet.

The codec validates format, version, units, coordinate system, identities, finite geometry, profile validity, and resource limits before accepting a file. Unknown versions fail explicitly; they never silently load as empty projects. Existing files are preserved on decoding failure. New-file creation refuses to replace an existing path. The current defensive limits are 120 MB per project (imported shapes are the large part), 10,000 sketches, 1,000 solids, and bounded polygon validation work.

The format started over at version 1 on October 20, 2026, with the rename to Swipe & Sketch; earlier `.pencilform` files are not read. The outer project version and nested workspace version are separate. A future incompatible change needs a new version with an explicit decoder or migration and regression fixtures; never reinterpret a version 1 field or discard unknown future geometry. Keep migrations copy-preserving until their output has been verified. The Open CASCADE kernel rebuilds solids from the native analytic source, which stays authoritative; only imported solids store exact bodies (`importedShapes`). Any further exact-body representation needs a new version, added deliberately.

## Export

A native `.swipesketch` project remains the editable original; exports are derived delivery files written to a temporary folder and handed to the share sheet. **3MF and STL are implemented** (`Export.swift`): every solid is rebuilt by the kernel, tessellated at 0.01 mm chordal / 5° angular tolerance (finer than display), and welded so shared edges share vertices; tests verify closed, consistently oriented, manifold meshes with the solid's volume. 3MF is a core-spec OPC package (unit millimeter, one object and build item per solid, deflate-compressed with Apple's Compression framework); STL is binary, all solids in one file, in millimeters. STP remains future work:

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
- **New entries in a solid's `cuts` list** (each with the solid's own profile and depth as placeholders): `"intersected": {solid}` keeps only where that solid's whole definition overlaps; `"scale": {"center": [x, y, z], "xAxis": [..], "yAxis": [..], "factors": [fx, fy, fz]}` scales everything before it about the center, along the axes (all in the solid's own frame, so it moves and mirrors with the solid; factors 0.001–1000); `"removedFaces": {"points": [[x, y, z], …]}` takes off the faces through those points (Delete Face); `"movedFaces": {"points": [...], "distance": mm}` moves those faces along their outward normals (Offset Face). Points are in the solid's own frame, as finish and shell points are; an edit that moves such a face away makes the solid fail to rebuild, and the edit is refused.
- **Sketch shapes:** `kind` may be `ellipse` (`start` its center, `end` the end of its own axis, `width` its diameter across) or `point` (`start` and `end` equal); `construction: true` marks reference geometry that bounds no region. **Regions** (profiles and holes) may carry `ellipse: {"center", "radiusX", "radiusY", "angle"}` when the loop is an exact ellipse.
- **Sketches and construction planes:** an optional `name`.
- **Preview picture:** the project may carry a top-level `"preview"`: a base64 PNG (320 × 320 pixels, at most 1 MB) of the visible solids from the standard 3D angle, or of the sketches when there is no solid. The app draws it when a project is left (closed, another project started, the app sent to the background) and for Save As copies; it is never needed to open the file. The `SwipeAndSketchThumbnails` Quick Look thumbnail extension finds it with a byte search of the memory-mapped file (keys are written sorted, so `preview` comes before `workspace`), so the document browser, Files, and AirDrop show the model; a file without one shows a plain cube instead of its JSON text. UIDocument's thumbnail attributes are not used: iOS ignores them for files on the device (verified October 21, 2026).
- **Groups (Model Tree):** the workspace may carry `"groups": [{"id": UUID, "name"?, "hidden": true?, "parent": UUID?}]`, and solids, sketches, and construction planes an optional `"group": UUID` naming the group they sit in (omitted at the top of the tree). A group's `parent` is the group it sits in. Every referenced group must exist and parents must not loop (at most 32 deep, 1,000 groups); a file that breaks this is refused, not repaired. A hidden group hides everything in it, at any depth, without changing the items' own `hidden`. Groups only organize: they do not move, combine, or export their contents. Whether a group is folded away in the Model Tree is not saved.

Editing after Done (October 24, 2026) adds no data of its own: Edit Hole, Edit Thread, and Edit Text replace their entry in the solid's `cuts` list in place, keeping its `id`, so the entries after it still apply after it. Edit Peg does the same for each solid's peg entries (a separate peg's solid stays where it was in the list).
