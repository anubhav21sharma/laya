import CShaderTypes
import EditorCore
import Foundation
@preconcurrency import Metal
import simd

struct PreparedLayerCompositeTransientSource: @unchecked Sendable {
    let layerID: UUID
    let descriptor: DocumentPaintTransientVisibleSourceDescriptor
    let samplingParameters: SparseTileSamplingEncodeParameters
}

struct PreparedLayerCompositeLayer: @unchecked Sendable {
    let layerID: UUID
    let opacity: Float
    let blendMode: LayerBlendMode
    let samplingPlan: SparseTileSamplingPlanContent
    let samplingParameters: SparseTileSamplingEncodeParameters
    let sourceSelection: SparseTileSourceSelection

    init(
        layerID: UUID,
        opacity: Float,
        blendMode: LayerBlendMode,
        samplingPlan: SparseTileSamplingPlanContent,
        samplingParameters: SparseTileSamplingEncodeParameters,
        sourceSelection: SparseTileSourceSelection
    ) {
        self.layerID = layerID
        self.opacity = opacity
        self.blendMode = blendMode
        self.samplingPlan = samplingPlan
        self.samplingParameters = samplingParameters
        self.sourceSelection = sourceSelection
    }
}

/// One immutable layer/order/source view retained from a single document
/// epoch. The root is snapshot retention only; texture pins remain the
/// responsibility of a later bounded encoding batch.
final class PreparedLayerCompositePlan: @unchecked Sendable {
    let documentGeneration: UInt64
    let geometry: DocumentPaintGeometry
    let outputRegion: SparseTileOutputRegion
    let outputMapping: SparseTileSamplingOutputMapping
    let layers: [PreparedLayerCompositeLayer]

    private let sourceCapture: TiledRasterExactReferenceCapture
    private let planLimits: SparseTilePlanLimits
    private let lock = NSLock()
    private var closed = false

    init(
        documentGeneration: UInt64,
        geometry: DocumentPaintGeometry,
        outputRegion: SparseTileOutputRegion,
        outputMapping: SparseTileSamplingOutputMapping,
        layers: [PreparedLayerCompositeLayer],
        sourceCapture: TiledRasterExactReferenceCapture,
        planLimits: SparseTilePlanLimits
    ) {
        self.documentGeneration = documentGeneration
        self.geometry = geometry
        self.outputRegion = outputRegion
        self.outputMapping = outputMapping
        self.layers = layers
        self.sourceCapture = sourceCapture
        self.planLimits = planLimits
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func sourceBatch(
        for layerID: UUID
    ) throws -> SparseTileOwnedSourceBatch {
        lock.lock()
        guard !closed,
              let selection = layers.first(where: {
                  $0.layerID == layerID
              })?.sourceSelection
        else {
            lock.unlock()
            throw TiledRasterSurfaceError.exactReferenceCaptureClosed
        }
        lock.unlock()
        return try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: sourceCapture
        )
    }

    func sourceBatch(
        for selection: SparseTileSourceSelection
    ) throws -> SparseTileOwnedSourceBatch {
        lock.lock()
        guard !closed else {
            lock.unlock()
            throw TiledRasterSurfaceError.exactReferenceCaptureClosed
        }
        lock.unlock()
        return try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: sourceCapture
        )
    }

    func layers(
        for childRegion: SparseTileOutputRegion,
        outputMapping: SparseTileSamplingOutputMapping
    ) throws -> [PreparedLayerCompositeLayer] {
        guard childRegion.minX >= outputRegion.minX,
              childRegion.minY >= outputRegion.minY,
              childRegion.maxX <= outputRegion.maxX,
              childRegion.maxY <= outputRegion.maxY
        else { throw LayerCompositorError.invalidPlan }
        // Child reachability geometry is shared, while source entitlement and
        // the mutable per-build authority remain layer-local.
        var sharedPeriodicReachabilitySeed:
            SparseTilePeriodicReachabilitySeed?
        return try layers.compactMap { layer in
            let sources = try layer.sourceSelection.restrictedSources(
                referenceScope: .entitlement
            )
            let originalKey = layer.samplingPlan.key
            let key = SparseTileSamplingPlanKey(
                documentGeneration: documentGeneration,
                orderedLayers: originalKey.orderedLayers,
                addressingRevision: originalKey.addressingRevision,
                outputGeometryRevision: originalKey.outputGeometryRevision,
                outputMapping: outputMapping
            )
            let selection = try SparseTileOwnedSourceBatch.selecting(
                sources: sources,
                key: key,
                outputRegion: childRegion,
                reusingPeriodicReachabilitySeed:
                    sharedPeriodicReachabilitySeed
            )
            if sharedPeriodicReachabilitySeed == nil {
                sharedPeriodicReachabilitySeed =
                    selection.reusablePeriodicReachabilitySeed
            }
            guard try selection.selectedReferenceCount() > 0 else {
                return nil
            }
            return PreparedLayerCompositeLayer(
                layerID: layer.layerID,
                opacity: layer.opacity,
                blendMode: layer.blendMode,
                samplingPlan: try SparseTileSamplingPlanBuilder.buildFull(
                    key: key,
                    selection: selection,
                    outputRegion: childRegion,
                    limits: planLimits
                ),
                samplingParameters: layer.samplingParameters
                    .replacingOutputMapping(outputMapping),
                sourceSelection: selection
            )
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        sourceCapture.close()
    }

    deinit { close() }
}

/// Independent scalar CPU authority for the later GPU layer kernel. Inputs
/// are already trusted linear-premultiplied colors and validated layer values.
enum LayerCPUCompositingReference {
    static func composite(
        stack: LayerStack,
        sample: (LayerDescriptor) -> SIMD4<Float>
    ) -> SIMD4<Float> {
        var result = SIMD4<Float>.zero
        for layer in stack.layers
        where layer.isVisible && layer.opacity > 0 {
            result = blend(
                source: sample(layer),
                over: result,
                opacity: layer.opacity,
                mode: layer.blendMode
            )
        }
        return result
    }

    static func sample<P: SparseTileCPUTexelProvider>(
        at point: SIMD2<Double>,
        plan: PreparedLayerCompositePlan,
        provider: P
    ) throws -> SIMD4<Float> {
        var result = SIMD4<Float>.zero
        for layer in plan.layers {
            let source = try SparseTileCPUReferenceSampler.sample(
                at: point,
                layerID: layer.layerID,
                role: .canonical,
                content: layer.samplingPlan,
                provider: provider
            )
            result = blend(
                source: source,
                over: result,
                opacity: layer.opacity,
                mode: layer.blendMode
            )
        }
        return result
    }

    private static func blend(
        source: SIMD4<Float>,
        over backdrop: SIMD4<Float>,
        opacity: Float,
        mode: LayerBlendMode
    ) -> SIMD4<Float> {
        let scaledSource = source * opacity
        let sourceAlpha = scaledSource.w
        let backdropAlpha = backdrop.w
        let sourceRGB = SIMD3(source.x, source.y, source.z)
        let backdropRGB = SIMD3(backdrop.x, backdrop.y, backdrop.z)
        let scaledSourceRGB = SIMD3(
            scaledSource.x,
            scaledSource.y,
            scaledSource.z
        )
        let sourceColor = source.w > 0
            ? sourceRGB / source.w : SIMD3<Float>.zero
        let backdropColor = backdropAlpha > 0
            ? backdropRGB / backdropAlpha : SIMD3<Float>.zero
        let blendedColor: SIMD3<Float> = switch mode {
        case .normal:
            sourceColor
        case .multiply:
            sourceColor * backdropColor
        case .screen:
            sourceColor + backdropColor - sourceColor * backdropColor
        }
        let overlap = sourceAlpha * backdropAlpha
        let rgb = scaledSourceRGB * (1 - backdropAlpha)
            + backdropRGB * (1 - sourceAlpha)
            + blendedColor * overlap
        let alpha = sourceAlpha + backdropAlpha * (1 - sourceAlpha)
        return SIMD4(rgb.x, rgb.y, rgb.z, alpha)
    }
}

enum LayerCompositorError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimit
    case invalidPlan
    case invalidTarget
    case busy
    case scratchLimitExceeded(required: Int, maximum: Int)
    case scratchAllocationFailed
    case commandCreationFailed
    case commandFailed(String)
    case cleanupPending

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "Layer compositor limits are invalid."
        case .invalidPlan:
            "Layer compositor plan is invalid or no longer available."
        case .invalidTarget:
            "Layer compositor target is incompatible."
        case .busy:
            "Layer compositor is already processing another request."
        case let .scratchLimitExceeded(required, maximum):
            "Layer compositor scratch requires \(required) bytes; maximum is \(maximum) bytes."
        case .scratchAllocationFailed:
            "Layer compositor scratch allocation failed."
        case .commandCreationFailed:
            "Layer compositor could not create a Metal command."
        case let .commandFailed(message):
            "Layer compositor Metal command failed: \(message)"
        case .cleanupPending:
            "Layer compositor cleanup did not complete within its bounded retry limit."
        }
    }
}

