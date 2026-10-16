import AppKit
import CoreGraphics
import XCTest

final class AppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testVoiceFocusUsesSystemAccent() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for appearance in ["system", "light", "dark"] {
            app.launchArguments = ["-ui-testing", "--\(appearance)-appearance", "-AppleAccentColor", "0", "-AppleLanguages", "(en)"]
            app.launch()
            let status = app.statusItems.firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            status.click()
            let voice = app.checkBoxes["Focus on Voice"]
            XCTAssertTrue(voice.waitForExistence(timeout: 3))
            voice.click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: voice)], timeout: 3), .completed)
            app.buttons["noiseControl.anc"].click()
            XCTAssertTrue(voice.waitForNonExistence(timeout: 3))
            app.buttons["noiseControl.ambient"].click()
            XCTAssertTrue(voice.waitForExistence(timeout: 3))
            XCTAssertEqual((voice.value as? NSNumber)?.intValue, 1)
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(voice.waitForNonExistence(timeout: 3))
            let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
            finder.activate()
            let statusFrame = status.frame
            let finderFrame = finder.frame
            finder.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: statusFrame.midX - finderFrame.minX, dy: statusFrame.midY - finderFrame.minY
            )).click()
            XCTAssertTrue(voice.waitForExistence(timeout: 3))
            let screenshot = voice.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Focus on Voice system accent — \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            var redPixels = 0
            var bluePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.redComponent > color.blueComponent + 0.2 && color.redComponent > color.greenComponent + 0.2 { redPixels += 1 }
                    if color.blueComponent > color.redComponent + 0.2 { bluePixels += 1 }
                }
            }
            XCTAssertGreaterThan(redPixels, 20)
            XCTAssertGreaterThan(redPixels, bluePixels)
            app.terminate()
        }
    }

    @MainActor
    func testSoundSettingsUsesSystemAccent() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for (appearance, language, accent) in [("light", "en", "0"), ("dark", "tr", "0"),
                                                ("light", "tr", "3"), ("dark", "en", "3")] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--\(appearance)-appearance",
                                   "-AppleAccentColor", accent, "-AppleLanguages", "(\(language))"]
            app.launch()
            app.typeKey(",", modifierFlags: .command)
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            let tab = window.toolbars.buttons[language == "tr" ? "Kulaklıklar" : "Headphones"]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.click()
            let label = language == "tr" ? "Ses Ayarları…" : "Sound Settings…"
            let link = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 3))
            XCTAssertTrue(link.isHittable)
            let screenshot = link.screenshot()
            captureGalleryScreenshot(screenshot, named: "Sound Settings accent — \(appearance), \(language), \(accent)")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            var accentPixels = 0
            var bluePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if accent == "0" {
                        if color.redComponent > color.blueComponent + 0.2 && color.redComponent > color.greenComponent + 0.2 { accentPixels += 1 }
                    } else {
                        if color.greenComponent > color.redComponent + 0.1 && color.greenComponent > color.blueComponent + 0.1 { accentPixels += 1 }
                    }
                    if color.blueComponent > color.redComponent + 0.2 && color.blueComponent > color.greenComponent + 0.1 { bluePixels += 1 }
                }
            }
            XCTAssertGreaterThan(accentPixels, 20)
            XCTAssertGreaterThan(accentPixels, bluePixels)
            app.terminate()
        }
    }

    @MainActor
    func testChargingCaseUsesOfficialOpenCaseArtwork() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for (model, finish) in [("wfXM5", "black"), ("wfXM5", "platinum-silver"), ("wfXM5", "smoky-pink"),
                                ("wfXM6", "black"), ("wfXM6", "platinum-silver")] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--charging-in-case", "--gallery-model", model,
                                   "--gallery-finish", finish, "--dark-appearance", "-AppleLanguages", "(en)"]
            app.launch()
            let panel = app.windows["Headphone Controls"]
            let artwork = app.images["device.artwork.openCase"]
            XCTAssertTrue(artwork.waitForExistence(timeout: 5))
            XCTAssertTrue(artwork.isHittable)
            XCTAssertTrue(panel.frame.contains(artwork.frame))
            XCTAssertFalse(app.images["device.artwork.case"].exists)
            XCTAssertTrue(app.statusItems.firstMatch.exists)
            captureGalleryScreenshot(panel.screenshot(), named: "Charging case — \(model), \(finish), simulated")
            app.terminate()
        }
    }

    @MainActor
    func testNoiseModeIndicatorUsesMenuBarAnchorWithoutTakingFocus() async throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--noise-hud-preview", "--\(appearance)-appearance",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let preview = app.buttons["Preview Noise Change"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            let window = app.windows["Headphone Controls"]
            let status = app.statusItems.firstMatch
            let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
            title.press(forDuration: 0.1, thenDragTo: title.withOffset(CGVector(
                dx: status.frame.midX - window.frame.midX, dy: 30 - window.frame.minY
            )))
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let indicator = app.dialogs["Noise Control"]
            let processIdentifier = try XCTUnwrap(NSRunningApplication.runningApplications(
                withBundleIdentifier: "dev.baglayan.Acouplet.debug"
            ).first?.processIdentifier)
            func present(_ button: XCUIElement, label: String, phase: String) async throws -> CGRect {
                let sampling = Task.detached(priority: .userInitiated) {
                    let start = ProcessInfo.processInfo.systemUptime
                    var frames: [(TimeInterval, CGWindowID, CGRect)] = []
                    while ProcessInfo.processInfo.systemUptime - start < 1.5 {
                        for (identifier, frame) in Self.panelWindows(processIdentifier: processIdentifier) {
                            frames.append((ProcessInfo.processInfo.systemUptime - start, identifier, frame))
                        }
                        try await Task.sleep(for: .milliseconds(8))
                    }
                    return frames
                }
                button.click()
                XCTAssertTrue(indicator.waitForExistence(timeout: 1))
                XCTAssertTrue(indicator.staticTexts[label].waitForExistence(timeout: 2), indicator.debugDescription)
                let firstContentFrame = indicator.staticTexts[label].frame
                let frames = try await sampling.value
                let finalFrame = indicator.frame
                let nativeWindow = try XCTUnwrap(Self.panelWindows(processIdentifier: processIdentifier).first {
                    abs($0.1.minX - finalFrame.minX) <= 1 && abs($0.1.minY - finalFrame.minY) <= 1
                        && abs($0.1.width - finalFrame.width) <= 1 && abs($0.1.height - finalFrame.height) <= 1
                })
                let samples = frames.filter { $0.1 == nativeWindow.0 }
                var previousFrame: CGRect?
                let changes = samples.compactMap { time, _, frame -> String? in
                    guard frame != previousFrame else { return nil }
                    previousFrame = frame
                    return String(format: "%.4f x=%.2f y=%.2f width=%.2f height=%.2f",
                                  time, frame.minX, frame.minY, frame.width, frame.height)
                }
                let evidence = XCTAttachment(string: "Status item: \(status.frame)\nFirst content: \(firstContentFrame)\nFinal content: \(indicator.staticTexts[label].frame)\nFinal window: \(finalFrame)\n"
                    + changes.joined(separator: "\n"))
                evidence.name = "Native HUD anchor — \(appearance), \(phase)"
                evidence.lifetime = .keepAlways
                add(evidence)
                XCTAssertFalse(samples.isEmpty)
                XCTAssertTrue(samples.allSatisfy { abs($0.2.minX - finalFrame.minX) <= 1 && abs($0.2.minY - finalFrame.minY) <= 1 },
                              "The HUD moved from its anchored top-left during \(phase).")
                XCTAssertTrue(samples.allSatisfy { abs($0.2.width - finalFrame.width) <= 1 && abs($0.2.height - finalFrame.height) <= 1 },
                              "The HUD's hosting window resized during \(phase).")
                XCTAssertEqual(finalFrame.midX, status.frame.midX, accuracy: 1)
                for frame in [firstContentFrame, indicator.staticTexts[label].frame] {
                    XCTAssertGreaterThanOrEqual(frame.minY, status.frame.maxY)
                    XCTAssertLessThanOrEqual(frame.maxY, status.frame.maxY + finalFrame.height)
                    XCTAssertLessThanOrEqual(abs(frame.midX - status.frame.midX), finalFrame.width / 2)
                }
                return finalFrame
            }
            let initialFrame = try await present(preview, label: "Noise Cancellation", phase: "cold entry")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foreground)
            let screenshot = XCTAttachment(screenshot: indicator.screenshot())
            screenshot.name = "Native noise mode indicator — \(appearance), simulated change"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertTrue(indicator.staticTexts["Noise Cancellation"].exists, indicator.debugDescription)
            XCTAssertFalse(indicator.buttons["noiseHUD.mode.off"].exists)
            XCTAssertFalse(indicator.buttons["noiseHUD.close"].exists)
            _ = try await present(app.buttons["Preview Noise Replacement"], label: "Ambient Sound", phase: "exit replacement")
            XCTAssertEqual(indicator.frame.minX, initialFrame.minX, accuracy: 1)
            XCTAssertEqual(indicator.frame.minY, initialFrame.minY, accuracy: 1)
            XCTAssertEqual(indicator.frame.width, initialFrame.width, accuracy: 1)
            XCTAssertEqual(indicator.frame.height, initialFrame.height, accuracy: 1)
            preview.hover()
            XCTAssertTrue(indicator.waitForNonExistence(timeout: 6), indicator.debugDescription)
            _ = try await present(preview, label: "Noise Cancellation", phase: "entry after dismissal")
            XCTAssertEqual(indicator.frame.minX, initialFrame.minX, accuracy: 1)
            XCTAssertEqual(indicator.frame.minY, initialFrame.minY, accuracy: 1)
            XCTAssertEqual(indicator.frame.width, initialFrame.width, accuracy: 1)
            XCTAssertEqual(indicator.frame.height, initialFrame.height, accuracy: 1)
            status.click()
            let dashboard = app.popovers.containing(.group, identifier: "headphones.dashboard").firstMatch
            XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
            XCTAssertTrue(indicator.waitForNonExistence(timeout: 1))
            app.terminate()
        }
    }

    @MainActor
    func testBatteryAndFirmwareAlertsUseNativeFlyout() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--noise-hud-preview", "--\(appearance)-appearance",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let battery = app.buttons["Preview Low Battery"]
            XCTAssertTrue(battery.waitForExistence(timeout: 5))
            app.activate()
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            for (button, title) in [("Preview Low Battery", "Left Earbud Low (10%)"),
                                    ("Preview Both Low", "Left Earbud Low (10%)"),
                                    ("Preview Firmware Update", "Firmware 6.0.0 Available")] {
                app.buttons[button].click()
                let indicator = app.dialogs[title]
                XCTAssertTrue(indicator.waitForExistence(timeout: 1))
                XCTAssertTrue(indicator.staticTexts[title].exists, indicator.debugDescription)
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foreground)
                captureGalleryScreenshot(indicator.screenshot(), named: "Native alert — \(button), \(appearance), simulated")
                if button == "Preview Firmware Update" {
                    XCTAssertTrue(indicator.staticTexts["Update in Sony | Sound Connect."].exists)
                    XCTAssertFalse(indicator.descendants(matching: .any)["sonyHUD.batteryRing"].exists)
                } else {
                    let ring = indicator.descendants(matching: .any)["sonyHUD.batteryRing"]
                    XCTAssertTrue(ring.exists, indicator.debugDescription)
                    XCTAssertEqual(ring.label, "Battery level")
                    XCTAssertEqual(try XCTUnwrap(ring.value as? NSNumber).doubleValue, 0.1, accuracy: 0.001)
                    XCTAssertGreaterThan(ring.frame.midX, indicator.staticTexts[title].frame.maxX)
                }
                battery.hover()
                XCTAssertTrue(indicator.waitForNonExistence(timeout: 6), indicator.debugDescription)
            }
            app.terminate()
        }
    }

    @MainActor
    func testCompatibleStatusBannersRetainModeBatteryAndFirmwareAlerts() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for material in [false, true] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--noise-hud-preview", "--fallback-hud-preview",
                                   "--dark-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if material { app.launchArguments.append("--material-hud-preview") }
            app.launch()
            let preview = app.buttons["Preview Noise Change"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            for (button, label, isMode) in [("Preview Noise Change", "Noise Cancellation", true),
                                           ("Preview Noise Replacement", "Ambient Sound", true),
                                           ("Preview Low Battery", "Left Earbud Low (10%)", false),
                                           ("Preview Firmware Update", "Firmware 6.0.0 Available", false)] {
                app.buttons[button].click()
                let panel = app.dialogs[isMode ? "Noise Control" : label]
                XCTAssertTrue(panel.waitForExistence(timeout: 2))
                let title = panel.staticTexts[label]
                XCTAssertTrue(title.exists)
                XCTAssertGreaterThan(panel.frame.width, 80)
                XCTAssertEqual(panel.frame.height, 66, accuracy: 1)
                XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(title.frame),
                              "Compatible status clips \(label): \(title.frame) outside \(panel.frame)")
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foreground)
                if button == "Preview Low Battery" {
                    let ring = panel.descendants(matching: .any)["sonyHUD.batteryRing"]
                    XCTAssertTrue(ring.exists)
                    XCTAssertEqual(try XCTUnwrap(ring.value as? NSNumber).doubleValue, 0.1, accuracy: 0.001)
                } else if button == "Preview Firmware Update" {
                    XCTAssertTrue(panel.staticTexts["Update in Sony | Sound Connect."].exists)
                }
                captureGalleryScreenshot(panel.screenshot(), named: "Compatible status — \(material ? "material" : "glass"), \(button), simulated")
                preview.hover()
                XCTAssertTrue(panel.waitForNonExistence(timeout: 6))
            }
            app.terminate()
        }
    }

    @MainActor
    func testAppLanguagePickerKeepsNativeLanguageNamesAndShowsRestartHint() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for (language, systemLabel) in [("en", "System Default"), ("tr", "Sistem Saptanmışı")] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(\(language))"]
            app.launch()
            app.typeKey(",", modifierFlags: .command)
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            let generalTab = window.toolbars.buttons[language == "tr" ? "Genel" : "General"]
            XCTAssertTrue(generalTab.waitForExistence(timeout: 3))
            generalTab.click()
            let picker = window.popUpButtons["settings.appLanguage"]
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            XCTAssertEqual(picker.value as? String, systemLabel)
            XCTAssertFalse(window.staticTexts["settings.appLanguageRestart"].exists)
            picker.click()
            app.menuItems["Türkçe"].click()
            XCTAssertEqual(picker.value as? String, "Türkçe")
            XCTAssertTrue(window.staticTexts["settings.appLanguageRestart"].waitForExistence(timeout: 3))
            picker.click()
            app.menuItems["English"].click()
            XCTAssertEqual(picker.value as? String, "English")
            picker.click()
            app.menuItems[systemLabel].click()
            XCTAssertFalse(window.staticTexts["settings.appLanguageRestart"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testMultipointPopoverFollowsAccentPreference() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for (appearance, systemAccent) in [("light", true), ("light", false), ("dark", true), ("dark", false)] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--\(appearance)-appearance", "-AppleAccentColor", "0",
                                   "-preferences.useSystemAccentColor", systemAccent ? "YES" : "NO", "-AppleLanguages", "(en)"]
            app.launch()
            let panel = app.windows["Headphone Controls"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.buttons["multipoint.open"].click()
            let manager = app.descendants(matching: .any).matching(identifier: "multipoint.popover").firstMatch
            let toggle = manager.descendants(matching: .any).matching(identifier: "multipoint.enabled").firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            XCTAssertEqual(toggle.value as? Int, 1)
            let screenshot = toggle.screenshot()
            captureGalleryScreenshot(screenshot, named: "Multipoint switch — \(systemAccent ? "system red" : "app gold")")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            var redPixels = 0
            var yellowPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.redComponent > color.blueComponent + 0.2 && color.redComponent > color.greenComponent + 0.2 { redPixels += 1 }
                    if color.redComponent > color.blueComponent + 0.2 && color.greenComponent > color.blueComponent + 0.2 && abs(color.redComponent - color.greenComponent) < 0.25 { yellowPixels += 1 }
                }
            }
            XCTAssertGreaterThan(systemAccent ? redPixels : yellowPixels, 20)
            XCTAssertGreaterThan(systemAccent ? redPixels : yellowPixels, systemAccent ? yellowPixels : redPixels)
            app.terminate()
        }
    }

    @MainActor
    func testGeneralShowsVersionAtBottom() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)"]
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        selectSettingsPane("general", in: window)
        let version = window.staticTexts["settings.version"]
        XCTAssertTrue(version.waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.contains(version.frame))
        XCTAssertTrue(version.label.hasPrefix("Version 0.") || (version.value as? String)?.hasPrefix("Version 0.") == true,
                      version.debugDescription)
        XCTAssertGreaterThan(version.frame.midY, window.frame.midY)
        var labels = ["Show battery percentage", "Reconnect automatically", "Launch at login", "Global ANC / Ambient shortcut"]
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        labels += ["Low battery", "Firmware updates"]
        #endif
        for label in labels {
            let text = window.staticTexts[label]
            XCTAssertTrue(text.exists, label)
            for _ in 0..<5 where text.frame.maxY >= version.frame.minY {
                window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -100)
            }
            XCTAssertTrue(window.frame.contains(text.frame), "General clips \(label): \(text.frame)")
            XCTAssertLessThan(text.frame.maxY, version.frame.minY)
        }
        let generalFrame = window.frame
        captureGalleryScreenshot(window.screenshot(), named: "General — installed version footer")
        for pane in ["headphones", "advanced", "general"] {
            selectSettingsPane(pane, in: window)
            XCTAssertEqual(window.frame.width, generalFrame.width, accuracy: 1)
        }
        XCTAssertEqual(window.frame.height, generalFrame.height, accuracy: 1)
    }

    @MainActor
    func testTurkishSettingsAndUpdatesUseNativeLocalization() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(tr)", "-AppleLocale", "tr_TR"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        let noise = panel.staticTexts["Gürültü Denetimi"]
        XCTAssertTrue(noise.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.frame.contains(noise.frame))
        panel.buttons["Ayarlar…"].click()
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let panes = [
            ("Genel", ["Pil yüzdesini göster", "Otomatik yeniden bağlan", "Oturum açıldığında başlat"]),
            ("Kulaklıklar", ["Aygıt", "Kulaklık kodeği", "Bağlantı tercihi"]),
            ("İleri Düzey", ["Bluetooth adresi", "Sony denetimi", "Protokol"]),
        ]
        var generalFrame = CGRect.zero
        for (title, labels) in panes {
            let tab = window.toolbars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            XCTAssertTrue(window.frame.contains(tab.frame))
            tab.click()
            XCTAssertEqual(window.title, title)
            for label in labels {
                let text = window.staticTexts[label].firstMatch
                XCTAssertTrue(text.waitForExistence(timeout: 3), label)
                XCTAssertGreaterThan(text.frame.width, 0)
                XCTAssertTrue(window.frame.contains(text.frame), "\(title) clips \(label): \(text.frame)")
            }
            if title == "Genel" {
                generalFrame = window.frame
                let check = window.buttons["Güncellemeleri Denetle…"]
                XCTAssertTrue(check.waitForExistence(timeout: 3))
                let version = window.staticTexts["settings.version"]
                XCTAssertTrue(version.exists)
                XCTAssertTrue(version.label.hasPrefix("Sürüm 0.") || (version.value as? String)?.hasPrefix("Sürüm 0.") == true,
                              version.debugDescription)
                XCTAssertTrue(window.frame.contains(version.frame))
                let versionFrame = version.frame
                for label in labels {
                    XCTAssertLessThan(window.staticTexts[label].firstMatch.frame.maxY, version.frame.minY)
                }
                let initial = XCTAttachment(screenshot: window.screenshot())
                initial.name = "Turkish Settings — Genel, initial viewport"
                initial.lifetime = .keepAlways
                add(initial)
                for _ in 0..<6 where !check.isHittable || check.frame.maxY >= version.frame.minY {
                    window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
                }
                for label in ["Güncellemeleri otomatik denetle", "Güncellemeleri otomatik indir ve yükle"] {
                    let text = window.staticTexts[label].firstMatch
                    XCTAssertTrue(text.waitForExistence(timeout: 3), label)
                    XCTAssertTrue(text.isHittable, label)
                    XCTAssertTrue(window.frame.contains(text.frame), "Updates clips \(label): \(text.frame)")
                    XCTAssertLessThan(text.frame.maxY, version.frame.minY)
                }
                XCTAssertTrue(check.isHittable)
                XCTAssertTrue(window.frame.contains(check.frame))
                XCTAssertLessThan(check.frame.maxY, version.frame.minY)
                XCTAssertEqual(window.frame, generalFrame)
                XCTAssertEqual(version.frame, versionFrame)
                XCTAssertTrue(window.frame.contains(version.frame))
            } else {
                XCTAssertEqual(window.frame.width, generalFrame.width, accuracy: 1)
            }
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "Turkish Settings — \(title), simulated headphones"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    #if ACOUPLET_NO_SONY_ARTWORK
    @MainActor
    func testMiniatureOnlyMainAndSettings() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for model in ["wfXM3", "wfXM4", "wfXM5", "wfXM6", "whXM5"] {
            for appearance in ["light", "dark"] {
                app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", model, "--\(appearance)-appearance",
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                let panel = app.windows["Headphone Controls"]
                XCTAssertTrue(panel.waitForExistence(timeout: 5))
                let artwork = panel.descendants(matching: .any)["device.artwork.\(model)"]
                XCTAssertTrue(artwork.exists)
                XCTAssertTrue(panel.frame.contains(artwork.frame))
                if model.hasPrefix("wf") {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: artwork.screenshot().pngRepresentation))
                    let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
                    for (index, side) in ["left", "right"].enumerated() {
                        var minimum = bitmap.pixelsWide
                        var maximum = -1
                        for y in 0..<bitmap.pixelsHigh {
                            for x in (index * bitmap.pixelsWide / 2)..<((index + 1) * bitmap.pixelsWide / 2) {
                                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                                if abs(color.redComponent - background.redComponent) > 0.2 {
                                    minimum = min(minimum, x)
                                    maximum = max(maximum, x)
                                }
                            }
                        }
                        XCTAssertLessThan(minimum, maximum, "Missing \(model) \(side) silhouette")
                        let center = artwork.frame.minX + CGFloat(minimum + maximum + 1) / 2 * artwork.frame.width / CGFloat(bitmap.pixelsWide)
                        let battery = panel.descendants(matching: .any)["battery.\(side)"]
                        XCTAssertTrue(battery.exists)
                        XCTAssertEqual(center, battery.frame.midX, accuracy: 1.5, "\(model) \(side) icon is off its battery ring")
                    }
                    let chargingCase = panel.images["device.artwork.case"]
                    XCTAssertEqual(chargingCase.frame.midX, panel.descendants(matching: .any)["battery.case"].frame.midX, accuracy: 1)
                }
                let noise = panel.buttons["noiseControl.anc"]
                XCTAssertTrue(noise.isEnabled)
                noise.click()
                captureGalleryScreenshot(panel.screenshot(), named: "Miniature-only main — \(model), \(appearance), simulated")
                app.typeKey(",", modifierFlags: .command)
                let settings = app.windows["com_apple_SwiftUI_Settings_window"]
                XCTAssertTrue(settings.waitForExistence(timeout: 5))
                selectSettingsPane("headphones", in: settings)
                captureGalleryScreenshot(settings.screenshot(), named: "Miniature-only Settings — \(model), \(appearance), simulated")
                #if ACOUPLET_PUBLIC_APIS_ONLY
                selectSettingsPane("general", in: settings)
                XCTAssertFalse(settings.checkBoxes["notifications.lowBattery"].exists)
                XCTAssertFalse(settings.checkBoxes["notifications.firmware"].exists)
                #endif
                app.terminate()
            }
        }
    }
    #endif

    @MainActor
    func testPowerSettingsUseNativeTogglesAndSeparateEffectCancellation() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--power-settings", "--dark-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        selectSettingsPane("headphones", in: window)
        let care = window.descendants(matching: .any)["power.batteryCare"]
        XCTAssertTrue(care.waitForExistence(timeout: 3))
        let scroll = window.scrollViews.firstMatch
        for _ in 0..<6 where !care.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(care.isHittable)
        XCTAssertTrue(window.staticTexts["85%"].exists)
        let cancel = window.buttons["power.cancelEffect"]
        XCTAssertTrue(cancel.exists)
        if !cancel.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -180) }
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        let automatic = window.descendants(matching: .any)["power.autoPowerSave"]
        XCTAssertEqual((automatic.value as? NSNumber)?.intValue, 1)
        if !care.isHittable { scroll.scroll(byDeltaX: 0, deltaY: 150) }
        care.click()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 0"), object: care)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        XCTAssertTrue(window.staticTexts["85%"].exists)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Battery Care and Auto Power Save — simulated device"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNoiseAdaptationUsesConfirmedValuesAndAdvertisedSupport() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        selectSettingsPane("headphones", in: window)
        let adaptation = window.descendants(matching: .any)["noise.adaptation"]
        XCTAssertTrue(adaptation.waitForExistence(timeout: 3))
        adaptation.click()
        let sensitivity = window.popUpButtons["noise.sensitivity"]
        XCTAssertTrue(sensitivity.waitForExistence(timeout: 3))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: sensitivity)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        sensitivity.click()
        app.menuItems["High"].click()
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "High"), object: sensitivity)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 3), .completed)
        app.terminate()
        app.launchArguments += ["--gallery-model", "wfXM5"]
        app.launch()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        selectSettingsPane("headphones", in: window)
        XCTAssertFalse(window.descendants(matching: .any)["noise.adaptation"].exists)
    }

    @MainActor
    func testLegacySoundEffectsUseConfirmedNativePickers() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM3", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        let surround = panel.popUpButtons["audio.surround"]
        XCTAssertTrue(surround.waitForExistence(timeout: 5))
        XCTAssertEqual(surround.value as? String, "Off")
        surround.click()
        app.menuItems["Concert Hall"].click()
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Concert Hall"), object: surround)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 3), .completed)
        panel.buttons["menu.settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectSettingsPane("headphones", in: settings)
        XCTAssertEqual(settings.popUpButtons["audio.surround"].value as? String, "Concert Hall")
        let position = settings.popUpButtons["audio.soundPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        XCTAssertEqual(settings.popUpButtons["audio.surround"].frame.maxX, position.frame.maxX, accuracy: 1)
        XCTAssertEqual(position.frame.maxX, settings.popUpButtons["audio.dsee"].frame.maxX, accuracy: 1)
        position.click()
        app.menuItems["Rear Right"].click()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Rear Right"), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 3), .completed)
        for model in ["wfXM5", "whXM4"] {
            app.terminate()
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", model, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(panel.images["device.artwork.\(model)"].waitForExistence(timeout: 5))
            XCTAssertFalse(panel.popUpButtons["audio.surround"].exists)
            XCTAssertFalse(panel.popUpButtons["audio.soundPosition"].exists)
        }
    }

    @MainActor
    func testLegacyOptimizerRequiresStartAndShowsConfirmedResults() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM4", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        selectSettingsPane("headphones", in: window)
        let open = window.buttons["optimizer.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        let parentFrame = window.frame
        open.click()
        let sheet = app.sheets.firstMatch
        let start = app.buttons["optimizer.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        let heading = sheet.staticTexts["optimizer.title"]
        XCTAssertTrue(heading.exists)
        let headingFrame = heading.frame
        let sheetFrame = sheet.frame
        XCTAssertFalse(headingFrame.isEmpty)
        XCTAssertFalse(app.descendants(matching: .any)["optimizer.result"].exists)
        XCTAssertEqual(window.frame, parentFrame)
        XCTAssertTrue(sheet.frame.contains(start.frame))
        XCTAssertTrue(start.isHittable)
        start.click()
        let result = app.descendants(matching: .any)["optimizer.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Native optimizer results, contained sheet actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let done = app.buttons["optimizer.cancel"]
        XCTAssertEqual(sheet.frame, sheetFrame)
        XCTAssertEqual(heading.frame, headingFrame)
        XCTAssertEqual(heading.value as? String, "Noise Cancelling Optimizer")
        XCTAssertEqual(window.frame, parentFrame)
        XCTAssertTrue(sheet.frame.contains(result.frame))
        XCTAssertTrue(sheet.frame.contains(done.frame))
        XCTAssertTrue(done.isHittable)
        done.click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
        open.click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.buttons["optimizer.cancel"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    @MainActor
    func testInterruptedLegacyOptimizerShowsRecoveryInstructionInConnectionPanel() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM4", "--connection-lifecycle",
                               "--gallery-hold-test-replies", "--settings-lifecycle", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let title = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
        title.press(forDuration: 0.1, thenDragTo: title.withOffset(CGVector(
            dx: 20 - panel.frame.minX, dy: 90 - panel.frame.minY
        )))
        panel.buttons["Open Settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settings)
        settings.buttons["optimizer.open"].click()
        let start = app.buttons["optimizer.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: start
        )], timeout: 3), .completed)
        start.click()
        XCTAssertTrue(app.descendants(matching: .any)["optimizer.progress"].waitForExistence(timeout: 3))
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
        let disconnect = panel.buttons["Disconnect"]
        XCTAssertTrue(disconnect.isHittable)
        disconnect.click()
        let message = panel.staticTexts["Controls disconnected. Optimization status is unknown. Check Sound Connect before reconnecting controls."]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertTrue(message.isHittable)
        let status = panel.descendants(matching: .any).matching(identifier: "headphones.connectionStatus").firstMatch
        XCTAssertEqual(status.value as? String ?? status.label, "Noise Cancelling Optimizer")
        XCTAssertTrue(panel.buttons["headphones.connect"].isEnabled)
        XCTAssertFalse(panel.buttons["noiseControl.anc"].exists)
        captureGalleryScreenshot(panel.screenshot(), named: "Legacy optimizer — interrupted controls, recovery instruction")
    }

    @MainActor
    private func selectSettingsPane(_ pane: String, in window: XCUIElement) {
        let tab = window.toolbars.buttons[pane.capitalized]
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        tab.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "title == %@", pane.capitalized), object: window
        )], timeout: 3), .completed)
    }

    @MainActor
    private func auditContrast(_ surface: XCUIElement, in app: XCUIApplication, named name: String) throws -> [String] {
        func contains(_ node: any XCUIElementSnapshot, matching target: any XCUIElementSnapshot) -> Bool {
            if node.elementType == target.elementType && node.frame == target.frame
                && node.identifier == target.identifier && node.label == target.label && node.title == target.title
                && String(describing: node.value) == String(describing: target.value) { return true }
            return node.children.contains { contains($0, matching: target) }
        }
        var contrastFailures: [String] = []
        let scroll = surface.scrollViews.firstMatch
        var deferred: [XCUIElement] = []
        var verified: [XCUIElement] = []
        for attempt in 0..<20 {
            let attachment = XCTAttachment(screenshot: surface.screenshot())
            attachment.name = "\(name), audit \(attempt + 1)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let viewport = scroll.exists ? scroll.frame.intersection(surface.frame) : surface.frame
            let surfaceSnapshot = try surface.snapshot()
            let appSnapshot = try app.snapshot()
            let scrollSnapshot = scroll.exists ? try scroll.snapshot() : nil
            var failures: [String] = []
            var outsideIssues: [String] = []
            try app.performAccessibilityAudit(for: .contrast) { issue in
                let issueSnapshot = try? issue.element?.snapshot()
                if let issueSnapshot, !contains(surfaceSnapshot, matching: issueSnapshot),
                   !contains(issueSnapshot, matching: surfaceSnapshot),
                   contains(appSnapshot, matching: issueSnapshot) {
                    outsideIssues.append("\(issue.detailedDescription) — \(issueSnapshot.frame)")
                    return true
                }
                if let element = issue.element, let issueSnapshot, let scrollSnapshot,
                   !viewport.contains(element.frame), contains(scrollSnapshot, matching: issueSnapshot) {
                    if !verified.contains(where: {
                        $0.elementType == element.elementType && $0.frame == element.frame
                            && $0.label == element.label && String(describing: $0.value) == String(describing: element.value)
                    }) { deferred.append(element) }
                    return true
                }
                let description = issue.element.map {
                    "\($0.elementType): label=\($0.label), value=\(String(describing: $0.value)), frame=\($0.frame)"
                } ?? "No element"
                failures.append("\(issue.detailedDescription) — \(description)")
                if let element = issue.element, surface.frame.contains(element.frame) {
                    let evidence = XCTAttachment(screenshot: element.screenshot())
                    evidence.name = issue.detailedDescription
                    evidence.lifetime = .keepAlways
                    self.add(evidence)
                }
                return true
            }
            if !outsideIssues.isEmpty {
                let scope = XCTAttachment(string: outsideIssues.joined(separator: "\n"))
                scope.name = "Outside requested AX subtree — \(name), audit \(attempt + 1)"
                scope.lifetime = .keepAlways
                add(scope)
            }
            contrastFailures.append(contentsOf: failures.map { "\(name): \($0)" })
            deferred.removeAll { element in
                if viewport.contains(element.frame) {
                    verified.append(element)
                    return true
                }
                return false
            }
            guard let element = deferred.first else { return contrastFailures }
            scroll.scroll(byDeltaX: 0, deltaY: viewport.midY - element.frame.midY)
            XCTAssertTrue(viewport.contains(element.frame), "Could not fully reveal deferred contrast element: \(element.label)")
        }
        XCTFail("Some clipped contrast elements were not audited fully visible in \(name)")
        return contrastFailures
    }

    @MainActor
    func testNativeAppearancesContrastAndControls() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        var contrastFailures: [String] = []
        for appearance in ["light", "dark"] {
            let variant = "\(appearance), system accent"
            app.launchArguments = ["-ui-testing", "--\(appearance)-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let status = app.statusItems.firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            guard status.frame.minX >= 0 else { throw XCTSkip("The status icon is in macOS menu bar overflow.") }
            status.click()
            let dashboard = app.descendants(matching: .any)["headphones.dashboard"]
            XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            selectSettingsPane("general", in: settings)
            XCTAssertTrue(settings.descendants(matching: .any)["settings.systemAccent"].exists)
            for pane in ["general", "headphones", "advanced"] {
                selectSettingsPane(pane, in: settings)
                contrastFailures += try auditContrast(settings, in: app, named: "Settings \(pane) — \(variant)")
            }
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
            status.click()
            XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
            let panel = app.popovers.containing(.group, identifier: "headphones.dashboard").firstMatch
            contrastFailures += try auditContrast(panel, in: app, named: "Menu panel — \(variant)")
            app.menuButtons["More"].click()
            app.menuItems["Custom Equalizer…"].click()
            let editor = app.windows["Equalizer"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            let bass = editor.sliders["Clear Bass"]
            let previousBass = try XCTUnwrap((bass.value as? NSNumber)?.intValue)
            bass.adjust(toNormalizedSliderPosition: 0.75)
            XCTAssertNotEqual((bass.value as? NSNumber)?.intValue, previousBass)
            let name = editor.textFields["Preset name"]
            name.click()
            name.typeText("Appearance Preset")
            editor.buttons["Save"].click()
            XCTAssertTrue(editor.buttons["Appearance Preset"].waitForExistence(timeout: 2))
            contrastFailures += try auditContrast(editor, in: app, named: "Equalizer — \(variant)")
            editor.buttons["Delete Appearance Preset"].click()
            XCTAssertTrue(editor.sheets.firstMatch.waitForExistence(timeout: 2))
            contrastFailures += try auditContrast(editor.sheets.firstMatch, in: app, named: "Preset confirmation — \(variant)")
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(editor.sheets.firstMatch.waitForNonExistence(timeout: 2))
            XCTAssertTrue(editor.buttons["Appearance Preset"].exists)
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
            app.terminate()
        }
        XCTAssertTrue(contrastFailures.isEmpty, contrastFailures.joined(separator: "\n"))
    }

    @MainActor
    func testNativeModalContrastScope() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        var failures: [String] = []
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--\(appearance)-appearance", "-AppleLanguages", "(en)"]
            app.launch()
            XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
            app.menuButtons["More"].click()
            app.menuItems["Custom Equalizer…"].click()
            let editor = app.windows["Equalizer"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            editor.textFields["Preset name"].click()
            editor.textFields["Preset name"].typeText("Contrast Check")
            editor.buttons["Save"].click()
            XCTAssertTrue(editor.buttons["Delete Contrast Check"].waitForExistence(timeout: 3))
            editor.buttons["Delete Contrast Check"].click()
            let sheet = editor.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 3))
            XCTAssertTrue(sheet.buttons["Cancel"].isHittable)
            XCTAssertTrue(sheet.buttons["Delete"].isHittable)
            failures += try auditContrast(sheet, in: app, named: "Native preset confirmation — \(appearance)")
            sheet.buttons["Cancel"].click()
            XCTAssertTrue(editor.buttons["Contrast Check"].exists)
            app.terminate()
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    @MainActor
    func testMenuBarAboutWindowIncludesUpdates() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-ui-testing", "--\(appearance)-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let status = app.statusItems.firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            guard status.frame.minX >= 0 else { throw XCTSkip("The status icon is in macOS menu bar overflow.") }
            status.click()
            let dashboard = app.descendants(matching: .any)["headphones.dashboard"]
            XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
            let panel = app.popovers.containing(.group, identifier: "headphones.dashboard").firstMatch
            XCTAssertTrue(panel.frame.contains(app.buttons["menu.settings"].frame))
            XCTAssertTrue(panel.frame.contains(app.buttons["Refresh headphone status"].frame))
            XCTAssertTrue(panel.frame.contains(app.menuButtons["More"].frame))
            let footerCapture = XCTAttachment(screenshot: panel.screenshot())
            footerCapture.name = "Restored integrated footer — \(appearance)"
            footerCapture.lifetime = .keepAlways
            add(footerCapture)
            app.menuButtons["More"].click()
            try XCTUnwrap(app.menuItems.matching(identifier: "About Acouplet").allElementsBoundByIndex.first(where: { $0.isHittable })).click()
            XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
            let about = app.windows["About Acouplet"]
            XCTAssertTrue(about.waitForExistence(timeout: 3))
            XCTAssertLessThan(about.frame.width, 500)
            XCTAssertLessThan(about.frame.height, 400)
            XCTAssertTrue(about.staticTexts["about.version"].exists)
            XCTAssertTrue(about.staticTexts["about.copyright"].exists)
            XCTAssertTrue(about.descendants(matching: .any)["about.repository"].isHittable)
            XCTAssertTrue(about.buttons["about.checkForUpdates"].exists)
            about.buttons["about.license"].click()
            let license = app.windows["License"]
            XCTAssertTrue(license.waitForExistence(timeout: 3))
            let licenseText = try XCTUnwrap(license.staticTexts["legal.contents"].value as? String)
            XCTAssertTrue(licenseText.contains("MIT License"))
            XCTAssertTrue(licenseText.contains("2026 Meriç Bağlayan\nCopyright (c) 2026 Mohamed Emad"))
            license.buttons[XCUIIdentifierCloseWindow].click()
            about.buttons["about.thirdPartyNotices"].click()
            let notices = app.windows["Third-Party Notices"]
            XCTAssertTrue(notices.waitForExistence(timeout: 3))
            let noticeText = try XCTUnwrap(notices.staticTexts["legal.contents"].value as? String)
            XCTAssertTrue(noticeText.contains("Sparkle"))
            XCTAssertTrue(noticeText.contains("Apache License"))
            XCTAssertFalse(noticeText.contains("planned public release"))
            notices.buttons[XCUIIdentifierCloseWindow].click()
            let capture = XCTAttachment(screenshot: about.screenshot())
            capture.name = "About Acouplet with Updates — \(appearance)"
            capture.lifetime = .keepAlways
            add(capture)
            about.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(about.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testNativeMenuBarControlsAndDismissal() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let status = app.statusItems.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(status.frame.width, 40)
        guard status.frame.minX >= 0 else { throw XCTSkip("The status icon is in macOS menu bar overflow.") }
        status.click()
        let dashboard = app.descendants(matching: .any)["headphones.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            status.click()
            XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
            status.click()
            XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
        status.doubleClick()
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
        status.click()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
        XCTAssertTrue(app.images["device.artwork.wfXM5"].exists)
        XCTAssertTrue(app.buttons["noiseControl.anc"].exists)
        app.buttons["noiseControl.anc"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: app.buttons["noiseControl.anc"])], timeout: 2), .completed)
        XCTAssertTrue(app.buttons["noiseControl.anc"].isSelected)
        XCTAssertFalse(app.buttons["noiseControl.ambient"].isSelected)
        XCTAssertFalse(app.buttons["noiseControl.off"].isSelected)
        app.buttons["Office"].click()
        XCTAssertTrue(app.sliders["Ambient sound level"].waitForExistence(timeout: 2))
        let connected = XCTAttachment(screenshot: app.screenshot())
        connected.name = "WF native panel"
        connected.lifetime = .keepAlways
        add(connected)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
        status.click()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
        status.click()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
        finder.menuBars.menuBarItems["Finder"].click()
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
        finder.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        status.click()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
        app.menuButtons["More"].click()
        XCTAssertTrue(app.menuItems["Custom Equalizer…"].waitForExistence(timeout: 2))
        XCTAssertTrue(dashboard.exists)
        finder.menuBars.menuBarItems["Finder"].click()
        XCTAssertTrue(app.menuItems["Custom Equalizer…"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
        finder.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        status.click()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
        app.buttons["menu.settings"].click()
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(settingsWindow.isHittable)
        XCTAssertEqual(app.windows.firstMatch.identifier, settingsWindow.identifier)
    }

    @MainActor
    func testNativeMenuBarReopensAfterEqualizerFromOtherApp() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-ui-testing", "--\(appearance)-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let status = app.statusItems.firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            let dashboard = app.popovers.containing(.group, identifier: "headphones.dashboard").firstMatch
            let equalizer = app.windows["Equalizer"]
            func clickStatus() throws {
                let statusFrame = status.frame
                guard statusFrame.minX >= 0 else { throw XCTSkip("The status icon is in macOS menu bar overflow.") }
                let finderFrame = finder.frame
                finder.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: statusFrame.midX - finderFrame.minX, dy: statusFrame.midY - finderFrame.minY
                )).click()
            }
            for _ in 0..<2 {
                finder.activate()
                try clickStatus()
                XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
                app.menuButtons["More"].click()
                XCTAssertTrue(app.menuItems["Custom Equalizer…"].waitForExistence(timeout: 2))
                app.menuItems["Custom Equalizer…"].click()
                XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
                XCTAssertTrue(equalizer.waitForExistence(timeout: 3))
                equalizer.buttons[XCUIIdentifierCloseWindow].click()
                XCTAssertTrue(equalizer.waitForNonExistence(timeout: 3))
                try clickStatus()
                XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
                try clickStatus()
                XCTAssertTrue(dashboard.waitForNonExistence(timeout: 3))
            }
            app.terminate()
        }
    }

    @MainActor
    func testWFControlsInNativeWindow() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM5", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.images["device.artwork.wfXM5"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["headphones.devicePicker"].firstMatch.exists)
        app.buttons["noiseControl.anc"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: app.buttons["noiseControl.anc"])], timeout: 2), .completed)
        app.buttons["Office"].click()
        XCTAssertTrue(app.sliders["Ambient sound level"].waitForExistence(timeout: 2))
        let screenshot = XCTAttachment(screenshot: app.windows["Headphone Controls"].screenshot())
        screenshot.name = "WF native controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testMultipleHeadphonesShareSelectionAndHidePickerWhenOnlyOneRemains() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--multiple-devices", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        let picker = panel.menuButtons["headphones.devicePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let hierarchy = XCTAttachment(string: panel.debugDescription)
        hierarchy.name = "Main device selector accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertEqual(picker.title, "Choose Headphones")
        XCTAssertEqual(picker.value as? String, "WF-1000XM5")
        let title = panel.staticTexts["menu.title"]
        XCTAssertTrue(title.exists)
        XCTAssertEqual(title.frame.midX, panel.frame.midX, accuracy: 1)
        XCTAssertGreaterThan(picker.frame.midX, title.frame.midX)
        XCTAssertTrue(picker.isHittable)
        let mainSelector = XCTAttachment(screenshot: panel.descendants(matching: .any)["test.mainPanel"].firstMatch.screenshot())
        mainSelector.name = "Two Sony devices — main native device selector"
        mainSelector.lifetime = .keepAlways
        add(mainSelector)
        picker.click()
        app.menuItems["WH-1000XM5"].click()
        XCTAssertTrue(panel.images["device.artwork.whXM5"].waitForExistence(timeout: 3))
        XCTAssertEqual(picker.value as? String, "WH-1000XM5")
        XCTAssertEqual(title.frame.midX, panel.frame.midX, accuracy: 1)
        panel.buttons["noiseControl.anc"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: panel.buttons["noiseControl.anc"])], timeout: 2), .completed)
        picker.click()
        app.menuItems["WF-1000XM5"].click()
        XCTAssertTrue(panel.images["device.artwork.wfXM5"].waitForExistence(timeout: 3))
        XCTAssertTrue(panel.sliders["Ambient sound level"].exists)
        picker.click()
        app.menuItems["WH-1000XM5"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: panel.buttons["noiseControl.anc"])], timeout: 2), .completed)
        panel.buttons["Disconnect Other Headphones"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 3))
        XCTAssertTrue(panel.staticTexts["menu.title"].exists)
        XCTAssertEqual(title.frame.midX, panel.frame.midX, accuracy: 1)
        let single = XCTAttachment(screenshot: panel.descendants(matching: .any)["test.mainPanel"].firstMatch.screenshot())
        single.name = "One Sony device — no switching controls"
        single.lifetime = .keepAlways
        add(single)
        panel.buttons["menu.settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        selectSettingsPane("headphones", in: settings)
        XCTAssertFalse(settings.popUpButtons["headphones.devicePicker"].exists)
        XCTAssertEqual(settings.staticTexts["headphones.deviceName"].value as? String, "WH-1000XM5")
        XCTAssertFalse(settings.staticTexts["Model"].exists)
        app.terminate()
        app.launch()
        panel.buttons["menu.settings"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        selectSettingsPane("headphones", in: settings)
        let settingsPicker = settings.popUpButtons["headphones.devicePicker"]
        XCTAssertTrue(settingsPicker.waitForExistence(timeout: 3))
        XCTAssertFalse(settings.staticTexts["Model"].exists)
        XCTAssertFalse(settings.staticTexts["headphones.deviceName"].exists)
        let multiple = XCTAttachment(screenshot: settings.screenshot())
        multiple.name = "Two Sony devices — Settings native device selector"
        multiple.lifetime = .keepAlways
        add(multiple)
        settingsPicker.click()
        app.menuItems["WH-1000XM5"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "WH-1000XM5"), object: settingsPicker)], timeout: 3), .completed)
        XCTAssertTrue(app.statusItems.firstMatch.label.contains("WH-1000XM5"))
        settingsPicker.click()
        app.menuItems["WF-1000XM5"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "WF-1000XM5"), object: settingsPicker)], timeout: 3), .completed)
        XCTAssertTrue(app.statusItems.firstMatch.label.contains("WF-1000XM5"))
    }

    @MainActor
    func testWH3InterfaceGallery() throws {
        try captureFamilyGallery(models: ["whXM3"])
    }

    @MainActor
    func testFamilyInterfaceGallery() throws {
        try captureFamilyGallery(models: ["wfXM6", "wfXM5", "whXM6", "whXM5", "whCH720N"])
    }

    @MainActor
    func testLegacyFamilyInterfaceGallery() throws {
        try captureFamilyGallery(models: ["wfXM4", "wfXM3", "whXM4", "whXM3"])
    }

    @MainActor
    func testAdditionalFamilyInterfaceGallery() throws {
        try captureFamilyGallery(models: ["whULT900N", "wh1000XX"])
    }

    @MainActor
    func testModernFamilyFinishGallery() throws {
        try captureFamilyGallery(models: ["wfXM6", "wfXM5", "whXM6", "whXM5", "whCH720N"], allFinishes: true)
    }

    @MainActor
    func testLegacyFamilyFinishGallery() throws {
        try captureFamilyGallery(models: ["wfXM4", "wfXM3", "whXM4", "whXM3"], allFinishes: true)
    }

    @MainActor
    func testAdditionalFamilyFinishGallery() throws {
        try captureFamilyGallery(models: ["whULT900N", "wh1000XX"], allFinishes: true)
    }

    @MainActor
    private func captureGalleryScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureFamilyGallery(models: [String], allFinishes: Bool = false) throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        let finishes: [String: [(String, UInt8?)]] = [
            "wfXM6": [("black", 1), ("platinum-silver", nil)],
            "wfXM5": [("black", 1), ("platinum-silver", 3), ("smoky-pink", nil)],
            "wfXM4": [("black", 1), ("platinum-silver", 3)],
            "wfXM3": [("black", 1), ("platinum-silver", nil)],
            "whXM6": [("black", 1), ("platinum-silver", nil), ("midnight-blue", nil), ("sand-pink", nil), ("sandstone", nil), ("olive-gray", nil)],
            "whXM5": [("black", 1), ("platinum-silver", 3), ("midnight-blue", nil), ("smoky-pink", nil)],
            "whXM4": [("black", 1), ("platinum-silver", 3), ("midnight-blue", nil), ("silent-white", nil)],
            "whXM3": [("black", 1), ("silver", 3)],
            "whCH720N": [("black", 1), ("white", 2), ("blue", 5), ("pink", 6)],
            "whULT900N": [("black", 1), ("forest-gray", nil), ("off-white", nil)],
            "wh1000XX": [("black", 1), ("platinum", nil)]
        ]
        for model in models {
            let variants: [(String, UInt8?)] = allFinishes ? finishes[model]!
                : (["wfXM5", "whXM5"].contains(model) ? [("unknown", nil), ("black", 1)] : [("unknown", nil)])
            for (finish, color) in variants {
                for appearance in ["light", "dark"] {
                    let selection = allFinishes ? "\(color == nil ? "visual" : "wire")-\(finish)" : finish
                    let variant = "\(model)-\(selection)-\(appearance)"
                    app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", model,
                                           "--\(appearance)-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    if let color { app.launchArguments += ["--gallery-color", String(color)] }
                    if allFinishes && color == nil { app.launchArguments += ["--gallery-finish", finish] }
                    app.launch()
                    app.activate()
                    let panel = app.windows["Headphone Controls"]
                    XCTAssertTrue(panel.waitForExistence(timeout: 5))
                    XCTAssertTrue(panel.images["device.artwork.\(model)"].exists)
                    for mode in ["off", "anc", "ambient"] {
                        panel.buttons["noiseControl.\(mode)"].click()
                        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"),
                                                                 object: panel.buttons["noiseControl.\(mode)"])
                        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
                        captureGalleryScreenshot(panel.screenshot(), named: "\(variant)-main-\(mode)")
                    }
                    panel.menuButtons["More"].click()
                    app.menuItems["Custom Equalizer…"].click()
                    let equalizer = app.windows["Equalizer"]
                    XCTAssertTrue(equalizer.waitForExistence(timeout: 3))
                    captureGalleryScreenshot(equalizer.screenshot(), named: "\(variant)-equalizer-01")
                    equalizer.buttons[XCUIIdentifierCloseWindow].click()
                    app.statusItems.firstMatch.click()
                    app.buttons["menu.settings"].click()
                    let settings = app.windows["com_apple_SwiftUI_Settings_window"]
                    XCTAssertTrue(settings.waitForExistence(timeout: 3))
                    for pane in ["general", "headphones", "advanced"] {
                        selectSettingsPane(pane, in: settings)
                        if pane == "advanced", ["wfXM4", "wfXM3", "whXM4", "whXM3"].contains(model) {
                            XCTAssertFalse(settings.buttons["Connect Controls with Bluetooth LE"].exists)
                        }
                        let scroll = settings.scrollViews.firstMatch
                        let bar = scroll.scrollBars.firstMatch
                        for _ in 0..<20 where bar.exists {
                            let previous = String(describing: bar.value)
                            scroll.scroll(byDeltaX: 0, deltaY: 480)
                            if String(describing: bar.value) == previous { break }
                        }
                        var pages = [settings.screenshot()]
                        var reachedEnd = !bar.exists
                        for _ in 1..<20 where !reachedEnd {
                            let previous = String(describing: bar.value)
                            scroll.scroll(byDeltaX: 0, deltaY: -480)
                            if String(describing: bar.value) == previous {
                                reachedEnd = true
                            } else {
                                pages.append(settings.screenshot())
                            }
                        }
                        XCTAssertTrue(reachedEnd, "The gallery must reach the end of \(pane).")
                        for (index, screenshot) in pages.enumerated() {
                            let suffix = index == pages.count - 1 ? "-end" : ""
                            captureGalleryScreenshot(screenshot, named: "\(variant)-\(pane)-\(String(format: "%02d", index + 1))\(suffix)")
                        }
                    }
                    app.terminate()
                }
            }
        }
    }

    @MainActor
    func testConnectionStateGallery() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            for (state, arguments) in [
                ("permission", ["--bluetooth-permission-pending"]),
                ("disconnected", ["--disconnected"]),
                ("timeout", ["--gallery-model", "wfXM5", "--gallery-control-timeout"]),
            ] {
                app.launchArguments = ["-ui-testing", "--ui-test-host", "--\(appearance)-appearance",
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
                app.launch()
                app.activate()
                let panel = app.windows["Headphone Controls"]
                XCTAssertTrue(panel.waitForExistence(timeout: 5))
                XCTAssertEqual(panel.descendants(matching: .any).matching(identifier: "headphones.connectionStatus").firstMatch.exists, state != "disconnected")
                XCTAssertEqual(panel.buttons["headphones.connect"].exists, state != "permission")
                XCTAssertFalse(panel.buttons["noiseControl.anc"].exists)
                captureGalleryScreenshot(panel.screenshot(), named: "app-unknown-\(appearance)-state-\(state)-main")
                if state == "timeout" {
                    let hierarchy = XCTAttachment(string: app.debugDescription)
                    hierarchy.name = "Timeout gallery accessibility tree — \(appearance)"
                    hierarchy.lifetime = .keepAlways
                    add(hierarchy)
                    let message = "The headphones did not respond."
                    XCTAssertTrue(panel.staticTexts["headphones.connectionFailure"].exists)
                    XCTAssertTrue(panel.descendants(matching: .any).matching(NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@", message, message
                    )).firstMatch.exists)
                }
                panel.buttons["menu.settings"].click()
                let settings = app.windows["com_apple_SwiftUI_Settings_window"]
                selectSettingsPane("headphones", in: settings)
                XCTAssertTrue(settings.descendants(matching: .any).matching(identifier: "headphones.connectionStatus").firstMatch.exists)
                captureGalleryScreenshot(settings.screenshot(), named: "app-unknown-\(appearance)-state-\(state)-settings")
                app.terminate()
            }
        }
    }

    @MainActor
    func testHeadphoneTestAndDialogGallery() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            for held in [true, false] {
                app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM5", "--gallery-color", "1",
                                       "--\(appearance)-appearance", "--delayed-equalizer-readback",
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                if held { app.launchArguments.append("--gallery-hold-test-replies") }
                app.launch()
                app.activate()
                let prefix = "wfXM5-black-\(appearance)-state"
                let panel = app.windows["Headphone Controls"]
                XCTAssertTrue(panel.waitForExistence(timeout: 5))
                if !held {
                    panel.menuButtons["More"].click()
                    app.menuItems["Turn Off Headphones…"].click()
                    XCTAssertTrue(app.buttons["Turn Off"].waitForExistence(timeout: 3))
                    captureGalleryScreenshot(panel.screenshot(), named: "\(prefix)-power-confirmation")
                    panel.sheets.buttons["Cancel"].click()
                }
                panel.buttons["menu.settings"].click()
                let settings = app.windows["com_apple_SwiftUI_Settings_window"]
                selectSettingsPane("headphones", in: settings)
                for kind in ["fit", "gesture"] {
                    let open = settings.buttons["\(kind).open"]
                    XCTAssertTrue(open.waitForExistence(timeout: 3))
                    for _ in 0..<12 where !open.isHittable {
                        settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: kind == "fit" ? -200 : 200)
                    }
                    XCTAssertTrue(open.isHittable)
                    open.click()
                    let start = app.buttons["\(kind).start"]
                    XCTAssertTrue(start.waitForExistence(timeout: 3))
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "isEnabled == true"), object: start
                    )], timeout: 3), .completed)
                    if held { captureGalleryScreenshot(settings.screenshot(), named: "\(prefix)-\(kind)-ready") }
                    start.click()
                    let marker = held ? (kind == "fit" ? "fit.progress" : "gesture.waiting")
                        : (kind == "fit" ? "fit.leftResult" : "gesture.detected")
                    XCTAssertTrue(app.descendants(matching: .any)[marker].firstMatch.waitForExistence(timeout: 5))
                    let state = held ? (kind == "fit" ? "measuring" : "waiting") : (kind == "fit" ? "results" : "detected")
                    captureGalleryScreenshot(settings.screenshot(), named: "\(prefix)-\(kind)-\(state)")
                    app.buttons["\(kind).cancel"].click()
                    XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
                }
                settings.buttons[XCUIIdentifierCloseWindow].click()
                if !held {
                    app.statusItems.firstMatch.click()
                    XCTAssertTrue(app.menuButtons["More"].waitForExistence(timeout: 3))
                    app.menuButtons["More"].click()
                    app.menuItems["Custom Equalizer…"].click()
                    let editor = app.windows["Equalizer"]
                    XCTAssertTrue(editor.waitForExistence(timeout: 3))
                    editor.buttons["Sync Equalizer"].click()
                    XCTAssertTrue(editor.staticTexts["Reading equalizer…"].exists)
                    captureGalleryScreenshot(editor.screenshot(), named: "\(prefix)-equalizer-reading")
                    XCTAssertTrue(editor.staticTexts["Reading equalizer…"].waitForNonExistence(timeout: 5))
                    let name = editor.textFields["Preset name"]
                    name.click()
                    name.typeText("Travel")
                    editor.buttons["Save"].click()
                    XCTAssertTrue(editor.buttons["Travel"].waitForExistence(timeout: 3))
                    name.click()
                    name.typeText("Travel")
                    editor.buttons["Save"].click()
                    XCTAssertTrue(editor.sheets.buttons["Replace"].waitForExistence(timeout: 3))
                    captureGalleryScreenshot(editor.screenshot(), named: "\(prefix)-equalizer-replace")
                    app.typeKey(.escape, modifierFlags: [])
                    XCTAssertTrue(editor.sheets.firstMatch.waitForNonExistence(timeout: 3))
                    editor.buttons["Delete Travel"].click()
                    XCTAssertTrue(editor.sheets.buttons["Delete"].waitForExistence(timeout: 3))
                    captureGalleryScreenshot(editor.screenshot(), named: "\(prefix)-equalizer-delete")
                    app.typeKey(.escape, modifierFlags: [])
                    XCTAssertTrue(editor.sheets.firstMatch.waitForNonExistence(timeout: 3))
                    editor.buttons[XCUIIdentifierCloseWindow].click()
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testLegacyOptimizerAndConnectionDialogGallery() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            for held in [true, false] {
                app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM4",
                                       "--legacy-connection-quality", "--legacy-quality-caution", "--\(appearance)-appearance",
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                if held { app.launchArguments.append("--gallery-hold-test-replies") }
                app.launch()
                app.activate()
                let prefix = "whXM4-unknown-\(appearance)-state"
                let panel = app.windows["Headphone Controls"]
                XCTAssertTrue(panel.waitForExistence(timeout: 5))
                panel.buttons["menu.settings"].click()
                let settings = app.windows["com_apple_SwiftUI_Settings_window"]
                selectSettingsPane("headphones", in: settings)
                settings.buttons["optimizer.open"].click()
                let start = app.buttons["optimizer.start"]
                XCTAssertTrue(start.waitForExistence(timeout: 3))
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "isEnabled == true"), object: start
                )], timeout: 3), .completed)
                if held { captureGalleryScreenshot(settings.screenshot(), named: "\(prefix)-optimizer-ready") }
                start.click()
                let marker = held ? "optimizer.progress" : "optimizer.result"
                XCTAssertTrue(app.descendants(matching: .any)[marker].firstMatch.waitForExistence(timeout: 5))
                captureGalleryScreenshot(settings.screenshot(), named: "\(prefix)-optimizer-\(held ? "running" : "results")")
                app.buttons["optimizer.cancel"].click()
                XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
                if !held {
                    let picker = settings.popUpButtons["audio.connectionMode"]
                    XCTAssertTrue(picker.isHittable)
                    picker.click()
                    app.menuItems["Stable Connection"].click()
                    let change = settings.sheets.buttons["Change Preference"]
                    XCTAssertTrue(change.waitForExistence(timeout: 3))
                    captureGalleryScreenshot(settings.screenshot(), named: "\(prefix)-connection-confirmation")
                    app.activate()
                    app.typeKey(.return, modifierFlags: [])
                    XCTAssertTrue(change.waitForNonExistence(timeout: 3))
                    let proceed = settings.sheets.buttons["Continue"]
                    XCTAssertTrue(proceed.waitForExistence(timeout: 3))
                    captureGalleryScreenshot(settings.screenshot(), named: "\(prefix)-connection-caution")
                    settings.sheets.buttons["Cancel"].click()
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testIndependentEarbudAppearance() {
        let app = XCUIApplication()
        defer { app.terminate() }
        let states = [
            ("both-connected", "", "Left: Connected, Right: Connected"),
            ("left-disconnected", "--left-disconnected", "Left: Disconnected, Right: Connected"),
            ("right-disconnected", "--right-disconnected", "Left: Connected, Right: Disconnected"),
            ("unknown", "--unknown-bud-connections", "Left: Unknown, Right: Unknown"),
        ]
        for appearance in ["light", "dark"] {
            for (name, argument, value) in states {
                app.launchArguments = ["-ui-testing", "--ui-test-host", "--\(appearance)-appearance", "-AppleLanguages", "(en)"]
                if !argument.isEmpty { app.launchArguments.append(argument) }
                app.launch()
                let artwork = app.images["device.artwork.wfXM5"]
                XCTAssertTrue(artwork.waitForExistence(timeout: 5))
                XCTAssertEqual(artwork.value as? String, value)
                for (side, percentage) in [("Left", "78 percent"), ("Right", "82 percent"), ("Case", "64 percent")] {
                    let battery = app.descendants(matching: .any)["battery.\(side.lowercased())"]
                    let state = argument == "--\(side.lowercased())-disconnected" ? "Disconnected" : percentage
                    XCTAssertEqual(battery.label, "\(side) battery, \(state)")
                }
                let status = app.statusItems.firstMatch
                XCTAssertTrue(status.exists)
                XCTAssertLessThanOrEqual(status.frame.width, 40)
                let window = app.windows["Headphone Controls"]
                let capture = XCTAttachment(screenshot: window.screenshot())
                capture.name = "Earbuds-\(appearance)-\(name)"
                capture.lifetime = .keepAlways
                add(capture)
                if status.frame.minX >= 0 {
                    let icon = XCTAttachment(screenshot: status.screenshot())
                    icon.name = "Tray-\(appearance)-\(name)"
                    icon.lifetime = .keepAlways
                    add(icon)
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testMainPanelFitsContentAndScrollsOnlyWhenConstrained() async throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var resizeFailures: [String] = []
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-ui-testing", "--\(appearance)-appearance", "-AppleLanguages", "(en)"]
            app.launch()
            let status = app.statusItems.firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            guard status.frame.minX >= 0 else { throw XCTSkip("The status icon is in macOS menu bar overflow.") }
            status.click()
            let dashboard = app.descendants(matching: .any)["headphones.dashboard"]
            let panel = app.popovers.containing(.group, identifier: "headphones.dashboard").firstMatch
            XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
            XCTAssertTrue(app.images["device.artwork.case"].exists)
            XCTAssertTrue(app.buttons["menu.settings"].isHittable)
            XCTAssertTrue(app.popUpButtons["audio.dsee"].isHittable)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Main panel accessibility tree"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let layout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                panel.frame.contains(app.buttons["menu.settings"].frame)
                    && panel.frame.contains(app.images["device.artwork.case"].frame)
            }, object: nil)
            let layoutResult = await XCTWaiter.fulfillment(of: [layout], timeout: 3)
            XCTAssertEqual(layoutResult, .completed)
            let ambientHeight = panel.frame.height
            let expanded = XCTAttachment(screenshot: panel.screenshot())
            expanded.name = "Main-panel-\(appearance)-ambient"
            expanded.lifetime = .keepAlways
            add(expanded)
            let processIdentifier = try XCTUnwrap(NSRunningApplication.runningApplications(
                withBundleIdentifier: "dev.baglayan.Acouplet.debug"
            ).first?.processIdentifier)
            let window = try XCTUnwrap(Self.panelWindows(processIdentifier: processIdentifier).first {
                abs($0.1.width - panel.frame.width) < 1 && abs($0.1.height - ambientHeight) < 1
            })
            func measureResize(to mode: String) async throws {
                let initialFrame = try XCTUnwrap(Self.panelWindows(processIdentifier: processIdentifier)
                    .first { $0.0 == window.0 }?.1)
                let windowID = window.0
                let sampling = Task.detached(priority: .userInitiated) {
                    let start = ProcessInfo.processInfo.systemUptime
                    var frames: [(TimeInterval, CGRect)] = []
                    while ProcessInfo.processInfo.systemUptime - start < 3 {
                        if let frame = Self.panelWindows(processIdentifier: processIdentifier)
                            .first(where: { $0.0 == windowID })?.1 {
                            frames.append((ProcessInfo.processInfo.systemUptime - start, frame))
                        }
                        try await Task.sleep(for: .milliseconds(8))
                    }
                    return frames
                }
                app.buttons["noiseControl.\(mode)"].click()
                let frames = try await sampling.value
                let finalFrame = try XCTUnwrap(Self.panelWindows(processIdentifier: processIdentifier)
                    .first { $0.0 == windowID }?.1)
                var previousFrame: CGRect?
                let changes = frames.compactMap { time, frame -> String? in
                    guard frame != previousFrame else { return nil }
                    previousFrame = frame
                    return String(format: "%.4f x=%.2f y=%.2f width=%.2f height=%.2f",
                                  time, frame.minX, frame.minY, frame.width, frame.height)
                }
                let evidence = XCTAttachment(string: "\(frames.count) samples, Reduce Motion: \(reduceMotion)\nInitial: \(initialFrame)\nFinal: \(finalFrame)\n"
                    + changes.joined(separator: "\n"))
                evidence.name = "Native window resize — \(appearance), \(mode)"
                evidence.lifetime = .keepAlways
                add(evidence)
                let lower = min(initialFrame.height, finalFrame.height) + 1
                let upper = max(initialFrame.height, finalFrame.height) - 1
                let intermediateHeights = Set(frames.map { $0.1.height }.filter { $0 > lower && $0 < upper })
                if reduceMotion ? !intermediateHeights.isEmpty : intermediateHeights.count < 2 {
                    resizeFailures.append("\(appearance), \(mode): \(intermediateHeights.count) intermediate window heights, Reduce Motion: \(reduceMotion)")
                }
                if frames.contains(where: { abs($0.1.minY - initialFrame.minY) > 1 }) {
                    resizeFailures.append("\(appearance), \(mode): the native panel's top edge moved during resize")
                }
            }
            try await measureResize(to: "anc")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: app.buttons["noiseControl.anc"])], timeout: 3), .completed)
            XCTAssertLessThan(panel.frame.height, ambientHeight)
            let compact = XCTAttachment(screenshot: panel.screenshot())
            compact.name = "Main-panel-\(appearance)-anc"
            compact.lifetime = .keepAlways
            add(compact)
            let steadyFrame = panel.frame
            let artworkFrame = app.images["device.artwork.wfXM5"].frame
            for mode in ["off", "anc", "off", "anc"] {
                app.buttons["noiseControl.\(mode)"].click()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: app.buttons["noiseControl.\(mode)"])], timeout: 3), .completed)
                XCTAssertEqual(panel.frame, steadyFrame)
                XCTAssertEqual(app.images["device.artwork.wfXM5"].frame, artworkFrame)
                XCTAssertTrue(app.buttons["menu.settings"].isHittable)
                for identifier in ["off", "anc", "ambient"] {
                    XCTAssertEqual(app.buttons.matching(identifier: "noiseControl.\(identifier)").count, 1)
                }
            }
            try await measureResize(to: "ambient")
            XCTAssertTrue(app.sliders["Ambient sound level"].waitForExistence(timeout: 3))
            XCTAssertEqual(panel.frame.height, ambientHeight, accuracy: 1)
            app.terminate()
        }
        app.launchArguments = ["-ui-testing", "--compact-panel", "--light-appearance", "-AppleLanguages", "(en)"]
        app.launch()
        let status = app.statusItems.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        let dashboard = app.descendants(matching: .any)["headphones.dashboard"]
        let panel = app.popovers.containing(.group, identifier: "headphones.dashboard").firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))
        XCTAssertEqual(dashboard.frame.height, 480, accuracy: 1)
        let scroll = app.scrollViews["headphones.controlsScroll"]
        XCTAssertTrue(scroll.exists)
        XCTAssertTrue(app.images["device.artwork.case"].isHittable)
        XCTAssertTrue(app.buttons["menu.settings"].isHittable)
        scroll.scroll(byDeltaX: 0, deltaY: -500)
        XCTAssertTrue(app.popUpButtons["audio.dsee"].isHittable)
        let limited = XCTAttachment(screenshot: panel.screenshot())
        limited.name = "Main-panel-limited-height"
        limited.lifetime = .keepAlways
        add(limited)
        XCTAssertTrue(resizeFailures.isEmpty, resizeFailures.joined(separator: "\n"))
    }

    nonisolated private static func panelWindows(processIdentifier: pid_t) -> [(CGWindowID, CGRect)] {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  let identifier = window[kCGWindowNumber as String] as? NSNumber,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (identifier.uint32Value, frame)
        }
    }

    @MainActor
    func testMenuBarFollowsDeviceConnectionWhileAppKeepsRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--disconnected", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.windows.count, 0)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertEqual(app.state, .runningBackground)
        app.terminate()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--disconnected", "--connection-lifecycle", "-AppleLanguages", "(en)"]
        app.launch()
        let window = app.windows["Headphone Controls"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(app.statusItems.firstMatch.waitForNonExistence(timeout: 3))
        window.buttons["Connect WF"].click()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.statusItems.firstMatch.label.contains("WF-1000XM5"))
        window.buttons["Controls Busy"].click()
        XCTAssertTrue(app.statusItems.firstMatch.exists)
        XCTAssertTrue(app.statusItems.firstMatch.label.contains("Controls busy"))
        window.buttons["Disconnect"].click()
        XCTAssertTrue(app.statusItems.firstMatch.waitForNonExistence(timeout: 3))
        window.buttons["Connect WH"].click()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.statusItems.firstMatch.label.contains("WH-1000XM5"))
        XCTAssertTrue(app.images["device.artwork.whXM5"].exists)
        window.buttons["Disconnect"].click()
        XCTAssertTrue(app.statusItems.firstMatch.waitForNonExistence(timeout: 3))
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertEqual(app.state, .runningBackground)
    }

    @MainActor
    func testReopeningDisconnectedBackgroundAppShowsSettings() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--disconnected", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.windows.count, 0)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertEqual(app.state, .runningBackground)

        let original = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.baglayan.Acouplet.debug"
        ).first)
        let bundleURL = try XCTUnwrap(original.bundleURL)
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = ["-a", bundleURL.path]
        try reopen.run()
        reopen.waitUntilExit()
        XCTAssertEqual(reopen.terminationStatus, 0)
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.statusItems.firstMatch.exists)
        app.terminate()
        app.launchArguments += ["--manual-launch"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.statusItems.firstMatch.exists)
        app.terminate()
        app.launchArguments += ["--background-service"]
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.windows.count, 0)
    }

    @MainActor
    func testDuplicateLaunchReopensDisconnectedBackgroundAppWithoutReplacingIt() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--disconnected", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.windows.count, 0)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertEqual(app.state, .runningBackground)
        let original = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.baglayan.Acouplet.debug"
        ).first)
        XCTAssertTrue(original.isFinishedLaunching)
        XCTAssertFalse(original.isTerminated)

        let duplicate = Process()
        duplicate.executableURL = try XCTUnwrap(original.executableURL)
        duplicate.arguments = ["--disable-native-battery", "--disable-native-identity"]
        duplicate.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            key != "ACOUPLET_TESTING" && !key.hasPrefix("XCTest") && !key.hasPrefix("XCInject")
                && !key.hasPrefix("DYLD_") && !key.hasPrefix("__XPC_DYLD_")
        }
        try duplicate.run()
        defer { if duplicate.isRunning { duplicate.terminate() } }
        XCTAssertNotEqual(duplicate.processIdentifier, original.processIdentifier)
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"].waitForExistence(timeout: 5))
        let exited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !duplicate.isRunning }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 8), .completed)
        XCTAssertFalse(original.isTerminated)
        XCTAssertEqual(NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.baglayan.Acouplet.debug"
        ).map(\.processIdentifier), [original.processIdentifier])
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, original.processIdentifier)
        XCTAssertFalse(app.statusItems.firstMatch.exists)
    }

    @MainActor
    func testEqualizerPresets() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--dark-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        let preset = app.popUpButtons["equalizer.preset"]
        XCTAssertEqual(preset.value as? String, "Bass Boost")
        preset.click()
        app.menuItems["Bright"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Bright"), object: preset)], timeout: 3), .completed)
        app.menuButtons["More"].click()
        app.menuItems["Custom Equalizer…"].click()
        let editor = app.windows["Equalizer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.sliders.count, 6)
        let faders = ["Clear Bass", "400 Hz", "1 kHz", "2.5 kHz", "6.3 kHz", "16 kHz"].map { editor.sliders[$0] }
        for (index, fader) in faders.enumerated() {
            XCTAssertTrue(fader.isHittable)
            XCTAssertGreaterThan(fader.frame.height, fader.frame.width * 3)
            XCTAssertEqual(fader.frame.midY, faders[0].frame.midY, accuracy: 1)
            if index > 0 { XCTAssertGreaterThan(fader.frame.minX, faders[index - 1].frame.maxX) }
        }
        let bass = editor.sliders["Clear Bass"]
        bass.adjust(toNormalizedSliderPosition: 0.75)
        let savedBass = try XCTUnwrap((bass.value as? NSNumber)?.intValue)
        XCTAssertGreaterThan(savedBass, 0)
        let band = editor.sliders["2.5 kHz"]
        band.adjust(toNormalizedSliderPosition: 0.25)
        let savedBand = try XCTUnwrap((band.value as? NSNumber)?.intValue)
        XCTAssertLessThan(savedBand, 0)
        XCTAssertEqual((bass.value as? NSNumber)?.intValue, savedBass)
        XCTAssertEqual((editor.sliders["1 kHz"].value as? NSNumber)?.intValue, 0)
        let adjusted = XCTAttachment(screenshot: editor.screenshot())
        adjusted.name = "Native equalizer adjusted"
        adjusted.lifetime = .keepAlways
        add(adjusted)
        let name = editor.textFields["Preset name"]
        name.click()
        name.typeText("Travel")
        XCTAssertEqual(name.value as? String, "Travel")
        editor.buttons["Save"].click()
        XCTAssertTrue(editor.buttons["Travel"].waitForExistence(timeout: 2))
        editor.buttons["Reset Flat"].click()
        for fader in faders { XCTAssertEqual((fader.value as? NSNumber)?.intValue, 0) }
        editor.buttons["Travel"].click()
        XCTAssertEqual((bass.value as? NSNumber)?.intValue, savedBass)
        XCTAssertEqual((band.value as? NSNumber)?.intValue, savedBand)
        editor.buttons["Reset Flat"].click()
        name.click()
        name.typeText(" travel ")
        editor.buttons["Save"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForExistence(timeout: 2))
        editor.sheets.buttons["Cancel"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForNonExistence(timeout: 3))
        editor.buttons["Travel"].click()
        XCTAssertEqual((bass.value as? NSNumber)?.intValue, savedBass)
        XCTAssertEqual((band.value as? NSNumber)?.intValue, savedBand)
        editor.buttons["Reset Flat"].click()
        editor.buttons["Save"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForExistence(timeout: 2))
        editor.sheets.buttons["Replace"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForNonExistence(timeout: 3))
        bass.adjust(toNormalizedSliderPosition: 0.75)
        editor.buttons["Travel"].click()
        for fader in faders { XCTAssertEqual((fader.value as? NSNumber)?.intValue, 0) }
        editor.buttons["Delete Travel"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForExistence(timeout: 2))
        editor.sheets.buttons["Cancel"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(editor.buttons["Travel"].exists)
        editor.buttons["Delete Travel"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForExistence(timeout: 2))
        editor.sheets.buttons["Delete"].click()
        XCTAssertTrue(editor.sheets.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(editor.buttons["Travel"].waitForNonExistence(timeout: 2))
        let eq = XCTAttachment(screenshot: editor.screenshot())
        eq.name = "Native equalizer"
        eq.lifetime = .keepAlways
        add(eq)
        editor.buttons[XCUIIdentifierCloseWindow].click()
    }

    @MainActor
    func testLegacyEqualizerSelectsManualBeforeApplyingDraft() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM3", "--light-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.menuButtons["More"].click()
        app.menuItems["Custom Equalizer…"].click()
        let editor = app.windows["Equalizer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.sliders.count, 6)
        let bass = editor.sliders["Clear Bass"]
        bass.adjust(toNormalizedSliderPosition: 0.75)
        let draft = try XCTUnwrap((bass.value as? NSNumber)?.intValue)
        XCTAssertGreaterThan(draft, 0)
        let manual = editor.buttons["Use Manual"]
        XCTAssertTrue(manual.isEnabled)
        XCTAssertFalse(editor.staticTexts["Applied to headphones."].exists)
        let name = editor.textFields["Preset name"]
        name.click()
        name.typeText("Unapplied Draft")
        let savedName = try XCTUnwrap(name.value as? String)
        XCTAssertFalse(savedName.isEmpty)
        editor.buttons["Save"].click()
        let savedPreset = editor.buttons[savedName]
        XCTAssertTrue(savedPreset.waitForExistence(timeout: 3))
        XCTAssertFalse(savedPreset.isEnabled)
        XCTAssertTrue(editor.staticTexts["Choose Manual to apply this draft."].exists)
        XCTAssertTrue(manual.isEnabled)
        XCTAssertFalse(editor.staticTexts["Applied to headphones."].exists)
        XCTAssertEqual((bass.value as? NSNumber)?.intValue, draft)
        captureGalleryScreenshot(editor.screenshot(), named: "Legacy equalizer — noneditable headphone state, saved local draft")
        manual.click()
        let apply = editor.buttons["Apply equalizer to headphones"]
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: apply)], timeout: 3), .completed)
        XCTAssertEqual((bass.value as? NSNumber)?.intValue, draft)
        apply.click()
        XCTAssertTrue(editor.staticTexts["Applied to headphones."].waitForExistence(timeout: 4))
        let screenshot = XCTAttachment(screenshot: editor.screenshot())
        screenshot.name = "Legacy equalizer confirmed Manual curve"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testTenBandEqualizerUsesAdvertisedPresetsAndVerticalFaders() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--ten-band-equalizer", "--dark-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        let preset = app.popUpButtons["equalizer.preset"]
        preset.click()
        XCTAssertTrue(app.menuItems["Clear"].exists)
        XCTAssertFalse(app.menuItems["Bright"].exists)
        app.menuItems["Clear"].click()
        app.menuButtons["More"].click()
        app.menuItems["Custom Equalizer…"].click()
        let editor = app.windows["Equalizer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.sliders.count, 10)
        XCTAssertFalse(editor.sliders["Clear Bass"].exists)
        let labels = ["31 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"]
        for (index, label) in labels.enumerated() {
            let fader = editor.sliders[label]
            XCTAssertTrue(fader.isHittable)
            if index > 0 { XCTAssertGreaterThan(fader.frame.minX, editor.sliders[labels[index - 1]].frame.maxX) }
        }
        editor.sliders["31 Hz"].adjust(toNormalizedSliderPosition: 0)
        editor.sliders["16 kHz"].adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual((editor.sliders["31 Hz"].value as? NSNumber)?.intValue, -6)
        XCTAssertEqual((editor.sliders["16 kHz"].value as? NSNumber)?.intValue, 6)
        XCTAssertTrue(editor.staticTexts["Applied to headphones."].waitForExistence(timeout: 4))
        let shot = XCTAttachment(screenshot: editor.screenshot())
        shot.name = "Ten-band native equalizer"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testEqualizerIntentOpensBeforeAnyMenuOrSettings() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--open-equalizer-intent", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let editor = app.windows["Equalizer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.sliders["Clear Bass"].isHittable)
        XCTAssertFalse(app.windows["com_apple_SwiftUI_Settings_window"].exists)
        XCTAssertFalse(app.windows["Headphone Controls"].exists)
        editor.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        app.statusItems.firstMatch.click()
        app.menuButtons["More"].click()
        app.menuItems["Custom Equalizer…"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(app.windows.matching(identifier: "Equalizer").count, 1)
        XCTAssertTrue(editor.sliders["Clear Bass"].isHittable)
    }

    @MainActor
    func testEqualizerSyncPreservesNewerDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--delayed-equalizer-readback", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        app.menuButtons["More"].click()
        app.menuItems["Custom Equalizer…"].click()
        let editor = app.windows["Equalizer"]
        let bass = editor.sliders["Clear Bass"]
        bass.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertTrue(editor.staticTexts["Applied to headphones."].waitForExistence(timeout: 4))
        let statusLeft = editor.staticTexts["Applied to headphones."].frame.minX
        let editorFrame = editor.frame
        editor.buttons["Sync Equalizer"].click()
        XCTAssertTrue(editor.staticTexts["Reading equalizer…"].exists)
        XCTAssertEqual(editor.staticTexts["Reading equalizer…"].frame.minX, statusLeft, accuracy: 1)
        XCTAssertEqual(editor.frame, editorFrame)
        bass.adjust(toNormalizedSliderPosition: 0.25)
        let draft = try XCTUnwrap((bass.value as? NSNumber)?.intValue)
        XCTAssertLessThan(draft, 0)
        XCTAssertTrue(editor.staticTexts["Applied to headphones."].waitForExistence(timeout: 5))
        XCTAssertEqual((bass.value as? NSNumber)?.intValue, draft)
        editor.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        app.statusItems.firstMatch.click()
        app.menuButtons["More"].click()
        app.menuItems["Custom Equalizer…"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual((bass.value as? NSNumber)?.intValue, draft)
    }

    @MainActor
    func testSettingsPanesRememberSelectionWhenReopened() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--manual-launch", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertEqual(settingsWindow.title, "General")
        XCTAssertTrue(settingsWindow.descendants(matching: .any)["settings.systemAccent"].exists)
        selectSettingsPane("headphones", in: settingsWindow)
        selectSettingsPane("advanced", in: settingsWindow)
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
        let original = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.baglayan.Acouplet.debug"
        ).first)
        let bundleURL = try XCTUnwrap(original.bundleURL)
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = ["-a", bundleURL.path]
        try reopen.run()
        reopen.waitUntilExit()
        XCTAssertEqual(reopen.terminationStatus, 0)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        XCTAssertEqual(settingsWindow.title, "Advanced")
        let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        screenshot.name = "Native Settings reopened to Advanced"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSettingsSceneLifecycleDuringClosedPublications() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--settings-lifecycle", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]

        func snapshot() async throws -> (phase: String, visible: Bool, body: Int, appeared: Int, disappeared: Int) {
            let button = panel.buttons["Snapshot Settings Lifecycle"]
            button.click()
            try await Task.sleep(for: .milliseconds(150))
            button.click()
            let value = try XCTUnwrap(panel.staticTexts["test.settingsLifecycle"].value as? String)
            let fields = value.split(separator: "|", omittingEmptySubsequences: false)
            XCTAssertEqual(fields.count, 5, value)
            return (String(fields[0]), try XCTUnwrap(Bool(String(fields[1]))), try XCTUnwrap(Int(fields[2])),
                    try XCTUnwrap(Int(fields[3])), try XCTUnwrap(Int(fields[4])))
        }

        panel.buttons["Open Settings"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        selectSettingsPane("headphones", in: settings)
        let frame = settings.frame
        let visible = try await snapshot()
        XCTAssertEqual(app.windows.firstMatch.title, "Headphone Controls")
        XCTAssertTrue(visible.visible)
        XCTAssertGreaterThan(visible.appeared, visible.disappeared)
        panel.buttons["Publish SBC"].click()
        let inactive = try await snapshot()
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(settings.staticTexts["SBC"].exists)
        XCTAssertEqual(settings.frame, frame)
        XCTAssertTrue(inactive.visible)
        XCTAssertEqual(inactive.appeared, visible.appeared)
        XCTAssertEqual(inactive.disappeared, visible.disappeared)
        XCTAssertGreaterThan(inactive.body, visible.body)

        settings.toolbars.buttons["Headphones"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
        let closed = try await snapshot()
        XCTAssertFalse(closed.visible)
        XCTAssertEqual(closed.appeared, closed.disappeared)
        for title in ["Publish LDAC", "Publish SBC", "Publish LDAC"] {
            panel.buttons[title].click()
            let state = try await snapshot()
            XCTAssertFalse(state.visible)
            XCTAssertEqual(state.body, closed.body)
            XCTAssertEqual(state.appeared, closed.appeared)
            XCTAssertEqual(state.disappeared, closed.disappeared)
            XCTAssertFalse(settings.exists)
        }
        let hidden = try await snapshot()
        XCTAssertEqual(hidden.body, closed.body)
        XCTAssertEqual(panel.staticTexts["test.settingsCodec"].value as? String, "LDAC")
        let evidence = XCTAttachment(string: "visible=\(visible)\ninactive=\(inactive)\nclosed=\(closed)\nhidden=\(hidden)\nhidden body evaluations=\(hidden.body - closed.body)")
        evidence.name = "Native Settings lifecycle and closed publication diagnostic"
        evidence.lifetime = .keepAlways
        add(evidence)

        panel.buttons["Open Settings"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertEqual(settings.title, "Headphones")
        XCTAssertEqual(settings.frame, frame)
        XCTAssertTrue(settings.staticTexts["LDAC"].exists)
        let reopened = try await snapshot()
        XCTAssertTrue(reopened.visible)
        XCTAssertGreaterThan(reopened.appeared, reopened.disappeared)
        XCTAssertGreaterThan(reopened.appeared, closed.appeared)
    }

    @MainActor
    func testPendingBluetoothPermissionShowsLoadingInsteadOfUnavailable() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--bluetooth-permission-pending", "-AppleLanguages", "(en)"]
        app.launch()
        let window = app.windows["Headphone Controls"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let status = window.descendants(matching: .any).matching(identifier: "headphones.connectionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.value as? String ?? status.label, "Checking Bluetooth…")
        XCTAssertTrue(window.staticTexts["Waiting for Bluetooth permission…"].exists)
        XCTAssertFalse(window.buttons["headphones.connect"].exists)
        XCTAssertFalse(window.staticTexts["Headphones Unavailable"].exists)
        XCTAssertFalse(window.staticTexts["Connect the headphones in Bluetooth settings."].exists)
        window.buttons["menu.settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settings)
        let settingsStatus = settings.descendants(matching: .any).matching(identifier: "headphones.connectionStatus").firstMatch
        XCTAssertTrue(settingsStatus.exists)
        XCTAssertEqual(settingsStatus.value as? String ?? settingsStatus.label, "Checking Bluetooth…")
        XCTAssertTrue(settings.staticTexts["Waiting for Bluetooth permission…"].exists)
        XCTAssertFalse(settings.buttons["headphones.connect"].exists)
        XCTAssertFalse(settings.staticTexts["Headphones Unavailable"].exists)
        XCTAssertFalse(settings.staticTexts["Color"].exists)
        XCTAssertFalse(settings.staticTexts["Firmware"].exists)
    }

    @MainActor
    func testOptionalTouchAndSystemReadTimeoutsShowLocalizedErrorsAndRefreshRecovery() {
        let app = XCUIApplication(bundleIdentifier: "dev.baglayan.Acouplet.debug")
        defer { app.terminate() }
        for (language, systemRead) in [("en", false), ("en", true), ("tr", false), ("tr", true)] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM5", "--optional-read-timeout",
                                   "-AppleLanguages", "(\(language))", "-AppleLocale", language == "tr" ? "tr_TR" : "en_US"]
            if systemRead { app.launchArguments.append("--optional-system-read-timeout") }
            app.launch()
            let panel = app.windows["Headphone Controls"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            let title = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
            title.press(forDuration: 0.1, thenDragTo: title.withOffset(CGVector(
                dx: 20 - panel.frame.minX, dy: 90 - panel.frame.minY
            )))
            panel.buttons["test.optionalRead.begin"].click()
            panel.buttons["test.optionalRead.expire"].click()
            panel.buttons["test.optionalRead.settings"].click()
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            settings.toolbars.buttons[language == "tr" ? "Kulaklıklar" : "Headphones"].click()
            let message = language == "tr" ? "Kulaklık ayarları alınamadı. Yeniden denemek için yenileyin."
                : "Headphone settings were not received. Refresh to try again."
            let errors = settings.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", message, message))
            XCTAssertEqual(errors.count, 1, settings.debugDescription)
            XCTAssertFalse(settings.staticTexts[language == "tr" ? "Dokunma denetimleri okunuyor…" : "Reading touch controls…"].exists)
            if systemRead { XCTAssertFalse(settings.switches["system.1"].exists) }
            let hierarchy = XCTAttachment(string: settings.debugDescription)
            hierarchy.name = "Optional read timeout — \(language), setting error"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let error = errors.firstMatch
            for _ in 0..<15 where !error.isHittable {
                settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
            }
            XCTAssertTrue(error.isHittable)
            XCTAssertTrue(settings.frame.contains(error.frame))
            captureGalleryScreenshot(settings.screenshot(), named: "Optional read timeout — \(language), \(systemRead ? "system" : "touch") error")
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
            let refresh = panel.buttons[language == "tr" ? "Kulaklık durumunu yenile" : "Refresh headphone status"]
            XCTAssertTrue(refresh.isEnabled)
            XCTAssertTrue(refresh.isHittable)
            refresh.click()
            XCTAssertFalse(panel.buttons["noiseControl.anc"].exists)
            panel.buttons["test.optionalRead.recover"].click()
            XCTAssertTrue(panel.buttons["noiseControl.anc"].waitForExistence(timeout: 3))
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 2000)
            let pause = settings.switches["system.1"]
            XCTAssertTrue(pause.waitForExistence(timeout: 3))
            for _ in 0..<15 where !pause.isHittable {
                settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
            }
            XCTAssertTrue(pause.isEnabled)
            XCTAssertTrue(pause.isHittable)
            pause.click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == 0"), object: pause
            )], timeout: 3), .completed)
            let assignment = settings.popUpButtons["touch.assignment.0"]
            for _ in 0..<15 where !assignment.isHittable {
                settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
            }
            XCTAssertTrue(assignment.isEnabled)
            XCTAssertTrue(assignment.isHittable)
            XCTAssertEqual(errors.count, 0)
            captureGalleryScreenshot(settings.screenshot(), named: "Optional read timeout — \(language), Refresh recovered controls")
            app.terminate()
        }
    }

    @MainActor
    func testLegacyReadTimeoutErrorsSurviveReusedHandshakeAndRecover() {
        let app = XCUIApplication(bundleIdentifier: "dev.baglayan.Acouplet.debug")
        defer { app.terminate() }
        for language in ["en", "tr"] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM3", "--optional-read-timeout",
                                   "-AppleLanguages", "(\(language))", "-AppleLocale", language == "tr" ? "tr_TR" : "en_US"]
            app.launch()
            let panel = app.windows["Headphone Controls"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            let title = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
            title.press(forDuration: 0.1, thenDragTo: title.withOffset(CGVector(
                dx: 20 - panel.frame.minX, dy: 90 - panel.frame.minY
            )))
            panel.buttons["test.optionalRead.begin"].click()
            panel.buttons["test.optionalRead.expire"].click()
            panel.buttons["test.optionalRead.settings"].click()
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            settings.toolbars.buttons[language == "tr" ? "Kulaklıklar" : "Headphones"].click()
            let messages = language == "tr"
                ? ["DSEE ayarları kullanılamıyor.", "Çevresel Ses (VPT) ayarları kullanılamıyor."]
                : ["DSEE settings are unavailable.", "Surround (VPT) settings are unavailable."]
            for phase in ["expired", "reused handshake"] {
                if phase == "reused handshake" {
                    panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
                    panel.buttons["test.optionalRead.rehandshake"].click()
                    XCTAssertTrue(panel.buttons["noiseControl.anc"].waitForExistence(timeout: 3))
                    settings.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
                }
                for message in messages {
                    let error = settings.staticTexts[message]
                    XCTAssertTrue(error.waitForExistence(timeout: 3), settings.debugDescription)
                    for _ in 0..<10 where !error.isHittable {
                        settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -150)
                    }
                    XCTAssertTrue(error.isHittable)
                    XCTAssertTrue(settings.frame.contains(error.frame))
                }
                XCTAssertFalse(settings.popUpButtons["audio.dsee"].isEnabled)
                XCTAssertFalse(settings.popUpButtons["audio.surround"].isEnabled)
                XCTAssertEqual(settings.popUpButtons["audio.dsee"].value as? String, language == "tr" ? "Bilinmiyor" : "Unknown")
                XCTAssertEqual(settings.popUpButtons["audio.surround"].value as? String, language == "tr" ? "Bilinmiyor" : "Unknown")
                captureGalleryScreenshot(settings.screenshot(), named: "Legacy optional read timeout — \(language), \(phase)")
            }
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
            panel.buttons["test.optionalRead.recover"].click()
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
            for message in messages { XCTAssertTrue(settings.staticTexts[message].waitForNonExistence(timeout: 3)) }
            let dsee = settings.popUpButtons["audio.dsee"]
            let surround = settings.popUpButtons["audio.surround"]
            XCTAssertTrue(dsee.isEnabled)
            XCTAssertTrue(surround.isEnabled)
            XCTAssertTrue(dsee.isHittable)
            XCTAssertTrue(surround.isHittable)
            surround.click()
            app.menuItems[language == "tr" ? "Konser Salonu" : "Concert Hall"].click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", language == "tr" ? "Konser Salonu" : "Concert Hall"), object: surround
            )], timeout: 3), .completed)
            captureGalleryScreenshot(settings.screenshot(), named: "Legacy optional read timeout — \(language), recovered native picker")
            app.terminate()
        }
    }

    @MainActor
    func testControlConnectionFailurePersistsUntilControlsReturn() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for language in ["en", "tr"] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--connection-lifecycle", "-AppleLanguages", "(\(language))",
                                   "-AppleLocale", language == "tr" ? "tr_TR" : "en_US"]
            app.launch()
            let window = app.windows["Headphone Controls"]
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            let success = window.descendants(matching: .any).matching(identifier: "headphones.connected").firstMatch
            XCTAssertFalse(success.exists)
            window.buttons["test.controlsBusy"].click()
            let status = window.descendants(matching: .any).matching(identifier: "headphones.connectionStatus").firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 3))
            XCTAssertEqual(status.value as? String ?? status.label, language == "tr" ? "Denetimlere bağlanılamadı" : "Couldn’t connect to controls")
            let retry = window.buttons["headphones.connect"]
            XCTAssertEqual(retry.label, language == "tr" ? "Yeniden Dene" : "Retry")
            XCTAssertTrue(retry.isEnabled)
            XCTAssertEqual(status.frame.midY, retry.frame.midY, accuracy: 1)
            XCTAssertTrue(window.frame.contains(status.frame))
            XCTAssertTrue(window.frame.contains(retry.frame))
            XCTAssertLessThan(status.frame.maxX, retry.frame.minX)
            let guidance = window.descendants(matching: .any).matching(identifier: "headphones.bluetoothSettings").firstMatch
            XCTAssertTrue(guidance.exists)
            XCTAssertTrue(window.frame.contains(guidance.frame))
            window.buttons["test.scheduleRetry"].click()
            XCTAssertTrue(retry.exists)
            XCTAssertTrue(retry.isEnabled)
            XCTAssertTrue(guidance.exists)
            XCTAssertEqual(status.value as? String ?? status.label, language == "tr" ? "Denetimlere bağlanılamadı" : "Couldn’t connect to controls")
            XCTAssertFalse(status.waitForNonExistence(timeout: 2.5))
            XCTAssertFalse(success.exists)
            captureGalleryScreenshot(window.screenshot(), named: "Controls — connection unavailable — \(language)")
            window.buttons["test.connectWF"].click()
            XCTAssertTrue(window.buttons["noiseControl.anc"].waitForExistence(timeout: 3))
            XCTAssertFalse(success.exists)
            captureGalleryScreenshot(window.screenshot(), named: "Controls — connection restored — \(language)")
            XCTAssertFalse(status.exists)
            XCTAssertFalse(retry.exists)
            XCTAssertTrue(window.buttons["noiseControl.anc"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testDisconnectedStateAndWHArtwork() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--disconnected", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["headphones.connect"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["noiseControl.anc"].exists)
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let disconnectedSettings = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: disconnectedSettings)
        XCTAssertTrue(disconnectedSettings.buttons["headphones.connect"].isHittable)
        let bluetoothSettings = disconnectedSettings.descendants(matching: .any)["headphones.bluetoothSettings"]
        XCTAssertTrue(bluetoothSettings.exists)
        for _ in 0..<3 where !bluetoothSettings.isHittable {
            disconnectedSettings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        XCTAssertTrue(bluetoothSettings.isHittable)
        let recovery = XCTAttachment(screenshot: disconnectedSettings.screenshot())
        recovery.name = "Headphones Settings recovery"
        recovery.lifetime = .keepAlways
        add(recovery)
        app.terminate()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--wh-device", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["device.artwork.whXM5"].waitForExistence(timeout: 3))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        screenshot.name = "WH Settings headphones symbol"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testCodecStatusAndDSEEInNativeSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        XCTAssertTrue(app.staticTexts["AAC"].waitForExistence(timeout: 3))
        let connection = settingsWindow.popUpButtons["audio.connectionMode"]
        XCTAssertTrue(connection.waitForExistence(timeout: 3))
        XCTAssertEqual(connection.value as? String, "Sound Quality")
        let dsee = settingsWindow.popUpButtons["audio.dsee"]
        XCTAssertTrue(dsee.waitForExistence(timeout: 3))
        dsee.click()
        app.menuItems["Off"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Off"), object: dsee)], timeout: 3), .completed)
        dsee.click()
        app.menuItems["Auto"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Auto"), object: dsee)], timeout: 3), .completed)
        let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        screenshot.name = "Native codec and DSEE settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testConnectionPreferenceOmitsUnverifiedLEAudio() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--left-disconnected", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let connection = settingsWindow.popUpButtons["audio.connectionMode"]
        XCTAssertTrue(connection.waitForExistence(timeout: 3))
        XCTAssertFalse(settingsWindow.staticTexts["audio.connectionModeRequirement"].exists)
        XCTAssertFalse(settingsWindow.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "LE Audio is experimental")).firstMatch.exists)
        connection.click()
        XCTAssertTrue(app.menuItems["Sound Quality"].exists)
        XCTAssertTrue(app.menuItems["Stable Connection"].exists)
        XCTAssertFalse(app.menuItems["Low Latency"].exists)
    }

    @MainActor
    func testConnectionPreferenceRequiresTheHeadphoneConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let connection = settingsWindow.popUpButtons["audio.connectionMode"]
        XCTAssertTrue(connection.waitForExistence(timeout: 3))
        connection.click()
        app.menuItems["Stable Connection"].click()
        let cancel = settingsWindow.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()
        XCTAssertEqual(connection.value as? String, "Sound Quality")
        connection.click()
        app.menuItems["Stable Connection"].click()
        let proceed = settingsWindow.sheets.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 3))
        let alert = XCTAttachment(screenshot: app.screenshot())
        alert.name = "Sony connection confirmation in a native alert"
        alert.lifetime = .keepAlways
        add(alert)
        proceed.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Stable Connection"), object: connection)], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["AAC"].exists)
    }

    @MainActor
    func testLegacyConnectionPreferenceSeparatesHostConsentFromTheDeviceOffer() {
        for variant in ["light", "dark", "caution", "hidden"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM4",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if variant != "hidden" { app.launchArguments.append("--legacy-connection-quality") }
            if variant == "dark" { app.launchArguments.append("--dark-appearance") }
            if variant == "caution" { app.launchArguments.append("--legacy-quality-caution") }
            app.launch()
            let settings = app.buttons["menu.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            selectSettingsPane("headphones", in: window)
            let picker = window.popUpButtons["audio.connectionMode"]
            if variant == "hidden" {
                XCTAssertFalse(picker.exists)
                app.terminate()
                continue
            }
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            XCTAssertEqual(picker.value as? String, "Sound Quality")
            picker.click()
            XCTAssertFalse(app.menuItems["Low Latency"].exists)
            app.menuItems["Stable Connection"].click()
            let cancel = window.sheets.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 3))
            XCTAssertTrue(window.sheets.buttons["Change Preference"].exists)
            cancel.click()
            XCTAssertEqual(picker.value as? String, "Sound Quality")
            for target in ["Stable Connection", "Sound Quality"] {
                picker.click()
                app.menuItems[target].click()
                let change = window.sheets.buttons["Change Preference"]
                XCTAssertTrue(change.waitForExistence(timeout: 3))
                change.click()
                if variant == "caution" {
                    let proceed = window.sheets.buttons["Continue"]
                    XCTAssertTrue(proceed.waitForExistence(timeout: 3))
                    XCTAssertTrue(window.sheets.staticTexts["Use Stable Connection?"].exists)
                    proceed.click()
                }
                let expected = variant == "caution" ? "Stable Connection" : target
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@ AND isEnabled == true", expected), object: picker)], timeout: 3), .completed)
            }
            let capture = XCTAttachment(screenshot: window.screenshot())
            capture.name = "Legacy connection preference — synthetic \(variant)"
            capture.lifetime = .keepAlways
            add(capture)
            app.terminate()
        }
    }

    @MainActor
    func testConnectionConfirmationReturnsToHeadphonesPane() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--delayed-connection-alert", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        for pane in ["general", "advanced"] {
            selectSettingsPane("headphones", in: settingsWindow)
            let connection = settingsWindow.popUpButtons["audio.connectionMode"]
            connection.click()
            app.menuItems["Stable Connection"].click()
            selectSettingsPane(pane, in: settingsWindow)
            let cancel = settingsWindow.sheets.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            let alert = XCTAttachment(screenshot: settingsWindow.screenshot())
            alert.name = "Connection confirmation received from \(pane)"
            alert.lifetime = .keepAlways
            add(alert)
            cancel.click()
            XCTAssertEqual(settingsWindow.title, "Headphones")
            XCTAssertEqual(connection.value as? String, "Sound Quality")
        }
    }

    @MainActor
    func testCompactMultipointSourceGridAndInlineActions() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--four-source-devices", "--dark-appearance", "-AppleLanguages", "(en)"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        let identifiers = ["02:00:00:00:00:01", "02:00:00:00:00:02", "02:00:00:00:00:04", "02:00:00:00:00:05"]
        let buttons = identifiers.map { panel.buttons["multipoint.sourcePicker.\($0)"] }
        XCTAssertTrue(buttons[0].waitForExistence(timeout: 5))
        XCTAssertEqual(buttons[0].frame.minY, buttons[1].frame.minY, accuracy: 1)
        XCTAssertEqual(buttons[2].frame.minY, buttons[3].frame.minY, accuracy: 1)
        XCTAssertGreaterThan(buttons[2].frame.minY, buttons[0].frame.maxY)
        XCTAssertLessThanOrEqual(buttons[0].frame.height, 30)
        XCTAssertEqual(buttons[0].frame.height, panel.buttons["Focus"].frame.height, accuracy: 1)
        XCTAssertGreaterThan(panel.staticTexts["Ambient Sound"].firstMatch.frame.minY, panel.buttons["Focus"].frame.maxY)
        XCTAssertGreaterThan(buttons[0].frame.minY, panel.staticTexts["Focus on Voice"].firstMatch.frame.maxY)
        XCTAssertLessThan(buttons[3].frame.maxY, panel.staticTexts["Equalizer"].firstMatch.frame.minY)
        buttons[3].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected for audio"), object: buttons[3])], timeout: 4), .completed)
        XCTAssertEqual(buttons[0].value as? String, "Not selected")
        captureGalleryScreenshot(panel.screenshot(), named: "Compact source selector — four connected devices")
        panel.buttons["multipoint.open"].click()
        let manager = app.descendants(matching: .any).matching(identifier: "multipoint.popover").firstMatch
        XCTAssertTrue(manager.waitForExistence(timeout: 3))
        XCTAssertTrue(manager.staticTexts["Connected"].firstMatch.exists)
        XCTAssertTrue(manager.staticTexts["Saved"].firstMatch.exists)
        let phone = manager.buttons["multipoint.select.02:00:00:00:00:02"]
        XCTAssertTrue(phone.isHittable)
        phone.hover()
        XCTAssertTrue(manager.buttons["multipoint.disconnect.02:00:00:00:00:02"].isHittable)
        phone.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected for audio"), object: phone)], timeout: 4), .completed)
        let saved = manager.descendants(matching: .any).matching(identifier: "multipoint.row.02:00:00:00:00:03").firstMatch
        saved.hover()
        XCTAssertFalse(manager.buttons["multipoint.connect.02:00:00:00:00:03"].isEnabled)
        XCTAssertTrue(manager.buttons["multipoint.bluetoothSettings"].exists)
        XCTAssertEqual(manager.buttons.matching(identifier: "multipoint.refresh").count, 1)
        captureGalleryScreenshot(manager.screenshot(), named: "Connected and saved devices — hover actions")
        manager.buttons["multipoint.select.02:00:00:00:00:05"].hover()
        manager.buttons["multipoint.disconnect.02:00:00:00:00:05"].click()
        XCTAssertTrue(manager.buttons["multipoint.select.02:00:00:00:00:05"].waitForNonExistence(timeout: 4))
        let connect = manager.buttons["multipoint.connect.02:00:00:00:00:03"]
        saved.hover()
        let connectReady = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: connect)], timeout: 4)
        captureGalleryScreenshot(manager.screenshot(), named: "Multipoint — after disconnect")
        XCTAssertEqual(connectReady, .completed, manager.debugDescription)
        if NSApplication.shared.isFullKeyboardAccessEnabled {
            manager.buttons["multipoint.refresh"].hover()
            for _ in 0..<16 where !connect.isHittable {
                app.typeKey(.tab, modifierFlags: [])
            }
            XCTAssertTrue(connect.isHittable, "Keyboard focus must reveal the saved-device action")
            app.typeKey(.tab, modifierFlags: [])
            app.typeKey(.space, modifierFlags: [])
        } else {
            connect.click()
        }
        XCTAssertTrue(manager.buttons["multipoint.select.02:00:00:00:00:03"].waitForExistence(timeout: 4))
        XCTAssertEqual(phone.value as? String, "Selected for audio")
    }

    @MainActor
    func testMultipointShortcutHidesWithOneConnectedSource() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            defer { app.terminate() }
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--\(appearance)-appearance", "-AppleLanguages", "(en)"]
            app.launch()
            let panel = app.windows["Headphone Controls"]
            let manage = panel.buttons["multipoint.open"]
            XCTAssertTrue(manage.waitForExistence(timeout: 5))
            manage.click()
            let disconnect = app.buttons["multipoint.disconnect.02:00:00:00:00:02"]
            let phone = app.buttons["multipoint.select.02:00:00:00:00:02"]
            XCTAssertTrue(phone.waitForExistence(timeout: 3))
            phone.hover()
            XCTAssertTrue(disconnect.waitForExistence(timeout: 3))
            let manager = app.descendants(matching: .any).matching(identifier: "multipoint.popover").firstMatch
            XCTAssertLessThanOrEqual(manager.frame.width, 322)
            XCTAssertLessThanOrEqual(manager.frame.height, 400)
            captureGalleryScreenshot(manager.screenshot(), named: "Compact multipoint — \(appearance)")
            disconnect.click()
            XCTAssertTrue(manage.waitForNonExistence(timeout: 5))
            XCTAssertTrue(panel.buttons["menu.settings"].isHittable)
        }
    }

    @MainActor
    func testMultipointProgressKeepsPopoverAndRowSize() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--hold-source-replies", "-AppleLanguages", "(en)"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.buttons["multipoint.open"].waitForExistence(timeout: 5))
        panel.buttons["multipoint.open"].click()
        let manager = app.descendants(matching: .any).matching(identifier: "multipoint.popover").firstMatch
        let phone = manager.buttons["multipoint.select.02:00:00:00:00:02"]
        XCTAssertTrue(phone.waitForExistence(timeout: 3))
        let frame = manager.frame
        let rowFrame = phone.frame
        phone.click()
        let changingSource = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Changing audio source…"), object: phone)], timeout: 3)
        captureGalleryScreenshot(manager.screenshot(), named: "Multipoint — pending source")
        XCTAssertEqual(changingSource, .completed, manager.debugDescription)
        XCTAssertEqual(manager.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(manager.frame.height, frame.height, accuracy: 1)
        XCTAssertEqual(phone.frame.height, rowFrame.height, accuracy: 1)
        XCTAssertEqual(phone.frame.width, rowFrame.width, accuracy: 1)
        captureGalleryScreenshot(manager.screenshot(), named: "Multipoint — progress inside device icon")
    }

    @MainActor
    func testMultipointDeviceActionProgressKeepsButtonAndRowSize() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--hold-source-replies", "-AppleLanguages", "(en)"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.buttons["multipoint.open"].waitForExistence(timeout: 5))
        panel.buttons["multipoint.open"].click()
        let manager = app.descendants(matching: .any).matching(identifier: "multipoint.popover").firstMatch
        let phone = manager.buttons["multipoint.select.02:00:00:00:00:02"]
        XCTAssertTrue(phone.waitForExistence(timeout: 3))
        phone.hover()
        let disconnect = manager.buttons["multipoint.disconnect.02:00:00:00:00:02"]
        XCTAssertTrue(disconnect.isHittable)
        let frame = manager.frame
        let rowFrame = phone.frame
        let buttonFrame = disconnect.frame
        disconnect.click()
        let progress = manager.activityIndicators["multipoint.progress.02:00:00:00:00:02"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertEqual(progress.label, "Disconnecting device…")
        manager.staticTexts["Connected"].firstMatch.hover()
        XCTAssertFalse(disconnect.exists)
        XCTAssertTrue(progress.isHittable)
        XCTAssertEqual(phone.value as? String, "Disconnecting device…")
        XCTAssertEqual(manager.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(manager.frame.height, frame.height, accuracy: 1)
        XCTAssertEqual(phone.frame.width, rowFrame.width, accuracy: 1)
        XCTAssertEqual(phone.frame.height, rowFrame.height, accuracy: 1)
        XCTAssertEqual(progress.frame.midX, buttonFrame.midX, accuracy: 1)
        XCTAssertEqual(progress.frame.midY, buttonFrame.midY, accuracy: 1)
        captureGalleryScreenshot(manager.screenshot(), named: "Multipoint — pending disconnect without button")
    }

    @MainActor
    func testMultipointSettingRequiresConfirmationAndSupportsBothDirections() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.buttons["multipoint.open"].click()
        let manager = app.descendants(matching: .any).matching(identifier: "multipoint.popover").firstMatch
        let compactMultipoint = manager.descendants(matching: .any).matching(identifier: "multipoint.enabled").firstMatch
        XCTAssertTrue(compactMultipoint.waitForExistence(timeout: 3))
        compactMultipoint.click()
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let cancel = window.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertEqual(window.sheets.count, 1)
        XCTAssertFalse(app.buttons["multipoint.reviewChange"].exists)
        cancel.click()
        XCTAssertTrue(window.sheets.firstMatch.waitForNonExistence(timeout: 3))
        selectSettingsPane("headphones", in: window)
        let multipoint = window.descendants(matching: .any).matching(identifier: "multipoint.enabled").firstMatch
        XCTAssertTrue(multipoint.waitForExistence(timeout: 3))
        for _ in 0..<5 where !multipoint.isHittable {
            window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertEqual(multipoint.value as? Int, 1)
        multipoint.click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(window.buttons["multipoint.reviewChange"].exists)
        cancel.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 1 AND isEnabled == true"), object: multipoint
        )], timeout: 4), .completed)
        multipoint.click()
        let proceed = window.sheets.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 3))
        XCTAssertFalse(window.buttons["multipoint.reviewChange"].exists)
        proceed.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 0 AND isEnabled == true"), object: multipoint
        )], timeout: 4), .completed)
        XCTAssertFalse(window.staticTexts["multipoint.settingError"].exists)

        for cancelWarning in [true, false] {
            multipoint.click()
            XCTAssertTrue(proceed.waitForExistence(timeout: 3))
            XCTAssertTrue(window.sheets.staticTexts["Enable multipoint?"].exists)
            let warningText = "Audio may cut out when Sound Quality and multipoint are both enabled."
            let message = window.sheets.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", warningText, warningText
            )).firstMatch
            XCTAssertTrue(message.exists)
            XCTAssertTrue((message.value as? String ?? message.label).contains("Changing this setting may briefly disconnect the headphones. Reconnect them if needed."))
            XCTAssertEqual(app.sheets.count, 1)
            XCTAssertFalse(window.buttons["multipoint.reviewChange"].exists)
            XCTAssertEqual(multipoint.value as? Int, 0)
            if cancelWarning {
                XCTAssertTrue(cancel.waitForExistence(timeout: 3))
                cancel.click()
            } else {
                XCTAssertTrue(proceed.waitForExistence(timeout: 3))
                proceed.click()
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %d AND isEnabled == true", cancelWarning ? 0 : 1), object: multipoint
            )], timeout: 4), .completed)
            XCTAssertFalse(window.staticTexts["multipoint.settingError"].exists)
            XCTAssertTrue(window.sheets.firstMatch.waitForNonExistence(timeout: 3))
            XCTAssertEqual(app.sheets.count, 0)
        }
    }

    @MainActor
    func testMultipointSourceSelectionAndKeepingUseConfirmedState() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--\(appearance)-appearance", "-AppleLanguages", "(en)"]
            app.launch()
            app.windows["Headphone Controls"].buttons["menu.settings"].click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            selectSettingsPane("headphones", in: window)
            XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "audio.macOutput").firstMatch.exists)
            let phoneButton = window.buttons["multipoint.select.02:00:00:00:00:02"]
            XCTAssertTrue(phoneButton.waitForExistence(timeout: 3))
            for _ in 0..<5 where !phoneButton.isHittable {
                window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
            }
            phoneButton.hover()
            XCTAssertTrue(window.buttons["multipoint.disconnect.02:00:00:00:00:02"].isHittable)
            XCTAssertEqual(window.buttons.matching(identifier: "multipoint.refresh").count, 1)
            phoneButton.click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected for audio"), object: phoneButton)], timeout: 4), .completed)
            let keeping = window.descendants(matching: .any).matching(identifier: "multipoint.keeping").firstMatch
            for _ in 0..<5 where !keeping.isHittable {
                window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -120)
            }
            XCTAssertTrue(keeping.isHittable)
            keeping.click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: keeping)], timeout: 4), .completed)
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "Multipoint — \(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let macButton = window.buttons["multipoint.select.02:00:00:00:00:01"]
            for _ in 0..<5 where !macButton.isHittable {
                window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 120)
            }
            macButton.click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected for audio"), object: macButton)], timeout: 4), .completed)
            XCTAssertEqual(keeping.value as? Int, 0)
            XCTAssertFalse(window.staticTexts["multipoint.error"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testVoiceAssistantUsesAdvertisedNativePickerAndConfirmedSelection() {
        for state in ["light", "dark", "unknown", "hidden"] {
            let app = XCUIApplication()
            defer { app.terminate() }
            app.launchArguments = ["-ui-testing", "--ui-test-host", state == "dark" ? "--dark-appearance" : "--light-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if state != "hidden" {
                app.launchArguments.append(state == "unknown" ? "--assistant-selection-unknown" : "--assistant-selection")
            }
            app.launch()
            let settings = app.buttons["menu.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            selectSettingsPane("headphones", in: window)
            let picker = window.popUpButtons["system.voiceAssistant"]
            if state == "hidden" {
                XCTAssertFalse(picker.exists)
            } else {
                XCTAssertTrue(picker.waitForExistence(timeout: 3))
                for _ in 0..<6 where !picker.isHittable {
                    window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -220)
                }
                if state == "unknown" {
                    XCTAssertEqual(picker.value as? String, "Unknown")
                    XCTAssertFalse(picker.isEnabled)
                } else {
                    XCTAssertTrue(picker.isEnabled)
                    XCTAssertEqual(picker.value as? String, "Mobile device assistant")
                    for expected in ["Amazon Alexa", "None", "Mobile device assistant"] {
                        picker.click()
                        XCTAssertTrue(app.menuItems["Google Assistant"].exists)
                        XCTAssertTrue(app.menuItems["Tencent Xiaowei"].exists)
                        XCTAssertFalse(app.menuItems["Sony voice assistant"].exists)
                        XCTAssertFalse(app.menuItems["Siri"].exists)
                        app.menuItems[expected].click()
                        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                            predicate: NSPredicate(format: "value == %@ AND isEnabled == true", expected), object: picker)], timeout: 3), .completed)
                    }
                }
                let capture = XCTAttachment(screenshot: window.screenshot())
                capture.name = "Voice assistant — synthetic \(state) state"
                capture.lifetime = .keepAlways
                add(capture)
            }
        }
    }

    @MainActor
    func testLegacyAutomaticPowerOffUsesAdvertisedNativePicker() {
        for advertised in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM4", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if advertised { app.launchArguments.append("--legacy-power") }
            app.launch()
            let settings = app.buttons["menu.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            selectSettingsPane("headphones", in: window)
            let picker = window.popUpButtons["system.automaticPowerOff"]
            if advertised {
                XCTAssertTrue(picker.waitForExistence(timeout: 3))
                for _ in 0..<6 where !picker.isHittable {
                    window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
                }
                XCTAssertTrue(picker.isEnabled)
                XCTAssertEqual(picker.value as? String, "When removed")
                for expected in ["After 30 minutes", "Never", "When removed"] {
                    picker.click()
                    XCTAssertFalse(app.menuItems["After 15 minutes"].exists)
                    app.menuItems[expected].click()
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@ AND isEnabled == true", expected), object: picker)], timeout: 3), .completed)
                }
                let capture = XCTAttachment(screenshot: window.screenshot())
                capture.name = "Legacy automatic power off — synthetic advertised capability"
                capture.lifetime = .keepAlways
                add(capture)
            } else {
                XCTAssertFalse(picker.exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testLegacyPauseOnRemovalUsesConfirmedNativeToggleOnlyWhenAdvertised() {
        for advertised in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "whXM4", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if advertised { app.launchArguments.append("--legacy-wearing") }
            app.launch()
            let settings = app.buttons["menu.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            selectSettingsPane("headphones", in: window)
            let pause = window.descendants(matching: .any).matching(identifier: "system.1").firstMatch
            if advertised {
                XCTAssertTrue(pause.waitForExistence(timeout: 3))
                for _ in 0..<6 where !pause.isHittable {
                    window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
                }
                XCTAssertTrue(pause.isEnabled)
                XCTAssertEqual(pause.value as? Int, 0)
                for expected in [1, 0] {
                    pause.click()
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %d AND isEnabled == true", expected), object: pause)], timeout: 3), .completed)
                }
                let capture = XCTAttachment(screenshot: window.screenshot())
                capture.name = "Legacy pause on removal — synthetic advertised capability"
                capture.lifetime = .keepAlways
                add(capture)
            } else {
                XCTAssertFalse(pause.exists)
                XCTAssertFalse(window.staticTexts["Pause when removed"].exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testVoiceAssistantWakeWordUsesConfirmedStateAndExplicitVisibility() throws {
        for fixture in ["--voice-assistant", "--voice-assistant-invisible", ""] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if !fixture.isEmpty { app.launchArguments.append(fixture) }
            app.launch()
            let settings = app.buttons["menu.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            selectSettingsPane("headphones", in: window)
            let wakeWord = window.descendants(matching: .any).matching(identifier: "system.5").firstMatch
            if fixture == "--voice-assistant" {
                XCTAssertTrue(wakeWord.waitForExistence(timeout: 3))
                for _ in 0..<6 where !wakeWord.isHittable {
                    window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
                }
                XCTAssertTrue(wakeWord.isEnabled)
                XCTAssertEqual(wakeWord.value as? Int, 0)
                for expected in [1, 0] {
                    wakeWord.click()
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %d AND isEnabled == true", expected), object: wakeWord)], timeout: 3), .completed)
                }
                let capture = XCTAttachment(screenshot: window.screenshot())
                capture.name = "Voice assistant wake word — synthetic advertised capability"
                capture.lifetime = .keepAlways
                add(capture)
            } else {
                XCTAssertFalse(wakeWord.exists)
                XCTAssertFalse(window.staticTexts["Voice assistant wake word"].exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testTouchNoiseCycleUsesConfirmedNativePickersAndSharedScope() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--touch-customization", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: window)
        let left = window.popUpButtons["touch.action.0.0"]
        XCTAssertTrue(left.waitForExistence(timeout: 3))
        for _ in 0..<6 where !left.isHittable {
            window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(left.isHittable)
        XCTAssertEqual(left.value as? String, "Noise Cancelling / Ambient Sound")
        XCTAssertFalse(window.staticTexts["touch.shared.0.0"].exists)
        let leftAssignment = window.popUpButtons["touch.assignment.0"]
        let rightAssignment = window.popUpButtons["touch.assignment.1"]
        let noiseAssignment = try XCTUnwrap(leftAssignment.value as? String)
        left.click()
        app.menuItems["Noise Cancelling / Off"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Noise Cancelling / Off"), object: left)], timeout: 3), .completed)
        XCTAssertEqual(rightAssignment.value as? String, "Playback Control")
        XCTAssertEqual(leftAssignment.value as? String, noiseAssignment)
        rightAssignment.click()
        app.menuItems[noiseAssignment].click()
        let right = window.popUpButtons["touch.action.1.0"]
        XCTAssertTrue(right.waitForExistence(timeout: 3))
        XCTAssertEqual(right.value as? String, "Noise Cancelling / Off")
        XCTAssertTrue(window.staticTexts["touch.shared.0.0"].exists)
        XCTAssertTrue(window.staticTexts["touch.shared.1.0"].exists)
        right.click()
        app.menuItems["Ambient Sound / Off"].click()
        for picker in [left, right] {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Ambient Sound / Off"), object: picker)], timeout: 3), .completed)
        }
        let capture = XCTAttachment(screenshot: window.screenshot())
        capture.name = "Touch noise cycle — synthetic shared-preset capability"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testLegacyAssignmentsUseNativePickersAndGenerationSpecificGestures() {
        for model in ["wfXM4", "whXM3"] {
            for appearance in ["light", "dark", "hidden"] {
                let app = XCUIApplication()
                app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", model,
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                if appearance != "hidden" { app.launchArguments.append("--legacy-assignments") }
                if appearance == "dark" { app.launchArguments.append("--dark-appearance") }
                app.launch()
                let settings = app.buttons["menu.settings"]
                XCTAssertTrue(settings.waitForExistence(timeout: 5))
                settings.click()
                let window = app.windows["com_apple_SwiftUI_Settings_window"]
                selectSettingsPane("headphones", in: window)
                let key = model == "wfXM4" ? "0" : "2"
                let picker = window.popUpButtons["touch.assignment.\(key)"]
                if appearance == "hidden" {
                    XCTAssertFalse(picker.exists)
                } else {
                    XCTAssertTrue(picker.waitForExistence(timeout: 3))
                    for _ in 0..<6 where !picker.isHittable {
                        window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
                    }
                    XCTAssertEqual(picker.value as? String, "Ambient Sound Control")
                    XCTAssertTrue(picker.isEnabled)
                    XCTAssertFalse(window.popUpButtons["touch.action.\(key).0"].exists)
                    if model == "wfXM4" {
                        let right = window.popUpButtons["touch.assignment.1"]
                        XCTAssertEqual(right.value as? String, "Playback Control")
                        XCTAssertLessThan(picker.frame.maxX, right.frame.minX)
                        XCTAssertEqual(picker.frame.midY, right.frame.midY, accuracy: 1)
                    } else {
                        XCTAssertEqual(window.staticTexts["touch.gesture.2.16"].value as? String,
                                       "Press and hold: Noise Cancelling Optimizer")
                    }
                    let target = model == "wfXM4" ? "Volume Control" : "Google Assistant"
                    picker.click()
                    app.menuItems[target].click()
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@ AND isEnabled == true", target), object: picker)], timeout: 3), .completed)
                    if model == "wfXM4" {
                        XCTAssertEqual(window.staticTexts["touch.gesture.0.0"].value as? String, "Tap: Volume up")
                        XCTAssertEqual(window.staticTexts["touch.gesture.0.1"].value as? String, "Double tap: Volume down")
                        XCTAssertEqual(window.popUpButtons["touch.assignment.1"].value as? String, "Playback Control")
                    }
                    let capture = XCTAttachment(screenshot: window.screenshot())
                    capture.name = "Legacy assignments — synthetic \(model) \(appearance)"
                    capture.lifetime = .keepAlways
                    add(capture)
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testTouchAssignmentsPreserveTheOtherEarbud() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let left = settingsWindow.descendants(matching: .any).matching(identifier: "touch.assignment.0").firstMatch
        let right = settingsWindow.descendants(matching: .any).matching(identifier: "touch.assignment.1").firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 3))
        for _ in 0..<6 where !left.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(left.isHittable)
        XCTAssertTrue(right.isHittable)
        XCTAssertLessThan(left.frame.maxX, right.frame.minX)
        XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 1)
        XCTAssertEqual(left.elementType, .popUpButton)
        XCTAssertEqual(right.elementType, .popUpButton)
        let original = try XCTUnwrap(left.value as? String)
        XCTAssertNotEqual(original, "Playback Control")
        XCTAssertEqual(right.value as? String, "Playback Control")
        let leftGesture = settingsWindow.staticTexts["touch.gesture.0.0"]
        let rightGesture = settingsWindow.staticTexts["touch.gesture.1.0"]
        XCTAssertEqual(leftGesture.value as? String, "Tap: Noise Cancelling / Ambient Sound / Off")
        XCTAssertEqual(rightGesture.value as? String, "Tap: Play / Pause")
        XCTAssertEqual(settingsWindow.staticTexts["touch.gesture.1.1"].value as? String, "Double tap: Next track")
        XCTAssertEqual(settingsWindow.staticTexts["touch.gesture.1.2"].value as? String, "Triple tap: Previous track")
        XCTAssertEqual(settingsWindow.staticTexts["touch.gesture.1.16"].value as? String, "Tap and hold: Voice Assistant")
        left.click()
        app.menuItems["Playback Control"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playback Control"), object: left)], timeout: 3), .completed)
        XCTAssertEqual(right.value as? String, "Playback Control")
        XCTAssertEqual(leftGesture.value as? String, "Tap: Play / Pause")
        XCTAssertEqual(rightGesture.value as? String, "Tap: Play / Pause")
        left.click()
        app.menuItems[original].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", original), object: left)], timeout: 3), .completed)
        selectSettingsPane("general", in: settingsWindow)
        selectSettingsPane("headphones", in: settingsWindow)
        XCTAssertEqual(left.value as? String, original)
        XCTAssertEqual(right.value as? String, "Playback Control")
        XCTAssertEqual(leftGesture.value as? String, "Tap: Noise Cancelling / Ambient Sound / Off")
        XCTAssertEqual(rightGesture.value as? String, "Tap: Play / Pause")
        for _ in 0..<6 where !left.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        }
        let holdGesture = settingsWindow.staticTexts["touch.gesture.1.16"]
        for _ in 0..<4 where !holdGesture.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        screenshot.name = "Independent left and right touch assignments"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        left.click()
        let qualifiedAssignment = "Ambient Sound & Quick Access (Classic only)"
        app.menuItems[qualifiedAssignment].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", qualifiedAssignment), object: left)], timeout: 3), .completed)
        XCTAssertEqual(right.value as? String, "Playback Control")
        XCTAssertEqual(left.elementType, .popUpButton)
        let qualifiedScreenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        qualifiedScreenshot.name = "Native touch pop-up with qualified selection"
        qualifiedScreenshot.lifetime = .keepAlways
        add(qualifiedScreenshot)
    }

    @MainActor
    func testFindEarbudsIsHiddenForUnqualifiedFirmwareAndModels() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for (model, language, appearance) in [("wfXM5", "en", "light"), ("wfXM4", "tr", "dark")] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", model,
                                   "--\(appearance)-appearance", "-AppleLanguages", "(\(language))",
                                   "-AppleLocale", language == "tr" ? "tr_TR" : "en_US"]
            app.launch()
            let panel = app.windows["Headphone Controls"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.buttons["menu.settings"].click()
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            let tab = settings.toolbars.buttons[language == "tr" ? "Kulaklıklar" : "Headphones"]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.click()
            let device = settings.staticTexts["headphones.deviceName"]
            XCTAssertTrue(device.waitForExistence(timeout: 3))
            XCTAssertEqual(device.value as? String, model == "wfXM5" ? "WF-1000XM5" : "WF-1000XM4")
            let heading = language == "tr" ? "Kulaklıkları Bul" : "Find Earbuds"
            let scroll = settings.scrollViews.firstMatch
            for _ in 0..<4 {
                XCTAssertFalse(settings.buttons["finder.open"].exists)
                XCTAssertFalse(settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", heading)).firstMatch.exists)
                XCTAssertFalse(app.sheets.firstMatch.exists)
                scroll.scroll(byDeltaX: 0, deltaY: -400)
            }
            XCTAssertFalse(settings.buttons["finder.open"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testFindEarbudsDisclosesUnavailableWearDetection() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for language in ["en", "tr"] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM5", "--finder-no-wear-sensor",
                                   "-AppleLanguages", "(\(language))", "-AppleLocale", language == "tr" ? "tr_TR" : "en_US"]
            app.launch()
            let panel = app.windows["Headphone Controls"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.buttons["menu.settings"].click()
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            let tab = settings.toolbars.buttons[language == "tr" ? "Kulaklıklar" : "Headphones"]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.click()
            let open = settings.buttons["finder.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 3))
            for _ in 0..<5 where !open.isHittable {
                settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
            }
            open.click()
            let warning = app.staticTexts["finder.wearingUnavailable"]
            XCTAssertTrue(warning.waitForExistence(timeout: 3))
            let expected = language == "tr"
                ? "Acouplet, bu kulaklıkların kulağınızda olup olmadığını algılayamıyor."
                : "Acouplet can’t detect whether these earbuds are in your ears."
            XCTAssertEqual(warning.value as? String, expected)
            XCTAssertTrue(settings.frame.contains(warning.frame))
            XCTAssertFalse(settings.buttons["finder.stop"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testFindEarbudsCanPlayAgainAfterDismissalAndSettingsRemainUsable() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for failure in [nil, "--finder-missing-ack", "--finder-rejected-start", "--finder-early-stop"] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM5", "--finder-no-wear-sensor", "--finder-auth-success",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if let failure { app.launchArguments.append(failure) }
            app.launch()
            let panel = app.windows["Headphone Controls"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.buttons["menu.settings"].click()
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            settings.toolbars.buttons["Headphones"].click()
            let open = settings.buttons["finder.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 3))
            for target in ["left", "right"] {
                for _ in 0..<5 where !open.isHittable {
                    settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
                }
                open.click()
                let play = settings.buttons["finder.\(target)"]
                XCTAssertTrue(play.waitForExistence(timeout: 3))
                XCTAssertTrue(play.isEnabled)
                play.click()
                let confirm = settings.buttons["Play Sound"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 3))
                confirm.click()
                let proceed = settings.buttons["Play Anyway"]
                XCTAssertTrue(proceed.waitForExistence(timeout: 3))
                proceed.click()
                let authorizedPlay = settings.buttons["finder.authorizedPlay"]
                XCTAssertTrue(authorizedPlay.waitForExistence(timeout: 3))
                XCTAssertFalse(authorizedPlay.isEnabled)
                let verification = settings.checkBoxes["finder.verifyNotWorn"]
                XCTAssertTrue(verification.waitForExistence(timeout: 3))
                verification.click()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "isEnabled == true"), object: authorizedPlay
                )], timeout: 3), .completed)
                authorizedPlay.click()
                if failure == nil {
                    let ringing = "Playing a sound in the \(target) earbud."
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "label == %@ OR value == %@", ringing, ringing), object: app.staticTexts["finder.status"]
                    )], timeout: 5), .completed)
                    let stop = settings.buttons["finder.stop"]
                    XCTAssertTrue(stop.isEnabled)
                    stop.click()
                }
                let expected = failure == "--finder-rejected-start" ? "The earbuds declined the locating-sound request." : "Sound stopped."
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@ OR value == %@", expected, expected), object: app.staticTexts["finder.status"]
                )], timeout: 5), .completed)
                let done = settings.buttons["finder.done"]
                XCTAssertTrue(done.isEnabled)
                done.click()
                XCTAssertTrue(done.waitForNonExistence(timeout: 3))
                XCTAssertTrue(settings.toolbars.buttons["General"].isEnabled)
                settings.toolbars.buttons["General"].click()
                settings.toolbars.buttons["Headphones"].click()
            }
            app.terminate()
        }
    }

    @MainActor
    func testFindEarbudsShowsControlRecoveryAfterSoundStops() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM5", "--finder-no-wear-sensor", "--finder-auth-success",
                               "--finder-controls-lost-after-stop", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.buttons["menu.settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.toolbars.buttons["Headphones"].click()
        let open = settings.buttons["finder.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        for _ in 0..<5 where !open.isHittable {
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        open.click()
        settings.buttons["finder.left"].click()
        let confirm = settings.buttons["Play Sound"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.click()
        let proceed = settings.buttons["Play Anyway"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 3))
        proceed.click()
        let authorizedPlay = settings.buttons["finder.authorizedPlay"]
        XCTAssertTrue(authorizedPlay.waitForExistence(timeout: 3))
        XCTAssertFalse(authorizedPlay.isEnabled)
        let verification = settings.checkBoxes["finder.verifyNotWorn"]
        XCTAssertTrue(verification.waitForExistence(timeout: 3))
        verification.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: authorizedPlay
        )], timeout: 3), .completed)
        authorizedPlay.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", "Playing a sound in the left earbud.", "Playing a sound in the left earbud."),
            object: app.staticTexts["finder.status"]
        )], timeout: 5), .completed)
        settings.buttons["finder.stop"].click()
        let sheet = app.sheets.firstMatch
        let reconnect = sheet.buttons["headphones.connect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 3))
        XCTAssertTrue(reconnect.isEnabled)
        XCTAssertTrue(sheet.descendants(matching: .any)["headphones.bluetoothSettings"].isHittable)
        XCTAssertFalse(sheet.buttons["finder.left"].isEnabled)
        XCTAssertFalse(sheet.buttons["finder.right"].isEnabled)
        XCTAssertFalse(sheet.staticTexts["Sound stopped."].exists)
        let done = sheet.buttons["finder.done"]
        XCTAssertTrue(done.isEnabled)
        done.click()
        XCTAssertTrue(done.waitForNonExistence(timeout: 3))
        settings.toolbars.buttons["General"].click()
        XCTAssertTrue(settings.descendants(matching: .any)["menuBar.keepIcon"].isHittable)
    }

    @MainActor
    func testFindEarbudsWearingConfirmationDefaultsToCancelAndWarnsOnlySelectedEarbud() {
        let app = XCUIApplication()
        defer { app.terminate() }
        for (language, appearance, target) in [("en", "light", "left"), ("tr", "dark", "right")] {
            app.launchArguments = ["-ui-testing", "--ui-test-host", "--gallery-model", "wfXM5", "--finder-worn", "--finder-auth-success",
                                   "--\(appearance)-appearance", "-AppleLanguages", "(\(language))",
                                   "-AppleLocale", language == "tr" ? "tr_TR" : "en_US"]
            app.launch()
            let panel = app.windows["Headphone Controls"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.buttons["menu.settings"].click()
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            let tab = settings.toolbars.buttons[language == "tr" ? "Kulaklıklar" : "Headphones"]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.click()
            let open = settings.buttons["finder.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 3))
            for _ in 0..<5 where !open.isHittable {
                settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
            }
            open.click()
            let sheet = app.sheets.firstMatch
            let play = settings.buttons["finder.\(target)"]
            let stop = settings.buttons["finder.stop"]
            let warning = settings.descendants(matching: .any)["finder.\(target)Warning"].firstMatch
            let otherWarning = settings.descendants(matching: .any)[target == "left" ? "finder.rightWarning" : "finder.leftWarning"].firstMatch
            let playSound = language == "tr" ? "Ses Çal" : "Play Sound"
            let playAnyway = language == "tr" ? "Yine de Çal" : "Play Anyway"
            let alertTitle = language == "tr" ? "Sağ kulaklık kulağa takılı olarak algılandı" : "Left earbud detected in ear"
            XCTAssertTrue(play.waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["finder.wearingUnavailable"].exists)
            XCTAssertFalse(stop.exists)
            XCTAssertFalse(warning.exists)
            XCTAssertFalse(otherWarning.exists)
            for confirmationStage in 0..<4 {
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "isEnabled == true"), object: play
                )], timeout: 3), .completed)
                play.click()
                let confirm = settings.buttons[playSound]
                XCTAssertTrue(confirm.waitForExistence(timeout: 3))
                confirm.click()
                let proceed = settings.buttons[playAnyway]
                XCTAssertTrue(proceed.waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts[alertTitle].exists)
                XCTAssertFalse(warning.exists)
                XCTAssertFalse(otherWarning.exists)
                if confirmationStage == 0 {
                    app.typeKey(.return, modifierFlags: [])
                    XCTAssertTrue(proceed.waitForNonExistence(timeout: 3))
                    XCTAssertTrue(stop.waitForNonExistence(timeout: 3))
                    XCTAssertFalse(warning.exists)
                    XCTAssertFalse(otherWarning.exists)
                } else {
                    captureGalleryScreenshot(settings.screenshot(), named: "find-earbuds-\(language)-\(appearance)-wearing-alert")
                    proceed.click()
                    let authorizedPlay = settings.buttons["finder.authorizedPlay"]
                    XCTAssertTrue(authorizedPlay.waitForExistence(timeout: 3))
                    let verification = settings.checkBoxes["finder.verifyNotWorn"]
                    XCTAssertTrue(verification.waitForExistence(timeout: 3))
                    XCTAssertEqual(verification.value as? Int, 0)
                    XCTAssertFalse(authorizedPlay.isEnabled)
                    let verificationText = language == "tr"
                        ? "Şu anda sağ kulaklığın kimsenin kulağında olmadığını onaylıyorum."
                        : "I verify that nobody is wearing the left earbud right now."
                    XCTAssertEqual(verification.label, verificationText)
                    captureGalleryScreenshot(settings.screenshot(), named: "find-earbuds-\(language)-\(appearance)-final-confirmation")
                    let expectedMessage = language == "tr"
                        ? "Şu anda bu kulaklığın kimsenin kulağında olmadığından EN UFAK BİR ŞÜPHEYE YER BIRAKMAYACAK KADAR EMİN MİSİNİZ? Bu işlem, Test User tarafından yetkilendirilmiş olarak kaydedilecek."
                        : "Are you ABSOLUTELY CERTAIN BEYOND ANY DOUBT that nobody is wearing the earbud right now? This action will be logged as authorized by Test User."
                    let finalMessage = app.staticTexts.matching(NSPredicate(format: "value == %@", expectedMessage)).firstMatch
                    XCTAssertTrue(finalMessage.exists)
                    XCTAssertEqual(finalMessage.value as? String, expectedMessage)
                    XCTAssertFalse(warning.exists)
                    XCTAssertFalse(otherWarning.exists)
                    XCTAssertTrue(settings.frame.contains(finalMessage.frame))
                    XCTAssertTrue(settings.frame.contains(verification.frame))
                    if confirmationStage == 1 {
                        app.typeKey(.return, modifierFlags: [])
                        XCTAssertTrue(authorizedPlay.waitForNonExistence(timeout: 3))
                        XCTAssertTrue(stop.waitForNonExistence(timeout: 3))
                        XCTAssertFalse(warning.exists)
                        XCTAssertFalse(otherWarning.exists)
                    } else {
                        verification.click()
                        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                            predicate: NSPredicate(format: "isEnabled == true"), object: authorizedPlay
                        )], timeout: 3), .completed)
                        XCTAssertEqual(verification.value as? Int, 1)
                        XCTAssertFalse(warning.exists)
                        verification.click()
                        XCTAssertEqual(verification.value as? Int, 0)
                        XCTAssertFalse(authorizedPlay.isEnabled)
                        verification.click()
                        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                            predicate: NSPredicate(format: "isEnabled == true"), object: authorizedPlay
                        )], timeout: 3), .completed)
                        if confirmationStage == 2 {
                            app.typeKey(.return, modifierFlags: [])
                            XCTAssertTrue(authorizedPlay.waitForNonExistence(timeout: 3))
                            XCTAssertTrue(stop.waitForNonExistence(timeout: 3))
                            XCTAssertFalse(warning.exists)
                            XCTAssertFalse(otherWarning.exists)
                        } else {
                            authorizedPlay.click()
                        }
                    }
                }
            }
            XCTAssertTrue(warning.waitForExistence(timeout: 3))
            XCTAssertFalse(otherWarning.exists)
            XCTAssertTrue(stop.waitForExistence(timeout: 3))
            XCTAssertTrue(stop.isEnabled)
            let warningText = language == "tr" ? "Bu kulaklık kulağınızdaysa DERHAL çıkarın!" : "If you’re wearing this earbud, take it out NOW!"
            XCTAssertEqual(warning.label, warningText)
            XCTAssertTrue(settings.frame.contains(sheet.frame))
            XCTAssertTrue(sheet.frame.contains(warning.frame))
            XCTAssertTrue(sheet.frame.contains(stop.frame))
            let textHeight = warningText.boundingRect(with: NSSize(width: warning.frame.width, height: .greatestFiniteMagnitude),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).height
            XCTAssertGreaterThanOrEqual(warning.frame.height + 1, textHeight)
            captureGalleryScreenshot(settings.screenshot(), named: "find-earbuds-\(language)-\(appearance)-wearing-warning")
            stop.click()
            XCTAssertTrue(warning.waitForNonExistence(timeout: 3))
            XCTAssertTrue(stop.waitForNonExistence(timeout: 3))
            XCTAssertFalse(otherWarning.exists)
            let stopped = language == "tr" ? "Ses durduruldu." : "Sound stopped."
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@ OR value == %@", stopped, stopped), object: app.staticTexts["finder.status"]
            )], timeout: 3), .completed)
            app.terminate()
        }
    }

    @MainActor
    func testEarTipFitUsesExplicitStartSeparateResultsAndConfirmedCleanup() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--fit-retry-both-good", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let open = settingsWindow.buttons["fit.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        for _ in 0..<5 where !open.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        let parentFrame = settingsWindow.frame
        let backgroundControls = [open, settingsWindow.buttons["gesture.open"], settingsWindow.descendants(matching: .any)["multipoint.enabled"].firstMatch]
        XCTAssertTrue(backgroundControls.allSatisfy(\.exists))
        let backgroundOrigins = backgroundControls.map { $0.frame.origin }
        open.click()
        let sheet = app.sheets.firstMatch
        let start = app.buttons["fit.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(backgroundControls.map { $0.frame.origin }, backgroundOrigins)
        XCTAssertFalse(app.staticTexts["Good seal"].exists)
        app.buttons["fit.cancel"].click()
        XCTAssertTrue(start.waitForNonExistence(timeout: 3))
        open.click()
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        let heading = sheet.staticTexts["fit.title"]
        XCTAssertTrue(heading.exists)
        let headingFrame = heading.frame
        let sheetFrame = sheet.frame
        XCTAssertFalse(headingFrame.isEmpty)
        start.click()
        let again = app.buttons["fit.again"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        let left = app.descendants(matching: .any)["fit.leftResult"].firstMatch
        let right = app.descendants(matching: .any)["fit.rightResult"].firstMatch
        XCTAssertTrue(left.exists)
        XCTAssertTrue(right.exists)
        XCTAssertEqual(right.value as? String, "Right, Adjust fit")
        XCTAssertLessThan(left.frame.midX, right.frame.midX)
        let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        screenshot.name = "Native ear-tip fit results, simulated"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let resultFrame = sheet.frame
        let done = app.buttons["fit.cancel"]
        let footerInset = resultFrame.maxY - done.frame.maxY
        XCTAssertEqual(resultFrame, sheetFrame)
        XCTAssertEqual(heading.frame, headingFrame)
        XCTAssertEqual(heading.value as? String, "Earbud Fit Test")
        let geometry = XCTAttachment(string: "Sheet: \(resultFrame)\nLeft: \(left.frame)\nRight: \(right.frame)\n" + sheet.debugDescription)
        geometry.name = "Ear-tip fit result accessibility geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertEqual(settingsWindow.frame, parentFrame)
        XCTAssertEqual(backgroundControls.map { $0.frame.origin }, backgroundOrigins)
        XCTAssertTrue(resultFrame.contains(left.frame), "Left result \(left.frame) must be inside sheet \(resultFrame)")
        XCTAssertTrue(resultFrame.contains(right.frame), "Right result \(right.frame) must be inside sheet \(resultFrame)")
        XCTAssertTrue(resultFrame.contains(again.frame))
        XCTAssertTrue(resultFrame.contains(done.frame))
        XCTAssertTrue(again.isHittable)
        XCTAssertTrue(done.isHittable)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Right, Good seal"), object: right)], timeout: 5), .completed)
        XCTAssertTrue(again.exists)
        XCTAssertFalse(start.exists)
        XCTAssertTrue(left.exists)
        XCTAssertTrue(right.exists)
        let repeatedScreenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        repeatedScreenshot.name = "Native ear-tip fit repeated results, retained sheet height"
        repeatedScreenshot.lifetime = .keepAlways
        add(repeatedScreenshot)
        XCTAssertEqual(sheet.frame, sheetFrame)
        XCTAssertEqual(heading.frame, headingFrame)
        XCTAssertEqual(sheet.frame.maxY - done.frame.maxY, footerInset, accuracy: 1)
        XCTAssertEqual(settingsWindow.frame, parentFrame)
        XCTAssertEqual(backgroundControls.map { $0.frame.origin }, backgroundOrigins)
        XCTAssertTrue(sheet.frame.contains(left.frame))
        XCTAssertTrue(sheet.frame.contains(right.frame))
        XCTAssertTrue(sheet.frame.contains(again.frame))
        XCTAssertTrue(again.isHittable)
        XCTAssertTrue(done.isHittable)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(again.waitForNonExistence(timeout: 3))
        XCTAssertTrue(open.isEnabled)
        XCTAssertEqual(backgroundControls.map { $0.frame.origin }, backgroundOrigins)
        open.click()
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    @MainActor
    func testEarTipFitGoodResultsUseDoneAsDefaultAndRetainEscape() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--fit-both-good", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let open = settingsWindow.buttons["fit.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        for _ in 0..<5 where !open.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        let parentFrame = settingsWindow.frame
        let openOrigin = open.frame.origin
        for key in [XCUIKeyboardKey.return, .escape] {
            open.click()
            let sheet = app.sheets.firstMatch
            let start = app.buttons["fit.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 3))
            XCTAssertTrue(start.isEnabled)
            let heading = sheet.staticTexts["fit.title"]
            XCTAssertTrue(heading.exists)
            let headingFrame = heading.frame
            let sheetFrame = sheet.frame
            XCTAssertFalse(headingFrame.isEmpty)
            XCTAssertEqual(open.frame.origin, openOrigin)
            start.click()
            let again = app.buttons["fit.again"]
            XCTAssertTrue(again.waitForExistence(timeout: 5))
            let left = app.descendants(matching: .any)["fit.leftResult"].firstMatch
            let right = app.descendants(matching: .any)["fit.rightResult"].firstMatch
            XCTAssertEqual(left.value as? String, "Left, Good seal")
            XCTAssertEqual(right.value as? String, "Right, Good seal")
            let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
            screenshot.name = "Native ear-tip fit — both seals good, Done default"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertEqual(settingsWindow.frame, parentFrame)
            XCTAssertEqual(sheet.frame, sheetFrame)
            XCTAssertEqual(heading.frame, headingFrame)
            XCTAssertEqual(heading.value as? String, "Earbud Fit Test")
            XCTAssertEqual(open.frame.origin, openOrigin)
            XCTAssertTrue(sheet.frame.contains(left.frame))
            XCTAssertTrue(sheet.frame.contains(right.frame))
            XCTAssertTrue(sheet.frame.contains(app.buttons["fit.cancel"].frame))
            XCTAssertTrue(app.buttons["fit.cancel"].isHittable)
            app.typeKey(key, modifierFlags: [])
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
            XCTAssertTrue(open.isEnabled)
            XCTAssertEqual(open.frame.origin, openOrigin)
        }
    }

    @MainActor
    func testHeadGesturePracticeRequiresStartDetectsGesturesAndDismissesAfterDone() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let open = settingsWindow.buttons["gesture.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        for _ in 0..<5 where !open.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        let parentFrame = settingsWindow.frame
        open.click()
        let sheet = app.sheets.firstMatch
        let start = app.buttons["gesture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        let heading = sheet.staticTexts["gesture.title"]
        XCTAssertTrue(heading.exists)
        let headingFrame = heading.frame
        XCTAssertFalse(headingFrame.isEmpty)
        let instructions = "Wear both earbuds and face forward."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", instructions, instructions
        )).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["gesture.detected"].firstMatch.exists)
        let readyScreenshot = XCTAttachment(screenshot: sheet.screenshot())
        readyScreenshot.name = "Native head-gesture practice, stable ready sheet"
        readyScreenshot.lifetime = .keepAlways
        add(readyScreenshot)
        let sheetFrame = sheet.frame
        XCTAssertEqual(settingsWindow.frame, parentFrame)
        XCTAssertTrue(sheet.frame.contains(start.frame))
        XCTAssertTrue(start.isHittable)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(start.waitForNonExistence(timeout: 3))
        XCTAssertEqual(open.label, "Practice Head Gestures…")
        open.click()
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        let shake = sheet.radioButtons["Shake"]
        XCTAssertTrue(shake.exists)
        shake.click()
        start.click()
        let count = app.staticTexts["gesture.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", "1 of 3 gestures detected", "1 of 3 gestures detected"), object: count
        )], timeout: 3), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["gesture.detected"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["gesture.success"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: sheet.screenshot())
        screenshot.name = "Native head-gesture practice, simulated detections"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let done = app.buttons["gesture.cancel"]
        XCTAssertEqual(done.label, "Done")
        XCTAssertEqual(heading.frame, headingFrame)
        XCTAssertEqual(heading.value as? String, "Practice Head Gestures")
        XCTAssertEqual(sheet.frame, sheetFrame)
        XCTAssertEqual(settingsWindow.frame, parentFrame)
        XCTAssertTrue(sheet.frame.contains(count.frame))
        XCTAssertTrue(sheet.frame.contains(done.frame))
        XCTAssertTrue(done.isHittable)
        done.click()
        XCTAssertTrue(count.waitForNonExistence(timeout: 3))
        XCTAssertTrue(done.waitForNonExistence(timeout: 3))
        XCTAssertEqual(open.label, "Practice Head Gestures…")
        XCTAssertTrue(open.isEnabled)
        open.click()
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        let reopenedScreenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        reopenedScreenshot.name = "Native head-gesture practice, stable new presentation"
        reopenedScreenshot.lifetime = .keepAlways
        add(reopenedScreenshot)
        XCTAssertEqual(sheet.frame, sheetFrame)
        XCTAssertEqual(settingsWindow.frame, parentFrame)
        XCTAssertTrue(sheet.frame.contains(start.frame))
        XCTAssertTrue(start.isHittable)
        start.click()
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    @MainActor
    func testTurkishHeadGestureSelectorFitsAndStartsPractice() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "-AppleLanguages", "(tr)", "-AppleLocale", "tr_TR"]
        app.launch()
        defer { app.terminate() }
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        let headphones = settingsWindow.toolbars.buttons["Kulaklıklar"]
        XCTAssertTrue(headphones.waitForExistence(timeout: 3))
        headphones.click()
        let open = settingsWindow.buttons["gesture.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        for _ in 0..<5 where !open.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        open.click()
        let sheet = app.sheets.firstMatch
        let start = sheet.buttons["gesture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        let heading = sheet.staticTexts["gesture.title"]
        XCTAssertTrue(sheet.frame.contains(heading.frame))
        for label in ["Yukarı aşağı", "Sağa sola"] {
            let segment = sheet.radioButtons[label]
            XCTAssertTrue(segment.isHittable)
            XCTAssertTrue(sheet.frame.contains(segment.frame))
            let textWidth = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
            XCTAssertGreaterThanOrEqual(segment.frame.width, textWidth)
            XCTAssertLessThan(heading.frame.maxX, segment.frame.minX)
            segment.click()
        }
        XCTAssertTrue(sheet.staticTexts["İleriye bakın, ardından başınızı sağa sola hareket ettirin."].exists)
        let readyScreenshot = XCTAttachment(screenshot: sheet.screenshot())
        readyScreenshot.name = "Turkish head gestures — ready, full selector labels"
        readyScreenshot.lifetime = .keepAlways
        add(readyScreenshot)
        let sheetFrame = sheet.frame
        start.click()
        let count = sheet.staticTexts["gesture.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", "Algılanan hareket: 1 / 3", "Algılanan hareket: 1 / 3"), object: count
        )], timeout: 3), .completed)
        XCTAssertEqual(sheet.frame, sheetFrame)
        for label in ["Yukarı aşağı", "Sağa sola"] {
            let segment = sheet.radioButtons[label]
            XCTAssertTrue(segment.isHittable)
            XCTAssertTrue(sheet.frame.contains(segment.frame))
        }
        let practicingScreenshot = XCTAttachment(screenshot: sheet.screenshot())
        practicingScreenshot.name = "Turkish head gestures — practicing, one of three"
        practicingScreenshot.lifetime = .keepAlways
        add(practicingScreenshot)
        sheet.buttons["gesture.cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
        XCTAssertTrue(open.isEnabled)
    }

    @MainActor
    func testHeadGesturePracticeCompletesAfterThreeMatchingReportsAndResetsSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--head-gesture-practice-success", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let open = settingsWindow.buttons["gesture.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        for _ in 0..<5 where !open.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        open.click()
        let sheet = app.sheets.firstMatch
        let start = sheet.buttons["gesture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        let sheetFrame = sheet.frame
        sheet.radioButtons["Shake"].click()
        start.click()
        let success = sheet.descendants(matching: .any)["gesture.success"].firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 4))
        let count = sheet.staticTexts["gesture.count"]
        XCTAssertEqual(count.value as? String, "3 of 3 gestures detected")
        XCTAssertEqual(sheet.frame, sheetFrame)
        let done = sheet.buttons["gesture.cancel"]
        XCTAssertEqual(done.label, "Done")
        XCTAssertTrue(done.isEnabled)
        let screenshot = XCTAttachment(screenshot: sheet.screenshot())
        screenshot.name = "Head gestures — three matching reports, All set"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        sheet.radioButtons["Nod"].click()
        XCTAssertTrue(success.waitForNonExistence(timeout: 2))
        XCTAssertEqual(count.value as? String, "0 of 3 gestures detected")
        XCTAssertTrue(sheet.descendants(matching: .any)["gesture.waiting"].firstMatch.exists)
        sheet.radioButtons["Shake"].click()
        XCTAssertEqual(count.value as? String, "0 of 3 gestures detected")
        XCTAssertFalse(success.exists)
        done.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
        XCTAssertEqual(open.label, "Practice Head Gestures…")
    }

    @MainActor
    func testPowerOffConfirmationAndExplicitRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--connection-lifecycle", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.menuButtons["More"].click()
        app.menuItems["Turn Off Headphones…"].click()
        XCTAssertTrue(app.buttons["Turn Off"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["Turn Off"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["noiseControl.ambient"].isEnabled)
        app.menuButtons["More"].click()
        app.menuItems["Turn Off Headphones…"].click()
        app.buttons["Turn Off"].click()
        XCTAssertTrue(app.staticTexts["Power Off Requested"].waitForExistence(timeout: 3))
        let reconnect = app.buttons["headphones.connect"]
        XCTAssertTrue(reconnect.isEnabled)
        XCTAssertFalse(app.buttons["noiseControl.ambient"].exists)
        XCTAssertTrue(app.statusItems.firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.windows["Headphone Controls"].screenshot())
        screenshot.name = "Acknowledged power-off request with explicit recovery"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        reconnect.click()
        XCTAssertTrue(app.staticTexts["Power Off Requested"].waitForNonExistence(timeout: 3))
        app.buttons["Connect WF"].click()
        XCTAssertTrue(app.buttons["noiseControl.ambient"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testGuidanceVolumeMenuStaysOpenDuringSettingsRefresh() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--settings-lifecycle", "--light-appearance", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let panel = app.windows["Headphone Controls"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.buttons["Open Settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settings)
        let volume = settings.popUpButtons["guidance.volume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 3))
        for _ in 0..<6 where !volume.isHittable {
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(volume.isHittable)
        XCTAssertEqual(volume.value as? String, "Medium")
        let frame = settings.frame

        func snapshot() async throws -> [Substring] {
            let button = panel.buttons["Snapshot Settings Lifecycle"]
            button.click()
            try await Task.sleep(for: .milliseconds(150))
            button.click()
            let value = try XCTUnwrap(panel.staticTexts["test.settingsLifecycle"].value as? String)
            let fields = value.split(separator: "|", omittingEmptySubsequences: false)
            XCTAssertEqual(fields.count, 5, value)
            return fields
        }

        let before = try await snapshot()
        panel.buttons["Schedule Settings Refresh"].click()
        volume.click()
        let high = app.menuItems["High"]
        XCTAssertTrue(high.waitForExistence(timeout: 2))
        let codec = panel.staticTexts["test.settingsCodec"]
        XCTAssertEqual(codec.value as? String, "AAC")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "LDAC"), object: codec
        )], timeout: 8), .completed)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(high.exists)
        XCTAssertTrue(high.isHittable)
        XCTAssertEqual(volume.value as? String, "Medium")
        high.click()
        XCTAssertTrue(high.waitForNonExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "High"), object: volume
        )], timeout: 5), .completed)
        XCTAssertEqual(settings.frame, frame)
        let after = try await snapshot()
        XCTAssertEqual(after[1], "true")
        XCTAssertGreaterThan(try XCTUnwrap(Int(after[2])), try XCTUnwrap(Int(before[2])))
        XCTAssertEqual(Array(after.suffix(2)), Array(before.suffix(2)))
    }

    @MainActor
    func testVoiceGuidanceControlsPreserveSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "--ui-test-host", "--light-appearance", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Headphone Controls"].waitForExistence(timeout: 5))
        app.windows["Headphone Controls"].buttons["menu.settings"].click()
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsPane("headphones", in: settingsWindow)
        let enabled = settingsWindow.descendants(matching: .any)["guidance.enabled"]
        let volume = settingsWindow.popUpButtons["guidance.volume"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3))
        for _ in 0..<6 where !enabled.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(enabled.isHittable)
        XCTAssertEqual((enabled.value as? NSNumber)?.intValue, 1)
        XCTAssertEqual(volume.value as? String, "Medium")
        for value in [0, 1] {
            enabled.click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", NSNumber(value: value)), object: enabled)], timeout: 3), .completed)
        }
        for title in ["Very low", "Very high"] {
            volume.click()
            app.menuItems[title].click()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: volume)], timeout: 3), .completed)
        }
        selectSettingsPane("general", in: settingsWindow)
        selectSettingsPane("headphones", in: settingsWindow)
        XCTAssertEqual((enabled.value as? NSNumber)?.intValue, 1)
        XCTAssertEqual(volume.value as? String, "Very high")
        for _ in 0..<6 where !volume.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        }
        let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        screenshot.name = "Voice guidance toggle and volume"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
