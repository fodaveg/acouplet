import Foundation

struct SonyMultipointDevice: Equatable, Identifiable, Sendable {
    let address: String
    let connectionID: UInt8
    let classOfDevice: UInt32
    let name: String

    var id: String { address }
    var isConnected: Bool { connectionID != 0 }

    var symbolName: String {
        let major = (classOfDevice >> 8) & 0x1F
        let minor = (classOfDevice >> 2) & 0x3F
        let unknown = classOfDevice & 0x03 != 0 || major == 0 || major == 0x1F
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let normalized = " " + words.joined(separator: " ") + " "
        func has(_ names: String...) -> Bool {
            names.contains { normalized.contains(" " + $0 + " ") }
        }

        if unknown || major == 1 {
            if has("macbook", "macbook pro", "macbook air", "macbookpro", "macbookair", "powerbook", "ibook") { return "macbook" }
            if has("mac mini", "macmini") { return "macmini" }
            if has("mac studio", "macstudio") { return "macstudio" }
            if has("mac pro", "macpro") {
                let years = words.filter { $0.count == 4 && $0.allSatisfy(\.isNumber) }
                if years.count == 1 {
                    switch years[0] {
                    case "2006", "2007", "2008", "2009", "2010", "2011", "2012": return "macpro.gen1"
                    case "2013": return "macpro.gen2"
                    case "2019", "2023": return has("rack") ? "macpro.gen3.server" : "macpro.gen3"
                    default: break
                    }
                }
                return "desktopcomputer"
            }
            if has("imac", "imac pro", "imacpro", "power mac", "powermac") { return "desktopcomputer" }
            if has("xserve") { return "server.rack" }
        }
        if (unknown || major == 2), has("iphone") {
            let model = words.drop { $0 != "iphone" }.dropFirst()
            let variant = model.dropFirst().first
            switch model.first {
            case "2g", "3g", "3gs", "4", "4s", "5", "5c", "5s", "6", "6s", "7", "8": return "iphone.gen1"
            case "se":
                if variant == nil || ["1", "2", "3", "1st", "2nd", "3rd", "2016", "2020", "2022"].contains(variant ?? "") {
                    return "iphone.gen1"
                }
            case "se2", "se3": return "iphone.gen1"
            case "x", "xr", "xs", "11", "12", "13", "16e", "17e": return "iphone.gen2"
            case "14": return variant == "pro" ? "iphone.gen3" : "iphone.gen2"
            case "15", "air": return "iphone.gen3"
            case "16", "17": return variant == "e" ? "iphone.gen2" : "iphone.gen3"
            case "18" where variant == "pro": return "iphone.gen3"
            default: break
            }
            return "iphone"
        }
        if (unknown || major == 1 || major == 2), has("ipad") { return "ipad" }
        if (unknown || major == 1 || major == 2 || major == 4), has("ipod touch", "ipodtouch", "ipod nano", "ipodnano") { return "ipodtouch" }
        if (unknown || major == 1 || major == 2 || major == 7), has("apple watch", "applewatch") { return "applewatch" }
        if (unknown || major == 1 || major == 4), has("apple tv", "appletv") { return "appletv" }
        if (unknown || major == 1 || major == 4 || major == 7), has("vision pro", "visionpro") { return "visionpro" }

        if unknown {
            if has("phone", "smartphone") { return "smartphone" }
            if has("tablet") { return "rectangle.portrait" }
            if has("laptop", "notebook") { return "laptopcomputer" }
            if has("desktop", "computer", "pc", "mac") { return "desktopcomputer" }
            if has("tv", "television") { return "tv" }
            return "wave.3.right"
        }
        switch major {
        case 1:
            switch minor {
            case 2: return "server.rack"
            case 3: return "laptopcomputer"
            case 4, 5: return "rectangle.portrait"
            case 6: return "applewatch"
            default: return "desktopcomputer"
            }
        case 2: return "smartphone"
        case 4:
            switch minor {
            case 1, 2, 6: return "headphones"
            case 4: return "mic"
            case 9, 14, 15: return "tv"
            case 12, 13: return "video"
            case 18: return "gamecontroller"
            default: return "hifispeaker"
            }
        case 7 where minor == 1: return "applewatch"
        case 7 where minor == 5: return "visionpro"
        default: return "wave.3.right"
        }
    }
}

