// Swipe & Sketch kernel facade over Open CASCADE Technology. See include/SSKernel.h.
//
// This software uses facilities provided by the Open CASCADE Technology software
// (https://dev.opencascade.org), licensed under the GNU LGPL 2.1 with the Open CASCADE exception.

#include "SSKernel.h"

#include <BRepAdaptor_Curve.hxx>
#include <BRepAlgoAPI_Defeaturing.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepOffsetAPI_MakeOffset.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <gp_Elips.hxx>
#include <gp_GTrsf.hxx>
#include <gp_Mat.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BinTools.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepLib.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <Geom2d_Line.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepTools.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GProp_GProps.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Poly_Triangulation.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_PrinterOStream.hxx>
#include <STEPControl_Reader.hxx>
#include <Interface_Check.hxx>
#include <Interface_InterfaceModel.hxx>
#include <StepGeom_CartesianPoint.hxx>
#include <StepGeom_Direction.hxx>
#include <StepShape_VertexPoint.hxx>
#include <StepGeom_Axis2Placement3d.hxx>
#include <StepGeom_Curve.hxx>
#include <StepGeom_Pcurve.hxx>
#include <StepRepr_DefinitionalRepresentation.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Pln.hxx>

#include <cmath>
#include <cstring>
#include <sstream>
#include <algorithm>
#include <exception>
#include <memory>
#include <string>
#include <vector>
#include <cctype>
#include <fstream>
#include <iterator>
#include <unordered_map>
#include <unordered_set>

using ShapeMap = NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>;
using AncestorMap = NCollection_IndexedDataMap<TopoDS_Shape, NCollection_List<TopoDS_Shape>, TopTools_ShapeMapHasher>;

struct SSKShape {
    TopoDS_Shape shape;
    ShapeMap faces;
    ShapeMap edges;
    explicit SSKShape(const TopoDS_Shape &value) : shape(value) {
        TopExp::MapShapes(shape, TopAbs_FACE, faces);
        TopExp::MapShapes(shape, TopAbs_EDGE, edges);
    }
};

struct SSKMesh {
    std::vector<float> positions, normals, edgePoints;
    std::vector<uint32_t> indices;
    std::vector<int32_t> faceStarts, edgeStarts;
    std::vector<uint8_t> edgeFlags;
};

namespace {

thread_local std::string lastError;
constexpr double kBooleanFuzz = 1e-5;      // tolerates coincident faces from snapped sketches

void fail(const std::string &message) { lastError = message; }

/// Runs an OCCT operation, converting every failure mode into NULL plus ssk_last_error.
template <typename Body> SSKShape *guarded(const char *operation, Body body) {
    lastError.clear();
    try {
        TopoDS_Shape result = body();
        if (result.IsNull()) { fail(std::string(operation) + " produced no shape"); return nullptr; }
        return new SSKShape(result);
    } catch (const Standard_Failure &error) {
        fail(std::string(operation) + " failed: " + (error.what() && *error.what() ? error.what() : error.ExceptionType()));
    } catch (const std::exception &error) {
        fail(std::string(operation) + " failed: " + error.what());
    } catch (...) {
        fail(std::string(operation) + " failed");
    }
    return nullptr;
}

gp_Pnt point(const SSKPlane &plane, double u, double v) {
    return gp_Pnt(plane.origin.x + u * plane.xAxis.x + v * plane.yAxis.x,
                  plane.origin.y + u * plane.xAxis.y + v * plane.yAxis.y,
                  plane.origin.z + u * plane.xAxis.z + v * plane.yAxis.z);
}

gp_Dir normal(const SSKPlane &plane) {
    gp_Vec x(plane.xAxis.x, plane.xAxis.y, plane.xAxis.z), y(plane.yAxis.x, plane.yAxis.y, plane.yAxis.z);
    return gp_Dir(x.Crossed(y));
}

/// A fillet or chamfer that runs out of room returns a broken shape rather than throwing.
TopoDS_Shape requireValid(const TopoDS_Shape &shape, const char *message) {
    if (shape.IsNull() || !BRepCheck_Analyzer(shape).IsValid()) throw Standard_Failure(message);
    return shape;
}

/// Sweeps are oriented by the profile winding; make every solid point its faces outward.
TopoDS_Shape outwardSolid(const TopoDS_Shape &swept, const char *kind) {
    // Collinear outline points (lines joined end to end) would leave seams on flat sides.
    ShapeUpgrade_UnifySameDomain unify(swept, true, true, false);
    unify.Build();
    TopoDS_Shape shape = unify.Shape();
    for (TopExp_Explorer it(shape, TopAbs_SOLID); it.More(); it.Next()) {
        TopoDS_Solid solid = TopoDS::Solid(it.Current());
        BRepLib::OrientClosedSolid(solid);
        return solid;
    }
    throw Standard_Failure((std::string(kind) + " is not a solid").c_str());
}

TopoDS_Shape prism(const TopoDS_Face &face, const gp_Dir &direction, double depth) {
    if (!std::isfinite(depth) || std::fabs(depth) < 0.01) throw Standard_Failure("depth must be at least 0.01 mm");
    BRepPrimAPI_MakePrism maker(face, gp_Vec(direction) * depth, true);
    if (!maker.IsDone()) throw Standard_Failure("prism construction did not complete");
    return outwardSolid(maker.Shape(), "prism");
}

/// Turns `face` about the axis from `from` toward `to`, right-handed, by `degrees` (±360 is a
/// full revolution). The profile must stay on one side of the axis; touching it is fine.
TopoDS_Shape revolution(const TopoDS_Face &face, const gp_Pnt &from, const gp_Pnt &to, double degrees) {
    if (!std::isfinite(degrees) || std::fabs(degrees) < 0.1 || std::fabs(degrees) > 360 + 1e-9)
        throw Standard_Failure("angle must be between 0.1° and 360°");
    if (from.Distance(to) < 1e-6) throw Standard_Failure("the axis is degenerate");
    const gp_Ax1 axis(from, gp_Dir(gp_Vec(from, to)));
    const bool full = std::fabs(degrees) >= 360 - 1e-9;
    BRepPrimAPI_MakeRevol maker(face, axis, full ? 2 * M_PI : degrees * M_PI / 180, true);
    if (!maker.IsDone()) throw Standard_Failure("revolution did not complete");
    return requireValid(outwardSolid(maker.Shape(), "revolution"), "the axis crosses the profile");
}

/// Signed distances of sketch points from the axis line, in the plane: all must share a side.
void requireOneSide(const std::vector<std::pair<double, double>> &points, double au, double av, double bu, double bv, double reach = 0) {
    const double du = bu - au, dv = bv - av, length = std::hypot(du, dv);
    if (!(length > 1e-6)) throw Standard_Failure("the axis is degenerate");
    double low = 0, high = 0;
    for (const auto &p : points) {
        const double side = (du * (p.second - av) - dv * (p.first - au)) / length;
        low = std::min(low, side - reach);
        high = std::max(high, side + reach);
    }
    const double tolerance = 1e-6;
    if (low < -tolerance && high > tolerance) throw Standard_Failure("the axis crosses the profile");
    if (high - low <= tolerance) throw Standard_Failure("the profile lies on the axis");
}

TopoDS_Shape extrude(const TopoDS_Face &face, const SSKPlane &plane, double depth) { return prism(face, normal(plane), depth); }

/// A flat face's outward normal (its plane normal, flipped for reversed faces).
bool outwardNormal(const TopoDS_Face &face, gp_Dir &result) {
    BRepAdaptor_Surface surface(face);
    if (surface.GetType() != GeomAbs_Plane) return false;
    result = surface.Plane().Axis().Direction();
    if (face.Orientation() == TopAbs_REVERSED) result.Reverse();
    return true;
}

NCollection_List<TopoDS_Shape> select(const ShapeMap &map, const int32_t *indices, int32_t count, const char *kind) {
    if (count <= 0 || !indices) throw Standard_Failure((std::string("no ") + kind + " selected").c_str());
    NCollection_List<TopoDS_Shape> result;
    for (int32_t i = 0; i < count; ++i) {
        if (indices[i] < 0 || indices[i] >= map.Extent())
            throw Standard_Failure((std::string(kind) + " index out of range").c_str());
        result.Append(map.FindKey(indices[i] + 1));
    }
    return result;
}

double volume(const TopoDS_Shape &shape) {
    GProp_GProps properties;
    BRepGProp::VolumeProperties(shape, properties);
    return properties.Mass();
}

/// A closed profile of straight edges and, where `mids` holds finite (u, v), exact arcs through
/// those points. `mids` may be NULL for an all-straight outline.
TopoDS_Face profileFace(const SSKPlane &plane, const double *xy, const double *mids, int32_t pointCount);

/// One closed loop of a region as a wire (see ssk_extrude_region): a full circle for one point.
TopoDS_Wire loopWire(const SSKPlane &plane, const double *xy, const double *mids, int32_t pointCount) {
    if (pointCount == 1) {
        if (!mids || !std::isfinite(mids[0]) || !std::isfinite(mids[1])) throw Standard_Failure("circle loop needs its center");
        const gp_Pnt center = point(plane, mids[0], mids[1]), start = point(plane, xy[0], xy[1]);
        const double radius = center.Distance(start);
        if (!std::isfinite(radius) || radius < 0.005) throw Standard_Failure("radius must be at least 0.005 mm");
        gp_Circ circle(gp_Ax2(center, normal(plane), gp_Dir(gp_Vec(center, start))), radius);
        return BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(circle).Edge()).Wire();
    }
    TopoDS_Face face = profileFace(plane, xy, mids, pointCount);
    return BRepTools::OuterWire(face);
}

/// A full ellipse loop of ssk_extrude_region_ex: its center and (major, minor, angle, flag).
TopoDS_Wire ellipseWire(const SSKPlane &plane, double u, double v, const double *ellipse) {
    double major = ellipse[0], minor = ellipse[1], angle = ellipse[2];
    if (!std::isfinite(major) || !std::isfinite(minor) || !std::isfinite(angle)) throw Standard_Failure("ellipse is not finite");
    // gp_Elips wants the longer axis first.
    if (minor > major) { std::swap(major, minor); angle += M_PI / 2; }
    if (minor < 0.005) throw Standard_Failure("ellipse radii must be at least 0.005 mm");
    const gp_Vec x(plane.xAxis.x, plane.xAxis.y, plane.xAxis.z), y(plane.yAxis.x, plane.yAxis.y, plane.yAxis.z);
    const gp_Dir along(x * std::cos(angle) + y * std::sin(angle));
    const gp_Elips ellipseCurve(gp_Ax2(point(plane, u, v), normal(plane), along), major, minor);
    return BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(ellipseCurve).Edge()).Wire();
}

/// A flat region: the first loop bounds it, the others are holes in it. `ellipses` (4 per loop,
/// may be NULL) marks loops that are full ellipses.
TopoDS_Face regionFace(const SSKPlane &plane, const double *xy, const double *mids, const int32_t *loopSizes, int32_t loopCount,
                       const double *ellipses = nullptr) {
    if (!xy || !loopSizes || loopCount < 1) throw Standard_Failure("a region needs an outline");
    std::vector<TopoDS_Wire> wires;
    int32_t offset = 0;
    for (int32_t i = 0; i < loopCount; ++i) {
        const int32_t size = loopSizes[i];
        if (size < 1) throw Standard_Failure("region loop is empty");
        const double *loopXY = xy + 2 * offset, *loopMids = mids ? mids + 2 * offset : nullptr;
        const double *ellipse = ellipses ? ellipses + 4 * i : nullptr;
        const bool isEllipse = size == 1 && ellipse && ellipse[3] > 0.5;
        TopoDS_Wire wire = isEllipse ? ellipseWire(plane, loopXY[0], loopXY[1], ellipse) : loopWire(plane, loopXY, loopMids, size);
        // The outline runs counterclockwise about the plane normal and holes clockwise. A circle loop
        // is built counterclockwise; other loops are measured through their points and arc middles.
        double area = 1;
        if (size > 1) {
            std::vector<std::pair<double, double>> ring;
            for (int32_t j = 0; j < size; ++j) {
                ring.emplace_back(loopXY[2 * j], loopXY[2 * j + 1]);
                if (loopMids && std::isfinite(loopMids[2 * j]) && std::isfinite(loopMids[2 * j + 1])) ring.emplace_back(loopMids[2 * j], loopMids[2 * j + 1]);
            }
            area = 0;
            for (size_t j = 0; j < ring.size(); ++j) {
                const auto &a = ring[j], &b = ring[(j + 1) % ring.size()];
                area += a.first * b.second - b.first * a.second;
            }
        }
        if ((i == 0) != (area > 0)) wire = TopoDS::Wire(wire.Reversed());
        wires.push_back(wire);
        offset += size;
    }
    BRepBuilderAPI_MakeFace maker(gp_Pln(gp_Ax3(point(plane, 0, 0), normal(plane), gp_Dir(plane.xAxis.x, plane.xAxis.y, plane.xAxis.z))), wires[0], true);
    if (!maker.IsDone()) throw Standard_Failure("region outline is not planar");
    for (size_t i = 1; i < wires.size(); ++i) maker.Add(wires[i]);
    if (!maker.IsDone()) throw Standard_Failure("region holes do not fit");
    TopoDS_Face face = maker.Face();
    if (face.IsNull() || !BRepCheck_Analyzer(face).IsValid()) {
        // Let shape healing settle anything left (edges built on a slightly different plane).
        ShapeFix_Face fix(face);
        fix.Perform();
        face = fix.Face();
    }
    if (face.IsNull() || !BRepCheck_Analyzer(face).IsValid()) throw Standard_Failure("region is not a valid face");
    return face;
}

