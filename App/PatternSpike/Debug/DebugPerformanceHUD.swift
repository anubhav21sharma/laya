#if DEBUG
import Foundation
import SwiftUI

struct DebugPerformanceHUD: View {
    let snapshot: DebugPerformanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("RENDER")
                    .fontWeight(.semibold)
                Text("~ close")
                    .foregroundStyle(.secondary)
            }
            metric(
                "FPS",
                snapshot.sampleCount == 0
                    ? "measuring"
                    : String(
                        format: "%.1f / %d",
                        snapshot.framesPerSecond,
                        snapshot.targetFramesPerSecond
                    )
            )
            metric(
                "p95 frame",
                String(format: "%.2f ms", snapshot.p95FrameMilliseconds)
            )
            metric(
                "missed",
                String(format: "%.2f%%", snapshot.missedFramePercentage)
            )
        }
        .font(.system(.caption, design: .monospaced))
        .padding(10)
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.16))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
        }
        .frame(minWidth: 168)
    }
}
#endif