struct SonyMultipointInventory: Equatable, Sendable {
    let devices: [SonyMultipointDevice]
    let playbackRightID: UInt8

    var selectedSource: SonyMultipointDevice? {
        guard playbackRightID != 0 else { return nil }
        return devices.first { $0.connectionID == playbackRightID }
    }

    /// Parses the v2 inventory (`37 02`) or, with `legacy`, the MDR v1 list (`37 01`). The v1 entries
    /// have no device-class bytes and the state byte is 0 for a saved device and 1 for a connected one.
    /// The trailing byte is the playback right in v2; v1 sends a constant `01` that carries no source.
    /// The v1 byte is a connection state, not an ID: every connected device reports 1. Connected v1
    /// devices therefore get synthetic IDs (1, 2, ... in list order) so they stay unique; saved ones get 0.
    fileprivate init?(payload: [UInt8], legacy: Bool = false) {
        guard payload.count >= 4 else { return nil }
        let classLength = legacy ? 0 : 3
        var offset = 3
        var syntheticID: UInt8 = 0
        var receivedDevices: [SonyMultipointDevice] = []
        for _ in 0..<payload[2] {
            guard offset + 19 + classLength < payload.count,
                  let address = multipointAddress(payload[offset..<(offset + 17)]) else { return nil }
            var connectionID = payload[offset + 17]
            if legacy, connectionID != 0 {
                syntheticID += 1
                connectionID = syntheticID
            }
            let classOfDevice = legacy ? 0 : UInt32(payload[offset + 18]) << 16
                | UInt32(payload[offset + 19]) << 8 | UInt32(payload[offset + 20])
            let nameLength = Int(payload[offset + 18 + classLength])
            offset += 19 + classLength
            guard (1...128).contains(nameLength), offset + nameLength < payload.count,
                  let name = String(bytes: payload[offset..<(offset + nameLength)], encoding: .utf8) else { return nil }
            receivedDevices.append(SonyMultipointDevice(address: address, connectionID: connectionID,
                                                        classOfDevice: classOfDevice, name: name))
            offset += nameLength
        }
        let connectedIDs = receivedDevices.filter(\.isConnected).map(\.connectionID)
        guard offset + 1 == payload.count,
              Set(receivedDevices.map(\.address)).count == receivedDevices.count,
              Set(connectedIDs).count == connectedIDs.count else { return nil }
        devices = receivedDevices
        playbackRightID = legacy ? 0 : payload[offset]
    }
}

enum SonySourceControlResult: Equatable, Sendable {
    case success, failure, callInProgress, a2dpNotConnected, voiceAssistantPriority
    case unknown(UInt8)

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .success
        case 0x01: .failure
        case 0x02: .callInProgress
        case 0x03: .a2dpNotConnected
        case 0x04: .voiceAssistantPriority
        default: .unknown(rawValue)
        }
    }

    var errorMessage: String? {
        switch self {
        case .success: nil
        case .failure: String(localized: "The headphones could not change the audio source.")
        case .callInProgress: String(localized: "Finish the phone call before changing the audio source.")
        case .a2dpNotConnected: String(localized: "The device is not connected for Bluetooth audio.")
        case .voiceAssistantPriority: String(localized: "Finish using the voice assistant before changing the audio source.")
        case .unknown: String(localized: "The headphones reported an unknown audio source result.")
        }
    }
}

struct SonySourceSelectionResult: Equatable, Sendable {
    let address: String
    let result: SonySourceControlResult

    func matches(address: String) -> Bool {
        self.address == multipointAddress(Array(address.utf8)[...])
    }
}

enum SonyPeripheralAction: UInt8, Sendable {
    case disconnect = 0x00
    case connect = 0x01
    case unpair = 0x02
}

