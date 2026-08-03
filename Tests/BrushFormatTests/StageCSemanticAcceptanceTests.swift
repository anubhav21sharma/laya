import BrushFormat
import Foundation
import PatternEngine
import SafeArchive
import Testing

@Suite("Stage C semantic compatibility acceptance")
struct StageCSemanticAcceptanceTests {
    @Test("frozen schema-v1 package preserves pre-Stage-C semantics")
    func frozenV1PackagePreservesPreStageCSemantics() throws {
        let url = try #require(Bundle.module.url(
            forResource: "stage2-v1",
            withExtension: "layabrush",
            subdirectory: "Fixtures"
        ))
        let archiveData = try Data(contentsOf: url)

        // These values were produced at fbfe5e77, the commit immediately
        // preceding the Stage C schema commit. Never regenerate them from the
        // implementation under test.
        #expect(
            BrushContentHash.sha256Hex(of: archiveData)
                == "12ab63f9c5588ccd7b625ebb41633221d7bc494e7f5fd21dd90f840efffbf98e"
        )

        let archive = try SafeArchiveCodec.open(
            archiveData,
            limits: BrushPackageCodec.archiveLimits
        )
        let frozenDefinitionData = try archive.data(for: "definition.json")
        #expect(
            BrushContentHash.sha256Hex(of: frozenDefinitionData)
                == "1619878df5c45fa61745813c71d7dcb11feaecd8abed0b82033ed8d7220852ad"
        )

        let package = try BrushPackageCodec.decode(archiveData)
        let expectedDefinition = try LegacyBrushRecipeAdapter.definition(
            from: BrushRecipe(id: BrushRecipeID("fixture.stage2-v1")),
            displayName: "Stage 2 V1 Fixture"
        )
        #expect(package.definition == expectedDefinition)
        #expect(package.definition.schemaVersion == 1)
        #expect(package.definition.sensorNormalization == nil)
        #expect(package.definition.sensorProgram == nil)
        #expect(package.definition.stabilizationV2 == nil)
        #expect(package.definition.direction == nil)
        #expect(package.definition.emission == nil)
        #expect(package.definition.tipSupports == nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(package.definition) == frozenDefinitionData)

        let program = try BrushProgramCompiler.compile(package.definition)
        #expect(program.definition == expectedDefinition)
        #expect(program.dynamics.size == .constant(1))
        #expect(program.dynamics.flow == .constant(1))
        #expect(program.dynamics.opacity == .constant(1))
        #expect(program.dynamics.spacing == .constant(1))
        #expect(program.dynamics.rotation == .constant(0))
        #expect(program.dynamics.scatter == .constant(1))
        #expect(program.dynamics.hardness == .constant(1))
        #expect(program.dynamics.grain == .constant(1))
        #expect(program.dynamics.offsetX == .constant(0))
        #expect(program.dynamics.offsetY == .constant(0))
        #expect(program.dynamics.hue == .constant(0))
        #expect(program.dynamics.saturation == .constant(0))
        #expect(program.dynamics.brightness == .constant(0))
        #expect(program.dynamics.secondaryColorMix == .constant(0))
        #expect(program.termination == .legacySchemaV1Cap)
        #expect(program.requiredCapabilities.isEmpty)
        #expect(program.ignoredOptionalCapabilityIdentifiers.isEmpty)
        #expect(program.requestedBackend == .deposition)
        #expect(program.replayContract.mode == .appendOnly)
        #expect(program.replayContract.limits == nil)
        #expect(program.replayContract.maximumWorldLength == nil)
        #expect(program.stageC == nil)

        #expect(
            try package.contentHash
                == "5b9ff4f916d0a20dc1df61ad2b53056fe20b9950ea1e90792b96b5f64e1d0912"
        )

        let dabs = frozenV1Dabs(program: program)
        #expect(dabs.count == 21)
        #expect(
            logicalDigest(dabs)
                == "40c4f8b7acfe363ac984f7a40df9bb7792ce24d497f26d69ec97944fcb1b2f86"
        )
        #expect(
            fullLogicalDigest(dabs)
                == "312dc6011bd6005e6213084869c084f95c16a405b65424d5bd09c530f4cf63ad"
        )
        #expect(
            referenceRasterDigest(dabs)
                == "7a98c6d088ad90de4cf29263de6919732a61ffb4861f12b27c893e1e124a77aa"
        )

        // Read-only decode must not rewrite the checked-in source bytes.
        #expect(try Data(contentsOf: url) == archiveData)
    }

    @Test("schema-v2 semantic field inventory is explicit")
    func v2SemanticFieldInventoryIsExplicit() throws {
        let definition = try BrushFormatTestSupport.v2Definition()
        let normalization = try #require(definition.sensorNormalization)
        let sensorProgram = try #require(definition.sensorProgram)
        let output = try #require(sensorProgram.outputs[.rotation])
        let term = try #require(output.terms.first)
        let direction = try #require(definition.direction)
        let emission = try #require(definition.emission)
        let support = try BrushTipSupportDefinition.normalizedBounds(
            minX: -0.5,
            maxX: 0.5,
            minY: -0.25,
            maxY: 0.25
        )
        let bounds = try #require(support.bounds)

        #expect(storedFieldNames(definition) == [
            "capabilities", "color", "compatibility", "coverage", "direction",
            "dynamics", "emission", "hasLegacySchemaV1Compatibility", "id",
            "limits", "material", "metadata", "performanceIntent", "placement",
            "replayLimits", "replayMode", "resources", "schemaVersion",
            "seedPolicy", "sensorNormalization", "sensorProgram", "stabilization",
            "stabilizationV2", "taper", "termination", "tipSupports",
        ])
        #expect(storedFieldNames(normalization) == [
            "fullScaleStrokeAge", "fullScaleStrokeDistanceInDiameters",
            "fullScaleWorldVelocity", "minimumVelocityDeltaTime",
        ])
        #expect(storedFieldNames(sensorProgram) == ["outputs"])
        #expect(storedFieldNames(output) == ["baseValue", "terms"])
        #expect(storedFieldNames(term) == [
            "input", "inputInverted", "jitter", "missingInputValue", "operation",
            "response", "responseLowerClamp", "responseOffset", "responseScale",
            "responseUpperClamp",
        ])
        #expect(storedFieldNames(direction) == [
            "maximumAngularStep", "stationaryDirection",
        ])
        #expect(storedFieldNames(emission) == ["mode", "timeInterval"])
        #expect(storedFieldNames(support) == ["bounds", "kind"])
        #expect(storedFieldNames(bounds) == ["maxX", "maxY", "minX", "minY"])
        #expect(BrushDynamicOutput.allCases.map(\.rawValue) == [
            "size", "flow", "opacity", "spacing", "rotation", "scatter",
            "hardness", "grain", "offsetX", "offsetY", "hue", "saturation",
            "brightness", "secondaryColorMix",
        ])
        #expect(BrushDynamicsInput.allCases.map(\.rawValue) == [
            "pressure", "speed", "direction", "tilt", "azimuth", "roll",
            "tangentialPressure", "age", "distance", "random",
        ])
    }

    @Test("every normalization and output field changes the v2 digest")
    func everyNormalizationAndOutputFieldChangesV2Digest() throws {
        let baseline = try BrushFormatTestSupport.v2Package()
        #expect(
            try baseline.contentHash
                == "1b50b2ccc39c1a4fd01f897331948eae020bef0aecfe20a814102c6198dbf05c"
        )
        let baselineHash = try baseline.contentHash

        let normalizationMutations: [(String, BrushSensorNormalizationDefinition)] = [
            ("normalization.fullScaleWorldVelocity", .init(
                fullScaleWorldVelocity: 2_001,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 32
            )),
            ("normalization.minimumVelocityDeltaTime", .init(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.002,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 32
            )),
            ("normalization.fullScaleStrokeAge", .init(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 5,
                fullScaleStrokeDistanceInDiameters: 32
            )),
            ("normalization.fullScaleStrokeDistanceInDiameters", .init(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 33
            )),
        ]
        for (name, normalization) in normalizationMutations {
            let changed = try semanticV2Package(normalization: normalization)
            #expect(
                try changed.contentHash != baselineHash,
                Comment(rawValue: name)
            )
        }

        for output in BrushDynamicOutput.allCases {
            var outputs = BrushFormatTestSupport.v2SensorProgram().outputs
            let original = try #require(outputs[output])
            let changedValue: Float = switch output {
            case .opacity: original.baseValue - 0.125
            default: original.baseValue + 0.125
            }
            outputs[output] = BrushOutputProgramDefinition(
                baseValue: changedValue,
                terms: original.terms
            )
            let changed = try semanticV2Package(
                sensorProgram: BrushSensorProgramDefinition(outputs: outputs)
            )
            #expect(
                try changed.contentHash != baselineHash,
                Comment(rawValue: "sensorProgram.\(output.rawValue).baseValue")
            )
        }
    }

    @Test("response tags, payloads, and every term field change the v2 digest")
    func everyResponseAndTermFieldChangesV2Digest() throws {
        var pairs: [DigestPair] = []

        for input in BrushDynamicsInput.allCases where input != .direction {
            pairs.append(try termPair(
                name: "term.input.\(input.rawValue)",
                reference: semanticTerm(input: .direction),
                changed: semanticTerm(input: input)
            ))
        }

        let curve = BrushResponseDefinition.curve(.init(points: [
            .init(x: 0, y: 0), .init(x: 0.5, y: 0.25), .init(x: 1, y: 1),
        ]))
        for (name, response) in [
            ("response.tag.constant", BrushResponseDefinition.constant(0.5)),
            ("response.tag.boundedPower", .boundedPower(exponent: 2)),
            ("response.tag.curve", curve),
        ] {
            pairs.append(try termPair(
                name: name,
                output: .size,
                reference: semanticTerm(input: .pressure, response: .linear),
                changed: semanticTerm(input: .pressure, response: response)
            ))
        }

        pairs += try [
            termPair(
                name: "response.constant.payload",
                output: .size,
                reference: semanticTerm(input: .pressure, response: .constant(0.25)),
                changed: semanticTerm(input: .pressure, response: .constant(0.5))
            ),
            termPair(
                name: "response.boundedPower.exponent",
                output: .size,
                reference: semanticTerm(
                    input: .pressure,
                    response: .boundedPower(exponent: 2)
                ),
                changed: semanticTerm(
                    input: .pressure,
                    response: .boundedPower(exponent: 3)
                )
            ),
            termPair(
                name: "response.curve.point.x",
                output: .size,
                reference: semanticTerm(input: .pressure, response: curve),
                changed: semanticTerm(input: .pressure, response: .curve(.init(points: [
                    .init(x: 0, y: 0), .init(x: 0.6, y: 0.25), .init(x: 1, y: 1),
                ])))
            ),
            termPair(
                name: "response.curve.point.y",
                output: .size,
                reference: semanticTerm(input: .pressure, response: curve),
                changed: semanticTerm(input: .pressure, response: .curve(.init(points: [
                    .init(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 1, y: 1),
                ])))
            ),
            termPair(
                name: "response.curve.pointCount",
                output: .size,
                reference: semanticTerm(input: .pressure, response: curve),
                changed: semanticTerm(input: .pressure, response: .curve(.init(points: [
                    .init(x: 0, y: 0), .init(x: 0.33, y: 0.2),
                    .init(x: 0.66, y: 0.7), .init(x: 1, y: 1),
                ])))
            ),
            termPair(
                name: "term.inputInverted",
                reference: semanticTerm(),
                changed: semanticTerm(inputInverted: true)
            ),
            termPair(
                name: "term.missingInputValue",
                reference: semanticTerm(),
                changed: semanticTerm(missingInputValue: 0.5)
            ),
            termPair(
                name: "term.responseScale",
                reference: semanticTerm(),
                changed: semanticTerm(responseScale: 2)
            ),
            termPair(
                name: "term.responseOffset",
                reference: semanticTerm(),
                changed: semanticTerm(responseOffset: 0.25)
            ),
            termPair(
                name: "term.responseLowerClamp",
                reference: semanticTerm(),
                changed: semanticTerm(responseLowerClamp: -2)
            ),
            termPair(
                name: "term.responseUpperClamp",
                reference: semanticTerm(),
                changed: semanticTerm(responseUpperClamp: 2)
            ),
            termPair(
                name: "term.jitter",
                reference: semanticTerm(),
                changed: semanticTerm(jitter: 0.1)
            ),
        ]

        for operation in semanticOperations where operation != .add {
            pairs.append(try termPair(
                name: "term.operation.\(operation)",
                output: .size,
                reference: semanticTerm(input: .pressure, operation: .add),
                changed: semanticTerm(input: .pressure, operation: operation)
            ))
        }

        let first = semanticTerm(input: .pressure)
        let second = semanticTerm(input: .speed)
        pairs.append(DigestPair(
            name: "output.termCount",
            reference: try semanticV2Package(
                sensorProgram: sensorProgram(output: .rotation, terms: [first])
            ),
            changed: try semanticV2Package(
                sensorProgram: sensorProgram(
                    output: .rotation,
                    terms: [first, second]
                )
            )
        ))
        pairs.append(DigestPair(
            name: "output.termOrder",
            reference: try semanticV2Package(
                sensorProgram: sensorProgram(
                    output: .rotation,
                    terms: [first, second]
                )
            ),
            changed: try semanticV2Package(
                sensorProgram: sensorProgram(
                    output: .rotation,
                    terms: [second, first]
                )
            )
        ))

        #expect(Set(pairs.map(\.name)).count == pairs.count)
        #expect(pairs.count == 30)
        try expectDifferentDigests(pairs)
    }

    @Test("stabilization, direction, emission, and tip fields change identity")
    func remainingV2FieldsChangeDigest() throws {
        let bounds = try BrushTipSupportDefinition.normalizedBounds(
            minX: -0.5,
            maxX: 0.5,
            minY: -0.25,
            maxY: 0.25
        )
        let pairs = try [
            DigestPair(
                name: "stabilization.tag.delayed",
                reference: semanticV2Package(stabilization: .weightedWindow(distance: 8)),
                changed: semanticV2Package(stabilization: .delayed(distance: 8))
            ),
            DigestPair(
                name: "stabilization.tag.none",
                reference: semanticV2Package(stabilization: .weightedWindow(distance: 8)),
                changed: semanticV2Package(
                    stabilization: BrushStabilizationDefinition.none
                )
            ),
            DigestPair(
                name: "stabilization.weightedWindow.distance",
                reference: semanticV2Package(stabilization: .weightedWindow(distance: 8)),
                changed: semanticV2Package(stabilization: .weightedWindow(distance: 9))
            ),
            DigestPair(
                name: "stabilization.delayed.distance",
                reference: semanticV2Package(stabilization: .delayed(distance: 8)),
                changed: semanticV2Package(stabilization: .delayed(distance: 9))
            ),
            DigestPair(
                name: "direction.maximumAngularStep",
                reference: semanticV2Package(direction: .init(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0
                )),
                changed: semanticV2Package(direction: .init(
                    maximumAngularStep: .pi / 5,
                    stationaryDirection: 0
                ))
            ),
            DigestPair(
                name: "direction.stationaryDirection",
                reference: semanticV2Package(direction: .init(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0
                )),
                changed: semanticV2Package(direction: .init(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0.25
                ))
            ),
            DigestPair(
                name: "emission.mode.time",
                reference: semanticV2Package(emission: .init(
                    mode: .distanceAndTime,
                    timeInterval: 1.0 / 120
                )),
                changed: semanticV2Package(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 120
                ))
            ),
            DigestPair(
                name: "emission.mode.distance-and-presence",
                reference: semanticV2Package(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 120
                )),
                changed: semanticV2Package(emission: .init(
                    mode: .distance,
                    timeInterval: nil
                ))
            ),
            DigestPair(
                name: "emission.timeInterval.payload",
                reference: semanticV2Package(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 120
                )),
                changed: semanticV2Package(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 100
                ))
            ),
            DigestPair(
                name: "tip.kind.rectangle",
                reference: semanticV2Package(tipSupports: [.analyticEllipse]),
                changed: semanticV2Package(tipSupports: [.analyticRectangle])
            ),
            DigestPair(
                name: "tip.kind.normalizedBounds",
                reference: semanticV2Package(tipSupports: [.analyticEllipse]),
                changed: semanticV2Package(tipSupports: [bounds])
            ),
            DigestPair(
                name: "tip.bounds.minX",
                reference: semanticV2Package(tipSupports: [bounds]),
                changed: semanticV2Package(tipSupports: [try .normalizedBounds(
                    minX: -0.6, maxX: 0.5, minY: -0.25, maxY: 0.25
                )])
            ),
            DigestPair(
                name: "tip.bounds.maxX",
                reference: semanticV2Package(tipSupports: [bounds]),
                changed: semanticV2Package(tipSupports: [try .normalizedBounds(
                    minX: -0.5, maxX: 0.6, minY: -0.25, maxY: 0.25
                )])
            ),
            DigestPair(
                name: "tip.bounds.minY",
                reference: semanticV2Package(tipSupports: [bounds]),
                changed: semanticV2Package(tipSupports: [try .normalizedBounds(
                    minX: -0.5, maxX: 0.5, minY: -0.35, maxY: 0.25
                )])
            ),
            DigestPair(
                name: "tip.bounds.maxY",
                reference: semanticV2Package(tipSupports: [bounds]),
                changed: semanticV2Package(tipSupports: [try .normalizedBounds(
                    minX: -0.5, maxX: 0.5, minY: -0.25, maxY: 0.35
                )])
            ),
            DigestPair(
                name: "tip.supportCount",
                reference: semanticV2Package(tipSupports: [.analyticEllipse]),
                changed: dualShapeV2Package(
                    tipSupports: [.analyticEllipse, .analyticRectangle]
                )
            ),
            DigestPair(
                name: "tip.supportOrder",
                reference: dualShapeV2Package(
                    tipSupports: [.analyticEllipse, .analyticRectangle]
                ),
                changed: dualShapeV2Package(
                    tipSupports: [.analyticRectangle, .analyticEllipse]
                )
            ),
        ]

        #expect(Set(pairs.map(\.name)).count == pairs.count)
        #expect(pairs.count == 17)
        try expectDifferentDigests(pairs)
    }

    @Test("dictionary insertion and randomized hash order do not change identity")
    func collectionInsertionAndHashOrderDoNotChangeIdentity() throws {
        let expected = try BrushFormatTestSupport.v2Package().contentHash
        let orders: [[BrushDynamicOutput]] = [
            BrushDynamicOutput.allCases,
            Array(BrushDynamicOutput.allCases.reversed()),
            Array(BrushDynamicOutput.allCases.dropFirst())
                + [BrushDynamicOutput.allCases[0]],
            BrushDynamicOutput.allCases.enumerated()
                .filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                + BrushDynamicOutput.allCases.enumerated()
                    .filter { !$0.offset.isMultiple(of: 2) }.map(\.element),
        ]
        let canonicalOutputs = BrushFormatTestSupport.v2SensorProgram().outputs

        for (index, order) in orders.enumerated() {
            var inserted: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
            for output in order {
                inserted[output] = try BrushFormatTestSupport.require(
                    canonicalOutputs[output]
                )
            }
            let package = try semanticV2Package(
                sensorProgram: BrushSensorProgramDefinition(outputs: inserted)
            )
            #expect(
                try package.contentHash == expected,
                Comment(rawValue: "insertion order \(index)")
            )
        }
    }
}

