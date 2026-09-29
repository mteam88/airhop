import AppKit
import CoreBluetooth
import IOBluetooth

/// Snapshot written to Paths.status for `airhop status`.
struct Status: Codable {
    var pid: Int32
    var updated: Date
    var enabled: Bool
    var dryRun: Bool
    var connectedToMac: Bool
    var holder: String?
    var ble: String?
    var bleAgeSeconds: Double?
    var rssi: Int?
    var nowPlaying: Bool
    var nowPlayingApp: String
    var micApps: [String]
    var events: [String]
}

/// The autonomous agent: takes the AirPods on local intent (play / mic), pauses when they're
/// taken away mid-playback, and releases them on sleep or when the phone beacons that it's taking them.
@MainActor final class Agent: NSObject {
    static let changedNotification = Notification.Name("com.mteam.airhop.changed")
    private static let takeCooldown: TimeInterval = 3
    private static let bleStaleAfter: TimeInterval = 10
    private static let beaconDedupe: TimeInterval = 3

    private let config: Config
    private let dryRun: Bool
    private let device: IOBluetoothDevice
    private let scanner: AirPodsScanner
    private let media: NowPlaying
    private let mic: MicMonitor
    private let advertiser = BeaconAdvertiser()

    private var ble: AirPodsAdvert?
    private var bleSeen = Date.distantPast
    private var rssi = 0
    private var connected = false
    private var busy = false
    private var lastTake = Date.distantPast
    private var ignoreMediaUntil = Date.distantPast
    private var expectingDisconnect = false
    private var pausedForLoss = false
    private var disconnectNote: IOBluetoothUserNotification?
    private var beaconLastSeen: [CBUUID: Date] = [:]
    private var events: [String] = []

    init(config: Config, dryRun: Bool) {
        self.config = config
        self.dryRun = dryRun
        guard let device = IOBluetoothDevice(addressString: config.airpodsAddress) else {
            fatalError("invalid airpods_address \(config.airpodsAddress)")
        }
        self.device = device
        scanner = AirPodsScanner(config: config)
        media = NowPlaying(tool: config.mediaControl)
        mic = MicMonitor(ignore: config.ignoreInputBundles)
        super.init()
    }

    private var enabled: Bool { !FileManager.default.fileExists(atPath: Paths.disabledFlag.path) }
    private var freshBLE: AirPodsAdvert? { Date.now.timeIntervalSince(bleSeen) < Self.bleStaleAfter ? ble : nil }

    private func beacon(_ sender: String, _ kind: Beacon.Kind) -> CBUUID? {
        Beacon.key.map { Beacon.uuid(sender: sender, kind, key: $0) }
    }

    private func holderName(_ suffix: String) -> String {
        switch suffix {
        case config.macSuffix: "mac"
        case config.pixelSuffix: "pixel"
        default: suffix
        }
    }

    func start() {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        event("starting (enabled=\(enabled) dryRun=\(dryRun) airpods=\(config.airpodsAddress) name='\(device.name ?? "?")')")

        scanner.onAdvert = { [self] ad, rssi in bleUpdate(ad, rssi: rssi) }
        scanner.watchedBeacons = Set(Beacon.Kind.allCases.compactMap { beacon("pixel", $0) })
        scanner.onBeacon = { [self] uuid, rssi in beaconReceived(uuid, rssi: rssi) }
        if Beacon.key == nil { event("no enc_key in \(Paths.secrets.path); beacons disabled") }
        scanner.onUnauthorized = { [self] in
            event("Bluetooth permission denied — grant Airhop access in System Settings > Privacy & Security > Bluetooth")
        }

        media.onChange = { [self] playing, app in mediaChanged(playing, app: app) }
        media.start()

        mic.onChange = { [self] _, started in
            if !started.isEmpty { take(reason: "mic input by \(started.sorted().joined(separator: ","))", resumeMedia: false) }
        }
        mic.start()

        setConnected(device.isConnected())
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [self] _ in
            MainActor.assumeIsolated { willSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [self] _ in
            MainActor.assumeIsolated { event("woke (connected=\(device.isConnected()))") }
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.changedNotification, object: nil, queue: .main) {
            [self] _ in MainActor.assumeIsolated { event(enabled ? "enabled" : "disabled") }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [self] _ in
            MainActor.assumeIsolated { writeStatus() }
        }
    }

