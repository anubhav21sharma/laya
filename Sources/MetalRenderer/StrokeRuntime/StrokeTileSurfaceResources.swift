import CShaderTypes
import Foundation
import Metal
import PatternEngine

enum StrokeTileFailureInjectionSeam: UInt8, CaseIterable, Sendable {
    case beforePartition
    case afterPartition
    case afterReservation
    case beforeCommandEncoding
    case afterCommandCompletion
    case beforeLeasePublication
}

struct StrokeTileFailureInjection: Sendable {
    let seam: StrokeTileFailureInjectionSeam

    func callAsFunction(_ observed: StrokeTileFailureInjectionSeam) throws {
        if observed == seam {
            throw StrokeTileSurfaceError.injectedFailure(seam)
        }
    }
}

enum StrokeTileSurfaceError: Error, Equatable, Sendable {
    case invalidPipelinePixelFormat(expected: UInt, actual: UInt)
    case invalidComponentBindingOrdinal(expected: UInt8, actual: UInt8)
    case componentBindingUnavailable(UInt8)
    case invalidCapacity
    case recordBudgetExceeded(required: Int, maximum: Int)
    case tileBudgetExceeded(required: Int, maximum: Int)
    case tileReferenceBudgetExceeded(required: Int, maximum: Int)
    case arithmeticOverflow
    case missingRadialPage(RadialPageCoordinate)
    case commandQueueUnavailable
    case uploadBufferAllocationFailed
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)
    case raster(DocumentPaintStrokeSurfaceError)
    case leaseTokenOverflow
    case outstandingLease
    case emptyCommitMutation
    case terminallySealed
    case staleLease
    case wrongGeneration(expected: UInt64, actual: UInt64)
    case wrongLayer(expected: UUID, actual: UUID)
    case duplicateSurfaceNamespace(UUID)
    case unauthenticatedSurfaceNamespace
    case injectedFailure(StrokeTileFailureInjectionSeam)
}

struct StrokeTilePartitionInput: Equatable, Sendable {
    let recordIndex: Int
    let supportBounds: PixelRect
    let radialPage: RadialPageCoordinate?

    init(
        recordIndex: Int,
        supportBounds: PixelRect,
        radialPage: RadialPageCoordinate? = nil
    ) {
        self.recordIndex = recordIndex
        self.supportBounds = supportBounds
        self.radialPage = radialPage
    }
}

struct StrokeTileRecordRange: Equatable, Sendable {
    let role: StrokePrivateSurfaceLayer
    let physicalCoordinate: PaintTileCoordinate
    let logicalOrigin: SIMD2<Int>
    let atlasOrigin: SIMD2<Int>
    let recordRange: Range<Int>
    let shouldClear: Bool
}

private struct StrokeTilePartitionReference: Equatable, Sendable {
    let coordinate: PaintTileCoordinate
    let recordIndex: Int
    let logicalOrigin: SIMD2<Int>
    let atlasOrigin: SIMD2<Int>
}

/// Caller-owned, fixed-capacity partition workspace. Sorting is stable insertion
/// sorting so a warmed call does not allocate hidden comparison buffers.
struct StrokeTilePartitionScratch: Sendable {
    let maximumRecordCount: Int
    let maximumTileReferenceCount: Int
    let maximumTileCount: Int
    private var references: [StrokeTilePartitionReference] = []
    private var radixScratch: [StrokeTilePartitionReference] = []
    private var radixCounts: [Int] = Array(repeating: 0, count: 256)
    private(set) var recordReferences: [Int] = []
    private(set) var ranges: [StrokeTileRecordRange] = []
    private(set) var lastSortPassCount = 0

    init(
        maximumRecordCount: Int,
        maximumTileReferenceCount: Int,
        maximumTileCount: Int
    ) {
        precondition(maximumRecordCount > 0)
        precondition(maximumTileReferenceCount > 0)
        precondition(maximumTileCount > 0)
        self.maximumRecordCount = maximumRecordCount
        self.maximumTileReferenceCount = maximumTileReferenceCount
        self.maximumTileCount = maximumTileCount
        references.reserveCapacity(maximumTileReferenceCount)
        radixScratch.reserveCapacity(maximumTileReferenceCount)
        recordReferences.reserveCapacity(maximumTileReferenceCount)
        ranges.reserveCapacity(maximumTileCount)
    }

    mutating func partition(
        _ inputs: [StrokeTilePartitionInput],
        pixelSize: PixelSize,
        role: StrokePrivateSurfaceLayer,
        radialLayout: RadialSectorLayout? = nil,
        shouldClear: Bool = false
    ) throws -> [StrokeTileRecordRange] {
        reset()
        do {
            guard inputs.count <= maximumRecordCount else {
                throw StrokeTileSurfaceError.recordBudgetExceeded(
                    required: inputs.count,
                    maximum: maximumRecordCount
                )
            }
            for input in inputs {
                if let pageCoordinate = input.radialPage {
                    guard let radialLayout,
                          let page = radialLayout.residentPage(
                              at: pageCoordinate
                          )
                    else {
                        throw StrokeTileSurfaceError.missingRadialPage(
                            pageCoordinate
                        )
                    }
                    let side = PaintTileDescriptor.side
                    let logicalOrigin = SIMD2(
                        page.coordinate.x * side,
                        page.coordinate.y * side
                    )
                    let coordinate = PaintTileCoordinate(
                        x: page.atlasSlot % radialLayout.atlasColumns,
                        y: page.atlasSlot / radialLayout.atlasColumns
                    )
                    let atlasOrigin = SIMD2(
                        coordinate.x * side,
                        coordinate.y * side
                    )
                    // Projected radial instances and their support bounds are
                    // expressed in packed-atlas coordinates. The logical page
                    // identity selects the resident slot, but must not be used
                    // as the raster-space intersection origin.
                    guard input.supportBounds.clipped(
                        toPageAt: atlasOrigin,
                        side: side
                    ) != nil else { continue }
                    try appendReference(
                        coordinate: coordinate,
                        recordIndex: input.recordIndex,
                        logicalOrigin: logicalOrigin,
                        atlasOrigin: atlasOrigin
                    )
                    continue
                }
                guard let clipped = input.supportBounds.clipped(to: pixelSize)
                else { continue }
                let side = PaintTileDescriptor.side
                let firstX = clipped.minX / side
                let lastX = (clipped.maxX - 1) / side
                let firstY = clipped.minY / side
                let lastY = (clipped.maxY - 1) / side
                for y in firstY...lastY {
                    for x in firstX...lastX {
                        let origin = SIMD2(x * side, y * side)
                        try appendReference(
                            coordinate: PaintTileCoordinate(x: x, y: y),
                            recordIndex: input.recordIndex,
                            logicalOrigin: origin,
                            atlasOrigin: origin
                        )
                    }
                }
            }
            sortReferencesInPlace()
            try publishRanges(role: role, shouldClear: shouldClear)
            return ranges
        } catch {
            reset()
            throw error
        }
    }

    mutating func reset() {
        references.removeAll(keepingCapacity: true)
        radixScratch.removeAll(keepingCapacity: true)
        recordReferences.removeAll(keepingCapacity: true)
        ranges.removeAll(keepingCapacity: true)
        lastSortPassCount = 0
    }

    private mutating func appendReference(
        coordinate: PaintTileCoordinate,
        recordIndex: Int,
        logicalOrigin: SIMD2<Int>,
        atlasOrigin: SIMD2<Int>
    ) throws {
        let (required, overflow) = references.count.addingReportingOverflow(1)
        guard !overflow else { throw StrokeTileSurfaceError.arithmeticOverflow }
        guard required <= maximumTileReferenceCount else {
            throw StrokeTileSurfaceError.tileReferenceBudgetExceeded(
                required: required,
                maximum: maximumTileReferenceCount
            )
        }
        references.append(StrokeTilePartitionReference(
            coordinate: coordinate,
            recordIndex: recordIndex,
            logicalOrigin: logicalOrigin,
            atlasOrigin: atlasOrigin
        ))
    }

    private mutating func sortReferencesInPlace() {
        guard references.count > 1 else { return }
        radixScratch.append(contentsOf: references)
        // Stable least-significant-digit passes produce (y, x, record) order.
        // Int components are nonnegative by construction after clipping/page
        // mapping, so their unsigned byte order is their row-major order.
        for component in 0..<3 {
            for byteIndex in 0..<MemoryLayout<UInt>.size {
                for bucket in radixCounts.indices { radixCounts[bucket] = 0 }
                let shift = UInt(byteIndex * 8)
                for reference in references {
                    let value = Self.radixComponent(reference, component)
                    radixCounts[Int((value >> shift) & 0xFF)] += 1
                }
                var running = 0
                for bucket in radixCounts.indices {
                    let count = radixCounts[bucket]
                    radixCounts[bucket] = running
                    running += count
                }
                for reference in references {
                    let value = Self.radixComponent(reference, component)
                    let bucket = Int((value >> shift) & 0xFF)
                    radixScratch[radixCounts[bucket]] = reference
                    radixCounts[bucket] += 1
                }
                swap(&references, &radixScratch)
                lastSortPassCount += 1
            }
        }
    }

    private static func radixComponent(
        _ reference: StrokeTilePartitionReference,
        _ component: Int
    ) -> UInt {
        switch component {
        case 0:
            return UInt(reference.recordIndex)
        case 1:
            return UInt(reference.coordinate.x)
        default:
            return UInt(reference.coordinate.y)
        }
    }

