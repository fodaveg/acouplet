import Foundation
#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
import Darwin
import OSLog
import SwiftUI
#endif

struct SonyNoiseModeChange: Equatable {
    let deviceID: String
    let session: UInt64
    let deviceName: String
    let mode: NoiseControlMode

    init?(deviceID: String?, session: UInt64, deviceName: String, previousMode: NoiseControlMode?,
          mode: NoiseControlMode, isUnsolicited: Bool, hasLocalCommand: Bool) {
        guard let deviceID, !deviceID.isEmpty, let previousMode, previousMode != mode,
              isUnsolicited, !hasLocalCommand else { return nil }
        self.deviceID = deviceID
        self.session = session
        self.deviceName = deviceName
        self.mode = mode
    }

    func matches(deviceID: String?, session: UInt64) -> Bool {
        self.deviceID == deviceID && self.session == session
    }
}

#if !ACOUPLET_PUBLIC_APIS_ONLY
@MainActor
final class SonyNativeHUDProbe {
    static let shared = SonyNativeHUDProbe(executableURL:
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/SonyNativeHUDCheck"))
    private let executableURL: URL
    private let timeout: TimeInterval
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.baglayan.Acouplet", category: "NoiseModeHUD")
    private var result: Task<Bool, Never>?
    private var completion: CheckedContinuation<Bool, Never>?
    private var expiry: Task<Void, Never>?

    init(executableURL: URL, timeout: TimeInterval = 8) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    static func supports(version: OperatingSystemVersion) -> Bool {
        version.majorVersion > 27 || (version.majorVersion == 27 && version.minorVersion >= 2)
    }

    func check() async -> Bool {
        if let result { return await result.value }
        let result = Task { await run() }
        self.result = result
        return await result.value
    }

    private func run() async -> Bool {
        await withCheckedContinuation { completion in
            self.completion = completion
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            process.terminationHandler = { [weak self] process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                try? output.fileHandleForReading.close()
                let status = process.terminationStatus
                let passed = process.terminationReason == .exit && status == 0
                    && data == Data("ACOUPLET_NATIVE_HUD_OK\n".utf8)
                Task { @MainActor [weak self] in
                    guard let self, self.completion != nil else { return }
                    self.logger.info("Native indicator compatibility probe completed; passed=\(passed, privacy: .public), status=\(status, privacy: .public)")
                    self.finish(passed)
                }
            }
            do {
                try process.run()
                try? output.fileHandleForWriting.close()
                expiry = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    guard let self else { return }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    self.logger.error("Native indicator compatibility probe timed out")
                    self.finish(false)
                }
            } catch {
                process.terminationHandler = nil
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                logger.error("Native indicator compatibility probe could not launch: \(error.localizedDescription, privacy: .public)")
                finish(false)
            }
        }
    }

    private func finish(_ passed: Bool) {
        expiry?.cancel()
        expiry = nil
        completion?.resume(returning: passed)
        completion = nil
    }
}

@MainActor
final class SonyNoiseModeHUD {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.baglayan.Acouplet", category: "NoiseModeHUD")
    private weak var anchorView: NSView?
    private weak var headphones: SonyHeadphonesController?
    private var nativeHUD: NativeHUD?
    private var fallbackPanel: NSPanel?
    private let fallbackLifetime = BannerLifetime()
    private var attemptedLoad = false
    private var nativeCompatible = false
    private var menuVisible = false
    var onAvailable: () -> Void = {}

    init() {
        fallbackLifetime.onExpire = { [weak self] in self?.dismissFallback() }
        #if arch(arm64)
        guard SonyNativeHUDProbe.supports(version: ProcessInfo.processInfo.operatingSystemVersion) else { return }
        #if DEBUG
        if CommandLine.arguments.contains("--fallback-hud-preview") { return }
        #endif
        Task { [weak self] in
            let compatible = await SonyNativeHUDProbe.shared.check()
            guard let self else { return }
            nativeCompatible = compatible
        }
        #endif
    }

