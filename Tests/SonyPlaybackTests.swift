import CoreAudio
import XCTest
@testable import Acouplet

final class SonyPlaybackTests: XCTestCase {
    @MainActor
    func testNegotiatedLegacyPlaybackUsesExactVolumeQueriesAndConfirmedWrites() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xA0 || $0.payload.first == 0xA2 || $0.payload.first == 0xA6 }.map(\.payload),
                       [[0xA0, 1], [0xA2, 1], [0xA6, 1, 0x20]])
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertEqual(controller.playback.volume, 12)
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlCallVolume)
        XCTAssertNil(controller.playback.musicCallStatus)
        controller.setPlaybackVolume(20)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 1, 0x20, 20])
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.playback.volume, 12)
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 20])
        XCTAssertEqual(controller.playback.volume, 20)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
    }

    @MainActor
    func testLegacyVolumeIgnoresOtherDialectAndUnownedReturns() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        for payload: [UInt8] in [[0xA1, 1, 41, 16], [0xA3, 1, 0, 1, 0], [0xA7, 0x20, 20],
                                [0xA9, 0x21, 7], [0xA7, 1, 0x20, 20], [0xA9, 1, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
            XCTAssertEqual(controller.playback.volume, 12)
            XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
            XCTAssertNil(controller.playback.callVolume)
            XCTAssertNil(controller.playback.musicCallStatus)
        }
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 20], type: 0x0E)
        XCTAssertEqual(controller.playback.volume, 12)
        controller.setCallVolume(5)
        controller.controlPlayback(.play)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testLegacyOldPollCannotConfirmANewerWrite() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        controller.setPlaybackVolume(20)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 20])
        XCTAssertEqual(controller.playback.volume, 12)
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 1, 0x20])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 20])
        XCTAssertEqual(controller.playback.volume, 20)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
    }

    @MainActor
    func testFreshVolumeReadReconcilesTimeoutWithoutConfirmingTheFailedWrite() async {
        for hasOldPoll in [false, true] {
            let controller = makeNoNoiseController(generation: .v1, functions: [0xA1, 0xE1])
            defer { controller.simulateControlLoss() }
            for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12],
                                    [0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] {
                controller.simulateProtocolMessage(payload)
            }
            XCTAssertTrue(controller.canChangeConnectionMode)
            if hasOldPoll {
                XCTAssertTrue(controller.refreshMusicVolume())
                acknowledgeSimulatedCommands(controller)
                controller.simulateProtocolMessage([0xA3, 1, 0, 2])
            }
            controller.setPlaybackVolume(20)
            acknowledgeSimulatedCommands(controller)
            controller.simulateSettingTimeout(.playbackVolume)
            for _ in 0..<4 { await Task.yield() }
            let issue = controller.settingErrors[.playbackVolume]
            XCTAssertNotNil(issue)
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertFalse(controller.canChangeConnectionMode)
            if hasOldPoll {
                controller.simulateProtocolMessage([0xA7, 1, 0x20, 14])
                XCTAssertEqual(controller.playback.volume, 12)
                XCTAssertFalse(controller.canChangeConnectionMode)
            } else {
                XCTAssertTrue(controller.refreshMusicVolume())
            }
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA7, 1, 0x20, 14])
            XCTAssertEqual(controller.playback.volume, 14)
            XCTAssertTrue(controller.canChangeConnectionMode)
            XCTAssertEqual(controller.settingErrors[.playbackVolume], issue)
        }
    }

    @MainActor
    func testLegacyQueuedVolumeCancellationAndDeferredNotificationRetainWriteOwnership() async throws {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertTrue(controller.refreshMusicVolume())
        let change = Task { @MainActor in
            try await controller.performConfirmedSettingChange(.playbackVolume) { controller.setPlaybackVolume(20) }
        }
        for _ in 0..<100 where controller.pendingChanges[.playbackVolume] == nil { await Task.yield() }
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        change.cancel()
        do { try await change.value; XCTFail("Cancelled legacy volume change completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 1, 0x20, 20] })
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertTrue(controller.isReady)
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        controller.defersSimulatedWrites = true
        controller.setPlaybackVolume(21)
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 21])
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [21])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [21])
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 21])
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertEqual(controller.playback.volume, 21)
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testLegacyVolumeAdmissionRefreshNeedsBothNewOwnedReadbacks() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.playback.generation, .v1)
        XCTAssertTrue(controller.refreshMusicVolume())
        controller.simulateProtocolMessage([0xA1, 1, 31, 1, 0])
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertNil(controller.musicStatusReadbackID)
        XCTAssertNil(controller.musicVolumeReadbackID)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        XCTAssertNotNil(controller.musicStatusReadbackID)
        XCTAssertNil(controller.musicVolumeReadbackID)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 12])
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        let status = controller.musicStatusReadbackID
        let volume = controller.musicVolumeReadbackID
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.refreshMusicVolume())
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 14]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertEqual(controller.musicStatusReadbackID, status)
        XCTAssertEqual(controller.musicVolumeReadbackID, volume)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        XCTAssertNotEqual(controller.musicStatusReadbackID, status)
        XCTAssertEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 14])
        XCTAssertNotEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        let latestStatus = controller.musicStatusReadbackID
        let latestVolume = controller.musicVolumeReadbackID
        controller.simulateProtocolMessage([0xA5, 1, 1, 2])
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 15])
        XCTAssertEqual(controller.musicStatusReadbackID, latestStatus)
        XCTAssertEqual(controller.musicVolumeReadbackID, latestVolume)
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        XCTAssertTrue(controller.refreshMusicVolume())
        controller.simulateControlLoss()
        XCTAssertNil(controller.musicStatusReadbackID)
        XCTAssertNil(controller.musicVolumeReadbackID)
        XCTAssertFalse(controller.refreshMusicVolume())
    }
    @MainActor
    func testLegacyAdmissionRefreshRetiresTimedOutReadsWithoutGrantingFreshness() async throws {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        let status = controller.musicStatusReadbackID
        let volume = controller.musicVolumeReadbackID
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(8100))
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertTrue(controller.refreshMusicVolume())
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 13]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertEqual(controller.musicStatusReadbackID, status)
        XCTAssertEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 14]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertNotEqual(controller.musicStatusReadbackID, status)
        XCTAssertNotEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertNil(controller.playbackReadError)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
    }
    #endif

    @MainActor
    func testRefreshWithoutNoiseControlsRenewsAdvertisedPlaybackBatteryAndEqualizer() {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let legacy = generation == .v1
            let controller = makeNoNoiseController(generation: generation, functions: legacy ? [0x11, 0x51, 0xA1] : [0x20, 0x50, 0xA1])
            defer { controller.simulateControlLoss() }
            let eqType: UInt8 = legacy ? 1 : 0
            let bands = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
            var replies: [[UInt8]] = [[0x51, eqType, 6, 21, 1, 0xA0, 0], [0x53, eqType, 0],
                                     [0x5B, eqType, 6] + bands, [0x57, eqType, 0xA0, 6, 10, 10, 10, 10, 10, 10],
                                     legacy ? [0x11, 0, 70, 0] : [0x23, 0, 70, 0],
                                     legacy ? [0xA1, 1, 31, 1, 0] : [0xA1, 1, 31, 16],
                                     legacy ? [0xA3, 1, 0, 2] : [0xA3, 1, 0, 2, 0],
                                     legacy ? [0xA7, 1, 0x20, 12] : [0xA7, 0x20, 12]]
            if !legacy { replies += [[0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x21, 7]] }
            for payload in replies {
                controller.simulateProtocolMessage(payload)
            }
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.canControlMusicVolume)
            XCTAssertEqual(controller.batteryLevel, 70)
            XCTAssertEqual(controller.equalizer.settings, .flat)
            XCTAssertNil(controller.simulatedPendingFrame)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            let status = controller.musicStatusReadbackID
            let volume = controller.musicVolumeReadbackID
            #endif
            let count = controller.simulatedTransmittedFrames.count
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let queries = controller.simulatedTransmittedFrames.dropFirst(count).filter { $0.type == 0x0C }.map(\.payload)
            XCTAssertEqual(queries, legacy ? [[0x10, 0], [0x56, 1], [0xA2, 1], [0xA6, 1, 0x20]]
                           : [[0x22, 0], [0x56, 0], [0xA2, 1], [0xA6, 1], [0xA6, 0x20], [0xA6, 0x21]])
            for payload: [UInt8] in [legacy ? [0x11, 0, 68, 0] : [0x23, 0, 68, 0],
                                    [0x57, eqType, 0xA0, 6, 11, 10, 10, 10, 10, 10],
                                    legacy ? [0xA3, 1, 0, 2] : [0xA3, 1, 0, 2, 0],
                                    legacy ? [0xA7, 1, 0x20, 14] : [0xA7, 0x20, 14]] {
                controller.simulateProtocolMessage(payload)
            }
            XCTAssertEqual(controller.batteryLevel, 68)
            XCTAssertEqual(controller.equalizer.settings?.values.first, 1)
            XCTAssertEqual(controller.playback.volume, 14)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertNotEqual(controller.musicStatusReadbackID, status)
            XCTAssertNotEqual(controller.musicVolumeReadbackID, volume)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            #endif
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    @MainActor
    func testRefreshWithoutNoiseControlsDoesNotInventUnadvertisedSettings() {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeNoNoiseController(generation: generation, functions: [])
            defer { controller.simulateControlLoss() }
            let count = controller.simulatedTransmittedFrames.count
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.simulatedTransmittedFrames.dropFirst(count).filter { $0.type == 0x0C }.isEmpty)
            XCTAssertNil(controller.batteryLevel)
            XCTAssertFalse(controller.equalizer.isSupported)
            XCTAssertFalse(controller.playback.isSupported)
            XCTAssertTrue(controller.availableNoiseModes.isEmpty)
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    func testCapturedWFRepliesAndAdvertisedDialect() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        XCTAssertEqual(playback.queryPayloads, [[0xA0, 1], [0xA2, 1], [0xA6, 1], [0xA6, 0x20], [0xA6, 0x21]])
        XCTAssertFalse(playback.canControl)
        XCTAssertTrue(playback.update([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0]))
        XCTAssertNil(playback.track?.title)
        XCTAssertTrue(playback.update([0xA7, 0x20, 12]))
        XCTAssertNil(playback.volume)
        XCTAssertTrue(playback.update([0xA1, 1, 31, 16]))
        XCTAssertEqual(playback.volume, 12)
        XCTAssertNil(playback.volumePayload(20))
        XCTAssertTrue(playback.update([0xA3, 1, 0, 2, 0]))
        XCTAssertEqual(playback.state, .paused)
        XCTAssertTrue(playback.canControl)
        for command in [SonyPlaybackCommand.play, .pause, .next, .previous] {
            XCTAssertEqual(playback.commandPayload(command), [0xA4, 1, 0, command.rawValue])
        }
        for volume in 0...30 { XCTAssertEqual(playback.volumePayload(volume), [0xA8, 0x20, UInt8(volume)]) }
        for volume in [Int.min, -1, 31, Int.max] { XCTAssertNil(playback.volumePayload(volume)) }
        var unsupported = SonyPlayback(supportedFunctions: [0xA2])
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        XCTAssertFalse(unsupported.update([0xA3, 1, 0, 2, 0]))
        XCTAssertFalse(unsupported.update([0xA1, 1, 31, 16]))
        XCTAssertFalse(unsupported.update([0xA7, 0x20, 12]))
        XCTAssertFalse(unsupported.update([0xA7, 0x21, 7]))
        XCTAssertNil(unsupported.commandPayload(.play))
        XCTAssertNil(unsupported.callVolumePayload(7))
    }

    func testMetadataHasFourByteCountedUTF8FieldsAndUnknownReportsClearText() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        let payload: [UInt8] = [0xA9, 1] + name("Şarkı 🎵") + name("Album") + name("Artist") + name("Unidentified field")
        XCTAssertTrue(playback.update(payload))
        XCTAssertEqual(playback.track?.title, "Şarkı 🎵")
        XCTAssertEqual(playback.track?.album, "Album")
        XCTAssertEqual(playback.track?.artist, "Artist")
        let prior = playback
        for count in 0..<payload.count {
            XCTAssertFalse(playback.update(Array(payload.prefix(count))))
            XCTAssertEqual(playback, prior)
        }
        for invalid in [payload + [0], [0xA7, 1, 2, 1, 0xFF, 1, 0, 1, 0, 1, 0], [0xA7, 1, 2, 255, 0]] {
            XCTAssertFalse(playback.update(invalid))
            XCTAssertEqual(playback, prior)
        }
        XCTAssertTrue(playback.update([0xA7, 1] + name("Old title", status: 0xFF) + name("", status: 1)
                                      + name("Old artist", status: 0) + name("", status: 1)))
        XCTAssertNil(playback.track?.title)
        XCTAssertNil(playback.track?.album)
        XCTAssertNil(playback.track?.artist)
    }

    func testVolumeCapabilitiesAreCountsAndNeverInventARange() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        playback.update([0xA3, 1, 0, 2, 0])
        playback.update([0xA7, 0x20, 0])
        playback.update([0xA7, 0x21, 0])
        XCTAssertNil(playback.musicVolumeRange)
        XCTAssertNil(playback.callVolumeRange)
        XCTAssertNil(playback.volume)
        XCTAssertNil(playback.callVolume)
        XCTAssertNil(playback.volumePayload(0))
        XCTAssertTrue(playback.update([0xA1, 1, 1, 255]))
        XCTAssertEqual(playback.musicVolumeRange, 0...0)
        XCTAssertEqual(playback.callVolumeRange, 0...254)
        XCTAssertEqual(playback.volume, 0)
        XCTAssertEqual(playback.callVolume, 0)
        XCTAssertEqual(playback.volumePayload(0), [0xA8, 0x20, 0])
        XCTAssertNil(playback.volumePayload(1))
        playback.update([0xA5, 1, 0, 0, 1])
        XCTAssertEqual(playback.callVolumePayload(254), [0xA8, 0x21, 254])
        for value in [Int.min, -1, 255, Int.max] { XCTAssertNil(playback.callVolumePayload(value)) }
        playback.update([0xA9, 0x21, 255])
        XCTAssertNil(playback.callVolume)
        XCTAssertNil(playback.callVolumePayload(0))
        playback.update([0xA7, 0x21, 254])
        XCTAssertEqual(playback.callVolume, 254)
        playback.update([0xA1, 1, 255, 1])
        XCTAssertEqual(playback.musicVolumeRange, 0...254)
        XCTAssertEqual(playback.callVolumeRange, 0...0)
        XCTAssertNil(playback.callVolume)
        playback.update([0xA9, 0x21, 0])
        XCTAssertEqual(playback.callVolumePayload(0), [0xA8, 0x21, 0])
    }

    func testVolumeContextIsSeparateFromMusicPlaybackState() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        playback.update([0xA1, 1, 31, 16])
        playback.update([0xA7, 0x20, 12])
        playback.update([0xA7, 0x21, 7])
        for state: UInt8 in [0, 1, 2, 3, 255] {
            playback.update([0xA5, 1, 0, state, 1])
            XCTAssertFalse(playback.canControl)
            XCTAssertFalse(playback.canControlMusicVolume)
            XCTAssertTrue(playback.canControlCallVolume)
            XCTAssertNil(playback.volumePayload(12))
            XCTAssertEqual(playback.callVolumePayload(15), [0xA8, 0x21, 15])
            XCTAssertNil(playback.callVolumePayload(16))
            playback.update([0xA5, 1, 0, state, 0])
            XCTAssertTrue(playback.canControlMusicVolume)
            XCTAssertFalse(playback.canControlCallVolume)
            XCTAssertEqual(playback.volumePayload(30), [0xA8, 0x20, 30])
            XCTAssertNil(playback.callVolumePayload(7))
        }
        playback.update([0xA9, 0x20, 31])
        XCTAssertNil(playback.volume)
        XCTAssertEqual(playback.callVolume, 7)
        XCTAssertFalse(playback.canControlMusicVolume)
    }

    func testUnavailableUnknownContextAndMalformedReportsPreserveHonestState() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        XCTAssertTrue(playback.update([0xA1, 1, 31, 16]))
        XCTAssertTrue(playback.update([0xA7, 0x20, 0]))
        XCTAssertTrue(playback.update([0xA7, 0x21, 0]))
        for status: [UInt8] in [[0xA3, 1, 1, 2, 0], [0xA5, 1, 0xFF, 2, 0],
                               [0xA5, 1, 1, 0, 1], [0xA5, 1, 0xFF, 1, 1], [0xA5, 1, 0, 1, 0xFF]] {
            XCTAssertTrue(playback.update(status))
            XCTAssertNil(playback.commandPayload(.next))
            XCTAssertNil(playback.volumePayload(1))
            XCTAssertNil(playback.callVolumePayload(1))
        }
        XCTAssertTrue(playback.update([0xA5, 1, 0, 1, 0]))
        XCTAssertEqual(playback.volumePayload(0), [0xA8, 0x20, 0])
        let prior = playback
        for invalid: [UInt8] in [[0xA3, 1, 0, 1], [0xA3, 1, 0, 1, 0, 0], [0xA5, 2, 0, 1, 0],
                                [0xA1, 1, 31], [0xA1, 1, 31, 16, 0], [0xA1, 1, 0, 16], [0xA1, 1, 31, 0],
                                [0xA1, 2, 31, 16], [0xA9, 1, 31, 16], [0xA7, 0x20], [0xA7, 0x20, 12, 0],
                                [0xA7, 0x21], [0xA9, 0x21, 12, 0], [0xA9, 0x30, 12], [0xA8, 0x20, 12]] {
            XCTAssertFalse(playback.update(invalid))
            XCTAssertEqual(playback, prior)
        }
        XCTAssertTrue(playback.update([0xA9, 0x20, 31]))
        XCTAssertNil(playback.volume)
        XCTAssertNil(playback.volumePayload(12))
    }

    @MainActor
    func testActionsAreSentOnceWithoutKeyReleaseAndAcknowledgmentIsNotPlaybackConfirmation() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        XCTAssertEqual(controller.pendingPlaybackCommand, .play)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA4, 1, 0, 7])
        controller.controlPlayback(.next)
        controller.setConnectionMode(.lowLatency)
        XCTAssertNil(controller.connectionTransition)
        XCTAssertNotNil(controller.sourceControlUnavailableReason)
        XCTAssertNotNil(controller.multipointUnavailableReason)
        acknowledgeSimulatedCommands(controller)
        XCTAssertNil(controller.pendingPlaybackCommand)
        XCTAssertEqual(controller.playback.state, .paused)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xA4 }.map(\.payload), [[0xA4, 1, 0, 7]])
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA2, 1] })
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA6, 1] })
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertEqual(controller.playback.state, .playing)
        controller.controlPlayback(.next)
        acknowledgeSimulatedCommands(controller)
        controller.controlPlayback(.next)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA4, 1, 0, 2] }.count, 2)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA4, 1, 0, 0] })
        controller.simulateControlLoss()
        XCTAssertFalse(controller.playback.isSupported)
        XCTAssertNil(controller.pendingPlaybackCommand)
    }

    @MainActor
    func testVolumeRequiresMatchingT1ReadbackAndDoesNotAcceptCallVolume() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setPlaybackVolume(0)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 0])
        XCTAssertEqual(controller.playback.volume, 12)
        acknowledgeSimulatedCommands(controller)
        for (type, payload): (UInt8, [UInt8]) in [(0x0E, [0xA9, 0x20, 0]), (0x0C, [0xA9, 0x21, 0]),
                                                 (0x0C, [0xA7, 0x20, 1]), (0x0C, [0xA7, 0x20, 31])] {
            controller.simulateProtocolMessage(payload, type: type)
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [0])
        }
        controller.simulateProtocolMessage([0xA9, 0x20, 0])
        XCTAssertEqual(controller.playback.volume, 0)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        controller.simulateControlLoss()
        XCTAssertNil(controller.playback.volume)
    }

    @MainActor
    func testCancelledQueuedMusicVolumeCannotTransmitWithUnchangedSource() async throws {
        for hasInventory in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: hasInventory ? nil : [])
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.multipoint.supportsInventory, hasInventory)
            XCTAssertTrue(controller.canControlMusicVolume)
            let source = controller.multipoint.selectedSource?.address
            let session = controller.simulatedControlSession
            controller.refreshEqualizer()
            let blocker = try XCTUnwrap(controller.simulatedPendingFrame)
            let change = Task { @MainActor in
                try await controller.performConfirmedSettingChange(.playbackVolume) { controller.setPlaybackVolume(20) }
            }
            for _ in 0..<100 where controller.pendingChanges[.playbackVolume] == nil { await Task.yield() }
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            XCTAssertEqual(controller.simulatedPendingFrame, blocker)
            change.cancel()
            do { try await change.value; XCTFail("Cancelled volume change completed") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.multipoint.selectedSource?.address, source)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    @MainActor
    func testRevokedMusicVolumeIntentCannotTransmitFromCommandOrTransportQueue() throws {
        for deferred in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            let source = controller.multipoint.selectedSource?.address
            let intent = UUID()
            var currentIntent = intent
            if deferred { controller.defersSimulatedWrites = true }
            else { controller.refreshEqualizer() }
            controller.setPlaybackVolume(20) { currentIntent == intent }
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            currentIntent = UUID()
            if deferred {
                controller.completeSimulatedWrite()
                controller.defersSimulatedWrites = false
            } else { acknowledgeSimulatedCommands(controller) }
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.multipoint.selectedSource?.address, source)
            XCTAssertTrue(controller.isReady)
            controller.setPlaybackVolume(21)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 21])
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 21] })
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA9, 0x20, 21])
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.playback.volume, 21)
        }
    }

    @MainActor
    func testDeferredUIVolumeCannotTransmitAfterSourceChangesBeforeItsFirstByte() {
        for selected: UInt8 in [2, 1] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            XCTAssertTrue(controller.canControlMusicVolume)
            controller.defersSimulatedWrites = true
            controller.setPlaybackVolume(20)
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
            if selected == 1 {
                controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
            }
            controller.completeSimulatedWrite()
            controller.defersSimulatedWrites = false
            for _ in 0..<20 { controller.completeSimulatedWrite() }
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.multipoint.selectedSource?.address, selected == 1 ? "02:00:00:00:00:01" : "02:00:00:00:00:02")
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    @MainActor
    func testCancellationAfterMusicVolumeTransmissionRetainsConfirmation() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        var isCurrent = true
        let change = Task { @MainActor in
            try await controller.performConfirmedSettingChange(.playbackVolume) {
                controller.setPlaybackVolume(20) { isCurrent }
            }
        }
        for _ in 0..<100 where controller.pendingChanges[.playbackVolume] == nil { await Task.yield() }
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
        isCurrent = false
        change.cancel()
        do { try await change.value; XCTFail("Cancelled volume change completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA9, 0x20, 20])
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertEqual(controller.playback.volume, 20)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testCallVolumeUsesItsOwnRangeAndMatchingT1ReportedConfirmation() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0xA5, 1, 0, 0, 1])
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertTrue(controller.canControlCallVolume)
        controller.setCallVolume(16)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.setCallVolume(0)
        XCTAssertEqual(controller.simulatedPendingFrame?.type, 0x0C)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x21, 0])
        XCTAssertEqual(controller.playback.callVolume, 7)
        XCTAssertFalse(controller.canControlCallVolume)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.pendingChanges[.callVolume], [0])
        for (type, payload): (UInt8, [UInt8]) in [(0x0E, [0xA9, 0x21, 0]), (0x0C, [0xA9, 0x20, 0]),
                                                 (0x0C, [0xA7, 0x21, 0, 0]), (0x0C, [0xA9, 0x21, 16]),
                                                 (0x0C, [0xA9, 0x21, 255]), (0x0C, [0xA7, 0x21, 1])] {
            controller.simulateProtocolMessage(payload, type: type)
            XCTAssertEqual(controller.pendingChanges[.callVolume], [0])
        }
        controller.simulateProtocolMessage([0xA9, 0x21, 0])
        XCTAssertEqual(controller.playback.callVolume, 0)
        XCTAssertNil(controller.pendingChanges[.callVolume])
        XCTAssertTrue(controller.canControlCallVolume)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xA8 }.map(\.payload), [[0xA8, 0x21, 0]])
        controller.simulateControlLoss()
        XCTAssertNil(controller.playback.callVolume)
        XCTAssertNil(controller.playback.callVolumeRange)
    }

    @MainActor
    func testQueuedCallVolumeAbortsWhenCallEndsOrReportedRangeShrinks() {
        for change: [UInt8] in [[0xA5, 1, 0, 2, 0], [0xA1, 1, 31, 8]] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.simulateProtocolMessage([0xA5, 1, 0, 0, 1])
            controller.refreshEqualizer()
            controller.setCallVolume(15)
            XCTAssertEqual(controller.pendingChanges[.callVolume], [15])
            controller.simulateProtocolMessage(change)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA8 })
            XCTAssertEqual(controller.lastErrorMessage, "Playback controls changed while waiting. Reconnect the headphones and try again.")
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA8 })
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testOldSourceCapabilityAndCallVolumeCannotInitializeTheNewSource() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        acknowledgeSimulatedCommands(controller)
        XCTAssertNil(controller.playback.musicVolumeRange)
        XCTAssertNil(controller.playback.callVolumeRange)
        controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
        controller.simulateProtocolMessage([0xA1, 1, 31, 16])
        XCTAssertNil(controller.playback.musicVolumeRange)
        XCTAssertNil(controller.playback.callVolumeRange)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA0, 1] }.count, 2)
        controller.simulateProtocolMessage([0xA1, 1, 41, 11])
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...40)
        XCTAssertEqual(controller.playback.callVolumeRange, 0...10)
        controller.simulateProtocolMessage([0xA7, 0x21, 9])
        XCTAssertNil(controller.playback.callVolume)
        controller.simulateProtocolMessage([0xA9, 0x21, 9])
        XCTAssertNil(controller.playback.callVolume)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 0x21] }.count, 2)
        controller.simulateProtocolMessage([0xA7, 0x21, 4])
        XCTAssertEqual(controller.playback.callVolume, 4)
        controller.simulateControlLoss()
    }

    @MainActor
    func testQueuedActionsAndVolumeAbortWhenACallStartsWithoutReplay() {
        for volume in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.refreshEqualizer()
            if volume { controller.setPlaybackVolume(15) } else { controller.controlPlayback(.next) }
            controller.simulateProtocolMessage([0xA5, 1, 0, 1, 1])
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA4 || $0.payload.first == 0xA8 })
            XCTAssertEqual(controller.lastErrorMessage, "Playback controls changed while waiting. Reconnect the headphones and try again.")
            XCTAssertNil(controller.pendingPlaybackCommand)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            XCTAssertNil(controller.pendingPlaybackCommand)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
    }

    @MainActor
    func testSourceChangeClearsPlaybackAndRequestsFreshStateWithoutConfirmingOldVolume() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0xA9, 1] + name("Mac track") + name("Album") + name("Artist") + name(""))
        controller.setPlaybackVolume(20)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        XCTAssertTrue(controller.playback.isSupported)
        XCTAssertNil(controller.playback.state)
        XCTAssertNil(controller.playback.volume)
        XCTAssertNil(controller.playback.track)
        XCTAssertFalse(controller.canControlPlayback)
        acknowledgeSimulatedCommands(controller)
        for query: [UInt8] in [[0xA0, 1], [0xA2, 1], [0xA6, 1], [0xA6, 0x20], [0xA6, 0x21]] {
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == query })
        }
        controller.simulateProtocolMessage([0xA9, 0x20, 20])
        XCTAssertNotNil(controller.pendingChanges[.playbackVolume])
        XCTAssertFalse(controller.canControlPlayback)
        controller.simulateControlLoss()
    }

    @MainActor
    func testSourceChangeDuringConnectionTransitionDefersPlaybackQueries() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setConnectionMode(.lowLatency)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        XCTAssertNil(controller.playback.state)
        XCTAssertFalse(controller.canControlPlayback)
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA2 || $0.payload.first == 0xA6 })
        controller.simulateControlLoss()
    }

    @MainActor
    func testOldSourceRepliesCannotRestorePlaybackBeforeReplacementReadsTransmit() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        XCTAssertNil(controller.playback.state)
        let stale: [UInt8] = [0xA3, 1, 0, 1, 0]
        controller.simulateProtocolMessage(stale)
        XCTAssertNil(controller.playback.state)
        controller.simulateProtocolMessage(stale)
        XCTAssertNil(controller.playback.state)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertNil(controller.playback.state)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA2, 1] }.count, 2)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertEqual(controller.playback.state, .paused)
        let staleTrack: [UInt8] = [0xA7, 1] + name("Mac track") + name("Album") + name("Artist") + name("")
        controller.simulateProtocolMessage(staleTrack)
        XCTAssertNil(controller.playback.track)
        acknowledgeSimulatedCommands(controller)
        let freshTrack: [UInt8] = [0xA7, 1] + name("Phone track") + name("Album") + name("Artist") + name("")
        controller.simulateProtocolMessage(freshTrack)
        XCTAssertEqual(controller.playback.track?.title, "Phone track")
        controller.simulateControlLoss()
    }

    @MainActor
    func testSameLinkHandshakeWaitsForOldPlaybackReplies() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        controller.setConnectionMode(.lowLatency)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xE9, 5, 2, 1])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .reconnecting)
        controller.simulateProtocolMessage([0xA3, 1, 0, 1, 0])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.simulateProtocolMessage([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        XCTAssertNil(controller.playbackReadError)
        controller.simulateControlLoss()
    }

    @MainActor
    func testMultipointRecoveryClosesLinkWithUnansweredPlaybackReads() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        controller.setMultipointEnabled(false)
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        XCTAssertFalse(controller.canCheckMultipointChange)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xD6, 0xD2])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xD7, 0xD2, 0, 0])
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.canCheckMultipointChange)
        controller.checkMultipointChange()
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertFalse(controller.isReady)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertNil(controller.playbackReadError)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testOptionalPlaybackTimeoutPreservesMusicVolumeAndFreshLDACReadback() async {
        for missing: [UInt8] in [[0xA6, 1], [0xA6, 0x21]] {
            let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
            defer { controller.simulateControlLoss() }
            let replies: [[UInt8]] = [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0],
                                     [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 12], [0xA7, 0x21, 7]]
            for payload in replies where controller.playback.queryPayload(for: payload) != missing {
                controller.simulateProtocolMessage(payload)
            }
            XCTAssertTrue(controller.canControlMusicVolume)
            controller.simulatePlaybackReadTimeout(missing)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNotNil(controller.playbackReadError)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canControlPlayback)
            XCTAssertTrue(controller.canControlMusicVolume)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            let previousReadback = controller.musicVolumeReadbackID
            #endif
            XCTAssertTrue(controller.refreshMusicVolume())
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
            controller.simulateProtocolMessage([0xA7, 0x20, 12])
            XCTAssertNotNil(controller.playbackReadError)
            XCTAssertTrue(controller.canControlMusicVolume)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            let readback = controller.musicVolumeReadbackID
            XCTAssertNotEqual(readback, previousReadback)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            #endif
            controller.setPlaybackVolume(20)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 20])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA9, 0x20, 20])
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.playback.volume, 20)
            for payload in replies where controller.playback.queryPayload(for: payload) == missing {
                controller.simulateProtocolMessage(payload)
            }
            XCTAssertNil(controller.playbackReadError)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertEqual(controller.musicVolumeReadbackID, readback)
            #endif
        }
    }

    @MainActor
    func testPlaybackVolumeTimeoutsOnlyBlockTheirOwnVolumeControl() async {
        for call in [false, true] {
            let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
            defer { controller.simulateControlLoss() }
            for payload: [UInt8] in [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, call ? 1 : 0],
                                    [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 12], [0xA7, 0x21, 7]] {
                controller.simulateProtocolMessage(payload)
            }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA3, 1, 0, 2, call ? 1 : 0])
            controller.simulateProtocolMessage([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0])
            let irrelevant: [UInt8] = [0xA6, call ? 0x20 : 0x21]
            let required: [UInt8] = [0xA6, call ? 0x21 : 0x20]
            controller.simulatePlaybackReadTimeout(irrelevant)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNotNil(controller.playbackReadError)
            XCTAssertEqual(controller.canControlMusicVolume, !call)
            XCTAssertEqual(controller.canControlCallVolume, call)
            controller.simulatePlaybackReadTimeout(required)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertFalse(controller.canControlMusicVolume)
            XCTAssertFalse(controller.canControlCallVolume)
            XCTAssertEqual(controller.canControlPlayback, !call)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
            XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
            #endif
        }
    }

    @MainActor
    func testPlaybackStatusTimeoutAndCallStateStillBlockMusicVolume() async {
        let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0],
                                [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 12], [0xA7, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
        }
        for state: UInt8 in [1, 2, 0xFF] {
            controller.simulateProtocolMessage([0xA5, 1, 0, 2, state])
            XCTAssertFalse(controller.canControlMusicVolume)
            XCTAssertFalse(controller.canControlPlayback)
            XCTAssertEqual(controller.canControlCallVolume, state == 1)
        }
        controller.simulateProtocolMessage([0xA5, 1, 0, 2, 0])
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 12])
        controller.simulatePlaybackReadTimeout([0xA2, 1])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canControlCallVolume)
        let frames = controller.simulatedTransmittedFrames
        controller.setPlaybackVolume(20)
        XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        #endif
    }

    @MainActor
    func testPlaybackCapabilityTimeoutBlocksControlsWithCachedVolumeRange() async {
        let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
        defer { controller.simulateControlLoss() }
        controller.refresh()
        controller.simulateProtocolMessage([0xA1, 1, 31, 16])
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA3, 1, 0, 2, 0], [0xA7, 0x20, 12],
                                [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
        }
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
        XCTAssertTrue(controller.canControlMusicVolume)
        controller.simulatePlaybackReadTimeout([0xA0, 1])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canControlCallVolume)
    }

    @MainActor
    func testMissingPlaybackReadStopsControlsWithoutRepeatedQueriesAndLateReplyRecovers() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(8_100))
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA2, 1] }.count, 1)
        controller.simulateProtocolMessage([0xA3, 1, 0, 1, 0])
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertTrue(controller.canControlPlayback)
        controller.simulateProtocolMessage([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0])
        XCTAssertNil(controller.playbackReadError)
        XCTAssertTrue(controller.canControlPlayback)
        controller.simulateControlLoss()
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testNativeLDACSourceWaitsForCurrentCapabilitiesAndLocalInventory() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        var addressLookups = 0
        func localAddress() -> String? {
            addressLookups += 1
            return "02:00:00:00:00:01"
        }
        XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 1)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0x05, 1, 10] + Array("WF-1000XM5".utf8), [0x05, 3, 0, 1],
                                [0x07, 0, 2, 0x6B, 0, 0xA1, 0],
                                [0x61, 0x17, 2, 0, 1, 20, 1, 1, 1, 20, 1],
                                [0x63, 0x17, 0], [0x67, 0x17, 1, 1, 0, 0, 10]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        for payload: [UInt8] in [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0], [0xA7, 0x20, 4]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        XCTAssertFalse(controller.multipoint.supportsInventory)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x06, 0] }.count, 1)
        controller.simulateProtocolMessage([0x07, 0, 1, 0x32, 0], type: 0x0E)
        XCTAssertTrue(controller.multipoint.supportsInventory)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 1)
        controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
        XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 2)
        controller.simulateProtocolMessage([0x07, 0, 0], type: 0x0E)
        XCTAssertTrue(controller.multipoint.supportsInventory)
        XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 3)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: "02:00:00:00:00:02"))
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: nil))
        controller.simulateProtocolMessage([0x39, 2, 1], type: 0x0E)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 3)
        controller.simulateControlLoss()
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 3)
    }

    @MainActor
    func testNativeLDACSourceAdmitsConfirmedEmptyOrAbsentCapabilityTable() {
        for advertised in [true, false] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            var addressLookups = 0
            func localAddress() -> String? {
                addressLookups += 1
                return nil
            }
            let protocolReply: [UInt8] = [0x01, 0, 3, 0, 0x30, 0x18, 0, advertised ? 0 : 1]
            controller.simulateProtocolMessage(protocolReply, beginConnection: true)
            XCTAssertEqual(controller.hasCurrentMusicSourceContext(for: localAddress()), !advertised)
            XCTAssertEqual(addressLookups, 0)
            acknowledgeSimulatedCommands(controller)
            for payload: [UInt8] in [[0x05, 1, 10] + Array("WF-1000XM5".utf8), [0x05, 3, 0, 1], [0x07, 0, 0]] {
                controller.simulateProtocolMessage(payload)
            }
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x06, 0] }.count, advertised ? 1 : 0)
            controller.simulateProtocolMessage([0x07, 0, 1], type: 0x0E)
            XCTAssertEqual(controller.hasCurrentMusicSourceContext(for: localAddress()), !advertised)
            XCTAssertEqual(addressLookups, 0)
            controller.simulateProtocolMessage([0x07, 0, 0], type: 0x0E)
            XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
            XCTAssertEqual(addressLookups, 0)
            controller.simulateProtocolMessage([0x07, 0, 1, 0x32, 0], type: 0x0E)
            XCTAssertTrue(controller.supportedFunctions2.isEmpty)
            XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
            XCTAssertEqual(addressLookups, 0)
            controller.simulateProtocolMessage(protocolReply, beginConnection: true)
            XCTAssertEqual(controller.hasCurrentMusicSourceContext(for: localAddress()), !advertised)
            XCTAssertEqual(addressLookups, 0)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testNativeLDACVolumeContextSurvivesPendingWriteAndRejectsSourceOrCallLoss() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA1, 1, 41, 16], [0xA3, 1, 0, 2, 0], [0xA7, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertNotNil(controller.musicVolumeReadbackID)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        XCTAssertTrue(controller.beginHeadGesturePractice())
        let practice = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
        XCTAssertTrue(controller.isRunningHeadphoneTest)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertFalse(controller.canPerformConfirmedSettingChange(.playbackVolume))
        let writes = controller.simulatedTransmittedFrames
        controller.setPlaybackVolume(19)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 1])
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage([0xF3, 0x10, 0])
        acknowledgeSimulatedCommands(controller)
        controller.cancelHeadGesturePractice(id: practice)
        controller.dismissHeadGesturePractice(id: practice)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        let readback = controller.musicVolumeReadbackID
        controller.setPlaybackVolume(20)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 20])
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        controller.simulateProtocolMessage([0xA9, 0x20, 20])
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        controller.refresh()
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 20])
        XCTAssertNotEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 1])
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateControlLoss()
        XCTAssertNil(controller.musicVolumeReadbackID)
    }

    func testNativeLDACAdmissionRejectsAliveButHiddenOrIneligibleOutput() {
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 1, defaultOutput: 0, systemOutput: 0))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 1, defaultOutput: 1, systemOutput: 1))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 0, defaultOutput: 0, systemOutput: 1))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 0, defaultOutput: 1, systemOutput: 0))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 0, hidden: 0, defaultOutput: 1, systemOutput: 1))
        XCTAssertTrue(LDACNativeOutput.canSelect(alive: 1, hidden: 0, defaultOutput: 1, systemOutput: 1))
    }

    func testNativeLDACControlsUseReportedRangeAndOnlyRestoreOwnedRoutes() {
        let controls = LDACNativeVolume(scalar: 0.5, muted: false)
        XCTAssertEqual(controls.volume(in: 0...40), 20)
        XCTAssertEqual(controls.volume(in: 0...254), 127)
        XCTAssertEqual(controls.volume(in: 0...0), 0)
        XCTAssertEqual(LDACNativeVolume.scalar(for: 12, range: 0...40), 0.3, accuracy: 0.00001)
        XCTAssertEqual(LDACNativeVolume.scalar(for: 0, range: 0...0), 0)
        XCTAssertTrue(LDACNativeVolume.shouldRestore(currentUID: LDACNativeOutput.uid, savedUID: "Sony-native"))
        XCTAssertFalse(LDACNativeVolume.shouldRestore(currentUID: "New-user-output", savedUID: "Sony-native"))
        XCTAssertFalse(LDACNativeVolume.shouldRestore(currentUID: LDACNativeOutput.uid, savedUID: LDACNativeOutput.uid))
    }

    func testNativeLDACTransfersVolumeAndMuteOnlyForTheTargetBluetoothOutput() {
        let address = "02:53:4F:4E:59:01"
        for uid in [address, "02-53-4f-4e-59-01", address + ":output"] {
            XCTAssertTrue(LDACNativeOutput.canTransferControls(uid: uid, transport: kAudioDeviceTransportTypeBluetooth, address: address))
        }
        for uid in ["BuiltInSpeakerDevice", "USB-DAC", "02:53:4F:4E:59:02:output", address + "0", "", "invalid-address!!"] {
            XCTAssertFalse(LDACNativeOutput.canTransferControls(uid: uid, transport: kAudioDeviceTransportTypeBluetooth, address: address))
        }
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetoothLE,
                          kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate] {
            XCTAssertFalse(LDACNativeOutput.canTransferControls(uid: address, transport: transport, address: address))
        }
        XCTAssertFalse(LDACNativeOutput.canTransferControls(uid: address, transport: kAudioDeviceTransportTypeBluetooth, address: ""))
    }
    #endif

    @MainActor
    private func makeNoNoiseController(generation: SonyProtocolInfo.Generation, functions: [UInt8]) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        // WH-1000XM3 keeps every advertised v1 function; the WH-1000XM4 hides the unverified ones.
        controller.simulateDeviceConnection(named: "WH-1000XM3")
        let protocolPayload: [UInt8] = generation == .v1 ? [0x01, 0, 2, 0x10] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 1]
        controller.simulateProtocolMessage(protocolPayload, beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let payload = [0x07, 0, UInt8(functions.count)] + (generation == .v1 ? functions : functions.flatMap { [$0, 0] })
        controller.simulateProtocolMessage(payload)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
        XCTAssertEqual(controller.protocolInformation?.generation, generation)
        XCTAssertTrue(controller.availableNoiseModes.isEmpty)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    @MainActor
    private func makeLegacyPlaybackController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM4")
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x07, 0, 1, 0xA1])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func sourceInventory(selected: UInt8) -> [UInt8] {
        let entries: [UInt8] = [("02:00:00:00:00:01", UInt8(1), "MacBook Pro"), ("02:00:00:00:00:02", UInt8(2), "Phone")]
            .flatMap { address, id, title in Array(address.utf8) + [id, 0x2A, 0x41, 4, UInt8(title.utf8.count)] + Array(title.utf8) }
        return [0x39, 2, 2] + entries + [selected]
    }

    private func name(_ value: String, status: UInt8 = 2) -> [UInt8] {
        [status, UInt8(value.utf8.count)] + Array(value.utf8)
    }
}