    private mutating func publishRanges(
        role: StrokePrivateSurfaceLayer,
        shouldClear: Bool
    ) throws {
        var index = 0
        while index < references.count {
            let first = references[index]
            let start = recordReferences.count
            var priorRecordIndex: Int?
            while index < references.count,
                  references[index].coordinate == first.coordinate
            {
                let reference = references[index]
                if reference.recordIndex != priorRecordIndex {
                    recordReferences.append(reference.recordIndex)
                    priorRecordIndex = reference.recordIndex
                }
                index += 1
            }
            let (tileCount, overflow) = ranges.count.addingReportingOverflow(1)
            guard !overflow else { throw StrokeTileSurfaceError.arithmeticOverflow }
            guard tileCount <= maximumTileCount else {
                throw StrokeTileSurfaceError.tileBudgetExceeded(
                    required: tileCount,
                    maximum: maximumTileCount
                )
            }
            ranges.append(StrokeTileRecordRange(
                role: role,
                physicalCoordinate: first.coordinate,
                logicalOrigin: first.logicalOrigin,
                atlasOrigin: first.atlasOrigin,
                recordRange: start..<recordReferences.count,
                shouldClear: shouldClear
            ))
        }
    }
}

private extension PixelRect {
    func clipped(
        toPageAt origin: SIMD2<Int>,
        side: Int
    ) -> PixelRect? {
        let (maxX, overflowX) = origin.x.addingReportingOverflow(side)
        let (maxY, overflowY) = origin.y.addingReportingOverflow(side)
        guard !overflowX, !overflowY else { return nil }
        return PixelRect(
            minX: max(minX, origin.x),
            minY: max(minY, origin.y),
            maxX: min(self.maxX, maxX),
            maxY: min(self.maxY, maxY)
        )
    }
}

struct StrokeTileSurfaceResourceSnapshot: Equatable, Sendable {
    let residentTileCount: Int
    let activeLeaseCount: Int
    let residentByteCount: Int
    let fullCanvasTextureCount: Int
}


/// Sparse, borrowed-store resources for the opt-in Task 5 renderer seam.
final class StrokeTileSurfaceResources: @unchecked Sendable {
    nonisolated let identity = UUID()
    let pixelSize: PixelSize
    let layerID: UUID
    let generation: UInt64
    let maximumRecordCount: Int
    let maximumTileReferenceCount: Int
    let capability: DocumentPaintStrokeSurfaceCapability
    fileprivate let commandQueue: any MTLCommandQueue
    fileprivate let uploadBuffer: any MTLBuffer
    fileprivate let depositionPassDescriptor: MTLRenderPassDescriptor

    var snapshot: StrokeTileSurfaceResourceSnapshot {
        capability.snapshot
    }

    @MainActor
    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        capability: DocumentPaintStrokeSurfaceCapability,
        maximumRecordCount: Int,
        maximumTileReferenceCount: Int
    ) throws {
        guard maximumRecordCount > 0, maximumTileReferenceCount > 0 else {
            throw StrokeTileSurfaceError.invalidCapacity
        }
        guard (commandQueue.device as AnyObject) === (device as AnyObject)
        else { throw StrokeTileSurfaceError.commandQueueUnavailable }
        let (uploadLength, overflow) = maximumTileReferenceCount
            .multipliedReportingOverflow(
                by: MemoryLayout<PatternDepositionStampInstance>.stride
            )
        guard !overflow, uploadLength > 0,
              let uploadBuffer = device.makeBuffer(
                  length: uploadLength,
                  options: .storageModeShared
              ) else {
            throw StrokeTileSurfaceError.uploadBufferAllocationFailed
        }
        pixelSize = capability.pixelSize
        layerID = capability.layerID
        generation = capability.generation
        self.maximumRecordCount = maximumRecordCount
        self.maximumTileReferenceCount = maximumTileReferenceCount
        self.capability = capability
        self.commandQueue = commandQueue
        self.uploadBuffer = uploadBuffer
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].storeAction = .store
        depositionPassDescriptor = pass
        commandQueue.label = "Off-main Sparse Stroke Preparation"
        uploadBuffer.label = "Off-main Sparse Stroke Instances"
    }

}

struct StrokeTileComponentEncodingBinding: @unchecked Sendable {
    let ordinal: UInt8
    let pipeline: DepositionPipelineBinding
    let materialUniforms: PatternDepositionMaterialUniforms
    let primaryShape: (any MTLTexture)?
    let secondaryShape: (any MTLTexture)?
    let primaryGrain: (any MTLTexture)?
    let secondaryGrain: (any MTLTexture)?

    @MainActor
    init(
        ordinal: UInt8,
        pipeline: DepositionPipelineBinding,
        material: DepositionMaterialBinding
    ) {
        let textures = material.textures
        self.ordinal = ordinal
        self.pipeline = pipeline
        materialUniforms = material.uniforms
        primaryShape = textures[.primaryShape]
        secondaryShape = textures[.secondaryShape]
        primaryGrain = textures[.primaryGrain]
        secondaryGrain = textures[.secondaryGrain]
    }

    init(
        ordinal: UInt8,
        pipeline: DepositionPipelineBinding,
        materialUniforms: PatternDepositionMaterialUniforms,
        primaryShape: (any MTLTexture)?,
        secondaryShape: (any MTLTexture)?,
        primaryGrain: (any MTLTexture)?,
        secondaryGrain: (any MTLTexture)?
    ) {
        self.ordinal = ordinal
        self.pipeline = pipeline
        self.materialUniforms = materialUniforms
        self.primaryShape = primaryShape
        self.secondaryShape = secondaryShape
        self.primaryGrain = primaryGrain
        self.secondaryGrain = secondaryGrain
    }
}

struct StrokeTileEncodingConfiguration: @unchecked Sendable {
    let resources: StrokeTileSurfaceResources
    let primaryComponent: StrokeTileComponentEncodingBinding
    let secondaryComponent: StrokeTileComponentEncodingBinding?
    let frameUniforms: PatternGridFrameUniforms
    let radialLayout: RadialSectorLayout?
    let forceCommandFailure: Bool
    let tileAllocationFailureInjection: PaintTileAllocationFailureInjection?
    let failureInjection: StrokeTileFailureInjection?

    init(
        resources: StrokeTileSurfaceResources,
        primaryComponent: StrokeTileComponentEncodingBinding,
        secondaryComponent: StrokeTileComponentEncodingBinding?,
        frameUniforms: PatternGridFrameUniforms,
        radialLayout: RadialSectorLayout?,
        forceCommandFailure: Bool,
        tileAllocationFailureInjection:
            PaintTileAllocationFailureInjection? = nil,
        failureInjection: StrokeTileFailureInjection? = nil
    ) {
        self.resources = resources
        self.primaryComponent = primaryComponent
        self.secondaryComponent = secondaryComponent
        self.frameUniforms = frameUniforms
        self.radialLayout = radialLayout
        self.forceCommandFailure = forceCommandFailure
        self.tileAllocationFailureInjection = tileAllocationFailureInjection
        self.failureInjection = failureInjection
    }

    init(
        resources: StrokeTileSurfaceResources,
        pipeline: DepositionPipelineBinding,
        materialUniforms: PatternDepositionMaterialUniforms,
        primaryShape: (any MTLTexture)?,
        secondaryShape: (any MTLTexture)?,
        primaryGrain: (any MTLTexture)?,
        secondaryGrain: (any MTLTexture)?,
        frameUniforms: PatternGridFrameUniforms,
        radialLayout: RadialSectorLayout?,
        forceCommandFailure: Bool,
        tileAllocationFailureInjection:
            PaintTileAllocationFailureInjection? = nil,
        failureInjection: StrokeTileFailureInjection? = nil
    ) {
        self.init(
            resources: resources,
            primaryComponent: StrokeTileComponentEncodingBinding(
                ordinal: 0,
                pipeline: pipeline,
                materialUniforms: materialUniforms,
                primaryShape: primaryShape,
                secondaryShape: secondaryShape,
                primaryGrain: primaryGrain,
                secondaryGrain: secondaryGrain
            ),
            secondaryComponent: nil,
            frameUniforms: frameUniforms,
            radialLayout: radialLayout,
            forceCommandFailure: forceCommandFailure,
            tileAllocationFailureInjection: tileAllocationFailureInjection,
            failureInjection: failureInjection
        )
    }
}

struct StrokePreparedTileBinding: @unchecked Sendable {
    let role: StrokePrivateSurfaceLayer
    let identity: PaintTileIdentity
    let descriptor: PaintTileDescriptor
    let texture: any MTLTexture
}

