import Foundation

public struct MonitorSettings: Codable, Equatable, Sendable {
    public var diskAlertEnabled = false
    public var minimumFreeGB = 20
    public var scheduledScanEnabled = false
    public var scanIntervalHours = 24
    public var junkThresholdMB = 2000
    public var showMenuBar = true
    public var lastDiskAlert: Date?
    public var lastScan: Date?

    public init() {}

    public static func load(from url: URL) -> MonitorSettings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MonitorSettings.self, from: $0) } ?? MonitorSettings()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Décide seulement quand prévenir : la surveillance ne supprime jamais rien.
public enum MonitorPolicy {
    private static let alertInterval: TimeInterval = 86_400

    public static func isDiskLow(_ settings: MonitorSettings, available: Int64) -> Bool {
        settings.diskAlertEnabled && available < Int64(settings.minimumFreeGB) * 1_000_000_000
    }

    public static func shouldAlertDisk(_ settings: MonitorSettings, available: Int64, now: Date) -> Bool {
        guard isDiskLow(settings, available: available) else { return false }
        guard let last = settings.lastDiskAlert else { return true }
        return now.timeIntervalSince(last) >= alertInterval
    }

    public static func shouldScan(_ settings: MonitorSettings, now: Date) -> Bool {
        guard settings.scheduledScanEnabled else { return false }
        guard let last = settings.lastScan else { return true }
        return now.timeIntervalSince(last) >= Double(settings.scanIntervalHours) * 3600
    }

    public static func junkWorthReporting(_ settings: MonitorSettings, result: ScanResult) -> Int64? {
        let size = result.categories.flatMap(\.items).filter(\.selectedByDefault).reduce(0) { $0 + $1.size }
        return size >= Int64(settings.junkThresholdMB) * 1_000_000 ? size : nil
    }
}
