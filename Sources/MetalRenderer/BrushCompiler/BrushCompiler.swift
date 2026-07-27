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

struct BrushCompilerPhaseContext: Equatable, Sendable {
    let phase: BrushCompilerPhase
    let definitionID: String
    let resourceID: String?
}

struct BrushCompilerTestHooks {
    let uploadFailureResourceID: String?
    let admissionFailureDefinitionID: String?
    let onPackageHash: @Sendable (String) async throws -> Void
    let onPhase:
        @MainActor @Sendable (BrushCompilerPhaseContext) async -> Void

    init(
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

    init(
        _ onPhase:
            @escaping @MainActor @Sendable
            (BrushCompilerPhaseContext) async -> Void
    ) {
        self.init(onPhase: onPhase)
    }

    static let none = BrushCompilerTestHooks()
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
}

private enum BrushCompilerCounterField {
    case packageDecode
    case imageDecode
    case textureUpload
    case cacheHit
    case activation
}

@MainActor
public final class BrushCompiler {
    public private(set) var activeBrush: CompiledBrush?

    public var debugCounters: BrushCompilerCounters {
        counters
    }

    var cachedKeys: [String] {
        cache.keys
    }

    var pinnedKeys: [String] {
        cache.pinnedKeys
    }

    var residentByteCount: Int {
        cache.residentByteCount
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let profile: BrushDeviceProfile
    private let testHooks: BrushCompilerTestHooks
    private var cache: BrushResourceCache
    private var counters: BrushCompilerCounters
    private var requestGeneration: UInt64
    private var packageHashTask: Task<String, Error>?

    public convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        profile: BrushDeviceProfile
    ) {
        self.init(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            testHooks: .none
        )
    }

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        profile: BrushDeviceProfile,
        testHooks: BrushCompilerTestHooks
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.profile = profile
        self.testHooks = testHooks
        cache = BrushResourceCache(byteBudget: profile.brushCacheBudgetBytes)
        counters = .zero
        requestGeneration = 0
        packageHashTask = nil
    }

    public func compileAndActivate(
        package: BrushPackage
    ) async throws -> CompiledBrush {
        let generation = try beginRequest()
        increment(.packageDecode)
        let definitionID = package.definition.id.rawValue
        let packageHash = try await packageContentHash(
            package,
            definitionID: definitionID,
            generation: generation
        )
        let requestedBackend: BrushBackendKind =
            package.definition.material.interaction == .none
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

        guard package.definition.compatibility.requiredSemanticKeys.isEmpty else {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .pipelineSelection,
                resourceID: nil,
                requestedBytes: nil,
                reason: "unsupportedRequiredSemantic",
                definitionID: definitionID
            )
        }
        guard program.requestedBackend == .deposition else {
            throw try failure(
                packageHash: packageHash,
                backend: program.requestedBackend,
                stage: .pipelineSelection,
                resourceID: nil,
                requestedBytes: nil,
                reason: "unsupportedBackend",
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
            targetFramesPerSecond: profile.targetFramesPerSecond
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
                increment(.cacheHit)
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
                        result = BrushTextureFactory.makeCPUPyramid(
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
                increment(.imageDecode)
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
            increment(.textureUpload)
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
                byteCount: decoded.residentByteCount
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

        let textures = try textureDictionary(
            bindings: textureBindings,
            cache: stagedCache
        )
        let residentBytes = try checkedActiveBytes(
            activeKeys,
            cache: stagedCache
        )
        let pipelineKey = pipelineKey(program: program)
        let uniformTemplate = BrushUniformTemplate(
            placement: package.definition.placement,
            coverage: package.definition.coverage,
            color: package.definition.color,
            material: package.definition.material
        )
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
            pipelineKey: pipelineKey,
            uniformTemplate: uniformTemplate,
            textures: textures,
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
        increment(.activation)
        return compiled
    }

    public func handleMemoryPressure(
        targetResidentBytes: Int
    ) -> BrushResourcePressureResult {
        cache.handleMemoryPressure(targetResidentBytes: targetResidentBytes)
    }

    private func beginRequest() throws -> UInt64 {
        let (next, overflow) = requestGeneration.addingReportingOverflow(1)
        guard !overflow else { throw CancellationError() }
        requestGeneration = next
        packageHashTask?.cancel()
        packageHashTask = nil
        return next
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
        guard generation == requestGeneration else {
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

        for reference in package.definition.resources
            .filter({ $0.kind != .preview })
            .sorted(by: { $0.identifier < $1.identifier })
        {
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

        for shape in package.definition.coverage.shapes {
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
        for grain in package.definition.coverage.grains {
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
            BrushTextureFactory.textureSize,
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
                width: workingDimension,
                height: workingDimension
            ),
            source: .builtIn(
                identity: identity,
                maximumDimension: maximumDimension
            ),
            usedFallback: usedFallback,
            projectedResidentBytes: projectedBytes,
            diagnostics: workingDimension == BrushTextureFactory.textureSize
                ? []
                : [
                    .resourceResampled(
                        id: resourceID,
                        sourceWidth: BrushTextureFactory.textureSize,
                        sourceHeight: BrushTextureFactory.textureSize,
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
        case .hardRound: .hardRoundShape
        case .softRound: .softRoundShape
        case .chisel: .chiselShape
        case .asset: nil
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

    private func pipelineKey(program: BrushProgram) -> BrushPipelineKey {
        let coverage = program.definition.coverage
        return BrushPipelineKey(
            backend: program.requestedBackend,
            accumulation: program.definition.material.accumulation,
            edgeTreatment: program.definition.material.edgeTreatment,
            functionConstants: BrushFunctionConstants(
                usesSecondaryShape: coverage.shapes.count > 1,
                usesGrain: !coverage.grains.isEmpty,
                usesSecondaryGrain: coverage.grains.count > 1,
                usesDestinationSampling:
                    program.requestedBackend == .canvasInteraction
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
        let simple = program.requestedBackend == .deposition
            && definition.coverage.shapes.count <= 1
            && definition.coverage.grains.count <= 1
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
        _ field: BrushCompilerCounterField
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
