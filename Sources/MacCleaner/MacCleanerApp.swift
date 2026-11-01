import MacCleanerCore
import SwiftUI

@main
struct MacCleanerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("macCleaner", id: "main") {
            RootView().environmentObject(model).frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)

        // SwiftUI réécrit ce binding à chaque rendu : ne publier qu'un vrai changement évite une boucle.
        MenuBarExtra(isInserted: Binding(
            get: { model.monitor.showMenuBar },
            set: { if $0 != model.monitor.showMenuBar { model.monitor.showMenuBar = $0 } }
        )) {
            MenuBarContent().environmentObject(model)
        } label: {
            Label(formatBytes(model.stats.diskAvailable), systemImage: model.monitorAlert == nil ? "sparkles" : "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    private let sections: [(String, [Module])] = [
        ("", [.dashboard, .smartCare]),
        ("Nettoyer", [.cleanup, .clutter, .spaceLens, .privacy, .cloud]),
        ("Applications", [.uninstaller, .leftovers, .updates]),
        ("Système", [.performance, .maintenance]),
        ("macCleaner", [.monitoring, .history, .exclusions]),
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $model.module) {
                ForEach(sections, id: \.0) { title, modules in
                    Section(title) {
                        ForEach(modules) { module in
                            Label(module.title, systemImage: module.symbol).tag(module)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(background)
        }
    }

    @ViewBuilder private var detail: some View {
        let module = model.module ?? .dashboard
        switch module {
        case .dashboard: DashboardView()
        case .maintenance: MaintenanceView()
        case .spaceLens: SpaceLensView()
        case .cloud: CloudView(store: model.cloud)
        case .updates: UpdatesView(store: model.updates)
        case .monitoring: MonitoringView()
        case .history: HistoryView()
        case .exclusions: ExclusionsView()
        default:
            if let store = model.stores[module] {
                ScanModuleView(module: module, store: store).id(module)
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [(model.module ?? .dashboard).tint.opacity(0.22), Color(nsColor: .windowBackgroundColor)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct ModuleHeader: View {
    let module: Module

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: module.symbol).font(.system(size: 30)).foregroundStyle(module.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.title.bold())
                Text(module.subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .dashboard)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                MeterCard(
                    title: "Disque", symbol: "internaldrive",
                    value: ratio(stats.diskTotal - stats.diskAvailable, stats.diskTotal),
                    caption: "\(formatBytes(stats.diskAvailable)) disponibles sur \(formatBytes(stats.diskTotal))"
                )
                MeterCard(
                    title: "Mémoire", symbol: "memorychip",
                    value: ratio(stats.memoryUsed, stats.memoryTotal),
                    caption: "\(formatBytes(stats.memoryUsed)) utilisés sur \(formatBytes(stats.memoryTotal))"
                )
                MeterCard(
                    title: "Charge processeur", symbol: "cpu",
                    value: min(stats.loadAverage / Double(max(stats.coreCount, 1)), 1),
                    caption: String(format: "%.2f sur %d cœurs", stats.loadAverage, stats.coreCount)
                )
                MeterCard(
                    title: "Allumé depuis", symbol: "clock", value: nil,
                    caption: Duration.seconds(stats.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
                )
            }
            .padding(24)
            Button {
                model.module = .smartCare
            } label: {
                Label("Lancer l'entretien rapide", systemImage: "sparkles").padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).padding(.horizontal, 24)
            Spacer()
        }
        .onReceive(timer) { _ in model.refreshStats() }
    }

    private func ratio(_ part: Int64, _ total: Int64) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}

struct MeterCard: View {
    let title: String
    let symbol: String
    let value: Double?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            if let value {
                ProgressView(value: value).tint(value > 0.9 ? .red : value > 0.75 ? .orange : .accentColor)
                Text("\(Int(value * 100)) %").font(.title2.bold().monospacedDigit())
            }
            Text(caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
