import Foundation
import Metal
import PatternEngine
import simd

enum SparseTileSamplingPlanError: Error, Equatable, Sendable {
    case invalidOutputRegion
    case invalidLimit
    case arithmeticOverflow
    case unsortedChangedCoordinates
    case duplicateChangedCoordinate(PaintTileCoordinate)
    case unsortedReference
    case duplicateReference(PaintTileCoordinate)
    case foreignReference(PaintTileReference)
    case contentRoleMismatch
    case sourceOrderMismatch
    case duplicateSource(layerID: UUID, role: SparseTileSampleRole)
    case duplicateLayer(UUID)
    case sourceLayerMismatch(expected: UUID, actual: UUID)
    case sourceGenerationMismatch(expected: UInt64, actual: UInt64)
    case sourcePixelSizeMismatch
    case inconsistentAddressing
    case contentKeyMismatch
    case pageEntryLimitExceeded(required: Int, maximum: Int)
    case pageChunkLimitExceeded(required: Int, maximum: Int)
    case pageTableByteLimitExceeded(required: Int, maximum: Int)
    case bindingSlotLimitExceeded(required: Int, maximum: Int)
    case bindingChunkLimitExceeded(required: Int, maximum: Int)
    case bindingByteLimitExceeded(required: Int, maximum: Int)
    case batchLimitExceeded(required: Int, maximum: Int)
    case onePixelBatchExceedsTextureLimit(required: Int, maximum: Int)
    case missingBinding(PaintTileReference)
    case bindingCountMismatch(references: Int, bindings: Int)
    case slotOwnerIdentityOverflow
    case staleSlotOwner
    case missingPageTable(layerID: UUID, role: SparseTileSampleRole)
    case nonFiniteSamplePoint
    case invalidOutputToSourceTransform
    case contentKeyCollision
    case consumerIdentityOverflow
    case leaseRetirementRequested
    case staleConsumer
    case leaseAlreadyRetired
    case sourceBatchInUse
    case sourceBatchConsumed
    case sourceBatchSelectionMismatch(sourceIndex: Int)
    case periodicReachabilityWorkLimitExceeded(maximum: Int)
    case injectedSourceLeaseFailure(Int)
    case injectedBoundTextureFailure
    case injectedContentPublicationFailure
}

enum SparseTileSampleRole: UInt8, CaseIterable, Hashable, Sendable {
    case canonical
    case authoritative
    case prediction
}

enum SparseTileAddressing: Equatable, Sendable {
    case finite(PixelSize)
    case periodic(period: PixelSize)
    case radial(layout: RadialSectorLayout)
}

/// Immutable axis-aligned mapping from target-local pixel centers into sparse
/// source pixel-center space. `sourceOffset` is relative to the P3 output
/// region's minimum; this keeps `.identity` correct for signed/nonzero regions.
struct SparseTileOutputToSourceTransform: Equatable, Hashable, Sendable {
    let sourceOffset: SIMD2<Float>
    let sourceStep: SIMD2<Float>

    static let identity = SparseTileOutputToSourceTransform(
        sourceOffset: .zero,
        sourceStep: SIMD2(repeating: 1)
    )

    func shaderSourceOrigin(
        outputRegion: SparseTileOutputRegion
    ) throws -> SIMD2<Float> {
        try shaderSourceOrigin(outputOrigin: SIMD2(
            outputRegion.minX,
            outputRegion.minY
        ))
    }

    func shaderSourceOrigin(
        outputOrigin: SIMD2<Int>
    ) throws -> SIMD2<Float> {
        let root = SIMD2(Float(outputOrigin.x), Float(outputOrigin.y))
        guard root.x.isFinite, root.y.isFinite,
              Double(root.x) == Double(outputOrigin.x),
              Double(root.y) == Double(outputOrigin.y),
              sourceOffset.x.isFinite, sourceOffset.y.isFinite,
              sourceStep.x.isFinite, sourceStep.y.isFinite
        else {
            throw SparseTileSamplingPlanError.invalidOutputToSourceTransform
        }
        let origin = root + sourceOffset
        guard origin.x.isFinite, origin.y.isFinite else {
            throw SparseTileSamplingPlanError.invalidOutputToSourceTransform
        }
        return origin
    }
}

enum SparseTileSamplingOutputMappingKind: UInt8, Hashable, Sendable {
    case affine
    case periodic
    case finiteRadial
}

struct SparseTilePeriodicOutputMapping: Equatable, Sendable {
    let fold: CompiledPeriodicDisplayFold
    let outputToWorldTransform: SparseTileOutputToSourceTransform
    /// Root-relative integer pixel displacement used by stable child chunks.
    /// Keeping the root transform unchanged lets CPU and Metal evaluate
    /// `origin + (localPixel + offset) * step` with the unsplit grouping.
    let screenPixelOffset: SIMD2<Int>

    init(
        fold: CompiledPeriodicDisplayFold,
        outputToWorldTransform: SparseTileOutputToSourceTransform,
        screenPixelOffset: SIMD2<Int> = .zero
    ) {
        self.fold = fold
        self.outputToWorldTransform = outputToWorldTransform
        self.screenPixelOffset = screenPixelOffset
    }

    func shaderSourceOrigin(
        outputRegion: SparseTileOutputRegion
    ) throws -> SIMD2<Float> {
        let rootX = try outputRegion.minX
            .subtractingChecked(screenPixelOffset.x)
        let rootY = try outputRegion.minY
            .subtractingChecked(screenPixelOffset.y)
        return try outputToWorldTransform.shaderSourceOrigin(
            outputOrigin: SIMD2(rootX, rootY)
        )
    }
}

extension SparseTilePeriodicOutputMapping: Hashable {
    static func == (
        lhs: SparseTilePeriodicOutputMapping,
        rhs: SparseTilePeriodicOutputMapping
    ) -> Bool {
        let left = lhs.fold
        let right = rhs.fold
        return left.family == right.family
            && left.coordinateSpace == right.coordinateSpace
            && left.worldToLattice == right.worldToLattice
            && left.canonicalSize == right.canonicalSize
            && left.repeatSize == right.repeatSize
            && left.phase == right.phase
            && left.alternatingReflections == right.alternatingReflections
            && lhs.outputToWorldTransform == rhs.outputToWorldTransform
            && lhs.screenPixelOffset == rhs.screenPixelOffset
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fold.family.rawValue)
        hasher.combine(fold.coordinateSpace.rawValue)
        hasher.combine(fold.worldToLattice.xAxis.x)
        hasher.combine(fold.worldToLattice.xAxis.y)
        hasher.combine(fold.worldToLattice.yAxis.x)
        hasher.combine(fold.worldToLattice.yAxis.y)
        hasher.combine(fold.worldToLattice.translation.x)
        hasher.combine(fold.worldToLattice.translation.y)
        hasher.combine(fold.canonicalSize.width)
        hasher.combine(fold.canonicalSize.height)
        hasher.combine(fold.repeatSize.width)
        hasher.combine(fold.repeatSize.height)
        if let phase = fold.phase {
            hasher.combine(true)
            switch phase.indexAxis {
            case .x: hasher.combine(UInt32(0))
            case .y: hasher.combine(UInt32(1))
            }
            switch phase.offsetAxis {
            case .x: hasher.combine(UInt32(0))
            case .y: hasher.combine(UInt32(1))
            }
            hasher.combine(phase.fractions.count)
            for fraction in phase.fractions { hasher.combine(fraction) }
        } else {
            hasher.combine(false)
        }
        hasher.combine(fold.alternatingReflections.rawValue)
        hasher.combine(outputToWorldTransform)
        hasher.combine(screenPixelOffset.x)
        hasher.combine(screenPixelOffset.y)
    }
}

struct SparseTileFiniteRadialOutputMapping: Equatable, Sendable {
    let strategy: TilingStrategy
    let outputToWorldTransform: SparseTileOutputToSourceTransform

    init(
        strategy: TilingStrategy,
        outputToWorldTransform: SparseTileOutputToSourceTransform = .identity
    ) throws {
        guard strategy.compiledSymmetry.family == .radial,
              let radial = strategy.compiledSymmetry.domain.finite?.radial,
              radial.configuration != nil,
              radial.layout != nil,
              outputToWorldTransform.sourceOffset.x.isFinite,
              outputToWorldTransform.sourceOffset.y.isFinite,
              outputToWorldTransform.sourceStep.x.isFinite,
              outputToWorldTransform.sourceStep.y.isFinite,
              outputToWorldTransform.sourceStep.x > 0,
              outputToWorldTransform.sourceStep.x
                == outputToWorldTransform.sourceStep.y
        else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        self.strategy = strategy
        self.outputToWorldTransform = outputToWorldTransform
    }

    var radial: CompiledRadialDomain {
        strategy.compiledSymmetry.domain.finite!.radial
    }

    var layout: RadialSectorLayout { radial.layout! }
}

extension SparseTileFiniteRadialOutputMapping: Hashable {
    static func == (
        lhs: SparseTileFiniteRadialOutputMapping,
        rhs: SparseTileFiniteRadialOutputMapping
    ) -> Bool {
        lhs.strategy == rhs.strategy
            && lhs.outputToWorldTransform == rhs.outputToWorldTransform
    }

    func hash(into hasher: inout Hasher) {
        let radial = radial
        let configuration = radial.configuration!
        hasher.combine(strategy.canvasSize.width)
        hasher.combine(strategy.canvasSize.height)
        hasher.combine(configuration.kind.rawValue)
        hasher.combine(configuration.rayCount)
        hasher.combine(configuration.center.x)
        hasher.combine(configuration.center.y)
        hasher.combine(configuration.referenceAngleRadians)
        hasher.combine(radial.sectorAngleRadians)
        hasher.combine(radial.displayedSectorCount)
        hasher.combine(configuration.kind != .rotation)
        hasher.combine(layout.pageOrigin.x)
        hasher.combine(layout.pageOrigin.y)
        hasher.combine(layout.pageTableSize.width)
        hasher.combine(layout.pageTableSize.height)
        hasher.combine(layout.atlasColumns)
        hasher.combine(layout.atlasPixelSize.width)
        hasher.combine(layout.atlasPixelSize.height)
        hasher.combine(outputToWorldTransform)
    }
}

enum SparseTileSamplingOutputMapping: Equatable, Hashable, Sendable {
    case affine(SparseTileOutputToSourceTransform)
    case periodic(SparseTilePeriodicOutputMapping)
    case finiteRadial(SparseTileFiniteRadialOutputMapping)

    static func finiteRadial(
        strategy: TilingStrategy,
        outputToWorldTransform: SparseTileOutputToSourceTransform = .identity
    ) throws -> SparseTileSamplingOutputMapping {
        .finiteRadial(try SparseTileFiniteRadialOutputMapping(
            strategy: strategy,
            outputToWorldTransform: outputToWorldTransform
        ))
    }

    var kind: SparseTileSamplingOutputMappingKind {
        switch self {
        case .affine: .affine
        case .periodic: .periodic
        case .finiteRadial: .finiteRadial
        }
    }

    var affineTransform: SparseTileOutputToSourceTransform? {
        guard case let .affine(transform) = self else { return nil }
        return transform
    }

    var outputToWorldTransform: SparseTileOutputToSourceTransform {
        switch self {
        case let .affine(transform): transform
        case let .periodic(mapping): mapping.outputToWorldTransform
        case let .finiteRadial(mapping): mapping.outputToWorldTransform
        }
    }

    var periodicScreenPixelOffset: SIMD2<Int> {
        guard case let .periodic(mapping) = self else { return .zero }
        return mapping.screenPixelOffset
    }
}

/// One compatibility authority used before any periodic root/source retention
/// and again by plan construction. Region-specific cell admissibility remains
/// in nonlinear reachability because it depends on the requested pixel centers.
enum SparseTilePeriodicOutputMappingValidator {
    static func validate(
        _ mapping: SparseTilePeriodicOutputMapping,
        addressing: SparseTileAddressing
    ) throws {
        guard case let .periodic(period) = addressing,
              period.width <= Int(Int32.max),
              period.height <= Int(Int32.max),
              Int(exactly: mapping.fold.canonicalSize.width) == period.width,
              Int(exactly: mapping.fold.canonicalSize.height) == period.height,
              mapping.fold.phase?.fractions.count ?? 0 <= 2,
              mapping.fold.family != .radial,
              mapping.outputToWorldTransform.sourceOffset.x.isFinite,
              mapping.outputToWorldTransform.sourceOffset.y.isFinite,
              mapping.outputToWorldTransform.sourceStep.x.isFinite,
              mapping.outputToWorldTransform.sourceStep.y.isFinite,
              mapping.screenPixelOffset.x >= 0,
              mapping.screenPixelOffset.y >= 0,
              mapping.screenPixelOffset.x <= Int(UInt32.max),
              mapping.screenPixelOffset.y <= Int(UInt32.max),
              Int(exactly: Float(mapping.screenPixelOffset.x))
                == mapping.screenPixelOffset.x,
              Int(exactly: Float(mapping.screenPixelOffset.y))
                == mapping.screenPixelOffset.y
        else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
    }
}

struct SparseTileRoleContentKey: Hashable, Sendable {
    let role: SparseTileSampleRole
    /// Stable namespace identity prevents equal per-surface revision counters
    /// from aliasing across strokes or replacement surfaces.
    let surfaceIdentity: UUID
    let contentRevision: UInt64
    let bindingChunkRevision: UInt64

    init(
        role: SparseTileSampleRole,
        surfaceIdentity: UUID,
        contentRevision: UInt64,
        bindingChunkRevision: UInt64
    ) {
        self.role = role
        self.surfaceIdentity = surfaceIdentity
        self.contentRevision = contentRevision
        self.bindingChunkRevision = bindingChunkRevision
    }
}

struct SparseTileLayerContentKey: Hashable, Sendable {
    let layerID: UUID
    let roles: [SparseTileRoleContentKey]
}

struct SparseTileSamplingPlanKey: Hashable, Sendable {
    let documentGeneration: UInt64
    let orderedLayers: [SparseTileLayerContentKey]
    let addressingRevision: UInt64
    let outputGeometryRevision: UInt64
    let outputMapping: SparseTileSamplingOutputMapping

    var outputToSourceTransform: SparseTileOutputToSourceTransform {
        outputMapping.outputToWorldTransform
    }

    init(
        documentGeneration: UInt64,
        orderedLayers: [SparseTileLayerContentKey],
        addressingRevision: UInt64,
        outputGeometryRevision: UInt64,
        outputToSourceTransform: SparseTileOutputToSourceTransform = .identity
    ) {
        self.documentGeneration = documentGeneration
        self.orderedLayers = orderedLayers
        self.addressingRevision = addressingRevision
        self.outputGeometryRevision = outputGeometryRevision
        outputMapping = .affine(outputToSourceTransform)
    }

    init(
        documentGeneration: UInt64,
        orderedLayers: [SparseTileLayerContentKey],
        addressingRevision: UInt64,
        outputGeometryRevision: UInt64,
        outputMapping: SparseTileSamplingOutputMapping
    ) {
        self.documentGeneration = documentGeneration
        self.orderedLayers = orderedLayers
        self.addressingRevision = addressingRevision
        self.outputGeometryRevision = outputGeometryRevision
        self.outputMapping = outputMapping
    }
}

enum SparseTileSourceDisposition: Equatable, Sendable {
    case fullSnapshot
    case delta
}

struct SparseTileSourceRequest: @unchecked Sendable {
    enum ReferenceScope {
        case identity
        case entitlement
    }

    let contentKey: SparseTileRoleContentKey
    let addressing: SparseTileAddressing
    let provider: TiledRasterExactReferenceProvider
    /// Exact immutable visible set captured at adaptation time. The mutable
    /// surface remains only as the owner used to lease these exact references.
    let references: [PaintTileReference]
    let changedCoordinates: [PaintTileCoordinate]
    let disposition: SparseTileSourceDisposition

    init(
        contentKey: SparseTileRoleContentKey,
        addressing: SparseTileAddressing,
        provider: TiledRasterExactReferenceProvider,
        changedCoordinates: [PaintTileCoordinate],
        disposition: SparseTileSourceDisposition,
        referenceScope: ReferenceScope = .identity
    ) throws {
        for index in changedCoordinates.indices.dropFirst() {
            let previous = changedCoordinates[index - 1]
            let current = changedCoordinates[index]
            if previous == current {
                throw SparseTileSamplingPlanError
                    .duplicateChangedCoordinate(current)
            }
            guard previous < current else {
                throw SparseTileSamplingPlanError.unsortedChangedCoordinates
            }
        }
        self.contentKey = contentKey
        self.addressing = addressing
        self.provider = provider
        // Ordinary captures preserve the complete logical identity even when
        // their provider entitlement is viewport-restricted. Independently
        // numbered tile-local child plans opt into the exact entitlement so
        // they cannot bind the same global slots again for every child region.
        references = switch referenceScope {
        case .identity: provider.references
        case .entitlement: provider.entitledReferences
        }
        self.changedCoordinates = changedCoordinates
        self.disposition = disposition
    }

    var role: SparseTileSampleRole { contentKey.role }
    var layerID: UUID { provider.layerID }
}

/// Pure Phase-A result. Construction is confined to this file so callers can
/// neither widen the selected entitlement nor substitute a different provider
/// between viewport selection and exact store retention.
struct SparseTileSourceSelection: @unchecked Sendable {
    fileprivate let sources: [SparseTileSourceRequest]
    fileprivate let selectedReferencesBySource: [[PaintTileReference]]
    fileprivate let periodicReachabilitySeed:
        SparseTilePeriodicReachabilitySeed?

    var reusablePeriodicReachabilitySeed:
        SparseTilePeriodicReachabilitySeed?
    {
        periodicReachabilitySeed
    }

    fileprivate init(
        sources: [SparseTileSourceRequest],
        selectedReferencesBySource: [[PaintTileReference]],
        periodicReachabilitySeed: SparseTilePeriodicReachabilitySeed?
    ) {
        self.sources = sources
        self.selectedReferencesBySource = selectedReferencesBySource
        self.periodicReachabilitySeed = periodicReachabilitySeed
    }

    func selectedReferenceCount() throws -> Int {
        var total = 0
        for references in selectedReferencesBySource {
            let (next, overflow) = total.addingReportingOverflow(
                references.count
            )
            guard !overflow else {
                throw SparseTileSamplingPlanError.arithmeticOverflow
            }
            total = next
        }
        return total
    }

    func restrictedSources(
        referenceScope: SparseTileSourceRequest.ReferenceScope = .identity
    ) throws -> [SparseTileSourceRequest] {
        guard selectedReferencesBySource.count == sources.count else {
            throw SparseTileSamplingPlanError
                .sourceBatchSelectionMismatch(
                    sourceIndex: min(
                        selectedReferencesBySource.count,
                        sources.count
                    )
                )
        }
        return try zip(sources, selectedReferencesBySource).map {
            source, selected in
            let provider = try source.provider
                .restrictingEntitlement(to: selected)
            return try SparseTileSourceRequest(
                contentKey: source.contentKey,
                addressing: source.addressing,
                provider: provider,
                changedCoordinates: source.changedCoordinates,
                disposition: source.disposition,
                referenceScope: referenceScope
            )
        }
    }

    #if DEBUG
    var testingPeriodicReachabilityReceipt:
        SparseTilePeriodicReachabilityReceipt?
    {
        guard let seed = periodicReachabilitySeed else { return nil }
        return SparseTilePeriodicReachabilityReceipt(
            physicalPages: seed.cachedPages[seed.outputRegion] ?? [],
            visitedNodeCount: seed.phaseAVisitedNodeCount,
            subdivisionCount: seed.phaseASubdivisionCount,
            enumeratedPixelCenterCount:
                seed.phaseAEnumeratedPixelCenterCount,
            singlePageFastPathCount:
                seed.phaseASinglePageFastPathCount,
            axisSweepPixelCenterCount:
                seed.phaseAAxisSweepPixelCenterCount,
            cacheHitCount: seed.phaseACacheHitCount,
            phaseAWorkCount: seed.phaseAWorkCount,
            acquisitionWorkCount: 0,
            workCount: seed.phaseAWorkCount
        )
    }

