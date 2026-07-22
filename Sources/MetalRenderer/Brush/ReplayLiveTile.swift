import Metal
import PatternEngine

public enum ReplayClearPlan: Equatable, Sendable {
    case regional(PixelRegionSet)
    case fullTile(PixelRegionSet)
}

/// Replacement-only live layer for predicted and retroactively tapered dabs.
@MainActor
public final class ReplayLiveTile {
    public static let maximumRegionalRectangleCount = 32

    public let pixelSize: PixelSize
    public let texture: any MTLTexture
    public private(set) var visibleEpoch: UInt64 = 0
    public private(set) var isVisible = false
    public private(set) var lastClearPlan: ReplayClearPlan?

    public init(device: any MTLDevice, pixelSize: PixelSize) throws {
        self.pixelSize = pixelSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        texture.label = "Replay Live Stroke"
        self.texture = texture
    }

    public func planReplacement(
        epoch: UInt64,
        prior: PixelRegionSet,
        replacement: PixelRegionSet
    ) -> ReplayClearPlan {
        precondition(epoch > visibleEpoch, "Replay epochs must be monotonic")
        let combined = PixelRegionSet(
            prior.rectangles + replacement.rectangles,
            clippedTo: pixelSize
        )
        let plan: ReplayClearPlan
        if combined.rectangles.count <= Self.maximumRegionalRectangleCount {
            plan = .regional(combined)
        } else {
            plan = .fullTile(fullTileRegion)
        }
        lastClearPlan = plan
        return plan
    }

    public func markVisible(epoch: UInt64) {
        guard epoch >= visibleEpoch else { return }
        visibleEpoch = epoch
        isVisible = true
    }

    public func markCleared(epoch: UInt64) {
        guard epoch >= visibleEpoch else { return }
        visibleEpoch = epoch
        isVisible = false
    }

    public func reset() {
        visibleEpoch = 0
        isVisible = false
        lastClearPlan = nil
    }

    private var fullTileRegion: PixelRegionSet {
        PixelRegionSet(
            [
                PixelRect(
                    minX: 0,
                    minY: 0,
                    maxX: pixelSize.width,
                    maxY: pixelSize.height
                )!,
            ],
            clippedTo: pixelSize
        )
    }
}
