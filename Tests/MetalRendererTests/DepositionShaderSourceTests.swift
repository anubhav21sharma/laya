import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Deposition shader specialization")
struct DepositionShaderSourceTests {
    @Test
    func depositionMaterialUniformsHaveFrozenSharedLayout() {
        #expect(MemoryLayout<PatternDepositionMaterialUniforms>.size == 64)
        #expect(MemoryLayout<PatternDepositionMaterialUniforms>.stride == 64)
        #expect(MemoryLayout<PatternDepositionMaterialUniforms>.alignment == 16)
        #expect(
            MemoryLayout<PatternDepositionMaterialUniforms>.offset(
                of: \.coverageParameters
            ) == 0
        )
        #expect(
            MemoryLayout<PatternDepositionMaterialUniforms>.offset(
                of: \.secondaryShapeTransform
            ) == 16
        )
        #expect(
            MemoryLayout<PatternDepositionMaterialUniforms>.offset(
                of: \.edgeParameters
            ) == 32
        )
        #expect(
            MemoryLayout<PatternDepositionMaterialUniforms>.offset(
                of: \.options
            ) == 48
        )
    }

    @Test
    func declaresEveryStageFourFunctionConstant() throws {
        let source = try depositionShaderSource()

        #expect(source.contains(
            "constant bool patternDepositionHasSecondaryShape"
        ))
        #expect(source.contains(
            "constant bool patternDepositionHasPrimaryGrain"
        ))
        #expect(source.contains(
            "constant bool patternDepositionHasSecondaryGrain"
        ))
        #expect(source.contains(
            "constant uint patternDepositionAccumulationMode"
        ))
        #expect(source.contains(
            "constant uint patternDepositionEdgeTreatment"
        ))
    }

    @Test
    func exposesSharedCoverageAccumulationAndProjectedEntryPoints() throws {
        let source = try depositionShaderSource()

        #expect(source.contains(
            "static float patternDepositionCoverage("
        ))
        #expect(source.contains(
            "static float patternDepositionAccumulatedAlpha("
        ))
        #expect(source.contains(
            "vertex PatternProjectedDepositionOut "
                + "patternProjectedDepositionVertex("
        ))
        #expect(source.contains(
            "fragment float4 patternDepositionFragment("
        ))
    }

    @Test
    func depositionFragmentHasNoLegacyMaterialDispatch() throws {
        let source = try depositionShaderSource()
        let fragment = try functionSource(
            named: "patternDepositionFragment",
            in: source
        )
        let forbidden = [
            "PatternMaterialWireInk",
            "PatternMaterialWireDry",
            "PatternMaterialWireGlaze",
            "PatternMaterialWireBoundedWash",
            "materialFamily",
            "patternWash",
            "fallback",
        ]

        for token in forbidden {
            #expect(!fragment.contains(token))
        }
    }

    @Test
    func wetConcentrationHasNoProductionShaderWireOrPipelineBranch() throws {
        let root = repositoryRoot()
        let sources = [
            try String(
                contentsOf: root.appendingPathComponent(
                    "Sources/CShaderTypes/include/ShaderTypes.h"
                ),
                encoding: .utf8
            ),
            try String(
                contentsOf: root.appendingPathComponent(
                    "Sources/MetalRenderer/Shaders.metal"
                ),
                encoding: .utf8
            ),
            try String(
                contentsOf: root.appendingPathComponent(
                    "Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift"
                ),
                encoding: .utf8
            ),
        ]

        #expect(
            sources.allSatisfy {
                !$0.contains("PatternDepositionEdgeWetConcentration")
            }
        )
    }

    @Test
    @MainActor
    func everySupportedSpecializationBuildsAProductionPipeline() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeShaderLibrary(device: device)
        let featureSets = [
            (false, false, false),
            (true, true, false),
            (true, true, true),
        ]
        let modes: [BrushAccumulationMode] = [
            .opaque,
            .flow,
            .uniformGlaze,
            .intenseGlaze,
            .destinationOut,
        ]
        let edges: [BrushEdgeTreatment] = [
            .none,
            .dryBreakup,
            .markerOverlap,
        ]

        for features in featureSets {
            for mode in modes {
                for edge in edges {
                    let constants = functionConstants(
                        hasSecondaryShape: features.0,
                        hasPrimaryGrain: features.1,
                        hasSecondaryGrain: features.2,
                        accumulationMode: mode,
                        edgeTreatment: edge
                    )
                    let vertex = try library.makeFunction(
                        name: "patternProjectedDepositionVertex",
                        constantValues: constants
                    )
                    let fragment = try library.makeFunction(
                        name: "patternDepositionFragment",
                        constantValues: constants
                    )
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = vertex
                    descriptor.fragmentFunction = fragment
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                    _ = try device.makeRenderPipelineState(
                        descriptor: descriptor
                    )
                }
            }
        }
    }

    @Test
    @MainActor
    func cpuAndMetalAgreeForEveryAccumulationAndEdgeMode() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeProbeLibrary(device: device)
        let vertex = try #require(
            library.makeFunction(name: "patternBlankVertex")
        )
        let fragment = try #require(
            library.makeFunction(name: "patternDepositionDifferentialProbe")
        )
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(
            descriptor: descriptor
        )
        let modes: [BrushAccumulationMode] = [
            .opaque,
            .flow,
            .uniformGlaze,
            .intenseGlaze,
            .destinationOut,
        ]
        let edges: [BrushEdgeTreatment] = [
            .none,
            .dryBreakup,
            .markerOverlap,
        ]

        var fixtureOrdinal = 0
        for mode in modes {
            for edge in edges {
                let textureSide = fixtureOrdinal.isMultiple(of: 2) ? 1 : 2
                let actual = try renderProbe(
                    device: device,
                    pipeline: pipeline,
                    textureSide: textureSide,
                    accumulationMode: mode,
                    edgeTreatment: edge
                )
                let expected = expectedProbeBGRA(
                    accumulationMode: mode,
                    edgeTreatment: edge
                )

                #expect(channelsMatch(actual, expected, maximumDelta: 1))
                fixtureOrdinal += 1
            }
        }
    }

    @Test
    @MainActor
    func productionFragmentMatchesReferenceSourceCoverage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeShaderLibrary(device: device)
        let modes: [BrushAccumulationMode] = [
            .opaque,
            .flow,
            .uniformGlaze,
            .intenseGlaze,
            .destinationOut,
        ]
        let edges: [BrushEdgeTreatment] = [
            .none,
            .dryBreakup,
            .markerOverlap,
        ]

        for mode in modes {
            for edge in edges {
                let constants = functionConstants(
                    hasSecondaryShape: true,
                    hasPrimaryGrain: true,
                    hasSecondaryGrain: true,
                    accumulationMode: mode,
                    edgeTreatment: edge
                )
                let vertex = try library.makeFunction(
                    name: "patternProjectedDepositionVertex",
                    constantValues: constants
                )
                let fragment = try library.makeFunction(
                    name: "patternDepositionFragment",
                    constantValues: constants
                )
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                let pipeline = try device.makeRenderPipelineState(
                    descriptor: descriptor
                )
                let actual = try renderProductionFragment(
                    device: device,
                    pipeline: pipeline
                )
                let expected = expectedProductionBGRA(
                    accumulationMode: mode,
                    edgeTreatment: edge
                )

                #expect(channelsMatch(actual, expected, maximumDelta: 1))
            }
        }
    }

    @Test
    func differentialValidatorRejectsAnIntenseGlazeRegression() {
        let current = Float(0.2)
        let flow = Float(0.25)
        let expected = DepositionReference.accumulateAlpha(
            current: current,
            baseCoverage: 0.5,
            flowCoverage: flow,
            mode: .intenseGlaze,
            accumulationLimit: 1
        )
        let incorrectFlowUnion = DepositionReference.accumulateAlpha(
            current: current,
            baseCoverage: 0.5,
            flowCoverage: flow,
            mode: .flow,
            accumulationLimit: 1
        )
        let expectedBGRA: [UInt8] = [0, 0, unorm(expected), 255]
        let incorrectBGRA: [UInt8] = [
            0,
            0,
            unorm(incorrectFlowUnion),
            255,
        ]

        #expect(!channelsMatch(
            incorrectBGRA,
            expectedBGRA,
            maximumDelta: 1
        ))
    }

    private func functionSource(
        named name: String,
        in source: String
    ) throws -> Substring {
        let nameRange = try #require(source.range(of: "\(name)("))
        let opening = try #require(
            source[nameRange.upperBound...].firstIndex(of: "{")
        )
        var depth = 0
        var index = opening
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return source[nameRange.lowerBound...index]
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        Issue.record("Unterminated Metal function \(name)")
        return source[nameRange.lowerBound...]
    }

    private func depositionShaderSource() throws -> String {
        return try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Sources/MetalRenderer/Shaders.metal"
            ),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func makeShaderLibrary(
        device: any MTLDevice,
        suffix: String = ""
    ) throws -> any MTLLibrary {
        let source = try depositionShaderSource()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let header = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
            encoding: .utf8
        )
        return try device.makeLibrary(
            source: source.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ) + suffix,
            options: nil
        )
    }

    @MainActor
    private func makeProbeLibrary(
        device: any MTLDevice
    ) throws -> any MTLLibrary {
        try makeShaderLibrary(device: device, suffix: Self.probeSource)
    }

    private func functionConstants(
        hasSecondaryShape: Bool,
        hasPrimaryGrain: Bool,
        hasSecondaryGrain: Bool,
        accumulationMode: BrushAccumulationMode,
        edgeTreatment: BrushEdgeTreatment
    ) -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        var secondaryShape = hasSecondaryShape
        var primaryGrain = hasPrimaryGrain
        var secondaryGrain = hasSecondaryGrain
        var accumulation = accumulationWire(accumulationMode)
        var edge = edgeWire(edgeTreatment)
        values.setConstantValue(
            &secondaryShape,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantSecondaryShape)
        )
        values.setConstantValue(
            &primaryGrain,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantPrimaryGrain)
        )
        values.setConstantValue(
            &secondaryGrain,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantSecondaryGrain)
        )
        values.setConstantValue(
            &accumulation,
            type: .uint,
            index: Int(PatternDepositionFunctionConstantAccumulation)
        )
        values.setConstantValue(
            &edge,
            type: .uint,
            index: Int(PatternDepositionFunctionConstantEdgeTreatment)
        )
        return values
    }

    @MainActor
    private func renderProbe(
        device: any MTLDevice,
        pipeline: any MTLRenderPipelineState,
        textureSide: Int,
        accumulationMode: BrushAccumulationMode,
        edgeTreatment: BrushEdgeTreatment
    ) throws -> [UInt8] {
        let primaryShape = try r8Texture(
            device: device,
            side: textureSide,
            value: 204
        )
        let secondaryShape = try r8Texture(
            device: device,
            side: textureSide,
            value: 128
        )
        let primaryGrain = try r8Texture(
            device: device,
            side: textureSide,
            value: 153
        )
        let secondaryGrain = try r8Texture(
            device: device,
            side: textureSide,
            value: 102
        )
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor
        ))
        var uniforms = DepositionProbeUniforms(
            coverageInputs: SIMD4(0.8, 0.6, 0.75, 0.9),
            material: PatternDepositionMaterialUniforms(
                coverageParameters: SIMD4(0.5, 0.25, 0, 0.8),
                secondaryShapeTransform: SIMD4(1, 0, 0, 0),
                edgeParameters: SIMD4(1, 0, 0, 0),
                options: SIMD4(
                    PatternDepositionShapeCombinationMultiply,
                    1,
                    PatternDepositionShapeKindTexture,
                    PatternDepositionShapeKindTexture
                )
            ),
            controls: SIMD4(
                edgeTreatment == .none ? 2 : 0,
                0.2,
                0,
                0
            ),
            features: SIMD4(1, 1, 1, edgeWire(edgeTreatment)),
            modes: SIMD4(
                accumulationWire(accumulationMode),
                0,
                0,
                0
            )
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = .init(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        let commandBuffer = try #require(
            device.makeCommandQueue()?.makeCommandBuffer()
        )
        let encoder = try #require(
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<DepositionProbeUniforms>.stride,
            index: 0
        )
        encoder.setFragmentTexture(primaryShape, index: 0)
        encoder.setFragmentTexture(secondaryShape, index: 1)
        encoder.setFragmentTexture(primaryGrain, index: 2)
        encoder.setFragmentTexture(secondaryGrain, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var bytes = [UInt8](repeating: 0, count: 4)
        target.getBytes(
            &bytes,
            bytesPerRow: 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        return bytes
    }

    @MainActor
    private func renderProductionFragment(
        device: any MTLDevice,
        pipeline: any MTLRenderPipelineState
    ) throws -> [UInt8] {
        let textures = try [
            r8Texture(device: device, side: 2, value: 204),
            r8Texture(device: device, side: 2, value: 128),
            r8Texture(device: device, side: 2, value: 153),
            r8Texture(device: device, side: 2, value: 102),
        ]
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor
        ))
        var frame = PatternGridFrameUniforms(
            drawableSize: SIMD2(1, 1),
            worldCenter: .zero,
            tileSize: SIMD2(1, 1),
            zoom: 1,
            gridLineWidth: 0,
            showGridLines: 0,
            liveVisible: 0,
            tilingKind: 0,
            diagnosticMode: 0,
            compositeMode: 0,
            symmetryFamily: 0,
            repeatSize: SIMD2(1, 1),
            latticeXAxis: SIMD2(1, 0),
            latticeYAxis: SIMD2(0, 1),
            latticeTranslation: .zero,
            guideKind: 0,
            showCanvasBoundary: 0
        )
        let identityFrame0 = SIMD4<Float>(1, 0, 0, 1)
        let identityFrame1 = SIMD4<Float>(0, 0, 0, 0)
        var instance = PatternDepositionStampInstance(
            tipFrame0: identityFrame0,
            tipFrame1: SIMD4(0, 0.5, 1, 0),
            primaryGrainFrame0: identityFrame0,
            primaryGrainFrame1: identityFrame1,
            secondaryGrainFrame0: identityFrame0,
            secondaryGrainFrame1: identityFrame1,
            premultipliedColor: SIMD4(1, 1, 1, 1),
            coverageInputs: SIMD4(0.8, 0.6, 0.75, 0.9),
            clip0: zeroClip,
            clip1: zeroClip,
            clip2: zeroClip,
            clip3: zeroClip,
            identity: .zero,
            metadata: SIMD4(0, 0, 3, PatternDepositionABIVersion),
            reserved0: .zero,
            reserved1: .zero
        )
        var material = probeMaterial
        let instanceBuffer = try #require(device.makeBuffer(
            bytes: &instance,
            length: MemoryLayout<PatternDepositionStampInstance>.stride
        ))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = .init(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        let commandBuffer = try #require(
            device.makeCommandQueue()?.makeCommandBuffer()
        )
        let encoder = try #require(
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(
            &frame,
            length: MemoryLayout<PatternGridFrameUniforms>.stride,
            index: Int(PatternBufferIndexGridFrameUniforms)
        )
        encoder.setVertexBuffer(
            instanceBuffer,
            offset: 0,
            index: Int(PatternBufferIndexDabInstances)
        )
        encoder.setFragmentBytes(
            &material,
            length: MemoryLayout<PatternDepositionMaterialUniforms>.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: 1
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var bytes = [UInt8](repeating: 0, count: 4)
        target.getBytes(
            &bytes,
            bytesPerRow: 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        return bytes
    }

    @MainActor
    private func r8Texture(
        device: any MTLDevice,
        side: Int,
        value: UInt8
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: side,
            height: side,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(
            descriptor: descriptor
        ))
        let bytes = [UInt8](repeating: value, count: side * side)
        texture.replace(
            region: MTLRegionMake2D(0, 0, side, side),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: side
        )
        return texture
    }

    private func expectedProbeBGRA(
        accumulationMode: BrushAccumulationMode,
        edgeTreatment: BrushEdgeTreatment
    ) -> [UInt8] {
        let referenceMaterial = DepositionReferenceMaterial(
            secondaryShapeCombination: .multiply,
            primaryGrainStrength: 0.5,
            secondaryGrainStrength: 0.25,
            tipThreshold: 0,
            antialiasing: true,
            accumulationMode: accumulationMode,
            edgeTreatment: edgeTreatment,
            materialStrength: 1,
            accumulationLimit: 0.8
        )
        let samples = DepositionCoverageSamples(
            primaryShape: Float(204) / 255,
            secondaryShape: Float(128) / 255,
            primaryGrain: Float(153) / 255,
            secondaryGrain: Float(102) / 255,
            signedTipEdgeDistance: edgeTreatment == .none ? 2 : 0
        )
        let instance = PatternDepositionStampInstance(
            tipFrame0: .zero,
            tipFrame1: .zero,
            primaryGrainFrame0: .zero,
            primaryGrainFrame1: .zero,
            secondaryGrainFrame0: .zero,
            secondaryGrainFrame1: .zero,
            premultipliedColor: .zero,
            coverageInputs: SIMD4(0.8, 0.6, 0.75, 0.9),
            clip0: zeroClip,
            clip1: zeroClip,
            clip2: zeroClip,
            clip3: zeroClip,
            identity: .zero,
            metadata: .zero,
            reserved0: .zero,
            reserved1: .zero
        )
        let base = DepositionReference.coverage(
            samples: samples,
            instance: instance,
            material: referenceMaterial
        )
        let flow = min(1, max(0, base * 0.6))
        let accumulated = DepositionReference.accumulateAlpha(
            current: 0.2,
            baseCoverage: base,
            flowCoverage: flow,
            mode: accumulationMode,
            accumulationLimit: 0.8
        )
        return [unorm(flow), unorm(base), unorm(accumulated), 255]
    }

    private func expectedProductionBGRA(
        accumulationMode: BrushAccumulationMode,
        edgeTreatment: BrushEdgeTreatment
    ) -> [UInt8] {
        let base = referenceCoverage(
            accumulationMode: accumulationMode,
            edgeTreatment: edgeTreatment,
            signedTipEdgeDistance: 0.5
        )
        let flow = min(1, max(0, base * 0.6))
        let deposited: Float
        switch accumulationMode {
        case .opaque:
            deposited = base
        case .intenseGlaze:
            deposited = 1 - (1 - flow) * (1 - flow)
        case .flow, .uniformGlaze, .destinationOut:
            deposited = flow
        }
        let limited = min(0.8, deposited)
        if accumulationMode == .destinationOut {
            return [0, 0, 0, unorm(limited)]
        }
        let value = unorm(limited)
        return [value, value, value, value]
    }

    private func referenceCoverage(
        accumulationMode: BrushAccumulationMode,
        edgeTreatment: BrushEdgeTreatment,
        signedTipEdgeDistance: Float
    ) -> Float {
        let material = DepositionReferenceMaterial(
            secondaryShapeCombination: .multiply,
            primaryGrainStrength: 0.5,
            secondaryGrainStrength: 0.25,
            tipThreshold: 0,
            antialiasing: true,
            accumulationMode: accumulationMode,
            edgeTreatment: edgeTreatment,
            materialStrength: 1,
            accumulationLimit: 0.8
        )
        let samples = DepositionCoverageSamples(
            primaryShape: Float(204) / 255,
            secondaryShape: Float(128) / 255,
            primaryGrain: Float(153) / 255,
            secondaryGrain: Float(102) / 255,
            signedTipEdgeDistance: signedTipEdgeDistance
        )
        let instance = PatternDepositionStampInstance(
            tipFrame0: .zero,
            tipFrame1: .zero,
            primaryGrainFrame0: .zero,
            primaryGrainFrame1: .zero,
            secondaryGrainFrame0: .zero,
            secondaryGrainFrame1: .zero,
            premultipliedColor: .zero,
            coverageInputs: SIMD4(0.8, 0.6, 0.75, 0.9),
            clip0: zeroClip,
            clip1: zeroClip,
            clip2: zeroClip,
            clip3: zeroClip,
            identity: .zero,
            metadata: .zero,
            reserved0: .zero,
            reserved1: .zero
        )
        return DepositionReference.coverage(
            samples: samples,
            instance: instance,
            material: material
        )
    }

    private var probeMaterial: PatternDepositionMaterialUniforms {
        PatternDepositionMaterialUniforms(
            coverageParameters: SIMD4(0.5, 0.25, 0, 0.8),
            secondaryShapeTransform: SIMD4(1, 0, 0, 0),
            edgeParameters: SIMD4(1, 0, 0, 0),
            options: SIMD4(
                PatternDepositionShapeCombinationMultiply,
                1,
                PatternDepositionShapeKindTexture,
                PatternDepositionShapeKindTexture
            )
        )
    }

    private var zeroClip: PatternClipHalfPlane {
        PatternClipHalfPlane(normal: .zero, offset: 0, padding: 0)
    }

    private func accumulationWire(
        _ mode: BrushAccumulationMode
    ) -> UInt32 {
        switch mode {
        case .opaque:
            PatternDepositionAccumulationOpaque
        case .flow:
            PatternDepositionAccumulationFlow
        case .uniformGlaze:
            PatternDepositionAccumulationUniformGlaze
        case .intenseGlaze:
            PatternDepositionAccumulationIntenseGlaze
        case .destinationOut:
            PatternDepositionAccumulationDestinationOut
        }
    }

    private func edgeWire(_ treatment: BrushEdgeTreatment) -> UInt32 {
        switch treatment {
        case .none:
            PatternDepositionEdgeNone
        case .dryBreakup:
            PatternDepositionEdgeDryBreakup
        case .markerOverlap:
            PatternDepositionEdgeMarkerOverlap
        case .wetConcentration:
            preconditionFailure(
                "Wet concentration is unavailable to production shaders"
            )
        }
    }

    private func channelsMatch(
        _ actual: [UInt8],
        _ expected: [UInt8],
        maximumDelta: Int
    ) -> Bool {
        actual.count == expected.count
            && zip(actual, expected).allSatisfy {
                abs(Int($0) - Int($1)) <= maximumDelta
            }
    }

    private func unorm(_ value: Float) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }

    private static let probeSource = #"""

