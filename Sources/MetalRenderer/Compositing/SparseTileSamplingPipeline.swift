import CShaderTypes
import Foundation
import Metal
import PatternEngine

enum SparseTileSamplingBackendRequest: Equatable, Sendable {
    case automatic
    case forceTier2
    case forceFallback
}

struct SparseTileSamplingDeviceCapabilities: Equatable, Sendable {
    let supportsTier2ArgumentBuffers: Bool

    init(supportsTier2ArgumentBuffers: Bool) {
        self.supportsTier2ArgumentBuffers = supportsTier2ArgumentBuffers
    }

    init(device: any MTLDevice) {
        supportsTier2ArgumentBuffers = device.argumentBuffersSupport == .tier2
    }
}

enum SparseTileSamplingBackend: UInt8, Hashable, Sendable {
    case tier2ArgumentBuffer
    case directFallback

    static func select(
        request: SparseTileSamplingBackendRequest,
        capabilities: SparseTileSamplingDeviceCapabilities
    ) throws -> Self {
        switch request {
        case .automatic:
            capabilities.supportsTier2ArgumentBuffers
                ? .tier2ArgumentBuffer : .directFallback
        case .forceTier2:
            if capabilities.supportsTier2ArgumentBuffers {
                .tier2ArgumentBuffer
            } else {
                throw SparseTileSamplingPipelineError.unsupportedTier2
            }
        case .forceFallback:
            .directFallback
        }
    }
}

struct SparseTileSamplingPipelineKey: Hashable, Sendable {
    let backend: SparseTileSamplingBackend
    let outputPixelFormatRawValue: UInt
    let sampleCount: Int
    let abiVersion: UInt16
    let outputMappingKind: SparseTileSamplingOutputMappingKind

    init(
        backend: SparseTileSamplingBackend,
        outputPixelFormatRawValue: UInt,
        sampleCount: Int,
        abiVersion: UInt16,
        outputMappingKind: SparseTileSamplingOutputMappingKind = .affine
    ) {
        self.backend = backend
        self.outputPixelFormatRawValue = outputPixelFormatRawValue
        self.sampleCount = sampleCount
        self.abiVersion = abiVersion
        self.outputMappingKind = outputMappingKind
    }
}

enum SparseTileSamplingOutputContract: Equatable, Sendable {
    case workingLinearPremultiplied
    case displayOpaqueSRGB
    case interchangeEncodedPremultiplied

    static func derive(pixelFormatRawValue: UInt) throws -> Self {
        if pixelFormatRawValue
            == DocumentColorPipeline.workingPixelFormat.rawValue
        {
            return .workingLinearPremultiplied
        }
        if pixelFormatRawValue
            == DocumentColorPipeline.displayPixelFormat.rawValue
        {
            return .displayOpaqueSRGB
        }
        if pixelFormatRawValue
            == DocumentColorPipeline.interchangePixelFormat.rawValue
        {
            return .interchangeEncodedPremultiplied
        }
        throw SparseTileSamplingPipelineError.invalidPixelFormat(
            pixelFormatRawValue
        )
    }
}

enum SparseTileSamplingPipelineError: Error, Equatable, Sendable {
    case unsupportedABI(UInt16)
    case unsupportedBackend(SparseTileSamplingBackend)
    case unsupportedTier2
    case invalidPixelFormat(UInt)
    case invalidSampleCount(Int)
    case invalidTarget(String)
    case invalidUsage(UInt)
    case targetSourceAlias
    case malformedDescriptor(Int)
    case malformedEntry(Int)
    case malformedRemap(Int)
    case limitExceeded(required: Int, maximum: Int)
    case byteOverflow
    case incompleteHalo
    case stalePlan
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String)
    case argumentEncoderUnavailable
    case bufferCreationFailed(String)
    case proportionalBufferCreationFailed(label: String, requiredBytes: Int)
    case injectedFailure(String)
    case alreadyConsumed
}

final class SparseTileSamplingPreparedAbandonmentFailureInjector:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var remainingFailures: Int

    init(failures: Int) {
        precondition(failures >= 0)
        remainingFailures = failures
    }

    fileprivate func failIfRequested() throws {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else { return }
        remainingFailures -= 1
        throw SparseTileSamplingPipelineError.injectedFailure(
            "preparedAbandonment"
        )
    }
}

final class SparseTileSamplingCompletionFailureInjector:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var remainingFailures: Int

    init(failures: Int) {
        precondition(failures >= 0)
        remainingFailures = failures
    }

    fileprivate func failIfRequested() throws {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else { return }
        remainingFailures -= 1
        throw SparseTileSamplingPipelineError.injectedFailure(
            "completion"
        )
    }
}

final class SparseTileSamplingPipelineBinding: @unchecked Sendable {
    let key: SparseTileSamplingPipelineKey
    let outputContract: SparseTileSamplingOutputContract
    let state: any MTLRenderPipelineState
    fileprivate let deviceRegistryID: UInt64
    private let fragmentFunction: any MTLFunction

    fileprivate init(
        key: SparseTileSamplingPipelineKey,
        outputContract: SparseTileSamplingOutputContract,
        state: any MTLRenderPipelineState,
        fragmentFunction: any MTLFunction,
        deviceRegistryID: UInt64
    ) {
        self.key = key
        self.outputContract = outputContract
        self.state = state
        self.fragmentFunction = fragmentFunction
        self.deviceRegistryID = deviceRegistryID
    }

    /// Argument encoders are mutable. Every immutable GPU plan receives a
    /// fresh instance instead of sharing one through the pipeline cache.
    func makeArgumentEncoder() throws -> (any MTLArgumentEncoder)? {
        guard key.backend == .tier2ArgumentBuffer else { return nil }
        return fragmentFunction.makeArgumentEncoder(
            bufferIndex: Int(PatternBufferIndexSparseTextureArguments)
        )
    }
}

enum SparseTileSamplingPipeline {
    @MainActor
    static func prepare(
        device: any MTLDevice,
        library: (any MTLLibrary)?,
        key: SparseTileSamplingPipelineKey,
        capabilities: SparseTileSamplingDeviceCapabilities? = nil
    ) throws -> SparseTileSamplingPipelineBinding {
        guard key.abiVersion == SparseSamplingABI.version else {
            throw SparseTileSamplingPipelineError.unsupportedABI(
                key.abiVersion
            )
        }
        let outputContract = try SparseTileSamplingOutputContract.derive(
            pixelFormatRawValue: key.outputPixelFormatRawValue
        )
        guard let outputPixelFormat = MTLPixelFormat(
            rawValue: key.outputPixelFormatRawValue
        ) else {
            throw SparseTileSamplingPipelineError.invalidPixelFormat(
                key.outputPixelFormatRawValue
            )
        }
        guard key.sampleCount == 1 else {
            throw SparseTileSamplingPipelineError.invalidSampleCount(
                key.sampleCount
            )
        }
        let resolvedCapabilities = capabilities
            ?? SparseTileSamplingDeviceCapabilities(device: device)
        if key.backend == .tier2ArgumentBuffer,
           !resolvedCapabilities.supportsTier2ArgumentBuffers {
            throw SparseTileSamplingPipelineError.unsupportedTier2
        }
        guard let library else {
            throw SparseTileSamplingPipelineError.shaderLibraryUnavailable
        }
        guard let vertex = library.makeFunction(
            name: "patternSparseSamplingVertex"
        ) else {
            throw SparseTileSamplingPipelineError.shaderFunctionUnavailable(
                "patternSparseSamplingVertex"
            )
        }
        let fragmentName = switch (
            key.outputMappingKind,
            outputContract,
            key.backend
        ) {
        case (
            .finiteRadial, .workingLinearPremultiplied,
            .tier2ArgumentBuffer
        ):
            "patternSparseRadialSamplingWorkingTier2Fragment"
        case (
            .finiteRadial, .workingLinearPremultiplied,
            .directFallback
        ):
            "patternSparseRadialSamplingWorkingFallbackFragment"
        case (.finiteRadial, .displayOpaqueSRGB, .tier2ArgumentBuffer):
            "patternSparseRadialSamplingDisplayTier2Fragment"
        case (.finiteRadial, .displayOpaqueSRGB, .directFallback):
            "patternSparseRadialSamplingDisplayFallbackFragment"
        case (
            .finiteRadial, .interchangeEncodedPremultiplied,
            .tier2ArgumentBuffer
        ):
            "patternSparseRadialSamplingInterchangeTier2Fragment"
        case (
            .finiteRadial, .interchangeEncodedPremultiplied,
            .directFallback
        ):
            "patternSparseRadialSamplingInterchangeFallbackFragment"
        case (
            .affine, .interchangeEncodedPremultiplied,
            .tier2ArgumentBuffer
        ):
            "patternSparseSamplingInterchangeTier2Fragment"
        case (
            .affine, .interchangeEncodedPremultiplied,
            .directFallback
        ):
            "patternSparseSamplingInterchangeFallbackFragment"
        case (.affine, _, .tier2ArgumentBuffer):
            "patternSparseSamplingTier2Fragment"
        case (.affine, _, .directFallback):
            "patternSparseSamplingFallbackFragment"
        }
        guard let fragment = library.makeFunction(name: fragmentName) else {
            throw SparseTileSamplingPipelineError.shaderFunctionUnavailable(
                fragmentName
            )
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Inactive Sparse Tile Sampling \(key.backend)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.rasterSampleCount = key.sampleCount
        guard let attachment = descriptor.colorAttachments[0] else {
            throw SparseTileSamplingPipelineError.pipelineCreationFailed(
                "Metal did not provide color attachment zero."
            )
        }
        attachment.pixelFormat = outputPixelFormat
        if outputContract == .displayOpaqueSRGB {
            // The drawable is cleared opaque by its owner. Premultiplied
            // source-over therefore preserves that opaque boundary while the
            // sRGB attachment performs the sole linear-to-encoded conversion.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else {
            attachment.isBlendingEnabled = false
        }
        do {
            return SparseTileSamplingPipelineBinding(
                key: key,
                outputContract: outputContract,
                state: try device.makeRenderPipelineState(
                    descriptor: descriptor
                ),
                fragmentFunction: fragment,
                deviceRegistryID: device.registryID
            )
        } catch {
            throw SparseTileSamplingPipelineError.pipelineCreationFailed(
                error.localizedDescription
            )
        }
    }
}

struct SparseTileSamplingGPUPlanLimits: Equatable, Sendable {
    let maximumDescriptors: Int
    let maximumPageEntries: Int
    let maximumBufferBytes: Int
    let maximumInflightEncodes: Int
    let maximumCachedPlans: Int
    let maximumCachedBufferBytes: Int
    let allowsCacheEviction: Bool

    init(
        maximumDescriptors: Int,
        maximumPageEntries: Int,
        maximumBufferBytes: Int,
        maximumInflightEncodes: Int = 3,
        maximumCachedPlans: Int = 64,
        maximumCachedBufferBytes: Int = 256 * 1_024 * 1_024,
        allowsCacheEviction: Bool = true
    ) {
        self.maximumDescriptors = maximumDescriptors
        self.maximumPageEntries = maximumPageEntries
        self.maximumBufferBytes = maximumBufferBytes
        self.maximumInflightEncodes = maximumInflightEncodes
        self.maximumCachedPlans = maximumCachedPlans
        self.maximumCachedBufferBytes = maximumCachedBufferBytes
        self.allowsCacheEviction = allowsCacheEviction
    }

