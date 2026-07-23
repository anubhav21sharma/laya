import Foundation
import CShaderTypes
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
          "schemaVersion": 6,
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

    #expect(throws: HarnessSceneError.unsupportedSchema(6)) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaFiveRoundTripsRequiredStrokeProvenanceAndChecks() throws {
    let scene = try HarnessScene.decode(schemaFiveData())

    #expect(scene.schemaVersion == 5)
    #expect(scene.recipeID == "anchor.ink")
    #expect(scene.seed == UInt64.max)
    #expect(scene.expectedMaterial == .ink)
    #expect(scene.replayMode == .replayTail)
    #expect(scene.attributedSamples.count == 2)
    #expect(scene.attributedSamples[0].phase == .began)
    #expect(scene.attributedSamples[0].source == .tablet)
    #expect(scene.attributedSamples[0].kind == .actual)
    #expect(scene.attributedSamples[0].capabilities == 7)
    #expect(scene.attributedSamples[0].strokeSample?.pressure == 0.25)
    #expect(scene.structuralChecks[0].metric == .peakRetainedSampleCount)

    let encoded = try JSONEncoder().encode(scene)
    let decoded = try HarnessScene.decode(encoded)
    #expect(decoded == scene)
}

@Test(arguments: [
    "recipeID",
    "seed",
    "attributedSamples",
    "expectedMaterial",
    "replayMode",
])
func schemaFiveRequiresEveryStrokeProvenanceField(_ key: String) throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: schemaFiveData())
            as? [String: Any]
    )
    object.removeValue(forKey: key)

    #expect(throws: HarnessSceneError.missingSchemaFiveField(key)) {
        try HarnessScene.decode(JSONSerialization.data(withJSONObject: object))
    }
}

@Test
func schemaFiveRejectsZeroSeedAndEmptyTrace() throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: schemaFiveData())
            as? [String: Any]
    )
    object["seed"] = 0
    #expect(throws: HarnessSceneError.invalidSchemaFiveSeed) {
        try HarnessScene.decode(JSONSerialization.data(withJSONObject: object))
    }

    object = try #require(
        JSONSerialization.jsonObject(with: schemaFiveData())
            as? [String: Any]
    )
    object["attributedSamples"] = []
    #expect(throws: HarnessSceneError.missingAttributedSamples) {
        try HarnessScene.decode(JSONSerialization.data(withJSONObject: object))
    }
}

@Test
func schemaFiveRejectsUnknownSampleCapabilities() throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: schemaFiveData())
            as? [String: Any]
    )
    var samples = try #require(
        object["attributedSamples"] as? [[String: Any]]
    )
    samples[1]["capabilities"] = 16
    object["attributedSamples"] = samples

    #expect(throws: HarnessSceneError.invalidAttributedSample(1)) {
        try HarnessScene.decode(JSONSerialization.data(withJSONObject: object))
    }
}

@Test
func schemaFourRejectsSliceFourOnlyStructuralMetrics() throws {
    let text = String(decoding: schemaFourData(), as: UTF8.self)
        .replacingOccurrences(
            of: "undoCanonicalByteDelta",
            with: "peakRetainedSampleCount"
        )

    #expect(
        throws: HarnessSceneError.structuralMetricUnavailableForSchema(
            metric: .peakRetainedSampleCount,
            schemaVersion: 4
        )
    ) {
        try HarnessScene.decode(Data(text.utf8))
    }
}

@Test
func sliceFourTraceCatalogIsReusableAtTheHarnessBoundary() {
    #expect(StrokeTraceFixtures.all.count == 8)
    #expect(StrokeTraceFixtures.gridSeam.samples.map(\.phase) == [
        .began,
        .moved,
        .ended,
    ])
    #expect(
        StrokeTraceFixtures.reflectedCell.samples.allSatisfy {
            $0.source == .tablet
        }
    )
}

@Test(arguments: [
    "coloredDraw",
    "eraserLiveCommit",
    "regionUndoSeam",
    "clearUndo",
    "tilingUndo",
    "resizeCropFill",
])
func schemaFourDecodesOnlySliceThreePrograms(_ program: String) throws {
    let scene = try HarnessScene.decode(
        schemaFourData(program: program)
    )

    #expect(scene.schemaVersion == 4)
    #expect(scene.program?.rawValue == program)
    #expect(scene.tileWidth == 96)
    #expect(scene.tileHeight == 80)
    #expect(scene.tiling == .grid)
    #expect(scene.diagnosticMode == .hardRound)
    #expect(scene.recipeID == nil)
    #expect(scene.seed == nil)
    #expect(scene.attributedSamples.isEmpty)
    #expect(scene.expectedMaterial == nil)
    #expect(scene.replayMode == nil)
}

@Test(arguments: [
    "tileWidth",
    "tileHeight",
    "tiling",
    "diagnosticMode",
    "program",
])
func schemaFourRequiresEverySchemaThreeProgramField(_ key: String) {
    let text = String(decoding: schemaFourData(), as: UTF8.self)
    let filtered = text
        .split(whereSeparator: \.isNewline)
        .filter { !$0.contains("\"\(key)\"") }
        .joined(separator: "\n")

    #expect(throws: HarnessSceneError.missingSchemaFourField(key)) {
        try HarnessScene.decode(Data(filtered.utf8))
    }
}

@Test
func schemaFourRejectsLegacyProgramsAndLegacySchemasRejectSliceThreePrograms() {
    #expect(
        throws: HarnessSceneError.programUnavailableForSchema(
            program: .halfDropEdge,
            schemaVersion: 4
        )
    ) {
        try HarnessScene.decode(schemaFourData(program: "halfDropEdge"))
    }

    for schemaVersion in [2, 3] {
        let data = schemaVersion == 2
            ? Data(
                """
                {
                  "schemaVersion": 2,
                  "name": "legacy-rejects-slice-three",
                  "width": 96,
                  "height": 80,
                  "program": "coloredDraw",
                  "checks": [],
                  "structuralChecks": [
                    {"metric":"oracleHoleCount","relation":"equal","value":0}
                  ]
                }
                """.utf8
            )
            : schemaThreeData(
                program: "coloredDraw",
                checksJSON: "[]",
                structuralChecksJSON: """
                [
                  {"metric":"oracleHoleCount","relation":"equal","value":0}
                ]
                """
            )
        #expect(
            throws: HarnessSceneError.programUnavailableForSchema(
                program: .coloredDraw,
                schemaVersion: schemaVersion
            )
        ) {
            try HarnessScene.decode(data)
        }
    }
}

@Test
func legacySchemasRejectSliceThreeOnlyStructuralMetrics() {
    #expect(
        throws: HarnessSceneError.structuralMetricUnavailableForSchema(
            metric: .historyCommandCount,
            schemaVersion: 3
        )
    ) {
        try HarnessScene.decode(
            schemaThreeData(
                checksJSON: "[]",
                structuralChecksJSON: """
                [
                  {"metric":"historyCommandCount","relation":"equal","value":0}
                ]
                """
            )
        )
    }
}

@Test
func sliceThreeStructuralDiagnosticIsByteExact() {
    let error = SliceThreeHarnessRunError.structuralMismatch(
        sceneName: "colored-draw-negative-control",
        metric: .coloredOutputMismatchCount,
        expectedRelation: .equal,
        expectedValue: 1,
        actualValue: 0
    )

    #expect(
        error.localizedDescription
            == "Slice 3 scene 'colored-draw-negative-control' metric coloredOutputMismatchCount: expected equal 1, actual 0."
    )
}

@Test
func sliceThreeScenePairsAreSchemaFourAndDifferOnlyAtNamedExpectation() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let directory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
    let pairs: [(String, TilingHarnessProgram, HarnessStructuralMetric)] = [
        ("colored-draw", .coloredDraw, .coloredOutputMismatchCount),
        ("eraser-live-commit", .eraserLiveCommit, .previewCommitViolationCount),
        ("region-undo-seam", .regionUndoSeam, .undoCanonicalByteDelta),
        ("clear-undo", .clearUndo, .redoCanonicalByteDelta),
        ("tiling-undo", .tilingUndo, .metadataCanonicalByteDelta),
        ("resize-crop-fill", .resizeCropFill, .redoCanonicalByteDelta),
    ]

    for (name, program, metric) in pairs {
        let positiveURL = directory.appendingPathComponent("\(name).json")
        let negativeURL = directory.appendingPathComponent(
            "\(name)-negative-control.json"
        )
        let positive = try HarnessScene.decode(Data(contentsOf: positiveURL))
        let negative = try HarnessScene.decode(Data(contentsOf: negativeURL))

        #expect(positive.schemaVersion == 4, "\(name)")
        #expect(positive.program == program, "\(name)")
        #expect(negative.name == "\(name)-negative-control", "\(name)")
        if name == "colored-draw" {
            let check = try #require(positive.checks.first)
            #expect(positive.checks.count == 1)
            #expect(check.channel == .canonical)
            #expect(check.x == 64)
            #expect(check.y == 64)
            #expect(check.expectedBGRA == [38, 77, 153, 191])
            #expect(check.tolerance == 1)
        } else if name == "eraser-live-commit" {
            let check = try #require(positive.checks.first)
            #expect(positive.checks.count == 1)
            #expect(check.channel == .canonical)
            #expect(check.x == 64)
            #expect(check.y == 64)
            #expect(check.expectedBGRA == [0, 0, 0, 0])
            #expect(check.tolerance == 0)
        }
        #expect(positive.structuralChecks.count == negative.structuralChecks.count)
        let positiveCheck = try #require(
            positive.structuralChecks.first { $0.metric == metric }
        )
        let negativeCheck = try #require(
            negative.structuralChecks.first { $0.metric == metric }
        )
        #expect(positiveCheck.relation == .equal)
        #expect(positiveCheck.value == 0)
        #expect(negativeCheck.relation == .equal)
        #expect(negativeCheck.value == 1)

        var normalizedNegative = try taskSevenSceneObject(at: negativeURL)
        normalizedNegative["name"] = name
        var checks = try #require(
            normalizedNegative["structuralChecks"] as? [[String: Any]]
        )
        let index = try #require(
            checks.firstIndex { $0["metric"] as? String == metric.rawValue }
        )
        checks[index]["value"] = 0
        normalizedNegative["structuralChecks"] = checks
        let positiveObject = try taskSevenSceneObject(at: positiveURL)
        #expect(
            NSDictionary(dictionary: normalizedNegative)
                .isEqual(to: positiveObject),
            "\(name)"
        )
    }
}

