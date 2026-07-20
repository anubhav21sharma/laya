import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Test
func harnessSceneDecodesAndValidates() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "blank-canvas",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 32,
              "y": 32,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)

    #expect(scene.name == "blank-canvas")
    #expect(scene.width == 64)
    #expect(scene.height == 64)
    #expect(scene.checks.count == 1)
    #expect(scene.checks[0].expectedBGRA == [241, 244, 242, 255])
}

@Test
func harnessSceneRejectsAnUnknownSchema() {
    let data = Data(
        """
        {
          "schemaVersion": 4,
          "name": "future-scene",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 0,
              "y": 0,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 0
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.unsupportedSchema(4)) {
        try HarnessScene.decode(data)
    }
}

@Test
func harnessSceneRejectsAnOutOfBoundsPixelCheck() {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "bad-coordinate",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 64,
              "y": 0,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 0
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.invalidCheckCoordinate(x: 64, y: 0)) {
        try HarnessScene.decode(data)
    }
}

@Test
func gridHarnessSceneDecodesVersionTwoProgramAndAssertions() throws {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "grid-interior",
          "width": 512,
          "height": 512,
          "program": "gridInterior",
          "checks": [
            {
              "channel": "liveScreen",
              "x": 200,
              "y": 256,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 1
            }
          ],
          "structuralChecks": [
            {
              "metric": "restampedInstanceCount",
              "relation": "equal",
              "value": 0
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)

    #expect(scene.program == .gridInterior)
    #expect(scene.checks[0].channel == .liveScreen)
    #expect(scene.structuralChecks.count == 1)
}

@Test
func schemaOneBlankSceneRemainsDecodable() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "blank-canvas",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 32,
              "y": 32,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)
    #expect(scene.program == nil)
    #expect(scene.checks[0].channel == .screen)
}

@Test
func schemaTwoRequiresAGridProgram() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "missing-program",
          "width": 512,
          "height": 512,
          "checks": []
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.missingProgram) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaOneForbidsGridPrograms() {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "invalid-legacy-grid",
          "width": 64,
          "height": 64,
          "program": "gridInterior",
          "checks": [
            {
              "x": 0,
              "y": 0,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.programForbiddenForSchemaOne) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaTwoRequiresAtLeastOneAssertion() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "missing-assertions",
          "width": 512,
          "height": 512,
          "program": "gridInterior",
          "checks": [],
          "structuralChecks": []
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.missingAssertions) {
        try HarnessScene.decode(data)
    }
}

@Test
func structuralAssertionsRejectNegativeValues() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "negative-structural-value",
          "width": 512,
          "height": 512,
          "program": "longStroke",
          "checks": [],
          "structuralChecks": [
            {
              "metric": "missedFrameCount",
              "relation": "lessThanOrEqual",
              "value": -1
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.invalidStructuralValue(-1)) {
        try HarnessScene.decode(data)
    }
}

@Test
func canonicalChecksRejectCoordinatesOutsideTheTileArtifact() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "canonical-out-of-bounds",
          "width": 512,
          "height": 512,
          "program": "gridBoundary",
          "checks": [
            {
              "channel": "canonical",
              "x": 256,
              "y": 0,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    #expect(
        throws: HarnessSceneError.invalidCheckCoordinate(x: 256, y: 0)
    ) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaOneEncodingPreservesTheLegacyShape() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "blank-canvas",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 32,
              "y": 32,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )
    let scene = try HarnessScene.decode(data)

    let encoded = try JSONEncoder().encode(scene)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let checks = try #require(object["checks"] as? [[String: Any]])

    #expect(object["program"] == nil)
    #expect(object["structuralChecks"] == nil)
    #expect(checks[0]["channel"] == nil)
}

@Test
func unavailableStructuralMetricsFailInsteadOfReadingAsZero() throws {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "unavailable-metric",
          "width": 512,
          "height": 512,
          "program": "fiveHundredDabs",
          "structuralChecks": [
            {
              "metric": "previewCommitMaximumDelta",
              "relation": "lessThanOrEqual",
              "value": 0
            }
          ]
        }
        """.utf8
    )
    let scene = try HarnessScene.decode(data)

    #expect(
        throws: HarnessRunError.missingStructuralMetric(
            sceneName: "unavailable-metric",
            metric: .previewCommitMaximumDelta
        )
    ) {
        try HarnessRunner.evaluateStructuralChecks(scene: scene, values: [:])
    }
}

