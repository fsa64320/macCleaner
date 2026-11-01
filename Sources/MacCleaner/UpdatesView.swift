import AppKit
import MacCleanerCore
import SwiftUI

@MainActor
final class UpdateStore: ObservableObject {
    @Published var updates: [AppUpdate] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var activity = ScanProgress.Snapshot()
    @Published var pending: AppUpdate?
    @Published var installing: AppUpdate?
    @Published var confirmingAll = false
    @Published var installingAll = false
    @Published var stopRequested = false
    @Published var messages: [String: String] = [:]

    private var progress: ScanProgress?

    func scan(environment: ScanEnvironment) {
        let progress = ScanProgress()
        self.progress = progress
        scanning = true
        Task {
            let polling = Task { [weak self] in
                while !Task.isCancelled {
                    self?.activity = progress.snapshot
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let found = await Task.detached(priority: .userInitiated) {
                ScanProgress.$current.withValue(progress) { UpdateScanner(environment: environment).scan() }
            }.value
            polling.cancel()
            if !progress.isCancelled {
                updates = found
                scanned = true
            }
            scanning = false
        }
    }

    func cancel() {
        progress?.cancel()
    }

    var installable: [AppUpdate] { AppUpdate.installQueue(updates) }

    func upgrade(_ update: AppUpdate) {
        Task { await install(update) }
    }

    /// Un échec n'arrête pas la suite ; l'arrêt prend effet entre deux mises à jour.
    func upgradeAll() {
        let queue = installable
        installingAll = true
        stopRequested = false
        Task {
            for update in queue where !stopRequested {
                await install(update)
            }
            installingAll = false
        }
    }

    private func install(_ update: AppUpdate) async {
        let source = update.source
        installing = update
        messages[update.id] = nil
        let outcome = await Task.detached {
            Result {
                switch source {
                case .homebrew(let token, let isCask): try Homebrew.upgrade(token: token, isCask: isCask)
                case .commandLine(let tool): try CommandLineTools.upgrade(tool)
                case .sparkle, .appStore: break
                }
            }
        }.value
        switch outcome {
        case .success:
            updates.removeAll { $0 == update }
        case .failure(let error):
            messages[update.id] = "Échec : \(error.localizedDescription)"
        }
        installing = nil
    }
}

struct UpdatesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: UpdateStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .updates)
            if store.scanning {
                ActivityView(title: "Recherche de mises à jour…", activity: store.activity, onCancel: store.cancel)
            } else if store.scanned {
                results
            } else {
                intro
            }
        }
        .confirmationDialog(
            "Mettre à jour \(store.pending?.name ?? "") ?",
            isPresented: Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Mettre à jour") {
                if let update = store.pending { store.upgrade(update) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(store.pending?.sourceName ?? "") installera la version \(store.pending?.latest ?? "").")
        }
        .confirmationDialog(
            "Tout mettre à jour ?", isPresented: $store.confirmingAll, titleVisibility: .visible
        ) {
            Button("Mettre à jour \(store.installable.count) élément(s)") { store.upgradeAll() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(allMessage)
        }
    }

    private var allMessage: String {
        let names = store.installable.prefix(12).map(\.name).joined(separator: ", ")
        let hidden = store.installable.count - min(store.installable.count, 12)
        let more = hidden > 0 ? " et \(hidden) autre(s)" : ""
        let manual = store.updates.count - store.installable.count
        let rest = manual > 0 ? " \(manual) mise(s) à jour à faire depuis l'app ou l'App Store ne seront pas lancées." : ""
        return "\(names)\(more). Les mises à jour se suivent, et un échec n'arrête pas les suivantes.\(rest)"
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            Button { store.scan(environment: model.environment) } label: {
                Text("Rechercher").font(.title2.bold()).frame(width: 150, height: 150)
                    .background(Module.updates.tint.gradient, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Text("Interroge les serveurs de mise à jour de vos apps et l'App Store.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            if store.updates.isEmpty {
                ContentUnavailableView("Tout est à jour", systemImage: "checkmark.seal", description: Text("Aucune mise à jour détectée."))
            } else {
                List(store.updates) { update in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.name).font(.headline)
                            Text("\(update.current) → \(update.latest) · \(update.sourceName)").font(.caption).foregroundStyle(.secondary)
                            if let message = store.messages[update.id] {
                                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        Spacer()
                        action(for: update)
                    }
                    .padding(.vertical, 3)
                }
                .scrollContentBackground(.hidden)
            }
            HStack {
                Button("Nouvelle recherche") { store.scan(environment: model.environment) }
                    .disabled(store.installing != nil)
                Spacer()
                Text("\(store.updates.count) mise(s) à jour").monospacedDigit()
                if store.installingAll {
                    Button(store.stopRequested ? "Arrêt après celle-ci…" : "Arrêter") { store.stopRequested = true }
                        .disabled(store.stopRequested)
                } else {
                    Button("Tout mettre à jour…") { store.confirmingAll = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.installable.isEmpty || store.installing != nil)
                }
            }
            .padding(14).background(.bar)
        }
    }

    @ViewBuilder private func action(for update: AppUpdate) -> some View {
        if store.installing == update {
            ProgressView().controlSize(.small)
        } else {
            switch update.source {
            case .homebrew, .commandLine:
                Button("Mettre à jour…") { store.pending = update }.disabled(store.installing != nil)
            case .sparkle(let app):
                Button("Ouvrir l'app") { NSWorkspace.shared.open(app) }
            case .appStore(let page):
                Button("App Store") { NSWorkspace.shared.open(page) }
            }
        }
    }
}
