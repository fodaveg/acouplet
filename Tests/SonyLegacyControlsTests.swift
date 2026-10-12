import XCTest
@testable import Acouplet

final class SonyLegacyControlsTests: XCTestCase {
    func testLegacyFunctionListAndBatteryCommandsStaySeparateFromV2() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 4, 0x11, 0x15, 0x18, 0x62]))
        XCTAssertEqual(controls.batteryQueries, [[0x10, 0], [0x10, 1], [0x10, 2]])
        XCTAssertEqual(controls.noiseQueries, [[0x60, 2], [0x62, 2], [0x66, 2]])
        XCTAssertNil(SonyLegacyControls(supportPayload: [0x07, 0, 2, 0x11, 1, 0x62, 1]))
        XCTAssertTrue(controls.update([0x11, 0x01, 73, 0, 84, 1]))
        XCTAssertEqual(controls.batteries.left?.level, 73)
        XCTAssertEqual(controls.batteries.right?.isCharging, true)
        XCTAssertTrue(controls.update([0x13, 0x02, 62, 0]))
        XCTAssertEqual(controls.batteries.caseBattery?.level, 62)
        let prior = controls
        XCTAssertFalse(controls.update([0x23, 0x09, 73, 0, 84, 1]))
        XCTAssertFalse(controls.update([0x11, 0x01, 73, 0, 84]))
        XCTAssertEqual(controls, prior)
    }

    func testDualSingleNoiseWritesUseAdvertisedTypesAndLimits() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0x62]))
        XCTAssertNil(controls.noiseControlPayload(mode: .anc, ambientLevel: 10, focusOnVoice: false))
        XCTAssertTrue(controls.update([0x61, 0x02, 0x02, 3, 0x01, 2, 0, 20, 1, 15]))
        XCTAssertTrue(controls.update([0x67, 0x02, 1, 2, 0, 1, 0, 12]))
        XCTAssertFalse(controls.canSetNoiseControl)
        XCTAssertTrue(controls.update([0x63, 0x02, 0]))
        XCTAssertTrue(controls.canSetNoiseControl)
        XCTAssertEqual(controls.noiseState?.mode, .ambient)
        XCTAssertEqual(controls.noiseControlPayload(mode: .anc, ambientLevel: 12, focusOnVoice: false), [0x68, 2, 1, 2, 2, 1, 0, 0])
        XCTAssertEqual(controls.noiseControlPayload(mode: .wind, ambientLevel: 12, focusOnVoice: false), [0x68, 2, 1, 2, 1, 1, 0, 0])
        XCTAssertEqual(controls.noiseControlPayload(mode: .ambient, ambientLevel: 15, focusOnVoice: true), [0x68, 2, 1, 2, 0, 1, 1, 15])
        XCTAssertNil(controls.noiseControlPayload(mode: .ambient, ambientLevel: 16, focusOnVoice: true))
        XCTAssertNil(controls.noiseControlPayload(mode: .ambient, ambientLevel: 0, focusOnVoice: false))
        XCTAssertEqual(controls.noiseControlPayload(mode: .off, ambientLevel: 0, focusOnVoice: false), [0x68, 2, 0, 2, 0, 1, 0, 12])
    }

    func testLegacyBatteryZeroIsAReadingAndUnknownChargingIsNotFalse() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 2, 0x15, 0x18]))
        XCTAssertTrue(controls.update([0x11, 1, 0, 0, 64, 0]))
        XCTAssertEqual(controls.batteries.left?.level, 0)
        XCTAssertEqual(controls.batteries.right?.level, 64)
        XCTAssertTrue(controls.update([0x13, 1, 52, 0xF0, 65, 1]))
        XCTAssertEqual(controls.batteries.left?.level, 52)
        XCTAssertEqual(controls.batteries.left?.chargingState, .unknown)
        XCTAssertEqual(controls.batteries.right?.isCharging, true)
        XCTAssertTrue(controls.update([0x13, 2, 77, 0xF0]))
        XCTAssertEqual(controls.batteries.caseBattery?.level, 77)
        XCTAssertEqual(controls.batteries.caseBattery?.chargingState, .unknown)
        XCTAssertTrue(controls.update([0x13, 1, 52, 2, 65, 3]))
        XCTAssertNil(controls.batteries.left)
        XCTAssertNil(controls.batteries.right)
        XCTAssertFalse(controls.update([0x11, 0, 90, 0]))
        XCTAssertNil(controls.batteries.single)
    }


    func testOnOffNoiseCapabilityDoesNotInventWindOrVoiceFocus() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0x62]))
        XCTAssertTrue(controls.update([0x61, 2, 0, 2, 0, 1, 0, 2]))
        XCTAssertTrue(controls.update([0x63, 2, 0]))
        XCTAssertTrue(controls.update([0x67, 2, 1, 0, 1, 0, 0, 0]))
        XCTAssertEqual(controls.noiseState?.mode, .anc)
        XCTAssertEqual(controls.noiseControlPayload(mode: .ambient, ambientLevel: 1, focusOnVoice: false), [0x68, 2, 1, 0, 0, 0, 0, 1])
        XCTAssertNil(controls.noiseControlPayload(mode: .wind, ambientLevel: 1, focusOnVoice: false))
        XCTAssertNil(controls.noiseControlPayload(mode: .ambient, ambientLevel: 1, focusOnVoice: true))
        XCTAssertNil(controls.noiseControlPayload(mode: .ambient, ambientLevel: 2, focusOnVoice: false))
    }

    func testMalformedAndUnavailableStatesCannotProduceWrites() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0x62]))
        XCTAssertFalse(controls.update([0x61, 2, 2, 3, 1, 2, 0, 20]))
        XCTAssertFalse(controls.update([0x61, 2, 2, 3, 1, 2, 0, 20, 0, 20]))
        XCTAssertTrue(controls.update([0x61, 2, 2, 3, 1, 1, 0, 20]))
        XCTAssertTrue(controls.update([0x63, 2, 0]))
        XCTAssertTrue(controls.update([0x67, 2, 1, 2, 2, 1, 0, 0]))
        XCTAssertTrue(controls.canSetNoiseControl)
        XCTAssertTrue(controls.update([0x65, 2, 1]))
        XCTAssertNil(controls.noiseControlPayload(mode: .off, ambientLevel: 10, focusOnVoice: false))
        XCTAssertTrue(controls.update([0x65, 2, 0xFF]))
        XCTAssertNil(controls.noiseAvailable)
        XCTAssertTrue(controls.update([0x65, 2, 0]))
        XCTAssertTrue(controls.update([0x69, 2, 0xFF, 2, 2, 1, 0, 0]))
        XCTAssertNil(controls.noiseState?.mode)
        XCTAssertFalse(controls.canSetNoiseControl)
        XCTAssertTrue(controls.update([0x61, 2, 1, 20, 1, 1, 0, 20]))
        XCTAssertTrue(controls.noiseCapability?.modes.isEmpty == true)
    }

    func testOffAndStaleCapabilityStatesDoNotBypassWireValidation() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0x62]))
        XCTAssertTrue(controls.update([0x61, 2, 2, 3, 1, 1, 0, 20]))
        XCTAssertTrue(controls.update([0x63, 2, 0]))
        XCTAssertTrue(controls.update([0x67, 2, 0, 2, 0xFF, 1, 0, 12]))
        XCTAssertNil(controls.noiseState?.mode)
        XCTAssertFalse(controls.canSetNoiseControl)
        XCTAssertTrue(controls.update([0x67, 2, 0, 2, 0, 1, 0, 12]))
        XCTAssertTrue(controls.canSetNoiseControl)
        XCTAssertTrue(controls.update([0x61, 2, 2, 3, 1, 1, 0, 10]))
        XCTAssertNil(controls.noiseControlPayload(mode: .off, ambientLevel: 10, focusOnVoice: false))
        XCTAssertTrue(controls.update([0x61, 2, 0, 2, 0, 1, 0, 2]))
        XCTAssertTrue(controls.update([0x67, 2, 0, 0, 0, 0, 0, 2]))
        XCTAssertNil(controls.noiseState?.mode)
        XCTAssertFalse(controls.canSetNoiseControl)
    }

    func testLegacyDSEEUsesAdvertisedTypeAndExplicitSettingType() {
        for (raw, expected) in [(UInt8(0), SonyDSEEType.hx), (1, .dsee), (2, .extreme)] {
            var dsee = SonyLegacyDSEE(isSupported: true)
            XCTAssertEqual(dsee.queryPayloads, [[0xE0, 2], [0xE2, 2], [0xE6, 2]])
            XCTAssertTrue(dsee.update([0xE1, 2, raw, 0]))
            XCTAssertEqual(dsee.type, expected)
            XCTAssertTrue(dsee.update([0xE3, 2, 0]))
            XCTAssertNil(dsee.setPayload(.automatic))
            XCTAssertTrue(dsee.update([0xE7, 2, 0, 0]))
            XCTAssertEqual(dsee.setPayload(.automatic), [0xE8, 2, 0, 1])
            XCTAssertEqual(dsee.setPayload(.off), [0xE8, 2, 0, 0])
            XCTAssertEqual(dsee.queryPayloads, [[0xE2, 2], [0xE6, 2]])
            XCTAssertFalse(dsee.acceptsSetPayload([0xE8, 1, 1]))
            XCTAssertFalse(dsee.acceptsSetPayload([0xE8, 2, 1, 1]))
            XCTAssertFalse(dsee.acceptsSetPayload([0xE8, 2, 0, 0xFF]))
        }
    }

    func testLegacyDSEEUnknownCapabilitiesAndStatusRemainNonWritable() {
        var dsee = SonyLegacyDSEE(isSupported: true)
        XCTAssertTrue(dsee.update([0xE1, 2, 3, 0]))
        XCTAssertTrue(dsee.update([0xE3, 2, 0]))
        XCTAssertTrue(dsee.update([0xE7, 2, 0, 0]))
        XCTAssertEqual(dsee.rawType, 3)
        XCTAssertNil(dsee.type)
        XCTAssertFalse(dsee.canSet)
        XCTAssertTrue(dsee.update([0xE1, 2, 0, 1]))
        XCTAssertFalse(dsee.canSet)
        XCTAssertTrue(dsee.update([0xE1, 2, 0, 0]))
        XCTAssertTrue(dsee.canSet)
        XCTAssertTrue(dsee.update([0xE9, 2, 1, 1]))
        XCTAssertFalse(dsee.canSet)
        XCTAssertTrue(dsee.update([0xE9, 2, 0, 0xFF]))
        XCTAssertEqual(dsee.mode, .unknown(0xFF))
        XCTAssertFalse(dsee.canSet)
        XCTAssertTrue(dsee.update([0xE9, 2, 0, 1]))
        XCTAssertTrue(dsee.update([0xE5, 2, 1]))
        XCTAssertEqual(dsee.available, false)
        XCTAssertFalse(dsee.canSet)
        XCTAssertTrue(dsee.update([0xE5, 2, 0xFF]))
        XCTAssertNil(dsee.available)
        XCTAssertFalse(dsee.canSet)
    }

    func testLegacyDSEERejectsUnadvertisedTruncatedAndV2Messages() {
        var dsee = SonyLegacyDSEE(isSupported: false)
        XCTAssertTrue(dsee.queryPayloads.isEmpty)
        XCTAssertFalse(dsee.update([0xE1, 2, 0, 0]))
        dsee = SonyLegacyDSEE(isSupported: true)
        let malformed: [[UInt8]] = [[0xE1, 2, 0], [0xE7, 2, 1], [0xE3, 2, 0, 0], [0xE1, 1, 0], [0xE9, 1, 1]]
        for payload in malformed {
            XCTAssertFalse(dsee.update(payload))
        }
        XCTAssertNil(dsee.rawType)
        XCTAssertNil(dsee.mode)
        XCTAssertNil(dsee.available)
    }

    func testLegacyConnectionQualityRequiresE1AndAdvertisedTypeForBothTypedChoices() throws {
        var unsupported = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 2, 0xE2, 0xE7]))
        XCTAssertFalse(unsupported.connectionQuality.isSupported)
        XCTAssertTrue(unsupported.connectionQuality.queryPayloads.isEmpty)
        for payload: [UInt8] in [[0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] {
            XCTAssertFalse(unsupported.update(payload))
        }
        XCTAssertFalse(unsupported.allows([0xE0, 1]))
        XCTAssertFalse(unsupported.allows([0xE8, 1, 0, 1]))
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0xE1]))
        XCTAssertEqual(controls.connectionQuality.queryPayloads, [[0xE0, 1], [0xE2, 1], [0xE6, 1]])
        for query in controls.connectionQuality.queryPayloads { XCTAssertTrue(controls.allows(query)) }
        XCTAssertFalse(controls.allows([0xE8, 1, 0, 1]))
        XCTAssertTrue(controls.update([0xE7, 1, 0, 0]))
        XCTAssertTrue(controls.update([0xE3, 1, 0]))
        XCTAssertNil(controls.connectionQuality.supportedModes)
        XCTAssertFalse(controls.connectionQuality.canSet)
        XCTAssertTrue(controls.update([0xE1, 1, 0]))
        XCTAssertEqual(controls.connectionQuality.supportedModes, [.soundQuality, .stableConnection])
        XCTAssertEqual(controls.connectionQuality.queryPayloads, [[0xE2, 1], [0xE6, 1]])
        let prior = controls
        for (mode, value) in [(SonyConnectionMode.soundQuality, UInt8(0)), (.stableConnection, 1)] {
            let payload: [UInt8] = [0xE8, 1, 0, value]
            XCTAssertEqual(controls.connectionQuality.setPayload(mode), payload)
            XCTAssertTrue(controls.connectionQuality.acceptsSetPayload(payload))
            XCTAssertTrue(controls.allows(payload))
        }
        XCTAssertEqual(controls, prior)
        XCTAssertNil(controls.connectionQuality.setPayload(.lowLatency))
        XCTAssertFalse(controls.allows([0xE8, 1, 0, 2]))
        XCTAssertFalse(controls.allows([0xE8, 5, 0, 1]))
        XCTAssertFalse(controls.allows([0xE8, 1, 1]))
    }

    func testLegacyConnectionQualityUnknownsNeverBecomeLowLatencyOrWritableDefaults() {
        var quality = SonyLegacyConnectionQuality(isSupported: true)
        for payload: [UInt8] in [[0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] {
            XCTAssertTrue(quality.update(payload))
        }
        XCTAssertTrue(quality.canSet)
        for value: UInt8 in [2, 0xFF] {
            var unknown = quality
            XCTAssertTrue(unknown.update([0xE9, 1, 0, value]))
            XCTAssertEqual(unknown.mode, .unknown(value))
            XCTAssertEqual(unknown.mode?.title, "Unknown")
            XCTAssertNotEqual(unknown.mode, .lowLatency)
            XCTAssertFalse(unknown.hasKnownParameter)
            XCTAssertNil(unknown.setPayload(.stableConnection))
        }
        for payload: [UInt8] in [[0xE1, 1, 1], [0xE1, 1, 0xFF], [0xE5, 1, 1], [0xE5, 1, 2],
                                [0xE5, 1, 0xFF], [0xE9, 1, 1, 0], [0xE9, 1, 0xFF, 1]] {
            var changed = quality
            XCTAssertTrue(changed.update(payload))
            XCTAssertFalse(changed.canSet)
            XCTAssertNil(changed.setPayload(.soundQuality))
            XCTAssertFalse(changed.acceptsSetPayload([0xE8, 1, 0, 0]))
            if payload[0] == 0xE1 {
                XCTAssertEqual(changed.settingType, payload[2])
                XCTAssertNil(changed.supportedModes)
                XCTAssertEqual(changed.mode, .soundQuality)
            } else if payload[0] == 0xE5 {
                XCTAssertEqual(changed.available, payload[2] == 1 ? false : nil)
                XCTAssertEqual(changed.mode, .soundQuality)
            } else {
                XCTAssertEqual(changed.parameterSettingType, payload[2])
                XCTAssertFalse(changed.hasKnownParameter)
            }
        }
    }

    func testLegacyConnectionQualityExactShapesKeepDSEEAndModernQualitySeparate() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 2, 0xE1, 0xE2]))
        for payload: [UInt8] in [[0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0],
                                [0xE1, 2, 2, 0], [0xE3, 2, 0], [0xE7, 2, 0, 0]] {
            XCTAssertTrue(controls.update(payload))
        }
        let prior = controls.connectionQuality
        var quality = prior
        for payload: [UInt8] in [[], [0xE1, 1], [0xE1, 1, 0, 0], [0xE3, 1], [0xE3, 1, 0, 0],
                                [0xE5, 1, 0, 0], [0xE7, 1, 0], [0xE7, 1, 0, 0, 0], [0xE9, 1, 1],
                                [0xE9, 1, 0, 1, 0], [0xE1, 2, 2, 0], [0xE7, 2, 0, 1],
                                [0xE1, 5, 2, 0, 1, 0], [0xE3, 5, 0, 0], [0xE7, 5, 1],
                                [0xE9, 5, 1, 2], [0xE8, 1, 0, 1]] {
            XCTAssertFalse(quality.update(payload))
            XCTAssertEqual(quality, prior)
        }
        for payload: [UInt8] in [[0xE8, 1, 1], [0xE8, 1, 1, 1], [0xE8, 1, 0, 1, 0],
                                [0xE8, 2, 0, 1], [0xE8, 5, 1, 0]] {
            XCTAssertFalse(quality.acceptsSetPayload(payload))
        }
        let dsee = controls.dsee
        XCTAssertTrue(controls.update([0xE9, 1, 0, 1]))
        XCTAssertEqual(controls.connectionQuality.mode, .stableConnection)
        XCTAssertEqual(controls.dsee, dsee)
        quality = controls.connectionQuality
        XCTAssertTrue(controls.update([0xE9, 2, 0, 1]))
        XCTAssertEqual(controls.dsee.mode, .automatic)
        XCTAssertEqual(controls.connectionQuality, quality)
        var modern = SonyAudioFeatures(supportedFunctions: [0xE2, 0xE7])
        XCTAssertFalse(modern.update([0xE7, 1, 0, 1]))
        XCTAssertTrue(modern.update([0xE7, 1, 1]))
        XCTAssertEqual(modern.dseeMode, .automatic)
        XCTAssertNil(modern.connectionMode)
        XCTAssertTrue(modern.update([0xE9, 5, 1, 2]))
        XCTAssertEqual(modern.connectionMode, .stableConnection)
        XCTAssertEqual(modern.lastConnectionModeSwitchingStream, .classicAudio)
        XCTAssertEqual(controls.connectionQuality, quality)
    }

    func testLegacyPauseRequiresAdvertisedTypedStateAndUsesOneForOn() throws {
        var unsupported = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0xF1]))
        XCTAssertTrue(unsupported.wearingControl.queryPayloads.isEmpty)
        XCTAssertNil(unsupported.wearingControl.state)
        for payload: [UInt8] in [[0xF1, 3, 0], [0xF3, 3, 0], [0xF7, 3, 0, 1]] {
            XCTAssertFalse(unsupported.update(payload))
        }
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0xF3]))
        XCTAssertEqual(controls.wearingControl.queryPayloads, [[0xF0, 3], [0xF2, 3], [0xF6, 3]])
        XCTAssertNil(controls.wearingControl.setPayload(enabled: true))
        XCTAssertTrue(controls.update([0xF3, 3, 0]))
        XCTAssertTrue(controls.update([0xF7, 3, 0, 0]))
        XCTAssertFalse(controls.wearingControl.canSet)
        XCTAssertTrue(controls.update([0xF1, 3, 0]))
        XCTAssertEqual(controls.wearingControl.queryPayloads, [[0xF2, 3], [0xF6, 3]])
        XCTAssertEqual(controls.wearingControl.state?.enabled, false)
        XCTAssertEqual(controls.wearingControl.setPayload(enabled: true), [0xF8, 3, 0, 1])
        XCTAssertEqual(controls.wearingControl.setPayload(enabled: false), [0xF8, 3, 0, 0])
        XCTAssertTrue(controls.allows([0xF8, 3, 0, 1]))
        XCTAssertTrue(controls.update([0xF9, 3, 0, 1]))
        XCTAssertEqual(controls.wearingControl.state?.enabled, true)
        XCTAssertFalse(controls.wearingControl.acceptsSetPayload([0xF8, 1, 0]))
        XCTAssertFalse(controls.wearingControl.acceptsSetPayload([0xF8, 3, 1, 1]))
        XCTAssertFalse(controls.wearingControl.acceptsSetPayload([0xF8, 3, 0, 2]))
    }

    func testLegacyPauseRejectsMalformedAndUnknownTypesStatusOrCurrentValues() {
        let valid: [[UInt8]] = [[0xF1, 3, 0], [0xF3, 3, 0], [0xF7, 3, 0, 1]]
        for unknown: [UInt8] in [[0xF1, 3, 1], [0xF1, 3, 0xFF], [0xF5, 3, 1], [0xF5, 3, 0xFF],
                                 [0xF9, 3, 1, 1], [0xF9, 3, 0, 0xFF]] {
            var wearing = SonyLegacyWearingControl(isSupported: true)
            for payload in valid { XCTAssertTrue(wearing.update(payload)) }
            XCTAssertTrue(wearing.canSet)
            XCTAssertTrue(wearing.update(unknown))
            XCTAssertFalse(wearing.canSet, "\(unknown)")
            XCTAssertNil(wearing.setPayload(enabled: false))
            XCTAssertEqual(wearing.state?.isVisible, true)
        }
        var wearing = SonyLegacyWearingControl(isSupported: true)
        for payload in valid { XCTAssertTrue(wearing.update(payload)) }
        let previous = wearing
        for malformed: [UInt8] in [[], [0xF1, 3], [0xF1, 3, 0, 0], [0xF3, 3, 0, 0],
                                   [0xF7, 3, 0], [0xF7, 3, 0, 1, 0], [0xF9, 1, 0, 1],
                                   [0xF9, 3, 2, 0x35, 0x20], [0xF8, 3, 0, 1]] {
            XCTAssertFalse(wearing.update(malformed))
            XCTAssertEqual(wearing, previous)
        }
    }

    func testLegacyPowerPolicyRequiresF4AndPreservesHiddenTimerWithoutOfferingV2OptionFour() throws {
        var unsupported = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 3, 0x24, 0x25, 0xF3]))
        XCTAssertNil(unsupported.automaticPowerOff)
        XCTAssertFalse(unsupported.update([0xF1, 4, 2, 0x10, 0x11]))
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [0x07, 0, 1, 0xF4]))
        XCTAssertEqual(controls.automaticPowerOff?.queryPayloads, [[0xF0, 4], [0xF2, 4], [0xF6, 4]])
        XCTAssertTrue(controls.update([0xF1, 4, 4, 0x11, 0x10, 4, 0xFE]))
        XCTAssertTrue(controls.update([0xF3, 4, 0]))
        XCTAssertNil(controls.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0x11)))
        XCTAssertTrue(controls.update([0xF7, 4, 1, 0x10, 3]))
        XCTAssertEqual(controls.automaticPowerOff?.options?.map(\.rawValue), [0x11, 0x10, 4, 0xFE])
        XCTAssertEqual(controls.automaticPowerOff?.knownOptions.map(\.rawValue), [0x11, 0x10])
        XCTAssertEqual(controls.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0x11)), [0xF8, 4, 1, 0x11, 3])
        XCTAssertTrue(controls.allows([0xF8, 4, 1, 0x11, 3]))
        for option: UInt8 in [0, 3, 4, 0xFE] {
            XCTAssertNil(controls.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: option)))
        }
        XCTAssertTrue(controls.update([0xF1, 4, 3, 3, 0, 0x11]))
        XCTAssertEqual(controls.automaticPowerOff?.options?.map(\.rawValue), [3, 0, 0x11])
        XCTAssertEqual(controls.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 0)), [0xF8, 4, 1, 0, 0])
        XCTAssertEqual(controls.automaticPowerOff?.setPayload(SonyAutomaticPowerOffOption(rawValue: 3)), [0xF8, 4, 1, 3, 3])
        XCTAssertFalse(controls.allows([0x28, 4, 0x11, 3]))
    }

    func testLegacyPowerPolicyRequiresKnownTypeAndBothIDsInExactFiveByteTuple() {
        let valid: [[UInt8]] = [[0xF1, 4, 2, 0x10, 0x11], [0xF3, 4, 0], [0xF7, 4, 1, 0x10, 3]]
        var state = SonyAutomaticPowerOffState(inquiryType: 4, generation: .v1)
        for payload in valid { XCTAssertTrue(state.update(payload)) }
        let prior = state
        for malformed: [UInt8] in [[0xF1, 4, 2, 0x10], [0xF1, 4, 2, 0x11, 0x11], [0xF3, 4, 0, 0],
                                   [0xF7, 4, 0x10, 3], [0xF9, 4, 1, 0x10, 3, 0], [0xF9, 3, 1, 0x10, 3],
                                   [0x27, 4, 0x11, 3], [0x29, 4, 0x11, 3]] {
            XCTAssertFalse(state.update(malformed))
            XCTAssertEqual(state, prior)
        }
        for unknown: [UInt8] in [[0xF5, 4, 1], [0xF5, 4, 0xFF], [0xF9, 4, 0, 0x10, 3],
                                 [0xF9, 4, 0xFF, 0x10, 3], [0xF9, 4, 1, 4, 3], [0xF9, 4, 1, 0x10, 4],
                                 [0xF9, 4, 1, 0xFE, 3], [0xF9, 4, 1, 0x10, 0xFF]] {
            var changed = prior
            XCTAssertTrue(changed.update(unknown))
            XCTAssertNil(changed.setPayload(SonyAutomaticPowerOffOption(rawValue: 0x11)))
            if unknown[0] == 0xF9 { XCTAssertFalse(changed.hasKnownParameter) }
        }
    }
}