    // MARK: Intent: take the AirPods

    private func mediaChanged(_ playing: Bool, app: String) {
        let ours = busy || Date.now < ignoreMediaUntil
        log("media: \(playing ? "playing" : "paused") (\(app.isEmpty ? "-" : app))\(ours ? " [self-inflicted]" : "")")
        if playing && !ours { take(reason: "now playing \(app)", resumeMedia: true) }
    }

    private func take(reason: String, resumeMedia: Bool) {
        guard !connected, !busy else { return }
        guard enabled else { return event("\(reason): disabled, not taking") }
        guard let ad = freshBLE else { return event("\(reason): no fresh BLE state, not taking") }
        guard ad.worn else { return event("\(reason): AirPods not worn, not taking") }
        guard Date.now.timeIntervalSince(lastTake) > Self.takeCooldown else {
            return event("\(reason): within take cooldown, not taking")
        }
        busy = true
        lastTake = .now
        event("TAKE (\(reason)): holder=\(holderName(ad.holder)) conn=\(ad.connStateName)")
        if resumeMedia { perform("pause") }
        sendBeacon(.take)
        // Give the phone a moment to release cooperatively before we page the AirPods.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in connect(resumeMedia: resumeMedia) }
    }

    private func connect(resumeMedia: Bool) {
        if dryRun {
            event("[dry-run] would openConnection, wait for AirPods output\(resumeMedia ? ", then play" : "")")
            busy = false
            return
        }
        let t0 = Date.now
        let result = device.openConnection()
        event("openConnection -> \(result) (\(ms(since: t0)))")
        // openConnection can return before IOBluetooth reports the link as up.
        waitForConnection(started: t0, ok: result == kIOReturnSuccess) { [self] in
            guard connected else {
                busy = false
                return event("take failed\(resumeMedia ? "; leaving media paused" : "")")
            }
            waitForOutput(started: t0) { [self] in
                if resumeMedia { perform("play") }
                ignoreMediaUntil = .now + 2
                busy = false
            }
        }
    }

    private func waitForConnection(started: Date, ok: Bool, done: @escaping () -> Void) {
        setConnected(device.isConnected())
        if connected || !ok || Date.now.timeIntervalSince(started) > 3 { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForConnection(started: started, ok: ok, done: done) }
    }

    /// Polls the default output device until it's the AirPods (or ~5s pass), then calls `done`.
    private func waitForOutput(started: Date, done: @escaping () -> Void) {
        let addr = config.airpodsAddress.uppercased().replacingOccurrences(of: ":", with: "-")
        if let out = OutputDevice.current(), out.bluetooth, out.uid.uppercased().contains(addr) || out.name.contains("AirPods") {
            event("output is '\(out.name)' (\(out.uid)) after \(ms(since: started))")
            return done()
        }
        if Date.now.timeIntervalSince(started) > 5 {
            event("output still '\(OutputDevice.current()?.name ?? "?")' after 5s; resuming anyway")
            return done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.waitForOutput(started: started, done: done) }
    }

    // MARK: BLE state

    private func bleUpdate(_ ad: AirPodsAdvert, rssi: Int) {
        let previous = freshBLE
        ble = ad
        bleSeen = .now
        self.rssi = rssi
        // Holder/conn lag real connection changes by several seconds, so they're informational only.
        guard previous?.worn != ad.worn || previous?.connState != ad.connState || previous?.holder != ad.holder else { return }
        log("ble: \(ad.summary.replacingOccurrences(of: "holder=\(ad.holder)", with: "holder=\(holderName(ad.holder))")) rssi=\(rssi)")
    }

    // MARK: Loss: someone else took them (IOBluetooth disconnect we didn't cause)

