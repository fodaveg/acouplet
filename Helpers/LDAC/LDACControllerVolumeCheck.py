import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[2]
source = (root / "Sources/LDACController.swift").read_text()
output_source = (root / "Sources/LDACNativeOutput.swift").read_text()


def member(name):
    match = re.search(r"^    (?:private )?(?:func|var) " + name + r"\b", source, re.MULTILINE)
    end = re.search(r"^    (?:(?:private )?(?:func|var|struct) |#(?:if|endif)\b)", source[match.end():], re.MULTILINE)
    return re.sub(r"^    private ", "    ", source[match.start():match.end() + end.start()], flags=re.MULTILINE)


volume = output_source[output_source.index("struct LDACNativeVolume:"):output_source.index("\nstruct LDACRouteRecovery")]
fixture = r'''
import Foundation
import Combine

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Fixture assertion failed") {
    if !condition() {
        FileHandle.standardError.write(Data((message() + "\n").utf8))
        exit(1)
    }
}

enum Generation { case v1, v2 }
enum Model { case unknown, wfXM3, whCH720N, whXM4, wfXM5; var name: String { "fixture" } }
struct LDACFormat: Equatable { var value = 1 }
enum LDACState: Equatable { case off, requested, waitingForDevice, connecting, active(LDACFormat), stopping, failed(String) }
enum LDACAudioCaptureAccess { case unchecked, checking, ready, permissionRequired }
struct LDACConfiguration { var sampleRate = 48000 }
struct LDACPriorityControl {}
struct LDACPriorityCleanupError: Error {}
struct LDACOwnerTimeoutError: Error {}
enum SonyBLEIdentity { static func normalizedAddress(_ address: String) -> String? { address.uppercased() } }
struct IOBluetoothDevice {
    init?(addressString: String) {}
    func isClassicConnected() -> Bool { true }
}
struct IOBluetoothHostController {
    static func `default`() -> Self? { Self() }
    func addressAsString() -> String { "02:00:00:00:00:02" }
}
enum ReconnectBackoff { static func delay(forAttempt: Int) -> Double { 0 } }
enum SonyConnectionMode { case soundQuality, stableConnection, lowLatency }
struct ConnectionTransition {
    enum Phase { case awaitingResponse, awaitingUser, recovering, confirmed, cancelled, failed, pairingRequired }
    var phase: Phase
    var isFinished: Bool { [.confirmed, .cancelled, .failed].contains(phase) }
    var awaitingUser: Bool { phase == .awaitingUser }
}
struct Route { var uid: String? }
struct EarbudFinder {
    var isBusy: Bool
    var mayBeRinging: Bool
}
@MainActor
final class MacAudioRouteObserver {
    var route: Route? = Route(uid: "fixture-headphones")
}
@MainActor
enum LDACDriverInstaller {
    enum State { case current }
    static func inspect(bundle: Bundle) -> State { .current }
}

__VOLUME__

@MainActor
final class SonyHeadphonesController: ObservableObject {
    enum Setting { case playbackVolume }
    struct Playback {
        var generation = Generation.v1
        var isSupported = true
        var hasReceivedCapabilities = true
        var musicVolumeRange: ClosedRange<Int>? = 0...30
        var volume: Int? = 12
    }
    struct Source { var address: String }
    struct Multipoint { var selectedSource: Source?; var inventoryIsStale = false }
    struct VolumeWrite { let volume: Int; let isCurrent: (() -> Bool)? }
    var deviceModel = Model.whXM4
    var address = "02:00:00:00:00:01"
    var playback = Playback()
    var multipoint = Multipoint()
    var earbudFinder: EarbudFinder?
    var isReady = true
    var isDeviceConnected = true
    var ldacRequiresMultipointOff = false
    var pendingControlTransition: String?
    var isLeavingLDACConnectionMode = false
    var requestedSourceSwitchAddress: String?
    var supportsConnectionMode = true
    @Published var connectionMode: SonyConnectionMode? = .soundQuality
    @Published var connectionTransition: ConnectionTransition?
    var lastConnectionModeChangeID: UUID?
    var connectionModeError: String?
    var connectionRequests: [SonyConnectionMode] = []
    var notificationSession: UInt64 = 1
    var capabilityFresh = true
    var statusFresh = true
    var volumeFresh = true
    var localSource = true
    var musicVolumeReadbackID: UUID? = UUID()
    var musicStatusReadbackID: UUID? = UUID()
    var refreshes = 0
    var volumeRefreshes = 0
    var queuedWrite: VolumeWrite?
    var blocksPlaybackCommands = false
    var transmitted: [Int] = []
    var continuation: CheckedContinuation<Void, Error>?
    var hasCurrentMusicVolumeControl: Bool {
        isReady && capabilityFresh && statusFresh && volumeFresh && playback.volume != nil && pendingControlTransition == nil
    }
    var hasFreshMusicVolumeReadback: Bool { hasCurrentMusicVolumeControl && canControlMusicVolume }
    var canControlMusicVolume: Bool { hasCurrentMusicVolumeControl && !blocksPlaybackCommands && queuedWrite == nil }
    func hasCurrentMusicSourceContext(for address: String?) -> Bool { localSource }
    func setConnectionMode(_ mode: SonyConnectionMode) {
        guard mode != connectionMode, connectionTransition?.isFinished != false else { return }
        connectionRequests.append(mode)
        lastConnectionModeChangeID = UUID()
        connectionTransition = ConnectionTransition(phase: .awaitingResponse)
    }
    func retryConnectionModeChange(expectedRequestID: UUID) -> Bool { false }
    func confirmConnectionMode(_ mode: SonyConnectionMode) {
        connectionMode = mode
        connectionTransition = ConnectionTransition(phase: .confirmed)
    }
    func canPerformConfirmedSettingChange(_ setting: Setting) -> Bool { isReady && !blocksPlaybackCommands && queuedWrite == nil }
    func refresh() {
        refreshes += 1
        guard isReady else { return }
        musicVolumeReadbackID = UUID()
        musicStatusReadbackID = UUID()
    }
    func refreshMusicVolume() -> Bool {
        guard isReady else { return false }
        volumeRefreshes += 1
        statusFresh = false
        volumeFresh = false
        return true
    }
    func receiveStatus() { statusFresh = true; musicStatusReadbackID = UUID() }
    func receiveVolume(_ volume: Int = 12) { volumeFresh = true; playback.volume = volume; musicVolumeReadbackID = UUID() }
    func performConfirmedSettingChange(_ setting: Setting, change: () -> Void) async throws {
        try Task.checkCancellation()
        change()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in
                let waiter = self.continuation
                self.continuation = nil
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
    func setPlaybackVolume(_ volume: Int, isCurrent: (() -> Bool)? = nil) {
        precondition(queuedWrite == nil)
        queuedWrite = VolumeWrite(volume: volume, isCurrent: isCurrent)
    }
    func transmitVolume() {
        guard let write = queuedWrite else { return }
        if write.isCurrent?() == false {
            queuedWrite = nil
            let waiter = continuation
            continuation = nil
            waiter?.resume(throwing: CancellationError())
        } else { transmitted.append(write.volume) }
    }
    func confirmVolume() {
        guard let write = queuedWrite else { return }
        precondition(transmitted.last == write.volume)
        playback.volume = write.volume
        queuedWrite = nil
        let waiter = continuation
        continuation = nil
        waiter?.resume()
    }
}

@MainActor
final class SonyDeviceCoordinator: ObservableObject {
    var controllers: [String: SonyHeadphonesController] = [:]
    @Published var isSystemSleeping = false
    var selectedAddress: String? = "02:00:00:00:00:01"
    func controller(for address: String) -> SonyHeadphonesController? { controllers[address] }
}

@MainActor
final class LDACNativeOutput {
    nonisolated static let uid = "fixture-output"
    var controls = LDACNativeVolume(scalar: 0.8, muted: false)
    var ready = false
    var selected = false
    var preparations = 0
    var silences = 0
    var configurations = 0
    var recoveryPreparations = 0
    var restores: [Bool] = []
    var restoreError: String?
    init(id: UUID, address: String, changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) {}
    func claim(model: String, targetAddress: String, sampleRate: Int) async throws {}
    func priorityControl() async throws {}
    var configureTimeouts = 0
    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) async throws {
        configurations += 1
        if configureTimeouts > 0 {
            configureTimeouts -= 1
            throw LDACOwnerTimeoutError()
        }
        if !preservingUserChange { _ = controls.update(volume: volume, range: range) }
    }
    func validateForRecovery() async throws {}
    func prepareForReconnect() async throws { recoveryPreparations += 1 }
    func selectForHandoff() async throws { selected = true }
    func finishPreparation() async throws { ready = true; preparations += 1 }
    func silence() { ready = false; silences += 1 }
    func restoreAndRelease(targetDisconnected: Bool = false) async -> String? { restores.append(targetDisconnected); ready = false; selected = false; return restoreError }
}

typealias LDACOwnerOutput = LDACNativeOutput
typealias LDACOwnerSession = LDACNativeSession

@MainActor
final class LDACNativeSession {
    struct Helpers { var isAvailable = true }
    struct Completion { var message: String?; var canRetry = false; var requiresAttention = false; var targetDisconnected = false; var waitForReconnect = false }
    enum Event {
        case handoffReady, connecting, active(LDACFormat), formatChanged(LDACFormat), gainApplied(Double)
        case audioCaptureAccess(LDACAudioCaptureAccess), failed(String), connectionLost(String), finished(Completion)
    }
    let id: UUID
    let address: String
    let restoringOnly: Bool
    let receive: (Event) -> Void
    var gains: [Double]
    var stops = 0
    var audioRestorations: [Bool] = []
    var handoffs = 0
    init(id: UUID, address: String, helpers: Helpers, gain: Double, outputDeviceUID: String,
         priority: LDACPriorityControl?, configuration: LDACConfiguration, recoveryAttempt: Bool,
         restoringOnly: Bool, receive: @escaping (Event) -> Void) {
        self.id = id
        self.address = address
        self.restoringOnly = restoringOnly
        self.receive = receive
        gains = [gain]
    }
    convenience init(id: UUID, output: LDACNativeOutput, configuration: LDACConfiguration,
                     recoveryAttempt: Bool, restoringOnly: Bool, receive: @escaping (Event) -> Void) {
        self.init(id: id, address: "02:00:00:00:00:01", helpers: Helpers(), gain: 0,
                  outputDeviceUID: LDACNativeOutput.uid, priority: nil, configuration: configuration,
                  recoveryAttempt: recoveryAttempt, restoringOnly: restoringOnly, receive: receive)
    }
    func start() {}
    func emit(_ event: Event) { receive(event) }
    func allowHandoff() { handoffs += 1 }
    func updateGain(_ gain: Double) { gains.append(gain) }
    func stop(restoreAudio: Bool) { stops += 1; audioRestorations.append(restoreAudio) }
    func recoverConnection(reason: String) {}
    func verifyConnectionLoss(reason: String) {}
}

@MainActor
final class Controller: ObservableObject {
    var state = LDACState.off
    var targetAddress: String?
    var isSessionRunning = false
    var isRecovering = false
    var audioCaptureAccess = LDACAudioCaptureAccess.unchecked
    var session: LDACNativeSession?
    var sessionID = UUID()
    var requestedAddress: String?
    var requestedConfiguration = LDACConfiguration()
    var nativeOutput: LDACNativeOutput?
    var outputID: UUID?
    var headphones: SonyHeadphonesController?
    let bundle = Bundle.main
    let inspectDriver: ((Bundle) -> LDACDriverInstaller.State)? = { LDACDriverInstaller.inspect(bundle: $0) }
    var isClassicConnected: (String) -> Bool = { _ in true }
    var driverState = LDACDriverInstaller.State.current
    var audioRoute: MacAudioRouteObserver? = MacAudioRouteObserver()
    var resumeOutputUID: String?
    var suspensionRequested = false
    var pendingConnectionModes: [String: UUID] = [:]
    var deferredConnectionModes: [String: UUID] = [:]
    var preferenceRestoreTasks: [String: Task<Void, Never>] = [:]
    var connectionModeRestoreID: UUID?
    var connectionModeConfirmed = false
    var controlObservation: Int?
    var startTask: Task<Void, Never>?
    var readinessTask: Task<Void, Never>?
    var volumeTask: Task<Void, Never>?
    var volumeTaskID: UUID?
    var cleanupTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var recoveryTaskID: UUID?
    var recoveryAttempt = 0
    var retryAfterRestoration = false
    var isAwaitingAutomaticRetry = false
    var automaticRetryDelay: Duration = .milliseconds(150)
    var bindingHeldSince: Date?
    var bindingHoldTask: Task<Void, Never>?
    var bindingHoldLimit: TimeInterval = 0.4
    var recoveryEvents: [String] = []
    var restoreAudioOnStop = true
    var stableSince: Date?
    var pendingVolume: Int?
    var initialReadbackID: UUID?
    var controlSession: UInt64?
    var sourceAddress: String?
    var volumeRange: ClosedRange<Int>?
    var transportFormat: LDACFormat?
    var usable = false
    var requestedOutputGain = 0.0
    var volumeError: String?
    var stopCompletions: [@MainActor () -> Void] = []
    let helpers = LDACNativeSession.Helpers()
    var devices: SonyDeviceCoordinator? = SonyDeviceCoordinator()
    func observeControls(_ headphones: SonyHeadphonesController, devices: SonyDeviceCoordinator) {}
    var events: [String] = []
    func record(_ event: String, reason: String) { events.append(event) }
    func recordRecovery(_ event: String, reason: String) { recoveryEvents.append("\(event) \(reason)") }
    __METHODS__
    struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String, userFacing: String? = nil) { self.message = userFacing ?? message }
    }
}

@main
enum Check {
    @MainActor
    static func waitUntil(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Production controller did not reach the expected fixture state at line \(line)")
    }

    @MainActor
    static func started(_ generation: Generation = .v1) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let controller = Controller()
        let headphones = SonyHeadphonesController()
        headphones.playback.generation = generation
        headphones.localSource = generation == .v2
        controller.devices?.controllers[headphones.address] = headphones
        controller.requestedAddress = headphones.address
        controller.start(headphones.address)
        try await waitUntil { controller.session != nil }
        return (controller, headphones, controller.nativeOutput!, controller.session!)
    }

    /// A modern-controls session that reached `volume-admitted`, optionally bound to a selected multipoint source.
    @MainActor
    static func active(source: String? = nil) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let controller = Controller()
        let headphones = SonyHeadphonesController()
        headphones.playback.generation = .v2
        headphones.localSource = true
        headphones.multipoint.selectedSource = source.map { .init(address: $0) }
        controller.devices?.controllers[headphones.address] = headphones
        controller.requestedAddress = headphones.address
        controller.start(headphones.address)
        try await waitUntil { controller.session != nil }
        let session = controller.session!
        session.emit(.handoffReady)
        try await waitUntil { session.handoffs == 1 }
        session.emit(.active(LDACFormat()))
        try await waitUntil { headphones.queuedWrite != nil || controller.usable }
        if headphones.queuedWrite != nil {
            headphones.transmitVolume()
            headphones.confirmVolume()
        }
        try await waitUntil { controller.usable }
        return (controller, headphones, controller.nativeOutput!, session)
    }

    @MainActor
    static func stop(_ controller: Controller) async throws {
        controller.stop(restoreAudio: false, reason: "fixture complete")
        controller.session?.emit(.finished(.init(message: nil)))
        try await waitUntil { !controller.isSessionRunning }
    }

    @MainActor
    static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1")
        let (controller, headphones, output, session) = try await started()
        precondition(controller.hasMusicVolumeForHandoff && !controller.hasOwnedMusicContext,
                     "Legacy raw ownership admitted before active")
        session.emit(.handoffReady)
        try await waitUntil { session.handoffs == 1 }
        precondition(output.selected && !output.ready && session.handoffs == 1)
        precondition(headphones.queuedWrite == nil && session.gains == [0])
        session.emit(.connecting)
        precondition(!controller.hasOwnedMusicContext && !output.ready)

        headphones.isReady = false
        session.emit(.active(LDACFormat()))
        precondition(headphones.refreshes == 2, "Disconnected legacy controls did not retain their reopen request")
        try await Task.sleep(for: .milliseconds(120))
        precondition(headphones.volumeRefreshes == 0 && controller.controlSession == nil && !output.ready)
        headphones.notificationSession += 1
        headphones.isReady = true
        try await waitUntil { headphones.volumeRefreshes == 1 }
        headphones.statusFresh = true
        headphones.receiveVolume()
        try await Task.sleep(for: .milliseconds(120))
        precondition(controller.controlSession == nil && headphones.queuedWrite == nil && !output.ready,
                     "Volume without post-admission status admitted legacy LDAC")
        headphones.receiveStatus()
        try await waitUntil { headphones.queuedWrite != nil }
        precondition(!output.ready && session.gains == [0], "An unconfirmed setter unmuted the output")
        headphones.transmitVolume()
        precondition(!output.ready)
        headphones.confirmVolume()
        try await waitUntil { controller.usable }
        precondition(output.ready && output.preparations == 1 && session.gains.last == 1)
        print("PASS actual start/handoff/active/readiness: legacy preparation is silent; delayed controls require new status and volume plus confirmed setter")

        controller.pendingVolume = 6
        controller.sendPendingVolume()
        try await waitUntil { headphones.queuedWrite != nil }
        session.emit(.connectionLost("fixture queued loss"))
        headphones.transmitVolume()
        precondition(headphones.transmitted.count == 1 && !output.ready && !controller.hasOwnedMusicContext)
        precondition(controller.transportFormat == nil && controller.controlSession == nil && session.gains.last == 0)
        try await stop(controller)
        print("PASS actual volume task: raw loss revokes the queued write token before fake transmission")

        let (waiting, waitingDevice, _, waitingRaw) = try await active()
        waitingRaw.emit(.connectionLost("fixture loss"))
        waitingRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: false, waitForReconnect: false)))
        try await waitUntil { !waiting.isSessionRunning && waiting.recoveryTask != nil }
        waiting.state = .off
        try await Task.sleep(for: .milliseconds(400))
        precondition(waiting.recoveryTask == nil && waiting.recoveryTaskID == nil && !waiting.isAwaitingAutomaticRetry,
                     "An early exit left the retry wait set")
        waiting.state = .waitingForDevice
        waiting.scheduleRecovery(waitingDevice.address)
        precondition(waiting.recoveryTask != nil, "A stale retry wait made later retries be ignored")
        waiting.stop()
        print("PASS L10: every exit of the retry wait clears recoveryTask, so a later retry is scheduled")

        let (retrying, retryDevice, retryOutput, firstRaw) = try await active()
        firstRaw.emit(.connectionLost("fixture raw loss"))
        precondition(!retryOutput.ready && !retrying.usable && retrying.isRecovering)
        firstRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: false)))
        try await Task.sleep(for: .milliseconds(50))
        precondition(retrying.session !== firstRaw && retrying.session?.restoringOnly == true,
                     "A recoverable abort left the headphones disconnected instead of restoring ordinary audio")
        let restoration = retrying.session!
        precondition(retryOutput.restores.isEmpty && retrying.requestedAddress == retryDevice.address && retrying.recoveryAttempt == 1
                     && !retrying.isAwaitingAutomaticRetry, "The retry was armed before ordinary audio returned")
        let renewedID = retrying.sessionID
        firstRaw.emit(.active(LDACFormat(value: 99)))
        precondition(retrying.sessionID == renewedID && retrying.transportFormat == nil, "An old raw session re-admitted LDAC")
        retrying.audioRoute?.route = Route(uid: "fixture-speakers")
        restoration.emit(.finished(.init(message: nil, requiresAttention: true)))
        try await waitUntil { !retrying.isSessionRunning }
        precondition(retryOutput.restores == [false] && retrying.state == .waitingForDevice && retrying.isAwaitingAutomaticRetry,
                     "Ordinary audio was not handed back while the retry waits")
        precondition(retryDevice.connectionRequests.isEmpty, "The fallback restored Stable Connection before its LDAC retry")
        retrying.audioRoute?.route = Route(uid: "fixture-headphones")
        for _ in 0..<10 { retrying.resumeIfReady() }
        precondition(retrying.session == nil, "LDAC retried before its delay")
        retrying.audioRoute?.route = Route(uid: "fixture-speakers")
        try await waitUntil { !retrying.isAwaitingAutomaticRetry }
        retrying.resumeIfReady()
        precondition(retrying.session == nil, "The retry replaced the user's subsequently selected output")
        retrying.audioRoute?.route = Route(uid: "fixture-headphones")
        retrying.resumeIfReady()
        try await waitUntil { retrying.session != nil }
        let retried = retrying.session!
        precondition(!retried.restoringOnly && retrying.recoveryAttempt == 1, "The automatic retry renewed its own budget")
        retried.emit(.connectionLost("fixture second loss"))
        retried.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: false)))
        try await waitUntil { retrying.session != nil && retrying.session !== retried }
        let finalRestoration = retrying.session!
        precondition(finalRestoration.restoringOnly && retrying.requestedAddress == nil,
                     "The aborted retry tried LDAC again instead of staying on ordinary audio")
        finalRestoration.emit(.finished(.init(message: nil, requiresAttention: true)))
        try await waitUntil { !retrying.isSessionRunning }
        guard case let .failed(notice) = retrying.state, notice.contains("ordinary Bluetooth audio") else {
            preconditionFailure("The aborted retry gave no notice: \(retrying.state)")
        }
        try await Task.sleep(for: .milliseconds(300))
        retrying.resumeIfReady()
        precondition(retrying.session == nil && !retrying.isAwaitingAutomaticRetry, "LDAC retried a second time")
        precondition(retrying.recoveryEvents.contains { $0.hasPrefix("native-fallback attempt=1") }
                     && retrying.recoveryEvents.contains { $0.hasPrefix("retry-exhausted") })
        print("PASS D1 recovery: a recoverable abort restores ordinary audio first, retries LDAC once after the delay under the source and output guards, and a failed retry stays on ordinary audio with a notice")

        let (renewed, _, _, longRaw) = try await active()
        renewed.recoveryAttempt = 1
        renewed.stableSince = Date().addingTimeInterval(-31)
        longRaw.emit(.connectionLost("fixture loss after stable playback"))
        longRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: false, waitForReconnect: false)))
        try await waitUntil { !renewed.isSessionRunning }
        precondition(renewed.requestedAddress != nil && renewed.isAwaitingAutomaticRetry && renewed.recoveryAttempt == 1,
                     "Thirty seconds of stable playback did not renew the single retry")
        precondition(renewed.session == nil, "Ordinary audio was still connected, yet the restore helper ran")
        renewed.stop()
        precondition(renewed.state == .off && !renewed.isAwaitingAutomaticRetry && renewed.recoveryTask == nil)
        print("PASS D1 budget: stable playback renews the retry; an abort before the deliberate disconnect only releases the output; Off cancels the wait")

        let (quiet, quietDevice, quietOutput, _) = try await active()
        let configurations = quietOutput.configurations
        let quietWrites = quietDevice.transmitted
        let confirmations = quiet.events.filter { $0 == "volume-confirmed" }.count
        for _ in 0..<40 {
            quiet.controlsChanged()
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))
        precondition(quietOutput.configurations == configurations && quiet.volumeTask == nil && quiet.pendingVolume == nil
                     && quiet.events.filter { $0 == "volume-confirmed" }.count == confirmations,
                     "Unchanged headphone volume re-sent the native volume on every change notification")
        quietDevice.playback.volume = 9
        quiet.controlsChanged()
        try await waitUntil { quiet.volumeTask == nil && quietOutput.controls.volume(in: 0...30) == 9 }
        precondition(quietOutput.configurations == configurations + 1 && quietDevice.transmitted == quietWrites,
                     "A headphone volume change was not mirrored exactly once")
        quietOutput.controls.scalar = 0.5
        quiet.pendingVolume = quietOutput.controls.volume(in: 0...30)
        quiet.sendPendingVolume()
        try await waitUntil { quietDevice.queuedWrite != nil }
        quietDevice.transmitVolume()
        quietDevice.confirmVolume()
        try await waitUntil { quiet.volumeTask == nil }
        precondition(quietDevice.playback.volume == 15 && quietOutput.configurations == configurations + 1,
                     "A Mac-side volume change configured the Mac output it came from")
        try await stop(quiet)
        print("PASS L6: change notifications with an unchanged volume send nothing; a headphone-side change configures the Mac once; a Mac-side change is not echoed back")

        let (late, lateDevice, lateOutput, _) = try await active()
        lateOutput.configureTimeouts = 1
        lateDevice.playback.volume = 7
        late.controlsChanged()
        try await waitUntil { late.volumeTask == nil && lateOutput.configureTimeouts == 0 }
        precondition(late.usable && lateOutput.ready && !late.isRecovering && late.requestedAddress != nil,
                     "A late owner reply to configure stopped LDAC")
        late.controlsChanged()
        try await waitUntil { late.volumeTask == nil && lateOutput.controls.volume(in: 0...30) == 7 }
        try await stop(late)
        print("PASS L12: a late configure reply is not fatal; the next change notification configures again")

        let (flapping, flapDevice, flapOutput, _) = try await active()
        flapDevice.volumeFresh = false
        flapping.controlsChanged()
        try await Task.sleep(for: .milliseconds(150))
        precondition(flapping.usable && flapOutput.ready && !flapping.isRecovering,
                     "A transient loss of volume freshness tore LDAC down")
        flapDevice.volumeFresh = true
        flapping.controlsChanged()
        precondition(flapping.bindingHeldSince == nil && flapping.bindingIsCurrent)
        flapDevice.volumeFresh = false
        flapping.controlsChanged()
        try await waitUntil { flapping.isRecovering }
        precondition(!flapOutput.ready && flapping.recoveryEvents.contains { $0.hasPrefix("binding-lost binding-hold-expired volume-controls-stale") },
                     "An expired hold did not name the clause that failed")
        try await stop(flapping)
        print("PASS L4: lost freshness holds LDAC and recovers only after the hold limit, naming the failed clause")

        let (keeping, keepDevice, keepOutput, _) = try await active()
        keepDevice.pendingControlTransition = "source-keeping"
        keeping.controlsChanged()
        try await Task.sleep(for: .milliseconds(600))
        precondition(keeping.usable && keepOutput.ready && !keeping.isRecovering, "A transition that keeps the source tore LDAC down")
        keeping.pendingVolume = 5
        keeping.sendPendingVolume()
        try await Task.sleep(for: .milliseconds(150))
        precondition(keepDevice.queuedWrite == nil, "A volume write was sent during a held transition")
        keepDevice.pendingControlTransition = nil
        keeping.controlsChanged()
        try await waitUntil { keepDevice.queuedWrite != nil }
        keepDevice.transmitVolume()
        keepDevice.confirmVolume()
        try await waitUntil { keeping.volumeTask == nil }
        precondition(keeping.usable && keepDevice.playback.volume == 5)
        keepDevice.pendingControlTransition = "multipoint"
        keepDevice.isDeviceConnected = false
        keeping.controlsChanged()
        precondition(keeping.isRecovering && !keepOutput.ready, "A transition hid a real control loss")
        try await stop(keeping)
        print("PASS L5: keeping, device-action and multipoint transitions hold the binding and defer volume; a real loss during one still recovers")

        for change in ["source", "connection-mode"] {
            let (changed, changedDevice, _, changedRaw) = try await active(source: "02:00:00:00:00:02")
            changedDevice.pendingControlTransition = "device-action"
            changed.controlsChanged()
            precondition(changed.usable && changed.requestedAddress != nil)
            changedDevice.pendingControlTransition = nil
            if change == "source" {
                changedDevice.requestedSourceSwitchAddress = "02:00:00:00:00:03"
                changedDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:03")
            }
            else { changedDevice.isLeavingLDACConnectionMode = true }
            changed.controlsChanged()
            precondition(changed.requestedAddress == nil && changedRaw.audioRestorations == [true] && !changed.isRecovering,
                         "A real \(change) change did not stop LDAC and restore ordinary audio")
            changedRaw.emit(.finished(.init(message: nil)))
            try await waitUntil { !changed.isSessionRunning }
            guard case let .failed(notice) = changed.state,
                  notice.contains(change == "source" ? "audio source" : "Sound Quality") else {
                preconditionFailure("A real \(change) change gave no notice: \(changed.state)")
            }
            for _ in 0..<10 { changed.resumeIfReady() }
            precondition(changed.session == nil, "LDAC resumed after a real \(change) change")
        }
        print("PASS D5: a real source or connection-mode change stops LDAC, restores ordinary audio and tells the user")

        for changed in ["range", "control-session", "target", "stop"] {
            let (bound, device, endpoint, raw) = try await started()
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            raw.emit(.active(LDACFormat()))
            try await waitUntil { device.volumeRefreshes == 1 }
            device.receiveStatus()
            device.receiveVolume()
            try await waitUntil { device.queuedWrite != nil }
            if changed == "range" { device.playback.musicVolumeRange = 0...20 }
            else if changed == "control-session" { device.notificationSession += 1 }
            else if changed == "stop" { bound.stop(reason: "fixture queued stop") }
            else {
                let returning = SonyHeadphonesController()
                returning.isDeviceConnected = false
                returning.isReady = false
                bound.devices?.controllers[device.address] = returning
            }
            bound.controlsChanged()
            if changed == "target" {
                precondition(bound.requestedAddress == device.address && bound.suspensionRequested)
                precondition(bound.state == .stopping && raw.audioRestorations == [false])
                raw.emit(.finished(.init(message: nil, targetDisconnected: true)))
                try await waitUntil { !bound.isSessionRunning }
                precondition(bound.requestedAddress == device.address && bound.state == .waitingForDevice)
            }
            device.transmitVolume()
            precondition(device.transmitted.isEmpty && !endpoint.ready && !bound.usable,
                         "Changed \(changed) retained queued legacy volume ownership")
            try await stop(bound)
        }
        print("PASS actual binding: range, Sony control session, controller replacement and stop revoke queued writes")

        let (modern, modernDevice, modernOutput, modernRaw) = try await started(.v2)
        precondition(modern.hasOwnedMusicContext)
        modernRaw.emit(.handoffReady)
        try await waitUntil { modernRaw.handoffs == 1 }
        modernRaw.emit(.active(LDACFormat()))
        try await waitUntil { modernDevice.queuedWrite != nil }
        precondition(modernDevice.volumeRefreshes == 0 && !modernOutput.ready)
        modernDevice.transmitVolume()
        modernDevice.confirmVolume()
        try await waitUntil { modern.usable }
        let transmitted = modernDevice.transmitted
        let silences = modernOutput.silences
        modernDevice.blocksPlaybackCommands = true
        modern.pendingVolume = 7
        modern.controlsChanged()
        try await Task.sleep(for: .milliseconds(150))
        precondition(modern.bindingIsCurrent && modern.usable && modernOutput.ready && !modern.isRecovering
                     && modern.session === modernRaw && modernOutput.silences == silences,
                     "A temporary command block discarded active LDAC ownership")
        precondition(modern.pendingVolume == 7 && modernDevice.queuedWrite == nil && modernDevice.transmitted == transmitted,
                     "A blocked Sony volume command was submitted")
        modernDevice.blocksPlaybackCommands = false
        modern.controlsChanged()
        try await waitUntil { modernDevice.queuedWrite != nil }
        modernDevice.transmitVolume()
        modernDevice.confirmVolume()
        try await waitUntil { modern.volumeTask == nil }
        precondition(modern.usable && modernOutput.ready && !modern.isRecovering && modernDevice.playback.volume == 7,
                     "Volume did not resume on the original LDAC session")
        modernDevice.blocksPlaybackCommands = true
        modernDevice.localSource = false
        modern.controlsChanged()
        precondition(modernOutput.ready && modern.usable, "An unconfirmed source context revoked LDAC without a hold")
        try await waitUntil { !modernOutput.ready && !modern.usable }
        try await stop(modern)
        print("PASS existing v2 path: temporary command blocks retain active audio and defer volume; unblocking resumes writes; a lost source context revokes ownership once its hold expires")

        for (controlsConnected, cleanupFails) in [(false, false), (true, false), (false, true)] {
            let (cased, casedDevice, casedOutput, casedRaw) = try await started(.v2)
            casedRaw.emit(.handoffReady)
            try await waitUntil { casedOutput.selected }
            casedDevice.isReady = false
            casedDevice.isDeviceConnected = controlsConnected
            cased.isClassicConnected = { _ in false }
            if cleanupFails { casedOutput.restoreError = "Fixture lease release failed" }
            casedRaw.emit(.connectionLost("Controls lost before deliberate recovery disconnect"))
            casedRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: false)))
            let restoring = cased.session
            precondition(restoring?.restoringOnly == true && cased.recoveryTask == nil,
                         "Unavailable controls after the deliberate disconnect left ordinary audio disconnected")
            restoring?.emit(.finished(.init(message: nil, requiresAttention: true)))
            try await waitUntil { !cased.isSessionRunning }
            precondition(cased.session == nil && cased.nativeOutput == nil)
            precondition(casedOutput.recoveryPreparations == 0 && casedOutput.restores == [false] && !casedOutput.selected,
                         "The fallback retained the virtual output")
            precondition(casedDevice.connectionRequests.isEmpty, "The fallback restored Stable Connection before its retry")
            if cleanupFails {
                precondition(cased.state == .failed("Fixture lease release failed") && cased.requestedAddress == nil
                             && cased.recoveryTask == nil, "A real output cleanup failure was hidden")
            } else {
                precondition(cased.state == .waitingForDevice && cased.requestedAddress == casedDevice.address
                             && cased.recoveryTask != nil, "The fallback discarded LDAC intent")
                try await waitUntil { cased.recoveryTask == nil }
                for _ in 0..<100 { cased.resumeIfReady() }
                precondition(cased.session == nil, "The retry bypassed control readiness")
                cased.audioRoute?.route = Route(uid: "fixture-speakers")
                casedDevice.isReady = true
                casedDevice.isDeviceConnected = true
                cased.isClassicConnected = { _ in true }
                cased.resumeIfReady()
                precondition(cased.session == nil && cased.audioRoute?.route?.uid == "fixture-speakers",
                             "Device return replaced the user's subsequently selected output")
                cased.audioRoute?.route = Route(uid: "fixture-headphones")
                cased.resumeIfReady()
                try await waitUntil { cased.session != nil }
                try await stop(cased)
            }
        }
        print("PASS actual incident sequence: controls unavailable during handoff, deliberate disconnect restores ordinary audio, the retry waits for readiness and the user's output; cleanup errors remain explicit")

        let (resuming, returning, oldOutput, oldSession) = try await started(.v2)
        let originalPreference = UUID()
        returning.lastConnectionModeChangeID = originalPreference
        resuming.connectionModeRestoreID = originalPreference
        resuming.connectionModeConfirmed = true
        returning.isDeviceConnected = false
        oldSession.emit(.connectionLost("Headphones returned to case"))
        oldSession.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: true)))
        try await waitUntil { resuming.state == .waitingForDevice }
        precondition(!resuming.isSessionRunning && resuming.session == nil && !oldOutput.selected)
        precondition(resuming.deferredConnectionModes[returning.address] == originalPreference)
        for _ in 0..<100 { resuming.resumeIfReady() }
        precondition(resuming.session == nil && resuming.recoveryTask == nil && returning.connectionRequests.isEmpty)
        returning.isDeviceConnected = true
        resuming.resumeIfReady()
        try await waitUntil { resuming.session != nil }
        let resumedSession = resuming.session!
        precondition(resumedSession !== oldSession && resuming.headphones === returning)
        precondition(resuming.connectionModeRestoreID == originalPreference && resuming.deferredConnectionModes.isEmpty,
                     "Actual resume dropped the original Stable Connection obligation")
        oldSession.emit(.failed("Stale session failure"))
        precondition(resuming.requestedAddress == returning.address && resuming.session === resumedSession)
        resuming.stop(restoreAudio: false, reason: "User disabled LDAC after resume")
        resumedSession.emit(.finished(.init(message: nil)))
        try await waitUntil { returning.connectionRequests == [.stableConnection] }
        returning.confirmConnectionMode(.stableConnection)
        try await waitUntil { !resuming.isSessionRunning }
        precondition(resuming.state == .off && resuming.requestedAddress == nil)
        print("PASS actual case-disconnect completion and resumed start: waiting releases output, notifications stay idle, stale events are ignored, and original Stable Connection is restored after manual Off")

        let (manual, manualDevice, _, manualRaw) = try await started(.v2)
        manualDevice.isDeviceConnected = false
        manual.stop(reason: "User disabled LDAC during disconnect")
        manualRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: true)))
        try await waitUntil { !manual.isSessionRunning }
        precondition(manual.session == nil && manual.state == .off,
                     "Manual Off launched a restoration helper for absent headphones")

        let (forced, _, _, forcedRaw) = try await started(.v2)
        forced.stop(reason: "User disabled LDAC after deliberate recovery disconnect")
        forcedRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true)))
        let restorationOnly = forced.session
        precondition(restorationOnly != nil && restorationOnly !== forcedRaw && restorationOnly?.restoringOnly == true,
                     "Manual Off skipped native-audio restoration after our deliberate disconnect")
        restorationOnly?.emit(.finished(.init(message: nil)))
        try await waitUntil { !forced.isSessionRunning }
        precondition(forced.session == nil && forced.state == .off)

        for controlsFresh in [true, false] {
            let (otherSource, sourceDevice, _, sourceRaw) = try await active(source: "02:00:00:00:00:02")
            sourceDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:03")
            sourceDevice.localSource = false
            if !controlsFresh { sourceDevice.volumeFresh = false }
            otherSource.controlsChanged()
            precondition(otherSource.requestedAddress == sourceDevice.address && sourceRaw.stops == 1,
                         "Another multipoint source playing stopped LDAC instead of suspending it")
            precondition(sourceRaw.audioRestorations == [true], "Phone playback left ordinary Mac Bluetooth audio disconnected")
            sourceRaw.emit(.finished(.init(message: nil)))
            try await waitUntil { otherSource.state == .waitingForDevice }
            for _ in 0..<10 { otherSource.resumeIfReady() }
            precondition(otherSource.session == nil, "LDAC took over another multipoint source")
            sourceDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:02")
            sourceDevice.localSource = true
            sourceDevice.volumeFresh = true
            otherSource.resumeIfReady()
            try await waitUntil { otherSource.session != nil }
            try await stop(otherSource)
        }
        print("PASS actual completion routing: manual Off never reconnects absent headphones; another multipoint source playing suspends LDAC with ordinary audio and resumes once the Mac is the source again")
        print("PASS scope: production controller methods and volume mapping; fake transport, confirmations, observations and native output; no hardware or installation")
    }
}
'''
names = ["needsStopBeforeTermination", "deviceUnavailableReason", "refreshDriverState", "start", "launch", "sessionFinished",
         "fallBackToOrdinaryAudio", "hasMusicVolumeForHandoff", "hasOwnedMusicContext",
         "hasOtherMusicSource", "bindingIsCurrent", "bindingCheck", "musicControlStatus", "waitForControls", "controlsChanged",
         "holdBinding", "recoverBinding", "stopForChange", "sendPendingVolume", "setOutputGain", "fail", "beginRecovery",
         "scheduleRecovery", "endRetryWait", "cancelAutomaticRetry", "stop", "stopSession",
         "suspend", "resumeIfReady", "reconcileConnectionPreferences", "forgetConnectionPreference", "scheduleConnectionPreferenceRestoration", "prepareConnectionMode", "waitForConnectionChange", "restoreConnectionMode",
         "restoreConnectionPreference", "finish", "completeStop"]