@Test
func everyLegacySceneFileStillDecodesWithoutSchemaThreeState() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
    let legacyNames = [
        "blank-canvas-negative-control",
        "blank-canvas",
        "cancel-preserves-canonical-negative-control",
        "cancel-preserves-canonical",
        "five-hundred-dabs-negative-control",
        "five-hundred-dabs",
        "grid-boundary-negative-control",
        "grid-boundary",
        "grid-interior-negative-control",
        "grid-interior",
        "long-stroke-negative-control",
        "long-stroke",
        "preview-commit-negative-control",
        "preview-commit",
    ]

    for name in legacyNames {
        let data = try Data(
            contentsOf: scenesDirectory.appendingPathComponent("\(name).json")
        )
        let scene = try HarnessScene.decode(data)

        #expect(scene.tileWidth == nil, "\(name)")
        #expect(scene.tileHeight == nil, "\(name)")
        #expect(scene.tiling == nil, "\(name)")
        #expect(scene.diagnosticMode == nil, "\(name)")
    }
}

@Test
func schemaThreeDecodesNumericHalfDropAndRequiredState() throws {
    let scene = try HarnessScene.decode(
        Data(
            """
            {
              "schemaVersion": 3,
              "name": "schema-three-half-drop",
              "width": 512,
              "height": 512,
              "tileWidth": 64,
              "tileHeight": 96,
              "tiling": 1,
              "diagnosticMode": "hardRound",
              "program": "halfDropEdge",
              "checks": [
                {
                  "channel": "canonical",
                  "x": 63,
                  "y": 95,
                  "expectedBGRA": [0, 0, 0, 255],
                  "tolerance": 1
                }
              ],
              "structuralChecks": [
                {
                  "metric": "oracleHoleCount",
                  "relation": "equal",
                  "value": 0
                }
              ]
            }
            """.utf8
        )
    )

    #expect(scene.program == .halfDropEdge)
    #expect(scene.tileWidth == 64)
    #expect(scene.tileHeight == 96)
    #expect(scene.tiling == .halfDrop)
    #expect(scene.diagnosticMode == .hardRound)
}

@Test(
    arguments: [
        ("tileWidth", 63, 96),
        ("tileWidth", 4_097, 96),
        ("tileHeight", 64, 63),
        ("tileHeight", 64, 4_097),
    ]
)
func schemaThreeRejectsTileDimensionsOutsideSupportedRange(
    field: String,
    tileWidth: Int,
    tileHeight: Int
) {
    let data = schemaThreeData(
        tileWidth: tileWidth,
        tileHeight: tileHeight
    )

    #expect(
        throws: HarnessSceneError.invalidTileDimensions(
            width: tileWidth,
            height: tileHeight
        ),
        "\(field)"
    ) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaThreeRejectsProgramTilingDisagreement() {
    let data = schemaThreeData(
        tiling: 0,
        program: "halfDropEdge"
    )

    #expect(
        throws: HarnessSceneError.programTilingMismatch(
            program: .halfDropEdge,
            tiling: .grid
        )
    ) {
        try HarnessScene.decode(data)
    }
}

@Test(
    arguments: [
        TilingHarnessProgram.gridInterior,
        .gridBoundary,
        .previewCommit,
        .cancelPreservesCanonical,
        .fiveHundredDabs,
        .longStroke,
    ]
)
func schemaThreeRequiresGridForEveryLegacyProgram(
    program: TilingHarnessProgram
) {
    let data = schemaThreeData(
        tiling: Int(TilingKind.halfDrop.rawValue),
        program: program.rawValue
    )

    #expect(
        throws: HarnessSceneError.programTilingMismatch(
            program: program,
            tiling: .halfDrop
        )
    ) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaThreeRejectsInteractiveDiagnosticMode() {
    let data = schemaThreeData(
        tiling: 1,
        diagnosticMode: "asymmetricCoverage",
        program: "projectedLongStroke"
    )

    #expect(
        throws: HarnessSceneError.interactiveDiagnosticRequiresHardRound(
            program: .projectedLongStroke,
            diagnosticMode: .asymmetricCoverage
        )
    ) {
        try HarnessScene.decode(data)
    }
}

