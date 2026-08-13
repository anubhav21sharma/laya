#if os(macOS)
import AppKit
import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import PatternFile
import SwiftUI
import Testing

@MainActor
private final class HostedSessionDriver: ObservableObject {
    @Published var controller: EditorSessionController

    init(controller: EditorSessionController) {
        self.controller = controller
    }
}

private struct HostedContentView: View {
    @ObservedObject var driver: HostedSessionDriver

    var body: some View {
        ContentView(controller: driver.controller)
    }
}

private struct HostedEditorCanvas: View {
    @ObservedObject var driver: HostedSessionDriver

    var body: some View {
        EditorCanvasHost(
            controller: driver.controller,
            brushDiameter: driver.controller.model.brushDiameter,
            requestEditorFocus: {},
            pointerCancellationGeneration: 0
        )
    }
}

private final class EstimatedTouchIdentity {}

@Test
func appProjectExportsEveryBrushLabDocumentTypeOnMacAndPad() throws {
    let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let project = try String(
        contentsOf: appDirectory.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let identifier =
        "UTTypeIdentifier: com.anubhav.brush-lab-professional-review-matrix"
    let extensionTag = "- json"

    #expect(project.components(separatedBy: identifier).count - 1 == 2)
    #expect(project.components(separatedBy: extensionTag).count - 1 == 2)
}

@Test
func productionPerformanceTraceWaitsForAcceptedInputWork() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "App/PatternSpike/Harness/HarnessLaunch.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains(
        "renderer.flushAcceptedStrokeInputForHarness()"
    ))
}

@Test
func imageExportPolicyKeepsTheProductRouteAvailableWithoutAcceptanceInjection()
    throws
{
    let destination = URL(fileURLWithPath: "/tmp/stage-d-export.png")
    #expect(EditorImageExportPolicy.disposition(
        acceptanceDestination: nil
    ) == .userSelectedDestination)
    #expect(EditorImageExportPolicy.disposition(
        acceptanceDestination: destination
    ) == .direct(destination))

    let pixelSize = PixelSize(width: 2, height: 1)
    let expectedBytes: [UInt8] = [
        1, 2, 3, 255,
        4, 5, 6, 255,
    ]
    let correctPNG = try PatternRasterPNGCodec.encode(PatternRasterImage(
        pixelSize: pixelSize,
        bgra8PremultipliedBytes: expectedBytes
    ))
    let correct = try StageDExportedPNGValidator.validate(
        correctPNG,
        expectedPixelSize: pixelSize,
        expectedBGRA8Bytes: expectedBytes
    )
    #expect(correct.pixelSize == pixelSize)
    #expect(correct.bgra8SHA256.count == 64)

    let wrongPNG = try PatternRasterPNGCodec.encode(PatternRasterImage(
        pixelSize: pixelSize,
        bgra8PremultipliedBytes: [
            9, 9, 9, 255,
            8, 8, 8, 255,
        ]
    ))
    #expect(throws: StageDExportedPNGValidationError.pixelMismatch) {
        _ = try StageDExportedPNGValidator.validate(
            wrongPNG,
            expectedPixelSize: pixelSize,
            expectedBGRA8Bytes: expectedBytes
        )
    }
}

@Test
func stagedFileExportDocumentsPreserveBytesAndExactTypes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    let projectURL = directory.appendingPathComponent("drawing.patternproj")
    let pngURL = directory.appendingPathComponent("drawing.png")
    let projectBytes = Data([1, 2, 3, 4])
    let pngBytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
    try projectBytes.write(to: projectURL)
    try pngBytes.write(to: pngURL)

    let project = try StagedEditorExportDocument(
        stagedFileURL: projectURL
    )
    let png = try StagedEditorExportDocument(stagedFileURL: pngURL)

    #expect(StagedEditorExportDocument.readableContentTypes == [
        .patternProject,
        .png,
    ])
    #expect(project.data == projectBytes)
    #expect(png.data == pngBytes)
}

@Test
func stageDRouteConfigurationRequiresEveryDeterministicBoundary() throws {
    #expect(StageDAppRouteConfiguration(environment: [:]) == nil)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let environment = [
        StageDAppRouteConfiguration.manifestEnvironmentKey:
            directory.appendingPathComponent("routes.json").path,
        StageDAppRouteConfiguration.projectEnvironmentKey:
            directory.appendingPathComponent("project.patternproj").path,
        StageDAppRouteConfiguration.exportEnvironmentKey:
            directory.appendingPathComponent("export.png").path,
        StageDAppRouteConfiguration.commitEnvironmentKey:
            String(repeating: "a", count: 40),
        StageDAppRouteConfiguration.dateEnvironmentKey:
            "2026-08-10T12:00:00Z",
    ]

    let configuration = try #require(
        StageDAppRouteConfiguration(environment: environment)
    )

    #expect(configuration.manifestURL.path.hasSuffix("routes.json"))
    #expect(configuration.projectURL.path.hasSuffix("project.patternproj"))
    #expect(configuration.exportURL.path.hasSuffix("export.png"))
    #expect(configuration.gitCommit == String(repeating: "a", count: 40))

    var relativeEnvironment = environment
    relativeEnvironment[StageDAppRouteConfiguration.manifestEnvironmentKey] =
        "relative/routes.json"
    #expect(StageDAppRouteConfiguration(
        environment: relativeEnvironment
    ) == nil)
}