/// Fixed storage plus a fixed open-address index. New coordinates append one
/// immutable chunk; later writes publish into a different free slot before the
/// prior generation is recycled. The index keeps publication O(changed tiles)
/// even for a maximum-size stroke.
private final class StrokeTileBindingChunkArena: @unchecked Sendable {
    private var chunks: [StrokePreparedTileBinding?]
    private var indexKeys: [PaintTileCoordinate?]
    private var indexValues: [Int]
    private let logicalCapacity: Int
    private var nextFreeChunkIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0 && capacity <= Int.max / 2)
        logicalCapacity = capacity
        // One inactive slot per visible coordinate lets a replacement publish
        // a new immutable chunk before the prior generation is recycled.
        chunks = Array(repeating: nil, count: capacity * 2)
        var indexCapacity = 1
        let minimumIndexCapacity = capacity * 2
        while indexCapacity < minimumIndexCapacity {
            precondition(indexCapacity <= Int.max / 2)
            indexCapacity *= 2
        }
        indexKeys = Array(repeating: nil, count: indexCapacity)
        indexValues = Array(repeating: -1, count: indexCapacity)
    }

    var capacity: Int { logicalCapacity }

    func reset() {
        for index in chunks.indices { chunks[index] = nil }
        for index in indexKeys.indices {
            indexKeys[index] = nil
            indexValues[index] = -1
        }
        nextFreeChunkIndex = 0
        count = 0
    }

    func install(_ binding: StrokePreparedTileBinding) -> Int {
        let coordinate = binding.descriptor.coordinate
        if let indexSlot = indexSlot(for: coordinate) {
            let oldChunkIndex = indexValues[indexSlot]
            let replacementIndex = freeChunkIndex()
            chunks[replacementIndex] = binding
            indexValues[indexSlot] = replacementIndex
            chunks[oldChunkIndex] = nil
            return replacementIndex
        }
        precondition(count < logicalCapacity, "Chunk capacity was preflighted")
        let chunkIndex = freeChunkIndex()
        chunks[chunkIndex] = binding
        count += 1
        insertIndex(coordinate: coordinate, chunkIndex: chunkIndex)
        return chunkIndex
    }

    func binding(at index: Int) -> StrokePreparedTileBinding? {
        guard index >= 0, index < chunks.count else { return nil }
        return chunks[index]
    }

    func snapshot() -> [StrokePreparedTileBinding] {
        var result: [StrokePreparedTileBinding] = []
        result.reserveCapacity(count)
        for index in chunks.indices {
            if let binding = chunks[index] { result.append(binding) }
        }
        result.sort { $0.descriptor.coordinate < $1.descriptor.coordinate }
        return result
    }

    private func indexSlot(for coordinate: PaintTileCoordinate) -> Int? {
        var index = hashIndex(for: coordinate)
        while let key = indexKeys[index] {
            if key == coordinate { return index }
            index = (index + 1) & (indexKeys.count - 1)
        }
        return nil
    }

    private func freeChunkIndex() -> Int {
        for offset in chunks.indices {
            let index = (nextFreeChunkIndex + offset) % chunks.count
            if chunks[index] == nil {
                nextFreeChunkIndex = (index + 1) % chunks.count
                return index
            }
        }
        preconditionFailure("Immutable chunk replacement capacity exhausted")
    }

    private func insertIndex(
        coordinate: PaintTileCoordinate,
        chunkIndex: Int
    ) {
        var index = hashIndex(for: coordinate)
        while indexKeys[index] != nil {
            index = (index + 1) & (indexKeys.count - 1)
        }
        indexKeys[index] = coordinate
        indexValues[index] = chunkIndex
    }

    private func hashIndex(for coordinate: PaintTileCoordinate) -> Int {
        var value = UInt(bitPattern: coordinate.x)
            &* 0x9E3779B185EBCA87
        value ^= UInt(bitPattern: coordinate.y)
            &* 0xC2B2AE3D27D4EB4F
        value ^= value >> 33
        return Int(value & UInt(indexKeys.count - 1))
    }
}

final class StrokeTilePublicationSlot: @unchecked Sendable {
    /// Stable, fixed-capacity chunk storage. A newly touched tile either
    /// appends one chunk or publishes a replacement into a free version slot. The
    /// per-frame publication stores only chunk indices, so unchanged history
    /// is neither recopied nor exposed to mutation while Main owns the lease.
    private let authoritativeArena: StrokeTileBindingChunkArena
    private let predictionArena: StrokeTileBindingChunkArena
    private var publishedChunkIndices: [Int?]
    private var deltaCoordinates: [PaintTileCoordinate?]
    private(set) var publishedChunkCount = 0
    private(set) var deltaCount = 0
    private(set) var version: UInt64 = 0
    private(set) var isOutstanding = false
    private var publishedRole: StrokePrivateSurfaceLayer = .authoritative

    init(capacity: Int) {
        precondition(capacity > 0)
        authoritativeArena = StrokeTileBindingChunkArena(capacity: capacity)
        predictionArena = StrokeTileBindingChunkArena(capacity: capacity)
        publishedChunkIndices = Array(repeating: nil, count: capacity)
        deltaCoordinates = Array(repeating: nil, count: capacity)
    }

    func preflightPublish(
        role: StrokePrivateSurfaceLayer,
        touchedCoordinates: [PaintTileCoordinate],
        newBindingCount: Int,
        deltaCount: Int,
        replacesVisibleLayer: Bool
    ) throws -> UInt64 {
        guard !isOutstanding,
              touchedCoordinates.count <= publishedChunkIndices.count,
              deltaCount <= deltaCoordinates.count
        else { throw StrokeTileSurfaceError.outstandingLease }
        let arena = role == .authoritative
            ? authoritativeArena : predictionArena
        let (appendedCount, overflow) = arena.count.addingReportingOverflow(
            newBindingCount
        )
        guard !overflow else { throw StrokeTileSurfaceError.arithmeticOverflow }
        let required = replacesVisibleLayer
            ? touchedCoordinates.count : appendedCount
        guard required <= arena.capacity else {
            throw StrokeTileSurfaceError.tileBudgetExceeded(
                required: required,
                maximum: arena.capacity
            )
        }
        let (successor, versionOverflow) = version.addingReportingOverflow(1)
        guard !versionOverflow else {
            throw StrokeTileSurfaceError.leaseTokenOverflow
        }
        return successor
    }

    func publishPreflighted(
        version successor: UInt64,
        role: StrokePrivateSurfaceLayer,
        provisionalBindings: DocumentPaintStrokeProvisionalReservation?,
        touchedCoordinates: [PaintTileCoordinate],
        bindingDeltaCoordinates: [PaintTileCoordinate],
        replacesVisibleLayer: Bool
    ) {
        precondition(!isOutstanding)
        precondition(touchedCoordinates.count <= publishedChunkIndices.count)
        precondition(bindingDeltaCoordinates.count <= deltaCoordinates.count)
        precondition(successor == version + 1)
        if replacesVisibleLayer {
            switch role {
            case .authoritative:
                authoritativeArena.reset()
            case .prediction:
                predictionArena.reset()
            }
        }
        var outputIndex = 0
        for provisional in provisionalBindings?.bindings ?? [] {
            guard StrokeTileSurfaceEncoder.containsSorted(
                touchedCoordinates,
                provisional.descriptor.coordinate
            ) else { continue }
            precondition(outputIndex < publishedChunkIndices.count)
            let chunk = StrokePreparedTileBinding(
                role: role,
                identity: provisional.identity,
                descriptor: provisional.descriptor,
                texture: provisional.candidateTexture
            )
            let chunkIndex: Int
            switch role {
            case .authoritative:
                chunkIndex = authoritativeArena.install(chunk)
            case .prediction:
                chunkIndex = predictionArena.install(chunk)
            }
            publishedChunkIndices[outputIndex] = chunkIndex
            outputIndex += 1
        }
        if outputIndex < publishedChunkCount {
            for index in outputIndex..<publishedChunkCount {
                publishedChunkIndices[index] = nil
            }
        }
        for index in bindingDeltaCoordinates.indices {
            deltaCoordinates[index] = bindingDeltaCoordinates[index]
        }
        if bindingDeltaCoordinates.count < deltaCount {
            for index in bindingDeltaCoordinates.count..<deltaCount {
                deltaCoordinates[index] = nil
            }
        }
        publishedChunkCount = outputIndex
        deltaCount = bindingDeltaCoordinates.count
        version = successor
        publishedRole = role
        isOutstanding = true
    }

    func release(expectedVersion: UInt64) throws {
        try preflightRelease(expectedVersion: expectedVersion)
        releasePreflighted(expectedVersion: expectedVersion)
    }

    func preflightRelease(expectedVersion: UInt64) throws {
        guard isOutstanding, version == expectedVersion else {
            throw StrokeTileSurfaceError.staleLease
        }
    }

    func releasePreflighted(expectedVersion: UInt64) {
        precondition(isOutstanding && version == expectedVersion)
        isOutstanding = false
    }

    func resetAll() {
        precondition(!isOutstanding)
        authoritativeArena.reset()
        predictionArena.reset()
        for index in publishedChunkIndices.indices {
            publishedChunkIndices[index] = nil
            deltaCoordinates[index] = nil
        }
        publishedChunkCount = 0
        deltaCount = 0
    }

    func bindingSnapshot(expectedVersion: UInt64) -> [StrokePreparedTileBinding] {
        guard isOutstanding, version == expectedVersion else { return [] }
        var result: [StrokePreparedTileBinding] = []
        result.reserveCapacity(publishedChunkCount)
        for chunkIndex in publishedChunkIndices.prefix(publishedChunkCount)
        where chunkIndex != nil {
            guard let chunkIndex else { continue }
            let chunk = publishedRole == .authoritative
                ? authoritativeArena.binding(at: chunkIndex)
                : predictionArena.binding(at: chunkIndex)
            if let chunk { result.append(chunk) }
        }
        return result
    }

    func chunkIndexSnapshot(expectedVersion: UInt64) -> [Int] {
        guard isOutstanding, version == expectedVersion else { return [] }
        return publishedChunkIndices.prefix(publishedChunkCount).compactMap {
            $0
        }
    }