@Test
func sliceThreeRunnerUsesTheAppLayerDocumentHistorySeam() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let rendererRunner = repositoryRoot.appendingPathComponent(
        "Sources/MetalRenderer/Capture/SliceThreeHarnessRunner.swift"
    )
    let appRunner = repositoryRoot.appendingPathComponent(
        "App/PatternSpike/Harness/SliceThreeHarnessRunner.swift"
    )

    #expect(!FileManager.default.fileExists(atPath: rendererRunner.path))
    let source = try String(contentsOf: appRunner, encoding: .utf8)
    #expect(source.contains("SliceThreeHarnessHistory"))
    #expect(source.contains("history.evidence"))
    #expect(source.contains("history.beginUndo()"))
    #expect(source.contains("history.beginRedo()"))
    #expect(!source.contains("harnessRasterRevisionResidentBytes"))
}

@Test
func sliceThreeGatePinsNegativeFirstOrderAndApprovedProjectedABI() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let gate = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/verify-slice3.sh"
        ),
        encoding: .utf8
    )
    let sliceTwoGate = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/verify-slice2.sh"
        ),
        encoding: .utf8
    )
    let expectedOrder = [
        "colored-draw|coloredOutputMismatchCount",
        "eraser-live-commit|previewCommitViolationCount",
        "region-undo-seam|undoCanonicalByteDelta",
        "clear-undo|redoCanonicalByteDelta",
        "tiling-undo|metadataCanonicalByteDelta",
        "resize-crop-fill|redoCanonicalByteDelta",
    ]
    var previous = gate.startIndex
    for row in expectedOrder {
        let range = try #require(gate.range(of: row, range: previous..<gate.endIndex))
        previous = range.upperBound
    }
    #expect(gate.contains("bytes == fragments * 128"))
    #expect(gate.contains("totalInstanceBytes == 512"))
    #expect(gate.contains("four fragments must retain 512 instance bytes"))
    #expect(sliceTwoGate.contains("bytes == fragments * 128"))
    #expect(sliceTwoGate.contains("128-byte instance accounting"))
    #expect(!sliceTwoGate.contains("bytes == fragments * 112"))
    #expect(gate.contains("SLICE3 GATE PASS"))
    #expect(!gate.contains("retry"))
    #expect(!gate.contains("warmup"))
    #expect(gate.contains("host_arch=\"$(uname -m)\""))
    #expect(gate.contains("platform=macOS,arch=$host_arch"))
}

@Test
func sliceThreeGatePreflightRejectsUntrackedSwiftInput() throws {
    let repository = try makeSliceThreeGatePreflightRepository()
    defer { try? FileManager.default.removeItem(at: repository) }
    let input = repository.appendingPathComponent(
        "Sources/UntrackedGateInput.swift"
    )
    try "struct UntrackedGateInput {}\n".write(to: input, atomically: true, encoding: .utf8)

    let result = try runSliceThreeGatePreflight(in: repository)

    #expect(result.status == 1)
    #expect(
        result.standardError.contains(
            "untracked build input is outside committed HEAD: Sources/UntrackedGateInput.swift"
        )
    )
}

@Test
func sliceThreeGatePreflightAllowsUnrelatedVSCodeFiles() throws {
    let repository = try makeSliceThreeGatePreflightRepository()
    defer { try? FileManager.default.removeItem(at: repository) }
    let settings = repository.appendingPathComponent(".vscode/launch.json")
    try "{}\n".write(to: settings, atomically: true, encoding: .utf8)

    let result = try runSliceThreeGatePreflight(in: repository)

    #expect(result.status == 0)
    #expect(result.standardError.isEmpty)
}

@Test
func sliceThreeGateDefersPerformancePendingUntilCompletionAudit() throws {
    let result = try runSliceThreeGateCompletionSimulation(
        ignoreAuditFails: false
    )

    #expect(result.status == 1)
    #expect(result.standardOutput.isEmpty)
    #expect(
        result.standardError
            == """
            SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment 'Apple Paravirtual device'.
            SLICE3 GATE ERROR: stable real-Metal performance acceptance remains pending

            """
    )
    #expect(result.trace == [
        "strict-validation",
        "generated-artifact-ignore",
        "source-provenance",
    ])
}

@Test
func sliceThreeGateAuditFailureOverridesDeferredPerformancePending() throws {
    let result = try runSliceThreeGateCompletionSimulation(
        ignoreAuditFails: true
    )

    #expect(result.status == 1)
    #expect(result.standardOutput.isEmpty)
    #expect(
        result.standardError
            == "SLICE3 GATE ERROR: simulated generated-artifact ignore failure\n"
    )
    #expect(result.trace == [
        "strict-validation",
        "generated-artifact-ignore",
        "source-provenance",
    ])
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

@Test
func schemaThreeDecodesEveryLegacyNumericTilingValue() throws {
    let expectedPresets: [SymmetryPresetID] = [
        .grid,
        .halfDrop,
        .brick,
        .mirrorX,
        .mirrorY,
        .mirrorXY,
        .rotational,
    ]

    for (rawValue, expectedPreset) in expectedPresets.enumerated() {
        let scene = try HarnessScene.decode(
            schemaThreeData(
                tiling: rawValue,
                program: TilingHarnessProgram.noncentralVisibleCell.rawValue
            )
        )

        #expect(
            scene.tiling == expectedPreset,
            "raw tiling \(rawValue)"
        )
    }
}

@Test
func schemaThreeRoundTripKeepsNumericTilingWithoutDescriptors() throws {
    for rawValue in 0...6 {
        let scene = try HarnessScene.decode(
            schemaThreeData(
                tiling: rawValue,
                program: TilingHarnessProgram.noncentralVisibleCell.rawValue
            )
        )
        let encoded = try JSONEncoder().encode(scene)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(object["tiling"] as? Int == rawValue)
        #expect(Set(object.keys) == [
            "schemaVersion",
            "name",
            "width",
            "height",
            "checks",
            "program",
            "structuralChecks",
            "tileWidth",
            "tileHeight",
            "tiling",
            "diagnosticMode",
        ])
        #expect(object["presetID"] == nil)
        #expect(object["symmetryFamily"] == nil)
        #expect(object["compiledSymmetry"] == nil)
        #expect(object["isometries"] == nil)
        #expect(object["ownership"] == nil)
        #expect(object["displayProgram"] == nil)

        let decoded = try HarnessScene.decode(encoded)
        #expect(decoded == scene)
    }
}

@Test
func schemaThreeRoundTripsVersionedPeriodicConfiguration() throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: schemaThreeData(
            tileWidth: 256,
            tileHeight: 256,
            tiling: 7,
            program: TilingHarnessProgram.noncentralVisibleCell.rawValue
        )) as? [String: Any]
    )
    object["periodicConfiguration"] = [
        "version": 1,
        "repeatWidth": 192,
        "repeatHeight": 192,
        "orientationRadians": 0.25,
    ]

    let scene = try HarnessScene.decode(
        JSONSerialization.data(withJSONObject: object)
    )

    #expect(scene.tiling == .squareRotation)
    #expect(scene.periodicConfiguration == HarnessPeriodicConfiguration(
        repeatWidth: 192,
        repeatHeight: 192,
        orientationRadians: 0.25
    ))
    let decoded = try HarnessScene.decode(JSONEncoder().encode(scene))
    #expect(decoded == scene)
}

@Test
func periodicConfigurationRejectsUnsupportedVersionAndNonSquareRepeat() throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: schemaThreeData(
            tileWidth: 256,
            tileHeight: 256,
            tiling: 8,
            program: TilingHarnessProgram.noncentralVisibleCell.rawValue
        )) as? [String: Any]
    )
    object["periodicConfiguration"] = [
        "version": 2,
        "repeatWidth": 192,
        "repeatHeight": 192,
        "orientationRadians": 0,
    ]
    #expect(
        throws: HarnessSceneError.unsupportedPeriodicConfigurationVersion(2)
    ) {
        try HarnessScene.decode(
            JSONSerialization.data(withJSONObject: object)
        )
    }

    object["periodicConfiguration"] = [
        "version": 1,
        "repeatWidth": 192,
        "repeatHeight": 160,
        "orientationRadians": 0,
    ]
    #expect(
        throws: HarnessSceneError.invalidPeriodicConfiguration(
            .nonSquareRepeat(width: 192, height: 160)
        )
    ) {
        try HarnessScene.decode(
            JSONSerialization.data(withJSONObject: object)
        )
    }
}

