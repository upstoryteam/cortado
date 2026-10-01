import SwiftUI

struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    /// Told the height the panel wants whenever that changes, so the popover can grow or shrink to it.
    var onHeight: (CGFloat) -> Void = { _ in }

    /// How rows come and go. The popover follows them on the same curve, over the same time.
    static let resizeDuration = 0.25
    static let resizeCurve = UnitCurve.easeInOut

    var body: some View {
        Group {
            if showingSettings {
                SettingsView { showingSettings = false }
            } else {
                // Clipped, so a row arriving in a section is uncovered as the
                // sections below move out of its way, rather than showing through them.
                VStack(spacing: 0) {
                    KeepAwakeSection().padding(Self.inset).clipped()
                    Divider()
                    MemorySection().clipped()
                    Divider()
                    HotspotSection().padding(Self.inset).clipped()
                    Divider()
                    footer
                }
            }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .timingCurve(Self.resizeCurve, duration: Self.resizeDuration), value: rows)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeight(height)
        }
        // While the popover is on its way to that height the panel stays at its top.
        // Without a minimum it would be centred, and cut off at both ends.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    static let inset: CGFloat = 16

    /// Everything that adds a row to the panel or takes one away. When any of it
    /// changes, the rows below ease into place instead of jumping.
    private var rows: [AnyHashable] {
        let session = model.session, hotspot = model.hotspot
        return [
            showingSettings,
            session.isActive, session.isWaitingForAgents, session.session?.followsAgents == true,
            session.startError != nil,
            hotspot.isOnHotspot, hotspot.activity != .idle, hotspot.lastEvent != nil,
            model.settings.memoryExpanded, model.memory.topGroups.count,
        ]
    }

    /// One action to a line, each under a divider of its own. The row that
    /// leads somewhere says so with a chevron.
    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                showingSettings = true
            } label: {
                HStack {
                    Text("Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            Divider()
            Button("Quit AgentBar") { NSApp.terminate(nil) }
                .padding(.vertical, 6)
        }
        .buttonStyle(RowStyle())
    }
}

/// How a section is, and why. Nil where a section is plainly off and has nothing to add.
struct Status {
    var state: String
    /// On is the state worth noticing, so it takes the colour of the dot in the menu bar.
    var isOn = false
    var detail: String?
}

struct StatusLine: View {
    let status: Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(status.state)
                .bold()
                .foregroundStyle(status.isOn ? AnyShapeStyle(Color(nsColor: StatusIcon.awakeColor)) : AnyShapeStyle(.secondary))
            if let detail = status.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit()
        // The words change at once. Faded, the old line shows through the new one.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
    }
}

/// Off, Auto and On, with a knob that slides to the one picked, as on the iPhone.
/// The Mac's own segmented control jumps from one segment to the next.
struct ModeControl: View {
    @Binding var mode: SessionController.Mode
    /// Where the knob has been dragged to, before it is let go.
    @State private var dragged: SessionController.Mode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let modes = SessionController.Mode.allCases
    static let height: CGFloat = 32

    var body: some View {
        let shown = dragged ?? mode
        GeometryReader { proxy in
            let segment = proxy.size.width / CGFloat(Self.modes.count)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .controlColor))
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                    .padding(2)
                    .frame(width: segment)
                    .offset(x: segment * CGFloat(Self.modes.firstIndex(of: shown) ?? 0))
                HStack(spacing: 0) {
                    ForEach(Self.modes, id: \.self) { mode in
                        Text(mode.label)
                            .fontWeight(mode == shown ? .semibold : .regular)
                            // Only the knob travels. The lettering changes at once.
                            .animation(nil, value: shown)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Capsule())
            // A click moves the knob when it is let go, together with everything the
            // choice changes below it. Picked up, the knob follows the pointer.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard Self.mode(at: drag.startLocation.x, segment: segment) == mode else { return }
                        dragged = Self.mode(at: drag.location.x, segment: segment)
                    }
                    .onEnded { drag in
                        let picked = Self.mode(at: drag.location.x, segment: segment)
                        dragged = nil
                        if picked != mode { mode = picked }
                    }
            )
        }
        .frame(height: Self.height)
        .background(.primary.opacity(0.1), in: Capsule())
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: shown)
        .accessibilityRepresentation {
            Picker("Keep awake", selection: $mode) {
                ForEach(Self.modes, id: \.self) { Text($0.label) }
            }
        }
    }

    private static func mode(at x: CGFloat, segment: CGFloat) -> SessionController.Mode {
        modes[min(modes.count - 1, max(0, Int(x / segment)))]
    }
}