    func wholeVisibleBindingSnapshot(
        role: StrokePrivateSurfaceLayer
    ) -> [StrokePreparedTileBinding] {
        (role == .authoritative ? authoritativeArena : predictionArena)
            .snapshot()
    }

    var visibleChunkCount: Int {
        authoritativeArena.count + predictionArena.count
    }

    func coordinateSnapshot(expectedVersion: UInt64) -> [PaintTileCoordinate] {
        guard isOutstanding, version == expectedVersion else { return [] }
        return deltaCoordinates.prefix(deltaCount).compactMap { $0 }
    }

}

struct StrokeTileSurfaceLeaseBacking: @unchecked Sendable {
    let resources: StrokeTileSurfaceResources
    let authoritativeReservation: DocumentPaintStrokeFrameReservation?
    let predictionReservation: DocumentPaintStrokeFrameReservation?
    private let publicationSlot: StrokeTilePublicationSlot
    private let publicationVersion: UInt64
    let layerID: UUID

    init(
        resources: StrokeTileSurfaceResources,
        authoritativeReservation: DocumentPaintStrokeFrameReservation?,
        predictionReservation: DocumentPaintStrokeFrameReservation?,
        publicationSlot: StrokeTilePublicationSlot,
        publicationVersion: UInt64,
        layerID: UUID
    ) {
        self.resources = resources
        self.authoritativeReservation = authoritativeReservation
        self.predictionReservation = predictionReservation
        self.publicationSlot = publicationSlot
        self.publicationVersion = publicationVersion
        self.layerID = layerID
    }

    var bindingDeltaCoordinates: [PaintTileCoordinate] {
        publicationSlot.coordinateSnapshot(expectedVersion: publicationVersion)
    }

    /// Test-only whole-visible inspection. The actor handoff itself retains
    /// only the changed immutable chunk. Historical visible chunks stay in the
    /// encoder arena and are never recopied into a per-frame handoff.
    var visibleBindings: [StrokePreparedTileBinding] {
        publicationSlot.bindingSnapshot(expectedVersion: publicationVersion)
    }

    var debugPublishedChunkIndices: [Int] {
        publicationSlot.chunkIndexSnapshot(expectedVersion: publicationVersion)
    }

    func wholeVisibleBindings(
        role: StrokePrivateSurfaceLayer
    ) -> [StrokePreparedTileBinding] {
        publicationSlot.wholeVisibleBindingSnapshot(role: role)
    }

    func releasePublication() throws {
        try publicationSlot.release(expectedVersion: publicationVersion)
    }

    func preflightReleasePublication() throws {
        try publicationSlot.preflightRelease(
            expectedVersion: publicationVersion
        )
    }

    func releasePublicationPreflighted() {
        publicationSlot.releasePreflighted(
            expectedVersion: publicationVersion
        )
    }

    func matchesPublication(_ other: StrokeTileSurfaceLeaseBacking) -> Bool {
        publicationSlot === other.publicationSlot
            && publicationVersion == other.publicationVersion
    }
}

struct StrokeTileSurfaceEncoderSnapshot: Equatable, Sendable {
    let authoritativeVisibleTileCount: Int
    let predictionVisibleTileCount: Int
    let bindingChunkCount: Int
    let tileReferenceHighWater: Int
    let residentTileHighWater: Int
    let hasOutstandingLease: Bool
    let hasOutstandingCommitMutationLease: Bool
    let isTerminallySealed: Bool
    let retainedLeaseWorkspaceBindingCount: Int
    let retainedProvisionalBindingCount: Int
}

enum StrokeTileFrameDisposition: Equatable, Sendable {
    case unpublished
    case mainOwnsLease
}

private struct StrokeTileCommandOutcome: Sendable {
    let succeeded: Bool
    let message: String?
}

/// Encodes current sparse private RGBA16F stroke tiles and publishes exact
/// store leases.
final class StrokeTileSurfaceEncoder: @unchecked Sendable {
    var snapshot: StrokeTileSurfaceEncoderSnapshot {
        StrokeTileSurfaceEncoderSnapshot(
            authoritativeVisibleTileCount: authoritativeCoordinates.count,
            predictionVisibleTileCount:
                predictionReplacement.visibleCoordinates.count,
            bindingChunkCount: publicationSlot?.visibleChunkCount ?? 0,
            tileReferenceHighWater: tileReferenceHighWater,
            residentTileHighWater: residentTileHighWater,
            hasOutstandingLease: outstandingLease != nil,
            hasOutstandingCommitMutationLease: false,
            isTerminallySealed: isTerminallySealed,
            retainedLeaseWorkspaceBindingCount:
                (authoritativeLeaseWorkspace?.retainedBindingCount ?? 0)
                    + (predictionLeaseWorkspace?.retainedBindingCount ?? 0),
            retainedProvisionalBindingCount:
                provisionalWorkspace?.retainedBindingCount ?? 0
        )
    }

    private var configuration: StrokeTileEncodingConfiguration?
    private var configuredGeneration: UInt64?
    private var partitionScratch: StrokeTilePartitionScratch?
    private var partitionInputs: [StrokeTilePartitionInput] = []
    private var predictionReplacement = PredictionTileReplacementState(
        maximumTileCount: 1
    )
    private var predictionReplacementPending = false
    private var authoritativeCoordinates: [PaintTileCoordinate] = []
    private var candidateRoleCoordinates: [PaintTileCoordinate] = []
    private var touchedCoordinates: [PaintTileCoordinate] = []
    private var clearOnlyCoordinates: [PaintTileCoordinate] = []
    private var bindingDeltaCoordinates: [PaintTileCoordinate] = []
    private var newCoordinates: [PaintTileCoordinate] = []
    private var publicationSlot: StrokeTilePublicationSlot?
    private var authoritativeLeaseWorkspace:
        PaintTileStrokeLeaseWorkspace?
    private var predictionLeaseWorkspace:
        PaintTileStrokeLeaseWorkspace?
    private var provisionalWorkspace: PaintTileProvisionalWorkspace?
    private var nextLeaseToken: UInt64 = 1
    private let tileLeasePinReasons: [PaintTilePinReason] = [
        .visible, .inFlight,
    ]
    private var outstandingLease: StrokePreparedSurfaceLease?
    private var isTerminallySealed = false
    private var retirementRequested = false
    private var tileReferenceHighWater = 0
    private var residentTileHighWater = 0

    init() {}

    func configure(
        _ configuration: StrokeTileEncodingConfiguration,
        generation: UInt64
    ) throws {
        guard !isTerminallySealed else {
            throw StrokeTileSurfaceError.terminallySealed
        }
        guard outstandingLease == nil else {
            throw StrokeTileSurfaceError.outstandingLease
        }
        guard configuration.resources.generation == generation else {
            throw StrokeTileSurfaceError.wrongGeneration(
                expected: configuration.resources.generation,
                actual: generation
            )
        }
        try Self.validateComponentBindings(configuration)
        self.configuration = configuration
        configuredGeneration = generation
        partitionScratch = StrokeTilePartitionScratch(
            maximumRecordCount:
                configuration.resources.maximumRecordCount,
            maximumTileReferenceCount:
                configuration.resources.maximumTileReferenceCount,
            maximumTileCount:
                configuration.resources.maximumTileReferenceCount
        )
        partitionInputs.removeAll(keepingCapacity: true)
        partitionInputs.reserveCapacity(
            configuration.resources.maximumRecordCount
        )
        predictionReplacement = PredictionTileReplacementState(
            maximumTileCount:
                configuration.resources.maximumTileReferenceCount
        )
        authoritativeCoordinates.removeAll(keepingCapacity: true)
        authoritativeCoordinates.reserveCapacity(
            configuration.resources.maximumTileReferenceCount
        )
        candidateRoleCoordinates.removeAll(keepingCapacity: true)
        touchedCoordinates.removeAll(keepingCapacity: true)
        clearOnlyCoordinates.removeAll(keepingCapacity: true)
        bindingDeltaCoordinates.removeAll(keepingCapacity: true)
        newCoordinates.removeAll(keepingCapacity: true)
        candidateRoleCoordinates.reserveCapacity(
            configuration.resources.maximumTileReferenceCount
        )
        touchedCoordinates.reserveCapacity(
            configuration.resources.maximumTileReferenceCount
        )
        clearOnlyCoordinates.reserveCapacity(
            configuration.resources.maximumTileReferenceCount
        )
        bindingDeltaCoordinates.reserveCapacity(
            configuration.resources.maximumTileReferenceCount
        )
        newCoordinates.reserveCapacity(
            configuration.resources.maximumTileReferenceCount
        )
        publicationSlot = StrokeTilePublicationSlot(
            capacity: configuration.resources.maximumTileReferenceCount
        )
        authoritativeLeaseWorkspace = PaintTileStrokeLeaseWorkspace(
            maximumBindingCount:
                configuration.resources.maximumTileReferenceCount
        )
        predictionLeaseWorkspace = PaintTileStrokeLeaseWorkspace(
            maximumBindingCount:
                configuration.resources.maximumTileReferenceCount
        )
        provisionalWorkspace = PaintTileProvisionalWorkspace(
            maximumBindingCount:
                configuration.resources.maximumTileReferenceCount
        )
        nextLeaseToken = 1
        predictionReplacementPending = false
        retirementRequested = false
        tileReferenceHighWater = 0
        residentTileHighWater = 0
    }

