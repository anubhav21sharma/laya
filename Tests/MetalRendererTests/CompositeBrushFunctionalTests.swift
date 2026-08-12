import BrushFormat
import Foundation
import Metal
@testable import MetalRenderer
@testable import MetalRendererDiagnostics
import PatternEngine
import Testing

@Suite("Composite brush functional acceptance", .serialized)
@MainActor
struct CompositeBrushFunctionalTests {
    @Test
    func projectFixtureCompilesMaximumComponentsAndSharesResidency()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup(
            pixelSize: PixelSize(width: 128, height: 128)
        ) else { return }
        let package = try DepositionHarnessFixtures.compositePackage()
        let compiled = try await setup.compiler.compileAndActivate(
            package: package
        )

        #expect(package.definition.components.count == 2)
        #expect(compiled.primaryComponent.ordinal == 0)
        #expect(compiled.secondaryComponent?.ordinal == 1)
        #expect(compiled.report.performance.tier == .realtime60)
        #expect(compiled.residentByteCount > 0)
        #expect(
            compiled.residentByteCount
                == compiled.report.residentResourceBytes
        )
        let primaryShared = try #require(
            compiled.primaryComponent.textures[
                DepositionHarnessFixtures.compositeSharedGrainID
            ]
        )
        let secondaryShared = try #require(
            compiled.secondaryComponent?.textures[
                DepositionHarnessFixtures.compositeSharedGrainID
            ]
        )
        #expect(
            ObjectIdentifier(primaryShared as AnyObject)
                == ObjectIdentifier(secondaryShared as AnyObject)
        )
    }

    @Test
    func compositeRasterIsDeterministicOrderedAndBothComponentsContribute()
        async throws
    {
        let package = try DepositionHarnessFixtures.compositePackage()
        let first = try await render(package, token: 18_001)
        let repeated = try await render(package, token: 18_002)
        let swapped = try await render(
            try reorderingComponents(package),
            token: 18_003
        )
        let withoutPrimary = try await render(
            try disablingComponent(0, in: package),
            token: 18_004
        )
        let withoutSecondary = try await render(
            try disablingComponent(1, in: package),
            token: 18_005
        )
        let digest = DepositionSceneEvidence.sha256(first)

        #expect(first == repeated)
        #expect(first != swapped)
        #expect(first != withoutPrimary)
        #expect(first != withoutSecondary)
        #expect(withoutPrimary != withoutSecondary)
        #expect(
            digest
                == "d67503cf503d715f0a626c5de3e0e6a9895a30c222bf9fa3a33dce890fd3d2f8"
        )
    }

    @Test
    func componentFlowAccumulationLimitsMatchOrderedCPUOracle()
        async throws
    {
        let limits: [Float] = [0.75, 0.25]
        let strokeAlpha: Float = 0.86
        let package = try analyticAccumulationPackage(
            accumulationLimits: limits
        )
        let pixels = try await renderStationary(
            package,
            token: 18_010,
            alpha: strokeAlpha
        )
        var expectedCoverage: Float = 0
        for limit in limits {
            let componentCoverage = DepositionReference.accumulateAlpha(
                current: 0,
                baseCoverage: 1,
                flowCoverage: 1,
                mode: .flow,
                accumulationLimit: limit
            )
            expectedCoverage += (1 - expectedCoverage) * componentCoverage
        }
        let expectedByte = Int(
            (expectedCoverage * strokeAlpha * 255).rounded()
        )
        let actualByte = Int(maximumAlpha(pixels))

        #expect(
            abs(actualByte - expectedByte) <= 1,
            "actual=\(actualByte) expected=\(expectedByte)"
        )
        #expect(actualByte > Int((limits[0] * strokeAlpha * 255).rounded()))
    }

    @Test
    func cursorUnionCoversRasterSupportAndEverySymmetryTransform()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup(
            pixelSize: PixelSize(width: 128, height: 128)
        ) else { return }
        let package = try DepositionHarnessFixtures.compositePackage()
        let compiled = try await setup.compiler.compileAndActivate(
            package: package
        )
        let input = try BrushCursorInput(
            nominalDiameter: 20,
            pressure: nil,
            altitude: nil,
            azimuth: nil,
            roll: nil,
            tangentialPressure: nil,
            direction: 0,
            deformation: .identity,
            viewportScale: 1,
            backingScale: 1
        )
        let cursor = try compiled.cursorDescriptor(input: input)
        let sample = compositeWorldSample(.began, x: 64, y: 64)
        var generator = BrushStrokeGenerator(
            program: compiled.program,
            nominalDiameter: 20,
            color: .black,
            seed: 18
        )
        let dabs = try generator.currentSampleDabs(sample)

        #expect(dabs.map(\.componentOrdinal) == [0, 1])
        #expect(cursor.secondaryComponent != nil)
        for dab in dabs {
            let relativeMinimum = dab.worldBounds.minimum - sample.position.simd
            let relativeMaximum = dab.worldBounds.maximum - sample.position.simd
            let tolerance: Float = 0.000_01
            #expect(
                cursor.envelopeBounds.minimum.x
                    <= relativeMinimum.x + tolerance
            )
            #expect(
                cursor.envelopeBounds.minimum.y
                    <= relativeMinimum.y + tolerance
            )
            #expect(
                cursor.envelopeBounds.maximum.x
                    >= relativeMaximum.x - tolerance
            )
            #expect(
                cursor.envelopeBounds.maximum.y
                    >= relativeMaximum.y - tolerance
            )
        }
        let secondaryEnvelope = try #require(
            cursor.secondaryComponent?.envelopeBounds
        )
        let primaryEnvelope = try #require(
            cursor.primaryComponent.envelopeBounds
        )
        #expect(
            primaryEnvelope.minimum != cursor.envelopeBounds.minimum
                || primaryEnvelope.maximum != cursor.envelopeBounds.maximum
        )
        #expect(
            secondaryEnvelope.minimum != cursor.envelopeBounds.minimum
                || secondaryEnvelope.maximum != cursor.envelopeBounds.maximum
        )

        let canvas = PixelSize(width: 128, height: 128)
        let strategies = try [
            TilingStrategy(
                finiteConfiguration: .plain,
                canvasSize: canvas
            ),
            TilingStrategy(kind: .grid, tileSize: PatternSize(
                width: 128,
                height: 128
            )),
            TilingStrategy(kind: .squareKaleidoscope, tileSize: PatternSize(
                width: 128,
                height: 128
            )),
            TilingStrategy(
                finiteConfiguration: .radial(
                    RadialSymmetryConfiguration(
                        kind: .rotation,
                        rayCount: 7,
                        center: WorldPoint(x: 64, y: 64)
                    )
                ),
                canvasSize: canvas
            ),
            TilingStrategy(
                finiteConfiguration: .radial(
                    RadialSymmetryConfiguration(
                        kind: .mandala,
                        rayCount: SymmetryDescriptorCompiler
                            .maximumRadialRayCount,
                        center: WorldPoint(x: 64, y: 64)
                    )
                ),
                canvasSize: canvas
            ),
        ]
        for strategy in strategies {
            for dab in dabs {
                let fragments = TilingProjection.fragments(
                    for: StampFootprint(
                        brushToWorld: dab.brushToWorld,
                        localBounds: TilingProjection
                            .depositionSupportLocalBounds(radius: dab.radius),
                        coverageSymmetry: .oriented
                    ),
                    using: strategy
                )
                #expect(!fragments.isEmpty)
                #expect(
                    fragments.count
                        <= TransientStrokeBufferContract
                            .visibleEpochProjectedInstanceCapacity
                )
            }
        }

        let draw = depositionStyle(compiled, compositeMode: .draw)
        let erase = depositionStyle(compiled, compositeMode: .erase)
        var drawGenerator = BrushStrokeGenerator(
            program: draw.program,
            nominalDiameter: draw.diameter,
            color: draw.color,
            seed: draw.seed
        )
        var eraseGenerator = BrushStrokeGenerator(
            program: erase.program,
            nominalDiameter: erase.diameter,
            color: erase.color,
            seed: erase.seed
        )
        #expect(
            try drawGenerator.currentSampleDabs(sample)
                == eraseGenerator.currentSampleDabs(sample)
        )
    }

    @Test
    func compositeDrawAndEraseRasterizeAcrossEveryTransformFamily()
        async throws
    {
        let canvas = PixelSize(width: 128, height: 128)
        let configurations: [(String, TilingKind?, FiniteSymmetryConfiguration?)] = [
            ("plain", nil, .plain),
            ("periodic", .grid, nil),
            ("reflected", .squareKaleidoscope, nil),
            (
                "radial-max",
                nil,
                .radial(RadialSymmetryConfiguration(
                    kind: .mandala,
                    rayCount: SymmetryDescriptorCompiler.maximumRadialRayCount,
                    center: WorldPoint(x: 64, y: 64)
                ))
            ),
        ]
        var drawDigests = Set<String>()
        for (index, configuration) in configurations.enumerated() {
            guard let setup = try makeDepositionRendererSetup(
                tiling: configuration.1 ?? .grid,
                finite: configuration.2,
                pixelSize: canvas
            ) else { return }
            let compiled = try await setup.compiler.compileAndActivate(
                package: DepositionHarnessFixtures.compositePackage()
            )
            try setup.renderer.activateDrawBrush(compiled)
            try await commit(
                renderer: setup.renderer,
                brush: compiled,
                token: RendererOperationToken(
                    rawValue: UInt64(18_020 + index * 2)
                )
            )
            let drawn = try await committedBytes(setup.renderer)
            let drawnAlpha = alphaSum(drawn)
            #expect(drawnAlpha > 0, Comment(rawValue: configuration.0))
            drawDigests.insert(DepositionSceneEvidence.sha256(drawn))

            try setup.renderer.activateEraserBrush(compiled)
            try await commit(
                renderer: setup.renderer,
                brush: compiled,
                token: RendererOperationToken(
                    rawValue: UInt64(18_021 + index * 2)
                ),
                compositeMode: .erase
            )
            let erased = try await committedBytes(setup.renderer)
            #expect(
                alphaSum(erased) < drawnAlpha,
                Comment(rawValue: configuration.0)
            )
        }
        #expect(drawDigests.count >= 3)
    }

    @Test
    func compositeHistoryRestoresExactCanonicalPixels() async throws {
        guard let setup = try makeDepositionRendererSetup(
            pixelSize: PixelSize(width: 128, height: 128)
        ) else { return }
        let compiled = try await setup.compiler.compileAndActivate(
            package: DepositionHarnessFixtures.compositePackage()
        )
        try setup.renderer.activateDrawBrush(compiled)
        let before = try await committedBytes(setup.renderer)
        var receipt: RasterMutationReceipt?
        setup.renderer.onOperationCompleted = { completion in
            if case let .rasterSuccess(value) = completion {
                receipt = value
            }
        }

        try await commit(
            renderer: setup.renderer,
            brush: compiled,
            token: RendererOperationToken(rawValue: 18_006)
        )
        let after = try await committedBytes(setup.renderer)
        let history = try #require(receipt)
        #expect(after != before)

        try await setup.renderer.restoreDocumentRevision(
            token: RendererOperationToken(rawValue: 18_007),
            revision: history.before
        )
        #expect(try await committedBytes(setup.renderer) == before)
        try await setup.renderer.restoreDocumentRevision(
            token: RendererOperationToken(rawValue: 18_008),
            revision: history.after
        )
        #expect(try await committedBytes(setup.renderer) == after)
        try await setup.renderer.releasePaintRevisions([
            history.before.id,
            history.after.id,
        ])
    }
}

