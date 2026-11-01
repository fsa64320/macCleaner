import CoreGraphics
import ImageIO
import SQLite3
import Foundation
import Testing
@testable import MacCleanerCore

final class URLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var urls: [URL] { lock.withLock { stored } }
    func add(_ url: URL) { lock.withLock { stored.append(url) } }
}

final class RecordingRemover: FileRemoving, @unchecked Sendable {
    var trashed: [URL] = []
    var deleted: [URL] = []
    var unloaded: [String] = []
    func moveToTrash(_ url: URL) throws -> URL? { trashed.append(url); return nil }
    var evicted: [URL] = []
    func evictLocalCopy(_ url: URL) throws { evicted.append(url) }
    var dockerImages: [String] = []
    func removeDockerImage(_ identifier: String) throws { dockerImages.append(identifier) }
    var tools: [(identifier: String, arguments: [String])] = []
    var failingTools: Set<String> = []
    struct ToolFailure: LocalizedError { var errorDescription: String? { "échec simulé" } }
    func uninstallCommandLineTool(_ identifier: String, arguments: [String]) throws {
        if failingTools.contains(identifier) { throw ToolFailure() }
        tools.append((identifier, arguments))
    }
    func deletePermanently(_ url: URL) throws { deleted.append(url) }
    func unloadLaunchAgent(label: String) throws { unloaded.append(label) }
}

