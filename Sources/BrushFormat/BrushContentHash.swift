import CryptoKit
import Foundation
import PatternEngine

/// Versioned renderer/cache identity for a native brush.
///
/// Provenance and generated preview metadata are intentionally excluded: they
/// do not alter rendered output. Package equality still includes both through
/// `BrushPackage.Equatable`.
public enum BrushContentHash {
    public static let currentSchemaVersion: UInt16 = 4
    public static let schemaVersion = currentSchemaVersion

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(of package: BrushPackage) throws -> String {
        return try digestOfValidatedPackage(package)
    }

    package static func digestOfValidatedPackage(
        _ package: BrushPackage
    ) throws -> String {
        var writer = CanonicalBrushWriter()
        writer.string("laya.brush.semantic")
        writer.u16(currentSchemaVersion)
        try append(package.definition, to: &writer)
        appendSemanticResources(package, to: &writer)
        return sha256Hex(of: writer.data)
    }

    private static func appendSemanticResources(
        _ package: BrushPackage,
        to writer: inout CanonicalBrushWriter
    ) {
        let semanticResources = package.manifest.resources
            .filter { $0.kind != .preview }
            .sorted { $0.id < $1.id }
        writer.count(semanticResources.count)
        for resource in semanticResources {
            writer.string(resource.id)
            writer.u8(resourceKindTag(resource.kind))
            writer.string(resource.mediaType)
            writer.integer(resource.pixelWidth)
            writer.integer(resource.pixelHeight)
            writer.integer(resource.encodedByteCount)
            writer.string(resource.sha256)
        }
    }

    private static func append(
        _ definition: BrushDefinition,
        to writer: inout CanonicalBrushWriter
    ) throws {
        writer.string(definition.id.rawValue)
        writer.u16(definition.schemaVersion)

        let capabilities = definition.capabilities.sorted {
            $0.identifier < $1.identifier
        }
        writer.count(capabilities.count)
        for capability in capabilities {
            writer.string(capability.identifier)
            writer.boolean(capability.required)
        }

        writer.string(definition.composition.identifier)
        writer.boolean(definition.composition.required)
        writer.count(definition.components.count)
        for component in definition.components {
            try append(component, to: &writer)
        }

        writer.float(definition.stabilization)
        writer.u8(replayModeTag(definition.replayMode))
        append(definition.replayLimits, to: &writer)
        append(
            BrushProgramCompiler.compileTermination(definition),
            to: &writer
        )
        switch definition.seedPolicy {
        case .perStroke:
            writer.u8(0)
        case let .fixed(value):
            writer.u8(1)
            writer.u64(value)
        }
        writer.float(definition.limits.minimumDiameter)
        writer.float(definition.limits.maximumDiameter)
        writer.float(definition.limits.maximumOpacity)
        writer.float(definition.limits.maximumSpacingFraction)
        writer.integer(definition.limits.maximumResourceDimension)
        writer.integer(definition.limits.maximumResidentBytes)
        writer.u8(performanceIntentTag(definition.performanceIntent))
        appendSorted(
            definition.compatibility.requiredSemanticKeys,
            to: &writer
        )
        append(definition.sensorNormalization, to: &writer)
        append(definition.stabilizationV2, to: &writer)
        append(definition.direction, to: &writer)
    }

    private static func append(
        _ component: BrushComponentDefinition,
        to writer: inout CanonicalBrushWriter
    ) throws {
        writer.string(component.identifier.rawValue)
        writer.u8(component.ordinal)
        let resources = component.resources
            .filter { $0.kind != .preview }
            .sorted { $0.identifier < $1.identifier }
        writer.count(resources.count)
        for resource in resources {
            writer.string(resource.identifier)
            writer.u8(resourceKindTag(resource.kind))
            writer.boolean(resource.required)
            switch resource.fallback {
            case nil:
                writer.u8(0)
            case let .builtIn(identifier)?:
                writer.u8(1)
                writer.string(identifier)
            }
        }
        append(component.coverage, to: &writer)
        append(component.placement, to: &writer)
        append(component.dynamics, to: &writer)
        append(component.color, to: &writer)
        append(component.material, to: &writer)
        append(component.taper, to: &writer)
        try append(component.sensorProgram, to: &writer)
        append(component.emission, to: &writer)
        try append(component.tipSupports, to: &writer)
    }

    private static func append(
        _ normalization: BrushSensorNormalizationDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.float(normalization.fullScaleWorldVelocity)
        writer.double(normalization.minimumVelocityDeltaTime)
        writer.double(normalization.fullScaleStrokeAge)
        writer.float(normalization.fullScaleStrokeDistanceInDiameters)
    }

