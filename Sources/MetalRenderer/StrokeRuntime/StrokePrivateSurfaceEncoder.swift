import CShaderTypes
import Foundation
import Metal
import PatternEngine

enum StrokePrivateSurfaceLayer: Equatable, Sendable {
    case authoritative
    case prediction
}

enum StrokePrivateSurfaceEncodingError: Error, Equatable, Sendable {
    case commandQueueUnavailable
    case textureAllocationFailed
    case uploadBufferAllocationFailed
    case recordLimitExceeded(actual: Int, maximum: Int)
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)
    case leaseTokenOverflow
}

/// Immutable per-stroke bindings for a renderer-warmed Metal workspace.
struct StrokeMetalResourceDescriptor: @unchecked Sendable {
    let surfaces: StrokeTileSurfaceResources
    let brushRenderIdentity: BrushRenderIdentity
    let primaryComponent: StrokeTileComponentEncodingBinding
    let secondaryComponent: StrokeTileComponentEncodingBinding?
    let frameUniforms: PatternGridFrameUniforms
    let radialLayout: RadialSectorLayout?
    let forceCommandFailure: Bool

    @MainActor
    init(
        surfaces: StrokeTileSurfaceResources,
        brush: CompiledBrushRenderState,
        frameUniforms: PatternGridFrameUniforms,
        radialLayout: RadialSectorLayout? = nil,
        forceCommandFailure: Bool
    ) {
        self.surfaces = surfaces
        brushRenderIdentity = brush.renderIdentity
        primaryComponent = StrokeTileComponentEncodingBinding(
            ordinal: brush.primaryComponent.ordinal,
            pipeline: brush.primaryComponent.depositionPipeline,
            material: brush.primaryComponent.depositionMaterial
        )
        secondaryComponent = brush.secondaryComponent.map {
            StrokeTileComponentEncodingBinding(
                ordinal: $0.ordinal,
                pipeline: $0.depositionPipeline,
                material: $0.depositionMaterial
            )
        }
        self.frameUniforms = frameUniforms
        self.radialLayout = radialLayout
        self.forceCommandFailure = forceCommandFailure
    }
}

/// Immutable, bounded surface handoff. It retains one per-stroke resource
/// holder; no command queue, encoder, or mutable CPU buffer is exposed to Main.
struct StrokePreparedSurfaceLease: Sendable {
    let generation: UInt64
    let token: UInt64
    let layer: StrokePrivateSurfaceLayer
    let authoritativeInstanceCount: Int
    let predictedInstanceCount: Int
    let clearedAuthoritativeSurface: Bool
    let clearedPredictionSurface: Bool
    let encodingRanOnMainThread: Bool

    let backing: StrokeTileSurfaceLeaseBacking
    let newBindingCount: Int

    var tiledBindings: [StrokePreparedTileBinding] {
        return backing.visibleBindings
    }

    var bindingDeltaCoordinates: [PaintTileCoordinate] {
        return backing.bindingDeltaCoordinates
    }
}

package struct StrokePrivateSurfaceEncoderSnapshot: Equatable, Sendable {
    package let encodedFrameCount: UInt64
    package let encodedInstanceCount: UInt64
    package let surfaceCount: Int
    package let surfaceLeaseHighWater: Int
    package let maximumUploadBytes: Int
    package let authoritativeSurfaceIsInitialized: Bool
    package let predictionSurfaceIsInitialized: Bool
    package let residentTileHighWater: Int
    package let tileReferenceHighWater: Int
    package let bindingChunkCount: Int
}

