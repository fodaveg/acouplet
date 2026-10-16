import Foundation
import Combine
import CoreBluetooth
import AppKit
import XCTest
@testable import Acouplet

final class SonyProtocolTests: XCTestCase {
    #if ACOUPLET_NO_SONY_ARTWORK
    private let expectsProductArtwork = false
    #else
    private let expectsProductArtwork = true
    #endif

    func testReconnectBackoffCapsAtThirtySeconds() {
        XCTAssertEqual((0...6).map(ReconnectBackoff.delay), [2, 4, 8, 15, 30, 30, 30])
    }

    @MainActor
    func testCommandQueuePublishesOnlyBusyAvailabilityChanges() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.defersSimulatedWrites = true
        defer { controller.simulateControlLoss() }
        var availabilityBeforeChanges: [Bool] = []
        let observation = controller.objectWillChange.sink {
            availabilityBeforeChanges.append(controller.canPowerOff)
        }
        defer { observation.cancel() }
        XCTAssertTrue(controller.canPowerOff)

        controller.refreshEqualizer()
        XCTAssertEqual(availabilityBeforeChanges, [true])
        XCTAssertFalse(controller.canPowerOff)
        XCTAssertTrue(controller.refreshMusicVolume())
        XCTAssertEqual(availabilityBeforeChanges, [true])

