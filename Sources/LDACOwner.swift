#if !ACOUPLET_PUBLIC_APIS_ONLY
import Darwin
import Foundation
import Security

private enum LDACOwnerCommand: Codable, Sendable {
    case claim(UUID, String, String, LDACSampleRate)
    case cancelStart
    case configure(Int, ClosedRange<Int>, Bool)
    case priority
    case handoff
    case validate
    case reconnect
    case prepared
    case silence
    case start(UUID, LDACConfiguration, Bool, Bool)
    case stop(Bool)
    case recover(String)
    case verify(String)
    case allowHandoff
    case gain(Double)
    case release(Bool)
    case restore(LDACRouteRecovery)
}

private struct LDACOwnerRequest: Codable, Sendable {
    let id: UUID?
    let command: LDACOwnerCommand
}

private enum LDACOwnerMessage: Codable, Sendable {
    case reply(UUID, LDACNativeVolume?, String?)
    case controls(LDACNativeVolume)
    case outputFailure(String, Bool)
    case session(UUID, LDACNativeSession.Event)
    case exited
    case recovery(LDACRouteRecovery)
}

private struct LDACOwnerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class LDACOwnerChannel: @unchecked Sendable {
    private let child: LDACNativeChild
    private let lock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var replies: [UUID: (signal: DispatchSemaphore, message: LDACOwnerMessage?)] = [:]
    private var ended = false
    private var closing = false
    private var recovery: LDACRouteRecovery?
    private var shutdownDeadline: DispatchTime?
    private var cleanExit = false
    private var latestControls: LDACNativeVolume?

    var cleaned: Bool { lock.withLock { cleanExit } }
    var currentControls: LDACNativeVolume? { lock.withLock { latestControls } }

    var recoveryState: LDACRouteRecovery? { lock.withLock { recovery } }
    var hasEnded: Bool { lock.withLock { ended } }
    private let receive: @MainActor @Sendable (LDACOwnerMessage) -> Void

    init(receive: @escaping @MainActor @Sendable (LDACOwnerMessage) -> Void) throws {
        self.receive = receive
        guard let executable = Bundle.main.executableURL else {
            throw LDACOwnerError(message: String(localized: "LDAC playback is unavailable in this installation of Acouplet."))
        }
        child = try LDACNativeChild(executable: executable, arguments: ["--ldac-owner"], inheritedPCM: nil, mergeDiagnostics: false)
        DispatchQueue.global(qos: .userInitiated).async { self.read() }
    }

    func send(_ command: LDACOwnerCommand) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { throw LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again.")) }
        try write(LDACOwnerRequest(id: nil, command: command))
        if case .stop = command, shutdownDeadline == nil { shutdownDeadline = .now() + 120 }
    }

    func request(_ command: LDACOwnerCommand, timeout: TimeInterval = 10) throws -> LDACNativeVolume? {
        let id = UUID()
        let signal = DispatchSemaphore(value: 0)
        lock.lock()
        guard !ended else {
            lock.unlock()
            throw LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again."))
        }
        replies[id] = (signal, nil)
        do { try write(LDACOwnerRequest(id: id, command: command)) }
        catch { replies[id] = nil; lock.unlock(); throw error }
        lock.unlock()
        _ = signal.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        guard case let .reply(_, controls, error) = replies.removeValue(forKey: id)?.message else {
            shutdown()
            throw LDACOwnerError(message: String(localized: "LDAC did not stop completely."))
        }
        if let error { throw LDACOwnerError(message: error) }
        return controls
    }

    func finish(disconnected: Bool) throws {
        lock.lock()
        closing = true
        lock.unlock()
        _ = try request(.release(disconnected), timeout: 120)
        guard exited.wait(timeout: .now() + 3) == .success else {
            throw LDACOwnerError(message: String(localized: "LDAC did not stop completely."))
        }
    }

