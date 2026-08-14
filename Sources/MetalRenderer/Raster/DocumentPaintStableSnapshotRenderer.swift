import Foundation
@preconcurrency import Metal
import CShaderTypes

enum DocumentPaintStableSnapshotRendererError: Error, Equatable, Sendable {
    case invalidLimit
    case invalidRequest
    case arithmeticOverflow
    case inexactFloatCoordinate
    case childOutsideFullRegion
    case busy
    case cleanupPending
    case shutDown
    case reentrantSinkOperation
    case chunkCountLimitExceeded(maximum: Int)
    case outputLimitExceeded(required: Int, maximum: Int)
    case cannotFitMinimumChunk(SparseTileOutputRegion)
    case commandCreationFailed
    case commandFailed(String)
    case readbackEncodingFailed
}

struct DocumentPaintStableSnapshotRendererLimits: Equatable, Sendable {
    let maximumChunkWidth: Int
    let maximumChunkHeight: Int
    let maximumScratchBytes: Int
    let maximumChunkCount: Int
    let maximumOutputPixels: Int
    let maximumOutputBytes: Int
    let maximumRetryCleanupPasses: Int

    init(
        maximumChunkWidth: Int,
        maximumChunkHeight: Int,
        maximumScratchBytes: Int,
        maximumChunkCount: Int = 65_536,
        maximumOutputPixels: Int = 268_435_456,
        maximumOutputBytes: Int = 1_073_741_824,
        maximumRetryCleanupPasses: Int
    ) throws {
        guard maximumChunkWidth > 0,
              maximumChunkHeight > 0,
              maximumScratchBytes > 0,
              maximumChunkCount > 0,
              maximumOutputPixels > 0,
              maximumOutputBytes > 0,
              maximumRetryCleanupPasses > 0
        else {
            throw DocumentPaintStableSnapshotRendererError.invalidLimit
        }
        let (_, pixelOverflow) = maximumChunkWidth
            .multipliedReportingOverflow(by: maximumChunkHeight)
        guard !pixelOverflow else {
            throw DocumentPaintStableSnapshotRendererError.invalidLimit
        }
        let rowBytes = try? DocumentPaintStableSnapshotChunkPlanner
            .alignedReadbackBytesPerRow(width: maximumChunkWidth)
        guard let rowBytes else {
            throw DocumentPaintStableSnapshotRendererError.invalidLimit
        }
        let (readbackBytes, readbackOverflow) = rowBytes
            .multipliedReportingOverflow(by: maximumChunkHeight)
        guard !readbackOverflow, readbackBytes <= maximumScratchBytes else {
            throw DocumentPaintStableSnapshotRendererError.invalidLimit
        }
        self.maximumChunkWidth = maximumChunkWidth
        self.maximumChunkHeight = maximumChunkHeight
        self.maximumScratchBytes = maximumScratchBytes
        self.maximumChunkCount = maximumChunkCount
        self.maximumOutputPixels = maximumOutputPixels
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumRetryCleanupPasses = maximumRetryCleanupPasses
    }

    static let production = try! Self(
        maximumChunkWidth: 2_048,
        maximumChunkHeight: 2_048,
        maximumScratchBytes: 32 * 1_024 * 1_024,
        maximumRetryCleanupPasses: 8
    )
}

enum DocumentPaintStableSnapshotChunkPlanner {
    static func orderedForEmission(
        _ regions: [SparseTileOutputRegion]
    ) -> [SparseTileOutputRegion] {
        regions.sorted {
            ($0.minY, $0.minX, $0.height, $0.width)
                < ($1.minY, $1.minX, $1.height, $1.width)
        }
    }

    static func validateOutput(
        _ region: SparseTileOutputRegion,
        limits: DocumentPaintStableSnapshotRendererLimits
    ) throws {
        let (pixels, overflow) = region.width
            .multipliedReportingOverflow(by: region.height)
        guard !overflow else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        guard pixels <= limits.maximumOutputPixels else {
            throw DocumentPaintStableSnapshotRendererError
                .outputLimitExceeded(
                    required: pixels,
                    maximum: limits.maximumOutputPixels
                )
        }
        let bytes = try checkedOutputByteCount(region)
        guard bytes <= limits.maximumOutputBytes else {
            throw DocumentPaintStableSnapshotRendererError
                .outputLimitExceeded(
                    required: bytes,
                    maximum: limits.maximumOutputBytes
                )
        }
    }

    static func bisect(
        _ region: SparseTileOutputRegion
    ) throws -> [SparseTileOutputRegion] {
        guard region.width > 1 || region.height > 1 else {
            throw DocumentPaintStableSnapshotRendererError
                .cannotFitMinimumChunk(region)
        }
        if region.width >= region.height {
            let midpoint = try checkedAdd(region.minX, region.width / 2)
            return [
                try SparseTileOutputRegion(
                    minX: region.minX,
                    minY: region.minY,
                    maxX: midpoint,
                    maxY: region.maxY
                ),
                try SparseTileOutputRegion(
                    minX: midpoint,
                    minY: region.minY,
                    maxX: region.maxX,
                    maxY: region.maxY
                ),
            ]
        }
        let midpoint = try checkedAdd(region.minY, region.height / 2)
        return [
            try SparseTileOutputRegion(
                minX: region.minX,
                minY: region.minY,
                maxX: region.maxX,
                maxY: midpoint
            ),
            try SparseTileOutputRegion(
                minX: region.minX,
                minY: midpoint,
                maxX: region.maxX,
                maxY: region.maxY
            ),
        ]
    }

    static func alignedReadbackBytesPerRow(width: Int) throws -> Int {
        guard width > 0 else {
            throw DocumentPaintStableSnapshotRendererError.invalidRequest
        }
        let (raw, rawOverflow) = width.multipliedReportingOverflow(by: 4)
        let (withPadding, paddingOverflow) = raw
            .addingReportingOverflow(255)
        guard !rawOverflow, !paddingOverflow else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        return (withPadding / 256) * 256
    }

