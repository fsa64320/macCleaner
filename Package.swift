// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacCleaner", targets: ["MacCleaner"])],
    targets: [
        .target(name: "MacCleanerCore"),
        .executableTarget(name: "MacCleaner", dependencies: ["MacCleanerCore"]),
        .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"]),
    ]
)
