import Darwin
import Foundation

/// One running process owned by the current user.
nonisolated struct ProcessEntry: Sendable, Equatable {
    let pid: pid_t
    let parent: pid_t
    let path: String
    /// Physical footprint in bytes, the figure Activity Monitor calls "Memory".
    let footprint: UInt64
    /// Total CPU time used so far, in nanoseconds.
    let cpuTime: UInt64

    var name: Substring {
        path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path[...]
    }

    /// The app this process belongs to, so helpers are counted with their app.
    var groupName: String {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return String(name)
    }
}

nonisolated enum ProcessSnapshot {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Lists the user's processes. Processes owned by other users (root daemons,
    /// WindowServer) don't report usage without privileges and are left out.
    static func capture() -> [ProcessEntry] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }

        var pathBuffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            var usage = rusage_info_v4()
            let usageStatus = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard usageStatus == 0 else { continue }

            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { continue }

            let pathLength = Int(proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)))
            guard pathLength > 0 else { continue }

            let ticks = usage.ri_user_time + usage.ri_system_time
            entries.append(ProcessEntry(
                pid: pid,
                parent: pid_t(info.pbi_ppid),
                path: String(decoding: pathBuffer[..<pathLength], as: UTF8.self),
                footprint: usage.ri_phys_footprint,
                cpuTime: ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
            ))
        }
        return entries
    }
}
