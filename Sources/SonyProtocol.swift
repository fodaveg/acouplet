import Foundation

enum ReconnectBackoff {
    private static let delays: [TimeInterval] = [2, 4, 8, 15, 30]

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        delays[min(max(0, attempt), delays.count - 1)]
    }
}

enum NoiseControlMode: String, CaseIterable, Identifiable, Sendable {
    case off, anc, ambient, wind

    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .anc: String(localized: "Noise Cancelling")
        case .ambient: String(localized: "Ambient")
        case .wind: String(localized: "Wind")
        }
    }

    var compactTitle: String {
        switch self {
        case .off: String(localized: "Off")
        case .anc: "ANC"
        case .ambient: String(localized: "Ambient")
        case .wind: String(localized: "Wind")
        }
    }

    var symbol: String {
        switch self {
        case .off: "circle"
        case .anc: "waveform.slash"
        case .ambient: "ear"
        case .wind: "wind"
        }
    }
}

enum EqualizerPreset: UInt8, CaseIterable, Identifiable, Sendable {
    case off = 0x00
    case rock = 0x01
    case pop = 0x02
    case jazz = 0x03
    case dance = 0x04
    case edm = 0x05
    case rnb = 0x06
    case acoustic = 0x07
    case bright = 0x10
    case excited = 0x11
    case mellow = 0x12
    case relaxed = 0x13
    case vocal = 0x14
    case trebleBoost = 0x15
    case bassBoost = 0x16
    case speech = 0x17
    case gaming = 0x20
    case fps1 = 0x21
    case fps2 = 0x22
    case fps3 = 0x23
    case heavy = 0x30
    case clear = 0x31
    case hard = 0x32
    case soft = 0x33
    case manual = 0xA0
    case user1 = 0xA1
    case user2 = 0xA2
    case user3 = 0xA3
    case user4 = 0xA4
    case user5 = 0xA5

    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .rock: String(localized: "Rock")
        case .pop: String(localized: "Pop")
        case .jazz: String(localized: "Jazz")
        case .dance: String(localized: "Dance")
        case .edm: String(localized: "EDM")
        case .rnb: String(localized: "R&B / Hip-Hop")
        case .acoustic: String(localized: "Acoustic")
        case .bright: String(localized: "Bright")
        case .excited: String(localized: "Excited")
        case .mellow: String(localized: "Mellow")
        case .relaxed: String(localized: "Relaxed")
        case .vocal: String(localized: "Vocal")
        case .trebleBoost: String(localized: "Treble Boost")
        case .bassBoost: String(localized: "Bass Boost")
        case .speech: String(localized: "Speech")
        case .gaming: String(localized: "Gaming")
        case .fps1: String(localized: "FPS 1")
        case .fps2: String(localized: "FPS 2")
        case .fps3: String(localized: "FPS 3")
        case .heavy: String(localized: "Heavy")
        case .clear: String(localized: "Clear")
        case .hard: String(localized: "Hard")
        case .soft: String(localized: "Soft")
        case .manual: String(localized: "Manual")
        case .user1: String(localized: "User 1")
        case .user2: String(localized: "User 2")
        case .user3: String(localized: "User 3")
        case .user4: String(localized: "User 4")
        case .user5: String(localized: "User 5")
        }
    }
}

struct EqualizerSettings: Codable, Equatable, Sendable {
    static let flat = EqualizerSettings(clearBass: 0, bands: [0, 0, 0, 0, 0])

    let layout: [SonyEqualizerBand]
    let levelSteps: UInt8
    var values: [Int]

    init(layout: [SonyEqualizerBand], levelSteps: UInt8, values: [Int]) {
        self.layout = layout
        self.levelSteps = levelSteps
        self.values = values
    }