struct LayerCompositorLimits: Equatable, Sendable {
    let maximumWidth: Int
    let maximumHeight: Int
    let maximumScratchBytes: Int
    let maximumCleanupPasses: Int

    init(
        maximumWidth: Int,
        maximumHeight: Int,
        maximumScratchBytes: Int,
        maximumCleanupPasses: Int
    ) throws {
        guard maximumWidth > 0,
              maximumHeight > 0,
              maximumScratchBytes > 0,
              maximumCleanupPasses > 0
        else { throw LayerCompositorError.invalidLimit }
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumScratchBytes = maximumScratchBytes
        self.maximumCleanupPasses = maximumCleanupPasses
    }

    static let production = try! Self(
        maximumWidth: 4_096,
        maximumHeight: 4_096,
        maximumScratchBytes: 96 * 1_024 * 1_024,
        maximumCleanupPasses: 8
    )
}

struct LayerCompositorSnapshot: Equatable, Sendable {
    let isBusy: Bool
    let scratchBytes: Int
    let cpuPlanCache: SparseTileSamplingPlanCacheSnapshot
    let gpuPlanCache: SparseTileSamplingGPUCacheSnapshot
    let completion: SparseTileSamplingCompletionSnapshot
    let tileReductionBytes: Int
    let physicalWorkspaceBytes: Int
    let physicalWorkspaceByteHighWater: Int
    let lastTileBatchMetrics: CanvasCompositeBatchMetrics?
}

struct LayerCompositorGPUPlanProfile: Equatable, Sendable {
    let maximumInflightEncodes: Int
    let maximumCachedPlans: Int
    let maximumCachedBufferBytes: Int
    let allowsCacheEviction: Bool
    let declaredTileBatchWorkspaceBytes: Int

    static let standard = LayerCompositorGPUPlanProfile(
        maximumInflightEncodes: 1,
        maximumCachedPlans: LayerStack.maximumLayerCount,
        maximumCachedBufferBytes: 64 * 1_024 * 1_024,
        allowsCacheEviction: true,
        declaredTileBatchWorkspaceBytes: 66 * 1_024 * 1_024
    )

    static func canonicalTileBatch(
        workspaceByteBudget: Int
    ) throws -> LayerCompositorGPUPlanProfile {
        // One physical 256² RGBA16F scratch set is 1.5 MiB. Reserve another
        // 0.5 MiB for the reduction buffer and allocation alignment; the GPU
        // plan cache owns the exact remainder and may not evict within a live
        // 8x8 tile/layer command chunk.
        let nonPlanWorkspace = 2 * 1_024 * 1_024
        guard workspaceByteBudget > nonPlanWorkspace else {
            throw LayerCompositorError.invalidLimit
        }
        return LayerCompositorGPUPlanProfile(
            maximumInflightEncodes: LayerStack.maximumLayerCount * 8,
            maximumCachedPlans: LayerStack.maximumLayerCount * 8,
            maximumCachedBufferBytes: workspaceByteBudget - nonPlanWorkspace,
            allowsCacheEviction: false,
            declaredTileBatchWorkspaceBytes: workspaceByteBudget
        )
    }
}

struct LayerCompositeTileBatchResult: Equatable, Sendable {
    let fullyTransparentCoordinates: [PaintTileCoordinate]
    let metrics: CanvasCompositeBatchMetrics
}

struct LayerCompositeTileBatchFailureInjection: Equatable, Sendable {
    let failingSampleEncodeIndex: Int?
    let failingCommandTerminalChunkIndex: Int?

    init(
        failingSampleEncodeIndex: Int? = nil,
        failingCommandTerminalChunkIndex: Int? = nil
    ) {
        self.failingSampleEncodeIndex = failingSampleEncodeIndex
        self.failingCommandTerminalChunkIndex =
            failingCommandTerminalChunkIndex
    }
}

final class CanonicalWorkspaceObservation: @unchecked Sendable {
    let snapshot: LayerCompositorSnapshot
    private let lock = NSLock()
    private var closeAction: (@Sendable () -> Void)?

    init(
        snapshot: LayerCompositorSnapshot,
        closeAction: @escaping @Sendable () -> Void
    ) {
        self.snapshot = snapshot
        self.closeAction = closeAction
    }

    func close() {
        lock.lock()
        let action = closeAction
        closeAction = nil
        lock.unlock()
        action?()
    }

    deinit { close() }
}

