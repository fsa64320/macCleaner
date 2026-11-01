import Foundation

public struct InstalledApp: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let buildVersion: String
    public let feedURL: URL?
}

public struct ApplicationScanner: Sendable {
    private let env: ScanEnvironment
    private let isRunning: @Sendable (String) -> Bool
    private let commandDirectories: [URL]

    public init(
        environment: ScanEnvironment, isRunning: @escaping @Sendable (String) -> Bool = { _ in false },
        commandDirectories: [URL]? = nil
    ) {
        env = environment
        self.isRunning = isRunning
        self.commandDirectories = commandDirectories ?? (["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"].map { URL(fileURLWithPath: $0) }
            + [environment.home.appendingPathComponent(".local/bin")])
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

    /// Restes sûrs d'un côté, éléments douteux de l'autre : ces derniers ne sont jamais présentés comme des restes.
    public func scanLeftovers() -> ScanResult {
        let installed = installedApps(in: env.applicationDirectories + env.systemApplicationDirectories)
        let rules = LeftoverRules(
            installedIDs: installed.map(\.bundleID) + [Bundle.main.bundleIdentifier].compactMap { $0 },
            appNames: installed.map(\.name) + installed.map { $0.url.deletingPathExtension().lastPathComponent },
            commands: commandDirectories.flatMap { (FileSystem.children(of: $0) ?? []).map(\.lastPathComponent) }
        )
        let freeNameFolders: Set<String> = ["Application Support", "Caches", "Logs"]
        // Le nom d'un groupe ne dit pas quelles apps s'en servent.
        let sharedFolders: Set<String> = ["Group Containers", "Application Scripts"]
        var collector = Collector()
        var items: [ScanItem] = []
        var doubtful: [ScanItem] = []
        for folder in ["Application Support", "Caches", "Containers", "Group Containers", "Preferences", "Saved Application State",
                       "HTTPStorages", "WebKit", "Application Scripts", "Logs"] {
            for url in collector.children(of: env.library.appendingPathComponent(folder)) {
                if ScanProgress.shouldStop { break }
                let allowsFreeName = freeNameFolders.contains(folder) && FileSystem.isDirectory(url)
                switch rules.verdict(fileName: url.lastPathComponent, allowsFreeName: allowsFreeName) {
                case .keep:
                    continue
                case .leftover where sharedFolders.contains(folder):
                    doubtful.append(ScanItem(url: url, detail: "\(folder) · partagé, l'app qui s'en sert n'est pas connue", size: FileSystem.allocatedSize(of: url)))
                case .leftover:
                    items.append(ScanItem(url: url, detail: "\(folder) · aucune app installée de cet éditeur", size: FileSystem.allocatedSize(of: url)))
                case .review:
                    doubtful.append(ScanItem(url: url, detail: "\(folder) · peut encore servir", size: FileSystem.allocatedSize(of: url)))
                }
            }
        }
        let installers = collector.children(of: env.home.appendingPathComponent("Downloads"))
            .filter { ["dmg", "pkg"].contains($0.pathExtension.lowercased()) }
            .map { ScanItem(url: $0, detail: "Fichier d'installation", size: FileSystem.allocatedSize(of: $0)) }
        return ScanResult(
            categories: [
                ScanCategory(id: "leftovers", title: "Restes d'applications", summary: "Aucune app installée de cet éditeur. Un outil en ligne de commande peut aussi les utiliser.", items: items),
                ScanCategory(id: "installers", title: "Fichiers d'installation", summary: "DMG et PKG dans Téléchargements.", items: installers),
                ScanCategory(id: "leftovers-review", title: "À vérifier", summary: "Même éditeur qu'une app installée, ou nom sans rapport connu. À retirer seulement si vous les reconnaissez.", items: doubtful),
            ],
            inaccessible: collector.denied.sorted()
        )
    }

    private func readApp(_ url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let build = (plist["CFBundleVersion"] as? String) ?? ""
        return InstalledApp(
            url: url, name: name, bundleID: bundleID,
            version: (plist["CFBundleShortVersionString"] as? String) ?? build, buildVersion: build,
            feedURL: (plist["SUFeedURL"] as? String).flatMap(URL.init(string:))
        )
    }
}