@Test
@MainActor
func stageDRouteRecorderBindsAppStatePixelsAndQuiescentSparseOwnership()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("routes.json")
    let recorder = StageDAppRouteEvidenceRecorder(environment: [
        StageDAppRouteConfiguration.manifestEnvironmentKey: manifestURL.path,
        StageDAppRouteConfiguration.projectEnvironmentKey:
            directory.appendingPathComponent("project.patternproj").path,
        StageDAppRouteConfiguration.exportEnvironmentKey:
            directory.appendingPathComponent("export.png").path,
        StageDAppRouteConfiguration.commitEnvironmentKey:
            String(repeating: "b", count: 40),
        StageDAppRouteConfiguration.dateEnvironmentKey:
            "2026-08-10T12:00:00Z",
    ])
    recorder.bind(controller)

    for expectedRoute in StageDAppRouteRequirements.orderedRoutes {
        let recordedRoute = try await recorder.recordNext()
        #expect(recordedRoute.scenarioID == expectedRoute.scenarioID)
        #expect(recordedRoute.routeID == expectedRoute.routeID)
    }
    let finalRoute = try #require(
        StageDAppRouteRequirements.orderedRoutes.last
    )
    let rerecordedRoute = try await recorder.rerecordLast()
    #expect(rerecordedRoute.scenarioID == finalRoute.scenarioID)
    #expect(rerecordedRoute.routeID == finalRoute.routeID)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
        StageDAcceptanceManifest.self,
        from: Data(contentsOf: manifestURL)
    )
    #expect(manifest.rows.map(\.scenarioID).sorted() == [
        StageDAcceptanceRequirements.appControls,
        StageDAcceptanceRequirements.appPersistence,
        StageDAcceptanceRequirements.appShortcuts,
    ])
    #expect(manifest.rows.allSatisfy { $0.status == .failed })
    #expect(manifest.rows.allSatisfy {
        $0.backend == .productionSparseMetal
            && $0.expectedSemanticHash == nil
            && $0.numericOracle?.expected == $0.numericOracle?.actual
            && $0.metrics["pendingOwnershipCount"] == 0
            && $0.metrics[
                "snapshotOwnershipAccountingMismatchCount"
            ] == 0
            && $0.attributes["canonicalSHA256"]?.count == 64
            && $0.attributes["normalizedInputCount"] == "0"
            && $0.attributes["observedSemanticHash"]?.count == 64
    })
}

@Test
@MainActor
func stageDRouteRecorderDrivesPendingStrokeToQuiescence() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("routes.json")
    let recorder = StageDAppRouteEvidenceRecorder(environment: [
        StageDAppRouteConfiguration.manifestEnvironmentKey: manifestURL.path,
        StageDAppRouteConfiguration.projectEnvironmentKey:
            directory.appendingPathComponent("project.patternproj").path,
        StageDAppRouteConfiguration.exportEnvironmentKey:
            directory.appendingPathComponent("export.png").path,
        StageDAppRouteConfiguration.commitEnvironmentKey:
            String(repeating: "c", count: 40),
        StageDAppRouteConfiguration.dateEnvironmentKey:
            "2026-08-10T12:00:00Z",
    ])
    recorder.bind(controller)

    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 24, y: 24),
        timestamp: 0,
        phase: .began
    ))
    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 40, y: 40),
        timestamp: 1,
        phase: .ended
    ))
    #expect(controller.model.isBusy)

    try await recorder.record(
        scenarioID: StageDAcceptanceRequirements.appControls,
        routeID: "controls.draw"
    )

    #expect(!controller.model.isBusy)
    #expect(renderer.isIdle)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
        StageDAcceptanceManifest.self,
        from: Data(contentsOf: manifestURL)
    )
    let row = try #require(manifest.rows.first)
    #expect(row.metrics["pendingOwnershipCount"] == 0)
    #expect(row.attributes["paintedPixelCount"] != "0")
}

@Test
@MainActor
func stageDRouteSemanticHashIgnoresVariableIntermediateGestureSamples()
    async throws
{
    let direct = try await recordedDrawEvidence(intermediatePoints: [])
    let sampled = try await recordedDrawEvidence(intermediatePoints: [
        ScreenPoint(x: 30, y: 52),
        ScreenPoint(x: 42, y: 20),
    ])

    #expect(direct.canonicalHash != sampled.canonicalHash)
    #expect(direct.semanticHash == sampled.semanticHash)
}

@Test
@MainActor
func stageDRouteRecorderReleasesDisplaySuspensionAfterGlobalTimeout()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = StageDAppRouteEvidenceRecorder(
        environment: stageDRouteEnvironment(
            directory: directory,
            commitCharacter: "e"
        ),
        quiescenceTimeoutNanoseconds: 1
    )
    recorder.bind(controller)
    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 24, y: 24),
        timestamp: 0,
        phase: .began
    ))
    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 40, y: 40),
        timestamp: 1,
        phase: .ended
    ))

    await #expect(throws: Error.self) {
        try await recorder.record(
            scenarioID: StageDAcceptanceRequirements.appControls,
            routeID: "controls.draw"
        )
    }
    #expect(!renderer.paintDisplayPreparationIsSuspendedForTesting)
}

@Test
@MainActor
func stageDRouteCaptureSerializesAnOverlappingAcceptanceExport() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = StageDAppRouteEvidenceRecorder(environment:
        stageDRouteEnvironment(directory: directory, commitCharacter: "f")
    )
    recorder.bind(controller)
    let gate = DocumentPaintPreparationTestGate()
    let export = Task { @MainActor in
        try await recorder.withDisplayPreparationSuspended(
            for: controller
        ) {
            await gate.wait()
        }
    }
    for _ in 0..<1_000
    where !renderer.paintDisplayPreparationIsSuspendedForTesting {
        await Task.yield()
    }
    #expect(renderer.paintDisplayPreparationIsSuspendedForTesting)

    let capture = Task { @MainActor in
        try await recorder.record(
            scenarioID: StageDAcceptanceRequirements.appControls,
            routeID: "controls.initial"
        )
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(renderer.paintDisplayPreparationIsSuspendedForTesting)

    await gate.open()
    try await export.value
    try await capture.value
    #expect(!renderer.paintDisplayPreparationIsSuspendedForTesting)
}

@Test
@MainActor
func productCaptureCoordinatesQuiescenceWithoutAcceptanceConfiguration()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let recorder = StageDAppRouteEvidenceRecorder(environment: [:])
    recorder.bind(controller)

    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 24, y: 24),
        timestamp: 0,
        phase: .began
    ))
    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 40, y: 40),
        timestamp: 1,
        phase: .ended
    ))

    var observedSuspendedQuiescence = false
    try await recorder.withDisplayPreparationSuspended(
        for: controller
    ) {
        observedSuspendedQuiescence =
            renderer.paintDisplayPreparationIsSuspendedForTesting
                && renderer.isIdle
                && !controller.model.isBusy
    }

    #expect(observedSuspendedQuiescence)
    #expect(!renderer.paintDisplayPreparationIsSuspendedForTesting)
}

