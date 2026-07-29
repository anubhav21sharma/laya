#if DEBUG
import BrushConverter
import BrushFormat
import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Brush Lab session", .serialized)
@MainActor
struct BrushLabSessionTests {
    @Test
    func fixedManualCardMatrixCoversEveryAnchorAndRequiredDimension() {
        let cards = BrushLabManualCard.fixedMatrix
        let anchorIDs = Set(AnchorBrushCatalog.all.map(\.id.rawValue))

        #expect(cards.count == 72)
        #expect(cards.map(\.cardID) == cards.map(\.cardID).sorted())
        #expect(Set(cards.map(\.cardID)).count == cards.count)
        #expect(Set(cards.map(\.brushID)) == anchorIDs)

        for anchorID in anchorIDs {
            let anchorCards = cards.filter { $0.brushID == anchorID }
            #expect(anchorCards.count == 12)
            #expect(Set(anchorCards.map(\.gesture)) == Set(
                BrushLabManualGesture.allCases
            ))
            #expect(Set(anchorCards.map(\.diameter)) == [2, 20, 2_000])
            #expect(Set(anchorCards.map(\.pressureProfile)) == [
                "high",
                "low",
                "medium",
            ])
            #expect(Set(anchorCards.map(\.documentMode)) == [
                "finite-radial",
                "periodic",
                "plain",
                "reflected",
            ])
            #expect(Set(anchorCards.map(\.background)) == [
                .opaque,
                .transparent,
            ])
            #expect(Set(anchorCards.map(\.predictionEnabled)) == [
                false,
                true,
            ])
            #expect(anchorCards.contains {
                $0.inputCapabilities == [
                    "pressure",
                    "altitude",
                    "azimuth",
                    "roll",
                ]
            })
            #expect(anchorCards.contains {
                $0.customResourceFixture
                    == "custom-asymmetric-shape-grain-v1"
            })
        }
    }

    @Test
    func freshSessionsProduceByteIdenticalManualCardJSON() throws {
        guard let first = try makeRuntime(),
              let second = try makeRuntime()
        else {
            return
        }

        let firstData = try first.session.makeManualCardsData()
        let secondData = try second.session.makeManualCardsData()

        #expect(firstData == secondData)
        #expect(
            BrushContentHash.sha256Hex(of: firstData)
                == "cabfd2d0fb1f6007fef745ca7e1480e9906f45f6f2361a2f8568874b2432d3e2"
        )
    }

    @Test
    func manualAssessmentsStartUnsetAndNeverSelfApprove() {
        let assessment = BrushLabManualAssessment(
            cardID: "builtin.native-ink.tap.minimum.low"
        )

        #expect(assessment.responsiveness == nil)
        #expect(assessment.edgeQuality == nil)
        #expect(assessment.textureCohesion == nil)
        #expect(assessment.buildup == nil)
        #expect(assessment.symmetryBehavior == nil)
        #expect(assessment.eraserMatch == nil)
        #expect(assessment.notes == nil)
    }

    @Test
    func selectsAndReplaysManualCardThroughProductionController()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.gesture == .tap
                && $0.documentMode == "periodic"
                && $0.predictionEnabled
                && $0.customResourceFixture == nil
        })

        try await runtime.session.selectManualCard(card.cardID)
        try runtime.session.replaySelectedManualCard()
        _ = try runtime.controller.renderer.finishCommitForHarness()

        #expect(runtime.session.selectedManualCardID == card.cardID)
        #expect(runtime.session.package?.definition.id.rawValue == card.brushID)
        #expect(runtime.controller.model.brushDiameter == card.diameter)
        #expect(runtime.controller.model.inkColor == card.paintColor)
        #expect(runtime.session.inputRecords == card.traceSamples().enumerated()
            .map { BrushLabInputRecord(sequence: $0.offset, sample: $0.element) })
        #expect(runtime.session.inputRecords.contains {
            $0.kind == "predicted"
        })
        #expect(!runtime.session.dabRecords.isEmpty)
        #expect(runtime.controller.renderer.isIdle)
        #expect(
            runtime.session.compiledBrush?.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
    }

    @Test
    func manualEvidenceArchiveWritesJSONPNGsAndTelemetryAtomically()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.gesture == .fastLine
                && $0.documentMode == "plain"
                && !$0.predictionEnabled
        })
        try await runtime.session.selectManualCard(card.cardID)
        try runtime.session.replaySelectedManualCard()
        _ = try runtime.controller.renderer.finishCommitForHarness()

        let archive = try runtime.session.makeManualEvidenceArchive()
        #expect(Set(archive.files.keys) == [
            "canvas.png",
            "evidence.json",
            "telemetry.json",
        ])
        #expect(archive.files["canvas.png"]?.prefix(8) == Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ]))

        let evidence = try #require(archive.files["evidence.json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        #expect(object["cardID"] as? String == card.cardID)
        let assessment = try #require(
            object["assessment"] as? [String: Any]
        )
        #expect(assessment["responsiveness"] is NSNull)
        #expect(assessment["edgeQuality"] is NSNull)
        let identity = try #require(
            object["renderIdentity"] as? [String: Any]
        )
        #expect(
            identity["semanticHash"] as? String
                == runtime.session.packageContentHash
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "laya-brush-lab-archive-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let destination = root.appendingPathComponent(
            "card.brushlabevidence",
            isDirectory: true
        )
        try archive.writeAtomically(to: destination)
        #expect(
            Set(
                try FileManager.default.contentsOfDirectory(
                    atPath: destination.path
                )
            ) == Set(archive.files.keys)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ).allSatisfy { !$0.hasPrefix(".card.brushlabevidence.tmp-") }
        )
    }

    @Test
    func customAsymmetricCardCompilesRealShapeAndGrainResources()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.customResourceFixture
                    == BrushLabManualCard.customAsymmetricFixture
                && $0.documentMode == "plain"
        })

        try await runtime.session.selectManualCard(card.cardID)

        #expect(
            Set(runtime.session.compiledBrush.map {
                Array($0.textures.keys)
            } ?? []) == [
                "brush-lab.custom-asymmetric.grain",
                "brush-lab.custom-asymmetric.shape",
            ]
        )
        #expect(runtime.session.package?.manifest.resources.count == 2)
        #expect(runtime.session.compilationReport?.residentResourceBytes ?? 0 > 0)
        #expect(
            runtime.session.compiledBrush?.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
    }

    @Test
    func loadsCompilesTracesAndExportsWithoutUIInteraction() async throws {
        guard let runtime = try makeRuntime() else { return }
        let package = try makePackage()

        await runtime.session.loadPackage(
            package,
            sourceName: "fixture.layabrush"
        )

        #expect(try runtime.session.packageContentHash == (package.contentHash))
        #expect(runtime.session.compilationReport != nil)
        #expect(runtime.session.drawingAvailability == .available)
        #expect(
            runtime.session.activeDrawingPackageContentHash
                == runtime.session.packageContentHash
        )
        #expect(runtime.session.settingGroups.count >= 5)

        let began = StrokeSample.mouse(
            position: ScreenPoint(x: 24, y: 24),
            timestamp: 1,
            phase: .began
        )
        runtime.controller.handleStrokeSample(began)
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 2,
                phase: .cancelled
            )
        )

        #expect(runtime.session.inputRecords.count == 2)
        #expect(!runtime.session.dabRecords.isEmpty)
        let evidence = try runtime.session.makeEvidenceData()
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["package"] != nil)
        #expect(object["trace"] != nil)
        #expect(object["renderer"] != nil)
        let canvas = try #require(object["canvas"] as? [String: Any])
        let encodedPixels = try #require(
            canvas["singleRasterBGRA8Base64"] as? String
        )
        #expect(!encodedPixels.isEmpty)
        let compiler = try #require(object["compiler"] as? [String: Any])
        #expect((compiler["cacheBudgetBytes"] as? Int) ?? 0 > 0)
    }

    @Test
    func loadsConvertedPackageAndReportFromDiskWithoutUI() async throws {
        guard let runtime = try makeRuntime() else { return }
        let source = try SyntheticV1DiagnosticFixture.source(
            includeWet: false
        )
        let document = try #require(
            SyntheticV1BrushParser().parse(source).first
        )
        let mapped = try SyntheticV1BrushMapper().map(document)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "laya-brush-lab-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let packageURL = directory.appendingPathComponent(
            "converted.layabrush"
        )
        try BrushPackageIO.save(mapped.package, to: packageURL)

        await runtime.session.loadPackage(at: packageURL)

        #expect(runtime.session.errorMessage == nil)
        #expect(runtime.session.sourceName == "converted.layabrush")
        #expect(runtime.session.package?.manifest.schemaVersion == 2)
        #expect(runtime.session.package?.conversionReport == mapped.report)
        #expect(runtime.session.drawingAvailability == .available)
        let compiled = try #require(runtime.session.compiledBrush)
        #expect(Set(compiled.textures.keys) == [
            "grain.synthetic",
            "shape.synthetic",
        ])
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 1,
                phase: .began
            )
        )
        let activeStyle = try #require(
            runtime.controller.renderer.harnessActiveStrokeStyle
        )
        #expect(activeStyle.renderIdentity == compiled.renderIdentity)
        #expect(
            activeStyle.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 2,
                phase: .cancelled
            )
        )
        let evidence = try runtime.session.makeEvidenceData()
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        let conversion = try #require(
            object["conversion"] as? [String: Any]
        )
        #expect(conversion["sourceFormat"] as? String == "synthetic")
        #expect(
            conversion["sourceContentHash"] as? String
                == mapped.report.sourceContentHash
        )
    }

    @Test
    func nativeOnlyProgramCompilesButIsNotSilentlyApproximated() async throws {
        guard let runtime = try makeRuntime() else { return }
        await runtime.session.loadPackage(
            try makePackage(),
            sourceName: "compatible.layabrush"
        )
        try await runtime.session.loadPackage(
            makePackage(nativeOnly: true),
            sourceName: "native-only.layabrush"
        )

        #expect(runtime.session.compilationReport != nil)
        #expect(
            runtime.session.drawingAvailability == .available
        )
        #expect(
            runtime.session.activeDrawingPackageContentHash
                == runtime.session.packageContentHash
        )
        #expect(
            runtime.session.compiledBrush?.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
        let compiled = try #require(runtime.session.compiledBrush)
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 1,
                phase: .began
            )
        )
        let activeStyle = try #require(
            runtime.controller.renderer.harnessActiveStrokeStyle
        )
        #expect(
            activeStyle.renderIdentity
                == compiled.renderIdentity
        )
        #expect(
            activeStyle.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 2,
                phase: .cancelled
            )
        )
    }

    @Test
    func wetPackageRemainsInspectableWithTypedUnsupportedAvailability()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }

        await runtime.session.loadPackage(
            try makePackage(wet: true),
            sourceName: "wet.layabrush"
        )

        #expect(runtime.session.compilationReport?.backend == .canvasInteraction)
        #expect(
            runtime.session.drawingAvailability == .unsupportedInteraction(.wetMix)
        )
        #expect(runtime.session.compilationFailure == nil)
        #expect(runtime.session.compiledBrush == nil)
    }

    private func makeRuntime() throws -> (
        controller: EditorSessionController,
        session: BrushLabSession
    )? {
        guard let renderer = try makeControllerRenderer(),
              let queue = renderer.device.makeCommandQueue()
        else {
            return nil
        }
        let controller = EditorSessionController(renderer: renderer)
        let compiler = try BrushCompiler(
            device: renderer.device,
            commandQueue: queue,
            profile: BrushDeviceProfile(
                registryID: renderer.device.registryID,
                recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 4_096,
                brushCacheBudgetBytes: 128 * 1_024 * 1_024,
                targetFramesPerSecond: 120
            ),
            pipelineLibrary: try makeNativeDepositionPipelineLibrary(
                device: renderer.device
            )
        )
        return (
            controller,
            BrushLabSession(controller: controller, compiler: compiler)
        )
    }

    private func makePackage(
        nativeOnly: Bool = false,
        wet: Bool = false
    ) throws
        -> BrushPackage
    {
        let base = try LegacyBrushRecipeAdapter.definition(
            from: BrushRecipe(id: BrushRecipeID("brush-lab.fixture")),
            displayName: "Brush Lab Fixture"
        )
        let definition: BrushDefinition
        if nativeOnly || wet {
            let material = wet ? BrushMaterialDefinition(
                accumulation: base.material.accumulation,
                interaction: .wetMix,
                edgeTreatment: base.material.edgeTreatment,
                strength: base.material.strength,
                wetness: base.material.wetness,
                bleedRadius: base.material.bleedRadius,
                softenPasses: base.material.softenPasses,
                accumulationLimit: base.material.accumulationLimit,
                interactionParameters: BrushInteractionDefinition(
                    pickup: 0.2, pull: 0.4, dilution: 0.3, charge: 0.4,
                    persistence: 0.5, dirtyHaloRadius: 2
                )
            ) : base.material
            definition = try BrushDefinition(
                id: base.id,
                schemaVersion: base.schemaVersion,
                metadata: base.metadata,
                capabilities: wet ? [BrushCapabilityDeclaration(
                    identifier: BrushCapability.wetMix.rawValue,
                    required: true
                )] : base.capabilities,
                resources: base.resources,
                coverage: base.coverage,
                placement: base.placement,
                dynamics: base.dynamics,
                color: base.color,
                material: material,
                stabilization: base.stabilization,
                taper: base.taper,
                replayMode: base.replayMode,
                replayLimits: base.replayLimits,
                seedPolicy: base.seedPolicy,
                limits: base.limits,
                performanceIntent: .quality,
                compatibility: base.compatibility
            )
        } else {
            definition = base
        }
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: definition,
            resourceData: [:]
        )
    }

    private func rendererProgram(
        _ controller: EditorSessionController
    ) -> BrushProgram? {
        controller.renderer.harnessActiveStrokeStyle?.program
    }
}

@MainActor
final class BrushLabTestPipelinePreparer:
    DepositionPipelinePreparing
{
    private let state: any MTLRenderPipelineState
    private var bindings:
        [DepositionPipelineKey: DepositionPipelineBinding] = [:]

    init(device: any MTLDevice) throws {
        state = try makeBrushLabTestPipelineState(device: device)
    }

    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        if let binding = bindings[key] {
            return binding
        }
        let binding = DepositionPipelineBinding(key: key, state: state)
        bindings[key] = binding
        return binding
    }
}

@MainActor
func makeBrushLabTestPipelineState(
    device: any MTLDevice
) throws -> any MTLRenderPipelineState {
    let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 brushLabCompilerVertex(uint id [[vertex_id]]) {
            const float2 points[3] = {
                float2(-1, -1), float2(3, -1), float2(-1, 3)
            };
            return float4(points[id], 0, 1);
        }
        fragment float4 brushLabCompilerFragment() {
            return float4(0);
        }
        """
    let library = try device.makeLibrary(source: source, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(
        name: "brushLabCompilerVertex"
    )
    descriptor.fragmentFunction = library.makeFunction(
        name: "brushLabCompilerFragment"
    )
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
}
#endif
