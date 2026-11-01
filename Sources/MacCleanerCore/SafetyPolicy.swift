import Foundation

public enum SafetyError: LocalizedError, Equatable {
    case outsideAllowedRoots(String)
    case protectedPath(String)
    case permanentOutsideTrash(String)
    case notCloudFile(String)

    public var errorDescription: String? {
        switch self {
        case .outsideAllowedRoots(let path): "Chemin hors des zones autorisées : \(path)"
        case .protectedPath(let path): "Chemin protégé : \(path)"
        case .permanentOutsideTrash(let path): "Suppression définitive refusée hors corbeille : \(path)"
        case .notCloudFile(let path): "Ce fichier n'est pas synchronisé : \(path)"
        }
    }
}

/// Dernier contrôle avant toute suppression, indépendant des scanners.
public struct SafetyPolicy: Sendable {
    private let home: String
    private let volumesRoot: String
    private let applicationRoots: [String]
    private let protectedExact: Set<String>
    private let protectedTrees: [String]

    public init(environment: ScanEnvironment) {
        home = Self.resolved(environment.home)
        volumesRoot = Self.resolved(environment.volumesRoot)
        applicationRoots = environment.applicationDirectories.map(Self.resolved)
        let home = self.home
        protectedExact = Set(
            ["", ".Trash", "Library", "Library/Caches", "Library/Logs", "Library/Preferences",
             "Library/Application Support", "Library/Containers", "Library/LaunchAgents",
             "Library/Group Containers", "Library/Application Scripts", "Library/WebKit", "Library/HTTPStorages",
             "Library/Saved Application State",
             "Applications", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"]
                .map { $0.isEmpty ? home : "\(home)/\($0)" }
        )
        protectedTrees = [".ssh", ".gnupg", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { "\(home)/\($0)" }
    }

    public func validate(_ url: URL, removal: Removal) throws {
        let path = Self.resolved(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
        if url.path.split(separator: "/").contains("..") { throw SafetyError.protectedPath(url.path) }
        if removal == .evictLocalCopy {
            let isCloud = ["\(home)/Library/CloudStorage/", "\(home)/Library/Mobile Documents/"].contains { path.hasPrefix($0) }
            guard isCloud else { throw SafetyError.notCloudFile(path) }
            return
        }
        if protectedExact.contains(path) || applicationRoots.contains(path) { throw SafetyError.protectedPath(path) }
        if protectedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw SafetyError.protectedPath(path)
        }
        if removal == .permanent {
            guard isInsideTrash(path) else { throw SafetyError.permanentOutsideTrash(path) }
            return
        }
        if path.hasPrefix(home + "/") { return }
        let isApplication = path.hasSuffix(".app") && applicationRoots.contains { path.hasPrefix($0 + "/") }
        guard isApplication else { throw SafetyError.outsideAllowedRoots(path) }
    }

    private func isInsideTrash(_ path: String) -> Bool {
        if path.hasPrefix("\(home)/.Trash/") { return true }
        guard path.hasPrefix(volumesRoot + "/") else { return false }
        let parts = path.dropFirst(volumesRoot.count + 1).split(separator: "/")
        return parts.count >= 4 && parts[1] == ".Trashes"
    }

    private static func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
