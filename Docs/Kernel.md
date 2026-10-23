# Solid-modeling kernel

Decision recorded October 18, 2026. Swipe & Sketch uses **Open CASCADE Technology (OCCT) 8.0.1** as its B-rep solid-modeling kernel. SceneKit stays the renderer. This document covers the integration: what was built, how it is wired, measured results, and known limits.

**Status:** committed solids render from the kernel (see *Canvas rendering* below). The live extrusion preview still uses `SCNShape`. Fillet and chamfer are exposed through the Fillet and Chamfer tools (edge finishes, see [ProjectFiles.md](ProjectFiles.md)); `SolidKernel.solid(for:)` replays a body's finishes on its extrusion. Cuts (Extrude ▸ Cut, including Through All) subtract extruded profiles with `BRepAlgoAPI_Cut`; joins and merges union with `BRepAlgoAPI_Fuse`; Shell uses `BRepOffsetAPI_MakeThickSolid` with open faces found by role (`ssk_face_plane`); holes subtract a tool built by `ssk_hole_tool` (cylinders, plus a counterbore cylinder or a countersink cone). 3MF/STL export tessellates the kernel solids (see ProjectFiles.md, *Export*).

**Incremental rebuilds:** `SolidCache` (Cuts.swift) keeps recently built kernel solids keyed by body value. A body is built from the cached solid of the same body minus its last step (last cut, else last finish), so a live cut or finish preview costs one kernel operation instead of a full replay.

## Why a kernel

SceneKit draws triangle meshes. It cannot run booleans, fillet or chamfer chosen edges, shell, or revolve, and it has no notion of B-rep faces for push/pull. OCCT is the only free kernel that covers every planned v1 modeling operation. It also builds for iPadOS. Commercial alternatives are Parasolid (used by several commercial CAD apps), ACIS, and C3D. Mesh libraries such as Manifold cannot produce true edge fillets.

## Architecture

```
Workspace (analytic sketches + SolidBody definitions, saved in .swipesketch)
   │  derive (never persisted)
   ▼
SolidKernel.swift ──► SSKernel C API (SwipeAndSketch/Kernel) ──► OCCT
   │  KernelSolid (immutable B-rep) → tessellate → KernelMesh (triangles grouped by face, edge polylines)
   ▼
KernelSceneGeometry.swift ──► SCNGeometry: one element per B-rep face + boundary-edge lines
```

- **Boundary.** Swift never touches OCCT types. The facade (`SwipeAndSketch/Kernel/include/SSKernel.h`) is a small C API with opaque immutable shape handles. Every operation returns a new shape, or NULL with a readable reason from `ssk_last_error`. All OCCT exceptions are caught at the boundary. With this boundary, a commercial kernel could replace OCCT without touching app code.
- **Document stays authoritative.** Kernel solids are derived from the saved analytic geometry and are not persisted. Snapshot undo (`WorkspaceHistory`) continues to work unchanged. Direct modeling plus snapshots avoids the topological-naming problem that history-based CAD has to solve.
- **Picking.** Each B-rep face is its own `SCNGeometryElement`, so `SCNHitTestResult.geometryIndex` maps to a face through `KernelSceneGeometry.elementFaces`.
- **Indices are per shape.** Face and edge indices are stable within one shape but renumbered by each operation. A fillet creates new faces and edges.
- **Plane mapping.** `SketchPlane.kernelPlane` uses the same frame as `ProjectFiles.md` and the canvas basis: normal = x × y (Top +Z, Front −Y, Right +X).

## Canvas rendering

`CanvasController.bodyNode(_:selected:)` turns each committed `SolidBody` into a kernel solid, then draws:

- **Faces:** `KernelSceneGeometry` triangles with the existing neutral Lambert material and lighting. There is one element per B-rep face, and the geometry is in world coordinates, so the node has no plane transform.
- **Borders:** the B-rep's boundary edges (seams excluded) as zoom-scaled tubes. `strokeNode` builds these and is shared with the fallback path. Borders are blue when the solid is selected and near-black otherwise.
- **Silhouettes:** `KernelSilhouettes` finds triangle edges inside curved faces where the surface turns away from the camera. These segments are recomputed whenever the view direction changes. They cover cylinders today and fillets later, with no special cases.
- **Cache:** the triangulation, face geometry, borders, and silhouette data are cached per body ID and invalidated when the `SolidBody` value changes. Zoom, orbit, and selection reuse them, and only the strokes are rebuilt.
- **Fallback:** if the kernel rejects a body, the previous `SCNShape` extrusion and analytic edges are used.

