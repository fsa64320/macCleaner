import Foundation

/// Liste les outils installés via Homebrew, npm et uv. Ne modifie rien.
public struct CommandLineToolScanner: Sendable {
    public struct Locations: Sendable {
        public let homebrew: URL   // contient Cellar et Caskroom
        public let npmRoot: URL    // node_modules global
        public let uvTools: URL

        public init(homebrew: URL, npmRoot: URL, uvTools: URL) {
            self.homebrew = homebrew
            self.npmRoot = npmRoot
            self.uvTools = uvTools
        }
    }

    private static let readTimeout: TimeInterval = 60
    private static let lockedNpm: Set<String> = ["npm", "corepack"]

    private let env: ScanEnvironment
    private let run: CommandLineTools.Runner
    private let locations: Locations?
    private let exclusions: Exclusions

    public init(
        environment: ScanEnvironment, run: @escaping CommandLineTools.Runner = CommandLineTools.run,
        locations: Locations? = nil, exclusions: Exclusions = Exclusions()
    ) {
        env = environment
        self.run = run
        self.locations = locations
        self.exclusions = exclusions
    }

    public func scan() -> ScanResult {
        var categories: [ScanCategory] = []
        // npm d'abord : l'alerte de `node` cite les paquets npm.
        ScanProgress.current?.update("Lecture de npm")
        let npm = npmItems()
        if ScanProgress.shouldStop { return ScanResult(categories: []) }
        ScanProgress.current?.update("Lecture de Homebrew")
        let brew = brewItems(npmNames: (npm ?? []).filter { !$0.locked }.map(\.name))
        if ScanProgress.shouldStop { return ScanResult(categories: []) }
        ScanProgress.current?.update("Lecture de uv")
        let uv = uvItems()
        if let brew { categories.append(ScanCategory(id: "cli.brew", title: "Homebrew", summary: "Formules et applications installées à la demande.", items: brew)) }
        if let npm { categories.append(ScanCategory(id: "cli.npm", title: "npm", summary: "Paquets installés globalement.", items: npm)) }
        if let uv { categories.append(ScanCategory(id: "cli.uv", title: "uv", summary: "Outils installés par uv.", items: uv)) }
        return ScanResult(categories: categories)
    }

    // MARK: Homebrew

    private func homebrewRoot() -> URL {
        if let locations { return locations.homebrew }
        let preferred = URL(fileURLWithPath: "/opt/homebrew")
        return FileManager.default.fileExists(atPath: preferred.path) ? preferred : URL(fileURLWithPath: "/usr/local")
    }

    private func brewItems(npmNames: [String]) -> [ScanItem]? {
        guard let output = run(.brew, ["info", "--json=v2", "--installed"], Self.readTimeout), output.status == 0,
              let parsed = CommandLineToolParsers.homebrew(output.data) else { return nil }
        let root = homebrewRoot()
        func cellar(_ name: String) -> URL {
            root.appendingPathComponent("Cellar").appendingPathComponent(CommandLineTools.baseName(name))
        }
        // Une alerte ou une exclusion vaut aussi pour une formule qui ne serait qu'une dépendance.
        let protected = Set(parsed.formulae.filter { formula in
            let base = CommandLineTools.baseName(formula.name)
            return base == "uv" || Self.warning(for: base, npmNames: []) != nil || formula.pinned
                || formula.kegCount > 1 || exclusions.covers(cellar(formula.name))
        }.map(\.name))
        var items: [ScanItem] = []
        for formula in CommandLineToolParsers.topLevel(parsed.formulae) {
            if ScanProgress.shouldStop { return items }
            ScanProgress.current?.update(formula.name)
            let dependencies = CommandLineToolParsers.exclusiveDependencies(
                of: formula.name, in: parsed.formulae, protected: protected
            )
            let folder = cellar(formula.name)
            let dependencyPaths = dependencies.map(cellar)
            // Sans `--force`, brew ne retire que la version active.
            let removed = formula.kegCount > 1 ? folder.appendingPathComponent(formula.version) : folder
            let size = ([removed] + dependencyPaths).reduce(Int64(0)) { $0 + FileSystem.allocatedSize(of: $1) }
            let base = CommandLineTools.baseName(formula.name)
            var detail = formula.version
            if formula.outdated { detail += " · mise à jour disponible" }
            if !dependencies.isEmpty { detail += " · emporte \(dependencies.count) dépendance(s)" }
            if formula.kegCount > 1 { detail += " · les anciennes versions restent installées" }
            if formula.pinned { detail += " · épinglée : lancez d'abord brew unpin" }
            items.append(ScanItem(
                url: folder, name: formula.name, detail: detail, size: size, removal: .commandLineTool,
                launchLabel: CommandLineTools.Identifier(source: .brew, name: formula.name).encoded,
                locked: base == "uv" || formula.pinned, removalArguments: dependencies,
                reinstallCommand: "brew install \(formula.name)",
                dependencyPaths: dependencyPaths, warning: Self.warning(for: base, npmNames: npmNames)
            ))
        }
        for cask in parsed.casks {
            if ScanProgress.shouldStop { return items }
            let folder = root.appendingPathComponent("Caskroom").appendingPathComponent(cask.name)
            items.append(ScanItem(
                url: folder, name: cask.name, detail: Self.detail(cask), size: FileSystem.allocatedSize(of: folder),
                removal: .commandLineTool,
                launchLabel: CommandLineTools.Identifier(source: .cask, name: cask.name).encoded,
                reinstallCommand: "brew install --cask \(cask.name)",
                warning: Self.warning(for: cask.name, npmNames: [])
            ))
        }
        return items
    }

