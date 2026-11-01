import AppKit
import MacCleanerCore
import SwiftUI

struct SpaceLensView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SpaceLensState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .spaceLens)
            HStack {
                Button("Choisir un dossier…", action: choose).disabled(state.scanning)
                Button("Dossier personnel") { state.scan(model.environment.home) }.disabled(state.scanning)
                if !state.path.isEmpty {
                    Button("Remonter", systemImage: "chevron.up") { state.path.removeLast() }
                }
                Spacer()
                if let current = state.current {
                    Text("\(current.url.path) · \(formatBytes(current.size))").lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            if state.scanning {
                ActivityView(title: "Lecture du disque…", activity: state.activity, onCancel: state.cancel)
            } else if let current = state.current {
                TreemapView(
                    node: current,
                    onOpen: { if $0.isDirectory && !$0.children.isEmpty { state.path.append($0) } },
                    onRemove: { state.pendingRemoval = $0 }
                )
                .padding([.horizontal, .bottom], 24)
            } else {
                ContentUnavailableView("Aucune analyse", systemImage: "square.grid.3x3.square", description: Text("Choisissez un dossier à cartographier."))
            }
        }
        .confirmationDialog(
            "Envoyer « \(state.pendingRemoval?.name ?? "") » à la Corbeille ?",
            isPresented: Binding(get: { state.pendingRemoval != nil }, set: { if !$0 { state.pendingRemoval = nil } }), titleVisibility: .visible
        ) {
            Button("Envoyer à la Corbeille", role: .destructive) {
                if let node = state.pendingRemoval { state.remove(node, runner: model.makeRunner(module: .spaceLens)) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(state.pendingRemoval.map { formatBytes($0.size) } ?? "") · récupérable depuis la Corbeille.")
        }
        .alert("Suppression impossible", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { state.scan(url) }
    }
}

@MainActor
private final class SpaceLensState: ObservableObject {
    @Published var root: SpaceNode?
    @Published var path: [SpaceNode] = []
    @Published var scanning = false
    @Published var pendingRemoval: SpaceNode?
    @Published var errorMessage: String?
    @Published var activity = ScanProgress.Snapshot()

    private var progress: ScanProgress?

    var current: SpaceNode? { path.last ?? root }

    func scan(_ url: URL) {
        scanning = true
        path = []
        let progress = ScanProgress()
        self.progress = progress
        Task {
            let polling = Task { [weak self] in
                while !Task.isCancelled {
                    self?.activity = progress.snapshot
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let node = await Task.detached(priority: .userInitiated) {
                ScanProgress.$current.withValue(progress) { SpaceScanner().scan(url) }
            }.value
            polling.cancel()
            if !progress.isCancelled { root = node }
            scanning = false
        }
    }

    func cancel() {
        progress?.cancel()
    }

    func remove(_ node: SpaceNode, runner: CleanupRunner?) {
        guard let runner else {
            errorMessage = "Le fichier des exclusions est illisible."
            return
        }
        let item = ScanItem(url: node.url, size: node.size)
        Task {
            let report = await Task.detached { runner.run([item]) }.value
            if let failure = report.failures.first {
                errorMessage = failure.reason
            } else if report.removed.isEmpty {
                errorMessage = "Cet élément est protégé par une exclusion."
            } else if let rootURL = root?.url {
                scan(rootURL)
            }
        }
    }
}

private struct TreemapView: View {
    let node: SpaceNode
    let onOpen: (SpaceNode) -> Void
    let onRemove: (SpaceNode) -> Void
    private let palette: [Color] = [.pink, .purple, .indigo, .blue, .teal, .green, .orange]

    var body: some View {
        GeometryReader { geometry in
            let nodes = Array(node.children.prefix(80))
            let rects = Treemap.layout(values: nodes.map { Double($0.size) }, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, child in
                    let rect = rects[index]
                    Button { onOpen(child) } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 5).fill(palette[index % palette.count].gradient)
                            if rect.width > 70, rect.height > 38 {
                                VStack(alignment: .leading) {
                                    Text(child.name).bold().lineLimit(1)
                                    Text(formatBytes(child.size)).font(.caption)
                                }
                                .foregroundStyle(.white).padding(6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(rect.width - 2, 1), height: max(rect.height - 2, 1))
                    .offset(x: rect.minX, y: rect.minY)
                    .help("\(child.name) · \(formatBytes(child.size))")
                    .contextMenu {
                        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
                        Button("Envoyer à la Corbeille…", role: .destructive) { onRemove(child) }
                    }
                }
            }
        }
    }
}
