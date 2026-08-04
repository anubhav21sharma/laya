import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Sparse tile sampling pipeline", .serialized)
struct SparseTileSamplingPipelineTests {
    @Test
    func sparseEntryPointsCompileIndependently() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseSamplingLibrary(device: device)
        #expect(library.makeFunction(name: "patternSparseSamplingVertex") != nil)
        #expect(
            library.makeFunction(
                name: "patternSparseSamplingTier2Fragment"
            ) != nil
        )
        #expect(
            library.makeFunction(
                name: "patternSparseSamplingFallbackFragment"
            ) != nil
        )
    }

    @Test
    func backendSelectionChecksRealTierAndCanForceFallback() throws {
        #expect(try SparseTileSamplingBackend.select(
            request: .automatic,
            capabilities: .init(supportsTier2ArgumentBuffers: true)
        ) == .tier2ArgumentBuffer)
        #expect(try SparseTileSamplingBackend.select(
            request: .forceFallback,
            capabilities: .init(supportsTier2ArgumentBuffers: true)
        ) == .directFallback)
        #expect(try SparseTileSamplingBackend.select(
            request: .automatic,
            capabilities: .init(supportsTier2ArgumentBuffers: false)
        ) == .directFallback)
        #expect(throws: SparseTileSamplingPipelineError.unsupportedTier2) {
            _ = try SparseTileSamplingBackend.select(
                request: .forceTier2,
                capabilities: .init(supportsTier2ArgumentBuffers: false)
            )
        }
    }

    @Test @MainActor
    func preparationCompilesOnlyRequestedBackend() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseSamplingLibrary(device: device)
        let capabilities = SparseTileSamplingDeviceCapabilities(device: device)
        let fallback = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: key(.directFallback),
            capabilities: capabilities
        )
        #expect(fallback.key.backend == .directFallback)
        #expect(try fallback.makeArgumentEncoder() == nil)

        if capabilities.supportsTier2ArgumentBuffers {
            let tier2 = try SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: key(.tier2ArgumentBuffer),
                capabilities: capabilities
            )
            #expect(tier2.key.backend == .tier2ArgumentBuffer)
            #expect(try tier2.makeArgumentEncoder() != nil)
        }
    }

    @Test @MainActor
    func forcedUnsupportedTier2DoesNotPreventFallbackPreparation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseSamplingLibrary(device: device)
        let tier1 = SparseTileSamplingDeviceCapabilities(
            supportsTier2ArgumentBuffers: false
        )
        #expect(throws: SparseTileSamplingPipelineError.unsupportedTier2) {
            _ = try SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: key(.tier2ArgumentBuffer),
                capabilities: tier1
            )
        }
        let fallback = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: key(.directFallback),
            capabilities: tier1
        )
        #expect(fallback.key.backend == .directFallback)
    }

    @Test @MainActor
    func immutableGPUPlanRejectsInvalidTargetBeforeEncoding() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let binding = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let gpuLease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: binding)
        try fixture.planLease.retire()

        let invalid = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.shaderRead])
        ))
        #expect(throws: SparseTileSamplingPipelineError.invalidUsage(
            invalid.usage.rawValue
        )) {
            _ = try SparseTileSamplingEncoder.preflightEncode(
                target: invalid,
                plan: gpuLease,
                parameters: .identity
            )
        }
        try gpuLease.complete()
        #expect(fixture.surfaces.allSatisfy {
            $0.backingSnapshot().activeLeaseCount == 0
        })
    }

    @Test @MainActor
    func exactSingleTexelMatchesOnFallbackAndTier2() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let expected = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        let fallback = try await renderSinglePixel(
            device: device,
            backend: .directFallback,
            roleColors: [.canonical: expected]
        )
        expectClose(fallback, expected)

        if device.argumentBuffersSupport == .tier2 {
            let tier2 = try await renderSinglePixel(
                device: device,
                backend: .tier2ArgumentBuffer,
                roleColors: [.canonical: expected]
            )
            expectClose(tier2, expected)
            expectClose(tier2, fallback)
        }
    }

    @Test @MainActor
    func drawEraseAndHiddenLiveUseNeighborCompositionContract() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let roles: [SparseTileSampleRole: SIMD4<Float>] = [
            .canonical: SIMD4(0, 0, 1, 1),
            .authoritative: SIMD4(0.5, 0, 0, 0.5),
            .prediction: SIMD4(0, 0.25, 0, 0.25),
        ]
        let drawn = try await renderSinglePixel(
            device: device,
            backend: .directFallback,
            roleColors: roles,
            parameters: .identity
        )
        expectClose(drawn, SIMD4(0.375, 0.25, 0.375, 1))

        let erased = try await renderSinglePixel(
            device: device,
            backend: .directFallback,
            roleColors: roles,
            parameters: .init(
                outputToSourceTransform: .identity,
                compositeMode: PatternCompositeWireErase,
                liveVisible: true,
                strokeOpacity: 1,
                accumulationLimit: 1,
                eraserStrength: 1
            )
        )
        expectClose(erased, SIMD4(0, 0, 0.375, 0.375))

        let hidden = try await renderSinglePixel(
            device: device,
            backend: .directFallback,
            roleColors: roles,
            parameters: .init(
                outputToSourceTransform: .identity,
                compositeMode: PatternCompositeWireDraw,
                liveVisible: false,
                strokeOpacity: 1,
                accumulationLimit: 1,
                eraserStrength: 1
            )
        )
        expectClose(hidden, roles[.canonical]!)
    }

    @Test @MainActor
    func missingAndClippedNeighborsStayTransparentOnEveryBackend() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let color = SIMD4<Float>(0.8, 0.4, 0.2, 0.6)
        for backend in availableBackends(device) {
            let missing = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: [.init(x: 0, y: 0): color]],
                pixelSize: PixelSize(width: 512, height: 256),
                addressing: .finite(PixelSize(width: 512, height: 256)),
                point: SIMD2(256, 0.5)
            )
            expectClose(missing, color * 0.5)

            let clipped = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: [.init(x: 1, y: 0): color]],
                pixelSize: PixelSize(width: 300, height: 1),
                addressing: .finite(PixelSize(width: 300, height: 1)),
                point: SIMD2(300, 0.5)
            )
            expectClose(clipped, color * 0.5)

            let clear = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: [:]],
                pixelSize: PixelSize(width: 256, height: 256),
                addressing: .finite(PixelSize(width: 256, height: 256)),
                point: SIMD2(0.5, 0.5)
            )
            expectClose(clear, .zero)
        }
    }

    @Test @MainActor
    func horizontalVerticalAndFourTileSeamsMatchLinearReference() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let red = SIMD4<Float>(1, 0, 0, 1)
        let green = SIMD4<Float>(0, 1, 0, 1)
        let blue = SIMD4<Float>(0, 0, 1, 1)
        let white = SIMD4<Float>(1, 1, 1, 1)
        let tiles: [PaintTileCoordinate: SIMD4<Float>] = [
            .init(x: 0, y: 0): red,
            .init(x: 1, y: 0): green,
            .init(x: 0, y: 1): blue,
            .init(x: 1, y: 1): white,
        ]
        let size = PixelSize(width: 512, height: 512)
        for backend in availableBackends(device) {
            let horizontal = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: tiles],
                pixelSize: size,
                addressing: .finite(size),
                point: SIMD2(256, 10.5)
            )
            expectClose(horizontal, (red + green) * 0.5)

            let vertical = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: tiles],
                pixelSize: size,
                addressing: .finite(size),
                point: SIMD2(10.5, 256)
            )
            expectClose(vertical, (red + blue) * 0.5)

            let corner = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: tiles],
                pixelSize: size,
                addressing: .finite(size),
                point: SIMD2(256, 256)
            )
            expectClose(corner, (red + green + blue + white) * 0.25)
        }
    }

    @Test @MainActor
    func negativeAndMaximumPeriodicSeamsMatchOnEveryBackend() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let left = SIMD4<Float>(0.2, 0.4, 0.6, 0.8)
        let right = SIMD4<Float>(0.8, 0.2, 0.4, 0.6)
        let size = PixelSize(width: 512, height: 256)
        let tiles: [PaintTileCoordinate: SIMD4<Float>] = [
            .init(x: 0, y: 0): left,
            .init(x: 1, y: 0): right,
        ]
        for backend in availableBackends(device) {
            let negative = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: tiles],
                pixelSize: size,
                addressing: .periodic(period: size),
                point: SIMD2(0, 0.5)
            )
            let maximum = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: tiles],
                pixelSize: size,
                addressing: .periodic(period: size),
                point: SIMD2(512, 0.5)
            )
            expectClose(negative, (right + left) * 0.5)
            expectClose(maximum, negative)
        }
    }

    @Test @MainActor
    func signedRadialLogicalPageAndAtlasSeamMatchOnEveryBackend() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 512,
            sectorAngleRadians: .pi
        )
        let pages = Dictionary(
            uniqueKeysWithValues: layout.residentPages.map {
                ($0.coordinate, $0)
            }
        )
        let lower = try #require(layout.residentPages.first { page in
            page.coordinate.x < 0
                && pages[RadialPageCoordinate(
                    x: page.coordinate.x + 1,
                    y: page.coordinate.y
                )] != nil
        })
        let upper = try #require(pages[RadialPageCoordinate(
            x: lower.coordinate.x + 1,
            y: lower.coordinate.y
        )])
        let lowerPhysical = physicalCoordinate(lower, layout: layout)
        let upperPhysical = physicalCoordinate(upper, layout: layout)
        let first = SIMD4<Float>(0.1, 0.3, 0.5, 0.7)
        let second = SIMD4<Float>(0.7, 0.5, 0.3, 0.9)
        let boundaryX = Double(upper.coordinate.x * PaintTileDescriptor.side)
        let y = Double(lower.coordinate.y * PaintTileDescriptor.side) + 0.5
        for backend in availableBackends(device) {
            let actual = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [.canonical: [
                    lowerPhysical: first,
                    upperPhysical: second,
                ]],
                pixelSize: layout.atlasPixelSize,
                addressing: .radial(layout: layout),
                point: SIMD2(boundaryX, y)
            )
            expectClose(actual, (first + second) * 0.5)
        }
    }

    @Test @MainActor
    func compositionHappensPerNeighborBeforeBilinearFiltering() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let clear = SIMD4<Float>.zero
        let opaqueBlue = SIMD4<Float>(0, 0, 1, 1)
        let halfRed = SIMD4<Float>(0.5, 0, 0, 0.5)
        let left = PaintTileCoordinate(x: 0, y: 0)
        let right = PaintTileCoordinate(x: 1, y: 0)
        let expected = SIMD4<Float>(0.25, 0, 0.5, 0.75)
        for backend in availableBackends(device) {
            let actual = try await renderSample(
                device: device,
                backend: backend,
                roleTiles: [
                    .canonical: [left: opaqueBlue, right: clear],
                    .authoritative: [left: clear, right: halfRed],
                ],
                pixelSize: size,
                addressing: .finite(size),
                point: SIMD2(256, 0.5)
            )
            expectClose(actual, expected)
        }
    }

    @Test @MainActor
    func gpuPlanCacheReusesImmutableContentAndCompletesOutOfOrder() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        let first = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let second = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        #expect(first.immutableContentIdentity == second.immutableContentIdentity)
        #expect(await cache.preparedCount == 1)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)

        try fixture.planLease.retire()
        try second.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        try first.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        #expect(throws: SparseTileSamplingPipelineError.alreadyConsumed) {
            try first.complete()
        }
    }

    @Test @MainActor
    func cacheEvictionDoesNotReleaseAnInflightP3Consumer() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        let lease = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        await cache.invalidate(content: fixture.planLease.content)
        #expect(await cache.preparedCount == 0)
        try fixture.planLease.retire()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        try lease.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func everyFallbackGPUPlanBuildFailureIsAtomicAndRetryable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        for phase in [
            SparseTileSamplingFailurePhase.descriptorBuffer,
            .entryBuffer,
            .fallbackRemapBuffer,
        ] {
            await cache.injectFailureForNextBuild(phase)
            do {
                _ = try await cache.acquire(
                    plan: fixture.planLease,
                    pipeline: pipeline
                )
                Issue.record("Expected injected failure at \(phase)")
            } catch {
                #expect(error as? SparseTileSamplingPipelineError
                    == .injectedFailure(phase.rawValue))
            }
            #expect(await cache.preparedCount == 0)
            #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
            let recovered = try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            try recovered.complete()
            await cache.invalidate(content: fixture.planLease.content)
        }
        try fixture.planLease.retire()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func tier2BuildFailurePreservesOldFallbackCacheEntry() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              device.argumentBuffersSupport == .tier2
        else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let library = try makeSparseSamplingLibrary(device: device)
        let fallback = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: key(.directFallback)
        )
        let tier2 = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: library,
            key: key(.tier2ArgumentBuffer)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        let old = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: fallback
        )
        #expect(await cache.preparedCount == 1)
        await cache.injectFailureForNextBuild(.argumentEncoder)
        do {
            _ = try await cache.acquire(plan: fixture.planLease, pipeline: tier2)
            Issue.record("Expected argument encoder failure")
        } catch {
            #expect(error as? SparseTileSamplingPipelineError
                == .injectedFailure("argumentEncoder"))
        }
        #expect(await cache.preparedCount == 1)
        let recovered = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: tier2
        )
        #expect(await cache.preparedCount == 2)
        try fixture.planLease.retire()
        try recovered.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        try old.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func failedCapacityReplacementPreservesCachedPlanTransactionally()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseSamplingLibrary(device: device)
        var cases: [(
            SparseTileSamplingBackend,
            [SparseTileSamplingFailurePhase]
        )] = [
            (
                .directFallback,
                [.descriptorBuffer, .entryBuffer, .fallbackRemapBuffer,
                 .uploadRing]
            ),
        ]
        if device.argumentBuffersSupport == .tier2 {
            cases.append((
                .tier2ArgumentBuffer,
                [.argumentEncoder, .descriptorBuffer, .entryBuffer,
                 .argumentBuffer, .uploadRing]
            ))
        }

        for (backend, phases) in cases {
            let pipeline = try SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: key(backend)
            )
            for (index, phase) in phases.enumerated() {
                let cache = SparseTileSamplingGPUPlanCache(
                    device: device,
                    limits: SparseTileSamplingGPUPlanLimits(
                        maximumDescriptors: 3,
                        maximumPageEntries: 64,
                        maximumBufferBytes: 64 * 1_024,
                        maximumInflightEncodes: 3,
                        maximumCachedPlans: 1,
                        maximumCachedBufferBytes: 64 * 1_024
                    )
                )
                let cachedFixture = try makeSamplingFixture(
                    device: device,
                    roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
                )
                let candidateFixture = try makeSamplingFixture(
                    device: device,
                    roleColors: [.canonical: SIMD4(
                        0.75,
                        Float(index + 1) / Float(phases.count + 1),
                        0.25,
                        1
                    )]
                )
                let cachedLease = try await cache.acquire(
                    plan: cachedFixture.planLease,
                    pipeline: pipeline
                )
                let cachedIdentity = cachedLease.immutableContentIdentity
                try cachedLease.complete()
                let before = await cache.allocationSnapshot

                await cache.injectFailureForNextBuild(phase)
                do {
                    _ = try await cache.acquire(
                        plan: candidateFixture.planLease,
                        pipeline: pipeline
                    )
                    Issue.record("Expected injected failure at \(phase)")
                } catch {
                    #expect(error as? SparseTileSamplingPipelineError
                        == .injectedFailure(phase.rawValue))
                }
                #expect(await cache.allocationSnapshot == before)
                #expect(await cache.preparedCount == 1)
                try candidateFixture.planLease.retire()
                #expect(
                    candidateFixture.surfaces[0].backingSnapshot()
                        .activeLeaseCount == 0
                )

                let reused = try await cache.acquire(
                    plan: cachedFixture.planLease,
                    pipeline: pipeline
                )
                #expect(reused.immutableContentIdentity == cachedIdentity)
                let target = try #require(device.makeTexture(
                    descriptor: targetDescriptor(usage: [.renderTarget])
                ))
                var prepared: SparseTileSamplingPreparedEncode? = try
                    SparseTileSamplingEncoder.preflightEncode(
                        target: target,
                        plan: reused,
                        parameters: .identity
                    )
                prepared = nil
                try cachedFixture.planLease.retire()
                #expect(
                    cachedFixture.surfaces[0].backingSnapshot()
                        .activeLeaseCount == 0
                )
                _ = prepared
            }
        }
    }

    @Test @MainActor
    func preflightBufferFailuresDoNotConsumeTheGPUPlan() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let lease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.renderTarget, .shaderRead])
        ))
        for phase in [
            SparseTileSamplingFailurePhase.preflightUniformBuffer,
            .preflightMaterialBuffer,
        ] {
            #expect(throws: SparseTileSamplingPipelineError.injectedFailure(
                phase.rawValue
            )) {
                _ = try SparseTileSamplingEncoder.preflightEncode(
                    target: target,
                    plan: lease,
                    parameters: .identity,
                    injectedFailure: phase
                )
            }
        }
        var prepared: SparseTileSamplingPreparedEncode? = try
            SparseTileSamplingEncoder.preflightEncode(
            target: target,
            plan: lease,
            parameters: .identity
        )
        try fixture.planLease.retire()
        prepared = nil
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        _ = prepared
    }

    @Test @MainActor
    func targetSourceAliasIsRejectedBeforeEncoderMutation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSamplingFixture(
            device: device,
            roleTiles: [.canonical: [
                .init(x: 0, y: 0): SIMD4(0.25, 0.5, 0.75, 1),
            ]],
            pixelSize: size,
            addressing: .finite(size),
            outputRegion: SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 256, maxY: 256
            )
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let lease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        let source = try #require(fixture.planLease.boundTextures.first?.texture)
        #expect(throws: SparseTileSamplingPipelineError.targetSourceAlias) {
            _ = try SparseTileSamplingEncoder.preflightEncode(
                target: source,
                plan: lease,
                parameters: .identity
            )
        }
        try fixture.planLease.retire()
        try lease.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func tier2CoalescesWhileFallbackUsesBoundedBatchesWithIdenticalOutput()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              device.argumentBuffersSupport == .tier2
        else { return }
        let tileCount = 17
        let size = PixelSize(
            width: tileCount * PaintTileDescriptor.side,
            height: 1
        )
        let colors = Dictionary(uniqueKeysWithValues: (0..<tileCount).map {
            index in
            (
                PaintTileCoordinate(x: index, y: 0),
                index.isMultiple(of: 2)
                    ? SIMD4<Float>(0.75, 0.25, 0.5, 1)
                    : SIMD4<Float>(0.125, 0.625, 0.375, 0.75)
            )
        })
        let fixture = try makeSamplingFixture(
            device: device,
            roleTiles: [.canonical: colors],
            pixelSize: size,
            addressing: .finite(size),
            outputRegion: SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: size.width, maxY: 1
            )
        )
        #expect(fixture.planLease.content.batches.count > 1)
        #expect(fixture.planLease.content.batches.allSatisfy {
            $0.globalSlots.count <= SparseSamplingABI.maximumFallbackTextures
        })

        let library = try makeSparseSamplingLibrary(device: device)
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        let fallback = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: key(.directFallback)
            )
        )
        let tier2 = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: key(.tier2ArgumentBuffer)
            )
        )
        #expect(fallback.drawCount == fixture.planLease.content.batches.count)
        #expect(fallback.drawCount > 1)
        #expect(tier2.drawCount == 1)

        try fixture.planLease.retire()
        let fallbackBits = try await renderPlan(
            device: device,
            plan: fallback,
            width: size.width,
            height: 1,
            parameters: .identity
        )
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        let tier2Bits = try await renderPlan(
            device: device,
            plan: tier2,
            width: size.width,
            height: 1,
            parameters: .identity
        )
        #expect(fallbackBits == tier2Bits)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        for index in 0..<tileCount {
            let pixel = readPixel(
                fallbackBits,
                x: index * PaintTileDescriptor.side + 128,
                width: size.width
            )
            expectClose(pixel, colors[.init(x: index, y: 0)]!)
        }
    }

    @Test @MainActor
    func twoAxisDepthFirstBatchesRenderWithoutRowMajorRejection() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let tileSide = PaintTileDescriptor.side
        let tileCount = 8
        let size = PixelSize(
            width: tileCount * tileSide,
            height: tileCount * tileSide
        )
        let colors = Dictionary(uniqueKeysWithValues: (0..<tileCount).flatMap {
            y in
            (0..<tileCount).map { x in
                let coordinate = PaintTileCoordinate(x: x, y: y)
                let color = SIMD4<Float>(
                    Float(x + 1) / Float(tileCount + 1),
                    Float(y + 1) / Float(tileCount + 1),
                    Float(x + y + 1) / Float(tileCount * 2),
                    1
                )
                return (coordinate, color)
            }
        })
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: .zero,
            sourceStep: SIMD2(repeating: Float(tileSide))
        )
        let fixture = try makeSamplingFixture(
            device: device,
            roleTiles: [.canonical: colors],
            pixelSize: size,
            addressing: .finite(size),
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: tileCount, maxY: tileCount
            ),
            outputToSourceTransform: transform
        )
        let batches = fixture.planLease.content.batches
        #expect(batches.count > 1)
        #expect(zip(batches, batches.dropFirst()).contains { pair in
            (pair.0.outputRegion.minY, pair.0.outputRegion.minX)
                > (pair.1.outputRegion.minY, pair.1.outputRegion.minX)
        })

        let library = try makeSparseSamplingLibrary(device: device)
        for backend in availableBackends(device) {
            let lease = try await SparseTileSamplingGPUPlanCache(
                device: device
            ).acquire(
                plan: fixture.planLease,
                pipeline: SparseTileSamplingPipeline.prepare(
                    device: device,
                    library: library,
                    key: key(backend)
                )
            )
            let bits = try await renderPlan(
                device: device,
                plan: lease,
                width: tileCount,
                height: tileCount,
                parameters: SparseTileSamplingEncodeParameters(
                    outputToSourceTransform: transform,
                    compositeMode: PatternCompositeWireDraw,
                    liveVisible: true,
                    strokeOpacity: 1,
                    accumulationLimit: 1,
                    eraserStrength: 1
                )
            )
            for y in 0..<tileCount {
                for x in 0..<tileCount {
                    expectClose(
                        readPixel(bits, x: x, y: y, width: tileCount),
                        colors[PaintTileCoordinate(x: x, y: y)]!
                    )
                }
            }
        }
        try fixture.planLease.retire()
        #expect(fixture.surfaces.allSatisfy {
            $0.backingSnapshot().activeLeaseCount == 0
        })
    }

    @Test @MainActor
    func preparationAcceptsOpaqueSRGBDrawableFormat() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseSamplingLibrary(device: device)
        for backend in availableBackends(device) {
            let binding = try SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: key(backend, pixelFormat: .bgra8Unorm_srgb)
            )
            #expect(binding.key.outputPixelFormatRawValue
                == MTLPixelFormat.bgra8Unorm_srgb.rawValue)
        }
    }

    @Test @MainActor
    func opaqueSRGBDrawableEncodesLinearColorExactlyOnceOnEveryBackend()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let linearPremultiplied = SIMD4<Float>(0.25, 0.125, 0, 0.5)
        let expected = [
            encodedSRGBByte(linearPremultiplied.z),
            encodedSRGBByte(linearPremultiplied.y),
            encodedSRGBByte(linearPremultiplied.x),
            UInt8.max,
        ]
        for backend in availableBackends(device) {
            let actual = try await renderOpaqueDisplaySinglePixel(
                device: device,
                backend: backend,
                color: linearPremultiplied
            )
            for channel in 0..<4 {
                #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 1)
            }
        }
    }

    @Test @MainActor
    func tier2ArgumentBufferFailureIsAtomicAndRetryable() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              device.argumentBuffersSupport == .tier2
        else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.tier2ArgumentBuffer)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        await cache.injectFailureForNextBuild(.argumentBuffer)
        do {
            _ = try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            Issue.record("Expected argument buffer failure")
        } catch {
            #expect(error as? SparseTileSamplingPipelineError
                == .injectedFailure("argumentBuffer"))
        }
        #expect(await cache.preparedCount == 0)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        let recovered = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        try fixture.planLease.retire()
        try recovered.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func gpuPlanLimitsRejectBeforeCachePublicationAndRemainRetryable()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let limited = SparseTileSamplingGPUPlanCache(
            device: device,
            limits: SparseTileSamplingGPUPlanLimits(
                maximumDescriptors: 0,
                maximumPageEntries: 64,
                maximumBufferBytes: 64 * 32
            )
        )
        do {
            _ = try await limited.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            Issue.record("Expected descriptor limit rejection")
        } catch {
            #expect(error as? SparseTileSamplingPipelineError
                == .limitExceeded(required: 1, maximum: 0))
        }
        #expect(await limited.preparedCount == 0)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        let recovered = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        try fixture.planLease.retire()
        try recovered.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func nonidentityPanAndZoomPlansCarryTheirActualSourceHalos() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let left = SIMD4<Float>(0.2, 0.4, 0.6, 0.8)
        let right = SIMD4<Float>(0.8, 0.2, 0.4, 0.6)
        let tiles: [SparseTileSampleRole:
            [PaintTileCoordinate: SIMD4<Float>]] = [
                .canonical: [
                    .init(x: 0, y: 0): left,
                    .init(x: 1, y: 0): right,
                ],
            ]
        let cases: [(SparseTileOutputToSourceTransform, SIMD4<Float>)] = [
            (
                .init(sourceOffset: SIMD2(256, 0), sourceStep: SIMD2(1, 1)),
                right
            ),
            (
                .init(sourceOffset: .zero, sourceStep: SIMD2(512, 1)),
                (left + right) * 0.5
            ),
            (
                .init(
                    sourceOffset: SIMD2(255.75, 0),
                    sourceStep: SIMD2(0.5, 1)
                ),
                (left + right) * 0.5
            ),
        ]
        for (transform, expected) in cases {
            for backend in availableBackends(device) {
                let actual = try await renderTransformedSinglePixel(
                    device: device,
                    backend: backend,
                    roleTiles: tiles,
                    pixelSize: size,
                    addressing: .finite(size),
                    transform: transform
                )
                expectClose(actual, expected)
            }
        }
    }

    @Test @MainActor
    func transformedNegativePeriodicAndSignedRadialPlansKeepCompleteHalos()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let periodicSize = PixelSize(width: 512, height: 256)
        let left = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        let right = SIMD4<Float>(0.75, 0.5, 0.25, 1)
        let negative = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(-1, 0),
            sourceStep: SIMD2(1, 1)
        )
        for backend in availableBackends(device) {
            let actual = try await renderTransformedSinglePixel(
                device: device,
                backend: backend,
                roleTiles: [.canonical: [
                    .init(x: 0, y: 0): left,
                    .init(x: 1, y: 0): right,
                ]],
                pixelSize: periodicSize,
                addressing: .periodic(period: periodicSize),
                transform: negative
            )
            expectClose(actual, right)
        }

        let layout = try RadialSectorLayout(
            maximumRadius: 512,
            sectorAngleRadians: .pi
        )
        let page = try #require(layout.residentPages.first {
            $0.coordinate.x < 0
        })
        let physical = physicalCoordinate(page, layout: layout)
        let radialColor = SIMD4<Float>(0.125, 0.375, 0.625, 0.875)
        let radial = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(
                Float(page.coordinate.x * PaintTileDescriptor.side),
                Float(page.coordinate.y * PaintTileDescriptor.side)
            ),
            sourceStep: SIMD2(1, 1)
        )
        for backend in availableBackends(device) {
            let actual = try await renderTransformedSinglePixel(
                device: device,
                backend: backend,
                roleTiles: [.canonical: [physical: radialColor]],
                pixelSize: layout.atlasPixelSize,
                addressing: .radial(layout: layout),
                transform: radial
            )
            expectClose(actual, radialColor)
        }
    }

    @Test @MainActor
    func encodeRejectsATransformThatDoesNotMatchTheImmutablePlan() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(256, 0),
            sourceStep: SIMD2(1, 1)
        )
        let fixture = try makeSamplingFixture(
            device: device,
            roleTiles: [.canonical: [
                .init(x: 1, y: 0): SIMD4(0.25, 0.5, 0.75, 1),
            ]],
            pixelSize: PixelSize(width: 512, height: 256),
            addressing: .finite(PixelSize(width: 512, height: 256)),
            outputRegion: SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputToSourceTransform: transform
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let lease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.renderTarget])
        ))
        #expect(throws: SparseTileSamplingPipelineError.incompleteHalo) {
            _ = try SparseTileSamplingEncoder.preflightEncode(
                target: target,
                plan: lease,
                parameters: .identity
            )
        }
        try fixture.planLease.retire()
        try lease.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func uploadRingAndPlanBuffersStayBoundedAndTrackRebuilds() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(
            device: device,
            limits: SparseTileSamplingGPUPlanLimits(
                maximumDescriptors: 3,
                maximumPageEntries: 64,
                maximumBufferBytes: 64 * 32,
                maximumInflightEncodes: 2
            )
        )
        let first = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let second = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let third = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.renderTarget])
        ))
        var firstPrepared: SparseTileSamplingPreparedEncode? = try
            SparseTileSamplingEncoder.preflightEncode(
                target: target, plan: first, parameters: .identity
            )
        var secondPrepared: SparseTileSamplingPreparedEncode? = try
            SparseTileSamplingEncoder.preflightEncode(
                target: target, plan: second, parameters: .identity
            )
        #expect(first.uploadRingSnapshot == SparseTileSamplingUploadRingSnapshot(
            capacity: 2,
            activeSlotCount: 2,
            highWaterSlotCount: 2,
            metalBufferAllocationCount: 1,
            metalBufferBytes: 2 * 512
        ))
        #expect(throws: SparseTileSamplingPipelineError.limitExceeded(
            required: 3,
            maximum: 2
        )) {
            _ = try SparseTileSamplingEncoder.preflightEncode(
                target: target, plan: third, parameters: .identity
            )
        }

        firstPrepared = nil
        #expect(first.uploadRingSnapshot.activeSlotCount == 1)
        var thirdPrepared: SparseTileSamplingPreparedEncode? = try
            SparseTileSamplingEncoder.preflightEncode(
                target: target, plan: third, parameters: .identity
            )
        #expect(first.uploadRingSnapshot.activeSlotCount == 2)
        secondPrepared = nil
        thirdPrepared = nil
        #expect(first.uploadRingSnapshot.activeSlotCount == 0)
        for _ in 0..<100 {
            let warmedLease = try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            var warmed: SparseTileSamplingPreparedEncode? = try
                SparseTileSamplingEncoder.preflightEncode(
                    target: target,
                    plan: warmedLease,
                    parameters: .identity
                )
            #expect(warmed != nil)
            warmed = nil
        }
        let warmed = first.uploadRingSnapshot
        let warmedCache = await cache.allocationSnapshot
        #expect(warmed.activeSlotCount == 0)
        #expect(warmed.highWaterSlotCount == 2)
        #expect(warmed.metalBufferAllocationCount == 1)
        #expect(warmedCache.planMetalBufferAllocationCount > 0)

        await cache.invalidate(content: fixture.planLease.content)
        let rebuilt = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let rebuiltCache = await cache.allocationSnapshot
        #expect(
            rebuiltCache.planMetalBufferAllocationCount
                == warmedCache.planMetalBufferAllocationCount * 2
        )
        #expect(
            rebuiltCache.uploadRing?.metalBufferAllocationCount
                == warmedCache.uploadRing?.metalBufferAllocationCount
        )

        try fixture.planLease.retire()
        try rebuilt.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        _ = firstPrepared
        _ = secondPrepared
        _ = thirdPrepared
    }

    @Test @MainActor
    func gpuLeaseAllowsExactlyOneSuccessfulPreflight() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let lease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.renderTarget])
        ))
        var prepared: SparseTileSamplingPreparedEncode? = try
            SparseTileSamplingEncoder.preflightEncode(
                target: target,
                plan: lease,
                parameters: .identity
            )

        #expect(throws: SparseTileSamplingPipelineError.alreadyConsumed) {
            _ = try SparseTileSamplingEncoder.preflightEncode(
                target: target,
                plan: lease,
                parameters: .identity
            )
        }

        try fixture.planLease.retire()
        prepared = nil
        _ = try? lease.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        _ = prepared
    }

    @Test @MainActor
    func externalCompletionIsRejectedAfterPreflightTransfersOwnership()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let lease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.renderTarget])
        ))
        var prepared: SparseTileSamplingPreparedEncode? = try
            SparseTileSamplingEncoder.preflightEncode(
                target: target,
                plan: lease,
                parameters: .identity
            )

        #expect(throws: SparseTileSamplingPipelineError.alreadyConsumed) {
            try lease.complete()
        }

        try fixture.planLease.retire()
        prepared = nil
        _ = try? lease.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        _ = prepared
    }

    @Test @MainActor
    func preparedEncodesAreOneShotAndTerminalCommandsMayCompleteOutOfOrder()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        let firstLease = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let secondLease = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let targets = try (0..<2).map { _ in
            try #require(device.makeTexture(
                descriptor: targetDescriptor(
                    usage: [.renderTarget, .shaderRead]
                )
            ))
        }
        let firstPrepared = try SparseTileSamplingEncoder.preflightEncode(
            target: targets[0],
            plan: firstLease,
            parameters: .identity
        )
        let secondPrepared = try SparseTileSamplingEncoder.preflightEncode(
            target: targets[1],
            plan: secondLease,
            parameters: .identity
        )
        #expect(firstLease.uploadRingSnapshot.activeSlotCount == 2)
        #expect(firstLease.uploadRingSnapshot.highWaterSlotCount == 2)
        try fixture.planLease.retire()

        let queue = try #require(device.makeCommandQueue())
        let firstCommand = try #require(queue.makeCommandBuffer())
        let secondCommand = try #require(queue.makeCommandBuffer())
        let firstPass = MTLRenderPassDescriptor()
        firstPass.colorAttachments[0].texture = targets[0]
        firstPass.colorAttachments[0].loadAction = .clear
        firstPass.colorAttachments[0].storeAction = .store
        let secondPass = MTLRenderPassDescriptor()
        secondPass.colorAttachments[0].texture = targets[1]
        secondPass.colorAttachments[0].loadAction = .clear
        secondPass.colorAttachments[0].storeAction = .store
        try firstPrepared.encode(
            commandBuffer: firstCommand,
            renderPassDescriptor: firstPass
        )
        try secondPrepared.encode(
            commandBuffer: secondCommand,
            renderPassDescriptor: secondPass
        )
        let rejectedCommand = try #require(queue.makeCommandBuffer())
        #expect(throws: SparseTileSamplingPipelineError.alreadyConsumed) {
            try firstPrepared.encode(
                commandBuffer: rejectedCommand,
                renderPassDescriptor: firstPass
            )
        }

        await withCheckedContinuation { continuation in
            secondCommand.addCompletedHandler { _ in continuation.resume() }
            secondCommand.commit()
        }
        #expect(firstLease.uploadRingSnapshot.activeSlotCount == 1)
        await withCheckedContinuation { continuation in
            firstCommand.addCompletedHandler { _ in continuation.resume() }
            firstCommand.commit()
        }
        #expect(firstLease.uploadRingSnapshot.activeSlotCount == 0)
        let completion = await cache.completionSnapshot
        #expect(completion.terminalCommandCount == 2)
        #expect(completion.commandFailureCount == 0)
        #expect(completion.pendingPlanCompletionCount == 0)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func failedPreparedAbandonmentIsRetryableAndRendererRemainsReusable()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let failure = OneShotLeaseReturnFailure()
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)],
            planCache: SparseTileSamplingPlanCache(
                returnLease: { surface, lease in
                    if failure.consumeFailure() {
                        throw PipelineTestError.injected
                    }
                    try surface.returnLease(lease)
                }
            )
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        let abandonedLease = try await cache.acquire(
            plan: fixture.planLease,
            pipeline: pipeline
        )
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.renderTarget, .shaderRead])
        ))
        var abandoned: SparseTileSamplingPreparedEncode? = try
            SparseTileSamplingEncoder.preflightEncode(
                target: target,
                plan: abandonedLease,
                parameters: .identity
            )
        #expect(abandonedLease.uploadRingSnapshot.activeSlotCount == 1)
        try fixture.planLease.retire()
        abandoned = nil
        #expect(abandonedLease.uploadRingSnapshot.activeSlotCount == 0)
        #expect(await cache.completionSnapshot.pendingPlanCompletionCount == 1)
        #expect(await cache.retryPendingPlanCompletions() == 0)
        #expect(await cache.completionSnapshot.pendingPlanCompletionCount == 0)
        #expect(await cache.retryPendingPlanCompletions() == 0)

        let reusableFixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.5, 0.25, 0.125, 1)],
            planCache: SparseTileSamplingPlanCache()
        )
        let reusableLease = try await cache.acquire(
            plan: reusableFixture.planLease,
            pipeline: pipeline
        )
        let prepared = try SparseTileSamplingEncoder.preflightEncode(
            target: target,
            plan: reusableLease,
            parameters: .identity
        )
        try reusableFixture.planLease.retire()
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try prepared.encode(
            commandBuffer: command,
            renderPassDescriptor: pass
        )
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        #expect(
            reusableFixture.surfaces[0].backingSnapshot().activeLeaseCount == 0
        )
        #expect(await cache.completionSnapshot.pendingPlanCompletionCount == 0)
        _ = abandoned
    }

    @Test @MainActor
    func preparedEncodeCannotSubstituteAnotherRenderTarget() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let expected = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: expected]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let lease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        let targetA = try #require(device.makeTexture(
            descriptor: targetDescriptor(
                usage: [.renderTarget, .shaderRead]
            )
        ))
        let targetB = try #require(device.makeTexture(
            descriptor: targetDescriptor(
                usage: [.renderTarget, .shaderRead]
            )
        ))
        let prepared = try SparseTileSamplingEncoder.preflightEncode(
            target: targetA,
            plan: lease,
            parameters: .identity
        )
        try fixture.planLease.retire()
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targetB
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        #expect(throws: SparseTileSamplingPipelineError.invalidTarget(
            "render pass does not own the preflight target"
        )) {
            try prepared.encode(
                commandBuffer: commandBuffer,
                renderPassDescriptor: pass
            )
        }
        pass.colorAttachments[0].texture = targetA
        try prepared.encode(
            commandBuffer: commandBuffer,
            renderPassDescriptor: pass
        )
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        expectClose(readSinglePixel(targetA), expected)
        expectClose(readSinglePixel(targetB), .zero)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func commandCompletionReturnsUploadSlotAndReportsPlanReturnFailure()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let failure = OneShotLeaseReturnFailure()
        let p3Cache = SparseTileSamplingPlanCache(
            returnLease: { surface, lease in
                if failure.consumeFailure() { throw PipelineTestError.injected }
                try surface.returnLease(lease)
            }
        )
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)],
            planCache: p3Cache
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let lease = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(
                usage: [.renderTarget, .shaderRead]
            )
        ))
        let prepared = try SparseTileSamplingEncoder.preflightEncode(
            target: target,
            plan: lease,
            parameters: .identity
        )
        #expect(lease.uploadRingSnapshot.activeSlotCount == 1)
        try fixture.planLease.retire()
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try prepared.encode(
            commandBuffer: commandBuffer,
            renderPassDescriptor: pass
        )
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        #expect(lease.uploadRingSnapshot.activeSlotCount == 0)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        let failed = lease.completionMailbox.snapshot
        #expect(failed.terminalCommandCount == 1)
        #expect(failed.commandFailureCount == 0)
        #expect(failed.planCompletionFailureCount == 1)
        #expect(failed.pendingPlanCompletionCount == 1)
        #expect(lease.completionMailbox.retryPendingPlanCompletions() == 0)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        #expect(lease.completionMailbox.snapshot.pendingPlanCompletionCount == 0)
    }

    @Test
    func allocatorProbeMeasuresWarmedSamplingLifecycle() throws {
        let root = repositoryRoot()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            root.appendingPathComponent(
                "scripts/run-brush-input-allocation-probe.sh"
            ).path,
            root.appendingPathComponent(
                ".build/stage-d-sampling-allocation-probe-tests"
            ).path,
            "release",
            "stage-d-sampling",
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)

        #expect(process.terminationStatus == 0, "\(output)")
        #expect(
            output.contains("ALLOCATOR PROBE STAGE D SAMPLING PASS"),
            "\(output)"
        )
    }

    @Test
    func frozenAllocationCapsRejectOneCountRegressionsWithoutLowerBounds() {
        let caps: [SparseTileSamplingAllocationCap] = [
            .acquire,
            .preflight,
            .submission,
            .completion,
            .completionWait,
        ]
        for cap in caps {
            #expect(cap.accepts(
                maximumObserved: 0,
                firstHalf: 0,
                lastHalf: 0
            ))
            #expect(cap.accepts(
                maximumObserved: cap.maximumSingleEventCount,
                firstHalf: 8,
                lastHalf: 8
            ))
            #expect(!cap.accepts(
                maximumObserved: cap.maximumSingleEventCount + 1,
                firstHalf: 8,
                lastHalf: 8
            ))
            if cap.enforcesNonIncreasingHalves {
                #expect(!cap.accepts(
                    maximumObserved: 0,
                    firstHalf: 7,
                    lastHalf: 8
                ))
            } else {
                #expect(cap.accepts(
                    maximumObserved: 0,
                    firstHalf: 0,
                    lastHalf: .max
                ))
            }
        }
    }

    @Test @MainActor
    func abandonedGPUPlanRetainsAFailedConsumerReturnForObservableRetry()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let failure = CountedLeaseReturnFailure(remainingFailures: 1)
        let p3Cache = SparseTileSamplingPlanCache(
            returnLease: { surface, lease in
                if failure.consumeFailure() { throw PipelineTestError.injected }
                try surface.returnLease(lease)
            }
        )
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)],
            planCache: p3Cache
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        var lease: SparseTileSamplingGPUPlanLease? = try await
            SparseTileSamplingGPUPlanCache(device: device).acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
        let mailbox = try #require(lease?.completionMailbox)
        try fixture.planLease.retire()
        lease = nil

        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        #expect(mailbox.snapshot.pendingConsumerCompletionCount == 1)
        #expect(mailbox.retryPendingPlanCompletions() == 0)
        #expect(mailbox.snapshot.pendingConsumerCompletionCount == 0)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func buildFailureRetainsConsumerWhenRetirementRacesWithBuild() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let failure = CountedLeaseReturnFailure(remainingFailures: 1)
        let p3Cache = SparseTileSamplingPlanCache(
            returnLease: { surface, lease in
                if failure.consumeFailure() { throw PipelineTestError.injected }
                try surface.returnLease(lease)
            }
        )
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)],
            planCache: p3Cache
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(
            device: device,
            buildObserver: { _ in try? fixture.planLease.retire() }
        )
        await cache.injectFailureForNextBuild(.descriptorBuffer)
        do {
            _ = try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            Issue.record("Expected injected descriptor failure")
        } catch {
            #expect(error as? SparseTileSamplingPipelineError
                == .injectedFailure("descriptorBuffer"))
        }

        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        #expect(await cache.completionSnapshot.pendingConsumerCompletionCount == 1)
        #expect(await cache.retryPendingPlanCompletions() == 0)
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func gpuPlanBuildRunsOffMainWhenAcquiredFromDetachedWork() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let witness = MainThreadWitness()
        let cache = SparseTileSamplingGPUPlanCache(
            device: device,
            buildObserver: { witness.record($0) }
        )
        let lease = try await Task.detached {
            try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
        }.value
        #expect(witness.values == [false])
        try fixture.planLease.retire()
        try lease.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func pageEntryAndCombinedByteLimitsRejectBeforeRingOrCachePublication()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.25, 0.5, 0.75, 1)]
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let limits = [
            SparseTileSamplingGPUPlanLimits(
                maximumDescriptors: 3,
                maximumPageEntries: 0,
                maximumBufferBytes: 64
            ),
            SparseTileSamplingGPUPlanLimits(
                maximumDescriptors: 3,
                maximumPageEntries: 1,
                maximumBufferBytes: 63
            ),
        ]
        let exactAggregateBytes = try expectedAggregateMetalBytes(
            plan: fixture.planLease,
            pipeline: pipeline,
            uploadCapacity: 3
        )
        for (index, limit) in limits.enumerated() {
            let workspace = WorkspaceAllocationWitness()
            let cache = SparseTileSamplingGPUPlanCache(
                device: device,
                limits: limit,
                workspaceAllocationObserver: { workspace.record($0) }
            )
            do {
                _ = try await cache.acquire(
                    plan: fixture.planLease,
                    pipeline: pipeline
                )
                Issue.record("Expected GPU-plan limit failure \(index)")
            } catch let error as SparseTileSamplingPipelineError {
                switch (index, error) {
                case (0, .limitExceeded(required: 1, maximum: 0)):
                    break
                case (1, .limitExceeded(
                    required: exactAggregateBytes,
                    maximum: 63
                )):
                    break
                default:
                    Issue.record("Unexpected limit error: \(error)")
                }
            }
            #expect(await cache.preparedCount == 0)
            #expect(workspace.values.isEmpty)
            #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 1)
        }
        let recovered = try await SparseTileSamplingGPUPlanCache(
            device: device
        ).acquire(plan: fixture.planLease, pipeline: pipeline)
        try fixture.planLease.retire()
        try recovered.complete()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func aggregateMetalBudgetRejectsOneByteBeforeAnyPlanBufferAllocation()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let tileCount = 17
        let size = PixelSize(
            width: tileCount * PaintTileDescriptor.side,
            height: 1
        )
        let colors = Dictionary(uniqueKeysWithValues: (0..<tileCount).map {
            index in
            (PaintTileCoordinate(x: index, y: 0), SIMD4<Float>(1, 0, 0, 1))
        })
        let fixture = try makeSamplingFixture(
            device: device,
            roleTiles: [.canonical: colors],
            pixelSize: size,
            addressing: .finite(size),
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: size.width, maxY: 1
            )
        )
        #expect(fixture.planLease.content.batches.count > 1)
        let library = try makeSparseSamplingLibrary(device: device)

        for backend in availableBackends(device) {
            let pipeline = try SparseTileSamplingPipeline.prepare(
                device: device,
                library: library,
                key: key(backend)
            )
            let exactBytes = try expectedAggregateMetalBytes(
                plan: fixture.planLease,
                pipeline: pipeline,
                uploadCapacity: 3
            )
            let exact = SparseTileSamplingGPUPlanCache(
                device: device,
                limits: SparseTileSamplingGPUPlanLimits(
                    maximumDescriptors: 3,
                    maximumPageEntries: 128,
                    maximumBufferBytes: exactBytes
                )
            )
            let exactLease = try await exact.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            let exactSnapshot = await exact.allocationSnapshot
            #expect(
                exactSnapshot.planMetalBufferAllocationBytes
                    + (exactSnapshot.uploadRing?.metalBufferBytes ?? 0)
                    == exactBytes
            )
            try exactLease.complete()

            let oneByteOver = SparseTileSamplingGPUPlanCache(
                device: device,
                limits: SparseTileSamplingGPUPlanLimits(
                    maximumDescriptors: 3,
                    maximumPageEntries: 128,
                    maximumBufferBytes: exactBytes - 1
                )
            )
            do {
                let unexpected = try await oneByteOver.acquire(
                    plan: fixture.planLease,
                    pipeline: pipeline
                )
                try unexpected.complete()
                Issue.record("Expected aggregate byte rejection for \(backend)")
            } catch {
                #expect(error as? SparseTileSamplingPipelineError
                    == .limitExceeded(
                        required: exactBytes,
                        maximum: exactBytes - 1
                    ))
            }
            let rejected = await oneByteOver.allocationSnapshot
            #expect(rejected.planMetalBufferAllocationCount == 0)
            #expect(rejected.uploadRing == nil)
        }

        try fixture.planLease.retire()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test @MainActor
    func revisionChurnCannotGrowTheDefaultGPUPlanCacheWithoutBound()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)

        for revision in 0..<70 {
            let scalar = Float(revision + 1) / 71
            let fixture = try makeSamplingFixture(
                device: device,
                roleColors: [.canonical: SIMD4(scalar, 0, 0, 1)]
            )
            let lease = try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            try fixture.planLease.retire()
            try lease.complete()
            #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
        }

        #expect(await cache.preparedCount <= 64)
    }

    @Test @MainActor
    func lruEvictionBoundsResidentBytesWhileAnEvictedLeaseStaysUsable()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let calibration = try makeSamplingFixture(
            device: device,
            roleColors: [.canonical: SIMD4(0.1, 0, 0, 1)]
        )
        let calibrationCache = SparseTileSamplingGPUPlanCache(device: device)
        let calibrationLease = try await calibrationCache.acquire(
            plan: calibration.planLease,
            pipeline: pipeline
        )
        let calibrationSnapshot = await calibrationCache.allocationSnapshot
        let onePlanBytes = calibrationSnapshot.cachedPlanMetalBufferBytes
        let ringBytes = try #require(
            calibrationSnapshot.uploadRing?.metalBufferBytes
        )
        try calibration.planLease.retire()
        try calibrationLease.complete()

        let maximumResidentBytes = onePlanBytes * 2 + ringBytes
        let cache = SparseTileSamplingGPUPlanCache(
            device: device,
            limits: SparseTileSamplingGPUPlanLimits(
                maximumDescriptors: 3,
                maximumPageEntries: 1_024,
                maximumBufferBytes: 64 * 1_024,
                maximumInflightEncodes: 3,
                maximumCachedPlans: 64,
                maximumCachedBufferBytes: maximumResidentBytes
            )
        )
        let fixtures = try (1...3).map { revision in
            try makeSamplingFixture(
                device: device,
                roleColors: [
                    .canonical: SIMD4(Float(revision) / 4, 0, 0, 1),
                ]
            )
        }
        var leases: [SparseTileSamplingGPUPlanLease] = []
        for fixture in fixtures {
            leases.append(try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            ))
        }
        let bounded = await cache.allocationSnapshot
        #expect(bounded.preparedContentCount == 2)
        #expect(
            bounded.cachedPlanMetalBufferBytes
                + (bounded.uploadRing?.metalBufferBytes ?? 0)
                <= maximumResidentBytes
        )

        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor(usage: [.renderTarget, .shaderRead])
        ))
        let prepared = try SparseTileSamplingEncoder.preflightEncode(
            target: target,
            plan: leases[0],
            parameters: .identity
        )
        for fixture in fixtures { try fixture.planLease.retire() }
        try leases[1].complete()
        try leases[2].complete()
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try prepared.encode(
            commandBuffer: commandBuffer,
            renderPassDescriptor: pass
        )
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        expectClose(readSinglePixel(target), SIMD4(0.25, 0, 0, 1))
        #expect(fixtures.allSatisfy {
            $0.surfaces[0].backingSnapshot().activeLeaseCount == 0
        })
    }

    @Test @MainActor
    func mappedShaderNeighborsOutsideInt32RejectBeforeWorkspaceAllocation()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(Float(Int32.max) + 4_096, 0),
            sourceStep: SIMD2(repeating: 1)
        )
        let fixture = try makeSamplingFixture(
            device: device,
            roleTiles: [.canonical: [
                .init(x: 0, y: 0): SIMD4(0.25, 0.5, 0.75, 1),
            ]],
            pixelSize: PixelSize(width: 256, height: 256),
            addressing: .finite(PixelSize(width: 256, height: 256)),
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputToSourceTransform: transform
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let workspace = WorkspaceAllocationWitness()
        let cache = SparseTileSamplingGPUPlanCache(
            device: device,
            workspaceAllocationObserver: { workspace.record($0) }
        )
        do {
            _ = try await cache.acquire(
                plan: fixture.planLease,
                pipeline: pipeline
            )
            Issue.record("Expected mapped shader range rejection")
        } catch {
            #expect(error as? SparseTileSamplingPipelineError == .byteOverflow)
        }
        #expect(workspace.values.isEmpty)
        try fixture.planLease.retire()
        #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    }

    @Test
    func extremeNegativeBatchOriginUsesCheckedSubtraction() throws {
        let region = try SparseTileOutputRegion(
            minX: Int.min,
            minY: Int.min,
            maxX: Int.min + 1,
            maxY: Int.min + 1
        )
        let geometry = try SparseTileSamplingGeometry.validateBatches([
            SparseTileBindingBatch(
                outputRegion: region,
                globalSlots: [],
                compactRemap: [:]
            ),
        ])
        #expect(geometry.origin == SIMD2(Int.min, Int.min))
        #expect(geometry.size == SIMD2(1, 1))
        let scissor = try SparseTileSamplingGeometry.normalizedScissor(
            region,
            origin: geometry.origin
        )
        #expect(scissor.x == 0)
        #expect(scissor.y == 0)
        #expect(scissor.width == 1)
        #expect(scissor.height == 1)
    }

    @Test @MainActor
    func p4RejectsMoreThanOneLayerBeforePublishingGPUResources() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let first = try makePipelineRequest(
            device: device,
            layerID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            color: SIMD4(1, 0, 0, 1),
            size: size
        )
        let second = try makePipelineRequest(
            device: device,
            layerID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            color: SIMD4(0, 1, 0, 1),
            size: size
        )
        let planKey = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [first, second].map {
                SparseTileLayerContentKey(
                    layerID: $0.surface.layerID,
                    roles: [$0.request.contentKey]
                )
            },
            addressingRevision: 1,
            outputGeometryRevision: 1
        )
        let p3 = try SparseTileSamplingPlanCache().acquire(
            key: planKey,
            sources: [first.request, second.request],
            outputRegion: SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            limits: .pipelineTestDefaults
        )
        let pipeline = try SparseTileSamplingPipeline.prepare(
            device: device,
            library: makeSparseSamplingLibrary(device: device),
            key: key(.directFallback)
        )
        let cache = SparseTileSamplingGPUPlanCache(device: device)
        do {
            _ = try await cache.acquire(plan: p3, pipeline: pipeline)
            Issue.record("P4 must not invent multi-layer semantics")
        } catch {
            #expect(error as? SparseTileSamplingPipelineError
                == .limitExceeded(required: 2, maximum: 1))
        }
        #expect(await cache.preparedCount == 0)
        try p3.retire()
        #expect(first.surface.backingSnapshot().activeLeaseCount == 0)
        #expect(second.surface.backingSnapshot().activeLeaseCount == 0)
    }

    @Test
    func sparsePipelineRemainsProductionInertAndHasNoPerTileDrawLoop() throws {
        let root = repositoryRoot()
        let consumers = [
            "Sources/MetalRenderer/GridRenderer.swift",
            "Sources/MetalRenderer/FlattenedSceneExporter.swift",
            "Sources/MetalRenderer/FiniteCanvasExporter.swift",
            "Sources/MetalRenderer/PeriodicRepeatExporter.swift",
            "Sources/MetalRenderer/PeriodicBakedRepeatExporter.swift",
        ]
        for path in consumers {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(!source.contains("SparseTileSamplingPipeline"))
            #expect(!source.contains("SparseTileSamplingGPUPlanCache"))
        }
        let pipeline = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/Compositing/SparseTileSamplingPipeline.swift"
            ),
            encoding: .utf8
        )
        #expect(pipeline.components(separatedBy: "drawPrimitives(").count - 1 == 2)
        #expect(!pipeline.contains("for tile in"))
        #expect(!pipeline.contains("for entry in"))
        let preflight = try #require(pipeline.range(
            of: "static func preflightEncode("
        )).lowerBound
        let helperBoundary = try #require(pipeline.range(
            of: "private func roleWire("
        )).lowerBound
        let preflightSource = String(pipeline[preflight..<helperBoundary])
        #expect(!preflightSource.contains("makeBuffer("))
        #expect(!pipeline.contains("try? retainedPlan.complete()"))
    }
}

