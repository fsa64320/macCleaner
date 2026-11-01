import Foundation

public struct DevToolsScanner: Sendable {
    private struct Artifact {
        let manifests: [String]
        let detail: String
    }

    private struct Cache {
        let path: String
        let name: String
        let selected: Bool
    }

    private static let artifacts = [
        "node_modules": Artifact(manifests: ["package.json"], detail: "npm install"),
        "target": Artifact(manifests: ["Cargo.toml"], detail: "cargo build"),
        ".build": Artifact(manifests: ["Package.swift"], detail: "swift build"),
        ".venv": Artifact(manifests: ["pyproject.toml", "requirements.txt"], detail: "environnement Python à recréer"),
        "venv": Artifact(manifests: ["pyproject.toml", "requirements.txt"], detail: "environnement Python à recréer"),
    ]
    private static let skippedFolders: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures"]
    private static let caches = [
        Cache(path: "Library/Caches/Homebrew", name: "Homebrew", selected: true),
        Cache(path: ".npm/_cacache", name: "npm", selected: true),
        Cache(path: "Library/Caches/Yarn", name: "Yarn", selected: true),
        Cache(path: "Library/pnpm/store", name: "pnpm", selected: false),
        Cache(path: "Library/Caches/pip", name: "pip", selected: true),
        Cache(path: ".cache/pip", name: "pip", selected: true),
        Cache(path: ".cache/uv", name: "uv", selected: true),
        Cache(path: "Library/Caches/CocoaPods", name: "CocoaPods", selected: true),
        Cache(path: "Library/Caches/go-build", name: "Go (compilation)", selected: true),
        Cache(path: ".cargo/registry/cache", name: "Cargo (archives)", selected: false),
        Cache(path: ".cargo/registry/src", name: "Cargo (sources)", selected: false),
        Cache(path: ".gradle/caches", name: "Gradle", selected: false),
        Cache(path: ".gradle/wrapper/dists", name: "Gradle (distributions)", selected: false),
        Cache(path: ".m2/repository", name: "Maven", selected: false),
    ]

    private let env: ScanEnvironment
    private let minimumAge: TimeInterval
    private let docker: @Sendable ([String]) -> Docker.Output?

    public init(
        environment: ScanEnvironment, minimumAge: TimeInterval = 30 * 86_400,
        docker: @escaping @Sendable ([String]) -> Docker.Output? = Docker.run
    ) {
        env = environment
        self.minimumAge = minimumAge
        self.docker = docker
    }

    public func scan() -> ScanResult {
        ScanResult(categories: [projects(), packageCaches(), dockerImages()])
    }

