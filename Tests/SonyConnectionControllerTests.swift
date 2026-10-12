import XCTest
import IOBluetooth
@testable import Acouplet

final class SonyConnectionControllerTests: XCTestCase {
    @MainActor
    func testNoiseShortcutUsesOffAndAmbientWhenANCIsNotAdvertised() throws {
        for (function, inquiry): (UInt8, UInt8) in [(0x66, 0x21), (0x67, 0x22)] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
            controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            acknowledgeAll(controller)
            deliver([0x07, 0, 1, function, 0], to: controller)
            acknowledgeAll(controller)
            deliver([0x67, inquiry, 1, 0, 0, 10], to: controller)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.availableNoiseModes, [.off, .ambient])
            controller.toggleNoiseControl()
            let ambient = try XCTUnwrap(controller.pendingChanges[.noiseControl])
            XCTAssertEqual(ambient, [inquiry, 1, 1, 0, 10])
            controller.toggleNoiseControl()
            acknowledgeAll(controller)
            deliver([0x69] + ambient, to: controller)
            XCTAssertEqual(controller.pendingChanges[.noiseControl], [inquiry, 1, 0, 0, 10])
        }
    }

    @MainActor
    func testDiagnosticsOmitRenamedDevicesAndIdentitiesWhilePreservingControlState() {
        let identifier = UUID()
        let address = "02:00:00:00:59:01"
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "Private renamed earbuds", peripheralIdentifier: identifier,
            simulatedAddress: address, galleryModel: .wfXM5)
        let sourceName = "Private source computer"
        let sourceAddress = "02:00:00:00:59:02"
        let nameBytes = Array(sourceName.utf8)
        controller.simulateProtocolMessage([0x37, 0x02, 1] + Array(sourceAddress.utf8) +
            [1, 0x2A, 0x41, 0x0C, UInt8(nameBytes.count)] + nameBytes + [1], type: 0x0E)
        controller.simulateProtocolMessage([0x05, 0x02, 5] + Array("2.5.1".utf8))
        XCTAssertEqual(controller.firmwareVersion, "2.5.1")
        XCTAssertEqual(controller.multipoint.selectedSource?.name, sourceName)
        let report = controller.diagnosticReport
        for privateValue in [controller.deviceName, address, identifier.uuidString, sourceName, sourceAddress, controller.bluetoothLEHash!] {
            XCTAssertFalse(report.contains(privateValue))
        }
        XCTAssertTrue(report.contains("Device model: WF-1000XM5"))
        XCTAssertTrue(report.contains("Selected headphone source connection: 1"))
        XCTAssertTrue(report.contains("Sony control session: \(controller.simulatedControlSession)"))
        XCTAssertTrue(report.contains("Firmware: \(controller.firmwareVersion!)"))
        XCTAssertTrue(report.contains("Capabilities:"))
        controller.connectBluetoothLE()
        XCTAssertTrue(controller.usesBluetoothLE)
        XCTAssertEqual(controller.linkState, .opening)
        let privateIssue = "Could not connect to Private renamed earbuds (\(identifier.uuidString), \(address))"
        controller.simulateBLEDisconnect(nil, error: NSError(domain: "CBErrorDomain", code: 6,
            userInfo: [NSLocalizedDescriptionKey: privateIssue]))
        XCTAssertEqual(controller.bluetoothLEError, String(localized: "Could not connect to the headphone controls. Try again."))
        let failedReport = controller.diagnosticReport
        for privateValue in ["Private renamed earbuds", identifier.uuidString, address, privateIssue] {
            XCTAssertFalse(failedReport.contains(privateValue))
        }
        XCTAssertTrue(failedReport.contains("Sony control: CBErrorDomain (code 6)"))
        XCTAssertTrue(failedReport.contains("Last LE connection issue: CBErrorDomain (code 6)"))
        XCTAssertTrue(failedReport.contains("Last error: CBErrorDomain (code 6)"))
        controller.simulateDeviceConnection(named: "Private renamed earbuds", peripheralIdentifier: identifier,
            simulatedAddress: address, galleryModel: .wfXM5)
        controller.connectBluetoothLE()
        XCTAssertEqual(controller.linkState, .opening)
        let timeout = "The headphone connection timed out."
        controller.simulateBLEDisconnect(timeout)
        XCTAssertTrue(controller.diagnosticReport.contains("Sony control: \(timeout)"))
        XCTAssertTrue(controller.diagnosticReport.contains("Last LE connection issue: \(timeout)"))
        XCTAssertTrue(controller.diagnosticReport.contains("Last error: \(timeout)"))
    }

    @MainActor
    func testClassicOpenTimesOutWhileRetirementIsBlockedAndDoesNotOpenLater() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        controller.rfcommCloseCompletion.enter()
        controller.simulateSonyLink(to: device)
        XCTAssertEqual(controller.linkState, .opening)
        XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
        XCTAssertTrue(device.openedChannels.isEmpty)

        controller.simulateHandshakeTimeout()
        for _ in 0..<20 where controller.simulatedHandshakeTimeoutPending { await Task.yield() }
        controller.rfcommCloseCompletion.leave()
        let drained = expectation(description: "Expired open callback drained")
        controller.rfcommCloseCompletion.notify(queue: .main) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        guard case .failed = controller.linkState else { return XCTFail("Retirement must not leave controls opening indefinitely") }
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        XCTAssertTrue(device.openedChannels.isEmpty)

        controller.simulateSonyLink(to: device)
        XCTAssertEqual(device.openedChannels, [7])
        XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
    }

    @MainActor
    func testPausedClassicWriteKeepsMainQueueResponsiveAndTimesOut() async throws {
        let channel = DeferredRFCOMMChannel()
        let controller = await openClassicController(channel: channel)
        defer { channel.finishWrite(); controller.simulateControlLoss() }
        let write = try XCTUnwrap(channel.writes.first)
        XCTAssertEqual(SonyFrameCodec.decode(write)?.payload, [0x00, 0x00])
        XCTAssertEqual(controller.linkState, .handshaking)

        let responsive = expectation(description: "Main queue runs while native write is blocked")
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        controller.simulateClassicWriteTimeout()
        guard case .failed = controller.linkState else { return XCTFail("A stalled write must fail the control session") }
        await fulfillment(of: [channel.closeFinished], timeout: 2)
        XCTAssertEqual(channel.closeCount, 1)
        XCTAssertEqual(controller.rfcommCloseCompletion.wait(timeout: .now()), .timedOut)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        let state = controller.linkState
        channel.finishWrite()
        let cleanup = expectation(description: "Cleanup waits for the blocked write to return")
        controller.rfcommCloseCompletion.notify(queue: .main) { cleanup.fulfill() }
        await fulfillment(of: [cleanup], timeout: 2)
        XCTAssertEqual(controller.rfcommCloseCompletion.wait(timeout: .now()), .success)
        XCTAssertEqual(channel.closeCount, 1)
        XCTAssertEqual(controller.linkState, state)
        XCTAssertEqual(channel.writes.count, 1)
    }

    @MainActor
    func testClassicReplyBeforeWriteCompletionPreservesAcknowledgmentAndCommandOrder() async throws {
        let channel = DeferredRFCOMMChannel()
        let controller = await openClassicController(channel: channel)
        defer { channel.finishWrite(); controller.simulateControlLoss() }
        let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1, payload: [])
        let reply = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00])
        let received = acknowledgment + reply
        controller.classicChannelData(channel, data: received)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(channel.writes.count, 1)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])

        channel.finishWrite()
        await waitForWrites(channel, count: 2)
        channel.finishWrite()
        await waitForWrites(channel, count: 3)
        let frames = channel.writes.compactMap { SonyFrameCodec.decode($0) }
        XCTAssertEqual(frames.prefix(2).map(\.type), [0x0C, 0x01])
        XCTAssertEqual(frames.last?.payload, [0x04, 0x01])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x04, 0x01])
    }

    @MainActor
    func testClassicWriteCallbacksFromClosedSessionCannotAffectReplacement() async throws {
        let oldChannel = DeferredRFCOMMChannel()
        let releaseClose = DispatchSemaphore(value: 0)
        oldChannel.closeRelease = releaseClose
        let controller = await openClassicController(channel: oldChannel)
        defer { controller.simulateControlLoss() }
        controller.simulateControlLoss()

        let newChannel = DeferredRFCOMMChannel()
        defer { newChannel.finishWrite() }
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        device.channel = newChannel
        let opened = expectation(description: "Replacement opens after native write and close")
        device.onOpen = { opened.fulfill() }
        controller.simulateSonyLink(to: device)
        XCTAssertTrue(device.openedChannels.isEmpty)
        oldChannel.finishWrite(status: kIOReturnError)
        await fulfillment(of: [oldChannel.closeStarted], timeout: 2)
        XCTAssertTrue(device.openedChannels.isEmpty)
        releaseClose.signal()
        await fulfillment(of: [opened], timeout: 2)
        controller.classicChannelOpenComplete(newChannel, status: kIOReturnSuccess)
        await waitForWrites(newChannel, count: 1)
        let session = controller.simulatedControlSession

        controller.classicChannelWriteComplete(newChannel, identifier: nil, status: kIOReturnError)
        controller.classicChannelClosed(oldChannel)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(newChannel.closeCount, 0)
        XCTAssertEqual(newChannel.writes.count, 1)
        controller.simulateClassicWriteTimeout()
        guard case .failed = controller.linkState else { return XCTFail("The replacement write must retain its own timeout") }
        await fulfillment(of: [newChannel.closeFinished], timeout: 2)
        XCTAssertEqual(newChannel.closeCount, 1)
        XCTAssertEqual(controller.rfcommCloseCompletion.wait(timeout: .now()), .timedOut)
        newChannel.finishWrite()
        let cleanup = expectation(description: "Replacement cleanup waits for its blocked write")
        controller.rfcommCloseCompletion.notify(queue: .main) { cleanup.fulfill() }
        await fulfillment(of: [cleanup], timeout: 2)
        XCTAssertEqual(controller.rfcommCloseCompletion.wait(timeout: .now()), .success)
        XCTAssertEqual(newChannel.closeCount, 1)
    }

    @MainActor
    func testClassicChannelCloseReleasesUncompletedWriteWithoutClosingReplacement() async throws {
        var oldChannel: DeferredRFCOMMChannel? = DeferredRFCOMMChannel()
        weak var retainedChannel = oldChannel
        let releaseClose = DispatchSemaphore(value: 0)
        oldChannel?.closeRelease = releaseClose
        let started = try XCTUnwrap(oldChannel?.closeStarted)
        let controller = await openClassicController(channel: try XCTUnwrap(oldChannel))
        defer { controller.simulateControlLoss() }
        controller.simulateControlLoss()
        let newChannel = DeferredRFCOMMChannel()
        defer { newChannel.finishWrite() }
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        device.channel = newChannel
        let opened = expectation(description: "Replacement opens after native close")
        device.onOpen = { opened.fulfill() }
        controller.simulateSonyLink(to: device)
        XCTAssertTrue(device.openedChannels.isEmpty)
        oldChannel?.finishWrite()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(device.openedChannels.isEmpty)
        let session = controller.simulatedControlSession
        oldChannel = nil
        XCTAssertNotNil(retainedChannel)
        if let retainedChannel { controller.classicChannelClosed(retainedChannel) }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNotNil(retainedChannel)
        XCTAssertTrue(device.openedChannels.isEmpty)
        XCTAssertEqual(controller.simulatedControlSession, session)

        releaseClose.signal()
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.classicChannelOpenComplete(newChannel, status: kIOReturnSuccess)
        await waitForWrites(newChannel, count: 1)
        XCTAssertNil(retainedChannel)
        XCTAssertEqual(controller.simulatedControlSession, session + 1)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(newChannel.closeCount, 0)
        XCTAssertEqual(newChannel.writes.count, 1)
    }

    @MainActor
    func testClassicWriteFailureClosesSessionWithoutWaitingForCompletion() async {
        for (immediate, status) in [(true, kIOReturnError), (false, kIOReturnError), (true, kIOReturnAborted), (false, kIOReturnAborted)] {
            let channel = DeferredRFCOMMChannel()
            if immediate { channel.finishWrite(status: status) }
            let controller = await openClassicController(channel: channel)
            defer { channel.finishWrite(); controller.simulateControlLoss() }
            XCTAssertEqual(channel.writes.count, 1)
            if !immediate { channel.finishWrite(status: status) }
            await fulfillment(of: [channel.closeFinished], timeout: 2)
            guard case .failed = controller.linkState else { XCTFail("A failed write must close the control session"); continue }
            XCTAssertEqual(channel.closeCount, 1)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        }
    }

    @MainActor
    func testRevokedClassicVolumeDoesNotSendAndDrainsBufferedNotification() async throws {
        for buffered in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            let channel = DeferredRFCOMMChannel(blockOnlyFirst: true)
            controller.simulateClassicTransport(channel)
            defer { channel.finishWrite(); controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
            await waitForWrites(channel, count: 1)
            XCTAssertEqual(SonyFrameCodec.decode(try XCTUnwrap(channel.writes.first))?.type, 0x01)
            var current = true
            controller.setPlaybackVolume(20) { current }
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 20])
            controller.setPlaybackVolume(21)
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            if buffered {
                controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0xA9, 0x20, 13]))
                XCTAssertEqual(controller.playback.volume, 12)
            }
            current = false
            channel.finishWrite()
            await waitForClassicWritesToDrain(controller)
            XCTAssertFalse(channel.writes.compactMap(SonyFrameCodec.decode).contains { $0.payload.first == 0xA8 })
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(controller.playback.volume, buffered ? 13 : 12)
            controller.simulateClassicWriteTimeout()
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(channel.closeCount, 0)
        }
    }

    @MainActor
    func testCancelledConfirmedClassicVolumeAllowsNextVolumeOnSameConnection() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let channel = DeferredRFCOMMChannel(blockOnlyFirst: true)
        controller.simulateClassicTransport(channel)
        defer { channel.finishWrite(); controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
        await waitForWrites(channel, count: 1)
        let change = Task { @MainActor in
            try await controller.performConfirmedSettingChange(.playbackVolume) { controller.setPlaybackVolume(20) }
        }
        for _ in 0..<200 where controller.pendingChanges[.playbackVolume] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelled = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(cancelled.payload, [0xA8, 0x20, 20])
        change.cancel()
        do { try await change.value; XCTFail("Cancelled volume change completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        channel.finishWrite()
        await waitForClassicWritesToDrain(controller)
        XCTAssertFalse(channel.writes.compactMap(SonyFrameCodec.decode).contains { $0.payload == cancelled.payload })
        guard controller.pendingChanges[.playbackVolume] == nil else { return XCTFail("Cancelled volume remained pending") }
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.setPlaybackVolume(21)
        let next = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(next.payload, [0xA8, 0x20, 21])
        XCTAssertEqual(next.sequence, cancelled.sequence)
        await waitForClassicWritesToDrain(controller)
        controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x01, sequence: 1 - next.sequence, payload: [])
            + SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0xA9, 0x20, 21]))
        await waitForClassicWritesToDrain(controller)
        XCTAssertEqual(controller.playback.volume, 21)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.lastErrorMessage)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(channel.closeCount, 0)
    }

    @MainActor
    func testClassicCancellationCannotGiveFragmentedACKToNextPlaybackRead() async throws {
        for split in 1..<9 {
            for prefixBeforeEnqueue in [false, true] {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                controller.simulateDeviceConnection(named: "WF-1000XM5")
                let channel = DeferredRFCOMMChannel(blockOnlyFirst: true)
                controller.simulateClassicTransport(channel)
                defer { channel.finishWrite(); controller.simulateControlLoss() }
                controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
                await waitForWrites(channel, count: 1)
                let oldACK = SonyFrameCodec.encode(type: 0x01, sequence: 1, payload: [])
                if prefixBeforeEnqueue { controller.classicChannelData(channel, data: oldACK.prefix(split)) }
                var current = true
                controller.setPlaybackVolume(20) { current }
                let cancelled = try XCTUnwrap(controller.simulatedPendingFrame)
                XCTAssertTrue(controller.refreshMusicVolume())
                if !prefixBeforeEnqueue { controller.classicChannelData(channel, data: oldACK.prefix(split)) }
                current = false
                channel.finishWrite()
                await waitForClassicWritesToDrain(controller)
                let status = try XCTUnwrap(controller.simulatedPendingFrame)
                XCTAssertEqual(status.payload, [0xA2, 1])
                XCTAssertEqual(status.sequence, cancelled.sequence)
                XCTAssertFalse(channel.writes.compactMap(SonyFrameCodec.decode).contains { $0.payload == cancelled.payload })
                controller.classicChannelData(channel, data: oldACK.dropFirst(split))
                await waitForClassicWritesToDrain(controller)
                XCTAssertEqual(controller.simulatedPendingFrame, status)
                let valid = SonyFrameCodec.encode(type: 0x01, sequence: 1 - status.sequence, payload: [])
                controller.classicChannelData(channel, data: valid.prefix(split))
                XCTAssertEqual(controller.simulatedPendingFrame, status)
                controller.classicChannelData(channel, data: valid.dropFirst(split))
                await waitForClassicWritesToDrain(controller)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
            }
        }
    }

    @MainActor
    func testClassicOriginalACKSurvivesQueuedRetry() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let channel = DeferredRFCOMMChannel()
        controller.simulateClassicTransport(channel)
        defer { channel.finishWrite(); controller.simulateControlLoss() }
        controller.simulateSameTransportHandshake()
        await waitForWrites(channel, count: 1)
        channel.finishWrite()
        await waitForClassicWritesToDrain(controller)
        let query = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(query.payload, [0, 0])
        controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
        await waitForWrites(channel, count: 2)
        controller.simulateAcknowledgmentTimeout()
        for _ in 0..<20 { await Task.yield() }
        let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - query.sequence, payload: [])
        controller.classicChannelData(channel, data: acknowledgment.prefix(4))
        channel.finishWrite()
        await waitForWrites(channel, count: 3)
        channel.finishWrite()
        await waitForClassicWritesToDrain(controller)
        controller.classicChannelData(channel, data: acknowledgment.dropFirst(4))
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testClassicFragmentedPayloadsSurviveUnsentVolumeCancellation() async throws {
        for payload: [UInt8] in [[0xA9, 0x20, 9], [0xA3, 1, 0, 2, 1]] {
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: payload)
            for split in 1..<encoded.count {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                controller.simulateDeviceConnection(named: "WF-1000XM5")
                let channel = DeferredRFCOMMChannel(blockOnlyFirst: true)
                controller.simulateClassicTransport(channel)
                defer { channel.finishWrite(); controller.simulateControlLoss() }
                controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
                await waitForWrites(channel, count: 1)
                var current = true
                controller.setPlaybackVolume(20) { current }
                XCTAssertTrue(controller.refreshMusicVolume())
                controller.classicChannelData(channel, data: encoded.prefix(split))
                current = false
                channel.finishWrite()
                await waitForClassicWritesToDrain(controller)
                let status = try XCTUnwrap(controller.simulatedPendingFrame)
                controller.classicChannelData(channel, data: encoded.dropFirst(split))
                await waitForClassicWritesToDrain(controller)
                XCTAssertEqual(controller.simulatedPendingFrame, status)
                if payload[0] == 0xA9 { XCTAssertEqual(controller.playback.volume, 9) }
                else { XCTAssertEqual(controller.playback.musicCallStatus, 1) }
            }
        }
    }

    @MainActor
    func testClassicFramePrefixBeforeAdmissionCannotAcknowledgeVolume() async throws {
        for split in 1..<9 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            let channel = DeferredRFCOMMChannel(blockOnlyFirst: true)
            controller.simulateClassicTransport(channel)
            defer { channel.finishWrite(); controller.simulateControlLoss() }
            controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
            await waitForWrites(channel, count: 1)
            controller.setPlaybackVolume(20)
            let volume = try XCTUnwrap(controller.simulatedPendingFrame)
            let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - volume.sequence, payload: [])
            controller.classicChannelData(channel, data: acknowledgment.prefix(split))
            channel.finishWrite()
            await waitForClassicWritesToDrain(controller)
            controller.classicChannelData(channel, data: acknowledgment.dropFirst(split))
            XCTAssertEqual(controller.simulatedPendingFrame, volume)
            controller.classicChannelData(channel, data: acknowledgment)
            XCTAssertNil(controller.simulatedPendingFrame)
        }
    }

    @MainActor
    func testClassicCancellationCannotGiveBufferedReplyToNextPlaybackRead() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let channel = DeferredRFCOMMChannel(blockOnlyFirst: true)
        controller.simulateClassicTransport(channel)
        defer { channel.finishWrite(); controller.simulateControlLoss() }
        controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 12]))
        await waitForWrites(channel, count: 1)
        var current = true
        controller.setPlaybackVolume(20) { current }
        let cancelled = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.refreshMusicVolume())
        controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x01, sequence: 1 - cancelled.sequence, payload: [])
            + SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0xA3, 1, 0, 2, 1]))
        current = false
        channel.finishWrite()
        await waitForClassicWritesToDrain(controller)
        let status = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(status.payload, [0xA2, 1])
        XCTAssertEqual(status.sequence, cancelled.sequence)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertNil(controller.musicStatusReadbackID)
        #endif
        XCTAssertFalse(channel.writes.compactMap(SonyFrameCodec.decode).contains { $0.payload == cancelled.payload })
        controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x01, sequence: 1 - status.sequence, payload: [])
            + SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA3, 1, 0, 2, 0]))
        await waitForClassicWritesToDrain(controller)
        let volume = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(volume.payload, [0xA6, 0x20])
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertNotNil(controller.musicStatusReadbackID)
        #endif
        controller.classicChannelData(channel, data: SonyFrameCodec.encode(type: 0x01, sequence: 1 - volume.sequence, payload: [])
            + SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0xA7, 0x20, 9]))
        await waitForClassicWritesToDrain(controller)
        XCTAssertEqual(controller.playback.volume, 9)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.lastErrorMessage)
        XCTAssertEqual(channel.closeCount, 0)
    }

    @MainActor
    func testClassicVolumeRevokedAfterAdmissionStillRequiresConfirmation() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let channel = DeferredRFCOMMChannel(blockOnlyFirst: true)
        controller.simulateClassicTransport(channel)
        defer { channel.finishWrite(); controller.simulateControlLoss() }
        var current = true
        controller.setPlaybackVolume(20) { current }
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        await waitForWrites(channel, count: 1)
        XCTAssertEqual(SonyFrameCodec.decode(try XCTUnwrap(channel.writes.first)), frame)
        current = false
        let acknowledgment = SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: [])
        controller.classicChannelData(channel, data: acknowledgment.prefix(4))
        controller.classicChannelData(channel, data: acknowledgment.dropFirst(4)
            + SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA9, 0x20, 20]))
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        XCTAssertEqual(controller.playback.volume, 12)
        channel.finishWrite()
        await waitForClassicWritesToDrain(controller)
        XCTAssertEqual(controller.playback.volume, 20)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(channel.writes.compactMap(SonyFrameCodec.decode).filter { $0 == frame }.count, 1)
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.lastErrorMessage)
        XCTAssertEqual(channel.closeCount, 0)
    }

    @MainActor
    private func waitForClassicWritesToDrain(_ controller: SonyHeadphonesController) async {
        for _ in 0..<200 where controller.simulatedClassicWritesPending {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.simulatedClassicWritesPending)
    }

    @MainActor
    private func openClassicController(channel: DeferredRFCOMMChannel) async -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        device.channel = channel
        controller.simulateSonyLink(to: device)
        controller.classicChannelOpenComplete(channel, status: kIOReturnSuccess)
        await waitForWrites(channel, count: 1)
        return controller
    }

    @MainActor
    private func waitForWrites(_ channel: DeferredRFCOMMChannel, count: Int) async {
        for _ in 0..<200 where channel.writes.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(channel.writes.count, count)
    }

    @MainActor
    func testVisibleControlsRetryReopensOnlyAnIdleConnectedControlLink() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateBluetoothInitialization()
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        controller.simulateSonyLink(to: device)
        XCTAssertFalse(controller.retryControlsIfNeeded())
        controller.simulateControlLoss()
        XCTAssertTrue(controller.retryControlsIfNeeded())
        for _ in 0..<10 { XCTAssertFalse(controller.retryControlsIfNeeded()) }
        XCTAssertEqual(device.openedChannels, [7, 7])
        XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
        controller.simulateDeviceConnection(named: "WH-1000XM4")
        XCTAssertFalse(controller.retryControlsIfNeeded())
        XCTAssertEqual(device.openedChannels, [7, 7])
    }

    @MainActor
    func testVisibleControlsRetryPreservesCooldownSuppressionAndUserOperations() throws {
        for scenario in 0..<10 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            if scenario != 0 { controller.simulateBluetoothInitialization() }
            let device = ServiceDiscoveryDevice()
            device.service = ServiceDiscoveryRecord()
            controller.simulateSonyLink(to: device)
            controller.simulateControlLoss()
            switch scenario {
            case 0: break
            case 1: device.connected = false
            case 2: controller.setReconnectAutomatically(false)
            case 3: controller.simulateScheduledRetry()
            case 4: controller.systemWillSleep()
            case 5: XCTAssertNotNil(controller.simulateClassicConnection())
            default:
                controller.simulateDeviceConnection(named: "WF-1000XM5")
                switch scenario {
                case 6: controller.powerOff(expectedSession: controller.simulatedControlSession)
                case 7:
                    XCTAssertTrue(controller.beginEarTipFit())
                    for reply: [UInt8] in [[0xF1, 6, 10, 1, 1, 4, 0, 1, 2, 3], [0xF3, 6, 0, 0, 1, 0], [0xF7, 6, 0, 0, 1, 0, 1, 255]] {
                        deliver(reply, to: controller)
                        acknowledge(controller)
                    }
                    controller.startEarTipFit(id: try XCTUnwrap(controller.earTipFitTransition?.id))
                    XCTAssertEqual(controller.earTipFitTransition?.phase, .entering)
                case 8:
                    XCTAssertTrue(controller.beginHeadGesturePractice())
                    deliver([0xF3, 0x10, 0], to: controller)
                    acknowledge(controller)
                    controller.startHeadGesturePractice(id: try XCTUnwrap(controller.headGesturePracticeTransition?.id))
                    XCTAssertEqual(controller.headGesturePracticeTransition?.phase, .entering)
                default: controller.setConnectionMode(.lowLatency)
                }
                controller.simulateControlLoss()
            }
            let state = controller.linkState
            let retry = controller.retrySecondsRemaining
            for _ in 0..<10 { XCTAssertFalse(controller.retryControlsIfNeeded(), "Scenario \(scenario)") }
            XCTAssertEqual(device.openedChannels, [7])
            XCTAssertTrue(device.discoveryCallbacks.isEmpty)
            XCTAssertEqual(controller.linkState, state)
            XCTAssertEqual(controller.retrySecondsRemaining, retry)
        }
    }

    @MainActor
    func testVisibleControlsRetryWaitsForAnOutstandingServiceQueryAfterTimeout() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateBluetoothInitialization()
        let device = ServiceDiscoveryDevice()
        controller.simulateSonyLink(to: device)
        XCTAssertFalse(controller.retryControlsIfNeeded())
        controller.simulateHandshakeTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.retryControlsIfNeeded())
        XCTAssertEqual(device.discoveryCallbacks.count, 1)
        device.service = ServiceDiscoveryRecord()
        device.complete()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.retryControlsIfNeeded())
        XCTAssertTrue(device.openedChannels.isEmpty)
        XCTAssertNotNil(controller.retrySecondsRemaining)
        controller.simulateRetryDeadlineReached()
        XCTAssertTrue(controller.retryControlsIfNeeded())
        XCTAssertEqual(device.openedChannels, [7])
    }

    @MainActor
    func testCachedSonyServiceOpensWithoutAnotherDiscovery() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        controller.simulateSonyLink(to: device)
        XCTAssertTrue(device.discoveryCallbacks.isEmpty)
        XCTAssertEqual(device.openedChannels, [7])
    }

    @MainActor
    func testSonyServiceLookupPrefersCurrentServiceAndFallsBackToLegacySerialService() throws {
        let current = Data(SonyHeadphonesController.sonyServiceUUIDs[0])
        let legacy = Data(SonyHeadphonesController.sonyServiceUUIDs[1])
        XCTAssertEqual(current.prefix(4), Data([0x95, 0x6C, 0x7B, 0x26]))
        XCTAssertEqual(legacy, Data([0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD,
                                     0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA]))

        let both = ServiceDiscoveryDevice()
        both.service = ServiceDiscoveryRecord()
        XCTAssertEqual(try XCTUnwrap(SonyHeadphonesController.sonyServiceRecord(on: both)).uuid, Array(current))
        XCTAssertEqual(both.lookedUpUUIDs, [current])

        let legacyOnly = ServiceDiscoveryDevice()
        legacyOnly.service = ServiceDiscoveryRecord()
        legacyOnly.serviceUUID = legacy
        XCTAssertEqual(try XCTUnwrap(SonyHeadphonesController.sonyServiceRecord(on: legacyOnly)).uuid, Array(legacy))
        XCTAssertEqual(legacyOnly.lookedUpUUIDs, [current, legacy])

        let neither = ServiceDiscoveryDevice()
        XCTAssertNil(SonyHeadphonesController.sonyServiceRecord(on: neither))
        XCTAssertEqual(neither.lookedUpUUIDs, [current, legacy])
    }

    @MainActor
    func testLegacySerialServiceOpensWithoutAnotherDiscovery() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        device.serviceUUID = Data(SonyHeadphonesController.sonyServiceUUIDs[1])
        controller.simulateSonyLink(to: device)
        XCTAssertTrue(device.discoveryCallbacks.isEmpty)
        XCTAssertEqual(device.openedChannels, [7])
    }

    @MainActor
    func testMissingSonyServiceIsDiscoveredBeforeOpeningWithoutDuplicateQueries() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let device = ServiceDiscoveryDevice()
        controller.simulateSonyLink(to: device)
        controller.simulateSonyLink(to: device)
        controller.simulateAutomaticRefresh()
        XCTAssertEqual(device.discoveryCallbacks.count, 1)
        XCTAssertTrue(device.openedChannels.isEmpty)
        XCTAssertEqual(controller.linkState, .opening)
        XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
        device.service = ServiceDiscoveryRecord()
        device.complete()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(device.openedChannels, [7])
        XCTAssertEqual(device.serviceLookups, 3)
        device.complete()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(device.openedChannels, [7])
    }

    @MainActor
    func testMissingOrFailedSonyServiceDiscoveryStopsWithoutOpening() async {
        for (startStatus, completionStatus) in [(kIOReturnSuccess, kIOReturnSuccess),
                                               (kIOReturnSuccess, kIOReturnError),
                                               (kIOReturnError, kIOReturnSuccess)] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            let device = ServiceDiscoveryDevice()
            device.discoveryStartStatus = startStatus
            controller.simulateSonyLink(to: device)
            device.complete(status: completionStatus)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(device.discoveryCallbacks.count, 1)
            XCTAssertTrue(device.openedChannels.isEmpty)
            XCTAssertEqual(controller.linkState, .failed(String(localized: "Could not connect to the headphones’ controls.")))
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        }
    }

    @MainActor
    func testSonyServiceDiscoveryDoesNotConnectAnAbsentDevice() async {
        for disconnectBeforeQuery in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            let device = ServiceDiscoveryDevice()
            device.connected = !disconnectBeforeQuery
            controller.simulateSonyLink(to: device)
            if !disconnectBeforeQuery {
                device.connected = false
                device.service = ServiceDiscoveryRecord()
                device.complete()
                for _ in 0..<4 { await Task.yield() }
            }
            XCTAssertEqual(device.discoveryCallbacks.count, disconnectBeforeQuery ? 0 : 1)
            XCTAssertTrue(device.openedChannels.isEmpty)
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertEqual(controller.linkState, .disconnected)
        }
    }

    @MainActor
    func testSonyServiceDiscoveryIgnoresCallbacksAfterTimeoutSleepOrReplacement() async {
        for interruption in 0..<3 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            let device = ServiceDiscoveryDevice()
            controller.simulateSonyLink(to: device)
            switch interruption {
            case 0: controller.simulateHandshakeTimeout()
            case 1: controller.systemWillSleep()
            default:
                controller.simulateControlLoss()
                controller.simulateSonyLink(to: device)
            }
            for _ in 0..<4 { await Task.yield() }
            let state = controller.linkState
            device.service = ServiceDiscoveryRecord()
            device.complete()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(device.openedChannels.isEmpty)
            XCTAssertEqual(controller.linkState, state)
            if interruption == 2 {
                XCTAssertEqual(device.discoveryCallbacks.count, 1)
                controller.simulateSonyLink(to: device)
                XCTAssertEqual(device.openedChannels, [7])
            }
        }
    }

    @MainActor
    func testSonyServiceDiscoveryWaitsForOutstandingCallbackBeforeAnotherQuery() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let device = ServiceDiscoveryDevice()
        controller.simulateSonyLink(to: device)
        controller.simulateHandshakeTimeout()
        for _ in 0..<4 { await Task.yield() }
        for _ in 0..<10 { controller.simulateSonyLink(to: device) }
        XCTAssertEqual(device.discoveryCallbacks.count, 1)
        XCTAssertTrue(device.openedChannels.isEmpty)
        device.complete()
        for _ in 0..<4 { await Task.yield() }
        controller.simulateSonyLink(to: device)
        XCTAssertEqual(device.discoveryCallbacks.count, 2)
        device.complete()
        for _ in 0..<4 { await Task.yield() }
        device.service = ServiceDiscoveryRecord()
        device.complete(1)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(device.openedChannels, [7])
    }

    @MainActor
    func testConnectionPreferenceOwnershipSurvivesControlResetAndChangesOnlyForAcceptedRequests() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        defer { controller.simulateControlLoss() }
        controller.setConnectionMode(.stableConnection)
        let first = try XCTUnwrap(controller.lastConnectionModeChangeID)
        controller.setConnectionMode(.lowLatency)
        XCTAssertEqual(controller.lastConnectionModeChangeID, first)
        controller.respondToConnectionAlert(try XCTUnwrap(controller.connectionTransition?.alert), action: .negative)
        controller.setConnectionMode(.stableConnection)
        let second = try XCTUnwrap(controller.lastConnectionModeChangeID)
        XCTAssertNotEqual(first, second)
        controller.respondToConnectionAlert(try XCTUnwrap(controller.connectionTransition?.alert), action: .positive)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        controller.setConnectionMode(.stableConnection)
        XCTAssertEqual(controller.lastConnectionModeChangeID, second)
        controller.systemWillSleep()
        XCTAssertNil(controller.connectionTransition)
        XCTAssertEqual(controller.lastConnectionModeChangeID, second)
        controller.systemDidWake()
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertEqual(controller.lastConnectionModeChangeID, second)
        controller.setConnectionMode(.stableConnection)
        XCTAssertNotEqual(controller.lastConnectionModeChangeID, second)
    }

    @MainActor
    func testOwnedConnectionPreferenceRetryChecksWithoutReplayingTheSetter() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        controller.setConnectionMode(.stableConnection)
        let request = try XCTUnwrap(controller.lastConnectionModeChangeID)
        acknowledgeAll(controller)
        controller.simulateConnectionModeTimeout()
        XCTAssertEqual(controller.connectionTransition?.phase, .failed)
        XCTAssertTrue(controller.diagnosticReport.contains("Connection preference change: failed"))
        XCTAssertTrue(controller.diagnosticReport.contains("Connection preference issue: \(controller.connectionModeError!)"))
        XCTAssertFalse(controller.retryConnectionModeChange(expectedRequestID: UUID()))
        XCTAssertEqual(controller.connectionTransition?.phase, .failed)
        XCTAssertTrue(controller.retryConnectionModeChange(expectedRequestID: request))
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertEqual(controller.lastConnectionModeChangeID, request)
        XCTAssertNil(controller.connectionModeError)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.count, 1)
    }

    @MainActor
    func testClassicConnectionWaitsForCompletionWithoutDuplicatePollingOpens() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM4", controlBusy: true)
        controller.simulateControlLoss(deviceConnected: false)
        controller.simulateBluetoothInitialization()
        defer { controller.simulateControlLoss() }
        let complete = try XCTUnwrap(controller.simulateClassicConnection())
        XCTAssertEqual(controller.linkState, .opening)
        XCTAssertNil(controller.simulateClassicConnection())
        controller.simulateAutomaticRefresh()
        XCTAssertEqual(controller.linkState, .opening)
        XCTAssertNil(controller.simulatedPendingFrame)
        complete(kIOReturnSuccess, true)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
    }

    @MainActor
    func testClassicConnectionFailureDoesNotStartHandshake() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM4", controlBusy: true)
        controller.simulateControlLoss(deviceConnected: false)
        defer { controller.simulateControlLoss() }
        let complete = try XCTUnwrap(controller.simulateClassicConnection())
        complete(kIOReturnError, false)
        XCTAssertEqual(controller.linkState, .failed(String(localized: "No response. Check that the headphones are on.")))
        XCTAssertFalse(controller.isDeviceConnected)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testClassicConnectionCompletionCannotReviveSleepingOrReplacedRequest() throws {
        for startReplacement in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WH-1000XM4", controlBusy: true)
            controller.simulateControlLoss(deviceConnected: false)
            controller.simulateBluetoothInitialization()
            controller.setReconnectAutomatically(false)
            defer { controller.simulateControlLoss() }
            let complete = try XCTUnwrap(controller.simulateClassicConnection())
            controller.systemWillSleep()
            XCTAssertNil(controller.simulateClassicConnection())
            var replacement: ((IOReturn, Bool) -> Void)?
            if startReplacement {
                controller.systemDidWake()
                replacement = try XCTUnwrap(controller.simulateClassicConnection())
            }
            complete(kIOReturnSuccess, true)
            XCTAssertEqual(controller.linkState, startReplacement ? .opening : .disconnected)
            XCTAssertFalse(controller.isDeviceConnected)
            XCTAssertNil(controller.simulatedPendingFrame)
            if let replacement {
                replacement(kIOReturnSuccess, true)
                XCTAssertEqual(controller.linkState, .handshaking)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
            }
        }
    }

    @MainActor
    func testClassicRecoveryCompletionCannotReviveTimedOutTransition() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        controller.setConnectionMode(.lowLatency)
        controller.simulateControlLoss(deviceConnected: false)
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        let complete = try XCTUnwrap(controller.simulateClassicConnection(recovering: true))
        controller.simulateConnectionModeTimeout()
        XCTAssertEqual(controller.connectionTransition?.phase, .failed)
        complete(kIOReturnSuccess, true)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertFalse(controller.isDeviceConnected)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testClassicDevicesWithoutNoiseControlFinishSyncAndLoadAdvertisedFeatures() {
        let cases: [(String, [UInt8], [UInt8], [UInt8])] = [
            ("WH-CH520", [0x01, 0, 3, 0, 0x30, 0x18, 0, 1], [0x07, 0, 2, 0x20, 0, 0xE2, 0], [0x22, 0]),
            ("WH-H800", [0x01, 0, 0x40, 0], [0x07, 0, 2, 0x11, 0xE2], [0x10, 0])
        ]
        for (name, protocolReply, functions, batteryQuery) in cases {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: name, controlBusy: true)
            deliver(protocolReply, to: controller, begin: true)
            acknowledgeAll(controller)
            deliver(functions, to: controller)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.supportsDSEE)
            XCTAssertTrue(controller.availableNoiseModes.isEmpty)
            XCTAssertFalse(controller.canChangeNoiseControl)
            XCTAssertNil(controller.noiseControlMode)
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == batteryQuery })
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { [0x60, 0x62, 0x66, 0x68].contains($0.payload.first) })
            deliver([batteryQuery[0] + 1, 0, 78, 0], to: controller)
            XCTAssertEqual(controller.batteryLevel, 78)
            controller.setNoiseControl(.anc)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        }
    }

    @MainActor
    func testDevicesWithoutNoiseControlStillVerifyBluetoothLEIdentity() {
        for hash in ["ABCDEF12", "12345678"] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-C510", controlBusy: true, peripheralIdentifier: UUID())
            controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1],
                beginConnection: true, expectedBLEHash: "ABCDEF12")
            acknowledgeAll(controller)
            deliver([0x07, 0, 2, 0x14, 0, 0x20, 0], to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.isReady)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x22, 0] })
            deliver([0x11, 4] + Array("00:11:22:33:44:55\(hash)".utf8), to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.isReady, hash == "ABCDEF12")
            XCTAssertEqual(controller.bluetoothLEError == nil, hash == "ABCDEF12")
            XCTAssertEqual(controller.simulatedTransmittedFrames.contains { $0.payload == [0x22, 0] }, hash == "ABCDEF12")
        }
    }

    @MainActor
    func testLegacyQualityAlertSubscriptionIsVersionGatedAndCautionNeverAutoAccepts() throws {
        for version: UInt8 in [0x30, 0x40] {
            let controller = preparedLegacyQualityController(version: version)
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.canChangeConnectionMode)
            XCTAssertEqual(controller.supportedConnectionModes, [.soundQuality, .stableConnection])
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x94 }.map(\.payload),
                           version == 0x40 ? [[0x94, 1, 0]] : [])
            deliver([0x99, 1, 1, 1], to: controller)
            let alert = try XCTUnwrap(controller.lastConnectionAlert)
            XCTAssertTrue(alert.isLegacyConnectionChange)
            XCTAssertNil(controller.connectionTransition)
            controller.respondToConnectionAlert(alert, action: .positive)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
            controller.setConnectionMode(.stableConnection)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
            deliver([0x99, 1, 1, 1], to: controller)
            XCTAssertEqual(controller.connectionTransition?.phase, .awaitingUser(alert))
            controller.simulateConnectionModeTimeout()
            XCTAssertTrue(controller.connectionTransition?.awaitingUser == true)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
            controller.respondToConnectionAlert(alert, action: .negative)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 1, 1, 0])
            XCTAssertEqual(controller.connectionTransition?.phase, .cancelled)
            XCTAssertEqual(controller.connectionMode, .soundQuality)
        }
        let controller = preparedLegacyQualityController()
        defer { controller.simulateControlLoss() }
        deliver([0xE9, 1, 0, 1], to: controller)
        controller.setConnectionMode(.soundQuality)
        acknowledgeAll(controller)
        deliver([0x99, 1, 1, 1], to: controller)
        let offer = try XCTUnwrap(controller.connectionTransition?.alert)
        XCTAssertEqual(controller.connectionTransition?.targetMode, .soundQuality)
        controller.respondToConnectionAlert(offer, action: .positive)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.connectionTransition?.targetMode, .stableConnection)
        deliver([0xE7, 1, 0, 0], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        deliver([0xE9, 1, 0, 1], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.map(\.payload), [[0xE8, 1, 0, 0]])
    }

    @MainActor
    func testLegacyAlertSubscriptionRequiresItsOwnACKWithoutFunction90() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM4", controlBusy: true)
        deliver([0x01, 0, 0x40, 0], to: controller, begin: true)
        acknowledgeAll(controller)
        deliver([0x07, 0, 2, 0x62, 0xE1], to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x94, 1, 0])
        let setup = controller.simulatedPendingFrame!
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: setup.sequence, payload: []))
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, setup.payload)
        controller.setConnectionMode(.stableConnection)
        XCTAssertNil(controller.connectionTransition)
        acknowledgeAll(controller)
        deliverLegacyNoise(to: controller)
        acknowledgeAll(controller)
        deliverLegacyQuality(to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.canChangeConnectionMode)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xE8 })
    }

    @MainActor
    func testLegacyQualityMetadataNeedsTransmittedOwnedReadsAndKnownRepliesEndDeadlines() async {
        let controller = beginLegacyQualityController(deferQualityReads: true)
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE0, 1])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xE0, 1] })
        deliverLegacyQuality(to: controller)
        XCTAssertNil(controller.legacyControls?.connectionQuality.settingType)
        XCTAssertNil(controller.legacyControls?.connectionQuality.available)
        XCTAssertNil(controller.connectionMode)
        controller.simulateSystemReadTimeout([0xE0, 1])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        for payload: [UInt8] in [[0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] {
            controller.simulateProtocolMessage(payload, type: 0x0E)
            deliver(payload + [0], to: controller)
        }
        XCTAssertNil(controller.connectionMode)
        XCTAssertFalse(controller.canChangeConnectionMode)
        deliverLegacyQuality(to: controller)
        XCTAssertTrue(controller.canChangeConnectionMode)
        for query: [UInt8] in [[0xE0, 1], [0xE2, 1], [0xE6, 1]] { controller.simulateSystemReadTimeout(query) }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        deliver([0xE1, 1, 0xFF], to: controller)
        deliver([0xE7, 1, 0, 1], to: controller)
        XCTAssertEqual(controller.legacyControls?.connectionQuality.settingType, 0)
        XCTAssertEqual(controller.connectionMode, .soundQuality)
    }

    @MainActor
    func testLegacyQualityUnknownOrMalformedOwnedRepliesRetainTheirDeadline() async {
        for (query, reply): ([UInt8], [UInt8]) in [
            ([0xE0, 1], [0xE1, 1, 0xFF]), ([0xE2, 1], [0xE3, 1, 0xFF]),
            ([0xE6, 1], [0xE7, 1, 0, 2]), ([0xE6, 1], [0xE7, 1, 0]),
        ] {
            let controller = beginLegacyQualityController()
            defer { controller.simulateControlLoss() }
            acknowledgeAll(controller)
            for known: [UInt8] in [[0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] where known[0] != reply[0] {
                deliver(known, to: controller)
            }
            deliver(reply, to: controller)
            XCTAssertFalse(controller.canChangeConnectionMode)
            XCTAssertNotEqual(controller.connectionMode, .lowLatency)
            let session = controller.simulatedControlSession
            controller.simulateSystemReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertFalse(controller.isReady)
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            controller.simulateProtocolMessage([0xE9, 1, 0, 1], session: session)
            XCTAssertNil(controller.connectionMode)
        }
    }

    @MainActor
    func testLegacyQualityConfirmationRequiresActualTransmissionAndTheExactTypedState() {
        let controller = preparedLegacyQualityController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setConnectionMode(.stableConnection)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 1, 0, 1])
        XCTAssertEqual(controller.connectionTransition?.phase, .queued)
        controller.defersSimulatedWrites = false
        deliver([0xE9, 1, 0, 1], to: controller)
        acknowledge(controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .queued)
        XCTAssertFalse(controller.connectionTransition?.preferenceConfirmed == true)
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        for payload: [UInt8] in [[0xE9, 1, 1], [0xE9, 5, 1, 2], [0xE9, 2, 0, 1], [0xE9, 1, 1, 1]] {
            deliver(payload, to: controller)
            XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        }
        XCTAssertNotEqual(controller.connectionMode, .lowLatency)
        deliver([0xE9, 1, 0, 1], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertEqual(controller.connectionMode, .stableConnection)
        XCTAssertNil(controller.connectionTransition?.requiredStream)
        XCTAssertFalse(controller.usesBluetoothLE)
        deliver([0x99, 1, 1, 1], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
    }

    @MainActor
    func testLegacyQualityOldPollCannotConfirmAfterExplicitCautionReply() async throws {
        let controller = preparedLegacyQualityController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setConnectionMode(.stableConnection)
        acknowledgeAll(controller)
        deliver([0x99, 1, 1, 1], to: controller)
        let alert = try XCTUnwrap(controller.connectionTransition?.alert)
        controller.simulateSystemReadTimeout([0xE6, 1])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingUser(alert))
        controller.respondToConnectionAlert(alert, action: .positive)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 1, 1, 1])
        acknowledgeAll(controller)
        let reads = controller.simulatedTransmittedFrames.filter { $0.payload == [0xE6, 1] }.count
        deliver([0xE7, 1, 0, 1], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        XCTAssertEqual(controller.connectionMode, .soundQuality)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE6, 1] }.count, reads + 1)
        deliver([0xE9, 1, 0, 2], to: controller)
        XCTAssertEqual(controller.connectionMode, .unknown(2))
        deliver([0xE7, 1, 0, 1], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        XCTAssertEqual(controller.connectionMode, .unknown(2))
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE6, 1] }.count, reads + 2)
        deliver([0xE7, 1, 0, 1], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertEqual(controller.connectionMode, .stableConnection)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.map(\.payload), [[0xE8, 1, 0, 1]])
    }

    @MainActor
    func testLegacyQualityNewNotificationsSupersedeOldPollsAndQueuedWrites() {
        for change: [UInt8] in [[0xE5, 1, 1], [0xE9, 1, 1, 0], [0xE9, 1, 0, 1]] {
            let controller = preparedLegacyQualityController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            controller.setConnectionMode(.stableConnection)
            XCTAssertEqual(controller.connectionTransition?.phase, .queued)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xE8 })
            deliver(change, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xE8 })
            XCTAssertEqual(controller.connectionTransition?.phase, .failed)
            XCTAssertNotNil(controller.connectionModeError)
        }
        for unknown in [false, true] {
            let controller = preparedLegacyQualityController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0xE9, 1, 0, unknown ? 2 : 1], to: controller)
            deliver([0xE5, 1, unknown ? 0xFF : 1], to: controller)
            deliver([0xE7, 1, 0, 0], to: controller)
            deliver([0xE3, 1, 0], to: controller)
            XCTAssertEqual(controller.connectionMode, unknown ? .unknown(2) : .stableConnection)
            XCTAssertEqual(controller.legacyControls?.connectionQuality.available, unknown ? nil : false)
            XCTAssertFalse(controller.canChangeConnectionMode)
        }
    }

    @MainActor
    func testLegacyQualityLostOrTimedOutChangeRecoversClassicWithFreshReadbackAndNoReplay() async {
        for (disconnects, actual): (Bool, UInt8) in [(false, 0), (false, 1), (true, 1)] {
            let controller = preparedLegacyQualityController()
            defer { controller.simulateControlLoss() }
            let address = controller.address
            controller.setConnectionMode(.stableConnection)
            acknowledgeAll(controller)
            let session = controller.simulatedControlSession
            if disconnects {
                controller.simulateControlLoss()
                XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
                controller.simulateClassicRecovery()
            } else {
                controller.simulateConnectionModeTimeout()
                XCTAssertEqual(controller.connectionTransition?.phase, .failed)
                XCTAssertFalse(controller.canChangeConnectionMode)
                controller.setConnectionMode(.stableConnection)
                XCTAssertEqual(controller.connectionTransition?.phase, .failed)
                controller.refresh()
                acknowledgeAll(controller)
                controller.connect()
                for _ in 0..<4 { await Task.yield() }
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
                deliver([0xE3, 1, 0], to: controller)
                deliver([0xE7, 1, 0, 0], to: controller)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
                deliver([0x63, 2, 0], to: controller)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertEqual(controller.simulatedControlSession, session)
                deliver([0x67, 2, 1, 0, 0, 1, 0, 12], to: controller)
                for _ in 0..<4 { await Task.yield() }
            }
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0])
            XCTAssertFalse(controller.usesBluetoothLE)
            XCTAssertEqual(controller.simulatedRecoveryAddress, address)
            negotiateLegacyQuality(to: controller, deferQualityReads: true)
            XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
            controller.simulateProtocolMessage([0xE9, 1, 0, 1], session: session)
            deliver([0xE7, 1, 0, 1], to: controller)
            XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
            controller.completeSimulatedWrite()
            acknowledgeAll(controller)
            deliver([0xE1, 1, 0], to: controller)
            deliver([0xE3, 1, 0], to: controller)
            deliver([0xE7, 1, 0, actual], to: controller)
            if actual == 1 {
                XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
            } else {
                XCTAssertNil(controller.connectionTransition)
                XCTAssertNotNil(controller.connectionModeError)
                XCTAssertTrue(controller.canChangeConnectionMode)
            }
            XCTAssertEqual(controller.connectionMode, actual == 1 ? .stableConnection : .soundQuality)
            XCTAssertFalse(controller.usesBluetoothLE)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.map(\.payload), [[0xE8, 1, 0, 1]])
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xE6, 5] })
        }
        for reportsFirmware in [false, true] {
            let controller = beginLegacyQualityController()
            defer { controller.simulateControlLoss() }
            acknowledgeAll(controller)
            deliverLegacyQuality(to: controller)
            XCTAssertNil(controller.firmwareVersion)
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x04, 2] })
            controller.setConnectionMode(.stableConnection)
            acknowledgeAll(controller)
            controller.simulateConnectionModeTimeout()
            let session = controller.simulatedControlSession
            controller.connect()
            deliver([0xE7, 1, 0, 0], to: controller)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
            XCTAssertTrue(controller.simulatedConnectionModeTimeoutPending)
            if reportsFirmware {
                deliver([0x05, 2, 5] + Array("1.0.0".utf8), to: controller)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertGreaterThan(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0])
            } else {
                controller.simulateConnectionModeTimeout()
                XCTAssertFalse(controller.isReady)
                XCTAssertGreaterThan(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.connectionTransition?.phase, .failed)
                XCTAssertNotNil(controller.connectionModeError)
                XCTAssertNil(controller.simulatedPendingFrame)
            }
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.map(\.payload), [[0xE8, 1, 0, 1]])
        }
    }

    @available(macOS 27.0, *)
    @MainActor
    func testAlternateClassicControlAddressKeepsPinnedIdentityAndNativeActions() throws {
        let suite = "dev.baglayan.Acouplet.pinned-recovery-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let address = "02:53:4F:4E:59:01"
        let alternate = "02:53:4F:4E:59:02"
        let peripheralID = UUID()
        let savedIdentity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: address, model: .wfXM5,
            hash: "ABCDEF12", peripheralIdentifier: peripheralID))
        SonyBLEIdentity.save(savedIdentity, in: defaults)
        let controller = preparedController(identityDefaults: defaults, pinnedAddress: address)
        defer { controller.simulateControlLoss() }
        let identity = try XCTUnwrap(controller.simulatedSavedIdentity)
        XCTAssertEqual(identity.peripheralIdentifier, peripheralID)
        deliver([0x49, 0x0E, 0] + Array(alternate.utf8), to: controller)
        XCTAssertEqual(controller.simulatedRecoveryAddress, address)
        controller.simulateClassicRecovery()
        XCTAssertEqual(controller.address, address)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0])
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0x07, 0, 2, 0x6B, 0, 0x14, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8), to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.address, address)
        XCTAssertEqual(controller.simulatedSavedIdentity, identity)
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults), [address: identity])
        XCTAssertFalse(controller.noiseControlActions.isEmpty)
        XCTAssertTrue(controller.noiseControlActions.allSatisfy { $0.id.hasPrefix(address + ":wfXM5:") })
        deliver([0x49, 0x0E, 0] + Array("02:00:00:00:00:02".utf8), to: controller)
        XCTAssertEqual(controller.address, address)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testVerifiedIdentitySurvivesColdStartAndStillRejectsTheWrongBLEHash() throws {
        let suite = "dev.baglayan.Acouplet.identity-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = preparedController(identityDefaults: defaults)
        let identity = try XCTUnwrap(first.simulatedSavedIdentity)
        XCTAssertEqual(identity.hash, "ABCDEF12")
        first.simulateControlLoss()
        XCTAssertNil(first.bluetoothLEHash)
        XCTAssertEqual(first.simulatedSavedIdentity, identity)
        let restarted = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        XCTAssertEqual(restarted.simulatedSavedIdentity, identity)
        XCTAssertNil(restarted.bluetoothLEHash)
        XCTAssertFalse(restarted.isReady)
        restarted.simulateDeviceConnection(named: "WF-1000XM5")
        restarted.simulateProtocolMessage([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00],
            beginConnection: true, expectedBLEHash: identity.hash)
        acknowledgeAll(restarted)
        let functions: [UInt8] = [0x6B, 0x14, 0x90]
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: restarted)
        acknowledgeAll(restarted)
        deliver([0x11, 0x04] + Array("00:11:22:33:44:5512345678".utf8), to: restarted)
        XCTAssertFalse(restarted.isReady)
        XCTAssertEqual(restarted.simulatedSavedIdentity, identity)
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults)[identity.classicAddress], identity)
        XCTAssertFalse(restarted.simulatedTransmittedFrames.contains { $0.payload.first == 0x94 || $0.payload.first == 0x66 })
        defaults.set([identity.classicAddress: ["hash": "invalid"]], forKey: SonyBLEIdentity.savedDevicesKey)
        let malformed = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        XCTAssertNil(malformed.simulatedSavedIdentity)
    }

    @MainActor
    func testVerifiedPeripheralIdentifierSurvivesTransitionControlLossAndRetry() {
        for identifier in [UUID(), nil] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5", peripheralIdentifier: identifier)
            controller.setConnectionMode(.lowLatency)
            XCTAssertEqual(controller.simulatedRecoveryPeripheralID, identifier)
            controller.simulateControlLoss()
            XCTAssertNil(controller.controlPeripheralID)
            XCTAssertEqual(controller.simulatedRecoveryPeripheralID, identifier)
            XCTAssertEqual(controller.simulatedRecoveryHash, "ABCDEF12")
            controller.simulateRecoveryFailure()
            controller.connect()
            XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
            XCTAssertEqual(controller.simulatedRecoveryPeripheralID, identifier)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
        }
    }

    @MainActor
    func testBluetoothLERetrievalStillRequiresMatchingProtocolHashBeforeControls() {
        for hash in ["ABCDEF12", "12345678"] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5", peripheralIdentifier: UUID())
            controller.simulateProtocolMessage([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00],
                beginConnection: true, expectedBLEHash: "ABCDEF12")
            acknowledgeAll(controller)
            let functions: [UInt8] = [0x6B, 0x14, 0x90, 0xE7]
            deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.isReady)
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x10, 0x04] })
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x94 || $0.payload.first == 0x66 })
            deliver([0x11, 0x04] + Array("00:11:22:33:44:55\(hash)".utf8), to: controller)
            if hash == "ABCDEF12" {
                acknowledgeAll(controller)
                deliver([0x67, 0x17, 0x01, 0x01, 0, 0, 10], to: controller)
                XCTAssertTrue(controller.isReady)
                XCTAssertNil(controller.bluetoothLEError)
                controller.simulateControlLoss()
            } else {
                XCTAssertFalse(controller.isReady)
                XCTAssertEqual(controller.bluetoothLEError, String(localized: "The connected device did not match the selected headphones."))
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x94 || $0.payload.first == 0x66 })
                XCTAssertNil(controller.simulatedPendingFrame)
            }
        }
    }

    @MainActor
    func testCapturedFirstPairingSequenceWaitsWithoutAutomaticRecoveryOrSetterReplay() throws {
        let controller = preparedController()
        controller.setConnectionMode(.lowLatency)
        acknowledge(controller)
        deliver([0x99, 0x06, 0x10, 0x09, 0x18, 0x0F, 0x0B, 0x09, 0x0C, 0x17, 0x15, 0x19, 0x12, 0x01], to: controller)
        let alert = try XCTUnwrap(controller.connectionTransition?.alert)
        controller.respondToConnectionAlert(alert, action: .positive)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0x06, 0x10, 0x01])
        acknowledge(controller)
        deliver([0x49, 0x0C, 0x00], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .pairingRequired)
        XCTAssertFalse(controller.simulatedConnectionModeTimeoutPending)
        acknowledge(controller)
        deliver([0xE9, 0x05, 0x00, 0x00], to: controller)
        deliver([0xE7, 0x05, 0x00], to: controller)
        controller.simulateConnectionModeTimeout()
        XCTAssertEqual(controller.audioFeatures.connectionMode, .soundQuality)
        XCTAssertEqual(controller.audioFeatures.codec, .aac)
        XCTAssertEqual(controller.connectionTransition?.phase, .pairingRequired)
        XCTAssertFalse(controller.connectionTransition?.preferenceConfirmed == true)
        XCTAssertNil(controller.connectionModeError)
        let writes = controller.simulatedTransmittedFrames
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        controller.simulateControlLoss()
        let session = controller.simulatedControlSession
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        XCTAssertEqual(controller.connectionTransition?.phase, .pairingRequired)
        XCTAssertEqual(controller.connectionTransition?.originalMode, .soundQuality)
        XCTAssertNil(controller.retrySecondsRemaining)
        controller.connect()
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertEqual(controller.simulatedRecoveryHash, "ABCDEF12")
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        XCTAssertEqual(writes.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
    }

    @MainActor
    func testPairingStandbyMustHaveExactLengthKnownOnValueAndAdvertisedFunction() throws {
        for supportsStandby in [false, true] {
            let controller = preparedController(supportsStandby: supportsStandby)
            controller.setConnectionMode(.lowLatency)
            acknowledge(controller)
            deliver([0x99, 0x06, 0x10, 0, 1], to: controller)
            controller.respondToConnectionAlert(try XCTUnwrap(controller.connectionTransition?.alert), action: .positive)
            acknowledgeAll(controller)
            for payload: [UInt8] in [[0x49, 0x0C], [0x49, 0x0C, 0, 0], [0x49, 0x0C, 0xFF], [0x49, 0x0C, 1]] {
                deliver(payload, to: controller)
                XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
            }
            deliver([0x49, 0x0C, 0], to: controller)
            XCTAssertEqual(controller.connectionTransition?.phase, supportsStandby ? .pairingRequired : .awaitingResponse)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testCheckingPairingReusesReadyControlsAfterOutstandingReadbackDrains() async throws {
        let controller = preparedController()
        controller.setConnectionMode(.lowLatency)
        acknowledge(controller)
        deliver([0x99, 0x06, 0x10, 0, 1], to: controller)
        controller.respondToConnectionAlert(try XCTUnwrap(controller.connectionTransition?.alert), action: .positive)
        acknowledge(controller)
        deliver([0x49, 0x0C, 0], to: controller)
        acknowledge(controller)
        let session = controller.simulatedControlSession
        controller.connect()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedModeReadbackCount, 1)
        deliver([0xE7, 0x05, 0], to: controller)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertEqual(controller.simulatedModeReadbackCount, 0)
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x57, 0x00, EqualizerPreset.bassBoost.rawValue, 0x00], to: controller)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testCheckingPairingTimesOutIfOldReadbackNeverArrives() throws {
        let controller = preparedController()
        controller.setConnectionMode(.lowLatency)
        acknowledge(controller)
        deliver([0x99, 0x06, 0x10, 0, 1], to: controller)
        controller.respondToConnectionAlert(try XCTUnwrap(controller.connectionTransition?.alert), action: .positive)
        acknowledge(controller)
        deliver([0x49, 0x0C, 0], to: controller)
        acknowledge(controller)
        controller.connect()
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertTrue(controller.simulatedConnectionModeTimeoutPending)
        XCTAssertEqual(controller.simulatedModeReadbackCount, 1)
        let session = controller.simulatedControlSession
        controller.simulateConnectionModeTimeout()
        XCTAssertEqual(controller.connectionTransition?.phase, .failed)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.simulatedModeReadbackCount, 0)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNotNil(controller.connectionModeError)
        let writes = controller.simulatedTransmittedFrames
        controller.simulateAutomaticRefresh()
        XCTAssertEqual(controller.connectionTransition?.phase, .failed)
        controller.connect()
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
    }

    @MainActor
    func testAlertSetupMustBeTransmittedAndAcknowledgedBeforeModeWrites() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        deliver([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00], to: controller, begin: true)
        acknowledgeAll(controller)
        deliver([0x07, 0x00, 0x03, 0x6B, 0x00, 0x90, 0x00, 0xE7, 0x00], to: controller)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x94, 0x00, 0x00])
        deliver([0x67, 0x17, 0x01, 0x01, 0x00, 0x00, 0x0A], to: controller)
        deliverModeState(to: controller)
        XCTAssertFalse(controller.isReady)
        XCTAssertFalse(controller.canChangeConnectionMode)
        controller.setConnectionMode(.stableConnection)
        XCTAssertNil(controller.connectionTransition)
        XCTAssertEqual(controller.connectionModeError, String(localized: "Connect the headphones first."))
        let setup = controller.simulatedPendingFrame!
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: setup.sequence, payload: []))
        XCTAssertFalse(controller.canChangeConnectionMode)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.canChangeConnectionMode)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xE8, 0x05, 0x01, 0x00] })
        acknowledgeAll(controller)
    }

    @MainActor
    func testQueuedOrPartiallySubmittedModeCannotBeConfirmed() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.refreshEqualizer()
        controller.setConnectionMode(.stableConnection)
        XCTAssertEqual(controller.connectionTransition?.phase, .queued)
        deliver([0xE7, 0x05, 0x01], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .queued)
        controller.defersSimulatedWrites = true
        acknowledge(controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 0x05, 0x01, 0x00])
        XCTAssertEqual(controller.connectionTransition?.phase, .queued)
        acknowledge(controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .queued)
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        controller.defersSimulatedWrites = false
        controller.simulateControlLoss()
    }

    @MainActor
    func testOldReadbackCannotConfirmAfterAlertReplyAndUnknownAlertsDoNotPause() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        pollWithoutModeReadback(controller)
        controller.setConnectionMode(.stableConnection)
        acknowledge(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x99, 0x00, 0x76, 0x01], to: controller)
        deliver([0x99, 0x00, 0x77, 0xFF], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        deliver([0x99, 0x00, 0x77, 0x01], to: controller)
        let alert = try XCTUnwrap(controller.connectionTransition?.alert)
        controller.simulateConnectionModeTimeout()
        XCTAssertTrue(controller.connectionTransition?.awaitingUser == true)
        XCTAssertNil(controller.connectionModeError)
        controller.respondToConnectionAlert(alert, action: .positive)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0x00, 0x77, 0x01])
        acknowledge(controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE6, 0x05])
        deliver([0xE7, 0x05, 0x01], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        deliver([0xE7, 0x05, 0x01], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertEqual(controller.audioFeatures.codec, .aac)
        acknowledgeAll(controller, mode: 1)
        deliver([0x99, 0x00, 0x77, 0x01], to: controller)
        XCTAssertTrue(controller.connectionTransition?.awaitingUser == true)
        controller.simulateControlLoss()
    }

    @MainActor
    func testModeRequestWaitsForAlertWithoutReadbackOrPeriodicQueries() throws {
        let controller = preparedController()
        controller.setConnectionMode(.stableConnection)
        acknowledge(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        let waitingWrites = controller.simulatedTransmittedFrames
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedTransmittedFrames, waitingWrites)
        XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
        deliver([0x99, 0x00, 0x77, 0x01], to: controller)
        let alert = try XCTUnwrap(controller.connectionTransition?.alert)
        let alertWrites = controller.simulatedTransmittedFrames
        for _ in 0..<10 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedTransmittedFrames, alertWrites)
        controller.respondToConnectionAlert(alert, action: .positive)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0x00, 0x77, 0x01])
        acknowledge(controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE6, 0x05])
        acknowledgeAll(controller, mode: 1)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
    }

    @MainActor
    func testCrossModeRequiresBothConnectedAndVerifiedIdentity() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        deliver([0x15, 0x01, 0x01, 0xFF], to: controller)
        controller.setConnectionMode(.lowLatency)
        XCTAssertNil(controller.connectionTransition)
        XCTAssertEqual(controller.connectionModeError, String(localized: "Connect both earbuds first."))
        deliver([0x15, 0x01, 0x01, 0x01], to: controller)
        XCTAssertNil(controller.connectionModeUnavailableReason(.lowLatency))
        XCTAssertNil(controller.connectionModeUnavailableReason(.soundQuality))
        controller.setConnectionMode(.lowLatency)
        XCTAssertEqual(controller.connectionTransition?.targetMode, .lowLatency)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        let writes = controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }
        XCTAssertEqual(writes.count, 1)
    }

    @MainActor
    func testCompletedModeChangeDoesNotTurnLaterDisconnectionIntoRecovery() throws {
        for automatic in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
            defer { controller.simulateControlLoss() }
            controller.setReconnectAutomatically(automatic)
            controller.setConnectionMode(.stableConnection)
            let alert = try XCTUnwrap(controller.connectionTransition?.alert)
            controller.respondToConnectionAlert(alert, action: .positive)
            XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
            controller.simulateControlLoss(deviceConnected: false)
            XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertNil(controller.retrySecondsRemaining)
            XCTAssertNil(controller.connectionModeError)
            controller.simulateAutomaticRefresh(deviceConnected: true)
            XCTAssertEqual(controller.linkState, automatic ? .handshaking : .disconnected)
        }
    }

    @MainActor
    func testExplicitConnectReschedulesDirectiveRecoveryWithoutModeTransition() {
        for directive: UInt8 in [0x0D, 0x0F] {
            let controller = preparedController()
            defer { controller.simulateControlLoss() }
            deliver([0x49, directive], to: controller)
            XCTAssertNil(controller.connectionTransition)
            XCTAssertNotNil(controller.retrySecondsRemaining)
            controller.simulateControlLoss(deviceConnected: false)
            XCTAssertNil(controller.retrySecondsRemaining)
            let frames = controller.simulatedTransmittedFrames
            controller.connect()
            XCTAssertNotNil(controller.retrySecondsRemaining)
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertNil(controller.connectionTransition)
            XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
            XCTAssertEqual(controller.simulatedRecoveryHash, "ABCDEF12")
        }
    }

    @MainActor
    func testRFCOMMClosureSchedulesModeRecoveryWhenBluetoothLinkIsAlreadyGone() async throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        controller.setConnectionMode(.lowLatency)
        let channel = DeferredRFCOMMChannel()
        let device = ServiceDiscoveryDevice()
        device.service = ServiceDiscoveryRecord()
        device.channel = channel
        controller.simulateSonyLink(to: device)
        XCTAssertEqual(device.openedChannels, [7])
        device.connected = false
        controller.classicChannelClosed(channel)
        await fulfillment(of: [channel.closeFinished], timeout: 2)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertNotNil(controller.retrySecondsRemaining)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
    }

    @MainActor
    func testDirectedDisconnectWaitsForAckAndStaleSessionCannotRespond() {
        let controller = preparedController()
        controller.setConnectionMode(.lowLatency)
        acknowledgeAll(controller)
        let oldSession = controller.simulatedControlSession
        controller.defersSimulatedWrites = true
        deliver([0x49, 0x0F], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, oldSession)
        controller.completeSimulatedWrite()
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertGreaterThan(controller.simulatedControlSession, oldSession)
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.type, 0x01)
        controller.defersSimulatedWrites = false
        controller.simulateProtocolMessage([0x99, 0x06, 0x11, 0, 1], session: oldSession)
        XCTAssertNil(controller.connectionTransition?.alert)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
    }

    @MainActor
    func testMalformedOrUnverifiedProfileDirectivesDoNotTearDownControls() {
        let controller = preparedController()
        for payload: [UInt8] in [
            [0x49, 0x0D, 0], [0x49, 0x0F, 0], [0x49, 0x0E, 0],
            [0x49, 0x0E, 2] + Array("02:53:4F:4E:59:01".utf8),
            [0x49, 0x0E, 1] + Array("02:53:4F:4E:59:0Z".utf8),
        ] { deliver(payload, to: controller) }
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.connectionModeError)
        deliver([0x49, 0x0E, 0] + Array("11:22:33:44:55:66".utf8), to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionModeError, String(localized: "The requested control device could not be verified."))
    }

    @MainActor
    func testAutomaticUISimulationCancelsThenConfirmsWithoutChangingCodec() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        controller.setConnectionMode(.stableConnection)
        let cancelled = try XCTUnwrap(controller.connectionTransition?.alert)
        XCTAssertEqual(cancelled.messageID, 0x77)
        controller.respondToConnectionAlert(cancelled, action: .negative)
        XCTAssertEqual(controller.connectionTransition?.phase, .cancelled)
        XCTAssertEqual(controller.audioFeatures.connectionMode, .soundQuality)
        controller.setConnectionMode(.stableConnection)
        let accepted = try XCTUnwrap(controller.connectionTransition?.alert)
        controller.respondToConnectionAlert(accepted, action: .positive)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertEqual(controller.audioFeatures.connectionMode, .stableConnection)
        XCTAssertEqual(controller.audioFeatures.codec, .aac)
        controller.simulateControlLoss()
    }

    @MainActor
    func testRecoveryFailureReleasesPendingUIAndRetryRetainsIdentityWithoutSetterReplay() {
        let controller = preparedController()
        controller.setConnectionMode(.lowLatency)
        let originalAddress = controller.address
        controller.simulateControlLoss()
        controller.simulateRecoveryFailure()
        XCTAssertEqual(controller.connectionTransition?.phase, .failed)
        XCTAssertTrue(controller.connectionTransition?.isFinished == true)
        XCTAssertNotNil(controller.connectionModeError)
        controller.connect()
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertNil(controller.connectionModeError)
        XCTAssertEqual(controller.simulatedRecoveryAddress, originalAddress)
        XCTAssertEqual(controller.simulatedRecoveryHash, "ABCDEF12")
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
    }

    @MainActor
    func testFailedRecoveryDoesNotRestartFromAutomaticPolling() {
        let controller = preparedController()
        controller.setConnectionMode(.lowLatency)
        controller.simulateControlLoss()
        controller.simulateRecoveryFailure()
        let session = controller.simulatedControlSession
        let writes = controller.simulatedTransmittedFrames
        for _ in 0..<6 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.connectionTransition?.phase, .failed)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        XCTAssertEqual(controller.simulatedRecoveryHash, "ABCDEF12")
        XCTAssertNotNil(controller.connectionModeError)
        controller.connect()
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
    }

    @MainActor
    func testReconnectPreferenceAndRefreshPreserveExplicitRecovery() {
        for multipoint in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateBluetoothInitialization()
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            if multipoint {
                controller.setMultipointEnabled(false)
            } else {
                controller.setConnectionMode(.lowLatency)
            }
            controller.simulateControlLoss()
            controller.simulateScheduledRetry()
            let session = controller.simulatedControlSession
            let writes = controller.simulatedTransmittedFrames
            for enabled in [false, true] {
                controller.setReconnectAutomatically(enabled)
                controller.refresh()
                XCTAssertEqual(controller.simulatedReconnectAutomatically, enabled)
                XCTAssertEqual(controller.retrySecondsRemaining, 1)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
                if multipoint {
                    XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
                    XCTAssertTrue(controller.simulatedMultipointTimeoutPending)
                } else {
                    XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
                }
            }
            controller.simulateControlLoss()
            XCTAssertNil(controller.retrySecondsRemaining)
        }
    }

    @MainActor
    func testDisconnectedUnverifiedDevicesKeepOrdinaryConnectAndRefreshOnClassic() {
        for model: SonyDeviceModel in [.whXM3, .whXM4, .whCH520, .wfXM5, .srsNS7] {
            for automatic in [false, true] {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                defer { controller.simulateControlLoss() }
                let device = ServiceDiscoveryDevice()
                device.connected = false
                device.reportedName = model.name
                device.reportedAddress = "02:53:4F:4E:59:01"
                device.classicPeer = ConnectionPeerFixture(UUID())
                controller.simulateInventoryRefresh([device], shouldOpenLink: automatic)
                if !automatic { controller.refresh() }
                XCTAssertFalse(controller.usesBluetoothLE, model.name)
                XCTAssertEqual(controller.linkState, .disconnected, model.name)
                XCTAssertEqual(device.classicOpenCount, 0, model.name)
                XCTAssertFalse(controller.simulatePairedBluetoothLE(automatically: automatic), model.name)
                controller.connect()
                XCTAssertEqual(device.classicOpenCount, 1, model.name)
                XCTAssertFalse(controller.usesBluetoothLE, model.name)
                XCTAssertEqual(controller.linkState, .opening, model.name)
            }
        }
    }

    @MainActor
    func testDisconnectedVerifiedDeviceCanUseBLEWithoutPagingClassic() throws {
        let suite = "dev.baglayan.Acouplet.verified-routing-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identifier = UUID()
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "02:53:4F:4E:59:01", model: .wfXM5,
            hash: "ABCDEF12", peripheralIdentifier: identifier))
        SonyBLEIdentity.save(identity, in: defaults)
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        defer { controller.simulateControlLoss() }
        let device = ServiceDiscoveryDevice()
        device.connected = false
        device.reportedName = "My paired earbuds"
        device.reportedAddress = identity.classicAddress
        device.classicPeer = ConnectionPeerFixture(identifier)
        controller.simulateSelectedDevice(device)
        controller.connect()
        XCTAssertTrue(controller.usesBluetoothLE)
        XCTAssertEqual(device.classicOpenCount, 0)
        controller.simulateBluetoothLEReady(identifier: identifier, name: "LE_WF-1000XM5")
        XCTAssertEqual(controller.deviceName, "My paired earbuds")
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testExplicitLEAndConnectedClassicServiceFallbackAllowIdentityBoundBootstrap() async {
        for explicit in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            let identifier = UUID()
            let device = ServiceDiscoveryDevice()
            device.connected = !explicit
            device.reportedName = "WF-1000XM5"
            device.reportedAddress = "02:53:4F:4E:59:01"
            device.classicPeer = ConnectionPeerFixture(identifier)
            controller.simulateSelectedDevice(device)
            XCTAssertFalse(controller.simulatePairedBluetoothLE(automatically: false))
            if explicit {
                controller.connectBluetoothLE()
            } else {
                controller.simulateSonyLink(to: device)
                XCTAssertEqual(device.discoveryCallbacks.count, 1)
                device.complete()
                for _ in 0..<4 { await Task.yield() }
            }
            XCTAssertTrue(controller.usesBluetoothLE)
            XCTAssertEqual(device.classicOpenCount, 0)
            controller.simulateBluetoothLEReady(identifier: identifier, name: "LE_WF-1000XM5")
            XCTAssertEqual(controller.deviceName, "WF-1000XM5")
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])
        }
    }
    #endif

    @MainActor
    func testInventoryWithoutRequestedConnectionSettlesSearchingAndPreservesFailure() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let device = ServiceDiscoveryDevice()
        device.reportedName = "WH-1000XM3"
        device.reportedAddress = "02:53:4F:4E:59:01"
        controller.simulateInventoryRefresh([device], shouldOpenLink: false)
        XCTAssertTrue(controller.isDeviceConnected)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertTrue(device.openedChannels.isEmpty)
        XCTAssertTrue(device.discoveryCallbacks.isEmpty)
        controller.simulateSonyLink(to: device)
        XCTAssertEqual(controller.linkState, .opening)
        controller.simulateInventoryRefresh([device], shouldOpenLink: false)
        XCTAssertEqual(controller.linkState, .opening)
        controller.simulateHandshakeTimeout()
        for _ in 0..<4 { await Task.yield() }
        let state = controller.linkState
        let error = controller.lastErrorMessage
        XCTAssertNotNil(error)
        controller.simulateInventoryRefresh([device], shouldOpenLink: false)
        XCTAssertEqual(controller.linkState, state)
        XCTAssertEqual(controller.lastErrorMessage, error)
    }

    @MainActor
    func testAutomaticBLEFallbackRequiresConnectedClassicOrPriorReadyLE() throws {
        let suite = "dev.baglayan.Acouplet.automatic-ble-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "02:53:4F:4E:59:01", model: .wfXM5,
            hash: "ABCDEF12", peripheralIdentifier: UUID()))
        SonyBLEIdentity.save(identity, in: defaults)
        let scenarios: [(name: String, automatic: Bool, priorLE: Bool, classicConnected: Bool, opensLE: Bool)] = [
            ("Disconnected Classic refresh", true, false, false, false),
            ("Connected Classic service fallback", true, false, true, true),
            ("Explicit first LE connection", false, false, false, true),
            ("Explicit LE with Classic connected", false, false, true, true),
            ("Previously ready LE session", true, true, false, true),
            ("Previously ready LE with Classic connected", true, true, true, true),
        ]
        for scenario in scenarios {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.simulateControlLoss(deviceConnected: scenario.classicConnected)
            XCTAssertEqual(controller.simulatedSavedIdentity, identity)
            let session = controller.simulatedControlSession
            let writes = controller.simulatedTransmittedFrames
            XCTAssertEqual(controller.simulateBLEReconnectWait(automatic: scenario.automatic, priorBluetoothLE: scenario.priorLE,
                classicConnected: scenario.classicConnected), scenario.opensLE, scenario.name)
            if scenario.opensLE {
                XCTAssertGreaterThan(controller.simulatedControlSession, session, scenario.name)
                XCTAssertEqual(controller.linkState, .opening, scenario.name)
                XCTAssertTrue(controller.usesBluetoothLE, scenario.name)
            } else {
                XCTAssertEqual(controller.simulatedControlSession, session, scenario.name)
                XCTAssertEqual(controller.simulatedTransmittedFrames, writes, scenario.name)
                XCTAssertEqual(controller.linkState, .disconnected, scenario.name)
                XCTAssertFalse(controller.usesBluetoothLE, scenario.name)
                controller.simulateAutomaticRefresh()
                XCTAssertFalse(controller.usesBluetoothLE, scenario.name)
                if scenario.classicConnected {
                    XCTAssertEqual(controller.linkState, .handshaking, scenario.name)
                    XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0], scenario.name)
                } else {
                    XCTAssertEqual(controller.linkState, .disconnected, scenario.name)
                    XCTAssertEqual(controller.simulatedControlSession, session, scenario.name)
                }
            }
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testDisablingAutomaticReconnectPreservesManualBLEAttempt() {
        for automatic in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateBluetoothInitialization()
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            XCTAssertTrue(controller.simulatedReconnectAutomatically)
            if automatic {
                controller.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: true, classicConnected: false)
            } else {
                controller.connectBluetoothLE()
            }
            XCTAssertEqual(controller.linkState, .opening)
            XCTAssertTrue(controller.usesBluetoothLE)
            let session = controller.simulatedControlSession
            let writes = controller.simulatedTransmittedFrames

            controller.setReconnectAutomatically(false)
            controller.simulateAutomaticRefresh()
            XCTAssertFalse(controller.simulatedReconnectAutomatically)
            XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
            XCTAssertNil(controller.simulatedPendingFrame)
            if automatic {
                XCTAssertGreaterThan(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.linkState, .disconnected)
                XCTAssertFalse(controller.usesBluetoothLE)
            } else {
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.linkState, .opening)
                XCTAssertTrue(controller.usesBluetoothLE)
            }

            controller.stop()
            XCTAssertFalse(controller.usesBluetoothLE)
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        }
    }

    @MainActor
    func testDisablingIdleReconnectCancelsRetryButManualRefreshStillWorks() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateBluetoothInitialization()
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateControlLoss()
        controller.simulateScheduledRetry()
        controller.setReconnectAutomatically(false)
        XCTAssertNil(controller.retrySecondsRemaining)
        controller.simulateAutomaticRefresh()
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertFalse(controller.retryControlsIfNeeded())
        controller.refresh()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        XCTAssertEqual(controller.linkState, .handshaking)
        controller.simulateControlLoss()
    }

    @MainActor
    func testSleepDiscardsPendingChangesAndDefersInitializationUntilWake() async throws {
        for reconnect in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            controller.setDSEE(.off)
            controller.setEqualizerPreset(.off)
            controller.setAmbientLevel(17)
            let oldSession = controller.simulatedControlSession
            let submittedFrame = try XCTUnwrap(controller.simulatedPendingFrame)
            let writesBeforeSleep = controller.simulatedTransmittedFrames
            controller.systemWillSleep()
            let sleepingSession = controller.simulatedControlSession
            XCTAssertGreaterThan(sleepingSession, oldSession)
            controller.systemWillSleep()
            XCTAssertEqual(controller.simulatedControlSession, sleepingSession)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            XCTAssertNil(controller.simulatedPendingFrame)
            controller.completeSimulatedWrite()
            XCTAssertEqual(controller.simulatedTransmittedFrames, writesBeforeSleep + [submittedFrame])
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            XCTAssertNil(controller.simulatedPendingFrame)
            let writes = controller.simulatedTransmittedFrames
            controller.defersSimulatedWrites = false
            controller.simulateBluetoothInitialization()
            controller.setReconnectAutomatically(reconnect)
            controller.refresh()
            controller.connect()
            controller.connectBluetoothLE()
            controller.simulateAutomaticRefresh()
            controller.simulateProtocolMessage([0x67, 0x17, 1, 1, 0, 0, 17], session: oldSession)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(controller.simulatedControlSession, sleepingSession)
            XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
            XCTAssertEqual(controller.linkState, .disconnected)
            controller.systemDidWake()
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, reconnect ? [0, 0] : nil)
            XCTAssertEqual(controller.linkState, reconnect ? .handshaking : .disconnected)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            let wakeWrites = controller.simulatedTransmittedFrames
            controller.systemDidWake()
            XCTAssertEqual(controller.simulatedTransmittedFrames, wakeWrites)
        }
    }

    @MainActor
    func testSleepPreservesActiveRecoveryWithoutReplayingConnectionSetters() {
        for multipoint in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.setReconnectAutomatically(false)
            if multipoint { controller.setMultipointEnabled(false) }
            else { controller.setConnectionMode(.lowLatency) }
            let writes = controller.simulatedTransmittedFrames
            controller.systemWillSleep()
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.simulatedMultipointTimeoutPending)
            controller.simulateAutomaticRefresh()
            controller.systemDidWake()
            XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
            XCTAssertNil(controller.simulatedPendingFrame)
            if multipoint {
                XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
                XCTAssertTrue(controller.simulatedMultipointTimeoutPending)
            } else {
                XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
            }
        }
    }

    @MainActor
    func testWakeDoesNotReviveCompletedConnectionChangeWhenReconnectIsDisabled() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        defer { controller.simulateControlLoss() }
        controller.setReconnectAutomatically(false)
        controller.setConnectionMode(.stableConnection)
        let alert = try XCTUnwrap(controller.connectionTransition?.alert)
        controller.respondToConnectionAlert(alert, action: .positive)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        controller.systemWillSleep()
        XCTAssertNil(controller.connectionTransition)
        controller.systemDidWake()
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testExplicitRefreshRetainsVerifiedBLETargetWhenOptionalReadNeverReplies() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        let identifier = UUID()
        controller.simulateDeviceConnection(named: "WF-C510", controlBusy: true, peripheralIdentifier: identifier)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1],
            beginConnection: true, expectedBLEHash: "ABCDEF12", connectedPeripheralID: identifier)
        acknowledgeAll(controller)
        deliver([0x07, 0, 2, 0x14, 0, 0x20, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 4] + Array("00:11:22:33:44:55ABCDEF12".utf8), to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        controller.setReconnectAutomatically(false)
        let session = controller.simulatedControlSession
        controller.simulateBatteryReadTimeout([0x22, 0])
        for _ in 0..<4 { await Task.yield() }
        controller.refresh()
        XCTAssertTrue(controller.usesBluetoothLE)
        XCTAssertEqual(controller.linkState, .opening)
        XCTAssertFalse(controller.simulatedBLEWaitsForConnection)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNil(controller.retrySecondsRemaining)
        let openingSession = controller.simulatedControlSession
        controller.refresh()
        XCTAssertEqual(controller.simulatedControlSession, openingSession)
        controller.simulateBluetoothLEReady(identifier: identifier, name: "LE_WF-C510")
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0x07, 0, 2, 0x14, 0, 0x20, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 4] + Array("00:11:22:33:44:5512345678".utf8), to: controller)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.bluetoothLEError, String(localized: "The connected device did not match the selected headphones."))
        XCTAssertNil(controller.retrySecondsRemaining)
    }

    @MainActor
    func testExplicitRefreshReopensExpiredOptionalReadOnceAndAutomaticPollingKeepsReadyControls() async {
        for readKind in ["battery", "equalizer", "playback", "listeningLevel"] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.setReconnectAutomatically(false)
            switch readKind {
            case "battery": controller.simulateBatteryRefresh()
            case "equalizer": controller.refreshEqualizer()
            case "playback": controller.controlPlayback(.play)
            default: controller.refreshSoundPressure()
            }
            acknowledgeAll(controller)
            let session = controller.simulatedControlSession
            let reads = controller.simulatedTransmittedFrames.map(\.payload)
            switch readKind {
            case "battery":
                let queries = reads.filter { $0.first == 0x22 }
                XCTAssertFalse(queries.isEmpty)
                for query in queries { controller.simulateBatteryReadTimeout(query) }
            case "equalizer": controller.simulateEqualizerReadTimeout()
            case "playback":
                let queries = reads.filter { [0xA0, 0xA2, 0xA6].contains($0.first) }
                XCTAssertFalse(queries.isEmpty)
                for query in queries { controller.simulatePlaybackReadTimeout(query) }
            default: controller.simulateSoundPressureReadTimeout()
            }
            for _ in 0..<10 { await Task.yield() }
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady, readKind)
            XCTAssertEqual(controller.simulatedControlSession, session, readKind)
            controller.refresh()
            let freshSession = controller.simulatedControlSession
            XCTAssertGreaterThan(freshSession, session, readKind)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0], readKind)
            XCTAssertNil(controller.retrySecondsRemaining, readKind)
            for _ in 0..<10 {
                controller.refresh()
                controller.simulateAutomaticRefresh()
            }
            XCTAssertEqual(controller.simulatedControlSession, freshSession, readKind)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0], readKind)
        }
    }

    @MainActor
    func testExpiredOptionalReadsReopenControlsToVerifyConnectionWithoutReplayingSetter() async {
        for readKind in ["battery", "equalizer", "playback", "listeningLevel"] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            switch readKind {
            case "battery": controller.simulateBatteryRefresh()
            case "equalizer": controller.refreshEqualizer()
            case "playback": controller.controlPlayback(.play)
            default: controller.refreshSoundPressure()
            }
            acknowledgeAll(controller)
            let reads = controller.simulatedTransmittedFrames.map(\.payload)
            let session = controller.simulatedControlSession
            controller.setConnectionMode(.lowLatency)
            acknowledgeAll(controller)
            deliver([0xE9, 5, 2, 1], to: controller)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(controller.simulatedControlSession, session, readKind)
            XCTAssertEqual(controller.connectionTransition?.phase, .reconnecting, readKind)
            switch readKind {
            case "battery":
                let queries = reads.filter { $0.first == 0x22 }
                XCTAssertFalse(queries.isEmpty)
                for query in queries { controller.simulateBatteryReadTimeout(query) }
            case "equalizer": controller.simulateEqualizerReadTimeout()
            case "playback":
                let queries = reads.filter { [0xA0, 0xA2, 0xA6].contains($0.first) }
                XCTAssertFalse(queries.isEmpty)
                for query in queries { controller.simulatePlaybackReadTimeout(query) }
            default: controller.simulateSoundPressureReadTimeout()
            }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertGreaterThan(controller.simulatedControlSession, session, readKind)
            XCTAssertEqual(controller.linkState, .disconnected, readKind)
            XCTAssertEqual(controller.connectionTransition?.phase, .recovering, readKind)
            XCTAssertNotNil(controller.retrySecondsRemaining, readKind)
            XCTAssertNil(controller.simulatedPendingFrame, readKind)
            controller.simulateProtocolMessage([0xE7, 5, 2], session: session)
            XCTAssertEqual(controller.connectionTransition?.phase, .recovering, readKind)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 5, 2, 0] }.count, 1, readKind)
        }
    }

    @MainActor
    func testCrossModeVerifiesExistingTransportAfterOldReadbackAndPreservesLateAlert() async throws {
        let controller = preparedController()
        pollWithoutModeReadback(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x62, 0x17] })
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x66, 0x17] })
        deliver([0x63, 0x17, 0], to: controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x04, 2])
        deliver([0x05, 2, 5] + Array("1.0.0".utf8), to: controller)
        acknowledge(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.setConnectionMode(.lowLatency)
        acknowledge(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        let originalSession = controller.simulatedControlSession
        let originalAddress = controller.address
        deliver([0xE9, 0x05, 0x02, 0x01], to: controller)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, originalSession)
        XCTAssertEqual(controller.audioFeatures.codec, .aac)
        deliver([0xE7, 0x05, 0x02], to: controller)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, originalSession)
        XCTAssertEqual(controller.connectionTransition?.phase, .reconnecting)
        XCTAssertEqual(controller.simulatedModeReadbackCount, 0)
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x57, 0x00, EqualizerPreset.bassBoost.rawValue, 0x00], to: controller)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertEqual(controller.address, originalAddress)
        XCTAssertGreaterThan(controller.simulatedControlSession, originalSession)
        XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])
        deliver([0x99, 0x06, 0x11, 0x00, 0x01], to: controller)
        let alert = try XCTUnwrap(controller.connectionTransition?.alert)
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        controller.respondToConnectionAlert(alert, action: .positive)
        XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
        acknowledge(controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0x06, 0x11, 0x01])
        acknowledge(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
        deliver([0xE7, 0x05, 0x02], to: controller)
        XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
        deliver([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00], to: controller)
        acknowledgeAll(controller)
        let functions: [UInt8] = [0x6B, 0x11, 0x12, 0x14, 0x40, 0x44, 0x90, 0xE7]
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8), to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 0x01, 0x01, 0, 0, 10], to: controller)
        acknowledgeAll(controller, mode: 2)
        deliver([0x13, 2, 2], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
        XCTAssertEqual(controller.connectionTransition?.requiredStream, .leAudio)
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertEqual(controller.audioFeatures.codec, .aac)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x05, 0x02, 0x00] }.count, 1)
    }

    @MainActor
    private func beginLegacyQualityController(version: UInt8 = 0x40, deferQualityReads: Bool = false) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM4", controlBusy: true)
        negotiateLegacyQuality(to: controller, version: version, begin: true, deferQualityReads: deferQualityReads)
        return controller
    }

    @MainActor
    private func preparedLegacyQualityController(version: UInt8 = 0x40) -> SonyHeadphonesController {
        let controller = beginLegacyQualityController(version: version)
        acknowledgeAll(controller)
        deliverLegacyQuality(to: controller)
        deliver([0x05, 2, 5] + Array("1.0.0".utf8), to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.canChangeConnectionMode)
        return controller
    }

    @MainActor
    private func negotiateLegacyQuality(to controller: SonyHeadphonesController, version: UInt8 = 0x40,
                                        begin: Bool = false, deferQualityReads: Bool = false) {
        deliver([0x01, 0, version, 0], to: controller, begin: begin)
        acknowledgeAll(controller)
        let name = Array("WF-1000XM4".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0, 1], to: controller)
        deliver([0x07, 0, 2, 0x62, 0xE1], to: controller)
        acknowledgeAll(controller)
        deliverLegacyNoise(to: controller, deferQualityReads: deferQualityReads)
    }

    @MainActor
    private func deliverLegacyNoise(to controller: SonyHeadphonesController, deferQualityReads: Bool = false) {
        deliver([0x61, 2, 0, 2, 1, 2, 0, 20, 1, 20], to: controller)
        deliver([0x63, 2, 0], to: controller)
        if !deferQualityReads { acknowledgeAll(controller) }
        deliver([0x67, 2, 1, 0, 0, 1, 0, 12], to: controller)
        if deferQualityReads {
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x66, 2])
            controller.defersSimulatedWrites = true
            acknowledge(controller)
            controller.defersSimulatedWrites = false
        }
    }

    @MainActor
    private func deliverLegacyQuality(to controller: SonyHeadphonesController) {
        for payload: [UInt8] in [[0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] { deliver(payload, to: controller) }
    }

    @MainActor
    private func preparedController(identityDefaults: UserDefaults? = nil, supportsStandby: Bool = true,
                                    pinnedAddress: String? = nil) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: identityDefaults, pinnedAddress: pinnedAddress)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        deliver([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00], to: controller, begin: true)
        acknowledgeAll(controller)
        let name = Array("WF-1000XM5".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0, 1], to: controller)
        let functions: [UInt8] = [0x6B, 0x11, 0x12, 0x14, 0x40, 0x44, 0x50, 0x90, 0xE7].filter { $0 != 0x40 || supportsStandby }
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        deliver([0x51, 0, 6, 21, 2, 0x16, 0, 0xA0, 0], to: controller)
        deliver([0x53, 0, 0], to: controller)
        let metadata: [UInt8] = SonyEqualizerBand.legacy.flatMap {
            [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)]
        }
        deliver([0x5B, 0, 6] + metadata, to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8), to: controller)
        deliver([0x41, 0] + Array("02:53:4F:4E:59:0102:53:4F:4E:59:0202:53:4F:4E:59:05".utf8), to: controller)
        deliver([0x67, 0x17, 0x01, 0x01, 0, 0, 10], to: controller)
        acknowledgeAll(controller)
        controller.simulateProtocolMessage([0x07, 0, 0], type: 0x0E)
        deliverModeState(to: controller)
        deliver([0x13, 1, 1, 1], to: controller)
        deliver([0x13, 2, 2], to: controller)
        return controller
    }

    @MainActor
    private func deliverModeState(to controller: SonyHeadphonesController) {
        deliver([0xE1, 5, 3, 0, 1, 2, 1, 0], to: controller)
        deliver([0xE3, 5, 0, 0], to: controller)
        deliver([0xE7, 5, 0], to: controller)
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController, begin: Bool = false) {
        controller.simulateProtocolMessage(payload, beginConnection: begin)
    }

    @MainActor
    private func acknowledge(_ controller: SonyHeadphonesController) {
        guard let frame = controller.simulatedPendingFrame else { return }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
    }

    @MainActor
    private func pollWithoutModeReadback(_ controller: SonyHeadphonesController) {
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        var count = 0
        var readbacks = 0
        while let frame = controller.simulatedPendingFrame, count < 80 {
            if frame.payload == [0xE6, 0x05] { readbacks += 1 }
            acknowledge(controller)
            count += 1
        }
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(readbacks, 1)
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController, mode: UInt8 = 0) {
        var count = 0
        while let frame = controller.simulatedPendingFrame, count < 80 {
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            if frame.payload == [0xE6, 0x05] { deliver([0xE7, 0x05, mode], to: controller) }
            acknowledge(controller)
            count += 1
        }
        XCTAssertNil(controller.simulatedPendingFrame)
    }
}

