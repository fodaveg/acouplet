import pathlib
import subprocess
import tempfile


source = (pathlib.Path(__file__).resolve().parents[2] / "Sources/LDACNativeSession.swift").read_text()

fixture = r'''
enum PipeSetupCheck {
    nonisolated(unsafe) static var failureCall = 0
    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var spawnAttempts = 0
    nonisolated(unsafe) static var descriptors: [Int32] = []

    static func configure(_ descriptor: Int32, _ command: Int32, _ value: Int32) -> Int32 {
        calls += 1
        if calls == failureCall { errno = EPERM; return -1 }
        return Darwin.fcntl(descriptor, command, value)
    }
}

final class SessionClock: @unchecked Sendable {
    static let shared = SessionClock()
    private let lock = NSLock()
    private var elapsed: TimeInterval?
    private var wallOffset: TimeInterval = 0

    var monotonic: DispatchTime {
        lock.withLock {
            elapsed.map { DispatchTime(uptimeNanoseconds: UInt64((1_000 + $0) * 1_000_000_000)) } ?? .now()
        }
    }

    var wallTime: Date {
        lock.withLock {
            elapsed.map { Date(timeIntervalSince1970: 1_700_000_000 + $0 + wallOffset) } ?? Date()
        }
    }

    func set(elapsed: TimeInterval?, wallOffset: TimeInterval = 0) {
        lock.withLock {
            self.elapsed = elapsed
            self.wallOffset = wallOffset
        }
    }
}

struct ClosureCheckError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ClosureCheckError(description: message) }
}

func waitUntil(_ condition: () throws -> Bool) throws {
    for _ in 0..<600 {
        if try condition() { return }
        usleep(5_000)
    }
    throw ClosureCheckError(description: "Fixture did not finish within three seconds")
}

func cleanUp(_ children: [LDACNativeChild]) {
    for child in children { child.signal(SIGKILL) }
    for _ in 0..<600 {
        for child in children { child.reap() }
        if children.allSatisfy({ $0.status != nil }) { return }
        usleep(5_000)
    }
    fatalError("Fixture cleanup did not reap its children")
}

@MainActor
final class SessionEvents {
    var values: [LDACNativeSession.Event] = []

    var names: [String] {
        values.map {
            switch $0 {
            case .connectionLost: "connectionLost"
            case .failed: "failed"
            case .active: "active"
            case .formatChanged: "formatChanged"
            case .ldacEndpoint(let supported): supported ? "ldacEndpoint" : "noLDACEndpoint"
            default: "other"
            }
        }
    }
}

extension LDACNativeSession.Helpers {
    init(fixture: URL) {
        signaling = fixture
        media = fixture
        capture = fixture
        connection = fixture
        logger = URL(fileURLWithPath: "/usr/bin/log")
    }
}
extension LDACNativeSession {
    static func finishChildrenCheck(executable: URL) throws {
        for stubborn in [false, true] {
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01", helpers: Helpers(fixture: executable), gain: 0) { _ in }
            let child = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", stubborn ? "trap '' TERM; echo READY; while :; do :; done" : "echo READY; exec sleep 60"], inheritedPCM: nil)
            let deadline = DispatchTime.now() + 2
            var ready = false
            while !ready && DispatchTime.now() < deadline {
                ready = try child.readLines().contains("READY")
                if !ready { Thread.sleep(forTimeInterval: 0.01) }
            }
            precondition(ready)
            session.children["capture"] = child
            session.finish()
            precondition(child.status != nil && kill(child.pid, 0) == -1 && errno == ESRCH)
            precondition(!stubborn || session.failure != nil)
        }
        print("PASS actual session finish reaps remaining children, including a SIGTERM-resistant child")
    }
}
extension LDACNativeSession {
    static func checkRestoreArguments(executable: URL, handle: Int?) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01", helpers: Helpers(fixture: executable), gain: 0) { _ in }
        let disconnect = try LDACNativeChild(executable: executable, arguments: ["fixture-disconnect"], inheritedPCM: nil)
        session.children["disconnect"] = disconnect
        func drain(_ child: LDACNativeChild) throws -> [String] {
            var lines: [String] = []
            for _ in 0..<600 {
                lines += try child.readLines()
                child.reap()
                if child.finished { return lines }
                usleep(5_000)
            }
            child.signal(SIGKILL)
            child.wait()
            fatalError("fixture child did not finish")
        }
        _ = try drain(disconnect)
        session.connectorHandle = handle
        try session.beginRestore()
        let child = session.children["restore-disconnect"]!
        let lines = try drain(child)
        let arguments = lines.first { $0.hasPrefix("FIXTURE_ARGS ") }!
        if let handle {
            precondition(arguments.hasSuffix(" --expected-handle " + String(format: "%04X", handle)))
        } else {
            precondition(!arguments.contains("--expected-handle"))
        }
        for value in session.children.values { value.closeInput() }
        print("PASS actual session restore-disconnect argument binding handle=\(handle.map(String.init) ?? "none")")
    }

    /// L8: with the connector's handle stuck at 0000, bluetoothd's per-connection ACL lines are the ownership
    /// evidence. A later ACL line for the target means the current connection is someone else's.
    static func checkRestoreOwnership(executable: URL, laterACL: String?) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01", helpers: Helpers(fixture: executable), gain: 0) { _ in }
        let disconnect = try LDACNativeChild(executable: executable, arguments: ["fixture-disconnect"], inheritedPCM: nil)
        session.children["disconnect"] = disconnect
        let connector = try LDACNativeChild(executable: executable, arguments: ["fixture-disconnect"], inheritedPCM: nil)
        session.children["connector"] = connector
        session.stop(restoreAudio: true)
        try session.handle("daemon", line: "2026-10-15 05:47:14.255715+0200  localhost bluetoothd[459]: (CoreUtils) [com.apple.bluetooth:CBStackDeviceMonitor] ACL connected: 02:00:00:00:00:01, result 0")
        try require(session.connected, "The fixture did not observe the owned ACL")
        try session.handle("connector", line: "CONNECT_READY handle=0000 guarded=0")
        try require(session.connectorReady && session.connectorHandle == 0 && !session.connectorHandleGuarded,
            "An unusable connector handle was trusted as a connection guard")
        try session.handle("daemon", line: "2026-10-15 05:47:20.000000+0200  localhost bluetoothd[459]: (CoreUtils) [com.apple.bluetooth:CBStackDeviceMonitor] ACL connected: 02:00:00:00:00:09, result 0")
        if let laterACL {
            try session.handle("daemon", line: "2026-10-15 05:47:21.000000+0200  localhost bluetoothd[459]: (CoreUtils) [com.apple.bluetooth:CBStackDeviceMonitor] \(laterACL)")
        }
        for child in [disconnect, connector] {
            for _ in 0..<600 {
                _ = try child.readLines()
                child.reap()
                if child.finished { break }
                usleep(5_000)
            }
        }
        session.lock.withLock { session.recoveryRequested = true }
        try session.beginRestore()
        if laterACL == nil {
            try require(session.children["restore-disconnect"] != nil && !session.ownedACLEnded,
                "The session refused to disconnect its own ACL")
        } else {
            try require(session.children["restore-disconnect"] == nil && session.ownedACLEnded,
                "restore-disconnect targeted a connection that replaced the owned ACL")
        }
        for value in session.children.values { value.closeInput() }
        print("PASS actual session restore-disconnect ownership laterACL=\(laterACL ?? "none")")
    }
}

extension LDACNativeSession {
    static func preliveStopCheck(_ mode: String, executable: URL) throws {
        defer { SessionClock.shared.set(elapsed: nil) }
        SessionClock.shared.set(elapsed: 0)
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        let media = try LDACNativeChild(executable: executable, arguments: ["--prelive-media"], inheritedPCM: nil)
        let capture = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { cleanUp([media, capture]) }
        session.children["media"] = media
        session.children["capture"] = capture
        if mode == "recovering" { session.connectionLost("Fixture transport ended before playback") }
        else { session.stop(restoreAudio: false) }
        try session.advance()
        try require(session.mediaStopSent && !session.captureStopSent,
            "Capture stopped before pre-live media accepted shutdown")
        var receivedStop = false
        try waitUntil {
            for line in try media.readLines() {
                if line == "FIXTURE_STOP_RECEIVED" { receivedStop = true }
                try session.handle("media", line: line)
            }
            return receivedStop
        }
        try session.advance()
        capture.reap()
        try require(capture.status == nil && !session.captureStopSent && !session.hardFailure,
            "Sending stop was confused with the media helper acknowledging it")
        if mode == "missing-ack" {
            SessionClock.shared.set(elapsed: 5)
            try session.advance()
            try waitUntil {
                _ = try media.readLines()
                media.reap()
                return media.finished
            }
            try require(session.hardFailure, "Missing pre-live stop acknowledgment had no bounded failure")
        } else {
            try media.send("ack")
            try waitUntil {
                for line in try media.readLines() { try session.handle("media", line: line) }
                return session.mediaStopReady
            }
        }
        try session.advance()
        try waitUntil { capture.reap(); return capture.status != nil }
        try require(session.captureStopSent && capture.status.map { $0 & 0x7F } == SIGTERM,
            "Capture was not stopped after media accepted its EOF")
        try require(session.hardFailure == (mode == "missing-ack"), "Pre-live cancellation became a hard failure")
    }

    static func captureStartupSignalCheck(_ role: String, signal: Int32, executable: URL) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        try session.launch(role, executable: executable, arguments: [String(signal)])
        let child = session.children[role]!
        defer { cleanUp([child]) }
        child.signal(signal)
        var masked = false
        try waitUntil {
            for line in try child.readLines() { masked = masked || line == "FIXTURE_MASK INT=1 TERM=1" }
            child.reap()
            return masked || child.finished
        }
        try require(masked && child.status == nil, "The capture helper could terminate before installing its signal handlers")
        try child.send("install")
        var handled = false
        try waitUntil {
            for line in try child.readLines() { handled = handled || line == "FIXTURE_HANDLED signal=\(signal)" }
            child.reap()
            return child.finished
        }
        try require(handled && child.exitCode == 0, "The blocked stop signal was not delivered after installing the production handlers")
    }

    static func clockJumpCheck(_ wallOffset: TimeInterval, logURL: URL) throws {
        defer { SessionClock.shared.set(elapsed: nil) }
        SessionClock.shared.set(elapsed: 0)
        let media = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { cleanUp([media]) }
        let stopping = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0,
            priority: LDACPriorityControl(request: { _, _ in }, state: { .init(phase: "idle", error: nil) }), receive: { _ in })
        stopping.children["media"] = media
        stopping.started = true
        stopping.stop(restoreAudio: false)
        try stopping.advance()
        try require(stopping.mediaStopSent && stopping.mediaStopDeadline == SessionClock.shared.monotonic + 5,
            "Media shutdown did not arm its five-second deadline")

        let checking = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        checking.verifyConnectionLoss(reason: "Fixture priority observation")
        try checking.advance()
        try require(checking.priorityObservationDeadline == SessionClock.shared.monotonic + 5 && checking.failure == nil,
            "Priority observation did not start a five-second verification")

        SessionClock.shared.set(elapsed: 4.9, wallOffset: wallOffset)
        try stopping.advance()
        try checking.advance()
        media.reap()
        try require(media.status == nil && stopping.mediaStopDeadline != .distantFuture,
            "A calendar-clock jump ended media before five elapsed seconds")
        try require(checking.failure == nil, "A calendar-clock jump prematurely failed priority verification")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        checking.log = try FileHandle(forWritingTo: logURL)
        checking.record("CLOCK_FIXTURE")
        try checking.log?.close()
        checking.log = nil
        try require(String(contentsOf: logURL, encoding: .utf8).hasPrefix("\(SessionClock.shared.wallTime.timeIntervalSince1970) CLOCK_FIXTURE\n"),
            "Diagnostic timestamps no longer follow calendar time")

        SessionClock.shared.set(elapsed: 5, wallOffset: wallOffset)
        try stopping.advance()
        try checking.advance()
        try waitUntil { media.reap(); return media.status != nil }
        try require(media.status.map { $0 & 0x7F } == SIGKILL && stopping.mediaStopDeadline == .distantFuture,
            "A calendar-clock jump delayed media shutdown beyond five elapsed seconds")
        try require(checking.failure != nil && checking.priorityObservation == nil,
            "A calendar-clock jump delayed priority verification beyond five elapsed seconds")
    }

    @MainActor
    static func loggerAuthorizationCheck() async throws {
        for source in ["daemon", "probe", "media"] {
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(bundle: .main), gain: 0, receive: { events.values.append($0) })
            try session.handle(source, line: "log: Must be admin to run 'stream' command")
            if source == "daemon" {
                session.fail("Bluetooth logging ended before LDAC was stopped.")
                session.finish()
            }
            for _ in 0..<100 { await Task.yield() }
            let messages = events.values.compactMap { event -> String? in
                switch event {
                case .failed(let message): message
                case .finished(let completion): completion.message
                default: nil
                }
            }
            let expected = source == "daemon" ? Array(repeating: "LDAC requires a macOS administrator account.", count: 2) : []
            try require(messages == expected, "Logger authorization failure was misattributed or replaced by a retry message")
        }
    }

    @MainActor
    static func failurePresentationCheck(logURL: URL) async throws {
        let raw = "PCM_FAILED helper=probe reason=nonfinite sourceSamples=128"
        for (mode, expected) in [
            ("setup", "LDAC could not start. Try again."),
            ("active", "LDAC playback stopped unexpectedly. Try again."),
            ("stopping", "LDAC did not stop completely."),
            ("restoring", "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings."),
            ("restored", "LDAC did not stop completely."),
            ("restore-preparation", "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings."),
        ] {
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(bundle: .main), gain: 1, receive: { events.values.append($0) })
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            session.log = try FileHandle(forWritingTo: logURL)
            session.active = mode == "active"
            session.requestedStop = mode == "stopping"
            session.restoring = mode == "restoring" || mode == "restored"
            session.nativeAudioRestored = mode == "restored"
            if mode == "restore-preparation" {
                session.requestedStop = true
                session.fail(raw, userMessage: "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings.")
            } else {
                session.fail(raw)
            }
            session.finish()
            try session.log?.close()
            session.log = nil
            for _ in 0..<100 { await Task.yield() }
            let messages = events.values.compactMap { event -> String? in
                switch event {
                case .failed(let message): message
                case .finished(let completion): completion.message
                default: nil
                }
            }
            try require(messages == [expected, expected], "Internal failure reached public events in \(mode): \(messages)")
            try require(session.failure == raw, "Failure presentation changed internal failure state")
            try require(String(contentsOf: logURL, encoding: .utf8).contains(raw), "Failure detail was lost from diagnostics")
        }
        let events = SessionEvents()
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1, receive: { events.values.append($0) })
        session.capturePermissionDenied()
        session.finish()
        for _ in 0..<100 { await Task.yield() }
        let messages = events.values.compactMap { event -> String? in
            switch event {
            case .failed(let message): message
            case .finished(let completion): completion.message
            default: nil
            }
        }
        try require(messages == [LDACAudioCaptureAccess.permissionGuidance, LDACAudioCaptureAccess.permissionGuidance],
            "Permission instructions were replaced by a generic failure")
    }

    @MainActor
    static func captureCancellationCheck(_ mode: String, executable: URL) async throws {
        let events = SessionEvents()
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { events.values.append($0) })
        let preflight = mode.hasPrefix("permission-")
        let recovering = mode == "capture-recovery"
        let clean = ["permission-term", "permission-int", "capture-cancel", "capture-recovery"].contains(mode)
        if recovering { session.connectionLost("Fixture connection closed before playback") }
        else { session.stop(restoreAudio: false) }
        let signal = mode == "permission-int" ? SIGINT : mode == "permission-unknown-signal" ? 1 : SIGTERM
        let cleanup = mode == "permission-cleanup-failed" ? 0 : 1
        let error = mode == "permission-capture-failed" ? 5 : 0
        let line: String
        if preflight {
            line = "AUDIO_PERMISSION_FAILED cleanup=\(cleanup) callbacks=0 error=\(error) interrupted=\(signal)"
        } else {
            let destroyed = mode == "capture-no-destruction" ? "DESTROY_TAP status=1" : "DESTROY_TAP status=0"
            let cancelled = mode == "capture-unclassified" ? "CAPTURE error=0 interrupted=15"
                : mode == "capture-cleanup-failed" ? "PCM_CAPTURE_CANCELLED cleanup=0 error=0 interrupted=15"
                : "PCM_CAPTURE_CANCELLED cleanup=1 error=0 interrupted=15"
            line = destroyed + "\n" + cancelled
        }
        let child = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", "exit", line, "", "1"], inheritedPCM: nil)
        defer { cleanUp([child]) }
        let name = preflight ? "preflight" : "capture"
        session.children[name] = child
        try waitUntil {
            for line in try child.readLines() { try session.handle(name, line: line) }
            child.reap()
            return child.finished
        }
        try session.advance()
        if session.canRestore { try session.beginRestore() }
        else { session.finish() }
        for _ in 0..<100 { await Task.yield() }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Cancellation did not publish completion: \(mode)")
        }
        try require(session.hardFailure != clean, "Cancellation cleanup was classified incorrectly: \(mode)")
        try require((completion.message == nil) == (clean && !recovering), "Cancellation retained the wrong failure: \(mode)")
        try require(completion.canRetry == recovering, "Clean interrupted capture blocked recovery: \(mode)")
        try require(events.names.contains("failed") != clean, "Cancellation emitted the wrong failure event: \(mode)")
    }

    @MainActor
    private static func lossSession(active: Bool, events: SessionEvents) throws -> LDACNativeSession {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1,
            configuration: LDACConfiguration(quality: .adaptive), receive: { events.values.append($0) })
        session.active = active
        session.started = true
        session.readySent = true
        session.captureReady = true
        session.pcmReady = true
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            var gate = LDACChannelGate()
            try gate.owned("OWNED_CHANNEL CID=\(cid)")
            try gate.daemon("connectedCB cid:0x\(cid) inMTU:1000 outMTU:1000 result:0")
            if name == "probe" { session.signalingGate = gate }
            else { session.mediaGate = gate }
        }
        return session
    }

    @MainActor
    static func probeFailureCheck(_ line: String, source: String, active: Bool, stopping: Bool) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: active, events: events)
        if stopping { session.stop(restoreAudio: false) }
        try session.handle(source, line: line)
        let rejected = source == "probe" && !stopping
        let unavailable = line == "LDAC_UNAVAILABLE rate=48000 channels=2"
        let recoverable = rejected && active && !unavailable
        try require((session.failure != nil) == rejected, "Probe diagnostic did not immediately set failure for its live owner")
        try require(session.shouldStop == (rejected || stopping), "Probe diagnostic did not revoke live ownership")
        try require(session.recoverableFailure == recoverable && session.recoveryRequested == recoverable,
            "Probe recovery classification did not match admitted playback")
        try require(session.hardFailure == (rejected && !recoverable), "Probe setup failure was not distinct from active connection loss")
        try require(!session.mediaCloseRequired && !session.mediaCloseSent && !session.finalized,
            "Probe diagnostic bypassed orderly protocol cleanup")
        if rejected {
            let message = unavailable ? "The headphones did not offer a compatible LDAC stream. Check their audio settings, then retry."
                : active ? "The LDAC Bluetooth connection ended."
                : "The LDAC audio connection could not finish setup. Try LDAC again."
            try require(session.failure == message, "Probe failure did not use the intended user-facing explanation")
            try session.handle("probe", line: "PEER_COMMAND_UNSUPPORTED")
            try session.handle("probe", line: "CONTROL_FAILED expected=media-finished closed=0")
            try session.handle("probe", line: "PREPARE_MEDIA")
            try session.handle("probe", line: "START_ACCEPTED signalingCID=0040 mediaCID=0041")
            if !active {
                try session.handle("media", line: "LIVE_SENT packets=1 rate=48000 channels=2 bitrateKbps=330 eqmid=2")
            }
            try session.handle("media", line: "LIVE_FORMAT rate=48000 channels=2 bitrateKbps=330 frameBytes=110")
            try session.advance()
            try require(session.children.isEmpty && !session.mediaCloseRequired && !session.finalized,
                "Late readiness restarted helpers or bypassed protocol cleanup")
            try session.handle("probe", line: "MEDIA_CLOSE_REQUIRED CID=0041")
            try session.handle("probe", line: "STREAM_CLOSED cleanupSignal=08")
            try require(session.mediaCloseRequired, "Real closure marker did not advance cleanup")
        }
        for _ in 0..<100 { await Task.yield() }
        if unavailable && rejected {
            let message = events.values.compactMap { event -> String? in
                if case .failed(let message) = event { return message }
                return nil
            }.first
            try require(message == session.failure, "LDAC availability instructions were replaced by a generic failure")
        }
        // LDAC_UNAVAILABLE without a listed LDAC endpoint also reports that no endpoint exists.
        let expected = (unavailable && rejected ? ["noLDACEndpoint"] : []) + (rejected ? [recoverable ? "connectionLost" : "failed"] : [])
        try require(events.names == expected,
            "Probe events were missing, duplicated, or reactivated playback: \(events.names)")
    }

    @MainActor
    static func mediaFailureCheck(_ mode: String) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: !["setup", "closed-before-active"].contains(mode), events: events)
        if mode == "stopping" { session.stop(restoreAudio: false) }
        let closed = "FEED_COMPLETE result=5 strictPass=0 sentPackets=1 drainedPackets=1 closed=1"
        let daemon = "l2capDisconnected for CID: 0x0041"
        let encoder = "ENCODER_FAILED reason=packet-boundary bytes=700 outgoingMTU=679 baseline=1000"
        var lines: [(String, String)]
        switch mode {
        case "media-first": lines = [("media", closed), ("daemon", daemon)]
        case "daemon-first": lines = [("daemon", daemon), ("media", closed)]
        case "daemon-then-encoder": lines = [("daemon", daemon), ("media", encoder), ("media", closed)]
        case "closed-before-active": lines = [("media", closed)]
        case "encoder-first": lines = [("media", encoder), ("media", closed), ("daemon", daemon)]
        case "closure-first": lines = [("media", closed), ("media", encoder), ("daemon", daemon)]
        case "pcm-error": lines = [("media", "PCM_FAILED reason=nonfinite sourceSamples=128 gain=1"), ("media", closed)]
        case "open-error": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 sentPackets=1 closed=0")]
        case "unknown-error": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 sentPackets=1")]
        case "setup": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 reason=invalid-start-or-prefill sentPackets=0")]
        case "stopping": lines = [("media", "FEED_COMPLETE result=0 strictPass=1 sentPackets=1 closed=0")]
        default: throw ClosureCheckError(description: "Unknown media fixture")
        }
        for (source, line) in lines {
            do { try session.handle(source, line: line) }
            catch { session.fail(error.localizedDescription) }
            if line == encoder { try require(session.hardFailure, "Encoder diagnostic did not immediately retain hard failure") }
        }
        let recoverable = ["media-first", "daemon-first", "closure-first", "daemon-then-encoder"].contains(mode)
        let hard = !["media-first", "daemon-first", "stopping"].contains(mode)
        try require(session.feedFinished && session.shouldStop, "Media completion did not enter shutdown")
        try require(session.recoverableFailure == recoverable && session.hardFailure == hard,
            "Media closure/error classification depended on child output order: \(mode)")
        try require(!session.mediaCloseRequired && !session.mediaCloseSent, "Media diagnostic bypassed signaling cleanup")
        if recoverable {
            try session.handle("media", line: closed)
        }
        for _ in 0..<100 { await Task.yield() }
        let expected = mode == "stopping" ? [] : ["closure-first", "daemon-then-encoder"].contains(mode) ? ["connectionLost", "failed"]
            : [hard ? "failed" : "connectionLost"]
        try require(events.names == expected, "Media failure emitted incorrect or repeated events: \(events.names)")
    }

    @MainActor
    static func recoveryExitCheck(_ mode: String, executable: URL, raw: URL) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: mode != "unclassified" && mode != "requested-stop-before-active", events: events)
        session.rawURL = raw
        if mode == "unclassified" || mode.hasPrefix("requested-stop") { session.stop(restoreAudio: false) }
        else { try session.handle("probe", line: "STREAM_CLOSED peerSignal=08") }
        if mode == "requested-stop-before-active" {
            try session.handle("probe", line: "STOP_COMPLETE protocolCleanup=1")
        }
        session.originalConnectionEnded = mode == "acl-first"
        if mode == "restore-disconnected" || mode == "forced-disconnect" || mode == "native-replaced" {
            try session.handle("restore-disconnect", line: "BEFORE time=1791160325.072411 address=02-00-00-00-00-01 paired=1 connected=\(mode == "forced-disconnect" ? 1 : 0)")
            try session.handle("restore-disconnect", line: "RESTORE_DISCONNECTED disconnected=1")
        }
        session.nativeAudioRestored = mode == "native-replaced"
        if mode == "encoder-error" || mode == "requested-stop-encoder-error" {
            try session.handle("media", line: "ENCODER_FAILED reason=packet-boundary")
        }
        if mode.hasPrefix("requested-stop-cleanup") {
            session.priorityCleanupFailed("Target publication was lost; confirm the old Bluetooth connection is disconnected.")
            if mode == "requested-stop-cleanup-recovered" { session.priorityPhase = .removed }
        }
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            if !["missing-closure", "requested-stop-missing-closure"].contains(mode) || name != "media" {
                try session.handle("daemon", line: "l2capDisconnected for CID: 0x\(cid)")
            }
            session.children[name] = try LDACNativeChild(executable: executable,
                arguments: ["--fixture", "exit", "FIXTURE_EXIT", "", mode == "unexpected-exit" && name == "probe" ? "6" : "5"],
                inheritedPCM: nil)
        }
        defer { cleanUp(Array(session.children.values)) }
        try waitUntil {
            for (name, child) in session.children {
                for line in try child.readLines() { try session.handle(name, line: line) }
                child.reap()
            }
            return session.children.values.allSatisfy(\.finished)
        }
        try require(session.canRestore, "Recovery did not wait for transport children to finish")
        try session.beginRestore()
        for _ in 0..<100 { await Task.yield() }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Recovery did not publish its completion")
        }
        let safe = ["channels-first", "acl-first", "restore-disconnected", "forced-disconnect"].contains(mode)
        let clean = safe || ["requested-stop", "requested-stop-before-active", "requested-stop-cleanup-recovered", "native-replaced"].contains(mode)
        try require(completion.canRetry == safe, "Recovery accepted an unsafe exit or rejected verified closure: \(mode)")
        try require(completion.requiresAttention == !safe, "Recovery reported the wrong attention requirement: \(mode)")
        try require(completion.targetDisconnected == ["acl-first", "restore-disconnected", "forced-disconnect"].contains(mode),
            "Channel closure was confused with confirmed target disconnection: \(mode)")
        try require(completion.waitForReconnect == ["acl-first", "restore-disconnected"].contains(mode),
            "A deliberate recovery disconnection was confused with an unavailable peer: \(mode)")
        try require(events.names.filter { $0 == "failed" }.isEmpty == clean,
            "Expected connection loss was promoted to a transport error: \(mode)")
        if clean && mode.hasPrefix("requested-stop") {
            try require(completion.message == nil, "Confirmed requested shutdown retained a transient cleanup warning")
        }
    }

    static func closureCheck(_ site: String, mode: String, fault: String, executable: URL, raw: URL) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1, receive: { _ in })
        session.stop(restoreAudio: false)
        session.signalingStopSent = true
        session.mediaCloseSent = true
        session.mediaStopSent = true
        session.rawURL = raw
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            var gate = LDACChannelGate()
            try gate.owned("OWNED_CHANNEL CID=\(cid)")
            try gate.daemon("connectedCB cid:0x\(cid) inMTU:672 outMTU:672 result:0")
            if fault != "missing-closure" || name != (site == "media-transport" ? "media" : "probe") {
                try gate.daemon("l2capDisconnected for CID: 0x\(cid)")
            }
            if name == "probe" { session.signalingGate = gate }
            else { session.mediaGate = gate }
        }
        let name = site == "media-transport" ? "media" : "probe"
        let other = name == "media" ? "probe" : "media"
        let command = site == "media-closed" ? "media-closed" : "transport-closed"
        let waiting = site == "media-closed" ? "WAIT_MEDIA_CLOSED" : "WAIT_TRANSPORT_CLOSED CID=\(name == "media" ? "0041" : "0040")"
        var control: [Int32] = [-1, -1]
        if mode == "broken" {
            try require(pipe(&control) == 0, "Control pipe could not be created")
        }
        defer {
            for descriptor in control where descriptor >= 0 { Darwin.close(descriptor) }
        }
        let child = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", mode, waiting, command, fault == "failed-exit" ? "5" : "0"],
            inheritedPCM: mode == "broken" ? control[0] : nil)
        defer { cleanUp([child]) }
        if control[0] >= 0 { Darwin.close(control[0]); control[0] = -1 }
        let companion = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", "exit", "FIXTURE_EXIT", "", "0"], inheritedPCM: nil)
        defer { cleanUp([companion]) }
        session.children[name] = child
        session.children[other] = companion
        var sawWaiting = false
        func drain() throws {
            for (helper, process) in [(name, child), (other, companion)] {
                for line in try process.readLines() {
                    if helper == name && line == waiting { sawWaiting = true }
                    try session.handle(helper, line: line)
                }
                process.reap()
            }
        }
        try waitUntil {
            try drain()
            return sawWaiting && companion.finished && (mode != "exit" || child.finished)
        }
        if fault == "missing-recipient" || fault == "bad-descriptor" {
            if fault == "missing-recipient" { session.children.removeValue(forKey: name) }
            else { child.closeInput() }
            var rejected = false
            do { try session.advance() }
            catch {
                rejected = true
                if fault == "bad-descriptor" {
                    try require((error as? POSIXError)?.code == .EBADF, "Terminal write did not preserve EBADF")
                } else {
                    try require(error is LDACSessionError, "Missing recipient did not report a session error")
                }
            }
            try require(rejected, "Terminal acknowledgment accepted \(fault)")
            return
        }
        if fault == "nonterminal" {
            var rejected = false
            do { try session.send(name, "stop") }
            catch {
                rejected = true
                if mode == "broken" {
                    try require((error as? POSIXError)?.code == .EPIPE, "Nonterminal write did not report EPIPE")
                }
            }
            try require(rejected, "Nonterminal send accepted a closed helper input")
            return
        }
        if fault == "hung" { session.ownerExitDeadline = DispatchTime(uptimeNanoseconds: 0) }
        do { try session.advance() }
        catch { session.fail(error.localizedDescription) }
        if fault == "hung" {
            try require(session.hardFailure && session.ownerInputsClosed && !session.canRestore,
                "Shutdown deadline did not reject a live owner")
        } else {
            try require(session.failure == nil && !session.hardFailure,
                "Terminal acknowledgment failed: \(session.failure ?? "unknown")")
        }
        if fault == "none" {
            let sent = site == "media-transport" ? session.mediaTransportClosedSent :
                site == "media-closed" ? session.mediaClosedSent : session.signalingClosedSent
            try require(sent == (mode == "read"), "Terminal acknowledgment delivery was recorded incorrectly")
        }
        if mode == "broken" {
            child.reap()
            try require(child.status == nil && !child.finished && !session.canRestore,
                "Broken input was treated as a completed child exit")
            var release: UInt8 = 1
            try require(Darwin.write(control[1], &release, 1) == 1, "Fixture could not be released")
            try waitUntil {
                child.reap()
                return child.status != nil
            }
            try require(!child.outputEnded && !session.canRestore,
                "A reaped child bypassed its output EOF requirement")
        }
        try waitUntil {
            try drain()
            return child.finished && companion.finished
        }
        try require(session.canRestore, "Exited children did not reach shutdown verification")
        try session.beginRestore()
        try require(session.finalized, "Shutdown verification did not finish")
        if ["missing-closure", "failed-exit", "hung"].contains(fault) {
            try require(session.failure != nil && session.hardFailure,
                "Shutdown verification accepted \(fault)")
            if fault == "missing-closure" {
                try require(session.shutdownUnverified, "Missing channel closure was not recorded")
            }
        } else {
            try require(session.failure == nil && !session.hardFailure && !session.shutdownUnverified,
                "Verified shutdown was rejected: \(session.failure ?? "unknown")")
        }
    }
}

@main
enum LDACSessionClosureCheck {
    static func child() -> Never {
        let arguments = CommandLine.arguments
        let mode = arguments[2]
        if mode == "broken" { Darwin.close(STDIN_FILENO) }
        let data = Data((arguments[3] + "\n").utf8)
        let sent = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, data.count) }
        if sent != data.count { exit(90) }
        if mode == "broken" {
            var release: UInt8 = 0
            if Darwin.read(3, &release, 1) != 1 { exit(91) }
        } else if mode == "read" {
            if readLine() != arguments[4] { exit(92) }
        }
        exit(Int32(arguments[5])!)
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--address" || CommandLine.arguments.dropFirst().first == "fixture-disconnect" {
            print("FIXTURE_ARGS " + CommandLine.arguments.dropFirst().joined(separator: " "))
            return
        }
        if CommandLine.arguments.dropFirst().first == "--prelive-media" {
            guard readLine() == "stop" else { exit(93) }
            print("FIXTURE_STOP_RECEIVED")
            fflush(stdout)
            guard readLine() == "ack" else { exit(94) }
            print("PCM_STOP_READY started=0")
            fflush(stdout)
            _ = readLine()
            exit(0)
        }
        if CommandLine.arguments.dropFirst().first == "--fixture" { child() }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        for handle in [nil, 0, 1] as [Int?] {
            try LDACNativeSession.checkRestoreArguments(executable: executable, handle: handle)
        }
        for laterACL in [nil, "ACL disconnected: 02:00:00:00:00:01, result 0, reason 10722", "ACL connected: 02:00:00:00:00:01, result 0"] {
            try LDACNativeSession.checkRestoreOwnership(executable: executable, laterACL: laterACL)
        }
        for failure in 1...3 {
            PipeSetupCheck.failureCall = failure
            PipeSetupCheck.calls = 0
            PipeSetupCheck.spawnAttempts = 0
            var rejected = false
            do {
                let child = try LDACNativeChild(executable: executable,
                    arguments: ["--fixture", "exit", "UNEXPECTED_CHILD", "", "0"], inheritedPCM: nil)
                cleanUp([child])
            } catch let error as POSIXError {
                rejected = true
                try require(error.code == .EPERM, "Pipe setup did not preserve its failure")
            }
            try require(rejected && PipeSetupCheck.spawnAttempts == 0,
                "Failed pipe setup launched a helper")
            try require(PipeSetupCheck.descriptors.count == 4, "Pipe setup did not capture every descriptor")
            for descriptor in PipeSetupCheck.descriptors {
                try require(Darwin.fcntl(descriptor, F_GETFD) == -1 && errno == EBADF,
                    "Failed pipe setup leaked a descriptor")
            }
            print("PASS pipe setup failure=\(failure): descriptors closed without spawning a helper")
        }
        PipeSetupCheck.failureCall = 0
        let signalingInput = try LDACNativeChild(executable: URL(fileURLWithPath: CommandLine.arguments[2]),
            arguments: [], inheritedPCM: nil)
        defer { cleanUp([signalingInput]) }
        var signalingLines: [String] = []
        try waitUntil {
            signalingLines += try signalingInput.readLines()
            signalingInput.reap()
            return signalingInput.finished
        }
        try require(signalingInput.exitCode == 0 && signalingLines.contains("FIXTURE_RX_INTACT length=4096"),
            "Signaling diagnostics modified the received protocol data")
        let dumps = signalingLines.filter { $0.hasPrefix("RX ") }
        try require(dumps.count == 1 && dumps[0].contains("length=4096 bytes=") && dumps[0].hasSuffix(" ...")
            && dumps[0].utf8.count < 1024, "Signaling diagnostic exceeded its bounded preview")
        print("PASS 4096-byte signaling input: complete protocol data and bounded parent-readable diagnostic")
        let raw = executable.deletingLastPathComponent().appendingPathComponent("signaling.bin")
        try Data().write(to: raw)
        try LDACNativeSession.finishChildrenCheck(executable: executable)
        try await LDACNativeSession.loggerAuthorizationCheck()
        print("PASS logger authorization failure retains its account requirement")
        for role in ["preflight", "capture"] {
            for signal in [SIGINT, SIGTERM] {
                try LDACNativeSession.captureStartupSignalCheck(role, signal: signal,
                    executable: URL(fileURLWithPath: CommandLine.arguments[1]))
                print("PASS capture startup signal role=\(role) signal=\(signal)")
            }
        }
        for mode in ["stopping", "recovering", "missing-ack"] {
            try LDACNativeSession.preliveStopCheck(mode, executable: executable)
            print("PASS pre-live capture stop ordering mode=\(mode)")
        }
        for offset: TimeInterval in [-86_400, 86_400] {
            try LDACNativeSession.clockJumpCheck(offset, logURL: raw.deletingLastPathComponent().appendingPathComponent("clock.log"))
            print("PASS clock jump seconds=\(offset): operation and shutdown deadlines use elapsed time; logs retain calendar time")
        }
        try await LDACNativeSession.failurePresentationCheck(logURL: raw.deletingLastPathComponent().appendingPathComponent("errors.log"))
        print("PASS LDAC failure presentation preserves diagnostics and actionable permission/availability messages")
        for mode in ["permission-term", "permission-int", "permission-unknown-signal", "permission-cleanup-failed", "permission-capture-failed",
                     "capture-cancel", "capture-recovery", "capture-unclassified", "capture-cleanup-failed", "capture-no-destruction"] {
            try await LDACNativeSession.captureCancellationCheck(mode, executable: executable)
            print("PASS capture cancellation mode=\(mode)")
        }
        var failures = 0
        for site in ["media-transport", "media-closed", "signaling-transport"] {
            for (mode, fault) in [("exit", "none"), ("broken", "none"), ("read", "none"),
                                  ("exit", "missing-closure"), ("exit", "failed-exit"),
                                  ("broken", "hung"), ("exit", "nonterminal"), ("broken", "nonterminal"),
                                  ("exit", "missing-recipient"), ("broken", "bad-descriptor")] {
                do {
                    try LDACNativeSession.closureCheck(site, mode: mode, fault: fault, executable: executable, raw: raw)
                    print("PASS \(site) mode=\(mode) fault=\(fault)")
                } catch {
                    failures += 1
                    print("FAIL \(site) mode=\(mode) fault=\(fault): \(error)")
                }
            }
        }
        print("Actual LDAC session shutdown checks: \(30 - failures)/30 passed; local fixture children only")
        let closureFailures = failures
        var ownershipChecks = 0
        for line in ["PEER_COMMAND_UNSUPPORTED", "CONTROL_FAILED expected=media-finished closed=0", "LDAC_UNAVAILABLE rate=48000 channels=2"] {
            for source in ["probe", "media", "daemon"] {
                for active in [false, true] {
                    for stopping in [false, true] {
                        ownershipChecks += 1
                        do {
                            try await LDACNativeSession.probeFailureCheck(line, source: source, active: active, stopping: stopping)
                            print("PASS probe diagnostic=\(line) source=\(source) active=\(active) stopping=\(stopping)")
                        } catch {
                            failures += 1
                            print("FAIL probe source=\(source) active=\(active) stopping=\(stopping): \(error)")
                        }
                    }
                }
            }
        }
        for mode in ["media-first", "daemon-first", "encoder-first", "closure-first", "daemon-then-encoder",
                     "pcm-error", "open-error", "unknown-error", "setup", "closed-before-active", "stopping"] {
            ownershipChecks += 1
            do {
                try await LDACNativeSession.mediaFailureCheck(mode)
                print("PASS media ownership mode=\(mode)")
            } catch {
                failures += 1
                print("FAIL media ownership mode=\(mode): \(error)")
            }
        }
        for mode in ["channels-first", "acl-first", "restore-disconnected", "forced-disconnect", "native-replaced", "unexpected-exit",
                     "missing-closure", "encoder-error", "unclassified", "requested-stop", "requested-stop-before-active",
                     "requested-stop-encoder-error", "requested-stop-missing-closure", "requested-stop-cleanup-recovered",
                     "requested-stop-cleanup-pending"] {
            ownershipChecks += 1
            do {
                try await LDACNativeSession.recoveryExitCheck(mode, executable: executable, raw: raw)
                print("PASS recovery exit mode=\(mode)")
            } catch {
                failures += 1
                print("FAIL recovery exit mode=\(mode): \(error)")
            }
        }
        print("Actual LDAC session ownership checks: \(ownershipChecks - failures + closureFailures)/\(ownershipChecks) passed; protocol input only")
        if failures > 0 { exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-session-closure-") as directory:
    directory = pathlib.Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    timed_source = source.replace("DispatchTime.now()", "SessionClock.shared.monotonic").replace("Date()", "SessionClock.shared.wallTime")
    timed_source = timed_source.replace("        guard fcntl(incoming[1]", "        PipeSetupCheck.descriptors = incoming + outgoing\n        guard fcntl(incoming[1]")
    timed_source = timed_source.replace("fcntl(", "PipeSetupCheck.configure(")
    timed_source = timed_source.replace("        let result = posix_spawn(", "        PipeSetupCheck.spawnAttempts += 1\n        let result = posix_spawn(")
    swift.write_text(timed_source + fixture)
    capture_source = (pathlib.Path(__file__).parent / "SystemAudioTapProbe.m").read_text()
    handler = capture_source[capture_source.index("static void Interrupt(int value)"):capture_source.index("static double MonotonicTime")]
    unblock = capture_source[capture_source.index("            signal(SIGINT, Interrupt);"):capture_source.index("            if (streaming || checkingPermission) signal(SIGPIPE, SIG_IGN);")]
    signal_source = directory / "Signals.c"
    signal_binary = directory / "signals"
    signal_source.write_text('''#include <signal.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static volatile sig_atomic_t interrupted;
