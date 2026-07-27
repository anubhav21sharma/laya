import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("BrushDeviceProfile")
struct BrushDeviceProfileTests {
    private let mebibyte = 1_024 * 1_024

    @Test
    func rejectsInvalidCapabilitiesAndBudgets() {
        #expect(throws: BrushDeviceProfileError.invalidRecommendedWorkingSetBytes) {
            _ = try BrushDeviceProfile(
                registryID: 1,
                recommendedWorkingSetBytes: 0,
                maximumWorkingTextureDimension: 4_096,
                targetFramesPerSecond: 120
            )
        }
        #expect(throws: BrushDeviceProfileError.invalidMaximumWorkingTextureDimension(0)) {
            _ = try BrushDeviceProfile(
                registryID: 1,
                recommendedWorkingSetBytes: 512 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 0,
                targetFramesPerSecond: 120
            )
        }
        #expect(throws: BrushDeviceProfileError.invalidMaximumWorkingTextureDimension(4_097)) {
            _ = try BrushDeviceProfile(
                registryID: 1,
                recommendedWorkingSetBytes: 512 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 4_097,
                targetFramesPerSecond: 120
            )
        }
        #expect(throws: BrushDeviceProfileError.invalidBrushCacheBudgetBytes(0)) {
            _ = try BrushDeviceProfile(
                registryID: 1,
                recommendedWorkingSetBytes: 512 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 4_096,
                brushCacheBudgetBytes: 0,
                targetFramesPerSecond: 120
            )
        }
        #expect(throws: BrushDeviceProfileError.invalidTargetFramesPerSecond(0)) {
            _ = try BrushDeviceProfile(
                registryID: 1,
                recommendedWorkingSetBytes: 512 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 4_096,
                targetFramesPerSecond: 0
            )
        }
        #expect(throws: BrushDeviceProfileError.invalidTargetFramesPerSecond(-1)) {
            _ = try BrushDeviceProfile(
                registryID: 1,
                recommendedWorkingSetBytes: 512 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 4_096,
                targetFramesPerSecond: -1
            )
        }
    }

    @Test
    func defaultCacheBudgetUsesFloorTenPercentAndCeiling() throws {
        let floor = try profile(workingSetBytes: UInt64(100 * mebibyte))
        let middle = try profile(workingSetBytes: UInt64(1_000 * mebibyte))
        let ceiling = try profile(workingSetBytes: UInt64(4_096 * mebibyte))

        #expect(floor.brushCacheBudgetBytes == 64 * mebibyte)
        #expect(middle.brushCacheBudgetBytes == 100 * mebibyte)
        #expect(ceiling.brushCacheBudgetBytes == 256 * mebibyte)
    }

    @Test
    func explicitValidBudgetIsPreserved() throws {
        let profile = try BrushDeviceProfile(
            registryID: 99,
            recommendedWorkingSetBytes: 512 * 1_024 * 1_024,
            maximumWorkingTextureDimension: 2_048,
            brushCacheBudgetBytes: 72 * mebibyte,
            targetFramesPerSecond: 60
        )

        #expect(profile.registryID == 99)
        #expect(profile.maximumWorkingTextureDimension == 2_048)
        #expect(profile.brushCacheBudgetBytes == 72 * mebibyte)
        #expect(profile.targetFramesPerSecond == 60)
    }

    private func profile(workingSetBytes: UInt64) throws -> BrushDeviceProfile {
        try BrushDeviceProfile(
            registryID: 1,
            recommendedWorkingSetBytes: workingSetBytes,
            maximumWorkingTextureDimension: 4_096,
            targetFramesPerSecond: 120
        )
    }
}

