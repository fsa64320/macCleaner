import CryptoKit
import Foundation

public struct ClutterScanner: Sendable {
    private let env: ScanEnvironment
    private let largeFileMinimum: Int64
    private let duplicateMinimum: Int64
    private let oldDownloadAge: TimeInterval
    private static let skippedFolders: Set<String> = ["Library", "node_modules", "Pods", "DerivedData", ".build", ".git"]
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentAccessDateKey,
        .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey, .fileResourceIdentifierKey,
    ]

    public init(
        environment: ScanEnvironment, largeFileMinimum: Int64 = 100_000_000,
        duplicateMinimum: Int64 = 1_000_000, oldDownloadAge: TimeInterval = 30 * 86_400
    ) {
        env = environment
        self.largeFileMinimum = largeFileMinimum
        self.duplicateMinimum = duplicateMinimum
        self.oldDownloadAge = oldDownloadAge
    }

    public func scan() -> ScanResult {
        let files = homeFiles()
        var collector = Collector()
        return ScanResult(
            categories: [largeFiles(files), duplicates(files), oldDownloads(&collector)],
            inaccessible: collector.denied.sorted()
        )
    }

    private struct FileEntry {
        let url: URL
        let size: Int64
        let allocated: Int64
        let modified: Date
        let accessed: Date
        let identifier: String
    }

    private func homeFiles() -> [FileEntry] {
        guard let walker = FileManager.default.enumerator(
            at: env.home, includingPropertiesForKeys: Array(Self.keys),
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return [] }
        var files: [FileEntry] = []
        for case let url as URL in walker {
            if ScanProgress.shouldStop { break }
            ScanProgress.current?.update(url.deletingLastPathComponent().path)
            if Self.skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Self.keys), values.isRegularFile == true else { continue }
            // Un fichier resté dans le cloud n'occupe rien et serait téléchargé par le hachage.
            if let status = values.ubiquitousItemDownloadingStatus, status != .current { continue }
            files.append(FileEntry(
                url: url, size: Int64(values.fileSize ?? 0), allocated: Int64(values.totalFileAllocatedSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast,
                accessed: values.contentAccessDate ?? .distantPast,
                identifier: values.fileResourceIdentifier.map { "\($0)" } ?? url.path
            ))
        }
        return files
    }

    private func largeFiles(_ files: [FileEntry]) -> ScanCategory {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        let items = files.filter { $0.allocated >= largeFileMinimum }.map {
            ScanItem(url: $0.url, detail: "Ouvert \(formatter.localizedString(for: $0.accessed, relativeTo: Date())) · \($0.url.deletingLastPathComponent().path)", size: $0.allocated)
        }
        return ScanCategory(id: "large", title: "Fichiers volumineux", summary: "Triés par taille.", items: items)
    }

    private func duplicates(_ files: [FileEntry]) -> ScanCategory {
        let candidates = Dictionary(grouping: files.filter { $0.size >= duplicateMinimum }, by: \.size).values.filter { $0.count > 1 }
        var items: [ScanItem] = []
        for (index, group) in candidates.enumerated() {
            if ScanProgress.shouldStop { break }
            ScanProgress.current?.update("Comparaison des doublons", fraction: Double(index) / Double(candidates.count))
            // Deux chemins vers le même inode ne libèrent rien.
            var seenInodes = Set<String>()
            let distinct = group.filter { seenInodes.insert($0.identifier).inserted }
            guard distinct.count > 1 else { continue }
            let byContent = Dictionary(grouping: distinct.compactMap { entry in Self.hash(entry.url).map { ($0, entry) } }, by: \.0)
            for matches in byContent.values where matches.count > 1 {
                let sorted = matches.map(\.1).sorted { $0.modified < $1.modified }
                let original = sorted[0]
                items += sorted.dropFirst().map {
                    ScanItem(url: $0.url, detail: "Copie de \(original.url.path)", size: $0.allocated)
                }
            }
        }
        return ScanCategory(id: "duplicates", title: "Doublons", summary: "Contenu identique ; le fichier le plus ancien est conservé hors liste.", items: items)
    }

    private func oldDownloads(_ collector: inout Collector) -> ScanCategory {
        let limit = Date().addingTimeInterval(-oldDownloadAge)
        let items = collector.children(of: env.home.appendingPathComponent("Downloads")).compactMap { url -> ScanItem? in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < limit else { return nil }
            return ScanItem(url: url, detail: "Plus de 30 jours", size: FileSystem.allocatedSize(of: url))
        }
        return ScanCategory(id: "downloads", title: "Anciens téléchargements", summary: "Éléments de plus de 30 jours.", items: items)
    }

    static func hash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if ScanProgress.shouldStop { return nil }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