    func testingWithRootOnlyPeriodicReachabilitySeed()
        -> SparseTileSourceSelection
    {
        guard let seed = periodicReachabilitySeed,
              let rootPages = seed.cachedPages[seed.outputRegion]
        else { return self }
        return SparseTileSourceSelection(
            sources: sources,
            selectedReferencesBySource: selectedReferencesBySource,
            periodicReachabilitySeed: SparseTilePeriodicReachabilitySeed(
                outputRegion: seed.outputRegion,
                mapping: seed.mapping,
                addressing: seed.addressing,
                cachedPages: [seed.outputRegion: rootPages],
                phaseAVisitedNodeCount: seed.phaseAVisitedNodeCount,
                phaseASubdivisionCount: seed.phaseASubdivisionCount,
                phaseAEnumeratedPixelCenterCount:
                    seed.phaseAEnumeratedPixelCenterCount,
                phaseASinglePageFastPathCount:
                    seed.phaseASinglePageFastPathCount,
                phaseAAxisSweepPixelCenterCount:
                    seed.phaseAAxisSweepPixelCenterCount,
                phaseACacheHitCount: seed.phaseACacheHitCount,
                phaseAWorkCount: seed.phaseAWorkCount
            )
        )
    }
    #endif
}

/// Explicit one-shot access envelope for every exact source provider in a plan
/// build. It either owns aggregate retention or holds one checked borrow from a
/// stable capture; consumption closes that access exactly once after selected
/// leases are installed or on failure.
final class SparseTileOwnedSourceBatch: @unchecked Sendable {
    private enum State { case fresh, inUse, consumed }

    private enum CaptureAccess {
        case owned(TiledRasterExactReferenceCapture)
        case borrowed(TiledRasterExactReferenceCapture.Borrow)

        func leaseExactReferences(
            _ references: [PaintTileReference],
            from provider: TiledRasterExactReferenceProvider,
            pinReasons: [PaintTilePinReason]
        ) throws -> TiledRasterExactReferenceLease {
            switch self {
            case let .owned(capture):
                try provider.leaseExactReferences(
                    references,
                    using: capture,
                    pinReasons: pinReasons
                )
            case let .borrowed(borrow):
                try provider.leaseExactReferences(
                    references,
                    using: borrow,
                    pinReasons: pinReasons
                )
            }
        }

        func close() {
            switch self {
            case let .owned(capture): capture.close()
            case let .borrowed(borrow): borrow.close()
            }
        }

    }

    let sources: [SparseTileSourceRequest]
    private let captureAccess: CaptureAccess
    private let lock = NSLock()
    private var state = State.fresh
    private let deinitDiagnostic: @Sendable () -> Void
    private var terminalAction: (@Sendable () -> Void)?
    fileprivate let periodicReachabilitySeed:
        SparseTilePeriodicReachabilitySeed?

    private init(
        sources: [SparseTileSourceRequest],
        captureAccess: CaptureAccess,
        periodicReachabilitySeed: SparseTilePeriodicReachabilitySeed?,
        deinitDiagnostic: @escaping @Sendable () -> Void = {},
        onTerminal: @escaping @Sendable () -> Void = {}
    ) {
        self.sources = sources
        self.captureAccess = captureAccess
        self.periodicReachabilitySeed = periodicReachabilitySeed
        self.deinitDiagnostic = deinitDiagnostic
        terminalAction = onTerminal
    }

    /// Pure selection path. Entitlement is derived by the same Phase-A selector
    /// that the cache rechecks before any reservation.
    /// This operation performs no store mutation and can run outside registry
    /// locks before an immutable epoch identity is revalidated. A seed may be
    /// shared across sources only when the authority authenticates the exact
    /// output region, periodic mapping, and addressing tuple.
    static func selecting(
        sources: [SparseTileSourceRequest],
        key: SparseTileSamplingPlanKey,
        outputRegion: SparseTileOutputRegion,
        reusingPeriodicReachabilitySeed:
            SparseTilePeriodicReachabilitySeed? = nil,
        maximumPeriodicReachabilityWork: Int = 250_000
    ) throws -> SparseTileSourceSelection {
        guard !sources.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        let metadata = try sources.map {
            try SparseTileSourceSnapshot(
                contentKey: $0.contentKey,
                addressing: $0.addressing,
                layerID: $0.layerID,
                references: $0.references,
                changedCoordinates: $0.changedCoordinates,
                disposition: $0.disposition
            )
        }
        let authority = try SparseTileSamplingPlanBuilder
            .makePeriodicReachabilityAuthority(
                key: key,
                addressing: metadata[0].addressing,
                outputRegion: outputRegion,
                maximumWork: maximumPeriodicReachabilityWork,
                seed: reusingPeriodicReachabilitySeed
            )
        let selected = try SparseTileSamplingPlanBuilder
            .selectingPhysicalReferences(
                key: key,
                sources: metadata,
                outputRegion: outputRegion,
                periodicReachabilityAuthority: authority
            )
        let seed = authority.map {
            SparseTileSamplingPlanBuilder.periodicReachabilitySeed(from: $0)
        }
        return SparseTileSourceSelection(
            sources: sources,
            selectedReferencesBySource: selected.map(\.references),
            periodicReachabilitySeed: seed
        )
    }

    /// Strict Phase-B capture. The selected entitlement is consumed exactly as
    /// supplied; this method never recomputes viewport reachability. Registry
    /// callers invoke it only after revalidating the immutable epoch identity.
    static func capturing(
        _ selection: SparseTileSourceSelection,
        deinitDiagnostic: @escaping @Sendable () -> Void = {}
    ) throws -> SparseTileOwnedSourceBatch {
        let sources = try selection.restrictedSources()
        let capture = try TiledRasterExactReferenceCapture(
            providers: sources.map(\.provider)
        )
        return Self(
            sources: sources,
            captureAccess: .owned(capture),
            periodicReachabilitySeed: selection.periodicReachabilitySeed,
            deinitDiagnostic: deinitDiagnostic
        )
    }

    /// Strict borrowed Phase-B access for a stable capture. The unforgeable
    /// selection still determines the exact entitlement; the capture validates
    /// that every restricted provider descends from a captured lineage.
    static func borrowing(
        _ selection: SparseTileSourceSelection,
        from capture: TiledRasterExactReferenceCapture,
        deinitDiagnostic: @escaping @Sendable () -> Void = {},
        onTerminal: @escaping @Sendable () -> Void = {}
    ) throws -> SparseTileOwnedSourceBatch {
        let sources = try selection.restrictedSources()
        let borrow = try capture.borrowing(providers: sources.map(\.provider))
        return Self(
            sources: sources,
            captureAccess: .borrowed(borrow),
            periodicReachabilitySeed: selection.periodicReachabilitySeed,
            deinitDiagnostic: deinitDiagnostic,
            onTerminal: onTerminal
        )
    }

    /// Compatibility bridge for call sites that do not yet participate in a
    /// registry epoch. B2b removes those callers in favor of registry-owned
    /// selection and strict capture.
    static func capturingSelection(
        sources: [SparseTileSourceRequest],
        key: SparseTileSamplingPlanKey,
        outputRegion: SparseTileOutputRegion,
        deinitDiagnostic: @escaping @Sendable () -> Void = {}
    ) throws -> SparseTileOwnedSourceBatch {
        try capturing(
            selecting(
                sources: sources,
                key: key,
                outputRegion: outputRegion
            ),
            deinitDiagnostic: deinitDiagnostic
        )
    }

    func beginConsumption() throws -> [SparseTileSourceRequest] {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .fresh:
            state = .inUse
            return sources
        case .inUse:
            throw SparseTileSamplingPlanError.sourceBatchInUse
        case .consumed:
            throw SparseTileSamplingPlanError.sourceBatchConsumed
        }
    }

    func finishConsumption() {
        lock.lock()
        guard state != .consumed else {
            lock.unlock()
            return
        }
        state = .consumed
        let terminalAction = terminalAction
        self.terminalAction = nil
        lock.unlock()
        captureAccess.close()
        terminalAction?()
    }

    func abandon() throws {
        lock.lock()
        switch state {
        case .fresh:
            state = .consumed
            let terminalAction = terminalAction
            self.terminalAction = nil
            lock.unlock()
            captureAccess.close()
            terminalAction?()
        case .inUse:
            lock.unlock()
            throw SparseTileSamplingPlanError.sourceBatchInUse
        case .consumed:
            lock.unlock()
        }
    }

    deinit {
        lock.lock()
        let wasExplicitlyConsumed = state == .consumed
        let terminalAction = terminalAction
        self.terminalAction = nil
        lock.unlock()
        if !wasExplicitlyConsumed {
            deinitDiagnostic()
            captureAccess.close()
            terminalAction?()
        }
    }

    fileprivate func leaseExactReferences(
        _ references: [PaintTileReference],
        from provider: TiledRasterExactReferenceProvider,
        pinReasons: [PaintTilePinReason]
    ) throws -> TiledRasterExactReferenceLease {
        try captureAccess.leaseExactReferences(
            references,
            from: provider,
            pinReasons: pinReasons
        )
    }

}

/// Immutable, normalized metadata used to construct reusable plan content.
/// It intentionally contains no texture or lifetime ownership.
struct SparseTileSourceSnapshot: Sendable {
    let contentKey: SparseTileRoleContentKey
    let addressing: SparseTileAddressing
    let layerID: UUID
    let references: [PaintTileReference]
    let changedCoordinates: [PaintTileCoordinate]
    let disposition: SparseTileSourceDisposition

    init(
        contentKey: SparseTileRoleContentKey,
        addressing: SparseTileAddressing,
        layerID: UUID,
        references: [PaintTileReference],
        changedCoordinates: [PaintTileCoordinate],
        disposition: SparseTileSourceDisposition
    ) throws {
        for index in references.indices {
            let reference = references[index]
            guard reference.layerID == layerID,
                  reference.identity.layerID == layerID,
                  reference.identity.coordinate == reference.coordinate
            else {
                throw SparseTileSamplingPlanError.foreignReference(reference)
            }
            if index > references.startIndex {
                let previous = references[index - 1]
                if previous.coordinate == reference.coordinate {
                    throw SparseTileSamplingPlanError
                        .duplicateReference(reference.coordinate)
                }
                guard previous.coordinate < reference.coordinate else {
                    throw SparseTileSamplingPlanError.unsortedReference
                }
                guard previous.storeIdentity == reference.storeIdentity else {
                    throw SparseTileSamplingPlanError.foreignReference(reference)
                }
            }
        }
        for index in changedCoordinates.indices.dropFirst() {
            let previous = changedCoordinates[index - 1]
            let current = changedCoordinates[index]
            if previous == current {
                throw SparseTileSamplingPlanError
                    .duplicateChangedCoordinate(current)
            }
            guard previous < current else {
                throw SparseTileSamplingPlanError.unsortedChangedCoordinates
            }
        }
        self.contentKey = contentKey
        self.addressing = addressing
        self.layerID = layerID
        self.references = references
        self.changedCoordinates = changedCoordinates
        self.disposition = disposition
    }

    var role: SparseTileSampleRole { contentKey.role }
}

struct SparseTileOutputRegion: Equatable, Hashable, Sendable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
    let width: Int
    let height: Int

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) throws {
        guard maxX > minX, maxY > minY else {
            throw SparseTileSamplingPlanError.invalidOutputRegion
        }
        let (width, widthOverflow) = maxX.subtractingReportingOverflow(minX)
        let (height, heightOverflow) = maxY.subtractingReportingOverflow(minY)
        guard !widthOverflow, !heightOverflow else {
            throw SparseTileSamplingPlanError.arithmeticOverflow
        }
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.width = width
        self.height = height
    }
}

struct SparseTilePlanLimits: Equatable, Sendable {
    let maximumPageEntries: Int
    let maximumPageChunks: Int
    let maximumPageTableBytes: Int
    let maximumBindingSlots: Int
    let maximumBindingChunks: Int
    let maximumBindingBytes: Int
    let maximumTexturesPerBatch: Int
    let maximumBatchCount: Int

    init(
        maximumPageEntries: Int,
        maximumPageChunks: Int,
        maximumPageTableBytes: Int,
        maximumBindingSlots: Int,
        maximumBindingChunks: Int,
        maximumBindingBytes: Int,
        maximumTexturesPerBatch: Int,
        maximumBatchCount: Int
    ) {
        self.maximumPageEntries = maximumPageEntries
        self.maximumPageChunks = maximumPageChunks
        self.maximumPageTableBytes = maximumPageTableBytes
        self.maximumBindingSlots = maximumBindingSlots
        self.maximumBindingChunks = maximumBindingChunks
        self.maximumBindingBytes = maximumBindingBytes
        self.maximumTexturesPerBatch = maximumTexturesPerBatch
        self.maximumBatchCount = maximumBatchCount
    }

    var allValues: [Int] {
        [
            maximumPageEntries, maximumPageChunks, maximumPageTableBytes,
            maximumBindingSlots, maximumBindingChunks, maximumBindingBytes,
            maximumTexturesPerBatch, maximumBatchCount,
        ]
    }
}

struct SparseTilePageEntry: Equatable, Sendable {
    let globalBindingSlot: Int
    let logicalOrigin: SIMD2<Int>
    let physicalOrigin: SIMD2<Int>
    let localBounds: PixelRect

    var isMissing: Bool { globalBindingSlot < 0 }
}

final class SparseTilePageTableChunk: @unchecked Sendable {
    let entries: [SparseTilePageEntry]
    init(entries: [SparseTilePageEntry]) { self.entries = entries }
}

struct SparseTilePageTable: Sendable {
    static let chunkCapacity = 64

    let layerID: UUID
    let role: SparseTileSampleRole
    let origin: PaintTileCoordinate
    let size: PixelSize
    let entryCount: Int
    let chunks: [SparseTilePageTableChunk]

    func entry(at coordinate: PaintTileCoordinate) -> SparseTilePageEntry? {
        let (x, xOverflow) = coordinate.x.subtractingReportingOverflow(origin.x)
        let (y, yOverflow) = coordinate.y.subtractingReportingOverflow(origin.y)
        guard !xOverflow, !yOverflow else { return nil }
        guard x >= 0, y >= 0, x < size.width, y < size.height else {
            return nil
        }
        let (row, rowOverflow) = y.multipliedReportingOverflow(by: size.width)
        let (index, indexOverflow) = row.addingReportingOverflow(x)
        guard !rowOverflow, !indexOverflow else { return nil }
        let chunk = index / Self.chunkCapacity
        let offset = index % Self.chunkCapacity
        guard chunk < chunks.count, offset < chunks[chunk].entries.count else {
            return nil
        }
        return chunks[chunk].entries[offset]
    }
}

struct SparseTileBindingRecord: Hashable, Sendable {
    let globalSlot: Int
    let layerID: UUID
    let role: SparseTileSampleRole
    let reference: PaintTileReference
}

final class SparseTileBindingChunk: @unchecked Sendable {
    let layerID: UUID
    let role: SparseTileSampleRole
    let records: [SparseTileBindingRecord]
    init(
        layerID: UUID,
        role: SparseTileSampleRole,
        records: [SparseTileBindingRecord]
    ) {
        self.layerID = layerID
        self.role = role
        self.records = records
    }
}

struct SparseTileBindingBatch: Equatable, Sendable {
    let outputRegion: SparseTileOutputRegion
    let globalSlots: [Int]
    let compactRemap: [Int: Int]
}

struct SparseTilePlanTelemetry: Equatable, Sendable {
    let rebuiltPageEntryCount: Int
    let rebuiltBindingCount: Int
}

final class SparseTileSamplingPlanContent: @unchecked Sendable {
    let key: SparseTileSamplingPlanKey
    let addressing: SparseTileAddressing
    let outputMapping: SparseTileSamplingOutputMapping
    let pageTables: [SparseTilePageTable]
    let bindingRecords: [SparseTileBindingRecord]
    let bindingChunks: [SparseTileBindingChunk]
    let batches: [SparseTileBindingBatch]
    let telemetry: SparseTilePlanTelemetry
    let outputToSourceTransform: SparseTileOutputToSourceTransform
    let shaderSourceOrigin: SIMD2<Float>
    let sourceFingerprints: [SparseTileSourceFingerprint]
    #if DEBUG
    /// Diagnostic receipt authenticates that prepared layer plans reused their
    /// immutable Phase-A selection. Release contents retain no diagnostic page
    /// set or work receipt.
    fileprivate(set) var periodicReachabilityReceipt:
        SparseTilePeriodicReachabilityReceipt?
    #endif
    fileprivate let outputRegion: SparseTileOutputRegion
    private let recordsBySlot: [Int: SparseTileBindingRecord]

    fileprivate init(
        key: SparseTileSamplingPlanKey,
        addressing: SparseTileAddressing,
        pageTables: [SparseTilePageTable],
        bindingRecords: [SparseTileBindingRecord],
        bindingChunks: [SparseTileBindingChunk],
        batches: [SparseTileBindingBatch],
        telemetry: SparseTilePlanTelemetry,
        outputToSourceTransform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>,
        sourceFingerprints: [SparseTileSourceFingerprint],
        outputRegion: SparseTileOutputRegion
    ) {
        self.key = key
        self.addressing = addressing
        outputMapping = key.outputMapping
        self.pageTables = pageTables
        self.bindingRecords = bindingRecords
        self.bindingChunks = bindingChunks
        self.batches = batches
        self.telemetry = telemetry
        self.outputToSourceTransform = outputToSourceTransform
        self.shaderSourceOrigin = shaderSourceOrigin
        self.sourceFingerprints = sourceFingerprints
        #if DEBUG
        self.periodicReachabilityReceipt = nil
        #endif
        self.outputRegion = outputRegion
        recordsBySlot = Dictionary(
            uniqueKeysWithValues: bindingRecords.map { ($0.globalSlot, $0) }
        )
    }

    func pageTable(
        layerID: UUID,
        role: SparseTileSampleRole
    ) -> SparseTilePageTable? {
        pageTables.first { $0.layerID == layerID && $0.role == role }
    }

    func bindingRecord(at slot: Int) -> SparseTileBindingRecord? {
        recordsBySlot[slot]
    }

    fileprivate func matches(
        slotAssignments: [SparseTileRecordCoordinateKey: Int]
    ) -> Bool {
        guard bindingRecords.count == slotAssignments.count else { return false }
        return bindingRecords.allSatisfy {
            slotAssignments[SparseTileRecordCoordinateKey(
                layerID: $0.layerID,
                role: $0.role,
                coordinate: $0.reference.coordinate
            )] == $0.globalSlot
        }
    }
}

struct SparseTileSourceFingerprint: Equatable, Sendable {
    let layerID: UUID
    let contentKey: SparseTileRoleContentKey
    let addressing: SparseTileAddressing
    let references: [PaintTileReference]
}

struct SparseTileBoundTexture: @unchecked Sendable {
    let globalSlot: Int
    let texture: any MTLTexture
}

private struct SparseTileHeldLease {
    let lease: TiledRasterExactReferenceLease
}

final class SparseTileSamplingPlanConsumerHandle: @unchecked Sendable {
    fileprivate let rawValue: UInt64

    private let lock = NSLock()
    private var owner: SparseTileSamplingPlanLease?
    private var acknowledged = false
    private var completionInProgress = false

    fileprivate init(rawValue: UInt64, owner: SparseTileSamplingPlanLease) {
        self.rawValue = rawValue
        self.owner = owner
    }

    func complete() throws {
        lock.lock()
        guard let owner else {
            lock.unlock()
            throw SparseTileSamplingPlanError.staleConsumer
        }
        lock.unlock()
        try complete(using: owner)
    }

    fileprivate func complete(using expectedOwner: SparseTileSamplingPlanLease)
        throws
    {
        let owner: SparseTileSamplingPlanLease
        let needsAcknowledgement: Bool
        lock.lock()
        guard let retainedOwner = self.owner, retainedOwner === expectedOwner,
              !completionInProgress
        else {
            lock.unlock()
            throw SparseTileSamplingPlanError.staleConsumer
        }
        completionInProgress = true
        owner = retainedOwner
        needsAcknowledgement = !acknowledged
        lock.unlock()

        do {
            if needsAcknowledgement {
                try owner.acknowledgeConsumer(rawValue)
                lock.lock()
                acknowledged = true
                lock.unlock()
            }
            try owner.retryRetirementIfReady()
            lock.lock()
            self.owner = nil
            completionInProgress = false
            lock.unlock()
        } catch {
            lock.lock()
            completionInProgress = false
            lock.unlock()
            throw error
        }
    }

