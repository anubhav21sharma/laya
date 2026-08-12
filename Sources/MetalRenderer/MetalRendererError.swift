import Foundation
import PatternEngine

public enum MetalRendererError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case defaultLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String)
    case textureAllocationFailed
    case sharedEventUnavailable
    case instanceBufferAllocationFailed
    case depositionEncoderUnavailable
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)
    case strokeSampleCapacityExceeded(Int)
    case generatedDabCapacityExceeded(Int)
    case projectedInstanceCapacityExceeded(Int)
    case brushDiameterOutOfRange(
        actual: Float,
        minimum: Float,
        maximum: Float
    )
    case invalidTileDimensions(width: Int, height: Int)
    case invalidPeriodicConfiguration(String)
    case invalidSymmetryConfiguration(String)
    case radialGeometryLocked
    case documentDomainLocked
    case tilingChangeRequiresIdle
    case invalidStrokeLifecycle
    case capturePreparationAlreadySuspended
    case capturePreparationNotSuspended
    case unsupportedBrushProgram
    case compiledBrushUnavailable(StrokeCompositeMode)
    case compiledBrushIdentityMismatch
    case compiledBrushActivationRequiresIdle
    case invalidCompiledBrush
    case unsupportedCompiledBrush
    case invalidRendererOperationToken
    case commitPendingInput
    case committedSnapshotUnavailable
    case committedSnapshotIncompatible
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
    case rasterRevisionLayerMismatch(expected: UUID, actual: UUID)
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
        case .sharedEventUnavailable:
            "Metal shared-event creation failed."
        case .instanceBufferAllocationFailed:
            "Metal instance-buffer allocation failed."
        case .depositionEncoderUnavailable:
            "The compiled brush deposition encoder is unavailable."
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
        case let .brushDiameterOutOfRange(actual, minimum, maximum):
            "Brush diameter \(actual) is outside \(minimum)...\(maximum)."
        case let .invalidTileDimensions(width, height):
            "Tile dimensions \(width)x\(height) are outside 64...4096."
        case let .invalidPeriodicConfiguration(message):
            "Invalid periodic symmetry: \(message)"
        case let .invalidSymmetryConfiguration(message):
            "Invalid symmetry: \(message)"
        case .radialGeometryLocked:
            "Radial geometry is locked because drawing has started."
        case .documentDomainLocked:
            "The document domain cannot change after the first raster edit."
        case .tilingChangeRequiresIdle:
            "Tiling can only change while the renderer is idle."
        case .invalidStrokeLifecycle:
            "The requested stroke transition is invalid."
        case .capturePreparationAlreadySuspended:
            "Paint display preparation is already suspended for capture."
        case .capturePreparationNotSuspended:
            "Paint display preparation is not suspended for capture."
        case .unsupportedBrushProgram:
            "The current renderer cannot render this brush program."
        case let .compiledBrushUnavailable(mode):
            "No prepared compiled brush is installed for \(mode)."
        case .compiledBrushIdentityMismatch:
            "The stroke style does not match the installed compiled brush."
        case .compiledBrushActivationRequiresIdle:
            "Compiled brushes can only be replaced while the renderer is idle."
        case .invalidCompiledBrush:
            "The prepared compiled brush has inconsistent render state."
        case .unsupportedCompiledBrush:
            "The prepared compiled brush requires an unsupported backend."
        case .invalidRendererOperationToken:
            "The renderer operation token does not match the active operation."
        case .commitPendingInput:
            "A canonical commit is still pending."
        case .committedSnapshotUnavailable:
            "Committed pixels are changing and cannot be captured yet."
        case .committedSnapshotIncompatible:
            "Committed project pixels do not match the validated document geometry."
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
        case let .rasterRevisionLayerMismatch(expected, actual):
            "Raster-revision layer mismatch: expected \(expected), got \(actual)."
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