enum SonyPeripheralResult: Equatable, Sendable {
    case disconnectionSuccess, disconnectionFailure, disconnectionInProgress, disconnectionBusy
    case connectionSuccess, connectionFailure, connectionInProgress, connectionBusy
    case unpairingSuccess, unpairingFailure, unpairingInProgress, unpairingBusy
    case pairingSuccess, pairingFailure, pairingInProgress, pairingBusy
    case unknown(UInt8)

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .disconnectionSuccess
        case 0x01: .disconnectionFailure
        case 0x02: .disconnectionInProgress
        case 0x03: .disconnectionBusy
        case 0x10: .connectionSuccess
        case 0x11: .connectionFailure
        case 0x12: .connectionInProgress
        case 0x13: .connectionBusy
        case 0x20: .unpairingSuccess
        case 0x21: .unpairingFailure
        case 0x22: .unpairingInProgress
        case 0x23: .unpairingBusy
        case 0x30: .pairingSuccess
        case 0x31: .pairingFailure
        case 0x32: .pairingInProgress
        case 0x33: .pairingBusy
        default: .unknown(rawValue)
        }
    }

    var isSuccess: Bool {
        switch self {
        case .disconnectionSuccess, .connectionSuccess, .unpairingSuccess, .pairingSuccess: true
        default: false
        }
    }

    var isInProgress: Bool {
        switch self {
        case .disconnectionInProgress, .connectionInProgress, .unpairingInProgress, .pairingInProgress: true
        default: false
        }
    }

    func matches(action: SonyPeripheralAction) -> Bool {
        switch self {
        case .disconnectionSuccess, .disconnectionFailure, .disconnectionInProgress, .disconnectionBusy: action == .disconnect
        case .connectionSuccess, .connectionFailure, .connectionInProgress, .connectionBusy: action == .connect
        case .unpairingSuccess, .unpairingFailure, .unpairingInProgress, .unpairingBusy: action == .unpair
        case .pairingSuccess, .pairingFailure, .pairingInProgress, .pairingBusy, .unknown: false
        }
    }
}

struct SonyPeripheralActionResult: Equatable, Sendable {
    let action: UInt8
    let result: SonyPeripheralResult
    let address: String

    func matches(action: SonyPeripheralAction, address: String) -> Bool {
        self.action == action.rawValue && self.address == multipointAddress(Array(address.utf8)[...])
    }
}

struct SonyMultipoint: Equatable, Sendable {
    let supportsInventory: Bool
    let supportsSourceControl: Bool
    /// MDR v1 headphones announce function 0x38 only while multipoint is on; they then answer `0E 36 01`
    /// with a read-only device list. They have no capacity, pairing mode or source control.
    let supportsLegacyInventory: Bool
    private(set) var maxPairedDevices: UInt8?
    private(set) var maxConnectedDevices: UInt8?
    private(set) var multipleConnectionFileTransfer: Bool?
    private(set) var bluetoothMode: UInt8?
    private(set) var available: Bool?
    private(set) var inventory: SonyMultipointInventory?
    private(set) var inventoryIsStale = false
    private(set) var keeping: Bool?
    private(set) var lastKeepingResult: SonySourceControlResult?
    private(set) var lastSourceResult: SonySourceSelectionResult?
    private(set) var lastPeripheralResult: SonyPeripheralActionResult?

    init(supportedFunctions: Set<UInt8> = []) {
        supportsInventory = !supportedFunctions.isDisjoint(with: [0x32, 0x33])
        supportsSourceControl = supportedFunctions.contains(0x31)
        supportsLegacyInventory = false
    }

    init(legacySupportedFunctions supportedFunctions: Set<UInt8>) {
        supportsInventory = false
        supportsSourceControl = false
        supportsLegacyInventory = supportedFunctions.contains(0x38)
    }

    var queryPayloads: [[UInt8]] {
        (supportsLegacyInventory ? [[0x36, 0x01]] : [])
            + (supportsInventory ? (maxPairedDevices == nil ? [[0x30, 0x02]] : []) + [[0x32, 0x02], [0x36, 0x02]] : [])
            + (supportsSourceControl ? [[0x36, 0x01]] : [])
    }

    var devices: [SonyMultipointDevice] { inventory?.devices ?? [] }
    var selectedSource: SonyMultipointDevice? { inventory?.selectedSource }

