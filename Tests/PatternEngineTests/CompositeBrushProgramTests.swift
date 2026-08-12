import Testing
@testable import PatternEngine

@Test func compilerBuildsIndependentOrderedComponentPrograms() throws {
    let base = nativeTestDefinition()
    var secondaryOutputs = base.components[0].sensorProgram.outputs
    secondaryOutputs[.spacing] = BrushOutputProgramDefinition(
        baseValue: 2,
        terms: []
    )
    let primary = component(from: base, identifier: "primary", ordinal: 0)
    let secondary = component(
        from: base,
        identifier: "texture",
        ordinal: 1,
        sensorProgram: BrushSensorProgramDefinition(outputs: secondaryOutputs),
        emission: BrushEmissionDefinition(
            mode: .time,
            timeInterval: 1.0 / 120
        )
    )
    let definition = try compositeDefinition(
        from: base,
        components: [primary, secondary]
    )

    let program = try BrushProgramCompiler.compile(definition)

    #expect(program.composition == .orderedSourceOver)
    #expect(program.primaryComponent.definition.identifier.rawValue == "primary")
    #expect(program.primaryComponent.definition.ordinal == 0)
    #expect(program.primaryComponent.stageC.emission == base.components[0].emission)
    let compiledSecondary = try #require(program.secondaryComponent)
    #expect(compiledSecondary.definition.identifier.rawValue == "texture")
    #expect(compiledSecondary.definition.ordinal == 1)
    #expect(compiledSecondary.stageC.emission == secondary.emission)
    #expect(compiledSecondary.stageC.compiledSensorProgram.spacing.baseValue == 2)
    #expect(
        compiledSecondary.stageC.compiledSensorProgram.spacing
            != program.primaryComponent.stageC.compiledSensorProgram.spacing
    )
}

@Test func compilerRejectsUnknownCompositionWithoutSelectingAFallback() throws {
    let base = nativeTestDefinition()
    let primary = component(from: base, identifier: "primary", ordinal: 0)

    let required = try compositeDefinition(
        from: base,
        composition: BrushCompositionModeDeclaration(
            identifier: "future.required-composition",
            required: true
        ),
        components: [primary]
    )
    #expect(throws: BrushProgramCompilerError.unknownRequiredCompositionMode(
        "future.required-composition"
    )) {
        _ = try BrushProgramCompiler.compile(required)
    }

    let optional = try compositeDefinition(
        from: base,
        composition: BrushCompositionModeDeclaration(
            identifier: "future.optional-composition",
            required: false
        ),
        components: [primary]
    )
    #expect(throws: BrushProgramCompilerError.unsupportedCompositionMode(
        "future.optional-composition"
    )) {
        _ = try BrushProgramCompiler.compile(optional)
    }
}

private func component(
    from definition: BrushDefinition,
    identifier: String,
    ordinal: UInt8,
    sensorProgram: BrushSensorProgramDefinition? = nil,
    emission: BrushEmissionDefinition? = nil
) -> BrushComponentDefinition {
    let component = definition.components[0]
    return BrushComponentDefinition(
        identifier: BrushComponentIdentifier(identifier),
        ordinal: ordinal,
        resources: component.resources,
        coverage: component.coverage,
        placement: component.placement,
        dynamics: component.dynamics,
        color: component.color,
        material: component.material,
        taper: component.taper,
        sensorProgram: sensorProgram ?? component.sensorProgram,
        emission: emission ?? component.emission,
        tipSupports: component.tipSupports
    )
}

private func compositeDefinition(
    from definition: BrushDefinition,
    composition: BrushCompositionModeDeclaration = .orderedSourceOver,
    components: [BrushComponentDefinition]
) throws -> BrushDefinition {
    try BrushDefinition(
        id: definition.id,
        metadata: definition.metadata,
        capabilities: definition.capabilities,
        composition: composition,
        components: components,
        stabilization: definition.stabilization,
        replayMode: definition.replayMode,
        replayLimits: definition.replayLimits,
        termination: definition.termination,
        seedPolicy: definition.seedPolicy,
        limits: definition.limits,
        performanceIntent: definition.performanceIntent,
        compatibility: definition.compatibility,
        sensorNormalization: definition.sensorNormalization,
        stabilizationV2: definition.stabilizationV2,
        direction: definition.direction
    )
}