private struct DigestPair {
    let name: String
    let reference: BrushPackage
    let changed: BrushPackage
}

private let semanticOperations: [BrushResponseOperation] = [
    .replace, .multiply, .add, .minimum, .maximum,
]

private func storedFieldNames<T>(_ value: T) -> Set<String> {
    Set(Mirror(reflecting: value).children.compactMap(\.label))
}

private func expectDifferentDigests(_ pairs: [DigestPair]) throws {
    for pair in pairs {
        #expect(
            try pair.reference.contentHash != pair.changed.contentHash,
            Comment(rawValue: pair.name)
        )
    }
}

private func termPair(
    name: String,
    output: BrushDynamicOutput = .rotation,
    reference: BrushResponseTermDefinition,
    changed: BrushResponseTermDefinition
) throws -> DigestPair {
    DigestPair(
        name: name,
        reference: try semanticV2Package(
            sensorProgram: sensorProgram(output: output, terms: [reference])
        ),
        changed: try semanticV2Package(
            sensorProgram: sensorProgram(output: output, terms: [changed])
        )
    )
}

private func semanticTerm(
    input: BrushDynamicsInput = .direction,
    response: BrushResponseDefinition = .linear,
    inputInverted: Bool = false,
    missingInputValue: Float = 0,
    responseScale: Float = 1,
    responseOffset: Float = 0,
    responseLowerClamp: Float = -.pi,
    responseUpperClamp: Float = .pi,
    jitter: Float = 0,
    operation: BrushResponseOperation = .add
) -> BrushResponseTermDefinition {
    BrushResponseTermDefinition(
        input: input,
        response: response,
        inputInverted: inputInverted,
        missingInputValue: missingInputValue,
        responseScale: responseScale,
        responseOffset: responseOffset,
        responseLowerClamp: responseLowerClamp,
        responseUpperClamp: responseUpperClamp,
        jitter: jitter,
        operation: operation
    )
}

