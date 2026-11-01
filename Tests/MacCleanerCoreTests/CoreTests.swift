import CoreGraphics
import Foundation
import Testing
@testable import MacCleanerCore

final class RecordingRemover: FileRemoving, @unchecked Sendable {
    var trashed: [URL] = []
    var deleted: [URL] = []
    var unloaded: [String] = []
    func moveToTrash(_ url: URL) throws { trashed.append(url) }
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

    private func makeApp(_ name: String, id: String) throws {
        let url = try write("Apps/\(name).app/Contents/Info.plist")
        let plist = ["CFBundleIdentifier": id, "CFBundleName": name]
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
        #expect(report.freedSize == 70)
        #expect(report.failures.map(\.item.url) == [keychain])
        #expect(report.skipped.count == 2)
    }

    @Test func testRunnerWritesLog() throws {
        let cache = try write("Library/Caches/foo")
        let log = home.appendingPathComponent("logs/cleanup.log")
        _ = CleanupRunner(remover: RecordingRemover(), environment: env, logURL: log).run([ScanItem(url: cache, size: 1)])
        #expect(try String(contentsOf: log, encoding: .utf8).contains(cache.path))
    }

    // MARK: Scanners

    @Test func testJunkScannerDefaultSelection() throws {
        try write("Library/Caches/org.example/data")
        try write("Library/Caches/com.apple.Safari/data")
        try write("Library/Logs/app.log")
        try write("Library/Developer/Xcode/DerivedData/Proj/x")
        try write("Library/Developer/Xcode/Archives/2026/x")
        try write(".Trash/old")
        try write(".ollama/models/blob")
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
        #expect(item("Modèles Ollama")?.selectedByDefault == false)
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
}

private extension URL {
    func write(text: String) throws { try text.write(to: self, atomically: true, encoding: .utf8) }
}