extension SessionController.Mode {
    var label: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .on: "On"
        }
    }
}

/// A row as wide as the panel that acts when clicked, lit under the pointer like a menu item.
struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, PanelView.inset - 6)
                .background(
                    .primary.opacity(configuration.isPressed ? 0.16 : isHovered ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .padding(.horizontal, 6)
        }
    }
}

/// The one button look used in the panel.
struct ChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                .primary.opacity(configuration.isPressed ? 0.22 : 0.1),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Keep awake

struct KeepAwakeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = model.session
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep awake").font(.headline)

            if !controller.hasPermission {
                permission
            } else {
                // The one control that matters most gets the largest target in the panel.
                ModeControl(mode: mode)
                    .help("Auto turns on while an agent is working. On stays on for a length you choose.")

                // Switched off, the control has said it all, and there is no line to leave a gap for.
                if controller.isActive || controller.isWaitingForAgents {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if let status = status(at: context.date) {
                            StatusLine(status: status)
                        }
                    }
                }

                // The lengths belong to On.
                if let session = controller.session, !session.followsAgents {
                    lengths
                    if model.settings.stopWhenAgentsFinish {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(agentStatus(during: session, now: context.date))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !controller.isActive, let note = model.settings.lastSessionNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }

            if let error = controller.startError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private var mode: Binding<SessionController.Mode> {
        Binding {
            model.session.mode
        } set: { mode in
            model.session.select(mode)
        }
    }

    /// Whether it is on, and what will change that.
    private func status(at now: Date) -> Status? {
        let controller = model.session
        guard let session = controller.session else {
            return controller.isWaitingForAgents
                ? Status(state: "Off", detail: "Turns on when an agent is working")
                : nil
        }
        func on(_ detail: String) -> Status {
            Status(state: "On", isOn: true, detail: detail)
        }
        if let end = session.end {
            return on(session.endsOnTheClock
                ? "Until \(end.formatted(date: .omitted, time: .shortened))"
                : "For \(Format.spelledDuration(end.timeIntervalSince(now)))")
        }
        guard session.followsAgents else { return on("Until you turn it off") }

        let lastActive = model.agents.lastActive
        let working = Agent.allCases.filter { agent in
            model.settings.watchedAgents.contains(agent) && AgentIdleRule.isWorking(lastActive: lastActive[agent], now: now)
        }
        if !working.isEmpty {
            let who = working.count == 1 ? "\(working[0].displayName) finishes" : "agents finish"
            return on("Until \(model.settings.agentsGraceMinutes) min after \(who)")
        }
        // Quiet agents leave it on for the grace period, and what matters now is how soon that runs out.
        let end = session.quietEnd(
            agentsLastActive: model.agents.latestActivity(among: model.settings.watchedAgents),
            grace: model.settings.stopRules.agentsGrace
        )
        // The work that switched the session on happened just before it started.
        let since = session.started.addingTimeInterval(-AgentIdleRule.workingWindow)
        let idle = Agent.allCases.filter { agent in
            model.settings.watchedAgents.contains(agent) && lastActive[agent].map { $0 >= since } == true
        }
        let who = idle.count == 1 ? idle[0].displayName : "Agents"
        return on("\(who) idle, off in \(Format.spelledDuration(end.timeIntervalSince(now)))")
    }

    /// Each length counts from now. The clock offers end times instead.
    private var lengths: some View {
        HStack(spacing: 6) {
            ForEach(Session.lengths, id: \.self) { length in
                let label = length.map(Format.duration) ?? "∞"
                Button(label) {
                    model.session.start(duration: length)
                }
                .help(length == nil ? "Stay awake until you switch it off" : "Stay awake for \(label) from now")
            }
            Menu {
                ForEach(Session.untilChoices(after: .now), id: \.self) { time in
                    Button("Until \(time.formatted(date: .omitted, time: .shortened))") {
                        model.session.start(until: time)
                    }
                }
            } label: {
                Image(systemName: "clock")
            }
            .menuIndicator(.hidden)
            .help("Stay awake until a time")
        }
        .buttonStyle(ChipStyle())
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Staying awake with the lid closed needs a one-time administrator approval.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.session.isInstallingPermission ? "Waiting for approval…" : "Allow…") {
                model.session.installPermission()
            }
            .buttonStyle(ChipStyle())
            .disabled(model.session.isInstallingPermission)
        }
    }

    private func agentStatus(during session: Session, now: Date) -> String {
        // The work that switched a session on happened just before it started.
        let since = session.followsAgents
            ? session.started.addingTimeInterval(-AgentIdleRule.workingWindow)
            : session.started
        let seen = Agent.allCases.compactMap { agent -> String? in
            guard model.settings.watchedAgents.contains(agent),
                  let last = model.agents.lastActive[agent], last >= since else { return nil }
            return AgentIdleRule.isWorking(lastActive: last, now: now)
                ? "\(agent.displayName) working"
                : "\(agent.displayName) idle \(Format.spelledDuration(now.timeIntervalSince(last)))"
        }
        return seen.isEmpty
            ? "Ends early \(model.settings.agentsGraceMinutes) min after agents finish."
            : seen.joined(separator: " · ")
    }
}

