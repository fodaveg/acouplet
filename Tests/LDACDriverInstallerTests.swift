import Combine
import XCTest
@testable import Acouplet

#if !ACOUPLET_PUBLIC_APIS_ONLY
@MainActor
final class LDACDriverInstallerTests: XCTestCase {
    func testInstallationDoesNotClaimLoadedDriverIsUpdated() {
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: nil, loaded: nil), .missing)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: nil, loaded: 1), .missing)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 0, loaded: 0), .outdated)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: nil), .restartRequired)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: 0), .restartRequired)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: 1), .current)
    }

    func testCompatibleDriverDoesNotRequireReinstallationForAppUpdates() {
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 2, loaded: 2), .current)
        XCTAssertEqual(LDACDriverInstaller.state(required: 2, installed: 1, loaded: 1), .outdated)
        XCTAssertEqual(LDACDriverInstaller.state(required: 2, installed: 2, loaded: 1), .restartRequired)
    }

    func testRefreshDistinguishesInstallationFromRestart() {
        var installed: Int? = 2
        var loaded: Int? = 2
        var inspections = 0
        let controller = LDACController(inspectDriver: { _ in
            inspections += 1
            return LDACDriverInstaller.state(required: 3, installed: installed, loaded: loaded)
        })
        var changes = 0
        let observation = controller.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        XCTAssertEqual(controller.driverState, .outdated)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 1)

        controller.refreshDriverState()
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(changes, 0)

        installed = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 3)
        XCTAssertEqual(changes, 1)

        loaded = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 4)
        XCTAssertEqual(changes, 1)

        loaded = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .current)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 5)
        XCTAssertEqual(changes, 2)

        installed = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .missing)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 6)
        XCTAssertEqual(changes, 3)
    }

    func testBackgroundRefreshOnlyInspectsWhenLDACIsEnabled() {
        var enabled = false
        var inspections = 0
        let controller = LDACController(inspectDriver: { _ in
            inspections += 1
            return .current
        }, isDriverInspectionEnabled: { enabled })
        XCTAssertEqual(inspections, 1)

        controller.refreshDriverStateInBackground()
        XCTAssertEqual(inspections, 1)

        enabled = true
        controller.refreshDriverStateInBackground()
        XCTAssertEqual(inspections, 2)
    }

    func testRefreshAfterCancelledInstallationStillRequiresUpdate() {
        let controller = LDACController(inspectDriver: { _ in
            LDACDriverInstaller.state(required: 3, installed: 2, loaded: 2)
        })
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .outdated)
        XCTAssertTrue(controller.canStartOrInstallDriver)
    }

    func testUntrustedBundleCannotOpenAnInstaller() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Untrusted.app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "example.untrusted", "CFBundlePackageType": "APPL", "AcoupletDistribution": "development"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("untrusted package".utf8).write(to: resources.appendingPathComponent("Acouplet LDAC Output.pkg"))
        try Data("untrusted package".utf8).write(to: resources.appendingPathComponent("Acouplet LDAC Removal.pkg"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        if case .unavailable = LDACDriverInstaller.inspect(bundle: bundle) {} else { XCTFail("Unsigned app must fail validation") }
        for removal in [false, true] {
            let package = resources.appendingPathComponent(removal ? "Acouplet LDAC Removal.pkg" : "Acouplet LDAC Output.pkg")
            for kind in ["unsigned", "missing", "linked"] {
                if kind == "missing" { try FileManager.default.removeItem(at: package) }
                if kind == "linked" {
                    let outside = directory.appendingPathComponent("outside.pkg")
                    try Data("untrusted package".utf8).write(to: outside)
                    try FileManager.default.createSymbolicLink(at: package, withDestinationURL: outside)
                }
                do {
                    if removal { try await LDACDriverInstaller.openUninstaller(bundle: bundle) }
                    else { try await LDACDriverInstaller.openInstaller(bundle: bundle) }
                    XCTFail("Untrusted package must not open Installer")
                } catch {
                    XCTAssertEqual((error as NSError).domain, kind == "missing" ? NSCocoaErrorDomain : "LDACDriverInstaller")
                }
            }
        }
    }
}