    static let production = SparseTileSamplingGPUPlanLimits(
        maximumDescriptors: 3,
        maximumPageEntries: 1_048_576,
        maximumBufferBytes: 64 * 1_024 * 1_024,
        maximumInflightEncodes: 3,
        maximumCachedPlans: 64,
        maximumCachedBufferBytes: 256 * 1_024 * 1_024
    )
}

enum SparseTileSamplingWorkspaceAllocation: Equatable, Sendable {
    case descriptors(capacity: Int)
    case entries(capacity: Int)
}

struct SparseTileSamplingUploadRingSnapshot: Equatable, Sendable {
    let capacity: Int
    let activeSlotCount: Int
    let highWaterSlotCount: Int
    let metalBufferAllocationCount: Int
    let metalBufferBytes: Int
}

struct SparseTileSamplingGPUCacheSnapshot: Equatable, Sendable {
    let preparedContentCount: Int
    let hitCount: UInt64
    let missCount: UInt64
    let cachedPlanMetalBufferBytes: Int
    let planMetalBufferAllocationCount: Int
    let planMetalBufferAllocationBytes: Int
    let uploadRing: SparseTileSamplingUploadRingSnapshot?
}

/// Read-only identities for auditing one exact prepared sparse submission.
/// They expose no Metal resource or lifetime authority.
struct SparseTileSamplingPreparedResourceIdentity:
    Hashable, @unchecked Sendable
{
    let preparedSubmission: ObjectIdentifier
    let gpuPlanContent: ObjectIdentifier
    let uploadRing: ObjectIdentifier
    let uploadLease: ObjectIdentifier
}

/// Authentication minted only by P4 after every retained frame resource has
/// been returned. Higher layers cannot manufacture an early terminal event.
struct SparseTileSamplingResourceReturnReceipt: Hashable, Sendable {
    let identity: UUID
    init() { identity = UUID() }
}

/// Unauthenticated command-terminal observation. Unlike the exact resource
/// return receipt, this record always fires once after the mailbox has either
/// returned the plan or retained it for retryable cleanup.
enum SparseTileSamplingTerminalKind: Equatable, Sendable {
    case command(succeeded: Bool)
    case abandoned
}

struct SparseTileSamplingTerminalRecord: Equatable, Sendable {
    let kind: SparseTileSamplingTerminalKind
    let resourcesReturned: Bool
}

private final class SparseTileSamplingUploadLease: @unchecked Sendable {
    let buffer: any MTLBuffer
    let uniformsOffset: Int
    let gridFrameOffset: Int
    let radialFrameOffset: Int
    let materialOffset: Int
    private let ring: SparseTileSamplingUploadRing
    private let slot: Int
    private let generation: UInt64
    private let lock = NSLock()
    private var completed = false

    init(
        buffer: any MTLBuffer,
        uniformsOffset: Int,
        gridFrameOffset: Int,
        radialFrameOffset: Int,
        materialOffset: Int,
        ring: SparseTileSamplingUploadRing,
        slot: Int,
        generation: UInt64
    ) {
        self.buffer = buffer
        self.uniformsOffset = uniformsOffset
        self.gridFrameOffset = gridFrameOffset
        self.radialFrameOffset = radialFrameOffset
        self.materialOffset = materialOffset
        self.ring = ring
        self.slot = slot
        self.generation = generation
    }

    func complete() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        ring.returnSlot(slot, generation: generation)
    }

    deinit { complete() }
}

private final class SparseTileSamplingUploadRing: @unchecked Sendable {
    private static let slotStride = 512
    private static let gridFrameOffsetInSlot = 64
    private static let radialFrameOffsetInSlot = 160
    private static let materialOffsetInSlot = 256

    private let buffer: any MTLBuffer
    private let lock = NSLock()
    private var active: [Bool]
    private var generations: [UInt64]
    private var highWater = 0
    private let metalBufferAllocationCount: Int
    private let metalBufferBytes: Int

    init(device: any MTLDevice, capacity: Int) throws {
        guard capacity > 0,
              capacity <= Int.max / Self.slotStride
        else {
            throw SparseTileSamplingPipelineError.byteOverflow
        }
        let length = try Self.requiredByteCount(capacity: capacity)
        var allocationCount = 0
        guard let buffer = device.makeBuffer(
            length: length,
            options: .storageModeShared
        ) else {
            throw SparseTileSamplingPipelineError.bufferCreationFailed(
                "sparse upload ring"
            )
        }
        allocationCount += 1
        buffer.label = "Sparse Sampling Upload Ring"
        self.buffer = buffer
        metalBufferAllocationCount = allocationCount
        metalBufferBytes = buffer.length
        active = Array(repeating: false, count: capacity)
        generations = Array(repeating: 0, count: capacity)
    }

    func acquire(
        uniforms: PatternSparseSamplingUniforms,
        material: PatternCompositeUniforms,
        radialFrames: (
            grid: PatternGridFrameUniforms,
            radial: PatternRadialFrameUniforms
        )? = nil
    ) throws -> SparseTileSamplingUploadLease {
        lock.lock()
        guard let slot = active.firstIndex(of: false) else {
            let capacity = active.count
            lock.unlock()
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: capacity + 1,
                maximum: capacity
            )
        }
        guard generations[slot] < UInt64.max else {
            lock.unlock()
            throw SparseTileSamplingPipelineError.byteOverflow
        }
        generations[slot] += 1
        let generation = generations[slot]
        active[slot] = true
        highWater = max(highWater, active.lazy.filter { $0 }.count)
        let base = slot * Self.slotStride
        buffer.contents().advanced(by: base)
            .assumingMemoryBound(to: PatternSparseSamplingUniforms.self)
            .pointee = uniforms
        if let radialFrames {
            buffer.contents().advanced(
                by: base + Self.gridFrameOffsetInSlot
            ).assumingMemoryBound(to: PatternGridFrameUniforms.self)
                .pointee = radialFrames.grid
            buffer.contents().advanced(
                by: base + Self.radialFrameOffsetInSlot
            ).assumingMemoryBound(to: PatternRadialFrameUniforms.self)
                .pointee = radialFrames.radial
        }
        buffer.contents().advanced(by: base + Self.materialOffsetInSlot)
            .assumingMemoryBound(to: PatternCompositeUniforms.self)
            .pointee = material
        lock.unlock()
        return SparseTileSamplingUploadLease(
            buffer: buffer,
            uniformsOffset: base,
            gridFrameOffset: base + Self.gridFrameOffsetInSlot,
            radialFrameOffset: base + Self.radialFrameOffsetInSlot,
            materialOffset: base + Self.materialOffsetInSlot,
            ring: self,
            slot: slot,
            generation: generation
        )
    }

    fileprivate func returnSlot(_ slot: Int, generation: UInt64) {
        lock.lock()
        precondition(
            slot >= 0 && slot < active.count
                && active[slot] && generations[slot] == generation,
            "Sparse upload slot returned by a stale owner"
        )
        active[slot] = false
        lock.unlock()
    }

    var snapshot: SparseTileSamplingUploadRingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SparseTileSamplingUploadRingSnapshot(
            capacity: active.count,
            activeSlotCount: active.lazy.filter { $0 }.count,
            highWaterSlotCount: highWater,
            metalBufferAllocationCount: metalBufferAllocationCount,
            metalBufferBytes: metalBufferBytes
        )
    }

    static func requiredByteCount(capacity: Int) throws -> Int {
        guard capacity > 0,
              capacity <= Int.max / slotStride
        else { throw SparseTileSamplingPipelineError.byteOverflow }
        return capacity * slotStride
    }
}

struct SparseTileSamplingCompletionSnapshot: Equatable, Sendable {
    let terminalCommandCount: UInt64
    let commandFailureCount: UInt64
    let planCompletionFailureCount: UInt64
    let pendingPlanCompletionCount: Int
    let pendingConsumerCompletionCount: Int
    let pendingPlanMetalBufferBytes: Int
    let lastFailure: String?
}

final class SparseTileSamplingCompletionMailbox: @unchecked Sendable {
    private struct PendingPlanCompletion {
        let plan: SparseTileSamplingGPUPlanLease
        let receipt: SparseTileSamplingResourceReturnReceipt
        let observer: (@Sendable (SparseTileSamplingResourceReturnReceipt) -> Void)?
    }

    private let lock = NSLock()
    private var terminalCommandCount: UInt64 = 0
    private var commandFailureCount: UInt64 = 0
    private var planCompletionFailureCount: UInt64 = 0
    private var nextPendingID: UInt64 = 0
    private var pending: [UInt64: PendingPlanCompletion] = [:]
    private var pendingConsumers: [
        UInt64: SparseTileSamplingPlanConsumerHandle
    ] = [:]
    private var lastFailure: String?

    fileprivate func recordTerminal(
        commandBuffer: any MTLCommandBuffer,
        plan: SparseTileSamplingGPUPlanLease,
        upload: SparseTileSamplingUploadLease,
        afterResourcesReturned: (@Sendable (
            SparseTileSamplingResourceReturnReceipt,
            Bool
        ) -> Void)? = nil,
        afterTerminalRecorded: (@Sendable (
            SparseTileSamplingTerminalRecord
        ) -> Void)? = nil
    ) {
        upload.complete()
        let commandFailed = commandBuffer.status != .completed
            || commandBuffer.error != nil
        let commandSucceeded = !commandFailed
        let receipt = SparseTileSamplingResourceReturnReceipt()
        let terminalObserver: (@Sendable (
            SparseTileSamplingResourceReturnReceipt
        ) -> Void)?
        if let afterResourcesReturned {
            terminalObserver = { receipt in
                afterResourcesReturned(receipt, commandSucceeded)
            }
        } else {
            terminalObserver = nil
        }
        let completionError: (any Error)?
        do {
            try plan.completeFromTerminalOwner()
            completionError = nil
        } catch {
            completionError = error
        }

        var notifyNow = false
        lock.lock()
        terminalCommandCount &+= 1
        if commandFailed {
            commandFailureCount &+= 1
            lastFailure = commandBuffer.error?.localizedDescription
                ?? "command status \(commandBuffer.status.rawValue)"
        }
        if let completionError {
            planCompletionFailureCount &+= 1
            if nextPendingID < UInt64.max {
                nextPendingID += 1
                pending[nextPendingID] = PendingPlanCompletion(
                    plan: plan,
                    receipt: receipt,
                    observer: terminalObserver
                )
            } else {
                preconditionFailure("Sparse completion identity exhausted")
            }
            lastFailure = String(describing: completionError)
        } else {
            notifyNow = true
        }
        lock.unlock()
        afterTerminalRecorded?(SparseTileSamplingTerminalRecord(
            kind: .command(succeeded: commandSucceeded),
            resourcesReturned: completionError == nil
        ))
        if notifyNow {
            afterResourcesReturned?(receipt, commandSucceeded)
        }
    }

    fileprivate func recordPreparedAbandonmentFailure(
        _ plan: SparseTileSamplingGPUPlanLease,
        error: any Error,
        receipt: SparseTileSamplingResourceReturnReceipt =
            SparseTileSamplingResourceReturnReceipt(),
        afterResourcesReturned: (@Sendable (
            SparseTileSamplingResourceReturnReceipt
        ) -> Void)? = nil,
        afterTerminalRecorded: (@Sendable (
            SparseTileSamplingTerminalRecord
        ) -> Void)? = nil
    ) {
        lock.lock()
        planCompletionFailureCount &+= 1
        if nextPendingID < UInt64.max {
            nextPendingID += 1
            pending[nextPendingID] = PendingPlanCompletion(
                plan: plan,
                receipt: receipt,
                observer: afterResourcesReturned
            )
        } else {
            preconditionFailure("Sparse completion identity exhausted")
        }
        lastFailure = String(describing: error)
        lock.unlock()
        afterTerminalRecorded?(SparseTileSamplingTerminalRecord(
            kind: .abandoned,
            resourcesReturned: false
        ))
    }

    fileprivate func recordConsumerCompletionFailure(
        _ consumer: SparseTileSamplingPlanConsumerHandle,
        error: any Error
    ) {
        lock.lock()
        planCompletionFailureCount &+= 1
        if nextPendingID < UInt64.max {
            nextPendingID += 1
            pendingConsumers[nextPendingID] = consumer
        } else {
            preconditionFailure("Sparse completion identity exhausted")
        }
        lastFailure = String(describing: error)
        lock.unlock()
    }

    /// Retries exact plans retained after a fallible P3 lease return. Failures
    /// remain owned here and visible in `snapshot`; none are discarded.
    @discardableResult
    func retryPendingPlanCompletions() -> Int {
        lock.lock()
        let candidates = pending.sorted { $0.key < $1.key }
        let consumerCandidates = pendingConsumers.sorted { $0.key < $1.key }
        lock.unlock()
        var completed: [UInt64] = []
        var notifications: [PendingPlanCompletion] = []
        for (identity, pendingCompletion) in candidates {
            do {
                try pendingCompletion.plan.completeFromMailbox()
                completed.append(identity)
                notifications.append(pendingCompletion)
            } catch {
                lock.lock()
                lastFailure = String(describing: error)
                lock.unlock()
            }
        }
        var completedConsumers: [UInt64] = []
        for (identity, consumer) in consumerCandidates {
            do {
                try consumer.complete()
                completedConsumers.append(identity)
            } catch {
                lock.lock()
                lastFailure = String(describing: error)
                lock.unlock()
            }
        }
        lock.lock()
        for identity in completed { pending.removeValue(forKey: identity) }
        for identity in completedConsumers {
            pendingConsumers.removeValue(forKey: identity)
        }
        let remaining = pending.count + pendingConsumers.count
        lock.unlock()
        for notification in notifications {
            notification.observer?(notification.receipt)
        }
        return remaining
    }

    var snapshot: SparseTileSamplingCompletionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SparseTileSamplingCompletionSnapshot(
            terminalCommandCount: terminalCommandCount,
            commandFailureCount: commandFailureCount,
            planCompletionFailureCount: planCompletionFailureCount,
            pendingPlanCompletionCount: pending.count,
            pendingConsumerCompletionCount: pendingConsumers.count,
            pendingPlanMetalBufferBytes: pending.values.reduce(0) {
                $0 + $1.plan.retainedPlanMetalBufferBytes
            },
            lastFailure: lastFailure
        )
    }
}

enum SparseTileSamplingFailurePhase: String, Equatable, Sendable {
    case descriptorBuffer
    case entryBuffer
    case argumentEncoder
    case argumentBuffer
    case fallbackRemapBuffer
    case uploadRing
    case preflightUniformBuffer
    case preflightMaterialBuffer
}

private struct SparseTileSamplingTextureSignature: Hashable, @unchecked Sendable {
    let slot: Int
    let identity: ObjectIdentifier
}

private struct SparseTileSamplingGPUPlanKey: Hashable, @unchecked Sendable {
    let contentIdentity: ObjectIdentifier
    let pipelineKey: SparseTileSamplingPipelineKey
    let textures: [SparseTileSamplingTextureSignature]
}

private struct SparseTileSamplingDraw: @unchecked Sendable {
    let scissor: MTLScissorRect
    let remapBuffer: (any MTLBuffer)?
    let textures: [(any MTLTexture)?]
}

private final class SparseTileSamplingGPUPlanContent: @unchecked Sendable {
    let key: SparseTileSamplingGPUPlanKey
    let pipeline: SparseTileSamplingPipelineBinding
    let descriptorsBuffer: any MTLBuffer
    let entriesBuffer: any MTLBuffer
    let argumentBuffer: (any MTLBuffer)?
    let allTextures: [any MTLTexture]
    let draws: [SparseTileSamplingDraw]
    let outputSize: SIMD2<Int>
    let outputOrigin: SIMD2<Int>
    let descriptorCount: Int
    let bindingCount: Int
    let layerCount: Int
    let addressing: SparseTileAddressing
    let outputMapping: SparseTileSamplingOutputMapping
    let outputToSourceTransform: SparseTileOutputToSourceTransform
    let shaderSourceOrigin: SIMD2<Float>
    let uploadRing: SparseTileSamplingUploadRing
    let completionMailbox: SparseTileSamplingCompletionMailbox
    let planMetalBufferBytes: Int

    init(
        key: SparseTileSamplingGPUPlanKey,
        pipeline: SparseTileSamplingPipelineBinding,
        descriptorsBuffer: any MTLBuffer,
        entriesBuffer: any MTLBuffer,
        argumentBuffer: (any MTLBuffer)?,
        allTextures: [any MTLTexture],
        draws: [SparseTileSamplingDraw],
        outputSize: SIMD2<Int>,
        outputOrigin: SIMD2<Int>,
        descriptorCount: Int,
        bindingCount: Int,
        layerCount: Int,
        addressing: SparseTileAddressing,
        outputMapping: SparseTileSamplingOutputMapping,
        outputToSourceTransform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        uploadRing: SparseTileSamplingUploadRing,
        completionMailbox: SparseTileSamplingCompletionMailbox,
        planMetalBufferBytes: Int
    ) {
        self.key = key
        self.pipeline = pipeline
        self.descriptorsBuffer = descriptorsBuffer
        self.entriesBuffer = entriesBuffer
        self.argumentBuffer = argumentBuffer
        self.allTextures = allTextures
        self.draws = draws
        self.outputSize = outputSize
        self.outputOrigin = outputOrigin
        self.descriptorCount = descriptorCount
        self.bindingCount = bindingCount
        self.layerCount = layerCount
        self.addressing = addressing
        self.outputMapping = outputMapping
        self.outputToSourceTransform = outputToSourceTransform
        self.shaderSourceOrigin = shaderSourceOrigin
        self.uploadRing = uploadRing
        self.completionMailbox = completionMailbox
        self.planMetalBufferBytes = planMetalBufferBytes
    }
}

final class SparseTileSamplingGPUPlanLease: @unchecked Sendable {
    private enum Ownership {
        case available
        case preflighting
        case prepared
        case inFlight
        case terminal
    }

    private enum CompletionAuthority: Equatable {
        case external
        case preparedAbandonment
        case terminalOwner
        case mailbox
    }

    fileprivate let content: SparseTileSamplingGPUPlanContent
    private let consumer: SparseTileSamplingPlanConsumerHandle
    private let preparedAbandonmentFailureInjector:
        SparseTileSamplingPreparedAbandonmentFailureInjector?
    private let completionFailureInjector:
        SparseTileSamplingCompletionFailureInjector?
    private let lock = NSLock()
    private var completionInProgress = false
    private var ownership = Ownership.available

    fileprivate init(
        content: SparseTileSamplingGPUPlanContent,
        consumer: SparseTileSamplingPlanConsumerHandle,
        preparedAbandonmentFailureInjector:
            SparseTileSamplingPreparedAbandonmentFailureInjector?,
        completionFailureInjector:
            SparseTileSamplingCompletionFailureInjector?
    ) {
        self.content = content
        self.consumer = consumer
        self.preparedAbandonmentFailureInjector =
            preparedAbandonmentFailureInjector
        self.completionFailureInjector = completionFailureInjector
    }

    var backend: SparseTileSamplingBackend { content.pipeline.key.backend }
    var drawCount: Int { content.draws.count }
    var immutableContentIdentity: ObjectIdentifier {
        ObjectIdentifier(content)
    }
    var uploadRingSnapshot: SparseTileSamplingUploadRingSnapshot {
        content.uploadRing.snapshot
    }
    var completionMailbox: SparseTileSamplingCompletionMailbox {
        content.completionMailbox
    }

    fileprivate var retainedPlanMetalBufferBytes: Int {
        content.planMetalBufferBytes
    }

    func complete() throws {
        try completeConsumer(authority: .external)
    }

    fileprivate func beginPreflight() throws {
        lock.lock()
        guard ownership == .available, !completionInProgress else {
            lock.unlock()
            throw SparseTileSamplingPipelineError.alreadyConsumed
        }
        ownership = .preflighting
        lock.unlock()
    }

    fileprivate func finishPreflight() {
        lock.lock()
        precondition(
            ownership == .preflighting && !completionInProgress,
            "Sparse preflight ownership changed before publication"
        )
        ownership = .prepared
        lock.unlock()
    }

    fileprivate func cancelPreflight() {
        lock.lock()
        precondition(
            ownership == .preflighting && !completionInProgress,
            "Sparse failed preflight ownership changed"
        )
        ownership = .available
        lock.unlock()
    }

    fileprivate func beginInFlight() throws {
        lock.lock()
        guard ownership == .prepared, !completionInProgress else {
            lock.unlock()
            throw SparseTileSamplingPipelineError.alreadyConsumed
        }
        ownership = .inFlight
        lock.unlock()
    }

    fileprivate func completePreparedAbandonment() throws {
        try preparedAbandonmentFailureInjector?.failIfRequested()
        try completeConsumer(authority: .preparedAbandonment)
    }

    fileprivate func completeFromTerminalOwner() throws {
        try completeConsumer(authority: .terminalOwner)
    }

    fileprivate func completeFromMailbox() throws {
        lock.lock()
        let isPreparedAbandonment = ownership == .prepared
        lock.unlock()
        if isPreparedAbandonment {
            try preparedAbandonmentFailureInjector?.failIfRequested()
        }
        try completeConsumer(authority: .mailbox)
    }

    private func completeConsumer(authority: CompletionAuthority) throws {
        lock.lock()
        let hasAuthority = switch (authority, ownership) {
        case (.external, .available),
             (.preparedAbandonment, .prepared),
             (.terminalOwner, .inFlight),
             (.mailbox, .prepared),
             (.mailbox, .inFlight):
            true
        default:
            false
        }
        guard hasAuthority, !completionInProgress
        else {
            lock.unlock()
            throw SparseTileSamplingPipelineError.alreadyConsumed
        }
        let priorOwnership = ownership
        completionInProgress = true
        lock.unlock()
        do {
            if authority == .terminalOwner || authority == .mailbox {
                try completionFailureInjector?.failIfRequested()
            }
            try consumer.complete()
            lock.lock()
            ownership = .terminal
            completionInProgress = false
            lock.unlock()
        } catch {
            lock.lock()
            ownership = priorOwnership
            completionInProgress = false
            lock.unlock()
            throw error
        }
    }

    deinit {
        lock.lock()
        let shouldComplete = ownership == .available && !completionInProgress
        completionInProgress = shouldComplete
        lock.unlock()
        guard shouldComplete else { return }
        do {
            try consumer.complete()
        } catch {
            content.completionMailbox.recordConsumerCompletionFailure(
                consumer,
                error: error
            )
        }
    }
}

