import AppIntents
import SwiftUI

@main
@MainActor
enum AcoupletMain {
    static func main() {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        if CommandLine.arguments == [CommandLine.arguments[0], "--ldac-owner"] {
            LDACOwnerWorker.run()
            return
        }
        #endif
        if let status = SettingsStore.runLoginItemCommand(CommandLine.arguments) {
            exit(status)
        }
        AcoupletApp.main()
    }
}

@MainActor
struct AcoupletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        let _ = registerNavigation()
        Window("Equalizer", id: "equalizer") {
            SelectedDeviceView(devices: appDelegate.environment.devices) {
                EqualizerEditorView()
                    .environmentObject(appDelegate.environment.settings)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Acouplet") {
                    openWindow(id: "about")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        #if ACOUPLET_SPARKLE
        .commands { AppUpdateCommands(updater: appDelegate.environment.updater) }
        #endif
        Window("About Acouplet", id: "about") {
            AppAboutView()
                .environmentObject(appDelegate.environment.settings)
                #if ACOUPLET_SPARKLE
                .environmentObject(appDelegate.environment.updater)
                #endif
        }
        .defaultLaunchBehavior(.suppressed)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        Window("License", id: "license") {
            AppLegalView(paths: ["Resources/LICENSE"])
                .environmentObject(appDelegate.environment.settings)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 600, height: 480)
        Window("Third-Party Notices", id: "third-party-notices") {
            AppLegalView(paths: thirdPartyNotices, markdown: true)
                .environmentObject(appDelegate.environment.settings)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 600, height: 480)
        AppSettingsScene(environment: appDelegate.environment)
    }

    private var thirdPartyNotices: [String] {
        var paths = ["Resources/THIRD-PARTY-NOTICES.md"]
        #if ACOUPLET_SPARKLE
        paths.append("Resources/Sparkle-LICENSE.txt")
        #endif
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        paths += ["Resources/LDAC-LICENSE.txt", "Resources/LDAC-NOTICE.txt",
                  "Helpers/AcoupletLDACOutput.driver/Contents/Resources/LICENSE.txt"]
        #endif
        return paths
    }

    private func registerNavigation() {
        appDelegate.openSettings = { openSettings() }
        if #available(macOS 27.0, *) {
            let navigation = HeadphoneIntentNavigation { [appDelegate, openWindow] destination in
                switch destination {
                case .settings:
                    appDelegate.environment.settings.selectedSettingsPane = "headphones"
                    appDelegate.showSettings()
                case .equalizer:
                    openWindow(id: "equalizer")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            AppDependencyManager.shared.add(dependency: navigation)
        }
    }
}

private struct AppAboutView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    #if ACOUPLET_SPARKLE
    @EnvironmentObject private var updater: AppUpdater
    #endif

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Acouplet").font(.title2.bold())
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("about.version")
            }
            Text("Copyright © 2026 Meriç Bağlayan")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("about.copyright")
            Link("GitHub Repository", destination: URL(string: "https://github.com/baglayan/acouplet")!)
                .font(.caption)
                .accessibilityIdentifier("about.repository")
            #if ACOUPLET_SPARKLE
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
                .padding(.top, 8)
                .accessibilityIdentifier("about.checkForUpdates")
            #endif
            HStack {
                Button("License") { openWindow(id: "license") }
                    .accessibilityIdentifier("about.license")
                Button("Third-Party Notices") { openWindow(id: "third-party-notices") }
                    .accessibilityIdentifier("about.thirdPartyNotices")
            }
            .padding(.top, 8)
        }
        .frame(width: 284)
        .padding(20)
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
    }
}

private struct AppLegalView: View {
    @EnvironmentObject private var settings: SettingsStore
    private let contents: Result<AttributedString, Error>

    init(paths: [String], markdown: Bool = false) {
        contents = Result {
            var contents = AttributedString()
            for (index, path) in paths.enumerated() {
                let text = try String(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/\(path)"), encoding: .utf8)
                if index > 0 { contents += AttributedString("\n\n") }
                if markdown && index == 0 {
                    for (paragraphIndex, paragraph) in text.components(separatedBy: "\n\n").enumerated() {
                        if paragraphIndex > 0 { contents += AttributedString("\n\n") }
                        let heading = paragraph.hasPrefix("# ") ? 1 : paragraph.hasPrefix("## ") ? 2 : 0
                        let body = heading == 0 ? paragraph : String(paragraph.dropFirst(heading + 1))
                        var styled = try AttributedString(markdown: body.replacingOccurrences(of: "\n", with: " "),
                                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                        if heading == 1 { styled.font = .title2.bold() }
                        if heading == 2 { styled.font = .headline }
                        contents += styled
                    }
                } else {
                    contents += AttributedString(text)
                }
            }
            return contents
        }
    }

    var body: some View {
        switch contents {
        case .success(let text):
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .accessibilityIdentifier("legal.contents")
            }
            .frame(minWidth: 360, minHeight: 240)
            .accentColor(settings.tintColor)
            .tint(settings.tintColor)
        case .failure(let error):
            ContentUnavailableView("Document Could Not Be Opened", systemImage: "doc.text",
                                   description: Text(error.localizedDescription))
        }
    }
}

#if ACOUPLET_SPARKLE
private struct AppUpdateCommands: Commands {
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
#endif

#if DEBUG
struct UITestHostView: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator
    @State private var settingsLifecycleSnapshot = ""
    let showSettings: () -> Void
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    let noiseModeHUD: SonyNoiseModeHUD
    let ldac: LDACController
    #endif