        for _ in 0..<2 {
            controller.completeSimulatedWrite()
            availabilityBeforeChanges.removeAll()
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            XCTAssertTrue(availabilityBeforeChanges.isEmpty)
            XCTAssertFalse(controller.canPowerOff)
        }
        controller.completeSimulatedWrite()
        availabilityBeforeChanges.removeAll()
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        XCTAssertEqual(availabilityBeforeChanges, [false])
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.canPowerOff)
    }

    func testFrameRoundTripIncludingEscapedBytes() {
        let payload: [UInt8] = [0x68, 0x3C, 0x3D, 0x3E, 0x01]
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: payload)
        XCTAssertEqual(SonyFrameCodec.decode(encoded), SonyFrame(type: 0x0C, sequence: 1, payload: payload))
    }

    func testStreamKeepsFrameStartTransmissionOwnershipAcrossFragments() {
        let old = UUID()
        let new = UUID()
        let encoded = SonyFrameCodec.encode(type: 0x01, sequence: 1, payload: [])
        for split in 1..<encoded.count {
            var stream = SonyFrameStream()
            XCTAssertTrue(stream.append(encoded.prefix(split), transmissionID: old).isEmpty)
            let received = stream.append(encoded.dropFirst(split) + encoded, transmissionID: new)
            XCTAssertEqual(received.count, 2)
            XCTAssertEqual(received.first?.transmissionID, old)
            XCTAssertEqual(received.last?.transmissionID, new)
        }
        var stream = SonyFrameStream()
        XCTAssertTrue(stream.append(encoded.prefix(4), transmissionID: nil).isEmpty)
        XCTAssertNil(stream.append(encoded.dropFirst(4), transmissionID: new).first?.transmissionID)
        XCTAssertTrue(stream.append(encoded.prefix(4), transmissionID: old).isEmpty)
        XCTAssertEqual(stream.append(encoded, transmissionID: new).first?.transmissionID, new)
        XCTAssertTrue(stream.append(Data([SonyFrameCodec.header]), transmissionID: old).isEmpty)
        XCTAssertTrue(stream.append(Data(repeating: 0, count: SonyFrameStream.maximumFrameLength), transmissionID: old).isEmpty)
        XCTAssertEqual(stream.append(encoded, transmissionID: new).first?.transmissionID, new)
        XCTAssertTrue(stream.append(encoded.prefix(4), transmissionID: old).isEmpty)
        stream = SonyFrameStream()
        XCTAssertTrue(stream.append(encoded.dropFirst(4), transmissionID: new).isEmpty)
        XCTAssertEqual(stream.append(encoded, transmissionID: new).first?.transmissionID, new)
    }

    @MainActor
    func testFragmentedACKForCurrentTransmittedCommandAdvancesQueue() throws {
        for split in 1..<9 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.refreshMusicVolume())
            let first = try XCTUnwrap(controller.simulatedPendingFrame)
            let packet = SonyFrameCodec.encode(type: 1, sequence: 1 - first.sequence, payload: [])
            controller.simulateProtocolData(packet.prefix(split))
            XCTAssertEqual(controller.simulatedPendingFrame, first)
            controller.simulateProtocolData(packet.dropFirst(split))
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
        }
    }

    @MainActor
    func testFragmentedNotificationSurvivesOutboundCommandAdmission() {
        let packet = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 60, 0])
        for split in 1..<packet.count {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolData(packet.prefix(split))
            controller.refreshEqualizer()
            controller.simulateProtocolData(packet.dropFirst(split))
            XCTAssertEqual(controller.batteries.single?.level, 60)
        }
    }

    @MainActor
    func testFragmentedPlaybackResponseSurvivesNextQueryAdmission() throws {
        let packet = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA3, 1, 0, 2, 1])
        for split in 1..<packet.count {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            XCTAssertTrue(controller.refreshMusicVolume())
            controller.completeSimulatedWrite()
            let status = try XCTUnwrap(controller.simulatedPendingFrame)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - status.sequence, payload: []))
            let volume = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(volume.payload, [0xA6, 0x20])
            controller.simulateProtocolData(packet.prefix(split))
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(packet.dropFirst(split))
            XCTAssertEqual(controller.playback.musicCallStatus, 1)
            XCTAssertEqual(controller.simulatedPendingFrame, volume)
        }
    }

    func testStreamReassemblesSplitFrames() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x00, 0x00])
        var stream = SonyFrameStream()
        XCTAssertTrue(stream.append(encoded.prefix(3)).isEmpty)
        XCTAssertEqual(stream.append(encoded.dropFirst(3)).first?.payload, [0x00, 0x00])
    }

    func testRejectsInvalidFrameSequence() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 255, payload: [0x23, 0x00, 50, 0])
        XCTAssertNil(SonyFrameCodec.decode(encoded))
    }

    func testStreamRecoversFromNoiseAndUnterminatedFrames() {
        let expected = SonyFrame(type: 0x0C, sequence: 0, payload: [0x3C, 0x3D, 0x3E])
        let encoded = SonyFrameCodec.encode(type: expected.type, sequence: expected.sequence, payload: expected.payload)
        var stream = SonyFrameStream()
        XCTAssertTrue(stream.append(Data(repeating: 0, count: 100_000)).isEmpty)
        XCTAssertTrue(stream.append(Data([SonyFrameCodec.header, 0, 0])).isEmpty)
        XCTAssertEqual(stream.append(encoded + encoded), [expected, expected])
        XCTAssertTrue(stream.append(Data([SonyFrameCodec.header])).isEmpty)
        for _ in 0..<20 {
            XCTAssertTrue(stream.append(Data(repeating: 0, count: 65_536)).isEmpty)
        }
        XCTAssertEqual(stream.append(encoded), [expected])
    }

    func testStreamRejectsOversizedFramesButAcceptsFollowingFrame() {
        let oversized = SonyFrameCodec.encode(type: 0x0C, sequence: 0,
                                             payload: [UInt8](repeating: 0, count: SonyFrameStream.maximumFrameLength))
        let valid = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x06, 0])
        var stream = SonyFrameStream()
        XCTAssertEqual(stream.append(oversized + valid).map(\.payload), [[0x06, 0]])
    }

    func testRejectsBadChecksum() {
        var encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x06, 0x00])
        encoded[encoded.count - 2] ^= 0x01
        XCTAssertNil(SonyFrameCodec.decode(encoded))
    }

    func testEqualizerPresetProtocolValues() {
        XCTAssertEqual(EqualizerPreset.off.rawValue, 0x00)
        XCTAssertEqual(EqualizerPreset.bassBoost.rawValue, 0x16)
        XCTAssertEqual(EqualizerPreset.manual.rawValue, 0xA0)
    }

    func testCustomEqualizerResponseAndClamping() {
        let settings = EqualizerSettings(clearBass: 12, bands: [-12, -4, 0, 6, 14])
        XCTAssertEqual(settings, EqualizerSettings(clearBass: 10, bands: [-10, -4, 0, 6, 10]))
        let response: [UInt8] = [0x57, 0x00, 0xA0, 0x06, 20, 0, 6, 10, 16, 20]
        XCTAssertEqual(EqualizerSettings(sonyPayload: response), settings)
    }
    func testDeviceIdentitySelectsEarbudArtwork() {
        let earbuds = SonyDeviceModel(name: "Listener’s WF-1000XM5")
        XCTAssertEqual(earbuds, .wfXM5)
        XCTAssertEqual(earbuds.artwork, expectsProductArtwork ? "WFXM5Hero" : nil)
        XCTAssertEqual(SonyDeviceModel(name: "wh-1000xm5").artwork, expectsProductArtwork ? "XM5Hero" : nil)
        XCTAssertNil(SonyDeviceModel(name: "Other headphones").artwork)
    }

    func testFinishArtworkMatchesOnlySourceDerivedModelAndColorPairs() {
        let nonblack: [SonyDeviceModel: [UInt8: String]] = [
            .wfXM5: [0x03: "Silver"], .wfXM4: [0x03: "Silver"],
            .whXM5: [0x03: "Silver"], .whXM4: [0x03: "Silver"], .whXM3: [0x03: "Silver"],
            .whCH720N: [0x02: "White", 0x05: "Blue", 0x06: "Pink"]
        ]
        let artworkModels: Set<SonyDeviceModel> = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                                   .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        var recognized = 0
        for model in SonyDeviceModel.allCases {
            XCTAssertNil(model.artworkSuffix(for: nil))
            for raw in UInt8.min...UInt8.max {
                let expected = artworkModels.contains(model) && raw == 0x01 ? "" : nonblack[model]?[raw]
                let suffix = model.artworkSuffix(for: SonyDeviceColor(rawValue: raw))
                XCTAssertEqual(suffix, expected, "\(model.name) color \(raw)")
                if suffix != nil { recognized += 1 }
            }
        }
        XCTAssertEqual(recognized, 19)
    }

    @MainActor
    func testMenuBarEarbudsKeepTheirIntrinsicSize() {
        let models: [(SonyDeviceModel, CGFloat)] = [(.wfXM5, 22), (.wfXM6, 25), (.wfXM4, 24), (.wfXM3, 27)]
        for (model, width) in models {
            let image = DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true)
            XCTAssertEqual(image.size, NSSize(width: width, height: 18), model.name)
            XCTAssertTrue(image.isTemplate)
        }
    }

    @MainActor
    func testChargingCaseIconsAndOfficialArtworkAreAvailable() throws {
        for model in [SonyDeviceModel.wfXM5, .wfXM6] {
            let image = DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true, chargingCase: true)
            let symbol = try XCTUnwrap(NSImage(named: try XCTUnwrap(model.caseSymbol)))
            XCTAssertEqual(image.size, symbol.size)
            XCTAssertEqual(image.tiffRepresentation, symbol.tiffRepresentation)
            XCTAssertTrue(image.isTemplate)
        }
        for asset in ["wfXM5OpenCaseProduct", "wfXM5OpenCaseProductSilver", "wfXM5OpenCaseProductSmokyPink", "wfXM6OpenCaseProduct", "wfXM6OpenCaseProductSilver"] {
            XCTAssertEqual(NSImage(named: asset) != nil, expectsProductArtwork, asset)
        }
    }

    @MainActor
    func testMenuBarBatteryWarningsKeepEachSideSeparate() throws {
        XCTAssertNil(DeviceIcon.batteryColor(for: nil))
        for level: UInt8 in [0, 9, 10, 19, 20, 21, 100] {
            let expected: NSColor? = level <= 20 ? .systemRed : nil
            XCTAssertEqual(DeviceIcon.batteryColor(for: BatteryReading(level: level, charging: 0)), expected)
        }
        let batteries = SonyBatteries(left: BatteryReading(level: 20, charging: 0), right: BatteryReading(level: 21, charging: 0))
        let image = DeviceIcon.menuBarImage(model: .wfXM5, leftConnected: true, rightConnected: true, batteries: batteries)
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 22, height: 18))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width),
                pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            var redLeft = 0, redRight = 0, yellowLeft = 0, yellowRight = 0
            var healthyRight = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    guard color.alphaComponent > 0.8 else { continue }
                    if color.redComponent > 0.7 && color.greenComponent < 0.5 {
                        if x < bitmap.pixelsWide / 2 { redLeft += 1 } else { redRight += 1 }
                    }
                    if color.redComponent > 0.7 && color.greenComponent > 0.6 && color.blueComponent < 0.5 {
                        if x < bitmap.pixelsWide / 2 { yellowLeft += 1 } else { yellowRight += 1 }
                    }
                    let healthyColor = appearance == .darkAqua
                        ? color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent > 0.7
                        : color.redComponent < 0.3 && color.greenComponent < 0.3 && color.blueComponent < 0.3
                    if x >= bitmap.pixelsWide / 2, healthyColor {
                        healthyRight += 1
                    }
                }
            }
            XCTAssertGreaterThan(redLeft, 0)
            XCTAssertEqual(yellowRight, 0)
            XCTAssertEqual(redRight, 0)
            XCTAssertEqual(yellowLeft, 0)
            XCTAssertGreaterThan(healthyRight, 0, appearance.rawValue)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "WF warning colors — \(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(DeviceIcon.menuBarImage(model: .wfXM5, leftConnected: false, rightConnected: false, batteries: batteries).isTemplate)
        XCTAssertFalse(DeviceIcon.menuBarImage(model: .whXM5, leftConnected: nil, rightConnected: nil,
            batteries: SonyBatteries(single: BatteryReading(level: 9, charging: 0))).isTemplate)
        for mode in NoiseControlMode.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil), mode.symbol)
        }
    }

    @MainActor
    func testGenericEarbudIconsPreservePerEarWarningsAndConnectionOpacity() throws {
        for model in [SonyDeviceModel.wfL900, .wfG700N] {
            let batteries = SonyBatteries(left: BatteryReading(level: 20, charging: 0), right: BatteryReading(level: 80, charging: 0))
            let image = DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true, batteries: batteries)
            XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            var red = [0, 0]
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0.8, color.redComponent > 0.7, color.greenComponent < 0.5 {
                        red[x < bitmap.pixelsWide / 2 ? 0 : 1] += 1
                    }
                }
            }
            XCTAssertGreaterThan(red[0], 0, model.name)
            XCTAssertEqual(red[1], 0, model.name)
            let disconnected = DeviceIcon.menuBarImage(model: model, leftConnected: false, rightConnected: true, batteries: batteries)
            XCTAssertTrue(disconnected.isTemplate)
            let dimmed = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(disconnected.tiffRepresentation)))
            var opacity: [CGFloat] = [0, 0]
            for x in 0..<dimmed.pixelsWide {
                for y in 0..<dimmed.pixelsHigh {
                    let side = x < dimmed.pixelsWide / 2 ? 0 : 1
                    opacity[side] = max(opacity[side], try XCTUnwrap(dimmed.colorAt(x: x, y: y)).alphaComponent)
                }
            }
            XCTAssertGreaterThan(opacity[0], 0)
            XCTAssertLessThanOrEqual(opacity[0], 0.36)
            XCTAssertGreaterThan(opacity[1], 0.8)
            XCTAssertTrue(DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true, chargingCase: true).isTemplate)
        }
        for model in [SonyDeviceModel.wiC100, .srsULT10] {
            XCTAssertFalse(DeviceIcon.menuBarImage(model: model, leftConnected: nil, rightConnected: nil,
                batteries: SonyBatteries(single: BatteryReading(level: 20, charging: 0))).isTemplate)
        }
    }

    func testDistinctSonyFamilyIdentitiesAndSymbols() {
        let models: [SonyDeviceModel] = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                        .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        XCTAssertEqual(Set(models.compactMap(\.symbol)).count, models.count)
        for model in models {
            XCTAssertEqual(SonyDeviceModel(name: model.name), model)
            XCTAssertEqual(SonyDeviceModel(name: "LE_" + model.name), model)
            XCTAssertEqual(model.caseSymbol != nil, model.isEarbuds)
            XCTAssertEqual(model.leftSymbol != nil, model.isEarbuds)
            XCTAssertEqual(model.rightSymbol != nil, model.isEarbuds)
            XCTAssertEqual(model.systemSymbol, model.isEarbuds ? "earbuds.stemless" : "headphones")
        }
        XCTAssertEqual(SonyDeviceModel(name: "WH-ULT900N"), .whULT900N)
        XCTAssertEqual(SonyDeviceModel(name: "WH-1000XX"), .wh1000XX)
        XCTAssertEqual(SonyDeviceModel(name: "WH-1000XM4C"), .whXM4C)
        XCTAssertEqual(SonyDeviceModel(name: "WF-1000XM50"), .unknown)
        XCTAssertEqual(SonyDeviceModel(name: "WF-1000XM5 WH-1000XM5"), .unknown)
        XCTAssertEqual(SonyDeviceModel(name: "NotWF-1000XM5"), .unknown)
    }

    func testRequestedSonyModelsHaveDistinctIdentitiesAndFormFactors() {
        let groups: [(SonyDeviceModel.FormFactor, [SonyDeviceModel])] = [
            (.earbuds, [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .wf1000X,
                        .wfL900, .wfLC900, .wfLS910N, .wfL910, .wfLS900N, .wfL900UC,
                        .wfC500, .wfC510, .wfC700N, .wfC710N, .wfH800, .wfSP700N, .wfSP800N, .wfSP900, .wfG700N]),
            (.onEarHeadphones, [.whCH520, .whCH530, .whCH535, .whH800, .whH810, .whXB700]),
            (.overEarHeadphones, [.whXM6, .whXM5, .whXM4, .whXM4C, .whXM3, .whXM2, .wh1000XX,
                                 .whCH700N, .whCH720N, .whCH730N, .whCH735N, .whH900N, .whH910N,
                                 .whXB900N, .whXB910N, .whULT900N, .mdrXB950B1, .mdrXB950N1, .whG910N]),
            (.neckbandEarbuds, [.wi1000X, .wi1000XM2, .wiC100, .wiC600N, .wiH700, .wiSP600N]),
            (.neckbandSpeaker, [.htAN7, .srsNS7, .srsNS7R]),
            (.portableSpeaker, [.srsLS1, .srsULT10, .srsULT30, .srsULT50, .srsULT70]),
            (.towerSpeaker, [.srsULT500, .srsULT700, .srsULT900, .srsULT900AC, .srsULT1000, .srsULT3000])
        ]
        let models = groups.flatMap { $0.1 }
        XCTAssertEqual(models.count, 65)
        XCTAssertEqual(Set(models).count, 65)
        XCTAssertEqual(Set(SonyDeviceModel.allCases), Set(models + [.unknown]))
        for (formFactor, models) in groups {
            for model in models {
                XCTAssertEqual(model.formFactor, formFactor, model.name)
                XCTAssertEqual(model.isEarbuds, formFactor == .earbuds, model.name)
                XCTAssertEqual(model.isSpeaker, [.neckbandSpeaker, .portableSpeaker, .towerSpeaker].contains(formFactor), model.name)
                XCTAssertEqual(SonyDeviceModel(name: model.name.lowercased()), model)
                XCTAssertEqual(SonyDeviceModel(name: "LE_" + model.name), model)
                XCTAssertEqual(SonyDeviceModel(name: "Listener’s " + model.name), model)
                XCTAssertEqual(SonyDeviceModel(name: "Not" + model.name), .unknown)
                XCTAssertEqual(SonyDeviceModel(name: model.name + "Z"), .unknown)
            }
        }
        let artworkModels: Set<SonyDeviceModel> = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                                   .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        for model in SonyDeviceModel.allCases where !artworkModels.contains(model) {
            XCTAssertNil(model.artwork, model.name)
            #if DEBUG
            XCTAssertTrue(model.galleryArtworkFinishes.isEmpty, model.name)
            #endif
        }
        XCTAssertEqual(SonyDeviceModel.wi1000X.systemSymbol, "earbuds.stemless")
        XCTAssertEqual(SonyDeviceModel.srsULT900.systemSymbol, "hifispeaker")
        XCTAssertEqual(SonyDeviceModel.htAN7.systemSymbol, "hifispeaker")
        XCTAssertEqual(SonyDeviceModel.unknown.systemSymbol, "speaker.wave.2")
    }

    func testAllRecognizedModelsHaveBundledCustomMiniIcons() throws {
        let models = SonyDeviceModel.allCases.filter { $0 != .unknown }
        XCTAssertEqual(models.count, 65)
        XCTAssertEqual(Set(models.compactMap(\.symbol)).count, models.count)
        for model in models {
            let symbol = try XCTUnwrap(model.symbol, model.name)
            XCTAssertNotNil(NSImage(named: symbol), symbol)
            if model.isEarbuds {
                let left = try XCTUnwrap(model.leftSymbol, model.name)
                let right = try XCTUnwrap(model.rightSymbol, model.name)
                let chargingCase = try XCTUnwrap(model.caseSymbol, model.name)
                let filledCase = try XCTUnwrap(model.filledCaseSymbol, model.name)
                XCTAssertNotEqual(left, right, model.name)
                XCTAssertTrue(left.hasSuffix("EarbudLeft"), left)
                XCTAssertTrue(right.hasSuffix("EarbudRight"), right)
                for name in [left, right, chargingCase, filledCase] {
                    XCTAssertNotNil(NSImage(named: name), name)
                }
            } else {
                XCTAssertNil(model.leftSymbol, model.name)
                XCTAssertNil(model.rightSymbol, model.name)
                XCTAssertNil(model.caseSymbol, model.name)
            }
        }
        XCTAssertNil(SonyDeviceModel.unknown.symbol)
    }

    func testSonyCommercialNamesDoNotCollideAcrossFamilies() {
        let aliases: [String: SonyDeviceModel] = [
            "LinkBuds": .wfL900, "LinkBuds Clip": .wfLC900, "LinkBuds Fit": .wfLS910N,
            "LinkBuds Open": .wfL910, "LinkBuds S": .wfLS900N, "LinkBuds UC": .wfL900UC,
            "LinkBuds Speaker": .srsLS1, "INZONE Buds": .wfG700N, "INZONE H9 II": .whG910N,
            "BRAVIA Theatre U": .htAN7, "ULT FIELD 1": .srsULT10, "ULT FIELD 3": .srsULT30,
            "ULT FIELD 5": .srsULT50, "ULT FIELD 7": .srsULT70, "ULT TOWER 5": .srsULT500,
            "ULT TOWER 7": .srsULT700, "ULT TOWER 9": .srsULT900, "ULT TOWER 9AC": .srsULT900AC,
            "ULT TOWER 10": .srsULT1000, "ULT TOWER MAX": .srsULT3000,
            "ULT WEAR": .whULT900N, "1000X THE COLLEXION": .wh1000XX
        ]
        for (name, model) in aliases {
            XCTAssertEqual(SonyDeviceModel(name: name), model)
            XCTAssertEqual(SonyDeviceModel(name: "LE_" + name), model)
            XCTAssertEqual(SonyDeviceModel(name: "Listener’s " + name), model)
        }
        for name in ["LinkBuds S2", "LinkBuds Unknown", "ULT TOWER 90", "INZONE H9",
                     "WH-1000XM4CC", "SRS-ULT900AC2", "SRS-NS7R2", "WH-CH5350",
                     "WH-CH530 series", "LE_WH-CH530 series", "WH-CH730N series", "LE_WH-CH730N series",
                     "WH-1000XM4 WH-1000XM4C", "LinkBuds S WF-L900",
                     "WF-LS900N LinkBuds Fit", "WF-1000XM5 SRS-ULT10"] {
            XCTAssertEqual(SonyDeviceModel(name: name), .unknown, name)
        }
        XCTAssertEqual(SonyDeviceModel(name: "LinkBuds S (WF-LS900N)"), .wfLS900N)
        XCTAssertEqual(SonyDeviceModel(name: "ULT TOWER 9AC (SRS-ULT900AC)"), .srsULT900AC)
    }

    func testSonyModelNameBoundariesHandleUnicodeAndRepeatedAliases() {
        let names: [String: SonyDeviceModel] = [
            "🎧 WF-1000XM5": .wfXM5, "ß WF-1000XM5": .wfXM5,
            "NotWF-1000XM5 / WF-1000XM5": .wfXM5,
            "WF-1000XM5 / WF-1000XM5": .wfXM5, "WF-1000XM5_custom": .wfXM5,
            "WH-CH530\tSERIES": .unknown, "WH-CH530 SERIES2": .whCH530,
            "LinkBuds\tS": .unknown
        ]
        for (name, model) in names {
            XCTAssertEqual(SonyDeviceModel(name: name), model, name)
        }
    }

    func testProtocolGenerationComesFromTheNegotiatedResponse() {
        let legacy = SonyProtocolInfo(payload: [0x01, 0, 0x02, 0x10])
        XCTAssertEqual(legacy?.generation, .v1)
        XCTAssertEqual(legacy?.version, 0x0210)
        XCTAssertEqual(legacy?.supportsTable1, true)
        XCTAssertEqual(legacy?.supportsTable2, false)
        let current = SonyProtocolInfo(payload: [0x01, 0, 0x03, 0, 0x30, 0x18, 0, 1])
        XCTAssertEqual(current?.generation, .v2)
        XCTAssertEqual(current?.version, 0x03003018)
        XCTAssertEqual(current?.supportsTable2, false)
        for malformed: [UInt8] in [[], [0x01, 0, 3], [0x01, 0, 3, 0, 1], [0x01, 0, 3, 0, 0, 0, 2, 0]] {
            XCTAssertNil(SonyProtocolInfo(payload: malformed))
        }
    }

    func testReportedModelAndColorPreserveUnknownAndDefaultValues() {
        var info = SonyDeviceInformation()
        XCTAssertNil(info.model)
        XCTAssertNil(info.color)
        let name = Array("WF-1000XM6".utf8)
        XCTAssertTrue(info.update([0x05, 0x01, UInt8(name.count)] + name))
        XCTAssertEqual(info.model, .wfXM6)
        XCTAssertTrue(info.update([0x05, 0x03, 0x30, 0x00]))
        XCTAssertEqual(info.series, 0x30)
        XCTAssertEqual(info.color?.rawValue, 0)
        XCTAssertEqual(info.color?.title, String(localized: "Default"))
        XCTAssertTrue(info.update([0x05, 0x03, 0x11, 0x11]))
        XCTAssertEqual(info.color?.title, String(localized: "Black") + "-I")
        XCTAssertTrue(info.update([0x05, 0x03, 0xFF, 0xFF]))
        XCTAssertEqual(info.series, 0xFF)
        XCTAssertEqual(info.color?.rawValue, 0xFF)
        XCTAssertEqual(info.color?.title, String(format: String(localized: "Unknown (0x%02X)"), 0xFF))
        let previous = info
        for malformed: [UInt8] in [[0x05, 0x03, 1], [0x05, 0x03, 1, 2, 3],
                                    [0x05, 0x01, 2, 0xFF, 0xFE], [0x05, 0x01, 1, 0],
                                    [0x05, 0x01, 2, 65], [0x05, 0x01, 0]] {
            XCTAssertFalse(info.update(malformed))
            XCTAssertEqual(info, previous)
        }
        let unrecognized = Array("Future Sony headphones".utf8)
        XCTAssertTrue(info.update([0x05, 0x01, UInt8(unrecognized.count)] + unrecognized))
        XCTAssertEqual(info.model, .unknown)
    }

    func testBatteryQueriesFollowAdvertisedTopologyAndThresholdVariant() {
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: []), [])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x20]), [0x00])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x21, 0x22]), [0x01, 0x02])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x28, 0x29, 0x2A]), [0x08, 0x09, 0x0A])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x20, 0x28, 0x21, 0x29, 0x22, 0x2A]), [0x00, 0x01, 0x02])
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x23, 0x01, 70, 0, 80, 1]))
        XCTAssertEqual(batteries.left?.level, 70)
        XCTAssertEqual(batteries.right?.level, 80)
        XCTAssertTrue(batteries.update([0x25, 0x02, 90, 0]))
        XCTAssertEqual(batteries.caseBattery?.level, 90)
        XCTAssertTrue(batteries.update([0x23, 0x09, 71, 0, 81, 1, 20, 20]))
        XCTAssertTrue(batteries.update([0x23, 0x0A, 91, 0, 20]))
        XCTAssertEqual(batteries.left?.level, 71)
        XCTAssertEqual(batteries.caseBattery?.level, 91)
        XCTAssertTrue(batteries.update([0x23, 0x08, 65, 0, 20]))
        XCTAssertEqual(batteries.single?.level, 65)
        XCTAssertNil(batteries.left)
        XCTAssertNil(batteries.right)
        XCTAssertFalse(batteries.update([0x23, 0x01, 10, 0, 20]))
    }

    func testEarbudBatteryRepliesNotificationsAndUnavailableEarbud() {
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x23, 0x09, 78, 0, 82, 1]))
        XCTAssertEqual(batteries.left?.level, 78)
        XCTAssertEqual(batteries.right?.level, 82)
        XCTAssertEqual(batteries.right?.isCharging, true)
        XCTAssertEqual(batteries.level, 78)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 64, 0]))
        XCTAssertEqual(batteries.caseBattery?.level, 64)
        XCTAssertEqual(batteries.level, 78)
        XCTAssertTrue(batteries.update([0x25, 0x09, 255, 0, 62, 0]))
        XCTAssertNil(batteries.left)
        XCTAssertEqual(batteries.level, 62)
        XCTAssertTrue(batteries.update([0x25, 0x09, 0, 0, 32, 0]))
        XCTAssertNil(batteries.left)
        XCTAssertEqual(batteries.level, 32)
        XCTAssertFalse(batteries.isCharging)
    }

    func testCaseZeroClearsItsPercentageWithoutSubstitutingTheThreshold() {
        for command: UInt8 in [0x23, 0x25] {
            for type: UInt8 in [0x02, 0x0A] {
                for state: UInt8 in [0, 1, 2, 3] {
                    for threshold: UInt8 in [0, 30, 100] {
                        var batteries = SonyBatteries()
                        let suffix: [UInt8] = type == 0x0A ? [threshold] : []
                        XCTAssertTrue(batteries.update([command, type, 50, state] + suffix))
                        XCTAssertEqual(batteries.caseBattery?.level, 50)
                        XCTAssertTrue(batteries.update([command, type, 0, state] + suffix))
                        XCTAssertNil(batteries.caseBattery)
                        XCTAssertEqual(BatteryReading(level: 0, charging: state)?.level, 0)
                        XCTAssertTrue(batteries.update([command, type, 1, state] + suffix))
                        XCTAssertEqual(batteries.caseBattery?.level, 1)
                        XCTAssertEqual(batteries.caseBattery?.chargingState.rawValue, state)
                    }
                }
            }
            for type: UInt8 in [0x00, 0x08] {
                var batteries = SonyBatteries()
                XCTAssertTrue(batteries.update([command, type, 0, 0] + (type == 0x08 ? [30] : [])))
                XCTAssertEqual(batteries.single?.level, 0)
            }
        }
    }

    func testBatteryParserRejectsTruncatedAndUnrelatedPackets() {
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x23, 0x00, 45, 1]))
        let previous = batteries
        for packet: [UInt8] in [[], [0x23], [0x23, 0x09, 45, 0], [0x57, 0x00, 12, 0], [0x23, 0xFF, 12, 0]] {
            XCTAssertFalse(batteries.update(packet))
            XCTAssertEqual(batteries, previous)
        }
        XCTAssertTrue(batteries.update([0x25, 0x00, 255, 0]))
        XCTAssertNil(batteries.level)
        XCTAssertNil(BatteryReading(level: 50, charging: 7))
    }

    func testBatteryChargingStatesPreserveUnknownAndChargedLevelsAcrossV2Topologies() {
        for command: UInt8 in [0x23, 0x25] {
            for type: UInt8 in [0x00, 0x08, 0x02, 0x0A] {
                for state: UInt8 in [2, 3] {
                    var batteries = SonyBatteries()
                    let payload = [command, type, 73, state] + (type >= 8 ? [20] : [])
                    XCTAssertTrue(batteries.update(payload))
                    let reading = type == 0 || type == 8 ? batteries.single : batteries.caseBattery
                    XCTAssertEqual(reading?.level, 73)
                    XCTAssertEqual(reading?.chargingState, state == 2 ? .unknown : .charged)
                    XCTAssertEqual(reading?.isCharging, false)
                }
            }
            for type: UInt8 in [0x01, 0x09] {
                var batteries = SonyBatteries()
                let payload = [command, type, 73, 2, 84, 3] + (type == 9 ? [20, 20] : [])
                XCTAssertTrue(batteries.update(payload))
                XCTAssertEqual(batteries.left?.level, 73)
                XCTAssertEqual(batteries.left?.chargingState, .unknown)
                XCTAssertEqual(batteries.right?.level, 84)
                XCTAssertEqual(batteries.right?.chargingState, .charged)
                XCTAssertFalse(batteries.isCharging)
            }
        }
    }

    func testBatteryChargingStateWireValuesRemainSpecificToProtocolGeneration() {
        XCTAssertEqual(BatteryReading(level: 0, charging: 0xF0, generation: .v1)?.chargingState, .unknown)
        XCTAssertNil(BatteryReading(level: 50, charging: 0xF0))
        XCTAssertNil(BatteryReading(level: 50, charging: 2, generation: .v1))
        XCTAssertNil(BatteryReading(level: 50, charging: 3, generation: .v1))
        XCTAssertNil(BatteryReading(level: 101, charging: 3))
        XCTAssertNil(BatteryReading(level: 50, charging: 0xFF))
        XCTAssertEqual(BatteryReading(level: 50, charging: 1)?.isCharging, true)
        XCTAssertEqual(BatteryReading(level: 50, charging: 1, generation: .v1)?.isCharging, true)
    }

    @MainActor
    func testBluetoothInitializationDoesNotBlockLaunchOrRepeatDuringRefresh() async {
        for authorization: CBManagerAuthorization in [.notDetermined, .allowedAlways] {
            let started = expectation(description: "Bluetooth initialization started")
            let finished = expectation(description: "Bluetooth initialization finished")
            let permissionResponse = DispatchSemaphore(value: 0)
            var controller: SonyHeadphonesController? = SonyHeadphonesController(startAutomatically: false)
            controller?.start(authorization: { authorization }) {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                XCTAssertEqual(permissionResponse.wait(timeout: .now() + 5), .success)
                finished.fulfill()
            }
            await fulfillment(of: [started], timeout: 2)
            controller?.refresh()
            controller?.connect()
            controller?.start(initializeBluetooth: { XCTFail("Initialization must run only once") })
            XCTAssertEqual(controller?.linkState, .searching)
            XCTAssertEqual(controller?.statusText, authorization == .notDetermined ? String(localized: "Waiting for Bluetooth permission…") : String(localized: "Searching…"))
            XCTAssertEqual(controller?.address, "")
            XCTAssertNil(controller?.controlChannelID)
            weak var pendingController = controller
            controller = nil
            XCTAssertNil(pendingController)
            permissionResponse.signal()
            await fulfillment(of: [finished], timeout: 2)
        }
    }

    @MainActor
    func testDeniedBluetoothAuthorizationDoesNotContinueToDeviceDiscovery() async {
        for authorization: CBManagerAuthorization in [.denied, .restricted] {
            let stopped = expectation(description: "Bluetooth access denied")
            let controller = SonyHeadphonesController(startAutomatically: false)
            let observation = controller.$linkState.sink { state in
                if state == .failed(String(localized: "Bluetooth access is not allowed.")) { stopped.fulfill() }
            }
            controller.start(authorization: { authorization }, initializeBluetooth: {})
            await fulfillment(of: [stopped], timeout: 2)
            XCTAssertEqual(controller.statusText, String(localized: "Bluetooth access is not allowed."))
            XCTAssertEqual(controller.address, "")
            XCTAssertFalse(controller.isReady)
            observation.cancel()
        }
    }

    @MainActor
    func testOfflineSimulationCannotOpenBluetooth() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.start()
        controller.setReconnectAutomatically(true)
        controller.refresh()
        controller.connect()
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertEqual(controller.address, "")
        XCTAssertNil(controller.controlChannelID)
    }

    @MainActor
    func testClosedMenuReleasesItsHostingControllerWithoutDisconnectingHeadphones() async throws {
        let suite = "dev.baglayan.Acouplet.menu-lifecycle-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5")
        defer { headphones.simulateControlLoss() }
        let environment = AppEnvironment(settings: SettingsStore(defaults: defaults), headphones: headphones,
                                         audioRoute: MacAudioRouteObserver(startAutomatically: false))
        let menu = MenuBarController(environment: environment, showSettings: {})
        defer { menu.stop() }
        XCTAssertNil(menu.simulatedPopoverContent)
        let session = headphones.notificationSession
        for stopping in [false, true] {
            menu.simulatePendingPopoverPresentation()
            weak var content = menu.simulatedPopoverContent
            XCTAssertNotNil(content)
            if !stopping {
                menu.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
                menu.simulatePendingPopoverPresentation()
                menu.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
                XCTAssertTrue(menu.simulatedPopoverContent === content)
            }
            if stopping { menu.stop() }
            else { menu.simulatePopoverDismissal() }
            XCTAssertNil(menu.simulatedPopoverContent)
            for _ in 0..<20 where content != nil {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertNil(content)
            headphones.objectWillChange.send()
            await Task.yield()
            XCTAssertNil(menu.simulatedPopoverContent)
            XCTAssertEqual(headphones.notificationSession, session)
            XCTAssertTrue(headphones.isReady)
        }
    }

    @MainActor
    func testBluetoothStartupHonorsSavedAutomaticReconnectPreference() throws {
        let suite = "dev.baglayan.Acouplet.startup-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for reconnect in [false, true] {
            let saved = SettingsStore(defaults: defaults)
            saved.reconnectAutomatically = reconnect
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.simulateControlLoss()
            let environment = AppEnvironment(settings: SettingsStore(defaults: defaults), headphones: controller,
                                             audioRoute: MacAudioRouteObserver(startAutomatically: false))
            XCTAssertEqual(controller.simulatedReconnectAutomatically, reconnect)
            controller.simulateBluetoothInitialization()
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, reconnect ? [0, 0] : nil)
            XCTAssertEqual(controller.linkState, reconnect ? .handshaking : .disconnected)
            XCTAssertEqual(environment.settings.reconnectAutomatically, reconnect)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testModeChangeCancelsPendingAmbientSliderWrite() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        controller.setAmbientLevel(14)
        controller.setNoiseControl(.anc)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x69] + payload.dropFirst())
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 1)
    }

    #if DEBUG
    @MainActor
    func testLegacyBLEProtocolDoesNotEnterV2HandshakeOrRetry() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM4", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10],
                                       beginConnection: true, expectedBLEHash: "ABCDEF12")
        XCTAssertEqual(controller.protocolInformation?.generation, .v1)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.statusText, String(localized: "These headphones need a Bluetooth Classic connection for their controls."))
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        XCTAssertNil(controller.retrySecondsRemaining)
        let frames = controller.simulatedTransmittedFrames
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
        XCTAssertFalse(frames.contains { $0.payload == [0x06, 0] || $0.payload == [0x04, 1] })
        controller.simulateProtocolMessage([0x07, 0, 1, 0x6D, 1])
        XCTAssertTrue(controller.supportedFunctions.isEmpty)
    }

    @MainActor
    func testOwnedModelReadOverridesAdvertisedIdentityAndResetsWithSession() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        let name = Array("WH-CH720N".utf8)
        let modelReply: [UInt8] = [0x05, 0x01, UInt8(name.count)] + name
        controller.simulateProtocolMessage(modelReply)
        XCTAssertEqual(controller.deviceModel, .wfXM5)
        controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage(modelReply)
        controller.simulateProtocolMessage([0x05, 0x03, 0x30, 0x00])
        XCTAssertEqual(controller.deviceModel, .whCH720N)
        XCTAssertEqual(controller.deviceName, "WF-1000XM5")
        XCTAssertEqual(controller.deviceInformation.color?.title, String(localized: "Default"))
        XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
        controller.simulateControlLoss()
        XCTAssertNil(controller.deviceInformation.modelName)
        XCTAssertNil(controller.deviceInformation.color)
        XCTAssertNil(controller.protocolInformation)
        controller.simulateProtocolMessage(modelReply)
        XCTAssertNil(controller.deviceInformation.modelName)
    }

    @MainActor
    func testMenuBarVisibilityFollowsPhysicalSupportedDeviceConnection() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        XCTAssertFalse(controller.showsMenuBarIcon)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(controller.showsMenuBarIcon)
        XCTAssertEqual(controller.deviceModel, .wfXM5)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(controller.showsMenuBarIcon)
        controller.simulateDeviceConnection(named: nil)
        XCTAssertFalse(controller.showsMenuBarIcon)
        controller.simulateDeviceConnection(named: "WH-1000XM5")
        XCTAssertTrue(controller.showsMenuBarIcon)
        XCTAssertEqual(controller.deviceModel, .whXM5)
        controller.simulateDeviceConnection(named: "Other headphones")
        XCTAssertFalse(controller.showsMenuBarIcon)
    }

    @MainActor
    func testGalleryModelsKeepImplementedCapabilitiesAndUnknownFinishesSeparate() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let models: [SonyDeviceModel] = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                        .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        for model in models {
            controller.simulateGalleryDevice(model: model)
            let legacy = [.wfXM4, .wfXM3, .whXM4, .whXM3].contains(model)
            XCTAssertEqual(controller.deviceModel, model, model.name)
            XCTAssertTrue(controller.isReady, model.name)
            XCTAssertNil(controller.deviceInformation.color, model.name)
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork, model.name)
            XCTAssertNil(controller.firmwareVersion, model.name)
            XCTAssertEqual(controller.protocolInformation?.generation, legacy ? .v1 : .v2, model.name)
            XCTAssertEqual(controller.legacyControls != nil, legacy, model.name)
            XCTAssertEqual(controller.batteries.left != nil, model.isEarbuds, model.name)
            XCTAssertEqual(controller.batteries.right != nil, model.isEarbuds, model.name)
            XCTAssertEqual(controller.batteries.caseBattery != nil, model.isEarbuds, model.name)
            XCTAssertEqual(controller.batteries.single != nil, !model.isEarbuds, model.name)
            XCTAssertEqual(controller.earTipFit.isSupported, [.wfXM5, .wfXM6].contains(model), model.name)
            XCTAssertEqual(controller.headGesturePractice.isSupported,
                           [.wfXM5, .wfXM6, .whXM6, .wh1000XX].contains(model), model.name)
            XCTAssertEqual(controller.touchAssignments.keys != nil, [.wfXM5, .wfXM6].contains(model), model.name)
            XCTAssertEqual(controller.equalizer.isSupported, ![.whULT900N, .wh1000XX].contains(model), model.name)
            if legacy {
                XCTAssertEqual(controller.equalizer.generation, .v1, model.name)
                XCTAssertEqual(controller.equalizer.inquiryType, 1, model.name)
                XCTAssertEqual(controller.equalizer.capabilities?.bandCount, 6, model.name)
                XCTAssertEqual(controller.equalizer.flatSettings?.levelRange, -10...10, model.name)
                XCTAssertTrue(controller.equalizer.requiresManualSelection, model.name)
                XCTAssertFalse(controller.equalizer.canEdit, model.name)
            }
            if [.wfXM6, .whXM6].contains(model) {
                XCTAssertEqual(controller.equalizer.capabilities?.bandCount, 10, model.name)
            }
            XCTAssertEqual(controller.systemFeatures[.speakToChat] != nil,
                           !legacy && ![.whCH720N, .whULT900N].contains(model), model.name)
            XCTAssertEqual(controller.systemFeatures[.pauseOnRemoval] != nil, !legacy && model != .whCH720N, model.name)
            XCTAssertEqual(controller.systemFeatures.multipoint != nil, !legacy && model != .wfXM6, model.name)
            XCTAssertEqual(controller.audioFeatures.supportedConnectionModes?.contains(.lowLatency) == true,
                           [.wfXM5, .wfXM6, .whXM6, .wh1000XX].contains(model), model.name)
            let dsee: SonyDSEEType = [.wfXM3, .whXM3].contains(model) ? .hx
                : [.whCH720N, .whULT900N].contains(model) ? .dsee : model == .wh1000XX ? .ultimate : .extreme
            XCTAssertEqual(controller.dseeType, dsee, model.name)
            XCTAssertTrue(controller.canSetDSEE, model.name)
            XCTAssertEqual(controller.powerFeatures.batteryCare != nil, [.wfXM6, .wh1000XX].contains(model), model.name)
            XCTAssertEqual(controller.powerFeatures.autoPowerSave != nil, model == .wfXM6, model.name)
            if model == .whCH720N { XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.inquiryType, 0x04) }
            for mode in [NoiseControlMode.off, .anc, .ambient] {
                controller.simulateGalleryDevice(model: model, noiseMode: mode)
                XCTAssertEqual(controller.noiseControlMode, mode, model.name)
                if legacy { XCTAssertEqual(controller.legacyControls?.noiseState?.mode, mode, model.name) }
            }
            XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty, model.name)
        }
        for model in [SonyDeviceModel.wfXM5, .whXM5] {
            controller.simulateGalleryDevice(model: model, color: 1)
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
            controller.simulateGalleryDevice(model: model)
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
            XCTAssertNil(controller.deviceInformation.color)
        }
    }

    @MainActor
    func testFinishGalleryUsesBundledPartsWithoutChangingReportedColor() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let finishes: [(SonyDeviceModel, UInt8, String, [String])] = [
            (.wfXM5, 0x03, "Silver", ["WFXM5FrontSilver", "wfXM5CaseProductSilver"]),
            (.wfXM4, 0x03, "Silver", ["wfXM4ProductSilver", "wfXM4ProductLeftSilver", "wfXM4ProductRightSilver", "wfXM4CaseProductSilver"]),
            (.whXM5, 0x03, "Silver", ["XM5HeroSilver"]),
            (.whXM4, 0x03, "Silver", ["whXM4ProductSilver"]),
            (.whXM3, 0x03, "Silver", ["whXM3ProductSilver"]),
            (.whCH720N, 0x02, "White", ["whCH720NProductWhite"]),
            (.whCH720N, 0x05, "Blue", ["whCH720NProductBlue"]),
            (.whCH720N, 0x06, "Pink", ["whCH720NProductPink"])
        ]
        for (model, color, suffix, assets) in finishes {
            controller.simulateGalleryDevice(model: model, color: color)
            XCTAssertEqual(controller.deviceModel, model)
            XCTAssertEqual(controller.deviceInformation.color?.rawValue, color)
            XCTAssertEqual(controller.deviceInformation.color?.title, String(localized: String.LocalizationValue(suffix)))
            XCTAssertEqual(controller.productArtworkSuffix, suffix)
            for asset in assets { XCTAssertEqual(NSImage(named: asset) != nil, expectsProductArtwork, asset) }
            controller.simulateGalleryDevice(model: model)
            XCTAssertNil(controller.deviceInformation.color)
            XCTAssertEqual(controller.productArtworkSuffix, "")
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
        }
        for (model, color) in [(SonyDeviceModel.wfXM6, UInt8(0x03)), (.whXM5, 0x13), (.whCH720N, 0x00), (.wfXM5, 0xFE)] {
            controller.simulateGalleryDevice(model: model, color: color)
            XCTAssertEqual(controller.deviceInformation.color?.rawValue, color)
            XCTAssertEqual(controller.productArtworkSuffix, "")
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
        }
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
    }

    @MainActor
    func testNamedVisualFinishGalleryLeavesDeviceColorUnread() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        var count = 0
        for model in SonyDeviceModel.allCases {
            for (finish, suffix) in model.galleryArtworkFinishes {
                controller.simulateGalleryDevice(model: model, visualFinish: finish)
                XCTAssertEqual(controller.productArtworkSuffix, suffix)
                XCTAssertNil(controller.deviceInformation.color)
                let product = model == .wfXM5 ? "WFXM5Front" : model == .whXM5 ? "XM5Hero" : model.rawValue + "Product"
                XCTAssertEqual(NSImage(named: product + suffix) != nil, expectsProductArtwork, "\(model.name) \(finish)")
                if model.isEarbuds {
                    XCTAssertEqual(NSImage(named: model.rawValue + "CaseProduct" + suffix) != nil, expectsProductArtwork)
                    if model != .wfXM5 {
                        for side in ["Left", "Right"] {
                            XCTAssertEqual(NSImage(named: model.rawValue + "Product" + side + suffix) != nil, expectsProductArtwork)
                        }
                    }
                }
                controller.simulateGalleryDevice(model: model)
                XCTAssertEqual(controller.productArtworkSuffix, "")
                XCTAssertNil(controller.deviceInformation.color)
                count += 1
            }
        }
        XCTAssertEqual(count, 34)
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
    }
    #endif

    @MainActor
    func testSimulatedControlsAndOfflineState() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertEqual(controller.deviceModel, .wfXM5)
        XCTAssertEqual(controller.batteryLevel, 78)
        controller.setNoiseControl(.anc)
        let noisePayload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x69] + noisePayload.dropFirst())
        XCTAssertEqual(controller.noiseControlMode, .anc)
        controller.applyPreset(mode: .ambient, ambientLevel: 8, focusOnVoice: true)
        XCTAssertEqual(controller.ambientLevel, 8)
        XCTAssertTrue(controller.focusOnVoice)
        controller.setEqualizerPreset(.bright)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x59, 0x00, 0x10, 0x00])
        XCTAssertEqual(controller.equalizerPreset, .bright)
        controller.setCustomEqualizer(.flat)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst())
        XCTAssertEqual(controller.equalizerPreset, .manual)
        let offline = SonyHeadphonesController(startAutomatically: false)
        XCTAssertFalse(offline.isReady)
        XCTAssertNil(offline.batteryLevel)
        XCTAssertEqual(offline.deviceModel, .unknown)
    }

}

