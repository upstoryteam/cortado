import Foundation
import Testing
@testable import Cortado

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let sixHours: TimeInterval = 6 * 3600
private let allRules = StopRules(batteryFloor: 20, stopWhenHot: true, agentsGrace: 600, endsWithAgents: true, autoLimit: sixHours)
private let noRules = StopRules(batteryFloor: nil, stopWhenHot: false, agentsGrace: 600, endsWithAgents: false, autoLimit: nil)

private func entry(_ pid: pid_t, parent: pid_t = 1, _ path: String, footprint: UInt64 = 0, cpu: UInt64 = 0) -> ProcessEntry {
    ProcessEntry(pid: pid, parent: parent, path: path, footprint: footprint, cpuTime: cpu)
}

@Suite struct SessionRules {
    let session = Session(started: start, end: start.addingTimeInterval(3600))

    private func reason(
        after seconds: TimeInterval,
        session: Session? = nil,
        battery: PowerControl.Battery? = .init(percent: 80, onAC: false),
        hotFor: TimeInterval? = nil,
        agentsLastActive: Date? = nil
    ) -> EndReason? {
        let now = start.addingTimeInterval(seconds)
        return (session ?? self.session).endReason(
            now: now,
            rules: allRules,
            battery: battery,
            hotSince: hotFor.map { now.addingTimeInterval(-$0) },
            agentsLastActive: agentsLastActive
        )
    }

    @Test func `keeps running while nothing is wrong`() {
        #expect(reason(after: 1800) == nil)
    }

    @Test func `ends when the timer runs out`() {
        #expect(reason(after: 3600) == .timer)
    }

    @Test func `an indefinite session has no timer`() {
        #expect(reason(after: 100_000, session: Session(started: start, end: nil)) == nil)
    }

    @Test func `ends at the battery floor only when unplugged`() {
        #expect(reason(after: 60, battery: .init(percent: 20, onAC: false)) == .battery(20))
        #expect(reason(after: 60, battery: .init(percent: 21, onAC: false)) == nil)
        #expect(reason(after: 60, battery: .init(percent: 5, onAC: true)) == nil)
    }

    @Test func `a desktop Mac without a battery is not stopped`() {
        #expect(reason(after: 60, battery: nil) == nil)
    }

    @Test func `brief heat is tolerated, sustained heat ends the session`() {
        #expect(reason(after: 300, hotFor: 30) == nil)
        #expect(reason(after: 300, hotFor: 60) == .tooHot)
    }

    @Test func `ends once agents have been quiet for the grace period`() {
        let worked = start.addingTimeInterval(120)
        #expect(reason(after: 120 + 599, agentsLastActive: worked) == nil)
        #expect(reason(after: 120 + 600, agentsLastActive: worked) == .agentsFinished)
    }

    @Test func `agents that never worked during the session leave it on the timer`() {
        #expect(reason(after: 1800, agentsLastActive: nil) == nil)
        #expect(reason(after: 1800, agentsLastActive: start.addingTimeInterval(-5)) == nil)
    }

    @Test func `disabled rules are ignored`() {
        let now = start.addingTimeInterval(1800)
        let result = session.endReason(
            now: now,
            rules: noRules,
            battery: .init(percent: 3, onAC: false),
            hotSince: start,
            agentsLastActive: start.addingTimeInterval(1)
        )
        #expect(result == nil)
    }

    @Test func `a session agents switched on lasts until they have been quiet, whatever the rule for your own`() {
        let session = Session(started: start, end: nil, followsAgents: true)
        func reason(after seconds: TimeInterval, lastActive: TimeInterval) -> EndReason? {
            session.endReason(
                now: start.addingTimeInterval(seconds),
                rules: noRules,
                battery: nil,
                hotSince: nil,
                agentsLastActive: start.addingTimeInterval(lastActive)
            )
        }
        // The work that switched it on came just before it started, and nothing since.
        #expect(reason(after: 599, lastActive: -5) == nil)
        #expect(reason(after: 600, lastActive: -5) == .agentsFinished)
        // More work pushes the end back.
        #expect(reason(after: 999, lastActive: 400) == nil)
        #expect(reason(after: 1000, lastActive: 400) == .agentsFinished)
        // The panel names the same moment as the one it ends at.
        #expect(session.quietEnd(agentsLastActive: start.addingTimeInterval(400), grace: 600) == start.addingTimeInterval(1000))
        #expect(session.quietEnd(agentsLastActive: nil, grace: 600) == start.addingTimeInterval(600))
    }