    deinit {
        lock.lock()
        guard let owner, !completionInProgress else {
            lock.unlock()
            return
        }
        let needsAcknowledgement = !acknowledged
        completionInProgress = true
        lock.unlock()
        if needsAcknowledgement { try? owner.acknowledgeConsumer(rawValue) }
        try? owner.retryRetirementIfReady()
    }
}

typealias SparseTileLeaseReturner = @Sendable (
    TiledRasterExactReferenceLease
) throws -> Void

/// Cache-owned retirement state. It deliberately outlives the public lease:
/// failed store returns remain pinned and retryable instead of being forgotten
/// by a deinitializer that cannot throw.
private final class SparseTileLeaseRetirementCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var heldLeases: [SparseTileHeldLease]
    private var retirementRequested = false
    private var retirementInProgress = false
    private var completed = false
    private let returnLease: SparseTileLeaseReturner
    private let onFullyReturned: @Sendable () throws -> Void

    init(
        heldLeases: [SparseTileHeldLease],
        returnLease: @escaping SparseTileLeaseReturner,
        onFullyReturned: @escaping @Sendable () throws -> Void
    ) {
        self.heldLeases = heldLeases
        self.returnLease = returnLease
        self.onFullyReturned = onFullyReturned
    }

    /// Installs ownership immediately after each exact lease is acquired.
    /// No throwable operation may occur between acquisition and this append.
    func append(_ heldLease: SparseTileHeldLease) {
        lock.lock()
        precondition(
            !retirementRequested && !retirementInProgress && !completed,
            "cannot append after sparse retirement begins"
        )
        heldLeases.append(heldLease)
        lock.unlock()
    }

    func requestRetirement() throws -> Bool {
        lock.lock()
        retirementRequested = true
        lock.unlock()
        return try retryIfRequested()
    }

    func retryIfRequested() throws -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            return true
        }
        guard retirementRequested, !retirementInProgress else {
            lock.unlock()
            return false
        }
        retirementInProgress = true
        lock.unlock()

        do {
            while true {
                lock.lock()
                let value = heldLeases.last
                lock.unlock()
                guard let value else { break }

                try returnLease(value.lease)
                lock.lock()
                guard heldLeases.last?.lease === value.lease else {
                    retirementInProgress = false
                    lock.unlock()
                    throw SparseTileSamplingPlanError.staleConsumer
                }
                heldLeases.removeLast()
                lock.unlock()
            }

            // The cache callback runs after the coordinator lock is released.
            // It removes exactly this opaque owner and cannot ABA-reuse it.
            try onFullyReturned()
            lock.lock()
            completed = true
            retirementInProgress = false
            lock.unlock()
            return true
        } catch {
            lock.lock()
            retirementInProgress = false
            lock.unlock()
            throw error
        }
    }
}

final class SparseTileSamplingPlanLease: @unchecked Sendable {
    let content: SparseTileSamplingPlanContent
    let boundTextures: [SparseTileBoundTexture]

    private let lock = NSLock()
    private var consumers: Set<UInt64> = []
    private var nextConsumerID: UInt64 = 0
    private var retirementRequested = false
    private var retirementCompleted = false
    private let retirement: SparseTileLeaseRetirementCoordinator

    fileprivate init(
        content: SparseTileSamplingPlanContent,
        boundTextures: [SparseTileBoundTexture],
        retirement: SparseTileLeaseRetirementCoordinator
    ) {
        self.content = content
        self.boundTextures = boundTextures
        self.retirement = retirement
    }

    func retire() throws {
        lock.lock()
        guard !retirementCompleted else {
            lock.unlock()
            throw SparseTileSamplingPlanError.leaseAlreadyRetired
        }
        retirementRequested = true
        lock.unlock()
        try retryRetirementIfReady()
    }

    func beginConsumer() throws -> SparseTileSamplingPlanConsumerHandle {
        lock.lock()
        defer { lock.unlock() }
        guard !retirementRequested, !retirementCompleted else {
            throw SparseTileSamplingPlanError.leaseRetirementRequested
        }
        guard nextConsumerID < UInt64.max else {
            throw SparseTileSamplingPlanError.consumerIdentityOverflow
        }
        nextConsumerID += 1
        consumers.insert(nextConsumerID)
        return SparseTileSamplingPlanConsumerHandle(
            rawValue: nextConsumerID,
            owner: self
        )
    }

    func completeConsumer(_ handle: SparseTileSamplingPlanConsumerHandle) throws {
        try handle.complete(using: self)
    }

    fileprivate func acknowledgeConsumer(_ consumerID: UInt64) throws {
        lock.lock()
        guard consumers.remove(consumerID) != nil else {
            lock.unlock()
            throw SparseTileSamplingPlanError.staleConsumer
        }
        lock.unlock()
    }

    fileprivate func retryRetirementIfReady() throws {
        lock.lock()
        guard retirementRequested, consumers.isEmpty, !retirementCompleted else {
            lock.unlock()
            return
        }
        lock.unlock()
        let completed = try retirement.requestRetirement()
        if completed {
            lock.lock()
            retirementCompleted = true
            lock.unlock()
        }
    }

    deinit {
        lock.lock()
        retirementRequested = true
        consumers.removeAll(keepingCapacity: false)
        lock.unlock()
        _ = try? retirement.requestRetirement()
    }
}

private struct SparseTileSlotOwnerID: Hashable, Sendable {
    let rawValue: UInt64
}

private struct SparseTileLiveSlotEntry {
    let slot: Int
    var owners: Set<SparseTileSlotOwnerID>
}

private enum SparseTileSlotOwnerState: Equatable {
    case pending
    case live
}

private struct SparseTileSlotOwnerRecord {
    let generation: UInt64
    let generationEpoch: SparseTileGenerationEpoch
    let coordinateKeys: [SparseTileRecordCoordinateKey]
    var state: SparseTileSlotOwnerState
}

private final class SparseTileGenerationEpoch: @unchecked Sendable {}

private struct SparseTilePendingSlotReservation {
    let ownerID: SparseTileSlotOwnerID
    let assignments: [SparseTileRecordCoordinateKey: Int]
}

/// CPU content identity. The logical plan key intentionally remains unchanged
/// inside content/shader-facing metadata; output-region chunking is a cache
/// concern and must not be smuggled through a fake geometry revision.
private struct SparseTileSamplingPlanCacheIdentity: Hashable, Sendable {
    let logicalKey: SparseTileSamplingPlanKey
    let outputRegion: SparseTileOutputRegion
}

private final class SparseTileContentEpoch: @unchecked Sendable {}

private struct SparseTileActiveContentAcquisition {
    var epoch: SparseTileContentEpoch
    var count: Int
}

struct SparseTileSamplingPlanCacheSnapshot: Equatable, Sendable {
    let cachedContentCount: Int
    let activeContentAcquisitionCount: Int
    let pendingRetirementCount: Int
    let hitCount: UInt64
    let missCount: UInt64

    init(
        cachedContentCount: Int,
        activeContentAcquisitionCount: Int,
        pendingRetirementCount: Int,
        hitCount: UInt64 = 0,
        missCount: UInt64 = 0
    ) {
        self.cachedContentCount = cachedContentCount
        self.activeContentAcquisitionCount = activeContentAcquisitionCount
        self.pendingRetirementCount = pendingRetirementCount
        self.hitCount = hitCount
        self.missCount = missCount
    }
}

final class SparseTileSamplingPlanCache: @unchecked Sendable {
    private let lock = NSLock()
    private var contents:
        [SparseTileSamplingPlanCacheIdentity: SparseTileSamplingPlanContent] = [:]
    private var activeContentAcquisitions:
        [SparseTileSamplingPlanCacheIdentity:
            SparseTileActiveContentAcquisition] = [:]
    private var liveSlots: [UInt64:
        [SparseTileRecordCoordinateKey: SparseTileLiveSlotEntry]] = [:]
    private var generationEpochs: [UInt64: SparseTileGenerationEpoch] = [:]
    private var slotOwners: [SparseTileSlotOwnerID: SparseTileSlotOwnerRecord]
        = [:]
    private var retirements: [SparseTileSlotOwnerID:
        SparseTileLeaseRetirementCoordinator] = [:]
    private var nextSlotOwnerID: UInt64 = 1
    private var hitCount: UInt64 = 0
    private var missCount: UInt64 = 0
    private let returnLease: SparseTileLeaseReturner
    private let afterSlotReservation: @Sendable () -> Void
    private let beforePublication: @Sendable () -> Void
    private let sourceLeaseFailureInjector: @Sendable (Int) throws -> Void
    private let boundTextureFailureInjector: @Sendable () throws -> Void
    private let afterContentPublication: @Sendable () throws -> Void
    private let maximumPeriodicReachabilityWork: Int
    #if DEBUG
    private var lastPeriodicReachabilityReceipt:
        SparseTilePeriodicReachabilityReceipt?
    #endif

    init(
        returnLease: @escaping SparseTileLeaseReturner = { lease in
            try lease.returnLease()
        },
        afterSlotReservation: @escaping @Sendable () -> Void = {},
        beforePublication: @escaping @Sendable () -> Void = {},
        sourceLeaseFailureInjector:
            @escaping @Sendable (Int) throws -> Void = { _ in },
        boundTextureFailureInjector:
            @escaping @Sendable () throws -> Void = {},
        afterContentPublication:
            @escaping @Sendable () throws -> Void = {},
        maximumPeriodicReachabilityWork: Int = 250_000
    ) {
        self.returnLease = returnLease
        self.afterSlotReservation = afterSlotReservation
        self.beforePublication = beforePublication
        self.sourceLeaseFailureInjector = sourceLeaseFailureInjector
        self.boundTextureFailureInjector = boundTextureFailureInjector
        self.afterContentPublication = afterContentPublication
        self.maximumPeriodicReachabilityWork =
            maximumPeriodicReachabilityWork
    }

    func acquire(
        key: SparseTileSamplingPlanKey,
        sourceBatch: SparseTileOwnedSourceBatch,
        outputRegion: SparseTileOutputRegion,
        limits: SparseTilePlanLimits,
        updating previous: SparseTileSamplingPlanContent? = nil
    ) throws -> SparseTileSamplingPlanLease {
        let cacheIdentity = SparseTileSamplingPlanCacheIdentity(
            logicalKey: key,
            outputRegion: outputRegion
        )
        let eligiblePrevious = previous?.outputRegion == outputRegion
            ? previous
            : nil
        let contentEpoch = beginContentAcquisition(for: cacheIdentity)
        defer { finishContentAcquisition(for: cacheIdentity) }
        let sources = try sourceBatch.beginConsumption()
        defer { sourceBatch.finishConsumption() }
        try Self.validate(key: key, sources: sources, limits: limits)
        let metadata = try sources.map {
            try SparseTileSourceSnapshot(
                contentKey: $0.contentKey,
                addressing: $0.addressing,
                layerID: $0.layerID,
                references: $0.references,
                changedCoordinates: $0.changedCoordinates,
                disposition: $0.disposition
            )
        }
        let sourceFingerprints = metadata.fingerprints
        let periodicReachabilityAuthority = try SparseTileSamplingPlanBuilder
            .makePeriodicReachabilityAuthority(
                key: key,
                addressing: metadata[0].addressing,
                outputRegion: outputRegion,
                maximumWork: maximumPeriodicReachabilityWork,
                seed: sourceBatch.periodicReachabilitySeed
            )
        // Selection is deliberately complete before the cache lock and slot
        // reservation. Full metadata remains the cache/collision identity;
        // only viewport-reachable physical references consume live resources.
        let selectedMetadata = try SparseTileSamplingPlanBuilder
            .selectingPhysicalReferences(
                key: key,
                sources: metadata,
                outputRegion: outputRegion,
                periodicReachabilityAuthority:
                    periodicReachabilityAuthority
            )
        for (sourceIndex, pair) in zip(
            sources,
            selectedMetadata
        ).enumerated() where
            pair.0.provider.entitledReferences != pair.1.references
        {
            throw SparseTileSamplingPlanError
                .sourceBatchSelectionMismatch(sourceIndex: sourceIndex)
        }

        let cachedBeforeBuild: SparseTileSamplingPlanContent?
        let reservation: SparseTilePendingSlotReservation
        lock.lock()
        do {
            cachedBeforeBuild = contents[cacheIdentity]
            if let cachedBeforeBuild {
                hitCount = Self.saturatingIncrement(hitCount)
                guard cachedBeforeBuild.sourceFingerprints == sourceFingerprints
                else {
                    throw SparseTileSamplingPlanError.contentKeyCollision
                }
            } else {
                missCount = Self.saturatingIncrement(missCount)
            }
            reservation = try reserveSlotsLocked(
                generation: key.documentGeneration,
                sources: selectedMetadata,
                maximum: min(limits.maximumBindingSlots, 512),
                previous: previous
            )
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        afterSlotReservation()

        // From this point onward one cache-owned coordinator is the rollback
        // authority for both the pending slot reservation and every exact tile
        // lease. It is installed before any build/acquisition step can throw.
        let retirement = SparseTileLeaseRetirementCoordinator(
            heldLeases: [],
            returnLease: returnLease,
            onFullyReturned: { [self] in
                try finishRetirement(reservation.ownerID)
            }
        )
        do {
            try registerPendingRetirement(
                reservation.ownerID,
                retirement: retirement
            )
        } catch {
            // Registration follows reservation without an intervening await or
            // owner mutation. A cancellation failure here is an internal cache
            // integrity violation; never hide it and continue with leaked slots.
            do {
                try cancelSlotOwner(reservation.ownerID)
            } catch {
                preconditionFailure(
                    "sparse pending owner could neither register nor cancel"
                )
            }
            throw error
        }

        let candidate: SparseTileSamplingPlanContent
        if let cachedBeforeBuild,
           cachedBeforeBuild.matches(slotAssignments: reservation.assignments),
           Self.content(cachedBeforeBuild, satisfies: limits) {
            candidate = cachedBeforeBuild
        } else {
            do {
                candidate = try SparseTileSamplingPlanBuilder.buildSelected(
                    key: key,
                    sources: selectedMetadata,
                    sourceFingerprints: sourceFingerprints,
                    outputRegion: outputRegion,
                    limits: limits,
                    previous: cachedBeforeBuild ?? eligiblePrevious,
                    slotAssignments: reservation.assignments,
                    periodicReachabilityAuthority:
                        periodicReachabilityAuthority
                )
            } catch {
                _ = try retirement.requestRetirement()
                throw error
            }
        }
        #if DEBUG
        if let periodicReachabilityAuthority {
            let receipt = SparseTileSamplingPlanBuilder
                .periodicReachabilityReceipt(
                    from: periodicReachabilityAuthority
                )
            lock.lock()
            lastPeriodicReachabilityReceipt = receipt
            lock.unlock()
        }
        #endif

        var acquired: [(request: SparseTileSourceRequest,
                        references: [PaintTileReference],
                        bindings: [PaintTileBinding])] = []
        var installedCandidate = false
        var displacedContent: SparseTileSamplingPlanContent?
        do {
            try ensureSlotOwnerCurrent(reservation.ownerID)
            for (sourceIndex, pair) in zip(sources, selectedMetadata).enumerated() {
                let (request, snapshot) = pair
                let selectedReferences = snapshot.references
                if selectedReferences.isEmpty {
                    acquired.append((request, [], []))
                    continue
                }
                try sourceLeaseFailureInjector(sourceIndex)
                let lease = try sourceBatch.leaseExactReferences(
                    selectedReferences,
                    from: request.provider,
                    pinReasons: [.visible, .inFlight]
                )
                retirement.append(.init(lease: lease))
                acquired.append((request, selectedReferences, lease.bindings))
            }

            let textures = try Self.boundTextures(
                content: candidate,
                acquired: acquired
            )
            try boundTextureFailureInjector()
            // Pins now own every selected physical tile. Drop aggregate
            // snapshot retention before any reusable content or live slot
            // owner becomes observable.
            sourceBatch.finishConsumption()
            beforePublication()

            let selected: SparseTileSamplingPlanContent
            lock.lock()
            do {
                try ensureSlotOwnerCurrentLocked(reservation.ownerID)
                if activeContentAcquisitions[cacheIdentity]?.epoch
                    !== contentEpoch
                {
                    // An exact eviction linearized after this acquisition
                    // began. The lease may finish, but stale work cannot undo
                    // that eviction by repopulating CPU cache state.
                    selected = candidate
                } else if let raced = contents[cacheIdentity] {
                    guard raced.sourceFingerprints == sourceFingerprints
                    else {
                        throw SparseTileSamplingPlanError.contentKeyCollision
                    }
                    if raced.matches(slotAssignments: reservation.assignments),
                       Self.content(raced, satisfies: limits) {
                        selected = raced
                    } else {
                        displacedContent = raced
                        contents[cacheIdentity] = candidate
                        installedCandidate = true
                        selected = candidate
                    }
                } else {
                    contents[cacheIdentity] = candidate
                    installedCandidate = true
                    selected = candidate
                }
                lock.unlock()
            } catch {
                lock.unlock()
                throw error
            }
            try afterContentPublication()

            try publishSlotOwner(reservation.ownerID, retirement: retirement)
            return SparseTileSamplingPlanLease(
                content: selected,
                boundTextures: textures,
                retirement: retirement
            )
        } catch {
            sourceBatch.finishConsumption()
            if installedCandidate {
                lock.lock()
                if contents[cacheIdentity] === candidate {
                    if let displacedContent {
                        contents[cacheIdentity] = displacedContent
                    } else {
                        contents.removeValue(forKey: cacheIdentity)
                    }
                }
                lock.unlock()
            }
            do {
                _ = try retirement.requestRetirement()
            } catch {
                // The coordinator is already cache-owned and retryable. Surface
                // cleanup failure rather than dropping the original exact leases.
                throw error
            }
            throw error
        }
    }

    func invalidate(documentGeneration: UInt64) {
        lock.lock()
        contents = contents.filter {
            $0.key.logicalKey.documentGeneration != documentGeneration
        }
        for (identity, var active) in activeContentAcquisitions
        where identity.logicalKey.documentGeneration == documentGeneration {
            active.epoch = SparseTileContentEpoch()
            activeContentAcquisitions[identity] = active
        }
        generationEpochs[documentGeneration] = SparseTileGenerationEpoch()
        lock.unlock()
    }

    /// Drops only one CPU content entry. Live leases and neighboring output
    /// regions remain independently owned; a later request rebuilds this exact
    /// compound identity.
    @discardableResult
    func evictContent(
        key: SparseTileSamplingPlanKey,
        outputRegion: SparseTileOutputRegion
    ) -> Bool {
        lock.lock()
        let identity = SparseTileSamplingPlanCacheIdentity(
            logicalKey: key,
            outputRegion: outputRegion
        )
        let removed = contents.removeValue(forKey: identity) != nil
        if var active = activeContentAcquisitions[identity] {
            active.epoch = SparseTileContentEpoch()
            activeContentAcquisitions[identity] = active
        }
        lock.unlock()
        return removed
    }

    #if DEBUG
    var testingActiveContentIdentityCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeContentAcquisitions.count
    }

    var testingLastPeriodicReachabilityReceipt:
        SparseTilePeriodicReachabilityReceipt?
    {
        lock.lock()
        defer { lock.unlock() }
        return lastPeriodicReachabilityReceipt
    }
    #endif

    private func beginContentAcquisition(
        for identity: SparseTileSamplingPlanCacheIdentity
    ) -> SparseTileContentEpoch {
        lock.lock()
        var active = activeContentAcquisitions[identity]
            ?? SparseTileActiveContentAcquisition(
                epoch: SparseTileContentEpoch(),
                count: 0
            )
        precondition(active.count < Int.max)
        active.count += 1
        activeContentAcquisitions[identity] = active
        lock.unlock()
        return active.epoch
    }

    private func finishContentAcquisition(
        for identity: SparseTileSamplingPlanCacheIdentity
    ) {
        lock.lock()
        guard var active = activeContentAcquisitions[identity],
              active.count > 0
        else {
            lock.unlock()
            preconditionFailure("missing sparse content acquisition")
        }
        active.count -= 1
        if active.count == 0 {
            activeContentAcquisitions.removeValue(forKey: identity)
        } else {
            activeContentAcquisitions[identity] = active
        }
        lock.unlock()
    }

