import Foundation

/// Keep a panel inside the usable screen rectangle; use the primary screen if the old screen is gone.
public enum PanelPlacement {
    public static func visibleFrame(preferred: CGRect, screens: [CGRect]) -> CGRect? {
        guard let first = screens.first else { return nil }
        let screen = screens.first(where: { $0.contains(preferred) })
            ?? screens.first(where: { $0.intersects(preferred) }) ?? first
        let width = min(max(1, preferred.width), screen.width)
        let height = min(max(1, preferred.height), screen.height)
        let x = min(max(preferred.minX, screen.minX), screen.maxX - width)
        let y = min(max(preferred.minY, screen.minY), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