actor SparseTileSamplingGPUPlanCache {
    private struct CachedPlan {
        let content: SparseTileSamplingGPUPlanContent
        var lastAccess: UInt64
    }

    private struct PlannedEvictions {
        let keys: [SparseTileSamplingGPUPlanKey]
        let planMetalBufferBytes: Int
    }

    private struct BuildAllocationTally {
        var count = 0
        var bytes = 0

        mutating func record(bytes byteCount: Int) {
            let (nextCount, countOverflow) = count.addingReportingOverflow(1)
            let (nextBytes, bytesOverflow) = bytes.addingReportingOverflow(
                byteCount
            )
            precondition(
                !countOverflow && !bytesOverflow,
                "Sparse staged Metal allocation accounting overflow"
            )
            count = nextCount
            bytes = nextBytes
        }
    }

    private struct StagedPlan {
        let content: SparseTileSamplingGPUPlanContent
        let evictions: PlannedEvictions
        let allocationTally: BuildAllocationTally
    }

    private let device: any MTLDevice
    private let limits: SparseTileSamplingGPUPlanLimits
    private let buildObserver: @Sendable (Bool) -> Void
    private let workspaceAllocationObserver:
        @Sendable (SparseTileSamplingWorkspaceAllocation) -> Void
    private let preparedAbandonmentFailureInjector:
        SparseTileSamplingPreparedAbandonmentFailureInjector?
    private let completionFailureInjector:
        SparseTileSamplingCompletionFailureInjector?
    private var prepared: [SparseTileSamplingGPUPlanKey: CachedPlan] = [:]
    private var cachedPlanMetalBufferBytes = 0
    private var accessClock: UInt64 = 0
    private var injectedFailure: SparseTileSamplingFailurePhase?
    private let completionMailbox = SparseTileSamplingCompletionMailbox()
    private var uploadRing: SparseTileSamplingUploadRing?
    private var planMetalBufferAllocationCount = 0
    private var planMetalBufferAllocationBytes = 0
    private var hitCount: UInt64 = 0
    private var missCount: UInt64 = 0

    init(
        device: any MTLDevice,
        limits: SparseTileSamplingGPUPlanLimits = .production,
        buildObserver: @escaping @Sendable (Bool) -> Void = { _ in },
        workspaceAllocationObserver: @escaping @Sendable (
            SparseTileSamplingWorkspaceAllocation
        ) -> Void = { _ in },
        preparedAbandonmentFailureInjector:
            SparseTileSamplingPreparedAbandonmentFailureInjector? = nil,
        completionFailureInjector:
            SparseTileSamplingCompletionFailureInjector? = nil
    ) {
        self.device = device
        self.limits = limits
        self.buildObserver = buildObserver
        self.workspaceAllocationObserver = workspaceAllocationObserver
        self.preparedAbandonmentFailureInjector =
            preparedAbandonmentFailureInjector
        self.completionFailureInjector = completionFailureInjector
    }

    func acquire(
        plan: SparseTileSamplingPlanLease,
        pipeline: SparseTileSamplingPipelineBinding,
        allocationProbe: StrokePreparationAllocationProbe? = nil
    ) throws -> SparseTileSamplingGPUPlanLease {
        allocationProbe?.arm()
        defer {
            allocationProbe?.disarmAndRecord(.sparseSamplingAcquire)
        }
        let consumer = try plan.beginConsumer()
        do {
            let key = try makeKey(plan: plan, pipeline: pipeline)
            let content: SparseTileSamplingGPUPlanContent
            if var cached = prepared[key] {
                hitCount = Self.saturatingIncrement(hitCount)
                cached.lastAccess = nextAccessStamp()
                prepared[key] = cached
                content = cached.content
            } else {
                missCount = Self.saturatingIncrement(missCount)
                let staged = try build(
                    key: key,
                    plan: plan,
                    pipeline: pipeline
                )
                content = try publish(staged, for: key)
            }
            return SparseTileSamplingGPUPlanLease(
                content: content,
                consumer: consumer,
                preparedAbandonmentFailureInjector:
                    preparedAbandonmentFailureInjector,
                completionFailureInjector: completionFailureInjector
            )
        } catch {
            do {
                try consumer.complete()
            } catch let completionError {
                completionMailbox.recordConsumerCompletionFailure(
                    consumer,
                    error: completionError
                )
            }
            throw error
        }
    }

    func invalidate(content: SparseTileSamplingPlanContent) {
        let identity = ObjectIdentifier(content)
        let keys = prepared.keys.filter { $0.contentIdentity == identity }
        for key in keys { removeCachedPlan(for: key) }
    }

    var preparedCount: Int { prepared.count }

    var allocationSnapshot: SparseTileSamplingGPUCacheSnapshot {
        SparseTileSamplingGPUCacheSnapshot(
            preparedContentCount: prepared.count,
            hitCount: hitCount,
            missCount: missCount,
            cachedPlanMetalBufferBytes: cachedPlanMetalBufferBytes,
            planMetalBufferAllocationCount: planMetalBufferAllocationCount,
            planMetalBufferAllocationBytes: planMetalBufferAllocationBytes,
            uploadRing: uploadRing?.snapshot
        )
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    var completionSnapshot: SparseTileSamplingCompletionSnapshot {
        completionMailbox.snapshot
    }

    func retryPendingPlanCompletions() -> Int {
        completionMailbox.retryPendingPlanCompletions()
    }

    func injectFailureForNextBuild(_ phase: SparseTileSamplingFailurePhase) {
        injectedFailure = phase
    }

    private func makeKey(
        plan: SparseTileSamplingPlanLease,
        pipeline: SparseTileSamplingPipelineBinding
    ) throws -> SparseTileSamplingGPUPlanKey {
        let sorted = plan.boundTextures.sorted { $0.globalSlot < $1.globalSlot }
        var previousSlot: Int?
        let signatures = try sorted.map { binding in
            guard binding.globalSlot >= 0,
                  binding.globalSlot < SparseSamplingABI.maximumTier2Textures,
                  previousSlot != binding.globalSlot
            else {
                throw SparseTileSamplingPipelineError.malformedRemap(
                    binding.globalSlot
                )
            }
            previousSlot = binding.globalSlot
            return SparseTileSamplingTextureSignature(
                slot: binding.globalSlot,
                identity: ObjectIdentifier(binding.texture as AnyObject)
            )
        }
        return SparseTileSamplingGPUPlanKey(
            contentIdentity: ObjectIdentifier(plan.content),
            pipelineKey: pipeline.key,
            textures: signatures
        )
    }

    private func build(
        key: SparseTileSamplingGPUPlanKey,
        plan: SparseTileSamplingPlanLease,
        pipeline: SparseTileSamplingPipelineBinding
    ) throws -> StagedPlan {
        buildObserver(Thread.isMainThread)
        let content = plan.content
        guard pipeline.deviceRegistryID == device.registryID else {
            throw SparseTileSamplingPipelineError.stalePlan
        }
        guard pipeline.key.outputMappingKind == content.outputMapping.kind else {
            throw SparseTileSamplingPipelineError.stalePlan
        }
        guard content.key.orderedLayers.count == 1 else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: content.key.orderedLayers.count,
                maximum: 1
            )
        }
        guard content.pageTables.count <= limits.maximumDescriptors else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: content.pageTables.count,
                maximum: limits.maximumDescriptors
            )
        }
        let geometry = try SparseTileSamplingGeometry.validateBatches(
            content.batches
        )
        try validateShaderIntegerRange(
            origin: content.shaderSourceOrigin,
            step: content.outputToSourceTransform.sourceStep,
            outputSize: geometry.size
        )
        var preflightEntryCount = 0
        for (descriptorIndex, table) in content.pageTables.enumerated() {
            var tableEntryCount = 0
            for chunk in table.chunks {
                tableEntryCount = try checkedAdd(
                    tableEntryCount,
                    chunk.entries.count
                )
            }
            guard tableEntryCount == table.entryCount else {
                throw SparseTileSamplingPipelineError.malformedDescriptor(
                    descriptorIndex
                )
            }
            preflightEntryCount = try checkedAdd(
                preflightEntryCount,
                tableEntryCount
            )
        }
        guard preflightEntryCount <= limits.maximumPageEntries else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: preflightEntryCount,
                maximum: limits.maximumPageEntries
            )
        }
        let descriptorBytes = try checkedMultiply(
            max(content.pageTables.count, 1),
            MemoryLayout<PatternSparsePageTableDescriptor>.stride
        )
        let entryBytes = try checkedMultiply(
            max(preflightEntryCount, 1),
            MemoryLayout<PatternSparseTilePageEntry>.stride
        )
        let bySlot = Dictionary(
            uniqueKeysWithValues: plan.boundTextures.map {
                ($0.globalSlot, $0.texture)
            }
        )
        guard bySlot.count == content.bindingRecords.count else {
            throw SparseTileSamplingPipelineError.malformedRemap(bySlot.count)
        }
        for record in content.bindingRecords {
            guard let texture = bySlot[record.globalSlot] else {
                throw SparseTileSamplingPipelineError.malformedRemap(
                    record.globalSlot
                )
            }
            guard texture.pixelFormat == .rgba16Float,
                  texture.width == PaintTileDescriptor.side,
                  texture.height == PaintTileDescriptor.side,
                  texture.textureType == .type2D,
                  texture.device.registryID == device.registryID
            else {
                throw SparseTileSamplingPipelineError.invalidTarget(
                    "source tile \(record.globalSlot)"
                )
            }
            guard texture.usage.contains(.shaderRead) else {
                throw SparseTileSamplingPipelineError.invalidUsage(
                    texture.usage.rawValue
                )
            }
        }
        let bindingCount = try content.bindingRecords.reduce(0) {
            let next = try checkedAdd($1.globalSlot, 1)
            return max($0, next)
        }
        guard bindingCount <= SparseSamplingABI.maximumTier2Textures else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: bindingCount,
                maximum: SparseSamplingABI.maximumTier2Textures
            )
        }

        let allTextures = content.bindingRecords.compactMap {
            bySlot[$0.globalSlot]
        }
        guard allTextures.count == content.bindingRecords.count else {
            throw SparseTileSamplingPipelineError.malformedRemap(
                allTextures.count
            )
        }
        let argumentEncoder: (any MTLArgumentEncoder)?
        let backendBufferBytes: Int
        switch pipeline.key.backend {
        case .tier2ArgumentBuffer:
            try failIfInjected(.argumentEncoder)
            guard let encoder = try pipeline.makeArgumentEncoder() else {
                throw SparseTileSamplingPipelineError.argumentEncoderUnavailable
            }
            argumentEncoder = encoder
            backendBufferBytes = max(encoder.encodedLength, 1)
        case .directFallback:
            argumentEncoder = nil
            for batch in content.batches {
                guard batch.globalSlots.count
                        <= SparseSamplingABI.maximumFallbackTextures
                else {
                    throw SparseTileSamplingPipelineError.limitExceeded(
                        required: batch.globalSlots.count,
                        maximum: SparseSamplingABI.maximumFallbackTextures
                    )
                }
                for slot in batch.globalSlots {
                    guard let local = batch.compactRemap[slot],
                          local >= 0,
                          local < SparseSamplingABI.maximumFallbackTextures,
                          bySlot[slot] != nil,
                          slot >= 0,
                          slot < bindingCount
                    else {
                        throw SparseTileSamplingPipelineError.malformedRemap(
                            slot
                        )
                    }
                }
                guard Set(batch.compactRemap.values).count
                        == batch.compactRemap.count,
                      batch.compactRemap.count == batch.globalSlots.count
                else {
                    throw SparseTileSamplingPipelineError.malformedRemap(
                        batch.compactRemap.count
                    )
                }
            }
            let oneRemapBytes = try checkedMultiply(
                max(bindingCount, 1),
                MemoryLayout<Int32>.stride
            )
            backendBufferBytes = try checkedMultiply(
                content.batches.count,
                oneRemapBytes
            )
        }
        let uploadRingBytes = try SparseTileSamplingUploadRing
            .requiredByteCount(capacity: limits.maximumInflightEncodes)
        let planBufferBytes = try checkedAdd(
            try checkedAdd(descriptorBytes, entryBytes),
            backendBufferBytes
        )
        let aggregateBufferBytes = try checkedAdd(
            planBufferBytes,
            uploadRingBytes
        )
        guard aggregateBufferBytes <= limits.maximumBufferBytes else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: aggregateBufferBytes,
                maximum: limits.maximumBufferBytes
            )
        }
        let plannedEvictions = try planRoomForCachedPlan(
            planMetalBufferBytes: planBufferBytes,
            uploadRingBytes: uploadRingBytes
        )
        guard limits.allowsCacheEviction || plannedEvictions.keys.isEmpty else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: try checkedAdd(
                    cachedPlanMetalBufferBytes,
                    planBufferBytes
                ),
                maximum: limits.maximumCachedBufferBytes
            )
        }
        var allocationTally = BuildAllocationTally()
        let (descriptors, entries) = try makeDescriptorPayload(
            content: content,
            entryCount: preflightEntryCount
        )
        try failIfInjected(.descriptorBuffer)
        let descriptorsBuffer = try makeBuffer(
            descriptors,
            label: "Sparse Page Table Descriptors",
            allocationTally: &allocationTally
        )
        try failIfInjected(.entryBuffer)
        let entriesBuffer = try makeBuffer(
            entries,
            label: "Sparse Page Entries",
            allocationTally: &allocationTally,
            failureIsProportional: true
        )
        let argumentBuffer: (any MTLBuffer)?
        let draws: [SparseTileSamplingDraw]
        switch pipeline.key.backend {
        case .tier2ArgumentBuffer:
            let encoder = try requireArgumentEncoder(argumentEncoder)
            try failIfInjected(.argumentBuffer)
            guard let buffer = device.makeBuffer(
                length: max(encoder.encodedLength, 1),
                options: .storageModeShared
            ) else {
                throw SparseTileSamplingPipelineError.bufferCreationFailed(
                    "Tier-2 argument buffer"
                )
            }
            allocationTally.record(bytes: buffer.length)
            buffer.label = "Sparse Tier-2 Texture Arguments"
            encoder.setArgumentBuffer(buffer, offset: 0)
            for binding in plan.boundTextures {
                encoder.setTexture(
                    binding.texture,
                    index: binding.globalSlot
                )
            }
            argumentBuffer = buffer
            draws = [SparseTileSamplingDraw(
                scissor: MTLScissorRect(
                    x: 0,
                    y: 0,
                    width: geometry.size.x,
                    height: geometry.size.y
                ),
                remapBuffer: nil,
                textures: []
            )]
        case .directFallback:
            argumentBuffer = nil
            var fallbackDraws: [SparseTileSamplingDraw] = []
            fallbackDraws.reserveCapacity(content.batches.count)
            for batch in content.batches {
                var remap = [Int32](
                    repeating: -1,
                    count: max(bindingCount, 1)
                )
                var textures = [(any MTLTexture)?](
                    repeating: nil,
                    count: SparseSamplingABI.maximumFallbackTextures
                )
                for slot in batch.globalSlots {
                    guard let local = batch.compactRemap[slot],
                          local >= 0,
                          local < SparseSamplingABI.maximumFallbackTextures,
                          let texture = bySlot[slot],
                          slot >= 0,
                          slot < bindingCount
                    else {
                        throw SparseTileSamplingPipelineError.malformedRemap(
                            slot
                        )
                    }
                    remap[slot] = Int32(local)
                    textures[local] = texture
                }
                try failIfInjected(.fallbackRemapBuffer)
                fallbackDraws.append(SparseTileSamplingDraw(
                    scissor: try SparseTileSamplingGeometry.normalizedScissor(
                        batch.outputRegion,
                        origin: geometry.origin
                    ),
                    remapBuffer: try makeBuffer(
                        remap,
                        label: "Sparse Fallback Binding Remap",
                        allocationTally: &allocationTally,
                        failureIsProportional: true
                    ),
                    textures: textures
                ))
            }
            draws = fallbackDraws
        }
        let uploadRing = try stagedUploadRing()
        let actualPlanBufferBytes = try draws.reduce(
            try checkedAdd(
                try checkedAdd(
                    descriptorsBuffer.length,
                    entriesBuffer.length
                ),
                argumentBuffer?.length ?? 0
            )
        ) { total, draw in
            try checkedAdd(total, draw.remapBuffer?.length ?? 0)
        }
        guard actualPlanBufferBytes == planBufferBytes else {
            throw SparseTileSamplingPipelineError.byteOverflow
        }
        let candidate = SparseTileSamplingGPUPlanContent(
            key: key,
            pipeline: pipeline,
            descriptorsBuffer: descriptorsBuffer,
            entriesBuffer: entriesBuffer,
            argumentBuffer: argumentBuffer,
            allTextures: allTextures,
            draws: draws,
            outputSize: geometry.size,
            outputOrigin: geometry.origin,
            descriptorCount: descriptors.count,
            bindingCount: bindingCount,
            layerCount: 1,
            addressing: content.addressing,
            outputMapping: content.outputMapping,
            outputToSourceTransform: content.outputToSourceTransform,
            shaderSourceOrigin: content.shaderSourceOrigin,
            uploadRing: uploadRing,
            completionMailbox: completionMailbox,
            planMetalBufferBytes: actualPlanBufferBytes
        )
        return StagedPlan(
            content: candidate,
            evictions: plannedEvictions,
            allocationTally: allocationTally
        )
    }

    private func makeDescriptorPayload(
        content: SparseTileSamplingPlanContent,
        entryCount: Int
    ) throws -> (
        [PatternSparsePageTableDescriptor],
        [PatternSparseTilePageEntry]
    ) {
        workspaceAllocationObserver(.descriptors(
            capacity: content.pageTables.count
        ))
        var descriptors: [PatternSparsePageTableDescriptor] = []
        descriptors.reserveCapacity(content.pageTables.count)
        workspaceAllocationObserver(.entries(capacity: entryCount))
        var entries: [PatternSparseTilePageEntry] = []
        entries.reserveCapacity(entryCount)
        for table in content.pageTables {
            let entryOffset = entries.count
            guard entryOffset <= Int(UInt32.max),
                  table.entryCount <= Int(UInt32.max),
                  table.size.width <= Int(UInt32.max),
                  table.size.height <= Int(UInt32.max)
            else { throw SparseTileSamplingPipelineError.byteOverflow }
            var descriptor = PatternSparsePageTableDescriptor()
            descriptor.entryOffset = UInt32(entryOffset)
            descriptor.entryCount = UInt32(table.entryCount)
            descriptor.tableOrigin = try checkedInt2(
                table.origin.x, table.origin.y
            )
            descriptor.tableSize = SIMD2(
                UInt32(table.size.width), UInt32(table.size.height)
            )
            descriptor.layerIndex = 0
            descriptor.role = roleWire(table.role)
            descriptors.append(descriptor)

            var localIndex = 0
            for chunk in table.chunks {
                for source in chunk.entries {
                    var entry = PatternSparseTilePageEntry()
                    entry.logicalOrigin = try checkedInt2(
                        source.logicalOrigin.x, source.logicalOrigin.y
                    )
                    entry.physicalOrigin = try checkedInt2(
                        source.physicalOrigin.x, source.physicalOrigin.y
                    )
                    guard source.globalBindingSlot >= -1,
                          source.globalBindingSlot <= Int(Int32.max)
                    else {
                        throw SparseTileSamplingPipelineError.malformedEntry(
                            entryOffset + localIndex
                        )
                    }
                    entry.globalBindingSlot = Int32(source.globalBindingSlot)
                    let bounds = try SparseSamplingABI.packLocalBounds(
                        minimum: SIMD2(
                            source.localBounds.minX, source.localBounds.minY
                        ),
                        maximum: SIMD2(
                            source.localBounds.maxX, source.localBounds.maxY
                        )
                    )
                    entry.packedLocalMinimum = bounds.minimum
                    entry.packedLocalMaximum = bounds.maximum
                    entry.flags = 0
                    entries.append(entry)
                    localIndex += 1
                }
            }
            precondition(localIndex == table.entryCount)
        }
        precondition(entries.count == entryCount)
        return (descriptors, entries)
    }

    private func planRoomForCachedPlan(
        planMetalBufferBytes: Int,
        uploadRingBytes: Int
    ) throws -> PlannedEvictions {
        guard limits.maximumCachedPlans > 0 else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: 1,
                maximum: limits.maximumCachedPlans
            )
        }
        let residentUploadBytes = uploadRing?.snapshot.metalBufferBytes
            ?? uploadRingBytes
        let candidateResidentBytes = try checkedAdd(
            planMetalBufferBytes,
            residentUploadBytes
        )
        guard candidateResidentBytes <= limits.maximumCachedBufferBytes else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: candidateResidentBytes,
                maximum: limits.maximumCachedBufferBytes
            )
        }
        let leastRecent = prepared.sorted {
            $0.value.lastAccess < $1.value.lastAccess
        }
        var remainingCount = prepared.count
        var remainingPlanBytes = cachedPlanMetalBufferBytes
        var victimKeys: [SparseTileSamplingGPUPlanKey] = []
        victimKeys.reserveCapacity(prepared.count)
        var victimBytes = 0
        var nextVictimIndex = 0
        while true {
            let projectedResidentBytes = try checkedAdd(
                try checkedAdd(
                    remainingPlanBytes,
                    planMetalBufferBytes
                ),
                residentUploadBytes
            )
            guard remainingCount >= limits.maximumCachedPlans
                    || projectedResidentBytes
                        > limits.maximumCachedBufferBytes
            else { break }
            guard nextVictimIndex < leastRecent.count else {
                throw SparseTileSamplingPipelineError.byteOverflow
            }
            let victim = leastRecent[nextVictimIndex]
            nextVictimIndex += 1
            victimKeys.append(victim.key)
            victimBytes = try checkedAdd(
                victimBytes,
                victim.value.content.planMetalBufferBytes
            )
            remainingPlanBytes = try checkedSubtract(
                remainingPlanBytes,
                victim.value.content.planMetalBufferBytes
            )
            remainingCount -= 1
        }
        return PlannedEvictions(
            keys: victimKeys,
            planMetalBufferBytes: victimBytes
        )
    }

    private func publish(
        _ staged: StagedPlan,
        for key: SparseTileSamplingGPUPlanKey
    ) throws -> SparseTileSamplingGPUPlanContent {
        let remainingBytes = try checkedSubtract(
            cachedPlanMetalBufferBytes,
            staged.evictions.planMetalBufferBytes
        )
        let nextCachedBytes = try checkedAdd(
            remainingBytes,
            staged.content.planMetalBufferBytes
        )
        let residentBytes = try checkedAdd(
            nextCachedBytes,
            staged.content.uploadRing.snapshot.metalBufferBytes
        )
        guard nextCachedBytes <= limits.maximumCachedBufferBytes,
              residentBytes <= limits.maximumCachedBufferBytes
        else { throw SparseTileSamplingPipelineError.byteOverflow }
        let nextAllocationCount = try checkedAdd(
            planMetalBufferAllocationCount,
            staged.allocationTally.count
        )
        let nextAllocationBytes = try checkedAdd(
            planMetalBufferAllocationBytes,
            staged.allocationTally.bytes
        )
        let access = nextAccessStamp()
        var nextPrepared = prepared
        for victimKey in staged.evictions.keys {
            precondition(
                nextPrepared.removeValue(forKey: victimKey) != nil,
                "Sparse staged eviction victim disappeared"
            )
        }
        nextPrepared[key] = CachedPlan(
            content: staged.content,
            lastAccess: access
        )

        prepared = nextPrepared
        cachedPlanMetalBufferBytes = nextCachedBytes
        uploadRing = staged.content.uploadRing
        planMetalBufferAllocationCount = nextAllocationCount
        planMetalBufferAllocationBytes = nextAllocationBytes
        return staged.content
    }

    private func removeCachedPlan(for key: SparseTileSamplingGPUPlanKey) {
        guard let removed = prepared.removeValue(forKey: key) else { return }
        let (nextBytes, underflow) = cachedPlanMetalBufferBytes
            .subtractingReportingOverflow(removed.content.planMetalBufferBytes)
        precondition(!underflow, "Sparse plan cache byte accounting underflow")
        cachedPlanMetalBufferBytes = nextBytes
    }

    private func nextAccessStamp() -> UInt64 {
        if accessClock == UInt64.max {
            let orderedKeys = prepared.keys.sorted {
                prepared[$0]!.lastAccess < prepared[$1]!.lastAccess
            }
            for (index, key) in orderedKeys.enumerated() {
                prepared[key]!.lastAccess = UInt64(index)
            }
            accessClock = UInt64(orderedKeys.count)
        }
        accessClock += 1
        return accessClock
    }

    private func makeBuffer<T>(
        _ values: [T],
        label: String,
        allocationTally: inout BuildAllocationTally,
        failureIsProportional: Bool = false
    ) throws -> any MTLBuffer {
        let byteCount = try checkedMultiply(
            max(values.count, 1),
            MemoryLayout<T>.stride
        )
        guard byteCount <= limits.maximumBufferBytes else {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: byteCount,
                maximum: limits.maximumBufferBytes
            )
        }
        let buffer: (any MTLBuffer)?
        if values.isEmpty {
            buffer = device.makeBuffer(
                length: byteCount,
                options: .storageModeShared
            )
        } else {
            buffer = values.withUnsafeBytes {
                device.makeBuffer(
                    bytes: $0.baseAddress!,
                    length: $0.count,
                    options: .storageModeShared
                )
            }
        }
        guard let buffer else {
            if failureIsProportional {
                throw SparseTileSamplingPipelineError
                    .proportionalBufferCreationFailed(
                        label: label,
                        requiredBytes: byteCount
                    )
            }
            throw SparseTileSamplingPipelineError.bufferCreationFailed(label)
        }
        allocationTally.record(bytes: buffer.length)
        buffer.label = label
        return buffer
    }

    private func requireArgumentEncoder(
        _ encoder: (any MTLArgumentEncoder)?
    ) throws -> any MTLArgumentEncoder {
        guard let encoder else {
            throw SparseTileSamplingPipelineError.argumentEncoderUnavailable
        }
        return encoder
    }

    private func failIfInjected(
        _ phase: SparseTileSamplingFailurePhase
    ) throws {
        guard injectedFailure == phase else { return }
        injectedFailure = nil
        throw SparseTileSamplingPipelineError.injectedFailure(phase.rawValue)
    }

    private func stagedUploadRing() throws -> SparseTileSamplingUploadRing {
        try failIfInjected(.uploadRing)
        if let uploadRing { return uploadRing }
        return try SparseTileSamplingUploadRing(
            device: device,
            capacity: limits.maximumInflightEncodes
        )
    }
}

