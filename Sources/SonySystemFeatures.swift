import Foundation

enum SonySystemFeature: UInt8, CaseIterable, Sendable {
    case pauseOnRemoval = 0x01
    case headGestures = 0x0F
    case speakToChat = 0x0C
    case voiceAssistantWakeWord = 0x05

    var title: String {
        switch self {
        case .pauseOnRemoval: String(localized: "Pause when removed")
        case .headGestures: String(localized: "Head gestures")
        case .speakToChat: String(localized: "Speak-to-Chat")
        case .voiceAssistantWakeWord: String(localized: "Voice assistant wake word")
        }
    }

    var function: UInt8 {
        switch self {
        case .pauseOnRemoval: 0xF1
        case .headGestures: 0xFF
        case .speakToChat: 0xFC
        case .voiceAssistantWakeWord: 0xF5
        }
    }
}

struct SonySystemFeatureState: Equatable, Sendable {
    var enabled: Bool?
    var available: Bool?
    var isVisible: Bool?
}

struct SonySpeechSensitivity: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    static let options = (UInt8(0)...2).map(Self.init)
    var sonyValue: UInt8? { rawValue <= 2 ? rawValue : nil }
    var title: String {
        switch rawValue {
        case 0: String(localized: "Automatic")
        case 1: String(localized: "High")
        case 2: String(localized: "Low")
        default: String(localized: "Unknown")
        }
    }
}

struct SonySpeakToChatDelay: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    static let options = (UInt8(0)...3).map(Self.init)
    var sonyValue: UInt8? { rawValue <= 3 ? rawValue : nil }
    var title: String {
        switch rawValue {
        case 0: String(localized: "Short")
        case 1: String(localized: "Medium")
        case 2: String(localized: "Long")
        case 3: String(localized: "Manually")
        default: String(localized: "Unknown")
        }
    }
}

struct SonySpeakToChatOptions: Equatable, Sendable {
    private(set) var sensitivity: SonySpeechSensitivity?
    private(set) var delay: SonySpeakToChatDelay?

    func setPayload(sensitivity: SonySpeechSensitivity, delay: SonySpeakToChatDelay) -> [UInt8]? {
        guard self.sensitivity?.sonyValue != nil, self.delay?.sonyValue != nil,
              let sensitivity = sensitivity.sonyValue, let delay = delay.sonyValue else { return nil }
        return [0xFC, 0x0C, sensitivity, delay]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == 0x0C else { return false }
        switch payload[0] {
        case 0xFB, 0xFD:
            guard payload.count == 4 else { return false }
            sensitivity = SonySpeechSensitivity(rawValue: payload[2])
            delay = SonySpeakToChatDelay(rawValue: payload[3])
        default:
            return false
        }
        return true
    }
}

struct SonyVoiceAssistantOption: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    var sonyValue: UInt8? { (0x30...0x34).contains(rawValue) || rawValue == 0x3F || rawValue == 0xFF ? rawValue : nil }

    var title: String {
        switch rawValue {
        case 0x30: String(localized: "Mobile device assistant")
        case 0x31: String(localized: "Google Assistant")
        case 0x32: String(localized: "Amazon Alexa")
        case 0x33: String(localized: "Tencent Xiaowei")
        case 0x34: String(localized: "Sony voice assistant")
        case 0x3F: String(localized: "Enabled on another device")
        case 0xFF: String(localized: "None")
        default: String(localized: "Unknown")
        }
    }
}

struct SonyVoiceAssistantState: Equatable, Sendable {
    private(set) var options: [SonyVoiceAssistantOption]?
    private(set) var keyType: UInt8?
    private(set) var available: Bool?
    private(set) var current: SonyVoiceAssistantOption?

    var hasKnownCapability: Bool { keyType.map { $0 <= 3 } == true && options != nil }
    var hasKnownParameter: Bool { knownCurrent != nil }
    var knownCurrent: SonyVoiceAssistantOption? { current.flatMap { $0.sonyValue != nil ? $0 : nil } }

    var knownOptions: [SonyVoiceAssistantOption] {
        guard hasKnownCapability, let options else { return [] }
        return options.filter { (0x30...0x34).contains($0.rawValue) } + [SonyVoiceAssistantOption(rawValue: 0xFF)]
    }