    private func pauseForLoss(_ reason: String) {
        guard !pausedForLoss, !expectingDisconnect, !busy else { return }
        guard media.playing else { return event("lost AirPods (\(reason)); media not playing") }
        guard enabled else { return event("lost AirPods (\(reason)); disabled, not pausing") }
        pausedForLoss = true
        event("LOST AirPods (\(reason)) while \(media.bundleID) playing -> pause")
        perform("pause")
    }

    // IOBluetooth delivers these on its own thread; hop to the main actor before touching state.
    @objc nonisolated private func deviceConnected(_ note: IOBluetoothUserNotification, device d: IOBluetoothDevice) {
        let address = d.addressString?.lowercased()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onConnect(address: address) } }
    }

    @objc nonisolated private func deviceDisconnected(_ note: IOBluetoothUserNotification, device d: IOBluetoothDevice) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onDisconnect() } }
    }

    private func onConnect(address: String?) {
        guard address == device.addressString?.lowercased() else { return }
        setConnected(true)
    }

    private func onDisconnect() {
        setConnected(false)
        if expectingDisconnect {
            expectingDisconnect = false
        } else {
            pauseForLoss("bluetooth disconnect")
        }
    }

    private func setConnected(_ value: Bool) {
        if value && disconnectNote == nil {
            disconnectNote = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        } else if !value {
            disconnectNote?.unregister()
            disconnectNote = nil
        }
        guard value != connected else { return }
        connected = value
        if value { pausedForLoss = false; expectingDisconnect = false }
        event("AirPods \(value ? "connected to" : "disconnected from") Mac")
    }

    // MARK: Release: hand them back (sleep, or the phone says it's taking them)

    private func willSleep() {
        guard device.isConnected() else { return event("sleeping (AirPods not connected)") }
        guard enabled else { return event("sleeping; disabled, keeping AirPods") }
        event("sleeping -> release")
        sendBeacon(.release)
        release()
    }

    private func beaconReceived(_ uuid: CBUUID, rssi: Int) {
        guard Date.now.timeIntervalSince(beaconLastSeen[uuid] ?? .distantPast) > Self.beaconDedupe else { return }
        beaconLastSeen[uuid] = .now
        guard uuid == beacon("pixel", .take) else { return event("beacon: pixel release received (rssi \(rssi)); ignored") }
        guard connected else { return event("beacon: pixel take received (rssi \(rssi)); AirPods not on Mac") }
        guard enabled else { return event("beacon: pixel take received; disabled, keeping AirPods") }
        guard !busy else { return event("beacon: pixel take received mid-take; ignoring") }
        event("beacon: pixel take received (rssi \(rssi)) -> \(media.playing ? "pause + " : "")release")
        if media.playing { perform("pause") }
        release()
    }

    private func release() {
        if dryRun { return event("[dry-run] would closeConnection") }
        expectingDisconnect = true
        let t0 = Date.now
        let result = device.closeConnection()
        event("closeConnection -> \(result) (\(ms(since: t0)))")
    }

    // MARK: Helpers

    private func perform(_ command: String) {
        if dryRun { return event("[dry-run] would media-control \(command)") }
        media.send(command)
    }

    private func sendBeacon(_ kind: Beacon.Kind) {
        guard let uuid = beacon("mac", kind) else { return }
        advertiser.advertise(uuid, label: "mac/\(kind.rawValue)")
    }

    private func ms(since t: Date) -> String { "\(Int(Date.now.timeIntervalSince(t) * 1000))ms" }

    private func event(_ message: String) {
        log(message)
        events.append("\(timestamp()) \(message)")
        if events.count > 20 { events.removeFirst(events.count - 20) }
        writeStatus()
    }

    private func writeStatus() {
        let ad = freshBLE
        let status = Status(
            pid: getpid(), updated: .now, enabled: enabled, dryRun: dryRun, connectedToMac: connected,
            holder: ad.map { holderName($0.holder) }, ble: ad?.summary,
            bleAgeSeconds: ble == nil ? nil : (Date.now.timeIntervalSince(bleSeen) * 10).rounded() / 10,
            rssi: ad == nil ? nil : rssi, nowPlaying: media.playing, nowPlayingApp: media.bundleID,
            micApps: mic.active.sorted(), events: events)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(status).write(to: Paths.status, options: .atomic)
    }
}
