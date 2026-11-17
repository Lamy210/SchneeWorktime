import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Panel-only presentation preference. No worktime state or notification plan depends on this value.
public enum PanelDisplayMode: String, Sendable, CaseIterable {
    case compact, detailed

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .detailed
    }

    public var height: CGFloat {
        switch self {
        case .compact: 180
        case .detailed: 300
        }
    }

    public var alternate: Self {
        self == .compact ? .detailed : .compact
    }

    /// Keep the upper edge stable, then clamp within the usable monitor.
    public func resizedFrame(previous: CGRect, screens: [CGRect]) -> CGRect? {
        let preferred = CGRect(
            x: previous.minX, y: previous.maxY - height, width: previous.width, height: height
        )
        return PanelPlacement.visibleFrame(preferred: preferred, screens: screens)
    }
}
