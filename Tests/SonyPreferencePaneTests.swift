import XCTest
@testable import Acouplet

@MainActor
@available(macOS 27.0, *)
final class SonyPreferencePaneTests: XCTestCase {
    func testAppRequirementUsesThePaneTeamAndKeepsTheOriginalTeamOtherwise() {
        let original = "anchor apple generic and identifier \"dev.baglayan.Acouplet\" and certificate leaf[subject.OU] = \"5743Y47SC7\""
        XCTAssertEqual(SonyPreferencePaneWire.appRequirement(team: nil), original)
        XCTAssertEqual(SonyPreferencePaneWire.appRequirement(team: "5743Y47SC7"), original)
        XCTAssertEqual(SonyPreferencePaneWire.appRequirement(team: "5LHT3P9C4T"),
                       "anchor apple generic and identifier \"dev.baglayan.Acouplet\" and certificate leaf[subject.OU] = \"5LHT3P9C4T\"")
        for invalid in ["", "5lht3p9c4t", "5LHT3P9C4", "5LHT3P9C4T\" or anchor apple", "5LHT3P9C4T\n"] {
            XCTAssertEqual(SonyPreferencePaneWire.appRequirement(team: invalid), original, invalid)
        }
    }

    func testCommandsRejectStaleSessionServerAndDuplicateWithoutWriting() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let server = SonyPreferencePaneServer(devices: SonyDeviceCoordinator(controller: controller), allowsCommands: true)
        try server.start()
        defer { server.stop() }
        let initial = await server.reply(to: .init(version: SonyPreferencePaneWire.version, id: UUID(), action: .snapshot))
        let snapshot = try XCTUnwrap(initial.snapshot)
        let device = try XCTUnwrap(snapshot.devices.first)
        XCTAssertTrue(device.isReady)
        let baseline = controller.simulatedTransmittedFrames
        var request = SonyPreferencePaneRequest(version: SonyPreferencePaneWire.version, id: UUID(), action: .noise,
            serverID: UUID(), address: device.address, session: device.session, mode: "ambient")
        var response = await server.reply(to: request)
        XCTAssertNotNil(response.error)
        request.serverID = snapshot.serverID
        request.session = device.session + 1
        response = await server.reply(to: request)
        XCTAssertNotNil(response.error)
        request.session = device.session
        request.address = "02:00:00:00:00:99"
        response = await server.reply(to: request)
        XCTAssertNotNil(response.error)
        request.address = device.address
        response = await server.reply(to: request)
        XCTAssertNil(response.error)
        response = await server.reply(to: request)
        XCTAssertEqual(response.error, "This command has already been submitted.")
        XCTAssertEqual(controller.simulatedTransmittedFrames, baseline)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testUnverifiedHostIntegrationRemainsReadOnlyAndStoppedServerRejects() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let server = SonyPreferencePaneServer(devices: SonyDeviceCoordinator(controller: controller))
        try server.start()
        defer { server.stop() }
        let initial = await server.reply(to: .init(version: SonyPreferencePaneWire.version, id: UUID(), action: .snapshot))
        let snapshot = try XCTUnwrap(initial.snapshot)
        let device = try XCTUnwrap(snapshot.devices.first)
        XCTAssertFalse(try XCTUnwrap(device.noise).canSet)
        XCTAssertFalse(try XCTUnwrap(device.speak).canSet)
        let baseline = controller.simulatedTransmittedFrames
        let request = SonyPreferencePaneRequest(version: SonyPreferencePaneWire.version, id: UUID(), action: .speak,
            serverID: snapshot.serverID, address: device.address, session: device.session, enabled: true)
        let response = await server.reply(to: request)
        XCTAssertEqual(response.error, "This connection currently shows headphone settings only.")
        server.stop()
        let stopped = await server.reply(to: request)
        XCTAssertNotNil(stopped.error)
        XCTAssertEqual(controller.simulatedTransmittedFrames, baseline)
    }
    func testSnapshotsExposeOnlyNegotiatedFeaturesAndRoundTrip() async throws {
        for model in [SonyDeviceModel.wfXM5, .wfXM6, .whXM3, .whCH720N] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateGalleryDevice(model: model)
            let server = SonyPreferencePaneServer(devices: SonyDeviceCoordinator(controller: controller))
            try server.start()
            let reply = await server.reply(to: .init(version: SonyPreferencePaneWire.version, id: UUID(), action: .snapshot))
            server.stop()
            let snapshot = try XCTUnwrap(reply.snapshot)
            let device = try XCTUnwrap(snapshot.devices.first)
            XCTAssertEqual(device.modelName, model.name)
            XCTAssertEqual(device.equalizer?.bands.count, controller.equalizer.flatSettings?.layout.count)
            XCTAssertEqual(device.equalizer?.values, controller.equalizer.settings?.values)
            XCTAssertEqual(device.dseeTitle, controller.dseeType?.title)
            XCTAssertEqual(device.touchAssignments.count, controller.touchAssignments.keys?.count ?? 0)
            XCTAssertFalse(device.systemFeatures.contains { $0.canSet })
            XCTAssertFalse(device.equalizer?.canEdit == true)
            XCTAssertFalse(device.volume?.canSet == true)
            XCTAssertEqual(device.systemFeatures.contains { $0.id == "15" }, controller.systemFeatureState(.headGestures) != nil)
            XCTAssertEqual(device.batteryCare != nil, controller.powerFeatures.batteryCare != nil)
            XCTAssertEqual(try JSONDecoder().decode(SonyPreferencePaneSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        }
    }

    func testChangedSettingTargetsExactSameModelDeviceAndWaitsForConfirmation() async throws {
        let first = makeController(address: "02:00:00:00:00:01")
        let second = makeController(address: "02:00:00:00:00:02")
        let coordinator = SonyDeviceCoordinator(fallbackController: first) { device in
            device.address == first.address ? first : second
        }
        coordinator.reconcileConnectedDevices([
            SonyConnectedDevice(address: first.address, name: first.deviceName, model: .wfXM5)!,
            SonyConnectedDevice(address: second.address, name: second.deviceName, model: .wfXM5)!,
        ])
        coordinator.select(address: first.address)
        let server = SonyPreferencePaneServer(devices: coordinator, allowsCommands: true)
        try server.start()
        defer { server.stop(); first.simulateControlLoss(); second.simulateControlLoss() }
        var request = try await self.request(.systemFeature, server: server, address: second.address)
        request.feature = SonySystemFeature.pauseOnRemoval.rawValue
        request.enabled = false
        let action = await begin(request, server: server)
        XCTAssertEqual(second.simulatedPendingFrame?.payload, [0xF8, 1, 1])
        XCTAssertTrue(first.simulatedTransmittedFrames.isEmpty)
        XCTAssertEqual(second.systemFeatureState(.pauseOnRemoval)?.enabled, true)
        acknowledgeAll(second)
        XCTAssertNotNil(second.pendingChanges[.system(.pauseOnRemoval)])
        deliver([0xF9, 0x0F, 0], to: second)
        XCTAssertNotNil(second.pendingChanges[.system(.pauseOnRemoval)])
        deliver([0xF9, 1, 1], to: second)
        let reply = await action.value
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.snapshot?.devices.first { $0.address == second.address }?.systemFeatures.first { $0.id == "1" }?.enabled, false)
        XCTAssertEqual(first.systemFeatureState(.pauseOnRemoval)?.enabled, true)
        XCTAssertTrue(first.simulatedTransmittedFrames.isEmpty)
    }

    func testSettingTimeoutAndSessionLossNeverReportApplied() async throws {
        for disconnect in [false, true] {
            let controller = makeController()
            let server = SonyPreferencePaneServer(devices: SonyDeviceCoordinator(controller: controller), allowsCommands: true)
            try server.start()
            var request = try await self.request(.dsee, server: server, address: controller.address)
            request.option = "0"
            let action = await begin(request, server: server)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 1, 0])
            acknowledgeAll(controller)
            if disconnect { controller.simulateControlLoss() }
            else { controller.simulateSettingTimeout(.dsee) }
            let reply = await action.value
            XCTAssertNotNil(reply.error)
            if !disconnect {
                XCTAssertEqual(controller.dseeMode, .automatic)
                XCTAssertFalse(try XCTUnwrap(reply.snapshot?.devices.first?.dsee).canSet)
                var retry = try await self.request(.dsee, server: server, address: controller.address)
                retry.option = "1"
                let retryReply = await server.reply(to: retry)
                XCTAssertNotNil(retryReply.error)
            }
            server.stop()
            controller.simulateControlLoss()
        }
    }

    func testInvalidCurveUnsupportedChoiceAndChangedSourceCannotWrite() async throws {
        let controller = makeController()
        let server = SonyPreferencePaneServer(devices: SonyDeviceCoordinator(controller: controller), allowsCommands: true)
        try server.start()
        defer { server.stop() }
        let baseline = controller.simulatedTransmittedFrames
        var curve = try await self.request(.equalizer, server: server, address: controller.address)
        curve.bandIDs = ["not-the-negotiated-layout"]
        curve.levelSteps = 21
        curve.values = [0]
        let curveReply = await server.reply(to: curve)
        XCTAssertNotNil(curveReply.error)
        var option = try await self.request(.automaticPowerOff, server: server, address: controller.address)
        option.option = "254"
        let optionReply = await server.reply(to: option)
        XCTAssertNotNil(optionReply.error)
        var volume = try await self.request(.volume, server: server, address: controller.address)
        volume.volume = 20
        volume.sourceAddress = "02:00:00:00:00:99"
        let volumeReply = await server.reply(to: volume)
        XCTAssertNotNil(volumeReply.error)
        XCTAssertEqual(controller.simulatedTransmittedFrames, baseline)
        do {
            try await controller.performConfirmedSettingChange(.dsee) {}
            XCTFail("A declined setter must not complete successfully.")
        } catch { XCTAssertEqual(error.localizedDescription, "The setting is no longer available.") }
    }

    func testCompleteEqualizerCurveNeedsConfirmedMatchingLayoutAndValues() async throws {
        let controller = makeController()
        let server = SonyPreferencePaneServer(devices: SonyDeviceCoordinator(controller: controller), allowsCommands: true)
        try server.start()
        defer { server.stop(); controller.simulateControlLoss() }
        let snapshot = await server.reply(to: .init(version: SonyPreferencePaneWire.version, id: UUID(), action: .snapshot))
        let equalizer = try XCTUnwrap(snapshot.snapshot?.devices.first?.equalizer)
        var request = try await self.request(.equalizer, server: server, address: controller.address)
        request.bandIDs = equalizer.bands.map(\.id)
        request.levelSteps = equalizer.levelSteps
        request.values = [1, 0, 0, 0, 0, 0]
        let action = await begin(request, server: server)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(payload, [0x58, 0, 0xA0, 6, 11, 10, 10, 10, 10, 10])
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        deliver([0x59, 0, 0xA0, 6, 10, 10, 10, 10, 10, 10], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        deliver([0x59] + payload.dropFirst(), to: controller)
        let reply = await action.value
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.snapshot?.devices.first?.equalizer?.values, request.values)
    }

    private func makeController(address: String = "02:00:00:00:00:01") -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: address)
        return controller
    }

    private func request(_ action: SonyPreferencePaneRequest.Action, server: SonyPreferencePaneServer,
                         address: String) async throws -> SonyPreferencePaneRequest {
        let reply = await server.reply(to: .init(version: SonyPreferencePaneWire.version, id: UUID(), action: .snapshot))
        let snapshot = try XCTUnwrap(reply.snapshot)
        let device = try XCTUnwrap(snapshot.devices.first { $0.address == address })
        return .init(version: SonyPreferencePaneWire.version, id: UUID(), action: action,
                     serverID: snapshot.serverID, address: address, session: device.session)
    }

    private func begin(_ request: SonyPreferencePaneRequest, server: SonyPreferencePaneServer) async -> Task<SonyPreferencePaneReply, Never> {
        let started = expectation(description: "Pane command started")
        let task = Task { @MainActor in
            started.fulfill()
            return await server.reply(to: request)
        }
        await fulfillment(of: [started], timeout: 1)
        return task
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }

}
