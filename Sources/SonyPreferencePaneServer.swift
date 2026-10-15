import Darwin
import Foundation
import OSLog

@MainActor
final class SonyPreferencePaneServer {
    private let devices: SonyDeviceCoordinator
    private let allowsCommands: Bool
    private let serverID = UUID()
    private var listener: DispatchSourceRead?
    private var clients: [UUID: (fd: Int32, task: Task<Void, Never>)] = [:]
    private var recentCommands: [UUID] = []
    private let path: String
    private nonisolated static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "PreferencePane")

    /// `path` defaults to the socket of this distribution: the container in the sandbox, Application Support
    /// outside it.
    init(devices: SonyDeviceCoordinator, allowsCommands: Bool = false,
         path: String = SonyPreferencePaneWire.socketPath(
            sandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)) {
        self.devices = devices
        self.allowsCommands = allowsCommands
        self.path = path
    }

    /// Starts listening. Throws, before creating anything, when the path does not fit in `sun_path`.
    func start() throws {
        guard listener == nil else { return }
        var address = try SonyPreferencePaneWire.address(path)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw SonyPreferencePaneWire.failure("The local settings connection path is already in use.")
            }
            do {
                let active = try SonyPreferencePaneWire.connect(path: path)
                close(active)
                throw SonyPreferencePaneWire.failure("Another local settings connection is already running.")
            } catch {
                let error = error as NSError
                guard error.domain == NSPOSIXErrorDomain, error.code == ECONNREFUSED else { throw error }
            }
            guard unlink(path) == 0 else { throw SonyPreferencePaneWire.failure("The old local settings connection could not be removed.") }
        } else if errno != ENOENT {
            throw SonyPreferencePaneWire.failure("The local settings connection path could not be checked.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SonyPreferencePaneWire.failure("The local settings connection could not be created.") }
        do {
            try SonyPreferencePaneWire.configure(fd)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw SonyPreferencePaneWire.failure("The local settings connection could not be bound.") }
            guard chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
                unlink(path)
                throw SonyPreferencePaneWire.failure("The local settings connection could not be opened.")
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.acceptConnections(fd) }
            }
            source.setCancelHandler { close(fd) }
            listener = source
            source.resume()
        } catch {
            close(fd)
            throw error
        }
    }

    func stop() {
        guard let listener else { return }
        self.listener = nil
        listener.cancel()
        unlink(path)
        for client in clients.values {
            shutdown(client.fd, SHUT_RDWR)
            client.task.cancel()
        }
    }

    private func acceptConnections(_ fd: Int32) {
        for _ in 0..<4 {
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            guard clients.count < 4 else { close(peer); continue }
            do { try SonyPreferencePaneWire.configure(peer) }
            catch { close(peer); continue }
            let id = UUID()
            let task = Task.detached { [weak self] in
                defer { close(peer) }
                do {
                    try SonyPreferencePaneWire.authenticate(peer, requirement: SonyPreferencePaneWire.hostRequirement)
                    let request = try SonyPreferencePaneWire.receive(SonyPreferencePaneRequest.self, from: peer, timeout: 3)
                    guard let self else { return }
                    let reply = await self.reply(to: request)
                    try SonyPreferencePaneWire.send(reply, to: peer)
                } catch {
                    Self.logger.debug("Preference pane connection ended: \(error.localizedDescription, privacy: .private)")
                }
                await self?.finished(id)
            }
            clients[id] = (peer, task)
        }
    }

    private func finished(_ id: UUID) { clients[id] = nil }

    func reply(to request: SonyPreferencePaneRequest) async -> SonyPreferencePaneReply {
        var issue: String?
        do {
            try Task.checkCancellation()
            guard listener != nil, request.version == SonyPreferencePaneWire.version else {
                throw SonyPreferencePaneWire.failure("The local settings connection needs to be reopened.")
            }
            if request.action != .snapshot {
                guard #available(macOS 27.0, *) else {
                    throw SonyPreferencePaneWire.failure("These controls require macOS 27 or later.")
                }
                guard allowsCommands else { throw SonyPreferencePaneWire.failure("This connection currently shows headphone settings only.") }
                guard request.serverID == serverID, let address = request.address,
                      devices.retainedDevices.contains(where: { $0.address == address }),
                      !devices.retiredControllerAddresses.contains(address),
                      let controller = devices.controller(for: address), controller.address == address,
                      controller.preferencePaneSession == request.session, controller.isReady else {
                    throw SonyPreferencePaneWire.failure("The headphone connection changed. Try again after it reconnects.")
                }
                guard !recentCommands.contains(request.id) else { throw SonyPreferencePaneWire.failure("This command has already been submitted.") }
                recentCommands.append(request.id)
                if recentCommands.count > 128 { recentCommands.removeFirst() }
                switch request.action {
                case .noise:
                    guard let mode = request.mode, NoiseControlMode(rawValue: mode) != nil else {
                        throw SonyPreferencePaneWire.failure("This listening mode is not supported.")
                    }
                    try await controller.performNoiseControlAction("\(address):\(controller.deviceModel.rawValue):\(mode)")
                case .speak:
                    guard let enabled = request.enabled else { throw SonyPreferencePaneWire.failure("Choose a Speak-to-Chat setting.") }
                    try await controller.performSpeakToChatAction("\(address):\(controller.deviceModel.rawValue):speak-to-chat-\(enabled ? "on" : "off")")
                case .snapshot:
                    break
                default:
                    try await apply(request, to: controller)
                }
            }
            Self.logger.debug("Preference pane authenticated request: \(request.action.rawValue, privacy: .public)")
        } catch { issue = error.localizedDescription }
        return SonyPreferencePaneReply(version: SonyPreferencePaneWire.version, id: request.id, snapshot: snapshot(), error: issue)
    }

    private func apply(_ request: SonyPreferencePaneRequest, to controller: SonyHeadphonesController) async throws {
        let unavailable = SonyPreferencePaneWire.failure("This setting is no longer available. Refresh the headphone settings.")
        let option = request.option.flatMap { UInt8($0) }
        switch request.action {
        case .equalizerPreset:
            guard let option, controller.equalizer.presetPayload(option) != nil else { throw unavailable }
            try await change(controller, setting: .equalizer, available: controller.equalizer.canSelectPreset,
                             unchanged: controller.equalizer.presetID == option) { controller.setEqualizerPreset(option) }
        case .equalizer:
            guard let flat = controller.equalizer.flatSettings, let values = request.values,
                  request.bandIDs == flat.layout.map(Self.bandID), request.levelSteps == Int(flat.levelSteps) else { throw unavailable }
            let settings = EqualizerSettings(layout: flat.layout, levelSteps: flat.levelSteps, values: values)
            guard controller.equalizer.settingsPayload(settings) != nil,
                  controller.canPerformConfirmedSettingChange(.equalizer) else { throw unavailable }
            if controller.equalizer.presetID != EqualizerPreset.manual.rawValue || controller.equalizer.settings != settings {
                try await controller.performConfirmedEqualizerChange(settings)
            }
        case .dsee:
            guard let option, SonyDSEEMode(rawValue: option).sonyValue != nil else { throw unavailable }
            let mode = SonyDSEEMode(rawValue: option)
            try await change(controller, setting: .dsee, available: controller.canSetDSEE,
                             unchanged: controller.dseeMode == mode) { controller.setDSEE(mode) }
        case .systemFeature:
            guard let raw = request.feature, let feature = SonySystemFeature(rawValue: raw), let enabled = request.enabled else { throw unavailable }
            try await change(controller, setting: .system(feature), available: controller.canSetSystemFeature(feature),
                             unchanged: controller.systemFeatureState(feature)?.enabled == enabled) {
                controller.setSystemFeature(feature, enabled: enabled)
            }
        case .touchAssignment:
            guard let key = request.key, let option, controller.touchAssignments.setPayload(key: key, preset: option) != nil else { throw unavailable }
            try await change(controller, setting: .touchAssignments, available: controller.canSetTouchAssignment(key: key),
                             unchanged: controller.touchAssignments.selectedPreset(key: key) == option) {
                controller.setTouchAssignment(key: key, preset: option)
            }
        case .touchAction:
            guard let key = request.key, let gesture = request.gesture, let option,
                  controller.touchAssignments.setActionPayload(key: key, action: gesture, function: option) != nil else { throw unavailable }
            let current = controller.touchAssignments.reportedActions(key: key)?.first { $0.action == gesture }?.function
            try await change(controller, setting: .touchCustomActions, available: controller.canSetTouchAction(key: key, action: gesture),
                             unchanged: current == option) { controller.setTouchAction(key: key, action: gesture, function: option) }
        case .automaticPowerOff:
            guard let option else { throw unavailable }
            let value = SonyAutomaticPowerOffOption(rawValue: option)
            guard controller.automaticPowerOff?.setPayload(value) != nil else { throw unavailable }
            try await change(controller, setting: .automaticPowerOff, available: controller.canSetAutomaticPowerOff,
                             unchanged: controller.automaticPowerOff?.knownCurrent == value) { controller.setAutomaticPowerOff(value) }
        case .batteryCare:
            guard let enabled = request.enabled else { throw unavailable }
            try await change(controller, setting: .batteryCare, available: controller.canSetBatteryCare,
                             unchanged: controller.powerFeatures.batteryCare?.enabled == enabled) { controller.setBatteryCare(enabled) }
        case .autoPowerSave:
            guard let enabled = request.enabled else { throw unavailable }
            try await change(controller, setting: .autoPowerSave, available: controller.canSetAutoPowerSave,
                             unchanged: controller.powerFeatures.autoPowerSave?.enabled == enabled) { controller.setAutoPowerSave(enabled) }
        case .volume:
            guard let volume = request.volume, request.sourceAddress == controller.multipoint.selectedSource?.address,
                  controller.playback.volumePayload(volume) != nil else { throw unavailable }
            try await change(controller, setting: .playbackVolume, available: controller.canControlMusicVolume,
                             unchanged: controller.playback.volume == volume) { controller.setPlaybackVolume(volume) }
        case .snapshot, .noise, .speak:
            throw unavailable
        }
    }

    private func change(_ controller: SonyHeadphonesController, setting: SonyHeadphonesController.Setting,
                        available: Bool, unchanged: Bool, apply: () -> Void) async throws {
        guard available, controller.canPerformConfirmedSettingChange(setting) else {
            throw SonyPreferencePaneWire.failure("This setting is not currently available.")
        }
        if !unchanged { try await controller.performConfirmedSettingChange(setting, change: apply) }
    }

    private static func bandID(_ band: SonyEqualizerBand) -> String { "\(band.informationType):\(band.value)" }

    private func populateSettings(_ result: inout SonyPreferencePaneDevice, from controller: SonyHeadphonesController) {
        typealias Device = SonyPreferencePaneDevice
        func writable(_ setting: SonyHeadphonesController.Setting, _ available: Bool) -> Bool {
            allowsCommands && available && controller.canPerformConfirmedSettingChange(setting)
        }
        func choice(_ setting: SonyHeadphonesController.Setting, current: String?, title: String?,
                    options: [Device.Option], available: Bool) -> Device.Choice {
            .init(current: current, currentTitle: title, options: options, canSet: writable(setting, available),
                  pending: controller.pendingChanges[setting] != nil, error: controller.settingErrors[setting])
        }
        func toggle(_ setting: SonyHeadphonesController.Setting, id: String, title: String,
                    enabled: Bool?, available: Bool) -> Device.Toggle {
            .init(id: id, title: title, enabled: enabled, canSet: writable(setting, available),
                  pending: controller.pendingChanges[setting] != nil, error: controller.settingErrors[setting])
        }
        result.firmwareVersion = controller.firmwareVersion
        result.codec = controller.audioFeatures.supportsCodecStatus ? controller.audioFeatures.codec?.title ?? "Unknown" : nil
        let equalizer = controller.equalizer
        if equalizer.isSupported {
            let flat = equalizer.flatSettings
            let preset = choice(.equalizer, current: equalizer.presetID.map(String.init), title: equalizer.presetTitle,
                options: equalizer.capabilities?.presets.map {
                    .init(id: String($0.id), title: $0.title, isEnabled: equalizer.presetPayload($0.id) != nil)
                } ?? [], available: equalizer.canSelectPreset)
            result.equalizer = .init(preset: preset, bands: flat?.layout.map { .init(id: Self.bandID($0), title: $0.title) } ?? [],
                values: equalizer.settings?.values, minimum: flat?.levelRange?.lowerBound ?? 0,
                maximum: flat?.levelRange?.upperBound ?? 0, levelSteps: Int(flat?.levelSteps ?? 0),
                canEdit: writable(.equalizer, equalizer.canEdit), requiresManualSelection: equalizer.requiresManualSelection,
                manualPresetID: equalizer.capabilities?.presets.contains { $0.id == EqualizerPreset.manual.rawValue } == true
                    ? String(EqualizerPreset.manual.rawValue) : nil)
        }
        if controller.supportsDSEE {
            result.dseeTitle = controller.dseeType?.title ?? "DSEE"
            result.dsee = choice(.dsee, current: controller.dseeMode?.sonyValue.map(String.init), title: controller.dseeMode?.title,
                options: SonyDSEEMode.allCases.compactMap { mode in
                    mode.sonyValue.map { .init(id: String($0), title: mode.title) }
                }, available: controller.canSetDSEE)
        }
        result.systemFeatures = SonySystemFeature.allCases.filter { $0 != .speakToChat }.compactMap { feature in
            guard let state = controller.systemFeatureState(feature), state.isVisible != false else { return nil }
            return toggle(.system(feature), id: String(feature.rawValue), title: feature.title,
                          enabled: state.enabled, available: controller.canSetSystemFeature(feature))
        }
        let touch = controller.touchAssignments
        result.touchAssignments = (touch.keys ?? []).map { key in
            let selected = touch.selectedPreset(key: key.key)
            let assignment = choice(.touchAssignments, current: selected.map(String.init),
                title: key.presets.first { $0.preset == selected }?.title(generation: touch.generation),
                options: key.presets.map { .init(id: String($0.preset), title: $0.title(generation: touch.generation),
                    isEnabled: touch.setPayload(key: key.key, preset: $0.preset) != nil) },
                available: controller.canSetTouchAssignment(key: key.key))
            let gestures: [Device.TouchKey.Gesture] = (touch.reportedActions(key: key.key) ?? []).map { action in
                let capability = touch.customizableActions(key: key.key).first { $0.action == action.action }
                let functions = capability?.functions.filter { (0x01...0x04).contains($0) } ?? []
                let customization: Device.Choice? = touch.inquiryType == 0x03 && !functions.isEmpty
                    ? choice(.touchCustomActions, current: String(action.function), title: action.functionTitle(generation: touch.generation),
                        options: functions.map { function in
                            .init(id: String(function), title: SonyTouchActionSetting(action: action.action, function: function).functionTitle,
                                isEnabled: touch.setActionPayload(key: key.key, action: action.action, function: function) != nil)
                        }, available: controller.canSetTouchAction(key: key.key, action: action.action)) : nil
                let shared = selected.map { touch.keysUsingPreset($0) } ?? []
                return .init(id: action.action, title: action.gestureTitle(keyType: key.keyType, generation: touch.generation),
                    functionTitle: action.functionTitle(generation: touch.generation), customization: customization,
                    sharedKeyTitles: shared.count > 1 ? shared.map { $0.title(generation: touch.generation) } : [])
            }
            return .init(id: key.key, title: key.title(generation: touch.generation), assignment: assignment, gestures: gestures)
        }
        if let state = controller.automaticPowerOff {
            result.automaticPowerOff = choice(.automaticPowerOff, current: state.knownCurrent.map { String($0.rawValue) },
                title: state.knownCurrent?.title, options: state.knownOptions.map {
                    .init(id: String($0.rawValue), title: $0.title, isEnabled: state.setPayload($0) != nil)
                }, available: controller.canSetAutomaticPowerOff)
        }
        if let state = controller.powerFeatures.batteryCare {
            result.batteryCare = toggle(.batteryCare, id: "batteryCare", title: "Battery Care", enabled: state.enabled,
                                       available: controller.canSetBatteryCare)
        }
        if let state = controller.powerFeatures.autoPowerSave {
            result.autoPowerSave = toggle(.autoPowerSave, id: "autoPowerSave", title: "Automatic Power Saving", enabled: state.enabled,
                                         available: controller.canSetAutoPowerSave)
        }
        if controller.supportsConnectionMode {
            result.connectionQuality = .init(current: controller.connectionMode?.sonyValue.map(String.init),
                currentTitle: controller.connectionMode?.title, options: (controller.supportedConnectionModes ?? []).compactMap { mode in
                    mode.sonyValue.map { .init(id: String($0), title: mode.title, isEnabled: false) }
                }, canSet: false, pending: controller.connectionTransition?.isFinished == false,
                error: controller.connectionModeError)
        }
        if let state = controller.systemFeatures.multipoint {
            result.multipoint = .init(id: "multipoint", title: "Connect to Two Devices", enabled: state.enabled,
                canSet: false, pending: controller.multipointTransition?.isFinished == false, error: controller.multipointTransition?.failureMessage)
        }
        if !controller.multipoint.inventoryIsStale {
            result.sources = controller.multipoint.devices.map { source in
                .init(id: source.address, title: source.name, isConnected: source.isConnected,
                      isSelected: source.address == controller.multipoint.selectedSource?.address)
            }
        }
        if controller.soundPressure.isSupported {
            result.listeningLevel = switch controller.soundPressure.reading {
            case .decibels(let value): "\(value) dB"
            case .notPlaying: "Not playing"
            case .inCall: "In a call"
            case .notWorn: "Not worn"
            case .unknown, nil: "Not reported"
            }
        }
        if let range = controller.playback.musicVolumeRange, let value = controller.playback.volume {
            result.volume = .init(value: value, minimum: range.lowerBound, maximum: range.upperBound,
                sourceAddress: controller.multipoint.selectedSource?.address, sourceTitle: controller.multipoint.selectedSource?.name,
                canSet: writable(.playbackVolume, controller.canControlMusicVolume),
                pending: controller.pendingChanges[.playbackVolume] != nil, error: controller.settingErrors[.playbackVolume])
        }
    }

    private func snapshot() -> SonyPreferencePaneSnapshot {
        let values = devices.retainedDevices.filter { !devices.retiredControllerAddresses.contains($0.address) }.compactMap { device -> SonyPreferencePaneDevice? in
            guard let controller = devices.controller(for: device.address) else { return nil }
            let readings: [(String, String, BatteryReading?)] = [
                ("single", "Headphones", controller.batteries.single),
                ("left", "Left", controller.batteries.left),
                ("right", "Right", controller.batteries.right),
                ("case", "Case", controller.batteries.caseBattery),
            ]
            let batteries = controller.isReady ? readings.compactMap { id, title, reading -> SonyPreferencePaneDevice.Battery? in
                reading.map { .init(id: id, title: title, level: $0.level, isCharging: $0.isCharging) }
            } : []
            let noiseKnown = controller.noiseControl != nil || controller.legacyControls?.noiseCapability != nil
            let noise = noiseKnown ? SonyPreferencePaneDevice.Noise(
                current: controller.noiseControlMode?.rawValue,
                options: controller.availableNoiseModes.map { .init(id: $0.rawValue, title: $0.title) },
                canSet: allowsCommands && controller.canChangeNoiseControl,
                pending: controller.pendingChanges[.noiseControl] != nil,
                error: controller.settingErrors[.noiseControl]) : nil
            let speakState = controller.systemFeatureState(.speakToChat).flatMap { $0.isVisible == false ? nil : $0 }
            let speak = speakState.map { state in SonyPreferencePaneDevice.Speak(
                enabled: state.enabled, canSet: allowsCommands && controller.canSetSystemFeature(.speakToChat),
                pending: controller.pendingChanges[.system(.speakToChat)] != nil,
                error: controller.settingErrors[.system(.speakToChat)]) }
            var result = SonyPreferencePaneDevice(address: device.address, name: controller.deviceName,
                displayTitle: ConnectedHeadphonePicker.title(for: device, among: devices.connectedDevices),
                modelName: device.model.name, systemSymbol: device.model.isEarbuds ? "earbuds.stemless" : "headphones",
                isConnected: controller.isDeviceConnected, isReady: controller.isReady,
                session: controller.preferencePaneSession, batteries: batteries, noise: noise, speak: speak)
            populateSettings(&result, from: controller)
            return result
        }
        return SonyPreferencePaneSnapshot(serverID: serverID, devices: values, selectedAddress: devices.selectedAddress)
    }
}