    @discardableResult
    func beginPredictionReplacement() -> StrokeTileSurfaceError? {
        guard !isTerminallySealed else { return .terminallySealed }
        guard outstandingLease == nil else { return .outstandingLease }
        predictionReplacementPending = true
        return nil
    }

    func encode(
        generation: UInt64,
        records: [StrokePreparedProjectedRecord],
        layer: StrokePrivateSurfaceLayer,
        allocationProbe: StrokePreparationAllocationProbe?
    ) async throws -> StrokePreparedSurfaceLease? {
        var activeProbeStage: StrokePreparationAllocationProbeStage?
        func armProbe(_ stage: StrokePreparationAllocationProbeStage) {
            guard allocationProbe != nil else { return }
            allocationProbe?.arm()
            activeProbeStage = stage
        }
        func finishProbe() {
            guard let stage = activeProbeStage else { return }
            allocationProbe?.disarmAndRecord(stage)
            activeProbeStage = nil
        }
        defer { finishProbe() }
        guard let configuration,
              let configuredGeneration,
              partitionScratch != nil
        else { return nil }
        guard !isTerminallySealed else {
            throw StrokeTileSurfaceError.terminallySealed
        }
        guard generation == configuredGeneration else {
            throw StrokeTileSurfaceError.wrongGeneration(
                expected: configuredGeneration,
                actual: generation
            )
        }
        guard outstandingLease == nil else {
            throw StrokeTileSurfaceError.outstandingLease
        }
        for record in records {
            _ = try Self.componentBinding(
                ordinal: record.componentOrdinal,
                configuration: configuration
            )
        }
        let clearsPrediction = layer == .prediction
            && predictionReplacementPending
        let token = nextLeaseToken
        let (successor, tokenOverflow) = token.addingReportingOverflow(1)
        guard !tokenOverflow else {
            throw StrokeTileSurfaceError.leaseTokenOverflow
        }
        try configuration.failureInjection?(.beforePartition)
        armProbe(.surfaceTilePartition)
        partitionInputs.removeAll(keepingCapacity: true)
        for index in records.indices {
            partitionInputs.append(StrokeTilePartitionInput(
                recordIndex: index,
                supportBounds: records[index].dirtyRect,
                radialPage: records[index].radialPage
            ))
        }
        let ranges: [StrokeTileRecordRange]
        do {
            ranges = try partitionScratch!.partition(
                partitionInputs,
                pixelSize: configuration.resources.pixelSize,
                role: layer,
                radialLayout: configuration.radialLayout,
                shouldClear: clearsPrediction
            )
        } catch {
            finishProbe()
            throw error
        }
        try configuration.failureInjection?(.afterPartition)
        let recordReferences = partitionScratch!.recordReferences
        tileReferenceHighWater = max(
            tileReferenceHighWater,
            recordReferences.count
        )
        touchedCoordinates.removeAll(keepingCapacity: true)
        for range in ranges {
            touchedCoordinates.append(range.physicalCoordinate)
        }
        newCoordinates.removeAll(keepingCapacity: true)
        for coordinate in touchedCoordinates {
            let alreadyVisible = layer == .authoritative
                ? Self.containsSorted(authoritativeCoordinates, coordinate)
                : Self.containsSorted(
                    predictionReplacement.visibleCoordinates,
                    coordinate
                )
            if !alreadyVisible { newCoordinates.append(coordinate) }
        }
        candidateRoleCoordinates.removeAll(keepingCapacity: true)
        if layer == .prediction && predictionReplacementPending {
            try predictionReplacement.beginReplacement(touchedCoordinates)
            candidateRoleCoordinates.append(contentsOf: touchedCoordinates)
        } else if layer == .authoritative {
            try Self.mergeSortedUnique(
                authoritativeCoordinates,
                touchedCoordinates,
                into: &candidateRoleCoordinates,
                maximum: configuration.resources.maximumTileReferenceCount
            )
        } else {
            try Self.mergeSortedUnique(
                predictionReplacement.visibleCoordinates,
                touchedCoordinates,
                into: &candidateRoleCoordinates,
                maximum: configuration.resources.maximumTileReferenceCount
            )
        }
        clearOnlyCoordinates.removeAll(keepingCapacity: true)
        if layer == .prediction && predictionReplacementPending {
            for coordinate in predictionReplacement.priorCoordinatesToClear
            where !Self.containsSorted(touchedCoordinates, coordinate) {
                clearOnlyCoordinates.append(coordinate)
            }
        }
        try Self.mergeSortedUnique(
            touchedCoordinates,
            layer == .prediction && predictionReplacementPending
                ? predictionReplacement.priorCoordinatesToClear : [],
            into: &bindingDeltaCoordinates,
            maximum: configuration.resources.maximumTileReferenceCount
        )
        let authoritativeLeaseCoordinates = layer == .authoritative
            ? bindingDeltaCoordinates : []
        let predictionLeaseCoordinates = layer == .prediction
            ? bindingDeltaCoordinates : []

        // Partitioning owns only the bounded CPU coordinate plan. Tile
        // reservation may allocate Metal resources for a newly encountered
        // namespace and is measured by the resource/store ownership gates,
        // not as application collection work.
        finishProbe()

        var authoritativeLease: DocumentPaintStrokeFrameReservation?
        var predictionLease: DocumentPaintStrokeFrameReservation?
        var provisionalBindings: DocumentPaintStrokeProvisionalReservation?
        var preflightedPublicationVersion: UInt64?
        do {
            if !authoritativeLeaseCoordinates.isEmpty {
                guard let authoritativeLeaseWorkspace else {
                    throw StrokeTileSurfaceError.invalidCapacity
                }
                authoritativeLease = try configuration.resources.capability
                    .reserveStrokeTiles(
                        role: .authoritative,
                        coordinates: authoritativeLeaseCoordinates,
                        pinReasons: tileLeasePinReasons,
                        workspace: authoritativeLeaseWorkspace,
                        failureInjection:
                            configuration.tileAllocationFailureInjection
                    )
            }
            if !predictionLeaseCoordinates.isEmpty {
                guard let predictionLeaseWorkspace else {
                    throw StrokeTileSurfaceError.invalidCapacity
                }
                predictionLease = try configuration.resources.capability
                    .reserveStrokeTiles(
                        role: .prediction,
                        coordinates: predictionLeaseCoordinates,
                        pinReasons: tileLeasePinReasons,
                        workspace: predictionLeaseWorkspace,
                        failureInjection:
                            configuration.tileAllocationFailureInjection
                    )
            }
            let roleLease = layer == .authoritative
                ? authoritativeLease : predictionLease
            if let roleLease, !bindingDeltaCoordinates.isEmpty {
                guard let provisionalWorkspace else {
                    throw StrokeTileSurfaceError.invalidCapacity
                }
                finishProbe()
                armProbe(.surfaceMetalSubmission)
                provisionalBindings = try configuration.resources.capability
                    .makeProvisionalBindings(
                        frame: roleLease,
                        coordinates: bindingDeltaCoordinates,
                        modifiedCoordinates: touchedCoordinates,
                        workspace: provisionalWorkspace
                )
                finishProbe()
            }
            guard let publicationSlot else {
                throw StrokeTileSurfaceError.invalidCapacity
            }
            armProbe(.surfaceTilePartition)
            preflightedPublicationVersion = try publicationSlot.preflightPublish(
                role: layer,
                touchedCoordinates: touchedCoordinates,
                newBindingCount: newCoordinates.count,
                deltaCount: bindingDeltaCoordinates.count,
                replacesVisibleLayer: clearsPrediction
            )
            finishProbe()
            try configuration.failureInjection?(.afterReservation)
            try configuration.failureInjection?(.beforeCommandEncoding)
            try await encodeCommand(
                configuration: configuration,
                records: records,
                ranges: ranges,
                references: recordReferences,
                layer: layer,
                authoritativeLease: authoritativeLease,
                predictionLease: predictionLease,
                provisionalBindings: provisionalBindings,
                coordinatesToClear:
                    layer == .prediction && predictionReplacementPending
                    ? predictionReplacement.priorCoordinatesToClear : [],
                allocationProbe: allocationProbe
            )
            try configuration.failureInjection?(.afterCommandCompletion)
            try configuration.failureInjection?(.beforeLeasePublication)
            armProbe(.surfaceTilePartition)
            if layer == .authoritative,
               let lease = authoritativeLease,
               let provisionalBindings {
                authoritativeLease = try configuration.resources.capability
                    .commitProvisionalBindings(
                        provisionalBindings,
                        frame: lease,
                        modifiedCoordinates: touchedCoordinates,
                        knownClearCoordinates: []
                    )
            } else if layer == .prediction,
                      let lease = predictionLease,
                      let provisionalBindings {
                predictionLease = try configuration.resources.capability
                    .commitProvisionalBindings(
                        provisionalBindings,
                        frame: lease,
                        modifiedCoordinates: touchedCoordinates,
                        knownClearCoordinates: clearOnlyCoordinates
                    )
            }
            finishProbe()
        } catch {
            finishProbe()
            if layer == .prediction && predictionReplacementPending {
                predictionReplacement.rollbackReplacement()
            }
            if let provisionalBindings {
                do {
                    try configuration.resources.capability
                        .cancelProvisionalBindings(provisionalBindings)
                } catch {
                    throw StrokeTileSurfaceError.raster(.wrapping(error))
                }
            }
            do {
                try configuration.resources.capability
                    .releaseFrameReservations(
                        authoritative: authoritativeLease,
                        prediction: predictionLease
                )
            } catch {
                throw StrokeTileSurfaceError.raster(.wrapping(error))
            }
            if let error = error as? StrokeTileSurfaceError { throw error }
            throw StrokeTileSurfaceError.raster(.wrapping(error))
        }

        armProbe(.surfaceTilePartition)
        if layer == .authoritative {
            swap(&authoritativeCoordinates, &candidateRoleCoordinates)
        } else if predictionReplacementPending {
            predictionReplacement.commitReplacement()
            predictionReplacementPending = false
        } else {
            try predictionReplacement.beginReplacement(
                candidateRoleCoordinates
            )
            predictionReplacement.commitReplacement()
        }
        guard let publicationSlot, let publicationVersion =
            preflightedPublicationVersion
        else {
            finishProbe()
            preconditionFailure("Publication was preflighted before commit")
        }
        publicationSlot.publishPreflighted(
            version: publicationVersion,
            role: layer,
            provisionalBindings: provisionalBindings,
            touchedCoordinates: touchedCoordinates,
            bindingDeltaCoordinates: bindingDeltaCoordinates,
            replacesVisibleLayer: clearsPrediction
        )
        if let provisionalBindings {
            try configuration.resources.capability
                .completeProvisionalBindings(provisionalBindings)
        }
        residentTileHighWater = max(
            residentTileHighWater,
            authoritativeCoordinates.count
                + predictionReplacement.visibleCoordinates.count
        )
        finishProbe()
        nextLeaseToken = successor
        armProbe(.surfaceTileLease)
        let backing = StrokeTileSurfaceLeaseBacking(
            resources: configuration.resources,
            authoritativeReservation: authoritativeLease,
            predictionReservation: predictionLease,
            publicationSlot: publicationSlot,
            publicationVersion: publicationVersion,
            layerID: configuration.resources.layerID
        )
        let lease = StrokePreparedSurfaceLease(
            generation: generation,
            token: token,
            layer: layer,
            authoritativeInstanceCount:
                layer == .authoritative ? records.count : 0,
            predictedInstanceCount:
                layer == .prediction ? records.count : 0,
            clearedAuthoritativeSurface: false,
            clearedPredictionSurface: clearsPrediction,
            encodingRanOnMainThread: tileSurfaceEncodingIsOnMainThread(),
            backing: backing,
            newBindingCount: newCoordinates.count
        )
        outstandingLease = lease
        finishProbe()
        return lease
    }

