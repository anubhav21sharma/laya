import BrushFormat
import Foundation
import PatternEngine
import SafeArchive

enum BrushFormatTestSupport {
    static let shapeID = "builtin.shape.hard-round"

    static func fixturePNG() throws -> Data {
        let url = try require(
            Bundle.module.url(
                forResource: "shape-4x4",
                withExtension: "png",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    static func package(
        resourceBytes: Data? = nil,
        provenance: BrushPackageProvenance? = nil
    ) throws -> BrushPackage {
        let bytes = try resourceBytes ?? fixturePNG()
        let resource = try BrushPackageResource(
            id: shapeID,
            kind: .shape,
            mediaType: "image/png",
            data: bytes,
            pixelWidth: 4,
            pixelHeight: 4
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(
                resources: [resource],
                provenance: provenance
            ),
            definition: try currentDefinition(),
            resourceData: [shapeID: bytes]
        )
    }

    static func fallbackOnlyPackage() throws -> BrushPackage {
        try BrushPackage(
            manifest: BrushPackageManifest(
                resources: []
            ),
            definition: currentDefinition(),
            resourceData: [:]
        )
    }

    static func currentPackage(
        metadata: BrushMetadata? = nil,
        compatibility: BrushCompatibilityMetadata? = nil,
        sensorNormalization: BrushSensorNormalizationDefinition? = nil,
        sensorProgram: BrushSensorProgramDefinition? = nil,
        stabilizationV2: BrushStabilizationDefinition? = nil,
        direction: BrushDirectionDefinition? = nil,
        emission: BrushEmissionDefinition? = nil,
        tipSupports: [BrushTipSupportDefinition]? = nil
    ) throws -> BrushPackage {
        let bytes = try fixturePNG()
        let resource = try BrushPackageResource(
            id: shapeID,
            kind: .shape,
            mediaType: "image/png",
            data: bytes,
            pixelWidth: 4,
            pixelHeight: 4
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(
                resources: [resource]
            ),
            definition: currentDefinition(
                metadata: metadata,
                compatibility: compatibility,
                sensorNormalization: sensorNormalization,
                sensorProgram: sensorProgram,
                stabilizationV2: stabilizationV2,
                direction: direction,
                emission: emission,
                tipSupports: tipSupports
            ),
            resourceData: [shapeID: bytes]
        )
    }

    static func currentDefinition(
        metadata: BrushMetadata? = nil,
        compatibility: BrushCompatibilityMetadata? = nil,
        sensorNormalization: BrushSensorNormalizationDefinition? = nil,
        sensorProgram: BrushSensorProgramDefinition? = nil,
        stabilizationV2: BrushStabilizationDefinition? = nil,
        direction: BrushDirectionDefinition? = nil,
        emission: BrushEmissionDefinition? = nil,
        tipSupports: [BrushTipSupportDefinition]? = nil
    ) throws -> BrushDefinition {
        let base = try definition()
        let component = base.components[0]
        return try BrushDefinition(
            id: base.id,
            metadata: metadata ?? base.metadata,
            capabilities: base.capabilities,
            resources: component.resources,
            coverage: component.coverage,
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
            compatibility: compatibility ?? base.compatibility,
            sensorNormalization: sensorNormalization
                ?? BrushSensorNormalizationDefinition(
                    fullScaleWorldVelocity: 2_000,
                    minimumVelocityDeltaTime: 0.001,
                    fullScaleStrokeAge: 4,
                    fullScaleStrokeDistanceInDiameters: 32
                ),
            sensorProgram: sensorProgram ?? currentSensorProgram(),
            stabilizationV2: stabilizationV2
                ?? .weightedWindow(distance: 8),
            direction: direction ?? BrushDirectionDefinition(
                maximumAngularStep: .pi / 6,
                stationaryDirection: 0
            ),
            emission: emission ?? BrushEmissionDefinition(
                mode: .distanceAndTime,
                timeInterval: 1.0 / 120
            ),
            tipSupports: tipSupports ?? [.analyticEllipse]
        )
    }

    static func currentSensorProgram(
        reversedInsertion: Bool = false,
        rotationTerms: [BrushResponseTermDefinition]? = nil
    ) -> BrushSensorProgramDefinition {
        let outputs = reversedInsertion
            ? Array(BrushDynamicOutput.allCases.reversed())
            : BrushDynamicOutput.allCases
        var values: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
        for output in outputs {
            let base: Float = switch output {
            case .size, .flow, .opacity, .spacing, .hardness, .grain: 1
            default: 0
            }
            values[output] = BrushOutputProgramDefinition(
                baseValue: base,
                terms: output == .rotation
                    ? (rotationTerms ?? [currentTerm(input: .direction)])
                    : []
            )
        }
        return BrushSensorProgramDefinition(outputs: values)
    }

    static func currentTerm(
        input: BrushDynamicsInput = .direction,
        response: BrushResponseDefinition = .linear,
        inputInverted: Bool = false,
        missingInputValue: Float = 0,
        responseScale: Float = 1,
        operation: BrushResponseOperation = .add,
        responseOffset: Float = 0,
        responseLowerClamp: Float = -.pi,
        responseUpperClamp: Float = .pi,
        jitter: Float = 0
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

    static func definition(
        capabilities: [BrushCapabilityDeclaration]? = nil,
        resources: [BrushResourceReference]? = nil,
        metadata: BrushMetadata? = nil,
        coverage: BrushCoverageDefinition? = nil,
        placement: BrushPlacementDefinition? = nil,
        dynamics: BrushDynamicsDefinition? = nil,
        color: BrushColorBehaviorDefinition? = nil,
        material: BrushMaterialDefinition? = nil,
        stabilization: Float? = nil,
        taper: BrushTaperConfiguration? = nil,
        replayMode: BrushReplayMode? = nil,
        replayLimits: BrushReplayLimits?? = nil,
        termination: BrushTerminationDefinition? = nil,
        seedPolicy: BrushSeedPolicy? = nil,
        limits: BrushDefinitionLimits? = nil,
        performanceIntent: BrushPerformanceIntent? = nil,
        compatibility: BrushCompatibilityMetadata? = nil
    ) throws -> BrushDefinition {
        let resolvedResources = resources ?? [BrushResourceReference(
            identifier: shapeID,
            kind: .shape,
            required: false,
            fallback: .builtIn(identifier: shapeID)
        )]
        let resolvedCoverage = coverage ?? BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(
                shape: .asset(shapeID),
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            )],
            grains: [],
            baseHardness: 1,
            aspectRatio: 1,
            tipThreshold: 0,
            antialiasing: true
        )
        return try BrushDefinition(
            id: BrushRecipeID("test.package"),
            metadata: metadata ?? BrushMetadata(displayName: "Package Test"),
            capabilities: capabilities ?? [],
            resources: resolvedResources,
            coverage: resolvedCoverage,
            placement: placement ?? BrushPlacementDefinition(
                baseSpacingFraction: 0.125,
                maximumSpacingFraction: 0.125,
                baseFlow: 1,
                strokeOpacity: 1,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            dynamics: dynamics ?? BrushDynamicsDefinition(
                size: constantMapping(1),
                flow: constantMapping(1),
                opacity: constantMapping(1),
                spacing: constantMapping(1),
                rotation: constantMapping(0),
                scatter: constantMapping(1),
                hardness: constantMapping(1),
                grain: constantMapping(1),
                offsetX: constantMapping(0),
                offsetY: constantMapping(0),
                hue: constantMapping(0),
                saturation: constantMapping(0),
                brightness: constantMapping(0),
                secondaryColorMix: constantMapping(0),
                noPressureNeutral: 1,
                randomization: .none
            ),
            color: color ?? BrushColorBehaviorDefinition(
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
            material: material ?? BrushMaterialDefinition(
                accumulation: .flow,
                interaction: .none,
                edgeTreatment: .none,
                strength: 1,
                wetness: 0,
                bleedRadius: 0,
                softenPasses: 0,
                accumulationLimit: 1,
                interactionParameters: nil
            ),
            stabilization: stabilization ?? 0,
            taper: taper ?? .none,
            replayMode: replayMode ?? .appendOnly,
            replayLimits: replayLimits ?? nil,
            termination: termination ?? .cap,
            seedPolicy: seedPolicy ?? .perStroke,
            limits: limits ?? BrushDefinitionLimits(
                minimumDiameter: 0.01,
                maximumDiameter: 16_384,
                maximumOpacity: 1,
                maximumSpacingFraction: 4,
                maximumResourceDimension: 4_096,
                maximumResidentBytes: 64 * 1_024 * 1_024
            ),
            performanceIntent: performanceIntent ?? .realtime120,
            compatibility: compatibility ?? BrushCompatibilityMetadata(
                sourceSettingKeys: [],
                requiredSemanticKeys: []
            )
        )
    }

    static func resource(
        id: String = shapeID,
        kind: BrushResourceKind = .shape,
        mediaType: String = "image/png",
        bytes: Data? = nil,
        width: Int = 4,
        height: Int = 4
    ) throws -> BrushPackageResource {
        try BrushPackageResource(
            id: id,
            kind: kind,
            mediaType: mediaType,
            data: bytes ?? fixturePNG(),
            pixelWidth: width,
            pixelHeight: height
        )
    }

    static func replacing(
        _ definition: BrushDefinition,
        resources: [BrushResourceReference]
    ) throws -> BrushDefinition {
        let component = definition.components[0]
        return try BrushDefinition(
            id: definition.id,
            metadata: definition.metadata,
            capabilities: definition.capabilities,
            resources: resources,
            coverage: component.coverage,
            placement: component.placement,
            dynamics: component.dynamics,
            color: component.color,
            material: component.material,
            stabilization: definition.stabilization,
            taper: component.taper,
            replayMode: definition.replayMode,
            replayLimits: definition.replayLimits,
            termination: definition.termination,
            seedPolicy: definition.seedPolicy,
            limits: definition.limits,
            performanceIntent: definition.performanceIntent,
            compatibility: definition.compatibility,
            sensorNormalization: definition.sensorNormalization,
            sensorProgram: component.sensorProgram,
            stabilizationV2: definition.stabilizationV2,
            direction: definition.direction,
            emission: component.emission,
            tipSupports: component.tipSupports
        )
    }

    static func archiveEntries(_ package: BrushPackage) throws -> [String: Data] {
        let data = try BrushPackageCodec.encode(package)
        let archive = try SafeArchiveCodec.open(
            data,
            limits: BrushPackageCodec.archiveLimits
        )
        return try Dictionary(
            uniqueKeysWithValues: archive.paths.map { ($0, try archive.data(for: $0)) }
        )
    }

    static func encodeArchive(_ entries: [String: Data]) throws -> Data {
        try SafeArchiveCodec.encode(
            entries: entries,
            limits: BrushPackageCodec.archiveLimits
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "laya-brush-format-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw SupportError.missingFixture }
        return value
    }

    enum SupportError: Error {
        case missingFixture
    }
}

func constantMapping(_ value: Float) -> BrushMappingDefinition {
    BrushMappingDefinition(
        input: .pressure,
        response: .constant(value),
        scale: 1,
        offset: 0,
        lowerClamp: value,
        upperClamp: value,
        inverted: false,
        jitter: 0,
        missingInputValue: 1
    )
}

func replacingRootObjectOrder(in data: Data) throws -> Data {
    guard let source = String(data: data, encoding: .utf8),
          source.first == "{",
          source.last == "}"
    else { throw BrushFormatTestSupport.SupportError.missingFixture }
    let body = source.dropFirst().dropLast()
    var fields: [Substring] = []
    var start = body.startIndex
    var index = start
    var depth = 0
    var inString = false
    var escaped = false
    while index < body.endIndex {
        let character = body[index]
        if inString {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
        } else {
            switch character {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            case "," where depth == 0:
                fields.append(body[start..<index])
                start = body.index(after: index)
            default: break
            }
        }
        index = body.index(after: index)
    }
    fields.append(body[start..<body.endIndex])
    return Data(("{\n" + fields.reversed().joined(separator: ",\n") + "\n}").utf8)
}

func zipSignatureOffsets(_ signature: UInt32, in data: Data) -> [Int] {
    guard data.count >= 4 else { return [] }
    return (0...(data.count - 4)).filter {
        zipUInt32(at: $0, in: data) == signature
    }
}

func zipUInt16(at offset: Int, in data: Data) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

func zipUInt32(at offset: Int, in data: Data) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
}

func zipSetUInt16(_ value: UInt16, at offset: Int, in data: inout Data) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

func zipSetUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