@Suite("BrushCompilationReport")
struct BrushCompilationReportTests {
    @Test
    func initializerAllowsEmptyAndRejectsUnsortedAndDuplicateCompatibility() throws {
        let empty = try report(compatibility: [])
        #expect(empty.compatibility.isEmpty)
        #expect(throws: BrushCompilationReportValidationError.unsortedCompatibility) {
            _ = try report(compatibility: [
                entry("zeta"),
                entry("alpha"),
            ])
        }
        #expect(throws: BrushCompilationReportValidationError.duplicateCompatibilitySemanticKey("alpha")) {
            _ = try report(compatibility: [
                entry("alpha"),
                entry("alpha"),
            ])
        }
    }

    @Test
    func initializerRejectsEmptySemanticKey() {
        #expect(throws: BrushCompilationReportValidationError.emptyCompatibilitySemanticKey) {
            _ = try report(compatibility: [entry("")])
        }
    }

    @Test
    func initializerRejectsInvalidIdentityHashAndByteCounts() {
        #expect(throws: BrushCompilationReportValidationError.emptyDefinitionID) {
            _ = try report(definitionID: "")
        }
        for hash in [
            "",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            #expect(throws: BrushCompilationReportValidationError.invalidPackageContentHash) {
                _ = try report(packageContentHash: hash)
            }
        }
        #expect(throws: BrushCompilationReportValidationError.negativeEncodedResourceBytes(-1)) {
            _ = try report(encodedResourceBytes: -1)
        }
        #expect(throws: BrushCompilationReportValidationError.negativeResidentResourceBytes(-2)) {
            _ = try report(residentResourceBytes: -2)
        }
    }

    @Test
    func decodingRevalidatesCompatibilityOrderingAndUniqueness() throws {
        let valid = try report(compatibility: [entry("alpha"), entry("zeta")])
        let encoded = try JSONEncoder().encode(valid)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["compatibility"] = [
            ["semanticKey": "zeta", "level": "exact", "message": "supported"],
            ["semanticKey": "alpha", "level": "exact", "message": "supported"],
        ]
        let unsorted = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: BrushCompilationReportValidationError.unsortedCompatibility) {
            _ = try JSONDecoder().decode(
                BrushCompilationReport.self,
                from: unsorted
            )
        }

        object["compatibility"] = [
            ["semanticKey": "alpha", "level": "exact", "message": "supported"],
            ["semanticKey": "alpha", "level": "exact", "message": "supported"],
        ]
        let duplicate = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: BrushCompilationReportValidationError.duplicateCompatibilitySemanticKey("alpha")) {
            _ = try JSONDecoder().decode(
                BrushCompilationReport.self,
                from: duplicate
            )
        }
    }

    @Test
    func decodingRevalidatesReportIdentityHashAndByteCounts() throws {
        let valid = try report(compatibility: [])
        let encoded = try JSONEncoder().encode(valid)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["definitionID"] = ""
        #expect(throws: BrushCompilationReportValidationError.emptyDefinitionID) {
            _ = try JSONDecoder().decode(
                BrushCompilationReport.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object["definitionID"] = "test.brush"
        object["packageContentHash"] = String(repeating: "A", count: 64)
        #expect(throws: BrushCompilationReportValidationError.invalidPackageContentHash) {
            _ = try JSONDecoder().decode(
                BrushCompilationReport.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object["packageContentHash"] = String(repeating: "a", count: 64)
        object["encodedResourceBytes"] = -1
        #expect(throws: BrushCompilationReportValidationError.negativeEncodedResourceBytes(-1)) {
            _ = try JSONDecoder().decode(
                BrushCompilationReport.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object["encodedResourceBytes"] = 16
        object["residentResourceBytes"] = -2
        #expect(throws: BrushCompilationReportValidationError.negativeResidentResourceBytes(-2)) {
            _ = try JSONDecoder().decode(
                BrushCompilationReport.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test
    func failureRejectsInvalidIdentityRequestedBytesAndReason() {
        #expect(throws: BrushCompilationReportValidationError.emptyDefinitionID) {
            _ = try failure(definitionID: "")
        }
        #expect(throws: BrushCompilationReportValidationError.invalidPackageContentHash) {
            _ = try failure(
                packageContentHash: String(repeating: "A", count: 64)
            )
        }
        #expect(throws: BrushCompilationReportValidationError.negativeRequestedBytes(-1)) {
            _ = try failure(requestedBytes: -1)
        }
        for reason in [
            "",
            String(repeating: "x", count: 1_025),
            String(repeating: "😀", count: 257),
            "unsafe\nreason",
            "unsafe\u{0000}reason",
        ] {
            #expect(throws: BrushCompilationReportValidationError.invalidFailureReason) {
                _ = try failure(reason: reason)
            }
        }
        #expect(throws: Never.self) {
            _ = try failure(reason: String(repeating: "😀", count: 256))
        }
    }

    @Test
    func decodingRevalidatesFailureFields() throws {
        let valid = try failure()
        let encoded = try JSONEncoder().encode(valid)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["definitionID"] = ""
        #expect(throws: BrushCompilationReportValidationError.emptyDefinitionID) {
            _ = try JSONDecoder().decode(
                BrushCompilationFailure.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object["definitionID"] = "test.brush"
        object["packageContentHash"] = String(repeating: "A", count: 64)
        #expect(throws: BrushCompilationReportValidationError.invalidPackageContentHash) {
            _ = try JSONDecoder().decode(
                BrushCompilationFailure.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object["packageContentHash"] = String(repeating: "a", count: 64)
        object["requestedBytes"] = -1
        #expect(throws: BrushCompilationReportValidationError.negativeRequestedBytes(-1)) {
            _ = try JSONDecoder().decode(
                BrushCompilationFailure.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object["requestedBytes"] = 42
        object["reason"] = "unsafe\treason"
        #expect(throws: BrushCompilationReportValidationError.invalidFailureReason) {
            _ = try JSONDecoder().decode(
                BrushCompilationFailure.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test
    func validReportAndFailureRoundTripWithoutResourcePayloads() throws {
        let report = try report(compatibility: [entry("coverage")])
        let decodedReport = try JSONDecoder().decode(
            BrushCompilationReport.self,
            from: JSONEncoder().encode(report)
        )
        #expect(decodedReport == report)

        let failure = try failure()
        let decodedFailure = try JSONDecoder().decode(
            BrushCompilationFailure.self,
            from: JSONEncoder().encode(failure)
        )
        #expect(decodedFailure == failure)
    }

    private func report(
        definitionID: String = "test.brush",
        packageContentHash: String = String(repeating: "a", count: 64),
        compatibility: [BrushCompatibilityEntry] = [],
        encodedResourceBytes: Int = 16,
        residentResourceBytes: Int = 21
    ) throws -> BrushCompilationReport {
        try BrushCompilationReport(
            definitionID: definitionID,
            packageContentHash: packageContentHash,
            backend: .deposition,
            compatibility: compatibility,
            performance: BrushPerformanceClassification(
                tier: .realtime120,
                basis: .estimated,
                reason: "bounded fixture"
            ),
            encodedResourceBytes: encodedResourceBytes,
            residentResourceBytes: residentResourceBytes,
            deviceRegistryID: 7
        )
    }

    private func failure(
        definitionID: String = "test.brush",
        packageContentHash: String = String(repeating: "a", count: 64),
        requestedBytes: Int? = 42,
        reason: String = "fixture failure"
    ) throws -> BrushCompilationFailure {
        try BrushCompilationFailure(
            definitionID: definitionID,
            packageContentHash: packageContentHash,
            backend: .deposition,
            stage: .imageDecode,
            resourceID: "shape.main",
            requestedBytes: requestedBytes,
            deviceRegistryID: 7,
            reason: reason
        )
    }

    private func entry(_ key: String) -> BrushCompatibilityEntry {
        BrushCompatibilityEntry(
            semanticKey: key,
            level: .exact,
            message: "supported"
        )
    }
}