struct SparseTileSamplingEncodeParameters: Equatable, Sendable {
    let outputMapping: SparseTileSamplingOutputMapping
    let compositeMode: UInt32
    let liveVisible: Bool
    let strokeOpacity: Float
    let accumulationLimit: Float
    let eraserStrength: Float
    let showGridLines: Bool
    let showCanvasBoundary: Bool

    var outputToSourceTransform: SparseTileOutputToSourceTransform {
        outputMapping.affineTransform ?? .identity
    }

    init(
        outputToSourceTransform: SparseTileOutputToSourceTransform,
        compositeMode: UInt32,
        liveVisible: Bool,
        strokeOpacity: Float,
        accumulationLimit: Float,
        eraserStrength: Float,
        showGridLines: Bool = false,
        showCanvasBoundary: Bool = false
    ) {
        outputMapping = .affine(outputToSourceTransform)
        self.compositeMode = compositeMode
        self.liveVisible = liveVisible
        self.strokeOpacity = strokeOpacity
        self.accumulationLimit = accumulationLimit
        self.eraserStrength = eraserStrength
        self.showGridLines = showGridLines
        self.showCanvasBoundary = showCanvasBoundary
    }

    init(
        outputMapping: SparseTileSamplingOutputMapping,
        compositeMode: UInt32,
        liveVisible: Bool,
        strokeOpacity: Float,
        accumulationLimit: Float,
        eraserStrength: Float,
        showGridLines: Bool = false,
        showCanvasBoundary: Bool = false
    ) {
        self.outputMapping = outputMapping
        self.compositeMode = compositeMode
        self.liveVisible = liveVisible
        self.strokeOpacity = strokeOpacity
        self.accumulationLimit = accumulationLimit
        self.eraserStrength = eraserStrength
        self.showGridLines = showGridLines
        self.showCanvasBoundary = showCanvasBoundary
    }

