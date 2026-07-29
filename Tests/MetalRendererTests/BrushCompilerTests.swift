import BrushFormat
import Foundation
import Metal
@testable import MetalRenderer
@testable import PatternEngine
import Testing

@MainActor
@Suite("Brush texture uploader", .serialized)
struct BrushTextureUploaderTests {
    @Test
    func uploadsEveryMipToPrivateR8TextureWithExactReadback() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let decoded = try compilerFixtureDecodedTexture()
        let uploader = BrushTextureUploader(device: device, commandQueue: queue)

        let texture = try await uploader.upload(decoded)

        #expect(texture.pixelFormat == .r8Unorm)
        #expect(texture.storageMode == .private)
        #expect(texture.usage.contains(.shaderRead))
        #expect(texture.width == 4)
        #expect(texture.height == 4)
        #expect(texture.mipmapLevelCount == 3)
        for level in decoded.mipLevels.indices {
            #expect(
                try readPrivateMip(
                    texture,
                    level: level,
                    device: device,
                    queue: queue
                ) == decoded.mipLevels[level]
            )
        }
    }

    @Test
    func oddMipLayoutUsesDeviceAlignmentAndExactFloorDimensions() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let decoded = DecodedBrushTexture(
            resourceID: "shape.odd",
            kind: .shape,
            sourceWidth: 5,
            sourceHeight: 3,
            workingWidth: 5,
            workingHeight: 3,
            mipLevels: [
                Data(0..<15),
                Data([20, 133]),
                Data([77]),
            ],
            residentByteCount: 18,
            wasResampled: false
        )
        let alignment = device.minimumTextureBufferAlignment(for: .r8Unorm)
        let layout = try BrushTextureUploadLayout.make(
            width: 5,
            height: 3,
            mipLevelByteCounts: decoded.mipLevels.map(\.count),
            alignment: alignment
        )

        #expect(layout.slices.map(\.width) == [5, 2, 1])
        #expect(layout.slices.map(\.height) == [3, 1, 1])
        #expect(layout.slices.allSatisfy { $0.bufferOffset % alignment == 0 })
        #expect(layout.slices.allSatisfy { $0.bytesPerRow % alignment == 0 })

        let texture = try await BrushTextureUploader(
            device: device,
            commandQueue: queue
        ).upload(decoded)
        for level in decoded.mipLevels.indices {
            #expect(
                try readPrivateMip(
                    texture,
                    level: level,
                    device: device,
                    queue: queue
                ) == decoded.mipLevels[level]
            )
        }
    }

    @Test
    func malformedMipChainsAndOverflowAreRejectedBeforeAllocation() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let malformed = DecodedBrushTexture(
            resourceID: "shape.bad",
            kind: .shape,
            sourceWidth: 4,
            sourceHeight: 4,
            workingWidth: 4,
            workingHeight: 4,
            mipLevels: [
                Data(repeating: 1, count: 16),
                Data(repeating: 2, count: 3),
                Data([3]),
            ],
            residentByteCount: 20,
            wasResampled: false
        )
        let uploader = BrushTextureUploader(device: device, commandQueue: queue)

        await #expect(
            throws: BrushTextureUploadError.invalidMipByteCount(
                resourceID: "shape.bad",
                level: 1,
                expected: 4,
                actual: 3
            )
        ) {
            _ = try await uploader.upload(malformed)
        }
        let tooFew = DecodedBrushTexture(
            resourceID: "shape.few",
            kind: .shape,
            sourceWidth: 4,
            sourceHeight: 4,
            workingWidth: 4,
            workingHeight: 4,
            mipLevels: [Data(repeating: 1, count: 16)],
            residentByteCount: 16,
            wasResampled: false
        )
        await #expect(
            throws: BrushTextureUploadError.invalidMipCount(
                resourceID: "shape.few",
                expected: 3,
                actual: 1
            )
        ) {
            _ = try await uploader.upload(tooFew)
        }
        let tooMany = DecodedBrushTexture(
            resourceID: "shape.many",
            kind: .shape,
            sourceWidth: 2,
            sourceHeight: 2,
            workingWidth: 2,
            workingHeight: 2,
            mipLevels: [
                Data(repeating: 1, count: 4),
                Data([2]),
                Data([3]),
            ],
            residentByteCount: 6,
            wasResampled: false
        )
        await #expect(
            throws: BrushTextureUploadError.invalidMipCount(
                resourceID: "shape.many",
                expected: 2,
                actual: 3
            )
        ) {
            _ = try await uploader.upload(tooMany)
        }
        let residentMismatch = DecodedBrushTexture(
            resourceID: "shape.resident",
            kind: .shape,
            sourceWidth: 2,
            sourceHeight: 2,
            workingWidth: 2,
            workingHeight: 2,
            mipLevels: [Data(repeating: 1, count: 4), Data([2])],
            residentByteCount: 6,
            wasResampled: false
        )
        await #expect(
            throws: BrushTextureUploadError.residentByteCountMismatch(
                resourceID: "shape.resident",
                expected: 5,
                actual: 6
            )
        ) {
            _ = try await uploader.upload(residentMismatch)
        }
        #expect(
            throws: BrushTextureUploadError.invalidAlignment(
                resourceID: "shape.bad",
                alignment: 0
            )
        ) {
            _ = try BrushTextureUploadLayout.make(
                resourceID: "shape.bad",
                width: 1,
                height: 1,
                mipLevelByteCounts: [1],
                alignment: 0
            )
        }
        #expect(
            throws: BrushTextureUploadError.storageOverflow(
                resourceID: "shape.bad"
            )
        ) {
            _ = try BrushTextureUploadLayout.make(
                resourceID: "shape.bad",
                width: .max,
                height: .max,
                mipLevelByteCounts: [Int](
                    repeating: .max,
                    count: Int.bitWidth - 1
                ),
                alignment: 256
            )
        }
    }

    @Test(arguments: BrushTextureUploadPhase.allCases)
    func typedInjectedFailuresNeverReturnPartialTextures(
        phase: BrushTextureUploadPhase
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let decoded = try compilerFixtureDecodedTexture()
        let uploader = BrushTextureUploader(
            device: device,
            commandQueue: queue,
            injectedFailure: phase
        )

        await #expect(
            throws: BrushTextureUploadError.injectedFailure(
                resourceID: decoded.resourceID,
                phase: phase
            )
        ) {
            _ = try await uploader.upload(decoded)
        }
    }
}

