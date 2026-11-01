import Foundation

/// Fichiers cloud déjà présents sur ce Mac. Aucune connexion : macOS gère les comptes synchronisés.
public struct CloudLocalScanner: Sendable {
    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .ubiquitousItemDownloadingStatusKey]
    private let env: ScanEnvironment
    private let minimumSize: Int64
    private let limit: Int
    private let isDownloaded: @Sendable (URL) -> Bool

    public init(
        environment: ScanEnvironment, minimumSize: Int64 = 10_000_000, limit: Int = 300,
        isDownloaded: @escaping @Sendable (URL) -> Bool = CloudLocalScanner.hasLocalCopy
    ) {
        env = environment
        self.minimumSize = minimumSize
        self.limit = limit
        self.isDownloaded = isDownloaded
    }

    public static let hasLocalCopy: @Sendable (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus == .current
    }

    public func scan() -> ScanResult {
        var collector = Collector()
        var accounts = collector.children(of: env.library.appendingPathComponent("CloudStorage"))
            .filter(FileSystem.isDirectory).map { (Self.title(of: $0.lastPathComponent), $0) }
        let iCloud = env.library.appendingPathComponent("Mobile Documents")
        if FileSystem.entryExists(iCloud) { accounts.append(("iCloud Drive", iCloud)) }
        let categories = accounts.map { title, root in
            ScanCategory(id: "cloud-\(root.lastPathComponent)", title: title, summary: "Le fichier reste dans le cloud et se retélécharge à l'ouverture.", items: items(in: root))
        }
        return ScanResult(categories: categories, inaccessible: collector.denied.sorted())
    }

    private func items(in root: URL) -> [ScanItem] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(Self.keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return [] }
        var found: [ScanItem] = []
        for case let url as URL in walker {
            if ScanProgress.shouldStop { break }
            ScanProgress.current?.update(url.deletingLastPathComponent().path)
            guard let values = try? url.resourceValues(forKeys: Self.keys), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            guard size >= minimumSize, isDownloaded(url) else { continue }
            found.append(ScanItem(url: url, detail: url.deletingLastPathComponent().path, size: size, removal: .evictLocalCopy))
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }

    static func title(of folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let names = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box"]
        let name = names[parts[0]] ?? parts[0]
        return parts.count > 1 ? "\(name) · \(parts[1])" : name
    }
}
