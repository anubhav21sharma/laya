import EditorCore
import Metal
import MetalRenderer
import PatternEngine
import PatternFile
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

let editorControlExtent: CGFloat = 32
let editorInspectorWidth: CGFloat = 216
#else
let editorControlExtent: CGFloat = 44
let editorInspectorWidth: CGFloat = 252
#endif

enum EditorFocusTarget: Hashable {
    case editor
    case tileWidth
    case tileHeight
    case latticeRepeatSize
    case latticeOrientation
    case radialRayCount
    case radialCenterX
    case radialCenterY
    case radialReferenceAngle
}

enum EditorImageExportDisposition: Equatable {
    case userSelectedDestination
    case direct(URL)
}

enum EditorImageExportPolicy {
    static func disposition(
        acceptanceDestination: URL?
    ) -> EditorImageExportDisposition {
        acceptanceDestination.map(EditorImageExportDisposition.direct)
            ?? .userSelectedDestination
    }
}

@MainActor
func makeBootstrapEditorSession(
    device: any MTLDevice,
    library: any MTLLibrary,
    selectionStore: any EditorBrushSelectionStore =
        UserDefaultsEditorBrushSelectionStore.live
) async throws -> EditorSessionController {
    let configuration = try TilingCanvasConfiguration(
        pixelSize: GridCanvasContract.defaultPixelSize,
        tiling: .grid
    )
    guard let queue = device.makeCommandQueue() else {
        throw MetalRendererError.commandQueueUnavailable
    }
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 1, height: 1),
        configuration: configuration
    )
    let pipelineLibrary = DepositionPipelineLibrary(
        device: device,
        library: library
    )
    let compiler = BrushCompiler(
        device: device,
        commandQueue: queue,
        profile: try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes: max(
                device.recommendedMaxWorkingSetSize,
                64 * 1_024 * 1_024
            ),
            maximumWorkingTextureDimension:
                BrushDeviceProfile.maximumPortableTextureDimension,
            targetFramesPerSecond: 120
        ),
        pipelineLibrary: pipelineLibrary
    )
    return try await makeBootstrapEditorSession(
        renderer: renderer,
        compileDefinition: { definition in
            try await compiler.compileAndActivate(definition: definition)
        },
        selectionStore: selectionStore
    )
}

@MainActor
func makeBootstrapEditorSession(
    renderer: GridRenderer,
    compileDefinition: @escaping @MainActor @Sendable
        (BrushDefinition) async throws -> CompiledBrush,
    selectionStore: any EditorBrushSelectionStore
) async throws -> EditorSessionController {
    let controller = EditorSessionController(
        renderer: renderer,
        compileDefinition: compileDefinition,
        selectionStore: selectionStore
    )
    let storedID = selectionStore.readSelectedBrushID().map {
        BrushRecipeID($0)
    }
    let resolvedID = try storedID.flatMap {
        try EditorBrushCatalog.resolveCurrentSelection($0)
    } ?? EditorBrushCatalog.defaultDraw.id
    let requestedEntry = EditorBrushCatalog.drawEntry(for: resolvedID)
        ?? EditorBrushCatalog.defaultDraw
    let eraser = try await compileDefinition(
        EditorBrushCatalog.eraser.definition
    )
    guard eraser.renderIdentity.definitionID == EditorBrushCatalog.eraser.id
    else {
        throw MetalRendererError.invalidCompiledBrush
    }

    do {
        try await installBootstrapSelection(
            requestedEntry,
            eraser: eraser,
            controller: controller,
            compileDefinition: compileDefinition
        )
    } catch {
        guard requestedEntry.id != EditorBrushCatalog.defaultDraw.id else {
            throw error
        }
        try await installBootstrapSelection(
            EditorBrushCatalog.defaultDraw,
            eraser: eraser,
            controller: controller,
            compileDefinition: compileDefinition
        )
    }
    return controller
}

@MainActor
private func installBootstrapSelection(
    _ entry: EditorBrushEntry,
    eraser: CompiledBrush,
    controller: EditorSessionController,
    compileDefinition: @MainActor @Sendable
        (BrushDefinition) async throws -> CompiledBrush
) async throws {
    let draw = try await compileDefinition(entry.definition)
    guard draw.renderIdentity.definitionID == entry.id else {
        throw MetalRendererError.invalidCompiledBrush
    }
    try controller.installBootstrapBrushes(draw: draw, eraser: eraser)
    try controller.confirmBootstrapBrushSelection(entry.id)
}

