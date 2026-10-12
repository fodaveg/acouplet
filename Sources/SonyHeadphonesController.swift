import Combine
import CoreBluetooth
import Foundation
import OSLog
@preconcurrency import IOBluetooth

protocol SonyServiceRecord: AnyObject {
    func getRFCOMMChannelID(_ channelID: UnsafeMutablePointer<BluetoothRFCOMMChannelID>!) -> IOReturn
}

extension IOBluetoothSDPServiceRecord: SonyServiceRecord {}

protocol SonyBluetoothDevice: AnyObject where Self: NSObject {
    var name: String! { get }
    var addressString: String! { get }
    func isClassicConnected() -> Bool
    func isPaired() -> Bool
    func openConnection(_ target: Any!) -> IOReturn
    func sonyServiceRecord(for uuid: IOBluetoothSDPUUID) -> (any SonyServiceRecord)?
    func performSonySDPQuery(_ target: any SonyServiceDiscoveryDelegate) -> IOReturn
    func openSonyRFCOMMChannel(withChannelID channelID: BluetoothRFCOMMChannelID, delegate: Any) -> (IOReturn, (any RFCOMMChannel)?)
}

protocol SonyServiceDiscoveryDelegate: AnyObject {
    @MainActor func sonySDPQueryComplete(_ device: any SonyBluetoothDevice, status: IOReturn)
}

extension IOBluetoothDevice: SonyBluetoothDevice {
    func isClassicConnected() -> Bool {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        if let connected = SonyBLEIdentity.classicConnectionState(for: self) { return connected }
        #endif
        return isConnected()
    }

    func sonyServiceRecord(for uuid: IOBluetoothSDPUUID) -> (any SonyServiceRecord)? {
        getServiceRecord(for: uuid)
    }

    func performSonySDPQuery(_ target: any SonyServiceDiscoveryDelegate) -> IOReturn {
        performSDPQuery(target)
    }

    func openSonyRFCOMMChannel(withChannelID channelID: BluetoothRFCOMMChannelID, delegate: Any) -> (IOReturn, (any RFCOMMChannel)?) {
        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = openRFCOMMChannelAsync(&openedChannel, withChannelID: channelID, delegate: delegate)
        return (result, openedChannel)
    }
}

@MainActor
final class SonyHeadphonesController: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case searching, disconnected, opening, handshaking, ready, controlBusy
        case failed(String)
    }

    enum PowerOffState: Equatable {
        case sending, acknowledged, disconnected, unconfirmed
    }

    enum Setting: Hashable {
        case dsee
        case legacySoundEffect(SonyLegacySoundEffect.Kind)
        case system(SonySystemFeature)
        case automaticPowerOff, voiceAssistant, sidetone, touchAssignments, touchCustomActions, speakToChatOptions
        case voiceGuidance, voiceGuidanceVolume
        case batteryCare, autoPowerSave, powerSaveEffect
        case equalizer, equalizerReadback, playbackVolume, callVolume, noiseControl
    }

    private struct BatteryRead {
        let id = UUID()
        var transmitted = false
        var isObsolete = false
        var timedOut = false
        var timeout: DispatchWorkItem?
    }

    private struct PowerRead {
        let id = UUID()
        let features: SonyPowerFeatures
        var setting: Setting
        var requestID: UUID?
        var resolvesUnconfirmed = false
        var transmitted = false
        var isObsolete = false
        var isRetired = false
        var timedOut = false
        var timeout: DispatchWorkItem?
    }

    private struct NoiseControlRead {
        let asmType: UInt8
        let requestID: UUID?
        let resolvesUnconfirmed: Bool
        var isObsolete = false
        var timedOut = false
    }

    private struct LegacySettingRead {
        let requestID: UUID?
        let resolvesUnconfirmed: Bool
        var isObsolete = false
    }

    private struct SystemRead {
        var id = UUID()
        var requestID: UUID?
        var errorSetting: Setting?
        var resolvesUnconfirmed = false
        var transmitted = false
        var isObsolete = false
        var isRetiredSidetoneRead = false
        var timedOut = false
        var timeout: DispatchWorkItem?
    }

    private struct EqualizerRead {
        let id = UUID()
        let setting: Setting?
        let requestID: UUID?
        var unconfirmedRequestID: UUID?
        var transmitted = false
        var timedOut = false
    }

    private struct DiscoveryRead {
        var id = UUID()
        var transmitted = false
        var retryTransmitted = false
        var retried = false
        var resolved = false
        var timeout: DispatchWorkItem?
    }

    private struct InventoryRead {
        let id = UUID()
        let requestID: UUID?
        var transmitted = false
        var timedOut = false
    }

    private struct PlaybackRead {
        let id = UUID()
        let sourceGeneration: UInt64
        let requestID: UUID?
        let resolvesUnconfirmed: Bool
        var timedOut = false
        var isObsolete = false
        var refreshRequested = false
    }

    private struct SoundPressureRead {
        let id = UUID()
        let generation: UInt64
        var transmitted = false
        var timedOut = false
    }

    private struct WearingStatusRead {
        let id = UUID()
        let generation: UInt64
        var transmitted = false
        var timedOut = false
    }

    private struct ClassicWrite {
        let data: NSMutableData
        let channel: any RFCOMMChannel
        let session: UInt64
        let waitsForResponse: Bool
        var hasStarted = false
        let timeout: DispatchWorkItem
        let completion: () -> Void
    }

    private struct MultipointConnection {
        let device: (any SonyBluetoothDevice)?
        let address: String
        let model: SonyDeviceModel
        let hash: String?
        let peripheralID: UUID?
        let usesBLE: Bool
        let controlAddresses: Set<String>
    }

    @Published private(set) var deviceName = String(localized: "Sony headphones")
    @Published private(set) var address = ""
    @Published private(set) var isDeviceConnected = false
    @Published private(set) var linkState: LinkState = .searching
    @Published private(set) var powerOffState: PowerOffState?
    @Published private(set) var noiseControlMode: NoiseControlMode?
    @Published private(set) var ambientLevel = 10
    @Published private(set) var focusOnVoice = false
    @Published private(set) var noiseControl: SonyNoiseControl?
    @Published private(set) var noiseControlDisplayState: SonyNoiseControl.State?
    let noiseModeChanges = PassthroughSubject<SonyNoiseModeChange, Never>()
    let audioSourceChanges = PassthroughSubject<SonyMultipointDevice, Never>()
    @Published private(set) var batteries = SonyBatteries()
    @Published private(set) var isChargingInCase = false
    private var chargingCaseTimeout: DispatchWorkItem?
    private var caseBatteryObservedAt: Date?
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @Published private(set) var nativeBatterySnapshot: SonyNativeBatterySnapshot?
    #endif
    @Published private(set) var lowBatteryReadings: [SonyLowBatteryPolicy.Reading] = []
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private let nativeAppearanceRefresh: SonyNativeAppearanceRefresh?
    #endif

    var notificationSession: UInt64 { controlSession }
    var lowBatteryNotificationDeviceID: String? {
        guard !isSimulated, isReady, isDeviceConnected, deviceModel != .unknown else { return nil }
        return SonyBLEIdentity.normalizedAddress(address)
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func nativeBatteryPublication(at date: Date) -> SonyNativeBatteryPublication? {
        guard !isSimulated, isReady, isDeviceConnected, deviceModel == .wfXM5,
              let snapshot = nativeBatterySnapshot, let device, device.isClassicConnected(),
              let identity = verifiedIdentity(for: device), identity.hash == bluetoothLEHash,
              identity.peripheralIdentifier == snapshot.identifier else { return nil }
        return SonyNativeBatteryPublication(address: address, controlSession: controlSession, snapshot: snapshot, at: date)
    }

    func nativeCaseBatteryPublication(at date: Date) -> SonyNativeCaseBatteryPublication? {
        guard !isSimulated, isReady, isDeviceConnected, deviceModel == .wfXM5,
              let snapshot = nativeBatterySnapshot, let device, device.isClassicConnected(),
              let identity = verifiedIdentity(for: device), identity.hash == bluetoothLEHash,
              identity.peripheralIdentifier == snapshot.identifier else { return nil }
        return SonyNativeCaseBatteryPublication(address: address, controlSession: controlSession, snapshot: snapshot, at: date)
    }
    #endif
    @Published private(set) var availableNoiseModes: [NoiseControlMode] = [.off, .anc, .ambient]
    @Published private(set) var isApplyingChange = false
    @Published private(set) var equalizer = SonyEqualizer()
    var equalizerPreset: EqualizerPreset? { equalizer.presetID.flatMap(EqualizerPreset.init(rawValue:)) }
    @Published private(set) var customEqualizer = EqualizerSettings.flat
    @Published private(set) var equalizerReadbackID: UUID?
    @Published private var requestedEqualizerPayload: [UInt8]?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var firmwareUpdateIdentity: SonyFirmwareUpdateIdentity?
    @Published private(set) var protocolVersion: UInt32?
    @Published private(set) var protocolInformation: SonyProtocolInfo?
    @Published private(set) var legacyControls: SonyLegacyControls?
    @Published private(set) var legacySurround = SonyLegacySoundEffect(kind: .surround)
    @Published private(set) var legacySoundPosition = SonyLegacySoundEffect(kind: .soundPosition)
    @Published private(set) var legacyOptimizer = SonyLegacyOptimizer()
    @Published private(set) var legacyOptimizerTransition: SonyLegacyOptimizerTransition?
    @Published private(set) var deviceInformation = SonyDeviceInformation()
    @Published private(set) var audioFeatures = SonyAudioFeatures()
    @Published private(set) var systemFeatures = SonySystemFeatures()
    @Published private(set) var powerFeatures = SonyPowerFeatures()
    @Published private(set) var touchAssignments = SonyTouchAssignments()
    @Published private(set) var voiceGuidance = SonyVoiceGuidance()
    @Published private(set) var earTipFit = SonyEarTipFit()
    @Published private(set) var earTipFitTransition: SonyEarTipFitTransition?
    @Published private(set) var headGesturePractice = SonyHeadGesturePractice()
    @Published private(set) var headGesturePracticeTransition: SonyHeadGesturePracticeTransition?
    @Published private(set) var earbudFinder: EarbudFinderController?
    private var earbudFinderObservation: AnyCancellable?
    @Published private(set) var soundPressure = SonySoundPressure()
    @Published private(set) var soundPressureReadError: String?
    @Published private(set) var soundPressureAutomaticRefreshSuspended = false
    @Published private var soundPressureRead: SoundPressureRead?
    @Published private(set) var wearingStatus = SonyWearingStatus()
    @Published private(set) var wearingStatusReadID: UUID?
    @Published private(set) var playback = SonyPlayback()
    @Published private var table2CapabilitiesSession: UInt64?
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @Published private(set) var musicVolumeReadbackID: UUID?
    @Published private(set) var musicStatusReadbackID: UUID?
    #endif
    @Published private(set) var pendingPlaybackCommand: SonyPlaybackCommand?
    @Published private(set) var playbackReadError: String?
    @Published private(set) var multipoint = SonyMultipoint()
    @Published private(set) var sourceTransition: SonySourceTransition?
    @Published private(set) var deviceActionTransition: SonyDeviceActionTransition?
    @Published private(set) var multipointTransition: SonyMultipointTransition?
    @Published private var inventoryRead: InventoryRead?
    @Published private(set) var lastConnectionAlert: SonyConnectionAlert?
    @Published private(set) var connectionTransition: SonyConnectionTransition?
    @Published private(set) var connectionModeError: String?
    @Published private(set) var pendingChanges: [Setting: [UInt8]] = [:]
    @Published private(set) var settingErrors: [Setting: String] = [:]
    @Published private(set) var supportedFunctions: Set<UInt8> = []
    @Published private(set) var supportedFunctions2: Set<UInt8> = []
    @Published private(set) var controlChannelID: Int?
    @Published private(set) var usesBluetoothLE = false
    @Published private(set) var controlPeripheralID: UUID?
    @Published private(set) var bluetoothLEError: String?
    private var bluetoothLEDiagnosticError: String?
    @Published private(set) var bluetoothLEHash: String?
    @Published private(set) var retrySecondsRemaining: Int?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastErrorMessage: String?

    var deviceModel: SonyDeviceModel {
        if let reportedModel = deviceInformation.model { return reportedModel }
        let advertisedModel = SonyDeviceModel(name: deviceName)
        if advertisedModel == .unknown, let savedIdentity, savedIdentity.classicAddress == address {
            return savedIdentity.model
        }
        return advertisedModel
    }
    var usesProductArtwork: Bool { deviceModel.artwork != nil }
    var productArtworkSuffix: String {
        #if DEBUG
        if let simulatedArtworkSuffix { return simulatedArtworkSuffix }
        #endif
        return deviceModel.artworkSuffix(for: deviceInformation.color) ?? ""
    }
    var supportsDSEE: Bool { legacyControls?.dsee.isSupported ?? audioFeatures.supportsDSEE }
    var dseeType: SonyDSEEType? { legacyControls == nil ? audioFeatures.dseeType : legacyControls?.dsee.type }
    var dseeMode: SonyDSEEMode? { legacyControls == nil ? audioFeatures.dseeMode : legacyControls?.dsee.mode }
    var dseeAvailable: Bool? { legacyControls == nil ? audioFeatures.dseeAvailable : legacyControls?.dsee.available }
    var canSetDSEE: Bool {
        guard isReady, pendingChanges[.dsee] == nil, unconfirmedChanges[.dsee] == nil else { return false }
        return legacyControls?.dsee.canSet ?? (audioFeatures.dseeAvailable == true && audioFeatures.dseeMode?.sonyValue != nil)
    }

    func legacySoundEffect(_ kind: SonyLegacySoundEffect.Kind) -> SonyLegacySoundEffect {
        kind == .surround ? legacySurround : legacySoundPosition
    }

    func canSetLegacySoundEffect(_ kind: SonyLegacySoundEffect.Kind) -> Bool {
        isReady && protocolInformation?.generation == .v1 && powerOffState == nil && !isRunningHeadphoneTest
            && connectionTransition?.isFinished != false && sourceTransition?.isFinished != false
            && deviceActionTransition?.isFinished != false && multipointTransition?.isFinished != false
            && pendingChanges[.legacySoundEffect(kind)] == nil && unconfirmedChanges[.legacySoundEffect(kind)] == nil
            && legacySoundEffect(kind).canSet
    }
    var showsMenuBarIcon: Bool { (isDeviceConnected || powerOffState != nil || earTipFitTransition != nil || headGesturePracticeTransition != nil || legacyOptimizerTransition != nil || earbudFinder?.isBusy == true || earbudFinder?.mayBeRinging == true || classicConnectionID != nil || hasPendingManualBLEConnection) && deviceModel != .unknown }
    var batteryLevel: Int? { batteries.level }
    var isCharging: Bool { batteries.isCharging }
    var isReady: Bool { linkState == .ready }
    var isBluetoothAccessDenied: Bool { bluetoothAuthorization == .denied || bluetoothAuthorization == .restricted }
    var hasOpenControlTransport: Bool {
        #if DEBUG
        if isSimulated { return isReady }
        #endif
        return channel?.isOpen() == true || bleTransport?.isReady == true
    }
    var hasPendingManualBLEConnection: Bool {
        bleTransport.map { !$0.isReady && !$0.shouldCancelAutomaticConnection } ?? false
    }
    var isCheckingEarTipFit: Bool { earTipFitTransition?.blocksCommands == true }
    var isPracticingHeadGestures: Bool { headGesturePracticeTransition?.blocksCommands == true }
    var isRunningHeadphoneTest: Bool { isCheckingEarTipFit || isPracticingHeadGestures || legacyOptimizerTransition?.blocksCommands == true || earbudFinder?.blocksCommands == true }
    var headphoneTestNeedsRecovery: Bool {
        earTipFitTransition?.phase == .interrupted || headGesturePracticeTransition?.phase == .interrupted || legacyOptimizerTransition?.phase == .interrupted
    }
    var isPoweringOff: Bool { powerOffState == .sending }
    var canPowerOff: Bool { powerOffUnavailableReason == nil }
    var powerOffSession: UInt64? { canPowerOff ? controlSession : nil }
    var powerOffUnavailableReason: String? {
        guard !isRunningHeadphoneTest else { return String(localized: "Finish the current headphone test first.") }
        guard powerOffState == nil else { return String(localized: "Connect the headphones to send another command.") }
        guard isReady else { return String(localized: "Connect the headphones first.") }
        guard supportedFunctions.contains(0x23) else { return String(localized: "These headphones do not report power-off support.") }
        guard connectionTransition?.isFinished != false, sourceTransition?.isFinished != false,
              deviceActionTransition?.isFinished != false, multipointTransition?.isFinished != false else {
            return String(localized: "Finish the current connection change first.")
        }
        guard pendingChanges.isEmpty, pendingPlaybackCommand == nil, !isEqualizerUpdatePending,
              !isApplyingChange, ambientWorkItem == nil, commandQueue.pending == nil else {
            return String(localized: "Wait for the current headphone command to finish.")
        }
        return nil
    }
    var canControlPlayback: Bool {
        canSendPlaybackChanges && playback.canControl
    }
    var canControlMusicVolume: Bool {
        canSendPlaybackChanges && playback.canControlMusicVolume
            && playbackReads[playback.musicVolumeQueryPayload]?.timedOut != true
    }
    var canControlCallVolume: Bool {
        canSendPlaybackChanges && playback.canControlCallVolume
            && playbackReads[[0xA6, 0x21]]?.timedOut != true
    }
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    var hasCurrentMusicVolumeControl: Bool {
        playbackControlContextIsAvailable && playback.canControlMusicVolume
            && [playback.capabilityQueryPayload, playback.statusQueryPayload, playback.musicVolumeQueryPayload]
                .allSatisfy { playbackFreshQueries.contains($0) }
    }
    var hasFreshMusicVolumeReadback: Bool {
        hasCurrentMusicVolumeControl && canControlMusicVolume && musicVolumeReadbackID != nil
            && [playback.statusQueryPayload, playback.musicVolumeQueryPayload]
                .allSatisfy { playbackReads[$0] == nil && !queuedPlaybackQueries.contains($0) }
    }
    func hasCurrentMusicSourceContext(for localAddress: @autoclosure () -> String?) -> Bool {
        guard hasCurrentTable2Capabilities else { return false }
        guard multipoint.supportsInventory else { return true }
        guard !multipoint.inventoryIsStale, let selected = multipoint.selectedSource, selected.isConnected,
              let localAddress = localAddress(),
              let localAddress = SonyBLEIdentity.normalizedAddress(localAddress) else { return false }
        return SonyBLEIdentity.normalizedAddress(selected.address) == localAddress
    }
    #endif

    @discardableResult
    func refreshMusicVolume() -> Bool {
        guard isReady, playback.isSupported, powerOffState == nil, !isRunningHeadphoneTest,
              connectionTransition?.isFinished != false, multipointTransition?.isFinished != false,
              sourceTransition?.isFinished != false, deviceActionTransition?.isFinished != false,
              !multipoint.inventoryIsStale else { return false }
        send(playback.statusQueryPayload)
        send(playback.musicVolumeQueryPayload)
        return true
    }

    private var canSendPlaybackChanges: Bool {
        playbackControlContextIsAvailable && !isRunningHeadphoneTest && pendingPlaybackCommand == nil
            && pendingChanges[.playbackVolume] == nil && pendingChanges[.callVolume] == nil
    }
    private var playbackControlContextIsAvailable: Bool {
        powerOffState == nil && isReady
            && [playback.capabilityQueryPayload, playback.statusQueryPayload]
                .allSatisfy { playbackReads[$0]?.timedOut != true }
            && connectionTransition?.isFinished != false && multipointTransition?.isFinished != false
            && sourceTransition?.isFinished != false && deviceActionTransition?.isFinished != false && !multipoint.inventoryIsStale
    }
    var canRefreshSoundPressure: Bool {
        powerOffState == nil && !isRunningHeadphoneTest && isReady && soundPressure.isSupported && soundPressure.available == true
            && !soundPressure.isStopped && soundPressureRead == nil && commandQueue.pending == nil
            && connectionTransition?.isFinished != false && multipointTransition?.isFinished != false
            && sourceTransition?.isFinished != false && deviceActionTransition?.isFinished != false
    }
    var isReadingSoundPressure: Bool { soundPressureRead != nil && soundPressureRead?.timedOut == false }
    var isEqualizerUpdatePending: Bool { requestedEqualizerPayload != nil || pendingChanges[.equalizer] != nil }
    var earTipFitUnavailableReason: String? {
        guard earTipFit.isSupported else { return String(localized: "These earbuds do not report fit-test support.") }
        return headphoneTestUnavailableReason
    }
    var headGesturePracticeUnavailableReason: String? {
        guard headGesturePractice.isSupported else { return String(localized: "These headphones do not report head-gesture practice support.") }
        guard systemFeatures[.headGestures]?.available != false else { return String(localized: "Head gestures are currently unavailable.") }
        return headphoneTestUnavailableReason
    }
    var canStartHeadGesturePractice: Bool {
        isReady && headGesturePracticeTransition?.phase == .ready && commandQueue.pending == nil
            && headGesturePractice.available == true && headGesturePractice.mode != .in
            && systemFeatures[.headGestures]?.available != false
    }
    var legacyOptimizerUnavailableReason: String? {
        guard legacyOptimizer.isSupported else { return String(localized: "These headphones do not report NC Optimizer support.") }
        return headphoneTestUnavailableReason
    }
    var canStartLegacyOptimizer: Bool {
        isReady && legacyOptimizerTransition?.phase == .ready && commandQueue.pending == nil && legacyOptimizer.canStart
    }
    private var headphoneTestUnavailableReason: String? {
        guard isReady, powerOffState == nil else { return String(localized: "Connect the headphones first.") }
        guard earTipFitTransition == nil, headGesturePracticeTransition == nil, legacyOptimizerTransition == nil,
              earbudFinder?.blocksCommands != true, earbudFinder?.mayBeRinging != true else { return String(localized: "Finish the current headphone test first.") }
        guard connectionTransition?.isFinished != false, sourceTransition?.isFinished != false,
              multipointTransition?.isFinished != false, deviceActionTransition?.isFinished != false else {
            return String(localized: "Finish the current connection change first.")
        }
        guard pendingChanges.isEmpty, pendingPlaybackCommand == nil, !isEqualizerUpdatePending,
              !isApplyingChange, ambientWorkItem == nil else {
            return String(localized: "Wait for the current headphone change to finish.")
        }
        return nil
    }
    var canStartEarTipFit: Bool {
        isReady && earTipFitTransition?.phase == .ready && commandQueue.pending == nil
            && earTipFit.status?.available == true && earTipFit.status?.mode == .out
            && earTipFit.status?.result == .noError && earTipFit.operation?.state != .started
            && earTipFit.measurementSeries != nil
    }
    var supportsConnectionMode: Bool {
        legacyControls?.connectionQuality.isSupported ?? audioFeatures.supportsConnectionMode
    }
    var supportedConnectionModes: [SonyConnectionMode]? {
        legacyControls.map { $0.connectionQuality.supportedModes } ?? audioFeatures.supportedConnectionModes
    }
    var connectionMode: SonyConnectionMode? {
        legacyControls.map { $0.connectionQuality.mode } ?? audioFeatures.connectionMode
    }
    var canChangeConnectionMode: Bool {
        supportedConnectionModes?.contains {
            $0 != connectionMode && connectionModeUnavailableReason($0) == nil
        } == true
    }

    func connectionModeUnavailableReason(_ mode: SonyConnectionMode) -> String? {
        guard connectionTransition?.isFinished != false else { return String(localized: "Finish the current connection change first.") }
        guard connectionTransition?.generation != .v1 || connectionTransition?.phase != .failed else {
            return String(localized: "Check the connection mode before changing it again.")
        }
        return connectionModePrerequisiteIssue(mode)
    }

    var sourceControlUnavailableReason: String? {
        guard !isRunningHeadphoneTest else { return String(localized: "Finish the current headphone test first.") }
        guard powerOffState == nil else { return String(localized: "Connect the headphones to change settings.") }
        guard isReady else { return String(localized: "Connect the headphones first.") }
        guard deviceActionTransition?.isFinished != false else { return String(localized: "Finish changing the device connection first.") }
        guard pendingPlaybackCommand == nil, pendingChanges[.playbackVolume] == nil, pendingChanges[.callVolume] == nil else { return String(localized: "Wait for the playback change to finish.") }
        guard connectionTransition?.isFinished != false else { return String(localized: "Finish the current connection change first.") }
        guard sourceTransition?.isFinished != false else { return String(localized: "Changing the audio source…") }
        guard multipointTransition?.isFinished != false else { return String(localized: "Finish changing device connections first.") }
        if let inventoryRead {
            return inventoryRead.timedOut ? String(localized: "The device list was not received. Reconnect the headphones to try again.") : String(localized: "Reading connected devices…")
        }
        guard multipoint.canControlSources else { return String(localized: "Audio source controls are currently unavailable.") }
        return nil
    }

    var canRefreshDevices: Bool {
        powerOffState == nil && !isRunningHeadphoneTest && isReady && inventoryRead == nil && sourceTransition?.isFinished != false && connectionTransition?.isFinished != false
            && multipointTransition?.isFinished != false && deviceActionTransition?.isFinished != false
    }

    func deviceActionUnavailableReason(_ action: SonyPeripheralAction, device: SonyMultipointDevice) -> String? {
        guard !isRunningHeadphoneTest else { return String(localized: "Finish the current headphone test first.") }
        guard powerOffState == nil else { return String(localized: "Connect the headphones to change settings.") }
        guard isReady else { return String(localized: "Connect the headphones first.") }
        guard deviceActionTransition?.isFinished != false, sourceTransition?.isFinished != false,
              connectionTransition?.isFinished != false, multipointTransition?.isFinished != false else {
            return String(localized: "Finish the current connection change first.")
        }
        if let inventoryRead {
            return inventoryRead.timedOut ? String(localized: "The device list was not received. Reconnect the headphones to try again.") : String(localized: "Reading connected devices…")
        }
        guard pendingChanges.isEmpty, pendingPlaybackCommand == nil, !isEqualizerUpdatePending, !isApplyingChange,
              ambientWorkItem == nil, commandQueue.pending == nil else { return String(localized: "Wait for the current headphone change to finish.") }
        guard action != .unpair, multipoint.canManageDevices else { return String(localized: "Device connection controls are currently unavailable.") }
        if action == .connect {
            guard let maximum = multipoint.maxConnectedDevices else { return String(localized: "Refresh the device list to read the connection limit.") }
            guard multipoint.devices.filter(\.isConnected).count < Int(maximum) else { return String(localized: "Disconnect a device before connecting another.") }
        }
        guard multipoint.peripheralActionPayload(action, address: device.address) != nil else { return String(localized: "The device connection changed. Refresh the device list.") }
        return nil
    }

    var multipointUnavailableReason: String? {
        guard !isRunningHeadphoneTest else { return String(localized: "Finish the current headphone test first.") }
        guard powerOffState == nil else { return String(localized: "Connect the headphones to change settings.") }
        guard isReady else { return String(localized: "Connect the headphones first.") }
        guard deviceActionTransition?.isFinished != false else { return String(localized: "Finish changing the device connection first.") }
        guard connectionTransition?.isFinished != false, sourceTransition?.isFinished != false,
              multipointTransition?.isFinished != false else { return String(localized: "Finish the current connection change first.") }
        guard pendingChanges.isEmpty, pendingPlaybackCommand == nil, !isEqualizerUpdatePending, !isApplyingChange else { return String(localized: "Wait for the current headphone change to finish.") }
        guard multipointReadbacks.isEmpty, multipointQueuedReadSlot == nil else { return String(localized: "Waiting for the headphone setting. Reconnect the headphones if it does not arrive.") }
        guard fixedAlertsEnabled else { return String(localized: "Preparing connection controls…") }
        guard systemFeatures.multipointSlot != nil, systemFeatures.multipoint?.available == true,
              systemFeatures.multipoint?.enabled != nil else { return String(localized: "This setting is currently unavailable.") }
        guard !address.isEmpty, !usesBluetoothLE || (bluetoothLEHash != nil && controlPeripheralID != nil) else {
            return String(localized: "Sync the headphone identity first.")
        }
        return nil
    }

    private func connectionModePrerequisiteIssue(_ mode: SonyConnectionMode) -> String? {
        guard !isRunningHeadphoneTest else { return String(localized: "Finish the current headphone test first.") }
        guard powerOffState == nil else { return String(localized: "Connect the headphones to change settings.") }
        guard deviceActionTransition?.isFinished != false else { return String(localized: "Finish changing the device connection first.") }
        guard pendingPlaybackCommand == nil, pendingChanges[.playbackVolume] == nil, pendingChanges[.callVolume] == nil else { return String(localized: "Wait for the playback change to finish.") }
        guard sourceTransition?.isFinished != false else { return String(localized: "Finish changing the audio source first.") }
        guard multipointTransition?.isFinished != false else { return String(localized: "Finish changing device connections first.") }
        guard isReady else { return String(localized: "Connect the headphones first.") }
        guard mode.sonyValue != nil, supportedConnectionModes?.contains(mode) == true else {
            return String(localized: "This mode is unavailable.")
        }
        guard let current = connectionMode, current.sonyValue != nil else { return String(localized: "Connection mode is unavailable.") }
        if let quality = legacyControls?.connectionQuality {
            guard quality.setPayload(mode) != nil else { return String(localized: "Connection mode is unavailable.") }
            guard pendingChanges.isEmpty, unconfirmedChanges.isEmpty, !isEqualizerUpdatePending,
                  !isApplyingChange, ambientWorkItem == nil else { return String(localized: "Wait for the current headphone change to finish.") }
            guard protocolVersion.map({ $0 < 0x4000 }) == true || fixedAlertsEnabled else { return String(localized: "Preparing connection controls…") }
        } else {
            guard audioFeatures.connectionModeAvailable == true else { return String(localized: "Connection mode is unavailable.") }
            guard fixedAlertsEnabled else { return String(localized: "Preparing connection controls…") }
        }
        if (current == .lowLatency) != (mode == .lowLatency) {
            guard audioFeatures.leftConnected == true, audioFeatures.rightConnected == true else {
                return String(localized: "Connect both earbuds first.")
            }
            guard bluetoothLEHash != nil, !address.isEmpty, isSimulated || device != nil else {
                return String(localized: "Sync the headphone identity first.")
            }
        }
        return nil
    }
    var controlProtocol: String {
        guard let protocolInformation else { return String(localized: "Unknown") }
        let version = protocolInformation.generation == .v1 ? "MDR v1" : "MDR v2"
        return usesBluetoothLE ? "\(version) · Bluetooth LE" : controlChannelID.map { "\(version) · RFCOMM \($0)" } ?? version
    }
    var statusText: String {
        switch linkState {
        case .searching: bluetoothAuthorization == .notDetermined ? String(localized: "Waiting for Bluetooth permission…") : String(localized: "Searching…")
        case .disconnected: String(localized: "Disconnected")
        case .opening: String(localized: "Connecting…")
        case .handshaking: String(localized: "Syncing…")
        case .ready: String(localized: "Connected")
        case .controlBusy: String(localized: "Controls busy")
        case .failed(let message): message
        }
    }

    var diagnosticReport: String {
        let lastIssue = lastErrorMessage != nil && lastErrorMessage == bluetoothLEError
            ? bluetoothLEDiagnosticError ?? bluetoothLEError ?? "None" : lastErrorMessage ?? "None"
        let controlState: String
        if case .failed = linkState { controlState = lastIssue } else { controlState = statusText }
        var lines = [
            "Acouplet diagnostics",
            "Device model: \(deviceModel.name)",
            "Bluetooth address: \(address.isEmpty ? "Not found" : "Available; omitted")",
            "Bluetooth device: \(isDeviceConnected ? "Connected" : "Disconnected")",
            "Sony control: \(controlState)",
            "Sony control session: \(controlSession)",
            "Protocol: \(controlProtocol)",
            "Protocol version: \(protocolVersion.map { String(format: "%08X", $0) } ?? "Unknown")",
            "LE peripheral: \(controlPeripheralID == nil ? "Not connected" : "Connected; identifier omitted")",
            "Sony BLE identity: \(bluetoothLEHash == nil ? "Unknown" : "Available; omitted")",
            "Last LE connection issue: \(bluetoothLEDiagnosticError ?? bluetoothLEError ?? "None")",
            "Firmware: \(firmwareVersion ?? "Unknown")",
            "Firmware update service: \(firmwareUpdateIdentity?.key ?? "Unknown")",
            "Battery: \(batteryLevel.map { "\($0)%" } ?? "Unknown")",
            "Left: \(batteries.left.map { "\($0.level)%" } ?? "Not reported")",
            "Right: \(batteries.right.map { "\($0.level)%" } ?? "Not reported")",
            "Case: \(batteries.caseBattery.map { "\($0.level)% (last reported)" } ?? "Not reported")",
            "Left charging: \(batteries.left?.chargingState.title ?? "Unknown")",
            "Right charging: \(batteries.right?.chargingState.title ?? "Unknown")",
            "Case charging (last reported): \(batteries.caseBattery?.chargingState.title ?? "Unknown")",
            "Noise control: \(noiseControlMode?.title ?? "Unknown")",
            "Equalizer: \(equalizerPreset?.title ?? "Unknown")",
            "Headphone codec: \(audioFeatures.codec?.title ?? "Unknown")",
            "Ear-tip fit workflow: \(earTipFitTransition.map { String(describing: $0.phase) } ?? "Not open")",
            "Ear-tip fit issue: \(earTipFitTransition?.message ?? "None")",
            "Head-gesture practice: \(headGesturePracticeTransition.map { String(describing: $0.phase) } ?? "Not open")",
            "Head-gesture practice issue: \(headGesturePracticeTransition?.message ?? "None")",
            "Listening level: \(soundPressure.reading.map { String(describing: $0) } ?? "Unknown")",
            "Listening level available: \(soundPressure.available.map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Listening level interval: \(soundPressure.intervalSeconds.map { "\($0) s" } ?? "Unknown")",
            "Last listening level issue: \(soundPressureReadError ?? "None")",
            "Selected headphone source connection: \(multipoint.selectedSource.map { String($0.connectionID) } ?? "Unknown")",
            "Keep audio source: \(multipoint.keeping.map { $0 ? "On" : "Off" } ?? "Unknown")",
            "Multipoint enabled: \(systemFeatures.multipoint?.enabled.map { $0 ? "On" : "Off" } ?? "Unknown")",
            "Multipoint change: \(multipointTransition.map { String(describing: $0.phase) } ?? "None")",
            "Paired source count: \(multipoint.devices.count), stale: \(multipoint.inventoryIsStale)",
            "Source change: \(sourceTransition.map { String(describing: $0.phase) } ?? "None")",
            "Device connection change: \(deviceActionTransition.map { String(describing: $0.phase) } ?? "None")",
            "Connection preference: \(connectionMode?.title ?? "Unknown")",
            "Connection preference change: \(connectionTransition.map { String(describing: $0.phase) } ?? "None")",
            "Requested connection preference: \(connectionTransition?.targetMode.title ?? "None")",
            "Connection preference confirmed: \(connectionTransition.map { $0.preferenceConfirmed ? "Yes" : "No" } ?? "Unknown")",
            "Connection preference issue: \(connectionModeError ?? "None")",
            "Supported connection modes: \(supportedConnectionModes.map { $0.map(\.title).joined(separator: ", ") } ?? "Unknown")",
            "Connection mode available: \((legacyControls.map { $0.connectionQuality.available } ?? audioFeatures.connectionModeAvailable).map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Left connected: \(audioFeatures.leftConnected.map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Right connected: \(audioFeatures.rightConnected.map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Connection mode status: \(audioFeatures.connectionModeStatus.map(String.init) ?? "Unknown"), \(audioFeatures.connectionModeAdditionalStatus.map(String.init) ?? "Unknown")",
            "LDAC exclusions: \(audioFeatures.connectionModeLDACExclusions.map { String(describing: $0) } ?? "Unknown")",
            "Connection alert: \(lastConnectionAlert.map { "format=\($0.format.rawValue) message=\($0.messageID) action=\($0.actionType)" } ?? "None")",
            "DSEE: \(dseeMode?.title ?? "Unknown")",
            "DSEE available: \(dseeAvailable.map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Automatic power-off: \(automaticPowerOff?.knownCurrent?.title ?? "Unknown")",
            "Remembered power-off timer: \(automaticPowerOff?.hasKnownParameter == true ? automaticPowerOff?.last?.title ?? "Unknown" : "Unknown")",
            "Automatic power-off available: \(automaticPowerOff?.available.map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Sidetone: \(systemFeatures.sidetone?.enabled.map { $0 ? "On" : "Off" } ?? "Unknown")",
            "Sidetone available: \(systemFeatures.sidetone?.available.map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Speech sensitivity: \(systemFeatures.speakToChatOptions?.sensitivity?.title ?? "Unknown")",
            "Speak-to-Chat delay: \(systemFeatures.speakToChatOptions?.delay?.title ?? "Unknown")",
            "Touch assignments: \(touchAssignments.selectedPresets.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "Unknown")",
            "Voice guidance: \(voiceGuidance.enabled.map { $0 ? "On" : "Off" } ?? "Unknown")",
            "Voice guidance volume: \(voiceGuidance.volume.map(String.init) ?? "Unknown")",
            "Playback state: \(playback.state.map { String(describing: $0) } ?? "Unknown")",
            "Headphone music volume: \(playback.volume.map(String.init) ?? "Unknown")",
            "Headphone music volume range: \(playback.musicVolumeRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "Unknown")",
            "Headphone music volume controllable: \(canControlMusicVolume ? "Yes" : "No")",
            "Playback music/call status: \(playback.musicCallStatus.map(String.init) ?? "Unknown")",
            "Capabilities: \(supportedFunctions.count) table 1, \(supportedFunctions2.count) table 2",
            "Table 1 functions: \(supportedFunctions.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))",
            "Table 2 functions: \(supportedFunctions2.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))",
            "Last sync: \(lastSyncDate?.formatted(date: .numeric, time: .standard) ?? "Never")",
            "Last error: \(lastIssue)",
        ]
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        lines.insert("Native device appearance: \(nativeAppearanceRefresh?.diagnosticDescription ?? "Disabled")", at: 10)
        lines.insert("Native battery observations: \(nativeBatterySnapshot?.diagnosticDescription(at: Date()) ?? "Unavailable")", at: 21)
        #endif
        return lines.joined(separator: "\n")
    }

    private enum Stage { case idle, protocolInfo, supportFunctions, bleIdentity, noiseControl, ready, unsupported }
    /// RFCOMM services that carry Sony's control protocol, in lookup order. Current models
    /// publish the first one; older MDR v1 headphones such as the WH-1000XM4 only publish
    /// the second ("Serial HPC"), so it is tried only when the first is absent.
    static let sonyServiceUUIDs: [[UInt8]] = [
        [0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8,
         0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2],
        [0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD,
         0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA],
    ]

    /// Returns the first Sony control service the device publishes, following `sonyServiceUUIDs`.
    static func sonyServiceRecord(on device: any SonyBluetoothDevice) -> (record: any SonyServiceRecord, uuid: [UInt8])? {
        for bytes in sonyServiceUUIDs {
            let uuid = bytes.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: bytes.count) }
            if let record = device.sonyServiceRecord(for: uuid) { return (record, bytes) }
        }
        return nil
    }
    private static let asmByFunction: [(function: UInt8, type: UInt8)] = [
        (0x6D, 0x19), (0x6B, 0x17), (0x68, 0x15), (0x67, 0x22), (0x66, 0x21),
    ]
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "SonyBluetooth")

    private let identityDefaults: UserDefaults?
    private let displayOnly: Bool
    let pinnedAddress: String?
    private var savedIdentity: SonyBLEIdentity.VerifiedDevice?
    private var device: (any SonyBluetoothDevice)?
    private var classicConnectionID: UUID?
    private var classicConnections: [UUID: ClassicConnection] = [:]
    private var serviceDiscoveryID: UUID?
    private var serviceDiscoveries: [UUID: ServiceDiscovery] = [:]
    var pairedDeviceInventory: [any SonyBluetoothDevice]?
    private var channel: (any RFCOMMChannel)?
    private var channelIO: RFCOMMChannelIO?
    private var classicWrites: [UInt: ClassicWrite] = [:]
    private var nextClassicWriteID: UInt = 0
    let rfcommCloseCompletion = DispatchGroup()
    private var pendingClassicOpenID: UUID?
    private var classicIncomingData: [(data: Data, transmissionID: UUID?)] = []
    private var classicIncomingDataLength = 0
    private var bleTransport: SonyBLETransport?
    private var expectedBLEIdentity: SonyBLEIdentity.ConnectionTarget?
    private var bluetoothLEIdentityReadTransmitted = false
    private var controlSession: UInt64 = 0
    var preferencePaneSession: UInt64 { controlSession }
    @Published private var fixedAlertsEnabled = false
    private var transmittedFrame: SonyFrame?
    private var connectionRequestID: UUID?
    private(set) var lastConnectionModeChangeID: UUID?
    private var connectionModeTimeout: DispatchWorkItem?
    private var modeReadbacks: [UUID?] = []
    private var pendingInboundAcknowledgments = 0
    private var transitionDevice: (any SonyBluetoothDevice)?
    private var transitionAddress: String?
    private var transitionHash: String?
    private var transitionPeripheralID: UUID?
    private var transitionModel = SonyDeviceModel.unknown
    private var controlAddresses: Set<String> = []
    private var transitionControlAddresses: Set<String> = []
    private var recoveryUsesBLE: Bool?
    private var recoveryClassicAddress: String?
    private var refreshTimer: Timer?
    @Published private var bluetoothAuthorization: CBManagerAuthorization?
    private var isInitializingBluetooth = false
    private var bluetoothInitializationID: UUID?
    private var isBluetoothInitialized = false
    private var isSystemSleeping = false
    private var retryWorkItem: DispatchWorkItem?
    private var ambientWorkItem: DispatchWorkItem?
    private var commandTimeoutWorkItem: DispatchWorkItem?
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var handshakeID: UUID?
    private var equalizerWorkItem: DispatchWorkItem?
    private var equalizerDebounceID: UUID?
    private var equalizerRead: EqualizerRead?
    private var equalizerReadTimeout: DispatchWorkItem?
    private var inventoryReadTimeout: DispatchWorkItem?
    private var sourceTimeout: DispatchWorkItem?
    private var deviceActionTimeout: DispatchWorkItem?
    private var multipointTimeout: DispatchWorkItem?
    private var multipointTimeoutID: UUID?
    private var multipointTimeoutPhase: SonyMultipointTransition.Phase?
    @Published private var multipointReadbacks: [(slot: UInt8, request: UUID?)] = []
    @Published private var multipointQueuedReadSlot: UInt8?
    private var multipointConnection: MultipointConnection?
    private var multipointRecoveryAttempts = 0
    private var unconfirmedEqualizerRequestID: UUID?
    private var acknowledgmentTimeout: DispatchWorkItem?
    private var transmissionID: UUID?
    private var commandQueue = SonyCommandQueue() {
        willSet {
            if (commandQueue.pending == nil) != (newValue.pending == nil) {
                objectWillChange.send()
            }
        }
    }
    private var settingTimeouts: [Setting: DispatchWorkItem] = [:]
    private var settingRefreshes: [Setting: DispatchWorkItem] = [:]
    private var settingRequests: [Setting: UUID] = [:]
    private var unconfirmedChanges: [Setting: [UInt8]] = [:]
    private var queuedSpeakToChatOptions: SonySpeakToChatOptions?
    private var queuedTouchChange: (key: UInt8, selection: [UInt8], sharedKeys: Set<UInt8>)?
    private var systemReads: [[UInt8]: SystemRead] = [:]
    private var voiceGuidanceReads: [[UInt8]: SystemRead] = [:]
    private var queuedPlaybackSource: String?
    private var queuedVolumeSource: String?
    private var queuedMusicVolumeIsCurrent: (() -> Bool)?
    private var soundPressureGeneration: UInt64 = 0
    private var soundPressureReadTimeout: DispatchWorkItem?
    private var wearingStatusGeneration: UInt64 = 0
    private var wearingStatusRead: WearingStatusRead?
    private var wearingStatusReadTimeout: DispatchWorkItem?
    private var lastSoundPressureRequest: ContinuousClock.Instant?
    private var playbackSourceGeneration: UInt64 = 0
    private var announcedAudioSourceAddress: String?
    private var playbackFreshQueries: Set<[UInt8]> = []
    private var playbackReads: [[UInt8]: PlaybackRead] = [:]
    private var queuedPlaybackQueries: Set<[UInt8]> = []
    private var playbackReadTimeouts: [[UInt8]: DispatchWorkItem] = [:]
    private var stream = SonyFrameStream()
    private var lastReceivedSequence: UInt8?
    private var stage: Stage = .idle
    private var asmType: UInt8?
    private var noiseControlRead: NoiseControlRead?
    private var queuedNoiseControlRead = false
    private var noiseControlRefresh: (id: UUID, work: DispatchWorkItem)?
    private var noiseControlRefreshAttempted = false
    private var noiseControlSawValidChanging = false
    private var requestedNoiseControlPayload: [UInt8]?
    private var requestedNoiseControlPreservesAdaptation = true
    private var noiseControlWriteState: SonyNoiseControl.State?
    private var settingIntent: (setting: Setting, requestID: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var noiseMetadataReads: [[UInt8]: Bool] = [:]
    private var noiseReadTimeouts: [[UInt8]: (id: UUID, work: DispatchWorkItem)] = [:]
    private var noiseAvailabilityReadObsolete = false
    private var reconnectAutomatically = true
    private var legacyOptimizerTimeout: DispatchWorkItem?
    private var legacyOptimizerTimeoutPhase: SonyLegacyOptimizerTransition.Phase?
    private var headGesturePracticeTimeout: DispatchWorkItem?
    private var headGesturePracticeTimeoutPhase: SonyHeadGesturePracticeTransition.Phase?
    private var earTipFitTimeout: DispatchWorkItem?
    private var earTipFitTimeoutPhase: SonyEarTipFitTransition.Phase?
    private var powerOffRequestSession: UInt64?
    private var batteryReads: [[UInt8]: BatteryRead] = [:]
    private var powerReads: [[UInt8]: PowerRead] = [:]
    private var powerRequestIDs: [Setting: UUID] = [:]
    private static let powerOffPayload: [UInt8] = [0x24, 0x03, 0x01]
    private var isSimulated = false
    private var lastReadyTransportWasBluetoothLE = false
    #if DEBUG
    private var simulatesSettingReplies = false
    #endif
    private var retryAttempt = 0
    private var deviceActionRecoveryAttempts = 0
    private var nextRetryDate: Date?
    private var syncPollCount = 0
    private var supportsTable2 = false
    private var supportFunctionsReadTransmitted = false
    @Published private var discoveryReads: [[UInt8]: DiscoveryRead] = [:]
    private var firmwareUpdateQueries: [[UInt8]: Bool] = [:]
    private var legacyFirmwareUpdateValues: [UInt8: String] = [:]
    private var legacyReads: Set<[UInt8]> = []
    private var queuedLegacyReads: Set<[UInt8]> = []
    private var legacyOptionalReadTimeouts: [[UInt8]: (id: UUID, work: DispatchWorkItem?)] = [:]
    private var obsoleteLegacyBatteryReads: Set<[UInt8]> = []
    private var legacyDSEERead: LegacySettingRead?
    private var legacyDSEEAvailabilityReadObsolete = false
    private var legacyDSEEReadTimeouts: [[UInt8]: (id: UUID, work: DispatchWorkItem?)] = [:]
    private var legacySoundEffectReads: [[UInt8]: LegacySettingRead] = [:]
    private var legacySoundEffectReadTimeouts: [[UInt8]: (id: UUID, work: DispatchWorkItem?)] = [:]

    private var timedOutLegacyReads: Set<[UInt8]> {
        Set(legacyDSEEReadTimeouts.compactMap { $0.value.work == nil ? $0.key : nil })
            .union(legacySoundEffectReadTimeouts.compactMap { $0.value.work == nil ? $0.key : nil })
            .union(legacyOptionalReadTimeouts.compactMap { $0.value.work == nil ? $0.key : nil })
    }

    private var hasExpiredControlRead: Bool {
        !timedOutLegacyReads.isEmpty
            || batteryReads.values.contains(where: { $0.timedOut })
            || equalizerRead?.timedOut == true
            || noiseControlRead?.timedOut == true
            || systemReads.values.contains(where: { $0.timedOut })
            || powerReads.values.contains(where: { $0.timedOut })
            || voiceGuidanceReads.values.contains(where: { $0.transmitted && $0.isObsolete && $0.timeout == nil })
            || playbackReads.values.contains(where: { $0.timedOut })
            || soundPressureRead?.timedOut == true
            || inventoryRead?.timedOut == true
            || wearingStatusRead?.timedOut == true
    }

    init(startAutomatically: Bool = true, simulated: Bool = false, simulatedReady: Bool = false, identityDefaults: UserDefaults? = nil,
         pinnedAddress: String? = nil, advertisedName: String? = nil, displayOnly: Bool = false,
         nativeAppearanceRefreshEnabled: Bool = false) {
        precondition(pinnedAddress == nil || SonyBLEIdentity.normalizedAddress(pinnedAddress!) != nil)
        self.pinnedAddress = pinnedAddress.flatMap(SonyBLEIdentity.normalizedAddress)
        self.identityDefaults = identityDefaults
        self.displayOnly = displayOnly
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        nativeAppearanceRefresh = nativeAppearanceRefreshEnabled && !simulated && !simulatedReady && !displayOnly
            ? SonyNativeAppearanceRefresh() : nil
        #endif
        let identities = identityDefaults.map(SonyBLEIdentity.savedDevices) ?? [:]
        savedIdentity = self.pinnedAddress.flatMap { identities[$0] } ?? (self.pinnedAddress == nil && identities.count == 1 ? identities.values.first : nil)
        super.init()
        address = self.pinnedAddress ?? ""
        if let advertisedName { deviceName = advertisedName }
        guard !displayOnly else {
            linkState = .disconnected
            return
        }
        #if DEBUG
        isSimulated = simulated || simulatedReady
        simulatesSettingReplies = simulatedReady || CommandLine.arguments.contains("-ui-testing")
        if isSimulated, !simulatedReady {
            linkState = .disconnected
            return
        }
        if simulatedReady {
            simulateDeviceConnection(named: CommandLine.arguments.contains("--wh-device") ? "WH-1000XM5" : "WF-1000XM5")
            return
        }
        #endif
        guard startAutomatically else {
            linkState = .disconnected
            return
        }
        start()
    }

    #if DEBUG
    var simulatedPendingFrame: SonyFrame? { isSimulated ? commandQueue.pending : nil }
    var simulatedControlSession: UInt64 { controlSession }
    var simulatedReconnectAutomatically: Bool { reconnectAutomatically }
    var simulatedHandshakeTimeoutPending: Bool { handshakeTimeoutWorkItem != nil }
    var simulatedEarTipFitTimeoutPending: Bool { earTipFitTimeout != nil }
    var simulatedHeadGesturePracticeTimeoutPending: Bool { headGesturePracticeTimeout != nil }
    func simulateAcknowledgmentTimeout() { acknowledgmentTimeout?.perform() }
    func simulateNoiseReadTimeout(_ query: [UInt8]) { noiseReadTimeouts[query]?.work.perform() }
    func simulatedNoiseReadTimeoutID(_ query: [UInt8]) -> UUID? { noiseReadTimeouts[query]?.id }
    func simulateSystemReadTimeout(_ query: [UInt8]) { systemReads[query]?.timeout?.perform() }
    func simulateVoiceGuidanceReadTimeout(_ query: [UInt8]) { voiceGuidanceReads[query]?.timeout?.perform() }
    func simulatePowerReadTimeout(_ query: [UInt8], type: UInt8 = 0x0C) { powerReads[[type] + query]?.timeout?.perform() }
    func simulateBatteryReadTimeout(_ query: [UInt8]) { batteryReads[query]?.timeout?.perform() }
    func simulateBatteryRefresh() { requestBattery() }
    func simulatePlaybackReadTimeout(_ query: [UInt8]) { playbackReadTimeouts[query]?.perform() }
    func simulateSoundPressureReadTimeout() { soundPressureReadTimeout?.perform() }
    func simulateInventoryReadTimeout() { inventoryReadTimeout?.perform() }
    func simulateDiscoveryReadTimeout(_ query: [UInt8], type: UInt8 = 0x0C) { discoveryReads[[type] + query]?.timeout?.perform() }
    func simulatedDiscoveryReadTimeoutID(_ query: [UInt8], type: UInt8 = 0x0C) -> UUID? {
        guard let read = discoveryReads[[type] + query], read.timeout != nil else { return nil }
        return read.id
    }
    func simulatedDiscoveryReadTimeoutWork(_ query: [UInt8], type: UInt8 = 0x0C) -> DispatchWorkItem? {
        discoveryReads[[type] + query]?.timeout
    }
    func simulateWearingStatusReadTimeout() { wearingStatusReadTimeout?.perform() }
    func simulateChargingCaseTimeout() { chargingCaseTimeout?.perform() }
    func simulateCaseBatteryExpiry(at date: Date) { expireCaseBattery(at: date) }

    func simulateTouchReadTimeout(_ query: [UInt8]) { simulateSystemReadTimeout(query) }

    func simulateOptionalReadUITest(_ action: String) {
        guard isSimulated, CommandLine.arguments.contains("-ui-testing"),
              CommandLine.arguments.contains("--optional-read-timeout") else { return }
        let legacy = CommandLine.arguments.contains("whXM3")
        switch action {
        case "begin":
            simulatesSettingReplies = false
            if legacy {
                send([0xE6, 2])
                send([0x46, 1])
            } else if CommandLine.arguments.contains("--optional-system-read-timeout") {
                send([0xF6, 1])
            } else {
                touchAssignments.invalidateRead([0xF0, 3])
                send([0xF0, 3])
            }
            acknowledgeOptionalReadUITestCommands()
            simulatesSettingReplies = true
        case "expire":
            if legacy {
                simulateLegacyDSEEReadTimeout([0xE6, 2])
                simulateLegacySoundEffectReadTimeout([0x46, 1])
            } else if CommandLine.arguments.contains("--optional-system-read-timeout") {
                simulateSystemReadTimeout([0xF6, 1])
            } else {
                simulateTouchReadTimeout([0xF0, 3])
            }
        case "rehandshake":
            simulatesSettingReplies = false
            simulateSameTransportHandshake()
            completeOptionalReadUITestHandshake(legacy: legacy)
            simulatesSettingReplies = true
        case "recover":
            if !isReady { completeOptionalReadUITestHandshake(legacy: legacy) }
            if legacy {
                simulateProtocolMessage([0xE9, 2, 0, 1])
                simulateProtocolMessage([0x49, 1, 2])
            } else {
                let capability: [UInt8] = [0xF1, 3, 2,
                    0, 0, 0x35, 1, 0x35, 1, 0, 0, 1,
                    1, 0, 0x20, 1, 0x20, 1, 0, 0, 0x20]
                for _ in 0..<2 {
                    simulateProtocolMessage(capability)
                    simulateProtocolMessage([0xF7, 1, 0])
                    acknowledgeOptionalReadUITestCommands()
                }
                simulateProtocolMessage([0xF3, 3, 2, 0, 0])
                simulateProtocolMessage([0xF7, 3, 2, 0x35, 0x20])
            }
            simulatesSettingReplies = true
        default:
            preconditionFailure("Choose an optional-read UI test action.")
        }
    }

    private func completeOptionalReadUITestHandshake(legacy: Bool) {
        let name = Array((legacy ? "WH-1000XM3" : "WF-1000XM5").utf8)
        let replies: [[UInt8]] = legacy ? [
            [0x01, 0, 2, 0x10], [0x05, 1, UInt8(name.count)] + name,
            [0x05, 3, 0x20, 0], [0x07, 0, 4, 0x62, 0xE2, 0x41, 0x42],
            [0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15], [0x63, 2, 0],
            [0x67, 2, 1, 2, 0, 1, 0, 12], [0xE1, 2, 0, 0], [0xE3, 2, 0],
            [0x41, 1, 3, 0, 0, 2, 0, 3, 0], [0x43, 1, 0],
            [0x41, 2, 1], [0x43, 2, 0], [0x47, 2, 0],
        ] : [
            [0x01, 0, 3, 0, 0x30, 0x18, 0, 0], [0x05, 1, UInt8(name.count)] + name,
            [0x05, 3, 0, 1], [0x07, 0, 3, 0x6B, 1, 0xF3, 1, 0xF1, 1],
            [0x61, 0x17, 1, 0, 1, 20, 1], [0x63, 0x17, 0],
            [0x67, 0x17, 1, 1, 1, 0, 8], [0xF3, 1, 0],
        ]
        acknowledgeOptionalReadUITestCommands()
        for reply in replies {
            simulateProtocolMessage(reply)
            acknowledgeOptionalReadUITestCommands()
        }
    }

    private func acknowledgeOptionalReadUITestCommands() {
        for _ in 0..<100 {
            guard let frame = simulatedPendingFrame else { return }
            simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        preconditionFailure("The optional-read UI test command queue did not drain.")
    }

    func simulateLegacyDSEEReadTimeout(_ query: [UInt8]) { legacyDSEEReadTimeouts[query]?.work?.perform() }
    func simulateLegacyOptionalReadTimeout(_ query: [UInt8]) { legacyOptionalReadTimeouts[query]?.work?.perform() }
    func simulatedLegacyOptionalReadTimeoutID(_ query: [UInt8]) -> UUID? {
        guard let timeout = legacyOptionalReadTimeouts[query], timeout.work != nil else { return nil }
        return timeout.id
    }
    func simulateSettingTimeout(_ setting: Setting) { settingTimeouts[setting]?.perform() }
    func simulateEqualizerReadTimeout() { equalizerReadTimeout?.perform() }
    func simulateLegacySoundEffectReadTimeout(_ query: [UInt8]) { legacySoundEffectReadTimeouts[query]?.work?.perform() }
    func simulateLegacySoundEffectSettingTimeout(_ kind: SonyLegacySoundEffect.Kind) { settingTimeouts[.legacySoundEffect(kind)]?.perform() }

    var simulatedLegacyOptimizerTimeoutPending: Bool { legacyOptimizerTimeout != nil }
    var simulatedConnectionModeTimeoutPending: Bool { connectionModeTimeout != nil }
    var simulatedModeReadbackCount: Int { modeReadbacks.count }
    var simulatedInventoryReadPending: Bool { inventoryRead != nil }
    var simulatedDeviceActionTimeoutPending: Bool { deviceActionTimeout != nil }
    var simulatedSourceTimeoutPending: Bool { sourceTimeout != nil }
    var simulatedBLEWaitsForConnection: Bool { bleTransport?.shouldCancelAutomaticConnection == true }
    var simulatedRecoveryAddress: String? { transitionAddress }
    var simulatedRecoveryHash: String? { transitionHash }
    var simulatedRecoveryPeripheralID: UUID? { transitionPeripheralID }
    var simulatedSavedIdentity: SonyBLEIdentity.VerifiedDevice? { savedIdentity }
    private(set) var simulatedTransmittedFrames: [SonyFrame] = []
    var defersSimulatedWrites = false
    private var simulatedWriteCompletions: [() -> Void] = []
    private var simulatedMode = SonyConnectionMode.soundQuality
    private var simulatedArtworkSuffix: String?
    private var simulatedSourceID: UInt8 = 1
    private var simulatedDeviceConnections: [String: UInt8] = [:]
    private var simulatedMultipointEnabled = true
    private var simulatedEarTipFitResultCount = 0

    var simulatedMultipointTimeoutPending: Bool { multipointTimeoutID != nil }
    var simulatedMultipointRecoveryUsesBLE: Bool? { multipointConnection?.usesBLE }

    func simulateLegacyOptimizerTimeout() {
        guard isSimulated else { return }
        finishLegacyOptimizerTimeout()
    }

    func simulateHeadGesturePracticeTimeout() {
        guard isSimulated else { return }
        finishHeadGesturePracticeTimeout()
    }

    func simulateEarTipFitTimeout() {
        guard isSimulated else { return }
        finishEarTipFitTimeout()
    }

    func simulateMultipointTimeout() {
        guard isSimulated else { return }
        multipointTimeout?.cancel()
        multipointTimeout = nil
        multipointTimeoutID = nil
        if multipointTransition?.phase == .recovering {
            finishMultipointRecovery(String(localized: "Controls could not reconnect to check the multipoint setting."))
        } else {
            if multipointTransition?.timeout() == true { advanceMultipointTransition() }
        }
    }

    private func simulatedMultipointInventory(selected: UInt8) -> [UInt8] {
        var devices: [(String, UInt8, UInt32, String)] = [("02:00:00:00:00:01", 1, 0x2A410C, "MacBook Pro"), ("02:00:00:00:00:02", 2, 0x5A020C, "Phone")]
        if CommandLine.arguments.contains("-ui-testing") {
            devices.append(("02:00:00:00:00:03", 0, 0x2A4114, "Tablet"))
            if CommandLine.arguments.contains("--four-source-devices") {
                devices += [("02:00:00:00:00:04", 3, 0x04043C, "TV"), ("02:00:00:00:00:05", 4, 0x2A4104, "Desktop")]
            }
        }
        let entries: [UInt8] = devices.flatMap { address, id, deviceClass, name in
            let details: [UInt8] = [simulatedDeviceConnections[address] ?? id, UInt8((deviceClass >> 16) & 0xFF), UInt8((deviceClass >> 8) & 0xFF), UInt8(deviceClass & 0xFF), UInt8(name.utf8.count)]
            return Array(address.utf8) + details + Array(name.utf8)
        }
        return [0x37, 0x02, UInt8(devices.count)] + entries + [selected]
    }

    func simulateSourceTimeout() {
        guard isSimulated else { return }
        sourceTimeout?.cancel()
        sourceTimeout = nil
        sourceTransition?.timeout()
    }

    func simulateDeviceActionTimeout() {
        guard isSimulated else { return }
        finishDeviceActionTimeout()
    }

    func completeSimulatedWrite() {
        guard isSimulated, !simulatedWriteCompletions.isEmpty else { return }
        simulatedWriteCompletions.removeFirst()()
    }

    func simulateControlLoss(deviceConnected: Bool? = nil) {
        guard isSimulated else { return }
        closeSonyLink()
        if let deviceConnected { isDeviceConnected = deviceConnected }
        linkState = .disconnected
    }

    func simulateClassicConnection(recovering: Bool = false) -> ((IOReturn, Bool) -> Void)? {
        guard isSimulated, let connection = beginClassicConnection(recovering: recovering) else { return nil }
        return connection.complete
    }

    func simulateSonyLink(to device: any SonyBluetoothDevice) {
        guard isSimulated else { return }
        self.device = device
        isDeviceConnected = device.isClassicConnected()
        openSonyLink()
    }

    func simulateSelectedDevice(_ device: any SonyBluetoothDevice) {
        guard isSimulated else { return }
        self.device = device
        isDeviceConnected = device.isClassicConnected()
        if let name = device.name { deviceName = name }
        if let address = device.addressString { self.address = Self.normalizedAddress(address) }
    }

    func simulateInventoryRefresh(_ devices: [any SonyBluetoothDevice], shouldOpenLink: Bool) {
        guard isSimulated else { return }
        isBluetoothInitialized = true
        pairedDeviceInventory = devices
        if stage == .idle, lastErrorMessage == nil { linkState = .searching }
        refresh(shouldOpenLink: shouldOpenLink)
    }

    func simulatePairedBluetoothLE(automatically: Bool) -> Bool {
        guard isSimulated, let device else { return false }
        return openPairedBluetoothLE(for: device, automatically: automatically)
    }

    func simulateBluetoothLEReady(identifier: UUID, name: String?) {
        guard isSimulated else { return }
        bleTransport?.onReady?(identifier, name)
    }

    func simulateRetryDeadlineReached() {
        guard isSimulated else { return }
        nextRetryDate = .distantPast
        updateRetryCountdown()
    }

    func simulateHandshakeTimeout() { handshakeTimeoutWorkItem?.perform() }

    func simulateSameTransportHandshake() {
        guard isSimulated else { return }
        beginHandshake(reusingConnection: true)
    }

    var simulatedClassicWritesPending: Bool { !classicWrites.isEmpty }

    func simulateClassicTransport(_ channel: any RFCOMMChannel) {
        guard isSimulated else { return }
        self.channel = channel
        channelIO = RFCOMMChannelIO(channel: channel)
    }

    func simulateClassicWriteTimeout() {
        guard isSimulated else { return }
        classicWrites.values.first(where: { $0.session == controlSession })?.timeout.perform()
    }

    func simulateConnectionModeTimeout() {
        guard isSimulated else { return }
        connectionModeTimeout?.cancel()
        connectionModeTimeout = nil
        finishConnectionModeTimeout()
    }

    func simulateAutomaticRefresh(deviceConnected: Bool? = nil) {
        guard isSimulated else { return }
        if let deviceConnected, isDeviceConnected != deviceConnected { isDeviceConnected = deviceConnected }
        poll()
    }

    @discardableResult
    func simulateBLEReconnectWait(automatic: Bool, priorBluetoothLE: Bool, classicConnected: Bool, retryAttempt: Int = 0) -> Bool {
        guard isSimulated else { return false }
        lastReadyTransportWasBluetoothLE = priorBluetoothLE
        isDeviceConnected = classicConnected
        self.retryAttempt = retryAttempt
        return openBluetoothLE(target: .verified(hash: "ABCDEF12", peripheralIdentifier: nil), model: deviceModel, automatically: automatic)
    }

    func simulateBLEDisconnect(_ message: String?, error: Error? = nil) {
        guard isSimulated else { return }
        if let error { bleTransport?.simulateFailure(error) }
        else if let message { bleTransport?.simulateFailure(message) }
        else { bleTransport?.onDisconnect?(nil) }
    }

    func simulateBluetoothInitialization() {
        guard isSimulated else { return }
        finishBluetoothInitialization(authorization: .allowedAlways)
    }

    func simulateScheduledRetry() {
        guard isSimulated else { return }
        retryWorkItem = DispatchWorkItem {}
        nextRetryDate = Date().addingTimeInterval(1)
        retrySecondsRemaining = 1
    }

    func simulateRecoveryFailure() {
        guard isSimulated else { return }
        finishConnectionRecoveryFailure()
    }

    func simulateClassicRecovery() {
        guard isSimulated else { return }
        recoverClassicConnection()
    }

    func simulateDeviceConnection(named name: String?, controlBusy: Bool = false, peripheralIdentifier: UUID? = nil,
                                  supportsEarpieceSelection: Bool = false, simulatedAddress: String? = nil,
                                  galleryModel: SonyDeviceModel? = nil, galleryColor: UInt8? = nil,
                                  simulatedTable2Functions: Set<UInt8>? = nil) {
        guard isSimulated else { return }
        let nextAddress = simulatedAddress ?? pinnedAddress ?? "02:53:4F:4E:59:01"
        guard acceptsDeviceAddress(nextAddress) else { return }
        simulatedArtworkSuffix = nil
        closeSonyLink()
        deviceName = name ?? String(localized: "Sony headphones")
        address = name == nil ? pinnedAddress ?? "" : Self.normalizedAddress(nextAddress)
        isDeviceConnected = name != nil
        linkState = name == nil ? .disconnected : controlBusy ? .controlBusy : .ready
        guard isReady else { return }
        noiseControlMode = .ambient
        ambientLevel = 12
        if deviceModel.isEarbuds {
            let charging: UInt8 = CommandLine.arguments.contains("--charging-in-case") ? 1 : 0
            batteries.update([0x23, 0x09, 78, charging, 82, charging])
            batteries.update([0x23, 0x0A, 64, 0])
            updateChargingCasePresence()
        } else {
            batteries.update([0x23, 0x00, 78, 0])
        }
        firmwareVersion = "2.5.1"
        protocolVersion = 0x03003018
        protocolInformation = SonyProtocolInfo(payload: [0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0])
        if let galleryModel {
            let name = Array(galleryModel.name.utf8)
            deviceInformation.update([0x05, 0x01, UInt8(name.count)] + name)
            if let galleryColor { deviceInformation.update([0x05, 0x03, 0, galleryColor]) }
            firmwareVersion = nil
        } else {
            deviceInformation.update([0x05, 0x03, 0, 0x01])
        }
        fixedAlertsEnabled = true
        bluetoothLEHash = "ABCDEF12"
        controlPeripheralID = peripheralIdentifier
        simulatedMode = .soundQuality
        controlChannelID = 9
        lastSyncDate = Date()
        stage = .ready
        asmType = galleryModel == nil ? 0x19 : 0x17
        let noiseInquiry: UInt8 = galleryModel == nil ? 0x19 : 0x17
        noiseControl = SonyNoiseControl(inquiryType: noiseInquiry)
        for payload: [UInt8] in [
            [0x61, noiseInquiry, 2, 0, 1, 20, 1, 1, 1, 20, 1], [0x63, noiseInquiry, 0],
            [0x67, noiseInquiry, 1, 1, 1, 0, 12] + (noiseInquiry == 0x19 ? [0, 0] : []),
        ] { noiseControl?.update(payload) }
        noiseControlDisplayState = noiseControl?.state
        if let galleryModel, [.wfXM4, .wfXM3, .whXM4, .whXM3].contains(galleryModel) {
            noiseControl = nil
            noiseControlDisplayState = nil
            protocolInformation = SonyProtocolInfo(payload: [0x01, 0, 1, 0])
            protocolVersion = protocolInformation?.version
            supportsTable2 = false
            supportedFunctions = []
            supportedFunctions2 = []
            let functions: [UInt8] = [0x51, 0x62, 0xE2] + (galleryModel.isEarbuds ? [0x15, 0x18] : [0x11, 0x81])
                + (galleryModel == .whXM3 ? [0x41, 0x42] : [])
                + (CommandLine.arguments.contains("--legacy-wearing") ? [0xF3] : [])
                + (CommandLine.arguments.contains("--legacy-power") ? [0xF4] : [])
                + (CommandLine.arguments.contains("--legacy-assignments") ? [0xF6] : [])
                + (CommandLine.arguments.contains("--legacy-connection-quality") ? [0xE1] : [])
            var controls = SonyLegacyControls(supportPayload: [0x07, 0, UInt8(functions.count)] + functions)!
            let dsee: UInt8 = [.wfXM3, .whXM3].contains(galleryModel) ? 0 : 2
            for payload: [UInt8] in [
                [0x61, 0x02, 0, 2, 1, 2, 0, 20, 1, 20], [0x63, 0x02, 0],
                [0x67, 0x02, 1, 0, 0, 1, 0, 12],
                [0xE1, 0x02, dsee, 0], [0xE3, 0x02, 0], [0xE7, 0x02, 0, 1],
                [0x11, 0, 78, 0], [0x11, 1, 78, 0, 82, 0], [0x11, 2, 64, 0],
            ] { controls.update(payload) }
            if CommandLine.arguments.contains("--legacy-connection-quality") {
                protocolInformation = SonyProtocolInfo(payload: [0x01, 0, 0x40, 0])
                protocolVersion = protocolInformation?.version
                for payload: [UInt8] in [[0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] { controls.update(payload) }
            }
            if CommandLine.arguments.contains("--legacy-wearing") {
                for payload: [UInt8] in [[0xF1, 0x03, 0], [0xF3, 0x03, 0], [0xF7, 0x03, 0, 0]] {
                    controls.update(payload)
                }
            }
            if CommandLine.arguments.contains("--legacy-power") {
                for payload: [UInt8] in [[0xF1, 0x04, 6, 0x10, 0x11, 0, 1, 2, 3], [0xF3, 0x04, 0], [0xF7, 0x04, 1, 0x10, 0]] {
                    controls.update(payload)
                }
            }
            if CommandLine.arguments.contains("--legacy-assignments") {
                touchAssignments = SonyTouchAssignments(supportedFunctions: controls.supportedFunctions, generation: .v1)
                let capability: [UInt8] = galleryModel.isEarbuds ? [
                    0xF1, 0x06, 2,
                    0, 0, 0, 3, 0, 2, 0, 1, 0x10, 0x10, 0x10, 2, 0, 0x11, 1, 0x12, 0xFF, 1, 0, 0,
                    1, 0, 0x20, 3, 0x20, 3, 0, 0x20, 1, 0x21, 2, 0x22, 0x31, 2, 0, 0x32, 0x10, 0x36, 0xFF, 1, 0, 0,
                ] : [0xF1, 0x06, 1, 2, 1, 0, 3, 0, 2, 0, 1, 0x10, 2, 0x31, 2, 0, 0x32, 0x10, 0x36, 0xFF, 1, 0, 0]
                touchAssignments.update(capability)
                let selected: [UInt8] = galleryModel.isEarbuds ? [0, 0x20] : [0]
                touchAssignments.update([0xF3, 0x06, UInt8(selected.count)] + Array(repeating: 0, count: selected.count))
                touchAssignments.update([0xF7, 0x06, UInt8(selected.count)] + selected)
            }
            legacyControls = controls
            legacyOptimizer = SonyLegacyOptimizer(supportedFunctions: controls.supportedFunctions)
            legacySurround = SonyLegacySoundEffect(kind: .surround, supportedFunctions: controls.supportedFunctions)
            legacySoundPosition = SonyLegacySoundEffect(kind: .soundPosition, supportedFunctions: controls.supportedFunctions)
            if galleryModel == .whXM3 {
                for payload: [UInt8] in [[0x41, 1, 5, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0], [0x43, 1, 0], [0x47, 1, 0]] {
                    legacySurround.update(payload)
                }
                for payload: [UInt8] in [[0x41, 2, 1], [0x43, 2, 0], [0x47, 2, 0]] {
                    legacySoundPosition.update(payload)
                }
            }
            batteries = controls.batteries
            equalizer = SonyEqualizer(supportedFunctions: controls.supportedFunctions, generation: .v1)
            let presets: [UInt8] = [0, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0]
            equalizer.update([0x51, 1, 6, 21, UInt8(presets.count)] + presets.flatMap { [$0, 0] })
            let bands: [UInt8] = SonyEqualizerBand.legacy.flatMap {
                [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)]
            }
            equalizer.update([0x5B, 1, 6] + bands)
            equalizer.update([0x53, 1, 0])
            equalizer.update([0x57, 1, 0x16, 0])
            customEqualizer = equalizer.flatSettings!
            asmType = 0x02
            availableNoiseModes = controls.noiseCapability!.modes
            bluetoothLEHash = nil
            return
        }
        supportedFunctions = [0x11, 0x12, 0x14, 0x23, 0x25, 0x40, 0x44, 0x90, 0xA1, 0xD1, 0xD2, 0xE2, 0xE7, 0xF1, 0xF3, 0xFF, 0xFC]
        supportedFunctions.insert(0x50)
        supportedFunctions.insert(galleryModel == nil ? 0x6D : 0x6B)
        supportedFunctions.formUnion(deviceModel.isEarbuds ? [0x29, 0x2A] : [0x20])
        if let galleryModel {
            if ![.wfXM5, .wfXM6, .whXM6, .wh1000XX].contains(galleryModel) { supportedFunctions.remove(0xFF) }
            if !galleryModel.isEarbuds { supportedFunctions.remove(0xF3) }
            if galleryModel == .whCH720N { supportedFunctions.subtract([0xF1, 0xFC, 0xD1, 0x25]); supportedFunctions.insert(0x24) }
            if galleryModel == .whULT900N { supportedFunctions.remove(0xFC) }
            if galleryModel == .whXM5 { supportedFunctions.remove(0xD1) }
            if galleryModel == .wfXM6 { supportedFunctions.remove(0xD2) }
            if [.whULT900N, .wh1000XX].contains(galleryModel) { supportedFunctions.remove(0x50) }
        }
        equalizer = SonyEqualizer(supportedFunctions: supportedFunctions)
        let tenBandEqualizer = galleryModel.map { [.wfXM6, .whXM6].contains($0) }
            ?? CommandLine.arguments.contains("--ten-band-equalizer")
        if tenBandEqualizer, galleryModel == nil { deviceName = "Ten-band test device" }
        let presets: [UInt8] = tenBandEqualizer
            ? [0x00, 0x30, 0x31, 0x32, 0x33, 0xA0, 0xA1, 0xA2]
            : [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0]
        equalizer.update([0x51, 0x00, tenBandEqualizer ? 10 : 6, tenBandEqualizer ? 13 : 21, UInt8(presets.count)]
                         + presets.flatMap { [$0, 0] })
        let frequencies = tenBandEqualizer
            ? [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
            : [400, 1000, 2500, 6300, 16000]
        let bands: [UInt8] = (tenBandEqualizer ? [] : [0x10, 0, 1])
            + frequencies.flatMap { [UInt8(1), UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        equalizer.update([0x5B, 0x00, UInt8(bands.count / 3)] + bands)
        equalizer.update([0x53, 0x00, 0])
        equalizer.update([0x57, 0x00, tenBandEqualizer ? 0x30 : 0x16, 0])
        customEqualizer = equalizer.flatSettings ?? .flat
        if deviceModel == .wfXM5 || galleryModel == .wfXM6 { supportedFunctions.insert(0xF6) }
        if supportsEarpieceSelection { supportedFunctions.insert(0xF7) }
        earTipFit = SonyEarTipFit(supportedFunctions: supportedFunctions)
        headGesturePractice = SonyHeadGesturePractice(supportedFunctions: supportedFunctions)
        audioFeatures = SonyAudioFeatures(supportedFunctions: supportedFunctions)
        playback = SonyPlayback(supportedFunctions: supportedFunctions)
        playback.update([0xA1, 0x01, 31, 16])
        playback.update([0xA3, 0x01, 0x00, 0x02, CommandLine.arguments.contains("--call-active") ? 1 : 0])
        playback.update([0xA7, 0x20, 12])
        playback.update([0xA7, 0x21, 7])
        playback.update([0xA7, 0x01, 1, 0, 1, 0, 1, 0, 1, 0])
        let unknownConnections = CommandLine.arguments.contains("--unknown-bud-connections")
        let leftConnection: UInt8 = unknownConnections ? 0xFF : CommandLine.arguments.contains("--left-disconnected") ? 0 : 1
        let rightConnection: UInt8 = unknownConnections ? 0xFF : CommandLine.arguments.contains("--right-disconnected") ? 0 : 1
        for payload: [UInt8] in [
            [0x13, 0x01, leftConnection, rightConnection],
            [0x13, 0x02, 0x02], [0xE1, 0x01, 0x02], [0xE3, 0x01, 0x00], [0xE7, 0x01, 0x01],
            [0xE1, 0x05, 0x03, 0x00, 0x01, 0x02, 0x01, 0x00],
            [0xE3, 0x05, 0x00, 0x00], [0xE7, 0x05, 0x00],
        ] {
            audioFeatures.update(payload)
        }
        if let galleryModel {
            let dsee: UInt8 = galleryModel == .wh1000XX ? 3 : [.whCH720N, .whULT900N].contains(galleryModel) ? 1 : 2
            audioFeatures.update([0xE1, 0x01, dsee])
            if ![.wfXM5, .wfXM6, .whXM6, .wh1000XX].contains(galleryModel) {
                audioFeatures.update([0xE1, 0x05, 2, 0, 1, 0])
            }
        }
        if CommandLine.arguments.contains("--voice-assistant") || CommandLine.arguments.contains("--voice-assistant-invisible") {
            supportedFunctions.insert(0xF5)
        }
        if CommandLine.arguments.contains("--assistant-selection") || CommandLine.arguments.contains("--assistant-selection-unknown") {
            supportedFunctions.insert(0xF4)
        }
        systemFeatures = SonySystemFeatures(supportedFunctions: supportedFunctions)
        for feature in SonySystemFeature.allCases {
            let suffix: [UInt8] = feature == .speakToChat ? [0x01] : []
            systemFeatures.update([0xF3, feature.rawValue, 0x00] + suffix)
            systemFeatures.update([0xF7, feature.rawValue, feature == .pauseOnRemoval ? 0x00 : 0x01] + suffix)
        }
        if CommandLine.arguments.contains("--voice-assistant-invisible") { systemFeatures.update([0xF5, 0x05, 2]) }
        if supportedFunctions.contains(0xF4) {
            systemFeatures.update([0xF1, 0x04, 0x03, 4, 0x30, 0x31, 0x32, 0x33])
            systemFeatures.update([0xF3, 0x04, 0])
            systemFeatures.update([0xF7, 0x04, CommandLine.arguments.contains("--assistant-selection-unknown") ? 0xFE : 0x30])
        }
        systemFeatures.update([0xFB, 0x0C, 0x00, 0x01])
        for payload: [UInt8] in [[0x21, 0x05, 2, 0x10, 0x11], [0x23, 0x05, 0], [0x27, 0x05, 0x10, 0]] {
            systemFeatures.update(payload)
        }
        if galleryModel == .whCH720N {
            for payload: [UInt8] in [[0x21, 0x04, 2, 0, 0x11], [0x23, 0x04, 0], [0x27, 0x04, 0, 0]] {
                systemFeatures.update(payload)
            }
        }
        let sidetoneTitle = Array("SIDETONE_SETTING".utf8)
        let sidetoneSummary = Array("SIDETONE_SETTING_SUMMARY".utf8)
        systemFeatures.update([0xD1, 0xD1, 0, 1, UInt8(sidetoneTitle.count)] + sidetoneTitle + [UInt8(sidetoneSummary.count)] + sidetoneSummary)
        systemFeatures.update([0xD3, 0xD1, 0])
        systemFeatures.update([0xD7, 0xD1, 0, 1])
        let multipointTitle = Array("MULTIPOINT_SETTING".utf8)
        systemFeatures.update([0xD1, 0xD2, 0, 1, UInt8(multipointTitle.count)] + multipointTitle + [0])
        systemFeatures.update([0xD3, 0xD2, 0])
        systemFeatures.update([0xD7, 0xD2, 0, 0])
        simulatedMultipointEnabled = true
        touchAssignments = SonyTouchAssignments(supportedFunctions: supportedFunctions)
        touchAssignments.update([0xF1, 0x03, 0x02,
            0x00, 0x00, 0x35, 0x03,
            0x35, 0x02, 0x00, 0x00, 0x01, 0x10, 0x10,
            0x20, 0x04, 0x00, 0x00, 0x20, 0x01, 0x21, 0x02, 0x22, 0x10, 0x30,
            0x43, 0x02, 0x00, 0x00, 0x01, 0x10, 0x10,
            0x01, 0x00, 0x20, 0x02,
            0x35, 0x02, 0x00, 0x00, 0x01, 0x10, 0x10,
            0x20, 0x04, 0x00, 0x00, 0x20, 0x01, 0x21, 0x02, 0x22, 0x10, 0x30,
        ])
        touchAssignments.update([0xF3, 0x03, 0x02, 0x00, 0x00])
        touchAssignments.update([0xF7, 0x03, 0x02, 0x35, 0x20])
        if CommandLine.arguments.contains("--touch-customization") {
            touchAssignments.update([0xF1, 0x03, 0x02,
                0x00, 0x00, 0x35, 0x02,
                0x35, 0x01, 0x01, 0x10, 0x10, 0x00, 0x02, 0x04, 0x01, 0x02, 0x03, 0x04,
                0x20, 0x04, 0x00, 0x00, 0x20, 0x01, 0x21, 0x02, 0x22, 0x10, 0x30,
                0x01, 0x00, 0x20, 0x02,
                0x35, 0x01, 0x01, 0x10, 0x10, 0x00, 0x02, 0x04, 0x01, 0x02, 0x03, 0x04,
                0x20, 0x04, 0x00, 0x00, 0x20, 0x01, 0x21, 0x02, 0x22, 0x10, 0x30,
            ])
            touchAssignments.update([0xFB, 0x03, 0x01, 0x35, 0x01, 0x00, 0x02])
        }
        supportedFunctions2 = simulatedTable2Functions ?? [0x31, 0x32, 0x42, 0x53]
        table2CapabilitiesSession = controlSession
        if galleryModel == .whCH720N || galleryModel == .wh1000XX { supportedFunctions2.remove(0x53) }
        supportsTable2 = true
        if galleryModel.map({ [.wfXM6, .wh1000XX].contains($0) }) ?? CommandLine.arguments.contains("--power-settings") {
            if galleryModel == nil { deviceName = "Power settings test device" }
            if galleryModel != .wh1000XX { supportedFunctions.insert(0x2B) }
            supportedFunctions2.insert(0x22)
            powerFeatures = SonyPowerFeatures(supportedFunctions: supportedFunctions, supportedFunctions2: supportedFunctions2)
            for payload: [UInt8] in [[0x21, 1, 85], [0x23, 1, 0, 1], [0x27, 1, 0]] {
                powerFeatures.update(payload, frameType: 0x0E)
            }
            for payload: [UInt8] in [[0x21, 0x0B, 20, 1, 0xE2, 0], [0x27, 0x0B, 0, 0]] {
                powerFeatures.update(payload, frameType: 0x0C)
            }
        }
        simulatedSourceID = 1
        simulatedDeviceConnections = [:]
        multipoint = SonyMultipoint(supportedFunctions: supportedFunctions2)
        let maximumConnections: UInt8 = CommandLine.arguments.contains("-ui-testing") && CommandLine.arguments.contains("--four-source-devices") ? 4 : 2
        multipoint.update([0x31, 0x02, 8, maximumConnections, 0])
        multipoint.update([0x33, 0x02, 0, 0])
        multipoint.update([0x37, 0x01, 1])
        multipoint.update(simulatedMultipointInventory(selected: 1))
        soundPressure = SonySoundPressure(supportedFunctions: supportedFunctions2)
        wearingStatus = SonyWearingStatus(supportedFunctions: supportedFunctions2)
        soundPressure.update([0x51, 0x03, 1, 0, 0, 0, 0, 5, 16])
        soundPressure.update([0x57, 0x03, 0])
        voiceGuidance = SonyVoiceGuidance(supportedFunctions: supportedFunctions2)
        for payload: [UInt8] in [
            [0x41, 0x01, 0, 0, 0, 0, 1, 2, 1, 0x10],
            [0x43, 0x01, 0, 0], [0x47, 0x01, 0, 1],
            [0x47, 0x20, 0],
        ] {
            voiceGuidance.update(payload)
        }
    }

    func simulateGalleryDevice(model: SonyDeviceModel, color: UInt8? = nil, noiseMode: NoiseControlMode = .ambient,
                               visualFinish: String? = nil) {
        guard isSimulated else { return }
        precondition(model != .unknown && noiseMode != .wind)
        simulateDeviceConnection(named: model.name, galleryModel: model, galleryColor: color)
        if let visualFinish {
            precondition(color == nil, "A visual finish must not fabricate a reported color.")
            guard let suffix = model.galleryArtworkFinishes[visualFinish] else {
                preconditionFailure("Choose an official finish for this gallery model.")
            }
            simulatedArtworkSuffix = suffix
        }
        noiseControlMode = noiseMode
        if let payload = legacyControls?.noiseControlPayload(mode: noiseMode, ambientLevel: ambientLevel, focusOnVoice: false) {
            legacyControls?.update([0x69] + payload.dropFirst())
        }
        if CommandLine.arguments.contains("--gallery-control-timeout") { fail(String(localized: "The headphones did not respond.")) }
        if model == .wfXM5, CommandLine.arguments.contains("--finder-worn") || CommandLine.arguments.contains("--finder-no-wear-sensor") {
            firmwareVersion = "6.1.0"
            if CommandLine.arguments.contains("--finder-worn") {
                wearingStatus = SonyWearingStatus(supportedFunctions: [0xF0])
            }
        }
    }

    func simulateProtocolData(_ data: Data, beginConnection: Bool = false, expectedBLEHash: String? = nil,
                              pairedPeripheralID: UUID? = nil, connectedPeripheralID: UUID? = nil, session: UInt64? = nil) {
        guard isSimulated, session == nil || session == controlSession else { return }
        if beginConnection {
            closeSonyLink()
            expectedBLEIdentity = expectedBLEHash.map { .verified(hash: $0, peripheralIdentifier: nil) }
                ?? pairedPeripheralID.map { .paired(peripheralIdentifier: $0) }
            controlPeripheralID = connectedPeripheralID
            usesBluetoothLE = expectedBLEIdentity != nil
            beginHandshake()
        }
        receive(data)
    }

    func simulateProtocolMessage(_ payload: [UInt8], type: UInt8 = 0x0C, beginConnection: Bool = false,
                                 expectedBLEHash: String? = nil, pairedPeripheralID: UUID? = nil,
                                 connectedPeripheralID: UUID? = nil, session: UInt64? = nil) {
        let sequence: UInt8 = beginConnection ? 0 : lastReceivedSequence.map { 1 - $0 } ?? 0
        simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: sequence, payload: payload),
                             beginConnection: beginConnection, expectedBLEHash: expectedBLEHash,
                             pairedPeripheralID: pairedPeripheralID, connectedPeripheralID: connectedPeripheralID, session: session)
    }
    #endif

    func start(authorization: @escaping @Sendable () -> CBManagerAuthorization = { CBManager.authorization },
               initializeBluetooth: @escaping @Sendable () -> Void = { _ = IOBluetoothDevice.pairedDevices() }) {
        guard !displayOnly, !isSystemSleeping, !isSimulated, refreshTimer == nil, !isInitializingBluetooth else { return }
        isInitializingBluetooth = true
        bluetoothAuthorization = authorization()
        linkState = .searching
        Self.logger.info("Initializing Bluetooth coordinator")
        let identifier = UUID()
        bluetoothInitializationID = identifier
        Self.initializeBluetooth(authorization: authorization, initialize: initializeBluetooth) { [weak self] authorization in
            guard let self, self.bluetoothInitializationID == identifier else { return }
            self.bluetoothInitializationID = nil
            self.finishBluetoothInitialization(authorization: authorization)
        }
    }

    static func initializeBluetooth(authorization: @escaping @Sendable () -> CBManagerAuthorization,
                                    initialize: @escaping @Sendable () -> Void,
                                    completion: @escaping @MainActor @Sendable (CBManagerAuthorization) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            initialize()
            Task { @MainActor in completion(authorization()) }
        }
    }

    func stop() {
        bluetoothInitializationID = nil
        isInitializingBluetooth = false
        isBluetoothInitialized = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        systemWillSleep()
    }

    func reportBluetoothAuthorization(_ authorization: CBManagerAuthorization) {
        bluetoothAuthorization = authorization
        if authorization != .allowedAlways, authorization != .notDetermined {
            linkState = .failed(String(localized: "Bluetooth access is not allowed."))
            lastErrorMessage = String(localized: "Bluetooth access is not allowed.")
        } else if displayOnly {
            linkState = authorization == .notDetermined ? .searching : .disconnected
            lastErrorMessage = nil
        }
    }

    private func finishBluetoothInitialization(authorization: CBManagerAuthorization) {
        isInitializingBluetooth = false
        reportBluetoothAuthorization(authorization)
        guard bluetoothAuthorization == .allowedAlways else { return }
        isBluetoothInitialized = true
        Self.logger.info("Bluetooth coordinator initialized")
        refresh(shouldOpenLink: reconnectAutomatically)
        guard !isSimulated else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func setReconnectAutomatically(_ enabled: Bool) {
        reconnectAutomatically = enabled
        guard !isSystemSleeping, isBluetoothInitialized, connectionTransition?.isFinished != false,
              multipointTransition?.isFinished != false, recoveryUsesBLE == nil else { return }
        if enabled {
            cancelScheduledRetry(resetAttempts: true)
            refresh(shouldOpenLink: true)
            requestCurrentSettings()
        } else {
            if bleTransport?.shouldCancelAutomaticConnection == true {
                closeSonyLink()
                linkState = .disconnected
            }
            retryWorkItem?.cancel()
            retryWorkItem = nil
            nextRetryDate = nil
            retrySecondsRemaining = nil
        }
    }

    func refresh() {
        guard !isSystemSleeping, connectionTransition?.isFinished != false, multipointTransition?.isFinished != false,
              recoveryUsesBLE == nil else { return }
        cancelScheduledRetry(resetAttempts: true)
        if isReady, hasExpiredControlRead, powerOffState == nil, !isRunningHeadphoneTest,
           earbudFinder?.isBusy != true, earbudFinder?.mayBeRinging != true,
           sourceTransition?.isFinished != false, deviceActionTransition?.isFinished != false,
           pendingChanges.isEmpty, pendingPlaybackCommand == nil, !isEqualizerUpdatePending,
           !isApplyingChange, ambientWorkItem == nil, requestedNoiseControlPayload == nil {
            let bleTarget = usesBluetoothLE ? expectedBLEIdentity : nil
            let model = deviceModel
            closeSonyLink()
            linkState = .disconnected
            if let bleTarget {
                openBluetoothLE(target: bleTarget, model: model)
                return
            }
        }
        refresh(shouldOpenLink: true, automatically: false)
        requestCurrentSettings()
    }

    func retryControlsIfNeeded() -> Bool {
        guard !displayOnly, !isSystemSleeping, isBluetoothInitialized, reconnectAutomatically,
              isDeviceConnected, powerOffState == nil, !isRunningHeadphoneTest,
              stage == .idle, channel == nil, bleTransport == nil, classicConnectionID == nil,
              serviceDiscoveries.isEmpty, recoveryUsesBLE == nil,
              connectionTransition?.isFinished != false, connectionTransition?.phase != .failed,
              multipointTransition?.isFinished != false,
              !(multipointTransition?.phase == .failed && multipointConnection != nil),
              sourceTransition?.isFinished != false,
              deviceActionTransition?.isFinished != false, canRecoverDeviceAction,
              nextRetryDate.map({ $0 <= Date() }) ?? true,
              let device, device.isClassicConnected() else { return false }
        cancelScheduledRetry(resetAttempts: false)
        openSonyLink(automatically: true)
        return true
    }

    func systemWillSleep() {
        guard !isSystemSleeping else { return }
        isSystemSleeping = true
        pairedDeviceInventory = nil
        if connectionTransition?.isFinished == true, connectionTransition?.phase != .failed {
            clearFinishedConnectionChange()
        }
        closeSonyLink()
        linkState = .disconnected
    }

    func systemDidWake() {
        guard isSystemSleeping else { return }
        isSystemSleeping = false
        if multipointTransition?.phase == .recovering || connectionTransition?.phase == .recovering || recoveryUsesBLE != nil {
            retryAttempt = 0
            multipointRecoveryAttempts = 0
            scheduleRetry()
        } else {
            refresh(shouldOpenLink: reconnectAutomatically)
        }
    }

    func refreshEqualizer(trackConfirmation: Bool = false) {
        guard powerOffState == nil, !isRunningHeadphoneTest, stage == .ready, deviceActionTransition?.isFinished != false else { return }
        guard let query = equalizer.parameterQueryPayload else { return }
        for payload in equalizer.queryPayloads where payload != query {
            if payload.first == 0x50, equalizer.capabilities != nil { continue }
            if payload.first == 0x52, equalizer.status != nil { continue }
            if payload.first == 0x5A, equalizer.bandInformation != nil { continue }
            send(payload)
        }
        if trackConfirmation {
            guard connectionTransition?.isFinished != false, !isEqualizerUpdatePending,
                  pendingChanges[.equalizerReadback] == nil else { return }
            sendSetting(query, setting: .equalizerReadback)
        } else {
            send(query)
        }
    }

    private func poll() {
        guard !isSystemSleeping else { return }
        expireCaseBattery(at: Date())
        updateRetryCountdown()
        refresh(shouldOpenLink: reconnectAutomatically)
        guard stage == .ready else { return }
        syncPollCount += 1
        if syncPollCount >= 5 {
            syncPollCount = 0
            requestCurrentSettings()
        }
    }

    private func requestCurrentSettings() {
        guard powerOffState == nil, !isRunningHeadphoneTest, stage == .ready, connectionTransition?.isFinished != false, sourceTransition?.isFinished != false,
              multipointTransition?.isFinished != false, deviceActionTransition?.isFinished != false else { return }
        for (key, read) in discoveryReads where read.transmitted && !read.resolved && !read.retried && read.timeout == nil {
            send(Array(key.dropFirst()), type: key[0], retryingDiscovery: true)
        }
        if let asmType {
            if protocolInformation?.generation == .v1 { send([0x62, 0x02]) }
            requestNoiseControl(asmType)
        }
        requestBattery()
        refreshEqualizer()
        if firmwareVersion == nil { send([0x04, 0x02]) }
        requestAudioFeatures()
    }

    private func beginDiscoveryRead(_ query: [UInt8], type: UInt8) {
        let key = [type] + query
        guard var read = discoveryReads[key] else { return }
        if read.transmitted { read.retryTransmitted = true }
        read.transmitted = true
        if read.resolved {
            discoveryReads[key] = read
            return
        }
        read.timeout?.cancel()
        let id = UUID()
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session,
                      let current = self.discoveryReads[key], current.id == id, current.timeout != nil else { return }
                self.discoveryReads[key]?.timeout?.cancel()
                self.discoveryReads[key]?.timeout = nil
                if !current.retried { self.send(query, type: type, retryingDiscovery: true) }
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        read.id = id
        read.timeout = timeout
        discoveryReads[key] = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func consumeDiscoveryRead(_ query: [UInt8], type: UInt8) -> Bool {
        let key = [type] + query
        guard var read = discoveryReads[key], read.transmitted else { return false }
        let shouldApply = !read.resolved
        read.resolved = true
        read.timeout?.cancel()
        read.timeout = nil
        discoveryReads[key] = read
        return shouldApply
    }

    private func resetDiscoveryReads() {
        for read in discoveryReads.values { read.timeout?.cancel() }
        discoveryReads = [:]
    }

    private func requestNoiseControl(_ type: UInt8) {
        guard noiseControlRead?.timedOut != true, !noiseControlSawValidChanging else { return }
        if noiseControl?.inquiryType == type {
            if noiseControl?.capabilities == nil { send([0x60, type]) }
            send([0x62, type])
            guard noiseControl?.capabilities != nil, noiseControl?.available != nil else { return }
        }
        send([0x66, type])
    }

    private func beginNoiseReadTimeout(_ query: [UInt8]) {
        guard noiseReadTimeouts[query] == nil else { return }
        let id = UUID()
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.noiseReadTimeouts[query]?.id == id else { return }
                if query.first == 0x66, self.noiseControlSawValidChanging, self.isReady {
                    self.noiseReadTimeouts[query] = nil
                    if self.noiseControlRead == nil {
                        self.noiseControlRead = NoiseControlRead(asmType: query[1], requestID: nil, resolvesUnconfirmed: false)
                    }
                    self.noiseControlRead?.timedOut = true
                    self.noiseControlRefresh?.work.cancel()
                    self.noiseControlRefresh = nil
                    self.verifyConnectionPreferenceIfNeeded()
                    return
                }
                self.fail(String(localized: "Noise control status was not received. Reconnect the headphones to try again."))
            }
        }
        noiseReadTimeouts[query] = (id, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func scheduleNoiseControlRefresh(_ inquiry: UInt8) {
        guard noiseControlRefresh == nil, !noiseControlSawValidChanging || !noiseControlRefreshAttempted else { return }
        if noiseControlSawValidChanging { noiseControlRefreshAttempted = true }
        let session = controlSession
        let id = UUID()
        let refresh = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.noiseControlRefresh?.id == id,
                      self.noiseControlRead?.timedOut != true else { return }
                self.noiseControlRefresh = nil
                if self.noiseControlSawValidChanging { self.noiseControlRead = nil }
                self.send([0x66, inquiry])
            }
        }
        noiseControlRefresh = (id, refresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: refresh)
    }

    private func beginLegacyOptionalReadTimeout(_ query: [UInt8]) {
        let id = UUID()
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.legacyOptionalReadTimeouts[query]?.id == id,
                      self.legacyOptionalReadTimeouts[query]?.work != nil else { return }
                self.legacyOptionalReadTimeouts[query]?.work = nil
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        legacyOptionalReadTimeouts[query] = (id, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func resetLegacyOptionalReads(preservingTimedOutReads: Bool = false) {
        for (query, timeout) in legacyOptionalReadTimeouts {
            if preservingTimedOutReads, timeout.work == nil { continue }
            legacyOptionalReadTimeouts.removeValue(forKey: query)?.work?.cancel()
        }
    }

    private func consumeLegacyOptionalRead(_ query: [UInt8]) -> Bool {
        legacyReads.remove(query)
        if let timeout = legacyOptionalReadTimeouts.removeValue(forKey: query) {
            timeout.work?.cancel()
            if timeout.work == nil {
                obsoleteLegacyBatteryReads.remove(query)
                if legacyControls?.batteryQueries.contains(query) == true
                    || equalizer.queryPayloads.contains(query)
                    || (query == [0x04, 0x02] && legacyControls != nil) {
                    send(query)
                }
                return false
            }
        }
        return true
    }

    private func beginLegacyDSEEReadTimeout(_ query: [UInt8]) {
        let id = UUID()
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.legacyDSEEReadTimeouts[query]?.id == id,
                      self.legacyDSEEReadTimeouts[query]?.work != nil else { return }
                self.legacyDSEEReadTimeouts[query]?.work = nil
                let obsolete = query[0] == 0xE2 ? self.legacyDSEEAvailabilityReadObsolete
                    : query[0] == 0xE6 && self.legacyDSEERead?.isObsolete == true
                if !obsolete {
                    self.legacyControls?.invalidateDSEERead(query)
                    if self.pendingChanges[.dsee] == nil, self.unconfirmedChanges[.dsee] == nil {
                        self.settingErrors[.dsee] = String(localized: "DSEE settings are unavailable.")
                    }
                }
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        legacyDSEEReadTimeouts[query] = (id, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func resetLegacyDSEEReads(preservingTimedOutReads: Bool = false) {
        for (query, timeout) in legacyDSEEReadTimeouts {
            if preservingTimedOutReads, timeout.work == nil { continue }
            legacyDSEEReadTimeouts.removeValue(forKey: query)?.work?.cancel()
        }
        if legacyDSEEReadTimeouts[[0xE6, 0x02]] == nil { legacyDSEERead = nil }
        if legacyDSEEReadTimeouts[[0xE2, 0x02]] == nil { legacyDSEEAvailabilityReadObsolete = false }
    }

    private func legacySoundEffectQueryKind(_ payload: [UInt8]) -> SonyLegacySoundEffect.Kind? {
        guard payload.count >= 2, let kind = SonyLegacySoundEffect.Kind(rawValue: payload[1]) else { return nil }
        let effect = legacySoundEffect(kind)
        return effect.isSupported && [effect.capabilityQuery, effect.statusQuery, effect.parameterQuery].contains(payload) ? kind : nil
    }

    private func beginLegacySoundEffectRead(_ query: [UInt8], kind: SonyLegacySoundEffect.Kind) {
        let setting = Setting.legacySoundEffect(kind)
        legacySoundEffectReads[query] = LegacySettingRead(
            requestID: query.first == 0x46 && settingTimeouts[setting] != nil ? settingRequests[setting] : nil,
            resolvesUnconfirmed: unconfirmedChanges[setting] != nil)
        let id = UUID()
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.legacySoundEffectReadTimeouts[query]?.id == id,
                      self.legacySoundEffectReadTimeouts[query]?.work != nil else { return }
                self.legacySoundEffectReadTimeouts[query]?.work = nil
                if self.legacySoundEffectReads[query]?.isObsolete != true {
                    if kind == .surround { self.legacySurround.invalidateRead(query) }
                    else { self.legacySoundPosition.invalidateRead(query) }
                    if self.pendingChanges[setting] == nil, self.unconfirmedChanges[setting] == nil {
                        self.settingErrors[setting] = String(localized: "\(kind.title) settings are unavailable.")
                    }
                }
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        legacySoundEffectReadTimeouts[query] = (id, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func resetLegacySoundEffectReads(preservingTimedOutReads: Bool = false) {
        for (query, timeout) in legacySoundEffectReadTimeouts {
            if preservingTimedOutReads, timeout.work == nil { continue }
            legacySoundEffectReadTimeouts.removeValue(forKey: query)?.work?.cancel()
            legacySoundEffectReads[query] = nil
        }
    }

    private func systemReadSetting(_ query: [UInt8]) -> Setting? {
        guard query.count == 2 else { return nil }
        if query == automaticPowerOff?.parameterQueryPayload { return .automaticPowerOff }
        if query[0] == 0xD6, query[1] == systemFeatures.sidetoneSlot { return .sidetone }
        if query[0] == 0xF6, query[1] == touchAssignments.inquiryType { return .touchAssignments }
        if protocolInformation?.generation == .v1 {
            return query == [0xF6, 0x03] && legacyControls?.wearingControl.isSupported == true
                ? .system(.pauseOnRemoval) : nil
        }
        if query == [0xE6, 0x01], audioFeatures.supportsDSEE { return .dsee }
        if query[0] == 0xF6 {
            if query[1] == 0x04, systemFeatures.voiceAssistant != nil { return .voiceAssistant }
            if let feature = SonySystemFeature(rawValue: query[1]), systemFeatures[feature] != nil { return .system(feature) }
        } else if query[0] == 0xFA {
            if query[1] == touchAssignments.inquiryType { return .touchCustomActions }
            if query[1] == 0x0C, systemFeatures.speakToChatOptions != nil { return .speakToChatOptions }
        }
        return nil
    }

    private func beginSystemRead(_ query: [UInt8]) {
        guard var read = systemReads[query] else { return }
        let setting = systemReadSetting(query)
        let parameterCommand: UInt8 = switch query[0] {
        case 0x20, 0x22: 0x26
        case 0xD0, 0xD2: 0xD6
        case 0xF0, 0xF2: 0xF6
        default: query[0]
        }
        read.errorSetting = setting ?? systemReadSetting([parameterCommand, query[1]])
        read.transmitted = true
        read.requestID = setting.flatMap { settingTimeouts[$0] != nil ? settingRequests[$0] : nil }
        read.resolvesUnconfirmed = setting.map { unconfirmedChanges[$0] != nil } ?? false
        if protocolInformation?.generation == .v1, query == [0xE6, 0x01] {
            read.requestID = isReady && connectionTransition?.readbackTransmitted(session: controlSession) == true ? connectionRequestID : nil
        }
        systemReads[query] = read
        if protocolInformation?.generation == .v1, query == [0xE6, 0x01], let transition = connectionTransition {
            switch transition.phase {
            case .awaitingUser, .replyQueued: return
            default: break
            }
        }
        scheduleSystemReadTimeout(query)
    }

    private func scheduleSystemReadTimeout(_ query: [UInt8]) {
        guard var read = systemReads[query], read.transmitted else { return }
        read.timeout?.cancel()
        read.id = UUID()
        let id = read.id
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.systemReads[query]?.id == id,
                      self.systemReads[query]?.timeout != nil else { return }
                if self.legacyControls?.connectionQuality.isSupported == true,
                   [[0xE0, 1], [0xE2, 1], [0xE6, 1]].contains(query) {
                    let name = String(localized: "Connection quality")
                    self.fail(String(localized: "\(name) settings were not received. Reconnect the headphones to try again."))
                    return
                }
                self.systemReads[query]?.timeout = nil
                self.systemReads[query]?.timedOut = true
                if self.systemReads[query]?.isObsolete == false, self.systemReads[query]?.isRetiredSidetoneRead == false {
                    self.systemFeatures.invalidateRead(query)
                    self.legacyControls?.invalidateSystemRead(query)
                    self.touchAssignments.invalidateRead(query)
                    if let setting = self.systemReads[query]?.errorSetting, setting != .dsee,
                       self.pendingChanges[setting] == nil, self.settingErrors[setting] == nil {
                        self.settingErrors[setting] = String(localized: "Headphone settings were not received. Refresh to try again.")
                    }
                }
                if query == [0xE6, 0x01] { self.invalidateExpiredDSEERead() }
                let bytes = query.map { String(format: "%02X", $0) }.joined(separator: " ")
                Self.logger.error("System read timeout; session=\(session) query=\(bytes, privacy: .private)")
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        read.timeout = timeout
        systemReads[query] = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func resetSystemReads(preservingTimedOutReads: Bool = false) {
        for (query, read) in systemReads {
            if preservingTimedOutReads, read.transmitted, read.timedOut { continue }
            systemReads.removeValue(forKey: query)?.timeout?.cancel()
        }
        queuedTouchChange = nil
    }

    private func invalidateExpiredDSEERead() {
        guard protocolInformation?.generation == .v2, let read = systemReads[[0xE6, 0x01]], read.timedOut,
              pendingChanges[.dsee] == nil, !read.isObsolete || unconfirmedChanges[.dsee] != nil else { return }
        audioFeatures.invalidateDSEERead()
        unconfirmedChanges[.dsee] = nil
        if settingErrors[.dsee] == nil { settingErrors[.dsee] = String(localized: "DSEE settings are unavailable.") }
    }

    private func clearSystemReadError(_ setting: Setting?) {
        guard let setting, settingErrors[setting] == String(localized: "Headphone settings were not received. Refresh to try again."),
              !systemReads.values.contains(where: { $0.errorSetting == setting && $0.timedOut }) else { return }
        settingErrors[setting] = nil
    }

    private func beginVoiceGuidanceRead(_ query: [UInt8]) {
        guard var read = voiceGuidanceReads[query], !read.transmitted else { return }
        read.transmitted = true
        if query[0] == 0x46 {
            let setting: Setting = query[1] == 1 ? .voiceGuidance : .voiceGuidanceVolume
            read.requestID = settingTimeouts[setting] != nil ? settingRequests[setting] : nil
            read.resolvesUnconfirmed = unconfirmedChanges[setting] != nil
        }
        let id = read.id
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.voiceGuidanceReads[query]?.id == id,
                      self.voiceGuidanceReads[query]?.timeout != nil else { return }
                self.voiceGuidanceReads[query]?.timeout = nil
                if self.voiceGuidanceReads[query]?.isObsolete == false { self.voiceGuidance.invalidateRead(query) }
                self.voiceGuidanceReads[query]?.isObsolete = true
                let bytes = query.map { String(format: "%02X", $0) }.joined(separator: " ")
                Self.logger.error("Voice guidance read timeout; session=\(session) query=\(bytes, privacy: .private)")
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        read.timeout = timeout
        voiceGuidanceReads[query] = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func resetVoiceGuidanceReads(preservingTimedOutReads: Bool = false) {
        for (query, read) in voiceGuidanceReads {
            if preservingTimedOutReads, read.transmitted, read.isObsolete, read.timeout == nil { continue }
            voiceGuidanceReads.removeValue(forKey: query)?.timeout?.cancel()
        }
    }

    private func beginPowerRead(_ query: [UInt8], type: UInt8) {
        let key = [type] + query
        guard var read = powerReads[key] else { return }
        if query[0] == 0x26 {
            if read.setting == .autoPowerSave,
               settingTimeouts[.powerSaveEffect] != nil || unconfirmedChanges[.powerSaveEffect] != nil {
                read.setting = .powerSaveEffect
            }
            read.requestID = settingTimeouts[read.setting] != nil ? settingRequests[read.setting] : nil
            read.resolvesUnconfirmed = unconfirmedChanges[read.setting] != nil
        }
        read.transmitted = true
        let id = read.id
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.powerReads[key]?.id == id,
                      self.powerReads[key]?.timeout != nil else { return }
                self.powerReads[key]?.timeout = nil
                self.powerReads[key]?.timedOut = true
                if self.powerReads[key]?.isObsolete == false, self.powerReads[key]?.isRetired == false {
                    self.powerFeatures.invalidateRead(query, frameType: type)
                }
                let bytes = query.map { String(format: "%02X", $0) }.joined(separator: " ")
                Self.logger.error("Power read timeout; session=\(session) type=\(type) query=\(bytes, privacy: .private)")
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        read.timeout = timeout
        powerReads[key] = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func resetPowerReads(preservingTimedOutReads: Bool = false) {
        for (key, read) in powerReads {
            if preservingTimedOutReads, read.transmitted, read.timedOut { continue }
            powerReads.removeValue(forKey: key)?.timeout?.cancel()
        }
    }

    private func requestAudioFeatures() {
        if let legacyControls {
            for payload in legacyControls.dsee.queryPayloads + legacyControls.connectionQuality.queryPayloads + legacyControls.wearingControl.queryPayloads
                + (legacyControls.automaticPowerOff?.queryPayloads ?? []) + touchAssignments.queryPayloads { send(payload) }
            for payload in legacySurround.queryPayloads + legacySoundPosition.queryPayloads { send(payload) }
            for payload in playback.queryPayloads {
                if payload == playback.capabilityQueryPayload, playback.hasReceivedCapabilities { continue }
                send(payload)
            }
            for payload in voiceGuidance.queryPayloads { send(payload, type: 0x0E) }
            return
        }
        guard protocolInformation?.generation != .v1 else { return }
        for payload in audioFeatures.queryPayloads + systemFeatures.queryPayloads + powerFeatures.queryPayloads(frameType: 0x0C) + touchAssignments.queryPayloads + playback.queryPayloads {
            if payload == [0xE0, 0x01], audioFeatures.dseeType != nil { continue }
            if payload == [0xE0, 0x05], audioFeatures.supportedConnectionModes != nil { continue }
            if payload == playback.capabilityQueryPayload, playback.hasReceivedCapabilities { continue }
            send(payload)
        }
        for payload in voiceGuidance.queryPayloads + multipoint.queryPayloads + soundPressure.queryPayloads + powerFeatures.queryPayloads(frameType: 0x0E) { send(payload, type: 0x0E) }
    }

    private func beginBatteryRead(_ query: [UInt8]) {
        guard let read = batteryReads[query], !read.transmitted else { return }
        batteryReads[query]?.transmitted = true
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.batteryReads[query]?.id == read.id else { return }
                self.batteryReads[query]?.timedOut = true
                self.batteryReads[query]?.timeout = nil
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        batteryReads[query]?.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func resetBatteryReads() {
        for read in batteryReads.values { read.timeout?.cancel() }
        batteryReads = [:]
    }

    private func requestBattery() {
        if let legacyControls {
            for query in legacyControls.batteryQueries { send(query) }
            return
        }
        for type in SonyBatteries.queryTypes(supportedFunctions: supportedFunctions) { send([0x22, type]) }
    }

    func pairedDevices(automatically: Bool,
                       discover: () -> [IOBluetoothDevice] = { (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] }) -> [any SonyBluetoothDevice] {
        if automatically || isSimulated, let pairedDeviceInventory { return pairedDeviceInventory }
        return discover()
    }

    private func refresh(shouldOpenLink: Bool, automatically: Bool = true) {
        guard !displayOnly, !isSystemSleeping, powerOffState == nil, !isRunningHeadphoneTest else { return }
        guard classicConnectionID == nil else { return }
        guard canRecoverDeviceAction else { return }
        if let transition = multipointTransition, !transition.isFinished || (transition.phase == .failed && multipointConnection != nil && !isReady) {
            if shouldOpenLink, transition.phase == .recovering, retryWorkItem == nil,
               channel == nil, bleTransport == nil { scheduleMultipointRecovery() }
            return
        }
        guard connectionTransition?.phase != .failed, connectionTransition?.phase != .pairingRequired else { return }
        if hasOpenControlTransport {
            if !isDeviceConnected { isDeviceConnected = true }
            return
        }
        if bleTransport != nil { return }
        #if DEBUG
        if isSimulated, pairedDeviceInventory == nil {
            if !isDeviceConnected {
                finishUnavailableRefresh(.disconnected)
            } else if shouldOpenLink, stage == .idle {
                if deviceActionTransition?.phase == .failed { deviceActionRecoveryAttempts += 1 }
                beginHandshake()
            }
            return
        }
        #endif
        if connectionTransition?.phase == .recovering || recoveryUsesBLE != nil { return }
        guard isBluetoothInitialized else {
            start()
            return
        }
        let paired = pairedDevices(automatically: automatically)
        let supported = paired.filter {
            acceptsDeviceAddress($0.addressString ?? "") && (SonyDeviceModel(name: $0.name ?? "") != .unknown || verifiedIdentity(for: $0) != nil)
        }
        let match: (any SonyBluetoothDevice)?
        if connectionTransition.map({ !$0.isFinished || $0.phase == .failed }) == true, let transitionAddress {
            match = supported.first(where: { Self.normalizedAddress($0.addressString ?? "") == Self.normalizedAddress(transitionAddress) })
                ?? transitionDevice.flatMap { acceptsDeviceAddress($0.addressString ?? "") ? $0 : nil }
        } else {
            match = supported.first(where: { verifiedIdentity(for: $0) != nil })
                ?? supported.first(where: { Self.normalizedAddress($0.addressString ?? "") == address && $0.isClassicConnected() })
                ?? supported.first(where: { $0.isClassicConnected() }) ?? supported.first
        }
        guard let match else {
            finishUnavailableRefresh(.failed(String(localized: "Pair your Sony headphones in Bluetooth settings")))
            device = nil
            let unavailableAddress = pinnedAddress ?? ""
            if address != unavailableAddress { address = unavailableAddress }
            return
        }
        if !address.isEmpty, address != Self.normalizedAddress(match.addressString ?? "") { closeSonyLink() }
        device = match
        let name = match.name ?? String(localized: "Sony headphones")
        if deviceName != name { deviceName = name }
        let matchedAddress = Self.normalizedAddress(match.addressString ?? "")
        if address != matchedAddress { address = matchedAddress }
        let connected = match.isClassicConnected()
        if isDeviceConnected != connected { isDeviceConnected = connected }
        if !shouldOpenLink, linkState == .searching { linkState = .disconnected }
        guard isDeviceConnected else {
            if !lastReadyTransportWasBluetoothLE { retryAttempt = 0 }
            if shouldOpenLink, nextRetryDate.map({ $0 <= Date() }) ?? true,
               openPairedBluetoothLE(for: match, automatically: automatically) { return }
            finishUnavailableRefresh(.disconnected)
            if connectionTransition?.phase == .recovering { scheduleRetry() }
            return
        }
        if shouldOpenLink, channel == nil, stage == .idle {
            guard nextRetryDate.map({ $0 <= Date() }) ?? true else { return }
            nextRetryDate = nil
            retrySecondsRemaining = nil
            openSonyLink(automatically: automatically)
        }
    }

    private func finishUnavailableRefresh(_ state: LinkState) {
        if stage != .idle { closeSonyLink() }
        if isDeviceConnected { isDeviceConnected = false }
        if linkState != state { linkState = state }
    }

    @discardableResult
    func beginLegacyOptimizer() -> Bool {
        if legacyOptimizerTransition != nil { return true }
        guard legacyOptimizerUnavailableReason == nil else { return false }
        cancelScheduledRetry(resetAttempts: true)
        legacyOptimizer = SonyLegacyOptimizer(supportedFunctions: legacyControls?.supportedFunctions ?? [])
        legacyOptimizerTransition = SonyLegacyOptimizerTransition(session: controlSession)
        advanceLegacyOptimizer()
        return true
    }

    func startLegacyOptimizer(id: UUID) {
        guard legacyOptimizerTransition?.id == id, canStartLegacyOptimizer,
              legacyOptimizerTransition?.start(model: legacyOptimizer) == true else { return }
        advanceLegacyOptimizer()
    }

    func cancelLegacyOptimizer(id: UUID) {
        guard legacyOptimizerTransition?.id == id else { return }
        let pendingQuery = commandQueue.pending.map {
            $0.type == 0x0C && legacyOptimizerTransition?.initialQueries.contains($0.payload) == true
        } ?? false
        legacyOptimizerTransition?.cancel(hasPendingQuery: pendingQuery)
        advanceLegacyOptimizer()
    }

    func dismissLegacyOptimizer(id: UUID) {
        guard legacyOptimizerTransition?.id == id, legacyOptimizerTransition?.canDismiss == true,
              legacyOptimizerTransition?.phase != .interrupted else { return }
        legacyOptimizerTransition = nil
        legacyOptimizerTimeoutPhase = nil
    }

    private func advanceLegacyOptimizer() {
        guard let transition = legacyOptimizerTransition else { return }
        if legacyOptimizerTimeoutPhase != transition.phase {
            legacyOptimizerTimeout?.cancel()
            legacyOptimizerTimeout = nil
            legacyOptimizerTimeoutPhase = transition.phase
        }
        if transition.waitingForReport, legacyOptimizerTimeout == nil {
            let duration = legacyOptimizer.capability.map {
                Int($0.optimizationSeconds) + Int($0.personalSeconds) + Int($0.pressureSeconds)
            } ?? 0
            let seconds = transition.phase == .running ? max(30, duration + 15) : 8
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.controlSession == transition.session,
                          self.legacyOptimizerTransition?.id == transition.id,
                          self.legacyOptimizerTransition?.phase == transition.phase else { return }
                    self.finishLegacyOptimizerTimeout()
                }
            }
            legacyOptimizerTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: timeout)
        }
        guard transition.session == controlSession, isReady, commandQueue.pending == nil else { return }
        if let payload = transition.expectedPayload, !transition.commandTransmitted {
            send(payload)
        } else if let query = transition.pendingQueries.first {
            send(query)
        }
    }

    private func finishLegacyOptimizerTimeout() {
        if commandQueue.pending != nil, transmittedFrame == nil {
            fail(String(localized: "The optimizer command could not be confirmed. Its outcome is unknown."))
            return
        }
        legacyOptimizerTransition?.timeout()
        advanceLegacyOptimizer()
    }

    private func receiveLegacyOptimizer(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == 1, [0x81, 0x83, 0x85, 0x87, 0x89].contains(payload[0]) else { return false }
        guard legacyOptimizerTransition?.accepts(payload, session: controlSession) == true else { return true }
        var updated = legacyOptimizer
        guard updated.update(payload) else { return true }
        let superseded = legacyOptimizerTransition?.isSupersededStatusResponse(payload) == true
        legacyOptimizerTransition?.receive(payload, model: updated)
        if !superseded { legacyOptimizer = updated }
        advanceLegacyOptimizer()
        return true
    }

    #if DEBUG
    private func simulateLegacyOptimizerResult() {
        guard isSimulated, simulatesSettingReplies, let transition = legacyOptimizerTransition else { return }
        guard !CommandLine.arguments.contains("--gallery-hold-test-replies") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == transition.session,
                      self.legacyOptimizerTransition?.id == transition.id,
                      self.legacyOptimizerTransition?.phase == .running else { return }
                self.dispatch([0x85, 1, 0, 0x11], type: 0x0C)
            }
        }
    }
    #endif

    @discardableResult
    func beginHeadGesturePractice() -> Bool {
        if headGesturePracticeTransition != nil { return true }
        guard headGesturePracticeUnavailableReason == nil else { return false }
        cancelScheduledRetry(resetAttempts: true)
        headGesturePractice.resetGestureEvents()
        headGesturePracticeTransition = SonyHeadGesturePracticeTransition(session: controlSession)
        advanceHeadGesturePractice()
        return true
    }

    func startHeadGesturePractice(id: UUID) {
        guard headGesturePracticeTransition?.id == id, canStartHeadGesturePractice,
              headGesturePracticeTransition?.start(model: headGesturePractice) == true else { return }
        advanceHeadGesturePractice()
    }

    func cancelHeadGesturePractice(id: UUID, dismissWhenFinished: Bool = false) {
        guard headGesturePracticeTransition?.id == id else { return }
        headGesturePracticeTransition?.cancel(dismissWhenFinished: dismissWhenFinished)
        advanceHeadGesturePractice()
    }

    func dismissHeadGesturePractice(id: UUID) {
        guard headGesturePracticeTransition?.id == id, headGesturePracticeTransition?.canDismiss == true,
              headGesturePracticeTransition?.phase != .interrupted else { return }
        headGesturePracticeTransition = nil
        headGesturePracticeTimeoutPhase = nil
    }

    private func advanceHeadGesturePractice() {
        guard let transition = headGesturePracticeTransition else { return }
        let changed = headGesturePracticeTimeoutPhase != transition.phase
        if changed {
            headGesturePracticeTimeout?.cancel()
            headGesturePracticeTimeout = nil
            headGesturePracticeTimeoutPhase = transition.phase
        }
        if transition.dismissWhenFinished, transition.phase == .finished {
            dismissHeadGesturePractice(id: transition.id)
            return
        }
        if transition.waitingForReport, headGesturePracticeTimeout == nil {
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.controlSession == transition.session,
                          self.headGesturePracticeTransition?.id == transition.id,
                          self.headGesturePracticeTransition?.phase == transition.phase else { return }
                    self.finishHeadGesturePracticeTimeout()
                }
            }
            headGesturePracticeTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
        guard transition.session == controlSession, isReady else { return }
        if changed, transition.phase == .checking { send(SonyHeadGesturePractice.queryPayload) }
        if let payload = headGesturePracticeTransition?.expectedPayload,
           headGesturePracticeTransition?.commandTransmitted == false, commandQueue.pending == nil { send(payload) }
    }

    private func finishHeadGesturePracticeTimeout() {
        let phase = headGesturePracticeTransition.map { String(describing: $0.phase) } ?? "none"
        Self.logger.notice("Head-gesture practice timeout; session=\(self.controlSession) phase=\(phase, privacy: .public)")
        if commandQueue.pending != nil, transmittedFrame == nil {
            fail(String(localized: "The practice command could not be confirmed. Its outcome is unknown."))
            return
        }
        headGesturePracticeTransition?.timeout()
        advanceHeadGesturePractice()
    }

    private func receiveHeadGesturePractice(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == 0x10, [0xF3, 0xF5, 0xF9].contains(payload[0]) else { return false }
        if !isPracticingHeadGestures, payload[0] == 0xF5 {
            headGesturePractice.update(payload)
            return true
        }
        let owned = headGesturePracticeTransition?.accepts(payload, session: controlSession) == true
        let parsed = owned && headGesturePractice.update(payload)
        let phase = headGesturePracticeTransition.map { String(describing: $0.phase) } ?? "none"
        let bytes = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        Self.logger.notice("Head-gesture practice RX; session=\(self.controlSession) phase=\(phase, privacy: .public) owned=\(owned) valid=\(parsed) payload=\(bytes, privacy: .private)")
        guard parsed else { return true }
        headGesturePracticeTransition?.receive(payload, model: headGesturePractice)
        advanceHeadGesturePractice()
        return true
    }

    #if DEBUG
    private func simulateHeadGesturePracticeEvents() {
        guard isSimulated, simulatesSettingReplies, let transition = headGesturePracticeTransition else { return }
        var gestures = [SonyHeadGesturePractice.Gesture.nod, .shake]
        guard !CommandLine.arguments.contains("--gallery-hold-test-replies") else { return }
        if CommandLine.arguments.contains("--head-gesture-practice-success") { gestures += [.shake, .shake] }
        for (index, gesture) in gestures.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index + 1) * 0.3) { [weak self] in
                Task { @MainActor in
                    guard let self, self.controlSession == transition.session, self.headGesturePracticeTransition?.id == transition.id,
                          self.headGesturePracticeTransition?.phase == .practicing else { return }
                    self.dispatch([0xF9, 0x10, gesture.rawValue], type: 0x0C)
                }
            }
        }
    }
    #endif

    @discardableResult
    func beginEarTipFit() -> Bool {
        if earTipFitTransition != nil { return true }
        guard earTipFitUnavailableReason == nil else { return false }
        cancelScheduledRetry(resetAttempts: true)
        earTipFit = SonyEarTipFit(supportedFunctions: supportedFunctions)
        earTipFitTransition = SonyEarTipFitTransition(session: controlSession, supportsEarpieceSelection: earTipFit.supportsEarpieceSelection)
        advanceEarTipFit()
        return true
    }

    func startEarTipFit(id: UUID) {
        guard earTipFitTransition?.id == id, canStartEarTipFit,
              earTipFitTransition?.start(model: earTipFit) == true else { return }
        advanceEarTipFit()
    }

    func cancelEarTipFit(id: UUID, dismissWhenFinished: Bool = false) {
        guard earTipFitTransition?.id == id else { return }
        earTipFitTransition?.cancel(dismissWhenFinished: dismissWhenFinished)
        advanceEarTipFit()
    }

    func prepareEarTipFitAgain(id: UUID) {
        guard earTipFitTransition?.id == id else { return }
        earTipFitTransition?.prepareAgain()
        advanceEarTipFit()
    }

    func dismissEarTipFit(id: UUID) {
        guard earTipFitTransition?.id == id, earTipFitTransition?.canDismiss == true,
              earTipFitTransition?.phase != .interrupted else { return }
        earTipFitTransition = nil
        earTipFitTimeoutPhase = nil
    }

    private func clearHeadphoneTestsForExplicitConnection() -> Bool {
        guard earTipFitTransition?.canDismiss != false, headGesturePracticeTransition?.canDismiss != false,
              legacyOptimizerTransition?.canDismiss != false else { return false }
        if headphoneTestNeedsRecovery {
            closeSonyLink()
        }
        earTipFitTransition = nil
        earTipFitTimeoutPhase = nil
        headGesturePracticeTransition = nil
        headGesturePracticeTimeoutPhase = nil
        legacyOptimizerTransition = nil
        legacyOptimizerTimeoutPhase = nil
        return true
    }

    private func advanceEarTipFit() {
        guard let transition = earTipFitTransition else { return }
        if transition.shouldStartAgain, transition.session == controlSession, canStartEarTipFit {
            startEarTipFit(id: transition.id)
            return
        }
        let changed = earTipFitTimeoutPhase != transition.phase
        if changed {
            earTipFitTimeout?.cancel()
            earTipFitTimeout = nil
            earTipFitTimeoutPhase = transition.phase
        }
        if transition.dismissWhenFinished, transition.phase == .finished {
            dismissEarTipFit(id: transition.id)
            return
        }
        if transition.waitingForReport, earTipFitTimeout == nil {
            let seconds = transition.phase == .measuring ? max(30, (earTipFit.capability?.durationSeconds ?? 0) + 15) : 8
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.controlSession == transition.session,
                          self.earTipFitTransition?.id == transition.id,
                          self.earTipFitTransition?.phase == transition.phase else { return }
                    self.finishEarTipFitTimeout()
                }
            }
            earTipFitTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: timeout)
        }
        guard transition.session == controlSession, isReady else { return }
        if changed, transition.phase == .checking {
            for query in transition.initialQueries {
                send(query)
            }
        }
        if let payload = earTipFitTransition?.expectedPayload,
           earTipFitTransition?.commandTransmitted == false, commandQueue.pending == nil { send(payload) }
    }

    private func finishEarTipFitTimeout() {
        let phase = earTipFitTransition.map { String(describing: $0.phase) } ?? "none"
        let operation = earTipFit.operation.map { String(describing: $0) } ?? "none"
        Self.logger.notice("Ear-tip fit timeout; session=\(self.controlSession) phase=\(phase, privacy: .public) operation=\(operation, privacy: .public)")
        if commandQueue.pending != nil, transmittedFrame == nil {
            fail(String(localized: "The fit-test command could not be confirmed. Its outcome is unknown."))
            return
        }
        earTipFitTransition?.timeout()
        advanceEarTipFit()
    }

    private func receiveEarTipFit(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == 0x06 || payload[1] == 0x07,
              [0xF1, 0xF3, 0xF5, 0xF7, 0xF9, 0xFB, 0xFD].contains(payload[0]) else { return false }
        let owned = earTipFitTransition?.accepts(payload, session: controlSession) == true
        let parsed = owned && earTipFit.update(payload)
        let phase = earTipFitTransition.map { String(describing: $0.phase) } ?? "none"
        let bytes = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        Self.logger.notice("Ear-tip fit RX; session=\(self.controlSession) phase=\(phase, privacy: .public) owned=\(owned) valid=\(parsed) payload=\(bytes, privacy: .private)")
        guard parsed else { return true }
        earTipFitTransition?.receive(payload, model: earTipFit)
        advanceEarTipFit()
        return true
    }

    #if DEBUG
    private func simulateEarTipFitResult() {
        guard isSimulated, simulatesSettingReplies, let transition = earTipFitTransition else { return }
        guard !CommandLine.arguments.contains("--gallery-hold-test-replies") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == transition.session, self.earTipFitTransition?.id == transition.id,
                      self.earTipFitTransition?.phase == .measuring else { return }
                var result: [UInt8] = [0xFD, 0x06, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF]
                if CommandLine.arguments.contains("-ui-testing"),
                   CommandLine.arguments.contains("--fit-both-good")
                    || (CommandLine.arguments.contains("--fit-retry-both-good") && self.simulatedEarTipFitResultCount > 0) {
                    result[3] = 0
                }
                self.simulatedEarTipFitResultCount += 1
                self.dispatch(result, type: 0x0C)
            }
        }
    }
    #endif

    func powerOff(expectedSession: UInt64) {
        guard expectedSession == controlSession, canPowerOff else { return }
        cancelScheduledRetry(resetAttempts: true)
        resetPlaybackReads()
        resetSoundPressureRead()
        invalidateWearingStatus()
        powerOffRequestSession = controlSession
        powerOffState = .sending
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == expectedSession, self.powerOffState == .sending else { return }
                self.fail(String(localized: "The power-off command was not acknowledged. Its outcome is unknown."))
            }
        }
        acknowledgmentTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        send(Self.powerOffPayload)
    }

    private func clearPowerOffForExplicitConnection() {
        guard powerOffState != nil else { return }
        closeSonyLink()
        linkState = .disconnected
        powerOffState = nil
        powerOffRequestSession = nil
    }

    func connect() {
        guard !displayOnly, !isSystemSleeping, classicConnectionID == nil else { return }
        guard clearHeadphoneTestsForExplicitConnection() else { return }
        clearPowerOffForExplicitConnection()
        guard deviceActionTransition?.isFinished != false else { return }
        deviceActionTransition = nil
        if multipointTransition?.phase == .failed {
            multipointTransition = nil
            multipointConnection = nil
        }
        guard multipointTransition?.isFinished != false else { return }
        if (connectionTransition?.phase == .failed && (!isReady || connectionTransition?.generation == .v1)) || connectionTransition?.phase == .pairingRequired,
           transitionAddress != nil,
           connectionTransition?.retryRecovery() == true {
            cancelScheduledRetry(resetAttempts: true)
            connectionModeError = nil
            recoveryUsesBLE = nil
            if isReady {
                updateConnectionModeTimeout()
                verifyConnectionPreferenceIfNeeded()
            } else {
                scheduleRetry()
            }
            return
        }
        if bleTransport != nil { closeSonyLink() }
        cancelScheduledRetry(resetAttempts: true)
        if connectionTransition?.phase == .recovering || recoveryUsesBLE != nil {
            scheduleRetry()
            return
        }
        guard let device else {
            guard !isSimulated else { return }
            refresh()
            return
        }
        if !device.isClassicConnected(), openPairedBluetoothLE(for: device) { return }
        openClassicConnection(device, recovering: false)
    }

    func connectBluetoothLE() {
        guard !displayOnly, !isSystemSleeping else { return }
        guard clearHeadphoneTestsForExplicitConnection() else { return }
        clearPowerOffForExplicitConnection()
        guard deviceActionTransition?.isFinished != false else { return }
        deviceActionTransition = nil
        guard multipointTransition?.isFinished != false else { return }
        if let device, openPairedBluetoothLE(for: device, allowPairedBootstrap: true) { return }
        guard let hash = bluetoothLEHash ?? transitionHash else {
            bluetoothLEDiagnosticError = nil
            bluetoothLEError = String(localized: "Connect the headphones in Bluetooth settings, then try again.")
            return
        }
        #if ACOUPLET_PUBLIC_APIS_ONLY
        let identifier = controlPeripheralID ?? transitionPeripheralID
        #else
        let identifier = controlPeripheralID ?? device.flatMap(SonyBLEIdentity.classicPeripheralIdentifier) ?? transitionPeripheralID
        #endif
        openBluetoothLE(target: .verified(hash: hash, peripheralIdentifier: identifier), model: deviceModel)
    }

    private func verifiedIdentity(for device: any SonyBluetoothDevice) -> SonyBLEIdentity.VerifiedDevice? {
        guard let savedIdentity else { return nil }
        #if ACOUPLET_PUBLIC_APIS_ONLY
        let peripheralIdentifier: UUID? = nil
        #else
        let peripheralIdentifier = SonyBLEIdentity.classicPeripheralIdentifier(for: device)
        #endif
        let advertisedModel = SonyDeviceModel(name: device.name ?? "")
        guard savedIdentity.matches(classicAddress: device.addressString ?? "", model: advertisedModel == .unknown ? savedIdentity.model : advertisedModel,
                                    peripheralIdentifier: peripheralIdentifier,
                                    isPaired: device.isPaired()) else { return nil }
        return savedIdentity
    }

    func acceptsDeviceAddress(_ address: String) -> Bool {
        guard let normalized = SonyBLEIdentity.normalizedAddress(address) else { return false }
        return pinnedAddress == nil || pinnedAddress == normalized
    }

    private func openPairedBluetoothLE(for device: any SonyBluetoothDevice, automatically: Bool = false,
                                      allowPairedBootstrap: Bool = false) -> Bool {
        guard connectionTransition?.generation != .v1 else { return false }
        if let identity = verifiedIdentity(for: device) {
            return openBluetoothLE(target: .verified(hash: identity.hash, peripheralIdentifier: identity.peripheralIdentifier),
                                   model: identity.model, automatically: automatically)
        }
        #if ACOUPLET_PUBLIC_APIS_ONLY
        return false
        #else
        guard allowPairedBootstrap,
              let target = SonyBLEIdentity.ConnectionTarget(pairedAddress: device.addressString ?? "",
            selectedAddress: address, model: deviceModel,
            peripheralIdentifier: SonyBLEIdentity.classicPeripheralIdentifier(for: device), isPaired: device.isPaired()) else { return false }
        return openBluetoothLE(target: target, model: deviceModel, automatically: automatically)
        #endif
    }

    @discardableResult
    private func openBluetoothLE(target: SonyBLEIdentity.ConnectionTarget, model: SonyDeviceModel, automatically: Bool = false) -> Bool {
        guard !isSystemSleeping, powerOffState == nil, !isRunningHeadphoneTest,
              connectionTransition?.generation != .v1,
              !automatically || lastReadyTransportWasBluetoothLE || (isDeviceConnected && retryAttempt < 2) else { return false }
        if automatically, deviceActionTransition?.phase == .failed {
            guard canRecoverDeviceAction else { return false }
            deviceActionRecoveryAttempts += 1
        }
        closeSonyLink()
        linkState = .opening
        lastErrorMessage = nil
        usesBluetoothLE = true
        bluetoothLEError = nil
        bluetoothLEDiagnosticError = nil
        expectedBLEIdentity = target
        let transport = SonyBLETransport(waitForConnection: automatically && reconnectAutomatically && lastReadyTransportWasBluetoothLE
                                         && connectionTransition?.isFinished != false && recoveryUsesBLE == nil
                                         && deviceActionTransition?.phase != .failed
                                         && multipointTransition?.isFinished != false)
        bleTransport = transport
        transport.onReady = { [weak self, weak transport] identifier, name in
            guard let self, let transport, self.bleTransport === transport else { return }
            if let pairedName = self.device?.name, !pairedName.isEmpty {
                self.deviceName = pairedName
            } else if let name = SonyBLETransport.matchingName(peripheralName: name, advertisedName: nil, model: model) {
                self.deviceName = name
            }
            self.controlPeripheralID = identifier
            self.isDeviceConnected = true
            self.beginHandshake()
        }
        transport.onData = { [weak self, weak transport] data in
            guard let self, let transport, self.bleTransport === transport else { return }
            self.receive(data)
        }
        transport.onDisconnect = { [weak self, weak transport] message in
            guard let self, let transport, self.bleTransport === transport else { return }
            self.isDeviceConnected = self.device?.isClassicConnected() ?? false
            let issue = message ?? String(localized: "The headphone controls disconnected.")
            self.bluetoothLEError = issue
            self.bluetoothLEDiagnosticError = transport.diagnosticError ?? issue
            self.fail(issue)
        }
        #if DEBUG
        if isSimulated {
            transport.simulateWaitingForConnection()
            return true
        }
        #endif
        transport.start(model: model, target: target)
        return true
    }

    func setConnectionMode(_ mode: SonyConnectionMode) {
        guard mode != connectionMode else { return }
        if let reason = connectionModeUnavailableReason(mode) {
            connectionModeError = reason
            return
        }
        guard let original = connectionMode, let supported = supportedConnectionModes,
              let generation = protocolInformation?.generation,
              let transition = SonyConnectionTransition(original: original, target: mode, supportedModes: supported,
                                                        session: controlSession, generation: generation) else { return }
        multipointTransition = nil
        multipointConnection = nil
        connectionModeTimeout?.cancel()
        connectionModeTimeout = nil
        connectionModeError = nil
        connectionRequestID = UUID()
        lastConnectionModeChangeID = connectionRequestID
        invalidateSoundPressureReading()
        connectionTransition = transition
        transitionDevice = device
        transitionAddress = address
        transitionHash = bluetoothLEHash
        transitionPeripheralID = controlPeripheralID
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        transitionPeripheralID = transitionPeripheralID ?? device.flatMap(SonyBLEIdentity.classicPeripheralIdentifier)
        #endif
        transitionModel = deviceModel
        transitionControlAddresses = controlAddresses
        transitionControlAddresses.insert(Self.normalizedAddress(address))
        recoveryUsesBLE = nil
        recoveryClassicAddress = address
        retryAttempt = 0
        send(transition.requestPayload)
    }

    func retryConnectionModeChange(expectedRequestID: UUID) -> Bool {
        guard !isSystemSleeping, powerOffState == nil, !isRunningHeadphoneTest,
              connectionRequestID == expectedRequestID, lastConnectionModeChangeID == expectedRequestID,
              connectionTransition?.phase == .failed, connectionTransition?.retryRecovery() == true else { return false }
        cancelScheduledRetry(resetAttempts: true)
        connectionModeError = nil
        recoveryUsesBLE = nil
        if isReady {
            updateConnectionModeTimeout()
            verifyConnectionPreferenceIfNeeded()
        } else {
            scheduleRetry()
        }
        return true
    }

    func refreshDevices() {
        guard canRefreshDevices else { return }
        sourceTransition = nil
        deviceActionTransition = nil
        for payload in multipoint.queryPayloads { send(payload, type: 0x0E) }
    }

    func changeDeviceConnection(_ action: SonyPeripheralAction, device: SonyMultipointDevice) {
        guard deviceActionUnavailableReason(action, device: device) == nil,
              let transition = SonyDeviceActionTransition(action: action, targetAddress: device.address, model: multipoint, session: controlSession) else { return }
        clearFinishedConnectionChange()
        sourceTransition = nil
        invalidateSoundPressureReading()
        deviceActionRecoveryAttempts = 0
        deviceActionTransition = transition
        advanceDeviceActionTransition()
    }

    private func advanceDeviceActionTransition() {
        if deviceActionTransition?.isFinished == true {
            deviceActionTimeout?.cancel()
            deviceActionTimeout = nil
        } else if let payload = deviceActionTransition?.expectedPayload {
            send(payload, type: 0x0E)
        }
    }

    private func beginDeviceActionConfirmation(_ frame: SonyFrame) {
        guard frame.type == 0x0E,
              deviceActionTransition?.commandTransmitted(frame.payload, model: multipoint, session: controlSession) == true,
              deviceActionTransition?.phase == .awaitingResult, let request = deviceActionTransition?.requestID else { return }
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.deviceActionTransition?.requestID == request else { return }
                self.finishDeviceActionTimeout()
            }
        }
        deviceActionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func finishDeviceActionTimeout() {
        guard deviceActionTransition?.timeout() == true else { return }
        deviceActionTimeout?.cancel()
        deviceActionTimeout = nil
        send([0x36, 0x02], type: 0x0E)
    }

    private var canRecoverDeviceAction: Bool {
        deviceActionTransition?.phase != .failed || isReady
            || (deviceActionTransition?.action == .connect && deviceActionRecoveryAttempts < 2)
    }

    func setMultipointEnabled(_ enabled: Bool) {
        guard multipointUnavailableReason == nil,
              let transition = SonyMultipointTransition(enabled: enabled, model: systemFeatures, session: controlSession) else { return }
        clearFinishedConnectionChange()
        multipointConnection = MultipointConnection(device: device, address: address, model: deviceModel,
            hash: bluetoothLEHash, peripheralID: controlPeripheralID, usesBLE: usesBluetoothLE,
            controlAddresses: controlAddresses.union([Self.normalizedAddress(address)]))
        multipointRecoveryAttempts = 0
        invalidateSoundPressureReading()
        multipointTransition = transition
        advanceMultipointTransition()
    }

    func respondToMultipointAlert(_ alert: SonyConnectionAlert, action: SonyConnectionAlertAction?, confirmsSoundQualityWarning: Bool = false) {
        guard isReady, multipointTransition?.session == controlSession else { return }
        if let action {
            guard multipointTransition?.respond(to: alert, action: action, confirmsSoundQualityWarning: confirmsSoundQualityWarning) != nil else { return }
        } else {
            guard multipointTransition?.acknowledge(alert) == true else { return }
        }
        advanceMultipointTransition()
    }

    var canCheckMultipointChange: Bool {
        powerOffState == nil && !isRunningHeadphoneTest && multipointTransition?.canRetryRecovery == true && multipointConnection != nil && commandQueue.pending == nil
            && deviceActionTransition?.isFinished != false
            && pendingChanges.isEmpty && (equalizerRead == nil || equalizerRead?.timedOut == true)
            && pendingInboundAcknowledgments == 0 && (inventoryRead == nil || inventoryRead?.timedOut == true)
    }

    func checkMultipointChange() {
        guard canCheckMultipointChange, multipointTransition?.retryRecovery() == true else { return }
        multipointRecoveryAttempts = 0
        updateMultipointTimeout()
        if isReady {
            guard matchesMultipointConnection else {
                finishMultipointRecovery(String(localized: "The connected headphones do not match the pending change."))
                return
            }
            if multipointReadbacks.isEmpty, playbackReads.isEmpty, queuedPlaybackQueries.isEmpty, soundPressureRead == nil {
                beginHandshake(reusingConnection: true)
            } else {
                closeSonyLink()
                linkState = .disconnected
                scheduleMultipointRecovery()
            }
        } else {
            scheduleMultipointRecovery()
        }
    }

    private var matchesMultipointConnection: Bool {
        guard let connection = multipointConnection, deviceModel == connection.model,
              usesBluetoothLE == connection.usesBLE,
              Self.normalizedAddress(address) == Self.normalizedAddress(connection.address) else { return false }
        if let hash = connection.hash, bluetoothLEHash != hash { return false }
        return !connection.usesBLE || controlPeripheralID == connection.peripheralID
    }

    private func advanceMultipointTransition() {
        updateMultipointTimeout()
        if let payload = multipointTransition?.expectedPayload { send(payload) }
    }

    private func updateMultipointTimeout() {
        guard let transition = multipointTransition else { return }
        if !isSystemSleeping, transition.phase == .recovering, multipointTimeoutID != nil, multipointTimeoutPhase == .recovering { return }
        multipointTimeout?.cancel()
        multipointTimeout = nil
        multipointTimeoutID = nil
        multipointTimeoutPhase = nil
        if transition.phase == .failed, !transition.canRetryRecovery { multipointConnection = nil }
        guard !isSystemSleeping, transition.phase == .awaitingResponse || transition.phase == .verifying || transition.phase == .recovering else { return }
        let identifier = UUID()
        multipointTimeoutID = identifier
        multipointTimeoutPhase = transition.phase
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.multipointTimeoutID == identifier,
                      self.multipointTransition?.requestID == transition.requestID,
                      self.multipointTransition?.phase == transition.phase else { return }
                self.multipointTimeout = nil
                self.multipointTimeoutID = nil
                self.multipointTimeoutPhase = nil
                if transition.phase == .recovering {
                    self.finishMultipointRecovery(String(localized: "Controls could not reconnect to check the multipoint setting."))
                } else {
                    if self.multipointTransition?.timeout() == true { self.advanceMultipointTransition() }
                }
            }
        }
        multipointTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (transition.phase == .recovering ? 30 : 10), execute: timeout)
    }

    private func beginMultipointConfirmation(_ frame: SonyFrame) {
        guard frame.type == 0x0C, systemReads[frame.payload] == nil else { return }
        if frame.payload.first == 0x98, multipointTransition?.expectedPayload == frame.payload {
            Self.logger.notice("Multipoint alert reply TX; session=\(self.controlSession) format=\(frame.payload[1]) message=\(frame.payload[2]) action=\(frame.payload[3])")
        }
        let advanced = multipointTransition?.commandTransmitted(frame.payload, model: systemFeatures, session: controlSession) == true
        if multipointTransition?.isFinished == false, frame.payload.count >= 2,
           [0xD8, 0xD6].contains(frame.payload[0]), frame.payload[1] == systemFeatures.multipointSlot {
            let setting = frame.payload[0] == 0xD8
            let enabled = setting ? frame.payload.last == 0 : multipointTransition?.targetEnabled == true
            Self.logger.notice("Multipoint TX; session=\(self.controlSession) setter=\(setting) slot=\(frame.payload[1]) target_enabled=\(enabled) phase=\(self.multipointTransition?.diagnosticPhase ?? "none", privacy: .public)")
        }
        if frame.payload.count == 2, frame.payload[0] == 0xD6,
           frame.payload[1] == systemFeatures.multipointSlot {
            multipointQueuedReadSlot = nil
            let owner = advanced && multipointTransition?.phase == .verifying ? multipointTransition?.requestID : nil
            multipointReadbacks.append((frame.payload[1], owner))
        }
        if advanced { advanceMultipointTransition() }
        #if DEBUG
        if isSimulated, simulatesSettingReplies, let slot = systemFeatures.multipointSlot {
            let reply: [UInt8]
            if frame.payload == multipointTransition?.requestPayload {
                reply = [0x99, 0x00, 0x07, 0x01]
            } else if frame.payload == [0x98, 0x00, 0x07, 0x01], let target = multipointTransition?.targetEnabled {
                if target {
                    reply = [0x99, 0x00, 0x70, 0x01]
                } else {
                    simulatedMultipointEnabled = false
                    reply = [0xD9, slot, 0, 1]
                }
            } else if frame.payload == [0x98, 0x00, 0x70, 0x01], multipointTransition?.targetEnabled == true {
                simulatedMultipointEnabled = true
                reply = [0xD9, slot, 0, 0]
            } else if frame.payload == [0xD6, slot] {
                reply = [0xD7, slot, 0, simulatedMultipointEnabled ? 0 : 1]
            } else { return }
            let session = controlSession
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.controlSession == session else { return }
                self.dispatch(reply, type: 0x0C)
            }
        }
        #endif
    }

    private func receiveMultipointSetting(_ payload: [UInt8]) {
        if multipointTransition?.isFinished == false, payload.count >= 2,
           [0xD7, 0xD9].contains(payload[0]), payload[1] == systemFeatures.multipointSlot {
            let read = multipointReadbacks.first { $0.slot == payload[1] }
            let owned = payload[0] == 0xD7 && read?.request != nil && read?.request == multipointTransition?.requestID
            let enabled = systemFeatures.multipoint?.enabled.map { $0 ? 1 : 0 } ?? -1
            Self.logger.notice("Multipoint RX; session=\(self.controlSession) notification=\(payload[0] == 0xD9) slot=\(payload[1]) enabled=\(enabled) owned=\(owned) phase=\(self.multipointTransition?.diagnosticPhase ?? "none", privacy: .public)")
        }
        if payload.first == 0xD1, isReady, multipointTransition?.phase == .recovering,
           systemFeatures.multipointSlot != nil {
            guard matchesMultipointConnection else {
                finishMultipointRecovery(String(localized: "The connected headphones do not match the pending change."))
                return
            }
            if multipointTransition?.controlReady(model: systemFeatures, session: controlSession) == true {
                advanceMultipointTransition()
            }
        }
        if payload.count >= 2, payload[0] == 0xD7,
           let index = multipointReadbacks.firstIndex(where: { $0.slot == payload[1] }) {
            let read = multipointReadbacks.remove(at: index)
            if multipointTransition?.receiveReadback(payload, model: systemFeatures, session: controlSession,
                readbackOwned: read.request != nil && read.request == multipointTransition?.requestID) == true {
                updateMultipointTimeout()
            }
        }
        if payload.count == 4, payload[0] == 0xD9, payload[1] == multipointTransition?.slot,
           systemFeatures.multipoint?.enabled == multipointTransition?.targetEnabled,
           multipointTransition?.requestReadback(model: systemFeatures, session: controlSession) == true {
            advanceMultipointTransition()
        }
    }

    private func scheduleMultipointRecovery() {
        guard !isSystemSleeping, powerOffState == nil, !isRunningHeadphoneTest else { return }
        guard multipointTransition?.phase == .recovering, let connection = multipointConnection else { return }
        updateMultipointTimeout()
        guard !isSimulated else { return }
        retryWorkItem?.cancel()
        guard multipointRecoveryAttempts < 2 else {
            finishMultipointRecovery(String(localized: "Reconnect the selected headphones to check the multipoint setting."))
            return
        }
        let delay = ReconnectBackoff.delay(forAttempt: multipointRecoveryAttempts)
        multipointRecoveryAttempts += 1
        let request = multipointTransition?.requestID
        let session = controlSession
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isSystemSleeping, self.controlSession == session,
                      self.multipointTransition?.requestID == request,
                      self.multipointTransition?.phase == .recovering else { return }
                self.retryWorkItem = nil
                self.nextRetryDate = nil
                self.retrySecondsRemaining = nil
                if connection.usesBLE, let hash = connection.hash {
                    self.openBluetoothLE(target: .verified(hash: hash, peripheralIdentifier: connection.peripheralID), model: connection.model)
                } else if let target = connection.device, target.isPaired(),
                          Self.normalizedAddress(target.addressString ?? "") == Self.normalizedAddress(connection.address) {
                    self.device = target
                    self.address = connection.address
                    self.deviceName = target.name ?? self.deviceName
                    self.isDeviceConnected = target.isClassicConnected()
                    self.openClassicConnection(target, recovering: true)
                } else {
                    self.finishMultipointRecovery(String(localized: "Reconnect the selected headphones in Bluetooth settings to check this change."))
                }
            }
        }
        retryWorkItem = item
        nextRetryDate = Date().addingTimeInterval(delay)
        retrySecondsRemaining = Int(delay.rounded(.up))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func finishMultipointRecovery(_ message: String) {
        multipointTransition?.controlLost(session: controlSession)
        multipointTransition?.recoveryFailed()
        cancelScheduledRetry(resetAttempts: false)
        updateMultipointTimeout()
        if !isReady { closeSonyLink() }
        lastErrorMessage = message
        if !isReady { linkState = .failed(message) }
    }

    func selectAudioSource(_ device: SonyMultipointDevice) {
        guard sourceControlUnavailableReason == nil,
              let transition = SonySourceTransition(targetAddress: device.address, model: multipoint, session: controlSession) else { return }
        clearFinishedConnectionChange()
        invalidateSoundPressureReading()
        sourceTransition = transition
        advanceSourceTransition()
    }

    func setSourceKeeping(_ enabled: Bool) {
        guard sourceControlUnavailableReason == nil,
              let transition = SonySourceTransition(keeping: enabled, model: multipoint, session: controlSession) else { return }
        clearFinishedConnectionChange()
        invalidateSoundPressureReading()
        sourceTransition = transition
        advanceSourceTransition()
    }

    private func clearFinishedConnectionChange() {
        connectionModeTimeout?.cancel()
        connectionModeTimeout = nil
        connectionTransition = nil
        connectionRequestID = nil
        connectionModeError = nil
        transitionDevice = nil
        transitionAddress = nil
        transitionHash = nil
        transitionPeripheralID = nil
        transitionControlAddresses = []
        recoveryUsesBLE = nil
        recoveryClassicAddress = nil
    }

    private func advanceSourceTransition() {
        sourceTimeout?.cancel()
        sourceTimeout = nil
        if let payload = sourceTransition?.expectedPayload { send(payload, type: 0x0E) }
    }

    private func beginSourceConfirmation(_ frame: SonyFrame) {
        guard frame.type == 0x0E else { return }
        if frame.payload == [0x36, 0x02], let read = inventoryRead {
            inventoryRead?.transmitted = true
            let session = controlSession
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.controlSession == session, self.inventoryRead?.id == read.id else { return }
                    self.inventoryRead?.timedOut = true
                    self.inventoryReadTimeout = nil
                }
            }
            inventoryReadTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
        if sourceTransition?.commandTransmitted(frame.payload, model: multipoint, session: controlSession) == true,
           sourceTransition?.isFinished == false, let request = sourceTransition?.requestID {
            let session = controlSession
            let phase = sourceTransition?.phase
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.controlSession == session, self.sourceTransition?.requestID == request,
                          self.sourceTransition?.phase == phase else { return }
                    self.sourceTimeout = nil
                    self.sourceTransition?.timeout()
                }
            }
            sourceTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        }
        #if DEBUG
        if isSimulated, simulatesSettingReplies {
            if CommandLine.arguments.contains("--hold-source-replies") { return }
            let reply: [UInt8]
            switch frame.payload.prefix(2) {
            case [0x30, 0x02]: reply = [0x31, 0x02, 8, multipoint.maxConnectedDevices ?? 2, 0]
            case [0x32, 0x02]: reply = [0x33, 0x02, 0, 0]
            case [0x36, 0x01]: reply = [0x37, 0x01, multipoint.keeping == true ? 0 : 1]
            case [0x36, 0x02]: reply = simulatedMultipointInventory(selected: simulatedSourceID)
            case [0x38, 0x01]: reply = [0x39, 0x01, frame.payload[2], 0]
            case [0x3C, 0x01]:
                let address = String(decoding: frame.payload.dropFirst(2), as: UTF8.self)
                simulatedSourceID = multipoint.devices.first(where: { $0.address == address })?.connectionID ?? 0
                reply = [0x3D, 0x01, 0] + frame.payload.dropFirst(2)
            case [0x3C, 0x02]:
                guard CommandLine.arguments.contains("-ui-testing"), frame.payload.count == 20,
                      let action = SonyPeripheralAction(rawValue: frame.payload[2]), action != .unpair else { return }
                let address = String(decoding: frame.payload.dropFirst(3), as: UTF8.self)
                if action == .connect {
                    simulatedDeviceConnections[address] = (1...(multipoint.maxConnectedDevices ?? 2)).first { id in !multipoint.devices.contains(where: { $0.connectionID == id }) }
                } else {
                    if multipoint.selectedSource?.address == address { simulatedSourceID = 0 }
                    simulatedDeviceConnections[address] = 0
                }
                reply = [0x3D, 0x02, action.rawValue, action.rawValue * 16] + frame.payload.dropFirst(3)
            default: return
            }
            let session = controlSession
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.controlSession == session else { return }
                self.dispatch(reply, type: 0x0E)
            }
        }
        #endif
    }

    private func receiveMultipoint(_ payload: [UInt8]) {
        var ownedReadback = false
        var ownedDeviceReadback = false
        if payload.prefix(2) == [0x37, 0x02], let read = inventoryRead, read.transmitted {
            ownedReadback = read.requestID != nil && read.requestID == sourceTransition?.requestID
            ownedDeviceReadback = read.requestID != nil && read.requestID == deviceActionTransition?.requestID
            inventoryRead = nil
            inventoryReadTimeout?.cancel()
            inventoryReadTimeout = nil
        }
        if sourceTransition?.receive(payload, model: multipoint, session: controlSession, readbackOwned: ownedReadback) == true {
            advanceSourceTransition()
        }
        if deviceActionTransition?.receive(payload, model: multipoint, session: controlSession, readbackOwned: ownedDeviceReadback) == true {
            advanceDeviceActionTransition()
        }
    }

    func respondToConnectionAlert(_ alert: SonyConnectionAlert, action: SonyConnectionAlertAction?) {
        guard stage != .idle, var transition = connectionTransition, transition.session == controlSession else { return }
        if let action {
            guard let payload = transition.respond(to: alert, action: action) else { return }
            connectionTransition = transition
            updateConnectionModeTimeout()
            send(payload)
        } else {
            guard transition.acknowledge(alert) else { return }
            connectionTransition = transition
            updateConnectionModeTimeout()
            if isReady { send(transition.readbackPayload) }
        }
    }

    private func verifyConnectionPreferenceIfNeeded() {
        guard isReady, connectionTransition?.phase == .reconnecting || connectionTransition?.phase == .recovering else { return }
        let session = controlSession
        Task { @MainActor [weak self] in
            guard let self, self.controlSession == session, self.isReady,
                  self.connectionTransition?.phase == .reconnecting || self.connectionTransition?.phase == .recovering,
                  self.commandQueue.pending == nil, self.modeReadbacks.isEmpty,
                  self.systemReads.values.allSatisfy({ $0.transmitted && $0.timedOut }),
                  self.powerReads.values.allSatisfy({ $0.transmitted && $0.timedOut }),
                  self.voiceGuidanceReads.values.allSatisfy({ $0.transmitted && $0.isObsolete && $0.timeout == nil }),
                  self.legacyReads.isSubset(of: self.timedOutLegacyReads),
                  self.batteryReads.values.allSatisfy({ $0.transmitted && $0.timedOut }),
                  self.noiseControlRead == nil || self.noiseControlRead?.timedOut == true,
                  self.noiseReadTimeouts.isEmpty, self.equalizerRead == nil || self.equalizerRead?.timedOut == true,
                  self.discoveryReads.values.allSatisfy({ $0.timeout == nil }),
                  self.playbackReads.values.allSatisfy({ $0.timedOut }), self.queuedPlaybackQueries.isEmpty,
                  self.soundPressureRead == nil || self.soundPressureRead?.timedOut == true,
                  self.pendingInboundAcknowledgments == 0 else { return }
            self.beginHandshake(reusingConnection: true)
        }
    }

    private func updateConnectionModeTimeout() {
        if stage != .idle, stage != .ready, connectionTransition?.session == controlSession {
            if connectionTransition?.awaitingUser == true {
                handshakeTimeoutWorkItem?.cancel()
                handshakeTimeoutWorkItem = nil
                handshakeID = nil
            } else if handshakeTimeoutWorkItem == nil {
                scheduleHandshakeTimeout()
            }
        }
        guard isReady, let transition = connectionTransition,
              transition.phase == .awaitingResponse || transition.phase == .verifying
                || transition.phase == .reconnecting || transition.phase == .recovering else {
            connectionModeTimeout?.cancel()
            connectionModeTimeout = nil
            return
        }
        guard connectionModeTimeout == nil, let request = connectionRequestID else { return }
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.connectionRequestID == request else { return }
                self.connectionModeTimeout = nil
                self.finishConnectionModeTimeout()
            }
        }
        connectionModeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func finishConnectionModeTimeout() {
        let wasRecovering = connectionTransition?.phase == .recovering
        if connectionTransition?.timeout() == true || connectionTransition?.recoveryFailed() == true {
            if wasRecovering, classicConnectionID != nil {
                classicConnectionID = nil
                linkState = .disconnected
            }
            if wasRecovering, isReady {
                closeSonyLink()
                linkState = .disconnected
            }
            connectionModeError = String(localized: "Headphones did not confirm the connection change.")
        }
    }

    private func beginConnectionConfirmation(_ frame: SonyFrame) {
        guard frame.type == 0x0C else { return }
        if protocolInformation?.generation == .v2, frame.payload == [0xE6, 0x05] {
            let expected = isReady && connectionTransition?.readbackTransmitted(session: controlSession) == true
            modeReadbacks.append(expected ? connectionRequestID : nil)
            #if DEBUG
            if isSimulated, simulatesSettingReplies, let value = simulatedMode.sonyValue {
                dispatch([0xE7, 0x05, value], type: 0x0C)
            }
            #endif
            return
        }
        guard connectionTransition?.commandTransmitted(frame.payload, session: controlSession) == true else { return }
        modeReadbacks = Array(repeating: nil, count: modeReadbacks.count)
        if connectionTransition?.generation == .v1, systemReads[[0xE6, 0x01]]?.transmitted == true {
            systemReads[[0xE6, 0x01]]?.isObsolete = true
            if systemReads[[0xE6, 0x01]]?.timeout == nil { scheduleSystemReadTimeout([0xE6, 0x01]) }
        }
        updateConnectionModeTimeout()
        #if DEBUG
        if isSimulated, simulatesSettingReplies, let transition = connectionTransition {
            if frame.payload == transition.requestPayload {
                let payload: [UInt8]
                if transition.generation == .v1 {
                    payload = CommandLine.arguments.contains("--legacy-quality-caution") && protocolVersion.map({ $0 >= 0x4000 }) == true
                        ? [0x99, 0x01, 0x01, 0x01] : []
                    if payload.isEmpty { simulatedMode = transition.targetMode }
                } else {
                    payload = switch transition.targetMode {
                    case .soundQuality: [0x99, 0x00, 0x76, 0x01]
                    case .stableConnection: [0x99, 0x00, 0x77, 0x01]
                    case .lowLatency: [0x99, 0x06, 0x11, 0x00, 0x01]
                    case .unknown: []
                    }
                }
                if !payload.isEmpty {
                    if CommandLine.arguments.contains("-ui-testing"), CommandLine.arguments.contains("--delayed-connection-alert") {
                        let session = controlSession
                        let request = connectionRequestID
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self, self.controlSession == session, self.connectionRequestID == request else { return }
                            self.dispatch(payload, type: 0x0C)
                        }
                    } else {
                        dispatch(payload, type: 0x0C)
                    }
                }
            } else if frame.payload.last == SonyConnectionAlertAction.positive.rawValue {
                simulatedMode = transition.targetMode
            }
        }
        #endif
        if isReady, let transition = connectionTransition, !transition.awaitingUser,
           transition.generation == .v1 || frame.payload != transition.requestPayload {
            send(transition.readbackPayload)
        }
    }

    func setNoiseControl(_ mode: NoiseControlMode) {
        sendNoiseControl(mode)
    }

    @available(macOS 27.0, *)
    var noiseControlActions: [HeadphoneNoiseControlAction] {
        guard canChangeNoiseControl, !address.isEmpty, deviceModel != .unknown else { return [] }
        let model = deviceModel
        return availableNoiseModes.map { mode in
            HeadphoneNoiseControlAction(id: noiseControlActionID(mode), title: mode.title,
                modelName: model.name, symbolName: model.symbol, systemSymbol: model.systemSymbol)
        }
    }

    private func noiseControlActionID(_ mode: NoiseControlMode) -> String {
        "\(Self.normalizedAddress(address)):\(deviceModel.rawValue):\(mode.rawValue)"
    }

    func performNoiseControlAction(_ identifier: String) async throws {
        try Task.checkCancellation()
        if let issue = noiseControlUnavailableReason { throw HeadphoneControlError(message: issue) }
        guard deviceModel != .unknown, !address.isEmpty,
              let mode = availableNoiseModes.first(where: { noiseControlActionID($0) == identifier }) else {
            throw HeadphoneControlError(message: String(localized: "This noise-control action is no longer available for the selected headphones."))
        }
        guard pendingChanges.isEmpty, pendingPlaybackCommand == nil, !isEqualizerUpdatePending,
              !isApplyingChange, ambientWorkItem == nil,
              requestedNoiseControlPayload == nil else {
            throw HeadphoneControlError(message: String(localized: "Wait for the current headphone command to finish."))
        }
        if noiseControlMode == mode { return }
        sendNoiseControl(mode)
        guard let requestID = settingRequests[.noiseControl] else {
            throw HeadphoneControlError(message: settingErrors[.noiseControl] ?? String(localized: "The noise-control command could not be sent."))
        }
        try await waitForSettingConfirmation(.noiseControl, requestID: requestID)
    }

    func canPerformConfirmedSettingChange(_ setting: Setting) -> Bool {
        systemControlContextIsAvailable && pendingChanges.isEmpty && unconfirmedChanges[setting] == nil
            && pendingPlaybackCommand == nil && !isEqualizerUpdatePending && !isApplyingChange
            && ambientWorkItem == nil && requestedNoiseControlPayload == nil && settingIntent == nil
    }

    func performConfirmedSettingChange(_ setting: Setting, change: () -> Void) async throws {
        try Task.checkCancellation()
        guard canPerformConfirmedSettingChange(setting) else {
            throw HeadphoneControlError(message: String(localized: "Wait for the current headphone change to finish."))
        }
        change()
        guard let requestID = settingRequests[setting], pendingChanges[setting] != nil else {
            throw HeadphoneControlError(message: settingErrors[setting] ?? String(localized: "The setting is no longer available."))
        }
        try await waitForSettingConfirmation(setting, requestID: requestID)
    }

    func performConfirmedEqualizerChange(_ settings: EqualizerSettings) async throws {
        guard let payload = equalizer.settingsPayload(settings) else {
            throw HeadphoneControlError(message: String(localized: "The equalizer layout changed. Reopen the equalizer and try again."))
        }
        try await performConfirmedSettingChange(.equalizer) {
            queueEqualizer(payload, debounce: false)
        }
    }

    private func waitForSettingConfirmation(_ setting: Setting, requestID: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                settingIntent = (setting, requestID, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if setting == .playbackVolume, self?.settingRequests[setting] == requestID,
                   self?.settingTimeouts[setting] == nil {
                    self?.queuedMusicVolumeIsCurrent = { false }
                }
                self?.finishSettingIntent(setting, requestID: requestID, error: CancellationError())
            }
        }
    }

    private func finishSettingIntent(_ setting: Setting?, requestID: UUID?, error: Error? = nil) {
        guard let waiter = settingIntent, waiter.setting == setting, waiter.requestID == requestID else { return }
        settingIntent = nil
        if let error { waiter.continuation.resume(throwing: error) }
        else { waiter.continuation.resume() }
    }

    @available(macOS 27.0, *)
    var speakToChatActions: [HeadphoneSpeakToChatAction] {
        guard canSetSystemFeature(.speakToChat), !address.isEmpty, deviceModel != .unknown else { return [] }
        return [true, false].map { enabled in
            HeadphoneSpeakToChatAction(id: speakToChatActionID(enabled), enabled: enabled, modelName: deviceModel.name)
        }
    }

    private func speakToChatActionID(_ enabled: Bool) -> String {
        "\(Self.normalizedAddress(address)):\(deviceModel.rawValue):speak-to-chat-\(enabled ? "on" : "off")"
    }

    func performSpeakToChatAction(_ identifier: String) async throws {
        try Task.checkCancellation()
        guard canSetSystemFeature(.speakToChat), deviceModel != .unknown, !address.isEmpty,
              let enabled = [true, false].first(where: { speakToChatActionID($0) == identifier }) else {
            throw HeadphoneControlError(message: String(localized: "This Speak-to-Chat action is no longer available for the selected headphones."))
        }
        guard pendingChanges.isEmpty, pendingPlaybackCommand == nil, !isEqualizerUpdatePending,
              !isApplyingChange, ambientWorkItem == nil,
              requestedNoiseControlPayload == nil else {
            throw HeadphoneControlError(message: String(localized: "Wait for the current headphone command to finish."))
        }
        if systemFeatureState(.speakToChat)?.enabled == enabled { return }
        setSystemFeature(.speakToChat, enabled: enabled)
        let setting = Setting.system(.speakToChat)
        guard let requestID = settingRequests[setting] else {
            throw HeadphoneControlError(message: settingErrors[setting] ?? String(localized: "The Speak-to-Chat command could not be sent."))
        }
        try await waitForSettingConfirmation(setting, requestID: requestID)
    }

    func toggleNoiseControl() {
        guard isReady else { return }
        let first: NoiseControlMode = availableNoiseModes.contains(.anc) ? .anc : .off
        let second: NoiseControlMode = availableNoiseModes.contains(.ambient) ? .ambient : .off
        guard first != second, availableNoiseModes.contains(first), availableNoiseModes.contains(second) else { return }
        let requested = requestedNoiseControlPayload ?? pendingChanges[.noiseControl].map { [0x68] + $0 }
        let mode = requested.flatMap(decodedNoiseControlMode) ?? noiseControlMode
        sendNoiseControl(mode == first ? second : first)
    }

    func setEqualizerPreset(_ preset: EqualizerPreset) {
        setEqualizerPreset(preset.rawValue)
    }

    func setEqualizerPreset(_ preset: UInt8) {
        guard let payload = equalizer.presetPayload(preset) else { return }
        queueEqualizer(payload, debounce: false)
    }

    func setDSEE(_ mode: SonyDSEEMode) {
        guard canSetDSEE, mode != dseeMode else { return }
        let payload = legacyControls == nil ? audioFeatures.dseeSetPayload(mode) : legacyControls?.dsee.setPayload(mode)
        guard let payload else { return }
        sendSetting(payload, setting: .dsee)
    }

    func setLegacySoundEffect(_ kind: SonyLegacySoundEffect.Kind, preset: UInt8) {
        let effect = legacySoundEffect(kind)
        guard canSetLegacySoundEffect(kind), effect.presetID != preset,
              let payload = effect.setPayload(preset) else { return }
        sendSetting(payload, setting: .legacySoundEffect(kind))
    }

    func systemFeatureState(_ feature: SonySystemFeature) -> SonySystemFeatureState? {
        if protocolInformation?.generation == .v1 {
            return feature == .pauseOnRemoval ? legacyControls?.wearingControl.state : nil
        }
        return systemFeatures[feature]
    }

    private func systemFeature(inquiry: UInt8) -> SonySystemFeature? {
        if protocolInformation?.generation == .v1 {
            return inquiry == 0x03 && legacyControls?.wearingControl.isSupported == true ? .pauseOnRemoval : nil
        }
        guard let feature = SonySystemFeature(rawValue: inquiry), systemFeatures[feature] != nil else { return nil }
        return feature
    }

    private func systemFeaturePayload(_ feature: SonySystemFeature, enabled: Bool) -> [UInt8]? {
        if protocolInformation?.generation == .v1 {
            return feature == .pauseOnRemoval ? legacyControls?.wearingControl.setPayload(enabled: enabled) : nil
        }
        return systemFeatures.setPayload(feature, enabled: enabled)
    }

    private func systemFeatureIsAvailable(_ feature: SonySystemFeature) -> Bool {
        systemControlContextIsAvailable && systemFeatureState(feature)?.available == true
            && systemFeatureState(feature)?.isVisible == true && systemFeatureState(feature)?.enabled != nil
            && (protocolInformation?.generation != .v1 || legacyControls?.wearingControl.canSet == true)
            && (feature != .voiceAssistantWakeWord || audioFeatures.codec != .lc3)
    }

    func canSetSystemFeature(_ feature: SonySystemFeature) -> Bool {
        systemFeatureIsAvailable(feature) && pendingChanges[.system(feature)] == nil
            && unconfirmedChanges[.system(feature)] == nil
            && (feature != .speakToChat || (pendingChanges[.speakToChatOptions] == nil && unconfirmedChanges[.speakToChatOptions] == nil))
    }

    var canSetSpeakToChatOptions: Bool {
        guard canSetSystemFeature(.speakToChat), let options = systemFeatures.speakToChatOptions,
              let sensitivity = options.sensitivity, let delay = options.delay else { return false }
        return options.setPayload(sensitivity: sensitivity, delay: delay) != nil
    }

    private var voiceAssistantIsAvailable: Bool {
        guard protocolInformation?.generation == .v2, systemControlContextIsAvailable, audioFeatures.codec != .lc3,
              let state = systemFeatures.voiceAssistant else { return false }
        return state.knownOptions.contains { state.setPayload($0) != nil }
    }

    var canSetVoiceAssistant: Bool {
        voiceAssistantIsAvailable && pendingChanges[.voiceAssistant] == nil && unconfirmedChanges[.voiceAssistant] == nil
    }

    func setVoiceAssistant(_ option: SonyVoiceAssistantOption) {
        guard canSetVoiceAssistant, let state = systemFeatures.voiceAssistant, state.current != option,
              let payload = state.setPayload(option) else { return }
        sendSetting(payload, setting: .voiceAssistant)
    }

    func setSystemFeature(_ feature: SonySystemFeature, enabled: Bool) {
        guard canSetSystemFeature(feature),
              let payload = systemFeaturePayload(feature, enabled: enabled),
              systemFeatureState(feature)?.enabled != enabled else { return }
        sendSetting(payload, setting: .system(feature))
    }

    func setSpeakToChatOptions(sensitivity: SonySpeechSensitivity, delay: SonySpeakToChatDelay) {
        guard canSetSpeakToChatOptions,
              let options = systemFeatures.speakToChatOptions,
              options.sensitivity != sensitivity || options.delay != delay,
              let payload = options.setPayload(sensitivity: sensitivity, delay: delay) else { return }
        queuedSpeakToChatOptions = options
        sendSetting(payload, setting: .speakToChatOptions)
    }

    var automaticPowerOff: SonyAutomaticPowerOffState? {
        protocolInformation?.generation == .v1 ? legacyControls?.automaticPowerOff : systemFeatures.automaticPowerOff
    }

    private var automaticPowerOffIsAvailable: Bool {
        guard systemControlContextIsAvailable, let state = automaticPowerOff, let options = state.options else { return false }
        return options.contains { state.setPayload($0) != nil }
    }

    var canSetAutomaticPowerOff: Bool {
        automaticPowerOffIsAvailable && pendingChanges[.automaticPowerOff] == nil
            && unconfirmedChanges[.automaticPowerOff] == nil
    }

    func setAutomaticPowerOff(_ option: SonyAutomaticPowerOffOption) {
        guard canSetAutomaticPowerOff,
              let state = automaticPowerOff, state.current != option,
              let payload = state.setPayload(option) else { return }
        sendSetting(payload, setting: .automaticPowerOff)
    }

    var canSetBatteryCare: Bool {
        systemControlContextIsAvailable && pendingChanges[.batteryCare] == nil && unconfirmedChanges[.batteryCare] == nil
            && powerFeatures.batteryCare?.setPayload(enabled: true) != nil
    }

    private var powerSaveChangeIsPending: Bool {
        pendingChanges[.autoPowerSave] != nil || pendingChanges[.powerSaveEffect] != nil
            || unconfirmedChanges[.autoPowerSave] != nil || unconfirmedChanges[.powerSaveEffect] != nil
    }

    var canSetAutoPowerSave: Bool {
        systemControlContextIsAvailable && !powerSaveChangeIsPending
            && powerFeatures.autoPowerSave?.setPayload(enabled: true) != nil
    }

    var canCancelPowerSaveEffect: Bool {
        systemControlContextIsAvailable && !powerSaveChangeIsPending
            && powerFeatures.autoPowerSave?.cancelEffectPayload != nil
    }

    func setBatteryCare(_ enabled: Bool) {
        guard canSetBatteryCare,
              let state = powerFeatures.batteryCare, state.enabled != enabled,
              let payload = state.setPayload(enabled: enabled) else { return }
        sendSetting(payload, setting: .batteryCare, type: state.frameType)
    }

    func setAutoPowerSave(_ enabled: Bool) {
        guard canSetAutoPowerSave,
              let state = powerFeatures.autoPowerSave, state.enabled != enabled,
              let payload = state.setPayload(enabled: enabled) else { return }
        sendSetting(payload, setting: .autoPowerSave)
    }

    func cancelPowerSaveEffect() {
        guard canCancelPowerSaveEffect,
              let payload = powerFeatures.autoPowerSave?.cancelEffectPayload else { return }
        sendSetting(payload, setting: .powerSaveEffect)
    }

    private var sidetoneIsAvailable: Bool {
        systemControlContextIsAvailable && systemFeatures.generalSettingsAreIdentified
            && systemFeatures.sidetone?.available == true && systemFeatures.sidetone?.enabled != nil
    }

    var canSetSidetone: Bool {
        sidetoneIsAvailable && pendingChanges[.sidetone] == nil && unconfirmedChanges[.sidetone] == nil
    }

    func setSidetone(_ enabled: Bool) {
        guard canSetSidetone, systemFeatures.sidetone?.enabled != enabled,
              let payload = systemFeatures.sidetoneSetPayload(enabled: enabled) else { return }
        sendSetting(payload, setting: .sidetone)
    }

    private var systemControlContextIsAvailable: Bool {
        isReady && (protocolInformation?.generation == .v2 || protocolInformation?.generation == .v1)
            && powerOffState == nil && !isRunningHeadphoneTest
            && connectionTransition?.isFinished != false && sourceTransition?.isFinished != false
            && deviceActionTransition?.isFinished != false && multipointTransition?.isFinished != false
    }

    private var touchChangeIsPending: Bool {
        pendingChanges[.touchAssignments] != nil || pendingChanges[.touchCustomActions] != nil
            || unconfirmedChanges[.touchAssignments] != nil || unconfirmedChanges[.touchCustomActions] != nil
    }

    func canSetTouchAssignment(key: UInt8) -> Bool {
        systemControlContextIsAvailable && !touchChangeIsPending && touchAssignments.isAvailable(key: key)
    }

    func canSetTouchAction(key: UInt8, action: UInt8) -> Bool {
        guard protocolInformation?.generation == .v2, systemControlContextIsAvailable, !touchChangeIsPending else { return false }
        return touchAssignments.customizableActions(key: key).contains {
            $0.action == action && $0.functions.contains { touchAssignments.setActionPayload(key: key, action: action, function: $0) != nil }
        }
    }

    func setTouchAssignment(key: UInt8, preset: UInt8) {
        guard canSetTouchAssignment(key: key), let selection = touchAssignments.selectedPresets,
              touchAssignments.selectedPreset(key: key) != preset,
              let payload = touchAssignments.setPayload(key: key, preset: preset) else { return }
        queuedTouchChange = (key, selection, [])
        sendSetting(payload, setting: .touchAssignments)
    }

    func setTouchAction(key: UInt8, action: UInt8, function: UInt8) {
        guard canSetTouchAction(key: key, action: action), let selection = touchAssignments.selectedPresets,
              let payload = touchAssignments.setActionPayload(key: key, action: action, function: function),
              touchAssignments.reportedFunction(preset: payload[3], action: action) != function else { return }
        queuedTouchChange = (key, selection, Set(touchAssignments.keysUsingPreset(payload[3]).map(\.key)))
        sendSetting(payload, setting: .touchCustomActions)
    }

    func setVoiceGuidance(_ enabled: Bool) {
        guard systemControlContextIsAvailable, pendingChanges[.voiceGuidance] == nil, unconfirmedChanges[.voiceGuidance] == nil,
              voiceGuidance.enabled != enabled, let payload = voiceGuidance.setEnabledPayload(enabled) else { return }
        sendSetting(payload, setting: .voiceGuidance, type: 0x0E)
    }

    func setVoiceGuidanceVolume(_ volume: Int) {
        guard systemControlContextIsAvailable, pendingChanges[.voiceGuidanceVolume] == nil, unconfirmedChanges[.voiceGuidanceVolume] == nil,
              voiceGuidance.volume != volume, let payload = voiceGuidance.setVolumePayload(volume) else { return }
        sendSetting(payload, setting: .voiceGuidanceVolume, type: 0x0E)
    }

    func refreshSoundPressure(automatically: Bool = false) {
        guard canRefreshSoundPressure, !automatically || (!soundPressureAutomaticRefreshSuspended
            && soundPressureReadError == nil && soundPressure.intervalSeconds != nil) else { return }
        if let interval = soundPressure.intervalSeconds, let lastSoundPressureRequest,
           lastSoundPressureRequest.duration(to: .now) < .seconds(interval) { return }
        if !automatically { soundPressureAutomaticRefreshSuspended = false }
        soundPressureReadError = nil
        soundPressureRead = SoundPressureRead(generation: soundPressureGeneration)
        send(SonySoundPressure.levelQueryPayload, type: 0x0E)
    }

    var supportsEarbudFinding: Bool {
        EarbudFinderController.isSupported(model: deviceInformation.model, firmware: firmwareVersion)
    }

    var hasCurrentTable2Capabilities: Bool {
        guard let protocolInformation else { return false }
        return !protocolInformation.supportsTable2 || table2CapabilitiesSession == controlSession
    }

    var hasFailedTable2Discovery: Bool {
        guard !hasCurrentTable2Capabilities, let read = discoveryReads[[0x0E, 0x06, 0x00]] else { return false }
        return read.retryTransmitted && read.timeout == nil && !read.resolved
    }

    var canRetryDeviceDiscovery: Bool {
        hasFailedTable2Discovery && systemControlContextIsAvailable
            && pendingChanges.isEmpty && pendingPlaybackCommand == nil && !isApplyingChange
            && commandQueue.pending == nil && earbudFinder?.isBusy != true && earbudFinder?.mayBeRinging != true
    }

    func retryDeviceDiscovery() {
        guard canRetryDeviceDiscovery else { return }
        closeSonyLink()
        linkState = .disconnected
        connect()
        refresh()
    }

    var hasPendingWearingStatusRead: Bool { wearingStatusRead != nil }

    func beginEarbudFinder() -> Bool {
        if let earbudFinder {
            if !earbudFinder.needsNewControlSession {
                earbudFinder.prepareForPresentation()
                return true
            }
            if earbudFinder.isBusy || earbudFinder.mayBeRinging { return true }
        }
        guard supportsEarbudFinding else { return false }
        let finder = EarbudFinderController(headphones: self, simulated: isSimulated)
        earbudFinder = finder
        earbudFinderObservation = finder.$session
            .map { $0?.phase }
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        return true
    }

    @discardableResult
    func refreshWearingStatus() -> UUID? {
        guard systemControlContextIsAvailable, isDeviceConnected, wearingStatus.isSupported,
              wearingStatusRead == nil, commandQueue.pending == nil else { return nil }
        invalidateWearingStatus()
        let read = WearingStatusRead(generation: wearingStatusGeneration)
        wearingStatusRead = read
        send(SonyWearingStatus.queryPayload, type: 0x0E)
        return read.id
    }

    private func invalidateWearingStatus() {
        wearingStatusGeneration += 1
        wearingStatusReadID = nil
        wearingStatus.invalidate()
    }

    private func beginWearingStatusRead() {
        guard let read = wearingStatusRead, !read.transmitted else { return }
        wearingStatusRead?.transmitted = true
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.wearingStatusRead?.id == read.id else { return }
                self.wearingStatusRead?.timedOut = true
                self.wearingStatusReadTimeout = nil
                self.invalidateWearingStatus()
            }
        }
        wearingStatusReadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func receiveWearingStatus(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == 0,
              payload[0] == 0xF3 || payload[0] == 0xF5 else { return false }
        guard payload.count == 3 else {
            invalidateWearingStatus()
            return true
        }
        if payload[0] == 0xF5 {
            wearingStatusGeneration += 1
            wearingStatusReadID = nil
            var updated = wearingStatus
            updated.invalidate()
            updated.update(payload)
            wearingStatus = updated
            return true
        }
        guard let read = wearingStatusRead, read.transmitted else { return true }
        wearingStatusReadTimeout?.cancel()
        wearingStatusReadTimeout = nil
        wearingStatusRead = nil
        guard !read.timedOut, read.generation == wearingStatusGeneration,
              systemControlContextIsAvailable, isDeviceConnected else { return true }
        if wearingStatus.update(payload) {
            wearingStatusReadID = read.id
        }
        return true
    }

    func invalidateSoundPressureReading() {
        soundPressureGeneration += 1
        soundPressure.invalidateReading()
    }

    private func beginSoundPressureRead() {
        guard let read = soundPressureRead else { return }
        soundPressureRead?.transmitted = true
        lastSoundPressureRequest = .now
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.soundPressureRead?.id == read.id else { return }
                self.soundPressureRead?.timedOut = true
                self.soundPressureReadTimeout = nil
                self.verifyConnectionPreferenceIfNeeded()
                guard read.generation == self.soundPressureGeneration else { return }
                self.soundPressure.invalidateReading()
                self.soundPressureReadError = String(localized: "The listening level was not received. Reconnect the headphones to try again.")
            }
        }
        soundPressureReadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func receiveSoundPressure(_ payload: [UInt8]) -> Bool {
        var updated = soundPressure
        guard updated.update(payload) else { return false }
        if payload[0] == 0x5B {
            guard let read = soundPressureRead, read.transmitted else { return true }
            soundPressureReadTimeout?.cancel()
            soundPressureReadTimeout = nil
            soundPressureRead = nil
            guard !read.timedOut, read.generation == soundPressureGeneration,
                  soundPressure.available == true, !soundPressure.isStopped,
                  connectionTransition?.isFinished != false, multipointTransition?.isFinished != false,
                  sourceTransition?.isFinished != false, deviceActionTransition?.isFinished != false else { return true }
        } else if updated.available != soundPressure.available
            || updated.measurementEnabled != soundPressure.measurementEnabled
            || updated.previewEnabled != soundPressure.previewEnabled
            || (payload[0] == 0x59 && (payload[2] > 1 || payload[3] > 1)) {
            soundPressureGeneration += 1
        }
        soundPressure = updated
        return true
    }

    func controlPlayback(_ command: SonyPlaybackCommand) {
        guard canControlPlayback, let payload = playback.commandPayload(command) else { return }
        pendingPlaybackCommand = command
        queuedPlaybackSource = multipoint.selectedSource?.address
        send(payload)
    }

    func setPlaybackVolume(_ volume: Int, isCurrent: (() -> Bool)? = nil) {
        guard canControlMusicVolume, playback.volume != volume, let payload = playback.volumePayload(volume) else { return }
        queuedVolumeSource = multipoint.selectedSource?.address
        queuedMusicVolumeIsCurrent = isCurrent
        sendSetting(payload, setting: .playbackVolume)
    }

    func setCallVolume(_ volume: Int) {
        guard canControlCallVolume, playback.callVolume != volume, let payload = playback.callVolumePayload(volume) else { return }
        queuedVolumeSource = multipoint.selectedSource?.address
        sendSetting(payload, setting: .callVolume)
    }

    private func playbackVolumeSetting(_ payload: [UInt8]) -> Setting? {
        guard let query = playback.queryPayload(for: payload) else { return nil }
        if query == playback.musicVolumeQueryPayload { return .playbackVolume }
        return playback.generation == .v2 && query == [0xA6, 0x21] ? .callVolume : nil
    }

    private func settingValue(_ payload: [UInt8], setting: Setting) -> [UInt8] {
        switch setting {
        case .system(.pauseOnRemoval) where protocolInformation?.generation == .v1: [payload[3] == 1 ? 0 : 1]
        case .voiceGuidance where voiceGuidance.generation == .v1: [payload[3] == 1 ? 0 : 1]
        case .playbackVolume: [payload[playback.generation == .v1 ? 3 : 2]]
        case .system, .voiceGuidance, .voiceGuidanceVolume, .callVolume, .batteryCare, .autoPowerSave: [payload[2]]
        case .dsee: protocolInformation?.generation == .v1 ? Array(payload.dropFirst()) : [payload[2]]
        case .automaticPowerOff, .voiceAssistant, .sidetone, .touchAssignments, .speakToChatOptions, .legacySoundEffect: Array(payload.dropFirst())
        case .touchCustomActions: [payload[3], payload[5], payload[6]]
        case .noiseControl:
            protocolInformation?.generation == .v1 && payload.count == 8 && payload[2] == 0x11
                ? [payload[1], 0x01] + payload.dropFirst(3) : Array(payload.dropFirst())
        case .equalizer: equalizer.confirmationValue(payload)
        case .equalizerReadback: []
        case .powerSaveEffect: Array(payload.dropFirst(2))
        }
    }

    private func sendSetting(_ payload: [UInt8], setting: Setting, type: UInt8 = 0x0C) {
        guard powerOffState == nil, !isRunningHeadphoneTest else { return }
        guard deviceActionTransition?.isFinished != false else {
            settingErrors[setting] = String(localized: "Finish changing the device connection first.")
            return
        }
        guard connectionTransition?.isFinished != false else {
            settingErrors[setting] = String(localized: "Finish the current connection change first.")
            return
        }
        guard multipointTransition?.isFinished != false else {
            settingErrors[setting] = String(localized: "Finish changing device connections first.")
            return
        }
        settingErrors[setting] = nil
        unconfirmedChanges[setting] = nil
        pendingChanges[setting] = settingValue(payload, setting: setting)
        settingRequests[setting] = UUID()
        if setting == .batteryCare || setting == .autoPowerSave || setting == .powerSaveEffect {
            powerRequestIDs[setting] = settingRequests[setting]
        }
        if setting == .equalizer { unconfirmedEqualizerRequestID = nil }
        send(payload, type: type)
    }

    private func beginSettingConfirmation(_ frame: SonyFrame) {
        let payload = frame.payload
        guard payload.count >= 2 else { return }
        let setting: Setting
        let query: [UInt8]?
        if frame.type == 0x0C, payload == equalizer.parameterQueryPayload {
            guard equalizerRead?.setting == .equalizerReadback,
                  equalizerRead?.requestID == settingRequests[.equalizerReadback] else { return }
            setting = .equalizerReadback
            query = nil
        } else if payload.count < 3 {
            return
        } else if payload[0] == 0x28, payload.count == 3,
                  frame.type == powerFeatures.batteryCare?.frameType, payload[1] == powerFeatures.batteryCare?.inquiryType {
            setting = .batteryCare
            query = [0x26, payload[1]]
        } else if frame.type == 0x0C, payload.count == 4, payload.prefix(2) == [0x28, 0x0B] {
            setting = payload[3] == 1 ? .powerSaveEffect : .autoPowerSave
            query = [0x26, 0x0B]
        } else if frame.type == 0x0E {
            guard payload[0] == 0x48 else { return }
            if payload[1] == 0x01, payload.count == (voiceGuidance.generation == .v1 ? 4 : 3) {
                setting = .voiceGuidance
            } else if payload[1] == 0x20, payload.count == 4 {
                setting = .voiceGuidanceVolume
            } else {
                return
            }
            query = setting == .voiceGuidance ? voiceGuidance.parameterQueryPayload : [0x46, payload[1]]
        } else if frame.type != 0x0C {
            return
        } else if protocolInformation?.generation == .v1, payload[0] == 0x48, payload.count == 3,
                  let kind = SonyLegacySoundEffect.Kind(rawValue: payload[1]) {
            setting = .legacySoundEffect(kind)
            query = legacySoundEffect(kind).parameterQuery
        } else if payload[0] == 0x68, decodedNoiseControlMode(payload) != nil {
            setting = .noiseControl
            query = [0x66, payload[1]]
        } else if payload[0] == 0x58, payload[1] == equalizer.inquiryType {
            setting = .equalizer
            query = equalizer.parameterQueryPayload
        } else if protocolInformation?.generation == .v1, legacyControls?.dsee.acceptsSetPayload(payload) == true {
            setting = .dsee
            query = [0xE6, 0x02]
        } else if protocolInformation?.generation == .v2, payload[0] == 0xE8, payload[1] == 0x01 {
            setting = .dsee
            query = [0xE6, 0x01]
        } else if payload[0] == 0xA8, let volumeSetting = playbackVolumeSetting(payload) {
            setting = volumeSetting
            query = playback.queryPayload(for: payload)
        } else if payload[0] == 0xFC, payload.count == 4, payload[1] == 0x0C {
            setting = .speakToChatOptions
            query = [0xFA, 0x0C]
        } else if protocolInformation?.generation == .v1, payload.count == 4, payload.prefix(3) == [0xF8, 0x03, 0], payload[3] <= 1 {
            setting = .system(.pauseOnRemoval)
            query = [0xF6, 0x03]
        } else if let state = automaticPowerOff, payload[1] == state.inquiryType,
                  payload[0] == (state.generation == .v1 ? 0xF8 : 0x28),
                  payload.count == (state.generation == .v1 ? 5 : 4), state.generation != .v1 || payload[2] == 1 {
            setting = .automaticPowerOff
            query = state.parameterQueryPayload
        } else if protocolInformation?.generation == .v2, payload.count == 3, payload.prefix(2) == [0xF8, 0x04],
                  systemFeatures.voiceAssistant != nil {
            setting = .voiceAssistant
            query = [0xF6, 0x04]
        } else if payload[0] == 0xF8, payload[1] == touchAssignments.inquiryType {
            setting = .touchAssignments
            query = [0xF6, payload[1]]
        } else if payload.count == 7, payload.prefix(3) == [0xFC, 0x03, 1], payload[4] == 1,
                  touchAssignments.inquiryType == 0x03 {
            setting = .touchCustomActions
            query = [0xFA, 0x03]
        } else if payload[0] == 0xF8, let feature = SonySystemFeature(rawValue: payload[1]) {
            setting = .system(feature)
            query = [0xF6, feature.rawValue]
        } else if payload[0] == 0xD8, payload.count == 4, payload[1] == systemFeatures.sidetoneSlot, payload[2] == 0 {
            setting = .sidetone
            query = [0xD6, payload[1]]
        } else {
            return
        }
        guard let requestID = settingRequests[setting], pendingChanges[setting] == settingValue(payload, setting: setting) else { return }
        let session = controlSession
        let refresh = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.settingRequests[setting] == requestID else { return }
                #if DEBUG
                if self.isSimulated {
                    if self.simulatesSettingReplies {
                        if setting == .equalizerReadback {
                            return
                        } else if setting == .equalizer, self.equalizer.generation == .v1, payload[2] == 0xFF {
                            self.dispatch([0x59, payload[1], EqualizerPreset.manual.rawValue] + payload.dropFirst(3), type: frame.type)
                        } else if setting == .batteryCare {
                            self.dispatch([0x29, payload[1], payload[2]], type: frame.type)
                        } else if setting == .touchCustomActions {
                            var records: [UInt8] = []
                            for record in self.touchAssignments.customizedActions ?? [] {
                                records += [record.preset, UInt8(record.actions.count)]
                                for action in record.actions {
                                    records += [action.action, record.preset == payload[3] && action.action == payload[5] ? payload[6] : action.function]
                                }
                            }
                            self.dispatch([0xFD, 0x03, UInt8(self.touchAssignments.customizedActions?.count ?? 0)] + records, type: frame.type)
                        } else if setting == .autoPowerSave || setting == .powerSaveEffect {
                            let effect: UInt8 = setting == .powerSaveEffect ? 1
                                : self.powerFeatures.autoPowerSave?.effectActive == true ? 0 : 1
                            self.dispatch([0x29, 0x0B, payload[2], effect], type: frame.type)
                        } else if frame.type == 0x0E, let query {
                            self.send(query, type: frame.type)
                        } else {
                            self.dispatch([payload[0] + 1] + payload.dropFirst(), type: frame.type)
                        }
                    }
                    return
                }
                #endif
                if let query {
                    self.send(query, type: frame.type)
                }
            }
        }
        settingRefreshes[setting] = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: refresh)
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.settingRequests[setting] == requestID else { return }
                self.unconfirmedChanges[setting] = self.pendingChanges[setting]
                if setting == .equalizer { self.unconfirmedEqualizerRequestID = requestID }
                self.pendingChanges[setting] = nil
                self.settingRequests[setting] = nil
                self.settingErrors[setting] = setting == .equalizerReadback
                    ? String(localized: "Headphones did not return equalizer settings.") : String(localized: "Headphones did not confirm the change.")
                if setting == .dsee { self.invalidateExpiredDSEERead() }
                self.settingTimeouts[setting] = nil
                self.settingRefreshes[setting] = nil
                if setting == .equalizer || setting == .equalizerReadback { self.sendRequestedEqualizer() }
                self.finishSettingIntent(setting, requestID: requestID,
                    error: HeadphoneControlError(message: String(localized: "Headphones did not confirm the change.")))
                if setting == .noiseControl {
                    self.sendRequestedNoiseControl()
                }
                if let query {
                    if frame.type == 0x0E, query.first == 0x46 { self.send(query, type: frame.type) }
                    else if self.powerQuerySetting(query, type: frame.type) != nil { self.send(query, type: frame.type) }
                    else if self.systemReadSetting(query) != nil { self.send(query) }
                }
            }
        }
        settingTimeouts[setting] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func confirmSetting(_ setting: Setting, value: [UInt8]?) {
        let sentValue = settingTimeouts[setting] == nil ? nil : pendingChanges[setting]
        guard let expected = sentValue ?? unconfirmedChanges[setting],
              value == expected || (setting == .equalizer && expected.count == 1 && value?.first == expected.first) else { return }
        let requestID = settingRequests[setting]
        pendingChanges[setting] = nil
        unconfirmedChanges[setting] = nil
        powerRequestIDs[setting] = nil
        if setting == .equalizer { unconfirmedEqualizerRequestID = nil }
        settingRequests[setting] = nil
        settingErrors[setting] = nil
        settingTimeouts.removeValue(forKey: setting)?.cancel()
        settingRefreshes.removeValue(forKey: setting)?.cancel()
        finishSettingIntent(setting, requestID: requestID)
        if setting == .equalizer || setting == .equalizerReadback { sendRequestedEqualizer() }
        if setting == .noiseControl {
            isApplyingChange = false
            commandTimeoutWorkItem?.cancel()
            commandTimeoutWorkItem = nil
            sendRequestedNoiseControl()
        }
    }

    private func resetSettingRequests(preservingTimedOutReads: Bool = false) {
        finishSettingIntent(settingIntent?.setting, requestID: settingIntent?.requestID,
            error: HeadphoneControlError(message: String(localized: "The headphone connection changed before the action was confirmed.")))
        requestedNoiseControlPayload = nil
        equalizerWorkItem?.cancel()
        equalizerWorkItem = nil
        equalizerDebounceID = nil
        requestedEqualizerPayload = nil
        equalizerReadTimeout?.cancel()
        equalizerReadTimeout = nil
        equalizerRead = nil
        unconfirmedEqualizerRequestID = nil
        for workItem in settingTimeouts.values { workItem.cancel() }
        for workItem in settingRefreshes.values { workItem.cancel() }
        settingTimeouts = [:]
        settingRefreshes = [:]
        pendingChanges = [:]
        unconfirmedChanges = [:]
        settingRequests = [:]
        if preservingTimedOutReads {
            var retained = Set(systemReads.values.filter { $0.transmitted && $0.timedOut }.compactMap(\.errorSetting))
            for read in powerReads.values where read.transmitted && read.timedOut { retained.insert(read.setting) }
            for (query, read) in voiceGuidanceReads where read.transmitted && read.isObsolete && read.timeout == nil {
                retained.insert(query[1] == 1 ? .voiceGuidance : .voiceGuidanceVolume)
            }
            if legacyDSEEReadTimeouts.values.contains(where: { $0.work == nil }) { retained.insert(.dsee) }
            for (query, timeout) in legacySoundEffectReadTimeouts where timeout.work == nil {
                if let kind = SonyLegacySoundEffect.Kind(rawValue: query[1]) { retained.insert(.legacySoundEffect(kind)) }
            }
            settingErrors = settingErrors.filter { retained.contains($0.key) }
        } else {
            settingErrors = [:]
        }
        queuedSpeakToChatOptions = nil
        queuedTouchChange = nil
        resetPowerReads(preservingTimedOutReads: preservingTimedOutReads)
        powerRequestIDs = [:]
        pendingPlaybackCommand = nil
        queuedPlaybackSource = nil
        queuedVolumeSource = nil
        queuedMusicVolumeIsCurrent = nil
    }

    func setCustomEqualizer(_ settings: EqualizerSettings) {
        guard let payload = equalizer.settingsPayload(settings) else {
            if isReady { settingErrors[.equalizer] = String(localized: "This equalizer layout is not available on the headphones.") }
            return
        }
        queueEqualizer(payload, debounce: true)
    }

    private func queueEqualizer(_ payload: [UInt8], debounce: Bool) {
        guard powerOffState == nil, !isRunningHeadphoneTest, multipointTransition?.isFinished != false, deviceActionTransition?.isFinished != false else { return }
        guard stage == .ready, connectionTransition?.isFinished != false else { return }
        equalizerWorkItem?.cancel()
        equalizerWorkItem = nil
        equalizerDebounceID = nil
        requestedEqualizerPayload = payload
        settingErrors[.equalizer] = nil
        guard debounce else {
            sendRequestedEqualizer()
            return
        }
        let session = controlSession
        let request = UUID()
        equalizerDebounceID = request
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.equalizerDebounceID == request else { return }
                self.equalizerWorkItem = nil
                self.sendRequestedEqualizer()
            }
        }
        equalizerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func sendRequestedEqualizer() {
        guard stage == .ready, connectionTransition?.isFinished != false,
              deviceActionTransition?.isFinished != false,
              equalizerWorkItem == nil, pendingChanges[.equalizer] == nil,
              pendingChanges[.equalizerReadback] == nil, let payload = requestedEqualizerPayload else { return }
        requestedEqualizerPayload = nil
        guard equalizer.acceptsSetPayload(payload) else {
            settingErrors[.equalizer] = String(localized: "Equalizer settings changed before the request could be sent.")
            return
        }
        sendSetting(payload, setting: .equalizer)
    }

    private func beginEqualizerRead() {
        guard var read = equalizerRead else { return }
        read.transmitted = true
        read.unconfirmedRequestID = unconfirmedEqualizerRequestID
        equalizerRead = read
        let readID = read.id
        let session = controlSession
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session, self.equalizerRead?.id == readID else { return }
                self.equalizerRead?.timedOut = true
                self.equalizerReadTimeout = nil
                if self.settingRequests[.equalizerReadback] != nil { self.failEqualizerReadback() }
                self.verifyConnectionPreferenceIfNeeded()
            }
        }
        equalizerReadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        #if DEBUG
        if isSimulated, simulatesSettingReplies {
            guard let type = equalizer.inquiryType else { return }
            let reply: [UInt8]
            if equalizerPreset == .manual, let payload = equalizer.settingsPayload(customEqualizer) {
                reply = [0x57, type, EqualizerPreset.manual.rawValue] + payload.dropFirst(3)
            } else {
                reply = [0x57, type, equalizer.presetID ?? 0x00, 0x00]
            }
            let delay = CommandLine.arguments.contains("-ui-testing") && CommandLine.arguments.contains("--delayed-equalizer-readback") ? 2.0 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    guard let self, self.controlSession == session, self.equalizerRead?.id == readID else { return }
                    self.dispatch(reply, type: 0x0C)
                }
            }
        }
        #endif
    }

    private func failEqualizerReadback(message: String = String(localized: "An equalizer read is still unanswered. Reconnect the headphones to retry.")) {
        pendingChanges[.equalizerReadback] = nil
        unconfirmedChanges[.equalizerReadback] = nil
        settingRequests[.equalizerReadback] = nil
        settingTimeouts.removeValue(forKey: .equalizerReadback)?.cancel()
        settingRefreshes.removeValue(forKey: .equalizerReadback)?.cancel()
        settingErrors[.equalizerReadback] = message
        sendRequestedEqualizer()
    }

    func applyPreset(mode: NoiseControlMode, ambientLevel level: Int, focusOnVoice focus: Bool) {
        guard canApplyNoisePreset(mode: mode, ambientLevel: level, focusOnVoice: focus) else { return }
        ambientWorkItem?.cancel()
        focusOnVoice = focus
        if let range = ambientLevelRange { ambientLevel = max(range.lowerBound, min(range.upperBound, level)) }
        sendNoiseControl(mode)
    }

    var canChangeNoiseControl: Bool { noiseControlUnavailableReason == nil }

    var ambientLevelStep: Int { noiseControl?.ambientStep(focusOnVoice: focusOnVoice) ?? 1 }

    private func normalizedAmbientLevel(_ level: Int) -> Int? {
        guard let range = ambientLevelRange else { return nil }
        if let capability = noiseControl?.ambientCapability(focusOnVoice: focusOnVoice) {
            return capability.normalized(level)
        }
        return min(range.upperBound, max(range.lowerBound, level))
    }

    var ambientLevelRange: ClosedRange<Int>? {
        if protocolInformation?.generation == .v1 {
            return legacyControls?.noiseCapability?.ambientRange(focusOnVoice: focusOnVoice)
        }
        if let noiseControl { return noiseControl.ambientRange(focusOnVoice: focusOnVoice) }
        return 1...20
    }

    var supportsVoiceFocus: Bool {
        if let noiseControl { return noiseControl.ambientRange(focusOnVoice: true) != nil }
        return protocolInformation?.generation != .v1
            || legacyControls?.noiseCapability?.ambientRange(focusOnVoice: true) != nil
    }

    func canApplyNoisePreset(mode: NoiseControlMode, ambientLevel level: Int, focusOnVoice focus: Bool) -> Bool {
        guard canChangeNoiseControl, availableNoiseModes.contains(mode) else { return false }
        if let noiseControl {
            return noiseControl.setPayload(mode: mode, ambientLevel: mode == .ambient ? level : nil,
                                              focusOnVoice: mode == .ambient ? focus : nil) != nil
        }
        guard let legacyControls else { return true }
        return legacyControls.noiseControlPayload(mode: mode, ambientLevel: level, focusOnVoice: focus) != nil
    }

    private func sendNoiseControl(_ mode: NoiseControlMode) {
        ambientWorkItem?.cancel()
        ambientWorkItem = nil
        if let issue = noiseControlUnavailableReason {
            settingErrors[.noiseControl] = issue
            return
        }
        guard availableNoiseModes.contains(mode), let asmType else { return }
        requestedNoiseControlPreservesAdaptation = true
        if let legacyControls {
            guard let range = ambientLevelRange,
                  let payload = legacyControls.noiseControlPayload(mode: mode,
                    ambientLevel: min(range.upperBound, max(range.lowerBound, ambientLevel)), focusOnVoice: focusOnVoice) else { return }
            requestedNoiseControlPayload = payload
            sendRequestedNoiseControl()
            return
        }
        if let noiseControl {
            guard let payload = noiseControl.setPayload(mode: mode,
                    ambientLevel: mode == .ambient ? ambientLevel : nil,
                    focusOnVoice: mode == .ambient ? focusOnVoice : nil) else { return }
            requestedNoiseControlPayload = payload
            sendRequestedNoiseControl()
            return
        }
        let noNoiseCancelling = asmType == 0x21 || asmType == 0x22
        let hasWindMode = asmType == 0x15
        var payload: [UInt8] = [0x68, asmType, 0x01, mode == .off ? 0x00 : 0x01]
        if !noNoiseCancelling { payload.append(mode == .ambient ? 0x01 : 0x00) }
        if hasWindMode { payload.append(mode == .wind ? 0x03 : 0x02) }
        payload += [focusOnVoice ? 1 : 0, UInt8(max(1, min(20, ambientLevel)))]
        requestedNoiseControlPayload = payload
        sendRequestedNoiseControl()
    }

    private var noiseControlUnavailableReason: String? {
        guard stage == .ready, isReady, asmType != nil, powerOffState == nil else { return String(localized: "Connect the headphones first.") }
        if noiseControl != nil || legacyControls != nil, unconfirmedChanges[.noiseControl] != nil {
            return String(localized: "Sync noise control before making another change.")
        }
        if noiseControl != nil, noiseControl?.canSet != true {
            return String(localized: "Noise control is unavailable on the headphones.")
        }
        if protocolInformation?.generation == .v1, legacyControls?.canSetNoiseControl != true {
            return String(localized: "Noise control is unavailable on the headphones.")
        }
        guard !isRunningHeadphoneTest else { return String(localized: "Finish the current headphone test first.") }
        guard connectionTransition?.isFinished != false, sourceTransition?.isFinished != false,
              multipointTransition?.isFinished != false, deviceActionTransition?.isFinished != false else {
            return String(localized: "Finish the current connection change first.")
        }
        return nil
    }

    private func sendRequestedNoiseControl() {
        guard pendingChanges[.noiseControl] == nil, var payload = requestedNoiseControlPayload else { return }
        requestedNoiseControlPayload = nil
        if let issue = noiseControlUnavailableReason {
            settingErrors[.noiseControl] = issue
            return
        }
        guard let mode = decodedNoiseControlMode(payload), availableNoiseModes.contains(mode) else {
            settingErrors[.noiseControl] = String(localized: "Noise controls changed. Choose the setting again.")
            return
        }
        if let noiseControl, requestedNoiseControlPreservesAdaptation {
            guard let updated = noiseControl.setPayload(mode: mode,
                ambientLevel: mode == .ambient ? Int(payload[6]) : nil,
                focusOnVoice: mode == .ambient ? payload[5] == 1 : nil) else { return }
            payload = updated
        }
        noiseControlWriteState = noiseControl?.state
        beginApplyingChange()
        sendSetting(payload, setting: .noiseControl)
    }

    func setAmbientLevel(_ level: Int) {
        guard canChangeNoiseControl, let level = normalizedAmbientLevel(level) else { return }
        ambientLevel = level
        ambientWorkItem?.cancel()
        ambientWorkItem = nil
        guard noiseControlMode == .ambient else { return }
        let session = controlSession
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.controlSession == session else { return }
                self.sendNoiseControl(.ambient)
            }
        }
        ambientWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
    }

    func setFocusOnVoice(_ enabled: Bool) {
        guard canChangeNoiseControl, supportsVoiceFocus else { return }
        focusOnVoice = enabled
        if let level = normalizedAmbientLevel(ambientLevel) { ambientLevel = level }
        if noiseControlMode == .ambient { sendNoiseControl(.ambient) }
    }

    func setNoiseAdaptation(enabled: Bool) {
        guard canChangeNoiseControl, pendingChanges[.noiseControl] == nil, ambientWorkItem == nil,
              let payload = noiseControl?.setPayload(adaptationEnabled: enabled) else { return }
        requestedNoiseControlPreservesAdaptation = false
        requestedNoiseControlPayload = payload
        sendRequestedNoiseControl()
    }

    func setNoiseAdaptationSensitivity(_ sensitivity: SonyNoiseControl.Sensitivity) {
        guard canChangeNoiseControl, pendingChanges[.noiseControl] == nil, ambientWorkItem == nil,
              let payload = noiseControl?.setPayload(sensitivity: sensitivity) else { return }
        requestedNoiseControlPreservesAdaptation = false
        requestedNoiseControlPayload = payload
        sendRequestedNoiseControl()
    }

    private func beginApplyingChange() {
        isApplyingChange = true
        commandTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.isApplyingChange = false }
        }
        commandTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func openSonyLink(automatically: Bool = false, discoverServices: Bool = true) {
        guard !isSystemSleeping, serviceDiscoveryID == nil else { return }
        guard powerOffState == nil, !isRunningHeadphoneTest else { return }
        guard let device else { return }
        if automatically, stage == .idle, deviceActionTransition?.phase == .failed {
            guard canRecoverDeviceAction else { return }
            deviceActionRecoveryAttempts += 1
        }
        stage = .protocolInfo
        linkState = .opening
        scheduleHandshakeTimeout()
        if rfcommCloseCompletion.wait(timeout: .now()) != .success {
            let identifier = UUID()
            let session = controlSession
            pendingClassicOpenID = identifier
            rfcommCloseCompletion.notify(queue: .main) { [weak self] in
                guard let self, self.controlSession == session,
                      self.pendingClassicOpenID == identifier else { return }
                self.pendingClassicOpenID = nil
                self.openSonyLink(automatically: automatically, discoverServices: discoverServices)
            }
            return
        }
        pendingClassicOpenID = nil
        guard let (record, uuid) = Self.sonyServiceRecord(on: device) else {
            if discoverServices {
                discoverSonyService(on: device, automatically: automatically)
            } else {
                sonyServiceUnavailable(on: device, automatically: automatically)
            }
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            fail(String(localized: "Could not open the headphones’ Bluetooth control connection."))
            return
        }
        let (result, openedChannel) = device.openSonyRFCOMMChannel(withChannelID: channelID, delegate: self)
        channel = openedChannel
        if let openedChannel { channelIO = RFCOMMChannelIO(channel: openedChannel) }
        guard result == kIOReturnSuccess else {
            handleOpenFailure(result)
            return
        }
        controlChannelID = Int(channelID)
        let service = uuid.prefix(4).map { String(format: "%02X", $0) }.joined()
        Self.logger.info("Opening RFCOMM channel \(channelID) for Sony service \(service, privacy: .public)")
    }

    private func discoverSonyService(on target: any SonyBluetoothDevice, automatically: Bool) {
        guard target.isClassicConnected() else {
            isDeviceConnected = false
            closeSonyLink()
            linkState = .disconnected
            return
        }
        guard serviceDiscoveries.isEmpty else {
            sonyServiceUnavailable(on: target, automatically: automatically)
            return
        }
        let identifier = UUID()
        let session = controlSession
        serviceDiscoveryID = identifier
        let discovery = ServiceDiscovery { [weak self] device, status in
            guard let self else { return }
            self.serviceDiscoveries[identifier] = nil
            guard self.serviceDiscoveryID == identifier, self.controlSession == session,
                  self.device === device, !self.isSystemSleeping else { return }
            self.serviceDiscoveryID = nil
            guard device.isClassicConnected() else {
                self.isDeviceConnected = false
                self.closeSonyLink()
                self.linkState = .disconnected
                return
            }
            Self.logger.info("Sony service discovery finished; status=\(status)")
            if status == kIOReturnSuccess {
                self.openSonyLink(automatically: automatically, discoverServices: false)
            } else {
                self.sonyServiceUnavailable(on: device, automatically: automatically)
            }
        }
        serviceDiscoveries[identifier] = discovery
        Self.logger.info("Querying missing Sony control service")
        let result = target.performSonySDPQuery(discovery)
        if result != kIOReturnSuccess { discovery.complete(target, result) }
    }

    private func sonyServiceUnavailable(on device: any SonyBluetoothDevice, automatically: Bool) {
        if multipointTransition?.phase != .recovering,
           openPairedBluetoothLE(for: device, automatically: automatically, allowPairedBootstrap: device.isClassicConnected()) { return }
        fail(String(localized: "Could not connect to the headphones’ controls."))
    }

    @MainActor
    private final class ServiceDiscovery: NSObject, SonyServiceDiscoveryDelegate {
        let complete: (any SonyBluetoothDevice, IOReturn) -> Void

        init(complete: @escaping (any SonyBluetoothDevice, IOReturn) -> Void) {
            self.complete = complete
        }

        @objc nonisolated
        func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            Task { @MainActor in sonySDPQueryComplete(device, status: status) }
        }

        func sonySDPQueryComplete(_ device: any SonyBluetoothDevice, status: IOReturn) {
            complete(device, status)
        }
    }

    private func closeSonyLink() {
        lastReceivedSequence = nil
        earbudFinder?.dismiss(retiringTransport: true)
        classicConnectionID = nil
        pendingClassicOpenID = nil
        serviceDiscoveryID = nil
        announcedAudioSourceAddress = nil
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        nativeAppearanceRefresh?.stop()
        #endif
        legacyOptimizerTransition?.controlLost()
        legacyOptimizerTimeout?.cancel()
        legacyOptimizerTimeout = nil
        legacyOptimizerTimeoutPhase = nil
        headGesturePracticeTransition?.controlLost()
        headGesturePracticeTimeout?.cancel()
        headGesturePracticeTimeout = nil
        headGesturePracticeTimeoutPhase = nil
        if let transition = headGesturePracticeTransition, transition.dismissWhenFinished, transition.phase == .finished {
            dismissHeadGesturePractice(id: transition.id)
        }
        earTipFitTransition?.controlLost()
        earTipFitTimeout?.cancel()
        earTipFitTimeout = nil
        earTipFitTimeoutPhase = nil
        if let transition = earTipFitTransition, transition.dismissWhenFinished, transition.phase == .finished {
            dismissEarTipFit(id: transition.id)
        }
        if powerOffRequestSession == controlSession {
            if powerOffState == .sending { powerOffState = .unconfirmed }
            if powerOffState == .acknowledged { powerOffState = .disconnected }
            powerOffRequestSession = nil
        }
        if multipointTransition?.phase == .complete || multipointTransition?.phase == .cancelled { multipointConnection = nil }
        connectionTransition?.controlLost(session: controlSession)
        sourceTransition?.controlLost(session: controlSession)
        deviceActionTransition?.controlLost(session: controlSession)
        multipointTransition?.controlLost(session: controlSession)
        updateMultipointTimeout()
        controlSession += 1
        pendingInboundAcknowledgments = 0
        cancelScheduledRetry(resetAttempts: false)
        resetCommandQueue()
        let closingBLETransport = bleTransport
        bleTransport = nil
        closingBLETransport?.stop()
        usesBluetoothLE = false
        controlPeripheralID = nil
        expectedBLEIdentity = nil
        bluetoothLEIdentityReadTransmitted = false
        bluetoothLEHash = nil
        controlAddresses = []
        let closingChannel = channel
        channel = nil
        let closingIO = channelIO
        channelIO = nil
        classicIncomingData.removeAll(keepingCapacity: false)
        classicIncomingDataLength = 0
        for write in classicWrites.values { write.timeout.cancel() }
        if let closingChannel, let closingIO {
            rfcommCloseCompletion.enter()
            let closingWrites = classicWrites.filter { $0.value.channel === closingChannel }
            let finishClosing: @MainActor @Sendable () -> Void = {
                for identifier in closingWrites.keys { self.classicWrites[identifier] = nil }
                self.rfcommCloseCompletion.leave()
            }
            closingIO.close(completion: finishClosing)
        }
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        handshakeID = nil
        ambientWorkItem?.cancel()
        ambientWorkItem = nil
        commandTimeoutWorkItem?.cancel()
        commandTimeoutWorkItem = nil
        stage = .idle
        updateConnectionModeTimeout()
        asmType = nil
        noiseControlMode = nil
        noiseControl = nil
        noiseControlDisplayState = nil
        batteries = SonyBatteries()
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        nativeBatterySnapshot = nil
        #endif
        lowBatteryReadings = []
        caseBatteryObservedAt = nil
        chargingCaseTimeout?.cancel()
        chargingCaseTimeout = nil
        isChargingInCase = false
        isApplyingChange = false
        equalizer = SonyEqualizer()
        firmwareVersion = nil
        protocolVersion = nil
        protocolInformation = nil
        legacyControls = nil
        legacySurround = SonyLegacySoundEffect(kind: .surround)
        legacySoundPosition = SonyLegacySoundEffect(kind: .soundPosition)
        legacyOptimizer = SonyLegacyOptimizer()
        deviceInformation = SonyDeviceInformation()
        resetDiscoveryReads()
        controlChannelID = nil
        equalizerWorkItem?.cancel()
        equalizerWorkItem = nil
        resetSettingRequests()
        audioFeatures = SonyAudioFeatures()
        systemFeatures = SonySystemFeatures()
        powerFeatures = SonyPowerFeatures()
        playback = SonyPlayback()
        touchAssignments = SonyTouchAssignments()
        voiceGuidance = SonyVoiceGuidance()
        soundPressure = SonySoundPressure()
        wearingStatus = SonyWearingStatus()
        earTipFit = SonyEarTipFit()
        headGesturePractice = SonyHeadGesturePractice()
        multipoint = SonyMultipoint()
        lastConnectionAlert = nil
        supportedFunctions = []
        supportedFunctions2 = []
        supportsTable2 = false
        supportFunctionsReadTransmitted = false
        table2CapabilitiesSession = nil
        lastSyncDate = nil
    }

    private func beginHandshake(reusingConnection: Bool = false) {
        guard powerOffState == nil, !isRunningHeadphoneTest else { return }
        if reusingConnection, equalizerRead != nil || !batteryReads.isEmpty || !playbackReads.isEmpty
            || soundPressureRead != nil || inventoryRead != nil || noiseControlRead != nil
            || queuedNoiseControlRead || !noiseReadTimeouts.isEmpty || noiseControlRefresh != nil
            || discoveryReads.values.contains(where: { $0.retryTransmitted || ($0.transmitted && !$0.resolved) }) {
            closeSonyLink()
            linkState = .disconnected
            scheduleRetry()
            return
        }
        resetWearingStatusRead(preservingPendingRead: reusingConnection)
        protocolInformation = nil
        supportFunctionsReadTransmitted = false
        bluetoothLEIdentityReadTransmitted = false
        legacyControls = nil
        legacySurround = SonyLegacySoundEffect(kind: .surround)
        legacySoundPosition = SonyLegacySoundEffect(kind: .soundPosition)
        legacyOptimizer = SonyLegacyOptimizer()
        noiseControl = nil
        noiseControlDisplayState = nil
        if noiseControlRead?.timedOut == true { noiseControlRead = nil }
        noiseControlRefreshAttempted = false
        noiseControlSawValidChanging = false
        noiseMetadataReads = [:]
        legacyReads = reusingConnection ? timedOutLegacyReads : []
        queuedLegacyReads = []
        resetLegacyOptionalReads(preservingTimedOutReads: reusingConnection)
        obsoleteLegacyBatteryReads = []
        resetLegacyDSEEReads(preservingTimedOutReads: reusingConnection)
        resetLegacySoundEffectReads(preservingTimedOutReads: reusingConnection)
        resetSystemReads(preservingTimedOutReads: reusingConnection)
        resetVoiceGuidanceReads(preservingTimedOutReads: reusingConnection)
        resetBatteryReads()
        resetPowerReads(preservingTimedOutReads: reusingConnection)
        deviceInformation = SonyDeviceInformation()
        resetDiscoveryReads()
        multipointReadbacks = []
        resetFirmwareUpdateReads()
        multipointQueuedReadSlot = nil
        supportedFunctions2 = []
        multipoint = SonyMultipoint()
        table2CapabilitiesSession = nil
        voiceGuidance = SonyVoiceGuidance()
        soundPressure = SonySoundPressure()
        wearingStatus = SonyWearingStatus()
        sourceTransition?.controlLost(session: controlSession)
        deviceActionTransition?.controlLost(session: controlSession)
        deviceActionTimeout?.cancel()
        deviceActionTimeout = nil
        sourceTimeout?.cancel()
        sourceTimeout = nil
        inventoryReadTimeout?.cancel()
        inventoryReadTimeout = nil
        inventoryRead = nil
        announcedAudioSourceAddress = nil
        controlSession += 1
        classicIncomingData.removeAll(keepingCapacity: false)
        classicIncomingDataLength = 0
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        nativeBatterySnapshot = nil
        #endif
        lowBatteryReadings = []
        caseBatteryObservedAt = nil
        chargingCaseTimeout?.cancel()
        chargingCaseTimeout = nil
        isChargingInCase = false
        if connectionTransition?.isFinished == true, connectionTransition?.phase != .failed {
            connectionTransition = nil
            connectionRequestID = nil
            transitionDevice = nil
            transitionAddress = nil
            transitionHash = nil
            transitionPeripheralID = nil
            transitionControlAddresses = []
            recoveryUsesBLE = nil
            recoveryClassicAddress = nil
        }
        if reusingConnection {
            resetSettingRequests(preservingTimedOutReads: true)
            resetPlaybackReads()
            resetSoundPressureRead()
            fixedAlertsEnabled = false
            connectionTransition?.controlReady(session: controlSession)
        } else {
            resetCommandQueue()
            stream = SonyFrameStream()
            lastReceivedSequence = nil
        }
        stage = .protocolInfo
        linkState = .handshaking
        updateConnectionModeTimeout()
        scheduleHandshakeTimeout()
        send([0x00, 0x00])
    }

    private func scheduleHandshakeTimeout() {
        handshakeTimeoutWorkItem?.cancel()
        let identifier = UUID()
        handshakeID = identifier
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.handshakeID == identifier else { return }
                self.fail(String(localized: "The headphones did not respond."))
            }
        }
        handshakeTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func resetPlaybackReads() {
        for timeout in playbackReadTimeouts.values { timeout.cancel() }
        playbackReadTimeouts = [:]
        playbackReads = [:]
        queuedPlaybackQueries = []
        playbackSourceGeneration = 0
        playbackFreshQueries = []
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        musicVolumeReadbackID = nil
        musicStatusReadbackID = nil
        #endif
        playbackReadError = nil
    }

    private func resetSoundPressureRead() {
        soundPressureReadTimeout?.cancel()
        soundPressureReadTimeout = nil
        soundPressureRead = nil
        soundPressureReadError = nil
        lastSoundPressureRequest = nil
        invalidateSoundPressureReading()
    }

    private func resetWearingStatusRead(preservingPendingRead: Bool = false) {
        wearingStatusReadTimeout?.cancel()
        wearingStatusReadTimeout = nil
        if preservingPendingRead, wearingStatusRead != nil {
            wearingStatusRead?.transmitted = true
            wearingStatusRead?.timedOut = true
        } else {
            wearingStatusRead = nil
        }
        invalidateWearingStatus()
    }

    private func resetCommandQueue() {
        resetFirmwareUpdateReads()
        noiseControlRefresh?.work.cancel()
        noiseControlRefresh = nil
        noiseControlRefreshAttempted = false
        noiseControlSawValidChanging = false
        for timeout in noiseReadTimeouts.values { timeout.work.cancel() }
        noiseReadTimeouts = [:]
        noiseMetadataReads = [:]
        legacyReads = []
        queuedLegacyReads = []
        resetLegacyOptionalReads()
        obsoleteLegacyBatteryReads = []
        resetLegacyDSEEReads()
        noiseAvailabilityReadObsolete = false
        resetLegacySoundEffectReads()
        resetSystemReads()
        resetVoiceGuidanceReads()
        resetBatteryReads()
        resetPowerReads()
        noiseControlRead = nil
        queuedNoiseControlRead = false
        resetPlaybackReads()
        resetSoundPressureRead()
        resetWearingStatusRead()
        multipointReadbacks = []
        multipointQueuedReadSlot = nil
        sourceTransition?.controlLost(session: controlSession)
        deviceActionTransition?.controlLost(session: controlSession)
        deviceActionTimeout?.cancel()
        deviceActionTimeout = nil
        sourceTimeout?.cancel()
        sourceTimeout = nil
        inventoryReadTimeout?.cancel()
        inventoryReadTimeout = nil
        inventoryRead = nil
        commandQueue = SonyCommandQueue()
        modeReadbacks = []
        fixedAlertsEnabled = false
        transmittedFrame = nil
        acknowledgmentTimeout?.cancel()
        acknowledgmentTimeout = nil
        transmissionID = nil
    }

    private func send(_ payload: [UInt8], type: UInt8 = 0x0C, retryingDiscovery: Bool = false) {
        guard powerOffState == nil || (powerOffState == .sending && type == 0x0C && payload == Self.powerOffPayload) else { return }
        guard !isRunningHeadphoneTest || (type == 0x0C
            && (earTipFitTransition?.initialQueries.contains(payload) == true
                || payload == earTipFitTransition?.expectedPayload
                || headGesturePracticeTransition?.initialQueries.contains(payload) == true
                || payload == headGesturePracticeTransition?.expectedPayload
                || legacyOptimizerTransition?.pendingQueries.contains(payload) == true
                || payload == legacyOptimizerTransition?.expectedPayload)) else { return }
        guard isSimulated || channel != nil || bleTransport?.isReady == true else { return }
        if protocolInformation?.generation == .v1 {
            let isEqualizerQuery = equalizer.queryPayloads.contains(payload)
            let isSoundEffectQuery = legacySoundEffectQueryKind(payload) != nil
            let isConnectionAlert: Bool
            if payload == [0x94, 0x01, 0x00], protocolVersion.map({ $0 >= 0x4000 }) == true {
                isConnectionAlert = true
            } else if let transition = connectionTransition, transition.generation == .v1,
                      case .replyQueued(let alert, let action) = transition.phase {
                isConnectionAlert = payload == alert.replyPayload(action)
            } else {
                isConnectionAlert = false
            }
            let isTouchAssignment = touchAssignments.queryPayloads.contains(payload)
                || (payload.count >= 3 && payload.prefix(2) == [0xF8, 0x06]
                    && pendingChanges[.touchAssignments] == settingValue(payload, setting: .touchAssignments))
            let isVoiceGuidance = type == 0x0E && voiceGuidance.generation == .v1 && voiceGuidance.supportsGuidance
                && (voiceGuidance.queryPayloads.contains(payload)
                    || (payload.count == 4 && payload.prefix(3) == [0x48, 1, 1]
                        && voiceGuidance.setEnabledPayload(payload[3] == 1) == payload))
            guard isVoiceGuidance || (type == 0x0C && (
                  (legacyControls?.allows(payload) ?? [[0x04, 0x01], [0x04, 0x03], [0x06, 0x00]].contains(payload))
                    || isEqualizerQuery || equalizer.acceptsSetPayload(payload) || isTouchAssignment || isConnectionAlert
                    || isSoundEffectQuery || legacySurround.acceptsSetPayload(payload) || legacySoundPosition.acceptsSetPayload(payload)
                    || playback.queryPayloads.contains(payload)
                    || (payload.first == 0xA8 && payload.last.flatMap { playback.volumePayload(Int($0)) } == payload)
                    || firmwareUpdateQueries[payload] != nil
                    || (legacyOptimizer.isSupported && (legacyOptimizerTransition?.pendingQueries.contains(payload) == true
                        || payload == legacyOptimizerTransition?.expectedPayload)))) else { return }
            if type == 0x0C, (payload.count == 2 && [0x06, 0x10, 0x60, 0x62, 0xE0, 0xE2, 0xE6].contains(payload[0])
                && legacyControls?.connectionQuality.queryPayloads.contains(payload) != true)
                || payload == [0x04, 0x02] || (isEqualizerQuery && payload != equalizer.parameterQueryPayload) || isSoundEffectQuery {
                guard !legacyReads.contains(payload), queuedLegacyReads.insert(payload).inserted else { return }
            }
        }
        if (type == 0x0C && [[0x04, 0x01], [0x04, 0x03]].contains(payload))
            || (type == 0x0E && payload == [0x06, 0x00] && supportsTable2) {
            let key = [type] + payload
            if let read = discoveryReads[key] {
                guard retryingDiscovery, !read.retried, !read.resolved else { return }
                discoveryReads[key]?.retried = true
            } else {
                discoveryReads[key] = DiscoveryRead()
            }
        }
        if type == 0x0C, let inquiry = noiseControl?.inquiryType, payload == [0x60, inquiry] || payload == [0x62, inquiry] {
            guard noiseMetadataReads[payload] == nil else { return }
            noiseMetadataReads[payload] = false
        }
        if type == 0x0C, payload.count == 2, payload[0] == 0x66 {
            guard noiseControlRead == nil, !queuedNoiseControlRead else { return }
            queuedNoiseControlRead = true
        }
        if type == 0x0C, systemReads[payload] != nil { return }
        if type == 0x0C, legacyControls?.connectionQuality.queryPayloads.contains(payload) == true
            || legacyControls?.wearingControl.queryPayloads.contains(payload) == true
            || systemReadSetting(payload) == .dsee
            || touchAssignments.queryPayloads.contains(payload)
            || automaticPowerOff?.queryPayloads.contains(payload) == true
            || systemFeatures.voiceAssistant?.queryPayloads.contains(payload) == true
            || (payload.first == 0xD0 && systemFeatures.queryPayloads.contains(payload))
            || (payload.count == 2 && [0xD2, 0xD6].contains(payload[0]) && payload[1] == systemFeatures.sidetoneSlot)
            || (payload.count == 2 && [0xF2, 0xF6, 0xFA].contains(payload[0]) && systemFeatures.queryPayloads.contains(payload)) {
            systemReads[payload] = SystemRead()
        }
        if protocolInformation?.generation == .v2, type == 0x0C, payload.count == 2, payload[0] == 0x22,
           SonyBatteries.queryTypes(supportedFunctions: supportedFunctions).contains(payload[1]) {
            guard batteryReads[payload] == nil else { return }
            batteryReads[payload] = BatteryRead()
        }
        if type == 0x0E, voiceGuidance.queryPayloads.contains(payload) {
            guard voiceGuidanceReads[payload] == nil else { return }
            voiceGuidanceReads[payload] = SystemRead()
        }
        if let setting = powerQuerySetting(payload, type: type) {
            let key = [type] + payload
            guard powerReads[key] == nil, powerFeatures.queryPayloads(frameType: type).contains(payload) else { return }
            powerReads[key] = PowerRead(features: powerFeatures, setting: setting)
        }
        if type == 0x0C, playback.queryPayloads.contains(payload) {
            if playbackReads[payload] != nil {
                playbackReads[payload]?.refreshRequested = true
                return
            }
            guard queuedPlaybackQueries.insert(payload).inserted else { return }
        }
        if type == 0x0C, payload.count == 2, payload[0] == 0xD6, payload[1] == systemFeatures.multipointSlot {
            guard multipointQueuedReadSlot != payload[1] else { return }
            guard multipointReadbacks.isEmpty || multipointTransition?.phase == .queuedReadback else { return }
            multipointQueuedReadSlot = payload[1]
        }
        if type == 0x0E, payload == [0x36, 0x02] {
            guard inventoryRead == nil else { return }
            let request = deviceActionTransition?.phase == .queuedReadback ? deviceActionTransition?.requestID
                : sourceTransition?.phase == .queuedReadback ? sourceTransition?.requestID : nil
            inventoryRead = InventoryRead(requestID: request)
        }
        if type == 0x0C, payload == equalizer.parameterQueryPayload {
            if let equalizerRead {
                if equalizerRead.timedOut, settingRequests[.equalizerReadback] != nil { failEqualizerReadback() }
                return
            }
            let setting: Setting? = settingRequests[.equalizerReadback] != nil ? .equalizerReadback
                : settingRequests[.equalizer] != nil ? .equalizer : nil
            equalizerRead = EqualizerRead(setting: setting, requestID: setting.flatMap { settingRequests[$0] })
        }
        if let frame = commandQueue.enqueue(payload: payload, type: type) { transmit(frame) }
    }

    private func transmit(_ frame: SonyFrame) {
        if discoveryReads[[frame.type] + frame.payload]?.resolved == true {
            if let next = commandQueue.discardUnsentPending() { transmit(next) }
            return
        }
        if frame.type == 0x0C, frame.payload.first == 0x66, noiseControlRead?.timedOut == true {
            queuedNoiseControlRead = false
            if let next = commandQueue.discardUnsentPending() { transmit(next) }
            return
        }
        if frame.type == 0x0C, frame.payload.first == 0xA8, playbackVolumeSetting(frame.payload) == .playbackVolume,
           queuedMusicVolumeIsCurrent?() == false {
            discardQueuedMusicVolume()
            return
        }
        if frame.type == 0x0E, frame.payload.count >= 3, frame.payload[0] == 0x48,
           [0x01, 0x20].contains(frame.payload[1]) {
            let setting: Setting = frame.payload[1] == 1 ? .voiceGuidance : .voiceGuidanceVolume
            let enabled = voiceGuidance.generation == .v1 ? frame.payload.last == 1 : frame.payload[2] == 0
            let expected = setting == .voiceGuidance ? voiceGuidance.setEnabledPayload(enabled)
                : voiceGuidance.setVolumePayload(Int(Int8(bitPattern: frame.payload[2])))
            guard systemControlContextIsAvailable, unconfirmedChanges[setting] == nil,
                  pendingChanges[setting] == settingValue(frame.payload, setting: setting), expected == frame.payload else {
                discardUnsentSetting(setting, error: String(localized: "Voice guidance settings changed before the change could be sent."))
                return
            }
        }
        if protocolInformation?.generation == .v2, frame.type == 0x0C, frame.payload.count == 3,
           frame.payload.prefix(2) == [0xF8, 0x04] {
            guard voiceAssistantIsAvailable, unconfirmedChanges[.voiceAssistant] == nil,
                  pendingChanges[.voiceAssistant] == settingValue(frame.payload, setting: .voiceAssistant),
                  systemFeatures.voiceAssistant?.setPayload(SonyVoiceAssistantOption(rawValue: frame.payload[2])) == frame.payload else {
                discardUnsentSetting(.voiceAssistant, error: String(localized: "Voice assistant settings changed before the change could be sent."))
                return
            }
        }
        if frame.type == 0x0C, frame.payload.count == 4, frame.payload[0] == 0xD8,
           pendingChanges[.sidetone] == Array(frame.payload.dropFirst()) || frame.payload[1] == systemFeatures.sidetoneSlot {
            guard sidetoneIsAvailable, unconfirmedChanges[.sidetone] == nil,
                  pendingChanges[.sidetone] == settingValue(frame.payload, setting: .sidetone),
                  systemFeatures.sidetoneSetPayload(enabled: frame.payload[3] == 0) == frame.payload else {
                discardUnsentSetting(.sidetone, error: String(localized: "Sidetone controls changed before the change could be sent."))
                return
            }
        }
        if frame.type == 0x0C, frame.payload.count >= 2, let state = automaticPowerOff,
           frame.payload[1] == state.inquiryType, frame.payload[0] == (state.generation == .v1 ? 0xF8 : 0x28) {
            guard automaticPowerOffIsAvailable, unconfirmedChanges[.automaticPowerOff] == nil,
                  pendingChanges[.automaticPowerOff] == settingValue(frame.payload, setting: .automaticPowerOff),
                  state.acceptsSetPayload(frame.payload) else {
                discardUnsentSetting(.automaticPowerOff, error: String(localized: "Automatic power-off settings changed before the change could be sent."))
                return
            }
        }
        if frame.type == 0x0C, frame.payload.count >= 3, frame.payload[0] == 0xF8,
           let feature = systemFeature(inquiry: frame.payload[1]) {
            let enabled = protocolInformation?.generation == .v1 ? frame.payload.last == 1 : frame.payload[2] == 0
            guard systemFeatureIsAvailable(feature),
                  systemFeaturePayload(feature, enabled: enabled) == frame.payload,
                  pendingChanges[.system(feature)] == settingValue(frame.payload, setting: .system(feature)),
                  unconfirmedChanges[.system(feature)] == nil,
                  feature != .speakToChat || (pendingChanges[.speakToChatOptions] == nil && unconfirmedChanges[.speakToChatOptions] == nil) else {
                discardUnsentSetting(.system(feature), error: String(localized: "System settings changed before the command could be sent."))
                return
            }
        }
        if frame.type == 0x0C, frame.payload.count >= 3,
           frame.payload[1] == touchAssignments.inquiryType, frame.payload[0] == 0xF8 || frame.payload[0] == 0xFC {
            let setting: Setting = frame.payload[0] == 0xF8 ? .touchAssignments : .touchCustomActions
            guard systemControlContextIsAvailable, let change = queuedTouchChange,
                  unconfirmedChanges[.touchAssignments] == nil, unconfirmedChanges[.touchCustomActions] == nil else {
                discardUnsentSetting(setting, error: String(localized: "Touch controls changed before the command could be sent."))
                return
            }
            let expected: [UInt8]?
            if frame.payload[0] == 0xF8 {
                if touchAssignments.selectedPresets == change.selection,
                   let index = touchAssignments.keys?.firstIndex(where: { $0.key == change.key }),
                   frame.payload.count > index + 3 {
                    expected = touchAssignments.setPayload(key: change.key, preset: frame.payload[index + 3])
                } else {
                    expected = nil
                }
            } else {
                expected = frame.payload.count == 7 && touchAssignments.selectedPreset(key: change.key) == frame.payload[3]
                    && Set(touchAssignments.keysUsingPreset(frame.payload[3]).map(\.key)) == change.sharedKeys
                    ? touchAssignments.setActionPayload(key: change.key, action: frame.payload[5], function: frame.payload[6]) : nil
            }
            guard expected == frame.payload, pendingChanges[setting] == settingValue(frame.payload, setting: setting) else {
                discardUnsentSetting(setting, error: String(localized: "Touch controls changed before the command could be sent."))
                return
            }
        }
        if protocolInformation?.generation == .v1, frame.type == 0x0C, frame.payload.first == 0x48 {
            guard frame.payload.count == 3, let kind = SonyLegacySoundEffect.Kind(rawValue: frame.payload[1]) else {
                fail(String(localized: "Sound effects became unavailable before the change could be sent."))
                return
            }
            guard legacySoundEffect(kind).acceptsSetPayload(frame.payload) else {
                discardUnsentSetting(.legacySoundEffect(kind), error: String(localized: "Sound effects became unavailable before the change could be sent."))
                return
            }
        }
        if frame.type == 0x0C, frame.payload.first == 0x84 {
            guard let transition = legacyOptimizerTransition, transition.session == controlSession, isReady,
                  protocolInformation?.generation == .v1, legacyOptimizer.isSupported,
                  frame.payload == transition.expectedPayload,
                  frame.payload != SonyLegacyOptimizer.startPayload || legacyOptimizer.canStart else {
                fail(String(localized: "NC Optimizer changed before the command could be sent."))
                return
            }
        }
        if protocolInformation?.generation == .v1, frame.payload.prefix(2) == [0xE8, 0x02],
           legacyControls?.dsee.acceptsSetPayload(frame.payload) != true {
            discardUnsentSetting(.dsee, error: String(localized: "DSEE became unavailable before the change could be sent."))
            return
        }
        if frame.type == 0x0C, frame.payload.first == 0x68 {
            guard noiseControlUnavailableReason == nil,
                  noiseControl == nil || noiseControl?.state == noiseControlWriteState,
                  let mode = decodedNoiseControlMode(frame.payload), availableNoiseModes.contains(mode) else {
                fail(String(localized: "Noise controls changed before the command could be sent."))
                return
            }
        }
        if frame.type == 0x0C, frame.payload.first == 0x58,
           !equalizer.acceptsSetPayload(frame.payload) {
            fail(String(localized: "Equalizer settings became unavailable before the command could be sent."))
            return
        }
        if frame.type == 0x0C, frame.payload.prefix(2) == [0xF4, 0x10] {
            guard let transition = headGesturePracticeTransition, transition.session == controlSession,
                  frame.payload == transition.expectedPayload, isReady,
                  frame.payload != SonyHeadGesturePractice.enterPayload
                    || (headGesturePractice.available == true && headGesturePractice.mode != .in
                        && systemFeatures[.headGestures]?.available != false) else {
                fail(String(localized: "Head-gesture practice changed before the command could be sent."))
                return
            }
        }
        if protocolInformation?.generation == .v2, frame.type == 0x0C, frame.payload.count >= 2, frame.payload[1] == 0x06,
           frame.payload[0] == 0xF4 || frame.payload[0] == 0xF8 {
            guard let transition = earTipFitTransition, transition.session == controlSession,
                  frame.payload == transition.expectedPayload, isReady,
                  earTipFit.status?.mode != .in || earTipFit.status?.count == 1 else {
                fail(String(localized: "The fit-test state changed before the command could be sent."))
                return
            }
            if frame.payload == SonyEarTipFit.startPayload(series: transition.series) {
                guard earTipFit.status?.available == true, earTipFit.status?.mode == .in,
                      earTipFit.status?.result == .noError else {
                    fail(String(localized: "The fit test became unavailable before it could start."))
                    return
                }
            }
        }
        if frame.type == 0x0C, frame.payload == Self.powerOffPayload {
            guard isReady, supportedFunctions.contains(0x23), powerOffState == .sending,
                  powerOffRequestSession == controlSession else {
                fail(String(localized: "The headphone connection changed before the power-off command could be sent."))
                return
            }
        }
        if frame.type == 0x0C, frame.payload.first == 0xA4 || frame.payload.first == 0xA8 {
            let isAction = frame.payload.first == 0xA4
            let expected = isAction ? pendingPlaybackCommand.flatMap { playback.commandPayload($0) }
                : frame.payload.last.flatMap {
                    playbackVolumeSetting(frame.payload) == .callVolume ? playback.callVolumePayload(Int($0)) : playback.volumePayload(Int($0))
                }
            let source = isAction ? queuedPlaybackSource : queuedVolumeSource
            guard connectionTransition?.isFinished != false, multipointTransition?.isFinished != false,
                  sourceTransition?.isFinished != false, deviceActionTransition?.isFinished != false,
                  !multipoint.inventoryIsStale, expected == frame.payload,
                  source == multipoint.selectedSource?.address else {
                fail(String(localized: "Playback controls changed while waiting. Reconnect the headphones and try again."))
                return
            }
        }
        if frame.payload.first == 0x28, frame.payload.count >= 3 {
            if (frame.type == 0x0C && frame.payload[1] == 0x0C) || (frame.type == 0x0E && frame.payload[1] == 0x01) {
                guard systemControlContextIsAvailable, unconfirmedChanges[.batteryCare] == nil,
                      pendingChanges[.batteryCare] == settingValue(frame.payload, setting: .batteryCare),
                      powerFeatures.batteryCare?.frameType == frame.type,
                      powerFeatures.batteryCare?.setPayload(enabled: frame.payload[2] == 0) == frame.payload else {
                    discardUnsentSetting(.batteryCare, error: String(localized: "Battery Care became unavailable before the change could be sent."))
                    return
                }
            } else if frame.type == 0x0C, frame.payload[1] == 0x0B, frame.payload.count == 4 {
                let setting: Setting = frame.payload[3] == 1 ? .powerSaveEffect : .autoPowerSave
                let other: Setting = setting == .powerSaveEffect ? .autoPowerSave : .powerSaveEffect
                let expected = frame.payload[3] == 1 ? powerFeatures.autoPowerSave?.cancelEffectPayload
                    : powerFeatures.autoPowerSave?.setPayload(enabled: frame.payload[2] == 0)
                guard systemControlContextIsAvailable,
                      unconfirmedChanges[setting] == nil, unconfirmedChanges[other] == nil,
                      pendingChanges[other] == nil,
                      pendingChanges[setting] == settingValue(frame.payload, setting: setting),
                      expected == frame.payload else {
                    discardUnsentSetting(setting, error: String(localized: "Power-saving settings changed before the command could be sent."))
                    return
                }
            }
        }
        if frame.type == 0x0C, frame.payload.count == 4, frame.payload[0...1] == [0xFC, 0x0C] {
            guard systemFeatureIsAvailable(.speakToChat),
                  pendingChanges[.system(.speakToChat)] == nil, unconfirmedChanges[.system(.speakToChat)] == nil,
                  unconfirmedChanges[.speakToChatOptions] == nil,
                  pendingChanges[.speakToChatOptions] == settingValue(frame.payload, setting: .speakToChatOptions),
                  let options = systemFeatures.speakToChatOptions,
                  let current = options.sensitivity, let delay = options.delay,
                  options.setPayload(sensitivity: current, delay: delay) != nil,
                  options == queuedSpeakToChatOptions || [current.rawValue, delay.rawValue] == Array(frame.payload[2...]) else {
                discardUnsentSetting(.speakToChatOptions, error: String(localized: "Speak-to-Chat settings changed. Try again."))
                return
            }
            queuedSpeakToChatOptions = nil
        }
        if frame.type == 0x0C, frame.payload == multipointTransition?.expectedPayload,
           multipointTransition?.validateForTransmission(model: systemFeatures, session: controlSession) == false {
            fail(multipointTransition?.failureMessage ?? String(localized: "Device connection controls became unavailable."))
            return
        }
        if frame.type == 0x0E, frame.payload == sourceTransition?.expectedPayload,
           sourceTransition?.validateForTransmission(model: multipoint, session: controlSession) == false {
            if frame.payload.first == 0x38 || frame.payload.first == 0x3C {
                advanceSourceTransition()
                if let next = commandQueue.discardUnsentPending() { transmit(next) }
            } else {
                fail(sourceTransition?.failureMessage ?? String(localized: "Audio source controls became unavailable."))
            }
            return
        }
        if frame.type == 0x0E, frame.payload == deviceActionTransition?.expectedPayload,
           deviceActionTransition?.validateForTransmission(model: multipoint, session: controlSession) == false {
            fail(deviceActionTransition?.failureMessage ?? String(localized: "Device connection controls became unavailable."))
            return
        }
        if frame.type == 0x0C, let transition = connectionTransition,
           transition.phase == .queued, frame.payload == transition.requestPayload {
            let issue = protocolInformation?.generation != transition.generation
                || (transition.generation == .v1 && connectionMode != transition.originalMode)
                ? String(localized: "The connection preference changed before the command could be sent.")
                : connectionModePrerequisiteIssue(transition.targetMode)
            if let issue {
                connectionModeError = issue
                fail(issue)
                return
            }
        }
        let identifier = UUID()
        let session = controlSession
        let playbackGeneration = playbackSourceGeneration
        transmissionID = identifier
        let volumeRequest = frame.type == 0x0C && frame.payload.first == 0xA8 && playbackVolumeSetting(frame.payload) == .playbackVolume
            ? settingRequests[.playbackVolume] : nil
        let volumeIsCurrent: (() -> Bool)? = volumeRequest.map { requestID in
            { [weak self] in
                guard let self, self.controlSession == session, self.transmissionID == identifier,
                      self.playbackSourceGeneration == playbackGeneration,
                      self.settingRequests[.playbackVolume] == requestID else { return false }
                return self.queuedMusicVolumeIsCurrent?() != false
            }
        }
        let accepted = write(frame, isCurrent: volumeIsCurrent, onCancelled: { [weak self] in
            guard let self, self.controlSession == session, self.transmissionID == identifier else { return }
            self.transmissionID = nil
            self.discardQueuedMusicVolume()
        }, completion: { [weak self] in
            guard let self, self.controlSession == session, self.transmissionID == identifier else { return }
            self.transmittedFrame = frame
            self.beginDiscoveryRead(frame.payload, type: frame.type)
            if frame.type == 0x0C, frame.payload == [0x10, 0x04] {
                self.bluetoothLEIdentityReadTransmitted = true
            }
            if frame.type == 0x0C, frame.payload == [0x06, 0x00],
               self.protocolInformation?.generation == .v2, self.stage == .supportFunctions {
                self.supportFunctionsReadTransmitted = true
            }
            if frame.type == 0x0C, self.firmwareUpdateQueries[frame.payload] == false {
                self.firmwareUpdateQueries[frame.payload] = true
            }
            if frame.type == 0x0E {
                self.beginVoiceGuidanceRead(frame.payload)
                if frame.payload.count >= 2, frame.payload[0] == 0x48 {
                    let query: [UInt8] = frame.payload[1] == 1 ? self.voiceGuidance.parameterQueryPayload : [0x46, frame.payload[1]]
                    if self.voiceGuidanceReads[query]?.transmitted == true { self.voiceGuidanceReads[query]?.isObsolete = true }
                }
            }
            self.beginPowerRead(frame.payload, type: frame.type)
            if frame.payload.count >= 2, frame.payload[0] == 0x28 {
                let key: [UInt8] = [frame.type, 0x26, frame.payload[1]]
                if self.powerReads[key]?.transmitted == true { self.powerReads[key]?.isObsolete = true }
            }
            if frame.type == 0x0C {
                self.beginBatteryRead(frame.payload)
                self.beginSystemRead(frame.payload)
                if frame.payload.count >= 2, [0x28, 0xD8, 0xE8, 0xF8, 0xFC].contains(frame.payload[0]) {
                    let query: [UInt8] = [frame.payload[0] - 2, frame.payload[1]]
                    if self.systemReadSetting(query) != nil, self.systemReads[query]?.transmitted == true {
                        self.systemReads[query]?.isObsolete = true
                    }
                }
            }
            if frame.type == 0x0C, self.noiseMetadataReads[frame.payload] == false {
                self.noiseMetadataReads[frame.payload] = true
                if frame.payload.first == 0x62 { self.noiseAvailabilityReadObsolete = false }
            }
            if frame.type == 0x0C, self.noiseControl != nil || self.legacyControls != nil, frame.payload.first == 0x68 {
                self.noiseControlRead?.isObsolete = true
            }
            if self.protocolInformation?.generation == .v1, self.queuedLegacyReads.remove(frame.payload) != nil {
                self.legacyReads.insert(frame.payload)
                if frame.payload == [0x04, 0x02] || self.legacyControls?.batteryQueries.contains(frame.payload) == true
                    || (self.equalizer.queryPayloads.contains(frame.payload) && frame.payload != self.equalizer.parameterQueryPayload) {
                    self.beginLegacyOptionalReadTimeout(frame.payload)
                }
                if let kind = self.legacySoundEffectQueryKind(frame.payload) {
                    self.beginLegacySoundEffectRead(frame.payload, kind: kind)
                }
                if frame.payload == [0x62, 0x02] { self.noiseAvailabilityReadObsolete = false }
                if frame.payload == [0xE2, 0x02] { self.legacyDSEEAvailabilityReadObsolete = false }
                if frame.payload == [0xE6, 0x02] {
                    self.legacyDSEERead = LegacySettingRead(
                        requestID: self.settingTimeouts[.dsee] != nil ? self.settingRequests[.dsee] : nil,
                        resolvesUnconfirmed: self.unconfirmedChanges[.dsee] != nil)
                }
                if frame.payload.count == 2, [0xE0, 0xE2, 0xE6].contains(frame.payload[0]), frame.payload[1] == 0x02 {
                    self.beginLegacyDSEEReadTimeout(frame.payload)
                }
            }
            if self.protocolInformation?.generation == .v1, frame.type == 0x0C, frame.payload.prefix(2) == [0xE8, 0x02] {
                self.legacyDSEERead?.isObsolete = true
            }
            if self.protocolInformation?.generation == .v1, frame.type == 0x0C,
               frame.payload.count == 3, frame.payload[0] == 0x48 {
                self.legacySoundEffectReads[[0x46, frame.payload[1]]]?.isObsolete = true
            }
            if frame.type == 0x0C {
                self.earTipFitTransition?.transmitted(frame.payload, session: session)
                self.headGesturePracticeTransition?.transmitted(frame.payload, session: session)
                if frame.payload.count >= 2,
                   (self.earTipFitTransition != nil && [0x06, 0x07].contains(frame.payload[1]))
                    || (self.headGesturePracticeTransition != nil && frame.payload[1] == 0x10) {
                    let bytes = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    Self.logger.notice("Headphone test TX; session=\(session) sequence=\(frame.sequence) payload=\(bytes, privacy: .private)")
                }
            }
            if frame.type == 0x0C, frame.payload[0] == 0xA8, let query = self.playback.queryPayload(for: frame.payload) {
                self.playbackReads[query]?.isObsolete = true
            }
            if frame.type == 0x0C, self.playback.queryPayloads.contains(frame.payload) {
                let query = frame.payload
                let setting = self.playbackVolumeSetting(query)
                let read = PlaybackRead(sourceGeneration: playbackGeneration,
                    requestID: setting.flatMap { self.settingTimeouts[$0] != nil ? self.settingRequests[$0] : nil },
                    resolvesUnconfirmed: setting.map { self.unconfirmedChanges[$0] != nil } ?? false)
                self.queuedPlaybackQueries.remove(query)
                self.playbackReads[query] = read
                let timeout = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        guard let self, self.controlSession == session, self.playbackReads[query]?.id == read.id else { return }
                        self.playbackReads[query]?.timedOut = true
                        self.playbackFreshQueries.remove(query)
                        self.playbackReadTimeouts[query] = nil
                        self.playbackReadError = String(localized: "Playback information was not received. Reconnect the headphones to try again.")
                        self.verifyConnectionPreferenceIfNeeded()
                    }
                }
                self.playbackReadTimeouts[query] = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
            }
            if self.connectionTransition?.isFinished == false {
                let payload = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                Self.logger.notice("Connection change TX; type=\(frame.type, format: .hex) sequence=\(frame.sequence) session=\(session) payload=\(payload, privacy: .private)")
            }
            self.scheduleAcknowledgmentTimeout(frame, identifier: identifier, session: session, allowRetry: true)
            if frame.type == 0x0E, frame.payload == SonySoundPressure.levelQueryPayload { self.beginSoundPressureRead() }
            if frame.type == 0x0E, frame.payload == SonyWearingStatus.queryPayload { self.beginWearingStatusRead() }
            if frame.type == 0x0C, frame.payload.count == 2, frame.payload[0] == 0x66 {
                self.queuedNoiseControlRead = false
                if self.noiseControlRead?.timedOut != true {
                    self.noiseControlRead = NoiseControlRead(asmType: frame.payload[1],
                        requestID: self.settingTimeouts[.noiseControl] != nil ? self.settingRequests[.noiseControl] : nil,
                        resolvesUnconfirmed: self.unconfirmedChanges[.noiseControl] != nil)
                }
            }
            if frame.type == 0x0C, self.noiseControl != nil || self.legacyControls != nil, frame.payload.count == 2,
               [0x60, 0x62, 0x66].contains(frame.payload[0]), frame.payload[1] == self.asmType,
               self.noiseControlRead?.timedOut != true {
                self.beginNoiseReadTimeout(frame.payload)
            }
            if frame.type == 0x0C {
                self.legacyOptimizerTransition?.transmitted(frame.payload, session: self.controlSession)
                self.advanceLegacyOptimizer()
            }
            self.beginSettingConfirmation(frame)
            if frame.type == 0x0C, frame.payload == self.equalizer.parameterQueryPayload { self.beginEqualizerRead() }
            self.beginConnectionConfirmation(frame)
            self.beginSourceConfirmation(frame)
            self.beginDeviceActionConfirmation(frame)
            self.beginMultipointConfirmation(frame)
            #if DEBUG
            if self.isSimulated, self.simulatesSettingReplies {
                if frame.type == 0x0E, self.voiceGuidanceReads[frame.payload]?.transmitted == true {
                    let inquiry = frame.payload[1]
                    switch frame.payload[0] {
                    case 0x40:
                        if let languages = self.voiceGuidance.supportedLanguages {
                            let supported: UInt8 = self.voiceGuidance.supportsOnOffSwitch.map { $0 ? 1 : 0 } ?? 0xFF
                            if self.voiceGuidance.generation == .v1 {
                                self.dispatch([0x41, inquiry, supported, 1, UInt8(languages.count)] + languages, type: frame.type)
                            } else {
                                self.dispatch([0x41, inquiry, 0, 0, 0, 0, supported, UInt8(languages.count)] + languages, type: frame.type)
                            }
                        }
                    case 0x42:
                        self.dispatch([0x43, inquiry, self.voiceGuidance.generation == .v1 ? 1 : 0,
                            self.voiceGuidance.available.map { $0 ? 0 : 1 } ?? 0xFF], type: frame.type)
                    case 0x46:
                        let setting: Setting = inquiry == 1 ? .voiceGuidance : .voiceGuidanceVolume
                        let current = setting == .voiceGuidance ? self.voiceGuidance.enabled.map { $0 ? UInt8(0) : 1 }
                            : self.voiceGuidance.volume.map { UInt8(bitPattern: Int8($0)) }
                        let requested = self.voiceGuidanceReads[frame.payload]?.requestID == self.settingRequests[setting]
                            ? self.pendingChanges[setting]?.first : nil
                        let value = requested ?? current ?? (inquiry == 1 ? 0xFF : 3)
                        if self.voiceGuidance.generation == .v1 {
                            self.dispatch([0x47, inquiry, 1, value <= 1 ? 1 - value : value], type: frame.type)
                        } else {
                            let language: [UInt8] = setting == .voiceGuidance ? [self.voiceGuidance.currentLanguage ?? 0xFF] : []
                            self.dispatch([0x47, inquiry, value] + language, type: frame.type)
                        }
                    default: break
                    }
                }
                if frame.type == 0x0C, self.batteryReads[frame.payload]?.transmitted == true {
                    let readings: [BatteryReading?]
                    switch frame.payload[1] {
                    case 0x00, 0x08: readings = [self.batteries.single]
                    case 0x01, 0x09: readings = [self.batteries.left, self.batteries.right]
                    default: readings = [self.batteries.caseBattery]
                    }
                    let values: [UInt8] = readings.flatMap { [$0.map { UInt8($0.level) } ?? 0xFF, $0.map { $0.isCharging ? 1 : 0 } ?? 0xFF] }
                    let threshold: [UInt8] = frame.payload[1] == 0x08 ? [0] : []
                    self.dispatch([0x23, frame.payload[1]] + values + threshold, type: 0x0C)
                }
                if frame.payload.count == 2, let state = self.powerFeatures.batteryCare,
                   frame.type == state.frameType, frame.payload[1] == state.inquiryType {
                    switch frame.payload[0] {
                    case 0x20:
                        if let threshold = state.threshold { self.dispatch([0x21, state.inquiryType, threshold], type: frame.type) }
                    case 0x22:
                        let notice: [UInt8] = state.includesThreshold ? [state.noticeNecessary.map { $0 ? 0 : 1 } ?? 0xFF] : []
                        self.dispatch([0x23, state.inquiryType, state.available.map { $0 ? 0 : 1 } ?? 0xFF] + notice, type: frame.type)
                    case 0x26:
                        self.dispatch([0x27, state.inquiryType, state.enabled.map { $0 ? 0 : 1 } ?? 0xFF], type: frame.type)
                    default: break
                    }
                }
                if frame.type == 0x0C, frame.payload.count == 2, frame.payload[1] == 0x0B,
                   let state = self.powerFeatures.autoPowerSave {
                    if frame.payload[0] == 0x20, let threshold = state.threshold {
                        self.dispatch([0x21, 0x0B, threshold, UInt8(state.affectedFunctions.count)] + state.affectedFunctions
                            + [UInt8(state.affectedFunctions2.count)] + state.affectedFunctions2, type: frame.type)
                    } else if frame.payload[0] == 0x26 {
                        self.dispatch([0x27, 0x0B, state.enabled.map { $0 ? 0 : 1 } ?? 0xFF,
                            state.effectActive.map { $0 ? 0 : 1 } ?? 0xFF], type: frame.type)
                    }
                }
                if frame.type == 0x0C {
                    if self.protocolInformation?.generation == .v1, frame.payload.count == 2, frame.payload[1] == 1,
                       let quality = self.legacyControls?.connectionQuality, quality.isSupported {
                        switch frame.payload[0] {
                        case 0xE0:
                            if let type = quality.settingType { self.dispatch([0xE1, 1, type], type: 0x0C) }
                        case 0xE2:
                            self.dispatch([0xE3, 1, quality.available.map { $0 ? 0 : 1 } ?? 0xFF], type: 0x0C)
                        case 0xE6:
                            if let type = quality.parameterSettingType, let mode = self.simulatedMode.sonyValue {
                                self.dispatch([0xE7, 1, type, mode], type: 0x0C)
                            }
                        default: break
                        }
                    }
                    if self.protocolInformation?.generation == .v2, frame.payload.count == 2, frame.payload[1] == 0x04,
                       let state = self.systemFeatures.voiceAssistant {
                        switch frame.payload[0] {
                        case 0xF0:
                            if let keyType = state.keyType, let options = state.options {
                                self.dispatch([0xF1, 0x04, keyType, UInt8(options.count)] + options.map(\.rawValue), type: 0x0C)
                            }
                        case 0xF2:
                            self.dispatch([0xF3, 0x04, state.available.map { $0 ? 0 : 1 } ?? 0xFF], type: 0x0C)
                        case 0xF6:
                            if let current = state.current { self.dispatch([0xF7, 0x04, current.rawValue], type: 0x0C) }
                        default: break
                        }
                    }
                    if frame.payload.count == 2, let state = self.automaticPowerOff, frame.payload[1] == state.inquiryType {
                        let base: UInt8 = state.generation == .v1 ? 0xF0 : 0x20
                        switch frame.payload[0] {
                        case base:
                            if let options = state.options {
                                self.dispatch([base + 1, state.inquiryType, UInt8(options.count)] + options.map(\.rawValue), type: 0x0C)
                            }
                        case base + 2:
                            self.dispatch([base + 3, state.inquiryType, state.available.map { $0 ? 0 : 1 } ?? 0xFF], type: 0x0C)
                        case base + 6:
                            if let current = state.current, let last = state.last {
                                let type: [UInt8] = state.generation == .v1 ? [state.parameterType ?? 0xFF] : []
                                self.dispatch([base + 7, state.inquiryType] + type + [current.rawValue, last.rawValue], type: 0x0C)
                            }
                        default: break
                        }
                    }
                    if self.protocolInformation?.generation == .v1, frame.payload.count == 2, frame.payload[1] == 0x03,
                       let wearing = self.legacyControls?.wearingControl, wearing.isSupported {
                        switch frame.payload[0] {
                        case 0xF0:
                            if let type = wearing.settingType { self.dispatch([0xF1, 0x03, type], type: 0x0C) }
                        case 0xF2:
                            if let status = wearing.status { self.dispatch([0xF3, 0x03, status], type: 0x0C) }
                        case 0xF6:
                            if let type = wearing.parameterSettingType, let value = wearing.value {
                                self.dispatch([0xF7, 0x03, type, value], type: 0x0C)
                            }
                        default: break
                        }
                    }
                    if frame.payload.count == 2, frame.payload[1] == self.touchAssignments.inquiryType {
                        let command = frame.payload[0]
                        if command == 0xF2, let statuses = self.touchAssignments.statuses {
                            self.dispatch([0xF3, frame.payload[1], UInt8(statuses.count)] + statuses, type: 0x0C)
                        } else if command == 0xF6, let selected = self.touchAssignments.selectedPresets {
                            self.dispatch([0xF7, frame.payload[1], UInt8(selected.count)] + selected, type: 0x0C)
                        } else if command == 0xFA, let custom = self.touchAssignments.customizedActions {
                            let records = custom.flatMap { record in
                                [record.preset, UInt8(record.actions.count)] + record.actions.flatMap { [$0.action, $0.function] }
                            }
                            self.dispatch([0xFB, frame.payload[1], UInt8(custom.count)] + records, type: 0x0C)
                        }
                    }
                    if self.protocolInformation?.generation == .v2, frame.payload.count == 2, let feature = SonySystemFeature(rawValue: frame.payload[1]),
                       let state = self.systemFeatures[feature] {
                        let suffix: [UInt8] = feature == .speakToChat ? [1] : []
                        if frame.payload[0] == 0xF2 {
                            let status: UInt8 = state.isVisible == false ? 2 : state.available.map { $0 ? 0 : 1 } ?? 0xFF
                            self.dispatch([0xF3, feature.rawValue, status] + suffix, type: 0x0C)
                        } else if frame.payload[0] == 0xF6 {
                            self.dispatch([0xF7, feature.rawValue, state.enabled.map { $0 ? 0 : 1 } ?? 0xFF] + suffix, type: 0x0C)
                        } else if frame.payload[0] == 0xFA, feature == .speakToChat,
                                  let options = self.systemFeatures.speakToChatOptions,
                                  let sensitivity = options.sensitivity, let delay = options.delay {
                            self.dispatch([0xFB, 0x0C, sensitivity.rawValue, delay.rawValue], type: 0x0C)
                        }
                    }
                    if frame.payload.count == 2, frame.payload[1] == self.systemFeatures.sidetoneSlot,
                       let state = self.systemFeatures.sidetone {
                        if frame.payload[0] == 0xD2 {
                            self.dispatch([0xD3, frame.payload[1], state.available.map { $0 ? 0 : 1 } ?? 0xFF], type: 0x0C)
                        } else if frame.payload[0] == 0xD6 {
                            self.dispatch([0xD7, frame.payload[1], 0, state.enabled.map { $0 ? 0 : 1 } ?? 0xFF], type: 0x0C)
                        }
                    }
                    switch frame.payload {
                    case [0x80, 1]: self.dispatch([0x81, 1, 5, 1, 3, 1, 4], type: 0x0C)
                    case [0x82, 1]:
                        let phase: UInt8 = self.legacyOptimizerTransition?.phase == .cancelling ? 0
                            : self.legacyOptimizerTransition?.phase == .starting || self.legacyOptimizerTransition?.phase == .running ? 1 : 0
                        self.dispatch([0x83, 1, 0, phase], type: 0x0C)
                    case [0x86, 1]: self.dispatch([0x87, 1, 1, 1, 1, 10], type: 0x0C)
                    case SonyLegacyOptimizer.startPayload:
                        self.dispatch([0x85, 1, 0, 1], type: 0x0C)
                        self.simulateLegacyOptimizerResult()
                    case SonyLegacyOptimizer.cancelPayload: self.dispatch([0x85, 1, 0, 0], type: 0x0C)
                    case SonyHeadGesturePractice.queryPayload: self.dispatch([0xF3, 0x10, 0], type: 0x0C)
                    case SonyHeadGesturePractice.enterPayload:
                        self.dispatch([0xF5, 0x10, 0, 0], type: 0x0C)
                        self.simulateHeadGesturePracticeEvents()
                    case SonyHeadGesturePractice.exitPayload: self.dispatch([0xF5, 0x10, 1, 0], type: 0x0C)
                    case [0xF0, 0x06] where self.protocolInformation?.generation == .v2: self.dispatch([0xF1, 0x06, 5, 1, 1, 4, 0, 1, 2, 3], type: 0x0C)
                    case [0xF2, 0x06] where self.protocolInformation?.generation == .v2: self.dispatch([0xF3, 0x06, 0, 0, 1, 0], type: 0x0C)
                    case [0xF6, 0x06] where self.protocolInformation?.generation == .v2: self.dispatch([0xF7, 0x06, 0, 0, 1, 0, 1, 0xFF], type: 0x0C)
                    case [0xF6, 0x07]: self.dispatch([0xF7, 0x07, 1], type: 0x0C)
                    case [0xA0, 0x01]: self.dispatch(self.playback.generation == .v1 ? [0xA1, 0x01, 31, 1, 0] : [0xA1, 0x01, 31, 16], type: 0x0C)
                    case [0xA2, 0x01]:
                        self.dispatch([0xA3, 0x01, 0, self.playback.state?.rawValue ?? 2]
                            + (self.playback.generation == .v1 ? [] : [self.playback.musicCallStatus ?? 0]), type: 0x0C)
                    case [0xA6, 0x01, 0x20] where self.playback.generation == .v1:
                        self.dispatch([0xA7, 0x01, 0x20, UInt8(self.playback.volume ?? 12)], type: 0x0C)
                    case [0xA6, 0x01]: self.dispatch([0xA7, 0x01, 1, 0, 1, 0, 1, 0, 1, 0], type: 0x0C)
                    case [0xA6, 0x20]: self.dispatch([0xA7, 0x20, UInt8(self.playback.volume ?? 12)], type: 0x0C)
                    case [0xA6, 0x21]: self.dispatch([0xA7, 0x21, UInt8(self.playback.callVolume ?? 7)], type: 0x0C)
                    default: break
                    }
                }
                if self.protocolInformation?.generation == .v2, frame.type == 0x0C, frame.payload.count == 4, frame.payload.prefix(2) == [0xF4, 0x06] {
                    self.dispatch([0xF5, 0x06, 0, frame.payload[2], 1, 0], type: 0x0C)
                }
                if self.protocolInformation?.generation == .v2, frame.type == 0x0C, frame.payload.count == 6, frame.payload.prefix(2) == [0xF8, 0x06] {
                    self.dispatch([0xF9, 0x06, frame.payload[2] == 0 ? 1 : 0, 0, 1, 0, frame.payload[4], 0xFF], type: 0x0C)
                    if frame.payload[2] == 0 { self.simulateEarTipFitResult() }
                }
                if frame.type == 0x0E, frame.payload == SonySoundPressure.levelQueryPayload {
                    self.dispatch([0x5B, 0x03, 80, 0xFF], type: 0x0E)
                }
                self.receive(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
            }
            #endif
        })
        if !accepted, powerOffState == .sending, powerOffRequestSession == session {
            fail(String(localized: "The power-off command could not be sent. Its outcome is unknown."))
        }
    }

    private func scheduleAcknowledgmentTimeout(_ frame: SonyFrame, identifier: UUID, session: UInt64, allowRetry: Bool) {
        let isStartupRead = frame.type == 0x0C && (
            [[0x00, 0x00], [0x04, 0x01], [0x04, 0x03], [0x06, 0x00], [0x10, 0x04]].contains(frame.payload)
                || (stage == .noiseControl && frame.payload.count == 2
                    && [0x60, 0x62, 0x66].contains(frame.payload[0])
                    && [0x02, 0x15, 0x17, 0x19, 0x21, 0x22].contains(frame.payload[1])))
            || (frame.type == 0x0E && frame.payload == [0x06, 0x00])
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.transmissionID == identifier else { return }
                let payload = frame.payload.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
                if allowRetry, isStartupRead || (self.protocolInformation?.generation == .v2 && frame.type == 0x0C
                    && [[0xF6, 0x0F], [0xF6, 0x0C], [0x22, 0x05], [0xF2, 0x05], [0xA6, 0x01]].contains(frame.payload)) {
                    Self.logger.notice("Retrying unacknowledged read; sequence=\(frame.sequence) session=\(session) payload=\(payload, privacy: .private)")
                    _ = self.write(frame, completion: { [weak self] in
                        guard let self, self.transmissionID == identifier else { return }
                        self.scheduleAcknowledgmentTimeout(frame, identifier: identifier, session: session, allowRetry: false)
                    })
                    return
                }
                Self.logger.error("Command ACK timeout; type=\(frame.type, format: .hex) sequence=\(frame.sequence) session=\(session) length=\(frame.payload.count) payloadPrefix=\(payload, privacy: .private)")
                if frame.type == 0x0E, frame.payload == SonySoundPressure.levelQueryPayload {
                    self.soundPressureAutomaticRefreshSuspended = true
                }
                self.fail(frame.type == 0x0C && frame.payload == Self.powerOffPayload
                          ? String(localized: "The power-off command was not acknowledged. Its outcome is unknown.")
                          : String(localized: "Headphones did not acknowledge a command."))
            }
        }
        acknowledgmentTimeout?.cancel()
        acknowledgmentTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func discardQueuedMusicVolume() {
        let requestID = settingRequests[.playbackVolume]
        pendingChanges[.playbackVolume] = nil
        settingRequests[.playbackVolume] = nil
        queuedMusicVolumeIsCurrent = nil
        queuedVolumeSource = nil
        finishSettingIntent(.playbackVolume, requestID: requestID, error: CancellationError())
        if let next = commandQueue.discardUnsentPending() { transmit(next) }
    }

    private func discardUnsentSetting(_ setting: Setting, error: String) {
        let requestID = settingRequests[setting]
        pendingChanges[setting] = nil
        settingRequests[setting] = nil
        powerRequestIDs[setting] = nil
        settingErrors[setting] = error
        if setting == .touchAssignments || setting == .touchCustomActions { queuedTouchChange = nil }
        if setting == .speakToChatOptions { queuedSpeakToChatOptions = nil }
        finishSettingIntent(setting, requestID: requestID, error: HeadphoneControlError(message: error))
        if let next = commandQueue.discardUnsentPending() { transmit(next) }
    }

    private func write(_ frame: SonyFrame, isCurrent: (() -> Bool)? = nil, onCancelled: @escaping () -> Void = {},
                       onQueued: (() -> Void)? = nil, completion: @escaping () -> Void = {}) -> Bool {
        #if DEBUG
        if isSimulated, channel == nil {
            let completed = { [weak self] in
                guard isCurrent?() != false else { onCancelled(); return }
                self?.simulatedTransmittedFrames.append(frame)
                completion()
            }
            if defersSimulatedWrites {
                simulatedWriteCompletions.append(completed)
                onQueued?()
            } else {
                onQueued?()
                completed()
            }
            return true
        }
        #endif
        let data = SonyFrameCodec.encode(type: frame.type, sequence: frame.sequence, payload: frame.payload)
        if let bleTransport {
            guard bleTransport.write(data, isCurrent: isCurrent, onCancelled: onCancelled, onQueued: onQueued, completion: completion) else {
                fail(String(localized: "Could not send the command to the headphones. Try again."))
                return false
            }
            return true
        }
        guard isCurrent?() != false else { onCancelled(); return true }
        guard let channel, let channelIO else { return false }
        guard data.count <= Int(channel.getMTU()), classicWrites.count < 64 else {
            fail(String(localized: "Could not send to headphones (\(kIOReturnNoSpace))"))
            return false
        }
        nextClassicWriteID += 1
        let identifier = nextClassicWriteID
        let session = controlSession
        let buffer = NSMutableData(data: data)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.controlSession == session, self.classicWrites[identifier] != nil else { return }
            self.fail(String(localized: "Could not send to headphones (\(kIOReturnTimeout))"))
        }
        classicWrites[identifier] = ClassicWrite(data: buffer, channel: channel, session: session, waitsForResponse: frame.type != 0x01,
                                                timeout: timeout, completion: completion)
        channelIO.write(data, willSend: { [weak self] in
            guard let self, self.channel === channel, self.controlSession == session,
                  let write = self.classicWrites[identifier] else { return false }
            guard isCurrent?() != false else {
                self.classicWrites[identifier] = nil
                write.timeout.cancel()
                self.drainClassicIncomingData(channel, session: session)
                onCancelled()
                return false
            }
            self.classicWrites[identifier]?.hasStarted = true
            return true
        }) { [weak self] result in
            DispatchQueue.main.async {
                self?.classicChannelWriteComplete(channel, identifier: identifier, status: result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        onQueued?()
        return true
    }

    private func receiveClassic(_ data: Data) {
        if classicWrites.values.contains(where: { $0.session == controlSession && $0.waitsForResponse }) {
            guard classicIncomingDataLength + data.count <= SonyFrameStream.maximumFrameLength else {
                fail(String(localized: "Could not send to headphones (\(kIOReturnNoSpace))"))
                return
            }
            let receivedTransmissionID = transmittedFrame == commandQueue.pending || classicWrites.values.contains(where: {
                $0.session == controlSession && $0.waitsForResponse && $0.hasStarted
            }) ? transmissionID : nil
            classicIncomingData.append((data, receivedTransmissionID))
            classicIncomingDataLength += data.count
        } else {
            receive(data)
        }
    }

    private func receive(_ data: Data) {
        receive(data, transmissionID: transmittedFrame == commandQueue.pending ? transmissionID : nil)
    }

    private func receive(_ data: Data, transmissionID receivedTransmissionID: UUID?) {
        let session = controlSession
        for received in stream.append(data, transmissionID: receivedTransmissionID) {
            guard session == controlSession else { return }
            let frame = received.frame
            if frame.type == 0x01 {
                guard frame.payload.isEmpty, let sent = transmittedFrame,
                      received.transmissionID == transmissionID, sent == commandQueue.pending else { continue }
                let acknowledgment = commandQueue.handleAcknowledgment(sequence: frame.sequence)
                guard acknowledgment.accepted else { continue }
                if multipointTransition?.isFinished == false, sent.type == 0x0C,
                   sent.payload.count >= 2, [0xD8, 0xD6].contains(sent.payload[0]),
                   sent.payload[1] == systemFeatures.multipointSlot {
                    let setter = sent.payload[0] == 0xD8
                    let owned = multipointTransition?.commandAcknowledged(sent.payload, session: session) == true
                    if owned, multipointTransition?.phase == .awaitingResponse { updateMultipointTimeout() }
                    let enabled = setter ? sent.payload.last == 0 : multipointTransition?.targetEnabled == true
                    Self.logger.notice("Multipoint ACK; session=\(self.controlSession) setter=\(setter) slot=\(sent.payload[1]) target_enabled=\(enabled) setter_owned=\(owned) phase=\(self.multipointTransition?.diagnosticPhase ?? "none", privacy: .public)")
                }
                if sent.type == 0x0C, sent.payload.first == 0x98,
                   multipointTransition?.commandAcknowledged(sent.payload, session: session) == true,
                   multipointTransition?.phase == .awaitingResponse {
                    Self.logger.notice("Multipoint alert reply ACK; session=\(self.controlSession) message=\(sent.payload[2]) action=\(sent.payload[3])")
                    updateMultipointTimeout()
                }
                if connectionTransition?.isFinished == false {
                    let payload = sent.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    Self.logger.notice("Connection change ACK; type=\(sent.type, format: .hex) sentSequence=\(sent.sequence) ackSequence=\(frame.sequence) session=\(session) payload=\(payload, privacy: .private)")
                }
                acknowledgmentTimeout?.cancel()
                acknowledgmentTimeout = nil
                transmissionID = nil
                transmittedFrame = nil
                if sent.type == 0x0C, sent.payload == Self.powerOffPayload,
                   powerOffState == .sending, powerOffRequestSession == session {
                    powerOffState = .acknowledged
                }
                if sent.type == 0x0C, sent.payload == [0x94, protocolInformation?.generation == .v1 ? 0x01 : 0x00, 0x00] {
                    fixedAlertsEnabled = true
                    Self.logger.notice("Connection alerts enabled; sequence=\(sent.sequence) ackSequence=\(frame.sequence) session=\(session)")
                }
                let playbackAcknowledged = sent.type == 0x0C && sent.payload.first == 0xA4
                if playbackAcknowledged {
                    pendingPlaybackCommand = nil
                    queuedPlaybackSource = nil
                    #if DEBUG
                    if isSimulated, simulatesSettingReplies, sent.payload.last == 1 || sent.payload.last == 7 {
                        playback.update([0xA5, 0x01, 0x00, sent.payload.last == 7 ? 1 : 2, 0x00])
                    }
                    #endif
                }
                if let next = acknowledgment.nextFrame { transmit(next) }
                if playbackAcknowledged, isReady {
                    send([0xA2, 0x01])
                    send([0xA6, 0x01])
                }
                advanceEarTipFit()
                advanceHeadGesturePractice()
                advanceLegacyOptimizer()
                verifyConnectionPreferenceIfNeeded()
                continue
            }
            if frame.type == 0x0C || frame.type == 0x0E {
                let protocolReply = frame.type == 0x0C && SonyProtocolInfo(payload: frame.payload)?.generation == .v2
                let shouldDispatch = frame.sequence != lastReceivedSequence || protocolReply
                if shouldDispatch { lastReceivedSequence = frame.sequence }
                let firmwareIdentityReadOwned = frame.type != 0x0C || frame.payload.count < 2 || frame.payload[0] != 0x37
                    || firmwareUpdateQueries[[0x36, frame.payload[1]]] == true
                let waitsForAcknowledgment = frame.type == 0x0C && frame.payload.first == 0x49
                let received = { [weak self] in
                    guard let self, self.controlSession == session else { return }
                    if shouldDispatch, !frame.payload.isEmpty, firmwareIdentityReadOwned { self.dispatch(frame.payload, type: frame.type) }
                }
                pendingInboundAcknowledgments += 1
                guard write(SonyFrame(type: 0x01, sequence: 1 - frame.sequence, payload: []),
                            onQueued: waitsForAcknowledgment ? nil : received, completion: { [weak self] in
                    guard let self, self.controlSession == session else { return }
                    self.pendingInboundAcknowledgments -= 1
                    if waitsForAcknowledgment { received() }
                    self.verifyConnectionPreferenceIfNeeded()
                }) else { return }
            }
        }
    }

    private func powerQuerySetting(_ payload: [UInt8], type: UInt8) -> Setting? {
        guard payload.count == 2, [0x20, 0x22, 0x26].contains(payload[0]) else { return nil }
        if (type == 0x0C && payload[1] == 0x0C) || (type == 0x0E && payload[1] == 1) { return .batteryCare }
        return type == 0x0C && payload[1] == 0x0B && payload[0] != 0x22 ? .autoPowerSave : nil
    }

    private func powerReplyIsKnown(_ payload: [UInt8], type: UInt8, features: SonyPowerFeatures) -> Bool {
        if let state = features.batteryCare, state.frameType == type, payload[1] == state.inquiryType {
            switch payload[0] {
            case 0x21: return state.threshold != nil
            case 0x23, 0x25: return state.available != nil
            default: return state.enabled != nil
            }
        }
        guard let state = features.autoPowerSave, type == 0x0C, payload[1] == 0x0B else { return false }
        return payload[0] == 0x21 ? state.threshold != nil : state.enabled != nil && state.effectActive != nil
    }

    private func receiveVoiceGuidance(_ payload: [UInt8]) {
        let isLegacy = voiceGuidance.generation == .v1
        guard payload.count >= 2, [0x41, 0x43, 0x45, 0x47].contains(payload[0])
                || (isLegacy && payload[0] == 0x49) else { return }
        if isLegacy, payload[0] != 0x41, payload.count < 3 { return }
        let query: [UInt8]? = payload[0] == 0x45 || payload[0] == 0x49 ? nil
            : [payload[0] - 1, payload[1]] + (isLegacy && payload[0] != 0x41 ? [payload[2]]
                : payload[0] == 0x43 && payload[1] == 1 ? [0] : [])
        let read = query.flatMap { voiceGuidanceReads[$0] }
        var guidance = voiceGuidance
        let owned = query == nil || read?.transmitted == true
        let parsed = owned && guidance.update(payload)
        let bytes = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        Self.logger.notice("Voice guidance RX; session=\(self.controlSession) owned=\(owned) valid=\(parsed) payload=\(bytes, privacy: .private)")
        guard parsed else { return }
        let known: Bool
        switch payload[0] {
        case 0x41: known = guidance.supportsOnOffSwitch != nil && guidance.supportedLanguages != nil
        case 0x43, 0x45: known = guidance.available != nil
        default: known = payload[1] == 1 ? guidance.enabled != nil : guidance.volume != nil
        }
        let setting: Setting = payload[1] == 1 ? .voiceGuidance : .voiceGuidanceVolume
        if let query {
            voiceGuidanceReads.removeValue(forKey: query)?.timeout?.cancel()
        } else {
            let previousQuery: [UInt8] = payload[0] == 0x49 ? voiceGuidance.parameterQueryPayload
                : [0x42, payload[1]] + (isLegacy ? [payload[2]] : payload[1] == 1 ? [0] : [])
            if voiceGuidanceReads[previousQuery]?.transmitted == true { voiceGuidanceReads[previousQuery]?.isObsolete = true }
        }
        if let read, read.isObsolete || (payload[0] == 0x47 && unconfirmedChanges[setting] != nil
            && read.requestID == nil && !read.resolvesUnconfirmed) {
            if let query, voiceGuidance.queryPayloads.contains(query) { send(query, type: 0x0E) }
            return
        }
        if voiceGuidance != guidance { voiceGuidance = guidance }
        lastSyncDate = Date()
        if isLegacy, payload[0] == 0x41 {
            for query in voiceGuidance.queryPayloads { send(query, type: 0x0E) }
        }
        guard known, payload[0] == 0x47 || payload[0] == 0x49 else { return }
        let confirmsNotification = payload[0] == 0x49
            && (settingTimeouts[setting] != nil || unconfirmedChanges[setting] != nil)
        if confirmsNotification || (read?.requestID != nil && read?.requestID == settingRequests[setting]) {
            confirmSetting(setting, value: settingValue(payload, setting: setting))
        }
        if unconfirmedChanges[setting] != nil, confirmsNotification || read?.requestID != nil || read?.resolvesUnconfirmed == true {
            unconfirmedChanges[setting] = nil
            settingErrors[setting] = nil
        }
        if let query, pendingChanges[setting] != nil, read?.requestID != settingRequests[setting] { send(query, type: 0x0E) }
    }

    private func receivePowerSettings(_ payload: [UInt8], type: UInt8) -> Bool {
        guard payload.count >= 2, [0x21, 0x23, 0x25, 0x27, 0x29].contains(payload[0]) else { return false }
        let isNotification = payload[0] == 0x25 || payload[0] == 0x29
        let query: [UInt8] = [payload[0] - (isNotification ? 3 : 1), payload[1]]
        guard let feature = powerQuerySetting(query, type: type) else { return false }
        let key = [type] + query
        let read = isNotification ? nil : powerReads[key]
        if !isNotification, read?.transmitted != true { return true }
        if let read, read.isRetired || read.timedOut {
            var previous = read.features
            guard previous.update(payload, frameType: type), powerReplyIsKnown(payload, type: type, features: previous) else { return true }
            powerReads.removeValue(forKey: key)?.timeout?.cancel()
            if powerFeatures.queryPayloads(frameType: type).contains(query) { send(query, type: type) }
            return true
        }
        var features = powerFeatures
        guard features.update(payload, frameType: type) else { return true }
        let known = powerReplyIsKnown(payload, type: type, features: features)
        let isParameter = query[0] == 0x26
        let settings: [Setting] = feature == .batteryCare ? [.batteryCare] : [.autoPowerSave, .powerSaveEffect]
        if isNotification {
            if powerReads[key]?.transmitted == true { powerReads[key]?.isObsolete = true }
        } else if known {
            powerReads.removeValue(forKey: key)?.timeout?.cancel()
        }
        if let read, read.isObsolete || (isParameter && settings.contains(where: { unconfirmedChanges[$0] != nil })
            && read.requestID == nil && !read.resolvesUnconfirmed) {
            if known, isParameter, settings.contains(where: { pendingChanges[$0] != nil || unconfirmedChanges[$0] != nil }) {
                send(query, type: type)
            }
            return true
        }
        powerFeatures = features
        lastSyncDate = Date()
        guard known, isParameter else { return true }
        for setting in settings {
            if isNotification || (read?.requestID != nil && read?.setting == setting
                && read?.requestID == powerRequestIDs[setting]) {
                confirmSetting(setting, value: settingValue(payload, setting: setting))
            }
            if unconfirmedChanges[setting] != nil,
               isNotification || (read?.setting == setting && (read?.requestID != nil || read?.resolvesUnconfirmed == true)) {
                unconfirmedChanges[setting] = nil
                settingErrors[setting] = nil
                powerRequestIDs[setting] = nil
            }
        }
        if let read, settings.contains(where: { pendingChanges[$0] != nil && settingRequests[$0] != read.requestID }) {
            send(query, type: type)
        }
        return true
    }

    private func receivePlayback(_ payload: [UInt8]) -> Bool {
        var updatedPlayback = playback
        guard updatedPlayback.update(payload) else { return false }
        let isResponse = payload[0] == 0xA1 || payload[0] == 0xA3 || payload[0] == 0xA7
        let query = playback.queryPayload(for: payload)!
        var read: PlaybackRead?
        var isFreshResponse = false
        var needsReplacement = false
        defer {
            if needsReplacement, isReady, connectionTransition?.isFinished != false,
               multipointTransition?.isFinished != false { send(query) }
        }
        if isResponse {
            read = playbackReads.removeValue(forKey: query)
            if let read {
                playbackReadTimeouts.removeValue(forKey: query)?.cancel()
                if !playbackReads.values.contains(where: { $0.timedOut }) { playbackReadError = nil }
                needsReplacement = read.refreshRequested || read.isObsolete || read.sourceGeneration != playbackSourceGeneration
                guard read.sourceGeneration == playbackSourceGeneration, !read.isObsolete else { return true }
                isFreshResponse = !read.timedOut && !read.refreshRequested
                if isFreshResponse { playbackFreshQueries.insert(query) }
                else { playbackFreshQueries.remove(query) }
            } else if playback.generation == .v1 || playbackSourceGeneration > 0 {
                return true
            } else {
                playbackFreshQueries.remove(query)
            }
        } else {
            if playbackSourceGeneration > 0, !playbackFreshQueries.contains(query) { return true }
            playbackReads[query]?.isObsolete = true
        }
        playback = updatedPlayback
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        if payload[0] == 0xA7, query == playback.musicVolumeQueryPayload, isFreshResponse {
            musicVolumeReadbackID = UUID()
        }
        if payload[0] == 0xA3, isFreshResponse { musicStatusReadbackID = UUID() }
        #endif
        lastSyncDate = Date()
        if payload[0] == 0xA7 || payload[0] == 0xA9, let setting = playbackVolumeSetting(payload),
           queuedVolumeSource == multipoint.selectedSource?.address {
            let isCall = setting == .callVolume
            let confirmsRead = isFreshResponse && ((read?.requestID != nil && read?.requestID == settingRequests[setting])
                || (settingRequests[setting] == nil && (read?.requestID != nil || read?.resolvesUnconfirmed == true)))
            if payload[0] == 0xA9 || confirmsRead {
                let value = (isCall ? playback.callVolume : playback.volume).map { [UInt8($0)] }
                confirmSetting(setting, value: value)
                if confirmsRead, value != nil { unconfirmedChanges[setting] = nil }
            }
        }
        return true
    }

    private func dispatch(_ payload: [UInt8], type: UInt8) {
        if stage == .unsupported { return }
        if receiveFirmwareUpdateIdentity(payload, type: type) { return }
        if type == 0x0C, payload[0] == 0x05, payload.count >= 2, [0x01, 0x03].contains(payload[1]) {
            var information = deviceInformation
            if information.update(payload), consumeDiscoveryRead([0x04, payload[1]], type: type) {
                deviceInformation = information
            }
            return
        }
        if type == 0x0C, receivePlayback(payload) { return }
        if protocolInformation?.generation == .v1 {
            if type == 0x0E { receiveVoiceGuidance(payload) }
            else { receiveLegacyControls(payload, type: type) }
            return
        }
        if receivePowerSettings(payload, type: type) { return }
        if payload[0] == 0x07 {
            parseSupportFunctions(payload, type: type)
            return
        }
        if type == 0x0E {
            let previousSource = multipoint.selectedSource?.address
            let previousDeviceActionPhase = deviceActionTransition?.phase
            var receivedMultipoint = multipoint
            let updatedMultipoint = receivedMultipoint.update(payload)
            if multipoint != receivedMultipoint { multipoint = receivedMultipoint }
            if updatedMultipoint || (multipoint.supportsInventory && (payload.prefix(2) == [0x37, 0x02] || payload.prefix(2) == [0x39, 0x02])) {
                if updatedMultipoint { lastSyncDate = Date() }
                receiveMultipoint(payload)
                if previousSource != multipoint.selectedSource?.address {
                    invalidateSoundPressureReading()
                    playbackSourceGeneration += 1
                    playbackFreshQueries = []
                    playback = SonyPlayback(supportedFunctions: supportedFunctions)
                }
                if previousSource != multipoint.selectedSource?.address
                    || (previousDeviceActionPhase != .complete && deviceActionTransition?.phase == .complete) {
                    if isReady, connectionTransition?.isFinished != false, multipointTransition?.isFinished != false,
                       sourceTransition?.isFinished != false, deviceActionTransition?.isFinished != false {
                        for query in playback.queryPayloads { send(query) }
                    }
                }
                if updatedMultipoint, isReady, isDeviceConnected, !multipoint.inventoryIsStale,
                   sourceTransition?.isFinished != false, deviceActionTransition?.isFinished != false,
                   (payload.prefix(2) == [0x39, 0x02]
                    || (connectionTransition?.isFinished != false && multipointTransition?.isFinished != false)),
                   let source = multipoint.selectedSource, source.isConnected {
                    let changed = announcedAudioSourceAddress.map { $0 != source.address } ?? false
                    announcedAudioSourceAddress = source.address
                    if changed { audioSourceChanges.send(source) }
                }
                return
            }
            if receiveWearingStatus(payload) || receiveSoundPressure(payload) { return }
            receiveVoiceGuidance(payload)
            return
        }
        guard type == 0x0C else { return }
        if receiveEarTipFit(payload) || receiveHeadGesturePractice(payload) { return }
        var receivedEqualizer = equalizer
        if [0x51, 0x53, 0x55, 0x5B].contains(payload[0]), receivedEqualizer.update(payload) {
            if equalizer != receivedEqualizer { equalizer = receivedEqualizer }
            lastSyncDate = Date()
            return
        }
        if connectionTransition?.isFinished == false, payload.count >= 2,
           payload[0] == 0x99 || payload[0] == 0x49 || ((payload[0] == 0xE7 || payload[0] == 0xE9) && payload[1] == 0x05) {
            let value = payload.prefix(payload[0] == 0x49 ? 3 : payload.count).map { String(format: "%02X", $0) }.joined(separator: " ")
            Self.logger.notice("Connection change RX; session=\(self.controlSession) length=\(payload.count) payload=\(value, privacy: .private) outstandingReadbacks=\(self.modeReadbacks.count)")
        }
        if payload.count >= 2, payload[0] == 0x11, payload[1] == 0x04,
           supportedFunctions.contains(0x14), bluetoothLEIdentityReadTransmitted,
           let hash = SonyBLEIdentity.capabilityHash(from: payload) {
            bluetoothLEIdentityReadTransmitted = false
            if (usesBluetoothLE && expectedBLEIdentity?.matches(hash: hash, peripheralIdentifier: controlPeripheralID) != true)
                || (connectionTransition?.isFinished == false && transitionHash != nil && hash != transitionHash)
                || (multipointTransition?.isFinished == false && multipointConnection?.hash != nil && hash != multipointConnection?.hash) {
                let issue = String(localized: "The connected device did not match the selected headphones.")
                bluetoothLEDiagnosticError = nil
                bluetoothLEError = issue
                fail(issue)
                return
            }
            bluetoothLEHash = hash
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            let primaryDevice = [device, transitionDevice].compactMap { $0 }.first {
                Self.normalizedAddress($0.addressString ?? "") == address
            }
            #endif
            let savedPeripheralID = savedIdentity.flatMap { $0.classicAddress == address ? $0.peripheralIdentifier : nil }
            #if ACOUPLET_PUBLIC_APIS_ONLY
            let peripheralIdentifier = controlPeripheralID ?? savedPeripheralID
            #else
            let peripheralIdentifier = primaryDevice.flatMap(SonyBLEIdentity.classicPeripheralIdentifier) ?? controlPeripheralID ?? savedPeripheralID
            #endif
            if let identityDefaults, let identity = SonyBLEIdentity.VerifiedDevice(
                classicAddress: address, model: deviceModel, hash: hash,
                peripheralIdentifier: peripheralIdentifier
            ) {
                savedIdentity = identity
                SonyBLEIdentity.save(identity, in: identityDefaults)
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                if let primaryDevice, primaryDevice.isPaired(),
                   let identifier = SonyBLEIdentity.classicPeripheralIdentifier(for: primaryDevice) {
                    nativeAppearanceRefresh?.start(identity: identity, canonicalIdentifier: identifier)
                }
                #endif
            }
            if stage == .bleIdentity { beginControlSync() }
            return
        }
        if let alert = SonyConnectionAlert(payload: payload) {
            if alert.isMultipointChange || multipointTransition?.isFinished == false {
                Self.logger.notice("Multipoint alert; session=\(self.controlSession) format=\(alert.format.rawValue) message=\(alert.messageID) action=\(String(describing: alert.actionType), privacy: .public) phase=\(self.multipointTransition?.diagnosticPhase ?? "none", privacy: .public)")
            }
            lastConnectionAlert = alert
            lastSyncDate = Date()
            if multipointTransition?.receiveAlert(alert, session: controlSession) == true {
                multipointReadbacks = multipointReadbacks.map { ($0.slot, nil) }
                advanceMultipointTransition()
            }
            if connectionTransition?.receiveAlert(alert, session: controlSession) == true {
                Self.logger.notice("Connection change alert accepted; session=\(self.controlSession) message=\(alert.messageID, format: .hex)")
                modeReadbacks = Array(repeating: nil, count: modeReadbacks.count)
                updateConnectionModeTimeout()
            }
            return
        }
        if payload.count == 53, payload.prefix(2) == [0x41, 0x00], supportedFunctions.contains(0x40) {
            let addresses = stride(from: 2, to: 53, by: 17).compactMap {
                Self.bluetoothAddress(Array(payload[$0..<($0 + 17)]))
            }
            if addresses.count == 3 { controlAddresses = Set(addresses) }
            return
        }
        if handleMultipointDirective(payload) || handleConnectionDirective(payload) { return }
        var receivedAudioFeatures = audioFeatures
        if receivedAudioFeatures.update(payload) {
            let dseeQuery: [UInt8] = [0xE6, 0x01]
            let dseeRead = payload[0] == 0xE7 && payload[1] == 0x01 ? systemReads[dseeQuery] : nil
            if payload[0] == 0xE7, payload[1] == 0x01 {
                guard let dseeRead, dseeRead.transmitted else { return }
                let known = receivedAudioFeatures.dseeMode?.sonyValue != nil
                if known { systemReads.removeValue(forKey: dseeQuery)?.timeout?.cancel() }
                if dseeRead.timedOut || dseeRead.isObsolete
                    || (unconfirmedChanges[.dsee] != nil && dseeRead.requestID == nil && !dseeRead.resolvesUnconfirmed) {
                    if known { send(dseeQuery) }
                    return
                }
            } else if payload[0] == 0xE9, payload[1] == 0x01, systemReads[dseeQuery]?.transmitted == true {
                systemReads[dseeQuery]?.isObsolete = true
            }
            if audioFeatures.leftConnected != receivedAudioFeatures.leftConnected
                || audioFeatures.rightConnected != receivedAudioFeatures.rightConnected {
                invalidateWearingStatus()
            }
            if audioFeatures != receivedAudioFeatures { audioFeatures = receivedAudioFeatures }
            lastSyncDate = Date()
            if (payload[0] == 0x13 || payload[0] == 0x15), payload[1] == 0x01 {
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                nativeBatterySnapshot?.invalidateUnavailableBuds(leftConnected: audioFeatures.leftConnected,
                                                               rightConnected: audioFeatures.rightConnected)
                #endif
                lowBatteryReadings.removeAll {
                    ($0.part == .left && audioFeatures.leftConnected != true)
                        || ($0.part == .right && audioFeatures.rightConnected != true)
                }
                if audioFeatures.leftConnected != true || audioFeatures.rightConnected != true {
                    for query: [UInt8] in [[0x22, 0x01], [0x22, 0x09]] where batteryReads[query]?.transmitted == true {
                        batteryReads[query]?.isObsolete = true
                    }
                }
            }
            if (payload[0] == 0xE7 || payload[0] == 0xE9), payload[1] == 0x01 {
                let confirmsRead = (dseeRead?.requestID != nil && dseeRead?.requestID == settingRequests[.dsee])
                    || (settingRequests[.dsee] == nil && (dseeRead?.requestID != nil || dseeRead?.resolvesUnconfirmed == true))
                if let value = audioFeatures.dseeMode?.sonyValue, payload[0] == 0xE9 || confirmsRead {
                    confirmSetting(.dsee, value: [value])
                    unconfirmedChanges[.dsee] = nil
                }
                if payload[0] == 0xE7, pendingChanges[.dsee] != nil, dseeRead?.requestID != settingRequests[.dsee] {
                    send(dseeQuery)
                }
            }
            if payload[0] == 0xE7, payload[1] == 0x05, !modeReadbacks.isEmpty {
                let request = modeReadbacks.removeFirst()
                if request != nil, request == connectionRequestID, let mode = audioFeatures.connectionMode {
                    connectionTransition?.receiveReadback(mode, session: controlSession)
                    updateConnectionModeTimeout()
                }
            } else if payload[0] == 0xE9, payload[1] == 0x05,
                      let mode = audioFeatures.connectionMode, let stream = audioFeatures.lastConnectionModeSwitchingStream {
                if connectionTransition?.receiveNotification(mode, stream: stream, session: controlSession) == true {
                    updateConnectionModeTimeout()
                }
            }
            return
        }
        if receiveTouchAssignments(payload) { return }
        if receiveSystemFeatures(payload) { return }
        if receiveGeneralSetting(payload) { return }
        var receivedSystemFeatures = systemFeatures
        let updatedSystemFeatures = receivedSystemFeatures.update(payload)
        if systemFeatures != receivedSystemFeatures { systemFeatures = receivedSystemFeatures }
        if updatedSystemFeatures || (payload.count >= 2 && payload[0] == 0xD7 && payload[1] == multipointTransition?.slot) {
            if updatedSystemFeatures { lastSyncDate = Date() }
            receiveMultipointSetting(payload)
            return
        }
        switch (payload[0], stage) {
        case (0x01, .protocolInfo):
            let reply = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            guard let info = SonyProtocolInfo(payload: payload) else {
                Self.logger.error("Unrecognized protocol info reply=\(reply, privacy: .public)")
                return
            }
            Self.logger.info("Protocol info; generation=\(info.generation.rawValue, privacy: .public) version=\(String(format: "0x%X", info.version), privacy: .public) reply=\(reply, privacy: .public)")
            protocolInformation = info
            protocolVersion = info.version
            guard info.supportsTable1, info.generation != .v1 || !usesBluetoothLE else {
                rejectUnsupportedProtocol(info.generation == .v1
                    ? String(localized: "These headphones need a Bluetooth Classic connection for their controls.")
                    : String(localized: "Acouplet does not support this device’s control protocol."))
                return
            }
            if info.generation == .v1 {
                supportedFunctions = []
                supportedFunctions2 = []
                availableNoiseModes = []
                equalizer = SonyEqualizer()
                audioFeatures = SonyAudioFeatures()
                systemFeatures = SonySystemFeatures()
                powerFeatures = SonyPowerFeatures()
                playback = SonyPlayback(generation: .v1)
                touchAssignments = SonyTouchAssignments()
                voiceGuidance = SonyVoiceGuidance()
                soundPressure = SonySoundPressure()
                earTipFit = SonyEarTipFit()
                headGesturePractice = SonyHeadGesturePractice()
                multipoint = SonyMultipoint()
            }
            supportsTable2 = info.supportsTable2
            stage = .supportFunctions
            send([0x04, 0x01])
            send([0x04, 0x03])
            send([0x06, 0x00])
        case (0x61, _), (0x63, _), (0x65, _):
            guard let inquiry = noiseControl?.inquiryType, payload.count >= 2, payload[1] == inquiry else { return }
            var receivedNoiseControl = noiseControl
            receivedNoiseControl?.update(payload)
            if payload[0] != 0x65 {
                let query: [UInt8] = [payload[0] - 1, payload[1]]
                guard noiseMetadataReads[query] == true else { return }
                let known = payload[0] == 0x61 ? receivedNoiseControl?.capabilities != nil : receivedNoiseControl?.available != nil
                guard known else {
                    if payload[0] != 0x63 || !noiseAvailabilityReadObsolete { noiseControl = receivedNoiseControl }
                    return
                }
                noiseMetadataReads[query] = nil
                noiseReadTimeouts.removeValue(forKey: query)?.work.cancel()
                if payload[0] == 0x63, noiseAvailabilityReadObsolete {
                    noiseAvailabilityReadObsolete = false
                    send(query)
                    return
                }
            } else if noiseMetadataReads[[0x62, inquiry]] == true {
                noiseAvailabilityReadObsolete = true
            }
            noiseControl = receivedNoiseControl
            if noiseControl?.capabilities != nil, noiseControl?.available != nil,
               stage == .noiseControl || (noiseControl?.available == true && noiseControl?.state == nil) {
                send([0x66, inquiry])
            }
        case (0x67, _), (0x69, _):
            parseNoiseControl(payload)
        case (0x23, _), (0x25, _):
            parseBattery(payload)
        case (0x57, _), (0x59, _):
            parseEqualizer(payload)
        case (0x05, _):
            parseFirmware(payload)
        default:
            break
        }
    }

    private func receiveGeneralSetting(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, [0xD1, 0xD3, 0xD5, 0xD7, 0xD9].contains(payload[0]) else { return false }
        if payload[0] == 0xD1 {
            let query: [UInt8] = [0xD0, payload[1], 1]
            guard let read = systemReads[query], read.transmitted else { return true }
            var features = systemFeatures
            guard features.update(payload) else { return true }
            systemReads.removeValue(forKey: query)?.timeout?.cancel()
            if read.timedOut {
                if systemFeatures.queryPayloads.contains(query) { send(query) }
                return true
            }
            let previousSlot = systemFeatures.sidetoneSlot
            if previousSlot != features.sidetoneSlot {
                if pendingChanges[.sidetone] != nil || unconfirmedChanges[.sidetone] != nil {
                    fail(String(localized: "Sidetone controls changed before the change was confirmed."))
                    return true
                }
                if let previousSlot {
                    for oldQuery: [UInt8] in [[0xD2, previousSlot], [0xD6, previousSlot]] where systemReads[oldQuery] != nil {
                        systemReads[oldQuery]?.isObsolete = true
                        systemReads[oldQuery]?.isRetiredSidetoneRead = true
                    }
                }
            }
            systemFeatures = features
            lastSyncDate = Date()
            receiveMultipointSetting(payload)
            if isReady {
                if let slot = systemFeatures.sidetoneSlot, slot == payload[1] || slot != previousSlot {
                    send([0xD2, slot])
                    send([0xD6, slot])
                }
                if payload[1] == systemFeatures.multipointSlot {
                    send([0xD2, payload[1]])
                    send([0xD6, payload[1]])
                }
            }
            return true
        }
        let query: [UInt8]? = [0xD3, 0xD7].contains(payload[0]) ? [payload[0] - 1, payload[1]] : nil
        let read = query.flatMap { systemReads[$0] }
        if payload[1] == systemFeatures.multipointSlot, query == nil || read == nil { return false }
        if query != nil, read?.transmitted != true { return true }
        if let query, read?.isRetiredSidetoneRead == true {
            let known = payload[0] == 0xD3 ? payload.count == 3 && payload[2] <= 1
                : payload.count == 4 && payload[2] == 0 && payload[3] <= 1
            guard known else { return true }
            systemReads.removeValue(forKey: query)?.timeout?.cancel()
            if systemFeatures.queryPayloads.contains(query) { send(query) }
            return true
        }
        var features = systemFeatures
        guard features.update(payload) else { return true }
        let isParameter = payload[0] == 0xD7 || payload[0] == 0xD9
        let known = isParameter ? features.sidetone?.enabled != nil : features.sidetone?.available != nil
        if let query {
            if known { systemReads.removeValue(forKey: query)?.timeout?.cancel() }
        } else {
            let oldQuery: [UInt8] = [payload[0] - 3, payload[1]]
            if systemReads[oldQuery]?.transmitted == true { systemReads[oldQuery]?.isObsolete = true }
        }
        if read?.timedOut == true {
            if known, let query { send(query) }
            return true
        }
        if let read, read.isObsolete || (isParameter && unconfirmedChanges[.sidetone] != nil
            && read.requestID == nil && !read.resolvesUnconfirmed) {
            if known, isParameter, let query, pendingChanges[.sidetone] != nil || unconfirmedChanges[.sidetone] != nil { send(query) }
            return true
        }
        systemFeatures = features
        lastSyncDate = Date()
        if known { clearSystemReadError(read?.errorSetting ?? .sidetone) }
        guard known, isParameter, payload[1] == systemFeatures.sidetoneSlot else { return true }
        if query == nil || (read?.requestID != nil && read?.requestID == settingRequests[.sidetone]) {
            confirmSetting(.sidetone, value: settingValue(payload, setting: .sidetone))
        }
        if unconfirmedChanges[.sidetone] != nil, query == nil || read?.requestID != nil || read?.resolvesUnconfirmed == true {
            unconfirmedChanges[.sidetone] = nil
            settingErrors[.sidetone] = nil
        }
        if let query, pendingChanges[.sidetone] != nil, read?.requestID != settingRequests[.sidetone] { send(query) }
        return true
    }

    private func receiveSystemFeatures(_ payload: [UInt8]) -> Bool {
        let isLegacy = protocolInformation?.generation == .v1
        guard payload.count >= 2 else { return false }
        let feature = systemFeature(inquiry: payload[1])
        let isVoiceAssistant = !isLegacy && systemFeatures.voiceAssistant != nil && payload[1] == 0x04
            && [0xF1, 0xF3, 0xF5, 0xF7, 0xF9].contains(payload[0])
        let isAutomaticPowerOff = payload[1] == automaticPowerOff?.inquiryType
            && (isLegacy ? [0xF1, 0xF3, 0xF5, 0xF7, 0xF9] : [0x21, 0x23, 0x25, 0x27, 0x29]).contains(payload[0])
        guard isVoiceAssistant || isAutomaticPowerOff || (feature != nil && ((isLegacy && payload[0] == 0xF1)
            || [0xF3, 0xF5, 0xF7, 0xF9].contains(payload[0])
            || (feature == .speakToChat && [0xFB, 0xFD].contains(payload[0])))) else { return false }
        let query: [UInt8]? = [0x21, 0x23, 0x27, 0xF1, 0xF3, 0xF7, 0xFB].contains(payload[0]) ? [payload[0] - 1, payload[1]] : nil
        let read = query.flatMap { systemReads[$0] }
        if query != nil, read?.transmitted != true { return true }
        var features = systemFeatures
        var controls = legacyControls
        if isLegacy {
            guard controls?.update(payload) == true else { return true }
        } else {
            guard features.update(payload) else { return true }
        }
        let powerOff = isLegacy ? controls?.automaticPowerOff : features.automaticPowerOff
        let state = isLegacy ? controls?.wearingControl.state : feature.flatMap { features[$0] }
        let setting = systemReadSetting([payload[0] - (query == nil ? 3 : 1), payload[1]])
        let known: Bool
        if isVoiceAssistant {
            switch payload[0] {
            case 0xF1: known = features.voiceAssistant?.hasKnownCapability == true
            case 0xF3, 0xF5: known = features.voiceAssistant?.available != nil
            default: known = features.voiceAssistant?.hasKnownParameter == true
            }
        } else if isAutomaticPowerOff {
            switch payload[0] {
            case 0x21, 0xF1: known = true
            case 0x23, 0x25, 0xF3, 0xF5: known = powerOff?.available != nil
            default: known = powerOff?.hasKnownParameter == true
            }
        } else {
            switch payload[0] {
            case 0xF1:
                known = controls?.wearingControl.settingType == 0
            case 0xF3, 0xF5:
                known = state?.available != nil && state?.isVisible != nil
            case 0xF7, 0xF9:
                known = state?.enabled != nil
            default:
                known = features.speakToChatOptions?.sensitivity?.sonyValue != nil
                    && features.speakToChatOptions?.delay?.sonyValue != nil
            }
        }
        if let query {
            if known { systemReads.removeValue(forKey: query)?.timeout?.cancel() }
        } else {
            let previousQuery: [UInt8] = [payload[0] - 3, payload[1]]
            if systemReads[previousQuery]?.transmitted == true { systemReads[previousQuery]?.isObsolete = true }
        }
        if read?.timedOut == true {
            if known, let query { send(query) }
            return true
        }
        if let read, read.isObsolete || (setting.map { unconfirmedChanges[$0] != nil } == true
            && read.requestID == nil && !read.resolvesUnconfirmed) {
            if known, let setting, let query, pendingChanges[setting] != nil || unconfirmedChanges[setting] != nil { send(query) }
            return true
        }
        if isLegacy { legacyControls = controls }
        else { systemFeatures = features }
        lastSyncDate = Date()
        if known { clearSystemReadError(read?.errorSetting ?? setting) }
        if isPracticingHeadGestures, systemFeatures[.headGestures]?.available == false {
            headGesturePracticeTransition?.unavailable()
            advanceHeadGesturePractice()
        }
        guard known, let setting else { return true }
        let value = settingValue(payload, setting: setting)
        if query == nil || (read?.requestID != nil && read?.requestID == settingRequests[setting]) {
            confirmSetting(setting, value: value)
        }
        if unconfirmedChanges[setting] != nil, query == nil || read?.requestID != nil || read?.resolvesUnconfirmed == true {
            unconfirmedChanges[setting] = nil
            settingErrors[setting] = nil
        }
        if let query, pendingChanges[setting] != nil, read?.requestID != settingRequests[setting] { send(query) }
        return true
    }

    private func receiveTouchAssignments(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == touchAssignments.inquiryType,
              [0xF1, 0xF3, 0xF5, 0xF7, 0xF9, 0xFB, 0xFD].contains(payload[0]) else { return false }
        let query: [UInt8]? = [0xF1, 0xF3, 0xF7, 0xFB].contains(payload[0]) ? [payload[0] - 1, payload[1]] : nil
        let read = query.flatMap { systemReads[$0] }
        if query != nil, read?.transmitted != true { return true }
        var assignments = touchAssignments
        guard assignments.update(payload) else { return true }
        let known: Bool
        if assignments.generation == .v1 {
            known = switch payload[0] {
            case 0xF1: assignments.hasKnownCapability
            case 0xF3, 0xF5: assignments.hasKnownStatus
            case 0xF7, 0xF9: assignments.hasKnownSelection
            default: true
            }
        } else {
            known = true
        }
        if let query {
            if known { systemReads.removeValue(forKey: query)?.timeout?.cancel() }
        } else {
            let previousQuery: [UInt8] = [payload[0] - 3, payload[1]]
            if systemReads[previousQuery]?.transmitted == true { systemReads[previousQuery]?.isObsolete = true }
        }
        let setting: Setting? = [0xF7, 0xF9].contains(payload[0]) ? .touchAssignments
            : [0xFB, 0xFD].contains(payload[0]) ? .touchCustomActions : nil
        if read?.timedOut == true {
            if known, let query { send(query) }
            return true
        }
        if let read, read.isObsolete || (setting.map { unconfirmedChanges[$0] != nil } == true
            && read.requestID == nil && !read.resolvesUnconfirmed) {
            if known, let setting, let query, pendingChanges[setting] != nil || unconfirmedChanges[setting] != nil { send(query) }
            return true
        }
        touchAssignments = assignments
        lastSyncDate = Date()
        if known { clearSystemReadError(read?.errorSetting ?? setting) }
        if payload[0] == 0xF1, assignments.queryPayloads.contains([0xFA, payload[1]]) { send([0xFA, payload[1]]) }
        guard known, let setting else { return true }
        let value: [UInt8]?
        if setting == .touchAssignments {
            if let keys = assignments.keys, let selected = assignments.selectedPresets, keys.count == selected.count,
               zip(keys, selected).allSatisfy({ key, preset in key.presets.filter { $0.preset == preset }.count == 1 }) {
                value = Array(payload.dropFirst())
            } else {
                value = nil
            }
        } else if let expected = pendingChanges[setting] ?? unconfirmedChanges[setting], expected.count == 3,
                  let function = assignments.reportedFunction(preset: expected[0], action: expected[1]),
                  assignments.keys?.contains(where: { key in
                      key.presets.contains { preset in
                          preset.preset == expected[0] && preset.customizableActions.contains {
                              $0.action == expected[1] && $0.functions.contains(function)
                          }
                      }
                  }) == true {
            value = [expected[0], expected[1], function]
        } else {
            value = nil
        }
        if query == nil || (read?.requestID != nil && read?.requestID == settingRequests[setting]) {
            confirmSetting(setting, value: value)
        }
        if value != nil, unconfirmedChanges[setting] != nil,
           query == nil || read?.requestID != nil || read?.resolvesUnconfirmed == true {
            unconfirmedChanges[setting] = nil
            settingErrors[setting] = nil
        }
        if let query, pendingChanges[setting] != nil, read?.requestID != settingRequests[setting] { send(query) }
        return true
    }

    private func rejectUnsupportedProtocol(_ message: String) {
        let info = protocolInformation
        let identity = deviceInformation
        closeSonyLink()
        protocolInformation = info
        protocolVersion = info?.version
        deviceInformation = identity
        stage = .unsupported
        linkState = .failed(message)
        lastErrorMessage = message
    }

    private func receiveLegacySoundEffect(_ payload: [UInt8]) -> Bool {
        guard [0x41, 0x43, 0x45, 0x47, 0x49].contains(payload[0]),
              let kind = SonyLegacySoundEffect.Kind(rawValue: payload[1]) else { return false }
        var effect = legacySoundEffect(kind)
        let query: [UInt8]? = switch payload[0] {
        case 0x41: effect.capabilityQuery
        case 0x43: effect.statusQuery
        case 0x47: effect.parameterQuery
        default: nil
        }
        if let query, !legacyReads.contains(query) { return true }
        guard effect.update(payload) else { return true }
        let read = query.flatMap { legacySoundEffectReads[$0] }
        if let query {
            legacyReads.remove(query)
            legacySoundEffectReads[query] = nil
            if let timeout = legacySoundEffectReadTimeouts.removeValue(forKey: query) {
                timeout.work?.cancel()
                if timeout.work == nil {
                    if legacySoundEffect(kind).queryPayloads.contains(query) { send(query) }
                    return true
                }
            }
        }
        if payload[0] == 0x45 { legacySoundEffectReads[effect.statusQuery]?.isObsolete = true }
        if payload[0] == 0x49 { legacySoundEffectReads[effect.parameterQuery]?.isObsolete = true }
        let setting = Setting.legacySoundEffect(kind)
        let predatesUnconfirmedChange = payload[0] == 0x47 && unconfirmedChanges[setting] != nil
            && read?.requestID == nil && read?.resolvesUnconfirmed != true
        if read?.isObsolete != true, !predatesUnconfirmedChange {
            if kind == .surround { legacySurround = effect }
            else { legacySoundPosition = effect }
            lastSyncDate = Date()
            if effect.presets != nil, effect.available != nil, effect.presetID != nil,
               pendingChanges[setting] == nil, unconfirmedChanges[setting] == nil {
                settingErrors[setting] = nil
            }
            if (payload[0] == 0x47 || payload[0] == 0x49), unconfirmedChanges[setting] != nil {
                unconfirmedChanges[setting] = nil
                settingErrors[setting] = nil
            }
            if payload[0] == 0x49 || (payload[0] == 0x47 && read?.requestID != nil && read?.requestID == settingRequests[setting]) {
                confirmSetting(setting, value: settingValue(payload, setting: setting))
            }
        }
        if payload[0] == 0x47,
           (unconfirmedChanges[setting] != nil && (read?.isObsolete == true || predatesUnconfirmedChange))
            || (pendingChanges[setting] != nil && settingTimeouts[setting] != nil
                && (read?.isObsolete == true || read?.requestID != settingRequests[setting])) {
            send(effect.parameterQuery)
        }
        return true
    }

    private func receiveLegacyConnectionQuality(_ payload: [UInt8]) -> Bool {
        guard payload[1] == 1, [0xE1, 0xE3, 0xE5, 0xE7, 0xE9].contains(payload[0]) else { return false }
        let query: [UInt8]? = [0xE1, 0xE3, 0xE7].contains(payload[0]) ? [payload[0] - 1, 1] : nil
        let read = query.flatMap { systemReads[$0] }
        if query != nil, read?.transmitted != true { return true }
        guard var controls = legacyControls, controls.update(payload) else { return true }
        let quality = controls.connectionQuality
        let known: Bool = switch payload[0] {
        case 0xE1: quality.settingType == 0
        case 0xE3, 0xE5: quality.available != nil
        default: quality.hasKnownParameter
        }
        if let query, known { systemReads.removeValue(forKey: query)?.timeout?.cancel() }
        if payload[0] == 0xE5, systemReads[[0xE2, 1]]?.transmitted == true { systemReads[[0xE2, 1]]?.isObsolete = true }
        if payload[0] == 0xE9, systemReads[[0xE6, 1]]?.transmitted == true { systemReads[[0xE6, 1]]?.isObsolete = true }
        if read?.isObsolete == true, known, payload[0] == 0xE7,
           read?.requestID != nil, read?.requestID == connectionRequestID {
            connectionTransition?.discardReadback(session: controlSession)
        }
        if read?.isObsolete != true {
            legacyControls = controls
            lastSyncDate = Date()
            if known, let mode = quality.mode {
                if payload[0] == 0xE9 {
                    connectionTransition?.receiveNotification(mode, stream: .none, session: controlSession)
                } else if payload[0] == 0xE7, read?.requestID != nil, read?.requestID == connectionRequestID {
                    if let transition = connectionTransition, transition.phase == .verifying, mode != transition.targetMode {
                        clearFinishedConnectionChange()
                        connectionModeError = String(localized: "Headphones reported \(mode.title); the requested \(transition.targetMode.title) change was not confirmed.")
                    } else {
                        connectionTransition?.receiveReadback(mode, session: controlSession)
                    }
                }
                updateConnectionModeTimeout()
            }
        }
        if known, payload[0] == 0xE7, let transition = connectionTransition,
           transition.phase == .awaitingResponse || transition.phase == .verifying,
           read?.isObsolete == true || read?.requestID != connectionRequestID {
            send([0xE6, 1])
        }
        return true
    }

    private func receiveLegacyControls(_ payload: [UInt8], type: UInt8) {
        guard type == 0x0C, payload.count >= 2 else { return }
        if payload[0] == 0x07 {
            guard stage == .supportFunctions, legacyReads.contains([0x06, 0]),
                  let controls = SonyLegacyControls(supportPayload: payload, model: deviceModel) else { return }
            legacyReads.remove([0x06, 0])
            let hex = { (functions: Set<UInt8>) in functions.sorted().map { String(format: "%02X", $0) }.joined(separator: " ") }
            let reported = hex(Set(payload.dropFirst(3)))
            let hidden = hex(Set(payload.dropFirst(3)).subtracting(controls.supportedFunctions))
            Self.logger.info("MDR v1 support functions=\(reported, privacy: .public) hidden=\(hidden, privacy: .public) model=\(self.deviceModel.rawValue, privacy: .public)")
            legacyControls = controls
            legacyOptimizer = SonyLegacyOptimizer(supportedFunctions: controls.supportedFunctions)
            legacySurround = SonyLegacySoundEffect(kind: .surround, supportedFunctions: controls.supportedFunctions)
            legacySoundPosition = SonyLegacySoundEffect(kind: .soundPosition, supportedFunctions: controls.supportedFunctions)
            equalizer = SonyEqualizer(supportedFunctions: controls.supportedFunctions, generation: .v1)
            playback = SonyPlayback(supportedFunctions: controls.supportedFunctions, generation: .v1)
            touchAssignments = SonyTouchAssignments(supportedFunctions: controls.supportedFunctions, generation: .v1)
            voiceGuidance = SonyVoiceGuidance(supportedFunctions: controls.supportedFunctions, generation: .v1)
            asmType = controls.noiseQueries.isEmpty ? nil : 0x02
            availableNoiseModes = []
            enableConnectionAlerts()
            if asmType != nil {
                stage = .noiseControl
                send([0x60, 0x02])
                send([0x62, 0x02])
                requestBattery()
                send([0x04, 0x02])
            } else {
                finishControlSync(initial: true)
            }
            return
        }
        if payload.prefix(2) == [0x05, 0x02] {
            guard legacyReads.contains([0x04, 0x02]), Self.decodedFirmware(payload) != nil,
                  consumeLegacyOptionalRead([0x04, 0x02]) else { return }
            parseFirmware(payload)
            return
        }
        guard stage == .noiseControl || stage == .ready, var controls = legacyControls else { return }
        if let alert = SonyConnectionAlert(payload: payload, generation: .v1) {
            lastConnectionAlert = alert
            lastSyncDate = Date()
            if connectionTransition?.receiveAlert(alert, session: controlSession) == true {
                if systemReads[[0xE6, 1]]?.transmitted == true {
                    systemReads[[0xE6, 1]]?.isObsolete = true
                    systemReads[[0xE6, 1]]?.timeout?.cancel()
                    systemReads[[0xE6, 1]]?.timeout = nil
                }
                updateConnectionModeTimeout()
            }
            return
        }
        if receiveLegacyConnectionQuality(payload) { return }
        if receiveTouchAssignments(payload) { return }
        if receiveSystemFeatures(payload) { return }
        if receiveLegacyOptimizer(payload) { return }
        if receiveLegacySoundEffect(payload) { return }
        if [0x51, 0x53, 0x55, 0x5B, 0x57, 0x59].contains(payload[0]), payload[1] == equalizer.inquiryType {
            if payload[0] == 0x57 || payload[0] == 0x59 {
                guard payload[0] == 0x59 || equalizerRead?.transmitted == true else { return }
                parseEqualizer(payload)
                return
            }
            let query: [UInt8]? = switch payload[0] {
            case 0x51: [0x50, payload[1], 1]
            case 0x53: [0x52, payload[1]]
            case 0x5B: [0x5A, payload[1]]
            default: nil
            }
            if let query, !legacyReads.contains(query) { return }
            var updated = equalizer
            guard updated.update(payload) else { return }
            if let query, !consumeLegacyOptionalRead(query) { return }
            equalizer = updated
            lastSyncDate = Date()
            return
        }
        let query: [UInt8]? = switch payload[0] {
        case 0x11, 0x61, 0x63, 0xE1, 0xE3, 0xE7: [payload[0] - 1, payload[1]]
        default: nil
        }
        if let query, !legacyReads.contains(query) { return }
        if payload[0] == 0x67, noiseControlRead?.asmType != payload[1] { return }
        guard controls.update(payload) else { return }
        if let query {
            if payload[0] == 0x11, !consumeLegacyOptionalRead(query) { return }
            legacyReads.remove(query)
            noiseReadTimeouts.removeValue(forKey: query)?.work.cancel()
            if let timeout = legacyDSEEReadTimeouts.removeValue(forKey: query) {
                timeout.work?.cancel()
                if timeout.work == nil {
                    if query == [0xE6, 0x02] { legacyDSEERead = nil }
                    if query == [0xE2, 0x02] { legacyDSEEAvailabilityReadObsolete = false }
                    if legacyControls?.dsee.queryPayloads.contains(query) == true { send(query) }
                    return
                }
            }
            if payload[0] == 0x11, obsoleteLegacyBatteryReads.remove(query) != nil { return }
        }
        if payload[0] == 0x13, legacyReads.contains([0x10, payload[1]]) {
            obsoleteLegacyBatteryReads.insert([0x10, payload[1]])
        }
        if payload[0] == 0x65, legacyReads.contains([0x62, 0x02]) { noiseAvailabilityReadObsolete = true }
        if payload[0] == 0x63, noiseAvailabilityReadObsolete {
            noiseAvailabilityReadObsolete = false
            return
        }
        if payload[0] == 0x69 { noiseControlRead?.isObsolete = true }
        if payload[0] == 0x67 {
            noiseReadTimeouts.removeValue(forKey: [0x66, 0x02])?.work.cancel()
            if let read = noiseControlRead,
               read.isObsolete || (unconfirmedChanges[.noiseControl] != nil && read.requestID == nil && !read.resolvesUnconfirmed) {
                noiseControlRead = nil
                if pendingChanges[.noiseControl] != nil || unconfirmedChanges[.noiseControl] != nil { send([0x66, 0x02]) }
                return
            }
        }
        let dseeRead = payload[0] == 0xE7 ? legacyDSEERead : nil
        if payload[0] == 0xE7 { legacyDSEERead = nil }
        if payload[0] == 0xE5, legacyReads.contains([0xE2, 0x02]) { legacyDSEEAvailabilityReadObsolete = true }
        if payload[0] == 0xE3, legacyDSEEAvailabilityReadObsolete {
            legacyDSEEAvailabilityReadObsolete = false
            return
        }
        if payload[0] == 0xE9 { legacyDSEERead?.isObsolete = true }
        if let read = dseeRead,
           read.isObsolete || (unconfirmedChanges[.dsee] != nil && read.requestID == nil && !read.resolvesUnconfirmed) {
            if pendingChanges[.dsee] != nil || unconfirmedChanges[.dsee] != nil { send([0xE6, 0x02]) }
            return
        }
        legacyControls = controls
        if [0xE1, 0xE3, 0xE5, 0xE7, 0xE9].contains(payload[0]) {
            lastSyncDate = Date()
            if controls.dsee.type != nil, controls.dsee.settingType == 0, controls.dsee.available != nil,
               controls.dsee.parameterSettingType == 0, controls.dsee.mode?.sonyValue != nil,
               pendingChanges[.dsee] == nil, unconfirmedChanges[.dsee] == nil {
                settingErrors[.dsee] = nil
            }
            if (payload[0] == 0xE7 || payload[0] == 0xE9),
               controls.dsee.parameterSettingType == 0, controls.dsee.mode?.sonyValue != nil {
                if unconfirmedChanges[.dsee] != nil {
                    unconfirmedChanges[.dsee] = nil
                    settingErrors[.dsee] = nil
                }
                if payload[0] == 0xE9 || (dseeRead?.requestID != nil && dseeRead?.requestID == settingRequests[.dsee]) {
                    confirmSetting(.dsee, value: settingValue(payload, setting: .dsee))
                }
            }
            if payload[0] == 0xE7, pendingChanges[.dsee] != nil, dseeRead?.requestID != settingRequests[.dsee] {
                send([0xE6, 0x02])
            }
            return
        }
        if payload[0] == 0x11 || payload[0] == 0x13 {
            var updated = controls.batteries
            if payload[1] != 0x02 { updated.caseBattery = batteries.caseBattery }
            batteries = updated
            let observedAt = Date()
            lastSyncDate = observedAt
            recordLowBatteryReadings(type: payload[1], observedAt: observedAt)
            return
        }
        if let capability = controls.noiseCapability {
            guard capability.supportsModes else {
                if capability.noiseType == 1, capability.ambientType <= 1,
                   capability.ambientSteps[0].map({ capability.ambientType == 0 || $0 > 0 }) == true {
                    asmType = nil
                    availableNoiseModes = []
                    noiseControlRead = nil
                    for query in controls.noiseQueries {
                        legacyReads.remove(query)
                        queuedLegacyReads.remove(query)
                        noiseReadTimeouts.removeValue(forKey: query)?.work.cancel()
                    }
                    if stage == .noiseControl { finishControlSync(initial: true) }
                    return
                }
                rejectUnsupportedProtocol(String(localized: "These headphones reported an older noise-control type that is not supported yet."))
                return
            }
            availableNoiseModes = capability.modes
        }
        if payload[0] == 0x67 || payload[0] == 0x69 {
            if payload[0] == 0x67, decodedNoiseControlMode(payload) == nil { noiseControlRead = nil }
            parseNoiseControl(payload)
        }
        if stage == .noiseControl, controls.noiseCapability != nil, controls.noiseAvailable != nil {
            send([0x66, 0x02])
        }
    }

    private func parseSupportFunctions(_ payload: [UInt8], type: UInt8) {
        guard protocolInformation?.generation == .v2,
              payload.count >= 3, payload[1] == 0x00,
              payload.count == 3 + Int(payload[2]) * 2 else { return }
        let functions = Set(stride(from: 3, to: payload.count, by: 2).map { payload[$0] })
        if type == 0x0E {
            guard supportsTable2, consumeDiscoveryRead([0x06, 0x00], type: type) else { return }
            table2CapabilitiesSession = controlSession
            guard functions != supportedFunctions2 else { return }
            if deviceActionTransition?.isFinished == false {
                deviceActionTransition?.capabilitiesChanged(session: controlSession)
                fail(String(localized: "The headphone settings changed before the device connection change was confirmed."))
                return
            }
            if sourceTransition?.isFinished == false {
                sourceTransition?.capabilitiesChanged(session: controlSession)
                fail(String(localized: "The headphone settings changed before the audio source change was confirmed."))
                return
            }
            invalidateSoundPressureReading()
            soundPressure = SonySoundPressure(supportedFunctions: functions)
            invalidateWearingStatus()
            wearingStatus = SonyWearingStatus(supportedFunctions: functions)
            supportedFunctions2 = functions
            let previousCare = powerFeatures.batteryCare?.includesThreshold
            powerFeatures.updateSupportedFunctions(supportedFunctions, supportedFunctions2: functions)
            if previousCare != powerFeatures.batteryCare?.includesThreshold {
                if pendingChanges[.batteryCare] != nil || unconfirmedChanges[.batteryCare] != nil {
                    fail(String(localized: "Battery Care changed before the change was confirmed."))
                    return
                }
                for key in powerReads.keys where powerReads[key]?.setting == .batteryCare {
                    powerReads[key]?.isRetired = true
                }
            }
            if pendingChanges[.voiceGuidance] != nil || pendingChanges[.voiceGuidanceVolume] != nil
                || unconfirmedChanges[.voiceGuidance] != nil || unconfirmedChanges[.voiceGuidanceVolume] != nil {
                fail(String(localized: "The voice guidance settings changed before the change was confirmed."))
                return
            }
            for query in voiceGuidanceReads.keys where voiceGuidanceReads[query]?.transmitted == true {
                voiceGuidanceReads[query]?.isObsolete = true
            }
            voiceGuidance = SonyVoiceGuidance(supportedFunctions: functions)
            multipoint = SonyMultipoint(supportedFunctions: functions)
            if isReady {
                for payload in voiceGuidance.queryPayloads + multipoint.queryPayloads + soundPressure.queryPayloads + powerFeatures.queryPayloads(frameType: 0x0E) { send(payload, type: 0x0E) }
            }
            return
        }
        guard stage == .supportFunctions, supportFunctionsReadTransmitted else { return }
        supportFunctionsReadTransmitted = false
        let supported = Self.asmByFunction.first(where: { functions.contains($0.function) })
        supportedFunctions = functions
        equalizer = SonyEqualizer(supportedFunctions: functions)
        earTipFit = SonyEarTipFit(supportedFunctions: functions)
        headGesturePractice = SonyHeadGesturePractice(supportedFunctions: functions)
        audioFeatures = SonyAudioFeatures(supportedFunctions: functions)
        systemFeatures = SonySystemFeatures(supportedFunctions: functions)
        powerFeatures = SonyPowerFeatures(supportedFunctions: functions, supportedFunctions2: supportedFunctions2)
        playback = SonyPlayback(supportedFunctions: functions)
        touchAssignments = SonyTouchAssignments(supportedFunctions: functions)
        asmType = supported?.type
        noiseControl = supported.flatMap { [0x17, 0x19].contains($0.type) ? SonyNoiseControl(inquiryType: $0.type) : nil }
        if functions.contains(0x40) { send([0x40, 0x00]) }
        if let supported {
            availableNoiseModes = supported.type == 0x21 || supported.type == 0x22
                ? [.off, .ambient] : [.off, .anc, .ambient]
            if supported.type == 0x15 { availableNoiseModes.append(.wind) }
        } else {
            availableNoiseModes = []
        }
        if usesBluetoothLE || (connectionTransition?.isFinished == false && transitionHash != nil)
            || (multipointTransition?.isFinished == false && multipointConnection?.hash != nil) {
            guard functions.contains(0x14) else {
                fail(String(localized: "This connection could not verify the selected headphones."))
                return
            }
            stage = .bleIdentity
            send([0x10, 0x04])
        } else {
            if functions.contains(0x14) { send([0x10, 0x04]) }
            beginControlSync()
        }
    }

    private func beginControlSync() {
        enableConnectionAlerts()
        if let asmType {
            stage = .noiseControl
            requestNoiseControl(asmType)
        } else {
            finishControlSync(initial: true)
        }
    }

    private func enableConnectionAlerts() {
        guard let protocolVersion, protocolVersion >= 0x4000 else { return }
        if protocolInformation?.generation == .v1 {
            send([0x94, 0x01, 0x00])
        } else if supportedFunctions.contains(0x90) {
            send([0x94, 0x00, 0x00])
        }
    }

    private func decodedNoiseControlMode(_ payload: [UInt8]) -> NoiseControlMode? {
        if let legacyControls {
            guard let state = SonyLegacyNoiseState(payload: payload) else { return nil }
            return legacyControls.validatedMode(state)
        }
        if let noiseControl { return noiseControl.validatedMode(payload) }
        guard let asmType, payload.count == [0x17: 7, 0x15: 8, 0x22: 6, 0x21: 6][Int(asmType)],
              payload[1] == asmType else { return nil }
        if payload[3] == 0x00 { return .off }
        if asmType == 0x15, payload[5] == 0x03 || payload[5] == 0x05 { return .wind }
        if asmType == 0x21 || asmType == 0x22 { return .ambient }
        return payload[4] == 0x00 ? .anc : .ambient
    }

    private func parseNoiseControl(_ payload: [UInt8]) {
        guard stage == .noiseControl || stage == .ready, payload.count >= 2 else { return }
        let read = payload[0] == 0x67 && noiseControlRead?.asmType == payload[1] ? noiseControlRead : nil
        if let inquiry = noiseControl?.inquiryType {
            guard payload[1] == inquiry, payload[0] == 0x69 || read != nil, read?.timedOut != true else { return }
            if payload[0] == 0x69 { noiseControlRead?.isObsolete = true }
            if read?.isObsolete == true {
                if noiseControlSawValidChanging {
                    scheduleNoiseControlRefresh(inquiry)
                    return
                }
                noiseControlRead = nil
                noiseReadTimeouts.removeValue(forKey: [0x66, inquiry])?.work.cancel()
                send([0x66, inquiry])
                return
            }
            if let read, unconfirmedChanges[.noiseControl] != nil,
               read.requestID == nil, !read.resolvesUnconfirmed {
                noiseControlRead = nil
                noiseReadTimeouts.removeValue(forKey: [0x66, inquiry])?.work.cancel()
                send([0x66, inquiry])
                return
            }
            noiseControl?.update(payload)
            guard let state = noiseControl?.state, noiseControl?.validatedMode(payload) != nil else {
                if payload.count > 2, payload[2] == 0 {
                    var terminal = payload
                    terminal[2] = 1
                    if noiseControl?.validatedMode(terminal) != nil, noiseControl?.available != nil {
                        noiseControlSawValidChanging = true
                        if stage == .noiseControl { finishControlSync(initial: true) }
                        scheduleNoiseControlRefresh(inquiry)
                        return
                    }
                }
                scheduleNoiseControlRefresh(inquiry)
                return
            }
            noiseControlRefresh?.work.cancel()
            noiseControlRefresh = nil
            noiseControlRefreshAttempted = false
            if read != nil || noiseControlRead == nil || noiseControlSawValidChanging {
                noiseControlRead = nil
                noiseReadTimeouts.removeValue(forKey: [0x66, inquiry])?.work.cancel()
            }
            noiseControlSawValidChanging = false
            noiseControlDisplayState = state
        }
        guard let mode = decodedNoiseControlMode(payload) else { return }
        if let transition = connectionTransition, !transition.isFinished,
           protocolInformation?.generation != transition.generation {
            fail(String(localized: "The headphone protocol changed during the connection change."))
            return
        }
        let modeChange = SonyNoiseModeChange(deviceID: lowBatteryNotificationDeviceID, session: controlSession,
            deviceName: deviceName, previousMode: noiseControlMode, mode: mode, isUnsolicited: payload[0] == 0x69,
            hasLocalCommand: pendingChanges[.noiseControl] != nil || unconfirmedChanges[.noiseControl] != nil
                || requestedNoiseControlPayload != nil || ambientWorkItem != nil || settingIntent?.setting == .noiseControl)
        if noiseControl != nil || legacyControls != nil, unconfirmedChanges[.noiseControl] != nil {
            unconfirmedChanges[.noiseControl] = nil
            settingErrors[.noiseControl] = nil
        }
        if read != nil { noiseControlRead = nil }
        let hasExtraAmbientFields = payload[1] == 0x19
        let index = payload.count - (hasExtraAmbientFields ? 4 : 2)
        if ambientWorkItem == nil, requestedNoiseControlPayload == nil,
           pendingChanges[.noiseControl] == nil || pendingChanges[.noiseControl] == settingValue(payload, setting: .noiseControl) {
            focusOnVoice = payload[index] == 0x01
            let level = Int(payload[index + 1])
            if let legacyControls, let range = legacyControls.noiseCapability?.ambientRange(focusOnVoice: focusOnVoice) {
                ambientLevel = range.contains(level) ? level : max(range.lowerBound, min(range.upperBound, ambientLevel))
            } else if noiseControl != nil {
                ambientLevel = level
            } else {
                ambientLevel = (0...20).contains(level) ? level : 10
            }
        }
        let isInitialSync = stage == .noiseControl
        noiseControlMode = mode
        if payload[0] == 0x69 || (read?.requestID != nil && read?.requestID == settingRequests[.noiseControl]) {
            confirmSetting(.noiseControl, value: settingValue(payload, setting: .noiseControl))
        }
        if let modeChange { noiseModeChanges.send(modeChange) }
        if let read, pendingChanges[.noiseControl] != nil, read.requestID != settingRequests[.noiseControl] {
            send([0x66, payload[1]])
        }
        if protocolInformation?.generation == .v1, legacyControls?.noiseAvailable == nil { return }
        Self.logger.info("Noise control synced; mode=\(mode.rawValue, privacy: .public)")
        finishControlSync(initial: isInitialSync)
    }

    private func finishControlSync(initial isInitialSync: Bool) {
        stage = .ready
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        linkState = .ready
        if deviceActionTransition?.phase == .failed, deviceActionRecoveryAttempts > 0 {
            deviceActionTransition = nil
            deviceActionRecoveryAttempts = 0
        }
        handshakeID = nil
        if isInitialSync {
            lastReadyTransportWasBluetoothLE = usesBluetoothLE
            isApplyingChange = false
            commandTimeoutWorkItem?.cancel()
            commandTimeoutWorkItem = nil
        }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryAttempt = 0
        nextRetryDate = nil
        retrySecondsRemaining = nil
        lastErrorMessage = nil
        lastSyncDate = Date()
        if batteryLevel == nil { requestBattery() }
        if equalizer.presetID == nil { refreshEqualizer() }
        if firmwareVersion == nil { send([0x04, 0x02]) }
        if isInitialSync {
            if connectionTransition?.controlReady(session: controlSession) == true {
                connectionModeError = nil
            }
            updateConnectionModeTimeout()
            recoveryUsesBLE = nil
            requestAudioFeatures()
            if supportsTable2 { send([0x06, 0x00], type: 0x0E) }
        }
    }

    private func parseBattery(_ payload: [UInt8]) {
        var updated = batteries
        guard updated.update(payload) else { return }
        let query: [UInt8] = [0x22, payload[1]]
        if payload[0] == 0x23 {
            guard let read = batteryReads[query], read.transmitted else { return }
            batteryReads.removeValue(forKey: query)?.timeout?.cancel()
            guard !read.isObsolete, !read.timedOut else { return }
        } else if batteryReads[query]?.transmitted == true {
            batteryReads[query]?.isObsolete = true
        }
        batteries = updated
        if payload[1] == 0x01 || payload[1] == 0x09 { updateChargingCasePresence() }
        let observedAt = Date()
        lastSyncDate = observedAt
        recordLowBatteryReadings(type: payload[1], observedAt: observedAt)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        guard !isSimulated, isReady, deviceModel == .wfXM5,
              payload[1] == 0x09 || payload[1] == 0x0A,
              let device, let identity = verifiedIdentity(for: device),
              identity.hash == bluetoothLEHash, let identifier = identity.peripheralIdentifier else { return }
        var snapshot = nativeBatterySnapshot.flatMap { $0.identifier == identifier ? $0 : nil }
            ?? SonyNativeBatterySnapshot(identifier: identifier, name: deviceName)
        snapshot.name = deviceName
        snapshot.update(batteries, type: payload[1], observedAt: observedAt)
        if audioFeatures.supportsConnectionStatus {
            snapshot.invalidateUnavailableBuds(leftConnected: audioFeatures.leftConnected,
                                              rightConnected: audioFeatures.rightConnected)
        }
        nativeBatterySnapshot = snapshot
        #endif
    }

    private func updateChargingCasePresence() {
        chargingCaseTimeout?.cancel()
        chargingCaseTimeout = nil
        isChargingInCase = isReady && isDeviceConnected
            && (deviceModel == .wfXM5 || deviceModel == .wfXM6)
            && batteries.left?.isCharging == true && batteries.right?.isCharging == true
        guard isChargingInCase else { return }
        let session = controlSession
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.controlSession == session else { return }
            self.isChargingInCase = false
            self.chargingCaseTimeout = nil
        }
        chargingCaseTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    private func expireCaseBattery(at date: Date) {
        guard let observedAt = caseBatteryObservedAt,
              !(-5...45).contains(date.timeIntervalSince(observedAt)) else { return }
        caseBatteryObservedAt = nil
        lowBatteryReadings.removeAll { $0.part == .caseBattery }
    }

    private func recordLowBatteryReadings(type: UInt8, observedAt: Date) {
        let parts: [(SonyLowBatteryPolicy.Part, BatteryReading?)]
        let group: SonyLowBatteryPolicy.Group
        switch type {
        case 0x00, 0x08:
            group = .headphones
            parts = [(.headphones, batteries.single)]
        case 0x01, 0x09:
            group = .earbuds
            parts = [(.left, batteries.left), (.right, batteries.right)]
        case 0x02, 0x0A:
            group = .caseBattery
            parts = [(.caseBattery, batteries.caseBattery)]
            caseBatteryObservedAt = batteries.caseBattery == nil ? nil : observedAt
        default:
            return
        }
        var readings = lowBatteryReadings.filter {
            $0.part.group != group && (group == .caseBattery || $0.part.group == .caseBattery)
        }
        readings += parts.compactMap { part, value in
            guard let value, value.chargingState != .unknown else { return nil }
            if audioFeatures.supportsConnectionStatus {
                if part == .left, audioFeatures.leftConnected != true { return nil }
                if part == .right, audioFeatures.rightConnected != true { return nil }
            }
            return SonyLowBatteryPolicy.Reading(part: part, level: value.level,
                                               isCharging: value.isCharging, observedAt: observedAt)
        }
        lowBatteryReadings = readings
    }

    private func parseEqualizer(_ payload: [UInt8]) {
        guard payload.count >= 2, payload[1] == equalizer.inquiryType else { return }
        var updated = equalizer
        guard updated.update(payload) else { return }
        let read = payload[0] == 0x57 && equalizerRead?.transmitted == true ? equalizerRead : nil
        let waitingSync = settingRequests[.equalizerReadback]
        let waitingChange = settingRequests[.equalizer]
        if read != nil {
            equalizerRead = nil
            equalizerReadTimeout?.cancel()
            equalizerReadTimeout = nil
        }
        defer {
            if let read {
                if let waitingSync, read.requestID != waitingSync, settingRequests[.equalizerReadback] == waitingSync {
                    if let query = equalizer.parameterQueryPayload { send(query) }
                } else if let waitingChange, read.requestID != waitingChange,
                          settingRequests[.equalizer] == waitingChange, settingTimeouts[.equalizer] != nil {
                    if let query = equalizer.parameterQueryPayload { send(query) }
                } else if let unconfirmedEqualizerRequestID,
                          read.timedOut || read.unconfirmedRequestID != unconfirmedEqualizerRequestID {
                    if let query = equalizer.parameterQueryPayload { send(query) }
                }
            }
        }
        equalizer = updated
        if let settings = equalizer.settings {
            customEqualizer = settings
        }
        lastSyncDate = Date()
        if payload[0] == 0x59 || (read?.setting == .equalizer && read?.requestID == (settingRequests[.equalizer] ?? unconfirmedEqualizerRequestID)) {
            confirmSetting(.equalizer, value: settingValue(payload, setting: .equalizer))
        }
        if let read, !read.timedOut, let unconfirmedEqualizerRequestID,
           read.unconfirmedRequestID == unconfirmedEqualizerRequestID {
            confirmSetting(.equalizer, value: settingValue(payload, setting: .equalizer))
            unconfirmedChanges[.equalizer] = nil
            self.unconfirmedEqualizerRequestID = nil
        }
        if let read, read.setting == .equalizerReadback, let requestID = read.requestID,
           settingRequests[.equalizerReadback] == requestID {
            if equalizer.generation == .v1, equalizer.settings == nil {
                failEqualizerReadback(message: String(localized: "The headphones did not report an equalizer curve."))
            } else {
                confirmSetting(.equalizerReadback, value: [])
                equalizerReadbackID = requestID
            }
        }
        if let equalizerPreset {
            Self.logger.info("Equalizer ready; preset=\(equalizerPreset.title, privacy: .public)")
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }

    private static func bluetoothAddress(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 17, bytes.enumerated().allSatisfy({ index, byte in
            index % 3 == 2 ? byte == 0x3A
                : (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }) else { return nil }
        return String(decoding: bytes, as: UTF8.self).uppercased()
    }

    private func handleConnectionDirective(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[0] == 0x49 else { return false }
        guard powerOffState == nil, !isRunningHeadphoneTest else { return true }
        let useBLE: Bool
        switch payload[1] {
        case 0x0C:
            guard payload.count == 3, supportedFunctions.contains(0x40), payload[2] <= 1 else { return false }
            if connectionTransition?.receiveLEStandby(payload[2] == 0, session: controlSession) == true {
                cancelScheduledRetry(resetAttempts: true)
                recoveryUsesBLE = nil
                connectionModeError = nil
                updateConnectionModeTimeout()
            }
            return true
        case 0x0D, 0x0F:
            guard payload.count == 2, supportedFunctions.contains(0x40) else { return false }
            useBLE = payload[1] == 0x0D ? usesBluetoothLE
                : connectionTransition.map { $0.targetMode == .lowLatency } ?? usesBluetoothLE
        case 0x0E:
            guard payload.count == 20, supportedFunctions.contains(0x44), payload[2] <= 1,
                  let targetAddress = Self.bluetoothAddress(Array(payload[3..<20])) else { return false }
            useBLE = payload[2] == 1
            let knownAddresses = controlAddresses.union(transitionControlAddresses).union([Self.normalizedAddress(address)])
            guard knownAddresses.contains(targetAddress) else {
                connectionModeError = String(localized: "The requested control device could not be verified.")
                return true
            }
            if !useBLE { recoveryClassicAddress = targetAddress }
        default:
            return false
        }
        if transitionAddress == nil {
            transitionDevice = device
            transitionAddress = address
            transitionHash = bluetoothLEHash
            transitionPeripheralID = controlPeripheralID
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            transitionPeripheralID = transitionPeripheralID ?? device.flatMap(SonyBLEIdentity.classicPeripheralIdentifier)
            #endif
            transitionModel = deviceModel
            transitionControlAddresses = controlAddresses
        }
        guard !useBLE || transitionHash != nil else {
            connectionModeError = String(localized: "The headphones could not be identified. Reconnect them and try again.")
            return true
        }
        recoveryUsesBLE = useBLE
        retryAttempt = 0
        closeSonyLink()
        linkState = .disconnected
        scheduleRetry()
        return true
    }

    private func handleMultipointDirective(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[0] == 0x49,
              let connection = multipointConnection else { return false }
        guard powerOffState == nil, !isRunningHeadphoneTest else { return true }
        switch payload[1] {
        case 0x0C:
            return true
        case 0x0D, 0x0F:
            guard payload.count == 2, supportedFunctions.contains(0x40) else { return true }
        case 0x0E:
            guard payload.count == 20, supportedFunctions.contains(0x44), payload[2] <= 1,
                  let target = Self.bluetoothAddress(Array(payload[3..<20])) else { return true }
            guard (payload[2] == 1) == connection.usesBLE, connection.controlAddresses.contains(target) else {
                finishMultipointRecovery(String(localized: "The requested control connection does not match the pending multipoint change."))
                return true
            }
        default:
            return false
        }
        Self.logger.notice("Multipoint control directive; session=\(self.controlSession) code=\(payload[1]) phase=\(self.multipointTransition?.diagnosticPhase ?? "none", privacy: .public)")
        guard multipointTransition?.phase != .queued else { return true }
        if multipointTransition?.isFinished == true,
           multipointTransition?.recheckAfterDirective(session: controlSession) != true { return true }
        closeSonyLink()
        linkState = .disconnected
        scheduleMultipointRecovery()
        return true
    }

    private func recoverClassicConnection() {
        guard !isSystemSleeping, powerOffState == nil, !isRunningHeadphoneTest, classicConnectionID == nil else { return }
        guard let targetAddress = recoveryClassicAddress ?? transitionAddress else {
            connectionModeError = String(localized: "The original Bluetooth connection is unavailable.")
            return
        }
        let logicalAddress = pinnedAddress ?? Self.normalizedAddress(targetAddress)
        #if DEBUG
        if isSimulated {
            address = logicalAddress
            isDeviceConnected = true
            beginHandshake()
            return
        }
        #endif
        let target: (any SonyBluetoothDevice)?
        if let transitionDevice, Self.normalizedAddress(transitionDevice.addressString ?? "") == Self.normalizedAddress(targetAddress) {
            target = transitionDevice
        } else {
            target = IOBluetoothDevice(addressString: targetAddress)
        }
        guard let target else {
            fail(String(localized: "The selected headphone connection is unavailable."))
            return
        }
        device = target
        address = logicalAddress
        deviceName = target.name ?? deviceName
        openClassicConnection(target, recovering: true)
    }

    private func openClassicConnection(_ target: any SonyBluetoothDevice, recovering: Bool) {
        guard let connection = beginClassicConnection(recovering: recovering) else { return }
        if target.isClassicConnected() {
            connection.complete(kIOReturnSuccess, true)
            return
        }
        let result = target.openConnection(connection)
        if result != kIOReturnSuccess { connection.complete(result, target.isClassicConnected()) }
    }

    private func beginClassicConnection(recovering: Bool) -> ClassicConnection? {
        guard !isSystemSleeping, classicConnectionID == nil else { return nil }
        let identifier = UUID()
        let session = controlSession
        linkState = .opening
        classicConnectionID = identifier
        let connection = ClassicConnection { [weak self] status, connected in
            guard let self else { return }
            self.classicConnections[identifier] = nil
            guard self.classicConnectionID == identifier, self.controlSession == session, !self.isSystemSleeping else { return }
            self.classicConnectionID = nil
            self.isDeviceConnected = connected
            guard status == kIOReturnSuccess || connected else {
                self.fail(recovering ? String(localized: "Could not reconnect the selected headphones.")
                    : String(localized: "No response. Check that the headphones are on."))
                return
            }
            if recovering { self.openSonyLink() }
            else {
                self.stage = .idle
                self.refresh()
            }
        }
        classicConnections[identifier] = connection
        return connection
    }

    @MainActor
    private final class ClassicConnection: NSObject {
        let complete: (IOReturn, Bool) -> Void

        init(complete: @escaping (IOReturn, Bool) -> Void) {
            self.complete = complete
        }

        @objc nonisolated
        func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            Task { @MainActor in complete(status, device.isClassicConnected()) }
        }
    }

    private func finishConnectionRecoveryFailure() {
        cancelScheduledRetry(resetAttempts: false)
        recoveryUsesBLE = nil
        connectionTransition?.recoveryFailed()
        updateConnectionModeTimeout()
        connectionModeError = String(localized: "Controls could not reconnect. Reconnect the selected headphones to check the mode.")
    }

    private func fail(_ message: String) {
        Self.logger.error("\(message, privacy: .private)")
        closeSonyLink()
        linkState = .failed(message)
        lastErrorMessage = message
        isApplyingChange = false
        scheduleRetry()
    }

    private func handleOpenFailure(_ error: IOReturn) {
        let message = String(localized: "Could not open the headphone connection. Try again.")
        Self.logger.error("Could not open headphone connection; status=\(error)")
        closeSonyLink()
        linkState = .controlBusy
        lastErrorMessage = message
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !isSystemSleeping, powerOffState == nil, !isRunningHeadphoneTest else {
            cancelScheduledRetry(resetAttempts: false)
            return
        }
        guard canRecoverDeviceAction else {
            cancelScheduledRetry(resetAttempts: false)
            return
        }
        if multipointTransition?.phase == .recovering {
            scheduleMultipointRecovery()
            return
        }
        if multipointTransition?.phase == .failed, multipointConnection != nil {
            cancelScheduledRetry(resetAttempts: false)
            return
        }
        guard connectionTransition?.phase != .failed, connectionTransition?.phase != .pairingRequired else {
            cancelScheduledRetry(resetAttempts: false)
            return
        }
        retryWorkItem?.cancel()
        if connectionTransition?.phase == .recovering || recoveryUsesBLE != nil {
            guard retryAttempt < 2, let transitionAddress, !transitionAddress.isEmpty else {
                finishConnectionRecoveryFailure()
                return
            }
            let preferred = recoveryUsesBLE ?? (connectionTransition?.targetMode == .lowLatency)
            let useBLE = connectionTransition?.generation == .v1 ? false : retryAttempt == 0 ? preferred : !preferred
            recoveryUsesBLE = preferred
            let delay = ReconnectBackoff.delay(forAttempt: retryAttempt)
            retryAttempt += 1
            nextRetryDate = Date().addingTimeInterval(delay)
            retrySecondsRemaining = Int(delay.rounded(.up))
            guard !isSimulated else { return }
            let request = connectionRequestID
            let session = controlSession
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, !self.isSystemSleeping, self.controlSession == session,
                          self.connectionRequestID == request else { return }
                    self.retryWorkItem = nil
                    self.nextRetryDate = nil
                    self.retrySecondsRemaining = nil
                    if useBLE, let hash = self.transitionHash {
                        self.openBluetoothLE(target: .verified(hash: hash, peripheralIdentifier: self.transitionPeripheralID), model: self.transitionModel)
                    } else {
                        self.recoverClassicConnection()
                    }
                }
            }
            retryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return
        }
        guard reconnectAutomatically, isDeviceConnected || lastReadyTransportWasBluetoothLE else {
            nextRetryDate = nil
            retrySecondsRemaining = nil
            return
        }
        let delay = ReconnectBackoff.delay(forAttempt: retryAttempt)
        retryAttempt += 1
        nextRetryDate = Date().addingTimeInterval(delay)
        retrySecondsRemaining = Int(delay.rounded(.up))
        guard !isSimulated else { return }
        let session = controlSession
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isSystemSleeping, self.controlSession == session,
                      self.reconnectAutomatically else { return }
                self.retryWorkItem = nil
                self.nextRetryDate = nil
                self.retrySecondsRemaining = nil
                self.refresh(shouldOpenLink: true)
            }
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledRetry(resetAttempts: Bool) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        nextRetryDate = nil
        retrySecondsRemaining = nil
        if resetAttempts { retryAttempt = 0 }
    }

    private func updateRetryCountdown() {
        let remaining = nextRetryDate.map { max(0, Int($0.timeIntervalSinceNow.rounded(.up))) }
        if retrySecondsRemaining != remaining { retrySecondsRemaining = remaining }
    }

    var firmwareUpdateSession: UInt64? {
        guard !isSimulated, stage == .ready, isDeviceConnected, powerOffState == nil, !isRunningHeadphoneTest,
              let model = deviceInformation.model, model != .unknown else { return nil }
        return controlSession
    }

    func requestFirmwareUpdateIdentity() {
        guard stage == .ready, isReady, isDeviceConnected, powerOffState == nil, !isRunningHeadphoneTest,
              firmwareUpdateIdentity == nil, firmwareUpdateQueries.isEmpty,
              let model = deviceInformation.model, model != .unknown else { return }
        let queries: [[UInt8]]
        switch protocolInformation?.generation {
        case .v1:
            guard legacyControls?.supportedFunctions.contains(0x30) == true else { return }
            queries = [[0x36, 0x02], [0x36, 0x03]]
        case .v2:
            guard let query = SonyFirmwareUpdateIdentity.request(supportedFunctions: supportedFunctions) else { return }
            queries = [query]
        case nil:
            return
        }
        for query in queries {
            firmwareUpdateQueries[query] = false
            send(query)
        }
    }

    private func receiveFirmwareUpdateIdentity(_ payload: [UInt8], type: UInt8) -> Bool {
        guard type == 0x0C, payload.count >= 2, payload[0] == 0x37,
              firmwareUpdateQueries[[0x36, payload[1]]] == true else { return false }
        if protocolInformation?.generation == .v1 {
            guard let value = SonyFirmwareUpdateIdentity.legacyValue(payload: payload, selector: payload[1]) else { return true }
            firmwareUpdateQueries[[0x36, payload[1]]] = false
            legacyFirmwareUpdateValues[payload[1]] = value
            if let category = legacyFirmwareUpdateValues[0x02], let service = legacyFirmwareUpdateValues[0x03] {
                firmwareUpdateIdentity = SonyFirmwareUpdateIdentity(categoryID: category, serviceID: service)
            }
        } else {
            guard let identity = SonyFirmwareUpdateIdentity(payload: payload, selector: payload[1]) else { return true }
            firmwareUpdateQueries[[0x36, payload[1]]] = false
            firmwareUpdateIdentity = identity
        }
        return true
    }

    private func resetFirmwareUpdateReads() {
        firmwareUpdateQueries = [:]
        legacyFirmwareUpdateValues = [:]
        firmwareUpdateIdentity = nil
    }

    private static func decodedFirmware(_ payload: [UInt8]) -> String? {
        guard payload.count > 3, payload[1] == 0x02, Int(payload[2]) == payload.count - 3 else { return nil }
        let value = String(bytes: payload.dropFirst(3), encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func parseFirmware(_ payload: [UInt8]) {
        guard let value = Self.decodedFirmware(payload) else { return }
        firmwareVersion = value
        lastSyncDate = Date()
        Self.logger.info("Firmware ready; version=\(value, privacy: .public)")
    }

    @objc nonisolated
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel, status error: IOReturn) {
        Task { @MainActor in classicChannelOpenComplete(rfcommChannel, status: error) }
    }

    func classicChannelOpenComplete(_ rfcommChannel: any RFCOMMChannel, status error: IOReturn) {
        guard channel === rfcommChannel else { return }
        guard error == kIOReturnSuccess else {
            handleOpenFailure(error)
            return
        }
        channel = rfcommChannel
        beginHandshake()
    }

    @objc nonisolated
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel, data dataPointer: UnsafeMutableRawPointer, length dataLength: Int) {
        let copied = Data(bytes: dataPointer, count: dataLength)
        DispatchQueue.main.async { self.classicChannelData(rfcommChannel, data: copied) }
    }

    func classicChannelData(_ rfcommChannel: any RFCOMMChannel, data: Data) {
        guard channel === rfcommChannel else { return }
        receiveClassic(data)
    }

    @objc nonisolated
    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel,
                                    refcon: UnsafeMutableRawPointer?, status: IOReturn) {
        guard let refcon else { return }
        let identifier = UInt(bitPattern: refcon)
        DispatchQueue.main.async { self.classicChannelWriteComplete(rfcommChannel, identifier: identifier, status: status) }
    }

    func classicChannelWriteComplete(_ rfcommChannel: any RFCOMMChannel, identifier: UInt?, status: IOReturn) {
        guard let identifier, let write = classicWrites.removeValue(forKey: identifier) else { return }
        write.timeout.cancel()
        guard channel === rfcommChannel, controlSession == write.session else { return }
        guard status == kIOReturnSuccess else {
            fail(String(localized: "Could not send to headphones (\(status))"))
            return
        }
        write.completion()
        drainClassicIncomingData(rfcommChannel, session: write.session)
    }

    private func drainClassicIncomingData(_ rfcommChannel: any RFCOMMChannel, session: UInt64) {
        guard channel === rfcommChannel, controlSession == session,
              !classicIncomingData.isEmpty,
              !classicWrites.values.contains(where: { $0.session == controlSession && $0.waitsForResponse }) else { return }
        let pending = classicIncomingData
        classicIncomingData.removeAll(keepingCapacity: false)
        classicIncomingDataLength = 0
        for received in pending {
            guard controlSession == session else { return }
            receive(received.data, transmissionID: received.transmissionID)
        }
    }

    @objc nonisolated
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        DispatchQueue.main.async { self.classicChannelClosed(rfcommChannel) }
    }

    func classicChannelClosed(_ rfcommChannel: any RFCOMMChannel) {
        for (identifier, write) in classicWrites where write.channel === rfcommChannel {
            write.timeout.cancel()
            classicWrites[identifier] = nil
        }
        guard channel === rfcommChannel else { return }
        closeSonyLink()
        isDeviceConnected = device?.isClassicConnected() ?? false
        Self.logger.info("Sony control link closed; Classic connected at callback=\(self.isDeviceConnected)")
        if isDeviceConnected {
            linkState = .controlBusy
            lastErrorMessage = String(localized: "The headphone controls disconnected.")
            scheduleRetry()
        } else {
            linkState = .disconnected
            if multipointTransition?.phase == .recovering || connectionTransition?.phase == .recovering || recoveryUsesBLE != nil {
                scheduleRetry()
            }
        }
    }
}
