import Combine
import CoreBluetooth
import XCTest
@testable import Acouplet

@MainActor
final class SonyDeviceCoordinatorLifecycleTests: XCTestCase {
    func testBluetoothAuthorizationGrantResumesOnlyIdleRunningDiscovery() {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        for authorization in [CBManagerAuthorization.notDetermined, .denied, .restricted] {
            XCTAssertFalse(devices.reportBluetoothAuthorization(authorization))
            XCTAssertFalse(devices.isDiscovering)
            XCTAssertNil(devices.discoveryTimer)
            XCTAssertTrue(devices.reportBluetoothAuthorization(.allowedAlways))
            devices.isDiscovering = true
            XCTAssertFalse(devices.reportBluetoothAuthorization(.allowedAlways))
            devices.isDiscovering = false
            devices.discoveryTimer = Timer(timeInterval: 3, repeats: true) { _ in }
            XCTAssertFalse(devices.reportBluetoothAuthorization(.allowedAlways))
        }
        devices.systemWillSleep()
        XCTAssertFalse(devices.reportBluetoothAuthorization(.allowedAlways))
        devices.stop()
        XCTAssertFalse(devices.reportBluetoothAuthorization(.allowedAlways))
    }

    func testBluetoothAuthorizationLossStopsDiscoveryAndRetainedControllers() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.reconcileDiscoveredDevices([earbuds], connectedAddresses: [earbuds.address])
        let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
        let generation = devices.discoveryGeneration
        let session = controller.simulatedControlSession
        devices.isDiscovering = true
        let timer = Timer(timeInterval: 3, repeats: true) { _ in }
        devices.discoveryTimer = timer