@MainActor
private func render(
    _ package: BrushPackage,
    token: UInt64
) async throws -> [UInt8] {
    guard let setup = try makeDepositionRendererSetup(
        pixelSize: PixelSize(width: 128, height: 128)
    ) else { return [] }
    let compiled = try await setup.compiler.compileAndActivate(
        package: package
    )
    try setup.renderer.activateDrawBrush(compiled)
    try await commit(
        renderer: setup.renderer,
        brush: compiled,
        token: RendererOperationToken(rawValue: token)
    )
    return try await committedBytes(setup.renderer)
}

@MainActor
private func renderStationary(
    _ package: BrushPackage,
    token: UInt64,
    alpha: Float
) async throws -> [UInt8] {
    guard let setup = try makeDepositionRendererSetup(
        pixelSize: PixelSize(width: 128, height: 128)
    ) else { return [] }
    let compiled = try await setup.compiler.compileAndActivate(
        package: package
    )
    try setup.renderer.activateDrawBrush(compiled)
    let operation = RendererOperationToken(rawValue: token)
    let color = try #require(InkColor(
        red: 0.82,
        green: 0.38,
        blue: 0.16,
        alpha: alpha
    ))
    try setup.renderer.beginStroke(
        token: operation,
        sample: depositionSample(.began, x: 64, y: 64),
        style: depositionStyle(
            compiled,
            compositeMode: .draw,
            diameter: 24,
            color: color
        )
    )
    try setup.renderer.requestStrokeCommit(
        token: operation,
        sample: depositionSample(.ended, x: 64, y: 64)
    )
    _ = try await setup.renderer.finishCommitForHarness()
    return try await committedBytes(setup.renderer)
}

