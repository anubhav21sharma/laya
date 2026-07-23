import Foundation
import PatternEngine

public enum HarnessPixelChannel: String, Codable, Equatable, Sendable {
    case screen
    case liveScreen
    case committedScreen
    case canonical
    case oracleCoverage
    case oracleCanonicalCoordinates
    case oracleBrushLocalCoordinates
}

public enum HarnessDiagnosticMode: String, Codable, Equatable, Sendable {
    case hardRound
    case asymmetricCoverage
    case canonicalCoordinates
    case brushLocalCoordinates
}

public struct HarnessPeriodicConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let repeatWidth: Float
    public let repeatHeight: Float
    public let orientationRadians: Float

    public init(
        version: Int = currentVersion,
        repeatWidth: Float,
        repeatHeight: Float,
        orientationRadians: Float
    ) {
        self.version = version
        self.repeatWidth = repeatWidth
        self.repeatHeight = repeatHeight
        self.orientationRadians = orientationRadians
    }

    func productionConfiguration(
        presetID: SymmetryPresetID
    ) -> PeriodicSymmetryConfiguration {
        PeriodicSymmetryConfiguration(
            presetID: presetID,
            repeatSize: PatternSize(
                width: repeatWidth,
                height: repeatHeight
            ),
            orientationRadians: orientationRadians
        )
    }
}

public enum TilingHarnessProgram: String, Codable, Equatable, Sendable {
    case gridInterior
    case gridBoundary
    case previewCommit
    case cancelPreservesCanonical
    case fiveHundredDabs
    case longStroke
    case generalizedGrid
    case halfDropInterior
    case halfDropEdge
    case halfDropCorner
    case brickTranspose
    case mirrorX
    case mirrorY
    case mirrorXY
    case rotationalGenerator
    case rotationalFixedPoint
    case rotationalOrientation
    case largeFootprint
    case asymmetricFootprint
    case canonicalCoordinateContinuity
    case brushLocalCoordinateContinuity
    case rectangularTile
    case noncentralVisibleCell
    case squareFixedPoint
    case metadataTilingSwitch
    case projectedLiveCommit
    case projectedLongStroke
    case coloredDraw
    case eraserLiveCommit
    case regionUndoSeam
    case clearUndo
    case tilingUndo
    case resizeCropFill

    var requiredTiling: TilingKind? {
        switch self {
        case .gridInterior, .gridBoundary, .previewCommit,
             .cancelPreservesCanonical, .fiveHundredDabs, .longStroke:
            .grid
        case .generalizedGrid, .largeFootprint, .rectangularTile,
             .metadataTilingSwitch:
            .grid
        case .halfDropInterior, .halfDropEdge, .halfDropCorner,
             .canonicalCoordinateContinuity, .projectedLiveCommit,
             .projectedLongStroke:
            .halfDrop
        case .brickTranspose:
            .brick
        case .mirrorX:
            .mirrorX
        case .mirrorY:
            .mirrorY
        case .mirrorXY, .brushLocalCoordinateContinuity:
            .mirrorXY
        case .rotationalGenerator, .rotationalFixedPoint,
             .rotationalOrientation, .asymmetricFootprint:
            .rotational
        case .noncentralVisibleCell, .squareFixedPoint:
            nil
        case .coloredDraw, .eraserLiveCommit, .regionUndoSeam,
             .clearUndo, .tilingUndo, .resizeCropFill:
            nil
        }
    }

    var requiresInteractiveHardRound: Bool {
        switch self {
        case .gridInterior, .gridBoundary, .previewCommit,
             .cancelPreservesCanonical, .fiveHundredDabs, .longStroke,
             .generalizedGrid, .halfDropInterior, .halfDropEdge,
             .halfDropCorner, .brickTranspose, .rotationalFixedPoint,
             .largeFootprint, .rectangularTile, .noncentralVisibleCell,
             .squareFixedPoint,
             .metadataTilingSwitch,
             .projectedLiveCommit, .projectedLongStroke:
            true
        default:
            false
        }
    }

