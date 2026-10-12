import Foundation

enum SonyConnectionAlertFormat: UInt8, Sendable {
    case fixed = 0x00
    case legacyFixed = 0x01
    case flexible = 0x06
}

enum SonyConnectionAlertActionType: Equatable, Sendable {
    case confirmationOnly, positiveNegative, positiveConfirmationWithReply
    case unknown(UInt8)

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .confirmationOnly
        case 0x01: .positiveNegative
        case 0x02: .positiveConfirmationWithReply
        default: .unknown(rawValue)
        }
    }
}

enum SonyConnectionAlertAction: UInt8, Sendable {
    case negative = 0x00
    case positive = 0x01
}

struct SonyConnectionAffectedFeature: RawRepresentable, Equatable, Sendable {
    let rawValue: UInt8

    var title: String {
        switch rawValue {
        case 0x00: String(localized: "Equalizer")
        case 0x01: "DSEE"
        case 0x02: String(localized: "Speak-to-Chat")
        case 0x03: String(localized: "Adaptive Volume Control")
        case 0x04, 0x0C: String(localized: "Voice activation")
        case 0x05: String(localized: "Service Link")
        case 0x06: "LDAC"
        case 0x07: String(localized: "Sound Quality priority")
        case 0x08: String(localized: "Google Assistant")
        case 0x09: String(localized: "Voice assistant")
        case 0x0A: String(localized: "Firmware updates")
        case 0x0B: String(localized: "Multipoint")
        case 0x0D: String(localized: "Background Music Effect")
        case 0x0E: String(localized: "Power save mode")
        case 0x0F: String(localized: "Spatial sound and head tracking")
        case 0x10: String(localized: "LE Audio")
        case 0x11: String(localized: "Immersive audio")
        case 0x12: String(localized: "Auto Switch")
        case 0x13: String(localized: "Some Auto Play functions")
        case 0x14: String(localized: "Noise cancellation")
        case 0x15: String(localized: "Sound AR")
        case 0x16: String(localized: "Voice control")
        case 0x17: String(localized: "Quick Access")
        case 0x18: String(localized: "LDAC playback")
        case 0x19: String(localized: "Some Scene-based Listening functions")
        default: String(localized: "Unknown feature")
        }
    }
}

struct SonyConnectionAlert: Equatable, Sendable {
    let format: SonyConnectionAlertFormat
    let messageID: UInt8
    let actionType: SonyConnectionAlertActionType
    let affectedFeatures: [SonyConnectionAffectedFeature]

    init?(payload: [UInt8], generation: SonyProtocolInfo.Generation = .v2) {
        guard payload.count >= 4, payload[0] == 0x99,
              let format = SonyConnectionAlertFormat(rawValue: payload[1]),
              (generation == .v1) == (format == .legacyFixed) else { return nil }
        switch format {
        case .fixed, .legacyFixed:
            guard payload.count == 4 else { return nil }
            affectedFeatures = []
            actionType = SonyConnectionAlertActionType(rawValue: payload[3])
        case .flexible:
            let featureCount = Int(payload[3])
            guard payload.count == featureCount + 5 else { return nil }
            affectedFeatures = payload[4..<(4 + featureCount)].map(SonyConnectionAffectedFeature.init(rawValue:))
            actionType = SonyConnectionAlertActionType(rawValue: payload[4 + featureCount])
        }
        self.format = format
        messageID = payload[2]
    }

    var requestedMode: SonyConnectionMode? {
        switch (format, messageID) {
        case (.fixed, 0x74), (.fixed, 0x76): .soundQuality
        case (.fixed, 0x75), (.fixed, 0x77): .stableConnection
        case (.flexible, 0x10), (.flexible, 0x11): .lowLatency
        default: nil
        }
    }

    var isMultipointChange: Bool {
        switch (format, messageID) {
        // MDR v1 0x06: sent by a WH-1000XM4 when multipoint is turned on; LDAC is then unavailable.
        case (.fixed, 0x06), (.fixed, 0x07), (.fixed, 0x70), (.flexible, 0x01), (.legacyFixed, 0x06): true
        default: false
        }
    }

    var isLegacyConnectionChange: Bool {
        format == .legacyFixed && messageID == 0x01 && actionType == .positiveNegative
    }

    var availableActions: [SonyConnectionAlertAction] {
        guard requestedMode != nil || isMultipointChange || isLegacyConnectionChange else { return [] }
        return switch actionType {
        case .positiveNegative: [.negative, .positive]
        case .positiveConfirmationWithReply: [.positive]
        case .confirmationOnly, .unknown: []
        }
    }

    func replyPayload(_ action: SonyConnectionAlertAction) -> [UInt8]? {
        guard availableActions.contains(action) else { return nil }
        return [0x98, format.rawValue, messageID, action.rawValue]
    }
}
