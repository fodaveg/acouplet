import Darwin
import Foundation
import Security

struct SonyPreferencePaneSnapshot: Codable, Equatable, Sendable {
    let serverID: UUID
    let devices: [SonyPreferencePaneDevice]
    let selectedAddress: String?
}

struct SonyPreferencePaneDevice: Codable, Equatable, Identifiable, Sendable {
    struct Option: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        var isEnabled = true
    }

    struct Choice: Codable, Equatable, Sendable {
        let current: String?
        let currentTitle: String?
        let options: [Option]
        let canSet: Bool
        let pending: Bool
        let error: String?
    }

    struct Toggle: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let enabled: Bool?
        let canSet: Bool
        let pending: Bool
        let error: String?
    }

    struct Equalizer: Codable, Equatable, Sendable {
        struct Band: Codable, Equatable, Identifiable, Sendable {
            let id: String
            let title: String
        }
        let preset: Choice
        let bands: [Band]
        let values: [Int]?
        let minimum: Int
        let maximum: Int
        let levelSteps: Int
        let canEdit: Bool
        let requiresManualSelection: Bool
        var manualPresetID: String?
    }

    struct TouchKey: Codable, Equatable, Identifiable, Sendable {
        struct Gesture: Codable, Equatable, Identifiable, Sendable {
            let id: UInt8
            let title: String
            let functionTitle: String
            let customization: Choice?
            let sharedKeyTitles: [String]
        }
        let id: UInt8
        let title: String
        let assignment: Choice
        let gestures: [Gesture]
    }

    struct Source: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let isConnected: Bool
        let isSelected: Bool
    }

    struct Volume: Codable, Equatable, Sendable {
        let value: Int
        let minimum: Int
        let maximum: Int
        let sourceAddress: String?
        let sourceTitle: String?
        let canSet: Bool
        let pending: Bool
        let error: String?
    }

    struct Battery: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let level: Int
        let isCharging: Bool
    }

    struct Noise: Codable, Equatable, Sendable {
        struct Option: Codable, Equatable, Identifiable, Sendable {
            let id: String
            let title: String
        }
        let current: String?
        let options: [Option]
        let canSet: Bool
        let pending: Bool
        let error: String?
    }

    struct Speak: Codable, Equatable, Sendable {
        let enabled: Bool?
        let canSet: Bool
        let pending: Bool
        let error: String?
    }

    let address: String
    let name: String
    let displayTitle: String
    let modelName: String
    let systemSymbol: String
    let isConnected: Bool
    let isReady: Bool
    let session: UInt64
    let batteries: [Battery]
    let noise: Noise?
    let speak: Speak?
    var firmwareVersion: String?
    var codec: String?
    var equalizer: Equalizer?
    var dsee: Choice?
    var dseeTitle: String?
    var systemFeatures: [Toggle] = []
    var touchAssignments: [TouchKey] = []
    var automaticPowerOff: Choice?
    var batteryCare: Toggle?
    var autoPowerSave: Toggle?
    var connectionQuality: Choice?
    var multipoint: Toggle?
    var sources: [Source] = []
    var listeningLevel: String?
    var volume: Volume?
    var id: String { address }
}

struct SonyPreferencePaneRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case snapshot, noise, speak, equalizerPreset, equalizer, dsee, systemFeature
        case touchAssignment, touchAction, automaticPowerOff, batteryCare, autoPowerSave, volume
    }
    let version: Int
    let id: UUID
    let action: Action
    var serverID: UUID?
    var address: String?
    var session: UInt64?
    var mode: String?
    var enabled: Bool?
    var option: String?
    var feature: UInt8?
    var key: UInt8?
    var gesture: UInt8?
    var bandIDs: [String]?
    var values: [Int]?
    var levelSteps: Int?
    var volume: Int?
    var sourceAddress: String?
}

struct SonyPreferencePaneReply: Codable, Sendable {
    let version: Int
    let id: UUID
    let snapshot: SonyPreferencePaneSnapshot?
    let error: String?
}

enum SonyPreferencePaneWire {
    static let version = 2
    static let maximumFrameSize = 65_536
    static let socketName = "sony-pane.sock"
    static let hostRequirement = "anchor apple and (identifier \"com.apple.systempreferences.legacyLoader.arm64\" or identifier \"com.apple.systempreferences.legacyLoader.x86_64\")"
    static let defaultAppTeam = "5743Y47SC7"
    /// Info.plist key where the pane builder records the team that signed the app and the pane.
    static let appTeamInfoKey = "AcoupletAppTeam"

    /// Requirement the app must meet before a pane talks to it. A missing or malformed team keeps the original team.
    static func appRequirement(team: String?) -> String {
        let team = team.flatMap { $0.range(of: "\\A[A-Z0-9]{10}\\z", options: .regularExpression) == nil ? nil : $0 } ?? defaultAppTeam
        return "anchor apple generic and identifier \"dev.baglayan.Acouplet\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SonyPreferencePane", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else {
            throw failure("The local connection path is too long.")
        }
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return value
    }

    static func authenticate(_ fd: Int32, requirement text: String) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout.size(ofValue: token))
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout.size(ofValue: token) else {
            throw failure("The local connection could not be authenticated.")
        }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw failure("The local connection has an unexpected app identity.")
        }
    }

    static func connect(path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("The local connection could not be opened.") }
        do {
            try configure(fd)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                  userInfo: [NSLocalizedDescriptionKey: "Open Acouplet to use these settings."])
                }
                try wait(fd, events: Int16(POLLOUT), deadline: ProcessInfo.processInfo.systemUptime + 3)
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: error))
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                    throw failure("Open Acouplet to use these settings.")
                }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func configure(_ fd: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw failure("The local connection could not be configured.")
        }
    }

    static func receive<T: Decodable>(_ type: T.Type, from fd: Int32, timeout: TimeInterval = 15) throws -> T {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let prefix = try read(4, from: fd, deadline: deadline)
        let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maximumFrameSize else { throw failure("The local response is too large or empty.") }
        return try JSONDecoder().decode(type, from: read(size, from: fd, deadline: deadline))
    }

    static func send<T: Encodable>(_ value: T, to fd: Int32) throws {
        let body = try JSONEncoder().encode(value)
        guard !body.isEmpty, body.count <= maximumFrameSize else { throw failure("The local message is too large.") }
        let size = UInt32(body.count)
        var packet = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        packet.append(body)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw failure("The local connection closed.") }
                offset += count
            }
        }
    }

    private static func read(_ size: Int, from fd: Int32, deadline: TimeInterval) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                try wait(fd, events: Int16(POLLIN), deadline: deadline)
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), size - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw failure("The local connection closed.") }
                offset += count
            }
        }
        return data
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw failure("The local connection timed out.") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & events != 0 else { throw failure("The local connection closed or timed out.") }
            return
        }
    }
}
