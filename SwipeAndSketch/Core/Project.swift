import Foundation

/// Portable editing data. Render meshes, selection, camera, and undo history are session state.
struct Project: Codable, Equatable, Sendable {
    static let formatIdentifier = "noventix.SwipeAndSketch.project"
    var format = Self.formatIdentifier
    /// The format version. Version 1 holds everything the app makes: sketches (lines, rectangles,
    /// circles, arcs, slots, and projected curves) on world, face, and construction planes; solids
    /// with their ordered cuts, joins, merges, subtracts, splits, shells, holes, revolves, finishes,
    /// and face extrusions; imported STEP shapes; and hidden items. A later version that a reader
    /// does not know is refused, never partly read.
    var schemaVersion = Self.currentSchemaVersion
    /// 2 since November 8, 2026: lean files, which leave out a circle's outline when it is exactly
    /// the circle's 128 points and a step's profile when it is its solid's own (`LeanOutline`,
    /// `StepProfile`). Version 1 wrote both out; it still reads, and is written as 2 when saved.
    static let currentSchemaVersion = 2
    static let readableSchemaVersions = 1...2
    var id: UUID
    var createdAtMilliseconds: Int64
    var modifiedAtMilliseconds: Int64
    var units = "millimeter"
    var coordinateSystem = "right-handed-z-up"
    var workspace: Workspace
    /// A small PNG picture of the model for the document browser's thumbnails (October 21, 2026;
    /// ProjectPreview.swift). Omitted until the app first draws one; never needed to open the file.
    var preview: Data?

    init(workspace: Workspace = Workspace(), id: UUID = UUID(), date: Date = Date()) {
        self.id = id
        createdAtMilliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        modifiedAtMilliseconds = createdAtMilliseconds
        self.workspace = workspace
    }

    mutating func update(_ workspace: Workspace, date: Date = Date()) {
        guard self.workspace != workspace else { return }
        self.workspace = workspace
        modifiedAtMilliseconds = max(createdAtMilliseconds, Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    }

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, id, createdAtMilliseconds, modifiedAtMilliseconds, units, coordinateSystem, workspace, preview
    }

    /// The envelope is checked before any geometry is decoded, so another format or a later version
    /// is refused, never partly read. Checking it with a decode of its own parsed the whole file
    /// twice on every open (November 8, 2026).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard format == Self.formatIdentifier, Self.readableSchemaVersions.contains(schemaVersion) else { throw ProjectError.unsupportedVersion }
        units = try container.decode(String.self, forKey: .units)
        coordinateSystem = try container.decode(String.self, forKey: .coordinateSystem)
        guard units == "millimeter", coordinateSystem == "right-handed-z-up" else { throw ProjectError.unsupportedUnits }
        id = try container.decode(UUID.self, forKey: .id)
        createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
        modifiedAtMilliseconds = try container.decode(Int64.self, forKey: .modifiedAtMilliseconds)
        workspace = try container.decode(Workspace.self, forKey: .workspace)
        preview = try container.decodeIfPresent(Data.self, forKey: .preview)
    }

    func copyForNewFile() -> Project {
        var copy = Project(workspace: workspace)
        copy.preview = preview
        return copy
    }
}

enum ProjectError: LocalizedError {
    case unsupportedVersion, invalidModel, unsupportedUnits, tooLarge, alreadyExists
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This project uses a file format this version of Swipe & Sketch cannot open."
        case .invalidModel: "The project contains invalid or incomplete model data."
        case .unsupportedUnits: "The project's units or coordinate system are not supported by this version of Swipe & Sketch."
        case .tooLarge: "This project is too large for this version of Swipe & Sketch."
        case .alreadyExists: "A file already exists at that location. The existing file has been preserved."
        }
    }
}

enum ProjectCodec {
    /// Imported shapes make files larger than drawn geometry ever does.
    static let maximumFileBytes = 120 * 1024 * 1024

    /// The budget for the polygon checks, counted as they run: the squared point count of every
    /// outline and hole of every solid, including the solids that merges, subtracts, and splits
    /// carry, except a circle's outline, which is checked point by point (on the circle, in order)
    /// and counts its points. It was 20 million until November 8, 2026, when splitting one plate of
    /// a Raspberry Pi case (8 solids, 17.7 million, checked in about 40 ms) took it over and the
    /// project could no longer be saved; that day circles still counted 128² each, which was 78% of
    /// that case's count. 100 million keeps the checks to a fraction of a second; files that large
    /// usually reach `maximumFileBytes` first.
    static let maximumPolygonWork = 100_000_000