final class SonyEqualizerControllerTests: XCTestCase {
    @MainActor
    func testNotificationReceivedBeforeTransmissionCannotConfirmAfterItsDelayedAcknowledgment() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setEqualizerPreset(.bright)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0x10])
        deliver([0x59, 0, 0x10, 0], to: controller)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0x10])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.payload, [0x58, 0, 0x10, 0])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.type, 0x01)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0x10])
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        deliver([0x59, 0, 0x10, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizer])
        XCTAssertNil(controller.settingErrors[.equalizer])
        XCTAssertEqual(controller.equalizerPreset, .bright)
    }

    @MainActor
    func testResponseReceivedBeforeReadTransmissionCannotOwnTheReadAfterItsDelayedAcknowledgment() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.refreshEqualizer(trackConfirmation: true)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        deliver([0x57, 0, 0x10, 0], to: controller)
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.payload, [0x56, 0])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.type, 0x01)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNil(controller.equalizerReadbackID)
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0, 0x16, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertNil(controller.settingErrors[.equalizerReadback])
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
    }

    @MainActor
    func testManualPresetSelectionAcceptsTheStoredCurveInItsReply() {
        let controller = makeController()
        controller.setEqualizerPreset(.manual)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0xA0])
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.equalizerPreset, .manual)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertNil(controller.settingErrors[.equalizer])
    }

    @MainActor
    func testTenBandCurveUsesAdvertisedRangeAndRejectsLegacyProfile() async throws {
        let controller = makeController()
        deliver([0x51, 0, 10, 13, 2, 0x30, 0, 0xA0, 0], to: controller)
        let metadata: [UInt8] = SonyEqualizerBand.tenBand.flatMap {
            [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)]
        }
        deliver([0x5B, 0, 10] + metadata, to: controller)
        deliver([0x57, 0, 0xA0, 0], to: controller)
        controller.setCustomEqualizer(.flat)
        XCTAssertNotNil(controller.settingErrors[.equalizer])
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        var draft = try XCTUnwrap(controller.equalizer.flatSettings)
        draft[0] = -6
        draft[9] = 6
        controller.setCustomEqualizer(draft)
        try await Task.sleep(for: .milliseconds(180))
        let payload: [UInt8] = [0x58, 0, 0xA0, 10, 0, 6, 6, 6, 6, 6, 6, 6, 6, 12]
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.payload, payload)
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + payload.dropFirst(), to: controller)
        XCTAssertEqual(controller.customEqualizer, draft)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertNil(controller.settingErrors[.equalizer])
    }

    @MainActor
    func testManualEqualizerRequiresACompleteMatchingTransmittedReadback() async throws {
        let controller = makeController()
        deliver([0x57, 0, 0xA0, 0], to: controller)
        let settings = EqualizerSettings(clearBass: 10, bands: [-10, -4, 0, 6, 10])
        controller.refreshEqualizer()
        controller.setCustomEqualizer(settings)
        XCTAssertTrue(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.equalizerPreset, .manual)
        XCTAssertEqual(controller.customEqualizer, .flat)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x56, 0x00])
        let reply = [UInt8(0x59)] + settings.sonySetPayload.dropFirst()
        deliver(reply, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        acknowledgeSimulatedCommands(controller)
        let readback = controller.equalizerReadbackID
        for payload: [UInt8] in [
            [0x57, 0x00, 0xA0],
            Array(reply.dropLast()),
            reply + [0],
            [0x59, 0x00, 0xA0, 5, 20, 0, 6, 10, 16],
            [0x59, 0x00, 0xA0, 6, 255, 0, 6, 10, 16, 20],
            [0x59, 0x01, 0xA0, 6, 20, 0, 6, 10, 16, 20],
        ] {
            deliver(payload, to: controller)
            XCTAssertNotNil(controller.pendingChanges[.equalizer])
            XCTAssertEqual(controller.customEqualizer, settings)
            XCTAssertEqual(controller.equalizerReadbackID, readback)
        }
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        deliver(reply, to: controller)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.customEqualizer, settings)
        XCTAssertNil(controller.settingErrors[.equalizer])
    }

    @MainActor
    func testRapidEditsKeepOnePendingWriteAndOnlyTheLatestDraft() async throws {
        let controller = makeController()
        deliver([0x57, 0, 0xA0, 0], to: controller)
        let first = EqualizerSettings(clearBass: 1, bands: [1, 0, 0, 0, 0])
        let skipped = EqualizerSettings(clearBass: 3, bands: [2, 0, 0, 0, 0])
        let latest = EqualizerSettings(clearBass: 5, bands: [4, 0, 0, 0, 0])
        controller.setCustomEqualizer(.flat)
        controller.setCustomEqualizer(first)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.setCustomEqualizer(skipped)
        controller.setCustomEqualizer(latest)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.map(\.payload), [first.sonySetPayload])
        deliver([0x59] + first.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, latest.sonySetPayload)
        XCTAssertTrue(controller.isEqualizerUpdatePending)
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + first.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        deliver([0x59] + latest.sonySetPayload.dropFirst(), to: controller)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.customEqualizer, latest)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.map(\.payload), [first.sonySetPayload, latest.sonySetPayload])
    }

    @MainActor
    func testPresetChangeSupersedesTheWaitingCustomDraftWithoutOptimism() async throws {
        let controller = makeController()
        controller.setCustomEqualizer(.flat)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.setCustomEqualizer(EqualizerSettings(clearBass: 4, bands: [1, 1, 1, 1, 1]))
        controller.setEqualizerPreset(.bright)
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x00, 0x10, 0x00])
        acknowledgeSimulatedCommands(controller)
        deliver([0x69, 0x19, 1, 1, 0, 0, 10, 0, 0], to: controller)
        XCTAssertTrue(controller.isEqualizerUpdatePending)
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0x00, 0x10, 6, 10, 10, 10, 10, 10, 10], to: controller)
        XCTAssertEqual(controller.equalizerPreset, .bright)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
    }

    @MainActor
    func testEqualizerTimeoutIsVisibleAndALateMatchingReplyClearsIt() async throws {
        let controller = makeController()
        let settings = EqualizerSettings(clearBass: 3, bands: [1, 2, 3, 4, 5])
        controller.setCustomEqualizer(settings)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.settingErrors[.equalizer], "Headphones did not confirm the change.")
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
        deliver([0x57] + settings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNil(controller.settingErrors[.equalizer])
        XCTAssertEqual(controller.customEqualizer, settings)
    }

    @MainActor
    func testExplicitSyncRequiresAValidReplyAndSerializesLaterEdits() async throws {
        let controller = makeController()
        deliver([0x57, 0, 0xA0, 0], to: controller)
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        let originalReadback = controller.equalizerReadbackID
        let settings = EqualizerSettings(clearBass: 2, bands: [2, 2, 2, 2, 2])
        controller.setCustomEqualizer(settings)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x58 })
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.equalizerReadbackID, originalReadback)
        deliver([0x57, 0x00, 0xA0, 6, 21, 10, 10, 10, 10, 10], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        deliver([0x57] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotEqual(controller.equalizerReadbackID, originalReadback)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, settings.sonySetPayload)
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + settings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.customEqualizer, settings)
    }

    @MainActor
    func testExplicitSyncTimeoutCanBeRetriedWithoutChangingConfirmedSettings() async throws {
        let controller = makeController()
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.settingErrors[.equalizerReadback], "Headphones did not return equalizer settings.")
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
        XCTAssertEqual(controller.customEqualizer, .flat)
        controller.refreshEqualizer(trackConfirmation: true)
        XCTAssertNotNil(controller.settingErrors[.equalizerReadback])
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 1)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNil(controller.equalizerReadbackID)
        controller.refreshEqualizer(trackConfirmation: true)
        XCTAssertNil(controller.settingErrors[.equalizerReadback])
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
    }

    @MainActor
    func testExplicitSyncWaitsForTheBackgroundReplyThenSendsItsOwnRead() {
        let controller = makeController()
        controller.refreshEqualizer()
        controller.refreshEqualizer()
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 1)
        let oldSettings = EqualizerSettings(clearBass: 1, bands: [1, 1, 1, 1, 1])
        deliver([0x57] + oldSettings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNil(controller.equalizerReadbackID)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x56, 0x00])
        acknowledgeSimulatedCommands(controller)
        let currentSettings = EqualizerSettings(clearBass: 4, bands: [2, 2, 2, 2, 2])
        deliver([0x57] + currentSettings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.customEqualizer, currentSettings)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 2)
    }

    @MainActor
    func testUnansweredBackgroundReadDoesNotReassignItsLateReplyToSync() async throws {
        let controller = makeController()
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        controller.refreshEqualizer(trackConfirmation: true)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotNil(controller.settingErrors[.equalizerReadback])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 1)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNil(controller.equalizerReadbackID)
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertNil(controller.settingErrors[.equalizerReadback])
    }

    @MainActor
    func testDisconnectCancelsDebouncePendingRequestsAndAutomaticReplay() async throws {
        let controller = makeController()
        deliver([0x57, 0, 0xA0, 0], to: controller)
        let settings = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        controller.setCustomEqualizer(settings)
        controller.simulateDeviceConnection(named: nil)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x58 })
        controller.setCustomEqualizer(settings)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.setCustomEqualizer(.flat)
        let session = controller.simulatedControlSession
        let sentCount = controller.simulatedTransmittedFrames.count
        controller.simulateDeviceConnection(named: nil)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0x59] + settings.sonySetPayload.dropFirst(), session: session)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, sentCount)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertTrue(controller.settingErrors.isEmpty)
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
    }

    @MainActor
    private func makeSlotController(active: UInt8 = 0x16) -> SonyHeadphonesController {
        let controller = makeController()
        deliver([0x51, 0, 6, 21, 4, 0x16, 0, 0xA0, 0, 0xA1, 0, 0xA2, 0], to: controller)
        deliver([0x57, 0, active, 0], to: controller)
        acknowledgeSimulatedCommands(controller)
        return controller
    }

    private var slotCurve: EqualizerSettings { EqualizerSettings(clearBass: 10, bands: [-10, -4, 0, 6, 10]) }
    private let slotRaw: [UInt8] = [20, 0, 6, 10, 16, 20]

    @MainActor
    func testSavingToUser1SelectsTheSlotBeforeWritingAndConfirmsByRereading() throws {
        for slot: UInt8 in [0xA1, 0xA2] {
            let controller = makeSlotController()
            XCTAssertEqual(controller.equalizer.savableSlots, [0xA1, 0xA2])
            let sent = controller.simulatedTransmittedFrames.count
            controller.saveEqualizerCurve(slotCurve, toSlot: slot)
            // 58 00 Ax 00 goes out alone; no values until the slot is confirmed.
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0, slot, 0])
            XCTAssertEqual(controller.simulatedTransmittedFrames.dropFirst(sent).filter { $0.payload.count > 4 }.count, 0)
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.isEqualizerUpdatePending)
            deliver([0x59, 0, slot, 0], to: controller)
            let write: [UInt8] = [0x58, 0, slot, 6] + slotRaw
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, write)
            acknowledgeSimulatedCommands(controller)
            XCTAssertNotNil(controller.pendingChanges[.equalizer])
            // The re-read of that slot is what confirms the save.
            controller.refreshEqualizer()
            acknowledgeSimulatedCommands(controller)
            deliver([0x57, 0, slot, 6] + slotRaw, to: controller)
            XCTAssertFalse(controller.isEqualizerUpdatePending)
            XCTAssertNil(controller.settingErrors[.equalizer])
            XCTAssertEqual(controller.equalizerPreset.map(\.rawValue), slot)
            XCTAssertEqual(controller.equalizer.settings, slotCurve)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.count, 2)
        }
    }

    @MainActor
    func testSlotSaveIsNotConfirmedByAMismatchingRereadAndReportsTheError() async {
        let controller = makeSlotController()
        controller.saveEqualizerCurve(slotCurve, toSlot: 0xA1)
        acknowledgeSimulatedCommands(controller)
        deliver([0x59, 0, 0xA1, 0], to: controller)
        acknowledgeSimulatedCommands(controller)
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0, 0xA1, 6, 10, 10, 10, 10, 10, 10], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        controller.simulateSettingTimeout(.equalizer)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.settingErrors[.equalizer], "Headphones did not confirm the change.")
        XCTAssertNotEqual(controller.equalizer.settings, slotCurve)
    }

    @MainActor
    func testSlotSaveIsRefusedWhenTheHeadphonesDoNotAdvertiseTheSlot() {
        let controller = makeController()
        XCTAssertEqual(controller.equalizer.savableSlots, [])
        let sent = controller.simulatedTransmittedFrames.count
        controller.saveEqualizerCurve(slotCurve, toSlot: 0xA1)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, sent)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
    }

    @MainActor
    func testManualCurveSelectsManualFirstWhenAUserSlotIsActive() async throws {
        for active: UInt8 in [0xA1, 0x16] {
            let controller = makeSlotController(active: active)
            controller.setCustomEqualizer(slotCurve)
            try await Task.sleep(for: .milliseconds(180))
            // Writing to A0 while User 1 is active would store the curve in Manual without activating it.
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0, 0xA0, 0])
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.count > 4 && $0.payload.first == 0x58 }.count, 0)
            acknowledgeSimulatedCommands(controller)
            deliver([0x59, 0, 0xA0, 0], to: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0, 0xA0, 6] + slotRaw)
            acknowledgeSimulatedCommands(controller)
            deliver([0x59, 0, 0xA0, 6] + slotRaw, to: controller)
            XCTAssertFalse(controller.isEqualizerUpdatePending)
            XCTAssertEqual(controller.equalizerPreset, .manual)
        }
    }

    @MainActor
    func testManualCurveSelectionFailureDropsTheWaitingCurve() async throws {
        let controller = makeSlotController(active: 0xA1)
        controller.setCustomEqualizer(slotCurve)
        acknowledgeSimulatedCommands(controller)
        controller.simulateSettingTimeout(.equalizer)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNotNil(controller.settingErrors[.equalizer])
        deliver([0x59, 0, 0xA0, 0], to: controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.count > 4 && $0.payload.first == 0x58 }.count, 0)
    }

    @MainActor
    private func makeController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }
}

