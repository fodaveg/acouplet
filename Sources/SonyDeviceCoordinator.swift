import Combine
import CoreBluetooth
import Foundation

struct SonyConnectedDevice: Identifiable, Equatable {
    let address: String
    let name: String
    let model: SonyDeviceModel

    var id: String { address }

    init?(address: String, name: String, model: SonyDeviceModel) {
        guard let address = SonyBLEIdentity.normalizedAddress(address), model != .unknown else { return nil }
        self.address = address
        self.name = name
        self.model = model
    }
}

@MainActor
final class SonyDeviceCoordinator: NSObject, ObservableObject {
    private struct NoiseControlTarget {
        let identifier: String
        let address: String
        let model: SonyDeviceModel
        let mode: NoiseControlMode

        init?(_ identifier: String) {
            let parts = identifier.split(separator: ":")
            guard parts.count == 8,
                  let address = SonyBLEIdentity.normalizedAddress(parts.prefix(6).joined(separator: ":")),
                  let model = SonyDeviceModel(rawValue: String(parts[6])), model != .unknown,
                  let mode = NoiseControlMode(rawValue: String(parts[7])),
                  identifier == "\(address):\(model.rawValue):\(mode.rawValue)" else { return nil }
            self.identifier = identifier
            self.address = address
            self.model = model
            self.mode = mode
        }
    }

    private struct SpeakToChatTarget {
        let identifier: String
        let address: String
        let model: SonyDeviceModel
        let enabled: Bool

        init?(_ identifier: String) {
            let parts = identifier.split(separator: ":")
            guard parts.count == 8,
                  let address = SonyBLEIdentity.normalizedAddress(parts.prefix(6).joined(separator: ":")),
                  let model = SonyDeviceModel(rawValue: String(parts[6])), model != .unknown,
                  ["speak-to-chat-on", "speak-to-chat-off"].contains(String(parts[7])),
                  identifier == "\(address):\(model.rawValue):\(parts[7])" else { return nil }
            self.identifier = identifier
            self.address = address
            self.model = model
            enabled = parts[7] == "speak-to-chat-on"
        }
    }

    @Published private(set) var connectedDevices: [SonyConnectedDevice] = []
    @Published private(set) var selectedAddress: String?
    @Published private(set) var controllers: [SonyHeadphonesController] = []

    private let fallbackController: SonyHeadphonesController
    private let controllerFactory: (SonyConnectedDevice) -> SonyHeadphonesController
    private var controllersByAddress: [String: SonyHeadphonesController] = [:]
    private var devicesByAddress: [String: SonyConnectedDevice] = [:]
    private var connectedAddresses: Set<String> = []
    private var observations: [String: AnyCancellable] = [:]
    private var fallbackObservation: AnyCancellable?
    private var updateScheduled = false
    private var earbudFindingTerminationObserver: AnyCancellable?
    private var earbudFindingTerminationSessions = Set<UUID>()

    var discoveryTimer: Timer?
    var bluetoothAuthorizationManager: CBCentralManager?
    var discoveryGeneration: UInt64 = 0
    @Published var isDiscovering = false
    @Published var isSystemSleeping = false
    @Published var isRunning = false
    private(set) var isTerminating = false
    var reconnectAutomatically = true
    var reconnectSuppressedAddress: String?
    var retiredControllerAddresses: Set<String> = []
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    var nativeBatteryPublisher: SonyNativeBatteryPublisher?
    #endif

    var selectedController: SonyHeadphonesController {
        selectedAddress.flatMap { controllersByAddress[$0] } ?? fallbackController
    }

    var retainedDevices: [SonyConnectedDevice] {
        devicesByAddress.values.sorted(by: Self.ordered)
    }

    var hasMultipleConnectedDevices: Bool { connectedDevices.count > 1 }

    var selectableDevices: [SonyConnectedDevice] {
        retainedDevices.filter { device in
            connectedAddresses.contains(device.address) || controllersByAddress[device.address]?.earbudFinder?.isBusy == true
                || controllersByAddress[device.address]?.earbudFinder?.mayBeRinging == true
        }
    }

    var hasOtherSelectableDevices: Bool { selectableDevices.contains { $0.address != selectedAddress } }

