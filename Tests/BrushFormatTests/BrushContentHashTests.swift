import BrushFormat
import Foundation
import PatternEngine
import Testing

@Suite("BrushContentHashTests")
struct BrushContentHashTests {
    @Test
    func schemaThreePackageRoundTripsWithHashWriterFour() throws {
        let package = try BrushFormatTestSupport.currentPackage()
        let archive = try BrushPackageCodec.encode(package)
        let decoded = try BrushPackageCodec.decode(archive)

        #expect(decoded == package)
        #expect(decoded.manifest.schemaVersion == 2)
        #expect(decoded.definition.schemaVersion == 3)
        #expect(BrushContentHash.currentSchemaVersion == 4)
        let digest = try decoded.contentHash
        #expect(
            digest
                == "16cc347463c824ecb491b2b1d6ff923134e4435a4283dabb5da9b2e4acf4f64f"
        )
    }

    @Test
    func schemaThreeDigestTracksEveryStageCSemanticGroup() throws {
        let baseline = try BrushFormatTestSupport.currentPackage().contentHash
        let changed = try [
            BrushFormatTestSupport.currentPackage(
                sensorNormalization: BrushSensorNormalizationDefinition(
                    fullScaleWorldVelocity: 2_001,
                    minimumVelocityDeltaTime: 0.001,
                    fullScaleStrokeAge: 4,
                    fullScaleStrokeDistanceInDiameters: 32
                )
            ),
            BrushFormatTestSupport.currentPackage(
                sensorProgram: BrushFormatTestSupport.currentSensorProgram(
                    rotationTerms: [
                        BrushFormatTestSupport.currentTerm(
                            input: .direction,
                            responseOffset: 0.25
                        ),
                    ]
                )
            ),
            BrushFormatTestSupport.currentPackage(
                stabilizationV2: .delayed(distance: 8)
            ),
            BrushFormatTestSupport.currentPackage(
                direction: BrushDirectionDefinition(
                    maximumAngularStep: .pi / 5,
                    stationaryDirection: 0
                )
            ),
            BrushFormatTestSupport.currentPackage(
                emission: BrushEmissionDefinition(
                    mode: .distanceAndTime,
                    timeInterval: 1.0 / 100
                )
            ),
            BrushFormatTestSupport.currentPackage(
                tipSupports: [.analyticRectangle]
            ),
        ]
        for package in changed {
            #expect(try package.contentHash != baseline)
        }
    }

    @Test
    func schemaThreeDigestTracksEveryBehaviorBearingStageCField() throws {
        let baseline = try BrushFormatTestSupport.currentPackage().contentHash
        func hash(term: BrushResponseTermDefinition) throws -> String {
            try BrushFormatTestSupport.currentPackage(
                sensorProgram: BrushFormatTestSupport.currentSensorProgram(
                    rotationTerms: [term]
                )
            ).contentHash
        }
        let termVariants = [
            BrushFormatTestSupport.currentTerm(input: .pressure),
            BrushFormatTestSupport.currentTerm(
                input: .pressure,
                response: .boundedPower(exponent: 2)
            ),
            BrushFormatTestSupport.currentTerm(inputInverted: true),
            BrushFormatTestSupport.currentTerm(missingInputValue: 0.5),
            BrushFormatTestSupport.currentTerm(responseScale: 2),
            BrushFormatTestSupport.currentTerm(responseOffset: 0.25),
            BrushFormatTestSupport.currentTerm(responseLowerClamp: -2),
            BrushFormatTestSupport.currentTerm(responseUpperClamp: 2),
            BrushFormatTestSupport.currentTerm(jitter: 0.1),
            BrushFormatTestSupport.currentTerm(operation: .replace),
        ]
        for term in termVariants {
            #expect(try hash(term: term) != baseline)
        }

        for output in BrushDynamicOutput.allCases {
            var outputs = BrushFormatTestSupport.currentSensorProgram().outputs
            let original = try #require(outputs[output])
            let changedBase: Float = output == .opacity
                ? original.baseValue - 0.125
                : original.baseValue + 0.125
            outputs[output] = BrushOutputProgramDefinition(
                baseValue: changedBase,
                terms: original.terms
            )
            let changed = try BrushFormatTestSupport.currentPackage(
                sensorProgram: BrushSensorProgramDefinition(outputs: outputs)
            )
            #expect(try changed.contentHash != baseline)
        }

        let normalizationVariants = [
            BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 2_001,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 32
            ),
            BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.002,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 32
            ),
            BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 5,
                fullScaleStrokeDistanceInDiameters: 32
            ),
            BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 33
            ),
        ]
        for normalization in normalizationVariants {
            let changed = try BrushFormatTestSupport.currentPackage(
                sensorNormalization: normalization
            )
            #expect(try changed.contentHash != baseline)
        }

        let remaining = try [
            BrushFormatTestSupport.currentPackage(
                stabilizationV2: .weightedWindow(distance: 9)
            ),
            BrushFormatTestSupport.currentPackage(
                direction: BrushDirectionDefinition(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0.25
                )
            ),
            BrushFormatTestSupport.currentPackage(
                emission: BrushEmissionDefinition(
                    mode: .time,
                    timeInterval: 1.0 / 120
                )
            ),
            BrushFormatTestSupport.currentPackage(
                tipSupports: [try .normalizedBounds(
                    minX: -0.75, maxX: 0.75, minY: -0.5, maxY: 0.5
                )]
            ),
        ]
        for package in remaining {
            #expect(try package.contentHash != baseline)
        }
    }

    @Test
    func orderedTermsChangeIdentityButDictionaryInsertionOrderDoesNot() throws {
        let a = BrushFormatTestSupport.currentTerm(input: .pressure)
        let b = BrushFormatTestSupport.currentTerm(input: .speed)
        let ordered = try BrushFormatTestSupport.currentPackage(
            sensorProgram: BrushFormatTestSupport.currentSensorProgram(
                rotationTerms: [a, b]
            )
        )
        let reordered = try BrushFormatTestSupport.currentPackage(
            sensorProgram: BrushFormatTestSupport.currentSensorProgram(
                rotationTerms: [b, a]
            )
        )
        let reverseDictionary = try BrushFormatTestSupport.currentPackage(
            sensorProgram: BrushFormatTestSupport.currentSensorProgram(
                reversedInsertion: true,
                rotationTerms: [a, b]
            )
        )

        #expect(try ordered.contentHash != reordered.contentHash)
        #expect(try ordered.contentHash == reverseDictionary.contentHash)
    }

    @Test
    func schemaThreeDisplayAndProvenanceMetadataAreNonsemantic() throws {
        let base = try BrushFormatTestSupport.currentPackage()
        let changed = try BrushFormatTestSupport.currentPackage(
            metadata: BrushMetadata(
                displayName: "Renamed",
                author: "Different Author",
                sourceApplication: "Different Source",
                sourceIdentifier: "different-id"
            )
        )
        #expect(try changed.contentHash == base.contentHash)
    }

    @Test
    func schemaThreeSourceSettingKeysAreProvenanceOnly() throws {
        let base = try BrushFormatTestSupport.currentPackage()
        let changed = try BrushFormatTestSupport.currentPackage(
            compatibility: BrushCompatibilityMetadata(
                sourceSettingKeys: ["converter.only", "source.setting"],
                requiredSemanticKeys: base.definition.compatibility
                    .requiredSemanticKeys
            )
        )
        let changedRequiredSemantics = try BrushFormatTestSupport.currentPackage(
            compatibility: BrushCompatibilityMetadata(
                sourceSettingKeys: base.definition.compatibility
                    .sourceSettingKeys,
                requiredSemanticKeys: ["required.runtime.semantic"]
            )
        )

        #expect(try changed.contentHash == base.contentHash)
        #expect(try changedRequiredSemantics.contentHash != base.contentHash)
    }

    @Test
    func schemaThreeSingleAndCompositeHashesArePinnedToWriterFour() throws {
        let single = try BrushFormatTestSupport.package()
        let composite = try compositeHashPackage(reversed: false)

        #expect(BrushContentHash.currentSchemaVersion == 4)
        #expect(single.manifest.schemaVersion == 2)
        #expect(single.definition.schemaVersion == 3)
        let singleHash = try single.contentHash
        let compositeHash = try composite.contentHash
        #expect(
            singleHash
                == "16cc347463c824ecb491b2b1d6ff923134e4435a4283dabb5da9b2e4acf4f64f"
        )
        #expect(
            compositeHash
                == "78bb1ac8727e7b573b44be9a725766c84d61d296349193041a450f66f4343849"
        )
    }

    @Test
    func componentOrderIsSemanticAndSharedResourceBytesAreHashedOnce()
        throws
    {
        let ordered = try compositeHashPackage(reversed: false)
        let reversed = try compositeHashPackage(reversed: true)
        #expect(ordered.manifest.resources.count == 1)
        #expect(ordered.definition.components.count == 2)
        #expect(
            ordered.definition.components[0].resources
                == ordered.definition.components[1].resources
        )
        #expect(try ordered.contentHash != reversed.contentHash)
        #expect(
            try BrushPackageCodec.decode(BrushPackageCodec.encode(ordered))
                == ordered
        )
    }
}