    /// Retries cache-owned retirement state left by a fallible tile-store
    /// return. Active leases are skipped; failed leases remain registered.
    func retryPendingRetirements() throws {
        lock.lock()
        let snapshot = Array(retirements.values)
        lock.unlock()
        var firstError: (any Error)?
        for retirement in snapshot {
            do {
                _ = try retirement.retryIfRequested()
            } catch where firstError == nil {
                firstError = error
            } catch {}
        }
        if let firstError { throw firstError }
    }

    var pendingRetirementCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retirements.count
    }

    func snapshot() -> SparseTileSamplingPlanCacheSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var activeAcquisitionCount = 0
        for acquisition in activeContentAcquisitions.values {
            let (sum, overflow) = activeAcquisitionCount
                .addingReportingOverflow(acquisition.count)
            precondition(!overflow)
            activeAcquisitionCount = sum
        }
        return SparseTileSamplingPlanCacheSnapshot(
            cachedContentCount: contents.count,
            activeContentAcquisitionCount: activeAcquisitionCount,
            pendingRetirementCount: retirements.count,
            hitCount: hitCount,
            missCount: missCount
        )
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private func reserveSlotsLocked(
        generation: UInt64,
        sources: [SparseTileSourceSnapshot],
        maximum: Int,
        previous: SparseTileSamplingPlanContent?
    ) throws -> SparseTilePendingSlotReservation {
        guard maximum > 0 else {
            throw SparseTileSamplingPlanError.invalidLimit
        }
        let coordinateKeys = sources.flatMap { source in
            source.references.map {
                SparseTileRecordCoordinateKey(
                    layerID: source.layerID,
                    role: source.role,
                    coordinate: $0.coordinate
                )
            }
        }
        var entries = liveSlots[generation] ?? [:]
        let generationEpoch: SparseTileGenerationEpoch
        if let current = generationEpochs[generation] {
            generationEpoch = current
        } else {
            let initial = SparseTileGenerationEpoch()
            generationEpochs[generation] = initial
            generationEpoch = initial
        }
        var occupiedBySlot = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.value.slot, $0.key) }
        )
        let previousAssignments = Dictionary(
            uniqueKeysWithValues: (previous?.bindingRecords ?? []).map {
                (SparseTileRecordCoordinateKey(
                    layerID: $0.layerID,
                    role: $0.role,
                    coordinate: $0.reference.coordinate
                ), $0.globalSlot)
            }
        )
        for (coordinateKey, slot) in previousAssignments {
            guard slot >= 0, slot < maximum else {
                let required = slot == Int.max ? Int.max : max(0, slot) + 1
                throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                    required: required,
                    maximum: maximum
                )
            }
            if let occupiedCoordinate = occupiedBySlot[slot],
               occupiedCoordinate != coordinateKey {
                throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                    required: occupiedBySlot.count + 1,
                    maximum: maximum
                )
            }
            occupiedBySlot[slot] = coordinateKey
        }
        var assignments: [SparseTileRecordCoordinateKey: Int] = [:]
        for coordinateKey in coordinateKeys {
            if let existing = entries[coordinateKey] {
                guard existing.slot < maximum else {
                    throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                        required: existing.slot + 1,
                        maximum: maximum
                    )
                }
                assignments[coordinateKey] = existing.slot
                continue
            }
            if let previousSlot = previousAssignments[coordinateKey] {
                entries[coordinateKey] = SparseTileLiveSlotEntry(
                    slot: previousSlot,
                    owners: []
                )
                assignments[coordinateKey] = previousSlot
                continue
            }
            var slot = 0
            while slot < maximum, occupiedBySlot[slot] != nil { slot += 1 }
            guard slot < maximum else {
                throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                    required: occupiedBySlot.count + 1,
                    maximum: maximum
                )
            }
            occupiedBySlot[slot] = coordinateKey
            entries[coordinateKey] = SparseTileLiveSlotEntry(
                slot: slot,
                owners: []
            )
            assignments[coordinateKey] = slot
        }
        guard nextSlotOwnerID < UInt64.max else {
            throw SparseTileSamplingPlanError.slotOwnerIdentityOverflow
        }
        let ownerID = SparseTileSlotOwnerID(rawValue: nextSlotOwnerID)
        nextSlotOwnerID += 1
        for coordinateKey in coordinateKeys {
            entries[coordinateKey]!.owners.insert(ownerID)
        }
        liveSlots[generation] = entries
        slotOwners[ownerID] = SparseTileSlotOwnerRecord(
            generation: generation,
            generationEpoch: generationEpoch,
            coordinateKeys: coordinateKeys,
            state: .pending
        )
        return SparseTilePendingSlotReservation(
            ownerID: ownerID,
            assignments: assignments
        )
    }

    private func publishSlotOwner(
        _ ownerID: SparseTileSlotOwnerID,
        retirement: SparseTileLeaseRetirementCoordinator
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var owner = slotOwners[ownerID], owner.state == .pending,
              generationEpochs[owner.generation] === owner.generationEpoch,
              retirements[ownerID] === retirement
        else {
            throw SparseTileSamplingPlanError.staleSlotOwner
        }
        owner.state = .live
        slotOwners[ownerID] = owner
    }

    private func registerPendingRetirement(
        _ ownerID: SparseTileSlotOwnerID,
        retirement: SparseTileLeaseRetirementCoordinator
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard slotOwners[ownerID]?.state == .pending,
              retirements[ownerID] == nil
        else { throw SparseTileSamplingPlanError.staleSlotOwner }
        retirements[ownerID] = retirement
    }

    private func ensureSlotOwnerCurrent(_ ownerID: SparseTileSlotOwnerID) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureSlotOwnerCurrentLocked(ownerID)
    }

    private func ensureSlotOwnerCurrentLocked(
        _ ownerID: SparseTileSlotOwnerID
    ) throws {
        guard let owner = slotOwners[ownerID], owner.state == .pending,
              generationEpochs[owner.generation] === owner.generationEpoch
        else { throw SparseTileSamplingPlanError.staleSlotOwner }
    }

    private func cancelSlotOwner(_ ownerID: SparseTileSlotOwnerID) throws {
        try removeSlotOwner(ownerID, expected: .pending)
    }

    private func removeSlotOwner(
        _ ownerID: SparseTileSlotOwnerID,
        expected: SparseTileSlotOwnerState
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try removeSlotOwnerLocked(ownerID, expected: expected)
    }

    private func finishRetirement(_ ownerID: SparseTileSlotOwnerID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard retirements[ownerID] != nil,
              let owner = slotOwners[ownerID]
        else { throw SparseTileSamplingPlanError.staleSlotOwner }
        try removeSlotOwnerLocked(ownerID, expected: owner.state)
        retirements.removeValue(forKey: ownerID)
    }

    private func removeSlotOwnerLocked(
        _ ownerID: SparseTileSlotOwnerID,
        expected: SparseTileSlotOwnerState
    ) throws {
        guard let owner = slotOwners[ownerID], owner.state == expected else {
            throw SparseTileSamplingPlanError.staleSlotOwner
        }
        var entries = liveSlots[owner.generation] ?? [:]
        for coordinateKey in owner.coordinateKeys {
            guard var entry = entries[coordinateKey],
                  entry.owners.remove(ownerID) != nil
            else { throw SparseTileSamplingPlanError.staleSlotOwner }
            if entry.owners.isEmpty {
                entries.removeValue(forKey: coordinateKey)
            } else {
                entries[coordinateKey] = entry
            }
        }
        if entries.isEmpty {
            liveSlots.removeValue(forKey: owner.generation)
        } else {
            liveSlots[owner.generation] = entries
        }
        slotOwners.removeValue(forKey: ownerID)
    }

    private static func content(
        _ content: SparseTileSamplingPlanContent,
        satisfies limits: SparseTilePlanLimits
    ) -> Bool {
        var pageEntries = 0
        var pageChunks = 0
        for table in content.pageTables {
            let (entries, entryOverflow) = pageEntries.addingReportingOverflow(
                table.entryCount
            )
            let (chunks, chunkOverflow) = pageChunks.addingReportingOverflow(
                table.chunks.count
            )
            guard !entryOverflow, !chunkOverflow else { return false }
            pageEntries = entries
            pageChunks = chunks
        }
        guard pageEntries <= limits.maximumPageEntries,
              pageChunks <= limits.maximumPageChunks,
              pageEntries <= limits.maximumPageTableBytes / 32,
              content.bindingRecords.count <= limits.maximumBindingSlots,
              content.bindingRecords.count <= limits.maximumBindingBytes / 64,
              content.bindingChunks.count <= limits.maximumBindingChunks,
              content.batches.count <= limits.maximumBatchCount,
              content.bindingRecords.allSatisfy({
                  $0.globalSlot >= 0
                      && $0.globalSlot < min(limits.maximumBindingSlots, 512)
              }),
              content.batches.allSatisfy({
                  $0.globalSlots.count <= limits.maximumTexturesPerBatch
              })
        else { return false }
        return true
    }

    private static func validate(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceRequest],
        limits: SparseTilePlanLimits
    ) throws {
        guard limits.allValues.allSatisfy({ $0 > 0 }) else {
            throw SparseTileSamplingPlanError.invalidLimit
        }
        guard !sources.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        let addressing = sources[0].addressing
        guard sources.allSatisfy({ $0.addressing == addressing }) else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        var expected: [(UUID, SparseTileRoleContentKey)] = []
        var seenLayerIDs: Set<UUID> = []
        for layer in key.orderedLayers {
            guard seenLayerIDs.insert(layer.layerID).inserted else {
                throw SparseTileSamplingPlanError.duplicateLayer(layer.layerID)
            }
            var previousRole: SparseTileSampleRole?
            for role in layer.roles {
                guard previousRole.map({ $0.rawValue < role.role.rawValue })
                        ?? true
                else {
                    throw SparseTileSamplingPlanError.contentRoleMismatch
                }
                previousRole = role.role
                expected.append((layer.layerID, role))
            }
        }
        let actual = sources.map { ($0.layerID, $0.contentKey) }
        guard expected.count == actual.count else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        for index in expected.indices {
            guard expected[index].0 == actual[index].0,
                  expected[index].1 == actual[index].1
            else { throw SparseTileSamplingPlanError.sourceOrderMismatch }
        }
        var seen: Set<String> = []
        for source in sources {
            let token = source.layerID.uuidString + ":" + String(source.role.rawValue)
            guard seen.insert(token).inserted else {
                throw SparseTileSamplingPlanError.duplicateSource(
                    layerID: source.layerID,
                    role: source.role
                )
            }
        }
    }

    private static func boundTextures(
        content: SparseTileSamplingPlanContent,
        acquired: [(request: SparseTileSourceRequest,
                    references: [PaintTileReference],
                    bindings: [PaintTileBinding])]
    ) throws -> [SparseTileBoundTexture] {
        var byReference: [PaintTileReference: any MTLTexture] = [:]
        for source in acquired {
            guard source.references.count == source.bindings.count else {
                throw SparseTileSamplingPlanError.bindingCountMismatch(
                    references: source.references.count,
                    bindings: source.bindings.count
                )
            }
            for (reference, binding) in zip(
                source.references, source.bindings
            ) {
                guard reference.identity == binding.identity,
                      reference.descriptor == binding.descriptor
                else {
                    throw SparseTileSamplingPlanError.missingBinding(reference)
                }
                byReference[reference] = binding.texture
            }
        }
        return try content.bindingRecords.map { record in
            guard let texture = byReference[record.reference] else {
                throw SparseTileSamplingPlanError.missingBinding(record.reference)
            }
            return SparseTileBoundTexture(
                globalSlot: record.globalSlot,
                texture: texture
            )
        }
    }
}

enum SparseTileAcceptedSourceAdapter {
    static func canonical(
        _ binding: DocumentPaintLayerBinding,
        addressing: SparseTileAddressing
    ) throws -> SparseTileSourceRequest {
        let references = binding.canonical.references
        let revision = binding.canonical.revision.rawValue
        return try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                surfaceIdentity: binding.canonical.surfaceID,
                contentRevision: revision,
                bindingChunkRevision: revision
            ),
            addressing: addressing,
            provider: binding.canonical.makeExactReferenceProvider(),
            changedCoordinates: references.map(\.coordinate),
            disposition: .fullSnapshot
        )
    }

    static func transient(
        layerID: UUID,
        authoritative: TiledRasterSurface,
        prediction: TiledRasterSurface,
        changedRole: StrokePrivateSurfaceLayer,
        changedCoordinates: [PaintTileCoordinate],
        addressing: SparseTileAddressing,
        disposition: SparseTileSourceDisposition = .delta
    ) throws -> [SparseTileSourceRequest] {
        guard authoritative.layerID == layerID else {
            throw SparseTileSamplingPlanError.sourceLayerMismatch(
                expected: layerID, actual: authoritative.layerID
            )
        }
        guard prediction.layerID == layerID else {
            throw SparseTileSamplingPlanError.sourceLayerMismatch(
                expected: layerID, actual: prediction.layerID
            )
        }
        guard authoritative.generation == prediction.generation else {
            throw SparseTileSamplingPlanError.sourceGenerationMismatch(
                expected: authoritative.generation,
                actual: prediction.generation
            )
        }
        guard authoritative.pixelSize == prediction.pixelSize else {
            throw SparseTileSamplingPlanError.sourcePixelSizeMismatch
        }
        let sortedChanges = changedCoordinates.sorted()
        let authoritativeChanges = disposition == .fullSnapshot
            ? authoritative.references.map(\.coordinate).sorted()
            : (changedRole == .authoritative ? sortedChanges : [])
        let predictionChanges = disposition == .fullSnapshot
            ? prediction.references.map(\.coordinate).sorted()
            : (changedRole == .prediction ? sortedChanges : [])
        let authoritativeRevision = authoritative.revision.rawValue
        let predictionRevision = prediction.revision.rawValue
        return [
            try SparseTileSourceRequest(
                contentKey: SparseTileRoleContentKey(
                    role: .authoritative,
                    surfaceIdentity: authoritative.surfaceID,
                    contentRevision: authoritativeRevision,
                    bindingChunkRevision: authoritativeRevision
                ),
                addressing: addressing,
                provider: authoritative.makeExactReferenceProvider(),
                changedCoordinates: authoritativeChanges,
                disposition: disposition
            ),
            try SparseTileSourceRequest(
                contentKey: SparseTileRoleContentKey(
                    role: .prediction,
                    surfaceIdentity: prediction.surfaceID,
                    contentRevision: predictionRevision,
                    bindingChunkRevision: predictionRevision
                ),
                addressing: addressing,
                provider: prediction.makeExactReferenceProvider(),
                changedCoordinates: predictionChanges,
                disposition: disposition
            ),
        ]
    }

}

extension DocumentPaintLayerBinding {
    func sparseTileSourceRequest(
        addressing: SparseTileAddressing
    ) throws -> SparseTileSourceRequest {
        try SparseTileAcceptedSourceAdapter.canonical(
            self, addressing: addressing
        )
    }
}

private extension Array where Element == SparseTileSourceSnapshot {
    var fingerprints: [SparseTileSourceFingerprint] {
        map {
            SparseTileSourceFingerprint(
                layerID: $0.layerID,
                contentKey: $0.contentKey,
                addressing: $0.addressing,
                references: $0.references
            )
        }
    }
}

struct SparseTileRecordCoordinateKey: Hashable {
    let layerID: UUID
    let role: SparseTileSampleRole
    let coordinate: PaintTileCoordinate
}

private struct SparseTilePageTableGeometry {
    let origin: PaintTileCoordinate
    let size: PixelSize
    let entryCount: Int
    let chunkCount: Int
}

enum SparseTilePlanAllocationKind: Sendable {
    case bindingRecords
    case bindingChunks
    case pageEntries
}

struct SparseTilePeriodicReachabilityReceipt: Equatable, Sendable {
    let physicalPages: Set<PaintTileCoordinate>
    let visitedNodeCount: Int
    let subdivisionCount: Int
    let enumeratedPixelCenterCount: Int
    let singlePageFastPathCount: Int
    let axisSweepPixelCenterCount: Int
    let cacheHitCount: Int
    let phaseAWorkCount: Int
    let acquisitionWorkCount: Int
    let workCount: Int
}

private final class SparseTilePeriodicReachabilityDiagnostics {
    var visitedNodeCount = 0
    var subdivisionCount = 0
    var enumeratedPixelCenterCount = 0
    var singlePageFastPathCount = 0
    var axisSweepPixelCenterCount = 0
}

struct SparseTilePeriodicReachabilitySeed: Sendable {
    fileprivate let outputRegion: SparseTileOutputRegion
    fileprivate let mapping: SparseTilePeriodicOutputMapping
    fileprivate let addressing: SparseTileAddressing
    fileprivate let cachedPages:
        [SparseTileOutputRegion: Set<PaintTileCoordinate>]
    fileprivate let phaseAVisitedNodeCount: Int
    fileprivate let phaseASubdivisionCount: Int
    fileprivate let phaseAEnumeratedPixelCenterCount: Int
    fileprivate let phaseASinglePageFastPathCount: Int
    fileprivate let phaseAAxisSweepPixelCenterCount: Int
    fileprivate let phaseACacheHitCount: Int
    fileprivate let phaseAWorkCount: Int
}

private final class SparseTilePeriodicReachabilityAuthority {
    let outputRegion: SparseTileOutputRegion
    let mapping: SparseTilePeriodicOutputMapping
    let addressing: SparseTileAddressing
    let maximumWork: Int
    let phaseAVisitedNodeCount: Int
    let phaseASubdivisionCount: Int
    let phaseAEnumeratedPixelCenterCount: Int
    let phaseASinglePageFastPathCount: Int
    let phaseAAxisSweepPixelCenterCount: Int
    let phaseACacheHitCount: Int
    let phaseAWorkCount: Int
    fileprivate let diagnostics = SparseTilePeriodicReachabilityDiagnostics()
    fileprivate var cachedPages:
        [SparseTileOutputRegion: Set<PaintTileCoordinate>] = [:]
    fileprivate var cacheHitCount = 0
    fileprivate var workCount = 0

    init(
        outputRegion: SparseTileOutputRegion,
        mapping: SparseTilePeriodicOutputMapping,
        addressing: SparseTileAddressing,
        maximumWork: Int = 250_000,
        seed: SparseTilePeriodicReachabilitySeed? = nil
    ) {
        self.outputRegion = outputRegion
        self.mapping = mapping
        self.addressing = addressing
        self.maximumWork = maximumWork
        phaseAVisitedNodeCount = seed?.phaseAVisitedNodeCount ?? 0
        phaseASubdivisionCount = seed?.phaseASubdivisionCount ?? 0
        phaseAEnumeratedPixelCenterCount =
            seed?.phaseAEnumeratedPixelCenterCount ?? 0
        phaseASinglePageFastPathCount =
            seed?.phaseASinglePageFastPathCount ?? 0
        phaseAAxisSweepPixelCenterCount =
            seed?.phaseAAxisSweepPixelCenterCount ?? 0
        phaseACacheHitCount = seed?.phaseACacheHitCount ?? 0
        phaseAWorkCount = seed?.phaseAWorkCount ?? 0
        if let seed {
            precondition(seed.outputRegion == outputRegion)
            precondition(seed.mapping == mapping)
            precondition(seed.addressing == addressing)
            cachedPages = seed.cachedPages
        }
    }
}

enum SparseTileSamplingPlanBuilder {
    fileprivate static func makePeriodicReachabilityAuthority(
        key: SparseTileSamplingPlanKey,
        addressing: SparseTileAddressing,
        outputRegion: SparseTileOutputRegion,
        maximumWork: Int = 250_000,
        seed: SparseTilePeriodicReachabilitySeed? = nil
    ) throws -> SparseTilePeriodicReachabilityAuthority? {
        guard case let .periodic(mapping) = key.outputMapping else {
            guard seed == nil else {
                throw SparseTileSamplingPlanError.inconsistentAddressing
            }
            return nil
        }
        guard maximumWork >= 0 else {
            throw SparseTileSamplingPlanError
                .periodicReachabilityWorkLimitExceeded(maximum: maximumWork)
        }
        try validateOutputMapping(.periodic(mapping), addressing: addressing)
        if let seed {
            guard seed.outputRegion == outputRegion,
                  seed.mapping == mapping,
                  seed.addressing == addressing
            else { throw SparseTileSamplingPlanError.inconsistentAddressing }
            guard seed.phaseAWorkCount <= maximumWork else {
                throw SparseTileSamplingPlanError
                    .periodicReachabilityWorkLimitExceeded(
                        maximum: maximumWork
                    )
            }
        }
        return SparseTilePeriodicReachabilityAuthority(
            outputRegion: outputRegion,
            mapping: mapping,
            addressing: addressing,
            maximumWork: maximumWork,
            seed: seed
        )
    }

