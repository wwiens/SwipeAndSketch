// Swipe & Sketch solid-modeling kernel facade.
//
// A small C API over Open CASCADE Technology (OCCT). Swift never sees OCCT types: shapes are
// opaque, immutable handles, and every operation returns a new shape (or NULL on failure, with
// the reason available from ssk_last_error). Units are millimeters in a right-handed, Z-up world.
//
// Face and edge indices are zero-based positions in the shape's own topology maps. They are
// stable for a given shape, but are NOT preserved across operations (a fillet renumbers edges).
#ifndef SSKKERNEL_H
#define SSKKERNEL_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SSKShape SSKShape;
typedef struct SSKMesh SSKMesh;

typedef struct { double x, y, z; } SSKVec3;

/// Places 2D sketch coordinates in the world: point(u, v) = origin + u * xAxis + v * yAxis.
/// Extrusion follows the plane normal, xAxis × yAxis. Axes must be orthonormal.
typedef struct { SSKVec3 origin, xAxis, yAxis; } SSKPlane;

typedef enum { SSKBooleanUnion = 0, SSKBooleanSubtract = 1, SSKBooleanIntersect = 2 } SSKBooleanOp;

/// Bits in ssk_mesh_edge_flags.
enum { SSKEdgeSeam = 1, SSKEdgeDegenerate = 2 };

/// Reason for the most recent failed call on the calling thread, or NULL.
const char *ssk_last_error(void);
const char *ssk_occt_version(void);

// Construction. `xy` holds pointCount (u, v) pairs describing a simple closed polygon.
SSKShape *ssk_extrude_polygon(SSKPlane plane, const double *xy, int32_t pointCount, double depth);
SSKShape *ssk_extrude_circle(SSKPlane plane, double centerU, double centerV, double radius, double depth);
/// A closed profile of straight edges and exact circular arcs. Edge i runs from point i to point
/// (i + 1) % pointCount; when `mids` holds finite (u, v) at pair i, that edge is the arc through it.
SSKShape *ssk_extrude_profile(SSKPlane plane, const double *xy, const double *mids, int32_t pointCount, double depth);
/// Revolves a profile about the in-plane axis from (axisU0, axisV0) toward (axisU1, axisV1),
/// right-handed, by `degrees` (0.1 to 360 either way; ±360 is a full revolution). The profile must
/// stay on one side of the axis (touching it is fine). `mids` follows ssk_extrude_profile and may
/// be NULL for straight edges only.
SSKShape *ssk_revolve_profile(SSKPlane plane, const double *xy, const double *mids, int32_t pointCount,
                            double axisU0, double axisV0, double axisU1, double axisV1, double degrees);
SSKShape *ssk_revolve_circle(SSKPlane plane, double centerU, double centerV, double radius,
                           double axisU0, double axisV0, double axisU1, double axisV1, double degrees);
/// A region with holes: `loopCount` closed loops, the first its outer boundary and the rest holes
/// inside it. Loop i takes the next `loopSizes[i]` points of `xy` (and pairs of `mids`, as in
/// ssk_extrude_profile). A loop of one point is a full circle through that point about the center
/// held in its `mids` pair.
SSKShape *ssk_extrude_region(SSKPlane plane, const double *xy, const double *mids, const int32_t *loopSizes, int32_t loopCount,
                           double depth);
SSKShape *ssk_revolve_region(SSKPlane plane, const double *xy, const double *mids, const int32_t *loopSizes, int32_t loopCount,
                           double axisU0, double axisV0, double axisU1, double axisV1, double degrees);

/// The general region builder (October 21, 2026): ssk_extrude_region's loops, where a loop may
/// also be a full ellipse (one point, its center, with `ellipses[4 * i …]` = major radius, minor
/// radius, angle of the major axis from the plane's x axis in radians, and 1; 0 in the last slot
/// for any other loop; `ellipses` may be NULL). The region starts `offset` mm along the normal and
/// runs `depth` mm (either sign), its sides leaning in by `draftDegrees` (−89 to 89; positive
/// narrows toward the far end, 0 is a plain prism).
SSKShape *ssk_extrude_region_ex(SSKPlane plane, const double *xy, const double *mids, const double *ellipses,
                                const int32_t *loopSizes, int32_t loopCount, double offset, double depth, double draftDegrees);
/// ssk_revolve_region with the loops of ssk_extrude_region_ex.
SSKShape *ssk_revolve_region_ex(SSKPlane plane, const double *xy, const double *mids, const double *ellipses,
                                const int32_t *loopSizes, int32_t loopCount,
                                double axisU0, double axisV0, double axisU1, double axisV1, double degrees);