    @Test func `Auto ends at its limit however busy agents look, and On is left to its own timer`() {
        func reason(after seconds: TimeInterval, followsAgents: Bool, rules: StopRules = allRules) -> EndReason? {
            Session(started: start, end: nil, followsAgents: followsAgents).endReason(
                now: start.addingTimeInterval(seconds),
                rules: rules,
                battery: nil,
                hotSince: nil,
                agentsLastActive: start.addingTimeInterval(seconds - 5)
            )
        }
        #expect(reason(after: sixHours - 1, followsAgents: true) == nil)
        #expect(reason(after: sixHours, followsAgents: true) == .limit(sixHours))
        #expect(reason(after: sixHours * 4, followsAgents: true, rules: noRules) == nil)
        #expect(reason(after: sixHours * 4, followsAgents: false) == nil)
        #expect(EndReason.limit(sixHours).note == "Auto had been on for 6 hrs")
    }
}

@Suite struct ClockTimes {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func `a time later today ends today`() {
        #expect(date(1, 18, 0).nextOccurrence(after: date(1, 14, 30), calendar: calendar) == date(1, 18, 0))
    }

    @Test func `a time that already passed rolls to tomorrow`() {
        #expect(date(1, 7, 15).nextOccurrence(after: date(1, 14, 30), calendar: calendar) == date(2, 7, 15))
    }

    @Test func `end times are offered on the half hour, none too soon to be useful`() {
        #expect(Session.untilChoices(after: date(1, 14, 10), calendar: calendar).first == date(1, 14, 30))
        #expect(Session.untilChoices(after: date(1, 14, 20), calendar: calendar).first == date(1, 15, 0))
        #expect(Session.untilChoices(after: date(1, 14, 45), calendar: calendar).first == date(1, 15, 0))
        let evening = Session.untilChoices(after: date(1, 22, 0), calendar: calendar)
        #expect(evening.count == 24)
        #expect(evening.first == date(1, 22, 30))
        #expect(evening.last == date(2, 10, 0))
    }

    @Test func `the picker's own date is irrelevant, only its clock time`() {
        #expect(date(20, 18, 0).nextOccurrence(after: date(1, 14, 30), calendar: calendar) == date(1, 18, 0))
    }
}

@Suite struct Formatting {
    @Test(arguments: zip(
        [1800, 1741, 3600, 6120, 5, -20] as [TimeInterval],
        ["30m", "30m", "1h", "1h 42m", "1m", "1m"]
    ))
    func `durations read as hours and minutes, rounded up`(interval: TimeInterval, expected: String) {
        #expect(Format.duration(interval) == expected)
    }

    @Test(arguments: zip(
        [1800, 1741, 3600, 6120, 7200, 5] as [TimeInterval],
        ["30 min", "30 min", "1 hr", "1 hr 42 min", "2 hrs", "1 min"]
    ))
    func `durations in a sentence are spelled out`(interval: TimeInterval, expected: String) {
        #expect(Format.spelledDuration(interval) == expected)
    }

    @Test func `memory reads in gigabytes to one decimal, megabytes whole`() {
        let megabyte: UInt64 = 1_048_576
        #expect(Format.bytes(3_922 * megabyte) == "3.8 GB")
        #expect(Format.bytes(1_024 * megabyte) == "1.0 GB")
        #expect(Format.bytes(993 * megabyte + 500_000) == "993 MB")
        #expect(Format.bytes(1_000 * megabyte) == "1.0 GB")
        #expect(Format.bytes(0) == "0 MB")
        #expect(Format.usage(17_830 * megabyte, of: 24_576 * megabyte) == "17.4 of 24 GB")
    }
}

@Suite struct Processes {
    private let home = "/Users/someone"

