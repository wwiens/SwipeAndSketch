import Foundation

// Reading a project without opening it for editing (Shortcuts and Siri: export, Send to Slicer,
// the parts list, and the print estimate). A coordinated read, so a save in progress elsewhere is
// never read half-written, and never a write: the file stays exactly as it was, whatever happens.

enum ProjectReader {
    enum Failure: LocalizedError, Equatable {
        /// An iCloud file not on this iPad yet, still missing after waiting.
        case notDownloaded(String)
        /// The file is gone or out of reach.
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded(let name): "“\(name)” is in iCloud Drive but not on this iPad yet. Open it once in Files to download it, then try again."
            case .missing(let name): "“\(name)” could not be found. It may have been moved or deleted."
            }
        }
    }

    /// The project's name: its file's name without the extension.
    static func name(of url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Reads and checks a project file. `downloadWait`: seconds to wait for an iCloud file that is
    /// not downloaded yet. A damaged, too-large, or future-version file throws the codec's error.
    static func read(_ url: URL, downloadWait: TimeInterval = 15) throws -> Project {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try waitUntilDownloaded(url, for: downloadWait)
        var coordinationError: NSError?
        var result: Result<Project, any Error> = .failure(Failure.missing(name(of: url)))
        // Without asking other presenters to save first: the editor's own open project is read from
        // the editor instead, and another device's save in progress is still waited for.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            result = Result {
                if let size = try? readURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ProjectCodec.maximumFileBytes {
                    throw ProjectError.tooLarge
                }
                guard FileManager.default.fileExists(atPath: readURL.path) else { throw Failure.missing(name(of: url)) }
                return try ProjectCodec.decode(Data(contentsOf: readURL))
            }
        }
        if let coordinationError {
            throw coordinationError.code == NSFileReadNoSuchFileError ? Failure.missing(name(of: url)) : coordinationError
        }
        return try result.get()
    }

    /// Asks iCloud for a file that is only a placeholder on this iPad, and waits for it.
    private static func waitUntilDownloaded(_ url: URL, for seconds: TimeInterval) throws {
        func isCurrent() -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                  values.isUbiquitousItem == true else { return true }
            return values.ubiquitousItemDownloadingStatus == .current
        }
        guard !isCurrent() else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if isCurrent() { return }
        }
        throw Failure.notDownloaded(name(of: url))
    }
}

extension Workspace {
    /// The solids an export, Send to Slicer, or parts list takes, with their Model Tree names: the
    /// visible ones (as the Export sheet), or every solid, hidden ones too.
    func printParts(includingHidden: Bool) -> [ModelExport.PrintPart] {
        let names = bodyNames
        return bodies.filter { includingHidden || !isHidden($0) }.map { ModelExport.PrintPart(body: $0, name: names[$0.id] ?? "Solid") }
    }
}

extension ModelExport {
    /// An export's bytes: a print-ready 3MF (named parts placed on the plate, with a picture) or an STL.
    static func file(_ parts: [PrintPart], format: Format, title: String, layout: PrintLayout, thumbnail: Data?) throws -> Data {
        format == .threeMF ? try threeMF(parts, title: title, layout: layout, thumbnail: thumbnail)
            : try data(format, bodies: parts.map(\.body), title: title)
    }

    /// A file name for an export (no slashes or colons).
    static func fileName(_ title: String, format: Format) -> String {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (safe.isEmpty ? "Untitled Project" : safe) + "." + format.rawValue
    }
}