@MainActor
private func recordedDrawEvidence(
    intermediatePoints: [ScreenPoint]
) async throws -> (semanticHash: String, canonicalHash: String) {
    let renderer = try #require(try makeControllerRenderer())
    let controller = EditorSessionController(renderer: renderer)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("routes.json")
    let recorder = StageDAppRouteEvidenceRecorder(environment:
        stageDRouteEnvironment(directory: directory, commitCharacter: "d")
    )
    recorder.bind(controller)

    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 24, y: 24),
        timestamp: 0,
        phase: .began
    ))
    for (index, point) in intermediatePoints.enumerated() {
        controller.handleStrokeSample(.mouse(
            position: point,
            timestamp: TimeInterval(index + 1),
            phase: .moved
        ))
    }
    controller.handleStrokeSample(.mouse(
        position: ScreenPoint(x: 48, y: 48),
        timestamp: TimeInterval(intermediatePoints.count + 1),
        phase: .ended
    ))
    try await recorder.record(
        scenarioID: StageDAcceptanceRequirements.appControls,
        routeID: "controls.draw"
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
        StageDAcceptanceManifest.self,
        from: Data(contentsOf: manifestURL)
    )
    let row = try #require(manifest.rows.first)
    return (
        try #require(row.attributes["observedSemanticHash"]),
        try #require(row.attributes["canonicalSHA256"])
    )
}

private func stageDRouteEnvironment(
    directory: URL,
    commitCharacter: Character
) -> [String: String] {
    [
        StageDAppRouteConfiguration.manifestEnvironmentKey:
            directory.appendingPathComponent("routes.json").path,
        StageDAppRouteConfiguration.projectEnvironmentKey:
            directory.appendingPathComponent("project.patternproj").path,
        StageDAppRouteConfiguration.exportEnvironmentKey:
            directory.appendingPathComponent("export.png").path,
        StageDAppRouteConfiguration.commitEnvironmentKey:
            String(repeating: commitCharacter, count: 40),
        StageDAppRouteConfiguration.dateEnvironmentKey:
            "2026-08-10T12:00:00Z",
    ]
}

@MainActor
private final class LifecycleBrushSelectionStore:
    EditorBrushSelectionStore
{
    var storedID: String?
    private(set) var writes: [String] = []

    init(storedID: String? = nil) {
        self.storedID = storedID
    }

    func readSelectedBrushID() -> String? {
        storedID
    }

    func writeSelectedBrushID(_ id: String) {
        storedID = id
        writes.append(id)
    }
}

#if DEBUG
@Test func debugHUDToggleAcceptsPhysicalGraveAndShiftedTilde() {
    #expect(isDebugHUDToggleCharacter("`"))
    #expect(isDebugHUDToggleCharacter("~"))
    #expect(isDebugHUDToggleCharacter("§"))
    #expect(isDebugHUDToggleCharacter("±"))
    #expect(!isDebugHUDToggleCharacter("1"))
    #expect(!isDebugHUDToggleCharacter(""))
}

@Test
@MainActor
func debugHUDHasACompactIntrinsicSize() {
    let host = NSHostingView(
        rootView: DebugPerformanceHUD(snapshot: DebugPerformanceSnapshot())
    )
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.width < 190)
    #expect(host.fittingSize.height < 200)
}

@Test
@MainActor
func hostedDebugHUDSamplesOnlyWhileVisible() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let host = NSHostingView(rootView: ContentView(controller: controller))
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 768),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    await settle(host)
    #expect(renderer.onInteractiveFramePresented == nil)

    sendKey("`", keyCode: 50, to: window)
    await settle(host)
    #expect(renderer.onInteractiveFramePresented != nil)
    #expect(renderer.onInteractiveFrameMetrics != nil)

    sendKey("`", keyCode: 50, to: window)
    await settle(host)
    #expect(renderer.onInteractiveFramePresented == nil)
    #expect(renderer.onInteractiveFrameMetrics == nil)

    sendKey("`", keyCode: 50, modifiers: .command, to: window)
    await settle(host)
    #expect(renderer.onInteractiveFramePresented == nil)
}
#endif

@Test(arguments: [
    SymmetryPresetID.squareRotation,
    .kaleidoscope30,
])
@MainActor
func latticeInspectorPreservesUntouchedContinuousConfigurationFields(
    _ preset: SymmetryPresetID
) {
    let committed = PeriodicSymmetryConfiguration(
        presetID: preset,
        repeatSize: PatternSize(width: 96.5004, height: 96.5004),
        orientationRadians: .pi / 7
    )
    let repeatDraft = TilingInspector.repeatSizeDraft(committed)
    let angleDraft = TilingInspector.orientationDraft(committed)

    let unchanged = TilingInspector.periodicConfiguration(
        repeatDraft: repeatDraft,
        orientationDraft: angleDraft,
        committed: committed,
        presetID: preset
    )
    #expect(unchanged == committed)

    let spacingOnly = TilingInspector.periodicConfiguration(
        repeatDraft: "120.25",
        orientationDraft: angleDraft,
        committed: committed,
        presetID: preset
    )
    #expect(spacingOnly?.repeatSize == PatternSize(
        width: 120.25,
        height: 120.25
    ))
    #expect(spacingOnly?.orientationRadians == committed.orientationRadians)

    let angleOnly = TilingInspector.periodicConfiguration(
        repeatDraft: repeatDraft,
        orientationDraft: "30.125",
        committed: committed,
        presetID: preset
    )
    #expect(angleOnly?.repeatSize == committed.repeatSize)
    #expect(angleOnly?.orientationRadians == Float(30.125) * .pi / 180)
}