    static let identity = SparseTileSamplingEncodeParameters(
        outputMapping: .affine(.identity),
        compositeMode: PatternCompositeWireDraw,
        liveVisible: true,
        strokeOpacity: 1,
        accumulationLimit: 1,
        eraserStrength: 1
    )
}

enum SparseTileSamplingRadialFrames {
    static func make(
        mapping: SparseTileFiniteRadialOutputMapping,
        outputOrigin: SIMD2<Int>,
        outputSize: SIMD2<Int>,
        parameters: SparseTileSamplingEncodeParameters
    ) throws -> (
        grid: PatternGridFrameUniforms,
        radial: PatternRadialFrameUniforms
    ) {
        let drawableSize = SIMD2(
            Float(outputSize.x),
            Float(outputSize.y)
        )
        let origin = SIMD2(
            Float(outputOrigin.x),
            Float(outputOrigin.y)
        )
        guard drawableSize.x.isFinite,
              drawableSize.y.isFinite,
              origin.x.isFinite,
              origin.y.isFinite,
              Int(exactly: drawableSize.x) == outputSize.x,
              Int(exactly: drawableSize.y) == outputSize.y,
              Int(exactly: origin.x) == outputOrigin.x,
              Int(exactly: origin.y) == outputOrigin.y
        else {
            throw SparseTileSamplingPipelineError.byteOverflow
        }
        let transform = mapping.outputToWorldTransform
        let worldCenter = origin + transform.sourceOffset
            + drawableSize * 0.5 * transform.sourceStep
        let zoom = 1 / transform.sourceStep.x
        guard worldCenter.x.isFinite, worldCenter.y.isFinite,
              zoom.isFinite, zoom > 0
        else {
            throw SparseTileSamplingPipelineError.byteOverflow
        }
        let strategy = mapping.strategy
        let compiled = strategy.compiledSymmetry
        let radial = mapping.radial
        let configuration = radial.configuration!
        let layout = mapping.layout
        guard compiled.displayProgram.family == .radial,
              let displayedSectorCount = UInt32(
                exactly: radial.displayedSectorCount
              ),
              let atlasColumns = UInt32(exactly: layout.atlasColumns)
        else {
            throw SparseTileSamplingPipelineError.malformedDescriptor(0)
        }
        let grid = PatternGridFrameUniforms(
            drawableSize: drawableSize,
            worldCenter: worldCenter,
            tileSize: strategy.tileSize.simd,
            zoom: zoom,
            gridLineWidth: 1,
            showGridLines: parameters.showGridLines ? 1 : 0,
            liveVisible: parameters.liveVisible ? 1 : 0,
            tilingKind: compiled.displayProgram.presetWireID,
            diagnosticMode: PatternDiagnosticWireNone,
            compositeMode: parameters.compositeMode,
            symmetryFamily: compiled.displayProgram.family.rawValue,
            repeatSize: SIMD2(
                Float(strategy.canvasSize.width),
                Float(strategy.canvasSize.height)
            ),
            latticeXAxis: SIMD2(1, 0),
            latticeYAxis: SIMD2(0, 1),
            latticeTranslation: .zero,
            guideKind: compiled.displayProgram.guideKind.rawValue,
            showCanvasBoundary: parameters.showCanvasBoundary ? 1 : 0
        )
        let radialFrame = PatternRadialFrameUniforms(
            canvasSize: SIMD2(
                Float(radial.canvasSize.width),
                Float(radial.canvasSize.height)
            ),
            center: configuration.center.simd,
            referenceAngle: configuration.referenceAngleRadians,
            sectorAngle: radial.sectorAngleRadians,
            displayedSectorCount: displayedSectorCount,
            dihedral: configuration.kind == .rotation ? 0 : 1,
            pageOrigin: SIMD2(
                Float(layout.pageOrigin.x),
                Float(layout.pageOrigin.y)
            ),
            pageTableSize: SIMD2(
                Float(layout.pageTableSize.width),
                Float(layout.pageTableSize.height)
            ),
            atlasColumns: atlasColumns,
            pageSide: UInt32(RadialSectorLayout.pageSide),
            atlasSize: SIMD2(
                Float(layout.atlasPixelSize.width),
                Float(layout.atlasPixelSize.height)
            )
        )
        return (grid, radialFrame)
    }
}

final class SparseTileSamplingPreparedSubmission: @unchecked Sendable {
    private enum State {
        case available
        case encoding
        case submitted
    }

    private let plan: SparseTileSamplingGPUPlanLease
    private let upload: SparseTileSamplingUploadLease
    private let lock = NSLock()
    private var state = State.available

    fileprivate init(
        plan: SparseTileSamplingGPUPlanLease,
        upload: SparseTileSamplingUploadLease
    ) {
        self.plan = plan
        self.upload = upload
    }

    var resourceIdentity: SparseTileSamplingPreparedResourceIdentity {
        SparseTileSamplingPreparedResourceIdentity(
            preparedSubmission: ObjectIdentifier(self),
            gpuPlanContent: plan.immutableContentIdentity,
            uploadRing: ObjectIdentifier(plan.content.uploadRing),
            uploadLease: ObjectIdentifier(upload)
        )
    }

    func encode(
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        allocationProbe: StrokePreparationAllocationProbe? = nil,
        completionAllocationProbe: StrokePreparationAllocationProbe? = nil,
        afterResourcesReturned: (@Sendable (
            SparseTileSamplingResourceReturnReceipt,
            Bool
        ) -> Void)? = nil,
        afterTerminalRecorded: (@Sendable (
            SparseTileSamplingTerminalRecord
        ) -> Void)? = nil
    ) throws {
        allocationProbe?.arm()
        defer {
            allocationProbe?.disarmAndRecord(
                .sparseSamplingMetalSubmission
            )
        }
        try validateTarget(target, renderPassDescriptor: renderPassDescriptor)
        lock.lock()
        guard state == .available else {
            lock.unlock()
            throw SparseTileSamplingPipelineError.alreadyConsumed
        }
        state = .encoding
        lock.unlock()
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            lock.lock()
            state = .available
            lock.unlock()
            throw SparseTileSamplingPipelineError.pipelineCreationFailed(
                "render encoder"
            )
        }
        do {
            try plan.beginInFlight()
        } catch {
            renderEncoder.endEncoding()
            lock.lock()
            state = .available
            lock.unlock()
            throw error
        }

        let content = plan.content
        renderEncoder.setRenderPipelineState(content.pipeline.state)
        renderEncoder.setVertexBuffer(
            upload.buffer,
            offset: upload.uniformsOffset,
            index: Int(PatternBufferIndexSparseSamplingUniforms)
        )
        renderEncoder.setFragmentBuffer(
            upload.buffer,
            offset: upload.materialOffset,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        if content.outputMapping.kind == .finiteRadial {
            renderEncoder.setFragmentBuffer(
                upload.buffer,
                offset: upload.gridFrameOffset,
                index: Int(PatternBufferIndexGridFrameUniforms)
            )
            renderEncoder.setFragmentBuffer(
                upload.buffer,
                offset: upload.radialFrameOffset,
                index: Int(PatternBufferIndexRadialFrameUniforms)
            )
        }
        renderEncoder.setFragmentBuffer(
            upload.buffer,
            offset: upload.uniformsOffset,
            index: Int(PatternBufferIndexSparseSamplingUniforms)
        )
        renderEncoder.setFragmentBuffer(
            content.descriptorsBuffer,
            offset: 0,
            index: Int(PatternBufferIndexSparsePageTableDescriptors)
        )
        renderEncoder.setFragmentBuffer(
            content.entriesBuffer,
            offset: 0,
            index: Int(PatternBufferIndexSparsePageEntries)
        )
        switch content.pipeline.key.backend {
        case .tier2ArgumentBuffer:
            renderEncoder.setFragmentBuffer(
                content.argumentBuffer,
                offset: 0,
                index: Int(PatternBufferIndexSparseTextureArguments)
            )
            if !content.allTextures.isEmpty {
                renderEncoder.useResources(
                    content.allTextures,
                    usage: .read,
                    stages: .fragment
                )
            }
            let draw = content.draws[0]
            renderEncoder.setScissorRect(draw.scissor)
            renderEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 3
            )
        case .directFallback:
            for draw in content.draws {
                renderEncoder.setFragmentBuffer(
                    draw.remapBuffer,
                    offset: 0,
                    index: Int(PatternBufferIndexSparseBindingRemap)
                )
                for index in 0..<SparseSamplingABI.maximumFallbackTextures {
                    renderEncoder.setFragmentTexture(
                        draw.textures[index],
                        index: Int(PatternTextureIndexSparseFallbackBase) + index
                    )
                }
                renderEncoder.setScissorRect(draw.scissor)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 3
                )
            }
        }
        let retainedPlan = plan
        let retainedUpload = upload
        let mailbox = plan.content.completionMailbox
        commandBuffer.addCompletedHandler { commandBuffer in
            completionAllocationProbe?.arm()
            defer {
                completionAllocationProbe?.disarmAndRecord(
                    .sparseSamplingCompletion
                )
            }
            mailbox.recordTerminal(
                commandBuffer: commandBuffer,
                plan: retainedPlan,
                upload: retainedUpload,
                afterResourcesReturned: afterResourcesReturned,
                afterTerminalRecorded: afterTerminalRecorded
            )
        }
        renderEncoder.endEncoding()
        lock.lock()
        state = .submitted
        lock.unlock()
    }

    func validateTarget(
        _ target: any MTLTexture,
        renderPassDescriptor descriptor: MTLRenderPassDescriptor
    ) throws {
        let content = plan.content
        guard target.device.registryID == content.pipeline.deviceRegistryID else {
            throw SparseTileSamplingPipelineError.stalePlan
        }
        guard target.pixelFormat.rawValue
                == content.pipeline.key.outputPixelFormatRawValue,
              target.textureType == .type2D,
              target.sampleCount == content.pipeline.key.sampleCount,
              target.width == content.outputSize.x,
              target.height == content.outputSize.y
        else {
            throw SparseTileSamplingPipelineError.invalidTarget(
                "target geometry or format"
            )
        }
        guard target.usage.contains(.renderTarget) else {
            throw SparseTileSamplingPipelineError.invalidUsage(
                target.usage.rawValue
            )
        }
        let targetRoot = rootTextureIdentity(target)
        guard !content.allTextures.contains(where: {
            rootTextureIdentity($0) == targetRoot
        }) else {
            throw SparseTileSamplingPipelineError.targetSourceAlias
        }
        guard let attachment = descriptor.colorAttachments[0],
              let attachmentTexture = attachment.texture,
              ObjectIdentifier(attachmentTexture as AnyObject)
                == ObjectIdentifier(target as AnyObject),
              attachment.level == 0,
              attachment.slice == 0,
              attachment.depthPlane == 0,
              attachment.resolveTexture == nil
        else {
            throw SparseTileSamplingPipelineError.invalidTarget(
                "render pass attachment"
            )
        }
        if content.pipeline.outputContract == .displayOpaqueSRGB {
            let clear = attachment.clearColor
            guard attachment.loadAction == .clear,
                  attachment.storeAction == .store,
                  clear.red.isFinite,
                  clear.green.isFinite,
                  clear.blue.isFinite,
                  clear.alpha.isFinite,
                  (0...1).contains(clear.red),
                  (0...1).contains(clear.green),
                  (0...1).contains(clear.blue),
                  clear.alpha == 1
            else {
                throw SparseTileSamplingPipelineError.invalidTarget(
                    "render pass opaque display contract"
                )
            }
        } else if content.pipeline.outputContract
            == .interchangeEncodedPremultiplied
        {
            let loadIsValid = attachment.loadAction == .dontCare
                || attachment.loadAction == .clear
            let clear = attachment.clearColor
            let clearIsValid = attachment.loadAction != .clear || (
                clear.red.isFinite
                    && clear.green.isFinite
                    && clear.blue.isFinite
                    && clear.alpha.isFinite
                    && (0...1).contains(clear.red)
                    && (0...1).contains(clear.green)
                    && (0...1).contains(clear.blue)
                    && (0...1).contains(clear.alpha)
            )
            guard loadIsValid,
                  attachment.storeAction == .store,
                  clearIsValid
            else {
                throw SparseTileSamplingPipelineError.invalidTarget(
                    "render pass transparent interchange contract"
                )
            }
        }
    }

    func abandon(
        afterResourcesReturned: (@Sendable (
            SparseTileSamplingResourceReturnReceipt
        ) -> Void)? = nil,
        afterTerminalRecorded: (@Sendable (
            SparseTileSamplingTerminalRecord
        ) -> Void)? = nil
    ) {
        lock.lock()
        let wasAbandoned = state != .submitted
        state = .submitted
        lock.unlock()
        guard wasAbandoned else { return }
        upload.complete()
        let receipt = SparseTileSamplingResourceReturnReceipt()
        do {
            try plan.completePreparedAbandonment()
            afterTerminalRecorded?(SparseTileSamplingTerminalRecord(
                kind: .abandoned,
                resourcesReturned: true
            ))
            afterResourcesReturned?(receipt)
        } catch {
            plan.content.completionMailbox.recordPreparedAbandonmentFailure(
                plan,
                error: error,
                receipt: receipt,
                afterResourcesReturned: afterResourcesReturned,
                afterTerminalRecorded: afterTerminalRecorded
            )
        }
    }

    deinit { abandon() }
}