@available(macOS 27.0, *)
@MainActor
final class SonyLegacyControllerTests: XCTestCase {
    private let capability: [UInt8] = [0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15]
    private let ambient: [UInt8] = [0x67, 2, 1, 2, 0, 1, 0, 12]

    func testNoiseShortcutTogglesFromPendingAndQueuedLegacyTargets() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.toggleNoiseControl()
        let anc = try XCTUnwrap(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(anc, [2, 1, 2, 2, 1, 0, 0])
        controller.toggleNoiseControl()
        acknowledgeAll(controller)
        deliver([0x69] + anc, to: controller)
        let ambient = try XCTUnwrap(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(ambient, [2, 1, 2, 0, 1, 0, 12])
        controller.toggleNoiseControl()
        controller.toggleNoiseControl()
        acknowledgeAll(controller)
        deliver([0x69] + ambient, to: controller)
        XCTAssertEqual(controller.pendingChanges[.noiseControl], ambient)
    }

    func testLegacyBudBatteryDoesNotRefreshLastReportedCaseReading() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        deliver([0x13, 2, 65, 1], to: controller)
        let observedAt = try XCTUnwrap(controller.lowBatteryReadings.first { $0.part == .caseBattery }?.observedAt)
        controller.simulateCaseBatteryExpiry(at: observedAt.addingTimeInterval(46))
        XCTAssertEqual(controller.batteries.caseBattery?.level, 65)
        XCTAssertFalse(controller.lowBatteryReadings.contains { $0.part == .caseBattery })
        deliver([0x13, 1, 73, 0, 76, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 73)
        XCTAssertEqual(controller.batteries.right?.level, 76)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 65)
        XCTAssertFalse(controller.lowBatteryReadings.contains { $0.part == .caseBattery })
        deliver([0x13, 2, 64, 0], to: controller)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 64)
        XCTAssertEqual(controller.batteries.caseBattery?.chargingState, .notCharging)
    }

    func testLegacyBatteryNotificationsRetireOnlyTheirTransmittedPollAndFreshness() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        deliver([0x13, 1, 19, 0, 18, 1], to: controller)
        let pair = controller.lowBatteryReadings
        XCTAssertEqual(pair.map(\.part), [.left, .right])
        XCTAssertEqual(pair.map(\.level), [19, 18])
        XCTAssertNil(controller.lowBatteryNotificationDeviceID)
        let pairQueries = controller.simulatedTransmittedFrames.filter { $0.payload == [0x10, 1] }.count
        controller.refresh()
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x10, 1] }.count, pairQueries)
        deliver([0x11, 1, 80, 0, 90, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 19)
        XCTAssertEqual(controller.batteries.right?.isCharging, true)
        XCTAssertEqual(controller.lowBatteryReadings, pair)
        deliver([0x11, 2, 24, 0], to: controller)
        XCTAssertEqual(Array(controller.lowBatteryReadings.prefix(2)), pair)
        XCTAssertEqual(controller.lowBatteryReadings.last?.part, .caseBattery)
        XCTAssertEqual(controller.lowBatteryReadings.last?.level, 24)
        controller.refresh()
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x10, 1] }.count, pairQueries + 1)
        deliver([0x11, 1, 17, 0, 18, 0], to: controller)
        XCTAssertEqual(controller.lowBatteryReadings.first { $0.part == .left }?.level, 17)
        deliver([0x13, 1, 255, 0, 255, 0], to: controller)
        XCTAssertEqual(controller.lowBatteryReadings.map(\.part), [.caseBattery])
        controller.simulateControlLoss()
        XCTAssertTrue(controller.lowBatteryReadings.isEmpty)
    }

    func testNegotiatedLegacyIdentityBatteryAndQueriesStaySeparateFromV2() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.deviceModel, .wfXM4)
        XCTAssertEqual(controller.deviceName, "WF-1000XM5")
        XCTAssertEqual(controller.deviceInformation.color?.rawValue, 0xFF)
        XCTAssertEqual(controller.controlProtocol, "MDR v1")
        XCTAssertEqual(controller.availableNoiseModes, [.off, .anc, .ambient, .wind])
        XCTAssertTrue(controller.supportedFunctions.isEmpty)
        XCTAssertTrue(controller.supportedFunctions2.isEmpty)
        XCTAssertFalse(controller.equalizer.isSupported)
        XCTAssertTrue(controller.audioFeatures.queryPayloads.isEmpty)
        XCTAssertTrue(controller.systemFeatures.queryPayloads.isEmpty)
        XCTAssertTrue(controller.touchAssignments.queryPayloads.isEmpty)
        XCTAssertFalse(controller.canPowerOff)
        deliver([0x11, 1, 0, 0, 84, 1], to: controller)
        deliver([0x11, 2, 65, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 0)
        XCTAssertEqual(controller.batteries.right?.isCharging, true)
        XCTAssertEqual(controller.batteries.caseBattery?.level, 65)
        deliver([0x11, 0, 95, 0], to: controller)
        deliver([0x23, 9, 96, 0, 96, 0], to: controller)
        deliver([0xE7, 1, 1], to: controller)
        XCTAssertNil(controller.batteries.single)
        XCTAssertEqual(controller.batteries.left?.level, 0)
        controller.refresh()
        controller.refreshEqualizer()
        controller.setEqualizerPreset(.bassBoost)
        acknowledgeAll(controller)
        let allowed: Set<[UInt8]> = [[0, 0], [4, 1], [4, 2], [4, 3], [6, 0], [0x60, 2], [0x62, 2], [0x66, 2], [0x10, 1], [0x10, 2]]
        let commands = controller.simulatedTransmittedFrames.filter { $0.type != 0x01 }
        let unexpected = commands.filter { $0.type != 0x0C || !allowed.contains($0.payload) }
        let details = unexpected.map { frame in
            "type \(String(format: "%02X", frame.type)): \(frame.payload.map { String(format: "%02X", $0) }.joined(separator: " "))"
        }.joined(separator: "; ")
        XCTAssertTrue(unexpected.isEmpty, "Unexpected V1 command frames: \(details)")
        XCTAssertTrue(controller.simulatedTransmittedFrames.filter { $0.type == 0x01 }.allSatisfy { $0.payload.isEmpty })
    }

    // Replies captured from a WH-1000XM4 on firmware 3.0.1 over the "Serial HPC" RFCOMM service.
    // The function list holds the 23 reported functions in sorted order.
    private let whXM4Functions: [UInt8] = [0x07, 0, 0x17, 0x11, 0x12, 0x13, 0x14, 0x21, 0x22, 0x30, 0x38, 0x39, 0x51, 0x62,
                                           0x71, 0x81, 0xA1, 0xC1, 0xD1, 0xD2, 0xE1, 0xE2, 0xF3, 0xF4, 0xF5, 0xF6]

    func testWHXM4CapturedRepliesDecodeAndUnverifiedFunctionsStayHidden() throws {
        XCTAssertEqual(SonyProtocolInfo(payload: [0x01, 0, 0x70, 0])?.generation, .v1)
        XCTAssertEqual(SonyProtocolInfo(payload: [0x01, 0, 0x70, 0])?.version, 0x7000)
        XCTAssertEqual(SonyLegacyControls.unverifiedFunctions(for: .whXM4), [0x81, 0xE1, 0xF6])
        XCTAssertTrue(SonyLegacyControls.unverifiedFunctions(for: .whXM3).isEmpty)
        XCTAssertEqual(try XCTUnwrap(SonyLegacyControls(supportPayload: whXM4Functions)).supportedFunctions.count, 23)

        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: whXM4Functions, model: .whXM4))
        XCTAssertEqual(controls.supportedFunctions.count, 20)
        XCTAssertTrue(controls.supportedFunctions.isDisjoint(with: [0x81, 0xE1, 0xF6]))
        XCTAssertFalse(controls.connectionQuality.isSupported)
        XCTAssertFalse(SonyLegacyOptimizer(supportedFunctions: controls.supportedFunctions).isSupported)
        XCTAssertNil(SonyTouchAssignments(supportedFunctions: controls.supportedFunctions, generation: .v1).inquiryType)
        XCTAssertTrue(controls.dsee.isSupported)
        XCTAssertTrue(controls.wearingControl.isSupported)
        XCTAssertNotNil(controls.automaticPowerOff)
        XCTAssertEqual(controls.batteryQueries, [[0x10, 0]])

        XCTAssertTrue(controls.update([0x61, 2, 2, 0, 1, 2, 0, 0x14, 1, 0x14]))
        XCTAssertEqual(controls.noiseCapability?.modes, [.off, .anc, .ambient, .wind])
        XCTAssertEqual(controls.noiseCapability?.ambientRange(focusOnVoice: false), 1...20)
        XCTAssertEqual(controls.noiseCapability?.ambientRange(focusOnVoice: true), 1...20)
        XCTAssertTrue(controls.update([0x63, 2, 0]))
        XCTAssertTrue(controls.update([0x11, 0, 0x50, 0]))
        XCTAssertEqual(controls.batteries.single?.level, 80)
        XCTAssertEqual(controls.batteries.single?.chargingState, .notCharging)
        XCTAssertTrue(controls.update([0x67, 2, 1, 2, 2, 1, 0, 0]))
        XCTAssertEqual(controls.noiseState?.mode, .anc)
        XCTAssertTrue(controls.canSetNoiseControl)
        XCTAssertEqual(controls.noiseControlPayload(mode: .ambient, ambientLevel: 15, focusOnVoice: true), [0x68, 2, 1, 2, 0, 1, 1, 0x0F])
        XCTAssertEqual(controls.noiseControlPayload(mode: .wind, ambientLevel: 10, focusOnVoice: false), [0x68, 2, 1, 2, 1, 1, 0, 0])
        XCTAssertEqual(controls.noiseControlPayload(mode: .anc, ambientLevel: 10, focusOnVoice: false), [0x68, 2, 1, 2, 2, 1, 0, 0])
        for (reply, mode, focus) in [([UInt8]([0x69, 2, 1, 2, 0, 1, 1, 0x0F]), NoiseControlMode.ambient, true),
                                     ([0x69, 2, 1, 2, 1, 1, 0, 0], .wind, false),
                                     ([0x69, 2, 0, 2, 1, 1, 0, 0], .off, false)] {
            XCTAssertTrue(controls.update(reply))
            XCTAssertEqual(controls.noiseState?.mode, mode)
            XCTAssertEqual(controls.noiseState?.focusOnVoice, focus)
        }
        XCTAssertEqual(controls.noiseControlPayload(mode: .off, ambientLevel: 10, focusOnVoice: false), [0x68, 2, 0, 2, 1, 1, 0, 0])

        XCTAssertTrue(controls.update([0xE1, 2, 2, 0]))
        XCTAssertTrue(controls.update([0xE3, 2, 0]))
        XCTAssertTrue(controls.update([0xE7, 2, 0, 1]))
        XCTAssertEqual(controls.dsee.mode, .automatic)
        XCTAssertEqual(controls.dsee.setPayload(.off), [0xE8, 2, 0, 0])
    }

    func testWHXM4HandshakeReadsBatteryAndNoiseAndWritesNoiseWithoutHiddenControls() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WH-1000XM4", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 0x70, 0], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array("WH-1000XM4".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0x30, 0x01], to: controller)
        deliver(whXM4Functions, to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 2, 2, 0, 1, 2, 0, 0x14, 1, 0x14], to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver([0x11, 0, 0x50, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 2, 1, 2, 2, 1, 0, 0], to: controller)
        acknowledgeAll(controller)

        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.deviceModel, .whXM4)
        XCTAssertEqual(controller.controlProtocol, "MDR v1")
        XCTAssertEqual(controller.batteries.single?.level, 80)
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertEqual(controller.availableNoiseModes, [.off, .anc, .ambient, .wind])
        XCTAssertTrue(controller.supportsVoiceFocus)
        XCTAssertFalse(controller.supportsConnectionMode)
        XCTAssertFalse(controller.legacyOptimizer.isSupported)
        XCTAssertTrue(controller.touchAssignments.queryPayloads.isEmpty)

        let sentBefore = controller.simulatedTransmittedFrames.count
        controller.setNoiseControl(.ambient)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.dropFirst(sentBefore).contains {
            $0.type == 0x0C && $0.payload == [0x68, 2, 1, 2, 0, 1, 0, 0x0A]
        })
        deliver([0x69, 2, 1, 2, 0, 1, 0, 0x0A], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        XCTAssertEqual(controller.ambientLevel, 10)
    }

    func testCapabilityAndAvailabilityMustPrecedeOwnedCurrentStateInEitherOrder() {
        for statusFirst in [false, true] {
            let controller = beginController()
            defer { controller.simulateControlLoss() }
            deliver([0x07, 0, 1, 0x62], to: controller)
            acknowledgeAll(controller)
            deliver(ambient, to: controller)
            XCTAssertNil(controller.legacyControls?.noiseState)
            XCTAssertFalse(controller.isReady)
            deliver(statusFirst ? [0x63, 2, 0] : capability, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x66, 2] })
            deliver(statusFirst ? capability : [0x63, 2, 0], to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 2] }.count, 1)
            XCTAssertFalse(controller.isReady)
            deliver(ambient, to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canChangeNoiseControl)
        }
    }

    func testLegacyCapabilityResponsesRequireTransmissionAndMalformedRepliesKeepOwnership() {
        let controller = beginController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        deliver([0x07, 0, 1, 0x62], to: controller)
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x60, 2])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x60, 2] })
        deliver(capability, to: controller)
        deliver([0x63, 2, 0], to: controller)
        XCTAssertNil(controller.legacyControls?.noiseCapability)
        XCTAssertNil(controller.legacyControls?.noiseAvailable)
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        deliver(Array(capability.dropLast()), to: controller)
        XCTAssertNil(controller.legacyControls?.noiseCapability)
        deliver(capability, to: controller)
        deliver([0x63, 2, 0], to: controller)
        acknowledgeAll(controller)
        deliver(ambient, to: controller)
        XCTAssertTrue(controller.isReady)
    }

    func testUnavailableAndBinaryAmbientCapabilitiesDoNotExposeUnsupportedControls() {
        let controller = makeController(capability: [0x61, 2, 0, 2, 0, 1, 0, 2],
                                        state: [0x67, 2, 1, 0, 1, 0, 0, 0], available: 1)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertFalse(controller.supportsVoiceFocus)
        XCTAssertEqual(controller.ambientLevelRange, 1...1)
        XCTAssertEqual(controller.availableNoiseModes, [.off, .anc, .ambient])
        XCTAssertTrue(controller.noiseControlActions.isEmpty)
        let count = controller.simulatedTransmittedFrames.count
        controller.setNoiseControl(.off)
        controller.setFocusOnVoice(true)
        controller.applyPreset(mode: .ambient, ambientLevel: 12, focusOnVoice: true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, count)
        deliver([0x65, 2, 0], to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
        XCTAssertFalse(controller.canApplyNoisePreset(mode: .ambient, ambientLevel: 12, focusOnVoice: false))
        controller.setNoiseControl(.ambient)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x68, 2, 1, 0, 0, 0, 0, 1])
    }

    func testNoiseConfirmationRequiresTransmissionAndTerminalExactTuple() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setNoiseControl(.anc)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(payload, [0x68, 2, 1, 2, 2, 1, 0, 0])
        controller.defersSimulatedWrites = false
        deliver([0x69] + payload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == payload })
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        var adjusting = payload
        adjusting[0] = 0x69
        adjusting[2] = 0x10
        deliver(adjusting, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertTrue(controller.noiseControlActions.isEmpty)
        var completed = adjusting
        completed[2] = 0x11
        completed[4] = 1
        deliver(completed, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        completed[4] = 2
        deliver(completed, to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertTrue(controller.canChangeNoiseControl)
    }

    func testAdjustingStateCannotCompleteHandshakeOrReturnSuccessfulNoOp() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let action = try XCTUnwrap(controller.noiseControlActions.first { $0.title == NoiseControlMode.ambient.title })
        deliver([0x69, 2, 0x10, 2, 0, 1, 0, 12], to: controller)
        do {
            try await controller.performNoiseControlAction(action.id)
            XCTFail("An adjusting state must not complete an action as a no-op.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Noise control is unavailable on the headphones.")
        }
        let connecting = makeController(state: [0x67, 2, 0x10, 2, 0, 1, 0, 12])
        defer { connecting.simulateControlLoss() }
        XCTAssertFalse(connecting.isReady)
        deliver([0x69, 2, 0x11, 2, 0, 1, 0, 12], to: connecting)
        XCTAssertTrue(connecting.isReady)
        XCTAssertEqual(connecting.noiseControlMode, .ambient)
    }

    func testOldNoisePollCannotConfirmNewLegacyWrite() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setNoiseControl(.anc)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        acknowledgeAll(controller)
        let before = controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 2] }.count
        deliver([0x67] + payload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 2] }.count, before + 1)
        deliver([0x67] + payload.dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
    }

    func testTimedOutNativeNoiseActionRejectsStaleNoOpUntilFreshOwnedState() async throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let anc = try XCTUnwrap(controller.noiseControlActions.first { $0.title == NoiseControlMode.anc.title })
        let ambientAction = try XCTUnwrap(controller.noiseControlActions.first { $0.title == NoiseControlMode.ambient.title })
        controller.refresh()
        acknowledgeAll(controller)
        let started = expectation(description: "Legacy noise action started")
        let action = Task { @MainActor in
            started.fulfill()
            try await controller.performNoiseControlAction(anc.id)
        }
        await fulfillment(of: [started], timeout: 1)
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        controller.simulateSettingTimeout(.noiseControl)
        do {
            try await action.value
            XCTFail("An unconfirmed legacy action must time out.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Headphones did not confirm the change.")
        }
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertTrue(controller.noiseControlActions.isEmpty)
        do {
            try await controller.performNoiseControlAction(ambientAction.id)
            XCTFail("A stale displayed mode must not complete a native action as a no-op.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Sync noise control before making another change.")
        }
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 1)
        let reads = controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 2] }.count
        let confirmedANC: [UInt8] = [0x67, 2, 1, 2, 2, 1, 0, 0]
        deliver(confirmedANC, to: controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x66, 2] }.count, reads + 1)
        deliver(confirmedANC, to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertNil(controller.settingErrors[.noiseControl])
        controller.simulateNoiseReadTimeout([0x66, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
    }

    func testOldLegacyNoiseRepliesCannotUndoNewerStateOrAvailability() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        deliver([0x69, 2, 1, 2, 2, 1, 0, 0], to: controller)
        deliver([0x65, 2, 1], to: controller)
        deliver(ambient, to: controller)
        deliver([0x63, 2, 0], to: controller)
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertEqual(controller.legacyControls?.noiseState?.mode, .anc)
        XCTAssertEqual(controller.legacyControls?.noiseAvailable, false)
        XCTAssertFalse(controller.canChangeNoiseControl)
        deliver([0x65, 2, 0], to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
    }

    func testAcknowledgedLegacyNoiseMetadataReadsHaveBoundedLifetime() async {
        for query: [UInt8] in [[0x60, 2], [0x62, 2]] {
            let controller = beginController()
            defer { controller.simulateControlLoss() }
            deliver([0x07, 0, 1, 0x62], to: controller)
            acknowledgeAll(controller)
            let session = controller.simulatedControlSession
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == query })
            controller.simulateNoiseReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.linkState, .failed("Noise control status was not received. Reconnect the headphones to try again."))
            controller.simulateProtocolMessage(capability, session: session)
            XCTAssertNil(controller.legacyControls)
        }
    }

    func testLegacyNoiseParameterDeadlineStartsAtTransmissionAndEndsWithItsSession() async {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        controller.simulateNoiseReadTimeout([0x66, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        acknowledgeAll(controller)
        let session = controller.simulatedControlSession
        controller.simulateNoiseReadTimeout([0x66, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.isReady)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.linkState, .failed("Noise control status was not received. Reconnect the headphones to try again."))
        controller.simulateDeviceConnection(named: "WF-1000XM4", galleryModel: .wfXM4)
        controller.simulateNoiseReadTimeout([0x66, 2])
        controller.simulateProtocolMessage(ambient, session: session)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
    }

    func testLegacySessionResetDiscardsIdentityReadsAndPendingCommands() throws {
        let controller = makeController()
        controller.setNoiseControl(.anc)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        controller.simulateProtocolMessage([0x69] + payload.dropFirst(), session: session)
        XCTAssertNil(controller.legacyControls)
        XCTAssertNil(controller.protocolInformation)
        XCTAssertNil(controller.deviceInformation.modelName)
        XCTAssertNil(controller.noiseControlMode)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNil(controller.batteries.left)
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
        acknowledgeAll(controller)
        deliver(capability, to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver(ambient, to: controller)
        XCTAssertNil(controller.legacyControls)
        XCTAssertFalse(controller.isReady)
        controller.simulateControlLoss()
    }

    func testLegacyLevelAdjustmentCapabilityKeepsOtherControlsReadyWithoutNoisePolling() {
        let controller = beginController()
        defer { controller.simulateControlLoss() }
        deliver([0x07, 0, 2, 0x62, 0x15], to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 2, 1, 20, 1, 1, 0, 20], to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertTrue(controller.availableNoiseModes.isEmpty)
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertEqual(controller.protocolInformation?.generation, .v1)
        deliver([0x11, 1, 80, 0, 82, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 80)
        let noiseReads = controller.simulatedTransmittedFrames.filter { [0x60, 0x62, 0x66].contains($0.payload.first) }
        for _ in 0..<10 {
            controller.simulateAutomaticRefresh()
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { [0x60, 0x62, 0x66].contains($0.payload.first) }, noiseReads)
        for query: [UInt8] in [[0x60, 2], [0x62, 2], [0x66, 2]] {
            XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
        }
    }

    func testUnknownLegacyNoiseCapabilityStillRejectsTheUnsupportedProtocol() {
        let controller = beginController()
        defer { controller.simulateControlLoss() }
        deliver([0x07, 0, 1, 0x62], to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 2, 0xFF, 20, 1, 1, 0, 20], to: controller)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(controller.statusText.contains("not supported yet"))
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
    }

    func testLegacyDSEEWaitsForCapabilityAvailabilityAndCurrentTypedValue() {
        let controller = makeController(supportsDSEE: true)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.supportsDSEE)
        XCTAssertFalse(controller.audioFeatures.supportsDSEE)
        XCTAssertFalse(controller.canSetDSEE)
        deliver([0xE1, 1, 0], to: controller)
        XCTAssertNil(controller.dseeType)
        deliver([0xE7, 2, 1], to: controller)
        XCTAssertNil(controller.dseeMode)
        deliver([0xE7, 2, 0, 0], to: controller)
        XCTAssertEqual(controller.dseeMode, .off)
        XCTAssertFalse(controller.canSetDSEE)
        deliver([0xE3, 2, 0], to: controller)
        XCTAssertFalse(controller.canSetDSEE)
        deliver([0xE1, 2, 0, 0], to: controller)
        XCTAssertEqual(controller.dseeType, .hx)
        XCTAssertTrue(controller.canSetDSEE)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE0 }.map(\.payload), [[0xE0, 2]])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E })
    }

    func testLegacyDSEEConfirmationRequiresTransmissionAndMatchingSettingType() throws {
        let controller = makeDSEEController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setDSEE(.automatic)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(payload, [0xE8, 2, 0, 1])
        controller.defersSimulatedWrites = false
        deliver([0xE9, 2, 0, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.dsee])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == payload })
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        deliver([0xE9, 2, 1, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.dsee])
        XCTAssertFalse(controller.canSetDSEE)
        deliver([0xE9, 1, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.dsee])
        deliver([0xE9, 2, 0, 1], to: controller)
        XCTAssertNil(controller.pendingChanges[.dsee])
        XCTAssertEqual(controller.dseeMode, .automatic)
        XCTAssertTrue(controller.canSetDSEE)
    }

    func testOldLegacyDSEEReadCannotConfirmNewWrite() {
        let controller = makeDSEEController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setDSEE(.automatic)
        acknowledgeAll(controller)
        let count = controller.simulatedTransmittedFrames.filter { $0.payload == [0xE6, 2] }.count
        deliver([0xE7, 2, 0, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.dsee])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE6, 2] }.count, count + 1)
        deliver([0xE7, 2, 0, 1], to: controller)
        XCTAssertNil(controller.pendingChanges[.dsee])
        XCTAssertEqual(controller.dseeMode, .automatic)
    }

    func testTimedOutLegacyDSEEWriteRequiresFreshOwnedState() async {
        let controller = makeDSEEController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setDSEE(.automatic)
        acknowledgeAll(controller)
        controller.simulateSettingTimeout(.dsee)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(controller.pendingChanges[.dsee])
        XCTAssertEqual(controller.dseeMode, .off)
        XCTAssertFalse(controller.canSetDSEE)
        controller.setDSEE(.automatic)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.count, 1)
        let reads = controller.simulatedTransmittedFrames.filter { $0.payload == [0xE6, 2] }.count
        deliver([0xE7, 2, 0, 1], to: controller)
        XCTAssertEqual(controller.dseeMode, .off)
        XCTAssertFalse(controller.canSetDSEE)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE6, 2] }.count, reads + 1)
        deliver([0xE7, 2, 0, 1], to: controller)
        XCTAssertEqual(controller.dseeMode, .automatic)
        XCTAssertTrue(controller.canSetDSEE)
        XCTAssertNil(controller.settingErrors[.dsee])
        controller.simulateLegacyDSEEReadTimeout([0xE6, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
    }

    func testOldLegacyDSEERepliesCannotUndoNewerStateOrAvailability() {
        let controller = makeDSEEController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        deliver([0xE9, 2, 0, 1], to: controller)
        deliver([0xE5, 2, 1], to: controller)
        deliver([0xE7, 2, 0, 0], to: controller)
        deliver([0xE3, 2, 0], to: controller)
        XCTAssertEqual(controller.dseeMode, .automatic)
        XCTAssertEqual(controller.dseeAvailable, false)
        XCTAssertFalse(controller.canSetDSEE)
        deliver([0xE5, 2, 0], to: controller)
        XCTAssertTrue(controller.canSetDSEE)
    }

    func testAcknowledgedLegacyDSEEReadExpiryIsIsolatedAndLateRepliesRequireAFreshRead() async {
        let replies: [[UInt8]] = [[0xE1, 2, 0, 0], [0xE3, 2, 0], [0xE7, 2, 0, 1]]
        for reply in replies {
            let query: [UInt8] = [reply[0] - 1, 2]
            let controller = makeController(supportsDSEE: true)
            defer { controller.simulateControlLoss() }
            for other in replies where other != reply { deliver(other, to: controller) }
            let session = controller.simulatedControlSession
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == query })
            controller.simulateLegacyDSEEReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertFalse(controller.canSetDSEE)
            XCTAssertEqual(controller.settingErrors[.dsee], "DSEE settings are unavailable.")
            let reads = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
            controller.simulateAutomaticRefresh()
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, reads)
            deliver(Array(reply.dropLast()), to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, reads)
            XCTAssertFalse(controller.canSetDSEE)
            deliver(reply, to: controller)
            XCTAssertFalse(controller.canSetDSEE)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, reads + 1)
            deliver(reply, to: controller)
            XCTAssertTrue(controller.canSetDSEE)
            XCTAssertNil(controller.settingErrors[.dsee])
        }
    }

    func testLegacyDSEEParameterDeadlineStartsAtTransmissionAndEndsWithItsSession() async {
        let controller = makeDSEEController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        controller.simulateLegacyDSEEReadTimeout([0xE6, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        acknowledgeAll(controller)
        controller.simulateLegacyDSEEReadTimeout([0xE6, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.dseeMode)
        XCTAssertFalse(controller.canSetDSEE)
        controller.simulateDeviceConnection(named: "WF-1000XM4", galleryModel: .wfXM4)
        controller.simulateLegacyDSEEReadTimeout([0xE6, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
    }

    func testExpiredLegacyDSEEPollCannotConfirmALaterWrite() async {
        let controller = makeDSEEController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setDSEE(.automatic)
        acknowledgeAll(controller)
        let session = controller.simulatedControlSession
        controller.simulateLegacyDSEEReadTimeout([0xE6, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.dseeMode, .off)
        XCTAssertNotNil(controller.pendingChanges[.dsee])
        controller.simulateSettingTimeout(.dsee)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.canSetDSEE)
        XCTAssertNotNil(controller.settingErrors[.dsee])
        deliver([0xE7, 2, 0, 1], to: controller)
        XCTAssertEqual(controller.dseeMode, .off)
        XCTAssertNotNil(controller.settingErrors[.dsee])
        acknowledgeAll(controller)
        deliver([0xE7, 2, 0, 1], to: controller)
        XCTAssertEqual(controller.dseeMode, .automatic)
        XCTAssertTrue(controller.canSetDSEE)
        XCTAssertNil(controller.settingErrors[.dsee])
    }

    func testLegacyDSEENotificationsRecoverExpiredReadsWithoutLateReturnsRewindingThem() async {
        let cases: [(query: [UInt8], notification: [UInt8], late: [UInt8])] = [
            ([0xE2, 2], [0xE5, 2, 0], [0xE3, 2, 1]),
            ([0xE6, 2], [0xE9, 2, 0, 1], [0xE7, 2, 0, 0]),
        ]
        for testCase in cases {
            for notificationFirst in [false, true] {
                let controller = makeDSEEController()
                defer { controller.simulateControlLoss() }
                controller.refresh()
                acknowledgeAll(controller)
                if notificationFirst { deliver(testCase.notification, to: controller) }
                controller.simulateLegacyDSEEReadTimeout(testCase.query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                if !notificationFirst {
                    XCTAssertFalse(controller.canSetDSEE)
                    deliver(testCase.notification, to: controller)
                }
                XCTAssertTrue(controller.canSetDSEE)
                XCTAssertNil(controller.settingErrors[.dsee])
                let mode = controller.dseeMode
                let available = controller.dseeAvailable
                deliver(testCase.late, to: controller)
                XCTAssertEqual(controller.dseeMode, mode)
                XCTAssertEqual(controller.dseeAvailable, available)
                XCTAssertTrue(controller.canSetDSEE)
            }
        }
    }

    func testQueuedLegacyDSEEWriteRevalidatesAvailabilityBeforeTransmission() {
        let controller = makeDSEEController()
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        controller.refresh()
        controller.setDSEE(.automatic)
        XCTAssertNotNil(controller.pendingChanges[.dsee])
        deliver([0xE5, 2, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xE8 })
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.pendingChanges[.dsee])
        XCTAssertEqual(controller.settingErrors[.dsee], "DSEE became unavailable before the change could be sent.")
    }

    func testUnadvertisedAndPreviousSessionDSEECannotEnableOrConfirmControls() {
        let unsupported = makeController()
        defer { unsupported.simulateControlLoss() }
        deliver([0xE1, 2, 0, 0], to: unsupported)
        deliver([0xE5, 2, 0], to: unsupported)
        deliver([0xE9, 2, 0, 0], to: unsupported)
        unsupported.setDSEE(.automatic)
        XCTAssertFalse(unsupported.supportsDSEE)
        XCTAssertNil(unsupported.dseeMode)
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains { $0.payload.first == 0xE8 })
        let controller = makeDSEEController()
        controller.setDSEE(.automatic)
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        controller.simulateProtocolMessage([0xE9, 2, 0, 1], session: session)
        XCTAssertFalse(controller.supportsDSEE)
        XCTAssertNil(controller.dseeMode)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testLegacyEqualizerMetadataAndStateRequireTheirTransmittedQueries() {
        let controller = beginController()
        defer { controller.simulateControlLoss() }
        deliver([0x07, 0, 2, 0x62, 0x51], to: controller)
        acknowledgeAll(controller)
        deliver(capability, to: controller)
        deliver([0x63, 2, 0], to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x66, 2])
        deliver(ambient, to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x50, 1, 1] })
        let metadata: [UInt8] = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        let replies: [[UInt8]] = [[0x51, 1, 6, 21, 1, 0xA0, 0], [0x53, 1, 0],
                                  [0x5B, 1, 6] + metadata, [0x57, 1, 0xA0, 6, 10, 10, 10, 10, 10, 10]]
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertNil(controller.equalizer.capabilities)
        XCTAssertNil(controller.equalizer.status)
        XCTAssertNil(controller.equalizer.bandInformation)
        XCTAssertNil(controller.equalizer.presetID)
        acknowledgeAll(controller)
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertTrue(controller.equalizer.canEdit)
        XCTAssertEqual(controller.equalizer.settings, .flat)
    }

    func testOptionalLegacyReadDeadlinesRetainMalformedOwnershipAndDrainExpiredReplies() async throws {
        let metadata: [UInt8] = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        let reads: [(query: [UInt8], malformed: [UInt8], reply: [UInt8])] = [
            ([0x10, 1], [0x11, 1, 73, 0, 84], [0x11, 1, 73, 0, 84, 0]),
            ([0x04, 2], [0x05, 2, 5, 0x31], [0x05, 2, 5] + Array("1.2.3".utf8)),
            ([0x50, 1, 1], [0x51, 1, 6, 21, 1, 0xA0], [0x51, 1, 6, 21, 1, 0xA0, 0]),
            ([0x52, 1], [0x53, 1], [0x53, 1, 0]),
            ([0x5A, 1], [0x5B, 1, 6], [0x5B, 1, 6] + metadata),
        ]
        for read in reads {
            let controller = makeController(supportsEqualizer: true)
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            let noise = controller.noiseControlDisplayState
            let timeoutID = try XCTUnwrap(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            let count = controller.simulatedTransmittedFrames.filter { $0.payload == read.query }.count
            deliver(read.malformed, to: controller)
            XCTAssertEqual(controller.simulatedLegacyOptionalReadTimeoutID(read.query), timeoutID)
            controller.simulateLegacyOptionalReadTimeout(read.query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.noiseControlDisplayState, noise)
            deliver(read.malformed, to: controller)
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == read.query }.count, count)
            deliver(read.reply, to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == read.query }.count, count + 1)
            XCTAssertNotNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            switch read.query[0] {
            case 0x10: XCTAssertNil(controller.batteries.left)
            case 0x04: XCTAssertNil(controller.firmwareVersion)
            case 0x50: XCTAssertNil(controller.equalizer.capabilities)
            case 0x52: XCTAssertNil(controller.equalizer.status)
            case 0x5A: XCTAssertNil(controller.equalizer.bandInformation)
            default: XCTFail("Unexpected legacy read")
            }
            deliver(read.reply, to: controller)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            switch read.query[0] {
            case 0x10: XCTAssertEqual(controller.batteries.left?.level, 73)
            case 0x04: XCTAssertEqual(controller.firmwareVersion, "1.2.3")
            case 0x50: XCTAssertNotNil(controller.equalizer.capabilities)
            case 0x52: XCTAssertEqual(controller.equalizer.status, 0)
            case 0x5A: XCTAssertEqual(controller.equalizer.bandInformation, SonyEqualizerBand.legacy)
            default: XCTFail("Unexpected legacy read")
            }
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    func testExplicitRefreshReopensExpiredLegacyReadsWithoutWaitingForOldReplies() async {
        let metadata: [UInt8] = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        let reads: [(query: [UInt8], reply: [UInt8])] = [
            ([0x10, 1], [0x11, 1, 73, 0, 84, 0]),
            ([0x04, 2], [0x05, 2, 5] + Array("1.2.3".utf8)),
            ([0x50, 1, 1], [0x51, 1, 6, 21, 1, 0xA0, 0]),
            ([0x52, 1], [0x53, 1, 0]),
            ([0x5A, 1], [0x5B, 1, 6] + metadata),
        ]
        for read in reads {
            let controller = makeController(supportsEqualizer: true)
            defer { controller.simulateControlLoss() }
            controller.setReconnectAutomatically(false)
            let session = controller.simulatedControlSession
            controller.simulateLegacyOptionalReadTimeout(read.query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            controller.refresh()
            let freshSession = controller.simulatedControlSession
            XCTAssertGreaterThan(freshSession, session)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
            XCTAssertNil(controller.retrySecondsRemaining)
            for _ in 0..<10 {
                controller.refresh()
                controller.simulateAutomaticRefresh()
            }
            XCTAssertEqual(controller.simulatedControlSession, freshSession)
            controller.simulateProtocolMessage(read.reply, session: session)
            XCTAssertNil(controller.batteries.left)
            XCTAssertNil(controller.firmwareVersion)
            XCTAssertNil(controller.equalizer.capabilities)
            XCTAssertNil(controller.equalizer.status)
            XCTAssertNil(controller.equalizer.bandInformation)
            deliver([0x01, 0, 2, 0x10], to: controller)
            acknowledgeAll(controller)
            deliver([0x07, 0, 5, 0x15, 0x18, 0x62, 0x23, 0x51], to: controller)
            acknowledgeAll(controller)
            deliver(capability, to: controller)
            deliver([0x63, 2, 0], to: controller)
            acknowledgeAll(controller)
            deliver(ambient, to: controller)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertNotNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            deliver(read.reply, to: controller)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            switch read.query[0] {
            case 0x10: XCTAssertEqual(controller.batteries.left?.level, 73)
            case 0x04: XCTAssertEqual(controller.firmwareVersion, "1.2.3")
            case 0x50: XCTAssertNotNil(controller.equalizer.capabilities)
            case 0x52: XCTAssertEqual(controller.equalizer.status, 0)
            case 0x5A: XCTAssertEqual(controller.equalizer.bandInformation, SonyEqualizerBand.legacy)
            default: XCTFail("Unexpected legacy read")
            }
        }
    }

    func testExplicitRefreshPreservesInFlightCommandDespiteExpiredOptionalRead() async {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        controller.simulateLegacyOptionalReadTimeout([0x10, 1])
        for _ in 0..<4 { await Task.yield() }
        controller.setNoiseControl(.anc)
        let pending = controller.pendingChanges[.noiseControl]
        XCTAssertNotNil(pending)
        controller.refresh()
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.pendingChanges[.noiseControl], pending)
        XCTAssertTrue(controller.isReady)
    }

    func testExpiredLegacyBatteryReplyPreservesNotificationAndFreshPollOwnership() async {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let query: [UInt8] = [0x10, 1]
        deliver([0x13, 1, 82, 0, 83, 0], to: controller)
        controller.simulateLegacyOptionalReadTimeout(query)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.batteries.left?.level, 82)
        let count = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
        deliver([0x11, 1, 20, 0, 21, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.batteries.left?.level, 82)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, count + 1)
        deliver([0x11, 1, 84, 0, 85, 0], to: controller)
        XCTAssertEqual(controller.batteries.left?.level, 84)
        XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(query))
        XCTAssertTrue(controller.isReady)
    }

    func testSameTransportHandshakeRetainsExpiredLegacyMetadataOwnership() async {
        let controller = makeController(supportsEqualizer: true)
        defer { controller.simulateControlLoss() }
        let query: [UInt8] = [0x50, 1, 1]
        let reply: [UInt8] = [0x51, 1, 6, 21, 1, 0xA0, 0]
        let metadata: [UInt8] = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        for payload: [UInt8] in [[0x11, 1, 70, 0, 71, 0], [0x11, 2, 72, 0],
                                [0x05, 2, 5] + Array("1.2.3".utf8), [0x53, 1, 0],
                                [0x5B, 1, 6] + metadata, [0x57, 1, 0xA0, 0]] {
            deliver(payload, to: controller)
        }
        XCTAssertNotNil(controller.simulatedLegacyOptionalReadTimeoutID(query))
        controller.simulateLegacyOptionalReadTimeout(query)
        for _ in 0..<4 { await Task.yield() }
        let count = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
        let session = controller.simulatedControlSession
        controller.simulateSameTransportHandshake()
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])
        deliver([0x01, 0, 2, 0x10], to: controller)
        acknowledgeAll(controller)
        deliver([0x07, 0, 4, 0x15, 0x18, 0x62, 0x51], to: controller)
        acknowledgeAll(controller)
        deliver(capability, to: controller)
        deliver([0x63, 2, 0], to: controller)
        acknowledgeAll(controller)
        deliver(ambient, to: controller)
        acknowledgeAll(controller)
        deliver([0x53, 1, 0], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.equalizer.available, true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, count)
        deliver([0x51, 1, 6, 21, 1, 0xA0], to: controller)
        XCTAssertNil(controller.equalizer.capabilities)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, count)
        deliver(reply, to: controller)
        acknowledgeAll(controller)
        XCTAssertNil(controller.equalizer.capabilities)
        XCTAssertFalse(controller.equalizer.canSelectPreset)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, count + 1)
        deliver(reply, to: controller)
        XCTAssertNotNil(controller.equalizer.capabilities)
        XCTAssertTrue(controller.equalizer.canSelectPreset)
        XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(query))
    }

    func testMissingEqualizerParameterReplyReopensTransportForRequestedVerification() async {
        let controller = makeController(supportsEqualizer: true, supportsConnectionQuality: true)
        defer { controller.simulateControlLoss() }
        let metadata: [UInt8] = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        for payload: [UInt8] in [[0x11, 1, 70, 0, 71, 0], [0x11, 2, 72, 0],
                                [0x05, 2, 5] + Array("1.2.3".utf8),
                                [0x51, 1, 6, 21, 1, 0xA0, 0], [0x53, 1, 0], [0x5B, 1, 6] + metadata,
                                [0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] {
            deliver(payload, to: controller)
        }
        XCTAssertTrue(controller.canChangeConnectionMode)
        controller.setConnectionMode(.stableConnection)
        acknowledgeAll(controller)
        controller.simulateConnectionModeTimeout()
        controller.connect()
        deliver([0xE7, 1, 0, 0], to: controller)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        let session = controller.simulatedControlSession
        let setters = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }
        controller.simulateEqualizerReadTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertEqual(controller.connectionTransition?.phase, .recovering)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNotNil(controller.retrySecondsRemaining)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage([0x57, 1, 0xA0, 0], session: session)
        XCTAssertNil(controller.equalizer.presetID)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }, setters)
    }

    func testFreshEqualizerReadReconcilesFailedWriteWithoutAcceptingOlderRead() async {
        for readState in ["fresh", "older", "expired", "matching"] {
            let controller = makeController(supportsEqualizer: true, supportsConnectionQuality: true)
            defer { controller.simulateControlLoss() }
            for payload: [UInt8] in [[0x51, 1, 6, 21, 2, 0xA0, 0, 0x16, 0], [0x53, 1, 0],
                                    [0x57, 1, 0x16, 0], [0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] {
                deliver(payload, to: controller)
            }
            acknowledgeAll(controller)
            XCTAssertTrue(controller.canChangeConnectionMode)
            if readState == "older" {
                controller.refreshEqualizer()
                acknowledgeAll(controller)
            }
            controller.setEqualizerPreset(.manual)
            acknowledgeAll(controller)
            controller.simulateSettingTimeout(.equalizer)
            for _ in 0..<4 { await Task.yield() }
            let issue = controller.settingErrors[.equalizer]
            XCTAssertNotNil(issue)
            XCTAssertFalse(controller.canChangeConnectionMode)
            controller.refreshEqualizer()
            if readState == "expired" {
                acknowledgeAll(controller)
                controller.simulateEqualizerReadTimeout()
                for _ in 0..<4 { await Task.yield() }
            }
            if readState == "older" || readState == "expired" {
                deliver([0x57, 1, 0x16, 0], to: controller)
                XCTAssertFalse(controller.canChangeConnectionMode)
                XCTAssertEqual(controller.settingErrors[.equalizer], issue)
            }
            acknowledgeAll(controller)
            let actualPreset: EqualizerPreset = readState == "matching" ? .manual : .bassBoost
            deliver([0x57, 1, actualPreset.rawValue, 0], to: controller)
            XCTAssertTrue(controller.canChangeConnectionMode)
            XCTAssertEqual(controller.settingErrors[.equalizer], readState == "matching" ? nil : issue)
            XCTAssertEqual(controller.equalizerPreset, actualPreset)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.count, 1)
        }
    }

    func testLegacyEqualizerUsesOwnedReadsAndConfirmsTheExactManualCurve() async throws {
        let controller = makeController(supportsEqualizer: true)
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.equalizer.generation, .v1)
        XCTAssertEqual(controller.equalizer.inquiryType, 1)
        let queries: Set<[UInt8]> = [[0x50, 1, 1], [0x52, 1], [0x5A, 1], [0x56, 1]]
        let sentQueries = Set(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload))
        XCTAssertTrue(queries.isSubset(of: sentQueries))
        deliver([0x51, 0, 6, 21, 1, 0xA0, 0], to: controller)
        deliver([0x51, 1, 6, 21, 1, 0xA0], to: controller)
        XCTAssertNil(controller.equalizer.capabilities)
        deliver([0x51, 1, 6, 21, 3, 0xA0, 0, 0x16, 0, 0, 0], to: controller)
        deliver([0x53, 1, 0], to: controller)
        let metadata: [UInt8] = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        deliver([0x5B, 1, 6] + metadata, to: controller)
        deliver([0x57, 1, 0x16, 6, 10, 10, 10, 10, 10, 10], to: controller)
        XCTAssertTrue(controller.equalizer.requiresManualSelection)
        XCTAssertFalse(controller.equalizer.canEdit)
        controller.setEqualizerPreset(.manual)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 1, 0xA0, 0])
        acknowledgeAll(controller)
        deliver([0x59, 1, 0xA0, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizer])
        XCTAssertNil(controller.equalizer.settings)
        XCTAssertTrue(controller.equalizer.canEdit)
        controller.setEqualizerPreset(.manual)
        acknowledgeAll(controller)
        deliver([0x59, 1, 0xA0, 6, 10, 10, 10, 10, 10, 10], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizer])

        var curve = try XCTUnwrap(controller.equalizer.flatSettings)
        curve.values = [-10, -5, 0, 3, 7, 10]
        let request: [UInt8] = [0x58, 1, 0xFF, 6, 0, 5, 10, 13, 17, 20]
        controller.setCustomEqualizer(curve)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, request)
        acknowledgeAll(controller)
        for reply: [UInt8] in [
            [0x59, 1, 0x16, 6, 0, 5, 10, 13, 17, 20],
            [0x59, 1, 0xFF, 6, 0, 5, 10, 13, 17, 20],
            [0x59, 1, 0xA0, 0], [0x59, 1, 0xA0, 6, 0, 5, 10, 13, 17, 19],
        ] {
            deliver(reply, to: controller)
            XCTAssertNotNil(controller.pendingChanges[.equalizer], "\(reply)")
        }
        deliver([0x59, 1, 0xA0, 6, 0, 5, 10, 13, 17, 20], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizer])
        XCTAssertEqual(controller.equalizer.settings, curve)

        controller.refreshEqualizer()
        acknowledgeAll(controller)
        curve[0] = -9
        controller.setCustomEqualizer(curve)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeAll(controller)
        let current: [UInt8] = [0x57, 1, 0xA0, 6, 1, 5, 10, 13, 17, 20]
        deliver(current, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x56, 1])
        acknowledgeAll(controller)
        deliver(current, to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizer])
        XCTAssertEqual(controller.equalizer.settings, curve)

        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeAll(controller)
        deliver([0x57, 1, 0xA0, 0], to: controller)
        XCTAssertNil(controller.equalizer.settings)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.settingErrors[.equalizerReadback], "The headphones did not report an equalizer curve.")
        controller.refreshEqualizer(trackConfirmation: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x56, 1])
        acknowledgeAll(controller)
        deliver(current, to: controller)
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertNil(controller.settingErrors[.equalizerReadback])
        XCTAssertEqual(controller.equalizer.settings, curve)

        controller.refreshEqualizer()
        let settersBefore = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.count
        curve[0] = -8
        controller.setCustomEqualizer(curve)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        deliver([0x55, 1, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.count, settersBefore)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNil(controller.equalizer.capabilities)
        deliver(current, to: controller)
        XCTAssertNil(controller.equalizer.settings)
    }

    func testLegacyPauseMetadataRequiresActualReadsAndMatchingKnownType() {
        let controller = beginWearingController()
        defer { controller.simulateControlLoss() }
        let replies: [[UInt8]] = [[0xF1, 3, 0], [0xF3, 3, 0], [0xF7, 3, 0, 0]]
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertNil(controller.legacyControls?.wearingControl.settingType)
        XCTAssertNil(controller.legacyControls?.wearingControl.available)
        XCTAssertNil(controller.systemFeatureState(.pauseOnRemoval)?.enabled)
        XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
        acknowledgeAll(controller)
        for reply in replies { deliver(reply, type: 0x0E, to: controller) }
        for reply: [UInt8] in [[0xF1, 3], [0xF3, 3, 0, 0], [0xF7, 3, 0]] { deliver(reply, to: controller) }
        XCTAssertNil(controller.legacyControls?.wearingControl.settingType)
        XCTAssertNil(controller.systemFeatureState(.pauseOnRemoval)?.enabled)
        deliver([0xF3, 3, 0], to: controller)
        deliver([0xF7, 3, 0, 0], to: controller)
        XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
        deliver([0xF1, 3, 0], to: controller)
        XCTAssertTrue(controller.canSetSystemFeature(.pauseOnRemoval))
        XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, false)
        deliver([0xF1, 3, 1], to: controller)
        XCTAssertEqual(controller.legacyControls?.wearingControl.settingType, 0)
        XCTAssertTrue(controller.touchAssignments.queryPayloads.isEmpty)
    }

    func testLegacyPauseWritesUseInverseBooleanAndNeedTransmittedConfirmation() {
        let controller = makeWearingController()
        defer { controller.simulateControlLoss() }
        for enabled in [true, false] {
            controller.defersSimulatedWrites = true
            let transmitted = controller.simulatedTransmittedFrames.count
            controller.setSystemFeature(.pauseOnRemoval, enabled: enabled)
            let expected: [UInt8] = [0xF8, 3, 0, enabled ? 1 : 0]
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, expected)
            XCTAssertFalse(controller.simulatedTransmittedFrames.dropFirst(transmitted).contains { $0.payload == expected })
            controller.defersSimulatedWrites = false
            deliver([0xF9, 3, 0, enabled ? 1 : 0], to: controller)
            XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, enabled)
            XCTAssertEqual(controller.pendingChanges[.system(.pauseOnRemoval)], [enabled ? 0 : 1])
            controller.completeSimulatedWrite()
            acknowledgeAll(controller)
            XCTAssertEqual(controller.simulatedTransmittedFrames.last { $0.payload.first == 0xF8 }?.payload, expected)
            XCTAssertNotNil(controller.pendingChanges[.system(.pauseOnRemoval)])
            deliver([0xF7, 3, 0, enabled ? 1 : 0], to: controller)
            deliver([0xF9, 3, 1, enabled ? 1 : 0], to: controller)
            XCTAssertNotNil(controller.pendingChanges[.system(.pauseOnRemoval)])
            XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
            deliver([0xF9, 3, 0, enabled ? 1 : 0], to: controller)
            XCTAssertNil(controller.pendingChanges[.system(.pauseOnRemoval)])
            XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, enabled)
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.map(\.payload),
                       [[0xF8, 3, 0, 1], [0xF8, 3, 0, 0]])
    }

    func testLegacyPauseOldReadsCannotRewindKnownOrUnknownNotifications() {
        for unknown in [false, true] {
            let controller = makeWearingController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0xF9, 3, 0, unknown ? 0xFF : 1], to: controller)
            deliver([0xF5, 3, unknown ? 0xFF : 1], to: controller)
            deliver([0xF7, 3, 0, 0], to: controller)
            deliver([0xF3, 3, 0], to: controller)
            XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, unknown ? nil : true)
            XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.available, unknown ? nil : false)
            XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
        }
    }

    func testLegacyPausePrewritePollCannotConfirmOrResolveTimedOutChange() async {
        for expires in [false, true] {
            let controller = makeWearingController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            controller.setSystemFeature(.pauseOnRemoval, enabled: true)
            acknowledgeAll(controller)
            if expires {
                controller.simulateSettingTimeout(.system(.pauseOnRemoval))
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.pendingChanges[.system(.pauseOnRemoval)])
                XCTAssertNotNil(controller.settingErrors[.system(.pauseOnRemoval)])
            }
            XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
            let count = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.count
            controller.setSystemFeature(.pauseOnRemoval, enabled: false)
            controller.setSystemFeature(.pauseOnRemoval, enabled: true)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.count, count)
            deliver([0xF7, 3, 0, 1], to: controller)
            XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, false)
            XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
            if !expires { XCTAssertNotNil(controller.pendingChanges[.system(.pauseOnRemoval)]) }
            acknowledgeAll(controller)
            deliver([0xF7, 3, 0, expires ? 0 : 1], to: controller)
            XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, !expires)
            XCTAssertTrue(controller.canSetSystemFeature(.pauseOnRemoval))
            XCTAssertNil(controller.pendingChanges[.system(.pauseOnRemoval)])
            XCTAssertNil(controller.settingErrors[.system(.pauseOnRemoval)])
        }
    }

    func testQueuedLegacyPauseRevalidatesAvailabilityAndCurrentType() {
        for change: [UInt8] in [[0xF5, 3, 1], [0xF5, 3, 0xFF], [0xF9, 3, 1, 0], [0xF9, 3, 0, 0xFF]] {
            let controller = makeWearingController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            controller.setSystemFeature(.pauseOnRemoval, enabled: true)
            XCTAssertNotNil(controller.pendingChanges[.system(.pauseOnRemoval)])
            deliver(change, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xF8 })
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            XCTAssertTrue(controller.isReady)
        }
    }

    func testLegacyPauseUnknownReadRepliesKeepDeadlinesAndResetWithSession() async {
        let cases: [(query: [UInt8], unknown: [UInt8])] = [
            ([0xF0, 3], [0xF1, 3, 0xFF]),
            ([0xF2, 3], [0xF3, 3, 0xFF]),
            ([0xF6, 3], [0xF7, 3, 0, 0xFF]),
        ]
        for testCase in cases {
            let controller = beginWearingController()
            defer { controller.simulateControlLoss() }
            controller.simulateSystemReadTimeout(testCase.query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == testCase.query })
            deliver(testCase.unknown, to: controller)
            let session = controller.simulatedControlSession
            controller.simulateSystemReadTimeout(testCase.query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
            XCTAssertNotNil(controller.noiseControlMode)
            controller.simulateDeviceConnection(named: "WF-1000XM4", galleryModel: .wfXM4)
            controller.simulateProtocolMessage([0xF9, 3, 0, 1], session: session)
            controller.simulateSystemReadTimeout(testCase.query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.systemFeatureState(.pauseOnRemoval))
        }
    }

    func testExpiredLegacyPauseReadRequiresFreshTypedReplyWithoutDisconnecting() async {
        let controller = makeWearingController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        let query: [UInt8] = [0xF6, 3]
        let reads = controller.simulatedTransmittedFrames.filter { $0.payload == query }.count
        let session = controller.simulatedControlSession
        controller.simulateSystemReadTimeout(query)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertFalse(controller.canSetSystemFeature(.pauseOnRemoval))
        XCTAssertNotNil(controller.noiseControlMode)
        deliver([0xF7, 3, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, reads)
        deliver([0xF7, 3, 0, 1], to: controller)
        XCTAssertNil(controller.systemFeatureState(.pauseOnRemoval)?.enabled)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }.count, reads + 1)
        deliver([0xF7, 3, 0, 0], to: controller)
        XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, false)
        XCTAssertTrue(controller.canSetSystemFeature(.pauseOnRemoval))
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    func testLegacyPauseAndV2TouchUseTheirOwnNegotiatedInquiryThreeDialect() {
        let unsupported = makeController()
        defer { unsupported.simulateControlLoss() }
        for reply: [UInt8] in [[0xF1, 3, 0], [0xF5, 3, 0], [0xF9, 3, 0, 1]] { deliver(reply, to: unsupported) }
        unsupported.setSystemFeature(.pauseOnRemoval, enabled: true)
        XCTAssertNil(unsupported.systemFeatureState(.pauseOnRemoval))
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains { $0.payload.first == 0xF8 })
        let legacy = makeWearingController()
        defer { legacy.simulateControlLoss() }
        deliver([0xF9, 3, 2, 0x20, 0x35], to: legacy)
        XCTAssertEqual(legacy.systemFeatureState(.pauseOnRemoval)?.enabled, false)
        XCTAssertNil(legacy.touchAssignments.selectedPresets)
        let modern = SonyHeadphonesController(startAutomatically: false, simulated: true)
        modern.simulateDeviceConnection(named: "WF-1000XM5")
        defer { modern.simulateControlLoss() }
        let selected = modern.touchAssignments.selectedPresets
        deliver([0xF9, 3, 0, 0], to: modern)
        XCTAssertEqual(modern.touchAssignments.selectedPresets, selected)
        XCTAssertEqual(modern.systemFeatureState(.pauseOnRemoval)?.enabled, true)
        deliver([0xF9, 3, 2, 0x20, 0x35], to: modern)
        XCTAssertEqual(modern.touchAssignments.selectedPresets, [0x20, 0x35])
        XCTAssertEqual(modern.systemFeatureState(.pauseOnRemoval)?.enabled, true)
    }

    func testLegacyPowerPolicyOwnsItsTypedReadsAndUnknownTypeKeepsTheDeadline() async {
        let controller = beginPowerPolicyController()
        defer { controller.simulateControlLoss() }
        let replies: [[UInt8]] = [[0xF1, 4, 3, 0x10, 0x11, 1], [0xF3, 4, 0], [0xF7, 4, 1, 0x10, 3]]
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertNil(controller.automaticPowerOff?.options)
        XCTAssertNil(controller.automaticPowerOff?.current)
        controller.simulateSystemReadTimeout([0xF6, 4])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        acknowledgeAll(controller)
        for reply in replies { deliver(reply, type: 0x0E, to: controller) }
        for reply: [UInt8] in [[0x21, 4, 2, 0, 0x11], [0x23, 4, 0], [0x27, 4, 0, 0], [0xF7, 4, 0x10, 3]] {
            deliver(reply, to: controller)
        }
        XCTAssertNil(controller.automaticPowerOff?.options)
        XCTAssertNil(controller.automaticPowerOff?.current)
        for reply in replies { deliver(reply, to: controller) }
        XCTAssertTrue(controller.canSetAutomaticPowerOff)
        XCTAssertNil(controller.systemFeatures.automaticPowerOff)
        controller.refresh()
        acknowledgeAll(controller)
        deliver([0xF7, 4, 0, 0x10, 3], to: controller)
        XCTAssertFalse(controller.canSetAutomaticPowerOff)
        XCTAssertEqual(controller.automaticPowerOff?.parameterType, 0)
        let session = controller.simulatedControlSession
        controller.simulateSystemReadTimeout([0xF6, 4])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.isDeviceConnected)
        XCTAssertFalse(controller.canSetAutomaticPowerOff)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNotNil(controller.noiseControlMode)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0xF9, 4, 1, 0x11, 3], session: session)
        deliver([0xF9, 4, 1, 0x11, 3], to: controller)
        controller.simulateSystemReadTimeout([0xF6, 4])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.automaticPowerOff?.current?.rawValue, 0x10)
        XCTAssertEqual(controller.automaticPowerOff?.last?.rawValue, 0)
    }

    func testLegacyPowerPolicyWritesAndConfirmationKeepTypeAndRememberedTimer() {
        let controller = makePowerPolicyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF8, 4, 1, 0x11, 3])
        controller.defersSimulatedWrites = false
        deliver([0xF9, 4, 1, 0x11, 3], to: controller)
        XCTAssertEqual(controller.automaticPowerOff?.current?.rawValue, 0x11)
        XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xF8 })
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
        for reply: [UInt8] in [[0xF7, 4, 1, 0x11, 3], [0x29, 4, 0x11, 3], [0xF9, 4, 0, 0x11, 3], [0xF9, 4, 1, 0x11, 1]] {
            deliver(reply, to: controller)
            XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
        }
        deliver([0xF9, 4, 1, 0x11, 3], to: controller)
        XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
        controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 1))
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.map(\.payload),
                       [[0xF8, 4, 1, 0x11, 3], [0xF8, 4, 1, 1, 1]])
        deliver([0xF9, 4, 1, 1, 3], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
        deliver([0xF9, 4, 1, 1, 1], to: controller)
        XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
    }

    func testLegacyPowerPolicyOldTupleCannotConfirmOrResolveUncertainty() async {
        for expires in [false, true] {
            let controller = makePowerPolicyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0xF5, 4, 0], to: controller)
            deliver([0xF9, 4, 1, 0x10, 3], to: controller)
            deliver([0xF3, 4, 1], to: controller)
            XCTAssertEqual(controller.automaticPowerOff?.available, true)
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
            acknowledgeAll(controller)
            if expires {
                controller.simulateSettingTimeout(.automaticPowerOff)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
                XCTAssertNotNil(controller.settingErrors[.automaticPowerOff])
            } else {
                XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
            }
            XCTAssertFalse(controller.canSetAutomaticPowerOff)
            let writes = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.map(\.payload)
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x10))
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xF8 }.map(\.payload), writes)
            deliver([0xF7, 4, 1, 0x11, 3], to: controller)
            XCTAssertEqual(controller.automaticPowerOff?.current?.rawValue, 0x10)
            XCTAssertFalse(controller.canSetAutomaticPowerOff)
            acknowledgeAll(controller)
            deliver([0xF7, 4, 1, expires ? 0x10 : 0x11, 3], to: controller)
            XCTAssertNil(controller.pendingChanges[.automaticPowerOff])
            XCTAssertNil(controller.settingErrors[.automaticPowerOff])
            XCTAssertTrue(controller.canSetAutomaticPowerOff)
            XCTAssertEqual(controller.automaticPowerOff?.current?.rawValue, expires ? 0x10 : 0x11)
        }
    }

    func testLegacyPowerPolicyQueuedChoiceCannotOverwriteNewRememberedTimer() {
        for changed: [UInt8] in [[0xF9, 4, 1, 0x10, 2], [0xF5, 4, 1]] {
            let controller = makePowerPolicyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            controller.setAutomaticPowerOff(SonyAutomaticPowerOffOption(rawValue: 0x11))
            XCTAssertNotNil(controller.pendingChanges[.automaticPowerOff])
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xF8 })
            deliver(changed, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xF8 })
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
    }

    private func beginController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array("WF-1000XM4".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0x30, 0xFF], to: controller)
        return controller
    }

    private func makeController(capability: [UInt8]? = nil, state: [UInt8]? = nil, available: UInt8 = 0,
                                supportsDSEE: Bool = false, supportsEqualizer: Bool = false,
                                supportsConnectionQuality: Bool = false) -> SonyHeadphonesController {
        let controller = beginController()
        let functions: [UInt8] = [0x15, 0x18, 0x62, 0x23] + (supportsDSEE ? [0xE2] : []) + (supportsEqualizer ? [0x51] : [])
            + (supportsConnectionQuality ? [0xE1] : [])
        deliver([0x07, 0, UInt8(functions.count)] + functions, to: controller)
        acknowledgeAll(controller)
        deliver(capability ?? self.capability, to: controller)
        deliver([0x63, 2, available], to: controller)
        acknowledgeAll(controller)
        deliver(state ?? ambient, to: controller)
        acknowledgeAll(controller)
        return controller
    }

    private func makeDSEEController() -> SonyHeadphonesController {
        let controller = makeController(supportsDSEE: true)
        deliver([0xE1, 2, 0, 0], to: controller)
        deliver([0xE3, 2, 0], to: controller)
        deliver([0xE7, 2, 0, 0], to: controller)
        return controller
    }

    private func beginWearingController() -> SonyHeadphonesController {
        let controller = beginController()
        deliver([0x07, 0, 2, 0x62, 0xF3], to: controller)
        acknowledgeAll(controller)
        deliver(capability, to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver(ambient, to: controller)
        return controller
    }

    private func makeWearingController() -> SonyHeadphonesController {
        let controller = beginWearingController()
        acknowledgeAll(controller)
        for reply: [UInt8] in [[0xF1, 3, 0], [0xF3, 3, 0], [0xF7, 3, 0, 0]] { deliver(reply, to: controller) }
        XCTAssertTrue(controller.canSetSystemFeature(.pauseOnRemoval))
        return controller
    }

    private func beginPowerPolicyController() -> SonyHeadphonesController {
        let controller = beginController()
        deliver([0x07, 0, 2, 0x62, 0xF4], to: controller)
        acknowledgeAll(controller)
        deliver(capability, to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver(ambient, to: controller)
        return controller
    }

    private func makePowerPolicyController() -> SonyHeadphonesController {
        let controller = beginPowerPolicyController()
        acknowledgeAll(controller)
        for reply: [UInt8] in [[0xF1, 4, 3, 0x10, 0x11, 1], [0xF3, 4, 0], [0xF7, 4, 1, 0x10, 3]] {
            deliver(reply, to: controller)
        }
        XCTAssertTrue(controller.canSetAutomaticPowerOff)
        return controller
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }
}

@MainActor
final class SonyLegacyMultipointTests: XCTestCase {
    private let address = "02:53:4F:4E:59:01"
    // Replies captured from a WH-1000XM4 (MDR v1, firmware 3.0.1).
    private let multipointIdentity: [UInt8] = [0xD1, 0xD2, 0x02, 0x12] + Array("MULTIPOINT_SETTING".utf8)
        + [0x1A] + Array("MULTIPOINT_SETTING_SUMMARY".utf8) + [0x01, 0x00]

    func testWHXM4ReadsAndChangesMultipointOverMDRV1() throws {
        let (_, headphones) = try preparedXM4(multipointEnabled: false)
        defer { headphones.simulateControlLoss() }
        XCTAssertEqual(headphones.systemFeatures.multipointSlot, 0xD2)
        XCTAssertEqual(headphones.systemFeatures.multipoint?.enabled, false)
        XCTAssertNotNil(MultipointSettingControl.enabled(for: headphones))
        XCTAssertTrue(MultipointSettingControl.showsMenuEntry(for: headphones))
        XCTAssertFalse(MultipointSettingControl.showsMenuEntry(for: SonyHeadphonesController(startAutomatically: false, simulated: true)))
        XCTAssertNil(headphones.multipointUnavailableReason)
        XCTAssertFalse(headphones.ldacRequiresMultipointOff)
        let sent = headphones.simulatedTransmittedFrames.map(\.payload)
        XCTAssertTrue(sent.contains([0xD0, 0xD2, 0x01]))
        XCTAssertTrue(sent.contains([0xD6, 0xD2]))

        headphones.setMultipointEnabled(true)
        XCTAssertEqual(headphones.simulatedPendingFrame?.payload, [0xD8, 0xD2, 0x01, 0x01])
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage([0x99, 0x01, 0x06, 0x01])
        let alert = try XCTUnwrap(headphones.multipointTransition?.alert)
        XCTAssertEqual(alert.format, .legacyFixed)
        XCTAssertEqual(alert.messageID, 0x06)
        headphones.respondToMultipointAlert(alert, action: .positive)
        XCTAssertEqual(headphones.simulatedPendingFrame?.payload, [0x98, 0x01, 0x06, 0x01])
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage([0xD9, 0xD2, 0x01, 0x01])
        XCTAssertEqual(headphones.simulatedPendingFrame?.payload, [0xD6, 0xD2])
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage([0xD7, 0xD2, 0x01, 0x01])
        XCTAssertEqual(headphones.multipointTransition?.phase, .complete)
        XCTAssertEqual(headphones.systemFeatures.multipoint?.enabled, true)
        XCTAssertTrue(headphones.ldacRequiresMultipointOff)
    }

    func testOnlyTheWHXM4NeedsMultipointOffForLDAC() {
        XCTAssertEqual(SonyDeviceModel.allCases.filter(\.offersLDACOnlyWithoutMultipoint), [.whXM4])
    }

    func testLDACAsksBeforeTurningMultipointOffAndKeepingItChangesNothing() async throws {
        let (coordinator, headphones) = try preparedXM4(multipointEnabled: true)
        defer { headphones.simulateControlLoss() }
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
        XCTAssertTrue(headphones.ldacRequiresMultipointOff)
        let frames = headphones.simulatedTransmittedFrames.count

        ldac.setEnabled(true, forAddress: address)
        XCTAssertEqual(ldac.multipointConflictAddress, address)
        XCTAssertFalse(ldac.isSessionRunning)
        XCTAssertEqual(ldac.state, .off)
        ldac.resolveMultipointConflict(turnOffMultipoint: false)
        XCTAssertNil(ldac.multipointConflictAddress)
        XCTAssertNil(ldac.multipointShutdownAddress)
        XCTAssertFalse(ldac.isSessionRunning)
        XCTAssertNil(headphones.multipointTransition)
        XCTAssertEqual(headphones.simulatedTransmittedFrames.count, frames)
        XCTAssertEqual(headphones.systemFeatures.multipoint?.enabled, true)

        ldac.setEnabled(true, forAddress: address)
        ldac.resolveMultipointConflict(turnOffMultipoint: true)
        XCTAssertNil(ldac.multipointConflictAddress)
        XCTAssertEqual(ldac.multipointShutdownAddress, address)
        XCTAssertFalse(ldac.isSessionRunning)
        XCTAssertEqual(headphones.multipointTransition?.targetEnabled, false)
        XCTAssertEqual(headphones.simulatedPendingFrame?.payload, [0xD8, 0xD2, 0x01, 0x00])
        ldac.setEnabled(true, forAddress: address)
        XCTAssertNil(ldac.multipointConflictAddress)

        // Turning multipoint off makes a WH-1000XM4 ask with MDR v1 alert 0x07; the flow answers it for the user.
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage([0x99, 0x01, 0x07, 0x01])
        for _ in 0..<40 where headphones.simulatedPendingFrame?.payload != [0x98, 0x01, 0x07, 0x01] {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(headphones.simulatedPendingFrame?.payload, [0x98, 0x01, 0x07, 0x01])
        XCTAssertNil(headphones.multipointTransition?.alert)

        headphones.simulateMultipointTimeout()
        XCTAssertEqual(headphones.multipointTransition?.phase, .failed)
        for _ in 0..<40 where ldac.multipointShutdownAddress != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(ldac.multipointShutdownAddress)
        XCTAssertFalse(ldac.isSessionRunning)
        guard case .failed = ldac.state else { return XCTFail("A failed multipoint change must not start LDAC") }
        XCTAssertEqual(ldac.targetAddress, address)
    }

    func testWHXM4ListsDevicesReadOnlyWhenMultipointAnnouncesFunction38() throws {
        let (_, headphones) = try preparedXM4(multipointEnabled: true, extraFunctions: [0x38])
        defer { headphones.simulateControlLoss() }
        XCTAssertTrue(headphones.multipoint.supportsLegacyInventory)
        XCTAssertFalse(headphones.multipoint.supportsInventory)
        XCTAssertEqual(headphones.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x36, 0x01] }.count, 1)
        XCTAssertFalse(MultipointControls.isVisible(for: headphones.multipoint))

        headphones.simulateProtocolMessage(legacyList, type: 0x0E)
        acknowledgeAll(headphones)
        XCTAssertEqual(headphones.multipoint.devices.map(\.name), ["Test Laptop", "Test Phone"])
        XCTAssertEqual(headphones.multipoint.devices.map(\.isConnected), [true, false])
        XCTAssertTrue(MultipointControls.isVisible(for: headphones.multipoint))
        XCTAssertNil(headphones.multipoint.selectedSource)

        let before = headphones.simulatedTransmittedFrames.count
        XCTAssertTrue(headphones.canRefreshDevices)
        headphones.refreshDevices()
        acknowledgeAll(headphones)
        XCTAssertEqual(headphones.simulatedTransmittedFrames.dropFirst(before).map { [$0.type] + $0.payload }, [[0x0E, 0x36, 0x01]])
        XCTAssertNil(headphones.multipoint.peripheralActionPayload(.disconnect, address: "02:00:00:00:00:A1"))
        XCTAssertNil(headphones.multipoint.sourceSwitchPayload(address: "02:00:00:00:00:A1"))
    }

    func testWHXM4WithoutFunction38NeverAsksForOrShowsADeviceList() throws {
        let (_, headphones) = try preparedXM4(multipointEnabled: false)
        defer { headphones.simulateControlLoss() }
        XCTAssertFalse(headphones.multipoint.supportsLegacyInventory)
        XCTAssertFalse(headphones.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x36 })
        headphones.simulateProtocolMessage(legacyList, type: 0x0E)
        XCTAssertTrue(headphones.multipoint.devices.isEmpty)
        let before = headphones.simulatedTransmittedFrames.count
        headphones.refreshDevices()
        XCTAssertEqual(headphones.simulatedTransmittedFrames.count, before)
        XCTAssertFalse(MultipointControls.isVisible(for: headphones.multipoint))
    }

    /// `37 01` as captured from a WH-1000XM4 (2 of 8 entries), with invented addresses and names.
    private var legacyList: [UInt8] {
        let laptop = Array("Test Laptop".utf8), phone = Array("Test Phone".utf8)
        return [0x37, 0x01, 0x02] + Array("02:00:00:00:00:A1".utf8) + [1, UInt8(laptop.count)] + laptop
            + Array("02:00:00:00:00:A2".utf8) + [0, UInt8(phone.count)] + phone + [1]
    }

    private func preparedXM4(multipointEnabled: Bool, extraFunctions: [UInt8] = []) throws -> (SonyDeviceCoordinator, SonyHeadphonesController) {
        let coordinator = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            SonyHeadphonesController(startAutomatically: false, simulated: true, pinnedAddress: device.address, advertisedName: device.name)
        }
        coordinator.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: "WH-1000XM4", model: .whXM4))])
        let headphones = try XCTUnwrap(coordinator.controller(for: address))
        headphones.simulateDeviceConnection(named: "WH-1000XM4", controlBusy: true, simulatedAddress: address)
        headphones.simulateProtocolMessage([0x01, 0, 0x70, 0], beginConnection: true)
        acknowledgeAll(headphones)
        let name = Array("WH-1000XM4".utf8)
        headphones.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
        headphones.simulateProtocolMessage([0x05, 3, 0x30, 0x01])
        headphones.simulateProtocolMessage([0x07, 0, UInt8(3 + extraFunctions.count), 0x11, 0xA1, 0xD2] + extraFunctions)
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage([0x05, 2, 5] + Array("3.0.1".utf8))
        XCTAssertTrue(headphones.isReady)
        XCTAssertEqual(headphones.deviceModel, .whXM4)
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage(multipointIdentity)
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage([0xD3, 0xD2, 0x00])
        headphones.simulateProtocolMessage([0xD7, 0xD2, 0x01, multipointEnabled ? 0x01 : 0x00])
        acknowledgeAll(headphones)
        return (coordinator, headphones)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }
}
