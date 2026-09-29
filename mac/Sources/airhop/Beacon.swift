import CoreBluetooth
import CryptoKit
import Foundation

/// Side channel between Mac and phone: a legacy BLE advert carrying one 128-bit service UUID,
/// uuid = SHA256("airhop/v1/<sender>/<kind>/<enc_key hex>")[0..<16].
enum Beacon {
    enum Kind: String, CaseIterable { case take, release }

    /// `enc_key` from secrets.toml, or nil if missing.
    static let key: String? = readTOML(Paths.secrets)["enc_key"].map { unquote($0).lowercased() }

    static func uuid(sender: String, _ kind: Kind, key: String) -> CBUUID {
        let digest = Data(SHA256.hash(data: Data("airhop/v1/\(sender)/\(kind.rawValue)/\(key)".utf8)))
        let bytes = digest.prefix(16).withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return CBUUID(nsuuid: UUID(uuid: bytes))
    }
}

extension CBUUID {
    var lowercased: String { uuidString.lowercased() }
}

/// Advertises beacons via CBPeripheralManager.
@MainActor final class BeaconAdvertiser: NSObject {
    private var manager: CBPeripheralManager!
    private var stop: DispatchWorkItem?

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func advertise(_ uuid: CBUUID, label: String, seconds: TimeInterval = 3) {
        guard manager.state == .poweredOn else {
            return log("beacon: can't send \(label), peripheral manager state \(manager.state.rawValue)")
        }
        manager.stopAdvertising()
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])
        log("beacon: sending \(label) (\(uuid.lowercased)) for \(seconds)s")
        stop?.cancel()
        let work = DispatchWorkItem { [self] in manager.stopAdvertising() }
        stop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

extension BeaconAdvertiser: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log("beacon: peripheral manager state \(peripheral.state.rawValue)")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        log(error.map { "beacon: advertising failed: \($0.localizedDescription)" } ?? "beacon: advertising started")
    }
}