enum SparseTileSamplingEncoder {
    static func prepareSubmission(
        plan: SparseTileSamplingGPUPlanLease,
        parameters: SparseTileSamplingEncodeParameters,
        injectedFailure: SparseTileSamplingFailurePhase? = nil,
        allocationProbe: StrokePreparationAllocationProbe? = nil
    ) throws -> SparseTileSamplingPreparedSubmission {
        allocationProbe?.arm()
        defer {
            allocationProbe?.disarmAndRecord(.sparseSamplingPreflight)
        }
        try plan.beginPreflight()
        do {
            return try makePreparedSubmission(
                plan: plan,
                parameters: parameters,
                injectedFailure: injectedFailure
            )
        } catch {
            plan.cancelPreflight()
            throw error
        }
    }

    private static func makePreparedSubmission(
        plan: SparseTileSamplingGPUPlanLease,
        parameters: SparseTileSamplingEncodeParameters,
        injectedFailure: SparseTileSamplingFailurePhase?
    ) throws -> SparseTileSamplingPreparedSubmission {
        let content = plan.content
        guard parameters.outputMapping == content.outputMapping
        else { throw SparseTileSamplingPipelineError.incompleteHalo }
        guard parameters.strokeOpacity.isFinite,
              parameters.accumulationLimit.isFinite,
              parameters.eraserStrength.isFinite,
              parameters.compositeMode == PatternCompositeWireDraw
                || parameters.compositeMode == PatternCompositeWireErase
        else {
            throw SparseTileSamplingPipelineError.invalidTarget(
                "non-finite sampling parameters"
            )
        }
        guard content.outputSize.x <= Int(UInt32.max),
              content.outputSize.y <= Int(UInt32.max),
              content.descriptorCount <= Int(UInt32.max),
              content.bindingCount <= Int(UInt32.max),
              content.layerCount <= Int(UInt32.max)
        else { throw SparseTileSamplingPipelineError.byteOverflow }

        let addressing: (flags: UInt32, period: SIMD2<UInt32>)
        switch content.addressing {
        case .finite:
            addressing = (0, SIMD2(0, 0))
        case let .periodic(period):
            guard period.width > 0, period.height > 0,
                  period.width <= Int(Int32.max),
                  period.height <= Int(Int32.max)
            else { throw SparseTileSamplingPipelineError.malformedDescriptor(0) }
            addressing = (
                PatternSparseAddressingPeriodic,
                SIMD2(UInt32(period.width), UInt32(period.height))
            )
        case .radial:
            addressing = (PatternSparseAddressingRadial, SIMD2(0, 0))
        }
        var uniforms = PatternSparseSamplingUniforms()
        uniforms.outputSize = SIMD2(
            UInt32(content.outputSize.x),
            UInt32(content.outputSize.y)
        )
        uniforms.sourceOrigin = content.shaderSourceOrigin
        uniforms.sourceStep = content.outputToSourceTransform.sourceStep
        uniforms.descriptorCount = UInt32(content.descriptorCount)
        uniforms.layerCount = UInt32(content.layerCount)
        uniforms.bindingCount = UInt32(content.bindingCount)
        uniforms.addressingFlags = addressing.flags
        uniforms.period = addressing.period
        uniforms.compositeMode = parameters.compositeMode
        uniforms.liveVisible = parameters.liveVisible ? 1 : 0
        uniforms.reserved = SIMD2(0, 0)
        var material = PatternCompositeUniforms()
        material.parameters = SIMD4(
            parameters.strokeOpacity,
            parameters.accumulationLimit,
            parameters.eraserStrength,
            0
        )
        if injectedFailure == .preflightUniformBuffer {
            throw SparseTileSamplingPipelineError.injectedFailure(
                SparseTileSamplingFailurePhase.preflightUniformBuffer.rawValue
            )
        }
        if injectedFailure == .preflightMaterialBuffer {
            throw SparseTileSamplingPipelineError.injectedFailure(
                SparseTileSamplingFailurePhase.preflightMaterialBuffer.rawValue
            )
        }
        let radialFrames: (
            grid: PatternGridFrameUniforms,
            radial: PatternRadialFrameUniforms
        )?
        switch content.outputMapping {
        case .affine:
            radialFrames = nil
        case let .finiteRadial(mapping):
            radialFrames = try SparseTileSamplingRadialFrames.make(
                mapping: mapping,
                outputOrigin: content.outputOrigin,
                outputSize: content.outputSize,
                parameters: parameters
            )
        }
        let upload = try content.uploadRing.acquire(
            uniforms: uniforms,
            material: material,
            radialFrames: radialFrames
        )
        let prepared = SparseTileSamplingPreparedSubmission(
            plan: plan,
            upload: upload
        )
        plan.finishPreflight()
        return prepared
    }
}

private func roleWire(_ role: SparseTileSampleRole) -> UInt32 {
    switch role {
    case .canonical: PatternSparseRoleCanonical
    case .authoritative: PatternSparseRoleAuthoritative
    case .prediction: PatternSparseRolePrediction
    }
}

private func checkedInt2(_ x: Int, _ y: Int) throws -> SIMD2<Int32> {
    guard x >= Int(Int32.min), x <= Int(Int32.max),
          y >= Int(Int32.min), y <= Int(Int32.max)
    else { throw SparseTileSamplingPipelineError.byteOverflow }
    return SIMD2(Int32(x), Int32(y))
}

private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw SparseTileSamplingPipelineError.byteOverflow }
    return value
}

private func checkedSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
    guard !overflow else { throw SparseTileSamplingPipelineError.byteOverflow }
    return value
}

private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw SparseTileSamplingPipelineError.byteOverflow }
    return value
}

enum SparseTileSamplingGeometry {
    static func validateBatches(
        _ batches: [SparseTileBindingBatch]
    ) throws -> (origin: SIMD2<Int>, size: SIMD2<Int>) {
        guard let first = batches.first else {
            throw SparseTileSamplingPipelineError.incompleteHalo
        }
        var minX = first.outputRegion.minX
        var minY = first.outputRegion.minY
        var maxX = first.outputRegion.maxX
        var maxY = first.outputRegion.maxY
        var area = 0
        for (index, batch) in batches.enumerated() {
            for earlier in batches[..<index] {
                let overlaps = max(
                    earlier.outputRegion.minX,
                    batch.outputRegion.minX
                ) < min(
                    earlier.outputRegion.maxX,
                    batch.outputRegion.maxX
                ) && max(
                    earlier.outputRegion.minY,
                    batch.outputRegion.minY
                ) < min(
                    earlier.outputRegion.maxY,
                    batch.outputRegion.maxY
                )
                guard !overlaps else {
                    throw SparseTileSamplingPipelineError.incompleteHalo
                }
            }
            minX = min(minX, batch.outputRegion.minX)
            minY = min(minY, batch.outputRegion.minY)
            maxX = max(maxX, batch.outputRegion.maxX)
            maxY = max(maxY, batch.outputRegion.maxY)
            area = try checkedAdd(
                area,
                try checkedMultiply(
                    batch.outputRegion.width,
                    batch.outputRegion.height
                )
            )
        }
        let width = try checkedSubtract(maxX, minX)
        let height = try checkedSubtract(maxY, minY)
        let boundingArea = try checkedMultiply(width, height)
        guard width > 0, height > 0, area == boundingArea else {
            throw SparseTileSamplingPipelineError.incompleteHalo
        }
        return (SIMD2(minX, minY), SIMD2(width, height))
    }

    static func normalizedScissor(
        _ region: SparseTileOutputRegion,
        origin: SIMD2<Int>
    ) throws -> MTLScissorRect {
        let x = try checkedSubtract(region.minX, origin.x)
        let y = try checkedSubtract(region.minY, origin.y)
        guard x >= 0, y >= 0 else {
            throw SparseTileSamplingPipelineError.incompleteHalo
        }
        return MTLScissorRect(
            x: x,
            y: y,
            width: region.width,
            height: region.height
        )
    }
}

private func validateShaderIntegerRange(
    origin: SIMD2<Float>,
    step: SIMD2<Float>,
    outputSize: SIMD2<Int>
) throws {
    guard outputSize.x > 0, outputSize.y > 0 else {
        throw SparseTileSamplingPipelineError.incompleteHalo
    }
    func validateAxis(origin: Float, step: Float, count: Int) throws {
        let first = Double(origin) + 0.5 * Double(step) - 0.5
        let last = Double(origin)
            + (Double(count) - 0.5) * Double(step) - 0.5
        guard first.isFinite, last.isFinite else {
            throw SparseTileSamplingPipelineError.byteOverflow
        }
        let lower = floor(min(first, last))
        let upperNeighbor = floor(max(first, last)) + 1
        guard lower >= Double(Int32.min),
              upperNeighbor <= Double(Int32.max)
        else { throw SparseTileSamplingPipelineError.byteOverflow }
    }
    try validateAxis(origin: origin.x, step: step.x, count: outputSize.x)
    try validateAxis(origin: origin.y, step: step.y, count: outputSize.y)
}

private func rootTextureIdentity(
    _ texture: any MTLTexture
) -> ObjectIdentifier {
    var root = texture
    while let parent = root.parent { root = parent }
    return ObjectIdentifier(root as AnyObject)
}

package struct SparseTileSamplingAllocationCap: Equatable, Sendable {
    package let maximumSingleEventCount: UInt64
    package let enforcesNonIncreasingHalves: Bool

    package init(
        maximumSingleEventCount: UInt64,
        enforcesNonIncreasingHalves: Bool = true
    ) {
        self.maximumSingleEventCount = maximumSingleEventCount
        self.enforcesNonIncreasingHalves = enforcesNonIncreasingHalves
    }

    package func accepts(
        maximumObserved: UInt64,
        firstHalf: UInt64,
        lastHalf: UInt64
    ) -> Bool {
        maximumObserved <= maximumSingleEventCount
            && (!enforcesNonIncreasingHalves || lastHalf <= firstHalf)
    }

    package static let acquire = Self(maximumSingleEventCount: 6)
    package static let preflight = Self(maximumSingleEventCount: 4)
    package static let submission = Self(
        maximumSingleEventCount: 32,
        enforcesNonIncreasingHalves: false
    )
    package static let completion = Self(maximumSingleEventCount: 0)
    package static let completionWait = Self(maximumSingleEventCount: 0)
}

package struct SparseTileSamplingAllocationProbeResult: Sendable {
    package let backend: String
    package let measuredIterationCount: Int
    package let sourceTileCount: Int
    package let drawCount: Int
    package let warmedPlanMetalBufferAllocationCount: Int
    package let finalPlanMetalBufferAllocationCount: Int
    package let warmedPlanMetalBufferAllocationBytes: Int
    package let finalPlanMetalBufferAllocationBytes: Int
    package let warmedCachedPlanMetalBufferBytes: Int
    package let finalCachedPlanMetalBufferBytes: Int
    package let warmedUploadMetalBufferAllocationCount: Int
    package let finalUploadMetalBufferAllocationCount: Int
    package let warmedUploadMetalBufferBytes: Int
    package let finalUploadMetalBufferBytes: Int
    package let uploadCapacity: Int
    package let uploadHighWaterSlotCount: Int
    package let finalActiveUploadSlotCount: Int
    package let terminalCommandCount: UInt64
    package let commandFailureCount: UInt64
    package let planCompletionFailureCount: UInt64
    package let pendingCompletionCount: Int
    package let finalSourceActiveLeaseCount: Int
}

private final class SparseTileSamplingCommandWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume()
        } else {
            completed = true
            lock.unlock()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private struct SparseTileSamplingPendingCommand {
    let commandBuffer: any MTLCommandBuffer
    let waiter: SparseTileSamplingCommandWaiter
}

/// Release/DYLD fixture for the complete warmed P4 sampling lifecycle,
/// including app orchestration, Metal command construction, three commands in
/// flight, terminal retirement, and async completion waiting.
package enum SparseTileSamplingAllocationProbeHarness {
    @MainActor
    package static func run(
        device: any MTLDevice,
        library: any MTLLibrary,
        probe: StrokePreparationAllocationProbe,
        warmupIterationCount: Int = 63,
        measuredIterationCount: Int = 255
    ) async throws -> [SparseTileSamplingAllocationProbeResult] {
        precondition(warmupIterationCount > 0 && warmupIterationCount % 3 == 0)
        precondition(
            measuredIterationCount > 0 && measuredIterationCount % 3 == 0
        )
        var backends: [SparseTileSamplingBackend] = [.directFallback]
        if device.argumentBuffersSupport == .tier2 {
            backends.append(.tier2ArgumentBuffer)
        }
        var results: [SparseTileSamplingAllocationProbeResult] = []
        results.reserveCapacity(backends.count)
        for backend in backends {
            results.append(try await runBackend(
                backend,
                device: device,
                library: library,
                probe: probe,
                warmupIterationCount: warmupIterationCount,
                measuredIterationCount: measuredIterationCount
            ))
        }
        return results
    }

    @MainActor
    private static func runBackend(
        _ backend: SparseTileSamplingBackend,
        device: any MTLDevice,
        library: any MTLLibrary,
        probe: StrokePreparationAllocationProbe,
        warmupIterationCount: Int,
        measuredIterationCount: Int
    ) async throws -> SparseTileSamplingAllocationProbeResult {
        let fixture = try makeFixture(device: device)
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: SparseTileSamplingPipelineKey(
                backend: backend,
                outputPixelFormatRawValue: MTLPixelFormat.rgba16Float.rawValue,
                sampleCount: 1,
                abiVersion: SparseSamplingABI.version
            )
        )
        let cache = SparseTileSamplingGPUPlanCache(
            device: device,
            limits: SparseTileSamplingGPUPlanLimits(
                maximumDescriptors: 3,
                maximumPageEntries: 64,
                maximumBufferBytes: 64 * 1_024,
                maximumInflightEncodes: 3
            )
        )
        guard let queue = device.makeCommandQueue() else {
            throw SparseTileSamplingPipelineError.bufferCreationFailed(
                "sampling allocation probe queue"
            )
        }
        let targets = (
            try makeTarget(device: device, width: fixture.size.width),
            try makeTarget(device: device, width: fixture.size.width),
            try makeTarget(device: device, width: fixture.size.width)
        )

        for _ in 0..<(warmupIterationCount / 3) {
            try await executeThree(
                cache: cache,
                sourcePlan: fixture.plan,
                pipeline: pipeline,
                targets: targets,
                queue: queue,
                probe: nil
            )
        }
        let warmed = await cache.allocationSnapshot
        let warmedTerminalCount = await cache.completionSnapshot
            .terminalCommandCount

        for _ in 0..<(measuredIterationCount / 3) {
            try await executeThree(
                cache: cache,
                sourcePlan: fixture.plan,
                pipeline: pipeline,
                targets: targets,
                queue: queue,
                probe: probe
            )
        }
        let final = await cache.allocationSnapshot
        let completion = await cache.completionSnapshot
        try fixture.plan.retire()
        let sourceSnapshot = fixture.surface.backingSnapshot()
        let warmedUpload = warmed.uploadRing
        let finalUpload = final.uploadRing
        return SparseTileSamplingAllocationProbeResult(
            backend: String(describing: backend),
            measuredIterationCount: measuredIterationCount,
            sourceTileCount: fixture.sourceTileCount,
            drawCount: backend == .tier2ArgumentBuffer
                ? 1
                : fixture.plan.content.batches.count,
            warmedPlanMetalBufferAllocationCount:
                warmed.planMetalBufferAllocationCount,
            finalPlanMetalBufferAllocationCount:
                final.planMetalBufferAllocationCount,
            warmedPlanMetalBufferAllocationBytes:
                warmed.planMetalBufferAllocationBytes,
            finalPlanMetalBufferAllocationBytes:
                final.planMetalBufferAllocationBytes,
            warmedCachedPlanMetalBufferBytes:
                warmed.cachedPlanMetalBufferBytes,
            finalCachedPlanMetalBufferBytes:
                final.cachedPlanMetalBufferBytes,
            warmedUploadMetalBufferAllocationCount:
                warmedUpload?.metalBufferAllocationCount ?? 0,
            finalUploadMetalBufferAllocationCount:
                finalUpload?.metalBufferAllocationCount ?? 0,
            warmedUploadMetalBufferBytes:
                warmedUpload?.metalBufferBytes ?? 0,
            finalUploadMetalBufferBytes:
                finalUpload?.metalBufferBytes ?? 0,
            uploadCapacity: finalUpload?.capacity ?? 0,
            uploadHighWaterSlotCount: finalUpload?.highWaterSlotCount ?? 0,
            finalActiveUploadSlotCount: finalUpload?.activeSlotCount ?? -1,
            terminalCommandCount:
                completion.terminalCommandCount - warmedTerminalCount,
            commandFailureCount: completion.commandFailureCount,
            planCompletionFailureCount:
                completion.planCompletionFailureCount,
            pendingCompletionCount:
                completion.pendingPlanCompletionCount
                    + completion.pendingConsumerCompletionCount,
            finalSourceActiveLeaseCount: sourceSnapshot.activeLeaseCount
        )
    }

    @MainActor
    private static func executeThree(
        cache: SparseTileSamplingGPUPlanCache,
        sourcePlan: SparseTileSamplingPlanLease,
        pipeline: SparseTileSamplingPipelineBinding,
        targets: (any MTLTexture, any MTLTexture, any MTLTexture),
        queue: any MTLCommandQueue,
        probe: StrokePreparationAllocationProbe?
    ) async throws {
        let first = try await prepare(
            cache: cache,
            sourcePlan: sourcePlan,
            pipeline: pipeline,
            probe: probe
        )
        let second = try await prepare(
            cache: cache,
            sourcePlan: sourcePlan,
            pipeline: pipeline,
            probe: probe
        )
        let third = try await prepare(
            cache: cache,
            sourcePlan: sourcePlan,
            pipeline: pipeline,
            probe: probe
        )
        guard first.plan.uploadRingSnapshot.activeSlotCount == 3 else {
            throw SparseTileSamplingPipelineError.pipelineCreationFailed(
                "sampling allocation probe did not reach three in-flight slots"
            )
        }
        let firstPending = try submit(
            prepared: first.prepared,
            target: targets.0,
            queue: queue,
            probe: probe
        )
        let secondPending = try submit(
            prepared: second.prepared,
            target: targets.1,
            queue: queue,
            probe: probe
        )
        let thirdPending = try submit(
            prepared: third.prepared,
            target: targets.2,
            queue: queue,
            probe: probe
        )
        try await wait(firstPending, probe: probe)
        try await wait(secondPending, probe: probe)
        try await wait(thirdPending, probe: probe)
    }

    @MainActor
    private static func prepare(
        cache: SparseTileSamplingGPUPlanCache,
        sourcePlan: SparseTileSamplingPlanLease,
        pipeline: SparseTileSamplingPipelineBinding,
        probe: StrokePreparationAllocationProbe?
    ) async throws -> (
        plan: SparseTileSamplingGPUPlanLease,
        prepared: SparseTileSamplingPreparedSubmission
    ) {
        let plan = try await cache.acquire(
            plan: sourcePlan,
            pipeline: pipeline,
            allocationProbe: probe
        )
        let prepared = try SparseTileSamplingEncoder.prepareSubmission(
            plan: plan,
            parameters: .identity,
            allocationProbe: probe
        )
        return (plan, prepared)
    }

    @MainActor
    private static func submit(
        prepared: SparseTileSamplingPreparedSubmission,
        target: any MTLTexture,
        queue: any MTLCommandQueue,
        probe: StrokePreparationAllocationProbe?
    ) throws -> SparseTileSamplingPendingCommand {
        probe?.arm()
        defer {
            probe?.disarmAndRecord(.sparseSamplingMetalSubmission)
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw SparseTileSamplingPipelineError.pipelineCreationFailed(
                "sampling allocation probe command"
            )
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let waiter = SparseTileSamplingCommandWaiter()
        try prepared.encode(
            target: target,
            commandBuffer: commandBuffer,
            renderPassDescriptor: pass,
            completionAllocationProbe: probe
        )
        commandBuffer.addCompletedHandler { _ in waiter.signal() }
        commandBuffer.commit()
        return SparseTileSamplingPendingCommand(
            commandBuffer: commandBuffer,
            waiter: waiter
        )
    }

    @MainActor
    private static func wait(
        _ pending: SparseTileSamplingPendingCommand,
        probe: StrokePreparationAllocationProbe?
    ) async throws {
        probe?.arm()
        await pending.waiter.wait()
        probe?.disarmAndRecord(.sparseSamplingCompletionWait)
        let commandBuffer = pending.commandBuffer
        guard commandBuffer.status == .completed,
              commandBuffer.error == nil
        else {
            throw SparseTileSamplingPipelineError.pipelineCreationFailed(
                commandBuffer.error?.localizedDescription
                    ?? "sampling allocation probe command status "
                    + "\(commandBuffer.status.rawValue)"
            )
        }
    }

    @MainActor
    private static func makeFixture(
        device: any MTLDevice
    ) throws -> (
        surface: TiledRasterSurface,
        plan: SparseTileSamplingPlanLease,
        size: PixelSize,
        sourceTileCount: Int
    ) {
        let layerID = UUID(
            uuidString: "d500ca11-0ca7-4d50-a110-ca710a54d504"
        )!
        let sourceTileCount = 17
        let size = PixelSize(
            width: sourceTileCount * PaintTileDescriptor.side,
            height: PaintTileDescriptor.side
        )
        let surface = TiledRasterSurface(
            device: device,
            layerID: layerID,
            pixelSize: size,
            generation: 1,
            byteBudget: sourceTileCount * PaintTileDescriptor.residentByteCount
        )
        let coordinates = (0..<sourceTileCount).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        let lease = try surface.reserveTiles(
            at: coordinates,
            pinReasons: [.dirty]
        )
        try surface.markDirty(lease)
        try surface.returnLease(lease)
        let roleKey = SparseTileRoleContentKey(
            role: .canonical,
            surfaceIdentity: surface.surfaceID,
            contentRevision: surface.revision.rawValue,
            bindingChunkRevision: 1
        )
        let source = try SparseTileSourceRequest(
            contentKey: roleKey,
            addressing: .finite(size),
            provider: surface.makeExactReferenceProvider(),
            changedCoordinates: coordinates,
            disposition: .fullSnapshot
        )
        let planKey = SparseTileSamplingPlanKey(
            documentGeneration: 1,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: layerID,
                roles: [roleKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1
        )
        let plan = try SparseTileSamplingPlanCache().acquire(
            key: planKey,
            sourceBatch: try SparseTileOwnedSourceBatch.capturingSelection(
                sources: [source],
                key: planKey,
                outputRegion: try SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: size.width, maxY: 1
                )
            ),
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: size.width, maxY: 1
            ),
            limits: SparseTilePlanLimits(
                maximumPageEntries: 64,
                maximumPageChunks: 16,
                maximumPageTableBytes: 64 * 32,
                maximumBindingSlots: 512,
                maximumBindingChunks: 16,
                maximumBindingBytes: 512 * 64,
                maximumTexturesPerBatch: 16,
                maximumBatchCount: 64
            )
        )
        return (surface, plan, size, sourceTileCount)
    }

    private static func makeTarget(
        device: any MTLDevice,
        width: Int
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw SparseTileSamplingPipelineError.bufferCreationFailed(
                "sampling allocation probe target"
            )
        }
        return target
    }
}
