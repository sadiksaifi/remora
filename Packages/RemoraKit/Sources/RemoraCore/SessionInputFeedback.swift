import Foundation

public enum InputSource: Sendable { case human, agent }

/// Input admitted to the remote transport, after local shortcut and ownership policy.
public enum SessionInputFeedback: Sendable {
    case pointer(RemotePoint, PointerButtons)
    case key(scancode: UInt32, down: Bool, characters: String? = nil)
    case text(String)
    case release
}