private struct SparseSamplingFixture {
    let surfaces: [TiledRasterSurface]
    let planLease: SparseTileSamplingPlanLease
}

private enum PipelineTestError: Error {
    case injected
}

private final class OneShotLeaseReturnFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func consumeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard shouldFail else { return false }
        shouldFail = false
        return true
    }
}

private final class CountedLeaseReturnFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int

    init(remainingFailures: Int) {
        self.remainingFailures = remainingFailures
    }

    func consumeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else { return false }
        remainingFailures -= 1
        return true
    }
}

private final class WorkspaceAllocationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SparseTileSamplingWorkspaceAllocation] = []

    func record(_ value: SparseTileSamplingWorkspaceAllocation) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [SparseTileSamplingWorkspaceAllocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class MainThreadWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    func record(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct PipelineRequestFixture {
    let surface: TiledRasterSurface
    let request: SparseTileSourceRequest
}

private func makePipelineRequest(
    device: any MTLDevice,
    layerID: UUID,
    color: SIMD4<Float>,
    size: PixelSize
) throws -> PipelineRequestFixture {
    let surface = TiledRasterSurface(
        device: device,
        layerID: layerID,
        pixelSize: size,
        generation: 7,
        byteBudget: PaintTileDescriptor.residentByteCount
    )
    let lease = try surface.reserveTiles(
        at: [.init(x: 0, y: 0)],
        pinReasons: [.dirty]
    )
    try uploadUniformColor(color, to: lease.bindings[0].texture, device: device)
    try surface.markDirty(lease)
    try surface.returnLease(lease)
    let contentKey = SparseTileRoleContentKey(
        role: .canonical,
        contentRevision: surface.revision.rawValue,
        bindingChunkRevision: 1
    )
    return PipelineRequestFixture(
        surface: surface,
        request: try SparseTileSourceRequest(
            contentKey: contentKey,
            addressing: .finite(size),
            surface: surface,
            changedCoordinates: [.init(x: 0, y: 0)],
            disposition: .fullSnapshot
        )
    )
}

@MainActor
private func renderSinglePixel(
    device: any MTLDevice,
    backend: SparseTileSamplingBackend,
    roleColors: [SparseTileSampleRole: SIMD4<Float>],
    parameters: SparseTileSamplingEncodeParameters = .identity
) async throws -> SIMD4<Float> {
    let fixture = try makeSamplingFixture(
        device: device,
        roleColors: roleColors
    )
    let pipeline = try SparseTileSamplingPipeline.prepare(
        device: device,
        library: makeSparseSamplingLibrary(device: device),
        key: key(backend)
    )
    let gpuLease = try await SparseTileSamplingGPUPlanCache(
        device: device
    ).acquire(plan: fixture.planLease, pipeline: pipeline)
    try fixture.planLease.retire()
    let target = try #require(device.makeTexture(
        descriptor: targetDescriptor(usage: [.renderTarget, .shaderRead])
    ))
    let prepared = try SparseTileSamplingEncoder.preflightEncode(
        target: target,
        plan: gpuLease,
        parameters: parameters
    )
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    try prepared.encode(
        commandBuffer: commandBuffer,
        renderPassDescriptor: pass
    )
    await withCheckedContinuation { continuation in
        commandBuffer.addCompletedHandler { _ in continuation.resume() }
        commandBuffer.commit()
    }
    #expect(commandBuffer.status == .completed)
    #expect(commandBuffer.error == nil)
    #expect(fixture.surfaces.allSatisfy {
        $0.backingSnapshot().activeLeaseCount == 0
    })
    return readSinglePixel(target)
}

