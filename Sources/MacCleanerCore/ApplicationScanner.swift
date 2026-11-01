import Foundation

public struct InstalledApp: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String
}

public struct ApplicationScanner: Sendable {
    private let env: ScanEnvironment
    private let isRunning: @Sendable (String) -> Bool

    public init(environment: ScanEnvironment, isRunning: @escaping @Sendable (String) -> Bool = { _ in false }) {
        env = environment
        self.isRunning = isRunning
    }

    public func installedApps(in directories: [URL]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for directory in directories {
            let walker = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            )
            while !ScanProgress.shouldStop, let url = walker?.nextObject() as? URL {
                if (walker?.level ?? 0) > 3 { walker?.skipDescendants(); continue }
                guard url.pathExtension == "app", let app = readApp(url) else { continue }
                apps.append(app)
            }
        }
        return apps
    }

    /// Une catégorie par application : son bundle et les fichiers qui lui sont liés.
    public func scanUninstaller() -> ScanResult {
        let selfID = Bundle.main.bundleIdentifier
        let apps = installedApps(in: env.applicationDirectories).filter {
            !$0.bundleID.hasPrefix("com.apple.") && $0.bundleID != selfID
        }
        var categories: [ScanCategory] = []
        for (index, app) in apps.enumerated() {
            if ScanProgress.shouldStop { break }
            ScanProgress.current?.update(app.name, fraction: Double(index) / Double(apps.count))
            let running = isRunning(app.bundleID)
            var items = [ScanItem(
                url: app.url, name: app.name,
                detail: running ? "Application ouverte · à quitter avant retrait" : "Application",
                size: FileSystem.allocatedSize(of: app.url)
            )]
            items += relatedFiles(of: app).map {
                ScanItem(url: $0, detail: "Fichier lié", size: FileSystem.allocatedSize(of: $0))
            }
            categories.append(ScanCategory(id: "app-\(app.url.path)", title: app.name, summary: app.bundleID, items: items))
        }
        return ScanResult(categories: categories.sorted { $0.totalSize > $1.totalSize })
    }

    public func relatedFiles(of app: InstalledApp) -> [URL] {
        let library = env.library
        var candidates: [URL] = []
        for folder in ["Application Support", "Caches", "Logs"] {
            let base = library.appendingPathComponent(folder)
            candidates.append(base.appendingPathComponent(app.bundleID))
            candidates.append(base.appendingPathComponent(app.name))
        }
        candidates += [
            library.appendingPathComponent("Containers/\(app.bundleID)"),
            library.appendingPathComponent("HTTPStorages/\(app.bundleID)"),
            library.appendingPathComponent("WebKit/\(app.bundleID)"),
            library.appendingPathComponent("Cookies/\(app.bundleID).binarycookies"),
            library.appendingPathComponent("Preferences/\(app.bundleID).plist"),
            library.appendingPathComponent("Saved Application State/\(app.bundleID).savedState"),
        ]
        var seen = Set<String>()
        return candidates.filter { FileSystem.entryExists($0) && seen.insert($0.path).inserted }
    }

    /// Fichiers nommés d'après un bundle ID dont aucun éditeur n'est encore installé.
    public func scanLeftovers() -> ScanResult {
        let installed = installedApps(in: env.applicationDirectories + env.systemApplicationDirectories)
        let vendors = Set(installed.map { Self.vendor(of: $0.bundleID) })
        var collector = Collector()
        var items: [ScanItem] = []
        for folder in ["Application Support", "Caches", "Containers", "Preferences", "Saved Application State", "HTTPStorages"] {
            for url in collector.children(of: env.library.appendingPathComponent(folder)) {
                if ScanProgress.shouldStop { break }
                guard let bundleID = Self.bundleID(fromFileName: url.lastPathComponent),
                      !bundleID.hasPrefix("com.apple."), !vendors.contains(Self.vendor(of: bundleID)) else { continue }
                items.append(ScanItem(url: url, detail: "\(folder) · aucune app installée de cet éditeur", size: FileSystem.allocatedSize(of: url)))
            }
        }
        let installers = collector.children(of: env.home.appendingPathComponent("Downloads"))
            .filter { ["dmg", "pkg"].contains($0.pathExtension.lowercased()) }
            .map { ScanItem(url: $0, detail: "Fichier d'installation", size: FileSystem.allocatedSize(of: $0)) }
        return ScanResult(
            categories: [
                ScanCategory(id: "leftovers", title: "Restes d'applications", summary: "À vérifier : un outil en ligne de commande peut aussi les utiliser.", items: items.filter { $0.size > 0 }),
                ScanCategory(id: "installers", title: "Fichiers d'installation", summary: "DMG et PKG dans Téléchargements.", items: installers),
            ],
            inaccessible: collector.denied.sorted()
        )
    }

    static func bundleID(fromFileName name: String) -> String? {
        var value = name
        for suffix in [".savedState", ".plist", ".binarycookies"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        let parts = value.split(separator: ".")
        guard parts.count >= 3, ["com", "org", "net", "io", "co", "app", "dev"].contains(parts[0].lowercased()) else { return nil }
        return value
    }

    static func vendor(of bundleID: String) -> String {
        bundleID.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    private func readApp(_ url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(url: url, name: name, bundleID: bundleID)
    }
}
