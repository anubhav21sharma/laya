#if DEBUG
import Foundation
import SwiftUI

struct DebugPerformanceHUD: View {
    let snapshot: DebugPerformanceSnapshot
    let loggingActive: Bool

    init(
        snapshot: DebugPerformanceSnapshot,
        loggingActive: Bool = false
    ) {
        self.snapshot = snapshot
        self.loggingActive = loggingActive
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
            metric(
                "FPS",
                snapshot.sampleCount == 0
                    ? "--"
                    : String(
                        format: "%.1f / %d",
                        snapshot.framesPerSecond,
                        snapshot.targetFramesPerSecond
                    )
            )
            metric(
                "frame p95",
                String(format: "%.2f ms", snapshot.p95FrameMilliseconds)
            )
            metric(
                "prepare p95",
                formattedMilliseconds(prepareP95)
            )
            metric(
                "submit p95",
                formattedMilliseconds(submitP95)
            )
            metric(
                "GPU p95",
                formattedMilliseconds(gpuP95)
            )
            metric(
                "actual/pred q",
                "\(actualQueueDepth)/\(predictedQueueDepth)"
            )
            metric("log", loggingActive ? "REC" : "off")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(6)
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.primary.opacity(0.16))
        }
        .accessibilityIdentifier("Debug Performance HUD")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .gridColumnAlignment(.trailing)
        }
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private func formattedMilliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.2f ms", milliseconds(nanoseconds))
    }

    private var prepareP95: UInt64 {
        snapshot.strokeRuntime?.prepare.p95
            ?? snapshot.deposition.cpuPreparation.p95
    }

    private var submitP95: UInt64 {
        snapshot.strokeRuntime?.eventToSubmit.p95
            ?? snapshot.deposition.eventToSubmit.p95
    }

    private var gpuP95: UInt64 {
        snapshot.strokeRuntime?.gpu.p95
            ?? snapshot.deposition.gpuDuration.p95
    }

    private var actualQueueDepth: Int {
        snapshot.strokeRuntime?.authoritativeQueueDepth
            ?? snapshot.deposition.authoritativeBacklog
    }

    private var predictedQueueDepth: Int {
        snapshot.strokeRuntime?.predictedQueueDepth
            ?? snapshot.deposition.predictedBacklog
    }
}
#endif