@Test(
    arguments: [
        (TilingHarnessProgram.gridInterior, TilingKind.grid),
        (.gridBoundary, .grid),
        (.previewCommit, .grid),
        (.cancelPreservesCanonical, .grid),
        (.fiveHundredDabs, .grid),
        (.longStroke, .grid),
        (.generalizedGrid, .grid),
        (.halfDropInterior, .halfDrop),
        (.halfDropEdge, .halfDrop),
        (.halfDropCorner, .halfDrop),
        (.brickTranspose, .brick),
        (.rotationalFixedPoint, .rotational),
        (.largeFootprint, .grid),
        (.rectangularTile, .grid),
        (.noncentralVisibleCell, .grid),
        (.metadataTilingSwitch, .grid),
        (.projectedLiveCommit, .halfDrop),
        (.projectedLongStroke, .halfDrop),
    ]
)
func schemaThreeHardRoundProgramsRejectIgnoredDiagnosticModes(
    program: TilingHarnessProgram,
    tiling: TilingKind
) {
    let unsupportedModes: [HarnessDiagnosticMode] = [
        .asymmetricCoverage,
        .canonicalCoordinates,
        .brushLocalCoordinates,
    ]

    for diagnosticMode in unsupportedModes {
        let data = schemaThreeData(
            tiling: Int(tiling.rawValue),
            diagnosticMode: diagnosticMode.rawValue,
            program: program.rawValue
        )

        #expect(
            throws: HarnessSceneError.interactiveDiagnosticRequiresHardRound(
                program: program,
                diagnosticMode: diagnosticMode
            )
        ) {
            try HarnessScene.decode(data)
        }
    }
}

@Test(
    arguments: [
        (
            TilingHarnessProgram.mirrorX,
            TilingKind.mirrorX,
            HarnessDiagnosticMode.asymmetricCoverage
        ),
        (.mirrorY, .mirrorY, .asymmetricCoverage),
        (.mirrorXY, .mirrorXY, .asymmetricCoverage),
        (.rotationalGenerator, .rotational, .asymmetricCoverage),
        (.rotationalOrientation, .rotational, .asymmetricCoverage),
        (.asymmetricFootprint, .rotational, .asymmetricCoverage),
        (
            .canonicalCoordinateContinuity,
            .halfDrop,
            .canonicalCoordinates
        ),
        (
            .brushLocalCoordinateContinuity,
            .mirrorXY,
            .brushLocalCoordinates
        ),
    ]
)
func schemaThreeAcceptsTaskSevenDiagnosticProgramModes(
    program: TilingHarnessProgram,
    tiling: TilingKind,
    diagnosticMode: HarnessDiagnosticMode
) throws {
    let scene = try HarnessScene.decode(
        schemaThreeData(
            tiling: Int(tiling.rawValue),
            diagnosticMode: diagnosticMode.rawValue,
            program: program.rawValue
        )
    )

    #expect(scene.program == program)
    #expect(scene.tiling == tiling)
    #expect(scene.diagnosticMode == diagnosticMode)
}

@Test(arguments: ["tileWidth", "tileHeight", "tiling", "diagnosticMode"])
func schemaThreeRejectsEachMissingRequiredKey(key: String) throws {
    let object = try #require(
        JSONSerialization.jsonObject(
            with: schemaThreeData()
        ) as? [String: Any]
    )
    var missing = object
    missing.removeValue(forKey: key)
    let data = try JSONSerialization.data(withJSONObject: missing)

    #expect(throws: HarnessSceneError.missingSchemaThreeField(key)) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaThreeRejectsUnknownNumericTilingWireValue() {
    #expect(throws: DecodingError.self) {
        try HarnessScene.decode(schemaThreeData(tiling: 7))
    }
}

@Test
func schemaThreeRequiresAtLeastOneAssertion() {
    let data = schemaThreeData(checksJSON: "[]", structuralChecksJSON: "[]")

    #expect(throws: HarnessSceneError.missingAssertions) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaThreeCanonicalCoordinatesUseSceneTileDimensions() {
    let data = schemaThreeData(
        tileWidth: 64,
        tileHeight: 96,
        checksJSON: """
        [
          {
            "channel": "canonical",
            "x": 64,
            "y": 95,
            "expectedBGRA": [0, 0, 0, 255],
            "tolerance": 1
          }
        ]
        """
    )

    #expect(
        throws: HarnessSceneError.invalidCheckCoordinate(x: 64, y: 95)
    ) {
        try HarnessScene.decode(data)
    }
}

