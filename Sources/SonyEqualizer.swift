import Foundation

struct SonyEqualizerBand: Codable, Equatable, Hashable, Sendable {
    let informationType: UInt8
    let value: UInt16

    static let clearBass = Self(informationType: 0x10, value: 1)
    static let legacy: [Self] = [.clearBass] + [400, 1_000, 2_500, 6_300, 16_000].map {
        Self(informationType: 1, value: $0)
    }
    static let tenBand: [Self] = [31, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000].map {
        Self(informationType: 1, value: $0)
    }

    var frequency: Int? {
        switch informationType {
        case 1: Int(value)
        case 2: Int(value) * 1_000
        default: nil
        }
    }

    var title: String {
        if self == .clearBass { return String(localized: "Clear Bass") }
        guard let frequency else { return String(localized: "Unknown Band") }
        return frequency >= 1_000
            ? "\((Double(frequency) / 1_000).formatted()) kHz"
            : "\(frequency) Hz"
    }
}

struct SonyEqualizerPreset: Equatable, Identifiable, Sendable {
    let id: UInt8
    let name: String?

    var title: String {
        if id < 0xA0, let preset = EqualizerPreset(rawValue: id) { return preset.title }
        return name ?? EqualizerPreset(rawValue: id)?.title ?? String(format: String(localized: "Preset %02X"), id)
    }
}

struct SonyEqualizerCapabilities: Equatable, Sendable {
    let bandCount: UInt8
    let levelSteps: UInt8
    let presets: [SonyEqualizerPreset]
    let ultAdditionalSteps: UInt8?

    init?(payload: [UInt8], generation: SonyProtocolInfo.Generation = .v2) {
        guard payload.count >= 5, payload[0] == 0x51,
              (generation == .v1 ? [1, 3] : [0, 2, 3, 4]).contains(payload[1]) else { return nil }
        let hasULT = generation == .v2 && payload[1] == 3
        let countIndex = hasULT ? 5 : 4
        guard payload.count > countIndex else { return nil }
        var offset = countIndex + 1
        var presets: [SonyEqualizerPreset] = []
        for _ in 0..<Int(payload[countIndex]) {
            guard offset + 2 <= payload.count else { return nil }
            if generation == .v1, payload[offset + 1] > 128 { return nil }
            let end = offset + 2 + Int(payload[offset + 1])
            guard end <= payload.count,
                  let name = String(bytes: payload[(offset + 2)..<end], encoding: .utf8) else { return nil }
            presets.append(SonyEqualizerPreset(id: payload[offset], name: name.isEmpty ? nil : name))
            offset = end
        }
        guard offset == payload.count else { return nil }
        bandCount = payload[2]
        levelSteps = payload[3]
        self.presets = presets
        ultAdditionalSteps = hasULT ? payload[4] : nil
    }
}