    fileprivate static func periodicReachabilitySeed(
        from authority: SparseTilePeriodicReachabilityAuthority
    ) -> SparseTilePeriodicReachabilitySeed {
        SparseTilePeriodicReachabilitySeed(
            outputRegion: authority.outputRegion,
            mapping: authority.mapping,
            addressing: authority.addressing,
            cachedPages: authority.cachedPages,
            phaseAVisitedNodeCount:
                authority.phaseAVisitedNodeCount
                    + authority.diagnostics.visitedNodeCount,
            phaseASubdivisionCount:
                authority.phaseASubdivisionCount
                    + authority.diagnostics.subdivisionCount,
            phaseAEnumeratedPixelCenterCount:
                authority.phaseAEnumeratedPixelCenterCount
                    + authority.diagnostics.enumeratedPixelCenterCount,
            phaseASinglePageFastPathCount:
                authority.phaseASinglePageFastPathCount
                    + authority.diagnostics.singlePageFastPathCount,
            phaseAAxisSweepPixelCenterCount:
                authority.phaseAAxisSweepPixelCenterCount
                    + authority.diagnostics.axisSweepPixelCenterCount,
            phaseACacheHitCount:
                authority.phaseACacheHitCount + authority.cacheHitCount,
            phaseAWorkCount:
                authority.phaseAWorkCount + authority.workCount
        )
    }

    fileprivate static func periodicReachabilityReceipt(
        from authority: SparseTilePeriodicReachabilityAuthority
    ) -> SparseTilePeriodicReachabilityReceipt {
        let phaseAWork = authority.phaseAWorkCount
        let acquisitionWork = authority.workCount
        return SparseTilePeriodicReachabilityReceipt(
            physicalPages: authority.cachedPages[authority.outputRegion] ?? [],
            visitedNodeCount: authority.phaseAVisitedNodeCount
                + authority.diagnostics.visitedNodeCount,
            subdivisionCount: authority.phaseASubdivisionCount
                + authority.diagnostics.subdivisionCount,
            enumeratedPixelCenterCount:
                authority.phaseAEnumeratedPixelCenterCount
                + authority.diagnostics.enumeratedPixelCenterCount,
            singlePageFastPathCount:
                authority.phaseASinglePageFastPathCount
                + authority.diagnostics.singlePageFastPathCount,
            axisSweepPixelCenterCount:
                authority.phaseAAxisSweepPixelCenterCount
                + authority.diagnostics.axisSweepPixelCenterCount,
            cacheHitCount:
                authority.phaseACacheHitCount + authority.cacheHitCount,
            phaseAWorkCount: phaseAWork,
            acquisitionWorkCount: acquisitionWork,
            workCount: phaseAWork + acquisitionWork
        )
    }

    #if DEBUG
    static func testingPeriodicReachabilityReceipt(
        for region: SparseTileOutputRegion,
        mapping: SparseTilePeriodicOutputMapping,
        addressing: SparseTileAddressing
    ) throws -> SparseTilePeriodicReachabilityReceipt {
        let authority = SparseTilePeriodicReachabilityAuthority(
            outputRegion: region,
            mapping: mapping,
            addressing: addressing,
            maximumWork: .max
        )
        _ = try periodicPhysicalPages(
            for: region,
            within: region,
            mapping: mapping,
            addressing: addressing,
            diagnostics: authority.diagnostics,
            authority: authority
        )
        return periodicReachabilityReceipt(from: authority)
    }

    #endif