    /// Vaut pour toutes les sources : `rea-agents`, par exemple, peut être un paquet npm.
    static func warning(for base: String, npmNames: [String]) -> String? {
        func alert(_ text: String) -> String { "Attention : \(text)" }
        if base == "node" || base.hasPrefix("node@") {
            let list = npmNames.isEmpty ? "" : " ; utilisé par les paquets npm : \(npmNames.joined(separator: ", "))"
            return alert("environnement d'exécution\(list)")
        }
        if base.hasPrefix("python@") || base.hasPrefix("openjdk") { return alert("environnement d'exécution") }
        if base == "gh" { return alert("outil de ce dépôt") }
        if base == "rea-agents" { return alert("fournit le serveur REA") }
        return nil
    }

    /// Une version inattendue n'entre pas dans la commande : l'outil se réinstalle alors sans version.
    static func safeVersion(_ version: String) -> String? {
        version.range(of: "^[A-Za-z0-9._+-]+\\z", options: .regularExpression) == nil ? nil : version
    }

    private static func detail(_ package: InstalledPackage) -> String {
        package.latest.map { "\(package.version) · mise à jour \($0)" } ?? package.version
    }

    // MARK: npm

    private func npmItems() -> [ScanItem]? {
        // Un statut non nul avec un JSON valide reste accepté : npm ls signale ainsi des dépendances manquantes.
        guard let output = run(.npm, ["ls", "-g", "--depth=0", "--json"], Self.readTimeout),
              let packages = CommandLineToolParsers.npmPackages(output.data),
              let root = npmRoot() else { return nil }
        // `npm outdated` rend 1 quand des paquets sont périmés.
        var latest: [String: String] = [:]
        if let outdated = run(.npm, ["outdated", "-g", "--json"], Self.readTimeout), outdated.status == 0 || outdated.status == 1 {
            latest = CommandLineToolParsers.npmOutdated(outdated.data) ?? [:]
        }
        return packages.compactMap { package in
            if ScanProgress.shouldStop { return nil }
            let folder = root.appendingPathComponent(package.name)
            ScanProgress.current?.update(package.name)
            let locked = Self.lockedNpm.contains(package.name)
            return ScanItem(
                url: folder, name: package.name,
                detail: Self.detail(InstalledPackage(name: package.name, version: package.version, latest: latest[package.name])),
                size: FileSystem.allocatedSize(of: folder), removal: .commandLineTool,
                launchLabel: CommandLineTools.Identifier(source: .npm, name: package.name).encoded, locked: locked,
                reinstallCommand: "npm install -g \(package.name)" + (Self.safeVersion(package.version).map { "@\($0)" } ?? ""),
                warning: locked ? "Attention : fourni avec Node"
                    : Self.warning(for: CommandLineTools.baseName(package.name), npmNames: [])
            )
        }
    }

    private func npmRoot() -> URL? {
        if let locations { return locations.npmRoot }
        return resolvedDirectory(.npm, ["root", "-g"])
    }

    // MARK: uv

    private func uvItems() -> [ScanItem]? {
        guard let output = run(.uv, ["tool", "list", "--show-paths"], Self.readTimeout), output.status == 0,
              let root = uvRoot() else { return nil }
        var latest: [String: String] = [:]
        if let outdated = run(.uv, ["tool", "list", "--outdated"], Self.readTimeout), outdated.status == 0 {
            latest = CommandLineToolParsers.uvOutdated(String(decoding: outdated.data, as: UTF8.self))
        }
        return CommandLineToolParsers.uvTools(String(decoding: output.data, as: UTF8.self)).compactMap { tool in
            if ScanProgress.shouldStop { return nil }
            let folder = root.appendingPathComponent(tool.name)
            ScanProgress.current?.update(tool.name)
            return ScanItem(
                url: folder, name: tool.name,
                detail: Self.detail(InstalledPackage(name: tool.name, version: tool.version, latest: latest[tool.name])),
                size: FileSystem.allocatedSize(of: folder), removal: .commandLineTool,
                launchLabel: CommandLineTools.Identifier(source: .uv, name: tool.name).encoded,
                reinstallCommand: "uv tool install \(tool.name)" + (Self.safeVersion(tool.version).map { "==\($0)" } ?? ""),
                warning: Self.warning(for: tool.name, npmNames: [])
            )
        }
    }

    private func uvRoot() -> URL? {
        if let locations { return locations.uvTools }
        return resolvedDirectory(.uv, ["tool", "dir"])
    }

    private func resolvedDirectory(_ source: CommandLineTools.Source, _ arguments: [String]) -> URL? {
        guard let output = run(source, arguments, Self.readTimeout), output.status == 0 else { return nil }
        let path = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