/// Outlines `distance` mm from a chain of sketch edges (points and arc mids as in
/// ssk_extrude_profile; `closed` joins the last point to the first). A closed loop grows outward
/// for positive distances and shrinks for negative ones; an open chain moves to its left (positive)
/// or right. Corners stay sharp (`rounded` false) or become arcs. The result is written as loops in
/// the same format (a full circle as one point with its center in the mids pair; other curves as
/// sampled straight edges): up to `capacity` points and `loopCapacity` loops, with `closedLoops[i]`
/// telling whether loop i closes. Returns the total point count (which may exceed `capacity`;
/// call again with room), or -1 on failure.
int32_t ssk_offset_outline(SSKPlane plane, const double *xy, const double *mids, int32_t pointCount, bool closed, double distance,
                           bool rounded, double *outXY, double *outMids, int32_t *outLoopSizes, bool *closedLoops,
                           int32_t capacity, int32_t loopCapacity, int32_t *loopCount);

// Modeling operations. Inputs are never modified.
SSKShape *ssk_boolean(const SSKShape *a, const SSKShape *b, SSKBooleanOp op);
SSKShape *ssk_fillet(const SSKShape *shape, const int32_t *edges, int32_t edgeCount, double radius);
SSKShape *ssk_chamfer(const SSKShape *shape, const int32_t *edges, int32_t edgeCount, double distance);
/// Hollows a solid inward to `thickness`, removing `openFaces` (may be empty for a closed shell).
SSKShape *ssk_shell(const SSKShape *shape, const int32_t *openFaces, int32_t faceCount, double thickness);
/// Extrudes closed outlines of lines and Bézier curves drawn on `plane` (text glyphs). Loop i has
/// `segmentCounts[i]` segments, whose degrees (1 line, 2 quadratic, 3 cubic) follow in `degrees`.
/// `xy` holds, per loop, its start point and then each segment's points after its start (as many
/// as its degree), as (u, v) pairs. Loops with the same `groups` value form one shape (a glyph):
/// its `filled` loops are united and the rest taken away as holes. Shapes run from `offset` to
/// `offset + depth` along the normal and are returned together as one compound.
SSKShape *ssk_extrude_outlines(SSKPlane plane, const double *xy, const int32_t *degrees, const int32_t *segmentCounts,
                               const int32_t *groups, const bool *filled, int32_t loopCount, double offset, double depth);
/// The tool for a modeled screw thread about the axis through `origin` along `axis` (`reference` is
/// any direction across it), from `start` to `end` along the axis. The thread has an ISO 60° profile
/// of `pitch`, its ridge running from `rootRadius` to `crestRadius`. Internal (a nut, on a hole of
/// `surfaceRadius`): the ridge itself. External (a bolt, on a round boss of `surfaceRadius`): the
/// grooves between its turns. Either way, subtract the result. `starts` ridges (1–8) wind side by
/// side a pitch apart, so each turn advances `starts` pitches.
/// `raised`: the thread is added onto the face instead of cut into it, and the result is united
/// with the solid. External: the ridges (and anything between the face and the root) outside
/// `surfaceRadius`. Internal: the nut's ridges (and anything between the crest and the face)
/// inside it. Either way only from `clipStart` to `clipEnd` along the axis (the face's own extent),
/// reaching a little into the face so the union joins.
SSKShape *ssk_thread_tool(SSKVec3 origin, SSKVec3 axis, SSKVec3 reference, double start, double end, double pitch,
                          double crestRadius, double rootRadius, double surfaceRadius, bool internal, bool leftHanded, int32_t starts,
                          bool raised, double clipStart, double clipEnd);