    init(fallbackController: SonyHeadphonesController,
         controllerFactory: @escaping (SonyConnectedDevice) -> SonyHeadphonesController) {
        self.fallbackController = fallbackController
        self.controllerFactory = controllerFactory
        super.init()
        fallbackObservation = fallbackController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    convenience init(controller: SonyHeadphonesController) {
        self.init(fallbackController: controller) { device in
            SonyHeadphonesController(startAutomatically: false, pinnedAddress: device.address, advertisedName: device.name)
        }
        if let device = SonyConnectedDevice(address: controller.address, name: controller.deviceName, model: controller.deviceModel) {
            retain(controller, for: device)
            selectedAddress = device.address
            if controller.isDeviceConnected {
                connectedAddresses = [device.address]
                connectedDevices = [device]
            }
        }
    }

    func controller(for address: String) -> SonyHeadphonesController? {
        SonyBLEIdentity.normalizedAddress(address).flatMap { controllersByAddress[$0] }
    }

    @discardableResult
    func reportBluetoothAuthorization(_ authorization: CBManagerAuthorization) -> Bool {
        fallbackController.reportBluetoothAuthorization(authorization)
        guard isRunning, !isSystemSleeping else { return false }
        guard authorization == .allowedAlways else {
            discoveryGeneration += 1
            isDiscovering = false
            discoveryTimer?.invalidate()
            discoveryTimer = nil
            for controller in controllers {
                controller.stop()
                controller.reportBluetoothAuthorization(authorization)
            }
            return false
        }
        return !isDiscovering && discoveryTimer == nil
    }

    func select(address: String) {
        guard let normalized = SonyBLEIdentity.normalizedAddress(address), selectableDevices.contains(where: { $0.address == normalized }),
              selectedAddress != normalized else { return }
        selectedAddress = normalized
    }

    func selectForWorkflow(address: String) {
        guard let normalized = SonyBLEIdentity.normalizedAddress(address), controllersByAddress[normalized] != nil,
              selectedAddress != normalized else { return }
        selectedAddress = normalized
    }

    func prepareEarbudFindingForTermination(completion: @escaping () -> Void) -> Bool {
        guard earbudFindingTerminationObserver == nil else { return true }
        for finder in controllers.compactMap(\.earbudFinder) { finder.requestTransportRetirement() }
        let finders = controllers.compactMap(\.earbudFinder).filter { finder in
            guard let session = finder.session else { return false }
            return (finder.isBusy || finder.mayBeRinging) && !earbudFindingTerminationSessions.contains(session.id)
        }
        guard !finders.isEmpty else { return false }
        earbudFindingTerminationSessions.formUnion(finders.compactMap { $0.session?.id })
        earbudFindingTerminationObserver = Publishers.MergeMany(finders.map { $0.$session.eraseToAnyPublisher() })
            .receive(on: DispatchQueue.main)
            .first { _ in finders.allSatisfy { !$0.isBusy } }
            .sink { [weak self] _ in
                guard let self else { return }
                self.earbudFindingTerminationObserver = nil
                completion()
            }
        for finder in finders {
            if finder.session?.isRetryingStop == true { continue }
            if finder.session?.phase == .unconfirmed, finder.mayBeRinging { finder.retryStop() }
            else { finder.dismiss() }
        }
        return true
    }

    /// Forbids new RFCOMM channels on every controller, including ones created while quitting.
    /// Safe to call repeatedly; call it before LDAC restoration reconnects the ACL.
    func beginTermination() {
        isTerminating = true
        for controller in terminationControllers { controller.beginTermination() }
    }

    /// Undoes `beginTermination()` when the quit is cancelled.
    func cancelTermination() {
        isTerminating = false
        for controller in terminationControllers { controller.cancelTermination() }
    }

    /// Closes every control channel and waits (bounded) for in-flight opens and closes.
    /// Returns `true` when `completion` will run later; `false` when nothing was pending.
    func drainRFCOMMForTermination(completion: @escaping @MainActor () -> Void) -> Bool {
        var remaining = 0
        var finished = false
        var waiting = false
        let leave: @MainActor () -> Void = {
            remaining -= 1
            if remaining == 0, waiting, !finished { finished = true; completion() }
        }
        for controller in terminationControllers {
            remaining += 1
            if !controller.drainRFCOMMForTermination(completion: leave) { remaining -= 1 }
        }
        waiting = true
        return remaining > 0
    }

    private var terminationControllers: [SonyHeadphonesController] {
        var all = controllers
        if !all.contains(where: { $0 === fallbackController }) { all.append(fallbackController) }
        return all
    }

    func resetEarbudFindingTermination() {
        earbudFindingTerminationObserver = nil
        earbudFindingTerminationSessions.removeAll()
    }

    func reconcileConnectedDevices(_ devices: [SonyConnectedDevice]) {
        reconcilePairedDevices(devices, connectedAddresses: Set(devices.map(\.address)))
    }

    func reconcilePairedDevices(_ devices: [SonyConnectedDevice], connectedAddresses: Set<String>) {
        var addresses: Set<String> = []
        for device in devices.sorted(by: Self.ordered) where addresses.insert(device.address).inserted {
            if controllersByAddress[device.address] == nil {
                retain(controllerFactory(device), for: device)
            } else {
                devicesByAddress[device.address] = device
            }
        }
        self.connectedAddresses = Set(connectedAddresses.compactMap(SonyBLEIdentity.normalizedAddress)).intersection(addresses)
        updateDevices()
        if selectedAddress == nil {
            selectedAddress = devices.sorted(by: Self.ordered).first?.address
        }
    }

    @available(macOS 27.0, *)
    var noiseControlActions: [HeadphoneNoiseControlAction] {
        let available = controllers.filter { !$0.noiseControlActions.isEmpty }
        return available.flatMap { controller in
            let actions = controller.noiseControlActions
            guard available.filter({ $0.deviceModel == controller.deviceModel }).count > 1 else { return actions }
            return actions.map { action in
                HeadphoneNoiseControlAction(id: action.id, title: action.title,
                    modelName: "\(action.modelName) · \(controller.address.suffix(5))",
                    symbolName: action.symbolName, systemSymbol: action.systemSymbol)
            }
        }
    }

    @available(macOS 27.0, *)
    func resolveNoiseControlActions(for identifiers: [String], startupTimeout: Duration = .seconds(10)) async throws -> [HeadphoneNoiseControlAction] {
        let targets = Set(identifiers).sorted().compactMap { NoiseControlTarget($0) }
        try await waitForControlStartup(targets.map { ($0.address, $0.model) }, requiresReady: false, timeout: startupTimeout)
        return targets.compactMap { target in
            guard let device = controlDevice(address: target.address, model: target.model) else { return nil }
            let name = retainedDevices.filter { $0.model == device.model && !retiredControllerAddresses.contains($0.address) }.count > 1
                ? "\(device.model.name) · \(device.address.suffix(5))" : device.model.name
            return HeadphoneNoiseControlAction(id: target.identifier, title: target.mode.title,
                modelName: name, symbolName: device.model.symbol, systemSymbol: device.model.systemSymbol)
        }
    }

    @available(macOS 27.0, *)
    func performNoiseControlAction(_ identifier: String, startupTimeout: Duration = .seconds(10)) async throws {
        guard let target = NoiseControlTarget(identifier) else {
            throw HeadphoneControlError(message: String(localized: "This headphone action is no longer valid."))
        }
        try await waitForControlStartup([(target.address, target.model)], requiresReady: true, timeout: startupTimeout)
        guard controlDevice(address: target.address, model: target.model) != nil, let controller = controllersByAddress[target.address],
              controller.noiseControlActions.contains(where: { $0.id == identifier }) else {
            throw HeadphoneControlError(message: String(localized: "These headphones are no longer available for noise control."))
        }
        try await controller.performNoiseControlAction(identifier)
    }

    @available(macOS 27.0, *)
    var speakToChatActions: [HeadphoneSpeakToChatAction] {
        let available = controllers.filter { !$0.speakToChatActions.isEmpty }
        return available.flatMap { controller in
            let actions = controller.speakToChatActions
            guard available.filter({ $0.deviceModel == controller.deviceModel }).count > 1 else { return actions }
            return actions.map { action in
                HeadphoneSpeakToChatAction(id: action.id, enabled: action.enabled,
                    modelName: "\(action.modelName) · \(controller.address.suffix(5))")
            }
        }
    }

    @available(macOS 27.0, *)
    func resolveSpeakToChatActions(for identifiers: [String], startupTimeout: Duration = .seconds(10)) async throws -> [HeadphoneSpeakToChatAction] {
        let targets = Set(identifiers).sorted().compactMap { SpeakToChatTarget($0) }
        try await waitForControlStartup(targets.map { ($0.address, $0.model) }, requiresReady: false, timeout: startupTimeout)
        return targets.compactMap { target in
            guard let device = controlDevice(address: target.address, model: target.model) else { return nil }
            let name = retainedDevices.filter { $0.model == device.model && !retiredControllerAddresses.contains($0.address) }.count > 1
                ? "\(device.model.name) · \(device.address.suffix(5))" : device.model.name
            return HeadphoneSpeakToChatAction(id: target.identifier, enabled: target.enabled, modelName: name)
        }
    }

    @available(macOS 27.0, *)
    func performSpeakToChatAction(_ identifier: String, startupTimeout: Duration = .seconds(10)) async throws {
        guard let target = SpeakToChatTarget(identifier) else {
            throw HeadphoneControlError(message: String(localized: "This headphone action is no longer valid."))
        }
        try await waitForControlStartup([(target.address, target.model)], requiresReady: true, timeout: startupTimeout)
        guard controlDevice(address: target.address, model: target.model) != nil, let controller = controllersByAddress[target.address],
              controller.speakToChatActions.contains(where: { $0.id == identifier }) else {
            throw HeadphoneControlError(message: String(localized: "These headphones are no longer available for Speak-to-Chat."))
        }
        try await controller.performSpeakToChatAction(identifier)
    }

    private func controlDevice(address: String, model: SonyDeviceModel) -> SonyConnectedDevice? {
        guard !retiredControllerAddresses.contains(address),
              let device = devicesByAddress[address], device.model == model,
              let controller = controllersByAddress[address],
              controller.deviceModel == .unknown || controller.deviceModel == model else { return nil }
        return device
    }

    private func controlStartupIsPending(_ targets: [(address: String, model: SonyDeviceModel)], requiresReady: Bool) -> Bool {
        guard !isSystemSleeping else { return false }
        return targets.contains { target in
            guard let device = controlDevice(address: target.address, model: target.model) else {
                return devicesByAddress[target.address] == nil &&
                    (isDiscovering || (!isRunning && discoveryGeneration == 0 && controllers.isEmpty))
            }
            guard requiresReady, isRunning, let controller = controllersByAddress[device.address] else { return false }
            return controller.linkState == .searching || controller.linkState == .opening || controller.linkState == .handshaking
        }
    }

    private func waitForControlStartup(_ targets: [(address: String, model: SonyDeviceModel)], requiresReady: Bool, timeout: Duration) async throws {
        try Task.checkCancellation()
        guard controlStartupIsPending(targets, requiresReady: requiresReady) else { return }
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = objectWillChange.sink { changes.continuation.yield(()) }
        let deadline = Task {
            try await Task.sleep(for: timeout)
            changes.continuation.finish()
        }
        defer {
            observation.cancel()
            deadline.cancel()
            changes.continuation.finish()
        }
        changes.continuation.yield(())
        for await _ in changes.stream {
            await Task.yield()
            try Task.checkCancellation()
            if !controlStartupIsPending(targets, requiresReady: requiresReady) { return }
        }
        try Task.checkCancellation()
        throw HeadphoneControlError(message: String(localized: "The headphones are still connecting. Try again in a moment."))
    }

    private func retain(_ controller: SonyHeadphonesController, for device: SonyConnectedDevice) {
        if isTerminating { controller.beginTermination() }
        controllersByAddress[device.address] = controller
        devicesByAddress[device.address] = device
        observations[device.address] = controller.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            guard !self.updateScheduled else { return }
            self.updateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.updateDevices()
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                self.reconcileNativeBatteries()
                #endif
            }
        }
        controllers = controllersByAddress.keys.sorted().compactMap { controllersByAddress[$0] }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func reconcileNativeBatteries() {
        guard let nativeBatteryPublisher else { return }
        guard isRunning, !isSystemSleeping else { nativeBatteryPublisher.revoke(); return }
        let date = Date()
        let eligible = controllers.filter {
            !retiredControllerAddresses.contains($0.address)
        }
        nativeBatteryPublisher.reconcile(eligible.compactMap { $0.nativeBatteryPublication(at: date) })
    }

