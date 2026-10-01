import Foundation
import IOKit.pwr_mgt
import Observation

nonisolated struct StopRules: Sendable, Equatable {
    /// End the session at or below this battery percentage while unplugged.
    var batteryFloor: Int?
    var stopWhenHot: Bool
    /// How long agents have to be quiet before they count as finished.
    var agentsGrace: TimeInterval
    /// Whether a session switched on by hand also ends when agents finish.
    var endsWithAgents: Bool
}

nonisolated enum EndReason: Sendable, Equatable {
    case timer
    case stopped
    case battery(Int)
    case tooHot
    case agentsFinished
    case quit

    var note: String {
        switch self {
        case .timer: "the timer ran out"
        case .stopped: "you stopped it"
        case .battery(let percent): "battery reached \(percent)%"
        case .tooHot: "the Mac was running hot"
        case .agentsFinished: "agents finished"
        case .quit: "Cortado quit"
        }
    }
}

nonisolated struct Session: Sendable, Equatable {
    let started: Date
    /// Nil for a session with no timer.
    var end: Date?
    /// Switched on because agents were working, so it lasts as long as they do.
    var followsAgents = false
    /// The end was picked as a time of day rather than a length, so that is how it reads.
    var endsOnTheClock = false

    /// The lengths offered in the panel. Nil runs until it is switched off.
    static let lengths: [TimeInterval?] = [30 * 60, 3600, 2 * 3600, 4 * 3600, 8 * 3600, nil]

    /// How long sustained heat has to last before it ends a session.
    static let heatTolerance: TimeInterval = 60

    func endReason(
        now: Date,
        rules: StopRules,
        battery: PowerControl.Battery?,
        hotSince: Date?,
        agentsLastActive: Date?
    ) -> EndReason? {
        if let end, now >= end {
            return .timer
        }
        if let floor = rules.batteryFloor, let battery, !battery.onAC, battery.percent <= floor {
            return .battery(battery.percent)
        }
        if rules.stopWhenHot, let hotSince, now.timeIntervalSince(hotSince) >= Self.heatTolerance {
            return .tooHot
        }
        if followsAgents {
            if now >= quietEnd(agentsLastActive: agentsLastActive, grace: rules.agentsGrace) {
                return .agentsFinished
            }
        } else if rules.endsWithAgents, AgentIdleRule.isFinished(
            lastActive: agentsLastActive, sessionStart: started, grace: rules.agentsGrace, now: now
        ) {
            return .agentsFinished
        }
        return nil
    }

    /// When a session that follows agents ends if they stay quiet from here on.
    /// Switching on counts as activity, so it ends even if agents never stir again.
    func quietEnd(agentsLastActive: Date?, grace: TimeInterval) -> Date {
        max(agentsLastActive ?? started, started).addingTimeInterval(grace)
    }
}

nonisolated extension Session {
    /// End times to offer: every half hour for the next twelve, starting far
    /// enough ahead that the first one is worth choosing.
    static func untilChoices(after now: Date, calendar: Calendar = .current) -> [Date] {
        let halfHour: TimeInterval = 30 * 60
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var first = hourStart
        while first.timeIntervalSince(now) < halfHour / 2 {
            first.addTimeInterval(halfHour)
        }
        return (0..<24).map { first.addingTimeInterval(Double($0) * halfHour) }
    }
}

nonisolated extension Date {
    /// The next time the clock shows this date's hour and minute, strictly after `now`.
    func nextOccurrence(after now: Date, calendar: Calendar = .current) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: self)
        return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime) ?? now
    }
}

/// Runs keep-awake sessions: holds the lid-closed override while one is active,
/// ends it on the timer or an early-stop rule, and switches one on by itself
/// when agents start working.
@Observable
final class SessionController {
    private(set) var session: Session?
    private(set) var hasPermission = false
    private(set) var startError: String?
    private(set) var isInstallingPermission = false
    /// macOS refused to switch on for agents. It isn't tried again until they finish.
    private(set) var isHeldOff = false

    /// The three positions of the panel's control.
    enum Mode: Sendable, CaseIterable {
        case off
        /// On while agents work.
        case auto
        /// On for a length you choose.
        case on
    }

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let agents: AgentMonitor
    @ObservationIgnored private let hotspot: HotspotController
    @ObservationIgnored private var watchdog: PowerControl.Watchdog?
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var hotSince: Date?

    var isActive: Bool { session != nil }

    /// On lasts as long as its session. After that the control is back on
    /// whichever of the other two it was on before.
    var mode: Mode {
        if let session, !session.followsAgents { .on } else if settings.startWithAgents { .auto } else { .off }
    }

    /// Off, and set to switch on as soon as an agent starts working.
    var isWaitingForAgents: Bool {
        session == nil && settings.startWithAgents && hasPermission && !isHeldOff
    }

    /// The state shown beside the menu bar icon and in the panel.
    var mark: StatusIcon.Awake {
        if isActive { .on } else if isWaitingForAgents { .waiting } else { .off }
    }

    /// Whether agents can end the running session, which is when their CPU use is worth sampling.
    var watchesAgents: Bool {
        guard let session else { return false }
        return session.followsAgents || settings.stopWhenAgentsFinish
    }

    init(settings: Settings, agents: AgentMonitor, hotspot: HotspotController) {
        self.settings = settings
        self.agents = agents
        self.hotspot = hotspot
    }