/// Tests only: makes ssk_thread_tool on this thread try just its fallback attempt `attempt` (0 is
/// the first), or every attempt in turn again when it is -1. Returns how many attempts there are.
int32_t ssk_set_thread_attempt(int32_t attempt);
/// For a cylindrical face: 1 when it faces away from its axis (a round boss), -1 when it faces the
/// axis (a hole), 0 for any other face.
int32_t ssk_face_cylinder_side(const SSKShape *shape, int32_t face);
/// True when `point` lies strictly inside the solid.
bool ssk_point_inside(const SSKShape *shape, SSKVec3 point);
/// The solid grown outward by `distance` (0.001 to 50 mm) on every side: each point of the result's
/// surface lies that far from the input. Used for printing clearance around a mating part.
SSKShape *ssk_offset_solid(const SSKShape *shape, double distance);
/// Extrudes flat face `face` of a solid exactly as it is (curved edges and holes included) along
/// its outward normal: positive depth grows out of the solid, negative goes into it. The result is
/// the prism alone; union or subtract it.
SSKShape *ssk_extrude_face(const SSKShape *shape, int32_t face, double depth);
/// Revolves flat face `face` of a solid exactly as it is about the world axis from `axisFrom`
/// toward `axisTo` (right-handed, `degrees` as in ssk_revolve_profile). The result is the swept
/// solid alone; union or subtract it.
SSKShape *ssk_revolve_face(const SSKShape *shape, int32_t face, SSKVec3 axisFrom, SSKVec3 axisTo, double degrees);
// STEP import and stored shapes.
/// Reads the solids of a STEP file, in millimeters, as one compound (see ssk_solid). Surfaces that
/// are not part of a solid are sewn, and each closed shell becomes a solid; what stays open is
/// counted in `skipped`. NULL when the file has no closed solid.
SSKShape *ssk_read_step(const char *path, int32_t *skipped);
int32_t ssk_solid_count(const SSKShape *shape);
SSKShape *ssk_solid(const SSKShape *shape, int32_t index);
/// The shape in OCCT's binary B-rep format (exact geometry, no triangles). Free with ssk_bytes_free.
uint8_t *ssk_write_shape(const SSKShape *shape, int64_t *length);
void ssk_bytes_free(uint8_t *bytes);
SSKShape *ssk_read_shape(const uint8_t *bytes, int64_t length);
/// The shape moved by world = R * p + t, with `m` the 3 × 4 row-major matrix [R | t]. R must be
/// orthonormal; a mirror (determinant −1) is allowed and the result is turned outward again.
SSKShape *ssk_transform(const SSKShape *shape, const double *m);
/// The shape placed by a rigid motion (no mirror), sharing its geometry and triangulation with the
/// input: instant, for solids being dragged. `m` is as in ssk_transform.
SSKShape *ssk_moved(const SSKShape *shape, const double *m);
/// The shape scaled about `center` by `fx`, `fy`, `fz` along the orthonormal axes `xAxis`, `yAxis`,
/// and their cross product (each 0.001 to 1000). Equal factors scale exactly; unequal ones stretch
/// the shape (curved faces become free-form surfaces).
SSKShape *ssk_scale(const SSKShape *shape, SSKVec3 center, SSKVec3 xAxis, SSKVec3 yAxis, double fx, double fy, double fz);
/// The solid with `faces` removed and the gap healed by extending the faces around them (a fillet,
/// chamfer, hole, or boss taken away). Fails when the neighbors cannot close the gap.
SSKShape *ssk_remove_faces(const SSKShape *shape, const int32_t *faces, int32_t faceCount);
/// The solid with `faces` moved `distance` mm along their outward normals (negative moves them
/// in), the faces around them following: a flat face pushed or pulled, or a round face's radius
/// grown or shrunk.
SSKShape *ssk_offset_faces(const SSKShape *shape, const int32_t *faces, int32_t faceCount, double distance);
/// Distance from a point to edge `edge`, or −1 on failure.
double ssk_edge_distance(const SSKShape *shape, int32_t edge, SSKVec3 point);
void ssk_shape_free(SSKShape *shape);

// Queries.
int32_t ssk_face_count(const SSKShape *shape);
int32_t ssk_edge_count(const SSKShape *shape);
/// True for exactly one closed, valid solid (BRepCheck), suitable for watertight export.
bool ssk_is_valid_solid(const SSKShape *shape);
double ssk_volume(const SSKShape *shape);
void ssk_bounds(const SSKShape *shape, SSKVec3 *minimum, SSKVec3 *maximum);
/// Samples `count` (≥ 2) points evenly in parameter along edge `edge`, including both ends,
/// into `xyz` (3 × count doubles). Returns false for a bad index or a degenerate edge.
bool ssk_edge_samples(const SSKShape *shape, int32_t edge, int32_t count, double *xyz);
/// Writes the indices of face `face`'s edges (each once) into `edges` (up to `capacity`) and
/// returns how many the face has, or -1 for a bad index.
int32_t ssk_face_edges(const SSKShape *shape, int32_t face, int32_t *edges, int32_t capacity);
/// Area centroid of face `face` into `xyz`. Returns false for a bad index.
bool ssk_face_center(const SSKShape *shape, int32_t face, double *xyz);
/// For an edge lying on a circle (full circle or arc), its center into `xyz` and radius.
bool ssk_edge_circle(const SSKShape *shape, int32_t edge, double *xyz, double *radius);
/// For a flat face: a point on it into `origin` and its outward unit normal into `normal`.
bool ssk_face_plane(const SSKShape *shape, int32_t face, double *origin, double *normal);
/// For a cylindrical face: a point on its axis, the axis direction, and its radius.
bool ssk_face_cylinder(const SSKShape *shape, int32_t face, double *axisPoint, double *axisDirection, double *radius);

