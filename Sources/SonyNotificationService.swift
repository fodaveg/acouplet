#if !ACOUPLET_PUBLIC_APIS_ONLY
import Combine
import Foundation

@MainActor
final class SonyNotificationService: ObservableObject {
    private let settings: SettingsStore
    private let devices: SonyDeviceCoordinator
    private let presentLowBattery: (SonyLowBatteryPolicy.Warning, String) -> Bool
    private let presentFirmware: (SonyHeadphonesController, String) -> Bool
    private let presentAudioSource: (SonyHeadphonesController, SonyMultipointDevice) -> Bool
    private let firmware: SonyFirmwareUpdateChecker
    private let firmwareSession: (SonyHeadphonesController) -> UInt64?
    private var policy: SonyLowBatteryPolicy
    private var cancellables = Set<AnyCancellable>()
    private var controllerObservers: [ObjectIdentifier: [AnyCancellable]] = [:]
    private var batteryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var firmwareTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var pendingFirmwareNotifications = Set<String>()
    private var pendingAudioSourceNotifications: [ObjectIdentifier: (session: UInt64, source: SonyMultipointDevice)] = [:]
    private var hasStarted = false

    init(settings: SettingsStore, devices: SonyDeviceCoordinator,
         firmware: SonyFirmwareUpdateChecker? = nil,
         firmwareSession: @escaping (SonyHeadphonesController) -> UInt64? = { $0.firmwareUpdateSession },
         presentLowBattery: @escaping (SonyLowBatteryPolicy.Warning, String) -> Bool = { _, _ in false },
         presentFirmware: @escaping (SonyHeadphonesController, String) -> Bool = { _, _ in false },
         presentAudioSource: @escaping (SonyHeadphonesController, SonyMultipointDevice) -> Bool = { _, _ in false }) {
        self.settings = settings
        self.devices = devices
        self.presentLowBattery = presentLowBattery
        self.presentFirmware = presentFirmware
        self.presentAudioSource = presentAudioSource
        self.firmware = firmware ?? SonyFirmwareUpdateChecker(defaults: settings.defaults)
        self.firmwareSession = firmwareSession
        policy = settings.defaults.data(forKey: "notifications.lowBatteryHistory")
            .flatMap { try? JSONDecoder().decode(SonyLowBatteryPolicy.self, from: $0) } ?? SonyLowBatteryPolicy()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        devices.$controllers
            .sink { [weak self] controllers in self?.observe(controllers) }
            .store(in: &cancellables)
        settings.$lowBatteryNotificationsEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                for controller in devices.controllers { restartBatteryTask(for: controller) }
            }
            .store(in: &cancellables)
        settings.$firmwareNotificationsEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                for controller in devices.controllers { restartFirmwareTask(for: controller) }
            }
            .store(in: &cancellables)
    }

    func updateLowBattery(deviceID: String, name: String, readings: [SonyLowBatteryPolicy.Reading],
                          isCurrent: () -> Bool = { true }, at date: Date = Date()) async {
        let previous = policy
        let warnings = policy.warnings(for: deviceID, readings: readings, at: date)
        if policy != previous { persistPolicy() }
        guard settings.lowBatteryNotificationsEnabled, let warning = warnings.first,
              !Task.isCancelled, warning.reading.isFresh(at: Date()), isCurrent() else { return }
        if presentLowBattery(warning, name) {
            policy.didPresent(warning, at: Date())
            persistPolicy()
        }
    }

    func retryPendingAlerts() {
        guard hasStarted else { return }
        for controller in devices.controllers {
            retryAudioSourceNotice(for: controller)
            restartBatteryTask(for: controller)
            restartFirmwareTask(for: controller)
        }
    }

    func checkFirmware(identity: SonyFirmwareUpdateIdentity, currentVersion: String) async -> SonyFirmwareAvailability {
        await firmware.check(identity: identity, currentVersion: currentVersion, force: true)
    }

    private func persistPolicy() {
        if let data = try? JSONEncoder().encode(policy) {
            settings.defaults.set(data, forKey: "notifications.lowBatteryHistory")
        }
    }

    private func observe(_ controllers: [SonyHeadphonesController]) {
        let identifiers = Set(controllers.map(ObjectIdentifier.init))
        controllerObservers = controllerObservers.filter { identifiers.contains($0.key) }
        pendingAudioSourceNotifications = pendingAudioSourceNotifications.filter { identifiers.contains($0.key) }
        for (identifier, task) in batteryTasks where !identifiers.contains(identifier) { task.cancel() }
        for (identifier, task) in firmwareTasks where !identifiers.contains(identifier) { task.cancel() }
        batteryTasks = batteryTasks.filter { identifiers.contains($0.key) }
        firmwareTasks = firmwareTasks.filter { identifiers.contains($0.key) }
        for controller in controllers where controllerObservers[ObjectIdentifier(controller)] == nil {
            let battery = controller.$lowBatteryReadings
                .combineLatest(controller.$linkState, controller.$isDeviceConnected)
                .sink { [weak self, weak controller] _ in
                    guard let controller else { return }
                    self?.restartBatteryTask(for: controller)
                }
            let firmware = controller.objectWillChange
                .prepend(())
                .receive(on: DispatchQueue.main)
                .map { [weak controller, firmwareSession] _ in
                    (controller.flatMap(firmwareSession), controller?.deviceInformation.modelName,
                     controller?.firmwareUpdateIdentity, controller?.firmwareVersion)
                }
                .removeDuplicates { $0 == $1 }
                .sink { [weak self, weak controller] _ in
                    guard let controller else { return }
                    self?.restartFirmwareTask(for: controller)
                }
            let source = controller.audioSourceChanges
                .sink { [weak self, weak controller] source in
                    guard let self, let controller else { return }
                    pendingAudioSourceNotifications[ObjectIdentifier(controller)] = (controller.notificationSession, source)
                    retryAudioSourceNotice(for: controller)
                }
            controllerObservers[ObjectIdentifier(controller)] = [battery, firmware, source]
        }
    }

    private func retryAudioSourceNotice(for controller: SonyHeadphonesController) {
        let identifier = ObjectIdentifier(controller)
        guard let pending = pendingAudioSourceNotifications[identifier] else { return }
        guard controller.isReady, controller.isDeviceConnected, controller.notificationSession == pending.session,
              !controller.multipoint.inventoryIsStale, controller.multipoint.selectedSource == pending.source else {
            pendingAudioSourceNotifications[identifier] = nil
            return
        }
        if presentAudioSource(controller, pending.source) { pendingAudioSourceNotifications[identifier] = nil }
    }

    private func restartBatteryTask(for controller: SonyHeadphonesController) {
        let identifier = ObjectIdentifier(controller)
        let previous = batteryTasks[identifier]
        previous?.cancel()
        batteryTasks[identifier] = Task { [weak self, weak controller] in
            await previous?.value
            guard !Task.isCancelled, let self, let controller,
                  let address = controller.lowBatteryNotificationDeviceID else { return }
            let session = controller.notificationSession
            await updateLowBattery(deviceID: address, name: controller.deviceName,
                                   readings: controller.lowBatteryReadings) {
                controller.notificationSession == session && controller.lowBatteryNotificationDeviceID == address
            }
        }
    }

    private func restartFirmwareTask(for controller: SonyHeadphonesController) {
        let identifier = ObjectIdentifier(controller)
        let previous = firmwareTasks[identifier]
        previous?.cancel()
        firmwareTasks[identifier] = Task { [weak self, weak controller] in
            await previous?.value
            guard !Task.isCancelled, let self, let controller, settings.firmwareNotificationsEnabled,
                  let session = firmwareSession(controller) else { return }
            controller.requestFirmwareUpdateIdentity()
            guard let identity = controller.firmwareUpdateIdentity, let currentVersion = controller.firmwareVersion else { return }
            guard case let .available(version) = await firmware.check(identity: identity, currentVersion: currentVersion),
                  !Task.isCancelled, firmware.shouldNotify(identity: identity, version: version),
                  pendingFirmwareNotifications.insert(identity.key).inserted else { return }
            defer { pendingFirmwareNotifications.remove(identity.key) }
            guard settings.firmwareNotificationsEnabled, firmwareSession(controller) == session,
                  controller.firmwareUpdateIdentity == identity, controller.firmwareVersion == currentVersion else { return }
            if presentFirmware(controller, version) { firmware.markNotified(identity: identity, version: version) }
        }
    }
}
#endif