    var body: some View {
        VStack(spacing: 0) {
            MenuBarView(showSettings: showSettings)
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                .environmentObject(ldac)
                #endif
                .environment(\.appearsActive, true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("test.mainPanel")
            if SettingsLifecycleProbe.isEnabled {
                HStack {
                    Button("Open Settings", action: showSettings)
                    Button("Snapshot Settings Lifecycle") { settingsLifecycleSnapshot = SettingsLifecycleProbe.snapshot }
                    Button("Schedule Settings Refresh") {
                        let timer = Timer(timeInterval: 4, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                for _ in 0..<5 { headphones.simulateAutomaticRefresh() }
                                headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x15, 0x02, 0x10]))
                            }
                        }
                        RunLoop.main.add(timer, forMode: .common)
                    }
                    ForEach([("Publish SBC", UInt8(0x01)), ("Publish LDAC", UInt8(0x10))], id: \.0) { title, codec in
                        Button(title) {
                            headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x15, 0x02, codec]))
                        }
                    }
                }
                .controlSize(.mini)
                Text(settingsLifecycleSnapshot).accessibilityIdentifier("test.settingsLifecycle")
                Text(headphones.audioFeatures.codec?.title ?? "Unknown").accessibilityIdentifier("test.settingsCodec")
            }
            if CommandLine.arguments.contains("--connection-lifecycle") {
                HStack {
                    Button("Connect WF") { headphones.simulateDeviceConnection(named: "WF-1000XM5") }
                        .accessibilityIdentifier("test.connectWF")
                    Button("Controls Busy") { headphones.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true) }
                        .accessibilityIdentifier("test.controlsBusy")
                    Button("Schedule Retry") { headphones.simulateScheduledRetry() }
                        .accessibilityIdentifier("test.scheduleRetry")
                    Button("Connect WH") { headphones.simulateDeviceConnection(named: "WH-1000XM5") }
                    Button("Disconnect") { headphones.simulateDeviceConnection(named: nil) }
                }
                .controlSize(.mini)
            }
            if CommandLine.arguments.contains("--optional-read-timeout") {
                HStack {
                    Button("Open Settings", action: showSettings)
                        .accessibilityIdentifier("test.optionalRead.settings")
                    ForEach(["begin", "expire", "rehandshake", "recover"], id: \.self) { action in
                        Button(action) { headphones.simulateOptionalReadUITest(action) }
                            .accessibilityIdentifier("test.optionalRead.\(action)")
                    }
                }
                .controlSize(.mini)
            }
            if CommandLine.arguments.contains("--multiple-devices") {
                Button("Disconnect Other Headphones") {
                    devices.reconcileConnectedDevices(devices.connectedDevices.filter { $0.address == devices.selectedAddress })
                }
                .controlSize(.mini)
            }
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            if CommandLine.arguments.contains("--noise-hud-preview") {
                Button("Preview Noise Change") {
                    noiseModeHUD.show(SonyNoiseModeChange(deviceID: SonyBLEIdentity.normalizedAddress(headphones.address),
                                                         session: headphones.notificationSession, deviceName: headphones.deviceName,
                                                         previousMode: .off, mode: .anc, isUnsolicited: true,
                                                         hasLocalCommand: false)!, headphones: headphones)
                }
                Button("Preview Noise Replacement") {
                    noiseModeHUD.dismiss()
                    noiseModeHUD.show(SonyNoiseModeChange(deviceID: SonyBLEIdentity.normalizedAddress(headphones.address),
                                                         session: headphones.notificationSession, deviceName: headphones.deviceName,
                                                         previousMode: .anc, mode: .ambient, isUnsolicited: true,
                                                         hasLocalCommand: false)!, headphones: headphones)
                }
                ForEach([("Preview Low Battery", 80), ("Preview Both Low", 15)], id: \.0) { title, rightLevel in
                    Button(title) {
                        let date = Date()
                        let left = SonyLowBatteryPolicy.Reading(part: .left, level: 10, isCharging: false, observedAt: date)
                        let right = SonyLowBatteryPolicy.Reading(part: .right, level: rightLevel, isCharging: false, observedAt: date)
                        let warning = SonyLowBatteryPolicy.Warning(deviceID: SonyBLEIdentity.normalizedAddress(headphones.address)!,
                                                                   group: .earbuds, reading: left, evaluatedAt: date)
                        _ = noiseModeHUD.showLowBatteryPreview(warning: warning, readings: [left, right], headphones: headphones)
                    }
                }
                Button("Preview Firmware Update") {
                    let image = DeviceIcon.menuBarImage(model: headphones.deviceModel, leftConnected: true, rightConnected: true)
                    _ = noiseModeHUD.showNoticePreview(title: "Firmware 6.0.0 Available", detail: "Update in Sony | Sound Connect.",
                                                      image: image, headphones: headphones)
                }
            }
            #endif
        }
    }
}
#endif

struct SelectedDeviceView<Content: View>: View {
    @ObservedObject var devices: SonyDeviceCoordinator
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environmentObject(devices)
            .environmentObject(devices.selectedController)
            .id(ObjectIdentifier(devices.selectedController))
    }
}
