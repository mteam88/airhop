import Foundation

/// Tracks system Now Playing via a long-lived `media-control stream` subprocess, restarted if it dies.
final class NowPlaying {
    private let tool: String
    private var process: Process?
    private var buffer = Data()
    private(set) var playing = false
    private(set) var bundleID = ""
    /// Called on every playing-state change with the new value.
    var onChange: (_ playing: Bool, _ bundleID: String) -> Void = { _, _ in }

    init(tool: String) { self.tool = tool }

    func start() {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = ["stream", "--no-diff", "--no-artwork"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.consume(chunk) } }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    log("media: stream exited (\(proc.terminationStatus)), restarting in 2s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            log("media: failed to launch \(tool): \(error); retrying in 10s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.start() }
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }
            let isPlaying = (payload["playing"] as? Bool) ?? (((payload["playbackRate"] as? Double) ?? 0) > 0)
            bundleID = payload["bundleIdentifier"] as? String ?? ""
            if isPlaying != playing {
                playing = isPlaying
                onChange(isPlaying, bundleID)
            }
        }
    }

    /// Runs a one-shot command (`play` / `pause`) and waits for it, so e.g. a pause lands before we drop the AirPods.
    func send(_ command: String) {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = [command]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            log("media: \(command) failed: \(error)")
        }
    }
}
