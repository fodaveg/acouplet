import Foundation
import XCTest
@testable import Acouplet

final class SonyEqualizerTests: XCTestCase {
    func testAdvertisedPresetOrderNamesAndUnknownIdentityArePreserved() {
        var equalizer = SonyEqualizer(supportedFunctions: [0x50])
        let name = Array("Göğüs".utf8)
        XCTAssertTrue(equalizer.update([0x51, 0, 255, 255, 3, 0x31, 0, 0x77, UInt8(name.count)] + name + [0, 0]))
        XCTAssertEqual(equalizer.capabilities?.bandCount, 255)
        XCTAssertEqual(equalizer.capabilities?.levelSteps, 255)
        XCTAssertEqual(equalizer.capabilities?.presets.map(\.id), [0x31, 0x77, 0])
        XCTAssertEqual(equalizer.capabilities?.presets.map(\.title), ["Clear", "Göğüs", "Off"])
        XCTAssertTrue(equalizer.update([0x57, 0, 0xFE, 0]))
        XCTAssertEqual(equalizer.presetID, 0xFE)
        XCTAssertEqual(equalizer.presetTitle, "Preset FE")
        XCTAssertNil(equalizer.presetPayload(0x31))
        XCTAssertTrue(equalizer.update([0x53, 0, 0]))
        XCTAssertEqual(equalizer.presetPayload(0x31), [0x58, 0, 0x31, 0])
        XCTAssertNil(equalizer.presetPayload(0x10))
        XCTAssertNil(equalizer.presetPayload(0xFE))
        XCTAssertFalse(equalizer.canEdit)
    }

    func testMalformedPacketsDoNotReplaceValidatedState() {
        var equalizer = prepared()
        let previous = equalizer
        for payload: [UInt8] in [
            [], [0x51], [0x51, 0, 6, 21, 1], [0x51, 0, 6, 21, 1, 0, 2, 65],
            [0x51, 0, 6, 21, 1, 0, 1, 0xFF], [0x51, 0, 6, 21, 0, 0],
            [0x53, 0], [0x53, 0, 0, 0], [0x5B, 0, 1, 1, 0],
            [0x5B, 0, 1, 1, 0, 31, 0], [0x57, 0, 0xA0, 2, 10],
            [0x59, 0, 0xA0, 0, 10], [0x57, 2, 0xA0, 0],
            [0x59, 0, 0xA0, 5, 10, 10, 10, 10, 10],
            [0x59, 0, 0xA0, 6, 21, 10, 10, 10, 10, 10],
        ] {
            XCTAssertFalse(equalizer.update(payload), "\(payload)")
            XCTAssertEqual(equalizer, previous)
        }
    }

    func testMetadataDecodesUInt16AndKeepsClearBassAtItsActualIndex() throws {
        let layout = Array(SonyEqualizerBand.legacy.dropFirst()) + [.clearBass]
        var equalizer = prepared(layout: layout)
        XCTAssertEqual(equalizer.bandInformation, layout)
        XCTAssertEqual(equalizer.bandInformation?[2].value, 2_500)
        XCTAssertTrue(equalizer.update([0x59, 0, 0xA0, 6, 11, 12, 13, 14, 15, 16]))
        let settings = try XCTUnwrap(equalizer.settings)
        XCTAssertEqual(settings.clearBass, 6)
        XCTAssertEqual(settings.bands, [1, 2, 3, 4, 5])
        XCTAssertEqual(equalizer.settingsPayload(settings), [0x58, 0, 0xA0, 6, 11, 12, 13, 14, 15, 16])
        XCTAssertNil(equalizer.settingsPayload(.flat))
        XCTAssertTrue(equalizer.update([0x59, 0, 0x31, 0]))
        XCTAssertEqual(equalizer.rawValues, [11, 12, 13, 14, 15, 16])
        XCTAssertEqual(equalizer.settings, settings)
    }

