import PatternEngine
@testable import MetalRenderer
import Testing

@Suite("Brush backend registry")
struct BrushBackendRegistryTests {
    @Test
    func nativeSchemaThreeTableRejectsTheRetiredNativeDefinitionVersion() throws {
        let registry = BrushBackendRegistry.nativeSchema3

        #expect(registry.registrations.map(\.key) == [
            BrushBackendRegistryKey(
                kind: .canvasInteraction,
                schemaVersion: 3
            ),
            BrushBackendRegistryKey(kind: .deposition, schemaVersion: 3),
        ])
        #expect(throws: BrushBackendRegistryError.unsupportedSchema(
            kind: .deposition,
            requested: 2,
            supported: [3]
        )) {
            _ = try registry.registration(for: .deposition, schemaVersion: 2)
        }
    }

    @Test
    func duplicateExactKeyIsRejectedInsteadOfSelectingOneRegistration() {
        let entry = registration(kind: .deposition, schemaVersion: 2)

        #expect(throws: BrushBackendRegistryError.duplicateRegistration(
            BrushBackendRegistryKey(kind: .deposition, schemaVersion: 2)
        )) {
            _ = try BrushBackendRegistry(registrations: [entry, entry])
        }
    }

    @Test
    func absentKindAndUnsupportedVersionHaveDifferentTypedFailures() throws {
        let registry = try BrushBackendRegistry(registrations: [
            registration(kind: .deposition, schemaVersion: 2),
        ])

        #expect(throws: BrushBackendRegistryError.unknownBackend(
            kind: .canvasInteraction,
            schemaVersion: 2
        )) {
            _ = try registry.registration(
                for: .canvasInteraction,
                schemaVersion: 2
            )
        }
        #expect(throws: BrushBackendRegistryError.unsupportedSchema(
            kind: .deposition,
            requested: 3,
            supported: [2]
        )) {
            _ = try registry.registration(for: .deposition, schemaVersion: 3)
        }
    }

    @Test
    func publishedRegistrationsHaveLiteralDeterministicOrder() throws {
        let registry = try BrushBackendRegistry(registrations: [
            registration(kind: .deposition, schemaVersion: 3),
            registration(kind: .deposition, schemaVersion: 2),
            registration(kind: .canvasInteraction, schemaVersion: 2),
        ])

        #expect(registry.registrations.map(\.key) == [
            BrushBackendRegistryKey(
                kind: .canvasInteraction,
                schemaVersion: 2
            ),
            BrushBackendRegistryKey(kind: .deposition, schemaVersion: 2),
            BrushBackendRegistryKey(kind: .deposition, schemaVersion: 3),
        ])
    }

    @Test
    func implementedCapabilityMustAlsoBeDeclared() {
        let key = BrushBackendRegistryKey(
            kind: .deposition,
            schemaVersion: 2
        )
        let invalid = BrushBackendRegistration(
            key: key,
            compilerFamily: .deposition,
            encoderFamily: .instancedDeposition,
            declaredCapabilities: [],
            implementedCapabilities: [.secondaryColorSource],
            activation: .available
        )

        #expect(
            throws: BrushBackendRegistryError
                .implementedCapabilitiesNotDeclared(key)
        ) {
            _ = try BrushBackendRegistry(registrations: [invalid])
        }
    }

    @Test
    func nativeSchemaThreeTableIsExactAndContinuousRibbonIsInternalOnly() throws {
        let registry = BrushBackendRegistry.nativeSchema3

        #expect(registry.registrations.map(\.key) == [
            BrushBackendRegistryKey(
                kind: .canvasInteraction,
                schemaVersion: 3
            ),
            BrushBackendRegistryKey(kind: .deposition, schemaVersion: 3),
        ])

        let canvas = try registry.registration(
            for: .canvasInteraction,
            schemaVersion: 3
        )
        #expect(canvas.compilerFamily == .continuousRibbon)
        #expect(canvas.encoderFamily == .continuousRibbon)
        #expect(canvas.declaredCapabilities == [.destinationSampling])
        #expect(canvas.implementedCapabilities.isEmpty)
        #expect(canvas.activation == .internalOnly)

        let deposition = try registry.registration(
            for: .deposition,
            schemaVersion: 3
        )
        #expect(deposition.compilerFamily == .deposition)
        #expect(deposition.encoderFamily == .instancedDeposition)
        #expect(deposition.declaredCapabilities.isEmpty)
        #expect(deposition.implementedCapabilities.isEmpty)
        #expect(deposition.activation == .available)

        #expect(throws: BrushBackendRegistryError.unsupportedSchema(
            kind: .deposition,
            requested: 1,
            supported: [3]
        )) {
            _ = try registry.registration(for: .deposition, schemaVersion: 1)
        }
        #expect(throws: BrushBackendRegistryError.unsupportedSchema(
            kind: .deposition,
            requested: 2,
            supported: [3]
        )) {
            _ = try registry.registration(for: .deposition, schemaVersion: 2)
        }
    }

    @Test
    func compilerProducesTheTypedSchemaThreeDepositionContract() throws {
        let compiler = BrushBackendCompiler(
            registry: .nativeSchema3
        )
        let dry = try backendProgram(id: "builtin.native-ink")

        let dryContract = try compiler.compile(
            program: dry,
            forActivation: true
        )
        guard case let .deposition(deposition) = dryContract else {
            Issue.record("Dry program did not select deposition")
            return
        }
        #expect(deposition.schemaVersion == 3)
        #expect(deposition.compilerFamily == .deposition)
        #expect(deposition.encoderFamily == .instancedDeposition)
    }

    @Test
    func retiredNativeAliasFailsWhileCurrentAndImportedIDsCompile() throws {
        let compiler = BrushBackendCompiler(registry: .nativeSchema3)

        #expect(throws: BrushBackendCompilationError.retiredNativeIdentifier(
            "builtin.bounded-wash"
        )) {
            _ = try compiler.compile(
                program: try backendProgram(id: "builtin.bounded-wash"),
                forActivation: true
            )
        }

        _ = try compiler.compile(
            program: try backendProgram(id: "builtin.native-ink"),
            forActivation: true
        )
        _ = try compiler.compile(
            program: try backendProgram(id: "imported.custom-dry"),
            forActivation: true
        )
    }

    @Test
    func requiredSemanticAndDepositionMaterialFailuresAreTyped() throws {
        let compiler = BrushBackendCompiler(registry: .nativeSchema3)

        #expect(throws: BrushBackendCompilationError.unsupportedRequiredSemantic(
            "foreign.alpha"
        )) {
            _ = try compiler.compile(
                program: try backendProgram(
                    id: "imported.semantic",
                    requiredSemanticKeys: ["foreign.alpha", "foreign.zeta"]
                ),
                forActivation: true
            )
        }
        #expect(throws: BrushBackendCompilationError.unsupportedEdgeTreatment(
            .wetConcentration
        )) {
            _ = try compiler.compile(
                program: try backendProgram(
                    id: "imported.wet-edge",
                    edgeTreatment: .wetConcentration
                ),
                forActivation: true
            )
        }
    }

    @Test
    func anyPossibleSecondaryColorUseRequiresImplementedColorSource() throws {
        let compiler = BrushBackendCompiler(registry: .nativeSchema3)
        let positiveOutputs: [(String, BrushOutputProgramDefinition)] = [
            ("base", BrushOutputProgramDefinition(baseValue: 0.25, terms: [])),
            ("replace", BrushOutputProgramDefinition(
                baseValue: 0,
                terms: [responseTerm(
                    lowerClamp: 0.25,
                    upperClamp: 0.25,
                    operation: .replace
                )]
            )),
            ("add", BrushOutputProgramDefinition(
                baseValue: 0,
                terms: [responseTerm(
                    lowerClamp: 0.25,
                    upperClamp: 0.25,
                    operation: .add
                )]
            )),
            ("multiply-signed", BrushOutputProgramDefinition(
                baseValue: 0,
                terms: [
                    responseTerm(
                        lowerClamp: -1,
                        upperClamp: -1,
                        operation: .replace
                    ),
                    responseTerm(
                        lowerClamp: -1,
                        upperClamp: -1,
                        operation: .multiply
                    ),
                ]
            )),
            ("minimum", BrushOutputProgramDefinition(
                baseValue: 1,
                terms: [responseTerm(
                    lowerClamp: 0.25,
                    upperClamp: 0.25,
                    operation: .minimum
                )]
            )),
            ("maximum", BrushOutputProgramDefinition(
                baseValue: 0,
                terms: [responseTerm(
                    lowerClamp: 0.25,
                    upperClamp: 0.25,
                    operation: .maximum
                )]
            )),
        ]

        for (label, output) in positiveOutputs {
            #expect(throws: BrushBackendCompilationError
                .missingImplementedCapability(.secondaryColorSource)) {
                _ = try compiler.compile(
                    program: try backendProgram(
                        id: "imported.secondary-\(label)",
                        secondaryColorOutput: output
                    ),
                    forActivation: true
                )
            }
        }
        #expect(throws: BrushBackendCompilationError
            .missingImplementedCapability(.secondaryColorSource)) {
            _ = try compiler.compile(
                program: try backendProgram(
                    id: "imported.secondary-stamp-jitter",
                    perStampSecondaryColorMix: 0.1
                ),
                forActivation: true
            )
        }
        #expect(throws: BrushBackendCompilationError
            .missingImplementedCapability(.secondaryColorSource)) {
            _ = try compiler.compile(
                program: try backendProgram(
                    id: "imported.secondary-stroke-jitter",
                    perStrokeSecondaryColorMix: 0.1
                ),
                forActivation: true
            )
        }
    }

    @Test
    func secondaryComponentSemanticsAreValidatedBeforeActivation() throws {
        let base = try stageCMetalBaseDefinition(id: "imported.composite")
        var outputs = base.components[0].sensorProgram.outputs
        outputs[.secondaryColorMix] = BrushOutputProgramDefinition(
            baseValue: 0.25,
            terms: []
        )
        func component(
            identifier: String,
            ordinal: UInt8,
            sensorProgram: BrushSensorProgramDefinition
        ) -> BrushComponentDefinition {
            BrushComponentDefinition(
                identifier: BrushComponentIdentifier(identifier),
                ordinal: ordinal,
                resources: base.components[0].resources,
                coverage: base.components[0].coverage,
                placement: base.components[0].placement,
                dynamics: base.components[0].dynamics,
                color: base.components[0].color,
                material: base.components[0].material,
                taper: base.components[0].taper,
                sensorProgram: sensorProgram,
                emission: base.components[0].emission,
                tipSupports: base.components[0].tipSupports
            )
        }
        let definition = try BrushDefinition(
            id: base.id,
            metadata: base.metadata,
            capabilities: base.capabilities,
            composition: .orderedSourceOver,
            components: [
                component(
                    identifier: "primary",
                    ordinal: 0,
                    sensorProgram: base.components[0].sensorProgram
                ),
                component(
                    identifier: "texture",
                    ordinal: 1,
                    sensorProgram: BrushSensorProgramDefinition(
                        outputs: outputs
                    )
                ),
            ],
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

        #expect(throws: BrushBackendCompilationError
            .missingImplementedCapability(.secondaryColorSource)) {
            _ = try BrushBackendCompiler(registry: .nativeSchema3).compile(
                program: BrushProgramCompiler.compile(definition),
                forActivation: true
            )
        }
    }

    @Test
    func provablyZeroSecondaryColorTermsRemainSupported() throws {
        let compiler = BrushBackendCompiler(registry: .nativeSchema3)
        let fixtures: [(BrushResponseOperation, Float)] = [
            (.replace, 0),
            (.add, 0),
            (.multiply, 1),
            (.minimum, 1),
            (.maximum, 0),
        ]

        for (operation, value) in fixtures {
            let output = BrushOutputProgramDefinition(
                baseValue: 0,
                terms: [responseTerm(
                    lowerClamp: value,
                    upperClamp: value,
                    operation: operation
                )]
            )
            _ = try compiler.compile(
                program: try backendProgram(
                    id: "imported.zero-\(operation.rawValue)",
                    secondaryColorOutput: output
                ),
                forActivation: true
            )
        }
    }

    private func registration(
        kind: BrushBackendKind,
        schemaVersion: UInt16
    ) -> BrushBackendRegistration {
        BrushBackendRegistration(
            key: BrushBackendRegistryKey(
                kind: kind,
                schemaVersion: schemaVersion
            ),
            compilerFamily: kind == .deposition
                ? .deposition
                : .continuousRibbon,
            encoderFamily: kind == .deposition
                ? .instancedDeposition
                : .continuousRibbon,
            declaredCapabilities: [],
            implementedCapabilities: [],
            activation: .available
        )
    }

    private func responseTerm(
        lowerClamp: Float,
        upperClamp: Float,
        operation: BrushResponseOperation
    ) -> BrushResponseTermDefinition {
        let usesNegativeClamp = lowerClamp < 0 || upperClamp < 0
        return BrushResponseTermDefinition(
            input: .pressure,
            response: usesNegativeClamp ? .linear : .constant(lowerClamp),
            inputInverted: false,
            missingInputValue: 1,
            responseScale: usesNegativeClamp ? 0 : 1,
            responseOffset: usesNegativeClamp ? lowerClamp : 0,
            responseLowerClamp: lowerClamp,
            responseUpperClamp: upperClamp,
            jitter: 0,
            operation: operation
        )
    }

    private func backendProgram(
        id: String,
        interaction: BrushInteractionMode = .none,
        edgeTreatment: BrushEdgeTreatment = .none,
        requiredSemanticKeys: [String] = [],
        secondaryColorOutput: BrushOutputProgramDefinition? = nil,
        perStampSecondaryColorMix: Float = 0,
        perStrokeSecondaryColorMix: Float = 0
    ) throws -> BrushProgram {
        let base = try stageCMetalBaseDefinition(id: id)
        var outputs = base.components[0].sensorProgram.outputs
        if let secondaryColorOutput {
            outputs[.secondaryColorMix] = secondaryColorOutput
        }
        let capability: BrushCapability? = switch interaction {
        case .none: nil
        case .pickup: .canvasInteraction
        case .smudge: .smudge
        case .wetMix: .wetMix
        }
        let capabilities = capability.map {
            [BrushCapabilityDeclaration(
                identifier: $0.rawValue,
                required: true
            )]
        } ?? []
        let material = BrushMaterialDefinition(
            accumulation: base.components[0].material.accumulation,
            interaction: interaction,
            edgeTreatment: edgeTreatment,
            strength: base.components[0].material.strength,
            wetness: base.components[0].material.wetness,
            bleedRadius: base.components[0].material.bleedRadius,
            softenPasses: base.components[0].material.softenPasses,
            accumulationLimit: base.components[0].material.accumulationLimit,
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
        let definition = try BrushDefinition(
            id: BrushRecipeID(id),
            metadata: base.metadata,
            capabilities: capabilities,
            resources: base.components[0].resources,
            coverage: base.components[0].coverage,
            placement: base.components[0].placement,
            dynamics: base.components[0].dynamics,
            color: BrushColorBehaviorDefinition(
                baseAdjustment: base.components[0].color.baseAdjustment,
                perStampJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: perStampSecondaryColorMix
                ),
                perStrokeJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: perStrokeSecondaryColorMix
                )
            ),
            material: material,
            stabilization: base.stabilization,
            taper: base.components[0].taper,
            replayMode: base.replayMode,
            replayLimits: base.replayLimits,
            termination: base.termination,
            seedPolicy: base.seedPolicy,
            limits: base.limits,
            performanceIntent: base.performanceIntent,
            compatibility: BrushCompatibilityMetadata(
                sourceSettingKeys: [],
                requiredSemanticKeys: requiredSemanticKeys
            ),
            sensorNormalization: base.sensorNormalization,
            sensorProgram: BrushSensorProgramDefinition(outputs: outputs),
            stabilizationV2: base.stabilizationV2,
            direction: base.direction,
            emission: base.components[0].emission,
            tipSupports: base.components[0].tipSupports
        )
        return try BrushProgramCompiler.compile(definition)
    }
}
