#if DEBUG
import BrushFormat
import EditorCore
import Metal
import MetalRenderer
import PatternEngine
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension UTType {
    static let layaBrush = UTType(
        exportedAs: "com.anubhav.layabrush",
        conformingTo: .zip
    )
    static let brushLabEvidence = UTType(
        exportedAs: "com.anubhav.brush-lab-evidence",
        conformingTo: .package
    )
}

struct BrushLabEvidenceDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.brushLabEvidence]

    private enum Storage: Sendable {
        case regular(Data)
        case directory([String: Data])
    }

    private let storage: Storage

    init(data: Data) {
        storage = .regular(data)
    }

    init(archive: BrushLabManualEvidenceArchive) {
        storage = .directory(archive.files)
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            storage = .regular(data)
            return
        }
        guard let wrappers = configuration.file.fileWrappers else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var files: [String: Data] = [:]
        for (name, wrapper) in wrappers {
            guard let data = wrapper.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            files[name] = data
        }
        storage = .directory(files)
    }

    func fileWrapper(
        configuration _: WriteConfiguration
    ) throws -> FileWrapper {
        switch storage {
        case let .regular(data):
            FileWrapper(regularFileWithContents: data)
        case let .directory(files):
            FileWrapper(
                directoryWithFileWrappers: files.mapValues {
                    FileWrapper(regularFileWithContents: $0)
                }
            )
        }
    }
}

@MainActor
final class BrushLabRuntime {
    let session: BrushLabSession

    var controller: EditorSessionController {
        session.controller
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw MetalRendererError.commandQueueUnavailable
        }
        let renderer = try GridRenderer(
            device: device,
            drawableSize: PatternSize(width: 1, height: 1),
            configuration: TilingCanvasConfiguration(
                pixelSize: GridCanvasContract.defaultPixelSize,
                tiling: .grid
            )
        )
            let controller = EditorSessionController(renderer: renderer)
            #if os(macOS)
            let targetFramesPerSecond = max(
                1,
                NSScreen.main?.maximumFramesPerSecond ?? 60
            )
            #else
            let targetFramesPerSecond = max(
                1,
                UIScreen.main.maximumFramesPerSecond
            )
            #endif
            let profile = try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes: max(
                device.recommendedMaxWorkingSetSize,
                64 * 1_024 * 1_024
            ),
                maximumWorkingTextureDimension:
                    BrushDeviceProfile.maximumPortableTextureDimension,
                targetFramesPerSecond: targetFramesPerSecond
        )
        session = BrushLabSession(
            controller: controller,
            compiler: BrushCompiler(
                device: device,
                commandQueue: queue,
                profile: profile
            )
        )
    }
}

struct BrushLabView: View {
    @State private var runtime: BrushLabRuntime?
    @State private var initializationError: String?
    @State private var importPresented = false
    @State private var exportPresented = false
    @State private var exportDocument: BrushLabEvidenceDocument?
    @State private var exportError: String?
    @State private var seedDraft = "1"
    @State private var showActualDabs = true
    @State private var showPredictedDabs = true
    @State private var performanceMonitor = DebugPerformanceMonitor()
    @State private var lastDisplayMissedFrameCount: UInt64 = 0

