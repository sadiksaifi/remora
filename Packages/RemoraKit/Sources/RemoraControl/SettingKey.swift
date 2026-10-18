public enum SettingKey: String, CaseIterable, Sendable {
    case captureSystemShortcuts, showAgentPointer, showPointerInRecordings, showKeyPresses, keyPressSize, saveLocation

    public var valueHelp: String {
        switch self {
        case .saveLocation: "string: an absolute folder path, or empty for the macOS screenshot location"
        case .showAgentPointer: "boolean: draw the agent's cursor on screen"
        case .keyPressSize: "number: the key press display's size, from 0.75 to 2, where 1 is the standard size"
        default: "boolean: true or false"
        }
    }
}
