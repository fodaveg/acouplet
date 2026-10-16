import pathlib
import re
import subprocess
import tempfile


source = (pathlib.Path(__file__).resolve().parents[2] / "Sources/LDACController.swift").read_text()


def method(name):
    match = re.search(r"^    (?:private )?(?:func|var) " + name + r"\b", source, re.MULTILINE)
    end = re.search(r"^    (?:(?:private )?(?:func|var|struct) |#(?:if|endif)\b)", source[match.end():], re.MULTILINE)
    return source[match.start():match.end() + end.start()]


fixture = r'''
import Foundation
import Combine

enum LDACState: Equatable { case off, requested, waitingForDevice, connecting, stopping, failed(String) }
enum LDACSupport { case supported, unsupported, unknown; func allowsStart(requested: Bool) -> Bool { requested && self != .unsupported } }
enum LDACAudioCaptureAccess { case checking, unchecked }
struct LDACConfiguration: Equatable { var value = 0 }
enum SonyBLEIdentity {
    static func normalizedAddress(_ value: String) -> String? { value }
}
struct IOBluetoothHostController {
    static func `default`() -> Self? { Self() }
    func addressAsString() -> String { "02:00:00:00:00:02" }
}
struct Route { var uid: String? }
@MainActor
final class MacAudioRouteObserver {
    var route: Route? = Route(uid: "fixture-headphones")
}

enum Model { case unknown, wfXM3, whCH720N, wfXM5, whXM5 }
enum SonyConnectionMode { case soundQuality, stableConnection, lowLatency }
struct ConnectionTransition {
    enum Phase { case awaitingResponse, awaitingUser, recovering, confirmed, cancelled, failed, pairingRequired }
    var phase: Phase
    var isFinished: Bool { [.confirmed, .cancelled, .failed].contains(phase) }
    var awaitingUser: Bool { phase == .awaitingUser }
}
struct Playback {
    var isSupported = true
    var hasReceivedCapabilities = false
    var musicVolumeRange: ClosedRange<Int>?
}
struct EarbudFinder {
    var isBusy: Bool
    var mayBeRinging: Bool
}
@MainActor
final class Device: ObservableObject {
    var deviceModel: Model
    @Published var isReady: Bool
    var notificationSession: UInt64 = 1
    @Published var isDeviceConnected = true
    var localSource = true
    var playback: Playback
    var earbudFinder: EarbudFinder?
    var supportsConnectionMode = true
    var ldacRequiresMultipointOff = false
    let address = "02:00:00:00:00:01"
    @Published var connectionMode: SonyConnectionMode? = .stableConnection
    @Published var connectionTransition: ConnectionTransition?
    var lastConnectionModeChangeID: UUID?
    var connectionModeError: String?
    var requests: [SonyConnectionMode] = []
    var retries = 0
    var refreshes = 0
    init(_ model: Model = .wfXM5, ready: Bool = true, playback: Bool = true) {
        deviceModel = model
        isReady = ready
        self.playback = Playback(isSupported: playback)
    }
    func setConnectionMode(_ mode: SonyConnectionMode) {
        guard mode != connectionMode, connectionTransition?.isFinished != false else { return }
        requests.append(mode)
        lastConnectionModeChangeID = UUID()
        connectionTransition = ConnectionTransition(phase: .awaitingResponse)
    }
    func confirm(_ mode: SonyConnectionMode) {
        connectionMode = mode
        connectionTransition = ConnectionTransition(phase: .confirmed)
    }
    func retryConnectionModeChange(expectedRequestID: UUID) -> Bool {
        guard lastConnectionModeChangeID == expectedRequestID, connectionTransition?.phase == .failed, retries == 0 else { return false }
        retries += 1
        connectionTransition = ConnectionTransition(phase: .recovering)
        return true
    }
    func refresh() { refreshes += 1 }
    func hasCurrentMusicSourceContext(for address: String?) -> Bool { localSource }
}
typealias SonyHeadphonesController = Device

@MainActor
final class Devices: ObservableObject {
    @Published var controllers = ["02:00:00:00:00:01": Device(), "02:00:00:00:00:02": Device(), "02:00:00:00:00:03": Device()]
    @Published var isSystemSleeping = false
    var selectedAddress: String? = "02:00:00:00:00:01"
    func controller(for address: String) -> Device? { controllers[address] }
}

@MainActor
enum LDACDriverInstaller {
    enum State: Equatable { case missing, outdated, restartRequired, current, unavailable(String) }
    static var state = State.current
    static var inspections = 0
    static var installations = 0
    static var error: Error?
    static func inspect(bundle: Bundle) -> State { inspections += 1; return state }
    static func invalidateCache() {}
    static func openInstaller(bundle: Bundle) async throws {
        installations += 1
        if let error { throw error }
    }
}

@MainActor
final class Output {
    var restores = 0
    var continuation: CheckedContinuation<String?, Never>?
    var disconnectedRestorations: [Bool] = []
    func silence() {}
    func restoreAndRelease(targetDisconnected: Bool = false) async -> String? {
        restores += 1
        disconnectedRestorations.append(targetDisconnected)
        return await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
final class Session {
    var stops: [Bool] = []
    func stop(restoreAudio: Bool) { stops.append(restoreAudio) }
}

@MainActor
final class Controller: ObservableObject {
    struct Helpers { var isAvailable = true }
    var helpers = Helpers()
    var driverState = LDACDriverInstaller.State.current
    var driverInstallationError: String?
    var isOpeningDriverInstaller = false
    let bundle = Bundle.main
    let inspectDriver: ((Bundle) -> LDACDriverInstaller.State)? = { LDACDriverInstaller.inspect(bundle: $0) }
    var isClassicConnected: (String) -> Bool = { _ in true }
    var devices: Devices? = Devices()
    var requestedConfiguration = LDACConfiguration()
    var audioRoute: MacAudioRouteObserver? = MacAudioRouteObserver()
    var resumeOutputUID: String? = "fixture-headphones"
    var suspensionRequested = false
    var pendingConnectionModes: [String: UUID] = [:]
    var deferredConnectionModes: [String: UUID] = [:]
    var preferenceRestoreTasks: [String: Task<Void, Never>] = [:]
    var sessionID = UUID()
    var state = LDACState.connecting
    var targetAddress: String? = "02:00:00:00:00:01"
    var requestedAddress: String? = "02:00:00:00:00:01"
    var isSessionRunning = true
    var isRecovering = true
    var recoveryAttempt = 0
    var retryAfterRestoration = false
    var isAwaitingAutomaticRetry = false
    var recoveryTaskID: UUID?
    var automaticRetryDelay: Duration = .milliseconds(1)
    var bindingHeldSince: Date?
    var bindingHoldTask: Task<Void, Never>?
    var multipointConflictAddress: String?
    var multipointConflictConfiguration: LDACConfiguration?
    var multipointShutdownAddress: String?
    var restoreAudioOnStop = true
    var nativeOutput: Output?
    var session: Session?
    var startTask: Task<Void, Never>?
    var cleanupTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var readinessTask: Task<Void, Never>?
    var volumeTask: Task<Void, Never>?
    var volumeTaskID: UUID?
    var controlObservation: Int?
    var outputID: UUID?
    var headphones: Device?
    var connectionModeRestoreID: UUID?
    var connectionModeConfirmed = false
    var transportFormat: Int?
    var controlSession: UInt64?
    var sourceAddress: String?
    var volumeRange: ClosedRange<Int>?
    var pendingVolume: Int?
    var initialReadbackID: UUID?
    var stableSince: Date?
    var requestedOutputGain = 0.0
    var usable = false
    var volumeError: String?
    var audioCaptureAccess = LDACAudioCaptureAccess.checking
    var stopCompletions: [@MainActor () -> Void] = []
    var starts: [String] = []
    var restores: [String] = []
    var musicControlStatus: String { "simulated" }

    init(output: Output? = nil) {
        nativeOutput = output
        if output == nil {
            isSessionRunning = false
            isRecovering = false
            state = .off
            targetAddress = nil
            requestedAddress = nil
        }
    }
    func record(_ event: String, reason: String) {}
    func recordRecovery(_ event: String, reason: String) {}
    func setOutputGain(_ gain: Double) { requestedOutputGain = gain }
    func sessionFinished(_ message: String? = nil, targetDisconnected: Bool = false) {
        finish(message, targetDisconnected: targetDisconnected)
    }
    func availabilityChanged() { resumeIfReady() }
    func launch(_ address: String, restoringOnly: Bool) { restores.append(address) }
    func start(_ address: String) {
        starts.append(address)
        targetAddress = address
        state = .requested
        isSessionRunning = true
    }
    func prepareQuality(_ address: String) async throws {
        headphones = devices!.controller(for: address)!
        try await prepareConnectionMode(headphones!, address: address, identifier: sessionID)
    }
    func restoreQuality() async -> String? { await restoreConnectionMode() }
    func awaitChange(_ address: String, timeout: Duration) async throws -> Bool {
        try await waitForConnectionChange(headphones!, address: address,
            request: headphones!.lastConnectionModeChangeID!, restoring: true, timeout: timeout)
    }
    private struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
    func support(forAddress address: String) -> LDACSupport { .unknown }
__METHODS__
}

@main
enum LDACControllerCleanupCheck {
    @MainActor
    static func waitUntil(line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Controller operation did not complete at line \(line)")
    }

    @MainActor
    static func disconnected(preference: UUID? = nil, restoreError: String? = nil) async -> Controller {
        let output = Output()
        let controller = Controller(output: output)
        let headphones = controller.devices!.controller(for: controller.targetAddress!)!
        controller.headphones = headphones
        headphones.isDeviceConnected = false
        headphones.connectionMode = .soundQuality
        headphones.lastConnectionModeChangeID = preference
        controller.connectionModeRestoreID = preference
        controller.connectionModeConfirmed = preference != nil
        controller.suspensionRequested = true
        controller.sessionFinished(targetDisconnected: true)
        await waitUntil { output.continuation != nil }
        precondition(output.disconnectedRestorations == [true])
        output.continuation?.resume(returning: restoreError)
        await waitUntil { controller.cleanupTask == nil }
        return controller
    }

    @MainActor
    static func main() async {
        let address = "02:00:00:00:00:01"
        for state in [LDACDriverInstaller.State.missing, .current, .restartRequired, .unavailable("Untrusted driver")] {
            let update = Controller()
            update.devices = nil
            LDACDriverInstaller.state = state
            LDACDriverInstaller.inspections = 0
            LDACDriverInstaller.installations = 0
            update.updateDriver()
            precondition(LDACDriverInstaller.inspections == 1 && LDACDriverInstaller.installations == 0)
            precondition(!update.isOpeningDriverInstaller, "Update LDAC Driver opened Installer for \(state)")
        }
        LDACDriverInstaller.state = .outdated
        for running in [false, true] {
            let update = Controller()
            update.isSessionRunning = running
            update.isOpeningDriverInstaller = !running
            LDACDriverInstaller.inspections = 0
            LDACDriverInstaller.installations = 0
            update.updateDriver()
            precondition(LDACDriverInstaller.inspections == 0 && LDACDriverInstaller.installations == 0,
                         "Update LDAC Driver opened Installer while LDAC streamed or Installer was opening")
        }
        let button = Controller()
        button.devices = nil
        LDACDriverInstaller.inspections = 0
        LDACDriverInstaller.installations = 0
        button.updateDriver()
        precondition(button.isOpeningDriverInstaller, "Update LDAC Driver required headphones")
        button.updateDriver()
        await waitUntil { !button.isOpeningDriverInstaller }
        precondition(LDACDriverInstaller.inspections == 1 && LDACDriverInstaller.installations == 1,
                     "A second press while Installer was opening opened it again")
        button.updateDriver()
        await waitUntil { !button.isOpeningDriverInstaller }
        precondition(LDACDriverInstaller.installations == 2, "A later press of Update LDAC Driver was ignored (D13)")
        precondition(button.starts.isEmpty && button.targetAddress == nil && button.state == .off)

        let failedUpdate = Controller()
        LDACDriverInstaller.installations = 0
        LDACDriverInstaller.error = NSError(domain: "DriverFixture", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "Installer could not open"])
        failedUpdate.updateDriver()
        await waitUntil { !failedUpdate.isOpeningDriverInstaller }
        precondition(failedUpdate.driverInstallationError == "Installer could not open")
        precondition(LDACDriverInstaller.installations == 1, "A failed update retried itself")
        LDACDriverInstaller.error = nil
        failedUpdate.installDriver(forAddress: address)
        precondition(failedUpdate.isOpeningDriverInstaller && failedUpdate.driverInstallationError == nil)
        await waitUntil { !failedUpdate.isOpeningDriverInstaller }
        precondition(LDACDriverInstaller.installations == 2, "A failed update prevented a manual retry")

        let volumeUnavailable = Device()
        volumeUnavailable.playback.hasReceivedCapabilities = true
        let finding = Device()
        finding.earbudFinder = EarbudFinder(isBusy: true, mayBeRinging: false)
        let unconfirmedStop = Device()
        unconfirmedStop.earbudFinder = EarbudFinder(isBusy: false, mayBeRinging: true)
        let refused: [(String, Device?)] = [
            ("missing", nil), ("unknown", Device(.unknown)),
            ("WF-1000XM3", Device(.wfXM3)), ("WH-CH720N", Device(.whCH720N)),
            ("disconnected", Device(ready: false)), ("missing playback", Device(playback: false)),
            ("reported no volume control", volumeUnavailable),
            ("active earbud finding", finding), ("unconfirmed finder Stop", unconfirmedStop),
        ]
        for (name, device) in refused {
            let admission = Controller()
            admission.devices?.controllers[address] = device
            precondition(admission.deviceUnavailableReason(forAddress: address) != nil, "Eligibility admitted \(name)")
            precondition(!admission.canEnable(forAddress: address), "Enable availability admitted \(name)")
            LDACDriverInstaller.inspections = 0
            LDACDriverInstaller.installations = 0
            LDACDriverInstaller.state = .missing
            admission.setEnabled(true, forAddress: address, configuration: LDACConfiguration(value: 1))
            precondition(LDACDriverInstaller.inspections == 0, "Enable inspected driver for \(name)")
            precondition(admission.starts.isEmpty && admission.requestedAddress == nil && admission.targetAddress == nil)
            precondition(admission.requestedConfiguration == LDACConfiguration() && admission.state == .off)
            admission.installDriver(forAddress: address)
            precondition(LDACDriverInstaller.inspections == 0, "Installer inspected driver for \(name)")
            precondition(!admission.isOpeningDriverInstaller && LDACDriverInstaller.installations == 0)
        }
        let missingCoordinator = Controller()
        missingCoordinator.devices = nil
        precondition(missingCoordinator.deviceUnavailableReason(forAddress: address) != nil)
        let idleFinder = Controller()
        idleFinder.devices?.controllers[address]?.earbudFinder = EarbudFinder(isBusy: false, mayBeRinging: false)
        precondition(idleFinder.deviceUnavailableReason(forAddress: address) == nil && idleFinder.canEnable(forAddress: address),
                     "An idle finder blocked LDAC admission")
        for model in [Model.wfXM5, .whXM5] {
            for state in [LDACDriverInstaller.State.current, .missing, .outdated] {
                let admission = Controller()
                admission.devices?.controllers[address] = Device(model)
                admission.devices?.controllers[address]?.playback.hasReceivedCapabilities = true
                admission.devices?.controllers[address]?.playback.musicVolumeRange = model == .wfXM5 ? 0...30 : 0...0
                LDACDriverInstaller.state = state
                LDACDriverInstaller.inspections = 0
                LDACDriverInstaller.installations = 0
                precondition(admission.deviceUnavailableReason(forAddress: address) == nil && admission.canEnable(forAddress: address))
                admission.setEnabled(true, forAddress: address)
                if state == .current {
                    precondition(admission.starts == [address] && admission.isSessionRunning)
                    precondition(LDACDriverInstaller.inspections == 1 && LDACDriverInstaller.installations == 0)
                } else {
                    precondition(admission.starts.isEmpty && admission.isOpeningDriverInstaller)
                    await waitUntil { !admission.isOpeningDriverInstaller }
                    precondition(LDACDriverInstaller.inspections == 2 && LDACDriverInstaller.installations == 1)
                }
            }
        }
        let active = Controller()
        active.isSessionRunning = true
        active.targetAddress = address
        active.requestedAddress = address
        active.state = .connecting
        let activeSession = Session()
        active.session = activeSession
        let next = "02:00:00:00:00:02"
        active.devices?.controllers[next]?.isReady = false
        active.setEnabled(true, forAddress: next)
        precondition(active.requestedAddress == address && activeSession.stops.isEmpty)
        active.devices?.controllers[next]?.isReady = true
        active.setEnabled(true, forAddress: next)
        precondition(active.requestedAddress == next && activeSession.stops == [true])
        active.devices?.controllers.removeAll()
        active.setEnabled(false, forAddress: address)
        precondition(active.requestedAddress == nil && activeSession.stops == [true, true], "Control loss prevented disable")

        let output = Output()
        let controller = Controller(output: output)
        controller.sessionFinished()
        await waitUntil { output.continuation != nil }
        var completions = 0
        controller.stop(reason: "app is terminating") { completions += 1 }
        controller.stop(restoreAudio: false, reason: "Mac is going to sleep") { completions += 1 }
        controller.stop(reason: "repeated stop")
        precondition(controller.restores.isEmpty, "Repeated stop launched another restoration session")
        precondition(!controller.restoreAudioOnStop, "A later stop weakened the sleep request")
        precondition(controller.isSessionRunning && completions == 0 && output.restores == 1)
        output.continuation?.resume(returning: nil)
        await waitUntil { controller.cleanupTask == nil }
        precondition(!controller.isSessionRunning && controller.state == .off && completions == 2)
        precondition(controller.starts.isEmpty && controller.stopCompletions.isEmpty)

        let pendingOutput = Output()
        let pending = Controller(output: pendingOutput)
        pending.sessionFinished()
        await waitUntil { pendingOutput.continuation != nil }
        pending.setEnabled(true, forAddress: "02:00:00:00:00:02")
        pending.setEnabled(true, forAddress: "02:00:00:00:00:03")
        precondition(pending.restores.isEmpty && pending.starts.isEmpty)
        precondition(pending.requestedAddress == "02:00:00:00:00:03")
        pendingOutput.continuation?.resume(returning: nil)
        await waitUntil { pending.cleanupTask == nil }
        precondition(pending.starts == ["02:00:00:00:00:03"] && pending.isSessionRunning)

        let blockedOutput = Output()
        let blocked = Controller(output: blockedOutput)
        blocked.sessionFinished()
        await waitUntil { blockedOutput.continuation != nil }
        blocked.setEnabled(true, forAddress: next)
        precondition(blocked.starts.isEmpty && blocked.requestedAddress == next)
        blockedOutput.continuation?.resume(returning: "The previous Mac audio output did not return.")
        await waitUntil { blocked.cleanupTask == nil }
        precondition(blocked.starts.isEmpty && blocked.requestedAddress == nil)
        if case .failed = blocked.state {} else { preconditionFailure("Unresolved restoration admitted next target") }

        let cancelledOutput = Output()
        let cancelled = Controller(output: cancelledOutput)
        cancelled.sessionFinished()
        await waitUntil { cancelledOutput.continuation != nil }
        cancelled.setEnabled(true, forAddress: "02:00:00:00:00:02")
        cancelled.stop(reason: "app is terminating") { completions += 1 }
        precondition(cancelled.requestedAddress == nil && cancelled.restores.isEmpty && completions == 2)
        cancelledOutput.continuation?.resume(returning: nil)
        await waitUntil { cancelled.cleanupTask == nil }
        precondition(cancelled.starts.isEmpty && !cancelled.isSessionRunning && completions == 3)
        for supportsPreference in [false, true] {
            let unchanged = Controller(output: Output())
            let unchangedHeadphones = unchanged.devices!.controller(for: address)!
            unchangedHeadphones.supportsConnectionMode = supportsPreference
            unchangedHeadphones.connectionMode = supportsPreference ? .soundQuality : nil
            try! await unchanged.prepareQuality(address)
            precondition(unchangedHeadphones.requests.isEmpty && unchanged.connectionModeRestoreID == nil)
        }

        let qualityOutput = Output()
        let quality = Controller(output: qualityOutput)
        let headphones = quality.devices!.controller(for: address)!
        let preparation = Task { try await quality.prepareQuality(address) }
        await waitUntil { headphones.requests == [.soundQuality] }
        precondition(quality.connectionModeRestoreID == headphones.lastConnectionModeChangeID)
        headphones.connectionTransition?.phase = .awaitingUser
        for _ in 0..<10 { await Task.yield() }
        precondition(!quality.connectionModeConfirmed)
        headphones.isReady = false
        headphones.confirm(.soundQuality)
        for _ in 0..<10 { await Task.yield() }
        precondition(!quality.connectionModeConfirmed)
        headphones.isReady = true
        try! await preparation.value
        quality.isRecovering = false
        quality.stop()
        await waitUntil { qualityOutput.continuation != nil }
        precondition(headphones.requests == [.soundQuality])
        qualityOutput.continuation?.resume(returning: nil)
        await waitUntil { headphones.requests == [.soundQuality, .stableConnection] }
        precondition(quality.isSessionRunning)
        headphones.confirm(.stableConnection)
        await waitUntil { !quality.isSessionRunning }
        precondition(quality.state == .off)

        let cancelledQualityOutput = Output()
        let cancelledQuality = Controller(output: cancelledQualityOutput)
        let pendingHeadphones = cancelledQuality.devices!.controller(for: address)!
        cancelledQuality.startTask = Task {
            do { try await cancelledQuality.prepareQuality(address) }
            catch {
                precondition(error is CancellationError)
                cancelledQuality.startTask = nil
                cancelledQuality.sessionFinished()
            }
        }
        await waitUntil { pendingHeadphones.requests == [.soundQuality] }
        cancelledQuality.stop()
        await waitUntil { cancelledQualityOutput.continuation != nil }
        cancelledQualityOutput.continuation?.resume(returning: nil)
        for _ in 0..<10 { await Task.yield() }
        precondition(cancelledQuality.isSessionRunning && pendingHeadphones.requests == [.soundQuality])
        pendingHeadphones.confirm(.soundQuality)
        await waitUntil { pendingHeadphones.requests == [.soundQuality, .stableConnection] }
        pendingHeadphones.confirm(.stableConnection)
        await waitUntil { !cancelledQuality.isSessionRunning }
        precondition(cancelledQuality.starts.isEmpty && cancelledQuality.state == .off)

        let superseded = Controller(output: Output())
        let supersededHeadphones = superseded.devices!.controller(for: address)!
        let supersededPreparation = Task { try await superseded.prepareQuality(address) }
        await waitUntil { supersededHeadphones.requests == [.soundQuality] }
        supersededHeadphones.confirm(.soundQuality)
        try! await supersededPreparation.value
        supersededHeadphones.setConnectionMode(.lowLatency)
        let supersededResult = await superseded.restoreQuality()
        precondition(supersededResult == nil)
        precondition(supersededHeadphones.requests == [.soundQuality, .lowLatency])

        let failedQuality = Controller(output: Output())
        let failedHeadphones = failedQuality.devices!.controller(for: address)!
        failedQuality.headphones = failedHeadphones
        failedHeadphones.setConnectionMode(.soundQuality)
        failedQuality.connectionModeRestoreID = failedHeadphones.lastConnectionModeChangeID
        failedHeadphones.connectionTransition?.phase = .failed
        let failedRestoration = Task { await failedQuality.restoreQuality() }
        await waitUntil { failedHeadphones.retries == 1 }
        precondition(failedHeadphones.requests == [.soundQuality])
        failedHeadphones.confirm(.soundQuality)
        await waitUntil { failedHeadphones.requests == [.soundQuality, .stableConnection] }
        failedHeadphones.confirm(.stableConnection)
        let failedRestorationResult = await failedRestoration.value
        precondition(failedRestorationResult == nil)

        let sleeping = Controller(output: Output())
        let sleepingHeadphones = sleeping.devices!.controller(for: address)!
        sleeping.headphones = sleepingHeadphones
        sleepingHeadphones.setConnectionMode(.soundQuality)
        sleepingHeadphones.confirm(.soundQuality)
        sleeping.connectionModeRestoreID = sleepingHeadphones.lastConnectionModeChangeID
        sleepingHeadphones.isReady = false
        sleepingHeadphones.connectionTransition = nil
        sleepingHeadphones.connectionMode = nil
        sleeping.devices!.isSystemSleeping = true
        let wakingRestoration = Task { await sleeping.restoreQuality() }
        for _ in 0..<10 { await Task.yield() }
        precondition(sleepingHeadphones.refreshes == 0)
        sleeping.devices!.isSystemSleeping = false
        await waitUntil { sleepingHeadphones.refreshes == 1 }
        sleepingHeadphones.isReady = true
        for _ in 0..<10 { await Task.yield() }
        precondition(sleepingHeadphones.requests == [.soundQuality])
        precondition(sleeping.connectionModeRestoreID != nil)
        sleepingHeadphones.connectionMode = .soundQuality
        await waitUntil { sleepingHeadphones.requests == [.soundQuality, .stableConnection] }
        sleepingHeadphones.confirm(.stableConnection)
        let wakingRestorationResult = await wakingRestoration.value
        precondition(wakingRestorationResult == nil)

        let timedOut = Controller(output: Output())
        let unreachable = timedOut.devices!.controller(for: address)!
        timedOut.headphones = unreachable
        unreachable.setConnectionMode(.soundQuality)
        unreachable.connectionTransition?.phase = .awaitingUser
        var timedOutFinished = false
        let waiting = Task {
            defer { timedOutFinished = true }
            do {
                _ = try await timedOut.awaitChange(address, timeout: .milliseconds(20))
                preconditionFailure("Unconfirmed preference was accepted")
            } catch { precondition(!(error is CancellationError)) }
        }
        try! await Task.sleep(for: .milliseconds(40))
        precondition(!timedOutFinished)
        timedOut.stop { }
        await waiting.value
        precondition(timedOutFinished)

        LDACDriverInstaller.state = .current
        let parked = await disconnected()
        precondition(parked.state == .waitingForDevice && parked.requestedAddress == address)
        precondition(!parked.isSessionRunning && parked.nativeOutput == nil && parked.recoveryTask == nil)
        for _ in 0..<100 { parked.availabilityChanged() }
        precondition(parked.starts.isEmpty && parked.state == .waitingForDevice,
                     "Disconnected availability notifications restarted LDAC")
        parked.devices!.controller(for: address)!.isDeviceConnected = true
        parked.availabilityChanged()
        parked.availabilityChanged()
        precondition(parked.starts == [address], "Ready reconnect did not resume exactly once")

        let retryOutput = Output()
        let retry = Controller(output: retryOutput)
        retry.suspensionRequested = true
        retry.retryAfterRestoration = true
        retry.recoveryAttempt = 1
        retry.sessionFinished()
        await waitUntil { retryOutput.continuation != nil }
        retryOutput.continuation?.resume(returning: nil)
        await waitUntil { retry.cleanupTask == nil }
        precondition(retry.state == .waitingForDevice && retry.isAwaitingAutomaticRetry && retry.recoveryTask != nil)
        retry.availabilityChanged()
        precondition(retry.starts.isEmpty, "The fallback resumed LDAC before its retry delay")
        await waitUntil { retry.recoveryTask == nil }
        try? await Task.sleep(for: .milliseconds(20))
        await waitUntil { retry.starts == [address] }
        precondition(retry.recoveryAttempt == 1, "The automatic retry renewed its own budget")
        let explicit = Controller()
        explicit.recoveryAttempt = 1
        explicit.setEnabled(true, forAddress: address)
        precondition(explicit.starts == [address] && explicit.recoveryAttempt == 0, "An explicit request did not renew the retry")

        let blockers: [(String, (Controller) -> Void)] = [
            ("sleep", { $0.devices!.isSystemSleeping = true }),
            ("controls", { $0.devices!.controller(for: address)!.isReady = false }),
            ("connection", { $0.devices!.controller(for: address)!.isDeviceConnected = false }),
            ("other or unknown source", { $0.devices!.controller(for: address)!.localSource = false }),
            ("other selected headphones", { $0.devices!.selectedAddress = next }),
            ("user-selected output", { $0.audioRoute!.route = Route(uid: "fixture-speakers") }),
            ("unknown original output", { $0.resumeOutputUID = nil }),
            ("missing output", { $0.audioRoute!.route = nil }),
            ("missing controller", { $0.devices!.controllers[address] = nil }),
            ("missing helpers", { $0.helpers.isAvailable = false }),
        ]
        for (name, block) in blockers {
            let waiting = await disconnected()
            waiting.devices!.controller(for: address)!.isDeviceConnected = true
            block(waiting)
            for _ in 0..<5 { waiting.availabilityChanged() }
            precondition(waiting.starts.isEmpty && waiting.state == .waitingForDevice,
                         "Automatic LDAC resume bypassed \(name)")
            waiting.stop()
        }
        let outdated = await disconnected()
        outdated.devices!.controller(for: address)!.isDeviceConnected = true
        LDACDriverInstaller.state = .outdated
        outdated.availabilityChanged()
        precondition(outdated.starts.isEmpty && !outdated.isOpeningDriverInstaller)
        LDACDriverInstaller.state = .current
        outdated.availabilityChanged()
        precondition(outdated.starts == [address])

        let originalPreference = UUID()
        let disabled = await disconnected(preference: originalPreference)
        precondition(disabled.deferredConnectionModes[address] == originalPreference,
                     "Disconnect lost the original Stable Connection obligation")
        disabled.setEnabled(false, forAddress: address)
        for _ in 0..<5 { disabled.availabilityChanged() }
        precondition(disabled.state == .off && disabled.requestedAddress == nil && disabled.starts.isEmpty)
        let returning = disabled.devices!.controller(for: address)!
        precondition(returning.requests.isEmpty && disabled.preferenceRestoreTasks.isEmpty)
        returning.isDeviceConnected = true
        disabled.availabilityChanged()
        await waitUntil { returning.requests == [.stableConnection] }
        precondition(!disabled.canEnable(forAddress: address))
        disabled.setEnabled(true, forAddress: address)
        precondition(disabled.requestedAddress == nil && disabled.starts.isEmpty,
                     "Manual enable raced the outstanding Stable Connection restoration")
        returning.confirm(.stableConnection)
        await waitUntil { disabled.preferenceRestoreTasks.isEmpty }
        precondition(disabled.deferredConnectionModes.isEmpty && disabled.starts.isEmpty,
                     "Manual Off was undone by a reconnect")

        let interrupted = await disconnected(preference: UUID())
        interrupted.setEnabled(false, forAddress: address)
        let disappearing = interrupted.devices!.controller(for: address)!
        disappearing.isDeviceConnected = true
        interrupted.availabilityChanged()
        await waitUntil { disappearing.requests == [.stableConnection] }
        let restoration = disappearing.lastConnectionModeChangeID!
        disappearing.isReady = false
        disappearing.isDeviceConnected = false
        disappearing.retries = 1
        disappearing.connectionTransition?.phase = .failed
        await waitUntil { interrupted.preferenceRestoreTasks.isEmpty }
        precondition(interrupted.deferredConnectionModes[address] == restoration,
                     "A second disconnect dropped the in-flight Stable Connection restoration")
        for _ in 0..<100 { interrupted.availabilityChanged() }
        precondition(disappearing.requests == [.stableConnection] && interrupted.preferenceRestoreTasks.isEmpty)
        disappearing.retries = 0
        disappearing.confirm(.soundQuality)
        disappearing.isReady = true
        disappearing.isDeviceConnected = true
        interrupted.availabilityChanged()
        await waitUntil { disappearing.requests == [.stableConnection, .stableConnection] }
        disappearing.confirm(.stableConnection)
        await waitUntil { interrupted.preferenceRestoreTasks.isEmpty }
        precondition(interrupted.deferredConnectionModes.isEmpty && interrupted.starts.isEmpty)

        let sleepOutput = Output()
        let sleeper = Controller(output: sleepOutput)
        sleeper.devices!.isSystemSleeping = true
        sleeper.suspend()
        await waitUntil { sleepOutput.continuation != nil }
        precondition(sleeper.requestedAddress == address && !sleeper.restoreAudioOnStop)
        sleepOutput.continuation?.resume(returning: nil)
        await waitUntil { sleeper.cleanupTask == nil }
        precondition(sleeper.state == .waitingForDevice && sleeper.starts.isEmpty)
        sleeper.devices!.isSystemSleeping = false
        sleeper.availabilityChanged()
        precondition(sleeper.starts == [address], "Wake lost the LDAC request")

        let unsafe = await disconnected(restoreError: "Output lease could not be released.")
        precondition(unsafe.state == .failed("Output lease could not be released.") && unsafe.requestedAddress == nil)
        unsafe.devices!.controller(for: address)!.isDeviceConnected = true
        for _ in 0..<10 { unsafe.availabilityChanged() }
        precondition(unsafe.starts.isEmpty, "Unconfirmed cleanup automatically restarted LDAC")

        let errorOutput = Output()
        let duplicate = Controller(output: errorOutput)
        duplicate.volumeError = "Transport failed."
        duplicate.sessionFinished("Transport failed. Cleanup failed.")
        await waitUntil { errorOutput.continuation != nil }
        errorOutput.continuation?.resume(returning: "Cleanup failed.")
        await waitUntil { duplicate.cleanupTask == nil }
        precondition(duplicate.state == .failed("Transport failed. Cleanup failed."),
                     "Nested cleanup errors repeated their primary failure")

        print("PASS actual LDAC admission, connection preference and cleanup methods: confirmations, readiness, output-before-preference restoration, cancelled startup, user supersession, bounded retry without setter replay, sleep/wake, quit deadline and existing lifecycle checks; fake peers only")
        print("PASS actual disconnect policy: idle waiting, one resume, source/output/selection/driver gates, deferred Stable Connection, manual Off, sleep/wake, cleanup failure and nested-error deduplication")
        print("PASS actual driver update policy (D13): the panel button opens Installer only for an outdated driver, without headphones, never while busy, on every later press, with surfaced errors and manual retry")
        print("PASS actual finder admission: active finding and unconfirmed Stop block LDAC and manual installation; absent or idle finder allows admission")
    }
}
'''.replace("__METHODS__", "\n".join(method(name) for name in ["needsStopBeforeTermination", "deviceUnavailableReason", "canEnable", "refreshDriverState", "updateDriver", "installDriver", "openDriverInstaller", "setEnabled", "stop", "suspend", "resumeIfReady", "recordRetryBlocked", "reconcileConnectionPreferences", "forgetConnectionPreference", "scheduleConnectionPreferenceRestoration", "stopSession", "prepareConnectionMode", "waitForConnectionChange", "restoreConnectionMode", "restoreConnectionPreference", "finish", "completeStop", "scheduleRecovery", "endRetryWait", "cancelAutomaticRetry"]))

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-controller-cleanup-") as directory:
    directory = pathlib.Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