    var anchorDescription: String {
        guard let anchorView, let window = anchorView.window else { return "Menu bar anchor unavailable" }
        let frame = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        return "Menu bar anchor: visible=\(window.isVisible && !anchorView.isHiddenOrHasHiddenAncestor), frame=\(NSStringFromRect(frame))"
    }

    func show(_ change: SonyNoiseModeChange, headphones: SonyHeadphonesController) {
        guard headphones.isReady, headphones.isDeviceConnected,
              change.matches(deviceID: SonyBLEIdentity.normalizedAddress(headphones.address),
                             session: headphones.notificationSession) else { return }
        let title: String
        switch change.mode {
        case .anc: title = String(localized: "Noise Cancellation")
        case .ambient: title = String(localized: "Ambient Sound")
        case .off: title = String(localized: "Noise Control Off")
        case .wind: title = change.mode.title
        }
        guard let nativeHUD = prepareNativeHUD() else {
            if showFallback(title: title, symbol: change.mode.symbol, replacing: true) { self.headphones = headphones }
            return
        }
        let accepted = title.withCString { title in
            change.mode.symbol.withCString { symbol in
                nativeHUD.show(nativeHUD.context, title, symbol, anchorView.map { Unmanaged.passUnretained($0).toOpaque() })
            }
        }
        if accepted {
            self.headphones = headphones
            logger.info("Native mode indicator accepted; mode=\(change.mode.rawValue, privacy: .public), \(self.anchorDescription, privacy: .public)")
        } else {
            logger.error("Native mode indicator unavailable")
        }
    }

    func showLowBattery(_ warning: SonyLowBatteryPolicy.Warning, headphones: SonyHeadphonesController) -> Bool {
        guard headphones.lowBatteryNotificationDeviceID == warning.deviceID else { return false }
        return showLowBattery(warning, readings: headphones.lowBatteryReadings, headphones: headphones)
    }

    private func showLowBattery(_ warning: SonyLowBatteryPolicy.Warning, readings: [SonyLowBatteryPolicy.Reading],
                                headphones: SonyHeadphonesController) -> Bool {
        let date = Date()
        guard warning.reading.isFresh(at: date), !warning.reading.isCharging,
              let image = Self.lowBatteryImage(model: headphones.deviceModel, part: warning.reading.part, readings: readings,
                                               leftConnected: headphones.audioFeatures.leftConnected,
                                               rightConnected: headphones.audioFeatures.rightConnected, at: date) else { return false }
        let title: String
        switch warning.reading.part {
        case .headphones: title = String(localized: "Low Battery")
        case .left: title = String(localized: "Left Earbud Battery Low")
        case .right: title = String(localized: "Right Earbud Battery Low")
        case .caseBattery: title = String(localized: "Case Battery Low")
        }
        return showNotice(title: title, detail: nil, image: image, headphones: headphones,
                          batteryLevel: warning.reading.level)
    }

    func showAudioSource(_ source: SonyMultipointDevice, headphones: SonyHeadphonesController) -> Bool {
        guard headphones.isReady, headphones.isDeviceConnected, !headphones.multipoint.inventoryIsStale,
              headphones.multipoint.selectedSource == source else { return false }
        let image = DeviceIcon.menuBarImage(model: headphones.deviceModel,
                                          leftConnected: headphones.audioFeatures.leftConnected,
                                          rightConnected: headphones.audioFeatures.rightConnected)
        return showNotice(title: String(localized: "Audio source: \(source.name)"), detail: nil,
                          image: image, headphones: headphones)
    }

    func showFirmware(version: String, headphones: SonyHeadphonesController) -> Bool {
        guard headphones.firmwareUpdateSession != nil else { return false }
        let image = DeviceIcon.menuBarImage(model: headphones.deviceModel,
                                           leftConnected: headphones.audioFeatures.leftConnected,
                                           rightConnected: headphones.audioFeatures.rightConnected)
        return showNotice(title: String(localized: "Firmware \(version) Available"), detail: String(localized: "Update in Sony | Sound Connect."),
                          image: image, headphones: headphones)
    }

