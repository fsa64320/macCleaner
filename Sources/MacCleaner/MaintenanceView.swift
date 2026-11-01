import MacCleanerCore
import SwiftUI

struct MaintenanceView: View {
    @StateObject private var state = MaintenanceState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .maintenance)
            List(MaintenanceTask.allCases) { task in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.headline)
                        Text(task.detail).font(.caption).foregroundStyle(.secondary)
                        if let message = state.messages[task] {
                            Text(message).font(.caption).foregroundStyle(.tint)
                        }
                    }
                    Spacer()
                    if state.running == task {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Exécuter…") { state.pending = task }.disabled(state.running != nil)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(
            state.pending?.title ?? "", isPresented: Binding(get: { state.pending != nil }, set: { if !$0 { state.pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Continuer") { if let task = state.pending { state.run(task) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("macOS va demander votre mot de passe administrateur. \(state.pending?.detail ?? "")")
        }
    }
}

@MainActor
private final class MaintenanceState: ObservableObject {
    @Published var running: MaintenanceTask?
    @Published var pending: MaintenanceTask?
    @Published var messages: [MaintenanceTask: String] = [:]

    func run(_ task: MaintenanceTask) {
        running = task
        Task {
            let outcome = await Task.detached { Result { try task.run() } }.value
            switch outcome {
            case .success: messages[task] = "Terminé."
            case .failure(let error): messages[task] = "Échec : \(error.localizedDescription)"
            }
            running = nil
        }
    }
}
