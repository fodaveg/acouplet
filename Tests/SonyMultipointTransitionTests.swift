import XCTest
@testable import Acouplet

final class SonyMultipointTransitionTests: XCTestCase {
    func testFallbackRequiresMatchingSetterAcknowledgmentAndRunsOnlyOnce() throws {
        for enabled in [false, true] {
            let state = model(enabled: !enabled)
            var transition = try XCTUnwrap(SonyMultipointTransition(enabled: enabled, model: state, session: 1))
            XCTAssertFalse(transition.commandAcknowledged(transition.requestPayload, session: 1))
            transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
            XCTAssertFalse(transition.commandAcknowledged(transition.requestPayload, session: 2))
            XCTAssertFalse(transition.commandAcknowledged([0xD6, 0xD2], session: 1))
            var unacknowledged = transition
            XCTAssertTrue(unacknowledged.timeout())
            XCTAssertEqual(unacknowledged.phase, .failed)
            XCTAssertTrue(transition.commandAcknowledged(transition.requestPayload, session: 1))
            XCTAssertEqual(transition.phase, .awaitingResponse)
            XCTAssertTrue(transition.timeout())
            XCTAssertEqual(transition.phase, .queuedReadback)
            XCTAssertFalse(transition.timeout())
            XCTAssertTrue(transition.commandTransmitted([0xD6, 0xD2], model: state, session: 1))
            XCTAssertTrue(transition.timeout())
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertNil(transition.expectedPayload)
        }
    }

