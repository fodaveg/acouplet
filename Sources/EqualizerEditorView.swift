import AppKit
import Combine
import SwiftUI

struct EqualizerEditorView: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profileName = ""
    @State private var presetChange: PresetChange?
    @State private var confirmationWidth: CGFloat?
    @State private var syncDraft: EqualizerSettings?

    struct PresetChange: Identifiable {
        let id = UUID()
        let profile: SavedEqualizerProfile
        let replacement: EqualizerSettings?

        @MainActor
        func makeAlert() -> NSAlert {
            let alert = NSAlert()
            alert.messageText = replacement == nil ? String(localized: "Delete Preset?") : String(localized: "Replace Preset?")
            alert.informativeText = replacement == nil
                ? String(localized: "The saved preset “\(profile.name)” will be deleted from this Mac. This cannot be undone.")
                : String(localized: "The saved settings for “\(profile.name)” will be replaced. This cannot be undone.")
            let confirm = alert.addButton(withTitle: replacement == nil ? String(localized: "Delete") : String(localized: "Replace"))
            confirm.hasDestructiveAction = true
            confirm.keyEquivalent = ""
            let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
            cancel.keyEquivalent = "\u{1B}"
            alert.window.defaultButtonCell = nil
            return alert
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Device") {
                    Text(headphones.deviceName).foregroundStyle(.primary)
                }
                equalizerStatus
            }
            Section("Custom Equalizer") {
                let displayedDraft = settings.customEqualizerDraft
                HStack(alignment: .top, spacing: 8) {
                    ForEach(displayedDraft.layout.indices, id: \.self) { index in
                        equalizerColumn(displayedDraft.layout[index].title, value: Binding(
                            get: { Double(displayedDraft[index]) },
                            set: { value in
                                var draft = settings.customEqualizerDraft
                                guard draft.layout == displayedDraft.layout,
                                      draft.levelSteps == displayedDraft.levelSteps else { return }
                                draft[index] = Int(value)
                                apply(draft)
                            }
                        ))
                    }
                }
                .padding(.vertical, 8)
                Button("Reset Flat") {
                    var draft = settings.customEqualizerDraft
                    draft.values = Array(repeating: 0, count: draft.layout.count)
                    apply(draft)
                }
                    .tint(.primary)
                ForEach(savableSlots, id: \.self) { slot in
                    Button(String(localized: "Save to \(slotTitle(slot))")) {
                        headphones.saveEqualizerCurve(settings.customEqualizerDraft, toSlot: slot)
                    }
                    .disabled(!canSave(to: slot))
                    .tint(.primary)
                    .help("Store this curve in the headphone preset so it survives without this Mac.")
                    .accessibilityIdentifier("equalizer.save.\(slot)")
                }
            }
            Section {
                HStack {
                    TextField("Preset name", text: $profileName)
                        .accessibilityLabel("Preset name")
                        .onSubmit(saveProfile)
                    Button("Save", action: saveProfile)
                        .tint(.primary)
                }
                ForEach(settings.equalizerProfiles) { profile in
                    HStack {
                        Button(profile.name) { apply(profile.settings) }
                            .tint(.primary)
                            .disabled(headphones.isReady && headphones.equalizer.settingsPayload(profile.settings) == nil)
                        Spacer()
                        Button(role: .destructive) {
                            confirmationWidth = editorWidth
                            presetChange = PresetChange(profile: profile, replacement: nil)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(profile.name)")
                    }
                }
            } header: {
                Text("Saved Presets")
            } footer: {
                Text("Saved on this Mac.")
            }
        }
        .formStyle(.grouped)
        .disabled(headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
        .transaction { $0.animation = nil }
        .frame(width: editorWidth, height: 620)
        .windowResizeAnchorIfAvailable(.topLeading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: editorWidth)
        .toolbar {
            Button(action: syncEqualizer) { Label("Sync Equalizer", systemImage: "arrow.clockwise") }
                .tint(.primary)
                .help("Read the headphone equalizer into this draft.")
                .disabled(!canRead || headphones.isEqualizerUpdatePending || headphones.pendingChanges[.equalizerReadback] != nil)
        }
        .onChange(of: headphones.equalizerReadbackID) { _, _ in finishSync() }
        .onChange(of: settings.customEqualizerDraft) { _, _ in syncDraft = nil }
        .onChange(of: presetChange?.id) { _, id in
            if id == nil { confirmationWidth = nil }
        }
        .onChange(of: headphones.isReady) { _, ready in
            if !ready { syncDraft = nil }
        }
        .onChange(of: headphones.settingErrors[.equalizerReadback]) { _, error in
            if error != nil { syncDraft = nil }
        }
        .background(EqualizerPresetConfirmation(change: $presetChange) { change in
            if let replacement = change.replacement {
                settings.customEqualizerDraft = replacement
                saveProfile(named: change.profile.name)
            } else {
                settings.deleteEqualizerProfile(id: change.profile.id)
            }
        }.frame(width: 0, height: 0).accessibilityHidden(true))
        .accessibilityIdentifier("equalizer.editor")
    }

    private var editorWidth: CGFloat {
        confirmationWidth ?? (settings.customEqualizerDraft.layout.count > 6 ? 720 : 520)
    }

    private var canRead: Bool {
        headphones.isReady && headphones.powerOffState == nil && !headphones.isRunningHeadphoneTest && headphones.connectionTransition?.isFinished != false && headphones.multipointTransition?.isFinished != false
            && headphones.deviceActionTransition?.isFinished != false && headphones.equalizer.parameterQueryPayload != nil
    }

    private var canApply: Bool {
        canRead && headphones.equalizer.settingsPayload(settings.customEqualizerDraft) != nil
    }

    private var savableSlots: [UInt8] { headphones.isReady ? headphones.equalizer.savableSlots : [] }

    private func slotTitle(_ slot: UInt8) -> String {
        EqualizerPreset(rawValue: slot)?.title ?? String(format: String(localized: "Preset %02X"), slot)
    }

    private func canSave(to slot: UInt8) -> Bool {
        canRead && headphones.equalizer.curvePayload(settings.customEqualizerDraft, target: slot) != nil
            && !headphones.isEqualizerUpdatePending && headphones.pendingChanges[.equalizerReadback] == nil
    }

    private var savedSlot: UInt8? {
        guard let id = headphones.equalizer.presetID, EqualizerPreset(rawValue: id) != .manual,
              SonyEqualizer.userSlots.contains(id),
              headphones.equalizer.settings == settings.customEqualizerDraft else { return nil }
        return id
    }

    private var isApplied: Bool {
        headphones.equalizerPreset == .manual && headphones.equalizer.settings == settings.customEqualizerDraft
    }

    private var equalizerStatus: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if headphones.isRunningHeadphoneTest {
                    Text("Finish the current headphone test before applying changes.")
                } else if headphones.powerOffState != nil {
                    Text("Draft saved on this Mac. Reconnect the headphones before applying changes.")
                } else if !headphones.isReady {
                    Text("Draft saved on this Mac. Headphones unavailable.")
                } else if headphones.isEqualizerUpdatePending {
                    Text("Applying equalizer…")
                } else if headphones.pendingChanges[.equalizerReadback] != nil {
                    Text("Reading equalizer…")
                } else if let error = headphones.settingErrors[.equalizer] ?? headphones.settingErrors[.equalizerReadback] {
                    Text(error)
                } else if headphones.equalizer.available == false {
                    Text("Equalizer is unavailable in the current headphone mode.")
                } else if headphones.equalizer.requiresManualSelection {
                    Text("Choose Manual to apply this draft.")
                } else if !headphones.equalizer.canEdit {
                    Text("Custom equalizer controls are not available for this device.")
                } else if !canApply {
                    Text("This draft uses a different equalizer layout. Sync to use this device’s settings.")
                } else if let savedSlot {
                    Text("Saved to \(slotTitle(savedSlot)).")
                } else if isApplied {
                    Text("Applied to headphones.")
                } else {
                    Text("Draft saved on this Mac.")
                    if let title = headphones.equalizer.presetTitle { Text("Headphones: \(title)") }
                }
            }
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .overlay(alignment: .trailing) {
                if headphones.isEqualizerUpdatePending || headphones.pendingChanges[.equalizerReadback] != nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel(headphones.isEqualizerUpdatePending ? String(localized: "Applying equalizer") : String(localized: "Reading equalizer"))
                }
            }
            if headphones.isReady {
                if headphones.equalizer.requiresManualSelection {
                    Button("Use Manual") { headphones.setEqualizerPreset(.manual) }
                        .disabled(!canRead || headphones.isEqualizerUpdatePending
                                  || headphones.pendingChanges[.equalizerReadback] != nil)
                        .tint(.primary)
                } else {
                    Button(headphones.settingErrors[.equalizer] == nil ? String(localized: "Apply") : String(localized: "Retry")) {
                        apply(settings.customEqualizerDraft)
                    }
                    .accessibilityLabel("Apply equalizer to headphones")
                    .disabled(!canApply || headphones.isEqualizerUpdatePending
                              || headphones.pendingChanges[.equalizerReadback] != nil
                              || (isApplied && headphones.settingErrors[.equalizer] == nil))
                    .tint(.primary)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("equalizer.status")
    }

    private func syncEqualizer() {
        syncDraft = settings.customEqualizerDraft
        headphones.refreshEqualizer(trackConfirmation: true)
    }

    private func finishSync() {
        guard let syncDraft, settings.customEqualizerDraft == syncDraft,
              !headphones.isEqualizerUpdatePending, headphones.pendingChanges[.equalizerReadback] == nil,
              headphones.settingErrors[.equalizerReadback] == nil else { return }
        self.syncDraft = nil
        if headphones.equalizerPreset == .manual, let curve = headphones.equalizer.settings {
            settings.customEqualizerDraft = curve
        }
    }

    private func equalizerColumn(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.primary)
            EqualizerFader(value: value, title: title, range: settings.customEqualizerDraft.levelRange,
                           color: settings.controlAccentColor)
                .frame(width: 28, height: 180)
            Text(Int(value.wrappedValue).formatted(.number.sign(strategy: .always())))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    private func apply(_ equalizer: EqualizerSettings) {
        syncDraft = nil
        settings.customEqualizerDraft = equalizer
        if headphones.equalizer.canEdit {
            headphones.setCustomEqualizer(equalizer)
        }
    }

    private func saveProfile() {
        let name = settings.equalizerProfileName(for: profileName)
        if let profile = settings.equalizerProfiles.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            confirmationWidth = editorWidth
            presetChange = PresetChange(profile: profile, replacement: settings.customEqualizerDraft)
        } else {
            saveProfile(named: name)
        }
    }

    private func saveProfile(named name: String) {
        let profile = settings.saveEqualizerProfile(named: name)
        profileName = ""
        apply(profile.settings)
    }
}

