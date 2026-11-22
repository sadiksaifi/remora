import Foundation

/// Clipboard state for one session attempt. Revisions order notifications from channel workers.
/// A new offer invalidates old text, including an offer with no text format.
public struct RemoteClipboard: Sendable {
    public enum Format: String, CaseIterable, Sendable {
        case text = "public.utf8-plain-text"
        case png = "public.png"
        case tiff = "public.tiff"
        case rtf = "public.rtf"
        case html = "public.html"
    }

    public struct Flavor: Equatable, Sendable {
        public let format: Format
        public let data: Data

        public init(_ format: Format, _ data: Data) {
            self.format = format
            self.data = data
        }

        public static func text(_ value: String) -> Self { Self(.text, Data(value.utf8)) }
    }

    public static func plainText(in flavors: [Flavor]) -> String? {
        flavors.first { $0.format == .text }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    public enum Status: Sendable, Equatable {
        case notReady, unknown, pending, unavailable
        case received([Flavor])
        case offered([Flavor])
        case failed

        public static func text(_ value: String) -> Self { .received([.text(value)]) }
    }
    public private(set) var status: Status = .notReady
    private var revision: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func update(revision: UInt64, status: Status) -> Bool {
        guard revision > self.revision else { return false }
        self.revision = revision
        self.status = status
        return true
    }
}