/// Capability boundary for persistent canonical composition. The cache cannot
/// invoke full-drawable display, collect, readback, or export scratch paths.
actor CanonicalTileCompositor {
    nonisolated let declaredTileBatchWorkspaceBytes: Int
    private let core: LayerCompositor
    #if DEBUG
    private var testingWorkspaceSnapshotOverride: Int?
    #endif
    private var workspaceMutationActive = false
    private var workspaceObservationActive = false
    private var workspaceGateWaiters: [CheckedContinuation<Void, Never>] = []

    init(wrapping core: LayerCompositor) {
        self.core = core
        declaredTileBatchWorkspaceBytes =
            core.declaredTileBatchWorkspaceBytes
    }

    @MainActor
    static func make(
        device: any MTLDevice,
        library: any MTLLibrary,
        backendRequest: SparseTileSamplingBackendRequest = .automatic,
        planLimits: SparseTilePlanLimits = .documentProduction,
        workspaceByteBudget: Int
    ) throws -> CanonicalTileCompositor {
        CanonicalTileCompositor(wrapping: try LayerCompositor.make(
            device: device,
            library: library,
            backendRequest: backendRequest,
            limits: .production,
            planLimits: planLimits,
            gpuPlanProfile: try .canonicalTileBatch(
                workspaceByteBudget: workspaceByteBudget
            )
        ))
    }

    #if DEBUG
    @MainActor
    static func makeForTesting(
        device: any MTLDevice,
        library: any MTLLibrary,
        workspaceByteBudget: Int,
        returnLease: @escaping SparseTileLeaseReturner = { lease in
            try lease.returnLease()
        },
        completionFailureInjector:
            SparseTileSamplingCompletionFailureInjector? = nil
    ) throws -> CanonicalTileCompositor {
        CanonicalTileCompositor(wrapping: try LayerCompositor.make(
            device: device,
            library: library,
            backendRequest: .forceFallback,
            gpuPlanProfile: try .canonicalTileBatch(
                workspaceByteBudget: workspaceByteBudget
            ),
            planCache: SparseTileSamplingPlanCache(returnLease: returnLease),
            completionFailureInjector: completionFailureInjector
        ))
    }
    #endif

    func compositeTiles(
        _ plan: CanvasCompositeTileUpdatePlan,
        into bindings: [PaintTileBinding],
        policy: CanvasCompositeBatchPolicy,
        failureInjection: LayerCompositeTileBatchFailureInjection?
    ) async throws -> LayerCompositeTileBatchResult {
        await beginWorkspaceMutation()
        defer { finishWorkspaceMutation() }
        return try await core.compositeTiles(
            plan,
            into: bindings,
            policy: policy,
            failureInjection: failureInjection
        )
    }

    func snapshot() async -> LayerCompositorSnapshot {
        let observation = await acquireWorkspaceObservation()
        defer { observation.close() }
        return observation.snapshot
    }

    func acquireWorkspaceObservation() async -> CanonicalWorkspaceObservation {
        while workspaceMutationActive || workspaceObservationActive {
            await withCheckedContinuation { workspaceGateWaiters.append($0) }
        }
        workspaceObservationActive = true
        let value = await core.snapshot()
        let observed: LayerCompositorSnapshot
        #if DEBUG
        if let testingWorkspaceSnapshotOverride {
            observed = LayerCompositorSnapshot(
                isBusy: value.isBusy,
                scratchBytes: value.scratchBytes,
                cpuPlanCache: value.cpuPlanCache,
                gpuPlanCache: value.gpuPlanCache,
                completion: value.completion,
                tileReductionBytes: value.tileReductionBytes,
                physicalWorkspaceBytes: testingWorkspaceSnapshotOverride,
                physicalWorkspaceByteHighWater: max(
                    value.physicalWorkspaceByteHighWater,
                    testingWorkspaceSnapshotOverride
                ),
                lastTileBatchMetrics: value.lastTileBatchMetrics
            )
        } else {
            observed = value
        }
        #else
        observed = value
        #endif
        return CanonicalWorkspaceObservation(
            snapshot: observed,
            closeAction: { [weak self] in
                Task { await self?.finishWorkspaceObservation() }
            }
        )
    }

    #if DEBUG
    func testingSetWorkspaceSnapshotOverride(_ bytes: Int?) {
        precondition(bytes == nil || bytes! >= 0)
        testingWorkspaceSnapshotOverride = bytes
    }
    #endif

    func retryCleanup() async throws {
        await beginWorkspaceMutation()
        defer { finishWorkspaceMutation() }
        try await core.retryDisplayCompletion()
    }

    func shutdown() async throws {
        await beginWorkspaceMutation()
        defer { finishWorkspaceMutation() }
        try await core.shutdown()
    }

    private func beginWorkspaceMutation() async {
        while workspaceMutationActive || workspaceObservationActive {
            await withCheckedContinuation { workspaceGateWaiters.append($0) }
        }
        workspaceMutationActive = true
    }

    private func finishWorkspaceMutation() {
        precondition(workspaceMutationActive)
        workspaceMutationActive = false
        resumeWorkspaceGateWaiters()
    }

    private func finishWorkspaceObservation() {
        guard workspaceObservationActive else { return }
        workspaceObservationActive = false
        resumeWorkspaceGateWaiters()
    }

    private func resumeWorkspaceGateWaiters() {
        let waiters = workspaceGateWaiters
        workspaceGateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Exclusive destination ownership for one compositor invocation. Callers
/// keep the handle, but must not access its texture until `composite` returns.
final class LayerCompositeTarget: @unchecked Sendable {
    let texture: any MTLTexture

    init(texture: any MTLTexture) {
        self.texture = texture
    }
}

private final class LayerCompositorDisplayTerminalWaiter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var isTerminal = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func recordTerminal() {
        lock.lock()
        precondition(!isTerminal)
        isTerminal = true
        let continuations = self.continuations
        self.continuations.removeAll(keepingCapacity: false)
        lock.unlock()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isTerminal {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class PreparedLayerCompositeDisplaySubmissionCore:
    @unchecked Sendable
{
    private enum State: Equatable {
        case available
        case encoding
        case submitted
        case terminal
    }

    private enum Settlement {
        case completeNow
        case wait
        case alreadyTerminal
    }

    let outputRegion: SparseTileOutputRegion
    private let source: any MTLTexture
    private let parameters: SparseTileSamplingEncodeParameters
    private let pipeline: LayerBlendPipelineBinding
    private let onTerminal: @Sendable () -> Void
    private let terminalWaiter = LayerCompositorDisplayTerminalWaiter()
    private let lock = NSLock()
    private var state = State.available
    private var settlementRequested = false

    init(
        source: any MTLTexture,
        outputRegion: SparseTileOutputRegion,
        parameters: SparseTileSamplingEncodeParameters,
        pipeline: LayerBlendPipelineBinding,
        onTerminal: @escaping @Sendable () -> Void
    ) {
        self.source = source
        self.outputRegion = outputRegion
        self.parameters = parameters
        self.pipeline = pipeline
        self.onTerminal = onTerminal
    }

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .terminal
    }

    func encode(
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) throws {
        lock.lock()
        guard state == .available else {
            lock.unlock()
            throw LayerCompositorError.invalidPlan
        }
        state = .encoding
        lock.unlock()
        do {
            try pipeline.encodeDisplay(
                source: source,
                target: target,
                outputRegion: outputRegion,
                parameters: parameters,
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPassDescriptor
            )
            commandBuffer.addCompletedHandler { [self] _ in finish() }
            lock.lock()
            precondition(state == .encoding)
            state = .submitted
            lock.unlock()
        } catch {
            lock.lock()
            precondition(state == .encoding)
            let mustTerminate = settlementRequested
            state = mustTerminate ? .terminal : .available
            lock.unlock()
            if mustTerminate { completeTerminal() }
            throw error
        }
    }

    func cancel() throws {
        lock.lock()
        guard state == .available else {
            lock.unlock()
            throw LayerCompositorError.invalidPlan
        }
        state = .terminal
        lock.unlock()
        completeTerminal()
    }

    func settle() async {
        switch beginSettlement() {
        case .completeNow:
            completeTerminal()
        case .wait:
            await terminalWaiter.wait()
        case .alreadyTerminal:
            break
        }
    }

    private func beginSettlement() -> Settlement {
        lock.lock()
        switch state {
        case .available:
            state = .terminal
            lock.unlock()
            return .completeNow
        case .encoding:
            settlementRequested = true
            lock.unlock()
            return .wait
        case .submitted:
            lock.unlock()
            return .wait
        case .terminal:
            lock.unlock()
            return .alreadyTerminal
        }
    }

    private func finish() {
        lock.lock()
        guard state == .submitted else {
            lock.unlock()
            return
        }
        state = .terminal
        lock.unlock()
        completeTerminal()
    }

    private func completeTerminal() {
        onTerminal()
        terminalWaiter.recordTerminal()
    }
}

private extension SparseTileSamplingEncodeParameters {
    func replacingOutputMapping(
        _ outputMapping: SparseTileSamplingOutputMapping
    ) -> SparseTileSamplingEncodeParameters {
        SparseTileSamplingEncodeParameters(
            outputMapping: outputMapping,
            compositeMode: compositeMode,
            liveVisible: liveVisible,
            strokeOpacity: strokeOpacity,
            accumulationLimit: accumulationLimit,
            eraserStrength: eraserStrength,
            showGridLines: showGridLines,
            showCanvasBoundary: showCanvasBoundary
        )
    }
}

final class PreparedLayerCompositeDisplaySubmission: @unchecked Sendable {
    fileprivate let core: PreparedLayerCompositeDisplaySubmissionCore
    let outputRegion: SparseTileOutputRegion

    fileprivate init(core: PreparedLayerCompositeDisplaySubmissionCore) {
        self.core = core
        outputRegion = core.outputRegion
    }

    var isTerminal: Bool { core.isTerminal }

    func encode(
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) throws {
        try core.encode(
            target: target,
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor
        )
    }

    func cancel() throws { try core.cancel() }
}

/// Bounded linear-premultiplied layer compositor. One layer's sparse source
/// batch is pinned at a time. Two reusable accumulation textures carry only
/// the current output chunk; there is no viewport or per-layer composite cache.
actor LayerCompositor {
    nonisolated let declaredTileBatchWorkspaceBytes: Int
    private struct PreparedTileSampling: @unchecked Sendable {
        let submission: SparseTileSamplingPreparedSubmission
        let content: SparseTileSamplingPlanContent
    }

    private struct Scratch: @unchecked Sendable {
        let sample: any MTLTexture
        let accumulationA: any MTLTexture
        let accumulationB: any MTLTexture
        let width: Int
        let height: Int
        let bytes: Int
    }

    private struct ExportScratch: @unchecked Sendable {
        let working: any MTLTexture
        let interchange: any MTLTexture
        let readback: any MTLBuffer
        let width: Int
        let height: Int
        let alignedBytesPerRow: Int
        let bytes: Int
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let samplingPipelines: [
        SparseTileSamplingOutputMappingKind: SparseTileSamplingPipelineBinding
    ]
    private let blendPipeline: LayerBlendPipelineBinding
    private let limits: LayerCompositorLimits
    private let planLimits: SparseTilePlanLimits
    private let planCache: SparseTileSamplingPlanCache
    private let gpuPlanCache: SparseTileSamplingGPUPlanCache
    private var scratch: Scratch?
    private var tileReductionBuffer: (any MTLBuffer)?
    private var physicalWorkspaceByteHighWater = 0
    private var lastTileBatchMetrics: CanvasCompositeBatchMetrics?
    private var exportScratch: ExportScratch?
    private var isBusy = false
    private var inflightCommandCount = 0
    private var activeDisplaySubmission:
        PreparedLayerCompositeDisplaySubmissionCore?

    @MainActor
    static func make(
        device: any MTLDevice,
        library: any MTLLibrary,
        backendRequest: SparseTileSamplingBackendRequest = .automatic,
        limits: LayerCompositorLimits = .production,
        planLimits: SparseTilePlanLimits = .documentProduction,
        gpuPlanProfile: LayerCompositorGPUPlanProfile = .standard,
        planCache: SparseTileSamplingPlanCache = SparseTileSamplingPlanCache(),
        completionFailureInjector:
            SparseTileSamplingCompletionFailureInjector? = nil
    ) throws -> LayerCompositor {
        ShaderABI.preconditionValid()
        let backend = try SparseTileSamplingBackend.select(
            request: backendRequest,
            capabilities: SparseTileSamplingDeviceCapabilities(device: device)
        )
        var samplingPipelines: [
            SparseTileSamplingOutputMappingKind:
                SparseTileSamplingPipelineBinding
        ] = [:]
        for kind in [
            SparseTileSamplingOutputMappingKind.affine,
            .periodic,
            .finiteRadial,
        ] {
            samplingPipelines[kind] = try SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: SparseTileSamplingPipelineKey(
                    backend: backend,
                    outputPixelFormatRawValue:
                        DocumentColorPipeline.workingPixelFormat.rawValue,
                    sampleCount: 1,
                    abiVersion: SparseSamplingABI.version,
                    outputMappingKind: kind
                )
            )
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw LayerCompositorError.commandCreationFailed
        }
        return LayerCompositor(
            device: device,
            commandQueue: commandQueue,
            samplingPipelines: samplingPipelines,
            blendPipeline: try LayerBlendPipeline.prepare(
                device: device,
                library: library,
                abiVersion: LayerBlendABI.version
            ),
            limits: limits,
            planLimits: planLimits,
            gpuPlanProfile: gpuPlanProfile,
            planCache: planCache,
            gpuPlanCache: SparseTileSamplingGPUPlanCache(
                device: device,
                limits: SparseTileSamplingGPUPlanLimits(
                    maximumDescriptors: 3,
                    maximumPageEntries: planLimits.maximumPageEntries,
                    maximumBufferBytes: min(
                        planLimits.maximumPageTableBytes,
                        gpuPlanProfile.maximumCachedBufferBytes
                    ),
                    maximumInflightEncodes:
                        gpuPlanProfile.maximumInflightEncodes,
                    maximumCachedPlans: gpuPlanProfile.maximumCachedPlans,
                    maximumCachedBufferBytes:
                        gpuPlanProfile.maximumCachedBufferBytes,
                    allowsCacheEviction: gpuPlanProfile.allowsCacheEviction
                ),
                completionFailureInjector: completionFailureInjector
            )
        )
    }


    private init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        samplingPipelines: [
            SparseTileSamplingOutputMappingKind:
                SparseTileSamplingPipelineBinding
        ],
        blendPipeline: LayerBlendPipelineBinding,
        limits: LayerCompositorLimits,
        planLimits: SparseTilePlanLimits,
        gpuPlanProfile: LayerCompositorGPUPlanProfile,
        planCache: SparseTileSamplingPlanCache,
        gpuPlanCache: SparseTileSamplingGPUPlanCache
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.samplingPipelines = samplingPipelines
        self.blendPipeline = blendPipeline
        self.limits = limits
        self.planLimits = planLimits
        self.planCache = planCache
        self.gpuPlanCache = gpuPlanCache
        declaredTileBatchWorkspaceBytes =
            gpuPlanProfile.declaredTileBatchWorkspaceBytes
    }

    /// Consumes `plan`. Its aggregate exact-reference root is closed exactly
    /// once after the last authenticated GPU return or after bounded cleanup.
    func composite(
        _ plan: PreparedLayerCompositePlan,
        into target: LayerCompositeTarget
    ) async throws {
        defer { plan.close() }
        await settleActiveDisplaySubmission()
        guard !isBusy else { throw LayerCompositorError.busy }
        isBusy = true
        defer { isBusy = false }
        try await performComposite(
            plan,
            layers: plan.layers,
            outputRegion: plan.outputRegion,
            into: target
        )
    }

    private func performComposite(
        _ plan: PreparedLayerCompositePlan,
        layers: [PreparedLayerCompositeLayer],
        outputRegion: SparseTileOutputRegion,
        into target: LayerCompositeTarget
    ) async throws {
        guard !plan.isClosed,
              layers.count <= LayerStack.maximumLayerCount
        else { throw LayerCompositorError.invalidPlan }
        let targetTexture = target.texture
        try validateTarget(targetTexture, for: outputRegion)

        do {
            try Task.checkCancellation()
            let scratch = try ensureScratch(for: outputRegion)
            if layers.isEmpty {
                try await clear(targetTexture)
            } else {
                var backdrop = scratch.accumulationA
                for (index, layer) in layers.enumerated() {
                    try Task.checkCancellation()
                    let isLast = index == layers.count - 1
                    let destination: any MTLTexture
                    if isLast {
                        destination = targetTexture
                    } else if backdrop === scratch.accumulationA {
                        destination = scratch.accumulationB
                    } else {
                        destination = scratch.accumulationA
                    }
                    try await composite(
                        layer: layer,
                        from: plan,
                        outputRegion: outputRegion,
                        sample: scratch.sample,
                        backdrop: backdrop,
                        destination: destination,
                        clearBackdrop: index == 0
                    )
                    backdrop = destination
                }
            }
            try Task.checkCancellation()
            guard await !hasCleanupDebt() else {
                guard await performBoundedCleanup() else {
                    throw LayerCompositorError.cleanupPending
                }
                return
            }
        } catch {
            guard await performBoundedCleanup() else {
                throw LayerCompositorError.cleanupPending
            }
            throw error
        }
    }

    /// Consumes one coherent full-output plan while emitting bounded BGRA8
    /// chunks. Every layer blend remains linear RGBA16F until the single
    /// interchange pack for that chunk.
    func collect(
        _ plan: PreparedLayerCompositePlan,
        to sink: any DocumentPaintStableSnapshotSink
    ) async throws {
        defer { plan.close() }
        await settleActiveDisplaySubmission()
        guard !isBusy else { throw LayerCompositorError.busy }
        guard !plan.isClosed else { throw LayerCompositorError.invalidPlan }
        isBusy = true
        defer { isBusy = false }
        var began = false
        var finished = false
        do {
            try Task.checkCancellation()
            try await sink.begin(DocumentPaintStableSnapshotSinkDescriptor(
                outputRegion: plan.outputRegion,
                bytesPerPixel: 4,
                pixelFormatRawValue:
                    DocumentColorPipeline.interchangePixelFormat.rawValue
            ))
            began = true
            for region in try exportRegions(for: plan.outputRegion) {
                try Task.checkCancellation()
                let childMapping = try DocumentPaintStableSnapshotChunkPlanner
                    .childMapping(
                        global: plan.outputMapping,
                        full: plan.outputRegion,
                        child: region
                    )
                let layers = try plan.layers(
                    for: region,
                    outputMapping: childMapping
                )
                let export = try ensureExportScratch(for: region)
                try await performComposite(
                    plan,
                    layers: layers,
                    outputRegion: region,
                    into: LayerCompositeTarget(texture: export.working)
                )
                try await packAndReadback(export)
                try await sink.consume(try makeExportChunk(
                    region: region,
                    scratch: export
                ))
            }
            try Task.checkCancellation()
            try await sink.finish()
            finished = true
        } catch {
            if began && !finished { await sink.abort() }
            guard await performBoundedCleanup() else {
                throw LayerCompositorError.cleanupPending
            }
            throw error
        }
    }

    func snapshot() async -> LayerCompositorSnapshot {
        reconcileDisplaySubmission()
        let gpu = await gpuPlanCache.allocationSnapshot
        let completion = await gpuPlanCache.completionSnapshot
        let workspace = physicalWorkspaceBytes(
            gpu: gpu,
            completion: completion
        )
        physicalWorkspaceByteHighWater = max(
            physicalWorkspaceByteHighWater,
            workspace
        )
        return LayerCompositorSnapshot(
            isBusy: isBusy,
            scratchBytes: (scratch?.bytes ?? 0) + (exportScratch?.bytes ?? 0),
            cpuPlanCache: planCache.snapshot(),
            gpuPlanCache: gpu,
            completion: completion,
            tileReductionBytes: tileReductionBuffer?.length ?? 0,
            physicalWorkspaceBytes: workspace,
            physicalWorkspaceByteHighWater:
                physicalWorkspaceByteHighWater,
            lastTileBatchMetrics: lastTileBatchMetrics
        )
    }

    private func physicalWorkspaceBytes(
        gpu: SparseTileSamplingGPUCacheSnapshot,
        completion: SparseTileSamplingCompletionSnapshot
    ) -> Int {
        (scratch?.bytes ?? 0)
            + (exportScratch?.bytes ?? 0)
            + (tileReductionBuffer?.length ?? 0)
            + gpu.cachedPlanMetalBufferBytes
            + (gpu.uploadRing?.metalBufferBytes ?? 0)
            + completion.pendingPlanMetalBufferBytes
    }

    private func recordPhysicalWorkspaceHighWater() async {
        let gpu = await gpuPlanCache.allocationSnapshot
        let completion = await gpuPlanCache.completionSnapshot
        physicalWorkspaceByteHighWater = max(
            physicalWorkspaceByteHighWater,
            physicalWorkspaceBytes(gpu: gpu, completion: completion)
        )
    }

    /// Consumes one raw-canonical update plan. Tiles are sorted and encoded in
    /// bounded serial chunks: one command submission/wait per chunk, never per
    /// tile or layer. One tracked-hazard scratch set is reused in command order.
    func compositeTiles(
        _ plan: CanvasCompositeTileUpdatePlan,
        into bindings: [PaintTileBinding],
        policy: CanvasCompositeBatchPolicy = try! .init(
            maximumTilesPerChunk: 8,
            maximumLayersPerTile: LayerStack.maximumLayerCount
        ),
        failureInjection: LayerCompositeTileBatchFailureInjection? = nil
    ) async throws -> LayerCompositeTileBatchResult {
        await settleActiveDisplaySubmission()
        if await hasCleanupDebt() {
            guard await performBoundedCleanup() else {
                throw LayerCompositorError.cleanupPending
            }
        }
        guard !isBusy else { throw LayerCompositorError.busy }
        guard !plan.isClosed,
              !bindings.isEmpty,
              plan.preparedTiles.count >= bindings.count,
              plan.preparedTiles.count == plan.dirtyCoordinates.count
        else { throw LayerCompositorError.invalidPlan }
        let bindingByCoordinate = Dictionary(
            uniqueKeysWithValues: bindings.map {
                ($0.descriptor.coordinate, $0)
            }
        )
        guard bindingByCoordinate.count == bindings.count,
              bindings.allSatisfy({ binding in
                  plan.preparedTiles.contains {
                    $0.coordinate == binding.descriptor.coordinate
                  }
              }),
              plan.preparedTiles.allSatisfy({
                  $0.layers.count <= policy.maximumLayersPerTile
              })
        else { throw LayerCompositorError.invalidPlan }

        isBusy = true
        defer { isBusy = false }
        var transparent: [PaintTileCoordinate] = []
        var commandCount = 0
        var sampleEncodeCount = 0
        var sampleEncodeAttemptCount = 0
        var maximumPrepared = 0
        do {
            try Task.checkCancellation()
            guard plan.validatesPublicationClaim() else {
                throw LayerCompositorError.invalidPlan
            }
            guard !plan.preparedTiles.isEmpty else {
                let metrics = try policy.structuralMetrics(
                    tileCount: 0,
                    layerCount: 0
                )
                lastTileBatchMetrics = metrics
                return LayerCompositeTileBatchResult(
                    fullyTransparentCoordinates: [],
                    metrics: metrics
                )
            }
            let fullTileRegion = try SparseTileOutputRegion(
                minX: 0,
                minY: 0,
                maxX: PaintTileDescriptor.side,
                maxY: PaintTileDescriptor.side
            )
            let scratch = try ensureScratch(for: fullTileRegion)
            let reduction = try ensureTileReductionBuffer(
                tileCapacity: policy.maximumTilesPerChunk
            )
            let bindingCoordinates = Set(bindingByCoordinate.keys)
            let sortedTiles = plan.preparedTiles.filter {
                bindingCoordinates.contains($0.coordinate)
            }.sorted {
                $0.coordinate < $1.coordinate
            }
            guard sortedTiles.count == bindings.count else {
                throw LayerCompositorError.invalidPlan
            }
            var chunkStart = 0
            while chunkStart < sortedTiles.count {
                try Task.checkCancellation()
                guard plan.validatesPublicationClaim() else {
                    throw LayerCompositorError.invalidPlan
                }
                let chunkEnd = min(
                    sortedTiles.count,
                    chunkStart + policy.maximumTilesPerChunk
                )
                let chunk = Array(sortedTiles[chunkStart..<chunkEnd])
                memset(
                    reduction.contents(),
                    0,
                    Self.tileReductionStride * chunk.count
                )
                guard let commandBuffer = commandQueue.makeCommandBuffer()
                else { throw LayerCompositorError.commandCreationFailed }
                var terminals: [(
                    prepared: SparseTileSamplingPreparedSubmission,
                    content: SparseTileSamplingPlanContent,
                    waiter: LayerCompositorSamplingTerminalWaiter
                )] = []
                terminals.reserveCapacity(
                    chunk.count * policy.maximumLayersPerTile
                )
                var encodedWork = false
                do {
                    for (tileIndex, tile) in chunk.enumerated() {
                        try Task.checkCancellation()
                        guard let binding = bindingByCoordinate[tile.coordinate]
                        else { throw LayerCompositorError.invalidPlan }
                        try validateTarget(binding.texture, for: fullTileRegion)
                        if tile.layers.isEmpty {
                            try encodeClear(
                                binding.texture,
                                commandBuffer: commandBuffer
                            )
                            encodedWork = true
                        } else {
                            var backdrop = scratch.accumulationA
                            for (layerIndex, layer) in tile.layers.enumerated() {
                                let prepared = try await prepareTileSubmission(
                                    layer: layer,
                                    from: plan,
                                    outputRegion: tile.outputRegion
                                )
                                let waiter = LayerCompositorSamplingTerminalWaiter()
                                var samplingSubmitted = false
                                do {
                                    let encodeIndex = sampleEncodeAttemptCount
                                    sampleEncodeAttemptCount += 1
                                    if failureInjection?
                                        .failingSampleEncodeIndex == encodeIndex {
                                        throw LayerCompositorError.commandFailed(
                                            "injected tile sample encode failure"
                                        )
                                    }
                                    if layerIndex == 0 {
                                        try encodeClear(
                                            backdrop,
                                            commandBuffer: commandBuffer
                                        )
                                        encodedWork = true
                                    }
                                    let pass = MTLRenderPassDescriptor()
                                    pass.colorAttachments[0].texture = scratch.sample
                                    pass.colorAttachments[0].loadAction = .clear
                                    pass.colorAttachments[0].storeAction = .store
                                    pass.colorAttachments[0].clearColor = .init(
                                        red: 0, green: 0, blue: 0, alpha: 0
                                    )
                                    try prepared.submission.encode(
                                        target: scratch.sample,
                                        commandBuffer: commandBuffer,
                                        renderPassDescriptor: pass,
                                        afterResourcesReturned: { _, succeeded in
                                            waiter.recordAuthenticatedReturn(
                                                commandSucceeded: succeeded
                                            )
                                        },
                                        afterTerminalRecorded: { terminal in
                                            waiter.recordTerminal(terminal)
                                        }
                                    )
                                    samplingSubmitted = true
                                    terminals.append((
                                        prepared.submission,
                                        prepared.content,
                                        waiter
                                    ))
                                    sampleEncodeCount += 1
                                    maximumPrepared = max(
                                        maximumPrepared,
                                        terminals.count
                                    )
                                    encodedWork = true
                                    let last = layerIndex == tile.layers.count - 1
                                    let destination: any MTLTexture = last
                                        ? binding.texture
                                        : (backdrop === scratch.accumulationA
                                            ? scratch.accumulationB
                                            : scratch.accumulationA)
                                    try blendPipeline.encode(
                                        source: scratch.sample,
                                        backdrop: backdrop,
                                        target: destination,
                                        opacity: layer.opacity,
                                        mode: layer.blendMode,
                                        commandBuffer: commandBuffer
                                    )
                                    backdrop = destination
                                } catch {
                                    if !samplingSubmitted {
                                        prepared.submission.abandon(
                                            afterResourcesReturned: { _ in
                                                waiter.recordAuthenticatedReturn(
                                                    commandSucceeded: nil
                                                )
                                            },
                                            afterTerminalRecorded: { terminal in
                                                waiter.recordTerminal(terminal)
                                            }
                                        )
                                        _ = await waiter.wait()
                                        await gpuPlanCache.invalidate(
                                            content: prepared.content
                                        )
                                    }
                                    throw error
                                }
                            }
                        }
                        let logical = binding.descriptor.logicalBounds
                        try blendPipeline.encodeAlphaReduction(
                            source: binding.texture,
                            logicalExtent: SIMD2(
                                UInt32(logical.width),
                                UInt32(logical.height)
                            ),
                            reductionBuffer: reduction,
                            reductionOffset:
                                tileIndex * Self.tileReductionStride,
                            commandBuffer: commandBuffer
                        )
                        encodedWork = true
                    }
                } catch {
                    let operationError = error
                    if encodedWork {
                        let commandWaiter = LayerCompositorCommandWaiter()
                        commandBuffer.addCompletedHandler { command in
                            commandWaiter.record(command.status == .completed)
                        }
                        inflightCommandCount += 1
                        commandBuffer.commit()
                        for terminal in terminals {
                            _ = await terminal.waiter.wait()
                            await gpuPlanCache.invalidate(
                                content: terminal.content
                            )
                        }
                        _ = await commandWaiter.wait()
                        inflightCommandCount -= 1
                    } else {
                        for terminal in terminals {
                            terminal.prepared.abandon(
                                afterResourcesReturned: { _ in
                                    terminal.waiter.recordAuthenticatedReturn(
                                        commandSucceeded: nil
                                    )
                                },
                                afterTerminalRecorded: { value in
                                    terminal.waiter.recordTerminal(value)
                                }
                            )
                        }
                        for terminal in terminals {
                            _ = await terminal.waiter.wait()
                            await gpuPlanCache.invalidate(
                                content: terminal.content
                            )
                        }
                    }
                    throw operationError
                }

                let commandWaiter = LayerCompositorCommandWaiter()
                commandBuffer.addCompletedHandler { command in
                    commandWaiter.record(command.status == .completed)
                }
                inflightCommandCount += 1
                commandBuffer.commit()
                commandCount += 1
                var authenticated = true
                for terminal in terminals {
                    let resolution = await terminal.waiter.wait()
                    authenticated = authenticated
                        && resolution.terminal.resourcesReturned
                        && resolution.authenticatedCommandSucceeded == true
                }
                let commandSucceeded = await commandWaiter.wait()
                inflightCommandCount -= 1
                for terminal in terminals {
                    await gpuPlanCache.invalidate(content: terminal.content)
                }
                guard authenticated, commandSucceeded,
                      commandBuffer.status == .completed
                else {
                    throw LayerCompositorError.commandFailed(
                        commandBuffer.error?.localizedDescription
                            ?? "command status \(commandBuffer.status.rawValue)"
                    )
                }
                if failureInjection?.failingCommandTerminalChunkIndex
                    == commandCount - 1 {
                    throw LayerCompositorError.commandFailed(
                        "injected tile command terminal failure"
                    )
                }
                for (tileIndex, tile) in chunk.enumerated() {
                    let pointer = reduction.contents()
                        .advanced(by: tileIndex * Self.tileReductionStride)
                        .assumingMemoryBound(
                            to: PatternDocumentPaintMutationReduction.self
                        )
                    guard pointer.pointee.invalid == 0 else {
                        throw LayerCompositorError.commandFailed(
                            "canonical tile contains invalid premultiplied pixels"
                        )
                    }
                    if pointer.pointee.maximumAlphaBits == 0 {
                        transparent.append(tile.coordinate)
                    }
                }
                chunkStart = chunkEnd
            }
            guard plan.validatesPublicationClaim() else {
                throw LayerCompositorError.invalidPlan
            }
            let metrics = CanvasCompositeBatchMetrics(
                commandSubmissionCount: commandCount,
                commandWaitCount: commandCount,
                sampleEncodeCount: sampleEncodeCount,
                scratchSetCount: 1,
                maximumScratchPixelCount:
                    PaintTileDescriptor.side * PaintTileDescriptor.side,
                maximumPreparedSubmissionCount: maximumPrepared
            )
            lastTileBatchMetrics = metrics
            return LayerCompositeTileBatchResult(
                fullyTransparentCoordinates: transparent.sorted(),
                metrics: metrics
            )
        } catch {
            guard await performBoundedCleanup() else {
                throw LayerCompositorError.cleanupPending
            }
            throw error
        }
    }

    /// Consumes one coherent layer plan into the reusable bounded display
    /// scratch, then reserves that exact result until one encode or cancel
    /// terminal. No persistent viewport composite is cached.
    func prepareDisplay(
        _ plan: PreparedLayerCompositePlan,
        parameters: SparseTileSamplingEncodeParameters,
        onTerminal: @escaping @Sendable () -> Void = {}
    ) async throws -> PreparedLayerCompositeDisplaySubmission {
        defer { plan.close() }
        await settleActiveDisplaySubmission()
        guard !isBusy else { throw LayerCompositorError.busy }
        guard parameters.outputMapping == plan.outputMapping else {
            throw LayerCompositorError.invalidPlan
        }
        isBusy = true
        do {
            let source = try await performCompositeToScratch(plan)
            let core = PreparedLayerCompositeDisplaySubmissionCore(
                source: source,
                outputRegion: plan.outputRegion,
                parameters: parameters,
                pipeline: blendPipeline,
                onTerminal: onTerminal
            )
            activeDisplaySubmission = core
            return PreparedLayerCompositeDisplaySubmission(core: core)
        } catch {
            isBusy = false
            throw error
        }
    }

    func retryDisplayCompletion() async throws {
        // Another actor turn may observe preparation after it claims the
        // compositor but before it publishes a display submission. That work
        // owns its inflight command and cleanup; a completion poll must neither
        // spin through the cleanup budget nor cancel the soon-to-publish frame.
        guard !isBusy || activeDisplaySubmission != nil else { return }
        reconcileDisplaySubmission()
        guard await performBoundedCleanup() else {
            throw LayerCompositorError.cleanupPending
        }
    }

    func shutdown() async throws {
        await settleActiveDisplaySubmission()
        guard await performBoundedCleanup() else {
            throw LayerCompositorError.cleanupPending
        }
        scratch = nil
        exportScratch = nil
        tileReductionBuffer = nil
    }

    private func settleActiveDisplaySubmission() async {
        guard let activeDisplaySubmission else { return }
        await activeDisplaySubmission.settle()
        reconcileDisplaySubmission()
    }

    private func reconcileDisplaySubmission() {
        guard let activeDisplaySubmission,
              activeDisplaySubmission.isTerminal
        else { return }
        self.activeDisplaySubmission = nil
        isBusy = false
    }

    private func performCompositeToScratch(
        _ plan: PreparedLayerCompositePlan
    ) async throws -> any MTLTexture {
        guard !plan.isClosed,
              plan.layers.count <= LayerStack.maximumLayerCount
        else { throw LayerCompositorError.invalidPlan }
        do {
            try Task.checkCancellation()
            let scratch = try ensureScratch(for: plan.outputRegion)
            guard !plan.layers.isEmpty else {
                try await clear(scratch.accumulationA)
                return scratch.accumulationA
            }
            var backdrop = scratch.accumulationA
            for (index, layer) in plan.layers.enumerated() {
                try Task.checkCancellation()
                let destination = backdrop === scratch.accumulationA
                    ? scratch.accumulationB : scratch.accumulationA
                try await composite(
                    layer: layer,
                    from: plan,
                    outputRegion: plan.outputRegion,
                    sample: scratch.sample,
                    backdrop: backdrop,
                    destination: destination,
                    clearBackdrop: index == 0
                )
                backdrop = destination
            }
            try Task.checkCancellation()
            guard await !hasCleanupDebt() else {
                guard await performBoundedCleanup() else {
                    throw LayerCompositorError.cleanupPending
                }
                return backdrop
            }
            return backdrop
        } catch {
            guard await performBoundedCleanup() else {
                throw LayerCompositorError.cleanupPending
            }
            throw error
        }
    }

    private func composite(
        layer: PreparedLayerCompositeLayer,
        from plan: PreparedLayerCompositePlan,
        outputRegion: SparseTileOutputRegion,
        sample: any MTLTexture,
        backdrop: any MTLTexture,
        destination: any MTLTexture,
        clearBackdrop: Bool
    ) async throws {
        guard let pipeline = samplingPipelines[
            layer.samplingPlan.outputMapping.kind
        ], let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LayerCompositorError.commandCreationFailed
        }
        var cpuPlan: SparseTileSamplingPlanLease?
        var gpuPlan: SparseTileSamplingGPUPlanLease?
        var prepared: SparseTileSamplingPreparedSubmission?
        var samplingEncoded = false
        var commandCommitted = false
        let waiter = LayerCompositorSamplingTerminalWaiter()
        do {
            let sourceBatch = try plan.sourceBatch(
                for: layer.sourceSelection
            )
            cpuPlan = try planCache.acquire(
                key: layer.samplingPlan.key,
                sourceBatch: sourceBatch,
                outputRegion: outputRegion,
                limits: planLimits,
                updating: layer.samplingPlan
            )
            gpuPlan = try await gpuPlanCache.acquire(
                plan: cpuPlan!,
                pipeline: pipeline
            )
            _ = planCache.evictContent(
                key: cpuPlan!.content.key,
                outputRegion: outputRegion
            )
            await gpuPlanCache.invalidate(content: cpuPlan!.content)
            try cpuPlan!.retire()
            cpuPlan = nil

            prepared = try SparseTileSamplingEncoder.prepareSubmission(
                plan: gpuPlan!,
                parameters: layer.samplingParameters
            )
            gpuPlan = nil
            if clearBackdrop {
                try encodeClear(backdrop, commandBuffer: commandBuffer)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = sample
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = .init(
                red: 0, green: 0, blue: 0, alpha: 0
            )
            guard let retainedPrepared = prepared else {
                preconditionFailure("sparse submission was not retained")
            }
            try retainedPrepared.encode(
                target: sample,
                commandBuffer: commandBuffer,
                renderPassDescriptor: pass,
                afterResourcesReturned: { _, succeeded in
                    waiter.recordAuthenticatedReturn(
                        commandSucceeded: succeeded
                    )
                },
                afterTerminalRecorded: { terminal in
                    waiter.recordTerminal(terminal)
                }
            )
            samplingEncoded = true
            try blendPipeline.encode(
                source: sample,
                backdrop: backdrop,
                target: destination,
                opacity: layer.opacity,
                mode: layer.blendMode,
                commandBuffer: commandBuffer
            )
            inflightCommandCount += 1
            commandBuffer.commit()
            commandCommitted = true
            let resolution = await waiter.wait()
            inflightCommandCount -= 1
            prepared = nil
            guard resolution.terminal.resourcesReturned,
                  case let .command(succeeded) = resolution.terminal.kind,
                  succeeded,
                  resolution.authenticatedCommandSucceeded == true,
                  commandBuffer.status == .completed
            else {
                throw LayerCompositorError.commandFailed(
                    commandBuffer.error?.localizedDescription
                        ?? "command status \(commandBuffer.status.rawValue)"
                )
            }
        } catch {
            let operationError = error
            if samplingEncoded && !commandCommitted {
                inflightCommandCount += 1
                commandBuffer.commit()
                _ = await waiter.wait()
                inflightCommandCount -= 1
                prepared = nil
            } else if let unsubmitted = prepared, !commandCommitted {
                unsubmitted.abandon(
                    afterResourcesReturned: { _ in
                        waiter.recordAuthenticatedReturn(commandSucceeded: nil)
                    },
                    afterTerminalRecorded: { terminal in
                        waiter.recordTerminal(terminal)
                    }
                )
                _ = await waiter.wait()
                prepared = nil
            } else if let unpreparedGPUPlan = gpuPlan {
                try? unpreparedGPUPlan.complete()
                gpuPlan = nil
            }
            if let unretiredCPUPlan = cpuPlan {
                _ = planCache.evictContent(
                    key: unretiredCPUPlan.content.key,
                    outputRegion: outputRegion
                )
                await gpuPlanCache.invalidate(content: unretiredCPUPlan.content)
                try? unretiredCPUPlan.retire()
                cpuPlan = nil
            }
            throw operationError
        }
    }

    private static let tileReductionStride = 256

    private func ensureTileReductionBuffer(
        tileCapacity: Int
    ) throws -> any MTLBuffer {
        let (required, overflow) = Self.tileReductionStride
            .multipliedReportingOverflow(by: tileCapacity)
        guard !overflow, required > 0 else {
            throw LayerCompositorError.invalidLimit
        }
        if let tileReductionBuffer,
           tileReductionBuffer.length >= required {
            return tileReductionBuffer
        }
        guard let buffer = device.makeBuffer(
            length: required,
            options: .storageModeShared
        ) else { throw LayerCompositorError.scratchAllocationFailed }
        buffer.label = "Canonical Tile Alpha Reductions"
        tileReductionBuffer = buffer
        return buffer
    }

    private func prepareTileSubmission(
        layer: PreparedLayerCompositeLayer,
        from plan: CanvasCompositeTileUpdatePlan,
        outputRegion: SparseTileOutputRegion
    ) async throws -> PreparedTileSampling {
        guard let pipeline = samplingPipelines[
            layer.samplingPlan.outputMapping.kind
        ] else { throw LayerCompositorError.invalidPlan }
        var cpuPlan: SparseTileSamplingPlanLease?
        var gpuPlan: SparseTileSamplingGPUPlanLease?
        do {
            let sourceBatch = try plan.sourceBatch(
                for: layer.sourceSelection
            )
            cpuPlan = try planCache.acquire(
                key: layer.samplingPlan.key,
                sourceBatch: sourceBatch,
                outputRegion: outputRegion,
                limits: planLimits,
                // Tile-local plans are independently numbered from slot zero.
                // They are immutable preparation evidence, not a predecessor
                // for this shared live-slot generation.
                updating: nil
            )
            gpuPlan = try await gpuPlanCache.acquire(
                plan: cpuPlan!,
                pipeline: pipeline
            )
            let content = cpuPlan!.content
            _ = planCache.evictContent(
                key: content.key,
                outputRegion: outputRegion
            )
            try cpuPlan!.retire()
            cpuPlan = nil
            let prepared = try SparseTileSamplingEncoder.prepareSubmission(
                plan: gpuPlan!,
                parameters: layer.samplingParameters
            )
            gpuPlan = nil
            await recordPhysicalWorkspaceHighWater()
            return PreparedTileSampling(
                submission: prepared,
                content: content
            )
        } catch {
            if let gpuPlan { try? gpuPlan.complete() }
            if let cpuPlan {
                _ = planCache.evictContent(
                    key: cpuPlan.content.key,
                    outputRegion: outputRegion
                )
                await gpuPlanCache.invalidate(content: cpuPlan.content)
                try? cpuPlan.retire()
            }
            throw error
        }
    }

    private func clear(_ target: any MTLTexture) async throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LayerCompositorError.commandCreationFailed
        }
        try encodeClear(target, commandBuffer: commandBuffer)
        let waiter = LayerCompositorCommandWaiter()
        commandBuffer.addCompletedHandler { command in
            waiter.record(command.status == .completed)
        }
        inflightCommandCount += 1
        commandBuffer.commit()
        let succeeded = await waiter.wait()
        inflightCommandCount -= 1
        guard succeeded else {
            throw LayerCompositorError.commandFailed(
                commandBuffer.error?.localizedDescription
                    ?? "command status \(commandBuffer.status.rawValue)"
            )
        }
    }

    private func encodeClear(
        _ texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = .init(
            red: 0, green: 0, blue: 0, alpha: 0
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else { throw LayerCompositorError.commandCreationFailed }
        encoder.endEncoding()
    }

    private func validateTarget(
        _ target: any MTLTexture,
        for region: SparseTileOutputRegion
    ) throws {
        guard target.device.registryID == device.registryID,
              target.pixelFormat == .rgba16Float,
              target.textureType == .type2D,
              target.sampleCount == 1,
              target.width == region.width,
              target.height == region.height,
              target.depth == 1,
              target.usage.contains(.shaderWrite),
              target.usage.contains(.renderTarget)
        else { throw LayerCompositorError.invalidTarget }
    }

    private func ensureScratch(
        for region: SparseTileOutputRegion
    ) throws -> Scratch {
        let (pixels, pixelOverflow) = region.width
            .multipliedReportingOverflow(by: region.height)
        let (oneTextureBytes, byteOverflow) = pixels
            .multipliedReportingOverflow(by: 8)
        let (requiredBytes, totalOverflow) = oneTextureBytes
            .multipliedReportingOverflow(by: 3)
        guard !pixelOverflow, !byteOverflow, !totalOverflow else {
            throw LayerCompositorError.scratchLimitExceeded(
                required: Int.max,
                maximum: limits.maximumScratchBytes
            )
        }
        guard region.width <= limits.maximumWidth,
              region.height <= limits.maximumHeight,
              requiredBytes <= limits.maximumScratchBytes
        else {
            throw LayerCompositorError.scratchLimitExceeded(
                required: requiredBytes,
                maximum: limits.maximumScratchBytes
            )
        }
        if let scratch,
           scratch.width == region.width,
           scratch.height == region.height {
            return scratch
        }
        let sample = try makeScratchTexture(
            width: region.width,
            height: region.height,
            usage: [.renderTarget, .shaderRead]
        )
        let accumulationA = try makeScratchTexture(
            width: region.width,
            height: region.height,
            usage: [.renderTarget, .shaderRead, .shaderWrite]
        )
        let accumulationB = try makeScratchTexture(
            width: region.width,
            height: region.height,
            usage: [.renderTarget, .shaderRead, .shaderWrite]
        )
        let scratch = Scratch(
            sample: sample,
            accumulationA: accumulationA,
            accumulationB: accumulationB,
            width: region.width,
            height: region.height,
            bytes: requiredBytes
        )
        self.scratch = scratch
        return scratch
    }

    private func exportRegions(
        for full: SparseTileOutputRegion
    ) throws -> [SparseTileOutputRegion] {
        let chunkWidth = min(limits.maximumWidth, 1_024)
        let chunkHeight = min(limits.maximumHeight, 1_024)
        var regions: [SparseTileOutputRegion] = []
        var y = full.minY
        while y < full.maxY {
            let maxY = min(full.maxY, y + chunkHeight)
            var x = full.minX
            while x < full.maxX {
                let maxX = min(full.maxX, x + chunkWidth)
                regions.append(try SparseTileOutputRegion(
                    minX: x,
                    minY: y,
                    maxX: maxX,
                    maxY: maxY
                ))
                x = maxX
            }
            y = maxY
        }
        return regions
    }

    private func ensureExportScratch(
        for region: SparseTileOutputRegion
    ) throws -> ExportScratch {
        if let exportScratch,
           exportScratch.width == region.width,
           exportScratch.height == region.height {
            return exportScratch
        }
        let (pixelCount, pixelOverflow) = region.width
            .multipliedReportingOverflow(by: region.height)
        let (workingBytes, workingOverflow) = pixelCount
            .multipliedReportingOverflow(by: 8)
        let alignedBytesPerRow = try DocumentPaintStableSnapshotChunkPlanner
            .alignedReadbackBytesPerRow(width: region.width)
        let (readbackBytes, readbackOverflow) = alignedBytesPerRow
            .multipliedReportingOverflow(by: region.height)
        let (rgbaScratchBytes, rgbaOverflow) = workingBytes
            .multipliedReportingOverflow(by: 4)
        let (interchangeBytes, interchangeOverflow) = pixelCount
            .multipliedReportingOverflow(by: 4)
        let (withInterchange, firstOverflow) = rgbaScratchBytes
            .addingReportingOverflow(interchangeBytes)
        let (totalBytes, totalOverflow) = withInterchange
            .addingReportingOverflow(readbackBytes)
        guard !pixelOverflow,
              !workingOverflow,
              !readbackOverflow,
              !rgbaOverflow,
              !interchangeOverflow,
              !firstOverflow,
              !totalOverflow,
              totalBytes <= limits.maximumScratchBytes,
              readbackBytes <= device.maxBufferLength
        else {
            throw LayerCompositorError.scratchLimitExceeded(
                required: totalOverflow ? Int.max : totalBytes,
                maximum: limits.maximumScratchBytes
            )
        }
        exportScratch = nil
        let working = try makeScratchTexture(
            width: region.width,
            height: region.height,
            usage: [.renderTarget, .shaderRead, .shaderWrite]
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.interchangePixelFormat,
            width: region.width,
            height: region.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite]
        guard let interchange = device.makeTexture(descriptor: descriptor),
              let readback = device.makeBuffer(
                length: readbackBytes,
                options: .storageModeShared
              )
        else { throw LayerCompositorError.scratchAllocationFailed }
        let result = ExportScratch(
            working: working,
            interchange: interchange,
            readback: readback,
            width: region.width,
            height: region.height,
            alignedBytesPerRow: alignedBytesPerRow,
            bytes: workingBytes + interchangeBytes + readbackBytes
        )
        exportScratch = result
        return result
    }

    private func packAndReadback(_ scratch: ExportScratch) async throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LayerCompositorError.commandCreationFailed
        }
        try blendPipeline.encodeInterchange(
            source: scratch.working,
            target: scratch.interchange,
            commandBuffer: commandBuffer
        )
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LayerCompositorError.commandCreationFailed
        }
        blit.copy(
            from: scratch.interchange,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: scratch.width,
                height: scratch.height,
                depth: 1
            ),
            to: scratch.readback,
            destinationOffset: 0,
            destinationBytesPerRow: scratch.alignedBytesPerRow,
            destinationBytesPerImage:
                scratch.alignedBytesPerRow * scratch.height
        )
        blit.endEncoding()
        let waiter = LayerCompositorCommandWaiter()
        commandBuffer.addCompletedHandler { command in
            waiter.record(command.status == .completed)
        }
        inflightCommandCount += 1
        commandBuffer.commit()
        let succeeded = await waiter.wait()
        inflightCommandCount -= 1
        guard succeeded else {
            throw LayerCompositorError.commandFailed(
                commandBuffer.error?.localizedDescription
                    ?? "command status \(commandBuffer.status.rawValue)"
            )
        }
    }

    private func makeExportChunk(
        region: SparseTileOutputRegion,
        scratch: ExportScratch
    ) throws -> DocumentPaintStableSnapshotChunk {
        let (tightBytesPerRow, rowOverflow) = region.width
            .multipliedReportingOverflow(by: 4)
        let (byteCount, byteOverflow) = tightBytesPerRow
            .multipliedReportingOverflow(by: region.height)
        guard !rowOverflow, !byteOverflow else {
            throw LayerCompositorError.scratchAllocationFailed
        }
        var bytes = Data(count: byteCount)
        bytes.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            let sourceBase = scratch.readback.contents()
            for row in 0..<region.height {
                memcpy(
                    destinationBase.advanced(by: row * tightBytesPerRow),
                    sourceBase.advanced(
                        by: row * scratch.alignedBytesPerRow
                    ),
                    tightBytesPerRow
                )
            }
        }
        return DocumentPaintStableSnapshotChunk(
            outputRegion: region,
            bytesPerRow: tightBytesPerRow,
            bytes: bytes
        )
    }

    private func makeScratchTexture(
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LayerCompositorError.scratchAllocationFailed
        }
        return texture
    }

    private func performBoundedCleanup() async -> Bool {
        for _ in 0..<limits.maximumCleanupPasses {
            try? planCache.retryPendingRetirements()
            _ = await gpuPlanCache.retryPendingPlanCompletions()
            try? planCache.retryPendingRetirements()
            _ = await gpuPlanCache.retryPendingPlanCompletions()
            if await !hasCleanupDebt() { return true }
        }
        return await !hasCleanupDebt()
    }

    private func hasCleanupDebt() async -> Bool {
        let cpu = planCache.snapshot()
        let gpu = await gpuPlanCache.allocationSnapshot
        let completion = await gpuPlanCache.completionSnapshot
        return cpu.cachedContentCount > 0
            || cpu.activeContentAcquisitionCount > 0
            || cpu.pendingRetirementCount > 0
            || gpu.preparedContentCount > 0
            || (gpu.uploadRing?.activeSlotCount ?? 0) > 0
            || completion.pendingPlanCompletionCount > 0
            || completion.pendingConsumerCompletionCount > 0
            || inflightCommandCount > 0
    }
}

