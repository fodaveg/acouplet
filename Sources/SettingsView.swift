import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

extension SettingsStore {
    var controlAccentColor: NSColor {
        if useSystemAccentColor { return .controlAccentColor }
        return NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 170.0 / 255, green: 137.0 / 255, blue: 64.0 / 255, alpha: 1)
            }
            return NSColor(srgbRed: 140.0 / 255, green: 107.0 / 255, blue: 10.0 / 255, alpha: 1)
        }
    }
    var tintColor: Color { Color(nsColor: controlAccentColor) }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator
    @EnvironmentObject private var audioRoute: MacAudioRouteObserver
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    @State private var showsDriverRemovalConfirmation = false
    @State private var isOpeningDriverRemoval = false
    @State private var driverRemovalError: String?
    #endif
    #if ACOUPLET_SPARKLE
    @EnvironmentObject private var updater: AppUpdater
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if DEBUG
        let _ = SettingsLifecycleProbe.recordBody()
        #endif
        TabView(selection: $settings.selectedSettingsPane) {
            Tab("General", systemImage: "gear", value: "general") {
                general
            }
            Tab(headphones.deviceModel.isSpeaker ? String(localized: "Speakers") : String(localized: "Headphones"),
                systemImage: headphones.deviceModel.systemSymbol, value: "headphones") {
                headphoneControls
            }
            Tab("Advanced", systemImage: "gearshape.2", value: "advanced") {
                advanced
            }
        }
        .formStyle(.grouped)
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
        .accessibilityIdentifier("settings.form")
        .onAppear {
            settings.refreshLaunchStatus()
            settings.refreshAppLanguage()
            #if DEBUG
            if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbe.appearances += 1 }
            #endif
        }
        .task(id: soundPressureRefreshInterval) {
            guard let interval = soundPressureRefreshInterval else { return }
            while !Task.isCancelled {
                headphones.refreshSoundPressure(automatically: true)
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
        .onChange(of: soundPressureRefreshInterval) { _, interval in
            if interval == nil { headphones.invalidateSoundPressureReading() }
        }
        .onDisappear {
            headphones.invalidateSoundPressureReading()
            #if DEBUG
            if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbe.disappearances += 1 }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                settings.refreshLaunchStatus()
                settings.refreshAppLanguage()
            }
            else { headphones.invalidateSoundPressureReading() }
        }
        .onChange(of: settings.selectedSettingsPane) { _, pane in
            if pane != "headphones" { headphones.invalidateSoundPressureReading() }
        }
        .onChange(of: headphones.connectionTransition?.alert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
        .onChange(of: headphones.multipointTransition?.alert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
    }

    private var soundPressureRefreshInterval: Int? {
        guard scenePhase == .active, settings.selectedSettingsPane == "headphones", headphones.isReady, headphones.powerOffState == nil, !headphones.isRunningHeadphoneTest,
              headphones.soundPressure.available == true, !headphones.soundPressure.isStopped,
              !headphones.soundPressureAutomaticRefreshSuspended,
              headphones.connectionTransition?.isFinished != false, headphones.sourceTransition?.isFinished != false,
              headphones.multipointTransition?.isFinished != false, headphones.deviceActionTransition?.isFinished != false else { return nil }
        return headphones.soundPressure.intervalSeconds
    }

    private var general: some View {
        Form {
            Section {
                Picker("App language", selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.setAppLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.appLanguage")
                if settings.appLanguageNeedsRestart {
                    Text("Quit and reopen Acouplet to apply the language change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.appLanguageRestart")
                }
                Toggle("Use system accent color", isOn: $settings.useSystemAccentColor)
                    .accessibilityIdentifier("settings.systemAccent")
            }
            Section("Menu Bar") {
                Toggle("Keep icon visible when disconnected", isOn: $settings.keepMenuBarIconWhenDisconnected)
                    .accessibilityIdentifier("menuBar.keepIcon")
                Toggle("Show battery percentage", isOn: $settings.showBatteryInMenuBar)
            }
            Section("Connection") {
                Toggle("Reconnect automatically", isOn: $settings.reconnectAutomatically)
                if settings.hasBackgroundService {
                    LabeledContent("Background access") {
                        Text(settings.backgroundServiceStatus == .enabled ? String(localized: "Allowed") : String(localized: "Not enabled")).foregroundStyle(.primary)
                    }
                    Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                }
                if let error = settings.backgroundServiceMigrationError ?? settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if settings.backgroundServiceMigrationError != nil {
                        Button("Retry") { settings.retryBackgroundServiceMigration?() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Keyboard") {
                Toggle("Global ANC / Ambient shortcut", isOn: $settings.globalShortcutEnabled)
                    .help("Available while Acouplet is running.")
                LabeledContent("Shortcut") {
                    Text("⌥⌘A").foregroundStyle(.primary)
                }
                if let error = settings.globalShortcutError {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            Section("Alerts") {
                Toggle("Low battery", isOn: $settings.lowBatteryNotificationsEnabled)
                .accessibilityIdentifier("notifications.lowBattery")
                Toggle("Firmware updates", isOn: $settings.firmwareNotificationsEnabled)
                .accessibilityIdentifier("notifications.firmware")
            }
            Section("Experimental Features") {
                Toggle("Show LDAC controls", isOn: $settings.experimentalLDACEnabled)
                    .accessibilityIdentifier("experimental.ldac")
                if settings.experimentalLDACEnabled {
                    Picker("Sample Rate", selection: $settings.ldacConfiguration.sampleRate) {
                        ForEach(LDACSampleRate.allCases, id: \.self) { rate in
                            Text(rate.displayName).tag(rate)
                        }
                    }
                    .disabled(ldac.isSessionRunning || ldac.state == .waitingForDevice)
                    .accessibilityIdentifier("ldac.sampleRate")
                    Picker("Playback Quality", selection: $settings.ldacConfiguration.quality) {
                        ForEach(LDACQuality.allCases, id: \.self) { quality in
                            let configuration = LDACConfiguration(sampleRate: settings.ldacConfiguration.sampleRate, quality: quality)
                            Text(configuration.qualityDisplayName).tag(quality)
                        }
                    }
                    .disabled(ldac.isSessionRunning || ldac.state == .waitingForDevice)
                    .accessibilityIdentifier("ldac.quality")
                    if !ldac.isSessionRunning { LDACDriverGuidance() }
                }
                if settings.experimentalLDACEnabled, ldac.targetAddress == headphones.address,
                   ldac.audioCaptureAccess == .permissionRequired {
                    LDACPermissionGuidance()
                }
                if hasInstalledLDACDriver {
                    Button("Remove LDAC Audio Driver…") { showsDriverRemovalConfirmation = true }
                        .disabled(ldac.needsStopBeforeTermination || ldac.isOpeningDriverInstaller || isOpeningDriverRemoval
                                  || settings.backgroundServiceMigrationError != nil)
                        .alert("Remove LDAC Audio Driver?", isPresented: $showsDriverRemovalConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Continue") {
                                isOpeningDriverRemoval = true
                                driverRemovalError = nil
                                Task {
                                    do {
                                        try await LDACDriverInstaller.openUninstaller()
                                        NSApp.terminate(nil)
                                    } catch {
                                        driverRemovalError = error.localizedDescription
                                    }
                                    isOpeningDriverRemoval = false
                                }
                            }
                        } message: {
                            Text("Acouplet will quit and open the removal installer. Restart your Mac after removing the driver.")
                        }
                    if let driverRemovalError {
                        Text(driverRemovalError).font(.caption).foregroundStyle(.primary)
                    }
                }
            }
            #endif
            #if ACOUPLET_SPARKLE
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!updater.allowsAutomaticUpdates)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Version \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("settings.version")
            }
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private var hasInstalledLDACDriver: Bool {
        switch ldac.driverState {
        case .current, .outdated, .restartRequired: true
        case .missing, .unavailable: false
        }
    }
    #endif

    private var headphoneControls: some View {
        Form {
            Section("Headphones") {
                if devices.hasOtherSelectableDevices {
                    ConnectedHeadphonePicker()
                } else {
                    LabeledContent("Device") {
                        Text(headphones.deviceName)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("headphones.deviceName")
                    }
                }
                if let color = headphones.deviceInformation.color {
                    LabeledContent("Color") {
                        Text(color.title).foregroundStyle(.primary)
                    }
                }
                if let firmware = headphones.firmwareVersion {
                    #if !ACOUPLET_PUBLIC_APIS_ONLY
                    FirmwareUpdateControl(firmware: firmware)
                    #else
                    LabeledContent("Firmware") {
                        Text(firmware).foregroundStyle(.primary)
                    }
                    #endif
                }
                HeadphoneConnectionView()
            }
            Section("Sound") {
                LabeledContent("Mac audio output", value: audioOutputName)
                    .accessibilityIdentifier("audio.macOutput")
                Link("Sound Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                    .foregroundStyle(Color.accentColor)
                if headphones.supportsConnectionMode || headphones.connectionTransition != nil {
                    ConnectionModeControl()
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
                }
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                if ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Restore the previous Stable Connection preference?")
                            .font(.caption)
                        HStack {
                            Button("Restore Stable Connection") {
                                ldac.restorePendingConnectionPreference(forAddress: headphones.address)
                            }
                            .disabled(!ldac.canRestoreConnectionPreference(forAddress: headphones.address))
                            Button("Keep Current Preference") {
                                ldac.keepConnectionPreference(forAddress: headphones.address)
                            }
                            .disabled(ldac.needsStopBeforeTermination)
                        }
                    }
                }
                #endif
                if headphones.audioFeatures.supportsCodecStatus {
                    LabeledContent("Headphone codec") {
                        Text(headphones.audioFeatures.codec?.title ?? String(localized: "Unknown")).foregroundStyle(.primary)
                    }
                        .accessibilityIdentifier("audio.codec")
                        .help("Reported by the headphones. With two devices connected, this may describe audio from the other device.")
                }
                if headphones.soundPressure.isSupported { SoundPressureControl() }
                if headphones.legacySurround.isSupported { LegacySoundEffectControl(kind: .surround) }
                if headphones.legacySoundPosition.isSupported { LegacySoundEffectControl(kind: .soundPosition) }
                if headphones.supportsDSEE {
                    DSEEControl().disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
                }
            }
            if headphones.legacyOptimizer.isSupported || headphones.legacyOptimizerTransition != nil {
                Section("Noise Cancelling") { LegacyOptimizerControl() }
            }
            if headphones.noiseControl?.inquiryType == 0x19 {
                Section("Noise Adaptation") {
                    NoiseAdaptationControl()
                }
            }
            if headphones.systemFeatures[.headGestures] != nil || headphones.headGesturePractice.isSupported || headphones.headGesturePracticeTransition != nil {
                Section("Head Gestures") {
                    SystemFeatureControl(feature: .headGestures)
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
                    if headphones.headGesturePractice.isSupported || headphones.headGesturePracticeTransition != nil {
                        HeadGesturePracticeControl()
                    }
                }
            }
            if headphones.earTipFit.isSupported || headphones.earTipFitTransition != nil {
                Section("Earbud Fit") { EarTipFitControl() }
            }
            FindEarbudsControl()
            if MultipointControls.isVisible(for: headphones.multipoint) || MultipointSettingControl.enabled(for: headphones) != nil {
                Section("Devices") {
                    MultipointSettingControl()
                    if MultipointControls.isVisible(for: headphones.multipoint) {
                        MultipointControls()
                    }
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
            }
            if SonySystemFeature.allCases.contains(where: { $0 != .headGestures && headphones.systemFeatureState($0) != nil && headphones.systemFeatureState($0)?.isVisible != false })
                || headphones.automaticPowerOff != nil || headphones.systemFeatures.sidetone != nil
                || headphones.systemFeatures.voiceAssistant != nil
                || headphones.voiceGuidance.supportsGuidance {
                Section("Headphone Controls") {
                    ForEach(SonySystemFeature.allCases.filter { $0 != .headGestures && $0 != .voiceAssistantWakeWord }, id: \.self) { feature in
                        SystemFeatureControl(feature: feature)
                    }
                    VoiceAssistantControl()
                    SystemFeatureControl(feature: .voiceAssistantWakeWord)
                    AutomaticPowerOffControl()
                    SidetoneControl()
                    VoiceGuidanceControls()
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
            }
            if headphones.powerFeatures.batteryCare != nil || headphones.powerFeatures.autoPowerSave != nil {
                Section("Battery") {
                    BatteryCareControl()
                    AutoPowerSaveControl()
                }
                .disabled(!headphones.isReady || headphones.isRunningHeadphoneTest || headphones.powerOffState != nil
                          || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false
                          || headphones.deviceActionTransition?.isFinished == false)
            }
            if headphones.touchAssignments.inquiryType != nil {
                Section(headphones.touchAssignments.keys?.allSatisfy { $0.keyType == 1 } == true ? String(localized: "Button Controls") : String(localized: "Touch Controls")) {
                    if let keys = headphones.touchAssignments.keys {
                        if headphones.deviceModel.isEarbuds, keys.contains(where: { $0.key <= 0x01 }) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(keys.filter { $0.key <= 0x01 }.sorted { $0.key < $1.key }, id: \.key) { key in
                                    TouchAssignmentControl(key: key)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                        }
                        ForEach(keys.filter { !headphones.deviceModel.isEarbuds || $0.key > 0x01 }, id: \.key) { key in
                            TouchAssignmentControl(key: key)
                        }
                    } else if headphones.settingErrors[.touchCustomActions] == nil && headphones.settingErrors[.touchAssignments] == nil {
                        Text("Reading touch controls…").foregroundStyle(.primary)
                    }
                    if headphones.pendingChanges[.touchAssignments] != nil || headphones.pendingChanges[.touchCustomActions] != nil {
                        ProgressView("Updating touch controls…").controlSize(.small)
                    }
                    if let error = headphones.settingErrors[.touchCustomActions] ?? headphones.settingErrors[.touchAssignments] {
                        Text(error).font(.caption).foregroundStyle(.primary)
                    }
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
            }
        }
    }

    private var advanced: some View {
        Form {
            Section("Mac Audio Output") {
                LabeledContent("Device", value: audioOutputName)
                if let route = audioRoute.route {
                    LabeledContent("Transport", value: route.transport?.title ?? String(localized: "Unknown"))
                    LabeledContent("Audio format", value: route.pcmFormatDescription)
                        .help(route.transport?.rawValue == kAudioDeviceTransportTypeUSB
                              ? String(localized: "A USB Bluetooth transmitter controls its wireless connection and codec.")
                              : String(localized: "The Mac’s output format does not identify the Bluetooth wireless codec."))
                }
                if audioRoute.error != nil {
                    Text("Some audio output details are unavailable. Copy diagnostics for details.")
                        .font(.caption)
                }
            }
            Section("Connection") {
                if !headphones.usesBluetoothLE {
                    LabeledContent("Bluetooth address") {
                        Text(headphones.address.isEmpty ? String(localized: "Not found") : headphones.address).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Headphone controls") {
                    Text(headphones.isReady && headphones.powerOffState == nil ? String(localized: "Ready") : headphones.statusText).foregroundStyle(.primary)
                }
            }
            Section("Diagnostics") {
                LabeledContent("Bluetooth device") {
                    Text(headphones.isDeviceConnected ? String(localized: "Connected") : String(localized: "Disconnected")).foregroundStyle(.primary)
                }
                LabeledContent("Protocol") {
                    Text(headphones.controlProtocol).foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                if let identifier = headphones.controlPeripheralID {
                    LabeledContent("LE peripheral") {
                        Text(identifier.uuidString).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Last sync") {
                    Text(lastSyncText).foregroundStyle(.primary)
                }
                if let error = headphones.lastErrorMessage {
                    LabeledContent("Last issue") {
                        Text(error)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Sync Now") {
                        if headphones.address.isEmpty { devices.refreshDiscovery() }
                        else { headphones.refresh() }
                    }
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                    Spacer()
                    Button("Copy Diagnostics") { copyDiagnostics() }
                }
                if headphones.protocolInformation?.generation != .v1 {
                    HStack {
                        Button("Connect Controls with Bluetooth LE") { headphones.connectBluetoothLE() }
                            .disabled(headphones.usesBluetoothLE || headphones.linkState == .opening || headphones.linkState == .handshaking
                                      || headphones.isPoweringOff
                                      || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                        if headphones.usesBluetoothLE {
                            Button("Reconnect Controls") { headphones.connect() }
                                .disabled(headphones.isPoweringOff || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                        }
                    }
                }
                if let error = headphones.bluetoothLEError {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
        }
        .tint(.primary)
    }

    private var audioOutputName: String {
        audioRoute.route?.name ?? (audioRoute.route != nil || audioRoute.error != nil ? String(localized: "Unavailable") : String(localized: "No output selected"))
    }

    private var lastSyncText: String {
        headphones.lastSyncDate?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "Never")
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(headphones.diagnosticReport + "\n" + audioRoute.diagnosticReport, forType: .string)
    }
}

#if !ACOUPLET_PUBLIC_APIS_ONLY
private struct FirmwareUpdateControl: View {
    let firmware: String
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var notifications: SonyNotificationService
    @State private var request: UUID?
    @State private var isChecking = false
    @State private var availability: SonyFirmwareAvailability?

    var body: some View {
        LabeledContent("Firmware") {
            HStack(spacing: 12) {
                Text(firmware).foregroundStyle(.primary)
                    .accessibilityIdentifier("headphones.firmwareVersion")
                Button(isChecking ? String(localized: "Checking…") : String(localized: "Check for Updates")) {
                    isChecking = true
                    availability = nil
                    request = UUID()
                }
                .disabled(isChecking || headphones.firmwareUpdateSession == nil || headphones.firmwareUpdateIdentity == nil)
                .accessibilityIdentifier("headphones.checkFirmware")
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .task(id: headphones.firmwareUpdateSession) {
            headphones.requestFirmwareUpdateIdentity()
            availability = nil
        }
        .task(id: request) {
            guard request != nil else { return }
            defer { isChecking = false }
            guard let session = headphones.firmwareUpdateSession, let identity = headphones.firmwareUpdateIdentity else { return }
            let result = await notifications.checkFirmware(identity: identity, currentVersion: firmware)
            guard !Task.isCancelled, headphones.firmwareUpdateSession == session,
                  headphones.firmwareUpdateIdentity == identity, headphones.firmwareVersion == firmware else { return }
            availability = result
        }
        .onChange(of: firmware) { _, _ in availability = nil }
        if let availability {
            Text(statusText(availability))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statusText(availability))
                .accessibilityIdentifier("headphones.firmwareUpdateStatus")
        }
    }

    private func statusText(_ availability: SonyFirmwareAvailability) -> String {
        switch availability {
        case .available(let version): String(localized: "Firmware \(version) is available. Install it with Sony | Sound Connect.")
        case .noUpdate: String(localized: "Firmware is up to date.")
        case .unavailable: String(localized: "Couldn’t check for updates. Try again.")
        }
    }
}
#endif

private struct HeadGesturePracticeControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsPractice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.headGesturePracticeTransition == nil ? String(localized: "Practice Head Gestures…") : String(localized: "Practice Details…")) {
                if headphones.beginHeadGesturePractice() { showsPractice = true }
            }
            .tint(.primary)
            .disabled(headphones.headGesturePracticeTransition == nil && headphones.headGesturePracticeUnavailableReason != nil)
            .help(headphones.headGesturePracticeUnavailableReason ?? "")
            .accessibilityIdentifier("gesture.open")
            .sheet(isPresented: $showsPractice) {
                if let transition = headphones.headGesturePracticeTransition {
                    HeadGesturePracticeSheet(transitionID: transition.id)
                }
            }
            if headphones.headGesturePracticeTransition?.phase == .interrupted,
               let message = headphones.headGesturePracticeTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HeadGesturePracticeSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var target = SonyHeadGesturePractice.Gesture.nod
    @State private var feedbackAfterRevision: UInt64 = 0
    @State private var countAtSelection = 0

    private var detectedGesture: SonyHeadGesturePractice.Gesture? {
        headphones.headGesturePractice.gestureRevision > feedbackAfterRevision ? headphones.headGesturePractice.receivedGesture : nil
    }

    private var matchingGestureCount: Int {
        min(3, max(0, headphones.headGesturePractice.count(for: target) - countAtSelection))
    }

    var body: some View {
        if let transition = headphones.headGesturePracticeTransition, transition.id == transitionID {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Text("Practice Head Gestures").font(.headline)
                        .accessibilityIdentifier("gesture.title")
                    Spacer(minLength: 0)
                    Picker("Gesture", selection: $target) {
                        Text("Nod").tag(SonyHeadGesturePractice.Gesture.nod)
                        Text("Shake").tag(SonyHeadGesturePractice.Gesture.shake)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 136)
                    .disabled(transition.phase != .ready && transition.phase != .practicing)
                    .accessibilityIdentifier("gesture.target")
                }
                GroupBox {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            let head = Image(systemName: "face.smiling.inverse")
                                .font(.system(size: 28))
                                .foregroundStyle(.tint)
                            if !reduceMotion && scenePhase == .active && matchingGestureCount < 3
                                && transition.phase == .practicing {
                                head.phaseAnimator([0, -1, 0, 1]) { content, phase in
                                    content.offset(x: target == .shake ? CGFloat(phase) * 6 : 0,
                                                   y: target == .nod ? CGFloat(phase) * 6 : 0)
                                } animation: { _ in .easeInOut(duration: 0.35) }
                            } else {
                                head
                            }
                            Image(systemName: target == .nod ? "arrow.up.and.down" : "arrow.left.and.right")
                                .font(.callout.weight(.medium))
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 64)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            if let message = transition.message {
                                Text(message).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("gesture.message")
                            } else if transition.phase == .practicing {
                                HStack(spacing: 6) {
                                    Image(systemName: matchingGestureCount == 3 || detectedGesture == target ? "checkmark.circle.fill" : detectedGesture == nil ? "circle.dotted" : "arrow.trianglehead.clockwise")
                                        .foregroundStyle(matchingGestureCount == 3 || detectedGesture == target ? Color.green : Color.secondary)
                                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                        .symbolEffectsRemoved(reduceMotion || detectedGesture != target)
                                        .symbolEffect(.bounce, value: matchingGestureCount)
                                        .accessibilityHidden(true)
                                    if matchingGestureCount == 3 {
                                        Text("All set")
                                    } else if let detectedGesture {
                                        Text("\(detectedGesture.title) detected")
                                    } else {
                                        Text("Waiting for a gesture…")
                                    }
                                }
                                .font(.headline)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier(matchingGestureCount == 3 ? "gesture.success" : detectedGesture == nil ? "gesture.waiting" : "gesture.detected")
                            } else if transition.phase == .finished {
                                Text("Practice has ended.").font(.headline)
                            } else {
                                Text("Wear both earbuds and face forward.")
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if transition.message == nil && transition.phase != .finished {
                                Text(target == .nod ? String(localized: "Face forward, then nod your head up and down.") : String(localized: "Face forward, then shake your head from side to side."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if transition.waitingForReport {
                                HeadphoneTestProgress(title: transition.phase == .checking ? String(localized: "Preparing practice…") : transition.phase == .entering ? String(localized: "Starting practice…") : String(localized: "Ending practice…"))
                                    .accessibilityIdentifier("gesture.progress")
                            } else if transition.phase == .practicing {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(matchingGestureCount) of 3 gestures detected")
                                        .font(.caption).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("gesture.count")
                                    HStack(spacing: 5) {
                                        ForEach(0..<3) { index in
                                            ProgressView(value: index < matchingGestureCount ? 1 : 0, total: 1)
                                                .progressViewStyle(.linear)
                                                .tint(index < matchingGestureCount ? .green : .clear)
                                                .frame(width: 18)
                                        }
                                    }
                                    .accessibilityHidden(true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                    .padding(6)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                Text("If a gesture is not detected, face forward and remain still for a moment before trying again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(transition.message == nil && transition.phase != .finished ? 1 : 0)
                    .accessibilityHidden(transition.message != nil || transition.phase == .finished)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(transition.canDismiss || transition.phase == .practicing ? String(localized: "Done") : String(localized: "Cancel")) {
                        if transition.canDismiss {
                            headphones.dismissHeadGesturePractice(id: transitionID)
                            dismiss()
                        } else { headphones.cancelHeadGesturePractice(id: transitionID) }
                    }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)
                    .disabled(transition.phase == .leaving)
                    .accessibilityIdentifier("gesture.cancel")
                    if transition.phase == .ready {
                        Button("Start Practice") { headphones.startHeadGesturePractice(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartHeadGesturePractice)
                            .accessibilityIdentifier("gesture.start")
                    }
                }
            }
            .padding(20)
            .frame(width: 440, height: 296)
            .presentationSizing(.fitted)
            .accessibilityElement(children: .contain)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .onChange(of: transition.phase) { _, phase in
                if phase == .finished, transition.shouldDismiss {
                    headphones.dismissHeadGesturePractice(id: transitionID)
                    dismiss()
                }
            }
            .onChange(of: target) { _, _ in
                feedbackAfterRevision = headphones.headGesturePractice.gestureRevision
                countAtSelection = headphones.headGesturePractice.count(for: target)
            }
            .onChange(of: headphones.headGesturePractice.gestureRevision) { _, _ in
                if NSWorkspace.shared.isVoiceOverEnabled, let gesture = headphones.headGesturePractice.receivedGesture {
                    NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
                                         userInfo: [.announcement: matchingGestureCount == 3 ? String(localized: "All set") : String(localized: "\(gesture.title) detected"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
            .onDisappear { headphones.cancelHeadGesturePractice(id: transitionID, dismissWhenFinished: true) }
        }
    }
}

private struct LegacyOptimizerControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsOptimizer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.legacyOptimizerTransition == nil ? String(localized: "Optimize Noise Cancelling…") : String(localized: "Optimizer Details…")) {
                if headphones.beginLegacyOptimizer() { showsOptimizer = true }
            }
            .tint(.primary)
            .disabled(headphones.legacyOptimizerTransition == nil && headphones.legacyOptimizerUnavailableReason != nil)
            .help(headphones.legacyOptimizerUnavailableReason ?? "")
            .accessibilityIdentifier("optimizer.open")
            .sheet(isPresented: $showsOptimizer) {
                if let transition = headphones.legacyOptimizerTransition {
                    LegacyOptimizerSheet(transitionID: transition.id)
                }
            }
            if headphones.legacyOptimizerTransition?.phase == .interrupted,
               let message = headphones.legacyOptimizerTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LegacyOptimizerSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let transition = headphones.legacyOptimizerTransition, transition.id == transitionID {
            VStack(alignment: .leading, spacing: 20) {
                Text("Noise Cancelling Optimizer").font(.title2).fontWeight(.semibold)
                    .accessibilityIdentifier("optimizer.title")
                VStack(alignment: .leading, spacing: 20) {
                    if let message = transition.message {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("optimizer.message")
                    } else if transition.phase == .checking || transition.phase == .ready {
                        Text("Wear the headphones as you normally do. This test plays sounds. Avoid touching the headphones until it finishes.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if transition.phase == .completed {
                        Label {
                            Text("Optimization Complete")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                            .accessibilityIdentifier("optimizer.result")
                        if let result = transition.result {
                            if result.personalType == 1 {
                                LabeledContent("Personal optimization", value: result.personalMeasured.map { $0 ? String(localized: "Measured") : String(localized: "Not measured") } ?? String(localized: "Unknown"))
                            }
                            if result.pressureType == 1 {
                                LabeledContent("Atmospheric pressure", value: result.pressureAtmospheres.map {
                                    String(localized: "\($0.formatted(.number.precision(.fractionLength(1)))) atm")
                                } ?? (result.pressureValue == 0 ? String(localized: "Not measured") : String(localized: "Unknown")))
                            }
                        }
                    } else if transition.waitingForReport || transition.phase == .checking {
                        HeadphoneTestProgress(title: progressText(transition.phase))
                            .accessibilityIdentifier("optimizer.progress")
                    }
                    Spacer(minLength: 0)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                HStack {
                    Spacer()
                    Button((transition.canDismiss && transition.phase != .ready) || transition.phase == .completed ? String(localized: "Done") : String(localized: "Cancel")) {
                        if transition.canDismiss {
                            headphones.dismissLegacyOptimizer(id: transitionID)
                            dismiss()
                        } else { headphones.cancelLegacyOptimizer(id: transitionID) }
                    }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)
                    .disabled(transition.phase == .cancelling || transition.phase == .readingResult
                              || (transition.phase == .completed && !transition.canDismiss))
                    .accessibilityIdentifier("optimizer.cancel")
                    if transition.phase == .ready {
                        Button("Start Optimization") { headphones.startLegacyOptimizer(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartLegacyOptimizer)
                            .accessibilityIdentifier("optimizer.start")
                    }
                }
            }
            .padding(24)
            .frame(width: 460, height: 260)
            .presentationSizing(.fitted)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .onChange(of: transition.shouldDismiss) { _, shouldDismiss in
                if shouldDismiss {
                    headphones.dismissLegacyOptimizer(id: transitionID)
                    dismiss()
                }
            }
            .onDisappear {
                if headphones.legacyOptimizerTransition?.canDismiss != true {
                    headphones.cancelLegacyOptimizer(id: transitionID)
                }
                headphones.dismissLegacyOptimizer(id: transitionID)
            }
        }
    }

    private func progressText(_ phase: SonyLegacyOptimizerTransition.Phase) -> String {
        switch phase {
        case .checking: String(localized: "Checking headphones…")
        case .starting, .running: String(localized: "Optimizing noise cancellation…")
        case .readingResult: String(localized: "Reading results…")
        case .cancelling: String(localized: "Stopping optimization…")
        default: String(localized: "Waiting for headphones…")
        }
    }
}

private struct EarTipFitControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsTest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.earTipFitTransition == nil ? String(localized: "Check Earbud Fit…") : String(localized: "Fit Test Details…")) {
                if headphones.beginEarTipFit() { showsTest = true }
            }
            .tint(.primary)
            .disabled(headphones.earTipFitTransition == nil && headphones.earTipFitUnavailableReason != nil)
            .help(headphones.earTipFitUnavailableReason ?? "")
            .accessibilityIdentifier("fit.open")
            .sheet(isPresented: $showsTest) {
                if let transition = headphones.earTipFitTransition {
                    EarTipFitSheet(transitionID: transition.id)
                }
            }
            if headphones.earTipFitTransition?.phase == .interrupted,
               let message = headphones.earTipFitTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EarTipFitSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var resultHasFocus: Bool

    var body: some View {
        if let transition = headphones.earTipFitTransition, transition.id == transitionID {
            let passed = transition.phase == .result && transition.result?.left == .good && transition.result?.right == .good
            VStack(alignment: .leading, spacing: 20) {
                Text("Earbud Fit Test").font(.title2).fontWeight(.semibold)
                    .accessibilityIdentifier("fit.title")
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 32) {
                        earbud(.left, seal: transition.result?.left)
                        earbud(.right, seal: transition.result?.right)
                    }
                    .frame(maxWidth: .infinity)
                    if let selectedSeries = headphones.earTipFit.selectedSeries {
                        LabeledContent("Ear-tip type", value: selectedSeries.title)
                    }
                    if let message = transition.message {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fit.message")
                    } else if !passed {
                        Text(instructions(transition.phase)).fixedSize(horizontal: false, vertical: true)
                    }
                    if transition.waitingForReport {
                        HeadphoneTestProgress(title: progressText(transition.phase))
                            .accessibilityIdentifier("fit.progress")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: transition.phase == .result ? .center : .top)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                HStack {
                    if transition.phase == .result {
                        Button("Test Again") { headphones.prepareEarTipFitAgain(id: transitionID) }
                            .keyboardShortcut(passed ? nil : .defaultAction)
                            .tint(passed ? .primary : .accentColor)
                            .accessibilityIdentifier("fit.again")
                    }
                    Spacer()
                    Button(transition.canDismiss || transition.phase == .result ? String(localized: "Done") : String(localized: "Cancel")) {
                        close(transition)
                    }
                    .keyboardShortcut(passed ? .defaultAction : .cancelAction)
                    .tint(passed ? .accentColor : .primary)
                    .disabled(transition.phase == .cancelling || transition.phase == .leaving)
                    .accessibilityIdentifier("fit.cancel")
                    if transition.phase == .ready {
                        Button("Start Test") { headphones.startEarTipFit(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartEarTipFit)
                            .accessibilityIdentifier("fit.start")
                    }
                }
            }
            .padding(24)
            .frame(width: 460, height: 380)
            .presentationSizing(.fitted)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .focusable(passed, interactions: .edit)
            .focused($resultHasFocus)
            .focusEffectDisabled()
            .onExitCommand(perform: passed ? { close(transition) } : nil)
            .onChange(of: passed, initial: true) { _, passed in resultHasFocus = passed }
            .onChange(of: transition.phase) { _, phase in
                if phase == .finished, transition.shouldDismiss {
                    headphones.dismissEarTipFit(id: transitionID)
                    dismiss()
                }
            }
            .onDisappear { headphones.cancelEarTipFit(id: transitionID, dismissWhenFinished: true) }
        }
    }

    private func close(_ transition: SonyEarTipFitTransition) {
        if transition.canDismiss {
            headphones.dismissEarTipFit(id: transitionID)
            dismiss()
        } else { headphones.cancelEarTipFit(id: transitionID) }
    }

    private func earbud(_ side: EarbudSide, seal: SonyEarTipFit.Seal?) -> some View {
        VStack(spacing: 8) {
            EarbudArtwork(model: headphones.deviceModel, side: side, usesProductArtwork: headphones.usesProductArtwork,
                          artworkSuffix: headphones.productArtworkSuffix)
                .frame(width: 100, height: 100 * 103.0 / 137.0).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(side == .left ? String(localized: "Left") : String(localized: "Right")).font(.headline)
                if let seal {
                    Label {
                        Text(seal == .good ? String(localized: "Good seal") : String(localized: "Adjust fit"))
                    } icon: {
                        Image(systemName: seal == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(seal == .good ? Color.green : Color.yellow)
                    }
                        .accessibilityIdentifier(side == .left ? "fit.leftResult" : "fit.rightResult")
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    private func instructions(_ phase: SonyEarTipFitTransition.Phase) -> String {
        switch phase {
        case .checking, .ready:
            String(localized: "Wear both earbuds in a quiet place. The test plays a short sound.")
        case .entering, .starting, .measuring:
            String(localized: "Keep still and leave both earbuds in your ears.")
        case .result:
            String(localized: "Reposition the earbud or try another tip size, then test again.")
        case .cancelling, .leaving:
            String(localized: "Waiting for the earbuds to finish.")
        case .finished:
            String(localized: "The fit test has ended.")
        case .unavailable, .interrupted:
            String(localized: "The fit test is unavailable.")
        }
    }

    private func progressText(_ phase: SonyEarTipFitTransition.Phase) -> String {
        switch phase {
        case .checking: String(localized: "Reading earbud information…")
        case .entering, .starting: String(localized: "Starting test…")
        case .measuring: String(localized: "Measuring fit…")
        case .cancelling: String(localized: "Cancelling test…")
        default: String(localized: "Finishing test…")
        }
    }
}

private struct HeadphoneTestProgress: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.regular)
            Text(title).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct VoiceGuidanceControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.voiceGuidance
        if state.supportsGuidance {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setVoiceGuidance($0) }
                        )) {
                            HStack {
                                Text("Voice guidance")
                                if headphones.pendingChanges[.voiceGuidance] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating voice guidance")
                                }
                            }
                        }
                        .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                                  || headphones.pendingChanges[.voiceGuidance] != nil
                                  || state.setEnabledPayload(!enabled) == nil)
                        .accessibilityIdentifier("guidance.enabled")
                    } else {
                        LabeledContent("Voice guidance") { Text("Unknown").foregroundStyle(.primary) }
                    }
                }
                if let error = headphones.settingErrors[.voiceGuidance] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.supportsVolume {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker(selection: Binding(
                            get: { state.volume },
                            set: { if let volume = $0 { headphones.setVoiceGuidanceVolume(volume) } }
                        )) {
                            if state.volume == nil { Text("Unknown").tag(Int?.none).disabled(true) }
                            ForEach(SonyVoiceGuidance.volumeRange, id: \.self) { volume in
                                Text([String(localized: "Very low"), String(localized: "Low"), String(localized: "Medium"), String(localized: "High"), String(localized: "Very high")][volume + 2])
                                    .tag(Optional(volume))
                                    .disabled(state.setVolumePayload(volume) == nil)
                            }
                        } label: {
                            HStack {
                                Text("Guidance volume")
                                if headphones.pendingChanges[.voiceGuidanceVolume] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating guidance volume")
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                                  || headphones.pendingChanges[.voiceGuidanceVolume] != nil
                                  || !SonyVoiceGuidance.volumeRange.contains(where: { state.setVolumePayload($0) != nil }))
                        .accessibilityIdentifier("guidance.volume")
                    }
                    if let error = headphones.settingErrors[.voiceGuidanceVolume] {
                        Text(error).font(.caption).foregroundStyle(.primary)
                    } else if state.volumeAvailable == false {
                        Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SoundPressureControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Listening level") {
                HStack {
                    Text(reading).monospacedDigit().foregroundStyle(.primary)
                    if headphones.soundPressure.intervalSeconds == nil || headphones.soundPressureReadError != nil
                        || headphones.soundPressureAutomaticRefreshSuspended {
                        Button("Refresh") { headphones.refreshSoundPressure() }
                            .disabled(!headphones.canRefreshSoundPressure)
                            .tint(.primary)
                    }
                }
            }
            .accessibilityIdentifier("audio.listeningLevel")
            .help("Reported by the headphones for the current audio source.")
            if let error = headphones.soundPressureReadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var reading: String {
        if headphones.soundPressure.isStopped { return String(localized: "Measurement is off") }
        if headphones.soundPressure.available == false { return String(localized: "Unavailable") }
        guard headphones.soundPressure.available == true else { return "—" }
        return switch headphones.soundPressure.reading {
        case .decibels(let value): String(localized: "\(value) dB")
        case .notPlaying: String(localized: "Not playing")
        case .inCall: String(localized: "In a call")
        case .notWorn: String(localized: "Not worn")
        case .unknown, nil: "—"
        }
    }
}

private struct TouchAssignmentControl: View {
    let key: SonyTouchKeyCapability
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if headphones.deviceModel.isEarbuds, key.key <= 0x01 {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 8) {
                    EarbudArtwork(model: headphones.deviceModel, side: key.key == 0x00 ? .left : .right,
                                  usesProductArtwork: headphones.usesProductArtwork, artworkSuffix: headphones.productArtworkSuffix)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    Text(key.title(generation: headphones.touchAssignments.generation)).font(.headline)
                }
                .frame(maxWidth: .infinity)
                assignmentPicker
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(key.title(generation: headphones.touchAssignments.generation)) assignment")
                    .accessibilityIdentifier("touch.assignment.\(key.key)")
                gestures
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(key.title(generation: headphones.touchAssignments.generation)).font(.headline)
                assignmentPicker
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("touch.assignment.\(key.key)")
                gestures
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var gestures: some View {
        if let actions = headphones.touchAssignments.reportedActions(key: key.key) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions, id: \.action) { action in
                    let title = String(localized: "\(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation)): \(action.functionTitle(generation: headphones.touchAssignments.generation))")
                    let isTouch = key.keyType == 0x00 || key.keyType == 0x02
                    let usesMark = isTouch && [0x00, 0x01, 0x02, 0x10, 0x11].contains(action.action)
                    HStack(alignment: .top, spacing: 8) {
                        if isTouch {
                            HStack(spacing: 3) {
                                if usesMark, action.action <= 0x02 {
                                    ForEach(0...Int(action.action), id: \.self) { _ in
                                        Circle().frame(width: 6, height: 6)
                                    }
                                } else if usesMark {
                                    if action.action == 0x11 {
                                        Circle().frame(width: 6, height: 6)
                                    }
                                    Capsule().frame(width: 18, height: 6)
                                }
                            }
                            .frame(width: 28, height: 20)
                            .accessibilityHidden(true)
                        }
                        if headphones.touchAssignments.inquiryType == 0x03,
                           let customizable = headphones.touchAssignments.customizableActions(key: key.key)
                            .first(where: { $0.action == action.action }),
                           customizable.functions.contains(where: { (0x01...0x04).contains($0) }) {
                            gesturePicker(action, capability: customizable)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.functionTitle(generation: headphones.touchAssignments.generation))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel(title)
                                    .accessibilityIdentifier("touch.gesture.\(key.key).\(action.action)")
                                if !usesMark {
                                    Text(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .help(title)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
        } else if headphones.touchAssignments.selectedPreset(key: key.key) != nil {
            Text("Gesture details not reported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func gesturePicker(_ action: SonyTouchActionSetting, capability: SonyTouchCustomizableAction) -> some View {
        let state = headphones.touchAssignments
        let functions = capability.functions.filter { (0x01...0x04).contains($0) }
        let sharedKeys = state.selectedPreset(key: key.key).map { state.keysUsingPreset($0) } ?? []
        let scope = sharedKeys.count > 1 ? sharedKeys.map(\.title).joined(separator: ", ") : key.title(generation: headphones.touchAssignments.generation)
        return VStack(alignment: .leading, spacing: 4) {
            Picker(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation), selection: Binding(
                get: { action.function },
                set: { headphones.setTouchAction(key: key.key, action: action.action, function: $0) }
            )) {
                if !functions.contains(action.function) {
                    Text(action.functionTitle(generation: headphones.touchAssignments.generation)).tag(action.function).disabled(true)
                }
                ForEach(functions, id: \.self) { function in
                    Text(SonyTouchActionSetting(action: action.action, function: function).functionTitle)
                        .tag(function)
                        .disabled(state.setActionPayload(key: key.key, action: action.action, function: function) == nil)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("\(scope) \(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation)) action")
            .accessibilityIdentifier("touch.action.\(key.key).\(action.action)")
            .disabled(!headphones.canSetTouchAction(key: key.key, action: action.action))
            if sharedKeys.count > 1 {
                Text("Shared: \(scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("touch.shared.\(key.key).\(action.action)")
            }
        }
    }

    private var assignmentPicker: some View {
        let state = headphones.touchAssignments
        let selected = state.selectedPreset(key: key.key)
        return Picker(key.title(generation: headphones.touchAssignments.generation), selection: Binding(
            get: { selected },
            set: { if let preset = $0 { headphones.setTouchAssignment(key: key.key, preset: preset) } }
        )) {
            if !key.presets.contains(where: { $0.preset == selected }) {
                Text(selected == nil ? String(localized: "Not reported") : String(localized: "Unsupported assignment"))
                    .tag(selected).disabled(true)
            }
            ForEach(key.presets, id: \.preset) { preset in
                Text(preset.title(generation: state.generation)).tag(Optional(preset.preset))
                    .disabled(state.setPayload(key: key.key, preset: preset.preset) == nil)
            }
        }
        .disabled(!headphones.canSetTouchAssignment(key: key.key))
    }
}

private struct ConnectionModeControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var showsAlert = false
    @State private var requestedMode: SonyConnectionMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connection preference")
                if headphones.connectionTransition?.isFinished == false && headphones.connectionTransition?.awaitingUser == false
                    && headphones.connectionTransition?.phase != .pairingRequired {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Changing connection preference")
                }
                Spacer()
                Picker("Connection preference", selection: Binding(
                    get: { headphones.connectionMode },
                    set: { mode in
                        guard let mode else { return }
                        if headphones.protocolInformation?.generation == .v1 {
                            requestedMode = mode
                            showsAlert = true
                        } else {
                            headphones.setConnectionMode(mode)
                        }
                    }
                )) {
                    if headphones.connectionMode?.sonyValue == nil {
                        Text(headphones.connectionMode == nil ? String(localized: "Loading…") : String(localized: "Unknown"))
                            .tag(headphones.connectionMode)
                    }
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.title).tag(Optional(mode))
                            .disabled(headphones.connectionModeUnavailableReason(mode) != nil)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .fixedSize()
                .disabled(!modes.contains { $0 != headphones.connectionMode && headphones.connectionModeUnavailableReason($0) == nil })
                .accessibilityIdentifier("audio.connectionMode")
            }
            if let error = headphones.connectionModeError {
                Text(error).font(.caption).foregroundStyle(.primary)
                if headphones.connectionTransition?.phase == .failed,
                   !headphones.isReady || headphones.connectionTransition?.generation == .v1 {
                    Button(headphones.isReady ? String(localized: "Check Preference") : String(localized: "Retry Connection")) { headphones.connect() }
                        .accessibilityIdentifier("audio.retryConnection")
                }
            } else if let status = transitionStatus {
                Text(status).font(.caption).foregroundStyle(.primary)
            }
            if headphones.connectionTransition?.awaitingUser == true {
                Button("Review Change…") { showsAlert = true }
                    .accessibilityIdentifier("audio.reviewConnectionChange")
            }
            if let transition = headphones.connectionTransition, transition.phase == .pairingRequired {
                Text("Pair the headphones with this Mac in Bluetooth settings, then check the connection.")
                    .font(.caption).foregroundStyle(.primary)
                Text("Last reported preference: \((headphones.connectionMode ?? transition.originalMode).title)")
                    .font(.caption).foregroundStyle(.primary)
                HStack {
                    Button("Bluetooth Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                    }
                    .foregroundStyle(Color.accentColor)
                    Button("Check Connection") { headphones.connect() }
                        .accessibilityIdentifier("audio.checkPairedConnection")
                }
            }
        }
        .onChange(of: headphones.connectionTransition?.alert, initial: true) { _, alert in
            presentedAlert = alert
            showsAlert = alert != nil
        }
        .alert(alertTitle, isPresented: $showsAlert) {
            if let mode = requestedMode {
                Button("Cancel", role: .cancel) { requestedMode = nil }
                Button("Change Preference") {
                    requestedMode = nil
                    headphones.setConnectionMode(mode)
                }
            } else if let alert = presentedAlert {
                if alert.availableActions.contains(.negative) {
                    Button("Cancel", role: .cancel) { headphones.respondToConnectionAlert(alert, action: .negative) }
                }
                if alert.availableActions.contains(.positive) {
                    Button("Continue") { headphones.respondToConnectionAlert(alert, action: .positive) }
                } else if alert.actionType == .confirmationOnly {
                    Button("OK") { headphones.respondToConnectionAlert(alert, action: nil) }
                }
            }
        } message: {
            if requestedMode != nil {
                Text("The audio connection may briefly disconnect while the headphones apply this preference.")
            } else if let alert = presentedAlert {
                Text(alertMessage(alert))
            }
        }
    }

    private var alertTitle: String {
        if let requestedMode { return String(localized: "Use \(requestedMode.title)?") }
        guard let alert = presentedAlert else { return String(localized: "Connection Change") }
        if alert.isLegacyConnectionChange { return String(localized: "Use Stable Connection?") }
        if alert.actionType == .confirmationOnly { return String(localized: "Connection Change") }
        return String(localized: "Use \((alert.requestedMode ?? headphones.connectionTransition?.targetMode)?.title ?? String(localized: "this connection"))?")
    }

    private var modes: [SonyConnectionMode] {
        var modes = (headphones.supportedConnectionModes ?? []).filter { $0.sonyValue != nil && $0 != .lowLatency }
        if let current = headphones.connectionMode, current.sonyValue != nil, !modes.contains(current) {
            modes.insert(current, at: 0)
        }
        return modes
    }

    private func alertMessage(_ alert: SonyConnectionAlert) -> String {
        let message = switch (alert.format, alert.messageID) {
        case (.legacyFixed, 0x01):
            String(localized: "The headphones require Stable Connection to change these settings. The audio connection will reconnect and music will stop.")
        case (.flexible, 0x10):
            String(localized: "This change requires LE Audio pairing. Pair the headphones with this Mac before using LE Audio.")
        case (.flexible, 0x11):
            String(localized: "This connection uses LE Audio. This Mac also needs an LE Audio connection for playback.")
        default:
            String(localized: "This connection uses Classic Bluetooth. Reconnect the headphones to this Mac to resume audio.")
        }
        let features = alert.affectedFeatures.map(\.title)
        return features.isEmpty ? message : message + String(localized: "\n\nUnavailable with this connection: ") + features.joined(separator: ", ") + "."
    }

    private var transitionStatus: String? {
        guard let transition = headphones.connectionTransition else { return nil }
        switch transition.phase {
        case .queued: return String(localized: "Waiting to send…")
        case .awaitingResponse: return String(localized: "Changing connection preference…")
        case .awaitingUser: return String(localized: "The headphones need your confirmation.")
        case .replyQueued: return String(localized: "Sending your response…")
        case .pairingRequired: return String(localized: "Pairing required.")
        case .reconnecting, .recovering: return String(localized: "Reconnecting controls…")
        case .verifying: return String(localized: "Checking connection preference…")
        case .cancelled: return String(localized: "Change cancelled.")
        case .confirmed, .failed: return nil
        }
    }
}

private struct NoiseAdaptationControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.noiseControlDisplayState, let adaptationEnabled = state.adaptationEnabled,
           let sensitivity = state.sensitivity {
            HStack {
                Toggle(isOn: Binding(
                    get: { headphones.noiseControlDisplayState?.adaptationEnabled ?? adaptationEnabled },
                    set: { headphones.setNoiseAdaptation(enabled: $0) }
                )) {
                    HStack {
                        Text("Noise adaptation")
                        if headphones.pendingChanges[.noiseControl] != nil {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel("Updating noise control")
                        }
                    }
                }
                .disabled(!headphones.canChangeNoiseControl || headphones.pendingChanges[.noiseControl] != nil)
                .accessibilityIdentifier("noise.adaptation")
            }
            Picker("Sensitivity", selection: Binding(
                get: { headphones.noiseControlDisplayState?.sensitivity ?? sensitivity },
                set: headphones.setNoiseAdaptationSensitivity
            )) {
                ForEach(SonyNoiseControl.Sensitivity.allCases) { sensitivity in
                    Text(sensitivity.title).tag(sensitivity)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canChangeNoiseControl || !adaptationEnabled || headphones.pendingChanges[.noiseControl] != nil)
            .accessibilityIdentifier("noise.sensitivity")
            if let error = headphones.settingErrors[.noiseControl] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if headphones.noiseControl?.canSet != true {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Noise adaptation", value: String(localized: "Unavailable"))
        }
    }
}

struct LegacySoundEffectControl: View {
    let kind: SonyLegacySoundEffect.Kind
    @EnvironmentObject private var headphones: SonyHeadphonesController

    private var effect: SonyLegacySoundEffect { headphones.legacySoundEffect(kind) }
    private var setting: SonyHeadphonesController.Setting { .legacySoundEffect(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.title)
                if headphones.pendingChanges[setting] != nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating \(kind.title)")
                }
                Spacer()
                Picker(kind.title, selection: Binding(
                    get: { effect.presetID },
                    set: { if let preset = $0 { headphones.setLegacySoundEffect(kind, preset: preset) } }
                )) {
                    if !effect.selectablePresets.contains(where: { $0.id == effect.presetID }) {
                        Text(effect.selectedTitle ?? (headphones.settingErrors[setting] == nil ? String(localized: "Loading…") : String(localized: "Unknown")))
                            .tag(effect.presetID).disabled(true)
                    }
                    ForEach(effect.selectablePresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(maxWidth: 180, alignment: .trailing)
                .disabled(!headphones.canSetLegacySoundEffect(kind))
                .accessibilityIdentifier(kind == .surround ? "audio.surround" : "audio.soundPosition")
            }
            if let error = headphones.settingErrors[setting] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if effect.available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DSEEControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(headphones.dseeType?.title ?? "DSEE")
                if headphones.pendingChanges[.dsee] != nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating \(headphones.dseeType?.title ?? "DSEE")")
                }
                Spacer()
                Picker(headphones.dseeType?.title ?? "DSEE", selection: Binding(
                    get: { headphones.dseeMode },
                    set: { if let mode = $0 { headphones.setDSEE(mode) } }
                )) {
                    if headphones.dseeMode?.sonyValue == nil {
                        Text(headphones.dseeMode == nil && headphones.settingErrors[.dsee] == nil ? String(localized: "Loading…") : String(localized: "Unknown"))
                            .tag(headphones.dseeMode)
                    }
                    ForEach(SonyDSEEMode.allCases) { mode in
                        Text(mode.title).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .fixedSize()
                .disabled(!headphones.canSetDSEE)
                .accessibilityIdentifier("audio.dsee")
            }
            if let error = headphones.settingErrors[.dsee] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if headphones.dseeAvailable == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SystemFeatureControl: View {
    let feature: SonySystemFeature
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatureState(feature), state.isVisible != false {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setSystemFeature(feature, enabled: $0) }
                        )) {
                            HStack {
                                Text(feature.title)
                                if headphones.pendingChanges[.system(feature)] != nil {
                                    ProgressView().controlSize(.mini)
                                        .accessibilityLabel("Updating \(feature.title)")
                                }
                            }
                        }
                        .disabled(!headphones.canSetSystemFeature(feature))
                        .accessibilityIdentifier("system.\(feature.rawValue)")
                    } else {
                        LabeledContent(feature.title) {
                            Text("Unknown").foregroundStyle(.primary)
                        }
                    }
                }
                if let error = headphones.settingErrors[.system(feature)] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if feature == .speakToChat {
                SpeakToChatOptionsControl()
            }
        }
    }
}

private struct SpeakToChatOptionsControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let options = headphones.systemFeatures.speakToChatOptions {
            Group {
                Picker(selection: Binding(
                    get: { options.sensitivity },
                    set: { if let sensitivity = $0, let delay = options.delay {
                        headphones.setSpeakToChatOptions(sensitivity: sensitivity, delay: delay)
                    } }
                )) {
                    if options.sensitivity?.sonyValue == nil {
                        Text("Unknown").tag(options.sensitivity).disabled(true)
                    }
                    ForEach(SonySpeechSensitivity.options, id: \.self) { sensitivity in
                        Text(sensitivity.title).tag(Optional(sensitivity))
                    }
                } label: {
                    HStack {
                        Text("Voice detection sensitivity")
                        if headphones.pendingChanges[.speakToChatOptions] != nil {
                            ProgressView().controlSize(.mini).accessibilityLabel("Updating Speak-to-Chat")
                        }
                    }
                }
                .help("Choose High if speech is missed, or Low if Speak-to-Chat starts unintentionally.")
                .accessibilityIdentifier("system.speechSensitivity")
                Picker("End Speak-to-Chat", selection: Binding(
                    get: { options.delay },
                    set: { if let delay = $0, let sensitivity = options.sensitivity {
                        headphones.setSpeakToChatOptions(sensitivity: sensitivity, delay: delay)
                    } }
                )) {
                    if options.delay?.sonyValue == nil {
                        Text("Unknown").tag(options.delay).disabled(true)
                    }
                    ForEach(SonySpeakToChatDelay.options, id: \.self) { delay in
                        Text(delay.title).tag(Optional(delay))
                    }
                }
                .help("The delay begins when you stop speaking.")
                .accessibilityIdentifier("system.speakToChatDelay")
                if let error = headphones.settingErrors[.speakToChatOptions] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canSetSpeakToChatOptions)
        }
    }
}

private struct VoiceAssistantControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatures.voiceAssistant {
            let options = state.knownOptions
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(selection: Binding(
                        get: { state.knownCurrent },
                        set: { if let option = $0 { headphones.setVoiceAssistant(option) } }
                    )) {
                        if !options.contains(where: { $0 == state.knownCurrent }) {
                            Text(state.knownCurrent?.title ?? String(localized: "Unknown")).tag(state.knownCurrent)
                                .disabled(true)
                        }
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                                .disabled(state.setPayload(option) == nil)
                        }
                    } label: {
                        HStack {
                            Text("Voice assistant")
                            if headphones.pendingChanges[.voiceAssistant] != nil {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Updating voice assistant")
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .disabled(!headphones.canSetVoiceAssistant)
                    .help(headphones.audioFeatures.codec == .lc3
                          ? String(localized: "Voice assistant selection is unavailable with LE Audio.")
                          : String(localized: "Assistant setup is managed in Sony Sound Connect on your phone."))
                    .accessibilityIdentifier("system.voiceAssistant")
                }
                if let error = headphones.settingErrors[.voiceAssistant] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AutomaticPowerOffControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.automaticPowerOff {
            let options = state.knownOptions
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(selection: Binding(
                        get: { state.knownCurrent },
                        set: { if let option = $0 { headphones.setAutomaticPowerOff(option) } }
                    )) {
                        if !options.contains(where: { $0 == state.knownCurrent }) {
                            Text(state.knownCurrent?.title ?? String(localized: "Unknown")).tag(state.knownCurrent)
                                .disabled(true)
                        }
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                                .disabled(state.setPayload(option) == nil)
                        }
                    } label: {
                        HStack {
                            Text("Automatic power off")
                            if headphones.pendingChanges[.automaticPowerOff] != nil {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Updating automatic power off")
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .disabled(!headphones.canSetAutomaticPowerOff)
                    .accessibilityIdentifier("system.automaticPowerOff")
                }
                if let error = headphones.settingErrors[.automaticPowerOff] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct BatteryCareControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.powerFeatures.batteryCare {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled }, set: { headphones.setBatteryCare($0) }
                        )) {
                            HStack {
                                Text("Battery Care")
                                if headphones.pendingChanges[.batteryCare] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating Battery Care")
                                }
                            }
                        }
                        .disabled(!headphones.canSetBatteryCare)
                        .accessibilityIdentifier("power.batteryCare")
                    } else {
                        LabeledContent("Battery Care", value: String(localized: "Unknown"))
                    }
                }
                if let threshold = state.threshold {
                    LabeledContent("Charging limit", value: "\(threshold)%").font(.caption)
                }
                if let error = headphones.settingErrors[.batteryCare] {
                    Text(error).font(.caption)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AutoPowerSaveControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.powerFeatures.autoPowerSave {
            let pending = headphones.pendingChanges[.autoPowerSave] != nil || headphones.pendingChanges[.powerSaveEffect] != nil
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled }, set: { headphones.setAutoPowerSave($0) }
                        )) {
                            HStack {
                                Text("Auto Power Save")
                                if pending {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating power saving")
                                }
                            }
                        }
                        .disabled(!headphones.canSetAutoPowerSave)
                        .accessibilityIdentifier("power.autoPowerSave")
                    } else {
                        LabeledContent("Auto Power Save", value: String(localized: "Unknown"))
                    }
                }
                if let threshold = state.threshold {
                    Text("Activates at \(threshold)% battery.").font(.caption)
                }
                if state.effectActive == true {
                    Text("Power saving is active.").font(.caption)
                    Button("Turn Off Power Saving for Now") { headphones.cancelPowerSaveEffect() }
                        .disabled(!headphones.canCancelPowerSaveEffect)
                        .accessibilityIdentifier("power.cancelEffect")
                        .help("Auto Power Save remains on.")
                }
                if let error = headphones.settingErrors[.autoPowerSave] ?? headphones.settingErrors[.powerSaveEffect] {
                    Text(error).font(.caption)
                }
            }
        }
    }
}

private struct SidetoneControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatures.sidetone {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setSidetone($0) }
                        )) {
                            HStack {
                                Text("Hear your voice during calls")
                                if headphones.pendingChanges[.sidetone] != nil {
                                    ProgressView().controlSize(.mini)
                                        .accessibilityLabel("Updating own voice during calls")
                                }
                            }
                        }
                        .disabled(!headphones.canSetSidetone)
                        .accessibilityIdentifier("system.sidetone")
                    } else {
                        LabeledContent("Hear your voice during calls") {
                            Text("Unknown").foregroundStyle(.primary)
                        }
                    }
                }
                if let error = headphones.settingErrors[.sidetone] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MultipointControls: View {
    var compact = false
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.multipoint
        VStack(alignment: .leading, spacing: 10) {
            if !state.devices.isEmpty {
                deviceGroup("Connected", devices: state.devices.filter(\.isConnected))
                if state.devices.contains(where: \.isConnected), state.devices.contains(where: { !$0.isConnected }) {
                    Divider()
                }
                deviceGroup("Saved", devices: state.devices.filter { !$0.isConnected })
            }
            if state.supportsSourceControl, let keeping = state.keeping {
                if !state.devices.isEmpty { Divider() }
                Toggle(isOn: Binding(get: { keeping }, set: headphones.setSourceKeeping)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep current audio source")
                        Text("Don’t switch when another device starts playing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .disabled(headphones.sourceControlUnavailableReason != nil || (!keeping && state.selectedSource == nil))
                .accessibilityIdentifier("multipoint.keeping")
                .help("Prevents automatic switching to another connected device. Choosing another device turns this off.")
            }
            if let message = headphones.sourceTransition?.failureMessage {
                Text(message).font(.caption)
                    .accessibilityIdentifier("multipoint.error")
            }
            if let message = headphones.deviceActionTransition?.failureMessage {
                Text(message).font(.caption)
                    .accessibilityIdentifier("multipoint.deviceError")
            }
            if state.inventoryIsStale {
                Label("The device list could not be read. Refresh to try again.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            if !compact {
                Divider()
                Button("Refresh Devices") { headphones.refreshDevices() }
                    .headphoneButtonStyle()
                    .tint(nil)
                    .controlSize(.small)
                    .disabled(!headphones.canRefreshDevices)
                    .accessibilityIdentifier("multipoint.refresh")
            }
        }
    }

    static func isVisible(for state: SonyMultipoint) -> Bool {
        !state.devices.isEmpty || (state.supportsSourceControl && state.keeping != nil)
    }

    @ViewBuilder
    private func deviceGroup(_ title: LocalizedStringKey, devices: [SonyMultipointDevice]) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                ForEach(devices) { device in
                    MultipointDeviceRow(device: device)
                }
            }
        }
    }

    static func title(for device: SonyMultipointDevice, among devices: [SonyMultipointDevice]) -> String {
        devices.filter { $0.name.localizedCaseInsensitiveCompare(device.name) == .orderedSame }.count > 1
            ? "\(device.name) · \(device.address)" : device.name
    }
}