final class SonyInitialHandshakeTests: XCTestCase {
    func testEveryByteSurvivesDeterministicFragmentationAndRejectedPrefixesRecover() {
        for sequence: UInt8 in [0, 1] {
            for type: UInt8 in [0x01, 0x0C, 0x0E, 0xFF] {
                let payload = Array(UInt8.min...UInt8.max)
                let expected = SonyFrame(type: type, sequence: sequence, payload: payload)
                let encoded = SonyFrameCodec.encode(type: type, sequence: sequence, payload: payload)
                for strideLength in [1, 2, 3, 7, 31, 127] {
                    var stream = SonyFrameStream()
                    var received: [SonyFrame] = []
                    for start in stride(from: 0, to: encoded.count, by: strideLength) {
                        received += stream.append(encoded[start..<min(encoded.count, start + strideLength)])
                    }
                    XCTAssertEqual(received, [expected], "Type \(type), sequence \(sequence), chunk \(strideLength)")
                }
                for length in 0..<encoded.count {
                    var stream = SonyFrameStream()
                    XCTAssertTrue(stream.append(encoded.prefix(length)).isEmpty)
                    XCTAssertEqual(stream.append(encoded), [expected], "Prefix \(length)")
                }
                for offset in 1..<(encoded.count - 1) {
                    var corrupted = encoded
                    corrupted[offset] ^= 1
                    var stream = SonyFrameStream()
                    XCTAssertEqual(stream.append(corrupted + encoded), [expected], "Mutation \(offset)")
                }
            }
        }
    }