@MainActor
@Suite("Brush compiler", .serialized)
struct BrushCompilerTests {
    @Test
    func exactPackageCompilesImmutableProgramResourcesAndEstimatedTier() async throws {
        guard let setup = try compilerSetup() else { return }
        let package = try compilerPackage()
        let compiled = try await setup.compiler.compileAndActivate(
            package: package
        )

        #expect(setup.compiler.activeBrush === compiled)
        #expect(compiled.program == (try BrushProgramCompiler.compile(package.definition)))
        #expect(compiled.pipelineKey.backend == .deposition)
        #expect(compiled.pipelineKey.accumulation == package.definition.material.accumulation)
        #expect(compiled.pipelineKey.edgeTreatment == package.definition.material.edgeTreatment)
        #expect(!compiled.pipelineKey.functionConstants.usesSecondaryShape)
        #expect(!compiled.pipelineKey.functionConstants.usesGrain)
        #expect(!compiled.pipelineKey.functionConstants.usesDestinationSampling)
        #expect(compiled.depositionPipeline.key.brush == compiled.pipelineKey)
        #expect(
            compiled.depositionPipeline.key.abiVersion
                == DepositionABI.version
        )
        #expect(
            compiled.depositionMaterial.textures[.primaryShape]
                === compiled.textures["shape.main"]
        )
        let rebuiltMaterial = try DepositionMaterialBinding(
            compiledBrush: compiled
        )
        #expect(
            rebuiltMaterial.uniforms.coverageParameters
                == compiled.depositionMaterial.uniforms.coverageParameters
        )
        #expect(compiled.uniformTemplate.placement == package.definition.placement)
        #expect(compiled.uniformTemplate.coverage == package.definition.coverage)
        #expect(compiled.uniformTemplate.color == package.definition.color)
        #expect(compiled.uniformTemplate.material == package.definition.material)
        #expect(compiled.textures["shape.main"]?.storageMode == .private)
        #expect(compiled.textures["shape.main"]?.pixelFormat == .r8Unorm)
        #expect(compiled.textures["shape.main"]?.mipmapLevelCount == 3)
        #expect(compiled.residentByteCount == 21)
        #expect(compiled.report.backend == .deposition)
        #expect(compiled.report.performance.tier == .realtime120)
        #expect(compiled.report.performance.basis == .estimated)
        #expect(compiled.report.residentResourceBytes == 21)
        #expect(compiled.report.encodedResourceBytes == compilerFixturePNG.count)
        #expect(compiled.report.deviceRegistryID == 7)
        #expect(compiled.diagnostics == [])
        #expect(
            setup.compiler.debugCounters
                == BrushCompilerCounters(
                    packageDecodeCount: 1,
                    imageDecodeCount: 1,
                    textureUploadCount: 1,
                    cacheHitCount: 0,
                    activationCount: 1
                )
        )
        #expect(setup.compiler.cachedKeys.count == 1)
        #expect(setup.compiler.cachedKeys[0].hasPrefix("brush-r8-v1:"))
    }

    @Test
    func pipelineFailurePreservesPriorActivationAndResourceTransaction()
        async throws
    {
        guard let setup = try compilerSetup() else { return }
        let active = try await setup.compiler.compileAndActivate(
            package: try compilerPackage(
                definitionID: "brush.pipeline-active",
                resourceID: nil
            )
        )
        let cachedKeys = setup.compiler.cachedKeys
        let residentBytes = setup.compiler.residentByteCount
        let counters = setup.compiler.debugCounters
        setup.pipelines.failure = .pipelineCreationFailed("injected")

        let failure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(
                package: try compilerPackage(
                    definitionID: "brush.pipeline-failure",
                    edgeTreatment: .dryBreakup
                )
            )
        }

        #expect(failure.stage == .pipelineSelection)
        #expect(failure.reason == "pipelinePreparationFailed")
        #expect(setup.compiler.activeBrush === active)
        #expect(setup.compiler.cachedKeys == cachedKeys)
        #expect(setup.compiler.residentByteCount == residentBytes)
        #expect(
            setup.compiler.debugCounters.activationCount
                == counters.activationCount
        )
    }

    @Test
    func resourceAndPipelineCacheHitsReuseThePreparedBinding() async throws {
        guard let setup = try compilerSetup() else { return }
        let package = try compilerPackage(
            definitionID: "brush.pipeline-cache"
        )
        let first = try await setup.compiler.compileAndActivate(
            package: package
        )
        let before = setup.compiler.debugCounters
        let second = try await setup.compiler.compileAndActivate(
            package: package
        )

        #expect(first.depositionPipeline === second.depositionPipeline)
        #expect(setup.pipelines.stateCreationCount == 1)
        #expect(
            setup.compiler.debugCounters.imageDecodeCount
                == before.imageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.textureUploadCount
                == before.textureUploadCount
        )
    }

    @Test
    func directDefinitionAndEquivalentPackageShareSemanticIdentity()
        async throws
    {
        guard let setup = try compilerSetup() else { return }
        let package = try compilerPackage(
            definitionID: "brush.definition-only",
            resourceID: nil,
            directShape: .hardRound
        )

        let direct = try await setup.compiler.compileAndActivate(
            definition: package.definition
        )
        let packaged = try await setup.compiler.compileAndActivate(
            package: package
        )

        #expect(direct.renderIdentity == packaged.renderIdentity)
        #expect(direct.depositionPipeline === packaged.depositionPipeline)
    }

    @Test
    func newerRequestWinsWhileOlderPipelinePreparationIsSuspended()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let gate = CompilerPhaseGate()
        let pipelines = try makeCompilerPipelinePreparer(device: device)
        let slow = try compilerPackage(
            definitionID: "brush.slow-pipeline",
            resourceID: nil
        )
        let slowProgram = try BrushProgramCompiler.compile(slow.definition)
        pipelines.suspendedBrushKey = compilerPipelineKey(
            program: slowProgram
        )
        pipelines.suspensionGate = gate
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: try compilerProfile(),
            pipelinePreparing: pipelines,
            testHooks: .none
        )
        let fast = try compilerPackage(
            definitionID: "brush.fast-pipeline",
            resourceID: nil,
            edgeTreatment: .dryBreakup
        )

        let slowTask = Task { @MainActor in
            _ = try await compiler.compileAndActivate(package: slow)
        }
        await gate.waitUntilSuspended()
        let fastCompiled = try await compiler.compileAndActivate(
            package: fast
        )
        await gate.release()
        do {
            try await slowTask.value
            Issue.record("Superseded pipeline request should cancel")
        } catch is CancellationError {
            // Expected.
        }

        #expect(compiler.activeBrush === fastCompiled)
        #expect(
            compiler.activeBrush?.program.definition.id.rawValue
                == "brush.fast-pipeline"
        )
        #expect(compiler.debugCounters.activationCount == 1)
    }

    @Test
    func compiledBrushRenderIdentityUsesPackageSemanticHash() async throws {
        guard let setup = try compilerSetup() else { return }
        let package = try compilerPackage(definitionID: "brush.identity")

        let compiled = try await setup.compiler.compileAndActivate(
            package: package
        )

        #expect(
            compiled.renderIdentity
                == (try BrushRenderIdentity(
                    definitionID: package.definition.id,
                    semanticHash: package.contentHash
                ))
        )
    }

    @Test
    func wetDefinitionFailsBeforeDecodeUploadOrActivation() async throws {
        guard let setup = try compilerSetup() else { return }
        let wet = try compilerPackage(
            definitionID: "brush.wet",
            interaction: .wetMix
        )

        let before = setup.compiler.debugCounters
        let failure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: wet)
        }

        #expect(failure.stage == .pipelineSelection)
        #expect(failure.backend == .canvasInteraction)
        #expect(failure.reason == "unsupportedInteraction")
        #expect(
            setup.compiler.debugCounters.packageDecodeCount
                == before.packageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.imageDecodeCount
                == before.imageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.textureUploadCount
                == before.textureUploadCount
        )
        #expect(
            setup.compiler.debugCounters.activationCount
                == before.activationCount
        )
        #expect(setup.pipelines.prepareCallCount == 0)
        #expect(setup.compiler.activeBrush == nil)
    }

    @Test
    func wetConcentrationFailsBeforeDecodeUploadOrActivation() async throws {
        guard let setup = try compilerSetup() else { return }
        let wetEdge = try compilerPackage(
            definitionID: "brush.wet-edge",
            edgeTreatment: .wetConcentration
        )

        let before = setup.compiler.debugCounters
        let failure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: wetEdge)
        }

        #expect(failure.stage == .pipelineSelection)
        #expect(failure.backend == .deposition)
        #expect(failure.reason == "unsupportedWetConcentration")
        #expect(
            setup.compiler.debugCounters.packageDecodeCount
                == before.packageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.imageDecodeCount
                == before.imageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.textureUploadCount
                == before.textureUploadCount
        )
        #expect(
            setup.compiler.debugCounters.activationCount
                == before.activationCount
        )
        #expect(setup.pipelines.prepareCallCount == 0)
        #expect(setup.compiler.activeBrush == nil)
    }

    @Test
    func failedReplacementLeavesPriorCompiledBrushPinned() async throws {
        guard let setup = try compilerSetup() else { return }
        let active = try await setup.compiler.compileAndActivate(
            package: try compilerPackage(definitionID: "brush.active")
        )
        let keys = setup.compiler.cachedKeys
        let pinned = setup.compiler.pinnedKeys
        let bytes = setup.compiler.residentByteCount
        let counters = setup.compiler.debugCounters
        let replacement = try compilerPackage(
            definitionID: "brush.failed-replacement",
            interaction: .smudge
        )

        _ = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(
                package: replacement
            )
        }

        #expect(setup.compiler.activeBrush === active)
        #expect(setup.compiler.cachedKeys == keys)
        #expect(setup.compiler.pinnedKeys == pinned)
        #expect(setup.compiler.residentByteCount == bytes)
        #expect(
            setup.compiler.debugCounters.packageDecodeCount
                == counters.packageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.imageDecodeCount
                == counters.imageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.textureUploadCount
                == counters.textureUploadCount
        )
        #expect(
            setup.compiler.debugCounters.activationCount
                == counters.activationCount
        )
    }

    @Test
    func equalDefinitionWithDifferentResourceHashHasDifferentRenderIdentity()
        async throws
    {
        guard let setup = try compilerSetup() else { return }
        let firstPackage = try compilerPackage(
            definitionID: "brush.resource-identity"
        )
        let secondPackage = try compilerPackage(
            definitionID: "brush.resource-identity",
            resourceBytes: Data(compilerFixturePNG + [0])
        )
        #expect(firstPackage.definition == secondPackage.definition)
        #expect(try firstPackage.contentHash != secondPackage.contentHash)

        let first = try await setup.compiler.compileAndActivate(
            package: firstPackage
        )
        let second = try await setup.compiler.compileAndActivate(
            package: secondPackage
        )

        #expect(
            first.renderIdentity.definitionID
                == second.renderIdentity.definitionID
        )
        #expect(first.renderIdentity != second.renderIdentity)
    }

    @Test
    func effectiveDefinitionAndDeviceCeilingsAreAppliedBeforeDecode() async throws {
        guard let setup = try compilerSetup(
            maximumWorkingTextureDimension: 4,
            targetFramesPerSecond: 60
        ) else { return }
        let package = try compilerPackage(
            maximumResourceDimension: 2,
            performanceIntent: .realtime120
        )

        let compiled = try await setup.compiler.compileAndActivate(
            package: package
        )

        #expect(compiled.textures["shape.main"]?.width == 2)
        #expect(compiled.textures["shape.main"]?.height == 2)
        #expect(compiled.residentByteCount == 5)
        #expect(compiled.diagnostics == [
            .resourceResampled(
                id: "shape.main",
                sourceWidth: 4,
                sourceHeight: 4,
                workingWidth: 2,
                workingHeight: 2
            ),
        ])
        #expect(compiled.report.performance.tier == .realtime60)
        #expect(compiled.report.performance.basis == .estimated)

        let builtIn = try await setup.compiler.compileAndActivate(
            package: try compilerPackage(
                definitionID: "brush.small-builtin",
                resourceID: nil,
                directShape: .softRound,
                maximumResourceDimension: 8
            )
        )
        #expect(builtIn.textures["builtin.shape.soft-round"]?.width == 4)
        #expect(builtIn.textures["builtin.shape.soft-round"]?.height == 4)
        #expect(builtIn.residentByteCount == 21)
        #expect(builtIn.diagnostics == [
            .resourceResampled(
                id: "builtin.shape.soft-round",
                sourceWidth: 64,
                sourceHeight: 64,
                workingWidth: 4,
                workingHeight: 4
            ),
        ])
    }

    @Test
    func performanceTierCountsEveryUniqueCompiledWorkingTexture() async throws {
        guard let setup = try compilerSetup() else { return }

        let compiled = try await setup.compiler.compileAndActivate(
            package: try compilerPackage(includeExtraShapeResource: true)
        )

        #expect(compiled.textures.keys.sorted() == ["shape.extra", "shape.main"])
        #expect(compiled.report.performance.tier == .realtime60)
        #expect(compiled.report.performance.basis == .estimated)
    }

    @Test
    func previewIsIgnoredAndContentCacheHitsAvoidDecodeAndUpload() async throws {
        guard let setup = try compilerSetup() else { return }
        let plain = try compilerPackage()
        let decorated = try compilerPackage(includePreview: true)
        #expect(try plain.contentHash == decorated.contentHash)

        _ = try await setup.compiler.compileAndActivate(package: plain)
        let before = setup.compiler.debugCounters
        let second = try await setup.compiler.compileAndActivate(
            package: decorated
        )

        #expect(second.textures.keys.sorted() == ["shape.main"])
        #expect(setup.compiler.debugCounters.packageDecodeCount == before.packageDecodeCount + 1)
        #expect(setup.compiler.debugCounters.imageDecodeCount == before.imageDecodeCount)
        #expect(setup.compiler.debugCounters.textureUploadCount == before.textureUploadCount)
        #expect(setup.compiler.debugCounters.cacheHitCount == before.cacheHitCount + 1)
        #expect(setup.compiler.debugCounters.activationCount == before.activationCount + 1)
    }

    @Test
    func contentKeyDeduplicatesIdenticalDataAcrossResourceIDsAndPackages() async throws {
        guard let setup = try compilerSetup() else { return }
        let first = try compilerPackage(
            definitionID: "brush.first",
            resourceID: "shape.first"
        )
        let second = try compilerPackage(
            definitionID: "brush.second",
            resourceID: "shape.second"
        )

        _ = try await setup.compiler.compileAndActivate(package: first)
        let compiled = try await setup.compiler.compileAndActivate(
            package: second
        )

        #expect(compiled.textures.keys.sorted() == ["shape.second"])
        #expect(setup.compiler.cachedKeys.count == 1)
        #expect(setup.compiler.residentByteCount == 21)
        #expect(setup.compiler.debugCounters.imageDecodeCount == 1)
        #expect(setup.compiler.debugCounters.textureUploadCount == 1)
        #expect(setup.compiler.debugCounters.cacheHitCount == 1)
    }

    @Test
    func cacheHitsCannotBypassDeclaredSourceMetadataValidation() async throws {
        guard let setup = try compilerSetup(
            maximumWorkingTextureDimension: 2
        ) else { return }
        let valid = try await setup.compiler.compileAndActivate(
            package: try compilerPackage(
                definitionID: "brush.valid-source",
                resourceID: "shape.valid"
            )
        )
        let before = setup.compiler.debugCounters

        let mediaFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(
                package: try compilerPackage(
                    definitionID: "brush.false-media",
                    resourceID: "shape.false-media",
                    mediaType: "image/tiff"
                )
            )
        }
        #expect(mediaFailure.stage == .imageDecode)
        #expect(mediaFailure.resourceID == "shape.false-media")

        let dimensionFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(
                package: try compilerPackage(
                    definitionID: "brush.false-dimensions",
                    resourceID: "shape.false-dimensions",
                    width: 8,
                    height: 8
                )
            )
        }
        #expect(dimensionFailure.stage == .imageDecode)
        #expect(dimensionFailure.resourceID == "shape.false-dimensions")
        #expect(setup.compiler.activeBrush === valid)
        #expect(setup.compiler.debugCounters.cacheHitCount == before.cacheHitCount)
    }

    @Test
    func builtInAndDeclaredFallbackUsePrivatePyramidsWithHonestReport() async throws {
        guard let setup = try compilerSetup() else { return }
        let builtIn = try compilerPackage(
            definitionID: "brush.builtin",
            resourceID: nil,
            directShape: .softRound
        )
        let fallback = try compilerPackage(
            definitionID: "brush.fallback",
            resourceID: "shape.missing",
            includeResourceData: false,
            resourceRequired: false,
            fallback: "builtin.shape.hard-round"
        )

        let first = try await setup.compiler.compileAndActivate(package: builtIn)
        let second = try await setup.compiler.compileAndActivate(package: fallback)

        #expect(first.textures["builtin.shape.soft-round"]?.storageMode == .private)
        #expect(first.residentByteCount == BrushTextureFactory.mipmappedTextureByteCount)
        #expect(second.textures["shape.missing"]?.storageMode == .private)
        #expect(second.report.compatibility == [
            BrushCompatibilityEntry(
                semanticKey: "resource.shape.missing",
                level: .approximated,
                message: "Declared built-in fallback was used."
            ),
        ])
    }

    @Test
    func professionalBuiltInFallbackUsesItsDeclaredSourceDimension() async throws {
        guard let setup = try compilerSetup() else { return }
        let package = try compilerPackage(
            definitionID: "brush.professional-fallback",
            resourceID: "shape.professional",
            includeResourceData: false,
            resourceRequired: false,
            fallback: "builtin.shape.technical-nib"
        )

        let compiled = try await setup.compiler.compileAndActivate(
            package: package
        )

        #expect(compiled.textures["shape.professional"]?.width == 128)
        #expect(compiled.textures["shape.professional"]?.mipmapLevelCount == 8)
        #expect(compiled.residentByteCount == 21_845)
    }

    @Test
    func unknownFallbackRequiredSemanticAndInteractionFailBeforeActivation() async throws {
        guard let setup = try compilerSetup() else { return }
        let old = try compilerPackage(
            definitionID: "brush.old",
            resourceID: nil,
            directShape: .hardRound
        )
        let active = try await setup.compiler.compileAndActivate(package: old)

        let unknown = try compilerPackage(
            definitionID: "brush.unknown",
            resourceID: "shape.missing",
            includeResourceData: false,
            resourceRequired: false,
            fallback: "builtin.shape.unknown"
        )
        let unknownFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: unknown)
        }
        #expect(unknownFailure.stage == .imageDecode)
        #expect(unknownFailure.resourceID == "shape.missing")
        #expect(unknownFailure.reason == "unknownBuiltinResource")

        let colliding = try compilerPackage(
            definitionID: "brush.colliding-resource",
            resourceID: BrushTextureIdentity.hardRoundShape.rawValue,
            additionalDirectShape: .hardRound
        )
        let collisionFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: colliding)
        }
        #expect(collisionFailure.stage == .imageDecode)
        #expect(
            collisionFailure.resourceID
                == BrushTextureIdentity.hardRoundShape.rawValue
        )
        #expect(collisionFailure.reason == "resourceIdentifierCollision")

        let semantic = try compilerPackage(
            definitionID: "brush.semantic",
            requiredSemanticKeys: ["foreign.secret"]
        )
        let semanticFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: semantic)
        }
        #expect(semanticFailure.stage == .pipelineSelection)
        #expect(semanticFailure.resourceID == nil)
        #expect(semanticFailure.reason == "unsupportedRequiredSemantic")

        let interaction = try compilerPackage(
            definitionID: "brush.interaction",
            interaction: .pickup
        )
        let interactionFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: interaction)
        }
        #expect(interactionFailure.stage == .pipelineSelection)
        #expect(interactionFailure.reason == "unsupportedInteraction")

        let invalidInteractionProgram = try compilerPackage(
            definitionID: "brush.invalid-interaction-program",
            interaction: .pickup,
            extraCapabilities: [
                BrushCapabilityDeclaration(
                    identifier: "future.required",
                    required: true
                ),
            ]
        )
        let invalidProgramFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(
                package: invalidInteractionProgram
            )
        }
        #expect(invalidProgramFailure.stage == .definition)
        #expect(invalidProgramFailure.backend == .canvasInteraction)
        #expect(setup.compiler.activeBrush === active)
    }

    @Test
    func decodeAndBudgetFailuresAreRedactedAndLeavePriorActivationUntouched() async throws {
        guard let setup = try compilerSetup(brushCacheBudgetBytes: 20) else {
            return
        }
        let old = try compilerPackage(
            definitionID: "brush.old",
            maximumResourceDimension: 2,
            maximumResidentBytes: 20_000
        )
        let active = try await setup.compiler.compileAndActivate(package: old)
        let originalKeys = setup.compiler.cachedKeys
        let originalBytes = setup.compiler.residentByteCount

        let tooLarge = try compilerPackage(
            definitionID: "brush.large",
            maximumResidentBytes: 20_000
        )
        let beforeBudgetFailure = setup.compiler.debugCounters
        let budgetFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: tooLarge)
        }
        #expect(budgetFailure.stage == .residency)
        #expect(budgetFailure.requestedBytes == 21)
        #expect(budgetFailure.reason == "unsupportedResourceCost")
        #expect(
            setup.compiler.debugCounters.imageDecodeCount
                == beforeBudgetFailure.imageDecodeCount
        )
        #expect(
            setup.compiler.debugCounters.textureUploadCount
                == beforeBudgetFailure.textureUploadCount
        )

        let corrupt = try compilerPackage(
            definitionID: "brush.corrupt",
            resourceBytes: Data([1, 2, 3, 4]),
            width: 4,
            height: 4,
            maximumResourceDimension: 2
        )
        let decodeFailure = try await compilationFailure {
            _ = try await setup.compiler.compileAndActivate(package: corrupt)
        }
        #expect(decodeFailure.stage == .imageDecode)
        #expect(decodeFailure.resourceID == "shape.main")
        #expect(decodeFailure.requestedBytes == 5)
        #expect(decodeFailure.reason == "assetDecodeFailed")
        #expect(setup.compiler.activeBrush === active)
        #expect(setup.compiler.cachedKeys == originalKeys)
        #expect(setup.compiler.residentByteCount == originalBytes)
    }

    @Test
    func uploadAndAdmissionFailuresAfterCompletedWorkAreAtomic() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let profile = try compilerProfile(brushCacheBudgetBytes: 100_000)
        let oldPackage = try compilerPackage(
            definitionID: "brush.old",
            resourceID: nil,
            directShape: .hardRound
        )

        let uploadCompiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: profile,
            pipelinePreparing: try makeCompilerPipelinePreparer(
                device: device
            ),
            testHooks: BrushCompilerTestHooks(
                uploadFailureResourceID: "shape.b"
            )
        )
        let uploadActive = try await uploadCompiler.compileAndActivate(
            package: oldPackage
        )
        let uploadKeys = uploadCompiler.cachedKeys
        let uploadBytes = uploadCompiler.residentByteCount
        let twoResources = try compilerTwoResourcePackage()
        let uploadFailure = try await compilationFailure {
            _ = try await uploadCompiler.compileAndActivate(
                package: twoResources
            )
        }
        #expect(uploadFailure.stage == .textureUpload)
        #expect(uploadFailure.resourceID == "shape.b")
        #expect(uploadCompiler.activeBrush === uploadActive)
        #expect(uploadCompiler.cachedKeys == uploadKeys)
        #expect(uploadCompiler.residentByteCount == uploadBytes)
        #expect(uploadCompiler.debugCounters.textureUploadCount >= 2)

        let admissionCompiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: profile,
            pipelinePreparing: try makeCompilerPipelinePreparer(
                device: device
            ),
            testHooks: BrushCompilerTestHooks(
                admissionFailureDefinitionID: "brush.new"
            )
        )
        let admissionActive = try await admissionCompiler.compileAndActivate(
            package: oldPackage
        )
        let admissionKeys = admissionCompiler.cachedKeys
        let admissionBytes = admissionCompiler.residentByteCount
        let admissionFailure = try await compilationFailure {
            _ = try await admissionCompiler.compileAndActivate(
                package: try compilerPackage(definitionID: "brush.new")
            )
        }
        #expect(admissionFailure.stage == .residency)
        #expect(admissionFailure.reason == "injectedAdmissionFailure")
        #expect(admissionCompiler.activeBrush === admissionActive)
        #expect(admissionCompiler.cachedKeys == admissionKeys)
        #expect(admissionCompiler.residentByteCount == admissionBytes)
    }

    @Test(arguments: BrushCompilerPhase.allCases)
    func cancellationAtEveryPhasePreservesCachePinsRecencyAndActivation(
        phase: BrushCompilerPhase
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let hooks = BrushCompilerTestHooks { context in
            guard context.definitionID == "brush.candidate",
                  context.phase == phase
            else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: try compilerProfile(),
            pipelinePreparing: try makeCompilerPipelinePreparer(
                device: device
            ),
            testHooks: hooks
        )
        let old = try await compiler.compileAndActivate(
            package: try compilerPackage(
                definitionID: "brush.old",
                resourceID: nil,
                directShape: .hardRound
            )
        )
        let originalKeys = compiler.cachedKeys
        let originalBytes = compiler.residentByteCount
        let originalCounters = compiler.debugCounters

        do {
            _ = try await compiler.compileAndActivate(
                package: try compilerPackage(definitionID: "brush.candidate")
            )
            Issue.record("Expected cancellation at \(phase)")
        } catch is CancellationError {
            // Expected.
        }

        #expect(compiler.activeBrush === old)
        #expect(compiler.cachedKeys == originalKeys)
        #expect(compiler.residentByteCount == originalBytes)
        #expect(compiler.debugCounters.activationCount == originalCounters.activationCount)
    }

    @Test
    func newerFastRequestWinsOverOlderSuspendedRequest() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let gate = CompilerPhaseGate()
        let hooks = BrushCompilerTestHooks { context in
            if context.definitionID == "brush.slow",
               context.phase == .beforeCacheTransaction
            {
                await gate.suspend()
            }
        }
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: try compilerProfile(),
            pipelinePreparing: try makeCompilerPipelinePreparer(
                device: device
            ),
            testHooks: hooks
        )
        let slow = try compilerPackage(
            definitionID: "brush.slow",
            resourceID: "shape.slow"
        )
        let fast = try compilerPackage(
            definitionID: "brush.fast",
            resourceID: "shape.fast"
        )

        let slowTask = Task { @MainActor in
            _ = try await compiler.compileAndActivate(package: slow)
        }
        await gate.waitUntilSuspended()
        let fastCompiled = try await compiler.compileAndActivate(package: fast)
        await gate.release()
        do {
            try await slowTask.value
            Issue.record("Superseded request should cancel")
        } catch is CancellationError {
            // Expected.
        }

        #expect(compiler.activeBrush === fastCompiled)
        #expect(compiler.activeBrush?.program.definition.id.rawValue == "brush.fast")
        #expect(compiler.debugCounters.activationCount == 1)
    }

    @Test
    func newerRequestCancelsDetachedPackageHashWork() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let probe = CompilerHashProbe()
        let hooks = BrushCompilerTestHooks(
            onPackageHash: { definitionID in
                guard definitionID == "brush.slow-hash" else { return }
                await probe.markStarted()
                try await ContinuousClock().sleep(for: .seconds(60))
            }
        )
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: try compilerProfile(),
            pipelinePreparing: try makeCompilerPipelinePreparer(
                device: device
            ),
            testHooks: hooks
        )
        let slow = try compilerPackage(
            definitionID: "brush.slow-hash",
            resourceID: "shape.slow-hash"
        )
        let fast = try compilerPackage(
            definitionID: "brush.fast-hash",
            resourceID: "shape.fast-hash"
        )

        let slowTask = Task { @MainActor in
            _ = try await compiler.compileAndActivate(package: slow)
        }
        await probe.waitUntilStarted()
        let fastCompiled = try await compiler.compileAndActivate(package: fast)
        do {
            try await slowTask.value
            Issue.record("Superseded hash work should cancel")
        } catch is CancellationError {
            // Expected.
        }

        #expect(compiler.activeBrush === fastCompiled)
        #expect(
            compiler.activeBrush?.program.definition.id.rawValue
                == "brush.fast-hash"
        )
    }

    @Test
    func cancelledSpeculativeCacheHitDoesNotRefreshFutureLRUOrder() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let hooks = BrushCompilerTestHooks { context in
            guard context.definitionID == "brush.speculative",
                  context.phase == .beforeCacheTransaction
            else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: try compilerProfile(
                maximumWorkingTextureDimension: 4,
                brushCacheBudgetBytes: 64
            ),
            pipelinePreparing: try makeCompilerPipelinePreparer(
                device: device
            ),
            testHooks: hooks
        )
        _ = try await compiler.compileAndActivate(
            package: try compilerPackage(
                definitionID: "brush.a",
                resourceID: "shape.a"
            )
        )
        let keyA = try #require(compiler.cachedKeys.first)
        _ = try await compiler.compileAndActivate(
            package: try compilerPackage(
                definitionID: "brush.b",
                resourceID: "shape.b",
                resourceBytes: compilerWidePNG,
                width: 8,
                height: 4
            )
        )
        let keyB = try #require(
            compiler.cachedKeys.first(where: { $0 != keyA })
        )
        _ = try await compiler.compileAndActivate(
            package: try compilerPackage(
                definitionID: "brush.c",
                resourceID: "shape.c",
                resourceBytes: compilerCoveragePNG,
                width: 2,
                height: 2
            )
        )

        let speculativeTask = Task { @MainActor in
            _ = try await compiler.compileAndActivate(
                package: try compilerPackage(
                    definitionID: "brush.speculative",
                    resourceID: "shape.speculative"
                )
            )
        }
        do {
            try await speculativeTask.value
            Issue.record("Expected speculative hit cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let pressure = compiler.handleMemoryPressure(targetResidentBytes: 16)
        guard case let .satisfied(evicted) = pressure else {
            Issue.record("Expected pressure eviction")
            return
        }
        #expect(evicted == [keyA])
        #expect(!compiler.cachedKeys.contains(keyA))
        #expect(compiler.cachedKeys.contains(keyB))
    }

    @Test
    func exactBudgetMultiResourceActivationPinsEveryCandidate() async throws {
        guard let setup = try compilerSetup(
            brushCacheBudgetBytes: 42
        ) else { return }
        let compiled = try await setup.compiler.compileAndActivate(
            package: try compilerTwoResourcePackage()
        )

        #expect(compiled.residentByteCount == 42)
        #expect(setup.compiler.residentByteCount == 42)
        #expect(setup.compiler.cachedKeys.count == 2)
        #expect(setup.compiler.pinnedKeys == setup.compiler.cachedKeys)
        #expect(
            setup.compiler.handleMemoryPressure(targetResidentBytes: 41)
                == .activeBrushExceedsTarget(
                    requiredBytes: 42,
                    targetBytes: 41
                )
        )
        #expect(setup.compiler.cachedKeys.count == 2)
    }

    @Test
    func activationProtectsEveryCachedActiveKeyBeforeAdmittingMisses() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return
        }
        var cache = BrushResourceCache(byteBudget: 2)

        _ = try cache.activate(
            activeKeys: ["z-hit"],
            candidates: [
                "z-hit": .init(texture: texture, byteCount: 1),
            ]
        )
        _ = try cache.activate(
            activeKeys: ["b-filler"],
            candidates: [
                "b-filler": .init(texture: texture, byteCount: 1),
            ]
        )

        _ = try cache.activate(
            activeKeys: ["a-new", "z-hit"],
            candidates: [
                "a-new": .init(texture: texture, byteCount: 1),
            ]
        )

        #expect(cache.keys == ["a-new", "z-hit"])
        #expect(cache.pinnedKeys == ["a-new", "z-hit"])
        #expect(cache.residentByteCount == 2)
    }

    @Test
    func memoryPressureEvictsInactiveOnlyAndReportsBelowActiveTargets() async throws {
        guard let setup = try compilerSetup(
            brushCacheBudgetBytes: 42
        ) else { return }
        let first = try compilerPackage(
            definitionID: "brush.first",
            resourceID: "shape.first"
        )
        let second = try compilerPackage(
            definitionID: "brush.second",
            resourceID: "shape.second",
            resourceBytes: compilerCoveragePNG,
            width: 2,
            height: 2
        )
        _ = try await setup.compiler.compileAndActivate(package: first)
        let firstKey = try #require(setup.compiler.cachedKeys.first)
        let active = try await setup.compiler.compileAndActivate(package: second)
        #expect(setup.compiler.cachedKeys.count == 2)

        let pressure = setup.compiler.handleMemoryPressure(targetResidentBytes: 21)
        guard case let .satisfied(evictedKeys) = pressure else {
            Issue.record("Expected inactive eviction")
            return
        }
        #expect(evictedKeys == [firstKey])
        #expect(!setup.compiler.cachedKeys.contains(firstKey))
        #expect(setup.compiler.cachedKeys.count == 1)
        #expect(setup.compiler.activeBrush === active)

        let below = setup.compiler.handleMemoryPressure(targetResidentBytes: 4)
        #expect(
            below == .activeBrushExceedsTarget(
                requiredBytes: active.residentByteCount,
                targetBytes: 4
            )
        )
        #expect(setup.compiler.activeBrush === active)
        #expect(setup.compiler.cachedKeys.count == 1)
    }

    @Test
    func oneCompilationThenOneThousandLogicalDabsDoesNotTouchCompiler() async throws {
        guard let setup = try compilerSetup() else { return }
        let compiled = try await setup.compiler.compileAndActivate(
            package: try compilerPackage()
        )
        let before = setup.compiler.debugCounters
        var emitted = 0
        for index in 0..<1_000 {
            var generator = BrushStrokeGenerator(
                program: compiled.program,
                nominalDiameter: 20,
                color: .black,
                seed: UInt64(index + 1)
            )
            let batches = generator.beginBatches(
                compilerWorldSample(phase: .began)
            )
            emitted += batches.reduce(0) { $0 + $1.dabs.count }
        }

        #expect(emitted == 1_000)
        #expect(setup.compiler.debugCounters == before)
    }
}