private final class ServiceDiscoveryRecord: SonyServiceRecord {
    func getRFCOMMChannelID(_ channelID: UnsafeMutablePointer<BluetoothRFCOMMChannelID>!) -> IOReturn {
        channelID.pointee = 7
        return kIOReturnSuccess
    }
}

private final class ServiceDiscoveryDevice: NSObject, SonyBluetoothDevice, @unchecked Sendable {
    var connected = true
    var reportedName: String?
    var reportedAddress: String?
    @objc var classicPeer: NSObject?
    var classicOpenCount = 0
    var service: (any SonyServiceRecord)?
    var channel: (any RFCOMMChannel)?
    var discoveryStartStatus = kIOReturnSuccess
    var discoveryCallbacks: [any SonyServiceDiscoveryDelegate] = []
    var openedChannels: [BluetoothRFCOMMChannelID] = []
    var serviceLookups = 0
    var lookedUpUUIDs: [Data] = []
    /// When set, only this service UUID resolves, to model devices that publish just one Sony service.
    var serviceUUID: Data?
    var onOpen: (() -> Void)?

    func isClassicConnected() -> Bool { connected }
    func isPaired() -> Bool { true }
    var name: String! { reportedName }
    var addressString: String! { reportedAddress }

    func openConnection(_ target: Any!) -> IOReturn {
        classicOpenCount += 1
        return kIOReturnSuccess
    }