    func restore(_ recovery: LDACRouteRecovery) throws {
        lock.withLock { closing = true }
        _ = try request(.restore(recovery), timeout: 65)
        guard exited.wait(timeout: .now() + 3) == .success else {
            throw LDACOwnerError(message: String(localized: "LDAC did not stop completely."))
        }
    }

    func close() {
        lock.lock()
        shutdown()
        lock.unlock()
    }

    private func shutdown() {
        child.closeInput()
        if shutdownDeadline == nil { shutdownDeadline = .now() + 120 }
    }

    private func write(_ request: LDACOwnerRequest) throws {
        let data = try JSONEncoder().encode(request)
        guard data.count <= 8192 else { throw LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again.")) }
        try child.send(String(decoding: data, as: UTF8.self))
    }

    private func read() {
        var invalid = false
        while !child.finished {
            var descriptor = pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 50)
            do {
                if result < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if result > 0 {
                    for line in try child.readLines() {
                        if invalid { continue }
                        let message = try JSONDecoder().decode(LDACOwnerMessage.self, from: Data(line.utf8))
                        if case let .recovery(state) = message {
                            lock.withLock { recovery = state }
                        } else if case let .reply(id, controls, _) = message {
                            lock.lock()
                            if let controls { latestControls = controls }
                            if let pending = replies[id] {
                                replies[id] = (pending.signal, message)
                                pending.signal.signal()
                            }
                            lock.unlock()
                        } else {
                            if case let .controls(controls) = message { lock.withLock { latestControls = controls } }
                            DispatchQueue.main.async { self.receive(message) }
                        }
                    }
                }
            } catch {
                invalid = true
                lock.withLock { shutdown() }
            }
            lock.lock()
            if child.outputEnded { shutdown() }
            let expired = shutdownDeadline.map { DispatchTime.now() >= $0 } ?? false
            lock.unlock()
            if expired { child.signal(SIGKILL) }
            child.reap()
            if child.outputEnded && !child.finished { Thread.sleep(forTimeInterval: 0.01) }
        }
        lock.lock()
        ended = true
        cleanExit = child.exitCode == 0 && !invalid
        let notify = !closing
        for pending in replies.values { pending.signal.signal() }
        exited.signal()
        lock.unlock()
        if notify { DispatchQueue.main.async { self.receive(.exited) } }
    }
}

@MainActor
final class LDACOwnerOutput {
    private let id: UUID
    private let changed: (Result<LDACNativeVolume, Error>) -> Void
    private var channel: LDACOwnerChannel?
    fileprivate var sessionReceiver: (UUID, (LDACNativeSession.Event) -> Void)?
    private(set) var controls = LDACNativeVolume(scalar: 0, muted: true)

    init(id: UUID, address: String, changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) {
        self.id = id
        self.changed = changed
    }