TopoDS_Face profileFace(const SSKPlane &plane, const double *xy, const double *mids, int32_t pointCount) {
    if (!xy || pointCount < 2) throw Standard_Failure("a profile needs at least two edges");
    BRepBuilderAPI_MakeWire wire;
    for (int32_t i = 0; i < pointCount; ++i) {
        const int32_t j = (i + 1) % pointCount;
        const gp_Pnt a = point(plane, xy[2 * i], xy[2 * i + 1]), b = point(plane, xy[2 * j], xy[2 * j + 1]);
        if (mids && std::isfinite(mids[2 * i]) && std::isfinite(mids[2 * i + 1])) {
            GC_MakeArcOfCircle arc(a, point(plane, mids[2 * i], mids[2 * i + 1]), b);
            if (!arc.IsDone()) throw Standard_Failure("profile arc is degenerate");
            wire.Add(BRepBuilderAPI_MakeEdge(arc.Value()).Edge());
        } else {
            if (a.Distance(b) < 1e-7) throw Standard_Failure("profile edge is degenerate");
            wire.Add(BRepBuilderAPI_MakeEdge(a, b).Edge());
        }
        if (!wire.IsDone()) throw Standard_Failure("profile edges do not join");
    }
    if (!BRep_Tool::IsClosed(wire.Wire())) throw Standard_Failure("profile outline is not closed");
    BRepBuilderAPI_MakeFace face(wire.Wire(), true);
    if (!face.IsDone()) throw Standard_Failure("profile is not planar");
    return face.Face();
}

TopoDS_Face circleFace(const SSKPlane &plane, double centerU, double centerV, double radius) {
    if (!std::isfinite(radius) || radius < 0.005) throw Standard_Failure("radius must be at least 0.005 mm");
    gp_Dir x(plane.xAxis.x, plane.xAxis.y, plane.xAxis.z);
    gp_Circ circle(gp_Ax2(point(plane, centerU, centerV), normal(plane), x), radius);
    BRepBuilderAPI_MakeFace face(BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(circle).Edge()).Wire(), true);
    if (!face.IsDone()) throw Standard_Failure("circle profile failed");
    return face.Face();
}

TopoDS_Shape loftedTaper(const TopoDS_Face &base, const gp_Dir &n, double depth, double degrees);
TopoDS_Shape draftedSides(const TopoDS_Face &base, const SSKPlane &plane, const gp_Dir &n, double offset, double depth, double degrees);

/// `face` extruded `depth` mm (either sign) from `offset` mm along the plane normal, its sides
/// leaning in by `degrees` (positive narrows toward the far end).
TopoDS_Shape draftedPrism(const TopoDS_Face &face, const SSKPlane &plane, double offset, double depth, double degrees) {
    const gp_Dir n = normal(plane);
    TopoDS_Face base = face;
    if (std::isfinite(offset) && std::fabs(offset) > 1e-12) {
        gp_Trsf lift;
        lift.SetTranslation(gp_Vec(n) * offset);
        base = TopoDS::Face(BRepBuilderAPI_Transform(face, lift, true).Shape());
    }
    if (!std::isfinite(degrees) || std::fabs(degrees) < 1e-9) return prism(base, n, depth);
    if (std::fabs(degrees) >= 89) throw Standard_Failure("the taper must be less than 89°");
    try { return draftedSides(base, plane, n, offset, depth, degrees); } catch (const Standard_Failure &) {}
    // Curved sides the draft cannot tilt (an ellipse, a free curve): loft each loop to its offset.
    return loftedTaper(base, n, depth, degrees);
}

/// A tapered extrusion as lofts: the outline to the outline offset inward by the taper at the far
/// end, less each hole lofted to its own offset (holes widen as the outline narrows).
TopoDS_Shape loftedTaper(const TopoDS_Face &base, const gp_Dir &n, double depth, double degrees) {
    const double inset = std::fabs(depth) * std::tan(degrees * M_PI / 180);
    gp_Trsf lift;
    lift.SetTranslation(gp_Vec(n) * depth);
    const gp_Pln pln = BRepAdaptor_Surface(base).Plane();
    auto loft = [&](const TopoDS_Wire &wire, double grow) -> TopoDS_Shape {
        BRepBuilderAPI_MakeFace face(pln, wire, true);
        if (!face.IsDone()) throw Standard_Failure("the profile is not flat");
        BRepOffsetAPI_MakeOffset offset(face.Face(), GeomAbs_Intersection);
        offset.Perform(grow);
        if (!offset.IsDone()) throw Standard_Failure("the taper closes the profile before the far end");
        TopExp_Explorer wires(offset.Shape(), TopAbs_WIRE);
        if (!wires.More()) throw Standard_Failure("the taper closes the profile before the far end");
        const TopoDS_Wire top = TopoDS::Wire(BRepBuilderAPI_Transform(wires.Current(), lift, true).Shape());
        BRepOffsetAPI_ThruSections sections(true, true);
        sections.AddWire(wire);
        sections.AddWire(top);
        sections.Build();
        if (!sections.IsDone()) throw Standard_Failure("the taper closes the profile before the far end");
        return sections.Shape();
    };
    const TopoDS_Wire outer = BRepTools::OuterWire(base);
    TopoDS_Shape result = loft(outer, -inset);
    for (TopExp_Explorer it(base, TopAbs_WIRE); it.More(); it.Next()) {
        const TopoDS_Wire wire = TopoDS::Wire(it.Current());
        if (wire.IsSame(outer)) continue;
        BRepAlgoAPI_Cut cut(result, loft(TopoDS::Wire(wire.Reversed()), inset));
        if (!cut.IsDone()) throw Standard_Failure("a hole cannot be tapered");
        result = cut.Shape();
    }
    return requireValid(outwardSolid(result, "tapered extrusion"), "the taper closes the profile before the far end");
}

/// Tilts every side of the straight prism about the sketch plane (the neutral plane).
TopoDS_Shape draftedSides(const TopoDS_Face &base, const SSKPlane &plane, const gp_Dir &n, double offset, double depth, double degrees) {
    const TopoDS_Shape straight = prism(base, n, depth);
    // Draft every side about the sketch plane (the neutral plane), pulling away from it.
    const gp_Dir pull = depth > 0 ? n : n.Reversed();
    const gp_Pln neutral(point(plane, 0, 0).Translated(gp_Vec(n) * offset), n);
    BRepOffsetAPI_DraftAngle draft(straight);
    for (TopExp_Explorer it(straight, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face side = TopoDS::Face(it.Current());
        gp_Dir faceNormal;
        if (outwardNormal(side, faceNormal) && std::fabs(faceNormal.Dot(n)) > 1 - 1e-9) continue;   // the two ends
        draft.Add(side, pull, degrees * M_PI / 180, neutral);
        if (!draft.AddDone()) throw Standard_Failure("this profile's sides cannot be tapered");
    }
    draft.Build();
    if (!draft.IsDone()) throw Standard_Failure("the taper closes the profile before the far end");
    return requireValid(outwardSolid(draft.Shape(), "tapered extrusion"), "the taper closes the profile before the far end");
}

/// A sketch point (u, v) of a world point on the plane.
std::pair<double, double> planeCoordinates(const SSKPlane &plane, const gp_Pnt &p) {
    const gp_Vec d(point(plane, 0, 0), p);
    return {d.Dot(gp_Vec(plane.xAxis.x, plane.xAxis.y, plane.xAxis.z)), d.Dot(gp_Vec(plane.yAxis.x, plane.yAxis.y, plane.yAxis.z))};
}

} // namespace

