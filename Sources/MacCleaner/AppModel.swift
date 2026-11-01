import AppKit
import MacCleanerCore
import SwiftUI

enum Module: String, CaseIterable, Identifiable {
    case dashboard, smartCare, cleanup, performance, maintenance, uninstaller, leftovers, clutter, spaceLens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Tableau de bord"
        case .smartCare: "Entretien rapide"
        case .cleanup: "Nettoyage"
        case .performance: "Agents de démarrage"
        case .maintenance: "Maintenance"
        case .uninstaller: "Désinstallation"
        case .leftovers: "Restes d'apps"
        case .clutter: "Encombrement"
        case .spaceLens: "Carte du disque"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: "L'état de votre Mac en un coup d'œil."
        case .smartCare: "Caches et journaux sans risque, en une passe."
        case .cleanup: "Caches, Xcode, corbeilles, résidus d'outils IA et pièces jointes."
        case .performance: "Ce qui se lance en arrière-plan, y compris les agents cassés."
        case .maintenance: "Tâches système ponctuelles, avec votre mot de passe."
        case .uninstaller: "Retirez une application et les fichiers qui l'accompagnent."
        case .leftovers: "Fichiers d'apps disparues et installateurs oubliés."
        case .clutter: "Gros fichiers, doublons et vieux téléchargements."
        case .spaceLens: "Voyez ce qui occupe réellement la place."
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .smartCare: "sparkles"
        case .cleanup: "trash.circle"
        case .performance: "bolt.horizontal.circle"
        case .maintenance: "wrench.and.screwdriver"
        case .uninstaller: "square.stack.3d.up.slash"
        case .leftovers: "shippingbox"
        case .clutter: "doc.on.doc"
        case .spaceLens: "square.grid.3x3.square"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: .indigo
        case .smartCare: .teal
        case .cleanup: .green
        case .performance: .orange
        case .maintenance: .brown
        case .uninstaller: .blue
        case .leftovers: .cyan
        case .clutter: .purple
        case .spaceLens: .pink
        }
    }
}

enum ScanPhase {
    case idle, scanning, results, cleaning, finished
}

@MainActor
final class ScanStore: ObservableObject {
    @Published var phase: ScanPhase = .idle
    @Published var result = ScanResult()
    @Published var selection: Set<String> = []
    @Published var report = CleanupReport()
    @Published var confirming = false

    private let environment: ScanEnvironment
    private let scanner: @Sendable () -> ScanResult

    init(environment: ScanEnvironment, scanner: @escaping @Sendable () -> ScanResult) {
        self.environment = environment
        self.scanner = scanner
    }

    var allItems: [ScanItem] { result.categories.flatMap(\.items) }
    var selectedItems: [ScanItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func scan() {
        phase = .scanning
        let scanner = scanner
        Task {
            let result = await Task.detached(priority: .userInitiated) { scanner() }.value
            self.result = result
            selection = Set(result.categories.flatMap(\.items).filter { $0.selectedByDefault && !$0.locked }.map(\.id))
            phase = .results
        }
    }

    func clean() {
        let items = selectedItems
        let environment = environment
        phase = .cleaning
        Task {
            report = await Task.detached(priority: .userInitiated) {
                let log = environment.library.appendingPathComponent("Logs/macCleaner/cleanup.log")
                return CleanupRunner(environment: environment, logURL: log).run(items)
            }.value
            phase = .finished
        }
    }

    func toggle(_ item: ScanItem) {
        guard !item.locked else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func toggle(_ category: ScanCategory) {
        let ids = category.items.filter { !$0.locked }.map(\.id)
        if ids.allSatisfy(selection.contains) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func reset() { phase = .idle }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var module: Module? = .dashboard
    @Published var stats = SystemStats.current()

    let environment = ScanEnvironment()
    private(set) lazy var stores: [Module: ScanStore] = makeStores()

    private func makeStores() -> [Module: ScanStore] {
        let environment = environment
        let apps = ApplicationScanner(environment: environment) { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        return [
            .smartCare: ScanStore(environment: environment) { JunkScanner(environment: environment).scanEssentials() },
            .cleanup: ScanStore(environment: environment) { JunkScanner(environment: environment).scan() },
            .performance: ScanStore(environment: environment) { PerformanceScanner(environment: environment).scan() },
            .uninstaller: ScanStore(environment: environment) { apps.scanUninstaller() },
            .leftovers: ScanStore(environment: environment) { apps.scanLeftovers() },
            .clutter: ScanStore(environment: environment) { ClutterScanner(environment: environment).scan() },
        ]
    }

    func refreshStats() { stats = SystemStats.current() }
}

func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