    func acknowledge(_ lease: StrokePreparedSurfaceLease) throws {
        guard let expected = outstandingLease,
              lease.token == expected.token,
              lease.generation == expected.generation,
              lease.layer == expected.layer,
              lease.authoritativeInstanceCount
                == expected.authoritativeInstanceCount,
              lease.predictedInstanceCount == expected.predictedInstanceCount,
              lease.clearedAuthoritativeSurface
                == expected.clearedAuthoritativeSurface,
              lease.clearedPredictionSurface
                == expected.clearedPredictionSurface,
              lease.newBindingCount == expected.newBindingCount,
              lease.generation == configuredGeneration,
              let configuration,
              lease.backing.resources === configuration.resources,
              expected.backing.resources === configuration.resources,
              lease.backing.layerID == configuration.resources.layerID,
              lease.backing.matchesPublication(expected.backing),
              lease.backing.authoritativeReservation?.reservationToken
                == expected.backing.authoritativeReservation?.reservationToken,
              lease.backing.predictionReservation?.reservationToken
                == expected.backing.predictionReservation?.reservationToken
        else { throw StrokeTileSurfaceError.staleLease }
        try expected.backing.preflightReleasePublication()
        try configuration.resources.capability.releaseFrameReservations(
            authoritative: expected.backing.authoritativeReservation,
            prediction: expected.backing.predictionReservation
        )
        expected.backing.releasePublicationPreflighted()
        outstandingLease = nil
        if retirementRequested { try retireGenerationIfPossible() }
    }

    func sealCommitMutationSource() throws
        -> StrokePreparedCommitMutationSource?
    {
        guard !isTerminallySealed else {
            throw StrokeTileSurfaceError.terminallySealed
        }
        guard outstandingLease == nil else {
            throw StrokeTileSurfaceError.outstandingLease
        }
        guard let configuration, configuredGeneration != nil else {
            throw StrokeTileSurfaceError.unauthenticatedSurfaceNamespace
        }
        let result = try configuration.resources.capability
            .issueCommitMutationSource()
        isTerminallySealed = true
        return result
    }

    func acquireCommitMutationSource() throws
        -> StrokePreparedCommitMutationSource
    {
        guard let result = try sealCommitMutationSource() else {
            throw StrokeTileSurfaceError.emptyCommitMutation
        }
        return result
    }

    func returnCommitMutationSource(
        _ lease: StrokePreparedCommitMutationSource
    ) throws {
        try lease.cancelUnclaimed()
        if retirementRequested { try retireGenerationIfPossible() }
    }

    func cancel(
        frameDisposition: StrokeTileFrameDisposition,
        allocationProbe: StrokePreparationAllocationProbe? = nil
    ) throws {
        allocationProbe?.arm()
        var probeIsArmed = allocationProbe != nil
        defer {
            if probeIsArmed {
                allocationProbe?.disarmAndRecord(.surfaceTileLease)
            }
        }
        retirementRequested = true
        if let outstandingLease {
            if frameDisposition == .mainOwnsLease {
                allocationProbe?.disarmAndRecord(.surfaceTileLease)
                probeIsArmed = false
                return
            }
            // Return the unpublished frame first, then retire its namespace.
            // Keeping these as separate measured application operations also
            // keeps driver/ARC cleanup outside the ACK accounting boundary.
            retirementRequested = false
            try acknowledge(outstandingLease)
            allocationProbe?.disarmAndRecord(.surfaceTileLease)
            probeIsArmed = false
            retirementRequested = true
            try retireGenerationIfPossible(allocationProbe: allocationProbe)
            return
        }
        allocationProbe?.disarmAndRecord(.surfaceTileLease)
        probeIsArmed = false
        try retireGenerationIfPossible(allocationProbe: allocationProbe)
    }

    func retireGenerationIfPossible(
        allocationProbe: StrokePreparationAllocationProbe? = nil
    ) throws {
        guard retirementRequested, outstandingLease == nil,
              let configuration else { return }
        allocationProbe?.arm()
        do {
            if !configuration.resources.capability.isTerminal {
                try configuration.resources.capability.cancel(
                    expectedOwnerIdentity:
                        configuration.resources.capability.ownerIdentity
                )
            }
        } catch {
            allocationProbe?.disarmAndRecord(.surfaceTileLease)
            throw error
        }
        publicationSlot?.resetAll()
        authoritativeLeaseWorkspace?.abandonReservation()
        predictionLeaseWorkspace?.abandonReservation()
        provisionalWorkspace?.clear()
        self.configuration = nil
        configuredGeneration = nil
        isTerminallySealed = false
        retirementRequested = false
        allocationProbe?.disarmAndRecord(.surfaceTileLease)
    }

