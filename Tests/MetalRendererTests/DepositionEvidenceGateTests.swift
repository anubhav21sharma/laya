@testable import BrushDepositionEvidenceValidation
import CryptoKit
import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Stage 4 deposition evidence gate")
struct DepositionEvidenceGateTests {
    @Test
    func completeVirtualEvidenceIsPerformancePendingOnly() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }

        #expect(
            try fixture.validate()
                == .performancePending(gpuName: fixture.gpuName)
        )
    }

    @Test
    func exactPositiveAndNegativeScenePairingIsRequired() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(
            at: fixture.root
                .appendingPathComponent("negative-control")
                .appendingPathComponent(
                    StageFourEvidenceValidator.positiveSceneNames[0]
                )
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test(arguments: [
        EvidenceIdentityDefect.definitionID,
        EvidenceIdentityDefect.semanticHash,
        .pipelineKey,
        .abi,
        .resourceBytes,
        .textureLevels,
    ])
    func schemaDefinitionPipelineABIAndResourcesFailClosed(
        _ defect: EvidenceIdentityDefect
    ) throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = StageFourEvidenceValidator.positiveSceneNames[0]
        try fixture.mutateEvidence(scene: scene) { object in
            switch defect {
            case .definitionID:
                object["definitionID"] = "other.native-brush"
            case .semanticHash:
                object["semanticHash"] = String(repeating: "d", count: 64)
            case .pipelineKey:
                object["pipelineKey"] =
                    "deposition:flow:dryBreakup:s0:g1:h0:d0:abi1:format80:samples1"
            case .abi:
                object["abiVersion"] = 2
            case .resourceBytes:
                object["resourceBytes"] = 4096
            case .textureLevels:
                object["textureLevels"] = ["other.shape": 1]
            }
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func canonicalPNGPixelDigestAndDimensionsAreRecomputed() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = StageFourEvidenceValidator.positiveSceneNames[0]
        try fixture.writePNG(
            scene: scene,
            name: "canonical.png",
            pixels: fixture.changedPixels
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func cpuGPUMaximumDeltaIsRecomputedFromPNGs() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutateEvidence(scene: "deposition-ink") {
            $0["maximumCPUGPUChannelDelta"] = 1
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func previewCommitDeltaIsRecomputedAndBounded() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = "deposition-preview-commit"
        try fixture.writePNG(
            scene: scene,
            name: "live.png",
            pixels: fixture.changedPixels
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func everyMetamorphicInvariantMustBePresentAndTrue() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutateEvidence(scene: "deposition-kinematics") { object in
            var invariants = object["invariantResults"] as! [String: Bool]
            invariants["zoomIndependent"] = false
            object["invariantResults"] = invariants
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func hotPathCompilerAndPipelineCountersMustRemainZero() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutateEvidence(scene: "deposition-ink") { object in
            var invariants = object["invariantResults"] as! [String: Bool]
            invariants["strokeCompilerCountersUnchanged"] = false
            object["invariantResults"] = invariants
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func eachNegativeControlMustExitExactlyOne() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        let scene = StageFourEvidenceValidator.positiveSceneNames[0]
        try Data("0\n".utf8).write(
            to: fixture.root
                .appendingPathComponent("negative-control")
                .appendingPathComponent(scene)
                .appendingPathComponent("exit-status.txt")
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func sourceTreeCommitAndTerminalTreeRemainBound() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try Data("changed\n".utf8).write(
            to: fixture.root.appendingPathComponent(
                "source-tree-terminal.txt"
            )
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func performancePendingCannotHideCorrectnessFailure() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutatePerformance {
            $0["correctnessPassed"] = false
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func paravirtualProfileCannotClaimRealtimePerformance() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.mutatePerformance { object in
            object["physicalProfiles"] = Dictionary(
                uniqueKeysWithValues:
                StageFourEvidenceValidator.requiredPhysicalProfiles.map {
                    ($0, "passed")
                }
            )
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func physicalLookingSelfAttestationCannotProducePass() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.makePhysicalLookingSelfAttestation()
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func metricDerivedStructuredPhysicalEvidenceCanProducePass() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.rewriteManifest()

        #expect(try fixture.validate() == .passed)
    }

    @Test
    func sharedM3MacFixtureCannotSatisfyDeviceSpecificPhysicalProfiles()
        throws
    {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeLegacySharedM3PhysicalProfiles()
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func oneSamplePhysicalTracesCannotSatisfyAcceptanceProfiles() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeUndersampledPhysicalProfiles()
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func physicalTraceDigestIsRecomputedInsideOuterManifest() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        let profile =
            StageFourEvidenceValidator.requiredPhysicalProfiles[0]
        try Data("tampered physical trace\n".utf8).write(
            to: fixture.root.appendingPathComponent("physical-profiles")
                .appendingPathComponent(profile)
                .appendingPathComponent("raw")
                .appendingPathComponent("trace.json")
        )
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func physicalMeasurementsMustMatchRawTraceSamplesWhenDigestsAreRewritten()
        throws
    {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        let profile =
            StageFourEvidenceValidator.requiredPhysicalProfiles[0]
        let directory = fixture.root
            .appendingPathComponent("physical-profiles")
            .appendingPathComponent(profile)
        let traceURL = directory.appendingPathComponent("raw/trace.json")
        var raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: traceURL)
        ) as! [String: Any]
        var samples = raw["samples"] as! [String: Any]
        let metricID = try #require(samples.keys.sorted().first)
        samples[metricID] = [0.25]
        raw["samples"] = samples
        let rawData = try StageFourArtifactFixture.json(raw)
        try rawData.write(to: traceURL)

        let evidenceURL = directory.appendingPathComponent("evidence.json")
        var evidence = try JSONSerialization.jsonObject(
            with: Data(contentsOf: evidenceURL)
        ) as! [String: Any]
        var traces = evidence["traces"] as! [[String: Any]]
        traces[0]["sha256"] = StageFourArtifactFixture.sha256(rawData)
        evidence["traces"] = traces
        try StageFourArtifactFixture.json(evidence).write(to: evidenceURL)
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func promotionClaimMustMatchObservedDisplayFrameIntervals() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile(
            "referenceMSeriesProMotion120Hz"
        ) { _, trace in
            let sampleCount =
                (trace["sampleTimestampsNanoseconds"] as! [NSNumber]).count
            let timestamps = (0 ..< sampleCount).map {
                1_000_000_000 + $0 * 16_666_667
            }
            trace["sampleTimestampsNanoseconds"] = timestamps
            trace["events"] = StageFourArtifactFixture.physicalEvents(
                kinds: ["inputSample", "displayFrame"],
                timestamps: timestamps
            )
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func missedFrameSamplesMustMatchIntermediateDisplayFrameGaps() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile(
            "referenceMSeriesProMotion120Hz"
        ) { _, trace in
            var timestamps =
                (trace["sampleTimestampsNanoseconds"] as! [NSNumber])
                    .map(\.intValue)
            let index = 100
            let interval = timestamps[index] - timestamps[index - 1]
            let shift = interval * 3 / 4
            timestamps[index] += shift
            trace["sampleTimestampsNanoseconds"] = timestamps
            var events = trace["events"] as! [[String: Any]]
            for eventIndex in events.indices
            where (events[eventIndex]["sampleIndex"] as! NSNumber)
                .intValue == index
            {
                events[eventIndex]["timestampNanoseconds"] =
                    (events[eventIndex]["timestampNanoseconds"] as! NSNumber)
                        .intValue + shift
            }
            trace["events"] = events
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func passingLatencySamplesMustMatchFailingObservedEventDeltas() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile("inputToPhoton") { _, trace in
            var events = trace["events"] as! [[String: Any]]
            for index in events.indices
            where events[index]["kind"] as? String == "inputEvent"
                && (events[index]["sampleIndex"] as! NSNumber).intValue > 0
            {
                let sampleIndex =
                    (events[index]["sampleIndex"] as! NSNumber).intValue
                let photon = events.first {
                    $0["kind"] as? String == "photonObserved"
                        && ($0["sampleIndex"] as! NSNumber).intValue
                            == sampleIndex
                }!
                events[index]["timestampNanoseconds"] =
                    (photon["timestampNanoseconds"] as! NSNumber).intValue
                        - 20_000_000
            }
            events.sort {
                ($0["timestampNanoseconds"] as! NSNumber).intValue
                    < ($1["timestampNanoseconds"] as! NSNumber).intValue
            }
            trace["events"] = events
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func eventGroupsMustBeBoundToTheirDeclaredSampleTimestamps() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile("pencil") { _, trace in
            var events = trace["events"] as! [[String: Any]]
            for index in events.indices
            where (events[index]["sampleIndex"] as! NSNumber).intValue == 1
            {
                events[index]["timestampNanoseconds"] =
                    (events[index]["timestampNanoseconds"] as! NSNumber)
                        .intValue + 1_000
            }
            events.sort {
                ($0["timestampNanoseconds"] as! NSNumber).intValue
                    < ($1["timestampNanoseconds"] as! NSNumber).intValue
            }
            trace["events"] = events
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func processorClassMustBeDerivedFromValidatedHardwareModel() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile(
            "referenceMSeriesProMotion120Hz"
        ) { evidence, trace in
            var evidenceDevice = evidence["device"] as! [String: Any]
            evidenceDevice["hardwareModel"] = "iPad13,2"
            evidence["device"] = evidenceDevice
            var traceDevice = trace["device"] as! [String: Any]
            traceDevice["hardwareModel"] = "iPad13,2"
            trace["device"] = traceDevice
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test(arguments: ["iPad13,18", "iPad13,19"])
    func tenthGenerationIPadCannotSatisfyMSeriesPromotionProfile(
        _ hardwareModel: String
    ) throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile(
            "referenceMSeriesProMotion120Hz"
        ) { evidence, trace in
            var evidenceDevice = evidence["device"] as! [String: Any]
            evidenceDevice["hardwareModel"] = hardwareModel
            evidence["device"] = evidenceDevice
            var traceDevice = trace["device"] as! [String: Any]
            traceDevice["hardwareModel"] = hardwareModel
            trace["device"] = traceDevice
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test(arguments: ["iPad13,18", "iPad13,19"])
    func tenthGenerationIPadCanSatisfyA14Profile(
        _ hardwareModel: String
    ) throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile("a14Floor60Hz") {
            evidence, trace in
            var evidenceDevice = evidence["device"] as! [String: Any]
            evidenceDevice["hardwareModel"] = hardwareModel
            evidence["device"] = evidenceDevice
            var traceDevice = trace["device"] as! [String: Any]
            traceDevice["hardwareModel"] = hardwareModel
            trace["device"] = traceDevice
        }
        try fixture.rewriteManifest()

        #expect(try fixture.validate() == .passed)
    }

    @Test
    func intelMacHardwareModelCannotClaimMSeriesProcessorClass() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile("wacom") { evidence, trace in
            var evidenceDevice = evidence["device"] as! [String: Any]
            evidenceDevice["hardwareModel"] = "MacBookPro16,1"
            evidence["device"] = evidenceDevice
            var traceDevice = trace["device"] as! [String: Any]
            traceDevice["hardwareModel"] = "MacBookPro16,1"
            trace["device"] = traceDevice
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func unknownMacHardwareModelCannotClaimMSeriesProcessorClass() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.writeValidPhysicalProfiles()
        try fixture.mutatePhysicalProfile("wacom") { evidence, trace in
            var evidenceDevice = evidence["device"] as! [String: Any]
            evidenceDevice["hardwareModel"] = "Mac99,1"
            evidence["device"] = evidenceDevice
            var traceDevice = trace["device"] as! [String: Any]
            traceDevice["hardwareModel"] = "Mac99,1"
            trace["device"] = traceDevice
        }
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }

    @Test
    func incompatibleHeadlessCatalogCannotSelfAttestItsDigest() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try fixture.rewriteProvenanceCatalogDigest()
        try fixture.rewriteManifest()

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validateProductionContract()
        }
    }

    @Test
    func alteredArtifactDigestFailsClosed() throws {
        let fixture = try StageFourArtifactFixture()
        defer { fixture.remove() }
        try Data("altered manifest\n".utf8).write(
            to: fixture.root.appendingPathComponent("artifact-sha256.txt")
        )

        #expect(throws: StageFourEvidenceValidationError.self) {
            try fixture.validate()
        }
    }
}

enum EvidenceIdentityDefect: CaseIterable, CustomTestStringConvertible {
    case definitionID
    case semanticHash
    case pipelineKey
    case abi
    case resourceBytes
    case textureLevels

    var testDescription: String {
        String(describing: self)
    }
}

private struct FixturePhysicalMetric {
    let unit: String
    let aggregation: String
    let relation: String
    let threshold: Double
    let passingSample: Double

    init(
        _ unit: String,
        _ aggregation: String,
        _ relation: String,
        _ threshold: Double,
        _ passingSample: Double
    ) {
        self.unit = unit
        self.aggregation = aggregation
        self.relation = relation
        self.threshold = threshold
        self.passingSample = passingSample
    }
}

private struct FixturePhysicalProfile {
    let platform: String
    let hardwareModel: String
    let processorClass: String
    let gpuName: String
    let refreshHertz: Double
    let displayProvenance: String
    let inputKind: String
    let inputVendor: String
    let inputModel: String
    let inputTransport: String
    let inputSamplingHertz: Double
    let inputTelemetryProvenance: String
    let sampleCount: Int
    let durationNanoseconds: Int
    let eventKinds: [String]
}

private struct StageFourArtifactFixture {
    let root: URL
    let commit = String(repeating: "a", count: 40)
    let gpuName = "Apple Paravirtual device"
    let sourceTree = Data(
        "100644 blob 0123456789012345678901234567890123456789\tPackage.swift\n"
            .utf8
    )
    let pixels: [UInt8] = {
        var value = [UInt8](
            repeating: 0,
            count: 128 * 128 * 4
        )
        for alpha in stride(from: 3, to: value.count, by: 4) {
            value[alpha] = 255
        }
        return value
    }()

    var changedPixels: [UInt8] {
        var value = pixels
        value[0] = 4
        return value
    }

    var sourceTreeSHA256: String {
        Self.sha256(sourceTree)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "brush-stage4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        for name in [
            "positive", "negative-control", "brush-lab-cards", "logs",
            "physical-profiles",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: false
            )
        }
        try writeSourceTree()
        try writeSceneMatrix()
        try writePositiveEvidence()
        try writeNegativeControls()
        try writeBrushLabCatalog()
        try writePerformance()
        try writeProvenance()
        try writePerformanceBenchmarks()
        try rewriteManifest()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func validate() throws -> StageFourEvidenceValidationStatus {
        let catalog = root.appendingPathComponent("brush-lab-cards")
            .appendingPathComponent("catalog.json")
        return try StageFourEvidenceValidator.validate(
            artifactRoot: root,
            expectedCommit: commit,
            expectedSourceTreeSHA256: sourceTreeSHA256,
            requiredBrushLabCatalogSHA256:
                Self.sha256(Data(contentsOf: catalog))
        )
    }

    func validateProductionContract() throws
        -> StageFourEvidenceValidationStatus
    {
        try StageFourEvidenceValidator.validate(
            artifactRoot: root,
            expectedCommit: commit,
            expectedSourceTreeSHA256: sourceTreeSHA256
        )
    }

    func mutateEvidence(
        scene: String,
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = root.appendingPathComponent("positive")
            .appendingPathComponent(scene)
            .appendingPathComponent("deposition-evidence.json")
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as! [String: Any]
        mutation(&object)
        try Self.json(object).write(to: url)
    }

    func mutatePerformance(
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = root.appendingPathComponent("performance-status.txt")
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as! [String: Any]
        mutation(&object)
        try Self.json(object).write(to: url)
    }

    func makePhysicalLookingSelfAttestation() throws {
        try makePhysicalHardware()
        try mutatePerformance { object in
            object["physicalProfiles"] = Dictionary(
                uniqueKeysWithValues:
                StageFourEvidenceValidator.requiredPhysicalProfiles.map {
                    ($0, "passed")
                }
            )
        }
    }

    func writeValidPhysicalProfiles() throws {
        try writeProfileSpecificPhysicalProfiles()
    }

    func writeUndersampledPhysicalProfiles() throws {
        try writeProfileSpecificPhysicalProfiles(sampleCountOverride: 1)
    }

    func writeLegacySharedM3PhysicalProfiles() throws {
        try makePhysicalHardware()
        let profiles = root.appendingPathComponent("physical-profiles")
        for profileID in
            StageFourEvidenceValidator.requiredPhysicalProfiles
        {
            let directory = profiles.appendingPathComponent(profileID)
            let raw = directory.appendingPathComponent("raw")
            try FileManager.default.createDirectory(
                at: raw,
                withIntermediateDirectories: true
            )
            let requirements = try #require(
                Self.physicalMetrics[profileID]
            )
            let source: [String: Any] = [
                "commit": commit,
                "sourceTreeSHA256": sourceTreeSHA256,
            ]
            let device: [String: Any] = [
                "gpuName": "Apple M3 Max",
                "gpuRegistryID": "fixture-registry-\(profileID)",
                "hardwareModel": "Mac15,9",
                "operatingSystem": "Fixture OS",
            ]
            let toolchain: [String: Any] = [
                "swiftVersion": "Fixture Swift",
                "xcodeVersion": "Fixture Xcode",
                "xcodegenVersion": "Fixture XcodeGen",
            ]
            let rawSamples = Dictionary(
                uniqueKeysWithValues: requirements.map {
                    ($0.key, [$0.value.passingSample])
                }
            )
            let trace = try Self.json([
                "schemaVersion": 1,
                "profileID": profileID,
                "source": source,
                "device": device,
                "toolchain": toolchain,
                "samples": rawSamples,
            ])
            try trace.write(
                to: raw.appendingPathComponent("trace.json")
            )
            let measurements = Dictionary(
                uniqueKeysWithValues: requirements.map {
                    metricID,
                    metric in
                    (
                        metricID,
                        [
                            "unit": metric.unit,
                            "aggregation": metric.aggregation,
                            "samples": [metric.passingSample],
                            "threshold": [
                                "relation": metric.relation,
                                "value": metric.threshold,
                            ],
                        ] as [String: Any]
                    )
                }
            )
            try Self.json([
                "schemaVersion": 1,
                "profileID": profileID,
                "source": source,
                "device": device,
                "toolchain": toolchain,
                "measurements": measurements,
                "traces": [
                    [
                        "id": "\(profileID).trace",
                        "path": "raw/trace.json",
                        "sampleCount": 1,
                        "sha256": Self.sha256(trace),
                    ],
                ],
            ]).write(
                to: directory.appendingPathComponent("evidence.json")
            )
        }
    }

    private func writeProfileSpecificPhysicalProfiles(
        sampleCountOverride: Int? = nil
    ) throws {
        try makePhysicalHardware()
        let profiles = root.appendingPathComponent("physical-profiles")
        for profileID in
            StageFourEvidenceValidator.requiredPhysicalProfiles
        {
            let profile = try #require(
                Self.physicalProfiles[profileID]
            )
            let directory = profiles.appendingPathComponent(profileID)
            let raw = directory.appendingPathComponent("raw")
            try FileManager.default.createDirectory(
                at: raw,
                withIntermediateDirectories: true
            )
            let metrics = try #require(
                Self.physicalMetrics[profileID]
            )
            let source: [String: Any] = [
                "commit": commit,
                "sourceTreeSHA256": sourceTreeSHA256,
            ]
            let device: [String: Any] = [
                "gpuName": profile.gpuName,
                "gpuRegistryID": "fixture-registry-\(profileID)",
                "hardwareModel": profile.hardwareModel,
                "operatingSystem": "\(profile.platform) Fixture",
                "platform": profile.platform,
                "processorClass": profile.processorClass,
                "display": [
                    "nominalRefreshHertz": profile.refreshHertz,
                    "measuredRefreshHertz": profile.refreshHertz,
                    "measurementProvenance":
                        profile.displayProvenance,
                ],
                "inputDevice": [
                    "kind": profile.inputKind,
                    "vendor": profile.inputVendor,
                    "model": profile.inputModel,
                    "transport": profile.inputTransport,
                    "samplingHertz": profile.inputSamplingHertz,
                    "telemetryProvenance":
                        profile.inputTelemetryProvenance,
                ],
            ]
            let toolchain: [String: Any] = [
                "swiftVersion": "Fixture Swift",
                "xcodeVersion": "Fixture Xcode",
                "xcodegenVersion": "Fixture XcodeGen",
            ]
            let sampleCount =
                sampleCountOverride ?? profile.sampleCount
            let timestamps = Self.physicalTimestamps(
                sampleCount: sampleCount,
                durationNanoseconds:
                    sampleCountOverride == nil
                        ? profile.durationNanoseconds : 0
            )
            var rawSamples = Dictionary(
                uniqueKeysWithValues: metrics.map {
                    (
                        $0.key,
                        [Double](
                            repeating: $0.value.passingSample,
                            count: sampleCount
                        )
                    )
                }
            )
            let eventSpanNanoseconds: Int
            switch profileID {
            case "memoryWarning":
                eventSpanNanoseconds = 100_000_000
            case "inputToPhoton":
                eventSpanNanoseconds = 10_000_000
            case "suspendResume":
                eventSpanNanoseconds = 200_000_000
            default:
                eventSpanNanoseconds = profile.eventKinds.count - 1
            }
            if profileID == "inputToPhoton" {
                rawSamples["inputToPhotonP95Milliseconds"] =
                    [Double](repeating: 10, count: sampleCount)
            } else if profileID == "memoryWarning" {
                rawSamples["memoryWarningRecoveryMilliseconds"] =
                    [Double](repeating: 100, count: sampleCount)
            } else if profileID == "suspendResume" {
                rawSamples["suspendResumeRecoveryMilliseconds"] =
                    [Double](repeating: 100, count: sampleCount)
            } else if profileID == "sustainedThermal" {
                var durations = [Double](
                    repeating: 0,
                    count: sampleCount
                )
                for index in 1 ..< sampleCount {
                    durations[index] = Double(
                        timestamps[index] - timestamps[index - 1]
                    ) / 1_000_000_000
                }
                rawSamples["thermalDurationSeconds"] = durations
            }
            let events = Self.physicalEvents(
                kinds: profile.eventKinds,
                timestamps: timestamps,
                eventSpanNanoseconds: eventSpanNanoseconds
            )
            let trace = try Self.json([
                "schemaVersion": 2,
                "profileID": profileID,
                "source": source,
                "device": device,
                "toolchain": toolchain,
                "sampleTimestampsNanoseconds": timestamps,
                "events": events,
                "samples": rawSamples,
            ])
            try trace.write(
                to: raw.appendingPathComponent("trace.json")
            )
            let measurements = Dictionary(
                uniqueKeysWithValues: metrics.map {
                    metricID,
                    metric in
                    (
                        metricID,
                        [
                            "unit": metric.unit,
                            "aggregation": metric.aggregation,
                            "samples": rawSamples[metricID]!,
                            "threshold": [
                                "relation": metric.relation,
                                "value": metric.threshold,
                            ],
                        ] as [String: Any]
                    )
                }
            )
            try Self.json([
                "schemaVersion": 2,
                "profileID": profileID,
                "source": source,
                "device": device,
                "toolchain": toolchain,
                "measurements": measurements,
                "traces": [
                    [
                        "id": "\(profileID).trace",
                        "path": "raw/trace.json",
                        "sampleCount": sampleCount,
                        "sha256": Self.sha256(trace),
                    ],
                ],
            ]).write(
                to: directory.appendingPathComponent("evidence.json")
            )
        }
    }

    private static func physicalTimestamps(
        sampleCount: Int,
        durationNanoseconds: Int
    ) -> [Int] {
        let start = 1_000_000_000
        guard sampleCount > 1 else { return [start] }
        return (0 ..< sampleCount).map {
            start + durationNanoseconds * $0 / (sampleCount - 1)
        }
    }

    fileprivate static func physicalEvents(
        kinds: [String],
        timestamps: [Int],
        eventSpanNanoseconds: Int? = nil
    ) -> [[String: Any]] {
        let span = eventSpanNanoseconds ?? kinds.count - 1
        return timestamps.enumerated().flatMap { sampleIndex, timestamp in
            let eventStart = timestamp - span
            return kinds.enumerated().map { offset, kind in
                [
                    "kind": kind,
                    "sampleIndex": sampleIndex,
                    "timestampNanoseconds": eventStart
                        + (kinds.count == 1
                            ? 0
                            : span * offset / (kinds.count - 1)),
                ] as [String: Any]
            }
        }
    }

    func mutatePhysicalProfile(
        _ profileID: String,
        _ mutation: (
            inout [String: Any],
            inout [String: Any]
        ) throws -> Void
    ) throws {
        let directory = root.appendingPathComponent("physical-profiles")
            .appendingPathComponent(profileID)
        let evidenceURL = directory.appendingPathComponent("evidence.json")
        let traceURL = directory.appendingPathComponent("raw/trace.json")
        var evidence = try JSONSerialization.jsonObject(
            with: Data(contentsOf: evidenceURL)
        ) as! [String: Any]
        var trace = try JSONSerialization.jsonObject(
            with: Data(contentsOf: traceURL)
        ) as! [String: Any]
        try mutation(&evidence, &trace)
        let traceData = try Self.json(trace)
        try traceData.write(to: traceURL)
        var traces = evidence["traces"] as! [[String: Any]]
        traces[0]["sha256"] = Self.sha256(traceData)
        evidence["traces"] = traces
        try Self.json(evidence).write(to: evidenceURL)
    }

    private func makePhysicalHardware() throws {
        let physicalGPU = "Apple M3 Max"
        try mutatePerformance { object in
            object["gpuName"] = physicalGPU
            object["gpuClassification"] = "physical"
            object["gpu500DabMilliseconds"] = 2.5
        }
        try mutateJSON(
            at: root.appendingPathComponent("provenance.json")
        ) { object in
            object["gpuName"] = physicalGPU
            object["gpuClassification"] = "physical"
            object["hardwareModel"] = "Mac15,9"
        }
        for scene in StageFourEvidenceValidator.positiveSceneNames {
            try mutateJSON(
                at: root.appendingPathComponent("positive")
                    .appendingPathComponent(scene)
                    .appendingPathComponent("benchmark.json")
            ) { object in
                var hardware = object["hardware"] as! [String: Any]
                hardware["gpuName"] = physicalGPU
                object["hardware"] = hardware
            }
        }
        try mutateJSON(
            at: root.appendingPathComponent("logs")
                .appendingPathComponent(
                    "five-hundred-dabs.benchmark.json"
                )
        ) { object in
            var hardware = object["hardware"] as! [String: Any]
            hardware["gpuName"] = physicalGPU
            object["hardware"] = hardware
            object["dabGPUMilliseconds"] = [2.5]
        }
    }

    func rewriteProvenanceCatalogDigest() throws {
        let catalog = root.appendingPathComponent("brush-lab-cards")
            .appendingPathComponent("catalog.json")
        try mutateJSON(
            at: root.appendingPathComponent("provenance.json")
        ) { object in
            object["brushLabCatalogSHA256"] =
                Self.sha256(try Data(contentsOf: catalog))
        }
    }

    private func mutateJSON(
        at url: URL,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as! [String: Any]
        try mutation(&object)
        try Self.json(object).write(to: url)
    }

    func writePNG(
        scene: String,
        name: String,
        pixels: [UInt8]
    ) throws {
        try PNGWriter.writeBGRA(
            pixels,
            pixelSize: PixelSize(width: 128, height: 128),
            to: root.appendingPathComponent("positive")
                .appendingPathComponent(scene)
                .appendingPathComponent(name)
        )
    }

    func rewriteManifest() throws {
        let manager = FileManager.default
        let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )!
        let files = enumerator.compactMap { $0 as? URL }
            .filter {
                $0.lastPathComponent != "artifact-sha256.txt"
                    && (try? $0.resourceValues(
                        forKeys: [.isRegularFileKey]
                    ).isRegularFile) == true
            }
            .sorted { $0.path < $1.path }
        let lines = try files.map { url in
            let relative = String(
                url.path.dropFirst(root.path.count + 1)
            )
            return try "\(Self.sha256(Data(contentsOf: url)))  ./\(relative)"
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(
            to: root.appendingPathComponent("artifact-sha256.txt")
        )
    }

    private func writeSourceTree() throws {
        try sourceTree.write(
            to: root.appendingPathComponent("source-tree.txt")
        )
        try sourceTree.write(
            to: root.appendingPathComponent("source-tree-terminal.txt")
        )
    }

    private func writeSceneMatrix() throws {
        try Self.json([
            "schemaVersion": 1,
            "positive": StageFourEvidenceValidator.positiveSceneNames,
            "negativeControls":
                StageFourEvidenceValidator.negativeSceneNames,
        ]).write(to: root.appendingPathComponent("scene-matrix.json"))
    }

    private func writePositiveEvidence() throws {
        let positive = root.appendingPathComponent("positive")
        for scene in StageFourEvidenceValidator.positiveSceneNames {
            let truth = Self.truth(scene)
            let directory = positive.appendingPathComponent(scene)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            for name in ["live.png", "committed.png", "canonical.png"] {
                try writePNG(scene: scene, name: name, pixels: pixels)
            }
            let hasCPUReference = scene == "deposition-ink"
            if hasCPUReference {
                try writePNG(
                    scene: scene,
                    name: "cpu-reference.png",
                    pixels: changedPixels
                )
            }
            let invariants = Dictionary(
                uniqueKeysWithValues:
                StageFourEvidenceValidator.requiredMetamorphicInvariants
                    .map { ($0, true) }
                    + [
                        ("strokeCompilerCountersUnchanged", true),
                        ("strokePipelinePreparationUnchanged", true),
                    ]
            )
            let evidence: [String: Any] = [
                "schemaVersion": 1,
                "scene": scene,
                "definitionID": truth.definitionID,
                "semanticHash": truth.semanticHash,
                "pipelineKey": truth.pipelineKey,
                "abiVersion": 1,
                "resourceBytes": truth.resourceBytes,
                "textureLevels": truth.textureLevels,
                "logicalDabCount": 4,
                "projectedInstanceCount": 4,
                "canonicalSHA256": Self.sha256(Data(pixels)),
                "previewCommitMaximumChannelDelta": 0,
                "telemetry": [
                    "authoritativeBacklog": 0,
                    "predictedBacklog": 0,
                    "backlogHighWater": 4,
                    "encodedInstanceCount": 4,
                    "bufferHighWater": 1,
                    "missedFrameCount": 0,
                ],
                "invariantResults": invariants,
            ]
            var complete = evidence
            if hasCPUReference {
                complete["cpuReferenceSHA256"] =
                    Self.sha256(Data(changedPixels))
                complete["maximumCPUGPUChannelDelta"] = 4
            }
            try Self.json(complete).write(
                to: directory.appendingPathComponent(
                    "deposition-evidence.json"
                )
            )
            try writeBenchmark(scene: scene, truth: truth, to: directory)
        }
    }

    private func writeBenchmark(
        scene: String,
        truth: FixtureSceneTruth,
        to directory: URL
    ) throws {
        let benchmark: [String: Any] = [
            "schemaVersion": 3,
            "timestampUTC": "1970-01-01T00:00:00Z",
            "sceneName": scene,
            "hardware": [
                "gpuName": gpuName,
                "logicalProcessorCount": 8,
                "physicalMemoryBytes": 8_589_934_592,
            ],
            "operatingSystem": "Fixture OS",
            "build": [
                "configuration": "Debug",
                "gitCommit": commit,
            ],
            "frameCount": 1,
            "cpuEncodeMilliseconds": [0.5],
            "gpuMilliseconds": [7.0],
            "peakResidentBytes": truth.resourceBytes,
            "newInstanceCounts": [4],
            "totalProjectedFragmentCount": 4,
            "totalInstanceBytes": 1024,
            "previewCommitViolationCount": 0,
            "recipeID": truth.definitionID,
            "seed": 1,
            "assetResidentBytes": truth.resourceBytes,
            "logicalDabDigest": String(repeating: "c", count: 64),
            "canonicalBGRA8Digest": Self.sha256(Data(pixels)),
            "logicalDabCount": 4,
            "program": "nativeDeposition",
        ]
        try Self.json(benchmark).write(
            to: directory.appendingPathComponent("benchmark.json")
        )
    }

    private func writeNegativeControls() throws {
        let negative = root.appendingPathComponent("negative-control")
        for scene in StageFourEvidenceValidator.positiveSceneNames {
            let directory = negative.appendingPathComponent(scene)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data().write(
                to: directory.appendingPathComponent("stdout.log")
            )
            try Data("HARNESS FAIL fixture\n".utf8).write(
                to: directory.appendingPathComponent("stderr.log")
            )
            try Data("1\n".utf8).write(
                to: directory.appendingPathComponent("exit-status.txt")
            )
        }
    }

    private func writeBrushLabCatalog() throws {
        let brushIDs = (0 ..< 6).map { "fixture.brush.\($0)" }
        let cards: [[String: Any]] = brushIDs.flatMap { brushID in
            (0 ..< 52).map { index in
                [
                    "cardID": "\(brushID).card.\(String(format: "%02d", index))",
                    "schemaVersion": 1,
                    "brushID": brushID,
                ]
            }
        }.sorted {
            ($0["cardID"] as! String) < ($1["cardID"] as! String)
        }
        let assessments = cards.map {
            [
                "cardID": $0["cardID"]!,
                "responsiveness": NSNull(),
                "edgeQuality": NSNull(),
                "textureCohesion": NSNull(),
                "buildup": NSNull(),
                "symmetryBehavior": NSNull(),
                "eraserMatch": NSNull(),
                "notes": NSNull(),
            ] as [String: Any]
        }
        try Self.json([
            "schemaVersion": 1,
            "cards": cards,
            "assessments": assessments,
        ]).write(
            to: root.appendingPathComponent("brush-lab-cards")
                .appendingPathComponent("catalog.json")
        )
    }

    private func writePerformance() throws {
        try Self.json([
            "schemaVersion": 2,
            "correctnessPassed": true,
            "gpuName": gpuName,
            "gpuClassification": "paravirtual",
            "cpuPreparationP95Milliseconds": 0.5,
            "cpuPreparationBudgetMilliseconds": 2.0,
            "gpu500DabMilliseconds": 7.0,
            "gpu500DabBudgetMilliseconds": 3.0,
            "completedStrokeLengthIndependent": true,
            "hotPathCompilerResourceCountersZero": true,
        ]).write(
            to: root.appendingPathComponent("performance-status.txt")
        )
    }

    private func writeProvenance() throws {
        let catalog = root.appendingPathComponent("brush-lab-cards")
            .appendingPathComponent("catalog.json")
        try Self.json([
            "schemaVersion": 1,
            "commit": commit,
            "sourceTreeSHA256": sourceTreeSHA256,
            "configuration": "Debug",
            "swiftVersion": "Fixture Swift",
            "xcodeVersion": "Fixture Xcode",
            "xcodegenVersion": "Fixture XcodeGen",
            "operatingSystem": "Fixture OS",
            "kernel": "Fixture Kernel",
            "hardwareMachine": "arm64",
            "hardwareModel": "VirtualMac2,1",
            "gpuName": gpuName,
            "gpuClassification": "paravirtual",
            "artifactRoot": root.standardizedFileURL.path,
            "brushLabCatalogSHA256":
                Self.sha256(Data(contentsOf: catalog)),
        ]).write(to: root.appendingPathComponent("provenance.json"))
    }

    private func writePerformanceBenchmarks() throws {
        let logs = root.appendingPathComponent("logs")
        try Self.json([
            "schemaVersion": 2,
            "sceneName": "five-hundred-dabs",
            "build": [
                "configuration": "Debug",
                "gitCommit": commit,
            ],
            "hardware": [
                "gpuName": gpuName,
                "logicalProcessorCount": 8,
                "physicalMemoryBytes": 8_589_934_592,
            ],
            "newInstanceCounts": [500],
            "dabGPUMilliseconds": [7.0],
        ]).write(
            to: logs.appendingPathComponent(
                "five-hundred-dabs.benchmark.json"
            )
        )
        try Self.json([
            "schemaVersion": 3,
            "sceneName": "projected-long-stroke",
            "build": [
                "configuration": "Debug",
                "gitCommit": commit,
            ],
            "newInstanceCounts": [Int](repeating: 1, count: 401),
            "totalStrokeInstanceCounts": Array(1 ... 401),
        ]).write(
            to: logs.appendingPathComponent(
                "projected-long-stroke.benchmark.json"
            )
        )
    }

    fileprivate static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static let physicalMetrics:
        [String: [String: FixturePhysicalMetric]] = [
            "a14Floor60Hz": [
                "cpuPreparationP95Milliseconds":
                    .init("milliseconds", "p95", "lessThan", 2, 0.5),
                "gpu500DabMilliseconds":
                    .init("milliseconds", "maximum", "lessThan", 3, 2.5),
                "missedFrameFraction":
                    .init("fraction", "maximum", "lessThan", 0.01, 0),
            ],
            "inputToPhoton": [
                "inputToPhotonP95Milliseconds":
                    .init(
                        "milliseconds", "p95", "lessThan", 16.667, 10
                    ),
            ],
            "memoryWarning": [
                "memoryWarningRecoveryMilliseconds":
                    .init(
                        "milliseconds", "maximum", "lessThan", 1_000, 100
                    ),
                "recoveryFailureCount":
                    .init("count", "sum", "equal", 0, 0),
            ],
            "pencil": [
                "inputContinuityFailureCount":
                    .init("count", "sum", "equal", 0, 0),
                "predictionTransitionFailureCount":
                    .init("count", "sum", "equal", 0, 0),
            ],
            "referenceMSeriesProMotion120Hz": [
                "cpuPreparationP95Milliseconds":
                    .init("milliseconds", "p95", "lessThan", 2, 0.5),
                "gpu500DabMilliseconds":
                    .init("milliseconds", "maximum", "lessThan", 3, 2.5),
                "missedFrameFraction":
                    .init("fraction", "maximum", "lessThan", 0.01, 0),
            ],
            "suspendResume": [
                "recoveryFailureCount":
                    .init("count", "sum", "equal", 0, 0),
                "suspendResumeRecoveryMilliseconds":
                    .init(
                        "milliseconds", "maximum", "lessThan", 1_000, 100
                    ),
            ],
            "sustainedThermal": [
                "cpuPreparationP95Milliseconds":
                    .init("milliseconds", "p95", "lessThan", 2, 0.5),
                "gpu500DabMilliseconds":
                    .init("milliseconds", "maximum", "lessThan", 3, 2.5),
                "missedFrameFraction":
                    .init("fraction", "maximum", "lessThan", 0.01, 0),
                "thermalDurationSeconds":
                    .init(
                        "seconds", "sum", "greaterThanOrEqual", 600, 600
                    ),
            ],
            "wacom": [
                "inputContinuityFailureCount":
                    .init("count", "sum", "equal", 0, 0),
                "pressureMonotonicityFailureCount":
                    .init("count", "sum", "equal", 0, 0),
            ],
        ]
    private static let physicalProfiles:
        [String: FixturePhysicalProfile] = [
            "a14Floor60Hz": .init(
                platform: "iPadOS",
                hardwareModel: "iPad13,2",
                processorClass: "A14Class",
                gpuName: "Apple A14 GPU",
                refreshHertz: 60,
                displayProvenance:
                    "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace",
                inputKind: "touch",
                inputVendor: "Apple",
                inputModel: "Integrated Multi-Touch",
                inputTransport: "integrated",
                inputSamplingHertz: 120,
                inputTelemetryProvenance: "UITouch.timestamp",
                sampleCount: 300,
                durationNanoseconds: 5_000_000_000,
                eventKinds: ["inputSample", "displayFrame"]
            ),
            "inputToPhoton": .init(
                platform: "iPadOS",
                hardwareModel: "iPad14,6",
                processorClass: "MSeries",
                gpuName: "Apple M2 GPU",
                refreshHertz: 120,
                displayProvenance:
                    "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace",
                inputKind: "applePencil",
                inputVendor: "Apple",
                inputModel: "Apple Pencil 2",
                inputTransport: "integrated",
                inputSamplingHertz: 240,
                inputTelemetryProvenance:
                    "UIEvent.coalescedTouches+predictedTouches",
                sampleCount: 120,
                durationNanoseconds: 5_000_000_000,
                eventKinds: ["inputEvent", "photonObserved"]
            ),
            "memoryWarning": .init(
                platform: "iPadOS",
                hardwareModel: "iPad13,2",
                processorClass: "A14Class",
                gpuName: "Apple A14 GPU",
                refreshHertz: 60,
                displayProvenance:
                    "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace",
                inputKind: "touch",
                inputVendor: "Apple",
                inputModel: "Integrated Multi-Touch",
                inputTransport: "integrated",
                inputSamplingHertz: 120,
                inputTelemetryProvenance: "UITouch.timestamp",
                sampleCount: 5,
                durationNanoseconds: 5_000_000_000,
                eventKinds: ["memoryWarning", "rendererRecovered"]
            ),
            "pencil": .init(
                platform: "iPadOS",
                hardwareModel: "iPad14,6",
                processorClass: "MSeries",
                gpuName: "Apple M2 GPU",
                refreshHertz: 120,
                displayProvenance:
                    "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace",
                inputKind: "applePencil",
                inputVendor: "Apple",
                inputModel: "Apple Pencil Pro",
                inputTransport: "integrated",
                inputSamplingHertz: 240,
                inputTelemetryProvenance:
                    "UIEvent.coalescedTouches+predictedTouches",
                sampleCount: 240,
                durationNanoseconds: 1_000_000_000,
                eventKinds: ["inputSample", "renderedSample"]
            ),
            "referenceMSeriesProMotion120Hz": .init(
                platform: "iPadOS",
                hardwareModel: "iPad14,6",
                processorClass: "MSeries",
                gpuName: "Apple M2 GPU",
                refreshHertz: 120,
                displayProvenance:
                    "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace",
                inputKind: "touch",
                inputVendor: "Apple",
                inputModel: "Integrated Multi-Touch",
                inputTransport: "integrated",
                inputSamplingHertz: 120,
                inputTelemetryProvenance: "UITouch.timestamp",
                sampleCount: 600,
                durationNanoseconds: 5_000_000_000,
                eventKinds: ["inputSample", "displayFrame"]
            ),
            "suspendResume": .init(
                platform: "iPadOS",
                hardwareModel: "iPad14,6",
                processorClass: "MSeries",
                gpuName: "Apple M2 GPU",
                refreshHertz: 120,
                displayProvenance:
                    "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace",
                inputKind: "touch",
                inputVendor: "Apple",
                inputModel: "Integrated Multi-Touch",
                inputTransport: "integrated",
                inputSamplingHertz: 120,
                inputTelemetryProvenance: "UITouch.timestamp",
                sampleCount: 5,
                durationNanoseconds: 5_000_000_000,
                eventKinds: [
                    "applicationSuspended", "applicationResumed",
                    "rendererRecovered",
                ]
            ),
            "sustainedThermal": .init(
                platform: "iPadOS",
                hardwareModel: "iPad14,6",
                processorClass: "MSeries",
                gpuName: "Apple M2 GPU",
                refreshHertz: 120,
                displayProvenance:
                    "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace",
                inputKind: "touch",
                inputVendor: "Apple",
                inputModel: "Integrated Multi-Touch",
                inputTransport: "integrated",
                inputSamplingHertz: 120,
                inputTelemetryProvenance: "UITouch.timestamp",
                sampleCount: 600,
                durationNanoseconds: 600_000_000_000,
                eventKinds: ["thermalStateSample", "displayFrame"]
            ),
            "wacom": .init(
                platform: "macOS",
                hardwareModel: "Mac15,9",
                processorClass: "MSeries",
                gpuName: "Apple M3 Max",
                refreshHertz: 60,
                displayProvenance:
                    "CGDisplayMode.refreshRate+frameTimestampTrace",
                inputKind: "wacomStylus",
                inputVendor: "Wacom",
                inputModel: "Wacom Intuos Pro",
                inputTransport: "USB",
                inputSamplingHertz: 200,
                inputTelemetryProvenance: "NSEvent.tabletPoint",
                sampleCount: 120,
                durationNanoseconds: 1_000_000_000,
                eventKinds: ["inputSample", "renderedSample"]
            ),
        ]

    private static func truth(_ scene: String) -> FixtureSceneTruth {
        let identities: [String: (String, String)] = [
            "deposition-airbrush": (
                "builtin.native-airbrush",
                "3639712d81bf00edeeb356dd83a85ef1042668e1e6e6cfec2399b9dd7af5c5f5"
            ),
            "deposition-cache-pinning": (
                "deposition-cache-pinning.brush",
                "c7d1978947bf5d2b1381f4fe7076ef34d57301d336d2f63d686d6d73fa22b4fa"
            ),
            "deposition-custom-asymmetric": (
                "deposition-custom-asymmetric.brush",
                "ed124245524b1c35fc2095e6ab7798a7024e661cf36d8c967ffdad93270a637c"
            ),
            "deposition-dry": (
                "builtin.native-dry-media",
                "53c0ad644685aee750fc80c1b7b2fdc1153c22ca0bd32840a30707fccfe0068c"
            ),
            "deposition-erase": (
                "builtin.native-eraser",
                "d66277d4325c5f6666b44aeb7c9be832d055e42b296a3f1acc5ce67aa571a485"
            ),
            "deposition-failure-matrix": (
                "deposition-failure-matrix.brush",
                "ba6bdb112332538b8d6b3c1d2525e54228142083161f51a4958d754ea7a7e84c"
            ),
            "deposition-glaze": (
                "builtin.native-glaze",
                "7c88c98d6dea03dc523aa9da1d6b1c4f96208792eed86dc12715c0106eea1fcd"
            ),
            "deposition-ink": (
                "builtin.native-ink",
                "308b4e92cf13f559b43f1b8f429d568b6e521198a891324e1da7a512b3ee2753"
            ),
            "deposition-kinematics": (
                "deposition-kinematics.brush",
                "adb32fbc7e6214ab38d373b25a41c4fde80a7a2371a0d0535d97ecaf7576d21d"
            ),
            "deposition-layer-matrix": (
                "evidence.layer-multiply-2-true",
                "6cd54e9f53dbb905c61b7d1cacc39d0194e2f42281ade84559e5e0eb29cac4d4"
            ),
            "deposition-marker": (
                "builtin.native-marker",
                "4d9a55a7584f382a2fa90c5d5177d78f38b0387085295e7c90f5622fae3117ff"
            ),
            "deposition-periodic-seams": (
                "deposition-periodic-seams.brush",
                "c0629f7fc1024e1a8a30a7599133d21be354af44f8a262ef0027a4e064afb698"
            ),
            "deposition-prediction": (
                "deposition-prediction.brush",
                "810fff75718833a4b2e12d04e64a125ebf863e5b3783b907e11da85edbad7a64"
            ),
            "deposition-preview-commit": (
                "deposition-preview-commit.brush",
                "f4feee7141a83949994dab8cd07482cdc8cf0f12d4c10badfe0e725aca342a97"
            ),
            "deposition-radial-reflection": (
                "deposition-radial-reflection.brush",
                "9709db5f7001eeab912ffc6a3ea302861a72dc76ec6e4283f3960ab0784614b7"
            ),
            "deposition-stamp-size-mips": (
                "evidence.native-mips",
                "987462e244018869a7b40db35fe3037007fb20a9dfeb02376eb3c450baa33a42"
            ),
        ]
        let identity = identities[scene]!
        let defaultPipeline =
            "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1"
        let pipeline: String = switch scene {
        case "deposition-custom-asymmetric",
             "deposition-periodic-seams",
             "deposition-radial-reflection":
            "deposition:flow:none:s0:g1:h0:d0:abi1:format80:samples1"
        case "deposition-dry":
            "deposition:flow:dryBreakup:s0:g1:h0:d0:abi1:format80:samples1"
        case "deposition-erase":
            "deposition:destinationOut:none:s0:g0:h0:d0:abi1:format80:samples1"
        case "deposition-glaze":
            "deposition:uniformGlaze:none:s0:g0:h0:d0:abi1:format80:samples1"
        case "deposition-layer-matrix":
            "deposition:flow:none:s1:g1:h1:d0:abi1:format80:samples1"
        case "deposition-marker":
            "deposition:uniformGlaze:markerOverlap:s0:g0:h0:d0:abi1:format80:samples1"
        default:
            defaultPipeline
        }
        let textures: [String: Int] = switch scene {
        case "deposition-airbrush", "deposition-glaze":
            ["builtin.shape.soft-round": 7]
        case "deposition-custom-asymmetric",
             "deposition-periodic-seams",
             "deposition-radial-reflection":
            [
                "custom.asymmetric.grain": 7,
                "custom.asymmetric.shape": 7,
            ]
        case "deposition-dry":
            [
                "builtin.grain.paper": 7,
                "builtin.shape.hard-round": 7,
            ]
        case "deposition-layer-matrix":
            [
                "matrix.primary.grain": 7,
                "matrix.primary.shape": 7,
                "matrix.secondary.grain": 7,
                "matrix.secondary.shape": 7,
            ]
        case "deposition-marker":
            ["builtin.shape.chisel": 7]
        case "deposition-stamp-size-mips":
            ["evidence.mip-probe.shape": 7]
        default:
            ["builtin.shape.hard-round": 7]
        }
        let resourceBytes = textures.count * 5461
        return FixtureSceneTruth(
            definitionID: identity.0,
            semanticHash: identity.1,
            pipelineKey: pipeline,
            resourceBytes: resourceBytes,
            textureLevels: textures
        )
    }
}

private struct FixtureSceneTruth {
    let definitionID: String
    let semanticHash: String
    let pipelineKey: String
    let resourceBytes: Int
    let textureLevels: [String: Int]
}