    @Test func `helpers are grouped under their app`() {
        let snapshot = [
            entry(1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", footprint: 300),
            entry(2, "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", footprint: 700),
            entry(3, "/usr/bin/swift-frontend", footprint: 400),
            entry(4, "/usr/sbin/tiny", footprint: 1),
        ]
        let top = ProcessGroup.top(2, from: snapshot)
        #expect(top == [
            ProcessGroup(name: "Google Chrome", footprint: 1000),
            ProcessGroup(name: "swift-frontend", footprint: 400),
        ])
    }

    @Test func `each agent is recognised by the binaries it really runs as`() {
        let claudeDesktop = entry(1, "\(home)/Library/Application Support/Claude/claude-code/2.1.284/claude.app/Contents/MacOS/claude")
        let claudeCLI = entry(2, "\(home)/.local/share/claude/versions/2.1.232")
        let claudeApp = entry(3, "/Applications/Claude.app/Contents/MacOS/Claude")
        let codexCLI = entry(4, "/opt/homebrew/Caskroom/codex/0.155.1/bin/codex")
        let codexApp = entry(5, "/Applications/ChatGPT.app/Contents/Resources/codex")
        let cursorHost = entry(6, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        let cursorCLI = entry(7, "\(home)/.local/share/cursor-agent/versions/2026.07.01/node")

        #expect(Agent.claude.owns(claudeDesktop))
        #expect(Agent.claude.owns(claudeCLI))
        #expect(!Agent.claude.owns(claudeApp), "the desktop app's own window is not an agent at work")
        #expect(Agent.codex.owns(codexCLI))
        #expect(Agent.codex.owns(codexApp))
        #expect(Agent.cursor.owns(cursorHost))
        #expect(Agent.cursor.owns(cursorCLI))
        #expect(!Agent.codex.owns(claudeCLI))
    }

    @Test func `an agent's CPU share includes everything it spawned`() {
        let second: UInt64 = 1_000_000_000
        let snapshot = [
            entry(10, "/x/claude", cpu: 5 * second),
            entry(11, parent: 10, "/bin/zsh", cpu: 1 * second),
            entry(12, parent: 11, "/usr/bin/swift-build", cpu: 9 * second),
            entry(20, "/x/codex", cpu: 4 * second),
            entry(30, "/usr/bin/unrelated", cpu: 50 * second),
        ]
        let previous: [pid_t: UInt64] = [10: 5 * second, 11: 1 * second, 12: 4 * second, 20: 4 * second, 30: 0]
        let shares = AgentUsage.cpuShare(in: snapshot, previous: previous, elapsed: 10, agents: [.claude, .codex])
        #expect(shares[.claude] == 0.5)
        #expect(shares[.codex] == 0)
        #expect(shares[.cursor] == nil)
    }

    @Test func `a process first seen this sample is not counted as a burst`() {
        let snapshot = [entry(10, "/x/claude", cpu: 90_000_000_000)]
        let shares = AgentUsage.cpuShare(in: snapshot, previous: [:], elapsed: 3, agents: [.claude])
        #expect(shares[.claude] == 0)
    }

    @Test func `transcripts are told apart from other files an agent keeps`() {
        #expect(Agent.claude.isTranscript(Agent.claude.transcriptRoot + "/p/abc.jsonl"))
        #expect(!Agent.claude.isTranscript(Agent.claude.transcriptRoot + "/p/memory/MEMORY.md"))
        #expect(Agent.cursor.isTranscript(Agent.cursor.transcriptRoot + "/p/agent-transcripts/a/a.jsonl"))
        #expect(!Agent.cursor.isTranscript(Agent.cursor.transcriptRoot + "/p/terminals/1.jsonl"))
        #expect(!Agent.codex.isTranscript(Agent.claude.transcriptRoot + "/p/abc.jsonl"), "another agent's transcript")
    }

    @Test @MainActor func `a transcript being written marks its own agent as working`() {
        let monitor = AgentMonitor()
        monitor.transcriptsChanged([
            Agent.codex.transcriptRoot + "/2026/10/01/rollout.jsonl",
            Agent.cursor.transcriptRoot + "/p/terminals/1.jsonl",
        ], now: start)
        #expect(monitor.lastActive == [.codex: start])
        #expect(monitor.latestActivity(among: [.claude, .cursor]) == nil)
    }

    @Test func `an agent counts as working for two minutes after it was last seen`() {
        #expect(AgentIdleRule.isWorking(lastActive: start, now: start.addingTimeInterval(119)))
        #expect(!AgentIdleRule.isWorking(lastActive: start, now: start.addingTimeInterval(120)))
        #expect(!AgentIdleRule.isWorking(lastActive: nil, now: start))
    }

    @Test @MainActor func `CPU use is not compared across a long gap between samples`() {
        let second: UInt64 = 1_000_000_000
        let monitor = AgentMonitor()
        monitor.sample([entry(10, "/x/claude", cpu: 0)], agents: [.claude], now: start)
        // An hour of work long ago, averaged over the gap, would still look busy.
        let later = start.addingTimeInterval(3 * 3600)
        monitor.sample([entry(10, "/x/claude", cpu: 3600 * second)], agents: [.claude], now: later)
        #expect(monitor.lastActive.isEmpty)
        monitor.sample([entry(10, "/x/claude", cpu: 3605 * second)], agents: [.claude], now: later.addingTimeInterval(15))
        #expect(monitor.lastActive == [.claude: later.addingTimeInterval(15)])
    }
}