The extrusion pipeline merges coplanar faces (`ShapeUpgrade_UnifySameDomain`), so outlines drawn as collinear joined lines produce clean flat sides with no seam strokes. All existing pixel tests for gray shading, dark borders, hidden rear edges, cylinder silhouettes, and border-tap selection pass unchanged.

## Operations exposed

| Swift | OCCT |
| --- | --- |
| `SolidKernel.extrude(profile, depth:)`: polygons, concave outlines, and analytic circles; either direction | `BRepPrimAPI_MakePrism` + `BRepLib::OrientClosedSolid` |
| `boolean(a, b, .union / .subtract / .intersect)` | `BRepAlgoAPI_Fuse/Cut/Common`, fuzzy value 1e-5 mm, `SimplifyResult` merges coplanar faces |
| `fillet(solid, edges:, radius:)` / `chamfer(solid, edges:, distance:)` | `BRepFilletAPI_MakeFillet/MakeChamfer` + `BRepCheck` validation |
| `shell(solid, openFaces:, thickness:)`: hollows inward, keeping outer dimensions | `BRepOffsetAPI_MakeThickSolid::MakeThickSolidByJoin` |
| `ssk_extrude_outlines` (Text.swift): closed loops of lines and quadratic or cubic Béziers on a plane, grouped per glyph (filled loops united, holes cut), extruded between two offsets; returned as one compound | `Geom_BezierCurve` edges, `BRepBuilderAPI_MakeFace`, `BRepPrimAPI_MakePrism`, `BRepAlgoAPI_Fuse`/`Cut` with argument lists |
| `ssk_thread_tool` (Threads.swift): a nut's or bolt's thread tool on an axis: an ISO profile swept along an exact helix (split into half turns), trimmed between two planes; the result is checked and rebuilt with other sweep settings if the boolean dropped the ridge | `Geom_CylindricalSurface` + `Geom2d_Line` helix edges, `BRepOffsetAPI_MakePipeShell` (fixed binormal, or Frenet), `BRepAlgoAPI_Cut` (fuzzy on retry); `ssk_face_cylinder_side`, `ssk_point_inside` (`BRepClass3d_SolidClassifier`) |
| `moved(solid, by:)`: a rigid placement sharing geometry and triangulation, so dragged solids are not rebuilt each frame (SolidCache seeds moved bodies) | `TopoDS_Shape::Moved(TopLoc_Location)` |
| `offset(solid, by:)`: grows a solid outward on every side, for printing clearance (Subtract's clearance) | `BRepOffsetAPI_MakeOffsetShape::PerformByJoin` with rounded joins (sharp joins as a fallback) + `BRepCheck` validation |
| `revolve(profile, spec)`: polygons, exact arcs, and analytic circles about an in-plane axis, 0.1° to 360° either way; `revolve(face:of:about:angle:)` for a solid's own flat face | `BRepPrimAPI_MakeRevol` + `ShapeUpgrade_UnifySameDomain` + `BRepLib::OrientClosedSolid` + `BRepCheck` validation; an axis through the profile is refused before building |
| `importSTEP(at:)`: the closed solids of a STEP file in millimeters; loose faces are sewn and closed shells kept | `STEPControl_Reader` (`SetSystemLengthUnit(1)`) + `BRepBuilderAPI_Sewing` + `BRepBuilderAPI_MakeSolid` + `BRepLib::OrientClosedSolid` |
| `shapeData()` / `shape(from:)`: an imported solid's stored bytes; `importedBase(of:)` places it by the solid's frame, mirrored if flagged | `BinTools::Write/Read` (no triangles); `BRepBuilderAPI_Transform` (a mirror is turned outward again) |
| `extrude` / `revolve` of a region with holes (a profile's `holes`) | `BRepBuilderAPI_MakeFace` on the plane with the outline counterclockwise and each hole clockwise (`ShapeFix_Face` settles anything left), then the prism or revolution |
| `edge(near:)`: the edge nearest a point, for finishes saved by point | bounding boxes, then `BRepExtrema_DistShapeShape` per edge |
| `edgeLength`, `faceArea`, `surfaceArea`, `faceCylinder`; `distance(part, to:, part)` between faces, edges, or whole shapes, with reference points, segments, and arcs (`KernelSolid.point/segment/arc`) for Measure | `BRepGProp` linear and surface properties, `BRepAdaptor_Surface`, `BRepExtrema_DistShapeShape` |
| `isValidSolid`, `volume`, `bounds`, `faceCount`, `edgeCount` | `BRepCheck_Analyzer`, `BRepGProp`, `BRepBndLib` |
| `tessellate()`: 0.02 mm chordal, 5° angular by default | `BRepMesh_IncrementalMesh` |

Text (October 20, 2026) does not use OCCT's FreeType text builder: CoreText supplies the glyph outlines on the Swift side, they are saved in the project, and `ssk_extrude_outlines` builds them.

## Measured results

| Check | Result |
| --- | --- |
| Builds | OCCT 8.0.1 static: the modeling modules (17 toolkits) plus, since STEP import (October 19, 2026), the STEP reader and the 10 toolkits it needs; 27 in all, for iPadOS arm64, iPadOS Simulator arm64 + x86_64, and macOS arm64 |
| Correctness (`swift test`, macOS) | 14 kernel tests pass, including collinear-outline face merging. Exact volumes for boxes and analytic cylinders on all three planes and both depth directions; concave profiles; drilled hole, union, and intersection; flush unions merge into one 6-face box; 12-edge fillet; chamfer; open shell; full enclosure workflow; watertight meshes with outward winding; cylinder vertices within 1e-4 mm of the true radius; oversized fillets fail with a reason and leave the input intact |
| Rendering and picking (simulator) | 3 hosted tests pass. `SCNView.hitTest` at screen points maps hits to the correct B-rep face (the canvas itself now picks with its own ray cast against the kernel mesh), sees through the open top to the floor, and passes through the drilled hole. The offscreen SceneKit render is attached to the test result |
| **On your iPad Air 11-inch (M3), iPadOS 27.2** | Whole enclosure (extrude, fillet 4 edges, shell, drilled hole) **43.4 ms** · tessellate **2.9 ms** (1,760 triangles, 20 faces) · SceneKit geometry **12.2 ms**. This was a single cold run in a fresh test process, so it includes first-use code loading |
| Speed (Apple-silicon Mac, Release kernel) | Extrude 0.1 ms · fillet 12 edges 6.9 ms · fillet 4 edges 3.5 ms · shell 4.5 ms · boolean cut 1.9 ms · tessellate 2.5 ms (1,760 triangles) |
| Size (iPad arm64) | About **+17.8 MB** stripped executable (**~7.6 MB** compressed, roughly the App Store download increase), measured with every facade function referenced and dead-stripping on. With kernel rendering switched on (extrude and tessellate only), the Release executable grew from 1.6 MB to 10.2 MB and the zipped app from 0.4 MB to 3.8 MB. It will approach the full figure as booleans, fillets, and shells are wired in |

To repeat the device timings, run `KernelSceneTests/testReportsOnDeviceKernelTimings` on the iPad and read the `[kernel timing]` lines. The test targets have no development team set; from the command line, add `DEVELOPMENT_TEAM=<the app target's team>` instead of changing the project.

## Known limitations found

- **Shelling after rounding every edge fails.** OCCT cannot hollow a box whose open face is bounded by fillets: the result is invalid, or with intersection joins it is silently unchanged. The facade detects both cases and returns *"this solid cannot be hollowed; try shelling before rounding its edges."* Shelling first and then filleting works, and so does filleting only the vertical edges before shelling. Both are tested. If users hit this often, a fallback is outer minus an inward offset (`BRepOffsetAPI_MakeOffsetShape`), which succeeded in a quick experiment.
- Fillet radii that consume an adjacent face fail, as they should. The UI should suggest a smaller radius.
- `tessellate` caches the triangulation on the shape. `KernelSolid` serializes it with a lock. Do not mesh one shape concurrently from C++.
- **OCCT's STEP reader is not hardened against damaged files** (found October 21, 2026 by feeding it thousands of damaged copies of the test fixtures). A missing entity, a reference to the wrong kind of entity, an entity that refers to itself, or absurd numbers made it dereference null (a crash, not a C++ exception, so `guarded` cannot catch it) or loop forever. `ssk_read_step` now refuses such files before translating them: a text scan before OCCT parses the file rejects reference loops (OCCT's own load check hangs on them), references to entries the file does not define, and numbers beyond 1e10 or nonzero below 1e-100; after parsing, entities with failed load checks, error entities, cartesian points beyond 1e7 or not finite, zero or non-finite directions, vertices on a missing or 2-D point, 3-D placements without a 3-D point, and curves-on-surface not defined by a curve are rejected. After these checks a fresh sweep of 9,000 damaged files (lines lost or cut short, references redirected, numbers changed) read 3,008, refused 5,992, and neither crashed nor hung; the 41 MB kitchen-timer model and the fixtures still import (the scan adds no measurable time). The message asks the user to export the file again. `ImportTests.testDamagedFilesAreRefusedOrReadWithoutCrashing` keeps a seeded sample and both crash fixtures (`SS_DAMAGED_ROUNDS=3000` widens it); `testRealWorldCorpus` (`SS_STEP_CORPUS=<folder>`) checks that real models still import. Remaining risk: a crafted file that is well-formed but geometrically wrong in a way not covered above can still crash the app; on iOS the import cannot run in a separate process.
- Booleans run non-destructively (`SetNonDestructive`), so a boolean never adjusts the tolerances of cached input shapes the canvas may be reading on another thread (October 21, 2026).
- Run heavy operations off the main actor once real modeling tools use them. Current timings are single-digit milliseconds, but complex fillets can take longer.

## Building the kernel

```sh
Scripts/build_kernel.sh            # first run: clone OCCT V8_0_1 and build 3 slices (~25 min on M-series), then the facade
Scripts/build_kernel.sh --facade   # after editing SwipeAndSketch/Kernel: rebuild facade + XCFramework (~10 s)
```

The facade gained `ssk_extrude_profile` (straight edges plus exact three-point arcs, for projected outlines) and, later that day, `ssk_revolve_profile`, `ssk_revolve_circle`, and `ssk_revolve_face` (Revolve) on October 19, 2026: rebuild with `--facade` after pulling. STEP import (October 19, 2026) added `ssk_read_step`, `ssk_solid_count`, `ssk_solid`, `ssk_write_shape`, `ssk_read_shape`, `ssk_transform`, and `ssk_edge_distance`, and links OCCT's STEP reader (`TKDESTEP` and the toolkits it needs, listed in `STEP_TOOLKITS`): run the full script once after pulling (it compiles only the new toolkits into the existing OCCT build). Later on October 20, 2026 it gained `ssk_offset_solid` (Subtract clearance), then `ssk_thread_tool`, `ssk_face_cylinder_side`, `ssk_point_inside`, and `ssk_moved` (Threads, drag speed), and `ssk_extrude_outlines` (Text): rebuild with `--facade` after pulling. On October 20, 2026 the facade gained `ssk_extrude_region` and `ssk_revolve_region` (regions with holes), `ssk_face_cylinder`, `ssk_edge_length`, `ssk_face_area`, `ssk_surface_area`, `ssk_edge_near`, `ssk_distance`, and `ssk_make_point`/`ssk_make_segment`/`ssk_make_arc` (fillets on any edge, Measure): rebuild with `--facade` after pulling.

Output is `Vendor/SSKernel.xcframework`, which is about 290 MB of static libraries and is git-ignored. OCCT sources and objects live under `build/occt` and are ignored too. The Xcode app target links the XCFramework with no embedding. `Package.swift` uses it as a binary target so `swift test` exercises the kernel on macOS. The facade header's module map links `libc++`.

## License obligations (LGPL 2.1 + Open CASCADE exception)

OCCT is LGPL 2.1 with the *Open CASCADE exception*. The exception allows distributing object code that incorporates OCCT header material under terms of your choice, **provided you give prominent notice in supporting documentation that the software uses Open CASCADE Technology**. Before shipping:

1. Add an in-app Acknowledgements screen and App Store / website notice: "This software uses Open CASCADE Technology (https://dev.opencascade.org), licensed under LGPL 2.1 with the Open CASCADE exception." Include the license texts from `build/occt/src/LICENSE_LGPL_21.txt` and `OCCT_LGPL_EXCEPTION.txt`.
2. Decision (October 21, 2026): OCCT stays statically linked and the app's GitHub repository will be published, so anyone can rebuild and relink the app against a modified OCCT (LGPL 2.1 §6). The Acknowledgements screen links to the repository. Background: get a legal review of static linking on the App Store if in doubt. Plain LGPL 2.1 expects users to be able to relink against a modified library. Open Cascade's maintainers have stated publicly that their license does not require dynamic linking, but that is a forum statement, not license text. Shipping OCCT as a dynamic framework is the conservative alternative.
3. Keep OCCT unmodified, or publish any modifications to OCCT itself. The facade is your own code.