extern "C" {

const char *ssk_last_error(void) { return lastError.empty() ? nullptr : lastError.c_str(); }
const char *ssk_occt_version(void) { return OCC_VERSION_COMPLETE; }

SSKShape *ssk_extrude_polygon(SSKPlane plane, const double *xy, int32_t pointCount, double depth) {
    return guarded("Extrude", [&] {
        if (!xy || pointCount < 3) throw Standard_Failure("a profile needs at least three points");
        BRepBuilderAPI_MakePolygon polygon;
        for (int32_t i = 0; i < pointCount; ++i) polygon.Add(point(plane, xy[2 * i], xy[2 * i + 1]));
        polygon.Close();
        if (!polygon.IsDone()) throw Standard_Failure("profile outline is degenerate");
        BRepBuilderAPI_MakeFace face(polygon.Wire(), true);
        if (!face.IsDone()) throw Standard_Failure("profile is not planar");
        return extrude(face.Face(), plane, depth);
    });
}

SSKShape *ssk_extrude_profile(SSKPlane plane, const double *xy, const double *mids, int32_t pointCount, double depth) {
    return guarded("Extrude", [&] {
        if (!mids) throw Standard_Failure("missing arc mid-points");
        return extrude(profileFace(plane, xy, mids, pointCount), plane, depth);
    });
}

SSKShape *ssk_extrude_circle(SSKPlane plane, double centerU, double centerV, double radius, double depth) {
    return guarded("Extrude", [&] { return extrude(circleFace(plane, centerU, centerV, radius), plane, depth); });
}

SSKShape *ssk_revolve_profile(SSKPlane plane, const double *xy, const double *mids, int32_t pointCount,
                            double axisU0, double axisV0, double axisU1, double axisV1, double degrees) {
    return guarded("Revolve", [&] {
        const TopoDS_Face face = profileFace(plane, xy, mids, pointCount);
        std::vector<std::pair<double, double>> points;
        for (int32_t i = 0; i < pointCount; ++i) {
            points.emplace_back(xy[2 * i], xy[2 * i + 1]);
            if (mids && std::isfinite(mids[2 * i]) && std::isfinite(mids[2 * i + 1])) points.emplace_back(mids[2 * i], mids[2 * i + 1]);
        }
        requireOneSide(points, axisU0, axisV0, axisU1, axisV1);
        return revolution(face, point(plane, axisU0, axisV0), point(plane, axisU1, axisV1), degrees);
    });
}

SSKShape *ssk_revolve_circle(SSKPlane plane, double centerU, double centerV, double radius,
                           double axisU0, double axisV0, double axisU1, double axisV1, double degrees) {
    return guarded("Revolve", [&] {
        const TopoDS_Face face = circleFace(plane, centerU, centerV, radius);
        requireOneSide({{centerU, centerV}}, axisU0, axisV0, axisU1, axisV1, radius);
        return revolution(face, point(plane, axisU0, axisV0), point(plane, axisU1, axisV1), degrees);
    });
}

SSKShape *ssk_extrude_region(SSKPlane plane, const double *xy, const double *mids, const int32_t *loopSizes, int32_t loopCount,
                           double depth) {
    return guarded("Extrude", [&] { return extrude(regionFace(plane, xy, mids, loopSizes, loopCount), plane, depth); });
}

SSKShape *ssk_revolve_region(SSKPlane plane, const double *xy, const double *mids, const int32_t *loopSizes, int32_t loopCount,
                           double axisU0, double axisV0, double axisU1, double axisV1, double degrees) {
    return guarded("Revolve", [&] {
        const TopoDS_Face face = regionFace(plane, xy, mids, loopSizes, loopCount);
        // The outer loop decides the side of the axis; holes lie inside it.
        std::vector<std::pair<double, double>> points;
        double reach = 0;
        if (loopSizes[0] == 1) {
            points.emplace_back(mids[0], mids[1]);
            reach = std::hypot(xy[0] - mids[0], xy[1] - mids[1]);
        } else {
            for (int32_t i = 0; i < loopSizes[0]; ++i) {
                points.emplace_back(xy[2 * i], xy[2 * i + 1]);
                if (mids && std::isfinite(mids[2 * i]) && std::isfinite(mids[2 * i + 1])) points.emplace_back(mids[2 * i], mids[2 * i + 1]);
            }
        }
        requireOneSide(points, axisU0, axisV0, axisU1, axisV1, reach);
        return revolution(face, point(plane, axisU0, axisV0), point(plane, axisU1, axisV1), degrees);
    });
}

SSKShape *ssk_hole_tool(SSKPlane plane, double u, double v, double diameter, double depth,
                      double counterboreDiameter, double counterboreDepth,
                      double countersinkDiameter, double countersinkAngle) {
    return guarded("Hole", [&]() -> TopoDS_Shape {
        if (!std::isfinite(diameter) || diameter < 0.1) throw Standard_Failure("hole diameter must be at least 0.1 mm");
        if (!std::isfinite(depth) || depth < 0.05) throw Standard_Failure("hole depth must be at least 0.05 mm");
        const gp_Dir n = normal(plane);
        const gp_Dir into = n.Reversed();
        const gp_Pnt center = point(plane, u, v);
        const gp_Dir x(plane.xAxis.x, plane.xAxis.y, plane.xAxis.z);
        // Start a little above the face so the tool never shares a face with the solid.
        const double lead = 0.5;
        auto cylinder = [&](double radius, double length) {
            gp_Ax2 axis(center.Translated(gp_Vec(n) * lead), into, x);
            return BRepPrimAPI_MakeCylinder(axis, radius, length + lead).Shape();
        };
        auto fuse = [](const TopoDS_Shape &a, const TopoDS_Shape &b) {
            BRepAlgoAPI_Fuse fused(a, b);
            if (!fused.IsDone()) throw Standard_Failure("hole tool fusion failed");
            return fused.Shape();
        };
        TopoDS_Shape tool = cylinder(diameter / 2, depth);
        if (counterboreDiameter > diameter && counterboreDepth > 0) {
            tool = fuse(tool, cylinder(counterboreDiameter / 2, std::min(counterboreDepth, depth)));
        }
        if (countersinkDiameter > diameter && countersinkAngle > 1 && countersinkAngle < 179) {
            const double r1 = countersinkDiameter / 2, r2 = diameter / 2;
            const double height = std::min(depth, (r1 - r2) / std::tan(countersinkAngle * M_PI / 360.0));
            const double r2Actual = r1 - height * std::tan(countersinkAngle * M_PI / 360.0);
            gp_Ax2 axis(center, into, x);
            tool = fuse(tool, BRepPrimAPI_MakeCone(axis, r1, std::max(r2Actual, r2), height).Shape());
            tool = fuse(tool, cylinder(r1, 0));   // the lead-in above the face at full countersink width
        }
        return tool;
    });
}

SSKShape *ssk_extrude_outlines(SSKPlane plane, const double *xy, const int32_t *degrees, const int32_t *segmentCounts,
                               const int32_t *groups, const bool *filled, int32_t loopCount, double offset, double depth) {
    return guarded("Outlines", [&]() -> TopoDS_Shape {
        if (!xy || !degrees || !segmentCounts || !groups || !filled || loopCount < 1 || loopCount > 20000) throw Standard_Failure("no outlines");
        if (!std::isfinite(depth) || std::fabs(depth) < 0.01 || !std::isfinite(offset)) throw Standard_Failure("depth must be at least 0.01 mm");
        const gp_Dir n = normal(plane);
        const gp_Pln pln(point(plane, 0, 0), n);
        int32_t pointIndex = 0, segmentIndex = 0;
        std::vector<std::pair<int32_t, std::pair<bool, TopoDS_Shape>>> prisms;
        for (int32_t loop = 0; loop < loopCount; ++loop) {
            const int32_t count = segmentCounts[loop];
            if (count < 1 || count > 100000) throw Standard_Failure("an outline has no segments");
            auto pointAt = [&](int32_t i) { return point(plane, xy[2 * i], xy[2 * i + 1]); };
            gp_Pnt current = pointAt(pointIndex++);
            BRepBuilderAPI_MakeWire wire;
            // Signed area of the control polygon, enough to tell which way the loop turns.
            double area = 0;
            const double u0 = xy[2 * (pointIndex - 1)], v0 = xy[2 * (pointIndex - 1) + 1];
            double cu = u0, cv = v0;
            for (int32_t s = 0; s < count; ++s) {
                const int32_t degree = degrees[segmentIndex++];
                if (degree < 1 || degree > 3) throw Standard_Failure("segments are lines or quadratic or cubic curves");
                NCollection_Array1<gp_Pnt> poles(1, degree + 1);
                poles.SetValue(1, current);
                for (int32_t k = 1; k <= degree; ++k) {
                    const double u = xy[2 * pointIndex], v = xy[2 * pointIndex + 1];
                    area += cu * v - u * cv;
                    cu = u; cv = v;
                    poles.SetValue(k + 1, pointAt(pointIndex++));
                }
                const gp_Pnt end = poles.Value(degree + 1);
                if (current.Distance(end) < 1e-7 && degree == 1) continue;
                TopoDS_Edge edge = degree == 1 ? BRepBuilderAPI_MakeEdge(current, end).Edge()
                                               : BRepBuilderAPI_MakeEdge(occ::handle<Geom_BezierCurve>(new Geom_BezierCurve(poles))).Edge();
                wire.Add(edge);
                if (!wire.IsDone()) throw Standard_Failure("an outline does not join up");
                current = end;
            }
            area += cu * v0 - u0 * cv;
            if (!wire.IsDone()) throw Standard_Failure("an outline is empty");
            TopoDS_Wire w = wire.Wire();
            if (!w.Closed()) {
                BRepBuilderAPI_MakeWire closing(w);
                TopoDS_Vertex v1, v2;
                TopExp::Vertices(w, v1, v2);
                if (BRep_Tool::Pnt(v1).Distance(BRep_Tool::Pnt(v2)) > 1e-7) closing.Add(BRepBuilderAPI_MakeEdge(BRep_Tool::Pnt(v2), BRep_Tool::Pnt(v1)).Edge());
                w = closing.Wire();
            }
            if (area < 0) w.Reverse();
            BRepBuilderAPI_MakeFace face(pln, w, true);
            if (!face.IsDone()) throw Standard_Failure("an outline does not make a face");
            gp_Trsf lift;
            lift.SetTranslation(gp_Vec(n) * offset);
            const TopoDS_Shape lifted = BRepBuilderAPI_Transform(face.Face(), lift, true).Shape();
            BRepPrimAPI_MakePrism prism(lifted, gp_Vec(n) * depth);
            TopoDS_Shape solid = prism.Shape();
            for (TopExp_Explorer it(solid, TopAbs_SOLID); it.More(); it.Next()) {
                TopoDS_Solid s = TopoDS::Solid(it.Current());
                BRepLib::OrientClosedSolid(s);
                solid = s;
                break;
            }
            prisms.push_back({groups[loop], {filled[loop], solid}});
        }
        // Each group (a glyph): its filled loops united, its other loops taken away.
        BRep_Builder builder;
        TopoDS_Compound all;
        builder.MakeCompound(all);
        std::vector<int32_t> seen;
        for (const auto &entry : prisms) {
            const int32_t group = entry.first;
            if (std::find(seen.begin(), seen.end(), group) != seen.end()) continue;
            seen.push_back(group);
            NCollection_List<TopoDS_Shape> solids, holes;
            for (const auto &other : prisms) {
                if (other.first != group) continue;
                (other.second.first ? solids : holes).Append(other.second.second);
            }
            if (solids.IsEmpty()) continue;
            TopoDS_Shape shape = solids.First();
            if (solids.Extent() > 1) {
                NCollection_List<TopoDS_Shape> arguments, tools;
                arguments.Append(solids.First());
                bool first = true;
                for (const auto &s : solids) { if (first) { first = false; continue; } tools.Append(s); }
                BRepAlgoAPI_Fuse fuse;
                fuse.SetArguments(arguments);
                fuse.SetTools(tools);
                fuse.Build();
                if (!fuse.IsDone()) throw Standard_Failure("a letter's outlines could not be joined");
                shape = fuse.Shape();
            }
            if (!holes.IsEmpty()) {
                NCollection_List<TopoDS_Shape> arguments;
                arguments.Append(shape);
                BRepAlgoAPI_Cut cut;
                cut.SetArguments(arguments);
                cut.SetTools(holes);
                cut.Build();
                if (!cut.IsDone()) throw Standard_Failure("a letter's holes could not be cut");
                shape = cut.Shape();
            }
            for (TopExp_Explorer it(shape, TopAbs_SOLID); it.More(); it.Next()) builder.Add(all, it.Current());
        }
        if (TopExp_Explorer(all, TopAbs_SOLID).More() == false) throw Standard_Failure("the outlines enclose nothing");
        return TopoDS_Shape(all);
    });
}

namespace {
const struct { int mode; double phase; double fuzz; } threadAttempts[] = {
    {0, 0, 0}, {0, 0, 1e-4}, {0, 0.13, 0}, {1, 0, 0}, {1, 0.29, 1e-4}, {0, 0.41, 1e-4}};
thread_local int32_t onlyThreadAttempt = -1;
}

int32_t ssk_set_thread_attempt(int32_t attempt) {
    onlyThreadAttempt = attempt;
    return (int32_t)std::size(threadAttempts);
}

SSKShape *ssk_thread_tool(SSKVec3 origin, SSKVec3 axis, SSKVec3 reference, double start, double end, double pitch,
                          double crestRadius, double rootRadius, double surfaceRadius, bool internal, bool leftHanded, int32_t starts,
                          bool raised, double clipStart, double clipEnd) {
    return guarded("Thread", [&]() -> TopoDS_Shape {
        if (starts < 1 || starts > 8) throw Standard_Failure("a thread has 1 to 8 starts");
        const double length = end - start;
        if (!std::isfinite(pitch) || pitch < 0.2 || pitch > 20) throw Standard_Failure("pitch must be 0.2 to 20 mm");
        if (!std::isfinite(length) || length < pitch * 0.5) throw Standard_Failure("the thread is shorter than half a pitch");
        if (length / pitch > 400) throw Standard_Failure("the thread has too many turns");
        if (!(rootRadius > 0.1) || !(crestRadius > rootRadius) || !(surfaceRadius > 0)) throw Standard_Failure("thread radii are out of order");
        if (raised && !(std::isfinite(clipStart) && std::isfinite(clipEnd) && clipStart >= start - 1e-9 && clipEnd <= end + 1e-9 &&
                        clipEnd - clipStart >= pitch * 0.5)) {
            throw Standard_Failure("a raised thread's face is shorter than half a pitch");
        }
        if (raised && (internal ? surfaceRadius <= rootRadius : surfaceRadius >= crestRadius)) {
            throw Standard_Failure("a raised thread must stand out of its face");
        }
        const gp_Dir z(axis.x, axis.y, axis.z);
        gp_Vec xv(reference.x, reference.y, reference.z);
        xv -= gp_Vec(z) * xv.Dot(gp_Vec(z));
        if (xv.Magnitude() < 1e-9) throw Standard_Failure("the reference direction is along the axis");
        const gp_Dir x(xv);
        const gp_Pnt o(origin.x, origin.y, origin.z);
        // The ridge: an ISO 60° profile, P/8 wide at its crest, widening toward the root. It starts a
        // little inside the root so it fully divides whatever it is cut from or subtracted from.
        const double tan30 = std::tan(M_PI / 6), inner = rootRadius - 0.05 * pitch;
        const double crestHalf = pitch / 16, baseHalf = crestHalf + (crestRadius - inner) * tan30;
        if (2 * baseHalf > 0.95 * pitch) throw Standard_Failure("the thread is too deep for its pitch");
        auto slab = [&](double radius) {
            return BRepPrimAPI_MakeCylinder(gp_Ax2(o.Translated(gp_Vec(z) * start), z, x), radius, length).Shape();
        };
        // The grooves between the ridge's turns, from the root out past the surface (a bolt's thread).
        const double bandRadius = std::max(surfaceRadius, crestRadius) + 0.05;
        const TopoDS_Shape band = slab(bandRadius);
        BRepAlgoAPI_Cut ringCut(band, slab(rootRadius));
        if (!ringCut.IsDone()) throw Standard_Failure("the thread could not be built");
        const TopoDS_Shape ring = ringCut.Shape();
        const double ringVolume = volume(ring);

        // The ridge swept along a helix from a pitch before the start to a pitch past the end, split
        // into half turns (a face that wraps the axis confuses the booleans). The boolean can
        // still quietly leave the ridge out, so each attempt is checked and the next varies the sweep.
        // A `phase` starts the sweep that fraction of a pitch earlier on the same helix, turned back to
        // match, so its half turns break elsewhere while the thread stays in step with its mate.
        auto ridgeFor = [&](int mode, double phase) -> TopoDS_Shape {
            const double z0 = start - pitch - baseHalf - phase * pitch, height = length + 2 * pitch + 2 * baseHalf + phase * pitch;
            const double lead = pitch * starts, back = 2 * M_PI * phase * pitch / lead;
            const gp_Ax3 frame(o.Translated(gp_Vec(z) * z0), z, x.Rotated(gp_Ax1(o, z), leftHanded ? back : -back));
            Handle(Geom_CylindricalSurface) cylinder = new Geom_CylindricalSurface(frame, inner);
            const double turns = height / lead, perTurn = std::hypot(2 * M_PI, lead);
            Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(0, 0), gp_Dir2d(leftHanded ? -2 * M_PI : 2 * M_PI, lead));
            BRepBuilderAPI_MakeWire wire;
            const int pieces = std::max(1, (int)std::ceil(turns * 2));
            for (int i = 0; i < pieces; ++i) {
                TopoDS_Edge edge = BRepBuilderAPI_MakeEdge(line, cylinder, turns * perTurn * i / pieces, turns * perTurn * (i + 1) / pieces).Edge();
                BRepLib::BuildCurves3d(edge, 1e-6, GeomAbs_C2, 14, 200);
                wire.Add(edge);
            }
            if (!wire.IsDone()) return TopoDS_Shape();
            auto at = [&](double r, double h) { return frame.Location().Translated(gp_Vec(frame.XDirection()) * r + gp_Vec(z) * h); };
            BRepBuilderAPI_MakePolygon trapezoid(at(inner, -baseHalf), at(crestRadius, -crestHalf), at(crestRadius, crestHalf), at(inner, baseHalf), true);
            BRepOffsetAPI_MakePipeShell pipe(wire.Wire());
            // A fixed binormal along the axis keeps the profile in planes through the axis; or Frenet.
            if (mode == 0) pipe.SetMode(z); else pipe.SetMode(true);
            pipe.Add(trapezoid.Wire());
            pipe.Build();
            if (!pipe.IsDone() || !pipe.MakeSolid()) return TopoDS_Shape();
            for (TopExp_Explorer it(pipe.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
                TopoDS_Solid solid = TopoDS::Solid(it.Current());
                BRepLib::OrientClosedSolid(solid);
                return BRepCheck_Analyzer(solid).IsValid() ? TopoDS_Shape(solid) : TopoDS_Shape();
            }
            return TopoDS_Shape();
        };
        auto cutAll = [](const TopoDS_Shape &a, const NCollection_List<TopoDS_Shape> &tools, double fuzz) -> TopoDS_Shape {
            NCollection_List<TopoDS_Shape> arguments;
            arguments.Append(a);
            BRepAlgoAPI_Cut op;
            op.SetArguments(arguments);
            op.SetTools(tools);
            if (fuzz > 0) op.SetFuzzyValue(fuzz);
            op.Build();
            return op.IsDone() ? op.Shape() : TopoDS_Shape();
        };
        auto cut = [&](const TopoDS_Shape &a, const TopoDS_Shape &b, double fuzz) {
            NCollection_List<TopoDS_Shape> tools;
            tools.Append(b);
            return cutAll(a, tools, fuzz);
        };
        // The ridge's share of the ring, exactly: its cross-section from the root to the crest turned
        // about the axis (2π ∫ r·width dr per turn), once per pitch of length over all the starts.
        // Between radii a and b, per pitch of length.
        auto ridgeBetween = [&](double a, double b) {
            return 2 * M_PI * 2 * (crestHalf * (b * b - a * a) / 2 + tan30 * (crestRadius * (b * b - a * a) / 2 - (std::pow(b, 3) - std::pow(a, 3)) / 3));
        };
        const double expectedRidge = ridgeBetween(rootRadius, crestRadius) * length / pitch;
        auto commonOf = [](const TopoDS_Shape &a, const TopoDS_Shape &b, double fuzz) -> TopoDS_Shape {
            NCollection_List<TopoDS_Shape> arguments, tools;
            arguments.Append(a);
            tools.Append(b);
            BRepAlgoAPI_Common op;
            op.SetArguments(arguments);
            op.SetTools(tools);
            if (fuzz > 0) op.SetFuzzyValue(fuzz);
            op.Build();
            return op.IsDone() ? op.Shape() : TopoDS_Shape();
        };
        // A raised thread is clipped to the face's own extent, and reaches this far into the face.
        const double clipLength = clipEnd - clipStart, reach = std::min(0.1, 0.05 * pitch);
        auto clipSlab = [&](double radius) {
            return BRepPrimAPI_MakeCylinder(gp_Ax2(o.Translated(gp_Vec(z) * clipStart), z, x), radius, clipLength).Shape();
        };
        for (int32_t index = 0; index < (int32_t)std::size(threadAttempts); ++index) {
            if (onlyThreadAttempt >= 0 && index != onlyThreadAttempt) continue;
            const auto &attempt = threadAttempts[index];
            try {
                const TopoDS_Shape ridge = ridgeFor(attempt.mode, attempt.phase);
                if (ridge.IsNull()) continue;
                // The other starts are the same ridge turned a fraction of a turn about the axis.
                NCollection_List<TopoDS_Shape> ridges;
                ridges.Append(ridge);
                for (int k = 1; k < starts; ++k) {
                    gp_Trsf turn;
                    turn.SetRotation(gp_Ax1(o, z), 2 * M_PI * k / starts);
                    ridges.Append(BRepBuilderAPI_Transform(ridge, turn, true).Shape());
                }
                const TopoDS_Shape grooves = cutAll(ring, ridges, attempt.fuzz);
                if (grooves.IsNull()) continue;
                // The boolean can quietly drop a ridge, or part of one: what it took must be the ridges.
                if (std::fabs(ringVolume - volume(grooves) - expectedRidge) > 0.05 * expectedRidge) continue;
                if (raised && internal) {
                    // A nut's ridges are the grooves a bolt would leave: those inside the hole's wall
                    // (and, in a hole wider than the crest, the sleeve filling it in to the crest).
                    const double outer = std::min(surfaceRadius + reach, bandRadius);
                    const TopoDS_Shape added = commonOf(grooves, clipSlab(surfaceRadius + reach), attempt.fuzz);
                    if (added.IsNull()) continue;
                    const double expected = M_PI * (outer * outer - rootRadius * rootRadius) * clipLength -
                        ridgeBetween(rootRadius, std::min(outer, crestRadius)) * clipLength / pitch;
                    if (std::fabs(volume(added) - expected) > 0.05 * expected) continue;
                    return added;
                }
                if (!internal && !raised) return grooves;
                // A nut's thread is what a bolt leaves: everything inside the band but the grooves, so
                // an undersized hole is also opened up to the root.
                const TopoDS_Shape nut = cut(band, grooves, attempt.fuzz);
                if (nut.IsNull()) continue;
                const double expected = volume(band) - volume(grooves);
                if (std::fabs(volume(nut) - expected) > 1e-3 * volume(band)) continue;
                if (!raised) return nut;
                // A bolt's raised thread is the same solid thread outside the boss: its ridges (and,
                // on a boss thinner than the root, the sleeve building it up to the root).
                const double inner = std::max(surfaceRadius - reach, 1e-3);
                const TopoDS_Shape tube = cut(clipSlab(bandRadius + 0.05), clipSlab(inner), 0);
                if (tube.IsNull()) continue;
                const TopoDS_Shape added = commonOf(nut, tube, attempt.fuzz);
                if (added.IsNull()) continue;
                const double raisedExpected = ridgeBetween(std::max(inner, rootRadius), crestRadius) * clipLength / pitch +
                    M_PI * std::max(0.0, rootRadius * rootRadius - inner * inner) * clipLength;
                if (std::fabs(volume(added) - raisedExpected) > 0.05 * raisedExpected) continue;
                return added;
            } catch (const Standard_Failure &) {}
        }
        throw Standard_Failure("the thread could not be built for this size; try another pitch or length");
    });
}

bool ssk_point_inside(const SSKShape *shape, SSKVec3 point) {
    if (!shape) return false;
    try {
        BRepClass3d_SolidClassifier classifier(shape->shape, gp_Pnt(point.x, point.y, point.z), 1e-6);
        return classifier.State() == TopAbs_IN;
    } catch (...) { return false; }
}

int32_t ssk_face_cylinder_side(const SSKShape *shape, int32_t face) {
    if (!shape || face < 0 || face >= shape->faces.Extent()) return 0;
    try {
        const TopoDS_Face f = TopoDS::Face(shape->faces.FindKey(face + 1));
        BRepAdaptor_Surface surface(f);
        if (surface.GetType() != GeomAbs_Cylinder) return 0;
        const double u = (surface.FirstUParameter() + surface.LastUParameter()) / 2;
        const double v = (surface.FirstVParameter() + surface.LastVParameter()) / 2;
        gp_Pnt p; gp_Vec du, dv;
        surface.D1(u, v, p, du, dv);
        gp_Vec n = du.Crossed(dv);
        if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
        const gp_Ax1 axis = surface.Cylinder().Axis();
        gp_Vec radial(axis.Location(), p);
        radial -= gp_Vec(axis.Direction()) * radial.Dot(gp_Vec(axis.Direction()));
        return n.Dot(radial) >= 0 ? 1 : -1;
    } catch (...) { return 0; }
}

SSKShape *ssk_boolean(const SSKShape *a, const SSKShape *b, SSKBooleanOp op) {
    return guarded("Boolean", [&]() -> TopoDS_Shape {
        if (!a || !b) throw Standard_Failure("missing operand");
        NCollection_List<TopoDS_Shape> arguments, tools;
        arguments.Append(a->shape);
        tools.Append(b->shape);
        auto run = [&](BRepAlgoAPI_BooleanOperation &&algorithm) {
            algorithm.SetArguments(arguments);
            algorithm.SetTools(tools);
            algorithm.SetFuzzyValue(kBooleanFuzz);
            // The inputs are cached solids the canvas may be reading on another thread: never let
            // the boolean adjust their tolerances or share-and-modify their sub-shapes.
            algorithm.SetNonDestructive(Standard_True);
            algorithm.SetRunParallel(true);
            algorithm.Build();
            if (!algorithm.IsDone() || algorithm.HasErrors()) throw Standard_Failure("operation did not complete");
            // Merge the coplanar faces and collinear edges a boolean leaves behind.
            algorithm.SimplifyResult();
            return algorithm.Shape();
        };
        switch (op) {
            case SSKBooleanUnion: return run(BRepAlgoAPI_Fuse());
            case SSKBooleanSubtract: return run(BRepAlgoAPI_Cut());
            case SSKBooleanIntersect: return run(BRepAlgoAPI_Common());
        }
        throw Standard_Failure("unknown operation");
    });
}

SSKShape *ssk_fillet(const SSKShape *shape, const int32_t *edges, int32_t edgeCount, double radius) {
    return guarded("Fillet", [&] {
        if (!shape) throw Standard_Failure("missing shape");
        if (!std::isfinite(radius) || radius < 0.01) throw Standard_Failure("radius must be at least 0.01 mm");
        BRepFilletAPI_MakeFillet fillet(shape->shape);
        for (const TopoDS_Shape &edge : select(shape->edges, edges, edgeCount, "edge")) fillet.Add(radius, TopoDS::Edge(edge));
        fillet.Build();
        if (!fillet.IsDone()) throw Standard_Failure("radius is too large for the selected edges");
        return requireValid(fillet.Shape(), "radius is too large for the selected edges");
    });
}

SSKShape *ssk_chamfer(const SSKShape *shape, const int32_t *edges, int32_t edgeCount, double distance) {
    return guarded("Chamfer", [&] {
        if (!shape) throw Standard_Failure("missing shape");
        if (!std::isfinite(distance) || distance < 0.01) throw Standard_Failure("distance must be at least 0.01 mm");
        BRepFilletAPI_MakeChamfer chamfer(shape->shape);
        for (const TopoDS_Shape &edge : select(shape->edges, edges, edgeCount, "edge")) chamfer.Add(distance, TopoDS::Edge(edge));
        chamfer.Build();
        if (!chamfer.IsDone()) throw Standard_Failure("distance is too large for the selected edges");
        return requireValid(chamfer.Shape(), "distance is too large for the selected edges");
    });
}

SSKShape *ssk_shell(const SSKShape *shape, const int32_t *openFaces, int32_t faceCount, double thickness) {
    return guarded("Shell", [&] {
        if (!shape) throw Standard_Failure("missing shape");
        if (!std::isfinite(thickness) || thickness < 0.01) throw Standard_Failure("thickness must be at least 0.01 mm");
        NCollection_List<TopoDS_Shape> faces;
        if (faceCount > 0) faces = select(shape->faces, openFaces, faceCount, "face");
        BRepOffsetAPI_MakeThickSolid thick;
        // Negative offset grows the wall inward, so outer dimensions stay as drawn.
        thick.MakeThickSolidByJoin(shape->shape, faces, -thickness, 1e-3, BRepOffset_Skin, true);
        if (!thick.IsDone()) throw Standard_Failure("wall thickness is too large for this solid");
        TopoDS_Shape result = requireValid(thick.Shape(), "this solid cannot be hollowed; try shelling before rounding its edges");
        // OCCT can report success while returning the input untouched; a shell must remove material.
        if (volume(result) > volume(shape->shape) * (1 - 1e-9))
            throw Standard_Failure("this solid cannot be hollowed; try shelling before rounding its edges");
        return result;
    });
}

SSKShape *ssk_offset_solid(const SSKShape *shape, double distance) {
    return guarded("Offset", [&] {
        if (!shape) throw Standard_Failure("missing shape");
        if (!std::isfinite(distance) || distance < 0.001 || distance > 50) throw Standard_Failure("offset must be 0.001 to 50 mm");
        const double before = volume(shape->shape);
        // Rounded joins keep every point exactly `distance` from the solid; sharp ones are the fallback.
        for (GeomAbs_JoinType join : {GeomAbs_Arc, GeomAbs_Intersection}) {
            try {
                BRepOffsetAPI_MakeOffsetShape offset;
                offset.PerformByJoin(shape->shape, distance, 1e-4, BRepOffset_Skin, false, false, join);
                if (!offset.IsDone()) continue;
                TopoDS_Shape grown = offset.Shape();
                TopoDS_Solid solid;
                TopExp_Explorer solids(grown, TopAbs_SOLID);
                if (solids.More()) {
                    solid = TopoDS::Solid(solids.Current());
                } else {
                    TopExp_Explorer shells(grown, TopAbs_SHELL);
                    if (!shells.More()) continue;
                    BRepBuilderAPI_MakeSolid maker(TopoDS::Shell(shells.Current()));
                    if (!maker.IsDone()) continue;
                    solid = maker.Solid();
                }
                BRepLib::OrientClosedSolid(solid);
                if (!BRepCheck_Analyzer(solid).IsValid() || volume(solid) <= before) continue;
                return TopoDS_Shape(solid);
            } catch (const Standard_Failure &) {}
        }
        throw Standard_Failure("this solid cannot be grown by that clearance");
    });
}

SSKShape *ssk_extrude_face(const SSKShape *shape, int32_t face, double depth) {
    return guarded("Extrude face", [&] {
        if (!shape || face < 0 || face >= shape->faces.Extent()) throw Standard_Failure("face index out of range");
        const TopoDS_Face f = TopoDS::Face(shape->faces.FindKey(face + 1));
        gp_Dir n;
        if (!outwardNormal(f, n)) throw Standard_Failure("only flat faces can be extruded");
        return prism(TopoDS::Face(f.Oriented(TopAbs_FORWARD)), n, depth);
    });
}

SSKShape *ssk_revolve_face(const SSKShape *shape, int32_t face, SSKVec3 axisFrom, SSKVec3 axisTo, double degrees) {
    return guarded("Revolve face", [&] {
        if (!shape || face < 0 || face >= shape->faces.Extent()) throw Standard_Failure("face index out of range");
        const TopoDS_Face f = TopoDS::Face(shape->faces.FindKey(face + 1));
        gp_Dir n;
        if (!outwardNormal(f, n)) throw Standard_Failure("only flat faces can be revolved");
        return revolution(TopoDS::Face(f.Oriented(TopAbs_FORWARD)), gp_Pnt(axisFrom.x, axisFrom.y, axisFrom.z),
                          gp_Pnt(axisTo.x, axisTo.y, axisTo.z), degrees);
    });
}

int32_t ssk_face_at(const SSKShape *shape, SSKVec3 point, SSKVec3 normal, double tolerance) {
    if (!shape) return -1;
    try {
        const gp_Pnt p(point.x, point.y, point.z);
        const gp_Vec wanted(normal.x, normal.y, normal.z);
        if (wanted.Magnitude() < 1e-12) return -1;
        for (int32_t i = 1; i <= shape->faces.Extent(); ++i) {
            const TopoDS_Face &f = TopoDS::Face(shape->faces.FindKey(i));
            gp_Dir n;
            if (!outwardNormal(f, n) || gp_Vec(n).Dot(wanted.Normalized()) < 0.9999) continue;
            if (BRepAdaptor_Surface(f).Plane().Distance(p) > tolerance) continue;
            if (BRepClass_FaceClassifier(f, p, tolerance).State() == TopAbs_IN) return i - 1;
        }
    } catch (...) {}
    return -1;
}

int32_t ssk_face_near(const SSKShape *shape, SSKVec3 point, double tolerance) {
    if (!shape) return -1;
    try {
        const TopoDS_Vertex v = BRepBuilderAPI_MakeVertex(gp_Pnt(point.x, point.y, point.z)).Vertex();
        int32_t best = -1;
        double nearest = tolerance;
        for (int32_t i = 1; i <= shape->faces.Extent(); ++i) {
            BRepExtrema_DistShapeShape distance(v, shape->faces.FindKey(i));
            if (!distance.IsDone()) continue;
            if (distance.Value() <= nearest) { nearest = distance.Value(); best = i - 1; }
        }
        return best;
    } catch (...) {}
    return -1;
}

int32_t ssk_face_outline(const SSKShape *shape, int32_t face, double *xyz, int32_t capacity, int32_t *singleEdge) {
    if (singleEdge) *singleEdge = -1;
    if (!shape || face < 0 || face >= shape->faces.Extent()) return -1;
    try {
        const TopoDS_Face f = TopoDS::Face(shape->faces.FindKey(face + 1).Oriented(TopAbs_FORWARD));
        const TopoDS_Wire outer = BRepTools::OuterWire(f);
        if (outer.IsNull()) return -1;
        int32_t count = 0, edges = 0, lastEdge = -1;
        auto add = [&](const gp_Pnt &p) {
            if (xyz && count < capacity) { xyz[3 * count] = p.X(); xyz[3 * count + 1] = p.Y(); xyz[3 * count + 2] = p.Z(); }
            ++count;
        };
        for (BRepTools_WireExplorer it(outer, f); it.More(); it.Next()) {
            const TopoDS_Edge &e = it.Current();
            ++edges;
            lastEdge = shape->edges.FindIndex(e) - 1;
            if (BRep_Tool::Degenerated(e)) continue;
            BRepAdaptor_Curve curve(e);
            const double first = curve.FirstParameter(), last = curve.LastParameter();
            int32_t segments = 1;
            if (curve.GetType() == GeomAbs_Circle) segments = std::max(2, int32_t(std::ceil(std::fabs(last - first) / (M_PI / 36))));
            else if (curve.GetType() != GeomAbs_Line) segments = 24;
            const bool reversed = e.Orientation() == TopAbs_REVERSED;
            // Each edge contributes its start and interior points; the next edge supplies its end.
            for (int32_t i = 0; i < segments; ++i) {
                const double t = double(i) / segments;
                add(curve.Value(reversed ? last + (first - last) * t : first + (last - first) * t));
            }
        }
        if (singleEdge && edges == 1) *singleEdge = lastEdge;
        return count;
    } catch (...) { return -1; }
}

// MARK: STEP import and stored shapes

// Damage OCCT cannot survive, found in the text before OCCT sees it (October 21, 2026), or nullptr.
// A STEP file's entities refer to each other without loops; a loop (an edge made of itself) sends
// OCCT's reader round forever while it checks the file. Numbers no real model has (beyond ten
// billion, or nonzero below 1e-100) send its shape repair into degenerate geometry, which crashes;
// so do references to entities the file never defines. Strings and comments are skipped; each
// `#n = …;` record's `#m` references are edges of the graph.
static const char *stepDamage(const char *path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return nullptr;
    const std::string text((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    std::unordered_map<long, std::vector<long>> refs;
    std::unordered_set<long> defined;
    long current = 0;
    bool inString = false;
    for (size_t i = 0; i < text.size(); ++i) {
        const char c = text[i];
        if (inString) {
            if (c == '\'') { if (i + 1 < text.size() && text[i + 1] == '\'') ++i; else inString = false; }
            continue;
        }
        if (c == '\'') { inString = true; continue; }
        if (c == '/' && i + 1 < text.size() && text[i + 1] == '*') {
            const size_t close = text.find("*/", i + 2);
            if (close == std::string::npos) break;
            i = close + 1;
            continue;
        }
        if (c == ';') { current = 0; continue; }
        const bool sign = (c == '-' || c == '+' || c == '.') && i + 1 < text.size() && std::isdigit(static_cast<unsigned char>(text[i + 1]));
        if (std::isdigit(static_cast<unsigned char>(c)) || sign) {
            // A number (reals always carry a point); an identifier's digits never start a token here.
            if (i > 0 && (std::isalnum(static_cast<unsigned char>(text[i - 1])) || text[i - 1] == '_')) continue;
            char *end = nullptr;
            const double value = std::strtod(text.c_str() + i, &end);
            const size_t length = size_t(end - (text.c_str() + i));
            if (length == 0) continue;
            const std::string token = text.substr(i, length);
            if (token.find_first_of(".Ee") != std::string::npos) {
                const double size = std::fabs(value);
                if (!std::isfinite(value) || size > 1e10 || (size > 0 && size < 1e-100)) return "some of its numbers are far outside any real model";
            }
            i += length - 1;
            continue;
        }
        if (c != '#') continue;
        size_t j = i + 1;
        long number = 0;
        while (j < text.size() && std::isdigit(static_cast<unsigned char>(text[j])) && number < 1000000000L) number = number * 10 + (text[j++] - '0');
        if (j == i + 1) continue;
        i = j - 1;
        if (current == 0) {
            size_t k = j;
            while (k < text.size() && std::isspace(static_cast<unsigned char>(text[k]))) ++k;
            if (k < text.size() && text[k] == '=') { current = number; defined.insert(number); }
        } else {
            refs[current].push_back(number);
        }
    }
    for (const auto &entry : refs) {
        for (const long target : entry.second) if (!defined.count(target)) return "some of its entries refer to entries it does not have";
    }
    // Depth-first search without recursion: 1 on the current path, 2 finished.
    std::unordered_map<long, uint8_t> state;
    for (const auto &entry : refs) {
        if (state[entry.first]) continue;
        std::vector<std::pair<long, size_t>> path{{entry.first, 0}};
        state[entry.first] = 1;
        while (!path.empty()) {
            auto &[node, next] = path.back();
            const auto found = refs.find(node);
            if (found == refs.end() || next >= found->second.size()) { state[node] = 2; path.pop_back(); continue; }
            const long child = found->second[next++];
            const uint8_t seen = state[child];
            if (seen == 1) return "some of its entries refer to themselves";
            if (seen == 0) { state[child] = 1; path.emplace_back(child, 0); }
        }
    }
    return nullptr;
}

SSKShape *ssk_read_step(const char *path, int32_t *skipped) {
    if (skipped) *skipped = 0;
    return guarded("STEP import", [&]() -> TopoDS_Shape {
        // The reader reports transfer statistics to stdout; the app has no use for them.
        Message::DefaultMessenger()->RemovePrinters(STANDARD_TYPE(Message_PrinterOStream));
        if (!path) throw Standard_Failure("This is not a readable STEP file");
        if (const char *damage = stepDamage(path)) {
            throw Standard_Failure((std::string("This STEP file is damaged: ") + damage + ". Export it again from its original program.").c_str());
        }
        STEPControl_Reader reader;
        if (reader.ReadFile(path) != IFSelect_RetDone) throw Standard_Failure("This is not a readable STEP file");
        // A damaged file (an entity missing or cut short, a field of the wrong type) leaves empty
        // references that the translator follows without checking, which would crash the app.
        // Such entities carry a failed load check; refuse the file instead (October 21, 2026).
        const auto model = reader.Model();
        if (model.IsNull()) throw Standard_Failure("This is not a readable STEP file");
        // Points and directions with numbers no real model has (beyond ten million units, or not
        // finite) send the shape repair into degenerate geometry, which crashes too.
        int damaged = 0;
        auto absurd = [](double v) { return !std::isfinite(v) || std::fabs(v) > 1e7; };
        for (int i = 1; i <= model->NbEntities(); ++i) {
            if (model->IsErrorEntity(i)) { ++damaged; continue; }
            const auto &check = model->Check(i, true);
            if (!check.IsNull() && check->HasFailed()) { ++damaged; continue; }
            const auto entity = model->Value(i);
            if (const auto vertex = occ::down_cast<StepShape_VertexPoint>(entity)) {
                // A vertex on a flat (2-D) point, or on none, has no place in space.
                const auto point = occ::down_cast<StepGeom_CartesianPoint>(vertex->VertexGeometry());
                if (vertex->VertexGeometry().IsNull() || (!point.IsNull() && point->NbCoordinates() != 3)) ++damaged;
            } else if (const auto placement = occ::down_cast<StepGeom_Axis2Placement3d>(entity)) {
                // A placement in space needs a 3-D point.
                const auto location = placement->Location();
                if (location.IsNull() || location->NbCoordinates() != 3) ++damaged;
            } else if (const auto pcurve = occ::down_cast<StepGeom_Pcurve>(entity)) {
                // A curve on a surface is defined by a curve.
                const auto definition = pcurve->ReferenceToCurve();
                if (definition.IsNull() || definition->NbItems() < 1 || occ::down_cast<StepGeom_Curve>(definition->ItemsValue(1)).IsNull()) ++damaged;
            } else if (const auto point = occ::down_cast<StepGeom_CartesianPoint>(entity)) {
                for (int k = 0; k < point->NbCoordinates() && k < 3; ++k) if (absurd(point->Coordinates()[k])) { ++damaged; break; }
            } else if (const auto direction = occ::down_cast<StepGeom_Direction>(entity)) {
                const auto &ratios = direction->DirectionRatios();
                double length = 0;
                for (int k = 0; k < direction->NbDirectionRatios() && k < 3; ++k) {
                    if (absurd(ratios[k])) { length = -1; break; }
                    length += ratios[k] * ratios[k];
                }
                if (!(length > 1e-24)) ++damaged;
            }
        }
        if (damaged > 0) {
            throw Standard_Failure((std::string("This STEP file is damaged: ") + std::to_string(damaged) +
                                    (damaged == 1 ? " entry" : " entries") + " could not be read. Export it again from its original program.").c_str());
        }
        reader.SetSystemLengthUnit(1.0);   // millimeters, whatever units the file uses
        reader.TransferRoots();
        const TopoDS_Shape all = reader.OneShape();
        if (all.IsNull()) throw Standard_Failure("The STEP file has no shapes");
        BRep_Builder builder;
        TopoDS_Compound result;
        builder.MakeCompound(result);
        int solids = 0, left = 0;
        auto keep = [&](TopoDS_Solid solid) {
            BRepLib::OrientClosedSolid(solid);
            if (volume(solid) > 1e-9) { builder.Add(result, solid); ++solids; } else { ++left; }
        };
        for (TopExp_Explorer it(all, TopAbs_SOLID); it.More(); it.Next()) keep(TopoDS::Solid(it.Current()));
        // Surfaces that are not part of a solid: sew them, and keep each closed shell as a solid.
        BRepBuilderAPI_Sewing sewing(1e-3);
        int loose = 0;
        for (TopExp_Explorer it(all, TopAbs_FACE, TopAbs_SOLID); it.More(); it.Next()) { sewing.Add(it.Current()); ++loose; }
        if (loose > 0) {
            sewing.Perform();
            for (TopExp_Explorer it(sewing.SewedShape(), TopAbs_SHELL); it.More(); it.Next()) {
                const TopoDS_Shell shell = TopoDS::Shell(it.Current());
                if (!BRep_Tool::IsClosed(shell)) { ++left; continue; }
                BRepBuilderAPI_MakeSolid maker(shell);
                if (maker.IsDone()) keep(maker.Solid()); else ++left;
            }
        }
        if (skipped) *skipped = left;
        if (solids == 0) throw Standard_Failure("The STEP file has no closed solids");
        return result;
    });
}

int32_t ssk_solid_count(const SSKShape *shape) {
    if (!shape) return 0;
    try {
        int32_t count = 0;
        for (TopExp_Explorer it(shape->shape, TopAbs_SOLID); it.More(); it.Next()) ++count;
        return count;
    } catch (...) { return 0; }
}

SSKShape *ssk_solid(const SSKShape *shape, int32_t index) {
    return guarded("Solid", [&]() -> TopoDS_Shape {
        if (!shape) throw Standard_Failure("missing shape");
        int32_t i = 0;
        for (TopExp_Explorer it(shape->shape, TopAbs_SOLID); it.More(); it.Next(), ++i) if (i == index) return it.Current();
        throw Standard_Failure("No such solid");
    });
}

uint8_t *ssk_write_shape(const SSKShape *shape, int64_t *length) {
    if (length) *length = 0;
    if (!shape) return nullptr;
    lastError.clear();
    try {
        std::ostringstream stream(std::ios::out | std::ios::binary);
        BinTools::Write(shape->shape, stream, false, false, BinTools_FormatVersion_CURRENT);
        const std::string bytes = stream.str();
        auto *result = static_cast<uint8_t *>(std::malloc(std::max<size_t>(bytes.size(), 1)));
        if (!result) { fail("Out of memory"); return nullptr; }
        std::memcpy(result, bytes.data(), bytes.size());
        if (length) *length = int64_t(bytes.size());
        return result;
    } catch (const Standard_Failure &error) {
        fail(std::string("Saving the shape failed: ") + (error.what() ? error.what() : ""));
    } catch (...) { fail("Saving the shape failed"); }
    return nullptr;
}

void ssk_bytes_free(uint8_t *bytes) { std::free(bytes); }

SSKShape *ssk_read_shape(const uint8_t *bytes, int64_t length) {
    return guarded("Reading the shape", [&]() -> TopoDS_Shape {
        if (!bytes || length <= 0) throw Standard_Failure("no shape data");
        std::istringstream stream(std::string(reinterpret_cast<const char *>(bytes), size_t(length)), std::ios::in | std::ios::binary);
        TopoDS_Shape shape;
        BinTools::Read(shape, stream);
        return shape;
    });
}

SSKShape *ssk_moved(const SSKShape *shape, const double *m) {
    return guarded("Moving the shape", [&]() -> TopoDS_Shape {
        if (!shape || !m) throw Standard_Failure("missing shape");
        gp_Trsf transform;
        transform.SetValues(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
        if (transform.IsNegative()) throw Standard_Failure("a move cannot mirror");
        // A placement only: the geometry and its triangulation are shared, so this costs nothing.
        return shape->shape.Moved(TopLoc_Location(transform));
    });
}

SSKShape *ssk_transform(const SSKShape *shape, const double *m) {
    return guarded("Placing the shape", [&]() -> TopoDS_Shape {
        if (!shape || !m) throw Standard_Failure("missing shape");
        gp_Trsf transform;
        transform.SetValues(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
        BRepBuilderAPI_Transform placed(shape->shape, transform, true);
        TopoDS_Shape result = placed.Shape();
        // A mirror turns the solid inside out; face it outward again.
        for (TopExp_Explorer it(result, TopAbs_SOLID); it.More(); it.Next()) {
            TopoDS_Solid solid = TopoDS::Solid(it.Current());
            BRepLib::OrientClosedSolid(solid);
            if (result.ShapeType() == TopAbs_SOLID) result = solid;
        }
        return result;
    });
}

double ssk_edge_distance(const SSKShape *shape, int32_t edge, SSKVec3 point) {
    if (!shape || edge < 0 || edge >= shape->edges.Extent()) return -1;
    try {
        const TopoDS_Vertex v = BRepBuilderAPI_MakeVertex(gp_Pnt(point.x, point.y, point.z)).Vertex();
        BRepExtrema_DistShapeShape distance(v, shape->edges.FindKey(edge + 1));
        return distance.IsDone() ? distance.Value() : -1;
    } catch (...) {}
    return -1;
}

void ssk_shape_free(SSKShape *shape) { delete shape; }

int32_t ssk_face_count(const SSKShape *shape) { return shape ? shape->faces.Extent() : 0; }
int32_t ssk_edge_count(const SSKShape *shape) { return shape ? shape->edges.Extent() : 0; }

bool ssk_is_valid_solid(const SSKShape *shape) {
    if (!shape) return false;
    try {
        int solids = 0;
        for (TopExp_Explorer it(shape->shape, TopAbs_SOLID); it.More(); it.Next()) ++solids;
        return solids == 1 && BRepCheck_Analyzer(shape->shape).IsValid();
    } catch (...) { return false; }
}

double ssk_volume(const SSKShape *shape) {
    if (!shape) return 0;
    try { return volume(shape->shape); } catch (...) { return 0; }
}

void ssk_bounds(const SSKShape *shape, SSKVec3 *minimum, SSKVec3 *maximum) {
    SSKVec3 zero = {0, 0, 0};
    if (minimum) *minimum = zero;
    if (maximum) *maximum = zero;
    if (!shape) return;
    try {
        Bnd_Box box;
        BRepBndLib::AddOptimal(shape->shape, box, false, false);
        if (box.IsVoid()) return;
        double x0, y0, z0, x1, y1, z1;
        box.Get(x0, y0, z0, x1, y1, z1);
        if (minimum) *minimum = {x0, y0, z0};
        if (maximum) *maximum = {x1, y1, z1};
    } catch (...) {}
}

int32_t ssk_face_edges(const SSKShape *shape, int32_t face, int32_t *edges, int32_t capacity) {
    if (!shape || face < 0 || face >= shape->faces.Extent()) return -1;
    try {
        ShapeMap own;
        TopExp::MapShapes(shape->faces.FindKey(face + 1), TopAbs_EDGE, own);
        for (int32_t i = 1; i <= own.Extent(); ++i)
            if (edges && i <= capacity) edges[i - 1] = shape->edges.FindIndex(own.FindKey(i)) - 1;
        return own.Extent();
    } catch (...) { return -1; }
}

bool ssk_face_center(const SSKShape *shape, int32_t face, double *xyz) {
    if (!shape || !xyz || face < 0 || face >= shape->faces.Extent()) return false;
    try {
        GProp_GProps properties;
        BRepGProp::SurfaceProperties(shape->faces.FindKey(face + 1), properties);
        const gp_Pnt c = properties.CentreOfMass();
        xyz[0] = c.X(); xyz[1] = c.Y(); xyz[2] = c.Z();
        return true;
    } catch (...) { return false; }
}

bool ssk_edge_circle(const SSKShape *shape, int32_t edge, double *xyz, double *radius) {
    if (!shape || !xyz || !radius || edge < 0 || edge >= shape->edges.Extent()) return false;
    try {
        const TopoDS_Edge &e = TopoDS::Edge(shape->edges.FindKey(edge + 1));
        if (BRep_Tool::Degenerated(e)) return false;
        BRepAdaptor_Curve curve(e);
        if (curve.GetType() != GeomAbs_Circle) return false;
        const gp_Circ circle = curve.Circle();
        xyz[0] = circle.Location().X(); xyz[1] = circle.Location().Y(); xyz[2] = circle.Location().Z();
        *radius = circle.Radius();
        return true;
    } catch (...) { return false; }
}

bool ssk_face_plane(const SSKShape *shape, int32_t face, double *origin, double *normal) {
    if (!shape || !origin || !normal || face < 0 || face >= shape->faces.Extent()) return false;
    try {
        const TopoDS_Face &f = TopoDS::Face(shape->faces.FindKey(face + 1));
        gp_Dir n;
        if (!outwardNormal(f, n)) return false;
        const gp_Pnt o = BRepAdaptor_Surface(f).Plane().Location();
        origin[0] = o.X(); origin[1] = o.Y(); origin[2] = o.Z();
        normal[0] = n.X(); normal[1] = n.Y(); normal[2] = n.Z();
        return true;
    } catch (...) { return false; }
}

bool ssk_face_cylinder(const SSKShape *shape, int32_t face, double *axisPoint, double *axisDirection, double *radius) {
    if (!shape || !axisPoint || !axisDirection || !radius || face < 0 || face >= shape->faces.Extent()) return false;
    try {
        BRepAdaptor_Surface surface(TopoDS::Face(shape->faces.FindKey(face + 1)));
        if (surface.GetType() != GeomAbs_Cylinder) return false;
        const gp_Cylinder cylinder = surface.Cylinder();
        const gp_Pnt p = cylinder.Axis().Location();
        const gp_Dir d = cylinder.Axis().Direction();
        axisPoint[0] = p.X(); axisPoint[1] = p.Y(); axisPoint[2] = p.Z();
        axisDirection[0] = d.X(); axisDirection[1] = d.Y(); axisDirection[2] = d.Z();
        *radius = cylinder.Radius();
        return true;
    } catch (...) { return false; }
}

double ssk_edge_length(const SSKShape *shape, int32_t edge) {
    if (!shape || edge < 0 || edge >= shape->edges.Extent()) return -1;
    try {
        GProp_GProps properties;
        BRepGProp::LinearProperties(shape->edges.FindKey(edge + 1), properties);
        return properties.Mass();
    } catch (...) { return -1; }
}

double ssk_face_area(const SSKShape *shape, int32_t face) {
    if (!shape || face < 0 || face >= shape->faces.Extent()) return -1;
    try {
        GProp_GProps properties;
        BRepGProp::SurfaceProperties(shape->faces.FindKey(face + 1), properties);
        return properties.Mass();
    } catch (...) { return -1; }
}

double ssk_surface_area(const SSKShape *shape) {
    if (!shape) return 0;
    try {
        GProp_GProps properties;
        BRepGProp::SurfaceProperties(shape->shape, properties);
        return properties.Mass();
    } catch (...) { return 0; }
}

int32_t ssk_edge_near(const SSKShape *shape, SSKVec3 point, double tolerance) {
    if (!shape) return -1;
    try {
        const gp_Pnt p(point.x, point.y, point.z);
        const TopoDS_Vertex v = BRepBuilderAPI_MakeVertex(p).Vertex();
        int32_t best = -1;
        double nearest = tolerance;
        for (int32_t i = 1; i <= shape->edges.Extent(); ++i) {
            const TopoDS_Edge &e = TopoDS::Edge(shape->edges.FindKey(i));
            if (BRep_Tool::Degenerated(e)) continue;
            Bnd_Box box;
            BRepBndLib::Add(e, box, false);
            box.Enlarge(nearest);
            if (box.IsOut(p)) continue;
            BRepExtrema_DistShapeShape distance(v, e);
            if (!distance.IsDone()) continue;
            if (distance.Value() <= nearest) { nearest = distance.Value(); best = i - 1; }
        }
        return best;
    } catch (...) {}
    return -1;
}

double ssk_distance(const SSKShape *a, SSKPart partA, int32_t indexA, const SSKShape *b, SSKPart partB, int32_t indexB,
                   SSKVec3 *pointA, SSKVec3 *pointB) {
    if (!a || !b) return -1;
    auto part = [](const SSKShape *shape, SSKPart kind, int32_t index) -> TopoDS_Shape {
        switch (kind) {
            case SSKPartFace: return index >= 0 && index < shape->faces.Extent() ? shape->faces.FindKey(index + 1) : TopoDS_Shape();
            case SSKPartEdge: return index >= 0 && index < shape->edges.Extent() ? shape->edges.FindKey(index + 1) : TopoDS_Shape();
            case SSKPartWhole: return shape->shape;
        }
        return TopoDS_Shape();
    };
    try {
        const TopoDS_Shape first = part(a, partA, indexA), second = part(b, partB, indexB);
        if (first.IsNull() || second.IsNull()) return -1;
        BRepExtrema_DistShapeShape distance(first, second);
        if (!distance.IsDone() || distance.NbSolution() < 1) return -1;
        const gp_Pnt p = distance.PointOnShape1(1), q = distance.PointOnShape2(1);
        if (pointA) *pointA = {p.X(), p.Y(), p.Z()};
        if (pointB) *pointB = {q.X(), q.Y(), q.Z()};
        return distance.Value();
    } catch (...) { return -1; }
}

SSKShape *ssk_make_point(SSKVec3 point) {
    return guarded("Point", [&] { return BRepBuilderAPI_MakeVertex(gp_Pnt(point.x, point.y, point.z)).Shape(); });
}

SSKShape *ssk_make_segment(SSKVec3 a, SSKVec3 b) {
    return guarded("Segment", [&] {
        const gp_Pnt p(a.x, a.y, a.z), q(b.x, b.y, b.z);
        if (p.Distance(q) < 1e-9) throw Standard_Failure("the segment is degenerate");
        return BRepBuilderAPI_MakeEdge(p, q).Shape();
    });
}

SSKShape *ssk_make_arc(SSKVec3 center, SSKVec3 normal, SSKVec3 start, double degrees) {
    return guarded("Arc", [&] {
        const gp_Pnt c(center.x, center.y, center.z), s(start.x, start.y, start.z);
        const double radius = c.Distance(s);
        if (!(radius > 1e-9)) throw Standard_Failure("the arc is degenerate");
        gp_Circ circle(gp_Ax2(c, gp_Dir(normal.x, normal.y, normal.z), gp_Dir(gp_Vec(c, s))), radius);
        if (std::fabs(degrees) >= 360 - 1e-9) return BRepBuilderAPI_MakeEdge(circle).Shape();
        const double sweep = degrees * M_PI / 180;
        return BRepBuilderAPI_MakeEdge(circle, std::min(0.0, sweep), std::max(0.0, sweep)).Shape();
    });
}

bool ssk_edge_samples(const SSKShape *shape, int32_t edge, int32_t count, double *xyz) {
    if (!shape || !xyz || count < 2 || edge < 0 || edge >= shape->edges.Extent()) return false;
    try {
        const TopoDS_Edge &e = TopoDS::Edge(shape->edges.FindKey(edge + 1));
        if (BRep_Tool::Degenerated(e)) return false;
        BRepAdaptor_Curve curve(e);
        const double first = curve.FirstParameter(), last = curve.LastParameter();
        for (int32_t i = 0; i < count; ++i) {
            gp_Pnt p = curve.Value(first + (last - first) * i / (count - 1));
            xyz[3 * i] = p.X(); xyz[3 * i + 1] = p.Y(); xyz[3 * i + 2] = p.Z();
        }
        return true;
    } catch (...) { return false; }
}

SSKMesh *ssk_tessellate(const SSKShape *shape, double linearDeflection, double angularDeflection) {
    lastError.clear();
    if (!shape) { fail("Tessellate failed: missing shape"); return nullptr; }
    try {
        // Meshing caches triangulations on the shape's faces, so callers must not tessellate
        // the same shape from two threads at once (the Swift wrapper serializes this).
        BRepMesh_IncrementalMesh mesher(shape->shape, linearDeflection, false, angularDeflection, true);
        if (!mesher.IsDone()) { fail("Tessellate failed"); return nullptr; }

        // Owned until returned, so an exception part-way through does not leak it.
        auto mesh = std::make_unique<SSKMesh>();
        mesh->faceStarts.push_back(0);
        for (int32_t f = 1; f <= shape->faces.Extent(); ++f) {
            const TopoDS_Face &face = TopoDS::Face(shape->faces.FindKey(f));
            TopLoc_Location location;
            const occ::handle<Poly_Triangulation> &triangles = BRep_Tool::Triangulation(face, location);
            if (!triangles.IsNull()) {
                BRepLib_ToolTriangulatedShape::ComputeNormals(face, triangles);
                const gp_Trsf transform = location.Transformation();
                const bool reversed = face.Orientation() == TopAbs_REVERSED;
                const uint32_t base = uint32_t(mesh->positions.size() / 3);
                for (int n = 1; n <= triangles->NbNodes(); ++n) {
                    gp_Pnt p = triangles->Node(n).Transformed(transform);
                    gp_Dir d = triangles->Normal(n).Transformed(transform);
                    if (reversed) d.Reverse();
                    mesh->positions.insert(mesh->positions.end(), {float(p.X()), float(p.Y()), float(p.Z())});
                    mesh->normals.insert(mesh->normals.end(), {float(d.X()), float(d.Y()), float(d.Z())});
                }
                for (int t = 1; t <= triangles->NbTriangles(); ++t) {
                    int a, b, c;
                    triangles->Triangle(t).Get(a, b, c);
                    if (reversed) std::swap(b, c);
                    mesh->indices.insert(mesh->indices.end(), {base + uint32_t(a - 1), base + uint32_t(b - 1), base + uint32_t(c - 1)});
                }
            }
            mesh->faceStarts.push_back(int32_t(mesh->indices.size()));
        }

        AncestorMap edgeFaces;
        TopExp::MapShapesAndAncestors(shape->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        mesh->edgeStarts.push_back(0);
        for (int32_t e = 1; e <= shape->edges.Extent(); ++e) {
            const TopoDS_Edge &edge = TopoDS::Edge(shape->edges.FindKey(e));
            uint8_t flags = BRep_Tool::Degenerated(edge) ? SSKEdgeDegenerate : 0;
            const NCollection_List<TopoDS_Shape> *faces = edgeFaces.Seek(edge);
            if (!flags && faces && !faces->IsEmpty()) {
                const TopoDS_Face &face = TopoDS::Face(faces->First());
                if (BRep_Tool::IsClosed(edge, face)) flags |= SSKEdgeSeam;
                TopLoc_Location location;
                const occ::handle<Poly_Triangulation> &triangles = BRep_Tool::Triangulation(face, location);
                if (!triangles.IsNull()) {
                    const occ::handle<Poly_PolygonOnTriangulation> &polygon = BRep_Tool::PolygonOnTriangulation(edge, triangles, location);
                    if (!polygon.IsNull()) {
                        const gp_Trsf transform = location.Transformation();
                        for (int i = 1; i <= polygon->NbNodes(); ++i) {
                            gp_Pnt p = triangles->Node(polygon->Node(i)).Transformed(transform);
                            mesh->edgePoints.insert(mesh->edgePoints.end(), {float(p.X()), float(p.Y()), float(p.Z())});
                        }
                    }
                }
            }
            mesh->edgeFlags.push_back(flags);
            mesh->edgeStarts.push_back(int32_t(mesh->edgePoints.size() / 3));
        }
        return mesh.release();
    } catch (const Standard_Failure &error) {
        fail(std::string("Tessellate failed: ") + error.what());
    } catch (const std::exception &error) {
        fail(std::string("Tessellate failed: ") + error.what());
    } catch (...) {
        fail("Tessellate failed");
    }
    return nullptr;
}

// MARK: Missing basics (October 21, 2026): scale, delete face, offset face, tapered and ellipse
// extrusions, and 2D offsets.

SSKShape *ssk_extrude_region_ex(SSKPlane plane, const double *xy, const double *mids, const double *ellipses,
                                const int32_t *loopSizes, int32_t loopCount, double offset, double depth, double draftDegrees) {
    return guarded("Extrude", [&] {
        return draftedPrism(regionFace(plane, xy, mids, loopSizes, loopCount, ellipses), plane, offset, depth, draftDegrees);
    });
}

SSKShape *ssk_revolve_region_ex(SSKPlane plane, const double *xy, const double *mids, const double *ellipses,
                                const int32_t *loopSizes, int32_t loopCount,
                                double axisU0, double axisV0, double axisU1, double axisV1, double degrees) {
    return guarded("Revolve", [&] {
        const TopoDS_Face face = regionFace(plane, xy, mids, loopSizes, loopCount, ellipses);
        // The outer loop decides the side of the axis; holes lie inside it.
        std::vector<std::pair<double, double>> points;
        double reach = 0;
        if (loopSizes[0] == 1 && ellipses && ellipses[3] > 0.5) {
            points.emplace_back(xy[0], xy[1]);
            reach = std::max(ellipses[0], ellipses[1]);
        } else if (loopSizes[0] == 1) {
            points.emplace_back(mids[0], mids[1]);
            reach = std::hypot(xy[0] - mids[0], xy[1] - mids[1]);
        } else {
            for (int32_t i = 0; i < loopSizes[0]; ++i) {
                points.emplace_back(xy[2 * i], xy[2 * i + 1]);
                if (mids && std::isfinite(mids[2 * i]) && std::isfinite(mids[2 * i + 1])) points.emplace_back(mids[2 * i], mids[2 * i + 1]);
            }
        }
        requireOneSide(points, axisU0, axisV0, axisU1, axisV1, reach);
        return revolution(face, point(plane, axisU0, axisV0), point(plane, axisU1, axisV1), degrees);
    });
}

SSKShape *ssk_scale(const SSKShape *shape, SSKVec3 center, SSKVec3 xAxis, SSKVec3 yAxis, double fx, double fy, double fz) {
    return guarded("Scale", [&]() -> TopoDS_Shape {
        if (!shape) throw Standard_Failure("missing shape");
        for (double f : {fx, fy, fz}) {
            if (!std::isfinite(f) || f < 0.001 || f > 1000) throw Standard_Failure("scale factors must be 0.1% to 100000%");
        }
        const gp_Pnt c(center.x, center.y, center.z);
        TopoDS_Shape result;
        if (std::fabs(fx - fy) < 1e-12 && std::fabs(fy - fz) < 1e-12) {
            gp_Trsf scale;
            scale.SetScale(c, fx);
            result = BRepBuilderAPI_Transform(shape->shape, scale, true).Shape();
        } else {
            gp_Vec x(xAxis.x, xAxis.y, xAxis.z), y(yAxis.x, yAxis.y, yAxis.z);
            if (x.Magnitude() < 1e-12 || y.Magnitude() < 1e-12) throw Standard_Failure("scale axes are degenerate");
            x.Normalize(); y.Normalize();
            const gp_Vec z = x.Crossed(y);
            // M = R · diag(f) · Rᵀ, about the center: p' = M p + (c − M c).
            const gp_Mat r(x.XYZ(), y.XYZ(), z.XYZ());
            gp_Mat rt = r;
            rt.Transpose();
            const gp_Mat m = r * gp_Mat(fx, 0, 0, 0, fy, 0, 0, 0, fz) * rt;
            gp_XYZ moved = c.XYZ();
            moved.Multiply(m);
            gp_GTrsf stretch;
            stretch.SetVectorialPart(m);
            stretch.SetTranslationPart(c.XYZ() - moved);
            BRepBuilderAPI_GTransform maker(shape->shape, stretch, true);
            if (!maker.IsDone()) throw Standard_Failure("the solid could not be stretched");
            result = maker.Shape();
        }
        for (TopExp_Explorer it(result, TopAbs_SOLID); it.More(); it.Next()) {
            TopoDS_Solid solid = TopoDS::Solid(it.Current());
            BRepLib::OrientClosedSolid(solid);
        }
        return requireValid(result, "the scaled solid is not valid");
    });
}

SSKShape *ssk_remove_faces(const SSKShape *shape, const int32_t *faces, int32_t faceCount) {
    return guarded("Delete face", [&]() -> TopoDS_Shape {
        if (!shape) throw Standard_Failure("missing shape");
        const NCollection_List<TopoDS_Shape> chosen = select(shape->faces, faces, faceCount, "face");
        BRepAlgoAPI_Defeaturing defeature;
        defeature.SetShape(shape->shape);
        defeature.AddFacesToRemove(chosen);
        defeature.SetToFillHistory(false);
        defeature.SetRunParallel(true);
        defeature.Build();
        if (!defeature.IsDone() || defeature.HasErrors()) throw Standard_Failure("the faces around them cannot close the gap");
        const TopoDS_Shape result = requireValid(defeature.Shape(), "the faces around them cannot close the gap");
        ShapeMap left;
        TopExp::MapShapes(result, TopAbs_FACE, left);
        if (left.Extent() >= shape->faces.Extent() && std::fabs(volume(result) - volume(shape->shape)) < 1e-9)
            throw Standard_Failure("the faces around them cannot close the gap");
        return result;
    });
}

SSKShape *ssk_offset_faces(const SSKShape *shape, const int32_t *faces, int32_t faceCount, double distance) {
    return guarded("Offset face", [&]() -> TopoDS_Shape {
        if (!shape) throw Standard_Failure("missing shape");
        if (!std::isfinite(distance) || std::fabs(distance) < 0.0005 || std::fabs(distance) > 1000) throw Standard_Failure("the distance must be 0.0005 to 1000 mm");
        const NCollection_List<TopoDS_Shape> chosen = select(shape->faces, faces, faceCount, "face");
        const double before = volume(shape->shape);
        // Every other face stays put (offset 0) and is trimmed or extended to meet the moved ones.
        for (bool intersection : {true, false}) {
            try {
                BRepOffset_MakeOffset offset;
                offset.Initialize(shape->shape, 0.0, 1e-5, BRepOffset_Skin, intersection, false, GeomAbs_Intersection, false, false);
                for (const TopoDS_Shape &face : chosen) offset.SetOffsetOnFace(TopoDS::Face(face), distance);
                offset.MakeOffsetShape();
                if (!offset.IsDone()) continue;
                const TopoDS_Shape moved = offset.Shape();
                TopoDS_Solid solid;
                TopExp_Explorer solids(moved, TopAbs_SOLID);
                if (solids.More()) {
                    solid = TopoDS::Solid(solids.Current());
                } else {
                    TopExp_Explorer shells(moved, TopAbs_SHELL);
                    if (!shells.More()) continue;
                    BRepBuilderAPI_MakeSolid maker(TopoDS::Shell(shells.Current()));
                    if (!maker.IsDone()) continue;
                    solid = maker.Solid();
                }
                BRepLib::OrientClosedSolid(solid);
                if (!BRepCheck_Analyzer(solid).IsValid()) continue;
                const double after = volume(solid);
                if (!(after > 1e-9) || std::fabs(after - before) < 1e-9) continue;
                // Moved out, a face adds material; moved in, it takes some away.
                if ((after > before) != (distance > 0)) continue;
                return TopoDS_Shape(solid);
            } catch (const Standard_Failure &) {}
        }
        throw Standard_Failure("this face cannot move that far; the faces around it cannot follow");
    });
}

int32_t ssk_offset_outline(SSKPlane plane, const double *xy, const double *mids, int32_t pointCount, bool closed, double distance,
                           bool rounded, double *outXY, double *outMids, int32_t *outLoopSizes, bool *closedLoops,
                           int32_t capacity, int32_t loopCapacity, int32_t *loopCount) {
    lastError.clear();
    if (loopCount) *loopCount = 0;
    try {
        if (!xy || pointCount < (closed ? 1 : 2)) throw Standard_Failure("nothing to offset");
        if (!std::isfinite(distance) || std::fabs(distance) < 1e-4 || std::fabs(distance) > 10000) throw Standard_Failure("the distance must be 0.0001 to 10000 mm");
        TopoDS_Wire wire;
        if (closed) {
            wire = loopWire(plane, xy, mids, pointCount);
        } else {
            BRepBuilderAPI_MakeWire chain;
            for (int32_t i = 0; i + 1 < pointCount; ++i) {
                const gp_Pnt a = point(plane, xy[2 * i], xy[2 * i + 1]), b = point(plane, xy[2 * i + 2], xy[2 * i + 3]);
                if (mids && std::isfinite(mids[2 * i]) && std::isfinite(mids[2 * i + 1])) {
                    GC_MakeArcOfCircle arc(a, point(plane, mids[2 * i], mids[2 * i + 1]), b);
                    if (!arc.IsDone()) throw Standard_Failure("an arc is degenerate");
                    chain.Add(BRepBuilderAPI_MakeEdge(arc.Value()).Edge());
                } else {
                    if (a.Distance(b) < 1e-7) throw Standard_Failure("an edge is degenerate");
                    chain.Add(BRepBuilderAPI_MakeEdge(a, b).Edge());
                }
                if (!chain.IsDone()) throw Standard_Failure("the edges do not join");
            }
            wire = chain.Wire();
        }
        const gp_Pln pln(gp_Ax3(point(plane, 0, 0), normal(plane), gp_Dir(plane.xAxis.x, plane.xAxis.y, plane.xAxis.z)));
        TopoDS_Shape result;
        for (GeomAbs_JoinType join : {rounded ? GeomAbs_Arc : GeomAbs_Intersection, GeomAbs_Arc}) {
            try {
                BRepOffsetAPI_MakeOffset offset;
                if (closed) {
                    BRepBuilderAPI_MakeFace face(pln, wire, true);
                    if (!face.IsDone()) throw Standard_Failure("the outline is not flat");
                    offset.Init(face.Face(), join, false);
                } else {
                    offset.Init(join, true);
                    offset.AddWire(wire);
                }
                offset.Perform(distance);
                if (!offset.IsDone()) continue;
                result = offset.Shape();
                if (!result.IsNull()) break;
            } catch (const Standard_Failure &) {}
        }
        if (result.IsNull()) throw Standard_Failure("the outline cannot be offset that far");
        int32_t count = 0, loops = 0;
        auto add = [&](const gp_Pnt &p, double mu, double mv) {
            const auto uv = planeCoordinates(plane, p);
            if (outXY && count < capacity) { outXY[2 * count] = uv.first; outXY[2 * count + 1] = uv.second; }
            if (outMids && count < capacity) { outMids[2 * count] = mu; outMids[2 * count + 1] = mv; }
            ++count;
        };
        for (TopExp_Explorer w(result, TopAbs_WIRE); w.More(); w.Next()) {
            const TopoDS_Wire loop = TopoDS::Wire(w.Current());
            const int32_t start = count;
            int32_t edges = 0;
            for (TopExp_Explorer e(loop, TopAbs_EDGE); e.More(); e.Next()) ++edges;
            TopoDS_Vertex first, last;
            TopExp::Vertices(loop, first, last);
            const bool isClosed = !first.IsNull() && !last.IsNull() && BRep_Tool::Pnt(first).Distance(BRep_Tool::Pnt(last)) < 1e-6;
            gp_Pnt end;
            for (BRepTools_WireExplorer it(loop); it.More(); it.Next()) {
                const TopoDS_Edge &edge = it.Current();
                if (BRep_Tool::Degenerated(edge)) continue;
                BRepAdaptor_Curve curve(edge);
                const double a = curve.FirstParameter(), b = curve.LastParameter();
                const bool reversed = edge.Orientation() == TopAbs_REVERSED;
                const double from = reversed ? b : a, to = reversed ? a : b;
                end = curve.Value(to);
                if (curve.GetType() == GeomAbs_Line) {
                    add(curve.Value(from), NAN, NAN);
                } else if (curve.GetType() == GeomAbs_Circle) {
                    if (edges == 1 && std::fabs(b - a) >= 2 * M_PI - 1e-9) {
                        // A full circle: one point on it, its center as the mid.
                        const auto c = planeCoordinates(plane, curve.Circle().Location());
                        add(curve.Value(from), c.first, c.second);
                    } else {
                        const auto mid = planeCoordinates(plane, curve.Value((a + b) / 2));
                        add(curve.Value(from), mid.first, mid.second);
                    }
                } else {
                    // Any other curve, as short straight pieces.
                    const int32_t pieces = 32;
                    for (int32_t k = 0; k < pieces; ++k) add(curve.Value(from + (to - from) * k / pieces), NAN, NAN);
                }
            }
            if (!isClosed) add(end, NAN, NAN);
            if (outLoopSizes && loops < loopCapacity) outLoopSizes[loops] = count - start;
            if (closedLoops && loops < loopCapacity) closedLoops[loops] = isClosed;
            ++loops;
        }
        if (loops == 0) throw Standard_Failure("the outline cannot be offset that far");
        if (loopCount) *loopCount = loops;
        return count;
    } catch (const Standard_Failure &error) {
        fail(std::string("Offset failed: ") + (error.what() && *error.what() ? error.what() : error.ExceptionType()));
    } catch (...) {
        fail("Offset failed");
    }
    return -1;
}

void ssk_mesh_free(SSKMesh *mesh) { delete mesh; }
int32_t ssk_mesh_vertex_count(const SSKMesh *mesh) { return mesh ? int32_t(mesh->positions.size() / 3) : 0; }
const float *ssk_mesh_positions(const SSKMesh *mesh) { return mesh ? mesh->positions.data() : nullptr; }
const float *ssk_mesh_normals(const SSKMesh *mesh) { return mesh ? mesh->normals.data() : nullptr; }
int32_t ssk_mesh_index_count(const SSKMesh *mesh) { return mesh ? int32_t(mesh->indices.size()) : 0; }
const uint32_t *ssk_mesh_indices(const SSKMesh *mesh) { return mesh ? mesh->indices.data() : nullptr; }
int32_t ssk_mesh_face_count(const SSKMesh *mesh) { return mesh ? int32_t(mesh->faceStarts.size()) - 1 : 0; }
const int32_t *ssk_mesh_face_starts(const SSKMesh *mesh) { return mesh ? mesh->faceStarts.data() : nullptr; }
int32_t ssk_mesh_edge_count(const SSKMesh *mesh) { return mesh ? int32_t(mesh->edgeStarts.size()) - 1 : 0; }
const int32_t *ssk_mesh_edge_starts(const SSKMesh *mesh) { return mesh ? mesh->edgeStarts.data() : nullptr; }
const float *ssk_mesh_edge_points(const SSKMesh *mesh) { return mesh ? mesh->edgePoints.data() : nullptr; }
const uint8_t *ssk_mesh_edge_flags(const SSKMesh *mesh) { return mesh ? mesh->edgeFlags.data() : nullptr; }

} // extern "C"