struct EditorCanvasHost: View {
    let controller: EditorSessionController
    let brushDiameter: Float
    let requestEditorFocus: @MainActor () -> Void
    let pointerCancellationGeneration: UInt

    var body: some View {
        MetalCanvas(
            controller: controller,
            renderer: controller.renderer,
            brushDiameter: brushDiameter,
            requestEditorFocus: requestEditorFocus,
            pointerCancellationGeneration:
                pointerCancellationGeneration
        )
        .id(ObjectIdentifier(controller))
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    @State private var state: CanvasState = .loading
    @State private var runtimeError: MetalRendererError?
    @State private var fileErrorMessage: String?
    @State private var projectIdentity = PatternProjectIdentity.new()
    @State private var fileOperationBusy = false
    @State private var fileOperationCompletionGeneration: UInt64 = 0
    @State private var importPresented = false
    @State private var projectExportPresented = false
    @State private var projectExportURL: URL?
    @State private var imageExportPresented = false
    @State private var imageExportURL: URL?
    @State private var stageDRouteEvidence = StageDAppRouteEvidenceRecorder()
    @State private var pointerCancellationGeneration: UInt = 0
    @State private var editorFocusCompletionGeneration: UInt64 = 0
    @FocusState private var focusTarget: EditorFocusTarget?
    #if DEBUG && os(macOS)
    @State private var debugHUDVisible = false
    @State private var debugPerformanceMonitor = DebugPerformanceMonitor()
    @State private var debugPerformanceLogger = DebugPerformanceLogger()
    @State private var debugPerformanceLoggingActive = false
    @State private var debugPerformanceControllerID: ObjectIdentifier?
    #endif

    init(controller: EditorSessionController) {
        _state = State(initialValue: .ready(controller))
    }

    init() {}

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Preparing renderer…")
            case let .ready(controller):
                editorShell(controller)
            case let .unavailable(message):
                ContentUnavailableView(
                    "Renderer Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await initializeRendererIfNeeded()
        }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: [.patternProject],
            allowsMultipleSelection: false
        ) {
            handleImportResult($0)
        }
        .fileExporter(
            isPresented: $projectExportPresented,
            item: projectExportURL,
            contentTypes: [.patternProject],
            defaultFilename: defaultProjectFilename
        ) { result in
            let temporaryURL = projectExportURL
            projectExportURL = nil
            if let temporaryURL {
                try? FileManager.default.removeItem(
                    at: temporaryURL.deletingLastPathComponent()
                )
            }
            if case let .failure(error) = result {
                fileErrorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $imageExportPresented,
            item: imageExportURL,
            contentTypes: [.png],
            defaultFilename: "Pattern.png"
        ) { result in
            let temporaryURL = imageExportURL
            imageExportURL = nil
            if let temporaryURL {
                try? FileManager.default.removeItem(
                    at: temporaryURL.deletingLastPathComponent()
                )
            }
            if case let .failure(error) = result {
                fileErrorMessage = error.localizedDescription
            }
        }
    }

    private func initializeRendererIfNeeded() async {
        guard case .loading = state else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .unavailable(
                "Pattern requires a Metal-capable Apple device."
            )
            return
        }