@Test
func legacyEncodingOmitsEverySchemaThreeKey() throws {
    let fixtures = [
        Data(
            """
            {
              "schemaVersion": 1,
              "name": "legacy-one",
              "width": 64,
              "height": 64,
              "checks": [
                {
                  "x": 0,
                  "y": 0,
                  "expectedBGRA": [241, 244, 242, 255],
                  "tolerance": 1
                }
              ]
            }
            """.utf8
        ),
        Data(
            """
            {
              "schemaVersion": 2,
              "name": "legacy-two",
              "width": 512,
              "height": 512,
              "program": "gridInterior",
              "checks": [],
              "structuralChecks": [
                {
                  "metric": "restampedInstanceCount",
                  "relation": "equal",
                  "value": 0
                }
              ]
            }
            """.utf8
        ),
    ]

    for fixture in fixtures {
        let scene = try HarnessScene.decode(fixture)
        let encoded = try JSONEncoder().encode(scene)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(object["tileWidth"] == nil)
        #expect(object["tileHeight"] == nil)
        #expect(object["tiling"] == nil)
        #expect(object["diagnosticMode"] == nil)
    }
}

@Test
func schemaThreeEncodingUsesNumericTilingAndDiagnosticString() throws {
    let scene = try HarnessScene.decode(schemaThreeData())
    let encoded = try JSONEncoder().encode(scene)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    #expect(object["tileWidth"] as? Int == 64)
    #expect(object["tileHeight"] as? Int == 96)
    #expect(object["tiling"] as? Int == 1)
    #expect(object["diagnosticMode"] as? String == "hardRound")
}

@Test
func schemaThreeArtifactChannelsAppendWithoutChangingLegacyRawValues() {
    #expect(HarnessPixelChannel.screen.rawValue == "screen")
    #expect(HarnessPixelChannel.liveScreen.rawValue == "liveScreen")
    #expect(HarnessPixelChannel.committedScreen.rawValue == "committedScreen")
    #expect(HarnessPixelChannel.canonical.rawValue == "canonical")
    #expect(
        HarnessPixelChannel.oracleCoverage.rawValue == "oracleCoverage"
    )
    #expect(
        HarnessPixelChannel.oracleCanonicalCoordinates.rawValue
            == "oracleCanonicalCoordinates"
    )
    #expect(
        HarnessPixelChannel.oracleBrushLocalCoordinates.rawValue
            == "oracleBrushLocalCoordinates"
    )
}

@Test
func tilingStructuralMismatchHasExactTypedDiagnostic() {
    let error = HarnessRunError.tilingStructuralMismatch(
        sceneName: "halfdrop-edge-negative-control",
        tiling: .halfDrop,
        cell: nil,
        metric: .oracleHoleCount,
        expectedRelation: .equal,
        expectedValue: 1,
        actualValue: 0
    )

    #expect(
        error.localizedDescription
            == "Tiling scene 'halfdrop-edge-negative-control' tiling halfDrop cell none metric oracleHoleCount: expected equal 1, actual 0."
    )
}

@Test
func productionCoverageUsesHalfCoverageThresholdAndAlphaChannel() {
    let coverage = HarnessRunner.productionCoverage(
        fromBGRA: [
            10, 20, 30, 0,
            10, 20, 30, 127,
            10, 20, 30, 128,
            10, 20, 30, 255,
        ],
        pixelSize: PixelSize(width: 2, height: 2)
    )

    #expect(coverage.bytes == [0, 0, 255, 255])
}

@Test
func schemaThreeMetricsAppendWithExactRawStrings() {
    let expected = [
        "oracleHoleCount",
        "oraclePhantomCount",
        "oracleMaximumDelta",
        "restoredDisplayMaximumDelta",
        "transformMismatchCount",
        "duplicateFixedPointWriteCount",
        "coordinateContinuityMismatchCount",
        "visibleCellCanonicalByteDelta",
        "previewCommitViolationCount",
    ]
    let actual = [
        HarnessStructuralMetric.oracleHoleCount,
        .oraclePhantomCount,
        .oracleMaximumDelta,
        .restoredDisplayMaximumDelta,
        .transformMismatchCount,
        .duplicateFixedPointWriteCount,
        .coordinateContinuityMismatchCount,
        .visibleCellCanonicalByteDelta,
        .previewCommitViolationCount,
    ].map(\.rawValue)

    #expect(actual == expected)
}

