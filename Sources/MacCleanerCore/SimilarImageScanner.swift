import Foundation
import Vision

public struct SimilarImageScanner: Sendable {
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff"]
    private let env: ScanEnvironment
    private let threshold: Float
    private let limit: Int
    private let minimumSize: Int64

    public init(environment: ScanEnvironment, threshold: Float = 0.35, limit: Int = 3000, minimumSize: Int64 = 50_000) {
        env = environment
        self.threshold = threshold
        self.limit = limit
        self.minimumSize = minimumSize
    }

    public func scan() -> ScanResult {
        let images = candidates()
        var prints: [(url: URL, size: Int64, print: VNFeaturePrintObservation)] = []
        for (index, url) in images.enumerated() {
            if ScanProgress.shouldStop { return ScanResult() }
            ScanProgress.current?.update("Lecture de \(url.lastPathComponent)", fraction: Double(index) / Double(images.count))
            if let print = Self.featurePrint(of: url) {
                prints.append((url, FileSystem.allocatedSize(of: url), print))
            }
        }
        var parents = Array(prints.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }
        for first in prints.indices {
            if ScanProgress.shouldStop { return ScanResult() }
            ScanProgress.current?.update("Comparaison des images", fraction: Double(first) / Double(max(prints.count, 1)))
            for second in prints.indices where second > first {
                var distance: Float = .infinity
                guard (try? prints[first].print.computeDistance(&distance, to: prints[second].print)) != nil else { continue }
                if distance <= threshold { parents[root(second)] = root(first) }
            }
        }
        var items: [ScanItem] = []
        for group in Dictionary(grouping: prints.indices, by: root).values where group.count > 1 {
            let sorted = group.sorted { prints[$0].size > prints[$1].size }
            let keeper = prints[sorted[0]].url
            items += sorted.dropFirst().map {
                ScanItem(url: prints[$0].url, detail: "Proche de \(keeper.lastPathComponent), conservée hors liste", size: prints[$0].size)
            }
        }
        var notes = ""
        if images.count >= limit { notes = " Limité à \(limit) images." }
        return ScanResult(categories: [
            ScanCategory(id: "similar-images", title: "Images similaires", summary: "Comparaison visuelle : vérifiez avant de retirer.\(notes)", items: items),
        ])
    }

    private func candidates() -> [URL] {
        var found: [URL] = []
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .ubiquitousItemDownloadingStatusKey]
        for folder in ["Pictures", "Desktop", "Documents", "Downloads"] {
            guard let walker = FileManager.default.enumerator(
                at: env.home.appendingPathComponent(folder), includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in walker {
                if ScanProgress.shouldStop || found.count >= limit { return found }
                guard Self.extensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: keys),
                      Int64(values.totalFileAllocatedSize ?? 0) >= minimumSize else { continue }
                if let status = values.ubiquitousItemDownloadingStatus, status != .current { continue }
                found.append(url)
            }
        }
        return found
    }

    static func featurePrint(of url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(url: url).perform([request])
        return request.results?.first
    }
}