private struct MultipointDeviceRow: View {
    let device: SonyMultipointDevice
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var hovered = false
    @FocusState private var sourceFocused: Bool
    @FocusState private var actionFocused: Bool

    private var title: String { MultipointControls.title(for: device, among: headphones.multipoint.devices) }
    private var selected: Bool {
        !headphones.multipoint.inventoryIsStale && headphones.multipoint.selectedSource?.id == device.id
    }
    private var status: String {
        selected ? String(localized: "Selected for audio") : device.isConnected ? String(localized: "Connected") : String(localized: "Saved")
    }
    private var pendingAction: SonyPeripheralAction? {
        guard let transition = headphones.deviceActionTransition, !transition.isFinished,
              transition.targetAddress == device.id else { return nil }
        return transition.action
    }
    private var showsAction: Bool { hovered || sourceFocused || actionFocused || voiceOverEnabled || pendingAction != nil }
    private var progressLabel: String? {
        if let pendingAction {
            return pendingAction == .connect ? String(localized: "Connecting device…") : String(localized: "Disconnecting device…")
        }
        if let transition = headphones.sourceTransition, !transition.isFinished,
           (transition.targetAddress ?? headphones.multipoint.selectedSource?.id) == device.id {
            return String(localized: "Changing audio source…")
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if device.isConnected, headphones.multipoint.supportsSourceControl {
                Button { headphones.selectAudioSource(device) } label: { deviceLabel }
                    .buttonStyle(.plain)
                    .focused($sourceFocused)
                    .focusEffectDisabled()
                    .disabled(headphones.sourceControlUnavailableReason != nil)
                    .help(headphones.sourceControlUnavailableReason ?? title)
                    .accessibilityLabel("Use \(title) for Audio")
                    .accessibilityValue(progressLabel ?? status)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("multipoint.select.\(device.id)")
            } else {
                deviceLabel
                    .focusable(headphones.multipoint.supportsInventory)
                    .focused($sourceFocused)
                    .focusEffectDisabled()
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(progressLabel ?? status)
            }
            if headphones.multipoint.supportsInventory {
                let action: SonyPeripheralAction = pendingAction ?? (device.isConnected ? .disconnect : .connect)
                let reason = headphones.deviceActionUnavailableReason(action, device: device)
                Button {
                    headphones.changeDeviceConnection(action, device: device)
                } label: {
                    Text(action == .disconnect ? String(localized: "Disconnect") : String(localized: "Connect"))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 6))
                .tint(nil)
                .controlSize(.small)
                .focused($actionFocused)
                .disabled(reason != nil)
                .help(reason ?? (device.isConnected ? String(localized: "Disconnect this device from the headphones") : String(localized: "Connect this device to the headphones")))
                .accessibilityLabel("\(action == .disconnect ? String(localized: "Disconnect") : String(localized: "Connect")) \(title)")
                .accessibilityIdentifier("multipoint.\(action == .disconnect ? "disconnect" : "connect").\(device.id)")
                .accessibilityHidden(pendingAction != nil)
                .opacity(showsAction && pendingAction == nil ? 1 : 0)
                .fixedSize()
                .overlay {
                    if let pendingAction {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(pendingAction == .connect ? String(localized: "Connecting device…") : String(localized: "Disconnecting device…"))
                            .accessibilityIdentifier("multipoint.progress.\(device.id)")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(showsAction ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, -8)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multipoint.row.\(device.id)")
    }

    private var deviceLabel: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.1))
                if pendingAction == nil, progressLabel != nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: device.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 28, height: 28)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(device.isConnected ? .primary : .secondary)
            if selected {
                Image(systemName: "checkmark").accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(title)
    }
}

