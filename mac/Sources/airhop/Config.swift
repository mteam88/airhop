import Foundation

/// Settings from ~/.config/airhop/mac.toml (flat `key = value` subset of TOML).
/// airpods_address, mac_suffix and pixel_suffix are per-setup and have no useful default.
struct Config {
    var airpodsAddress = ""
    var airpodsModel: UInt16 = 0x2720
    /// Last 3 bytes (hex) of this Mac's and the phone's BT addresses, as seen in the advert's holder field.
    var macSuffix = ""
    var pixelSuffix = ""
    /// Other holder suffixes that mark an advert as ours (e.g. "nobody holds them").
    var extraSuffixes = ["000000"]
    /// Processes whose mic use is not a call (bundle-ID prefixes).
    var ignoreInputBundles = [
        "com.apple.siri", "com.apple.assistantd", "com.apple.corespeechd",
        "com.apple.SpeechRecognitionCore", "com.apple.accessibility.heard",
        "com.apple.dictation", "com.apple.controlcenter", "com.electron.wispr-flow",
    ]
    var mediaControl = "/opt/homebrew/bin/media-control"

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/airhop/mac.toml")

    static func load() -> Config {
        var c = Config()
        for (key, value) in readTOML(path) {
            let str = unquote(value)
            let list = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
            switch key {
            case "airpods_address": c.airpodsAddress = str
            case "airpods_model": c.airpodsModel = UInt16(str, radix: 16) ?? c.airpodsModel
            case "mac_suffix": c.macSuffix = str.lowercased()
            case "pixel_suffix": c.pixelSuffix = str.lowercased()
            case "extra_suffixes": c.extraSuffixes = list.map { $0.lowercased() }
            case "ignore_input_bundles": c.ignoreInputBundles = list
            case "media_control": c.mediaControl = str
            default: log("config: unknown key \(key)")
            }
        }
        return c
    }
}

/// Reads flat `key = value` lines (the subset of TOML our config files use); values are raw.
func readTOML(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: String] = [:]
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { result[parts[0]] = parts[1] }
    }
    return result
}

func unquote(_ s: String) -> String {
    s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
}

enum Paths {
    static let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/airhop")
    static let status = stateDir.appending(path: "status.json")
    static let disabledFlag = stateDir.appending(path: "disabled")
    static let secrets = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/airhop/secrets.toml")
}

private let timestampFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func timestamp(_ date: Date = .now) -> String { timestampFormat.string(from: date) }

func log(_ message: String) {
    print("\(timestamp()) \(message)")
    fflush(stdout)
}
