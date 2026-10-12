import Combine
import Darwin
import Foundation

@MainActor
final class SonyPreferencePaneClient: ObservableObject {
    @Published private(set) var snapshot: SonyPreferencePaneSnapshot?
    @Published private(set) var selectedAddress: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var isUpdating = false
    let pinnedAddress: String?
    private let appRequirement: String
    private var observation: Task<Void, Never>?
    private var command: Task<Void, Never>?
    private var generation = UUID()
    private var requestSequence = 0
    private var appliedSequence = 0
    private var commandError: String?
    private var commandFailure: (request: SonyPreferencePaneRequest, reported: Bool)?
    private let path = FileManager.default.homeDirectoryForCurrentUser.path
        + "/Library/Containers/dev.baglayan.Acouplet/Data/tmp/" + SonyPreferencePaneWire.socketName

    init(pinnedAddress: String? = nil, appTeam: String? = nil) {
        self.pinnedAddress = pinnedAddress
        appRequirement = SonyPreferencePaneWire.appRequirement(team: appTeam)
        selectedAddress = pinnedAddress
    }

    var selectedDevice: SonyPreferencePaneDevice? {
        snapshot?.devices.first { $0.address == selectedAddress }
    }

    func start() {
        guard observation == nil else { return }
        let generation = generation
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                if !self.isUpdating { await self.refresh(generation: generation) }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    func stop() {
        generation = UUID()
        observation?.cancel()
        observation = nil
        command?.cancel()
        command = nil
        isUpdating = false
        snapshot = nil
        connectionError = nil
        commandError = nil
        commandFailure = nil
    }

    func select(address: String) {
        guard pinnedAddress == nil, !isUpdating, address != selectedAddress,
              snapshot?.devices.contains(where: { $0.address == address }) == true else { return }
        selectedAddress = address
        commandError = nil
        if connectionError != nil { connectionError = nil }
    }

    func setNoise(mode: String) {
        guard let device = selectedDevice, device.noise?.canSet == true,
              device.noise?.options.contains(where: { $0.id == mode }) == true else { return }
        submit(action: .noise, device: device, mode: mode)
    }

    func setSpeak(enabled: Bool) {
        guard let device = selectedDevice, device.speak?.canSet == true else { return }
        submit(action: .speak, device: device, enabled: enabled)
    }

    func setEqualizerPreset(option: String) {
        setChoice(.equalizerPreset, value: selectedDevice?.equalizer?.preset, option: option)
    }

    func setEqualizer(values: [Int]) {
        guard let device = selectedDevice, let equalizer = device.equalizer, equalizer.canEdit,
              values.count == equalizer.bands.count,
              values.allSatisfy({ (equalizer.minimum...equalizer.maximum).contains($0) }) else { return }
        submit(action: .equalizer, device: device, bandIDs: equalizer.bands.map(\.id), values: values,
               levelSteps: equalizer.levelSteps)
    }

    func setDSEE(option: String) {
        setChoice(.dsee, value: selectedDevice?.dsee, option: option)
    }

    func setSystemFeature(id: String, enabled: Bool) {
        guard let device = selectedDevice, let feature = UInt8(id),
              device.systemFeatures.contains(where: { $0.id == id && $0.canSet }) else { return }
        submit(action: .systemFeature, device: device, enabled: enabled, feature: feature)
    }

    func setTouchAssignment(key: UInt8, option: String) {
        setChoice(.touchAssignment, value: selectedDevice?.touchAssignments.first { $0.id == key }?.assignment,
                  option: option, key: key)
    }

    func setTouchAction(key: UInt8, gesture: UInt8, option: String) {
        setChoice(.touchAction, value: selectedDevice?.touchAssignments.first { $0.id == key }?
            .gestures.first { $0.id == gesture }?.customization, option: option, key: key, gesture: gesture)
    }

    func setAutomaticPowerOff(option: String) {
        setChoice(.automaticPowerOff, value: selectedDevice?.automaticPowerOff, option: option)
    }

    func setBatteryCare(enabled: Bool) {
        guard let device = selectedDevice, device.batteryCare?.canSet == true else { return }
        submit(action: .batteryCare, device: device, enabled: enabled)
    }

    func setAutoPowerSave(enabled: Bool) {
        guard let device = selectedDevice, device.autoPowerSave?.canSet == true else { return }
        submit(action: .autoPowerSave, device: device, enabled: enabled)
    }

    func setVolume(_ value: Int, sourceAddress: String?) {
        guard let device = selectedDevice, let volume = device.volume, volume.canSet,
              volume.sourceAddress == sourceAddress,
              (volume.minimum...volume.maximum).contains(value) else { return }
        submit(action: .volume, device: device, volume: value, sourceAddress: sourceAddress)
    }

    private func setChoice(_ action: SonyPreferencePaneRequest.Action, value: SonyPreferencePaneDevice.Choice?,
                           option: String, key: UInt8? = nil, gesture: UInt8? = nil) {
        guard let device = selectedDevice, let value, value.canSet,
              value.options.contains(where: { $0.id == option && $0.isEnabled }) else { return }
        submit(action: action, device: device, option: option, key: key, gesture: gesture)
    }

    private func submit(action: SonyPreferencePaneRequest.Action, device: SonyPreferencePaneDevice,
                        mode: String? = nil, enabled: Bool? = nil, option: String? = nil, feature: UInt8? = nil,
                        key: UInt8? = nil, gesture: UInt8? = nil, bandIDs: [String]? = nil, values: [Int]? = nil,
                        levelSteps: Int? = nil, volume: Int? = nil, sourceAddress: String? = nil) {
        guard !isUpdating, let snapshot else { return }
        let request = SonyPreferencePaneRequest(version: SonyPreferencePaneWire.version, id: UUID(), action: action,
            serverID: snapshot.serverID, address: device.address, session: device.session, mode: mode, enabled: enabled,
            option: option, feature: feature, key: key, gesture: gesture, bandIDs: bandIDs, values: values,
            levelSteps: levelSteps, volume: volume, sourceAddress: sourceAddress)
        isUpdating = true
        commandError = nil
        let generation = generation
        command = Task { [weak self] in
            guard let self else { return }
            await self.exchange(request, generation: generation)
            guard self.generation == generation else { return }
            self.isUpdating = false
            self.command = nil
        }
    }

    private func refresh(generation: UUID) async {
        await exchange(.init(version: SonyPreferencePaneWire.version, id: UUID(), action: .snapshot), generation: generation)
    }

    private func exchange(_ request: SonyPreferencePaneRequest, generation: UUID) async {
        let path = path
        let appRequirement = appRequirement
        requestSequence += 1
        let sequence = requestSequence
        do {
            let reply = try await Task.detached {
                let fd = try SonyPreferencePaneWire.connect(path: path)
                defer { close(fd) }
                try SonyPreferencePaneWire.authenticate(fd, requirement: appRequirement)
                try SonyPreferencePaneWire.send(request, to: fd)
                let reply = try SonyPreferencePaneWire.receive(SonyPreferencePaneReply.self, from: fd)
                guard reply.version == SonyPreferencePaneWire.version, reply.id == request.id else {
                    throw SonyPreferencePaneWire.failure("The local response belongs to another request.")
                }
                return reply
            }.value
            guard self.generation == generation, !Task.isCancelled, sequence >= appliedSequence else { return }
            appliedSequence = sequence
            apply(reply, to: request)
        } catch {
            guard self.generation == generation, !Task.isCancelled, sequence >= appliedSequence else { return }
            appliedSequence = sequence
            if snapshot != nil { snapshot = nil }
            if connectionError != error.localizedDescription { connectionError = error.localizedDescription }
        }
    }

    private func apply(_ reply: SonyPreferencePaneReply, to request: SonyPreferencePaneRequest) {
        if snapshot != reply.snapshot { snapshot = reply.snapshot }
        if request.action != .snapshot {
            commandError = reply.error
            commandFailure = reply.error.map { (request, settingError(for: request, in: reply.snapshot) == $0) }
        }
        if let commandError, let failure = commandFailure, let snapshot {
            let device = snapshot.devices.first { $0.address == failure.request.address }
            if snapshot.serverID != failure.request.serverID || device?.session != failure.request.session
                || (failure.reported && settingError(for: failure.request, in: snapshot) != commandError) {
                self.commandError = nil
                commandFailure = nil
            }
        }
        let reportedError = reply.error ?? commandError
        let error = commandFailure?.reported == true && reportedError == commandError ? nil : reportedError
        if connectionError != error { connectionError = error }
        if pinnedAddress == nil, snapshot?.devices.contains(where: { $0.address == selectedAddress }) != true {
            let address = snapshot?.selectedAddress ?? snapshot?.devices.first?.address
            if selectedAddress != address { selectedAddress = address }
        }
    }

    private func settingError(for request: SonyPreferencePaneRequest, in snapshot: SonyPreferencePaneSnapshot?) -> String? {
        guard let device = snapshot?.devices.first(where: { $0.address == request.address }) else { return nil }
        switch request.action {
        case .snapshot: return nil
        case .noise: return device.noise?.error
        case .speak: return device.speak?.error
        case .equalizerPreset, .equalizer: return device.equalizer?.preset.error
        case .dsee: return device.dsee?.error
        case .systemFeature: return device.systemFeatures.first { $0.id == request.feature.map(String.init) }?.error
        case .touchAssignment: return device.touchAssignments.first { $0.id == request.key }?.assignment.error
        case .touchAction:
            return device.touchAssignments.first { $0.id == request.key }?.gestures.first { $0.id == request.gesture }?.customization?.error
        case .automaticPowerOff: return device.automaticPowerOff?.error
        case .batteryCare: return device.batteryCare?.error
        case .autoPowerSave: return device.autoPowerSave?.error
        case .volume: return device.volume?.error
        }
    }

    #if DEBUG
    func previewApply(_ reply: SonyPreferencePaneReply, to request: SonyPreferencePaneRequest) {
        apply(reply, to: request)
    }

    static func preview(snapshot: SonyPreferencePaneSnapshot, selectedAddress: String?, pinnedAddress: String? = nil) -> SonyPreferencePaneClient {
        let client = SonyPreferencePaneClient(pinnedAddress: pinnedAddress)
        client.snapshot = snapshot
        client.selectedAddress = pinnedAddress ?? selectedAddress
        return client
    }
    #endif
}
