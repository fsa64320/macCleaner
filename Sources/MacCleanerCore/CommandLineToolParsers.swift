import Foundation

struct HomebrewFormula: Equatable {
    let name: String            // full_name, tap compris
    let version: String
    let onRequest: Bool
    let outdated: Bool
    let dependencies: [String]  // full_name des runtime_dependencies, toutes versions confondues
    let kegCount: Int           // versions installées côte à côte
    let pinned: Bool
}

struct InstalledPackage: Equatable {
    let name: String
    let version: String
    let latest: String?
}

/// Décodage des sorties de brew, npm et uv, sans lancer aucun outil.
enum CommandLineToolParsers {
    /// `brew info --json=v2 --installed` : une formule sans version installée est ignorée.
    static func homebrew(_ data: Data) -> (formulae: [HomebrewFormula], casks: [InstalledPackage])? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formulae = (json["formulae"] as? [[String: Any]] ?? []).compactMap { entry -> HomebrewFormula? in
            guard let name = entry["full_name"] as? String,
                  let kegs = entry["installed"] as? [[String: Any]],
                  let newest = kegs.last else { return nil }
            // `installed` est trié par version croissante : la version active est `linked_keg`, sinon la dernière.
            let linked = entry["linked_keg"] as? String
            let selected = kegs.first { $0["version"] as? String == linked } ?? newest
            var dependencies: [String] = []
            for keg in kegs {
                for dependency in keg["runtime_dependencies"] as? [[String: Any]] ?? [] {
                    if let name = dependency["full_name"] as? String, !dependencies.contains(name) { dependencies.append(name) }
                }
            }
            return HomebrewFormula(
                name: name,
                version: selected["version"] as? String ?? "?",
                // Sans l'information, la formule compte comme demandée : elle ne partira pas en dépendance.
                onRequest: selected["installed_on_request"] as? Bool ?? true,
                outdated: entry["outdated"] as? Bool ?? false,
                dependencies: dependencies,
                kegCount: kegs.count,
                pinned: entry["pinned"] as? Bool ?? false
            )
        }
        let casks = (json["casks"] as? [[String: Any]] ?? []).compactMap { entry -> InstalledPackage? in
            guard let token = entry["token"] as? String else { return nil }
            let latest = entry["version"] as? String
            // `installed` est la version posée (texte), parfois une liste selon la version de brew.
            let installed = (entry["installed"] as? String) ?? (entry["installed"] as? [String])?.first
            let outdated = entry["outdated"] as? Bool ?? false
            return InstalledPackage(name: token, version: installed ?? latest ?? "?", latest: outdated ? latest : nil)
        }
        return (formulae, casks)
    }

    /// Les formules que l'utilisateur a choisies d'installer et qu'aucune autre formule installée ne requiert.
    static func topLevel(_ formulae: [HomebrewFormula]) -> [HomebrewFormula] {
        var required = Set<String>()
        for formula in formulae {
            for dependency in formula.dependencies where dependency != formula.name { required.insert(dependency) }
        }
        return formulae.filter { $0.onRequest && !required.contains($0.name) }
    }

    /// Dépendances de `tool` qui peuvent partir avec lui : ni demandées par l'utilisateur,
    /// ni protégées, ni requises par une formule qui reste installée. Une formule protégée reste,
    /// donc ce qu'elle requiert reste aussi. Un outil à plusieurs versions garde ses anciennes
    /// versions, qui requièrent encore leurs dépendances : rien ne part avec lui.
    static func exclusiveDependencies(
        of tool: String, in formulae: [HomebrewFormula], protected: Set<String>
    ) -> [String] {
        let byName = Dictionary(formulae.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        if byName[tool]?.kegCount ?? 1 > 1 { return [] }
        // Fermeture transitive, limitée aux formules installées.
        var closure = Set<String>()
        var pending = byName[tool]?.dependencies ?? []
        while let next = pending.popLast() {
            guard next != tool, let formula = byName[next], closure.insert(next).inserted else { continue }
            pending.append(contentsOf: formula.dependencies)
        }
        var candidates = closure.filter { byName[$0]?.onRequest == false && !protected.contains($0) }
        var changed = true
        while changed {
            changed = false
            let leaving = candidates.union([tool])
            for candidate in candidates {
                let stillNeeded = formulae.contains { !leaving.contains($0.name) && $0.dependencies.contains(candidate) }
                if stillNeeded { candidates.remove(candidate); changed = true }
            }
        }
        return candidates.sorted()
    }

    /// `npm ls -g --depth=0 --json`.
    static func npmPackages(_ data: Data) -> [InstalledPackage]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dependencies = json["dependencies"] as? [String: [String: Any]] ?? [:]
        return dependencies.map { InstalledPackage(name: $0.key, version: $0.value["version"] as? String ?? "?", latest: nil) }
            .sorted { $0.name < $1.name }
    }

    /// `npm outdated -g --json` : nom du paquet vers sa dernière version.
    static func npmOutdated(_ data: Data) -> [String: String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        return json.compactMapValues { $0["latest"] as? String }
    }

    /// `uv tool list` (avec ou sans `--show-paths`) : les lignes « - exécutable » sont ignorées.
    static func uvTools(_ text: String) -> [InstalledPackage] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> InstalledPackage? in
            guard !line.hasPrefix("-"), !line.hasPrefix(" ") else { return nil }
            let words = line.split(separator: " ")
            guard words.count >= 2, words[1].hasPrefix("v") else { return nil }
            return InstalledPackage(name: String(words[0]), version: String(words[1].dropFirst()), latest: nil)
        }
    }

    /// `uv tool list --outdated` : nom de l'outil vers la version annoncée entre crochets.
    static func uvOutdated(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("-") {
            guard let name = line.split(separator: " ").first,
                  let marker = line.range(of: "[latest: "),
                  let end = line[marker.upperBound...].firstIndex(of: "]") else { continue }
            result[String(name)] = String(line[marker.upperBound..<end])
        }
        return result
    }
}