@Test
func periodicConfigurationRejectsNonpositiveRepeatBeforeProductionConversion()
    throws
{
    var object = try #require(
        JSONSerialization.jsonObject(with: schemaThreeData(
            tileWidth: 256,
            tileHeight: 192,
            tiling: 7,
            program: TilingHarnessProgram.noncentralVisibleCell.rawValue
        )) as? [String: Any]
    )
    object["periodicConfiguration"] = [
        "version": 1,
        "repeatWidth": 0,
        "repeatHeight": 0,
        "orientationRadians": 0,
    ]

    #expect(
        throws: HarnessSceneError.invalidPeriodicRepeatDimensions(
            width: 0,
            height: 0
        )
    ) {
        try HarnessScene.decode(
            JSONSerialization.data(withJSONObject: object)
        )
    }
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
        (.squareFixedPoint, .squareRotation),
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
        try HarnessScene.decode(schemaThreeData(tiling: 9))
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
func runnerBoundaryPreservesExplicitPeriodicConfiguration() throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: schemaThreeData(
            tileWidth: 256,
            tileHeight: 256,
            tiling: 8,
            program: TilingHarnessProgram.noncentralVisibleCell.rawValue
        )) as? [String: Any]
    )
    object["periodicConfiguration"] = [
        "version": 1,
        "repeatWidth": 176,
        "repeatHeight": 176,
        "orientationRadians": 0.125,
    ]
    let scene = try HarnessScene.decode(
        JSONSerialization.data(withJSONObject: object)
    )

    #expect(
        HarnessRunner.configuration(for: scene)
            == HarnessRenderConfiguration(
                pixelSize: PixelSize(width: 256, height: 256),
                periodicConfiguration: PeriodicSymmetryConfiguration(
                    presetID: .squareKaleidoscope,
                    repeatSize: PatternSize(width: 176, height: 176),
                    orientationRadians: 0.125
                ),
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

        let intendedIndex = try #require(
            positive.structuralChecks.firstIndex {
                $0.metric == negativeMetric
            }
        )
        for (index, pair) in zip(
            positive.structuralChecks,
            negative.structuralChecks
        ).enumerated() {
            let (positiveCheck, negativeCheck) = pair
            #expect(positiveCheck.metric == negativeCheck.metric)
            #expect(positiveCheck.relation == negativeCheck.relation)
            if index == intendedIndex {
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
        (object["structuralChecks"] as? [[String: Any]])?.count == 4
    )
}

@Test(arguments: [
    "halfdrop-edge",
    "halfdrop-edge-negative-control",
])
func halfDropEdgePairDecodesOnlyTheExactCanonicalPixelCheck(
    sceneName: String
) throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repositoryRoot.appendingPathComponent(
        "App/PatternSpike/Harness/Scenes/\(sceneName).json"
    )
    let scene = try JSONDecoder().decode(
        HarnessScene.self,
        from: Data(contentsOf: url)
    )

    #expect(scene.checks.count == 1)
    let check = try #require(scene.checks.first)
    #expect(check.channel == .canonical)
    #expect(check.x == 0)
    #expect(check.y == 0)
    #expect(check.expectedBGRA == [0, 0, 0, 255])
    #expect(check.tolerance == 1)
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

@Test
func taskSevenScenePairsExistAndDifferByOneIntendedAssertion() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
    let pairs: [(String, HarnessStructuralMetric)] = [
        ("mirror-x", .transformMismatchCount),
        ("mirror-y", .transformMismatchCount),
        ("mirror-xy", .transformMismatchCount),
        ("rotational-generator", .transformMismatchCount),
        ("rotational-fixed-point", .duplicateFixedPointWriteCount),
        ("rotational-orientation", .transformMismatchCount),
        ("large-footprint", .oracleHoleCount),
        ("asymmetric-footprint", .transformMismatchCount),
        (
            "canonical-coordinate-continuity",
            .coordinateContinuityMismatchCount
        ),
        (
            "brush-local-coordinate-continuity",
            .coordinateContinuityMismatchCount
        ),
    ]

    for (name, negativeMetric) in pairs {
        let positiveObject = try taskSevenSceneObject(
            at: scenesDirectory.appendingPathComponent("\(name).json")
        )
        let negativeObject = try taskSevenSceneObject(
            at: scenesDirectory.appendingPathComponent(
                "\(name)-negative-control.json"
            )
        )
        var normalizedPositive = positiveObject
        var normalizedNegative = negativeObject
        normalizedPositive["name"] = "<name>"
        normalizedNegative["name"] = "<name>"
        let positiveChecks = try #require(
            normalizedPositive["structuralChecks"] as? [[String: Any]]
        )
        var negativeChecks = try #require(
            normalizedNegative["structuralChecks"] as? [[String: Any]]
        )
        let intendedIndex = try #require(
            positiveChecks.firstIndex {
                $0["metric"] as? String == negativeMetric.rawValue
            }
        )
        #expect(positiveChecks[intendedIndex]["value"] as? Int == 0)
        #expect(negativeChecks[intendedIndex]["value"] as? Int == 1)
        negativeChecks[intendedIndex]["value"] = 0
        normalizedPositive["structuralChecks"] = positiveChecks
        normalizedNegative["structuralChecks"] = negativeChecks

        #expect(
            NSDictionary(dictionary: normalizedPositive)
                .isEqual(to: normalizedNegative),
            "\(name)"
        )
    }
}

@Test
func taskSevenScenesUseTheExactApprovedProgramMatrix() throws {
    let expected: [
        (String, TilingHarnessProgram, TilingKind, HarnessDiagnosticMode)
    ] = [
        ("mirror-x", .mirrorX, .mirrorX, .asymmetricCoverage),
        ("mirror-y", .mirrorY, .mirrorY, .asymmetricCoverage),
        ("mirror-xy", .mirrorXY, .mirrorXY, .asymmetricCoverage),
        (
            "rotational-generator",
            .rotationalGenerator,
            .rotational,
            .asymmetricCoverage
        ),
        (
            "rotational-fixed-point",
            .rotationalFixedPoint,
            .rotational,
            .hardRound
        ),
        (
            "rotational-orientation",
            .rotationalOrientation,
            .rotational,
            .asymmetricCoverage
        ),
        ("large-footprint", .largeFootprint, .grid, .hardRound),
        (
            "asymmetric-footprint",
            .asymmetricFootprint,
            .rotational,
            .asymmetricCoverage
        ),
        (
            "canonical-coordinate-continuity",
            .canonicalCoordinateContinuity,
            .halfDrop,
            .canonicalCoordinates
        ),
        (
            "brush-local-coordinate-continuity",
            .brushLocalCoordinateContinuity,
            .mirrorXY,
            .brushLocalCoordinates
        ),
    ]
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")

    for (name, program, tiling, mode) in expected {
        let scene = try HarnessScene.decode(
            Data(
                contentsOf: scenesDirectory.appendingPathComponent(
                    "\(name).json"
                )
            )
        )
        #expect(scene.program == program, "\(name)")
        #expect(scene.tiling == tiling, "\(name)")
        #expect(scene.diagnosticMode == mode, "\(name)")
        #expect(scene.width == 512, "\(name)")
        #expect(scene.height == 512, "\(name)")
    }
}

@Test
func taskSevenTileSizesAndRunnerInputsMatchTheApprovedMatrix() throws {
    struct Expected {
        let name: String
        let tileSize: PixelSize
        let translation: SIMD2<Float>
        let xAxis: SIMD2<Float>
        let yAxis: SIMD2<Float>
        let radius: Float
        let diagnosticMode: HarnessDiagnosticMode
        let oracleFootprint: OracleFootprint
        let requiresDistantCells: Bool
    }
    let angle: Float = 0.37
    let expected: [Expected] = [
        Expected(
            name: "mirror-x",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(256, 96),
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, 40),
            radius: 40,
            diagnosticMode: .asymmetricCoverage,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
        Expected(
            name: "mirror-y",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(96, 256),
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, 40),
            radius: 40,
            diagnosticMode: .asymmetricCoverage,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
        Expected(
            name: "mirror-xy",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(256, 256),
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, 40),
            radius: 40,
            diagnosticMode: .asymmetricCoverage,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
        Expected(
            name: "rotational-generator",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(64, 80),
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, 40),
            radius: 40,
            diagnosticMode: .asymmetricCoverage,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
        Expected(
            name: "rotational-fixed-point",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(128, 128),
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 1),
            radius: 10,
            diagnosticMode: .hardRound,
            oracleFootprint: .hardRound(radius: 10),
            requiresDistantCells: false
        ),
        Expected(
            name: "rotational-orientation",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(64, 80),
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, 40),
            radius: 40,
            diagnosticMode: .asymmetricCoverage,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
        Expected(
            name: "large-footprint",
            tileSize: PixelSize(width: 64, height: 96),
            translation: SIMD2(0, 0),
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 1),
            radius: 256,
            diagnosticMode: .hardRound,
            oracleFootprint: .hardRound(radius: 256),
            requiresDistantCells: true
        ),
        Expected(
            name: "asymmetric-footprint",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(250, 128),
            xAxis: SIMD2(cos(angle), sin(angle)) * 40,
            yAxis: SIMD2(-sin(angle), cos(angle)) * 40,
            radius: 40,
            diagnosticMode: .asymmetricCoverage,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
        Expected(
            name: "canonical-coordinate-continuity",
            tileSize: PixelSize(width: 288, height: 192),
            translation: SIMD2(288, 96),
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, 40),
            radius: 40,
            diagnosticMode: .canonicalCoordinates,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
        Expected(
            name: "brush-local-coordinate-continuity",
            tileSize: PixelSize(width: 256, height: 256),
            translation: SIMD2(256, 256),
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, 40),
            radius: 40,
            diagnosticMode: .brushLocalCoordinates,
            oracleFootprint: .asymmetricTriangle,
            requiresDistantCells: false
        ),
    ]
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")

    for item in expected {
        let scene = try HarnessScene.decode(
            Data(
                contentsOf: scenesDirectory.appendingPathComponent(
                    "\(item.name).json"
                )
            )
        )
        let program = try #require(scene.program)
        let input = try #require(HarnessRunner.taskSevenInput(for: program))
        #expect(scene.tileWidth == item.tileSize.width, "\(item.name)")
        #expect(scene.tileHeight == item.tileSize.height, "\(item.name)")
        #expect(input.brushToWorld.translation == item.translation, "\(item.name)")
        #expect(input.brushToWorld.xAxis == item.xAxis, "\(item.name)")
        #expect(input.brushToWorld.yAxis == item.yAxis, "\(item.name)")
        #expect(input.radius == item.radius, "\(item.name)")
        #expect(input.diagnosticMode == item.diagnosticMode, "\(item.name)")
        #expect(input.oracleFootprint == item.oracleFootprint, "\(item.name)")
        #expect(
            input.requiresDistantCells == item.requiresDistantCells,
            "\(item.name)"
        )
        switch item.oracleFootprint {
        case .asymmetricTriangle:
            #expect(
                input.stampFootprint.brushToWorld == input.brushToWorld,
                "\(item.name)"
            )
            #expect(
                input.stampFootprint.localBounds
                    == AxisAlignedRect(
                        minimum: SIMD2(-0.75, -0.60),
                        maximum: SIMD2(0.85, 0.90)
                    ),
                "\(item.name)"
            )
            #expect(
                input.stampFootprint.coverageSymmetry == .oriented,
                "\(item.name)"
            )
        case let .hardRound(radius):
            #expect(
                input.stampFootprint.brushToWorld
                    == Affine2D(
                        xAxis: SIMD2(radius, 0),
                        yAxis: SIMD2(0, radius),
                        translation: item.translation
                    ),
                "\(item.name)"
            )
            #expect(
                input.stampFootprint.localBounds
                    == AxisAlignedRect(
                        minimum: SIMD2(-1, -1),
                        maximum: SIMD2(1, 1)
                    ),
                "\(item.name)"
            )
            #expect(
                input.stampFootprint.coverageSymmetry
                    == .halfTurnInvariant,
                "\(item.name)"
            )
        }
    }
}