    var queryPayloads: [[UInt8]] {
        (options == nil ? [[0xF0, 0x04]] : []) + [[0xF2, 0x04], [0xF6, 0x04]]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0xF0, 0x04]:
            options = nil
            keyType = nil
        case [0xF2, 0x04]: available = nil
        case [0xF6, 0x04]: current = nil
        default: break
        }
    }

    func setPayload(_ option: SonyVoiceAssistantOption) -> [UInt8]? {
        guard available == true, hasKnownParameter, knownOptions.contains(option) else { return nil }
        return [0xF8, 0x04, option.rawValue]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3, payload[1] == 0x04 else { return false }
        switch payload[0] {
        case 0xF1:
            guard payload.count >= 4, payload.count == 4 + Int(payload[3]),
                  Set(payload.dropFirst(4)).count == Int(payload[3]) else { return false }
            keyType = payload[2]
            options = payload.dropFirst(4).map(SonyVoiceAssistantOption.init)
        case 0xF3, 0xF5:
            guard payload.count == 3 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0xF7, 0xF9:
            guard payload.count == 3 else { return false }
            current = SonyVoiceAssistantOption(rawValue: payload[2])
        default:
            return false
        }
        return true
    }
}

struct SonyAutomaticPowerOffOption: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    var sonyValue: UInt8? { rawValue <= 0x04 || rawValue == 0x10 || rawValue == 0x11 ? rawValue : nil }

    var title: String {
        switch rawValue {
        case 0x00: String(localized: "After 5 minutes")
        case 0x01: String(localized: "After 30 minutes")
        case 0x02: String(localized: "After 60 minutes")
        case 0x03: String(localized: "After 180 minutes")
        case 0x04: String(localized: "After 15 minutes")
        case 0x10: String(localized: "When removed")
        case 0x11: String(localized: "Never")
        default: String(localized: "Unknown")
        }
    }
}

struct SonyAutomaticPowerOffState: Equatable, Sendable {
    let inquiryType: UInt8
    let generation: SonyProtocolInfo.Generation
    private(set) var options: [SonyAutomaticPowerOffOption]?
    private(set) var available: Bool?
    private(set) var parameterType: UInt8?
    private(set) var current: SonyAutomaticPowerOffOption?
    private(set) var last: SonyAutomaticPowerOffOption?

    init(inquiryType: UInt8, generation: SonyProtocolInfo.Generation = .v2) {
        self.inquiryType = inquiryType
        self.generation = generation
    }

    private func recognizes(_ option: SonyAutomaticPowerOffOption) -> Bool {
        option.sonyValue != nil && (generation != .v1 || option.rawValue != 0x04)
    }

    var knownOptions: [SonyAutomaticPowerOffOption] { options?.filter { recognizes($0) } ?? [] }

    var knownCurrent: SonyAutomaticPowerOffOption? {
        guard generation != .v1 || parameterType == 1, let current, recognizes(current),
              generation != .v2 || inquiryType != 0x04 || current.rawValue != 0x10 else { return nil }
        return current
    }

    var hasKnownParameter: Bool {
        knownCurrent != nil && last.map { recognizes($0)
            && (generation != .v2 || inquiryType != 0x04 || $0.rawValue != 0x10) } == true
    }

    var parameterQueryPayload: [UInt8] { [generation == .v1 ? 0xF6 : 0x26, inquiryType] }

    mutating func invalidateRead(_ query: [UInt8]) {
        guard query.count == 2, query[1] == inquiryType else { return }
        switch (generation, query[0]) {
        case (.v1, 0xF0), (.v2, 0x20): options = nil
        case (.v1, 0xF2), (.v2, 0x22): available = nil
        case (.v1, 0xF6), (.v2, 0x26):
            parameterType = nil
            current = nil
            last = nil
        default: break
        }
    }

    var queryPayloads: [[UInt8]] {
        (options == nil ? [[generation == .v1 ? 0xF0 : 0x20, inquiryType]] : [])
            + [[generation == .v1 ? 0xF2 : 0x22, inquiryType], parameterQueryPayload]
    }

    func setPayload(_ option: SonyAutomaticPowerOffOption) -> [UInt8]? {
        guard available == true, options?.contains(option) == true, recognizes(option), hasKnownParameter,
              let last, generation != .v2 || inquiryType != 0x04 || option.rawValue != 0x10 else { return nil }
        let selected = option.rawValue
        return (generation == .v1 ? [0xF8, inquiryType, 1] : [0x28, inquiryType])
            + [selected, selected <= 0x04 ? selected : last.rawValue]
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count == (generation == .v1 ? 5 : 4) else { return false }
        return setPayload(SonyAutomaticPowerOffOption(rawValue: payload[payload.count - 2])) == payload
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3, payload[1] == inquiryType else { return false }
        switch (generation, payload[0]) {
        case (.v1, 0xF1), (.v2, 0x21):
            guard payload.count == 3 + Int(payload[2]), Set(payload.dropFirst(3)).count == Int(payload[2]) else { return false }
            options = payload.dropFirst(3).map(SonyAutomaticPowerOffOption.init)
        case (.v1, 0xF3), (.v1, 0xF5), (.v2, 0x23), (.v2, 0x25):
            guard payload.count == 3 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
        case (.v1, 0xF7), (.v1, 0xF9), (.v2, 0x27), (.v2, 0x29):
            guard payload.count == (generation == .v1 ? 5 : 4) else { return false }
            if generation == .v1 { parameterType = payload[2] }
            current = SonyAutomaticPowerOffOption(rawValue: payload[payload.count - 2])
            last = SonyAutomaticPowerOffOption(rawValue: payload[payload.count - 1])
        default:
            return false
        }
        return true
    }
}