@Test
@MainActor
func radialInspectorAcceptsArbitraryRaysAndRejectsInvalidGeometry() throws {
    let size = PixelSize(width: 320, height: 192)
    for rays in [2, 5, 17, 32] {
        let configuration = try #require(
            TilingInspector.radialConfiguration(
                kind: .mandala,
                rayDraft: " \(rays) ",
                centerXDraft: "160.5",
                centerYDraft: "91.25",
                referenceAngleDraft: "-30",
                pixelSize: size
            )
        )
        #expect(configuration.rayCount == rays)
        #expect(configuration.center == WorldPoint(x: 160.5, y: 91.25))
        #expect(
            abs(configuration.referenceAngleRadians + .pi / 6)
                < 0.000_1
        )
    }

    for invalidRays in ["1", "33", "2.5", "nan", ""] {
        #expect(TilingInspector.radialConfiguration(
            kind: .rotation,
            rayDraft: invalidRays,
            centerXDraft: "160",
            centerYDraft: "96",
            referenceAngleDraft: "0",
            pixelSize: size
        ) == nil)
    }
    #expect(TilingInspector.radialConfiguration(
        kind: .rotation,
        rayDraft: "8",
        centerXDraft: "320",
        centerYDraft: "96",
        referenceAngleDraft: "0",
        pixelSize: size
    ) == nil)
    #expect(TilingInspector.radialConfiguration(
        kind: .rotation,
        rayDraft: "8",
        centerXDraft: "160",
        centerYDraft: "96",
        referenceAngleDraft: "infinity",
        pixelSize: size
    ) == nil)

    let mirror = try #require(TilingInspector.radialConfiguration(
        kind: .mirror,
        rayDraft: "not-used",
        centerXDraft: "160",
        centerYDraft: "96",
        referenceAngleDraft: "15",
        pixelSize: size
    ))
    #expect(mirror.rayCount == 1)
}

@Test
@MainActor
func radialInspectorDefaultIsCenteredEightRayMandala() {
    let configuration = TilingInspector.defaultRadialConfiguration(
        pixelSize: PixelSize(width: 320, height: 192)
    )

    #expect(configuration.kind == .mandala)
    #expect(configuration.rayCount == 8)
    #expect(configuration.center == WorldPoint(x: 160, y: 96))
    #expect(configuration.referenceAngleRadians == 0)
}

@Test
func defaultContentViewInitializerDoesNotAllocateRenderer() throws {
    let source = try contentViewInitializerSource()

    #expect(!source.contains("MTLCreateSystemDefaultDevice"))
    #expect(!source.contains("GridRenderer("))
}

@Test
@MainActor
func contentViewBootstrapReturnsOnlyAfterProfessionalBrushesAreInstalled()
    async throws
{
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let store = LifecycleBrushSelectionStore()
    let controller = try await makeBootstrapEditorSession(
        device: device,
        library: makeNativeTestLibrary(device: device),
        selectionStore: store
    )

    #expect(
        controller.renderer.harnessPreparedDrawBrushIdentity?.definitionID
            == EditorBrushCatalog.defaultDraw.id
    )
    #expect(
        controller.renderer.harnessPreparedEraserBrushIdentity?.definitionID
            == EditorBrushCatalog.eraser.id
    )
    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
    #expect(store.writes == [EditorBrushCatalog.defaultDraw.id.rawValue])
}

@Test
@MainActor
func bootstrapRestoresAndConfirmsAStoredCanonicalBrushOnlyAfterActivation()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let store = LifecycleBrushSelectionStore(
        storedID: EditorBrushCatalog.nativeDryMedia.id.rawValue
    )

    let controller = try await makeBootstrapEditorSession(
        renderer: renderer,
        compileDefinition: { definition in
            try await compiler.compileAndActivate(definition: definition)
        },
        selectionStore: store
    )

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.nativeDryMedia.id)
    #expect(
        renderer.harnessPreparedDrawBrushIdentity?.definitionID
            == EditorBrushCatalog.nativeDryMedia.id
    )
    #expect(
        renderer.harnessPreparedEraserBrushIdentity?.definitionID
            == EditorBrushCatalog.eraser.id
    )
    #expect(store.writes == [EditorBrushCatalog.nativeDryMedia.id.rawValue])
}

@Test
@MainActor
func bootstrapFallsBackFromUnknownPersistenceAndRewritesDefault()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let store = LifecycleBrushSelectionStore(storedID: " \nunknown/brush\u{0}")

    let controller = try await makeBootstrapEditorSession(
        renderer: renderer,
        compileDefinition: { definition in
            try await compiler.compileAndActivate(definition: definition)
        },
        selectionStore: store
    )

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
    #expect(
        renderer.harnessPreparedDrawBrushIdentity?.definitionID
            == EditorBrushCatalog.defaultDraw.id
    )
    #expect(store.writes == [EditorBrushCatalog.defaultDraw.id.rawValue])
}

@Test
@MainActor
func bootstrapRejectsRetiredNativePersistenceBeforeCompilation() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let retiredID = BrushRecipeID("builtin.bounded-wash")
    let store = LifecycleBrushSelectionStore(storedID: retiredID.rawValue)
    var compiledIDs: [BrushRecipeID] = []

    await #expect(
        throws: EditorBrushSelectionError.retiredIdentifier(retiredID)
    ) {
        _ = try await makeBootstrapEditorSession(
            renderer: renderer,
            compileDefinition: { definition in
                compiledIDs.append(definition.id)
                throw MetalRendererError.unsupportedBrushProgram
            },
            selectionStore: store
        )
    }

    #expect(compiledIDs.isEmpty)
    #expect(store.storedID == retiredID.rawValue)
    #expect(store.writes.isEmpty)
}

@Test
@MainActor
func bootstrapCompileFailureFallsBackWithoutPublishingRequestedSelection()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let store = LifecycleBrushSelectionStore(
        storedID: EditorBrushCatalog.nativeDryMedia.id.rawValue
    )

    let controller = try await makeBootstrapEditorSession(
        renderer: renderer,
        compileDefinition: { definition in
            if definition.id == EditorBrushCatalog.nativeDryMedia.id {
                throw MetalRendererError.unsupportedBrushProgram
            }
            return try await compiler.compileAndActivate(
                definition: definition
            )
        },
        selectionStore: store
    )

    #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
    #expect(
        renderer.harnessPreparedDrawBrushIdentity?.definitionID
            == EditorBrushCatalog.defaultDraw.id
    )
    #expect(
        renderer.harnessPreparedEraserBrushIdentity?.definitionID
            == EditorBrushCatalog.eraser.id
    )
    #expect(store.writes == [EditorBrushCatalog.defaultDraw.id.rawValue])
}

