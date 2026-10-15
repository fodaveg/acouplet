import Combine
import Foundation
import ServiceManagement

struct SavedEqualizerProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var settings: EqualizerSettings
}

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case turkish = "tr"

    init(preferredLanguages: [String]?) {
        guard let preferredLanguages, !preferredLanguages.isEmpty else {
            self = .system
            return
        }
        self = Bundle.preferredLocalizations(from: ["en", "tr"], forPreferences: preferredLanguages).first == "tr"
            ? .turkish : .english
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var selectedSettingsPane = "general"
    @Published private(set) var appLanguage: AppLanguage
    var appLanguageNeedsRestart: Bool { appLanguage != languageAtLaunch }
    @Published var useSystemAccentColor: Bool {
        didSet { defaults.set(useSystemAccentColor, forKey: Keys.useSystemAccentColor) }
    }
    @Published var reconnectAutomatically: Bool {
        didSet { defaults.set(reconnectAutomatically, forKey: Keys.reconnectAutomatically) }
    }
    @Published var keepMenuBarIconWhenDisconnected: Bool {
        didSet { defaults.set(keepMenuBarIconWhenDisconnected, forKey: Keys.keepMenuBarIconWhenDisconnected) }
    }
    @Published var showBatteryInMenuBar: Bool {
        didSet { defaults.set(showBatteryInMenuBar, forKey: Keys.showBatteryInMenuBar) }
    }
    @Published var lowBatteryNotificationsEnabled: Bool {
        didSet { defaults.set(lowBatteryNotificationsEnabled, forKey: Keys.lowBatteryNotificationsEnabled) }
    }
    @Published var firmwareNotificationsEnabled: Bool {
        didSet { defaults.set(firmwareNotificationsEnabled, forKey: Keys.firmwareNotificationsEnabled) }
    }
    @Published var experimentalLDACEnabled: Bool {
        didSet { defaults.set(experimentalLDACEnabled, forKey: Keys.experimentalLDACEnabled) }
    }
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @Published var ldacConfiguration: LDACConfiguration {
        didSet { persist(ldacConfiguration, forKey: Keys.ldacConfiguration) }
    }
    #endif
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var backgroundServiceStatus: SMAppService.Status = .notRegistered
    @Published var backgroundServiceMigrationError: String?
    var retryBackgroundServiceMigration: (() -> Void)?
    /// Whether the app is installed with its LaunchAgent, read from the plist's real state rather than from
    /// how this copy was started (decision D9). Settings then shows the service instead of Launch at login.
    var hasBackgroundService: Bool {
        backgroundServiceStatus == .enabled || backgroundServiceStatus == .requiresApproval
    }
    /// Whether this process is the LaunchAgent's copy, which launchd starts with `--background-service`.
    var isBackgroundServiceProcess: Bool {
        CommandLine.arguments.contains("--background-service")
    }
    @Published var globalShortcutEnabled: Bool {
        didSet { defaults.set(globalShortcutEnabled, forKey: Keys.globalShortcutEnabled) }
    }
    @Published var globalShortcutError: String?
    @Published var customEqualizerDraft: EqualizerSettings {
        didSet {
            guard !isLoadingEqualizerDraft else { return }
            if let equalizerDeviceAddress {
                equalizerDraftsByDevice[equalizerDeviceAddress] = customEqualizerDraft
                persist(equalizerDraftsByDevice, forKey: Keys.equalizerDraftsByDevice)
            } else {
                persist(customEqualizerDraft, forKey: Keys.customEqualizerDraft)
            }
        }
    }
    @Published private(set) var equalizerProfiles: [SavedEqualizerProfile] {
        didSet { persist(equalizerProfiles, forKey: Keys.equalizerProfiles) }
    }

    let defaults: UserDefaults
    private var equalizerDeviceAddress: String?
    private var equalizerDraftsByDevice: [String: EqualizerSettings]
    private var isLoadingEqualizerDraft = false

    private let managesLaunchService: Bool
    private let preferencesDomain: String?
    private let languageAtLaunch: AppLanguage

    init(defaults: UserDefaults, managesLaunchService: Bool = false, preferencesDomain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.managesLaunchService = managesLaunchService
        self.preferencesDomain = preferencesDomain
        let languages = preferencesDomain.flatMap { defaults.persistentDomain(forName: $0)?[Keys.appleLanguages] as? [String] }
        let language = AppLanguage(preferredLanguages: languages)
        appLanguage = language
        languageAtLaunch = language
        useSystemAccentColor = defaults.object(forKey: Keys.useSystemAccentColor) == nil
            ? true
            : defaults.bool(forKey: Keys.useSystemAccentColor)
        keepMenuBarIconWhenDisconnected = defaults.bool(forKey: Keys.keepMenuBarIconWhenDisconnected)
        showBatteryInMenuBar = defaults.bool(forKey: Keys.showBatteryInMenuBar)
        lowBatteryNotificationsEnabled = defaults.bool(forKey: Keys.lowBatteryNotificationsEnabled)
        firmwareNotificationsEnabled = defaults.bool(forKey: Keys.firmwareNotificationsEnabled)
        experimentalLDACEnabled = defaults.bool(forKey: Keys.experimentalLDACEnabled)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        ldacConfiguration = Self.decode(LDACConfiguration.self, from: defaults.data(forKey: Keys.ldacConfiguration)) ?? LDACConfiguration()
        #endif
        reconnectAutomatically = defaults.object(forKey: Keys.reconnectAutomatically) == nil
            ? true
            : defaults.bool(forKey: Keys.reconnectAutomatically)
        launchAtLogin = managesLaunchService && SMAppService.mainApp.status == .enabled
        globalShortcutEnabled = defaults.object(forKey: Keys.globalShortcutEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.globalShortcutEnabled)
        customEqualizerDraft = Self.decode(EqualizerSettings.self, from: defaults.data(forKey: Keys.customEqualizerDraft)) ?? .flat
        equalizerDraftsByDevice = Self.decode([String: EqualizerSettings].self, from: defaults.data(forKey: Keys.equalizerDraftsByDevice)) ?? [:]
        equalizerProfiles = Self.decode([SavedEqualizerProfile].self, from: defaults.data(forKey: Keys.equalizerProfiles)) ?? []
        refreshLaunchStatus()
    }

    /// Returns true the first time a build runs, and records it so later launches of that build return false.
    ///
    /// The background service opens Settings on that launch, so the app does not look closed after an
    /// installation or update when no headphones are connected and its menu-bar icon is hidden.
    func consumeFirstLaunch(ofBuild build: String?) -> Bool {
        guard let build, !build.isEmpty, defaults.string(forKey: Keys.lastLaunchedBuild) != build else { return false }
        defaults.set(build, forKey: Keys.lastLaunchedBuild)
        return true
    }

    func setAppLanguage(_ language: AppLanguage) {
        appLanguage = language
        if language == .system {
            defaults.removeObject(forKey: Keys.appleLanguages)
        } else {
            defaults.set([language.rawValue], forKey: Keys.appleLanguages)
        }
    }

    func refreshAppLanguage() {
        let languages = preferencesDomain.flatMap { defaults.persistentDomain(forName: $0)?[Keys.appleLanguages] as? [String] }
        appLanguage = AppLanguage(preferredLanguages: languages)
    }

    static func migrateLegacyPreferences(from legacy: [String: Any], to defaults: UserDefaults, bundleIdentifier: String?) {
        let migrationKey = "migration.legacyPreferences"
        guard bundleIdentifier == "dev.baglayan.Acouplet" else { return }
        if defaults.bool(forKey: migrationKey) {
            if defaults.object(forKey: Keys.launchAtLoginDefaultApplied) == nil {
                defaults.set(true, forKey: Keys.launchAtLoginDefaultApplied)
            }
            return
        }
        let keys = ["headphones.verifiedIdentity", "headphones.verifiedIdentities", "notifications.lowBatteryHistory",
                    "SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            if key.hasPrefix("preferences.") || key.hasPrefix("firmwareUpdate.") || keys.contains(key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }

    func selectEqualizerDevice(address: String, defaultDraft: EqualizerSettings?) {
        let address = address.replacingOccurrences(of: "-", with: ":").uppercased()
        guard !address.isEmpty,
              equalizerDeviceAddress != address || (equalizerDraftsByDevice[address] == nil && defaultDraft != nil) else { return }
        let legacyDraft = equalizerDeviceAddress == nil && equalizerDraftsByDevice.isEmpty
            ? Self.decode(EqualizerSettings.self, from: defaults.data(forKey: Keys.customEqualizerDraft)) : nil
        let draft = equalizerDraftsByDevice[address] ?? legacyDraft ?? defaultDraft
        equalizerDeviceAddress = address
        isLoadingEqualizerDraft = draft == nil
        customEqualizerDraft = draft ?? .flat
        isLoadingEqualizerDraft = false
    }

    func refreshLaunchStatus() {
        guard managesLaunchService, let user = getpwuid(getuid()) else { return }
        let home = String(cString: user.pointee.pw_dir)
        let plist = URL(fileURLWithPath: home).appending(path: "Library/LaunchAgents/dev.baglayan.Acouplet.agent.plist")
        backgroundServiceStatus = SMAppService.statusForLegacyPlist(at: plist)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func enableLaunchAtLoginByDefault() {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        guard !hasBackgroundService, !isBackgroundServiceProcess,
              !defaults.bool(forKey: Keys.launchAtLoginDefaultApplied) else { return }
        defaults.set(true, forKey: Keys.launchAtLoginDefaultApplied)
        if !managesLaunchService || SMAppService.mainApp.status == .notRegistered {
            setLaunchAtLogin(true)
        }
        #endif
    }

    /// Runs the installer's `--unregister-login-item` or `--register-login-item` command and returns its exit
    /// status, or returns nil for any other launch.
    ///
    /// `AcoupletMain` calls this before `NSApplication` exists, so these short-lived processes never register
    /// with LaunchServices and a background service starting at the same time cannot take them for a running
    /// copy of the app. Unregistering prints `login-item: removed` when a registration existed, which tells
    /// the installer to give it back if the installation is rolled back.
    static func runLoginItemCommand(_ arguments: [String], defaults: UserDefaults = .standard,
                                    service: any LoginItemService = SMAppService.mainApp) -> Int32? {
        guard arguments.count == 2, ["--unregister-login-item", "--register-login-item"].contains(arguments[1]) else {
            return nil
        }
        defaults.set(true, forKey: Keys.launchAtLoginDefaultApplied)
        do {
            if arguments[1] == "--register-login-item" {
                try service.register()
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
                print("login-item: removed")
            } else {
                print("login-item: absent")
            }
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return EXIT_FAILURE
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        defaults.set(true, forKey: Keys.launchAtLoginDefaultApplied)
        guard managesLaunchService else {
            launchAtLogin = enabled
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

    @discardableResult
    func saveEqualizerProfile(named proposedName: String) -> SavedEqualizerProfile {
        let name = equalizerProfileName(for: proposedName)
        if let index = equalizerProfiles.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            equalizerProfiles[index].settings = customEqualizerDraft
            return equalizerProfiles[index]
        }
        let profile = SavedEqualizerProfile(id: UUID(), name: name, settings: customEqualizerDraft)
        equalizerProfiles.append(profile)
        return profile
    }

    func equalizerProfileName(for proposedName: String) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(32)) }
        var number = 1
        while equalizerProfiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(String(localized: "My EQ \(number)")) == .orderedSame }) {
            number += 1
        }
        return String(localized: "My EQ \(number)")
    }

    func deleteEqualizerProfile(id: UUID) {
        equalizerProfiles.removeAll { $0.id == id }
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum Keys {
        static let appleLanguages = "AppleLanguages"
        static let useSystemAccentColor = "preferences.useSystemAccentColor"
        static let keepMenuBarIconWhenDisconnected = "preferences.keepMenuBarIconWhenDisconnected"
        static let showBatteryInMenuBar = "preferences.showBatteryInMenuBar"
        static let lowBatteryNotificationsEnabled = "preferences.lowBatteryNotificationsEnabled"
        static let firmwareNotificationsEnabled = "preferences.firmwareNotificationsEnabled"
        static let experimentalLDACEnabled = "preferences.experimentalLDACEnabled"
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        static let ldacConfiguration = "preferences.ldacConfiguration"
        #endif
        static let reconnectAutomatically = "preferences.reconnectAutomatically"
        static let launchAtLoginDefaultApplied = "preferences.launchAtLoginDefaultApplied"
        static let lastLaunchedBuild = "lifecycle.lastLaunchedBuild"
        static let globalShortcutEnabled = "preferences.globalShortcutEnabled"
        static let customEqualizerDraft = "preferences.customEqualizerDraft"
        static let equalizerDraftsByDevice = "preferences.equalizerDraftsByDevice"
        static let equalizerProfiles = "preferences.equalizerProfiles"
    }
}

/// The part of `SMAppService` that the installer's login-item commands use, so tests can replace it.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

#if !ACOUPLET_PUBLIC_APIS_ONLY
enum LegacyBackgroundService {
    static let label = "dev.baglayan.Acouplet.agent"
    static let migrationLabel = "dev.baglayan.Acouplet.agent.migration"
    static let policyKey = "ACOUPLET_SERVICE_POLICY"
    static let policy = "successful-exit-v1"
    static let attemptKey = "migration.backgroundService.successfulExitV1"
    static let executablePath = "/Applications/Acouplet.app/Contents/MacOS/Acouplet"

    static var domain: String { "gui/\(getuid())" }
    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static func configuration(from data: Data, executablePath: String) throws -> [String: Any] {
        let decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard var plist = decoded as? [String: Any], plist["Label"] as? String == label,
              plist["ProgramArguments"] as? [String] == [executablePath, "--background-service"],
              plist["Program"] == nil,
              plist["EnvironmentVariables"] == nil || plist["EnvironmentVariables"] is [String: String] else {
            throw failure(1)
        }
        var environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        environment[policyKey] = policy
        plist["EnvironmentVariables"] = environment
        plist["KeepAlive"] = ["SuccessfulExit": false]
        return plist
    }

    #if !DEBUG
    static func prepare(defaults: UserDefaults = .standard) throws {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "dev.baglayan.Acouplet",
              Bundle.main.executableURL?.path == executablePath,
              CommandLine.arguments.contains("--background-service"),
              environment["XPC_SERVICE_NAME"] == label || CommandLine.arguments.contains("--service-migration-recovery") else { return }
        let recovering = CommandLine.arguments.contains("--service-migration-recovery")
        if !recovering, environment[policyKey] == policy {
            defaults.removeObject(forKey: attemptKey)
            return
        }
        guard !defaults.bool(forKey: attemptKey) else { throw failure(2) }
        let contents = try configuration(from: ownedPlistData(), executablePath: executablePath)
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        let token = UUID().uuidString
        let directory = migrationDirectory(token: token)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { removeMigrationDirectory(directory) }
        let fifo = directory.appending(path: "result")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw failure(3) }
        let descriptor = open(fifo.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure(4) }
        let completion = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        reader.setEventHandler {
            var result: UInt8 = 1
            if read(descriptor, &result, 1) == 1, result == 0 { ready.signal() }
            completion.signal()
            reader.cancel()
        }
        reader.setCancelHandler { close(descriptor) }
        reader.resume()
        defer { reader.cancel() }
        let migration: [String: Any] = [
            "Label": migrationLabel, "ProgramArguments": [executablePath, "--migrate-background-service"],
            "RunAtLoad": true, "LaunchOnlyOnce": true,
            "EnvironmentVariables": ["ACOUPLET_MIGRATION_TOKEN": token,
                                     "ACOUPLET_MIGRATION_RECOVERY": recovering ? "1" : "0",
                                     "ACOUPLET_MIGRATION_PARENT": String(ProcessInfo.processInfo.processIdentifier)],
        ]
        let migrationData = try PropertyListSerialization.data(fromPropertyList: migration, format: .xml, options: 0)
        let migrationURL = directory.appending(path: "agent.plist")
        try migrationData.write(to: migrationURL, options: .atomic)
        defaults.set(true, forKey: attemptKey)
        try launchctl(["bootstrap", domain, migrationURL.path])
        guard completion.wait(timeout: .now() + 15) == .success else { throw failure(5) }
        guard ready.wait(timeout: .now()) == .success, recovering else { throw failure(5) }
    }

    static func runMigration() throws {
        guard Bundle.main.bundleIdentifier == "dev.baglayan.Acouplet",
              Bundle.main.executableURL?.path == executablePath,
              ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == migrationLabel,
              let token = ProcessInfo.processInfo.environment["ACOUPLET_MIGRATION_TOKEN"],
              UUID(uuidString: token)?.uuidString == token else { throw failure(6) }
        let directory = migrationDirectory(token: token)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw failure(7) }
        let descriptor = open(directory.appending(path: "result").path, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure(8) }
        defer { close(descriptor) }
        signal(SIGPIPE, SIG_IGN)
        var oldJobRemoved = false
        do {
            try FileManager.default.removeItem(at: directory)
            let data = try ownedPlistData()
            let expected = try configuration(from: data, executablePath: executablePath)
            let actual = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
            guard actual == expected as NSDictionary else { throw failure(9) }
            if ProcessInfo.processInfo.environment["ACOUPLET_MIGRATION_RECOVERY"] == "1" {
                guard let rawPID = ProcessInfo.processInfo.environment["ACOUPLET_MIGRATION_PARENT"],
                      let parentPID = Int32(rawPID), parentPID > 0 else { throw failure(13) }
                let exited = DispatchSemaphore(value: 0)
                let parent = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global())
                parent.setEventHandler { exited.signal() }
                parent.resume()
                defer { parent.cancel() }
                var result: UInt8 = 0
                guard write(descriptor, &result, 1) == 1,
                      exited.wait(timeout: .now() + 10) == .success else { throw failure(14) }
                oldJobRemoved = true
                try launchctl(["bootstrap", domain, plistURL.path])
            } else {
                try reload(plistURL: plistURL, domain: domain, label: label) { oldJobRemoved = true }
            }
        } catch {
            NSLog("Background service migration failed: %@", error.localizedDescription)
            var result: UInt8 = 1
            let notified = write(descriptor, &result, 1) == 1
            if oldJobRemoved {
                try command("/usr/bin/open", ["-n", "/Applications/Acouplet.app", "--args",
                                              "--background-service", "--service-migration-recovery"])
            } else if !notified {
                throw error
            }
        }
    }

    private static func ownedPlistData() throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: plistURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw failure(10) }
        return try Data(contentsOf: plistURL)
    }

    private static func migrationDirectory(token: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(migrationLabel).\(token)")
    }

    private static func removeMigrationDirectory(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            NSLog("Background service migration cleanup failed: %@", error.localizedDescription)
        }
    }
    #endif

    static func reload(plistURL: URL, domain: String, label: String, didBootout: () -> Void = {}) throws {
        try launchctl(["bootout", "\(domain)/\(label)"])
        didBootout()
        try launchctl(["bootstrap", domain, plistURL.path])
    }

    static func launchctl(_ arguments: [String], quiet: Bool = false) throws {
        try command("/bin/launchctl", arguments, quiet: quiet)
    }

    private static func command(_ executable: String, _ arguments: [String], quiet: Bool = false) throws {
        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = quiet ? FileHandle.nullDevice : FileHandle.standardError
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                if completion.wait(timeout: .now() + 1) == .timedOut { throw failure(11) }
            }
            process.waitUntilExit()
            throw failure(12)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure(Int(process.terminationStatus)) }
    }

    private static func failure(_ code: Int) -> NSError {
        NSError(domain: label, code: code)
    }
}
#endif