fixture = fixture.replace("precondition(", "check(")
fixture = fixture.replace("__VOLUME__", volume).replace("__METHODS__", "\n".join(member(name) for name in names))

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-controller-volume-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(fixture)
    environment = os.environ.copy()
    environment["ACOUPLET_TESTING"] = "1"
    environment["CFFIXED_USER_HOME"] = str(directory / "home")
    Path(environment["CFFIXED_USER_HOME"]).mkdir()
    environment["CLANG_MODULE_CACHE_PATH"] = str(directory / "module-cache")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                   env=environment, check=True)
    subprocess.run([str(binary)], env=environment, check=True)
    if "--check-mutations" in sys.argv:
        mutations = [
            ("raw", "hasMusicVolumeForHandoff && (headphones?.playback.generation != .v1 || transportFormat != nil)",
             "hasMusicVolumeForHandoff", "Legacy raw ownership admitted before active"),
            ("status", "&& headphones.musicStatusReadbackID != nil && headphones.musicStatusReadbackID != initialStatusReadbackID",
             "", "Volume without post-admission status admitted legacy LDAC"),
            ("ordinary-audio restoration", "        if targetDisconnected {\n            sessionID = UUID()\n            launch(address, restoringOnly: true)\n        } else {\n            finish(nil)\n        }",
             "        finish(nil, targetDisconnected: targetDisconnected)", "A recoverable abort left the headphones disconnected"),
            ("single retry", "if recoveryAttempt >= 1 {", "if recoveryAttempt >= 2 {", "The aborted retry tried LDAC again"),
            ("retry-wait cleanup", "        guard recoveryTaskID == taskID else { return }\n        recoveryTask = nil",
             "        guard recoveryTaskID == taskID else { return }\n        return;", "An early exit left the retry wait set"),
            ("unchanged-volume filter", "let output = nativeOutput, output.controls.volume(in: range) != volume {",
             "let output = nativeOutput {", "Unchanged headphone volume re-sent the native volume"),
            ("configure echo filter", "let output = self.nativeOutput,\n                       output.controls.volume(in: range) != volume {",
             "let output = self.nativeOutput {", "A Mac-side volume change configured the Mac output it came from"),
            ("late configure tolerance", "                        catch is LDACOwnerTimeoutError {",
             "                        catch let error as LDACOwnerTimeoutError where false {", "A late owner reply to configure stopped LDAC"),
            ("multipoint suspension", "           headphones?.requestedSourceSwitchAddress != selected {",
             "           headphones?.requestedSourceSwitchAddress != selected, false {",
             "Another multipoint source playing stopped LDAC instead of suspending it"),
            ("requested-switch stop", "           headphones?.requestedSourceSwitchAddress != selected {",
             "           true {", "A real source change did not stop LDAC and restore ordinary audio"),
            ("binding hold", "            holdBinding(reason, transition: transition)\n            return",
             "            recoverBinding(reason)\n            return", "A transient loss of volume freshness tore LDAC down"),
            ("source-change stop", "        case let .sourceChanged(reason):\n            stopForChange(reason)\n            return",
             "        case let .sourceChanged(reason):\n            recoverBinding(reason)\n            return",
             "change did not stop LDAC and restore ordinary audio"),
        ]
        for name, before, after, failure in mutations:
            assert fixture.count(before) == 1
            swift.write_text(fixture.replace(before, after))
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                           env=environment, check=True)
            result = subprocess.run([str(binary)], env=environment, capture_output=True, text=True)
            assert result.returncode == 1 and failure in result.stderr, (name, result.returncode, result.stdout, result.stderr)
            print(f"PASS mutation rejected: missing {name} admission witness")
