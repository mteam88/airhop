import CoreAudio
import Foundation

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

private func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

private func getObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

/// Describes the current default output device, e.g. to confirm the AirPods took over.
struct OutputDevice {
    var name: String
    var uid: String
    var bluetooth: Bool

    static func current() -> OutputDevice? {
        guard let id = getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                AudioDeviceID(0)), id != 0
        else { return nil }
        let transport = getValue(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
        return OutputDevice(name: getString(id, kAudioObjectPropertyName),
                            uid: getString(id, kAudioDevicePropertyDeviceUID),
                            bluetooth: transport == kAudioDeviceTransportTypeBluetooth
                                || transport == kAudioDeviceTransportTypeBluetoothLE)
    }
}

/// Watches CoreAudio process objects and reports which apps are capturing microphone input.
final class MicMonitor {
    private let ignore: [String]
    private var watched = Set<AudioObjectID>()
    /// Bundle IDs currently running input (after filtering).
    private(set) var active = Set<String>()
    private var ignoredActive = Set<String>()
    var onChange: (_ active: Set<String>, _ started: Set<String>) -> Void = { _, _ in }

    init(ignore: [String]) { self.ignore = ignore }

    func start() {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            MainActor.assumeIsolated { self.refresh() }
        }
        refresh()
    }

    /// Lists every audio process with its input/output activity (for `airhop mics`).
    static func describeProcesses() -> [String] {
        getObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { p in
            let pid = getValue(p, kAudioProcessPropertyPID, pid_t(0)) ?? 0
            let bundle = getString(p, kAudioProcessPropertyBundleID)
            let input = getValue(p, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0
            let output = getValue(p, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0
            return "pid=\(pid) input=\(input) output=\(output) \(bundle.isEmpty ? "(no bundle id)" : bundle)"
        }
    }

    private func refresh() {
        let processes = getObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        for p in processes where !watched.contains(p) {
            watched.insert(p)
            var addr = address(kAudioProcessPropertyIsRunningInput)
            AudioObjectAddPropertyListenerBlock(p, &addr, .main) { _, _ in
                MainActor.assumeIsolated { self.refresh() }
            }
        }
        watched.formIntersection(processes)  // dead process objects drop their listeners with them

        var now = Set<String>(), ignored = Set<String>()
        for p in processes where getValue(p, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 {
            let pid = getValue(p, kAudioProcessPropertyPID, pid_t(0)) ?? 0
            let bundle = getString(p, kAudioProcessPropertyBundleID)
            if pid == getpid() { continue }
            if bundle.isEmpty || ignore.contains(where: { bundle.hasPrefix($0) }) {
                ignored.insert("\(pid):\(bundle)")
            } else {
                now.insert(bundle)
            }
        }
        if ignored != ignoredActive {
            log("mic: ignored input processes \(ignoredActive.sorted()) -> \(ignored.sorted())")
            ignoredActive = ignored
        }
        guard now != active else { return }
        let started = now.subtracting(active)
        log("mic: input processes \(active.sorted()) -> \(now.sorted())")
        active = now
        onChange(now, started)
    }
}
