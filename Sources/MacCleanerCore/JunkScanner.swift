import Foundation

public struct JunkScanner: Sendable {
    private let env: ScanEnvironment
    private static let sensitiveCaches: Set<String> = ["CloudKit", "FamilyCircle", "Metadata", "GeoServices"]

    public init(environment: ScanEnvironment) { env = environment }

    public func scan() -> ScanResult {
        var collector = Collector()
        let categories = [
            userCaches(&collector), containerCaches(&collector), logs(&collector), developer(&collector),
            brokenPreferences(&collector), trash(&collector), aiJunk(&collector), localModels(&collector),
            mailAttachments(&collector),
        ]
        return ScanResult(categories: categories, inaccessible: collector.denied.sorted())
    }

    public func scanEssentials() -> ScanResult {
        var collector = Collector()
        return ScanResult(
            categories: [userCaches(&collector), containerCaches(&collector), logs(&collector)],
            inaccessible: collector.denied.sorted()
        )
    }

    private func userCaches(_ collector: inout Collector) -> ScanCategory {
        let root = env.library.appendingPathComponent("Caches")
        let items = collector.children(of: root).map { url in
            cacheItem(url, detail: "Régénéré par l'application au besoin")
        }
        return ScanCategory(id: "user-caches", title: "Caches utilisateur", summary: "Fichiers temporaires des applications.", items: items)
    }

    private func containerCaches(_ collector: inout Collector) -> ScanCategory {
        let root = env.library.appendingPathComponent("Containers")
        var items: [ScanItem] = []
        for container in collector.children(of: root) {
            let caches = container.appendingPathComponent("Data/Library/Caches")
            items += collector.children(of: caches).map { url in
                let selected = !container.lastPathComponent.hasPrefix("com.apple.") && isSafeCacheName(url.lastPathComponent)
                return ScanItem(
                    url: url, name: "\(container.lastPathComponent) · \(url.lastPathComponent)",
                    detail: "Cache d'application sandboxée", size: FileSystem.allocatedSize(of: url),
                    selectedByDefault: selected
                )
            }
        }
        return ScanCategory(id: "container-caches", title: "Caches des conteneurs", summary: "Caches des applications en bac à sable.", items: items.filter { $0.size > 0 })
    }

    private func logs(_ collector: inout Collector) -> ScanCategory {
        let root = env.library.appendingPathComponent("Logs")
        let items = collector.children(of: root).map {
            ScanItem(url: $0, detail: "Journal d'application", size: FileSystem.allocatedSize(of: $0), selectedByDefault: true)
        }
        return ScanCategory(id: "user-logs", title: "Journaux", summary: "Journaux et rapports de diagnostic.", items: items.filter { $0.size > 0 })
    }

    private func developer(_ collector: inout Collector) -> ScanCategory {
        let developer = env.library.appendingPathComponent("Developer")
        let rules: [(String, String, Bool)] = [
            ("Xcode/DerivedData", "Données de compilation, recréées au prochain build", true),
            ("Xcode/iOS DeviceSupport", "Symboles d'appareils, recréés à la connexion", false),
            ("Xcode/Archives", "Archives d'apps publiées, à conserver pour symboliquer", false),
            ("CoreSimulator/Caches", "Caches des simulateurs", true),
        ]
        var items: [ScanItem] = []
        for (path, detail, selected) in rules {
            items += collector.children(of: developer.appendingPathComponent(path)).map {
                ScanItem(url: $0, detail: detail, size: FileSystem.allocatedSize(of: $0), selectedByDefault: selected)
            }
        }
        return ScanCategory(id: "developer", title: "Xcode et développement", summary: "Données régénérables des outils de développement.", items: items.filter { $0.size > 0 })
    }

    private func brokenPreferences(_ collector: inout Collector) -> ScanCategory {
        let root = env.library.appendingPathComponent("Preferences")
        let items = collector.children(of: root).filter { $0.pathExtension == "plist" }.compactMap { url -> ScanItem? in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            let isValid = (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil
            return isValid ? nil : ScanItem(url: url, detail: "Fichier de préférences illisible", size: FileSystem.allocatedSize(of: url))
        }
        return ScanCategory(id: "broken-preferences", title: "Préférences cassées", summary: "Fichiers plist corrompus.", items: items)
    }

    private func trash(_ collector: inout Collector) -> ScanCategory {
        var items = collector.children(of: env.userTrash).map {
            ScanItem(url: $0, detail: "Corbeille · suppression définitive", size: FileSystem.allocatedSize(of: $0), removal: .permanent)
        }
        for volume in collector.children(of: env.volumesRoot) {
            let userTrash = volume.appendingPathComponent(".Trashes/\(getuid())")
            guard FileSystem.entryExists(userTrash) else { continue }
            items += collector.children(of: userTrash).map {
                ScanItem(url: $0, detail: "Corbeille de \(volume.lastPathComponent) · suppression définitive", size: FileSystem.allocatedSize(of: $0), removal: .permanent)
            }
        }
        return ScanCategory(id: "trash", title: "Corbeilles", summary: "La suppression y est définitive.", items: items)
    }

    private func aiJunk(_ collector: inout Collector) -> ScanCategory {
        let browserProfiles = [".cache/chrome-devtools-mcp/chrome-profile", ".gemini/antigravity-browser-profile"]
        let browserCaches = ["Default/Cache", "Default/Code Cache", "Default/GPUCache", "Default/Service Worker/CacheStorage", "GraphiteDawnCache", "component_crx_cache"]
        var paths = [".claude/telemetry", ".claude/stats-cache.json", ".codex/cache", ".local/share/opencode/log", "Library/Logs/Claude"]
        paths += browserProfiles.flatMap { profile in browserCaches.map { "\(profile)/\($0)" } }
        let items = paths.compactMap { path -> ScanItem? in
            let url = env.home.appendingPathComponent(path)
            guard FileSystem.entryExists(url) else { return nil }
            return ScanItem(url: url, name: path, detail: "Cache ou journal d'outil IA", size: FileSystem.allocatedSize(of: url), selectedByDefault: true)
        }
        return ScanCategory(id: "ai-junk", title: "Résidus d'outils IA", summary: "Caches et journaux d'agents de code.", items: items.filter { $0.size > 0 })
    }

    private func localModels(_ collector: inout Collector) -> ScanCategory {
        LocalModelScanner(env: env).category(&collector)
    }

    private func mailAttachments(_ collector: inout Collector) -> ScanCategory {
        let root = env.library.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads")
        let items = collector.children(of: root).map {
            ScanItem(url: $0, detail: "Copie locale d'une pièce jointe", size: FileSystem.allocatedSize(of: $0))
        }
        return ScanCategory(id: "mail", title: "Pièces jointes Mail", summary: "Copies téléchargées lors de l'ouverture.", items: items.filter { $0.size > 0 })
    }

    private func cacheItem(_ url: URL, detail: String) -> ScanItem {
        ScanItem(url: url, detail: detail, size: FileSystem.allocatedSize(of: url), selectedByDefault: isSafeCacheName(url.lastPathComponent))
    }

    private func isSafeCacheName(_ name: String) -> Bool {
        !name.hasPrefix("com.apple.") && !Self.sensitiveCaches.contains(name)
    }
}

struct Collector {
    var denied: Set<String> = []

    mutating func children(of url: URL) -> [URL] {
        if ScanProgress.shouldStop { return [] }
        ScanProgress.current?.update(url.path)
        guard let children = FileSystem.children(of: url) else {
            denied.insert(url.path)
            return []
        }
        return children
    }
}
