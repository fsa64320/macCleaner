import Foundation

public struct AppUpdate: Identifiable, Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case homebrew(token: String, isCask: Bool)
        case sparkle(app: URL)
        case appStore(page: URL)
    }

    public var id: String { "\(name)-\(latest)" }
    public let name: String
    public let current: String
    public let latest: String
    public let source: Source

    public var sourceName: String {
        switch source {
        case .homebrew: "Homebrew"
        case .sparkle: "Mise à jour intégrée"
        case .appStore: "App Store"
        }
    }
}

public enum Version {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(candidate), right = components(current)
        guard !left.isEmpty, !right.isEmpty else { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split { !$0.isNumber }.compactMap { Int($0) }
    }
}

public struct UpdateScanner: Sendable {
    private let env: ScanEnvironment
    private let fetch: @Sendable (URL) -> Data?
    private let brewOutdated: @Sendable () -> Data?

    public init(
        environment: ScanEnvironment,
        fetch: @escaping @Sendable (URL) -> Data? = UpdateScanner.download,
        brewOutdated: @escaping @Sendable () -> Data? = Homebrew.outdated
    ) {
        env = environment
        self.fetch = fetch
        self.brewOutdated = brewOutdated
    }

    public func scan() -> [AppUpdate] {
        ScanProgress.current?.update("Interrogation de Homebrew")
        let brew = brewOutdated().map(Self.parseBrew) ?? []
        let apps = ApplicationScanner(environment: env).installedApps(in: env.applicationDirectories)
            .filter { !$0.bundleID.hasPrefix("com.apple.") }
        let lock = NSLock()
        var found: [AppUpdate] = []
        var done = 0
        let progress = ScanProgress.current
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            if progress?.isCancelled == true { return }
            let update = check(apps[index])
            lock.withLock {
                if let update { found.append(update) }
                done += 1
                progress?.update("Vérification de \(apps[index].name)", fraction: Double(done) / Double(apps.count))
            }
        }
        // Une app gérée par Homebrew se met à jour par Homebrew.
        let brewNames = Set(brew.map { Self.normalized($0.name) })
        let others = found.filter { !brewNames.contains(Self.normalized($0.name)) }
        return (brew + others).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func check(_ app: InstalledApp) -> AppUpdate? {
        let receipt = app.url.appendingPathComponent("Contents/_MASReceipt")
        if FileSystem.entryExists(receipt) { return checkAppStore(app) }
        guard let feed = app.feedURL, feed.scheme == "https", let data = fetch(feed),
              let latest = AppcastParser.latest(in: data), Version.isNewer(latest.build, than: app.buildVersion) else { return nil }
        return AppUpdate(name: app.name, current: app.version, latest: latest.display, source: .sparkle(app: app.url))
    }

    private func checkAppStore(_ app: InstalledApp) -> AppUpdate? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [URLQueryItem(name: "bundleId", value: app.bundleID), URLQueryItem(name: "country", value: "fr")]
        guard let url = components?.url, let data = fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["results"] as? [[String: Any]])?.first,
              let latest = result["version"] as? String, Version.isNewer(latest, than: app.version),
              let page = (result["trackViewUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        return AppUpdate(name: app.name, current: app.version, latest: latest, source: .appStore(page: page))
    }

    static func parseBrew(_ data: Data) -> [AppUpdate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let formulae = (json["formulae"] as? [[String: Any]] ?? []).compactMap { entry -> AppUpdate? in
            guard let name = entry["name"] as? String, let latest = entry["current_version"] as? String else { return nil }
            let current = (entry["installed_versions"] as? [String])?.last ?? "?"
            return AppUpdate(name: name, current: current, latest: latest, source: .homebrew(token: name, isCask: false))
        }
        let casks = (json["casks"] as? [[String: Any]] ?? []).compactMap { entry -> AppUpdate? in
            guard let name = entry["name"] as? String, let latest = entry["current_version"] as? String else { return nil }
            let current = (entry["installed_versions"] as? [String])?.last ?? "?"
            return AppUpdate(name: name, current: current, latest: latest, source: .homebrew(token: name, isCask: true))
        }
        return formulae + casks
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static let download: @Sendable (URL) -> Data? = { url in
        let semaphore = DispatchSemaphore(value: 0)
        let box = DataBox()
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.value = data }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return box.value
    }

    private final class DataBox: @unchecked Sendable {
        var value: Data?
    }
}

enum AppcastParser {
    struct Release {
        let build: String
        let display: String
    }

    static func latest(in data: Data) -> Release? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.releases.max { Version.isNewer($1.build, than: $0.build) }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var releases: [Release] = []
        private var inItem = false
        private var build: String?
        private var display: String?
        private var isPrerelease = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            if name == "item" {
                inItem = true
                build = nil
                display = nil
                isPrerelease = false
            } else if inItem, name == "enclosure" {
                build = attributes["sparkle:version"] ?? build
                display = attributes["sparkle:shortVersionString"] ?? display
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:version" where inItem: build = value
            case "sparkle:shortVersionString" where inItem: display = value
            case "sparkle:channel" where inItem: isPrerelease = true
            case "item":
                inItem = false
                if let build, !isPrerelease { releases.append(Release(build: build, display: display ?? build)) }
            default: break
            }
        }
    }
}

public enum Homebrew {
    private static let locations = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    private static var executable: String? {
        locations.first(where: FileManager.default.isExecutableFile)
    }

    public static let outdated: @Sendable () -> Data? = {
        guard let executable else { return nil }
        return try? run(executable, ["outdated", "--json=v2"]).output
    }

    public static func upgrade(token: String, isCask: Bool) throws {
        guard let executable else { throw failure("Homebrew est introuvable.") }
        guard isValid(token: token) else { throw failure("Nom de paquet invalide : \(token)") }
        let result = try run(executable, ["upgrade"] + (isCask ? ["--cask"] : []) + ["--", token])
        guard result.status == 0 else { throw failure(String(decoding: result.output, as: UTF8.self)) }
    }

    static func isValid(token: String) -> Bool {
        !token.hasPrefix("-") && token.range(of: "^[A-Za-z0-9@._+/-]+$", options: .regularExpression) != nil
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Homebrew", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (output: Data, status: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (output, process.terminationStatus)
    }
}
