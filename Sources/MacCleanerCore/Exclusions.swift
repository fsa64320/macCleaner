import Foundation

/// Chemins que macCleaner ne doit jamais proposer ni retirer.
public struct Exclusions: Codable, Equatable, Sendable {
    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths
    }

    public static func load(from url: URL) throws -> Exclusions {
        guard FileManager.default.fileExists(atPath: url.path) else { return Exclusions() }
        return try JSONDecoder().decode(Exclusions.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public mutating func add(_ url: URL) {
        let path = Self.normalized(url)
        if !paths.contains(path) { paths.append(path) }
        paths.sort()
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    /// Vrai aussi pour un dossier parent : le retirer emporterait le chemin exclu.
    public func covers(_ url: URL) -> Bool {
        let path = Self.normalized(url)
        return paths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }

    public func applied(to result: ScanResult) -> ScanResult {
        let categories = result.categories.map { category in
            ScanCategory(
                id: category.id, title: category.title, summary: category.summary,
                items: category.items.filter { item in !([item.url] + item.companions).contains(where: covers) }
            )
        }
        return ScanResult(categories: categories, inaccessible: result.inaccessible)
    }

    private static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
