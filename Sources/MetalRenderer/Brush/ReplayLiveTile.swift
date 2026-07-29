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
    private var hasPlannedClear = false
    private var usesFullTileClear = false
    private var plannedRegionalRectangles: [PixelRect] = []

    public var lastClearPlan: ReplayClearPlan? {
        guard hasPlannedClear else { return nil }
        if usesFullTileClear {
            return .fullTile(fullTileRegion)
        }
        return .regional(
            PixelRegionSet(
                plannedRegionalRectangles,
                clippedTo: pixelSize
            )
        )
    }

    var hasRegionalClearPlan: Bool {
        hasPlannedClear && !usesFullTileClear
    }

    var regionalClearRectangles: [PixelRect] {
        plannedRegionalRectangles
    }

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
        plannedRegionalRectangles.reserveCapacity(
            Self.maximumRegionalRectangleCount
        )
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
        planReplacementInPlace(
            epoch: epoch,
            canonicalRegions: combined.rectangles
        )
        return lastClearPlan!
    }

    func planReplacementInPlace(
        epoch: UInt64,
        canonicalRegions: [PixelRect]
    ) {
        precondition(epoch > visibleEpoch, "Replay epochs must be monotonic")
        hasPlannedClear = true
        plannedRegionalRectangles.removeAll(keepingCapacity: true)
        usesFullTileClear =
            canonicalRegions.count > Self.maximumRegionalRectangleCount
        guard !usesFullTileClear else { return }
        precondition(
            plannedRegionalRectangles.capacity
                >= canonicalRegions.count,
            "Replay clear storage must be reserved before interactive input."
        )
        plannedRegionalRectangles.append(contentsOf: canonicalRegions)
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
        hasPlannedClear = false
        usesFullTileClear = false
        plannedRegionalRectangles.removeAll(keepingCapacity: true)
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
