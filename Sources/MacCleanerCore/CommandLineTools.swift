import Foundation

/// Retrait des outils en ligne de commande installés via Homebrew, npm ou uv.
public enum CommandLineTools {
    public enum Source: String, Sendable { case brew, cask, npm, uv }

    public struct Identifier: Equatable, Sendable {
        public let source: Source
        public let name: String

        /// Forme « source:nom », par exemple `npm:@a/b`.
        public var encoded: String { "\(source.rawValue):\(name)" }

        public init(source: Source, name: String) {
            self.source = source
            self.name = name
        }

        /// Coupe au premier « : » : un nom peut lui-même en contenir.
        public init?(encoded: String) {
            guard let separator = encoded.firstIndex(of: ":"),
                  let source = Source(rawValue: String(encoded[..<separator])) else { return nil }
            self.init(source: source, name: String(encoded[encoded.index(after: separator)...]))
        }
    }

    public typealias Runner = @Sendable (_ tool: Source, _ arguments: [String], _ timeout: TimeInterval) -> Docker.Output?

    /// Lecture : stderr est écarté pour garder une sortie JSON propre.
    public static let run: Runner = { tool, arguments, timeout in
        execute(tool, arguments, timeout: timeout, mergeErrors: false)
    }

    private static let uninstallTimeout: TimeInterval = 300

    private static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
    }

    private static func executable(for tool: Source) -> String? {
        let directories = tool == .uv ? searchDirectories : Array(searchDirectories.prefix(2))
        let name = tool == .cask ? "brew" : tool.rawValue
        return directories.map { "\($0)/\(name)" }.first(where: FileManager.default.isExecutableFile)
    }

    /// Exécute l'outil sans shell. Avec `mergeErrors`, stderr rejoint stdout pour remonter le message d'échec.
    static func execute(
        _ tool: Source, _ arguments: [String], timeout: TimeInterval, mergeErrors: Bool
    ) -> Docker.Output? {
        guard let executable = executable(for: tool) else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["PATH"] = (searchDirectories + ["/usr/bin", "/bin"]).joined(separator: ":")
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = mergeErrors ? pipe : FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Le tube est lu jusqu'à la fin avant d'attendre la sortie du processus.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return Docker.Output(data: data, status: process.terminationStatus)
    }

    static func isValid(name: String) -> Bool {
        !name.contains("..")
            && name.range(
                of: "^@?[A-Za-z0-9][A-Za-z0-9@._+-]*(/[A-Za-z0-9][A-Za-z0-9@._+-]*)*$", options: .regularExpression
            ) != nil
    }

    static func uninstallArguments(_ id: Identifier, extra: [String]) throws -> [String] {
        guard isValid(name: id.name), extra.allSatisfy(isValid(name:)) else {
            throw failure("Nom d'outil invalide.")
        }
        let prefix: [String]
        switch id.source {
        case .brew: prefix = ["uninstall"]
        case .cask: prefix = ["uninstall", "--cask"]
        case .npm: prefix = ["uninstall", "-g"]
        case .uv: prefix = ["tool", "uninstall"]
        }
        return prefix + ["--", id.name] + extra
    }

    public static func uninstall(identifier: String, arguments: [String]) throws {
        guard let id = Identifier(encoded: identifier) else { throw failure("Identifiant d'outil invalide.") }
        let command = try uninstallArguments(id, extra: arguments)
        guard let output = execute(id.source, command, timeout: uninstallTimeout, mergeErrors: true) else {
            throw failure("Outil introuvable ou impossible à lancer.")
        }
        guard output.status == 0 else {
            throw failure(String(String(decoding: output.data, as: UTF8.self).prefix(500)))
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CommandLineTools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
