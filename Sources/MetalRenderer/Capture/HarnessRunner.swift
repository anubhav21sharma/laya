import Darwin
import Foundation
import Metal

public struct HarnessRunResult: Equatable, Sendable {
    public let imageURL: URL
    public let benchmarkURL: URL
    public let benchmark: BenchmarkRecord
}

public enum HarnessRunError: Error, Equatable, LocalizedError {
    case processMetricsUnavailable
    case pixelMismatch(
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )

    public var errorDescription: String? {
        switch self {
        case .processMetricsUnavailable:
            "Peak resident-memory measurement is unavailable."
        case let .pixelMismatch(x, y, expected, actual, tolerance):
            "Pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        }
    }
}

@MainActor
public final class HarnessRunner {
    private let renderer: BlankRenderer

    public init(device: any MTLDevice) throws {
        renderer = try BlankRenderer(device: device)
    }

    public func run(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let frame = try renderer.renderOffscreen(
            width: scene.width,
            height: scene.height
        )
        let imageURL = outputDirectory
            .appendingPathComponent("\(scene.name).screen.png")

        try PNGWriter.write(texture: frame.texture, to: imageURL)

        for check in scene.checks {
            let actual = PNGWriter.pixel(
                in: frame.texture,
                x: check.x,
                y: check.y
            )
            let expected = SIMD4(
                check.expectedBGRA[0],
                check.expectedBGRA[1],
                check.expectedBGRA[2],
                check.expectedBGRA[3]
            )
            guard BlankCanvasContract.matches(
                actual: actual,
                expected: expected,
                tolerance: check.tolerance
            ) else {
                throw HarnessRunError.pixelMismatch(
                    x: check.x,
                    y: check.y,
                    expected: check.expectedBGRA,
                    actual: [actual.x, actual.y, actual.z, actual.w],
                    tolerance: check.tolerance
                )
            }
        }

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: 1,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: renderer.device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: 1,
            cpuEncodeMilliseconds: [frame.metrics.cpuEncodeMilliseconds],
            gpuMilliseconds: [frame.metrics.gpuMilliseconds],
            peakResidentBytes: try Self.peakResidentBytes()
        )
        let benchmarkURL = outputDirectory
            .appendingPathComponent("\(scene.name).benchmark.json")
        try BenchmarkRecord.encode(record).write(
            to: benchmarkURL,
            options: .atomic
        )

        return HarnessRunResult(
            imageURL: imageURL,
            benchmarkURL: benchmarkURL,
            benchmark: record
        )
    }

    private static func peakResidentBytes() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw HarnessRunError.processMetricsUnavailable
        }
        return UInt64(usage.ru_maxrss)
    }
}