struct SonySystemFeatures: Equatable, Sendable {
    private var states: [SonySystemFeature: SonySystemFeatureState] = [:]
    private(set) var speakToChatOptions: SonySpeakToChatOptions?
    private(set) var voiceAssistant: SonyVoiceAssistantState?
    private(set) var automaticPowerOff: SonyAutomaticPowerOffState?
    private var generalSlots: [UInt8] = []
    private var identifiedGeneralSlots: Set<UInt8> = []
    private var sidetoneStates: [UInt8: SonySystemFeatureState] = [:]
    private var multipointStates: [UInt8: SonySystemFeatureState] = [:]
    private(set) var generation = SonyProtocolInfo.Generation.v2

    /// MDR v1 exposes only the general settings (functions D1–D4), such as multipoint on the WH-1000XM4.
    /// Their replies use a v1 layout: `D1 slot type titleLength title summaryLength summary xx xx`,
    /// `D7 slot 01 value` and `D8 slot 01 value`, where value 1 means on.
    init(legacyGeneralSettings supportedFunctions: Set<UInt8>) {
        generation = .v1
        generalSlots = (0xD1...0xD4).filter { supportedFunctions.contains($0) }
    }

    init(supportedFunctions: Set<UInt8> = []) {
        for feature in SonySystemFeature.allCases where supportedFunctions.contains(feature.function) {
            states[feature] = SonySystemFeatureState(isVisible: feature == .voiceAssistantWakeWord ? nil : true)
        }
        if supportedFunctions.contains(SonySystemFeature.speakToChat.function) {
            speakToChatOptions = SonySpeakToChatOptions()
        }
        if supportedFunctions.contains(0xF4) { voiceAssistant = SonyVoiceAssistantState() }
        if supportedFunctions.contains(0x25) {
            automaticPowerOff = SonyAutomaticPowerOffState(inquiryType: 0x05)
        } else if supportedFunctions.contains(0x24) {
            automaticPowerOff = SonyAutomaticPowerOffState(inquiryType: 0x04)
        }
        generalSlots = (0xD1...0xD4).filter { supportedFunctions.contains($0) }
    }

    subscript(_ feature: SonySystemFeature) -> SonySystemFeatureState? { states[feature] }

    var sidetoneSlot: UInt8? { sidetoneStates.count == 1 ? sidetoneStates.keys.first : nil }
    var sidetone: SonySystemFeatureState? { sidetoneSlot.flatMap { sidetoneStates[$0] } }
    var multipointSlot: UInt8? { multipointStates.count == 1 ? multipointStates.keys.first : nil }
    var multipoint: SonySystemFeatureState? { multipointSlot.flatMap { multipointStates[$0] } }
    var generalSettingsAreIdentified: Bool { generalSlots.allSatisfy { identifiedGeneralSlots.contains($0) } }

    var queryPayloads: [[UInt8]] {
        var queries: [[UInt8]] = SonySystemFeature.allCases.filter { states[$0] != nil }.flatMap {
            [[0xF2, $0.rawValue], [0xF6, $0.rawValue]]
        }
        if speakToChatOptions != nil { queries += [[0xFA, 0x0C]] }
        queries += voiceAssistant?.queryPayloads ?? []
        queries += automaticPowerOff?.queryPayloads ?? []
        queries += generalSlots.filter { !identifiedGeneralSlots.contains($0) }.map { [0xD0, $0, 0x01] }
        if let slot = sidetoneSlot { queries += [[0xD2, slot], [0xD6, slot]] }
        if let slot = multipointSlot { queries += [[0xD2, slot], [0xD6, slot]] }
        return queries
    }