    func testPositiveReplyMustBeAcknowledgedBeforeFallbackCanRead() throws {
        let state = model()
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
        transition.commandAcknowledged(transition.requestPayload, session: 1)
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
        transition.receiveAlert(alert, session: 1)
        let reply = try XCTUnwrap(transition.respond(to: alert, action: .positive))
        transition.commandTransmitted(reply, model: state, session: 1)
        XCTAssertEqual(transition.phase, .awaitingResponse)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.commandAcknowledged(transition.requestPayload, session: 1))
        var missingAcknowledgment = transition
        missingAcknowledgment.timeout()
        XCTAssertEqual(missingAcknowledgment.phase, .failed)
        XCTAssertTrue(transition.commandAcknowledged(reply, session: 1))
        XCTAssertEqual(transition.phase, .awaitingResponse)
        transition.timeout()
        XCTAssertEqual(transition.phase, .queuedReadback)
    }

    func testOnlyKnownAvailableDifferentValuesCanQueueTheIdentifiedSlot() throws {
        XCTAssertNil(SonyMultipointTransition(enabled: true, model: SonySystemFeatures(), session: 1))
        XCTAssertNil(SonyMultipointTransition(enabled: true, model: model(enabled: nil), session: 1))
        XCTAssertNil(SonyMultipointTransition(enabled: true, model: model(available: nil), session: 1))
        XCTAssertNil(SonyMultipointTransition(enabled: true, model: model(available: false), session: 1))
        XCTAssertNil(SonyMultipointTransition(enabled: false, model: model(), session: 1))
        for enabled in [false, true] {
            let state = model(enabled: !enabled, slot: 0xD4)
            let request = UUID()
            var transition = try XCTUnwrap(SonyMultipointTransition(enabled: enabled, model: state, session: 3, requestID: request))
            XCTAssertEqual(transition.requestID, request)
            XCTAssertEqual(transition.originalEnabled, !enabled)
            XCTAssertEqual(transition.targetEnabled, enabled)
            XCTAssertEqual(transition.slot, 0xD4)
            XCTAssertEqual(transition.expectedPayload, [0xD8, 0xD4, 0, enabled ? 0 : 1])
            XCTAssertFalse(transition.timeout())
            XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, model: state, session: 2))
            XCTAssertFalse(transition.commandTransmitted([0xD8, 0xD2, 0, enabled ? 0 : 1], model: state, session: 3))
            XCTAssertFalse(transition.requestReadback(model: state, session: 3))
            XCTAssertTrue(transition.commandTransmitted(transition.requestPayload, model: state, session: 3))
            XCTAssertEqual(transition.phase, .awaitingResponse)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, model: state, session: 3))
        }
        for changed in [model(enabled: true), model(enabled: nil), model(available: false), model(slot: 0xD4)] {
            var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: model(), session: 1))
            XCTAssertFalse(transition.validateForTransmission(model: changed, session: 1))
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertNotNil(transition.failureMessage)
        }
    }

    func testKnownMultipointAlertsRequireTransmissionAndPreserveTheirReplyContracts() throws {
        let state = model()
        for prefix: [UInt8] in [[0x99, 0, 6], [0x99, 0, 7], [0x99, 0, 0x70], [0x99, 6, 1, 1, 6]] {
            for actionType: UInt8 in [0, 1, 2] {
                var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
                let alert = try XCTUnwrap(SonyConnectionAlert(payload: prefix + [actionType]))
                XCTAssertFalse(transition.receiveAlert(alert, session: 1))
                XCTAssertTrue(transition.commandTransmitted(transition.requestPayload, model: state, session: 1))
                XCTAssertFalse(transition.receiveAlert(alert, session: 0))
                XCTAssertTrue(transition.receiveAlert(alert, session: 1))
                XCTAssertEqual(transition.alert, alert)
                XCTAssertTrue(transition.awaitingUser)
                XCTAssertFalse(transition.timeout())
                XCTAssertFalse(transition.requestReadback(model: state, session: 1))
                XCTAssertFalse(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true))
                if actionType == 0 {
                    XCTAssertNil(transition.respond(to: alert, action: .positive))
                    XCTAssertNil(transition.respond(to: alert, action: .negative))
                    XCTAssertTrue(transition.acknowledge(alert))
                } else {
                    XCTAssertFalse(transition.acknowledge(alert))
                    if actionType == 2 { XCTAssertNil(transition.respond(to: alert, action: .negative)) }
                    let reply = try XCTUnwrap(transition.respond(to: alert, action: .positive))
                    XCTAssertEqual(reply, [0x98, prefix[1], prefix[2], 1])
                    XCTAssertEqual(transition.phase, .replyQueued(alert, .positive))
                    XCTAssertFalse(transition.timeout())
                    XCTAssertFalse(transition.commandTransmitted(Array(reply.dropLast()) + [0], model: state, session: 1))
                    XCTAssertTrue(transition.commandTransmitted(reply, model: state, session: 1))
                }
                XCTAssertEqual(transition.phase, .awaitingResponse)
                XCTAssertNil(transition.expectedPayload)
                XCTAssertTrue(transition.requestReadback(model: state, session: 1))
                XCTAssertEqual(transition.phase, .queuedReadback)
                XCTAssertFalse(transition.timeout())
                XCTAssertEqual(transition.expectedPayload, [0xD6, 0xD2])
                XCTAssertTrue(transition.commandTransmitted([0xD6, 0xD2], model: state, session: 1))
                XCTAssertEqual(transition.phase, .verifying)
                XCTAssertTrue(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true))
                XCTAssertEqual(transition.phase, .complete)
                XCTAssertTrue(transition.isFinished)
                XCTAssertNil(transition.failureMessage)
            }
        }
    }

    func testUnrelatedAndUnknownAlertsCannotPauseOrCreateReplies() throws {
        let state = model()
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
        for payload: [UInt8] in [[0x99, 0, 0x74, 1], [0x99, 6, 0x11, 0, 1], [0x99, 0, 1, 1], [0x99, 0, 6, 0xFF]] {
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: payload))
            XCTAssertFalse(transition.receiveAlert(alert, session: 1))
            XCTAssertNil(transition.respond(to: alert, action: .positive))
            XCTAssertFalse(transition.acknowledge(alert))
            XCTAssertEqual(transition.phase, .awaitingResponse)
        }
        XCTAssertTrue(transition.timeout())
        XCTAssertTrue(transition.isFinished)
        XCTAssertFalse(transition.requestReadback(model: state, session: 1))
    }

    func testOnlyOwnedFreshReadbackCanCompleteAndReportedMismatchOrUnknownFails() throws {
        for target in [false, true] {
            let state = model(enabled: !target)
            var waiting = try XCTUnwrap(SonyMultipointTransition(enabled: target, model: state, session: 4))
            let response: [UInt8] = [0xD7, 0xD2, 0, target ? 0 : 1]
            waiting.commandTransmitted(waiting.requestPayload, model: state, session: 4)
            XCTAssertFalse(waiting.receiveReadback(response, model: state, session: 4, readbackOwned: true))
            XCTAssertTrue(waiting.requestReadback(model: state, session: 4))
            XCTAssertFalse(waiting.receiveReadback(response, model: state, session: 4, readbackOwned: true))
            waiting.commandTransmitted([0xD6, 0xD2], model: state, session: 4)
            XCTAssertFalse(waiting.receiveReadback(response, model: state, session: 4))
            XCTAssertFalse(waiting.receiveReadback(response, model: state, session: 3, readbackOwned: true))
            XCTAssertFalse(waiting.receiveReadback([0xD9] + response.dropFirst(), model: state, session: 4, readbackOwned: true))
            XCTAssertFalse(waiting.receiveReadback([0xD7, 0xD4, 0, target ? 0 : 1], model: state, session: 4, readbackOwned: true))
            for invalid in [[0xD7, 0xD2], [0xD7, 0xD2, 1, 0], [0xD7, 0xD2, 0, 0xFF], [0xD7, 0xD2, 0, target ? 1 : 0], response + [0]] {
                var failed = waiting
                XCTAssertTrue(failed.receiveReadback(invalid, model: state, session: 4, readbackOwned: true))
                XCTAssertEqual(failed.phase, .failed)
                XCTAssertNotNil(failed.failureMessage)
                XCTAssertFalse(failed.receiveReadback(response, model: state, session: 4, readbackOwned: true))
            }
            XCTAssertTrue(waiting.receiveReadback(response, model: state, session: 4, readbackOwned: true))
            XCTAssertEqual(waiting.phase, .complete)
            XCTAssertFalse(waiting.controlLost(session: 4))
            XCTAssertFalse(waiting.timeout())
        }
    }

    func testAlertDuringVerificationRequiresNewPostReplyReadbackOwnership() throws {
        let state = model()
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
        transition.requestReadback(model: state, session: 1)
        transition.commandTransmitted([0xD6, 0xD2], model: state, session: 1)
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
        XCTAssertTrue(transition.receiveAlert(alert, session: 1))
        XCTAssertFalse(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true))
        let reply = try XCTUnwrap(transition.respond(to: alert, action: .positive))
        transition.commandTransmitted(reply, model: state, session: 1)
        XCTAssertFalse(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true))
        transition.requestReadback(model: state, session: 1)
        transition.commandTransmitted([0xD6, 0xD2], model: state, session: 1)
        XCTAssertFalse(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: false))
        XCTAssertTrue(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true))
        XCTAssertEqual(transition.phase, .complete)
    }

    func testNegativeReplyCancelsOnlyAfterTransmissionAndCannotBeReplayed() throws {
        let state = model()
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 6, 1]))
        transition.receiveAlert(alert, session: 1)
        let reply = try XCTUnwrap(transition.respond(to: alert, action: .negative))
        XCTAssertEqual(reply, [0x98, 0, 6, 0])
        XCTAssertFalse(transition.isFinished)
        XCTAssertTrue(transition.commandTransmitted(reply, model: state, session: 1))
        XCTAssertEqual(transition.phase, .cancelled)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.commandTransmitted(reply, model: state, session: 1))
        XCTAssertFalse(transition.controlLost(session: 1))
        XCTAssertFalse(transition.controlReady(model: state, session: 2))
        XCTAssertFalse(transition.receiveAlert(alert, session: 1))
        XCTAssertFalse(transition.retryRecovery())
    }

    func testRecoveryReidentifiesSlotInNewSessionAndOnlyReadsWithoutSetterReplay() throws {
        let state = model()
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 4))
        let originalRequest = transition.requestPayload
        let requestID = transition.requestID
        transition.commandTransmitted(originalRequest, model: state, session: 4)
        XCTAssertFalse(transition.controlLost(session: 3))
        XCTAssertTrue(transition.controlLost(session: 4))
        XCTAssertEqual(transition.phase, .recovering)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.timeout())
        XCTAssertFalse(transition.commandTransmitted(originalRequest, model: state, session: 4))
        XCTAssertFalse(transition.controlReady(model: state, session: 4))
        XCTAssertFalse(transition.controlReady(model: SonySystemFeatures(supportedFunctions: [0xD4]), session: 6))
        let discovered = model(enabled: nil, slot: 0xD4, available: nil)
        XCTAssertTrue(transition.controlReady(model: discovered, session: 6))
        XCTAssertEqual(transition.slot, 0xD4)
        XCTAssertEqual(transition.session, 6)
        XCTAssertEqual(transition.requestID, requestID)
        XCTAssertEqual(transition.originalEnabled, false)
        XCTAssertEqual(transition.targetEnabled, true)
        XCTAssertEqual(transition.expectedPayload, [0xD6, 0xD4])
        XCTAssertFalse(transition.commandTransmitted(originalRequest, model: discovered, session: 6))
        XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, model: discovered, session: 6))
        XCTAssertFalse(transition.receiveReadback([0xD7, 0xD4, 0, 0], model: discovered, session: 6, readbackOwned: true))
        XCTAssertTrue(transition.commandTransmitted([0xD6, 0xD4], model: discovered, session: 6))
        XCTAssertFalse(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 4, readbackOwned: true))
        XCTAssertTrue(transition.receiveReadback([0xD7, 0xD4, 0, 0], model: discovered, session: 6, readbackOwned: true))
        XCTAssertEqual(transition.phase, .complete)
        XCTAssertFalse(transition.retryRecovery())
    }

    func testCancellationIntentSurvivesLossBeforeReplyAndCannotBecomeSuccess() throws {
        let state = model()
        for enabled in [false, true] {
            var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
            transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
            transition.receiveAlert(alert, session: 1)
            let reply = try XCTUnwrap(transition.respond(to: alert, action: .negative))
            transition.controlLost(session: 1)
            transition.controlReady(model: state, session: 2)
            XCTAssertFalse(transition.commandTransmitted(reply, model: state, session: 2))
            transition.commandTransmitted([0xD6, 0xD2], model: state, session: 2)
            XCTAssertTrue(transition.receiveReadback([0xD7, 0xD2, 0, enabled ? 0 : 1], model: state, session: 2, readbackOwned: true))
            XCTAssertEqual(transition.phase, enabled ? .failed : .cancelled)
        }
    }

    func testQueuedLossAndRecoveryFailureAreTerminalAndVerificationCanTimeOut() throws {
        let state = model()
        var queued = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        XCTAssertFalse(queued.canRetryRecovery)
        XCTAssertTrue(queued.controlLost(session: 1))
        XCTAssertEqual(queued.phase, .failed)
        XCTAssertFalse(queued.canRetryRecovery)
        XCTAssertFalse(queued.retryRecovery())
        XCTAssertFalse(queued.controlReady(model: state, session: 2))
        var sent = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        XCTAssertFalse(sent.recoveryFailed())
        sent.commandTransmitted(sent.requestPayload, model: state, session: 1)
        sent.controlLost(session: 1)
        var recovering = sent
        XCTAssertTrue(recovering.recoveryFailed())
        XCTAssertEqual(recovering.phase, .failed)
        XCTAssertFalse(recovering.controlReady(model: state, session: 2))
        sent.controlReady(model: state, session: 2)
        XCTAssertFalse(sent.timeout())
        sent.commandTransmitted([0xD6, 0xD2], model: state, session: 2)
        XCTAssertTrue(sent.timeout())
        XCTAssertEqual(sent.phase, .failed)
        XCTAssertNil(sent.expectedPayload)
    }

    func testRetryAfterFailedVerificationReadsAgainWithoutReplayingOrLosingCancellation() throws {
        let state = model()
        for cancel in [false, true] {
            var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
            let requestID = transition.requestID
            transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
            if cancel {
                let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
                transition.receiveAlert(alert, session: 1)
                _ = transition.respond(to: alert, action: .negative)
                transition.controlLost(session: 1)
                transition.recoveryFailed()
            } else {
                transition.timeout()
            }
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertTrue(transition.canRetryRecovery)
            XCTAssertTrue(transition.retryRecovery())
            XCTAssertEqual(transition.phase, .recovering)
            XCTAssertFalse(transition.canRetryRecovery)
            XCTAssertNil(transition.failureMessage)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertFalse(transition.retryRecovery())
            XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, model: state, session: 1))
            XCTAssertTrue(transition.controlReady(model: state, session: 3))
            XCTAssertEqual(transition.requestID, requestID)
            XCTAssertEqual(transition.expectedPayload, [0xD6, 0xD2])
            XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, model: state, session: 3))
            transition.commandTransmitted([0xD6, 0xD2], model: state, session: 3)
            XCTAssertTrue(transition.receiveReadback([0xD7, 0xD2, 0, cancel ? 1 : 0], model: state, session: 3, readbackOwned: true))
            XCTAssertEqual(transition.phase, cancel ? .cancelled : .complete)
        }
    }

    func testDirectiveRecheckRequiresFinishedTransmittedSameSessionAndKeepsCancellation() throws {
        let state = model()
        var unsent = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        XCTAssertFalse(unsent.recheckAfterDirective(session: 1))
        unsent.controlLost(session: 1)
        XCTAssertFalse(unsent.recheckAfterDirective(session: 1))
        for phase: SonyMultipointTransition.Phase in [.complete, .cancelled, .failed] {
            var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
            let requestID = transition.requestID
            transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
            XCTAssertFalse(transition.recheckAfterDirective(session: 1))
            if phase == .cancelled {
                let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
                transition.receiveAlert(alert, session: 1)
                let reply = try XCTUnwrap(transition.respond(to: alert, action: .negative))
                transition.commandTransmitted(reply, model: state, session: 1)
            } else if phase == .complete {
                transition.requestReadback(model: state, session: 1)
                transition.commandTransmitted([0xD6, 0xD2], model: state, session: 1)
                transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true)
            } else {
                transition.timeout()
            }
            XCTAssertEqual(transition.phase, phase)
            XCTAssertEqual(transition.canRetryRecovery, phase == .failed)
            let finished = transition
            XCTAssertFalse(transition.controlLost(session: 1))
            XCTAssertFalse(transition.recheckAfterDirective(session: 0))
            XCTAssertFalse(transition.recheckAfterDirective(session: 2))
            XCTAssertEqual(transition, finished)
            XCTAssertTrue(transition.recheckAfterDirective(session: 1))
            XCTAssertEqual(transition.phase, .recovering)
            XCTAssertNil(transition.failureMessage)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertFalse(transition.recheckAfterDirective(session: 1))
            let discovered = model(enabled: nil, slot: 0xD4, available: nil)
            XCTAssertTrue(transition.controlReady(model: discovered, session: 3))
            XCTAssertEqual(transition.requestID, requestID)
            XCTAssertEqual(transition.expectedPayload, [0xD6, 0xD4])
            XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, model: discovered, session: 3))
            XCTAssertFalse(transition.receiveReadback([0xD7, 0xD4, 0, 0], model: discovered, session: 3, readbackOwned: true))
            transition.commandTransmitted([0xD6, 0xD4], model: discovered, session: 3)
            if phase == .cancelled {
                var changed = transition
                XCTAssertTrue(changed.receiveReadback([0xD7, 0xD4, 0, 0], model: discovered, session: 3, readbackOwned: true))
                XCTAssertEqual(changed.phase, .failed)
            }
            XCTAssertTrue(transition.receiveReadback([0xD7, 0xD4, 0, phase == .cancelled ? 1 : 0], model: discovered, session: 3, readbackOwned: true))
            XCTAssertEqual(transition.phase, phase == .cancelled ? .cancelled : .complete)
        }
    }

    func testSecondMultipointCautionRequiresItsOwnReplyAcknowledgment() throws {
        let state = model()
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
        transition.commandAcknowledged(transition.requestPayload, session: 1)
        let first = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
        let second = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 0x70, 1]))
        XCTAssertTrue(transition.receiveAlert(first, session: 1))
        let firstReply = try XCTUnwrap(transition.respond(to: first, action: .positive))
        transition.commandTransmitted(firstReply, model: state, session: 1)
        transition.commandAcknowledged(firstReply, session: 1)
        XCTAssertTrue(transition.receiveAlert(second, session: 1))
        XCTAssertFalse(transition.timeout())
        XCTAssertNil(transition.respond(to: first, action: .positive))
        let secondReply = try XCTUnwrap(transition.respond(to: second, action: .positive))
        XCTAssertEqual(secondReply, [0x98, 0, 0x70, 1])
        transition.commandTransmitted(secondReply, model: state, session: 1)
        XCTAssertFalse(transition.commandAcknowledged(firstReply, session: 1))
        XCTAssertFalse(transition.commandAcknowledged(secondReply, session: 2))
        var missingAcknowledgment = transition
        missingAcknowledgment.timeout()
        XCTAssertEqual(missingAcknowledgment.phase, .failed)
        XCTAssertTrue(transition.commandAcknowledged(secondReply, session: 1))
        XCTAssertEqual(transition.phase, .awaitingResponse)
        XCTAssertNil(transition.expectedPayload)
        transition.timeout()
        XCTAssertEqual(transition.expectedPayload, [0xD6, 0xD2])
    }

    func testCombinedConfirmationQueuesOneWarningReplyAndStillRequiresOwnedReadback() throws {
        let state = model()
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
        let first = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
        let warning = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 0x70, 1]))
        transition.receiveAlert(first, session: 1)
        let firstReply = try XCTUnwrap(transition.respond(to: first, action: .positive, confirmsSoundQualityWarning: true))
        transition.commandTransmitted(firstReply, model: state, session: 1)
        transition.commandAcknowledged(firstReply, session: 1)
        XCTAssertTrue(transition.receiveAlert(warning, session: 1))
        XCTAssertEqual(transition.phase, .replyQueued(warning, .positive))
        XCTAssertNil(transition.alert)
        XCTAssertEqual(transition.expectedPayload, [0x98, 0, 0x70, 1])
        XCTAssertFalse(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true))
        let reply = try XCTUnwrap(transition.expectedPayload)
        XCTAssertTrue(transition.commandTransmitted(reply, model: state, session: 1))
        XCTAssertFalse(transition.commandAcknowledged(firstReply, session: 1))
        var missingAcknowledgment = transition
        missingAcknowledgment.timeout()
        XCTAssertEqual(missingAcknowledgment.phase, .failed)
        XCTAssertTrue(transition.commandAcknowledged(reply, session: 1))
        var repeated = transition
        XCTAssertTrue(repeated.receiveAlert(warning, session: 1))
        XCTAssertEqual(repeated.alert, warning)
        XCTAssertNil(repeated.expectedPayload)
        XCTAssertTrue(transition.timeout())
        XCTAssertTrue(transition.commandTransmitted([0xD6, 0xD2], model: state, session: 1))
        XCTAssertFalse(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1))
        XCTAssertTrue(transition.receiveReadback([0xD7, 0xD2, 0, 0], model: state, session: 1, readbackOwned: true))
        XCTAssertEqual(transition.phase, .complete)
    }

    func testCombinedConfirmationRequiresInitialEnableReconnectAlertAndPositiveChoice() throws {
        let warning = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 0x70, 1]))
        for enabled in [false, true] {
            let state = model(enabled: !enabled)
            for payload: [UInt8] in [[0x99, 0, 6, 1], [0x99, 0, 7, 1], [0x99, 0, 7, 2], [0x99, 6, 1, 0, 1]] {
                for action: SonyConnectionAlertAction in [.negative, .positive] {
                    let first = try XCTUnwrap(SonyConnectionAlert(payload: payload))
                    var transition = try XCTUnwrap(SonyMultipointTransition(enabled: enabled, model: state, session: 1))
                    transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
                    transition.receiveAlert(first, session: 1)
                    guard let reply = transition.respond(to: first, action: action, confirmsSoundQualityWarning: true) else { continue }
                    transition.commandTransmitted(reply, model: state, session: 1)
                    if action == .negative {
                        XCTAssertEqual(transition.phase, .cancelled)
                        XCTAssertFalse(transition.receiveAlert(warning, session: 1))
                    } else {
                        XCTAssertTrue(transition.receiveAlert(warning, session: 1))
                        if enabled && payload == [0x99, 0, 7, 1] {
                            XCTAssertEqual(transition.phase, .replyQueued(warning, .positive))
                        } else {
                            XCTAssertEqual(transition.alert, warning)
                            XCTAssertNil(transition.expectedPayload)
                        }
                    }
                }
            }
        }
    }

    func testCombinedConfirmationDoesNotCoverDifferentWarningOrActionType() throws {
        let state = model()
        let first = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
        let warning = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 0x70, 1]))
        for payload: [UInt8] in [[0x99, 0, 6, 1], [0x99, 0, 7, 1], [0x99, 0, 0x70, 0], [0x99, 0, 0x70, 2], [0x99, 0, 0x70, 0xFF], [0x99, 6, 1, 0, 1]] {
            var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
            transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
            transition.receiveAlert(first, session: 1)
            let reply = try XCTUnwrap(transition.respond(to: first, action: .positive, confirmsSoundQualityWarning: true))
            transition.commandTransmitted(reply, model: state, session: 1)
            let other = try XCTUnwrap(SonyConnectionAlert(payload: payload))
            if case .unknown = other.actionType {
                XCTAssertFalse(transition.receiveAlert(other, session: 1))
            } else {
                XCTAssertTrue(transition.receiveAlert(other, session: 1))
                XCTAssertEqual(transition.alert, other)
                XCTAssertNil(transition.expectedPayload)
                if other.actionType == .confirmationOnly {
                    transition.acknowledge(other)
                } else {
                    let reply = try XCTUnwrap(transition.respond(to: other, action: .positive, confirmsSoundQualityWarning: true))
                    transition.commandTransmitted(reply, model: state, session: 1)
                }
            }
            XCTAssertTrue(transition.receiveAlert(warning, session: 1))
            XCTAssertEqual(transition.alert, warning)
            XCTAssertNil(transition.expectedPayload)
        }
    }

    func testCombinedConfirmationCannotCarryAcrossControlSessionOrNewRequest() throws {
        let state = model()
        let first = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 7, 1]))
        let warning = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 0x70, 1]))
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        transition.commandTransmitted(transition.requestPayload, model: state, session: 1)
        transition.receiveAlert(first, session: 1)
        let reply = try XCTUnwrap(transition.respond(to: first, action: .positive, confirmsSoundQualityWarning: true))
        transition.commandTransmitted(reply, model: state, session: 1)
        XCTAssertFalse(transition.receiveAlert(warning, session: 2))
        transition.controlLost(session: 1)
        transition.controlReady(model: state, session: 2)
        XCTAssertFalse(transition.receiveAlert(warning, session: 1))
        XCTAssertTrue(transition.receiveAlert(warning, session: 2))
        XCTAssertEqual(transition.alert, warning)
        XCTAssertNil(transition.expectedPayload)
        var newRequest = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 2))
        XCTAssertFalse(newRequest.receiveAlert(warning, session: 2))
        newRequest.commandTransmitted(newRequest.requestPayload, model: state, session: 2)
        XCTAssertTrue(newRequest.receiveAlert(warning, session: 2))
        XCTAssertEqual(newRequest.alert, warning)
        XCTAssertNil(newRequest.expectedPayload)
    }

    // Replies captured from a WH-1000XM4 (MDR v1, firmware 3.0.1).
    private static let legacyTouchPanel: [UInt8] = [0xD1, 0xD1, 0x02, 0x13] + Array("TOUCH_PANEL_SETTING".utf8) + [0x00, 0x01, 0x00]
    private static let legacyMultipoint: [UInt8] = [0xD1, 0xD2, 0x02, 0x12] + Array("MULTIPOINT_SETTING".utf8)
        + [0x1A] + Array("MULTIPOINT_SETTING_SUMMARY".utf8) + [0x01, 0x00]

    func testLegacyGeneralSettingsUseTheV1LayoutAndOneForOn() throws {
        var model = SonySystemFeatures(legacyGeneralSettings: [0x11, 0x62, 0xD1, 0xD2, 0xF4])
        XCTAssertEqual(model.generation, .v1)
        XCTAssertNil(model.voiceAssistant)
        XCTAssertNil(model.automaticPowerOff)
        XCTAssertEqual(model.queryPayloads, [[0xD0, 0xD1, 0x01], [0xD0, 0xD2, 0x01]])
        XCTAssertTrue(model.update(Self.legacyTouchPanel))
        XCTAssertNil(model.multipointSlot)
        XCTAssertTrue(model.update(Self.legacyMultipoint))
        XCTAssertEqual(model.multipointSlot, 0xD2)
        XCTAssertTrue(model.generalSettingsAreIdentified)
        XCTAssertEqual(model.queryPayloads, [[0xD2, 0xD2], [0xD6, 0xD2]])
        XCTAssertTrue(model.update([0xD3, 0xD2, 0x00]))
        XCTAssertFalse(model.update([0xD7, 0xD2, 0x00, 0x01]))
        XCTAssertTrue(model.update([0xD7, 0xD2, 0x01, 0x01]))
        XCTAssertEqual(model.multipoint?.enabled, true)
        XCTAssertEqual(model.multipointSetPayload(enabled: false), [0xD8, 0xD2, 0x01, 0x00])
        XCTAssertTrue(model.update([0xD9, 0xD2, 0x01, 0x00]))
        XCTAssertEqual(model.multipoint?.enabled, false)
        XCTAssertEqual(model.multipointSetPayload(enabled: true), [0xD8, 0xD2, 0x01, 0x01])
        XCTAssertTrue(model.update([0xD7, 0xD2, 0x01, 0x02]))
        XCTAssertNil(model.multipoint?.enabled)
        XCTAssertNil(model.multipointSetPayload(enabled: true))

        var malformed = SonySystemFeatures(legacyGeneralSettings: [0xD2])
        XCTAssertFalse(malformed.update(Array(Self.legacyMultipoint.dropLast())))
        XCTAssertFalse(malformed.update(Array(Self.legacyMultipoint.dropLast(2))))
        var modern = SonySystemFeatures(supportedFunctions: [0xD2])
        XCTAssertFalse(modern.update(Self.legacyMultipoint))
        XCTAssertNil(modern.multipointSlot)
    }

    func testLegacyMultipointEnableUsesV1SetterAndAcceptsTheLDACWarning() throws {
        var state = SonySystemFeatures(legacyGeneralSettings: [0xD2])
        state.update(Self.legacyMultipoint)
        state.update([0xD3, 0xD2, 0x00])
        state.update([0xD7, 0xD2, 0x01, 0x00])
        var transition = try XCTUnwrap(SonyMultipointTransition(enabled: true, model: state, session: 1))
        XCTAssertEqual(transition.requestPayload, [0xD8, 0xD2, 0x01, 0x01])
        XCTAssertEqual(transition.expectedPayload, [0xD8, 0xD2, 0x01, 0x01])
        XCTAssertTrue(transition.commandTransmitted([0xD8, 0xD2, 0x01, 0x01], model: state, session: 1))
        let warning = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x01, 0x06, 0x01], generation: .v1))
        XCTAssertTrue(warning.isMultipointChange)
        XCTAssertFalse(warning.isLegacyConnectionChange)
        XCTAssertNil(SonyConnectionAlert(payload: [0x99, 0x01, 0x06, 0x01]))
        XCTAssertTrue(transition.receiveAlert(warning, session: 1))
        XCTAssertEqual(transition.alert, warning)
        XCTAssertEqual(transition.respond(to: warning, action: .positive), [0x98, 0x01, 0x06, 0x01])
        XCTAssertTrue(transition.commandTransmitted([0x98, 0x01, 0x06, 0x01], model: state, session: 1))
        XCTAssertTrue(transition.controlLost(session: 1))
        var restarted = SonySystemFeatures(legacyGeneralSettings: [0xD2])
        restarted.update(Self.legacyMultipoint)
        XCTAssertTrue(transition.controlReady(model: restarted, session: 2))
        XCTAssertEqual(transition.expectedPayload, [0xD6, 0xD2])
        XCTAssertTrue(transition.commandTransmitted([0xD6, 0xD2], model: restarted, session: 2))
        XCTAssertTrue(transition.receiveReadback([0xD7, 0xD2, 0x01, 0x01], model: restarted, session: 2, readbackOwned: true))
        XCTAssertEqual(transition.phase, .complete)

        let off = try XCTUnwrap(SonyMultipointTransition(enabled: false, model: { var on = state; on.update([0xD7, 0xD2, 0x01, 0x01]); return on }(), session: 3))
        XCTAssertEqual(off.requestPayload, [0xD8, 0xD2, 0x01, 0x00])
        XCTAssertFalse(SonyConnectionAlert(payload: [0x99, 0x01, 0x07, 0x01], generation: .v1)!.isMultipointChange)
    }

    private func model(enabled: Bool? = false, slot: UInt8 = 0xD2, available: Bool? = true) -> SonySystemFeatures {
        var model = SonySystemFeatures(supportedFunctions: [slot])
        let title = Array("MULTIPOINT_SETTING".utf8)
        model.update([0xD1, slot, 0, 1, UInt8(title.count)] + title + [0])
        if let available { model.update([0xD3, slot, available ? 0 : 1]) }
        if let enabled { model.update([0xD7, slot, 0, enabled ? 0 : 1]) }
        return model
    }
}
