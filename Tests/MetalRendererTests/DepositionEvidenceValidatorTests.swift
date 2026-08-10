import Foundation
@testable import MetalRenderer
import Testing

@Suite("Native deposition evidence validator")
struct DepositionEvidenceValidatorTests {
    @Test
    func evidenceSchemaRoundTripsWithStableSortedJSON() throws {
        let evidence = DepositionSceneEvidence(
            schemaVersion: DepositionSceneEvidence.currentSchemaVersion,
            scene: "deposition-ink",
            definitionID: "anchor.ink",
            semanticHash: String(repeating: "a", count: 64),
            pipelineKey:
                "deposition:sourceOver:analyticAA:s0g0h0d0:abi1:bgra8Unorm:1",
            abiVersion: DepositionABI.version,
            resourceBytes: 256,
            textureLevels: [
                "builtin.shape.hard-round": 1,
            ],
            logicalDabCount: 3,
            projectedInstanceCount: 3,
            canonicalSHA256: String(repeating: "b", count: 64),
            cpuReferenceSHA256: String(repeating: "c", count: 64),
            maximumCPUGPUChannelDelta: 1,
            previewCommitMaximumChannelDelta: 0,
            telemetry: DepositionTelemetryEvidence(
                authoritativeBacklog: 0,
                predictedBacklog: 0,
                backlogHighWater: 3,
                encodedInstanceCount: 3,
                bufferHighWater: 1,
                missedFrameCount: 0
            ),
            invariantResults: [
                "zoomIndependent": true,
                "batchPartitionsEqual": true,
            ]
        )

        let data = try evidence.encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        let batch = try #require(text.range(of: "\"batchPartitionsEqual\""))
        let zoom = try #require(text.range(of: "\"zoomIndependent\""))

        #expect(batch.lowerBound < zoom.lowerBound)
        #expect(try DepositionSceneEvidence.decode(data) == evidence)
        try DepositionEvidenceValidator.validate(evidence)
    }

    @Test
    func validatorRejectsMalformedEvidenceDigest() throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: validEvidenceData()
            ) as? [String: Any]
        )
        object["canonicalSHA256"] = "not-a-sha"
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DepositionEvidenceValidationError.self) {
            _ = try DepositionSceneEvidence.decode(data)
        }
    }

    @Test(arguments: [
        SceneSetDefect.missing,
        .duplicate,
        .unsorted,
    ])
    func validatorRejectsEverySceneSetDefect(_ defect: SceneSetDefect)
        throws
    {
        var scenes = try DepositionEvidenceValidator.loadScenes(
            from: repositorySceneDirectory()
        )
        switch defect {
        case .missing:
            scenes.removeLast()
        case .duplicate:
            scenes[scenes.count - 1] = scenes[0]
        case .unsorted:
            scenes.swapAt(0, 1)
        }

        #expect(throws: DepositionEvidenceValidationError.self) {
            try DepositionEvidenceValidator.validateSceneSet(scenes)
        }
    }

    @Test
    func eachNegativePairChangesExactlyOneAuthoritativeExpectation()
        throws
    {
        let scenes = try DepositionEvidenceValidator.loadScenes(
            from: repositorySceneDirectory()
        )
        try DepositionEvidenceValidator.validateSceneSet(scenes)

        for positiveName in DepositionEvidenceValidator.positiveSceneNames {
            let positive = try #require(
                scenes.first { $0.name == positiveName }
            )
            let negative = try #require(
                scenes.first {
                    $0.name == "\(positiveName)-negative-control"
                }
            )
            let differingKeys = Set(
                positive.depositionInvariantExpectations.keys.filter {
                    positive.depositionInvariantExpectations[$0]
                        != negative.depositionInvariantExpectations[$0]
                }
            )

            #expect(differingKeys.count == 1, "\(positiveName)")
            #expect(
                positive.depositionInvariantExpectations.keys
                    == negative.depositionInvariantExpectations.keys,
                "\(positiveName)"
            )
        }
    }
}

enum SceneSetDefect: CaseIterable, CustomTestStringConvertible {
    case missing
    case duplicate
    case unsorted

    var testDescription: String { String(describing: self) }
}

private func repositorySceneDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
}

private func validEvidenceData() throws -> Data {
    try JSONEncoder().encode(
        DepositionSceneEvidence(
            schemaVersion: DepositionSceneEvidence.currentSchemaVersion,
            scene: "deposition-ink",
            definitionID: "anchor.ink",
            semanticHash: String(repeating: "a", count: 64),
            pipelineKey: "pipeline",
            abiVersion: DepositionABI.version,
            resourceBytes: 0,
            textureLevels: [:],
            logicalDabCount: 1,
            projectedInstanceCount: 1,
            canonicalSHA256: String(repeating: "b", count: 64),
            cpuReferenceSHA256: nil,
            maximumCPUGPUChannelDelta: nil,
            previewCommitMaximumChannelDelta: 0,
            telemetry: .zero,
            invariantResults: ["familyAndAccumulationCorrect": true]
        )
    )
}
