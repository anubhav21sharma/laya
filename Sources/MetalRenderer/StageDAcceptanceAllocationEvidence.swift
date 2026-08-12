public struct StageDAllocationEvidence: Equatable, Sendable {
    public let inputSampleCount: Int
    public let partitionEventCount: Int
    public let leaseEventCount: Int
    public let metalDriverEventCount: Int
    public let metalDriverAllocationCount: Int
    public let offMainSurfaceMetalAllocationCount: Int
    public let firstLifecycleAllocationCount: Int
    public let lastLifecycleAllocationCount: Int
    public let firstDecileNanosecondsPerEvent: UInt64
    public let lastDecileNanosecondsPerEvent: UInt64
    public let zeroWorkLeaseCount: Int
    public let maximumZeroWorkLeaseCount: Int
    public let deferredDrainCount: Int
}

public enum StageDAllocationEvidenceValidationError: Error, Equatable {
    case missingLine(String)
    case duplicateLine(String)
    case malformedLine(String)
    case missingField(String)
    case invalidField(String)
}

public enum StageDAllocationEvidenceValidator {
    private static let tilesPrefix =
        "ALLOCATOR PROBE STAGE D TILES PASS"
    private static let samplingPrefix =
        "ALLOCATOR PROBE STAGE D SAMPLING PASS"
    private static let offMainPrefix =
        "ALLOCATOR PROBE OFF-MAIN PASS"
    private static let productionPrefix =
        "ALLOCATOR PROBE PRODUCTION PASS"
    private static let tracePrefix =
        "ALLOCATOR PROBE TEN-MINUTE TRACE PASS"