private func compositeHashPackage(reversed: Bool) throws -> BrushPackage {
    let package = try BrushFormatTestSupport.package()
    let base = package.definition
    let inherited = base.components[0]
    func component(
        identifier: String,
        ordinal: UInt8,
        offset: SIMD2<Float>,
        scale: Float
    ) -> BrushComponentDefinition {
        BrushComponentDefinition(
            identifier: BrushComponentIdentifier(identifier),
            ordinal: ordinal,
            resources: inherited.resources,
            coverage: BrushCoverageDefinition(
                shapes: [BrushShapeLayerDefinition(
                    shape: inherited.coverage.shapes[0].shape,
                    combination: .replace,
                    scale: scale,
                    rotation: 0,
                    offset: .zero
                )],
                grains: inherited.coverage.grains,
                baseHardness: inherited.coverage.baseHardness,
                aspectRatio: inherited.coverage.aspectRatio,
                tipThreshold: inherited.coverage.tipThreshold,
                antialiasing: inherited.coverage.antialiasing
            ),
            placement: BrushPlacementDefinition(
                baseSpacingFraction: inherited.placement.baseSpacingFraction,
                maximumSpacingFraction:
                    inherited.placement.maximumSpacingFraction,
                baseFlow: inherited.placement.baseFlow,
                strokeOpacity: inherited.placement.strokeOpacity,
                baseScatterFraction:
                    inherited.placement.baseScatterFraction,
                baseRotation: inherited.placement.baseRotation,
                baseJitterFraction: inherited.placement.baseJitterFraction,
                baseOffset: offset
            ),
            dynamics: inherited.dynamics,
            color: inherited.color,
            material: inherited.material,
            taper: inherited.taper,
            sensorProgram: inherited.sensorProgram,
            emission: inherited.emission,
            tipSupports: inherited.tipSupports
        )
    }
    let first = component(
        identifier: reversed ? "texture" : "primary",
        ordinal: 0,
        offset: reversed ? SIMD2(8, 0) : .zero,
        scale: reversed ? 0.5 : 1
    )
    let second = component(
        identifier: reversed ? "primary" : "texture",
        ordinal: 1,
        offset: reversed ? .zero : SIMD2(8, 0),
        scale: reversed ? 1 : 0.5
    )
    let definition = try BrushDefinition(
        id: base.id,
        metadata: base.metadata,
        capabilities: base.capabilities,
        composition: .orderedSourceOver,
        components: [first, second],
        stabilization: base.stabilization,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: base.termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: .realtime60,
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
