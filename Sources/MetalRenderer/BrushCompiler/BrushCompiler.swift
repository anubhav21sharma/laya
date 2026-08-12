import BrushFormat
import Foundation
import Metal
import PatternEngine

enum BrushCompilerPhase: String, CaseIterable, Equatable, Sendable {
    case beforeDecode
    case betweenResources
    case beforeUpload
    case afterUpload
    case beforeCacheTransaction
}

package struct BrushCompilerPhaseContext: Equatable, Sendable {
    let phase: BrushCompilerPhase
    let definitionID: String
    let resourceID: String?
}

package struct BrushCompilerTestHooks {
    let uploadFailureResourceID: String?
    let admissionFailureDefinitionID: String?
    let onPackageHash: @Sendable (String) async throws -> Void
    let onPhase:
        @MainActor @Sendable (BrushCompilerPhaseContext) async -> Void

    package init(
        uploadFailureResourceID: String? = nil,
        admissionFailureDefinitionID: String? = nil,
        onPackageHash:
            @escaping @Sendable (String) async throws -> Void = { _ in },
        onPhase:
            @escaping @MainActor @Sendable
            (BrushCompilerPhaseContext) async -> Void = { _ in }
    ) {
        self.uploadFailureResourceID = uploadFailureResourceID
        self.admissionFailureDefinitionID = admissionFailureDefinitionID
        self.onPackageHash = onPackageHash
        self.onPhase = onPhase
    }

    package init(
        _ onPhase:
            @escaping @MainActor @Sendable
            (BrushCompilerPhaseContext) async -> Void
    ) {
        self.init(onPhase: onPhase)
    }

    package static let none = BrushCompilerTestHooks()
}

private enum BrushCompilerWorkSource: Sendable {
    case packaged(resource: BrushPackageResource, data: Data)
    case builtIn(identity: BrushTextureIdentity, maximumDimension: Int)
}

private struct BrushCompilerResourceWork: Sendable {
    let resourceID: String
    let kind: BrushResourceKind
    let cacheKey: String
    let source: BrushCompilerWorkSource
    let usedFallback: Bool
    let projectedResidentBytes: Int
    let diagnostics: [BrushCompilationDiagnostic]
}

private enum BrushCompilerPreparationError: Error {
    case unknownBuiltIn(resourceID: String)
    case missingManifestResource(resourceID: String)
    case resourceIdentifierCollision(resourceID: String)
    case resourceCostOverflow
    case missingTipSupport(resourceID: String)
}

private enum BrushCompilerCounterField {
    case packageDecode
    case imageDecode
    case textureUpload
    case cacheHit
    case activation
}

public final class BrushCompilationBatch {
    public let brushes: [CompiledBrush]

    fileprivate let owner: ObjectIdentifier
    fileprivate let baseRevision: UInt64
    fileprivate let cache: BrushResourceCache
    fileprivate let counters: BrushCompilerCounters
    fileprivate let activeBrush: CompiledBrush?

    fileprivate init(
        owner: ObjectIdentifier,
        baseRevision: UInt64,
        cache: BrushResourceCache,
        counters: BrushCompilerCounters,
        activeBrush: CompiledBrush?,
        brushes: [CompiledBrush]
    ) {
        self.owner = owner
        self.baseRevision = baseRevision
        self.cache = cache
        self.counters = counters
        self.activeBrush = activeBrush
        self.brushes = brushes
    }
}

public final class BrushCompilationRollbackToken {
    fileprivate let owner: ObjectIdentifier
    fileprivate let committedRevision: UInt64
    fileprivate let cache: BrushResourceCache
    fileprivate let counters: BrushCompilerCounters
    fileprivate let activeBrush: CompiledBrush?

    fileprivate init(
        owner: ObjectIdentifier,
        committedRevision: UInt64,
        cache: BrushResourceCache,
        counters: BrushCompilerCounters,
        activeBrush: CompiledBrush?
    ) {
        self.owner = owner
        self.committedRevision = committedRevision
        self.cache = cache
        self.counters = counters
        self.activeBrush = activeBrush
    }
}

struct BrushCompilerRevisionSnapshot: Equatable, Sendable {
    let requestGeneration: UInt64
    let stateRevision: UInt64
    let isExhausted: Bool
}

@MainActor
public final class BrushCompiler {
    public private(set) var activeBrush: CompiledBrush?

    public var debugCounters: BrushCompilerCounters {
        counters
    }

    public var diagnosticSnapshot: BrushCompilerDiagnosticSnapshot {
        BrushCompilerDiagnosticSnapshot(
            counters: counters,
            cacheResidentBytes: cache.residentByteCount,
            cacheBudgetBytes: profile.brushCacheBudgetBytes,
            cachedResourceCount: cache.keys.count,
            pinnedResourceCount: cache.pinnedKeys.count,
            activeDefinitionID: activeBrush?.program.definition.id.rawValue
        )
    }

    package var cachedKeys: [String] {
        cache.keys
    }

    package var pinnedKeys: [String] {
        cache.pinnedKeys
    }

    package var residentByteCount: Int {
        cache.residentByteCount
    }

    var revisionSnapshot: BrushCompilerRevisionSnapshot {
        BrushCompilerRevisionSnapshot(
            requestGeneration: requestGeneration,
            stateRevision: stateRevision,
            isExhausted: revisionExhausted
        )
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let profile: BrushDeviceProfile
    private let backendRegistry: BrushBackendRegistry
    private let pipelinePreparing: any DepositionPipelinePreparing
    private let testHooks: BrushCompilerTestHooks
    private var cache: BrushResourceCache
    private var counters: BrushCompilerCounters
    private var requestGeneration: UInt64
    private var packageHashTask: Task<String, Error>?
    private var stateRevision: UInt64
    private var revisionExhausted: Bool

    public convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        profile: BrushDeviceProfile
    ) {
        self.init(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelinePreparing: DepositionPipelineLibrary(device: device),
            testHooks: .none
        )
    }