@Test
@MainActor
func bootstrapDefaultFailureDoesNotConfirmOrRewritePersistence()
    async throws
{
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let store = LifecycleBrushSelectionStore(
        storedID: EditorBrushCatalog.nativeDryMedia.id.rawValue
    )

    await #expect(throws: MetalRendererError.self) {
        _ = try await makeBootstrapEditorSession(
            renderer: renderer,
            compileDefinition: { definition in
                if definition.id == EditorBrushCatalog.nativeDryMedia.id
                    || definition.id == EditorBrushCatalog.defaultDraw.id
                {
                    throw MetalRendererError.unsupportedBrushProgram
                }
                return try await compiler.compileAndActivate(
                    definition: definition
                )
            },
            selectionStore: store
        )
    }

    #expect(store.storedID == EditorBrushCatalog.nativeDryMedia.id.rawValue)
    #expect(store.writes.isEmpty)
}

@Test
@MainActor
func bootstrapRejectsMismatchedEraserBeforePublishingSelection() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let compiler = try makeNativeCompiler(renderer: renderer)
    let wrongEraser = try await compiler.compileAndActivate(
        definition: EditorBrushCatalog.nativeDryMedia.definition
    )
    let store = LifecycleBrushSelectionStore()

    await #expect(throws: MetalRendererError.self) {
        _ = try await makeBootstrapEditorSession(
            renderer: renderer,
            compileDefinition: { definition in
                if definition.id == EditorBrushCatalog.eraser.id {
                    return wrongEraser
                }
                return try await compiler.compileAndActivate(
                    definition: definition
                )
            },
            selectionStore: store
        )
    }

    #expect(store.writes.isEmpty)
}

@Test
@MainActor
func hostedContentViewRetainsOneEditorSessionAcrossUpdates() async throws {
    guard let initialRenderer = try makeControllerRenderer(),
          let replacementRenderer = try makeControllerRenderer()
    else { return }

    let initialController = EditorSessionController(renderer: initialRenderer)
    let replacementController = EditorSessionController(
        renderer: replacementRenderer
    )
    let driver = HostedSessionDriver(controller: initialController)
    let host = NSHostingView(rootView: HostedContentView(driver: driver))
    host.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)

    await settle(host)
    let initialCanvas = try #require(findCanvas(in: host))
    #expect(initialCanvas.controller === initialController)
    #expect(initialCanvas.gridRenderer === initialRenderer)
    #expect(initialCanvas.brushDiameterForTesting == 20)

    initialController.stepBrush(larger: true)
    initialController.handleTool(.erase)
    initialController.handleGridVisibility(true)
    initialController.handleTiling(.halfDrop)
    await settle(host)

    #expect(initialCanvas.brushDiameterForTesting == 25)
    #expect(initialController.model.tool == .erase)
    #expect(initialRenderer.interactiveGridVisibility)
    #expect(initialRenderer.tiling == .halfDrop)

    driver.controller = replacementController
    await settle(host)

    let updatedCanvas = try #require(findCanvas(in: host))
    #expect(updatedCanvas === initialCanvas)
    #expect(updatedCanvas.controller === initialController)
    #expect(updatedCanvas.gridRenderer === initialRenderer)
    #expect(updatedCanvas.brushDiameterForTesting == 25)
    #expect(replacementController.model.brushDiameter == 20)
}

@Test
@MainActor
func editorCanvasReplacesItsNativeViewForAnImportedSession() async throws {
    guard let initialRenderer = try makeControllerRenderer(),
          let replacementRenderer = try makeControllerRenderer()
    else { return }

    let initialController = EditorSessionController(renderer: initialRenderer)
    let replacementController = EditorSessionController(
        renderer: replacementRenderer
    )
    let driver = HostedSessionDriver(controller: initialController)
    let host = NSHostingView(rootView: HostedEditorCanvas(driver: driver))
    host.frame = CGRect(x: 0, y: 0, width: 640, height: 480)

    await settle(host)
    let initialCanvas = try #require(findCanvas(in: host))
    #expect(initialCanvas.controller === initialController)
    #expect(initialCanvas.gridRenderer === initialRenderer)

    driver.controller = replacementController
    await settle(host)

    let replacementCanvas = try #require(findCanvas(in: host))
    #expect(replacementCanvas !== initialCanvas)
    #expect(replacementCanvas.controller === replacementController)
    #expect(replacementCanvas.gridRenderer === replacementRenderer)
}

@Test
@MainActor
func hostedIdleCanvasPresentsWithoutStrokeLifecycleErrors() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var errors: [MetalRendererError] = []
    renderer.onError = { errors.append($0) }
    let host = NSHostingView(
        rootView: EditorCanvasHost(
            controller: controller,
            brushDiameter: controller.model.brushDiameter,
            requestEditorFocus: {},
            pointerCancellationGeneration: 0
        )
    )
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    await settle(host)
    try await Task.sleep(for: .milliseconds(100))
    await settle(host)

    #expect(!errors.contains(.invalidStrokeLifecycle))
}

@Test
@MainActor
func hostedTileFieldReceivesNumberKeyEventsWithoutEditorShortcuts() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let host = NSHostingView(rootView: ContentView(controller: controller))
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 768),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    await settle(host)
    let widthField = try #require(
        findSubviews(of: NSTextField.self, in: host).first {
            $0.isEditable && $0.placeholderString == "Width"
        }
    )
    widthField.selectText(nil)
    await Task.yield()

    sendKey("3", keyCode: 20, to: window)
    sendKey("2", keyCode: 19, to: window)
    sendKey("0", keyCode: 29, to: window)
    await settle(host)

    #expect(widthField.stringValue == "320")
    #expect(controller.model.tiling == .grid)
}

