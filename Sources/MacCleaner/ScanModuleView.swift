import AppKit
import MacCleanerCore
import SwiftUI

struct ScanModuleView: View {
    let module: Module
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: module)
            switch store.phase {
            case .idle: intro
            case .scanning: busy("Analyse en cours…")
            case .cleaning: busy("Suppression en cours…")
            case .results: results
            case .finished: finished
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $store.confirming, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { store.clean() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            Button(action: store.scan) {
                Text("Analyser").font(.title2.bold()).frame(width: 150, height: 150)
                    .background(module.tint.gradient, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Text("L'analyse ne modifie rien.").foregroundStyle(.secondary)
            if module == .performance {
                Button("Ouvrir les réglages Ouverture de session") {
                    openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func busy(_ title: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(title).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            if !store.result.inaccessible.isEmpty {
                HStack {
                    Image(systemName: "lock.fill")
                    Text("\(store.result.inaccessible.count) dossier(s) illisible(s) : résultats partiels.")
                    Spacer()
                    Button("Accès complet au disque") {
                        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    }
                }
                .padding(10).background(.yellow.opacity(0.18)).help(store.result.inaccessible.joined(separator: "\n"))
            }
            if store.result.categories.isEmpty {
                ContentUnavailableView("Rien à signaler", systemImage: "checkmark.seal", description: Text("Aucun élément trouvé."))
            } else {
                List {
                    ForEach(store.result.categories) { category in
                        CategoryRow(category: category, store: store)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            HStack {
                Button("Nouvelle analyse", action: store.scan)
                Spacer()
                Text("\(store.selection.count) élément(s) · \(formatBytes(store.selectedSize))").monospacedDigit()
                Button("Nettoyer…") { store.confirming = true }
                    .buttonStyle(.borderedProminent).tint(module.tint).disabled(store.selection.isEmpty)
            }
            .padding(14).background(.bar)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(formatBytes(store.report.freedSize)) traités").font(.largeTitle.bold())
            Text("\(store.report.removed.count) élément(s) retiré(s). Le contenu envoyé à la Corbeille reste récupérable et ne libère l'espace qu'une fois celle-ci vidée.")
                .foregroundStyle(.secondary)
            if !store.report.failures.isEmpty {
                Text("\(store.report.failures.count) échec(s)").font(.headline).foregroundStyle(.red)
                List(store.report.failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.item.name)
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            Spacer()
            Button("Terminé", action: store.reset).buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private var confirmTitle: String {
        "Retirer \(store.selectedItems.count) élément(s) ?"
    }

    private var confirmMessage: String {
        let permanent = store.selectedItems.filter { $0.removal == .permanent }.count
        let base = "\(formatBytes(store.selectedSize)) seront envoyés à la Corbeille."
        return permanent > 0 ? "\(base) ATTENTION : \(permanent) élément(s) des corbeilles seront supprimés définitivement." : base
    }
}

private struct CategoryRow: View {
    let category: ScanCategory
    @ObservedObject var store: ScanStore

    var body: some View {
        DisclosureGroup {
            ForEach(category.items.prefix(500)) { item in
                HStack {
                    Toggle(isOn: Binding(get: { store.selection.contains(item.id) }, set: { _ in store.toggle(item) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .disabled(item.locked)
                    Spacer()
                    Text(formatBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
            }
            if category.items.count > 500 {
                Text("500 plus gros éléments affichés sur \(category.items.count).").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Toggle(isOn: Binding(get: { isFullySelected }, set: { _ in store.toggle(category) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.title).font(.headline)
                        if !category.summary.isEmpty {
                            Text(category.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Text(formatBytes(category.totalSize)).font(.headline.monospacedDigit())
            }
        }
    }

    private var isFullySelected: Bool {
        let ids = category.items.filter { !$0.locked }.map(\.id)
        return !ids.isEmpty && ids.allSatisfy(store.selection.contains)
    }
}

func openSettings(_ address: String) {
    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
}
