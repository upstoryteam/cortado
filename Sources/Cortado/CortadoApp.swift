import AppKit
import QuartzCore
import SwiftUI

@main
enum CortadoApp {
    static func main() {
        let app = NSApplication.shared
        #if DEBUG
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(flag + 1) {
            Snapshot.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            Task { await Snapshot.diagnose() }
            app.run()
        }
        if CommandLine.arguments.contains("--measure") {
            Task { await Snapshot.measure() }
            app.run()
        }
        #endif
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    let popover = NSPopover()
    private(set) var statusItem: NSStatusItem?
    private var timer: Timer?
    private var resizing: CADisplayLink?
    private var resize = (from: CGFloat(0), to: CGFloat(0), began: CFTimeInterval(0))
    private var shownIcon: IconState?

    /// What the icon currently shows. The gauge moves in steps of about a pixel,
    /// so the icon is only redrawn when it would look different.
    private struct IconState: Equatable {
        static let steps = 20.0
        let step: Int
        let level: PressureLevel
        let awake: StatusIcon.Awake
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        popover.behavior = .transient
        popover.delegate = self

        model.start()
        let timer = Timer(timeInterval: AppModel.tickInterval, repeats: true) { [model] _ in
            MainActor.assumeIsolated { model.tick() }
        }
        // Loose timing lets macOS fold these wake-ups in with ones it was making anyway.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        keepIconCurrent()
        #if DEBUG
        if let flag = CommandLine.arguments.firstIndex(of: "--show-panel"),
           CommandLine.arguments.indices.contains(flag + 1) {
            Task { await checkPanel(savingTo: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--film"),
           CommandLine.arguments.indices.contains(flag + 1) {
            Task { await filmPanel(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func popoverDidClose(_ notification: Notification) {
        model.panelVisible = false
        // The panel only exists while it is open. Left in place, a hidden SwiftUI
        // view keeps laying itself out on every change it observes.
        popover.contentViewController = nil
        stopResizing()
    }

    @objc func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.panelVisible = true
        let panel = PanelView { [weak self] height in
            self?.resizePanel(to: height)
        }
        let content = NSHostingController(rootView: panel.environment(model))
        // The panel says what size it wants. The popover is moved there by `resizePanel`.
        content.sizingOptions = .intrinsicContentSize
        popover.contentViewController = content
        let wanted = content.view.fittingSize
        popover.contentSize = NSSize(width: wanted.width, height: wanted.height.rounded(.up))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Key so clicks land at once, but nothing focused until it is clicked.
        content.view.window?.makeKey()
        content.view.window?.makeFirstResponder(nil)
    }

    /// Rows come and go in the panel. The popover eases to its new height as the
    /// rows move, a step on each frame the display draws.
    private func resizePanel(to height: CGFloat) {
        let start = popover.contentSize.height
        let target = height.rounded(.up)
        guard popover.isShown, abs(target - start) > 0.5,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let view = popover.contentViewController?.view else {
            stopResizing()
            setPanelHeight(target)
            return
        }
        resize = (start, target, CACurrentMediaTime())
        guard resizing == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(stepResize))
        link.add(to: .main, forMode: .common)
        resizing = link
    }

    @objc private func stepResize(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - resize.began) / PanelView.resizeDuration)
        let eased = PanelView.resizeCurve.value(at: progress)
        // Whole points. The popover hangs from its top edge, which a fraction would shake.
        let height = (resize.from + (resize.to - resize.from) * eased).rounded()
        if height != popover.contentSize.height {
            setPanelHeight(height)
        }
        if progress == 1 {
            stopResizing()
        }
    }

    /// The popover has an animation of its own for a change of size, and the whole
    /// app stands still while it runs, rows included. So it is switched off for these.
    private func setPanelHeight(_ height: CGFloat) {
        popover.animates = false
        popover.contentSize.height = height
        popover.animates = true
    }

    private func stopResizing() {
        resizing?.invalidate()
        resizing = nil
    }

    /// Redraws the menu bar icon when what it shows has changed.
    private func keepIconCurrent() {
        withObservationTracking {
            let stats = model.memory.stats
            let state = IconState(
                step: Int((stats.pressureFraction * IconState.steps).rounded()),
                level: stats.pressure,
                awake: model.session.mark
            )
            guard state != shownIcon, let button = statusItem?.button else { return }
            shownIcon = state
            button.image = StatusIcon.image(
                fraction: Double(state.step) / IconState.steps, level: state.level, awake: state.awake
            )
            let description = StatusIcon.description(level: state.level, awake: state.awake)
            button.toolTip = description
            button.setAccessibilityLabel(description)
        } onChange: { [weak self] in
            Task { @MainActor in self?.keepIconCurrent() }
        }
    }
}
