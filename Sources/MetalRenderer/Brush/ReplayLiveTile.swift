import Metal
import PatternEngine

public enum ReplayClearPlan: Equatable, Sendable {
    case regional(PixelRegionSet)
    case fullTile(PixelRegionSet)
}

/// Replacement-only live layer for predicted and retroactively tapered dabs.
@MainActor
public final class ReplayLiveTile {
    public static let maximumRegionalRectangleCount =
        TransientStrokeBufferContract.visibleEpochProjectedInstanceCapacity

    public let pixelSize: PixelSize
    public let texture: any MTLTexture
    public private(set) var visibleEpoch: UInt64 = 0
    public private(set) var isVisible = false
    private var hasPlannedClear = false
    private var plannedEpoch: UInt64?
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
    ) -> ReplayClearPlan? {
        let combined = PixelRegionSet(
            prior.rectangles + replacement.rectangles,
            clippedTo: pixelSize
        )
        guard planReplacementInPlace(
            epoch: epoch,
            canonicalRegions: combined.rectangles
        ) else { return nil }
        return lastClearPlan!
    }

    @discardableResult
    func planReplacementInPlace(
        epoch: UInt64,
        canonicalRegions: [PixelRect]
    ) -> Bool {
        guard epoch > visibleEpoch,
              plannedEpoch.map({ epoch > $0 }) ?? true else {
            return false
        }
        hasPlannedClear = true
        plannedEpoch = epoch
        plannedRegionalRectangles.removeAll(keepingCapacity: true)
        usesFullTileClear =
            canonicalRegions.count > Self.maximumRegionalRectangleCount
        guard !usesFullTileClear else { return true }
        precondition(
            plannedRegionalRectangles.capacity
                >= canonicalRegions.count,
            "Replay clear storage must be reserved before interactive input."
        )
        plannedRegionalRectangles.append(contentsOf: canonicalRegions)
        return true
    }

    @discardableResult
    public func markVisible(epoch: UInt64) -> Bool {
        if let plannedEpoch {
            guard epoch == plannedEpoch else { return false }
        } else {
            guard epoch >= visibleEpoch else { return false }
        }
        plannedEpoch = nil
        visibleEpoch = epoch
        isVisible = true
        return true
    }

    @discardableResult
    public func markCleared(epoch: UInt64) -> Bool {
        if let plannedEpoch {
            guard epoch == plannedEpoch else { return false }
        } else {
            guard epoch >= visibleEpoch else { return false }
        }
        plannedEpoch = nil
        visibleEpoch = epoch
        isVisible = false
        return true
    }

    public func reset() {
        visibleEpoch = 0
        isVisible = false
        hasPlannedClear = false
        plannedEpoch = nil
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
