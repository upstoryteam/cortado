import Darwin
import Foundation
import Observation

nonisolated enum PressureLevel: Int32, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

nonisolated struct MemoryStats: Sendable, Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: PressureLevel = .normal
    /// 0 when memory is plentiful, 1 when the system has none left to give.
    /// This is the figure macOS bases its pressure level on.
    var pressureFraction: Double = 0

    private static let host = mach_host_self()

    static func current() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let page = UInt64(pageSize)
            let purgeable = UInt64(vm.purgeable_count)
            let appMemory = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), purgeable)
            stats.compressed = UInt64(vm.compressor_page_count) * page
            stats.used = (appMemory + UInt64(vm.wire_count)) * page + stats.compressed
        }

        if let swap = sysctlValue("vm.swapusage", as: xsw_usage.self) {
            stats.swapUsed = swap.xsu_used
        }
        if let raw = sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self),
           let level = PressureLevel(rawValue: raw) {
            stats.pressure = level
        }
        if let freePercent = sysctlValue("kern.memorystatus_level", as: Int32.self) {
            stats.pressureFraction = Double(100 - min(100, max(0, freePercent))) / 100
        }
        return stats
    }
}

nonisolated func sysctlValue<T>(_ name: String, as type: T.Type) -> T? {
    var size = MemoryLayout<T>.size
    return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
        guard sysctlbyname(name, buffer.baseAddress, &size, nil, 0) == 0,
              size == MemoryLayout<T>.size else { return nil }
        return buffer[0]
    }
}

/// Processes that share an app, counted together.
nonisolated struct ProcessGroup: Sendable, Equatable, Identifiable {
    let name: String
    let footprint: UInt64
    var id: String { name }

    static func top(_ limit: Int, from snapshot: [ProcessEntry]) -> [ProcessGroup] {
        var totals: [String: UInt64] = [:]
        for entry in snapshot {
            // An agent's own process is listed under the agent's name rather than its binary's.
            let name = Agent.allCases.first { $0.owns(entry) }?.displayName ?? entry.groupName
            totals[name, default: 0] += entry.footprint
        }
        return totals
            .map { ProcessGroup(name: $0.key, footprint: $0.value) }
            .sorted { ($0.footprint, $1.name) > ($1.footprint, $0.name) }
            .prefix(limit)
            .map { $0 }
    }
}

@Observable
final class MemoryMonitor {
    static let historyLimit = 200

    private(set) var stats = MemoryStats()
    private(set) var history: [Double] = []
    private(set) var topGroups: [ProcessGroup] = []

    func refresh() {
        stats = .current()
        history.append(stats.pressureFraction)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    func updateTopProcesses(from snapshot: [ProcessEntry]) {
        topGroups = ProcessGroup.top(4, from: snapshot)
    }
}
