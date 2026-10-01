import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// The system-level pieces of a keep-awake session.
///
/// Closing the lid sleeps a Mac regardless of ordinary sleep assertions. The only
/// switch that overrides it is `pmset disablesleep`, which needs root, so the app
/// relies on a sudoers rule that allows exactly those two commands without a password.
nonisolated enum PowerControl {
    private static let pmset = "/usr/bin/pmset"
    private static let sudo = "/usr/bin/sudo"
    private static let allowCommand = "\(pmset) disablesleep 1"
    private static let restoreCommand = "\(pmset) disablesleep 0"

    // MARK: Lid-closed sleep

    static func hasLidSleepPermission() -> Bool {
        let rules = Shell.run(sudo, ["-n", "-l"]).output
        return rules.contains("NOPASSWD") && rules.contains(allowCommand) && rules.contains(restoreCommand)
    }

    @discardableResult
    static func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        Shell.run(sudo, ["-n", pmset, "disablesleep", disabled ? "1" : "0"]).succeeded
    }

    static func isLidSleepDisabled() -> Bool {
        Shell.run(pmset, ["-g"]).output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.first == "SleepDisabled" && fields.last == "1"
        }
    }

    /// Installs the sudoers rule. macOS shows its own administrator prompt.
    /// The rule is written and checked by root before it replaces anything.
    @concurrent
    static func installLidSleepPermission() async -> Bool {
        let user = NSUserName()
        guard user.wholeMatch(of: /[A-Za-z0-9_.\-]+/) != nil else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: \(allowCommand), \(restoreCommand)"
        let staged = "/private/etc/sudoers.d/.agentbar.new"
        let installed = "/private/etc/sudoers.d/agentbar"
        let command = """
            umask 227; /usr/bin/printf '%s\\n' '# AgentBar: keep the Mac awake with the lid closed' '\(rule)' > \(staged) \
            && /usr/sbin/visudo -cf \(staged) && /bin/mv -f \(staged) \(installed) \
            || { /bin/rm -f \(staged); exit 1; }
            """
        let prompt = "AgentBar needs permission to keep the Mac awake with the lid closed."
        let script = "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
        return Shell.run("/usr/bin/osascript", ["-e", script]).succeeded
    }

    /// Restores normal sleep if the app dies mid-session, so a crash can't leave
    /// the Mac awake in a bag.
    ///
    /// The watchdog waits on a pipe that only this app holds open. Waiting costs
    /// nothing, and the pipe closes the moment the app is gone, however it died.
    struct Watchdog {
        private let process: Process
        private let lifeline: Pipe

        static func start() -> Watchdog? {
            let lifeline = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "read _; exec \(sudo) -n \(restoreCommand)"]
            process.standardInput = lifeline
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                return Watchdog(process: process, lifeline: lifeline)
            } catch {
                return nil
            }
        }

        /// Call when the session ends normally, after sleep has been restored.
        func stop() {
            process.terminate()
        }
    }

    static func sleepNow() {
        Shell.run(pmset, ["sleepnow"])
    }

    // MARK: Idle sleep

    static func holdIdleSleepAssertion() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AgentBar keep-awake session" as CFString,
            &id
        )
        return status == kIOReturnSuccess ? id : nil
    }

    static func releaseAssertion(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }

    // MARK: Sensors

    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool ?? false
    }

    /// A closed lid with a display still attached is a desk setup, where sleeping
    /// the Mac would take it away from whoever is using it.
    static func isPutAway() -> Bool {
        isLidClosed() && !hasExternalDisplay()
    }

    private static func hasExternalDisplay() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    struct Battery: Sendable, Equatable {
        let percent: Int
        let onAC: Bool
    }

    static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = info[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { continue }
            let onAC = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return Battery(percent: current * 100 / capacity, onAC: onAC)
        }
        return nil
    }

    static var isRunningHot: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        default: false
        }
    }
}
