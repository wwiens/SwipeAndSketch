# Radial toolbar

The radial toolbar is a movable wheel holding every tool from the dock, in the same modeling and sketching groups. It is the default layout; Settings ▸ Workspace ▸ Tool Layout chooses Dock or Radial Toolbar. The choice and the wheel's center (as a fraction of the window) are saved on the device.

## Workspace modes

New preferences start in Essentials. The workspace control at the top of every project, or Settings ▸ Workspace Mode, switches between Essentials and All Tools. The device remembers `workspace.mode` across projects and launches. The selection is independent of the tool layout and is never stored in a project file.

The Integrated project header groups the left-aligned document name, save status, and item counts. The workspace selector is a quiet text control with the existing disclosure glyph rotated downward, separated from document details by a short divider. The only ellipsis opens the project menu. The header is at most 642 points wide; below 440 available points the workspace selector moves below the document details. Home, workspace, and project-menu controls keep 44-point touch targets and ignore touches during an active canvas Pencil stroke. Show Tips is also available directly in the workspace menu.

Essentials shows Sketch, Create, Modify, Combine, and Transform. Create puts Box, Cylinder, Sphere, and Torus directly beside Extrude. Modify offers Fillet, Chamfer, and Shell; Combine offers Union and Subtract; Transform offers Align and Scale. Sketching keeps Line, Rectangle, Circle, Arc, Slot, Trim, Fillet, Offset, and Dimension, plus Hole and Text on a face. All Tools retains the full catalog below. Both layouts use the same filtering policy.

Essentials adds the current help topic's overview beneath the hint. Settings ▸ Workspace ▸ Show Tips can hide these extra explanations while keeping the current tool hint and Help available. Tips start on, and `workspace.showTips` remembers the choice across projects, launches, and workspace-mode changes. Extrude starts with its common controls, with More Options revealing Symmetric, Taper, and Up To. Collapsing those controls keeps their settings and displays active values. All Tools shows the options directly. Switching workspace modes closes tool menus but preserves selection, active tools, drafts, previews, geometry, access policy, and history. Existing feature-edit controls and the full Controls guide remain available in both workspaces.

The wheel keeps a stable set of modeling or sketching sectors in complete concentric rings, and shares the dock's command catalog and dispatcher. Opening the Model Tree or selecting geometry does not replace its tools.

## Tool coverage

| Mode / first ring | Second ring | Third ring |
| --- | --- | --- |
| Modeling: Sketch | Begins plane selection / sketching | |
| Project | Existing Project operation | |
| Planes | Offset Plane, Midplane, Plane at Angle, 3-Point Plane, Tangent Plane, Axis | |
| Create | Extrude, Revolve, Loft, Sweep, Rib, Primitives | Box, Cylinder, Sphere, Torus |
| Modify | Fillet, Chamfer, Shell, Draft, Delete Face, Split Body | |
| Combine | Union, Subtract, Intersect | |
| Transform | Align, Scale, Mirror, Pattern | |
| Joints | Peg & Socket, Thread, Screw Lid, Fit Test | |
| Sketching: Finish Sketch | Ends sketching | |
| Line, Rectangle | Direct commands; tapping active Rectangle switches Center / Corners | |
| Shapes | Circle, Arc, Slot, Ellipse, Polygon, Spline, Point | |
| Modify | Trim, Extend, Fillet, Offset, Mirror | |
| Dimension, Project | Direct commands | |
| Features (flat face sketch only) | Hole, Peg & Socket, Text | |

`ToolbarEntry.roots` feeds both layouts. `ToolGroup.tools` feeds the dock popups and radial children. Create only subdivides its existing primitive tools; it does not omit them. Identifiers and modeling commands retain their existing values. Automated coverage compares the reachable tools in every group.

Selection actions, dimension editing, operation controls, Undo, Redo, and Controls remain available in their existing bottom areas in both layouts. Numeric editors and Keep/Cancel controls retain their existing validation and undo behavior. These controls are deliberately not compressed into sectors. Operation and assistant review controls temporarily suspend the wheel, and the Tools button does nothing meanwhile; whether it was shown or hidden is restored afterward. A read-only file shows the wheel with its tools disabled, like the dock.

## Interaction and visual design

- First-ring sectors have stable names and positions within each mode; an active tool highlights its group without renaming it.
- A group opens ring two. Create > Primitives opens ring three. The violet hub goes back one level, then hides the wheel.
- Drag the hub with Pencil or a finger. UIKit moves the hosted wheel directly during tracking; SwiftUI and the saved position update only at lift. Cancelling restores the saved location. The position is independent of the document and camera. The hub has no grip bar or instructional caption.
- The bottom-right Tools button toggles visibility. Pencil Pro squeeze toggles on completion, when the system preference is Show Contextual Palette. Active and cancelled squeezes do nothing. Opening by squeeze preserves the saved location.
- The wheel stays open while selecting and drawing on uncovered canvas. There is no screen-wide dismissal layer. The existing Pencil-only drawing and finger navigation paths are unchanged. The wheel's palm guard disables its controls during a canvas Pencil stroke.
- The first ring is 272 points across; the 64-point outer rings make two rings 412 points and three rings 552 points across. Captions (icon, title, and optional subtitle) are measured against their annular sector and kept at least three points from its edges; layouts are cached, so dragging adds no measuring. Caption hit areas stay inside their own sectors.
- Full-sector hit areas surround conventional accessible buttons; the hub also has VoiceOver move actions. Reduce Motion disables ring animations. Glyphs and colors come from the existing Swipe & Sketch assets.
- A ring that would extend off screen temporarily brings the center inward; collapsing restores the preferred location. The wheel stays beside the Notes and Assistant panels, in portrait too, unless the room left is too narrow for two rings. Rotation and side-panel changes recompute bounds.
- Windows too small for three rings show primitives in ring two with Back. Windows too small for two rings show the selected group's tools in ring one and use the hub to return. Targets are never scaled down.

Pencil squeeze follows Apple's [Pencil interaction guidance](https://developer.apple.com/documentation/uikit/uipencilinteraction) and SwiftUI's `onPencilSqueeze` API. A simulator cannot establish physical squeeze reliability, Pencil feel, or palm rejection; those require an iPad and Pencil Pro.

## Verification

App tests check complete tool reachability, stable identifiers, target separation, and placement constraints. Simulator UI tests check dock regression, layout switching, tool groups, three-ring primitives, operation cancellation, sketch tools, movement and hide/show persistence, canvas taps, and portrait containment. Existing canvas tests cover geometry/input/rendering integration. An exhaustive test lays out every entry in modeling, sketching, face-feature, primitive, and compact arrangements. None of this verifies hardware: Pencil Pro squeeze, Pencil feel, and palm rejection need an iPad and Pencil Pro.

Workspace-mode coverage checks the shared Essentials tool policy and every Essentials radial caption. UI scenarios exercise both layouts, preserve a selected body and an active drawing tool across mode switches, change the mode in Settings, and relaunch to verify persistence. An Extrude scenario retains a typed depth and Symmetric setting across collapsed options and mode switches, commits the solid, and undoes it in one step. Hosted canvas tests also verify primitive dimensions, placement on a face, validation, cancellation, and undo.
