import XCTest
@testable import Acouplet

final class SonySourceControllerTests: XCTestCase {
    @MainActor
    func testAudioSourceNoticesIgnoreInitialRepeatedAndStaleInventory() {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        var changes: [SonyMultipointDevice] = []
        let observer = controller.audioSourceChanges.sink { changes.append($0) }
        defer { observer.cancel() }
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertTrue(changes.isEmpty)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        deliver([0x39, 2, 1], to: controller)
        XCTAssertEqual(changes.count, 1)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone", "MacBook Pro"])
        controller.simulateControlLoss()
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.count, 2)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.count, 2)
    }

    @MainActor
    func testUnsolicitedAudioSourceNoticeDuringUnrelatedConnectionChanges() {
        for multipointChange in [false, true] {
            let controller = preparedController()
            defer { controller.simulateControlLoss() }
            var changes: [SonyMultipointDevice] = []
            let observer = controller.audioSourceChanges.sink { changes.append($0) }
            defer { observer.cancel() }
            deliver(inventory(command: 0x39, selected: 1), to: controller)
            if multipointChange {
                controller.setMultipointEnabled(false)
                XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
            } else {
                controller.setConnectionMode(.stableConnection)
                XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
            }
            deliver(inventory(command: 0x39, selected: 2), to: controller)
            XCTAssertEqual(changes.map(\.name), ["Phone"])
        }
    }

    @MainActor
    func testReusedHandshakeResetsAudioSourceNoticeBaseline() {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        var changes: [SonyMultipointDevice] = []
        let observer = controller.audioSourceChanges.sink { changes.append($0) }
        defer { observer.cancel() }
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        controller.simulateMultipointTimeout()
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 0], type: 0x0C, to: controller)
        XCTAssertTrue(controller.canCheckMultipointChange)
        let session = controller.notificationSession
        controller.checkMultipointChange()
        XCTAssertGreaterThan(controller.notificationSession, session)
        XCTAssertEqual(controller.linkState, .handshaking)
        acknowledgeAll(controller)
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], type: 0x0C, to: controller)
        acknowledgeAll(controller)
        deliver([0x07, 0, 4, 0x31, 0, 0x32, 0, 0x20, 0, 0x14, 0], type: 0x0C, to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 4] + Array("02:53:4F:4E:59:01ABCDEF12".utf8), type: 0x0C, to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        deliver([0x07, 0, 3, 0x31, 0, 0x32, 0, 0x20, 0], to: controller)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone", "Phone"])
    }

    @MainActor
    func testSelectionReleasesKeepingAndWaitsForMatchingResultAndOwnedReadback() throws {
        let controller = preparedController()
        var changes: [SonyMultipointDevice] = []
        let observer = controller.audioSourceChanges.sink { changes.append($0) }
        defer { observer.cancel() }
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.setSourceKeeping(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x38, 0x01, 0])
        acknowledgeAll(controller)
        deliver([0x37, 0x01, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingKeeping)
        deliver([0x39, 0x01, 0, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x38, 0x01, 1])
        XCTAssertNotNil(controller.connectionModeUnavailableReason(.stableConnection))
        deliver([0x39, 0x01, 1, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .queuedSelection)
        deliver([0x3D, 0x01, 0] + Array(phone.address.utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .queuedSelection)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        deliver([0x3D, 0x01, 0] + Array("02:00:00:00:00:01".utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        deliver([0x3D, 0x01, 0] + Array(phone.address.utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        XCTAssertTrue(changes.isEmpty)
        deliver(inventory(command: 0x37, selected: 2), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        XCTAssertEqual(controller.multipoint.selectedSource?.address, phone.address)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        controller.simulateControlLoss()
    }

    @MainActor
    func testEnablingKeepingKeepsTheFieldsLDACBindingDependsOn() throws {
        let controller = preparedController()
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        let source = controller.multipoint.selectedSource?.address
        let session = controller.notificationSession
        let range = controller.playback.musicVolumeRange
        XCTAssertNotNil(source)
        controller.setSourceKeeping(true)
        acknowledgeAll(controller)
        deliver([0x37, 0x01, 0], to: controller)
        XCTAssertTrue(controller.isChangingSourceKeepingOnly)
        deliver([0x39, 0x01, 0, 0], to: controller)
        XCTAssertFalse(controller.isChangingSourceKeepingOnly)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        XCTAssertEqual(controller.multipoint.selectedSource?.address, source)
        XCTAssertEqual(controller.notificationSession, session)
        XCTAssertEqual(controller.playback.musicVolumeRange, range)
        controller.simulateControlLoss()
    }

    @MainActor
    func testEarlierInventoryReadCannotBecomeSwitchConfirmation() throws {
        let controller = preparedController()
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.refreshDevices()
        acknowledgeAll(controller)
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        controller.selectAudioSource(phone)
        XCTAssertNil(controller.sourceTransition)
        controller.refreshDevices()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x36, 2] }.count, 1)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        acknowledgeAll(controller)
        deliver([0x3D, 1, 0] + Array(phone.address.utf8), to: controller)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testQueueDelayDoesNotTimeoutAndControlLossNeverReplaysMutation() {
        let controller = preparedController()
        controller.setDSEE(.off)
        controller.setSourceKeeping(true)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        controller.simulateSourceTimeout()
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingKeeping)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertNil(controller.simulatedPendingFrame)
        let writes = controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x38 }.count
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x38 }.count, writes)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateControlLoss()
    }

    @MainActor
    func testQueuedSourceInvalidationKeepsControlsAndTransmitsFollowingQueuedCommand() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        let session = controller.simulatedControlSession
        controller.setDSEE(.off)
        let previous = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        controller.refreshEqualizer()
        deliver([0x39, 2, 2] + entry(address: "02:00:00:00:00:01", id: 1, name: "MacBook Pro")
                + entry(address: phone.address, id: 0, name: "Phone") + [1], to: controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - previous.sequence, payload: []))
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertFalse(controller.simulatedSourceTimeoutPending)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.prefix(2) == [0x3C, 1] })
        let next = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(next.payload, controller.equalizer.parameterQueryPayload)
        XCTAssertEqual(next.sequence, 1 - previous.sequence)
        acknowledgeAll(controller)
        controller.simulateSourceTimeout()
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertFalse(controller.simulatedSourceTimeoutPending)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    @MainActor
    func testUnownedCapabilitiesCannotStealReadbackOrCancelQueuedWrites() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.selectAudioSource(phone)
        acknowledgeAll(controller)
        let functions = controller.supportedFunctions2.sorted()
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        deliver([0x3D, 1, 0] + Array(phone.address.utf8), to: controller)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x37, selected: 2), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        controller.setDSEE(.off)
        controller.setSourceKeeping(true)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        let session = controller.simulatedControlSession
        let pending = controller.simulatedPendingFrame
        deliver([0x07, 0, 2, 0x31, 0, 0x32, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.supportedFunctions2.sorted(), functions)
        XCTAssertEqual(controller.simulatedPendingFrame, pending)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x38, 1, 0] })
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingKeeping)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x38, 1, 0] })
    }

    @MainActor
    func testCallFailureAndMalformedInventoryDoNotSelectOrRetry() throws {
        let controller = preparedController()
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.selectAudioSource(phone)
        acknowledgeAll(controller)
        deliver([0x3D, 1, 2] + Array(phone.address.utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertEqual(controller.sourceTransition?.failureMessage, String(localized: "Finish the phone call before changing the audio source."))
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x39, 2, 1], to: controller)
        XCTAssertTrue(controller.multipoint.inventoryIsStale)
        let request = controller.sourceTransition?.requestID
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.requestID, request)
        controller.simulateControlLoss()
    }

    @MainActor
    private func preparedController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        var count = 0
        while let frame = controller.simulatedPendingFrame, count < 50 {
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
            count += 1
        }
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0E, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    private func inventory(command: UInt8, selected: UInt8) -> [UInt8] {
        [command, 2, 2] + entry(address: "02:00:00:00:00:01", id: 1, name: "MacBook Pro")
            + entry(address: "02:00:00:00:00:02", id: 2, name: "Phone") + [selected]
    }

    private func entry(address: String, id: UInt8, name: String) -> [UInt8] {
        Array(address.utf8) + [id, 0x2A, 0x41, 4, UInt8(name.utf8.count)] + Array(name.utf8)
    }
}