    func claim(model: String, targetAddress: String, sampleRate: LDACSampleRate = .hz48000) async throws {
        let channel = try LDACOwnerChannel { [weak self] message in self?.receive(message) }
        self.channel = channel
        do {
            let controls = try await withTaskCancellationHandler {
                try await Task.detached { try channel.request(.claim(self.id, targetAddress, model, sampleRate), timeout: 65) }.value
            } onCancel: {
                try? channel.send(.cancelStart)
            }
            if let controls { self.controls = controls }
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) async throws {
        try await request(.configure(volume, range, preservingUserChange))
    }

    func priorityControl() async throws { try await request(.priority) }
    func selectForHandoff() async throws { try await request(.handoff) }
    func validateForRecovery() async throws { try await request(.validate) }
    func prepareForReconnect() async throws { try await request(.reconnect) }
    func finishPreparation() async throws { try await request(.prepared) }

    func silence() {
        do { try channel?.send(.silence) }
        catch { changed(.failure(error)) }
    }

    func restoreAndRelease(targetDisconnected: Bool = false) async -> String? {
        guard let channel else { return nil }
        defer { self.channel = nil }
        if channel.hasEnded && channel.cleaned { return nil }
        do {
            try await Task.detached { try channel.finish(disconnected: targetDisconnected) }.value
            return nil
        } catch {
            channel.close()
            if channel.hasEnded, let recovery = channel.recoveryState {
                do {
                    let replacement = try LDACOwnerChannel { _ in }
                    defer { replacement.close() }
                    try await Task.detached { try replacement.restore(recovery) }.value
                } catch { return error.localizedDescription }
            }
            return error.localizedDescription
        }
    }

    fileprivate func send(_ command: LDACOwnerCommand) {
        do { try channel?.send(command) }
        catch { changed(.failure(error)) }
    }

    private func request(_ command: LDACOwnerCommand) async throws {
        guard let channel else { throw LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again.")) }
        let controls = try await Task.detached { try channel.request(command) }.value
        try Task.checkCancellation()
        if let controls = channel.currentControls ?? controls { self.controls = controls }
    }

    deinit { channel?.close() }

    private func receive(_ message: LDACOwnerMessage) {
        switch message {
        case let .controls(controls):
            self.controls = channel?.currentControls ?? controls
            changed(.success(self.controls))
        case let .outputFailure(message, priority):
            if priority { changed(.failure(LDACPriorityCleanupError(message: message))) }
            else { changed(.failure(LDACOwnerError(message: message))) }
        case let .session(id, event):
            if sessionReceiver?.0 == id { sessionReceiver?.1(event) }
        case .exited:
            if let receive = sessionReceiver?.1 {
                receive(.finished(LDACNativeSession.Completion(message: String(localized: "LDAC did not stop completely."),
                    canRetry: false, requiresAttention: true, targetDisconnected: false, waitForReconnect: false)))
            } else {
                changed(.failure(LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again."))))
            }
        case .reply, .recovery: break
        }
    }
}

@MainActor
final class LDACOwnerSession {
    let id: UUID
    private let output: LDACOwnerOutput
    private let configuration: LDACConfiguration
    private let recoveryAttempt: Bool
    private let restoringOnly: Bool

    init(id: UUID, output: LDACOwnerOutput, configuration: LDACConfiguration, recoveryAttempt: Bool,
         restoringOnly: Bool, receive: @escaping (LDACNativeSession.Event) -> Void) {
        self.id = id
        self.output = output
        self.configuration = configuration
        self.recoveryAttempt = recoveryAttempt
        self.restoringOnly = restoringOnly
        output.sessionReceiver = (id, receive)
    }

    func start() { output.send(.start(id, configuration, recoveryAttempt, restoringOnly)) }
    func stop(restoreAudio: Bool) { output.send(.stop(restoreAudio)) }
    func recoverConnection(reason: String) { output.send(.recover(reason)) }
    func verifyConnectionLoss(reason: String) { output.send(.verify(reason)) }
    func allowHandoff() { output.send(.allowHandoff) }
    func updateGain(_ gain: Double) { output.send(.gain(gain)) }
}

@MainActor
enum LDACOwnerWorker {
    private static var activeWorker: Worker?

    static func run() {
        var ownCode: SecCode?
        var staticCode: SecStaticCode?
        var parentCode: SecCode?
        var requirement: SecRequirement?
        let parent = getppid()
        guard parent > 1,
              SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: parent] as CFDictionary, [], &parentCode) == errSecSuccess,
              let parentCode, SecCodeCheckValidity(parentCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            exit(EXIT_FAILURE)
        }
        signal(SIGPIPE, SIG_IGN)
        let worker = Worker()
        activeWorker = worker
        worker.watchParent(parent)
        worker.readCommands()
        dispatchMain()
    }

    @MainActor
    private final class Worker {
        private var parentWatcher: DispatchSourceProcess?
        private var signalWatchers: [DispatchSourceSignal] = []
        private var output: LDACNativeOutput?
        private var priority: LDACPriorityControl?
        private var session: LDACNativeSession?
        private var claimTask: Task<Void, Never>?
        private var startCancelled = false
        private var parentEnded = false
        private var releasing = false
        private var address: String?
        private var stoppingRestore = true
        private var restoreAfterSession = false
        private var targetDisconnected = false

        func watchParent(_ parent: pid_t) {
            for value in [SIGTERM, SIGINT] {
                signal(value, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: value, queue: .global(qos: .userInitiated))
                source.setEventHandler { @Sendable [weak self] in self?.scheduleParentExit() }
                signalWatchers.append(source)
                source.resume()
            }
            let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global(qos: .userInitiated))
            watcher.setEventHandler { @Sendable [weak self] in self?.scheduleParentExit() }
            parentWatcher = watcher
            watcher.resume()
            if getppid() != parent { scheduleParentExit() }
        }

        nonisolated private func scheduleParentExit() {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 120) { kill(getpid(), SIGKILL) }
            DispatchQueue.main.async { self.parentExited() }
        }

        func readCommands() {
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                do {
                    while true {
                        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        pending.append(contentsOf: buffer.prefix(count))
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let data = pending.prefix(upTo: newline)
                            pending.removeSubrange(...newline)
                            guard data.count <= 8192 else { throw LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again.")) }
                            let request = try JSONDecoder().decode(LDACOwnerRequest.self, from: data)
                            DispatchQueue.main.async { self.handle(request) }
                        }
                        guard pending.count <= 8192 else { throw LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again.")) }
                    }
                } catch {}
                self.scheduleParentExit()
            }
        }

        private func send(_ message: LDACOwnerMessage) {
            do {
                var data = try JSONEncoder().encode(message)
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch { scheduleParentExit() }
        }

        private func reply(_ request: LDACOwnerRequest, error: String? = nil) {
            if let output { send(.recovery(output.routeRecovery)) }
            if let id = request.id { send(.reply(id, output?.controls, error)) }
            else if let error { send(.outputFailure(error, false)) }
        }

        private func handle(_ request: LDACOwnerRequest) {
            guard !parentEnded, !releasing else { return }
            do {
                switch request.command {
                case let .claim(id, address, model, sampleRate):
                    if startCancelled { throw CancellationError() }
                    guard output == nil else { throw LDACOwnerError(message: String(localized: "LDAC playback stopped unexpectedly. Try again.")) }
                    let output = LDACNativeOutput(id: id, address: address) { [weak self] result in
                        switch result {
                        case let .success(controls):
                            if let output = self?.output { self?.send(.recovery(output.routeRecovery)) }
                            self?.send(.controls(controls))
                        case let .failure(error): self?.send(.outputFailure(error.localizedDescription, error is LDACPriorityCleanupError))
                        }
                    }
                    self.output = output
                    self.address = address
                    claimTask = Task {
                        do {
                            try await output.claim(model: model, targetAddress: address, sampleRate: sampleRate)
                            try Task.checkCancellation()
                            reply(request)
                        } catch { reply(request, error: error.localizedDescription) }
                        claimTask = nil
                        if parentEnded { await restoreAfterParentExit() }
                    }
                    return
                case .cancelStart: startCancelled = true; claimTask?.cancel()
                case let .configure(volume, range, preserve): try output?.configure(volume: volume, range: range, preservingUserChange: preserve)
                case .priority: priority = try LDACPlaybackPriority.control { try output?.priorityControl() }
                case .handoff:
                    if let output {
                        let state = output.routeRecovery
                        send(.recovery(.init(address: state.address, model: state.model, sampleRate: state.sampleRate,
                            defaults: state.defaults, controls: state.controls, selected: true)))
                        try output.selectForHandoff()
                    }
                case .validate: try output?.validateForRecovery()
                case .reconnect:
                    priority = try LDACPlaybackPriority.control { try output?.prepareForReconnect() }
                    if priority == nil { try output?.validateForRecovery() }
                case .prepared: try output?.finishPreparation()
                case .silence: output?.silence()
                case let .start(id, configuration, recovery, restore):
                    guard session == nil, let address, claimTask == nil else { throw LDACOwnerError(message: String(localized: "LDAC did not stop completely.")) }
                    let session = LDACNativeSession(id: id, address: address, helpers: .init(bundle: .main), gain: 0,
                        outputDeviceUID: LDACNativeOutput.uid, priority: restore ? nil : priority, configuration: configuration,
                        recoveryAttempt: recovery, restoringOnly: restore) { [weak self] event in
                        guard let self, self.session?.id == id else { return }
                        if case let .finished(completion) = event {
                            self.session = nil
                            self.restoreAfterSession = completion.canRetry && !completion.waitForReconnect
                            self.targetDisconnected = completion.targetDisconnected
                        }
                        self.send(.session(id, event))
                        if self.parentEnded, self.session == nil { Task { await self.restoreAfterParentExit() } }
                    }
                    self.session = session
                    session.start()
                case let .stop(restore): stoppingRestore = stoppingRestore && restore; session?.stop(restoreAudio: stoppingRestore)
                case let .recover(reason): session?.recoverConnection(reason: reason)
                case let .verify(reason): session?.verifyConnectionLoss(reason: reason)
                case .allowHandoff: session?.allowHandoff()
                case let .gain(gain): session?.updateGain(gain)
                case let .restore(recovery):
                    guard output == nil else { throw LDACOwnerError(message: String(localized: "LDAC did not stop completely.")) }
                    let output = LDACNativeOutput(id: UUID(), address: recovery.address) { _ in }
                    self.output = output
                    claimTask = Task {
                        var failure: String?
                        do {
                            try await output.claim(model: recovery.model, targetAddress: recovery.address,
                                sampleRate: recovery.sampleRate, recovering: recovery)
                        } catch { failure = error.localizedDescription }
                        let restoreError = await output.restoreAndRelease()
                        reply(request, error: failure ?? restoreError)
                        exit(failure == nil && restoreError == nil ? EXIT_SUCCESS : EXIT_FAILURE)
                    }
                    return
                case let .release(disconnected):
                    guard session == nil, claimTask == nil else { throw LDACOwnerError(message: String(localized: "LDAC did not stop completely.")) }
                    parentEnded = true
                    Task { await release(disconnected: disconnected, request: request) }
                    return
                }
                reply(request)
            } catch {
                if case let .start(id, _, _, _) = request.command {
                    send(.session(id, .finished(.init(message: String(localized: "LDAC did not stop completely."),
                        canRetry: false, requiresAttention: true, targetDisconnected: false, waitForReconnect: false))))
                } else { reply(request, error: error.localizedDescription) }
            }
        }

        private func parentExited() {
            guard !parentEnded else { return }
            parentEnded = true
            claimTask?.cancel()
            output?.silence()
            if let session { session.stop(restoreAudio: stoppingRestore) }
            else if claimTask == nil { Task { await restoreAfterParentExit() } }
        }

        private func restoreAfterParentExit() async {
            if restoreAfterSession, stoppingRestore, let address {
                restoreAfterSession = false
                let id = UUID()
                let session = LDACNativeSession(id: id, address: address, helpers: .init(bundle: .main), gain: 0,
                    restoringOnly: true) { [weak self] event in
                    guard let self, self.session?.id == id else { return }
                    if case let .finished(completion) = event {
                        self.session = nil
                        Task { await self.release(disconnected: completion.targetDisconnected) }
                    }
                }
                self.session = session
                session.start()
            } else { await release(disconnected: targetDisconnected) }
        }

        private func release(disconnected: Bool, request: LDACOwnerRequest? = nil) async {
            guard !releasing else { return }
            releasing = true
            let error = await output?.restoreAndRelease(targetDisconnected: disconnected)
            if let request { reply(request, error: error) }
            exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }
}
#endif