@MainActor
private func renderSample(
    device: any MTLDevice,
    backend: SparseTileSamplingBackend,
    roleTiles: [SparseTileSampleRole: [PaintTileCoordinate: SIMD4<Float>]],
    pixelSize: PixelSize,
    addressing: SparseTileAddressing,
    point: SIMD2<Double>,
    parameters: SparseTileSamplingEncodeParameters? = nil
) async throws -> SIMD4<Float> {
    let lowerX = Int(floor(point.x - 0.5))
    let lowerY = Int(floor(point.y - 0.5))
    let outputRegion = try SparseTileOutputRegion(
        minX: lowerX,
        minY: lowerY,
        maxX: lowerX + 1,
        maxY: lowerY + 1
    )
    let transform = SparseTileOutputToSourceTransform(
        sourceOffset: SIMD2(
            Float(point.x - Double(lowerX) - 0.5),
            Float(point.y - Double(lowerY) - 0.5)
        ),
        sourceStep: SIMD2(1, 1)
    )
    let fixture = try makeSamplingFixture(
        device: device,
        roleTiles: roleTiles,
        pixelSize: pixelSize,
        addressing: addressing,
        outputRegion: outputRegion,
        outputToSourceTransform: transform
    )
    let pipeline = try SparseTileSamplingPipeline.prepare(
        device: device,
        library: makeSparseSamplingLibrary(device: device),
        key: key(backend)
    )
    let gpuLease = try await SparseTileSamplingGPUPlanCache(
        device: device
    ).acquire(plan: fixture.planLease, pipeline: pipeline)
    try fixture.planLease.retire()
    let target = try #require(device.makeTexture(
        descriptor: targetDescriptor(usage: [.renderTarget, .shaderRead])
    ))
    let resolvedParameters = parameters ?? .init(
        outputToSourceTransform: transform,
        compositeMode: PatternCompositeWireDraw,
        liveVisible: true,
        strokeOpacity: 1,
        accumulationLimit: 1,
        eraserStrength: 1
    )
    let prepared = try SparseTileSamplingEncoder.preflightEncode(
        target: target,
        plan: gpuLease,
        parameters: resolvedParameters
    )
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    try prepared.encode(
        commandBuffer: commandBuffer,
        renderPassDescriptor: pass
    )
    await withCheckedContinuation { continuation in
        commandBuffer.addCompletedHandler { _ in continuation.resume() }
        commandBuffer.commit()
    }
    #expect(commandBuffer.status == .completed)
    #expect(commandBuffer.error == nil)
    #expect(fixture.surfaces.allSatisfy {
        $0.backingSnapshot().activeLeaseCount == 0
    })
    return readSinglePixel(target)
}

