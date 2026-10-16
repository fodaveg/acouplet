import AppKit
import Combine
import os
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let devices: SonyDeviceCoordinator
    private let settings: SettingsStore
    private let showSettings: () -> Void
    #if ACOUPLET_SPARKLE
    private let updater: AppUpdater
    #endif
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private let noiseModeHUD: SonyNoiseModeHUD
    private let ldac: LDACController
    #endif
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var imageState: (model: SonyDeviceModel, leftConnected: Bool?, rightConnected: Bool?, batteries: SonyBatteries, chargingCase: Bool)?
    private var measuredContentSize = NSSize.zero
    private var wantsPopover = false
    private var retriedControllers = Set<ObjectIdentifier>()
    private var dismissalObservations = Set<AnyCancellable>()
    private var foregroundApplicationPID: Int32?
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "MenuBar")
    /// Uptime at which the status item asked for the panel; cleared once the popover is shown (G9 timing marks).
    private var openRequestedAt: TimeInterval?

    init(environment: AppEnvironment, showSettings: @escaping () -> Void) {
        let devices = environment.devices
        let settings = environment.settings
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        let ldac = environment.ldac
        #endif
        self.devices = devices
        self.settings = settings
        self.showSettings = showSettings
        #if ACOUPLET_SPARKLE
        updater = environment.updater
        #endif
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        noiseModeHUD = environment.noiseModeHUD
        self.ldac = ldac
        #endif
        super.init()
        statusItem.autosaveName = "HeadphoneControls"
        if #available(macOS 27.0, *) {
            statusItem.expandedInterfaceDelegate = self
        } else {
            statusItem.button?.target = self
            statusItem.button?.action = #selector(togglePopover)
        }
        popover.appearance = NSApp.appearance
        popover.behavior = .transient
        popover.delegate = self
        var changes = devices.objectWillChange.merge(with: settings.objectWillChange).eraseToAnyPublisher()
        #if ACOUPLET_SPARKLE
        changes = changes.merge(with: updater.objectWillChange).eraseToAnyPublisher()
        #endif
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        changes = changes.merge(with: ldac.objectWillChange).eraseToAnyPublisher()
        #endif
        observation = changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
        updateStatusItem()
    }

    func stop() {
        observation = nil
        dismissalObservations.removeAll()
        closeMenu()
        popover.close()
        releasePopoverContent()
        popover.delegate = nil
        if #available(macOS 27.0, *) { statusItem.expandedInterfaceDelegate = nil }
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        noiseModeHUD.setAnchorView(nil)
        #endif
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func preparePopoverContent() {
        guard popover.contentViewController == nil else { return }
        let settings = self.settings
        let showSettings = self.showSettings
        #if ACOUPLET_SPARKLE
        let updater = self.updater
        #endif
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        let ldac = self.ldac
        #endif
        let screenHeight = statusItem.button?.window?.screen?.visibleFrame.height
        let controller = NSHostingController(rootView: SelectedDeviceView(devices: devices) { [weak self] in
            MenuBarView(showSettings: showSettings, closeMenu: { [weak self] in self?.closeMenu() }, initialScreenHeight: screenHeight)
                .environmentObject(settings)
                #if ACOUPLET_SPARKLE
                .environmentObject(updater)
                #endif
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                .environmentObject(ldac)
                #endif
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    guard let self, self.wantsPopover else { return }
                    self.measuredContentSize = size
                    Task { @MainActor [weak self] in
                        guard let self, self.wantsPopover else { return }
                        self.updatePopoverSize()
                        if !self.popover.isShown { self.showPopover() }
                    }
                }
        }.frame(minHeight: 0, maxHeight: .infinity, alignment: .top))
        controller.sizingOptions = []
        popover.contentViewController = controller
    }

    private func releasePopoverContent() {
        popover.contentViewController = nil
        measuredContentSize = .zero
    }

    #if DEBUG
    var simulatedPopoverContent: NSViewController? { popover.contentViewController }

    func simulatePendingPopoverPresentation() {
        wantsPopover = true
        preparePopoverContent()
    }

    func simulatePopoverDismissal() { closeMenu() }
    #endif

    private func updateStatusItem() {
        let headphones = devices.selectedController
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        let keepsLDACVisible = ldac.targetAddress == headphones.address && ldac.state.keepsMenuBarVisible(isSessionRunning: ldac.isSessionRunning)
        // The panel offers the driver update instead of opening Installer.app, so it must be reachable (D13).
        let hasPendingDriverUpdate = settings.experimentalLDACEnabled && ldac.driverState == .outdated && !ldac.isSessionRunning
        #else
        let keepsLDACVisible = false
        let hasPendingDriverUpdate = false
        #endif
        #if ACOUPLET_SPARKLE
        let hasPendingUpdate = updater.hasPendingUpdate
        #else
        let hasPendingUpdate = false
        #endif
        let keepsFinderVisible = devices.controllers.contains { $0.earbudFinder?.isBusy == true || $0.earbudFinder?.mayBeRinging == true }
        let isVisible = hasPendingUpdate || hasPendingDriverUpdate || settings.keepMenuBarIconWhenDisconnected || headphones.showsMenuBarIcon || keepsFinderVisible
            || (keepsLDACVisible && headphones.deviceModel != .unknown)
        if statusItem.isVisible != isVisible { statusItem.isVisible = isVisible }
        guard let button = statusItem.button else { return }
        let model = headphones.deviceModel
        if !keepsLDACVisible || headphones.isReady || button.image == nil {
            let imageState = (
                model: model,
                leftConnected: headphones.audioFeatures.leftConnected,
                rightConnected: headphones.audioFeatures.rightConnected,
                batteries: headphones.isReady ? headphones.batteries : SonyBatteries(),
                chargingCase: headphones.isReady && headphones.isChargingInCase
            )
            if self.imageState.map({ $0 == imageState }) != true || button.image == nil {
                self.imageState = imageState
                button.image = DeviceIcon.menuBarImage(model: imageState.model,
                    leftConnected: imageState.leftConnected, rightConnected: imageState.rightConnected,
                    batteries: imageState.batteries, chargingCase: imageState.chargingCase)
            }
        }
        let title: String
        if settings.showBatteryInMenuBar, headphones.isReady, let level = headphones.batteryLevel {
            title = "\(level)%"
        } else if settings.showBatteryInMenuBar, keepsLDACVisible, !headphones.isReady {
            title = button.title
        } else {
            title = ""
        }
        if button.title != title { button.title = title }
        let imagePosition: NSControl.ImagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if button.imagePosition != imagePosition { button.imagePosition = imagePosition }
        let batteryDescription: String
        if !headphones.isReady {
            batteryDescription = ""
        } else if !model.isEarbuds {
            batteryDescription = headphones.batteries.single.map { String(localized: "Battery \($0.level)%") } ?? ""
        } else {
            var parts = [(String(localized: "Left"), headphones.batteries.left), (String(localized: "Right"), headphones.batteries.right)]
                .compactMap { name, reading in reading.map { String(localized: "\(name) \($0.level)%") } }
            if let reading = headphones.batteries.caseBattery {
                parts.append(String(localized: "Case \(reading.level)%, \(reading.chargingState.title), last reported"))
            }
            batteryDescription = parts.joined(separator: ", ")
        }
        button.setAccessibilityLabel(String(localized: "Acouplet, \(headphones.deviceName), \(headphones.statusText)"))
        button.setAccessibilityValue(model.isEarbuds ? DeviceIcon.connectionValue(
            left: headphones.audioFeatures.leftConnected,
            right: headphones.audioFeatures.rightConnected
        ) + ". " + batteryDescription : batteryDescription)
        button.toolTip = batteryDescription.isEmpty ? headphones.deviceName : "\(headphones.deviceName) · \(batteryDescription)"
        if hasPendingUpdate { button.toolTip = String(localized: "Update Available…") }
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        noiseModeHUD.setAnchorView(statusItem.isVisible ? button : nil)
        #endif
        if !statusItem.isVisible { closeMenu() }
        retryVisibleControls()
    }

    private func retryVisibleControls() {
        guard wantsPopover, popover.isShown else { return }
        let headphones = devices.selectedController
        let identifier = ObjectIdentifier(headphones)
        guard retriedControllers.insert(identifier).inserted else { return }
        if !headphones.retryControlsIfNeeded() { retriedControllers.remove(identifier) }
    }

    private func updatePopoverSize() {
        let size = measuredContentSize
        guard size.width > 0, size.height > 0, size != popover.contentSize else { return }
        guard popover.isShown else {
            popover.contentSize = size
            return
        }
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animates ? 0.2 : 0
            context.allowsImplicitAnimation = animates
            self.popover.contentSize = size
        }, completionHandler: nil)
    }

    private func showPopover() {
        guard let button = statusItem.button, button.window != nil else {
            closeMenu()
            return
        }
        wantsPopover = true
        if openRequestedAt == nil {
            openRequestedAt = ProcessInfo.processInfo.systemUptime
            Self.logger.info("Panel open requested")
        }
        preparePopoverContent()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        guard measuredContentSize.width > 0, measuredContentSize.height > 0 else { return }
        updatePopoverSize()
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        noiseModeHUD.setMenuVisible(true)
        #endif
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closeMenu() {
        wantsPopover = false
        openRequestedAt = nil
        if #available(macOS 27.0, *), let session = statusItem.expandedInterfaceSession {
            session.cancel()
        }
        popover.close()
        if !popover.isShown { releasePopoverContent() }
    }

    @objc private func togglePopover() {
        if popover.isShown || wantsPopover { closeMenu() }
        else { showPopover() }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .leftMouseUp,
           let button = statusItem.button, event.window === button.window,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
            return false
        }
        return true
    }

    func popoverWillShow(_ notification: Notification) {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        ldac.refreshDriverStateInBackground()
        #endif
        retriedControllers.removeAll()
        let shownAt = ProcessInfo.processInfo.systemUptime
        dismissalObservations.removeAll()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard event.timestamp > shownAt else { return }
            MainActor.assumeIsolated { self?.closeMenu() }
        }) {
            AnyCancellable { NSEvent.removeMonitor(monitor) }.store(in: &dismissalObservations)
        }
        foregroundApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.isActive else { return }
                let processIdentifier = application.processIdentifier
                guard processIdentifier != self.foregroundApplicationPID else { return }
                self.foregroundApplicationPID = processIdentifier
                if processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.closeMenu()
                }
            }
            .store(in: &dismissalObservations)
    }

    func popoverDidShow(_ notification: Notification) {
        if let requestedAt = openRequestedAt {
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000)
            Self.logger.info("Panel shown \(milliseconds, privacy: .public) ms after the open request")
            openRequestedAt = nil
        }
        retryVisibleControls()
    }

    func popoverWillClose(_ notification: Notification) {
        wantsPopover = false
        retriedControllers.removeAll()
        dismissalObservations.removeAll()
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        noiseModeHUD.setMenuVisible(false)
        #endif
        if #available(macOS 27.0, *) { statusItem.expandedInterfaceSession?.cancel() }
    }

    func popoverDidClose(_ notification: Notification) {
        if wantsPopover {
            if !popover.isShown { showPopover() }
        } else {
            releasePopoverContent()
        }
    }

}

#if !ACOUPLET_PUBLIC_APIS_ONLY
extension LDACState {
    func keepsMenuBarVisible(isSessionRunning: Bool) -> Bool {
        switch self {
        case .requested, .connecting, .active, .stopping: true
        case .failed: isSessionRunning
        case .off, .waitingForDevice: false
        }
    }
}
#endif

@available(macOS 27.0, *)
extension MenuBarController: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        showPopover()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        guard wantsPopover else { return }
        wantsPopover = false
        popover.animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.close()
        if !popover.isShown { releasePopoverContent() }
    }
}
