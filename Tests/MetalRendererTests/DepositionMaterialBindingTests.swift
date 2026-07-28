import CShaderTypes
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Deposition material binding", .serialized)
@MainActor
struct DepositionMaterialBindingTests {
    @Test
    func mapsDefinitionOrderToFrozenUniformsAndTextureSlots() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let secondaryShape = try texture(device: device, label: "secondary")
        let primaryGrain = try texture(device: device, label: "primary-grain")
        let secondaryGrain = try texture(
            device: device,
            label: "secondary-grain"
        )
        let binding = try DepositionMaterialBinding(
            uniformTemplate: template(
                shapes: [
                    shape(.hardRound, combination: .replace),
                    shape(
                        .asset("shape.secondary"),
                        combination: .multiply,
                        scale: 0.75,
                        rotation: 0.25,
                        offset: SIMD2(0.1, -0.2)
                    ),
                ],
                grains: [
                    grain(.asset("grain.primary"), strength: 0.25),
                    grain(.paper, strength: 0.75),
                ]
            ),
            textures: [
                "shape.secondary": secondaryShape,
                "grain.primary": primaryGrain,
                BrushTextureIdentity.paperGrain.rawValue: secondaryGrain,
            ]
        )

        #expect(
            binding.uniforms.coverageParameters
                == SIMD4(0.25, 0.75, 0.4, 0.8)
        )
        #expect(
            binding.uniforms.secondaryShapeTransform
                == SIMD4(0.75, 0.25, 0.1, -0.2)
        )
        #expect(binding.uniforms.edgeParameters == SIMD4(0.6, 0, 0, 0))
        #expect(
            binding.uniforms.options
                == SIMD4(
                    PatternDepositionShapeCombinationMultiply,
                    1,
                    PatternDepositionShapeKindHardRound,
                    PatternDepositionShapeKindTexture
                )
        )
        #expect(binding.textures.boundSlots == [
            .secondaryShape,
            .primaryGrain,
            .secondaryGrain,
        ])
        #expect(binding.textures[.primaryShape] == nil)
        #expect(binding.textures[.secondaryShape] === secondaryShape)
        #expect(binding.textures[.primaryGrain] === primaryGrain)
        #expect(binding.textures[.secondaryGrain] === secondaryGrain)
    }

    @Test
    func missingRequiredTextureFailsBeforeBindingPublication() throws {
        let missing = template(
            shapes: [shape(.asset("shape.missing"), combination: .replace)],
            grains: []
        )

        #expect(
            throws: DepositionPreparationError.missingRequiredResource(
                "shape.missing"
            )
        ) {
            _ = try DepositionMaterialBinding(
                uniformTemplate: missing,
                textures: [:]
            )
        }
    }

    @Test
    func analyticHardRoundLeavesItsTextureSlotUnbound() throws {
        let binding = try DepositionMaterialBinding(
            uniformTemplate: template(
                shapes: [shape(.hardRound, combination: .replace)],
                grains: []
            ),
            textures: [:]
        )

        #expect(binding.textures.boundSlots.isEmpty)
        #expect(
            binding.uniforms.options.z
                == PatternDepositionShapeKindHardRound
        )
    }

    private func template(
        shapes: [BrushShapeLayerDefinition],
        grains: [BrushGrainLayerDefinition]
    ) -> BrushUniformTemplate {
        return BrushUniformTemplate(
            placement: BrushPlacementDefinition(
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.2,
                baseFlow: 0.7,
                strokeOpacity: 0.9,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            coverage: BrushCoverageDefinition(
                shapes: shapes,
                grains: grains,
                baseHardness: 0.5,
                aspectRatio: 1,
                tipThreshold: 0.4,
                antialiasing: true
            ),
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
                edgeTreatment: .dryBreakup,
                strength: 0.6,
                wetness: 0,
                bleedRadius: 0,
                softenPasses: 0,
                accumulationLimit: 0.8,
                interactionParameters: nil
            )
        )
    }

    private func shape(
        _ descriptor: BrushShapeDescriptor,
        combination: BrushShapeCombinationMode,
        scale: Float = 1,
        rotation: Float = 0,
        offset: SIMD2<Float> = .zero
    ) -> BrushShapeLayerDefinition {
        BrushShapeLayerDefinition(
            shape: descriptor,
            combination: combination,
            scale: scale,
            rotation: rotation,
            offset: offset
        )
    }

    private func grain(
        _ descriptor: BrushGrainDescriptor,
        strength: Float
    ) -> BrushGrainLayerDefinition {
        BrushGrainLayerDefinition(
            grain: descriptor,
            coordinateMode: .canonical,
            transform: .identity,
            grainMovementFraction: 0,
            grainFollowsBrushRotation: false,
            strength: strength
        )
    }

    private func texture(
        device: any MTLDevice,
        label: String
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.label = label
        return texture
    }
}
