import MacCleanerCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = HistoryState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .history)
            if state.entries.isEmpty {
                ContentUnavailableView("Aucun nettoyage", systemImage: "clock", description: Text("Les nettoyages apparaîtront ici."))
            } else {
                HStack(spacing: 24) {
                    Text("\(formatBytes(state.entries.reduce(0) { $0 + $1.trashedBytes })) envoyés à la Corbeille")
                    Text("\(formatBytes(state.entries.reduce(0) { $0 + $1.permanentBytes })) supprimés définitivement")
                }
                .font(.headline).padding(.horizontal, 24).padding(.bottom, 8)
                if state.unreadableLines > 0 {
                    Text("\(state.unreadableLines) ligne(s) illisible(s) ignorée(s).")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
                }
                List(state.entries) { entry in
                    DisclosureGroup {
                        ForEach(entry.paths, id: \.self) { path in
                            Text(path).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        ForEach(entry.reinstallCommands ?? [], id: \.self) { command in
                            Text(command).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.module) · \(entry.date.formatted(date: .abbreviated, time: .shortened))").font(.headline)
                            Text(summary(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { state.load(model.history) }
    }

    private func summary(_ entry: HistoryEntry) -> String {
        var parts = ["\(entry.removedCount) élément(s)", formatBytes(entry.trashedBytes + entry.permanentBytes + (entry.evictedBytes ?? 0))]
        if entry.failureCount > 0 { parts.append("\(entry.failureCount) échec(s)") }
        if entry.cancelledCount > 0 { parts.append("interrompu") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
private final class HistoryState: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var unreadableLines = 0

    func load(_ history: CleanupHistory) {
        (entries, unreadableLines) = history.load()
    }
}