    private static func append(
        _ sensorProgram: BrushSensorProgramDefinition,
        to writer: inout CanonicalBrushWriter
    ) throws {
        for output in BrushDynamicOutput.allCases {
            writer.u8(dynamicOutputTag(output))
            guard let outputProgram = sensorProgram.outputs[output] else {
                throw BrushPackageError.invalidDefinition
            }
            writer.float(outputProgram.baseValue)
            writer.count(outputProgram.terms.count)
            for term in outputProgram.terms {
                writer.u8(dynamicsInputTag(term.input))
                append(term.response, to: &writer)
                writer.boolean(term.inputInverted)
                writer.float(term.missingInputValue)
                writer.float(term.responseScale)
                writer.float(term.responseOffset)
                writer.float(term.responseLowerClamp)
                writer.float(term.responseUpperClamp)
                writer.float(term.jitter)
                writer.u8(responseOperationTag(term.operation))
            }
        }
    }

    private static func append(
        _ stabilization: BrushStabilizationDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        switch stabilization {
        case .none:
            writer.u8(0)
        case let .weightedWindow(distance):
            writer.u8(1); writer.float(distance)
        case let .delayed(distance):
            writer.u8(2); writer.float(distance)
        }
    }

    private static func append(
        _ direction: BrushDirectionDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.float(direction.maximumAngularStep)
        writer.float(direction.stationaryDirection)
    }

    private static func append(
        _ emission: BrushEmissionDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        switch emission.mode {
        case .distance: writer.u8(0)
        case .time: writer.u8(1)
        case .distanceAndTime: writer.u8(2)
        }
        if let interval = emission.timeInterval {
            writer.u8(1); writer.double(interval)
        } else {
            writer.u8(0)
        }
    }

    private static func append(
        _ tipSupports: [BrushTipSupportDefinition],
        to writer: inout CanonicalBrushWriter
    ) throws {
        writer.count(tipSupports.count)
        for support in tipSupports {
            switch support.kind {
            case .analyticEllipse: writer.u8(0)
            case .analyticRectangle: writer.u8(1)
            case .normalizedBounds:
                writer.u8(2)
                guard let bounds = support.bounds else {
                    throw BrushPackageError.invalidDefinition
                }
                writer.float(bounds.minX); writer.float(bounds.maxX)
                writer.float(bounds.minY); writer.float(bounds.maxY)
            }
        }
    }

    private static func append(_ metadata: BrushMetadata, to writer: inout CanonicalBrushWriter) {
        writer.string(metadata.displayName)
        writer.optionalString(metadata.author)
        writer.optionalString(metadata.sourceApplication)
        writer.optionalString(metadata.sourceIdentifier)
    }

    private static func append(
        _ coverage: BrushCoverageDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.count(coverage.shapes.count)
        for shape in coverage.shapes {
            append(shape.shape, to: &writer)
            writer.u8(shapeCombinationTag(shape.combination))
            writer.float(shape.scale)
            writer.float(shape.rotation)
            writer.float(shape.offset.x)
            writer.float(shape.offset.y)
        }
        writer.count(coverage.grains.count)
        for grain in coverage.grains {
            append(grain.grain, to: &writer)
            writer.u8(grainCoordinateTag(grain.coordinateMode))
            writer.float(grain.transform.scale)
            writer.float(grain.transform.rotation)
            writer.float(grain.transform.offset.x)
            writer.float(grain.transform.offset.y)
            writer.float(grain.grainMovementFraction)
            writer.boolean(grain.grainFollowsBrushRotation)
            writer.float(grain.strength)
        }
        writer.float(coverage.baseHardness)
        writer.float(coverage.aspectRatio)
        writer.float(coverage.tipThreshold)
        writer.boolean(coverage.antialiasing)
    }

    private static func append(
        _ placement: BrushPlacementDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.float(placement.baseSpacingFraction)
        writer.float(placement.maximumSpacingFraction)
        writer.float(placement.baseFlow)
        writer.float(placement.strokeOpacity)
        writer.float(placement.baseScatterFraction)
        writer.float(placement.baseRotation)
        writer.float(placement.baseJitterFraction)
        writer.float(placement.baseOffset.x)
        writer.float(placement.baseOffset.y)
    }

