import Darwin
import Foundation

public struct SystemStats: Sendable {
    public let diskTotal: Int64
    public let diskAvailable: Int64
    public let memoryTotal: Int64
    public let memoryUsed: Int64
    public let loadAverage: Double
    public let coreCount: Int
    public let uptime: TimeInterval

    public static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SystemStats {
        let volume = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        return SystemStats(
            diskTotal: Int64(volume?.volumeTotalCapacity ?? 0),
            diskAvailable: volume?.volumeAvailableCapacityForImportantUsage ?? 0,
            memoryTotal: Int64(ProcessInfo.processInfo.physicalMemory),
            memoryUsed: usedMemory(),
            loadAverage: load[0],
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func usedMemory() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return pages * Int64(sysconf(_SC_PAGESIZE))
    }
}
