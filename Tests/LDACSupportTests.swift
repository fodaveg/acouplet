import Foundation
import XCTest
@testable import Acouplet

final class LDACSupportTests: XCTestCase {
    func testDecisionHasThreeStates() {
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: false, discovered: true), .supported)
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: false, discovered: false), .unsupported)
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: false, discovered: nil), .unknown)
    }

    func testModelThatOffersLDACIsNeverUnsupported() {
        // A DISCOVER taken with multipoint on lists only SBC and AAC for a WH-1000XM4.
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: true, discovered: false), .supported)
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: true, discovered: nil), .supported)
        XCTAssertTrue(SonyDeviceModel.whXM4.offersLDACOnlyWithoutMultipoint)
        XCTAssertFalse(SonyDeviceModel.wfC710N.offersLDACOnlyWithoutMultipoint)
    }

    func testUnsupportedBeatsTheStoredRequest() {
        XCTAssertFalse(LDACSupport.unsupported.allowsStart(requested: true))
        XCTAssertTrue(LDACSupport.unknown.allowsStart(requested: true))
        XCTAssertTrue(LDACSupport.supported.allowsStart(requested: true))
        for support in [LDACSupport.supported, .unsupported, .unknown] {
            XCTAssertFalse(support.allowsStart(requested: false))
        }
    }

    func testStoreKeepsTheLastDiscoverPerAddress() throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LDACSupportStore(defaults: defaults)
        XCTAssertNil(store.discovered(forAddress: "AA-BB-CC-DD-EE-01"))
        store.record(false, forAddress: "AA-BB-CC-DD-EE-01")
        store.record(true, forAddress: "AA-BB-CC-DD-EE-02")
        let reopened = LDACSupportStore(defaults: defaults)
        XCTAssertEqual(reopened.discovered(forAddress: "AA-BB-CC-DD-EE-01"), false)
        XCTAssertEqual(reopened.discovered(forAddress: "AA-BB-CC-DD-EE-02"), true)
        store.record(true, forAddress: "AA-BB-CC-DD-EE-01")
        XCTAssertEqual(LDACSupportStore(defaults: defaults).discovered(forAddress: "AA-BB-CC-DD-EE-01"), true)
    }

    func testSupportListLineHasModelVersionAndEveryFunctionButNoAddress() {
        let line = SonySupportFunctionsLog.line(generation: "v2", table: 1, model: "WF-C710N",
                                                protocolVersion: 0x03003018, functions: [0xE7, 0x12, 0x0A])
        XCTAssertEqual(line, "MDR support list generation=v2 table=1 model=WF-C710N protocol=03003018 count=3 functions=0A 12 E7")
        XCTAssertTrue(SonySupportFunctionsLog.line(generation: "v1", table: 1, model: "X", protocolVersion: nil, functions: [])
            .hasSuffix("protocol=unknown count=0 functions="))
    }
}