@Test
func runnerBoundaryResolvesLegacyDefaultsAndSchemaThreeValues() throws {
    let legacy = try HarnessScene.decode(
        Data(
            """
            {
              "schemaVersion": 2,
              "name": "legacy",
              "width": 512,
              "height": 512,
              "program": "gridInterior",
              "structuralChecks": [
                {
                  "metric": "restampedInstanceCount",
                  "relation": "equal",
                  "value": 0
                }
              ]
            }
            """.utf8
        )
    )
    let schemaThree = try HarnessScene.decode(schemaThreeData())

    #expect(
        HarnessRunner.configuration(for: legacy)
            == HarnessRenderConfiguration(
                pixelSize: PixelSize(width: 256, height: 256),
                tiling: .grid,
                diagnosticMode: .hardRound
            )
    )
    #expect(
        HarnessRunner.configuration(for: schemaThree)
            == HarnessRenderConfiguration(
                pixelSize: PixelSize(width: 64, height: 96),
                tiling: .halfDrop,
                diagnosticMode: .hardRound
            )
    )
}

@Test
func coverageComparisonUsesCorrespondingProductionCapture() {
    let expected = OracleCoverage(
        pixelSize: PixelSize(width: 2, height: 2),
        bytes: [255, 0, 255, 0]
    )
    let productionBGRA: [UInt8] = [
        0, 0, 0, 0,
        0, 0, 0, 255,
        0, 0, 0, 255,
        0, 0, 0, 0,
    ]

    #expect(
        HarnessRunner.compareOracleCoverage(
            expected: expected,
            productionBGRA: productionBGRA
        ) == CoverageComparison(
            holeCount: 1,
            phantomCount: 1,
            maximumDelta: 255
        )
    )
}

@Test
func rawBGRAAndCoveragePNGArtifactsAreActuallyWritten() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let bgraURL = directory.appendingPathComponent("coordinates.png")
    let coverageURL = directory.appendingPathComponent("coverage.png")

    try PNGWriter.writeBGRA(
        [
            0, 64, 128, 255,
            0, 128, 255, 255,
        ],
        pixelSize: PixelSize(width: 2, height: 1),
        to: bgraURL
    )
    try PNGWriter.write(
        coverage: OracleCoverage(
            pixelSize: PixelSize(width: 2, height: 1),
            bytes: [0, 255]
        ),
        to: coverageURL
    )

    let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    #expect(try Data(contentsOf: bgraURL).prefix(8) == pngSignature)
    #expect(try Data(contentsOf: coverageURL).prefix(8) == pngSignature)
}

@Test
func schemaThreeStructuralEvaluationThrowsExactTypedError() throws {
    let scene = try HarnessScene.decode(schemaThreeData())

    #expect(
        throws: HarnessRunError.tilingStructuralMismatch(
            sceneName: "schema-three",
            tiling: .halfDrop,
            cell: nil,
            metric: .oracleHoleCount,
            expectedRelation: .equal,
            expectedValue: 0,
            actualValue: 1
        )
    ) {
        try HarnessRunner.evaluateStructuralChecks(
            scene: scene,
            values: [.oracleHoleCount: 1]
        )
    }
}

@Test
func translationProgramsUseTheApprovedDeterministicWorldInputs() {
    let expected: [(TilingHarnessProgram, TilingKind, WorldPoint)] = [
        (.generalizedGrid, .grid, WorldPoint(x: -2, y: -2)),
        (.halfDropInterior, .halfDrop, WorldPoint(x: 432, y: 144)),
        (.halfDropEdge, .halfDrop, WorldPoint(x: 288, y: 96)),
        (.halfDropCorner, .halfDrop, WorldPoint(x: 288, y: 288)),
        (.brickTranspose, .brick, WorldPoint(x: 144, y: 192)),
    ]

    for (program, tiling, center) in expected {
        #expect(
            HarnessRunner.translationInput(for: program)
                == TranslationHarnessInput(
                    center: center,
                    tiling: tiling,
                    capturesPhasedGridLines: tiling != .grid
                )
        )
    }
}