    private func projects() -> ScanCategory {
        ScanProgress.current?.update("Recherche des projets")
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let walker = FileManager.default.enumerator(
            at: env.home, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }
        )
        var items: [ScanItem] = []
        while !ScanProgress.shouldStop, let url = walker?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if (walker?.level ?? 0) > 8 || Self.skippedFolders.contains(name) {
                walker?.skipDescendants()
                continue
            }
            if let artifact = Self.artifacts[name], hasManifest(artifact, url.deletingLastPathComponent()) {
                walker?.skipDescendants()
                ScanProgress.current?.update(url.path)
                if let item = staleItem(url, artifact) { items.append(item) }
            } else if name == "node_modules" || name.hasPrefix(".") {
                walker?.skipDescendants()
            }
        }
        return ScanCategory(
            id: "dev-projects", title: "Projets inactifs",
            summary: "Dossiers recréables de projets sans modification depuis \(Int(minimumAge / 86_400)) jours.", items: items
        )
    }

    private func hasManifest(_ artifact: Artifact, _ project: URL) -> Bool {
        artifact.manifests.contains { FileSystem.entryExists(project.appendingPathComponent($0)) }
    }

    private func staleItem(_ url: URL, _ artifact: Artifact) -> ScanItem? {
        let project = url.deletingLastPathComponent()
        guard let modified = lastActivity(in: project, ignoring: url.lastPathComponent) else { return nil }
        let age = Date().timeIntervalSince(modified)
        guard age >= minimumAge else { return nil }
        return ScanItem(
            url: url, name: "\(project.lastPathComponent)/\(url.lastPathComponent)",
            detail: "Inactif depuis \(Int(age / 86_400)) jours · \(artifact.detail) · \(project.path)",
            size: FileSystem.allocatedSize(of: url)
        )
    }

    /// `.git` change à chaque fetch : il ne dit rien du travail sur le projet.
    private func lastActivity(in project: URL, ignoring artifact: String) -> Date? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries
            .filter { ![artifact, ".git", ".DS_Store"].contains($0.lastPathComponent) }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }

    private func packageCaches() -> ScanCategory {
        let items = Self.caches.compactMap { cache -> ScanItem? in
            if ScanProgress.shouldStop { return nil }
            let url = env.home.appendingPathComponent(cache.path)
            guard FileSystem.entryExists(url) else { return nil }
            ScanProgress.current?.update(url.path)
            return ScanItem(
                url: url, name: cache.name, detail: "Retéléchargé au besoin · \(cache.path)",
                size: FileSystem.allocatedSize(of: url), selectedByDefault: cache.selected
            )
        }
        return ScanCategory(id: "dev-caches", title: "Caches de paquets", summary: "Prochaine installation plus lente, sans perte de données.", items: items.filter { $0.size > 0 })
    }

    private func dockerImages() -> ScanCategory {
        let summary = "Suppression définitive. L'espace revient d'abord au disque virtuel de Docker."
        guard !ScanProgress.shouldStop, docker(["version", "--format", "{{.Client.Version}}"]) != nil else {
            return ScanCategory(id: "dev-docker", title: "Images Docker", items: [])
        }
        ScanProgress.current?.update("Interrogation de Docker")
        guard let output = docker(["system", "df", "-v", "--format", "{{json .}}"]), output.status == 0 else {
            let item = ScanItem(
                url: URL(fileURLWithPath: "/docker/indisponible"), name: "Docker n'est pas démarré",
                detail: "Lancez Docker pour analyser ses images", size: 0, locked: true
            )
            return ScanCategory(id: "dev-docker", title: "Images Docker", summary: summary, items: [item])
        }
        return ScanCategory(id: "dev-docker", title: "Images Docker", summary: summary, items: Docker.unusedImages(from: output.data))
    }

}

public enum Docker {
    public struct Output: Sendable {
        public let data: Data
        public let status: Int32

        public init(data: Data, status: Int32) {
            self.data = data
            self.status = status
        }
    }

    private static let timeout: TimeInterval = 20

    private static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/docker", "/usr/local/bin/docker", "\(home)/.docker/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ].first(where: FileManager.default.isExecutableFile)
    }

    /// Borné dans le temps : un démon arrêté peut laisser le client en attente.
    public static let run: @Sendable ([String]) -> Output? = { arguments in
        guard let executable else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return Output(data: data, status: process.terminationStatus)
    }

    static func unusedImages(from data: Data) -> [ScanItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["Images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            // Un nombre de conteneurs illisible n'est pas zéro : l'image n'est pas proposée.
            guard let identifier = image["ID"] as? String, isValid(identifier: identifier),
                  containerCount(image["Containers"]) == 0 else { return nil }
            let repository = image["Repository"] as? String ?? "<none>"
            let tag = image["Tag"] as? String ?? "<none>"
            let name = repository == "<none>" ? "Image sans nom \(identifier.prefix(19))" : "\(repository):\(tag)"
            return ScanItem(
                url: URL(fileURLWithPath: "/docker/images/\(identifier)"), name: name,
                detail: "Aucun conteneur ne l'utilise · \(image["CreatedSince"] as? String ?? "")",
                size: parseSize(image["Size"] as? String ?? ""), removal: .dockerImage, launchLabel: identifier
            )
        }
    }

    private static func containerCount(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }

    static func isValid(identifier: String) -> Bool {
        identifier.range(of: "^(sha256:)?[0-9a-f]{12,64}$", options: .regularExpression) != nil
    }

    static func parseSize(_ text: String) -> Int64 {
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            return Int64((Double(text.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    public static func removeImage(_ identifier: String) throws {
        guard isValid(identifier: identifier) else {
            throw NSError(domain: "Docker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Identifiant d'image invalide."])
        }
        guard let output = run(["image", "rm", identifier]), output.status == 0 else {
            throw NSError(domain: "Docker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Docker a refusé de retirer cette image."])
        }
    }
}