    private static func append(
        _ dynamics: BrushDynamicsDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        for mapping in [
            dynamics.size, dynamics.flow, dynamics.opacity, dynamics.spacing,
            dynamics.rotation, dynamics.scatter, dynamics.hardness, dynamics.grain,
            dynamics.offsetX, dynamics.offsetY, dynamics.hue, dynamics.saturation,
            dynamics.brightness, dynamics.secondaryColorMix,
        ] {
            append(mapping, to: &writer)
        }
        writer.float(dynamics.noPressureNeutral)
        writer.float(dynamics.randomization.spacing)
        writer.float(dynamics.randomization.scatter)
        writer.float(dynamics.randomization.rotation)
        writer.float(dynamics.randomization.grain)
        writer.float(dynamics.randomization.material)
    }

    private static func append(
        _ mapping: BrushMappingDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.u8(dynamicsInputTag(mapping.input))
        append(mapping.response, to: &writer)
        writer.float(mapping.scale)
        writer.float(mapping.offset)
        writer.float(mapping.lowerClamp)
        writer.float(mapping.upperClamp)
        writer.boolean(mapping.inverted)
        writer.float(mapping.jitter)
        writer.float(mapping.missingInputValue)
    }

    private static func append(
        _ response: BrushResponseDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        switch response {
        case let .constant(value):
            writer.u8(0)
            writer.float(value)
        case .linear:
            writer.u8(1)
        case let .boundedPower(exponent):
            writer.u8(2)
            writer.float(exponent)
        case let .curve(curve):
            writer.u8(3)
            writer.count(curve.points.count)
            for point in curve.points {
                writer.float(point.x)
                writer.float(point.y)
            }
        }
    }

    private static func append(
        _ color: BrushColorBehaviorDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.float(color.baseAdjustment.redMultiplier)
        writer.float(color.baseAdjustment.greenMultiplier)
        writer.float(color.baseAdjustment.blueMultiplier)
        writer.float(color.baseAdjustment.alphaMultiplier)
        append(color.perStampJitter, to: &writer)
        append(color.perStrokeJitter, to: &writer)
    }

    private static func append(_ jitter: BrushColorJitter, to writer: inout CanonicalBrushWriter) {
        writer.float(jitter.hue)
        writer.float(jitter.saturation)
        writer.float(jitter.brightness)
        writer.float(jitter.secondaryColorMix)
    }

    private static func append(
        _ material: BrushMaterialDefinition,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.u8(accumulationTag(material.accumulation))
        writer.u8(interactionTag(material.interaction))
        writer.u8(edgeTag(material.edgeTreatment))
        writer.float(material.strength)
        writer.float(material.wetness)
        writer.float(material.bleedRadius)
        writer.integer(material.softenPasses)
        writer.float(material.accumulationLimit)
        switch material.interactionParameters {
        case nil:
            writer.u8(0)
        case let parameters?:
            writer.u8(1)
            writer.float(parameters.pickup)
            writer.float(parameters.pull)
            writer.float(parameters.dilution)
            writer.float(parameters.charge)
            writer.float(parameters.persistence)
            writer.float(parameters.dirtyHaloRadius)
        }
    }

    private static func append(
        _ taper: BrushTaperConfiguration,
        to writer: inout CanonicalBrushWriter
    ) {
        append(taper.start, to: &writer)
        append(taper.end, to: &writer)
        writer.float(taper.minimumSize)
        writer.float(taper.minimumFlow)
        writer.u8(taper.effects.rawValue)
    }

    private static func append(
        _ termination: BrushTerminationProgram,
        to writer: inout CanonicalBrushWriter
    ) {
        switch termination {
        case .cap:
            writer.u8(0)
        case let .pressureRelease(maximumWorldLength):
            writer.u8(1)
            writer.float(maximumWorldLength)
        case let .boundedCorrection(
            maximumSamples,
            maximumWorldLength,
            maximumDabs
        ):
            writer.u8(2)
            writer.integer(maximumSamples)
            writer.float(maximumWorldLength)
            writer.integer(maximumDabs)
        }
    }

    private static func append(_ length: BrushTaperLength, to writer: inout CanonicalBrushWriter) {
        switch length {
        case .disabled:
            writer.u8(0)
        case let .worldPixels(value):
            writer.u8(1)
            writer.float(value)
        case let .diameterMultiples(value):
            writer.u8(2)
            writer.float(value)
        }
    }

    private static func append(
        _ limits: BrushReplayLimits?,
        to writer: inout CanonicalBrushWriter
    ) {
        guard let limits else {
            writer.u8(0)
            return
        }
        writer.u8(1)
        writer.integer(limits.maximumSamples)
        writer.integer(limits.maximumDabs)
        writer.integer(limits.maximumProjectedInstances)
    }

