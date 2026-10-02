import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    let done: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            HStack {
                Button(action: done) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .overlay { Text("Settings").font(.headline) }
            .padding(.horizontal, PanelView.inset)
            .padding(.vertical, 12)

            Divider()

            group("Keep awake") {
                SettingRow("Default length") {
                    Picker("Default length", selection: $settings.defaultLength) {
                        ForEach(Session.lengths, id: \.self) { length in
                            Text(length.map(Format.duration) ?? "No limit").tag(length)
                        }
                    }
                    .fixedSize()
                }
            }

            Divider()

            group("Switch off early when") {
                SettingRow("Battery drops to \(settings.batteryFloor)%") {
                    Toggle("Battery is low", isOn: $settings.batteryFloorEnabled)
                } stepper: {
                    Stepper("Battery level", value: $settings.batteryFloor, in: 5...80, step: 5)
                        .disabled(!settings.batteryFloorEnabled)
                }
                SettingRow("The Mac runs hot") {
                    Toggle("The Mac runs hot", isOn: $settings.stopWhenHot)
                }
                SettingRow("Auto has been on for \(Format.spelledDuration(TimeInterval(settings.autoLimitHours * 3600)))") {
                    Toggle("Auto has been on too long", isOn: $settings.autoLimitEnabled)
                } stepper: {
                    Stepper("Hours on Auto", value: $settings.autoLimitHours, in: 1...24)
                        .disabled(!settings.autoLimitEnabled)
                }
                SettingRow("Agents are idle for \(settings.agentsGraceMinutes) min") {
                    Toggle("Agents have finished", isOn: $settings.stopWhenAgentsFinish)
                } stepper: {
                    Stepper("Idle minutes", value: $settings.agentsGraceMinutes, in: 5...60, step: 5)
                        .disabled(!followsAgents)
                }
                if followsAgents {
                    HStack(spacing: 12) {
                        ForEach(Agent.allCases) { agent in
                            Toggle(agent.displayName, isOn: watching(agent))
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, 16)
                    note("Auto always ends this way. On does once an agent has worked since.")
                }
            }

            Divider()

            group("Hotspot") {
                SettingRow("Phone") {
                    Picker("Phone", selection: $settings.hotspotName) {
                        Text("None").tag("")
                        ForEach(phoneChoices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .fixedSize()
                }
                SettingRow("Leave when saved Wi-Fi appears") {
                    Toggle("Leave when saved Wi-Fi appears", isOn: $settings.switchBackToWiFi)
                }
                if settings.switchBackToWiFi, !model.hotspot.canSeeNetworkNames {
                    SettingRow("Needs Location Services to see Wi-Fi names") {
                        Button("Allow…") { model.hotspot.requestLocationAccess() }
                            .buttonStyle(ChipStyle())
                            .frame(width: 64)
                    }
                }
                note("Only joins during a keep-awake session. Only leaves when a saved network comes into range.")
            }

            Divider()

            group("General") {
                SettingRow("Open at login") {
                    Toggle("Open at login", isOn: $opensAtLogin)
                        .onChange(of: opensAtLogin) { _, enabled in
                            setOpensAtLogin(enabled)
                        }
                }
                SettingRow("Lid-closed permission") {
                    if model.session.hasPermission {
                        Text("Granted").foregroundStyle(.secondary)
                    } else {
                        Button("Allow…") { model.session.installPermission() }
                            .buttonStyle(ChipStyle())
                            .frame(width: 64)
                            .disabled(model.session.isInstallingPermission)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onAppear {
            model.session.refreshPermission()
            model.hotspot.reloadSavedNetworks()
        }
    }

    /// Whether agents can switch keep-awake on or off, which is when the idle time and the list of agents matter.
    private var followsAgents: Bool {
        model.settings.startWithAgents || model.settings.stopWhenAgentsFinish
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            rows()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PanelView.inset)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Saved networks with phone-like names first, since that's what a hotspot is called.
    private var phoneChoices: [String] {
        let saved = model.hotspot.savedNetworks
        let current = model.settings.hotspotName
        let all = saved.contains(current) || current.isEmpty ? saved : [current] + saved
        return all.filter(HotspotRules.looksLikePhone) + all.filter { !HotspotRules.looksLikePhone($0) }.sorted()
    }

    private func watching(_ agent: Agent) -> Binding<Bool> {
        Binding {
            model.settings.watchedAgents.contains(agent)
        } set: { watched in
            if watched {
                model.settings.watchedAgents.insert(agent)
            } else {
                model.settings.watchedAgents.remove(agent)
            }
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// A setting on one line: what it is on the left, its switch on the right.
/// A stepper, if there is one, sits beside the number it changes.
private struct SettingRow<Control: View, Adjuster: View>: View {
    let title: String
    let control: Control
    let stepper: Adjuster

    init(_ title: String, @ViewBuilder control: () -> Control, @ViewBuilder stepper: () -> Adjuster = { EmptyView() }) {
        self.title = title
        self.control = control()
        self.stepper = stepper()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            stepper
            Spacer(minLength: 8)
            control
        }
        .labelsHidden()
    }
}
