#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
import Foundation
import Security

@MainActor
enum LDACDriverInstaller {
    enum State: Equatable {
        case missing
        case outdated
        case restartRequired
        case current
        case unavailable(String)
    }

    /// Resultado de validar los bundles del disco, sin consultar el driver cargado en Core Audio.
    enum Disk: Equatable, Sendable {
        case missing
        case outdated
        case installed(required: Int, installed: Int)
    }

    private nonisolated static let identifier = "dev.baglayan.Acouplet.LDACOutput"
    private nonisolated static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/AcoupletLDACOutput.driver", isDirectory: true)
    private nonisolated static let legacyURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/XM5LDACOutput.driver", isDirectory: true)
    private nonisolated static let cache = DiskCache()

    /// Guarda el último resultado correcto de la validación de firmas. La clave incluye la versión de la app y la
    /// huella (inodo, fecha y tamaño) de los ficheros de firma de los tres bundles, de modo que cualquier cambio
    /// en el driver instalado o en el embebido obliga a validar de nuevo. Los errores no se guardan.
    private final class DiskCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (key: String, disk: Disk)?

        func value(for key: String) -> Disk? {
            lock.lock(); defer { lock.unlock() }
            return entry?.key == key ? entry?.disk : nil
        }

        func store(_ disk: Disk, for key: String) {
            lock.lock(); defer { lock.unlock() }
            entry = (key, disk)
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            entry = nil
        }
    }

    /// Descarta la caché; los flujos de instalación la usan para revalidar siempre.
    nonisolated static func invalidateCache() { cache.removeAll() }

    static func inspect(bundle: Bundle = .main, useCache: Bool = true) -> State {
        do { return try state(for: validateOnDisk(bundle: bundle, useCache: useCache)) }
        catch { return .unavailable(error.localizedDescription) }
    }

    /// Como `inspect`, pero la validación de firmas (`SecStaticCodeCheckValidity`) corre fuera del hilo principal.
    /// Solo la consulta del driver cargado, que es barata, se hace de vuelta en el actor principal.
    static func inspectInBackground(bundle: Bundle = .main) async -> State {
        let result = await Task.detached(priority: .utility) { () -> Result<Disk, Error> in
            Result { try validateOnDisk(bundle: bundle) }
        }.value
        do { return try state(for: result.get()) }
        catch { return .unavailable(error.localizedDescription) }
    }

    private static func state(for disk: Disk) throws -> State {
        switch disk {
        case .missing: return .missing
        case .outdated: return .outdated
        case .installed(let required, let installed):
            return state(required: required, installed: installed, loaded: try LDACNativeOutput.driverRevision())
        }
    }

    nonisolated static func validateOnDisk(bundle: Bundle = .main, useCache: Bool = true) throws -> Disk {
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/AcoupletLDACOutput.driver", isDirectory: true)
        let key = cacheKey(bundle: bundle, bundled: bundled)
        if useCache, let hit = cache.value(for: key) { return hit }
        let team = try signingTeam(bundle: bundle)
        let development = isDevelopment(bundle: bundle)
        try validateCode(at: bundled, identifier: identifier, team: team, development: development)
        let required = try revision(at: bundled)
        guard required > 0 else { throw failure("The app’s LDAC driver is incomplete. Reinstall the app.") }
        let disk: Disk
        if FileManager.default.fileExists(atPath: installedURL.path) {
            try validateCode(at: installedURL, identifier: identifier, team: team, development: development)
            let installed = try revision(at: installedURL)
            disk = installed >= required ? .installed(required: required, installed: installed) : .outdated
        } else if FileManager.default.fileExists(atPath: legacyURL.path) {
            try validateCode(at: legacyURL, identifier: "local.xm5control.ldac-output-driver", team: team, development: development)
            disk = .outdated
        } else {
            disk = .missing
        }
        cache.store(disk, for: key)
        return disk
    }

    private nonisolated static func cacheKey(bundle: Bundle, bundled: URL) -> String {
        let version = [bundle.object(forInfoDictionaryKey: "CFBundleVersion"),
                       bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")]
            .map { ($0 as? String) ?? "-" }.joined(separator: "/")
        return ([bundle.bundleURL.path, version, String(isDevelopment(bundle: bundle))]
                + [bundled, installedURL, legacyURL].map(fingerprint)).joined(separator: "|")
    }

    /// Huella de lo que cambia al sustituir un bundle: inodo, fecha y tamaño de sus ficheros de firma y ejecutables.
    private nonisolated static func fingerprint(_ bundle: URL) -> String {
        let manager = FileManager.default
        var paths = ["", "Contents", "Contents/Info.plist", "Contents/_CodeSignature", "Contents/_CodeSignature/CodeResources", "Contents/MacOS"]
        let executables = (try? manager.contentsOfDirectory(atPath: bundle.appendingPathComponent("Contents/MacOS").path)) ?? []
        paths += executables.sorted().map { "Contents/MacOS/" + $0 }
        return paths.map { path in
            let url = path.isEmpty ? bundle : bundle.appendingPathComponent(path)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return "-" }
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.stringValue ?? "?"
            return "\(inode):\(modified):\(size)"
        }.joined(separator: ",")
    }

    static func state(required: Int, installed: Int?, loaded: Int?) -> State {
        guard let installed else { return .missing }
        guard installed >= required else { return .outdated }
        guard let loaded, loaded >= required else { return .restartRequired }
        return .current
    }

    static func openInstaller(bundle: Bundle = .main) async throws {
        try await openPackage(named: "Acouplet LDAC Output.pkg", bundle: bundle)
    }

    static func openUninstaller(bundle: Bundle = .main) async throws {
        try await openPackage(named: "Acouplet LDAC Removal.pkg", bundle: bundle)
    }

    private static func openPackage(named name: String, bundle: Bundle) async throws {
        let package = bundle.bundleURL.appendingPathComponent("Contents/Resources/" + name)
        let values = try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let expectedPackage = bundle.bundleURL.resolvingSymlinksInPath().appendingPathComponent("Contents/Resources/" + name)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              package.resolvingSymlinksInPath() == expectedPackage else {
            throw failure("The LDAC installer is missing or has been changed. Reinstall the app.")
        }
        guard let identifier = bundle.bundleIdentifier else {
            throw failure("The app’s identity could not be verified. Reinstall the app.")
        }
        let development = isDevelopment(bundle: bundle)
        try validateCode(at: bundle.bundleURL, identifier: identifier, team: signingTeam(bundle: bundle),
                         development: development, resources: true)
        let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app", isDirectory: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([package], withApplicationAt: installer, configuration: .init()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private nonisolated static func revision(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier else {
            throw failure("The LDAC driver’s identity could not be verified. Reinstall the app.")
        }
        guard let value = info["AcoupletLDACDriverRevision"] else { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              number.intValue > 0, number.doubleValue == Double(number.intValue) else {
            throw failure("The LDAC driver’s version could not be verified. Reinstall the app.")
        }
        return number.intValue
    }

    private nonisolated static func signingTeam(bundle: Bundle) throws -> String {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw failure("The app’s signing identity could not be verified. Reinstall the app.")
        }
        return team
    }

    private nonisolated static func isDevelopment(bundle: Bundle) -> Bool {
        #if DEBUG
        true
        #else
        bundle.object(forInfoDictionaryKey: "AcoupletDistribution") as? String == "development"
        #endif
    }

    private nonisolated static func validateCode(at url: URL, identifier: String, team: String, development: Bool, resources: Bool = false) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let identity = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let certificate = development ? "" : " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        let flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures | (resources ? kSecCSCheckNestedCode : kSecCSDoNotValidateResources)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString((identity + certificate) as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), requirement) == errSecSuccess else {
            throw failure("The LDAC installation’s signature could not be verified. Reinstall the app.")
        }
    }

    private nonisolated static func failure(_ message: String.LocalizationValue) -> NSError {
        NSError(domain: "LDACDriverInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: message)])
    }
}
#endif