    /// Call once at launch. Restores normal sleep if a previous run ended mid-session.
    func recover() {
        hasPermission = PowerControl.hasLidSleepPermission()
        if settings.sessionInProgress {
            PowerControl.setLidSleepDisabled(false)
            settings.sessionInProgress = false
            settings.lastSessionNote = "Last session was cut short because Cortado closed unexpectedly."
        }
    }

    func refreshPermission() {
        hasPermission = PowerControl.hasLidSleepPermission()
    }

    func installPermission() {
        guard !isInstallingPermission else { return }
        isInstallingPermission = true
        Task {
            _ = await PowerControl.installLidSleepPermission()
            refreshPermission()
            isInstallingPermission = false
        }
    }

    /// Starts a session, or resets the end time of the one already running.
    func start(duration: TimeInterval?, now: Date = .now) {
        begin(end: duration.map { now.addingTimeInterval($0) }, now: now)
    }

    func start(until time: Date, now: Date = .now) {
        begin(end: time.nextOccurrence(after: now), onTheClock: true, now: now)
    }

    func select(_ mode: Mode, now: Date = .now) {
        switch mode {
        case .off:
            settings.startWithAgents = false
            stop(.stopped, now: now)
        case .auto:
            settings.startWithAgents = true
            isHeldOff = false
            guard let session, !session.followsAgents else {
                tick(now: now)
                return
            }
            // Agents still at it take the session over, rather than it stopping and starting again.
            if agentsUnfinished(now: now) {
                begin(Session(started: session.started, end: nil, followsAgents: true))
            } else {
                stop(.stopped, now: now)
            }
        case .on:
            start(duration: settings.defaultLength, now: now)
        }
    }

    func stop(_ reason: EndReason, now: Date = .now) {
        guard session != nil else { return }
        session = nil
        hotSince = nil

        PowerControl.setLidSleepDisabled(false)
        settings.sessionInProgress = false
        watchdog?.stop()
        watchdog = nil
        if let assertion {
            PowerControl.releaseAssertion(assertion)
            self.assertion = nil
        }
        hotspot.sessionEnded()

        let time = now.formatted(date: .omitted, time: .shortened)
        settings.lastSessionNote = reason == .stopped ? nil : "Turned off at \(time): \(reason.note)."

        // With the lid shut nothing else will put the Mac to sleep until it is opened and closed again.
        if reason != .stopped, reason != .quit, PowerControl.isPutAway() {
            PowerControl.sleepNow()
        }
    }

    func tick(now: Date = .now) {
        let agentsLastActive = agents.latestActivity(among: settings.watchedAgents)
        guard let session else {
            startForAgents(lastActive: agentsLastActive, now: now)
            return
        }
        // Checked on every tick, because whatever wakes the display lights it again.
        if PowerControl.isLitUnderLid() {
            PowerControl.sleepDisplay()
        }
        if PowerControl.isRunningHot {
            hotSince = hotSince ?? now
        } else {
            hotSince = nil
        }
        let reason = session.endReason(
            now: now,
            rules: settings.stopRules,
            battery: PowerControl.battery(),
            hotSince: hotSince,
            agentsLastActive: agentsLastActive
        )
        guard let reason else { return }
        // A timer that ran out under working agents would only be switched straight
        // back on, after putting a closed Mac to sleep in between.
        if reason == .timer, settings.startWithAgents, AgentIdleRule.isWorking(lastActive: agentsLastActive, now: now) {
            begin(Session(started: session.started, end: nil, followsAgents: true))
        } else {
            stop(reason, now: now)
        }
    }

    /// Switches keep-awake on when an agent is working and nothing says it shouldn't be.
    private func startForAgents(lastActive: Date?, now: Date) {
        guard settings.startWithAgents else {
            isHeldOff = false
            return
        }
        if isHeldOff {
            isHeldOff = agentsUnfinished(now: now)
            return
        }
        guard hasPermission, AgentIdleRule.isWorking(lastActive: lastActive, now: now) else { return }
        // No point starting what a rule would end at once: a low battery, or a Mac already running hot.
        let session = Session(started: now, end: nil, followsAgents: true)
        let blocked = session.endReason(
            now: now,
            rules: settings.stopRules,
            battery: PowerControl.battery(),
            hotSince: PowerControl.isRunningHot ? .distantPast : nil,
            agentsLastActive: lastActive
        )
        guard blocked == nil else { return }
        // If macOS refuses, wait for the agents to finish before trying again.
        isHeldOff = !begin(session)
    }

    /// Whether agents have worked within the grace period, so they haven't finished yet.
    private func agentsUnfinished(now: Date) -> Bool {
        guard let lastActive = agents.latestActivity(among: settings.watchedAgents) else { return false }
        return now.timeIntervalSince(lastActive) < settings.stopRules.agentsGrace
    }

    /// Starts a session by hand, or gives the running one a new end time.
    private func begin(end: Date?, onTheClock: Bool = false, now: Date) {
        begin(Session(started: session?.started ?? now, end: end, endsOnTheClock: onTheClock))
    }

    /// Switches on, or replaces the session already running without letting go of the override.
    @discardableResult
    private func begin(_ session: Session) -> Bool {
        guard self.session == nil else {
            self.session = session
            return true
        }
        guard PowerControl.setLidSleepDisabled(true) else {
            refreshPermission()
            startError = hasPermission
                ? "macOS refused to change the sleep setting."
                : "Cortado needs one-time permission to keep the Mac awake with the lid closed."
            return false
        }
        startError = nil
        isHeldOff = false
        settings.sessionInProgress = true
        settings.lastSessionNote = nil
        watchdog = .start()
        assertion = PowerControl.holdIdleSleepAssertion()
        self.session = session
        return true
    }
}