        do {
            guard let library = device.makeDefaultLibrary() else {
                throw MetalRendererError.defaultLibraryUnavailable
            }
            state = .ready(try await makeBootstrapEditorSession(
                device: device,
                library: library
            ))
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    private func editorShell(
        _ controller: EditorSessionController
    ) -> some View {
        VStack(spacing: 0) {
            EditorTopBar(
                controller: controller,
                requestEditorFocus: requestEditorFocus,
                openProject: beginOpen,
                saveProject: {
                    beginSave(controller)
                },
                exportImage: {
                    beginImageExport(controller)
                },
                imageExportEnabled: true,
                fileOperationsEnabled: !fileOperationBusy,
                reportError: { error in
                    fileErrorMessage = error.localizedDescription
                }
            )
            StageDAppRouteEvidenceControl(
                recorder: stageDRouteEvidence,
                fileOperationCompletionGeneration:
                    fileOperationCompletionGeneration,
                editorFocusCompletionGeneration:
                    editorFocusCompletionGeneration,
                debugHUDVisible: stageDDebugHUDVisible,
                restoreEditorFocus: restoreEditorKeyboardFocus
            )
            Divider()
            HStack(spacing: 0) {
                ToolRail(
                    controller: controller,
                    requestEditorFocus: requestEditorFocus
                )
                Divider()
                ZStack(alignment: .bottomTrailing) {
                    EditorCanvasHost(
                        controller: controller,
                        brushDiameter: controller.model.brushDiameter,
                        requestEditorFocus: requestEditorFocus,
                        pointerCancellationGeneration:
                            pointerCancellationGeneration
                    )
                    .accessibilityIdentifier("Pattern Canvas")
                    #if DEBUG && os(macOS)
                    if debugHUDVisible {
                        DebugPerformanceHUD(
                            snapshot: debugPerformanceMonitor.snapshot,
                            loggingActive: debugPerformanceLoggingActive
                        )
                        .padding(8)
                        .allowsHitTesting(false)
                    }
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    LayerPanel(
                        controller: controller,
                        reportError: { error in
                            fileErrorMessage = error.localizedDescription
                        },
                        requestEditorFocus: requestEditorFocus
                    )
                    Divider()
                    TilingInspector(
                        controller: controller,
                        runtimeError: $runtimeError,
                        focusTarget: $focusTarget,
                        requestEditorFocus: requestEditorFocus
                    )
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if let runtimeError {
                    ErrorBanner(error: runtimeError) {
                        self.runtimeError = nil
                        requestEditorFocus()
                    }
                }
                if let fileErrorMessage {
                    FileErrorBanner(message: fileErrorMessage) {
                        self.fileErrorMessage = nil
                        requestEditorFocus()
                    }
                }
            }
            .padding(.top, editorControlExtent + 16)
        }
        .focusable()
        .focused($focusTarget, equals: .editor)
        .onChange(of: focusTarget) { _, target in
            if target != .editor {
                cancelCurrentInteraction(controller)
            }
        }
        .onKeyPress(phases: .all) { press in
            handleKeyPress(press, controller: controller)
        }
        .onAppear {
            stageDRouteEvidence.bind(controller)
            requestEditorFocus()
            controller.onError = {
                runtimeError = $0
            }
            controller.renderer.onError = {
                runtimeError = $0
            }
            #if DEBUG && os(macOS)
            updateDebugPerformanceSampling(
                controller,
                visible: debugHUDVisible
            )
            #endif
        }
        .onDisappear {
            stageDRouteEvidence.unbind(controller)
            cancelCurrentInteraction(controller)
            controller.onError = nil
            controller.renderer.onError = nil
            #if DEBUG && os(macOS)
            updateDebugPerformanceSampling(controller, visible: false)
            #endif
        }
        #if DEBUG && os(macOS)
        .onChange(of: debugHUDVisible) { _, visible in
            updateDebugPerformanceSampling(controller, visible: visible)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            updateDebugPerformanceSampling(controller, visible: false)
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                cancelCurrentInteraction(controller)
            }
        }
        #if os(macOS)
        .onChange(of: controlActiveState) { _, activeState in
            if activeState != .key {
                cancelCurrentInteraction(controller)
            }
        }
        .focusedSceneValue(
            \.editorCommandActions,
            commandActions(for: controller)
        )
        #endif
        .id(ObjectIdentifier(controller))
    }

    private func requestEditorFocus() {
        focusTarget = .editor
    }

    private func restoreEditorKeyboardFocus() {
        focusTarget = nil
        Task { @MainActor in
            await Task.yield()
            focusTarget = .editor
            editorFocusCompletionGeneration &+= 1
        }
    }

    private var defaultProjectFilename: String {
        let base = projectIdentity.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = base.isEmpty ? "Untitled Pattern" : base
        return title.lowercased().hasSuffix(".patternproj")
            ? title
            : "\(title).patternproj"
    }

    private func beginOpen() {
        guard !fileOperationBusy else { return }
        if let url = stageDRouteEvidence.projectURL {
            openProject(at: url, securityScoped: false)
            return
        }
        importPresented = true
    }

    private func beginSave(
        _ controller: EditorSessionController
    ) {
        guard !fileOperationBusy else { return }
        fileErrorMessage = nil
        fileOperationBusy = true
        Task {
            defer { completeFileOperation() }
            do {
                let captured = try await PatternProjectBridge.capture(
                    renderer: controller.renderer,
                    identity: projectIdentity,
                    appVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "0.1.0"
                )
                let requestedDestination = stageDRouteEvidence.projectURL
                let filename = defaultProjectFilename
                let writtenURL = try await Task.detached(
                    priority: .utility
                ) {
                    let directory: URL
                    let destination: URL
                    let createdTemporaryDirectory: Bool
                    if let requested = requestedDestination {
                        directory = requested.deletingLastPathComponent()
                        createdTemporaryDirectory = false
                        try FileManager.default.createDirectory(
                            at: directory,
                            withIntermediateDirectories: true
                        )
                        destination = requested
                        try? FileManager.default.removeItem(at: destination)
                    } else {
                        createdTemporaryDirectory = true
                        directory = FileManager.default.temporaryDirectory
                            .appendingPathComponent(
                                UUID().uuidString,
                                isDirectory: true
                            )
                        try FileManager.default.createDirectory(
                            at: directory,
                            withIntermediateDirectories: false
                        )
                        destination = directory.appendingPathComponent(
                            filename,
                            isDirectory: false
                        )
                    }
                    do {
                        try PatternProjectPackageCodec.save(
                            metadata: captured.metadata,
                            tilePayloadProvider: captured,
                            to: destination
                        )
                        return destination
                    } catch {
                        if createdTemporaryDirectory {
                            try? FileManager.default.removeItem(at: directory)
                        }
                        throw error
                    }
                }.value
                if requestedDestination == nil {
                    projectExportURL = writtenURL
                    projectExportPresented = true
                }
            } catch {
                fileErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleImportResult(
        _ result: Result<[URL], Error>
    ) {
        guard !fileOperationBusy else { return }
        switch result {
        case let .failure(error):
            fileErrorMessage = error.localizedDescription
        case let .success(urls):
            guard let url = urls.first else { return }
            openProject(at: url, securityScoped: true)
        }
    }

    private func openProject(
        at url: URL,
        securityScoped: Bool
    ) {
        guard !fileOperationBusy else { return }
        fileOperationBusy = true
        fileErrorMessage = nil
        Task {
            defer { completeFileOperation() }
            do {
                let decoded = try await Task.detached(
                    priority: .utility
                ) {
                    let accessed = securityScoped
                        && url.startAccessingSecurityScopedResource()
                    defer {
                        if accessed {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    return try PatternProjectPackageCodec.open(at: url)
                }.value
                guard case let .ready(current) = state else {
                    throw PatternProjectBridgeError
                        .incompatibleSurface
                }
                let identity = try PatternProjectBridge.identity(
                    from: decoded
                )
                let renderer = try await PatternProjectBridge.makeRenderer(
                    from: decoded,
                    device: current.renderer.device,
                    library: current.renderer.library,
                    drawableSize:
                        current.renderer.viewport.drawableSize
                )
                let replacement = try current.replacementSession(
                    renderer: renderer
                )
                #if DEBUG && os(macOS)
                if debugHUDVisible {
                    updateDebugPerformanceSampling(
                        current,
                        visible: false
                    )
                }
                #endif
                projectIdentity = identity
                stageDRouteEvidence.unbind(current)
                stageDRouteEvidence.bind(replacement)
                state = .ready(replacement)
                #if DEBUG && os(macOS)
                if debugHUDVisible {
                    updateDebugPerformanceSampling(
                        replacement,
                        visible: true
                    )
                }
                #endif
                requestEditorFocus()
            } catch {
                fileErrorMessage = error.localizedDescription
            }
        }
    }

    private func beginImageExport(
        _ controller: EditorSessionController
    ) {
        guard !fileOperationBusy else { return }
        let disposition = EditorImageExportPolicy.disposition(
            acceptanceDestination: stageDRouteEvidence.exportURL
        )
        fileOperationBusy = true
        fileErrorMessage = nil
        Task {
            defer { completeFileOperation() }
            do {
                let output = try await controller.renderer
                    .exportFlattenedScene(
                        pixelSize: controller.model.pixelSize,
                        transparentBackground: true
                    )
                let written = try await Task.detached(priority: .utility) {
                    let destination: URL
                    let presentsExporter: Bool
                    switch disposition {
                    case let .direct(requested):
                        destination = requested
                        presentsExporter = false
                    case .userSelectedDestination:
                        let temporary = FileManager.default.temporaryDirectory
                            .appendingPathComponent(
                                UUID().uuidString,
                                isDirectory: true
                            )
                        try FileManager.default.createDirectory(
                            at: temporary,
                            withIntermediateDirectories: false
                        )
                        destination = temporary.appendingPathComponent(
                            "Pattern.png",
                            isDirectory: false
                        )
                        presentsExporter = true
                    }
                    let directory = destination.deletingLastPathComponent()
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    try? FileManager.default.removeItem(at: destination)
                    try EncodedPNGWriter.writeBGRA(
                        output.bgra8Bytes,
                        pixelSize: output.pixelSize,
                        to: destination
                    )
                    return (destination, presentsExporter)
                }.value
                if written.1 {
                    imageExportURL = written.0
                    imageExportPresented = true
                }
            } catch {
                fileErrorMessage = error.localizedDescription
            }
        }
    }

    private func completeFileOperation() {
        fileOperationBusy = false
        fileOperationCompletionGeneration &+= 1
    }

    private var stageDDebugHUDVisible: Bool {
        #if DEBUG && os(macOS)
        debugHUDVisible
        #else
        false
        #endif
    }

    private func cancelCurrentInteraction(
        _ controller: EditorSessionController
    ) {
        handleEditorShortcut(
            .cancel,
            controller: controller,
            pointerCancellationGeneration: &pointerCancellationGeneration
        )
    }

    private func handleKeyPress(
        _ press: KeyPress,
        controller: EditorSessionController
    ) -> KeyPress.Result {
        guard focusTarget == .editor else {
            return .ignored
        }

        #if DEBUG && os(macOS)
        if press.phase == .down,
           press.modifiers.isEmpty || press.modifiers == .shift,
           isDebugHUDToggleCharacter(press.characters)
        {
            debugHUDVisible.toggle()
            if debugHUDVisible {
                debugPerformanceMonitor.reset()
            }
            return .handled
        }
        #endif

        guard let phase = editorPhase(from: press.phase),
              let shortcut = EditorKeymap.resolve(
                editorKey(from: press),
                modifiers: editorModifiers(from: press.modifiers),
                phase: phase
              )
        else {
            return .ignored
        }

        handleEditorShortcut(
            shortcut,
            controller: controller,
            pointerCancellationGeneration: &pointerCancellationGeneration
        )
        return .handled
    }

    #if DEBUG && os(macOS)
    private func updateDebugPerformanceSampling(
        _ controller: EditorSessionController,
        visible: Bool
    ) {
        controller.renderer.onInteractiveFramePresented = nil
        controller.renderer.onInteractiveFrameMetrics = nil
        controller.renderer.onStrokeRuntimeSnapshot = nil
        controller.renderer.onStrokeRuntimeSegmentMarker = nil
        let monitor = debugPerformanceMonitor
        let logger = debugPerformanceLogger
        let gpuName = controller.renderer.device.name
        let controllerID = ObjectIdentifier(controller)
        guard visible else {
            guard debugPerformanceControllerID == controllerID else {
                return
            }
            debugPerformanceControllerID = nil
            debugPerformanceLoggingActive = false
            let snapshot = monitor.snapshot
            let context = debugPerformanceContext(controller)
            logger.record(
                .sessionEnded,
                snapshot: snapshot,
                gpuName: gpuName,
                context: context
            )
            controller.renderer.disableStrokeRuntimeTelemetry()
            Task {
                try? await logger.flush()
            }
            return
        }
        let startsNewSession =
            debugPerformanceControllerID != controllerID
        debugPerformanceControllerID = controllerID
        debugPerformanceLoggingActive = true
        if startsNewSession {
            monitor.reset()
            Task { @MainActor in
                let evidence = await controller.renderer
                    .stageDAcceptanceEvidence()
                guard debugPerformanceControllerID == controllerID else {
                    return
                }
                monitor.recordPaintEvidence(evidence)
            }
            controller.renderer.onStrokeRuntimeSnapshot = { runtime in
                monitor.recordStrokeRuntimeSnapshot(runtime)
            }
            controller.renderer.configureStrokeRuntimeTelemetry(
                profile: .productionTenSeconds
            )
            print("DEBUG PERF LOG \(logger.logURL.path)")
            let initialContext = debugPerformanceContext(controller)
            logger.record(
                .sessionStarted,
                snapshot: monitor.snapshot,
                gpuName: gpuName,
                context: initialContext
            )
        }
        controller.renderer.onStrokeRuntimeSnapshot = { runtime in
            monitor.recordStrokeRuntimeSnapshot(runtime)
            logger.record(
                .sample,
                snapshot: monitor.snapshot,
                gpuName: gpuName,
                context: debugPerformanceContext(controller)
            )
        }
        controller.renderer.onStrokeRuntimeSegmentMarker = { marker in
            guard let runtime = controller.renderer.strokeRuntimeSnapshot,
                  runtime.sessionID == marker.sessionID,
                  runtime.segmentID == marker.segmentID
            else { return }
            monitor.recordStrokeRuntimeSnapshot(runtime)
            logger.record(
                marker.kind == .segmentBegan ? .segmentBegan : .segmentEnded,
                snapshot: monitor.snapshot,
                gpuName: gpuName,
                context: debugPerformanceContext(controller)
            )
        }
        controller.renderer.onInteractiveFrameMetrics = { metrics in
            monitor.recordRendererFrame(
                metrics,
                deposition: controller.renderer
                    .brushLabDiagnosticSnapshot.deposition
            )
            Task { @MainActor in
                let evidence = await controller.renderer
                    .stageDAcceptanceEvidence()
                guard debugPerformanceControllerID == controllerID else {
                    return
                }
                monitor.recordPaintEvidence(evidence)
            }
        }
        controller.renderer.onInteractiveFramePresented = {
            timestamp,
            targetFramesPerSecond in
            guard monitor.recordPresentedFrame(
                at: timestamp,
                targetFramesPerSecond: targetFramesPerSecond
            ) else {
                return
            }
        }
    }

    private func debugPerformanceContext(
        _ controller: EditorSessionController
    ) -> DebugPerformanceContext {
        DebugPerformanceContext(
            brushID: controller.model.selectedRecipeID.rawValue,
            tool: String(describing: controller.model.tool),
            brushDiameter: controller.model.brushDiameter,
            symmetry: String(describing: controller.model.tiling),
            canvasWidth: controller.model.pixelSize.width,
            canvasHeight: controller.model.pixelSize.height,
            gridVisible: controller.model.showGrid
        )
    }
    #endif

    private func editorKey(from press: KeyPress) -> EditorKey {
        switch press.key {
        case .escape:
            .escape
        case .space:
            .space
        case .return:
            .returnKey
        default:
            EditorKey(rawValue: press.characters)
        }
    }

    private func editorPhase(from phase: KeyPress.Phases) -> EditorKeyPhase? {
        switch phase {
        case .down:
            .down
        case .repeat:
            .repeat
        case .up:
            .up
        default:
            nil
        }
    }

    private func editorModifiers(
        from modifiers: EventModifiers
    ) -> EditorKeyModifiers {
        var result: EditorKeyModifiers = []
        if modifiers.contains(.command) {
            result.insert(.command)
        }
        if modifiers.contains(.shift) {
            result.insert(.shift)
        }
        if modifiers.contains(.option) {
            result.insert(.option)
        }
        if modifiers.contains(.control) {
            result.insert(.control)
        }
        return result
    }

    #if os(macOS)
    private func commandActions(
        for controller: EditorSessionController
    ) -> EditorCommandActions {
        EditorCommandActions(
            undo: {
                controller.undo()
                requestEditorFocus()
            },
            redo: {
                controller.redo()
                requestEditorFocus()
            },
            clear: {
                controller.clear()
                requestEditorFocus()
            },
            selectDraw: {
                controller.handleTool(.draw)
                requestEditorFocus()
            },
            selectErase: {
                controller.handleTool(.erase)
                requestEditorFocus()
            },
            openProject: beginOpen,
            saveProject: {
                beginSave(controller)
            },
            canUndo: controller.model.canUndo,
            canRedo: controller.model.canRedo,
            canEdit: !controller.model.isBusy,
            canUseFileCommands: !fileOperationBusy
        )
    }
    #endif

    private enum CanvasState {
        case loading
        case ready(EditorSessionController)
        case unavailable(String)
    }
}

#if DEBUG && os(macOS)
func isDebugHUDToggleCharacter(_ characters: String) -> Bool {
    ["`", "~", "§", "±"].contains(characters)
}
#endif

private struct ErrorBanner: View {
    let error: MetalRendererError
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error.localizedDescription)
                .font(.caption)
                .lineLimit(2)
                .accessibilityIdentifier("Renderer Error")
                .accessibilityValue(error.localizedDescription)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Error")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: editorControlExtent)
        .foregroundStyle(.white)
        .background(Color.red.opacity(0.92))
    }
}

private struct FileErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.exclamationmark")
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .accessibilityIdentifier("File Error")
                .accessibilityValue(message)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss File Error")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: editorControlExtent)
        .foregroundStyle(.white)
        .background(Color.red.opacity(0.92))
    }
}