    public convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        profile: BrushDeviceProfile,
        pipelineLibrary: DepositionPipelineLibrary
    ) {
        self.init(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelinePreparing: pipelineLibrary,
            testHooks: .none
        )
    }

    package init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        profile: BrushDeviceProfile,
        pipelinePreparing: any DepositionPipelinePreparing,
        testHooks: BrushCompilerTestHooks,
        initialRequestGeneration: UInt64 = 0,
        initialStateRevision: UInt64 = 0,
        backendRegistry: BrushBackendRegistry = .nativeSchema3
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.profile = profile
        self.backendRegistry = backendRegistry
        self.pipelinePreparing = pipelinePreparing
        self.testHooks = testHooks
        cache = BrushResourceCache(byteBudget: profile.brushCacheBudgetBytes)
        counters = .zero
        requestGeneration = initialRequestGeneration
        packageHashTask = nil
        stateRevision = initialStateRevision
        revisionExhausted = false
    }

    public func compileAndActivate(
        definition: BrushDefinition
    ) async throws -> CompiledBrush {
        let package = try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: definition,
            resourceData: [:]
        )
        return try await compileAndActivate(package: package)
    }

    /// Compiles an ordered brush set against an isolated copy of compiler
    /// state. Failed or superseded preparation cannot alter the live cache,
    /// active brush, counters, or diagnostics.
    public func prepareCompilationBatch(
        packages: [BrushPackage]
    ) async throws -> BrushCompilationBatch {
        guard !packages.isEmpty else {
            throw CancellationError()
        }
        try requireRevisionCapacity()
        let baseRevision = stateRevision
        let staging = BrushCompiler(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelinePreparing: pipelinePreparing,
            testHooks: testHooks,
            backendRegistry: backendRegistry
        )
        staging.cache = cache
        staging.counters = counters
        staging.activeBrush = activeBrush

        var brushes: [CompiledBrush] = []
        brushes.reserveCapacity(packages.count)
        for package in packages {
            brushes.append(
                try await staging.compileAndActivate(package: package)
            )
        }
        try requireRevisionCapacity()
        return BrushCompilationBatch(
            owner: ObjectIdentifier(self),
            baseRevision: baseRevision,
            cache: staging.cache,
            counters: staging.counters,
            activeBrush: staging.activeBrush,
            brushes: brushes
        )
    }

    /// Publishes a successfully prepared batch only if the live compiler has
    /// not changed since preparation began.
    public func commitCompilationBatch(
        _ batch: BrushCompilationBatch
    ) throws -> BrushCompilationRollbackToken {
        let nextRevision = try nextStateRevision()
        guard batch.owner == ObjectIdentifier(self),
              batch.baseRevision == stateRevision
        else {
            throw CancellationError()
        }
        let rollback = BrushCompilationRollbackToken(
            owner: ObjectIdentifier(self),
            committedRevision: nextRevision,
            cache: cache,
            counters: counters,
            activeBrush: activeBrush
        )
        cache = batch.cache
        counters = batch.counters
        activeBrush = batch.activeBrush
        stateRevision = nextRevision
        return rollback
    }

    /// Restores the state replaced by one exact batch commit. Rollback never
    /// rewinds the compiler revision, so every batch prepared before either
    /// the commit or rollback remains invalid.
    public func rollbackCompilationBatch(
        _ rollback: BrushCompilationRollbackToken
    ) throws {
        let nextRevision = try nextStateRevision()
        guard rollback.owner == ObjectIdentifier(self),
              rollback.committedRevision == stateRevision
        else {
            throw CancellationError()
        }
        cache = rollback.cache
        counters = rollback.counters
        activeBrush = rollback.activeBrush
        stateRevision = nextRevision
    }

    public func compileAndActivate(
        package: BrushPackage
    ) async throws -> CompiledBrush {
        let generation = try beginRequest()
        var stagedCounters = counters
        let definitionID = package.definition.id.rawValue
        let packageHash = try await packageContentHash(
            package,
            definitionID: definitionID,
            generation: generation
        )
        let renderIdentity = try BrushRenderIdentity(
            definitionID: package.definition.id,
            semanticHash: packageHash
        )
        let requestedBackend: BrushBackendKind =
            package.definition.components.allSatisfy {
                $0.material.interaction == .none
            }
            ? .deposition
            : .canvasInteraction
        let program: BrushProgram
        do {
            program = try BrushProgramCompiler.compile(package.definition)
        } catch {
            throw try failure(
                packageHash: packageHash,
                backend: requestedBackend,
                stage: .definition,
                resourceID: nil,
                requestedBytes: nil,
                reason: "programCompilationFailed",
                definitionID: definitionID
            )
        }

        let backendContract: CompiledBrushBackendContract
        do {
            backendContract = try BrushBackendCompiler(
                registry: backendRegistry
            ).compile(program: program, forActivation: true)
        } catch let error as BrushBackendCompilationError {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .pipelineSelection,
                resourceID: nil,
                requestedBytes: nil,
                reason: backendFailureReason(error),
                definitionID: definitionID
            )
        }
        guard case .deposition = backendContract else {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .pipelineSelection,
                resourceID: nil,
                requestedBytes: nil,
                reason: "backendEncoderUnavailable",
                definitionID: definitionID
            )
        }
        let effectiveDimension = min(
            BrushDeviceProfile.maximumPortableTextureDimension,
            profile.maximumWorkingTextureDimension,
            package.definition.limits.maximumResourceDimension
        )
        let effectiveBudget = min(
            profile.brushCacheBudgetBytes,
            package.definition.limits.maximumResidentBytes
        )
        let effectiveProfile = try BrushDeviceProfile(
            registryID: profile.registryID,
            recommendedWorkingSetBytes: profile.recommendedWorkingSetBytes,
            maximumWorkingTextureDimension: effectiveDimension,
            brushCacheBudgetBytes: effectiveBudget,
            targetFramesPerSecond: profile.targetFramesPerSecond,
            depositionFrameBudget: profile.depositionFrameBudget
        )

        let work: [BrushCompilerResourceWork]
        do {
            work = try prepareWork(
                package: package,
                effectiveDimension: effectiveDimension
            )
        } catch let error as BrushCompilerPreparationError {
            let context = preparationFailureContext(error)
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .imageDecode,
                resourceID: context.resourceID,
                requestedBytes: nil,
                reason: context.reason,
                definitionID: definitionID
            )
        }

        let projectedBytes: Int
        do {
            projectedBytes = try checkedUniqueProjectedBytes(work)
        } catch {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .residency,
                resourceID: nil,
                requestedBytes: nil,
                reason: "resourceCostOverflow",
                definitionID: definitionID
            )
        }
        guard projectedBytes <= effectiveBudget else {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .residency,
                resourceID: nil,
                requestedBytes: projectedBytes,
                reason: "unsupportedResourceCost",
                definitionID: definitionID
            )
        }

        let primaryPipelineKey = pipelineKey(
            program: program,
            component: program.primaryComponent
        )
        let primaryPipeline: DepositionPipelineBinding
        let secondaryPipeline: DepositionPipelineBinding?
        do {
            primaryPipeline = try await preparePipeline(
                for: primaryPipelineKey,
                generation: generation
            )
            if let secondaryComponent = program.secondaryComponent {
                secondaryPipeline = try await preparePipeline(
                    for: pipelineKey(
                        program: program,
                        component: secondaryComponent
                    ),
                    generation: generation
                )
            } else {
                secondaryPipeline = nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .pipelineSelection,
                resourceID: nil,
                requestedBytes: nil,
                reason: "pipelinePreparationFailed",
                definitionID: definitionID
            )
        }
        increment(.packageDecode, in: &stagedCounters)

        try ensureCurrent(generation)
        var candidates: [String: BrushResourceCache.Candidate] = [:]
        var textureBindings: [String: String] = [:]
        var compatibility: [BrushCompatibilityEntry] = []
        var diagnostics: [BrushCompilationDiagnostic] = []
        var seenKeys = Set<String>()

        for item in work {
            textureBindings[item.resourceID] = item.cacheKey
            diagnostics.append(contentsOf: item.diagnostics)
            if item.usedFallback {
                compatibility.append(
                    BrushCompatibilityEntry(
                        semanticKey: "resource.\(item.resourceID)",
                        level: .approximated,
                        message: "Declared built-in fallback was used."
                    )
                )
            }
            guard seenKeys.insert(item.cacheKey).inserted else { continue }

            if cache.entry(for: item.cacheKey) != nil {
                increment(.cacheHit, in: &stagedCounters)
                continue
            }

            try await phase(
                .beforeDecode,
                definitionID: definitionID,
                resourceID: item.resourceID,
                generation: generation
            )
            let decoded: DecodedBrushTexture
            do {
                let source = item.source
                let resourceID = item.resourceID
                let decodeTask = Task.detached(
                    priority: .userInitiated
                ) { () throws -> DecodedBrushTexture in
                    try Task.checkCancellation()
                    let result: DecodedBrushTexture
                    switch source {
                    case let .packaged(resource, data):
                        result = try BrushAssetDecoder.decode(
                            resource: resource,
                            data: data,
                            profile: effectiveProfile
                        )
                    case let .builtIn(identity, maximumDimension):
                        result = try BrushTextureFactory.makeCPUPyramid(
                            identity: identity,
                            resourceID: resourceID,
                            maximumDimension: maximumDimension
                        )
                    }
                    try Task.checkCancellation()
                    return result
                }
                decoded = try await withTaskCancellationHandler {
                    try await decodeTask.value
                } onCancel: {
                    decodeTask.cancel()
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw try failure(
                    packageHash: packageHash,
                    backend: program.requestedBackend,
                    stage: .imageDecode,
                    resourceID: item.resourceID,
                    requestedBytes: item.projectedResidentBytes,
                    reason: "assetDecodeFailed",
                    definitionID: definitionID
                )
            }
            if case .packaged = item.source {
                increment(.imageDecode, in: &stagedCounters)
            }
            try await phase(
                .betweenResources,
                definitionID: definitionID,
                resourceID: item.resourceID,
                generation: generation
            )
            try await phase(
                .beforeUpload,
                definitionID: definitionID,
                resourceID: item.resourceID,
                generation: generation
            )
            increment(.textureUpload, in: &stagedCounters)
            let injectedUploadFailure: BrushTextureUploadPhase? =
                testHooks.uploadFailureResourceID == item.resourceID
                ? .beforeEncoderCreation
                : nil
            let texture: any MTLTexture
            do {
                texture = try await BrushTextureUploader(
                    device: device,
                    commandQueue: commandQueue,
                    injectedFailure: injectedUploadFailure
                ).upload(decoded)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw try failure(
                    packageHash: packageHash,
                    backend: program.requestedBackend,
                    stage: .textureUpload,
                    resourceID: item.resourceID,
                    requestedBytes: decoded.residentByteCount,
                    reason: "textureUploadFailed",
                    definitionID: definitionID
                )
            }
            try await phase(
                .afterUpload,
                definitionID: definitionID,
                resourceID: item.resourceID,
                generation: generation
            )
            candidates[item.cacheKey] = .init(
                texture: texture,
                byteCount: decoded.residentByteCount,
                tipSupport: decoded.tipSupport
            )
        }

        try await phase(
            .beforeCacheTransaction,
            definitionID: definitionID,
            resourceID: nil,
            generation: generation
        )
        try ensureCurrent(generation)
        if testHooks.admissionFailureDefinitionID == definitionID {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .residency,
                resourceID: nil,
                requestedBytes: projectedBytes,
                reason: "injectedAdmissionFailure",
                definitionID: definitionID
            )
        }

        let activeKeys = Set(textureBindings.values)
        var stagedCache = cache
        do {
            _ = try stagedCache.activate(
                activeKeys: activeKeys,
                candidates: candidates
            )
        } catch {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .residency,
                resourceID: nil,
                requestedBytes: projectedBytes,
                reason: "residencyFailed",
                definitionID: definitionID
            )
        }

        let residentBytes = try checkedActiveBytes(
            activeKeys,
            cache: stagedCache
        )
        let primaryComponent: CompiledBrushComponent
        let secondaryComponent: CompiledBrushComponent?
        do {
            primaryComponent = try compiledComponent(
                program: program,
                component: program.primaryComponent,
                pipeline: primaryPipeline,
                bindings: textureBindings,
                cache: stagedCache
            )
            if let secondaryProgram = program.secondaryComponent,
               let secondaryPipeline
            {
                secondaryComponent = try compiledComponent(
                    program: program,
                    component: secondaryProgram,
                    pipeline: secondaryPipeline,
                    bindings: textureBindings,
                    cache: stagedCache
                )
            } else {
                secondaryComponent = nil
            }
        } catch let error as DepositionPreparationError {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .pipelineSelection,
                resourceID: depositionResourceID(error),
                requestedBytes: nil,
                reason: depositionFailureReason(error),
                definitionID: definitionID
            )
        } catch let error as BrushCompilerPreparationError {
            let context = preparationFailureContext(error)
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .pipelineSelection,
                resourceID: context.resourceID,
                requestedBytes: nil,
                reason: context.reason,
                definitionID: definitionID
            )
        }
        let report = try BrushCompilationReport(
            definitionID: definitionID,
            packageContentHash: packageHash,
            backend: program.requestedBackend,
            compatibility: compatibility.sorted {
                $0.semanticKey < $1.semanticKey
            },
            performance: performance(
                definition: package.definition,
                program: program,
                residentBytes: residentBytes,
                work: work
            ),
            encodedResourceBytes: try checkedEncodedResourceBytes(package),
            residentResourceBytes: residentBytes,
            deviceRegistryID: profile.registryID
        )
        let compiled = CompiledBrush(
            program: program,
            backendContract: backendContract,
            renderIdentity: renderIdentity,
            primaryComponent: primaryComponent,
            secondaryComponent: secondaryComponent,
            residentByteCount: residentBytes,
            report: report,
            diagnostics: diagnostics,
            cacheKeys: activeKeys
        )

        // This is the only installation point. No await or cancellable hook is
        // permitted between this final generation check and state replacement.
        try ensureCurrent(generation)
        cache = stagedCache
        activeBrush = compiled
        increment(.activation, in: &stagedCounters)
        counters = stagedCounters
        return compiled
    }

    /// Produces deterministic inspection evidence for packages whose backend
    /// is not executable by the deposition renderer. It intentionally does
    /// not decode, upload, cache, or activate resources.
    public func inspectionReport(
        for package: BrushPackage
    ) throws -> BrushCompilationReport {
        let program = try BrushProgramCompiler.compile(package.definition)
        let backendContract = try BrushBackendCompiler(
            registry: backendRegistry
        ).compile(program: program, forActivation: false)
        let hash = try package.contentHash
        let compatibility: [BrushCompatibilityEntry] = switch backendContract {
        case .deposition:
            []
        case .canvasInteraction:
            [BrushCompatibilityEntry(
                semanticKey: "material.interaction",
                level: .unsupported,
                message: "Canvas interaction is not executable by deposition."
            )]
        }
        return try BrushCompilationReport(
            definitionID: package.definition.id.rawValue,
            packageContentHash: hash,
            backend: program.requestedBackend,
            compatibility: compatibility,
            performance: BrushPerformanceClassification(
                tier: .realtime120,
                basis: .estimated,
                reason: "Inspection only; backend activation is unsupported."
            ),
            encodedResourceBytes: try checkedEncodedResourceBytes(package),
            residentResourceBytes: 0,
            deviceRegistryID: profile.registryID
        )
    }

    private func backendFailureReason(
        _ error: BrushBackendCompilationError
    ) -> String {
        switch error {
        case let .registry(registryError):
            switch registryError {
            case .unsupportedSchema:
                "unsupportedBackendSchema"
            case .unknownBackend:
                "unknownBackend"
            case .duplicateRegistration,
                 .implementedCapabilitiesNotDeclared:
                "invalidBackendRegistry"
            }
        case .retiredNativeIdentifier:
            "retiredNativeIdentifier"
        case .unsupportedRequiredSemantic:
            "unsupportedRequiredSemantic"
        case .unsupportedInteraction:
            "unsupportedInteraction"
        case .unsupportedEdgeTreatment(.wetConcentration):
            "unsupportedWetConcentration"
        case .unsupportedEdgeTreatment:
            "unsupportedEdgeTreatment"
        case .missingDeclaredCapability:
            "missingBackendCapability"
        case let .missingImplementedCapability(capability):
            capability == .secondaryColorSource
                ? "unimplementedSecondaryColorSource"
                : "unimplementedBackendCapability"
        case .backendUnavailable:
            "backendEncoderUnavailable"
        }
    }

    private func depositionFailureReason(
        _ error: DepositionPreparationError
    ) -> String {
        switch error {
        case .unsupportedInteraction:
            "unsupportedInteraction"
        case .unsupportedEdgeTreatment(.wetConcentration):
            "unsupportedWetConcentration"
        case .unsupportedEdgeTreatment:
            "unsupportedEdgeTreatment"
        case .missingRequiredResource:
            "missingRequiredResource"
        case .pipelinePreparationFailed:
            "pipelinePreparationFailed"
        }
    }

    private func depositionResourceID(
        _ error: DepositionPreparationError
    ) -> String? {
        switch error {
        case let .missingRequiredResource(resourceID):
            resourceID
        case .unsupportedInteraction,
             .unsupportedEdgeTreatment,
             .pipelinePreparationFailed:
            nil
        }
    }

    public func handleMemoryPressure(
        targetResidentBytes: Int
    ) -> BrushResourcePressureResult {
        let result = cache.handleMemoryPressure(
            targetResidentBytes: targetResidentBytes
        )
        if case let .satisfied(evictedKeys) = result,
           !evictedKeys.isEmpty,
           !revisionExhausted
        {
            let (nextRevision, overflow) =
                stateRevision.addingReportingOverflow(1)
            if overflow {
                exhaustRevision()
            } else {
                stateRevision = nextRevision
            }
        }
        return result
    }

    private func beginRequest() throws -> UInt64 {
        guard !revisionExhausted else { throw CancellationError() }
        let (nextGeneration, generationOverflow) =
            requestGeneration.addingReportingOverflow(1)
        let (nextRevision, revisionOverflow) =
            stateRevision.addingReportingOverflow(1)
        guard !generationOverflow, !revisionOverflow else {
            exhaustRevision()
            throw CancellationError()
        }
        requestGeneration = nextGeneration
        stateRevision = nextRevision
        packageHashTask?.cancel()
        packageHashTask = nil
        return nextGeneration
    }

    private func requireRevisionCapacity() throws {
        _ = try nextStateRevision()
    }

    private func nextStateRevision() throws -> UInt64 {
        guard !revisionExhausted else { throw CancellationError() }
        let (nextRevision, overflow) =
            stateRevision.addingReportingOverflow(1)
        guard !overflow else {
            exhaustRevision()
            throw CancellationError()
        }
        return nextRevision
    }

    private func exhaustRevision() {
        revisionExhausted = true
        packageHashTask?.cancel()
        packageHashTask = nil
    }

    private func packageContentHash(
        _ package: BrushPackage,
        definitionID: String,
        generation: UInt64
    ) async throws -> String {
        let onPackageHash = testHooks.onPackageHash
        let task = Task.detached(
            priority: .userInitiated
        ) { () throws -> String in
            try Task.checkCancellation()
            try await onPackageHash(definitionID)
            try Task.checkCancellation()
            let result = try package.contentHash
            try Task.checkCancellation()
            return result
        }
        packageHashTask = task
        defer {
            if generation == requestGeneration {
                packageHashTask = nil
            }
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try ensureCurrent(generation)
        return result
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard !revisionExhausted,
              generation == requestGeneration
        else {
            throw CancellationError()
        }
    }

    private func phase(
        _ phase: BrushCompilerPhase,
        definitionID: String,
        resourceID: String?,
        generation: UInt64
    ) async throws {
        try ensureCurrent(generation)
        await testHooks.onPhase(
            BrushCompilerPhaseContext(
                phase: phase,
                definitionID: definitionID,
                resourceID: resourceID
            )
        )
        try ensureCurrent(generation)
    }

    private func prepareWork(
        package: BrushPackage,
        effectiveDimension: Int
    ) throws -> [BrushCompilerResourceWork] {
        let manifest = Dictionary(
            uniqueKeysWithValues: package.manifest.resources
                .filter { $0.kind != .preview }
                .map { ($0.id, $0) }
        )
        var work: [String: BrushCompilerResourceWork] = [:]

        let references = package.definition.components
            .flatMap(\.resources)
            .filter { $0.kind != .preview }
            .sorted {
                if $0.identifier == $1.identifier {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.identifier < $1.identifier
            }
        for reference in references
        {
            if let existing = work[reference.identifier] {
                guard existing.kind == reference.kind else {
                    throw BrushCompilerPreparationError
                        .resourceIdentifierCollision(
                            resourceID: reference.identifier
                        )
                }
                continue
            }
            if let resource = manifest[reference.identifier] {
                guard let data = package.resourceData[resource.id] else {
                    throw BrushCompilerPreparationError
                        .missingManifestResource(resourceID: resource.id)
                }
                let dimensions = workingDimensions(
                    width: resource.pixelWidth,
                    height: resource.pixelHeight,
                    ceiling: effectiveDimension
                )
                let bytes = try projectedMipBytes(
                    width: dimensions.width,
                    height: dimensions.height
                )
                let key = BrushResourceCacheKey.make(
                    contentHash: resource.sha256,
                    sourceValidationHash: sourceValidationHash(
                        resource: resource
                    ),
                    kind: reference.kind,
                    width: dimensions.width,
                    height: dimensions.height
                )
                work[reference.identifier] = BrushCompilerResourceWork(
                    resourceID: reference.identifier,
                    kind: reference.kind,
                    cacheKey: key,
                    source: .packaged(resource: resource, data: data),
                    usedFallback: false,
                    projectedResidentBytes: bytes,
                    diagnostics: dimensions.width == resource.pixelWidth
                        && dimensions.height == resource.pixelHeight
                        ? []
                        : [
                            .resourceResampled(
                                id: reference.identifier,
                                sourceWidth: resource.pixelWidth,
                                sourceHeight: resource.pixelHeight,
                                workingWidth: dimensions.width,
                                workingHeight: dimensions.height
                            ),
                        ]
                )
            } else {
                guard case let .builtIn(identifier)? = reference.fallback,
                      let identity = BrushTextureIdentity(rawValue: identifier)
                else {
                    throw BrushCompilerPreparationError.unknownBuiltIn(
                        resourceID: reference.identifier
                    )
                }
                work[reference.identifier] = try builtInWork(
                    identity: identity,
                    resourceID: reference.identifier,
                    usedFallback: true,
                    maximumDimension: effectiveDimension
                )
            }
        }

        for shape in package.definition.components.flatMap({
            $0.coverage.shapes
        }) {
            guard let identity = identity(for: shape.shape) else { continue }
            if let existing = work[identity.rawValue] {
                guard case let .builtIn(existingIdentity, _) = existing.source,
                      existingIdentity == identity
                else {
                    throw BrushCompilerPreparationError
                        .resourceIdentifierCollision(
                            resourceID: identity.rawValue
                        )
                }
            } else {
                work[identity.rawValue] = try builtInWork(
                    identity: identity,
                    resourceID: identity.rawValue,
                    usedFallback: false,
                    maximumDimension: effectiveDimension
                )
            }
        }
        for grain in package.definition.components.flatMap({
            $0.coverage.grains
        }) {
            guard let identity = identity(for: grain.grain) else { continue }
            if let existing = work[identity.rawValue] {
                guard case let .builtIn(existingIdentity, _) = existing.source,
                      existingIdentity == identity
                else {
                    throw BrushCompilerPreparationError
                        .resourceIdentifierCollision(
                            resourceID: identity.rawValue
                        )
                }
            } else {
                work[identity.rawValue] = try builtInWork(
                    identity: identity,
                    resourceID: identity.rawValue,
                    usedFallback: false,
                    maximumDimension: effectiveDimension
                )
            }
        }
        return work.values.sorted { $0.resourceID < $1.resourceID }
    }

    private func builtInWork(
        identity: BrushTextureIdentity,
        resourceID: String,
        usedFallback: Bool,
        maximumDimension: Int
    ) throws -> BrushCompilerResourceWork {
        let workingDimension = min(
            identity.sourceDimension,
            maximumDimension
        )
        let projectedBytes = try projectedMipBytes(
            width: workingDimension,
            height: workingDimension
        )
        let contentIdentity = [
            BrushTextureFactory.cpuPyramidContentVersion,
            identity.rawValue,
            "\(workingDimension)x\(workingDimension)",
        ].joined(separator: ":")
        return BrushCompilerResourceWork(
            resourceID: resourceID,
            kind: identity.kind == .shape ? .shape : .grain,
            cacheKey: BrushResourceCacheKey.make(
                contentHash: BrushContentHash.sha256Hex(
                    of: Data(contentIdentity.utf8)
                ),
                sourceValidationHash: BrushContentHash.sha256Hex(
                    of: Data(
                        "builtin-source-v1:\(identity.rawValue)".utf8
                    )
                ),
                kind: identity.kind == .shape ? .shape : .grain,
                width: workingDimension,
                height: workingDimension
            ),
            source: .builtIn(
                identity: identity,
                maximumDimension: maximumDimension
            ),
            usedFallback: usedFallback,
            projectedResidentBytes: projectedBytes,
            diagnostics: workingDimension == identity.sourceDimension
                ? []
                : [
                    .resourceResampled(
                        id: resourceID,
                        sourceWidth: identity.sourceDimension,
                        sourceHeight: identity.sourceDimension,
                        workingWidth: workingDimension,
                        workingHeight: workingDimension
                    ),
                ]
        )
    }

    private func sourceValidationHash(
        resource: BrushPackageResource
    ) -> String {
        let identity = [
            "packaged-source-v1",
            resource.mediaType,
            "\(resource.pixelWidth)x\(resource.pixelHeight)",
        ].joined(separator: ":")
        return BrushContentHash.sha256Hex(of: Data(identity.utf8))
    }

    private func identity(
        for descriptor: BrushShapeDescriptor
    ) -> BrushTextureIdentity? {
        switch descriptor {
        case .hardRound, .softRound, .chisel, .asset:
            nil
        }
    }

    private func identity(
        for descriptor: BrushGrainDescriptor
    ) -> BrushTextureIdentity? {
        switch descriptor {
        case .opaque: .opaqueGrain
        case .paper: .paperGrain
        case .noise: .noiseGrain
        case .asset: nil
        }
    }

    private func workingDimensions(
        width: Int,
        height: Int,
        ceiling: Int
    ) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > ceiling else { return (width, height) }
        let scale = Double(ceiling) / Double(longest)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    private func projectedMipBytes(
        width: Int,
        height: Int
    ) throws -> Int {
        var width = width
        var height = height
        var total = 0
        while true {
            let (level, multiplyOverflow) =
                width.multipliedReportingOverflow(by: height)
            let (next, addOverflow) = total.addingReportingOverflow(level)
            guard !multiplyOverflow, !addOverflow else {
                throw BrushCompilerPreparationError.resourceCostOverflow
            }
            total = next
            guard width > 1 || height > 1 else { return total }
            width = max(1, width / 2)
            height = max(1, height / 2)
        }
    }

    private func checkedUniqueProjectedBytes(
        _ work: [BrushCompilerResourceWork]
    ) throws -> Int {
        var seen = Set<String>()
        var total = 0
        for item in work where seen.insert(item.cacheKey).inserted {
            let (next, overflow) = total.addingReportingOverflow(
                item.projectedResidentBytes
            )
            guard !overflow else {
                throw BrushCompilerPreparationError.resourceCostOverflow
            }
            total = next
        }
        return total
    }

    private func checkedEncodedResourceBytes(
        _ package: BrushPackage
    ) throws -> Int {
        var total = 0
        for resource in package.manifest.resources
            .filter({ $0.kind != .preview })
            .sorted(by: { $0.id < $1.id })
        {
            let (next, overflow) = total.addingReportingOverflow(
                resource.encodedByteCount
            )
            guard !overflow else {
                throw BrushCompilerPreparationError.resourceCostOverflow
            }
            total = next
        }
        return total
    }

    private func checkedActiveBytes(
        _ keys: Set<String>,
        cache: BrushResourceCache
    ) throws -> Int {
        var total = 0
        for key in keys.sorted() {
            guard let entry = cache.entry(for: key) else {
                throw BrushResourceCacheError.missingCandidate(key)
            }
            let (next, overflow) = total.addingReportingOverflow(entry.byteCount)
            guard !overflow else {
                throw BrushCompilerPreparationError.resourceCostOverflow
            }
            total = next
        }
        return total
    }

    private func textureDictionary(
        bindings: [String: String],
        cache: BrushResourceCache
    ) throws -> [String: any MTLTexture] {
        var textures: [String: any MTLTexture] = [:]
        for resourceID in bindings.keys.sorted() {
            guard let key = bindings[resourceID],
                  let entry = cache.entry(for: key)
            else {
                throw BrushResourceCacheError
                    .missingCandidate(bindings[resourceID] ?? resourceID)
            }
            textures[resourceID] = entry.texture
        }
        return textures
    }

    private func componentTextureBindings(
        component: BrushComponentDefinition,
        bindings: [String: String]
    ) -> [String: String] {
        var identifiers = Set(
            component.resources
                .filter { $0.kind != .preview }
                .map(\.identifier)
        )
        for shape in component.coverage.shapes {
            if let identity = identity(for: shape.shape) {
                identifiers.insert(identity.rawValue)
            }
        }
        for grain in component.coverage.grains {
            if let identity = identity(for: grain.grain) {
                identifiers.insert(identity.rawValue)
            }
        }
        return Dictionary(uniqueKeysWithValues: identifiers.compactMap {
            identifier in
            bindings[identifier].map { (identifier, $0) }
        })
    }

    private func compiledComponent(
        program: BrushProgram,
        component: BrushComponentProgram,
        pipeline: DepositionPipelineBinding,
        bindings: [String: String],
        cache: BrushResourceCache
    ) throws -> CompiledBrushComponent {
        let definition = component.definition
        let componentBindings = componentTextureBindings(
            component: definition,
            bindings: bindings
        )
        let textures = try textureDictionary(
            bindings: componentBindings,
            cache: cache
        )
        let tipSupports = try compiledTipSupports(
            definition: definition,
            bindings: componentBindings,
            cache: cache
        )
        let uniformTemplate = BrushUniformTemplate(
            placement: definition.placement,
            coverage: definition.coverage,
            color: definition.color,
            material: definition.material
        )
        let material = try DepositionMaterialBinding(
            uniformTemplate: uniformTemplate,
            textures: textures,
            tipSupports: tipSupports
        )
        return CompiledBrushComponent(
            identifier: definition.identifier,
            ordinal: definition.ordinal,
            pipelineKey: pipelineKey(
                program: program,
                component: component
            ),
            uniformTemplate: uniformTemplate,
            textures: textures,
            tipSupports: tipSupports,
            cursorTipProfile: try cursorTipProfile(
                definition: definition,
                tipSupports: tipSupports
            ),
            depositionPipeline: pipeline,
            depositionMaterial: material
        )
    }

    private func preparePipeline(
        for brushKey: BrushPipelineKey,
        generation: UInt64
    ) async throws -> DepositionPipelineBinding {
        let key = DepositionPipelineKey(
            brush: brushKey,
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue:
                DocumentColorPipeline.workingPixelFormat.rawValue,
            sampleCount: DocumentColorPipeline.renderSampleCount
        )
        let binding = try await pipelinePreparing.prepare(for: key)
        try ensureCurrent(generation)
        return binding
    }

    private func compiledTipSupports(
        definition: BrushComponentDefinition,
        bindings: [String: String],
        cache: BrushResourceCache
    ) throws -> [CompiledBrushTipSupport] {
        try definition.coverage.shapes.enumerated().map { index, layer in
            let declared = definition.tipSupports[index]
            let source: CompiledBrushTipSource
            let assetSupport: BrushTipAssetSupport?
            let sourceWidth: Int?
            let sourceHeight: Int?
            let mipLevelCount: Int
            let sourceIdentity: String

            switch layer.shape {
            case .hardRound:
                source = .analyticEllipse
                assetSupport = nil
                sourceWidth = nil
                sourceHeight = nil
                mipLevelCount = 0
                sourceIdentity = "analytic-hard-round"
            case .softRound:
                source = .analyticEllipse
                assetSupport = nil
                sourceWidth = nil
                sourceHeight = nil
                mipLevelCount = 0
                sourceIdentity = "analytic-soft-round"
            case .chisel:
                source = .analyticRectangle
                assetSupport = nil
                sourceWidth = nil
                sourceHeight = nil
                mipLevelCount = 0
                sourceIdentity = "analytic-rectangle"
            case let .asset(resourceID):
                guard let key = bindings[resourceID],
                      let entry = cache.entry(for: key),
                      let support = entry.tipSupport
                else {
                    throw BrushCompilerPreparationError.missingTipSupport(
                        resourceID: resourceID
                    )
                }
                source = .texture(resourceID: resourceID)
                assetSupport = support
                sourceWidth = entry.texture.width
                sourceHeight = entry.texture.height
                mipLevelCount = entry.texture.mipmapLevelCount
                sourceIdentity = key
            }
            let semanticIdentity = [
                "compiled-tip-v1",
                sourceIdentity,
                declared.kind.rawValue,
                declared.bounds.map {
                    [
                        String($0.minX.bitPattern),
                        String($0.maxX.bitPattern),
                        String($0.minY.bitPattern),
                        String($0.maxY.bitPattern),
                    ].joined(separator: ",")
                } ?? "full-support",
                String(layer.scale.bitPattern),
                String(layer.rotation.bitPattern),
                String(layer.offset.x.bitPattern),
                String(layer.offset.y.bitPattern),
            ].joined(separator: ":")
            return CompiledBrushTipSupport(
                semanticTipHash: BrushContentHash.sha256Hex(
                    of: Data(semanticIdentity.utf8)
                ),
                source: source,
                definition: declared,
                assetSupport: assetSupport,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                mipLevelCount: mipLevelCount
            )
        }
    }

    private func cursorTipProfile(
        definition: BrushComponentDefinition,
        tipSupports: [CompiledBrushTipSupport]
    ) throws -> BrushCursorTipProfile {
        guard tipSupports.count == definition.coverage.shapes.count,
              let primarySupport = tipSupports.first
        else {
            throw BrushCompilerPreparationError.missingTipSupport(
                resourceID: definition.identifier.rawValue
            )
        }
        func cursorShape(
            _ support: CompiledBrushTipSupport
        ) throws -> BrushCursorTipShape {
            switch support.source {
            case .analyticEllipse:
                return .analyticEllipse
            case .analyticRectangle:
                return .analyticRectangle
            case let .texture(resourceID):
                guard let contour = support.assetSupport?.contour else {
                    throw BrushCompilerPreparationError.missingTipSupport(
                        resourceID: resourceID
                    )
                }
                return .contour(contour)
            }
        }
        let secondary = tipSupports.count == 2
            ? try cursorShape(tipSupports[1])
            : nil
        return BrushCursorTipProfile(
            primary: try cursorShape(primarySupport),
            secondary: secondary,
            secondaryCombination: secondary == nil
                ? nil
                : definition.coverage.shapes[1].combination
        )
    }

    private func pipelineKey(
        program: BrushProgram,
        component: BrushComponentProgram
    ) -> BrushPipelineKey {
        let definition = component.definition
        let coverage = definition.coverage
        return BrushPipelineKey(
            backend: program.requestedBackend,
            accumulation: definition.material.accumulation,
            edgeTreatment: definition.material.edgeTreatment,
            functionConstants: BrushFunctionConstants(
                usesSecondaryShape: coverage.shapes.count > 1,
                usesGrain: !coverage.grains.isEmpty,
                usesSecondaryGrain: coverage.grains.count > 1
            )
        )
    }

    private func performance(
        definition: BrushDefinition,
        program: BrushProgram,
        residentBytes: Int,
        work: [BrushCompilerResourceWork]
    ) -> BrushPerformanceClassification {
        let shapeKeys = Set(
            work.filter { $0.kind == .shape }.map(\.cacheKey)
        )
        let grainKeys = Set(
            work.filter { $0.kind == .grain }.map(\.cacheKey)
        )
        let simple = definition.components.count == 1
            && program.requestedBackend == .deposition
            && definition.components[0].coverage.shapes.count <= 1
            && definition.components[0].coverage.grains.count <= 1
            && shapeKeys.count <= 1
            && grainKeys.count <= 1
            && residentBytes <= 64 * 1_024 * 1_024
            && definition.performanceIntent == .realtime120
            && profile.targetFramesPerSecond >= 120
        return BrushPerformanceClassification(
            tier: simple ? .realtime120 : .realtime60,
            basis: .estimated,
            reason: simple
                ? "Estimated simple deposition workload."
                : "Estimated supported deposition workload."
        )
    }

    private func preparationFailureContext(
        _ error: BrushCompilerPreparationError
    ) -> (resourceID: String?, reason: String) {
        switch error {
        case let .unknownBuiltIn(resourceID):
            (resourceID, "unknownBuiltinResource")
        case let .missingManifestResource(resourceID):
            (resourceID, "missingResourceData")
        case let .resourceIdentifierCollision(resourceID):
            (resourceID, "resourceIdentifierCollision")
        case .resourceCostOverflow:
            (nil, "resourceCostOverflow")
        case let .missingTipSupport(resourceID):
            (resourceID, "missingTipSupport")
        }
    }

    private func failure(
        packageHash: String,
        backend: BrushBackendKind,
        stage: BrushCompilationStage,
        resourceID: String?,
        requestedBytes: Int?,
        reason: String,
        definitionID: String
    ) throws -> BrushCompilationFailure {
        try BrushCompilationFailure(
            definitionID: definitionID,
            packageContentHash: packageHash,
            backend: backend,
            stage: stage,
            resourceID: resourceID,
            requestedBytes: requestedBytes,
            deviceRegistryID: profile.registryID,
            reason: reason
        )
    }

    private func increment(
        _ field: BrushCompilerCounterField,
        in counters: inout BrushCompilerCounters
    ) {
        let old = counters
        func incremented(_ value: UInt64) -> UInt64 {
            value == .max ? .max : value + 1
        }
        counters = BrushCompilerCounters(
            packageDecodeCount: field == .packageDecode
                ? incremented(old.packageDecodeCount)
                : old.packageDecodeCount,
            imageDecodeCount: field == .imageDecode
                ? incremented(old.imageDecodeCount)
                : old.imageDecodeCount,
            textureUploadCount: field == .textureUpload
                ? incremented(old.textureUploadCount)
                : old.textureUploadCount,
            cacheHitCount: field == .cacheHit
                ? incremented(old.cacheHitCount)
                : old.cacheHitCount,
            activationCount: field == .activation
                ? incremented(old.activationCount)
                : old.activationCount
        )
    }
}
