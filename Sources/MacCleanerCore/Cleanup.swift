import Foundation

public protocol FileRemoving: Sendable {
    func moveToTrash(_ url: URL) throws
    func deletePermanently(_ url: URL) throws
    func unloadLaunchAgent(label: String) throws
}

public struct SystemFileRemover: FileRemoving {
    public init() {}

    public func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public func deletePermanently(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
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

    public init() {}

    public var freedSize: Int64 { removed.reduce(0) { $0 + $1.size } }
}

public struct CleanupRunner: Sendable {
    private let remover: any FileRemoving
    private let policy: SafetyPolicy
    private let logURL: URL?

    public init(remover: any FileRemoving = SystemFileRemover(), environment: ScanEnvironment, logURL: URL? = nil) {
        self.remover = remover
        policy = SafetyPolicy(environment: environment)
        self.logURL = logURL
    }

    public func run(_ items: [ScanItem], progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> CleanupReport {
        var report = CleanupReport()
        for (index, item) in items.enumerated() {
            progress(index, items.count)
            guard !item.locked else { report.skipped.append(item); continue }
            // Un parent déjà retiré emporte ses enfants sélectionnés.
            guard FileSystem.entryExists(item.url) else { report.skipped.append(item); continue }
            do {
                try policy.validate(item.url, removal: item.removal)
                switch item.removal {
                case .moveToTrash:
                    try remover.moveToTrash(item.url)
                case .permanent:
                    try remover.deletePermanently(item.url)
                case .launchAgent:
                    if let label = item.launchLabel { try remover.unloadLaunchAgent(label: label) }
                    try remover.moveToTrash(item.url)
                }
                report.removed.append(item)
            } catch {
                report.failures.append(CleanupFailure(item: item, reason: error.localizedDescription))
            }
        }
        progress(items.count, items.count)
        writeLog(report)
        return report
    }

    private func writeLog(_ report: CleanupReport) {
        guard let logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = report.removed.map { "\(stamp) OK \($0.removal.rawValue) \($0.url.path)" }
        lines += report.failures.map { "\(stamp) ECHEC \($0.item.url.path) : \($0.reason)" }
        guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
