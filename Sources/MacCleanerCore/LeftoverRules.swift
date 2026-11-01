import Foundation

/// Règles propres à macCleaner, fondées sur les conventions de nommage de macOS.
struct LeftoverRules {
    enum Verdict: Equatable {
        case keep
        case review
        case leftover
    }

    /// Dossiers à nom libre créés par le système ou par des outils courants.
    private static let knownFolders: Set<String> = [
        "addressbook", "applicationsupport", "cloudkit", "coredata", "coresimulator", "crashreporter",
        "diagnosticreports", "dock", "familycircle", "fileprovider", "geoservices", "homebrew", "icdd",
        "knowledge", "maccleaner", "metadata", "mobilesync", "networkserviceproxy", "privacypreservingmeasurement",
        "quicklook", "siriservice", "siritts", "sirittsservice", "spotlight", "syncservices", "tcc", "virtualization",
    ]

    private let bundleIDs: Set<String>
    private let vendors: Set<String>
    private let names: Set<String>
    private let commands: Set<String>

    init(installedIDs: [String], appNames: [String], commands: [String]) {
        bundleIDs = Set(installedIDs.map { $0.lowercased() })
        vendors = Set(bundleIDs.map(Self.vendor))
        names = Set((appNames + vendors.compactMap { $0.split(separator: ".").last.map(String.init) }).map(Self.normalized)).subtracting([""])
        self.commands = Set(commands.map { $0.lowercased() })
    }

    func verdict(fileName: String, allowsFreeName: Bool) -> Verdict {
        guard !fileName.hasPrefix(".") else { return .keep }
        if let identifier = Self.identifier(fromFileName: fileName) { return verdict(identifier: identifier) }
        return allowsFreeName ? verdict(freeName: fileName) : .keep
    }

    private func verdict(identifier: String) -> Verdict {
        // `is.workflow` est l'ancien identifiant de Raccourcis, une app d'Apple.
        if identifier.hasPrefix("com.apple.") || identifier.contains(".apple.") || identifier.hasPrefix("is.workflow.") { return .keep }
        if bundleIDs.contains(where: { identifier == $0 || identifier.hasPrefix($0 + ".") || $0.hasPrefix(identifier + ".") }) { return .keep }
        if vendors.contains(Self.vendor(identifier)) { return .review }
        let parts = identifier.split(separator: ".").dropFirst().map(String.init)
        return parts.contains(where: commands.contains) ? .review : .leftover
    }

    private func verdict(freeName: String) -> Verdict {
        let name = Self.normalized(freeName)
        guard name.count >= 3, !Self.knownFolders.contains(name), !commands.contains(freeName.lowercased()) else { return .keep }
        let matchesApp = names.contains { $0 == name || ($0.count >= 4 && name.contains($0)) || (name.count >= 4 && $0.contains(name)) }
        return matchesApp ? .keep : .review
    }

    /// Accepte `ru.editeur.app`, un préfixe d'équipe et les groupes d'apps.
    static func identifier(fromFileName name: String) -> String? {
        var value = name
        for suffix in [".savedState", ".plist", ".binarycookies"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        if value.range(of: "^[A-Z0-9]{10}\\.", options: .regularExpression) != nil { value = String(value.dropFirst(11)) }
        value = value.lowercased()
        for prefix in ["systemgroup.", "group."] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        let parts = value.split(separator: ".")
        guard parts.count >= 3, parts[0].range(of: "^[a-z]{2,6}$", options: .regularExpression) != nil, parts[1].count >= 2 else { return nil }
        return value
    }

    private static func vendor(_ identifier: String) -> String {
        identifier.split(separator: ".").prefix(2).joined(separator: ".")
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