    static func childTransform(
        global: SparseTileOutputToSourceTransform,
        full: SparseTileOutputRegion,
        child: SparseTileOutputRegion
    ) throws -> SparseTileOutputToSourceTransform {
        guard child.minX >= full.minX,
              child.minY >= full.minY,
              child.maxX <= full.maxX,
              child.maxY <= full.maxY
        else {
            throw DocumentPaintStableSnapshotRendererError
                .childOutsideFullRegion
        }
        guard global.sourceOffset.x.isFinite,
              global.sourceOffset.y.isFinite,
              global.sourceStep.x.isFinite,
              global.sourceStep.y.isFinite
        else {
            throw DocumentPaintStableSnapshotRendererError.invalidRequest
        }
        let deltaX = try checkedSubtract(child.minX, full.minX)
        let deltaY = try checkedSubtract(child.minY, full.minY)
        let floatDeltaX = Float(deltaX)
        let floatDeltaY = Float(deltaY)
        guard floatDeltaX.isFinite,
              floatDeltaY.isFinite,
              Int(exactly: floatDeltaX) == deltaX,
              Int(exactly: floatDeltaY) == deltaY,
              Float(full.minX).isFinite,
              Float(full.minY).isFinite,
              Float(child.minX).isFinite,
              Float(child.minY).isFinite,
              Int(exactly: Float(full.minX)) == full.minX,
              Int(exactly: Float(full.minY)) == full.minY,
              Int(exactly: Float(child.minX)) == child.minX,
              Int(exactly: Float(child.minY)) == child.minY
        else {
            throw DocumentPaintStableSnapshotRendererError
                .inexactFloatCoordinate
        }
        let adjustment = SIMD2(floatDeltaX, floatDeltaY)
            * (global.sourceStep - SIMD2(repeating: 1))
        let offset = global.sourceOffset + adjustment
        guard offset.x.isFinite, offset.y.isFinite else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        return SparseTileOutputToSourceTransform(
            sourceOffset: offset,
            sourceStep: global.sourceStep
        )
    }

    static func childMapping(
        global: SparseTileSamplingOutputMapping,
        full: SparseTileOutputRegion,
        child: SparseTileOutputRegion
    ) throws -> SparseTileSamplingOutputMapping {
        switch global {
        case let .affine(transform):
            return .affine(try childTransform(
                global: transform,
                full: full,
                child: child
            ))
        case let .periodic(mapping):
            // Retain the root transform itself. Only the recovered root pixel
            // and cumulative relative offset participate in the periodic ABI;
            // an absolute child coordinate beyond Float's consecutive-integer
            // range is valid when that pair remains exact.
            guard child.minX >= full.minX,
                  child.minY >= full.minY,
                  child.maxX <= full.maxX,
                  child.maxY <= full.maxY
            else {
                throw DocumentPaintStableSnapshotRendererError
                    .childOutsideFullRegion
            }
            let transform = mapping.outputToWorldTransform
            guard transform.sourceOffset.x.isFinite,
                  transform.sourceOffset.y.isFinite,
                  transform.sourceStep.x.isFinite,
                  transform.sourceStep.y.isFinite,
                  mapping.screenPixelOffset.x >= 0,
                  mapping.screenPixelOffset.y >= 0,
                  mapping.screenPixelOffset.x <= Int(UInt32.max),
                  mapping.screenPixelOffset.y <= Int(UInt32.max),
                  Int(exactly: Float(mapping.screenPixelOffset.x))
                    == mapping.screenPixelOffset.x,
                  Int(exactly: Float(mapping.screenPixelOffset.y))
                    == mapping.screenPixelOffset.y
            else {
                throw DocumentPaintStableSnapshotRendererError
                    .inexactFloatCoordinate
            }
            let rootX = try checkedSubtract(
                full.minX, mapping.screenPixelOffset.x
            )
            let rootY = try checkedSubtract(
                full.minY, mapping.screenPixelOffset.y
            )
            let floatRoot = SIMD2(Float(rootX), Float(rootY))
            let sourceOrigin = floatRoot + transform.sourceOffset
            guard floatRoot.x.isFinite, floatRoot.y.isFinite,
                  Int(exactly: floatRoot.x) == rootX,
                  Int(exactly: floatRoot.y) == rootY,
                  sourceOrigin.x.isFinite, sourceOrigin.y.isFinite
            else {
                throw DocumentPaintStableSnapshotRendererError
                    .inexactFloatCoordinate
            }
            let deltaX = try checkedSubtract(child.minX, full.minX)
            let deltaY = try checkedSubtract(child.minY, full.minY)
            let (offsetX, overflowX) = mapping.screenPixelOffset.x
                .addingReportingOverflow(deltaX)
            let (offsetY, overflowY) = mapping.screenPixelOffset.y
                .addingReportingOverflow(deltaY)
            guard offsetX >= 0, offsetY >= 0,
                  !overflowX, !overflowY,
                  offsetX <= Int(UInt32.max),
                  offsetY <= Int(UInt32.max),
                  Int(exactly: Float(offsetX)) == offsetX,
                  Int(exactly: Float(offsetY)) == offsetY
            else {
                throw DocumentPaintStableSnapshotRendererError
                    .inexactFloatCoordinate
            }
            return .periodic(SparseTilePeriodicOutputMapping(
                fold: mapping.fold,
                outputToWorldTransform: mapping.outputToWorldTransform,
                screenPixelOffset: SIMD2(offsetX, offsetY)
            ))
        case let .finiteRadial(mapping):
            guard child.minX >= full.minX,
                  child.minY >= full.minY,
                  child.maxX <= full.maxX,
                  child.maxY <= full.maxY
            else {
                throw DocumentPaintStableSnapshotRendererError
                    .childOutsideFullRegion
            }
            for coordinate in [
                full.minX, full.minY, full.maxX, full.maxY,
                child.minX, child.minY, child.maxX, child.maxY,
            ] {
                let value = Float(coordinate)
                guard value.isFinite, Int(exactly: value) == coordinate else {
                    throw DocumentPaintStableSnapshotRendererError
                        .inexactFloatCoordinate
                }
            }
            return .finiteRadial(try SparseTileFiniteRadialOutputMapping(
                strategy: mapping.strategy,
                outputToWorldTransform: try childTransform(
                    global: mapping.outputToWorldTransform,
                    full: full,
                    child: child
                )
            ))
        }
    }

