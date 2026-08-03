import BrushFormat
import Foundation
import PatternEngine
import Testing

@Suite("BrushContentHashTests")
struct BrushContentHashTests {
    @Test
    func frozenSchemaV1FixtureCompilesAndEmitsPinnedLogicalTrace() throws {
        let url = try #require(Bundle.module.url(
            forResource: "stage2-v1",
            withExtension: "layabrush",
            subdirectory: "Fixtures"
        ))
        let package = try BrushPackageCodec.decode(Data(contentsOf: url))
        let program = try BrushProgramCompiler.compile(package.definition)
        var generator = BrushStrokeGenerator(
            program: program,
            nominalDiameter: 20,
            color: .black,
            seed: 41
        )
        let viewport = ViewportTransform(
            drawableSize: PatternSize(width: 64, height: 64),
            worldCenter: WorldPoint(x: 32, y: 32)
        )
        var input = BrushInputDeriver()
        func sample(
            x: Float,
            pressure: Float,
            timestamp: TimeInterval,
            phase: StrokePhase
        ) -> WorldStrokeSample {
            input.derive(
                StrokeSample(
                    position: ScreenPoint(x: x, y: 32),
                    pressure: pressure,
                    timestamp: timestamp,
                    phase: phase,
                    source: .pencil,
                    capabilities: [.pressure]
                ),
                viewport: viewport
            )
        }
        var dabs: [DabAttributes] = []
        generator.begin(sample(
            x: 8, pressure: 0.25, timestamp: 0, phase: .began
        )) { dabs.append($0) }
        generator.append(sample(
            x: 32, pressure: 0.75, timestamp: 0.5, phase: .moved
        )) { dabs.append($0) }
        generator.finish(sample(
            x: 56, pressure: 1, timestamp: 1, phase: .ended
        )) { dabs.append($0) }

        let trace = dabs.map {
            [
                String($0.position.x.bitPattern),
                String($0.position.y.bitPattern),
                String($0.diameter.bitPattern),
                String($0.spacing.bitPattern),
                String($0.flow.bitPattern),
                String($0.strokeOpacity.bitPattern),
                String($0.ordinal),
            ].joined(separator: ":")
        }.joined(separator: "|")
        let digest = BrushContentHash.sha256Hex(of: Data(trace.utf8))

        #expect(dabs.count == 21)
        #expect(
            digest
                == "40c4f8b7acfe363ac984f7a40df9bb7792ce24d497f26d69ec97944fcb1b2f86"
        )
        #expect(program.stageC == nil)
    }

    @Test
    func schemaV2PackageRoundTripsWithHashSchemaThree() throws {
        let package = try BrushFormatTestSupport.v2Package()
        let archive = try BrushPackageCodec.encode(package)
        let decoded = try BrushPackageCodec.decode(archive)

        #expect(decoded == package)
        #expect(decoded.manifest.schemaVersion == 2)
        #expect(decoded.definition.schemaVersion == 2)
        #expect(BrushContentHash.legacySchemaVersion == 2)
        #expect(BrushContentHash.currentSchemaVersion == 3)
        #expect(
            try decoded.contentHash
                == "bd7bcd38c40ce5c200353d91ef8ff3f0bb958153217240ed192cfbab1bc7e076"
        )
    }

    @Test
    func schemaV2DigestTracksEveryStageCSemanticGroup() throws {
        let baseline = try BrushFormatTestSupport.v2Package().contentHash
        let changed = try [
            BrushFormatTestSupport.v2Package(
                sensorNormalization: BrushSensorNormalizationDefinition(
                    fullScaleWorldVelocity: 2_001,
                    minimumVelocityDeltaTime: 0.001,
                    fullScaleStrokeAge: 4,
                    fullScaleStrokeDistanceInDiameters: 32
                )
            ),
            BrushFormatTestSupport.v2Package(
                sensorProgram: BrushFormatTestSupport.v2SensorProgram(
                    rotationTerms: [
                        BrushFormatTestSupport.v2Term(
                            input: .direction,
                            responseOffset: 0.25
                        ),
                    ]
                )
            ),
            BrushFormatTestSupport.v2Package(
                stabilizationV2: .delayed(distance: 8)
            ),
            BrushFormatTestSupport.v2Package(
                direction: BrushDirectionDefinition(
                    maximumAngularStep: .pi / 5,
                    stationaryDirection: 0
                )
            ),
            BrushFormatTestSupport.v2Package(
                emission: BrushEmissionDefinition(
                    mode: .distanceAndTime,
                    timeInterval: 1.0 / 100
                )
            ),
            BrushFormatTestSupport.v2Package(
                tipSupports: [.analyticRectangle]
            ),
        ]
        for package in changed {
            #expect(try package.contentHash != baseline)
        }
    }

    @Test
    func schemaV2DigestTracksEveryBehaviorBearingStageCField() throws {
        let baseline = try BrushFormatTestSupport.v2Package().contentHash
        func hash(term: BrushResponseTermDefinition) throws -> String {
            try BrushFormatTestSupport.v2Package(
                sensorProgram: BrushFormatTestSupport.v2SensorProgram(
                    rotationTerms: [term]
                )
            ).contentHash
        }
        let termVariants = [
            BrushFormatTestSupport.v2Term(input: .pressure),
            BrushFormatTestSupport.v2Term(
                input: .pressure,
                response: .boundedPower(exponent: 2)
            ),
            BrushFormatTestSupport.v2Term(inputInverted: true),
            BrushFormatTestSupport.v2Term(missingInputValue: 0.5),
            BrushFormatTestSupport.v2Term(responseScale: 2),
            BrushFormatTestSupport.v2Term(responseOffset: 0.25),
            BrushFormatTestSupport.v2Term(responseLowerClamp: -2),
            BrushFormatTestSupport.v2Term(responseUpperClamp: 2),
            BrushFormatTestSupport.v2Term(jitter: 0.1),
            BrushFormatTestSupport.v2Term(operation: .replace),
        ]
        for term in termVariants {
            #expect(try hash(term: term) != baseline)
        }

        for output in BrushDynamicOutput.allCases {
            var outputs = BrushFormatTestSupport.v2SensorProgram().outputs
            let original = try #require(outputs[output])
            let changedBase: Float = output == .opacity
                ? original.baseValue - 0.125
                : original.baseValue + 0.125
            outputs[output] = BrushOutputProgramDefinition(
                baseValue: changedBase,
                terms: original.terms
            )
            let changed = try BrushFormatTestSupport.v2Package(
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
            let changed = try BrushFormatTestSupport.v2Package(
                sensorNormalization: normalization
            )
            #expect(try changed.contentHash != baseline)
        }

        let remaining = try [
            BrushFormatTestSupport.v2Package(
                stabilizationV2: .weightedWindow(distance: 9)
            ),
            BrushFormatTestSupport.v2Package(
                direction: BrushDirectionDefinition(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0.25
                )
            ),
            BrushFormatTestSupport.v2Package(
                emission: BrushEmissionDefinition(
                    mode: .time,
                    timeInterval: 1.0 / 120
                )
            ),
            BrushFormatTestSupport.v2Package(
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
        let a = BrushFormatTestSupport.v2Term(input: .pressure)
        let b = BrushFormatTestSupport.v2Term(input: .speed)
        let ordered = try BrushFormatTestSupport.v2Package(
            sensorProgram: BrushFormatTestSupport.v2SensorProgram(
                rotationTerms: [a, b]
            )
        )
        let reordered = try BrushFormatTestSupport.v2Package(
            sensorProgram: BrushFormatTestSupport.v2SensorProgram(
                rotationTerms: [b, a]
            )
        )
        let reverseDictionary = try BrushFormatTestSupport.v2Package(
            sensorProgram: BrushFormatTestSupport.v2SensorProgram(
                reversedInsertion: true,
                rotationTerms: [a, b]
            )
        )

        #expect(try ordered.contentHash != reordered.contentHash)
        #expect(try ordered.contentHash == reverseDictionary.contentHash)
    }

    @Test
    func manifestVersionAndProvenanceCannotSelectCanonicalWriter() throws {
        let base = try BrushFormatTestSupport.package()
        let legacyManifest = try BrushPackageManifest(
            schemaVersion: 1,
            resources: base.manifest.resources
        )
        let legacyManifestPackage = try BrushPackage(
            manifest: legacyManifest,
            definition: base.definition,
            resourceData: base.resourceData
        )

        #expect(try legacyManifestPackage.contentHash == base.contentHash)
        #expect(base.definition.schemaVersion == 1)
        #expect(try base.contentHash ==
            "ed1f9b8e914d9dc597b45ba9b03baccf57194eb2179776f743bdd2d9d0a872fb")
    }

    @Test
    func schemaV2DisplayAndProvenanceMetadataAreNonsemantic() throws {
        let base = try BrushFormatTestSupport.v2Package()
        let changed = try BrushFormatTestSupport.v2Package(
            metadata: BrushMetadata(
                displayName: "Renamed",
                author: "Different Author",
                sourceApplication: "Different Source",
                sourceIdentifier: "different-id"
            )
        )
        #expect(try changed.contentHash == base.contentHash)
    }
}