struct SonyEqualizer: Equatable, Sendable {
    let supportedFunctions: Set<UInt8>
    let generation: SonyProtocolInfo.Generation
    let inquiryType: UInt8?
    private(set) var capabilities: SonyEqualizerCapabilities?
    private(set) var bandInformation: [SonyEqualizerBand]?
    private(set) var status: UInt8?
    private(set) var errorCodes: [UInt8]?
    private(set) var presetID: UInt8?
    private(set) var rawValues: [UInt8]?

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v2) {
        self.supportedFunctions = supportedFunctions
        self.generation = generation
        let types: [(UInt8, UInt8)] = generation == .v1 ? [(0x51, 1), (0x53, 3)]
            : [(0x57, 4), (0x50, 0), (0x52, 2), (0x53, 3)]
        inquiryType = types
            .first { supportedFunctions.contains($0.0) }?.1
    }

    var isSupported: Bool { generation == .v1 ? inquiryType != nil : !supportedFunctions.isDisjoint(with: 0x50...0x59) }

    private var isOrdinary: Bool {
        generation == .v1 ? inquiryType == 1 || inquiryType == 3 : inquiryType == 0 || inquiryType == 2 || inquiryType == 4
    }

    var queryPayloads: [[UInt8]] {
        guard let inquiryType else { return [] }
        let capability: [[UInt8]] = [[0x50, inquiryType, 1]]
        return isOrdinary ? capability + [[0x52, inquiryType], [0x5A, inquiryType], [0x56, inquiryType]] : capability
    }

    var parameterQueryPayload: [UInt8]? {
        guard isOrdinary, let inquiryType else { return nil }
        return [0x56, inquiryType]
    }

    var available: Bool? {
        switch status {
        case 0: true
        case 1: false
        default: nil
        }
    }

    var presetTitle: String? {
        guard let presetID else { return nil }
        return capabilities?.presets.first { $0.id == presetID }?.title
            ?? SonyEqualizerPreset(id: presetID, name: nil).title
    }

    var canSelectPreset: Bool { isOrdinary && available == true && capabilities != nil }

    var flatSettings: EqualizerSettings? {
        guard isOrdinary, let capabilities, let bandInformation,
              capabilities.levelSteps > 1, capabilities.levelSteps % 2 == 1 else { return nil }
        let frequencies = bandInformation.compactMap(\.frequency)
        let bassCount = bandInformation.filter { $0 == .clearBass }.count
        let legacy = bassCount == 1 && frequencies == SonyEqualizerBand.legacy.compactMap(\.frequency)
            && bandInformation.count == 6 && (capabilities.bandCount == 6 || (generation == .v2 && capabilities.bandCount == 5))
        let tenBand = generation == .v2 && bassCount == 0 && frequencies == SonyEqualizerBand.tenBand.compactMap(\.frequency)
            && bandInformation.count == 10 && capabilities.bandCount == 10
        guard legacy || tenBand else { return nil }
        return EqualizerSettings(layout: bandInformation, levelSteps: capabilities.levelSteps,
                                 values: Array(repeating: 0, count: bandInformation.count))
    }

    var settings: EqualizerSettings? {
        guard let flatSettings, let rawValues, rawValues.count == flatSettings.layout.count,
              rawValues.allSatisfy({ $0 < flatSettings.levelSteps }) else { return nil }
        let center = (Int(flatSettings.levelSteps) - 1) / 2
        return EqualizerSettings(layout: flatSettings.layout, levelSteps: flatSettings.levelSteps,
                                 values: rawValues.map { Int($0) - center })
    }

    /// Presets that store a curve of their own: Manual plus the two user slots the Mac can fill.
    static let userSlots: [UInt8] = [EqualizerPreset.user1.rawValue, EqualizerPreset.user2.rawValue]

    private static func isCurveTarget(_ id: UInt8) -> Bool {
        id == EqualizerPreset.manual.rawValue || userSlots.contains(id)
    }

    private var supportsCurveWrite: Bool {
        canSelectPreset && (generation == .v1 ? inquiryType == 1 : inquiryType != 2) && flatSettings != nil
    }

    private func advertises(_ preset: UInt8) -> Bool {
        capabilities?.presets.contains { $0.id == preset } == true
    }

    var canEdit: Bool {
        supportsCurveWrite && (generation == .v1 ? presetID == EqualizerPreset.manual.rawValue : presetID != nil)
            && advertises(EqualizerPreset.manual.rawValue)
    }

    /// User slots the headphones advertise and that accept a curve in the current state.
    var savableSlots: [UInt8] {
        supportsCurveWrite ? Self.userSlots.filter(advertises) : []
    }

    var requiresManualSelection: Bool {
        generation == .v1 && inquiryType == 1 && canSelectPreset && flatSettings != nil
            && presetID != EqualizerPreset.manual.rawValue
            && advertises(EqualizerPreset.manual.rawValue)
    }

    func presetPayload(_ preset: UInt8) -> [UInt8]? {
        guard canSelectPreset, let inquiryType, generation != .v1 || preset != 0xFF,
              capabilities?.presets.contains(where: { $0.id == preset }) == true else { return nil }
        return [0x58, inquiryType, preset, 0]
    }

    func settingsPayload(_ settings: EqualizerSettings) -> [UInt8]? {
        guard canEdit else { return nil }
        return curvePayload(settings, target: EqualizerPreset.manual.rawValue)
    }

    /// Curve write for `target` (Manual or a user slot). It only builds the bytes: the target must
    /// be selected and confirmed first, and `acceptsSetPayload` enforces that when the frame is sent.
    /// v1 always writes to `FF` and relies on the selected slot; v2 names the slot.
    func curvePayload(_ settings: EqualizerSettings, target: UInt8) -> [UInt8]? {
        guard supportsCurveWrite, Self.isCurveTarget(target), advertises(target), let inquiryType, let flatSettings,
              settings.layout == flatSettings.layout, settings.levelSteps == flatSettings.levelSteps,
              settings.values.count == flatSettings.layout.count, let range = settings.levelRange,
              settings.values.allSatisfy(range.contains) else { return nil }
        let center = range.upperBound
        return [0x58, inquiryType, generation == .v1 ? 0xFF : target, UInt8(settings.values.count)]
            + settings.values.map { UInt8($0 + center) }
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 4, payload[0] == 0x58, payload[1] == inquiryType,
              payload.count == 4 + Int(payload[3]) else { return false }
        if payload[3] == 0 { return presetPayload(payload[2]) == payload }
        guard payload[2] == (generation == .v1 ? 0xFF : presetID ?? 0), let target = presetID,
              Self.isCurveTarget(target), let flatSettings,
              payload[3] == flatSettings.layout.count else { return false }
        let center = (Int(flatSettings.levelSteps) - 1) / 2
        let settings = EqualizerSettings(layout: flatSettings.layout, levelSteps: flatSettings.levelSteps,
                                         values: payload.dropFirst(4).map { Int($0) - center })
        return curvePayload(settings, target: target) == payload
    }

    func confirmationValue(_ payload: [UInt8]) -> [UInt8] {
        if generation == .v1, payload[0] == 0x58, payload[2] == 0xFF, payload[3] != 0 {
            return [presetID ?? EqualizerPreset.manual.rawValue] + payload.dropFirst(3)
        }
        return Self.isCurveTarget(payload[2]) && payload[3] != 0 ? Array(payload.dropFirst(2)) : [payload[2]]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, let inquiryType, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x51:
            guard let capabilities = SonyEqualizerCapabilities(payload: payload, generation: generation) else { return false }
            self.capabilities = capabilities
        case 0x53, 0x55:
            guard isOrdinary else { return false }
            if inquiryType == 4 {
                guard payload.count >= 4, payload.count == 4 + Int(payload[3]) else { return false }
                errorCodes = Array(payload.dropFirst(4))
            } else {
                guard payload.count == 3 else { return false }
                errorCodes = nil
            }
            status = payload[2]
        case 0x5B:
            guard isOrdinary, payload.count >= 3, payload.count == 3 + 3 * Int(payload[2]) else { return false }
            bandInformation = stride(from: 3, to: payload.count, by: 3).map { index in
                SonyEqualizerBand(informationType: payload[index],
                                  value: UInt16(payload[index + 1]) << 8 | UInt16(payload[index + 2]))
            }
        case 0x57, 0x59:
            guard isOrdinary, payload.count >= 4, payload.count == 4 + Int(payload[3]) else { return false }
            if generation == .v1, payload[3] != 0, let capabilities {
                guard payload[3] == capabilities.bandCount,
                      payload.dropFirst(4).allSatisfy({ $0 < capabilities.levelSteps }) else { return false }
            } else if payload[3] != 0, let flatSettings {
                guard payload[3] == flatSettings.layout.count,
                      payload.dropFirst(4).allSatisfy({ $0 < flatSettings.levelSteps }) else { return false }
            }
            presetID = generation == .v1 && payload[2] == 0xFF ? nil : payload[2]
            if generation == .v1 || payload[3] != 0 {
                rawValues = payload[3] == 0 ? nil : Array(payload.dropFirst(4))
            }
        default:
            return false
        }
        return true
    }
}