    /// Tells the user, without taking focus, that headphones other than the selected ones are asking for a
    /// confirmation. The menu-bar panel then offers to open Settings for them.
    func showConfirmationRequest(headphones: SonyHeadphonesController) -> Bool {
        let image = DeviceIcon.menuBarImage(model: headphones.deviceModel,
                                           leftConnected: headphones.audioFeatures.leftConnected,
                                           rightConnected: headphones.audioFeatures.rightConnected)
        return showNotice(title: String(localized: "\(headphones.deviceName) needs your confirmation"),
                          detail: String(localized: "Open Acouplet from the menu bar to respond."),
                          image: image, headphones: headphones)
    }

    #if DEBUG
    func showNoticePreview(title: String, detail: String?, image: NSImage, headphones: SonyHeadphonesController) -> Bool {
        showNotice(title: title, detail: detail, image: image, headphones: headphones)
    }

    func showLowBatteryPreview(warning: SonyLowBatteryPolicy.Warning, readings: [SonyLowBatteryPolicy.Reading],
                              headphones: SonyHeadphonesController) -> Bool {
        guard headphones.isReady, headphones.isDeviceConnected,
              SonyBLEIdentity.normalizedAddress(headphones.address) == warning.deviceID else { return false }
        return showLowBattery(warning, readings: readings, headphones: headphones)
    }
    #endif

    static func lowBatteryImage(model: SonyDeviceModel, part: SonyLowBatteryPolicy.Part,
                               readings: [SonyLowBatteryPolicy.Reading] = [], leftConnected: Bool? = nil,
                               rightConnected: Bool? = nil, at date: Date = Date()) -> NSImage? {
        if part == .left || part == .right {
            guard model.isEarbuds else { return nil }
            var batteries = SonyBatteries()
            for reading in readings where reading.isFresh(at: date) && !reading.isCharging {
                let value = BatteryReading(level: UInt8(reading.level), charging: 0)
                switch reading.part {
                case .left: batteries.left = value
                case .right: batteries.right = value
                case .headphones, .caseBattery: break
                }
            }
            return DeviceIcon.menuBarImage(model: model, leftConnected: leftConnected, rightConnected: rightConnected,
                                           batteries: batteries, foregroundColor: .white)
        }
        let name: String?
        switch part {
        case .headphones: name = model.symbol
        case .left: name = model.leftSymbol
        case .right: name = model.rightSymbol
        case .caseBattery: name = model.caseSymbol
        }
        if let image = name.flatMap(NSImage.init(named:)) { return image }
        guard model != .unknown else { return nil }
        if part == .caseBattery {
            return model.isEarbuds ? NSImage(systemSymbolName: "earbuds.case", accessibilityDescription: nil) : nil
        }
        return NSImage(systemSymbolName: model.systemSymbol, accessibilityDescription: model.name)
    }

    private func showNotice(title: String, detail: String?, image: NSImage, headphones: SonyHeadphonesController,
                            batteryLevel: Int? = nil) -> Bool {
        guard let nativeHUD = prepareNativeHUD() else {
            let accepted = showFallback(title: title, detail: detail, image: image, batteryLevel: batteryLevel)
            if accepted { self.headphones = headphones }
            return accepted
        }
        let accepted = title.withCString { title in
            if let batteryLevel {
                return nativeHUD.showBatteryNotice(nativeHUD.context, title, Unmanaged.passUnretained(image).toOpaque(),
                                                   Int32(batteryLevel), anchorView.map { Unmanaged.passUnretained($0).toOpaque() })
            }
            if let detail {
                return detail.withCString { detail in
                    nativeHUD.showNotice(nativeHUD.context, title, detail, Unmanaged.passUnretained(image).toOpaque(),
                                         anchorView.map { Unmanaged.passUnretained($0).toOpaque() })
                }
            }
            return nativeHUD.showNotice(nativeHUD.context, title, nil, Unmanaged.passUnretained(image).toOpaque(),
                                        anchorView.map { Unmanaged.passUnretained($0).toOpaque() })
        }
        if accepted { self.headphones = headphones }
        return accepted
    }

