import AppKit
import CoreBluetooth

let usage = """
    usage: airhop [run] [--dry-run]   run the agent (what the LaunchAgent does)
           airhop status              show the running agent's state and last 20 events
           airhop enable | disable    toggle the running agent
           airhop scan [seconds]      print our AirPods' BLE adverts and airhop beacons (default 15s)
           airhop beacons             print the beacon UUIDs derived from secrets.toml
           airhop beacon take|release [seconds]   advertise a mac beacon (default 10s)
           airhop mics                list CoreAudio processes and their input/output activity
    """

let args = Array(CommandLine.arguments.dropFirst())
let config = Config.load()

switch args.first {
case nil, "run", "--dry-run":
    let agent = Agent(config: config, dryRun: args.contains("--dry-run"))
    agent.start()
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()

case "status":
    guard let data = try? Data(contentsOf: Paths.status) else {
        print("no status file at \(Paths.status.path) — has the agent run?")
        exit(1)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let s = try decoder.decode(Status.self, from: data)
    let alive = kill(s.pid, 0) == 0
    print("""
        agent:      \(alive ? "running" : "NOT running") (pid \(s.pid), updated \(timestamp(s.updated)))\(s.dryRun ? " [dry-run]" : "")
        enabled:    \(!FileManager.default.fileExists(atPath: Paths.disabledFlag.path))
        connected:  \(s.connectedToMac) (to this Mac)
        holder:     \(s.holder ?? "unknown (no fresh BLE)")
        ble:        \(s.ble.map { "\($0) rssi=\(s.rssi ?? 0) age=\(s.bleAgeSeconds ?? 0)s" } ?? "stale / not seen")
        media:      \(s.nowPlaying ? "playing" : "not playing") \(s.nowPlayingApp)
        mic:        \(s.micApps.isEmpty ? "-" : s.micApps.joined(separator: ", "))
        events:
        """)
    s.events.forEach { print("  \($0)") }

case "enable", "disable":
    try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
    if args[0] == "enable" {
        try? FileManager.default.removeItem(at: Paths.disabledFlag)
    } else {
        FileManager.default.createFile(atPath: Paths.disabledFlag.path, contents: nil)
    }
    DistributedNotificationCenter.default().postNotificationName(Agent.changedNotification, object: nil,
                                                                 deliverImmediately: true)
    print("airhop \(args[0])d")

case "scan":
    let seconds = args.dropFirst().first.flatMap(Double.init) ?? 15
    let scanner = AirPodsScanner(config: config)
    var last: AirPodsAdvert?
    scanner.onAdvert = { ad, rssi in
        if ad != last { log("\(ad.summary) status=0x\(String(ad.status, radix: 16)) rssi=\(rssi)") }
        last = ad
    }
    var names: [CBUUID: String] = [:]
    if let key = Beacon.key {
        for sender in ["mac", "pixel"] {
            for kind in Beacon.Kind.allCases { names[Beacon.uuid(sender: sender, kind, key: key)] = "\(sender)/\(kind)" }
        }
    }
    scanner.watchedBeacons = Set(names.keys)
    scanner.onBeacon = { uuid, rssi in log("beacon \(names[uuid] ?? "?") seen rssi=\(rssi)") }
    RunLoop.main.run(until: .now + seconds)

case "beacons", "beacon":
    guard let key = Beacon.key else {
        print("no enc_key in \(Paths.secrets.path)")
        exit(1)
    }
    if args[0] == "beacons" {
        for sender in ["mac", "pixel"] {
            for kind in Beacon.Kind.allCases { print("\(sender)/\(kind): \(Beacon.uuid(sender: sender, kind, key: key).lowercased)") }
        }
    } else {
        guard let kind = args.dropFirst().first.flatMap(Beacon.Kind.init(rawValue:)) else {
            print(usage)
            exit(2)
        }
        let seconds = args.dropFirst(2).first.flatMap(Double.init) ?? 10
        let advertiser = BeaconAdvertiser()
        RunLoop.main.run(until: .now + 1)  // let the peripheral manager power on
        advertiser.advertise(Beacon.uuid(sender: "mac", kind, key: key), label: "mac/\(kind)", seconds: seconds)
        RunLoop.main.run(until: .now + seconds + 0.2)
    }

case "mics":
    MicMonitor.describeProcesses().forEach { print($0) }

default:
    print(usage)
    exit(args.first == "help" || args.first == "--help" ? 0 : 2)
}