    private func encodeCommand(
        configuration: StrokeTileEncodingConfiguration,
        records: [StrokePreparedProjectedRecord],
        ranges: [StrokeTileRecordRange],
        references: [Int],
        layer: StrokePrivateSurfaceLayer,
        authoritativeLease: DocumentPaintStrokeFrameReservation?,
        predictionLease: DocumentPaintStrokeFrameReservation?,
        provisionalBindings: DocumentPaintStrokeProvisionalReservation?,
        coordinatesToClear: [PaintTileCoordinate],
        allocationProbe: StrokePreparationAllocationProbe?
    ) async throws {
        guard !ranges.isEmpty || !coordinatesToClear.isEmpty else { return }
        allocationProbe?.arm()
        var probeIsArmed = allocationProbe != nil
        func finishProbe() {
            guard probeIsArmed else { return }
            allocationProbe?.disarmAndRecord(.surfaceMetalSubmission)
            probeIsArmed = false
        }
        defer { finishProbe() }
        guard let provisionalBindings,
              (layer == .authoritative
                ? authoritativeLease : predictionLease) != nil,
              let commandBuffer = configuration.resources.commandQueue
                .makeCommandBuffer()
        else { throw StrokeTileSurfaceError.commandBufferUnavailable }
        let destination = configuration.resources.uploadBuffer.contents()
            .bindMemory(
                to: PatternDepositionStampInstance.self,
                capacity: configuration.resources.maximumTileReferenceCount
            )
        for index in references.indices {
            destination[index] = records[references[index]]
                .depositionRecord.instance
        }
        var requiresCopy = false
        for provisional in provisionalBindings.bindings {
            if !provisional.sourceIsKnownClear
                && !(layer == .prediction
                    && Self.containsSorted(
                        coordinatesToClear,
                        provisional.descriptor.coordinate
                    ))
            {
                requiresCopy = true
            }
            if provisional.sourceComponentCoverageTexture != nil {
                requiresCopy = true
            }
        }
        if requiresCopy {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw StrokeTileSurfaceError.renderEncoderUnavailable
            }
            for provisional in provisionalBindings.bindings {
                let mustClear = provisional.sourceIsKnownClear
                    || (layer == .prediction
                        && Self.containsSorted(
                            coordinatesToClear,
                            provisional.descriptor.coordinate
                        ))
                if mustClear { continue }
                blit.copy(
                    from: provisional.sourceTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(
                        width: provisional.descriptor.logicalBounds.width,
                        height: provisional.descriptor.logicalBounds.height,
                        depth: 1
                    ),
                    to: provisional.candidateTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                if let sourceCoverage = provisional
                    .sourceComponentCoverageTexture
                {
                    blit.copy(
                        from: sourceCoverage,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(
                            width: provisional.descriptor.logicalBounds.width,
                            height: provisional.descriptor.logicalBounds.height,
                            depth: 1
                        ),
                        to: provisional.candidateComponentCoverageTexture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                }
            }
            blit.endEncoding()
        }
        var rangeIndex = 0
        var clearIndex = 0
        for provisional in provisionalBindings.bindings {
            let coordinate = provisional.descriptor.coordinate
            while rangeIndex < ranges.count,
                  ranges[rangeIndex].physicalCoordinate < coordinate
            {
                rangeIndex += 1
            }
            while clearIndex < coordinatesToClear.count,
                  coordinatesToClear[clearIndex] < coordinate
            {
                clearIndex += 1
            }
            let range = rangeIndex < ranges.count
                    && ranges[rangeIndex].physicalCoordinate == coordinate
                ? ranges[rangeIndex] : nil
            let clear = (clearIndex < coordinatesToClear.count
                    && coordinatesToClear[clearIndex] == coordinate)
                || range?.shouldClear == true
            guard range != nil || clear else { continue }
            // Packed stamp, grain, and clip coordinates are physical atlas
            // coordinates. A radial page can live in any compact atlas slot,
            // so its tile-local viewport subtracts that physical origin while
            // the logical origin remains page-table metadata for sampling.
            let viewportOrigin = range?.atlasOrigin ?? SIMD2(
                coordinate.x * PaintTileDescriptor.side,
                coordinate.y * PaintTileDescriptor.side
            )
            let pass = configuration.resources.depositionPassDescriptor
            pass.colorAttachments[0].texture = provisional.candidateTexture
            pass.colorAttachments[1].texture =
                provisional.candidateComponentCoverageTexture
            let initializesFromClear = clear
                || provisional.sourceIsKnownClear
            pass.colorAttachments[0].loadAction = initializesFromClear
                ? .clear : .load
            if initializesFromClear {
                pass.colorAttachments[0].clearColor = MTLClearColorMake(
                    0, 0, 0, 0
                )
            }
            let initializesCoverageFromClear = initializesFromClear
                || provisional.sourceComponentCoverageTexture == nil
            pass.colorAttachments[1].loadAction = initializesCoverageFromClear
                ? .clear : .load
            pass.colorAttachments[1].storeAction = .store
            if initializesCoverageFromClear {
                pass.colorAttachments[1].clearColor = MTLClearColorMake(
                    0, 0, 0, 0
                )
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: pass
            ) else { throw StrokeTileSurfaceError.renderEncoderUnavailable }
            encoder.setViewport(MTLViewport(
                originX: -Double(viewportOrigin.x),
                originY: -Double(viewportOrigin.y),
                width: Double(configuration.frameUniforms.tileSize.x),
                height: Double(configuration.frameUniforms.tileSize.y),
                znear: 0,
                zfar: 1
            ))
            encoder.setScissorRect(MTLScissorRect(
                x: 0,
                y: 0,
                width: provisional.descriptor.logicalBounds.width,
                height: provisional.descriptor.logicalBounds.height
            ))
            if let range, !range.recordRange.isEmpty {
                var frame = configuration.frameUniforms
                encoder.setVertexBytes(
                    &frame,
                    length: MemoryLayout<PatternGridFrameUniforms>.stride,
                    index: Int(PatternBufferIndexGridFrameUniforms)
                )
                var runStart = range.recordRange.lowerBound
                while runStart < range.recordRange.upperBound {
                    let ordinal = records[references[runStart]]
                        .componentOrdinal
                    var runEnd = runStart + 1
                    while runEnd < range.recordRange.upperBound,
                          records[references[runEnd]].componentOrdinal
                            == ordinal
                    {
                        runEnd += 1
                    }
                    let component = try Self.componentBinding(
                        ordinal: ordinal,
                        configuration: configuration
                    )
                    Self.bind(component, to: encoder)
                    encoder.setVertexBuffer(
                        configuration.resources.uploadBuffer,
                        offset: runStart
                            * MemoryLayout<
                                PatternDepositionStampInstance
                            >.stride,
                        index: Int(PatternBufferIndexDabInstances)
                    )
                    encoder.drawPrimitives(
                        type: .triangle,
                        vertexStart: 0,
                        vertexCount: 6,
                        instanceCount: runEnd - runStart
                    )
                    runStart = runEnd
                }
            }
            encoder.endEncoding()
        }
        let outcome = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { completed in
                continuation.resume(returning: StrokeTileCommandOutcome(
                    succeeded: completed.status == .completed
                        && completed.error == nil,
                    message: completed.error?.localizedDescription
                ))
            }
            commandBuffer.commit()
            // The allocator hook is thread-local. Stop measuring immediately
            // after submission, before this task suspends and may resume on a
            // different cooperative-executor thread.
            finishProbe()
        }
        guard !configuration.forceCommandFailure, outcome.succeeded else {
            throw StrokeTileSurfaceError.commandFailed(
                outcome.message ?? "sparse stroke command failed"
            )
        }
    }

    private static func validateComponentBindings(
        _ configuration: StrokeTileEncodingConfiguration
    ) throws {
        guard configuration.primaryComponent.ordinal == 0 else {
            throw StrokeTileSurfaceError.invalidComponentBindingOrdinal(
                expected: 0,
                actual: configuration.primaryComponent.ordinal
            )
        }
        try validatePipeline(configuration.primaryComponent.pipeline)
        if let secondary = configuration.secondaryComponent {
            guard secondary.ordinal == 1 else {
                throw StrokeTileSurfaceError.invalidComponentBindingOrdinal(
                    expected: 1,
                    actual: secondary.ordinal
                )
            }
            try validatePipeline(secondary.pipeline)
        }
    }

    private static func validatePipeline(
        _ pipeline: DepositionPipelineBinding
    ) throws {
        let actual = pipeline.key.colorPixelFormatRawValue
        guard actual == MTLPixelFormat.rgba16Float.rawValue else {
            throw StrokeTileSurfaceError.invalidPipelinePixelFormat(
                expected: MTLPixelFormat.rgba16Float.rawValue,
                actual: actual
            )
        }
    }

    private static func componentBinding(
        ordinal: UInt8,
        configuration: StrokeTileEncodingConfiguration
    ) throws -> StrokeTileComponentEncodingBinding {
        if ordinal == configuration.primaryComponent.ordinal {
            return configuration.primaryComponent
        }
        if let secondary = configuration.secondaryComponent,
           ordinal == secondary.ordinal
        {
            return secondary
        }
        throw StrokeTileSurfaceError.componentBindingUnavailable(ordinal)
    }