    #endif

    private func updateDevices() {
        for (address, controller) in controllersByAddress {
            guard let previous = devicesByAddress[address] else { continue }
            let name = controller.deviceName == String(localized: "Sony headphones") ? previous.name : controller.deviceName
            let model = controller.deviceModel == .unknown ? previous.model : controller.deviceModel
            devicesByAddress[address] = SonyConnectedDevice(address: address, name: name, model: model)
        }
        let connected = retainedDevices.filter { connectedAddresses.contains($0.address) }
        if connectedDevices != connected { connectedDevices = connected }
        guard let first = connected.first, selectedAddress.map({ !connectedAddresses.contains($0) }) ?? true else { return }
        if selectedAddress != nil, selectedController.needsDeviceContext || selectedAddress == reconnectSuppressedAddress { return }
        selectedAddress = first.address
    }

    private static func ordered(_ lhs: SonyConnectedDevice, _ rhs: SonyConnectedDevice) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame ? lhs.address < rhs.address : comparison == .orderedAscending
    }
}

extension SonyHeadphonesController {
    var needsDeviceContext: Bool {
        earTipFitTransition != nil || headGesturePracticeTransition != nil || legacyOptimizerTransition != nil
            || earbudFinder?.isBusy == true || earbudFinder?.mayBeRinging == true
            || connectionTransition.map { !$0.isFinished || $0.phase == .failed || $0.phase == .pairingRequired } == true
            || multipointTransition.map { !$0.isFinished || $0.phase == .failed } == true
            || sourceTransition?.isFinished == false || deviceActionTransition?.isFinished == false
            || !pendingChanges.isEmpty || isApplyingChange || isPoweringOff || hasPendingManualBLEConnection
    }
}