private let compilerFixturePNG = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAABKADAAQAAAABAAAABAAAAADFbP4CAAAAJ0lEQVQIHWP4DwQMDAxwzMTIyMgAEQMKAwETiEAWZATyQcrBAKQSAJJxEPsf8WuRAAAAAElFTkSuQmCC"
)!

private let compilerCoveragePNG = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAADtGLyqAAAAFklEQVQIHWNoaGj4DwQMDECigQFIAQBiSgn5RlJcQwAAAABJRU5ErkJggg=="
)!

private let compilerWidePNG = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAACKADAAQAAAABAAAABAAAAABQdJZTAAAAGUlEQVQIHWP4DwQMDAwgCivNBJTECyhXAAARfxPzMqX7wAAAAABJRU5ErkJggg=="
)!

@MainActor
private func compilerSetup(
    maximumWorkingTextureDimension: Int = 4_096,
    brushCacheBudgetBytes: Int = 128 * 1_024 * 1_024,
    targetFramesPerSecond: Int = 120
) throws -> (
    compiler: BrushCompiler,
    device: any MTLDevice,
    queue: any MTLCommandQueue,
    pipelines: CompilerPipelinePreparer
)? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue()
    else { return nil }
    let pipelines = try makeCompilerPipelinePreparer(device: device)
    return (
        BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: try compilerProfile(
                maximumWorkingTextureDimension:
                    maximumWorkingTextureDimension,
                brushCacheBudgetBytes: brushCacheBudgetBytes,
                targetFramesPerSecond: targetFramesPerSecond
            ),
            pipelinePreparing: pipelines,
            testHooks: .none
        ),
        device,
        queue,
        pipelines
    )
}

