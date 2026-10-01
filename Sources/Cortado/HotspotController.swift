import CoreLocation
import CoreWLAN
import Foundation
import Network
import Observation

nonisolated struct VisibleNetwork: Sendable, Equatable {
    let name: String
    let signal: Int
    let isOpen: Bool
}

nonisolated enum HotspotRules {
    /// Weaker than this and a network isn't worth leaving the hotspot for.
    static let minimumSignal = -75

    /// `networksetup -listpreferredwirelessnetworks` prints a header, then one indented name per line.
    static func savedNetworks(fromListing listing: String) -> [String] {
        listing.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func looksLikePhone(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["iphone", "ipad", "android", "hotspot"].contains { lowered.contains($0) }
    }

    /// Saved networks in range that could replace the hotspot: they have a password,
    /// a usable signal, and aren't the hotspot or another phone.
    static func usableNetworks(visible: [VisibleNetwork], saved: Set<String>, hotspot: String) -> [VisibleNetwork] {
        visible.filter { network in
            saved.contains(network.name)
                && network.name != hotspot
                && !network.isOpen
                && network.signal >= minimumSignal
                && !looksLikePhone(network.name)
        }
    }

    /// The network to leave the hotspot for: the strongest usable one that isn't excluded.
    static func switchBackTarget(
        visible: [VisibleNetwork],
        saved: Set<String>,
        hotspot: String,
        excluding excluded: Set<String>
    ) -> String? {
        usableNetworks(visible: visible, saved: saved, hotspot: hotspot)
            .filter { !excluded.contains($0.name) }
            .max { $0.signal < $1.signal }?
            .name
    }
}

nonisolated enum WiFi {
    private static let networksetup = "/usr/sbin/networksetup"

    static var interfaceName: String {
        CWWiFiClient.shared().interface()?.interfaceName ?? "en0"
    }

    static func savedNetworks() -> [String] {
        let listing = Shell.run(networksetup, ["-listpreferredwirelessnetworks", interfaceName])
        return listing.succeeded ? HotspotRules.savedNetworks(fromListing: listing.output) : []
    }

    /// Joins a saved network by name using the password in the keychain.
    /// Returns nil on success, or what `networksetup` said went wrong.
    @concurrent
    static func join(_ name: String) async -> String? {
        // networksetup exits 0 even when it fails; success is silence.
        let result = Shell.run(networksetup, ["-setairportnetwork", interfaceName, name])
        return result.succeeded && result.output.isEmpty ? nil : result.output
    }

    static func disconnect() {
        CWWiFiClient.shared().interface()?.disassociate()
    }

    /// Nil if the scan failed. Names are only visible once the app has Location Services permission.
    @concurrent
    static func scan() async -> [VisibleNetwork]? {
        guard let interface = CWWiFiClient.shared().interface(),
              let networks = try? interface.scanForNetworks(withSSID: nil) else { return nil }
        return networks.compactMap { network in
            guard let name = network.ssid else { return nil }
            return VisibleNetwork(name: name, signal: network.rssiValue, isOpen: network.supportsSecurity(.none))
        }
    }

    /// True when a real page comes back, which a captive portal or dead uplink can't fake.
    @concurrent
    static func hasInternet() async -> Bool {
        var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self).contains("Success")
    }
}

/// Uses the phone's hotspot as a fallback and gets off it when better Wi-Fi is around.
@Observable
final class HotspotController {
    enum Activity: Equatable {
        case idle
        case joining(attempt: Int)
        case switching(to: String)
    }

    private static let joinAttempts = 6
    private static let offlineTolerance: TimeInterval = 20
    private static let retryInterval: TimeInterval = 90
    /// A scan takes the radio off its channel for a few seconds, so they are spaced out.
    private static let scanInterval: TimeInterval = 180
    private static let probeInterval: TimeInterval = 60
    private static let blockDuration: TimeInterval = 30 * 60
    /// Scans used to learn what was already in range when the hotspot was joined.
    private static let baselineScans = 2

    private(set) var activity: Activity = .idle
    private(set) var isOnline = true
    private(set) var isOnHotspot = false
    private(set) var lastEvent: String?
    private(set) var savedNetworks: [String] = []
    private(set) var canSeeNetworkNames = false

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var joinedByApp = false
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var offlineSince: Date?
    @ObservationIgnored private var failedProbes = 0
    @ObservationIgnored private var nextFallback = Date.distantPast
    @ObservationIgnored private var nextScan = Date.distantPast
    @ObservationIgnored private var nextProbe = Date.distantPast
    @ObservationIgnored private var blockedUntil: [String: Date] = [:]
    /// Networks that were in range when the hotspot was chosen over them. Whoever
    /// joined the hotspot passed these over, so only a newly arrived network counts.
    @ObservationIgnored private var passedOver: Set<String> = []
    @ObservationIgnored private var scansThisConnection = 0

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        reloadSavedNetworks()
        if settings.hotspotName.isEmpty {
            settings.hotspotName = savedNetworks.first(where: HotspotRules.looksLikePhone) ?? ""
        }
        refreshLocationAccess()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // macOS marks an iPhone hotspot as an expensive Wi-Fi path.
            let onHotspot = online && path.usesInterfaceType(.wifi) && path.isExpensive
            Task { @MainActor in
                self?.isOnline = online
                self?.isOnHotspot = onHotspot
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Cortado.network-path"))
    }