    public var isSliceThreeProgram: Bool {
        switch self {
        case .coloredDraw, .eraserLiveCommit, .regionUndoSeam,
             .clearUndo, .tilingUndo, .resizeCropFill:
            true
        default:
            false
        }
    }
}

public typealias GridHarnessProgram = TilingHarnessProgram

public enum HarnessStructuralMetric: String, Codable, Equatable, Sendable {
    case emittedDabCount
    case encodedInstanceCount
    case restampedInstanceCount
    case canonicalRevisionDelta
    case previewCommitMaximumDelta
    case canonicalByteDelta
    case missedFrameCount
    case oracleHoleCount
    case oraclePhantomCount
    case oracleMaximumDelta
    case restoredDisplayMaximumDelta
    case transformMismatchCount
    case duplicateFixedPointWriteCount
    case coordinateContinuityMismatchCount
    case visibleCellCanonicalByteDelta
    case previewCommitViolationCount
    case coloredOutputMismatchCount
    case historyCommandCount
    case historyResidentBytes
    case changedRegionCount
    case undoCanonicalByteDelta
    case redoCanonicalByteDelta
    case metadataCanonicalByteDelta
    case restoredWidth
    case restoredHeight
    case peakRetainedSampleCount
    case peakRetainedDabCount
    case replayCount
    case promotedSettledPrefixCount
    case replayDegradationCount
    case assetResidentBytes
    case materialMismatchCount
    case replayModeMismatchCount
    case assetIdentityMismatchCount
    case predictedDuplicateSettledDabCount
    case staleReplayEpochViolationCount
    case processedWashPixelCount
    case washWorkingBytes
    case drawEraseChangedByteCount
    case legacyParityMaximumDelta
    case anchorTilingMatrixPassCount
    case anchorTilingNoncentralCount
    case anchorTilingLiveCommitPassCount
    case anchorTilingContinuityPassCount
    case anchorTilingEraserAlphaPassCount
    case anchorTilingEraserColorPassCount
    case anchorCatalogEqualityCount
    case sameSeedMaximumDelta
    case differentSeedChangedByteCount
    case pressureResponseChangedByteCount
    case shapeHardnessChangedByteCount
    case gpuFailurePreservedCanonicalCount
    case allocationFailurePreservedCanonicalCount

    var isSliceThreeOnly: Bool {
        switch self {
        case .coloredOutputMismatchCount, .historyCommandCount,
             .historyResidentBytes,
             .changedRegionCount, .undoCanonicalByteDelta,
             .redoCanonicalByteDelta, .metadataCanonicalByteDelta,
             .restoredWidth, .restoredHeight:
            true
        default:
            false
        }
    }

    var isSliceFourOnly: Bool {
        switch self {
        case .peakRetainedSampleCount, .peakRetainedDabCount, .replayCount,
             .promotedSettledPrefixCount, .replayDegradationCount,
             .assetResidentBytes, .materialMismatchCount,
             .replayModeMismatchCount, .assetIdentityMismatchCount,
             .predictedDuplicateSettledDabCount,
             .staleReplayEpochViolationCount, .processedWashPixelCount,
             .washWorkingBytes, .drawEraseChangedByteCount,
             .legacyParityMaximumDelta, .anchorTilingMatrixPassCount,
             .anchorTilingNoncentralCount,
             .anchorTilingLiveCommitPassCount,
             .anchorTilingContinuityPassCount,
             .anchorTilingEraserAlphaPassCount,
             .anchorTilingEraserColorPassCount,
             .anchorCatalogEqualityCount, .sameSeedMaximumDelta,
             .differentSeedChangedByteCount,
             .pressureResponseChangedByteCount,
             .shapeHardnessChangedByteCount,
             .gpuFailurePreservedCanonicalCount,
             .allocationFailurePreservedCanonicalCount:
            true
        default:
            false
        }
    }
}