private func compilerProfile(
    maximumWorkingTextureDimension: Int = 4_096,
    brushCacheBudgetBytes: Int = 128 * 1_024 * 1_024,
    targetFramesPerSecond: Int = 120
) throws -> BrushDeviceProfile {
    try BrushDeviceProfile(
        registryID: 7,
        recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
        maximumWorkingTextureDimension: maximumWorkingTextureDimension,
        brushCacheBudgetBytes: brushCacheBudgetBytes,
        targetFramesPerSecond: targetFramesPerSecond
    )
}

private func compilerPackage(
    definitionID: String = "brush.exact",
    resourceID: String? = "shape.main",
    resourceBytes: Data = compilerFixturePNG,
    mediaType: String = "image/png",
    width: Int = 4,
    height: Int = 4,
    includeResourceData: Bool = true,
    resourceRequired: Bool = true,
    fallback: String? = nil,
    directShape: BrushShapeDescriptor = .hardRound,
    maximumResourceDimension: Int = 4_096,
    maximumResidentBytes: Int = 128 * 1_024 * 1_024,
    performanceIntent: BrushPerformanceIntent = .realtime120,
    requiredSemanticKeys: [String] = [],
    interaction: BrushInteractionMode = .none,
    edgeTreatment: BrushEdgeTreatment? = nil,
    includePreview: Bool = false,
    includeExtraShapeResource: Bool = false,
    additionalDirectShape: BrushShapeDescriptor? = nil,
    extraCapabilities: [BrushCapabilityDeclaration] = []
) throws -> BrushPackage {
    let base = try LegacyBrushRecipeAdapter.definition(
        from: BrushRecipe(id: BrushRecipeID(definitionID)),
        displayName: definitionID
    )
    let shape: BrushShapeDescriptor = resourceID.map {
        .asset($0)
    } ?? directShape
    var references: [BrushResourceReference] = []
    var manifestResources: [BrushPackageResource] = []
    var data: [String: Data] = [:]
    if let resourceID {
        references.append(
            BrushResourceReference(
                identifier: resourceID,
                kind: .shape,
                required: resourceRequired,
                fallback: fallback.map {
                    .builtIn(identifier: $0)
                }
            )
        )
        if includeResourceData {
            manifestResources.append(
                try BrushPackageResource(
                    id: resourceID,
                    kind: .shape,
                    mediaType: mediaType,
                    data: resourceBytes,
                    pixelWidth: width,
                    pixelHeight: height
                )
            )
            data[resourceID] = resourceBytes
        }
    }
    if includeExtraShapeResource {
        let extraID = "shape.extra"
        references.append(
            BrushResourceReference(
                identifier: extraID,
                kind: .shape,
                required: true,
                fallback: nil
            )
        )
        manifestResources.append(
            try BrushPackageResource(
                id: extraID,
                kind: .shape,
                mediaType: "image/png",
                data: compilerCoveragePNG,
                pixelWidth: 2,
                pixelHeight: 2
            )
        )
        data[extraID] = compilerCoveragePNG
    }
    if includePreview {
        let previewBytes = Data([1, 2, 3])
        manifestResources.append(
            try BrushPackageResource(
                id: "preview.generated",
                kind: .preview,
                mediaType: "image/png",
                data: previewBytes,
                pixelWidth: 1,
                pixelHeight: 1
            )
        )
        data["preview.generated"] = previewBytes
    }
    var capabilities: [BrushCapabilityDeclaration]
    let material: BrushMaterialDefinition
    if interaction == .none, edgeTreatment == nil {
        capabilities = base.capabilities
        material = base.material
    } else {
        let interactionCapability: BrushCapability? = switch interaction {
        case .none:
            nil
        case .pickup:
            .canvasInteraction
        case .smudge:
            .smudge
        case .wetMix:
            .wetMix
        }
        capabilities = interactionCapability.map {
            [
                BrushCapabilityDeclaration(
                    identifier: $0.rawValue,
                    required: true
                ),
            ]
        } ?? base.capabilities
        material = BrushMaterialDefinition(
            accumulation: base.material.accumulation,
            interaction: interaction,
            edgeTreatment: edgeTreatment ?? base.material.edgeTreatment,
            strength: base.material.strength,
            wetness: base.material.wetness,
            bleedRadius: base.material.bleedRadius,
            softenPasses: base.material.softenPasses,
            accumulationLimit: base.material.accumulationLimit,
            interactionParameters: interaction == .none
                ? nil
                : BrushInteractionDefinition(
                    pickup: 0.5,
                    pull: 0,
                    dilution: 0,
                    charge: 0,
                    persistence: 0,
                    dirtyHaloRadius: 0
                )
        )
    }
    capabilities.append(contentsOf: extraCapabilities)
    var shapes = [
        BrushShapeLayerDefinition(
            shape: shape,
            combination: .replace,
            scale: 1,
            rotation: 0,
            offset: .zero
        ),
    ]
    if let additionalDirectShape {
        shapes.append(
            BrushShapeLayerDefinition(
                shape: additionalDirectShape,
                combination: .multiply,
                scale: 1,
                rotation: 0,
                offset: .zero
            )
        )
        capabilities.append(
            BrushCapabilityDeclaration(
                identifier: BrushCapability.dualShape.rawValue,
                required: true
            )
        )
    }
    let definition = try BrushDefinition(
        id: BrushRecipeID(definitionID),
        schemaVersion: base.schemaVersion,
        metadata: base.metadata,
        capabilities: capabilities,
        resources: references.sorted { $0.identifier < $1.identifier },
        coverage: BrushCoverageDefinition(
            shapes: shapes,
            grains: [],
            baseHardness: base.coverage.baseHardness,
            aspectRatio: base.coverage.aspectRatio,
            tipThreshold: base.coverage.tipThreshold,
            antialiasing: base.coverage.antialiasing
        ),
        placement: base.placement,
        dynamics: base.dynamics,
        color: base.color,
        material: material,
        stabilization: base.stabilization,
        taper: base.taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        seedPolicy: base.seedPolicy,
        limits: BrushDefinitionLimits(
            minimumDiameter: base.limits.minimumDiameter,
            maximumDiameter: base.limits.maximumDiameter,
            maximumOpacity: base.limits.maximumOpacity,
            maximumSpacingFraction: base.limits.maximumSpacingFraction,
            maximumResourceDimension: maximumResourceDimension,
            maximumResidentBytes: maximumResidentBytes
        ),
        performanceIntent: performanceIntent,
        compatibility: BrushCompatibilityMetadata(
            nativeFeatureVersion: base.compatibility.nativeFeatureVersion,
            sourceSettingKeys: base.compatibility.sourceSettingKeys,
            requiredSemanticKeys: requiredSemanticKeys
        )
    )
    return try BrushPackage(
        manifest: BrushPackageManifest(resources: manifestResources),
        definition: definition,
        resourceData: data
    )
}