@Suite struct Hotspot {
    private let saved: Set<String> = ["Home", "Office", "Cafe Open", "Kim iPhone", "Sam iPhone 17 Pro"]
    private let hotspot = "Sam iPhone 17 Pro"

    private func target(_ visible: [VisibleNetwork], excluding excluded: Set<String> = []) -> String? {
        HotspotRules.switchBackTarget(visible: visible, saved: saved, hotspot: hotspot, excluding: excluded)
    }

    @Test func `reads the saved network list`() {
        let listing = "Preferred networks on en0:\n\tSam iPhone 17 Pro\n\tHome\n\tGuest Wi-Fi 5G\n"
        #expect(HotspotRules.savedNetworks(fromListing: listing) == ["Sam iPhone 17 Pro", "Home", "Guest Wi-Fi 5G"])
    }

    @Test func `picks the strongest saved network in range`() {
        let visible = [
            VisibleNetwork(name: "Office", signal: -70, isOpen: false),
            VisibleNetwork(name: "Home", signal: -52, isOpen: false),
            VisibleNetwork(name: "Neighbour", signal: -30, isOpen: false),
        ]
        #expect(target(visible) == "Home")
    }

    @Test func `never leaves the hotspot for itself or another phone`() {
        let visible = [
            VisibleNetwork(name: "Sam iPhone 17 Pro", signal: -30, isOpen: false),
            VisibleNetwork(name: "Kim iPhone", signal: -35, isOpen: false),
        ]
        #expect(target(visible) == nil)
    }

    @Test func `skips weak and open networks`() {
        #expect(target([VisibleNetwork(name: "Home", signal: -80, isOpen: false)]) == nil)
        #expect(target([VisibleNetwork(name: "Cafe Open", signal: -40, isOpen: true)]) == nil)
    }

    @Test func `a network passed over when the hotspot was joined is left alone, a new arrival is not`() {
        let visible = [
            VisibleNetwork(name: "Office", signal: -40, isOpen: false),
            VisibleNetwork(name: "Home", signal: -60, isOpen: false),
        ]
        #expect(target(visible, excluding: ["Office"]) == "Home")
        #expect(target(visible, excluding: ["Office", "Home"]) == nil)
    }
}

/// Exercises the real lid-closed override. Skipped on a Mac without the sudoers rule,
/// or while something (the installed app, say) already holds the override.
@Suite(.serialized) struct LidOverride {
    private static let transcript = Agent.claude.transcriptRoot + "/project/session.jsonl"

