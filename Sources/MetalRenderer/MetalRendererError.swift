import Foundation

public enum MetalRendererError: Error, Equatable, LocalizedError {
    case commandQueueUnavailable
    case defaultLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String)
    case textureAllocationFailed
    case sharedEventUnavailable
    case instanceBufferAllocationFailed
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)
    case projectedInstanceCapacityExceeded(Int)
    case invalidTileDimensions(width: Int, height: Int)
    case tilingChangeRequiresIdle
    case invalidStrokeLifecycle
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
        case let .projectedInstanceCapacityExceeded(capacity):
            "Projected-instance capacity \(capacity) was exceeded."
        case let .invalidTileDimensions(width, height):
            "Tile dimensions \(width)x\(height) are outside 64...4096."
        case .tilingChangeRequiresIdle:
            "Tiling can only change while the renderer is idle."
        case .invalidStrokeLifecycle:
            "The requested stroke transition is invalid."
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
        }
    }
}
