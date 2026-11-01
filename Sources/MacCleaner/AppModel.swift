import AppKit
import MacCleanerCore
import SwiftUI

enum Module: String, CaseIterable, Identifiable {
    case dashboard, smartCare, cleanup, performance, maintenance, uninstaller, leftovers, clutter, spaceLens, history, exclusions

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
        case .history: "Historique"
        case .exclusions: "Exclusions"
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
        case .history: "Ce qui a été retiré, et quand."
        case .exclusions: "Ce que macCleaner ne doit jamais proposer ni retirer."
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
        case .history: "clock.arrow.circlepath"
        case .exclusions: "hand.raised"
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
        case .history: .gray
        case .exclusions: .red
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
    @Published var activity = ScanProgress.Snapshot()

    private let module: Module
    private unowned let model: AppModel
    private let scanner: @Sendable () -> ScanResult
    private var progress: ScanProgress?

    init(module: Module, model: AppModel, scanner: @escaping @Sendable () -> ScanResult) {
        self.module = module
        self.model = model
        self.scanner = scanner
    }

    var allItems: [ScanItem] { result.categories.flatMap(\.items) }
    var selectedItems: [ScanItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func scan() {
        phase = .scanning
        let scanner = scanner
        Task {
            let (result, cancelled) = await track { scanner() }
            guard !cancelled else {
                phase = .idle
                return
            }
            self.result = model.exclusions.applied(to: result)
            selection = Set(allItems.filter { $0.selectedByDefault && !$0.locked }.map(\.id))
            phase = .results
        }
    }

    func clean() {
        guard let runner = model.makeRunner(module: module) else { return }
        let items = selectedItems
        phase = .cleaning
        Task {
            report = await track { runner.run(items) }.0
            phase = .finished
        }
    }

    func cancel() {
        progress?.cancel()
    }

    func exclude(_ item: ScanItem) {
        model.addExclusion(item.url)
        result = model.exclusions.applied(to: result)
        selection.formIntersection(allItems.map(\.id))
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

    private func track<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> (Value, Bool) {
        let progress = ScanProgress()
        self.progress = progress
        activity = ScanProgress.Snapshot()
        let polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.activity = progress.snapshot
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let value = await Task.detached(priority: .userInitiated) {
            ScanProgress.$current.withValue(progress) { work() }
        }.value
        polling.cancel()
        self.progress = nil
        return (value, progress.isCancelled)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var module: Module? = .dashboard
    @Published var stats = SystemStats.current()
    @Published private(set) var exclusions = Exclusions()
    /// Tant qu'elle est renseignée, aucune suppression n'est permise : les exclusions sont inconnues.
    @Published private(set) var exclusionsLoadError: String?
    @Published private(set) var exclusionsSaveError: String?

    let environment = ScanEnvironment()
    private(set) lazy var stores: [Module: ScanStore] = makeStores()

    private var support: URL { environment.library.appendingPathComponent("Application Support/macCleaner") }
    private var exclusionsURL: URL { support.appendingPathComponent("exclusions.json") }
    var history: CleanupHistory { CleanupHistory(fileURL: support.appendingPathComponent("history.jsonl")) }

    init() {
        loadExclusions()
    }

    func loadExclusions() {
        do {
            exclusions = try Exclusions.load(from: exclusionsURL)
            exclusionsLoadError = nil
        } catch {
            exclusionsLoadError = "\(exclusionsURL.path) est illisible. Corrigez ou supprimez ce fichier."
        }
    }

    func addExclusion(_ url: URL) {
        var updated = exclusions
        updated.add(url)
        store(updated)
    }

    func removeExclusion(_ path: String) {
        var updated = exclusions
        updated.remove(path)
        store(updated)
    }

    private func store(_ updated: Exclusions) {
        guard exclusionsLoadError == nil else { return }
        exclusions = updated
        do {
            try updated.save(to: exclusionsURL)
            exclusionsSaveError = nil
        } catch {
            exclusionsSaveError = "Exclusions non enregistrées : \(error.localizedDescription)"
        }
    }

    func makeRunner(module: Module) -> CleanupRunner? {
        guard exclusionsLoadError == nil else { return nil }
        return CleanupRunner(
            environment: environment, exclusions: exclusions,
            logURL: environment.library.appendingPathComponent("Logs/macCleaner/cleanup.log"),
            history: history, module: module.title
        )
    }

    private func makeStores() -> [Module: ScanStore] {
        let environment = environment
        let apps = ApplicationScanner(environment: environment) { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        return [
            .smartCare: ScanStore(module: .smartCare, model: self) { JunkScanner(environment: environment).scanEssentials() },
            .cleanup: ScanStore(module: .cleanup, model: self) { JunkScanner(environment: environment).scan() },
            .performance: ScanStore(module: .performance, model: self) { PerformanceScanner(environment: environment).scan() },
            .uninstaller: ScanStore(module: .uninstaller, model: self) { apps.scanUninstaller() },
            .leftovers: ScanStore(module: .leftovers, model: self) { apps.scanLeftovers() },
            .clutter: ScanStore(module: .clutter, model: self) { ClutterScanner(environment: environment).scan() },
        ]
    }

    func refreshStats() { stats = SystemStats.current() }
}

func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

struct ActivityView: View {
    let title: String
    let activity: ScanProgress.Snapshot
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let fraction = activity.fraction {
                ProgressView(value: fraction).frame(maxWidth: 360)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.headline)
            Text(activity.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Button("Annuler", action: onCancel)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