@Test
func rotationalGeneratorUsesBaseTranslatedAndHalfTurnedScreenProbes() {
    let input = try! #require(
        HarnessRunner.taskSevenInput(for: .rotationalGenerator)
    )

    #expect(
        HarnessRunner.rotationalGeneratorWorldProbes(
            input: input,
            tileSize: PixelSize(width: 256, height: 256)
        ) == [
            WorldPoint(x: 64, y: 80),
            WorldPoint(x: 320, y: 80),
            WorldPoint(x: 64, y: 336),
            WorldPoint(x: 192, y: 176),
        ]
    )
}

@Test
func coordinateContinuityUsesCircularCanonicalAndLinearBrushLocalDistances() {
    let expected: [UInt8] = [
        0, 255, 255, 255,
        0, 0, 0, 255,
    ]
    let wrapped: [UInt8] = [
        0, 0, 0, 255,
        0, 255, 255, 255,
    ]

    #expect(
        HarnessRunner.coordinateContinuityMismatchCount(
            productionBGRA: wrapped,
            oracleBGRA: expected,
            usesCircularRGDistance: true
        ) == 0
    )
    #expect(
        HarnessRunner.coordinateContinuityMismatchCount(
            productionBGRA: wrapped,
            oracleBGRA: expected,
            usesCircularRGDistance: false
        ) == 2
    )

    var corrupted = expected
    corrupted[1] = 252
    #expect(
        HarnessRunner.coordinateContinuityMismatchCount(
            productionBGRA: corrupted,
            oracleBGRA: expected,
            usesCircularRGDistance: true
        ) == 1
    )
}

@Test
func displayMetricsUseIndependentMirrorRotationalAndGridLineFormulas() {
    let tileSize = PixelSize(width: 8, height: 8)
    let screenSize = PixelSize(width: 16, height: 16)
    let canonical = (0..<(tileSize.width * tileSize.height)).flatMap {
        index -> [UInt8] in
        let x = UInt8(index % tileSize.width)
        let y = UInt8(index / tileSize.width)
        return [x &* 7, y &* 11, x &* 13, 255]
    }

    for tiling in [TilingKind.mirrorX, .mirrorY, .mirrorXY, .rotational] {
        let display = independentTaskSevenDisplay(
            canonicalBGRA: canonical,
            screenSize: screenSize,
            tileSize: tileSize,
            tiling: tiling
        )
        #expect(
            HarnessRunner.displayFoldMismatchCount(
                productionScreenBGRA: display,
                canonicalBGRA: canonical,
                screenSize: screenSize,
                tileSize: tileSize,
                tiling: tiling
            ) == 0
        )

        var corrupted = display
        corrupted[2] &+= 1
        #expect(
            HarnessRunner.displayFoldMismatchCount(
                productionScreenBGRA: corrupted,
                canonicalBGRA: canonical,
                screenSize: screenSize,
                tileSize: tileSize,
                tiling: tiling
            ) == 1
        )

        let wrongTiling: TilingKind = switch tiling {
        case .mirrorX: .mirrorY
        case .mirrorY: .mirrorX
        case .mirrorXY: .rotational
        case .rotational: .mirrorXY
        case .grid, .halfDrop, .brick:
            preconditionFailure("Task 7 display fixture only")
        case .squareRotation: .squareKaleidoscope
        case .squareKaleidoscope: .squareRotation
        }
        let wrongParityOrAxis = independentTaskSevenDisplay(
            canonicalBGRA: canonical,
            screenSize: screenSize,
            tileSize: tileSize,
            tiling: wrongTiling
        )
        #expect(
            HarnessRunner.displayFoldMismatchCount(
                productionScreenBGRA: wrongParityOrAxis,
                canonicalBGRA: canonical,
                screenSize: screenSize,
                tileSize: tileSize,
                tiling: tiling
            ) > 0
        )

        let gridLines = independentTaskSevenGridLines(
            baseBGRA: display,
            screenSize: screenSize,
            tileSize: tileSize
        )
        #expect(
            HarnessRunner.gridLineLatticeMismatchCount(
                productionGridBGRA: gridLines,
                productionBaseBGRA: display,
                screenSize: screenSize,
                tileSize: tileSize
            ) == 0
        )

        var corruptedGrid = gridLines
        corruptedGrid[(4 * screenSize.width + 4) * 4 + 3] &+= 2
        #expect(
            HarnessRunner.gridLineLatticeMismatchCount(
                productionGridBGRA: corruptedGrid,
                productionBaseBGRA: display,
                screenSize: screenSize,
                tileSize: tileSize
            ) == 1
        )

        let doubledGridLattice = independentTaskSevenGridLines(
            baseBGRA: display,
            screenSize: screenSize,
            tileSize: PixelSize(
                width: tileSize.width * 2,
                height: tileSize.height * 2
            )
        )
        #expect(
            HarnessRunner.gridLineLatticeMismatchCount(
                productionGridBGRA: doubledGridLattice,
                productionBaseBGRA: display,
                screenSize: screenSize,
                tileSize: tileSize
            ) > 0
        )
    }

    let rotational = independentTaskSevenDisplay(
        canonicalBGRA: canonical,
        screenSize: screenSize,
        tileSize: tileSize,
        tiling: .rotational
    )
    let checkerboard = independentTaskSevenDisplay(
        canonicalBGRA: canonical,
        screenSize: screenSize,
        tileSize: tileSize,
        tiling: .mirrorXY
    )
    let probes = [
        WorldPoint(x: 2, y: 2),
        WorldPoint(x: 10, y: 2),
        WorldPoint(x: 2, y: 10),
        WorldPoint(x: 6, y: 6),
    ]
    #expect(
        HarnessRunner.displayProbeMismatchCount(
            productionScreenBGRA: rotational,
            canonicalBGRA: canonical,
            screenSize: screenSize,
            tileSize: tileSize,
            tiling: .rotational,
            worldPoints: probes
        ) == 0
    )
    #expect(
        HarnessRunner.displayProbeMismatchCount(
            productionScreenBGRA: checkerboard,
            canonicalBGRA: canonical,
            screenSize: screenSize,
            tileSize: tileSize,
            tiling: .rotational,
            worldPoints: probes
        ) > 0
    )
}

@Test
func transformMetricUsesIndependentCellFormulaAndDetectsOneAxisSwap() {
    let brushToWorld = Affine2D(
        xAxis: SIMD2(40, 0),
        yAxis: SIMD2(0, 40),
        translation: SIMD2(256, 96)
    )
    let clip = ConvexClip(halfPlanes: [])
    let correct = CellFragment(
        cell: CellIndex(column: 1, row: 0),
        imageOrdinal: 0,
        canonicalFromBrush: Affine2D(
            xAxis: SIMD2(-40, 0),
            yAxis: SIMD2(0, 40),
            translation: SIMD2(256, 96)
        ),
        brushClip: clip
    )
    let axisSwapped = CellFragment(
        cell: correct.cell,
        imageOrdinal: correct.imageOrdinal,
        canonicalFromBrush: Affine2D(
            xAxis: SIMD2(40, 0),
            yAxis: SIMD2(0, -40),
            translation: SIMD2(256, 96)
        ),
        brushClip: clip
    )

    #expect(
        HarnessRunner.independentTransformMismatchCount(
            fragments: [correct],
            brushToWorld: brushToWorld,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .mirrorX
        ) == 0
    )
    #expect(
        HarnessRunner.independentTransformMismatchCount(
            fragments: [axisSwapped],
            brushToWorld: brushToWorld,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .mirrorX
        ) == 1
    )
}