    static func checkedOutputByteCount(
        _ region: SparseTileOutputRegion
    ) throws -> Int {
        let (pixels, pixelOverflow) = region.width
            .multipliedReportingOverflow(by: region.height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        return bytes
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        return value
    }

    private static func checkedSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        return value
    }
}

struct DocumentPaintStableSnapshotPendingRegions: Sendable {
    private var heap: [SparseTileOutputRegion] = []

    var count: Int { heap.count }
    var isEmpty: Bool { heap.isEmpty }

    mutating func insert(_ region: SparseTileOutputRegion) {
        heap.append(region)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.precedes(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func popFirst() -> SparseTileOutputRegion? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let result = heap[0]
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            let child = right < heap.count
                && Self.precedes(heap[right], heap[left]) ? right : left
            guard Self.precedes(heap[child], heap[parent]) else { break }
            heap.swapAt(parent, child)
            parent = child
        }
        return result
    }

    private static func precedes(
        _ lhs: SparseTileOutputRegion,
        _ rhs: SparseTileOutputRegion
    ) -> Bool {
        (lhs.minY, lhs.minX, lhs.height, lhs.width)
            < (rhs.minY, rhs.minX, rhs.height, rhs.width)
    }
}

struct DocumentPaintStableSnapshotRenderRequest: @unchecked Sendable {
    let snapshot: DocumentPaintStableCanonicalSnapshot
    let outputRegion: SparseTileOutputRegion
    let outputGeometryRevision: UInt64
    let outputMapping: SparseTileSamplingOutputMapping

    var outputToSourceTransform: SparseTileOutputToSourceTransform {
        outputMapping.outputToWorldTransform
    }

    init(
        snapshot: DocumentPaintStableCanonicalSnapshot,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputToSourceTransform: SparseTileOutputToSourceTransform = .identity
    ) {
        self.snapshot = snapshot
        self.outputRegion = outputRegion
        self.outputGeometryRevision = outputGeometryRevision
        outputMapping = .affine(outputToSourceTransform)
    }

    init(
        snapshot: DocumentPaintStableCanonicalSnapshot,
        outputRegion: SparseTileOutputRegion,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping
    ) {
        self.snapshot = snapshot
        self.outputRegion = outputRegion
        self.outputGeometryRevision = outputGeometryRevision
        self.outputMapping = outputMapping
    }
}

struct DocumentPaintStableSnapshotSinkDescriptor: Equatable, Sendable {
    let outputRegion: SparseTileOutputRegion
    let bytesPerPixel: Int
    let pixelFormatRawValue: UInt
}

struct DocumentPaintStableSnapshotChunk: Equatable, Sendable {
    let outputRegion: SparseTileOutputRegion
    let bytesPerRow: Int
    let bytes: Data
}

protocol DocumentPaintStableSnapshotSink: Sendable {
    func begin(_ descriptor: DocumentPaintStableSnapshotSinkDescriptor)
        async throws
    func consume(_ chunk: DocumentPaintStableSnapshotChunk) async throws
    func finish() async throws
    func abort() async
}

enum DocumentPaintStableSnapshotRendererLifecycle: Equatable, Sendable {
    case active
    case busy
    case cleaning
    case cleanupPending
    case shutDown
}

struct DocumentPaintStableSnapshotRendererMetrics: Equatable, Sendable {
    var requestCount: UInt64 = 0
    var completedRequestCount: UInt64 = 0
    var failedRequestCount: UInt64 = 0
    var cancellationCount: UInt64 = 0
    var emittedChunkCount: UInt64 = 0
    var emittedByteCount: UInt64 = 0
    var adaptiveSplitCount: UInt64 = 0
    var terminalCommandCount: UInt64 = 0
    var cleanupRetryPassCount: UInt64 = 0
    var targetAllocationCount: UInt64 = 0
    var readbackAllocationCount: UInt64 = 0
}

struct DocumentPaintStableSnapshotRendererSnapshot: Equatable, Sendable {
    let lifecycle: DocumentPaintStableSnapshotRendererLifecycle
    let shutdownRequested: Bool
    let shutdownWaiterCount: Int
    let metrics: DocumentPaintStableSnapshotRendererMetrics
    let inflightCommandCount: Int
    let targetByteCount: Int
    let readbackByteCount: Int
    let cpuCache: SparseTileSamplingPlanCacheSnapshot
    let gpuCache: SparseTileSamplingGPUCacheSnapshot
    let completion: SparseTileSamplingCompletionSnapshot
}

private enum DocumentPaintStableSnapshotAdaptiveCapacityError: Error {
    case scratch
}

enum DocumentPaintStableSnapshotRendererTestPhase: Hashable, Sendable {
    case scratchAllocation
    case targetAllocation
    case readbackAllocation
    case proportionalPlanBufferAllocation
    case commandCreation
    case submissionPreparation
    case submissionEncoding
    case readbackEncoding
    case commandTerminal
}

