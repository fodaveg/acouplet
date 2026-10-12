import AppKit
import OSLog
import PreferencePanes
import SwiftUI

@MainActor
@objc(SonyPreferencePane)
final class SonyPreferencePane: NSPreferencePane {
    private let client: SonyPreferencePaneClient
    private let logger = Logger(subsystem: "dev.baglayan.Acouplet.preference-pane", category: "lifecycle")

    override init(bundle: Bundle) {
        client = MainActor.assumeIsolated {
            SonyPreferencePaneClient(pinnedAddress: bundle.object(forInfoDictionaryKey: "SonyDeviceAddress") as? String,
                                     appTeam: bundle.object(forInfoDictionaryKey: SonyPreferencePaneWire.appTeamInfoKey) as? String)
        }
        super.init(bundle: bundle)
    }

    nonisolated override func loadMainView() -> NSView {
        let view = MainActor.assumeIsolated { [client, logger] in
            logger.notice("loadMainView")
            let view = NSHostingView(rootView: SonyPreferencePaneView(client: client))
            view.sizingOptions = []
            view.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
            view.autoresizingMask = [.width, .height]
            return view
        }
        mainView = view
        return view
    }

    nonisolated override func willSelect() {
        super.willSelect()
        MainActor.assumeIsolated { [client, logger] in
            logger.notice("willSelect")
            client.start()
        }
    }

    nonisolated override func didUnselect() {
        MainActor.assumeIsolated { [client, logger] in
            logger.notice("didUnselect")
            client.stop()
        }
        super.didUnselect()
    }
}
