import Foundation
import Testing
@testable import MacCleanerCore

/// Touchent le vrai système : MACCLEANER_INTEGRATION=1 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACCLEANER_INTEGRATION"] == "1"))
struct RealSystemTests {
    @Test func testMoveToRealTrash() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("maccleaner-test-\(UUID().uuidString)")
        try Data("test".utf8).write(to: file)
        let location = try #require(try SystemFileRemover().moveToTrash(file))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: location.path))
        try FileManager.default.removeItem(at: location)
    }

    @Test func testPermanentDeletionThroughRunner() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".Trash/old")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: file)
        let env = ScanEnvironment(home: home, applicationDirectories: [])
        let report = CleanupRunner(environment: env).run([ScanItem(url: file, size: 4, removal: .permanent)])
        #expect(report.removed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func testUnloadRealLaunchAgent() throws {
        let label = "local.maccleaner.test.\(UUID().uuidString)"
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        let content: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sleep", "60"], "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0).write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }
        let domain = "gui/\(getuid())"
        #expect(launchctl(["bootstrap", domain, plist.path]) == 0)
        #expect(launchctl(["print", "\(domain)/\(label)"]) == 0)
        try SystemFileRemover().unloadLaunchAgent(label: label)
        #expect(launchctl(["print", "\(domain)/\(label)"]) != 0)
    }

    @Test func testCancellingRealHomeScanIsQuick() async throws {
        let progress = ScanProgress()
        let scan = Task.detached {
            ScanProgress.$current.withValue(progress) { ClutterScanner(environment: ScanEnvironment()).scan() }
        }
        try await Task.sleep(for: .seconds(4))
        let start = ContinuousClock.now
        progress.cancel()
        _ = await scan.value
        let delay = ContinuousClock.now - start
        #expect(delay < .seconds(2), "\(delay)")
    }

    @Test func testKeychainRoundTrip() throws {
        let keychain = Keychain(service: "local.maccleaner.test.\(UUID().uuidString)")
        defer { keychain.delete("account") }
        try keychain.write(Data("v1".utf8), account: "account")
        try keychain.write(Data("v2".utf8), account: "account")
        #expect(keychain.read("account") == Data("v2".utf8))
        #expect(keychain.contains("account"))
        keychain.delete("account")
        #expect(keychain.read("account") == nil)
    }

    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