@Test
func radialNumericFieldsUseDistinctNonEditorFocusTargets() throws {
    let source = try tilingInspectorSource()

    for target in [
        "radialRayCount",
        "radialCenterX",
        "radialCenterY",
        "radialReferenceAngle",
    ] {
        #expect(
            source.contains(
                ".focused(focusTarget, equals: .\(target))"
            ) || source.contains(
                "equals: .\(target)"
            )
        )
    }
}

@Test
@MainActor
func hostedSquareFieldsAreConditionalAndKeepDigitsOutOfShortcuts() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let host = NSHostingView(rootView: ContentView(controller: controller))
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 768),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    await settle(host)
    #expect(
        findSubviews(of: NSTextField.self, in: host).allSatisfy {
            $0.placeholderString != "Spacing"
                && $0.placeholderString != "Angle"
        }
    )

    controller.handleTiling(.squareRotation)
    await settle(host)
    let repeatField = try #require(
        findSubviews(of: NSTextField.self, in: host).first {
            $0.isEditable && $0.placeholderString == "Spacing"
        }
    )
    repeatField.selectText(nil)
    await Task.yield()
    sendKey("3", keyCode: 20, to: window)
    sendKey("2", keyCode: 19, to: window)
    sendKey("0", keyCode: 29, to: window)
    await settle(host)

    #expect(repeatField.stringValue == "320")
    #expect(controller.model.tiling == .squareRotation)

    let angleField = try #require(
        findSubviews(of: NSTextField.self, in: host).first {
            $0.isEditable && $0.placeholderString == "Angle"
        }
    )
    angleField.selectText(nil)
    await Task.yield()
    sendKey("4", keyCode: 21, to: window)
    sendKey("5", keyCode: 23, to: window)
    await settle(host)

    #expect(angleField.stringValue == "45")
    #expect(controller.model.tiling == .squareRotation)

    sendKey("\r", keyCode: 36, to: window)
    await settle(host)

    #expect(
        controller.model.periodicConfiguration.repeatSize
            == PatternSize(width: 320, height: 320)
    )
    #expect(
        abs(
            controller.model.periodicConfiguration.orientationRadians
                - Float.pi / 4
        ) < 0.0001
    )
}

@Test
@MainActor
func hostedInkColorWellUpdatesTheEditorController() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var focusRequestCount = 0
    let topBar = EditorTopBar(
        controller: controller,
        requestEditorFocus: { focusRequestCount += 1 }
    )
    let host = NSHostingView(rootView: topBar)
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 600, height: 48),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer {
        NSColorPanel.shared.close()
        window.close()
    }

    await settle(host)
    let colorWell: NSColorWell = try #require(findSubview(in: host))
    NSColorPanel.shared.close()
    #expect(colorWell.accessibilityPerformPress())
    await settle(host)
    #expect(NSColorPanel.shared.isVisible)

    colorWell.color = NSColor(
        srgbRed: 0.25,
        green: 0.5,
        blue: 0.75,
        alpha: 0.8
    )
    colorWell.sendAction(colorWell.action, to: colorWell.target)
    await settle(host)

    let ink = controller.model.inkColor
    #expect(abs(ink.red - 0.25) < 0.001)
    #expect(abs(ink.green - 0.5) < 0.001)
    #expect(abs(ink.blue - 0.75) < 0.001)
    #expect(abs(ink.alpha - 0.8) < 0.001)
    #expect(focusRequestCount == 0)
}

@Test
@MainActor
func hostedBrushPickerUsesOnlyEditorDrawEntriesAndKeepsNominalDiameter() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var focusRequestCount = 0
    let topBar = EditorTopBar(
        controller: controller,
        requestEditorFocus: { focusRequestCount += 1 }
    )
    do {
        let host = NSHostingView(rootView: topBar)
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 48)

        await settle(host)
        let expectedNames = EditorBrushCatalog.drawEntries.map(\.displayName)
        let picker = try #require(
            findSubviews(of: NSPopUpButton.self, in: host).first {
                $0.itemTitles == expectedNames
            }
        )
        #expect(picker.itemTitles == expectedNames)
        #expect(!picker.itemTitles.contains(
            AnchorBrushCatalog.eraser.displayName
        ))
    }

    let nominalDiameter = controller.model.brushDiameter
    for entry in EditorBrushCatalog.drawEntries.reversed() {
        topBar.editorRecipeBinding.wrappedValue = entry.id

        #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
        #expect(controller.model.brushDiameter == nominalDiameter)
    }

    #expect(focusRequestCount == 0)
}

@Test
@MainActor
func repeatedRecipeAndToolChangesRemainCoherent() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let topBar = EditorTopBar(
        controller: controller,
        requestEditorFocus: {}
    )
    for entry in EditorBrushCatalog.drawEntries {
        controller.handleTool(.erase)
        topBar.editorRecipeBinding.wrappedValue = entry.id

        #expect(controller.model.tool == .erase)
        #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)

        controller.handleTool(.draw)
        #expect(controller.model.tool == .draw)
        #expect(controller.model.selectedRecipeID == EditorBrushCatalog.defaultDraw.id)
    }
}

@Test
@MainActor
func brushInputAdapterKeepsMouseNeutralAndOrdersValidSamples() throws {
    let adapter = BrushInputAdapter()
    let samples = adapter.orderedSamples([
        .init(
            position: ScreenPoint(x: 30, y: 30),
            pressure: 1,
            timestamp: 3,
            phase: .moved,
            isTablet: false
        ),
        .init(
            position: ScreenPoint(x: .nan, y: 10),
            pressure: 0,
            timestamp: 2,
            phase: .moved,
            isTablet: false
        ),
        .init(
            position: ScreenPoint(x: 10, y: 10),
            pressure: 0,
            timestamp: 1,
            phase: .began,
            isTablet: false
        ),
        .init(
            position: ScreenPoint(x: 20, y: 20),
            pressure: 0,
            timestamp: 3,
            phase: .moved,
            isTablet: false
        ),
    ])

    #expect(samples.map(\.timestamp) == [1, 3, 3])
    #expect(samples.map(\.position.x) == [10, 30, 20])
    #expect(samples.allSatisfy { $0.pressure == 0.5 })
    #expect(samples.allSatisfy { $0.source == .mouse })
    #expect(samples.allSatisfy { $0.kind == .actual })
    #expect(samples.allSatisfy { $0.capabilities.isEmpty })
}

