import Foundation
import Observation

/// User preferences, stored in UserDefaults.
@Observable
final class Settings {
    @ObservationIgnored private let defaults: UserDefaults

    /// How long keep-awake runs when it is switched on. Nil runs until it is switched off.
    var defaultLength: TimeInterval? { didSet { defaults.set(defaultLength ?? 0, forKey: Key.defaultLength) } }
    /// Switch keep-awake on whenever an agent is working, and off once they finish.
    var startWithAgents: Bool { didSet { defaults.set(startWithAgents, forKey: Key.startWithAgents) } }

    var batteryFloorEnabled: Bool { didSet { defaults.set(batteryFloorEnabled, forKey: Key.batteryFloorEnabled) } }
    var batteryFloor: Int { didSet { defaults.set(batteryFloor, forKey: Key.batteryFloor) } }
    var stopWhenHot: Bool { didSet { defaults.set(stopWhenHot, forKey: Key.stopWhenHot) } }

    var stopWhenAgentsFinish: Bool { didSet { defaults.set(stopWhenAgentsFinish, forKey: Key.stopWhenAgentsFinish) } }
    var agentsGraceMinutes: Int { didSet { defaults.set(agentsGraceMinutes, forKey: Key.agentsGraceMinutes) } }
    var watchedAgents: Set<Agent> {
        didSet { defaults.set(watchedAgents.map(\.rawValue).sorted(), forKey: Key.watchedAgents) }
    }

    var hotspotName: String { didSet { defaults.set(hotspotName, forKey: Key.hotspotName) } }
    var hotspotFallback: Bool { didSet { defaults.set(hotspotFallback, forKey: Key.hotspotFallback) } }
    var switchBackToWiFi: Bool { didSet { defaults.set(switchBackToWiFi, forKey: Key.switchBackToWiFi) } }

    /// Whether the panel shows the detail under the memory pressure line.
    var memoryExpanded: Bool { didSet { defaults.set(memoryExpanded, forKey: Key.memoryExpanded) } }

    /// Whether the panel has ever been opened. Until it has, the app opens it at launch.
    var panelSeen: Bool { didSet { defaults.set(panelSeen, forKey: Key.panelSeen) } }

    /// How the most recent session ended, shown in the panel afterwards.
    var lastSessionNote: String? { didSet { defaults.set(lastSessionNote, forKey: Key.lastSessionNote) } }
    /// True while a session holds the lid-closed override, to recover after a crash.
    var sessionInProgress: Bool { didSet { defaults.set(sessionInProgress, forKey: Key.sessionInProgress) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.defaultLength: 2 * 3600.0,
            Key.startWithAgents: true,
            Key.batteryFloorEnabled: true,
            Key.batteryFloor: 20,
            Key.stopWhenHot: true,
            Key.stopWhenAgentsFinish: true,
            Key.agentsGraceMinutes: 10,
            Key.watchedAgents: Agent.allCases.map(\.rawValue),
            Key.hotspotFallback: true,
            Key.switchBackToWiFi: true,
        ])
        let length = defaults.double(forKey: Key.defaultLength)
        defaultLength = length > 0 ? length : nil
        startWithAgents = defaults.bool(forKey: Key.startWithAgents)
        batteryFloorEnabled = defaults.bool(forKey: Key.batteryFloorEnabled)
        batteryFloor = defaults.integer(forKey: Key.batteryFloor)
        stopWhenHot = defaults.bool(forKey: Key.stopWhenHot)
        stopWhenAgentsFinish = defaults.bool(forKey: Key.stopWhenAgentsFinish)
        agentsGraceMinutes = defaults.integer(forKey: Key.agentsGraceMinutes)
        watchedAgents = Set((defaults.stringArray(forKey: Key.watchedAgents) ?? []).compactMap(Agent.init))
        hotspotName = defaults.string(forKey: Key.hotspotName) ?? ""
        hotspotFallback = defaults.bool(forKey: Key.hotspotFallback)
        switchBackToWiFi = defaults.bool(forKey: Key.switchBackToWiFi)
        memoryExpanded = defaults.bool(forKey: Key.memoryExpanded)
        panelSeen = defaults.bool(forKey: Key.panelSeen)
        lastSessionNote = defaults.string(forKey: Key.lastSessionNote)
        sessionInProgress = defaults.bool(forKey: Key.sessionInProgress)
    }

    var stopRules: StopRules {
        StopRules(
            batteryFloor: batteryFloorEnabled ? batteryFloor : nil,
            stopWhenHot: stopWhenHot,
            agentsGrace: TimeInterval(agentsGraceMinutes * 60),
            endsWithAgents: stopWhenAgentsFinish
        )
    }

    private enum Key {
        static let defaultLength = "defaultLength"
        static let startWithAgents = "startWithAgents"
        static let batteryFloorEnabled = "batteryFloorEnabled"
        static let batteryFloor = "batteryFloor"
        static let stopWhenHot = "stopWhenHot"
        static let stopWhenAgentsFinish = "stopWhenAgentsFinish"
        static let agentsGraceMinutes = "agentsGraceMinutes"
        static let watchedAgents = "watchedAgents"
        static let hotspotName = "hotspotName"
        static let hotspotFallback = "hotspotFallback"
        static let switchBackToWiFi = "switchBackToWiFi"
        static let memoryExpanded = "memoryExpanded"
        static let panelSeen = "panelSeen"
        static let lastSessionNote = "lastSessionNote"
        static let sessionInProgress = "sessionInProgress"
    }
}