@MainActor
final class LDACConnectionPreferenceTests: XCTestCase {
    func testFinderDefersOwnedRestorationUntilStopIsConfirmed() async throws {
        for phase in [EarbudFindingSession.Phase.connecting, .starting, .ringing, .stopping, .unconfirmed] {
            let (coordinator, headphones, finder, request) = try preparedFinder()
            let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
            defer { finish(headphones) }
            finder.play(.left)
            if phase != .connecting { await openUnwornEarbud(finder, headphones: headphones) }
            if phase == .ringing {
                finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 2, 30]).encoded))
            } else if phase == .stopping { finder.stop() }
            else if phase == .unconfirmed { finder.simulateTransportFailure() }
            XCTAssertEqual(finder.session?.phase, phase)

            let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
            XCTAssertNil(error)
            XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(headphones.connectionMode, .soundQuality)

            headphones.simulateProtocolMessage([0x13, 1, 1, 1])
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)

            if phase == .unconfirmed {
                finder.retryStop()
                finder.simulateConnectionOpened()
            } else { finder.stop() }
            if finder.mayBeRinging {
                finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
            }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertNil(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address))
            XCTAssertNotEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(headphones.connectionTransition?.targetMode, .stableConnection)
            headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .positive)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(headphones.connectionMode, .stableConnection)
            XCTAssertEqual(headphones.connectionTransition?.phase, .confirmed)
        }
    }

    func testFinderDoesNotRetainSupersededConnectionPreferenceOwnership() async throws {
        let (coordinator, headphones, finder, _) = try preparedFinder()
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
        defer { finish(headphones) }
        finder.play(.left)
        await openUnwornEarbud(finder, headphones: headphones)
        let currentRequest = headphones.lastConnectionModeChangeID

        let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: UUID())

        XCTAssertNil(error)
        XCTAssertNil(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address))
        XCTAssertEqual(headphones.lastConnectionModeChangeID, currentRequest)
        XCTAssertEqual(finder.session?.phase, .starting)
    }

    func testStopWaitsForRunningPreferenceRestorationAndCompletesEveryHandlerOnce() async throws {
        for action in [SonyConnectionAlertAction.positive, .negative] {
            let (coordinator, headphones, finder, request) = try preparedFinder()
            let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
            defer { finish(headphones) }
            finder.play(.left)
            let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
            XCTAssertNil(error)
            finder.stop()
            for _ in 0..<20 { await Task.yield() }
            let alert = try XCTUnwrap(headphones.connectionTransition?.alert)
            XCTAssertFalse(ldac.isSessionRunning)
            XCTAssertTrue(ldac.needsStopBeforeTermination)
            var firstCompletions = 0
            var secondCompletions = 0

            ldac.stop { firstCompletions += 1 }
            ldac.stop { secondCompletions += 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(firstCompletions, 0)
            XCTAssertEqual(secondCompletions, 0)

            headphones.respondToConnectionAlert(alert, action: action)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(ldac.needsStopBeforeTermination)
            XCTAssertEqual(firstCompletions, 1)
            XCTAssertEqual(secondCompletions, 1)
            var laterCompletions = 0
            ldac.stop { laterCompletions += 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(firstCompletions, 1)
            XCTAssertEqual(secondCompletions, 1)
            XCTAssertEqual(laterCompletions, 1)
        }
    }

    func testStopDoesNotStartDeferredRestorationWhileFinderSoundIsUnconfirmed() async throws {
        let (coordinator, headphones, finder, request) = try preparedFinder()
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
        defer { finish(headphones) }
        finder.play(.left)
        await openUnwornEarbud(finder, headphones: headphones)
        finder.simulateTransportFailure()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
        XCTAssertNil(error)
        var completions = 0

        ldac.stop { completions += 1 }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(completions, 1)
        XCTAssertFalse(ldac.needsStopBeforeTermination)
        XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)
        XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
        XCTAssertTrue(finder.mayBeRinging)
    }

    func testDeferredPreferenceSurvivesQuitWithoutRestoringUntilRequestedAfterRelaunch() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (coordinator, headphones) = try preparedHeadphones()
        defer { finish(headphones) }
        headphones.setConnectionMode(.stableConnection)
        headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .positive)
        XCTAssertEqual(headphones.connectionMode, .stableConnection)
        var ldac: LDACController? = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })
        ldac?.simulateRecoverySession(headphones)
        let preparation = Task { try await ldac?.simulateConnectionPreferencePreparation(headphones) }
        for _ in 0..<20 { await Task.yield() }
        let request = try XCTUnwrap(headphones.lastConnectionModeChangeID)
        XCTAssertEqual(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[headphones.address] as? String, request.uuidString)
        headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .positive)
        try await preparation.value
        headphones.simulateControlLoss()
        ldac?.suspend()
        for _ in 0..<20 { await Task.yield() }
        ldac?.stop()
        XCTAssertFalse(try XCTUnwrap(ldac).needsStopBeforeTermination)
        ldac = nil

        let (nextCoordinator, nextHeadphones) = try preparedHeadphones()
        defer { finish(nextHeadphones) }
        let relaunched = LDACController(devices: nextCoordinator, defaults: defaults, inspectDriver: { _ in .current })
        nextCoordinator.objectWillChange.send()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(relaunched.hasPendingConnectionPreferenceRestoration(forAddress: nextHeadphones.address))
        XCTAssertTrue(relaunched.canRestoreConnectionPreference(forAddress: nextHeadphones.address))
        XCTAssertNil(nextHeadphones.lastConnectionModeChangeID)
        XCTAssertNil(nextHeadphones.connectionTransition)
        relaunched.stop()
        XCTAssertNil(nextHeadphones.lastConnectionModeChangeID)

        relaunched.restorePendingConnectionPreference(forAddress: nextHeadphones.address)
        let restoration = try XCTUnwrap(nextHeadphones.lastConnectionModeChangeID)
        XCTAssertNotEqual(restoration, request)
        XCTAssertEqual(nextHeadphones.connectionTransition?.targetMode, .stableConnection)
        nextHeadphones.respondToConnectionAlert(try XCTUnwrap(nextHeadphones.connectionTransition?.alert), action: .positive)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(relaunched.needsStopBeforeTermination)
        XCTAssertEqual(nextHeadphones.connectionMode, .stableConnection)
        XCTAssertFalse(relaunched.hasPendingConnectionPreferenceRestoration(forAddress: nextHeadphones.address))
        XCTAssertNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[nextHeadphones.address])
    }

    func testRelaunchDoesNotOverwriteLaterPhonePreferenceOrAnotherDevice() async throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (coordinator, headphones) = try preparedHeadphones()
        defer { finish(headphones) }
        let otherAddress = "02:53:4F:4E:59:02"
        defaults.set([headphones.address: UUID().uuidString, otherAddress: UUID().uuidString], forKey: "ldac.pendingConnectionPreferences")
        let ldac = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })

        headphones.simulateProtocolMessage([0xE9, 5, 1, 0])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(headphones.connectionMode, .stableConnection)
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
        XCTAssertTrue(ldac.hasPendingConnectionPreferenceRestoration(forAddress: otherAddress))
        XCTAssertFalse(ldac.canRestoreConnectionPreference(forAddress: otherAddress))
        XCTAssertNil(headphones.lastConnectionModeChangeID)
        headphones.simulateProtocolMessage([0xE9, 5, 0, 0])
        for _ in 0..<20 { await Task.yield() }
        ldac.restorePendingConnectionPreference(forAddress: headphones.address)
        XCTAssertEqual(headphones.connectionMode, .soundQuality)
        XCTAssertNil(headphones.lastConnectionModeChangeID)
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
        XCTAssertNotNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[otherAddress])
    }

    func testRelaunchRespectsNewLocalChoiceAndCancelledExplicitRestoration() async throws {
        for explicitRestore in [false, true] {
            let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let (coordinator, headphones) = try preparedHeadphones()
            defer { finish(headphones) }
            defaults.set([headphones.address: UUID().uuidString], forKey: "ldac.pendingConnectionPreferences")
            let ldac = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })
            if explicitRestore { ldac.restorePendingConnectionPreference(forAddress: headphones.address) }
            else { headphones.setConnectionMode(.stableConnection) }
            let request = headphones.lastConnectionModeChangeID
            headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .negative)
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(headphones.connectionMode, .soundQuality)
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
            XCTAssertFalse(ldac.needsStopBeforeTermination)
            XCTAssertNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[headphones.address])
        }
    }

    func testKeepCurrentPreferenceClearsOnlyThatDeviceAndInvalidRecordsAreIgnored() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (coordinator, headphones) = try preparedHeadphones()
        defer { finish(headphones) }
        let otherAddress = "02:53:4F:4E:59:02"
        defaults.set([headphones.address: UUID().uuidString, otherAddress: UUID().uuidString,
                      "not-an-address": UUID().uuidString, "02:53:4F:4E:59:03": "not-a-request"],
                     forKey: "ldac.pendingConnectionPreferences")
        let ldac = LDACController(devices: coordinator, defaults: defaults, inspectDriver: { _ in .current })
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: "not-an-address"))
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: "02:53:4F:4E:59:03"))
        ldac.keepConnectionPreference(forAddress: headphones.address)
        XCTAssertFalse(ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address))
        XCTAssertTrue(ldac.hasPendingConnectionPreferenceRestoration(forAddress: otherAddress))
        XCTAssertNil(headphones.lastConnectionModeChangeID)
        XCTAssertEqual(headphones.connectionMode, .soundQuality)
        XCTAssertNil(defaults.dictionary(forKey: "ldac.pendingConnectionPreferences")?[headphones.address])
    }

    private func preparedHeadphones() throws -> (SonyDeviceCoordinator, SonyHeadphonesController) {
        let address = "02:53:4F:4E:59:01"
        let coordinator = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: .wfXM5,
                                                simulatedTable2Functions: [0x31, 0x32, 0x42, 0x53, 0xF0])
            return controller
        }
        coordinator.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: "WF-1000XM5", model: .wfXM5))])
        let headphones = try XCTUnwrap(coordinator.controller(for: address))
        let firmware = Array("6.1.0".utf8)
        headphones.simulateProtocolMessage([0x05, 2, UInt8(firmware.count)] + firmware)
        return (coordinator, headphones)
    }

    private func preparedFinder() throws -> (SonyDeviceCoordinator, SonyHeadphonesController, EarbudFinderController, UUID) {
        let (coordinator, headphones) = try preparedHeadphones()
        headphones.setConnectionMode(.stableConnection)
        let request = try XCTUnwrap(headphones.lastConnectionModeChangeID)
        headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .negative)
        XCTAssertEqual(headphones.connectionMode, .soundQuality)
        XCTAssertTrue(headphones.beginEarbudFinder())
        return (coordinator, headphones, try XCTUnwrap(headphones.earbudFinder), request)
    }

    private func openUnwornEarbud(_ finder: EarbudFinderController, headphones: SonyHeadphonesController) async {
        finder.simulateConnectionOpened()
        for _ in 0..<200 {
            guard let frame = headphones.simulatedPendingFrame else { break }
            headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTAssertNil(headphones.simulatedPendingFrame)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        headphones.simulateProtocolMessage([0xF3, 0, 4], type: 0x0E)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(headphones.wearingStatus.leftWorn, false)
        XCTAssertEqual(finder.session?.phase, .starting)
    }

    private func finish(_ headphones: SonyHeadphonesController) {
        headphones.earbudFinder?.dismiss()
        headphones.earbudFinder?.simulateTransportFailure()
        headphones.simulateControlLoss()
    }
}