@Test
@MainActor
func brushInputAdapterNormalizesTabletPressureTiltAndRotation() throws {
    var adapter = BrushInputAdapter()
    adapter.updateTabletProximity(
        deviceIdentifier: 7,
        capabilityMask:
            BrushInputAdapter.TabletCapability.pressure
                | BrushInputAdapter.TabletCapability.tiltX
                | BrushInputAdapter.TabletCapability.tiltY
                | BrushInputAdapter.TabletCapability.rotation,
        isEntering: true
    )
    let sample = try #require(adapter.orderedSamples([
        .init(
            position: ScreenPoint(x: 12, y: 34),
            pressure: 1.4,
            timestamp: 5,
            tilt: SIMD2(0.3, 0.4),
            rotationDegrees: 270,
            deviceIdentifier: 7,
            phase: .moved,
            kind: .coalesced,
            isTablet: true
        ),
    ]).first)

    #expect(sample.source == .tablet)
    #expect(sample.kind == .coalesced)
    #expect(sample.pressure == 1)
    #expect(sample.capabilities == [.pressure, .altitude, .azimuth, .roll])
    #expect(sample.deviceIdentifier == 7)
    #expect(abs(try #require(sample.altitude) - Float.pi / 3) < 0.0001)
    #expect(abs(try #require(sample.azimuth) - atan2(0.4, 0.3)) < 0.0001)
    #expect(abs(try #require(sample.roll) + Float.pi / 2) < 0.0001)
}

@Test
@MainActor
func brushInputAdapterUsesOnlyCachedDeclaredTabletCapabilities() throws {
    var adapter = BrushInputAdapter()
    adapter.updateTabletProximity(
        deviceIdentifier: 9,
        capabilityMask:
            BrushInputAdapter.TabletCapability.tangentialPressure,
        isEntering: true
    )

    let sample = try #require(adapter.orderedSamples([
        .init(
            position: ScreenPoint(x: 12, y: 34),
            pressure: 0.8,
            timestamp: 5,
            tilt: SIMD2(0.3, 0.4),
            rotationDegrees: 30,
            tangentialPressure: -1.4,
            deviceIdentifier: 9,
            phase: .moved,
            isTablet: true
        ),
    ]).first)

    #expect(sample.pressure == 0.5)
    #expect(sample.tangentialPressure == -1)
    #expect(sample.capabilities == [.tangentialPressure])
    #expect(sample.altitude == nil)
    #expect(sample.azimuth == nil)
    #expect(sample.roll == nil)

    adapter.updateTabletProximity(
        deviceIdentifier: 9,
        capabilityMask: 0,
        isEntering: false
    )
    let afterExit = try #require(adapter.orderedSamples([
        .init(
            position: ScreenPoint(x: 12, y: 34),
            pressure: 0.8,
            timestamp: 6,
            tangentialPressure: 0.4,
            deviceIdentifier: 9,
            phase: .moved,
            isTablet: true
        ),
    ]).first)
    #expect(afterExit.capabilities.isEmpty)
    #expect(afterExit.tangentialPressure == nil)
}

@Test
func brushInputBatchPolicyIsStableAndKeepsLifecycleOffEarlierSamples() {
    let ordered = BrushInputBatchPolicy.stableOrder(
        [(timestamp: 3.0, id: 0), (timestamp: 1.0, id: 1),
         (timestamp: 3.0, id: 2)],
        timestamp: \.timestamp
    )
    #expect(ordered.map(\.id) == [1, 0, 2])
    #expect(
        BrushInputBatchPolicy.phase(
            at: 0,
            count: 2,
            terminalPhase: .ended
        ) == .moved
    )
    #expect(
        BrushInputBatchPolicy.phase(
            at: 1,
            count: 2,
            terminalPhase: .ended
        ) == .ended
    )
    #expect(
        BrushInputBatchPolicy.phase(
            at: 0,
            count: 3,
            terminalPhase: .began
        ) == .began
    )
    #expect(
        BrushInputBatchPolicy.phase(
            at: 1,
            count: 3,
            terminalPhase: .began
        ) == .moved
    )
    #expect(
        BrushInputBatchPolicy.phase(
            at: 2,
            count: 3,
            terminalPhase: .began
        ) == .moved
    )

    let submittedPredictions = Array(0..<100_000)
    let predictionBatch = BrushInputBatchPolicy.predictionBatch(
        submittedPredictions,
        maximumCount: PredictionAdmissionLimits.maximumNormalizedSampleCount
    )
    var trackingCallCount = 0
    for _ in predictionBatch.admitted {
        trackingCallCount += 1
    }
    var transformationCallCount = 0
    let transformed = predictionBatch.admitted.map { value in
        transformationCallCount += 1
        return value
    }
    #expect(predictionBatch.submittedCount == 100_000)
    #expect(predictionBatch.admitted.count == 64)
    #expect(trackingCallCount == 64)
    #expect(transformationCallCount == 64)
    #expect(transformed == Array(0..<64))
}

@Test
func brushInputBatchPolicyDiscoversAndPersistsRollWithoutAdvertisingZero() {
    #expect(!BrushInputBatchPolicy.discoversRoll(
        previouslyDiscovered: false,
        rollIsEstimated: false,
        rollExpectsUpdate: false,
        nativeRoll: 0
    ))
    #expect(BrushInputBatchPolicy.discoversRoll(
        previouslyDiscovered: false,
        rollIsEstimated: true,
        rollExpectsUpdate: false,
        nativeRoll: 0
    ))
    #expect(BrushInputBatchPolicy.discoversRoll(
        previouslyDiscovered: true,
        rollIsEstimated: false,
        rollExpectsUpdate: false,
        nativeRoll: 0
    ))
}

