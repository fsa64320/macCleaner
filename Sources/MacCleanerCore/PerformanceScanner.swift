import Foundation

public struct PerformanceScanner: Sendable {
    private let env: ScanEnvironment

    public init(environment: ScanEnvironment) { env = environment }

    public func scan() -> ScanResult {
        var collector = Collector()
        let user = collector.children(of: env.library.appendingPathComponent("LaunchAgents"))
            .filter { $0.pathExtension == "plist" }.map { agentItem($0, locked: false) }
        let system = env.systemLaunchDirectories.flatMap { collector.children(of: $0) }
            .filter { $0.pathExtension == "plist" }.map { agentItem($0, locked: true) }
        return ScanResult(
            categories: [
                ScanCategory(id: "user-agents", title: "Agents utilisateur", summary: "Lancés à l'ouverture de session.", items: user),
                ScanCategory(id: "system-agents", title: "Agents système tiers", summary: "Consultation seule, ils exigent les droits administrateur.", items: system),
            ],
            inaccessible: collector.denied.sorted()
        )
    }

    private func agentItem(_ url: URL, locked: Bool) -> ScanItem {
        let plist = (try? Data(contentsOf: url)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let label = plist?["Label"] as? String
        let program = (plist?["Program"] as? String) ?? (plist?["ProgramArguments"] as? [String])?.first
        let isBroken = plist == nil || program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? true
        return ScanItem(
            url: url, name: label ?? url.deletingPathExtension().lastPathComponent,
            detail: isBroken ? "Cassé : programme introuvable" : (program ?? ""),
            size: FileSystem.allocatedSize(of: url), removal: .launchAgent,
            launchLabel: label, locked: locked
        )
    }
}

public enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case flushDNS, freeRAM, reindexSpotlight, thinSnapshots

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flushDNS: "Vider le cache DNS"
        case .freeRAM: "Libérer la mémoire inactive"
        case .reindexSpotlight: "Réindexer Spotlight"
        case .thinSnapshots: "Réduire les instantanés Time Machine"
        }
    }

    public var detail: String {
        switch self {
        case .flushDNS: "Utile quand un site reste inaccessible après un changement de réseau."
        case .freeRAM: "Effet ponctuel : macOS gère déjà sa mémoire. Les apps peuvent ralentir un instant."
        case .reindexSpotlight: "Reconstruit l'index. La recherche reste incomplète pendant l'opération."
        case .thinSnapshots: "Demande à macOS de récupérer jusqu'à 10 Go. Des points de restauration locaux peuvent disparaître."
        }
    }

    var command: String {
        switch self {
        case .flushDNS: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .freeRAM: "/usr/sbin/purge"
        case .reindexSpotlight: "/usr/bin/mdutil -E /"
        case .thinSnapshots: "/usr/bin/tmutil thinlocalsnapshots / 10000000000 4"
        }
    }

    /// macOS affiche sa propre demande de mot de passe : macCleaner ne le voit jamais.
    public func run() throws -> String {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MaintenanceTask", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}