    static func buildFull(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceSnapshot],
        outputRegion: SparseTileOutputRegion,
        limits: SparseTilePlanLimits,
        previous: SparseTileSamplingPlanContent? = nil,
        slotAssignments: [SparseTileRecordCoordinateKey: Int]? = nil,
        allocationObserver: (@Sendable (
            SparseTilePlanAllocationKind, Int
        ) -> Void)? = nil
    ) throws -> SparseTileSamplingPlanContent {
        guard !sources.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        let sourceFingerprints = sources.fingerprints
        let authority = try makePeriodicReachabilityAuthority(
            key: key,
            addressing: sources[0].addressing,
            outputRegion: outputRegion
        )
        let selectedSources = try selectingPhysicalReferences(
            key: key,
            sources: sources,
            outputRegion: outputRegion,
            periodicReachabilityAuthority: authority
        )
        return try buildSelected(
            key: key,
            sources: selectedSources,
            sourceFingerprints: sourceFingerprints,
            outputRegion: outputRegion,
            limits: limits,
            previous: previous,
            slotAssignments: slotAssignments,
            allocationObserver: allocationObserver,
            periodicReachabilityAuthority: authority
        )
    }

    /// Builds from an authenticated Phase-A selection. Periodic reachability
    /// starts from its immutable cache/receipt and charges only uncached work;
    /// prepared root and stable-child plans therefore cannot launch a second
    /// independent full-budget traversal.
    static func buildFull(
        key: SparseTileSamplingPlanKey,
        selection: SparseTileSourceSelection,
        outputRegion: SparseTileOutputRegion,
        limits: SparseTilePlanLimits,
        referenceScope: SparseTileSourceRequest.ReferenceScope = .identity,
        previous: SparseTileSamplingPlanContent? = nil,
        slotAssignments: [SparseTileRecordCoordinateKey: Int]? = nil,
        allocationObserver: (@Sendable (
            SparseTilePlanAllocationKind, Int
        ) -> Void)? = nil,
        maximumPeriodicReachabilityWork: Int = 250_000
    ) throws -> SparseTileSamplingPlanContent {
        guard (key.outputMapping.kind == .periodic)
                == (selection.periodicReachabilitySeed != nil)
        else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        let requests = try selection.restrictedSources(
            referenceScope: referenceScope
        )
        guard !requests.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        let sources = try requests.map {
            try SparseTileSourceSnapshot(
                contentKey: $0.contentKey,
                addressing: $0.addressing,
                layerID: $0.layerID,
                references: $0.references,
                changedCoordinates: $0.changedCoordinates,
                disposition: $0.disposition
            )
        }
        let sourceFingerprints = sources.fingerprints
        let authority = try makePeriodicReachabilityAuthority(
            key: key,
            addressing: sources[0].addressing,
            outputRegion: outputRegion,
            maximumWork: maximumPeriodicReachabilityWork,
            seed: selection.periodicReachabilitySeed
        )
        let selectedSources = try selectingPhysicalReferences(
            key: key,
            sources: sources,
            outputRegion: outputRegion,
            periodicReachabilityAuthority: authority
        )
        guard selectedSources.count
                == selection.selectedReferencesBySource.count
        else {
            throw SparseTileSamplingPlanError.sourceBatchSelectionMismatch(
                sourceIndex: min(
                    selectedSources.count,
                    selection.selectedReferencesBySource.count
                )
            )
        }
        for (sourceIndex, pair) in zip(
            selectedSources,
            selection.selectedReferencesBySource
        ).enumerated() where pair.0.references != pair.1 {
            throw SparseTileSamplingPlanError.sourceBatchSelectionMismatch(
                sourceIndex: sourceIndex
            )
        }
        return try buildSelected(
            key: key,
            sources: selectedSources,
            sourceFingerprints: sourceFingerprints,
            outputRegion: outputRegion,
            limits: limits,
            previous: previous,
            slotAssignments: slotAssignments,
            allocationObserver: allocationObserver,
            periodicReachabilityAuthority: authority
        )
    }

    /// Converts logical viewport reachability to the exact physical reference
    /// set that may be sampled by the four-neighbor bilinear kernel. This is
    /// metadata-only: it performs no reservation, page-in, or pin mutation.
    fileprivate static func selectingPhysicalReferences(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceSnapshot],
        outputRegion: SparseTileOutputRegion,
        periodicReachabilityAuthority:
            SparseTilePeriodicReachabilityAuthority? = nil
    ) throws -> [SparseTileSourceSnapshot] {
        guard !sources.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        guard sources.dropFirst().allSatisfy({
            $0.addressing == sources[0].addressing
        }) else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        let addressing = sources[0].addressing
        try validateOutputMapping(key.outputMapping, addressing: addressing)

        let selectedNonlinearPhysicalCoordinates: Set<PaintTileCoordinate>?
        let affineIntervals: (x: [Range<Int>], y: [Range<Int>])?
        switch key.outputMapping {
        case let .affine(transform):
            let shaderSourceOrigin = try transform.shaderSourceOrigin(
                outputRegion: outputRegion
            )
            let halo = try mappedSourceHalo(
                for: outputRegion,
                within: outputRegion,
                transform: transform,
                shaderSourceOrigin: shaderSourceOrigin
            )
            affineIntervals = (
                try addressedIntervals(
                    minimum: halo.minX,
                    maximumInclusive: halo.maxX,
                    axisLimit: addressing.axisWidth,
                    wraps: addressing.wraps
                ),
                try addressedIntervals(
                    minimum: halo.minY,
                    maximumInclusive: halo.maxY,
                    axisLimit: addressing.axisHeight,
                    wraps: addressing.wraps
                )
            )
            selectedNonlinearPhysicalCoordinates = nil
        case let .periodic(mapping):
            affineIntervals = nil
            if let authority = periodicReachabilityAuthority {
                selectedNonlinearPhysicalCoordinates = try authorityPages(
                    for: outputRegion,
                    authority: authority
                )
            } else {
                selectedNonlinearPhysicalCoordinates = try periodicPhysicalPages(
                    for: outputRegion,
                    within: outputRegion,
                    mapping: mapping,
                    addressing: addressing
                )
            }
        case let .finiteRadial(mapping):
            affineIntervals = nil
            selectedNonlinearPhysicalCoordinates = Set(
                try radialLogicalPages(
                    for: outputRegion,
                    mapping: mapping
                ).compactMap { coordinate in
                    mapping.layout.residentPage(at: coordinate)
                }.map { page in
                    PaintTileCoordinate(
                        x: page.atlasSlot % mapping.layout.atlasColumns,
                        y: page.atlasSlot / mapping.layout.atlasColumns
                    )
                }
            )
        }

        return try sources.map { source in
            let selectedCoordinates: Set<PaintTileCoordinate>
            switch key.outputMapping {
            case .affine:
                let affineRanges = affineIntervals!
                switch source.addressing {
                case .finite, .periodic:
                selectedCoordinates = Set(source.references.compactMap {
                    reference in
                    let bounds = reference.descriptor.logicalBounds
                    guard intervals(
                        affineRanges.x,
                        overlap: bounds.minX..<bounds.maxX
                    ), intervals(
                        affineRanges.y,
                        overlap: bounds.minY..<bounds.maxY
                    ) else { return nil }
                    return reference.coordinate
                })
                case let .radial(layout):
                    var physical: Set<PaintTileCoordinate> = []
                    for page in layout.residentPages {
                        let minX = try checkedProduct(
                            page.coordinate.x,
                            PaintTileDescriptor.side
                        )
                        let minY = try checkedProduct(
                            page.coordinate.y,
                            PaintTileDescriptor.side
                        )
                        let maxX = try checkedSum(
                            minX, PaintTileDescriptor.side
                        )
                        let maxY = try checkedSum(
                            minY, PaintTileDescriptor.side
                        )
                        guard intervals(
                            affineRanges.x, overlap: minX..<maxX
                        ), intervals(
                            affineRanges.y, overlap: minY..<maxY
                        ) else { continue }
                        physical.insert(PaintTileCoordinate(
                            x: page.atlasSlot % layout.atlasColumns,
                            y: page.atlasSlot / layout.atlasColumns
                        ))
                    }
                    selectedCoordinates = physical
                }
            case .periodic, .finiteRadial:
                selectedCoordinates = selectedNonlinearPhysicalCoordinates!
            }
            let selectedReferences = source.references.filter {
                selectedCoordinates.contains($0.coordinate)
            }
            let selectedChanges = source.changedCoordinates.filter {
                selectedCoordinates.contains($0)
            }
            return try SparseTileSourceSnapshot(
                contentKey: source.contentKey,
                addressing: source.addressing,
                layerID: source.layerID,
                references: selectedReferences,
                changedCoordinates: selectedChanges,
                disposition: source.disposition
            )
        }
    }

    fileprivate static func buildSelected(
        key: SparseTileSamplingPlanKey,
        sources: [SparseTileSourceSnapshot],
        sourceFingerprints: [SparseTileSourceFingerprint],
        outputRegion: SparseTileOutputRegion,
        limits: SparseTilePlanLimits,
        previous: SparseTileSamplingPlanContent? = nil,
        slotAssignments: [SparseTileRecordCoordinateKey: Int]? = nil,
        allocationObserver: (@Sendable (
            SparseTilePlanAllocationKind, Int
        ) -> Void)? = nil,
        periodicReachabilityAuthority:
            SparseTilePeriodicReachabilityAuthority? = nil
    ) throws -> SparseTileSamplingPlanContent {
        guard !sources.isEmpty else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        guard limits.allValues.allSatisfy({ $0 > 0 }) else {
            throw SparseTileSamplingPlanError.invalidLimit
        }
        guard sources.dropFirst().allSatisfy({
            $0.addressing == sources[0].addressing
        }) else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        guard sourceFingerprints.count == sources.count,
              zip(sources, sourceFingerprints).allSatisfy({ source, fingerprint in
                  source.layerID == fingerprint.layerID
                      && source.contentKey == fingerprint.contentKey
                      && source.addressing == fingerprint.addressing
              })
        else {
            throw SparseTileSamplingPlanError.contentKeyMismatch
        }
        try validateOutputMapping(
            key.outputMapping,
            addressing: sources[0].addressing
        )
        let shaderSourceOrigin: SIMD2<Float>
        switch key.outputMapping {
        case let .affine(transform):
            shaderSourceOrigin = try transform.shaderSourceOrigin(
                outputRegion: outputRegion
            )
        case let .periodic(mapping):
            shaderSourceOrigin = try mapping.shaderSourceOrigin(
                outputRegion: outputRegion
            )
        case .finiteRadial:
            shaderSourceOrigin = .zero
        }
        let maximumGlobalSlots = min(limits.maximumBindingSlots, 512)
        let bindingCount = try sources.reduce(into: 0) { count, source in
            count = try checkedSum(count, source.references.count)
        }
        guard bindingCount <= maximumGlobalSlots else {
            throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                required: bindingCount,
                maximum: maximumGlobalSlots
            )
        }
        let bindingBytes = try checkedProduct(bindingCount, 64)
        guard bindingBytes <= limits.maximumBindingBytes else {
            throw SparseTileSamplingPlanError.bindingByteLimitExceeded(
                required: bindingBytes,
                maximum: limits.maximumBindingBytes
            )
        }
        let bindingChunkCount = try sources.reduce(into: 0) { count, source in
            count = try checkedSum(
                count,
                try checkedChunkCount(
                    itemCount: source.references.count,
                    capacity: 64
                )
            )
        }
        guard bindingChunkCount <= limits.maximumBindingChunks else {
            throw SparseTileSamplingPlanError.bindingChunkLimitExceeded(
                required: bindingChunkCount,
                maximum: limits.maximumBindingChunks
            )
        }

        let geometries = try sources.map(pageTableGeometry)
        var totalPageEntries = 0
        var totalPageChunks = 0
        for geometry in geometries {
            totalPageEntries = try checkedSum(
                totalPageEntries, geometry.entryCount
            )
            totalPageChunks = try checkedSum(
                totalPageChunks, geometry.chunkCount
            )
        }
        guard totalPageEntries <= limits.maximumPageEntries else {
            throw SparseTileSamplingPlanError.pageEntryLimitExceeded(
                required: totalPageEntries,
                maximum: limits.maximumPageEntries
            )
        }
        guard totalPageChunks <= limits.maximumPageChunks else {
            throw SparseTileSamplingPlanError.pageChunkLimitExceeded(
                required: totalPageChunks,
                maximum: limits.maximumPageChunks
            )
        }
        let pageBytes = try checkedProduct(totalPageEntries, 32)
        guard pageBytes <= limits.maximumPageTableBytes else {
            throw SparseTileSamplingPlanError.pageTableByteLimitExceeded(
                required: pageBytes,
                maximum: limits.maximumPageTableBytes
            )
        }

        // Validate the complete deterministic subdivision before allocating
        // records, chunks, or page entries. This includes terminal child
        // regions, not only an output that starts at one pixel.
        try preflightOutputHalo(
            outputRegion,
            outputMapping: key.outputMapping,
            shaderSourceOrigin: shaderSourceOrigin,
            addressing: sources[0].addressing,
            periodicReachabilityAuthority: periodicReachabilityAuthority
        )
        try preflightBatches(
            sources: sources,
            outputRegion: outputRegion,
            outputMapping: key.outputMapping,
            shaderSourceOrigin: shaderSourceOrigin,
            limits: limits,
            periodicReachabilityAuthority: periodicReachabilityAuthority
        )
        allocationObserver?(.bindingRecords, bindingCount)

        let previousRecords = previous?.bindingRecords ?? []
        guard previousRecords.allSatisfy({
            $0.globalSlot >= 0 && $0.globalSlot < maximumGlobalSlots
        }) else {
            throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                required: previousRecords.count,
                maximum: maximumGlobalSlots
            )
        }
        let previousByCoordinate = Dictionary(
            uniqueKeysWithValues: previousRecords.map {
                (SparseTileRecordCoordinateKey(
                    layerID: $0.layerID,
                    role: $0.role,
                    coordinate: $0.reference.coordinate
                ), $0)
            }
        )
        let reservedSlots = Set(previousRecords.map(\.globalSlot))
        var assignedSlots: Set<Int> = []
        var records: [SparseTileBindingRecord] = []
        for source in sources {
            for reference in source.references {
                let coordinateKey = SparseTileRecordCoordinateKey(
                    layerID: source.layerID,
                    role: source.role,
                    coordinate: reference.coordinate
                )
                let slot: Int
                if let assigned = slotAssignments?[coordinateKey] {
                    slot = assigned
                } else if let existing = previousByCoordinate[coordinateKey] {
                    slot = existing.globalSlot
                } else {
                    var candidate = 0
                    while reservedSlots.contains(candidate)
                            || assignedSlots.contains(candidate) {
                        candidate = try checkedSum(candidate, 1)
                    }
                    slot = candidate
                }
                guard slot < maximumGlobalSlots else {
                    let union = reservedSlots.union(assignedSlots).count + 1
                    throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                        required: union,
                        maximum: maximumGlobalSlots
                    )
                }
                guard assignedSlots.insert(slot).inserted else {
                    throw SparseTileSamplingPlanError.bindingSlotLimitExceeded(
                        required: assignedSlots.count + 1,
                        maximum: maximumGlobalSlots
                    )
                }
                records.append(SparseTileBindingRecord(
                    globalSlot: slot,
                    layerID: source.layerID,
                    role: source.role,
                    reference: reference
                ))
            }
        }
        allocationObserver?(.bindingChunks, bindingChunkCount)
        var bindingChunks: [SparseTileBindingChunk] = []
        var rebuiltBindingCount = 0
        for source in sources {
            let sourceRecords = records.filter {
                $0.layerID == source.layerID
                    && $0.role == source.role
            }
            let previousChunks = previous?.bindingChunks.filter {
                $0.layerID == source.layerID
                    && $0.role == source.role
            } ?? []
            for (index, chunkRecords) in sourceRecords.chunked(capacity: 64)
                .enumerated() {
                if index < previousChunks.count,
                   previousChunks[index].records == chunkRecords {
                    bindingChunks.append(previousChunks[index])
                } else {
                    bindingChunks.append(SparseTileBindingChunk(
                        layerID: source.layerID,
                        role: source.role,
                        records: chunkRecords
                    ))
                    rebuiltBindingCount = try checkedSum(
                        rebuiltBindingCount, chunkRecords.count
                    )
                }
            }
        }
        allocationObserver?(.pageEntries, totalPageEntries)
        var pageTables: [SparseTilePageTable] = []
        for index in sources.indices {
            let source = sources[index]
            let geometry = geometries[index]
            let recordsForSource = records.filter {
                $0.layerID == source.layerID
                    && $0.role == source.role
            }
            let sourceFingerprint = sourceFingerprints[index]
            let previousFingerprint = previous?.sourceFingerprints.first {
                $0.layerID == source.layerID
                    && $0.contentKey.role == source.role
            }
            let table = try makePageTable(
                source: source,
                geometry: geometry,
                records: recordsForSource,
                previous: previous?.pageTable(
                    layerID: source.layerID,
                    role: source.role
                ),
                changedCoordinates: sourceFingerprint == previousFingerprint
                    ? [] : source.changedCoordinates
            )
            pageTables.append(table)
        }
        let batches = try makeBatches(
            pageTables: pageTables,
            addressing: sources[0].addressing,
            outputRegion: outputRegion,
            outputMapping: key.outputMapping,
            shaderSourceOrigin: shaderSourceOrigin,
            limits: limits,
            periodicReachabilityAuthority: periodicReachabilityAuthority
        )
        let rebuiltPageEntries = pageTables.reduce(into: 0) { result, table in
            let oldChunks = previous?.pageTable(
                layerID: table.layerID, role: table.role
            )?.chunks ?? []
            for (index, chunk) in table.chunks.enumerated()
                where index >= oldChunks.count || chunk !== oldChunks[index] {
                result += chunk.entries.count
            }
        }
        let content = SparseTileSamplingPlanContent(
            key: key,
            addressing: sources[0].addressing,
            pageTables: pageTables,
            bindingRecords: records,
            bindingChunks: bindingChunks,
            batches: batches,
            telemetry: .init(
                rebuiltPageEntryCount: rebuiltPageEntries,
                rebuiltBindingCount: rebuiltBindingCount
            ),
            outputToSourceTransform: key.outputToSourceTransform,
            shaderSourceOrigin: shaderSourceOrigin,
            sourceFingerprints: sourceFingerprints,
            outputRegion: outputRegion
        )
        #if DEBUG
        content.periodicReachabilityReceipt =
            periodicReachabilityAuthority.map {
                periodicReachabilityReceipt(from: $0)
            }
        #endif
        return content
    }

    private static func makePageTable(
        source: SparseTileSourceSnapshot,
        geometry: SparseTilePageTableGeometry,
        records: [SparseTileBindingRecord],
        previous: SparseTilePageTable?,
        changedCoordinates: [PaintTileCoordinate]
    ) throws -> SparseTilePageTable {
        let origin = geometry.origin
        let size = geometry.size
        var slotByPhysicalCoordinate: [PaintTileCoordinate: Int] = [:]
        for record in records {
            slotByPhysicalCoordinate[record.reference.coordinate] = record.globalSlot
        }
        var entries: [SparseTilePageEntry] = []
        entries.reserveCapacity(geometry.entryCount)
        for tableY in 0..<size.height {
            for tableX in 0..<size.width {
                let logical = PaintTileCoordinate(
                    x: try checkedSum(origin.x, tableX),
                    y: try checkedSum(origin.y, tableY)
                )
                let physical: PaintTileCoordinate?
                switch source.addressing {
                case .finite, .periodic:
                    physical = logical
                case let .radial(layout):
                    if let page = layout.residentPage(at: .init(
                        x: logical.x, y: logical.y
                    )) {
                        physical = PaintTileCoordinate(
                            x: page.atlasSlot % layout.atlasColumns,
                            y: page.atlasSlot / layout.atlasColumns
                        )
                    } else {
                        physical = nil
                    }
                }
                let slot = physical.flatMap { slotByPhysicalCoordinate[$0] } ?? -1
                let logicalX = try checkedProduct(logical.x, PaintTileDescriptor.side)
                let logicalY = try checkedProduct(logical.y, PaintTileDescriptor.side)
                let physicalX = try checkedProduct(
                    physical?.x ?? 0, PaintTileDescriptor.side
                )
                let physicalY = try checkedProduct(
                    physical?.y ?? 0, PaintTileDescriptor.side
                )
                let localBounds: PixelRect
                if slot >= 0,
                   let record = records.first(where: { $0.globalSlot == slot }),
                   case .radial = source.addressing {
                    _ = record
                    localBounds = PixelRect(
                        minX: 0, minY: 0,
                        maxX: PaintTileDescriptor.side,
                        maxY: PaintTileDescriptor.side
                    )!
                } else if slot >= 0,
                          let record = records.first(where: { $0.globalSlot == slot }) {
                    let bounds = record.reference.descriptor.logicalBounds
                    localBounds = PixelRect(
                        minX: bounds.minX - physicalX,
                        minY: bounds.minY - physicalY,
                        maxX: bounds.maxX - physicalX,
                        maxY: bounds.maxY - physicalY
                    )!
                } else {
                    localBounds = PixelRect(
                        minX: 0, minY: 0,
                        maxX: PaintTileDescriptor.side,
                        maxY: PaintTileDescriptor.side
                    )!
                }
                entries.append(.init(
                    globalBindingSlot: slot,
                    logicalOrigin: SIMD2(logicalX, logicalY),
                    physicalOrigin: SIMD2(physicalX, physicalY),
                    localBounds: localBounds
                ))
            }
        }
        let entryChunks = entries.chunked(
            capacity: SparseTilePageTable.chunkCapacity
        )
        let changed = Set(changedCoordinates)
        let chunks = entryChunks.enumerated().map { index, chunkEntries in
            let intersectsChange = chunkEntries.contains { entry in
                let physical = PaintTileCoordinate(
                    x: floorDivide(
                        entry.physicalOrigin.x,
                        divisor: PaintTileDescriptor.side
                    ),
                    y: floorDivide(
                        entry.physicalOrigin.y,
                        divisor: PaintTileDescriptor.side
                    )
                )
                return changed.contains(physical)
            }
            if !intersectsChange,
               let old = previous?.chunks[safe: index],
               old.entries == chunkEntries {
                return old
            }
            return SparseTilePageTableChunk(entries: chunkEntries)
        }
        return SparseTilePageTable(
            layerID: source.layerID,
            role: source.role,
            origin: origin,
            size: size,
            entryCount: geometry.entryCount,
            chunks: chunks
        )
    }

    private static func pageTableGeometry(
        for source: SparseTileSourceSnapshot
    ) throws -> SparseTilePageTableGeometry {
        let origin: PaintTileCoordinate
        let size: PixelSize
        switch source.addressing {
        case let .finite(pixelSize), let .periodic(pixelSize):
            origin = PaintTileCoordinate(x: 0, y: 0)
            size = PixelSize(
                width: try ceilDivide(pixelSize.width, by: PaintTileDescriptor.side),
                height: try ceilDivide(pixelSize.height, by: PaintTileDescriptor.side)
            )
        case let .radial(layout):
            origin = PaintTileCoordinate(
                x: layout.pageOrigin.x,
                y: layout.pageOrigin.y
            )
            size = layout.pageTableSize
        }
        let entryCount = try checkedProduct(size.width, size.height)
        let chunkCount = try checkedChunkCount(
            itemCount: entryCount,
            capacity: SparseTilePageTable.chunkCapacity
        )
        return SparseTilePageTableGeometry(
            origin: origin,
            size: size,
            entryCount: entryCount,
            chunkCount: chunkCount
        )
    }

    private static func preflightOutputHalo(
        _ outputRegion: SparseTileOutputRegion,
        outputMapping: SparseTileSamplingOutputMapping,
        shaderSourceOrigin: SIMD2<Float>,
        addressing: SparseTileAddressing,
        periodicReachabilityAuthority:
            SparseTilePeriodicReachabilityAuthority?
    ) throws {
        if case let .periodic(mapping) = outputMapping {
            if let periodicReachabilityAuthority {
                _ = try authorityPages(
                    for: outputRegion,
                    authority: periodicReachabilityAuthority
                )
            } else {
                _ = try periodicPhysicalPages(
                    for: outputRegion,
                    within: outputRegion,
                    mapping: mapping,
                    addressing: addressing
                )
            }
            return
        } else if case let .finiteRadial(mapping) = outputMapping {
            _ = try radialLogicalPages(
                for: outputRegion,
                mapping: mapping
            )
            return
        }
        guard case let .affine(transform) = outputMapping else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        let halo = try mappedSourceHalo(
            for: outputRegion,
            within: outputRegion,
            transform: transform,
            shaderSourceOrigin: shaderSourceOrigin
        )
        _ = try addressedIntervals(
            minimum: halo.minX,
            maximumInclusive: halo.maxX,
            axisLimit: addressing.axisWidth,
            wraps: addressing.wraps
        )
        _ = try addressedIntervals(
            minimum: halo.minY,
            maximumInclusive: halo.maxY,
            axisLimit: addressing.axisHeight,
            wraps: addressing.wraps
        )
    }

    private static func requiredSourceBindingCount(
        for region: SparseTileOutputRegion,
        within outputRegion: SparseTileOutputRegion,
        outputMapping: SparseTileSamplingOutputMapping,
        shaderSourceOrigin: SIMD2<Float>,
        sources: [SparseTileSourceSnapshot],
        periodicReachabilityAuthority:
            SparseTilePeriodicReachabilityAuthority?
    ) throws -> Int {
        if case let .periodic(mapping) = outputMapping {
            let physicalCoordinates: Set<PaintTileCoordinate>
            if let periodicReachabilityAuthority {
                physicalCoordinates = try authorityPages(
                    for: region,
                    authority: periodicReachabilityAuthority
                )
            } else {
                physicalCoordinates = try periodicPhysicalPages(
                    for: region,
                    within: outputRegion,
                    mapping: mapping,
                    addressing: sources[0].addressing
                )
            }
            var required: Set<SparseTileRecordCoordinateKey> = []
            for source in sources {
                for reference in source.references
                where physicalCoordinates.contains(reference.coordinate) {
                    required.insert(SparseTileRecordCoordinateKey(
                        layerID: source.layerID,
                        role: source.role,
                        coordinate: reference.coordinate
                    ))
                }
            }
            return required.count
        } else if case let .finiteRadial(mapping) = outputMapping {
            let physicalCoordinates = Set(
                try radialLogicalPages(for: region, mapping: mapping)
                    .compactMap { mapping.layout.residentPage(at: $0) }
                    .map {
                        PaintTileCoordinate(
                            x: $0.atlasSlot % mapping.layout.atlasColumns,
                            y: $0.atlasSlot / mapping.layout.atlasColumns
                        )
                    }
            )
            var required: Set<SparseTileRecordCoordinateKey> = []
            for source in sources {
                for reference in source.references
                    where physicalCoordinates.contains(reference.coordinate) {
                    required.insert(SparseTileRecordCoordinateKey(
                        layerID: source.layerID,
                        role: source.role,
                        coordinate: reference.coordinate
                    ))
                }
            }
            return required.count
        }
        guard case let .affine(transform) = outputMapping else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        let addressing = sources[0].addressing
        let halo = try mappedSourceHalo(
            for: region,
            within: outputRegion,
            transform: transform,
            shaderSourceOrigin: shaderSourceOrigin
        )
        let xIntervals = try addressedIntervals(
            minimum: halo.minX,
            maximumInclusive: halo.maxX,
            axisLimit: addressing.axisWidth,
            wraps: addressing.wraps
        )
        let yIntervals = try addressedIntervals(
            minimum: halo.minY,
            maximumInclusive: halo.maxY,
            axisLimit: addressing.axisHeight,
            wraps: addressing.wraps
        )
        var required: Set<SparseTileRecordCoordinateKey> = []
        for source in sources {
            switch source.addressing {
            case .finite, .periodic:
                for reference in source.references {
                    let bounds = reference.descriptor.logicalBounds
                    if intervals(xIntervals, overlap: bounds.minX..<bounds.maxX),
                       intervals(yIntervals, overlap: bounds.minY..<bounds.maxY) {
                        required.insert(SparseTileRecordCoordinateKey(
                            layerID: source.layerID,
                            role: source.role,
                            coordinate: reference.coordinate
                        ))
                    }
                }
            case let .radial(layout):
                let referenceCoordinates = Set(
                    source.references.map(\.coordinate)
                )
                for page in layout.residentPages {
                    let minX = try checkedProduct(
                        page.coordinate.x, PaintTileDescriptor.side
                    )
                    let minY = try checkedProduct(
                        page.coordinate.y, PaintTileDescriptor.side
                    )
                    let maxX = try checkedSum(minX, PaintTileDescriptor.side)
                    let maxY = try checkedSum(minY, PaintTileDescriptor.side)
                    guard intervals(xIntervals, overlap: minX..<maxX),
                          intervals(yIntervals, overlap: minY..<maxY)
                    else { continue }
                    let physical = PaintTileCoordinate(
                        x: page.atlasSlot % layout.atlasColumns,
                        y: page.atlasSlot / layout.atlasColumns
                    )
                    if referenceCoordinates.contains(physical) {
                        required.insert(SparseTileRecordCoordinateKey(
                            layerID: source.layerID,
                            role: source.role,
                            coordinate: physical
                        ))
                    }
                }
            }
        }
        return required.count
    }

    private static func preflightBatches(
        sources: [SparseTileSourceSnapshot],
        outputRegion: SparseTileOutputRegion,
        outputMapping: SparseTileSamplingOutputMapping,
        shaderSourceOrigin: SIMD2<Float>,
        limits: SparseTilePlanLimits,
        periodicReachabilityAuthority:
            SparseTilePeriodicReachabilityAuthority?
    ) throws {
        var batchCount = 0
        var examinedRegionCount = 0
        let maximumExaminedRegions = limits.maximumBatchCount > Int.max / 2
            ? Int.max
            : limits.maximumBatchCount * 2 - 1

        func split(_ region: SparseTileOutputRegion) throws {
            examinedRegionCount = try checkedSum(examinedRegionCount, 1)
            guard examinedRegionCount <= maximumExaminedRegions else {
                throw SparseTileSamplingPlanError.batchLimitExceeded(
                    required: try checkedSum(limits.maximumBatchCount, 1),
                    maximum: limits.maximumBatchCount
                )
            }
            let required = try requiredSourceBindingCount(
                for: region,
                within: outputRegion,
                outputMapping: outputMapping,
                shaderSourceOrigin: shaderSourceOrigin,
                sources: sources,
                periodicReachabilityAuthority:
                    periodicReachabilityAuthority
            )
            if required <= limits.maximumTexturesPerBatch {
                batchCount = try checkedSum(batchCount, 1)
                guard batchCount <= limits.maximumBatchCount else {
                    throw SparseTileSamplingPlanError.batchLimitExceeded(
                        required: batchCount,
                        maximum: limits.maximumBatchCount
                    )
                }
                return
            }
            guard region.width > 1 || region.height > 1 else {
                throw SparseTileSamplingPlanError
                    .onePixelBatchExceedsTextureLimit(
                        required: required,
                        maximum: limits.maximumTexturesPerBatch
                    )
            }
            if region.width >= region.height, region.width > 1 {
                let midpoint = try checkedSum(region.minX, region.width / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX,
                    minY: region.minY,
                    maxX: midpoint,
                    maxY: region.maxY
                ))
                try split(SparseTileOutputRegion(
                    minX: midpoint,
                    minY: region.minY,
                    maxX: region.maxX,
                    maxY: region.maxY
                ))
            } else {
                let midpoint = try checkedSum(region.minY, region.height / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX,
                    minY: region.minY,
                    maxX: region.maxX,
                    maxY: midpoint
                ))
                try split(SparseTileOutputRegion(
                    minX: region.minX,
                    minY: midpoint,
                    maxX: region.maxX,
                    maxY: region.maxY
                ))
            }
        }

        try split(outputRegion)
    }

    private static func intervals(
        _ intervals: [Range<Int>],
        overlap target: Range<Int>
    ) -> Bool {
        intervals.contains {
            $0.lowerBound < target.upperBound
                && target.lowerBound < $0.upperBound
        }
    }

    private static func makeBatches(
        pageTables: [SparseTilePageTable],
        addressing: SparseTileAddressing,
        outputRegion: SparseTileOutputRegion,
        outputMapping: SparseTileSamplingOutputMapping,
        shaderSourceOrigin: SIMD2<Float>,
        limits: SparseTilePlanLimits,
        periodicReachabilityAuthority:
            SparseTilePeriodicReachabilityAuthority?
    ) throws -> [SparseTileBindingBatch] {
        var batches: [SparseTileBindingBatch] = []
        func split(_ region: SparseTileOutputRegion) throws {
            let slots = try requiredSlots(
                for: region,
                within: outputRegion,
                outputMapping: outputMapping,
                shaderSourceOrigin: shaderSourceOrigin,
                pageTables: pageTables,
                addressing: addressing,
                periodicReachabilityAuthority:
                    periodicReachabilityAuthority
            )
            if slots.count <= limits.maximumTexturesPerBatch {
                let remap = Dictionary(
                    uniqueKeysWithValues: slots.enumerated().map {
                        ($0.element, $0.offset)
                    }
                )
                batches.append(SparseTileBindingBatch(
                    outputRegion: region,
                    globalSlots: slots,
                    compactRemap: remap
                ))
                guard batches.count <= limits.maximumBatchCount else {
                    throw SparseTileSamplingPlanError.batchLimitExceeded(
                        required: batches.count,
                        maximum: limits.maximumBatchCount
                    )
                }
                return
            }
            guard region.width > 1 || region.height > 1 else {
                throw SparseTileSamplingPlanError
                    .onePixelBatchExceedsTextureLimit(
                        required: slots.count,
                        maximum: limits.maximumTexturesPerBatch
                    )
            }
            if region.width >= region.height, region.width > 1 {
                let midpoint = try checkedSum(region.minX, region.width / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX, minY: region.minY,
                    maxX: midpoint, maxY: region.maxY
                ))
                try split(SparseTileOutputRegion(
                    minX: midpoint, minY: region.minY,
                    maxX: region.maxX, maxY: region.maxY
                ))
            } else {
                let midpoint = try checkedSum(region.minY, region.height / 2)
                try split(SparseTileOutputRegion(
                    minX: region.minX, minY: region.minY,
                    maxX: region.maxX, maxY: midpoint
                ))
                try split(SparseTileOutputRegion(
                    minX: region.minX, minY: midpoint,
                    maxX: region.maxX, maxY: region.maxY
                ))
            }
        }
        try split(outputRegion)
        return batches
    }

    private static func requiredSlots(
        for region: SparseTileOutputRegion,
        within outputRegion: SparseTileOutputRegion,
        outputMapping: SparseTileSamplingOutputMapping,
        shaderSourceOrigin: SIMD2<Float>,
        pageTables: [SparseTilePageTable],
        addressing: SparseTileAddressing,
        periodicReachabilityAuthority:
            SparseTilePeriodicReachabilityAuthority?
    ) throws -> [Int] {
        if case let .periodic(mapping) = outputMapping {
            let physicalPages: Set<PaintTileCoordinate>
            if let periodicReachabilityAuthority {
                physicalPages = try authorityPages(
                    for: region,
                    authority: periodicReachabilityAuthority
                )
            } else {
                physicalPages = try periodicPhysicalPages(
                    for: region,
                    within: outputRegion,
                    mapping: mapping,
                    addressing: addressing
                )
            }
            var slots: Set<Int> = []
            for table in pageTables {
                for coordinate in physicalPages {
                    if let entry = table.entry(at: coordinate),
                       !entry.isMissing {
                        slots.insert(entry.globalBindingSlot)
                    }
                }
            }
            return slots.sorted()
        } else if case let .finiteRadial(mapping) = outputMapping {
            let logicalPages = try radialLogicalPages(
                for: region,
                mapping: mapping
            )
            var slots: Set<Int> = []
            for table in pageTables {
                for coordinate in logicalPages {
                    let page = PaintTileCoordinate(
                        x: coordinate.x,
                        y: coordinate.y
                    )
                    if let entry = table.entry(at: page), !entry.isMissing {
                        slots.insert(entry.globalBindingSlot)
                    }
                }
            }
            return slots.sorted()
        }
        guard case let .affine(transform) = outputMapping else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        let halo = try mappedSourceHalo(
            for: region,
            within: outputRegion,
            transform: transform,
            shaderSourceOrigin: shaderSourceOrigin
        )
        let xIntervals = try addressedIntervals(
            minimum: halo.minX,
            maximumInclusive: halo.maxX,
            axisLimit: addressing.axisWidth,
            wraps: addressing.wraps
        )
        let yIntervals = try addressedIntervals(
            minimum: halo.minY,
            maximumInclusive: halo.maxY,
            axisLimit: addressing.axisHeight,
            wraps: addressing.wraps
        )
        var slots: Set<Int> = []
        for table in pageTables {
            for chunk in table.chunks {
                for entry in chunk.entries where !entry.isMissing {
                    let minX = try checkedSum(
                        entry.logicalOrigin.x, entry.localBounds.minX
                    )
                    let maxX = try checkedSum(
                        entry.logicalOrigin.x, entry.localBounds.maxX
                    )
                    let minY = try checkedSum(
                        entry.logicalOrigin.y, entry.localBounds.minY
                    )
                    let maxY = try checkedSum(
                        entry.logicalOrigin.y, entry.localBounds.maxY
                    )
                    guard xIntervals.contains(where: {
                        $0.lowerBound < maxX && minX < $0.upperBound
                    }), yIntervals.contains(where: {
                        $0.lowerBound < maxY && minY < $0.upperBound
                    }) else { continue }
                    slots.insert(entry.globalBindingSlot)
                }
            }
        }
        return slots.sorted()
    }

    private struct SparseTileMappedSourceHalo {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    private static func validateOutputMapping(
        _ outputMapping: SparseTileSamplingOutputMapping,
        addressing: SparseTileAddressing
    ) throws {
        switch outputMapping {
        case .affine:
            // Accepted B3b.2 behavior includes affine access to already-folded
            // signed radial logical coordinates.
            return
        case let .periodic(mapping):
            try SparseTilePeriodicOutputMappingValidator.validate(
                mapping,
                addressing: addressing
            )
        case let .finiteRadial(mapping):
            guard case let .radial(layout) = addressing,
                  layout == mapping.layout
            else {
                throw SparseTileSamplingPlanError.inconsistentAddressing
            }
        }
    }

    private static func authorityPages(
        for region: SparseTileOutputRegion,
        authority: SparseTilePeriodicReachabilityAuthority
    ) throws -> Set<PaintTileCoordinate> {
        guard region.minX >= authority.outputRegion.minX,
              region.minY >= authority.outputRegion.minY,
              region.maxX <= authority.outputRegion.maxX,
              region.maxY <= authority.outputRegion.maxY
        else { throw SparseTileSamplingPlanError.invalidOutputRegion }
        if let cached = authority.cachedPages[region] {
            authority.cacheHitCount = try checkedSum(
                authority.cacheHitCount, 1
            )
            return cached
        }
        let pages = try periodicPhysicalPages(
            for: region,
            within: authority.outputRegion,
            mapping: authority.mapping,
            addressing: authority.addressing,
            diagnostics: authority.diagnostics,
            authority: authority
        )
        return pages
    }

    private enum PeriodicCellSignatureComponent: Equatable, Hashable {
        /// Axis-aligned folds execute a 32-bit Metal cell conversion.
        case shaderInt(Int)
        /// Unit-lattice folds use modulo directly. Preserve the exact Float
        /// floor identity without narrowing a valid large lattice coordinate.
        case floatFloor(UInt32)
    }

    private struct PeriodicCellSignature: Equatable, Hashable {
        let column: PeriodicCellSignatureComponent
        let row: PeriodicCellSignatureComponent
    }

    /// Shared periodic nonlinear reachability authority. It evaluates discrete
    /// output pixel centers, recursively proving a complete fold-cell signature
    /// before using corner extrema. Ambiguous or boundary-crossing rectangles
    /// bisect deterministically; small leaves enumerate exact centers. The
    /// resulting physical canonical pages drive selection, preflight, fallback
    /// count, and final slot validation.
    private static func periodicPhysicalPages(
        for region: SparseTileOutputRegion,
        within outputRegion: SparseTileOutputRegion,
        mapping: SparseTilePeriodicOutputMapping,
        addressing: SparseTileAddressing,
        diagnostics: SparseTilePeriodicReachabilityDiagnostics? = nil,
        authority: SparseTilePeriodicReachabilityAuthority? = nil
    ) throws -> Set<PaintTileCoordinate> {
        try validateOutputMapping(.periodic(mapping), addressing: addressing)
        guard case let .periodic(period) = addressing else {
            throw SparseTileSamplingPlanError.inconsistentAddressing
        }
        let transform = mapping.outputToWorldTransform
        let shaderOrigin = try mapping.shaderSourceOrigin(
            outputRegion: outputRegion
        )
        let fullColumns = try ceilDivide(
            period.width,
            by: PaintTileDescriptor.side
        )
        let fullRows = try ceilDivide(
            period.height,
            by: PaintTileDescriptor.side
        )
        let fullPageCount = try checkedProduct(fullColumns, fullRows)
        func recordWork(_ count: Int) throws {
            guard count >= 0 else {
                throw SparseTileSamplingPlanError.arithmeticOverflow
            }
            if let authority {
                let acquisitionWork = try checkedSum(
                    authority.workCount, count
                )
                let aggregateWork = try checkedSum(
                    authority.phaseAWorkCount, acquisitionWork
                )
                guard aggregateWork <= authority.maximumWork else {
                    throw SparseTileSamplingPlanError
                        .periodicReachabilityWorkLimitExceeded(
                            maximum: authority.maximumWork
                        )
                }
                authority.workCount = acquisitionWork
            }
        }

        func worldAxis(
            origin: Float,
            localIndex: Int,
            screenPixelOffset: Int,
            step: Float
        ) throws -> Float {
            let localCenter = Float(localIndex) + 0.5
            let offset = Float(screenPixelOffset)
            let center = localCenter + offset
            guard localCenter.isFinite, offset.isFinite, center.isFinite,
                  Double(Float(localIndex)) == Double(localIndex),
                  Int(exactly: offset) == screenPixelOffset
            else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            // This is the exact expression written in the precise periodic
            // Metal scope: sourceOrigin + rootPixel * sourceStep.
            let value = origin + center * step
            guard value.isFinite else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            return value
        }

        func worldPoint(x: Int, y: Int) throws -> WorldPoint {
            let localX = try x.subtractingChecked(outputRegion.minX)
            let localY = try y.subtractingChecked(outputRegion.minY)
            guard localX >= 0, localY >= 0,
                  localX < outputRegion.width,
                  localY < outputRegion.height
            else { throw SparseTileSamplingPlanError.invalidOutputRegion }
            let xValue = try worldAxis(
                origin: shaderOrigin.x,
                localIndex: localX,
                screenPixelOffset: mapping.screenPixelOffset.x,
                step: transform.sourceStep.x
            )
            let yValue = try worldAxis(
                origin: shaderOrigin.y,
                localIndex: localY,
                screenPixelOffset: mapping.screenPixelOffset.y,
                step: transform.sourceStep.y
            )
            return WorldPoint(x: xValue, y: yValue)
        }

        func latticePoint(_ world: WorldPoint) throws -> SIMD2<Float> {
            // Matches both Task 7 and the reassociation-disabled Metal vector
            // expression `(xAxis * x + yAxis * y) + translation`.
            let lattice = mapping.fold.worldToLattice.applying(to: world.simd)
            guard lattice.x.isFinite, lattice.y.isFinite else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            return lattice
        }

        func resolvedCellIndex(
            coordinate: Float,
            extent: Float,
            phase: Float
        ) throws -> Int {
            let phased = coordinate - phase
            let quotient = phased / extent
            guard phased.isFinite, quotient.isFinite,
                  let initial = Int(exactly: floor(quotient))
            else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            var result = initial
            let origin = Float(result) * extent + phase
            let boundary = origin + extent
            guard origin.isFinite, boundary.isFinite else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            if coordinate < origin {
                result = try checkedSum(result, -1)
            } else if coordinate >= boundary {
                result = try checkedSum(result, 1)
            }
            return result
        }

        /// Throwing mirror of Task 7's preconditioned cell authority. Every
        /// world candidate must pass this exact-Float and half-open round-trip
        /// proof before `CompiledPeriodicDisplayFold.applying` is invoked.
        func cellIndex(
            coordinate: Float,
            extent: Float,
            phase: Float,
            requiresShaderInt32: Bool = true
        ) throws -> Int {
            let result = try resolvedCellIndex(
                coordinate: coordinate,
                extent: extent,
                phase: phase
            )
            let floatResult = Float(result)
            guard Int(exactly: floatResult) == result,
                  !requiresShaderInt32 || Int32(exactly: result) != nil
            else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            let unphasedOrigin = floatResult * extent
            let origin = unphasedOrigin + phase
            let boundary = origin + extent
            let successor = try checkedSum(result, 1)
            guard unphasedOrigin.isFinite,
                  origin.isFinite,
                  boundary.isFinite,
                  phase == 0 || origin - unphasedOrigin == phase,
                  boundary - origin == extent,
                  try resolvedCellIndex(
                    coordinate: origin, extent: extent, phase: phase
                  ) == result,
                  try resolvedCellIndex(
                    coordinate: boundary.nextDown,
                    extent: extent,
                    phase: phase
                  ) == result,
                  try resolvedCellIndex(
                    coordinate: boundary, extent: extent, phase: phase
                  ) == successor,
                  coordinate >= origin,
                  coordinate < boundary
            else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            return result
        }

        func phaseOffset(_ index: Int, _ phase: PeriodicPhaseProgram) -> Float {
            let count = phase.fractions.count
            let remainder = index % count
            let slot = remainder >= 0 ? remainder : remainder + count
            let extent: Float = switch phase.offsetAxis {
            case .x: mapping.fold.repeatSize.width
            case .y: mapping.fold.repeatSize.height
            }
            return phase.fractions[slot] * extent
        }

        func signature(
            _ world: WorldPoint
        ) throws -> PeriodicCellSignature {
            let fold = mapping.fold
            switch fold.coordinateSpace {
            case .unitLattice:
                let lattice = try latticePoint(world)
                if fold.family == .rectangular {
                    // Task 7 proves exact Float cell round-trips for this
                    // family even though Metal itself folds by modulo.
                    _ = try cellIndex(
                        coordinate: lattice.x,
                        extent: 1,
                        phase: 0,
                        requiresShaderInt32: false
                    )
                    _ = try cellIndex(
                        coordinate: lattice.y,
                        extent: 1,
                        phase: 0,
                        requiresShaderInt32: false
                    )
                }
                func component(
                    _ coordinate: Float
                ) throws -> PeriodicCellSignatureComponent {
                    let value = floor(coordinate)
                    guard value.isFinite else {
                        throw SparseTileSamplingPlanError
                            .invalidOutputToSourceTransform
                    }
                    let normalized: Float = value == 0 ? 0 : value
                    return .floatFloor(normalized.bitPattern)
                }
                return PeriodicCellSignature(
                    column: try component(lattice.x),
                    row: try component(lattice.y)
                )
            case .axisAlignedRepeat:
                guard let phase = fold.phase else {
                    return PeriodicCellSignature(
                        column: .shaderInt(try cellIndex(
                            coordinate: world.x,
                            extent: fold.repeatSize.width,
                            phase: 0
                        )),
                        row: .shaderInt(try cellIndex(
                            coordinate: world.y,
                            extent: fold.repeatSize.height,
                            phase: 0
                        ))
                    )
                }
                switch phase.indexAxis {
                case .x:
                    let column = try cellIndex(
                        coordinate: world.x,
                        extent: fold.repeatSize.width,
                        phase: 0
                    )
                    return PeriodicCellSignature(
                        column: .shaderInt(column),
                        row: .shaderInt(try cellIndex(
                            coordinate: world.y,
                            extent: fold.repeatSize.height,
                            phase: phaseOffset(column, phase)
                        ))
                    )
                case .y:
                    let row = try cellIndex(
                        coordinate: world.y,
                        extent: fold.repeatSize.height,
                        phase: 0
                    )
                    return PeriodicCellSignature(
                        column: .shaderInt(try cellIndex(
                            coordinate: world.x,
                            extent: fold.repeatSize.width,
                            phase: phaseOffset(row, phase)
                        )),
                        row: .shaderInt(row)
                    )
                }
            }
        }

        func samplePosition(_ world: WorldPoint) throws -> SIMD2<Float> {
            // Validate Task 7's preconditions before invoking its compiled
            // fold. The periodic Metal scope writes the same expression and
            // explicitly disables reassociation and contraction.
            _ = try signature(world)
            let compiled = mapping.fold.applying(to: world)
            let sample = SIMD2(compiled.x, compiled.y)
                - SIMD2(repeating: 0.5)
            guard compiled.x.isFinite, compiled.y.isFinite,
                  sample.x.isFinite, sample.y.isFinite
            else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            return sample
        }

        func insertSamplePosition(
            _ sample: SIMD2<Float>,
            into pages: inout Set<PaintTileCoordinate>
        ) throws {
            let lowerX = try checkedFloorToInt(Double(sample.x))
            let lowerY = try checkedFloorToInt(Double(sample.y))
            for deltaY in 0...1 {
                for deltaX in 0...1 {
                    let x = try checkedSum(lowerX, deltaX)
                    let y = try checkedSum(lowerY, deltaY)
                    let wrappedX = (x % period.width + period.width)
                        % period.width
                    let wrappedY = (y % period.height + period.height)
                        % period.height
                    pages.insert(PaintTileCoordinate(
                        x: wrappedX / PaintTileDescriptor.side,
                        y: wrappedY / PaintTileDescriptor.side
                    ))
                }
            }
        }

        func physicalPages(
            for samples: [SIMD2<Float>]
        ) throws -> Set<PaintTileCoordinate> {
            var result: Set<PaintTileCoordinate> = []
            for sample in samples {
                let lowerX = try checkedFloorToInt(Double(sample.x))
                let lowerY = try checkedFloorToInt(Double(sample.y))
                for deltaY in 0...1 {
                    for deltaX in 0...1 {
                        let pixelX = try checkedSum(lowerX, deltaX)
                        let pixelY = try checkedSum(lowerY, deltaY)
                        let wrappedX = (pixelX % period.width + period.width)
                            % period.width
                        let wrappedY = (pixelY % period.height + period.height)
                            % period.height
                        result.insert(PaintTileCoordinate(
                            x: wrappedX / PaintTileDescriptor.side,
                            y: wrappedY / PaintTileDescriptor.side
                        ))
                    }
                }
            }
            return result
        }

        func upperPhysicalPages(
            for worlds: [WorldPoint]
        ) throws -> Set<PaintTileCoordinate> {
            try recordWork(worlds.count)
            let samples = try worlds.map(samplePosition)
            guard let minimumX = samples.map(\.x).min(),
                  let maximumX = samples.map(\.x).max(),
                  let minimumY = samples.map(\.y).min(),
                  let maximumY = samples.map(\.y).max()
            else { throw SparseTileSamplingPlanError.invalidOutputRegion }
            let minX = try checkedFloorToInt(Double(minimumX))
            let maxX = try checkedSum(
                try checkedFloorToInt(Double(maximumX)), 1
            )
            let minY = try checkedFloorToInt(Double(minimumY))
            let maxY = try checkedSum(
                try checkedFloorToInt(Double(maximumY)), 1
            )
            let xIntervals = try addressedIntervals(
                minimum: minX,
                maximumInclusive: maxX,
                axisLimit: period.width,
                wraps: true
            )
            let yIntervals = try addressedIntervals(
                minimum: minY,
                maximumInclusive: maxY,
                axisLimit: period.height,
                wraps: true
            )
            var pageIterationCount = 0
            for xInterval in xIntervals {
                let firstX = floorDivide(
                    xInterval.lowerBound,
                    divisor: PaintTileDescriptor.side
                )
                let lastX = floorDivide(
                    xInterval.upperBound - 1,
                    divisor: PaintTileDescriptor.side
                )
                let xCount = try checkedSum(
                    try lastX.subtractingChecked(firstX), 1
                )
                for yInterval in yIntervals {
                    let firstY = floorDivide(
                        yInterval.lowerBound,
                        divisor: PaintTileDescriptor.side
                    )
                    let lastY = floorDivide(
                        yInterval.upperBound - 1,
                        divisor: PaintTileDescriptor.side
                    )
                    let yCount = try checkedSum(
                        try lastY.subtractingChecked(firstY), 1
                    )
                    pageIterationCount = try checkedSum(
                        pageIterationCount,
                        try checkedProduct(xCount, yCount)
                    )
                }
            }
            // Charge the complete Cartesian page walk before inserting its
            // first element, so enormous valid periods fail typed and leave no
            // partial authority cache behind.
            try recordWork(pageIterationCount)
            var result: Set<PaintTileCoordinate> = []
            for xInterval in xIntervals {
                let firstX = floorDivide(
                    xInterval.lowerBound,
                    divisor: PaintTileDescriptor.side
                )
                let lastX = floorDivide(
                    xInterval.upperBound - 1,
                    divisor: PaintTileDescriptor.side
                )
                for yInterval in yIntervals {
                    let firstY = floorDivide(
                        yInterval.lowerBound,
                        divisor: PaintTileDescriptor.side
                    )
                    let lastY = floorDivide(
                        yInterval.upperBound - 1,
                        divisor: PaintTileDescriptor.side
                    )
                    for y in firstY...lastY {
                        for x in firstX...lastX {
                            result.insert(PaintTileCoordinate(x: x, y: y))
                        }
                    }
                }
            }
            return result
        }

        func witnessedPhysicalPages(
            in candidate: SparseTileOutputRegion
        ) throws -> Set<PaintTileCoordinate> {
            let middleX = try checkedSum(
                candidate.minX, (candidate.width - 1) / 2
            )
            let middleY = try checkedSum(
                candidate.minY, (candidate.height - 1) / 2
            )
            let xs = Set([candidate.minX, middleX, candidate.maxX - 1])
            let ys = Set([candidate.minY, middleY, candidate.maxY - 1])
            try recordWork(try checkedProduct(xs.count, ys.count))
            var samples: [SIMD2<Float>] = []
            for y in ys {
                for x in xs {
                    let world = try worldPoint(x: x, y: y)
                    samples.append(try samplePosition(world))
                }
            }
            return try physicalPages(for: samples)
        }

        func physicalAxisSamplePages(
            _ samplePosition: Float,
            axisLimit: Int
        ) throws -> Set<Int> {
            let lower = try checkedFloorToInt(Double(samplePosition))
            var result: Set<Int> = []
            for delta in 0...1 {
                let pixel = try checkedSum(lower, delta)
                let wrapped = (pixel % axisLimit + axisLimit) % axisLimit
                result.insert(wrapped / PaintTileDescriptor.side)
            }
            return result
        }

        func enumerate(
            _ leaf: SparseTileOutputRegion
        ) throws -> Set<PaintTileCoordinate> {
            let centerCount = try checkedProduct(leaf.width, leaf.height)
            diagnostics?.enumeratedPixelCenterCount = try checkedSum(
                diagnostics?.enumeratedPixelCenterCount ?? 0,
                centerCount
            )
            try recordWork(centerCount)
            var result: Set<PaintTileCoordinate> = []
            for y in leaf.minY..<leaf.maxY {
                for x in leaf.minX..<leaf.maxX {
                    let world = try worldPoint(x: x, y: y)
                    try insertSamplePosition(
                        try samplePosition(world), into: &result
                    )
                }
            }
            return result
        }

        /// Within one complete rectangular fold signature, canonical x and y
        /// are separable. Sweep each discrete output axis rather than filling
        /// the continuous corner range: sparse source steps may intentionally
        /// skip physical pages. If an interior sample changes phase/cell/
        /// reflection signature, return false so deterministic subdivision
        /// establishes smaller separable pieces.
        func exactAxisSeparablePages(
            _ candidate: SparseTileOutputRegion
        ) throws -> Set<PaintTileCoordinate>? {
            let sweepCount = try checkedSum(
                candidate.width, candidate.height
            )
            try recordWork(sweepCount)
            diagnostics?.axisSweepPixelCenterCount = try checkedSum(
                diagnostics?.axisSweepPixelCenterCount ?? 0,
                sweepCount
            )
            var observedSignatures: Set<PeriodicCellSignature> = []
            var xPages: Set<Int> = []
            var yPages: Set<Int> = []
            for x in candidate.minX..<candidate.maxX {
                let world = try worldPoint(x: x, y: candidate.minY)
                observedSignatures.insert(try signature(world))
                let sample = try samplePosition(world)
                xPages.formUnion(try physicalAxisSamplePages(
                    sample.x,
                    axisLimit: period.width
                ))
            }
            for y in candidate.minY..<candidate.maxY {
                let world = try worldPoint(x: candidate.minX, y: y)
                observedSignatures.insert(try signature(world))
                let sample = try samplePosition(world)
                yPages.formUnion(try physicalAxisSamplePages(
                    sample.y,
                    axisLimit: period.height
                ))
            }
            guard observedSignatures.count == 1 else { return nil }
            try recordWork(try checkedProduct(xPages.count, yPages.count))
            var result: Set<PaintTileCoordinate> = []
            for y in yPages {
                for x in xPages {
                    result.insert(PaintTileCoordinate(x: x, y: y))
                }
            }
            return result
        }

        /// Choose the axis whose remaining output extent spans more folded
        /// canonical pages. This is only a subdivision-order heuristic; exact
        /// reachability still comes from the shared fold/page authority.
        func projectedAmbiguitySpan(
            forX: Bool,
            in candidate: SparseTileOutputRegion
        ) throws -> Double {
            let fold = mapping.fold
            let pixelCount = Double(
                forX ? candidate.width : candidate.height
            )
            let canonicalWidth = Double(fold.canonicalSize.width)
            let canonicalHeight = Double(fold.canonicalSize.height)
            let pageSide = Double(PaintTileDescriptor.side)
            let span: Double
            switch fold.coordinateSpace {
            case .axisAlignedRepeat:
                if forX {
                    let cells = abs(Double(transform.sourceStep.x))
                        / Double(fold.repeatSize.width)
                    var canonical = cells * canonicalWidth
                    if let phase = fold.phase, phase.indexAxis == .x {
                        canonical = max(canonical, cells * canonicalHeight)
                    }
                    span = canonical * pixelCount / pageSide
                } else {
                    let cells = abs(Double(transform.sourceStep.y))
                        / Double(fold.repeatSize.height)
                    var canonical = cells * canonicalHeight
                    if let phase = fold.phase, phase.indexAxis == .y {
                        canonical = max(canonical, cells * canonicalWidth)
                    }
                    span = canonical * pixelCount / pageSide
                }
            case .unitLattice:
                let derivative = forX
                    ? fold.worldToLattice.xAxis * transform.sourceStep.x
                    : fold.worldToLattice.yAxis * transform.sourceStep.y
                let canonical = max(
                    abs(Double(derivative.x)) * canonicalWidth,
                    abs(Double(derivative.y)) * canonicalHeight
                )
                span = canonical * pixelCount / pageSide
            }
            guard span.isFinite else {
                throw SparseTileSamplingPlanError
                    .invalidOutputToSourceTransform
            }
            return span
        }

        func collect(
            _ candidate: SparseTileOutputRegion
        ) throws -> Set<PaintTileCoordinate> {
            if let cached = authority?.cachedPages[candidate] {
                authority?.cacheHitCount = try checkedSum(
                    authority?.cacheHitCount ?? 0, 1
                )
                return cached
            }
            diagnostics?.visitedNodeCount = try checkedSum(
                diagnostics?.visitedNodeCount ?? 0, 1
            )
            try recordWork(1)

            func finish(
                _ result: Set<PaintTileCoordinate>
            ) -> Set<PaintTileCoordinate> {
                authority?.cachedPages[candidate] = result
                return result
            }
            let lastX = candidate.maxX - 1
            let lastY = candidate.maxY - 1
            let corners = [
                (candidate.minX, candidate.minY),
                (lastX, candidate.minY),
                (candidate.minX, lastY),
                (lastX, lastY),
            ]
            try recordWork(corners.count)
            var worlds: [WorldPoint] = []
            for point in corners {
                worlds.append(try worldPoint(x: point.0, y: point.1))
            }
            var allSignatures: Set<PeriodicCellSignature> = []
            for world in worlds {
                allSignatures.insert(try signature(world))
            }
            if allSignatures.count == 1 {
                let upper = try upperPhysicalPages(for: worlds)
                let witnessed = try witnessedPhysicalPages(in: candidate)
                if upper == witnessed {
                    diagnostics?.singlePageFastPathCount = try checkedSum(
                        diagnostics?.singlePageFastPathCount ?? 0, 1
                    )
                    return finish(upper)
                }
                switch mapping.fold.coordinateSpace {
                case .axisAlignedRepeat:
                    if let exact = try exactAxisSeparablePages(candidate) {
                        return finish(exact)
                    }
                case .unitLattice:
                    // A rotated/sheared footprint is a parallelogram, not its
                    // Cartesian bounding box. When witnesses do not prove the
                    // complete upper set, subdivide instead of retaining an
                    // unreachable Cartesian range.
                    break
                }
            }
            let area = try checkedProduct(candidate.width, candidate.height)
            if area <= 64 {
                return finish(try enumerate(candidate))
            }
            let canSplitX = candidate.width > 1
            let canSplitY = candidate.height > 1
            let splitX: Bool
            if canSplitX, canSplitY {
                let xSpan = try projectedAmbiguitySpan(
                    forX: true, in: candidate
                )
                let ySpan = try projectedAmbiguitySpan(
                    forX: false, in: candidate
                )
                splitX = xSpan == ySpan
                    ? candidate.width >= candidate.height
                    : xSpan > ySpan
            } else {
                splitX = canSplitX
            }
            if splitX, canSplitX {
                diagnostics?.subdivisionCount = try checkedSum(
                    diagnostics?.subdivisionCount ?? 0, 1
                )
                let midpoint = try checkedSum(
                    candidate.minX, candidate.width / 2
                )
                let first = try collect(SparseTileOutputRegion(
                    minX: candidate.minX, minY: candidate.minY,
                    maxX: midpoint, maxY: candidate.maxY
                ))
                if first.count == fullPageCount { return finish(first) }
                let second = try collect(SparseTileOutputRegion(
                    minX: midpoint, minY: candidate.minY,
                    maxX: candidate.maxX, maxY: candidate.maxY
                ))
                try recordWork(try checkedSum(first.count, second.count))
                return finish(first.union(second))
            } else if candidate.height > 1 {
                diagnostics?.subdivisionCount = try checkedSum(
                    diagnostics?.subdivisionCount ?? 0, 1
                )
                let midpoint = try checkedSum(
                    candidate.minY, candidate.height / 2
                )
                let first = try collect(SparseTileOutputRegion(
                    minX: candidate.minX, minY: candidate.minY,
                    maxX: candidate.maxX, maxY: midpoint
                ))
                if first.count == fullPageCount { return finish(first) }
                let second = try collect(SparseTileOutputRegion(
                    minX: candidate.minX, minY: midpoint,
                    maxX: candidate.maxX, maxY: candidate.maxY
                ))
                try recordWork(try checkedSum(first.count, second.count))
                return finish(first.union(second))
            } else {
                return finish(try enumerate(candidate))
            }
        }

        return try collect(region)
    }

    /// Conservative nonlinear reachability shared by root selection and every
    /// preflight/batch bisection. `images(intersecting:)` supplies the exact
    /// radial logical page cells; one logical page in every direction covers
    /// the four-neighbor bilinear footprint at page, ray, and tile seams.
    private static func radialLogicalPages(
        for region: SparseTileOutputRegion,
        mapping: SparseTileFiniteRadialOutputMapping
    ) throws -> Set<RadialPageCoordinate> {
        let transform = mapping.outputToWorldTransform
        let origin = try transform.shaderSourceOrigin(outputRegion: region)
        let extent = SIMD2(Float(region.width), Float(region.height))
            * transform.sourceStep
        let maximum = origin + extent
        guard extent.x.isFinite, extent.y.isFinite,
              maximum.x.isFinite, maximum.y.isFinite
        else { throw SparseTileSamplingPlanError.invalidOutputToSourceTransform }
        let bounds = AxisAlignedRect(
            minimum: origin,
            maximum: maximum
        )
        var result: Set<RadialPageCoordinate> = []
        for image in mapping.strategy.images(intersecting: bounds) {
            for deltaY in -1...1 {
                for deltaX in -1...1 {
                    let coordinate = RadialPageCoordinate(
                        x: try checkedSum(image.cell.column, deltaX),
                        y: try checkedSum(image.cell.row, deltaY)
                    )
                    if mapping.layout.residentPage(at: coordinate) != nil {
                        result.insert(coordinate)
                    }
                }
            }
        }
        return result
    }

    private static func mappedSourceHalo(
        for region: SparseTileOutputRegion,
        within outputRegion: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        shaderSourceOrigin: SIMD2<Float>
    ) throws -> SparseTileMappedSourceHalo {
        let localMinX = try region.minX.subtractingChecked(outputRegion.minX)
        let localMinY = try region.minY.subtractingChecked(outputRegion.minY)
        let localMaxX = try region.maxX.subtractingChecked(outputRegion.minX)
        let localMaxY = try region.maxY.subtractingChecked(outputRegion.minY)
        guard localMinX >= 0, localMinY >= 0,
              localMaxX <= outputRegion.width,
              localMaxY <= outputRegion.height
        else { throw SparseTileSamplingPlanError.invalidOutputRegion }

        func axis(
            localMinimum: Int,
            localMaximum: Int,
            origin: Float,
            step: Float
        ) throws -> (minimum: Int, maximum: Int) {
            guard localMaximum > localMinimum else {
                throw SparseTileSamplingPlanError.invalidOutputRegion
            }
            let firstCenter = Float(localMinimum) + 0.5
            let lastCenter = Float(localMaximum - 1) + 0.5
            guard firstCenter.isFinite, lastCenter.isFinite else {
                throw SparseTileSamplingPlanError.invalidOutputToSourceTransform
            }
            func sampleBounds(at center: Float) throws
                -> (lower: Double, upper: Double)
            {
                // Metal fast math may both contract and reassociate
                // `origin + center * step - 0.5`. Evaluate every legal Float
                // grouping explicitly; any of them can cross a sparse-page
                // boundary even when the written grouping and its FMA agree.
                let product = center * step
                let leftUnfused = (origin + product) - 0.5
                let leftFused = origin.addingProduct(center, step) - 0.5
                let shiftedOrigin = origin - 0.5
                let shiftedOriginUnfused = shiftedOrigin + product
                let shiftedOriginFused = shiftedOrigin.addingProduct(
                    center,
                    step
                )
                let shiftedProductUnfused = origin + (product - 0.5)
                let shiftedProductFused = origin
                    + (-Float(0.5)).addingProduct(center, step)
                let samples = [
                    leftUnfused,
                    leftFused,
                    shiftedOriginUnfused,
                    shiftedOriginFused,
                    shiftedProductUnfused,
                    shiftedProductFused,
                ]
                guard samples.allSatisfy(\.isFinite),
                      let minimum = samples.min(),
                      let maximum = samples.max()
                else {
                    throw SparseTileSamplingPlanError
                        .invalidOutputToSourceTransform
                }
                let lower = Double(minimum)
                let upper = Double(maximum)
                guard lower != upper else { return (lower, upper) }
                return (lower.nextDown, upper.nextUp)
            }

            let first = try sampleBounds(at: firstCenter)
            let last = try sampleBounds(at: lastCenter)
            let minimum = try checkedFloorToInt(min(first.lower, last.lower))
            let upperLower = try checkedFloorToInt(max(first.upper, last.upper))
            return (minimum, try checkedSum(upperLower, 1))
        }

        let x = try axis(
            localMinimum: localMinX,
            localMaximum: localMaxX,
            origin: shaderSourceOrigin.x,
            step: transform.sourceStep.x
        )
        let y = try axis(
            localMinimum: localMinY,
            localMaximum: localMaxY,
            origin: shaderSourceOrigin.y,
            step: transform.sourceStep.y
        )
        return SparseTileMappedSourceHalo(
            minX: x.minimum,
            minY: y.minimum,
            maxX: x.maximum,
            maxY: y.maximum
        )
    }

    private static func addressedIntervals(
        minimum: Int,
        maximumInclusive: Int,
        axisLimit: Int?,
        wraps: Bool
    ) throws -> [Range<Int>] {
        let exclusiveMaximum = try checkedSum(maximumInclusive, 1)
        guard let axisLimit else { return [minimum..<exclusiveMaximum] }
        if !wraps {
            let lower = max(0, minimum)
            let upper = min(axisLimit, exclusiveMaximum)
            return lower < upper ? [lower..<upper] : []
        }
        let span = try checkedSum(
            try maximumInclusive.subtractingChecked(minimum), 1
        )
        if span >= axisLimit { return [0..<axisLimit] }
        let start = positiveRemainder(minimum, modulus: axisLimit)
        let end = try checkedSum(start, span)
        if end <= axisLimit { return [start..<end] }
        return [start..<axisLimit, 0..<(end - axisLimit)]
    }
}

