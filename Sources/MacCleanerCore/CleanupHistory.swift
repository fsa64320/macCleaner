import Foundation

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)-\(module)" }
    public let date: Date
    public let module: String
    public let removedCount: Int
    public let trashedBytes: Int64
    public let permanentBytes: Int64
    public var evictedBytes: Int64?
    public let failureCount: Int
    public let cancelledCount: Int
    public let paths: [String]
    /// Commandes pour réinstaller les outils retirés ; absent des anciennes lignes.
    public var reinstallCommands: [String]?
}

/// Un objet JSON par ligne : une ligne abîmée n'emporte pas le reste de l'historique.
public struct CleanupHistory: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func append(_ entry: HistoryEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)
        try FileSystem.append(data, to: fileURL)
    }

    public func recordRemote(module: String, count: Int, bytes: Int64, failures: Int) throws {
        guard count > 0 || failures > 0 else { return }
        try append(HistoryEntry(
            date: Date(), module: module, removedCount: count, trashedBytes: bytes,
            permanentBytes: 0, evictedBytes: nil, failureCount: failures, cancelledCount: 0, paths: []
        ))
    }

    /// Du plus récent au plus ancien.
    public func load() -> (entries: [HistoryEntry], unreadableLines: Int) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], 0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [HistoryEntry] = []
        var unreadable = 0
        for line in data.split(separator: 0x0A) {
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) {
                entries.append(entry)
            } else {
                unreadable += 1
            }
        }
        return (entries.reversed(), unreadable)
    }
}