struct DocumentPaintStableSnapshotRendererTestHooks: @unchecked Sendable {
    var afterCPUEviction: (@Sendable () async -> Void)?
    var afterGPUAcquire: (@Sendable () async -> Void)?
    var afterGPUInvalidation: (@Sendable () async -> Void)?
    var beforeCommandCommit: (@Sendable () async -> Void)?
    var afterCommandCommit: (@Sendable () async -> Void)?
    var beforeCleanupRetryPass: (@Sendable () async -> Void)?
    var shouldFailAtPhase:
        (@Sendable (DocumentPaintStableSnapshotRendererTestPhase) -> Bool)?
}

private final class DocumentPaintStableSnapshotTerminalWaiter:
    @unchecked Sendable
{
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
        precondition(terminal == nil, "duplicate sparse terminal record")
        terminal = value
        let resolution = resolutionIfReadyLocked()
        let continuation = resolution == nil ? nil : self.continuation
        if continuation != nil { self.continuation = nil }
        lock.unlock()
        if let resolution, let continuation {
            continuation.resume(returning: resolution)
        }
    }

    func recordAuthenticatedReturn(commandSucceeded: Bool?) {
        lock.lock()
        precondition(
            !authenticatedReturnObserved,
            "duplicate sparse authenticated return"
        )
        authenticatedReturnObserved = true
        authenticatedCommandSucceeded = commandSucceeded
        let resolution = resolutionIfReadyLocked()
        let continuation = resolution == nil ? nil : self.continuation
        if continuation != nil { self.continuation = nil }
        lock.unlock()
        if let resolution, let continuation {
            continuation.resume(returning: resolution)
        }
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

private final class DocumentPaintStableSnapshotSinkInvocationToken:
    @unchecked Sendable
{}

private enum DocumentPaintStableSnapshotSinkInvocation {
    @TaskLocal static var tokens:
        [DocumentPaintStableSnapshotSinkInvocationToken] = []
}

actor DocumentPaintStableSnapshotRenderer {
    private struct Scratch: @unchecked Sendable {
        let target: any MTLTexture
        let readback: any MTLBuffer
        let width: Int
        let height: Int
        let alignedBytesPerRow: Int
        let targetByteCount: Int
        let readbackByteCount: Int
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipelines: [
        SparseTileSamplingOutputMappingKind: SparseTileSamplingPipelineBinding
    ]
    private let limits: DocumentPaintStableSnapshotRendererLimits
    private let planLimits: SparseTilePlanLimits
    private let planCache: SparseTileSamplingPlanCache
    private let gpuPlanCache: SparseTileSamplingGPUPlanCache
    private var lifecycle = DocumentPaintStableSnapshotRendererLifecycle.active
    private var shutdownRequested = false
    private var metrics = DocumentPaintStableSnapshotRendererMetrics()
    private var scratch: Scratch?
    private var inflightCommandCount = 0
    private let sinkInvocationToken =
        DocumentPaintStableSnapshotSinkInvocationToken()
    private var activeSinkInvocationCount = 0
    private var shutdownWaiters: [CheckedContinuation<Void, any Error>] = []
    private let testingHooks: DocumentPaintStableSnapshotRendererTestHooks?

    @MainActor
    static func make(
        device: any MTLDevice,
        library: any MTLLibrary,
        backendRequest: SparseTileSamplingBackendRequest = .automatic,
        limits: DocumentPaintStableSnapshotRendererLimits = .production,
        planLimits: SparseTilePlanLimits = .documentProduction
    ) throws -> DocumentPaintStableSnapshotRenderer {
        let backend = try SparseTileSamplingBackend.select(
            request: backendRequest,
            capabilities: SparseTileSamplingDeviceCapabilities(device: device)
        )
        let pipelines = try makePipelines(
            device: device,
            library: library,
            backend: backend
        )
        guard let commandQueue = device.makeCommandQueue() else {
            throw DocumentPaintStableSnapshotRendererError
                .commandCreationFailed
        }
        return DocumentPaintStableSnapshotRenderer(
            device: device,
            commandQueue: commandQueue,
            pipelines: pipelines,
            limits: limits,
            planLimits: planLimits,
            planCache: SparseTileSamplingPlanCache(),
            gpuPlanCache: SparseTileSamplingGPUPlanCache(
                device: device,
                limits: dedicatedGPULimits(planLimits: planLimits)
            )
        )
    }

    @MainActor
    private static func makePipelines(
        device: any MTLDevice,
        library: any MTLLibrary,
        backend: SparseTileSamplingBackend
    ) throws -> [
        SparseTileSamplingOutputMappingKind: SparseTileSamplingPipelineBinding
    ] {
        var result: [
            SparseTileSamplingOutputMappingKind:
                SparseTileSamplingPipelineBinding
        ] = [:]
        for kind in [
            SparseTileSamplingOutputMappingKind.affine,
            .periodic,
            .finiteRadial,
        ] {
            result[kind] = try SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: SparseTileSamplingPipelineKey(
                    backend: backend,
                    outputPixelFormatRawValue:
                        DocumentColorPipeline.interchangePixelFormat.rawValue,
                    sampleCount: 1,
                    abiVersion: SparseSamplingABI.version,
                    outputMappingKind: kind
                )
            )
        }
        return result
    }

    #if DEBUG
    @MainActor
    static func testingMake(
        device: any MTLDevice,
        library: any MTLLibrary,
        backendRequest: SparseTileSamplingBackendRequest = .forceFallback,
        limits: DocumentPaintStableSnapshotRendererLimits = .production,
        planLimits: SparseTilePlanLimits = .documentProduction,
        planCache: SparseTileSamplingPlanCache,
        preparedAbandonmentFailureInjector:
            SparseTileSamplingPreparedAbandonmentFailureInjector? = nil,
        hooks: DocumentPaintStableSnapshotRendererTestHooks = .init()
    ) throws -> DocumentPaintStableSnapshotRenderer {
        let backend = try SparseTileSamplingBackend.select(
            request: backendRequest,
            capabilities: SparseTileSamplingDeviceCapabilities(device: device)
        )
        let pipelines = try makePipelines(
            device: device,
            library: library,
            backend: backend
        )
        guard let queue = device.makeCommandQueue() else {
            throw DocumentPaintStableSnapshotRendererError.commandCreationFailed
        }
        return DocumentPaintStableSnapshotRenderer(
            device: device,
            commandQueue: queue,
            pipelines: pipelines,
            limits: limits,
            planLimits: planLimits,
            planCache: planCache,
            gpuPlanCache: SparseTileSamplingGPUPlanCache(
                device: device,
                limits: dedicatedGPULimits(planLimits: planLimits),
                preparedAbandonmentFailureInjector:
                    preparedAbandonmentFailureInjector
            ),
            testingHooks: hooks
        )
    }
    #endif

    private init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        pipelines: [
            SparseTileSamplingOutputMappingKind:
                SparseTileSamplingPipelineBinding
        ],
        limits: DocumentPaintStableSnapshotRendererLimits,
        planLimits: SparseTilePlanLimits,
        planCache: SparseTileSamplingPlanCache,
        gpuPlanCache: SparseTileSamplingGPUPlanCache,
        testingHooks: DocumentPaintStableSnapshotRendererTestHooks? = nil
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.pipelines = pipelines
        self.limits = limits
        self.planLimits = planLimits
        self.planCache = planCache
        self.gpuPlanCache = gpuPlanCache
        self.testingHooks = testingHooks
    }

    func render(
        _ request: DocumentPaintStableSnapshotRenderRequest,
        to sink: any DocumentPaintStableSnapshotSink
    ) async throws {
        try beginRequest(request)
        var sinkStarted = false
        var sinkFinished = false
        do {
            try ensureMayContinue()
            sinkStarted = true
            try await invokeSink {
                try await sink.begin(
                    DocumentPaintStableSnapshotSinkDescriptor(
                        outputRegion: request.outputRegion,
                        bytesPerPixel: 4,
                        pixelFormatRawValue: DocumentColorPipeline
                            .interchangePixelFormat.rawValue
                    )
                )
            }
            try ensureMayContinue()
            var pending = DocumentPaintStableSnapshotPendingRegions()
            pending.insert(request.outputRegion)
            var attemptedChunkCount = 0
            while let chunkRegion = pending.popFirst() {
                try ensureMayContinue()
                attemptedChunkCount = try incremented(attemptedChunkCount)
                guard attemptedChunkCount <= limits.maximumChunkCount else {
                    throw DocumentPaintStableSnapshotRendererError
                        .chunkCountLimitExceeded(
                            maximum: limits.maximumChunkCount
                        )
                }
                let chunk: DocumentPaintStableSnapshotChunk
                do {
                    chunk = try await renderChunk(
                        request: request,
                        region: chunkRegion
                    )
                } catch {
                    guard isAdaptiveCapacityError(error) else { throw error }
                    guard chunkRegion.width > 1 || chunkRegion.height > 1 else {
                        throw DocumentPaintStableSnapshotRendererError
                            .cannotFitMinimumChunk(chunkRegion)
                    }
                    let halves = try DocumentPaintStableSnapshotChunkPlanner
                        .bisect(chunkRegion)
                    pending.insert(halves[0])
                    pending.insert(halves[1])
                    increment(&metrics.adaptiveSplitCount)
                    continue
                }
                try ensureMayContinue()
                try await invokeSink { try await sink.consume(chunk) }
                increment(&metrics.emittedChunkCount)
                add(
                    UInt64(chunk.bytes.count),
                    to: &metrics.emittedByteCount
                )
            }
            try ensureMayContinue()
            try await invokeSink { try await sink.finish() }
            sinkFinished = true
            increment(&metrics.completedRequestCount)
            await settleLifecycleAfterOperation()
        } catch {
            if sinkStarted && !sinkFinished {
                await invokeSink { await sink.abort() }
            }
            increment(&metrics.failedRequestCount)
            if error is CancellationError { increment(&metrics.cancellationCount) }
            await settleLifecycleAfterOperation()
            throw error
        }
    }

    @discardableResult
    func retryCleanup() async throws
        -> DocumentPaintStableSnapshotRendererSnapshot
    {
        if lifecycle == .busy || lifecycle == .cleaning {
            throw DocumentPaintStableSnapshotRendererError.busy
        }
        guard lifecycle == .cleanupPending else {
            if lifecycle == .shutDown {
                throw DocumentPaintStableSnapshotRendererError.shutDown
            }
            return await snapshot()
        }
        lifecycle = .cleaning
        let cleaned = await performBoundedCleanup()
        if cleaned {
            if shutdownRequested {
                completeShutdown(cleaned: true)
            } else {
                lifecycle = .active
            }
            return await snapshot()
        }
        if shutdownRequested {
            completeShutdown(cleaned: false)
        } else {
            lifecycle = .cleanupPending
        }
        throw DocumentPaintStableSnapshotRendererError.cleanupPending
    }

    func shutdown() async throws {
        guard !DocumentPaintStableSnapshotSinkInvocation.tokens.contains(
            where: { $0 === sinkInvocationToken }
        ) || activeSinkInvocationCount == 0
        else {
            throw DocumentPaintStableSnapshotRendererError
                .reentrantSinkOperation
        }
        shutdownRequested = true
        switch lifecycle {
        case .active:
            completeShutdown(cleaned: true)
        case .shutDown:
            return
        case .busy, .cleaning:
            try await withCheckedThrowingContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        case .cleanupPending:
            lifecycle = .cleaning
            let cleaned = await performBoundedCleanup()
            completeShutdown(cleaned: cleaned)
            guard cleaned else {
                throw DocumentPaintStableSnapshotRendererError.cleanupPending
            }
        }
    }

    func snapshot() async -> DocumentPaintStableSnapshotRendererSnapshot {
        let gpu = await gpuPlanCache.allocationSnapshot
        let completion = await gpuPlanCache.completionSnapshot
        return DocumentPaintStableSnapshotRendererSnapshot(
            lifecycle: lifecycle,
            shutdownRequested: shutdownRequested,
            shutdownWaiterCount: shutdownWaiters.count,
            metrics: metrics,
            inflightCommandCount: inflightCommandCount,
            targetByteCount: scratch?.targetByteCount ?? 0,
            readbackByteCount: scratch?.readbackByteCount ?? 0,
            cpuCache: planCache.snapshot(),
            gpuCache: gpu,
            completion: completion
        )
    }

    private func beginRequest(
        _ request: DocumentPaintStableSnapshotRenderRequest
    ) throws {
        switch lifecycle {
        case .active: break
        case .busy, .cleaning:
            throw DocumentPaintStableSnapshotRendererError.busy
        case .cleanupPending:
            throw DocumentPaintStableSnapshotRendererError.cleanupPending
        case .shutDown:
            throw DocumentPaintStableSnapshotRendererError.shutDown
        }
        guard !request.snapshot.isClosed else {
            throw DocumentPaintStableSnapshotRendererError.invalidRequest
        }
        switch request.outputMapping {
        case let .affine(transform):
            guard transform.sourceOffset.x.isFinite,
                  transform.sourceOffset.y.isFinite,
                  transform.sourceStep.x.isFinite,
                  transform.sourceStep.y.isFinite
            else {
                throw DocumentPaintStableSnapshotRendererError.invalidRequest
            }
        case let .periodic(mapping):
            guard case let .periodic(period) = request.snapshot.addressing,
                  request.snapshot.geometry.radialLayout == nil,
                  request.snapshot.geometry.storagePixelSize == period
            else {
                throw SparseTileSamplingPlanError.inconsistentAddressing
            }
            try SparseTilePeriodicOutputMappingValidator.validate(
                mapping,
                addressing: request.snapshot.addressing
            )
        case let .finiteRadial(mapping):
            guard case let .radial(layout) = request.snapshot.addressing,
                  layout == mapping.layout,
                  request.snapshot.geometry.radialLayout == mapping.layout,
                  request.snapshot.geometry.documentPixelSize
                    == mapping.strategy.canvasSize
            else {
                throw SparseTileSamplingPlanError.inconsistentAddressing
            }
        }
        try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
            request.outputRegion,
            limits: limits
        )
        _ = try DocumentPaintStableSnapshotChunkPlanner.childMapping(
            global: request.outputMapping,
            full: request.outputRegion,
            child: request.outputRegion
        )
        lifecycle = .busy
        increment(&metrics.requestCount)
    }

    private func renderChunk(
        request: DocumentPaintStableSnapshotRenderRequest,
        region: SparseTileOutputRegion
    ) async throws -> DocumentPaintStableSnapshotChunk {
        let childMapping = try DocumentPaintStableSnapshotChunkPlanner
            .childMapping(
                global: request.outputMapping,
                full: request.outputRegion,
                child: region
            )
        guard let pipeline = pipelines[childMapping.kind] else {
            throw DocumentPaintStableSnapshotRendererError.invalidRequest
        }
        let scratch = try ensureScratch(for: region)
        #if DEBUG
        if testingHooks?.shouldFailAtPhase?(.commandCreation) == true {
            throw DocumentPaintStableSnapshotRendererError
                .commandCreationFailed
        }
        #endif
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DocumentPaintStableSnapshotRendererError
                .commandCreationFailed
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scratch.target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        var cpuPlan: SparseTileSamplingPlanLease?
        var gpuPlan: SparseTileSamplingGPUPlanLease?
        var prepared: SparseTileSamplingPreparedSubmission?
        do {
            try ensureMayContinue()
            let acquired = try request.snapshot.acquireVisiblePlan(
                cache: planCache,
                outputRegion: region,
                outputGeometryRevision: request.outputGeometryRevision,
                outputMapping: childMapping,
                limits: planLimits
            )
            cpuPlan = acquired
            _ = planCache.evictContent(
                key: acquired.content.key,
                outputRegion: region
            )
            #if DEBUG
            await testingHooks?.afterCPUEviction?()
            if testingHooks?.shouldFailAtPhase?(
                .proportionalPlanBufferAllocation
            ) == true {
                throw SparseTileSamplingPipelineError
                    .proportionalBufferCreationFailed(
                        label: "Sparse Page Entries",
                        requiredBytes: 1
                    )
            }
            #endif
            try ensureMayContinue()
            let acquiredGPU = try await gpuPlanCache.acquire(
                plan: acquired,
                pipeline: pipeline
            )
            gpuPlan = acquiredGPU
            #if DEBUG
            await testingHooks?.afterGPUAcquire?()
            #endif
            try ensureMayContinue()
            await gpuPlanCache.invalidate(content: acquired.content)
            #if DEBUG
            await testingHooks?.afterGPUInvalidation?()
            #endif
            try ensureMayContinue()
            try acquired.retire()
            #if DEBUG
            if testingHooks?.shouldFailAtPhase?(.submissionPreparation)
                == true {
                throw SparseTileSamplingPipelineError.injectedFailure(
                    "stableSnapshotSubmissionPreparation"
                )
            }
            #endif
            let submission = try SparseTileSamplingEncoder.prepareSubmission(
                plan: acquiredGPU,
                parameters: SparseTileSamplingEncodeParameters(
                    outputMapping: childMapping,
                    compositeMode: PatternCompositeWireDraw,
                    liveVisible: false,
                    strokeOpacity: 1,
                    accumulationLimit: 1,
                    eraserStrength: 1
                )
            )
            prepared = submission
            gpuPlan = nil
            #if DEBUG
            if testingHooks?.shouldFailAtPhase?(.submissionEncoding) == true {
                throw SparseTileSamplingPipelineError.injectedFailure(
                    "stableSnapshotSubmissionEncoding"
                )
            }
            #endif
            let waiter = DocumentPaintStableSnapshotTerminalWaiter()
            try submission.encode(
                target: scratch.target,
                commandBuffer: commandBuffer,
                renderPassDescriptor: pass,
                afterResourcesReturned: { _, succeeded in
                    waiter.recordAuthenticatedReturn(
                        commandSucceeded: succeeded
                    )
                },
                afterTerminalRecorded: { record in
                    waiter.recordTerminal(record)
                }
            )

            var postEncodeError: (any Error)?
            do {
                try encodeReadback(
                    commandBuffer: commandBuffer,
                    scratch: scratch,
                    region: region
                )
            } catch {
                postEncodeError = error
            }
            #if DEBUG
            await testingHooks?.beforeCommandCommit?()
            #endif
            inflightCommandCount = 1
            commandBuffer.commit()
            #if DEBUG
            await testingHooks?.afterCommandCommit?()
            #endif
            let resolution = await waiter.wait()
            inflightCommandCount = 0
            increment(&metrics.terminalCommandCount)
            prepared = nil
            cpuPlan = nil
            guard resolution.terminal.resourcesReturned else {
                throw DocumentPaintStableSnapshotRendererError.cleanupPending
            }
            if let postEncodeError { throw postEncodeError }
            #if DEBUG
            let forcedTerminalFailure = testingHooks?
                .shouldFailAtPhase?(.commandTerminal) == true
            #else
            let forcedTerminalFailure = false
            #endif
            guard case let .command(succeeded) = resolution.terminal.kind,
                  succeeded,
                  resolution.authenticatedCommandSucceeded == true,
                  !forcedTerminalFailure
            else {
                throw DocumentPaintStableSnapshotRendererError.commandFailed(
                    commandBuffer.error?.localizedDescription
                        ?? "command status \(commandBuffer.status.rawValue)"
                )
            }
            try ensureMayContinue()
            return try makeChunk(region: region, scratch: scratch)
        } catch {
            if let prepared {
                let waiter = DocumentPaintStableSnapshotTerminalWaiter()
                prepared.abandon(
                    afterResourcesReturned: { _ in
                        waiter.recordAuthenticatedReturn(commandSucceeded: nil)
                    },
                    afterTerminalRecorded: { record in
                        waiter.recordTerminal(record)
                    }
                )
                let resolution = await waiter.wait()
                _ = resolution
            } else if let unpreparedGPUPlan = gpuPlan {
                do {
                    try unpreparedGPUPlan.complete()
                } catch {
                    // Releasing the final local owner invokes the lease's
                    // defensive retry/retention path before debt is inspected.
                }
                gpuPlan = nil
            }
            if let cpuPlan {
                _ = planCache.evictContent(
                    key: cpuPlan.content.key,
                    outputRegion: region
                )
                await gpuPlanCache.invalidate(content: cpuPlan.content)
                try? cpuPlan.retire()
            }
            if await hasCleanupDebt() {
                throw DocumentPaintStableSnapshotRendererError.cleanupPending
            }
            throw error
        }
    }

    private func ensureScratch(
        for region: SparseTileOutputRegion
    ) throws -> Scratch {
        guard region.width <= limits.maximumChunkWidth,
              region.height <= limits.maximumChunkHeight
        else {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        let rowBytes = try DocumentPaintStableSnapshotChunkPlanner
            .alignedReadbackBytesPerRow(width: region.width)
        let (readbackBytes, overflow) = rowBytes
            .multipliedReportingOverflow(by: region.height)
        guard !overflow else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        guard readbackBytes <= device.maxBufferLength else {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        if let scratch,
           scratch.width == region.width,
           scratch.height == region.height,
           scratch.alignedBytesPerRow == rowBytes {
            return scratch
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.interchangePixelFormat,
            width: region.width,
            height: region.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget]
        let targetAllocationBytes = device
            .heapTextureSizeAndAlign(descriptor: descriptor).size
        let (combinedScratchBytes, combinedOverflow) = targetAllocationBytes
            .addingReportingOverflow(readbackBytes)
        guard !combinedOverflow,
              combinedScratchBytes <= limits.maximumScratchBytes
        else {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        #if DEBUG
        if testingHooks?.shouldFailAtPhase?(.scratchAllocation) == true {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        #endif
        scratch = nil
        #if DEBUG
        if testingHooks?.shouldFailAtPhase?(.targetAllocation) == true {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        #endif
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        #if DEBUG
        if testingHooks?.shouldFailAtPhase?(.readbackAllocation) == true {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        #endif
        guard let readback = device.makeBuffer(
            length: readbackBytes,
            options: .storageModeShared
        ) else {
            throw DocumentPaintStableSnapshotAdaptiveCapacityError.scratch
        }
        increment(&metrics.targetAllocationCount)
        increment(&metrics.readbackAllocationCount)
        let result = Scratch(
            target: target,
            readback: readback,
            width: region.width,
            height: region.height,
            alignedBytesPerRow: rowBytes,
            targetByteCount: targetAllocationBytes,
            readbackByteCount: readbackBytes
        )
        scratch = result
        return result
    }

    private func encodeReadback(
        commandBuffer: any MTLCommandBuffer,
        scratch: Scratch,
        region: SparseTileOutputRegion
    ) throws {
        #if DEBUG
        if testingHooks?.shouldFailAtPhase?(.readbackEncoding) == true {
            throw DocumentPaintStableSnapshotRendererError
                .readbackEncodingFailed
        }
        #endif
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw DocumentPaintStableSnapshotRendererError
                .readbackEncodingFailed
        }
        blit.copy(
            from: scratch.target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: region.width,
                height: region.height,
                depth: 1
            ),
            to: scratch.readback,
            destinationOffset: 0,
            destinationBytesPerRow: scratch.alignedBytesPerRow,
            destinationBytesPerImage: scratch.readbackByteCount
        )
        blit.endEncoding()
    }

    private func makeChunk(
        region: SparseTileOutputRegion,
        scratch: Scratch
    ) throws -> DocumentPaintStableSnapshotChunk {
        let tightRowBytes = try DocumentPaintStableSnapshotChunkPlanner
            .checkedOutputByteCount(try SparseTileOutputRegion(
                minX: 0,
                minY: 0,
                maxX: region.width,
                maxY: 1
            ))
        let byteCount = try DocumentPaintStableSnapshotChunkPlanner
            .checkedOutputByteCount(region)
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            let sourceBase = scratch.readback.contents()
            for row in 0..<region.height {
                memcpy(
                    destinationBase.advanced(by: row * tightRowBytes),
                    sourceBase.advanced(
                        by: row * scratch.alignedBytesPerRow
                    ),
                    tightRowBytes
                )
            }
        }
        return DocumentPaintStableSnapshotChunk(
            outputRegion: region,
            bytesPerRow: tightRowBytes,
            bytes: data
        )
    }

    private func ensureMayContinue() throws {
        if shutdownRequested {
            throw DocumentPaintStableSnapshotRendererError.shutDown
        }
        try Task.checkCancellation()
    }

    /// Sink callbacks may spawn child tasks which inherit the task-local token.
    /// The active count limits rejection to the callback's actual await scope,
    /// so an inherited child may shut this renderer down after the callback has
    /// returned while unrelated renderers are never blocked.
    private func invokeSink<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let (nextCount, overflow) = activeSinkInvocationCount
            .addingReportingOverflow(1)
        precondition(!overflow, "sink invocation count overflow")
        activeSinkInvocationCount = nextCount
        defer {
            precondition(activeSinkInvocationCount > 0)
            activeSinkInvocationCount -= 1
        }
        var tokens = DocumentPaintStableSnapshotSinkInvocation.tokens
        tokens.append(sinkInvocationToken)
        return try await DocumentPaintStableSnapshotSinkInvocation.$tokens
            .withValue(tokens) {
                try await operation()
            }
    }

    private func isAdaptiveCapacityError(_ error: any Error) -> Bool {
        if error is DocumentPaintStableSnapshotAdaptiveCapacityError {
            return true
        }
        if case DocumentPaintStableCanonicalSnapshotError
            .selectedReferenceLimitExceeded = error {
            return true
        }
        if let error = error as? SparseTileSamplingPlanError {
            switch error {
            case .pageEntryLimitExceeded,
                 .pageChunkLimitExceeded,
                 .pageTableByteLimitExceeded,
                 .bindingSlotLimitExceeded,
                 .bindingChunkLimitExceeded,
                 .bindingByteLimitExceeded,
                 .batchLimitExceeded,
                 .onePixelBatchExceedsTextureLimit:
                return true
            default: return false
            }
        }
        if case SparseTileSamplingPipelineError.limitExceeded = error {
            return true
        }
        if case SparseTileSamplingPipelineError
            .proportionalBufferCreationFailed = error {
            return true
        }
        if case PaintTileResidencyError.insufficientCapacity = error {
            return true
        }
        return false
    }

    private func settleLifecycleAfterOperation() async {
        let hasDebt = await hasCleanupDebt()
        if shutdownRequested {
            if hasDebt {
                lifecycle = .cleaning
                completeShutdown(cleaned: await performBoundedCleanup())
            } else {
                completeShutdown(cleaned: true)
            }
        } else if hasDebt {
            lifecycle = .cleanupPending
        } else {
            lifecycle = .active
        }
    }

    private func performBoundedCleanup() async -> Bool {
        for _ in 0..<limits.maximumRetryCleanupPasses {
            #if DEBUG
            await testingHooks?.beforeCleanupRetryPass?()
            #endif
            increment(&metrics.cleanupRetryPassCount)
            try? planCache.retryPendingRetirements()
            _ = await gpuPlanCache.retryPendingPlanCompletions()
            try? planCache.retryPendingRetirements()
            _ = await gpuPlanCache.retryPendingPlanCompletions()
            if await !hasCleanupDebt() { return true }
        }
        return false
    }

    private func completeShutdown(cleaned: Bool) {
        lifecycle = cleaned ? .shutDown : .cleanupPending
        if cleaned { scratch = nil }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            if cleaned {
                waiter.resume()
            } else {
                waiter.resume(
                    throwing: DocumentPaintStableSnapshotRendererError
                        .cleanupPending
                )
            }
        }
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


    private static func dedicatedGPULimits(
        planLimits: SparseTilePlanLimits
    ) -> SparseTileSamplingGPUPlanLimits {
        SparseTileSamplingGPUPlanLimits(
            maximumDescriptors: 3,
            maximumPageEntries: planLimits.maximumPageEntries,
            maximumBufferBytes: min(
                planLimits.maximumPageTableBytes,
                64 * 1_024 * 1_024
            ),
            maximumInflightEncodes: 1,
            maximumCachedPlans: 1,
            maximumCachedBufferBytes: 64 * 1_024 * 1_024
        )
    }

    private func incremented(_ value: Int) throws -> Int {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw DocumentPaintStableSnapshotRendererError.arithmeticOverflow
        }
        return next
    }

    private func increment(_ value: inout UInt64) {
        precondition(value < UInt64.max, "stable snapshot metric overflow")
        value += 1
    }

    private func add(_ amount: UInt64, to value: inout UInt64) {
        let (result, overflow) = value.addingReportingOverflow(amount)
        precondition(!overflow, "stable snapshot metric overflow")
        value = result
    }
}