@MainActor
private func renderTransformedSinglePixel(
    device: any MTLDevice,
    backend: SparseTileSamplingBackend,
    roleTiles: [SparseTileSampleRole: [PaintTileCoordinate: SIMD4<Float>]],
    pixelSize: PixelSize,
    addressing: SparseTileAddressing,
    transform: SparseTileOutputToSourceTransform
) async throws -> SIMD4<Float> {
    let fixture = try makeSamplingFixture(
        device: device,
        roleTiles: roleTiles,
        pixelSize: pixelSize,
        addressing: addressing,
        outputRegion: SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 1, maxY: 1
        ),
        outputToSourceTransform: transform
    )
    let pipeline = try SparseTileSamplingPipeline.prepare(
        device: device,
        library: makeSparseSamplingLibrary(device: device),
        key: key(backend)
    )
    let lease = try await SparseTileSamplingGPUPlanCache(
        device: device
    ).acquire(plan: fixture.planLease, pipeline: pipeline)
    try fixture.planLease.retire()
    let bits = try await renderPlan(
        device: device,
        plan: lease,
        width: 1,
        height: 1,
        parameters: SparseTileSamplingEncodeParameters(
            outputToSourceTransform: transform,
            compositeMode: PatternCompositeWireDraw,
            liveVisible: true,
            strokeOpacity: 1,
            accumulationLimit: 1,
            eraserStrength: 1
        )
    )
    #expect(fixture.surfaces.allSatisfy {
        $0.backingSnapshot().activeLeaseCount == 0
    })
    return readPixel(bits, x: 0, width: 1)
}

