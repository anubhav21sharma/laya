import Foundation

public enum MetalRendererError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case defaultLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String)
    case textureAllocationFailed
    case boundedWashSurfaceAllocationFailed
    case sharedEventUnavailable
    case instanceBufferAllocationFailed
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)
    case strokeSampleCapacityExceeded(Int)
    case generatedDabCapacityExceeded(Int)
    case projectedInstanceCapacityExceeded(Int)
    case invalidTileDimensions(width: Int, height: Int)
    case invalidPeriodicConfiguration(String)
    case tilingChangeRequiresIdle
    case invalidStrokeLifecycle
    case invalidRendererOperationToken
    case commitPendingInput
    case invalidDrawableSize
    case rasterRevisionBufferAllocationFailed
    case rasterRevisionStorageOverflow
    case emptyRasterRevisionRegions
    case rasterRevisionRegionOutOfBounds
    case invalidRasterRevisionTextureFormat
    case rasterRevisionTextureSizeMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case missingRasterRevision
    case invalidRasterRevisionOperationToken
    case rasterRevisionOperationDidNotComplete
    case rasterRevisionStorageLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            "Metal command queue creation failed."
        case .defaultLibraryUnavailable:
            "The app Metal library is unavailable."
        case let .shaderFunctionUnavailable(name):
            "Metal shader function '\(name)' is unavailable."
        case let .pipelineCreationFailed(message):
            "Metal pipeline creation failed: \(message)"
        case .textureAllocationFailed:
            "Metal render texture allocation failed."
        case .boundedWashSurfaceAllocationFailed:
            "Bounded-wash working texture allocation failed."
        case .sharedEventUnavailable:
            "Metal shared-event creation failed."
        case .instanceBufferAllocationFailed:
            "Metal instance-buffer allocation failed."
        case .commandBufferUnavailable:
            "Metal command buffer creation failed."
        case .renderEncoderUnavailable:
            "Metal render encoder creation failed."
        case let .commandFailed(message):
            "Metal command execution failed: \(message)"
        case let .strokeSampleCapacityExceeded(capacity):
            "Stroke-sample capacity \(capacity) was exceeded."
        case let .generatedDabCapacityExceeded(capacity):
            "Generated-dab capacity \(capacity) was exceeded."
        case let .projectedInstanceCapacityExceeded(capacity):
            "Projected-instance capacity \(capacity) was exceeded."
        case let .invalidTileDimensions(width, height):
            "Tile dimensions \(width)x\(height) are outside 64...4096."
        case let .invalidPeriodicConfiguration(message):
            "Invalid periodic symmetry: \(message)"
        case .tilingChangeRequiresIdle:
            "Tiling can only change while the renderer is idle."
        case .invalidStrokeLifecycle:
            "The requested stroke transition is invalid."
        case .invalidRendererOperationToken:
            "The renderer operation token does not match the active operation."
        case .commitPendingInput:
            "A canonical commit is still pending."
        case .invalidDrawableSize:
            "The drawable size is invalid."
        case .rasterRevisionBufferAllocationFailed:
            "Metal raster-revision buffer allocation failed."
        case .rasterRevisionStorageOverflow:
            "Raster-revision storage size overflowed."
        case .emptyRasterRevisionRegions:
            "A raster revision requires at least one pixel region."
        case .rasterRevisionRegionOutOfBounds:
            "A raster-revision region lies outside its pixel dimensions."
        case .invalidRasterRevisionTextureFormat:
            "Raster revisions require a BGRA8-unorm texture."
        case let .rasterRevisionTextureSizeMismatch(
            expectedWidth,
            expectedHeight,
            actualWidth,
            actualHeight
        ):
            """
            Raster-revision texture size mismatch: expected \
            \(expectedWidth)x\(expectedHeight), got \
            \(actualWidth)x\(actualHeight).
            """
        case .missingRasterRevision:
            "The requested raster revision is no longer resident."
        case .invalidRasterRevisionOperationToken:
            "The raster-revision operation token is invalid or stale."
        case .rasterRevisionOperationDidNotComplete:
            "The raster-revision GPU operation did not complete successfully."
        case .rasterRevisionStorageLimitExceeded:
            "The raster mutation exceeds the retained-history byte limit."
        }
    }
}