    private func prepareNativeHUD() -> NativeHUD? {
        guard !menuVisible else {
            dismiss()
            return nil
        }
        guard nativeCompatible, fallbackPanel?.isVisible != true else { return nil }
        if !attemptedLoad {
            attemptedLoad = true
            nativeHUD = loadNativeHUD()
            nativeHUD?.onAvailable = { [weak self] in
                guard let self, !menuVisible else { return }
                onAvailable()
            }
        }
        return nativeHUD
    }

    private func loadNativeHUD() -> NativeHUD? {
        #if DEBUG
        if CommandLine.arguments.contains("-ui-testing"), CommandLine.arguments.contains("--fallback-hud-preview") { return nil }
        #endif
        #if arch(arm64)
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("SonyNativeHUD.dylib"),
              let hud = NativeHUD(url: url) else {
            logger.error("Native mode indicator helper could not be loaded")
            return nil
        }
        return hud
        #else
        logger.info("Native mode indicator skipped; unsupported architecture")
        return nil
        #endif
    }

    func dismiss(for headphones: SonyHeadphonesController) {
        if self.headphones === headphones { dismiss() }
    }

    func dismissIfControllerRemoved(from controllers: [SonyHeadphonesController]) {
        if let headphones, !controllers.contains(where: { $0 === headphones }) { dismiss() }
    }

    func setMenuVisible(_ visible: Bool) {
        let wasVisible = menuVisible
        menuVisible = visible
        if visible { dismiss() }
        else if wasVisible { onAvailable() }
    }

    func setAnchorView(_ view: NSView?) {
        anchorView = view
    }

    func dismiss() {
        headphones = nil
        if let nativeHUD { nativeHUD.dismiss(nativeHUD.context) }
        dismissFallback()
    }