public enum HarnessExpectedMaterial: String, Codable, Equatable, Sendable {
    case ink
    case dry
    case glaze
    case boundedWash

    public var brushMaterialFamily: BrushMaterialFamily {
        switch self {
        case .ink: .ink
        case .dry: .dry
        case .glaze: .glaze
        case .boundedWash: .boundedWash
        }
    }
}

public enum HarnessReplayMode: String, Codable, Equatable, Sendable {
    case appendOnly
    case replayTail
    case boundedWholeStroke

    public var brushReplayMode: BrushReplayMode {
        switch self {
        case .appendOnly: .appendOnly
        case .replayTail: .replayTail
        case .boundedWholeStroke: .boundedWholeStroke
        }
    }
}

public enum HarnessStrokePhase: String, Codable, Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled

    public var strokePhase: StrokePhase {
        switch self {
        case .began: .began
        case .moved: .moved
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }
}

public enum HarnessStrokeSource: String, Codable, Equatable, Sendable {
    case mouse
    case tablet
    case pencil

    public var strokeSource: StrokeSource {
        switch self {
        case .mouse: .mouse
        case .tablet: .tablet
        case .pencil: .pencil
        }
    }
}

public enum HarnessStrokeSampleKind: String, Codable, Equatable, Sendable {
    case actual
    case coalesced
    case predicted
    case estimatedUpdate

    public var strokeSampleKind: StrokeSampleKind {
        switch self {
        case .actual: .actual
        case .coalesced: .coalesced
        case .predicted: .predicted
        case .estimatedUpdate: .estimatedUpdate
        }
    }
}

/// Codable V2 input sample used by schema 5 evidence scenes.
public struct HarnessAttributedSample: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let pressure: Float
    public let timestamp: TimeInterval
    public let altitude: Float?
    public let azimuth: Float?
    public let roll: Float?
    public let phase: HarnessStrokePhase
    public let source: HarnessStrokeSource
    public let kind: HarnessStrokeSampleKind
    public let capabilities: UInt8

    public init(
        x: Float,
        y: Float,
        pressure: Float,
        timestamp: TimeInterval,
        altitude: Float? = nil,
        azimuth: Float? = nil,
        roll: Float? = nil,
        phase: HarnessStrokePhase,
        source: HarnessStrokeSource,
        kind: HarnessStrokeSampleKind = .actual,
        capabilities: UInt8 = 0
    ) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.timestamp = timestamp
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
        self.phase = phase
        self.source = source
        self.kind = kind
        self.capabilities = capabilities
    }

    public var strokeSample: StrokeSample? {
        StrokeSample.validated(
            position: ScreenPoint(x: x, y: y),
            pressure: pressure,
            timestamp: timestamp,
            phase: phase.strokePhase,
            source: source.strokeSource,
            kind: kind.strokeSampleKind,
            capabilities: StrokeInputCapabilities(rawValue: capabilities),
            altitude: altitude,
            azimuth: azimuth,
            roll: roll
        )
    }
}

public enum HarnessRelation: String, Codable, Equatable, Sendable {
    case equal
    case lessThanOrEqual
    case greaterThanOrEqual
}

public struct HarnessStructuralCheck: Codable, Equatable, Sendable {
    public let metric: HarnessStructuralMetric
    public let relation: HarnessRelation
    public let value: Int
}

public struct HarnessPixelCheck: Codable, Equatable, Sendable {
    public let channel: HarnessPixelChannel
    public let x: Int
    public let y: Int
    public let expectedBGRA: [UInt8]
    public let tolerance: UInt8