@MainActor
private func commit(
    renderer: GridRenderer,
    brush: CompiledBrush,
    token: RendererOperationToken,
    compositeMode: StrokeCompositeMode = .draw
) async throws {
    try renderer.beginStroke(
        token: token,
        sample: depositionSample(.began, x: 20, y: 64),
        style: depositionStyle(
            brush,
            compositeMode: compositeMode,
            diameter: 24,
            color: InkColor(
                red: 0.82,
                green: 0.38,
                blue: 0.16,
                alpha: 0.86
            )!
        )
    )
    try renderer.appendStroke(
        token: token,
        sample: depositionSample(.moved, x: 72, y: 58)
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: depositionSample(.ended, x: 108, y: 68)
    )
    _ = try await renderer.finishCommitForHarness()
}

private func alphaSum(_ pixels: [UInt8]) -> UInt64 {
    stride(from: 3, to: pixels.count, by: 4).reduce(0) {
        $0 + UInt64(pixels[$1])
    }
}

@MainActor
private func committedBytes(_ renderer: GridRenderer) async throws
    -> [UInt8]
{
    let snapshot = try await renderer.captureCommittedDocument()
    return switch snapshot.storage {
    case let .singleRaster(bytes): bytes
    case let .radialPages(pages):
        pages.flatMap(\.bgra8PremultipliedBytes)
    }
}