protocol SparseTileCPUTexelProvider: Sendable {
    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float>
}

struct SparseTileResolvedTexelAddress: Equatable, Sendable {
    let layerID: UUID
    let role: SparseTileSampleRole
    let globalBindingSlot: Int
    let reference: PaintTileReference
    let localX: Int
    let localY: Int
}

struct SparseTileResolvedIntegerNeighbor: Equatable, Sendable {
    let logicalPixel: SIMD2<Int>
    /// Fixed layer order, then canonical/authoritative/prediction role order.
    /// Missing sources are absent and therefore contribute transparent black.
    let contributions: [SparseTileResolvedTexelAddress]
}

struct SparseTileFourNeighborResolution: Equatable, Sendable {
    /// Fraction of `point - 0.5` used by the one final bilinear mix.
    let fraction: SIMD2<Float>
    /// Ordered 00, 10, 01, 11.
    let neighbors: [SparseTileResolvedIntegerNeighbor]
}

enum SparseTileCPUReferenceSampler {
    static func resolveFourNeighbors(
        at point: SIMD2<Double>,
        content: SparseTileSamplingPlanContent
    ) throws -> SparseTileFourNeighborResolution {
        guard point.x.isFinite, point.y.isFinite else {
            throw SparseTileSamplingPlanError.nonFiniteSamplePoint
        }
        let sampleX = point.x - 0.5
        let sampleY = point.y - 0.5
        let x0 = try checkedFloorToInt(sampleX)
        let y0 = try checkedFloorToInt(sampleY)
        let x1 = try checkedSum(x0, 1)
        let y1 = try checkedSum(y0, 1)
        let pixels = [
            SIMD2(x0, y0), SIMD2(x1, y0),
            SIMD2(x0, y1), SIMD2(x1, y1),
        ]
        let neighbors = try pixels.map { pixel in
            SparseTileResolvedIntegerNeighbor(
                logicalPixel: pixel,
                contributions: try content.pageTables.compactMap { table in
                    try resolveAddress(
                        x: pixel.x,
                        y: pixel.y,
                        table: table,
                        content: content
                    )
                }
            )
        }
        return SparseTileFourNeighborResolution(
            fraction: SIMD2(
                Float(sampleX - floor(sampleX)),
                Float(sampleY - floor(sampleY))
            ),
            neighbors: neighbors
        )
    }

