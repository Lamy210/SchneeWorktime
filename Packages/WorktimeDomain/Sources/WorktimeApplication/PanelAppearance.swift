import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Presentation-only preferences. No attendance or reminder state is included.
public enum PanelOpacity: String, Sendable, CaseIterable {
    case opaque, subtle, translucent

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .opaque
    }

    public var alpha: CGFloat {
        switch self {
        case .opaque: 1
        case .subtle: 0.95
        case .translucent: 0.85
        }
    }

    public var title: String {
        switch self {
        case .opaque: "100%"
        case .subtle: "95%"
        case .translucent: "85%"
        }
    }
}

/// Retain the top-left anchor rather than a stale size or monitor identifier.
public struct PanelAnchor: Codable, Sendable, Equatable {
    public let x: Double
    public let top: Double

    public init?(frame: CGRect) {
        let x = Double(frame.minX)
        let top = Double(frame.maxY)
        guard Self.valid(x), Self.valid(top) else { return nil }
        self.x = x
        self.top = top
    }

    private static func valid(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= 1_000_000
    }

    public static func restore(_ data: Data?) -> Self? {
        guard let data, data.count <= 1024,
              let anchor = try? JSONDecoder().decode(Self.self, from: data),
              valid(anchor.x), valid(anchor.top) else { return nil }
        return anchor
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public func preferredFrame(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(top) - height, width: width, height: height)
    }
}