private func compositeWorldSample(
    _ phase: StrokePhase,
    x: Float,
    y: Float
) -> WorldStrokeSample {
    var deriver = BrushInputDeriver()
    return deriver.derive(
        depositionSample(phase, x: x, y: y),
        viewport: ViewportTransform(
            drawableSize: PatternSize(width: 128, height: 128),
            worldCenter: WorldPoint(x: 64, y: 64)
        )
    )
}

private func maximumAlpha(_ pixels: [UInt8]) -> UInt8 {
    stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
}

private func analyticAccumulationPackage(
    accumulationLimits: [Float]
) throws -> BrushPackage {
    precondition(accumulationLimits.count == 2)
    let base = try DepositionHarnessFixtures.compositePackage().definition
    let inherited = base.components[0]
    var outputs = inherited.sensorProgram.outputs
    for output in [
        BrushDynamicOutput.size,
        .flow,
        .opacity,
        .spacing,
        .hardness,
        .grain,
    ] {
        outputs[output] = BrushOutputProgramDefinition(
            baseValue: 1,
            terms: []
        )
    }
    func component(
        ordinal: UInt8,
        accumulationLimit: Float
    ) -> BrushComponentDefinition {
        BrushComponentDefinition(
            identifier: BrushComponentIdentifier("glaze-\(ordinal)"),
            ordinal: ordinal,
            resources: [],
            coverage: BrushCoverageDefinition(
                shapes: [BrushShapeLayerDefinition(
                    shape: .hardRound,
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                )],
                grains: [],
                baseHardness: 1,
                aspectRatio: 1,
                tipThreshold: 0,
                antialiasing: true
            ),
            placement: BrushPlacementDefinition(
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.25,
                baseFlow: 1,
                strokeOpacity: 1,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            dynamics: inherited.dynamics,
            color: BrushColorBehaviorDefinition(
                baseAdjustment: .identity,
                perStampJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                ),
                perStrokeJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                )
            ),
            material: BrushMaterialDefinition(
                accumulation: .flow,
                interaction: .none,
                edgeTreatment: .none,
                strength: 1,
                wetness: 0,
                bleedRadius: 0,
                softenPasses: 0,
                accumulationLimit: accumulationLimit,
                interactionParameters: nil
            ),
            taper: .none,
            sensorProgram: BrushSensorProgramDefinition(outputs: outputs),
            emission: BrushEmissionDefinition(
                mode: .distance,
                timeInterval: nil
            ),
            tipSupports: [.analyticEllipse]
        )
    }
    let definition = try BrushDefinition(
        id: BrushRecipeID("test.composite.glaze-materials"),
        metadata: BrushMetadata(displayName: "Composite glaze materials"),
        capabilities: [],
        composition: .orderedSourceOver,
        components: [
            component(ordinal: 0, accumulationLimit: accumulationLimits[0]),
            component(ordinal: 1, accumulationLimit: accumulationLimits[1]),
        ],
        stabilization: base.stabilization,
        replayMode: .appendOnly,
        replayLimits: nil,
        termination: base.termination,
        seedPolicy: .fixed(18_010),
        limits: base.limits,
        performanceIntent: .realtime120,
        compatibility: BrushCompatibilityMetadata(
            sourceSettingKeys: [],
            requiredSemanticKeys: []
        ),
        sensorNormalization: base.sensorNormalization,
        stabilizationV2: base.stabilizationV2,
        direction: base.direction
    )
    return try BrushPackage(
        manifest: BrushPackageManifest(resources: []),
        definition: definition,
        resourceData: [:]
    )
}