private func sensorProgram(
    output: BrushDynamicOutput,
    terms: [BrushResponseTermDefinition]
) throws -> BrushSensorProgramDefinition {
    var outputs = BrushFormatTestSupport.v2SensorProgram().outputs
    let original = try BrushFormatTestSupport.require(outputs[output])
    outputs[output] = BrushOutputProgramDefinition(
        baseValue: original.baseValue,
        terms: terms
    )
    return BrushSensorProgramDefinition(outputs: outputs)
}

private func semanticV2Package(
    normalization: BrushSensorNormalizationDefinition? = nil,
    sensorProgram: BrushSensorProgramDefinition? = nil,
    stabilization: BrushStabilizationDefinition? = nil,
    direction: BrushDirectionDefinition? = nil,
    emission: BrushEmissionDefinition? = nil,
    tipSupports: [BrushTipSupportDefinition]? = nil
) throws -> BrushPackage {
    try BrushFormatTestSupport.v2Package(
        sensorNormalization: normalization,
        sensorProgram: sensorProgram,
        stabilizationV2: stabilization,
        direction: direction,
        emission: emission,
        tipSupports: tipSupports
    )
}

private func dualShapeV2Package(
    tipSupports: [BrushTipSupportDefinition]
) throws -> BrushPackage {
    let package = try BrushFormatTestSupport.v2Package()
    let base = package.definition
    let primary = base.coverage.shapes[0]
    let coverage = BrushCoverageDefinition(
        shapes: [
            primary,
            BrushShapeLayerDefinition(
                shape: .hardRound,
                combination: .multiply,
                scale: 0.75,
                rotation: 0,
                offset: .zero
            ),
        ],
        grains: base.coverage.grains,
        baseHardness: base.coverage.baseHardness,
        aspectRatio: base.coverage.aspectRatio,
        tipThreshold: base.coverage.tipThreshold,
        antialiasing: base.coverage.antialiasing
    )
    let definition = try BrushDefinition(
        v2ID: base.id,
        metadata: base.metadata,
        capabilities: [BrushCapabilityDeclaration(
            identifier: BrushCapability.dualShape.rawValue,
            required: true
        )],
        resources: base.resources,
        coverage: coverage,
        placement: base.placement,
        dynamics: base.dynamics,
        color: base.color,
        material: base.material,
        stabilization: base.stabilization,
        taper: base.taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: base.termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility,
        sensorNormalization: try #require(base.sensorNormalization),
        sensorProgram: try #require(base.sensorProgram),
        stabilizationV2: try #require(base.stabilizationV2),
        direction: try #require(base.direction),
        emission: try #require(base.emission),
        tipSupports: tipSupports
    )
    return try BrushPackage(
        manifest: package.manifest,
        definition: definition,
        resourceData: package.resourceData
    )
}

