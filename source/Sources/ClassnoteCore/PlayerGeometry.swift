import Foundation
import CoreGraphics

public enum PlayerDockEdge: String, Sendable { case left, right }

/// Free positions keep the top-left anchor; docked positions keep their screen edge.
public enum PlayerGeometry {
    public static let compactSize = CGSize(width: 278, height: 66)
    public static func frame(current: CGRect, size: CGSize, bounds: CGRect, leftEdge: Bool) -> CGRect {
        frame(current: current, size: size, bounds: bounds, dockedEdge: leftEdge ? .left : .right)
    }
    public static func frame(current: CGRect, size: CGSize, bounds: CGRect, dockedEdge: PlayerDockEdge?) -> CGRect {
        let fitted = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        let x: CGFloat
        switch dockedEdge {
        case .left: x = bounds.minX
        case .right: x = bounds.maxX - fitted.width
        case nil: x = min(max(current.minX, bounds.minX), bounds.maxX - fitted.width)
        }
        let top = min(max(current.maxY, bounds.minY + fitted.height), bounds.maxY)
        return CGRect(x: x, y: top - fitted.height, width: fitted.width, height: fitted.height)
    }
    public static func dockedEdge(for current: CGRect, bounds: CGRect, threshold: CGFloat = 24) -> PlayerDockEdge? {
        let clamped = frame(current: current, size: current.size, bounds: bounds, dockedEdge: nil)
        let left = abs(clamped.minX - bounds.minX), right = abs(bounds.maxX - clamped.maxX)
        guard min(left, right) <= threshold else { return nil }
        return left <= right ? .left : .right
    }
}
