import Foundation

public enum Removal: String, Sendable {
    case moveToTrash
    case permanent
    case launchAgent
    /// Retire la copie locale ; le fichier reste dans le cloud.
    case evictLocalCopy
    /// Image Docker, identifiée par `launchLabel`. Suppression définitive.
    case dockerImage
    /// Outil en ligne de commande, identifié par `launchLabel`. Retiré par sa commande, pas par fichier.
    case commandLineTool
}

public struct ScanItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let detail: String
    public let size: Int64
    public let selectedByDefault: Bool
    public let removal: Removal
    public let launchLabel: String?
    public let locked: Bool
    /// Fichiers qui partent avec l'élément, comme les blobs d'un modèle Ollama.
    public let companions: [URL]
    /// Arguments passés à la commande de retrait d'un outil en ligne de commande.
    public let removalArguments: [String]
    /// Commande qui réinstalle l'outil, gardée dans l'historique.
    public let reinstallCommand: String?
    /// Dossiers du Cellar des dépendances qui partent avec l'outil.
    public let dependencyPaths: [URL]
    /// Alerte à montrer avant tout retrait. Un élément alerté n'est jamais coché en bloc.
    public let warning: String?

    public init(
        url: URL, name: String? = nil, detail: String = "", size: Int64,
        selectedByDefault: Bool = false, removal: Removal = .moveToTrash,
        launchLabel: String? = nil, locked: Bool = false, companions: [URL] = [],
        removalArguments: [String] = [], reinstallCommand: String? = nil,
        dependencyPaths: [URL] = [], warning: String? = nil
    ) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.detail = detail
        self.size = size
        self.selectedByDefault = selectedByDefault
        self.removal = removal
        self.launchLabel = launchLabel
        self.locked = locked
        self.companions = companions
        self.removalArguments = removalArguments
        self.reinstallCommand = reinstallCommand
        self.dependencyPaths = dependencyPaths
        self.warning = warning
    }
}

public struct ScanCategory: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let items: [ScanItem]

    public init(id: String, title: String, summary: String = "", items: [ScanItem]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.items = items.sorted { $0.size > $1.size }
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Lignes concernées par la case de la catégorie : ni verrouillées, ni alertées.
    public var bulkSelectableItems: [ScanItem] { items.filter { !$0.locked && $0.warning == nil } }
}

public struct ScanResult: Sendable {
    public var categories: [ScanCategory]
    /// Dossiers illisibles, le plus souvent faute d'accès complet au disque.
    public var inaccessible: [String]

    public init(categories: [ScanCategory] = [], inaccessible: [String] = []) {
        self.categories = categories.filter { !$0.items.isEmpty }
        self.inaccessible = inaccessible
    }

    public var totalSize: Int64 { categories.reduce(0) { $0 + $1.totalSize } }

    public static func merged(_ results: [ScanResult]) -> ScanResult {
        ScanResult(
            categories: results.flatMap(\.categories),
            inaccessible: Array(Set(results.flatMap(\.inaccessible))).sorted()
        )
    }
}

public struct ScanEnvironment: Sendable {
    public var home: URL
    public var volumesRoot: URL
    public var applicationDirectories: [URL]
    public var systemApplicationDirectories: [URL]
    public var systemLaunchDirectories: [URL]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes"),
        applicationDirectories: [URL]? = nil,
        systemApplicationDirectories: [URL] = [URL(fileURLWithPath: "/System/Applications")],
        systemLaunchDirectories: [URL] = [
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
        ]
    ) {
        self.home = home
        self.volumesRoot = volumesRoot
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
        ]
        self.systemApplicationDirectories = systemApplicationDirectories
        self.systemLaunchDirectories = systemLaunchDirectories
    }

    public var library: URL { home.appendingPathComponent("Library") }
    public var userTrash: URL { home.appendingPathComponent(".Trash") }
}
