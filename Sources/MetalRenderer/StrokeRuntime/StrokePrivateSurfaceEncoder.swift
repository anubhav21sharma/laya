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
    let surfaces: StrokeMetalSurfaceResources
    let brushRenderIdentity: BrushRenderIdentity
    let pipelineState: any MTLRenderPipelineState
    let materialUniforms: PatternDepositionMaterialUniforms
    let primaryShape: (any MTLTexture)?
    let secondaryShape: (any MTLTexture)?
    let primaryGrain: (any MTLTexture)?
    let secondaryGrain: (any MTLTexture)?
    let frameUniforms: PatternGridFrameUniforms
    let forceCommandFailure: Bool

    @MainActor
    init(
        surfaces: StrokeMetalSurfaceResources,
        brush: CompiledBrushRenderState,
        frameUniforms: PatternGridFrameUniforms,
        forceCommandFailure: Bool
    ) {
        let compiledResources = brush.resources
        let textures = compiledResources.depositionMaterial.textures
        self.surfaces = surfaces
        brushRenderIdentity = brush.renderIdentity
        pipelineState = compiledResources.depositionPipeline.state
        materialUniforms = compiledResources.depositionMaterial.uniforms
        primaryShape = textures[.primaryShape]
        secondaryShape = textures[.secondaryShape]
        primaryGrain = textures[.primaryGrain]
        secondaryGrain = textures[.secondaryGrain]
        self.frameUniforms = frameUniforms
        self.forceCommandFailure = forceCommandFailure
    }
}

/// The single audited sendability boundary for off-main stroke Metal work.
///
/// Metal protocol existentials do not declare `Sendable`. Every reference in
/// this holder is created once at pointer-down and never replaced. Only the
/// actor-confined `StrokePrivateSurfaceEncoder` dereferences the command queue,
/// render targets, pipeline, material textures, or upload buffer for mutation.
/// MainActor may read the two completed render targets through an immutable
/// lease, and the actor cannot mutate them again until that lease is returned.
final class StrokeMetalSurfaceResources: @unchecked Sendable {
    nonisolated let identity = UUID()
    let pixelSize: PixelSize
    let maximumRecordCount: Int

    fileprivate let commandQueue: any MTLCommandQueue
    fileprivate let authoritativeTexture: any MTLTexture
    fileprivate let predictionTexture: any MTLTexture
    fileprivate let uploadBuffer: any MTLBuffer
    fileprivate let clearPassDescriptor: MTLRenderPassDescriptor
    fileprivate let depositionPassDescriptor: MTLRenderPassDescriptor

