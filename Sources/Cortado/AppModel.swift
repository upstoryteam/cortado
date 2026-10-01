import Foundation
import Observation

/// Owns the app's moving parts and drives them from one timer.
@Observable
final class AppModel {
    static let tickInterval: TimeInterval = 3
    /// How often agents are sampled while nobody is looking. Their CPU share is an
    /// average over the gap, so a longer gap costs nothing in accuracy.
    private static let backgroundSampleInterval: TimeInterval = 15

    let settings: Settings
    let memory = MemoryMonitor()
    let agents = AgentMonitor()
    let hotspot: HotspotController
    let session: SessionController

    /// The process list is only sampled while the apps using the most memory are
    /// on show, or a rule needs it.
    var panelVisible = false {
        didSet {
            if panelVisible { tick() }
        }
    }

    @ObservationIgnored private var lastProcessSample = Date.distantPast

    init(settings: Settings = Settings()) {
        self.settings = settings
        hotspot = HotspotController(settings: settings)
        session = SessionController(settings: settings, agents: agents, hotspot: hotspot)
    }

    func start() {
        session.recover()
        agents.watchTranscripts()
        hotspot.start()
        tick()
    }

    func shutdown() {
        session.stop(.quit)
    }

    func tick(now: Date = .now) {
        memory.refresh()

        let watchingAgents = session.watchesAgents
        let sampleDue = now.timeIntervalSince(lastProcessSample) >= Self.backgroundSampleInterval
        let showingApps = panelVisible && settings.memoryExpanded
        if showingApps || (watchingAgents && sampleDue) {
            lastProcessSample = now
            let snapshot = ProcessSnapshot.capture()
            if showingApps {
                memory.updateTopProcesses(from: snapshot)
            }
            if watchingAgents {
                agents.sample(snapshot, agents: settings.watchedAgents, now: now)
            }
        }

        session.tick(now: now)
        hotspot.tick(now: now, sessionActive: session.isActive)
    }
}
