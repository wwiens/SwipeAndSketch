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
    static let currentSchemaVersion = 1
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

    static func validate(_ project: Project) throws {
        guard project.format == Project.formatIdentifier, project.schemaVersion == Project.currentSchemaVersion else { throw ProjectError.unsupportedVersion }
        guard project.units == "millimeter", project.coordinateSystem == "right-handed-z-up" else { throw ProjectError.unsupportedUnits }
        let workspace = project.workspace
        guard workspace.shapes.count <= 10_000, workspace.bodies.count <= 1_000 else { throw ProjectError.tooLarge }
        // Bound the (quadratic) polygon checks before running them: every outline and hole of every
        // solid, including the solids that merges and subtracts carry, counts toward one budget.
        var polygonWork = 0
        func limit(_ body: SolidBody) throws {
            guard body.cuts.count <= ExtrusionCut.maximumPerBody else { throw ProjectError.tooLarge }
            for profile in [body.profile] + body.cuts.map(\.profile) {
                for count in [profile.outline.count] + (profile.holes ?? []).map(\.outline.count) {
                    guard count <= 2_048 else { throw ProjectError.tooLarge }
                    polygonWork += count * count
                    guard polygonWork <= 20_000_000 else { throw ProjectError.tooLarge }
                }
            }
            for nested in body.cuts.compactMap(\.nestedSolid) { try limit(nested) }
        }
        for body in workspace.bodies {
            try limit(body)
            if let circle = body.profile.circle {
                let tolerance = max(1e-7, circle.radius * 1e-10)
                guard body.profile.outline.allSatisfy({ abs($0.distance(to: circle.center) - circle.radius) <= tolerance }) else { throw ProjectError.invalidModel }
            }
        }
        guard (project.preview?.count ?? 0) <= ProjectPreview.maximumBytes else { throw ProjectError.tooLarge }
        guard project.createdAtMilliseconds >= 0, project.modifiedAtMilliseconds >= project.createdAtMilliseconds,
              workspace.isValid else { throw ProjectError.invalidModel }
    }

    static func encode(_ project: Project) throws -> Data {
        try validate(project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        guard data.count <= maximumFileBytes else { throw ProjectError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Project {
        guard data.count <= maximumFileBytes else { throw ProjectError.tooLarge }
        // Inspect the envelope before decoding geometry: another format or a later version is refused.
        struct Header: Decodable { var format: String; var schemaVersion: Int; var units: String; var coordinateSystem: String }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.format == Project.formatIdentifier, header.schemaVersion == Project.currentSchemaVersion else { throw ProjectError.unsupportedVersion }
        guard header.units == "millimeter", header.coordinateSystem == "right-handed-z-up" else { throw ProjectError.unsupportedUnits }
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