        XCTAssertFalse(devices.reportBluetoothAuthorization(.denied))
        XCTAssertGreaterThan(devices.discoveryGeneration, generation)
        XCTAssertFalse(devices.isDiscovering)
        XCTAssertNil(devices.discoveryTimer)
        XCTAssertFalse(timer.isValid)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(controller.isBluetoothAccessDenied)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(devices.reportBluetoothAuthorization(.allowedAlways))
    }

    func testInventoryRefreshRevocationInvalidatesControlsAndDiscovery() throws {
        for authorization in [CBManagerAuthorization.denied, .restricted] {
            let devices = makeCoordinator()
            defer { devices.stop() }
            devices.isRunning = true
            devices.reconcileDiscoveredDevices([earbuds], connectedAddresses: [earbuds.address])
            let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
            XCTAssertTrue(controller.isReady)
            controller.setDSEE(.off)
            XCTAssertNotNil(controller.pendingChanges[.dsee])
            XCTAssertNotNil(controller.simulatedPendingFrame)
            let session = controller.simulatedControlSession
            let timer = Timer(timeInterval: 3, repeats: true) { _ in }
            devices.discoveryTimer = timer

            devices.refreshPairedInventory(authorization: authorization)

            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertFalse(controller.isReady)
            XCTAssertTrue(controller.isBluetoothAccessDenied)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertNil(devices.discoveryTimer)
            XCTAssertFalse(timer.isValid)
            XCTAssertTrue(devices.reportBluetoothAuthorization(.allowedAlways))
        }
    }

    func testInventoryRefreshCannotReactivateStoppedOrSleepingDiscovery() throws {
        for sleeping in [false, true] {
            let devices = makeCoordinator()
            defer { devices.stop() }
            devices.isRunning = true
            devices.reconcileDiscoveredDevices([earbuds], connectedAddresses: [earbuds.address])
            let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
            if sleeping { devices.systemWillSleep() }
            else { devices.stop() }
            let session = controller.simulatedControlSession
            let generation = devices.discoveryGeneration

            devices.refreshPairedInventory(authorization: .denied)

            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(devices.discoveryGeneration, generation)
            XCTAssertFalse(controller.isBluetoothAccessDenied)
            XCTAssertNil(devices.discoveryTimer)
        }
    }

    func testManagedControllersShareDiscoveryInventoryWithoutRepeatingScans() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.setReconnectAutomatically(false)
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [], pairedDeviceInventory: [])
        var scans = 0
        for controller in devices.controllers {
            XCTAssertNotNil(controller.pairedDeviceInventory)
            XCTAssertTrue(controller.pairedDevices(automatically: true, discover: { scans += 1; return [] }).isEmpty)
            XCTAssertFalse(controller.simulatedReconnectAutomatically)
        }
        XCTAssertEqual(scans, 0)
        devices.systemWillSleep()
        XCTAssertTrue(devices.controllers.allSatisfy { $0.pairedDeviceInventory == nil })
    }

    func testManualAndStandaloneDiscoveryReadFreshInventory() {
        let controller = SonyHeadphonesController(displayOnly: true)
        var scans = 0
        XCTAssertTrue(controller.pairedDevices(automatically: true, discover: { scans += 1; return [] }).isEmpty)
        XCTAssertEqual(scans, 1)
        controller.pairedDeviceInventory = []
        XCTAssertTrue(controller.pairedDevices(automatically: false, discover: { scans += 1; return [] }).isEmpty)
        XCTAssertEqual(scans, 2)
        XCTAssertTrue(controller.pairedDevices(automatically: true, discover: { scans += 1; return [] }).isEmpty)
        XCTAssertEqual(scans, 2)
    }

    func testDisconnectedPollingCleansPendingHandshakeOnceAndDoesNotPublishUnchangedState() async throws {
        for reconnect in [false, true] {
            let devices = makeCoordinator()
            defer { devices.stop() }
            devices.isRunning = true
            devices.setReconnectAutomatically(reconnect)
            devices.reconcileDiscoveredDevices([earbuds], connectedAddresses: [earbuds.address])
            let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
            controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            XCTAssertNotNil(controller.simulatedPendingFrame)
            XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
            let openingSession = controller.simulatedControlSession

            controller.simulateAutomaticRefresh(deviceConnected: false)
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertGreaterThan(controller.simulatedControlSession, openingSession)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
            for _ in 0..<4 { await Task.yield() }

            let disconnectedSession = controller.simulatedControlSession
            var controllerPublications = 0
            var coordinatorPublications = 0
            let controllerObservation = controller.objectWillChange.sink { controllerPublications += 1 }
            let coordinatorObservation = devices.objectWillChange.sink { coordinatorPublications += 1 }
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(controller.simulatedControlSession, disconnectedSession)
            XCTAssertEqual(controllerPublications, 0)
            XCTAssertEqual(coordinatorPublications, 0)
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertNil(controller.simulatedPendingFrame)
            controllerObservation.cancel()
            coordinatorObservation.cancel()
        }
    }

    func testDisconnectedPollingPreservesPendingManualTransportConnections() throws {
        for bluetoothLE in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
            controller.setReconnectAutomatically(false)
            if bluetoothLE {
                XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: false, classicConnected: false))
            } else {
                XCTAssertNotNil(controller.simulateClassicConnection())
            }
            let openingSession = controller.simulatedControlSession
            var publications = 0
            let observation = controller.objectWillChange.sink { publications += 1 }
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            XCTAssertEqual(controller.simulatedControlSession, openingSession)
            XCTAssertEqual(controller.linkState, .opening)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(publications, 0)
            observation.cancel()
        }
    }

    func testDiscoveryStartsPinnedControllersWithSharedPreferenceAndRetainsActiveRecovery() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.setReconnectAutomatically(false)
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        let first = try XCTUnwrap(devices.controller(for: earbuds.address))
        let second = try XCTUnwrap(devices.controller(for: headphones.address))
        XCTAssertFalse(first.simulatedReconnectAutomatically)
        XCTAssertFalse(second.simulatedReconnectAutomatically)
        devices.select(address: earbuds.address)
        first.setConnectionMode(.lowLatency)
        first.simulateControlLoss()
        XCTAssertEqual(first.connectionTransition?.phase, .recovering)
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        XCTAssertEqual(devices.controllers.count, 2)
        XCTAssertTrue(devices.selectedController === first)
        XCTAssertEqual(first.connectionTransition?.phase, .recovering)
        devices.setReconnectAutomatically(true)
        XCTAssertTrue(first.simulatedReconnectAutomatically)
        XCTAssertTrue(second.simulatedReconnectAutomatically)
    }

    func testSleepAndStopInvalidateEveryRetainedControllerAndBlockNewDiscovery() throws {
        let devices = makeCoordinator()
        devices.isRunning = true
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        let first = try XCTUnwrap(devices.controller(for: earbuds.address))
        let second = try XCTUnwrap(devices.controller(for: headphones.address))
        devices.select(address: headphones.address)
        XCTAssertTrue(first.beginEarTipFit())
        second.setDSEE(.off)
        XCTAssertNotNil(second.pendingChanges[.dsee])
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        let sessions = devices.controllers.map(\.simulatedControlSession)
        devices.systemWillSleep()
        XCTAssertEqual(first.earTipFitTransition?.phase, .finished)
        XCTAssertFalse(first.isRunningHeadphoneTest)
        XCTAssertTrue(second.pendingChanges.isEmpty)
        for (index, controller) in devices.controllers.enumerated() {
            XCTAssertGreaterThan(controller.simulatedControlSession, sessions[index])
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertNil(controller.simulatedPendingFrame)
        }
        let third = try XCTUnwrap(SonyConnectedDevice(address: "02:00:00:00:00:03", name: "WF-1000XM4", model: .wfXM4))
        devices.reconcileDiscoveredDevices([third], connectedAddresses: [third.address])
        XCTAssertNil(devices.controller(for: third.address))
        let writes = devices.controllers.map(\.simulatedTransmittedFrames)
        devices.stop()
        devices.systemDidWake()
        XCTAssertFalse(devices.isRunning)
        XCTAssertEqual(devices.controllers.map(\.simulatedTransmittedFrames), writes)
    }

    func testDisplayOnlyControllerDoesNotInitializeBluetooth() async {
        let unexpectedInitialization = expectation(description: "Display-only controller stays inert")
        unexpectedInitialization.isInverted = true
        let controller = SonyHeadphonesController(displayOnly: true)
        controller.start(authorization: { .denied }, initializeBluetooth: { unexpectedInitialization.fulfill() })
        await fulfillment(of: [unexpectedInitialization], timeout: 0.05)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertTrue(controller.address.isEmpty)
        controller.reportBluetoothAuthorization(.denied)
        XCTAssertEqual(controller.statusText, String(localized: "Bluetooth access is not allowed."))
        controller.reportBluetoothAuthorization(.allowedAlways)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testForgottenIdleDeviceStopsAndRestartsOnlyWhenRediscovered() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        let first = try XCTUnwrap(devices.controller(for: earbuds.address))
        first.simulateControlLoss()
        let session = first.simulatedControlSession
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        XCTAssertGreaterThan(first.simulatedControlSession, session)
        XCTAssertEqual(first.linkState, .disconnected)
        XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
        let stoppedSession = first.simulatedControlSession
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        XCTAssertEqual(first.simulatedControlSession, stoppedSession)
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        XCTAssertFalse(devices.retiredControllerAddresses.contains(earbuds.address))
        XCTAssertTrue(devices.controller(for: earbuds.address) === first)
        XCTAssertEqual(first.simulatedPendingFrame?.payload, [0, 0])
    }

    func testLiveClassicSessionSurvivesEitherBudLossAndDiscoveryInventoryGap() throws {
        for connections: [UInt8] in [[0, 1], [1, 0]] {
            let devices = makeCoordinator()
            defer { devices.stop() }
            devices.isRunning = true
            devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
            devices.select(address: earbuds.address)
            let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
            let session = controller.simulatedControlSession
            controller.simulateProtocolMessage([0x15, 0x01] + connections)
            controller.simulateAutomaticRefresh()
            devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
            XCTAssertTrue(controller.hasOpenControlTransport)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertEqual(controller.audioFeatures.leftConnected, connections[0] == 1)
            XCTAssertEqual(controller.audioFeatures.rightConnected, connections[1] == 1)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(devices.selectedController === controller)
            XCTAssertTrue(devices.connectedDevices.contains { $0.address == earbuds.address })
            XCTAssertFalse(devices.retiredControllerAddresses.contains(earbuds.address))

            controller.simulateControlLoss(deviceConnected: false)
            devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
            XCTAssertFalse(controller.hasOpenControlTransport)
            XCTAssertFalse(controller.isReady)
            XCTAssertFalse(devices.connectedDevices.contains { $0.address == earbuds.address })
            XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
            XCTAssertEqual(devices.selectedAddress, headphones.address)
        }
    }

    func testStopRejectsDelayedBluetoothInitialization() async throws {
        let initializationStarted = expectation(description: "Injected initialization started")
        let initializationReleased = expectation(description: "Injected initialization released")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let controller = SonyHeadphonesController(startAutomatically: false)
        controller.start(authorization: { .denied }, initializeBluetooth: {
            initializationStarted.fulfill()
            release.wait()
            initializationReleased.fulfill()
        })
        await fulfillment(of: [initializationStarted], timeout: 1)
        controller.stop()
        release.signal()
        await fulfillment(of: [initializationReleased], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testDiscoveryGapPreservesManualBLEAttemptButRetiresAutomaticWait() throws {
        for automatic in [false, true] {
            let devices = makeCoordinator()
            defer { devices.stop() }
            devices.isRunning = true
            let other = try XCTUnwrap(SonyConnectedDevice(address: headphones.address, name: earbuds.name, model: earbuds.model))
            devices.reconcileDiscoveredDevices([earbuds, other], connectedAddresses: [earbuds.address, other.address])
            let first = try XCTUnwrap(devices.controller(for: earbuds.address))
            let second = try XCTUnwrap(devices.controller(for: other.address))
            devices.select(address: earbuds.address)
            first.simulateBLEReconnectWait(automatic: automatic, priorBluetoothLE: automatic, classicConnected: false)
            let session = first.simulatedControlSession
            let writes = first.simulatedTransmittedFrames
            let otherSession = second.simulatedControlSession

            devices.reconcileDiscoveredDevices([other], connectedAddresses: [other.address])
            XCTAssertEqual(first.simulatedTransmittedFrames, writes)
            XCTAssertEqual(second.simulatedControlSession, otherSession)
            XCTAssertTrue(second.isReady)
            if automatic {
                XCTAssertGreaterThan(first.simulatedControlSession, session)
                XCTAssertEqual(first.linkState, .disconnected)
                XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
                XCTAssertTrue(devices.selectedController === second)
            } else {
                XCTAssertEqual(first.simulatedControlSession, session)
                XCTAssertEqual(first.linkState, .opening)
                XCTAssertFalse(devices.retiredControllerAddresses.contains(earbuds.address))
                XCTAssertTrue(devices.selectedController === first)
                first.simulateControlLoss()
                devices.reconcileDiscoveredDevices([other], connectedAddresses: [other.address])
                XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
                XCTAssertTrue(devices.selectedController === second)
            }
        }
    }

    func testInventoryRefreshUsesCachedAuthorizationInsteadOfAskingTCC() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.reconcileDiscoveredDevices([earbuds], connectedAddresses: [earbuds.address])
        let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
        devices.cachedBluetoothAuthorization = .denied

        devices.refreshPairedInventory()

        XCTAssertTrue(controller.isBluetoothAccessDenied)
        XCTAssertEqual(SonyDeviceCoordinator.inventoryBackupInterval, 30)
    }

    func testIdleDisconnectedControllerCanPausePollingAndConnectedOneCannot() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.reconcileDiscoveredDevices([earbuds], connectedAddresses: [earbuds.address])
        let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
        XCTAssertFalse(controller.canPausePolling)
        controller.simulateControlLoss()
        // Una pausa solicitada sin temporizador en marcha no cambia nada y se puede revertir.
        controller.setPollingActive(false)
        XCTAssertFalse(controller.isPollingActive)
        controller.setPollingActive(true)
        XCTAssertFalse(controller.isPollingActive)
    }

    private func makeCoordinator() -> SonyDeviceCoordinator {
        SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(displayOnly: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true,
                                                      pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address)
            return controller
        }
    }

    private var earbuds: SonyConnectedDevice {
        SonyConnectedDevice(address: "02:00:00:00:00:01", name: "WF-1000XM5", model: .wfXM5)!
    }

    private var headphones: SonyConnectedDevice {
        SonyConnectedDevice(address: "02:00:00:00:00:02", name: "WH-1000XM5", model: .whXM5)!
    }
}