@MainActor
private func renderOpaqueDisplaySinglePixel(
    device: any MTLDevice,
    backend: SparseTileSamplingBackend,
    color: SIMD4<Float>
) async throws -> [UInt8] {
    let fixture = try makeSamplingFixture(
        device: device,
        roleColors: [.canonical: color]
    )
    let pipeline = try SparseTileSamplingPipeline.prepare(
        device: device,
        library: makeSparseSamplingLibrary(device: device),
        key: key(backend, pixelFormat: .bgra8Unorm_srgb)
    )
    let lease = try await SparseTileSamplingGPUPlanCache(
        device: device
    ).acquire(plan: fixture.planLease, pipeline: pipeline)
    let target = try #require(device.makeTexture(
        descriptor: targetDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            usage: [.renderTarget, .shaderRead]
        )
    ))
    let prepared = try SparseTileSamplingEncoder.preflightEncode(
        target: target,
        plan: lease,
        parameters: .identity
    )
    try fixture.planLease.retire()
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    try prepared.encode(
        commandBuffer: commandBuffer,
        renderPassDescriptor: pass
    )
    await withCheckedContinuation { continuation in
        commandBuffer.addCompletedHandler { _ in continuation.resume() }
        commandBuffer.commit()
    }
    #expect(commandBuffer.status == .completed)
    #expect(commandBuffer.error == nil)
    #expect(fixture.surfaces[0].backingSnapshot().activeLeaseCount == 0)
    var bytes = [UInt8](repeating: 0, count: 4)
    target.getBytes(
        &bytes,
        bytesPerRow: 4,
        from: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0
    )
    return bytes
}

