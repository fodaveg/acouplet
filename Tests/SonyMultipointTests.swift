import XCTest
import AppKit
@testable import Acouplet

final class SonyMultipointTests: XCTestCase {
    func testSourceSymbolsRecognizeAppleFamiliesWithoutDependingOnOwnerNames() {
        let cases: [(String, UInt32, String)] = [
            ("Work MacBook Pro", 0x2A4104, "macbook"), ("MacBook Air", 0x010C, "macbook"),
            ("MacBook", 0, "macbook"), ("PowerBook", 0x010C, "macbook"), ("iBook", 0, "macbook"),
            ("Office iMac", 0x0104, "desktopcomputer"), ("iMac Pro", 0, "desktopcomputer"),
            ("Mac mini", 0x0104, "macmini"), ("Mac Studio", 0x0104, "macstudio"),
            ("Mac Pro", 0x0104, "desktopcomputer"), ("Power Mac", 0x0104, "desktopcomputer"),
            ("Xserve", 0x0108, "server.rack"), ("Morgan’s iPhone", 0x5A020C, "iphone"),
            ("IPAD Pro", 0x020C, "ipad"), ("iPad mini", 0x0114, "ipad"),
            ("iPod touch", 0x041C, "ipodtouch"), ("iPod nano", 0x041C, "ipodtouch"),
            ("Apple Watch Ultra", 0x020C, "applewatch"), ("Apple Watch SE", 0x0704, "applewatch"),
            ("Living room Apple TV", 0x0424, "appletv"), ("Apple Vision Pro", 0x0100, "visionpro"),
            ("MacMini", 0xFFFFFF, "macmini")
        ]
        for (name, deviceClass, symbol) in cases {
            let device = SonyMultipointDevice(address: firstAddress, connectionID: 1, classOfDevice: deviceClass, name: name)
            XCTAssertEqual(device.symbolName, symbol, name)
            XCTAssertNotNil(NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil), symbol)
        }
    }

    func testSourceSymbolsUseExplicitMacProAndIPhoneGenerations() {
        let cases: [(String, UInt32, String)] = [
            ("Mac Pro (2006)", 0x0104, "macpro.gen1"), ("Mac Pro (Early 2008)", 0, "macpro.gen1"),
            ("Mac Pro (Mid 2012)", 0x0104, "macpro.gen1"), ("Mac Pro (Late 2013)", 0, "macpro.gen2"),
            ("Mac Pro (2019)", 0x0104, "macpro.gen3"), ("Mac Pro 2023", 0, "macpro.gen3"),
            ("Mac Pro (Rack, 2023)", 0x0108, "macpro.gen3.server"), ("Mac Pro 2027", 0, "desktopcomputer"),
            ("Mac Pro 2013 2023", 0, "desktopcomputer"), ("iPhone 3GS", 0x020C, "iphone.gen1"),
            ("iPhone 6s Plus", 0, "iphone.gen1"), ("iPhone 8 Plus", 0, "iphone.gen1"),
            ("iPhone SE", 0, "iphone.gen1"), ("iPhone SE 2", 0, "iphone.gen1"),
            ("iPhone SE (3rd generation)", 0, "iphone.gen1"), ("iPhone SE3", 0, "iphone.gen1"),
            ("iPhone SE (2022)", 0, "iphone.gen1"), ("iPhone SE 4", 0, "iphone"),
            ("iPhone X", 0, "iphone.gen2"), ("iPhone XR", 0, "iphone.gen2"),
            ("iPhone XS Max", 0, "iphone.gen2"), ("iPhone 11 Pro", 0, "iphone.gen2"),
            ("iPhone 12 mini", 0, "iphone.gen2"), ("iPhone 13 Pro Max", 0, "iphone.gen2"),
            ("iPhone 14 Plus", 0, "iphone.gen2"), ("iPhone 14 Pro Max", 0, "iphone.gen3"),
            ("iPhone 15", 0, "iphone.gen3"), ("iPhone 16e", 0, "iphone.gen2"),
            ("iPhone 16 Pro", 0, "iphone.gen3"), ("iPhone 17e", 0, "iphone.gen2"),
            ("iPhone 17 e", 0, "iphone.gen2"), ("iPhone 17 Pro", 0, "iphone.gen3"),
            ("iPhone Air", 0, "iphone.gen3"), ("iPhone 18 Pro Max", 0, "iphone.gen3"),
            ("iPhone 18", 0, "iphone"), ("iPhone 99", 0, "iphone"),
            ("iPhone 16e speaker", 0x0414, "hifispeaker"), ("Mac Pro 2013 phone", 0x020C, "smartphone")
        ]
        for (name, deviceClass, symbol) in cases {
            let device = SonyMultipointDevice(address: firstAddress, connectionID: 1, classOfDevice: deviceClass, name: name)
            XCTAssertEqual(device.symbolName, symbol, name)
            XCTAssertNotNil(NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil), symbol)
        }
    }

    func testSourceSymbolsRetainReportedCategoryForRenamedAndConflictingDevices() {
        let cases: [(String, UInt32, String)] = [
            ("Work", 0x2A410C, "laptopcomputer"), ("Study", 0x0104, "desktopcomputer"),
            ("Server", 0x0108, "server.rack"), ("Reading", 0x0114, "rectangle.portrait"),
            ("Personal", 0x5A020C, "smartphone"), ("Wrist", 0x0704, "applewatch"),
            ("TV", 0x043C, "tv"), ("Player", 0x041C, "hifispeaker"),
            ("Mac mini", 0x020C, "smartphone"), ("iPhone", 0x0104, "desktopcomputer"),
            ("iPhone speaker", 0x0414, "hifispeaker"), ("Apple TV", 0x020C, "smartphone"),
            ("MacBook gamepad", 0x0508, "wave.3.right")
        ]
        for (name, deviceClass, symbol) in cases {
            let device = SonyMultipointDevice(address: firstAddress, connectionID: 0, classOfDevice: deviceClass, name: name)
            XCTAssertEqual(device.symbolName, symbol, name)
            XCTAssertNotNil(NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil), symbol)
        }
    }

    func testSourceSymbolsDoNotMatchProductNamesInsideOtherWords() {
        for name in ["Pineapple Watch", "Notiphone", "Macbookish", "Microphone", "iPod classic", "iPod shuffle", "HomePod", "Personal"] {
            let device = SonyMultipointDevice(address: firstAddress, connectionID: 0, classOfDevice: 0xFFFFFF, name: name)
            XCTAssertEqual(device.symbolName, "wave.3.right", name)
        }
        for (name, symbol) in [("Phone", "smartphone"), ("Tablet", "rectangle.portrait"), ("Laptop", "laptopcomputer"), ("TV", "tv")] {
            let device = SonyMultipointDevice(address: firstAddress, connectionID: 0, classOfDevice: 0, name: name)
            XCTAssertEqual(device.symbolName, symbol, name)
        }
    }

    @MainActor
    func testSourceTitlesDisambiguateNamesAndCollidingAddressSuffixes() {
        let first = SonyMultipointDevice(address: "02:00:00:00:00:01", connectionID: 1, classOfDevice: 0, name: "MacBook Pro")
        let second = SonyMultipointDevice(address: "02:00:00:00:00:02", connectionID: 2, classOfDevice: 0, name: "macbook pro")
        let third = SonyMultipointDevice(address: "03:00:00:00:00:01", connectionID: 3, classOfDevice: 0, name: "MacBook Pro")
        XCTAssertEqual(MultipointSourcePicker.title(for: first, among: [first]), "MacBook Pro")
        XCTAssertEqual(MultipointSourcePicker.title(for: first, among: [first, second]), "MacBook Pro · 00:01")
        XCTAssertEqual(MultipointSourcePicker.title(for: second, among: [first, second]), "macbook pro · 00:02")
        XCTAssertEqual(MultipointSourcePicker.title(for: first, among: [first, second, third]), "MacBook Pro · 02:00:00:00:00:01")
        XCTAssertEqual(MultipointSourcePicker.title(for: third, among: [first, second, third]), "MacBook Pro · 03:00:00:00:00:01")
    }

    func testOnlyNegotiatedInventoryAndSourceFunctionsProduceReadQueries() {
        for functions: Set<UInt8> in [[], [0x30], [0x34], [0x42, 0x47]] {
            var multipoint = SonyMultipoint(supportedFunctions: functions)
            XCTAssertTrue(multipoint.queryPayloads.isEmpty)
            XCTAssertFalse(multipoint.update(capturedInventory))
            XCTAssertFalse(multipoint.update([0x37, 1, 1]))
            XCTAssertNil(multipoint.sourceSwitchPayload(address: firstAddress))
        }
        for function: UInt8 in [0x32, 0x33] {
            var multipoint = SonyMultipoint(supportedFunctions: [function])
            XCTAssertEqual(multipoint.queryPayloads, [[0x30, 2], [0x32, 2], [0x36, 2]])
            XCTAssertTrue(multipoint.update(capturedInventory))
            XCTAssertFalse(multipoint.update([0x37, 1, 1]))
            XCTAssertTrue(multipoint.update([0x31, 2, 8, 2, 0]))
            XCTAssertEqual(multipoint.maxPairedDevices, 8)
            XCTAssertEqual(multipoint.maxConnectedDevices, 2)
            XCTAssertEqual(multipoint.multipleConnectionFileTransfer, true)
            XCTAssertEqual(multipoint.queryPayloads, [[0x32, 2], [0x36, 2]])
        }
        var sourceOnly = SonyMultipoint(supportedFunctions: [0x31])
        XCTAssertEqual(sourceOnly.queryPayloads, [[0x36, 1]])
        XCTAssertTrue(sourceOnly.update([0x37, 1, 1]))
        XCTAssertFalse(sourceOnly.update(capturedInventory))
        XCTAssertNil(sourceOnly.keepingSetPayload(true))
    }

    func testCapturedSnapshotRetainsIDsBigEndianClassNamesAndIndependentKeeping() throws {
        var multipoint = readyMultipoint()
        XCTAssertEqual(multipoint.devices.count, 8)
        XCTAssertEqual(multipoint.devices.map(\.connectionID), [1, 2, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(multipoint.devices.map(\.name), ["Test Laptop A", "Test Phone", "Test Desktop PC", "Test Mac", "Test Laptop A", "Test", "Test Mac", "Test Laptop B"])
        let first = try XCTUnwrap(multipoint.devices.first)
        XCTAssertEqual(first.address, firstAddress)
        XCTAssertEqual(first.classOfDevice, 0x2A4104)
        XCTAssertEqual(multipoint.devices[1].classOfDevice, 0x5A020C)
        XCTAssertEqual(multipoint.devices[2].classOfDevice, 0xFFFFFF)
        XCTAssertEqual(multipoint.selectedSource, first)
        XCTAssertEqual(multipoint.keeping, false)
        XCTAssertFalse(multipoint.inventoryIsStale)
        XCTAssertTrue(multipoint.update([0x39, 1, 1, 2]))
        XCTAssertEqual(multipoint.lastKeepingResult, .callInProgress)
        XCTAssertEqual(multipoint.keeping, false)
        XCTAssertEqual(multipoint.selectedSource, first)
        XCTAssertNil(multipoint.lastSourceResult)
        var updated = capturedInventory
        updated[0] = 0x39
        updated[updated.count - 1] = 2
        XCTAssertTrue(multipoint.update(updated))
        XCTAssertEqual(multipoint.selectedSource?.address, secondAddress)
        for identifier: UInt8 in [0, 3, 0xFF] {
            updated[updated.count - 1] = identifier
            XCTAssertTrue(multipoint.update(updated))
            XCTAssertEqual(multipoint.inventory?.playbackRightID, identifier)
            XCTAssertNil(multipoint.selectedSource)
        }
        XCTAssertTrue(multipoint.update([0x37, 2, 0, 0]))
        XCTAssertEqual(multipoint.devices, [])
        XCTAssertNil(multipoint.selectedSource)
    }

    func testMalformedSnapshotsAreAtomicAndMarkRetainedInventoryStaleUntilValidRead() {
        for length in 0..<capturedInventory.count {
            var multipoint = readyMultipoint()
            let inventory = multipoint.inventory
            XCTAssertFalse(multipoint.update(Array(capturedInventory.prefix(length))), "Length \(length)")
            XCTAssertEqual(multipoint.inventory, inventory)
            XCTAssertEqual(multipoint.inventoryIsStale, length >= 2)
            if length >= 2 {
                XCTAssertNil(multipoint.sourceSwitchPayload(address: firstAddress))
                XCTAssertNil(multipoint.keepingSetPayload(false))
                XCTAssertNil(multipoint.peripheralActionPayload(.disconnect, address: firstAddress))
            }
            XCTAssertTrue(multipoint.update(capturedInventory))
            XCTAssertFalse(multipoint.inventoryIsStale)
        }
        var invalidPackets = [capturedInventory + [0], oneDevicePacket(name: []), oneDevicePacket(name: [0xC3, 0x28]),
                              oneDevicePacket(name: Array(repeating: 0x41, count: 129))]
        for (index, value): (Int, UInt8) in [(2, 7), (2, 9), (3, 0x47), (5, 0x2D), (24, 0), (24, 128), (55, 1)] {
            var invalid = capturedInventory
            invalid[index] = value
            invalidPackets.append(invalid)
        }
        var duplicateAddress = capturedInventory
        duplicateAddress.replaceSubrange(38..<55, with: duplicateAddress[3..<20])
        invalidPackets.append(duplicateAddress)
        for payload in invalidPackets {
            var multipoint = readyMultipoint()
            let prior = multipoint.inventory
            XCTAssertFalse(multipoint.update(payload))
            XCTAssertEqual(multipoint.inventory, prior)
            XCTAssertTrue(multipoint.inventoryIsStale)
        }
    }

    func testUTF8ByteLengthsAndUnsignedInventoryCounts() {
        var multipoint = SonyMultipoint(supportedFunctions: [0x32])
        for name in ["é", "耳機 🎧", String(repeating: "é", count: 64)] {
            XCTAssertTrue(multipoint.update(oneDevicePacket(name: Array(name.utf8))))
            XCTAssertEqual(multipoint.devices.first?.name, name)
            XCTAssertEqual(multipoint.devices.first?.classOfDevice, 0x010203)
        }
        var payload: [UInt8] = [0x37, 2, 128]
        for value in 0..<128 {
            let address = String(format: "00:00:00:00:00:%02X", value)
            payload += Array(address.utf8) + [0, 0, 0, 0, 1, 0x41]
        }
        payload.append(0)
        XCTAssertTrue(multipoint.update(payload))
        XCTAssertEqual(multipoint.devices.count, 128)
        XCTAssertNil(multipoint.selectedSource)
    }

    func testWritesRequireKnownAvailableFreshStateAndPreserveConfirmedValues() {
        var multipoint = SonyMultipoint(supportedFunctions: [0x31, 0x32])
        XCTAssertTrue(multipoint.update(capturedInventory))
        XCTAssertNil(multipoint.sourceSwitchPayload(address: secondAddress))
        XCTAssertTrue(multipoint.update([0x33, 2, 0, 0]))
        XCTAssertNil(multipoint.sourceSwitchPayload(address: secondAddress))
        XCTAssertTrue(multipoint.update([0x37, 1, 1]))
        let prior = multipoint
        XCTAssertEqual(multipoint.sourceSwitchPayload(address: secondAddress.lowercased()), [0x3C, 1] + Array(secondAddress.utf8))
        XCTAssertEqual(multipoint.keepingSetPayload(true), [0x38, 1, 0])
        XCTAssertEqual(multipoint.keepingSetPayload(false), [0x38, 1, 1])
        XCTAssertEqual(multipoint, prior)
        for address in ["00:00:00:00:00:00", "02:00:00:00:00:A3", "02-00-00-00-00-A2", "invalid", "02:00:00:00:00:A2 "] {
            XCTAssertNil(multipoint.sourceSwitchPayload(address: address))
        }
        for status: [UInt8] in [[0, 1], [0, 2], [2, 0], [0xFF, 0]] {
            XCTAssertTrue(multipoint.update([0x35, 2] + status))
            XCTAssertNil(multipoint.sourceSwitchPayload(address: secondAddress))
            XCTAssertNil(multipoint.keepingSetPayload(false))
        }
        multipoint = readyMultipoint()
        XCTAssertTrue(multipoint.update([0x31, 2, 8, 2, 0xFF]))
        XCTAssertNil(multipoint.multipleConnectionFileTransfer)
        XCTAssertNotNil(multipoint.sourceSwitchPayload(address: secondAddress))
        XCTAssertTrue(multipoint.update([0x37, 1, 0xFF]))
        XCTAssertNil(multipoint.keeping)
        XCTAssertNil(multipoint.sourceSwitchPayload(address: secondAddress))
        XCTAssertNil(multipoint.keepingSetPayload(false))
        multipoint = readyMultipoint()
        var noSelectedSource = capturedInventory
        noSelectedSource[noSelectedSource.count - 1] = 0
        XCTAssertTrue(multipoint.update(noSelectedSource))
        XCTAssertNil(multipoint.keepingSetPayload(true))
        XCTAssertNotNil(multipoint.keepingSetPayload(false))
    }

    func testSourceResultsCorrelateAddressesWithoutChangingSelectedSourceAndResetWithSession() throws {
        var multipoint = readyMultipoint()
        let priorInventory = multipoint.inventory
        let results: [SonySourceControlResult] = [.success, .failure, .callInProgress, .a2dpNotConnected, .voiceAssistantPriority, .unknown(5)]
        for (index, result) in results.enumerated() {
            XCTAssertTrue(multipoint.update([0x3D, 1, UInt8(index)] + Array(secondAddress.lowercased().utf8)))
            let received = try XCTUnwrap(multipoint.lastSourceResult)
            XCTAssertEqual(received.result, result)
            XCTAssertEqual(received.address, secondAddress)
            XCTAssertTrue(received.matches(address: secondAddress.lowercased()))
            XCTAssertFalse(received.matches(address: firstAddress))
            XCTAssertFalse(received.matches(address: ""))
            XCTAssertEqual(multipoint.inventory, priorInventory)
        }
        XCTAssertTrue(multipoint.update([0x39, 1, 0, 2]))
        XCTAssertEqual(multipoint.keeping, true)
        XCTAssertEqual(multipoint.lastKeepingResult, .callInProgress)
        XCTAssertTrue(multipoint.update([0x39, 1, 0xFF, 0xFF]))
        XCTAssertNil(multipoint.keeping)
        XCTAssertEqual(multipoint.lastKeepingResult, .unknown(0xFF))
        multipoint = SonyMultipoint()
        XCTAssertNil(multipoint.inventory)
        XCTAssertNil(multipoint.keeping)
        XCTAssertNil(multipoint.lastKeepingResult)
        XCTAssertNil(multipoint.lastSourceResult)
        XCTAssertNil(multipoint.lastPeripheralResult)
        XCTAssertFalse(multipoint.update([0x3D, 1, 0] + Array(secondAddress.utf8)))
        XCTAssertTrue(multipoint.queryPayloads.isEmpty)
    }

    func testExplicitPeripheralActionsPairingAndResultFamilies() throws {
        var multipoint = readyMultipoint()
        let pairedAddress = "02:00:00:00:00:A3"
        XCTAssertNil(multipoint.peripheralActionPayload(.connect, address: pairedAddress))
        XCTAssertTrue(multipoint.update([0x31, 2, 8, 3, 0]))
        let prior = multipoint
        XCTAssertEqual(multipoint.peripheralActionPayload(.connect, address: pairedAddress), [0x3C, 2, 1] + Array(pairedAddress.utf8))
        XCTAssertEqual(multipoint.peripheralActionPayload(.disconnect, address: firstAddress), [0x3C, 2, 0] + Array(firstAddress.utf8))
        XCTAssertEqual(multipoint.peripheralActionPayload(.unpair, address: pairedAddress), [0x3C, 2, 2] + Array(pairedAddress.utf8))
        XCTAssertNil(multipoint.peripheralActionPayload(.connect, address: firstAddress))
        XCTAssertNil(multipoint.peripheralActionPayload(.disconnect, address: pairedAddress))
        XCTAssertNil(multipoint.peripheralActionPayload(.unpair, address: "00:00:00:00:00:00"))
        XCTAssertEqual(multipoint, prior)
        XCTAssertTrue(multipoint.update([0x35, 2, 1, 0]))
        XCTAssertEqual(multipoint.pairingMode, true)
        for action in [SonyPeripheralAction.disconnect, .connect, .unpair] {
            for offset: UInt8 in 0...3 {
                XCTAssertTrue(multipoint.update([0x3D, 2, action.rawValue, action.rawValue * 16 + offset] + Array(pairedAddress.utf8)))
                let received = try XCTUnwrap(multipoint.lastPeripheralResult)
                XCTAssertTrue(received.matches(action: action, address: pairedAddress.lowercased()))
                XCTAssertFalse(received.matches(action: action, address: firstAddress))
                XCTAssertTrue(received.result.matches(action: action))
                XCTAssertEqual(received.result.isSuccess, offset == 0)
                XCTAssertEqual(received.result.isInProgress, offset == 2)
                XCTAssertEqual(multipoint.inventory, prior.inventory)
            }
        }
        XCTAssertTrue(multipoint.update([0x3D, 2, 1, 0] + Array(pairedAddress.utf8)))
        XCTAssertFalse(multipoint.lastPeripheralResult?.result.matches(action: .connect) == true)
        XCTAssertTrue(multipoint.update([0x3D, 2, 0xFF, 0xFF] + Array(pairedAddress.utf8)))
        XCTAssertEqual(multipoint.lastPeripheralResult?.action, 0xFF)
        XCTAssertEqual(multipoint.lastPeripheralResult?.result, .unknown(0xFF))
        XCTAssertEqual(SonyPeripheralResult(rawValue: 0x30), .pairingSuccess)
        XCTAssertEqual(SonyPeripheralResult(rawValue: 0x31), .pairingFailure)
        XCTAssertEqual(SonyPeripheralResult(rawValue: 0x32), .pairingInProgress)
        XCTAssertEqual(SonyPeripheralResult(rawValue: 0x33), .pairingBusy)
    }

    func testMalformedFixedPacketsAndUnnegotiatedSubtypesPreserveState() {
        var multipoint = readyMultipoint()
        let validPackets: [[UInt8]] = [[0x31, 2, 8, 2, 0], [0x33, 2, 0, 0], [0x35, 2, 1, 0],
                                      [0x37, 1, 1], [0x39, 1, 1, 2],
                                      [0x3D, 1, 0] + Array(secondAddress.utf8),
                                      [0x3D, 2, 1, 0x10] + Array(secondAddress.utf8)]
        let prior = multipoint
        for packet in validPackets {
            for length in 0..<packet.count {
                XCTAssertFalse(multipoint.update(Array(packet.prefix(length))))
                XCTAssertEqual(multipoint, prior)
            }
            XCTAssertFalse(multipoint.update(packet + [0]))
            XCTAssertEqual(multipoint, prior)
        }
        for payload: [UInt8] in [[0x31, 1, 8, 2, 0], [0x33, 1, 0, 0], [0x37, 3, 0], [0x39, 3, 0, 0],
                                 [0x37, 0, 0, 0], [0x39, 0, 0, 0],
                                 [0x3D, 1, 0] + Array("02-00-00-00-00-A2".utf8),
                                 [0x3D, 2, 1, 0x10] + Array("02:00:00:00:00:GG".utf8)] {
            XCTAssertFalse(multipoint.update(payload))
            XCTAssertEqual(multipoint, prior)
        }
    }

    // MDR v1 `37 01` list: [address][state][name length][name] per entry plus a trailing 01, no class bytes.
    // Addresses and names are invented; the byte layout follows a WH-1000XM4 capture (firmware 3.0.1).
    private func legacyListPacket(_ entries: [(String, UInt8, String)]) -> [UInt8] {
        var packet: [UInt8] = [0x37, 0x01, UInt8(entries.count)]
        for (address, state, name) in entries {
            packet += Array(address.utf8)
            packet += [state, UInt8(name.utf8.count)]
            packet += Array(name.utf8)
        }
        packet.append(0x01)
        return packet
    }

    func testLegacyListParsesConnectedAndSavedDevicesWithoutASource() throws {
        var multipoint = SonyMultipoint(legacySupportedFunctions: [0x38])
        XCTAssertEqual(multipoint.queryPayloads, [[0x36, 0x01]])
        XCTAssertTrue(multipoint.update(legacyListPacket([(firstAddress, 1, "Test Laptop"), (secondAddress, 0, "Test Phone Ü")])))
        XCTAssertEqual(multipoint.devices.map(\.address), [firstAddress, secondAddress])
        XCTAssertEqual(multipoint.devices.map(\.name), ["Test Laptop", "Test Phone Ü"])
        XCTAssertEqual(multipoint.devices.map(\.isConnected), [true, false])
        XCTAssertNil(multipoint.selectedSource)
        XCTAssertFalse(multipoint.inventoryIsStale)
        XCTAssertFalse(multipoint.canManageDevices)
        XCTAssertFalse(multipoint.canControlSources)
        XCTAssertNil(multipoint.peripheralActionPayload(.connect, address: secondAddress))
    }

    func testLegacyListRejectsMalformedPacketsAndMarksTheListStale() {
        var multipoint = SonyMultipoint(legacySupportedFunctions: [0x38])
        XCTAssertTrue(multipoint.update(legacyListPacket([(firstAddress, 1, "Test Laptop")])))
        var truncated = legacyListPacket([(firstAddress, 1, "Test Laptop")])
        truncated.removeLast(3)
        XCTAssertFalse(multipoint.update(truncated))
        XCTAssertTrue(multipoint.inventoryIsStale)
        XCTAssertFalse(multipoint.update(legacyListPacket([(firstAddress, 1, "A"), (firstAddress, 0, "B")])))
        XCTAssertTrue(multipoint.update(legacyListPacket([(secondAddress, 0, "Test Phone")])))
        XCTAssertFalse(multipoint.inventoryIsStale)
        XCTAssertEqual(multipoint.devices.map(\.name), ["Test Phone"])
    }

    func testLegacyListIsIgnoredWithoutFunction38AndV2KeepsItsOwnMeaning() {
        var without = SonyMultipoint(legacySupportedFunctions: [0x30])
        XCTAssertTrue(without.queryPayloads.isEmpty)
        XCTAssertFalse(without.update(legacyListPacket([(firstAddress, 1, "Test Laptop")])))
        XCTAssertTrue(without.devices.isEmpty)

        var v2 = SonyMultipoint(supportedFunctions: [0x31, 0x32])
        XCTAssertFalse(v2.supportsLegacyInventory)
        XCTAssertEqual(v2.queryPayloads, [[0x30, 0x02], [0x32, 0x02], [0x36, 0x02], [0x36, 0x01]])
        XCTAssertTrue(v2.update([0x37, 0x01, 0]))
        XCTAssertEqual(v2.keeping, true)
        XCTAssertFalse(v2.update(legacyListPacket([(firstAddress, 1, "Test Laptop")])))
        XCTAssertTrue(v2.devices.isEmpty)
    }

    private let firstAddress = "02:00:00:00:00:A1"
    private let secondAddress = "02:00:00:00:00:A2"

    private func readyMultipoint() -> SonyMultipoint {
        var multipoint = SonyMultipoint(supportedFunctions: [0x31, 0x32])
        for packet in [[0x31, 2, 8, 2, 0], [0x33, 2, 0, 0], capturedInventory, [0x37, 1, 1]] {
            XCTAssertTrue(multipoint.update(packet))
        }
        return multipoint
    }

    private func oneDevicePacket(name: [UInt8]) -> [UInt8] {
        [0x37, 2, 1] + Array(firstAddress.utf8) + [1, 1, 2, 3, UInt8(name.count)] + name + [1]
    }

    private var capturedInventory: [UInt8] {
        [
            0x37, 0x02, 0x08, 0x30, 0x32, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30,
            0x30, 0x3A, 0x41, 0x31, 0x01, 0x2A, 0x41, 0x04, 0x0D, 0x54, 0x65, 0x73, 0x74, 0x20, 0x4C, 0x61,
            0x70, 0x74, 0x6F, 0x70, 0x20, 0x41, 0x30, 0x32, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30,
            0x30, 0x3A, 0x30, 0x30, 0x3A, 0x41, 0x32, 0x02, 0x5A, 0x02, 0x0C, 0x0A, 0x54, 0x65, 0x73, 0x74,
            0x20, 0x50, 0x68, 0x6F, 0x6E, 0x65, 0x30, 0x32, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30,
            0x30, 0x3A, 0x30, 0x30, 0x3A, 0x41, 0x33, 0x00, 0xFF, 0xFF, 0xFF, 0x0F, 0x54, 0x65, 0x73, 0x74,
            0x20, 0x44, 0x65, 0x73, 0x6B, 0x74, 0x6F, 0x70, 0x20, 0x50, 0x43, 0x30, 0x32, 0x3A, 0x30, 0x30,
            0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x41, 0x34, 0x00, 0xFF, 0xFF, 0xFF,
            0x08, 0x54, 0x65, 0x73, 0x74, 0x20, 0x4D, 0x61, 0x63, 0x30, 0x32, 0x3A, 0x30, 0x30, 0x3A, 0x30,
            0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x41, 0x35, 0x00, 0xFF, 0xFF, 0xFF, 0x0D, 0x54,
            0x65, 0x73, 0x74, 0x20, 0x4C, 0x61, 0x70, 0x74, 0x6F, 0x70, 0x20, 0x41, 0x30, 0x32, 0x3A, 0x30,
            0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x41, 0x36, 0x00, 0xFF, 0xFF,
            0xFF, 0x04, 0x54, 0x65, 0x73, 0x74, 0x30, 0x32, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30,
            0x30, 0x3A, 0x30, 0x30, 0x3A, 0x41, 0x37, 0x00, 0xFF, 0xFF, 0xFF, 0x08, 0x54, 0x65, 0x73, 0x74,
            0x20, 0x4D, 0x61, 0x63, 0x30, 0x32, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A,
            0x30, 0x30, 0x3A, 0x41, 0x38, 0x00, 0xFF, 0xFF, 0xFF, 0x0D, 0x54, 0x65, 0x73, 0x74, 0x20, 0x4C,
            0x61, 0x70, 0x74, 0x6F, 0x70, 0x20, 0x42, 0x01,
        ]
    }
}