private func compilerTwoResourcePackage() throws -> BrushPackage {
    let base = try LegacyBrushRecipeAdapter.definition(
        from: BrushRecipe(id: BrushRecipeID("brush.two")),
        displayName: "brush.two"
    )
    let secondBytes = Data(compilerFixturePNG + [0])
    let resources = try [
        BrushPackageResource(
            id: "shape.a",
            kind: .shape,
            mediaType: "image/png",
            data: compilerFixturePNG,
            pixelWidth: 4,
            pixelHeight: 4
        ),
        BrushPackageResource(
            id: "shape.b",
            kind: .shape,
            mediaType: "image/png",
            data: secondBytes,
            pixelWidth: 4,
            pixelHeight: 4
        ),
    ]
    let references = ["shape.a", "shape.b"].map {
        BrushResourceReference(
            identifier: $0,
            kind: .shape,
            required: true,
            fallback: nil
        )
    }
    let definition = try BrushDefinition(
        id: BrushRecipeID("brush.two"),
        metadata: base.metadata,
        capabilities: [
            BrushCapabilityDeclaration(
                identifier: BrushCapability.dualShape.rawValue,
                required: true
            ),
        ],
        resources: references,
        coverage: BrushCoverageDefinition(
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .asset("shape.a"),
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
                BrushShapeLayerDefinition(
                    shape: .asset("shape.b"),
                    combination: .multiply,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
            ],
            grains: [],
            baseHardness: base.coverage.baseHardness,
            aspectRatio: base.coverage.aspectRatio,
            tipThreshold: base.coverage.tipThreshold,
            antialiasing: base.coverage.antialiasing
        ),
        placement: base.placement,
        dynamics: base.dynamics,
        color: base.color,
        material: base.material,
        stabilization: base.stabilization,
        taper: base.taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        seedPolicy: base.seedPolicy,
        limits: BrushDefinitionLimits(
            minimumDiameter: base.limits.minimumDiameter,
            maximumDiameter: base.limits.maximumDiameter,
            maximumOpacity: base.limits.maximumOpacity,
            maximumSpacingFraction: base.limits.maximumSpacingFraction,
            maximumResourceDimension: base.limits.maximumResourceDimension,
            maximumResidentBytes: 100_000
        ),
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility
    )
    return try BrushPackage(
        manifest: BrushPackageManifest(resources: resources),
        definition: definition,
        resourceData: [
            "shape.a": compilerFixturePNG,
            "shape.b": secondBytes,
        ]
    )
}