    var pairingMode: Bool? {
        switch bluetoothMode {
        case 0x00: false
        case 0x01: true
        default: nil
        }
    }

    var canManageDevices: Bool {
        supportsInventory && available == true && pairingMode != nil && inventory != nil && !inventoryIsStale
    }

    var canControlSources: Bool { supportsSourceControl && canManageDevices && keeping != nil }

    func sourceSwitchPayload(address: String) -> [UInt8]? {
        guard canControlSources, let address = multipointAddress(Array(address.utf8)[...]),
              devices.contains(where: { $0.address == address && $0.isConnected }) else { return nil }
        return [0x3C, 0x01] + Array(address.utf8)
    }

    func keepingSetPayload(_ enabled: Bool) -> [UInt8]? {
        guard canControlSources, !enabled || selectedSource != nil else { return nil }
        return [0x38, 0x01, enabled ? 0x00 : 0x01]
    }

    func peripheralActionPayload(_ action: SonyPeripheralAction, address: String) -> [UInt8]? {
        guard canManageDevices, let address = multipointAddress(Array(address.utf8)[...]),
              let device = devices.first(where: { $0.address == address }) else { return nil }
        switch action {
        case .connect:
            guard !device.isConnected, let maxConnectedDevices,
                  devices.filter(\.isConnected).count < Int(maxConnectedDevices) else { return nil }
        case .disconnect: guard device.isConnected else { return nil }
        case .unpair: break
        }
        return [0x3C, 0x02, action.rawValue] + Array(address.utf8)
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2 else { return false }
        switch (payload[0], payload[1]) {
        case (0x31, 0x02):
            guard supportsInventory, payload.count == 5 else { return false }
            maxPairedDevices = payload[2]
            maxConnectedDevices = payload[3]
            multipleConnectionFileTransfer = payload[4] <= 1 ? payload[4] == 0 : nil
        case (0x33, 0x02), (0x35, 0x02):
            guard supportsInventory, payload.count == 4 else { return false }
            bluetoothMode = payload[2]
            available = payload[3] <= 1 ? payload[3] == 0 : nil
        case (0x37, 0x02), (0x39, 0x02):
            guard supportsInventory else { return false }
            guard let receivedInventory = SonyMultipointInventory(payload: payload) else {
                inventoryIsStale = true
                return false
            }
            inventory = receivedInventory
            inventoryIsStale = false
        case (0x37, 0x01) where supportsLegacyInventory:
            guard payload.count > 3 else { return false }
            guard let receivedInventory = SonyMultipointInventory(payload: payload, legacy: true) else {
                inventoryIsStale = true
                return false
            }
            inventory = receivedInventory
            inventoryIsStale = false
        case (0x37, 0x01):
            guard supportsSourceControl, payload.count == 3 else { return false }
            keeping = payload[2] <= 1 ? payload[2] == 0 : nil
        case (0x39, 0x01):
            guard supportsSourceControl, payload.count == 4 else { return false }
            keeping = payload[2] <= 1 ? payload[2] == 0 : nil
            lastKeepingResult = SonySourceControlResult(rawValue: payload[3])
        case (0x3D, 0x01):
            guard supportsSourceControl, payload.count == 20,
                  let address = multipointAddress(payload[3...]) else { return false }
            lastSourceResult = SonySourceSelectionResult(address: address, result: SonySourceControlResult(rawValue: payload[2]))
        case (0x3D, 0x02):
            guard supportsInventory, payload.count == 21,
                  let address = multipointAddress(payload[4...]) else { return false }
            lastPeripheralResult = SonyPeripheralActionResult(action: payload[2], result: SonyPeripheralResult(rawValue: payload[3]), address: address)
        default:
            return false
        }
        return true
    }
}

private func multipointAddress(_ bytes: ArraySlice<UInt8>) -> String? {
    guard bytes.count == 17, bytes.enumerated().allSatisfy({ index, byte in
        index % 3 == 2 ? byte == 0x3A : (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }) else { return nil }
    return String(decoding: bytes, as: UTF8.self).uppercased()
}