private func makeSamplingFixture(
    device: any MTLDevice,
    roleColors: [SparseTileSampleRole: SIMD4<Float>],
    planCache: SparseTileSamplingPlanCache = SparseTileSamplingPlanCache()
) throws -> SparseSamplingFixture {
    let size = PixelSize(width: 256, height: 256)
    return try makeSamplingFixture(
        device: device,
        roleTiles: roleColors.mapValues {
            [.init(x: 0, y: 0): $0]
        },
        pixelSize: size,
        addressing: .finite(size),
        outputRegion: SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 1, maxY: 1
        ),
        outputToSourceTransform: .identity,
        planCache: planCache
    )
}

private func makeSamplingFixture(
    device: any MTLDevice,
    roleTiles: [SparseTileSampleRole: [PaintTileCoordinate: SIMD4<Float>]],
    pixelSize: PixelSize,
    addressing: SparseTileAddressing,
    outputRegion: SparseTileOutputRegion,
    outputToSourceTransform: SparseTileOutputToSourceTransform = .identity,
    planCache: SparseTileSamplingPlanCache = SparseTileSamplingPlanCache()
) throws -> SparseSamplingFixture {
    let layerID = UUID()
    var requests: [SparseTileSourceRequest] = []
    var surfaces: [TiledRasterSurface] = []
    for role in SparseTileSampleRole.allCases where roleTiles[role] != nil {
        let tiles = roleTiles[role]!
        let surface = TiledRasterSurface(
            device: device,
            layerID: layerID,
            pixelSize: pixelSize,
            generation: 7,
            byteBudget: max(1, tiles.count)
                * PaintTileDescriptor.residentByteCount
        )
        let coordinates = tiles.keys.sorted()
        if !coordinates.isEmpty {
            let lease = try surface.reserveTiles(
                at: coordinates,
                pinReasons: [.dirty]
            )
            for binding in lease.bindings {
                try uploadUniformColor(
                    tiles[binding.descriptor.coordinate]!,
                    to: binding.texture,
                    device: device
                )
            }
            try surface.markDirty(lease)
            try surface.returnLease(lease)
        }
        let contentKey = SparseTileRoleContentKey(
            role: role,
            contentRevision: surface.revision.rawValue,
            bindingChunkRevision: 1
        )
        requests.append(try SparseTileSourceRequest(
            contentKey: contentKey,
            addressing: addressing,
            surface: surface,
            changedCoordinates: coordinates,
            disposition: .fullSnapshot
        ))
        surfaces.append(surface)
    }
    let key = SparseTileSamplingPlanKey(
        documentGeneration: 7,
        orderedLayers: [SparseTileLayerContentKey(
            layerID: layerID,
            roles: requests.map(\.contentKey)
        )],
        addressingRevision: 1,
        outputGeometryRevision: 1,
        outputToSourceTransform: outputToSourceTransform
    )
    let planLease = try planCache.acquire(
        key: key,
        sources: requests,
        outputRegion: outputRegion,
        limits: .pipelineTestDefaults
    )
    return SparseSamplingFixture(surfaces: surfaces, planLease: planLease)
}

