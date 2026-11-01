import Foundation

/// Canal entre une opération synchrone et l'interface. Transmis par task-local
/// pour que les scanners et les calculs de taille n'aient pas à le propager.
public final class ScanProgress: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var message = ""
        public var fraction: Double?

        public init(message: String = "", fraction: Double? = nil) {
            self.message = message
            self.fraction = fraction
        }
    }

    @TaskLocal public static var current: ScanProgress?

    private let lock = NSLock()
    private var state = Snapshot()
    private var cancelled = false

    public init() {}

    public var snapshot: Snapshot {
        lock.withLock { state }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public func update(_ message: String, fraction: Double? = nil) {
        lock.withLock { state = Snapshot(message: message, fraction: fraction) }
    }
}

extension ScanProgress {
    static var shouldStop: Bool { current?.isCancelled == true }
}
