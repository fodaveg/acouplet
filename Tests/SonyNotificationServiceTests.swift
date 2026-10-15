#if !ACOUPLET_PUBLIC_APIS_ONLY
import Foundation
import XCTest
@testable import Acouplet

final class SonyNotificationServiceTests: XCTestCase {
    @MainActor
    func testRejectedAudioSourceRetriesAndOnlyKeepsLatestSource() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        var accepted = false
        var attempts: [String] = []
        var presented: [String] = []
        let notifications = SonyNotificationService(settings: SettingsStore(defaults: defaults),
                                                    devices: SonyDeviceCoordinator(controller: controller),
                                                    presentAudioSource: { headphones, source in
            XCTAssertTrue(headphones === controller)
            attempts.append(source.name)
            if accepted { presented.append(source.name) }
            return accepted
        })
        notifications.start()
        deliverSourceInventory(selected: 1, to: controller)
        XCTAssertTrue(attempts.isEmpty)
        deliverSourceInventory(selected: 2, to: controller)
        XCTAssertEqual(attempts, ["Phone"])
        accepted = true
        notifications.retryPendingAlerts()
        XCTAssertEqual(presented, ["Phone"])
        notifications.retryPendingAlerts()
        XCTAssertEqual(attempts, ["Phone", "Phone"])
        accepted = false
        deliverSourceInventory(selected: 1, to: controller)
        deliverSourceInventory(selected: 2, to: controller)
        accepted = true
        notifications.retryPendingAlerts()
        XCTAssertEqual(attempts, ["Phone", "Phone", "MacBook Pro", "Phone", "Phone"])
        XCTAssertEqual(presented, ["Phone", "Phone"])
    }

    @MainActor
    func testPendingAudioSourceCannotSurviveDisconnectOrNewSession() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for disconnect in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            var attempts = 0
            var accepted = false
            let notifications = SonyNotificationService(settings: SettingsStore(defaults: defaults),
                                                        devices: SonyDeviceCoordinator(controller: controller),
                                                        presentAudioSource: { _, _ in attempts += 1; return accepted })
            notifications.start()
            deliverSourceInventory(selected: 1, to: controller)
            deliverSourceInventory(selected: 2, to: controller)
            XCTAssertEqual(attempts, 1)
            if disconnect {
                controller.simulateControlLoss()
                accepted = true
                notifications.retryPendingAlerts()
                XCTAssertEqual(attempts, 1)
            }
            let session = controller.notificationSession
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            XCTAssertNotEqual(controller.notificationSession, session)
            deliverSourceInventory(selected: 2, to: controller)
            accepted = true
            notifications.retryPendingAlerts()
            XCTAssertEqual(attempts, 1)
        }
    }

    @MainActor
    func testStaleInventoryDiscardsPendingAudioSourceNotice() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        var attempts = 0
        let notifications = SonyNotificationService(settings: SettingsStore(defaults: defaults),
                                                    devices: SonyDeviceCoordinator(controller: controller),
                                                    presentAudioSource: { _, _ in attempts += 1; return false })
        notifications.start()
        deliverSourceInventory(selected: 1, to: controller)
        deliverSourceInventory(selected: 2, to: controller)
        controller.simulateProtocolMessage([0x39, 2, 1], type: 0x0E)
        notifications.retryPendingAlerts()
        XCTAssertEqual(attempts, 1)
        deliverSourceInventory(selected: 2, to: controller)
        notifications.retryPendingAlerts()
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testFirmwareIgnoresRepeatedReportsAndResumesAfterFitTestWithoutConnectionChange() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = firmwareController()
        defer { controller.simulateControlLoss() }
        let settings = SettingsStore(defaults: defaults)
        settings.firmwareNotificationsEnabled = true
        let firstCheck = expectation(description: "Initial firmware check")
        firstCheck.assertForOverFulfill = false
        let bothChecks = expectation(description: "Firmware check resumes after fit test")
        bothChecks.expectedFulfillmentCount = 2
        let checker = SonyFirmwareUpdateChecker(defaults: defaults) { _ in
            firstCheck.fulfill()
            bothChecks.fulfill()
            return Data()
        }
        let notifications = SonyNotificationService(settings: settings, devices: SonyDeviceCoordinator(controller: controller),
                                                    firmware: checker, firmwareSession: {
            $0.isReady && $0.isDeviceConnected && $0.powerOffState == nil && !$0.isRunningHeadphoneTest
                && $0.deviceInformation.model == .wfXM5 ? $0.notificationSession : nil
        }, presentFirmware: { _, _ in XCTFail("No available firmware expected"); return false })
        notifications.start()
        await fulfillment(of: [firstCheck], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        let attemptKey = "firmwareUpdate.HP002.MDRID296300.attempted"
        XCTAssertNotNil(defaults.object(forKey: attemptKey))
        defaults.removeObject(forKey: attemptKey)
        for _ in 0..<3 { deliver([0x05, 0x02, 5] + Array("6.1.0".utf8), to: controller) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(defaults.object(forKey: attemptKey))
        let session = controller.notificationSession
        XCTAssertTrue(controller.beginEarTipFit())
        let id = try XCTUnwrap(controller.earTipFitTransition?.id)
        for reply: [UInt8] in [[0xF1, 6, 5, 1, 1, 4, 0, 1, 2, 3], [0xF3, 6, 0, 0, 1, 0], [0xF7, 6, 0, 0, 1, 0, 1, 255]] {
            deliver(reply, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
        XCTAssertTrue(controller.isRunningHeadphoneTest)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(defaults.object(forKey: attemptKey))
        controller.cancelEarTipFit(id: id)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertEqual(controller.notificationSession, session)
        XCTAssertTrue(controller.isDeviceConnected)
        await fulfillment(of: [bothChecks], timeout: 2)
        XCTAssertNotNil(defaults.object(forKey: attemptKey))
    }

    @MainActor
    func testLowBatteryPolicyIsOnlyPersistedWhenItChanges() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let devices = SonyDeviceCoordinator(controller: SonyHeadphonesController(startAutomatically: false, displayOnly: true))
        let notifications = SonyNotificationService(settings: SettingsStore(defaults: defaults), devices: devices)
        let key = "notifications.lowBatteryHistory"
        let healthy = SonyLowBatteryPolicy.Reading(part: .headphones, level: 80, isCharging: false, observedAt: Date())
        XCTAssertNil(defaults.data(forKey: key))
        await notifications.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [healthy])
        await notifications.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [healthy])
        XCTAssertNil(defaults.data(forKey: key), "An unchanged policy must not be written to UserDefaults")
    }

    @MainActor
    func testOptInFailureAndPersistenceOnlyConsumePresentedWarnings() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let devices = SonyDeviceCoordinator(controller: SonyHeadphonesController(startAutomatically: false, displayOnly: true))
        var accepted = false
        var attempts = 0
        var presented: [SonyLowBatteryPolicy.Warning] = []
        let notifications = SonyNotificationService(settings: settings, devices: devices, presentLowBattery: { warning, name in
            XCTAssertEqual(name, "WH-1000XM5")
            attempts += 1
            if accepted { presented.append(warning) }
            return accepted
        })
        let reading = SonyLowBatteryPolicy.Reading(part: .headphones, level: 20, isCharging: false, observedAt: Date())
        XCTAssertFalse(settings.lowBatteryNotificationsEnabled)
        await notifications.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [reading])
        XCTAssertEqual(attempts, 0)
        settings.lowBatteryNotificationsEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).lowBatteryNotificationsEnabled)
        await notifications.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [reading])
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(presented.isEmpty)
        accepted = true
        await notifications.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [reading])
        XCTAssertEqual(presented.map(\.reading), [reading])
        await notifications.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [reading])
        let restored = SonyNotificationService(settings: SettingsStore(defaults: defaults), devices: devices,
                                                presentLowBattery: { warning, _ in presented.append(warning); return true })
        await restored.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [reading])
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(presented.count, 1)
        let charged = SonyLowBatteryPolicy.Reading(part: .headphones, level: 50, isCharging: false, observedAt: Date())
        await restored.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [charged])
        await restored.updateLowBattery(deviceID: "WH", name: "WH-1000XM5", readings: [reading])
        XCTAssertEqual(presented.count, 2)
    }

    @MainActor
    func testDisconnectedContextCancellationAndChargingCannotConsumeWarnings() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.lowBatteryNotificationsEnabled = true
        let controller = SonyHeadphonesController(startAutomatically: false, pinnedAddress: "02:53:4F:4E:59:01",
                                                  advertisedName: "WF-1000XM5")
        let devices = SonyDeviceCoordinator(controller: controller)
        let deviceID = controller.address
        let session = controller.notificationSession
        XCTAssertEqual(controller.deviceModel, .wfXM5)
        XCTAssertFalse(controller.isDeviceConnected)
        XCTAssertNil(controller.lowBatteryNotificationDeviceID)
        var presented = 0
        let notifications = SonyNotificationService(settings: settings, devices: devices,
                                                    presentLowBattery: { _, _ in presented += 1; return true })
        let reading = SonyLowBatteryPolicy.Reading(part: .right, level: 10, isCharging: false, observedAt: Date())
        await notifications.updateLowBattery(deviceID: deviceID, name: "WF-1000XM5", readings: [reading],
                                             isCurrent: {
            controller.notificationSession == session && controller.lowBatteryNotificationDeviceID == deviceID
        })
        let task = Task { await notifications.updateLowBattery(deviceID: deviceID, name: "WF-1000XM5", readings: [reading]) }
        task.cancel()
        await task.value
        let stale = SonyLowBatteryPolicy.Reading(part: .right, level: 10, isCharging: false, observedAt: Date().addingTimeInterval(-46))
        await notifications.updateLowBattery(deviceID: deviceID, name: "WF-1000XM5", readings: [stale])
        let charging = SonyLowBatteryPolicy.Reading(part: .right, level: 10, isCharging: true, observedAt: Date())
        await notifications.updateLowBattery(deviceID: deviceID, name: "WF-1000XM5", readings: [charging])
        XCTAssertEqual(presented, 0)
        await notifications.updateLowBattery(deviceID: deviceID, name: "WF-1000XM5", readings: [reading])
        XCTAssertEqual(presented, 1)
    }

    @MainActor
    func testSuppressedNativePresentationRemainsEligibleAcrossRestart() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.lowBatteryNotificationsEnabled = true
        let devices = SonyDeviceCoordinator(controller: SonyHeadphonesController(startAutomatically: false, displayOnly: true))
        let notifications = SonyNotificationService(settings: settings, devices: devices, presentLowBattery: { _, _ in false })
        let reading = SonyLowBatteryPolicy.Reading(part: .left, level: 5, isCharging: false, observedAt: Date())
        await notifications.updateLowBattery(deviceID: "WF", name: "WF-1000XM5", readings: [reading])
        var presented = 0
        let restored = SonyNotificationService(settings: settings, devices: devices,
                                                presentLowBattery: { _, _ in presented += 1; return true })
        await restored.updateLowBattery(deviceID: "WF", name: "WF-1000XM5", readings: [reading])
        XCTAssertEqual(presented, 1)
    }

    @MainActor
    func testOneFreshSnapshotOnlyPresentsItsLowestEligiblePart() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.lowBatteryNotificationsEnabled = true
        let devices = SonyDeviceCoordinator(controller: SonyHeadphonesController(startAutomatically: false, displayOnly: true))
        var presented: [SonyLowBatteryPolicy.Warning] = []
        let notifications = SonyNotificationService(settings: settings, devices: devices,
                                                    presentLowBattery: { warning, _ in presented.append(warning); return true })
        let readings: [SonyLowBatteryPolicy.Reading] = [
            .init(part: .left, level: 20, isCharging: false, observedAt: Date()),
            .init(part: .caseBattery, level: 5, isCharging: false, observedAt: Date()),
        ]
        await notifications.updateLowBattery(deviceID: "WF", name: "WF-1000XM5", readings: readings)
        XCTAssertEqual(presented.map(\.reading.part), [.caseBattery])
        await notifications.updateLowBattery(deviceID: "WF", name: "WF-1000XM5", readings: readings)
        XCTAssertEqual(presented.map(\.reading.part), [.caseBattery, .left])
    }

    @MainActor
    func testFirmwareRejectionDoesNotConsumeVersionAndAcceptanceDeduplicates() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.firmwareNotificationsEnabled = true
        let controller = firmwareController()
        defer { controller.simulateControlLoss() }
        deliver([0x05, 0x02, 5] + Array("6.0.0".utf8), to: controller)
        let firstAttempt = expectation(description: "Native firmware presentation is rejected")
        let secondAttempt = expectation(description: "Native firmware presentation is accepted")
        let checker = SonyFirmwareUpdateChecker(defaults: defaults) { _ in SonyFirmwareUpdateTests.manifest }
        var accepted = false
        var attempts = 0
        let notifications = SonyNotificationService(settings: settings, devices: SonyDeviceCoordinator(controller: controller),
                                                    firmware: checker, firmwareSession: {
            $0.isReady && $0.isDeviceConnected ? $0.notificationSession : nil
        }, presentFirmware: { origin, version in
            XCTAssertTrue(origin === controller)
            XCTAssertEqual(version, "6.1.0")
            attempts += 1
            if accepted { secondAttempt.fulfill() }
            else { firstAttempt.fulfill() }
            return accepted
        })
        notifications.start()
        await fulfillment(of: [firstAttempt], timeout: 2)
        let key = "firmwareUpdate.HP002.MDRID296300.notified"
        XCTAssertNil(defaults.object(forKey: key))
        accepted = true
        notifications.retryPendingAlerts()
        await fulfillment(of: [secondAttempt], timeout: 2)
        XCTAssertEqual(defaults.string(forKey: key), "6.1.0")
        notifications.retryPendingAlerts()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testFirmwareSessionLossDuringCheckCannotPresentOrConsumeVersion() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.firmwareNotificationsEnabled = true
        let controller = firmwareController()
        defer { controller.simulateControlLoss() }
        deliver([0x05, 0x02, 5] + Array("6.0.0".utf8), to: controller)
        let checking = expectation(description: "Firmware metadata is pending")
        let checker = SonyFirmwareUpdateChecker(defaults: defaults) { _ in
            checking.fulfill()
            try await Task.sleep(for: .milliseconds(100))
            return SonyFirmwareUpdateTests.manifest
        }
        let notifications = SonyNotificationService(settings: settings, devices: SonyDeviceCoordinator(controller: controller),
                                                    firmware: checker, firmwareSession: {
            $0.isReady && $0.isDeviceConnected ? $0.notificationSession : nil
        }, presentFirmware: { _, _ in XCTFail("The originating connection has ended"); return true })
        notifications.start()
        await fulfillment(of: [checking], timeout: 2)
        controller.simulateControlLoss()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(defaults.object(forKey: "firmwareUpdate.HP002.MDRID296300.notified"))
    }

    @MainActor
    private func deliverSourceInventory(selected: UInt8, to controller: SonyHeadphonesController) {
        let devices: [(String, UInt8, String)] = [("02:00:00:00:00:01", 1, "MacBook Pro"), ("02:00:00:00:00:02", 2, "Phone")]
        let entries: [UInt8] = devices.flatMap { address, id, name -> [UInt8] in
            Array(address.utf8) + [id, 0x2A, 0x41, 4, UInt8(name.utf8.count)] + Array(name.utf8)
        }
        controller.simulateProtocolMessage([0x39, 2, 2] + entries + [selected], type: 0x0E)
    }

    @MainActor
    private func firmwareController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        deliver([0x05, 0x01, 10] + Array("WF-1000XM5".utf8), to: controller)
        deliver([7, 0, 3, 0x6B, 1, 0x32, 1, 0xF6, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 0x17, 1, 0, 2, 18, 3], to: controller)
        deliver([0x63, 0x17, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 1, 0, 8], to: controller)
        acknowledgeAll(controller)
        deliver([0x05, 0x02, 5] + Array("6.1.0".utf8), to: controller)
        controller.requestFirmwareUpdateIdentity()
        acknowledgeAll(controller)
        let fields = ["HP002", "MDRID296300", "US", "English", "12345"].flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
        deliver([0x37, 0x02] + fields, to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertNotNil(controller.firmwareUpdateIdentity)
        return controller
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The command queue did not drain.")
    }
}
#endif