    init(clearBass: Int, bands: [Int]) {
        layout = SonyEqualizerBand.legacy
        levelSteps = 21
        values = [Self.clamp(clearBass)] + (0..<5).map { index in
            Self.clamp(index < bands.count ? bands[index] : 0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case layout, levelSteps, values, clearBass, bands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.layout) {
            self.init(
                layout: try container.decode([SonyEqualizerBand].self, forKey: .layout),
                levelSteps: try container.decode(UInt8.self, forKey: .levelSteps),
                values: try container.decode([Int].self, forKey: .values)
            )
            guard values.count == layout.count, !layout.isEmpty, layout.count <= 255,
                  let range = levelRange, values.allSatisfy(range.contains) else {
                throw DecodingError.dataCorruptedError(forKey: .values, in: container,
                                                       debugDescription: "Invalid equalizer layout or levels")
            }
        } else {
            self.init(
                clearBass: try container.decode(Int.self, forKey: .clearBass),
                bands: try container.decode([Int].self, forKey: .bands)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout, forKey: .layout)
        try container.encode(levelSteps, forKey: .levelSteps)
        try container.encode(values, forKey: .values)
    }

    var levelRange: ClosedRange<Int>? {
        guard levelSteps > 1, levelSteps % 2 == 1 else { return nil }
        let center = (Int(levelSteps) - 1) / 2
        return -center...center
    }

    private var clearBassIndex: Int {
        guard let index = layout.firstIndex(of: .clearBass) else {
            preconditionFailure("This equalizer has no Clear Bass band")
        }
        return index
    }

    var clearBass: Int {
        get { values[clearBassIndex] }
        set { self[clearBassIndex] = newValue }
    }

    var bands: [Int] {
        layout.indices.filter { layout[$0] != .clearBass }.map { values[$0] }
    }

    subscript(_ index: Int) -> Int {
        get { values[index] }
        set {
            if let range = levelRange {
                values[index] = max(range.lowerBound, min(range.upperBound, newValue))
            } else {
                values[index] = newValue
            }
        }
    }

    subscript(band index: Int) -> Int {
        get { bands[index] }
        set { self[layout.indices.filter { layout[$0] != .clearBass }[index]] = newValue }
    }

    init?(sonyPayload: [UInt8]) {
        guard sonyPayload.count == 10,
              sonyPayload[1] == 0x00,
              sonyPayload[2] == EqualizerPreset.manual.rawValue,
              sonyPayload[3] == 0x06,
              sonyPayload[4...].allSatisfy({ $0 <= 20 }) else { return nil }
        self.init(
            clearBass: Int(sonyPayload[4]) - 10,
            bands: sonyPayload[5..<10].map { Int($0) - 10 }
        )
    }

    private static func clamp(_ value: Int) -> Int { max(-10, min(10, value)) }
}

struct SonyFrame: Equatable, Sendable {
    let type: UInt8
    let sequence: UInt8
    let payload: [UInt8]
}

enum SonyFrameCodec {
    static let header: UInt8 = 0x3E
    static let trailer: UInt8 = 0x3C
    static let escape: UInt8 = 0x3D
    private static let escapeMask: UInt8 = 0xEF

    static func encode(type: UInt8, sequence: UInt8, payload: [UInt8]) -> Data {
        let count = UInt32(payload.count)
        var body: [UInt8] = [
            type, sequence,
            UInt8((count >> 24) & 0xFF), UInt8((count >> 16) & 0xFF),
            UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF),
        ]
        body.append(contentsOf: payload)
        body.append(body.reduce(0, &+))

        var encoded = [header]
        for byte in body {
            if byte == header || byte == trailer || byte == escape {
                encoded += [escape, byte & escapeMask]
            } else {
                encoded.append(byte)
            }
        }
        encoded.append(trailer)
        return Data(encoded)
    }

    static func decode(_ data: Data) -> SonyFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, bytes.first == header, bytes.last == trailer else { return nil }
        var raw: [UInt8] = []
        var index = 1
        while index < bytes.count - 1 {
            var byte = bytes[index]
            if byte == escape {
                index += 1
                guard index < bytes.count - 1 else { return nil }
                byte = bytes[index] | ~escapeMask
            }
            raw.append(byte)
            index += 1
        }
        guard raw.count >= 7, raw[1] <= 1, raw.last == raw.dropLast().reduce(0, &+) else { return nil }
        let length = Int(UInt32(raw[2]) << 24 | UInt32(raw[3]) << 16 | UInt32(raw[4]) << 8 | UInt32(raw[5]))
        guard length == raw.count - 7 else { return nil }
        return SonyFrame(type: raw[0], sequence: raw[1], payload: Array(raw[6..<(6 + length)]))
    }
}

struct SonyFrameStream: Sendable {
    static let maximumFrameLength = 65_536
    private var buffer = Data()
    private var transmissionID: UUID?