struct MultipointSourcePicker: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.multipoint
        let connected = state.devices.filter(\.isConnected)
        let selectedID = state.inventoryIsStale ? nil : state.selectedSource?.id
        if state.supportsSourceControl, connected.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(connected) { device in
                        let selected = selectedID == device.id
                        Button { headphones.selectAudioSource(device) } label: {
                            Text(Self.title(for: device, among: connected))
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : Color.primary)
                        }
                        .headphoneButtonStyle(prominent: selected)
                        .tint(selected ? .primary : nil)
                        .help(headphones.sourceControlUnavailableReason ?? MultipointControls.title(for: device, among: state.devices))
                        .accessibilityLabel(MultipointControls.title(for: device, among: state.devices))
                        .accessibilityValue(selected ? String(localized: "Selected for audio") : String(localized: "Not selected"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("multipoint.sourcePicker.\(device.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Multipoint")
                .accessibilityIdentifier("multipoint.sourcePicker")
                if selectedID == nil {
                    Text("Not reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.regular)
            .tint(nil)
            .disabled(headphones.sourceControlUnavailableReason != nil)
            .help(headphones.sourceControlUnavailableReason ?? String(localized: "Multipoint"))
        }
    }

    static func title(for device: SonyMultipointDevice, among devices: [SonyMultipointDevice]) -> String {
        let matching = devices.filter { $0.name.localizedCaseInsensitiveCompare(device.name) == .orderedSame }
        guard matching.count > 1 else { return device.name }
        let suffix = String(device.address.suffix(5))
        let identifier = matching.filter { $0.address.hasSuffix(suffix) }.count > 1 ? device.address : suffix
        return "\(device.name) · \(identifier)"
    }
}

struct MultipointSettingControl: View {
    var compact = false
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var showsAlert = false
    @State private var presentedSoundQualityWarning = false

    var body: some View {
        let enabled = Self.enabled(for: headphones)
        if compact || enabled != nil {
            VStack(alignment: .leading, spacing: 6) {
                if compact {
                    HStack(spacing: 12) {
                        Text("Multipoint").font(.headline).fontWeight(.semibold)
                        Spacer()
                        Button { headphones.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .tint(nil)
                            .foregroundStyle(.secondary)
                            .disabled(!headphones.canRefreshDevices)
                            .accessibilityLabel("Refresh Devices")
                            .accessibilityIdentifier("multipoint.refresh")
                            .help("Refresh Devices")
                            .frame(width: 16, height: 16)
                        if let enabled {
                            Toggle("Multipoint", isOn: Binding(get: { enabled }, set: headphones.setMultipointEnabled))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(headphones.multipointUnavailableReason != nil)
                                .help(headphones.multipointUnavailableReason ?? "")
                                .accessibilityIdentifier("multipoint.enabled")
                        }
                    }
                } else if let enabled {
                    Toggle("Multipoint", isOn: Binding(get: { enabled }, set: headphones.setMultipointEnabled))
                        .disabled(headphones.multipointUnavailableReason != nil)
                        .help(headphones.multipointUnavailableReason ?? "")
                        .accessibilityIdentifier("multipoint.enabled")
                }
                if let transition = headphones.multipointTransition {
                    if let failure = transition.failureMessage {
                        HStack(spacing: 10) {
                            ConnectionStatusIndicator()
                            Text(failure).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("multipoint.settingError")
                            Spacer(minLength: 0)
                            if transition.canRetryRecovery {
                                Button("Retry") { headphones.checkMultipointChange() }
                                    .controlSize(.small)
                                    .disabled(!headphones.canCheckMultipointChange)
                                    .accessibilityIdentifier("multipoint.checkSetting")
                            }
                        }
                    } else if !transition.isFinished && !transition.awaitingUser {
                        HStack(spacing: 10) {
                            ConnectionStatusIndicator(isLoading: true)
                            Text(transition.phase == .recovering ? String(localized: "Reconnecting controls…") : String(localized: "Checking device connections…"))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("multipoint.settingProgress")
                    }
                }
            }
            .onChange(of: headphones.multipointTransition?.alert, initial: true) { _, alert in
                guard !compact else { return }
                presentedAlert = alert
                presentedSoundQualityWarning = alert?.format == .fixed && alert?.messageID == 0x07
                    && alert?.actionType == .positiveNegative && headphones.multipointTransition?.targetEnabled == true
                    && headphones.connectionMode == .soundQuality
                showsAlert = alert != nil
            }
            .alert(alertTitle, isPresented: $showsAlert, presenting: presentedAlert) { alert in
                if alert.availableActions.contains(.negative) {
                    Button("Cancel", role: .cancel) { headphones.respondToMultipointAlert(alert, action: .negative) }
                }
                if alert.availableActions.contains(.positive) {
                    Button("Continue") {
                        headphones.respondToMultipointAlert(alert, action: .positive, confirmsSoundQualityWarning: presentedSoundQualityWarning)
                    }
                } else if alert.actionType == .confirmationOnly {
                    Button("OK") { headphones.respondToMultipointAlert(alert, action: nil) }
                }
            } message: { alert in
                Text(alertMessage(alert))
            }
        }
    }

    static func enabled(for headphones: SonyHeadphonesController) -> Bool? {
        headphones.systemFeatures.multipoint?.enabled
            ?? headphones.multipointTransition.flatMap { $0.isFinished ? nil : $0.originalEnabled }
    }

    private var alertTitle: String {
        if presentedAlert?.format == .fixed, presentedAlert?.messageID == 0x70 { return String(localized: "Audio may cut out") }
        guard presentedAlert?.actionType == .positiveNegative else { return String(localized: "Device Connection Change") }
        return headphones.multipointTransition?.targetEnabled == true ? String(localized: "Enable multipoint?") : String(localized: "Use one device at a time?")
    }

    private func alertMessage(_ alert: SonyConnectionAlert) -> String {
        if alert.format == .fixed, alert.messageID == 0x70 {
            return String(localized: "Audio may cut out when Sound Quality and multipoint are both enabled.")
        }
        var message = String(localized: "Changing this setting may briefly disconnect the headphones. Reconnect them if needed.")
        if presentedSoundQualityWarning {
            message += "\n\n" + String(localized: "Audio may cut out when Sound Quality and multipoint are both enabled.")
        }
        if alert.format == .fixed || alert.format == .legacyFixed, alert.messageID == 0x06 {
            message += String(localized: "\n\nThe headphones report that LDAC will be unavailable with this change.")
        }
        if alert.format == .flexible {
            let known = alert.affectedFeatures.filter { $0.title != String(localized: "Unknown feature") }.map(\.title)
            if !known.isEmpty { message += String(localized: "\n\nUnavailable with this change: ") + known.joined(separator: ", ") + "." }
            if known.count != alert.affectedFeatures.count {
                message += String(localized: "\n\nThe headphones also report an affected feature this app cannot identify.")
            }
        }
        return message
    }
}