struct PatternDepositionProbeUniforms {
    float4 coverageInputs;
    PatternDepositionMaterialUniforms material;
    float4 controls;
    uint4 features;
    uint4 modes;
};

fragment float4 patternDepositionDifferentialProbe(
    PatternVertexOut input [[stage_in]],
    constant PatternDepositionProbeUniforms& uniforms [[buffer(0)]],
    texture2d<float> primaryShape [[texture(0)]],
    texture2d<float> secondaryShape [[texture(1)]],
    texture2d<float> primaryGrain [[texture(2)]],
    texture2d<float> secondaryGrain [[texture(3)]]
) {
    constexpr sampler sampleValue(
        coord::normalized,
        address::clamp_to_edge,
        filter::nearest
    );
    const float2 uv = float2(0.5);
    const float base = patternDepositionCoverage(
        primaryShape.sample(sampleValue, uv).r,
        secondaryShape.sample(sampleValue, uv).r,
        primaryGrain.sample(sampleValue, uv).r,
        secondaryGrain.sample(sampleValue, uv).r,
        uniforms.controls.x,
        uniforms.coverageInputs,
        uniforms.material,
        uniforms.features.x != 0,
        uniforms.features.y != 0,
        uniforms.features.z != 0,
        uniforms.features.w
    );
    const float flow = patternDepositionClamp01(
        base * patternDepositionClamp01(uniforms.coverageInputs.y)
    );
    const float accumulated = patternDepositionAccumulatedAlpha(
        uniforms.controls.y,
        base,
        flow,
        uniforms.modes.x,
        uniforms.material.coverageParameters.w
    );
    return float4(accumulated, base, flow, 1.0);
}
"""#
}

private struct DepositionProbeUniforms {
    var coverageInputs: SIMD4<Float>
    var material: PatternDepositionMaterialUniforms
    var controls: SIMD4<Float>
    var features: SIMD4<UInt32>
    var modes: SIMD4<UInt32>
}
