import Foundation

// Groups in the Model Tree (October 21, 2026): named containers for solids, sketches, construction
// planes, and other groups, so a model can be organized (a lid and its hardware, reference
// sketches) and parts of it shown or hidden together. A group's eye hides everything inside it
// without touching each item's own eye, so showing the group again brings back exactly what was
// shown before. Groups do not combine their contents; from October 24, 2026 a selected group moves,
// turns, scales, mirrors, patterns, duplicates, and exports as a unit (everything inside it at once).

/// A group of items in the Model Tree. Items name their group; a group names its parent group.
struct ItemGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// The name chosen in the Model Tree. Omitted when unset ("Group 01").
    var name: String?
    /// Hides everything inside. Omitted when shown.
    var hidden: Bool?
    /// The group it sits in. Omitted at the top of the tree.
    var parent: UUID?
    var isHidden: Bool { hidden == true }
}

/// Something that can sit in a group.
enum GroupMember: Hashable, Sendable {
    case body(UUID), sketch(UUID), plane(UUID), group(UUID)
}

extension Workspace {
    static let maximumGroups = 1_000
    /// Groups inside groups, at most this deep.
    static let maximumGroupDepth = 32

    var groupNames: [UUID: String] { ItemNames.names(groups.map { ($0.id, $0.name) }, numbered: "Group") }

    func group(_ id: UUID?) -> ItemGroup? { id.flatMap { id in groups.first { $0.id == id } } }

    /// Every group exists once, parents exist without loops, and every item's group exists.
    var groupsAreValid: Bool {
        guard groups.count <= Self.maximumGroups else { return false }
        let ids = Set(groups.map(\.id))
        guard ids.count == groups.count, groups.allSatisfy({ ItemNames.isValid($0.name) && ($0.parent.map(ids.contains) ?? true) }) else { return false }
        guard groups.allSatisfy({ ancestors(of: $0.id) != nil }) else { return false }
        let used = bodies.compactMap(\.group) + sketches.compactMap(\.group) + constructionPlanes.compactMap(\.group)
        return used.allSatisfy(ids.contains)
    }

    /// The groups above `id`, nearest first; nil when they loop or run too deep.
    func ancestors(of id: UUID) -> [UUID]? {
        var result: [UUID] = [], current = group(id)?.parent
        while let parent = current {
            guard parent != id, !result.contains(parent), result.count < Self.maximumGroupDepth else { return nil }
            result.append(parent)
            current = group(parent)?.parent
        }
        return result
    }

