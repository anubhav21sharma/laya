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
                "p95",
                String(format: "%.2f ms", snapshot.p95FrameMilliseconds)
            )
            metric(
                "miss",
                String(format: "%.2f%%", snapshot.missedFramePercentage)
            )
            metric(
                "CPU/GPU",
                String(
                    format: "%.2f / %.2f ms",
                    milliseconds(snapshot.deposition.cpuPreparation.p95),
                    milliseconds(snapshot.deposition.gpuDuration.p95)
                )
            )
            metric(
                "in/done",
                String(
                    format: "%.2f / %.2f ms",
                    milliseconds(snapshot.deposition.eventToSubmit.p95),
                    milliseconds(snapshot.deposition.gpuCompletion.p95)
                )
            )
            metric(
                "queue",
                "\(snapshot.deposition.authoritativeBacklog)"
                    + "/\(snapshot.deposition.predictedBacklog)"
                    + " · max \(snapshot.deposition.backlogHighWater)"
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
}
#endif
