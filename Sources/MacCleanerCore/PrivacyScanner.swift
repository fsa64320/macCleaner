import Foundation
import SQLite3

/// Mots de passe et favoris ne sont jamais proposés : les perdre coûte trop cher.
public struct PrivacyScanner: Sendable {
    private struct Chromium {
        let name: String
        let bundleID: String
        let root: String
    }

    private static let chromiumBrowsers = [
        Chromium(name: "Chrome", bundleID: "com.google.Chrome", root: "Google/Chrome"),
        Chromium(name: "Edge", bundleID: "com.microsoft.edgemac", root: "Microsoft Edge"),
        Chromium(name: "Brave", bundleID: "com.brave.Browser", root: "BraveSoftware/Brave-Browser"),
    ]
    private static let chromiumFiles = [
        ("History", "Historique"), ("History-journal", "Historique (journal)"),
        ("Network/Cookies", "Cookies"), ("Cookies", "Cookies"),
        ("Top Sites", "Sites les plus visités"), ("Visited Links", "Liens visités"),
        ("Sessions", "Onglets de la dernière session"),
    ]
    private static let serviceNames = [
        "kTCCServiceCamera": "Caméra", "kTCCServiceMicrophone": "Microphone",
        "kTCCServiceScreenCapture": "Enregistrement de l'écran", "kTCCServiceAddressBook": "Contacts",
        "kTCCServiceCalendar": "Calendrier", "kTCCServiceReminders": "Rappels",
        "kTCCServicePhotos": "Photos", "kTCCServiceAccessibility": "Accessibilité",
        "kTCCServiceSystemPolicyAllFiles": "Accès complet au disque",
        "kTCCServiceSystemPolicyDocumentsFolder": "Documents",
        "kTCCServiceSystemPolicyDesktopFolder": "Bureau",
        "kTCCServiceSystemPolicyDownloadsFolder": "Téléchargements",
        "kTCCServiceSpeechRecognition": "Reconnaissance vocale", "kTCCServiceMediaLibrary": "Musique",
    ]

    private let env: ScanEnvironment
    private let isRunning: @Sendable (String) -> Bool

    public init(environment: ScanEnvironment, isRunning: @escaping @Sendable (String) -> Bool = { _ in false }) {
        env = environment
        self.isRunning = isRunning
    }

    public func scan() -> ScanResult {
        var collector = Collector()
        var categories = Self.chromiumBrowsers.map { chromium($0, &collector) }
        categories.append(safari(&collector))
        categories.append(firefox(&collector))
        categories.append(permissions(&collector))
        return ScanResult(categories: categories, inaccessible: collector.denied.sorted())
    }

    private func chromium(_ browser: Chromium, _ collector: inout Collector) -> ScanCategory {
        let root = env.library.appendingPathComponent("Application Support/\(browser.root)")
        let profiles = collector.children(of: root).filter {
            $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ")
        }
        var items: [ScanItem] = []
        for profile in profiles {
            for (path, title) in Self.chromiumFiles {
                let url = profile.appendingPathComponent(path)
                guard FileSystem.entryExists(url) else { continue }
                items.append(browserItem(url, title: "\(title) · \(profile.lastPathComponent)", browser: browser.name, bundleID: browser.bundleID))
            }
        }
        return ScanCategory(id: "privacy-\(browser.bundleID)", title: browser.name, summary: summary(browser.name, browser.bundleID), items: items)
    }

    private func safari(_ collector: inout Collector) -> ScanCategory {
        let folder = env.library.appendingPathComponent("Safari")
        let files = collector.children(of: folder).filter {
            $0.lastPathComponent.hasPrefix("History.db") || $0.lastPathComponent == "LastSession.plist"
        }
        var items = files.map { url in
            let title = url.lastPathComponent == "LastSession.plist" ? "Dernière session" : "Historique (\(url.lastPathComponent))"
            return browserItem(url, title: title, browser: "Safari", bundleID: "com.apple.Safari")
        }
        let cookies = env.library.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        if FileSystem.entryExists(cookies) {
            items.append(browserItem(cookies, title: "Cookies", browser: "Safari", bundleID: "com.apple.Safari"))
        }
        return ScanCategory(id: "privacy-safari", title: "Safari", summary: summary("Safari", "com.apple.Safari"), items: items)
    }

    /// `places.sqlite` mêle historique et favoris : il reste volontairement hors liste.
    private func firefox(_ collector: inout Collector) -> ScanCategory {
        let root = env.library.appendingPathComponent("Application Support/Firefox/Profiles")
        var items: [ScanItem] = []
        for profile in collector.children(of: root) {
            for (file, title) in [("cookies.sqlite", "Cookies"), ("formhistory.sqlite", "Historique des formulaires")] {
                let url = profile.appendingPathComponent(file)
                guard FileSystem.entryExists(url) else { continue }
                items.append(browserItem(url, title: "\(title) · \(profile.lastPathComponent)", browser: "Firefox", bundleID: "org.mozilla.firefox"))
            }
        }
        return ScanCategory(id: "privacy-firefox", title: "Firefox", summary: summary("Firefox", "org.mozilla.firefox"), items: items)
    }

    private func browserItem(_ url: URL, title: String, browser: String, bundleID: String) -> ScanItem {
        let running = isRunning(bundleID)
        return ScanItem(
            url: url, name: title, detail: running ? "Quittez \(browser) pour le retirer" : url.deletingLastPathComponent().lastPathComponent,
            size: FileSystem.allocatedSize(of: url), locked: running
        )
    }

    private func summary(_ browser: String, _ bundleID: String) -> String {
        let base = "Va à la Corbeille : videz-la pour effacer ces données."
        return isRunning(bundleID) ? "\(browser) est ouvert. \(base)" : base
    }

    private func permissions(_ collector: inout Collector) -> ScanCategory {
        let database = env.library.appendingPathComponent("Application Support/com.apple.TCC/TCC.db")
        guard FileSystem.entryExists(database) else {
            return ScanCategory(id: "privacy-permissions", title: "Permissions", items: [])
        }
        guard let rows = Self.grantedPermissions(in: database) else {
            collector.denied.insert(database.path)
            return ScanCategory(id: "privacy-permissions", title: "Permissions", items: [])
        }
        let items = rows.map { service, client in
            ScanItem(
                url: database.appendingPathComponent(service).appendingPathComponent(client), name: client,
                detail: Self.serviceNames[service] ?? service, size: 0, locked: true
            )
        }
        return ScanCategory(
            id: "privacy-permissions", title: "Permissions accordées",
            summary: "Consultation seule : à modifier dans Réglages Système.",
            items: items.sorted { ($0.detail, $0.name) < ($1.detail, $1.name) }
        )
    }

    static func grantedPermissions(in database: URL) -> [(service: String, client: String)]? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT service, client FROM access WHERE auth_value = 2"
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        var rows: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let service = sqlite3_column_text(statement, 0), let client = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: service), String(cString: client)))
        }
        return rows
    }
}