    func testTenBandProfilesKeepTheirLayoutRangeAndAllValues() throws {
        let equalizer = prepared(layout: SonyEqualizerBand.tenBand, steps: 13)
        var settings = try XCTUnwrap(equalizer.flatSettings)
        settings[9] = 99
        settings[0] = -99
        XCTAssertEqual(settings.levelRange, -6...6)
        XCTAssertEqual(settings.values, [-6, 0, 0, 0, 0, 0, 0, 0, 0, 6])
        let restored = try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(equalizer.settingsPayload(restored), [0x58, 0, 0xA0, 10, 0, 6, 6, 6, 6, 6, 6, 6, 6, 12])
        XCTAssertNil(equalizer.settingsPayload(.flat))
        XCTAssertNil(prepared().settingsPayload(restored))
        XCTAssertEqual(SonyEqualizerBand(informationType: 2, value: 16).frequency, 16_000)
    }

    func testLegacyProfilesNormalizeButNewProfilesRejectCorruptionInsteadOfTruncating() throws {
        let old = Data(#"{"clearBass":99,"bands":[-99,4]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EqualizerSettings.self, from: old),
                       EqualizerSettings(clearBass: 10, bands: [-10, 4, 0, 0, 0]))
        let short = EqualizerSettings(layout: SonyEqualizerBand.tenBand, levelSteps: 13, values: [0, 0])
        XCTAssertThrowsError(try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(short)))
        var outOfRange = EqualizerSettings(layout: SonyEqualizerBand.tenBand, levelSteps: 13, values: Array(repeating: 0, count: 10))
        outOfRange.values[9] = 7
        XCTAssertThrowsError(try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(outOfRange)))
        XCTAssertNil(prepared(layout: SonyEqualizerBand.tenBand, steps: 13).settingsPayload(outOfRange))
    }

    func testUnavailableStateInvalidatesQueuedCurveAndPresetWrites() throws {
        var equalizer = prepared()
        let curve = try XCTUnwrap(equalizer.settingsPayload(.flat))
        let preset = try XCTUnwrap(equalizer.presetPayload(0))
        XCTAssertTrue(equalizer.acceptsSetPayload(curve))
        XCTAssertTrue(equalizer.acceptsSetPayload(preset))
        XCTAssertFalse(equalizer.acceptsSetPayload([0x58, 0, 0xA0, 6, 21, 10, 10, 10, 10, 10]))
        XCTAssertTrue(equalizer.update([0x55, 0, 1]))
        XCTAssertFalse(equalizer.acceptsSetPayload(curve))
        XCTAssertFalse(equalizer.acceptsSetPayload(preset))
        XCTAssertNotNil(equalizer.settings)
        XCTAssertTrue(equalizer.update([0x55, 0, 0xFE]))
        XCTAssertEqual(equalizer.status, 0xFE)
        XCTAssertNil(equalizer.available)
    }

    func testNoncustomizableAndErrorCodeDialectsUseTheirOwnSchemas() {
        var noncustomizable = prepared(type: 2)
        XCTAssertEqual(noncustomizable.presetPayload(0), [0x58, 2, 0, 0])
        XCTAssertFalse(noncustomizable.canEdit)
        XCTAssertNil(noncustomizable.settingsPayload(.flat))
        XCTAssertFalse(noncustomizable.update([0x55, 0, 0]))
        XCTAssertEqual(noncustomizable.parameterQueryPayload, [0x56, 2])

        var withErrors = prepared(type: 4)
        XCTAssertTrue(withErrors.update([0x55, 4, 1, 2, 0x01, 0xEF]))
        XCTAssertEqual(withErrors.errorCodes, [0x01, 0xEF])
        XCTAssertFalse(withErrors.canSelectPreset)
        XCTAssertFalse(withErrors.update([0x53, 4, 0]))
        XCTAssertFalse(withErrors.update([0x53, 4, 0, 2, 0x01]))
        XCTAssertTrue(withErrors.update([0x53, 4, 0, 0]))
        XCTAssertEqual(withErrors.settingsPayload(.flat).map { Array($0.prefix(2)) }, [0x58, 4])
        XCTAssertEqual(withErrors.parameterQueryPayload, [0x56, 4])
    }

    func testUnsupportedMetadataStepsAndULTNeverBecomeOrdinaryWritableEQ() {
        var equalizer = prepared()
        XCTAssertTrue(equalizer.update([0x5B, 0, 1, 0x7F, 0xBE, 0xEF]))
        XCTAssertEqual(equalizer.bandInformation, [SonyEqualizerBand(informationType: 0x7F, value: 0xBEEF)])
        XCTAssertNotNil(equalizer.rawValues)
        XCTAssertNil(equalizer.settings)
        XCTAssertFalse(equalizer.canEdit)
        for steps: UInt8 in [0, 1, 12] {
            XCTAssertNil(prepared(steps: steps).flatSettings)
        }
        var ult = SonyEqualizer(supportedFunctions: [0x53])
        XCTAssertTrue(ult.update([0x51, 3, 6, 21, 5, 2, 0, 0, 0xA0, 0]))
        XCTAssertEqual(ult.inquiryType, 3)
        XCTAssertEqual(ult.capabilities?.ultAdditionalSteps, 5)
        XCTAssertEqual(ult.capabilities?.presets.map(\.id), [0, 0xA0])
        XCTAssertEqual(ult.queryPayloads, [[0x50, 3, 1]])
        XCTAssertNil(ult.parameterQueryPayload)
        XCTAssertFalse(ult.update([0x53, 3, 0]))
        XCTAssertFalse(ult.update([0x57, 3, 0xA0, 6, 10, 10, 10, 10, 10, 10]))
        XCTAssertNil(ult.presetPayload(0))
        XCTAssertNil(ult.settingsPayload(.flat))
    }

    func testUserSlotCurvesWriteRawValuesForTheSelectedSlotOnly() throws {
        var equalizer = prepared(presets: [0, 0xA0, 0xA1, 0xA2])
        XCTAssertEqual(equalizer.savableSlots, [0xA1, 0xA2])
        var curve = try XCTUnwrap(equalizer.flatSettings)
        curve.values = [-10, -5, 0, 3, 7, 10]
        let raw: [UInt8] = [0, 5, 10, 13, 17, 20]
        XCTAssertEqual(equalizer.curvePayload(curve, target: 0xA1), [0x58, 0, 0xA1, 6] + raw)
        XCTAssertEqual(equalizer.curvePayload(curve, target: 0xA2), [0x58, 0, 0xA2, 6] + raw)
        XCTAssertEqual(equalizer.curvePayload(curve, target: 0xA0), [0x58, 0, 0xA0, 6] + raw)
        XCTAssertNil(equalizer.curvePayload(curve, target: 0xA3))
        XCTAssertNil(equalizer.curvePayload(curve, target: 0x10))
        XCTAssertEqual(equalizer.presetPayload(0xA1), [0x58, 0, 0xA1, 0])
        // The slot has to be the active preset when the frame goes out.
        let toUser1 = try XCTUnwrap(equalizer.curvePayload(curve, target: 0xA1))
        XCTAssertFalse(equalizer.acceptsSetPayload(toUser1))
        XCTAssertTrue(equalizer.update([0x59, 0, 0xA1, 0]))
        XCTAssertTrue(equalizer.acceptsSetPayload(toUser1))
        XCTAssertFalse(equalizer.acceptsSetPayload([0x58, 0, 0xA2, 6] + raw))
        XCTAssertFalse(equalizer.acceptsSetPayload([0x58, 0, 0xA0, 6] + raw))
        // The confirmation is the whole curve in that slot, never the bare selection.
        XCTAssertEqual(equalizer.confirmationValue(toUser1), [0xA1, 6] + raw)
        XCTAssertEqual(equalizer.confirmationValue([0x57, 0, 0xA1, 6] + raw), [0xA1, 6] + raw)
        XCTAssertEqual(equalizer.confirmationValue([0x58, 0, 0xA1, 0]), [0xA1])
        // The re-read `57 00 Ax n ...` is parsed as that slot's curve.
        XCTAssertTrue(equalizer.update([0x57, 0, 0xA1, 6] + raw))
        XCTAssertEqual(equalizer.presetID, 0xA1)
        XCTAssertEqual(equalizer.settings, curve)
        XCTAssertTrue(equalizer.update([0x57, 0, 0xA2, 6] + raw.reversed()))
        XCTAssertEqual(equalizer.presetID, 0xA2)
        XCTAssertNotEqual(equalizer.settings, curve)
        // Slots that are not advertised are not offered.
        XCTAssertEqual(prepared(presets: [0, 0xA0, 0xA2]).savableSlots, [0xA2])
        XCTAssertEqual(prepared().savableSlots, [])
    }

    func testThirteenStepSlotsCenterOnSix() throws {
        var equalizer = prepared(layout: SonyEqualizerBand.tenBand, steps: 13, presets: [0, 0xA0, 0xA1, 0xA2])
        var curve = try XCTUnwrap(equalizer.flatSettings)
        curve.values = [-6, -5, -4, -3, 0, 1, 2, 3, 5, 6]
        let raw: [UInt8] = [0, 1, 2, 3, 6, 7, 8, 9, 11, 12]
        XCTAssertEqual(equalizer.curvePayload(curve, target: 0xA2), [0x58, 0, 0xA2, 10] + raw)
        curve.values[0] = -7
        XCTAssertNil(equalizer.curvePayload(curve, target: 0xA2))
        XCTAssertTrue(equalizer.update([0x57, 0, 0xA2, 10] + raw))
        XCTAssertEqual(equalizer.settings?.values, [-6, -5, -4, -3, 0, 1, 2, 3, 5, 6])
    }

    func testLegacySlotsSelectFirstThenWriteToFFAndReadTheSlotBack() throws {
        var equalizer = SonyEqualizer(supportedFunctions: [0x51], generation: .v1)
        let presets: [UInt8] = [0, 0x16, 0xA0, 0xA1, 0xA2]
        XCTAssertTrue(equalizer.update([0x51, 1, 6, 21, UInt8(presets.count)] + presets.flatMap { [$0, 0] }))
        XCTAssertTrue(equalizer.update([0x53, 1, 0]))
        let bands: [UInt8] = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        XCTAssertTrue(equalizer.update([0x5B, 1, 6] + bands))
        XCTAssertTrue(equalizer.update([0x57, 1, 0x16, 0]))
        XCTAssertEqual(equalizer.savableSlots, [0xA1, 0xA2])
        var curve = try XCTUnwrap(equalizer.flatSettings)
        curve.values = [-10, -5, 0, 3, 7, 10]
        let raw: [UInt8] = [0, 5, 10, 13, 17, 20]
        let write = try XCTUnwrap(equalizer.curvePayload(curve, target: 0xA1))
        XCTAssertEqual(write, [0x58, 1, 0xFF, 6] + raw)
        XCTAssertEqual(equalizer.curvePayload(curve, target: 0xA2), write)
        XCTAssertFalse(equalizer.acceptsSetPayload(write))
        XCTAssertEqual(equalizer.presetPayload(0xA1), [0x58, 1, 0xA1, 0])
        XCTAssertTrue(equalizer.update([0x59, 1, 0xA1, 0]))
        XCTAssertTrue(equalizer.acceptsSetPayload(write))
        XCTAssertEqual(equalizer.confirmationValue(write), [0xA1, 6] + raw)
        XCTAssertTrue(equalizer.update([0x57, 1, 0xA1, 6] + raw))
        XCTAssertEqual(equalizer.settings, curve)
        XCTAssertEqual(equalizer.confirmationValue([0x57, 1, 0xA1, 6] + raw), [0xA1, 6] + raw)
        // A different slot's readback does not confirm the write.
        XCTAssertNotEqual(equalizer.confirmationValue([0x57, 1, 0xA2, 6] + raw), [0xA1, 6] + raw)
    }

    private func prepared(layout: [SonyEqualizerBand] = SonyEqualizerBand.legacy, steps: UInt8 = 21,
                          type: UInt8 = 0, presets: [UInt8] = [0, 0xA0]) -> SonyEqualizer {
        let function: UInt8 = type == 4 ? 0x57 : type == 2 ? 0x52 : 0x50
        var equalizer = SonyEqualizer(supportedFunctions: [function])
        XCTAssertTrue(equalizer.update([0x51, type, UInt8(layout.count), steps, UInt8(presets.count)] + presets.flatMap { [$0, 0] }))
        let metadata: [UInt8] = layout.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        XCTAssertTrue(equalizer.update([0x5B, type, UInt8(layout.count)] + metadata))
        XCTAssertTrue(equalizer.update(type == 4 ? [0x53, type, 0, 0] : [0x53, type, 0]))
        XCTAssertTrue(equalizer.update([0x57, type, 0xA0, UInt8(layout.count)]
            + Array(repeating: steps > 0 ? (steps - 1) / 2 : 0, count: layout.count)))
        return equalizer
    }
}