struct EqualizerPresetConfirmation: NSViewRepresentable {
    @Binding var change: EqualizerEditorView.PresetChange?
    let onConfirm: (EqualizerEditorView.PresetChange) -> Void

    func makeNSView(context: Context) -> ConfirmationView {
        ConfirmationView()
    }

    func updateNSView(_ nsView: ConfirmationView, context: Context) {
        nsView.change = $change
        nsView.onConfirm = onConfirm
        if change == nil {
            nsView.cancel()
        } else {
            nsView.schedulePresentation()
        }
    }

    static func dismantleNSView(_ nsView: ConfirmationView, coordinator: ()) {
        nsView.cancel()
        nsView.change = nil
        nsView.onConfirm = nil
    }

    final class ConfirmationView: NSView {
        var change: Binding<EqualizerEditorView.PresetChange?>?
        var onConfirm: ((EqualizerEditorView.PresetChange) -> Void)?
        private var alert: NSAlert?
        private var closeObservation: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeObservation = nil
            guard let window else {
                cancel()
                return
            }
            closeObservation = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
                .filter { [weak window] notification in notification.object as? NSWindow === window }
                .sink { [weak self] _ in self?.cancel() }
            schedulePresentation()
        }

        func schedulePresentation() {
            DispatchQueue.main.async { [weak self] in self?.present() }
        }

