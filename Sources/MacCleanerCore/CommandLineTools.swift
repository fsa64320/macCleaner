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
            .map { Docker.Output(data: $0.data, status: $0.status) }
    }

    struct Result: Sendable {
        let data: Data
        let status: Int32
        let timedOut: Bool
    }

    private static let uninstallTimeout: TimeInterval = 300

    private static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
    }

    /// Un cask passe par `brew` : `cask` n'est pas un exécutable.
    static func executableName(for tool: Source) -> String {
        tool == .cask ? "brew" : tool.rawValue
    }

    private static func executable(for tool: Source) -> String? {
        let directories = tool == .uv ? searchDirectories : Array(searchDirectories.prefix(2))
        return directories.map { "\($0)/\(executableName(for: tool))" }.first(where: FileManager.default.isExecutableFile)
    }

    /// Environnement des commandes. `brew uninstall` lance `autoremove` par défaut, ce qui retirerait
    /// tous les orphelins de la machine : `HOMEBREW_NO_AUTOREMOVE` l'en empêche.
    static func commandEnvironment(from base: [String: String], searchDirectories: [String]) -> [String: String] {
        var environment = base
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_AUTOREMOVE"] = "1"
        environment["PATH"] = (searchDirectories + ["/usr/bin", "/bin"]).joined(separator: ":")
        return environment
    }

    /// Exécute l'outil sans shell. Avec `mergeErrors`, stderr rejoint stdout pour remonter le message d'échec.
    static func execute(
        _ tool: Source, _ arguments: [String], timeout: TimeInterval, mergeErrors: Bool
    ) -> Result? {
        guard let executable = executable(for: tool) else { return nil }
        let environment = commandEnvironment(from: ProcessInfo.processInfo.environment, searchDirectories: searchDirectories)
        return launch(
            executable, arguments, environment: environment, timeout: timeout, mergeErrors: mergeErrors
        )
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        func append(_ chunk: Data) { lock.withLock { stored.append(chunk) } }
        var data: Data { lock.withLock { stored } }
    }

    /// Lance le processus avec une échéance ferme : SIGTERM à l'échéance, SIGKILL après `grace`.
    /// La lecture se fait en arrière-plan, donc un enfant qui garde le tube ouvert ne bloque jamais l'appelant.
    static func launch(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
        timeout: TimeInterval, grace: TimeInterval = 5, mergeErrors: Bool
    ) -> Result? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = pipe
        process.standardError = mergeErrors ? pipe : FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()

        let collected = Collected()
        let reachedEnd = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global().async {
            while case let chunk = reader.availableData, !chunk.isEmpty { collected.append(chunk) }
            reachedEnd.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + grace)
            }
        }
        // Un petit-enfant peut garder le tube ouvert après la fin du processus : on n'attend pas plus.
        _ = reachedEnd.wait(timeout: .now() + min(grace, 1))
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(data: collected.data, status: status, timedOut: timedOut)
    }

    static func isValid(name: String) -> Bool {
        !name.contains("..")
            && name.range(
                of: "^@?[A-Za-z0-9][A-Za-z0-9@._+-]*(/[A-Za-z0-9][A-Za-z0-9@._+-]*)*\\z", options: .regularExpression
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

    /// Nom sans le préfixe de tap : c'est celui du dossier dans le Cellar.
    static func baseName(_ name: String) -> String {
        String(name.split(separator: "/").last ?? "")
    }

    /// Commande de retrait. Une formule supplémentaire déjà disparue ferait échouer `brew` après coup :
    /// elle est écartée, après validation de tous les noms. L'outil lui-même reste, et son absence échoue.
    static func uninstallCommand(_ id: Identifier, extra: [String], homebrewPrefix: URL?) throws -> [String] {
        _ = try uninstallArguments(id, extra: extra)
        guard id.source == .brew, let homebrewPrefix else { return try uninstallArguments(id, extra: extra) }
        let cellar = homebrewPrefix.appendingPathComponent("Cellar")
        let present = extra.filter {
            FileManager.default.fileExists(atPath: cellar.appendingPathComponent(baseName($0)).path)
        }
        return try uninstallArguments(id, extra: present)
    }

    private static var homebrewPrefix: URL? {
        executable(for: .brew).map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() }
    }

    public static func uninstall(identifier: String, arguments: [String]) throws {
        guard let id = Identifier(encoded: identifier) else { throw failure("Identifiant d'outil invalide.") }
        let command = try uninstallCommand(id, extra: arguments, homebrewPrefix: homebrewPrefix)
        guard let output = execute(id.source, command, timeout: uninstallTimeout, mergeErrors: true) else {
            throw failure("Outil introuvable ou impossible à lancer.")
        }
        if let message = failureMessage(output) { throw failure(message) }
    }

    /// Message d'échec en français, ou nil si le retrait a réussi.
    static func failureMessage(_ result: Result) -> String? {
        let text = String(String(decoding: result.data, as: UTF8.self).prefix(500))
        if result.timedOut {
            let suffix = text.isEmpty ? "" : " Sortie : \(text)"
            return "Délai dépassé : le retrait a été interrompu et peut être incomplet.\(suffix)"
        }
        guard result.status != 0 else { return nil }
        return text.isEmpty ? "Le retrait a échoué (code de sortie \(result.status)) sans message." : text
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CommandLineTools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