@Test
func fixedPointMetricCountsDuplicateCoverageDomainsFromTransforms() {
    let clip = ConvexClip(halfPlanes: [])
    let identity = CellFragment(
        cell: CellIndex(column: 0, row: 0),
        imageOrdinal: 0,
        canonicalFromBrush: Affine2D(
            xAxis: SIMD2(10, 0),
            yAxis: SIMD2(0, 10),
            translation: SIMD2(128, 128)
        ),
        brushClip: clip
    )
    let rotated = CellFragment(
        cell: CellIndex(column: 0, row: 0),
        imageOrdinal: 1,
        canonicalFromBrush: Affine2D(
            xAxis: SIMD2(-10, 0),
            yAxis: SIMD2(0, -10),
            translation: SIMD2(128, 128)
        ),
        brushClip: clip
    )

    #expect(
        HarnessRunner.duplicateFixedPointWriteCount(
            fragments: [identity]
        ) == 0
    )
    #expect(
        HarnessRunner.duplicateFixedPointWriteCount(
            fragments: [identity, rotated]
        ) == 1
    )

    let ulpShifted = CellFragment(
        cell: rotated.cell,
        imageOrdinal: rotated.imageOrdinal,
        canonicalFromBrush: Affine2D(
            xAxis: rotated.canonicalFromBrush.xAxis,
            yAxis: rotated.canonicalFromBrush.yAxis,
            translation: SIMD2(
                Float(128).nextUp,
                Float(128).nextDown
            )
        ),
        brushClip: clip
    )
    #expect(
        HarnessRunner.duplicateFixedPointWriteCount(
            fragments: [identity, ulpShifted]
        ) == 1
    )
}

@Test
func squareFixedPointHarnessProjectionUsesCompleteRoundSymmetry() {
    let pixelSize = PixelSize(width: 256, height: 256)
    for preset in [
        SymmetryPresetID.squareRotation,
        .squareKaleidoscope,
    ] {
        let configuration = HarnessRenderConfiguration(
            pixelSize: pixelSize,
            periodicConfiguration: PeriodicSymmetryConfiguration(
                presetID: preset,
                repeatSize: PatternSize(width: 192, height: 192),
                orientationRadians: .pi / 12
            ),
            diagnosticMode: .hardRound
        )
        let basis = configuration.makeStrategy()
            .compiledSymmetry.domain.periodic!.translationBasis
        let center = WorldPoint(basis.origin + (basis.u + basis.v) * 0.5)

        let fragments = HarnessRunner.hardRoundFragments(
            at: center,
            radius: GridCanvasContract.brushRadius,
            configuration: configuration,
            coverageSymmetry: .rotationAndReflectionInvariant
        )

        #expect(fragments.count == 1)
    }
}

@Test
func taskEightNoncentralInputsUseApprovedParityDistinctVisibleCells() {
    let expected: [
        (TilingKind, PixelSize, WorldPoint, WorldPoint, CellIndex)
    ] = [
        (
            .grid,
            PixelSize(width: 256, height: 256),
            WorldPoint(x: 64, y: 64),
            WorldPoint(x: 320, y: 64),
            CellIndex(column: 1, row: 0)
        ),
        (
            .halfDrop,
            PixelSize(width: 288, height: 192),
            WorldPoint(x: 64, y: 64),
            WorldPoint(x: 352, y: 160),
            CellIndex(column: 1, row: 0)
        ),
        (
            .brick,
            PixelSize(width: 288, height: 192),
            WorldPoint(x: 64, y: 64),
            WorldPoint(x: 208, y: 256),
            CellIndex(column: 0, row: 1)
        ),
        (
            .mirrorX,
            PixelSize(width: 256, height: 256),
            WorldPoint(x: 64, y: 64),
            WorldPoint(x: 448, y: 64),
            CellIndex(column: 1, row: 0)
        ),
        (
            .mirrorY,
            PixelSize(width: 256, height: 256),
            WorldPoint(x: 64, y: 64),
            WorldPoint(x: 64, y: 448),
            CellIndex(column: 0, row: 1)
        ),
        (
            .mirrorXY,
            PixelSize(width: 256, height: 256),
            WorldPoint(x: 64, y: 64),
            WorldPoint(x: 448, y: 448),
            CellIndex(column: 1, row: 1)
        ),
        (
            .rotational,
            PixelSize(width: 256, height: 256),
            WorldPoint(x: 64, y: 80),
            WorldPoint(x: 320, y: 80),
            CellIndex(column: 1, row: 0)
        ),
    ]

    for (tiling, tileSize, central, visible, visibleCell) in expected {
        let input = HarnessRunner.taskEightNoncentralInput(for: tiling)

        #expect(input.tileSize == tileSize, "\(tiling)")
        #expect(input.central == central, "\(tiling)")
        #expect(input.visible == visible, "\(tiling)")
        #expect(input.visibleCell == visibleCell, "\(tiling)")
    }
}

@Test
func phaseTwoSquareNoncentralInputStaysGenericInLatticeSpace() throws {
    for tiling in [TilingKind.squareRotation, .squareKaleidoscope] {
        let configuration = HarnessRenderConfiguration(
            pixelSize: PixelSize(width: 256, height: 256),
            periodicConfiguration: PeriodicSymmetryConfiguration(
                presetID: tiling,
                repeatSize: PatternSize(width: 192, height: 192),
                orientationRadians: .pi / 12
            ),
            diagnosticMode: .hardRound
        )
        let strategy = configuration.makeStrategy()
        let periodic = try #require(
            strategy.compiledSymmetry.domain.periodic
        )
        let input = HarnessRunner.taskEightNoncentralInput(
            for: configuration
        )
        let centralLattice = periodic.worldToLattice.applying(
            to: input.central.simd
        )
        let visibleLattice = periodic.worldToLattice.applying(
            to: input.visible.simd
        )

        #expect(simd_distance(centralLattice, SIMD2(0.31, 0.17)) < 0.000_01)
        #expect(simd_distance(visibleLattice, SIMD2(1.31, 0.17)) < 0.000_01)
        #expect(input.visibleCell == CellIndex(column: 1, row: 0))
    }
}

@Test
func taskEightByteMetricsMeasureActualDifferencesAndParityTolerance() {
    let baseline: [UInt8] = [
        0, 0, 0, 255,
        10, 20, 30, 255,
    ]
    var changed = baseline
    changed[1] = 2
    changed[6] = 31

    #expect(
        HarnessRunner.differingByteCount(
            baseline,
            changed
        ) == 2
    )
    #expect(
        HarnessRunner.maximumByteDelta(
            baseline,
            changed
        ) == 2
    )
    #expect(
        HarnessRunner.previewCommitViolationCount(
            baseline,
            changed,
            tolerance: 1
        ) == 1
    )
}

@Test
func taskEightProgramsUseApprovedFixedInputs() {
    #expect(
        HarnessRunner.taskEightRectangularCenter
            == WorldPoint(x: 318, y: 190)
    )
    #expect(
        HarnessRunner.taskEightMetadataCenter
            == WorldPoint(x: 64, y: 64)
    )
    #expect(
        HarnessRunner.taskEightLiveCommitPoints == [
            WorldPoint(x: 278, y: 90),
            WorldPoint(x: 298, y: 110),
        ]
    )

    let points = HarnessRunner.taskEightLongStrokePoints
    #expect(points.count == 401)
    for pair in zip(points, points.dropFirst()) {
        #expect(pair.0.y == pair.1.y)
        #expect(abs(pair.1.x - pair.0.x) == 32)
    }
}

@Test
func taskEightScenePairsUseTheExactApprovedMatrixAndOneNegativeMetric()
    throws
{
    struct Expected {
        let name: String
        let program: TilingHarnessProgram
        let tileSize: PixelSize
        let tiling: TilingKind
        let negativeMetric: HarnessStructuralMetric
    }
    let expected = [
        Expected(
            name: "rectangular-tile",
            program: .rectangularTile,
            tileSize: PixelSize(width: 320, height: 192),
            tiling: .grid,
            negativeMetric: .oracleHoleCount
        ),
        Expected(
            name: "noncentral-visible-cell-grid",
            program: .noncentralVisibleCell,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .grid,
            negativeMetric: .visibleCellCanonicalByteDelta
        ),
        Expected(
            name: "noncentral-visible-cell-halfdrop",
            program: .noncentralVisibleCell,
            tileSize: PixelSize(width: 288, height: 192),
            tiling: .halfDrop,
            negativeMetric: .visibleCellCanonicalByteDelta
        ),
        Expected(
            name: "noncentral-visible-cell-brick",
            program: .noncentralVisibleCell,
            tileSize: PixelSize(width: 288, height: 192),
            tiling: .brick,
            negativeMetric: .visibleCellCanonicalByteDelta
        ),
        Expected(
            name: "noncentral-visible-cell-mirror-x",
            program: .noncentralVisibleCell,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .mirrorX,
            negativeMetric: .visibleCellCanonicalByteDelta
        ),
        Expected(
            name: "noncentral-visible-cell-mirror-y",
            program: .noncentralVisibleCell,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .mirrorY,
            negativeMetric: .visibleCellCanonicalByteDelta
        ),
        Expected(
            name: "noncentral-visible-cell-mirror-xy",
            program: .noncentralVisibleCell,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .mirrorXY,
            negativeMetric: .visibleCellCanonicalByteDelta
        ),
        Expected(
            name: "noncentral-visible-cell-rotational",
            program: .noncentralVisibleCell,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .rotational,
            negativeMetric: .visibleCellCanonicalByteDelta
        ),
        Expected(
            name: "metadata-tiling-switch",
            program: .metadataTilingSwitch,
            tileSize: PixelSize(width: 256, height: 256),
            tiling: .grid,
            negativeMetric: .canonicalByteDelta
        ),
        Expected(
            name: "projected-live-commit",
            program: .projectedLiveCommit,
            tileSize: PixelSize(width: 288, height: 192),
            tiling: .halfDrop,
            negativeMetric: .previewCommitViolationCount
        ),
        Expected(
            name: "projected-long-stroke",
            program: .projectedLongStroke,
            tileSize: PixelSize(width: 288, height: 192),
            tiling: .halfDrop,
            negativeMetric: .restampedInstanceCount
        ),
    ]
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")

    for item in expected {
        let positiveURL = scenesDirectory.appendingPathComponent(
            "\(item.name).json"
        )
        let negativeURL = scenesDirectory.appendingPathComponent(
            "\(item.name)-negative-control.json"
        )
        let positive = try HarnessScene.decode(
            Data(contentsOf: positiveURL)
        )
        let negative = try HarnessScene.decode(
            Data(contentsOf: negativeURL)
        )

        #expect(positive.name == item.name)
        #expect(negative.name == "\(item.name)-negative-control")
        #expect(positive.program == item.program)
        #expect(positive.tileWidth == item.tileSize.width)
        #expect(positive.tileHeight == item.tileSize.height)
        #expect(positive.tiling == item.tiling)
        #expect(positive.diagnosticMode == .hardRound)

        let positiveObject = try taskSevenSceneObject(at: positiveURL)
        let negativeObject = try taskSevenSceneObject(at: negativeURL)
        var normalizedPositive = positiveObject
        var normalizedNegative = negativeObject
        normalizedPositive["name"] = "<name>"
        normalizedNegative["name"] = "<name>"
        let positiveChecks = try #require(
            normalizedPositive["structuralChecks"] as? [[String: Any]]
        )
        var negativeChecks = try #require(
            normalizedNegative["structuralChecks"] as? [[String: Any]]
        )
        let intendedIndex = try #require(
            positiveChecks.firstIndex {
                $0["metric"] as? String == item.negativeMetric.rawValue
            }
        )
        #expect(positiveChecks[intendedIndex]["value"] as? Int == 0)
        #expect(negativeChecks[intendedIndex]["value"] as? Int == 1)
        negativeChecks[intendedIndex]["value"] = 0
        normalizedPositive["structuralChecks"] = positiveChecks
        normalizedNegative["structuralChecks"] = negativeChecks

        #expect(
            NSDictionary(dictionary: normalizedPositive)
                .isEqual(to: normalizedNegative)
        )
    }
}