    private static func bind(
        _ component: StrokeTileComponentEncodingBinding,
        to encoder: any MTLRenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(component.pipeline.state)
        var material = component.materialUniforms
        material.edgeParameters.y = Float(component.ordinal)
        encoder.setFragmentBytes(
            &material,
            length: MemoryLayout<PatternDepositionMaterialUniforms>.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        encoder.setFragmentTexture(
            component.primaryShape,
            index: DepositionTextureSlot.primaryShape.rawValue
        )
        encoder.setFragmentTexture(
            component.secondaryShape,
            index: DepositionTextureSlot.secondaryShape.rawValue
        )
        encoder.setFragmentTexture(
            component.primaryGrain,
            index: DepositionTextureSlot.primaryGrain.rawValue
        )
        encoder.setFragmentTexture(
            component.secondaryGrain,
            index: DepositionTextureSlot.secondaryGrain.rawValue
        )
    }

    private static func mergeSortedUnique(
        _ lhs: [PaintTileCoordinate],
        _ rhs: [PaintTileCoordinate],
        into result: inout [PaintTileCoordinate],
        maximum: Int
    ) throws {
        result.removeAll(keepingCapacity: true)
        var left = 0
        var right = 0
        while left < lhs.count || right < rhs.count {
            let candidate: PaintTileCoordinate
            if right == rhs.count
                || (left < lhs.count && lhs[left] < rhs[right])
            {
                candidate = lhs[left]
                left += 1
            } else if left == lhs.count || rhs[right] < lhs[left] {
                candidate = rhs[right]
                right += 1
            } else {
                candidate = lhs[left]
                left += 1
                right += 1
            }
            if result.last != candidate {
                guard result.count < maximum else {
                    throw StrokeTileSurfaceError.tileBudgetExceeded(
                        required: result.count + 1,
                        maximum: maximum
                    )
                }
                result.append(candidate)
            }
        }
    }

    fileprivate static func containsSorted(
        _ coordinates: [PaintTileCoordinate],
        _ candidate: PaintTileCoordinate
    ) -> Bool {
        var lower = 0
        var upper = coordinates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if coordinates[middle] < candidate {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < coordinates.count && coordinates[lower] == candidate
    }
}

private func tileSurfaceEncodingIsOnMainThread() -> Bool {
    Thread.isMainThread
}

/// Release-allocation fixture for the current sparse stroke surface.
package enum StrokeTileAllocationProbeHarness {
    @MainActor
    package static func run(
        device: any MTLDevice,
        library: any MTLLibrary,
        probe: StrokePreparationAllocationProbe
    ) async throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw StrokeTileSurfaceError.commandQueueUnavailable
        }
        let pipeline = try await DepositionPipelineLibrary(
            device: device,
            library: library
        ).prepare(for: DepositionPipelineKey(
            brush: BrushPipelineKey(
                backend: .deposition,
                accumulation: .flow,
                edgeTreatment: .none,
                functionConstants: BrushFunctionConstants(
                    usesSecondaryShape: false,
                    usesGrain: false,
                    usesSecondaryGrain: false
                )
            ),
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue: MTLPixelFormat.rgba16Float.rawValue,
            sampleCount: 1
        ))
        let layerID = UUID(
            uuidString: "1a110ca7-10a5-4d50-a110-ca710a54d501"
        )!
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 16,
            geometry: DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 512, height: 512),
                storagePixelSize: PixelSize(width: 512, height: 512),
                radialLayout: nil
            ),
            layerIDs: [layerID],
            generation: 1
        )
        let first = try makeResources(
            device: device,
            commandQueue: commandQueue,
            registry: registry,
            layerID: layerID,
            pipeline: pipeline
        )
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            configuration(first, pipeline: pipeline),
            generation: 1
        )
        let actual = try record(
            ordinal: 1,
            componentOrdinal: 0,
            predicted: false
        )
        let predicted = try record(
            ordinal: 2,
            componentOrdinal: 1,
            predicted: true
        )

        // Warm every state shape before arming the release allocator probe.
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 1,
            records: [actual],
            layer: .authoritative,
            probe: nil
        )
        encoder.beginPredictionReplacement()
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 1,
            records: [predicted],
            layer: .prediction,
            probe: nil
        )
        encoder.beginPredictionReplacement()
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 1,
            records: [],
            layer: .prediction,
            probe: nil
        )
        try encoder.cancel(frameDisposition: .unpublished)

        let generationTwo = try registry.makeCandidate()
        registry.commitPrepared(try registry.prepareCommit(generationTwo))

        let measured = try makeResources(
            device: device,
            commandQueue: commandQueue,
            registry: registry,
            layerID: layerID,
            pipeline: pipeline
        )
        try encoder.configure(
            configuration(measured, pipeline: pipeline),
            generation: 2
        )
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 2,
            records: [actual],
            layer: .authoritative,
            probe: nil
        )
        encoder.beginPredictionReplacement()
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 2,
            records: [predicted],
            layer: .prediction,
            probe: nil
        )
        // Reconfigure the same namespace after warming every persistent store
        // and candidate shape; measured calls exercise only the warmed path.
        try encoder.configure(
            configuration(measured, pipeline: pipeline),
            generation: 2
        )

        let second = try makeResources(
            device: device,
            commandQueue: commandQueue,
            registry: registry,
            layerID: layerID,
            pipeline: pipeline
        )
        let secondWarmer = StrokeTileSurfaceEncoder()
        try secondWarmer.configure(
            configuration(second, pipeline: pipeline),
            generation: 2
        )
        try await encodeAndAcknowledge(
            encoder: secondWarmer,
            generation: 2,
            records: [actual],
            layer: .authoritative,
            probe: nil
        )

        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 2,
            records: [actual],
            layer: .authoritative,
            probe: probe
        )
        encoder.beginPredictionReplacement()
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 2,
            records: [predicted],
            layer: .prediction,
            probe: probe
        )
        encoder.beginPredictionReplacement()
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 2,
            records: [],
            layer: .prediction,
            probe: probe
        )

        let unpublishedLease = try await encoder.encode(
            generation: 2,
            records: [actual],
            layer: .authoritative,
            allocationProbe: probe
        )
        try encoder.cancel(
            frameDisposition: .unpublished,
            allocationProbe: probe
        )
        withExtendedLifetime(unpublishedLease) {}

        try encoder.configure(
            configuration(second, pipeline: pipeline),
            generation: 2
        )
        try await encodeAndAcknowledge(
            encoder: encoder,
            generation: 2,
            records: [actual],
            layer: .authoritative,
            probe: probe
        )
        try encoder.cancel(
            frameDisposition: .unpublished,
            allocationProbe: probe
        )
    }

    @MainActor
    private static func makeResources(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        registry: DocumentPaintSurfaceStore,
        layerID: UUID,
        pipeline: DepositionPipelineBinding
    ) throws -> StrokeTileSurfaceResources {
        let capability = try registry.issueCurrentStrokeSurfaceCapability(
            layerID: layerID,
            ownerIdentity: UUID(),
            onTerminal: { _ in }
        )
        return try StrokeTileSurfaceResources(
            device: device,
            commandQueue: commandQueue,
            capability: capability,
            maximumRecordCount: 32,
            maximumTileReferenceCount: 128
        )
    }

    private static func configuration(
        _ resources: StrokeTileSurfaceResources,
        pipeline: DepositionPipelineBinding
    ) -> StrokeTileEncodingConfiguration {
        let primary = StrokeTileComponentEncodingBinding(
            ordinal: 0,
            pipeline: pipeline,
            materialUniforms: PatternDepositionMaterialUniforms(),
            primaryShape: nil,
            secondaryShape: nil,
            primaryGrain: nil,
            secondaryGrain: nil
        )
        let secondary = StrokeTileComponentEncodingBinding(
            ordinal: 1,
            pipeline: pipeline,
            materialUniforms: PatternDepositionMaterialUniforms(),
            primaryShape: nil,
            secondaryShape: nil,
            primaryGrain: nil,
            secondaryGrain: nil
        )
        return StrokeTileEncodingConfiguration(
            resources: resources,
            primaryComponent: primary,
            secondaryComponent: secondary,
            frameUniforms: PatternGridFrameUniforms(
                drawableSize: SIMD2(repeating: 512),
                worldCenter: SIMD2(repeating: 256),
                tileSize: SIMD2(repeating: 512),
                zoom: 1,
                gridLineWidth: 0,
                showGridLines: 0,
                liveVisible: 1,
                tilingKind: 0,
                diagnosticMode: 0,
                compositeMode: 0,
                symmetryFamily: 0,
                repeatSize: SIMD2(repeating: 512),
                latticeXAxis: SIMD2(1, 0),
                latticeYAxis: SIMD2(0, 1),
                latticeTranslation: .zero,
                guideKind: 0,
                showCanvasBoundary: 0
            ),
            radialLayout: nil,
            forceCommandFailure: false
        )
    }

    private static func encodeAndAcknowledge(
        encoder: StrokeTileSurfaceEncoder,
        generation: UInt64,
        records: [StrokePreparedProjectedRecord],
        layer: StrokePrivateSurfaceLayer,
        probe: StrokePreparationAllocationProbe?
    ) async throws {
        guard let lease = try await encoder.encode(
            generation: generation,
            records: records,
            layer: layer,
            allocationProbe: probe
        ) else { return }
        if let probe {
            try measure(probe) { try encoder.acknowledge(lease) }
        } else {
            try encoder.acknowledge(lease)
        }
    }

    private static func measure(
        _ probe: StrokePreparationAllocationProbe,
        _ operation: () throws -> Void
    ) throws {
        probe.arm()
        do {
            try operation()
            probe.disarmAndRecord(.surfaceTileLease)
        } catch {
            probe.disarmAndRecord(.surfaceTileLease)
            throw error
        }
    }

    private static func record(
        ordinal: UInt64,
        componentOrdinal: UInt8,
        predicted: Bool
    ) throws -> StrokePreparedProjectedRecord {
        let dab = LogicalDab(
            position: WorldPoint(x: 16, y: 16),
            brushToWorld: Affine2D(
                xAxis: SIMD2(4, 0),
                yAxis: SIMD2(0, 4),
                translation: SIMD2(16, 16)
            ),
            radius: 4,
            diameter: 8,
            spacing: 1,
            flow: 1,
            strokeOpacity: 1,
            rotation: 0,
            scatter: .zero,
            hardness: 1,
            grainOffset: .zero,
            grainScale: 1,
            grainRotation: 0,
            color: .black,
            colorAdjustment: .identity,
            materialFamily: .ink,
            materialContribution: 1,
            sourceDistance: 0,
            ordinal: ordinal,
            isPredicted: predicted
        )
        let fragment = CellFragment(
            cell: CellIndex(column: 0, row: 0),
            imageOrdinal: 0,
            canonicalFromBrush: dab.brushToWorld,
            brushClip: ConvexClip(halfPlanes: [])
        )
        guard let dirtyRect = PixelRect(
            minX: 8, minY: 8, maxX: 24, maxY: 24
        ) else { throw StrokeTileSurfaceError.invalidCapacity }
        return StrokePreparedProjectedRecord(
            depositionRecord: ProjectedDepositionRecord(
                identity: ordinal,
                componentOrdinal: componentOrdinal,
                instance: try PatternDepositionStampInstance(
                    fragment: fragment,
                    dab: dab,
                    logicalOrdinal: ordinal,
                    isometryOrdinal: 0
                ),
                radialPage: nil
            ),
            dirtyRect: dirtyRect,
            radialPage: nil
        )
    }
}
