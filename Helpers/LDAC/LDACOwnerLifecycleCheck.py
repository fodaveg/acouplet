from pathlib import Path
import json
import os
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
owner = (root / 'Sources/LDACOwner.swift').read_text()
native = (root / 'Sources/LDACNativeSession.swift').read_text()
output = (root / 'Sources/LDACNativeOutput.swift').read_text()
types = native[native.index('struct LDACFormat:'):native.index('final class LDACNativeSession:')]
child = native[native.index('final class LDACNativeChild {'):native.rindex('#endif')]
events = native[native.index('    enum Event:'):native.index('    private static let daemonEventExpression')]
volume = output[output.index('struct LDACNativeVolume:'):output.index('@MainActor\nfinal class LDACNativeOutput')]
restoration = output[output.index('    @discardableResult\n    func silence('):output.index('    private func applyControls(')]
selectors = output[output.index('    private var handoffSelectors:'):output.index('    init(id:')]
fixture = r'''
import Foundation
import Darwin
import CoreAudio

@MainActor
func AudioObjectRemovePropertyListenerBlock(_ object: AudioObjectID, _ property: inout AudioObjectPropertyAddress,
    _ queue: DispatchQueue, _ block: AudioObjectPropertyListenerBlock) -> OSStatus { noErr }

@MainActor
func SwiftRecord(_ value: String) {
    let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWNER_CHECK"]!).appendingPathComponent("events")
    let handle = try! FileHandle(forWritingTo: file)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data((value + "\n").utf8))
    try! handle.close()
}

struct OutputError: LocalizedError {
    let message: String
    init(_ message: String, userFacing: String? = nil) { self.message = userFacing ?? message }
    var errorDescription: String? { message }
}

__TYPES__
__VOLUME__

@MainActor
final class LDACNativeOutput {
    nonisolated static let uid = "dev.baglayan.Acouplet.ldac-output"
    static let system: AudioObjectID = 1
    static let defaultSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
    static var routes: [UInt32: UInt32] {
        get {
            let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWNER_CHECK"]!).appendingPathComponent("routes")
            guard let data = try? Data(contentsOf: url) else { return [defaultSelectors[0]: 6, defaultSelectors[1]: 8] }
            return try! JSONDecoder().decode([UInt32: UInt32].self, from: data)
        }
        set {
            let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWNER_CHECK"]!).appendingPathComponent("routes")
            try! JSONEncoder().encode(newValue).write(to: url)
        }
    }
    static var routeOwner: FileHandle?
    var holdsRouteOwner = false
    var restoringOwner = false
    static var muteWrites: [UInt32] = []
    static var missing = false
    var device: AudioObjectID = 5
    let address: String
    var model = ""
    var controls = LDACNativeVolume(scalar: 0.4, muted: false)
    var expected = LDACNativeVolume(scalar: 0.4, muted: true)
    var savedDefaults: [UInt32: String] = [:]
    var ready = false
    var restoring = false
    var isSelected = false
    var ownsLease = false
    var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var renewTask: Task<Void, Never>?
    var leaseActivity: NSObjectProtocol?
    __SELECTORS__
    init(id: UUID, address: String, changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) { self.address = address }
    func claim(model: String, targetAddress: String, sampleRate: LDACSampleRate, recovering: LDACRouteRecovery? = nil) async throws {
        self.model = model
        restoringOwner = recovering != nil
        Self.missing = model == "missing"
        ownsLease = true
        savedDefaults = [Self.defaultSelectors[0]: "headphones", Self.defaultSelectors[1]: "speakers"]
        if let recovering {
            savedDefaults = recovering.defaults
            controls = recovering.controls
            isSelected = recovering.selected
            SwiftRecord("owner-recovery")
        }
        SwiftRecord("claim \(getpid()) \(sampleRate.rawValue)")
        FileHandle.standardError.write(Data("fixture diagnostic on stderr\n".utf8))
        if model == "slow" { try await Task.sleep(for: .seconds(10)) }
    }
    var routeRecovery: LDACRouteRecovery {
        .init(address: address, model: model, sampleRate: .hz48000, defaults: savedDefaults, controls: controls, selected: isSelected)
    }
    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) throws {
        if model == "delayed" || model == "hung" || model == "parent-hung" || model == "ordering" {
            SwiftRecord("owner-configure-start")
            usleep(model == "delayed" || model == "ordering" ? 500_000 : model == "hung" ? 800_000 : 10_000_000)
            SwiftRecord("owner-configure-end")
        }
        _ = controls.update(volume: volume, range: range)
    }
    func priorityControl() throws -> LDACPriorityControl { LDACPriorityControl(request: { _, _ in }, state: { .init(phase: "idle", error: nil) }) }
    func selectForHandoff() throws {
        isSelected = true
        Self.routes[Self.defaultSelectors[0]] = model == "changed" ? 9 : 5
        SwiftRecord("handoff")
    }
    func validateForRecovery() throws {}
    func prepareForReconnect() throws -> LDACPriorityControl { try priorityControl() }
    func finishPreparation() throws { ready = true }
    __RESTORATION__
    func leaseIsOwned() throws -> Bool { ownsLease }
    func setLease(_ claim: Bool) throws {
        SwiftRecord("lease \(claim)")
        let state: [String: Any] = ["routes": Self.routes.mapKeys, "mutes": Self.muteWrites, "lease": claim]
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWNER_CHECK"]!).appendingPathComponent("state"))
    }
    func record(_ event: String, reason: String) { SwiftRecord("output \(event)") }
    static func resolve(_ uid: String) throws -> UInt32? { uid == "headphones" ? (missing ? nil : 6) : 8 }
    static func isAliveOutput(_ object: UInt32) throws -> Bool { true }
    nonisolated static func canTransferControls(uid: String, transport: UInt32, address: String) -> Bool { uid == "headphones" }
    static func setMute(_ object: UInt32, muted: Bool) throws { muteWrites.append(object) }
    static func readString(_ object: UInt32, selector: UInt32) throws -> String {
        if object == 5 { return uid }
        if object == 6 { return "headphones" }
        return "speakers"
    }
    static func read<T>(_ object: UInt32, selector: UInt32, initial: T) throws -> T {
        (object == system ? routes[selector]! : kAudioDeviceTransportTypeBluetooth) as! T
    }
    static func write<T>(_ object: UInt32, selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal,
                         value: T, requiringLease: Bool = false) throws {
        if object == system { routes[selector] = value as? UInt32; SwiftRecord("route-write") }
    }
}

extension Dictionary where Key == UInt32, Value == UInt32 {
    var mapKeys: [String: UInt32] { Dictionary<String, UInt32>(uniqueKeysWithValues: map { (String($0.key), $0.value) }) }
}

final class LDACNativeSession: @unchecked Sendable {
    struct Helpers: Sendable { init(bundle: Bundle) {} }
    __EVENTS__
    let id: UUID
    private let receive: @MainActor @Sendable (Event) -> Void
    private let configuration: LDACConfiguration
    private let restoringOnly: Bool
    private var children: [LDACNativeChild] = []
    private var stopped = false
    init(id: UUID, address: String, helpers: Helpers, gain: Double, outputDeviceUID: String? = nil,
         priority: LDACPriorityControl? = nil, configuration: LDACConfiguration = LDACConfiguration(),
         recoveryAttempt: Bool = false, restoringOnly: Bool = false,
         receive: @escaping @MainActor @Sendable (Event) -> Void) {
        self.id = id
        self.receive = receive
        self.configuration = configuration
        self.restoringOnly = restoringOnly
    }
    @MainActor
    func start() {
        if restoringOnly {
            SwiftRecord("native-restored-after-gap")
            receive(.finished(.init(message: nil, canRetry: false, requiresAttention: false, targetDisconnected: false, waitForReconnect: false)))
            return
        }
        for role in ["capture", "logger"] {
            let child = try! LDACNativeChild(executable: Bundle.main.executableURL!, arguments: ["--fixture-child", role], inheritedPCM: nil)
            children.append(child)
            SwiftRecord("child \(child.pid)")
        }
        SwiftRecord("start \(configuration.sampleRate.rawValue) \(configuration.quality.rawValue)")
        receive(.handoffReady)
        receive(.active(configuration.format))
    }
    @MainActor
    func stop(restoreAudio: Bool) {
        if stopped { return }
        stopped = true
        SwiftRecord("stop-intent \(restoreAudio)")
        let receive = receive
        DispatchQueue.global().async {
            for child in self.children { child.closeInput(); child.wait() }
            Task { @MainActor in
                SwiftRecord("children-reaped")
                if restoreAudio { SwiftRecord("native-restored") }
                let mode = ProcessInfo.processInfo.environment["OWNER_MODE"]!
                receive(.finished(.init(message: nil, canRetry: mode == "gap", requiresAttention: false,
                    targetDisconnected: mode == "missing", waitForReconnect: false)))
            }
        }
    }
    func recoverConnection(reason: String) {}
    func verifyConnectionLoss(reason: String) {}
    func allowHandoff() {}
    func updateGain(_ gain: Double) {}
}

__CHILD__
__OWNER__

extension LDACNativeChild {
    func duplicateInput() throws -> LDACNativeChild {
        try LDACNativeChild(executable: Bundle.main.executableURL!, arguments: ["--fixture-held-input"], inheritedPCM: input)
    }
}

extension LDACOwnerChannel {
    func duplicateInput() throws -> LDACNativeChild { try child.duplicateInput() }
    var ownerPID: pid_t { child.pid }
    func malformed() throws { try child.send("{") }
    func oversized() throws { try child.send(String(repeating: "x", count: 8193)) }
}

extension LDACOwnerOutput {
    func duplicateInput() throws -> LDACNativeChild { try channel!.duplicateInput() }
    var ownerPID: pid_t { channel!.ownerPID }
    func malformed() throws { try channel!.malformed() }
    func oversized() throws { try channel!.oversized() }
    func endInput() { channel!.close() }
    var ownerEnded: Bool { channel!.hasEnded }
}

@main
@MainActor
enum Check {
    static func main() async throws {
        if CommandLine.arguments.contains("--ldac-owner") { LDACOwnerWorker.run(); return }
        if CommandLine.arguments.contains("--fixture-held-input") { usleep(3_000_000); return }
        if CommandLine.arguments.contains("--fixture-child") {
            while !FileHandle.standardInput.availableData.isEmpty {}
            return
        }
        let mode = ProcessInfo.processInfo.environment["OWNER_MODE"]!
        for rate in LDACSampleRate.allCases {
            for quality in LDACQuality.allCases {
                let configuration = LDACConfiguration(sampleRate: rate, quality: quality)
                let request = LDACOwnerRequest(id: UUID(), command: .start(UUID(), configuration, false, false))
                let decoded = try JSONDecoder().decode(LDACOwnerRequest.self, from: JSONEncoder().encode(request))
                guard case let .start(_, returned, _, _) = decoded.command else { fatalError() }
                precondition(returned == configuration && returned.helperArguments == configuration.helperArguments)
            }
        }
        if mode == "dropped" {
            var output: LDACOwnerOutput? = LDACOwnerOutput(id: UUID(), address: "02:00:00:00:00:01") { _ in }
            try await output!.claim(model: mode, targetAddress: "02:00:00:00:00:01", sampleRate: .hz48000)
            try await output!.selectForHandoff()
            output = nil
            let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWNER_CHECK"]!).appendingPathComponent("state")
            while !FileManager.default.fileExists(atPath: state.path) { try await Task.sleep(for: .milliseconds(5)) }
            SwiftRecord("app-complete")
            return
        }
        if mode == "early" {
            let output = LDACOwnerOutput(id: UUID(), address: "02:00:00:00:00:01") { _ in }
            let claim = Task { try await output.claim(model: "slow", targetAddress: "02:00:00:00:00:01", sampleRate: .hz44100) }
            claim.cancel()
            do { try await claim.value; fatalError("Cancelled claim succeeded") }
            catch is CancellationError {}
            SwiftRecord("spawned \(output.ownerPID)")
            let result = await output.restoreAndRelease()
            precondition(result == nil)
            SwiftRecord("app-complete")
            return
        }
        if mode == "cancel" {
            let output = LDACOwnerOutput(id: UUID(), address: "02:00:00:00:00:01") { _ in }
            let claim = Task { try await output.claim(model: "slow", targetAddress: "02:00:00:00:00:01", sampleRate: .hz44100) }
            let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWNER_CHECK"]!).appendingPathComponent("events")
            while !(try String(contentsOf: file, encoding: .utf8)).contains("claim ") { try await Task.sleep(for: .milliseconds(5)) }
            claim.cancel()
            do { try await claim.value; fatalError("Cancelled claim succeeded") }
            catch is CancellationError {}
            let result = await output.restoreAndRelease()
            precondition(result == nil)
            SwiftRecord("app-complete")
            return
        }
        var active = false
        var completed = false
        let output = LDACOwnerOutput(id: UUID(), address: "02:00:00:00:00:01") { _ in }
        try await output.claim(model: mode, targetAddress: "02:00:00:00:00:01", sampleRate: .hz96000)
        if mode == "claimed" {
            SwiftRecord("app-claimed")
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        try await output.priorityControl()
        if mode == "ordering" {
            output.send(.configure(10, 0...30, false))
            let session = LDACOwnerSession(id: UUID(), output: output,
                configuration: .init(sampleRate: .hz44100, quality: .balanced), recoveryAttempt: false, restoringOnly: false) { _ in }
            session.start()
            session.stop(restoreAudio: false)
            output.endInput()
            while !output.ownerEnded { try await Task.sleep(for: .milliseconds(5)) }
            let result = await output.restoreAndRelease()
            precondition(result == nil)
            SwiftRecord("app-complete")
            return
        }
        if mode == "inherited" {
            let holder = try output.duplicateInput()
            SwiftRecord("holder \(holder.pid)")
        }
        let session = LDACOwnerSession(id: UUID(), output: output,
            configuration: .init(sampleRate: .hz96000, quality: .adaptive), recoveryAttempt: false, restoringOnly: false) { event in
            switch event {
            case .handoffReady: Task { try! await output.selectForHandoff(); active = true }
            case .active: break
            case .finished: completed = true
            default: break
            }
        }
        session.start()
        while !active { try await Task.sleep(for: .milliseconds(5)) }
        SwiftRecord("app-active")
        if mode == "parent-hung" {
            _ = Task { try await output.configure(volume: 10, range: 0...30) }
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        if mode == "delayed" || mode == "hung" {
            let pending = Task { try await output.configure(volume: 10, range: 0...30) }
            try await Task.sleep(for: .milliseconds(50))
            SwiftRecord("main-responsive")
            if mode == "delayed" { pending.cancel() }
            session.stop(restoreAudio: true)
            SwiftRecord("stop-admitted")
            do { try await pending.value; fatalError("Delayed request was admitted after cancellation or timeout") }
            catch is CancellationError { precondition(mode == "delayed") }
            catch {
                // A late configure is not fatal: the owner stays up and the stop already sent still completes (L12).
                precondition(mode == "hung" && error.localizedDescription == "The LDAC audio output did not respond in time.")
                precondition(!output.ownerEnded, "A late configure shut the owner down")
                SwiftRecord("configure-timed-out")
            }
        }
        if mode == "malformed" { try output.malformed() }
        if mode == "oversized" { try output.oversized() }
        if mode == "eof" { output.endInput() }
        if ["owner-crash", "malformed", "oversized", "eof", "owner-term"].contains(mode) {
            while !completed { try await Task.sleep(for: .milliseconds(5)) }
            while !output.ownerEnded { try await Task.sleep(for: .milliseconds(5)) }
            let error = await output.restoreAndRelease()
            precondition((error != nil) == (mode == "owner-crash"))
            SwiftRecord("app-complete")
            return
        }
        if ["crash", "inherited", "missing", "changed"].contains(mode) {
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        if mode != "delayed" && mode != "hung" { session.stop(restoreAudio: true) }
        while !completed { try await Task.sleep(for: .milliseconds(5)) }
        if mode == "gap" {
            SwiftRecord("app-gap")
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        precondition(await output.restoreAndRelease() == nil)
        if mode == "normal" {
            let second = LDACOwnerOutput(id: UUID(), address: "02:00:00:00:00:01") { _ in }
            try await second.claim(model: "second", targetAddress: "02:00:00:00:00:01", sampleRate: .hz88200)
            try await second.priorityControl()
            var secondActive = false
            var secondDone = false
            let secondSession = LDACOwnerSession(id: UUID(), output: second,
                configuration: .init(sampleRate: .hz88200, quality: .balanced), recoveryAttempt: false, restoringOnly: false) { event in
                switch event {
                case .handoffReady: Task { try! await second.selectForHandoff(); secondActive = true }
                case .active: break
                case .finished: secondDone = true
                default: break
                }
            }
            secondSession.start()
            while !secondActive { try await Task.sleep(for: .milliseconds(5)) }
            secondSession.stop(restoreAudio: true)
            while !secondDone { try await Task.sleep(for: .milliseconds(5)) }
            let result = await second.restoreAndRelease()
            precondition(result == nil)
            SwiftRecord("second-complete")
        }
        SwiftRecord("app-complete")
    }
}
'''
fixture = fixture.replace('__TYPES__', types).replace('__VOLUME__', volume).replace('__SELECTORS__', selectors)
fixture = fixture.replace('__RESTORATION__', restoration).replace('__EVENTS__', events).replace('__CHILD__', child).replace('__OWNER__', owner)
fixture = fixture.replace('timeout: TimeInterval = 10', 'timeout: TimeInterval = 0.2').replace('shutdownDeadline = .now() + 120', 'shutdownDeadline = .now() + 1').replace('asyncAfter(deadline: .now() + 120)', 'asyncAfter(deadline: .now() + 5)')
fixture = fixture.replace('precondition(await output.restoreAndRelease() == nil)', 'let result = await output.restoreAndRelease()\n        precondition(result == nil)')


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError('Fixture deadline expired')


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