    /// The polygon-check work of `profile` (see `maximumPolygonWork`); nil when an outline has more
    /// points than a profile may.
    static func polygonWork(of profile: SketchProfile) -> Int? {
        var work = 0
        for (index, count) in ([profile.outline.count] + (profile.holes ?? []).map(\.outline.count)).enumerated() {
            guard count <= 2_048 else { return nil }
            work += index == 0 && profile.circle != nil ? count : count * count
        }
        return work
    }

    /// The limits on how much a project holds, which bound the work of opening and checking it.
    /// Linear in the stored points, so cheap enough to check before every edit.
    static func checkSize(_ workspace: Workspace) throws {
        guard workspace.shapes.count <= 10_000, workspace.bodies.count <= 1_000 else { throw ProjectError.tooLarge }
        var polygonWork = 0
        func limit(_ body: SolidBody) throws {
            guard body.cuts.count <= ExtrusionCut.maximumPerBody else { throw ProjectError.tooLarge }
            for profile in [body.profile] + body.cuts.map(\.profile) {
                guard let work = Self.polygonWork(of: profile) else { throw ProjectError.tooLarge }
                polygonWork += work
                guard polygonWork <= maximumPolygonWork else { throw ProjectError.tooLarge }
            }
            for nested in body.cuts.compactMap(\.nestedSolid) { try limit(nested) }
        }
        for body in workspace.bodies { try limit(body) }
    }

    /// `known`, when given, is a workspace already validated (the document's last saved one): its
    /// solids that `project` holds unchanged are not checked again.
    static func validate(_ project: Project, changedFrom known: Workspace? = nil) throws {
        let performance = Performance.begin("Validate project")
        defer { Performance.end(performance) }
        guard project.format == Project.formatIdentifier, Project.readableSchemaVersions.contains(project.schemaVersion) else { throw ProjectError.unsupportedVersion }
        guard project.units == "millimeter", project.coordinateSystem == "right-handed-z-up" else { throw ProjectError.unsupportedUnits }
        let workspace = project.workspace
        // Bound the polygon checks before running them.
        try checkSize(workspace)
        for body in workspace.bodies {
            if let circle = body.profile.circle {
                let tolerance = max(1e-7, circle.radius * 1e-10)
                guard body.profile.outline.allSatisfy({ abs($0.distance(to: circle.center) - circle.radius) <= tolerance }) else { throw ProjectError.invalidModel }
            }
        }
        guard (project.preview?.count ?? 0) <= ProjectPreview.maximumBytes else { throw ProjectError.tooLarge }
        guard project.createdAtMilliseconds >= 0, project.modifiedAtMilliseconds >= project.createdAtMilliseconds,
              known.map(workspace.isValid(changedFrom:)) ?? workspace.isValid else { throw ProjectError.invalidModel }
    }

    /// `knownValid`: a workspace already validated, as `validate`'s `changedFrom`. An open
    /// document's model was validated when it was read or edited, so its autosaves pass it and
    /// skip checking every solid again on each save (November 8, 2026); the file's limits and the
    /// rest of `validate` still run.
    static func encode(_ project: Project, knownValid: Workspace? = nil) throws -> Data {
        let performance = Performance.begin("Encode project")
        defer { Performance.end(performance) }
        // Always written in the current (lean) form, so a version 1 file is saved as version 2.
        var project = project
        project.schemaVersion = Project.currentSchemaVersion
        try validate(project, changedFrom: knownValid)
        let encoder = JSONEncoder()
        // Compact since November 8, 2026: indentation made an 8-solid case 34 MB instead of 9.5 MB,
        // all written (and uploaded to iCloud) on every autosave. Keys stay sorted, which
        // `ProjectPreview.png(in:)` relies on.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(project)
        guard data.count <= maximumFileBytes else { throw ProjectError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Project {
        let performance = Performance.begin("Decode project")
        defer { Performance.end(performance) }
        guard data.count <= maximumFileBytes else { throw ProjectError.tooLarge }
        // The envelope is checked before the geometry (`Project.init(from:)`).
        let project = try JSONDecoder().decode(Project.self, from: data)
        try validate(project)
        return project
    }

    /// Used only for new local/staged files. Existing documents are written by UIDocument.
    static func create(_ project: Project, at url: URL) throws {
        let data = try encode(project)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        guard !manager.fileExists(atPath: url.path) else { throw ProjectError.alreadyExists }
        // A same-volume move refuses to replace an existing file, including a racing writer.
        try manager.moveItem(at: temporary, to: url)
    }
}
