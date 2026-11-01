import Foundation

public protocol FileRemoving: Sendable {
    @discardableResult func moveToTrash(_ url: URL) throws -> URL?
    func deletePermanently(_ url: URL) throws
    func unloadLaunchAgent(label: String) throws
    func evictLocalCopy(_ url: URL) throws
    func removeDockerImage(_ identifier: String) throws
    func uninstallCommandLineTool(_ identifier: String, arguments: [String]) throws
}

public struct SystemFileRemover: FileRemoving {
    public init() {}

    @discardableResult public func moveToTrash(_ url: URL) throws -> URL? {
        var location: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &location)
        return location as URL?
    }

    public func deletePermanently(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func evictLocalCopy(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    public func removeDockerImage(_ identifier: String) throws {
        try Docker.removeImage(identifier)
    }

    public func uninstallCommandLineTool(_ identifier: String, arguments: [String]) throws {
        try CommandLineTools.uninstall(identifier: identifier, arguments: arguments)
    }

    public func unloadLaunchAgent(label: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // Un agent déjà arrêté renvoie une erreur : son fichier reste à retirer.
    }
}

public struct CleanupFailure: Identifiable, Sendable {
    public var id: String { item.id }
    public let item: ScanItem
    public let reason: String
}

public struct CleanupReport: Sendable {
    public var removed: [ScanItem] = []
    public var skipped: [ScanItem] = []
    public var failures: [CleanupFailure] = []
    public var cancelledCount = 0

    public init() {}

    public var trashedSize: Int64 { removed.filter { $0.removal == .moveToTrash || $0.removal == .launchAgent }.reduce(0) { $0 + $1.size } }
    public var evictedSize: Int64 { removed.filter { $0.removal == .evictLocalCopy }.reduce(0) { $0 + $1.size } }
    public var permanentSize: Int64 { removed.filter { $0.removal == .permanent || $0.removal == .dockerImage || $0.removal == .commandLineTool }.reduce(0) { $0 + $1.size } }
}

public struct CleanupRunner: Sendable {
    private let remover: any FileRemoving
    private let policy: SafetyPolicy
    private let exclusions: Exclusions
    private let logURL: URL?
    private let history: CleanupHistory?
    private let module: String

    public init(
        remover: any FileRemoving = SystemFileRemover(), environment: ScanEnvironment,
        exclusions: Exclusions = Exclusions(), logURL: URL? = nil,
        history: CleanupHistory? = nil, module: String = ""
    ) {
        self.remover = remover
        policy = SafetyPolicy(environment: environment)
        self.exclusions = exclusions
        self.logURL = logURL
        self.history = history
        self.module = module
    }

    public func run(_ items: [ScanItem]) -> CleanupReport {
        var report = CleanupReport()
        for (index, item) in items.enumerated() {
            if ScanProgress.shouldStop {
                report.cancelledCount = items.count - index
                break
            }
            ScanProgress.current?.update(item.name, fraction: Double(index) / Double(items.count))
            guard !item.locked, !([item.url] + item.companions + item.dependencyPaths).contains(where: exclusions.covers) else { report.skipped.append(item); continue }
            if item.removal == .dockerImage || item.removal == .commandLineTool {
                remove(byCommand: item, into: &report)
                continue
            }
            // Un parent déjà retiré emporte ses enfants sélectionnés.
            guard FileSystem.entryExists(item.url) else { report.skipped.append(item); continue }
            do {
                try policy.validate(item.url, removal: item.removal)
                try item.companions.forEach { try policy.validate($0, removal: item.removal) }
                switch item.removal {
                case .moveToTrash:
                    try remover.moveToTrash(item.url)
                case .permanent:
                    try remover.deletePermanently(item.url)
                case .evictLocalCopy:
                    try remover.evictLocalCopy(item.url)
                case .dockerImage, .commandLineTool:
                    break
                case .launchAgent:
                    if let label = item.launchLabel { try remover.unloadLaunchAgent(label: label) }
                    try remover.moveToTrash(item.url)
                }
                try item.companions.filter(FileSystem.entryExists).forEach { try remover.moveToTrash($0) }
                report.removed.append(item)
            } catch {
                report.failures.append(CleanupFailure(item: item, reason: error.localizedDescription))
            }
        }
        writeLog(report)
        recordHistory(report)
        return report
    }

    /// Docker et les outils en ligne de commande partent par une commande, sans passer par un fichier.
    private func remove(byCommand item: ScanItem, into report: inout CleanupReport) {
        do {
            if item.removal == .commandLineTool {
                try remover.uninstallCommandLineTool(item.launchLabel ?? "", arguments: item.removalArguments)
            } else {
                try remover.removeDockerImage(item.launchLabel ?? "")
            }
            report.removed.append(item)
        } catch {
            report.failures.append(CleanupFailure(item: item, reason: error.localizedDescription))
        }
    }

    private func recordHistory(_ report: CleanupReport) {
        guard let history, !report.removed.isEmpty || !report.failures.isEmpty else { return }
        let reinstall = report.removed.compactMap(\.reinstallCommand)
        try? history.append(HistoryEntry(
            date: Date(), module: module, removedCount: report.removed.count,
            trashedBytes: report.trashedSize, permanentBytes: report.permanentSize,
            evictedBytes: report.evictedSize,
            failureCount: report.failures.count, cancelledCount: report.cancelledCount,
            paths: report.removed.flatMap { [$0.url.path] + $0.dependencyPaths.map(\.path) },
            reinstallCommands: reinstall.isEmpty ? nil : reinstall
        ))
    }

    private func writeLog(_ report: CleanupReport) {
        guard let logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = report.removed.flatMap { item in
            ["\(stamp) OK \(item.removal.rawValue) \(item.url.path)"]
                + item.dependencyPaths.map { "\(stamp) OK \(item.removal.rawValue) \($0.path) (dépendance de \(item.name))" }
        }
        // Une raison sur plusieurs lignes imiterait d'autres entrées du journal.
        lines += report.failures.map {
            "\(stamp) ECHEC \($0.item.url.path) : \($0.reason.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " "))"
        }
        guard !lines.isEmpty else { return }
        try? FileSystem.append(Data((lines.joined(separator: "\n") + "\n").utf8), to: logURL)
    }
}