private func availableBackends(
    _ device: any MTLDevice
) -> [SparseTileSamplingBackend] {
    device.argumentBuffersSupport == .tier2
        ? [.directFallback, .tier2ArgumentBuffer]
        : [.directFallback]
}

private func expectedAggregateMetalBytes(
    plan: SparseTileSamplingPlanLease,
    pipeline: SparseTileSamplingPipelineBinding,
    uploadCapacity: Int
) throws -> Int {
    let descriptorBytes = max(plan.content.pageTables.count, 1)
        * MemoryLayout<PatternSparsePageTableDescriptor>.stride
    let entryCount = plan.content.pageTables.reduce(0) { partial, table in
        partial + table.chunks.reduce(0) { $0 + $1.entries.count }
    }
    let entryBytes = max(entryCount, 1)
        * MemoryLayout<PatternSparseTilePageEntry>.stride
    let backendBytes: Int
    switch pipeline.key.backend {
    case .tier2ArgumentBuffer:
        let argumentEncoder = try pipeline.makeArgumentEncoder()
        backendBytes = max(
            try #require(argumentEncoder).encodedLength,
            1
        )
    case .directFallback:
        let bindingCount = max(
            (plan.content.bindingRecords.map(\.globalSlot).max() ?? -1) + 1,
            1
        )
        backendBytes = plan.content.batches.count
            * bindingCount * MemoryLayout<Int32>.stride
    }
    return descriptorBytes + entryBytes + backendBytes
        + uploadCapacity * 512
}