    static func fallbackFrame(size: NSSize, screen: NSRect, anchor: NSRect?) -> NSRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let left = max(screen.minX, min((anchor?.midX ?? screen.midX) - width / 2, screen.maxX - width))
        let top = min(anchor?.minY ?? screen.maxY, screen.maxY) - 8
        return NSRect(x: left, y: max(screen.minY, top - height), width: width, height: height)
    }

    private func showFallback(title: String, symbol: String = "", detail: String? = nil, image: NSImage? = nil,
                              batteryLevel: Int? = nil, replacing: Bool = false) -> Bool {
        guard !menuVisible, replacing || fallbackPanel?.isVisible != true else { return false }
        let anchorWindow = anchorView.flatMap { !$0.isHiddenOrHasHiddenAncestor && $0.window?.isVisible == true ? $0.window : nil }
        guard let screen = anchorWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return false }
        let anchor = anchorWindow.flatMap { window in anchorView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } }
        var useGlass = true
        #if DEBUG
        if CommandLine.arguments.contains("-ui-testing"), CommandLine.arguments.contains("--material-hud-preview") { useGlass = false }
        #endif
        let content = FallbackStatusView(title: title, symbol: symbol, detail: detail, image: image,
                                         batteryLevel: batteryLevel, useGlass: useGlass)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel: NSPanel
        if let fallbackPanel {
            panel = fallbackPanel
        } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setAccessibilityRole(.window)
            panel.setAccessibilitySubrole(.dialog)
            panel.setAccessibilityIdentifier("sony-fallback-status")
            fallbackPanel = panel
        }
        panel.title = image == nil ? String(localized: "Noise Control") : title
        panel.contentView = hosting
        panel.setFrame(Self.fallbackFrame(size: hosting.fittingSize, screen: screen.visibleFrame, anchor: anchor), display: false)
        panel.orderFrontRegardless()
        fallbackLifetime.presented()
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: detail.map { title + ". " + $0 } ?? title,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        return true
    }

    private func dismissFallback() {
        let wasVisible = fallbackPanel?.isVisible == true
        fallbackLifetime.dismissed()
        fallbackPanel?.orderOut(nil)
        if wasVisible, !menuVisible { onAvailable() }
    }

    private struct FallbackStatusView: View {
        let title: String
        let symbol: String
        let detail: String?
        let image: NSImage?
        let batteryLevel: Int?
        let useGlass: Bool

        var body: some View {
            Group {
                if #available(macOS 26.0, *), useGlass {
                    content.glassEffect(.regular, in: Capsule(style: .continuous))
                } else {
                    content.background(.ultraThinMaterial, in: Capsule(style: .continuous))
                }
            }
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(image == nil ? "sony-noise-status" : "sony-device-status")
        }

        private var content: some View {
            HStack(spacing: 7) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .renderingMode(image.isTemplate ? .template : .original)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: symbol).font(.system(size: 26))
                    }
                }
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    if let detail { Text(detail).font(.caption) }
                }
                if let batteryLevel {
                    Gauge(value: Double(batteryLevel), in: 0...100) {} currentValueLabel: {
                        Text("\(batteryLevel)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(batteryLevel <= 20 ? Color(nsColor: .systemRed) : .green)
                        .fixedSize()
                        .scaleEffect(28.0 / 58.0)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Battery level")
                        .accessibilityValue("\(batteryLevel) percent")
                        .accessibilityIdentifier("sonyHUD.batteryRing")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 66)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @MainActor
    private final class NativeHUD {
        typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
        typealias Show = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutableRawPointer?) -> Bool
        typealias ShowNotice = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool
        typealias ShowBatteryNotice = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutableRawPointer, Int32, UnsafeMutableRawPointer?) -> Bool
        typealias Available = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias SetAvailable = @convention(c) (UnsafeMutableRawPointer, Available?, UnsafeMutableRawPointer?) -> Void
        typealias Dismiss = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void

        let context: UnsafeMutableRawPointer
        let show: Show
        let showNotice: ShowNotice
        let showBatteryNotice: ShowBatteryNotice
        let dismiss: Dismiss
        var onAvailable: () -> Void = {}
        private let setAvailable: SetAvailable
        private let destroy: Destroy
        private let library: UnsafeMutableRawPointer

        init?(url: URL) {
            guard let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL),
                  let create = dlsym(library, "sony_native_hud_create"),
                  let show = dlsym(library, "sony_native_hud_show"),
                  let showNotice = dlsym(library, "sony_native_hud_show_notice"),
                  let showBatteryNotice = dlsym(library, "sony_native_hud_show_battery_notice"),
                  let setAvailable = dlsym(library, "sony_native_hud_set_available"),
                  let dismiss = dlsym(library, "sony_native_hud_dismiss"),
                  let destroy = dlsym(library, "sony_native_hud_destroy"),
                  let context = unsafeBitCast(create, to: Create.self)() else { return nil }
            self.library = library
            self.context = context
            self.show = unsafeBitCast(show, to: Show.self)
            self.showNotice = unsafeBitCast(showNotice, to: ShowNotice.self)
            self.showBatteryNotice = unsafeBitCast(showBatteryNotice, to: ShowBatteryNotice.self)
            self.dismiss = unsafeBitCast(dismiss, to: Dismiss.self)
            self.destroy = unsafeBitCast(destroy, to: Destroy.self)
            self.setAvailable = unsafeBitCast(setAvailable, to: SetAvailable.self)
            self.setAvailable(context, { context in
                let hud = Unmanaged<NativeHUD>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    hud.onAvailable()
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }

        isolated deinit {
            setAvailable(context, nil, nil)
            destroy(context)
        }
    }
}
#endif