private final class LayerCompositorSamplingTerminalWaiter: @unchecked Sendable {
    struct Resolution: Sendable {
        let terminal: SparseTileSamplingTerminalRecord
        let authenticatedCommandSucceeded: Bool?
    }

    private let lock = NSLock()
    private var terminal: SparseTileSamplingTerminalRecord?
    private var authenticatedCommandSucceeded: Bool?
    private var authenticatedReturnObserved = false
    private var continuation: CheckedContinuation<Resolution, Never>?

    func recordTerminal(_ value: SparseTileSamplingTerminalRecord) {
        lock.lock()
        precondition(terminal == nil)
        terminal = value
        resumeIfReadyLocked()
    }

    func recordAuthenticatedReturn(commandSucceeded: Bool?) {
        lock.lock()
        precondition(!authenticatedReturnObserved)
        authenticatedReturnObserved = true
        authenticatedCommandSucceeded = commandSucceeded
        resumeIfReadyLocked()
    }

    func wait() async -> Resolution {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolution = resolutionIfReadyLocked() {
                lock.unlock()
                continuation.resume(returning: resolution)
            } else {
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func resumeIfReadyLocked() {
        let resolution = resolutionIfReadyLocked()
        let continuation = resolution == nil ? nil : self.continuation
        if continuation != nil { self.continuation = nil }
        lock.unlock()
        if let resolution, let continuation {
            continuation.resume(returning: resolution)
        }
    }

    private func resolutionIfReadyLocked() -> Resolution? {
        guard let terminal else { return nil }
        guard !terminal.resourcesReturned || authenticatedReturnObserved else {
            return nil
        }
        return Resolution(
            terminal: terminal,
            authenticatedCommandSucceeded: authenticatedCommandSucceeded
        )
    }
}

private final class LayerCompositorCommandWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func record(_ value: Bool) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            result = value
            lock.unlock()
        }
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