@Suite final class CoreTests {
    private let home: URL
    private let env: ScanEnvironment

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        env = ScanEnvironment(
            home: home, volumesRoot: home.appendingPathComponent("Volumes"),
            applicationDirectories: [home.appendingPathComponent("Apps")],
            systemApplicationDirectories: [], systemLaunchDirectories: []
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func write(_ path: String, bytes: Int = 8192, seed: UInt8 = 1) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: seed, count: bytes).write(to: url)
        return url
    }

    private func makeApp(_ name: String, id: String, extra: [String: String] = [:]) throws {
        let url = try write("Apps/\(name).app/Contents/Info.plist")
        let plist = ["CFBundleIdentifier": id, "CFBundleName": name].merging(extra) { $1 }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    // MARK: SafetyPolicy

    @Test func testPolicyRejectsSensitiveLocations() {
        let policy = SafetyPolicy(environment: env)
        for path in ["", "Library", "Documents", "Library/Caches", ".ssh/id_rsa", "Library/Keychains/login.keychain-db", "Library/Mobile Documents/doc"] {
            #expect(throws: (any Error).self) { try policy.validate(home.appendingPathComponent(path), removal: .moveToTrash) }
        }
        #expect(throws: (any Error).self) { try policy.validate(URL(fileURLWithPath: "/usr/bin/true"), removal: .moveToTrash) }
        #expect(throws: (any Error).self) { try policy.validate(URL(fileURLWithPath: "/etc/hosts"), removal: .moveToTrash) }
    }

    @Test func testPolicyRestrictsPermanentDeletionToTrash() throws {
        let policy = SafetyPolicy(environment: env)
        #expect(throws: (any Error).self) { try policy.validate(home.appendingPathComponent("Library/Caches/x"), removal: .permanent) }
        #expect(throws: Never.self) { try policy.validate(home.appendingPathComponent(".Trash/x"), removal: .permanent) }
        #expect(throws: Never.self) { try policy.validate(home.appendingPathComponent("Volumes/USB/.Trashes/501/x"), removal: .permanent) }
        #expect(throws: (any Error).self) { try policy.validate(home.appendingPathComponent("Volumes/USB/data/x"), removal: .permanent) }
    }

    @Test func testPolicyFollowsSymlinkedParents() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try SafetyPolicy(environment: env).validate(link.appendingPathComponent("x"), removal: .moveToTrash) }
    }

    @Test func testPolicyAllowsOnlyAppBundlesInApplications() {
        let policy = SafetyPolicy(environment: env)
        #expect(throws: Never.self) { try policy.validate(home.appendingPathComponent("Apps/Foo.app"), removal: .moveToTrash) }
        #expect(throws: (any Error).self) { try policy.validate(home.appendingPathComponent("Apps"), removal: .moveToTrash) }
    }

    // MARK: CleanupRunner

    @Test func testRunnerRoutesRemovalsAndReportsBlockedItems() throws {
        let cache = try write("Library/Caches/foo/data")
        let trashed = try write(".Trash/old")
        let keychain = try write("Library/Keychains/login")
        let agent = try write("Library/LaunchAgents/a.plist")
        let locked = try write("Library/LaunchAgents/b.plist")
        let remover = RecordingRemover()
        let report = CleanupRunner(remover: remover, environment: env).run([
            ScanItem(url: cache, size: 10),
            ScanItem(url: trashed, size: 20, removal: .permanent),
            ScanItem(url: keychain, size: 30),
            ScanItem(url: agent, size: 40, removal: .launchAgent, launchLabel: "com.a"),
            ScanItem(url: locked, size: 50, locked: true),
            ScanItem(url: home.appendingPathComponent("Library/Caches/gone"), size: 60),
        ])
        #expect(remover.trashed == [cache, agent])
        #expect(remover.deleted == [trashed])
        #expect(remover.unloaded == ["com.a"])
        #expect(report.trashedSize == 50)
        #expect(report.permanentSize == 20)
        #expect(report.failures.map(\.item.url) == [keychain])
        #expect(report.skipped.count == 2)
    }

    @Test func testRunnerWritesLog() throws {
        let cache = try write("Library/Caches/foo")
        let log = home.appendingPathComponent("logs/cleanup.log")
        _ = CleanupRunner(remover: RecordingRemover(), environment: env, logURL: log).run([ScanItem(url: cache, size: 1)])
        #expect(try String(contentsOf: log, encoding: .utf8).contains(cache.path))
    }

    @Test func testRunnerSkipsExcludedAndWritesHistory() throws {
        let kept = try write("Library/Caches/keep/data")
        let removed = try write("Library/Caches/drop")
        let remover = RecordingRemover()
        let history = CleanupHistory(fileURL: home.appendingPathComponent("support/history.jsonl"))
        var exclusions = Exclusions()
        exclusions.add(kept)
        let report = CleanupRunner(remover: remover, environment: env, exclusions: exclusions, history: history, module: "Test").run([
            ScanItem(url: kept.deletingLastPathComponent(), size: 5),
            ScanItem(url: removed, size: 7),
        ])
        #expect(remover.trashed == [removed])
        #expect(report.skipped.count == 1)
        let entry = try #require(history.load().entries.first)
        #expect(entry.module == "Test")
        #expect(entry.trashedBytes == 7)
        #expect(entry.paths == [removed.path])
    }

    @Test func testRunnerStopsWhenCancelled() throws {
        let first = try write("Library/Caches/a")
        let progress = ScanProgress()
        progress.cancel()
        let remover = RecordingRemover()
        let report = ScanProgress.$current.withValue(progress) {
            CleanupRunner(remover: remover, environment: env).run([ScanItem(url: first, size: 1)])
        }
        #expect(remover.trashed.isEmpty)
        #expect(report.cancelledCount == 1)
    }

    @Test func testHistorySurvivesCorruptLine() throws {
        let url = home.appendingPathComponent("history.jsonl")
        let history = CleanupHistory(fileURL: url)
        let entry = HistoryEntry(date: Date(), module: "A", removedCount: 1, trashedBytes: 1, permanentBytes: 0, evictedBytes: nil, failureCount: 0, cancelledCount: 0, paths: [])
        try history.append(entry)
        try FileSystem.append(Data("pas du json\n".utf8), to: url)
        try history.append(entry)
        let loaded = history.load()
        #expect(loaded.entries.count == 2)
        #expect(loaded.unreadableLines == 1)
    }

    // MARK: Exclusions

    @Test func testExclusionsCoverChildrenAndParents() {
        var exclusions = Exclusions()
        exclusions.add(home.appendingPathComponent("Library/Caches/app/keep"))
        #expect(exclusions.covers(home.appendingPathComponent("Library/Caches/app/keep/file")))
        #expect(exclusions.covers(home.appendingPathComponent("Library/Caches/app")))
        #expect(!exclusions.covers(home.appendingPathComponent("Library/Caches/app/keep2")))
    }

    @Test func testExclusionsRoundTripAndRejectCorruptFile() throws {
        let url = home.appendingPathComponent("support/exclusions.json")
        #expect(try Exclusions.load(from: url).paths.isEmpty)
        var exclusions = Exclusions()
        exclusions.add(home.appendingPathComponent("x"))
        try exclusions.save(to: url)
        #expect(try Exclusions.load(from: url) == exclusions)
        try Data("{".utf8).write(to: url)
        #expect(throws: (any Error).self) { try Exclusions.load(from: url) }
    }

    @Test func testExclusionsFilterResults() throws {
        let kept = try write("Library/Caches/keep")
        let other = try write("Library/Caches/other")
        var exclusions = Exclusions()
        exclusions.add(kept)
        let result = exclusions.applied(to: JunkScanner(environment: env).scan())
        #expect(result.categories.flatMap(\.items).map(\.url.lastPathComponent) == [other.lastPathComponent])
    }

    // MARK: Annulation

    @Test func testCancelledScanStopsEarly() throws {
        try write("Library/Caches/a/data")
        let progress = ScanProgress()
        progress.cancel()
        let result = ScanProgress.$current.withValue(progress) { JunkScanner(environment: env).scan() }
        #expect(result.categories.isEmpty)
    }

    @Test func testProgressReportsCurrentFolder() throws {
        try write("Library/Caches/a/data")
        let progress = ScanProgress()
        _ = ScanProgress.$current.withValue(progress) { JunkScanner(environment: env).scanEssentials() }
        #expect(!progress.snapshot.message.isEmpty)
    }

    // MARK: Maintenance

    @Test func testMaintenanceScriptsCompile() throws {
        for task in MaintenanceTask.allCases {
            let script = try #require(NSAppleScript(source: task.appleScript))
            var error: NSDictionary?
            #expect(script.compileAndReturnError(&error), "\(task)")
        }
    }

    // MARK: Modèles locaux

    private func ollamaManifest(_ name: String, blobs: [String]) throws {
        let url = try write(".ollama/models/manifests/registry.ollama.ai/library/\(name)/latest")
        let json: [String: Any] = ["layers": blobs.map { ["digest": "sha256:\($0)"] }]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    @Test func testOllamaKeepsSharedBlobs() throws {
        try ollamaManifest("alpha", blobs: ["aaa", "shared"])
        try ollamaManifest("beta", blobs: ["bbb", "shared"])
        try write(".ollama/models/blobs/sha256-aaa", bytes: 40000)
        try write(".ollama/models/blobs/sha256-bbb", bytes: 40000)
        try write(".ollama/models/blobs/sha256-shared", bytes: 400_000)
        let items = JunkScanner(environment: env).scan().categories.flatMap(\.items)
        let alpha = try #require(items.first { $0.name == "Ollama · alpha:latest" })
        #expect(alpha.companions.map(\.lastPathComponent) == ["sha256-aaa"])
        #expect(alpha.size < 100_000)
        #expect(!alpha.selectedByDefault)
    }

    @Test func testOllamaManifestCannotEscapeBlobFolder() throws {
        let url = try write("manifest")
        try JSONSerialization.data(withJSONObject: ["layers": [["digest": "../../../.ssh/id_rsa"]]]).write(to: url)
        #expect(LocalModelScanner.blobs(inManifest: url) == [])
    }

    @Test func testRunnerRemovesCompanionsAndValidatesThem() throws {
        let manifest = try write(".ollama/models/manifests/x")
        let blob = try write(".ollama/models/blobs/sha256-x")
        let key = try write(".ssh/id_rsa")
        let remover = RecordingRemover()
        let runner = CleanupRunner(remover: remover, environment: env)
        let report = runner.run([ScanItem(url: manifest, size: 1, companions: [blob])])
        #expect(remover.trashed == [manifest, blob])
        #expect(report.removed.count == 1)
        let blocked = runner.run([ScanItem(url: manifest, size: 1, companions: [key])])
        #expect(blocked.failures.count == 1)
        #expect(!remover.trashed.contains(key))
    }

    @Test func testExclusionCoversCompanions() throws {
        let manifest = try write("m")
        let blob = try write("b")
        var exclusions = Exclusions()
        exclusions.add(blob)
        let result = ScanResult(categories: [ScanCategory(id: "c", title: "c", items: [ScanItem(url: manifest, size: 1, companions: [blob])])])
        #expect(exclusions.applied(to: result).categories.isEmpty)
    }

    @Test func testLMStudioAndHuggingFaceListedPerModel() throws {
        try write(".lmstudio/models/acme/model-a/w.gguf")
        try write(".cache/huggingface/hub/models--acme--model-b/blob")
        let names = JunkScanner(environment: env).scan().categories.flatMap(\.items).map(\.name)
        #expect(names.contains("LM Studio · acme/model-a"))
        #expect(names.contains("Hugging Face · acme/model-b"))
    }

    // MARK: Confidentialité

    @Test func testPrivacyListsTracesButNeverPasswordsOrBookmarks() throws {
        let profile = "Library/Application Support/Google/Chrome/Default"
        for file in ["History", "Network/Cookies", "Login Data", "Bookmarks"] { try write("\(profile)/\(file)") }
        try write("Library/Application Support/Firefox/Profiles/a.default/cookies.sqlite")
        try write("Library/Application Support/Firefox/Profiles/a.default/places.sqlite")
        try write("Library/Application Support/Firefox/Profiles/a.default/logins.json")
        try write("Library/Safari/History.db")
        try write("Library/Safari/Bookmarks.plist")
        let items = PrivacyScanner(environment: env).scan().categories.flatMap(\.items)
        let files = Set(items.map(\.url.lastPathComponent))
        #expect(files == ["History", "Cookies", "cookies.sqlite", "History.db"])
        #expect(items.allSatisfy { !$0.selectedByDefault })
    }

    @Test func testPrivacyLocksRunningBrowser() throws {
        try write("Library/Application Support/Google/Chrome/Default/History")
        let scanner = PrivacyScanner(environment: env) { $0 == "com.google.Chrome" }
        let item = try #require(scanner.scan().categories.first?.items.first)
        #expect(item.locked)
    }

    @Test func testPermissionsReadFromDatabase() throws {
        let url = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE access(service TEXT, client TEXT, auth_value INT); INSERT INTO access VALUES('kTCCServiceCamera','com.acme.app',2),('kTCCServiceMicrophone','com.acme.no',0);", nil, nil, nil)
        sqlite3_close(handle)
        let category = try #require(PrivacyScanner(environment: env).scan().categories.first { $0.id == "privacy-permissions" })
        #expect(category.items.map(\.name) == ["com.acme.app"])
        #expect(category.items.first?.detail == "Caméra")
        #expect(category.items.first?.locked == true)
    }

    // MARK: Images similaires

    private func image(_ path: String, variant: Int, size: Int = 512) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let unit = CGFloat(size) / 512
        if variant == 0 {
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 100 * unit, y: 200 * unit, width: 240 * unit, height: 240 * unit))
            context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: 150 * size / 512))
        } else {
            for row in 0..<16 {
                for column in 0..<16 {
                    let shade = CGFloat((row * 7 + column * 11) % 16) / 15
                    context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.3, alpha: 1))
                    context.fill(CGRect(x: CGFloat(column) * 32 * unit, y: CGFloat(row) * 32 * unit, width: 32 * unit, height: 32 * unit))
                }
            }
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func testSimilarImagesGroupsResizedCopy() throws {
        _ = try image("Pictures/original.png", variant: 0, size: 1024)
        let copy = try image("Pictures/copy.png", variant: 0, size: 512)
        _ = try image("Pictures/other.png", variant: 1)
        let result = SimilarImageScanner(environment: env, minimumSize: 0).scan()
        let items = result.categories.flatMap(\.items)
        #expect(items.map(\.url.lastPathComponent) == [copy.lastPathComponent])
        #expect(items.allSatisfy { !$0.selectedByDefault })
    }

    // MARK: Mises à jour

    @Test func testVersionComparison() {
        #expect(Version.isNewer("1.10.0", than: "1.9"))
        #expect(!Version.isNewer("1.0", than: "1.0.0"))
        #expect(!Version.isNewer("abc", than: "1.0"))
    }

    @Test func testAppcastTakesLatestStableRelease() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure url="https://x/1" sparkle:version="10" sparkle:shortVersionString="1.0"/></item>
        <item><sparkle:version>20</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString><enclosure url="https://x/2"/></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure url="https://x/3" sparkle:version="30"/></item>
        </channel></rss>
        """
        let release = try #require(AppcastParser.latest(in: Data(xml.utf8)))
        #expect(release.build == "20")
        #expect(release.display == "2.0")
    }

    @Test func testUpdateScannerCombinesSources() throws {
        try makeApp("Spark", id: "com.acme.spark", extra: ["SUFeedURL": "https://acme.test/feed", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"])
        try makeApp("Plain", id: "com.acme.plain", extra: ["SUFeedURL": "http://acme.test/insecure", "CFBundleVersion": "1"])
        try makeApp("Store", id: "com.acme.store", extra: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"])
        try write("Apps/Store.app/Contents/_MASReceipt/receipt")
        let feed = #"<rss xmlns:sparkle="s"><channel><item><enclosure sparkle:version="2" sparkle:shortVersionString="2.0"/></item></channel></rss>"#
        let lookup = #"{"results":[{"version":"3.0","trackViewUrl":"https://apps.apple.com/app/id1"}]}"#
        let brew = #"{"formulae":[{"name":"wget","installed_versions":["1.0"],"current_version":"1.1"}],"casks":[{"name":"plain","installed_versions":["1"],"current_version":"2"}]}"#
        let requested = URLLog()
        let scanner = UpdateScanner(environment: env, fetch: { url in
            requested.add(url)
            return Data((url.host == "itunes.apple.com" ? lookup : feed).utf8)
        }, brewOutdated: { Data(brew.utf8) })
        let updates = scanner.scan()
        #expect(updates.map(\.name) == ["plain", "Spark", "Store", "wget"])
        #expect(!requested.urls.contains { $0.scheme == "http" })
    }

    @Test func testAppStoreLookupIgnoresIOSVersion() throws {
        try makeApp("Store", id: "com.acme.store", extra: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"])
        try write("Apps/Store.app/Contents/_MASReceipt/receipt")
        let scanner = UpdateScanner(environment: env, fetch: { url in
            let isMac = url.query?.contains("entity=desktopSoftware") == true
            let version = isMac ? "1.0" : "2.0"
            return Data(#"{"results":[{"version":"\#(version)","trackViewUrl":"https://apps.apple.com/app/id1"}]}"#.utf8)
        }, brewOutdated: { nil })
        #expect(scanner.scan().isEmpty)
    }

    @Test func testHomebrewRejectsUnsafeTokens() {
        #expect(Homebrew.isValid(token: "openssl@3"))
        #expect(!Homebrew.isValid(token: "--force"))
        #expect(!Homebrew.isValid(token: "a b"))
        #expect(!Homebrew.isValid(token: "a;rm"))
    }

    // MARK: Surveillance

    @Test func testDiskAlertRespectsThresholdAndInterval() {
        var settings = MonitorSettings()
        let now = Date()
        #expect(!MonitorPolicy.shouldAlertDisk(settings, available: 1, now: now))
        settings.diskAlertEnabled = true
        #expect(MonitorPolicy.shouldAlertDisk(settings, available: 1, now: now))
        #expect(!MonitorPolicy.shouldAlertDisk(settings, available: 21_000_000_000, now: now))
        settings.lastDiskAlert = now.addingTimeInterval(-3600)
        #expect(!MonitorPolicy.shouldAlertDisk(settings, available: 1, now: now))
        #expect(MonitorPolicy.isDiskLow(settings, available: 1))
        settings.lastDiskAlert = now.addingTimeInterval(-90_000)
        #expect(MonitorPolicy.shouldAlertDisk(settings, available: 1, now: now))
    }

    @Test func testScheduledScanAndReporting() throws {
        var settings = MonitorSettings()
        let now = Date()
        #expect(!MonitorPolicy.shouldScan(settings, now: now))
        settings.scheduledScanEnabled = true
        #expect(MonitorPolicy.shouldScan(settings, now: now))
        settings.lastScan = now.addingTimeInterval(-3600)
        #expect(!MonitorPolicy.shouldScan(settings, now: now))
        settings.junkThresholdMB = 1
        let url = home.appendingPathComponent("x")
        let big = ScanResult(categories: [ScanCategory(id: "c", title: "c", items: [
            ScanItem(url: url, size: 2_000_000, selectedByDefault: true),
            ScanItem(url: url.appendingPathExtension("y"), size: 5_000_000),
        ])])
        #expect(MonitorPolicy.junkWorthReporting(settings, result: big) == 2_000_000)
        settings.junkThresholdMB = 3
        #expect(MonitorPolicy.junkWorthReporting(settings, result: big) == nil)
    }

    @Test func testMonitorSettingsFallBackWhenCorrupt() throws {
        let url = home.appendingPathComponent("monitor.json")
        try Data("{".utf8).write(to: url)
        #expect(MonitorSettings.load(from: url) == MonitorSettings())
    }

    // MARK: Cloud sur ce Mac

    @Test func testCloudLocalListsOnlyDownloadedLargeFiles() throws {
        let kept = try write("Library/CloudStorage/GoogleDrive-moi@exemple.fr/Mon Drive/gros.mov", bytes: 300_000)
        try write("Library/CloudStorage/GoogleDrive-moi@exemple.fr/Mon Drive/enligne.mov", bytes: 300_000)
        try write("Library/CloudStorage/GoogleDrive-moi@exemple.fr/petit.txt", bytes: 8192)
        try write("Library/Mobile Documents/com~apple~CloudDocs/video.mp4", bytes: 300_000)
        let scanner = CloudLocalScanner(environment: env, minimumSize: 100_000) { $0.lastPathComponent != "enligne.mov" }
        let result = scanner.scan()
        #expect(Set(result.categories.map(\.title)) == ["Google Drive · moi@exemple.fr", "iCloud Drive"])
        let items = result.categories.flatMap(\.items)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.removal == .evictLocalCopy && !$0.selectedByDefault })
        #expect(items.contains { $0.url.lastPathComponent == kept.lastPathComponent })
    }

    @Test func testEvictionAllowedOnlyForCloudFiles() throws {
        let policy = SafetyPolicy(environment: env)
        let cloud = try write("Library/CloudStorage/Dropbox/a.bin")
        #expect(throws: Never.self) { try policy.validate(cloud, removal: .evictLocalCopy) }
        #expect(throws: (any Error).self) { try policy.validate(cloud, removal: .moveToTrash) }
        #expect(throws: (any Error).self) { try policy.validate(home.appendingPathComponent("Documents/a"), removal: .evictLocalCopy) }
    }

    @Test func testRunnerEvictsWithoutTrashing() throws {
        let cloud = try write("Library/Mobile Documents/x/a.bin")
        let remover = RecordingRemover()
        let report = CleanupRunner(remover: remover, environment: env).run([ScanItem(url: cloud, size: 9, removal: .evictLocalCopy)])
        #expect(remover.evicted == [cloud])
        #expect(remover.trashed.isEmpty)
        #expect(report.evictedSize == 9)
        #expect(report.trashedSize == 0)
    }

    // MARK: Outils de développement

    private func age(_ path: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: home.appendingPathComponent(path).path)
    }

    private func noDocker() -> DevToolsScanner {
        DevToolsScanner(environment: env, docker: { _ in nil })
    }

    @Test func testDevToolsFindsOnlyStaleProjectsWithManifest() throws {
        try write("code/old/package.json")
        try write("code/old/node_modules/dep/index.js", bytes: 40000)
        try write("code/old/node_modules/dep/node_modules/nested/x.js")
        try age("code/old/package.json", days: 90)
        try write("code/fresh/package.json")
        try write("code/fresh/node_modules/dep/index.js")
        try write("code/nomanifest/target/file")
        try age("code/nomanifest/target", days: 90)
        try write("code/rust/Cargo.toml")
        try write("code/rust/target/debug/app")
        try age("code/rust/Cargo.toml", days: 200)
        try write("Library/app/node_modules/x/y.js")
        let category = try #require(noDocker().scan().categories.first { $0.id == "dev-projects" })
        #expect(Set(category.items.map(\.name)) == ["old/node_modules", "rust/target"])
        #expect(category.items.allSatisfy { !$0.selectedByDefault && $0.removal == .moveToTrash })
    }

    @Test func testGitActivityDoesNotKeepProjectFresh() throws {
        try write("code/old/package.json")
        try write("code/old/node_modules/x.js")
        try write("code/old/.git/FETCH_HEAD")
        try age("code/old/package.json", days: 90)
        let items = noDocker().scan().categories.flatMap(\.items)
        #expect(items.map(\.name) == ["old/node_modules"])
    }

    @Test func testPackageCachesPreselectOnlySafeOnes() throws {
        try write("Library/Caches/Homebrew/downloads/x")
        try write(".gradle/caches/modules/y")
        let items = noDocker().scan().categories.flatMap(\.items)
        #expect(items.first { $0.name == "Homebrew" }?.selectedByDefault == true)
        #expect(items.first { $0.name == "Gradle" }?.selectedByDefault == false)
        #expect(throws: Never.self) { try SafetyPolicy(environment: env).validate(try #require(items.first).url, removal: .moveToTrash) }
    }

    @Test func testDockerListsOnlyUnusedImages() throws {
        let unused = "sha256:" + String(repeating: "a", count: 64)
        let used = "sha256:" + String(repeating: "b", count: 64)
        let unknown = "sha256:" + String(repeating: "c", count: 64)
        let json = """
        {"Images":[
        {"ID":"\(unused)","Repository":"redis","Tag":"7","Size":"1.5GB","Containers":"0","CreatedSince":"2 months ago"},
        {"ID":"\(used)","Repository":"nginx","Tag":"1","Size":"100MB","Containers":"2"},
        {"ID":"\(unknown)","Repository":"x","Tag":"1","Size":"1MB","Containers":"N/A"},
        {"ID":"../../etc","Repository":"y","Tag":"1","Size":"1MB","Containers":"0"}
        ]}
        """
        let scanner = DevToolsScanner(environment: env, docker: { _ in Docker.Output(data: Data(json.utf8), status: 0) })
        let items = try #require(scanner.scan().categories.first { $0.id == "dev-docker" }).items
        #expect(items.map(\.name) == ["redis:7"])
        #expect(items.first?.size == 1_500_000_000)
        #expect(items.first?.selectedByDefault == false)
    }

    @Test func testDockerStoppedIsReportedNotSelectable() throws {
        let scanner = DevToolsScanner(environment: env, docker: { _ in Docker.Output(data: Data(), status: 1) })
        let item = try #require(scanner.scan().categories.first { $0.id == "dev-docker" }?.items.first)
        #expect(item.locked)
    }

    @Test func testRunnerRemovesDockerImageAsPermanent() throws {
        let remover = RecordingRemover()
        let identifier = String(repeating: "a", count: 12)
        let item = ScanItem(url: URL(fileURLWithPath: "/docker/images/\(identifier)"), size: 9, removal: .dockerImage, launchLabel: identifier)
        let report = CleanupRunner(remover: remover, environment: env).run([item])
        #expect(remover.dockerImages == [identifier])
        #expect(report.permanentSize == 9)
    }

    @Test func testRunnerUninstallsCommandLineTool() throws {
        let url = home.appendingPathComponent("Cellar/ripgrep")
        let item = ScanItem(url: url, size: 10, removal: .commandLineTool, launchLabel: "brew:ripgrep",
                            removalArguments: ["pcre2"], reinstallCommand: "brew install ripgrep")
        let remover = RecordingRemover()
        let report = CleanupRunner(remover: remover, environment: env).run([item])
        #expect(remover.tools.map(\.identifier) == ["brew:ripgrep"])
        #expect(remover.tools.first?.arguments == ["pcre2"])
        #expect(report.permanentSize == 10)
    }

    @Test func testRunnerSkipsExcludedAndLockedTools() throws {
        let excludedURL = home.appendingPathComponent("Cellar/excluded")
        var exclusions = Exclusions()
        exclusions.add(excludedURL)
        let remover = RecordingRemover()
        let report = CleanupRunner(remover: remover, environment: env, exclusions: exclusions).run([
            ScanItem(url: excludedURL, size: 1, removal: .commandLineTool, launchLabel: "brew:excluded"),
            ScanItem(url: home.appendingPathComponent("Cellar/locked"), size: 1, removal: .commandLineTool, launchLabel: "brew:locked", locked: true),
        ])
        #expect(report.skipped.count == 2)
        #expect(remover.tools.isEmpty)
    }

    @Test func testRunnerContinuesAfterToolFailure() throws {
        let broken = home.appendingPathComponent("Cellar/broken")
        let fine = home.appendingPathComponent("Cellar/fine")
        let remover = RecordingRemover()
        remover.failingTools = ["brew:broken"]
        let report = CleanupRunner(remover: remover, environment: env).run([
            ScanItem(url: broken, size: 1, removal: .commandLineTool, launchLabel: "brew:broken"),
            ScanItem(url: fine, size: 2, removal: .commandLineTool, launchLabel: "brew:fine"),
        ])
        #expect(report.failures.count == 1)
        #expect(report.removed.count == 1)
        #expect(remover.tools.map(\.identifier) == ["brew:fine"])
        #expect(!FileManager.default.fileExists(atPath: fine.path))
    }

    @Test func testHistoryKeepsReinstallCommands() throws {
        let history = CleanupHistory(fileURL: home.appendingPathComponent("history.jsonl"))
        let item = ScanItem(url: home.appendingPathComponent("Cellar/ripgrep"), size: 10, removal: .commandLineTool,
                            launchLabel: "brew:ripgrep", reinstallCommand: "brew install ripgrep")
        _ = CleanupRunner(remover: RecordingRemover(), environment: env, history: history, module: "Test").run([item])
        #expect(history.load().entries.first?.reinstallCommands == ["brew install ripgrep"])
    }

    @Test func testHistoryReadsOldLines() throws {
        let url = home.appendingPathComponent("history.jsonl")
        let line = #"{"date":"2026-01-01T00:00:00Z","module":"A","removedCount":1,"trashedBytes":1,"permanentBytes":0,"failureCount":0,"cancelledCount":0,"paths":[]}"#
        try Data((line + "\n").utf8).write(to: url)
        let loaded = CleanupHistory(fileURL: url).load()
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries.first?.reinstallCommands == nil)
        #expect(loaded.unreadableLines == 0)
    }

    @Test func testDockerRejectsUnsafeIdentifiers() {
        #expect(Docker.isValid(identifier: "abcdef123456"))
        #expect(!Docker.isValid(identifier: "--force"))
        #expect(!Docker.isValid(identifier: "redis:7"))
        #expect(throws: (any Error).self) { try Docker.removeImage("--all") }
        #expect(Docker.parseSize("512kB") == 512_000)
    }

    @Test func testSystemAndUnreadableCachesAreNotOffered() throws {
        try write("Library/Caches/familycircled/data")
        try write("Library/Caches/org.example/data")
        let locked = try write("Library/Caches/locked/data").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let names = JunkScanner(environment: env).scanEssentials().categories.flatMap(\.items).map(\.name)
        #expect(names == ["org.example"])
    }

    // MARK: Scanners

    @Test func testJunkScannerDefaultSelection() throws {
        try write("Library/Caches/org.example/data")
        try write("Library/Caches/com.apple.Safari/data")
        try write("Library/Logs/app.log")
        try write("Library/Developer/Xcode/DerivedData/Proj/x")
        try write("Library/Developer/Xcode/Archives/2026/x")
        try write(".Trash/old")
        try write("Library/Preferences/broken.plist").write(text: "pas un plist")
        let items = JunkScanner(environment: env).scan().categories.flatMap(\.items)
        func item(_ name: String) -> ScanItem? { items.first { $0.name == name } }
        #expect(item("org.example")?.selectedByDefault == true)
        #expect(item("com.apple.Safari")?.selectedByDefault == false)
        #expect(item("app.log")?.selectedByDefault == true)
        #expect(item("Proj")?.selectedByDefault == true)
        #expect(item("2026")?.selectedByDefault == false)
        #expect(item("old")?.removal == .permanent)
        #expect(item("old")?.selectedByDefault == false)
        #expect(item("broken.plist") != nil)
    }

    @Test func testUninstallerFindsRelatedFiles() throws {
        try makeApp("Demo", id: "com.acme.demo")
        try write("Library/Application Support/Demo/db")
        try write("Library/Preferences/com.acme.demo.plist")
        try write("Library/Containers/com.acme.demo/Data/x")
        try write("Library/Caches/com.other.tool/x")
        let category = try #require(ApplicationScanner(environment: env).scanUninstaller().categories.first)
        #expect(category.title == "Demo")
        #expect(category.items.count == 4)
        #expect(category.items.allSatisfy { !$0.selectedByDefault })
    }

    @Test func testLeftoversIgnoreInstalledVendorsAndApple() throws {
        try makeApp("Demo", id: "com.acme.demo")
        try write("Library/Caches/com.acme.helper/x")
        try write("Library/Caches/com.apple.Music/x")
        try write("Library/Caches/com.gone.app/x")
        try write("Library/Preferences/com.gone.other.plist")
        try write("Library/Caches/NotBundleID/x")
        try write("Downloads/setup.dmg")
        let result = ApplicationScanner(environment: env).scanLeftovers()
        #expect(Set(result.categories[0].items.map(\.name)) == ["com.gone.app", "com.gone.other.plist"])
        #expect(result.categories[1].items.map(\.name) == ["setup.dmg"])
    }

    @Test func testClutterFindsDuplicatesAndLargeFiles() throws {
        try write("Documents/a.bin", bytes: 2_000_000, seed: 7)
        try write("Documents/b.bin", bytes: 2_000_000, seed: 7)
        try write("Documents/c.bin", bytes: 2_000_000, seed: 8)
        try write("Library/ignored.bin", bytes: 2_000_000, seed: 7)
        let original = home.appendingPathComponent("Documents/a.bin")
        let link = home.appendingPathComponent("Documents/hard.bin")
        try FileManager.default.linkItem(at: original, to: link)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: original.path)
        let scanner = ClutterScanner(environment: env, largeFileMinimum: 1_000_000)
        let result = scanner.scan()
        let duplicates = try #require(result.categories.first { $0.id == "duplicates" })
        #expect(duplicates.items.map(\.name) == ["b.bin"])
        let large = try #require(result.categories.first { $0.id == "large" })
        #expect(!(large.items.contains { $0.name == "ignored.bin" }))
    }

    @Test func testPerformanceFlagsBrokenAgents() throws {
        let plist: [String: Any] = ["Label": "com.broken.agent", "Program": "/nonexistent/tool"]
        let url = try write("Library/LaunchAgents/com.broken.agent.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        let item = try #require(PerformanceScanner(environment: env).scan().categories.first?.items.first)
        #expect(item.launchLabel == "com.broken.agent")
        #expect(item.detail.hasPrefix("Cassé"))
    }

    @Test func testSpaceScannerAggregatesAndDoesNotFollowSymlinks() throws {
        try write("disk/a/one", bytes: 16384)
        try write("disk/b", bytes: 8192)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("disk/loop"), withDestinationURL: home)
        let node = SpaceScanner().scan(home.appendingPathComponent("disk"))
        #expect(node.children.first?.name == "a")
        #expect(node.size == node.children.reduce(0) { $0 + $1.size })
        #expect(node.size < 100_000)
    }

    @Test func testTreemapCoversRectWithoutOverlap() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = Treemap.layout(values: [60, 30, 20, 10, 5, 1], in: rect)
        #expect(rects.count == 6)
        #expect(abs(rects.reduce(0) { $0 + $1.width * $1.height } - 240_000) <= 1)
        for (index, first) in rects.enumerated() {
            for second in rects[(index + 1)...] {
                let overlap = first.intersection(second)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func testToolIdentifierKeepsScopedName() throws {
        let id = try #require(CommandLineTools.Identifier(encoded: "npm:@anthropic-ai/claude-code"))
        #expect(id.source == .npm && id.name == "@anthropic-ai/claude-code")
        #expect(id.encoded == "npm:@anthropic-ai/claude-code")
        #expect(CommandLineTools.Identifier(encoded: "pip:x") == nil)
    }

    @Test func testToolNameValidation() {
        for name in ["ripgrep", "node@24", "@anthropic-ai/claude-code", "arthur-ficial/tap/apfel-gui", "graphifyy"] {
            #expect(CommandLineTools.isValid(name: name))
        }
        for name in ["--force", "-g", "a b", "a;rm", "", "../x", "ripgrep\n"] {
            #expect(!CommandLineTools.isValid(name: name))
        }
    }

    @Test func testCommandEnvironmentDisablesAutoremove() {
        let environment = CommandLineTools.commandEnvironment(
            from: ["HOME": "/Users/x", "PATH": "/ailleurs"], searchDirectories: ["/opt/homebrew/bin"]
        )
        #expect(environment["HOMEBREW_NO_AUTOREMOVE"] == "1")
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(environment["HOME"] == "/Users/x")
        #expect(CommandLineTools.commandEnvironment(from: ["HOMEBREW_NO_AUTOREMOVE": "0"], searchDirectories: [])["HOMEBREW_NO_AUTOREMOVE"] == "1")
    }

    @Test func testCaskRunsThroughBrew() {
        #expect(CommandLineTools.executableName(for: .cask) == "brew")
        #expect(CommandLineTools.executableName(for: .brew) == "brew")
        #expect(CommandLineTools.executableName(for: .npm) == "npm")
        #expect(CommandLineTools.executableName(for: .uv) == "uv")
    }

    @Test func testUninstallCommandDropsVanishedDependencies() throws {
        try write("brew/Cellar/graphviz/1/f")
        try write("brew/Cellar/gts/1/f")
        try write("brew/Cellar/apfel/1/f")
        let prefix = home.appendingPathComponent("brew")
        let brew = CommandLineTools.Identifier(source: .brew, name: "graphviz")
        let command = try CommandLineTools.uninstallCommand(brew, extra: ["gts", "disparu", "user/tap/apfel", "user/tap/parti"], homebrewPrefix: prefix)
        #expect(command == ["uninstall", "--", "graphviz", "gts", "user/tap/apfel"])
    }

    @Test func testUninstallCommandKeepsMissingToolItself() throws {
        let brew = CommandLineTools.Identifier(source: .brew, name: "disparu")
        let command = try CommandLineTools.uninstallCommand(brew, extra: [], homebrewPrefix: home.appendingPathComponent("brew"))
        #expect(command == ["uninstall", "--", "disparu"])
    }

    @Test func testUninstallCommandStillRejectsInvalidExtras() {
        let brew = CommandLineTools.Identifier(source: .brew, name: "graphviz")
        #expect(throws: (any Error).self) {
            try CommandLineTools.uninstallCommand(brew, extra: ["--force"], homebrewPrefix: self.home)
        }
    }

    @Test func testUninstallCommandFiltersOnlyHomebrewFormulae() throws {
        let npm = CommandLineTools.Identifier(source: .npm, name: "omniroute")
        let command = try CommandLineTools.uninstallCommand(npm, extra: ["x"], homebrewPrefix: home)
        #expect(command == ["uninstall", "-g", "--", "omniroute", "x"])
    }

    @Test func testUninstallArguments() throws {
        let brew = CommandLineTools.Identifier(source: .brew, name: "graphviz")
        #expect(try CommandLineTools.uninstallArguments(brew, extra: ["gts"]) == ["uninstall", "--", "graphviz", "gts"])
        let cask = CommandLineTools.Identifier(source: .cask, name: "1password-cli")
        #expect(try CommandLineTools.uninstallArguments(cask, extra: []) == ["uninstall", "--cask", "--", "1password-cli"])
        let npm = CommandLineTools.Identifier(source: .npm, name: "omniroute")
        #expect(try CommandLineTools.uninstallArguments(npm, extra: []) == ["uninstall", "-g", "--", "omniroute"])
        let uv = CommandLineTools.Identifier(source: .uv, name: "graphifyy")
        #expect(try CommandLineTools.uninstallArguments(uv, extra: []) == ["tool", "uninstall", "--", "graphifyy"])
        #expect(throws: (any Error).self) { try CommandLineTools.uninstallArguments(brew, extra: ["--force"]) }
    }

    @Test func testUninstallRejectsMalformedIdentifierBeforeAnyProcess() {
        for identifier in ["", "graphviz", "npm:", "npm:--force", "brew:a b", "pip:x"] {
            #expect(throws: (any Error).self) { try CommandLineTools.uninstall(identifier: identifier, arguments: []) }
        }
        #expect(throws: (any Error).self) {
            try CommandLineTools.uninstall(identifier: "brew:graphviz", arguments: ["--ignore-dependencies"])
        }
    }

    @Test func testFailureMessageReportsTimeoutAndEmptyOutput() {
        let timeout = CommandLineTools.failureMessage(.init(data: Data(), status: 15, timedOut: true))
        #expect(timeout?.contains("incomplet") == true)
        let silent = CommandLineTools.failureMessage(.init(data: Data(), status: 3, timedOut: false))
        #expect(silent?.contains("3") == true)
        let printed = CommandLineTools.failureMessage(.init(data: Data("boom".utf8), status: 1, timedOut: false))
        #expect(printed == "boom")
        #expect(CommandLineTools.failureMessage(.init(data: Data(), status: 0, timedOut: false)) == nil)
    }

    @Test func testLaunchReportsTimeoutAndStopsProcess() throws {
        let started = Date()
        let result = try #require(CommandLineTools.launch("/bin/sleep", ["30"], timeout: 0.3, grace: 0.3, mergeErrors: true))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
        let quick = try #require(CommandLineTools.launch("/bin/sleep", ["0"], timeout: 5, mergeErrors: true))
        #expect(!quick.timedOut && quick.status == 0)
    }

    @Test func testLaunchDoesNotHangWhenChildHoldsPipe() throws {
        let started = Date()
        let result = try #require(CommandLineTools.launch(
            "/bin/sh", ["-c", "echo hi; /bin/sleep 8 & exit 0"], timeout: 5, grace: 0.3, mergeErrors: true
        ))
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(!result.timedOut && result.status == 0)
        #expect(String(decoding: result.data, as: UTF8.self).hasPrefix("hi"))
    }

    private func formula(_ name: String, _ deps: [String] = [], onRequest: Bool = false) -> HomebrewFormula {
        HomebrewFormula(name: name, version: "1", onRequest: onRequest, outdated: false, dependencies: deps)
    }

    @Test func testExclusiveDependencies() {
        let all = [
            formula("graphviz", ["gts", "librsvg"], onRequest: true),
            formula("gts", ["netpbm"]), formula("netpbm"),
            formula("librsvg"), formula("other", ["librsvg"], onRequest: true),
            formula("kept"), formula("tool", ["kept2"], onRequest: true), formula("kept2", onRequest: true),
        ]
        #expect(Set(CommandLineToolParsers.exclusiveDependencies(of: "graphviz", in: all)) == ["gts", "netpbm"])
        #expect(CommandLineToolParsers.exclusiveDependencies(of: "tool", in: all).isEmpty)
    }

    @Test func testTopLevelHidesDependencies() {
        let all = [formula("a", ["b"], onRequest: true), formula("b", onRequest: true), formula("c")]
        #expect(CommandLineToolParsers.topLevel(all).map(\.name) == ["a"])
    }

    @Test func testHomebrewParsing() throws {
        let json = """
        {"formulae":[
          {"full_name":"user/tap/foo","outdated":true,"installed":[{"version":"1.2","installed_on_request":true,
            "runtime_dependencies":[{"full_name":"bar"},{"full_name":"baz"}]}]},
          {"full_name":"ghost","outdated":false,"installed":[]}
        ],"casks":[{"token":"app","version":"3.0","outdated":true,"installed":"2.0"}]}
        """
        let parsed = try #require(CommandLineToolParsers.homebrew(Data(json.utf8)))
        #expect(parsed.formulae == [HomebrewFormula(name: "user/tap/foo", version: "1.2", onRequest: true,
                                                    outdated: true, dependencies: ["bar", "baz"])])
        #expect(parsed.casks == [InstalledPackage(name: "app", version: "2.0", latest: "3.0")])
        #expect(CommandLineToolParsers.homebrew(Data("pas du json".utf8)) == nil)
    }

    @Test func testNpmParsing() throws {
        let json = #"{"name":"lib","dependencies":{"@a/b":{"version":"1.0.0"},"c":{"version":"2.0.0"}}}"#
        let packages = try #require(CommandLineToolParsers.npmPackages(Data(json.utf8)))
        #expect(packages.contains(InstalledPackage(name: "@a/b", version: "1.0.0", latest: nil)))
        #expect(packages.count == 2)
        #expect(CommandLineToolParsers.npmPackages(Data("{}".utf8))?.isEmpty == true)
        #expect(CommandLineToolParsers.npmPackages(Data("oops".utf8)) == nil)
        #expect(CommandLineToolParsers.npmOutdated(Data(#"{"x":{"current":"1","latest":"2"}}"#.utf8)) == ["x": "2"])
        #expect(CommandLineToolParsers.npmOutdated(Data("{}".utf8)) == [:])
        #expect(CommandLineToolParsers.npmOutdated(Data("oops".utf8)) == nil)
    }

    @Test func testUvParsing() {
        let text = """
        graphifyy v0.9.95 [latest: 0.9.100]
        - graphify
        - graphify-mcp
        specify-cli v1.2.3 [latest: 1.2.5]
        - specify
        """
        #expect(CommandLineToolParsers.uvOutdated(text) == ["graphifyy": "0.9.100", "specify-cli": "1.2.5"])
        let tools = CommandLineToolParsers.uvTools(text)
        #expect(tools.map(\.name) == ["graphifyy", "specify-cli"])
        #expect(tools.map(\.version) == ["0.9.95", "1.2.3"])
        let withPaths = "graphifyy v0.9.95 (/Users/x/.local/share/uv/tools/graphifyy)\n- graphify (/Users/x/.local/bin/graphify)"
        #expect(CommandLineToolParsers.uvTools(withPaths).map(\.version) == ["0.9.95"])
        #expect(CommandLineToolParsers.uvTools("").isEmpty)
        #expect(CommandLineToolParsers.uvOutdated("").isEmpty)
    }

    // MARK: Scanner d'outils en ligne de commande

    private static let brewJSON = """
    {"formulae":[
     {"full_name":"ripgrep","outdated":false,"installed":[{"version":"14.1","installed_on_request":true,"runtime_dependencies":[{"full_name":"pcre2"}]}]},
     {"full_name":"pcre2","outdated":false,"installed":[{"version":"10.4","installed_on_request":false,"runtime_dependencies":[]}]},
     {"full_name":"arthur-ficial/tap/apfel-gui","outdated":false,"installed":[{"version":"1.0","installed_on_request":true,"runtime_dependencies":[]}]},
     {"full_name":"node@24","outdated":false,"installed":[{"version":"24.1","installed_on_request":true,"runtime_dependencies":[]}]},
     {"full_name":"python@3.14","outdated":false,"installed":[{"version":"3.14","installed_on_request":true,"runtime_dependencies":[]}]},
     {"full_name":"openjdk@21","outdated":false,"installed":[{"version":"21","installed_on_request":true,"runtime_dependencies":[]}]},
     {"full_name":"gh","outdated":false,"installed":[{"version":"2.0","installed_on_request":true,"runtime_dependencies":[]}]},
     {"full_name":"rea-agents","outdated":false,"installed":[{"version":"1.0","installed_on_request":true,"runtime_dependencies":[]}]},
     {"full_name":"uv","outdated":false,"installed":[{"version":"0.5","installed_on_request":true,"runtime_dependencies":[]}]}
    ],"casks":[]}
    """
    private static let npmJSON = #"{"dependencies":{"npm":{"version":"10.0.0"},"corepack":{"version":"0.30.0"},"omniroute":{"version":"3.8.52"}}}"#
    private static let npmOutdatedJSON = #"{"omniroute":{"current":"3.8.52","latest":"3.9.0"}}"#
    private static let uvText = "graphifyy v0.9.95 (/x/graphifyy)\n- graphify (/x/bin/graphify)\n"
    private static let uvOutdatedText = "graphifyy v0.9.95 [latest: 0.9.100]\n- graphify\n"

    private func toolRunner(
        npmOutdatedFails: Bool = false, uv: Bool = true
    ) -> CommandLineTools.Runner {
        { source, arguments, _ in
            func out(_ text: String, _ status: Int32 = 0) -> Docker.Output { Docker.Output(data: Data(text.utf8), status: status) }
            switch (source, arguments.joined(separator: " ")) {
            case (.brew, "info --json=v2 --installed"): return out(CoreTests.brewJSON)
            case (.npm, "ls -g --depth=0 --json"): return out(CoreTests.npmJSON)
            case (.npm, "outdated -g --json"): return npmOutdatedFails ? nil : Docker.Output(data: Data(CoreTests.npmOutdatedJSON.utf8), status: 1)
            case (.uv, "tool list --show-paths"): return uv ? out(CoreTests.uvText) : nil
            case (.uv, "tool list --outdated"): return uv ? out(CoreTests.uvOutdatedText) : nil
            default: return nil
            }
        }
    }

    private func toolScan(_ run: @escaping CommandLineTools.Runner) throws -> ScanResult {
        for folder in ["brew/Cellar/ripgrep", "brew/Cellar/pcre2", "brew/Cellar/apfel-gui"] {
            try write("\(folder)/file.bin", bytes: 20_000)
        }
        let locations = CommandLineToolScanner.Locations(
            homebrew: home.appendingPathComponent("brew"), npmRoot: home.appendingPathComponent("npm"),
            uvTools: home.appendingPathComponent("uv")
        )
        return CommandLineToolScanner(environment: env, run: run, locations: locations).scan()
    }

    private func toolItem(_ result: ScanResult, _ category: String, _ label: String) -> ScanItem? {
        result.categories.first { $0.id == category }?.items.first { $0.launchLabel == label }
    }

    @Test func testToolScanListsTopLevelOnly() throws {
        let result = try toolScan(toolRunner())
        #expect(result.categories.map(\.id) == ["cli.brew", "cli.npm", "cli.uv"])
        #expect(result.categories.map(\.title) == ["Homebrew", "npm", "uv"])
        #expect(toolItem(result, "cli.brew", "brew:pcre2") == nil)
        let ripgrep = try #require(toolItem(result, "cli.brew", "brew:ripgrep"))
        #expect(ripgrep.removalArguments == ["pcre2"])
        #expect(ripgrep.size > 2 * 8192)
        #expect(ripgrep.size == FileSystem.allocatedSize(of: home.appendingPathComponent("brew/Cellar/ripgrep"))
            + FileSystem.allocatedSize(of: home.appendingPathComponent("brew/Cellar/pcre2")))
        #expect(ripgrep.detail.contains("14.1") && ripgrep.detail.contains("emporte 1 dépendance"))
        #expect(!ripgrep.selectedByDefault)
        #expect(ripgrep.removal == .commandLineTool)
        #expect(ripgrep.reinstallCommand == "brew install ripgrep")
    }

    @Test func testToolScanResolvesTapFolder() throws {
        let result = try toolScan(toolRunner())
        let item = try #require(toolItem(result, "cli.brew", "brew:arthur-ficial/tap/apfel-gui"))
        #expect(item.url == home.appendingPathComponent("brew/Cellar/apfel-gui"))
        #expect(item.size > 0)
        let missing = try #require(toolItem(result, "cli.brew", "brew:gh"))
        #expect(missing.size == 0)
    }

    @Test func testToolScanLocksCorePackages() throws {
        let result = try toolScan(toolRunner())
        #expect(try #require(toolItem(result, "cli.npm", "npm:npm")).locked)
        #expect(try #require(toolItem(result, "cli.npm", "npm:corepack")).locked)
        #expect(try !#require(toolItem(result, "cli.npm", "npm:omniroute")).locked)
        #expect(try #require(toolItem(result, "cli.brew", "brew:uv")).locked)
    }

    @Test func testToolScanWarnsForRuntimes() throws {
        let result = try toolScan(toolRunner())
        let node = try #require(toolItem(result, "cli.brew", "brew:node@24"))
        #expect(node.detail.contains("omniroute"))
        #expect(!node.detail.contains("corepack"))
        for label in ["brew:python@3.14", "brew:openjdk@21", "brew:gh", "brew:rea-agents"] {
            #expect(try #require(toolItem(result, "cli.brew", label)).detail.contains("Attention"))
        }
    }

    @Test func testToolScanShowsUpdates() throws {
        let result = try toolScan(toolRunner())
        let uv = try #require(toolItem(result, "cli.uv", "uv:graphifyy"))
        #expect(uv.detail.contains("0.9.100"))
        #expect(uv.reinstallCommand == "uv tool install graphifyy==0.9.95")
        let npm = try #require(toolItem(result, "cli.npm", "npm:omniroute"))
        #expect(npm.detail.contains("3.9.0"))
        #expect(npm.reinstallCommand == "npm install -g omniroute@3.8.52")
    }

    @Test func testToolScanKeepsListWhenOutdatedFails() throws {
        let result = try toolScan(toolRunner(npmOutdatedFails: true))
        let npm = try #require(toolItem(result, "cli.npm", "npm:omniroute"))
        #expect(!npm.detail.contains("mise à jour"))
    }

    @Test func testToolScanAcceptsNpmOutdatedStatusOne() throws {
        let result = try toolScan(toolRunner())
        #expect(try #require(toolItem(result, "cli.npm", "npm:omniroute")).detail.contains("mise à jour 3.9.0"))
    }

    @Test func testToolScanSkipsMissingSources() throws {
        let result = try toolScan(toolRunner(uv: false))
        #expect(result.categories.map(\.id) == ["cli.brew", "cli.npm"])
    }
}

private extension URL {
    func write(text: String) throws { try text.write(to: self, atomically: true, encoding: .utf8) }
}
