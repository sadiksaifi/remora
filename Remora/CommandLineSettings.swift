import AppKit
import RemoraControl
import RemoraCore

extension CommandLineController {
    func handleSettings(_ request: ControlRequest) throws -> ControlValue {
        switch request.command {
        case "settings.get", "settings.set", "settings.reset":
            try request.validateArguments(request.command == "settings.set" ? ["key", "value"] : ["key"])
            let key = try request.string("key", required: request.command == "settings.set")
            let keys = try key.map { [try SettingKey($0)] } ?? SettingKey.allCases
            if request.command == "settings.set" {
                try AppSettings.set(keys[0], value: request.string("value", required: true)!)
            } else if request.command == "settings.reset" {
                for key in keys { UserDefaults.standard.removeObject(forKey: key.defaultsKey) }
            }
            return .object(Dictionary(uniqueKeysWithValues: keys.map { ($0.rawValue, AppSettings.value($0)) }))
        case "settings.permission":
            try request.validateArguments(["open"])
            let open = try request.flag("open")
            if open { SystemShortcutCapture.openAccessibilitySettings() }
            return .object(["accessibility": .string(SystemShortcutCapture.isTrusted ? "allowed" : "notAllowed"), "opened": .bool(open)])
        default: throw ControlFailure(.unknownCommand, "Unknown settings command.")
        }
    }
}

extension SettingKey {
    init(_ name: String) throws {
        guard let key = Self(rawValue: name) else {
            throw ControlFailure(
                .invalidArgument, "Unknown setting '\(name)'.",
                hint: "Use \(Self.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        self = key
    }
    var defaultsKey: String {
        switch self {
        case .captureSystemShortcuts: SystemShortcutCapture.enabledKey
        case .showAgentPointer: AppSettings.showAgentPointerKey
        case .showPointerInRecordings: AppSettings.showPointerInRecordingsKey
        case .showKeyPresses: AppSettings.showKeyPressesKey
        case .keyPressSize: AppSettings.keyPressSizeKey
        case .saveLocation: AppSettings.saveLocationKey
        }
    }
}

extension AppSettings {
    static func value(_ key: SettingKey) -> ControlValue {
        if key == .saveLocation { return .string(UserDefaults.standard.string(forKey: key.defaultsKey) ?? "") }
        if key == .keyPressSize { return .number(keyPressSize) }
        return .bool(UserDefaults.standard.object(forKey: key.defaultsKey) as? Bool ?? (key != .showKeyPresses))
    }

    static func set(_ key: SettingKey, value: String) throws {
        if key == .saveLocation {
            guard value.isEmpty || (value.hasPrefix("/") && !value.utf8.contains(0)) else {
                throw ControlFailure(.invalidArgument, "saveLocation must be an absolute folder path, or empty for the macOS screenshot location.")
            }
            UserDefaults.standard.set(value, forKey: key.defaultsKey)
        } else if key == .keyPressSize {
            guard let size = Double(value), KeyPressPill.sizes.contains(size) else {
                throw ControlFailure(.invalidArgument, "keyPressSize must be a number from 0.75 to 2, where 1 is the standard size.")
            }
            UserDefaults.standard.set(size, forKey: key.defaultsKey)
        } else {
            guard value == "true" || value == "false" else { throw ControlFailure(.invalidArgument, "\(key.rawValue) must be true or false.") }
            UserDefaults.standard.set(value == "true", forKey: key.defaultsKey)
        }
    }
}