@Test
func taskNineScenePairsMatchTheCompleteFixedMatrixExactly() throws {
    struct Expected {
        let name: String
        let program: TilingHarnessProgram
        let tileSize: PixelSize
        let tiling: TilingKind
        let diagnosticMode: HarnessDiagnosticMode
        let negativeMetric: HarnessStructuralMetric
        let isCoverageProgram: Bool
    }
    let expected: [Expected] = [
        .init(name: "generalized-grid", program: .generalizedGrid, tileSize: .init(width: 256, height: 256), tiling: .grid, diagnosticMode: .hardRound, negativeMetric: .oracleHoleCount, isCoverageProgram: true),
        .init(name: "halfdrop-interior", program: .halfDropInterior, tileSize: .init(width: 288, height: 192), tiling: .halfDrop, diagnosticMode: .hardRound, negativeMetric: .oraclePhantomCount, isCoverageProgram: true),
        .init(name: "halfdrop-edge", program: .halfDropEdge, tileSize: .init(width: 288, height: 192), tiling: .halfDrop, diagnosticMode: .hardRound, negativeMetric: .oracleHoleCount, isCoverageProgram: true),
        .init(name: "halfdrop-corner", program: .halfDropCorner, tileSize: .init(width: 288, height: 192), tiling: .halfDrop, diagnosticMode: .hardRound, negativeMetric: .oraclePhantomCount, isCoverageProgram: true),
        .init(name: "brick-transpose", program: .brickTranspose, tileSize: .init(width: 288, height: 192), tiling: .brick, diagnosticMode: .hardRound, negativeMetric: .transformMismatchCount, isCoverageProgram: true),
        .init(name: "mirror-x", program: .mirrorX, tileSize: .init(width: 256, height: 256), tiling: .mirrorX, diagnosticMode: .asymmetricCoverage, negativeMetric: .transformMismatchCount, isCoverageProgram: true),
        .init(name: "mirror-y", program: .mirrorY, tileSize: .init(width: 256, height: 256), tiling: .mirrorY, diagnosticMode: .asymmetricCoverage, negativeMetric: .transformMismatchCount, isCoverageProgram: true),
        .init(name: "mirror-xy", program: .mirrorXY, tileSize: .init(width: 256, height: 256), tiling: .mirrorXY, diagnosticMode: .asymmetricCoverage, negativeMetric: .transformMismatchCount, isCoverageProgram: true),
        .init(name: "rotational-generator", program: .rotationalGenerator, tileSize: .init(width: 256, height: 256), tiling: .rotational, diagnosticMode: .asymmetricCoverage, negativeMetric: .transformMismatchCount, isCoverageProgram: true),
        .init(name: "rotational-fixed-point", program: .rotationalFixedPoint, tileSize: .init(width: 256, height: 256), tiling: .rotational, diagnosticMode: .hardRound, negativeMetric: .duplicateFixedPointWriteCount, isCoverageProgram: true),
        .init(name: "rotational-orientation", program: .rotationalOrientation, tileSize: .init(width: 256, height: 256), tiling: .rotational, diagnosticMode: .asymmetricCoverage, negativeMetric: .transformMismatchCount, isCoverageProgram: true),
        .init(name: "large-footprint", program: .largeFootprint, tileSize: .init(width: 64, height: 96), tiling: .grid, diagnosticMode: .hardRound, negativeMetric: .oracleHoleCount, isCoverageProgram: true),
        .init(name: "asymmetric-footprint", program: .asymmetricFootprint, tileSize: .init(width: 256, height: 256), tiling: .rotational, diagnosticMode: .asymmetricCoverage, negativeMetric: .transformMismatchCount, isCoverageProgram: true),
        .init(name: "canonical-coordinate-continuity", program: .canonicalCoordinateContinuity, tileSize: .init(width: 288, height: 192), tiling: .halfDrop, diagnosticMode: .canonicalCoordinates, negativeMetric: .coordinateContinuityMismatchCount, isCoverageProgram: true),
        .init(name: "brush-local-coordinate-continuity", program: .brushLocalCoordinateContinuity, tileSize: .init(width: 256, height: 256), tiling: .mirrorXY, diagnosticMode: .brushLocalCoordinates, negativeMetric: .coordinateContinuityMismatchCount, isCoverageProgram: true),
        .init(name: "rectangular-tile", program: .rectangularTile, tileSize: .init(width: 320, height: 192), tiling: .grid, diagnosticMode: .hardRound, negativeMetric: .oracleHoleCount, isCoverageProgram: true),
        .init(name: "noncentral-visible-cell-grid", program: .noncentralVisibleCell, tileSize: .init(width: 256, height: 256), tiling: .grid, diagnosticMode: .hardRound, negativeMetric: .visibleCellCanonicalByteDelta, isCoverageProgram: false),
        .init(name: "noncentral-visible-cell-halfdrop", program: .noncentralVisibleCell, tileSize: .init(width: 288, height: 192), tiling: .halfDrop, diagnosticMode: .hardRound, negativeMetric: .visibleCellCanonicalByteDelta, isCoverageProgram: false),
        .init(name: "noncentral-visible-cell-brick", program: .noncentralVisibleCell, tileSize: .init(width: 288, height: 192), tiling: .brick, diagnosticMode: .hardRound, negativeMetric: .visibleCellCanonicalByteDelta, isCoverageProgram: false),
        .init(name: "noncentral-visible-cell-mirror-x", program: .noncentralVisibleCell, tileSize: .init(width: 256, height: 256), tiling: .mirrorX, diagnosticMode: .hardRound, negativeMetric: .visibleCellCanonicalByteDelta, isCoverageProgram: false),
        .init(name: "noncentral-visible-cell-mirror-y", program: .noncentralVisibleCell, tileSize: .init(width: 256, height: 256), tiling: .mirrorY, diagnosticMode: .hardRound, negativeMetric: .visibleCellCanonicalByteDelta, isCoverageProgram: false),
        .init(name: "noncentral-visible-cell-mirror-xy", program: .noncentralVisibleCell, tileSize: .init(width: 256, height: 256), tiling: .mirrorXY, diagnosticMode: .hardRound, negativeMetric: .visibleCellCanonicalByteDelta, isCoverageProgram: false),
        .init(name: "noncentral-visible-cell-rotational", program: .noncentralVisibleCell, tileSize: .init(width: 256, height: 256), tiling: .rotational, diagnosticMode: .hardRound, negativeMetric: .visibleCellCanonicalByteDelta, isCoverageProgram: false),
        .init(name: "metadata-tiling-switch", program: .metadataTilingSwitch, tileSize: .init(width: 256, height: 256), tiling: .grid, diagnosticMode: .hardRound, negativeMetric: .canonicalByteDelta, isCoverageProgram: false),
        .init(name: "projected-live-commit", program: .projectedLiveCommit, tileSize: .init(width: 288, height: 192), tiling: .halfDrop, diagnosticMode: .hardRound, negativeMetric: .previewCommitViolationCount, isCoverageProgram: false),
        .init(name: "projected-long-stroke", program: .projectedLongStroke, tileSize: .init(width: 288, height: 192), tiling: .halfDrop, diagnosticMode: .hardRound, negativeMetric: .restampedInstanceCount, isCoverageProgram: false),
    ]
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")

    #expect(expected.count == 26)
    for item in expected {
        let positiveURL = scenesDirectory.appendingPathComponent(
            "\(item.name).json"
        )
        let negativeURL = scenesDirectory.appendingPathComponent(
            "\(item.name)-negative-control.json"
        )
        let positive = try HarnessScene.decode(Data(contentsOf: positiveURL))
        let negative = try HarnessScene.decode(Data(contentsOf: negativeURL))

        #expect(positive.schemaVersion == 3, "\(item.name)")
        #expect(positive.width == 512, "\(item.name)")
        #expect(positive.height == 512, "\(item.name)")
        #expect(positive.program == item.program, "\(item.name)")
        #expect(positive.tileWidth == item.tileSize.width, "\(item.name)")
        #expect(positive.tileHeight == item.tileSize.height, "\(item.name)")
        #expect(positive.tiling == item.tiling, "\(item.name)")
        #expect(positive.diagnosticMode == item.diagnosticMode, "\(item.name)")
        #expect(
            positive.checks.isEmpty || item.name == "halfdrop-edge",
            "\(item.name)"
        )
        #expect(positive.checks == negative.checks, "\(item.name)")

        let expectedChecks: [HarnessStructuralCheck] = item.isCoverageProgram
            ? [
                .init(metric: item.negativeMetric, relation: .equal, value: 0),
                .init(metric: .oracleHoleCount, relation: .equal, value: 0),
                .init(metric: .oraclePhantomCount, relation: .equal, value: 0),
                .init(metric: .oracleMaximumDelta, relation: .lessThanOrEqual, value: 1),
            ]
            : [
                .init(metric: item.negativeMetric, relation: .equal, value: 0)
            ]
        #expect(positive.structuralChecks == expectedChecks, "\(item.name)")
        var expectedNegativeChecks = expectedChecks
        expectedNegativeChecks[0] = .init(
            metric: item.negativeMetric,
            relation: .equal,
            value: 1
        )
        #expect(
            negative.structuralChecks == expectedNegativeChecks,
            "\(item.name)"
        )
    }
}

