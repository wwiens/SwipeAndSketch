import XCTest
import simd
@testable import SwipeAndSketchCore

/// Model Tree groups: membership, visibility, saving, and the assistant.
final class GroupTests: XCTestCase {
    /// Two solids, a sketch, and a construction plane.
    func workspace() throws -> Workspace {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 10))
        let profile = try XCTUnwrap(Geometry.profiles(in: [rectangle], on: .top).first)
        var space = Workspace(shapes: [rectangle], bodies: [SolidBody(profile: profile, depth: 10), SolidBody(profile: profile, depth: 5)])
        space.constructionPlanes = [ConstructionPlane(plane: .top, width: 10, height: 10)]
        return space
    }

    func testGroupsHoldItemsAndOtherGroups() throws {
        let space = try workspace()
        let body = space.bodies[0].id, sketch = space.sketches[0].id, plane = space.constructionPlanes[0].id
        let (one, lid) = try XCTUnwrap(space.addingGroup(containing: [.body(body), .sketch(sketch)], name: " Lid "))
        XCTAssertEqual(one.groupNames[lid], "Lid")
        XCTAssertEqual(one.members(of: lid), [.body(body), .sketch(sketch)])
        XCTAssertEqual(one.members(of: nil), [.group(lid), .body(space.bodies[1].id), .plane(plane)])
        let (two, inner) = try XCTUnwrap(one.addingGroup(in: lid, containing: [.plane(plane)]))
        XCTAssertEqual(two.groupNames[inner], "Group 02", "Numbered in the order made")
        XCTAssertEqual(two.groupPath(inner), "Lid › Group 02")
        XCTAssertEqual(two.members(of: lid), [.group(inner), .body(body), .sketch(sketch)])
        XCTAssertEqual(Set(two.contents(of: lid).planes), [plane], "Contents include groups inside")
        XCTAssertTrue(two.isValid)

        XCTAssertNil(two.moving([.group(lid)], into: inner), "A group cannot go inside itself")
        XCTAssertNil(two.moving([.group(lid)], into: lid))
        XCTAssertNil(two.moving([.body(body)], into: UUID()), "A missing group")
        let out = try XCTUnwrap(two.moving([.body(body)], into: nil))
        XCTAssertNil(out.bodies[0].group)

        // Loops and missing groups are not valid (a damaged file is refused, not repaired).
        var looped = two
        looped.groups[0].parent = inner
        XCTAssertFalse(looped.isValid)
        var dangling = two
        dangling.bodies[1].group = UUID()
        XCTAssertFalse(dangling.isValid)
    }

    func testAHiddenGroupHidesEverythingInItAndKeepsTheirOwnEyes() throws {
        var space = try workspace()
        space.sketches[0].hidden = true
        let body = space.bodies[0].id, sketch = space.sketches[0].id, plane = space.constructionPlanes[0].id
        let (one, outer) = try XCTUnwrap(space.addingGroup(containing: [.body(body), .sketch(sketch)]))
        let (two, inner) = try XCTUnwrap(one.addingGroup(in: outer, containing: [.plane(plane)]))
        XCTAssertFalse(two.isHidden(body: body))
        XCTAssertTrue(two.isHidden(sketch: sketch), "Its own eye")

        let hidden = try XCTUnwrap(two.settingGroup(outer, hidden: true))
        XCTAssertTrue(hidden.isHidden(body: body))
        XCTAssertTrue(hidden.isHidden(plane: plane), "Through the group inside it")
        XCTAssertTrue(hidden.isGroupHidden(inner))
        XCTAssertFalse(hidden.isHidden(body: space.bodies[1].id), "Outside the group")
        XCTAssertNil(hidden.bodies[0].hidden, "The item's own eye is untouched")
        let visible = hidden.visible
        XCTAssertEqual(visible.bodies.map(\.id), [space.bodies[1].id])
        XCTAssertTrue(visible.constructionPlanes.isEmpty)
        XCTAssertTrue(visible.shapes.isEmpty)
        XCTAssertTrue(hidden.profiles.isEmpty, "A hidden group's sketches give no regions")

        // Shown again, everything is as it was: the sketch hidden on its own stays hidden.
        let shown = try XCTUnwrap(hidden.settingGroup(outer, hidden: false))
        XCTAssertFalse(shown.isHidden(body: body))
        XCTAssertTrue(shown.isHidden(sketch: sketch))

        // Ungrouping a hidden group keeps its contents off the canvas, one by one.
        let ungrouped = try XCTUnwrap(hidden.ungrouping(outer))
        XCTAssertEqual(ungrouped.groups.map(\.id), [inner])
        XCTAssertNil(ungrouped.groups[0].parent)
        XCTAssertTrue(ungrouped.isHidden(body: body))
        XCTAssertTrue(ungrouped.isHidden(plane: plane))
        XCTAssertNil(ungrouped.bodies[0].group)
        XCTAssertTrue(ungrouped.isValid)
    }

    func testDeletingAGroupDeletesItsContents() throws {
        let space = try workspace()
        let (one, outer) = try XCTUnwrap(space.addingGroup(containing: [.body(space.bodies[0].id), .sketch(space.sketches[0].id)]))
        let (two, _) = try XCTUnwrap(one.addingGroup(in: outer, containing: [.plane(space.constructionPlanes[0].id)]))
        let deleted = try XCTUnwrap(two.deletingGroup(outer))
        XCTAssertEqual(deleted.bodies.map(\.id), [space.bodies[1].id])
        XCTAssertTrue(deleted.sketches.isEmpty && deleted.shapes.isEmpty && deleted.constructionPlanes.isEmpty && deleted.groups.isEmpty)
        XCTAssertTrue(deleted.isValid)
    }

    func testGroupsSaveAndOlderFilesHaveNone() throws {
        let space = try workspace()
        let plain = try ProjectCodec.encode(Project(workspace: space))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"group"), "Files without groups are unchanged")
        let (one, lid) = try XCTUnwrap(space.addingGroup(containing: [.body(space.bodies[0].id), .sketch(space.sketches[0].id)], name: "Lid"))
        let grouped = try XCTUnwrap(one.settingGroup(lid, hidden: true))
        let data = try ProjectCodec.encode(Project(workspace: grouped))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, grouped)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"groups\""))
    }

    func testCopiesStayInTheirGroupOnlyWhereItExists() throws {
        let space = try workspace()
        let (grouped, lid) = try XCTUnwrap(space.addingGroup(containing: [.body(space.bodies[0].id), .sketch(space.sketches[0].id)]))
        let clipboard = grouped.copying(bodies: [space.bodies[0].id], sketches: [space.sketches[0].id])
        let here = try XCTUnwrap(grouped.pasting(clipboard))
        XCTAssertEqual(here.workspace.bodies.last?.group, lid, "A duplicate lands beside its original")
        XCTAssertEqual(here.workspace.sketches.last?.group, lid)
        let elsewhere = try XCTUnwrap(Workspace().pasting(clipboard))
        XCTAssertNil(elsewhere.workspace.bodies[0].group, "Another project has no such group")
        XCTAssertNil(elsewhere.workspace.sketches[0].group)
        XCTAssertTrue(elsewhere.workspace.isValid)
    }

    func testAssistantGroupsHidesAndUngroups() throws {
        var bench = AssistantWorkbench(workspace: try workspace())
        let made = try bench.group(items: ["Body 01", "Rectangle 01"], into: nil, newName: "Lid")
        XCTAssertEqual(made, "Moved Body 01, Rectangle 01 into a new group, Lid.")
        XCTAssertEqual(bench.workspace.bodies[0].group, bench.workspace.groups[0].id)
        XCTAssertEqual(bench.workspace.sketches[0].group, bench.workspace.groups[0].id, "A shape's sketch is grouped")
        XCTAssertTrue(bench.summary().contains("Lid: Body 01, Sketch 01"), bench.summary())
        _ = try bench.group(items: ["Plane 01"], into: "lid", newName: nil)
        XCTAssertEqual(bench.workspace.constructionPlanes[0].group, bench.workspace.groups[0].id)
        _ = try bench.setHidden(items: ["Lid"], hidden: true)
        XCTAssertTrue(bench.workspace.isHidden(body: bench.workspace.bodies[0].id))
        XCTAssertTrue(bench.summary().contains("Lid (hidden, with everything in it)"), bench.summary())
        XCTAssertTrue(bench.summary().contains("hidden by its group"), bench.summary())
        _ = try bench.rename(item: "Lid", to: "Cap")
        XCTAssertEqual(bench.workspace.groupNames[bench.workspace.groups[0].id], "Cap")
        XCTAssertThrowsError(try bench.group(items: ["Body 02"], into: "Nowhere", newName: nil))
        _ = try bench.ungroup("cap")
        XCTAssertTrue(bench.workspace.groups.isEmpty)
        XCTAssertTrue(bench.workspace.isHidden(body: bench.workspace.bodies[0].id), "Ungrouping a hidden group keeps its contents hidden")
    }

    func testSeveralMembersAtOnce() throws {
        let space = try workspace()
        let a = space.bodies[0].id, b = space.bodies[1].id, sketch = space.sketches[0].id, plane = space.constructionPlanes[0].id
        let (one, lid) = try XCTUnwrap(space.addingGroup(containing: [.body(a)]))
        // An item inside a picked group goes along with the group rather than on its own.
        XCTAssertEqual(one.outermost([.body(a), .group(lid), .sketch(sketch)]), [.group(lid), .sketch(sketch)])
        XCTAssertEqual(one.commonGroup(of: [.body(b), .sketch(sketch)]), nil)
        XCTAssertEqual(one.commonGroup(of: [.body(a)]), lid)
        let hidden = one.setting([.group(lid), .plane(plane)], hidden: true)
        XCTAssertTrue(hidden.isHidden(body: a) && hidden.isHidden(plane: plane))
        XCTAssertNil(hidden.bodies[0].hidden, "A group hides by its own eye")
        let deleted = try XCTUnwrap(one.deleting([.group(lid), .body(a), .sketch(sketch)]))
        XCTAssertEqual(deleted.bodies.map(\.id), [b])
        XCTAssertTrue(deleted.groups.isEmpty && deleted.sketches.isEmpty && deleted.shapes.isEmpty)
        XCTAssertEqual(deleted.constructionPlanes.map(\.id), [plane])
    }
}