/// Non-Sendable mutable Metal backend confined to `StrokeFrameScheduler`.
/// Commands are completed before publication. A single borrowed lease keeps
/// the two actor-owned surfaces immutable while Main composites them.
/// Mutable state is exclusively owned by `StrokeFrameScheduler`; unchecked
/// sendability permits that actor to suspend for GPU completion without
/// transferring the encoder to another owner.
final class StrokePrivateSurfaceEncoder: @unchecked Sendable {
    var snapshot: StrokePrivateSurfaceEncoderSnapshot {
        let value = tileEncoder.snapshot
        return StrokePrivateSurfaceEncoderSnapshot(
            encodedFrameCount: encodedFrameCount,
            encodedInstanceCount: encodedInstanceCount,
            surfaceCount: 2,
            surfaceLeaseHighWater: value.hasOutstandingLease
                ? 1 : surfaceLeaseHighWater,
            maximumUploadBytes: maximumTileReferenceCount
                * MemoryLayout<PatternDepositionStampInstance>.stride,
            authoritativeSurfaceIsInitialized:
                value.authoritativeVisibleTileCount > 0,
            predictionSurfaceIsInitialized:
                value.predictionVisibleTileCount > 0,
            residentTileHighWater: value.residentTileHighWater,
            tileReferenceHighWater: value.tileReferenceHighWater,
            bindingChunkCount: value.bindingChunkCount
        )
    }

    private var configuration: StrokeMetalResourceDescriptor?
    private let tileEncoder = StrokeTileSurfaceEncoder()
    private var maximumTileReferenceCount = 0
    private var hasOutstandingLease = false
    private var encodedFrameCount: UInt64 = 0
    private var encodedInstanceCount: UInt64 = 0
    private var surfaceLeaseHighWater = 0

    init() {}

    func configure(_ configuration: StrokeMetalResourceDescriptor) throws {
        precondition(!hasOutstandingLease)
        self.configuration = configuration
        encodedFrameCount = 0
        encodedInstanceCount = 0
        surfaceLeaseHighWater = 0
        let resources = configuration.surfaces
        try tileEncoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                primaryComponent: configuration.primaryComponent,
                secondaryComponent: configuration.secondaryComponent,
                frameUniforms: configuration.frameUniforms,
                radialLayout: configuration.radialLayout,
                forceCommandFailure: configuration.forceCommandFailure
            ),
            generation: resources.generation
        )
        maximumTileReferenceCount = resources.maximumTileReferenceCount
    }

    func resetAfterCancellation(
        frameDisposition: StrokeTileFrameDisposition
    ) -> StrokeTileSurfaceError? {
        do {
            try tileEncoder.cancel(frameDisposition: frameDisposition)
        } catch let error as StrokeTileSurfaceError {
            return error
        } catch {
            return .raster(.wrapping(error))
        }
        if frameDisposition == .mainOwnsLease, hasOutstandingLease {
            // Main may continue reading the immutable handoff until exact ACK.
            // Keep the encoder/resources alive so the ACK can return its pins
            // and finish the already-requested tiled retirement.
            return nil
        }
        configuration = nil
        hasOutstandingLease = false
        return nil
    }

    /// Marks the next prediction-layer encode as the first chunk of an atomic
    /// replacement. Continuation chunks load the same private texture instead
    /// of clearing work already encoded for the replacement.
    func beginPredictionReplacement() {
        precondition(!hasOutstandingLease)
        tileEncoder.beginPredictionReplacement()
    }

    func encode(
        generation: UInt64,
        records: [StrokePreparedProjectedRecord],
        layer: StrokePrivateSurfaceLayer,
        allocationProbe: StrokePreparationAllocationProbe?
    ) async throws -> StrokePreparedSurfaceLease? {
        guard configuration != nil else { return nil }
        precondition(!hasOutstandingLease)
        let lease = try await tileEncoder.encode(
            generation: generation,
            records: records,
            layer: layer,
            allocationProbe: allocationProbe
        )
        if lease != nil {
            hasOutstandingLease = true
            surfaceLeaseHighWater = max(surfaceLeaseHighWater, 1)
            encodedFrameCount = Self.saturatingIncrement(encodedFrameCount)
            encodedInstanceCount = Self.saturatingAdd(
                encodedInstanceCount,
                UInt64(records.count)
            )
        }
        return lease
    }

    func acknowledge(_ lease: StrokePreparedSurfaceLease) throws {
        precondition(hasOutstandingLease)
        try tileEncoder.acknowledge(lease)
        hasOutstandingLease = false
    }

    func sealCommitMutation()
        throws -> StrokePreparedCommitMutation
    {
        if let source = try tileEncoder.sealCommitMutationSource() {
            return .source(source)
        }
        return .noOp
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}