        private func present() {
            guard let request = change?.wrappedValue else {
                cancel()
                return
            }
            guard alert == nil, let window, window.isVisible else { return }
            let alert = request.makeAlert()
            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, let alert, self.alert === alert else { return }
                self.alert = nil
                self.finish(response, for: request)
                self.schedulePresentation()
            }
        }

        func finish(_ response: NSApplication.ModalResponse, for request: EqualizerEditorView.PresetChange) {
            guard change?.wrappedValue?.id == request.id else { return }
            change?.wrappedValue = nil
            if response == .alertFirstButtonReturn { onConfirm?(request) }
        }

        func cancel() {
            let presented = alert
            alert = nil
            if let presented, let parent = presented.window.sheetParent {
                parent.endSheet(presented.window, returnCode: .cancel)
            }
            let binding = change
            guard let requestID = binding?.wrappedValue?.id else { return }
            DispatchQueue.main.async {
                if binding?.wrappedValue?.id == requestID { binding?.wrappedValue = nil }
            }
        }
    }
}

private struct EqualizerFader: NSViewRepresentable {
    @Binding var value: Double
    let title: String
    let range: ClosedRange<Int>?
    let color: NSColor
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: Double(range?.lowerBound ?? 0), maxValue: Double(range?.upperBound ?? 0),
                              target: context.coordinator, action: #selector(Coordinator.changeValue(_:)))
        slider.isVertical = true
        if #available(macOS 26.0, *) {
            slider.neutralValue = 0
            slider.tintProminence = .primary
        }
        slider.numberOfTickMarks = range?.count ?? 0
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel(title)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.setAccessibilityLabel(title)
        slider.minValue = Double(range?.lowerBound ?? 0)
        slider.maxValue = Double(range?.upperBound ?? 0)
        slider.numberOfTickMarks = range?.count ?? 0
        slider.doubleValue = value
        slider.trackFillColor = color
        slider.isEnabled = isEnabled && range != nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func changeValue(_ slider: NSSlider) {
            value.wrappedValue = slider.doubleValue
        }
    }
}