    var body: some View {
        Group {
            if let runtime {
                shell(runtime)
            } else if let initializationError {
                ContentUnavailableView(
                    "Brush Lab Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(initializationError)
                )
            } else {
                ProgressView("Preparing Brush Lab…")
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            guard runtime == nil, initializationError == nil else { return }
            do {
                runtime = try BrushLabRuntime()
            } catch {
                initializationError = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: [.layaBrush],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first,
                  let runtime
            else {
                if case let .failure(error) = result {
                    exportError = error.localizedDescription
                }
                return
            }
            Task {
                await runtime.session.loadPackage(at: url)
                seedDraft = String(runtime.session.deterministicSeed)
            }
        }
        .fileExporter(
            isPresented: $exportPresented,
            document: exportDocument,
            contentType: .brushLabEvidence,
            defaultFilename: evidenceFilename
        ) { result in
            exportDocument = nil
            if case let .failure(error) = result {
                exportError = error.localizedDescription
            }
        }
    }

    private func shell(_ runtime: BrushLabRuntime) -> some View {
        VStack(spacing: 0) {
            toolbar(runtime)
            Divider()
            GeometryReader { proxy in
                if proxy.size.width >= 900 {
                    HStack(spacing: 0) {
                        drawingPad(runtime)
                        Divider()
                        inspector(runtime)
                            .frame(width: 390)
                    }
                } else {
                    VStack(spacing: 0) {
                        drawingPad(runtime)
                        Divider()
                        inspector(runtime)
                            .frame(height: min(330, proxy.size.height * 0.45))
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let message = exportError ?? runtime.session.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                        .font(.caption)
                        Spacer()
                        Button {
                            exportError = nil
                            runtime.session.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .foregroundStyle(.white)
                .background(Color.red.opacity(0.92))
            }
        }
        .onAppear {
            runtime.controller.renderer.onInteractiveFramePresented = {
                timestamp,
                targetFramesPerSecond in
                performanceMonitor.recordPresentedFrame(
                    at: timestamp,
                    targetFramesPerSecond: targetFramesPerSecond
                )
                let snapshot = performanceMonitor.snapshot
                runtime.session.updateFrameMetrics(
                    framesPerSecond: snapshot.framesPerSecond,
                    p95FrameMilliseconds:
                    snapshot.p95FrameMilliseconds,
                    missedFramePercentage:
                    snapshot.missedFramePercentage,
                    targetFramesPerSecond:
                    snapshot.targetFramesPerSecond,
                    sampleCount: snapshot.sampleCount
                )
            }
            runtime.controller.renderer.onInteractiveFrameMetrics = {
                runtime.session.recordRendererFrameMetrics($0)
                let renderer = runtime.controller.renderer
                    .brushLabDiagnosticSnapshot
                let cpuNanoseconds = UInt64(
                    max(0, $0.cpuEncodeMilliseconds) * 1_000_000
                )
                let displayMissedFrames =
                    performanceMonitor.snapshot.missedFrameCount
                let newMissedFrames = displayMissedFrames
                    >= lastDisplayMissedFrameCount
                    ? displayMissedFrames - lastDisplayMissedFrameCount
                    : 0
                lastDisplayMissedFrameCount = displayMissedFrames
                performanceMonitor.recordDepositionSample(
                    authoritativeBacklog:
                        renderer.deposition.authoritativePending,
                    predictedBacklog:
                        renderer.deposition.predictedPending,
                    authoritativeHighWater:
                        renderer.deposition.authoritativeHighWater,
                    predictedHighWater:
                        renderer.deposition.predictedHighWater,
                    backlogHighWater:
                        renderer.deposition.backlogHighWater,
                    encodedDabs: UInt64($0.encodedDabCount),
                    encodedInstances:
                        UInt64($0.encodedInstanceCount),
                    currentBufferLeaseCount:
                        renderer.deposition.currentBufferLeaseCount,
                    strokeBufferLeaseHighWater:
                        renderer.deposition.strokeBufferLeaseHighWater,
                    lifetimeBufferLeaseHighWater:
                        renderer.deposition.lifetimeBufferLeaseHighWater,
                    cpuPreparationNanoseconds: cpuNanoseconds,
                    eventToSubmitNanoseconds:
                        $0.eventToSubmitNanoseconds,
                    gpuDurationNanoseconds: UInt64(
                        max(0, $0.gpuMilliseconds) * 1_000_000
                    ),
                    gpuCompletionNanoseconds:
                        $0.gpuCompletionNanoseconds,
                    missedFrames: newMissedFrames
                )
                runtime.session.updateDepositionMetrics(
                    performanceMonitor.snapshot.deposition
                )
            }
        }
        .onDisappear {
            runtime.controller.renderer.onInteractiveFramePresented = nil
            runtime.controller.renderer.onInteractiveFrameMetrics = nil
            runtime.controller.handleFocusLoss()
        }
    }

    private func toolbar(_ runtime: BrushLabRuntime) -> some View {
        HStack(spacing: 8) {
            Button {
                importPresented = true
            } label: {
                Label("Load .layabrush", systemImage: "folder")
            }
            .disabled(runtime.session.isLoading)

            Button {
                exportEvidence(runtime)
            } label: {
                Label(
                    "Export Card Evidence",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(
                runtime.session.selectedManualCard == nil
                    || !runtime.controller.renderer.isIdle
            )

            Divider()
                .frame(height: 22)

            Text("Seed")
                .foregroundStyle(.secondary)
            TextField("Seed", text: $seedDraft)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 110)
                .onSubmit {
                    applySeed(runtime)
                }
            Button("Apply") {
                applySeed(runtime)
            }

            Button("Clear Trace") {
                runtime.session.clearTrace()
            }

            Menu {
                ForEach(runtime.session.manualCards, id: \.cardID) { card in
                    Button(card.cardID) {
                        Task {
                            do {
                                try await runtime.session.selectManualCard(
                                    card.cardID
                                )
                                resetDiagnosticsTracking()
                                exportError = nil
                            } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    }
                }
            } label: {
                Label(
                    runtime.session.selectedManualCard.map {
                        "\($0.gesture.rawValue) · \($0.brushID)"
                    } ?? "Select Card",
                    systemImage: "rectangle.stack"
                )
            }

            Button("Replay Card") {
                Task {
                    do {
                        _ = try await runtime.session
                            .replaySelectedManualCard()
                        exportError = nil
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
            }
            .disabled(
                runtime.session.selectedManualCard == nil
                    || !runtime.controller.renderer.isIdle
            )

            Button("Clear Card") {
                runtime.session.clearManualCard()
                resetDiagnosticsTracking()
            }
            .disabled(!runtime.controller.renderer.isIdle)

            Spacer()
            if runtime.session.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(runtime.session.sourceName ?? "No package")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(.bar)
    }

    private func drawingPad(_ runtime: BrushLabRuntime) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(
                    "Tool",
                    selection: Binding(
                        get: { runtime.controller.model.tool },
                        set: { runtime.controller.handleTool($0) }
                    )
                ) {
                    Text("Draw").tag(EditorTool.draw)
                    Text("Erase").tag(EditorTool.erase)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Button {
                    runtime.controller.stepBrush(larger: false)
                } label: {
                    Image(systemName: "minus")
                }
                Text(
                    "\(Int(runtime.controller.model.brushDiameter.rounded())) px"
                )
                .monospacedDigit()
                Button {
                    runtime.controller.stepBrush(larger: true)
                } label: {
                    Image(systemName: "plus")
                }

                Picker(
                    "Tiling",
                    selection: Binding(
                        get: { runtime.controller.model.tiling },
                        set: { tiling in
                            guard tiling.isPeriodic else { return }
                            if !runtime.controller.model.tiling.isPeriodic {
                                runtime.controller.selectSeamlessPatternMode()
                            }
                            runtime.controller.handleTiling(tiling)
                        }
                    )
                ) {
                    if !runtime.controller.model.tiling.isPeriodic {
                        Text(String(
                            describing: runtime.controller.model.tiling
                        ))
                        .tag(runtime.controller.model.tiling)
                    }
                    ForEach(TilingKind.periodicCases, id: \.self) {
                        Text(String(describing: $0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 190)
                .disabled(
                    runtime.controller.model.documentDomainLocked
                        && !runtime.controller.model.tiling.isPeriodic
                )

                Toggle(
                    "Symmetry overlay",
                    isOn: Binding(
                        get: { runtime.controller.model.showGrid },
                        set: {
                            runtime.controller.handleGridVisibility($0)
                        }
                    )
                )
                .toggleStyle(.switch)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(6)
            .background(.bar)

            statusBanner(runtime.session.drawingAvailability)

            EditorCanvasHost(
                controller: runtime.controller,
                brushDiameter: runtime.controller.model.brushDiameter,
                requestEditorFocus: {},
                pointerCancellationGeneration: 0
            )
            .accessibilityIdentifier("Brush Lab Canvas")
            .allowsHitTesting(!runtime.session.isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func statusBanner(
        _ availability: BrushLabDrawingAvailability
    ) -> some View {
        switch availability {
        case .unloaded:
            Label(
                "Load a native package; the pad currently uses the built-in "
                    + "brush.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(6)
        case .available:
            Label(
                "Compiled package is active in the production renderer.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.caption)
            .padding(6)
        case let .unsupportedInteraction(interaction):
            Label(
                "\(interaction.rawValue) interaction is inspectable but unavailable in the production deposition renderer.",
                systemImage: "hammer.fill"
            )
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(6)
        case let .compilationFailed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .padding(6)
        }
    }

    private func inspector(_ runtime: BrushLabRuntime) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                manualCardSection(runtime.session)
                resourcesSection(runtime.session)
                conversionSection(runtime.session)
                compilationSection(runtime.session)
                settingsSection(runtime.session)
                metricsSection(runtime.session)
                traceSection(runtime.session)
            }
            .padding(10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func manualCardSection(_ session: BrushLabSession) -> some View {
        inspectorHeader("Manual Card")
        if let card = session.selectedManualCard {
            keyValue("ID", card.cardID)
            keyValue("Gesture", card.gesture.rawValue)
            keyValue(
                "Size / pressure",
                "\(card.diameter) / \(card.pressureProfile)"
            )
            keyValue("Projection", card.documentMode)
            keyValue(
                "Background / prediction",
                "\(card.background.rawValue) / "
                    + (card.predictionEnabled ? "on" : "off")
            )
            keyValue(
                "Capabilities",
                card.inputCapabilities.isEmpty
                    ? "none"
                    : card.inputCapabilities.joined(separator: ", ")
            )
            keyValue(
                "Custom fixture",
                card.customResourceFixture ?? "none"
            )
            Text("Assessment pending user input")
                .font(.caption2.monospaced())
                .foregroundStyle(.orange)
        } else {
            Text("Select one of \(session.manualCards.count) fixed cards")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resourcesSection(_ session: BrushLabSession) -> some View {
        inspectorHeader("Resources")
        if session.resourcePreviews.isEmpty {
            Text("No packaged image resources")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112))],
                spacing: 8
            ) {
                ForEach(session.resourcePreviews) { preview in
                    VStack(alignment: .leading, spacing: 4) {
                        resourceImage(preview.data)
                            .frame(height: 92)
                            .frame(maxWidth: .infinity)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(preview.descriptor.id)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                        Text(
                            "\(preview.descriptor.kind.rawValue) · "
                                + "\(preview.descriptor.pixelWidth)×"
                                + "\(preview.descriptor.pixelHeight)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func conversionSection(_ session: BrushLabSession) -> some View {
        inspectorHeader("Conversion")
        if let report = session.package?.conversionReport {
            Text(
                "\(report.sourceFormat) · exact \(report.summary.exact) · "
                    + "approx \(report.summary.approximated) · unsupported "
                    + "\(report.summary.unsupported)"
            )
            .font(.caption.monospaced())
            ForEach(report.entries, id: \.sourceSemanticKey) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(entry.disposition.rawValue) · "
                            + entry.sourceSemanticKey
                    )
                    .font(.caption.monospaced())
                    Text(entry.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Native package; no conversion report")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func compilationSection(_ session: BrushLabSession) -> some View {
        inspectorHeader("Compiler")
        if let report = session.compilationReport {
            let compiled = session.compiledBrush
            keyValue("Backend", report.backend.rawValue)
            keyValue(
                "Pipeline",
                compiled.map {
                    "\($0.pipelineKey.accumulation.rawValue) / "
                        + $0.pipelineKey.edgeTreatment.rawValue
                } ?? "—"
            )
            keyValue(
                "ABI",
                compiled.map {
                    "\($0.depositionPipeline.key.abiVersion)"
                } ?? "—"
            )
            keyValue("Textures", "\(compiled?.textures.count ?? 0)")
            ForEach(
                compiled?.textures.keys.sorted() ?? [],
                id: \.self
            ) { id in
                if let texture = compiled?.textures[id] {
                    keyValue(
                        id,
                        "\(texture.mipmapLevelCount) levels · "
                            + ByteCountFormatter.string(
                                fromByteCount: Int64(texture.allocatedSize),
                                countStyle: .memory
                            )
                    )
                }
            }
            keyValue("Tier", report.performance.tier.rawValue)
            keyValue(
                "Resident",
                ByteCountFormatter.string(
                    fromByteCount: Int64(report.residentResourceBytes),
                    countStyle: .memory
                )
            )
            keyValue(
                "Package hash",
                String(report.packageContentHash.prefix(12))
            )
            ForEach(
                session.compilationDiagnostics,
                id: \.self
            ) {
                Text($0)
                    .font(.caption2.monospaced())
            }
        } else if let failure = session.compilationFailure {
            Text(
                "\(failure.stage.rawValue): \(failure.reason)"
            )
            .font(.caption.monospaced())
            .foregroundStyle(.red)
        } else {
            Text("Not compiled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsSection(_ session: BrushLabSession) -> some View {
        ForEach(session.settingGroups) { group in
            VStack(alignment: .leading, spacing: 4) {
                inspectorHeader(group.title)
                ForEach(group.items) { item in
                    keyValue(item.name, item.value)
                }
            }
        }
    }

    private func metricsSection(_ session: BrushLabSession) -> some View {
        let compiler = session.compiler.diagnosticSnapshot
        let counters = compiler.counters
        let renderer = session.controller.renderer
            .brushLabDiagnosticSnapshot
        return VStack(alignment: .leading, spacing: 3) {
            inspectorHeader("Live Metrics")
            keyValue("Dabs", "\(renderer.totalDabsThisStroke)")
            keyValue(
                "Actual / predicted",
                "\(renderer.actualDabCount) / \(renderer.predictedDabCount)"
            )
            keyValue("Instances", "\(renderer.totalInstancesThisStroke)")
            keyValue("Dirty regions", "\(renderer.dirtyRegionCount)")
            keyValue("Replay count", "\(renderer.replayCount)")
            keyValue(
                "Backlog A / P",
                "\(session.depositionMetrics.authoritativeBacklog) / "
                    + "\(session.depositionMetrics.predictedBacklog)"
            )
            keyValue(
                "Backlog high A / P",
                "\(session.depositionMetrics.authoritativeHighWater) / "
                    + "\(session.depositionMetrics.predictedHighWater)"
            )
            keyValue(
                "Buffer current / stroke / life",
                "\(session.depositionMetrics.currentBufferLeaseCount) / "
                    + "\(session.depositionMetrics.strokeBufferLeaseHighWater)"
                    + " / "
                    + "\(session.depositionMetrics.lifetimeBufferLeaseHighWater)"
            )
            keyValue(
                "Encoded dabs / instances",
                "\(session.depositionMetrics.encodedDabCount) / "
                    + "\(session.depositionMetrics.encodedInstanceCount)"
            )
            keyValue(
                "Revision residency",
                ByteCountFormatter.string(
                    fromByteCount:
                    Int64(renderer.rasterRevisionResidentBytes),
                    countStyle: .memory
                )
            )
            keyValue(
                "Compile/cache",
                "\(counters.activationCount) / \(counters.cacheHitCount)"
            )
            keyValue(
                "Uploads",
                "\(counters.textureUploadCount)"
            )
            keyValue(
                "Brush cache",
                ByteCountFormatter.string(
                    fromByteCount: Int64(compiler.cacheResidentBytes),
                    countStyle: .memory
                )
                    + " / "
                    + ByteCountFormatter.string(
                        fromByteCount: Int64(compiler.cacheBudgetBytes),
                        countStyle: .memory
                    )
            )
            keyValue(
                "CPU / GPU",
                session.frameMetrics.rendererSampleCount == 0
                    ? "collecting…"
                    : String(
                        format: "%.2f / %.2f ms",
                        session.frameMetrics.cpuEncodeMilliseconds,
                        session.frameMetrics.gpuMilliseconds
                    )
            )
            keyValue(
                "CPU / GPU p95",
                session.frameMetrics.rendererSampleCount == 0
                    ? "collecting…"
                    : String(
                        format: "%.2f / %.2f ms",
                        session.frameMetrics.p95CPUEncodeMilliseconds,
                        session.frameMetrics.p95GPUMilliseconds
                    )
            )
            keyValue(
                "Prep / submit / complete p95",
                String(
                    format: "%.2f / %.2f / %.2f ms",
                    Double(
                        session.depositionMetrics.cpuPreparation.p95
                    ) / 1_000_000,
                    Double(
                        session.depositionMetrics.eventToSubmit.p95
                    ) / 1_000_000,
                    Double(
                        session.depositionMetrics.gpuCompletion.p95
                    ) / 1_000_000
                )
            )
            keyValue(
                "Missed frames",
                "\(session.depositionMetrics.missedFrameCount)"
            )
            keyValue(
                "Last failure stage",
                session.compilationFailure?.stage.rawValue ?? "none"
            )
            keyValue(
                "FPS / p95",
                session.frameMetrics.sampleCount == 0
                    ? "collecting…"
                    : String(
                        format: "%.1f / %.2f ms",
                        session.frameMetrics.framesPerSecond,
                        session.frameMetrics.p95FrameMilliseconds
                    )
            )
        }
    }

    private func traceSection(_ session: BrushLabSession) -> some View {
        let visible = session.dabRecords.filter {
            $0.predicted ? showPredictedDabs : showActualDabs
        }
        let dropped = session.droppedInputRecordCount
            + session.droppedDabRecordCount
        return VStack(alignment: .leading, spacing: 5) {
            inspectorHeader("Normalized Input / Logical Dabs")
            HStack {
                Toggle("Actual", isOn: $showActualDabs)
                Toggle("Predicted", isOn: $showPredictedDabs)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Text(
                "inputs \(session.inputRecords.count) · dabs "
                    + "\(session.dabRecords.count) · dropped "
                    + "\(dropped)"
            )
            .font(.caption2.monospaced())
            ForEach(visible.suffix(40), id: \.sequence) { dab in
                Text(
                    "#\(dab.ordinal) \(dab.predicted ? "P" : "A") "
                        + String(
                            format: "(%.1f, %.1f) %.1fpx r%.2f",
                            dab.x,
                            dab.y,
                            dab.diameter,
                            dab.rotation
                        )
                )
                .font(.caption2.monospaced())
            }
        }
    }

    private func inspectorHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func resourceImage(_ data: Data) -> some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "photo.badge.exclamationmark")
        }
        #else
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "photo.badge.exclamationmark")
        }
        #endif
    }

    private func applySeed(_ runtime: BrushLabRuntime) {
        guard let seed = UInt64(seedDraft), seed != 0 else {
            exportError = "Seed must be a nonzero unsigned integer."
            return
        }
        do {
            try runtime.session.setDeterministicSeed(seed)
            seedDraft = String(seed)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func resetDiagnosticsTracking() {
        performanceMonitor.reset()
        lastDisplayMissedFrameCount = 0
    }

    private func exportEvidence(_ runtime: BrushLabRuntime) {
        do {
            let archive = try runtime.session.makeManualEvidenceArchive()
            #if os(macOS)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.brushLabEvidence]
            panel.nameFieldStringValue = evidenceFilename
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try BrushLabManualEvidenceSaveService.live.save(
                        archive,
                        to: url
                    )
                    exportError = nil
                } catch {
                    exportError = error.localizedDescription
                }
            }
            #else
            exportDocument = BrushLabEvidenceDocument(
                archive: archive
            )
            exportPresented = true
            exportError = nil
            #endif
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var evidenceFilename: String {
        guard let sourceName = runtime?.session.sourceName else {
            return "brush-lab-card.brushlabevidence"
        }
        let base = URL(fileURLWithPath: sourceName)
            .deletingPathExtension()
            .lastPathComponent
        return "\(base)-card.brushlabevidence"
    }
}

struct BrushLabCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Developer") {
            Button("Open Brush Lab") {
                openWindow(id: "brush-lab")
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
#endif