    @MainActor
    func testAllSingleByteCommandsAndUnknownFrameTypesCannotCompleteInitialHandshake() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(Data(), beginConnection: true)
        let pending = controller.simulatedPendingFrame
        for type: UInt8 in [0x0C, 0x0E] {
            for command in UInt8.min...UInt8.max {
                controller.simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: command % 2, payload: [command]))
                XCTAssertEqual(controller.linkState, .handshaking, "Table \(type), command \(command)")
                XCTAssertEqual(controller.simulatedPendingFrame, pending)
                XCTAssertNil(controller.protocolInformation)
            }
        }
        let transmitted = controller.simulatedTransmittedFrames.count
        for type in UInt8.min...UInt8.max where ![0x01, 0x0C, 0x0E].contains(type) {
            controller.simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: type % 2,
                payload: [0x01, 0, 3, 0, 0x30, 0x18, 0, 0]))
        }
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, transmitted)
        XCTAssertEqual(controller.simulatedPendingFrame, pending)
        XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
    }

    @MainActor
    func testEveryRecognizedModelUsesNegotiatedGenerationAndNoiseInquiry() throws {
        let profiles: [(protocolPayload: [UInt8], functions: [UInt8], inquiry: UInt8?)] = [
            ([0x01, 0, 0x40, 0], [0x62], 2),
            ([0x01, 0, 0x40, 0], [], nil),
            ([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], [0x6B], 0x17),
            ([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], [0x6D], 0x19),
            ([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], [], nil),
        ]
        for model in SonyDeviceModel.allCases where model != .unknown {
            for profile in profiles {
                let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
                defer { controller.simulateControlLoss() }
                controller.simulateDeviceConnection(named: model.name, controlBusy: true)
                deliver(profile.protocolPayload, to: controller, begin: true)
                let generation = try XCTUnwrap(SonyProtocolInfo(payload: profile.protocolPayload)).generation
                XCTAssertEqual(controller.protocolInformation?.generation, generation, model.name)
                XCTAssertFalse(controller.isReady, model.name)
                drain(controller)
                let functions = generation == .v1 ? profile.functions : profile.functions.flatMap { [$0, 0] }
                deliver([0x07, 0, UInt8(profile.functions.count)] + functions, to: controller)
                drain(controller)
                if let inquiry = profile.inquiry {
                    XCTAssertFalse(controller.isReady, model.name)
                    XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x60, inquiry] }, model.name)
                    if generation == .v1 {
                        deliver([0x61, 2, 0, 2, 1, 2, 0, 20, 1, 20], to: controller)
                    } else {
                        deliver([0x61, inquiry, 2, 0, 1, 20, 1, 1, 1, 20, 1], to: controller)
                    }
                    deliver([0x63, inquiry, 0], to: controller)
                    drain(controller)
                    XCTAssertFalse(controller.isReady, model.name)
                    let state: [UInt8] = generation == .v1
                        ? [0x67, 2, 1, 0, 0, 1, 0, 12]
                        : [0x67, inquiry, 1, 1, 1, 0, 12] + (inquiry == 0x19 ? [0, 0] : [])
                    for length in 1..<state.count {
                        deliver(Array(state.prefix(length)), to: controller)
                        XCTAssertFalse(controller.isReady, "\(model.name), truncated state \(length)")
                    }
                    deliver(state, to: controller)
                    XCTAssertTrue(controller.canChangeNoiseControl, model.name)
                }
                XCTAssertTrue(controller.isReady, "\(model.name), \(generation), inquiry \(String(describing: profile.inquiry))")
                XCTAssertFalse(controller.simulatedHandshakeTimeoutPending, model.name)
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E }, model.name)
            }
        }
    }

    @MainActor
    func testInitialStageTimeoutsRetireSessionAndLateFramesCannotOwnRetry() async throws {
        for stage in 0..<4 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "Renamed Sony headphones", controlBusy: true)
            controller.simulateProtocolData(Data(), beginConnection: true)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0])
            if stage > 0 { drain(controller) }
            if stage > 1 {
                deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller)
                drain(controller)
            }
            if stage > 2 {
                deliver([0x07, 0, 1, 0x6B, 0], to: controller)
                drain(controller)
            }
            let expiredSession = controller.simulatedControlSession
            controller.simulateHandshakeTimeout()
            for _ in 0..<8 { await Task.yield() }
            XCTAssertFalse(controller.isReady)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
            controller.simulateProtocolData(Data(), beginConnection: true)
            let retrySession = controller.simulatedControlSession
            XCTAssertGreaterThan(retrySession, expiredSession)
            let pending = try XCTUnwrap(controller.simulatedPendingFrame)
            let transmitted = controller.simulatedTransmittedFrames.count
            for payload: [UInt8] in [[0x01, 0, 3, 0, 0x30, 0x18, 0, 1], [0x07, 0, 0], [0x67, 0x17, 1, 1, 0, 0, 12]] {
                controller.simulateProtocolMessage(payload, session: expiredSession)
            }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - pending.sequence, payload: []), session: expiredSession)
            XCTAssertEqual(controller.simulatedPendingFrame, pending)
            XCTAssertEqual(controller.simulatedTransmittedFrames.count, transmitted)
            XCTAssertEqual(controller.linkState, .handshaking)
            drain(controller)
            deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller)
            drain(controller)
            deliver([0x07, 0, 0], to: controller)
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testV2UnavailableNoiseStillCompletesControlHandshakeWithValidParameter() {
        for (function, inquiry): (UInt8, UInt8) in [(0x6B, 0x17), (0x6D, 0x19)] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller, begin: true)
            drain(controller)
            deliver([0x07, 0, 1, function, 0], to: controller)
            drain(controller)
            deliver([0x61, inquiry, 2, 0, 1, 20, 1, 1, 1, 20, 1], to: controller)
            deliver([0x63, inquiry, 1], to: controller)
            drain(controller)
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x66, inquiry] })
            deliver([0x67, inquiry, 1, 1, 1, 0, 12] + (inquiry == 0x19 ? [0, 0] : []), to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertFalse(controller.canChangeNoiseControl)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
            deliver([0x65, inquiry, 0], to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canChangeNoiseControl)
        }
    }

    @MainActor
    func testBLEHandshakeRequiresCompleteMatchingIdentityAndRejectsLegacyGeneration() {
        let identity: [UInt8] = [0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8)
        for legacy in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            let protocolPayload: [UInt8] = legacy ? [0x01, 0, 0x40, 0] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 1]
            controller.simulateProtocolMessage(protocolPayload,
                beginConnection: true, expectedBLEHash: "ABCDEF12")
            drain(controller)
            if legacy {
                XCTAssertFalse(controller.isReady)
                XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x06, 0] })
                continue
            }
            deliver([0x07, 0, 1, 0x14, 0], to: controller)
            drain(controller)
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0x10, 4] })
            for length in 1..<identity.count {
                deliver(Array(identity.prefix(length)), to: controller)
                XCTAssertFalse(controller.isReady, "Truncated BLE identity \(length)")
            }
            deliver(identity, to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.bluetoothLEHash, "ABCDEF12")
        }
        let mismatched = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { mismatched.simulateControlLoss() }
        mismatched.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true, expectedBLEHash: "00000000")
        drain(mismatched)
        deliver([0x07, 0, 1, 0x14, 0], to: mismatched)
        drain(mismatched)
        deliver(identity, to: mismatched)
        XCTAssertFalse(mismatched.isReady)
        XCTAssertNil(mismatched.simulatedPendingFrame)
        XCTAssertFalse(mismatched.simulatedHandshakeTimeoutPending)
    }

    @MainActor
    func testFirstAutomaticBLEFallbackHasFiniteAttemptsAndConnectionWait() {
        for attempt in 0...3 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: false,
                classicConnected: true, retryAttempt: attempt), attempt < 2)
            XCTAssertFalse(controller.simulatedBLEWaitsForConnection)
        }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: false, priorBluetoothLE: false,
            classicConnected: true, retryAttempt: 3))
        XCTAssertFalse(controller.simulatedBLEWaitsForConnection)
        XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: true,
            classicConnected: true, retryAttempt: 3))
        XCTAssertTrue(controller.simulatedBLEWaitsForConnection)
    }

    @MainActor
    func testFirstBLEHandshakePinsPairedUUIDAndLearnsHashWithoutUsingHostAddress() throws {
        let suite = "dev.baglayan.Acouplet.first-ble-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identifier = UUID()
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true,
            pairedPeripheralID: identifier, connectedPeripheralID: identifier)
        drain(controller)
        deliver([0x07, 0, 1, 0x14, 0], to: controller)
        drain(controller)
        let identity: [UInt8] = [0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8)
        for length in 1..<identity.count {
            deliver(Array(identity.prefix(length)), to: controller)
            XCTAssertFalse(controller.isReady)
            XCTAssertTrue(SonyBLEIdentity.savedDevices(in: defaults).isEmpty)
        }
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x20, 0x09] })
        deliver(identity, to: controller)
        XCTAssertTrue(controller.isReady)
        let saved = try XCTUnwrap(controller.simulatedSavedIdentity)
        XCTAssertEqual(saved.classicAddress, "02:53:4F:4E:59:01")
        XCTAssertEqual(saved.model, .wfXM5)
        XCTAssertEqual(saved.hash, "ABCDEF12")
        XCTAssertEqual(saved.peripheralIdentifier, identifier)
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults)[saved.classicAddress], saved)
        deliver([0x11, 0x04] + Array("00:11:22:33:44:5500000000".utf8), to: controller)
        XCTAssertEqual(controller.simulatedSavedIdentity, saved)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testFirstBLEHandshakeRejectsWrongOrMissingPairedUUIDWithoutSavingIdentity() throws {
        for connectedIdentifier in [UUID(), nil] {
            let suite = "dev.baglayan.Acouplet.first-ble-tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
            controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true,
                pairedPeripheralID: UUID(), connectedPeripheralID: connectedIdentifier)
            drain(controller)
            deliver([0x07, 0, 1, 0x14, 0], to: controller)
            drain(controller)
            deliver([0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8), to: controller)
            XCTAssertFalse(controller.isReady)
            XCTAssertNil(controller.simulatedSavedIdentity)
            XCTAssertTrue(SonyBLEIdentity.savedDevices(in: defaults).isEmpty)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        }
    }

    @MainActor
    func testFirstBLEHandshakeRequiresSupportedIdentityAndV2Protocol() {
        for legacy in [false, true] {
            let identifier = UUID()
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            let protocolPayload: [UInt8] = legacy ? [0x01, 0, 0x40, 0] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 1]
            controller.simulateProtocolMessage(protocolPayload,
                beginConnection: true, pairedPeripheralID: identifier, connectedPeripheralID: identifier)
            drain(controller)
            if !legacy { deliver([0x07, 0, 0], to: controller) }
            XCTAssertFalse(controller.isReady)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x10, 0x04] })
        }
    }

    @MainActor
    func testBLEIdentityReplyCannotBypassQueuedIdentityQuery() {
        let identifier = UUID()
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true,
            pairedPeripheralID: identifier, connectedPeripheralID: identifier)
        drain(controller)
        deliver([0x07, 0, 2, 0x40, 0, 0x14, 0], to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x40, 0])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x10, 0x04] })
        let identity: [UInt8] = [0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8)
        deliver(identity, to: controller)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.bluetoothLEHash)
        drain(controller)
        deliver(identity, to: controller)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testV2CapabilitiesCannotCompleteHandshakeBeforeTheirQueryWasTransmitted() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller, begin: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x06, 0] })
        deliver([0x07, 0, 0], to: controller)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
        drain(controller)
        deliver([0x07, 0, 0], to: controller)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testV2CapabilityOwnershipSurvivesACKAndMalformedReplies() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller, begin: true)
        drain(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x06, 0] }.count, 1)
        for payload: [UInt8] in [[0x07], [0x07, 1, 0], [0x07, 0, 1], [0x07, 0, 0, 1]] {
            deliver(payload, to: controller)
            XCTAssertFalse(controller.isReady)
            XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
        }
        deliver([0x07, 0, 0], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
    }

    @MainActor
    func testV2CapabilityReplyBeforeNativeWriteCompletionCannotConsumeOwnership() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller, begin: true)
        controller.defersSimulatedWrites = true
        let initial = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - initial.sequence, payload: []))
        for expected: [UInt8] in [[0x04, 1], [0x04, 3]] {
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, expected)
            controller.completeSimulatedWrite()
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x06, 0])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x06, 0] })
        deliver([0x07, 0, 0], to: controller)
        XCTAssertFalse(controller.isReady)
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        deliver([0x07, 0, 0], to: controller)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testTable2ProtocolReplyCannotNegotiateTable1Handshake() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0E, sequence: 0,
            payload: [0x01, 0, 3, 0, 0x30, 0x18, 0, 0]), beginConnection: true)
        XCTAssertNil(controller.protocolInformation)
        drain(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x06, 0] })
        XCTAssertEqual(controller.linkState, .handshaking)
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], to: controller)
        drain(controller)
        deliver([0x07, 0, 0], to: controller)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testAcknowledgedDiscoveryReadsRetryOnceAndAcceptLateRepliesAfterExhaustion() async throws {
        for read in discoveryReads {
            let controller = makeDiscoveryController()
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 1)
            let firstTimeout = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            let firstWork = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutWork(read.query, type: read.type))
            controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
            for _ in 0..<8 { await Task.yield() }
            drain(controller)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            let retryTimeout = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            XCTAssertNotEqual(firstTimeout, retryTimeout)
            firstWork.perform()
            for _ in 0..<8 { await Task.yield() }
            XCTAssertEqual(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type), retryTimeout)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            XCTAssertTrue(controller.isReady)
            for _ in 0..<3 {
                controller.simulateAutomaticRefresh()
                drain(controller)
                controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
                for _ in 0..<8 { await Task.yield() }
            }
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testValidDiscoveryReplyCancelsItsResponseDeadlineAndStaleCallback() async throws {
        for read in discoveryReads {
            let controller = makeDiscoveryController()
            defer { controller.simulateControlLoss() }
            let timeout = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutWork(read.query, type: read.type))
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            timeout.perform()
            for _ in 0..<8 { await Task.yield() }
            drain(controller)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 1)
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testMalformedAndWrongTableDiscoveryRepliesPreserveTheOwnedDeadline() throws {
        for read in discoveryReads {
            let controller = makeDiscoveryController()
            defer { controller.simulateControlLoss() }
            let timeout = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            for payload in [Array(read.reply.prefix(2)), read.reply + [0xFF]] {
                deliverDiscovery(payload, type: read.type, to: controller)
                XCTAssertEqual(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type), timeout)
            }
            for type: UInt8 in [0x0C, 0x0D, 0x0E] where type != read.type {
                deliverDiscovery(read.reply, type: type, to: controller)
                XCTAssertEqual(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type), timeout)
            }
            if read.query == [0x06, 0] { XCTAssertFalse(controller.hasCurrentTable2Capabilities) }
            else if read.query == [0x04, 1] { XCTAssertNil(controller.deviceInformation.modelName) }
            else { XCTAssertNil(controller.deviceInformation.series) }
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
        }
    }

    @MainActor
    func testQueuedDiscoveryReplyCannotClaimOwnershipBeforeTransmission() {
        for read in discoveryReads {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], to: controller, begin: true)
            if read.type == 0x0E {
                advance(to: [0x06, 0], type: 0x0C, on: controller)
                deliver([0x07, 0, 0], to: controller)
                XCTAssertTrue(controller.isReady)
            }
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 0)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            deliverDiscovery(read.reply, type: read.type, to: controller)
            if read.type == 0x0E { XCTAssertFalse(controller.hasCurrentTable2Capabilities) }
            else if read.query == [0x04, 1] { XCTAssertNil(controller.deviceInformation.modelName) }
            else { XCTAssertNil(controller.deviceInformation.series) }
            drain(controller)
            if !controller.isReady {
                deliver([0x07, 0, 0], to: controller)
                drain(controller)
            }
            XCTAssertNotNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
        }
    }

    @MainActor
    func testDiscoveryOwnershipStartsAtNativeWriteCompletion() {
        for read in discoveryReads {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], to: controller, begin: true)
            if read.type == 0x0E {
                advance(to: [0x06, 0], type: 0x0C, on: controller)
                deliver([0x07, 0, 0], to: controller)
            }
            controller.defersSimulatedWrites = true
            for _ in 0..<128 {
                guard let frame = controller.simulatedPendingFrame else { break }
                if frame.type == read.type, frame.payload == read.query { break }
                controller.completeSimulatedWrite()
                controller.completeSimulatedWrite()
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
            }
            XCTAssertEqual(controller.simulatedPendingFrame?.type, read.type)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, read.query)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 0)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            deliverDiscovery(read.reply, type: read.type, to: controller)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            if read.type == 0x0E { XCTAssertFalse(controller.hasCurrentTable2Capabilities) }
            else if read.query == [0x04, 1] { XCTAssertNil(controller.deviceInformation.modelName) }
            else { XCTAssertNil(controller.deviceInformation.series) }
            controller.completeSimulatedWrite()
            controller.completeSimulatedWrite()
            controller.defersSimulatedWrites = false
            XCTAssertNotNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
        }
    }

    @MainActor
    func testDiscoveryDeadlineAndReplyFromPreviousSessionCannotOwnReconnect() async throws {
        for read in discoveryReads {
            let controller = makeDiscoveryController()
            defer { controller.simulateControlLoss() }
            let staleTimeout = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutWork(read.query, type: read.type))
            let staleSession = controller.simulatedControlSession
            controller.simulateControlLoss()
            beginDiscoveryHandshake(on: controller)
            let currentTimeout = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            let transmissions = discoveryTransmissionCount(read.query, type: read.type, on: controller)
            staleTimeout.perform()
            controller.simulateProtocolMessage(read.reply, type: read.type, session: staleSession)
            for _ in 0..<8 { await Task.yield() }
            drain(controller)
            XCTAssertEqual(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type), currentTimeout)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), transmissions)
            if read.type == 0x0E { XCTAssertFalse(controller.hasCurrentTable2Capabilities) }
            else if read.query == [0x04, 1] { XCTAssertNil(controller.deviceInformation.modelName) }
            else { XCTAssertNil(controller.deviceInformation.series) }
            XCTAssertTrue(controller.isReady)
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
        }
    }

    @MainActor
    func testConfirmedEmptyTable2CompletesDiscoveryWithoutRepeatingQueries() async throws {
        let controller = makeDiscoveryController()
        defer { controller.simulateControlLoss() }
        let timeout = try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutWork([0x06, 0], type: 0x0E))
        deliverDiscovery([0x07, 0, 0], type: 0x0E, to: controller)
        XCTAssertTrue(controller.hasCurrentTable2Capabilities)
        XCTAssertTrue(controller.supportedFunctions2.isEmpty)
        XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID([0x06, 0], type: 0x0E))
        timeout.perform()
        for _ in 0..<8 { await Task.yield() }
        for _ in 0..<3 {
            controller.simulateAutomaticRefresh()
            drain(controller)
        }
        XCTAssertEqual(discoveryTransmissionCount([0x06, 0], type: 0x0E, on: controller), 1)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testOriginalDiscoveryReplyDiscardsItsQueuedRetryBeforeTransmission() async throws {
        for read in discoveryReads {
            let controller = makeDiscoveryController()
            defer { controller.simulateControlLoss() }
            for other in discoveryReads where other.type != read.type || other.query != read.query {
                deliverDiscovery(other.reply, type: other.type, to: controller)
            }
            drain(controller)
            for _ in 0..<5 { controller.simulateAutomaticRefresh() }
            let blocker = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertNotEqual([blocker.type] + blocker.payload, [read.type] + read.query)
            controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertEqual(controller.simulatedPendingFrame, blocker)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 1)
            deliverDiscovery(read.reply, type: read.type, to: controller)
            drain(controller)
            assertDiscoveryReceived(read.query, on: controller)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 1)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            controller.simulateSameTransportHandshake()
            XCTAssertEqual(controller.linkState, .handshaking)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        }
    }

    @MainActor
    func testDuplicateTable2ReplyAfterTransmittedRetryCannotReplaceCapabilitiesOrPermitChannelReuse() async {
        let controller = makeDiscoveryController()
        defer { controller.simulateControlLoss() }
        for read in discoveryReads where read.type == 0x0C {
            deliverDiscovery(read.reply, type: read.type, to: controller)
        }
        controller.simulateDiscoveryReadTimeout([0x06, 0], type: 0x0E)
        for _ in 0..<8 { await Task.yield() }
        drain(controller)
        XCTAssertEqual(discoveryTransmissionCount([0x06, 0], type: 0x0E, on: controller), 2)
        deliverDiscovery([0x07, 0, 1, 0x42, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.supportedFunctions2, [0x42])
        deliverDiscovery([0x07, 0, 1, 0xF0, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.supportedFunctions2, [0x42])
        XCTAssertTrue(controller.voiceGuidance.supportsGuidance)
        XCTAssertFalse(controller.wearingStatus.isSupported)
        deliverDiscovery([0x07, 0, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.supportedFunctions2, [0x42])
        drain(controller)
        let protocolQueries = discoveryTransmissionCount([0, 0], type: 0x0C, on: controller)
        let session = controller.simulatedControlSession
        controller.simulateSameTransportHandshake()
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(discoveryTransmissionCount([0, 0], type: 0x0C, on: controller), protocolQueries)
    }

    @MainActor
    func testOriginalDiscoveryReplyDuringDeferredRetryCompletionRequiresFreshTransport() async {
        for read in discoveryReads {
            let controller = makeDiscoveryController()
            defer { controller.simulateControlLoss() }
            for other in discoveryReads where other.type != read.type || other.query != read.query {
                deliverDiscovery(other.reply, type: other.type, to: controller)
            }
            drain(controller)
            controller.defersSimulatedWrites = true
            controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertEqual(controller.simulatedPendingFrame?.type, read.type)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, read.query)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 1)
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
            controller.completeSimulatedWrite()
            controller.completeSimulatedWrite()
            controller.defersSimulatedWrites = false
            drain(controller)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            let protocolQueries = discoveryTransmissionCount([0, 0], type: 0x0C, on: controller)
            let session = controller.simulatedControlSession
            controller.simulateSameTransportHandshake()
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(discoveryTransmissionCount([0, 0], type: 0x0C, on: controller), protocolQueries)
        }
    }

    @MainActor
    func testSameTransportHandshakeStartsFreshDiscoveryAfterAllResponsesDrain() {
        let controller = makeDiscoveryController()
        defer { controller.simulateControlLoss() }
        for read in discoveryReads {
            deliverDiscovery(read.reply, type: read.type, to: controller)
        }
        drain(controller)
        let session = controller.simulatedControlSession
        controller.simulateSameTransportHandshake()
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        XCTAssertNil(controller.deviceInformation.modelName)
        XCTAssertNil(controller.deviceInformation.series)
        XCTAssertFalse(controller.hasCurrentTable2Capabilities)
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], to: controller)
        drain(controller)
        deliver([0x07, 0, 0], to: controller)
        drain(controller)
        for read in discoveryReads {
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            XCTAssertNotNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
        }
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testExpiredUnansweredDiscoveryForcesAReopenBeforeAnotherHandshake() async {
        for read in discoveryReads {
            let controller = makeDiscoveryController()
            defer { controller.simulateControlLoss() }
            for other in discoveryReads where other.type != read.type || other.query != read.query {
                deliverDiscovery(other.reply, type: other.type, to: controller)
            }
            drain(controller)
            for _ in 0..<2 {
                controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
                for _ in 0..<8 { await Task.yield() }
                drain(controller)
            }
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            let protocolQueries = discoveryTransmissionCount([0, 0], type: 0x0C, on: controller)
            let session = controller.simulatedControlSession
            controller.simulateSameTransportHandshake()
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(discoveryTransmissionCount([0, 0], type: 0x0C, on: controller), protocolQueries)
            controller.simulateProtocolMessage(read.reply, type: read.type, session: session)
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertNil(controller.deviceInformation.modelName)
            XCTAssertTrue(controller.supportedFunctions2.isEmpty)
        }
    }

    @MainActor
    func testDiscoveryRetryDeferredDuringFitTestResumesOnceOnOrdinaryRefresh() async throws {
        for read in discoveryReads {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
            deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], to: controller, begin: true)
            drain(controller)
            deliver([0x07, 0, 1, 0xF6, 0], to: controller)
            drain(controller)
            for other in discoveryReads where other.type != read.type || other.query != read.query {
                deliverDiscovery(other.reply, type: other.type, to: controller)
            }
            drain(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.beginEarTipFit())
            let fit = try XCTUnwrap(controller.earTipFitTransition?.id)
            drain(controller)
            XCTAssertTrue(controller.isRunningHeadphoneTest)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .checking)
            controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 1)
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            drain(controller)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 1)
            for reply: [UInt8] in [
                [0xF1, 6, 10, 0], [0xF3, 6, 0, 0, 1, 0],
                [0xF7, 6, 0, 0, 1, 0, 0, 0xFF],
            ] {
                deliver(reply, to: controller)
            }
            XCTAssertEqual(controller.earTipFitTransition?.phase, .ready)
            controller.cancelEarTipFit(id: fit)
            XCTAssertEqual(controller.earTipFitTransition?.phase, .finished)
            controller.dismissEarTipFit(id: fit)
            XCTAssertFalse(controller.isRunningHeadphoneTest)
            for _ in 0..<5 { controller.simulateAutomaticRefresh() }
            drain(controller)
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            XCTAssertNotNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
            for _ in 0..<8 { await Task.yield() }
            for _ in 0..<15 {
                controller.simulateAutomaticRefresh()
                drain(controller)
            }
            XCTAssertEqual(discoveryTransmissionCount(read.query, type: read.type, on: controller), 2)
            XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
            XCTAssertTrue(controller.isReady)
            deliverDiscovery(read.reply, type: read.type, to: controller)
            assertDiscoveryReceived(read.query, on: controller)
        }
    }

    private var discoveryReads: [(query: [UInt8], type: UInt8, reply: [UInt8])] {
        let name = Array("WF-1000XM5".utf8)
        return [
            ([0x04, 1], 0x0C, [0x05, 1, UInt8(name.count)] + name),
            ([0x04, 3], 0x0C, [0x05, 3, 0x30, 0]),
            ([0x06, 0], 0x0E, [0x07, 0, 1, 0x42, 0]),
        ]
    }

    @MainActor
    private func makeDiscoveryController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        beginDiscoveryHandshake(on: controller)
        return controller
    }

    @MainActor
    private func beginDiscoveryHandshake(on controller: SonyHeadphonesController) {
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], to: controller, begin: true)
        drain(controller)
        deliver([0x07, 0, 0], to: controller)
        drain(controller)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    private func deliverDiscovery(_ payload: [UInt8], type: UInt8, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    @MainActor
    private func discoveryTransmissionCount(_ query: [UInt8], type: UInt8, on controller: SonyHeadphonesController) -> Int {
        controller.simulatedTransmittedFrames.filter { $0.type == type && $0.payload == query }.count
    }

    @MainActor
    private func assertDiscoveryReceived(_ query: [UInt8], on controller: SonyHeadphonesController) {
        if query == [0x06, 0] {
            XCTAssertTrue(controller.hasCurrentTable2Capabilities)
            XCTAssertEqual(controller.supportedFunctions2, [0x42])
            XCTAssertTrue(controller.voiceGuidance.supportsGuidance)
        } else if query == [0x04, 1] {
            XCTAssertEqual(controller.deviceInformation.model, .wfXM5)
        } else {
            XCTAssertEqual(controller.deviceInformation.series, 0x30)
            XCTAssertEqual(controller.deviceInformation.color?.rawValue, 0)
        }
    }

    @MainActor
    private func advance(to query: [UInt8], type: UInt8, on controller: SonyHeadphonesController) {
        for _ in 0..<128 {
            guard let frame = controller.simulatedPendingFrame else { break }
            if frame.type == type, frame.payload == query { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("Discovery query was not reached")
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController, begin: Bool = false) {
        controller.simulateProtocolMessage(payload, beginConnection: begin)
    }

    @MainActor
    private func drain(_ controller: SonyHeadphonesController) {
        for _ in 0..<128 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("Handshake commands did not drain within 128 acknowledgments")
    }
}

final class SonyReceiveSequenceTests: XCTestCase {
    @MainActor
    func testDuplicateDataIsAcknowledgedWithoutApplyingAgainAndNewSequenceAcceptsTheSamePayload() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        var observations = 0
        let observation = controller.$batteries.dropFirst().sink { _ in observations += 1 }
        defer { observation.cancel() }
        let payload: [UInt8] = [0x25, 0, 50, 0]
        let packet = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: payload)
        controller.simulateProtocolData(packet)
        XCTAssertEqual(controller.batteryLevel, 50)
        XCTAssertEqual(observations, 1)
        controller.simulateProtocolData(packet)
        XCTAssertEqual(controller.batteryLevel, 50)
        XCTAssertEqual(observations, 1)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: payload))
        XCTAssertEqual(observations, 2)
        XCTAssertEqual(acknowledgments(controller), [1, 1, 0])
    }

    @MainActor
    func testReceiveSequenceIsSharedAcrossTablesAndCommandACKsDoNotAdvanceIt() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 50, 0]))
        controller.setNoiseControl(.anc)
        let command = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - command.sequence, payload: []))
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 60, 0]))
        XCTAssertEqual(controller.batteryLevel, 50)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0E, sequence: 1, payload: [0xFF]))
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x25, 0, 60, 0]))
        XCTAssertEqual(controller.batteryLevel, 50)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 60, 0]))
        XCTAssertEqual(controller.batteryLevel, 60)
        XCTAssertEqual(acknowledgments(controller), [1, 1, 0, 0, 1])
    }

    @MainActor
    func testCoalescedDuplicateFramesApplyOncePerAlternatingSequence() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        var observations = 0
        let observation = controller.$batteries.dropFirst().sink { _ in observations += 1 }
        defer { observation.cancel() }
        let first = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 50, 0])
        let second = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x25, 0, 60, 0])
        controller.simulateProtocolData(first + first + second + second)
        XCTAssertEqual(controller.batteryLevel, 60)
        XCTAssertEqual(observations, 2)
        XCTAssertEqual(acknowledgments(controller), [1, 1, 0, 0])
    }

    @MainActor
    func testDuplicateSuppressionPrecedesDeferredAcknowledgmentCompletion() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WH-1000XM3", galleryModel: .whXM3)
        XCTAssertEqual(controller.legacySurround.presetID, 0)
        controller.defersSimulatedWrites = true
        let first = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x49, 1, 1])
        let duplicate = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x49, 1, 2])
        controller.simulateProtocolData(first + duplicate)
        XCTAssertEqual(controller.legacySurround.presetID, 0)
        XCTAssertTrue(acknowledgments(controller).isEmpty)
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.legacySurround.presetID, 1)
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.legacySurround.presetID, 1)
        XCTAssertEqual(acknowledgments(controller), [1, 1])
        controller.defersSimulatedWrites = false
    }

    @MainActor
    func testRejectedWireFramesDoNotConsumeTheNextReceiveSequence() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 50, 0]))
        var badChecksum = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x25, 0, 60, 0])
        badChecksum[badChecksum.count - 2] ^= 1
        let badSequence = SonyFrameCodec.encode(type: 0x0C, sequence: 255, payload: [0x25, 0, 60, 0])
        let unknownType = SonyFrameCodec.encode(type: 0x0D, sequence: 1, payload: [0x25, 0, 60, 0])
        controller.simulateProtocolData(badSequence + badChecksum + unknownType)
        XCTAssertEqual(controller.batteryLevel, 50)
        XCTAssertEqual(acknowledgments(controller), [1])
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x25, 0, 60, 0]))
        XCTAssertEqual(controller.batteryLevel, 60)
        XCTAssertEqual(acknowledgments(controller), [1, 0])
    }

    @MainActor
    func testReceiveSequenceSurvivesSameChannelHandshakeAndResetsForFreshTransport() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 50, 0]))
        controller.simulateSameTransportHandshake()
        XCTAssertEqual(controller.linkState, .handshaking)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 60, 0]))
        XCTAssertEqual(controller.batteryLevel, 50)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x25, 0, 70, 0]))
        XCTAssertEqual(controller.batteryLevel, 70)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x25, 0, 80, 0]), beginConnection: true)
        XCTAssertEqual(controller.batteryLevel, 80)
        XCTAssertEqual(controller.linkState, .handshaking)
    }

    @MainActor
    func testOnlyValidTable1ProtocolInformationBypassesDuplicateSequenceSuppression() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 50, 0]))
        controller.simulateSameTransportHandshake()
        let protocolInfo: [UInt8] = [0x01, 0, 3, 0, 0x30, 0x18, 0, 1]
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x01, 0, 3]))
        XCTAssertNil(controller.protocolInformation)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0E, sequence: 0, payload: protocolInfo))
        XCTAssertNil(controller.protocolInformation)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: protocolInfo))
        XCTAssertEqual(controller.protocolInformation?.generation, .v2)
        XCTAssertEqual(controller.protocolInformation?.version, 0x03003018)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(acknowledgments(controller), [1, 1, 1, 1])
    }

    @MainActor
    func testV1ProtocolInformationRequiresTheNextReceiveSequence() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0, 50, 0]))
        controller.simulateSameTransportHandshake()
        let protocolInfo: [UInt8] = [0x01, 0, 0x40, 0]
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: protocolInfo))
        XCTAssertNil(controller.protocolInformation)
        XCTAssertEqual(controller.linkState, .handshaking)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: protocolInfo))
        XCTAssertEqual(controller.protocolInformation?.generation, .v1)
        XCTAssertEqual(controller.protocolInformation?.version, 0x4000)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(acknowledgments(controller), [1, 1, 0])
    }

    @MainActor
    private func makeController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5")
        return controller
    }

    @MainActor
    private func acknowledgments(_ controller: SonyHeadphonesController) -> [UInt8] {
        controller.simulatedTransmittedFrames.filter { $0.type == 1 }.map(\.sequence)
    }
}

