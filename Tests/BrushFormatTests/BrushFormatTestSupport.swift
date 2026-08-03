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
        let definition = try definition()
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
            definition: definition,
            resourceData: [shapeID: bytes]
        )
    }

    static func fallbackOnlyPackage() throws -> BrushPackage {
        try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: definition(),
            resourceData: [:]
        )
    }

    static func v2Package(
        metadata: BrushMetadata? = nil,
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
                schemaVersion: BrushPackageManifest.currentVersion,
                resources: [resource]
            ),
            definition: v2Definition(
                metadata: metadata,
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

    static func v2Definition(
        metadata: BrushMetadata? = nil,
        sensorNormalization: BrushSensorNormalizationDefinition? = nil,
        sensorProgram: BrushSensorProgramDefinition? = nil,
        stabilizationV2: BrushStabilizationDefinition? = nil,
        direction: BrushDirectionDefinition? = nil,
        emission: BrushEmissionDefinition? = nil,
        tipSupports: [BrushTipSupportDefinition]? = nil
    ) throws -> BrushDefinition {
        let base = try definition()
        return try BrushDefinition(
            v2ID: base.id,
            metadata: metadata ?? base.metadata,
            capabilities: base.capabilities,
            resources: base.resources,
            coverage: base.coverage,
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
            sensorNormalization: sensorNormalization
                ?? BrushSensorNormalizationDefinition(
                    fullScaleWorldVelocity: 2_000,
                    minimumVelocityDeltaTime: 0.001,
                    fullScaleStrokeAge: 4,
                    fullScaleStrokeDistanceInDiameters: 32
                ),
            sensorProgram: sensorProgram ?? v2SensorProgram(),
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

    static func v2SensorProgram(
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
                    ? (rotationTerms ?? [v2Term(input: .direction)])
                    : []
            )
        }
        return BrushSensorProgramDefinition(outputs: values)
    }

    static func v2Term(
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
        let base = try LegacyBrushRecipeAdapter.definition(
            from: BrushRecipe(
                id: BrushRecipeID("test.package"),
                shape: .asset(shapeID)
            ),
            displayName: "Package Test"
        )
        return try BrushDefinition(
            id: base.id,
            schemaVersion: base.schemaVersion,
            metadata: metadata ?? base.metadata,
            capabilities: capabilities ?? base.capabilities,
            resources: resources ?? base.resources,
            coverage: coverage ?? base.coverage,
            placement: placement ?? base.placement,
            dynamics: dynamics ?? base.dynamics,
            color: color ?? base.color,
            material: material ?? base.material,
            stabilization: stabilization ?? base.stabilization,
            taper: taper ?? base.taper,
            replayMode: replayMode ?? base.replayMode,
            replayLimits: replayLimits ?? base.replayLimits,
            termination: termination ?? base.termination,
            seedPolicy: seedPolicy ?? base.seedPolicy,
            limits: limits ?? base.limits,
            performanceIntent: performanceIntent ?? base.performanceIntent,
            compatibility: compatibility ?? base.compatibility
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