    init(
        device: any MTLDevice,
        pixelSize: PixelSize,
        maximumRecordCount: Int
    ) throws {
        precondition(maximumRecordCount > 0)
        guard let commandQueue = device.makeCommandQueue() else {
            throw StrokePrivateSurfaceEncodingError
                .commandQueueUnavailable
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let authoritativeTexture = device.makeTexture(
            descriptor: descriptor
        ), let predictionTexture = device.makeTexture(
            descriptor: descriptor
        ) else {
            throw StrokePrivateSurfaceEncodingError.textureAllocationFailed
        }
        let (uploadLength, overflow) = maximumRecordCount
            .multipliedReportingOverflow(
                by: MemoryLayout<PatternDepositionStampInstance>.stride
            )
        guard !overflow, uploadLength > 0,
              let uploadBuffer = device.makeBuffer(
                  length: uploadLength,
                  options: .storageModeShared
              )
        else {
            throw StrokePrivateSurfaceEncodingError
                .uploadBufferAllocationFailed
        }

        commandQueue.label = "Off-main Stroke Preparation"
        authoritativeTexture.label = "Off-main Authoritative Stroke"
        predictionTexture.label = "Off-main Prediction Stroke"
        uploadBuffer.label = "Off-main Stroke Instances"
        let clearPassDescriptor = MTLRenderPassDescriptor()
        clearPassDescriptor.colorAttachments[0].loadAction = .clear
        clearPassDescriptor.colorAttachments[0].storeAction = .store
        clearPassDescriptor.colorAttachments[0].clearColor =
            MTLClearColorMake(0, 0, 0, 0)
        let depositionPassDescriptor = MTLRenderPassDescriptor()
        depositionPassDescriptor.colorAttachments[0].storeAction = .store
        self.pixelSize = pixelSize
        self.maximumRecordCount = maximumRecordCount
        self.commandQueue = commandQueue
        self.authoritativeTexture = authoritativeTexture
        self.predictionTexture = predictionTexture
        self.uploadBuffer = uploadBuffer
        self.clearPassDescriptor = clearPassDescriptor
        self.depositionPassDescriptor = depositionPassDescriptor
    }

    @MainActor
    fileprivate func texture(
        for layer: StrokePrivateSurfaceLayer
    ) -> any MTLTexture {
        switch layer {
        case .authoritative:
            authoritativeTexture
        case .prediction:
            predictionTexture
        }
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

    fileprivate let resources: StrokeMetalSurfaceResources

    @MainActor
    var authoritativeTexture: any MTLTexture {
        resources.texture(for: .authoritative)
    }

    @MainActor
    var predictionTexture: any MTLTexture {
        resources.texture(for: .prediction)
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
}

private struct StrokePrivateSurfaceCommandOutcome: Sendable {
    let succeeded: Bool
    let errorMessage: String?
}

/// Non-Sendable mutable Metal backend confined to `StrokeFrameScheduler`.
/// Commands are completed before publication. A single borrowed lease keeps
/// the two actor-owned surfaces immutable while Main composites them.
/// Mutable state is exclusively owned by `StrokeFrameScheduler`; unchecked
/// sendability permits that actor to suspend for GPU completion without
/// transferring the encoder to another owner.
final class StrokePrivateSurfaceEncoder: @unchecked Sendable {
    var snapshot: StrokePrivateSurfaceEncoderSnapshot {
        StrokePrivateSurfaceEncoderSnapshot(
            encodedFrameCount: encodedFrameCount,
            encodedInstanceCount: encodedInstanceCount,
            surfaceCount: 2,
            surfaceLeaseHighWater: surfaceLeaseHighWater,
            maximumUploadBytes: resources.maximumRecordCount
                * MemoryLayout<PatternDepositionStampInstance>.stride,
            authoritativeSurfaceIsInitialized:
                authoritativeSurfaceIsInitialized,
            predictionSurfaceIsInitialized:
                predictionSurfaceIsInitialized
        )
    }

    private var configuration: StrokeMetalResourceDescriptor?
    private var resources: StrokeMetalSurfaceResources {
        precondition(configuration != nil)
        return configuration!.surfaces
    }
    private var authoritativeSurfaceIsInitialized = false
    private var predictionSurfaceIsInitialized = false
    private var predictionIsVisible = false
    private var predictionReplacementNeedsClear = false
    private var nextLeaseToken: UInt64 = 1
    private var hasOutstandingLease = false
    private var encodedFrameCount: UInt64 = 0
    private var encodedInstanceCount: UInt64 = 0
    private var surfaceLeaseHighWater = 0

    init() {}

    func configure(_ configuration: StrokeMetalResourceDescriptor) {
        precondition(!hasOutstandingLease)
        self.configuration = configuration
        authoritativeSurfaceIsInitialized = false
        predictionSurfaceIsInitialized = false
        predictionIsVisible = false
        predictionReplacementNeedsClear = false
        nextLeaseToken = 1
        encodedFrameCount = 0
        encodedInstanceCount = 0
        surfaceLeaseHighWater = 0
    }

    func resetAfterCancellation() {
        configuration = nil
        hasOutstandingLease = false
    }

    /// Marks the next prediction-layer encode as the first chunk of an atomic
    /// replacement. Continuation chunks load the same private texture instead
    /// of clearing work already encoded for the replacement.
    func beginPredictionReplacement() {
        precondition(!hasOutstandingLease)
        predictionReplacementNeedsClear = true
    }

    func encode(
        generation: UInt64,
        records: [StrokePreparedProjectedRecord],
        layer: StrokePrivateSurfaceLayer,
        allocationProbe: StrokePreparationAllocationProbe?
    ) async throws -> StrokePreparedSurfaceLease? {
        guard let configuration else { return nil }
        precondition(!hasOutstandingLease)
        guard records.count <= resources.maximumRecordCount else {
            throw StrokePrivateSurfaceEncodingError.recordLimitExceeded(
                actual: records.count,
                maximum: resources.maximumRecordCount
            )
        }
        let clearsAuthoritative = !authoritativeSurfaceIsInitialized
        let clearsPrediction =
            !predictionSurfaceIsInitialized
            || (layer == .prediction && predictionReplacementNeedsClear)
            || (layer == .authoritative && predictionIsVisible)
        guard !records.isEmpty || clearsAuthoritative || clearsPrediction
        else {
            return nil
        }
        allocationProbe?.arm()
        packRecords(records)
        allocationProbe?.disarmAndRecord(.surfaceRecordPacking)

        allocationProbe?.arm()
        guard let commandBuffer = resources.commandQueue.makeCommandBuffer()
        else {
            allocationProbe?.disarmAndRecord(.surfaceMetalSubmission)
            throw StrokePrivateSurfaceEncodingError.commandBufferUnavailable
        }
        commandBuffer.label = "Off-main Stroke Surface"
        let encodingRanOnMainThread = surfaceEncodingIsOnMainThread()
        do {
            if clearsAuthoritative && layer != .authoritative {
                try encodeClear(
                    resources.authoritativeTexture,
                    label: "Initialize Off-main Authoritative",
                    commandBuffer: commandBuffer
                )
            }
            if clearsPrediction && layer != .prediction {
                try encodeClear(
                    resources.predictionTexture,
                    label: "Clear Off-main Prediction",
                    commandBuffer: commandBuffer
                )
            }
            try encodePreparedRecords(
                records,
                into: layer == .authoritative
                    ? resources.authoritativeTexture
                    : resources.predictionTexture,
                clear: layer == .authoritative
                    ? clearsAuthoritative
                    : clearsPrediction,
                commandBuffer: commandBuffer
            )
        } catch {
            allocationProbe?.disarmAndRecord(.surfaceMetalSubmission)
            throw error
        }
        let commandOutcome = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { completed in
                continuation.resume(
                    returning: StrokePrivateSurfaceCommandOutcome(
                        succeeded: completed.status == .completed
                            && completed.error == nil,
                        errorMessage: completed.error?.localizedDescription
                    )
                )
            }
            commandBuffer.commit()
            // The continuation may resume this actor on a different worker.
            // Disarm the TLS probe synchronously on the encoding thread.
            allocationProbe?.disarmAndRecord(.surfaceMetalSubmission)
        }
        if configuration.forceCommandFailure {
            throw StrokePrivateSurfaceEncodingError.commandFailed(
                "injected off-main stroke command failure"
            )
        }
        guard commandOutcome.succeeded else {
            throw StrokePrivateSurfaceEncodingError.commandFailed(
                commandOutcome.errorMessage
                    ?? "off-main stroke command failed"
            )
        }

        if clearsAuthoritative || layer == .authoritative {
            authoritativeSurfaceIsInitialized = true
        }
        if clearsPrediction || layer == .prediction {
            predictionSurfaceIsInitialized = true
        }
        if layer == .prediction {
            predictionReplacementNeedsClear = false
        }
        predictionIsVisible = layer == .prediction && !records.isEmpty
        let token = nextLeaseToken
        let (successor, overflow) = token.addingReportingOverflow(1)
        guard !overflow else {
            throw StrokePrivateSurfaceEncodingError.leaseTokenOverflow
        }
        nextLeaseToken = successor
        hasOutstandingLease = true
        surfaceLeaseHighWater = max(surfaceLeaseHighWater, 1)
        encodedFrameCount = Self.saturatingIncrement(encodedFrameCount)
        encodedInstanceCount = Self.saturatingAdd(
            encodedInstanceCount,
            UInt64(records.count)
        )
        return StrokePreparedSurfaceLease(
            generation: generation,
            token: token,
            layer: layer,
            authoritativeInstanceCount:
                layer == .authoritative ? records.count : 0,
            predictedInstanceCount:
                layer == .prediction ? records.count : 0,
            clearedAuthoritativeSurface: clearsAuthoritative,
            clearedPredictionSurface: clearsPrediction,
            encodingRanOnMainThread: encodingRanOnMainThread,
            resources: resources
        )
    }

    func acknowledge(_ lease: StrokePreparedSurfaceLease) {
        precondition(hasOutstandingLease)
        precondition(lease.resources === resources)
        hasOutstandingLease = false
    }

    private func encodeClear(
        _ texture: any MTLTexture,
        label: String,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let pass = resources.clearPassDescriptor
        pass.colorAttachments[0].texture = texture
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw StrokePrivateSurfaceEncodingError.renderEncoderUnavailable
        }
        encoder.label = label
        encoder.endEncoding()
    }

    private func packRecords(
        _ records: [StrokePreparedProjectedRecord]
    ) {
        let destination = resources.uploadBuffer.contents().bindMemory(
            to: PatternDepositionStampInstance.self,
            capacity: resources.maximumRecordCount
        )
        for index in records.indices {
            destination[index] = records[index].depositionRecord.instance
        }
    }

    private func encodePreparedRecords(
        _ records: [StrokePreparedProjectedRecord],
        into texture: any MTLTexture,
        clear: Bool,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard let configuration else {
            preconditionFailure("Stroke surface encoder is not configured")
        }
        let pass = resources.depositionPassDescriptor
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        if clear {
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw StrokePrivateSurfaceEncodingError.renderEncoderUnavailable
        }
        encoder.label = "Off-main Brush Deposition"
        if !records.isEmpty {
            encoder.setRenderPipelineState(configuration.pipelineState)
            var frame = configuration.frameUniforms
            encoder.setVertexBytes(
                &frame,
                length: MemoryLayout<PatternGridFrameUniforms>.stride,
                index: Int(PatternBufferIndexGridFrameUniforms)
            )
            encoder.setVertexBuffer(
                resources.uploadBuffer,
                offset: 0,
                index: Int(PatternBufferIndexDabInstances)
            )
            var material = configuration.materialUniforms
            encoder.setFragmentBytes(
                &material,
                length: MemoryLayout<PatternDepositionMaterialUniforms>.stride,
                index: Int(PatternBufferIndexBrushMaterial)
            )
            encoder.setFragmentTexture(
                configuration.primaryShape,
                index: DepositionTextureSlot.primaryShape.rawValue
            )
            encoder.setFragmentTexture(
                configuration.secondaryShape,
                index: DepositionTextureSlot.secondaryShape.rawValue
            )
            encoder.setFragmentTexture(
                configuration.primaryGrain,
                index: DepositionTextureSlot.primaryGrain.rawValue
            )
            encoder.setFragmentTexture(
                configuration.secondaryGrain,
                index: DepositionTextureSlot.secondaryGrain.rawValue
            )
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: records.count
            )
        }
        encoder.endEncoding()
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

private func surfaceEncodingIsOnMainThread() -> Bool {
    Thread.isMainThread
}