@Test
func phaseTwoSquareScenePairsUseExplicitGeometryAndOneNegativeCause() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
    let expected: [(
        name: String,
        preset: SymmetryPresetID,
        repeatSide: Float,
        orientation: Float
    )] = [
        (
            "square-rotation-noncentral",
            .squareRotation,
            192,
            0.2617994
        ),
        (
            "square-kaleidoscope-noncentral",
            .squareKaleidoscope,
            160,
            -0.17453292
        ),
    ]

    for item in expected {
        let positive = try HarnessScene.decode(Data(contentsOf:
            scenesDirectory.appendingPathComponent("\(item.name).json")
        ))
        let negative = try HarnessScene.decode(Data(contentsOf:
            scenesDirectory.appendingPathComponent(
                "\(item.name)-negative-control.json"
            )
        ))

        #expect(positive.schemaVersion == 3)
        #expect(positive.program == .noncentralVisibleCell)
        #expect(positive.tiling == item.preset)
        #expect(positive.periodicConfiguration?.version == 1)
        #expect(positive.periodicConfiguration?.repeatWidth == item.repeatSide)
        #expect(positive.periodicConfiguration?.repeatHeight == item.repeatSide)
        #expect(
            positive.periodicConfiguration?.orientationRadians
                == item.orientation
        )
        #expect(positive.structuralChecks == [
            HarnessStructuralCheck(
                metric: .visibleCellCanonicalByteDelta,
                relation: .equal,
                value: 0
            ),
        ])
        #expect(negative.structuralChecks == [
            HarnessStructuralCheck(
                metric: .visibleCellCanonicalByteDelta,
                relation: .equal,
                value: 1
            ),
        ])

        var positiveObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(positive)
            ) as? [String: Any]
        )
        var negativeObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(negative)
            ) as? [String: Any]
        )
        positiveObject["name"] = "<name>"
        negativeObject["name"] = "<name>"
        negativeObject["structuralChecks"] =
            positiveObject["structuralChecks"]
        #expect(
            NSDictionary(dictionary: positiveObject)
                .isEqual(to: negativeObject)
        )
    }
}

@Test
func phaseTwoSquareFixedPointPairsPinOracleLiveCommitAndDeduplication()
    throws
{
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenesDirectory = repositoryRoot
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
    let cases: [(String, SymmetryPresetID)] = [
        ("square-rotation-fixed-point", .squareRotation),
        ("square-kaleidoscope-fixed-point", .squareKaleidoscope),
    ]
    let expectedChecks: [HarnessStructuralCheck] = [
        .init(
            metric: .duplicateFixedPointWriteCount,
            relation: .equal,
            value: 0
        ),
        .init(metric: .oracleHoleCount, relation: .equal, value: 0),
        .init(metric: .oraclePhantomCount, relation: .equal, value: 0),
        .init(
            metric: .oracleMaximumDelta,
            relation: .lessThanOrEqual,
            value: 1
        ),
        .init(
            metric: .previewCommitMaximumDelta,
            relation: .lessThanOrEqual,
            value: 1
        ),
    ]

    for (name, preset) in cases {
        let positive = try HarnessScene.decode(Data(contentsOf:
            scenesDirectory.appendingPathComponent("\(name).json")
        ))
        let negative = try HarnessScene.decode(Data(contentsOf:
            scenesDirectory.appendingPathComponent(
                "\(name)-negative-control.json"
            )
        ))

        #expect(positive.program == .squareFixedPoint)
        #expect(positive.tiling == preset)
        #expect(positive.structuralChecks == expectedChecks)
        var negativeChecks = expectedChecks
        negativeChecks[0] = .init(
            metric: .duplicateFixedPointWriteCount,
            relation: .equal,
            value: 1
        )
        #expect(negative.structuralChecks == negativeChecks)
    }
}

@Test
func fragmentAuditRejectsCapacityAndOrderChanges() throws {
    let first = CellFragment(
        cell: CellIndex(column: 0, row: 0),
        imageOrdinal: 0,
        canonicalFromBrush: .identity,
        brushClip: ConvexClip(halfPlanes: [])
    )
    let second = CellFragment(
        cell: CellIndex(column: 1, row: 0),
        imageOrdinal: 0,
        canonicalFromBrush: .identity,
        brushClip: ConvexClip(halfPlanes: [])
    )

    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "audit",
            message: "generated 2 fragments beyond the fixed 1 pending-instance capacity"
        )
    ) {
        try HarnessRunner.auditFragmentBatch(
            sceneName: "audit",
            fragments: [first, second],
            repeatedFragments: [first, second],
            pendingCapacity: 1
        )
    }
    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "audit",
            message: "fragment order changed across identical projection runs"
        )
    ) {
        try HarnessRunner.auditFragmentBatch(
            sceneName: "audit",
            fragments: [first, second],
            repeatedFragments: [second, first],
            pendingCapacity: 2
        )
    }
}

@Test
func fragmentAuditMeasuresCountsPlanesAndInstanceBytes() throws {
    let fragment = CellFragment(
        cell: CellIndex(column: 0, row: 0),
        imageOrdinal: 0,
        canonicalFromBrush: .identity,
        brushClip: ConvexClip(
            halfPlanes: [
                HalfPlane2D(normal: SIMD2(1, 0), offset: 1),
                HalfPlane2D(normal: SIMD2(0, 1), offset: 1),
            ]
        )
    )

    let audit = try HarnessRunner.auditFragmentBatch(
        sceneName: "audit",
        fragments: [fragment],
        repeatedFragments: [fragment],
        pendingCapacity: 1
    )

    #expect(audit.projectedFragmentCount == 1)
    #expect(audit.maximumClipPlaneCount == 2)
    #expect(
        audit.instanceBytes
            == MemoryLayout<PatternProjectedStampInstance>.stride
    )
}

@Test
func encodedIdentityRangeAuditAcceptsExactContiguousMultiRange() throws {
    let audit = try HarnessRunner.auditEncodedInstanceIdentityRanges(
        sceneName: "identity-audit",
        previousEncodedHighWater: 7,
        emittedHighWater: 10,
        encodedIdentityRanges: [7..<8, 8..<10]
    )

    #expect(audit.newlyEncodedInstanceCount == 3)
    #expect(audit.restampedInstanceCount == 0)
    #expect(audit.encodedHighWater == 10)
}

@Test
func encodedIdentityRangeAuditRejectsDuplicateOldAndEqualCountSubstitution() {
    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "identity-audit",
            message: "encoded projected identity range 6..<8 did not begin at expected high-water 7"
        )
    ) {
        try HarnessRunner.auditEncodedInstanceIdentityRanges(
            sceneName: "identity-audit",
            previousEncodedHighWater: 7,
            emittedHighWater: 10,
            encodedIdentityRanges: [6..<8, 8..<10]
        )
    }
    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "identity-audit",
            message: "encoded projected identity range 6..<7 did not begin at expected high-water 7"
        )
    ) {
        try HarnessRunner.auditEncodedInstanceIdentityRanges(
            sceneName: "identity-audit",
            previousEncodedHighWater: 7,
            emittedHighWater: 10,
            encodedIdentityRanges: [6..<7, 8..<10]
        )
    }
}

@Test
func encodedIdentityRangeAuditRejectsDroppedGapAndOutOfOrderNewIdentity() {
    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "identity-audit",
            message: "encoded projected identity range 9..<10 did not begin at expected high-water 8"
        )
    ) {
        try HarnessRunner.auditEncodedInstanceIdentityRanges(
            sceneName: "identity-audit",
            previousEncodedHighWater: 7,
            emittedHighWater: 10,
            encodedIdentityRanges: [7..<8, 9..<10]
        )
    }
    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "identity-audit",
            message: "encoded projected identity range 8..<10 did not begin at expected high-water 7"
        )
    ) {
        try HarnessRunner.auditEncodedInstanceIdentityRanges(
            sceneName: "identity-audit",
            previousEncodedHighWater: 7,
            emittedHighWater: 10,
            encodedIdentityRanges: [8..<10, 7..<8]
        )
    }
}

