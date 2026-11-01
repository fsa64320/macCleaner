import Foundation

enum FileSystem {
    private static let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]

    /// Taille réelle sur disque. Ne suit pas les liens symboliques.
    static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(sizeKeys), options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            if ScanProgress.shouldStop { break }
            let childValues = try? child.resourceValues(forKeys: sizeKeys)
            total += Int64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// `nil` si le dossier existe mais reste illisible, `[]` s'il n'existe pas.
    static func children(of url: URL) -> [URL]? {
        guard entryExists(url) else { return [] }
        return try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(sizeKeys), options: []
        ).filter { $0.lastPathComponent != ".DS_Store" }
    }

    static func append(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Vrai aussi pour un lien symbolique cassé, contrairement à `fileExists`.
    static func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