// MARK: - Memory

struct MemorySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.memory.stats
        let color = Color(nsColor: StatusIcon.tint(for: stats.pressure) ?? .systemGreen)
        let expanded = model.settings.memoryExpanded
        VStack(spacing: 0) {
            // A section that only reports sits back: one line, and the rest for whoever asks.
            Button {
                model.settings.memoryExpanded = !expanded
                // The apps are only looked up while they are on show.
                if !expanded { model.tick() }
            } label: {
                HStack(spacing: 6) {
                    Text("Memory pressure").font(.subheadline.weight(.medium))
                    Spacer(minLength: 12)
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text("\(stats.pressure.label) \(Format.percent(stats.pressureFraction))")
                        .font(.subheadline)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(RowStyle())
            .padding(.vertical, 6)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                details(stats, color: color)
                    .padding(.horizontal, PanelView.inset)
                    .padding(.top, 4)
                    .padding(.bottom, PanelView.inset)
            }
        }
    }

    private func details(_ stats: MemoryStats, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Sparkline(values: model.memory.history, capacity: MemoryMonitor.historyLimit, color: color)
                .frame(height: 24)
                .help("Memory pressure over the last 10 minutes")

            HStack(alignment: .top) {
                stat("Used", Format.usage(stats.used, of: stats.total), .leading)
                Spacer()
                stat("Compressed", Format.bytes(stats.compressed), .leading)
                Spacer()
                stat("Swap", Format.bytes(stats.swapUsed), .trailing)
            }

            VStack(spacing: 5) {
                ForEach(model.memory.topGroups) { group in
                    HStack {
                        Text(group.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(Format.bytes(group.footprint))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
        }
    }
}

/// A line graph of values between 0 and 1. Newest values sit at the right edge,
/// so a short history starts partway across rather than stretching.
struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = points(in: proxy.size)
            ZStack(alignment: .bottom) {
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.addLines(points)
                    path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: first.x, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.15))
                Path { $0.addLines(points) }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, capacity > 1 else { return [] }
        let step = size.width / CGFloat(capacity - 1)
        let offset = CGFloat(capacity - values.count) * step
        return values.enumerated().map { index, value in
            CGPoint(
                x: offset + CGFloat(index) * step,
                y: size.height * (1 - CGFloat(min(1, max(0, value))))
            )
        }
    }
}

// MARK: - Hotspot

struct HotspotSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hotspot = model.hotspot
        let name = model.settings.hotspotName
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 10) {
            Text("Hotspot").font(.headline)

            if name.isEmpty {
                Text("Choose your phone in Settings.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Group {
                        if hotspot.isOnHotspot {
                            Button("Disconnect") { hotspot.disconnect() }
                        } else {
                            Button("Connect") { hotspot.connect() }
                                .disabled(hotspot.activity != .idle)
                        }
                    }
                    .buttonStyle(ChipStyle())
                    .frame(width: 96)
                }
                if let status {
                    StatusLine(status: status)
                }
                Toggle("Auto-join if the connection is lost", isOn: $settings.hotspotFallback)
                    .toggleStyle(.checkbox)
                    .help("Joins the phone when the internet has been down for 20 seconds while keep awake is on.")
            }

            if let event = hotspot.lastEvent {
                Text(event).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// What it is doing, and what it will do by itself from here. Nothing while it is simply off.
    private var status: Status? {
        let hotspot = model.hotspot
        switch hotspot.activity {
        case .joining(let attempt): return Status(state: attempt > 1 ? "Joining, try \(attempt)…" : "Joining…")
        case .switching(let target): return Status(state: "Switching to \(target)…")
        case .idle: break
        }
        guard hotspot.isOnHotspot else { return nil }
        let leaves = model.settings.switchBackToWiFi && hotspot.canSeeNetworkNames
        return Status(state: "Connected", isOn: true, detail: leaves ? "Leaves when saved Wi-Fi appears" : nil)
    }
}
