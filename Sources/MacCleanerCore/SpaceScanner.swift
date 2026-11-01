import CoreGraphics
import Foundation

public struct SpaceNode: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let isDirectory: Bool
    public let children: [SpaceNode]

    public var name: String { url.lastPathComponent }
}

public struct SpaceScanner: Sendable {
    private let maxDepth: Int
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey]

    public init(maxDepth: Int = 5) { self.maxDepth = maxDepth }

    public func scan(_ root: URL) -> SpaceNode {
        let volume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        return node(for: root, depth: 0, volume: volume)
    }

    private func node(for url: URL, depth: Int, volume: NSObject?) -> SpaceNode {
        let values = try? url.resourceValues(forKeys: Self.keys)
        let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
        guard isDirectory else {
            return SpaceNode(url: url, size: FileSystem.allocatedSize(of: url), isDirectory: false, children: [])
        }
        guard depth < maxDepth, !Task.isCancelled else {
            return SpaceNode(url: url, size: FileSystem.allocatedSize(of: url), isDirectory: true, children: [])
        }
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(Self.keys))) ?? []
        let children = entries
            .filter { ((try? $0.resourceValues(forKeys: Self.keys))?.volumeIdentifier as? NSObject) == volume }
            .map { node(for: $0, depth: depth + 1, volume: volume) }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        return SpaceNode(url: url, size: children.reduce(0) { $0 + $1.size }, isDirectory: true, children: children)
    }
}

public enum Treemap {
    /// Disposition « squarified » : `values` doit être trié par ordre décroissant.
    public static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        var index = 0
        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [areas[index]]
            var next = index + 1
            while next < areas.count, worst(row + [areas[next]], side: side) <= worst(row, side: side) {
                row.append(areas[next])
                next += 1
            }
            result += place(row, in: &remaining)
            index = next
        }
        return result
    }

    private static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else { return .infinity }
        return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }

    private static func place(_ row: [Double], in remaining: inout CGRect) -> [CGRect] {
        let sum = row.reduce(0, +)
        var rects: [CGRect] = []
        if remaining.width >= remaining.height {
            let width = CGFloat(sum) / max(remaining.height, .leastNonzeroMagnitude)
            var y = remaining.minY
            for area in row {
                let height = CGFloat(area) / max(width, .leastNonzeroMagnitude)
                rects.append(CGRect(x: remaining.minX, y: y, width: width, height: height))
                y += height
            }
            remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(remaining.width - width, 0), height: remaining.height)
        } else {
            let height = CGFloat(sum) / max(remaining.width, .leastNonzeroMagnitude)
            var x = remaining.minX
            for area in row {
                let width = CGFloat(area) / max(height, .leastNonzeroMagnitude)
                rects.append(CGRect(x: x, y: remaining.minY, width: width, height: height))
                x += width
            }
            remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(remaining.height - height, 0))
        }
        return rects
    }
}