@MainActor
final class LDACRecoveryTests: XCTestCase {
    private let abort = LDACNativeSession.Completion(message: nil, canRetry: true, requiresAttention: false,
                                                     targetDisconnected: true, waitForReconnect: false)
    private let restored = LDACNativeSession.Completion(message: nil, canRetry: false, requiresAttention: true,
                                                        targetDisconnected: false, waitForReconnect: false)

    func testRecoverableAbortRestoresOrdinaryAudioBeforeTheSingleRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }

        ldac.simulateSessionFinished(abort)
        XCTAssertEqual(ldac.simulatedLaunches?.map { $0.restoringOnly }, [true],
                       "A recoverable abort left the headphones disconnected instead of restoring ordinary audio")
        XCTAssertEqual(ldac.simulatedRecoveryAttempt, 1)
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry, "The retry was scheduled before ordinary audio returned")

        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(ldac.state, .waitingForDevice)
        XCTAssertTrue(ldac.isAwaitingAutomaticRetry)
        XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
        XCTAssertFalse(ldac.isSessionRunning)

        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry, "The retry delay did not end")
        XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
    }

    func testAbortOfTheRetryKeepsOrdinaryAudioAndTellsTheUser() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        ldac.simulateSessionFinished(abort)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        ldac.simulateRecoverySession(headphones)

        ldac.simulateSessionFinished(abort)
        XCTAssertEqual(ldac.simulatedLaunches?.map { $0.restoringOnly }, [true, true],
                       "The second abort did not restore ordinary audio")
        XCTAssertNil(ldac.simulatedRequestedAddress, "A second abort retried LDAC again")
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }

        guard case let .failed(message) = ldac.state else { return XCTFail("No notice after the retry failed: \(ldac.state)") }
        XCTAssertTrue(message.contains("ordinary Bluetooth audio"), message)
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry)
        XCTAssertFalse(ldac.isSessionRunning)
    }

    func testAbortWithoutDisconnectingReleasesTheOutputWithoutTheRestoreHelper() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }

        ldac.simulateSessionFinished(.init(message: nil, canRetry: true, requiresAttention: false,
                                           targetDisconnected: false, waitForReconnect: false))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(ldac.simulatedLaunches?.count, 0, "Ordinary audio was still connected, yet the restore helper ran")
        XCTAssertEqual(ldac.state, .waitingForDevice)
        XCTAssertTrue(ldac.isAwaitingAutomaticRetry)
    }

    func testShortActivePeriodDoesNotRenewTheRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        let start = Date(timeIntervalSince1970: 1_000)
        ldac.simulateSessionFinished(abort, at: start)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        ldac.simulateRecoverySession(headphones)

        ldac.simulateSessionFinished(abort, stableSince: start, at: start.addingTimeInterval(29.9))
        XCTAssertNil(ldac.simulatedRequestedAddress)
    }

    func testThirtySecondsOfStablePlaybackRenewsTheRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        let start = Date(timeIntervalSince1970: 1_000)
        ldac.simulateSessionFinished(abort, at: start)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        ldac.simulateRecoverySession(headphones)

        ldac.simulateSessionFinished(abort, stableSince: start, at: start.addingTimeInterval(30))
        XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
        XCTAssertEqual(ldac.simulatedRecoveryAttempt, 1)
    }

    func testExplicitStopCancelsThePendingRetry() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        ldac.simulateSessionFinished(abort)
        ldac.simulateSessionFinished(restored)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(ldac.isAwaitingAutomaticRetry)

        ldac.stop()

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertFalse(ldac.isAwaitingAutomaticRetry)
    }

    func testPhoneSourceSuspensionRestoresOrdinaryAudioWhileSleepDoesNot() async throws {
        for restoreAudio in [true, false] {
            let (ldac, headphones) = try preparedRecovery()
            defer { headphones.simulateControlLoss() }

            if restoreAudio { ldac.suspend(restoreAudio: true, reason: "another headphone music source is active") }
            else { ldac.suspend() }
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(ldac.simulatedRestoresAudioOnStop, restoreAudio)
            XCTAssertEqual(ldac.state, .waitingForDevice)
            XCTAssertEqual(ldac.simulatedRequestedAddress, headphones.address)
            XCTAssertFalse(ldac.isSessionRunning)
        }
    }

    func testExplicitStopCancelsRememberedRecoveryIntent() async throws {
        let (ldac, headphones) = try preparedRecovery()
        defer { headphones.simulateControlLoss() }
        ldac.suspend(restoreAudio: true, reason: "another headphone music source is active")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(ldac.state, .waitingForDevice)

        ldac.stop()

        XCTAssertEqual(ldac.state, .off)
        XCTAssertNil(ldac.targetAddress)
        XCTAssertNil(ldac.simulatedRequestedAddress)
        XCTAssertFalse(ldac.isSessionRunning)
    }

    private func preparedRecovery(isClassicConnected: ((String) -> Bool)? = nil) throws -> (LDACController, SonyHeadphonesController) {
        let address = "02:53:4F:4E:59:01"
        let coordinator = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: .wfXM5)
            return controller
        }
        coordinator.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: "WF-1000XM5", model: .wfXM5))])
        let headphones = try XCTUnwrap(coordinator.controller(for: address))
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current },
                                  isClassicConnected: isClassicConnected ?? { _ in headphones.isDeviceConnected })
        ldac.simulateHelpers()
        ldac.simulateRecoverySession(headphones)
        return (ldac, headphones)
    }
}
#endif