    /// `id` and every group inside it, at any depth.
    func groupAndDescendants(_ id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id], added = true
        while added {
            added = false
            for group in groups where !result.contains(group.id) && group.parent.map(result.contains) == true {
                result.insert(group.id)
                added = true
            }
        }
        return result
    }

    // MARK: Visibility

    /// The group is hidden, or sits inside a hidden group.
    func isGroupHidden(_ id: UUID?) -> Bool {
        guard let id, !groups.isEmpty else { return false }
        var current: UUID? = id, steps = 0
        while let group = self.group(current), steps <= Self.maximumGroupDepth {
            if group.isHidden { return true }
            current = group.parent
            steps += 1
        }
        return false
    }

    /// Hidden itself, or by a group it is in.
    func isHidden(_ body: SolidBody) -> Bool { body.isHidden || isGroupHidden(body.group) }
    func isHidden(_ sketch: Sketch) -> Bool { sketch.isHidden || isGroupHidden(sketch.group) }
    func isHidden(_ plane: ConstructionPlane) -> Bool { plane.isHidden || isGroupHidden(plane.group) }
    func isHidden(body id: UUID) -> Bool { bodies.first { $0.id == id }.map(isHidden) ?? true }
    func isHidden(sketch id: UUID) -> Bool { sketch(id).map(isHidden) ?? true }
    func isHidden(plane id: UUID) -> Bool { constructionPlanes.first { $0.id == id }.map(isHidden) ?? true }

    /// What the canvas can see: these exist and are not hidden by themselves or a group.
    func isShown(body id: UUID) -> Bool { !isHidden(body: id) }
    func isShown(sketch id: UUID) -> Bool { !isHidden(sketch: id) }
    func isShown(plane id: UUID) -> Bool { !isHidden(plane: id) }

    // MARK: Membership

    /// The group a member is in (nil at the top of the tree).
    func group(of member: GroupMember) -> UUID? {
        switch member {
        case .body(let id): bodies.first { $0.id == id }?.group
        case .sketch(let id): sketch(id)?.group
        case .plane(let id): constructionPlanes.first { $0.id == id }?.group
        case .group(let id): group(id)?.parent
        }
    }

    /// What sits directly in a group (nil: the top of the tree): groups, then solids, planes, and sketches.
    func members(of id: UUID?) -> [GroupMember] {
        groups.filter { $0.parent == id }.map { .group($0.id) } + bodies.filter { $0.group == id }.map { .body($0.id) } +
            constructionPlanes.filter { $0.group == id }.map { .plane($0.id) } + sketches.filter { $0.group == id }.map { .sketch($0.id) }
    }

    /// Solids, sketches, and planes in a group or any group inside it.
    func contents(of id: UUID) -> (bodies: [UUID], sketches: [UUID], planes: [UUID]) {
        let all = groupAndDescendants(id)
        return (bodies.filter { $0.group.map(all.contains) == true }.map(\.id),
                sketches.filter { $0.group.map(all.contains) == true }.map(\.id),
                constructionPlanes.filter { $0.group.map(all.contains) == true }.map(\.id))
    }

    /// The members moved into `target` (nil: out to the top of the tree). Nil when the target is
    /// missing, a member is missing, or a group would end up inside itself.
    func moving(_ members: [GroupMember], into target: UUID?) -> Workspace? {
        if let target, group(target) == nil { return nil }
        var result = self
        for member in members {
            switch member {
            case .body(let id):
                guard let i = result.bodies.firstIndex(where: { $0.id == id }) else { return nil }
                result.bodies[i].group = target
            case .sketch(let id):
                guard let i = result.sketches.firstIndex(where: { $0.id == id }) else { return nil }
                result.sketches[i].group = target
            case .plane(let id):
                guard let i = result.constructionPlanes.firstIndex(where: { $0.id == id }) else { return nil }
                result.constructionPlanes[i].group = target
            case .group(let id):
                guard let i = result.groups.firstIndex(where: { $0.id == id }) else { return nil }
                if let target, result.groupAndDescendants(id).contains(target) { return nil }
                result.groups[i].parent = target
            }
        }
        return result.groupsAreValid ? result : nil
    }

    /// A new group in `parent` holding `members` (which may be none). Returns its id.
    func addingGroup(in parent: UUID? = nil, containing members: [GroupMember] = [], name: String? = nil) -> (workspace: Workspace, group: UUID)? {
        guard groups.count < Self.maximumGroups, parent.map({ group($0) != nil }) ?? true else { return nil }
        var result = self
        let group = ItemGroup(name: name.flatMap(ItemNames.cleaned), parent: parent)
        result.groups.append(group)
        guard let moved = result.moving(members, into: group.id) else { return nil }
        return (moved, group.id)
    }

    /// The group removed and its contents moved up into its parent, keeping their own eyes. A
    /// hidden group's contents are hidden one by one, so nothing reappears.
    func ungrouping(_ id: UUID) -> Workspace? {
        guard let removed = group(id) else { return nil }
        var result = self
        let hide = removed.isHidden && !isGroupHidden(removed.parent)
        for i in result.bodies.indices where result.bodies[i].group == id {
            result.bodies[i].group = removed.parent
            if hide { result.bodies[i].hidden = true }
        }
        for i in result.sketches.indices where result.sketches[i].group == id {
            result.sketches[i].group = removed.parent
            if hide { result.sketches[i].hidden = true }
        }
        for i in result.constructionPlanes.indices where result.constructionPlanes[i].group == id {
            result.constructionPlanes[i].group = removed.parent
            if hide { result.constructionPlanes[i].hidden = true }
        }
        for i in result.groups.indices where result.groups[i].parent == id {
            result.groups[i].parent = removed.parent
            if hide { result.groups[i].hidden = true }
        }
        result.groups.removeAll { $0.id == id }
        return result.groupsAreValid ? result : nil
    }

    /// The group, the groups inside it, and every solid, sketch, and plane in them, deleted.
    func deletingGroup(_ id: UUID) -> Workspace? {
        guard group(id) != nil else { return nil }
        let all = groupAndDescendants(id)
        let doomed = contents(of: id)
        var result = self
        result.bodies.removeAll { doomed.bodies.contains($0.id) }
        result.shapes.removeAll { $0.sketch.map(doomed.sketches.contains) == true }
        result.sketches.removeAll { doomed.sketches.contains($0.id) }
        result.constructionPlanes.removeAll { doomed.planes.contains($0.id) }
        result.groups.removeAll { all.contains($0.id) }
        result.pruneImportedShapes()
        return result.isValid ? result : nil
    }

    func settingGroup(_ id: UUID, hidden: Bool) -> Workspace? {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return nil }
        var result = self
        result.groups[index].hidden = hidden ? true : nil
        return result
    }

    func renaming(group id: UUID, to name: String) -> Workspace? {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return nil }
        var result = self
        result.groups[index].name = ItemNames.cleaned(name)
        return result
    }

    // MARK: Several at once

    /// The members that are not inside another of them: an item in a picked group goes along with
    /// the group, so moving or grouping keeps it where it is inside that group.
    func outermost(_ members: Set<GroupMember>) -> [GroupMember] {
        let picked = Set(members.compactMap { if case .group(let id) = $0 { id } else { nil } })
        func insidePicked(_ group: UUID?) -> Bool {
            guard let group else { return false }
            return picked.contains(group) || (ancestors(of: group) ?? []).contains(where: picked.contains)
        }
        // In tree order: groups, then solids, planes, and sketches, each as listed.
        let ordered = groups.map { GroupMember.group($0.id) } + bodies.map { .body($0.id) } +
            constructionPlanes.map { .plane($0.id) } + sketches.map { .sketch($0.id) }
        return ordered.filter { members.contains($0) && !insidePicked(group(of: $0)) }
    }

    /// The group several members share, or nil when they sit in different places.
    func commonGroup(of members: [GroupMember]) -> UUID? {
        let places = Set(members.map { group(of: $0) })
        return places.count == 1 ? places.first! : nil
    }

    /// Shows or hides each member: an item by its own eye, a group with everything in it.
    func setting(_ members: [GroupMember], hidden: Bool) -> Workspace {
        var result = self
        let flag: Bool? = hidden ? true : nil
        for member in members {
            switch member {
            case .body(let id): if let i = result.bodies.firstIndex(where: { $0.id == id }) { result.bodies[i].hidden = flag }
            case .sketch(let id): if let i = result.sketches.firstIndex(where: { $0.id == id }) { result.sketches[i].hidden = flag }
            case .plane(let id): if let i = result.constructionPlanes.firstIndex(where: { $0.id == id }) { result.constructionPlanes[i].hidden = flag }
            case .group(let id): if let i = result.groups.firstIndex(where: { $0.id == id }) { result.groups[i].hidden = flag }
            }
        }
        return result
    }

    /// The members deleted: solids, sketches (with their shapes), planes, and groups with everything in them.
    func deleting(_ members: [GroupMember]) -> Workspace? {
        var result = self
        for member in outermost(Set(members)) {
            switch member {
            case .body(let id): result.bodies.removeAll { $0.id == id }
            case .sketch(let id):
                result.shapes.removeAll { $0.sketch == id }
                result.sketches.removeAll { $0.id == id }
            case .plane(let id): result.constructionPlanes.removeAll { $0.id == id }
            case .group(let id):
                guard let next = result.deletingGroup(id) else { return nil }
                result = next
            }
        }
        result.pruneImportedShapes()
        return result.isValid ? result : nil
    }

    /// "Group 01 › Group 02": where a group sits, for menus that list every group.
    func groupPath(_ id: UUID) -> String {
        let names = groupNames
        return ((ancestors(of: id) ?? []).reversed() + [id]).map { names[$0] ?? "Group" }.joined(separator: " › ")
    }

    /// Group references a copy cannot keep (its group is not in this workspace) dropped.
    mutating func dropMissingGroups() {
        let ids = Set(groups.map(\.id))
        for i in bodies.indices where bodies[i].group.map(ids.contains) == false { bodies[i].group = nil }
        for i in sketches.indices where sketches[i].group.map(ids.contains) == false { sketches[i].group = nil }
        for i in constructionPlanes.indices where constructionPlanes[i].group.map(ids.contains) == false { constructionPlanes[i].group = nil }
    }
}