''' + handler + '''int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    sigset_t inherited;
    pthread_sigmask(SIG_BLOCK, NULL, &inherited);
    printf("FIXTURE_MASK INT=%d TERM=%d\\n", sigismember(&inherited, SIGINT), sigismember(&inherited, SIGTERM));
    char command[32];
    if (!fgets(command, sizeof(command), stdin)) return 1;
''' + unblock + '''
    printf("FIXTURE_HANDLED signal=%d\\n", interrupted);
    return argc == 2 && interrupted == atoi(argv[1]) ? 0 : 2;
}
''')
    subprocess.run(["xcrun", "clang", str(signal_source), "-o", str(signal_binary)], check=True)
    signaling_source = (pathlib.Path(__file__).parent / "DirectAVDTPSustainedPlaybackProbe.m").read_text()
    poll = signaling_source[signaling_source.index("@implementation DirectPlaybackProbe"):signaling_source.index("\n@end", signaling_source.index("@implementation DirectPlaybackProbe")) + len("\n@end")]
    signaling_fixture = directory / "SignalingInput.m"
    signaling_binary = directory / "signaling-input"
    signaling_fixture.write_text('''#import <Foundation/Foundation.h>
@interface DirectPlaybackProbe : NSObject
@property BOOL closed, failed, closing, inputEnded;
@property(strong) NSInputStream *input;
@property(strong) NSObject *channel;
@property(strong) NSMutableData *pending, *raw;
@property NSUInteger received;
- (void)pollInput;
@end
''' + poll + '''
int main(void) {
    @autoreleasepool {
        NSMutableData *expected = [NSMutableData dataWithLength:4096];
        uint8_t *bytes = expected.mutableBytes;
        for (NSUInteger i = 0; i < expected.length; i++) bytes[i] = (uint8_t)i;
        DirectPlaybackProbe *probe = [DirectPlaybackProbe new];
        probe.pending = [NSMutableData data];
        probe.raw = [NSMutableData data];
        probe.closing = YES;
        probe.input = [NSInputStream inputStreamWithData:expected];
        [probe.input open];
        [probe pollInput];
        [probe.input close];
        if (![probe.pending isEqualToData:expected] || ![probe.raw isEqualToData:expected] || probe.received != 4096) return 1;
        puts("FIXTURE_RX_INTACT length=4096");
    }
    return 0;
}
''')
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(signaling_fixture), "-o", str(signaling_binary)], check=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(signal_binary), str(signaling_binary)], check=True)
    connection_source = (pathlib.Path(__file__).parent / "PairedSonyConnectionProbe.m").read_text()
    media_source = (pathlib.Path(__file__).parent / "DirectAVDTPLiveMediaProbe.m").read_text()
    timing = signaling_source[signaling_source.index("static void RunLoopFor("):signaling_source.index("static NSString *NormalizeAddress(")]
    for helper_source in [signaling_source, connection_source, media_source]:
        assert "dateWithTimeIntervalSinceNow:" not in helper_source and ".timeIntervalSinceNow" not in helper_source
        start = helper_source.index("static void RunLoopFor(")
        end = helper_source.index("\n}\n", helper_source.index("static double MonotonicTime(", start)) + len("\n}\n")
        assert helper_source[start:end].strip() == timing.strip()
    probe = signaling_source[signaling_source.index("@interface DirectPlaybackProbe"):signaling_source.index("static NSString *ReadLine(")]
    read = signaling_source[signaling_source.index("static NSString *ReadLine("):signaling_source.index("static NSArray<NSNumber *> *DecodeReply(")]
    response = signaling_source[signaling_source.index("static NSData *AwaitResponse("):signaling_source.index("static NSData *Query(")]
    control = signaling_source[signaling_source.index("static BOOL WaitControl("):signaling_source.index("static BOOL LDACSelection(")]
    closed = signaling_source[signaling_source.index("static void WaitTransportClosed("):signaling_source.index("int main(")]
    connection_lock = connection_source[connection_source.index("static int ConnectionLock("):connection_source.index("static BOOL ReadAudio(")]
    observer = connection_source[connection_source.index("@interface ConnectionObserver"):connection_source.index("static int WatchConnection(")]
    watch = connection_source[connection_source.index("static int WatchConnection("):connection_source.index("int main(")]
    start = media_source.index("        double openDeadline =")
    opening = media_source[start:media_source.index("        if (openExpired)", start)]
    clock_fixture = directory / "NativeClock.m"
    clock_binary = directory / "native-clock"
    clock_fixture.write_text(r'''#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