@MainActor
private func compilationFailure(
    _ operation: @MainActor () async throws -> Void
) async throws -> BrushCompilationFailure {
    do {
        try await operation()
        throw CompilerTestError.expectedFailure
    } catch let failure as BrushCompilationFailure {
        return failure
    }
}

private func compilerWorldSample(
    phase: StrokePhase
) -> WorldStrokeSample {
    WorldStrokeSample(
        position: WorldPoint(x: 0, y: 0),
        pressure: 1,
        timestamp: 0,
        altitude: nil,
        azimuth: nil,
        roll: nil,
        tangentialPressure: nil,
        deviceIdentifier: nil,
        estimationUpdateIndex: nil,
        estimatedProperties: [],
        estimatedPropertiesExpectingUpdates: [],
        velocity: 0,
        phase: phase,
        source: .pencil,
        kind: .actual,
        capabilities: [.pressure]
    )
}

@MainActor
private final class CompilerPipelinePreparer:
    DepositionPipelinePreparing
{
    var failure: DepositionPipelineLibraryError?
    var suspendedBrushKey: BrushPipelineKey?
    var suspensionGate: CompilerPhaseGate?
    private(set) var prepareCallCount = 0
    private(set) var stateCreationCount = 0

    private let state: any MTLRenderPipelineState
    private var bindings:
        [DepositionPipelineKey: DepositionPipelineBinding] = [:]

    init(state: any MTLRenderPipelineState) {
        self.state = state
    }

    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        prepareCallCount += 1
        if key.brush == suspendedBrushKey, let suspensionGate {
            await suspensionGate.suspend()
        }
        if let failure {
            throw failure
        }
        if let binding = bindings[key] {
            return binding
        }
        let binding = DepositionPipelineBinding(key: key, state: state)
        bindings[key] = binding
        stateCreationCount += 1
        return binding
    }
}

