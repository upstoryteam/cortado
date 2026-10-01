import CoreServices
import Foundation
import Observation

nonisolated enum Agent: String, CaseIterable, Sendable, Identifiable {
    case claude, codex, cursor

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// Whether a process is this agent itself. Anything it spawns (builds, tests,
    /// scripts) is found by walking down from these.
    func owns(_ entry: ProcessEntry) -> Bool {
        switch self {
        case .claude: entry.name == "claude" || entry.path.contains("/claude/versions/")
        case .codex: entry.name == "codex" || entry.name.hasPrefix("codex-")
        case .cursor: entry.name == "Cursor Helper (Plugin)" || entry.path.contains("/cursor-agent/")
        }
    }

    /// Where the agent writes its session transcripts. A transcript that just
    /// changed means the agent is mid-task even if it is only waiting on the network.
    var transcriptRoot: String {
        switch self {
        case .claude: NSHomeDirectory() + "/.claude/projects"
        case .codex: NSHomeDirectory() + "/.codex/sessions"
        case .cursor: NSHomeDirectory() + "/.cursor/projects"
        }
    }

    /// Cursor keeps many other files beside each project's transcripts.
    func isTranscript(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(transcriptRoot + "/") else { return false }
        return self != .cursor || path.contains("/agent-transcripts/")
    }
}

nonisolated enum AgentUsage {
    /// An agent using at least this share of one CPU core counts as working.
    static let busyThreshold = 0.10

    /// CPU use of each agent's process tree since the previous snapshot, as a share of one core.
    static func cpuShare(
        in snapshot: [ProcessEntry],
        previous: [pid_t: UInt64],
        elapsed: TimeInterval,
        agents: Set<Agent>
    ) -> [Agent: Double] {
        guard elapsed > 0 else { return [:] }
        var children: [pid_t: [ProcessEntry]] = [:]
        for entry in snapshot {
            children[entry.parent, default: []].append(entry)
        }

        var shares: [Agent: Double] = [:]
        for agent in agents {
            var pending = snapshot.filter(agent.owns)
            var seen = Set<pid_t>()
            var nanoseconds: UInt64 = 0
            while let entry = pending.popLast() {
                guard seen.insert(entry.pid).inserted else { continue }
                if let before = previous[entry.pid], entry.cpuTime > before {
                    nanoseconds += entry.cpuTime - before
                }
                pending.append(contentsOf: children[entry.pid] ?? [])
            }
            shares[agent] = Double(nanoseconds) / 1_000_000_000 / elapsed
        }
        return shares
    }
}

nonisolated enum AgentIdleRule {
    /// An agent seen this recently counts as working right now. Long enough to
    /// span the pauses between one transcript entry and the next.
    static let workingWindow: TimeInterval = 120

    static func isWorking(lastActive: Date?, now: Date) -> Bool {
        guard let lastActive else { return false }
        return now.timeIntervalSince(lastActive) < workingWindow
    }

    /// Agents count as finished once they have worked during the session and then
    /// stayed quiet for the grace period. A session where no agent ever works runs
    /// on its timer.
    static func isFinished(lastActive: Date?, sessionStart: Date, grace: TimeInterval, now: Date) -> Bool {
        guard let lastActive, lastActive >= sessionStart else { return false }
        return now.timeIntervalSince(lastActive) >= grace
    }
}

/// Tracks when each agent was last seen working.
@Observable
final class AgentMonitor {
    /// Transcript changes arrive in batches this far apart, after the first, which arrives at once.
    private static let transcriptLatency: TimeInterval = 5
    /// CPU use is compared between samples; across a longer gap than this the
    /// comparison would smear an old burst of work over the present.
    private static let longestSampleGap: TimeInterval = 60

    private(set) var lastActive: [Agent: Date] = [:]

    @ObservationIgnored private var previousCPU: [pid_t: UInt64] = [:]
    @ObservationIgnored private var previousSample: Date?
    @ObservationIgnored private var transcripts: FSEventStreamRef?

    isolated deinit {
        guard let transcripts else { return }
        FSEventStreamStop(transcripts)
        FSEventStreamInvalidate(transcripts)
        FSEventStreamRelease(transcripts)
    }

    func latestActivity(among agents: Set<Agent>) -> Date? {
        agents.compactMap { lastActive[$0] }.max()
    }

    /// Has macOS report writes under the transcript folders. Nothing is polled:
    /// while no agent writes, this costs nothing at all.
    func watchTranscripts() {
        guard transcripts == nil else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil,
            transcriptEvents,
            &context,
            Agent.allCases.map(\.transcriptRoot) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.transcriptLatency,
            FSEventStreamCreateFlags(flags)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        transcripts = stream
    }

    func transcriptsChanged(_ paths: [String], now: Date = .now) {
        for agent in Agent.allCases where paths.contains(where: agent.isTranscript) {
            markActive(agent, at: now)
        }
    }

    /// Catches work that leaves the transcript alone, such as a long build the agent is waiting on.
    func sample(_ snapshot: [ProcessEntry], agents: Set<Agent>, now: Date = .now) {
        if let previousSample, now.timeIntervalSince(previousSample) <= Self.longestSampleGap {
            let shares = AgentUsage.cpuShare(
                in: snapshot,
                previous: previousCPU,
                elapsed: now.timeIntervalSince(previousSample),
                agents: agents
            )
            for (agent, share) in shares where share >= AgentUsage.busyThreshold {
                markActive(agent, at: now)
            }
        }
        previousCPU = Dictionary(snapshot.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { first, _ in first })
        previousSample = now
    }

    private func markActive(_ agent: Agent, at date: Date) {
        lastActive[agent] = max(date, lastActive[agent] ?? .distantPast)
    }
}

/// Called by macOS on the main queue with the files that changed under the transcript folders.
private nonisolated func transcriptEvents(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    // Deleting an old transcript is housekeeping, not work.
    let written = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated)
    let changed = zip(paths, UnsafeBufferPointer(start: flags, count: count)).filter { $0.1 & written != 0 }.map(\.0)
    let monitor = Unmanaged<AgentMonitor>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.transcriptsChanged(changed)
    }
}