static double elapsed, wallOffset, jump;
static NSUInteger ticks;
static BOOL disarmed;
static int commandFD = -1;
static uint64_t ClockNanoseconds(clockid_t clock) {
    assert(clock == CLOCK_MONOTONIC);
    return (uint64_t)(elapsed * 1000000000.0);
}
static SInt32 ClockRunLoop(CFRunLoopMode mode, CFTimeInterval seconds, Boolean returnAfterSourceHandled) {
    assert(CFEqual(mode, kCFRunLoopDefaultMode) && seconds > 0 && !returnAfterSourceHandled);
    assert(++ticks < 100);
    elapsed += 1;
    wallOffset = jump;
    if (commandFD >= 0) {
        assert(write(commandFD, "stop\n", 5) == 5);
        commandFD = -1;
    }
    return kCFRunLoopRunTimedOut;
}
@interface ClockDate : NSObject
+ (NSDate *)date;
@end
@implementation ClockDate
+ (NSDate *)date { return [NSDate dateWithTimeIntervalSince1970:1700000000 + elapsed + wallOffset]; }
@end
#define NSDate ClockDate
#define clock_gettime_nsec_np ClockNanoseconds
#define CFRunLoopRunInMode ClockRunLoop
''' + timing + r'''
#undef CFRunLoopRunInMode
#undef clock_gettime_nsec_np
''' + probe + read + r'''
static BOOL HandlePeerCommand(DirectPlaybackProbe *probe, NSData *packet) { abort(); }
''' + response + control + closed + r'''
static BOOL ParentInputEnded(void) { return NO; }
static BOOL ParentExited(int events) { return YES; }
static int NativeOutputState(NSString *address) { return 0; }
static int PriorityIdle(NSString *uid) { return 0; }
''' + (pathlib.Path(__file__).parent.parent / "SonyClassicConnection.h").read_text() + connection_lock + observer + watch + r'''
@interface ClockDevice : NSObject
@property BluetoothConnectionHandle connectionHandle;
- (BOOL)isConnected;
@end
@implementation ClockDevice
- (BOOL)isConnected { return YES; }
@end
@interface ClockMediaProbe : NSObject
@property BOOL stdinEnded, closeRequested, failed;
@end
@implementation ClockMediaProbe
@end
static NSString *AvailableCommand(ClockMediaProbe *probe) { return nil; }
static BOOL MediaOpenTimeout(void) {
    ClockMediaProbe *probe = [ClockMediaProbe new];
    BOOL openDone = NO;
''' + opening + r'''
    return openExpired;
}
static void ResetClock(void) { elapsed = 0; wallOffset = 0; ticks = 0; }
static void CheckElapsed(double expected) {
    assert(elapsed == expected && wallOffset == jump);
    assert(NSDate.date.timeIntervalSince1970 == 1700000000 + expected + jump);
}
#undef NSDate
''' + timing.replace("RunLoopFor", "NativeRunLoopFor").replace("MonotonicTime", "NativeMonotonicTime") + r'''
int main(void) {
    @autoreleasepool {
        __block BOOL handled = NO, dispatched = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ dispatched = YES; });
        CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent() + 0.01,
            0, 0, 0, ^(CFRunLoopTimerRef timer) { handled = YES; });
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
        double started = NativeMonotonicTime();
        NativeRunLoopFor(0.03);
        assert(handled && dispatched && NativeMonotonicTime() - started < 1);
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
        int input[2];
        assert(pipe(input) == 0);
        int original = dup(STDIN_FILENO);
        assert(original >= 0 && dup2(input[0], STDIN_FILENO) >= 0);
        close(input[0]);
        for (NSUInteger direction = 0; direction < 2; direction++) {
            jump = direction ? -3600 : 3600;
            DirectPlaybackProbe *probe = [DirectPlaybackProbe new];
            probe.pending = [NSMutableData data];
            probe.controlPending = [NSMutableData data];
            probe.continuous = YES;
            ResetClock();
            assert(!ReadLine(probe, MonotonicTime() + 3, NO, 0.001));
            CheckElapsed(3);
            ResetClock();
            assert(!ConsumeSDU(probe, @"0x500C 2", MonotonicTime() + 3));
            CheckElapsed(3);
            const uint8_t accepted[] = {0x42, 0x08};
            NSData *packet = [NSData dataWithBytes:accepted length:sizeof(accepted)];
            [probe.pending appendData:packet];
            assert([ConsumeSDU(probe, @"0x500C 2", MonotonicTime() + 3) isEqualToData:packet]);
            ResetClock();
            assert(!FramedReply(probe, MonotonicTime() + 3));
            CheckElapsed(3);
            ResetClock();
            assert(!AwaitResponse(probe, 1, 1));
            CheckElapsed(30);
            ResetClock();
            assert(!WaitControl(probe, @"media-ready"));
            CheckElapsed(30);
            ResetClock();
            commandFD = input[1];
            assert([ReadLine(probe, INFINITY, NO, 0.001) isEqualToString:@"stop"] && probe.stopRequested);
            CheckElapsed(1);
            ResetClock();
            probe.stdinEnded = YES;
            WaitTransportClosed(probe);
            assert(probe.failed && !probe.closed);
            CheckElapsed(2);
            ResetClock();
            assert(MediaOpenTimeout());
            CheckElapsed(5);
            ResetClock();
            NSString *address = [NSString stringWithFormat:@"clock-fixture-%d-%lu", getpid(), direction];
            int held = ConnectionLock(address, NO);
            assert(held >= 0 && ConnectionLock(address, NO) == -1);
            CheckElapsed(5);
            close(held);
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"dev.baglayan.Acouplet.audio-%@.lock", address]];
            assert(unlink(path.fileSystemRepresentation) == 0);
            ResetClock();
            ClockDevice *device = [ClockDevice new];
            device.connectionHandle = 1;
            ConnectionObserver *observer = [ConnectionObserver new];
            observer.originalHandle = 1;
            assert(WatchConnection((IOBluetoothDevice *)device, observer, address, @"fixture", -1) == 6);
            alarm(0);
            CheckElapsed(45);
            printf("PASS native helper clock jump=%.0f: signaling reply/control/close, media open, connection lock/recovery deadlines and epoch logs; no devices accessed\n", jump);
        }
        assert(dup2(original, STDIN_FILENO) >= 0);
        close(original);
        close(input[1]);
    }
    return 0;
}
''')
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-D_DARWIN_C_SOURCE", "-DACOUPLET_LDAC_PROBE_ONLY=0", "-framework", "Foundation", "-framework", "CoreFoundation", str(clock_fixture), "-o", str(clock_binary)], check=True)
    result = subprocess.run([str(clock_binary)], check=True, capture_output=True, text=True, timeout=15)
    for timestamp in ["1700003603.000000", "1699996403.000000"]:
        assert "SDU_GATE time=" + timestamp in result.stdout, result.stdout
    print(result.stdout, end="")
