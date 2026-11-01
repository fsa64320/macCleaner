import AppKit
import MacCleanerCore
import SwiftUI

struct MonitoringView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .monitoring)
            Form {
                Section("Menu bar") {
                    Toggle("Afficher l'espace libre dans la menu bar", isOn: $model.monitor.showMenuBar)
                    Toggle("Ouvrir macCleaner à l'ouverture de session", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
                    ))
                    if let error = model.launchAtLoginError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Disque") {
                    Toggle("Prévenir quand l'espace libre est faible", isOn: Binding(
                        get: { model.monitor.diskAlertEnabled },
                        set: { model.monitor.diskAlertEnabled = $0; if $0 { model.requestNotifications() } }
                    ))
                    Stepper("Seuil : \(model.monitor.minimumFreeGB) Go", value: $model.monitor.minimumFreeGB, in: 5...500, step: 5)
                }
                Section("Analyse planifiée") {
                    Toggle("Analyser caches et journaux régulièrement", isOn: Binding(
                        get: { model.monitor.scheduledScanEnabled },
                        set: { model.monitor.scheduledScanEnabled = $0; if $0 { model.requestNotifications() } }
                    ))
                    Stepper("Toutes les \(model.monitor.scanIntervalHours) h", value: $model.monitor.scanIntervalHours, in: 6...168, step: 6)
                    Stepper("Prévenir à partir de \(model.monitor.junkThresholdMB) Mo", value: $model.monitor.junkThresholdMB, in: 500...50000, step: 500)
                    Text("macCleaner doit être ouvert. L'analyse prévient seulement : le nettoyage reste manuel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(formatBytes(model.stats.diskAvailable)) disponibles")
        Text("Mémoire : \(formatBytes(model.stats.memoryUsed)) utilisés")
        if let alert = model.monitorAlert {
            Divider()
            Text(alert)
        }
        Divider()
        Button("Ouvrir macCleaner") { open(.dashboard) }
        Button("Entretien rapide") { open(.smartCare) }
        Divider()
        Button("Quitter") { NSApp.terminate(nil) }
    }

    private func open(_ module: Module) {
        model.module = module
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