@Test
func translationScenePairsExistAndDifferByOnlyTheIntendedAssertion() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
    let pairs: [(String, HarnessStructuralMetric)] = [
        ("generalized-grid", .oracleHoleCount),
        ("halfdrop-interior", .oraclePhantomCount),
        ("halfdrop-edge", .oracleHoleCount),
        ("halfdrop-corner", .oraclePhantomCount),
        ("brick-transpose", .transformMismatchCount),
    ]

    for (name, negativeMetric) in pairs {
        let positiveData = try Data(
            contentsOf: scenesDirectory.appendingPathComponent("\(name).json")
        )
        let negativeData = try Data(
            contentsOf: scenesDirectory.appendingPathComponent(
                "\(name)-negative-control.json"
            )
        )
        let positive = try HarnessScene.decode(positiveData)
        let negative = try HarnessScene.decode(negativeData)

        #expect(positive.name == name)
        #expect(negative.name == "\(name)-negative-control")
        #expect(positive.program == negative.program)
        #expect(positive.tileWidth == negative.tileWidth)
        #expect(positive.tileHeight == negative.tileHeight)
        #expect(positive.tiling == negative.tiling)
        #expect(positive.diagnosticMode == negative.diagnosticMode)
        #expect(positive.checks == negative.checks)
        #expect(positive.structuralChecks.count == negative.structuralChecks.count)

        for (positiveCheck, negativeCheck) in zip(
            positive.structuralChecks,
            negative.structuralChecks
        ) {
            #expect(positiveCheck.metric == negativeCheck.metric)
            #expect(positiveCheck.relation == negativeCheck.relation)
            if positiveCheck.metric == negativeMetric {
                #expect(positiveCheck.value == 0)
                #expect(negativeCheck.value == 1)
            } else {
                #expect(positiveCheck.value == negativeCheck.value)
            }
        }
    }
}

@Test
func halfDropEdgeFixtureHasTheExactApprovedShape() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repositoryRoot.appendingPathComponent(
        "App/PatternSpike/Harness/Scenes/halfdrop-edge.json"
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
    )

    #expect(Set(object.keys) == [
        "schemaVersion", "name", "width", "height", "tileWidth",
        "tileHeight", "tiling", "diagnosticMode", "program", "checks",
        "structuralChecks",
    ])
    #expect(object["schemaVersion"] as? Int == 3)
    #expect(object["name"] as? String == "halfdrop-edge")
    #expect(object["width"] as? Int == 512)
    #expect(object["height"] as? Int == 512)
    #expect(object["tileWidth"] as? Int == 288)
    #expect(object["tileHeight"] as? Int == 192)
    #expect(object["tiling"] as? Int == 1)
    #expect(object["diagnosticMode"] as? String == "hardRound")
    #expect(object["program"] as? String == "halfDropEdge")
    #expect((object["checks"] as? [[String: Any]])?.count == 1)
    #expect(
        (object["structuralChecks"] as? [[String: Any]])?.count == 3
    )
}

@Test
func phasedGridLineProbeFailsClosedWithoutUnsignedOverflow() {
    #expect(
        HarnessRunner.isPhasedGridLineVisible(
            line: SIMD4(199, 202, 198, 255),
            offLine: SIMD4(241, 244, 242, 255)
        )
    )
    #expect(
        !HarnessRunner.isPhasedGridLineVisible(
            line: SIMD4(241, 244, 242, 255),
            offLine: SIMD4(241, 244, 242, 255)
        )
    )
}

@Test
func oracleMetricsArtifactEncodesIndependentComparisonValues() throws {
    let metrics = HarnessOracleMetrics(
        oracleHoleCount: 0,
        oraclePhantomCount: 0,
        oracleMaximumDelta: 1,
        transformMismatchCount: 0
    )
    let object = try #require(
        JSONSerialization.jsonObject(
            with: try HarnessOracleMetrics.encode(metrics)
        ) as? [String: Int]
    )

    #expect(object == [
        "oracleHoleCount": 0,
        "oraclePhantomCount": 0,
        "oracleMaximumDelta": 1,
        "transformMismatchCount": 0,
    ])
}

private func schemaThreeData(
    tileWidth: Int = 64,
    tileHeight: Int = 96,
    tiling: Int = 1,
    diagnosticMode: String = "hardRound",
    program: String = "halfDropEdge",
    checksJSON: String = """
    [
      {
        "channel": "canonical",
        "x": 0,
        "y": 0,
        "expectedBGRA": [0, 0, 0, 255],
        "tolerance": 1
      }
    ]
    """,
    structuralChecksJSON: String = """
    [
      {
        "metric": "oracleHoleCount",
        "relation": "equal",
        "value": 0
      }
    ]
    """
) -> Data {
    Data(
        """
        {
          "schemaVersion": 3,
          "name": "schema-three",
          "width": 512,
          "height": 512,
          "tileWidth": \(tileWidth),
          "tileHeight": \(tileHeight),
          "tiling": \(tiling),
          "diagnosticMode": "\(diagnosticMode)",
          "program": "\(program)",
          "checks": \(checksJSON),
          "structuralChecks": \(structuralChecksJSON)
        }
        """.utf8
    )
}