@Test
func brushInputBatchPolicySelectsUniquePencilAmongIncidentalTouches() {
    struct Candidate: Equatable {
        let id: Int
        let isPencil: Bool
    }
    let pencil = Candidate(id: 1, isPencil: true)
    let palm = Candidate(id: 2, isPencil: false)
    let secondPencil = Candidate(id: 3, isPencil: true)

    #expect(
        BrushInputBatchPolicy.primaryInput(
            [palm, pencil],
            isPencil: \.isPencil
        ) == pencil
    )
    #expect(
        BrushInputBatchPolicy.primaryInput(
            [palm],
            isPencil: \.isPencil
        ) == palm
    )
    #expect(
        BrushInputBatchPolicy.primaryInput(
            [palm, Candidate(id: 4, isPencil: false)],
            isPencil: \.isPencil
        ) == nil
    )
    #expect(
        BrushInputBatchPolicy.primaryInput(
            [pencil, secondPencil],
            isPencil: \.isPencil
        ) == nil
    )
}

@Test
func pendingEstimatedInputRegistryRetainsEarlierSamplesThroughCleanEnd() {
    var registry = PendingEstimatedInputRegistry<String>()
    registry.record(
        "coalesced",
        index: 71,
        expecting: [.pressure],
        isPredicted: false
    )
    registry.record(
        "clean-end",
        index: nil,
        expecting: [],
        isPredicted: false
    )

    #expect(registry.count == 1)
    #expect(registry.value(for: 71) == "coalesced")
    registry.record(
        "resolved",
        index: 71,
        expecting: [],
        isPredicted: false
    )
    #expect(registry.isEmpty)
}

@Test
func pendingEstimatedInputRegistryResolvesIndicesIndependently() {
    var registry = PendingEstimatedInputRegistry<Int>()
    registry.record(
        1,
        index: 81,
        expecting: [.pressure],
        isPredicted: false
    )
    registry.record(
        2,
        index: 82,
        expecting: [.roll],
        isPredicted: true
    )
    #expect(registry.indices == [81, 82])

    registry.record(
        3,
        index: 81,
        expecting: [],
        isPredicted: false
    )
    #expect(registry.indices == [82])
    registry.discardPredicted()
    #expect(registry.isEmpty)
}

@Test
func pendingEstimatedInputRegistryRequiresStoredObjectIdentity() {
    let priorTouch = EstimatedTouchIdentity()
    let currentTouch = EstimatedTouchIdentity()
    var registry = PendingEstimatedInputRegistry<EstimatedTouchIdentity>()
    registry.record(
        currentTouch,
        index: 91,
        expecting: [.pressure],
        isPredicted: false,
        inputGeneration: 7
    )

    #expect(registry.containsIdentical(currentTouch, for: 91))
    #expect(!registry.containsIdentical(priorTouch, for: 91))
    #expect(registry.inputGeneration(for: 91) == 7)
}

@Test
func tabletEventDeduplicatorKeepsPressureChangesAndDropsDuplicates() {
    var deduplicator = TabletEventDeduplicator()
    let first = TabletEventSignature(
        timestamp: 1,
        position: ScreenPoint(x: 10, y: 20),
        pressure: 0.4,
        deviceIdentifier: 9,
        phase: .moved
    )
    let acceptsFirst = deduplicator.shouldDeliver(first)
    let rejectsDuplicate = !deduplicator.shouldDeliver(first)
    let acceptsPressureChange = deduplicator.shouldDeliver(
        TabletEventSignature(
        timestamp: 1,
        position: ScreenPoint(x: 10, y: 20),
        pressure: 0.7,
        deviceIdentifier: 9,
        phase: .moved
        )
    )
    #expect(acceptsFirst)
    #expect(rejectsDuplicate)
    #expect(acceptsPressureChange)
    deduplicator.reset()
    let acceptsAfterReset = deduplicator.shouldDeliver(first)
    #expect(acceptsAfterReset)
}

@Test
@MainActor
func brushInputAdapterExtractsAnActualNativeMouseEvent() throws {
    let event = try #require(NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: NSPoint(x: 7, y: 9),
        modifierFlags: [],
        timestamp: 12,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ))
    let sample = try #require(BrushInputAdapter().orderedSamples(
        for: event,
        phase: .moved,
        position: ScreenPoint(x: 70, y: 90)
    ).first)

    #expect(sample.position == ScreenPoint(x: 70, y: 90))
    #expect(sample.timestamp == 12)
    #expect(sample.phase == .moved)
    #expect(sample.source == .mouse)
    #expect(sample.kind == .actual)
    #expect(sample.pressure == 0.5)
}

@MainActor
private func settle<Content: View>(_ host: NSHostingView<Content>) async {
    host.layoutSubtreeIfNeeded()
    await Task.yield()
    host.layoutSubtreeIfNeeded()
    await Task.yield()
}

@MainActor
private func findCanvas(in view: NSView) -> InteractiveMetalView? {
    if let canvas = view as? InteractiveMetalView {
        return canvas
    }
    for subview in view.subviews {
        if let canvas = findCanvas(in: subview) {
            return canvas
        }
    }
    return nil
}

@MainActor
private func findSubview<Subview: NSView>(in view: NSView) -> Subview? {
    if let subview = view as? Subview {
        return subview
    }
    for child in view.subviews {
        if let subview: Subview = findSubview(in: child) {
            return subview
        }
    }
    return nil
}

@MainActor
private func findSubviews<Subview: NSView>(
    of type: Subview.Type,
    in view: NSView
) -> [Subview] {
    var matches: [Subview] = []
    if let match = view as? Subview {
        matches.append(match)
    }
    for child in view.subviews {
        matches.append(contentsOf: findSubviews(of: type, in: child))
    }
    return matches
}

@MainActor
private func sendKey(
    _ character: String,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [],
    to window: NSWindow
) {
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ) else { continue }
        window.sendEvent(event)
    }
}

private func contentViewInitializerSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "App/PatternSpike/ContentView.swift"
        ),
        encoding: .utf8
    )
    let initializerStart = try #require(source.range(of: "    init() {"))
    let bodyStart = try #require(
        source.range(
            of: "\n    var body:",
            range: initializerStart.upperBound..<source.endIndex
        )
    )
    return String(source[initializerStart.lowerBound..<bodyStart.lowerBound])
}

private func tilingInspectorSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "App/PatternSpike/Panels/TilingInspector.swift"
        ),
        encoding: .utf8
    )
}
#endif