private func physicalCoordinate(
    _ page: RadialResidentPage,
    layout: RadialSectorLayout
) -> PaintTileCoordinate {
    PaintTileCoordinate(
        x: page.atlasSlot % layout.atlasColumns,
        y: page.atlasSlot / layout.atlasColumns
    )
}

private extension SparseTilePlanLimits {
    static let pipelineTestDefaults = SparseTilePlanLimits(
        maximumPageEntries: 64,
        maximumPageChunks: 16,
        maximumPageTableBytes: 64 * 32,
        maximumBindingSlots: 512,
        maximumBindingChunks: 16,
        maximumBindingBytes: 512 * 64,
        maximumTexturesPerBatch: 16,
        maximumBatchCount: 64
    )
}

private func uploadUniformColor(
    _ color: SIMD4<Float>,
    to texture: any MTLTexture,
    device: any MTLDevice
) throws {
    let texel = [color.x, color.y, color.z, color.w].map {
        Float16($0).bitPattern
    }
    let values = Array(
        repeating: texel,
        count: PaintTileDescriptor.side * PaintTileDescriptor.side
    ).flatMap { $0 }
    let byteCount = values.count * MemoryLayout<UInt16>.stride
    let buffer = try #require(values.withUnsafeBytes {
        device.makeBuffer(bytes: $0.baseAddress!, length: byteCount)
    })
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let blit = try #require(commandBuffer.makeBlitCommandEncoder())
    blit.copy(
        from: buffer,
        sourceOffset: 0,
        sourceBytesPerRow: PaintTileDescriptor.side * 8,
        sourceBytesPerImage: byteCount,
        sourceSize: MTLSize(
            width: PaintTileDescriptor.side,
            height: PaintTileDescriptor.side,
            depth: 1
        ),
        to: texture,
        destinationSlice: 0,
        destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
}

private func targetDescriptor(
    width: Int = 1,
    height: Int = 1,
    pixelFormat: MTLPixelFormat = .rgba16Float,
    usage: MTLTextureUsage
) -> MTLTextureDescriptor {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = usage
    return descriptor
}

private func encodedSRGBByte(_ linear: Float) -> UInt8 {
    let bounded = min(1, max(0, linear))
    let encoded = bounded <= 0.003_130_8
        ? bounded * 12.92
        : 1.055 * pow(bounded, 1 / 2.4) - 0.055
    return UInt8((encoded * 255).rounded())
}

@MainActor
private func renderPlan(
    device: any MTLDevice,
    plan: SparseTileSamplingGPUPlanLease,
    width: Int,
    height: Int,
    parameters: SparseTileSamplingEncodeParameters
) async throws -> [UInt16] {
    let target = try #require(device.makeTexture(
        descriptor: targetDescriptor(
            width: width,
            height: height,
            usage: [.renderTarget, .shaderRead]
        )
    ))
    let prepared = try SparseTileSamplingEncoder.preflightEncode(
        target: target,
        plan: plan,
        parameters: parameters
    )
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    try prepared.encode(
        commandBuffer: commandBuffer,
        renderPassDescriptor: pass
    )
    await withCheckedContinuation { continuation in
        commandBuffer.addCompletedHandler { _ in continuation.resume() }
        commandBuffer.commit()
    }
    #expect(commandBuffer.status == .completed)
    #expect(commandBuffer.error == nil)
    var bits = [UInt16](repeating: 0, count: width * height * 4)
    target.getBytes(
        &bits,
        bytesPerRow: width * 8,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0
    )
    return bits
}

private func readPixel(
    _ bits: [UInt16],
    x: Int,
    y: Int = 0,
    width: Int
) -> SIMD4<Float> {
    let offset = (y * width + x) * 4
    return SIMD4(
        Float(Float16(bitPattern: bits[offset])),
        Float(Float16(bitPattern: bits[offset + 1])),
        Float(Float16(bitPattern: bits[offset + 2])),
        Float(Float16(bitPattern: bits[offset + 3]))
    )
}

private func readSinglePixel(_ texture: any MTLTexture) -> SIMD4<Float> {
    var bits = [UInt16](repeating: 0, count: 4)
    texture.getBytes(
        &bits,
        bytesPerRow: 8,
        from: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0
    )
    return SIMD4(
        Float(Float16(bitPattern: bits[0])),
        Float(Float16(bitPattern: bits[1])),
        Float(Float16(bitPattern: bits[2])),
        Float(Float16(bitPattern: bits[3]))
    )
}

private func expectClose(
    _ actual: SIMD4<Float>,
    _ expected: SIMD4<Float>,
    tolerance: Float = 0.002
) {
    for index in 0..<4 {
        #expect(abs(actual[index] - expected[index]) <= tolerance)
    }
}

private func key(
    _ backend: SparseTileSamplingBackend,
    pixelFormat: MTLPixelFormat = .rgba16Float,
    sampleCount: Int = 1,
    abiVersion: UInt16 = SparseSamplingABI.version
) -> SparseTileSamplingPipelineKey {
    SparseTileSamplingPipelineKey(
        backend: backend,
        outputPixelFormatRawValue: pixelFormat.rawValue,
        sampleCount: sampleCount,
        abiVersion: abiVersion
    )
}

private func makeSparseSamplingLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    return try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
