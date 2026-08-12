import BrushFormat
import Foundation
import PatternEngine
import Testing

@Suite("Stage C semantic compatibility acceptance")
struct StageCSemanticAcceptanceTests {
    @Test("schema-3 semantic field inventory is explicit")
    func schemaThreeSemanticFieldInventoryIsExplicit() throws {
        let definition = try BrushFormatTestSupport.currentDefinition()
        let component = definition.components[0]
        let normalization = definition.sensorNormalization
        let sensorProgram = component.sensorProgram
        let output = try #require(sensorProgram.outputs[.rotation])
        let term = try #require(output.terms.first)
        let direction = definition.direction
        let emission = component.emission
        let support = try BrushTipSupportDefinition.normalizedBounds(
            minX: -0.5,
            maxX: 0.5,
            minY: -0.25,
            maxY: 0.25
        )
        let bounds = try #require(support.bounds)

        #expect(storedFieldNames(definition) == [
            "capabilities", "compatibility", "components", "composition",
            "direction", "id", "limits", "metadata", "performanceIntent",
            "replayLimits", "replayMode", "schemaVersion", "seedPolicy",
            "sensorNormalization", "stabilization", "stabilizationV2",
            "termination",
        ])
        #expect(storedFieldNames(component) == [
            "color", "coverage", "dynamics", "emission", "identifier",
            "material", "ordinal", "placement", "resources", "sensorProgram",
            "taper", "tipSupports",
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

    @Test("every normalization and output field changes the schema-3 digest")
    func everyNormalizationAndOutputFieldChangesSchemaThreeDigest() throws {
        let baseline = try BrushFormatTestSupport.currentPackage()
        #expect(
            try baseline.contentHash
                == "16cc347463c824ecb491b2b1d6ff923134e4435a4283dabb5da9b2e4acf4f64f"
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
            let changed = try semanticCurrentPackage(normalization: normalization)
            #expect(
                try changed.contentHash != baselineHash,
                Comment(rawValue: name)
            )
        }

        for output in BrushDynamicOutput.allCases {
            var outputs = BrushFormatTestSupport.currentSensorProgram().outputs
            let original = try #require(outputs[output])
            let changedValue: Float = switch output {
            case .opacity: original.baseValue - 0.125
            default: original.baseValue + 0.125
            }
            outputs[output] = BrushOutputProgramDefinition(
                baseValue: changedValue,
                terms: original.terms
            )
            let changed = try semanticCurrentPackage(
                sensorProgram: BrushSensorProgramDefinition(outputs: outputs)
            )
            #expect(
                try changed.contentHash != baselineHash,
                Comment(rawValue: "sensorProgram.\(output.rawValue).baseValue")
            )
        }
    }

    @Test("response tags, payloads, and every term field change the schema-3 digest")
    func everyResponseAndTermFieldChangesSchemaThreeDigest() throws {
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
            reference: try semanticCurrentPackage(
                sensorProgram: sensorProgram(output: .rotation, terms: [first])
            ),
            changed: try semanticCurrentPackage(
                sensorProgram: sensorProgram(
                    output: .rotation,
                    terms: [first, second]
                )
            )
        ))
        pairs.append(DigestPair(
            name: "output.termOrder",
            reference: try semanticCurrentPackage(
                sensorProgram: sensorProgram(
                    output: .rotation,
                    terms: [first, second]
                )
            ),
            changed: try semanticCurrentPackage(
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
    func remainingSchemaThreeFieldsChangeDigest() throws {
        let bounds = try BrushTipSupportDefinition.normalizedBounds(
            minX: -0.5,
            maxX: 0.5,
            minY: -0.25,
            maxY: 0.25
        )
        let pairs = try [
            DigestPair(
                name: "stabilization.tag.delayed",
                reference: semanticCurrentPackage(stabilization: .weightedWindow(distance: 8)),
                changed: semanticCurrentPackage(stabilization: .delayed(distance: 8))
            ),
            DigestPair(
                name: "stabilization.tag.none",
                reference: semanticCurrentPackage(stabilization: .weightedWindow(distance: 8)),
                changed: semanticCurrentPackage(
                    stabilization: BrushStabilizationDefinition.none
                )
            ),
            DigestPair(
                name: "stabilization.weightedWindow.distance",
                reference: semanticCurrentPackage(stabilization: .weightedWindow(distance: 8)),
                changed: semanticCurrentPackage(stabilization: .weightedWindow(distance: 9))
            ),
            DigestPair(
                name: "stabilization.delayed.distance",
                reference: semanticCurrentPackage(stabilization: .delayed(distance: 8)),
                changed: semanticCurrentPackage(stabilization: .delayed(distance: 9))
            ),
            DigestPair(
                name: "direction.maximumAngularStep",
                reference: semanticCurrentPackage(direction: .init(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0
                )),
                changed: semanticCurrentPackage(direction: .init(
                    maximumAngularStep: .pi / 5,
                    stationaryDirection: 0
                ))
            ),
            DigestPair(
                name: "direction.stationaryDirection",
                reference: semanticCurrentPackage(direction: .init(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0
                )),
                changed: semanticCurrentPackage(direction: .init(
                    maximumAngularStep: .pi / 6,
                    stationaryDirection: 0.25
                ))
            ),
            DigestPair(
                name: "emission.mode.time",
                reference: semanticCurrentPackage(emission: .init(
                    mode: .distanceAndTime,
                    timeInterval: 1.0 / 120
                )),
                changed: semanticCurrentPackage(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 120
                ))
            ),
            DigestPair(
                name: "emission.mode.distance-and-presence",
                reference: semanticCurrentPackage(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 120
                )),
                changed: semanticCurrentPackage(emission: .init(
                    mode: .distance,
                    timeInterval: nil
                ))
            ),
            DigestPair(
                name: "emission.timeInterval.payload",
                reference: semanticCurrentPackage(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 120
                )),
                changed: semanticCurrentPackage(emission: .init(
                    mode: .time,
                    timeInterval: 1.0 / 100
                ))
            ),
            DigestPair(
                name: "tip.kind.rectangle",
                reference: semanticCurrentPackage(tipSupports: [.analyticEllipse]),
                changed: semanticCurrentPackage(tipSupports: [.analyticRectangle])
            ),
            DigestPair(
                name: "tip.kind.normalizedBounds",
                reference: semanticCurrentPackage(tipSupports: [.analyticEllipse]),
                changed: semanticCurrentPackage(tipSupports: [bounds])
            ),
            DigestPair(
                name: "tip.bounds.minX",
                reference: semanticCurrentPackage(tipSupports: [bounds]),
                changed: semanticCurrentPackage(tipSupports: [try .normalizedBounds(
                    minX: -0.6, maxX: 0.5, minY: -0.25, maxY: 0.25
                )])
            ),
            DigestPair(
                name: "tip.bounds.maxX",
                reference: semanticCurrentPackage(tipSupports: [bounds]),
                changed: semanticCurrentPackage(tipSupports: [try .normalizedBounds(
                    minX: -0.5, maxX: 0.6, minY: -0.25, maxY: 0.25
                )])
            ),
            DigestPair(
                name: "tip.bounds.minY",
                reference: semanticCurrentPackage(tipSupports: [bounds]),
                changed: semanticCurrentPackage(tipSupports: [try .normalizedBounds(
                    minX: -0.5, maxX: 0.5, minY: -0.35, maxY: 0.25
                )])
            ),
            DigestPair(
                name: "tip.bounds.maxY",
                reference: semanticCurrentPackage(tipSupports: [bounds]),
                changed: semanticCurrentPackage(tipSupports: [try .normalizedBounds(
                    minX: -0.5, maxX: 0.5, minY: -0.25, maxY: 0.35
                )])
            ),
            DigestPair(
                name: "tip.supportCount",
                reference: semanticCurrentPackage(tipSupports: [.analyticEllipse]),
                changed: dualShapeCurrentPackage(
                    tipSupports: [.analyticEllipse, .analyticRectangle]
                )
            ),
            DigestPair(
                name: "tip.supportOrder",
                reference: dualShapeCurrentPackage(
                    tipSupports: [.analyticEllipse, .analyticRectangle]
                ),
                changed: dualShapeCurrentPackage(
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
        let expected = try BrushFormatTestSupport.currentPackage().contentHash
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
        let canonicalOutputs = BrushFormatTestSupport.currentSensorProgram().outputs

        for (index, order) in orders.enumerated() {
            var inserted: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
            for output in order {
                inserted[output] = try BrushFormatTestSupport.require(
                    canonicalOutputs[output]
                )
            }
            let package = try semanticCurrentPackage(
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
        reference: try semanticCurrentPackage(
            sensorProgram: sensorProgram(output: output, terms: [reference])
        ),
        changed: try semanticCurrentPackage(
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
    var outputs = BrushFormatTestSupport.currentSensorProgram().outputs
    let original = try BrushFormatTestSupport.require(outputs[output])
    outputs[output] = BrushOutputProgramDefinition(
        baseValue: original.baseValue,
        terms: terms
    )
    return BrushSensorProgramDefinition(outputs: outputs)
}

private func semanticCurrentPackage(
    normalization: BrushSensorNormalizationDefinition? = nil,
    sensorProgram: BrushSensorProgramDefinition? = nil,
    stabilization: BrushStabilizationDefinition? = nil,
    direction: BrushDirectionDefinition? = nil,
    emission: BrushEmissionDefinition? = nil,
    tipSupports: [BrushTipSupportDefinition]? = nil
) throws -> BrushPackage {
    try BrushFormatTestSupport.currentPackage(
        sensorNormalization: normalization,
        sensorProgram: sensorProgram,
        stabilizationV2: stabilization,
        direction: direction,
        emission: emission,
        tipSupports: tipSupports
    )
}

private func dualShapeCurrentPackage(
    tipSupports: [BrushTipSupportDefinition]
) throws -> BrushPackage {
    let package = try BrushFormatTestSupport.currentPackage()
    let base = package.definition
    let component = base.components[0]
    let primary = component.coverage.shapes[0]
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
        grains: component.coverage.grains,
        baseHardness: component.coverage.baseHardness,
        aspectRatio: component.coverage.aspectRatio,
        tipThreshold: component.coverage.tipThreshold,
        antialiasing: component.coverage.antialiasing
    )
    let definition = try BrushDefinition(
        id: base.id,
        metadata: base.metadata,
        capabilities: [BrushCapabilityDeclaration(
            identifier: BrushCapability.dualShape.rawValue,
            required: true
        )],
        resources: component.resources,
        coverage: coverage,
        placement: component.placement,
        dynamics: component.dynamics,
        color: component.color,
        material: component.material,
        stabilization: base.stabilization,
        taper: component.taper,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: base.termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility,
        sensorNormalization: base.sensorNormalization,
        sensorProgram: component.sensorProgram,
        stabilizationV2: base.stabilizationV2,
        direction: base.direction,
        emission: component.emission,
        tipSupports: tipSupports
    )
    return try BrushPackage(
        manifest: package.manifest,
        definition: definition,
        resourceData: package.resourceData
    )
}