private func disablingComponent(
    _ ordinal: UInt8,
    in package: BrushPackage
) throws -> BrushPackage {
    try replacingComponents(
        package.definition.components.map {
            copiedComponent($0, ordinal: $0.ordinal, disabled: $0.ordinal == ordinal)
        },
        in: package
    )
}

private func reorderingComponents(
    _ package: BrushPackage
) throws -> BrushPackage {
    let components = package.definition.components
    return try replacingComponents([
        copiedComponent(components[1], ordinal: 0, disabled: false),
        copiedComponent(components[0], ordinal: 1, disabled: false),
    ], in: package)
}

private func copiedComponent(
    _ component: BrushComponentDefinition,
    ordinal: UInt8,
    disabled: Bool
) -> BrushComponentDefinition {
    var outputs = component.sensorProgram.outputs
    if disabled {
        outputs[.flow] = BrushOutputProgramDefinition(
            baseValue: 0,
            terms: []
        )
    }
    return BrushComponentDefinition(
        identifier: component.identifier,
        ordinal: ordinal,
        resources: component.resources,
        coverage: component.coverage,
        placement: BrushPlacementDefinition(
            baseSpacingFraction: component.placement.baseSpacingFraction,
            maximumSpacingFraction:
                component.placement.maximumSpacingFraction,
            baseFlow: disabled ? 0 : component.placement.baseFlow,
            strokeOpacity: component.placement.strokeOpacity,
            baseScatterFraction: component.placement.baseScatterFraction,
            baseRotation: component.placement.baseRotation,
            baseJitterFraction: component.placement.baseJitterFraction,
            baseOffset: component.placement.baseOffset
        ),
        dynamics: component.dynamics,
        color: component.color,
        material: component.material,
        taper: component.taper,
        sensorProgram: BrushSensorProgramDefinition(outputs: outputs),
        emission: component.emission,
        tipSupports: component.tipSupports
    )
}

private func replacingComponents(
    _ components: [BrushComponentDefinition],
    in package: BrushPackage
) throws -> BrushPackage {
    let base = package.definition
    let definition = try BrushDefinition(
        id: base.id,
        metadata: base.metadata,
        capabilities: base.capabilities,
        composition: base.composition,
        components: components,
        stabilization: base.stabilization,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: base.termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility,
        sensorNormalization: base.sensorNormalization,
        stabilizationV2: base.stabilizationV2,
        direction: base.direction
    )
    return try BrushPackage(
        manifest: package.manifest,
        definition: definition,
        resourceData: package.resourceData
    )
}