@MainActor
private func makeCompilerPipelinePreparer(
    device: any MTLDevice
) throws -> CompilerPipelinePreparer {
    let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 compilerPipelineVertex(uint id [[vertex_id]]) {
            const float2 points[3] = {
                float2(-1, -1), float2(3, -1), float2(-1, 3)
            };
            return float4(points[id], 0, 1);
        }
        fragment float4 compilerPipelineFragment() {
            return float4(0);
        }
        """
    let library = try device.makeLibrary(source: source, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = try #require(
        library.makeFunction(name: "compilerPipelineVertex")
    )
    descriptor.fragmentFunction = try #require(
        library.makeFunction(name: "compilerPipelineFragment")
    )
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return CompilerPipelinePreparer(
        state: try device.makeRenderPipelineState(descriptor: descriptor)
    )
}

private func compilerPipelineKey(
    program: BrushProgram
) -> BrushPipelineKey {
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

private actor CompilerPhaseGate {
    private var suspended = false
    private var released = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        suspendedWaiters.forEach { $0.resume() }
        suspendedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation {
            releaseWaiters.append($0)
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation {
            suspendedWaiters.append($0)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CompilerHashProbe {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation {
            waiters.append($0)
        }
    }
}

private enum CompilerTestError: Error {
    case expectedFailure
}

private func compilerFixtureDecodedTexture() throws -> DecodedBrushTexture {
    let data = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAABKADAAQAAAABAAAABAAAAADFbP4CAAAAJ0lEQVQIHWP4DwQMDAxwzMTIyMgAEQMKAwETiEAWZATyQcrBAKQSAJJxEPsf8WuRAAAAAElFTkSuQmCC"
        )
    )
    let resource = try BrushPackageResource(
        id: "shape.main",
        kind: .shape,
        mediaType: "image/png",
        data: data,
        pixelWidth: 4,
        pixelHeight: 4
    )
    return try BrushAssetDecoder.decode(
        resource: resource,
        data: data,
        profile: BrushDeviceProfile(
            registryID: 7,
            recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
            maximumWorkingTextureDimension: 4,
            brushCacheBudgetBytes: 1_024,
            targetFramesPerSecond: 120
        )
    )
}

private func readPrivateMip(
    _ texture: any MTLTexture,
    level: Int,
    device: any MTLDevice,
    queue: any MTLCommandQueue
) throws -> Data {
    let width = max(1, texture.width >> level)
    let height = max(1, texture.height >> level)
    let alignment = device.minimumTextureBufferAlignment(for: texture.pixelFormat)
    let bytesPerRow = ((width + alignment - 1) / alignment) * alignment
    let buffer = try #require(
        device.makeBuffer(
            length: bytesPerRow * height,
            options: .storageModeShared
        )
    )
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let encoder = try #require(commandBuffer.makeBlitCommandEncoder())
    encoder.copy(
        from: texture,
        sourceSlice: 0,
        sourceLevel: level,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: width, height: height, depth: 1),
        to: buffer,
        destinationOffset: 0,
        destinationBytesPerRow: bytesPerRow,
        destinationBytesPerImage: bytesPerRow * height
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    try #require(commandBuffer.status == .completed)

    let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
    var result = Data()
    result.reserveCapacity(width * height)
    for row in 0..<height {
        result.append(source.advanced(by: row * bytesPerRow), count: width)
    }
    return result
}