    func setPayload(_ feature: SonySystemFeature, enabled: Bool) -> [UInt8]? {
        guard let state = states[feature], state.available == true, state.enabled != nil,
              state.isVisible == true else { return nil }
        return [0xF8, feature.rawValue, enabled ? 0x00 : 0x01]
            + (feature == .speakToChat ? [0x01] : [])
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        voiceAssistant?.invalidateRead(query)
        automaticPowerOff?.invalidateRead(query)
        if query == [0xFA, 0x0C], speakToChatOptions != nil { speakToChatOptions = SonySpeakToChatOptions() }
        guard query.count == 2 else { return }
        if let feature = SonySystemFeature(rawValue: query[1]), states[feature] != nil {
            if query[0] == 0xF2 {
                states[feature]?.available = nil
                if feature == .voiceAssistantWakeWord { states[feature]?.isVisible = nil }
            } else if query[0] == 0xF6 {
                states[feature]?.enabled = nil
            }
        }
        if query[0] == 0xD2 { sidetoneStates[query[1]]?.available = nil }
        else if query[0] == 0xD6 { sidetoneStates[query[1]]?.enabled = nil }
    }

    func sidetoneSetPayload(enabled: Bool) -> [UInt8]? {
        guard let slot = sidetoneSlot, let state = sidetone,
              state.available == true, state.enabled != nil else { return nil }
        return generalSetPayload(slot: slot, enabled: enabled)
    }

    func multipointSetPayload(enabled: Bool) -> [UInt8]? {
        guard let slot = multipointSlot, let state = multipoint,
              state.available == true, state.enabled != nil else { return nil }
        return generalSetPayload(slot: slot, enabled: enabled)
    }

    private func generalSetPayload(slot: UInt8, enabled: Bool) -> [UInt8] {
        generation == .v1 ? [0xD8, slot, 0x01, enabled ? 0x01 : 0x00] : [0xD8, slot, 0x00, enabled ? 0x00 : 0x01]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        if speakToChatOptions?.update(payload) == true { return true }
        if voiceAssistant?.update(payload) == true { return true }
        if automaticPowerOff?.update(payload) == true { return true }
        if updateGeneralSetting(payload) { return true }
        guard payload.count >= 2, let feature = SonySystemFeature(rawValue: payload[1]),
              var state = states[feature],
              payload.count == (feature == .speakToChat ? 4 : 3) else { return false }
        let value = payload[2] <= 1 ? payload[2] == 0 : nil
        switch payload[0] {
        case 0xF3, 0xF5:
            state.available = value
            if feature == .voiceAssistantWakeWord {
                state.isVisible = payload[2] <= 2 ? payload[2] != 2 : nil
                if payload[2] == 2 { state.available = false }
            }
        case 0xF7, 0xF9:
            state.enabled = value
        default:
            return false
        }
        states[feature] = state
        return true
    }

    private mutating func updateGeneralSetting(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3, generalSlots.contains(payload[1]) else { return false }
        let slot = payload[1]
        if payload[0] == 0xD1 {
            let isBoolean: Bool
            let titleStart: Int
            let trailer: Int
            if generation == .v1 {
                guard payload.count >= 5 else { return false }
                isBoolean = payload[2] == 0x02
                titleStart = 4
                trailer = 2
            } else {
                guard payload.count >= 6, payload[2] == 0x00, payload[3] <= 1 else { return false }
                isBoolean = payload[3] == 1
                titleStart = 5
                trailer = 0
            }
            let titleEnd = titleStart + Int(payload[titleStart - 1])
            guard titleEnd < payload.count else { return false }
            let summaryEnd = titleEnd + 1 + Int(payload[titleEnd])
            guard payload.count == summaryEnd + trailer,
                  let title = String(bytes: payload[titleStart..<titleEnd], encoding: .utf8),
                  String(bytes: payload[(titleEnd + 1)..<summaryEnd], encoding: .utf8) != nil else { return false }
            identifiedGeneralSlots.insert(slot)
            if isBoolean, title == "SIDETONE_SETTING" {
                if sidetoneStates[slot] == nil { sidetoneStates[slot] = SonySystemFeatureState() }
            } else {
                sidetoneStates[slot] = nil
            }
            if isBoolean, title == "MULTIPOINT_SETTING" {
                if multipointStates[slot] == nil { multipointStates[slot] = SonySystemFeatureState() }
            } else {
                multipointStates[slot] = nil
            }
            return true
        }
        guard var state = sidetoneStates[slot] ?? multipointStates[slot] else { return false }
        switch payload[0] {
        case 0xD3, 0xD5:
            guard payload.count == 3 else { return false }
            state.available = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0xD7, 0xD9:
            guard payload.count == 4, payload[2] == (generation == .v1 ? 0x01 : 0x00) else { return false }
            state.enabled = payload[3] <= 1 ? payload[3] == (generation == .v1 ? 1 : 0) : nil
        default:
            return false
        }
        if sidetoneStates[slot] != nil {
            sidetoneStates[slot] = state
        } else {
            multipointStates[slot] = state
        }
        return true
    }
}
