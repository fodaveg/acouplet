import Foundation

/// Whether a pair of headphones offers an LDAC audio endpoint. `unknown` behaves as before: the controls stay visible.
enum LDACSupport: String, Equatable, Sendable {
    case supported, unsupported, unknown

    /// The one place that decides. Sources, strongest first:
    /// 1. The model is known to offer LDAC in some configuration (`offersLDACOnlyWithoutMultipoint`). A DISCOVER taken
    ///    while multipoint was on lists only SBC and AAC for those models, so it cannot rule them out.
    /// 2. What the last real AVDTP DISCOVER found for this device: `true` when it listed the LDAC endpoint, `false` when
    ///    it ended with `LDAC_UNAVAILABLE` without having seen one.
    /// A source built from the MDR support list would be one more parameter here.
    static func decide(modelImpliesLDAC: Bool, discovered: Bool?) -> LDACSupport {
        if modelImpliesLDAC { return .supported }
        switch discovered {
        case true?: return .supported
        case false?: return .unsupported
        case nil: return .unknown
        }
    }

    /// A stored request for LDAC never overrides `unsupported`.
    func allowsStart(requested: Bool) -> Bool { requested && self != .unsupported }
}

/// Per-device result of the last AVDTP DISCOVER, kept in the app's settings store under the normalized address.
struct LDACSupportStore {
    static let key = "ldac.discoveredSupport"
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) { self.defaults = defaults }

    var all: [String: Bool] { defaults?.dictionary(forKey: Self.key) as? [String: Bool] ?? [:] }

    func discovered(forAddress address: String) -> Bool? { all[address] }

    func record(_ supported: Bool, forAddress address: String) {
        var values = all
        values[address] = supported
        defaults?.set(values, forKey: Self.key)
    }
}

/// The line logged at `.notice` (persisted) for each MDR support-function list the app already receives.
/// It carries the model name and protocol version, never the Bluetooth address.
enum SonySupportFunctionsLog {
    static func line(generation: String, table: Int, model: String, protocolVersion: UInt32?, functions: Set<UInt8>) -> String {
        let version = protocolVersion.map { String(format: "%08X", $0) } ?? "unknown"
        let list = functions.sorted().map { String(format: "%02X", $0) }.joined(separator: " ")
        return "MDR support list generation=\(generation) table=\(table) model=\(model) protocol=\(version) count=\(functions.count) functions=\(list)"
    }
}