    static func sample<P: SparseTileCPUTexelProvider>(
        at point: SIMD2<Double>,
        layerID: UUID,
        role: SparseTileSampleRole,
        content: SparseTileSamplingPlanContent,
        provider: P
    ) throws -> SIMD4<Float> {
        _ = try content.pageTable(layerID: layerID, role: role).unwrap(
            SparseTileSamplingPlanError.missingPageTable(
                layerID: layerID, role: role
            )
        )
        let resolution = try resolveFourNeighbors(at: point, content: content)
        let colors = try resolution.neighbors.map { neighbor in
            guard let address = neighbor.contributions.first(where: {
                $0.layerID == layerID && $0.role == role
            }) else { return SIMD4<Float>.zero }
            return try provider.texel(
                reference: address.reference,
                localX: address.localX,
                localY: address.localY
            )
        }
        let c00 = colors[0]
        let c10 = colors[1]
        let c01 = colors[2]
        let c11 = colors[3]
        let fx = resolution.fraction.x
        let fy = resolution.fraction.y
        return simd_mix(simd_mix(c00, c10, SIMD4(repeating: fx)),
                        simd_mix(c01, c11, SIMD4(repeating: fx)),
                        SIMD4(repeating: fy))
    }

    private static func resolveAddress(
        x: Int,
        y: Int,
        table: SparseTilePageTable,
        content: SparseTileSamplingPlanContent
    ) throws -> SparseTileResolvedTexelAddress? {
        let addressed: SIMD2<Int>?
        switch content.addressing {
        case let .finite(size):
            guard x >= 0, y >= 0, x < size.width, y < size.height else {
                return nil
            }
            addressed = SIMD2(x, y)
        case let .periodic(period):
            addressed = SIMD2(
                positiveRemainder(x, modulus: period.width),
                positiveRemainder(y, modulus: period.height)
            )
        case .radial:
            addressed = SIMD2(x, y)
        }
        guard let addressed else { return nil }
        let pageX = floorDivide(addressed.x, divisor: PaintTileDescriptor.side)
        let pageY = floorDivide(addressed.y, divisor: PaintTileDescriptor.side)
        let localX = positiveRemainder(
            addressed.x, modulus: PaintTileDescriptor.side
        )
        let localY = positiveRemainder(
            addressed.y, modulus: PaintTileDescriptor.side
        )
        guard let entry = table.entry(at: .init(x: pageX, y: pageY)),
              !entry.isMissing,
              localX >= entry.localBounds.minX,
              localY >= entry.localBounds.minY,
              localX < entry.localBounds.maxX,
              localY < entry.localBounds.maxY,
              let record = content.bindingRecord(at: entry.globalBindingSlot)
        else { return nil }
        return SparseTileResolvedTexelAddress(
            layerID: table.layerID,
            role: table.role,
            globalBindingSlot: entry.globalBindingSlot,
            reference: record.reference,
            localX: localX,
            localY: localY
        )
    }
}

private func positiveRemainder(_ value: Int, modulus: Int) -> Int {
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
}

private func floorDivide(_ value: Int, divisor: Int) -> Int {
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

private extension SparseTileAddressing {
    var wraps: Bool {
        if case .periodic = self { return true }
        return false
    }

    var axisWidth: Int? {
        switch self {
        case let .finite(size), let .periodic(size): size.width
        case .radial: nil
        }
    }

    var axisHeight: Int? {
        switch self {
        case let .finite(size), let .periodic(size): size.height
        case .radial: nil
        }
    }
}

private extension Int {
    func subtractingChecked(_ other: Int) throws -> Int {
        let (value, overflow) = subtractingReportingOverflow(other)
        guard !overflow else {
            throw SparseTileSamplingPlanError.arithmeticOverflow
        }
        return value
    }
}

private func ceilDivide(_ value: Int, by divisor: Int) throws -> Int {
    guard value >= 0, divisor > 0 else {
        throw SparseTileSamplingPlanError.arithmeticOverflow
    }
    return try checkedSum(value / divisor, value % divisor == 0 ? 0 : 1)
}

private func checkedChunkCount(itemCount: Int, capacity: Int) throws -> Int {
    guard itemCount >= 0, capacity > 0 else {
        throw SparseTileSamplingPlanError.arithmeticOverflow
    }
    return try checkedSum(
        itemCount / capacity,
        itemCount % capacity == 0 ? 0 : 1
    )
}

private func checkedFloorToInt(_ value: Double) throws -> Int {
    let rounded = floor(value)
    guard let exact = Int(exactly: rounded) else {
        throw SparseTileSamplingPlanError.arithmeticOverflow
    }
    return exact
}

private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw SparseTileSamplingPlanError.arithmeticOverflow }
    return value
}

private func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw SparseTileSamplingPlanError.arithmeticOverflow }
    return value
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    func chunked(capacity: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        var result: [[Element]] = []
        result.reserveCapacity((count + capacity - 1) / capacity)
        var start = 0
        while start < count {
            let end = Swift.min(count, start + capacity)
            result.append(Array(self[start..<end]))
            start = end
        }
        return result
    }
}

private extension Optional {
    func unwrap(_ error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
