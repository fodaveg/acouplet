import Foundation

struct SonyMultipointTransition: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case awaitingResponse
        case awaitingUser(SonyConnectionAlert)
        case replyQueued(SonyConnectionAlert, SonyConnectionAlertAction)
        case queuedReadback
        case recovering
        case verifying
        case complete
        case cancelled
        case failed
    }

    let requestID: UUID
    let originalEnabled: Bool
    let targetEnabled: Bool
    private(set) var slot: UInt8
    private(set) var session: UInt64
    private(set) var phase = Phase.queued
    private(set) var failureMessage: String?
    private var requestTransmitted = false
    private var requestAcknowledged = false
    private var confirmationReply: [UInt8]?
    private var cancellationRequested = false
    private var receivedAlertCount = 0
    private var soundQualityWarningConfirmed = false

    /// The setter in the headphones' own protocol generation, fixed when the change is requested.
    let requestPayload: [UInt8]

    init?(enabled: Bool, model: SonySystemFeatures, session: UInt64, requestID: UUID = UUID()) {
        guard let slot = model.multipointSlot, let original = model.multipoint?.enabled,
              original != enabled, let payload = model.multipointSetPayload(enabled: enabled) else { return nil }
        self.requestID = requestID
        originalEnabled = original
        targetEnabled = enabled
        requestPayload = payload
        self.slot = slot
        self.session = session
    }

    var expectedPayload: [UInt8]? {
        switch phase {
        case .queued: requestPayload
        case .replyQueued(let alert, let action): alert.replyPayload(action)
        case .queuedReadback: [0xD6, slot]
        default: nil
        }
    }

    var alert: SonyConnectionAlert? {
        if case .awaitingUser(let alert) = phase { alert } else { nil }
    }

    var awaitingUser: Bool { alert != nil }
    var isFinished: Bool { phase == .complete || phase == .cancelled || phase == .failed }
    var canRetryRecovery: Bool { phase == .failed && requestTransmitted }

    @discardableResult
    mutating func validateForTransmission(model: SonySystemFeatures, session: UInt64) -> Bool {
        guard session == self.session, expectedPayload != nil else { return false }
        switch phase {
        case .queued:
            guard model.multipointSlot == slot, model.multipoint?.enabled == originalEnabled,
                  model.multipointSetPayload(enabled: targetEnabled) == requestPayload else {
                return fail(String(localized: "Multipoint changed or its controls are no longer available."))
            }
        case .queuedReadback:
            guard model.multipointSlot == slot else {
                return fail(String(localized: "The headphones no longer identify the requested multipoint setting."))
            }
        default:
            break
        }
        return true
    }

    @discardableResult
    mutating func commandTransmitted(_ payload: [UInt8], model: SonySystemFeatures, session: UInt64) -> Bool {
        guard payload == expectedPayload, validateForTransmission(model: model, session: session) else { return false }
        switch phase {
        case .queued:
            requestTransmitted = true
            phase = .awaitingResponse
        case .replyQueued(_, let action):
            if action == .negative {
                phase = .cancelled
            } else {
                confirmationReply = payload
                requestAcknowledged = false
                phase = .awaitingResponse
            }
        case .queuedReadback: phase = .verifying
        default: return false
        }
        return true
    }

    @discardableResult
    mutating func commandAcknowledged(_ payload: [UInt8], session: UInt64) -> Bool {
        guard session == self.session, requestTransmitted, !isFinished, payload == (confirmationReply ?? requestPayload) else { return false }
        requestAcknowledged = true
        return true
    }

    var diagnosticPhase: String {
        switch phase {
        case .queued: "queued"
        case .awaitingResponse: "awaitingResponse"
        case .awaitingUser: "awaitingUser"
        case .replyQueued: "replyQueued"
        case .queuedReadback: "queuedReadback"
        case .recovering: "recovering"
        case .verifying: "verifying"
        case .complete: "complete"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    @discardableResult
    mutating func receiveAlert(_ alert: SonyConnectionAlert, session: UInt64) -> Bool {
        guard session == self.session, alert.isMultipointChange,
              phase == .awaitingResponse || phase == .queuedReadback || phase == .verifying else { return false }
        let warningConfirmed = soundQualityWarningConfirmed
        soundQualityWarningConfirmed = false
        receivedAlertCount += 1
        if case .unknown = alert.actionType { return false }
        if warningConfirmed, alert.format == .fixed, alert.messageID == 0x70, alert.actionType == .positiveNegative {
            phase = .replyQueued(alert, .positive)
        } else {
            phase = .awaitingUser(alert)
        }
        return true
    }

    mutating func respond(to alert: SonyConnectionAlert, action: SonyConnectionAlertAction, confirmsSoundQualityWarning: Bool = false) -> [UInt8]? {
        guard phase == .awaitingUser(alert), let payload = alert.replyPayload(action) else { return nil }
        cancellationRequested = action == .negative
        soundQualityWarningConfirmed = confirmsSoundQualityWarning && receivedAlertCount == 1 && targetEnabled
            && action == .positive && alert.format == .fixed && alert.messageID == 0x07 && alert.actionType == .positiveNegative
        phase = .replyQueued(alert, action)
        return payload
    }

    @discardableResult
    mutating func acknowledge(_ alert: SonyConnectionAlert) -> Bool {
        guard phase == .awaitingUser(alert), alert.actionType == .confirmationOnly else { return false }
        phase = .awaitingResponse
        return true
    }

    @discardableResult
    mutating func requestReadback(model: SonySystemFeatures, session: UInt64) -> Bool {
        guard session == self.session, phase == .awaitingResponse else { return false }
        guard model.multipointSlot == slot else {
            return fail(String(localized: "The headphones no longer identify the requested multipoint setting."))
        }
        phase = .queuedReadback
        return true
    }

    @discardableResult
    mutating func receiveReadback(_ payload: [UInt8], model: SonySystemFeatures, session: UInt64, readbackOwned: Bool = false) -> Bool {
        guard session == self.session, phase == .verifying, readbackOwned,
              payload.prefix(2) == [0xD7, slot] else { return false }
        var received = model
        guard received.multipointSlot == slot, received.update(payload), let enabled = received.multipoint?.enabled else {
            fail(String(localized: "The headphones did not report a valid multipoint setting."))
            return true
        }
        if cancellationRequested {
            if enabled == originalEnabled {
                phase = .cancelled
            } else {
                fail(String(localized: "Multipoint changed before your cancellation could be confirmed."))
            }
        } else if enabled == targetEnabled {
            phase = .complete
        } else {
            fail(String(localized: "The headphones did not confirm the requested multipoint change."))
        }
        return true
    }

    @discardableResult
    mutating func controlLost(session: UInt64) -> Bool {
        guard session == self.session, !isFinished else { return false }
        soundQualityWarningConfirmed = false
        if phase == .queued {
            fail(String(localized: "The control connection was lost before the multipoint request was sent."))
        } else {
            phase = .recovering
        }
        return true
    }

    @discardableResult
    mutating func controlReady(model: SonySystemFeatures, session: UInt64) -> Bool {
        guard session > self.session, phase == .recovering, let slot = model.multipointSlot else { return false }
        self.session = session
        self.slot = slot
        soundQualityWarningConfirmed = false
        phase = .queuedReadback
        return true
    }

    @discardableResult
    mutating func timeout() -> Bool {
        guard phase == .awaitingResponse || phase == .verifying else { return false }
        if phase == .awaitingResponse, requestAcknowledged {
            phase = .queuedReadback
            return true
        }
        fail(String(localized: "The headphones did not confirm the multipoint change in time."))
        return true
    }

    @discardableResult
    mutating func recoveryFailed() -> Bool {
        guard phase == .recovering else { return false }
        fail(String(localized: "Reconnect the selected headphones to check the multipoint setting."))
        return true
    }

    @discardableResult
    mutating func retryRecovery() -> Bool {
        guard canRetryRecovery else { return false }
        phase = .recovering
        failureMessage = nil
        return true
    }

    @discardableResult
    mutating func recheckAfterDirective(session: UInt64) -> Bool {
        guard session == self.session, isFinished, requestTransmitted else { return false }
        phase = .recovering
        failureMessage = nil
        return true
    }

    @discardableResult
    private mutating func fail(_ message: String) -> Bool {
        phase = .failed
        failureMessage = message
        return false
    }
}
