import CoreBluetooth
import Foundation

/// One decoded proximity-pairing advert (Apple manufacturer data, TLV type 0x07).
struct AirPodsAdvert: Equatable {
    var model: UInt16
    var status: UInt8
    var connState: UInt8
    var leftInEar: Bool
    var rightInEar: Bool
    var left: UInt8, right: UInt8, caseBattery: UInt8  // raw payload bytes; 0xff = unknown, 0x80 = charging
    var holder: String  // hex of last 3 BT-address bytes of the device holding the AirPods

    var worn: Bool { leftInEar || rightInEar }

    var connStateName: String {
        switch connState {
        case 0x00: "disconnected"
        case 0x04: "idle"
        case 0x05: "music"
        case 0x06: "call"
        case 0x07: "ringing"
        case 0x09: "hanging-up"
        default: String(format: "0x%02x", connState)
        }
    }

    /// Parses manufacturer data as delivered by CoreBluetooth; the payload is only
    /// decrypted (and thus meaningful) for AirPods paired to this Mac.
    init?(_ b: [UInt8]) {
        guard b.count >= 20, b[0] == 0x4c, b[1] == 0x00, b[2] == 0x07, b[3] == 0x19 else { return nil }
        model = UInt16(b[5]) << 8 | UInt16(b[6])
        status = b[7]
        connState = b[12]
        let primaryLeft = (status >> 5) & 1, thisInCase = (status >> 6) & 1
        let flipped = primaryLeft ^ thisInCase == 1
        leftInEar = status & (flipped ? 0x08 : 0x02) != 0
        rightInEar = status & (flipped ? 0x02 : 0x08) != 0
        left = b[14]; right = b[15]; caseBattery = b[16]
        holder = b[17...19].map { String(format: "%02x", $0) }.joined()
    }

    var batteriesPlausible: Bool {
        [left, right, caseBattery].allSatisfy { $0 == 0xff || $0 & 0x7f <= 100 }
    }

    static func battery(_ v: UInt8) -> String {
        v == 0xff ? "?" : "\(v & 0x7f)%\(v & 0x80 != 0 ? "+" : "")"
    }

    var summary: String {
        "worn=\(worn) (L=\(leftInEar) R=\(rightInEar)) conn=\(connStateName) holder=\(holder) "
            + "batt L\(Self.battery(left)) R\(Self.battery(right)) C\(Self.battery(caseBattery))"
    }
}

/// Scans BLE continuously and reports adverts that belong to our AirPods, plus watched beacon UUIDs.
@MainActor final class AirPodsScanner: NSObject {
    private let config: Config
    private let knownHolders: Set<String>
    private var central: CBCentralManager!
    /// Peripheral identifier of the last advert we positively identified; lets us keep
    /// tracking our AirPods if they report a holder suffix we don't know yet.
    private var ourPeripheral: UUID?
    var onAdvert: (AirPodsAdvert, _ rssi: Int) -> Void = { _, _ in }
    var watchedBeacons: Set<CBUUID> = []
    var onBeacon: (CBUUID, _ rssi: Int) -> Void = { _, _ in }
    var onUnauthorized: () -> Void = {}

    init(config: Config) {
        self.config = config
        knownHolders = Set(([config.macSuffix, config.pixelSuffix] + config.extraSuffixes).filter { !$0.isEmpty })
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
}

extension AirPodsScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("ble: powered on, scanning")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .unauthorized:
            log("ble: UNAUTHORIZED (authorization=\(CBCentralManager.authorization.rawValue)) — allow Airhop under System Settings > Privacy & Security > Bluetooth")
            onUnauthorized()
        default:
            log("ble: state \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        for uuid in services where watchedBeacons.contains(uuid) { onBeacon(uuid, RSSI.intValue) }

        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let ad = AirPodsAdvert([UInt8](data)),
              ad.model == config.airpodsModel, ad.batteriesPlausible
        else { return }
        if knownHolders.contains(ad.holder) {
            ourPeripheral = peripheral.identifier
        } else if peripheral.identifier != ourPeripheral {
            return
        }
        onAdvert(ad, RSSI.intValue)
    }
}