// Measurement.
/// Length of edge `edge` in millimeters, or -1 for a bad index.
double ssk_edge_length(const SSKShape *shape, int32_t edge);
/// Area of face `face` in square millimeters, or -1 for a bad index.
double ssk_face_area(const SSKShape *shape, int32_t face);
/// Total area of every face of the shape.
double ssk_surface_area(const SSKShape *shape);
/// The edge nearest `point` within `tolerance` mm, or -1. Edges whose bounding box is farther
/// away are skipped without measuring.
int32_t ssk_edge_near(const SSKShape *shape, SSKVec3 point, double tolerance);

/// Which part of a shape a distance is measured from.
typedef enum { SSKPartWhole = 0, SSKPartFace = 1, SSKPartEdge = 2 } SSKPart;
/// The minimum distance between a part of `a` and a part of `b` (a face or edge by index, or the
/// whole shape), with the nearest points on each into `pointA` and `pointB`. -1 on failure.
double ssk_distance(const SSKShape *a, SSKPart partA, int32_t indexA, const SSKShape *b, SSKPart partB, int32_t indexB,
                   SSKVec3 *pointA, SSKVec3 *pointB);
/// Reference geometry to measure against: a point, a straight segment, and a circular arc about
/// `center` starting at `start`, turning right-handed about `normal` by `degrees` (360: a circle).
SSKShape *ssk_make_point(SSKVec3 point);
SSKShape *ssk_make_segment(SSKVec3 a, SSKVec3 b);
SSKShape *ssk_make_arc(SSKVec3 center, SSKVec3 normal, SSKVec3 start, double degrees);

/// The flat face whose outward normal is `normal` and that contains `point` strictly inside
/// (within `tolerance` mm of its plane), or -1 when there is none.
int32_t ssk_face_at(const SSKShape *shape, SSKVec3 point, SSKVec3 normal, double tolerance);
/// The face (flat or curved) nearest `point` within `tolerance`, or -1.
int32_t ssk_face_near(const SSKShape *shape, SSKVec3 point, double tolerance);
/// The outer boundary of face `face` as an ordered closed polygon into `xyz` (3 doubles per point,
/// up to `capacity` points): straight edges give their start, arcs a point every 5°, other curves
/// 24 points. Returns the point count (which may exceed `capacity`), or -1 for a bad index.
/// `singleEdge` receives the boundary's edge index when it is one edge (a full circle), else -1.
int32_t ssk_face_outline(const SSKShape *shape, int32_t face, double *xyz, int32_t capacity, int32_t *singleEdge);

/// A hole-making tool at sketch point (u, v) on `plane`, drilled along −normal (into a face
/// whose normal points out of the solid). Depth is measured from the plane. Optional features:
/// a counterbore (diameter > hole, depth > 0) and a countersink (diameter > hole, included
/// angle in degrees). Subtract the result from the solid.
SSKShape *ssk_hole_tool(SSKPlane plane, double u, double v, double diameter, double depth,
                      double counterboreDiameter, double counterboreDepth,
                      double countersinkDiameter, double countersinkAngle);

/// Triangulates for display. Deflections are absolute (mm) and in radians. The triangulation is
/// cached on the shape, so do not tessellate one shape from several threads concurrently.
SSKMesh *ssk_tessellate(const SSKShape *shape, double linearDeflection, double angularDeflection);
void ssk_mesh_free(SSKMesh *mesh);

int32_t ssk_mesh_vertex_count(const SSKMesh *mesh);
const float *ssk_mesh_positions(const SSKMesh *mesh);  // xyz per vertex
const float *ssk_mesh_normals(const SSKMesh *mesh);    // xyz per vertex, outward
int32_t ssk_mesh_index_count(const SSKMesh *mesh);
const uint32_t *ssk_mesh_indices(const SSKMesh *mesh); // counter-clockwise triangles seen from outside
/// Triangles are grouped by B-rep face: face i owns indices [starts[i], starts[i + 1]).
int32_t ssk_mesh_face_count(const SSKMesh *mesh);
const int32_t *ssk_mesh_face_starts(const SSKMesh *mesh);
/// Edge i owns polyline points [starts[i], starts[i + 1]) of ssk_mesh_edge_points (xyz each).
int32_t ssk_mesh_edge_count(const SSKMesh *mesh);
const int32_t *ssk_mesh_edge_starts(const SSKMesh *mesh);
const float *ssk_mesh_edge_points(const SSKMesh *mesh);
const uint8_t *ssk_mesh_edge_flags(const SSKMesh *mesh);

#ifdef __cplusplus
}
#endif

#endif
