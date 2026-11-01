import AppKit
import MacCleanerCore
import SwiftUI

struct ExclusionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .exclusions)
            ForEach([model.exclusionsLoadError, model.exclusionsSaveError].compactMap { $0 }, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.15))
            }
            if model.exclusions.paths.isEmpty {
                ContentUnavailableView(
                    "Aucune exclusion", systemImage: "hand.raised",
                    description: Text("Ajoutez un fichier ou un dossier, ou faites un clic droit sur un résultat.")
                )
            } else {
                List(model.exclusions.paths, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Retirer", systemImage: "minus.circle") { model.removeExclusion(path) }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            HStack {
                Button("Ajouter…", action: add).disabled(model.exclusionsLoadError != nil)
                if model.exclusionsLoadError != nil {
                    Button("Réessayer", action: model.loadExclusions)
                }
                Spacer()
            }
            .padding(14).background(.bar)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK { panel.urls.forEach(model.addExclusion) }
    }
}