@Test
func encodedIdentityRangeAuditRejectsFinalMissingSuffixAndBackwardHighWater() {
    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "identity-audit",
            message: "encoded projected high-water 9 did not reach emitted high-water 10"
        )
    ) {
        try HarnessRunner.auditEncodedInstanceIdentityRanges(
            sceneName: "identity-audit",
            previousEncodedHighWater: 7,
            emittedHighWater: 10,
            encodedIdentityRanges: [7..<9]
        )
    }
    #expect(
        throws: HarnessRunError.counterInvariant(
            sceneName: "identity-audit",
            message: "emitted projected-instance identity moved backward"
        )
    ) {
        try HarnessRunner.auditEncodedInstanceIdentityRanges(
            sceneName: "identity-audit",
            previousEncodedHighWater: 10,
            emittedHighWater: 9,
            encodedIdentityRanges: []
        )
    }
}

@Test
func longStrokeFrameRunsHarnessAuditAfterProductionSubmit() {
    var events: [String] = []
    var injectedClock = 10.0

    let result = HarnessRunner
        .performLongStrokeProductionThenAudit(
            production: {
                injectedClock += 0.25
                events.append("production-submit")
                return (value: 42, measurement: injectedClock - 10)
            },
            audit: { result in
                injectedClock += 100
                events.append("harness-audit-\(result)")
            }
        )

    #expect(result.value == 42)
    #expect(result.measurement == 0.25)
    #expect(injectedClock == 110.25)
    #expect(events == ["production-submit", "harness-audit-42"])
}

private func makeSliceThreeGatePreflightRepository() throws -> URL {
    let repository = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: repository.appendingPathComponent("Sources"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: repository.appendingPathComponent(".vscode"),
        withIntermediateDirectories: true
    )
    try "fixture\n".write(
        to: repository.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    try runGateFixtureCommand(["init", "--quiet"], in: repository)
    try runGateFixtureCommand(["config", "user.email", "gate@example.invalid"], in: repository)
    try runGateFixtureCommand(["config", "user.name", "Slice 3 Gate Fixture"], in: repository)
    try runGateFixtureCommand(["add", "README.md"], in: repository)
    try runGateFixtureCommand(["commit", "--quiet", "-m", "fixture"], in: repository)
    return repository
}

private func runSliceThreeGatePreflight(
    in repository: URL
) throws -> (status: Int32, standardError: String) {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/verify-slice3.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        "source \"$1\"; cd \"$2\"; verify_source_provenance",
        "bash",
        script.path,
        repository.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    let standardError = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

private func runSliceThreeGateCompletionSimulation(
    ignoreAuditFails: Bool
) throws -> (
    status: Int32,
    standardOutput: String,
    standardError: String,
    trace: [String]
) {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/verify-slice3.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        trace="$2/trace.log"
        strict_evidence_log="$2/strict-evidence.log"
        ignore_mode="$3"
        validate_strict_evidence() {
          printf '%s\\n' 'strict-validation' >> "$trace"
          printf '%s\\n' \
            "SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment 'Apple Paravirtual device'." \
            > "$strict_evidence_log"
          return 2
        }
        evaluate_benchmarks() {
          printf '%s\\n' 'performance-budgets' >> "$trace"
          return 0
        }
        prove_generated_artifacts_ignored() {
          printf '%s\\n' 'generated-artifact-ignore' >> "$trace"
          if [[ "$ignore_mode" == 'fail' ]]; then
            gate_error 'simulated generated-artifact ignore failure'
            return 1
          fi
        }
        verify_source_provenance() {
          printf '%s\\n' 'source-provenance' >> "$trace"
        }
        if complete_gate_after_harness; then
          status=0
        else
          status=$?
        fi
        exit "$status"
        """,
        "bash",
        script.path,
        temporaryDirectory.path,
        ignoreAuditFails ? "fail" : "pass",
    ]
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let traceURL = temporaryDirectory.appendingPathComponent("trace.log")
    let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
    return (
        process.terminationStatus,
        String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ),
        String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ),
        trace.split(separator: "\n").map(String.init)
    )
}

private func runGateFixtureCommand(
    _ arguments: [String],
    in repository: URL
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = repository
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GateFixtureError.gitCommandFailed(arguments)
    }
}

private enum GateFixtureError: Error {
    case gitCommandFailed([String])
}

private func taskSevenSceneObject(
    at url: URL
) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
    )
}

private func independentTaskSevenDisplay(
    canonicalBGRA: [UInt8],
    screenSize: PixelSize,
    tileSize: PixelSize,
    tiling: TilingKind
) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(screenSize.width * screenSize.height * 4)
    let tileWidth = Float(tileSize.width)
    let tileHeight = Float(tileSize.height)
    for y in 0..<screenSize.height {
        for x in 0..<screenSize.width {
            let worldX = Float(x) + 0.5
                - Float(screenSize.width) * 0.5
                + tileWidth * 0.5
            let worldY = Float(y) + 0.5
                - Float(screenSize.height) * 0.5
                + tileHeight * 0.5
            let column = Int(floor(worldX / tileWidth))
            let row = Int(floor(worldY / tileHeight))
            let localX = worldX - floor(worldX / tileWidth) * tileWidth
            let localY = worldY - floor(worldY / tileHeight) * tileHeight
            let reflectsX = (tiling == .mirrorX || tiling == .mirrorXY)
                && (column & 1) != 0
            let reflectsY = (tiling == .mirrorY || tiling == .mirrorXY)
                && (row & 1) != 0
            let canonicalX = reflectsX
                ? tileWidth - localX
                : localX
            let canonicalY = reflectsY
                ? tileHeight - localY
                : localY
            let sampleX = Int(floor(canonicalX))
                .quotientAndRemainder(dividingBy: tileSize.width)
                .remainder
            let sampleY = Int(floor(canonicalY))
                .quotientAndRemainder(dividingBy: tileSize.height)
                .remainder
            let wrappedX = sampleX < 0 ? sampleX + tileSize.width : sampleX
            let wrappedY = sampleY < 0 ? sampleY + tileSize.height : sampleY
            let offset = (wrappedY * tileSize.width + wrappedX) * 4
            result.append(contentsOf: canonicalBGRA[offset..<(offset + 4)])
        }
    }
    return result
}

private func independentTaskSevenGridLines(
    baseBGRA: [UInt8],
    screenSize: PixelSize,
    tileSize: PixelSize
) -> [UInt8] {
    var result = baseBGRA
    let tileWidth = Float(tileSize.width)
    let tileHeight = Float(tileSize.height)
    for y in 0..<screenSize.height {
        for x in 0..<screenSize.width {
            let worldX = Float(x) + 0.5
                - Float(screenSize.width) * 0.5
                + tileWidth * 0.5
            let worldY = Float(y) + 0.5
                - Float(screenSize.height) * 0.5
                + tileHeight * 0.5
            let localX = worldX - floor(worldX / tileWidth) * tileWidth
            let localY = worldY - floor(worldY / tileHeight) * tileHeight
            let edgeDistance = min(
                min(localX, tileWidth - localX),
                min(localY, tileHeight - localY)
            )
            let t = min(1, max(0, edgeDistance - 1))
            let smooth = t * t * (3 - 2 * t)
            let alpha = 0.22 * (1 - smooth)
            let offset = (y * screenSize.width + x) * 4
            let gridBGRA: [Float] = [
                0.19 * alpha,
                0.20 * alpha,
                0.18 * alpha,
                alpha,
            ]
            for channel in 0..<4 {
                let base = Float(baseBGRA[offset + channel]) / 255
                result[offset + channel] = UInt8(
                    min(255, max(0, round(
                        (gridBGRA[channel] + base * (1 - alpha)) * 255
                    )))
                )
            }
        }
    }
    return result
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

private func schemaFourData(
    program: String = "coloredDraw"
) -> Data {
    Data(
        """
        {
          "schemaVersion": 4,
          "name": "schema-four",
          "width": 96,
          "height": 80,
          "tileWidth": 96,
          "tileHeight": 80,
          "tiling": 0,
          "diagnosticMode": "hardRound",
          "program": "\(program)",
          "checks": [],
          "structuralChecks": [
            {
              "metric": "undoCanonicalByteDelta",
              "relation": "equal",
              "value": 0
            }
          ]
        }
        """.utf8
    )
}

private func schemaFiveData() -> Data {
    Data(
        """
        {
          "schemaVersion": 5,
          "name": "slice-four-ink",
          "width": 96,
          "height": 80,
          "tileWidth": 96,
          "tileHeight": 80,
          "tiling": 0,
          "diagnosticMode": "hardRound",
          "program": "projectedLiveCommit",
          "recipeID": "anchor.ink",
          "seed": 18446744073709551615,
          "attributedSamples": [
            {
              "x": 12,
              "y": 18,
              "pressure": 0.25,
              "timestamp": 1,
              "altitude": 0.8,
              "azimuth": 0.2,
              "phase": "began",
              "source": "tablet",
              "kind": "actual",
              "capabilities": 7
            },
            {
              "x": 24,
              "y": 30,
              "pressure": 0.75,
              "timestamp": 1.01,
              "phase": "ended",
              "source": "tablet",
              "kind": "coalesced",
              "capabilities": 1
            }
          ],
          "expectedMaterial": "ink",
          "replayMode": "replayTail",
          "checks": [],
          "structuralChecks": [
            {
              "metric": "peakRetainedSampleCount",
              "relation": "lessThanOrEqual",
              "value": 256
            }
          ]
        }
        """.utf8
    )
}