final class SonyControlFaultSequenceTests: XCTestCase {
    private typealias Profile = (name: String, generation: SonyProtocolInfo.Generation, inquiry: UInt8?, ble: Bool)
    private typealias Discovery = (query: [UInt8], type: UInt8, reply: [UInt8])

    @MainActor
    func testSeededOptionalFaultSequencesPreserveConfirmedControlsAcrossRecognizedModels() throws {
        let suite = "dev.baglayan.Acouplet.control-faults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = SonyDeviceModel.allCases.filter { $0 != .unknown }
        var coverage = Array(repeating: 0, count: 12)
        for (index, model) in models.enumerated() {
            let profile = profiles[index % profiles.count]
            let seed = UInt64(index + 1) &* 0x9E3779B97F4A7C15
            var random = Generator(state: seed)
            let controller = negotiate(model: model, profile: profile, defaults: defaults)
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            let identity = controller.deviceInformation
            let functions = controller.supportedFunctions
            let functions2 = controller.supportedFunctions2
            let mode = controller.noiseControlMode
            let transmitted = controller.simulatedTransmittedFrames.count
            var sequence: UInt8 = 0
            var previous: Data?
            var battery = 70
            for step in 0..<96 {
                let action = step < coverage.count ? step : random.next(coverage.count)
                coverage[action] += 1
                let context = "\(model.name), \(profile.name), seed \(String(seed, radix: 16)), step \(step), action \(action)"
                let acknowledgmentsBefore = ackCount(controller)
                var expectedACKs = 0
                switch action {
                case 0:
                    let payload = malformedOptionalReplies[random.next(malformedOptionalReplies.count)]
                    let type: UInt8 = random.next(2) == 0 ? 0x0C : 0x0E
                    previous = send(payload, type: type, sequence: &sequence, to: controller)
                    expectedACKs = 1
                case 1:
                    if let previous {
                        controller.simulateProtocolData(previous)
                        expectedACKs = 1
                    }
                case 2:
                    var packet = SonyFrameCodec.encode(type: 0x0C, sequence: sequence,
                        payload: batteryPayload(level: 99, model: model, profile: profile))
                    packet[packet.count - 2] ^= 1
                    controller.simulateProtocolData(packet)
                case 3:
                    battery = 25 + random.next(65)
                    let packet = SonyFrameCodec.encode(type: 0x0C, sequence: sequence,
                        payload: batteryPayload(level: battery, model: model, profile: profile))
                    var offset = 0
                    while offset < packet.count {
                        let length = min(1 + random.next(7), packet.count - offset)
                        controller.simulateProtocolData(packet.subdata(in: offset..<(offset + length)))
                        offset += length
                    }
                    sequence = 1 - sequence
                    previous = packet
                    expectedACKs = 1
                case 4:
                    let type: UInt8 = [0, 2, 0x0D, 0xFF][random.next(4)]
                    controller.simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: sequence,
                        payload: batteryPayload(level: 99, model: model, profile: profile)))
                case 5:
                    previous = send(batteryPayload(level: 99, model: model, profile: profile), type: 0x0E,
                        sequence: &sequence, to: controller)
                    expectedACKs = 1
                case 6:
                    let read = discovery(model: .whCH720N, profile: profile)[random.next(profile.generation == .v1 ? 2 : 3)]
                    let reply: [UInt8] = read.type == 0x0E ? [0x07, 0, 1, 0x42, 0]
                        : read.query == [0x04, 3] ? [0x05, 3, 0x20, 3] : read.reply
                    previous = send(reply, type: read.type, sequence: &sequence, to: controller)
                    expectedACKs = 1
                case 7:
                    battery = 25 + random.next(65)
                    previous = send(batteryPayload(level: battery, model: model, profile: profile),
                        sequence: &sequence, to: controller)
                    expectedACKs = 1
                case 8:
                    let payload = [UInt8(0xFE)] + (0..<random.next(32)).map { _ in UInt8(random.next(256)) }
                    previous = send(payload, type: random.next(2) == 0 ? 0x0C : 0x0E,
                        sequence: &sequence, to: controller)
                    expectedACKs = 1
                case 9:
                    battery = 25 + random.next(65)
                    let packet = SonyFrameCodec.encode(type: 0x0C, sequence: sequence,
                        payload: batteryPayload(level: battery, model: model, profile: profile))
                    let otherTable = SonyFrameCodec.encode(type: 0x0E, sequence: sequence,
                        payload: batteryPayload(level: 99, model: model, profile: profile))
                    controller.simulateProtocolData(packet + packet + otherTable)
                    sequence = 1 - sequence
                    previous = packet
                    expectedACKs = 3
                case 10:
                    controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: sequence,
                        payload: batteryPayload(level: 99, model: model, profile: profile)), session: session - 1)
                default:
                    controller.simulateAutomaticRefresh()
                    drain(controller)
                }
                XCTAssertEqual(ackCount(controller) - acknowledgmentsBefore, expectedACKs, context)
                XCTAssertTrue(controller.isReady, context)
                XCTAssertEqual(controller.simulatedControlSession, session, context)
                XCTAssertEqual(controller.protocolInformation?.generation, profile.generation, context)
                XCTAssertEqual(controller.deviceInformation, identity, context)
                XCTAssertEqual(controller.supportedFunctions, functions, context)
                XCTAssertEqual(controller.supportedFunctions2, functions2, context)
                XCTAssertEqual(controller.noiseControlMode, mode, context)
                XCTAssertEqual(controller.batteryLevel, battery, context)
                XCTAssertTrue(controller.pendingChanges.isEmpty, context)
            }
            let setters: Set<UInt8> = [0x28, 0x48, 0x54, 0x58, 0x68, 0xA4, 0xA8, 0xD8, 0xE8, 0xF8]
            XCTAssertFalse(controller.simulatedTransmittedFrames.dropFirst(transmitted).contains {
                $0.type != 1 && $0.payload.first.map(setters.contains) == true
            }, "Unsolicited write for \(model.name), \(profile.name), seed \(String(seed, radix: 16))")
        }
        XCTAssertTrue(coverage.allSatisfy { $0 > 0 })
    }

    @MainActor
    func testSeededConcurrentDiscoveryFaultsKeepRecoveryBoundedAndRequireUnambiguousTransport() async throws {
        let suite = "dev.baglayan.Acouplet.discovery-faults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for profile in profiles {
            for seed: UInt64 in [1, 0x534F4E59, 0xC0FFEE, 0xFFFFFFFF] {
                var random = Generator(state: seed)
                let model = profile.inquiry == 0x19 ? SonyDeviceModel.wfXM5 : .whXM3
                let controller = negotiate(model: model, profile: profile, defaults: defaults, resolveDiscovery: false)
                defer { controller.simulateControlLoss() }
                let reads = discovery(model: model, profile: profile)
                let session = controller.simulatedControlSession
                var sequence: UInt8 = 0
                var previous: Data?
                for step in 0..<64 {
                    let index = step < reads.count ? step : random.next(reads.count)
                    let read = reads[index]
                    let action = step < reads.count ? 0 : random.next(6)
                    let context = "\(profile.name), seed \(String(seed, radix: 16)), step \(step), action \(action), query \(read.query)"
                    switch action {
                    case 0:
                        controller.simulateDiscoveryReadTimeout(read.query, type: read.type)
                        for _ in 0..<8 { await Task.yield() }
                    case 1:
                        previous = send(read.reply, type: read.type, sequence: &sequence, to: controller)
                    case 2:
                        previous = send(Array(read.reply.prefix(2)), type: read.type, sequence: &sequence, to: controller)
                    case 3:
                        if let previous { controller.simulateProtocolData(previous) }
                    case 4:
                        controller.simulateAutomaticRefresh()
                    default:
                        drain(controller)
                    }
                    XCTAssertTrue(controller.isReady, context)
                    XCTAssertEqual(controller.simulatedControlSession, session, context)
                    XCTAssertTrue(controller.pendingChanges.isEmpty, context)
                    for candidate in reads {
                        XCTAssertLessThanOrEqual(transmissionCount(candidate, on: controller), 2, context)
                    }
                }
                for read in reads { _ = send(read.reply, type: read.type, sequence: &sequence, to: controller) }
                drain(controller)
                for _ in 0..<15 {
                    controller.simulateAutomaticRefresh()
                    drain(controller)
                }
                XCTAssertEqual(controller.deviceInformation.model, model)
                XCTAssertEqual(controller.deviceInformation.series, 0x30)
                XCTAssertTrue(controller.hasCurrentTable2Capabilities)
                for read in reads {
                    XCTAssertLessThanOrEqual(transmissionCount(read, on: controller), 2)
                    XCTAssertNil(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type))
                }
                let retried = reads.contains { transmissionCount($0, on: controller) > 1 }
                controller.simulateSameTransportHandshake()
                XCTAssertEqual(controller.linkState, retried ? .disconnected : .handshaking,
                    "\(profile.name), seed \(String(seed, radix: 16))")
            }
        }
    }

    @MainActor
    func testSeededStaleDiscoveryCallbacksAndDeferredWritesCannotMutateReplacementSessions() async throws {
        let suite = "dev.baglayan.Acouplet.stale-faults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for profile in profiles {
            for seed: UInt64 in [7, 41, 0x534F4E59, 0xFFFFFFFF] {
                var random = Generator(state: seed)
                let controller = negotiate(model: .whXM3, profile: profile, defaults: defaults, resolveDiscovery: false)
                defer { controller.simulateControlLoss() }
                let oldSession = controller.simulatedControlSession
                let oldReads = discovery(model: .whXM3, profile: profile)
                let oldTimeouts = try oldReads.map {
                    try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutWork($0.query, type: $0.type))
                }
                controller.defersSimulatedWrites = true
                let pending = oldReads[random.next(oldReads.count)]
                controller.simulateDiscoveryReadTimeout(pending.query, type: pending.type)
                for _ in 0..<8 { await Task.yield() }
                let retiredFrame = try XCTUnwrap(controller.simulatedPendingFrame)
                controller.defersSimulatedWrites = false
                negotiate(controller, model: .wfXM5, profile: profile, resolveDiscovery: false)
                let replacement = controller.simulatedControlSession
                let reads = discovery(model: .wfXM5, profile: profile)
                let timeoutIDs = try reads.map {
                    try XCTUnwrap(controller.simulatedDiscoveryReadTimeoutID($0.query, type: $0.type))
                }
                let transmitted = controller.simulatedTransmittedFrames.count
                let replacementBattery = controller.batteries
                var retiredWriteCompleted = false
                for step in 0..<48 {
                    let index = random.next(oldReads.count)
                    switch random.next(4) {
                    case 0: oldTimeouts[index].perform()
                    case 1:
                        controller.completeSimulatedWrite()
                        retiredWriteCompleted = true
                    case 2:
                        controller.simulateProtocolData(SonyFrameCodec.encode(type: oldReads[index].type,
                            sequence: UInt8(random.next(2)), payload: oldReads[index].reply), session: oldSession)
                    default:
                        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: UInt8(random.next(2)), payload: []),
                            session: oldSession)
                    }
                    for _ in 0..<4 { await Task.yield() }
                    let context = "\(profile.name), seed \(String(seed, radix: 16)), step \(step)"
                    XCTAssertTrue(controller.isReady, context)
                    XCTAssertEqual(controller.simulatedControlSession, replacement, context)
                    XCTAssertNil(controller.deviceInformation.modelName, context)
                    XCTAssertNil(controller.deviceInformation.series, context)
                    XCTAssertTrue(controller.supportedFunctions2.isEmpty, context)
                    XCTAssertEqual(controller.batteries, replacementBattery, context)
                    XCTAssertNil(controller.simulatedPendingFrame, context)
                    XCTAssertEqual(Array(controller.simulatedTransmittedFrames.dropFirst(transmitted)),
                        retiredWriteCompleted ? [retiredFrame] : [], context)
                    for (index, read) in reads.enumerated() {
                        XCTAssertEqual(controller.simulatedDiscoveryReadTimeoutID(read.query, type: read.type), timeoutIDs[index], context)
                    }
                }
                for read in reads { controller.simulateProtocolMessage(read.reply, type: read.type) }
                XCTAssertEqual(controller.deviceInformation.model, .wfXM5)
                XCTAssertEqual(controller.deviceInformation.series, 0x30)
                XCTAssertTrue(controller.hasCurrentTable2Capabilities)
            }
        }
    }

    private var profiles: [Profile] {
        [
            ("V1 ANC", .v1, 2, false), ("V1 without ANC", .v1, nil, false),
            ("V2 inquiry17 Classic", .v2, 0x17, false), ("V2 inquiry19 Classic", .v2, 0x19, false),
            ("V2 without ANC", .v2, nil, false), ("V2 inquiry17 BLE", .v2, 0x17, true),
        ]
    }

    private var malformedOptionalReplies: [[UInt8]] {
        [[0x05, 1, 8, 0x62, 0x61, 0x64], [0x05, 3, 0], [0x07, 0, 1], [0x07, 1, 0],
         [0x41, 1], [0x43, 1], [0x47, 1], [0x51, 3], [0x57, 3, 0, 0],
         [0xF1, 3], [0xF3, 3], [0xF7, 3], [0xD1, 0xD1], [0xD3, 0xD1], [0x37, 2, 1], [0xE1, 1]]
    }

    @MainActor
    private func negotiate(model: SonyDeviceModel, profile: Profile, defaults: UserDefaults,
                           resolveDiscovery: Bool = true) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        negotiate(controller, model: model, profile: profile, resolveDiscovery: resolveDiscovery)
        return controller
    }

    @MainActor
    private func negotiate(_ controller: SonyHeadphonesController, model: SonyDeviceModel, profile: Profile,
                           resolveDiscovery: Bool) {
        controller.simulateDeviceConnection(named: model.name, controlBusy: true)
        let protocolInfo: [UInt8] = profile.generation == .v1 ? [0x01, 0, 0x40, 0] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 0]
        controller.simulateProtocolMessage(protocolInfo, beginConnection: true, expectedBLEHash: profile.ble ? "ABCDEF12" : nil)
        drain(controller)
        if resolveDiscovery {
            for read in discovery(model: model, profile: profile) where read.type == 0x0C {
                controller.simulateProtocolMessage(read.reply)
            }
        }
        var functions: [UInt8] = profile.generation == .v1
            ? (model.isEarbuds ? [0x15, 0x18] : [0x11]) : (model.isEarbuds ? [0x21, 0x22] : [0x20])
        if let inquiry = profile.inquiry { functions.append(profile.generation == .v1 ? 0x62 : inquiry == 0x17 ? 0x6B : 0x6D) }
        if profile.ble { functions.append(0x14) }
        let encodedFunctions = profile.generation == .v1 ? functions : functions.flatMap { [$0, 0] }
        controller.simulateProtocolMessage([0x07, 0, UInt8(functions.count)] + encodedFunctions)
        drain(controller)
        if profile.ble {
            controller.simulateProtocolMessage([0x11, 4] + Array("00:11:22:33:44:55ABCDEF12".utf8))
            drain(controller)
        }
        if let inquiry = profile.inquiry {
            let capability: [UInt8] = profile.generation == .v1
                ? [0x61, 2, 0, 2, 1, 2, 0, 20, 1, 20] : [0x61, inquiry, 2, 0, 1, 20, 1, 1, 1, 20, 1]
            controller.simulateProtocolMessage(capability)
            controller.simulateProtocolMessage([0x63, inquiry, 0])
            drain(controller)
            let state: [UInt8] = profile.generation == .v1
                ? [0x67, 2, 1, 0, 0, 1, 0, 12]
                : [0x67, inquiry, 1, 1, 1, 0, 12] + (inquiry == 0x19 ? [0, 0] : [])
            controller.simulateProtocolMessage(state)
            drain(controller)
        }
        if resolveDiscovery, profile.generation == .v2 { controller.simulateProtocolMessage([0x07, 0, 0], type: 0x0E) }
        controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
        controller.simulateProtocolMessage(batteryPayload(level: 70, model: model, profile: profile))
        drain(controller)
        for sequence: UInt8 in [0, 1] {
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: sequence, payload: [0xFE]))
        }
        XCTAssertTrue(controller.isReady, "\(model.name), \(profile.name)")
        XCTAssertEqual(controller.batteryLevel, 70)
    }

    private func discovery(model: SonyDeviceModel, profile: Profile) -> [Discovery] {
        let name = Array(model.name.utf8)
        let identity: [Discovery] = [([0x04, 1], 0x0C, [0x05, 1, UInt8(name.count)] + name),
                                   ([0x04, 3], 0x0C, [0x05, 3, 0x30, 0])]
        return identity + (profile.generation == .v2 ? [([0x06, 0], 0x0E, [0x07, 0, 0])] : [])
    }

    private func batteryPayload(level: Int, model: SonyDeviceModel, profile: Profile) -> [UInt8] {
        let command: UInt8 = profile.generation == .v1 ? 0x13 : 0x25
        return model.isEarbuds ? [command, 1, UInt8(level), 0, UInt8(level), 0] : [command, 0, UInt8(level), 0]
    }

    @MainActor
    @discardableResult
    private func send(_ payload: [UInt8], type: UInt8 = 0x0C, sequence: inout UInt8,
                      to controller: SonyHeadphonesController) -> Data {
        let packet = SonyFrameCodec.encode(type: type, sequence: sequence, payload: payload)
        controller.simulateProtocolData(packet)
        sequence = 1 - sequence
        return packet
    }

    @MainActor
    private func drain(_ controller: SonyHeadphonesController) {
        for _ in 0..<128 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("Fault sequence exceeded the command queue bound")
    }

    @MainActor
    private func ackCount(_ controller: SonyHeadphonesController) -> Int {
        controller.simulatedTransmittedFrames.filter { $0.type == 1 }.count
    }

    @MainActor
    private func transmissionCount(_ read: Discovery, on controller: SonyHeadphonesController) -> Int {
        controller.simulatedTransmittedFrames.filter { $0.type == read.type && $0.payload == read.query }.count
    }

    private struct Generator {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(bound))
        }
    }
}

extension EqualizerSettings {
    var sonySetPayload: [UInt8] {
        precondition(layout == SonyEqualizerBand.legacy && levelSteps == 21 && values.count == 6)
        return [0x58, 0x00, EqualizerPreset.manual.rawValue, 0x06]
            + values.map { UInt8(max(-10, min(10, $0)) + 10) }
    }
}
