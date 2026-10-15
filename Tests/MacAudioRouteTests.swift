import CoreAudio
import Darwin
import Foundation
import XCTest
@testable import Acouplet

final class MacAudioRouteTests: XCTestCase {
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func testLDACLogPredicateRetainsOwnershipEventsAndRejectsUnrelatedTraffic() {
        let predicate = NSPredicate(format: LDACNativeSession.daemonPredicate)
        for message in [
            "connectedCB cid:0x0040 inMTU:100 outMTU:100 result:0",
            "l2capDisconnected for CID: 0x0040",
            "l2capDataInd for CID: 0x0040, len: 0x0002",
            "ACL connected: 02-00-00-00-00-01, result 0",
            "ACL disconnected: 02-00-00-00-00-01, result 0, reason 10722",
            "Received connection result for \"A2DP Source\" profile on device 02-00-00-00-00-01 result was 0"
        ] {
            XCTAssertTrue(predicate.evaluate(with: ["process": "bluetoothd", "eventMessage": message]))
            XCTAssertTrue(predicate.evaluate(with: ["process": "bluetoothd", "eventMessage": message.uppercased()]))
            XCTAssertFalse(predicate.evaluate(with: ["process": "unrelated", "eventMessage": message]))
        }
        for message in ["PipeMgr: Write completed", "Advertising state changed", "Device scan result"] {
            XCTAssertFalse(predicate.evaluate(with: ["process": "bluetoothd", "eventMessage": message]))
        }
    }

    func testLDACChildDrainsFinalOutputAfterProcessExit() throws {
        let child = try LDACNativeChild(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                        arguments: ["first\nsecond"], inheritedPCM: nil)
        defer { child.signal(SIGKILL); child.wait() }
        child.wait()
        XCTAssertEqual(try drain(child), ["first", "second"])
        XCTAssertEqual(child.exitCode, 0)
    }