private func frozenV1Dabs(program: BrushProgram) -> [DabAttributes] {
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
    return dabs
}

private func logicalDigest(_ dabs: [DabAttributes]) -> String {
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
    return BrushContentHash.sha256Hex(of: Data(trace.utf8))
}

/// Covers every public logical-dab field, including transforms, material
/// inputs, random words, and conservative bounds. The shorter digest above is
/// retained because it was the first Stage C compatibility trace.
private func fullLogicalDigest(_ dabs: [DabAttributes]) -> String {
    func bits(_ value: Float) -> String { String(value.bitPattern) }
    func affine(_ value: Affine2D?) -> [String] {
        guard let value else { return ["nil"] }
        return [
            "some", bits(value.xAxis.x), bits(value.xAxis.y),
            bits(value.yAxis.x), bits(value.yAxis.y),
            bits(value.translation.x), bits(value.translation.y),
        ]
    }
    let records = dabs.map { dab -> String in
        let compatibility = dab.randomValues.compatibility
        let material = dab.materialInputs
        var fields = [
            bits(dab.position.x), bits(dab.position.y),
        ] + affine(dab.brushToWorld) + [
            bits(dab.radius), bits(dab.diameter), bits(dab.spacing),
            bits(dab.flow), bits(dab.strokeOpacity), bits(dab.rotation),
            bits(dab.scatter.x), bits(dab.scatter.y),
            bits(dab.hardness), bits(dab.grainOffset.x),
            bits(dab.grainOffset.y), bits(dab.grainScale),
            bits(dab.grainRotation), bits(dab.color.red),
            bits(dab.color.green), bits(dab.color.blue), bits(dab.color.alpha),
            bits(dab.colorAdjustment.redMultiplier),
            bits(dab.colorAdjustment.greenMultiplier),
            bits(dab.colorAdjustment.blueMultiplier),
            bits(dab.colorAdjustment.alphaMultiplier),
            bits(dab.secondaryColorMix), String(dab.materialFamily.rawValue),
            bits(dab.materialContribution), bits(dab.sourceDistance),
            String(dab.ordinal), String(dab.isPredicted),
        ]
        fields += affine(dab.primaryGrainToWorld)
        fields += affine(dab.secondaryGrainToWorld)
        fields += [
            material.accumulation.rawValue, material.interaction.rawValue,
            material.edgeTreatment.rawValue, bits(material.strength),
            bits(material.wetness), bits(material.bleedRadius),
            bits(material.accumulationLimit),
            material.interactionParameters == nil ? "nil" : "some",
            bits(compatibility.spacing), bits(compatibility.scatterX),
            bits(compatibility.scatterY), bits(compatibility.rotation),
            bits(compatibility.grainX), bits(compatibility.grainY),
            bits(compatibility.materialVariation), bits(dab.randomValues.size),
            bits(dab.randomValues.flow), bits(dab.randomValues.opacity),
            bits(dab.randomValues.hardness), bits(dab.randomValues.offsetX),
            bits(dab.randomValues.offsetY), bits(dab.randomValues.hue),
            bits(dab.randomValues.saturation), bits(dab.randomValues.brightness),
            bits(dab.randomValues.secondaryColorMix),
            bits(dab.worldBounds.minimum.x), bits(dab.worldBounds.minimum.y),
            bits(dab.worldBounds.maximum.x), bits(dab.worldBounds.maximum.y),
        ]
        return fields.joined(separator: ":")
    }
    return BrushContentHash.sha256Hex(
        of: Data(records.joined(separator: "|").utf8)
    )
}

/// Independent deterministic alpha raster for the fixture's one hard-round
/// shape. It deliberately does not reuse the renderer or semantic hash writer.
private func referenceRasterDigest(_ dabs: [DabAttributes]) -> String {
    var raster = [UInt8](repeating: 0, count: 64 * 64)
    for dab in dabs {
        let coverage = TilingCoverageOracle.renderCanonical(
            footprint: .hardRound(radius: 1),
            brushToWorld: dab.brushToWorld,
            tileSize: PixelSize(width: 64, height: 64),
            tiling: .grid,
            supersampling: 4
        ).coverage.bytes
        for index in raster.indices {
            let source = Int(coverage[index])
            let destination = Int(raster[index])
            raster[index] = UInt8(
                255 - ((255 - destination) * (255 - source) + 127) / 255
            )
        }
    }
    return BrushContentHash.sha256Hex(of: Data(raster))
}
