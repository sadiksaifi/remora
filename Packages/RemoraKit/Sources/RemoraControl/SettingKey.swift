public enum SettingKey: String, CaseIterable, Sendable {
    case captureSystemShortcuts, showAgentPointer, saveLocation

    public var valueHelp: String {
        switch self {
        case .saveLocation: "string: an absolute folder path, or empty for the macOS screenshot location"
        default: "boolean: true or false"
        }
    }
}