    func sonyServiceRecord(for uuid: IOBluetoothSDPUUID) -> (any SonyServiceRecord)? {
        serviceLookups += 1
        let bytes = Data(bytes: uuid.bytes, count: Int(uuid.length))
        lookedUpUUIDs.append(bytes)
        if let serviceUUID, serviceUUID != bytes { return nil }
        return service
    }

    func performSonySDPQuery(_ target: any SonyServiceDiscoveryDelegate) -> IOReturn {
        discoveryCallbacks.append(target)
        return discoveryStartStatus
    }

    func openSonyRFCOMMChannel(withChannelID channelID: BluetoothRFCOMMChannelID, delegate: Any) -> (IOReturn, (any RFCOMMChannel)?) {
        openedChannels.append(channelID)
        onOpen?()
        return (kIOReturnSuccess, channel)
    }

    func complete(_ index: Int = 0, status: IOReturn = kIOReturnSuccess) {
        Task { @MainActor in discoveryCallbacks[index].sonySDPQueryComplete(self, status: status) }
    }
}

private final class ConnectionPeerFixture: NSObject {
    @objc let identifier: NSUUID

    init(_ identifier: UUID) {
        self.identifier = identifier as NSUUID
    }
}

private final class DeferredRFCOMMChannel: RFCOMMChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedWrites: [Data] = []
    private var writeStatuses: [IOReturn] = []
    private var completedCloses = 0
    private let writeRelease = DispatchSemaphore(value: 0)
    private let blockOnlyFirst: Bool
    var writes: [Data] { lock.withLock { recordedWrites } }
    var closeCount: Int { lock.withLock { completedCloses } }
    let closeStarted = XCTestExpectation(description: "Native close started")
    let closeFinished = XCTestExpectation(description: "Native close finished")
    var closeRelease: DispatchSemaphore?

    init(blockOnlyFirst: Bool = false) {
        self.blockOnlyFirst = blockOnlyFirst
    }

    func isOpen() -> Bool { closeCount == 0 }
    func getMTU() -> BluetoothRFCOMMMTU { 1024 }
    func isTransmissionPaused() -> Bool { true }

    func finishWrite(status: IOReturn = kIOReturnSuccess) {
        lock.withLock { writeStatuses.append(status) }
        writeRelease.signal()
    }

    func writeAsync(_ data: UnsafeMutableRawPointer!, length: UInt16, refcon: UnsafeMutableRawPointer!) -> IOReturn {
        XCTFail("Native asynchronous writes can perform blocking I/O on the main queue")
        return kIOReturnError
    }

    func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn {
        XCTAssertFalse(Thread.isMainThread)
        let copied = Data(bytes: data, count: Int(length))
        let blocks = lock.withLock {
            recordedWrites.append(copied)
            return !blockOnlyFirst || recordedWrites.count == 1
        }
        if !blocks { return kIOReturnSuccess }
        guard writeRelease.wait(timeout: .now() + 5) == .success else {
            XCTFail("The test did not release the native write")
            return kIOReturnTimeout
        }
        XCTAssertEqual(Data(bytes: data, count: Int(length)), copied)
        return lock.withLock { writeStatuses.removeFirst() }
    }

    func setDelegate(_ delegate: Any!) -> IOReturn { kIOReturnSuccess }

    func close() -> IOReturn {
        XCTAssertFalse(Thread.isMainThread)
        closeStarted.fulfill()
        if let closeRelease { XCTAssertEqual(closeRelease.wait(timeout: .now() + 5), .success) }
        lock.withLock { completedCloses += 1 }
        closeFinished.fulfill()
        return kIOReturnSuccess
    }
}
