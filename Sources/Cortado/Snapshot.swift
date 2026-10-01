#if DEBUG
import AppKit
import SwiftUI

/// Development aids, debug builds only.
///
/// `Cortado --snapshot <folder>` renders the panel, the settings and the menu bar
/// icon to PNG files so the layout can be checked without clicking through the
/// menu bar. It briefly starts real sessions to draw the running states.
enum Snapshot {
    static func write(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "Cortado.snapshot") ?? .standard
        defaults.removePersistentDomain(forName: "Cortado.snapshot")
        let settings = Settings(defaults: defaults)
        // A made-up phone, so the pictures don't show the one this Mac has saved.
        settings.hotspotName = "Sam iPhone 17 Pro"
        let model = AppModel(settings: settings)
        model.start()
        model.panelVisible = true
        for _ in 0..<60 {
            model.memory.refresh()
        }

        func renderBoth(_ name: String, _ view: some View) {
            for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                render(view, model: model, scheme: scheme, to: folder.appending(path: "\(name)-\(suffix).png"))
            }
        }
        // Nothing is watched at first, so an agent really at work can't switch it on mid-picture.
        let watched = model.settings.watchedAgents
        model.settings.watchedAgents = []
        model.tick()
        renderBoth("panel-idle", PanelView())
        // An agent that wrote its last two minutes ago has gone quiet, and the session is counting down.
        model.settings.watchedAgents = [.codex]
        model.agents.transcriptsChanged(
            [Agent.codex.transcriptRoot + "/2026/rollout.jsonl"],
            now: .now.addingTimeInterval(3 - AgentIdleRule.workingWindow)
        )
        model.tick()
        RunLoop.current.run(until: .now.addingTimeInterval(4))
        renderBoth("panel-quiet", PanelView())
        model.session.select(.off)
        model.session.select(.auto)
        // An agent writing to its transcript switches a session on by itself.
        model.settings.watchedAgents = watched
        model.agents.transcriptsChanged([Agent.claude.transcriptRoot + "/project/session.jsonl"])
        model.tick()
        renderBoth("panel-agents", PanelView())
        model.session.select(.off)
        renderBoth("panel-off", PanelView())
        model.settings.memoryExpanded = true
        model.tick()
        renderBoth("panel-memory", PanelView())
        model.settings.memoryExpanded = false
        model.session.start(duration: 2 * 3600 - 18 * 60)
        renderBoth("panel-active", PanelView())
        model.session.select(.off)
        renderBoth("settings", SettingsView {}.frame(width: 320))
        renderIcons(to: folder.appending(path: "icons.png"))
    }

    private static func render(_ view: some View, model: AppModel, scheme: ColorScheme, to url: URL) {
        let content = view
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: .now.addingTimeInterval(0.6))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    /// `Cortado --diagnose` starts a real session, watches the agents for a few
    /// seconds, prints what it saw, then kills itself without cleaning up. The
    /// watchdog should restore normal sleep within a few seconds.
    static func diagnose() async {
        let defaults = UserDefaults(suiteName: "Cortado.snapshot") ?? .standard
        defaults.removePersistentDomain(forName: "Cortado.snapshot")
        let model = AppModel(settings: Settings(defaults: defaults))
        model.start()
        model.session.start(duration: 600)
        print("session active:", model.session.isActive, "| override on:", PowerControl.isLidSleepDisabled())
        for _ in 0..<4 {
            try? await Task.sleep(for: .seconds(3))
            model.tick()
        }
        try? await Task.sleep(for: .seconds(1))
        let now = Date.now
        for agent in Agent.allCases {
            let seen = model.agents.lastActive[agent].map { "active \(Int(now.timeIntervalSince($0)))s ago" } ?? "no activity"
            print(agent.displayName + ":", seen)
        }
        let stats = model.memory.stats
        print("memory:", Format.bytes(stats.used), "used,", stats.pressure.label, Format.percent(stats.pressureFraction))
        print("hotspot:", model.settings.hotspotName, "| on hotspot:", model.hotspot.isOnHotspot, "| online:", model.hotspot.isOnline)
        print("lid closed:", PowerControl.isLidClosed(), "| battery:", PowerControl.battery().map { "\($0.percent)% ac=\($0.onAC)" } ?? "none",
              "| hot:", PowerControl.isRunningHot)
        fflush(stdout)
        kill(getpid(), SIGKILL)
    }

    /// `Cortado --measure` times each piece of work the app repeats, so its
    /// polling intervals can be chosen from numbers rather than guesses.
    static func measure() async {
        let clock = ContinuousClock()
        func report(_ label: String, _ durations: [Duration]) {
            let median = durations.sorted()[durations.count / 2]
            let micros = Double(median.components.attoseconds) / 1e12 + Double(median.components.seconds) * 1e6
            print(label.padding(toLength: 34, withPad: " ", startingAt: 0), String(format: "%9.0f µs", micros))
        }
        func time(_ label: String, runs: Int = 15, _ body: () -> Void) {
            report(label, (0..<runs).map { _ in clock.measure(body) })
        }

        time("memory statistics") { _ = MemoryStats.current() }
        time("battery") { _ = PowerControl.battery() }
        time("lid state") { _ = PowerControl.isLidClosed() }
        time("menu bar icon") { _ = StatusIcon.image(fraction: 0.4, level: .normal, awake: .on).tiffRepresentation }
        var snapshot: [ProcessEntry] = []
        time("process list") { snapshot = ProcessSnapshot.capture() }
        print("  \(snapshot.count) processes")
        time("top apps") { _ = ProcessGroup.top(5, from: snapshot) }
        let previous = Dictionary(snapshot.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { first, _ in first })
        time("agent CPU share") {
            _ = AgentUsage.cpuShare(in: snapshot, previous: previous, elapsed: 3, agents: Set(Agent.allCases))
        }
        let transcript = Agent.cursor.transcriptRoot + "/project/agent-transcripts/a/a.jsonl"
        time("a batch of 50 file changes") {
            for agent in Agent.allCases {
                _ = (0..<50).contains { _ in agent.isTranscript(transcript) }
            }
        }

        // A minute of each state with the panel closed, ticking as the app does.
        // Agents are left out of the first minute so that it stays idle.
        let defaults = UserDefaults(suiteName: "Cortado.snapshot") ?? .standard
        defaults.removePersistentDomain(forName: "Cortado.snapshot")
        let model = AppModel(settings: Settings(defaults: defaults))
        model.settings.startWithAgents = false
        model.start()
        for (label, sessionActive) in [("idle", false), ("in a session", true)] {
            if sessionActive {
                model.session.start(duration: 600)
                model.tick()
            }
            let before = cpuSeconds()
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(AppModel.tickInterval))
                model.tick()
            }
            print(String(format: "one minute \(label), panel closed: %.1f ms of CPU", (cpuSeconds() - before) * 1000))
        }
        let seen = Agent.allCases.filter { model.agents.lastActive[$0] != nil }.map(\.displayName)
        print("agents seen working meanwhile:", seen.isEmpty ? "none" : seen.joined(separator: ", "))
        model.session.stop(.stopped)
        exit(0)
    }

    /// CPU time this process has used so far.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// Every icon state on a light and a dark strip, enlarged.
    private static func renderIcons(to url: URL) {
        let states: [(Double, PressureLevel, StatusIcon.Awake)] = [
            (0.25, .normal, .off), (0.3, .normal, .waiting), (0.4, .normal, .on),
            (0.7, .warning, .waiting), (0.75, .warning, .on), (0.95, .critical, .on),
        ]
        let scale: CGFloat = 4
        let cell = NSSize(width: 30 * scale, height: 24 * scale)
        let size = NSSize(width: cell.width * CGFloat(states.count), height: cell.height * 2)
        let sheet = NSImage(size: size, flipped: false) { _ in
            for (row, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                // The icon takes its colours from the appearance it is drawn under, as it does in the menu bar.
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    let strip = NSRect(x: 0, y: CGFloat(row) * cell.height, width: size.width, height: cell.height)
                    (name == .aqua ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
                    strip.fill()
                    for (column, state) in states.enumerated() {
                        let icon = StatusIcon.image(fraction: state.0, level: state.1, awake: state.2)
                        let target = NSRect(
                            x: CGFloat(column) * cell.width + (cell.width - icon.size.width * scale) / 2,
                            y: strip.minY + (cell.height - icon.size.height * scale) / 2,
                            width: icon.size.width * scale,
                            height: icon.size.height * scale
                        )
                        icon.draw(in: target)
                    }
                }
            }
            return true
        }
        guard let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// `Cortado --show-panel <file>` drives the real popover from the real menu bar
/// item: opens it, clicks in it, saves pictures, and closes it.
extension AppDelegate {
    func checkPanel(savingTo url: URL) async {
        // Agents at work would flip the switch between clicks, so only one that isn't running is watched.
        model.settings.watchedAgents = [.cursor]
        model.settings.startWithAgents = false
        model.settings.defaultLength = 2 * 3600
        try? await Task.sleep(for: .seconds(1))
        togglePanel()
        try? await Task.sleep(for: .seconds(1))
        guard let view = popover.contentViewController?.view else {
            print("the popover did not open")
            exit(1)
        }
        print("open: shown \(popover.isShown), popover \(popover.contentSize)")

        func state() -> String {
            let ends = model.session.session?.end.map { Format.duration($0.timeIntervalSinceNow) } ?? "-"
            return "shown \(popover.isShown), session \(model.session.isActive), override \(PowerControl.isLidSleepDisabled()), ends in \(ends), popover \(popover.contentSize)"
        }
        func save(_ suffix: String) {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let file = url.deletingPathExtension().appendingPathExtension("\(suffix).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        }
        /// The menu bar item as it draws itself, enlarged on grey so either colour of icon shows.
        func saveIcon(_ suffix: String) {
            guard let button = statusItem?.button,
                  let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let scale: CGFloat = 6
            let size = NSSize(width: button.bounds.width * scale, height: button.bounds.height * scale)
            let enlarged = NSImage(size: size, flipped: false) { rect in
                NSColor(white: 0.5, alpha: 1).setFill()
                rect.fill()
                bitmap.draw(in: rect)
                return true
            }
            let file = url.deletingPathExtension().appendingPathExtension("icon-\(suffix).png")
            guard let tiff = enlarged.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        save("off")
        saveIcon("off")
        print("menu bar item: \(statusItem?.button?.effectiveAppearance.name.rawValue ?? "-"), \(statusItem?.button?.bounds.size ?? .zero)")

        // Off, Auto and On share the control under the header, measured from the panel's top-left corner.
        let modes = NSRect(
            x: PanelView.inset, y: PanelView.inset + 16 + 10,
            width: view.bounds.width - 2 * PanelView.inset, height: ModeControl.height
        )
        func modeCentre(_ index: CGFloat) -> NSPoint {
            NSPoint(x: modes.minX + modes.width * (index + 0.5) / 3, y: modes.midY)
        }
        // Under the control: the status line, then the lengths.
        let lengthRow = modes.maxY + 10 + 16 + 10 + 13
        let chipPitch = (view.bounds.width - 2 * PanelView.inset + 6) / 7
        func chipCentre(_ index: CGFloat) -> NSPoint {
            NSPoint(x: PanelView.inset + chipPitch * index + (chipPitch - 6) / 2, y: lengthRow)
        }

        // Rows appear under the control when it goes on. The panel should grow to fit them, not jump.
        func heights() async -> [Int] {
            var heights: [Int] = []
            for sample in 0..<14 {
                try? await Task.sleep(for: .milliseconds(25))
                heights.append(Int(view.window?.frame.height ?? 0))
                // A picture from the middle of it, to see the rows on their way.
                if sample == 4 { save("resizing") }
            }
            return heights
        }
        await click(modeCentre(2), in: view)
        print("panel height after picking On, every 25 ms:", await heights())
        try? await Task.sleep(for: .seconds(1))
        print("picked On:", state())
        save("on")
        saveIcon("on")

        await click(chipCentre(1), in: view)
        try? await Task.sleep(for: .seconds(1))
        print("clicked 1h:", state())

        let opened = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { notification in
            // Menus only exist on the main thread, where this notification arrives.
            guard let found = notification.object as? NSMenu else { return }
            nonisolated(unsafe) let menu = found
            let titles = menu.items.map(\.title)
            print("clicked clock: menu with \(titles.count) times, \(titles.first ?? "-") to \(titles.last ?? "-")")
            RunLoop.main.perform(inModes: [.eventTracking, .common]) { menu.cancelTracking() }
        }
        await click(chipCentre(6), in: view)
        try? await Task.sleep(for: .seconds(1))
        NotificationCenter.default.removeObserver(opened)

        // The knob is the brightest stretch of the control. Watched from On to Off, it should cross the middle.
        func knobCentre() -> Int {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let row = Int((modes.minY + 5) * scale)
            let columns = (Int(modes.minX * scale)..<Int(modes.maxX * scale)).map { x in
                (x, bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0)
            }
            guard let low = columns.map(\.1).min(), let high = columns.map(\.1).max(), high > low else { return -1 }
            let knob = columns.filter { $0.1 > (low + high) / 2 }.map(\.0)
            return Int(CGFloat(knob.reduce(0, +)) / CGFloat(knob.count) / scale)
        }
        await click(modeCentre(0), in: view)
        var path: [Int] = []
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
            path.append(knobCentre())
        }
        print("knob after picking Off, every 25 ms:", path)
        try? await Task.sleep(for: .seconds(1))
        print("picked Off:", state())

        await click(modeCentre(1), in: view)
        try? await Task.sleep(for: .seconds(1))
        print("picked Auto: on for agents \(model.settings.startWithAgents), waiting \(model.session.isWaitingForAgents)")
        save("waiting")
        saveIcon("waiting")

        // An agent at work switches it on with nobody touching it.
        model.agents.transcriptsChanged([Agent.cursor.transcriptRoot + "/project/agent-transcripts/a/a.jsonl"])
        try? await Task.sleep(for: .seconds(4))
        print("agent started work:", state(), "follows agents \(model.session.session?.followsAgents ?? false)")
        save("agents")

        // Off is off, whatever the agent is doing.
        await click(modeCentre(0), in: view)
        try? await Task.sleep(for: .seconds(4))
        print("picked Off under a working agent:", state(), "on for agents \(model.settings.startWithAgents)")

        // The memory line follows the keep-awake section and a divider. Opened, it shows the apps.
        let memory = NSPoint(x: view.bounds.midX, y: modes.maxY + PanelView.inset + 1 + 6 + 15)
        await click(memory, in: view)
        try? await Task.sleep(for: .seconds(1))
        print("opened Memory: \(model.settings.memoryExpanded), top apps \(model.memory.topGroups.count), popover \(popover.contentSize)")
        save("memory")
        await click(memory, in: view)
        try? await Task.sleep(for: .seconds(1))
        print("closed Memory: \(!model.settings.memoryExpanded), popover \(popover.contentSize)")

        // The auto-join checkbox ends the hotspot section, above the two rows of the footer.
        let footer = 2 * (30 + 12 + 1)
        let before = model.settings.hotspotFallback
        await click(NSPoint(x: PanelView.inset + 8, y: view.bounds.height - CGFloat(footer) - PanelView.inset - 8), in: view)
        try? await Task.sleep(for: .seconds(1))
        print("clicked auto-join: \(before) to \(model.settings.hotspotFallback)")
        save("no-auto-join")
        model.settings.hotspotFallback = before

        // Settings is a different height altogether, and Back returns to this one.
        await click(NSPoint(x: view.bounds.midX, y: view.bounds.height - 64), in: view)
        try? await Task.sleep(for: .seconds(1))
        print("opened Settings: popover \(popover.contentSize), panel \(view.fittingSize)")
        save("settings")
        await click(NSPoint(x: PanelView.inset + 20, y: 20), in: view)
        try? await Task.sleep(for: .seconds(1))
        print("went back: popover \(popover.contentSize), panel \(view.fittingSize)")

        togglePanel()
        try? await Task.sleep(for: .seconds(2))
        print("closed: shown \(popover.isShown), content released \(popover.contentViewController == nil), sampling processes \(model.panelVisible)")

        exit(0)
    }

    /// A real mouse click at a point measured from the view's top-left corner,
    /// held for a moment as a finger holds it.
    private func click(_ point: NSPoint, in view: NSView) async {
        mouse(.leftMouseDown, at: point, in: view)
        try? await Task.sleep(for: .milliseconds(90))
        mouse(.leftMouseUp, at: point, in: view)
    }
}
/// `Cortado --film <folder>` opens the real popover and saves each change of the
/// control as a strip of frames, with the window's size as the window server had
/// it and any moment the main thread stood still.
extension AppDelegate {
    func filmPanel(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.settings.watchedAgents = [.cursor]
        model.settings.startWithAgents = false
        model.settings.defaultLength = 2 * 3600
        try? await Task.sleep(for: .seconds(1))
        togglePanel()
        try? await Task.sleep(for: .seconds(1))
        guard let view = popover.contentViewController?.view, let window = view.window else {
            print("the popover did not open")
            exit(1)
        }
        let modes = NSRect(
            x: PanelView.inset, y: PanelView.inset + 16 + 10,
            width: view.bounds.width - 2 * PanelView.inset, height: ModeControl.height
        )
        func modeCentre(_ index: CGFloat) -> NSPoint {
            NSPoint(x: modes.minX + modes.width * (index + 0.5) / 3, y: modes.midY)
        }

        /// Taking a picture holds the main thread for longer than a frame lasts, so
        /// each change is timed once with no pictures and then pictured once more.
        func film(_ name: String, pictures: Bool, _ action: () async -> Void) async {
            let id = CGWindowID(window.windowNumber)
            let trace = Task { await Self.traceWindow(id, for: 0.7) }
            let beats = Beats()
            let pulse = Timer(timeInterval: 0.004, repeats: true) { _ in
                MainActor.assumeIsolated { beats.times.append(CACurrentMediaTime()) }
            }
            RunLoop.main.add(pulse, forMode: .common)
            let began = CACurrentMediaTime()
            await action()
            var frames: [(ms: Int, image: NSBitmapImageRep)] = []
            for index in 0..<(pictures ? 16 : 0) {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    frames.append((Int((CACurrentMediaTime() - began) * 1000), bitmap))
                }
                let next = began + Double(index + 1) * 0.03
                try? await Task.sleep(for: .seconds(max(0.001, next - CACurrentMediaTime())))
            }
            try? await Task.sleep(for: .milliseconds(pictures ? 400 : 900))
            pulse.invalidate()
            let samples = await trace.value

            guard pictures else {
                let stalls = zip(beats.times, beats.times.dropFirst()).filter { $1 - $0 > 0.014 }
                    .map { "\(Int(($0 - began) * 1000))+\(Int(($1 - $0) * 1000))" }
                var steps: [String] = []
                var last = (top: -1.0, height: -1.0)
                for sample in samples where (sample.top, sample.height) != last {
                    steps.append("\(sample.ms):\(sample.height)" + (last.top >= 0 && sample.top != last.top ? "(top \(sample.top))" : ""))
                    last = (sample.top, sample.height)
                }
                print("\n\(name)")
                print("  window height by ms:", steps.joined(separator: " "))
                print("  main thread stood still at ms+for:", stalls.isEmpty ? "never" : stalls.joined(separator: " "))
                return
            }

            // Frames side by side, each as tall as the popover was then, on a colour nothing in the panel uses.
            let width = view.bounds.width
            let tallest = frames.map { $0.image.size.height }.max() ?? 0
            let perRow = 8
            let strips = (frames.count + perRow - 1) / perRow
            let size = NSSize(width: width * CGFloat(perRow), height: (tallest + 14) * CGFloat(strips))
            let sheet = NSImage(size: size, flipped: true) { rect in
                NSColor(red: 1, green: 0.85, blue: 1, alpha: 1).setFill()
                rect.fill()
                for (index, frame) in frames.enumerated() {
                    let origin = NSPoint(
                        x: CGFloat(index % perRow) * width,
                        y: CGFloat(index / perRow) * (tallest + 14) + 14
                    )
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: origin, size: frame.image.size).fill()
                    frame.image.draw(
                        in: NSRect(origin: origin, size: frame.image.size),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                    )
                    ("\(frame.ms) ms" as NSString).draw(at: NSPoint(x: origin.x + 4, y: origin.y - 14), withAttributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    ])
                }
                return true
            }
            if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
            }
            for (index, frame) in frames.enumerated() {
                try? frame.image.representation(using: .png, properties: [:])?
                    .write(to: folder.appending(path: "\(name)-\(String(format: "%02d", index)).png"))
            }
        }
        /// Pressed for as long as a finger takes.
        func press(_ point: NSPoint) async {
            mouse(.leftMouseDown, at: point, in: view)
            try? await Task.sleep(for: .milliseconds(90))
            mouse(.leftMouseUp, at: point, in: view)
        }

        for pictures in [false, true] {
            await film("1-off-to-on", pictures: pictures) { await press(modeCentre(2)) }
            await film("2-on-to-off", pictures: pictures) { await press(modeCentre(0)) }
            await film("3-off-to-auto", pictures: pictures) { await press(modeCentre(1)) }
            await film("4-agent-starts", pictures: pictures) {
                model.agents.transcriptsChanged([Agent.cursor.transcriptRoot + "/project/agent-transcripts/a/a.jsonl"])
                model.tick()
            }
            await film("5-auto-to-on", pictures: pictures) { await press(modeCentre(2)) }
            await film("6-on-to-auto", pictures: pictures) { await press(modeCentre(1)) }
            await film("7-auto-to-off", pictures: pictures) { await press(modeCentre(0)) }
            // The memory line follows the keep-awake section and a divider.
            let memory = NSPoint(x: view.bounds.midX, y: modes.maxY + PanelView.inset + 1 + 6 + 15)
            await film("8-memory-opens", pictures: pictures) { await press(memory) }
            await film("9-memory-closes", pictures: pictures) { await press(memory) }
        }
        togglePanel()
        try? await Task.sleep(for: .seconds(1))
        exit(0)
    }

    /// When the main thread last came round.
    private final class Beats {
        var times: [Double] = []
    }

    /// The window as the window server has it, read off the main thread so that
    /// nothing the app is busy with can hide a step.
    @concurrent
    nonisolated private static func traceWindow(_ id: CGWindowID, for seconds: Double) async -> [(ms: Int, top: Double, height: Double)] {
        let began = CACurrentMediaTime()
        var samples: [(ms: Int, top: Double, height: Double)] = []
        while CACurrentMediaTime() - began < seconds {
            if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
               let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds) {
                samples.append((Int((CACurrentMediaTime() - began) * 1000), rect.minY, rect.height))
            }
            usleep(3000)
        }
        return samples
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) {
        guard let window = view.window else { return }
        window.makeKey()
        let local = NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: type, location: view.convert(local, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
#endif