    private static func append(
        _ limits: BrushReplayLimits,
        to writer: inout CanonicalBrushWriter
    ) {
        writer.integer(limits.maximumSamples)
        writer.integer(limits.maximumDabs)
        writer.integer(limits.maximumProjectedInstances)
    }

    private static func append(
        _ shape: BrushShapeDescriptor,
        to writer: inout CanonicalBrushWriter
    ) {
        switch shape {
        case .hardRound: writer.u8(0)
        case .softRound: writer.u8(1)
        case .chisel: writer.u8(2)
        case let .asset(identifier):
            writer.u8(3)
            writer.string(identifier)
        }
    }

    private static func append(
        _ grain: BrushGrainDescriptor,
        to writer: inout CanonicalBrushWriter
    ) {
        switch grain {
        case .opaque: writer.u8(0)
        case .paper: writer.u8(1)
        case .noise: writer.u8(2)
        case let .asset(identifier):
            writer.u8(3)
            writer.string(identifier)
        }
    }

    private static func appendSorted(_ values: [String], to writer: inout CanonicalBrushWriter) {
        let sorted = values.sorted()
        writer.count(sorted.count)
        for value in sorted { writer.string(value) }
    }

    private static func resourceKindTag(_ value: BrushResourceKind) -> UInt8 {
        switch value { case .shape: 0; case .grain: 1; case .preview: 2 }
    }

    private static func shapeCombinationTag(_ value: BrushShapeCombinationMode) -> UInt8 {
        switch value { case .replace: 0; case .multiply: 1; case .minimum: 2; case .maximum: 3 }
    }

    private static func grainCoordinateTag(_ value: BrushGrainCoordinateMode) -> UInt8 {
        switch value { case .canonical: 0; case .brushLocal: 1 }
    }

    private static func dynamicsInputTag(_ value: BrushDynamicsInput) -> UInt8 {
        switch value {
        case .pressure: 0
        case .speed: 1
        case .direction: 2
        case .tilt: 3
        case .azimuth: 4
        case .roll: 5
        case .tangentialPressure: 6
        case .age: 7
        case .distance: 8
        case .random: 9
        }
    }

    private static func dynamicOutputTag(_ value: BrushDynamicOutput) -> UInt8 {
        switch value {
        case .size: 0
        case .flow: 1
        case .opacity: 2
        case .spacing: 3
        case .rotation: 4
        case .scatter: 5
        case .hardness: 6
        case .grain: 7
        case .offsetX: 8
        case .offsetY: 9
        case .hue: 10
        case .saturation: 11
        case .brightness: 12
        case .secondaryColorMix: 13
        }
    }

    private static func responseOperationTag(
        _ value: BrushResponseOperation
    ) -> UInt8 {
        switch value {
        case .replace: 0
        case .multiply: 1
        case .add: 2
        case .minimum: 3
        case .maximum: 4
        }
    }

    private static func accumulationTag(_ value: BrushAccumulationMode) -> UInt8 {
        switch value {
        case .opaque: 0
        case .flow: 1
        case .uniformGlaze: 2
        case .intenseGlaze: 3
        case .destinationOut: 4
        }
    }

    private static func interactionTag(_ value: BrushInteractionMode) -> UInt8 {
        switch value { case .none: 0; case .pickup: 1; case .smudge: 2; case .wetMix: 3 }
    }

    private static func edgeTag(_ value: BrushEdgeTreatment) -> UInt8 {
        switch value {
        case .none: 0
        case .dryBreakup: 1
        case .markerOverlap: 2
        case .wetConcentration: 3
        }
    }

    private static func replayModeTag(_ value: BrushReplayMode) -> UInt8 {
        switch value { case .appendOnly: 0; case .replayTail: 1 }
    }

    private static func performanceIntentTag(_ value: BrushPerformanceIntent) -> UInt8 {
        switch value { case .realtime120: 0; case .realtime60: 1; case .quality: 2 }
    }
}

private struct CanonicalBrushWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func u32(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func integer(_ value: Int) {
        u64(UInt64(bitPattern: Int64(value)))
    }

    mutating func count(_ value: Int) {
        integer(value)
    }

    mutating func boolean(_ value: Bool) {
        u8(value ? 1 : 0)
    }

    mutating func float(_ value: Float) {
        u32(value.bitPattern)
    }

    mutating func double(_ value: Double) {
        u64(value.bitPattern)
    }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        u64(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func optionalString(_ value: String?) {
        guard let value else {
            u8(0)
            return
        }
        u8(1)
        string(value)
    }
}