    func testLDACChildHandlesInputClosureAndCancellation() throws {
        let child = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], inheritedPCM: nil)
        defer { child.signal(SIGKILL); child.wait() }
        var descriptor = pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 10), 0)
        try child.send("round-trip")
        child.closeInput()
        XCTAssertEqual(try drain(child), ["round-trip"])
        child.wait()
        XCTAssertEqual(child.exitCode, 0)

        let cancelled = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], inheritedPCM: nil)
        defer { cancelled.signal(SIGKILL); cancelled.wait() }
        cancelled.signal(SIGTERM)
        XCTAssertTrue(try drain(cancelled).isEmpty)
        cancelled.wait()
        XCTAssertNotEqual(cancelled.status, 0)
    }

    func testLDACChildRejectsOversizedStatusOutput() throws {
        let child = try LDACNativeChild(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                        arguments: [String(repeating: "x", count: 8193) + "\n"], inheritedPCM: nil)
        defer { child.signal(SIGKILL); child.wait() }
        XCTAssertThrowsError(try drain(child))
    }

    func testLDACShutdownKeepsDeadlineWhenMediaInputIsFull() throws {
        let media = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { media.signal(SIGKILL); media.wait() }
        let capture = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { capture.signal(SIGKILL); capture.wait() }
        var blocked = false
        for _ in 0..<262_144 {
            do { try media.send("stop") }
            catch let error as POSIXError where error.code == .EAGAIN {
                blocked = true
                break
            }
        }
        XCTAssertTrue(blocked)
        guard blocked else { return }

        let failure = expectation(description: "The failed stop command is reported")
        let session = LDACNativeSession(id: UUID(), address: "02-00-00-00-00-01", helpers: .init(bundle: .main), gain: 0,
            priority: LDACPriorityControl(request: { _, _ in }, state: { .init(phase: "idle", error: nil) })) { event in
                if case .failed = event { failure.fulfill() }
            }
        session.simulateStartedMediaShutdown(media: media, capture: capture)
        let began = DispatchTime.now()
        session.advanceSimulatedShutdown()
        XCTAssertGreaterThanOrEqual(session.simulatedMediaStopDeadline, began)
        XCTAssertLessThanOrEqual(session.simulatedMediaStopDeadline, DispatchTime.now() + 5)

        session.advanceSimulatedShutdown()
        XCTAssertTrue(try drain(capture).isEmpty)
        guard capture.outputEnded else { return }
        capture.wait()
        XCTAssertNotNil(capture.status)
        XCTAssertNil(media.status)

        session.advanceSimulatedShutdown(mediaDeadline: DispatchTime(uptimeNanoseconds: 0))
        XCTAssertTrue(try drain(media).isEmpty)
        guard media.outputEnded else { return }
        media.wait()
        XCTAssertEqual(try XCTUnwrap(media.status) & 0x7F, SIGKILL)
        wait(for: [failure], timeout: 1)
    }

    private func drain(_ child: LDACNativeChild) throws -> [String] {
        let deadline = Date().addingTimeInterval(2)
        var lines: [String] = []
        while !child.outputEnded && Date() < deadline {
            var descriptor = pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 50) > 0 { lines += try child.readLines() }
            child.reap()
        }
        XCTAssertTrue(child.outputEnded)
        return lines
    }
    #endif

    func testDiagnosticsOmitOutputNameAndUIDWhilePreservingTransportAndFormat() {
        let route = MacAudioRoute(deviceID: 123, name: "Private living room speaker",
            uid: "private-output-identifier", transport: MacAudioTransport(rawValue: kAudioDeviceTransportTypeBluetooth),
            outputChannels: 2, nominalSampleRate: 96_000)
        let report = route.diagnosticReport
        XCTAssertFalse(report.contains(route.name!))
        XCTAssertFalse(report.contains(route.uid!))
        XCTAssertFalse(report.contains("Output UID:"))
        XCTAssertTrue(report.contains("Output transport: Bluetooth Classic"))
        XCTAssertTrue(report.contains(route.pcmFormatDescription))
    }

    func testChannelCountRejectsTruncatedAndOverflowingBufferLists() {
        func configuration(_ channels: [UInt32]) -> Data {
            let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
            var data = Data(count: offset + channels.count * MemoryLayout<AudioBuffer>.stride)
            data.withUnsafeMutableBytes { bytes in
                bytes.storeBytes(of: UInt32(channels.count), as: UInt32.self)
                for (index, count) in channels.enumerated() {
                    bytes.storeBytes(of: count, toByteOffset: offset + index * MemoryLayout<AudioBuffer>.stride, as: UInt32.self)
                }
            }
            return data
        }

        XCTAssertEqual(MacAudioRoute.channelCount(in: configuration([])), 0)
        XCTAssertEqual(MacAudioRoute.channelCount(in: configuration([2])), 2)
        XCTAssertEqual(MacAudioRoute.channelCount(in: configuration([1, 1])), 2)
        XCTAssertNil(MacAudioRoute.channelCount(in: Data()))
        XCTAssertNil(MacAudioRoute.channelCount(in: Data(configuration([2]).dropLast())))
        XCTAssertNil(MacAudioRoute.channelCount(in: configuration([UInt32.max, 1])))
    }

    func testUSBAndLETransportDoNotClaimAWirelessCodec() {
        let usb = MacAudioRoute(
            deviceID: 123,
            name: "USB transmitter",
            uid: "test-usb-output",
            transport: MacAudioTransport(rawValue: kAudioDeviceTransportTypeUSB),
            outputChannels: 2,
            nominalSampleRate: 96_000
        )
        XCTAssertEqual(usb.transport?.title, "USB")
        XCTAssertEqual(MacAudioTransport(rawValue: kAudioDeviceTransportTypeBluetoothLE).title, "Bluetooth LE")
        XCTAssertTrue(usb.pcmFormatDescription.contains("kHz"))
        XCTAssertTrue(usb.pcmFormatDescription.contains("PCM"))
        XCTAssertFalse(usb.pcmFormatDescription.contains("LDAC"))
        XCTAssertFalse(usb.pcmFormatDescription.contains("LC3"))
        XCTAssertEqual(MacAudioTransport(rawValue: 0x12345678).title,
                       String(format: String(localized: "Other (0x%08X)"), 0x12345678))
    }
}