    mutating func append(_ data: Data) -> [SonyFrame] {
        append(data, transmissionID: nil).map(\.frame)
    }

    mutating func append(_ data: Data, transmissionID: UUID?) -> [(frame: SonyFrame, transmissionID: UUID?)] {
        var frames: [(frame: SonyFrame, transmissionID: UUID?)] = []
        for byte in data {
            if byte == SonyFrameCodec.header {
                buffer.removeAll(keepingCapacity: true)
                self.transmissionID = transmissionID
            }
            guard byte == SonyFrameCodec.header || !buffer.isEmpty else { continue }
            buffer.append(byte)
            if byte == SonyFrameCodec.trailer {
                if let frame = SonyFrameCodec.decode(buffer) { frames.append((frame, self.transmissionID)) }
                buffer.removeAll(keepingCapacity: true)
            } else if buffer.count == Self.maximumFrameLength {
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }
}

enum SonyDeviceModel: String, CaseIterable, Sendable {
    case wfXM6, wfXM5, wfXM4, wfXM3, wf1000X
    case wfL900, wfLC900, wfLS910N, wfL910, wfLS900N, wfL900UC
    case wfC500, wfC510, wfC700N, wfC710N, wfH800, wfSP700N, wfSP800N, wfSP900
    case whXM6, whXM5, whXM4, whXM4C, whXM3, whXM2, wh1000XX
    case whCH520, whCH530, whCH535, whCH700N, whCH720N, whCH730N, whCH735N
    case whH800, whH810, whH900N, whH910N, whXB700, whXB900N, whXB910N, whULT900N
    case mdrXB950B1, mdrXB950N1, wi1000X, wi1000XM2, wiC100, wiC600N, wiH700, wiSP600N
    case wfG700N, whG910N
    case htAN7, srsLS1, srsNS7, srsNS7R, srsULT10, srsULT30, srsULT50, srsULT70
    case srsULT500, srsULT700, srsULT900, srsULT900AC, srsULT1000, srsULT3000
    case unknown

    enum FormFactor: Sendable {
        case earbuds, onEarHeadphones, overEarHeadphones, neckbandEarbuds
        case neckbandSpeaker, portableSpeaker, towerSpeaker, unknown
    }

    private static let namePatterns: [(model: Self, aliases: [(name: String, expression: NSRegularExpression)])] = allCases.map { model in
        (model, model.names.map { alias in
            let suffix: String
            switch alias {
            case "LINKBUDS": suffix = "(?![A-Z0-9]|\\s+[A-Z0-9])"
            case "WH-CH530", "WH-CH730N": suffix = "(?![A-Z0-9]|\\s+SERIES(?![A-Z0-9]))"
            default: suffix = "(?![A-Z0-9])"
            }
            let pattern = "(?<![A-Z0-9])" + NSRegularExpression.escapedPattern(for: alias) + suffix
            return (alias, try! NSRegularExpression(pattern: pattern))
        })
    }

    init(name: String) {
        let name = name.uppercased()
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        let matches = Self.namePatterns.filter { model in
            model.aliases.contains { alias in
                name.contains(alias.name) && alias.expression.firstMatch(in: name, range: range) != nil
            }
        }
        self = matches.count == 1 ? matches[0].model : .unknown
    }

    var name: String {
        switch self {
        case .wfXM6: "WF-1000XM6"
        case .wfXM5: "WF-1000XM5"
        case .wfXM4: "WF-1000XM4"
        case .wfXM3: "WF-1000XM3"
        case .whXM6: "WH-1000XM6"
        case .whXM5: "WH-1000XM5"
        case .whXM4: "WH-1000XM4"
        case .whXM3: "WH-1000XM3"
        case .whCH720N: "WH-CH720N"
        case .whULT900N: "ULT WEAR"
        case .wh1000XX: "1000X THE COLLEXION"
        case .wf1000X: "WF-1000X"
        case .wfL900: "WF-L900"
        case .wfLC900: "WF-LC900"
        case .wfLS910N: "WF-LS910N"
        case .wfL910: "WF-L910"
        case .wfLS900N: "WF-LS900N"
        case .wfL900UC: "WF-L900UC"
        case .wfC500: "WF-C500"
        case .wfC510: "WF-C510"
        case .wfC700N: "WF-C700N"
        case .wfC710N: "WF-C710N"
        case .wfH800: "WF-H800"
        case .wfSP700N: "WF-SP700N"
        case .wfSP800N: "WF-SP800N"
        case .wfSP900: "WF-SP900"
        case .whXM4C: "WH-1000XM4C"
        case .whXM2: "WH-1000XM2"
        case .whCH520: "WH-CH520"
        case .whCH530: "WH-CH530"
        case .whCH535: "WH-CH535"
        case .whCH700N: "WH-CH700N"
        case .whCH730N: "WH-CH730N"
        case .whCH735N: "WH-CH735N"
        case .whH800: "WH-H800"
        case .whH810: "WH-H810"
        case .whH900N: "WH-H900N"
        case .whH910N: "WH-H910N"
        case .whXB700: "WH-XB700"
        case .whXB900N: "WH-XB900N"
        case .whXB910N: "WH-XB910N"
        case .mdrXB950B1: "MDR-XB950B1"
        case .mdrXB950N1: "MDR-XB950N1"
        case .wi1000X: "WI-1000X"
        case .wi1000XM2: "WI-1000XM2"
        case .wiC100: "WI-C100"
        case .wiC600N: "WI-C600N"
        case .wiH700: "WI-H700"
        case .wiSP600N: "WI-SP600N"
        case .wfG700N: "WF-G700N"
        case .whG910N: "WH-G910N"
        case .htAN7: "HT-AN7"
        case .srsLS1: "SRS-LS1"
        case .srsNS7: "SRS-NS7"
        case .srsNS7R: "SRS-NS7R"
        case .srsULT10: "SRS-ULT10"
        case .srsULT30: "SRS-ULT30"
        case .srsULT50: "SRS-ULT50"
        case .srsULT70: "SRS-ULT70"
        case .srsULT500: "SRS-ULT500"
        case .srsULT700: "SRS-ULT700"
        case .srsULT900: "SRS-ULT900"
        case .srsULT900AC: "SRS-ULT900AC"
        case .srsULT1000: "SRS-ULT1000"
        case .srsULT3000: "SRS-ULT3000"
        case .unknown: String(localized: "Sony audio device")
        }
    }

    private var names: [String] {
        switch self {
        case .wfL900: [name, "LINKBUDS"]
        case .wfLC900: [name, "LINKBUDS CLIP"]
        case .wfLS910N: [name, "LINKBUDS FIT"]
        case .wfL910: [name, "LINKBUDS OPEN"]
        case .wfLS900N: [name, "LINKBUDS S"]
        case .wfL900UC: [name, "LINKBUDS UC"]
        case .wfG700N: [name, "INZONE BUDS"]
        case .whG910N: [name, "INZONE H9 II"]
        case .htAN7: [name, "BRAVIA THEATRE U"]
        case .srsLS1: [name, "LINKBUDS SPEAKER"]
        case .srsULT10: [name, "ULT FIELD 1"]
        case .srsULT30: [name, "ULT FIELD 3"]
        case .srsULT50: [name, "ULT FIELD 5"]
        case .srsULT70: [name, "ULT FIELD 7"]
        case .srsULT500: [name, "ULT TOWER 5"]
        case .srsULT700: [name, "ULT TOWER 7"]
        case .srsULT900: [name, "ULT TOWER 9"]
        case .srsULT900AC: [name, "ULT TOWER 9AC"]
        case .srsULT1000: [name, "ULT TOWER 10"]
        case .srsULT3000: [name, "ULT TOWER MAX"]
        case .whULT900N: [name, "WH-ULT900N"]
        case .wh1000XX: [name, "WH-1000XX"]
        case .unknown: []
        default: [name]
        }
    }

    var formFactor: FormFactor {
        switch self {
        case .wfXM6, .wfXM5, .wfXM4, .wfXM3, .wf1000X,
             .wfL900, .wfLC900, .wfLS910N, .wfL910, .wfLS900N, .wfL900UC,
             .wfC500, .wfC510, .wfC700N, .wfC710N, .wfH800, .wfSP700N, .wfSP800N, .wfSP900, .wfG700N: .earbuds
        case .whCH520, .whCH530, .whCH535, .whH800, .whH810, .whXB700: .onEarHeadphones
        case .whXM6, .whXM5, .whXM4, .whXM4C, .whXM3, .whXM2, .wh1000XX,
             .whCH700N, .whCH720N, .whCH730N, .whCH735N, .whH900N, .whH910N,
             .whXB900N, .whXB910N, .whULT900N, .mdrXB950B1, .mdrXB950N1, .whG910N: .overEarHeadphones
        case .wi1000X, .wi1000XM2, .wiC100, .wiC600N, .wiH700, .wiSP600N: .neckbandEarbuds
        case .htAN7, .srsNS7, .srsNS7R: .neckbandSpeaker
        case .srsLS1, .srsULT10, .srsULT30, .srsULT50, .srsULT70: .portableSpeaker
        case .srsULT500, .srsULT700, .srsULT900, .srsULT900AC, .srsULT1000, .srsULT3000: .towerSpeaker
        case .unknown: .unknown
        }
    }

    var isEarbuds: Bool { formFactor == .earbuds }

    /// Models that stop offering an LDAC audio endpoint while multipoint is on. A WH-1000XM4 on firmware 3.0.1 warns
    /// with MDR v1 alert 0x06 when multipoint is turned on and then lists only SBC and AAC sinks.
    var offersLDACOnlyWithoutMultipoint: Bool { self == .whXM4 }

    var isSpeaker: Bool {
        switch formFactor {
        case .neckbandSpeaker, .portableSpeaker, .towerSpeaker: true
        default: false
        }
    }

    var systemSymbol: String {
        switch formFactor {
        case .earbuds, .neckbandEarbuds: "earbuds.stemless"
        case .onEarHeadphones, .overEarHeadphones: "headphones"
        case .neckbandSpeaker, .portableSpeaker, .towerSpeaker: "hifispeaker"
        case .unknown: "speaker.wave.2"
        }
    }

    var symbol: String? {
        switch self {
        case .wfXM6: "WFXM6Earbuds"
        case .wfXM5: "Earbuds"
        case .wfXM4: "WFXM4Earbuds"
        case .wfXM3: "WFXM3Earbuds"
        case .wf1000X: "WF1000XEarbuds"
        case .wfL900: "WFL900Earbuds"
        case .wfLC900: "WFLC900Earbuds"
        case .wfLS910N: "WFLS910NEarbuds"
        case .wfL910: "WFL910Earbuds"
        case .wfLS900N: "WFLS900NEarbuds"
        case .wfL900UC: "WFL900UCEarbuds"
        case .wfC500: "WFC500Earbuds"
        case .wfC510: "WFC510Earbuds"
        case .wfC700N: "WFC700NEarbuds"
        case .wfC710N: "WFC710NEarbuds"
        case .wfH800: "WFH800Earbuds"
        case .wfSP700N: "WFSP700NEarbuds"
        case .wfSP800N: "WFSP800NEarbuds"
        case .wfSP900: "WFSP900Earbuds"
        case .whXM6: "WHXM6Headphones"
        case .whXM5: "WHXM5Headphones"
        case .whXM4: "WHXM4Headphones"
        case .whXM4C: "WHXM4CHeadphones"
        case .whXM3: "WHXM3Headphones"
        case .whXM2: "WHXM2Headphones"
        case .wh1000XX: "WH1000XXHeadphones"
        case .whCH520: "WHCH520Headphones"
        case .whCH530: "WHCH530Headphones"
        case .whCH535: "WHCH535Headphones"
        case .whCH700N: "WHCH700NHeadphones"
        case .whCH720N: "WHCH720NHeadphones"
        case .whCH730N: "WHCH730NHeadphones"
        case .whCH735N: "WHCH735NHeadphones"
        case .whH800: "WHH800Headphones"
        case .whH810: "WHH810Headphones"
        case .whH900N: "WHH900NHeadphones"
        case .whH910N: "WHH910NHeadphones"
        case .whXB700: "WHXB700Headphones"
        case .whXB900N: "WHXB900NHeadphones"
        case .whXB910N: "WHXB910NHeadphones"
        case .whULT900N: "WHULT900NHeadphones"
        case .mdrXB950B1: "MDRXB950B1Headphones"
        case .mdrXB950N1: "MDRXB950N1Headphones"
        case .wi1000X: "WI1000XEarbuds"
        case .wi1000XM2: "WI1000XM2Earbuds"
        case .wiC100: "WIC100Earbuds"
        case .wiC600N: "WIC600NEarbuds"
        case .wiH700: "WIH700Earbuds"
        case .wiSP600N: "WISP600NEarbuds"
        case .wfG700N: "WFG700NEarbuds"
        case .whG910N: "WHG910NHeadphones"
        case .htAN7: "HTAN7Speaker"
        case .srsLS1: "SRSLS1Speaker"
        case .srsNS7: "SRSNS7Speaker"
        case .srsNS7R: "SRSNS7RSpeaker"
        case .srsULT10: "SRSULT10Speaker"
        case .srsULT30: "SRSULT30Speaker"
        case .srsULT50: "SRSULT50Speaker"
        case .srsULT70: "SRSULT70Speaker"
        case .srsULT500: "SRSULT500Speaker"
        case .srsULT700: "SRSULT700Speaker"
        case .srsULT900: "SRSULT900Speaker"
        case .srsULT900AC: "SRSULT900ACSpeaker"
        case .srsULT1000: "SRSULT1000Speaker"
        case .srsULT3000: "SRSULT3000Speaker"
        case .unknown: nil
        }
    }

    var leftSymbol: String? {
        switch self {
        case .wfXM6: "WFXM6EarbudLeft"
        case .wfXM5: "EarbudLeft"
        case .wfXM4: "WFXM4EarbudLeft"
        case .wfXM3: "WFXM3EarbudLeft"
        case .wf1000X: "WF1000XEarbudLeft"
        case .wfL900: "WFL900EarbudLeft"
        case .wfLC900: "WFLC900EarbudLeft"
        case .wfLS910N: "WFLS910NEarbudLeft"
        case .wfL910: "WFL910EarbudLeft"
        case .wfLS900N: "WFLS900NEarbudLeft"
        case .wfL900UC: "WFL900UCEarbudLeft"
        case .wfC500: "WFC500EarbudLeft"
        case .wfC510: "WFC510EarbudLeft"
        case .wfC700N: "WFC700NEarbudLeft"
        case .wfC710N: "WFC710NEarbudLeft"
        case .wfH800: "WFH800EarbudLeft"
        case .wfSP700N: "WFSP700NEarbudLeft"
        case .wfSP800N: "WFSP800NEarbudLeft"
        case .wfSP900: "WFSP900EarbudLeft"
        case .wfG700N: "WFG700NEarbudLeft"
        default: nil
        }
    }

    var rightSymbol: String? {
        switch self {
        case .wfXM6: "WFXM6EarbudRight"
        case .wfXM5: "EarbudRight"
        case .wfXM4: "WFXM4EarbudRight"
        case .wfXM3: "WFXM3EarbudRight"
        case .wf1000X: "WF1000XEarbudRight"
        case .wfL900: "WFL900EarbudRight"
        case .wfLC900: "WFLC900EarbudRight"
        case .wfLS910N: "WFLS910NEarbudRight"
        case .wfL910: "WFL910EarbudRight"
        case .wfLS900N: "WFLS900NEarbudRight"
        case .wfL900UC: "WFL900UCEarbudRight"
        case .wfC500: "WFC500EarbudRight"
        case .wfC510: "WFC510EarbudRight"
        case .wfC700N: "WFC700NEarbudRight"
        case .wfC710N: "WFC710NEarbudRight"
        case .wfH800: "WFH800EarbudRight"
        case .wfSP700N: "WFSP700NEarbudRight"
        case .wfSP800N: "WFSP800NEarbudRight"
        case .wfSP900: "WFSP900EarbudRight"
        case .wfG700N: "WFG700NEarbudRight"
        default: nil
        }
    }

    var caseSymbol: String? {
        switch self {
        case .wfXM6: "WFXM6CaseSymbol"
        case .wfXM5: "WFXM5CaseSymbol"
        case .wfXM4: "WFXM4CaseSymbol"
        case .wfXM3: "WFXM3CaseSymbol"
        case .wf1000X: "WF1000XCaseSymbol"
        case .wfL900: "WFL900CaseSymbol"
        case .wfLC900: "WFLC900CaseSymbol"
        case .wfLS910N: "WFLS910NCaseSymbol"
        case .wfL910: "WFL910CaseSymbol"
        case .wfLS900N: "WFLS900NCaseSymbol"
        case .wfL900UC: "WFL900UCCaseSymbol"
        case .wfC500: "WFC500CaseSymbol"
        case .wfC510: "WFC510CaseSymbol"
        case .wfC700N: "WFC700NCaseSymbol"
        case .wfC710N: "WFC710NCaseSymbol"
        case .wfH800: "WFH800CaseSymbol"
        case .wfSP700N: "WFSP700NCaseSymbol"
        case .wfSP800N: "WFSP800NCaseSymbol"
        case .wfSP900: "WFSP900CaseSymbol"
        case .wfG700N: "WFG700NCaseSymbol"
        default: nil
        }
    }

    var filledCaseSymbol: String? { caseSymbol.map { $0 + "Fill" } }

    var artwork: String? {
        #if ACOUPLET_NO_SONY_ARTWORK
        nil
        #else
        switch self {
        case .wfXM5: "WFXM5Hero"
        case .whXM5: "XM5Hero"
        case .wfXM6, .wfXM4, .wfXM3, .whXM6, .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX: rawValue + "Product"
        default: nil
        }
        #endif
    }

    func artworkSuffix(for color: SonyDeviceColor?) -> String? {
        switch (self, color?.rawValue) {
        case (.wfXM6, 0x01), (.wfXM5, 0x01), (.wfXM4, 0x01), (.wfXM3, 0x01),
             (.whXM6, 0x01), (.whXM5, 0x01), (.whXM4, 0x01), (.whXM3, 0x01),
             (.whCH720N, 0x01), (.whULT900N, 0x01), (.wh1000XX, 0x01): ""
        case (.wfXM5, 0x03), (.wfXM4, 0x03), (.whXM5, 0x03), (.whXM4, 0x03), (.whXM3, 0x03): "Silver"
        case (.whCH720N, 0x02): "White"
        case (.whCH720N, 0x05): "Blue"
        case (.whCH720N, 0x06): "Pink"
        default: nil
        }
    }

    #if DEBUG
    var galleryArtworkFinishes: [String: String] {
        switch self {
        case .wfXM6, .wfXM4, .wfXM3: ["black": "", "platinum-silver": "Silver"]
        case .wfXM5: ["black": "", "platinum-silver": "Silver", "smoky-pink": "SmokyPink"]
        case .whXM6: ["black": "", "platinum-silver": "Silver", "midnight-blue": "MidnightBlue",
                      "sand-pink": "SandPink", "sandstone": "Sandstone", "olive-gray": "OliveGray"]
        case .whXM5: ["black": "", "platinum-silver": "Silver", "midnight-blue": "MidnightBlue", "smoky-pink": "SmokyPink"]
        case .whXM4: ["black": "", "platinum-silver": "Silver", "midnight-blue": "MidnightBlue", "silent-white": "SilentWhite"]
        case .whXM3: ["black": "", "silver": "Silver"]
        case .whCH720N: ["black": "", "white": "White", "blue": "Blue", "pink": "Pink"]
        case .whULT900N: ["black": "", "forest-gray": "ForestGray", "off-white": "OffWhite"]
        case .wh1000XX: ["black": "", "platinum": "Platinum"]
        default: [:]
        }
    }
    #endif
}

struct SonyProtocolInfo: Equatable, Sendable {
    enum Generation: String, Sendable { case v1, v2 }

    let generation: Generation
    let version: UInt32
    let supportsTable1: Bool
    let supportsTable2: Bool

    init?(payload: [UInt8]) {
        guard payload.prefix(2) == [0x01, 0x00] else { return nil }
        switch payload.count {
        case 4:
            generation = .v1
            version = UInt32(payload[2]) << 8 | UInt32(payload[3])
            supportsTable1 = true
            supportsTable2 = false
        case 8:
            guard payload[6] <= 1, payload[7] <= 1 else { return nil }
            generation = .v2
            version = payload[2...5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            supportsTable1 = payload[6] == 0
            supportsTable2 = payload[7] == 0
        default:
            return nil
        }
    }
}

struct SonyDeviceColor: Equatable, Sendable {
    let rawValue: UInt8

    var title: String {
        if rawValue == 0 { return String(localized: "Default") }
        let names = [String(localized: "Black"), String(localized: "White"), String(localized: "Silver"), String(localized: "Red"), String(localized: "Blue"), String(localized: "Pink"), String(localized: "Yellow"),
                     String(localized: "Green"), String(localized: "Gray"), String(localized: "Gold"), String(localized: "Cream"), String(localized: "Orange"), String(localized: "Brown"), String(localized: "Violet")]
        let code = Int(rawValue & 0x0F)
        guard (1...14).contains(code), rawValue < 0x20 else {
            return String(format: String(localized: "Unknown (0x%02X)"), rawValue)
        }
        return names[code - 1] + (rawValue >= 0x10 ? "-I" : "")
    }
}

struct SonyDeviceInformation: Equatable, Sendable {
    private(set) var modelName: String?
    private(set) var series: UInt8?
    private(set) var color: SonyDeviceColor?

    var model: SonyDeviceModel? { modelName.map(SonyDeviceModel.init(name:)) }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 4, payload[0] == 0x05 else { return false }
        switch payload[1] {
        case 0x01:
            guard (1...128).contains(payload[2]), payload.count == Int(payload[2]) + 3,
                  let value = String(bytes: payload.dropFirst(3), encoding: .utf8),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            modelName = value
        case 0x03:
            guard payload.count == 4 else { return false }
            series = payload[2]
            color = SonyDeviceColor(rawValue: payload[3])
        default:
            return false
        }
        return true
    }
}

struct BatteryReading: Equatable, Sendable {
    enum ChargingState: UInt8, Sendable {
        case notCharging = 0, charging = 1, unknown = 2, charged = 3

        var title: String {
            switch self {
            case .notCharging: String(localized: "Not charging")
            case .charging: String(localized: "Charging")
            case .unknown: String(localized: "Unknown")
            case .charged: String(localized: "Charged")
            }
        }
    }

    let level: Int
    let chargingState: ChargingState

    var isCharging: Bool { chargingState == .charging }

    init?(level: UInt8, charging: UInt8, generation: SonyProtocolInfo.Generation = .v2) {
        guard level <= 100 else { return nil }
        switch generation {
        case .v1:
            switch charging {
            case 0: chargingState = .notCharging
            case 1: chargingState = .charging
            case 0xF0: chargingState = .unknown
            default: return nil
            }
        case .v2:
            guard let state = ChargingState(rawValue: charging) else { return nil }
            chargingState = state
        }
        self.level = Int(level)
    }

    var symbol: String {
        isCharging ? "battery.100percent.bolt" : "battery.\(Int((Double(level) / 25).rounded()) * 25)percent"
    }
}

struct SonyBatteries: Equatable, Sendable {
    var single: BatteryReading?
    var left: BatteryReading?
    var right: BatteryReading?
    var caseBattery: BatteryReading?

    var level: Int? { single?.level ?? [left?.level, right?.level].compactMap { $0 }.min() }
    var isCharging: Bool { single?.isCharging ?? ([left, right].compactMap { $0 }.contains { $0.isCharging }) }

    static func queryTypes(supportedFunctions: Set<UInt8>) -> [UInt8] {
        [(UInt8(0x20), UInt8(0x28), UInt8(0x00), UInt8(0x08)),
         (0x21, 0x29, 0x01, 0x09), (0x22, 0x2A, 0x02, 0x0A)].compactMap { function, thresholdFunction, type, thresholdType in
            if supportedFunctions.contains(function) { return type }
            if supportedFunctions.contains(thresholdFunction) { return thresholdType }
            return nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 4, payload[0] == 0x23 || payload[0] == 0x25 else { return false }
        switch payload[1] {
        case 0x00, 0x08:
            guard payload.count == (payload[1] == 0x00 ? 4 : 5) else { return false }
            single = BatteryReading(level: payload[2], charging: payload[3])
            left = nil
            right = nil
        case 0x01, 0x09:
            guard payload.count == 6 || (payload[1] == 0x09 && payload.count == 8) else { return false }
            single = nil
            left = payload[2] == 0 ? nil : BatteryReading(level: payload[2], charging: payload[3])
            right = payload[4] == 0 ? nil : BatteryReading(level: payload[4], charging: payload[5])
        case 0x02, 0x0A:
            guard payload.count == 4 || (payload[1] == 0x0A && payload.count == 5) else { return false }
            caseBattery = payload[2] == 0 ? nil : BatteryReading(level: payload[2], charging: payload[3])
        default:
            return false
        }
        return true
    }
}
