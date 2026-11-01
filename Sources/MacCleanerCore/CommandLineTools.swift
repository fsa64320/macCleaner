import Foundation

/// Retrait des outils en ligne de commande, complété à la tâche suivante.
enum CommandLineTools {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Retrait non disponible." }
    }

    static func uninstall(identifier: String, arguments: [String]) throws {
        throw Unavailable()
    }
}