    func reloadSavedNetworks() {
        savedNetworks = WiFi.savedNetworks()
    }

    func refreshLocationAccess() {
        canSeeNetworkNames = locationManager.authorizationStatus == .authorizedAlways
    }

    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: Joining and leaving

    func connect() {
        let name = settings.hotspotName
        guard work == nil, !name.isEmpty else { return }
        work = Task {
            var failure = ""
            for attempt in 1...Self.joinAttempts {
                activity = .joining(attempt: attempt)
                guard let problem = await WiFi.join(name) else {
                    joinedByApp = true
                    failedProbes = 0
                    finish("Joined \(name).")
                    return
                }
                failure = problem
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled {
                    finish(nil)
                    return
                }
            }
            finish("Couldn't join \(name). \(failure)")
        }
    }

    func disconnect() {
        leaveHotspot(because: "you disconnected")
    }

    func sessionEnded() {
        sessionActive = false
        offlineSince = nil
        failedProbes = 0
        if joinedByApp {
            leaveHotspot(because: "the session ended")
        }
    }

    private func leaveHotspot(because reason: String) {
        guard isOnHotspot else { return }
        work?.cancel()
        WiFi.disconnect()
        joinedByApp = false
        note("Left the hotspot: \(reason).")
    }

    // MARK: Automatic behaviour

    func tick(now: Date = .now, sessionActive: Bool) {
        self.sessionActive = sessionActive
        refreshLocationAccess()
        blockedUntil = blockedUntil.filter { $0.value > now }

        if sessionActive, settings.hotspotFallback, !isOnHotspot {
            probeIfDue(now: now)
            let internetDown = !isOnline || failedProbes >= 2
            offlineSince = internetDown ? (offlineSince ?? now) : nil
            if let offlineSince, now.timeIntervalSince(offlineSince) >= Self.offlineTolerance,
               now >= nextFallback, work == nil {
                nextFallback = now.addingTimeInterval(Self.retryInterval)
                connect()
            }
        } else {
            offlineSince = nil
        }

        if !isOnHotspot {
            passedOver = []
            scansThisConnection = 0
        } else if settings.switchBackToWiFi, canSeeNetworkNames, now >= nextScan, work == nil {
            nextScan = now.addingTimeInterval(Self.scanInterval)
            lookForSavedNetwork(now: now)
        }
    }

    /// Catches a network that is connected but has no route out, which the path monitor can't see.
    private func probeIfDue(now: Date) {
        guard isOnline, now >= nextProbe else { return }
        nextProbe = now.addingTimeInterval(Self.probeInterval)
        Task {
            failedProbes = await WiFi.hasInternet() ? 0 : failedProbes + 1
        }
    }

    private func lookForSavedNetwork(now: Date) {
        let hotspot = settings.hotspotName
        let saved = Set(savedNetworks)
        let blocked = Set(blockedUntil.keys)
        work = Task {
            guard let visible = await WiFi.scan() else {
                finish(nil)
                return
            }
            scansThisConnection += 1
            if scansThisConnection <= Self.baselineScans {
                let inRange = HotspotRules.usableNetworks(visible: visible, saved: saved, hotspot: hotspot)
                passedOver.formUnion(inRange.map(\.name))
                finish(nil)
                return
            }
            guard let target = HotspotRules.switchBackTarget(
                visible: visible, saved: saved, hotspot: hotspot, excluding: blocked.union(passedOver)
            ) else {
                finish(nil)
                return
            }
            activity = .switching(to: target)
            if let problem = await WiFi.join(target) {
                blockedUntil[target] = now.addingTimeInterval(Self.blockDuration)
                finish("Couldn't switch to \(target). \(problem)")
            } else if await WiFi.hasInternet() {
                joinedByApp = false
                finish("Switched from the hotspot to \(target).")
            } else {
                // Leave it blocked; the fallback rule rejoins the hotspot if a session is running.
                blockedUntil[target] = now.addingTimeInterval(Self.blockDuration)
                failedProbes = 2
                finish("\(target) had no internet.")
            }
        }
    }

    private func finish(_ event: String?) {
        activity = .idle
        work = nil
        if let event {
            note(event)
        }
    }

    private func note(_ event: String) {
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        lastEvent = "\(time)  \(event)"
    }
}