    private enum CodingKeys: String, CodingKey {
        case channel
        case x
        case y
        case expectedBGRA
        case tolerance
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        channel = try values.decodeIfPresent(
            HarnessPixelChannel.self,
            forKey: .channel
        ) ?? .screen
        x = try values.decode(Int.self, forKey: .x)
        y = try values.decode(Int.self, forKey: .y)
        expectedBGRA = try values.decode(
            [UInt8].self,
            forKey: .expectedBGRA
        )
        tolerance = try values.decode(UInt8.self, forKey: .tolerance)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if channel != .screen {
            try values.encode(channel, forKey: .channel)
        }
        try values.encode(x, forKey: .x)
        try values.encode(y, forKey: .y)
        try values.encode(expectedBGRA, forKey: .expectedBGRA)
        try values.encode(tolerance, forKey: .tolerance)
    }
}

public struct HarnessScene: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let checks: [HarnessPixelCheck]
    public let program: TilingHarnessProgram?
    public let structuralChecks: [HarnessStructuralCheck]
    public let negativeControls: [HarnessStructuralCheck]
    public let tileWidth: Int?
    public let tileHeight: Int?
    public let tiling: TilingKind?
    public let diagnosticMode: HarnessDiagnosticMode?
    public let periodicConfiguration: HarnessPeriodicConfiguration?
    public let recipeID: String?
    public let seed: UInt64?
    public let attributedSamples: [HarnessAttributedSample]
    public let expectedMaterial: HarnessExpectedMaterial?
    public let replayMode: HarnessReplayMode?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case width
        case height
        case checks
        case program
        case structuralChecks
        case negativeControls
        case tileWidth
        case tileHeight
        case tiling
        case diagnosticMode
        case periodicConfiguration
        case recipeID
        case seed
        case attributedSamples
        case expectedMaterial
        case replayMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        name = try values.decode(String.self, forKey: .name)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        checks = try values.decodeIfPresent(
            [HarnessPixelCheck].self,
            forKey: .checks
        ) ?? []
        program = try values.decodeIfPresent(
            TilingHarnessProgram.self,
            forKey: .program
        )
        structuralChecks = try values.decodeIfPresent(
            [HarnessStructuralCheck].self,
            forKey: .structuralChecks
        ) ?? []
        negativeControls = try values.decodeIfPresent(
            [HarnessStructuralCheck].self,
            forKey: .negativeControls
        ) ?? []
        if (3...5).contains(schemaVersion) {
            if schemaVersion == 4, program == nil {
                throw HarnessSceneError.missingSchemaFourField("program")
            }
            tileWidth = try Self.decodeRequiredTilingValue(
                Int.self,
                key: .tileWidth,
                field: "tileWidth",
                schemaVersion: schemaVersion,
                from: values
            )
            tileHeight = try Self.decodeRequiredTilingValue(
                Int.self,
                key: .tileHeight,
                field: "tileHeight",
                schemaVersion: schemaVersion,
                from: values
            )
            tiling = try Self.decodeRequiredTilingValue(
                TilingKind.self,
                key: .tiling,
                field: "tiling",
                schemaVersion: schemaVersion,
                from: values
            )
            diagnosticMode = try Self.decodeRequiredTilingValue(
                HarnessDiagnosticMode.self,
                key: .diagnosticMode,
                field: "diagnosticMode",
                schemaVersion: schemaVersion,
                from: values
            )
        } else {
            tileWidth = nil
            tileHeight = nil
            tiling = nil
            diagnosticMode = nil
        }
        periodicConfiguration = try values.decodeIfPresent(
            HarnessPeriodicConfiguration.self,
            forKey: .periodicConfiguration
        )
        if schemaVersion == 5 {
            recipeID = try Self.decodeRequiredSchemaFiveValue(
                String.self,
                key: .recipeID,
                field: "recipeID",
                from: values
            )
            seed = try Self.decodeRequiredSchemaFiveValue(
                UInt64.self,
                key: .seed,
                field: "seed",
                from: values
            )
            attributedSamples = try Self.decodeRequiredSchemaFiveValue(
                [HarnessAttributedSample].self,
                key: .attributedSamples,
                field: "attributedSamples",
                from: values
            )
            expectedMaterial = try Self.decodeRequiredSchemaFiveValue(
                HarnessExpectedMaterial.self,
                key: .expectedMaterial,
                field: "expectedMaterial",
                from: values
            )
            replayMode = try Self.decodeRequiredSchemaFiveValue(
                HarnessReplayMode.self,
                key: .replayMode,
                field: "replayMode",
                from: values
            )
        } else {
            recipeID = nil
            seed = nil
            attributedSamples = []
            expectedMaterial = nil
            replayMode = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(name, forKey: .name)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(checks, forKey: .checks)
        try values.encodeIfPresent(program, forKey: .program)
        if !structuralChecks.isEmpty {
            try values.encode(structuralChecks, forKey: .structuralChecks)
        }
        if !negativeControls.isEmpty {
            try values.encode(negativeControls, forKey: .negativeControls)
        }
        if (3...5).contains(schemaVersion) {
            try values.encode(tileWidth, forKey: .tileWidth)
            try values.encode(tileHeight, forKey: .tileHeight)
            try values.encode(tiling, forKey: .tiling)
            try values.encode(diagnosticMode, forKey: .diagnosticMode)
        }
        try values.encodeIfPresent(
            periodicConfiguration,
            forKey: .periodicConfiguration
        )
        if schemaVersion == 5 {
            try values.encode(recipeID, forKey: .recipeID)
            try values.encode(seed, forKey: .seed)
            try values.encode(attributedSamples, forKey: .attributedSamples)
            try values.encode(expectedMaterial, forKey: .expectedMaterial)
            try values.encode(replayMode, forKey: .replayMode)
        }
    }

    public static func decode(_ data: Data) throws -> HarnessScene {
        let scene = try JSONDecoder().decode(HarnessScene.self, from: data)
        try scene.validate()
        return scene
    }

    private func validate() throws {
        if (1...3).contains(schemaVersion),
           let metric = structuralChecks.first(where: {
               $0.metric.isSliceThreeOnly
           })?.metric
        {
            throw HarnessSceneError.structuralMetricUnavailableForSchema(
                metric: metric,
                schemaVersion: schemaVersion
            )
        }
        if (1...4).contains(schemaVersion),
           let metric = structuralChecks.first(where: {
               $0.metric.isSliceFourOnly
           })?.metric
        {
            throw HarnessSceneError.structuralMetricUnavailableForSchema(
                metric: metric,
                schemaVersion: schemaVersion
            )
        }
        switch schemaVersion {
        case 1:
            guard program == nil else {
                throw HarnessSceneError.programForbiddenForSchemaOne
            }
        case 2:
            guard program != nil else {
                throw HarnessSceneError.missingProgram
            }
            guard program?.isSliceThreeProgram == false else {
                throw HarnessSceneError.programUnavailableForSchema(
                    program: program!,
                    schemaVersion: schemaVersion
                )
            }
        case 3:
            guard let program else {
                throw HarnessSceneError.missingProgram
            }
            guard !program.isSliceThreeProgram else {
                throw HarnessSceneError.programUnavailableForSchema(
                    program: program,
                    schemaVersion: schemaVersion
                )
            }
            guard let tileWidth, let tileHeight else {
                preconditionFailure(
                    "Schema 3 required tile fields must be decoded before validation"
                )
            }
            guard (64...4_096).contains(tileWidth),
                  (64...4_096).contains(tileHeight)
            else {
                throw HarnessSceneError.invalidTileDimensions(
                    width: tileWidth,
                    height: tileHeight
                )
            }
            guard let tiling, let diagnosticMode else {
                preconditionFailure(
                    "Schema 3 required tiling fields must be decoded before validation"
                )
            }
            if let requiredTiling = program.requiredTiling,
               requiredTiling != tiling
            {
                throw HarnessSceneError.programTilingMismatch(
                    program: program,
                    tiling: tiling
                )
            }
            if program == .squareFixedPoint, !tiling.isSquare {
                throw HarnessSceneError.programTilingMismatch(
                    program: program,
                    tiling: tiling
                )
            }
            if program.requiresInteractiveHardRound,
               diagnosticMode != .hardRound
            {
                throw HarnessSceneError.interactiveDiagnosticRequiresHardRound(
                    program: program,
                    diagnosticMode: diagnosticMode
                )
            }
        case 4:
            guard let program else {
                throw HarnessSceneError.missingSchemaFourField("program")
            }
            guard program.isSliceThreeProgram else {
                throw HarnessSceneError.programUnavailableForSchema(
                    program: program,
                    schemaVersion: schemaVersion
                )
            }
            guard let tileWidth, let tileHeight else {
                preconditionFailure(
                    "Schema 4 required tile fields must be decoded before validation"
                )
            }
            guard (64...4_096).contains(tileWidth),
                  (64...4_096).contains(tileHeight)
            else {
                throw HarnessSceneError.invalidTileDimensions(
                    width: tileWidth,
                    height: tileHeight
                )
            }
            guard tiling != nil, diagnosticMode != nil else {
                preconditionFailure(
                    "Schema 4 required tiling fields must be decoded before validation"
                )
            }
        case 5:
            guard program != nil else {
                throw HarnessSceneError.missingSchemaFiveField("program")
            }
            guard let tileWidth, let tileHeight else {
                preconditionFailure(
                    "Schema 5 required tile fields must be decoded before validation"
                )
            }
            guard (64...4_096).contains(tileWidth),
                  (64...4_096).contains(tileHeight)
            else {
                throw HarnessSceneError.invalidTileDimensions(
                    width: tileWidth,
                    height: tileHeight
                )
            }
            guard tiling != nil, diagnosticMode != nil else {
                preconditionFailure(
                    "Schema 5 required tiling fields must be decoded before validation"
                )
            }
            guard let recipeID,
                  !recipeID.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            else {
                throw HarnessSceneError.invalidSchemaFiveRecipeID
            }
            guard let seed, seed != 0 else {
                throw HarnessSceneError.invalidSchemaFiveSeed
            }
            guard !attributedSamples.isEmpty else {
                throw HarnessSceneError.missingAttributedSamples
            }
            for (index, sample) in attributedSamples.enumerated() {
                let unknownCapabilities = sample.capabilities & ~UInt8(0x0F)
                guard unknownCapabilities == 0,
                      sample.strokeSample != nil
                else {
                    throw HarnessSceneError.invalidAttributedSample(index)
                }
            }
            guard expectedMaterial != nil, replayMode != nil else {
                preconditionFailure(
                    "Schema 5 material and replay fields must be decoded before validation"
                )
            }
        default:
            throw HarnessSceneError.unsupportedSchema(schemaVersion)
        }
        if let periodicConfiguration {
            guard schemaVersion == 3 else {
                throw HarnessSceneError.periodicConfigurationUnavailableForSchema(
                    schemaVersion
                )
            }
            guard periodicConfiguration.version
                    == HarnessPeriodicConfiguration.currentVersion
            else {
                throw HarnessSceneError.unsupportedPeriodicConfigurationVersion(
                    periodicConfiguration.version
                )
            }
            guard let tiling, let tileWidth, let tileHeight else {
                preconditionFailure(
                    "Periodic harness configuration requires decoded schema 3 tiling state"
                )
            }
            guard periodicConfiguration.repeatWidth.isFinite,
                  periodicConfiguration.repeatHeight.isFinite,
                  periodicConfiguration.repeatWidth > 0,
                  periodicConfiguration.repeatHeight > 0
            else {
                throw HarnessSceneError.invalidPeriodicRepeatDimensions(
                    width: periodicConfiguration.repeatWidth,
                    height: periodicConfiguration.repeatHeight
                )
            }
            do {
                _ = try SymmetryDescriptorCompiler.compile(
                    configuration: periodicConfiguration
                        .productionConfiguration(presetID: tiling),
                    canonicalRasterSize: PixelSize(
                        width: tileWidth,
                        height: tileHeight
                    )
                )
            } catch let error as SymmetryDescriptorError {
                throw HarnessSceneError.invalidPeriodicConfiguration(
                    error
                )
            }
        }
        guard !name.isEmpty else {
            throw HarnessSceneError.emptyName
        }
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw HarnessSceneError.invalidDimensions(width: width, height: height)
        }
        if schemaVersion == 1, checks.isEmpty {
            throw HarnessSceneError.missingPixelChecks
        }
        if schemaVersion >= 2, checks.isEmpty, structuralChecks.isEmpty {
            throw HarnessSceneError.missingAssertions
        }

        for check in checks {
            let usesTileDimensions: Bool
            switch check.channel {
            case .canonical, .oracleCoverage,
                 .oracleCanonicalCoordinates,
                 .oracleBrushLocalCoordinates:
                usesTileDimensions = true
            case .screen, .liveScreen, .committedScreen:
                usesTileDimensions = false
            }
            let artifactWidth = usesTileDimensions
                ? (tileWidth ?? Int(GridCanvasContract.tileSize))
                : width
            let artifactHeight = usesTileDimensions
                ? (tileHeight ?? Int(GridCanvasContract.tileSize))
                : height
            guard
                (0..<artifactWidth).contains(check.x),
                (0..<artifactHeight).contains(check.y)
            else {
                throw HarnessSceneError.invalidCheckCoordinate(x: check.x, y: check.y)
            }
            guard check.expectedBGRA.count == 4 else {
                throw HarnessSceneError.invalidExpectedPixelCount(
                    check.expectedBGRA.count
                )
            }
        }
        for check in structuralChecks {
            guard check.value >= 0 else {
                throw HarnessSceneError.invalidStructuralValue(check.value)
            }
        }
        for check in negativeControls {
            guard schemaVersion == 5,
                  name.hasSuffix("-negative-control"),
                  check.value >= 0
            else {
                throw HarnessSceneError.invalidNegativeControl
            }
        }
        guard Set(negativeControls.map { $0.metric.rawValue }).count
                == negativeControls.count
        else {
            throw HarnessSceneError.invalidNegativeControl
        }
    }

    private static func decodeRequiredTilingValue<Value: Decodable>(
        _ type: Value.Type,
        key: CodingKeys,
        field: String,
        schemaVersion: Int,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Value {
        guard values.contains(key),
              try !values.decodeNil(forKey: key)
        else {
            if schemaVersion == 3 {
                throw HarnessSceneError.missingSchemaThreeField(field)
            }
            if schemaVersion == 5 {
                throw HarnessSceneError.missingSchemaFiveField(field)
            }
            throw HarnessSceneError.missingSchemaFourField(field)
        }
        return try values.decode(Value.self, forKey: key)
    }

    private static func decodeRequiredSchemaFiveValue<Value: Decodable>(
        _ type: Value.Type,
        key: CodingKeys,
        field: String,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Value {
        guard values.contains(key), try !values.decodeNil(forKey: key) else {
            throw HarnessSceneError.missingSchemaFiveField(field)
        }
        return try values.decode(Value.self, forKey: key)
    }
}

public enum HarnessSceneError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case emptyName
    case invalidDimensions(width: Int, height: Int)
    case missingPixelChecks
    case invalidCheckCoordinate(x: Int, y: Int)
    case invalidExpectedPixelCount(Int)
    case missingProgram
    case programForbiddenForSchemaOne
    case missingAssertions
    case invalidStructuralValue(Int)
    case invalidNegativeControl
    case missingSchemaThreeField(String)
    case missingSchemaFourField(String)
    case missingSchemaFiveField(String)
    case invalidSchemaFiveRecipeID
    case invalidSchemaFiveSeed
    case missingAttributedSamples
    case invalidAttributedSample(Int)
    case invalidTileDimensions(width: Int, height: Int)
    case periodicConfigurationUnavailableForSchema(Int)
    case unsupportedPeriodicConfigurationVersion(Int)
    case invalidPeriodicRepeatDimensions(width: Float, height: Float)
    case invalidPeriodicConfiguration(SymmetryDescriptorError)
    case programUnavailableForSchema(
        program: TilingHarnessProgram,
        schemaVersion: Int
    )
    case structuralMetricUnavailableForSchema(
        metric: HarnessStructuralMetric,
        schemaVersion: Int
    )
    case programTilingMismatch(
        program: TilingHarnessProgram,
        tiling: TilingKind
    )
    case interactiveDiagnosticRequiresHardRound(
        program: TilingHarnessProgram,
        diagnosticMode: HarnessDiagnosticMode
    )

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported harness scene schema \(version)."
        case .emptyName:
            "Harness scene name is empty."
        case let .invalidDimensions(width, height):
            "Harness dimensions \(width)x\(height) are outside 1...4096."
        case .missingPixelChecks:
            "Harness scene has no pixel checks."
        case let .invalidCheckCoordinate(x, y):
            "Harness check coordinate (\(x), \(y)) is outside the scene."
        case let .invalidExpectedPixelCount(count):
            "Expected BGRA pixel has \(count) components instead of 4."
        case .missingProgram:
            "Schema 2 harness scene requires a grid program."
        case .programForbiddenForSchemaOne:
            "Schema 1 harness scene cannot contain a grid program."
        case .missingAssertions:
            "Schema 2 harness scene has no pixel or structural assertions."
        case let .invalidStructuralValue(value):
            "Harness structural assertion value \(value) is negative."
        case .invalidNegativeControl:
            "Harness negative controls must be unique nonnegative schema 5 assertions on a negative-control scene."
        case let .missingSchemaThreeField(field):
            "Schema 3 harness scene requires '\(field)'."
        case let .missingSchemaFourField(field):
            "Schema 4 harness scene requires '\(field)'."
        case let .missingSchemaFiveField(field):
            "Schema 5 harness scene requires '\(field)'."
        case .invalidSchemaFiveRecipeID:
            "Schema 5 harness scene requires a nonempty recipe ID."
        case .invalidSchemaFiveSeed:
            "Schema 5 harness scene requires a nonzero UInt64 seed."
        case .missingAttributedSamples:
            "Schema 5 harness scene requires at least one attributed sample."
        case let .invalidAttributedSample(index):
            "Schema 5 harness scene attributed sample \(index) is invalid."
        case let .invalidTileDimensions(width, height):
            "Harness tile dimensions \(width)x\(height) are outside 64...4096."
        case let .periodicConfigurationUnavailableForSchema(schemaVersion):
            "Harness periodic configuration is unavailable in schema \(schemaVersion)."
        case let .unsupportedPeriodicConfigurationVersion(version):
            "Unsupported harness periodic configuration version \(version)."
        case let .invalidPeriodicRepeatDimensions(width, height):
            "Harness repeat dimensions \(width)x\(height) must be positive and finite."
        case let .invalidPeriodicConfiguration(error):
            "Invalid harness periodic configuration: \(error.localizedDescription)"
        case let .programUnavailableForSchema(program, schemaVersion):
            "Harness program \(program.rawValue) is unavailable in schema \(schemaVersion)."
        case let .structuralMetricUnavailableForSchema(metric, schemaVersion):
            "Harness structural metric \(metric.rawValue) is unavailable in schema \(schemaVersion)."
        case let .programTilingMismatch(program, tiling):
            "Harness program \(program.rawValue) requires a different tiling than \(tiling)."
        case let .interactiveDiagnosticRequiresHardRound(program, mode):
            "Interactive harness program \(program.rawValue) cannot use diagnostic mode \(mode.rawValue)."
        }
    }
}