with tempfile.TemporaryDirectory(prefix='acouplet-owner-check-') as temporary:
    directory = Path(temporary)
    swift = directory / 'Check.swift'
    binary = directory / 'check'
    swift.write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    rejected = subprocess.run([str(binary), '--ldac-owner'], capture_output=True, timeout=5)
    assert rejected.returncode != 0, 'A foreign parent invoked the signed owner entry point'
    print('PASS actual owner parent-signature check rejects direct foreign invocation')
    for mode in ['normal', 'crash', 'inherited', 'slow', 'early', 'cancel', 'dropped', 'claimed', 'missing', 'changed', 'gap', 'owner-crash', 'owner-term', 'malformed', 'oversized', 'eof', 'delayed', 'hung', 'parent-hung', 'ordering']:
        run = directory / ('run-' + mode + '-' + str(time.monotonic_ns()))
        run.mkdir()
        events = run / 'events'
        events.write_text('')
        environment = dict(os.environ, OWNER_MODE=mode, OWNER_CHECK=str(run))
        process = subprocess.Popen([str(binary)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        owner_pid = None
        helpers = []
        holder = None
        try:
            marker = 'owner-configure-start' if mode == 'parent-hung' else 'claim ' if mode == 'slow' else ('app-complete' if mode in ['early', 'cancel', 'dropped', 'ordering'] else 'app-claimed' if mode == 'claimed' else 'app-gap' if mode == 'gap' else 'app-active')
            wait_for(lambda: marker in events.read_text() or process.poll() is not None)
            assert process.poll() is None or mode in ['normal', 'early', 'cancel', 'dropped', 'delayed', 'malformed', 'oversized', 'eof', 'hung', 'ordering'], process.communicate(timeout=1)
            lines = events.read_text().splitlines()
            owner_pid = int(next(line.split()[1] for line in lines if line.startswith(('claim ', 'spawned '))))
            helpers = [int(line.split()[1]) for line in lines if line.startswith('child ')]
            if mode == 'inherited':
                holder = int(next(line.split()[1] for line in lines if line.startswith('holder ')))
            killed_at = time.monotonic()
            if mode == 'owner-crash':
                os.kill(owner_pid, signal.SIGKILL)
            elif mode == 'parent-hung':
                process.kill()
            elif mode == 'owner-term':
                os.kill(owner_pid, signal.SIGTERM)
            elif mode not in ['normal', 'early', 'cancel', 'dropped', 'malformed', 'oversized', 'eof', 'delayed', 'hung', 'parent-hung', 'ordering']:
                process.kill()
            transcript, diagnostics = process.communicate(timeout=8)
            if mode not in ['early', 'parent-hung']:
                try:
                    wait_for(lambda: (run / 'state').exists())
                except AssertionError:
                    raise AssertionError(mode + '\n' + events.read_text() + '\n' + diagnostics.decode() + '\n' + repr({'caller_exit': process.returncode, 'owner_alive': alive(owner_pid), 'helpers_alive': [pid for pid in helpers if alive(pid)]}))
            wait_for(lambda: not alive(owner_pid))
            if mode == 'inherited':
                assert time.monotonic() - killed_at < 1.5 and alive(holder), 'Owner waited for inherited pipe EOF'
                os.kill(holder, signal.SIGKILL)
                wait_for(lambda: not alive(holder))
            helpers = [int(line.split()[1]) for line in events.read_text().splitlines() if line.startswith('child ')]
            for helper in helpers:
                wait_for(lambda: not alive(helper))
            if mode == 'parent-hung':
                assert not (run / 'state').exists(), 'Forced owner termination claimed cooperative route restoration'
                print('PASS actual parent death with a blocked owner: independent watchdog ends worker and children; restoration remains unverified')
                continue
            if mode == 'early':
                assert 'claim ' not in events.read_text()
                print('PASS actual owner cancels startup before native claim and exits')
                continue
            state = json.loads((run / 'state').read_text())
            lines = events.read_text().splitlines()
            assert state['lease'] is False
            routes = list(state['routes'].values())
            assert 8 in routes, 'Independent system-sound choice was replaced'
            assert state['mutes'] == ([] if mode in ['slow', 'cancel', 'claimed', 'missing', 'changed', 'owner-crash', 'ordering'] else [6]), (mode, state, lines)
            assert (9 if mode == 'changed' else 5 if mode == 'missing' else 6) in routes
            if mode == 'hung':
                assert 'configure-timed-out' in lines and 'owner-recovery' not in lines, 'A late configure shut the owner down'
            if mode == 'owner-crash':
                assert 'owner-recovery' in lines
            elif helpers:
                assert lines.index('children-reaped') < lines.index('output restoring')
            if mode == 'normal':
                assert 'second-complete' in lines
                for line in lines:
                    if line.startswith('claim '):
                        assert not alive(int(line.split()[1]))
            if mode in ['delayed', 'hung']:
                assert lines.index('main-responsive') < lines.index('stop-admitted')
                assert lines.index('owner-configure-start') < lines.index('main-responsive')
                assert mode == 'hung' or lines.index('stop-admitted') < lines.index('owner-configure-end')
            if mode == 'ordering':
                start = next(i for i, line in enumerate(lines) if line.startswith('start '))
                assert lines.index('owner-configure-end') < start < lines.index('stop-intent false') < lines.index('children-reaped')
                assert 'native-restored' not in lines and 'owner-recovery' not in lines
            if mode == 'gap':
                assert 'native-restored-after-gap' in lines
            print('PASS actual owner process, channel and route restoration mode=' + mode)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for pid in [owner_pid, holder] + helpers:
                if pid is not None and alive(pid):
                    os.kill(pid, signal.SIGKILL)