    /// A controller with only the agent rules in play, so the Mac's battery, heat and lid can't decide a test.
    @MainActor private func controller(
        isPutAway: @escaping () -> Bool = { false }
    ) -> (SessionController, AgentMonitor, Settings) {
        let defaults = UserDefaults(suiteName: "Cortado.tests")!
        defaults.removePersistentDomain(forName: "Cortado.tests")
        let settings = Settings(defaults: defaults)
        settings.batteryFloorEnabled = false
        settings.stopWhenHot = false
        let agents = AgentMonitor()
        let controller = SessionController(
            settings: settings, agents: agents, hotspot: HotspotController(settings: settings), isPutAway: isPutAway
        )
        controller.recover()
        return (controller, agents, settings)
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `Auto switches on for an agent at work, and Off stays off until Auto is picked again`() {
        let (controller, agents, _) = controller()
        let now = Date.now
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

        controller.tick(now: now)
        #expect(controller.mode == .auto)
        #expect(controller.mark == .waiting, "nothing is working yet")

        agents.transcriptsChanged([Self.transcript], now: now)
        controller.tick(now: at(3))
        #expect(controller.session == Session(started: at(3), end: nil, followsAgents: true))
        #expect(controller.mode == .auto)
        #expect(controller.mark == .on)
        #expect(PowerControl.isLidSleepDisabled())

        controller.select(.off, now: at(10))
        #expect(controller.mode == .off)
        #expect(controller.mark == .off)
        agents.transcriptsChanged([Self.transcript], now: at(15))
        controller.tick(now: at(18))
        #expect(!controller.isActive, "the agent is still at it, but Off is off")
        #expect(!PowerControl.isLidSleepDisabled())

        controller.select(.auto, now: at(20))
        #expect(controller.session == Session(started: at(20), end: nil, followsAgents: true))

        controller.select(.off, now: at(30))
        #expect(!PowerControl.isLidSleepDisabled())
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `Auto switches off at its limit, and stays off until the agents have finished`() {
        let (controller, agents, settings) = controller()
        let now = Date.now
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
        func work(at seconds: TimeInterval) { agents.transcriptsChanged([Self.transcript], now: at(seconds)) }

        work(at: 0)
        controller.tick(now: at(3))
        #expect(controller.mark == .on)

        work(at: sixHours)
        controller.tick(now: at(sixHours))
        #expect(controller.mark == .on, "three seconds short of six hours")
        controller.tick(now: at(sixHours + 3))
        #expect(!controller.isActive)
        #expect(controller.mode == .auto)
        #expect(controller.mark == .off, "not waiting either: the agent is still at it")
        #expect(settings.lastSessionNote?.hasSuffix("Auto had been on for 6 hrs.") == true)
        #expect(!PowerControl.isLidSleepDisabled())

        work(at: sixHours + 60)
        controller.tick(now: at(sixHours + 63))
        #expect(!controller.isActive, "more work doesn't switch it back on")

        controller.tick(now: at(sixHours + 60 + 600))
        #expect(controller.mark == .waiting, "quiet for the grace period, so the next job gets Auto again")
        work(at: sixHours + 700)
        controller.tick(now: at(sixHours + 703))
        #expect(controller.mark == .on)

        // Picking Auto again doesn't wait for the agents to finish.
        work(at: 2 * sixHours + 700)
        controller.tick(now: at(2 * sixHours + 703))
        #expect(!controller.isActive)
        controller.select(.auto, now: at(2 * sixHours + 710))
        #expect(controller.mark == .on)

        controller.select(.off, now: at(2 * sixHours + 720))
        #expect(!PowerControl.isLidSleepDisabled())
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `Auto leaves a shut Mac alone, and switches on once it is opened`() {
        var lidShut = true
        let (controller, agents, _) = controller(isPutAway: { lidShut })
        let now = Date.now
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

        agents.transcriptsChanged([Self.transcript], now: now)
        controller.tick(now: at(3))
        #expect(!controller.isActive, "an agent stirring under the lid")
        #expect(controller.mark == .waiting)
        #expect(!PowerControl.isLidSleepDisabled())

        lidShut = false
        controller.tick(now: at(6))
        #expect(controller.mark == .on)
        #expect(PowerControl.isLidSleepDisabled())

        // Shutting the lid on a session that is already on changes nothing.
        lidShut = true
        agents.transcriptsChanged([Self.transcript], now: at(9))
        controller.tick(now: at(12))
        #expect(controller.mark == .on)

        controller.select(.off, now: at(15))
        #expect(!PowerControl.isLidSleepDisabled())
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `agents are left alone when the setting is off`() {
        let (controller, agents, settings) = controller()
        settings.startWithAgents = false
        let now = Date.now
        agents.transcriptsChanged([Self.transcript], now: now)
        controller.tick(now: now.addingTimeInterval(3))
        #expect(!controller.isActive)
        #expect(controller.mode == .off)
        #expect(!controller.isWaitingForAgents)
        #expect(!PowerControl.isLidSleepDisabled())
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `On lasts the default length, and going back to Auto hands it to agents still at work or drops it`() {
        let (controller, agents, _) = controller()
        let now = Date.now
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

        controller.select(.on, now: now)
        #expect(controller.session == Session(started: now, end: at(2 * 3600)))
        #expect(controller.mode == .on)

        agents.transcriptsChanged([Self.transcript], now: at(5))
        controller.select(.auto, now: at(10))
        #expect(controller.session == Session(started: now, end: nil, followsAgents: true))
        #expect(controller.mode == .auto)
        #expect(PowerControl.isLidSleepDisabled(), "the override was never let go")

        controller.select(.on, now: at(20))
        #expect(controller.mode == .on)
        controller.select(.auto, now: at(5 + 600))
        #expect(!controller.isActive, "the agent finished a while ago")
        #expect(controller.mark == .waiting)
        #expect(!PowerControl.isLidSleepDisabled())
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `a timer that runs out under working agents hands over to them, and a new length takes it back`() {
        let (controller, agents, _) = controller()
        let now = Date.now
        controller.start(duration: 60, now: now)
        agents.transcriptsChanged([Self.transcript], now: now.addingTimeInterval(50))
        controller.tick(now: now.addingTimeInterval(61))
        #expect(controller.session == Session(started: now, end: nil, followsAgents: true))
        #expect(controller.mode == .auto)
        #expect(PowerControl.isLidSleepDisabled())

        let later = now.addingTimeInterval(90)
        controller.start(duration: 3600, now: later)
        #expect(controller.session == Session(started: now, end: later.addingTimeInterval(3600)))
        #expect(PowerControl.isLidSleepDisabled())

        // An end picked from the clock is remembered as one, so it reads as a time.
        controller.start(until: later.addingTimeInterval(1800), now: later)
        #expect(controller.session?.endsOnTheClock == true)
        #expect(controller.mode == .on)

        controller.stop(.stopped, now: later)
        #expect(!PowerControl.isLidSleepDisabled())
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `a session turns the override on and stopping turns it off`() {
        let defaults = UserDefaults(suiteName: "Cortado.tests")!
        defaults.removePersistentDomain(forName: "Cortado.tests")
        let settings = Settings(defaults: defaults)
        let controller = SessionController(
            settings: settings, agents: AgentMonitor(), hotspot: HotspotController(settings: settings)
        )
        controller.recover()

        controller.start(duration: 3600)
        #expect(controller.isActive)
        #expect(PowerControl.isLidSleepDisabled())
        #expect(settings.sessionInProgress)

        controller.stop(.stopped)
        #expect(!controller.isActive)
        #expect(!PowerControl.isLidSleepDisabled())
        #expect(!settings.sessionInProgress)
    }

    @Test(.enabled(if: PowerControl.hasLidSleepPermission() && !PowerControl.isLidSleepDisabled()))
    @MainActor func `an override left behind by a crash is cleared at launch`() {
        let defaults = UserDefaults(suiteName: "Cortado.tests")!
        defaults.removePersistentDomain(forName: "Cortado.tests")
        let settings = Settings(defaults: defaults)
        settings.sessionInProgress = true
        PowerControl.setLidSleepDisabled(true)

        let controller = SessionController(
            settings: settings, agents: AgentMonitor(), hotspot: HotspotController(settings: settings)
        )
        controller.recover()

        #expect(!PowerControl.isLidSleepDisabled())
        #expect(!settings.sessionInProgress)
    }
}

@Suite struct Preferences {
    @Test @MainActor func `switching on lasts two hours until another length is chosen, and no limit is remembered`() {
        let defaults = UserDefaults(suiteName: "Cortado.tests.preferences")!
        defaults.removePersistentDomain(forName: "Cortado.tests.preferences")
        let settings = Settings(defaults: defaults)
        let twoHours: TimeInterval = 2 * 3600
        #expect(settings.defaultLength == twoHours)
        #expect(settings.startWithAgents)
        #expect(settings.stopRules.autoLimit == sixHours)
        settings.autoLimitEnabled = false
        #expect(Settings(defaults: defaults).stopRules.autoLimit == nil)
        #expect(Session.lengths.contains(settings.defaultLength))

        settings.defaultLength = nil
        #expect(Settings(defaults: defaults).defaultLength == nil)
        settings.defaultLength = 1800
        #expect(Settings(defaults: defaults).defaultLength == 1800)
    }
}