    public static func validate(_ log: String) throws
        -> StageDAllocationEvidence
    {
        let lines = log.split(whereSeparator: \Character.isNewline)
            .map(String.init)
        let tileFields = try fields(
            line(named: "tiles", prefix: tilesPrefix, in: lines),
            name: "tiles",
            prefix: tilesPrefix
        )
        let samplingFields = try fields(
            line(named: "sampling", prefix: samplingPrefix, in: lines),
            name: "sampling",
            prefix: samplingPrefix
        )
        let offMainFields = try fields(
            line(named: "off-main", prefix: offMainPrefix, in: lines),
            name: "off-main",
            prefix: offMainPrefix
        )
        let productionFields = try fields(
            line(
                named: "production",
                prefix: productionPrefix,
                in: lines
            ),
            name: "production",
            prefix: productionPrefix
        )
        let traceFields = try fields(
            line(named: "trace", prefix: tracePrefix, in: lines),
            name: "trace",
            prefix: tracePrefix
        )

        let partition = try ratio(
            tileFields,
            field: "partition",
            scope: "tiles"
        )
        let lease = try ratio(
            tileFields,
            field: "lease",
            scope: "tiles"
        )
        let metalDriver = try ratio(
            tileFields,
            field: "metal_driver",
            scope: "tiles"
        )
        guard partition.0 >= 5, partition.1 == 0 else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "tiles.partition"
            )
        }
        guard lease.0 >= 10, lease.1 == 0 else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "tiles.lease"
            )
        }

        for field in [
            "app_acquire", "app_preflight", "app_completion", "app_wait",
        ] {
            let value = try slashLeadingInteger(
                samplingFields,
                field: field,
                scope: "sampling"
            )
            guard value == 0 else {
                throw StageDAllocationEvidenceValidationError.invalidField(
                    "sampling.\(field)"
                )
            }
        }
        guard try integer(samplingFields, field: "events", scope: "sampling")
            > 0 else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "sampling.events"
            )
        }

        for field in [
            "application", "workspace", "main", "authoritative",
            "estimated", "prediction", "packaging", "tile_partition",
            "tile_lease",
        ] {
            guard try integer(
                offMainFields,
                field: field,
                scope: "off-main"
            ) == 0 else {
                throw StageDAllocationEvidenceValidationError.invalidField(
                    "off-main.\(field)"
                )
            }
        }
        let surfaceMetal = try integer(
            offMainFields,
            field: "surface_metal_mallocs",
            scope: "off-main"
        )

        guard try integer(
            productionFields,
            field: "allocations",
            scope: "production"
        ) == 0 else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "production.allocations"
            )
        }

        let samples = try integer(
            traceFields,
            field: "samples",
            scope: "trace"
        )
        guard samples == 36_000 else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "trace.samples"
            )
        }
        let hot = try ratio(
            traceFields,
            field: "hot_allocations",
            scope: "trace"
        )
        guard hot == (0, 0) else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "trace.hot_allocations"
            )
        }
        let lifecycle = try ratio(
            traceFields,
            field: "lifecycle",
            scope: "trace"
        )
        let cpu = try unsignedRatio(
            traceFields,
            field: "cpu_ns",
            scope: "trace"
        )
        let doubled = cpu.0.multipliedReportingOverflow(by: 2)
        let plusBound = cpu.0.addingReportingOverflow(100_000)
        let maximumLast = max(
            doubled.overflow ? UInt64.max : doubled.partialValue,
            plusBound.overflow ? UInt64.max : plusBound.partialValue
        )
        guard cpu.1 <= maximumLast else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "trace.cpu_ns"
            )
        }
        guard try integer(traceFields, field: "missed", scope: "trace") == 0
        else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "trace.missed"
            )
        }
        let zeroWork = try ratio(
            traceFields,
            field: "zero_work",
            scope: "trace"
        )
        guard zeroWork.0 == zeroWork.1 else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "trace.zero_work"
            )
        }
        let deferred = try integer(
            traceFields,
            field: "deferred",
            scope: "trace"
        )

        return StageDAllocationEvidence(
            inputSampleCount: samples,
            partitionEventCount: partition.0,
            leaseEventCount: lease.0,
            metalDriverEventCount: metalDriver.0,
            metalDriverAllocationCount: metalDriver.1,
            offMainSurfaceMetalAllocationCount: surfaceMetal,
            firstLifecycleAllocationCount: lifecycle.0,
            lastLifecycleAllocationCount: lifecycle.1,
            firstDecileNanosecondsPerEvent: cpu.0,
            lastDecileNanosecondsPerEvent: cpu.1,
            zeroWorkLeaseCount: zeroWork.0,
            maximumZeroWorkLeaseCount: zeroWork.1,
            deferredDrainCount: deferred
        )
    }

    private static func line(
        named name: String,
        prefix: String,
        in lines: [String]
    ) throws -> String {
        let matching = lines.filter { $0.hasPrefix(prefix) }
        guard !matching.isEmpty else {
            throw StageDAllocationEvidenceValidationError.missingLine(name)
        }
        guard matching.count == 1 else {
            throw StageDAllocationEvidenceValidationError.duplicateLine(name)
        }
        return matching[0]
    }

    private static func fields(
        _ line: String,
        name: String,
        prefix: String
    ) throws -> [String: String] {
        guard line == prefix || line.hasPrefix(prefix + " ") else {
            throw StageDAllocationEvidenceValidationError.malformedLine(name)
        }
        let suffix = line.dropFirst(prefix.count)
        var result: [String: String] = [:]
        for token in suffix.split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else {
                throw StageDAllocationEvidenceValidationError
                    .malformedLine(name)
            }
            let key = String(pair[0])
            guard result[key] == nil else {
                throw StageDAllocationEvidenceValidationError
                    .malformedLine(name)
            }
            result[key] = String(pair[1])
        }
        return result
    }

    private static func integer(
        _ fields: [String: String],
        field: String,
        scope: String
    ) throws -> Int {
        guard let raw = fields[field] else {
            throw StageDAllocationEvidenceValidationError.missingField(
                "\(scope).\(field)"
            )
        }
        guard let value = Int(raw), value >= 0 else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "\(scope).\(field)"
            )
        }
        return value
    }

    private static func ratio(
        _ fields: [String: String],
        field: String,
        scope: String
    ) throws -> (Int, Int) {
        guard let raw = fields[field] else {
            throw StageDAllocationEvidenceValidationError.missingField(
                "\(scope).\(field)"
            )
        }
        let pair = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard pair.count == 2,
              let first = Int(pair[0]), first >= 0,
              let second = Int(pair[1]), second >= 0
        else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "\(scope).\(field)"
            )
        }
        return (first, second)
    }

    private static func unsignedRatio(
        _ fields: [String: String],
        field: String,
        scope: String
    ) throws -> (UInt64, UInt64) {
        guard let raw = fields[field] else {
            throw StageDAllocationEvidenceValidationError.missingField(
                "\(scope).\(field)"
            )
        }
        let pair = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard pair.count == 2,
              let first = UInt64(pair[0]),
              let second = UInt64(pair[1])
        else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "\(scope).\(field)"
            )
        }
        return (first, second)
    }

    private static func slashLeadingInteger(
        _ fields: [String: String],
        field: String,
        scope: String
    ) throws -> Int {
        guard let raw = fields[field] else {
            throw StageDAllocationEvidenceValidationError.missingField(
                "\(scope).\(field)"
            )
        }
        guard let leading = raw.split(separator: "/").first,
              let value = Int(leading), value >= 0
        else {
            throw StageDAllocationEvidenceValidationError.invalidField(
                "\(scope).\(field)"
            )
        }
        return value
    }
}
