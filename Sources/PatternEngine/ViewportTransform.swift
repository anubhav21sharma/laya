import Foundation

public struct ViewportTransform: Equatable, Sendable {
    public let drawableSize: PatternSize
    public let worldCenter: WorldPoint
    public let zoom: Float

    public init(
        drawableSize: PatternSize,
        worldCenter: WorldPoint,
        zoom: Float = 1
    ) {
        self.drawableSize = drawableSize
        self.worldCenter = worldCenter
        self.zoom = min(8, max(0.25, zoom))
    }

    public func worldToScreen(_ point: WorldPoint) -> ScreenPoint {
        let center = SIMD2(drawableSize.width * 0.5, drawableSize.height * 0.5)
        let screen = (point.simd - worldCenter.simd) * zoom + center
        return ScreenPoint(x: screen.x, y: screen.y)
    }

    public func screenToWorld(_ point: ScreenPoint) -> WorldPoint {
        let center = SIMD2(drawableSize.width * 0.5, drawableSize.height * 0.5)
        return WorldPoint((point.simd - center) / zoom + worldCenter.simd)
    }

    public func panned(byScreenDelta delta: SIMD2<Float>) -> ViewportTransform {
        ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(worldCenter.simd - delta / zoom),
            zoom: zoom
        )
    }

    public func zoomed(
        by factor: Float,
        anchorScreen: ScreenPoint
    ) -> ViewportTransform {
        let anchorWorld = screenToWorld(anchorScreen)
        let clamped = min(8, max(0.25, zoom * factor))
        let center = SIMD2(drawableSize.width * 0.5, drawableSize.height * 0.5)
        let adjustedCenter = anchorWorld.simd - (anchorScreen.simd - center) / clamped
        return ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(adjustedCenter),
            zoom: clamped
        )
    }

    public func resized(to size: PatternSize) -> ViewportTransform {
        ViewportTransform(
            drawableSize: size,
            worldCenter: worldCenter,
            zoom: zoom
        )
    }
}
